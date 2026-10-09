//! Request interception (capability "intercept"), the enforced network
//! policy (0x86 block) and filter-list subscriptions, split out of
//! `cefhost.zig`. The resource-request callbacks here run on CEF's IO
//! thread (see the "Request interception" banner below). The subscription
//! fetcher also carries GM_xmlhttpRequest for userscripts. The `Host`
//! methods are free functions taking `*Host`, re-exported from `Host`.

const std = @import("std");
const SpinLock = @import("../../util/spinlock.zig").SpinLock;
const atomicwrite = @import("../../util/atomicwrite.zig");
const c = @import("cbindings");
const cef = @import("cef");
const filter = @import("../filter.zig");
const filtersub = @import("../filtersub.zig");
const netpolicy = @import("../netpolicy.zig");
const urlhost = @import("../urlhost.zig");
const capture = @import("../capture.zig");
const nowMs = @import("../../util/clock.zig").nowMs;
const pathz = @import("../../util/pathz.zig");
const proto = @import("../protocol.zig");
const webrequest = @import("../webext/webrequest.zig");
const host_mod = @import("../cefhost.zig");
const CookieJob = host_mod.CookieJob;
const HOLD_HDR_MAX = host_mod.HOLD_HDR_MAX;
const HeapRef = host_mod.HeapRef;
const Host = host_mod.Host;
const Utf8 = host_mod.Utf8;
const View = host_mod.View;
const browserHost = host_mod.browserHost;
const dlReadHoldEnv = host_mod.dlReadHoldEnv;
const ext_scheme = host_mod.ext_scheme;
const headerMapJson = host_mod.headerMapJson;
const jsonStr = host_mod.jsonStr;
const release = host_mod.release;
const releaseArg = host_mod.releaseArg;
const setStr = host_mod.setStr;
const utf16Into = host_mod.utf16Into;
const webrequestDeinit = host_mod.webrequestDeinit;
const wreqConsider = host_mod.wreqConsider;
const wreqInitPipe = host_mod.wreqInitPipe;
const wreqNotifyAll = host_mod.wreqNotifyAll;
const wreqReadTimeoutEnv = host_mod.wreqReadTimeoutEnv;
const wreqTypeOf = host_mod.wreqTypeOf;

// -- request interception ------------------------------------------

/// Enable/disable blocking, globally (`view` 0) or per view. The
/// filter lists stay loaded; only the verdict is gated.
pub fn interceptSet(self: *Host, req: proto.InterceptSet) void {
    if (req.view == 0) {
        g_int.acquire();
        defer g_int.release();
        g_int.global_enabled = req.enabled != 0;
        for (&g_int.slots) |*s| {
            if (s.used) s.dirty = true;
        }
        return;
    }
    // Find-or-create: a per-view toggle sent BEFORE the
    // `view_create` naming the view (the ordering every policied
    // open relies on) used to be dropped silently here.
    const s = interceptSlotFor(self.gpa, req.view) orelse return;
    g_int.acquire();
    defer g_int.release();
    s.enabled = req.enabled != 0;
    s.dirty = true;
}

/// Reload the filter set from the seed list, the config filters
/// dir, and any extra paths named. The paths are REMEMBERED (this
/// frame is replace-all) so a later subscription reconcile's
/// reload cannot silently drop them. No network fetching.
pub fn interceptLists(self: *Host, req: proto.InterceptLists) void {
    var next: std.ArrayList([]const u8) = .empty;
    var adopted = false;
    defer if (!adopted) {
        for (next.items) |p| self.gpa.free(p);
        next.deinit(self.gpa);
    };
    for (req.paths) |p| {
        const dup = self.gpa.dupe(u8, p) catch return;
        next.append(self.gpa, dup) catch {
            self.gpa.free(dup);
            return;
        };
    }
    for (self.intercept_extra.items) |p| self.gpa.free(p);
    self.intercept_extra.deinit(self.gpa);
    self.intercept_extra = next;
    adopted = true;
    _ = interceptReload(self.gpa, self.intercept_extra.items);
}

/// The client's filter-list subscriptions (REPLACE-ALL).
///
/// Reconciles the cache directory against exactly this set: stale
/// or missing lists are fetched, and the cache files of
/// subscriptions that went away are removed. Fetching is the one
/// thing only this process can do — the daemon links libc and has
/// no TLS — and it happens nowhere unless the user configured a
/// url, so the default remains "filtering never touches the
/// network".
pub fn interceptSubscribe(self: *Host, req: proto.InterceptSubscribe) void {
    filterSubApply(self, req.update_hours, req.urls);
}

pub fn interceptStatus(self: *Host, req: proto.InterceptStatusReq) void {
    self.post(self.statusFrame(req.view));
}

pub fn statusFrame(self: *Host, view_id: u32) proto.InterceptStatus {
    _ = self;
    g_int.acquire();
    defer g_int.release();
    var out = proto.InterceptStatus{
        .view = view_id,
        .enabled = if (g_int.global_enabled) 1 else 0,
        .rules = g_int.rules,
        .blocked = 0,
        .total = 0,
    };
    for (&g_int.slots) |*s| {
        if (s.used and s.view_id == view_id) {
            out.enabled = if (g_int.global_enabled and s.enabled) 1 else 0;
            out.blocked = s.blocked;
            out.total = s.total;
            break;
        }
    }
    return out;
}

/// One view's log ring copied out under the lock: entries with seq >
/// `since`, the NEWEST `max` of them, oldest first, each with its
/// `net-log-detail` and the string storage both borrow (a ring entry's
/// own storage is free to change the moment the lock drops). Shared by
/// `intercept_log` and `net_log`, which differ only in the frame.
const LogSnap = struct {
    rows: [NLOG]proto.NetEntry2 = undefined,
    details: [NLOG]proto.NetDetail = undefined,
    url: [NLOG][LOG_URL_MAX]u8 = undefined,
    method: [NLOG][8]u8 = undefined,
    mime: [NLOG][LOG_MIME_MAX]u8 = undefined,
    stext: [NLOG][LOG_STEXT_MAX]u8 = undefined,
    n: usize = 0,
    next_seq: u32 = 0,

    fn put(self: *LogSnap, i: usize, e: *const LogEntry) void {
        fillEntry(&self.rows[i].entry, &self.url[i], &self.method[i], e);
        self.rows[i].reason = e.reason;
        @memcpy(self.mime[i][0..e.mime_len], e.mime[0..e.mime_len]);
        @memcpy(self.stext[i][0..e.stext_len], e.stext[0..e.stext_len]);
        self.details[i] = .{
            .flags = if (e.redirect) proto.NetDetail.REDIRECT else 0,
            .err = e.err,
            .prev_seq = e.prev_seq,
            .mime = self.mime[i][0..e.mime_len],
            .status_text = self.stext[i][0..e.stext_len],
        };
    }

    fn take(self: *LogSnap, view: u32, since: u32, max: u16) void {
        self.n = 0;
        self.next_seq = since;
        const cap: usize = @min(@as(usize, if (max == 0) NLOG else max), NLOG);
        {
            g_int.acquire();
            defer g_int.release();
            for (&g_int.slots) |*s| {
                if (!s.used or s.view_id != view) continue;
                self.next_seq = s.next_seq;
                const ring = s.ring orelse break;
                for (ring) |*e| {
                    if (e.seq == 0 or e.seq <= since) continue;
                    if (self.n >= cap) {
                        // Keep the NEWEST `cap`: replace the oldest held
                        // if this one is newer.
                        var oldest: usize = 0;
                        for (self.rows[0..self.n], 0..) |se, i| {
                            if (se.entry.seq < self.rows[oldest].entry.seq) oldest = i;
                        }
                        if (e.seq <= self.rows[oldest].entry.seq) continue;
                        self.put(oldest, e);
                        continue;
                    }
                    self.put(self.n, e);
                    self.n += 1;
                }
                break;
            }
        }
        // Ascending by seq (insertion sort; n <= NLOG). Rows and details
        // move together; their strings stay in the per-index storage,
        // which the slices already point into.
        var i: usize = 1;
        while (i < self.n) : (i += 1) {
            var j = i;
            while (j > 0 and self.rows[j - 1].entry.seq > self.rows[j].entry.seq) : (j -= 1) {
                std.mem.swap(proto.NetEntry2, &self.rows[j], &self.rows[j - 1]);
                std.mem.swap(proto.NetDetail, &self.details[j], &self.details[j - 1]);
            }
        }
    }
};

/// Answer a log pull (`intercept_log`, the frame the GUI face reads).
pub fn interceptLog(self: *Host, req: proto.InterceptLogReq) void {
    var snap: LogSnap = .{};
    snap.take(req.view, req.since, req.max);
    var entries: [NLOG]proto.NetEntry = undefined;
    for (snap.rows[0..snap.n], 0..) |r, i| entries[i] = r.entry;
    self.post(proto.InterceptLog{ .view = req.view, .next_seq = snap.next_seq, .entries = entries[0..snap.n], .details = snap.details[0..snap.n] });
}

// -- enforced network policy (0x86 block) --------------------------

var fault_policy_installs: u32 = 0;

/// Rig-only `SKETERM_WEB_FAULT_POLICY_INSTALL=<n>` + `SKETERM_WEB_FAULT_POLICY_ACK=oom|drop|stale` (default oom): fault the n-th install.
const PolicyFault = enum { oom, drop, stale };

fn policyFault() ?PolicyFault {
    const ordinal = c.getenv("SKETERM_WEB_FAULT_POLICY_INSTALL") orelse return null;
    fault_policy_installs +|= 1;
    const wanted = std.fmt.parseInt(u32, std.mem.span(ordinal), 10) catch return null;
    if (wanted != fault_policy_installs) return null;
    const mode = c.getenv("SKETERM_WEB_FAULT_POLICY_ACK") orelse return .oom;
    return std.meta.stringToEnum(PolicyFault, std.mem.span(mode));
}

/// Reserve a fail-closed slot before any allocation and acknowledge only installed monotone policies.
pub fn netPolicySet(self: *Host, req: proto.NetPolicySet) void {
    const s = policySlotFor(req.view) orelse return refusePolicyView(self, req);
    g_int.acquire();
    const failed = s.pc.exhausted == .policy_refused;
    g_int.release();
    if (!validPolicySet(req) or failed) {
        rejectPolicy(self, s, req.serial);
        return;
    }
    const fault = policyFault();
    // The injected OOM stands in for the real build allocation failing,
    // never for an ACK of an already accepted policy.
    const built = if (fault == .oom) error.OutOfMemory else netpolicy.Policy.build(self.gpa, req);
    const pol = built catch {
        if (fault == .oom) host_mod.logLine("fault policy oom view={d} serial={d} browser={any}", .{ req.view, req.serial, self.find(req.view) != null });
        rejectPolicy(self, s, req.serial);
        return;
    };
    if (s.pol) |old| {
        if (!netpolicy.subsetOf(pol, old)) {
            pol.deinit(self.gpa);
            rejectPolicy(self, s, req.serial);
            return;
        }
    }
    var old: ?*netpolicy.Policy = null;
    {
        g_int.acquire();
        defer g_int.release();
        old = s.pol;
        s.pol = pol;
        if (old == null) s.pc = .{ .started_ms = nowMs() };
        // An idle install must not emit a second, honest ACK behind the injected one.
        s.pol_dirty = fault != .drop and fault != .stale;
        if (old == null) s.deadline_stopped = false;
    }
    if (old) |o| o.deinit(self.gpa);
    var ack = netPolicyFrame(req.view);
    if (fault) |mode| {
        host_mod.logLine("fault policy {s} view={d} serial={d} browser={any}", .{ @tagName(mode), req.view, req.serial, self.find(req.view) != null });
        if (mode == .drop) return;
        if (mode == .stale) ack.serial -%= 1;
    }
    self.post(ack);
}

const table_full_msg = "network policy table is full; this view is refused";

/// No slot can hold the policy: fail THAT view closed (its create, or its
/// unpoliced existing browser) and keep every other view serving. Only a
/// refusal set that is itself full falls back to refusing the route.
fn refusePolicyView(self: *Host, req: proto.NetPolicySet) void {
    self.post(proto.EvNetPolicy{
        .view = req.view,
        .serial = req.serial,
        .active = 0,
        .exhausted = @intFromEnum(proto.NetReason.policy_refused),
        .requests = 0,
        .bytes = 0,
        .navigations = 0,
        .ms_left = 0,
        .denied = @splat(0),
    });
    if (self.findAny(req.view) != null) {
        // Created past the table without a slot: it can never be policied.
        self.failView(req.view, table_full_msg);
        return;
    }
    g_int.acquire();
    const remembered = g_int.refuseView(req.view);
    if (!remembered) g_int.policy_failed = true;
    g_int.release();
    if (remembered) return;
    self.route_refusal = "network policy table and its refusal list are full; this helper route is fail-closed";
    self.post(proto.EvRouteRefused{ .reason = self.route_refusal });
}

/// MAIN thread: the view was refused a policy, so its `view_create*` must fail.
pub fn policyRefusedView(view: u32) bool {
    g_int.acquire();
    defer g_int.release();
    for (g_int.refused_views) |id| if (id == view) return true;
    return false;
}

fn policyTestSet(view: u32, serial: u32) proto.NetPolicySet {
    return .{
        .view = view,
        .serial = serial,
        .flags = 0,
        .block_types = filter.RType.script.bit(),
        .allow_schemes = netpolicy.default_schemes,
        .max_requests = 100,
        .max_bytes = 1000,
        .max_navigations = 10,
        .deadline_ms = 5000,
        .allow_top = &.{"site.example"},
        .allow_sub = &.{"cdn.example"},
    };
}

