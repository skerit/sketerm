//! GTK browser-action toolbar buttons and extension popup presentation.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const proto = @import("../web/protocol.zig");
const webface = @import("webface.zig");
const webframe = @import("webframe.zig");
const webext = @import("webext.zig");

const POPUP_W: u16 = 420;
const POPUP_H: u16 = 520;

const Action = struct {
    id: []u8,
    enabled: bool,
    popup: bool,
    button: *c.GtkWidget,

    fn deinit(self: *Action, gpa: std.mem.Allocator) void {
        gpa.free(self.id);
    }
};

const Incoming = struct {
    id: []const u8 = "",
    title: []const u8 = "",
    icon: []const u8 = "",
    badge: []const u8 = "",
    badgeTextColor: [4]u8 = .{ 255, 255, 255, 255 },
    badgeBackgroundColor: [4]u8 = .{ 204, 34, 51, 255 },
    enabled: bool = true,
    popup: bool = false,
};

pub const Toolbar = struct {
    allocator: std.mem.Allocator,
    face_view: u32 = 0,
    cl: ?*webface.Client = null,
    box: *c.GtkWidget,
    actions: std.ArrayList(Action) = .empty,
    popup: ?*Popup = null,
    severed: bool = false,
    /// The popup close, indirected because the re-entrancy it can cause
    /// IS the invariant: `Popup.destroy` posts a ViewDestroy, and a post
    /// that loses the connection re-enters `refresh` through
    /// `helperGone` and frees every Action. Tests script it to prove
    /// nothing holds an `*Action` or an index across the call.
    close_popup: *const fn (*Toolbar) bool = realClosePopup,

    pub fn create(allocator: std.mem.Allocator, box: *c.GtkWidget) ?*Toolbar {
        const self = allocator.create(Toolbar) catch return null;
        self.* = .{ .allocator = allocator, .box = box };
        return self;
    }

    pub fn bindView(self: *Toolbar, view: u32, cl: *webface.Client) void {
        self.face_view = view;
        self.cl = cl;
    }

    pub fn refresh(self: *Toolbar, json: []const u8) void {
        if (self.severed) return;
        var parsed = std.json.parseFromSlice([]Incoming, self.allocator, json, .{ .ignore_unknown_fields = true }) catch return;
        defer parsed.deinit();
        // First pass: retire the open popup. Closing it posts a
        // ViewDestroy, and a post that loses the connection re-enters
        // here (helperGone -> refresh -> clearActions) and frees every
        // Action, so this happens before anything holds an `*Action` or
        // an index into the list.
        if (self.popup) |p| {
            if (self.popupRetired(p, parsed.value)) {
                if (!self.close_popup(self)) return;
            }
        }
        // Second pass: whether the list can be reused in place is
        // decided AFTER that close, against whatever list survived it.
        var count: usize = 0;
        var same_actions = true;
        for (parsed.value) |in| {
            if (!validId(in.id)) continue;
            if (count >= self.actions.items.len or !std.mem.eql(u8, self.actions.items[count].id, in.id))
                same_actions = false;
            count += 1;
        }
        same_actions = same_actions and count == self.actions.items.len;
        if (same_actions) {
            var idx: usize = 0;
            for (parsed.value) |in| {
                if (!validId(in.id)) continue;
                // configureButton only touches GTK, never the client,
                // so this borrow cannot outlive the list.
                self.configureButton(&self.actions.items[idx], in);
                idx += 1;
            }
            c.gtk_widget_set_visible(self.box, @intFromBool(self.actions.items.len != 0));
            return;
        }
        if (!self.close_popup(self)) return;
        self.clearActions(true);
        for (parsed.value) |in| {
            if (!validId(in.id)) continue;
            const id = self.allocator.dupe(u8, in.id) catch continue;
            const btn = c.gtk_button_new().?;
            const idx = self.actions.items.len;
            self.actions.append(self.allocator, .{
                .id = id,
                .enabled = in.enabled,
                .popup = in.popup,
                .button = btn,
            }) catch {
                self.allocator.free(id);
                c.g_object_unref(@as(?*anyopaque, @ptrCast(btn)));
                continue;
            };
            self.configureButton(&self.actions.items[idx], in);
            c.gtk_box_append(@ptrCast(self.box), btn);
            _ = c.g_object_set_data(@ptrCast(btn), "sketerm-webaction-index", @ptrFromInt(idx + 1));
            _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(&onClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        }
        c.gtk_widget_set_visible(self.box, @intFromBool(self.actions.items.len != 0));
    }

    /// Does the open popup's action lose its popup in this update? The
    /// popover is matched to its anchor button and then compared by
    /// ID, never by list position: an action that vanished entirely
    /// counts as retired too.
    fn popupRetired(self: *Toolbar, p: *Popup, incoming: []const Incoming) bool {
        for (self.actions.items) |a| {
            if (a.button != p.anchor) continue;
            for (incoming) |in| {
                if (!validId(in.id) or !std.mem.eql(u8, in.id, a.id)) continue;
                return !in.enabled or !in.popup;
            }
            return true;
        }
        return false;
    }

    /// The live action carrying `id`. The ID is the only stable handle:
    /// a refresh reallocates the list AND every button in it, so an
    /// `*Action` or an index re-resolved this way is the only one safe
    /// to use after anything that could have posted to the client.
    fn actionById(self: *Toolbar, id: []const u8) ?*Action {
        for (self.actions.items) |*a| {
            if (std.mem.eql(u8, a.id, id)) return a;
        }
        return null;
    }

    pub fn setPresented(self: *Toolbar, presented: bool) void {
        if (self.severed) return;
        if (!presented) {
            if (self.popup) |p| p.destroy(true);
        }
        c.gtk_widget_set_visible(self.box, @intFromBool(presented and self.actions.items.len != 0));
    }

    fn configureButton(self: *Toolbar, a: *Action, in: Incoming) void {
        const row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 3).?;
        c.gtk_box_append(@ptrCast(row), self.actionIcon(in.id, in.icon));
        if (in.badge.len != 0) {
            var bbuf: [32:0]u8 = @splat(0);
            const n = utf8Prefix(in.badge, bbuf.len - 1);
            @memcpy(bbuf[0..n], in.badge[0..n]);
            const badge = c.gtk_label_new(&bbuf).?;
            c.gtk_widget_add_css_class(badge, "caption");
            c.gtk_widget_add_css_class(badge, "sketerm-webext-badge");
            self.styleBadge(a, badge, in.badgeTextColor, in.badgeBackgroundColor);
            c.gtk_box_append(@ptrCast(row), badge);
        }
        c.gtk_button_set_child(@ptrCast(a.button), row);
        var tip: [256:0]u8 = @splat(0);
        const tn = utf8Prefix(in.title, tip.len - 1);
        @memcpy(tip[0..tn], in.title[0..tn]);
        c.gtk_widget_set_tooltip_text(a.button, &tip);
        c.gtk_widget_set_sensitive(a.button, @intFromBool(in.enabled));
        c.gtk_widget_add_css_class(a.button, "flat");
        a.enabled = in.enabled;
        a.popup = in.popup;
    }

    fn styleBadge(self: *Toolbar, a: *Action, badge: *c.GtkWidget, fg: [4]u8, bg: [4]u8) void {
        _ = self;
        _ = a;
        const provider = c.gtk_css_provider_new() orelse return;
        var css: [256:0]u8 = @splat(0);
        const text = std.fmt.bufPrintZ(&css,
            \\.sketerm-webext-badge {{ color: rgba({d},{d},{d},{d:.3}); background: rgba({d},{d},{d},{d:.3}); border-radius: 7px; padding: 0 4px; }}
        , .{ fg[0], fg[1], fg[2], @as(f64, @floatFromInt(fg[3])) / 255.0, bg[0], bg[1], bg[2], @as(f64, @floatFromInt(bg[3])) / 255.0 }) catch {
            c.g_object_unref(provider);
            return;
        };
        c.gtk_css_provider_load_from_string(provider, text.ptr);
        c.gtk_style_context_add_provider(
            c.gtk_widget_get_style_context(badge),
            @ptrCast(@alignCast(provider)),
            c.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
        c.g_object_unref(provider);
    }

    pub fn onPopup(self: *Toolbar, ev: proto.EvWebextPopup) void {
        const p = self.popup orelse return;
        if (p.view != ev.popup_view) return;
        if (ev.state == proto.webext_popup_error) {
            p.showError(ev.detail);
        } else if (ev.state == proto.webext_popup_closed) {
            p.closeFromHelper();
        }
    }

    pub fn openPopup(self: *Toolbar, id: []const u8) bool {
        if (self.severed) return false;
        const a = self.actionById(id) orelse return false;
        if (!a.enabled or !a.popup) return false;
        return self.activate(a);
    }

    pub fn adoptBuffer(self: *Toolbar, fb: proto.FrameBuffer, fd: c_int) bool {
        const p = self.popup orelse return false;
        if (p.view != fb.view) return false;
        p.adoptBuffer(fb, fd);
        return true;
    }

    pub fn damage(self: *Toolbar, ev: proto.FrameDamage) bool {
        const p = self.popup orelse return false;
        if (p.view != ev.view) return false;
        p.damage(ev);
        return true;
    }

    pub fn inlineFrame(self: *Toolbar, ev: proto.FrameInline) bool {
        const p = self.popup orelse return false;
        if (p.view != ev.view) return false;
        p.inlineFrame(ev);
        return true;
    }

    pub fn sever(self: *Toolbar, widgets_dead: bool) void {
        if (self.severed) return;
        self.severed = true;
        if (self.popup) |p| p.destroy(true);
        self.popup = null;
        if (!widgets_dead) {
            for (self.actions.items) |a| {
                _ = c.g_signal_handlers_disconnect_matched(
                    @ptrCast(a.button),
                    c.G_SIGNAL_MATCH_DATA,
                    0,
                    0,
                    null,
                    null,
                    @ptrCast(self),
                );
            }
        }
        self.clearActions(!widgets_dead);
    }

    pub fn helperGone(self: *Toolbar) void {
        if (self.popup) |p| {
            p.view = 0;
            p.destroy(false);
        }
        self.popup = null;
        if (!self.severed) self.refresh("[]");
    }

    pub fn destroy(self: *Toolbar) void {
        self.clearActions(!self.severed);
        self.actions.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn clearActions(self: *Toolbar, widgets_live: bool) void {
        if (widgets_live) {
            while (c.gtk_widget_get_first_child(self.box)) |child| c.gtk_box_remove(@ptrCast(self.box), child);
            c.gtk_widget_set_visible(self.box, 0);
        }
        for (self.actions.items) |*a| a.deinit(self.allocator);
        self.actions.clearRetainingCapacity();
    }

    fn actionIcon(self: *Toolbar, id: []const u8, rel: []const u8) *c.GtkWidget {
        const path = webext.assetPath(self.allocator, id, rel) orelse
            return c.gtk_image_new_from_icon_name("application-x-addon-symbolic").?;
        defer self.allocator.free(path);
        const z = self.allocator.dupeZ(u8, path) catch
            return c.gtk_image_new_from_icon_name("application-x-addon-symbolic").?;
        defer self.allocator.free(z);
        const pixbuf = c.gdk_pixbuf_new_from_file_at_size(z.ptr, 18, 18, null) orelse
            return c.gtk_image_new_from_icon_name("application-x-addon-symbolic").?;
        defer c.g_object_unref(@ptrCast(pixbuf));
        return c.gtk_image_new_from_pixbuf(pixbuf).?;
    }

    fn onClicked(btn: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(Toolbar, user);
        _ = self.cl orelse return;
        if (self.severed) return;
        const raw = c.g_object_get_data(@ptrCast(btn), "sketerm-webaction-index") orelse return;
        const idx = @intFromPtr(raw) - 1;
        if (idx >= self.actions.items.len) return;
        const a = &self.actions.items[idx];
        // The index is qdata from when the list was built, so it is
        // verified against the button that actually fired rather than
        // trusted; the alternative, an owned id per button, would buy
        // the same guarantee for an allocation and a lifetime.
        if (a.button != btn or !a.enabled) return;
        _ = self.activate(a);
    }

    fn activate(self: *Toolbar, a: *Action) bool {
        const cl = self.cl orelse return false;
        // The activation and its popup view only mean anything to a
        // helper that advertised the capability; a remote client has it
        // forced off, so this is also what keeps extension actions from
        // being driven across the mux wire.
        if (!cl.cap_webext_action or cl.state != .ready) return false;
        // Closing the previous popup posts a ViewDestroy, and a post
        // that loses the connection frees every Action (helperGone ->
        // refresh -> clearActions) and destroys their buttons with the
        // box. So the only thing carried across the close is an OWNED
        // copy of the ID, and the action is re-resolved from it after.
        // With no popup open nothing can re-enter, so that copy is paid
        // for only when there is something to close.
        var live = a;
        if (self.popup != null) {
            const id = self.allocator.dupe(u8, a.id) catch return false;
            defer self.allocator.free(id);
            if (!self.close_popup(self)) return false;
            self.popup = null;
            live = self.actionById(id) orelse return false;
        }
        if (!live.enabled) return false;
        // Capabilities belong to the CONNECTION and are cleared when it
        // is lost, so the client is re-read rather than reused.
        const conn = self.cl orelse return false;
        if (!conn.cap_webext_action or conn.state != .ready) return false;
        const popup = if (live.popup) Popup.create(self, live.button) else null;
        if (live.popup and popup == null) return false;
        self.popup = popup;
        const popup_view = if (popup) |p| p.view else 0;
        const scale = if (webface.faceByViewOn(conn, self.face_view)) |face| face.popupScale() else 1000;
        conn.post(proto.WebextActionActivate{
            .view = self.face_view,
            .id = live.id,
            .popup_view = popup_view,
            .w = POPUP_W,
            .h = POPUP_H,
            .scale_x1000 = scale,
        });
        return true;
    }

    fn post(self: *Toolbar, value: anytype) void {
        const cl = self.cl orelse return;
        cl.post(value);
    }
};

fn validId(id: []const u8) bool {
    const manifest = @import("../web/webext/manifest.zig");
    return manifest.idValid(id);
}

fn utf8Prefix(text: []const u8, max: usize) usize {
    if (text.len <= max and std.unicode.utf8ValidateSlice(text)) return text.len;
    var end = @min(text.len, max);
    while (end > 0 and !std.unicode.utf8ValidateSlice(text[0..end])) end -= 1;
    return end;
}

test "utf8Prefix never splits a codepoint" {
    try std.testing.expectEqual(@as(usize, 4), utf8Prefix("A€B", 4));
    try std.testing.expectEqual(@as(usize, 1), utf8Prefix("A€B", 3));
    try std.testing.expect(std.unicode.utf8ValidateSlice("A€B"[0..utf8Prefix("A€B", 3)]));
}

// `actionById` is the re-validation every post-crossing caller uses,
// so it is pinned here; the fake widget pointers are never touched.
test "actionById resolves by id rather than by position" {
    const gpa = std.testing.allocator;
    var tb = Toolbar{ .allocator = gpa, .box = @ptrFromInt(0x1000) };
    defer tb.actions.deinit(gpa);
    defer for (tb.actions.items) |*a| a.deinit(gpa);
    for ([_][]const u8{ "aaaa", "bbbb", "cccc" }, 0..) |name, i| {
        try tb.actions.append(gpa, .{
            .id = try gpa.dupe(u8, name),
            .enabled = true,
            .popup = false,
            .button = @ptrFromInt(0x1000 * (i + 2)),
        });
    }
    try std.testing.expectEqual(&tb.actions.items[2], tb.actionById("cccc").?);
    try std.testing.expectEqual(&tb.actions.items[0], tb.actionById("aaaa").?);
    try std.testing.expect(tb.actionById("dddd") == null);
}

/// Close the open popup, if any. False once its ViewDestroy post lost
/// the connection: helperGone has then already cleared the toolbar from
/// under the caller, whose snapshot now describes a helper that is gone,
/// so the caller must stop rather than rebuild. At file scope because it
/// is the default of `Toolbar.close_popup`.
fn realClosePopup(self: *Toolbar) bool {
    const p = self.popup orelse return true;
    p.destroy(true);
    if (self.severed) return false;
    if (self.cl) |cl| if (cl.state != .ready) return false;
    return true;
}

/// Drives the one ordering rule of `refresh`/`activate`: the popup is
/// closed BEFORE anything holds an `*Action` or an index, because the
/// close can re-enter and free the whole list. The scripted close stands
/// in for `Popup.destroy` -> post -> helperGone -> refresh("[]").
const CloseProbe = struct {
    var closes: usize = 0;
    var actions_at_close: usize = 0;

    fn reset() void {
        closes = 0;
        actions_at_close = 0;
    }

    /// The connection died in the close: every Action is freed and the
    /// caller must stop.
    fn losing(tb: *Toolbar) bool {
        closes += 1;
        actions_at_close = tb.actions.items.len;
        tb.popup = null;
        for (tb.actions.items) |*a| a.deinit(tb.allocator);
        tb.actions.clearRetainingCapacity();
        return false;
    }

    /// The connection survived, but the helper replaced the list during
    /// the close: the old storage is gone, so any surviving `*Action`
    /// is stale and the re-resolve must find the NEW, disabled entry.
    fn replacing(tb: *Toolbar) bool {
        closes += 1;
        actions_at_close = tb.actions.items.len;
        tb.popup = null;
        for (tb.actions.items) |*a| a.deinit(tb.allocator);
        tb.actions.deinit(tb.allocator);
        tb.actions = .empty;
        tb.actions.append(tb.allocator, .{
            .id = tb.allocator.dupe(u8, "aaaa") catch unreachable,
            .enabled = false,
            .popup = false,
            .button = @ptrFromInt(0x9000),
        }) catch unreachable;
        return true;
    }
};

fn fakePopup(tb: *Toolbar, anchor: *c.GtkWidget) Popup {
    return .{
        .owner = tb,
        .view = 1,
        .widget = @ptrFromInt(0x3000),
        .anchor = anchor,
        .picture = @ptrFromInt(0x4000),
        .status = @ptrFromInt(0x5000),
        .motion = undefined,
        .click = undefined,
        .scroll = undefined,
        .key = undefined,
        .focus = undefined,
    };
}

fn probeToolbar(gpa: std.mem.Allocator, close: *const fn (*Toolbar) bool) Toolbar {
    return .{ .allocator = gpa, .box = @ptrFromInt(0x1000), .close_popup = close };
}

fn addAction(tb: *Toolbar, id: []const u8, button: usize) !void {
    try tb.actions.append(tb.allocator, .{
        .id = try tb.allocator.dupe(u8, id),
        .enabled = true,
        .popup = true,
        .button = @ptrFromInt(button),
    });
}

fn dropActions(tb: *Toolbar) void {
    for (tb.actions.items) |*a| a.deinit(tb.allocator);
    tb.actions.deinit(tb.allocator);
}

test "refresh closes the popup before it borrows the action list" {
    const gpa = std.testing.allocator;
    CloseProbe.reset();
    var tb = probeToolbar(gpa, CloseProbe.losing);
    defer dropActions(&tb);
    try addAction(&tb, "aaaa", 0x2000);
    var pop = fakePopup(&tb, tb.actions.items[0].button);
    tb.popup = &pop;

    // The SAME action, only without its popup: the list is reusable in
    // place, which is exactly the path that used to take `&items[idx]`
    // and only then close the popover out from under it.
    tb.refresh("[{\"id\":\"aaaa\",\"enabled\":true,\"popup\":false}]");

    try std.testing.expectEqual(@as(usize, 1), CloseProbe.closes);
    // The close ran while the list was still the one refresh was given.
    try std.testing.expectEqual(@as(usize, 1), CloseProbe.actions_at_close);
    // And it took the list with it, so refresh stopped instead of
    // configuring a button through a freed Action.
    try std.testing.expectEqual(@as(usize, 0), tb.actions.items.len);
    try std.testing.expect(tb.popup == null);
}

test "activate re-resolves its action after the close instead of reusing it" {
    const gpa = std.testing.allocator;
    var cl = webface.Client{ .state = .ready, .cap_webext_action = true };

    // A close that loses the connection: the caller's `*Action` is
    // freed, and activate must stop rather than post with it.
    CloseProbe.reset();
    var lost = probeToolbar(gpa, CloseProbe.losing);
    defer dropActions(&lost);
    lost.cl = &cl;
    try addAction(&lost, "aaaa", 0x2000);
    var lost_pop = fakePopup(&lost, lost.actions.items[0].button);
    lost.popup = &lost_pop;
    try std.testing.expect(!lost.activate(&lost.actions.items[0]));
    try std.testing.expectEqual(@as(usize, 1), CloseProbe.closes);
    try std.testing.expectEqual(@as(usize, 0), lost.actions.items.len);

    // A close the connection survived, but which replaced the list:
    // the re-resolved action is disabled, so the activation stops
    // there. Reusing the pre-close pointer would read the old, enabled
    // copy out of freed storage and open a popup for it.
    CloseProbe.reset();
    var moved = probeToolbar(gpa, CloseProbe.replacing);
    defer dropActions(&moved);
    moved.cl = &cl;
    try addAction(&moved, "aaaa", 0x2000);
    var moved_pop = fakePopup(&moved, moved.actions.items[0].button);
    moved.popup = &moved_pop;
    try std.testing.expect(!moved.activate(&moved.actions.items[0]));
    try std.testing.expectEqual(@as(usize, 1), CloseProbe.closes);
    try std.testing.expectEqual(@as(usize, 1), moved.actions.items.len);
    try std.testing.expect(!moved.actions.items[0].enabled);

    // With no popup open nothing can re-enter, so the activation takes
    // no copy of the id and no close is attempted.
    CloseProbe.reset();
    var plain = probeToolbar(gpa, CloseProbe.losing);
    defer dropActions(&plain);
    plain.cl = &cl;
    try addAction(&plain, "aaaa", 0x2000);
    plain.actions.items[0].enabled = false;
    try std.testing.expect(!plain.activate(&plain.actions.items[0]));
    try std.testing.expectEqual(@as(usize, 0), CloseProbe.closes);
}

const Popup = struct {
    owner: *Toolbar,
    view: u32,
    widget: *c.GtkWidget,
    /// The button the popover is parented to, kept rather than read back
    /// with `gtk_widget_get_parent` so matching a popup to its action is
    /// a pointer compare and nothing else.
    anchor: *c.GtkWidget,
    picture: *c.GtkWidget,
    status: *c.GtkWidget,
    map: ?*webframe.Map = null,
    buf_id: u32 = 0,
    w: u16 = 0,
    h: u16 = 0,
    stride: u32 = 0,
    last_x: i32 = 0,
    last_y: i32 = 0,
    motion: *c.GtkEventController,
    click: *c.GtkGesture,
    scroll: *c.GtkEventController,
    key: *c.GtkEventController,
    focus: *c.GtkEventController,
    closing: bool = false,

    fn create(owner: *Toolbar, anchor: *c.GtkWidget) ?*Popup {
        const self = owner.allocator.create(Popup) catch return null;
        const pop = c.gtk_popover_new() orelse {
            owner.allocator.destroy(self);
            return null;
        };
        const overlay = c.gtk_overlay_new().?;
        c.gtk_widget_set_size_request(overlay, POPUP_W, POPUP_H);
        const area = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0).?;
        c.gtk_widget_set_focusable(area, 1);
        c.gtk_overlay_set_child(@ptrCast(overlay), area);
        const picture = c.gtk_picture_new().?;
        c.gtk_picture_set_content_fit(@ptrCast(picture), c.GTK_CONTENT_FIT_FILL);
        c.gtk_widget_set_can_target(picture, 0);
        c.gtk_overlay_add_overlay(@ptrCast(overlay), picture);
        const status = c.gtk_label_new("Loading extension popup...").?;
        c.gtk_label_set_wrap(@ptrCast(status), 1);
        c.gtk_widget_set_halign(status, c.GTK_ALIGN_CENTER);
        c.gtk_widget_set_valign(status, c.GTK_ALIGN_CENTER);
        c.gtk_overlay_add_overlay(@ptrCast(overlay), status);
        c.gtk_popover_set_child(@ptrCast(pop), overlay);
        c.gtk_popover_set_position(@ptrCast(pop), c.GTK_POS_BOTTOM);
        c.gtk_widget_set_parent(pop, anchor);
        _ = c.g_object_ref(@as(?*anyopaque, @ptrCast(pop)));
        self.* = .{
            .owner = owner,
            .view = webface.nextAuxView(),
            .widget = pop,
            .anchor = anchor,
            .picture = picture,
            .status = status,
            .motion = undefined,
            .click = undefined,
            .scroll = undefined,
            .key = undefined,
            .focus = undefined,
        };
        const ctrls = webframe.wireInput(InputSink, area, @ptrCast(self)) orelse {
            c.gtk_widget_unparent(pop);
            c.g_object_unref(@as(?*anyopaque, @ptrCast(pop)));
            owner.allocator.destroy(self);
            return null;
        };
        self.motion = ctrls.motion;
        self.click = ctrls.click;
        self.scroll = ctrls.scroll;
        self.key = ctrls.key;
        self.focus = ctrls.focus;
        _ = c.g_signal_connect_data(pop, "closed", @ptrCast(&onClosed), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_popover_popup(@ptrCast(pop));
        _ = c.gtk_widget_grab_focus(area);
        return self;
    }

    fn destroy(self: *Popup, notify_helper: bool) void {
        if (self.closing) return;
        self.closing = true;
        const objects = [_]?*anyopaque{
            @ptrCast(self.widget), @ptrCast(self.motion), @ptrCast(self.click),
            @ptrCast(self.scroll), @ptrCast(self.key),    @ptrCast(self.focus),
        };
        for (objects) |object| {
            _ = c.g_signal_handlers_disconnect_matched(
                object,
                c.G_SIGNAL_MATCH_DATA,
                0,
                0,
                null,
                null,
                @ptrCast(self),
            );
        }
        if (notify_helper and self.view != 0) self.owner.post(proto.ViewDestroy{ .view = self.view });
        c.gtk_picture_set_paintable(@ptrCast(self.picture), null);
        if (self.map) |m| m.unref();
        self.map = null;
        const owner = self.owner;
        if (owner.popup == self) owner.popup = null;
        if (c.gtk_widget_get_parent(self.widget)) |anchor| {
            // GTK only MOVES the window's focus out of a hidden popover
            // on the next frame's after-paint phase; unparenting before
            // that frame leaves `gtk_window_get_focus` pointing at a
            // widget with no root, so nothing (focusedPane, a remote
            // `web-open split`) can resolve the pane the popup sat on.
            // Hand focus to the anchor now, the same rule the context
            // menu popover applies.
            @import("menu.zig").returnFocusTo(anchor, self.widget);
            c.gtk_widget_unparent(self.widget);
        }
        c.g_object_unref(@as(?*anyopaque, @ptrCast(self.widget)));
        owner.allocator.destroy(self);
    }

    fn closeFromHelper(self: *Popup) void {
        self.view = 0;
        self.destroy(false);
    }

    fn showError(self: *Popup, detail: []const u8) void {
        var buf: [512:0]u8 = @splat(0);
        const text = if (detail.len != 0) detail else "The extension popup could not be opened.";
        const n = utf8Prefix(text, buf.len - 1);
        @memcpy(buf[0..n], text[0..n]);
        c.gtk_label_set_text(@ptrCast(self.status), &buf);
        c.gtk_widget_set_visible(self.status, 1);
    }

    fn adoptBuffer(self: *Popup, fb: proto.FrameBuffer, fd: c_int) void {
        defer _ = c.close(fd);
        const m = webframe.mapFrameFd(self.owner.allocator, fd, fb.w, fb.h, fb.stride) orelse return;
        c.gtk_picture_set_paintable(@ptrCast(self.picture), null);
        if (self.map) |old| old.unref();
        self.map = m;
        self.buf_id = fb.buf_id;
        self.w = fb.w;
        self.h = fb.h;
        self.stride = fb.stride;
        self.owner.post(proto.FrameRequest{ .view = self.view, .flags = 0 });
    }

    fn damage(self: *Popup, ev: proto.FrameDamage) void {
        if (ev.buf_id != self.buf_id) return;
        const m = self.map orelse return;
        const tex = webframe.buildBgraTexture(m, self.w, self.h, self.stride, null, null) orelse return;
        c.gtk_picture_set_paintable(@ptrCast(self.picture), @ptrCast(tex));
        c.g_object_unref(@ptrCast(tex));
        c.gtk_widget_set_visible(self.status, 0);
    }

    fn inlineFrame(self: *Popup, ev: proto.FrameInline) void {
        if (ev.w == 0 or ev.h == 0) return;
        const stride = @as(u32, ev.w) * 4;
        const size = @as(usize, stride) * ev.h;
        const need_new = self.map == null or self.w != ev.w or self.h != ev.h or self.stride != stride;
        if (need_new) {
            const map = webframe.mapAnon(self.owner.allocator, size) orelse return;
            c.gtk_picture_set_paintable(@ptrCast(self.picture), null);
            if (self.map) |old| old.unref();
            self.map = map;
            self.w = ev.w;
            self.h = ev.h;
            self.stride = stride;
            self.buf_id +%= 1;
            if (self.buf_id == 0) self.buf_id = 1;
        }
        const map = self.map orelse return;
        for (ev.rects) |r| {
            _ = webframe.decodeInlineRect(self.owner.allocator, map, stride, ev.w, ev.h, r);
        }
        self.damage(.{ .view = ev.view, .buf_id = self.buf_id, .gen = ev.gen, .rects = &.{} });
    }

    fn sendPointer(self: *Popup, kind: proto.PointerKind, x: f64, y: f64, button: u8, clicks: u8, mods: u32) void {
        self.owner.post(proto.InputPointer{
            .view = self.view,
            .kind = @intFromEnum(kind),
            .x = @intFromFloat(@round(x)),
            .y = @intFromFloat(@round(y)),
            .button = button,
            .clicks = clicks,
            .mods = mods,
        });
    }

    fn onClosed(_: *c.GtkPopover, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(Popup, user);
        if (self.closing) return;
        self.destroy(true);
    }

    /// `webframe.wireInput` sink: everything a popup does with an event
    /// is post it, so this is the shared translation plus the one local
    /// rule that Escape closes the popover.
    const InputSink = struct {
        pub fn pointer(
            user: ?*anyopaque,
            kind: proto.PointerKind,
            x: f64,
            y: f64,
            button: u8,
            clicks: u8,
            mods: u32,
        ) void {
            const self = cast.userData(Popup, user);
            // A leave carries no position of its own; the page is told
            // the pointer left from where it last was.
            if (kind == .leave) {
                self.sendPointer(kind, @floatFromInt(self.last_x), @floatFromInt(self.last_y), button, clicks, mods);
                return;
            }
            if (kind == .move or kind == .down) {
                self.last_x = @intFromFloat(@round(x));
                self.last_y = @intFromFloat(@round(y));
            }
            self.sendPointer(kind, x, y, button, clicks, mods);
        }

        pub fn scroll(user: ?*anyopaque, dx: f64, dy: f64, mods: u32) c.gboolean {
            const self = cast.userData(Popup, user);
            self.owner.post(proto.InputScroll{
                .view = self.view,
                .x = self.last_x,
                .y = self.last_y,
                .dx = webframe.wheelDelta(dx),
                .dy = webframe.wheelDelta(dy),
                .mods = mods,
            });
            return 1;
        }

        pub fn key(
            user: ?*anyopaque,
            kind: proto.KeyKind,
            keyval: c.guint,
            keycode: c.guint,
            state: c.GdkModifierType,
        ) c.gboolean {
            const self = cast.userData(Popup, user);
            if (kind == .down and keyval == c.GDK_KEY_Escape) {
                c.gtk_popover_popdown(@ptrCast(self.widget));
                return 1;
            }
            const mods = modsFromState(state);
            var text_buf: [8]u8 = undefined;
            self.owner.post(proto.InputKey{
                .view = self.view,
                .kind = @intFromEnum(kind),
                .keyval = keyval,
                .keycode = keycode,
                .mods = mods,
                .text = webframe.keyText(&text_buf, kind, keyval, mods),
            });
            return 1;
        }

        pub fn focus(user: ?*anyopaque, focused: bool) void {
            const self = cast.userData(Popup, user);
            self.owner.post(proto.InputFocus{ .view = self.view, .focused = @intFromBool(focused) });
        }
    };
};

const modsFromState = webframe.modsFromState;
