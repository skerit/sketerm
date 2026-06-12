//! GUI-side host of the sketerm-native app pipe (GUI-only; GTK).
//!
//! One AppHost per `wayland_native` channel: owns the wlhost
//! Compositor (the protocol brain) and renders each toplevel as a
//! plain GtkWindow holding a GtkPicture fed by GdkMemoryTexture —
//! the v1 full-copy pipeline. terminal.zig pumps chan_data payloads
//! in via feed() and ships flush()'d bytes back to the daemon.
//!
//! Input flows back through the compositor's seat (keyboard +
//! pointer); popups render as overlay children inside the parent
//! window; the close button sends xdg_toplevel.close.

const std = @import("std");
const c = @import("c.zig").c;
const builtin = @import("builtin");

// Backend-specific identity calls; the headers are too heavy for
// the cimport set, so declare the handful of symbols directly.
// Referenced only on Linux (comptime-gated) — they resolve there.
extern fn gdk_wayland_toplevel_set_application_id(toplevel: ?*c.GdkSurface, application_id: [*:0]const u8) void;
extern fn gdk_x11_display_get_xdisplay(display: ?*c.GdkDisplay) ?*anyopaque;
extern fn gdk_x11_surface_get_xid(surface: ?*c.GdkSurface) c_ulong;
extern fn XChangeProperty(dpy: ?*anyopaque, win: c_ulong, prop: c_ulong, kind: c_ulong, format: c_int, mode: c_int, data: [*]const u8, n: c_int) c_int;
const cast = @import("util/cast.zig");
const Compositor = @import("wlhost/compositor.zig").Compositor;