fn policyTestAck(out: *proto.Outbox) !proto.EvNetPolicy {
    const msg = out.front() orelse return error.MissingAck;
    var reader = proto.Reader.init(msg.bytes);
    const frame = (try reader.next()) orelse return error.MissingAck;
    try std.testing.expectEqual(proto.Tag.ev_net_policy, frame.tag);
    const ev = try proto.decode(proto.EvNetPolicy, frame.payload);
    out.advance(msg.bytes.len);
    return ev;
}

test "policy installation OOM reserves a rejection and ring OOM cannot detach enforcement" {
    const gpa = std.testing.allocator;
    var out = proto.Outbox.init(gpa);
    defer out.deinit();
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    var host = Host.init(failing.allocator(), &out);
    defer host.deinit();
    defer interceptUnregister(gpa, 91);
    netPolicySet(&host, policyTestSet(91, 1));
    const ev = try policyTestAck(&out);
    try std.testing.expectEqual(@as(u32, 1), ev.serial);
    try std.testing.expectEqual(@as(u8, 0), ev.active);
    try std.testing.expectEqual(@intFromEnum(proto.NetReason.policy_refused), ev.exhausted);
    interceptRegister(failing.allocator(), 91, 88);
    try std.testing.expect(g_int.slotByCef(88) != null);
    try std.testing.expect(g_int.slotByCef(88).?.ring == null);
    const Fake = struct {
        fn id(_: [*c]cef.cef_browser_t) callconv(.c) c_int {
            return 88;
        }
    };
    var browser = std.mem.zeroes(cef.cef_browser_t);
    browser.get_identifier = Fake.id;
    try std.testing.expectEqual(@as(cef.cef_return_value_t, cef.RV_CANCEL), onBeforeResourceLoad(null, &browser, null, null, null));
    host.gpa = gpa;
    netPolicySet(&host, policyTestSet(91, 2));
    const retry = try policyTestAck(&out);
    try std.testing.expectEqual(@as(u8, 0), retry.active);
    try std.testing.expectEqual(@as(u32, 2), retry.serial);
}

test "replacement OOM latches refusal instead of retaining an usable broader grant" {
    const gpa = std.testing.allocator;
    var out = proto.Outbox.init(gpa);
    defer out.deinit();
    var host = Host.init(gpa, &out);
    defer host.deinit();
    defer interceptUnregister(gpa, 92);
    netPolicySet(&host, policyTestSet(92, 1));
    _ = try policyTestAck(&out);
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    host.gpa = failing.allocator();
    var next = policyTestSet(92, 2);
    next.max_requests = 10;
    netPolicySet(&host, next);
    const ev = try policyTestAck(&out);
    try std.testing.expectEqual(@as(u8, 0), ev.active);
    try std.testing.expectEqual(@as(u32, 2), ev.serial);
    const s = policySlotFor(92).?;
    try std.testing.expectEqual(proto.NetReason.policy_refused, s.pc.exhausted);
    try std.testing.expectEqual(proto.NetReason.policy_refused, netpolicy.decide(s.pol.?, &s.pc, .{
        .host = "site.example",
        .scheme = "https",
        .rtype = .document,
        .is_top = true,
    }, nowMs()));
    host.gpa = gpa;
}

test "helper validates all replacement scope and budget fields and preserves accounting" {
    const gpa = std.testing.allocator;
    for (0..11) |change| {
        var out = proto.Outbox.init(gpa);
        defer out.deinit();
        var host = Host.init(gpa, &out);
        defer host.deinit();
        defer interceptUnregister(gpa, 93);
        netPolicySet(&host, policyTestSet(93, 1));
        _ = try policyTestAck(&out);
        const s = policySlotFor(93).?;
        s.pc = .{ .started_ms = nowMs() - 100, .requests = 7, .bytes = 50, .navigations = 2, .exhausted = .byte_cap };
        const started = s.pc.started_ms;
        var next = policyTestSet(93, 2);
        switch (change) {
            0 => {
                next.max_requests = 10;
                next.allow_sub = &.{"site.example"};
            },
            1 => next.allow_top = &.{"extra.example"},
            2 => next.allow_sub = &.{"extra.example"},
            3 => next.allow_schemes |= netpolicy.Scheme.ws.bit(),
            4 => next.flags = proto.NetPolicySet.flag_allow_private,
            5 => next.block_types = 0,
            6 => next.max_requests = 101,
            7 => next.max_bytes = 0,
            8 => next.max_navigations = 11,
            9 => next.deadline_ms = 5001,
            10 => next.flags = proto.NetPolicySet.flag_untrusted,
            else => unreachable,
        }
        netPolicySet(&host, next);
        const ev = try policyTestAck(&out);
        try std.testing.expectEqual(@as(u32, 2), ev.serial);
        try std.testing.expectEqual(@as(u8, if (change == 0) 1 else 0), ev.active);
        try std.testing.expectEqual(started, s.pc.started_ms);
        try std.testing.expectEqual(@as(u32, 7), ev.requests);
        try std.testing.expectEqual(@as(u64, 50), ev.bytes);
        try std.testing.expectEqual(@as(u32, 2), ev.navigations);
        try std.testing.expect(ev.ms_left <= 4900);
        try std.testing.expectEqual(if (change == 0) proto.NetReason.byte_cap else .policy_refused, s.pc.exhausted);
    }
}

test "a full policy table refuses only the view past it" {
    const gpa = std.testing.allocator;
    var out = proto.Outbox.init(gpa);
    defer out.deinit();
    var host = Host.init(gpa, &out);
    defer host.deinit();
    defer {
        for (0..MAX_ISLOTS) |i| interceptUnregister(gpa, @intCast(100 + i));
        interceptUnregister(gpa, 500);
        g_int.policy_failed = false;
    }
    for (0..MAX_ISLOTS) |i| {
        netPolicySet(&host, policyTestSet(@intCast(100 + i), 1));
        try std.testing.expectEqual(@as(u8, 1), (try policyTestAck(&out)).active);
    }
    // The 33rd view: refused, and remembered so its create fails closed.
    netPolicySet(&host, policyTestSet(500, 5));
    const ev = try policyTestAck(&out);
    try std.testing.expectEqual(@as(u8, 0), ev.active);
    try std.testing.expectEqual(@as(u32, 5), ev.serial);
    try std.testing.expectEqual(@intFromEnum(proto.NetReason.policy_refused), ev.exhausted);
    try std.testing.expect(out.empty());
    try std.testing.expectEqual(@as(usize, 0), host.route_refusal.len);
    try std.testing.expect(!g_int.policy_failed);
    try std.testing.expect(policyRefusedView(500));
    try host.createView(.{ .view = 500, .w = 8, .h = 8, .scale_x1000 = 1000, .context = 0 });
    try std.testing.expect(host.find(500) == null);
    {
        const msg = out.front().?;
        var reader = proto.Reader.init(msg.bytes);
        try std.testing.expectEqual(proto.Tag.ev_view_create_failed, (try reader.next()).?.tag);
        out.advance(msg.bytes.len);
    }
    // Every other view keeps its policy, its replacements and its verdicts.
    for (0..MAX_ISLOTS) |i| {
        const view: u32 = @intCast(100 + i);
        try std.testing.expect(!policyRefusedView(view));
        const s = policySlotFor(view).?;
        try std.testing.expectEqual(proto.NetReason.none, netpolicy.decide(s.pol.?, &s.pc, .{ .host = "site.example", .scheme = "https", .rtype = .document, .is_top = true }, nowMs()));
    }
    var narrower = policyTestSet(100, 2);
    narrower.max_requests = 50;
    netPolicySet(&host, narrower);
    try std.testing.expectEqual(@as(u8, 1), (try policyTestAck(&out)).active);
    try std.testing.expectEqual(@as(cef.cef_return_value_t, cef.RV_CONTINUE), onBeforeResourceLoad(null, null, null, null, null));
    // Destroying the refused id forgets the refusal.
    host.destroyView(500);
    try std.testing.expect(!policyRefusedView(500));
}

test "destroy before browser creation releases installed and rejected policy slots" {
    const gpa = std.testing.allocator;
    var out = proto.Outbox.init(gpa);
    defer out.deinit();
    var host = Host.init(gpa, &out);
    defer host.deinit();
    for ([_]bool{ false, true }) |reject| {
        var req = policyTestSet(94, 1);
        if (reject) req.flags = 0x80000000;
        netPolicySet(&host, req);
        _ = try policyTestAck(&out);
        host.destroyView(94);
        for (&g_int.slots) |s| try std.testing.expect(!s.used or s.view_id != 94);
        netPolicyStatus(&host, .{ .view = 94, .serial = 123 });
        const ev = try policyTestAck(&out);
        try std.testing.expectEqual(@as(u32, 123), ev.serial);
        try std.testing.expectEqual(@as(u8, 0), ev.active);
    }
}

fn validPolicySet(req: proto.NetPolicySet) bool {
    const schemes: u16 = (1 << std.meta.fields(netpolicy.Scheme).len) - 1;
    const types: u16 = (1 << std.meta.fields(filter.RType).len) - 1;
    if (req.flags & ~(proto.NetPolicySet.flag_allow_private | proto.NetPolicySet.flag_untrusted) != 0 or
        req.allow_schemes & ~schemes != 0 or req.block_types & ~types != 0 or
        req.allow_top.len > netpolicy.MAX_HOSTS or req.allow_sub.len > netpolicy.MAX_HOSTS) return false;
    if (req.flags & proto.NetPolicySet.flag_untrusted != 0 and req.allow_schemes & ~netpolicy.default_schemes != 0) return false;
    for ([_][]const []const u8{ req.allow_top, req.allow_sub }) |hosts| {
        for (hosts) |host| if (!netpolicy.validHostEntry(host)) return false;
    }
    return true;
}

fn policySlotFor(view: u32) ?*ISlot {
    g_int.acquire();
    defer g_int.release();
    var free: ?*ISlot = null;
    for (&g_int.slots) |*s| {
        if (s.used and s.view_id == view) return s;
        if (!s.used and free == null) free = s;
    }
    const s = free orelse return null;
    s.* = .{ .used = true, .view_id = view };
    return s;
}

fn rejectPolicy(self: *Host, s: *ISlot, serial: u32) void {
    g_int.acquire();
    s.pol_failed_serial = serial;
    s.pc.exhausted = .policy_refused;
    netpolicy.deny(&s.pc, .policy_refused);
    s.pol_dirty = true;
    g_int.release();
    self.post(netPolicyFrame(s.view_id));
    if (self.find(s.view_id)) |v| if (v.browser) |b| if (b.stop_load) |stop| stop(b);
}

pub fn untrustedPolicyPresent(view: u32) bool {
    g_int.acquire();
    defer g_int.release();
    for (&g_int.slots) |*s| if (s.used and s.view_id == view) {
        return if (s.pol) |p| p.untrusted and s.pc.exhausted != .policy_refused else false;
    };
    return false;
}

pub fn untrustedPrivateAllowed(cef_id: c_int) ?bool {
    g_int.acquire();
    defer g_int.release();
    const s = g_int.slotByCef(cef_id) orelse return null;
    if (g_int.policy_failed or s.pc.exhausted == .policy_refused) return null;
    const pol = s.pol orelse return null;
    return if (pol.untrusted) pol.allow_private else null;
}

/// The broker's `enum sk_web_untrusted_reason` as a wire reason; an unknown (newer) value is a broker failure, never an allowance.
pub fn untrustedReason(reason: c_int) proto.NetReason {
    return switch (reason) {
        cef.SK_WEB_UNTRUSTED_PRIVATE => .resolved_private_address,
        cef.SK_WEB_UNTRUSTED_UNSUPPORTED => .untrusted_http,
        cef.SK_WEB_UNTRUSTED_BROKER_FAILURE => .untrusted_broker,
        cef.SK_WEB_UNTRUSTED_TIMEOUT => .untrusted_timeout,
        cef.SK_WEB_UNTRUSTED_QUEUE_FULL => .untrusted_queue_full,
        else => .untrusted_broker,
    };
}

pub fn untrustedDenied(cef_id: c_int, reason: c_int) callconv(.c) void {
    g_int.acquire();
    defer g_int.release();
    const s = g_int.slotByCef(cef_id) orelse return;
    netpolicy.deny(&s.pc, untrustedReason(reason));
    s.pol_dirty = true;
}

test "broker reasons map by the header's enum and unknown values fail closed" {
    try std.testing.expectEqual(proto.NetReason.resolved_private_address, untrustedReason(cef.SK_WEB_UNTRUSTED_PRIVATE));
    try std.testing.expectEqual(proto.NetReason.untrusted_http, untrustedReason(cef.SK_WEB_UNTRUSTED_UNSUPPORTED));
    try std.testing.expectEqual(proto.NetReason.untrusted_broker, untrustedReason(cef.SK_WEB_UNTRUSTED_BROKER_FAILURE));
    try std.testing.expectEqual(proto.NetReason.untrusted_timeout, untrustedReason(cef.SK_WEB_UNTRUSTED_TIMEOUT));
    try std.testing.expectEqual(proto.NetReason.untrusted_queue_full, untrustedReason(cef.SK_WEB_UNTRUSTED_QUEUE_FULL));
    for ([_]c_int{ 0, -1, 99 }) |unknown| try std.testing.expectEqual(proto.NetReason.untrusted_broker, untrustedReason(unknown));
}

