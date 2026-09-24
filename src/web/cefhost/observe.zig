//! Watch-along, split out of `cefhost.zig`: the Wayland presenter
//! (capability "presenter") and observer subscriptions (capability
//! "observe", 0xF0 block) that let one client watch another's views.
//! The `Host` methods are free functions taking `*Host`, re-exported
//! from `Host` under their old names.

const presenter = @import("../presenter.zig");
const proto = @import("../protocol.zig");
const host_mod = @import("../cefhost.zig");
const Host = host_mod.Host;
const Sub = host_mod.Sub;
const View = host_mod.View;
const max_frame_backlog = host_mod.max_frame_backlog;
const presenterKey = host_mod.presenterKey;
const presenterPointer = host_mod.presenterPointer;
const presenterScroll = host_mod.presenterScroll;

// -- presenter -----------------------------------------------------

/// Arm the Wayland presenter when the environment asks for it.
/// Called once by the server after `install`; a helper that is not
/// a session client gets null and never presents.
pub fn presenterStart(self: *Host) void {
    self.presenter = presenter.Presenter.start(self.gpa, .{
        .ctx = self,
        .pointer = presenterPointer,
        .scroll = presenterScroll,
        .key = presenterKey,
    });
}

/// Whether the presenter came up, for `hello_ack` (a reported fact,
/// never inferred from the environment by a client).
pub fn presenterActive(self: *const Host) bool {
    const p = self.presenter orelse return false;
    return p.active;
}

/// The display fd for the server's poll set; -1 when none.
pub fn presenterFd(self: *const Host) c_int {
    const p = self.presenter orelse return -1;
    return p.pollFd();
}

pub fn presenterWantsWrite(self: *const Host) bool {
    const p = self.presenter orelse return false;
    return p.wantsWrite();
}

/// One poll turn of display service; a disarmed presenter is freed
/// here so its fd leaves the poll set.
pub fn presenterPump(self: *Host) void {
    const p = self.presenter orelse return;
    p.pump();
    if (!p.active) {
        p.deinit();
        self.presenter = null;
    }
}

/// Views a human may watch: pages, never engine chrome. Background
/// pages and action popups belong to extensions, inspectors are
/// engine UI, and a windowed inspector has no frames at all.
pub fn presentable(v: *const View) bool {
    return !v.webext_bg and !v.webext_popup and v.devtools_of == 0 and !v.windowed;
}

// -- observers (capability "observe") ------------------------------
//
// A second connection watching, and optionally driving, a view it
// does not own. The owner's paths are untouched: every hook below
// is a side channel off the existing event, and the observer's own
// frames reach the target through `dispatch_alias` (see `find`).

/// The subscription `conn` holds under the engine-global alias id,
/// if any.
pub fn aliasOf(self: *Host, conn: u32, alias: u32) ?*Sub {
    if (conn == 0 or alias == 0) return null;
    for (self.subs.items) |*s| {
        if (s.conn == conn and s.alias == alias) return s;
    }
    return null;
}

pub fn isObserver(self: *const Host, conn: u32) bool {
    for (self.observers.items) |o| {
        if (o == conn) return true;
    }
    return false;
}

/// Whether `v` is a page another connection may observe: a
/// presentable view with an owner (owner 0 is the routerless
/// single-client shape, where nobody else exists to observe it).
pub fn observable(v: *const View) bool {
    return v.owner != 0 and presentable(v);
}

/// The alias id in the observer's OWN namespace, what its frames
/// carry.
pub fn aliasWire(sub: *const Sub) u32 {
    return sub.alias - sub.conn * proto.CONN_ID_WINDOW;
}

pub fn observerOut(self: *Host, conn: u32) ?*proto.Outbox {
    const rt = self.router orelse return null;
    return rt.route(rt.ctx, conn);
}

pub fn announceTo(self: *Host, conn: u32, v: *const View, state: u8) void {
    const out = self.observerOut(conn) orelse return;
    out.post(proto.EvObserveView{
        .target = v.id,
        .owner = v.owner,
        .state = state,
        .opener = if (v.page_popup) v.opener_view else 0,
        .w = v.w,
        .h = v.h,
        .scale_x1000 = v.scale_x1000,
        .url = v.url,
        .title = v.title,
    }, null) catch {};
}