pub const AppHost = struct {
    allocator: std.mem.Allocator,
    comp: Compositor,
    windows: std.AutoHashMapUnmanaged(u32, *Win) = .empty,
    /// Popup surfaces, rendered as overlay children of the parent
    /// window (GTK4 has no positioned toplevels — menus clip at the
    /// window edge, same as nested compositors).
    popups: std.AutoHashMapUnmanaged(u32, *Popup) = .empty,
    /// Channel is gone — feed() refuses, windows show stale frames
    /// until the user closes them.
    dead: bool = false,
    /// Hook for shipping requestClose (and other view-initiated
    /// events) immediately rather than on the next feed.
    on_flush: ?*const fn (ctx: ?*anyopaque) void = null,
    flush_ctx: ?*anyopaque = null,
    /// GTK async clipboard reads in flight — their callbacks hold
    /// this AppHost, so destroy() defers the final free until they
    /// all land (doomed marks the limbo state).
    pending_reads: u32 = 0,
    doomed: bool = false,
    /// Surface that last got a clipboard offer — re-offer happens
    /// per keyboard-focus change, not per keystroke.
    offered_focus: u32 = 0,
    /// Title/app_id that arrived BEFORE the first frame created the
    /// window (the usual order) — applied in winFor. Owned strings.
    pending_titles: std.AutoHashMapUnmanaged(u32, []u8) = .empty,
    pending_app_ids: std.AutoHashMapUnmanaged(u32, []u8) = .empty,
    /// Surfaces whose app negotiated server-side decorations before
    /// the window existed (the normal order).
    pending_ssd: std.AutoHashMapUnmanaged(u32, bool) = .empty,

    const Popup = struct {
        host: *AppHost,
        surface: u32,
        /// Window hosting the overlay this popup renders into.
        win: *Win,
        picture: *c.GtkWidget,
    };

    const Win = struct {
        host: *AppHost,
        surface: u32,
        window: *c.GtkWindow,
        /// GtkOverlay between window and picture — popups land here.
        overlay: *c.GtkWidget,
        picture: *c.GtkWidget,
        /// Committed buffer size — the surface coordinate space.
        buf_w: i32 = 0,
        buf_h: i32 = 0,
        /// Last size sent via configureToplevel (resize feedback
        /// guard: don't re-configure what the app already drew).
        sent_w: i32 = 0,
        sent_h: i32 = 0,
        /// Latest button press (widget coords) — gdk's interactive
        /// move/resize grab wants the originating press.
        press_btn: c_uint = 0,
        press_x: f64 = 0,
        press_y: f64 = 0,

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

    /// CSD apps carry alpha (drop shadows, rounded corners) in
    /// their buffers; the host window must not paint a background
    /// behind it or shadows composite onto theme gray.
    fn ensureTransparentCss() void {
        const S = struct {
            var done: bool = false;
        };
        if (S.done) return;
        S.done = true;
        const display = c.gdk_display_get_default() orelse return;
        const provider = c.gtk_css_provider_new();
        c.gtk_css_provider_load_from_string(provider, "window.sketerm-remote-app { background: transparent; }");
        c.gtk_style_context_add_provider_for_display(display, @ptrCast(@alignCast(provider)), c.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
        c.g_object_unref(provider);
    }

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
            .toplevel_app_id = onAppId,
            .toplevel_gone = onGone,
            .popup_new = onPopupNew,
            .popup_gone = onPopupGone,
            .cursor_shape = onCursorShape,
            .toplevel_decoration = onDecoration,
            .toplevel_move = onMove,
            .toplevel_resize = onResize,
            .clipboard_offer = onClipOffer,
            .clipboard_data = onClipData,
            .clipboard_read = onClipRead,
        });
        return self;
    }

    pub fn destroy(self: *AppHost) void {
        self.dead = true;
        var it = self.windows.valueIterator();
        while (it.next()) |w| {
            // Break the close-request link before gtk teardown.
            _ = c.g_object_set_data(@ptrCast(w.*.window), "sketerm-wlapp", null);
            c.gtk_window_destroy(w.*.window);
            self.allocator.destroy(w.*);
        }
        self.windows.deinit(self.allocator);
        var pit = self.popups.valueIterator();
        while (pit.next()) |p| self.allocator.destroy(p.*);
        self.popups.deinit(self.allocator);
        var tit = self.pending_titles.valueIterator();
        while (tit.next()) |v| self.allocator.free(v.*);
        self.pending_titles.deinit(self.allocator);
        var ait = self.pending_app_ids.valueIterator();
        while (ait.next()) |v| self.allocator.free(v.*);
        self.pending_app_ids.deinit(self.allocator);
        self.pending_ssd.deinit(self.allocator);
        if (self.pending_reads > 0) {
            self.doomed = true;
            return;
        }
        self.finalFree();
    }

    fn finalFree(self: *AppHost) void {
        self.comp.deinit();
        self.allocator.destroy(self);
    }

    /// One chan_data payload from the daemon. Errors are protocol
    /// fatal — caller closes the channel.
    pub fn feed(self: *AppHost, bytes: []const u8) !void {
        if (self.dead) return;
        self.stampNow();
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

    fn newTexture(w: i32, h: i32, format: u32, pixels: []const u8) ?*c.GdkTexture {
        // wl_shm: 0 = argb8888 (premultiplied), 1 = xrgb8888 — both
        // little-endian BGRA in memory.
        const gdk_format: c.GdkMemoryFormat = if (format == 1)
            c.GDK_MEMORY_B8G8R8X8
        else
            c.GDK_MEMORY_B8G8R8A8_PREMULTIPLIED;
        const gbytes = c.g_bytes_new(pixels.ptr, pixels.len) orelse return null;
        defer c.g_bytes_unref(gbytes);
        return c.gdk_memory_texture_new(w, h, gdk_format, gbytes, @intCast(w * 4));
    }

    fn onFrame(ctx: ?*anyopaque, surface: u32, w: i32, h: i32, format: u32, pixels: []const u8) void {
        const self = cast.userData(AppHost, ctx);
        if (self.popups.get(surface)) |popup| {
            const tex = newTexture(w, h, format, pixels) orelse return;
            defer c.g_object_unref(tex);
            c.gtk_widget_set_size_request(popup.picture, w, h);
            c.gtk_picture_set_paintable(@ptrCast(popup.picture), @ptrCast(tex));
            return;
        }
        const win = self.winFor(surface, w, h) orelse return;
        win.buf_w = w;
        win.buf_h = h;
        const tex = newTexture(w, h, format, pixels) orelse return;
        defer c.g_object_unref(tex);
        c.gtk_picture_set_paintable(@ptrCast(win.picture), @ptrCast(tex));
    }

    /// A popup landed: hang its picture in the parent window's
    /// overlay at (x, y) — parent may itself be a popup (nested
    /// menus), in which case offsets accumulate.
    fn onPopupNew(ctx: ?*anyopaque, surface: u32, parent: u32, x: i32, y: i32) void {
        const self = cast.userData(AppHost, ctx);
        var px = x;
        var py = y;
        var win: *Win = undefined;
        if (self.windows.get(parent)) |w| {
            win = w;
        } else if (self.popups.get(parent)) |pp| {
            win = pp.win;
            px += c.gtk_widget_get_margin_start(pp.picture);
            py += c.gtk_widget_get_margin_top(pp.picture);
        } else return;

        const popup = self.allocator.create(Popup) catch return;
        const picture = c.gtk_picture_new();
        c.gtk_picture_set_content_fit(@ptrCast(picture), c.GTK_CONTENT_FIT_FILL);
        c.gtk_widget_set_halign(picture, c.GTK_ALIGN_START);
        c.gtk_widget_set_valign(picture, c.GTK_ALIGN_START);
        c.gtk_widget_set_margin_start(picture, @max(0, px));
        c.gtk_widget_set_margin_top(picture, @max(0, py));
        popup.* = .{ .host = self, .surface = surface, .win = win, .picture = picture.? };
        self.popups.put(self.allocator, surface, popup) catch {
            self.allocator.destroy(popup);
            return;
        };
        c.gtk_overlay_add_overlay(@ptrCast(win.overlay), picture);

        const motion = c.gtk_event_controller_motion_new();
        _ = c.g_signal_connect_data(@ptrCast(motion), "enter", @ptrCast(&onPopupPtrEnter), popup, null, 0);
        _ = c.g_signal_connect_data(@ptrCast(motion), "motion", @ptrCast(&onPopupPtrMotion), popup, null, 0);
        c.gtk_widget_add_controller(picture, motion);
        const click = c.gtk_gesture_click_new();
        c.gtk_gesture_single_set_button(@ptrCast(click), 0);
        _ = c.g_signal_connect_data(@ptrCast(click), "pressed", @ptrCast(&onPopupBtnPress), popup, null, 0);
        _ = c.g_signal_connect_data(@ptrCast(click), "released", @ptrCast(&onPopupBtnRelease), popup, null, 0);
        c.gtk_widget_add_controller(picture, @ptrCast(click));
    }

    fn onPopupGone(ctx: ?*anyopaque, surface: u32) void {
        const self = cast.userData(AppHost, ctx);
        const popup = self.popups.get(surface) orelse return;
        _ = self.popups.remove(surface);
        c.gtk_overlay_remove_overlay(@ptrCast(popup.win.overlay), popup.picture);
        self.allocator.destroy(popup);
    }

    fn onPopupPtrEnter(_: ?*c.GtkEventControllerMotion, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
        const popup = cast.userData(Popup, user);
        popup.host.stampNow();
        popup.host.comp.pointerEnter(popup.surface, x, y) catch return;
        popup.host.flushHost();
    }

    fn onPopupPtrMotion(_: ?*c.GtkEventControllerMotion, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
        const popup = cast.userData(Popup, user);
        popup.host.stampNow();
        popup.host.comp.pointerEnter(popup.surface, x, y) catch return;
        popup.host.comp.pointerMotion(x, y) catch return;
        popup.host.flushHost();
    }

    fn onPopupBtnPress(gesture: ?*c.GtkGestureClick, _: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
        const popup = cast.userData(Popup, user);
        popup.host.stampNow();
        popup.host.comp.pointerEnter(popup.surface, x, y) catch return;
        const btn = c.gtk_gesture_single_get_current_button(@ptrCast(gesture));
        popup.host.comp.pointerButton(evdevButton(btn), true) catch return;
        popup.host.flushHost();
    }

    fn onPopupBtnRelease(gesture: ?*c.GtkGestureClick, _: c_int, _: f64, _: f64, user: ?*anyopaque) callconv(.c) void {
        const popup = cast.userData(Popup, user);
        popup.host.stampNow();
        const btn = c.gtk_gesture_single_get_current_button(@ptrCast(gesture));
        popup.host.comp.pointerButton(evdevButton(btn), false) catch return;
        popup.host.flushHost();
    }

    fn onTitle(ctx: ?*anyopaque, surface: u32, title: []const u8) void {
        const self = cast.userData(AppHost, ctx);
        const win = self.windows.get(surface) orelse {
            // Window doesn't exist until the first frame — remember.
            const owned = self.allocator.dupe(u8, title) catch return;
            if (self.pending_titles.fetchPut(self.allocator, surface, owned) catch {
                self.allocator.free(owned);
                return;
            }) |old| self.allocator.free(old.value);
            return;
        };
        var buf: [256:0]u8 = undefined;
        const z = std.fmt.bufPrintZ(&buf, "{s}", .{title}) catch return;
        c.gtk_window_set_title(win.window, z.ptr);
    }

    fn onAppId(ctx: ?*anyopaque, surface: u32, app_id: []const u8) void {
        const self = cast.userData(AppHost, ctx);
        const win = self.windows.get(surface) orelse {
            const owned = self.allocator.dupe(u8, app_id) catch return;
            if (self.pending_app_ids.fetchPut(self.allocator, surface, owned) catch {
                self.allocator.free(owned);
                return;
            }) |old| self.allocator.free(old.value);
            return;
        };
        applyAppId(win, app_id);
    }

    /// Desktop identity: app ids double as icon names by convention
    /// (org.gnome.Calculator etc.), and the window itself gets the
    /// remote app's identity so taskbars group/iconify it as that
    /// app instead of as sketerm.
    fn applyAppId(win: *Win, app_id: []const u8) void {
        var buf: [256:0]u8 = undefined;
        const z = std.fmt.bufPrintZ(&buf, "{s}", .{app_id}) catch return;
        c.gtk_window_set_icon_name(win.window, z.ptr);
        if (comptime !builtin.os.tag.isDarwin()) {
            const display = c.gdk_display_get_default() orelse return;
            const surface = c.gtk_native_get_surface(@ptrCast(win.window)) orelse return;
            const backend = std.mem.span(c.g_type_name_from_instance(@ptrCast(@alignCast(display))));
            if (std.mem.indexOf(u8, backend, "Wayland") != null) {
                gdk_wayland_toplevel_set_application_id(surface, z.ptr);
            } else if (std.mem.indexOf(u8, backend, "X11") != null) {
                const xdpy = gdk_x11_display_get_xdisplay(display) orelse return;
                const xid = gdk_x11_surface_get_xid(surface);
                if (xid == 0) return;
                // WM_CLASS (atom 67), XA_STRING (31), PropModeReplace:
                // "instance\0class\0".
                var cls: [520]u8 = undefined;
                const n = @min(z.len, 255);
                @memcpy(cls[0..n], z[0..n]);
                cls[n] = 0;
                @memcpy(cls[n + 1 ..][0..n], z[0..n]);
                cls[n + 1 + n] = 0;
                _ = XChangeProperty(xdpy, xid, 67, 31, 8, 0, &cls, @intCast(2 * n + 2));
            }
        }
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
        ensureTransparentCss();
        c.gtk_widget_add_css_class(@ptrCast(window), "sketerm-remote-app");
        // Undecorated unless the app asked for host decorations —
        // Wayland apps default to drawing their own chrome, and a
        // second titlebar around it looks broken.
        c.gtk_window_set_decorated(window, @intFromBool(self.pending_ssd.get(surface) orelse false));
        c.gtk_window_set_default_size(window, w, h);
        const overlay = c.gtk_overlay_new();
        c.gtk_overlay_set_child(@ptrCast(overlay), picture);
        c.gtk_window_set_child(window, overlay);
        c.gtk_picture_set_content_fit(@ptrCast(picture), c.GTK_CONTENT_FIT_FILL);
        win.* = .{ .host = self, .surface = surface, .window = window, .overlay = overlay.?, .picture = picture.? };
        self.windows.put(self.allocator, surface, win) catch {
            c.gtk_window_destroy(window);
            self.allocator.destroy(win);
            return null;
        };
        if (self.pending_titles.fetchRemove(surface)) |kv| {
            var tbuf: [256:0]u8 = undefined;
            if (std.fmt.bufPrintZ(&tbuf, "{s}", .{kv.value})) |z| {
                c.gtk_window_set_title(window, z.ptr);
            } else |_| {}
            self.allocator.free(kv.value);
        }
        if (self.pending_app_ids.fetchRemove(surface)) |kv| {
            applyAppId(win, kv.value);
            self.allocator.free(kv.value);
        }
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

        // Window resize → xdg configure, so the app redraws at the
        // new size instead of us stretching stale pixels. GTK4 keeps
        // default-width/height live while the user resizes.
        _ = c.g_signal_connect_data(@ptrCast(window), "notify::default-width", @ptrCast(&onWinResize), win, null, 0);
        _ = c.g_signal_connect_data(@ptrCast(window), "notify::default-height", @ptrCast(&onWinResize), win, null, 0);

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
        win.press_btn = c.gtk_gesture_single_get_current_button(@ptrCast(gesture));
        win.press_x = x;
        win.press_y = y;
        win.host.stampNow();
        // A click on the main surface while a menu is up dismisses it.
        win.host.comp.dismissPopups() catch {};
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
        const target = if (win.host.comp.grabbed_popup != 0) win.host.comp.grabbed_popup else win.surface;
        win.host.comp.keyboardEnter(target) catch return;
        // First key toward a newly focused surface: make sure it
        // has a host-clipboard offer to paste from (the focus
        // controller alone is unreliable under bare X).
        if (win.host.offered_focus != win.host.comp.keyboard_focus) {
            win.host.offered_focus = win.host.comp.keyboard_focus;
            win.host.comp.offerSelection("text/plain;charset=utf-8") catch {};
        }
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
        // Fresh offer per focus: the host clipboard may have changed
        // while the app was unfocused. Empty clipboards just paste
        // empty (the async read answers honestly either way).
        win.host.offered_focus = win.host.comp.keyboard_focus;
        win.host.comp.offerSelection("text/plain;charset=utf-8") catch {};
        win.host.flushHost();
    }

    fn onFocusLeave(_: ?*c.GtkEventControllerFocus, user: ?*anyopaque) callconv(.c) void {
        const win = cast.userData(Win, user);
        win.host.stampNow();
        win.host.comp.keyboardLeave() catch return;
        win.host.flushHost();
    }

    /// cursor-shape-v1 enum → CSS cursor names (GDK speaks CSS).
    const cursor_names = [_][:0]const u8{
        "default",     "context-menu", "help",        "pointer",
        "progress",    "wait",         "cell",        "crosshair",
        "text",        "vertical-text", "alias",      "copy",
        "move",        "no-drop",      "not-allowed", "grab",
        "grabbing",    "e-resize",     "n-resize",    "ne-resize",
        "nw-resize",   "s-resize",     "se-resize",   "sw-resize",
        "w-resize",    "ew-resize",    "ns-resize",   "nesw-resize",
        "nwse-resize", "col-resize",   "row-resize",  "all-scroll",
        "zoom-in",     "zoom-out",
    };

    /// Remote app sets its cursor: apply to the pointer-focused
    /// window's picture so the local pointer matches (text beam
    /// over terminals, hand over links…).
    fn onMove(ctx: ?*anyopaque, surface: u32) void {
        const self = cast.userData(AppHost, ctx);
        const win = self.windows.get(surface) orelse return;
        const display = c.gdk_display_get_default() orelse return;
        const device = c.gdk_seat_get_pointer(c.gdk_display_get_default_seat(display)) orelse return;
        const gdk_surface = c.gtk_native_get_surface(@ptrCast(win.window)) orelse return;
        c.gdk_toplevel_begin_move(@ptrCast(gdk_surface), device, @intCast(win.press_btn), win.press_x, win.press_y, 0);
    }

    fn onResize(ctx: ?*anyopaque, surface: u32, edges: u32) void {
        const self = cast.userData(AppHost, ctx);
        const win = self.windows.get(surface) orelse return;
        const display = c.gdk_display_get_default() orelse return;
        const device = c.gdk_seat_get_pointer(c.gdk_display_get_default_seat(display)) orelse return;
        const gdk_surface = c.gtk_native_get_surface(@ptrCast(win.window)) orelse return;
        // wayland edge bits (1 top, 2 bottom, 4 left, 8 right) →
        // GdkSurfaceEdge enum.
        const edge: c.GdkSurfaceEdge = switch (edges) {
            1 => c.GDK_SURFACE_EDGE_NORTH,
            2 => c.GDK_SURFACE_EDGE_SOUTH,
            4 => c.GDK_SURFACE_EDGE_WEST,
            5 => c.GDK_SURFACE_EDGE_NORTH_WEST,
            6 => c.GDK_SURFACE_EDGE_SOUTH_WEST,
            8 => c.GDK_SURFACE_EDGE_EAST,
            9 => c.GDK_SURFACE_EDGE_NORTH_EAST,
            10 => c.GDK_SURFACE_EDGE_SOUTH_EAST,
            else => return,
        };
        c.gdk_toplevel_begin_resize(@ptrCast(gdk_surface), edge, device, @intCast(win.press_btn), win.press_x, win.press_y, 0);
    }

    fn onDecoration(ctx: ?*anyopaque, surface: u32, ssd: bool) void {
        const self = cast.userData(AppHost, ctx);
        if (self.windows.get(surface)) |win| {
            c.gtk_window_set_decorated(win.window, @intFromBool(ssd));
        } else {
            self.pending_ssd.put(self.allocator, surface, ssd) catch {};
        }
    }

    fn onCursorShape(ctx: ?*anyopaque, shape: u32) void {
        const self = cast.userData(AppHost, ctx);
        if (shape < 1 or shape > cursor_names.len) return;
        const focus = self.comp.pointer_focus;
        if (focus == 0) return;
        const widget: ?*c.GtkWidget = if (self.windows.get(focus)) |win|
            win.picture
        else if (self.popups.get(focus)) |p|
            p.picture
        else
            null;
        if (widget) |wd| c.gtk_widget_set_cursor_from_name(wd, cursor_names[shape - 1].ptr);
    }

    // ── clipboard bridge (compositor seat ↔ GdkClipboard) ───────

    fn gdkClipboard() ?*c.GdkClipboard {
        const display = c.gdk_display_get_default() orelse return null;
        return c.gdk_display_get_clipboard(display);
    }

    /// App announced a copy: pull the content through the pipe; the
    /// answer lands in onClipData.
    fn onClipOffer(ctx: ?*anyopaque, source: u32, mime: []const u8) void {
        const self = cast.userData(AppHost, ctx);
        self.comp.fetchClipboard(source, mime) catch return;
        self.flushHost();
    }

    /// Fetched app clipboard content → host clipboard.
    fn onClipData(ctx: ?*anyopaque, bytes: []const u8) void {
        const self = cast.userData(AppHost, ctx);
        const clipboard = gdkClipboard() orelse return;
        const z = self.allocator.dupeZ(u8, bytes) catch return;
        defer self.allocator.free(z);
        c.gdk_clipboard_set_text(clipboard, z.ptr);
    }

    /// App wants to paste: async-read the host clipboard; ALWAYS
    /// answer (the daemon holds a pipe fd per outstanding read).
    fn onClipRead(ctx: ?*anyopaque, mime: []const u8) void {
        _ = mime; // text-only scope
        const self = cast.userData(AppHost, ctx);
        const clipboard = gdkClipboard() orelse {
            self.comp.sendClipData("") catch return;
            self.flushHost();
            return;
        };
        self.pending_reads += 1;
        c.gdk_clipboard_read_text_async(clipboard, null, @ptrCast(&onClipReadDone), self);
    }

    fn onClipReadDone(src: ?*c.GObject, res: ?*c.GAsyncResult, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(AppHost, user);
        const text = c.gdk_clipboard_read_text_finish(@ptrCast(src), res, null);
        defer if (text != null) c.g_free(text);
        if (!self.dead) {
            const bytes: []const u8 = if (text) |tp| std.mem.span(@as([*:0]const u8, @ptrCast(tp))) else "";
            if (self.comp.sendClipData(bytes)) self.flushHost() else |_| {}
        }
        self.pending_reads -= 1;
        if (self.doomed and self.pending_reads == 0) self.finalFree();
    }

    fn onWinResize(_: ?*c.GtkWindow, _: ?*c.GParamSpec, user: ?*anyopaque) callconv(.c) void {
        const win = cast.userData(Win, user);
        var w: c_int = 0;
        var h: c_int = 0;
        c.gtk_window_get_default_size(win.window, &w, &h);
        if (w <= 0 or h <= 0) return;
        // Skip echoes of the size the app already drew (or that we
        // already asked for) — configure storms upset some clients.
        if ((w == win.buf_w and h == win.buf_h) or (w == win.sent_w and h == win.sent_h)) return;
        win.sent_w = w;
        win.sent_h = h;
        win.host.comp.configureToplevel(win.surface, w, h) catch return;
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