test "untrusted broker limits mirrored for the MCP server match the header" {
    try std.testing.expectEqual(cef.SK_WEB_UNTRUSTED_MAX_JOBS, proto.UNTRUSTED_MAX_JOBS);
    try std.testing.expectEqual(cef.SK_WEB_UNTRUSTED_QUEUE_CAP, proto.UNTRUSTED_QUEUE_CAP);
    try std.testing.expectEqual(cef.SK_WEB_UNTRUSTED_TIMEOUT_MS, proto.UNTRUSTED_TIMEOUT_MS);
    try std.testing.expectEqual(cef.SK_WEB_UNTRUSTED_URL_CAP, proto.UNTRUSTED_URL_CAP);
    try std.testing.expectEqual(cef.SK_WEB_UNTRUSTED_UPLOAD_CAP, proto.UNTRUSTED_UPLOAD_CAP);
    try std.testing.expectEqual(cef.SK_WEB_UNTRUSTED_BODY_CAP, proto.UNTRUSTED_BODY_CAP);
}

pub fn netPolicyStatus(self: *Host, req: proto.NetPolicyReq) void {
    var ev = netPolicyFrame(req.view);
    if (req.serial != 0) ev.serial = req.serial;
    self.post(ev);
}

/// Latch only a refused navigation attempt; allowed preflight leaves resource-gate accounting untouched.
pub fn navigationBudget(view: u32, is_main: bool, scheme: []const u8, now_ms: i64) proto.NetReason {
    g_int.acquire();
    defer g_int.release();
    for (&g_int.slots) |*s| {
        if (!s.used or s.view_id != view) continue;
        const reason = if (s.pc.exhausted == .policy_refused)
            proto.NetReason.policy_refused
        else if (s.pol) |pol|
            netpolicy.budgetReason(pol, &s.pc, is_main, scheme, now_ms)
        else
            return .none;
        if (reason != .none) {
            netpolicy.deny(&s.pc, reason);
            s.pol_dirty = true;
        }
        return reason;
    }
    return .none;
}

test "navigation preflight leaves subframes and unrelated views outside the main-frame cap" {
    const gpa = std.testing.allocator;
    var out = proto.Outbox.init(gpa);
    defer out.deinit();
    var host = Host.init(gpa, &out);
    defer host.deinit();
    defer interceptUnregister(gpa, 95);
    var req = policyTestSet(95, 1);
    req.deadline_ms = 0;
    req.max_navigations = 1;
    netPolicySet(&host, req);
    _ = try policyTestAck(&out);
    const s = policySlotFor(95).?;
    netpolicy.commit(&s.pc, true);
    const before = s.pc;
    try std.testing.expectEqual(proto.NetReason.none, navigationBudget(95, false, "https", nowMs()));
    try std.testing.expectEqual(proto.NetReason.none, navigationBudget(95, true, "about", nowMs()));
    try std.testing.expectEqual(proto.NetReason.none, navigationBudget(96, true, "https", nowMs()));
    try std.testing.expectEqualDeep(before, s.pc);
    try std.testing.expectEqual(proto.NetReason.nav_cap, navigationBudget(95, true, "https", nowMs()));
    try std.testing.expectEqual(before.requests, s.pc.requests);
    try std.testing.expectEqual(before.navigations, s.pc.navigations);
    try std.testing.expectEqual(proto.NetReason.nav_cap, s.pc.exhausted);
    try std.testing.expectEqual(proto.NetReason.nav_cap, navigationBudget(95, true, "about", nowMs()));
    try std.testing.expectEqual(proto.NetReason.none, navigationBudget(96, true, "https", nowMs()));
}

/// Answer a reason-carrying log pull; the `intercept_log` shape
/// with the policy verdict per entry.
pub fn netLog(self: *Host, req: proto.NetLogReq) void {
    var snap: LogSnap = .{};
    snap.take(req.view, req.since, req.max);
    self.post(proto.NetLog{ .view = req.view, .next_seq = snap.next_seq, .entries = snap.rows[0..snap.n], .details = snap.details[0..snap.n] });
}

pub fn netPolicyFrame(view_id: u32) proto.EvNetPolicy {
    g_int.acquire();
    defer g_int.release();
    var out = proto.EvNetPolicy{
        .view = view_id,
        .serial = 0,
        .active = 0,
        .exhausted = 0,
        .requests = 0,
        .bytes = 0,
        .navigations = 0,
        .ms_left = 0,
        .denied = @splat(0),
    };
    for (&g_int.slots) |*s| {
        if (!s.used or s.view_id != view_id) continue;
        out.serial = if (s.pc.exhausted == .policy_refused) s.pol_failed_serial else if (s.pol) |pol| pol.serial else 0;
        out.active = if (s.pol != null and s.pc.exhausted != .policy_refused) 1 else 0;
        out.exhausted = @intFromEnum(s.pc.exhausted);
        out.requests = s.pc.requests;
        out.bytes = s.pc.bytes;
        out.navigations = s.pc.navigations;
        if (s.pol) |pol| {
            out.ms_left = if (pol.deadline_ms == 0)
                0
            else
                @intCast(std.math.clamp(@as(i64, pol.deadline_ms) - (nowMs() - s.pc.started_ms), 0, std.math.maxInt(u32)));
        }
        out.denied = s.pc.denied;
        break;
    }
    return out;
}

/// The deadline sweep + coalesced accounting push. Called once per
/// poll iteration next to `flushInterceptStatus`. A view whose
/// deadline ran out gets ONE `stop_load` (an in-flight streaming
/// body is invisible to the pre-request gate).
pub fn flushNetPolicy(self: *Host) void {
    var pending: [MAX_ISLOTS]proto.EvNetPolicy = undefined;
    var stops: [MAX_ISLOTS]u32 = undefined;
    var n: usize = 0;
    var nstops: usize = 0;
    const now = nowMs();
    {
        g_int.acquire();
        defer g_int.release();
        for (&g_int.slots) |*s| {
            if (!s.used) continue;
            const pol = s.pol orelse continue;
            if (pol.deadline_ms != 0 and now - s.pc.started_ms >= pol.deadline_ms and !s.deadline_stopped) {
                if (s.pc.exhausted == .none) s.pc.exhausted = .deadline;
                s.deadline_stopped = true;
                s.pol_dirty = true;
                stops[nstops] = s.view_id;
                nstops += 1;
            }
            if (!s.pol_dirty) continue;
            s.pol_dirty = false;
            pending[n] = .{
                .view = s.view_id,
                .serial = if (s.pc.exhausted == .policy_refused) s.pol_failed_serial else pol.serial,
                .active = if (s.pc.exhausted == .policy_refused) 0 else 1,
                .exhausted = @intFromEnum(s.pc.exhausted),
                .requests = s.pc.requests,
                .bytes = s.pc.bytes,
                .navigations = s.pc.navigations,
                .ms_left = if (pol.deadline_ms == 0)
                    0
                else
                    @intCast(std.math.clamp(@as(i64, pol.deadline_ms) - (now - s.pc.started_ms), 0, std.math.maxInt(u32))),
                .denied = s.pc.denied,
            };
            n += 1;
        }
    }
    for (stops[0..nstops]) |view_id| {
        const v = self.find(view_id) orelse continue;
        const b = v.browser orelse continue;
        if (b.stop_load) |f| f(b);
    }
    for (pending[0..n]) |ev| self.post(ev);
}

/// Push a coalesced `intercept_status` for every view whose
/// counters moved since the last flush. Called once per poll
/// iteration — a page issuing thousands of requests still costs at
/// most one status frame per iteration per view.
pub fn flushInterceptStatus(self: *Host) void {
    var pending: [MAX_ISLOTS]proto.InterceptStatus = undefined;
    var n: usize = 0;
    {
        g_int.acquire();
        defer g_int.release();
        for (&g_int.slots) |*s| {
            if (!s.used or !s.dirty) continue;
            s.dirty = false;
            pending[n] = .{
                .view = s.view_id,
                .enabled = if (g_int.global_enabled and s.enabled) 1 else 0,
                .rules = g_int.rules,
                .blocked = s.blocked,
                .total = s.total,
            };
            n += 1;
        }
    }
    for (pending[0..n]) |st| self.post(st);
}

// ── filter-list subscription ────────────────────────────────────
//
// The helper is the only process here with an HTTPS stack, so keeping a
// subscribed EasyList current happens in this file. A `cef_urlrequest`
// rather than a view: navigating a view to a `.txt` RENDERS it, and
// scraping a rendered document back out is neither exact nor bounded.
//
// The refcount rule is `CookieJob`'s and is not optional: CEF's CToCpp
// wrappers TRANSFER the request and client references and may drop the
// client before the create call even returns. The fetch is born with a
// CEF reference plus a Host reference that lasts through retirement.

/// A subscription fetch in flight. One per url; there is no queue,
/// because the set is small and CEF runs them concurrently anyway.
pub const FilterFetch = struct {
    client: cef.cef_urlrequest_client_t,
    refs: std.atomic.Value(u32) = .init(1),
    gpa: std.mem.Allocator,
    body: std.ArrayList(u8) = .empty,
    request: ?*cef.cef_urlrequest_t = null,
    dest: []u8,
    url: []u8,
    serial: u32,
    status_ok: bool = false,
    response_ok: bool = false,
    completed: bool = false,
    /// Set when an append failed: a truncated list must never be
    /// written, because half a filter list is a working filter list
    /// that silently stops blocking half of what it used to.
    lost: bool = false,
    /// A userscript `GM_xmlhttpRequest` riding the same URLRequest
    /// machinery (same two-reference rule): the page view and the
    /// script's request id to answer, and the response to answer with.
    gm: bool = false,
    gm_view: u32 = 0,
    gm_req: u32 = 0,
    status_code: i32 = 0,
    status_text: []u8 = &.{},
    resp_headers: []u8 = &.{},

    pub fn destroyOwned(self: *FilterFetch) void {
        if (self.status_text.len != 0) self.gpa.free(self.status_text);
        if (self.resp_headers.len != 0) self.gpa.free(self.resp_headers);
        self.body.deinit(self.gpa);
        self.gpa.free(self.dest);
        self.gpa.free(self.url);
        self.gpa.destroy(self);
    }
};

pub fn warnSub(what: []const u8, url: []const u8) void {
    std.debug.print("sketerm-web: filter list {s}: {s}\n", .{ url, what });
}

pub const SubRef = HeapRef(FilterFetch, "client");

pub fn subOnDownloadData(
    self_: [*c]cef.cef_urlrequest_client_t,
    request: [*c]cef.cef_urlrequest_t,
    data: ?*const anyopaque,
    len: usize,
) callconv(.c) void {
    defer releaseArg(request);
    const f: *FilterFetch = SubRef.owner(@ptrCast(self_));
    if (f.lost or len == 0) return;
    // A list that grows past this is not a list we want to load either;
    // `interceptReload` reads at most 16MB back off disk.
    if (len > filter_list_max or f.body.items.len > filter_list_max - len) {
        f.lost = true;
        if (request) |r| {
            if (r.*.cancel) |cancel| cancel(r);
        }
        return;
    }
    const bytes: [*]const u8 = @ptrCast(data orelse return);
    f.body.appendSlice(f.gpa, bytes[0..len]) catch {
        f.lost = true;
    };
}

pub fn subOnComplete(
    self_: [*c]cef.cef_urlrequest_client_t,
    request: [*c]cef.cef_urlrequest_t,
) callconv(.c) void {
    defer releaseArg(request);
    const f: *FilterFetch = SubRef.owner(@ptrCast(self_));
    f.status_ok = false;
    f.response_ok = false;
    if (request) |r| {
        const st = if (r.*.get_request_status) |g| g(r) else @as(cef.cef_urlrequest_status_t, @intCast(cef.UR_FAILED));
        f.status_ok = st == @as(cef.cef_urlrequest_status_t, @intCast(cef.UR_SUCCESS));
        if (r.*.get_response) |gr| {
            if (gr(r)) |resp| {
                defer release(&resp.*.base);
                const code = if (resp.*.get_status) |gs| gs(resp) else 0;
                f.response_ok = code >= 200 and code < 300;
                if (f.gm) gmCaptureResponse(f, resp, code);
            }
        }
    }
    // Host.filterSubPump retires this after the callback returns. The
    // Host reference keeps it alive if CEF releases immediately.
    f.completed = true;
}

pub fn subOnUploadProgress(_: [*c]cef.cef_urlrequest_client_t, request: [*c]cef.cef_urlrequest_t, _: i64, _: i64) callconv(.c) void {
    releaseArg(request);
}
pub fn subOnDownloadProgress(
    self_: [*c]cef.cef_urlrequest_client_t,
    request: [*c]cef.cef_urlrequest_t,
    _: i64,
    total: i64,
) callconv(.c) void {
    defer releaseArg(request);
    if (total <= filter_list_max) return;
    const f: *FilterFetch = SubRef.owner(@ptrCast(self_));
    f.lost = true;
    if (request) |r| {
        if (r.*.cancel) |cancel| cancel(r);
    }
}
pub fn subGetAuthCredentials(
    _: [*c]cef.cef_urlrequest_client_t,
    _: c_int,
    _: [*c]const cef.cef_string_t,
    _: c_int,
    _: [*c]const cef.cef_string_t,
    _: [*c]const cef.cef_string_t,
    callback: [*c]cef.cef_auth_callback_t,
) callconv(.c) c_int {
    // Never authenticate to a filter-list host: a subscription is a
    // public url, and a prompt here has no user to answer it.
    releaseArg(callback);
    return 0;
}

