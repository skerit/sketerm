//! Watching an assistant's browser AS A BROWSER: the assistant's pages
//! open as ordinary web pages (`WebFace`, full chrome) in a web tab of
//! this window, because the GUI becomes a second CLIENT of the
//! assistant's own `sketerm-webengine` and OBSERVES its views
//! (capability "observe", `src/web/protocol.zig` CAP_OBSERVE).
//!
//! One `Watch` per (window, assistant browser). It owns an observer
//! `webface.Client` connected to the helper socket beside the
//! assistant's mux socket (`<instance dir>/web.sock`, or the routed
//! `web-<slug>.sock` whose presence file names the session), or, for a
//! remote assistant, a bridged connection the remote daemon opened
//! with `web_helper_connect`. The helper announces every page the
//! assistant has; each becomes a page of the watch's browser tab,
//! subscribed under an alias id this GUI minted, and every later page
//! the assistant opens is added the same way. Watch is a read-only
//! subscription; Take control flips the lease with `observe_control`,
//! after which this GUI's input drives the page exactly as the
//! assistant's own trusted input does. Neither ever RESIZES,
//! discards or destroys the assistant's view: closing the tab drops
//! the subscription and nothing else, and a page the assistant closes
//! ends here too.
//!
//! Lifetimes: pages are faces of the pane's `webgroup.Group`, which
//! frees them with the pane; each face tells its watch on deinit
//! (`onFaceGone`), and the watch that loses its last page closes the
//! observer connection and frees itself. Every callback from the
//! client resolves the watch through `Client.watch`, which the watch
//! nulls before freeing itself (the nullable back-pointer fence).

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const proto = @import("../web/protocol.zig");
const webpresence = @import("../web/webpresence.zig");
const webface = @import("webface.zig");
const webgroup = @import("webgroup.zig");
const muxtabs = @import("muxtabs.zig");
const remotectl = @import("remotectl.zig");
const winmod = @import("window.zig");
const Window = winmod.Window;
const Pane = @import("pane.zig").Pane;

/// Longest assistant label and key the watch keeps; anything longer
/// is truncated for display and refused as a key.
const MAX_LABEL = 128;
const MAX_KEY = 384;

