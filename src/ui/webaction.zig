//! GTK browser-action toolbar buttons and extension popup presentation.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const proto = @import("../web/protocol.zig");
const zpool = @import("../wlhost/zpool.zig");
const webface = @import("webface.zig");
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
                const a = &self.actions.items[idx];
                if (self.popup) |p| {
                    if (c.gtk_widget_get_parent(p.widget) == a.button and (!in.enabled or !in.popup)) p.destroy(true);
                }
                self.configureButton(a, in);
                idx += 1;
            }
            c.gtk_widget_set_visible(self.box, @intFromBool(self.actions.items.len != 0));
            return;
        }
        if (self.popup) |p| p.destroy(true);
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
            c.gtk_widget_get_style_context(badge), @ptrCast(@alignCast(provider)), c.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION,
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

    pub fn openPopup(self: *Toolbar, id: []const u8) void {
        if (self.severed) return;
        for (self.actions.items) |*a| {
            if (!std.mem.eql(u8, a.id, id) or !a.enabled or !a.popup) continue;
            self.activate(a);
            return;
        }
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
                    @ptrCast(a.button), c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, @ptrCast(self),
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
        if (!a.enabled) return;
        self.activate(a);
    }

    fn activate(self: *Toolbar, a: *Action) void {
        const cl = self.cl orelse return;
        if (self.popup) |old| old.destroy(true);
        self.popup = null;
        const popup = if (a.popup) Popup.create(self, a.button) else null;
        if (a.popup and popup == null) return;
        self.popup = popup;
        const popup_view = if (popup) |p| p.view else 0;
        const scale = if (webface.faceByViewOn(cl, self.face_view)) |face| face.popupScale() else 1000;
        cl.post(proto.WebextActionActivate{
            .view = self.face_view,
            .id = a.id,
            .popup_view = popup_view,
            .w = POPUP_W,
            .h = POPUP_H,
            .scale_x1000 = scale,
        });
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

const Popup = struct {
    owner: *Toolbar,
    view: u32,
    widget: *c.GtkWidget,
    picture: *c.GtkWidget,
    status: *c.GtkWidget,
    map: ?*Map = null,
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
        const motion = c.gtk_event_controller_motion_new().?;
        const click = c.gtk_gesture_click_new().?;
        const scroll = c.gtk_event_controller_scroll_new(c.GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES).?;
        const key = c.gtk_event_controller_key_new().?;
        const focus = c.gtk_event_controller_focus_new().?;
        self.* = .{
            .owner = owner,
            .view = webface.nextAuxView(),
            .widget = pop,
            .picture = picture,
            .status = status,
            .motion = motion,
            .click = @ptrCast(click),
            .scroll = scroll,
            .key = key,
            .focus = focus,
        };
        _ = c.g_signal_connect_data(pop, "closed", @ptrCast(&onClosed), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(motion, "motion", @ptrCast(&onMotion), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(motion, "leave", @ptrCast(&onPointerLeave), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(area, motion);
        c.gtk_gesture_single_set_button(@ptrCast(click), 0);
        _ = c.g_signal_connect_data(click, "pressed", @ptrCast(&onPressed), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(click, "released", @ptrCast(&onReleased), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(area, @ptrCast(click));
        _ = c.g_signal_connect_data(scroll, "scroll", @ptrCast(&onScroll), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(area, scroll);
        _ = c.g_signal_connect_data(key, "key-pressed", @ptrCast(&onKeyPressed), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(key, "key-released", @ptrCast(&onKeyReleased), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(area, key);
        _ = c.g_signal_connect_data(focus, "enter", @ptrCast(&onFocusEnter), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(focus, "leave", @ptrCast(&onFocusLeave), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(area, focus);
        c.gtk_popover_popup(@ptrCast(pop));
        _ = c.gtk_widget_grab_focus(area);
        return self;
    }

    fn destroy(self: *Popup, notify_helper: bool) void {
        if (self.closing) return;
        self.closing = true;
        const objects = [_]?*anyopaque{
            @ptrCast(self.widget), @ptrCast(self.motion), @ptrCast(self.click),
            @ptrCast(self.scroll), @ptrCast(self.key), @ptrCast(self.focus),
        };
        for (objects) |object| {
            _ = c.g_signal_handlers_disconnect_matched(
                object, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, @ptrCast(self),
            );
        }
        if (notify_helper and self.view != 0) self.owner.post(proto.ViewDestroy{ .view = self.view });
        c.gtk_picture_set_paintable(@ptrCast(self.picture), null);
        if (self.map) |m| m.unref();
        self.map = null;
        const owner = self.owner;
        if (owner.popup == self) owner.popup = null;
        if (c.gtk_widget_get_parent(self.widget) != null) c.gtk_widget_unparent(self.widget);
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
        const n = @min(text.len, buf.len - 1);
        @memcpy(buf[0..n], text[0..n]);
        c.gtk_label_set_text(@ptrCast(self.status), &buf);
        c.gtk_widget_set_visible(self.status, 1);
    }

    fn adoptBuffer(self: *Popup, fb: proto.FrameBuffer, fd: c_int) void {
        defer _ = c.close(fd);
        const size = @as(usize, fb.stride) * fb.h;
        if (fb.w == 0 or fb.h == 0 or fb.stride < @as(u32, fb.w) * 4 or size == 0) return;
        const addr = c.mmap(null, size, c.PROT_READ, c.MAP_SHARED, fd, 0);
        if (addr == c.MAP_FAILED) return;
        const m = self.owner.allocator.create(Map) catch {
            _ = c.munmap(addr, size);
            return;
        };
        m.* = .{ .ptr = @ptrCast(addr), .len = size, .allocator = self.owner.allocator, .mapped = true };
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
        const builder = c.gdk_memory_texture_builder_new() orelse return;
        defer c.g_object_unref(@ptrCast(builder));
        const bytes = c.g_bytes_new_with_free_func(m.ptr, m.len, Map.gbytesDestroy, m.ref()) orelse {
            m.unref();
            return;
        };
        defer c.g_bytes_unref(bytes);
        c.gdk_memory_texture_builder_set_bytes(builder, bytes);
        c.gdk_memory_texture_builder_set_width(builder, self.w);
        c.gdk_memory_texture_builder_set_height(builder, self.h);
        c.gdk_memory_texture_builder_set_stride(builder, self.stride);
        c.gdk_memory_texture_builder_set_format(builder, c.GDK_MEMORY_B8G8R8A8_PREMULTIPLIED);
        const tex = c.gdk_memory_texture_builder_build(builder) orelse return;
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
            const bytes = self.owner.allocator.alloc(u8, size) catch return;
            @memset(bytes, 0);
            const map = self.owner.allocator.create(Map) catch {
                self.owner.allocator.free(bytes);
                return;
            };
            map.* = .{ .ptr = bytes.ptr, .len = bytes.len, .allocator = self.owner.allocator };
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
            if (@as(u32, r.x) + r.w > ev.w or @as(u32, r.y) + r.h > ev.h) continue;
            const raw_len = @as(usize, r.w) * r.h * 4;
            var scratch: ?[]u8 = null;
            defer if (scratch) |s| self.owner.allocator.free(s);
            const decoded = switch (r.enc) {
                proto.inline_enc_raw => if (r.data.len == raw_len) r.data else continue,
                proto.inline_enc_deflate => blk: {
                    const s = self.owner.allocator.alloc(u8, raw_len) catch continue;
                    scratch = s;
                    break :blk zpool.decompress(r.data, s) catch continue;
                },
                else => continue,
            };
            const row_bytes = @as(usize, r.w) * 4;
            for (0..r.h) |row| {
                const dst = (@as(usize, r.y) + row) * stride + @as(usize, r.x) * 4;
                @memcpy(map.ptr[dst..][0..row_bytes], decoded[row * row_bytes ..][0..row_bytes]);
            }
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

    fn onMotion(ctrl: *c.GtkEventControllerMotion, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(Popup, user);
        self.last_x = @intFromFloat(@round(x));
        self.last_y = @intFromFloat(@round(y));
        self.sendPointer(.move, x, y, 0, 0, modsOf(@ptrCast(ctrl)));
    }

    fn onPointerLeave(ctrl: *c.GtkEventControllerMotion, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(Popup, user);
        self.sendPointer(.leave, self.last_x, self.last_y, 0, 0, modsOf(@ptrCast(ctrl)));
    }

    fn onPressed(g: *c.GtkGestureClick, n: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
        const button = cefButton(c.gtk_gesture_single_get_current_button(@ptrCast(g)));
        const self = cast.userData(Popup, user);
        self.last_x = @intFromFloat(@round(x));
        self.last_y = @intFromFloat(@round(y));
        self.sendPointer(.down, x, y, button, @intCast(@max(n, 1)), modsOf(@ptrCast(g)));
    }

    fn onReleased(g: *c.GtkGestureClick, n: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
        const button = cefButton(c.gtk_gesture_single_get_current_button(@ptrCast(g)));
        cast.userData(Popup, user).sendPointer(.up, x, y, button, @intCast(@max(n, 1)), modsOf(@ptrCast(g)));
    }

    fn onScroll(ctrl: *c.GtkEventControllerScroll, dx: f64, dy: f64, user: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast.userData(Popup, user);
        self.owner.post(proto.InputScroll{
            .view = self.view,
            .x = self.last_x,
            .y = self.last_y,
            .dx = @intFromFloat(@round(dx * 120.0)),
            .dy = @intFromFloat(@round(dy * 120.0)),
            .mods = modsOf(@ptrCast(ctrl)),
        });
        return 1;
    }

    fn onKeyPressed(_: *c.GtkEventControllerKey, keyval: c.guint, keycode: c.guint, state: c.GdkModifierType, user: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast.userData(Popup, user);
        if (keyval == c.GDK_KEY_Escape) {
            c.gtk_popover_popdown(@ptrCast(self.widget));
            return 1;
        }
        const mods = modsFromState(state);
        var text_buf: [8]u8 = undefined;
        var text: []const u8 = &.{};
        if (mods & (proto.mod_ctrl | proto.mod_alt) == 0) {
            const cp = c.gdk_keyval_to_unicode(keyval);
            if (cp >= 0x20 and cp != 0x7f) {
                const n = std.unicode.utf8Encode(@intCast(cp), &text_buf) catch 0;
                text = text_buf[0..n];
            }
        }
        self.owner.post(proto.InputKey{
            .view = self.view,
            .kind = @intFromEnum(proto.KeyKind.down),
            .keyval = keyval,
            .keycode = keycode,
            .mods = mods,
            .text = text,
        });
        return 1;
    }

    fn onKeyReleased(_: *c.GtkEventControllerKey, keyval: c.guint, keycode: c.guint, state: c.GdkModifierType, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(Popup, user);
        self.owner.post(proto.InputKey{
            .view = self.view,
            .kind = @intFromEnum(proto.KeyKind.up),
            .keyval = keyval,
            .keycode = keycode,
            .mods = modsFromState(state),
            .text = "",
        });
    }

    fn onFocusEnter(_: *c.GtkEventControllerFocus, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(Popup, user);
        self.owner.post(proto.InputFocus{ .view = self.view, .focused = 1 });
    }

    fn onFocusLeave(_: *c.GtkEventControllerFocus, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(Popup, user);
        self.owner.post(proto.InputFocus{ .view = self.view, .focused = 0 });
    }
};

const Map = struct {
    ptr: [*]u8,
    len: usize,
    refs: u32 = 1,
    allocator: std.mem.Allocator,
    mapped: bool = false,

    fn ref(self: *Map) *Map {
        self.refs += 1;
        return self;
    }

    fn unref(self: *Map) void {
        self.refs -= 1;
        if (self.refs != 0) return;
        if (self.mapped) {
            _ = c.munmap(self.ptr, self.len);
        } else {
            self.allocator.free(self.ptr[0..self.len]);
        }
        self.allocator.destroy(self);
    }

    fn gbytesDestroy(user: ?*anyopaque) callconv(.c) void {
        cast.userData(Map, user).unref();
    }
};

fn cefButton(btn: c.guint) u8 {
    return switch (btn) {
        2 => 1,
        3 => 2,
        else => 0,
    };
}

fn modsOf(ctrl: *c.GtkEventController) u32 {
    return modsFromState(c.gtk_event_controller_get_current_event_state(ctrl));
}

fn modsFromState(state: c.GdkModifierType) u32 {
    var mods: u32 = 0;
    const s: c_int = @intCast(state);
    if (s & c.GDK_SHIFT_MASK != 0) mods |= proto.mod_shift;
    if (s & c.GDK_CONTROL_MASK != 0) mods |= proto.mod_ctrl;
    if (s & c.GDK_ALT_MASK != 0) mods |= proto.mod_alt;
    if (s & c.GDK_SUPER_MASK != 0) mods |= proto.mod_super;
    if (s & c.GDK_LOCK_MASK != 0) mods |= proto.mod_capslock;
    return mods;
}