/// Start one fetch. Returns false when nothing was started.
pub fn filterSubFetch(host: *Host, url: []const u8, dest: []const u8, serial: u32) bool {
    // A browserless request rides the global context: on a refused
    // route it would leave outside it, so it is never started (the
    // previous copy of the list keeps blocking, as for any failure).
    if (host.route_refusal.len != 0) return false;
    // `cef_request_create` is a plain extern fn here, not an optional
    // function pointer like the struct members are.
    const req = cef.cef_request_create() orelse return false;
    var request_transferred = false;
    defer if (!request_transferred) release(&req.*.base);

    var u = std.mem.zeroes(cef.cef_string_t);
    setStr(url, &u);
    defer cef.cef_string_utf16_clear(&u);
    if (req.*.set_url) |set| set(req, &u);
    var method = std.mem.zeroes(cef.cef_string_t);
    setStr("GET", &method);
    defer cef.cef_string_utf16_clear(&method);
    if (req.*.set_method) |set| set(req, &method);
    if (req.*.set_flags) |set| set(req, cef.UR_FLAG_DISABLE_CACHE | cef.UR_FLAG_NO_RETRY_ON_5XX);

    host.filter_fetches.ensureUnusedCapacity(host.gpa, 1) catch return false;
    const f = host.gpa.create(FilterFetch) catch return false;
    const dest_owned = host.gpa.dupe(u8, dest) catch {
        host.gpa.destroy(f);
        return false;
    };
    const url_owned = host.gpa.dupe(u8, url) catch {
        host.gpa.free(dest_owned);
        host.gpa.destroy(f);
        return false;
    };
    f.* = .{
        .client = .{
            .base = SubRef.base(),
            .on_request_complete = subOnComplete,
            .on_upload_progress = subOnUploadProgress,
            .on_download_progress = subOnDownloadProgress,
            .on_download_data = subOnDownloadData,
            .get_auth_credentials = subGetAuthCredentials,
        },
        .gpa = host.gpa,
        .dest = dest_owned,
        .url = url_owned,
        .serial = serial,
    };

    // CEF consumes one reference and may release it before returning;
    // the Host owns the other until the next-loop retirement. The
    // request object is consumed by the same CToCpp wrapper too.
    f.refs.store(2, .release);
    request_transferred = true;
    const handle = cef.cef_urlrequest_create(req, &f.client, null);
    if (handle) |h| {
        f.request = h;
        host.filter_fetches.appendAssumeCapacity(f);
        return true;
    }
    _ = SubRef.release(&f.client.base);
    return false;
}

pub const filter_list_max: usize = 16 * 1024 * 1024;

/// Keep what a `GM_xmlhttpRequest` answer needs from the response: the
/// status line and the headers as `Name: value\r\n` lines (the shape
/// `responseHeaders` has in every userscript manager).
pub fn gmCaptureResponse(f: *FilterFetch, resp: *cef.cef_response_t, code: i32) void {
    f.status_code = code;
    var tb: [256]u8 = undefined;
    const text = if (resp.get_status_text) |gt| userfreeInto(gt(resp), &tb) else "";
    f.status_text = f.gpa.dupe(u8, text) catch &.{};
    const gh = resp.get_header_map orelse return;
    const map = cef.cef_string_multimap_alloc() orelse return;
    defer cef.cef_string_multimap_free(map);
    gh(resp, map);
    var out: std.ArrayList(u8) = .empty;
    const n = cef.cef_string_multimap_size(map);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var key = std.mem.zeroes(cef.cef_string_t);
        var val = std.mem.zeroes(cef.cef_string_t);
        defer cef.cef_string_utf16_clear(&key);
        defer cef.cef_string_utf16_clear(&val);
        if (cef.cef_string_multimap_key(map, i, &key) == 0) continue;
        _ = cef.cef_string_multimap_value(map, i, &val);
        var kbuf: [256]u8 = undefined;
        var vbuf: [2048]u8 = undefined;
        out.print(f.gpa, "{s}: {s}\r\n", .{ utf16Into(&key, &kbuf), utf16Into(&val, &vbuf) }) catch break;
    }
    f.resp_headers = out.toOwnedSlice(f.gpa) catch &.{};
}

/// Start one `GM_xmlhttpRequest` through the PAGE VIEW's request
/// context, so it carries that page's cookies and leaves by its route.
/// Returns false when nothing was started (the caller answers).
pub fn gmXhrStart(host: *Host, v: *View, req_id: u32, url: []const u8, method: []const u8, headers: std.json.Value, data: ?[]const u8) bool {
    if (host.route_refusal.len != 0) return false;
    const req = cef.cef_request_create() orelse return false;
    var request_transferred = false;
    defer if (!request_transferred) release(&req.*.base);
    var u = std.mem.zeroes(cef.cef_string_t);
    setStr(url, &u);
    defer cef.cef_string_utf16_clear(&u);
    if (req.*.set_url) |set| set(req, &u);
    var m = std.mem.zeroes(cef.cef_string_t);
    setStr(if (method.len == 0) "GET" else method, &m);
    defer cef.cef_string_utf16_clear(&m);
    if (req.*.set_method) |set| set(req, &m);
    if (req.*.set_flags) |set| set(req, cef.UR_FLAG_ALLOW_STORED_CREDENTIALS);
    if (headers == .object) {
        var it = headers.object.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.* != .string) continue;
            var nk = std.mem.zeroes(cef.cef_string_t);
            var nv = std.mem.zeroes(cef.cef_string_t);
            setStr(kv.key_ptr.*, &nk);
            setStr(kv.value_ptr.*.string, &nv);
            defer cef.cef_string_utf16_clear(&nk);
            defer cef.cef_string_utf16_clear(&nv);
            if (req.*.set_header_by_name) |seth| seth(req, &nk, &nv, 1);
        }
    }
    if (data) |body| if (body.len != 0) {
        const pd = cef.cef_post_data_create() orelse return false;
        const el = cef.cef_post_data_element_create() orelse {
            release(&pd.*.base);
            return false;
        };
        if (el.*.set_to_bytes) |stb| stb(el, body.len, body.ptr);
        // Both are CONSUMED by the calls they are passed to.
        if (pd.*.add_element) |ae| _ = ae(pd, el) else release(&el.*.base);
        if (req.*.set_post_data) |spd| spd(req, pd) else release(&pd.*.base);
    };

    host.filter_fetches.ensureUnusedCapacity(host.gpa, 1) catch return false;
    const f = host.gpa.create(FilterFetch) catch return false;
    const dest_owned = host.gpa.dupe(u8, "") catch {
        host.gpa.destroy(f);
        return false;
    };
    const url_owned = host.gpa.dupe(u8, url) catch {
        host.gpa.free(dest_owned);
        host.gpa.destroy(f);
        return false;
    };
    f.* = .{
        .client = .{
            .base = SubRef.base(),
            .on_request_complete = subOnComplete,
            .on_upload_progress = subOnUploadProgress,
            .on_download_progress = subOnDownloadProgress,
            .on_download_data = subOnDownloadData,
            .get_auth_credentials = subGetAuthCredentials,
        },
        .gpa = host.gpa,
        .dest = dest_owned,
        .url = url_owned,
        .serial = 0,
        .gm = true,
        .gm_view = v.id,
        .gm_req = req_id,
    };
    // The page's context: the returned reference is ours and the create
    // call CONSUMES it (CToCpp transfers), exactly like the request.
    var rc: ?*cef.cef_request_context_t = null;
    if (browserHost(v)) |bh| {
        defer release(&bh.base);
        if (bh.get_request_context) |grc| rc = grc(bh);
    }
    f.refs.store(2, .release);
    request_transferred = true;
    const handle = cef.cef_urlrequest_create(req, &f.client, rc);
    if (handle) |h| {
        f.request = h;
        host.filter_fetches.appendAssumeCapacity(f);
        return true;
    }
    _ = SubRef.release(&f.client.base);
    return false;
}

pub fn subRules() u32 {
    g_int.acquire();
    defer g_int.release();
    return g_int.rules;
}

pub fn subIntervalMs(hours: u32) i64 {
    if (hours == 0) return std.math.maxInt(i64);
    return @as(i64, hours) * 3_600_000;
}

pub fn ensureFiltersDir(dir: [:0]const u8) bool {
    pathz.makeDirs(dir, 0o700) catch return false;
    return true;
}

pub fn subUrlWanted(urls: []const []u8, name: []const u8) bool {
    for (urls) |u| {
        var nb: [filtersub.MAX_NAME]u8 = undefined;
        const want = filtersub.cacheName(u, &nb) catch continue;
        if (std.mem.eql(u8, want, name)) return true;
    }
    return false;
}

pub fn filterSubApply(self: *Host, hours: u32, urls: []const []const u8) void {
    var next: std.ArrayList([]u8) = .empty;
    var adopted = false;
    defer if (!adopted) {
        for (next.items) |u| self.gpa.free(u);
        next.deinit(self.gpa);
    };
    var invalid: u16 = 0;
    for (urls) |u| {
        if (!filtersub.validUrl(u)) {
            invalid +|= 1;
            continue;
        }
        var duplicate = false;
        for (next.items) |have| {
            if (std.mem.eql(u8, have, u)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) continue;
        const dup = self.gpa.dupe(u8, u) catch {
            filterSubFailAll(self, urls.len);
            return;
        };
        next.append(self.gpa, dup) catch {
            self.gpa.free(dup);
            filterSubFailAll(self, urls.len);
            return;
        };
    }

    filterSubCancel(self);
    for (self.filter_sub_urls.items) |u| self.gpa.free(u);
    self.filter_sub_urls.deinit(self.gpa);
    self.filter_sub_urls = next;
    adopted = true;
    self.filter_sub_hours = hours;
    self.filter_sub_serial +%= 1;
    if (self.filter_sub_serial == 0) self.filter_sub_serial = 1;
    self.filter_sub_active = @intCast(self.filter_sub_urls.items.len);
    self.filter_sub_fetched = 0;
    self.filter_sub_updated = 0;
    self.filter_sub_failed = invalid;
    self.filter_sub_pending = 0;
    self.filter_sub_reload = false;
    self.filter_sub_batch_open = true;
    filterSubReconcile(self);
}

/// Answer a replace-all whose owned url copies could not be allocated:
/// the previous subscription set and schedule stay live, but the
/// completion frame is still posted (every request is answered) with
/// every requested url counted as failed.
pub fn filterSubFailAll(self: *Host, requested: usize) void {
    filterSubCancel(self);
    self.filter_sub_serial +%= 1;
    if (self.filter_sub_serial == 0) self.filter_sub_serial = 1;
    self.filter_sub_active = @intCast(@min(requested, std.math.maxInt(u16)));
    self.filter_sub_fetched = 0;
    self.filter_sub_updated = 0;
    self.filter_sub_failed = self.filter_sub_active;
    self.filter_sub_pending = 0;
    self.filter_sub_reload = false;
    self.filter_sub_batch_open = true;
    filterSubFinish(self, nowMs());
}

pub fn filterSubReconcile(self: *Host) void {
    var dir_buf: [4096]u8 = undefined;
    const dir = filtersDir(&dir_buf) orelse {
        self.filter_sub_failed +|= self.filter_sub_active;
        filterSubFinish(self, nowMs());
        return;
    };
    if (self.filter_sub_urls.items.len != 0 and !ensureFiltersDir(dir)) {
        self.filter_sub_failed +|= self.filter_sub_active;
        filterSubFinish(self, nowMs());
        return;
    }

    // Drop the caches of subscriptions that went away. Only ever OUR
    // exact cache/stage names, never a similarly-prefixed user file.
    if (c.opendir(dir.ptr)) |dp| {
        defer _ = c.closedir(dp);
        while (c.readdir(dp)) |entp| {
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entp.*.d_name)));
            const staged = filtersub.stageCacheName(name);
            const cache_name = staged orelse
                (if (filtersub.isCacheName(name)) name else continue);
            // A stage is always an orphan: the writer renames its own.
            if (staged == null and subUrlWanted(self.filter_sub_urls.items, cache_name)) continue;
            var p_buf: [4352:0]u8 = undefined;
            const p = std.fmt.bufPrintZ(&p_buf, "{s}/{s}", .{ dir, name }) catch continue;
            if (c.unlink(p.ptr) == 0 and filtersub.isCacheName(name)) self.filter_sub_reload = true;
        }
    }

    const now: i64 = @intCast(c.time(null));
    for (self.filter_sub_urls.items) |u| {
        var nb: [filtersub.MAX_NAME]u8 = undefined;
        const name = filtersub.cacheName(u, &nb) catch continue;
        var p_buf: [4352:0]u8 = undefined;
        const path = std.fmt.bufPrintZ(&p_buf, "{s}/{s}", .{ dir, name }) catch continue;
        var st: c.struct_stat = undefined;
        // Darwin spells it st_mtimespec; the same @hasField idiom guards
        // every other stat site in the repo, and this was the one that
        // would have blocked a macOS build of the helper.
        const mtime: i64 = if (c.stat(path.ptr, &st) == 0)
            @intCast((if (@hasField(c.struct_stat, "st_mtim")) st.st_mtim else st.st_mtimespec).tv_sec)
        else
            0;
        // A missing file is always due, whatever the interval says --
        // otherwise `filter_update_hours = 0` would mean "subscribe to
        // this and never actually get it".
        if (mtime != 0 and !filtersub.isStale(now, mtime, self.filter_sub_hours)) continue;
        self.filter_sub_fetched +|= 1;
        if (filterSubFetch(self, u, path, self.filter_sub_serial)) {
            self.filter_sub_pending +|= 1;
        } else {
            self.filter_sub_failed +|= 1;
        }
    }
    if (self.filter_sub_pending == 0) filterSubFinish(self, nowMs());
}