pub const Watch = struct {
    allocator: std.mem.Allocator,
    win: *Window,
    cl: *webface.Client,
    /// Assistant display name, owned.
    label: []u8,
    /// Identity of the helper this watch observes (`sock:<path>` or
    /// `host:<host>|<session>`), owned; what makes a second Watch on
    /// the same assistant focus the first instead.
    key: []u8,
    lease: muxtabs.Lease,
    pane: ?*Pane = null,
    pane_id: u32 = 0,
    pages: std.ArrayList(Page) = .empty,
    /// Set once teardown started, so a page closing during it does not
    /// re-enter.
    closing: bool = false,

    const Page = struct {
        target: u32,
        view: u32,
        face: *webface.WebFace,
    };

    fn pageByView(self: *Watch, view: u32) ?*Page {
        for (self.pages.items) |*p| if (p.view == view) return p;
        return null;
    }

    fn pageByTarget(self: *Watch, target: u32) ?*Page {
        for (self.pages.items) |*p| if (p.target == target) return p;
        return null;
    }

    /// The assistant's name, for chips and toasts.
    pub fn labelSlice(self: *const Watch) []const u8 {
        return self.label;
    }

    /// Change the lease of every page: `observe_control` per alias;
    /// the helper answers each with its state and the chip follows.
    pub fn setLease(self: *Watch, lease: muxtabs.Lease) void {
        self.lease = lease;
        for (self.pages.items) |p| p.face.postObserveControl(lease == .control);
        if (self.pane) |pane| pane.refreshLeaseChip();
    }

    /// Bring the watch's tab forward.
    pub fn focus(self: *Watch) void {
        const pane = self.pane orelse return;
        muxtabs.focusPaneTab(self.win, pane);
    }

    /// A page announced by the helper: mint an alias, subscribe, and
    /// give it a face in this watch's browser tab (creating the tab for
    /// the first page).
    fn addPage(self: *Watch, ev: proto.EvObserveView) void {
        if (self.closing) return;
        if (self.pageByTarget(ev.target) != null) return;
        const view = webface.mintViewId();
        self.cl.post(proto.ObserveSubscribe{
            .view = view,
            .target = ev.target,
            .control = if (self.lease == .control) 1 else 0,
        });
        const face: *webface.WebFace = blk: {
            if (self.pane) |pane| {
                const g = webgroup.Group.fromPane(pane) orelse break :blk null;
                break :blk webface.WebFace.attachObservedPage(self.allocator, g, view, self.cl, self) catch null;
            }
            const pane = self.win.newWebTabObserving(self, view) catch break :blk null;
            self.pane = pane;
            self.pane_id = pane.id;
            break :blk webface.WebFace.fromPane(pane);
        } orelse {
            // No face to present it in: let the helper forget the alias
            // rather than stream frames at nobody.
            self.cl.post(proto.ViewDestroy{ .view = view });
            return;
        };
        face.seedObserved(ev.w, ev.h, ev.scale_x1000, ev.url, ev.title);
        self.pages.append(self.allocator, .{ .target = ev.target, .view = view, .face = face }) catch {
            face.closeSelf();
            return;
        };
        if (self.pane) |pane| pane.refreshLeaseChip();
    }

    fn onState(self: *Watch, ev: proto.EvObserveState) void {
        const page = self.pageByView(ev.view) orelse return;
        switch (ev.state) {
            proto.observe_subscribed => page.face.onObserved(ev.w, ev.h, ev.scale_x1000, ev.control != 0),
            proto.observe_refused => page.face.observeRefused(ev.reason),
            proto.observe_ended => page.face.closeSelf(),
            else => {},
        }
        if (self.pane) |pane| pane.refreshLeaseChip();
    }

    /// A face of this watch is being freed (the page ended, or the
    /// user closed it or the tab). The last one takes the watch down.
    pub fn onFaceGone(self: *Watch, face: *webface.WebFace) void {
        for (self.pages.items, 0..) |p, i| {
            if (p.face == face) {
                _ = self.pages.orderedRemove(i);
                break;
            }
        }
        if (self.pages.items.len != 0 or self.closing) return;
        self.closing = true;
        // The pane may be mid-teardown (the user closed the tab) or
        // alive with its shell showing again (the assistant closed its
        // last page): resolve it by id on an idle turn and close it if
        // it is still there, never from inside a face's deinit.
        const ctx = self.allocator.create(CloseCtx) catch null;
        if (ctx) |cx| {
            cx.* = .{ .allocator = self.allocator, .win = self.win, .pane_id = self.pane_id };
            _ = c.g_idle_add(@ptrCast(&closeIdle), @ptrCast(cx));
        }
        self.teardown();
    }

    const CloseCtx = struct { allocator: std.mem.Allocator, win: *Window, pane_id: u32 };

    fn closeIdle(user: ?*anyopaque) callconv(.c) c.gboolean {
        const cx = cast.userData(CloseCtx, user);
        defer cx.allocator.destroy(cx);
        // Resolved through the live GTK windows, never through the
        // stored pointer: the window may have closed meanwhile.
        const app: ?*c.GtkApplication = @ptrCast(@alignCast(c.g_application_get_default()));
        const ref = remotectl.windowForPane(app, cx.pane_id) orelse return 0;
        if (ref.win != cx.win) return 0;
        // Only a pane that no longer shows a browser is ours to close:
        // a new watch may already have re-used it.
        if (webgroup.Group.fromPane(ref.pane) != null) return 0;
        ref.win.closePane(ref.pane);
        return 0;
    }

    /// The observer connection is gone (the assistant exited, or its
    /// helper died): every page ends.
    fn onLost(self: *Watch) void {
        if (self.closing) return;
        var msg: [MAX_LABEL + 320]u8 = undefined;
        const why = if (self.cl.reason.len != 0) self.cl.reason else "browser closed";
        winmod.showToast(self.win, std.fmt.bufPrint(&msg, "{s}: {s}", .{ self.label, why }) catch "Assistant browser closed");
        // closeSelf frees the face, which calls onFaceGone, which
        // removes the page; closing the LAST page frees the group and
        // with it every remaining face, and then THIS watch. So: one
        // page per turn, from the back, never past the last.
        while (self.pages.items.len != 0) {
            const before = self.pages.items.len;
            const face = self.pages.items[before - 1].face;
            face.closeSelf();
            if (before == 1) return; // self is gone
            if (self.pages.items.len == before) break; // a group mid-teardown; it frees them
        }
        if (!self.closing) {
            self.closing = true;
            self.teardown();
        }
    }

    fn teardown(self: *Watch) void {
        self.cl.watch = null;
        self.cl.stopObserving();
        // The group may outlive the watch (the assistant closed its
        // last page and the pane shows its shell until the idle above
        // closes it): its chip must not resolve a freed watch.
        if (self.pane) |pane| {
            if (webgroup.Group.fromPane(pane)) |g| {
                if (g.watch == @as(?*anyopaque, @ptrCast(self))) g.watch = null;
            }
        }
        for (self.win.web_watches.items, 0..) |w, i| {
            if (w == self) {
                _ = self.win.web_watches.orderedRemove(i);
                break;
            }
        }
        self.pages.deinit(self.allocator);
        self.allocator.free(self.label);
        self.allocator.free(self.key);
        self.allocator.destroy(self);
    }
};

