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

/// Answer a log pull: entries with seq > `req.since`, oldest first,
/// up to `req.max` (bounded). The ring is snapshotted under the
/// lock into a small stack buffer, then encoded outside it.
pub fn interceptLog(self: *Host, req: proto.InterceptLogReq) void {
    var snap: [NLOG]proto.NetEntry = undefined;
    var url_store: [NLOG][LOG_URL_MAX]u8 = undefined;
    var method_store: [NLOG][8]u8 = undefined;
    var n: usize = 0;
    var next_seq: u32 = req.since;
    const cap: usize = @min(@as(usize, if (req.max == 0) NLOG else req.max), NLOG);
    {
        g_int.acquire();
        defer g_int.release();
        for (&g_int.slots) |*s| {
            if (!s.used or s.view_id != req.view) continue;
            next_seq = s.next_seq;
            const ring = s.ring orelse break;
            // Emit in seq order: the ring is a circular buffer, so
            // walk it and collect, then a caller-side sort would be
            // overkill — seqs increase with widx, so oldest is at
            // widx. Simplest correct pass: scan all, filter, insert
            // sorted (NLOG is tiny).
            for (ring) |*e| {
                if (e.seq == 0 or e.seq <= req.since) continue;
                if (n >= cap) {
                    // Keep the NEWEST `cap`: replace the oldest held
                    // if this one is newer.
                    var oldest: usize = 0;
                    for (snap[0..n], 0..) |se, i| {
                        if (se.seq < snap[oldest].seq) oldest = i;
                    }
                    if (e.seq <= snap[oldest].seq) continue;
                    fillEntry(&snap[oldest], &url_store[oldest], &method_store[oldest], e);
                    continue;
                }
                fillEntry(&snap[n], &url_store[n], &method_store[n], e);
                n += 1;
            }
            break;
        }
    }
    // Sort ascending by seq (insertion sort; n <= NLOG).
    var i: usize = 1;
    while (i < n) : (i += 1) {
        var j = i;
        while (j > 0 and snap[j - 1].seq > snap[j].seq) : (j -= 1) {
            const tmp = snap[j];
            snap[j] = snap[j - 1];
            snap[j - 1] = tmp;
        }
    }
    self.post(proto.InterceptLog{ .view = req.view, .next_seq = next_seq, .entries = snap[0..n] });
}

// -- enforced network policy (0x86 block) --------------------------

/// Install (or replace) a view's enforced policy. MAIN thread; the
/// slot is found-or-created so the frame can precede the
/// `view_create` naming the view. When no slot is free (the
/// MAX_POLICY_VIEWS ceiling) an `active=0` event is posted — the
/// client refuses the open on its own count, this is the belt.
pub fn netPolicySet(self: *Host, req: proto.NetPolicySet) void {
    const pol = netpolicy.Policy.build(self.gpa, req) catch return;
    const s = interceptSlotFor(self.gpa, req.view) orelse {
        pol.deinit(self.gpa);
        self.post(proto.EvNetPolicy{
            .view = req.view,
            .serial = req.serial,
            .active = 0,
            .exhausted = 0,
            .requests = 0,
            .bytes = 0,
            .navigations = 0,
            .ms_left = 0,
            .denied = @splat(0),
        });
        return;
    };
    var old: ?*netpolicy.Policy = null;
    {
        g_int.acquire();
        defer g_int.release();
        old = s.pol;
        s.pol = pol;
        s.pc = .{ .started_ms = nowMs() };
        s.pol_dirty = true;
        s.deadline_stopped = false;
    }
    if (old) |o| o.deinit(self.gpa);
}

pub fn netPolicyStatus(self: *Host, req: proto.NetPolicyReq) void {
    self.post(netPolicyFrame(req.view));
}