pub fn filterSubFinish(self: *Host, now_ms: i64) void {
    if (!self.filter_sub_batch_open) return;
    if (self.filter_sub_reload and !interceptReload(self.gpa, self.intercept_extra.items)) self.filter_sub_failed +|= 1;
    self.filter_sub_batch_open = false;
    self.filter_sub_next_ms = if (self.filter_sub_stopping)
        std.math.maxInt(i64)
    else
        now_ms +| subIntervalMs(self.filter_sub_hours);
    self.post(proto.EvInterceptSubscribeDone{
        .serial = self.filter_sub_serial,
        .active = self.filter_sub_active,
        .fetched = self.filter_sub_fetched,
        .updated = self.filter_sub_updated,
        .failed = self.filter_sub_failed,
        .rules = subRules(),
    });
}

pub fn filterSubPump(self: *Host, now_ms: i64) void {
    var i: usize = 0;
    while (i < self.filter_fetches.items.len) {
        const f = self.filter_fetches.items[i];
        if (!f.completed) {
            i += 1;
            continue;
        }
        if (f.gm) {
            if (self.find(f.gm_view)) |v| {
                if (f.status_ok and !f.lost) {
                    self.usXhrReply(v, f.gm_req, f.status_code, f.status_text, f.resp_headers, f.body.items, f.url, "");
                } else {
                    self.usXhrReply(v, f.gm_req, f.status_code, f.status_text, f.resp_headers, "", f.url, "network error");
                }
            }
            retireFilterFetch(self, i);
            continue;
        }
        const current = self.filter_sub_batch_open and f.serial == self.filter_sub_serial;
        if (current) {
            if (self.filter_sub_pending > 0) self.filter_sub_pending -= 1;
            if (!f.lost and f.status_ok and f.response_ok and filtersub.looksLikeFilterList(f.body.items)) {
                atomicwrite.writeFile(f.dest, f.body.items, 0o600) catch {
                    warnSub("could not be written; keeping the previous copy", f.url);
                    self.filter_sub_failed +|= 1;
                    retireFilterFetch(self, i);
                    continue;
                };
                self.filter_sub_updated +|= 1;
                self.filter_sub_reload = true;
            } else {
                warnSub("fetch failed or returned an invalid list; keeping the previous copy", f.url);
                self.filter_sub_failed +|= 1;
            }
        }
        retireFilterFetch(self, i);
    }
    if (self.filter_sub_batch_open and self.filter_sub_pending == 0) filterSubFinish(self, now_ms);
}

pub fn retireFilterFetch(self: *Host, i: usize) void {
    const f = self.filter_fetches.swapRemove(i);
    if (f.request) |r| release(&r.base);
    f.request = null;
    _ = SubRef.release(&f.client.base);
}

pub fn filterSubCancel(self: *Host) void {
    for (self.filter_fetches.items) |f| {
        if (f.request) |r| {
            if (r.cancel) |cancel| cancel(r);
        }
    }
    self.filter_sub_batch_open = false;
    self.filter_sub_pending = 0;
}

pub fn filterSubTick(self: *Host, now_ms: i64) void {
    if (self.filter_sub_stopping or self.filter_sub_batch_open or self.filter_sub_hours == 0 or now_ms < self.filter_sub_next_ms) return;
    self.filter_sub_serial +%= 1;
    if (self.filter_sub_serial == 0) self.filter_sub_serial = 1;
    self.filter_sub_active = @intCast(self.filter_sub_urls.items.len);
    self.filter_sub_fetched = 0;
    self.filter_sub_updated = 0;
    self.filter_sub_failed = 0;
    self.filter_sub_pending = 0;
    self.filter_sub_reload = false;
    self.filter_sub_batch_open = true;
    filterSubReconcile(self);
}

pub fn filterSubShutdown(self: *Host) void {
    self.filter_sub_stopping = true;
    filterSubCancel(self);
}

pub fn filterSubBusy(self: *const Host) bool {
    return self.filter_fetches.items.len != 0;
}

pub fn filterSubAbandon(self: *Host) void {
    filterSubShutdown(self);
    while (self.filter_fetches.items.len != 0) {
        const f = self.filter_fetches.pop().?;
        if (f.request) |r| release(&r.base);
        f.request = null;
        _ = SubRef.release(&f.client.base);
    }
}

pub const JobRef = HeapRef(CookieJob, "visitor");

pub fn jobVisit(
    self_: [*c]cef.cef_cookie_visitor_t,
    cookie: [*c]const cef.cef_cookie_t,
    count: c_int,
    total: c_int,
    delete_cookie: [*c]c_int,
) callconv(.c) c_int {
    _ = count;
    _ = total;
    if (self_ == null or cookie == null) return 0;
    const vis: *cef.cef_cookie_visitor_t = @ptrCast(self_);
    const job: *CookieJob = @fieldParentPtr("visitor", vis);
    const ck: *const cef.cef_cookie_t = @ptrCast(cookie);
    job.total += 1;
    switch (job.mode) {
        .list => job.record(ck),
        .delete_all => {
            if (delete_cookie != null) delete_cookie.* = 1;
            job.removed += 1;
        },
        .delete_named => {
            if (job.matches(ck)) {
                if (delete_cookie != null) delete_cookie.* = 1;
                job.removed += 1;
            }
        },
    }
    return 1;
}

// ---------------------------------------------------------------------
// Request interception (capability "intercept")
// ---------------------------------------------------------------------
//
// THE ONE EXCEPTION to this file's single-thread story: CEF delivers
// `on_before_resource_load` / `on_resource_load_complete` on its IO
// THREAD, not inside `pump()`. That is also the whole point — a
// blocking verdict must not round-trip anywhere (uBO's lesson: cross-
// process blocking latency is the hard part), so the filter engine
// lives in this process and the verdict is computed inline where the
// request already is. Everything the IO thread touches lives in the
// `g_int` registry below, guarded by the repo's spinlock pattern
// (src/ui/panel/events.zig documents why a spinlock and not a mutex),
// and NOTHING in it allocates on the IO thread: log entries are
// fixed-size, appended into per-view rings the MAIN thread allocated.
// The main thread only ever swaps whole engines / registers slots
// under the same lock. Host.views is never read from the IO thread.

/// Built-in seed list: a handful of universally safe ad/tracker hosts,
/// so blocking demonstrably works with zero setup. Typeless rules, so
/// none of them can ever block a top-level navigation.
pub const seed_filter_list =
    \\! sketerm built-in seed filters (ad/tracker hosts)
    \\||doubleclick.net^
    \\||googlesyndication.com^
    \\||googleadservices.com^
    \\||google-analytics.com^
    \\||adservice.google.com^
    \\||googletagservices.com^
    \\||scorecardresearch.com^
    \\||quantserve.com^
    \\||taboola.com^
    \\||outbrain.com^
    \\||criteo.com^
    \\||adnxs.com^
    \\||hotjar.com^$third-party
    \\
;

/// Log-ring depth per view. At ~300 bytes per entry a view costs
/// ~38KB, allocated only while the view lives.
pub const NLOG = 128;

/// Main-document rows per view kept out of the ring's overwrite order.
pub const DOC_PINS = 8;

/// Concurrent views the registry can track. A view past the cap still
/// gets verdicts (global engine + global enable), just no log/badge —
/// and can hold no POLICY, which is why the client refuses a policied
/// open past it (the constant is wire-adjacent and lives in protocol).
pub const MAX_ISLOTS = proto.MAX_POLICY_VIEWS;

/// Longest URL kept in a log entry; the tail is truncated, the
/// VERDICT always sees the full url.
pub const LOG_URL_MAX = 256;
/// Longest content type / status text a log entry keeps (`net-log-detail`).
pub const LOG_MIME_MAX = 64;
pub const LOG_STEXT_MAX = 48;

pub const LogEntry = struct {
    seq: u32 = 0,
    req_id: u64 = 0,
    start_ms: i64 = 0,
    dur_ms: u32 = 0,
    status: u16 = 0,
    size: u32 = 0,
    rtype: u8 = 0,
    blocked: bool = false,
    done: bool = false,
    /// `proto.NetReason` byte; nonzero only on blocked entries.
    reason: u8 = 0,
    /// This hop ended in a server redirect (`done` with the redirect's
    /// status); `continued` once the next hop's entry names it.
    redirect: bool = false,
    continued: bool = false,
    /// Net error the load ended with; 0 = none.
    err: i32 = 0,
    /// Seq of the hop this one continues; 0 = the request's first.
    prev_seq: u32 = 0,
    method_len: u8 = 0,
    method: [8]u8 = @splat(0),
    url_len: u16 = 0,
    url: [LOG_URL_MAX]u8 = @splat(0),
    mime_len: u8 = 0,
    mime: [LOG_MIME_MAX]u8 = @splat(0),
    stext_len: u8 = 0,
    stext: [LOG_STEXT_MAX]u8 = @splat(0),

    fn setResponse(e: *LogEntry, status: u16, mime: []const u8, stext: []const u8) void {
        if (status != 0) e.status = status;
        if (mime.len > 0) {
            e.mime_len = @intCast(@min(mime.len, LOG_MIME_MAX));
            @memcpy(e.mime[0..e.mime_len], mime[0..e.mime_len]);
        }
        if (stext.len > 0) {
            e.stext_len = @intCast(@min(stext.len, LOG_STEXT_MAX));
            @memcpy(e.stext[0..e.stext_len], stext[0..e.stext_len]);
        }
    }
};

/// Under the lock. The entry a request with `req_id` is currently on:
/// its newest entry while that is still open, or ended in a redirect no
/// later hop has taken up yet. CEF keeps the request identifier across a
/// server redirect chain (measured on CEF 151), so a re-entry of
/// `on_before_resource_load` that finds one IS the redirected re-issue.
fn hopOf(ring: *[NLOG]LogEntry, req_id: u64) ?*LogEntry {
    var best: ?*LogEntry = null;
    for (ring) |*e| {
        if (e.seq == 0 or e.req_id != req_id) continue;
        if (best == null or e.seq > best.?.seq) best = e;
    }
    const e = best orelse return null;
    if (e.blocked) return null;
    if (!e.done or (e.redirect and !e.continued)) return e;
    return null;
}

/// Under the lock. The newest still-open entry of `req_id`, the one a
/// response or completion belongs to (a redirect chain leaves several
/// entries with the same id; the OLDEST is long finished).
fn openEntry(ring: *[NLOG]LogEntry, req_id: u64) ?*LogEntry {
    var best: ?*LogEntry = null;
    for (ring) |*e| {
        if (e.seq == 0 or e.req_id != req_id or e.done) continue;
        if (best == null or e.seq > best.?.seq) best = e;
    }
    return best;
}

pub const ISlot = struct {
    used: bool = false,
    cef_id: c_int = 0,
    view_id: u32 = 0,
    enabled: bool = true,
    blocked: u32 = 0,
    total: u32 = 0,
    /// Counters changed since the last pushed `intercept_status`; the
    /// poll loop flushes at most one frame per view per iteration, so
    /// an ad-heavy page cannot stream a frame per request.
    dirty: bool = false,
    next_seq: u32 = 1,
    widx: usize = 0,
    ring: ?*[NLOG]LogEntry = null,
    /// Seqs of the newest main-document rows, which the ring never
    /// overwrites (`logRequest`): a navigation's own row must outlive the
    /// hundreds of subresources a busy page loads after it, or a client
    /// reading what the navigation produced finds nothing.
    docs: [DOC_PINS]u32 = @splat(0),
    docs_w: usize = 0,
    /// Enforced policy, or null (the common case: one branch on the hot
    /// path and nothing else). Swapped whole by the MAIN thread under
    /// the lock, freed outside it, like the filter engine.
    pol: ?*netpolicy.Policy = null,
    pol_failed_serial: u32 = 0,
    /// Live accounting shared by UI-thread navigation preflight and the IO-thread resource gate.
    pc: netpolicy.Counters = .{},
    /// Accounting changed since the last pushed `ev_net_policy`.
    pol_dirty: bool = false,
    /// The deadline sweep already issued its one `stop_load`.
    deadline_stopped: bool = false,
    /// Response-body capture (`cefhost/capture.zig`), or null. The slot
    /// owns one reference; the IO thread takes its own under the lock
    /// before using it outside, so a reinstall or unregister never frees
    /// a store a callback is still writing into.
    cap: ?*capture.Store = null,
    /// `ViewCreateUrl.FLAG_NO_REDIRECT`: a main-frame redirect hop is
    /// refused (`redirect_refused`) instead of followed.
    no_redirect: bool = false,
};