/// What a window already shows for an assistant's browser, for the
/// chip and Overview buttons: nothing, or a watch under `lease`.
pub const Placement = union(enum) { none, watching: muxtabs.Lease };

/// The watch this window holds on `key`, if any.
fn find(win: *Window, key: []const u8) ?*Watch {
    for (win.web_watches.items) |w| {
        if (std.mem.eql(u8, w.key, key)) return w;
    }
    return null;
}

pub fn placementLocal(win: *Window, mux_socket: []const u8, session: []const u8) Placement {
    var key_buf: [MAX_KEY]u8 = undefined;
    const key = localKey(&key_buf, mux_socket, session) orelse return .none;
    const w = find(win, key) orelse return .none;
    return .{ .watching = w.lease };
}

pub fn placementRemote(win: *Window, host: []const u8, session: []const u8) Placement {
    var key_buf: [MAX_KEY]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "host:{s}|{s}", .{ host, session }) catch return .none;
    const w = find(win, key) orelse return .none;
    return .{ .watching = w.lease };
}

/// `sock:<helper socket>` for a LOCAL assistant session, resolved
/// through the presence files beside its mux socket.
fn localKey(buf: []u8, mux_socket: []const u8, session: []const u8) ?[]const u8 {
    var sock_buf: [webpresence.MAX_PATH]u8 = undefined;
    const sock = webpresence.helperSocketFor(&sock_buf, mux_socket, session) orelse return null;
    return std.fmt.bufPrint(buf, "sock:{s}", .{sock}) catch null;
}

/// Watch (or take control of) a LOCAL assistant's browser: the
/// assistant whose private daemon is `mux_socket`, its web session
/// `session`. An existing watch is focused and, for `.control`,
/// escalated. Returns false when nothing could be started.
pub fn openLocal(win: *Window, label: []const u8, mux_socket: []const u8, session: []const u8, lease: muxtabs.Lease) bool {
    var key_buf: [MAX_KEY]u8 = undefined;
    const key = localKey(&key_buf, mux_socket, session) orelse return false;
    if (find(win, key)) |w| return reuse(w, lease);
    const cl = webface.observerClient(win.allocator, .{ .local = key["sock:".len..] }) orelse return false;
    return start(win, cl, label, key, lease);
}