/// Answer a reason-carrying log pull; the `intercept_log` shape
/// with the policy verdict per entry.
pub fn netLog(self: *Host, req: proto.NetLogReq) void {
    var snap: [NLOG]proto.NetEntry2 = undefined;
    var url_store: [NLOG][LOG_URL_MAX]u8 = undefined;
    var method_store: [NLOG][8]u8 = undefined;
    var n: usize = 0;
    var next_seq: u32 = req.since;
    const cap: usize = @min(@as(usize, if (req.max == 0) NLOG else req.max), NLOG);
    {
        g_int.acquire();
        defer g_int.release();
        for (&g_int.slots) |*s| {
            if (!s.used or s.view_id != req.view) continue;
            next_seq = s.next_seq;
            const ring = s.ring orelse break;
            for (ring) |*e| {
                if (e.seq == 0 or e.seq <= req.since) continue;
                if (n >= cap) {
                    var oldest: usize = 0;
                    for (snap[0..n], 0..) |se, i| {
                        if (se.entry.seq < snap[oldest].entry.seq) oldest = i;
                    }
                    if (e.seq <= snap[oldest].entry.seq) continue;
                    fillEntry(&snap[oldest].entry, &url_store[oldest], &method_store[oldest], e);
                    snap[oldest].reason = e.reason;
                    continue;
                }
                fillEntry(&snap[n].entry, &url_store[n], &method_store[n], e);
                snap[n].reason = e.reason;
                n += 1;
            }
            break;
        }
    }
    var i: usize = 1;
    while (i < n) : (i += 1) {
        var j = i;
        while (j > 0 and snap[j - 1].entry.seq > snap[j].entry.seq) : (j -= 1) {
            const tmp = snap[j];
            snap[j] = snap[j - 1];
            snap[j - 1] = tmp;
        }
    }
    self.post(proto.NetLog{ .view = req.view, .next_seq = next_seq, .entries = snap[0..n] });
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
        const pol = s.pol orelse break;
        out.serial = pol.serial;
        out.active = 1;
        out.exhausted = @intFromEnum(s.pc.exhausted);
        out.requests = s.pc.requests;
        out.bytes = s.pc.bytes;
        out.navigations = s.pc.navigations;
        out.ms_left = if (pol.deadline_ms == 0)
            0
        else
            @intCast(std.math.clamp(@as(i64, pol.deadline_ms) - (nowMs() - s.pc.started_ms), 0, std.math.maxInt(u32)));
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
                .serial = pol.serial,
                .active = 1,
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

/// Concurrent views the registry can track. A view past the cap still
/// gets verdicts (global engine + global enable), just no log/badge —
/// and can hold no POLICY, which is why the client refuses a policied
/// open past it (the constant is wire-adjacent and lives in protocol).
pub const MAX_ISLOTS = proto.MAX_POLICY_VIEWS;

/// Longest URL kept in a log entry; the tail is truncated, the
/// VERDICT always sees the full url.
pub const LOG_URL_MAX = 256;

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
    method_len: u8 = 0,
    method: [8]u8 = @splat(0),
    url_len: u16 = 0,
    url: [LOG_URL_MAX]u8 = @splat(0),
};

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
    /// Enforced policy, or null (the common case: one branch on the hot
    /// path and nothing else). Swapped whole by the MAIN thread under
    /// the lock, freed outside it, like the filter engine.
    pol: ?*netpolicy.Policy = null,
    /// Live accounting for `pol`; IO-thread-mutated under the lock.
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
    rules: u32 = 0,
    slots: [MAX_ISLOTS]ISlot = @splat(.{}),

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
    const ring = gpa.create([NLOG]LogEntry) catch return;
    ring.* = @splat(.{});
    var keep = false;
    defer if (!keep) gpa.destroy(ring);
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