pub const Intercept = struct {
    lock: SpinLock = .{},
    engine: ?*filter.Engine = null,
    /// IO-thread matches in flight against `engine` OUTSIDE the lock
    /// (`pinEngine`/`unpinEngine`). A match is a linear scan over tens
    /// of thousands of rules, far too long for a spinlock the main
    /// thread spins on, so the reader pins the engine and walks it
    /// unlocked; `retireEngine` waits for the pins to drain before
    /// freeing a swapped-out engine.
    readers: u32 = 0,
    global_enabled: bool = true,
    /// Last resort: a policy could be neither installed nor remembered as
    /// refused, so no request of this helper may proceed.
    policy_failed: bool = false,
    rules: u32 = 0,
    slots: [MAX_ISLOTS]ISlot = @splat(.{}),
    /// Views refused a policy because `slots` was full (0 = free entry);
    /// forgotten when the view id is destroyed.
    refused_views: [MAX_ISLOTS]u32 = @splat(0),

    /// Under the lock. False when the refusal list itself is full.
    fn refuseView(self: *Intercept, view: u32) bool {
        for (self.refused_views) |id| if (id == view) return true;
        for (&self.refused_views) |*id| if (id.* == 0) {
            id.* = view;
            return true;
        };
        return false;
    }

    pub fn acquire(self: *Intercept) void {
        self.lock.lock();
    }

    pub fn release(self: *Intercept) void {
        self.lock.unlock();
    }

    /// The slot registered for a CEF browser id. Under the lock.
    pub fn slotByCef(self: *Intercept, cef_id: c_int) ?*ISlot {
        for (&self.slots) |*s| {
            if (s.used and s.cef_id == cef_id) return s;
        }
        return null;
    }

    /// Under the lock: the current engine, pinned so that a concurrent
    /// swap cannot free it until `unpinEngine`.
    fn pinEngine(self: *Intercept) ?*filter.Engine {
        const e = self.engine orelse return null;
        self.readers += 1;
        return e;
    }

    /// Takes the lock itself; never call while holding it.
    fn unpinEngine(self: *Intercept) void {
        self.acquire();
        defer self.release();
        self.readers -= 1;
    }

    /// Free an engine taken out of `engine` once no pinned reader can
    /// still be walking it. NOT under the lock: it waits for the IO
    /// thread's in-flight matches, which is bounded CPU work, and the
    /// wait must not block those readers' own `unpinEngine`.
    fn retireEngine(self: *Intercept, gpa: std.mem.Allocator, old: *filter.Engine) void {
        while (true) {
            self.acquire();
            const busy = self.readers != 0;
            self.release();
            if (!busy) break;
            std.atomic.spinLoopHint();
        }
        old.deinit();
        gpa.destroy(old);
    }
};

pub var g_int: Intercept = .{};

/// Register a view in the intercept registry (main thread; idempotent
/// per view id — `onAfterCreated` and `createViewAt` both call it, so
/// a load racing `create_browser_sync`'s return is still attributed).
pub fn interceptRegister(gpa: std.mem.Allocator, view_id: u32, cef_id: c_int) void {
    if (cef_id == 0) return;
    const ring = gpa.create([NLOG]LogEntry) catch null;
    if (ring) |r| r.* = @splat(.{});
    var keep = false;
    defer if (!keep) if (ring) |r| gpa.destroy(r);
    g_int.acquire();
    defer g_int.release();
    var free_slot: ?*ISlot = null;
    for (&g_int.slots) |*s| {
        if (s.used and s.view_id == view_id) {
            // Adopt a slot minted by a pre-create `net_policy_set` /
            // `intercept_set`: attach the missing ring instead of
            // leaving the view logless.
            s.cef_id = cef_id;
            if (s.ring == null) {
                s.ring = ring;
                keep = true;
            }
            return;
        }
        if (!s.used and free_slot == null) free_slot = s;
    }
    const s = free_slot orelse return;
    s.* = .{ .used = true, .cef_id = cef_id, .view_id = view_id, .ring = ring };
    keep = true;
}

/// MAIN thread. The slot for `view_id`, found or created (ring
/// included, `cef_id` 0 until `interceptRegister` attributes it). Slot
/// lifecycle is main-thread-only — the IO thread only ever READS the
/// table — so the returned pointer stays valid; mutate its fields under
/// the lock.
pub fn interceptSlotFor(gpa: std.mem.Allocator, view_id: u32) ?*ISlot {
    {
        g_int.acquire();
        defer g_int.release();
        for (&g_int.slots) |*s| {
            if (s.used and s.view_id == view_id) return s;
        }
    }
    const ring = gpa.create([NLOG]LogEntry) catch return null;
    ring.* = @splat(.{});
    var keep = false;
    defer if (!keep) gpa.destroy(ring);
    g_int.acquire();
    defer g_int.release();
    var free_slot: ?*ISlot = null;
    for (&g_int.slots) |*s| {
        if (s.used and s.view_id == view_id) return s;
        if (!s.used and free_slot == null) free_slot = s;
    }
    const s = free_slot orelse return null;
    s.* = .{ .used = true, .cef_id = 0, .view_id = view_id, .ring = ring };
    keep = true;
    return s;
}

/// MAIN thread. Mark `view_id`'s slot (minted now when missing) to
/// refuse main-frame redirects. False when the table is full.
pub fn refuseRedirects(gpa: std.mem.Allocator, view_id: u32) bool {
    const s = interceptSlotFor(gpa, view_id) orelse return false;
    g_int.acquire();
    defer g_int.release();
    s.no_redirect = true;
    return true;
}

pub fn interceptUnregister(gpa: std.mem.Allocator, view_id: u32) void {
    var ring: ?*[NLOG]LogEntry = null;
    var pol: ?*netpolicy.Policy = null;
    var cap: ?*capture.Store = null;
    {
        g_int.acquire();
        defer g_int.release();
        for (&g_int.refused_views) |*id| if (id.* == view_id) {
            id.* = 0;
        };
        for (&g_int.slots) |*s| {
            if (!s.used or s.view_id != view_id) continue;
            ring = s.ring;
            pol = s.pol;
            cap = s.cap;
            s.* = .{};
            break;
        }
    }
    // Freed OUTSIDE the lock: nobody can reach them any more, and the
    // IO thread re-resolves its slot on every callback.
    if (ring) |r| gpa.destroy(r);
    if (pol) |p| p.deinit(gpa);
    if (cap) |s| s.release();
}

/// Read one file whole (bounded); caller frees.
pub fn readFileBounded(gpa: std.mem.Allocator, path: [*:0]const u8, max: usize) ?[]u8 {
    return readFileBoundedAlloc(gpa, path, max) catch null;
}

/// Error-returning so the `errdefer` runs. As a `?[]u8` body, a read
/// error or an over-cap file returned null with the partial read still
/// on the heap.
pub fn readFileBoundedAlloc(gpa: std.mem.Allocator, path: [*:0]const u8, max: usize) ![]u8 {
    const f = c.fopen(path, "rb") orelse return error.OpenFailed;
    defer _ = c.fclose(f);
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = c.fread(&buf, 1, buf.len, f);
        if (n == 0) {
            if (c.ferror(f) != 0) return error.ReadFailed;
            break;
        }
        if (n > max -| list.items.len) return error.StreamTooLong;
        try list.appendSlice(gpa, buf[0..n]);
    }
    return list.toOwnedSlice(gpa);
}

/// $XDG_CONFIG_HOME/sketerm/filters (or ~/.config/...), NUL-terminated
/// into `buf`.
pub fn filtersDir(buf: []u8) ?[:0]const u8 {
    if (c.getenv("XDG_CONFIG_HOME")) |xdg| {
        const base = std.mem.span(xdg);
        if (base.len != 0)
            return std.fmt.bufPrintZ(buf, "{s}/sketerm/filters", .{base}) catch null;
    }
    const home = c.getenv("HOME") orelse return null;
    return std.fmt.bufPrintZ(buf, "{s}/.config/sketerm/filters", .{std.mem.span(home)}) catch null;
}

/// Build a fresh engine from the seed list, every *.txt in the config
/// filters dir, and `extra_paths`, then swap it in. Main thread only.
pub fn interceptReload(gpa: std.mem.Allocator, extra_paths: []const []const u8) bool {
    const eng = gpa.create(filter.Engine) catch return false;
    eng.* = filter.Engine.init(gpa);
    var ok = true;
    eng.addList(seed_filter_list) catch {
        ok = false;
    };

    var dir_buf: [4096]u8 = undefined;
    if (filtersDir(&dir_buf)) |dir| {
        if (c.opendir(dir.ptr)) |dp| {
            defer _ = c.closedir(dp);
            while (c.readdir(dp)) |entp| {
                const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entp.*.d_name)));
                if (!std.mem.endsWith(u8, name, ".txt")) continue;
                var path_buf: [4352:0]u8 = undefined;
                const p = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ dir, name }) catch continue;
                const text = readFileBounded(gpa, p.ptr, 16 * 1024 * 1024) orelse continue;
                eng.addList(text) catch {
                    gpa.free(text);
                    ok = false;
                    break;
                };
                gpa.free(text);
            }
        }
    }
    for (extra_paths) |path| {
        var path_buf: [4352:0]u8 = undefined;
        const p = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch continue;
        const text = readFileBounded(gpa, p.ptr, 16 * 1024 * 1024) orelse continue;
        eng.addList(text) catch {
            gpa.free(text);
            ok = false;
            break;
        };
        gpa.free(text);
    }
    if (!ok) {
        eng.deinit();
        gpa.destroy(eng);
        return false;
    }

    var old: ?*filter.Engine = null;
    {
        g_int.acquire();
        defer g_int.release();
        old = g_int.engine;
        g_int.engine = eng;
        g_int.rules = eng.count;
        for (&g_int.slots) |*s| {
            if (s.used) s.dirty = true;
        }
    }
    if (old) |o| g_int.retireEngine(gpa, o);
    return true;
}

/// Load the initial filter set (seed + config dir). Called once at
/// helper startup, before any view exists.
pub fn interceptInit(gpa: std.mem.Allocator) void {
    _ = interceptReload(gpa, &.{});
    wreqInitPipe();
    wreqReadTimeoutEnv();
    dlReadHoldEnv();
}

/// Free the engine and any leftover rings (client gone, views already
/// destroyed).
pub fn interceptDeinit(gpa: std.mem.Allocator) void {
    // Before anything else: a held request must not outlive the table
    // that owns its callback.
    webrequestDeinit();
    var old: ?*filter.Engine = null;
    var pols: [MAX_ISLOTS]?*netpolicy.Policy = @splat(null);
    var rings: [MAX_ISLOTS]?*[NLOG]LogEntry = @splat(null);
    var caps: [MAX_ISLOTS]?*capture.Store = @splat(null);
    {
        g_int.acquire();
        defer g_int.release();
        old = g_int.engine;
        g_int.engine = null;
        g_int.rules = 0;
        for (&g_int.slots, 0..) |*s, i| {
            if (s.used) {
                rings[i] = s.ring;
                pols[i] = s.pol;
                caps[i] = s.cap;
                s.* = .{};
            }
        }
    }
    for (caps) |cp| {
        if (cp) |s| s.release();
    }
    // Detached under the lock, freed outside it: an allocator call is
    // not spinlock work, and nothing can reach a ring once its slot
    // is cleared.
    for (rings) |r| {
        if (r) |ring| gpa.destroy(ring);
    }
    for (pols) |p| {
        if (p) |pol| pol.deinit(gpa);
    }
    if (old) |o| g_int.retireEngine(gpa, o);
}

/// Whether the shield allows cosmetic hiding for `view_id`: global
/// AND per-view, exactly the network-verdict gate. Main thread.
pub fn cosmeticEnabledFor(view_id: u32) bool {
    g_int.acquire();
    defer g_int.release();
    if (!g_int.global_enabled) return false;
    for (&g_int.slots) |*s| {
        if (s.used and s.view_id == view_id) return s.enabled;
    }
    return true;
}

/// The compiled element-hiding sheet for one host, or null when there
/// is nothing to hide. MAIN THREAD ONLY: the engine pointer is read
/// under the lock but walked outside it, which is safe because engine
/// swaps (`interceptReload`) happen on this same thread — the IO
/// thread only ever reads. Caller frees.
pub fn cosmeticCss(gpa: std.mem.Allocator, host: []const u8) ?[]u8 {
    var eng: ?*filter.Engine = null;
    {
        g_int.acquire();
        defer g_int.release();
        eng = g_int.engine;
    }
    const e = eng orelse return null;
    const css = e.cosmeticFor(gpa, host) catch return null;
    if (css.len == 0) {
        gpa.free(css);
        return null;
    }
    return css;
}

/// CEF's resource type as the wire's engine-agnostic byte.
pub fn rtypeOf(t: cef.cef_resource_type_t) filter.RType {
    return switch (t) {
        cef.RT_MAIN_FRAME => .document,
        cef.RT_SUB_FRAME => .subdocument,
        cef.RT_STYLESHEET => .stylesheet,
        cef.RT_SCRIPT => .script,
        cef.RT_IMAGE, cef.RT_FAVICON => .image,
        cef.RT_FONT_RESOURCE => .font,
        cef.RT_XHR => .xhr,
        cef.RT_MEDIA => .media,
        cef.RT_PING, cef.RT_CSP_REPORT => .ping,
        else => .other,
    };
}

/// UTF-8 of a userfree CEF string result, into `buf` (truncated).
pub fn jsonU32(o: std.json.ObjectMap, key: []const u8) u32 {
    const v = o.get(key) orelse return 0;
    return switch (v) {
        .integer => |i| @intCast(@max(i, 0)),
        else => 0,
    };
}

pub fn jsonBool(o: std.json.ObjectMap, key: []const u8) bool {
    const v = o.get(key) orelse return false;
    return v == .bool and v.bool;
}

pub fn jsonStrField(o: std.json.ObjectMap, key: []const u8) []const u8 {
    const v = o.get(key) orelse return "";
    return if (v == .string) v.string else "";
}

pub fn userfreeInto(raw: cef.cef_string_userfree_t, buf: []u8) []const u8 {
    if (raw == null) return "";
    defer cef.cef_string_userfree_utf16_free(raw);
    var s = Utf8.init(raw);
    defer s.free();
    const src = s.slice();
    const n = @min(src.len, buf.len);
    @memcpy(buf[0..n], src[0..n]);
    return buf[0..n];
}

/// Longest url the gate reads whole; the untrusted broker refuses anything longer.
const URL_MAX = proto.UNTRUSTED_URL_CAP;