/// Same for an assistant on a REMOTE mux host (`host` in the mux host
/// vocabulary): the remote daemon connects to the helper serving
/// `session` beside its own socket and bridges it.
pub fn openRemote(win: *Window, label: []const u8, host: []const u8, session: []const u8, lease: muxtabs.Lease) bool {
    var key_buf: [MAX_KEY]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "host:{s}|{s}", .{ host, session }) catch return false;
    if (find(win, key)) |w| return reuse(w, lease);
    const cl = webface.observerClient(win.allocator, .{ .remote = .{ .host = host, .session = session } }) orelse return false;
    return start(win, cl, label, key, lease);
}

fn reuse(w: *Watch, lease: muxtabs.Lease) bool {
    if (lease == .control and w.lease != .control) w.setLease(.control);
    w.focus();
    return true;
}

fn start(win: *Window, cl: *webface.Client, label: []const u8, key: []const u8, lease: muxtabs.Lease) bool {
    const allocator = win.allocator;
    const w = allocator.create(Watch) catch return false;
    const label_owned = allocator.dupe(u8, label[0..@min(label.len, MAX_LABEL)]) catch {
        allocator.destroy(w);
        return false;
    };
    const key_owned = allocator.dupe(u8, key) catch {
        allocator.free(label_owned);
        allocator.destroy(w);
        return false;
    };
    w.* = .{
        .allocator = allocator,
        .win = win,
        .cl = cl,
        .label = label_owned,
        .key = key_owned,
        .lease = if (lease == .default) .read_only else lease,
    };
    win.web_watches.append(allocator, w) catch {
        allocator.free(label_owned);
        allocator.free(key_owned);
        allocator.destroy(w);
        return false;
    };
    // Connect BEFORE the watch is reachable from the client: a
    // synchronous failure (no socket, no helper) must not call back
    // into a watch that `start` is still holding.
    cl.ensure(allocator);
    if (cl.state == .unavailable) {
        var msg: [320]u8 = undefined;
        winmod.showToast(win, std.fmt.bufPrint(&msg, "{s}: {s}", .{ w.label, cl.reason }) catch cl.reason);
        w.closing = true;
        w.teardown();
        return false;
    }
    cl.watch = @ptrCast(w);
    return true;
}

// -- callbacks from the observer client (all main thread) -------------

fn watchOf(cl: *webface.Client) ?*Watch {
    const p = cl.watch orelse return null;
    return @ptrCast(@alignCast(p));
}

pub fn onObserveView(cl: *webface.Client, ev: proto.EvObserveView) void {
    const w = watchOf(cl) orelse return;
    switch (ev.state) {
        proto.observe_view_present => w.addPage(ev),
        proto.observe_view_gone => if (w.pageByTarget(ev.target)) |p| p.face.closeSelf(),
        else => {},
    }
}

pub fn onObserveState(cl: *webface.Client, ev: proto.EvObserveState) void {
    const w = watchOf(cl) orelse return;
    w.onState(ev);
}

pub fn onClientLost(cl: *webface.Client) void {
    const w = watchOf(cl) orelse return;
    w.onLost();
}

/// The lease chip's text for a pane whose browser is a watch, and
/// whether its Take control button applies. Null when the group has no
/// watch. `buf` receives the text.
pub fn chipText(g: *webgroup.Group, buf: []u8) ?struct { text: []const u8, view_only: bool } {
    const w: *Watch = @ptrCast(@alignCast(g.watch orelse return null));
    return switch (w.lease) {
        .control => .{
            .text = std.fmt.bufPrint(buf, "Controlling {s}'s browser", .{w.label}) catch "Controlling the assistant's browser",
            .view_only = false,
        },
        else => .{
            .text = std.fmt.bufPrint(buf, "View only - {s} controls", .{w.label}) catch "View only",
            .view_only = true,
        },
    };
}

/// The pane's Take control button on a watch: escalate the lease.
pub fn takeControl(g: *webgroup.Group) bool {
    const w: *Watch = @ptrCast(@alignCast(g.watch orelse return false));
    w.setLease(.control);
    return true;
}