/// `observe_enable` from `conn`: start or stop the announcements.
/// Starting replays every observable page of every OTHER
/// connection, in table order.
pub fn observeEnable(self: *Host, conn: u32, enable: bool) void {
    if (conn == 0) return;
    const was = self.isObserver(conn);
    if (!enable) {
        if (!was) return;
        for (self.observers.items, 0..) |o, i| {
            if (o == conn) {
                _ = self.observers.swapRemove(i);
                break;
            }
        }
        return;
    }
    if (!was) self.observers.append(self.gpa, conn) catch return;
    for (self.views.items) |v| {
        if (!observable(v) or v.owner == conn) continue;
        self.announceTo(conn, v, proto.observe_view_present);
    }
}

/// A page came into existence (browser spawned): tell every
/// announcing connection but its owner.
pub fn observeViewPresent(self: *Host, v: *const View) void {
    if (!observable(v)) return;
    for (self.observers.items) |o| {
        if (o == v.owner) continue;
        self.announceTo(o, v, proto.observe_view_present);
    }
}

/// A page is leaving the table: end every subscription on it and
/// announce it gone. Runs BEFORE `freeView`, while `v` is intact.
pub fn observeViewGone(self: *Host, v: *const View, reason: []const u8) void {
    var i: usize = 0;
    while (i < self.subs.items.len) {
        const s = self.subs.items[i];
        if (s.target != v.id) {
            i += 1;
            continue;
        }
        self.postObserveState(&s, v, proto.observe_ended, reason);
        _ = self.subs.orderedRemove(i);
    }
    if (!observable(v)) return;
    for (self.observers.items) |o| {
        if (o == v.owner) continue;
        self.announceTo(o, v, proto.observe_view_gone);
    }
}

pub fn postObserveState(self: *Host, sub: *const Sub, v: ?*const View, state: u8, reason: []const u8) void {
    const out = self.observerOut(sub.conn) orelse return;
    out.post(proto.EvObserveState{
        .view = aliasWire(sub),
        .target = sub.target,
        .state = state,
        .control = if (sub.control) 1 else 0,
        .w = if (v) |vv| vv.w else 0,
        .h = if (v) |vv| vv.h else 0,
        .scale_x1000 = if (v) |vv| vv.scale_x1000 else 0,
        .reason = reason,
    }, null) catch {};
}

/// `observe_subscribe` from `conn`: `alias` is already engine-global
/// (the edge windowed it). Refusals are answered, never silent.
pub fn observeSubscribe(self: *Host, conn: u32, alias: u32, target: u32, control: bool) void {
    if (conn == 0 or alias == 0) return;
    const probe = Sub{ .conn = conn, .alias = alias, .target = target, .control = control };
    if (self.findAny(alias) != null or self.aliasOf(conn, alias) != null) {
        self.postObserveState(&probe, null, proto.observe_refused, "the alias id is already in use");
        return;
    }
    const v = self.findAny(target) orelse {
        self.postObserveState(&probe, null, proto.observe_refused, "no such view");
        return;
    };
    if (!observable(v) or v.owner == conn) {
        self.postObserveState(&probe, null, proto.observe_refused, "that view cannot be observed");
        return;
    }
    self.subs.append(self.gpa, probe) catch {
        self.postObserveState(&probe, null, proto.observe_refused, "out of memory");
        return;
    };
    const sub = &self.subs.items[self.subs.items.len - 1];
    self.postObserveState(sub, v, proto.observe_subscribed, "");
    self.seedObserver(sub, v);
}

/// What a subscriber needs to draw the page as it is right now:
/// its navigation state, its title, and the whole surface.
pub fn seedObserver(self: *Host, sub: *Sub, v: *View) void {
    const out = self.observerOut(sub.conn) orelse return;
    out.post(proto.EvNavState{
        .view = aliasWire(sub),
        .can_back = if (v.nav_back) 1 else 0,
        .can_fwd = if (v.nav_fwd) 1 else 0,
        .loading = if (v.nav_loading) 1 else 0,
        .url = v.url,
    }, null) catch {};
    if (v.title.len != 0) out.post(proto.EvTitle{ .view = aliasWire(sub), .title = v.title }, null) catch {};
    if (v.map.len != 0 and !v.buf_unpainted) {
        sub.dirty = .{ .x = 0, .y = 0, .w = v.pw, .h = v.ph };
        self.flushSub(sub, v);
    }
}

/// `observe_control`: flip the lease of a live alias.
pub fn observeControl(self: *Host, conn: u32, alias: u32, control: bool) void {
    const sub = self.aliasOf(conn, alias) orelse {
        const probe = Sub{ .conn = conn, .alias = alias, .target = 0, .control = control };
        self.postObserveState(&probe, null, proto.observe_refused, "no such alias");
        return;
    };
    sub.control = control;
    self.postObserveState(sub, self.findAny(sub.target), proto.observe_subscribed, "");
}