/// Under the lock. Append one request to the view's ring; a `reason` other than `.none` marks it refused and final.
fn logRequest(s: *ISlot, req_id: u64, now: i64, rtype: filter.RType, reason: proto.NetReason, method: []const u8, url: []const u8) void {
    const ring = s.ring orelse return;
    const blocked = reason != .none;
    // A redirect hop links back to the entry it continues. That entry
    // normally ended at `on_resource_redirect`; one that did not (a
    // webRequest redirect re-issues the request without it) ends here.
    var prev_seq: u32 = 0;
    if (hopOf(ring, req_id)) |hop| {
        prev_seq = hop.seq;
        hop.continued = true;
        if (!hop.done) {
            hop.done = true;
            hop.redirect = true;
            hop.dur_ms = @intCast(std.math.clamp(now - hop.start_ms, 0, std.math.maxInt(u32)));
        }
    }
    // Step over pinned document rows; DOC_PINS < NLOG, so a free slot
    // always exists within one lap.
    var laps: usize = 0;
    while (laps < NLOG and pinned(s, &ring[s.widx])) : (laps += 1) s.widx = (s.widx + 1) % NLOG;
    const e = &ring[s.widx];
    s.widx = (s.widx + 1) % NLOG;
    if (rtype == .document) {
        s.docs[s.docs_w] = s.next_seq;
        s.docs_w = (s.docs_w + 1) % DOC_PINS;
    }
    e.* = .{
        .seq = s.next_seq,
        .req_id = req_id,
        .start_ms = now,
        .rtype = @intFromEnum(rtype),
        .blocked = blocked,
        // A blocked entry never completes; it is final now.
        .done = blocked,
        .reason = @intFromEnum(reason),
        .prev_seq = prev_seq,
    };
    s.next_seq +%= 1;
    if (s.next_seq == 0) s.next_seq = 1;
    e.method_len = @intCast(@min(method.len, e.method.len));
    @memcpy(e.method[0..e.method_len], method[0..e.method_len]);
    e.url_len = @intCast(@min(url.len, e.url.len));
    @memcpy(e.url[0..e.url_len], url[0..e.url_len]);
}

fn pinned(s: *const ISlot, e: *const LogEntry) bool {
    if (e.seq == 0 or e.rtype != @intFromEnum(filter.RType.document)) return false;
    return std.mem.indexOfScalar(u32, &s.docs, e.seq) != null;
}

/// IO THREAD. Refuse a request before the filter/policy step: counted, latched if a budget, and logged with its reason.
fn denyRequest(cef_id: c_int, reason: proto.NetReason, req_id: u64, rtype: filter.RType, method: []const u8, url: []const u8, now: i64) void {
    g_int.acquire();
    defer g_int.release();
    const s = g_int.slotByCef(cef_id) orelse return;
    netpolicy.deny(&s.pc, reason);
    s.pol_dirty = true;
    s.total +%= 1;
    s.blocked +%= 1;
    s.dirty = true;
    logRequest(s, req_id, now, rtype, reason, method, url);
}

/// IO THREAD. The verdict and the log append, inline with the request.
pub fn onBeforeResourceLoad(
    _: [*c]cef.cef_resource_request_handler_t,
    browser: [*c]cef.cef_browser_t,
    frame: [*c]cef.cef_frame_t,
    request: [*c]cef.cef_request_t,
    callback: [*c]cef.cef_callback_t,
) callconv(.c) cef.cef_return_value_t {
    defer releaseArg(browser);
    defer releaseArg(frame);
    // A hold KEEPS `request` and `callback` (the answer path releases
    // them); every other exit gives their references back here.
    var held = false;
    defer if (!held) {
        releaseArg(request);
        releaseArg(callback);
    };
    {
        g_int.acquire();
        defer g_int.release();
        if (g_int.policy_failed) return cef.RV_CANCEL;
        if (browser) |b| if (b[0].get_identifier) |gi| {
            if (g_int.slotByCef(gi(b))) |s| if (s.pc.exhausted == .policy_refused) return cef.RV_CANCEL;
        };
    }
    const untrusted = host_mod.untrusted.enabled;
    // Untrusted: no request without a view to attribute it to. Such a
    // request (browserless, or racing registration/teardown) has no slot
    // and therefore no ring or counter to name its refusal in.
    const req: *cef.cef_request_t = request orelse return if (untrusted) cef.RV_CANCEL else cef.RV_CONTINUE;
    // Service-worker / urlrequest traffic has no browser and thus no
    // view to attribute it to; it passes unfiltered (matching without
    // a first-party context would misapply domain=/third-party rules).
    const b: *cef.cef_browser_t = browser orelse return if (untrusted) cef.RV_CANCEL else cef.RV_CONTINUE;
    const gi = b.get_identifier orelse return if (untrusted) cef.RV_CANCEL else cef.RV_CONTINUE;
    const cef_id = gi(b);

    // One byte past the broker's cap is how an overlong url is detected
    // (`userfreeInto` truncates to the buffer); trusted mode shares the
    // size so the filter sees the same url the broker would.
    var url_raw: [URL_MAX + 1]u8 = undefined;
    var url_buf: [URL_MAX + 1]u8 = undefined;
    const gu = req.get_url orelse return if (untrusted) cef.RV_CANCEL else cef.RV_CONTINUE;
    const url_unf = userfreeInto(gu(req), &url_raw);
    const rtype = if (req.get_resource_type) |grt| rtypeOf(grt(req)) else filter.RType.other;
    const req_id: u64 = if (req.get_identifier) |gid| gid(req) else 0;
    var method_buf: [8]u8 = undefined;
    var method: []const u8 = "";
    if (req.get_method) |gm| method = userfreeInto(gm(req), &method_buf);
    const now = nowMs();
    if (untrusted) {
        const raw_rt = if (req.get_resource_type) |rt| rt(req) else cef.RT_SUB_RESOURCE;
        const refusal: proto.NetReason = if (url_unf.len > URL_MAX)
            .url_too_long
        else if (untrustedPrivateAllowed(cef_id) == null)
            .policy_refused
        else if (host_mod.untrusted.restrictedRequest(raw_rt, url_unf, true) != null)
            .untrusted_transport
        else
            .none;
        if (refusal != .none) {
            denyRequest(cef_id, refusal, req_id, rtype, method, url_unf, now);
            return cef.RV_CANCEL;
        }
    }

    // AN EXTENSION'S OWN ORIGIN IS NEVER FILTERED. `filter.hostOf` sees
    // a 16-hex-digit host it cannot know anything about, the seed engine
    // has no rule for it — and yet the load came back
    // ERR_BLOCKED_BY_CLIENT, because a `chrome-extension://` load is not
    // web traffic and must not enter this path at all. Firefox draws the
    // same line: webRequest never sees a `moz-extension://` load, and a
    // filter list that could block an extension's own background page
    // would disable the extension at random.
    if (std.mem.startsWith(u8, url_unf, ext_scheme ++ "://")) return cef.RV_CONTINUE;

    const url = filter.foldUrl(&url_buf, url_unf);
    const host = filter.hostOf(url);

    var fp_raw: [512]u8 = undefined;
    var fp_buf: [512]u8 = undefined;
    var doc_host: []const u8 = "";
    if (req.get_first_party_for_cookies) |gfp| {
        const fp = filter.foldUrl(&fp_buf, userfreeInto(gfp(req), &fp_raw));
        doc_host = filter.hostOf(fp);
    }

    var verdict = false;
    var shield_on = true;
    var view_id: u32 = 0;
    // The view's capture and the log seq this request was given, taken
    // under the lock and used after it (the filter match can run a
    // regex, far too long for a spinlock).
    var cap_store: ?*capture.Store = null;
    var cap_seq: u32 = 0;
    defer if (cap_store) |cs| cs.release();
    // The filter match runs OUTSIDE the lock against a pinned engine:
    // it is a linear scan over every generic rule, and the main thread
    // would spin for the whole of it. The slot is looked up again for
    // the policy + log step below, since a view can be unregistered in
    // between and a pointer into the table must not be carried across.
    var eng: ?*filter.Engine = null;
    {
        g_int.acquire();
        defer g_int.release();
        const slot = g_int.slotByCef(cef_id);
        if (slot) |s| view_id = s.view_id;
        shield_on = g_int.global_enabled and (if (slot) |s| s.enabled else true);
        if (shield_on and host.len > 0) eng = g_int.pinEngine();
    }
    if (eng) |e| {
        verdict = e.match(.{ .url = url, .host = host, .doc_host = doc_host, .rtype = rtype });
        g_int.unpinEngine();
    }
    {
        g_int.acquire();
        defer g_int.release();
        const slot = g_int.slotByCef(cef_id);
        // PRECEDENCE, step 2: the enforced POLICY. Runs only past the
        // filter (a filter cancel is final and keeps its own reason)
        // and never for a slotless request (service workers /
        // urlrequest traffic — documented unpoliced, matching the
        // filter's own exemption above).
        var pol_reason: proto.NetReason = .none;
        // A view that must not follow redirects refuses the re-issued
        // main-frame hop; the 3xx before it is already logged.
        if (!verdict) if (slot) |s| if (s.no_redirect and rtype == .document) {
            if (s.ring) |ring| if (hopOf(ring, req_id) != null) {
                pol_reason = .redirect_refused;
                verdict = true;
            };
        };
        if (!verdict) {
            if (slot) |s| {
                if (s.pol) |pol| {
                    const is_top = rtype == .document;
                    // A redirected re-issue (`hopOf`).
                    const is_hop = if (s.ring) |ring| hopOf(ring, req_id) != null else false;
                    // An authority whose port does not parse cannot be
                    // matched against a port-carrying entry: refused, named.
                    const port: ?u16 = if (host.len == 0) 0 else urlhost.portOf(url);
                    pol_reason = if (port) |p| netpolicy.decide(pol, &s.pc, .{
                        .host = host,
                        .scheme = netpolicy.schemeOf(url),
                        .port = p,
                        .rtype = rtype,
                        .is_top = is_top,
                        .is_redirect_hop = is_hop,
                    }, now) else .malformed_url;
                    if (pol_reason == .none) {
                        netpolicy.commit(&s.pc, is_top);
                    } else {
                        netpolicy.deny(&s.pc, pol_reason);
                        verdict = true;
                    }
                    s.pol_dirty = true;
                }
            }
        }
        if (slot) |s| {
            s.total +%= 1;
            if (verdict) s.blocked +%= 1;
            s.dirty = true;
            if (s.ring != null and !verdict) {
                if (s.cap) |cs| {
                    cap_store = cs.retain();
                    cap_seq = s.next_seq;
                }
            }
            const reason: proto.NetReason = if (pol_reason != .none) pol_reason else if (verdict) .filter_list else .none;
            logRequest(s, req_id, now, rtype, reason, method, url_unf);
        }
    }
    // Only a request that will reach the network can have a response to
    // capture; a refused one never took a store reference above.
    if (cap_store) |cs| cs.admitRequest(req_id, cap_seq, url_unf, host, rtype, method, now);
    // PRECEDENCE, step 1: the native engine's cancel is FINAL, and a
    // policy denial is equally final. An extension is never asked about
    // a request either already refused, and never asked at all while
    // the shield is off.
    if (verdict) return cef.RV_CANCEL;
    if (!shield_on) return cef.RV_CONTINUE;

    held = wreqConsider(req, callback, url_unf, method, wreqTypeOf(
        if (req.get_resource_type) |grt| grt(req) else cef.RT_SUB_RESOURCE,
    ), view_id);
    return if (held) cef.RV_CONTINUE_ASYNC else cef.RV_CONTINUE;
}

/// IO THREAD. `onHeadersReceived`, observationally.
///
/// MEASURED ENGINE LIMITATION, and the reason this is not a hold:
/// `cef_resource_request_handler_t::on_resource_response` takes NO
/// `cef_callback_t` and returns an int — there is no
/// `RV_CONTINUE_ASYNC` equivalent anywhere on the response path, so the
/// request cannot be paused while a listener in another process
/// answers. The listener therefore RUNS and SEES the real response
/// headers, but a `responseHeaders` array it returns is counted and
/// dropped rather than applied. The alternative — taking the whole load
/// over with our own `cef_resource_handler_t` and re-issuing it through
/// `cef_urlrequest` — would put credentials, cookies, ranges and
/// streaming back in our hands, which is a far bigger correctness
/// surface than the feature buys. smoke-web stage 34d is the canary.
pub fn onResourceResponse(
    _: [*c]cef.cef_resource_request_handler_t,
    browser: [*c]cef.cef_browser_t,
    frame: [*c]cef.cef_frame_t,
    request: [*c]cef.cef_request_t,
    response: [*c]cef.cef_response_t,
) callconv(.c) c_int {
    defer releaseArg(browser);
    defer releaseArg(frame);
    defer releaseArg(request);
    defer releaseArg(response);
    const req: *cef.cef_request_t = request orelse return 0;
    if (response) |resp| noteResponse(browser, req, resp, null);
    if (!webrequest.any_listeners.load(.acquire)) return 0;

    var url_raw: [2048]u8 = undefined;
    const gu = req.get_url orelse return 0;
    const url = userfreeInto(gu(req), &url_raw);
    if (std.mem.startsWith(u8, url, ext_scheme ++ "://")) return 0;
    const rtype = wreqTypeOf(if (req.get_resource_type) |grt| grt(req) else cef.RT_SUB_RESOURCE);
    const view_id = viewIdOfBrowser(browser);

    var hdr_buf: [HOLD_HDR_MAX]u8 = undefined;
    var hdr_len: u16 = 0;
    if (response) |resp| hdr_len = headerMapJson(resp, &hdr_buf);
    var method_buf: [8]u8 = undefined;
    var method: []const u8 = "";
    if (req.get_method) |gm| method = userfreeInto(gm(req), &method_buf);
    var extra_buf: [256]u8 = undefined;
    const extra = responseExtra(&extra_buf, response);

    // Both events are notifications on this path: `onHeadersReceived`
    // because the response cannot be paused (above), and
    // `onResponseStarted` by definition. Every matching extension gets
    // its own mailbox drop.
    inline for (.{ webrequest.Event.headers_received, webrequest.Event.response_started }) |ev| {
        _ = wreqNotifyAll(.{
            .event = ev,
            .url = url,
            .method = method,
            .rtype = rtype,
            .view_id = view_id,
            .hdr = hdr_buf[0..hdr_len],
            .extra = extra,
        });
    }
    return 0;
}

