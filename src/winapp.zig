//! GUI host for window-stream channels (GUI-only; GTK): the render
//! half of "macOS apps on Linux". One WsHost per `winstream`
//! channel; each remote window becomes a GtkWindow + GtkPicture fed
//! by full BGRA frames (winstream/proto.zig). Input goes back as
//! input_* units — evdev key codes and window-local pixels; the
//! remote agent translates. No compositor brain here: the remote
//! end is pixels, not protocol.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig").c;
const cast = @import("util/cast.zig");
const proto = @import("winstream/proto.zig");
const rw = @import("remote_window.zig");
const vcodec = @import("wlhost/vcodec.zig");
const build_options = @import("build_options");

pub const WsHost = struct {
    allocator: std.mem.Allocator,
    windows: std.AutoHashMapUnmanaged(u32, *Win) = .empty,
    inbuf: std.ArrayList(u8) = .empty,
    out: std.ArrayList(u8) = .empty,
    zbuf: std.ArrayList(u8) = .empty,
    /// Scratch for a decoded video tile's BGRA before blitting (-Dvideo).
    vscratch: std.ArrayList(u8) = .empty,
    dead: bool = false,
    on_flush: ?*const fn (ctx: ?*anyopaque) void = null,
    flush_ctx: ?*anyopaque = null,

    const Win = struct {
        host: *WsHost,
        id: u32,
        window: *c.GtkWindow,
        picture: *c.GtkWidget,
        /// Last size applied to the GtkWindow, in points. The remote
        /// window resizes (e.g. Calculator Basic↔Scientific) by sending
        /// frames at a new resolution; we resize the window to match.
        w: i32 = 0,
        h: i32 = 0,
        /// Pending revert of the macOS opaque-resize workaround (0 =
        /// none). See armOpaqueResize.
        opaque_settle_id: c_uint = 0,

        /// Draggable (title-bar) rects measured by the remote daemon's
        /// Accessibility hit-test (proto win_drag), in the window's point
        /// space (ref_w/ref_h). A primary press inside one moves THIS
        /// window locally instead of forwarding the click — a forwarded
        /// title-bar drag moves the window on the Mac, not here.
        drag_rects: []proto.DragRect = &.{},
        drag_ref_w: i16 = 0,
        drag_ref_h: i16 = 0,
        /// False between a title-bar press (which began a local move) and
        /// its release, so the release isn't forwarded either. Mirrors
        /// wlapp.zig's fwd_press for the host-resize band.
        fwd_press: bool = true,

        /// Persistent BGRA backing (w*h*4). Full frames fill it,
        /// damaged patches (win_patch_c) blit into it, and every
        /// present re-wraps it as a texture — so a damaged-rect source
        /// only has to ship the rect, not the whole window.
        backing: std.ArrayList(u8) = .empty,
        /// Lazily-created video decoder for win_vtile updates, recreated
        /// on a dimension/codec change (build_options.video).
        vdec: ?vcodec.Decoder = null,
        vdec_w: i32 = 0,
        vdec_h: i32 = 0,
        vdec_codec: vcodec.Codec = .stub,

        /// Is (x,y) — picture-local — inside a draggable region? Rects are
        /// in point space; scale to the current frame size so the test
        /// matches the press coordinates.
        fn inDragRegion(win: *Win, x: f64, y: f64) bool {
            if (win.drag_rects.len == 0 or win.drag_ref_w <= 0 or win.drag_ref_h <= 0) return false;
            const sx = @as(f64, @floatFromInt(win.w)) / @as(f64, @floatFromInt(win.drag_ref_w));
            const sy = @as(f64, @floatFromInt(win.h)) / @as(f64, @floatFromInt(win.drag_ref_h));
            for (win.drag_rects) |r| {
                const bx = @as(f64, @floatFromInt(r.x)) * sx;
                const by = @as(f64, @floatFromInt(r.y)) * sy;
                const bw = @as(f64, @floatFromInt(r.w)) * sx;
                const bh = @as(f64, @floatFromInt(r.h)) * sy;
                if (x >= bx and x < bx + bw and y >= by and y < by + bh) return true;
            }
            return false;
        }

        /// macOS: a non-opaque NSWindow only composites the region its
        /// backing was last painted into, so a growing window leaves the
        /// new area transparent until the app repaints it. Make the
        /// window opaque for the duration of a resize (the grown region
        /// then composites), reverting ~400ms after it settles. Mirrors
        /// wlapp.zig's armOpaqueResize for the winstream path.
        fn armOpaqueResize(win: *Win) void {
            c.gtk_widget_add_css_class(@ptrCast(win.window), "opaque-resize");
            if (win.opaque_settle_id != 0) _ = c.g_source_remove(win.opaque_settle_id);
            win.opaque_settle_id = c.g_timeout_add(400, @ptrCast(&opaqueRevertCb), win);
        }

        fn cancelOpaqueResize(win: *Win) void {
            if (win.opaque_settle_id != 0) {
                _ = c.g_source_remove(win.opaque_settle_id);
                win.opaque_settle_id = 0;
            }
        }

        /// Queue a pointer unit for this window and flush. `detail`
        /// is the X11 button for press/release, ignored otherwise.
        fn sendPtr(win: *Win, kind: u8, x: f64, y: f64, detail: u32) void {
            proto.appendInputPtr(&win.host.out, win.host.allocator, .{ .win = win.id, .kind = kind, .x = x, .y = y, .detail = detail }) catch return;
            win.host.flush();
        }

        /// Queue a key unit (evdev code + X11-order mods) and flush.
        fn sendKey(win: *Win, key: u32, pressed: bool, state: c.GdkModifierType) void {
            proto.appendInputKey(&win.host.out, win.host.allocator, .{ .win = win.id, .key = key, .pressed = pressed, .mods = @as(u32, @intCast(state)) & 0xff }) catch return;
            win.host.flush();
        }

        /// Re-wrap the backing buffer as a texture and show it.
        fn present(win: *Win) void {
            if (win.w <= 0 or win.h <= 0) return;
            const need: usize = @as(usize, @intCast(win.w)) * @as(usize, @intCast(win.h)) * 4;
            if (win.backing.items.len < need) return;
            // 0 = premultiplied BGRA — what the winstream agent sends.
            const tex = rw.newTexture(win.w, win.h, 0, win.backing.items[0..need]) orelse return;
            defer c.g_object_unref(tex);
            c.gtk_picture_set_paintable(@ptrCast(win.picture), @ptrCast(tex));
        }
    };

    pub fn create(allocator: std.mem.Allocator) !*WsHost {
        const self = try allocator.create(WsHost);
        self.* = .{ .allocator = allocator };
        return self;
    }

    pub fn destroy(self: *WsHost) void {
        var it = self.windows.valueIterator();
        while (it.next()) |w| {
            w.*.cancelOpaqueResize();
            self.allocator.free(w.*.drag_rects);
            w.*.backing.deinit(self.allocator);
            if (w.*.vdec) |*d| d.deinit();
            _ = c.g_object_set_data(@ptrCast(w.*.window), "sketerm-winapp", null);
            c.gtk_window_destroy(w.*.window);
            self.allocator.destroy(w.*);
        }
        self.windows.deinit(self.allocator);
        self.inbuf.deinit(self.allocator);
        self.out.deinit(self.allocator);
        self.zbuf.deinit(self.allocator);
        self.vscratch.deinit(self.allocator);
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
            .win_frame, .win_frame_z => {
                const fr = (proto.decodeFrameAny(u.tag, u.payload, &self.zbuf, self.allocator) catch return error.Protocol) orelse return error.Protocol;
                self.showFrame(fr.win, fr.w, fr.h, fr.pixels);
            },
            .win_frame_c => {
                const fr = (proto.decodeFrameC(u.payload, &self.zbuf, self.allocator) catch return error.Protocol) orelse return error.Protocol;
                self.showFrame(fr.win, fr.w, fr.h, fr.pixels);
            },
            .win_patch_c => {
                const p = (proto.decodePatchC(u.payload, &self.zbuf, self.allocator) catch return error.Protocol) orelse return error.Protocol;
                self.showPatch(p);
            },
            .win_vtile => if (comptime build_options.video) {
                const wv = proto.decodeWinVtile(u.payload) orelse return error.Protocol;
                const peeled = (vcodec.peelTile(wv.blob) catch return error.Protocol) orelse return error.Protocol;
                const tile = peeled.tile;
                if (tile.w <= 0 or tile.h <= 0) return error.Protocol;
                const win = self.windows.get(wv.win) orelse return;
                if (win.backing.items.len == 0) return; // need a base frame first
                if (win.vdec == null or win.vdec_w != tile.w or win.vdec_h != tile.h or win.vdec_codec != tile.codec) {
                    if (win.vdec) |*d| d.deinit();
                    win.vdec = vcodec.Decoder.initAvcodec(self.allocator, tile.w, tile.h, tile.codec) catch return error.Protocol;
                    win.vdec_w = tile.w;
                    win.vdec_h = tile.h;
                    win.vdec_codec = tile.codec;
                }
                const need: usize = @as(usize, @intCast(tile.w)) * @as(usize, @intCast(tile.h)) * 4;
                try self.vscratch.resize(self.allocator, need);
                win.vdec.?.decodeTile(tile, self.vscratch.items) catch return error.Protocol;
                rw.blitRect(win.backing.items, win.w, win.h, self.vscratch.items, tile.x, tile.y, tile.w, tile.h);
                win.present();
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
                win.cancelOpaqueResize();
                self.allocator.free(win.drag_rects);
                win.backing.deinit(self.allocator);
                if (win.vdec) |*d| d.deinit();
                _ = c.g_object_set_data(@ptrCast(win.window), "sketerm-winapp", null);
                c.gtk_window_destroy(win.window);
                self.allocator.destroy(win);
            },
            .win_drag => {
                const wd = proto.decodeWinDrag(u.payload) orelse return error.Protocol;
                const win = self.windows.get(wd.win) orelse return;
                self.allocator.free(win.drag_rects);
                win.drag_rects = &.{};
                if (wd.n > 0) {
                    const buf = self.allocator.alloc(proto.DragRect, wd.n) catch return;
                    for (0..wd.n) |i| buf[i] = proto.dragRectAt(wd.body, i);
                    win.drag_rects = buf;
                }
                win.drag_ref_w = wd.ref_w;
                win.drag_ref_h = wd.ref_h;
            },
            else => {},
        }
    }

    fn showFrame(self: *WsHost, id: u32, w: i32, h: i32, pixels: []const u8) void {
        const win = self.winFor(id, w, h, "remote window") orelse return;
        const need: usize = @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4;
        if (pixels.len < need) return;
        win.backing.resize(self.allocator, need) catch return;
        @memcpy(win.backing.items, pixels[0..need]);
        win.present();
    }

    /// Apply a damaged sub-rect into the window's backing, then present.
    /// Dropped if no full frame has established the backing yet.
    fn showPatch(self: *WsHost, p: proto.Patch) void {
        const win = self.windows.get(p.win) orelse return;
        if (win.backing.items.len == 0) return;
        rw.blitRect(win.backing.items, win.w, win.h, p.pixels, p.x, p.y, p.w, p.h);
        win.present();
    }

    fn winFor(self: *WsHost, id: u32, w: i32, h: i32, title: []const u8) ?*Win {
        if (self.windows.get(id)) |win| {
            // Remote window changed size — track it and resize the
            // GtkWindow so the picture isn't scaled into a stale box.
            if (w > 0 and h > 0 and (win.w != w or win.h != h)) {
                win.w = w;
                win.h = h;
                c.gtk_window_set_default_size(win.window, w, h);
                if (builtin.os.tag == .macos) win.armOpaqueResize();
            }
            return win;
        }
        const win = self.allocator.create(Win) catch return null;
        // Same free-floating chrome as a Wayland app window —
        // undecorated (the macOS title bar is in the captured
        // pixels), transparent, taskbar-joined. See remote_window.zig.
        var tbuf: [256:0]u8 = undefined;
        const tz: [:0]const u8 = std.fmt.bufPrintZ(&tbuf, "{s}", .{title}) catch "remote app";
        const widgets = rw.create(tz, w, h, false) orelse {
            self.allocator.destroy(win);
            return null;
        };
        const window = widgets.window;
        const picture = widgets.picture;
        win.* = .{ .host = self, .id = id, .window = window, .picture = picture, .w = w, .h = h };
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

    fn opaqueRevertCb(user: ?*anyopaque) callconv(.c) c.gboolean {
        const win = cast.userData(Win, user);
        win.opaque_settle_id = 0;
        c.gtk_widget_remove_css_class(@ptrCast(win.window), "opaque-resize");
        return 0;
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
        cast.userData(Win, user).sendPtr(0, x, y, 0);
    }

    fn onPress(g: ?*c.GtkGestureClick, _: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
        const win = cast.userData(Win, user);
        const btn = c.gtk_gesture_single_get_current_button(@ptrCast(g));
        // A primary press on a title-bar region drags THIS window via the
        // window manager — don't forward it, or the Mac moves its own
        // window and ours stays put.
        if (btn == 1 and win.inDragRegion(x, y)) {
            win.fwd_press = false;
            // Claim the sequence BEFORE begin_move — as GtkWindowHandle
            // does. The interactive move hands the pointer grab to the
            // compositor, so this gesture never sees the button-release;
            // claiming resolves the sequence cleanly so it resets and
            // keeps firing for later clicks. Without it the gesture stays
            // stuck on button 1 and every subsequent click is swallowed.
            _ = c.gtk_gesture_set_state(@ptrCast(g), c.GTK_EVENT_SEQUENCE_CLAIMED);
            rw.beginMove(win.window, btn, x, y);
            return;
        }
        win.fwd_press = true;
        win.sendPtr(1, x, y, btn);
    }

    fn onRelease(g: ?*c.GtkGestureClick, _: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
        const win = cast.userData(Win, user);
        if (!win.fwd_press) return; // press began a local move, not app input
        const btn = c.gtk_gesture_single_get_current_button(@ptrCast(g));
        win.sendPtr(2, x, y, btn);
    }

    fn onScroll(ctl: ?*c.GtkEventControllerScroll, dx: f64, dy: f64, user: ?*anyopaque) callconv(.c) c.gboolean {
        // Wheel events arrive as ±1 notches; touchpads report
        // surface pixels — normalize to wheel-line-ish units so the
        // agent can treat x/y as scroll lines.
        const surface = c.gtk_event_controller_scroll_get_unit(ctl) == c.GDK_SCROLL_UNIT_SURFACE;
        const scale: f64 = if (surface) 40.0 else 1.0;
        cast.userData(Win, user).sendPtr(3, dx / scale, dy / scale, 0);
        return 1;
    }

    fn onKeyPress(_: ?*c.GtkEventControllerKey, _: c_uint, keycode: c_uint, state: c.GdkModifierType, user: ?*anyopaque) callconv(.c) c.gboolean {
        if (keycode >= 8) cast.userData(Win, user).sendKey(keycode - 8, true, state);
        return 1;
    }

    fn onKeyRelease(_: ?*c.GtkEventControllerKey, _: c_uint, keycode: c_uint, state: c.GdkModifierType, user: ?*anyopaque) callconv(.c) void {
        if (keycode >= 8) cast.userData(Win, user).sendKey(keycode - 8, false, state);
    }
};
