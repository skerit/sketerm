//! GUI host for window-stream channels (GUI-only; GTK): the render
//! half of "macOS apps on Linux". One WsHost per `winstream`
//! channel; each remote window becomes a GtkWindow + GtkPicture fed
//! by full BGRA frames (winstream/proto.zig). Input goes back as
//! input_* units — evdev key codes and window-local pixels; the
//! remote agent translates. No compositor brain here: the remote
//! end is pixels, not protocol.

const std = @import("std");
const c = @import("c.zig").c;
const cast = @import("util/cast.zig");
const proto = @import("winstream/proto.zig");
const zpool = @import("wlhost/zpool.zig");

pub const WsHost = struct {
    allocator: std.mem.Allocator,
    windows: std.AutoHashMapUnmanaged(u32, *Win) = .empty,
    inbuf: std.ArrayList(u8) = .empty,
    out: std.ArrayList(u8) = .empty,
    zbuf: std.ArrayList(u8) = .empty,
    dead: bool = false,
    on_flush: ?*const fn (ctx: ?*anyopaque) void = null,
    flush_ctx: ?*anyopaque = null,

    const Win = struct {
        host: *WsHost,
        id: u32,
        window: *c.GtkWindow,
        picture: *c.GtkWidget,
    };

    pub fn create(allocator: std.mem.Allocator) !*WsHost {
        const self = try allocator.create(WsHost);
        self.* = .{ .allocator = allocator };
        return self;
    }

    pub fn destroy(self: *WsHost) void {
        var it = self.windows.valueIterator();
        while (it.next()) |w| {
            _ = c.g_object_set_data(@ptrCast(w.*.window), "sketerm-winapp", null);
            c.gtk_window_destroy(w.*.window);
            self.allocator.destroy(w.*);
        }
        self.windows.deinit(self.allocator);
        self.inbuf.deinit(self.allocator);
        self.out.deinit(self.allocator);
        self.zbuf.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn takeOut(self: *WsHost) []const u8 {
        return self.out.items;
    }

    pub fn clearOut(self: *WsHost) void {
        self.out.clearRetainingCapacity();
    }

    /// One chan_data payload. Errors are fatal (caller closes).
    pub fn feed(self: *WsHost, bytes: []const u8) !void {
        if (self.dead) return;
        try self.inbuf.appendSlice(self.allocator, bytes);
        var pos: usize = 0;
        while (proto.peelUnit(self.inbuf.items[pos..]) catch return error.Protocol) |p| {
            self.unit(p.unit) catch return error.Protocol;
            pos += p.consumed;
        }
        if (pos > 0) {
            const rem = self.inbuf.items.len - pos;
            std.mem.copyForwards(u8, self.inbuf.items[0..rem], self.inbuf.items[pos..]);
            self.inbuf.shrinkRetainingCapacity(rem);
        }
    }

    fn unit(self: *WsHost, u: proto.Unit) !void {
        switch (u.tag) {
            .win_open => {
                const wo = proto.decodeWinOpen(u.payload) orelse return error.Protocol;
                _ = self.winFor(wo.win, wo.w, wo.h, wo.title);
            },
            .win_frame => {
                const fr = proto.decodeFrame(u.payload) orelse return error.Protocol;
                self.showFrame(fr.win, fr.w, fr.h, fr.pixels);
            },
            .win_frame_z => {
                const fz = proto.decodeFrameZ(u.payload) orelse return error.Protocol;
                const need = @as(usize, @intCast(@max(fz.w, 1))) * 4 * @as(usize, @intCast(@max(fz.h, 1)));
                if (fz.raw_len != need) return error.Protocol;
                try self.zbuf.resize(self.allocator, fz.raw_len);
                _ = zpool.decompress(fz.z, self.zbuf.items) catch return error.Protocol;
                self.showFrame(fz.win, fz.w, fz.h, self.zbuf.items);
            },
            .win_title => {
                if (u.payload.len < 4) return error.Protocol;
                const id = std.mem.readInt(u32, u.payload[0..4], .little);
                const win = self.windows.get(id) orelse return;
                var buf: [256:0]u8 = undefined;
                const z = std.fmt.bufPrintZ(&buf, "{s}", .{u.payload[4..]}) catch return;
                c.gtk_window_set_title(win.window, z.ptr);
            },
            .win_close => {
                if (u.payload.len < 4) return error.Protocol;
                const id = std.mem.readInt(u32, u.payload[0..4], .little);
                const win = self.windows.get(id) orelse return;
                _ = self.windows.remove(id);
                _ = c.g_object_set_data(@ptrCast(win.window), "sketerm-winapp", null);
                c.gtk_window_destroy(win.window);
                self.allocator.destroy(win);
            },
            else => {},
        }
    }

    fn showFrame(self: *WsHost, id: u32, w: i32, h: i32, pixels: []const u8) void {
        const win = self.winFor(id, w, h, "remote window") orelse return;
        const gbytes = c.g_bytes_new(pixels.ptr, pixels.len) orelse return;
        defer c.g_bytes_unref(gbytes);
        const tex = c.gdk_memory_texture_new(w, h, c.GDK_MEMORY_B8G8R8A8_PREMULTIPLIED, gbytes, @intCast(w * 4)) orelse return;
        defer c.g_object_unref(tex);
        c.gtk_picture_set_paintable(@ptrCast(win.picture), @ptrCast(tex));
    }

    fn winFor(self: *WsHost, id: u32, w: i32, h: i32, title: []const u8) ?*Win {
        if (self.windows.get(id)) |win| return win;
        const win = self.allocator.create(Win) catch return null;
        const window: *c.GtkWindow = @ptrCast(c.gtk_window_new());
        const picture = c.gtk_picture_new();
        c.gtk_picture_set_content_fit(@ptrCast(picture), c.GTK_CONTENT_FIT_FILL);
        var tbuf: [256:0]u8 = undefined;
        if (std.fmt.bufPrintZ(&tbuf, "{s}", .{title})) |z| {
            c.gtk_window_set_title(window, z.ptr);
        } else |_| {}
        c.gtk_window_set_default_size(window, w, h);
        c.gtk_window_set_child(window, picture);
        win.* = .{ .host = self, .id = id, .window = window, .picture = picture.? };
        self.windows.put(self.allocator, id, win) catch {
            c.gtk_window_destroy(window);
            self.allocator.destroy(win);
            return null;
        };
        _ = c.g_object_set_data(@ptrCast(window), "sketerm-winapp", win);
        _ = c.g_signal_connect_data(@ptrCast(window), "close-request", @ptrCast(&onCloseRequest), win, null, 0);

        const motion = c.gtk_event_controller_motion_new();
        _ = c.g_signal_connect_data(@ptrCast(motion), "motion", @ptrCast(&onMotion), win, null, 0);
        c.gtk_widget_add_controller(picture, motion);
        const click = c.gtk_gesture_click_new();
        c.gtk_gesture_single_set_button(@ptrCast(click), 0);
        _ = c.g_signal_connect_data(@ptrCast(click), "pressed", @ptrCast(&onPress), win, null, 0);
        _ = c.g_signal_connect_data(@ptrCast(click), "released", @ptrCast(&onRelease), win, null, 0);
        c.gtk_widget_add_controller(picture, @ptrCast(click));
        const scroll = c.gtk_event_controller_scroll_new(c.GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES);
        _ = c.g_signal_connect_data(@ptrCast(scroll), "scroll", @ptrCast(&onScroll), win, null, 0);
        c.gtk_widget_add_controller(picture, @ptrCast(scroll));
        const key = c.gtk_event_controller_key_new();
        _ = c.g_signal_connect_data(@ptrCast(key), "key-pressed", @ptrCast(&onKeyPress), win, null, 0);
        _ = c.g_signal_connect_data(@ptrCast(key), "key-released", @ptrCast(&onKeyRelease), win, null, 0);
        c.gtk_widget_add_controller(@ptrCast(window), key);

        c.gtk_window_present(window);
        return win;
    }

    fn flush(self: *WsHost) void {
        if (self.on_flush) |f| f(self.flush_ctx);
    }

    fn onCloseRequest(_: ?*c.GtkWindow, user: ?*anyopaque) callconv(.c) c.gboolean {
        const win = cast.userData(Win, user);
        if (win.host.dead) return 0;
        var p: [4]u8 = undefined;
        std.mem.writeInt(u32, &p, win.id, .little);
        proto.appendUnit(&win.host.out, win.host.allocator, .close_req, &p) catch return 0;
        win.host.flush();
        return 1;
    }

    fn onMotion(_: ?*c.GtkEventControllerMotion, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
        const win = cast.userData(Win, user);
        proto.appendInputPtr(&win.host.out, win.host.allocator, .{ .win = win.id, .kind = 0, .x = x, .y = y, .detail = 0 }) catch return;
        win.host.flush();
    }

    fn onPress(g: ?*c.GtkGestureClick, _: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
        const win = cast.userData(Win, user);
        const btn = c.gtk_gesture_single_get_current_button(@ptrCast(g));
        proto.appendInputPtr(&win.host.out, win.host.allocator, .{ .win = win.id, .kind = 1, .x = x, .y = y, .detail = btn }) catch return;
        win.host.flush();
    }

    fn onRelease(g: ?*c.GtkGestureClick, _: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
        const win = cast.userData(Win, user);
        const btn = c.gtk_gesture_single_get_current_button(@ptrCast(g));
        proto.appendInputPtr(&win.host.out, win.host.allocator, .{ .win = win.id, .kind = 2, .x = x, .y = y, .detail = btn }) catch return;
        win.host.flush();
    }

    fn onScroll(ctl: ?*c.GtkEventControllerScroll, dx: f64, dy: f64, user: ?*anyopaque) callconv(.c) c.gboolean {
        const win = cast.userData(Win, user);
        // Wheel events arrive as ±1 notches; touchpads report
        // surface pixels — normalize to wheel-line-ish units so the
        // agent can treat x/y as scroll lines.
        var fx = dx;
        var fy = dy;
        if (c.gtk_event_controller_scroll_get_unit(ctl) == c.GDK_SCROLL_UNIT_SURFACE) {
            fx /= 40.0;
            fy /= 40.0;
        }
        proto.appendInputPtr(&win.host.out, win.host.allocator, .{ .win = win.id, .kind = 3, .x = fx, .y = fy, .detail = 0 }) catch return 1;
        win.host.flush();
        return 1;
    }

    fn onKeyPress(_: ?*c.GtkEventControllerKey, _: c_uint, keycode: c_uint, state: c.GdkModifierType, user: ?*anyopaque) callconv(.c) c.gboolean {
        const win = cast.userData(Win, user);
        if (keycode >= 8) {
            proto.appendInputKey(&win.host.out, win.host.allocator, .{ .win = win.id, .key = @intCast(keycode - 8), .pressed = true, .mods = @as(u32, @intCast(state)) & 0xff }) catch return 1;
            win.host.flush();
        }
        return 1;
    }

    fn onKeyRelease(_: ?*c.GtkEventControllerKey, _: c_uint, keycode: c_uint, state: c.GdkModifierType, user: ?*anyopaque) callconv(.c) void {
        const win = cast.userData(Win, user);
        if (keycode >= 8) {
            proto.appendInputKey(&win.host.out, win.host.allocator, .{ .win = win.id, .key = @intCast(keycode - 8), .pressed = false, .mods = @as(u32, @intCast(state)) & 0xff }) catch return;
            win.host.flush();
        }
    }
};