/// IO THREAD. Record a response's status, status text and content type
/// on the log entry its request is on; with `redirect`, that entry also
/// ENDS here as a redirect hop (the next hop's entry links back to it).
fn noteResponse(browser: ?*cef.cef_browser_t, req: *cef.cef_request_t, resp: *cef.cef_response_t, redirect: ?i64) void {
    const b = browser orelse return;
    const gi = b.get_identifier orelse return;
    const cef_id = gi(b);
    const req_id: u64 = if (req.get_identifier) |gid| gid(req) else return;
    var status: u16 = 0;
    if (resp.get_status) |gs| status = @intCast(std.math.clamp(gs(resp), 0, 999));
    var mime_buf: [LOG_MIME_MAX]u8 = undefined;
    var mime: []const u8 = "";
    if (resp.get_mime_type) |gm| mime = userfreeInto(gm(resp), &mime_buf);
    var stext_buf: [LOG_STEXT_MAX]u8 = undefined;
    var stext: []const u8 = "";
    if (resp.get_status_text) |gt| stext = userfreeInto(gt(resp), &stext_buf);
    // A redirect names the hop by its OLD url too: should the engine ever
    // re-enter `on_before_resource_load` first, the open entry would be
    // the NEW hop, and that one must not be ended as a redirect.
    var url_buf: [LOG_URL_MAX]u8 = undefined;
    const url: []const u8 = if (redirect != null) (if (req.get_url) |gu| userfreeInto(gu(req), &url_buf) else "") else "";
    g_int.acquire();
    defer g_int.release();
    const s = g_int.slotByCef(cef_id) orelse return;
    const ring = s.ring orelse return;
    const e = if (redirect == null) openEntry(ring, req_id) orelse return else blk: {
        var best: ?*LogEntry = null;
        for (ring) |*x| {
            if (x.seq == 0 or x.req_id != req_id or x.blocked) continue;
            if (!std.mem.eql(u8, x.url[0..x.url_len], url[0..@min(url.len, x.url_len)])) continue;
            if (best == null or x.seq > best.?.seq) best = x;
        }
        break :blk best orelse return;
    };
    e.setResponse(status, mime, stext);
    if (redirect) |now| {
        e.redirect = true;
        if (!e.done) {
            e.done = true;
            e.dur_ms = @intCast(std.math.clamp(now - e.start_ms, 0, std.math.maxInt(u32)));
        }
    }
    s.dirty = true;
}

/// IO THREAD. A server redirect: the hop it ends gets the redirect's
/// status, and the re-issue `on_before_resource_load` sees next is linked
/// to it (`hopOf`). The new url is left as the engine chose it.
pub fn onResourceRedirect(
    _: [*c]cef.cef_resource_request_handler_t,
    browser: [*c]cef.cef_browser_t,
    frame: [*c]cef.cef_frame_t,
    request: [*c]cef.cef_request_t,
    response: [*c]cef.cef_response_t,
    _: [*c]cef.cef_string_t,
) callconv(.c) void {
    defer releaseArg(browser);
    defer releaseArg(frame);
    defer releaseArg(request);
    defer releaseArg(response);
    const req: *cef.cef_request_t = request orelse return;
    const resp: *cef.cef_response_t = response orelse return;
    noteResponse(browser, req, resp, nowMs());
}

/// The net error a finished load ended with: the response's own code,
/// else ABORTED for a cancelled load and FAILED otherwise; 0 on success.
fn loadErrCode(response: ?*cef.cef_response_t, ur_status: cef.cef_urlrequest_status_t) i32 {
    if (ur_status == @as(cef.cef_urlrequest_status_t, @intCast(cef.UR_SUCCESS))) return 0;
    var code: i32 = if (ur_status == @as(cef.cef_urlrequest_status_t, @intCast(cef.UR_CANCELED))) -3 else -2;
    if (response) |resp| {
        if (resp.get_error) |ge| {
            const e: i32 = @intCast(ge(resp));
            if (e != 0) code = e;
        }
    }
    return code;
}

/// `"statusCode":200,"statusLine":"HTTP/1.1 200 OK","fromCache":false`
/// for a response, "" without one. IO THREAD: fixed buffer only.
pub fn responseExtra(buf: []u8, response: ?*cef.cef_response_t) []const u8 {
    const resp = response orelse return "";
    var status: i32 = 0;
    if (resp.get_status) |gs| status = gs(resp);
    var text_buf: [128]u8 = undefined;
    var text: []const u8 = "";
    if (resp.get_status_text) |gt| text = userfreeInto(gt(resp), &text_buf);
    var w = std.Io.Writer.fixed(buf);
    w.print("\"statusCode\":{d},\"statusLine\":", .{status}) catch return "";
    var line_buf: [160]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, "HTTP/1.1 {d} {s}", .{ status, text }) catch "";
    jsonStr(&w, line) catch return "";
    w.writeAll(",\"fromCache\":false") catch return "";
    return buf[0..w.end];
}

/// The view a browser belongs to, 0 when none (a background page's own
/// fetch, a urlrequest). IO THREAD safe: reads the intercept table.
pub fn viewIdOfBrowser(browser: ?*cef.cef_browser_t) u32 {
    const b = browser orelse return 0;
    const gi = b.get_identifier orelse return 0;
    const cef_id = gi(b);
    g_int.acquire();
    defer g_int.release();
    return if (g_int.slotByCef(cef_id)) |s| s.view_id else 0;
}

/// IO THREAD. `webRequest.onCompleted` / `onErrorOccurred`, as
/// notifications to every matching extension.
pub fn notifyLoadComplete(
    browser: ?*cef.cef_browser_t,
    req: *cef.cef_request_t,
    response: ?*cef.cef_response_t,
    ur_status: cef.cef_urlrequest_status_t,
) void {
    if (!webrequest.any_listeners.load(.acquire)) return;
    var url_raw: [2048]u8 = undefined;
    const gu = req.get_url orelse return;
    const url = userfreeInto(gu(req), &url_raw);
    if (std.mem.startsWith(u8, url, ext_scheme ++ "://")) return;
    const rtype = wreqTypeOf(if (req.get_resource_type) |grt| grt(req) else cef.RT_SUB_RESOURCE);
    var method_buf: [8]u8 = undefined;
    var method: []const u8 = "";
    if (req.get_method) |gm| method = userfreeInto(gm(req), &method_buf);
    const code = loadErrCode(response, ur_status);
    const ok = code == 0;
    var extra_buf: [256]u8 = undefined;
    var extra: []const u8 = "";
    if (ok) {
        extra = responseExtra(&extra_buf, response);
    } else {
        var w = std.Io.Writer.fixed(&extra_buf);
        w.writeAll("\"fromCache\":false,\"error\":") catch {};
        var name_buf: [64]u8 = undefined;
        jsonStr(&w, netErrorName(&name_buf, code)) catch {};
        extra = extra_buf[0..w.end];
    }
    _ = wreqNotifyAll(.{
        .event = if (ok) .completed else .error_occurred,
        .url = url,
        .method = method,
        .rtype = rtype,
        .view_id = viewIdOfBrowser(browser),
        .extra = extra,
    });
}

pub const netErrorName = proto.netErrorName;

/// IO THREAD. Completes a logged entry with status/size/timing.
pub fn onResourceLoadComplete(
    _: [*c]cef.cef_resource_request_handler_t,
    browser: [*c]cef.cef_browser_t,
    frame: [*c]cef.cef_frame_t,
    request: [*c]cef.cef_request_t,
    response: [*c]cef.cef_response_t,
    ur_status: cef.cef_urlrequest_status_t,
    received: i64,
) callconv(.c) void {
    defer releaseArg(browser);
    defer releaseArg(frame);
    defer releaseArg(request);
    defer releaseArg(response);
    const req: *cef.cef_request_t = request orelse return;
    notifyLoadComplete(browser, req, response, ur_status);
    const b: *cef.cef_browser_t = browser orelse return;
    const gi = b.get_identifier orelse return;
    const cef_id = gi(b);
    const req_id: u64 = if (req.get_identifier) |gid| gid(req) else return;
    var status: u16 = 0;
    var mime_buf: [LOG_MIME_MAX]u8 = undefined;
    var mime: []const u8 = "";
    var stext_buf: [LOG_STEXT_MAX]u8 = undefined;
    var stext: []const u8 = "";
    if (response) |resp| {
        if (resp.*.get_status) |gs| status = @intCast(std.math.clamp(gs(resp), 0, 999));
        if (resp.*.get_mime_type) |gm| mime = userfreeInto(gm(resp), &mime_buf);
        if (resp.*.get_status_text) |gt| stext = userfreeInto(gt(resp), &stext_buf);
    }
    const now = nowMs();
    const err = loadErrCode(response, ur_status);
    captureFinish(cef_id, req_id, err, status, now);

    g_int.acquire();
    defer g_int.release();
    for (&g_int.slots) |*s| {
        if (!s.used or s.cef_id != cef_id) continue;
        // Byte budget: accounted at completion (the only place the
        // engine reports a size), so a response that CROSSES the cap
        // completes and the NEXT request is what gets refused. The
        // schema says so; no CEF callback can pre-empt a body.
        if (s.pol) |pol| {
            s.pc.bytes +|= @intCast(@max(received, 0));
            if (pol.max_bytes != 0 and s.pc.bytes >= pol.max_bytes and s.pc.exhausted == .none)
                s.pc.exhausted = .byte_cap;
            s.pol_dirty = true;
        }
        const ring = s.ring orelse return;
        const e = openEntry(ring, req_id) orelse return;
        e.done = true;
        e.setResponse(status, mime, stext);
        e.err = err;
        e.size = @intCast(std.math.clamp(received, 0, std.math.maxInt(u32)));
        e.dur_ms = @intCast(std.math.clamp(now - e.start_ms, 0, std.math.maxInt(u32)));
        s.dirty = true;
        return;
    }
}

/// IO THREAD. Tell the view's capture, if any, that `req_id` finished.
fn captureFinish(cef_id: c_int, req_id: u64, err: i32, status: u16, now: i64) void {
    const store = captureOf(cef_id) orelse return;
    defer store.release();
    store.finish(req_id, err == 0, err, status, now);
}

/// IO THREAD. The capture of the view browser `cef_id` belongs to, with
/// a reference the caller releases; null when it has none.
pub fn captureOf(cef_id: c_int) ?*capture.Store {
    g_int.acquire();
    defer g_int.release();
    const s = g_int.slotByCef(cef_id) orelse return null;
    const cs = s.cap orelse return null;
    return cs.retain();
}

/// Copy a ring `LogEntry` into a `proto.NetEntry`, with its strings
/// staged into caller-owned buffers (the entry's own storage is
/// released the moment the lock drops). Called under the lock.
pub fn fillEntry(out: *proto.NetEntry, url_buf: *[LOG_URL_MAX]u8, method_buf: *[8]u8, e: *const LogEntry) void {
    @memcpy(url_buf[0..e.url_len], e.url[0..e.url_len]);
    @memcpy(method_buf[0..e.method_len], e.method[0..e.method_len]);
    out.* = .{
        .seq = e.seq,
        .blocked = if (e.blocked) 1 else 0,
        .rtype = e.rtype,
        .done = if (e.done) 1 else 0,
        .status = e.status,
        .dur_ms = e.dur_ms,
        .size = e.size,
        .method = method_buf[0..e.method_len],
        .url = url_buf[0..e.url_len],
    };
}

test "a redirect re-issue links to the hop it continues, and document rows outlive busy pages" {
    const gpa = std.testing.allocator;
    const ring = try gpa.create([NLOG]LogEntry);
    defer gpa.destroy(ring);
    ring.* = @splat(.{});
    var s = ISlot{ .used = true, .ring = ring };
    logRequest(&s, 77, 0, .document, .none, "GET", "http://h/r1");
    // The engine ends the first hop as a redirect, then re-issues.
    const first = openEntry(ring, 77).?;
    first.setResponse(301, "text/html", "Moved Permanently");
    first.done = true;
    first.redirect = true;
    try std.testing.expect(hopOf(ring, 77) == first);
    logRequest(&s, 77, 1, .document, .none, "GET", "http://h/r2");
    // A hop without its own redirect callback still ends as one.
    logRequest(&s, 77, 2, .document, .none, "GET", "http://h/final");
    const last = openEntry(ring, 77).?;
    try std.testing.expectEqualStrings("http://h/final", last.url[0..last.url_len]);
    try std.testing.expectEqual(@as(u32, 2), last.prev_seq);
    try std.testing.expectEqual(@as(u32, 1), ring[1].prev_seq);
    try std.testing.expect(ring[1].redirect and ring[1].done and ring[1].continued);
    try std.testing.expect(first.continued);

    // Hundreds of subresources later every document row is still there.
    var i: u64 = 0;
    while (i < 3 * NLOG) : (i += 1) logRequest(&s, 1000 + i, 3, .image, .none, "GET", "http://h/i.png");
    var docs: usize = 0;
    for (ring) |*e| {
        if (e.seq != 0 and e.rtype == @intFromEnum(filter.RType.document)) docs += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), docs);
    // A finished request is no hop: a new request with an old id starts afresh.
    last.done = true;
    try std.testing.expect(hopOf(ring, 77) == null);
}
