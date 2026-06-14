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
const builtin = @import("builtin");
const c = @import("c.zig").c;
const cast = @import("util/cast.zig");
// Shared free-floating-window chrome (creation, transparent CSS, app
// identity, move/resize, texture) — identical to what the winstream
// renderer uses, so the two stay byte-for-byte the same window.
const rw = @import("remote_window.zig");
const Compositor = @import("wlhost/compositor.zig").Compositor;

pub const AppHost = struct {
    allocator: std.mem.Allocator,
    comp: Compositor,
    windows: std.AutoHashMapUnmanaged(u32, *Win) = .empty,
    /// Popup surfaces, rendered as overlay children of the parent
    /// window (GTK4 has no positioned toplevels — menus clip at the
    /// window edge, same as nested compositors).
    popups: std.AutoHashMapUnmanaged(u32, *Popup) = .empty,
    /// Subsurface surfaces (GTK3 tooltips / tree-view type-ahead),
    /// rendered as overlay children at a parent-relative offset.
    subsurfaces: std.AutoHashMapUnmanaged(u32, *Subsurface) = .empty,
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
    /// Committed window-geometry rect per surface ({x, y, w, h} in
    /// buffer coords): the visible window inside the buffer, the rest
    /// being CSD shadow. The full buffer is shown (shadow visible); the
    /// shadow is reported as the host toplevel's shadow width so the WM
    /// snaps/maximizes to this rect, not the shadow edge.
    geos: std.AutoHashMapUnmanaged(u32, [4]i32) = .empty,

    /// An owned copy of a surface's physical (HiDPI) pixels, drawn by a
    /// GtkDrawingArea sized to LOGICAL units — so overlay children are
    /// correctly sized AND crisp (GtkPicture would treat the physical
    /// pixel count as the logical size and render them oversized).
    const OverlayTex = struct {
        pixels: []u8 = &.{},
        pw: i32 = 0,
        ph: i32 = 0,
        format: u32 = 0,

        fn set(self: *OverlayTex, alloc: std.mem.Allocator, w: i32, h: i32, format: u32, pixels: []const u8) void {
            const new = alloc.dupe(u8, pixels) catch return;
            if (self.pixels.len > 0) alloc.free(self.pixels);
            self.pixels = new;
            self.pw = w;
            self.ph = h;
            self.format = format;
        }
        fn deinit(self: *OverlayTex, alloc: std.mem.Allocator) void {
            if (self.pixels.len > 0) alloc.free(self.pixels);
            self.pixels = &.{};
        }
        /// Paint at full resolution into a `lw`×`lh` logical area.
        fn draw(self: *OverlayTex, cr: ?*c.cairo_t, lw: c_int, lh: c_int) void {
            if (self.pixels.len == 0 or self.pw <= 0 or self.ph <= 0 or lw <= 0 or lh <= 0) return;
            const fmt: c.cairo_format_t = if (self.format == 1) c.CAIRO_FORMAT_RGB24 else c.CAIRO_FORMAT_ARGB32;
            const surf = c.cairo_image_surface_create_for_data(@constCast(self.pixels.ptr), fmt, self.pw, self.ph, self.pw * 4) orelse return;
            defer c.cairo_surface_destroy(surf);
            c.cairo_save(cr);
            c.cairo_scale(cr, @as(f64, @floatFromInt(lw)) / @as(f64, @floatFromInt(self.pw)), @as(f64, @floatFromInt(lh)) / @as(f64, @floatFromInt(self.ph)));
            c.cairo_set_source_surface(cr, surf, 0, 0);
            if (c.cairo_get_source(cr)) |pat| c.cairo_pattern_set_filter(pat, c.CAIRO_FILTER_GOOD);
            c.cairo_paint(cr);
            c.cairo_restore(cr);
        }
    };

    const Popup = struct {
        host: *AppHost,
        surface: u32,
        /// Window hosting the overlay this popup renders into.
        win: *Win,
        area: *c.GtkWidget, // GtkDrawingArea
        tex: OverlayTex = .{},
    };

    /// A subsurface rendered into a parent window's overlay at a
    /// parent-relative offset. Input-transparent (the app routes input
    /// through the parent surface).
    const Subsurface = struct {
        host: *AppHost,
        surface: u32,
        /// Window hosting the overlay this subsurface renders into.
        win: *Win,
        area: *c.GtkWidget, // GtkDrawingArea
        tex: OverlayTex = .{},
        /// Offset inherited from the parent chain (toplevel-relative).
        /// The subsurface's own set_position is added on top.
        cox: i32 = 0,
        coy: i32 = 0,
    };

    const Win = struct {
        host: *AppHost,
        surface: u32,
        window: *c.GtkWindow,
        /// GtkOverlay between window and picture — popups land here.
        overlay: *c.GtkWidget,
        picture: *c.GtkWidget,
        /// Committed surface size in LOGICAL units (physical buffer
        /// size ÷ buffer scale) — the surface coordinate space. The
        /// texture itself is shown at full physical resolution.
        buf_w: i32 = 0,
        buf_h: i32 = 0,
        /// Displayed sub-rect of the buffer in LOGICAL surface coords
        /// (x, y, w, h). Full buffer on Linux; the window-geometry rect
        /// on macOS (CSD shadow cropped). mapXY + popups read these.
        crop_x: i32 = 0,
        crop_y: i32 = 0,
        crop_w: i32 = 0,
        crop_h: i32 = 0,
        /// Last size sent via configureToplevel (resize feedback
        /// guard: don't re-configure what the app already drew).
        sent_w: i32 = 0,
        sent_h: i32 = 0,
        /// Latest button press (widget coords) — gdk's interactive
        /// move/resize grab wants the originating press.
        press_btn: c_uint = 0,
        press_x: f64 = 0,
        press_y: f64 = 0,
        /// Last host-edge band the pointer was in (Wayland edge mask,
        /// 0 = interior). Drives the resize cursor and gates whether a
        /// press starts a host-window resize vs. goes to the app.
        hover_edge: u32 = 0,
        /// The last press was forwarded to the app (not consumed as a
        /// host-window resize) — so its release is forwarded too.
        fwd_press: bool = false,
        /// macOS only: debounce timer that reverts the window to
        /// transparent after a resize settles (0 = inactive). See
        /// armOpaqueResize.
        opaque_settle_id: c_uint = 0,

        /// Host-window resize edge under (x, y) in picture coords, or 0
        /// for the interior. Disabled while maximized/fullscreen (the
        /// WM owns the size then).
        fn resizeEdge(self: *Win, x: f64, y: f64) u32 {
            if (c.gtk_window_is_maximized(self.window) != 0) return 0;
            if (c.gtk_window_is_fullscreen(self.window) != 0) return 0;
            return rw.resizeEdgeAt(c.gtk_widget_get_width(self.picture), c.gtk_widget_get_height(self.picture), x, y);
        }

        /// Apply the resize cursor (or hand the cursor back to the app)
        /// when the pointer crosses into/out of an edge band.
        fn applyEdge(self: *Win, edge: u32) void {
            if (edge == self.hover_edge) return;
            self.hover_edge = edge;
            if (rw.edgeCursorName(edge)) |name|
                c.gtk_widget_set_cursor_from_name(self.picture, name)
            else
                c.gtk_widget_set_cursor(self.picture, null);
        }

        /// Widget → surface coordinates. The picture shows the displayed
        /// crop rect (full buffer on Linux; the geometry rect on macOS),
        /// so scale widget coords across that rect and add its origin.
        fn mapXY(self: *Win, wx: f64, wy: f64) [2]f64 {
            const ww = c.gtk_widget_get_width(self.picture);
            const wh = c.gtk_widget_get_height(self.picture);
            const cw = if (self.crop_w > 0) self.crop_w else self.buf_w;
            const ch = if (self.crop_h > 0) self.crop_h else self.buf_h;
            if (ww > 0 and wh > 0 and cw > 0 and ch > 0) {
                return .{
                    @as(f64, @floatFromInt(self.crop_x)) + wx * @as(f64, @floatFromInt(cw)) / @as(f64, @floatFromInt(ww)),
                    @as(f64, @floatFromInt(self.crop_y)) + wy * @as(f64, @floatFromInt(ch)) / @as(f64, @floatFromInt(wh)),
                };
            }
            return .{ wx, wy };
        }

        /// Host toplevel shadow width {left, right, top, bottom} = the
        /// buffer area outside the committed window geometry (the CSD
        /// shadow margin). Reported via the compute-size signal so the
        /// WM treats the geometry rect — not the shadow — as the window.
        fn shadowMargins(self: *Win) [4]i32 {
            // macOS crops the shadow out of the displayed buffer, so the
            // toplevel has no shadow margin to report.
            if (builtin.os.tag == .macos) return .{ 0, 0, 0, 0 };
            const geo = self.host.geos.get(self.surface) orelse return .{ 0, 0, 0, 0 };
            if (geo[2] <= 0 or geo[3] <= 0 or self.buf_w <= 0 or self.buf_h <= 0) return .{ 0, 0, 0, 0 };
            return .{
                @max(0, geo[0]), // left
                @max(0, self.buf_w - geo[0] - geo[2]), // right
                @max(0, geo[1]), // top
                @max(0, self.buf_h - geo[1] - geo[3]), // bottom
            };
        }

        /// macOS: a non-opaque NSWindow only composites the region its
        /// backing was last painted into, so a growing window clips the
        /// new area. Make the window opaque for the duration of a resize
        /// (the grown region then composites), reverting to transparent
        /// ~400ms after it settles — the grown region stays painted, and
        /// at rest the app's own transparency (rounded corners,
        /// translucent terminals) is preserved. Idempotent per tick.
        fn armOpaqueResize(self: *Win) void {
            c.gtk_widget_add_css_class(@ptrCast(self.window), "opaque-resize");
            if (self.opaque_settle_id != 0) _ = c.g_source_remove(self.opaque_settle_id);
            self.opaque_settle_id = c.g_timeout_add(400, @ptrCast(&opaqueRevertCb), self);
        }

        fn cancelOpaqueResize(self: *Win) void {
            if (self.opaque_settle_id != 0) {
                _ = c.g_source_remove(self.opaque_settle_id);
                self.opaque_settle_id = 0;
            }
        }
    };

    fn opaqueRevertCb(user: ?*anyopaque) callconv(.c) c.gboolean {
        const win = cast.userData(Win, user);
        win.opaque_settle_id = 0;
        c.gtk_widget_remove_css_class(@ptrCast(win.window), "opaque-resize");
        return 0;
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
            .subsurface_new = onSubsurfaceNew,
            .subsurface_pos = onSubsurfacePos,
            .subsurface_gone = onSubsurfaceGone,
            .cursor_shape = onCursorShape,
            .toplevel_decoration = onDecoration,
            .toplevel_move = onMove,
            .toplevel_resize = onResize,
            .input_region = onInputRegion,
            .toplevel_geometry = onGeometry,
            .toplevel_parent = onParent,
            .toplevel_min_size = onMinSize,
            .toplevel_state_request = onStateRequest,
            .clipboard_offer = onClipOffer,
            .clipboard_data = onClipData,
            .clipboard_read = onClipRead,
        });
        // Advertise the local display scale so apps render HiDPI
        // buffers (set before the app binds wl_output on first feed).
        self.comp.output_scale = localScale();
        return self;
    }

    /// Integer scale factor of the primary monitor (1 unless HiDPI).
    fn localScale() i32 {
        const display = c.gdk_display_get_default() orelse return 1;
        const monitors = c.gdk_display_get_monitors(display) orelse return 1;
        const mon = c.g_list_model_get_item(@ptrCast(monitors), 0) orelse return 1;
        defer c.g_object_unref(mon);
        const sf = c.gdk_monitor_get_scale_factor(@ptrCast(@alignCast(mon)));
        return if (sf > 0) sf else 1;
    }

    pub fn destroy(self: *AppHost) void {
        self.dead = true;
        var it = self.windows.valueIterator();
        while (it.next()) |w| {
            // Break the close-request link before gtk teardown.
            w.*.cancelOpaqueResize();
            _ = c.g_object_set_data(@ptrCast(w.*.window), "sketerm-wlapp", null);
            c.gtk_window_destroy(w.*.window);
            self.allocator.destroy(w.*);
        }
        self.windows.deinit(self.allocator);
        var pit = self.popups.valueIterator();
        while (pit.next()) |p| {
            p.*.tex.deinit(self.allocator);
            self.allocator.destroy(p.*);
        }
        self.popups.deinit(self.allocator);
        var sit = self.subsurfaces.valueIterator();
        while (sit.next()) |s| {
            s.*.tex.deinit(self.allocator);
            self.allocator.destroy(s.*);
        }
        self.subsurfaces.deinit(self.allocator);
        var tit = self.pending_titles.valueIterator();
        while (tit.next()) |v| self.allocator.free(v.*);
        self.pending_titles.deinit(self.allocator);
        var ait = self.pending_app_ids.valueIterator();
        while (ait.next()) |v| self.allocator.free(v.*);
        self.pending_app_ids.deinit(self.allocator);
        self.pending_ssd.deinit(self.allocator);
        self.geos.deinit(self.allocator);
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

    fn onFrame(ctx: ?*anyopaque, surface: u32, w: i32, h: i32, scale: i32, format: u32, pixels: []const u8) void {
        const self = cast.userData(AppHost, ctx);
        // The buffer is physical pixels (scale× the surface-local size).
        // GTK sizes (windows, overlay children, positions, the pointer
        // map) are LOGICAL = physical ÷ the surface's buffer scale; the
        // texture itself stays physical (HiDPI-crisp).
        const s: i32 = if (scale > 0) scale else 1;
        const lw = @divTrunc(w, s);
        const lh = @divTrunc(h, s);
        if (self.popups.get(surface)) |popup| {
            popup.tex.set(self.allocator, w, h, format, pixels);
            c.gtk_drawing_area_set_content_width(@ptrCast(popup.area), lw);
            c.gtk_drawing_area_set_content_height(@ptrCast(popup.area), lh);
            c.gtk_widget_queue_draw(popup.area);
            // Constraint adjustment, slide-style: keep the popup
            // inside the host window now that its size is known.
            const pw = c.gtk_widget_get_width(popup.win.picture);
            const ph = c.gtk_widget_get_height(popup.win.picture);
            if (pw > 0 and ph > 0) {
                const mx = c.gtk_widget_get_margin_start(popup.area);
                const my = c.gtk_widget_get_margin_top(popup.area);
                const cx = std.math.clamp(mx, 0, @max(0, pw - lw));
                const cy = std.math.clamp(my, 0, @max(0, ph - lh));
                if (cx != mx) c.gtk_widget_set_margin_start(popup.area, cx);
                if (cy != my) c.gtk_widget_set_margin_top(popup.area, cy);
            }
            return;
        }
        if (self.subsurfaces.get(surface)) |sub| {
            sub.tex.set(self.allocator, w, h, format, pixels);
            c.gtk_drawing_area_set_content_width(@ptrCast(sub.area), lw);
            c.gtk_drawing_area_set_content_height(@ptrCast(sub.area), lh);
            c.gtk_widget_queue_draw(sub.area);
            return;
        }
        // Displayed region in LOGICAL surface coords. Linux shows the
        // full buffer and reports the CSD shadow as the toplevel's
        // shadow width; macOS ignores shadow-width, so it crops the
        // buffer to the window-geometry rect and sizes the window to it
        // (otherwise the shadow shows as a fat border).
        var dx: i32 = 0;
        var dy: i32 = 0;
        var dw: i32 = lw;
        var dh: i32 = lh;
        if (builtin.os.tag == .macos) {
            if (self.geos.get(surface)) |g| {
                if (g[2] > 0 and g[3] > 0 and g[0] >= 0 and g[1] >= 0 and g[0] + g[2] <= lw and g[1] + g[3] <= lh) {
                    dx = g[0];
                    dy = g[1];
                    dw = g[2];
                    dh = g[3];
                }
            }
        }
        const win = self.winFor(surface, dw, dh) orelse return;
        win.buf_w = lw;
        win.buf_h = lh;
        // Geometry size changed (app self-resize or first frame): match
        // the host window to it. Same-size calls no-op in GTK.
        if (builtin.os.tag == .macos and (dw != win.crop_w or dh != win.crop_h)) {
            c.gtk_window_set_default_size(win.window, dw, dh);
        }
        win.crop_x = dx;
        win.crop_y = dy;
        win.crop_w = dw;
        win.crop_h = dh;
        const cropped = (dx != 0 or dy != 0 or dw != lw or dh != lh);
        const tex = (if (cropped)
            rw.newTextureCropped(w, h, format, pixels, dx * s, dy * s, dw * s, dh * s)
        else
            rw.newTexture(w, h, format, pixels)) orelse return;
        defer c.g_object_unref(tex);
        c.gtk_picture_set_paintable(@ptrCast(win.picture), @ptrCast(tex));
    }

    fn onPopupDraw(_: ?*c.GtkDrawingArea, cr: ?*c.cairo_t, width: c_int, height: c_int, user: ?*anyopaque) callconv(.c) void {
        cast.userData(Popup, user).tex.draw(cr, width, height);
    }
    fn onSubsurfaceDraw(_: ?*c.GtkDrawingArea, cr: ?*c.cairo_t, width: c_int, height: c_int, user: ?*anyopaque) callconv(.c) void {
        cast.userData(Subsurface, user).tex.draw(cr, width, height);
    }

    /// A subsurface gained its role: render it in the parent window's
    /// overlay. Parent may be a toplevel, a popup, or another
    /// subsurface — offsets accumulate up the chain.
    fn onSubsurfaceNew(ctx: ?*anyopaque, surface: u32, parent: u32, x: i32, y: i32) void {
        const self = cast.userData(AppHost, ctx);
        // x,y from the compositor is the initial (0,0); set_position
        // follows. Capture only the inherited chain offset here.
        var cox = x;
        var coy = y;
        var win: *Win = undefined;
        if (self.windows.get(parent)) |w| {
            win = w;
            // Parent-relative coords are in the toplevel's window
            // geometry; the Linux overlay is in buffer coords (shadow
            // shown), so shift past the shadow. macOS crops to geometry,
            // so the overlay origin already IS the geometry origin.
            if (builtin.os.tag != .macos) {
                if (self.geos.get(parent)) |g| {
                    cox += g[0];
                    coy += g[1];
                }
            }
        } else if (self.popups.get(parent)) |pp| {
            win = pp.win;
            cox += c.gtk_widget_get_margin_start(pp.area);
            coy += c.gtk_widget_get_margin_top(pp.area);
        } else if (self.subsurfaces.get(parent)) |ps| {
            win = ps.win;
            cox += c.gtk_widget_get_margin_start(ps.area);
            coy += c.gtk_widget_get_margin_top(ps.area);
        } else return;

        const sub = self.allocator.create(Subsurface) catch return;
        const area = c.gtk_drawing_area_new();
        c.gtk_widget_set_halign(area, c.GTK_ALIGN_START);
        c.gtk_widget_set_valign(area, c.GTK_ALIGN_START);
        c.gtk_widget_set_can_target(area, 0); // input-transparent
        c.gtk_widget_set_margin_start(area, @max(0, cox));
        c.gtk_widget_set_margin_top(area, @max(0, coy));
        sub.* = .{ .host = self, .surface = surface, .win = win, .area = area.?, .cox = cox, .coy = coy };
        c.gtk_drawing_area_set_draw_func(@ptrCast(area), @ptrCast(&onSubsurfaceDraw), sub, null);
        self.subsurfaces.put(self.allocator, surface, sub) catch {
            self.allocator.destroy(sub);
            return;
        };
        c.gtk_overlay_add_overlay(@ptrCast(win.overlay), area);
    }

    fn onSubsurfacePos(ctx: ?*anyopaque, surface: u32, x: i32, y: i32) void {
        const self = cast.userData(AppHost, ctx);
        const sub = self.subsurfaces.get(surface) orelse return;
        c.gtk_widget_set_margin_start(sub.area, @max(0, sub.cox + x));
        c.gtk_widget_set_margin_top(sub.area, @max(0, sub.coy + y));
    }

    fn onSubsurfaceGone(ctx: ?*anyopaque, surface: u32) void {
        const self = cast.userData(AppHost, ctx);
        const sub = self.subsurfaces.get(surface) orelse return;
        _ = self.subsurfaces.remove(surface);
        c.gtk_overlay_remove_overlay(@ptrCast(sub.win.overlay), sub.area);
        sub.tex.deinit(self.allocator);
        self.allocator.destroy(sub);
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
            // Positioner coords are in the parent's window geometry; the
            // Linux overlay is in buffer coords, so shift past the shadow.
            // macOS crops to geometry — origin already matches.
            if (builtin.os.tag != .macos) {
                if (self.geos.get(parent)) |g| {
                    px += g[0];
                    py += g[1];
                }
            }
        } else if (self.popups.get(parent)) |pp| {
            win = pp.win;
            px += c.gtk_widget_get_margin_start(pp.area);
            py += c.gtk_widget_get_margin_top(pp.area);
        } else return;

        const popup = self.allocator.create(Popup) catch return;
        const area = c.gtk_drawing_area_new();
        c.gtk_widget_set_halign(area, c.GTK_ALIGN_START);
        c.gtk_widget_set_valign(area, c.GTK_ALIGN_START);
        c.gtk_widget_set_margin_start(area, @max(0, px));
        c.gtk_widget_set_margin_top(area, @max(0, py));
        popup.* = .{ .host = self, .surface = surface, .win = win, .area = area.? };
        c.gtk_drawing_area_set_draw_func(@ptrCast(area), @ptrCast(&onPopupDraw), popup, null);
        self.popups.put(self.allocator, surface, popup) catch {
            self.allocator.destroy(popup);
            return;
        };
        c.gtk_overlay_add_overlay(@ptrCast(win.overlay), area);

        const motion = c.gtk_event_controller_motion_new();
        _ = c.g_signal_connect_data(@ptrCast(motion), "enter", @ptrCast(&onPopupPtrEnter), popup, null, 0);
        _ = c.g_signal_connect_data(@ptrCast(motion), "motion", @ptrCast(&onPopupPtrMotion), popup, null, 0);
        c.gtk_widget_add_controller(area, motion);
        const click = c.gtk_gesture_click_new();
        c.gtk_gesture_single_set_button(@ptrCast(click), 0);
        _ = c.g_signal_connect_data(@ptrCast(click), "pressed", @ptrCast(&onPopupBtnPress), popup, null, 0);
        _ = c.g_signal_connect_data(@ptrCast(click), "released", @ptrCast(&onPopupBtnRelease), popup, null, 0);
        c.gtk_widget_add_controller(area, @ptrCast(click));
    }

    fn onPopupGone(ctx: ?*anyopaque, surface: u32) void {
        const self = cast.userData(AppHost, ctx);
        const popup = self.popups.get(surface) orelse return;
        _ = self.popups.remove(surface);
        c.gtk_overlay_remove_overlay(@ptrCast(popup.win.overlay), popup.area);
        popup.tex.deinit(self.allocator);
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
        rw.applyAppId(win.window, app_id);
    }

    fn onGone(ctx: ?*anyopaque, surface: u32) void {
        const self = cast.userData(AppHost, ctx);
        const win = self.windows.get(surface) orelse return;
        _ = self.windows.remove(surface);
        win.cancelOpaqueResize();
        _ = c.g_object_set_data(@ptrCast(win.window), "sketerm-wlapp", null);
        c.gtk_window_destroy(win.window);
        self.allocator.destroy(win);
    }

    /// Window for a surface, created on first frame (when the size
    /// is finally known).
    fn winFor(self: *AppHost, surface: u32, w: i32, h: i32) ?*Win {
        if (self.windows.get(surface)) |win| return win;

        const win = self.allocator.create(Win) catch return null;
        // Same free-floating chrome the winstream renderer builds —
        // undecorated (unless the app negotiated host decorations),
        // transparent, taskbar-joined. See remote_window.zig.
        const widgets = rw.create("remote app", w, h, self.pending_ssd.get(surface) orelse false) orelse {
            self.allocator.destroy(win);
            return null;
        };
        const window = widgets.window;
        const picture = widgets.picture;
        win.* = .{ .host = self, .surface = surface, .window = window, .overlay = widgets.overlay, .picture = picture };
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
            rw.applyAppId(win.window, kv.value);
            self.allocator.free(kv.value);
        }
        _ = c.g_object_set_data(@ptrCast(window), "sketerm-wlapp", win);
        _ = c.g_signal_connect_data(@ptrCast(window), "close-request", @ptrCast(&onCloseRequest), win, null, 0);
        // Report the CSD shadow as the toplevel's shadow width once the
        // GdkSurface exists, so the WM snaps/maximizes to the geometry.
        _ = c.g_signal_connect_data(@ptrCast(window), "realize", @ptrCast(&onWinRealize), win, null, 0);

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
        // default-size does NOT track maximization — listen and
        // configure with the real allocation + maximized state.
        _ = c.g_signal_connect_data(@ptrCast(window), "notify::maximized", @ptrCast(&onWinResize), win, null, 0);
        _ = c.g_signal_connect_data(@ptrCast(window), "notify::fullscreened", @ptrCast(&onWinResize), win, null, 0);
        // Apps render inactive chrome when not activated.
        _ = c.g_signal_connect_data(@ptrCast(window), "notify::is-active", @ptrCast(&onWinState), win, null, 0);

        c.gtk_window_present(window);
        return win;
    }

    // ── input handlers (GTK → compositor seat) ──────────────────

    fn flushHost(self: *AppHost) void {
        if (self.on_flush) |f| f(self.flush_ctx);
    }

    fn onPtrEnter(_: ?*c.GtkEventControllerMotion, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
        const win = cast.userData(Win, user);
        const edge = win.resizeEdge(x, y);
        win.applyEdge(edge);
        if (edge != 0) return; // host resize band — not the app's pointer
        win.host.stampNow();
        const p = win.mapXY(x, y);
        win.host.comp.pointerEnter(win.surface, p[0], p[1]) catch return;
        win.host.flushHost();
    }

    fn onPtrMotion(_: ?*c.GtkEventControllerMotion, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
        const win = cast.userData(Win, user);
        const edge = win.resizeEdge(x, y);
        win.applyEdge(edge);
        if (edge != 0) return; // host resize band — not the app's pointer
        win.host.stampNow();
        const p = win.mapXY(x, y);
        // Enter may have been missed (window created under cursor).
        win.host.comp.pointerEnter(win.surface, p[0], p[1]) catch return;
        win.host.comp.pointerMotion(p[0], p[1]) catch return;
        win.host.flushHost();
    }

    fn onPtrLeave(_: ?*c.GtkEventControllerMotion, user: ?*anyopaque) callconv(.c) void {
        const win = cast.userData(Win, user);
        win.applyEdge(0);
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
        // A primary-button press in the host edge band resizes the host
        // window itself — the app's cropped buffer has no CSD handles
        // (they live in the shadow margin we crop away). Don't forward
        // it, so the app sees no stray press/release pair.
        const edge = win.resizeEdge(x, y);
        if (edge != 0 and win.press_btn == 1) {
            win.fwd_press = false;
            rw.beginResize(win.window, edge, win.press_btn, x, y);
            return;
        }
        win.fwd_press = true;
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
        if (!win.fwd_press) return; // press started a host resize, not app input
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
    /// The app's input region → the host GdkSurface, so clicks in
    /// CSD shadow margins pass through to whatever is underneath.
    fn onParent(ctx: ?*anyopaque, surface: u32, parent: u32) void {
        const self = cast.userData(AppHost, ctx);
        const win = self.windows.get(surface) orelse return;
        const pwin: ?*c.GtkWindow = if (parent != 0)
            (if (self.windows.get(parent)) |p| p.window else null)
        else
            null;
        c.gtk_window_set_transient_for(win.window, pwin);
    }

    fn onMinSize(ctx: ?*anyopaque, surface: u32, mw: i32, mh: i32) void {
        const self = cast.userData(AppHost, ctx);
        const win = self.windows.get(surface) orelse return;
        c.gtk_widget_set_size_request(@ptrCast(win.window), if (mw > 0) mw else -1, if (mh > 0) mh else -1);
    }

    fn onStateRequest(ctx: ?*anyopaque, surface: u32, req: u8) void {
        const self = cast.userData(AppHost, ctx);
        const win = self.windows.get(surface) orelse return;
        switch (req) {
            1 => c.gtk_window_maximize(win.window),
            2 => c.gtk_window_unmaximize(win.window),
            3 => c.gtk_window_fullscreen(win.window),
            4 => c.gtk_window_unfullscreen(win.window),
            5 => c.gtk_window_minimize(win.window),
            else => {},
        }
    }

    fn onGeometry(ctx: ?*anyopaque, surface: u32, x: i32, y: i32, gw: i32, gh: i32) void {
        const self = cast.userData(AppHost, ctx);
        self.geos.put(self.allocator, surface, .{ x, y, gw, gh }) catch {};
        // Shadow margins changed → recompute the toplevel size so the
        // WM picks up the new geometry (compute-size re-fires).
        if (self.windows.get(surface)) |win| c.gtk_widget_queue_resize(@ptrCast(win.window));
    }

    /// GdkSurface exists now: report the CSD shadow as the toplevel's
    /// shadow width. Connected AFTER GtkWindow's own compute-size
    /// handler so ours wins (the default handler reports zero).
    fn onWinRealize(window: ?*c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
        const win = cast.userData(Win, user);
        const surface = c.gtk_native_get_surface(@ptrCast(window)) orelse return;
        _ = c.g_signal_connect_data(@ptrCast(surface), "compute-size", @ptrCast(&onComputeSize), win, null, c.G_CONNECT_AFTER);
    }

    fn onComputeSize(_: ?*c.GdkToplevel, size: ?*c.GdkToplevelSize, user: ?*anyopaque) callconv(.c) void {
        const win = cast.userData(Win, user);
        const m = win.shadowMargins();
        c.gdk_toplevel_size_set_shadow_width(size, m[0], m[1], m[2], m[3]);
        // Maximize/fullscreen: the window allocation isn't settled when
        // notify::maximized fires, so onWinResize reads a stale size and
        // never tells the app to repaint (it just stretches the stale
        // buffer, shadow and all). The toplevel bounds — the work area
        // KWin hands us here — ARE the maximized geometry, so configure
        // the app to that now and it repaints to fill.
        const st = winStates(win);
        if (!st.maximized and !st.fullscreen) return;
        var bw: c_int = 0;
        var bh: c_int = 0;
        c.gdk_toplevel_size_get_bounds(size, &bw, &bh);
        if (bw <= 0 or bh <= 0) return;
        if (bw == win.sent_w and bh == win.sent_h) return;
        win.sent_w = bw;
        win.sent_h = bh;
        win.host.comp.configureToplevel(win.surface, bw, bh, st) catch return;
        win.host.flushHost();
    }

    fn onInputRegion(ctx: ?*anyopaque, surface: u32, rects: ?[]const @import("wlhost/compositor.zig").Rect) void {
        const self = cast.userData(AppHost, ctx);
        const win = self.windows.get(surface) orelse return;
        const gdk_surface = c.gtk_native_get_surface(@ptrCast(win.window)) orelse return;
        const list = rects orelse {
            c.gdk_surface_set_input_region(gdk_surface, null);
            return;
        };
        // Full buffer is shown, so input-region rects (surface coords)
        // map straight to the host surface — no geometry offset.
        const region = c.cairo_region_create() orelse return;
        defer c.cairo_region_destroy(region);
        for (list) |r| {
            var cr = c.cairo_rectangle_int_t{ .x = r.x, .y = r.y, .width = r.w, .height = r.h };
            _ = c.cairo_region_union_rectangle(region, &cr);
        }
        c.gdk_surface_set_input_region(gdk_surface, region);
    }

    fn onMove(ctx: ?*anyopaque, surface: u32) void {
        const self = cast.userData(AppHost, ctx);
        const win = self.windows.get(surface) orelse return;
        rw.beginMove(win.window, win.press_btn, win.press_x, win.press_y);
    }

    fn onResize(ctx: ?*anyopaque, surface: u32, edges: u32) void {
        const self = cast.userData(AppHost, ctx);
        const win = self.windows.get(surface) orelse return;
        rw.beginResize(win.window, edges, win.press_btn, win.press_x, win.press_y);
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
            p.area
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

    fn winStates(win: *Win) @import("wlhost/compositor.zig").Compositor.ToplevelState {
        return .{
            .activated = c.gtk_window_is_active(win.window) != 0,
            .maximized = c.gtk_window_is_maximized(win.window) != 0,
            .fullscreen = c.gtk_window_is_fullscreen(win.window) != 0,
            .resizing = false,
        };
    }

    fn onWinResize(_: ?*c.GtkWindow, _: ?*c.GParamSpec, user: ?*anyopaque) callconv(.c) void {
        const win = cast.userData(Win, user);
        // Before the maximize early-return so it also covers maximize:
        // keep the window opaque while it grows (else macOS clips the
        // new area), reverting after the resize settles.
        if (builtin.os.tag == .macos) win.armOpaqueResize();
        var st = winStates(win);
        // Maximize/fullscreen sizing is driven from onComputeSize (the
        // allocation isn't settled here). This handler owns the normal
        // and unmaximize cases, where default-size tracks the target.
        if (st.maximized or st.fullscreen) return;
        st.resizing = true;
        var w: c_int = 0;
        var h: c_int = 0;
        c.gtk_window_get_default_size(win.window, &w, &h);
        // GTK reports the full surface (buffer) size; the app wants its
        // window-geometry size, so strip the shadow margins back off.
        const m = win.shadowMargins();
        w -= m[0] + m[1];
        h -= m[2] + m[3];
        if (w <= 0 or h <= 0) return;
        // Skip echoes of the geometry the app already drew (or that we
        // already asked for) — configure storms upset some clients.
        const geo = win.host.geos.get(win.surface) orelse [4]i32{ 0, 0, 0, 0 };
        if ((w == geo[2] and h == geo[3]) or (w == win.sent_w and h == win.sent_h)) return;
        win.sent_w = w;
        win.sent_h = h;
        win.host.comp.configureToplevel(win.surface, w, h, st) catch return;
        win.host.flushHost();
    }

    /// State-only change (focus in/out): configure at the current
    /// geometry size with fresh states — bypasses the size echo guard.
    fn onWinState(_: ?*c.GtkWindow, _: ?*c.GParamSpec, user: ?*anyopaque) callconv(.c) void {
        const win = cast.userData(Win, user);
        const geo = win.host.geos.get(win.surface) orelse return;
        if (geo[2] <= 0 or geo[3] <= 0) return;
        win.host.comp.configureToplevel(win.surface, geo[2], geo[3], winStates(win)) catch return;
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
