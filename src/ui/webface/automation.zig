//! Automation (the `web_*` MCP tools ride this), the face half: the
//! correlated semantic round trips, their collected results, and the
//! network log/intercept counters the tools read. Split out of `webface.zig`; the `WebFace` methods are free functions
//! taking `*WebFace`, re-exported from `WebFace` by name.

const std = @import("std");
const c = @import("../../c.zig").c;
const clock = @import("../../util/clock.zig");
const proto = @import("../../web/protocol.zig");
const reader_guards = @import("../../web/reader_guards.zig");
const reader_model = @import("../../web/reader.zig");
const wf_hints = @import("../webface/hints.zig");
const wf_site = @import("../webface/siteinfo.zig");
const host_mod = @import("../webface.zig");
const WebFace = host_mod.WebFace;

// ---------------------------------------------------------------------
// Automation (the `web_*` MCP tools ride this)
// ---------------------------------------------------------------------

/// One kind of semantic round trip. Correlated helpers allow overlap;
/// legacy helpers keep at most one request of each kind in flight.
pub const AutoKind = enum { snapshot, act, expand, query, read, eval, network };

pub const AutoOp = struct {
    token: u32,
    kind: AutoKind,
    /// Client request id on the correlated semantic protocol; 0 for
    /// legacy semantic frames and non-semantic network pulls.
    request: u32 = 0,
    /// A `mode:full` snapshot is not satisfied by a spontaneous delta.
    want_full: bool = false,
    started_ms: i64 = 0,
};

/// How long an unanswered request blocks its kind. A page that never
/// answers (a wedged renderer, a promise that outlives its view) must
/// not lock the kind out for the life of the tab.
pub const AUTO_STALE_MS: i64 = 120_000;

/// Extra fields a snapshot reply carries; zero for every other kind.
pub const AutoMeta = struct {
    doc_gen: u32 = 0,
    rev: u32 = 0,
    snap_kind: u8 = 0,
    reader_ids: bool = false,
};

/// A finished round trip, waiting to be collected by `autoTake`. `text`
/// is owned by the face until taken, then by the caller.
pub const AutoResult = struct {
    token: u32,
    kind: AutoKind,
    ok: bool,
    text: []u8,
    meta: AutoMeta = .{},
};

/// Completed results a face keeps before dropping the oldest. A caller
/// that never collects is a caller that crashed; the cap keeps that
/// from growing without bound.
pub const MAX_AUTO_RESULTS = 16;

// ---- automation -------------------------------------------------

pub fn autoClear(self: *WebFace) void {
    for (self.auto_results.items) |r| self.allocator.free(r.text);
    self.auto_results.clearRetainingCapacity();
    self.auto_ops.clearRetainingCapacity();
    if (self.last_eval) |e| self.allocator.free(e);
    self.last_eval = null;
}

pub fn abandonAutoOps(self: *WebFace, connection_reset: bool) void {
    if (connection_reset) {
        self.auto_legacy_quarantine.reset();
    } else {
        for (self.auto_ops.items) |op| {
            if (op.request == 0) self.auto_legacy_quarantine.mark(@intFromEnum(op.kind));
        }
    }
    self.auto_ops.clearRetainingCapacity();
}

pub fn autoBusy(self: *WebFace, kind: AutoKind) bool {
    const now = clock.nowMs();
    var i: usize = 0;
    while (i < self.auto_ops.items.len) {
        if (now - self.auto_ops.items[i].started_ms > AUTO_STALE_MS) {
            const stale = self.auto_ops.orderedRemove(i);
            if (stale.request == 0) self.auto_legacy_quarantine.mark(@intFromEnum(stale.kind));
            continue;
        }
        i += 1;
    }
    if (kind != .network and self.cl.has(.semantic_request_ids)) return false;
    if (self.auto_legacy_quarantine.isHeld(@intFromEnum(kind))) return true;
    for (self.auto_ops.items) |op| {
        if (op.kind == kind) return true;
    }
    return false;
}