/// `view_destroy` on an alias: drop the subscription only. The
/// target is the owner's and keeps living.
pub fn observeUnsubscribe(self: *Host, conn: u32, alias: u32) void {
    for (self.subs.items, 0..) |s, i| {
        if (s.conn == conn and s.alias == alias) {
            _ = self.subs.orderedRemove(i);
            return;
        }
    }
}

/// `view_hide` / `view_show` on an alias: the observer's own pause.
/// Resuming re-seeds the whole surface, since paints were skipped.
pub fn observePause(self: *Host, conn: u32, alias: u32, paused: bool) void {
    const sub = self.aliasOf(conn, alias) orelse return;
    sub.paused = paused;
    if (paused) {
        sub.dirty = null;
        return;
    }
    const v = self.findAny(sub.target) orelse return;
    if (v.map.len != 0 and !v.buf_unpainted) {
        sub.dirty = .{ .x = 0, .y = 0, .w = v.pw, .h = v.ph };
        self.flushSub(sub, v);
    }
}

/// The target's logical geometry changed: every subscriber is told,
/// so its letterbox and input mapping follow.
pub fn observeGeometry(self: *Host, v: *const View) void {
    for (self.subs.items) |*s| {
        if (s.target == v.id) self.postObserveState(s, v, proto.observe_subscribed, "");
    }
}

/// A connection left: its subscriptions and its announcement flag
/// go with it. Its OWN views are destroyed by `dropConn`'s sweep,
/// which ends every subscription on them.
pub fn observeDropConn(self: *Host, conn: u32) void {
    var i: usize = 0;
    while (i < self.subs.items.len) {
        if (self.subs.items[i].conn == conn) {
            _ = self.subs.orderedRemove(i);
        } else i += 1;
    }
    for (self.observers.items, 0..) |o, k| {
        if (o == conn) {
            _ = self.observers.swapRemove(k);
            break;
        }
    }
}

/// New pixels landed in `v.map`: widen every subscriber's pending
/// damage and ship what the backpressure allows. Union rather than
/// queue, exactly like the owner's inline path.
pub fn observeDamage(self: *Host, v: *View, rects: []const proto.Rect) void {
    if (self.subs.items.len == 0) return;
    for (self.subs.items) |*s| {
        if (s.target != v.id or s.paused) continue;
        for (rects) |r| unionSubDirty(s, r);
        self.flushSub(s, v);
    }
}

pub fn unionSubDirty(s: *Sub, r: proto.Rect) void {
    const d = s.dirty orelse {
        s.dirty = r;
        return;
    };
    const x0 = @min(d.x, r.x);
    const y0 = @min(d.y, r.y);
    const x1 = @max(@as(u32, d.x) + d.w, @as(u32, r.x) + r.w);
    const y1 = @max(@as(u32, d.y) + d.h, @as(u32, r.y) + r.h);
    s.dirty = .{ .x = x0, .y = y0, .w = @intCast(x1 - x0), .h = @intCast(y1 - y0) };
}

/// Ship a subscriber's pending damage as inline bands, unless its
/// outbox is backed up (then the union waits for the next flush).
pub fn flushSub(self: *Host, s: *Sub, v: *View) void {
    const d = s.dirty orelse return;
    if (v.map.len == 0) {
        s.dirty = null;
        return;
    }
    const out = self.observerOut(s.conn) orelse {
        s.dirty = null;
        return;
    };
    if (out.pending() >= max_frame_backlog) return;
    s.dirty = null;
    self.shipInline(v, d, out, aliasWire(s));
}

/// The drain-side half for observers: called once per poll beside
/// `flushInline`, so damage held back by backpressure goes out.
pub fn flushObservers(self: *Host) void {
    for (self.subs.items) |*s| {
        if (s.dirty == null or s.paused) continue;
        const v = self.findAny(s.target) orelse continue;
        self.flushSub(s, v);
    }
}

/// New pixels landed in `v.map`: mirror them to the toplevel.
pub fn presentPaint(self: *Host, v: *View, rects: []const proto.Rect) void {
    const p = self.presenter orelse return;
    if (!presentable(v)) return;
    p.paint(v.id, v.pw, v.ph, v.scale_x1000, v.map, rects);
}

pub fn presentTitle(self: *Host, v: *View, title: []const u8) void {
    const p = self.presenter orelse return;
    if (!presentable(v)) return;
    p.setTitle(v.id, title);
}