pub fn interceptUnregister(gpa: std.mem.Allocator, view_id: u32) void {
    var ring: ?*[NLOG]LogEntry = null;
    var pol: ?*netpolicy.Policy = null;
    var cap: ?*capture.Store = null;
    {
        g_int.acquire();
        defer g_int.release();
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
    const req: *cef.cef_request_t = request orelse return cef.RV_CONTINUE;
    // Service-worker / urlrequest traffic has no browser and thus no
    // view to attribute it to; it passes unfiltered (matching without
    // a first-party context would misapply domain=/third-party rules).
    const b: *cef.cef_browser_t = browser orelse return cef.RV_CONTINUE;
    const gi = b.get_identifier orelse return cef.RV_CONTINUE;
    const cef_id = gi(b);

    var url_raw: [2048]u8 = undefined;
    var url_buf: [2048]u8 = undefined;
    const gu = req.get_url orelse return cef.RV_CONTINUE;
    const url_unf = userfreeInto(gu(req), &url_raw);

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

    var method_buf: [8]u8 = undefined;
    var method: []const u8 = "";
    if (req.get_method) |gm| method = userfreeInto(gm(req), &method_buf);

    const rtype = if (req.get_resource_type) |grt| rtypeOf(grt(req)) else filter.RType.other;
    const req_id: u64 = if (req.get_identifier) |gid| gid(req) else 0;
    const now = nowMs();

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
        if (!verdict) {
            if (slot) |s| {
                if (s.pol) |pol| {
                    const is_top = rtype == .document;
                    // CEF keeps the request identifier across a server
                    // redirect chain (measured on CEF 151): a live ring
                    // entry with this id means this request IS the
                    // redirected re-issue.
                    var is_hop = false;
                    if (s.ring) |ring| {
                        for (ring) |*e| {
                            if (e.seq != 0 and e.req_id == req_id and !e.done) {
                                is_hop = true;
                                break;
                            }
                        }
                    }
                    pol_reason = netpolicy.decide(pol, &s.pc, .{
                        .host = host,
                        .scheme = netpolicy.schemeOf(url),
                        .rtype = rtype,
                        .is_top = is_top,
                        .is_redirect_hop = is_hop,
                    }, now);
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
            if (s.ring) |ring| {
                if (!verdict) {
                    if (s.cap) |cs| {
                        cap_store = cs.retain();
                        cap_seq = s.next_seq;
                    }
                }
                const e = &ring[s.widx];
                s.widx = (s.widx + 1) % NLOG;
                e.* = .{
                    .seq = s.next_seq,
                    .req_id = req_id,
                    .start_ms = now,
                    .rtype = @intFromEnum(rtype),
                    .blocked = verdict,
                    // A blocked entry never completes; it is final now.
                    .done = verdict,
                    .reason = if (pol_reason != .none)
                        @intFromEnum(pol_reason)
                    else if (verdict)
                        @intFromEnum(proto.NetReason.filter_list)
                    else
                        0,
                };
                s.next_seq +%= 1;
                if (s.next_seq == 0) s.next_seq = 1;
                e.method_len = @intCast(@min(method.len, e.method.len));
                @memcpy(e.method[0..e.method_len], method[0..e.method_len]);
                e.url_len = @intCast(@min(url_unf.len, e.url.len));
                @memcpy(e.url[0..e.url_len], url_unf[0..e.url_len]);
            }
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
    const ok = ur_status == @as(cef.cef_urlrequest_status_t, @intCast(cef.UR_SUCCESS));
    var extra_buf: [256]u8 = undefined;
    var extra: []const u8 = "";
    if (ok) {
        extra = responseExtra(&extra_buf, response);
    } else {
        var code: i32 = if (ur_status == @as(cef.cef_urlrequest_status_t, @intCast(cef.UR_CANCELED))) -3 else -2;
        if (response) |resp| {
            if (resp.get_error) |ge| {
                const e: i32 = @intCast(ge(resp));
                if (e != 0) code = e;
            }
        }
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

/// Chromium's `net::ERR_*` spelling for the codes a page actually
/// meets; anything else keeps its number, never a made-up name.
pub fn netErrorName(buf: []u8, code: i32) []const u8 {
    const name: []const u8 = switch (code) {
        -2 => "FAILED",
        -3 => "ABORTED",
        -7 => "TIMED_OUT",
        -20 => "BLOCKED_BY_CLIENT",
        -21 => "NETWORK_CHANGED",
        -100 => "CONNECTION_CLOSED",
        -101 => "CONNECTION_RESET",
        -102 => "CONNECTION_REFUSED",
        -105 => "NAME_NOT_RESOLVED",
        -106 => "INTERNET_DISCONNECTED",
        -118 => "CONNECTION_TIMED_OUT",
        -200 => "CERT_COMMON_NAME_INVALID",
        -201 => "CERT_DATE_INVALID",
        -202 => "CERT_AUTHORITY_INVALID",
        else => return std.fmt.bufPrint(buf, "net::ERROR_{d}", .{code}) catch "net::ERR_FAILED",
    };
    return std.fmt.bufPrint(buf, "net::ERR_{s}", .{name}) catch "net::ERR_FAILED";
}

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
    if (response) |resp| {
        if (resp.*.get_status) |gs| status = @intCast(std.math.clamp(gs(resp), 0, 999));
    }
    const now = nowMs();
    captureFinish(cef_id, req_id, response, ur_status, status, now);

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
        for (ring) |*e| {
            if (e.seq == 0 or e.req_id != req_id or e.done) continue;
            e.done = true;
            e.status = status;
            e.size = @intCast(std.math.clamp(received, 0, std.math.maxInt(u32)));
            e.dur_ms = @intCast(std.math.clamp(now - e.start_ms, 0, std.math.maxInt(u32)));
            s.dirty = true;
            return;
        }
        return;
    }
}

/// IO THREAD. Tell the view's capture, if any, that `req_id` finished.
fn captureFinish(
    cef_id: c_int,
    req_id: u64,
    response: ?*cef.cef_response_t,
    ur_status: cef.cef_urlrequest_status_t,
    status: u16,
    now: i64,
) void {
    const store = captureOf(cef_id) orelse return;
    defer store.release();
    const ok = ur_status == @as(cef.cef_urlrequest_status_t, @intCast(cef.UR_SUCCESS));
    var err: i32 = 0;
    if (!ok) {
        err = if (ur_status == @as(cef.cef_urlrequest_status_t, @intCast(cef.UR_CANCELED))) -3 else -2;
        if (response) |resp| {
            if (resp.get_error) |ge| {
                const e: i32 = @intCast(ge(resp));
                if (e != 0) err = e;
            }
        }
    }
    store.finish(req_id, ok, err, status, now);
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