/// Register an in-flight request; null when the view cannot serve
/// one right now, which the caller reports rather than hanging.
pub fn autoBegin(self: *WebFace, kind: AutoKind, want_full: bool) ?u32 {
    if (!self.view_live) return null;
    // An agent driving a background tab must not be handed the
    // helper's "this view is discarded" answer when what it wants
    // is the page: revive first, so the request rides the reload
    // (a pending snapshot is re-issued at load end helper-side).
    // The helper's error reply stays the backstop for any client
    // that does not do this.
    self.reviveNow();
    if (self.autoBusy(kind)) return null;
    const token = self.auto_next;
    self.auto_next +%= 1;
    if (self.auto_next == 0) self.auto_next = 1;
    self.auto_ops.append(self.allocator, .{
        .token = token,
        .kind = kind,
        .request = if (kind != .network and self.cl.has(.semantic_request_ids)) token else 0,
        .want_full = want_full,
        .started_ms = clock.nowMs(),
    }) catch return null;
    return token;
}

pub fn acceptsOp(self: *WebFace, kind: AutoKind, request: u32) bool {
    if (!self.auto_legacy_quarantine.consume(@intFromEnum(kind), request)) return false;
    for (self.auto_ops.items) |op| {
        if (op.kind == kind and op.request == request) return true;
    }
    return false;
}

/// Satisfy the correlated request, or the oldest legacy request.
pub fn completeOp(self: *WebFace, kind: AutoKind, request: u32, ok: bool, text: []const u8, meta: AutoMeta) void {
    if (!self.acceptsOp(kind, request)) return;
    var idx: ?usize = null;
    for (self.auto_ops.items, 0..) |op, i| {
        if (op.kind != kind or op.request != request) continue;
        if (kind == .snapshot and op.want_full and meta.snap_kind != 0) continue;
        idx = i;
        break;
    }
    const i = idx orelse return;
    const op = self.auto_ops.orderedRemove(i);
    const owned = self.allocator.dupe(u8, text) catch return;
    if (self.auto_results.items.len >= MAX_AUTO_RESULTS) {
        const old = self.auto_results.orderedRemove(0);
        self.allocator.free(old.text);
    }
    self.auto_results.append(self.allocator, .{
        .token = op.token,
        .kind = kind,
        .ok = ok,
        .text = owned,
        .meta = meta,
    }) catch self.allocator.free(owned);
}

/// True while `token` is still waiting on the helper.
pub fn autoPending(self: *WebFace, token: u32) bool {
    for (self.auto_ops.items) |op| {
        if (op.token == token) return true;
    }
    return false;
}

/// Collect a finished result; the caller owns `text` from here.
pub fn autoTake(self: *WebFace, token: u32) ?AutoResult {
    for (self.auto_results.items, 0..) |r, i| {
        if (r.token == token) return self.auto_results.orderedRemove(i);
    }
    return null;
}

pub fn autoSnapshot(self: *WebFace, mode: u8, detail: u8, scope: u32) ?u32 {
    const token = self.autoBegin(.snapshot, mode == @intFromEnum(proto.SnapMode.full) or scope != 0) orelse return null;
    self.postSemantic(token, proto.SemSnapshotReq{
        .view = self.view,
        .mode = mode,
        .detail = detail,
        .scope = scope,
    });
    return token;
}

pub fn autoAct(self: *WebFace, id: u32, action: u8, arg: []const u8) ?u32 {
    const token = self.autoBegin(.act, false) orelse return null;
    // Guard entries only exist while the connection that minted
    // them lives (resetEpoch clears the store on ready/unavailable),
    // so store membership already implies the capability; the gate
    // is the cheap belt against a misbehaving helper.
    if (if (self.cl.has(.reader_ids)) self.readerGuard(id) else null) |guard| {
        self.postSemantic(token, proto.SemActGuarded{
            .view = self.view,
            .doc_gen = guard.doc_gen,
            .rev = guard.rev,
            .id = id,
            .guard = guard.guard,
            .action = action,
            .arg = arg,
        });
    } else {
        self.postSemantic(token, proto.SemAction{ .view = self.view, .id = id, .action = action, .arg = arg });
    }
    return token;
}

