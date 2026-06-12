//! GUI-side host of the sketerm-native app pipe (GUI-only; GTK).
//!
//! One AppHost per `wayland_native` channel: owns the wlhost
//! Compositor (the protocol brain) and renders each toplevel as a
//! plain GtkWindow holding a GtkPicture fed by GdkMemoryTexture —
//! the v1 full-copy pipeline. terminal.zig pumps chan_data payloads
//! in via feed() and ships flush()'d bytes back to the daemon.
//!
//! No input yet (the compositor advertises a capability-less seat);
//! the window close button sends xdg_toplevel.close, which is the
//! one liberty a render-only view can take.

const std = @import("std");
const c = @import("c.zig").c;
const cast = @import("util/cast.zig");
const Compositor = @import("wlhost/compositor.zig").Compositor;

pub const AppHost = struct {
    allocator: std.mem.Allocator,
    comp: Compositor,
    windows: std.AutoHashMapUnmanaged(u32, *Win) = .empty,
    /// Channel is gone — feed() refuses, windows show stale frames
    /// until the user closes them.
    dead: bool = false,
    /// Hook for shipping requestClose (and other view-initiated
    /// events) immediately rather than on the next feed.
    on_flush: ?*const fn (ctx: ?*anyopaque) void = null,
    flush_ctx: ?*anyopaque = null,

    const Win = struct {
        host: *AppHost,
        surface: u32,
        window: *c.GtkWindow,
        picture: *c.GtkWidget,
        /// Committed buffer size — the surface coordinate space.
        buf_w: i32 = 0,
        buf_h: i32 = 0,

        /// Widget → surface coordinates (the picture stretches to
        /// the widget, content-fit FILL).
        fn mapXY(self: *Win, wx: f64, wy: f64) [2]f64 {
            const ww = c.gtk_widget_get_width(self.picture);
            const wh = c.gtk_widget_get_height(self.picture);
            if (ww <= 0 or wh <= 0 or self.buf_w <= 0 or self.buf_h <= 0)
                return .{ wx, wy };
            return .{
                wx * @as(f64, @floatFromInt(self.buf_w)) / @as(f64, @floatFromInt(ww)),
                wy * @as(f64, @floatFromInt(self.buf_h)) / @as(f64, @floatFromInt(wh)),
            };
        }
    };

    /// Stamp the compositor clock (frame-callback and input event
    /// timestamps) from the GLib monotonic clock.
    fn stampNow(self: *AppHost) void {
        self.comp.now_ms = @truncate(@as(u64, @intCast(@divTrunc(c.g_get_monotonic_time(), 1000))));
    }

    pub fn create(allocator: std.mem.Allocator) !*AppHost {
        const self = try allocator.create(AppHost);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .comp = undefined,
        };
        self.comp = try Compositor.init(allocator, .{
            .ctx = self,
            .toplevel_frame = onFrame,
            .toplevel_title = onTitle,
            .toplevel_gone = onGone,
        });
        return self;
    }

    pub fn destroy(self: *AppHost) void {
        var it = self.windows.valueIterator();
        while (it.next()) |w| {
            // Break the close-request link before gtk teardown.
            _ = c.g_object_set_data(@ptrCast(w.*.window), "sketerm-wlapp", null);
            c.gtk_window_destroy(w.*.window);
            self.allocator.destroy(w.*);
        }
        self.windows.deinit(self.allocator);
        self.comp.deinit();
        self.allocator.destroy(self);
    }

    /// One chan_data payload from the daemon. Errors are protocol
    /// fatal — caller closes the channel.
    pub fn feed(self: *AppHost, bytes: []const u8) !void {
        if (self.dead) return;
        try self.comp.feed(bytes);
        if (self.comp.dead) return error.Protocol;
    }

    /// Pending event bytes toward the daemon. Caller ships them as
    /// chan_data and then calls clearOut.
    pub fn takeOut(self: *AppHost) []const u8 {
        return self.comp.takeOut();
    }

    pub fn clearOut(self: *AppHost) void {
        self.comp.clearOut();
    }

    // ── view callbacks (main thread — GTK is safe) ──────────────

    fn onFrame(ctx: ?*anyopaque, surface: u32, w: i32, h: i32, format: u32, pixels: []const u8) void {
        const self = cast.userData(AppHost, ctx);
        const win = self.winFor(surface, w, h) orelse return;
        win.buf_w = w;
        win.buf_h = h;
        // wl_shm: 0 = argb8888 (premultiplied), 1 = xrgb8888 — both
        // little-endian BGRA in memory.
        const gdk_format: c.GdkMemoryFormat = if (format == 1)
            c.GDK_MEMORY_B8G8R8X8
        else
            c.GDK_MEMORY_B8G8R8A8_PREMULTIPLIED;
        const gbytes = c.g_bytes_new(pixels.ptr, pixels.len) orelse return;
        defer c.g_bytes_unref(gbytes);
        const tex = c.gdk_memory_texture_new(w, h, gdk_format, gbytes, @intCast(w * 4)) orelse return;
        defer c.g_object_unref(tex);
        c.gtk_picture_set_paintable(@ptrCast(win.picture), @ptrCast(tex));
    }

    fn onTitle(ctx: ?*anyopaque, surface: u32, title: []const u8) void {
        const self = cast.userData(AppHost, ctx);
        const win = self.windows.get(surface) orelse return;
        var buf: [256:0]u8 = undefined;
        const z = std.fmt.bufPrintZ(&buf, "{s}", .{title}) catch return;
        c.gtk_window_set_title(win.window, z.ptr);
    }

    fn onGone(ctx: ?*anyopaque, surface: u32) void {
        const self = cast.userData(AppHost, ctx);
        const win = self.windows.get(surface) orelse return;
        _ = self.windows.remove(surface);
        _ = c.g_object_set_data(@ptrCast(win.window), "sketerm-wlapp", null);
        c.gtk_window_destroy(win.window);
        self.allocator.destroy(win);
    }

    /// Window for a surface, created on first frame (when the size
    /// is finally known).
    fn winFor(self: *AppHost, surface: u32, w: i32, h: i32) ?*Win {
        if (self.windows.get(surface)) |win| return win;

        const win = self.allocator.create(Win) catch return null;
        const window: *c.GtkWindow = @ptrCast(c.gtk_window_new());
        const picture = c.gtk_picture_new();
        c.gtk_window_set_title(window, "remote app");
        c.gtk_window_set_default_size(window, w, h);
        c.gtk_window_set_child(window, picture);
        c.gtk_picture_set_content_fit(@ptrCast(picture), c.GTK_CONTENT_FIT_FILL);
        win.* = .{ .host = self, .surface = surface, .window = window, .picture = picture.? };
        self.windows.put(self.allocator, surface, win) catch {
            c.gtk_window_destroy(window);
            self.allocator.destroy(win);
            return null;
        };
        _ = c.g_object_set_data(@ptrCast(window), "sketerm-wlapp", win);
        _ = c.g_signal_connect_data(@ptrCast(window), "close-request", @ptrCast(&onCloseRequest), win, null, 0);

        // Input: pointer on the picture (its coords), keyboard +
        // focus on the window. All feed the compositor's seat.
        const motion = c.gtk_event_controller_motion_new();
        _ = c.g_signal_connect_data(@ptrCast(motion), "enter", @ptrCast(&onPtrEnter), win, null, 0);
        _ = c.g_signal_connect_data(@ptrCast(motion), "motion", @ptrCast(&onPtrMotion), win, null, 0);
        _ = c.g_signal_connect_data(@ptrCast(motion), "leave", @ptrCast(&onPtrLeave), win, null, 0);
        c.gtk_widget_add_controller(picture, motion);

        const click = c.gtk_gesture_click_new();
        c.gtk_gesture_single_set_button(@ptrCast(click), 0); // all buttons
        _ = c.g_signal_connect_data(@ptrCast(click), "pressed", @ptrCast(&onBtnPress), win, null, 0);
        _ = c.g_signal_connect_data(@ptrCast(click), "released", @ptrCast(&onBtnRelease), win, null, 0);
        c.gtk_widget_add_controller(picture, @ptrCast(click));

        const scroll = c.gtk_event_controller_scroll_new(c.GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES);
        _ = c.g_signal_connect_data(@ptrCast(scroll), "scroll", @ptrCast(&onScroll), win, null, 0);
        c.gtk_widget_add_controller(picture, scroll);

        const key = c.gtk_event_controller_key_new();
        _ = c.g_signal_connect_data(@ptrCast(key), "key-pressed", @ptrCast(&onKeyPress), win, null, 0);
        _ = c.g_signal_connect_data(@ptrCast(key), "key-released", @ptrCast(&onKeyRelease), win, null, 0);
        c.gtk_widget_add_controller(@ptrCast(window), key);

        const focus = c.gtk_event_controller_focus_new();
        _ = c.g_signal_connect_data(@ptrCast(focus), "enter", @ptrCast(&onFocusEnter), win, null, 0);
        _ = c.g_signal_connect_data(@ptrCast(focus), "leave", @ptrCast(&onFocusLeave), win, null, 0);
        c.gtk_widget_add_controller(@ptrCast(window), focus);

        c.gtk_window_present(window);
        return win;
    }

    // ── input handlers (GTK → compositor seat) ──────────────────

    fn flushHost(self: *AppHost) void {
        if (self.on_flush) |f| f(self.flush_ctx);
    }

    fn onPtrEnter(_: ?*c.GtkEventControllerMotion, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
        const win = cast.userData(Win, user);
        win.host.stampNow();
        const p = win.mapXY(x, y);
        win.host.comp.pointerEnter(win.surface, p[0], p[1]) catch return;
        win.host.flushHost();
    }

    fn onPtrMotion(_: ?*c.GtkEventControllerMotion, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
        const win = cast.userData(Win, user);
        win.host.stampNow();
        const p = win.mapXY(x, y);
        // Enter may have been missed (window created under cursor).
        win.host.comp.pointerEnter(win.surface, p[0], p[1]) catch return;
        win.host.comp.pointerMotion(p[0], p[1]) catch return;
        win.host.flushHost();
    }

    fn onPtrLeave(_: ?*c.GtkEventControllerMotion, user: ?*anyopaque) callconv(.c) void {
        const win = cast.userData(Win, user);
        win.host.stampNow();
        win.host.comp.pointerLeave() catch return;
        win.host.flushHost();
    }

    /// GDK mouse button → evdev BTN_* code.
    fn evdevButton(gdk_button: c_uint) u32 {
        return switch (gdk_button) {
            1 => 0x110, // BTN_LEFT
            2 => 0x112, // BTN_MIDDLE
            3 => 0x111, // BTN_RIGHT
            8 => 0x113, // BTN_SIDE (back)
            9 => 0x114, // BTN_EXTRA (forward)
            else => 0x110,
        };
    }

    fn onBtnPress(gesture: ?*c.GtkGestureClick, _: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
        const win = cast.userData(Win, user);
        win.host.stampNow();
        const p = win.mapXY(x, y);
        win.host.comp.pointerEnter(win.surface, p[0], p[1]) catch return;
        const btn = c.gtk_gesture_single_get_current_button(@ptrCast(gesture));
        win.host.comp.pointerButton(evdevButton(btn), true) catch return;
        win.host.flushHost();
    }

    fn onBtnRelease(gesture: ?*c.GtkGestureClick, _: c_int, _: f64, _: f64, user: ?*anyopaque) callconv(.c) void {
        const win = cast.userData(Win, user);
        win.host.stampNow();
        const btn = c.gtk_gesture_single_get_current_button(@ptrCast(gesture));
        win.host.comp.pointerButton(evdevButton(btn), false) catch return;
        win.host.flushHost();
    }

    fn onScroll(_: ?*c.GtkEventControllerScroll, dx: f64, dy: f64, user: ?*anyopaque) callconv(.c) c.gboolean {
        const win = cast.userData(Win, user);
        win.host.stampNow();
        // Discrete wheel steps arrive as ±1; ~10 surface px per
        // step matches what stock compositors send.
        if (dy != 0) win.host.comp.pointerAxis(0, dy * 10.0) catch return 0;
        if (dx != 0) win.host.comp.pointerAxis(1, dx * 10.0) catch return 0;
        win.host.flushHost();
        return 1;
    }

    fn sendKey(win: *Win, keycode: c_uint, state: c.GdkModifierType, pressed: bool) void {
        win.host.stampNow();
        win.host.comp.keyboardEnter(win.surface) catch return;
        // GDK's low modifier bits are the X11/xkb mod order the
        // pc105/us keymap uses (shift, lock, ctrl, mod1…).
        win.host.comp.keyboardModifiers(@as(u32, @intCast(state)) & 0xff, 0, 0, 0) catch return;
        if (keycode >= 8)
            win.host.comp.keyboardKey(@intCast(keycode - 8), pressed) catch return;
        win.host.flushHost();
    }

    fn onKeyPress(_: ?*c.GtkEventControllerKey, _: c_uint, keycode: c_uint, state: c.GdkModifierType, user: ?*anyopaque) callconv(.c) c.gboolean {
        const win = cast.userData(Win, user);
        sendKey(win, keycode, state, true);
        return 1;
    }

    fn onKeyRelease(_: ?*c.GtkEventControllerKey, _: c_uint, keycode: c_uint, state: c.GdkModifierType, user: ?*anyopaque) callconv(.c) void {
        const win = cast.userData(Win, user);
        sendKey(win, keycode, state, false);
    }

    fn onFocusEnter(_: ?*c.GtkEventControllerFocus, user: ?*anyopaque) callconv(.c) void {
        const win = cast.userData(Win, user);
        win.host.stampNow();
        win.host.comp.keyboardEnter(win.surface) catch return;
        win.host.flushHost();
    }

    fn onFocusLeave(_: ?*c.GtkEventControllerFocus, user: ?*anyopaque) callconv(.c) void {
        const win = cast.userData(Win, user);
        win.host.stampNow();
        win.host.comp.keyboardLeave() catch return;
        win.host.flushHost();
    }

    /// Close button → xdg_toplevel.close toward the app; keep the
    /// window until the app destroys its toplevel (or died already,
    /// in which case let GTK close it).
    fn onCloseRequest(window: ?*c.GtkWindow, user: ?*anyopaque) callconv(.c) c.gboolean {
        _ = window;
        const win = cast.userData(Win, user);
        const self = win.host;
        if (self.dead) return 0; // app is gone — really close
        self.comp.requestClose(win.surface) catch return 0;
        if (self.on_flush) |f| f(self.flush_ctx);
        return 1; // handled; wait for the app
    }
};