pub fn autoExpand(self: *WebFace, id: u32, off: u32, len: u32) ?u32 {
    const token = self.autoBegin(.expand, false) orelse return null;
    self.postSemantic(token, proto.SemExpand{ .view = self.view, .id = id, .off = off, .len = len });
    return token;
}

pub fn autoQuery(self: *WebFace, kind: u8, arg: []const u8) ?u32 {
    const token = self.autoBegin(.query, false) orelse return null;
    self.postSemantic(token, proto.SemQueryReq{ .view = self.view, .kind = kind, .arg = arg });
    return token;
}

pub fn autoRead(self: *WebFace) ?u32 {
    const token = self.autoBegin(.read, false) orelse return null;
    if (self.cl.has(.reader_ids))
        self.postSemantic(token, proto.SemReadIds{ .view = self.view })
    else
        self.postSemantic(token, proto.SemRead{ .view = self.view });
    return token;
}

pub fn readerGuard(self: *const WebFace, id: u32) ?reader_guards.Entry {
    return self.reader_guards.get(id);
}

pub fn invalidateReaderGuards(self: *WebFace) void {
    self.reader_guards.invalidate();
}

pub fn onReadIds(self: *WebFace, ev: proto.SemReadIdsResult, request: u32) void {
    if (!self.acceptsOp(.read, request)) return;
    _ = self.reader_guards.apply(self.allocator, request, ev) catch return;
    const json = reader_model.stringifyWire(self.allocator, ev) catch return;
    defer self.allocator.free(json);
    self.completeOp(.read, request, true, json, .{ .doc_gen = ev.doc_gen, .rev = ev.rev, .reader_ids = true });
}

/// `max_str` is the caller's per-string serialization budget (0 =
/// the page-side default); see `proto.SemEval`.
pub fn autoEval(self: *WebFace, code: []const u8, want_await: bool, timeout_ms: u32, max_str: u32) ?u32 {
    const token = self.autoBegin(.eval, false) orelse return null;
    self.postSemantic(token, proto.SemEval{
        .view = self.view,
        .flags = if (want_await) proto.eval_flag_await else 0,
        .timeout_ms = timeout_ms,
        .code = .{ .s = code },
        .max_str = max_str,
    });
    return token;
}

pub fn postSemantic(self: *WebFace, token: u32, value: anytype) void {
    if (!self.cl.has(.semantic_request_ids)) {
        self.cl.post(value);
        return;
    }
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(self.allocator);
    const wrapped = proto.semRequestWrap(self.allocator, &payload, token, value) catch return;
    self.cl.post(wrapped);
}

/// Pull recent network-log entries (`intercept_log`), answered
/// through the same token/`web-result` path the semantic ops use.
pub fn autoNetworkLog(self: *WebFace, since: u32, max: u16) ?u32 {
    const token = self.autoBegin(.network, false) orelse return null;
    self.cl.post(proto.InterceptLogReq{ .view = self.view, .since = since, .max = max });
    return token;
}

/// Enable/disable blocking for THIS view (the per-site toggle). The
/// daemon-side per-site store is a separate integration point (see
/// `netStoreApply`); this only moves the live helper state.
pub fn setNetwork(self: *WebFace, enabled: bool) void {
    if (!self.view_live) return;
    self.net_enabled = enabled;
    self.cl.post(proto.InterceptSet{ .view = self.view, .enabled = if (enabled) 1 else 0 });
    self.updateShield();
}

pub fn netCounters(self: *WebFace) struct { enabled: bool, blocked: u32, total: u32, rules: u32 } {
    return .{ .enabled = self.net_enabled, .blocked = self.net_blocked, .total = self.net_total, .rules = self.net_rules };
}

/// A coalesced `intercept_status` arrived: refresh the badge.
pub fn onInterceptStatus(self: *WebFace, ev: proto.InterceptStatus) void {
    self.net_enabled = ev.enabled != 0;
    self.net_blocked = ev.blocked;
    self.net_total = ev.total;
    self.net_rules = ev.rules;
    self.updateShield();
}

pub fn onInterceptLog(self: *WebFace, ev: proto.InterceptLog) void {
    self.net_next_seq = ev.next_seq;
    const json = proto.netLogJson(self.allocator, ev.next_seq, ev.entries) catch return;
    defer self.allocator.free(json);
    self.completeOp(.network, 0, true, json, .{});
}

/// The daemon-side per-site store's entry point: called with the
/// remembered decision for the page's site on every origin change
/// (`onSiteReply`), including the "no override, back to the global
/// default" case — a view walks many sites and the previous one's
/// answer must not stick. Idempotent, so re-applying the default
/// costs no round trip.
pub fn netStoreApply(self: *WebFace, enabled: bool) void {
    if (enabled == self.net_enabled) return;
    self.setNetwork(enabled);
}

pub fn updateShield(self: *WebFace) void {
    if (self.widgets_dead) return;
    var buf: [32]u8 = undefined;
    const txt = if (!self.net_enabled)
        std.fmt.bufPrintZ(&buf, "off", .{}) catch "off"
    else if (self.net_blocked > 0)
        std.fmt.bufPrintZ(&buf, "{d}", .{self.net_blocked}) catch "0"
    else
        std.fmt.bufPrintZ(&buf, "0", .{}) catch "0";
    c.gtk_label_set_text(@ptrCast(self.shield_label), txt.ptr);
    self.refreshSiteInfo(false);
    var tip: [128]u8 = undefined;
    const t = std.fmt.bufPrintZ(&tip, "Content blocking: {s} ({d} blocked of {d} requests, {d} rules)", .{
        if (self.net_enabled) "on" else "off",
        self.net_blocked,
        self.net_total,
        self.net_rules,
    }) catch "Content blocking";
    c.gtk_widget_set_tooltip_text(self.shield_btn, t.ptr);
}

pub const onSiteInfo = wf_site.onSiteInfo;
pub const showSiteInfo = wf_site.showSiteInfo;
pub const onRouteButton = wf_site.onRouteButton;
pub const showRouteMenu = wf_site.showRouteMenu;
pub const appendRouteRows = wf_site.appendRouteRows;
pub const onMenuTorTab = wf_site.onMenuTorTab;
pub const chooseRoute = wf_site.chooseRoute;
pub const routeToast = wf_site.routeToast;
pub const refreshSiteInfo = wf_site.refreshSiteInfo;
pub const tlsState = wf_site.tlsState;
pub const updateSiteButton = wf_site.updateSiteButton;
pub const nextSiteReq = wf_site.nextSiteReq;
pub const siteDataUsable = wf_site.siteDataUsable;
pub const requestCookies = wf_site.requestCookies;
pub const deleteCookie = wf_site.deleteCookie;
pub const clearCookies = wf_site.clearCookies;
pub const clearSiteData = wf_site.clearSiteData;
pub const forgetSitePermission = wf_site.forgetSitePermission;
pub const storeOrigin = wf_site.storeOrigin;
pub const setBlockingForSite = wf_site.setBlockingForSite;
pub const onCookies = wf_site.onCookies;
pub const onSitedataDone = wf_site.onSitedataDone;

/// Wheel scrolling through the ORDINARY input path, at the last
/// pointer position — the same frame an interactive scroll sends.
pub fn autoScroll(self: *WebFace, dx: i32, dy: i32) bool {
    if (!self.view_live) return false;
    self.cl.post(proto.InputScroll{
        .view = self.view,
        .x = self.last_x,
        .y = self.last_y,
        .dx = dx,
        .dy = dy,
        .mods = 0,
    });
    return true;
}

/// The full text of the last eval result, which a truncated tool
/// reply pages through `web_expand [0]`.
pub fn lastEval(self: *WebFace) ?[]const u8 {
    return self.last_eval;
}

pub const startHints = wf_hints.startHints;
pub const onHintsResult = wf_hints.onHintsResult;
pub const buildHints = wf_hints.buildHints;
pub const cancelHints = wf_hints.cancelHints;
pub const hintsKey = wf_hints.hintsKey;
pub const refilterHints = wf_hints.refilterHints;
pub const soleVisibleHint = wf_hints.soleVisibleHint;
pub const activateHint = wf_hints.activateHint;
