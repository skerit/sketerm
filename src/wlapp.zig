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
const wlpipe = @import("wlhost/pipe.zig");

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
    /// A headless MCP client is attached (drives the badge).
    driven: bool = false,
    /// Pane-provided container for the embedded (in-tab) app view.
    /// When set before the first toplevel frame, that toplevel
    /// renders inside it instead of a floating window; later
    /// toplevels (dialogs) always float. Not owned here.
    embed_box: ?*c.GtkWidget = null,
    /// Surface currently embedded in embed_box (0 = none).
    embed_surface: u32 = 0,
    /// Fired when the embedded view appears/disappears, so the pane
    /// can toggle the terminal (app log) underneath.
    on_embed: ?*const fn (ctx: ?*anyopaque, active: bool) void = null,
    /// Fired by the host menu's "Show in Tab" on a floating window;
    /// the pane answers by installing embed_box and calling popIn.
    /// Null = no pane offers a tab (menu row hidden).
    on_request_embed: ?*const fn (ctx: ?*anyopaque) void = null,
    embed_ctx: ?*anyopaque = null,
    flush_ctx: ?*anyopaque = null,
    /// Fired once, on the first frame of the app's FIRST toplevel
    /// window. Distinguishes "the app really showed a window" from
    /// "the app merely connected to the display" — single-instance
    /// apps (pcmanfm) hand off to a running instance and exit
    /// without ever mapping one.
    on_first_window: ?*const fn (ctx: ?*anyopaque) void = null,
    first_window_ctx: ?*anyopaque = null,
    saw_window: bool = false,
    /// Outgoing seat-intent units (proto v5). The local compositor
    /// is a passive replica whose protocol output is discarded — the
    /// daemon brain answers the app; only these intents travel.
    intents: std.ArrayList(u8) = .empty,
    /// GTK async clipboard reads in flight — their callbacks hold
    /// this AppHost, so destroy() defers the final free until they
    /// all land (doomed marks the limbo state).
    pending_reads: u32 = 0,
    doomed: bool = false,
    /// Surface that last got a clipboard offer — re-offer happens
    /// per keyboard-focus change, not per keystroke.
    offered_focus: u32 = 0,
    /// Kinds of in-flight clip_send fetches, FIFO-paired with the
    /// clip_data answers (0 = clipboard, 1 = primary) — the wire
    /// carries no kind, so ordering routes the result.
    fetch_kinds: std.ArrayList(u8) = .empty,
    /// The app has an enabled zwp_text_input_v3: route keystrokes
    /// through the host IM context so local IMEs (and compose/dead
    /// keys) commit text instead of raw evdev codes.
    text_active: bool = false,
    /// Title/app_id that arrived BEFORE the first frame created the
    /// window (the usual order) — applied in winFor. Owned strings.
    pending_titles: std.AutoHashMapUnmanaged(u32, []u8) = .empty,
    pending_app_ids: std.AutoHashMapUnmanaged(u32, []u8) = .empty,
    /// Surfaces whose app negotiated server-side decorations before
    /// the window existed (the normal order).
    pending_ssd: std.AutoHashMapUnmanaged(u32, bool) = .empty,
    /// Surface → parent surface for xdg_toplevel.set_parent. Toolkits
    /// (JBR/AWT, GTK dialogs) send set_parent at toplevel creation,
    /// BEFORE the first frame builds the window — so the transient-for
    /// must be latched here and applied in winFor, or the dialog opens
    /// as a standalone taskbar window instead of a modal over its
    /// parent. Also the live source of truth for re-parenting. 0 = the
    /// parent was unset.
    pending_parents: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// Icon textures that arrived BEFORE the first frame (the usual
    /// order — the daemon injects the icon right after the app_id,
    /// before any buffer commit). Owned refs; moved to the Win in
    /// winFor, or unref'd in destroy if the window never opened.
    pending_icons: std.AutoHashMapUnmanaged(u32, *c.GdkTexture) = .empty,
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
        /// "AI" corner badge, shown while a headless MCP client is
        /// attached to the session (assistant-is-driving indicator).
        badge: ?*c.GtkWidget = null,
        /// Active recording of this window (host menu): GIF or WebM.
        rec: ?@import("util/gifrec.zig").Rec = null,
        vrec: ?@import("util/videorec.zig").Rec = null,
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
        /// Rendered inside the pane's embed box instead of a floating
        /// window. The GtkWindow still exists (hidden, childless) so
        /// window-based code paths stay valid; pop-out re-childs and
        /// presents it.
        embedded: bool = false,
        /// The floating-window signal set is connected (wired lazily
        /// at pop-out for windows born embedded).
        float_wired: bool = false,
        /// The embedded input set is connected (key/focus controllers
        /// on the picture; wired lazily on first embed).
        embed_wired: bool = false,
        /// Embedded resize sensor: input-transparent GtkDrawingArea
        /// filling the overlay — its "resize" signal is GTK4's only
        /// clean allocation-change hook.
        embed_sensor: ?*c.GtkWidget = null,
        /// The app's Wayland app_id (owned). The full apply (Wayland
        /// set_application_id / X11 WM_CLASS) needs the GdkSurface,
        /// which doesn't exist until realize — so it's stored here and
        /// re-applied in onWinRealize. Gives the floating window the
        /// remote app's taskbar icon + name instead of sketerm's.
        app_id: ?[]u8 = null,
        /// The app's icon as a GdkTexture (owned ref), applied via
        /// gdk_toplevel_set_icon_list on realize. Ships PIXELS, so it
        /// works for REMOTE apps whose icon isn't installed locally
        /// (xdg-toplevel-icon on Wayland, _NET_WM_ICON on X11).
        icon_tex: ?*c.GdkTexture = null,
        /// Key controllers (floating window / embedded picture) — kept
        /// so the IM context can be attached when text-input activates.
        key_ctl: ?*c.GtkEventControllerKey = null,
        embed_key_ctl: ?*c.GtkEventControllerKey = null,
        /// Host IM context; its "commit" ships text_commit intents
        /// while the app has an enabled text input.
        im: ?*c.GtkIMContext = null,

        /// Store the icon texture and apply it (needs the surface;
        /// onWinRealize re-applies). Takes ownership of one ref.
        fn setIconTexture(self: *Win, tex: *c.GdkTexture) void {
            if (self.icon_tex) |old| c.g_object_unref(old);
            self.icon_tex = tex;
            self.applyIcon();
        }

        /// gdk_toplevel_set_icon_list with our single texture, once the
        /// GdkSurface (a GdkToplevel) exists. No-op before realize.
        fn applyIcon(self: *Win) void {
            const tex = self.icon_tex orelse return;
            const surface = c.gtk_native_get_surface(@ptrCast(self.window)) orelse return;
            const list = c.g_list_append(null, tex);
            c.gdk_toplevel_set_icon_list(@ptrCast(surface), list);
            c.g_list_free(list);
        }

        /// Store the app_id and apply it. Called pre- and post-realize
        /// (idempotent): pre-realize only the icon-name lands (no
        /// surface); onWinRealize re-applies the surface-bound parts.
        fn setAppId(self: *Win, app_id: []const u8) void {
            const owned = self.host.allocator.dupe(u8, app_id) catch return;
            if (self.app_id) |old| self.host.allocator.free(old);
            self.app_id = owned;
            rw.applyAppId(self.window, owned);
        }

        /// Ctrl+right-click host menu: the only host-side chrome a
        /// forwarded window has (everything else goes to the app).
        fn showHostMenu(self: *Win, x: f64, y: f64) void {
            const pop = c.gtk_popover_new();
            const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
            const shot = c.gtk_button_new_with_label("Screenshot Window…");
            c.gtk_button_set_has_frame(@ptrCast(shot), 0);
            _ = c.g_signal_connect_data(@ptrCast(shot), "clicked", @ptrCast(&onMenuScreenshot), self, null, 0);
            c.gtk_box_append(@ptrCast(box), shot);
            const recording = self.rec != null or self.vrec != null;
            const rec_btn = c.gtk_button_new_with_label(if (recording) "Stop Recording…" else "Record Window (WebM)");
            c.gtk_button_set_has_frame(@ptrCast(rec_btn), 0);
            _ = c.g_signal_connect_data(@ptrCast(rec_btn), "clicked", @ptrCast(&onMenuRecordWebm), self, null, 0);
            c.gtk_box_append(@ptrCast(box), rec_btn);
            if (!recording) {
                const gif_btn = c.gtk_button_new_with_label("Record Window (GIF)");
                c.gtk_button_set_has_frame(@ptrCast(gif_btn), 0);
                _ = c.g_signal_connect_data(@ptrCast(gif_btn), "clicked", @ptrCast(&onMenuRecord), self, null, 0);
                c.gtk_box_append(@ptrCast(box), gif_btn);
            }
            if (self.embedded) {
                const out_btn = c.gtk_button_new_with_label("Pop Out Window");
                c.gtk_button_set_has_frame(@ptrCast(out_btn), 0);
                _ = c.g_signal_connect_data(@ptrCast(out_btn), "clicked", @ptrCast(&onMenuPopOut), self, null, 0);
                c.gtk_box_append(@ptrCast(box), out_btn);
            } else if (self.host.on_request_embed != null and self.host.embed_surface == 0) {
                const in_btn = c.gtk_button_new_with_label("Show in Tab");
                c.gtk_button_set_has_frame(@ptrCast(in_btn), 0);
                _ = c.g_signal_connect_data(@ptrCast(in_btn), "clicked", @ptrCast(&onMenuShowInTab), self, null, 0);
                c.gtk_box_append(@ptrCast(box), in_btn);
            }
            const close_btn = c.gtk_button_new_with_label("Close Window");
            c.gtk_button_set_has_frame(@ptrCast(close_btn), 0);
            _ = c.g_signal_connect_data(@ptrCast(close_btn), "clicked", @ptrCast(&onMenuClose), self, null, 0);
            c.gtk_box_append(@ptrCast(box), close_btn);
            c.gtk_popover_set_child(@ptrCast(pop), box);
            c.gtk_widget_set_parent(pop, self.picture);
            var rect = c.GdkRectangle{ .x = @intFromFloat(x), .y = @intFromFloat(y), .width = 1, .height = 1 };
            c.gtk_popover_set_pointing_to(@ptrCast(pop), &rect);
            _ = c.g_signal_connect_data(@ptrCast(pop), "closed", @ptrCast(&onHostMenuClosed), null, null, 0);
            c.gtk_popover_popup(@ptrCast(pop));
        }

        fn popdownFrom(btn: ?*c.GtkButton) void {
            const pop = c.gtk_widget_get_ancestor(@ptrCast(btn), c.gtk_popover_get_type()) orelse return;
            c.gtk_popover_popdown(@ptrCast(pop));
        }

        /// Snapshot the CURRENT frame texture immediately (its GBytes
        /// outlives the window), then ask where to save it.
        fn onMenuScreenshot(btn: ?*c.GtkButton, user: ?*anyopaque) callconv(.c) void {
            const win = cast.userData(Win, user);
            popdownFrom(btn);
            const paintable = c.gtk_picture_get_paintable(@ptrCast(win.picture)) orelse return;
            if (c.g_type_check_instance_is_a(@ptrCast(@alignCast(paintable)), c.gdk_texture_get_type()) == 0) return;
            const bytes = c.gdk_texture_save_to_png_bytes(@ptrCast(paintable)) orelse return;
            const dialog = c.gtk_file_dialog_new();
            c.gtk_file_dialog_set_title(dialog, "Save App Screenshot");
            c.gtk_file_dialog_set_initial_name(dialog, "sketerm-app.png");
            c.gtk_file_dialog_save(dialog, win.window, null, @ptrCast(&onShotPicked), bytes);
        }

        fn onShotPicked(source: *c.GObject, result: *c.GAsyncResult, user: ?*anyopaque) callconv(.c) void {
            const bytes: *c.GBytes = @ptrCast(@alignCast(user.?));
            defer c.g_bytes_unref(bytes);
            const dialog: *c.GtkFileDialog = @ptrCast(source);
            const file = c.gtk_file_dialog_save_finish(dialog, result, null) orelse return;
            defer c.g_object_unref(file);
            var sz: usize = 0;
            const data = c.g_bytes_get_data(bytes, &sz) orelse return;
            _ = c.g_file_replace_contents(
                file,
                @ptrCast(data),
                sz,
                null,
                0,
                c.G_FILE_CREATE_REPLACE_DESTINATION,
                null,
                null,
                null,
            );
        }

        fn recNowMs() i64 {
            return @divTrunc(c.g_get_monotonic_time(), 1000);
        }

        /// Toggle GIF recording of this window's committed frames.
        fn onMenuRecord(btn: ?*c.GtkButton, user: ?*anyopaque) callconv(.c) void {
            const win = cast.userData(Win, user);
            popdownFrom(btn);
            const gifrec = @import("util/gifrec.zig");
            if (win.rec) |*r| {
                const gif = r.finish(recNowMs()) catch {
                    win.rec = null;
                    return;
                };
                win.rec = null;
                const bytes = c.g_bytes_new(gif.ptr, gif.len);
                win.host.allocator.free(gif);
                const dialog = c.gtk_file_dialog_new();
                c.gtk_file_dialog_set_title(dialog, "Save Recording");
                c.gtk_file_dialog_set_initial_name(dialog, "sketerm-recording.gif");
                c.gtk_file_dialog_save(dialog, win.window, null, @ptrCast(&onShotPicked), bytes);
                return;
            }
            win.rec = gifrec.Rec.init(win.host.allocator, 0);
        }

        /// Toggle WebM/VP9 recording of this window's committed frames.
        fn onMenuRecordWebm(btn: ?*c.GtkButton, user: ?*anyopaque) callconv(.c) void {
            const win = cast.userData(Win, user);
            popdownFrom(btn);
            const videorec = @import("util/videorec.zig");
            // Stop whichever recording is active (WebM or GIF).
            if (win.rec) |*r| {
                const gif = r.finish(recNowMs()) catch {
                    win.rec = null;
                    return;
                };
                win.rec = null;
                const bytes = c.g_bytes_new(gif.ptr, gif.len);
                win.host.allocator.free(gif);
                const dialog = c.gtk_file_dialog_new();
                c.gtk_file_dialog_set_title(dialog, "Save Recording");
                c.gtk_file_dialog_set_initial_name(dialog, "sketerm-recording.gif");
                c.gtk_file_dialog_save(dialog, win.window, null, @ptrCast(&onShotPicked), bytes);
                return;
            }
            if (win.vrec) |*r| {
                const webm = r.finish(recNowMs()) catch {
                    win.vrec = null;
                    return;
                };
                win.vrec = null;
                const bytes = c.g_bytes_new(webm.ptr, webm.len);
                win.host.allocator.free(webm);
                const dialog = c.gtk_file_dialog_new();
                c.gtk_file_dialog_set_title(dialog, "Save Recording");
                c.gtk_file_dialog_set_initial_name(dialog, "sketerm-recording.webm");
                c.gtk_file_dialog_save(dialog, win.window, null, @ptrCast(&onShotPicked), bytes);
                return;
            }
            win.vrec = videorec.Rec.init(win.host.allocator, 0);
        }

        fn onMenuClose(btn: ?*c.GtkButton, user: ?*anyopaque) callconv(.c) void {
            const win = cast.userData(Win, user);
            popdownFrom(btn);
            if (win.embedded) {
                // No close-request path on the hidden window: ask the
                // app directly, exactly like the floating handler.
                win.host.requestCloseIntent(win.surface);
                win.host.flushHost();
                return;
            }
            c.gtk_window_close(win.window);
        }

        fn onMenuPopOut(btn: ?*c.GtkButton, user: ?*anyopaque) callconv(.c) void {
            const win = cast.userData(Win, user);
            popdownFrom(btn);
            win.host.popOut();
        }

        fn onMenuShowInTab(btn: ?*c.GtkButton, user: ?*anyopaque) callconv(.c) void {
            const win = cast.userData(Win, user);
            popdownFrom(btn);
            if (win.host.on_request_embed) |f| f(win.host.embed_ctx);
        }

        fn onHostMenuClosed(pop: ?*c.GtkPopover, _: ?*anyopaque) callconv(.c) void {
            // Unparent OUTSIDE the closed emission; ref-held so a
            // window teardown racing the idle can't leave a dangler.
            _ = c.g_object_ref(@ptrCast(pop));
            _ = c.g_idle_add(@ptrCast(&idleUnparentPopover), pop);
        }

        fn idleUnparentPopover(user: ?*anyopaque) callconv(.c) c_int {
            const w: *c.GtkWidget = @ptrCast(@alignCast(user.?));
            if (c.gtk_widget_get_parent(w) != null) c.gtk_widget_unparent(w);
            c.g_object_unref(@ptrCast(w));
            return 0; // G_SOURCE_REMOVE
        }

        /// Host-window resize edge under (x, y) in picture coords, or 0
        /// for the interior. Disabled while maximized/fullscreen (the
        /// WM owns the size then).
        fn resizeEdge(self: *Win, x: f64, y: f64) u32 {
            if (self.embedded) return 0; // the pane owns the size
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
            // Go opaque as soon as the pointer enters a resize-edge band,
            // BEFORE any begin_resize grab starts — toggling opacity
            // *during* a macOS interactive resize disrupts its event
            // session (the mouse-up gets lost, leaving the resize stuck).
            // While hovering an edge the revert keeps deferring (see
            // opaqueRevertCb), so it stays stable through the whole drag.
            if (builtin.os.tag == .macos and edge != 0) self.armOpaqueResize();
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
        // Still on a resize edge (a drag may be mid-flight, or about to
        // start) — keep opaque and check again later, so opacity never
        // flips during the macOS resize session.
        if (win.hover_edge != 0) {
            win.opaque_settle_id = c.g_timeout_add(400, @ptrCast(&opaqueRevertCb), win);
            return 0;
        }
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
            .toplevel_icon = onIcon,
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
            .popup_moved = onPopupMoved,
            .pointer_locked = onPointerLocked,
            .text_input_active = onTextInputActive,
            .primary_offer = onPrimaryOffer,
            .primary_read = onPrimaryRead,
            .toplevel_raise = onRaise,
        });
        // Advertise the local display scale so apps render HiDPI
        // buffers (set before the app binds wl_output on first feed).
        self.comp.output_scale = localScale();
        // The TRUE (possibly fractional) scale rides to the daemon
        // brain as a set_scale intent — it drives wp_fractional_scale
        // preferred_scale so apps render for the real pixel grid.
        // Queued now; ships with the first flush after attach.
        self.comp.scale120 = localScale120();
        var spl: [4]u8 = undefined;
        std.mem.writeInt(u32, &spl, self.comp.scale120, .little);
        wlpipe.appendUnit(&self.intents, allocator, .set_scale, &spl) catch {};
        // Passive replica: the daemon brain owns server-created
        // object ids (clipboard offers) this side never learns.
        self.comp.lenient = true;
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

    /// TRUE scale of the primary monitor × 120 (the fractional-scale
    /// wire unit): 1.5 → 180. Falls back to the integer factor.
    fn localScale120() u32 {
        const display = c.gdk_display_get_default() orelse return 120;
        const monitors = c.gdk_display_get_monitors(display) orelse return 120;
        const mon = c.g_list_model_get_item(@ptrCast(monitors), 0) orelse return 120;
        defer c.g_object_unref(mon);
        const sf = c.gdk_monitor_get_scale(@ptrCast(@alignCast(mon)));
        if (sf <= 0) return @intCast(localScale() * 120);
        return @intFromFloat(@round(sf * 120.0));
    }

    pub fn destroy(self: *AppHost) void {
        self.dead = true;
        var it = self.windows.valueIterator();
        while (it.next()) |w| {
            // Belt-and-braces: a still-embedded overlay lives in the
            // pane's box — pull it out before the window teardown.
            // (The pane normally releases first via on_app_view.)
            if (w.*.embedded) {
                w.*.embedded = false;
                if (self.embed_box) |box| c.gtk_box_remove(@ptrCast(box), w.*.overlay);
            }
            // Break the close-request link before gtk teardown.
            w.*.cancelOpaqueResize();
            if (w.*.app_id) |aid| self.allocator.free(aid);
            if (w.*.icon_tex) |tex| c.g_object_unref(tex);
            if (w.*.im) |im| c.g_object_unref(im);
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
        var iit = self.pending_icons.valueIterator();
        while (iit.next()) |v| c.g_object_unref(v.*);
        self.pending_icons.deinit(self.allocator);
        self.pending_ssd.deinit(self.allocator);
        self.pending_parents.deinit(self.allocator);
        self.geos.deinit(self.allocator);
        self.fetch_kinds.deinit(self.allocator);
        if (self.pending_reads > 0) {
            self.doomed = true;
            return;
        }
        self.finalFree();
    }

    /// Reachable from tests that park a host via `pending_reads`;
    /// production paths get here through destroy()/onClipReadDone.
    pub fn finalFree(self: *AppHost) void {
        self.intents.deinit(self.allocator);
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

    /// Pending intent bytes toward the daemon. Caller ships them as
    /// chan_data and then calls clearOut. The replica compositor's
    /// own protocol output is discarded here — sending it would
    /// double-drive the app against the daemon brain.
    pub fn takeOut(self: *AppHost) []const u8 {
        self.comp.clearOut();
        return self.intents.items;
    }

    pub fn clearOut(self: *AppHost) void {
        self.intents.clearRetainingCapacity();
    }

    // ── seat intents (viewer → daemon brain) ────────────────────
    // Each wrapper updates the local replica (focus bookkeeping for
    // cursor shapes / popup grabs) AND queues the intent unit.

    fn seatEnter(self: *AppHost, sid: u32, x: f64, y: f64) void {
        self.comp.pointerEnter(sid, x, y) catch {};
        wlpipe.appendSeatEnter(&self.intents, self.allocator, sid, x, y) catch {};
    }

    fn seatMotion(self: *AppHost, x: f64, y: f64) void {
        self.comp.pointerMotion(x, y) catch {};
        wlpipe.appendSeatMotion(&self.intents, self.allocator, x, y) catch {};
    }

    fn seatLeave(self: *AppHost) void {
        self.comp.pointerLeave() catch {};
        wlpipe.appendUnit(&self.intents, self.allocator, .seat_leave, "") catch {};
    }

    fn seatButton(self: *AppHost, button: u32, pressed: bool) void {
        self.comp.pointerButton(button, pressed) catch {};
        wlpipe.appendSeatButton(&self.intents, self.allocator, button, pressed) catch {};
    }

    fn seatAxis(self: *AppHost, axis: u32, value: f64, value120: i32) void {
        self.comp.pointerAxis(axis, value, value120) catch {};
        wlpipe.appendSeatAxis(&self.intents, self.allocator, axis, value, value120) catch {};
    }

    fn seatKbdEnter(self: *AppHost, sid: u32) void {
        self.comp.keyboardEnter(sid) catch {};
        wlpipe.appendSeatKbdEnter(&self.intents, self.allocator, sid) catch {};
    }

    fn seatKbdLeave(self: *AppHost) void {
        self.comp.keyboardLeave() catch {};
        wlpipe.appendUnit(&self.intents, self.allocator, .seat_kbd_leave, "") catch {};
    }

    fn seatKey(self: *AppHost, key: u32, pressed: bool) void {
        self.comp.keyboardKey(key, pressed) catch {};
        wlpipe.appendSeatKey(&self.intents, self.allocator, key, pressed) catch {};
    }

    fn seatMods(self: *AppHost, depressed: u32, latched: u32, locked: u32, group: u32) void {
        self.comp.keyboardModifiers(depressed, latched, locked, group) catch {};
        wlpipe.appendSeatMods(&self.intents, self.allocator, depressed, latched, locked, group) catch {};
    }

    fn dismissPopupsIntent(self: *AppHost) void {
        self.comp.dismissPopups() catch {};
        wlpipe.appendUnit(&self.intents, self.allocator, .dismiss_popups, "") catch {};
    }

    fn configureIntent(self: *AppHost, sid: u32, w: i32, h: i32, st: Compositor.ToplevelState) void {
        var bits: u32 = 0;
        if (st.activated) bits |= 1;
        if (st.maximized) bits |= 2;
        if (st.fullscreen) bits |= 4;
        if (st.resizing) bits |= 8;
        wlpipe.appendConfigure(&self.intents, self.allocator, sid, w, h, bits) catch {};
    }

    fn requestCloseIntent(self: *AppHost, sid: u32) void {
        wlpipe.appendRequestClose(&self.intents, self.allocator, sid) catch {};
    }

    fn offerSelectionIntent(self: *AppHost, mime: []const u8) void {
        wlpipe.appendUnit(&self.intents, self.allocator, .offer_selection, mime) catch {};
    }

    fn offerPrimaryIntent(self: *AppHost, mime: []const u8) void {
        wlpipe.appendUnit(&self.intents, self.allocator, .offer_primary, mime) catch {};
    }

    fn primaryDataIntent(self: *AppHost, bytes: []const u8) void {
        wlpipe.appendUnit(&self.intents, self.allocator, .primary_data, bytes) catch {};
    }

    fn textCommitIntent(self: *AppHost, text: []const u8) void {
        wlpipe.appendUnit(&self.intents, self.allocator, .text_commit, text) catch {};
    }

    fn hostDropIntent(self: *AppHost, sid: u32, x: f64, y: f64, mime: []const u8, data: []const u8) void {
        wlpipe.appendHostDrop(&self.intents, self.allocator, sid, x, y, mime, data) catch {};
    }

    fn clipSendIntent(self: *AppHost, source: u32, mime: []const u8) void {
        var pl: std.ArrayList(u8) = .empty;
        defer pl.deinit(self.allocator);
        var idb: [4]u8 = undefined;
        std.mem.writeInt(u32, &idb, source, .little);
        pl.appendSlice(self.allocator, &idb) catch return;
        pl.appendSlice(self.allocator, mime) catch return;
        wlpipe.appendUnit(&self.intents, self.allocator, .clip_send, pl.items) catch {};
    }

    fn clipDataIntent(self: *AppHost, bytes: []const u8) void {
        wlpipe.appendUnit(&self.intents, self.allocator, .clip_data, bytes) catch {};
    }

    // ── view callbacks (main thread — GTK is safe) ──────────────

    fn onFrame(ctx: ?*anyopaque, surface: u32, w: i32, h: i32, scale: i32, lwp: i32, lhp: i32, format: u32, pixels: []const u8) void {
        const self = cast.userData(AppHost, ctx);
        // The buffer is physical pixels. GTK sizes (windows, overlay
        // children, positions, the pointer map) are LOGICAL — the
        // compositor's lw/lh: the viewport destination for
        // fractional-scale clients, physical ÷ buffer_scale otherwise.
        // The texture itself stays physical (HiDPI-crisp: GTK renders
        // fractionally, so logical widget × real scale maps 1:1).
        const s: i32 = if (scale > 0) scale else 1;
        const lw = if (lwp > 0) lwp else @divTrunc(w, s);
        const lh = if (lhp > 0) lhp else @divTrunc(h, s);
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
        // Displayed region in LOGICAL surface coords. Linux floating
        // windows show the full buffer and report the CSD shadow as
        // the toplevel's shadow width; macOS — and embedded views,
        // which have no WM to report shadows to — crop the buffer to
        // the window-geometry rect instead (otherwise the shadow
        // shows as a fat border inside the tab).
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
        if (!self.saw_window) {
            self.saw_window = true;
            if (self.on_first_window) |f| f(self.first_window_ctx);
        }
        if (builtin.os.tag != .macos and win.embedded) {
            if (self.geos.get(surface)) |g| {
                if (g[2] > 0 and g[3] > 0 and g[0] >= 0 and g[1] >= 0 and g[0] + g[2] <= lw and g[1] + g[3] <= lh) {
                    dx = g[0];
                    dy = g[1];
                    dw = g[2];
                    dh = g[3];
                }
            }
        }
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
        // Crop coords are logical; pixel coords scale by the REAL
        // physical/logical ratio (fractional under a viewport, where
        // buffer_scale stays 1 and s would under-shoot).
        const fx = @as(f64, @floatFromInt(w)) / @as(f64, @floatFromInt(@max(1, lw)));
        const fy = @as(f64, @floatFromInt(h)) / @as(f64, @floatFromInt(@max(1, lh)));
        const cpx: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(dx)) * fx));
        const cpy: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(dy)) * fy));
        const cpw: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(dw)) * fx));
        const cph: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(dh)) * fy));
        const tex = (if (cropped)
            rw.newTextureCropped(w, h, format, pixels, cpx, cpy, @min(cpw, w - cpx), @min(cph, h - cpy))
        else
            rw.newTexture(w, h, format, pixels)) orelse return;
        defer c.g_object_unref(tex);
        c.gtk_picture_set_paintable(@ptrCast(win.picture), @ptrCast(tex));
        if (win.rec) |*r| {
            r.addShmFrame(pixels, @intCast(w), @intCast(h), format, Win.recNowMs()) catch {};
        }
        if (win.vrec) |*r| {
            r.addShmFrame(pixels, @intCast(w), @intCast(h), format, Win.recNowMs()) catch {};
        }
    }

    /// Raise every window of this app (mirror click).
    pub fn presentAll(self: *AppHost) void {
        var it = self.windows.valueIterator();
        while (it.next()) |w| c.gtk_window_present(w.*.window);
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
        popup.host.seatEnter(popup.surface, x, y);
        popup.host.flushHost();
    }

    fn onPopupPtrMotion(_: ?*c.GtkEventControllerMotion, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
        const popup = cast.userData(Popup, user);
        popup.host.stampNow();
        popup.host.seatEnter(popup.surface, x, y);
        popup.host.seatMotion(x, y);
        popup.host.flushHost();
    }

    fn onPopupBtnPress(gesture: ?*c.GtkGestureClick, _: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
        const popup = cast.userData(Popup, user);
        popup.host.stampNow();
        popup.host.seatEnter(popup.surface, x, y);
        const btn = c.gtk_gesture_single_get_current_button(@ptrCast(gesture));
        popup.host.seatButton(evdevButton(btn), true);
        popup.host.flushHost();
    }

    fn onPopupBtnRelease(gesture: ?*c.GtkGestureClick, _: c_int, _: f64, _: f64, user: ?*anyopaque) callconv(.c) void {
        const popup = cast.userData(Popup, user);
        popup.host.stampNow();
        const btn = c.gtk_gesture_single_get_current_button(@ptrCast(gesture));
        popup.host.seatButton(evdevButton(btn), false);
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
        win.setAppId(app_id);
    }

    /// The app's icon bytes (daemon-injected). Decode to a GdkTexture
    /// and set it on the window; stash if the window isn't up yet.
    fn onIcon(ctx: ?*anyopaque, surface: u32, kind: u8, bytes: []const u8) void {
        const self = cast.userData(AppHost, ctx);
        const tex = decodeIcon(kind, bytes) orelse return;
        if (self.windows.get(surface)) |win| {
            win.setIconTexture(tex);
            return;
        }
        if (self.pending_icons.fetchPut(self.allocator, surface, tex) catch {
            c.g_object_unref(tex);
            return;
        }) |old| c.g_object_unref(old.value);
    }

    /// Icon bytes → GdkTexture. PNG via GdkTexture's native loader;
    /// SVG through gdk-pixbuf (librsvg) at a taskbar-ish size.
    fn decodeIcon(kind: u8, bytes: []const u8) ?*c.GdkTexture {
        const gb = c.g_bytes_new(bytes.ptr, bytes.len) orelse return null;
        defer c.g_bytes_unref(gb);
        if (kind == 2) { // svg
            const stream = c.g_memory_input_stream_new_from_bytes(gb);
            defer c.g_object_unref(stream);
            const pb = c.gdk_pixbuf_new_from_stream_at_scale(@ptrCast(stream), 128, 128, 1, null, null) orelse return null;
            defer c.g_object_unref(pb);
            return c.gdk_texture_new_for_pixbuf(@ptrCast(pb));
        }
        return c.gdk_texture_new_from_bytes(gb, null);
    }

    fn onGone(ctx: ?*anyopaque, surface: u32) void {
        const self = cast.userData(AppHost, ctx);
        // Purge parent latches BEFORE the window lookup: a toplevel can
        // die between set_parent and its first frame (no Win yet), and
        // clients recycle surface ids — a stale entry would re-parent an
        // unrelated future window. A dying PARENT unsets its children
        // (value → 0, per xdg-shell semantics; in-place, iteration-safe).
        _ = self.pending_parents.remove(surface);
        var pvit = self.pending_parents.valueIterator();
        while (pvit.next()) |v| {
            if (v.* == surface) v.* = 0;
        }
        const win = self.windows.get(surface) orelse return;
        _ = self.windows.remove(surface);
        if (win.embedded) {
            // Pull the overlay out of the pane's box before the
            // (childless) window teardown, and tell the pane its
            // embedded view is gone.
            self.embed_surface = 0;
            win.embedded = false;
            if (self.embed_box) |box| c.gtk_box_remove(@ptrCast(box), win.overlay);
            if (self.on_embed) |f| f(self.embed_ctx, false);
        }
        if (win.rec) |*r| r.abort();
        if (win.vrec) |*r| r.abort();
        if (win.app_id) |aid| self.allocator.free(aid);
        if (win.icon_tex) |tex| c.g_object_unref(tex);
        win.cancelOpaqueResize();
        _ = c.g_object_set_data(@ptrCast(win.window), "sketerm-wlapp", null);
        c.gtk_window_destroy(win.window);
        self.allocator.destroy(win);
    }

    /// Show/hide the AI badge on every window (assistant attached to
    /// the session). Remembered for windows created later.
    pub fn setDriven(self: *AppHost, on: bool) void {
        if (self.driven == on) return;
        self.driven = on;
        var it = self.windows.valueIterator();
        while (it.next()) |w| {
            if (w.*.badge) |b| c.gtk_widget_set_visible(b, @intFromBool(on));
        }
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
            win.setAppId(kv.value);
            self.allocator.free(kv.value);
        }
        if (self.pending_icons.fetchRemove(surface)) |kv| {
            win.icon_tex = kv.value; // applied on realize
        }
        // Assistant-is-driving badge, toggled by setDriven.
        const badge = c.gtk_label_new("AI");
        c.gtk_widget_add_css_class(badge, "sketerm-ai-badge");
        c.gtk_widget_set_halign(badge, c.GTK_ALIGN_END);
        c.gtk_widget_set_valign(badge, c.GTK_ALIGN_START);
        c.gtk_widget_set_tooltip_text(badge, "An AI assistant is attached to this app's session");
        c.gtk_widget_set_can_target(badge, 0);
        c.gtk_overlay_add_overlay(@ptrCast(widgets.overlay), badge);
        c.gtk_widget_set_visible(badge, @intFromBool(self.driven));
        win.badge = badge;

        _ = c.g_object_set_data(@ptrCast(window), "sketerm-wlapp", win);

        // Input: pointer on the picture (its coords — the picture
        // travels between the floating window and the embed box, so
        // these work in both modes). All feed the compositor's seat.
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

        // Host→app dnd: dropping local files or text onto the
        // forwarded window synthesizes a Wayland drop in the app.
        const drop = c.gtk_drop_target_new(c.G_TYPE_INVALID, c.GDK_ACTION_COPY);
        var drop_types = [_]c.GType{ c.gdk_file_list_get_type(), c.G_TYPE_STRING };
        c.gtk_drop_target_set_gtypes(drop, &drop_types, drop_types.len);
        _ = c.g_signal_connect_data(@ptrCast(drop), "drop", @ptrCast(&onHostDrop), win, null, 0);
        c.gtk_widget_add_controller(picture, @ptrCast(drop));

        // Apply any latched set_parent now that the window exists —
        // both as a child (our parent may already be up) and as a
        // parent (children that raced ahead of us can now bind).
        self.applyParent(surface);
        var pit = self.pending_parents.iterator();
        while (pit.next()) |e| if (e.value_ptr.* == surface) self.applyParent(e.key_ptr.*);

        // Only the FIRST toplevel embeds; dialogs and secondary
        // windows always float (transient over the embedded view).
        if (self.embed_box != null and self.embed_surface == 0) {
            self.embedWin(win);
        } else {
            self.wireFloating(win);
            c.gtk_window_present(window);
        }
        return win;
    }

    /// Connect the floating-window signal set (idempotent — windows
    /// born embedded get it lazily at pop-out).
    fn wireFloating(self: *AppHost, win: *Win) void {
        _ = self;
        if (win.float_wired) return;
        win.float_wired = true;
        const window = win.window;
        _ = c.g_signal_connect_data(@ptrCast(window), "close-request", @ptrCast(&onCloseRequest), win, null, 0);
        // Report the CSD shadow as the toplevel's shadow width once the
        // GdkSurface exists, so the WM snaps/maximizes to the geometry.
        _ = c.g_signal_connect_data(@ptrCast(window), "realize", @ptrCast(&onWinRealize), win, null, 0);

        // Keyboard + focus on the window.
        const key = c.gtk_event_controller_key_new();
        _ = c.g_signal_connect_data(@ptrCast(key), "key-pressed", @ptrCast(&onKeyPress), win, null, 0);
        _ = c.g_signal_connect_data(@ptrCast(key), "key-released", @ptrCast(&onKeyRelease), win, null, 0);
        c.gtk_widget_add_controller(@ptrCast(window), key);
        win.key_ctl = @ptrCast(key);
        win.host.applyImRouting(win);

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
    }

    /// Move a window's content (the overlay: picture + popups +
    /// subsurfaces) into the pane's embed box; the GtkWindow stays
    /// alive but hidden and childless so window-based code paths
    /// remain valid.
    fn embedWin(self: *AppHost, win: *Win) void {
        const box = self.embed_box orelse return;
        c.gtk_widget_set_visible(@ptrCast(win.window), 0);
        _ = c.g_object_ref(@ptrCast(win.overlay));
        c.gtk_window_set_child(win.window, null);
        c.gtk_box_append(@ptrCast(box), win.overlay);
        c.g_object_unref(@ptrCast(win.overlay));
        c.gtk_widget_set_hexpand(win.overlay, 1);
        c.gtk_widget_set_vexpand(win.overlay, 1);
        win.embedded = true;
        self.embed_surface = win.surface;
        self.wireEmbedded(win);
        // Reset the size-echo guard: the pane's size is authoritative
        // now, whatever the floating window last asked for.
        win.sent_w = 0;
        win.sent_h = 0;
        if (self.on_embed) |f| f(self.embed_ctx, true);
    }

    /// Connect the embedded input set (idempotent): key + focus on
    /// the picture (there is no window to catch them), plus the
    /// resize sensor that drives configure at the pane's size.
    fn wireEmbedded(self: *AppHost, win: *Win) void {
        _ = self;
        if (win.embed_wired) {
            if (win.embed_sensor) |s| c.gtk_widget_set_visible(s, 1);
            return;
        }
        win.embed_wired = true;
        c.gtk_widget_set_focusable(win.picture, 1);

        const key = c.gtk_event_controller_key_new();
        _ = c.g_signal_connect_data(@ptrCast(key), "key-pressed", @ptrCast(&onEmbedKeyPress), win, null, 0);
        _ = c.g_signal_connect_data(@ptrCast(key), "key-released", @ptrCast(&onEmbedKeyRelease), win, null, 0);
        c.gtk_widget_add_controller(win.picture, key);
        win.embed_key_ctl = @ptrCast(key);
        win.host.applyImRouting(win);

        const focus = c.gtk_event_controller_focus_new();
        _ = c.g_signal_connect_data(@ptrCast(focus), "enter", @ptrCast(&onEmbedFocusEnter), win, null, 0);
        _ = c.g_signal_connect_data(@ptrCast(focus), "leave", @ptrCast(&onEmbedFocusLeave), win, null, 0);
        c.gtk_widget_add_controller(win.picture, focus);

        const sensor = c.gtk_drawing_area_new();
        c.gtk_widget_set_can_target(sensor, 0);
        c.gtk_widget_set_hexpand(sensor, 1);
        c.gtk_widget_set_vexpand(sensor, 1);
        _ = c.g_signal_connect_data(@ptrCast(sensor), "resize", @ptrCast(&onEmbedResize), win, null, 0);
        c.gtk_overlay_add_overlay(@ptrCast(win.overlay), sensor);
        win.embed_sensor = sensor;
    }

    /// Detach the embedded view back into its floating window
    /// ("Pop Out" — and the mechanical half of releaseEmbed).
    pub fn popOut(self: *AppHost) void {
        const win = self.unembed() orelse return;
        self.wireFloating(win);
        // Size the floating window to the full committed buffer (the
        // Linux floating path shows buffer + CSD shadow and reports
        // the shadow width to the WM).
        if (win.buf_w > 0 and win.buf_h > 0)
            c.gtk_window_set_default_size(win.window, win.buf_w, win.buf_h);
        c.gtk_window_present(win.window);
        if (self.on_embed) |f| f(self.embed_ctx, false);
    }

    /// Embed the primary floating window into the pane's embed box
    /// ("Show in Tab"). The pane installs embed_box before calling.
    pub fn popIn(self: *AppHost) void {
        if (self.embed_box == null or self.embed_surface != 0) return;
        // Primary = first non-transient window (dialogs stay afloat).
        var pick: ?*Win = null;
        var it = self.windows.valueIterator();
        while (it.next()) |w| {
            if (c.gtk_window_get_transient_for(w.*.window) == null) {
                pick = w.*;
                break;
            }
            if (pick == null) pick = w.*;
        }
        const win = pick orelse return;
        self.embedWin(win);
    }

    /// Return the embedded overlay to its hidden window WITHOUT
    /// presenting; clears embed state. Returns the window, or null
    /// if nothing was embedded.
    fn unembed(self: *AppHost) ?*Win {
        const sid = self.embed_surface;
        if (sid == 0) return null;
        self.embed_surface = 0;
        const win = self.windows.get(sid) orelse return null;
        if (win.embed_sensor) |s| c.gtk_widget_set_visible(s, 0);
        if (self.embed_box) |box| {
            _ = c.g_object_ref(@ptrCast(win.overlay));
            c.gtk_box_remove(@ptrCast(box), win.overlay);
            c.gtk_window_set_child(win.window, win.overlay);
            c.g_object_unref(@ptrCast(win.overlay));
        }
        win.embedded = false;
        // Display switches from the geometry crop back to the full
        // buffer next frame; keep mapXY consistent meanwhile.
        win.crop_x = 0;
        win.crop_y = 0;
        win.crop_w = win.buf_w;
        win.crop_h = win.buf_h;
        return win;
    }

    /// The pane is going away or switching hosts: silently return
    /// the embedded view to its (hidden) window and forget the
    /// pane's box + callbacks. Safe when nothing is embedded.
    pub fn releaseEmbed(self: *AppHost) void {
        _ = self.unembed();
        self.embed_box = null;
        self.on_embed = null;
        self.on_request_embed = null;
        self.embed_ctx = null;
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
        win.host.seatEnter(win.surface, p[0], p[1]);
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
        win.host.seatEnter(win.surface, p[0], p[1]);
        win.host.seatMotion(p[0], p[1]);
        win.host.flushHost();
    }

    fn onPtrLeave(_: ?*c.GtkEventControllerMotion, user: ?*anyopaque) callconv(.c) void {
        const win = cast.userData(Win, user);
        win.applyEdge(0);
        win.host.stampNow();
        win.host.seatLeave();
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
        // Ctrl+right-click is the HOST menu (screenshot etc.) — the
        // only chrome a forwarded window has. Never forwarded.
        const state = c.gtk_event_controller_get_current_event_state(@ptrCast(gesture));
        if (win.press_btn == 3 and (state & c.GDK_CONTROL_MASK) != 0) {
            win.fwd_press = false;
            win.showHostMenu(x, y);
            return;
        }
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
        // Embedded: the picture must own keyboard focus for the
        // picture-level key controller to see keystrokes.
        if (win.embedded) _ = c.gtk_widget_grab_focus(win.picture);
        win.host.stampNow();
        // A click on the main surface while a menu is up dismisses it.
        win.host.dismissPopupsIntent();
        const p = win.mapXY(x, y);
        win.host.seatEnter(win.surface, p[0], p[1]);
        const btn = c.gtk_gesture_single_get_current_button(@ptrCast(gesture));
        win.host.seatButton(evdevButton(btn), true);
        win.host.flushHost();
    }

    fn onBtnRelease(gesture: ?*c.GtkGestureClick, _: c_int, _: f64, _: f64, user: ?*anyopaque) callconv(.c) void {
        const win = cast.userData(Win, user);
        if (!win.fwd_press) return; // press started a host resize, not app input
        win.host.stampNow();
        const btn = c.gtk_gesture_single_get_current_button(@ptrCast(gesture));
        win.host.seatButton(evdevButton(btn), false);
        win.host.flushHost();
    }

    fn onScroll(scroll: ?*c.GtkEventControllerScroll, dx: f64, dy: f64, user: ?*anyopaque) callconv(.c) c.gboolean {
        const win = cast.userData(Win, user);
        win.host.stampNow();
        // Discrete wheel steps arrive as ±1; ~10 surface px per
        // step matches what stock compositors send. Wheel-unit
        // scrolls additionally carry axis_value120 (±120/detent)
        // for v8-seat clients.
        const wheel = c.gtk_event_controller_scroll_get_unit(scroll) == c.GDK_SCROLL_UNIT_WHEEL;
        const v120y: i32 = if (wheel) @intFromFloat(dy * 120.0) else 0;
        const v120x: i32 = if (wheel) @intFromFloat(dx * 120.0) else 0;
        if (dy != 0) win.host.seatAxis(0, dy * 10.0, v120y);
        if (dx != 0) win.host.seatAxis(1, dx * 10.0, v120x);
        win.host.flushHost();
        return 1;
    }

    /// A local drop landed on the forwarded window: files become a
    /// text/uri-list, plain text stays text. NOTE: file URIs name
    /// LOCAL paths — for apps running on a remote host they won't
    /// resolve (text drops work everywhere).
    fn onHostDrop(_: ?*c.GtkDropTarget, value: ?*c.GValue, x: f64, y: f64, user: ?*anyopaque) callconv(.c) c.gboolean {
        const win = cast.userData(Win, user);
        const v = value orelse return 0;
        const host = win.host;
        const p = win.mapXY(x, y);
        host.stampNow();
        if (c.g_type_check_value_holds(v, c.G_TYPE_STRING) != 0) {
            const s = c.g_value_get_string(v) orelse return 0;
            host.hostDropIntent(win.surface, p[0], p[1], "text/plain;charset=utf-8", std.mem.span(@as([*:0]const u8, @ptrCast(s))));
            host.flushHost();
            return 1;
        }
        if (c.g_type_check_value_holds(v, c.gdk_file_list_get_type()) != 0) {
            const flist: ?*c.GdkFileList = @ptrCast(@alignCast(c.g_value_get_boxed(v)));
            const files = c.gdk_file_list_get_files(flist orelse return 0);
            var uris: std.ArrayList(u8) = .empty;
            defer uris.deinit(host.allocator);
            var it = files;
            while (it != null) : (it = it.*.next) {
                const gf: ?*c.GFile = @ptrCast(@alignCast(it.*.data));
                const uri = c.g_file_get_uri(gf orelse continue) orelse continue;
                defer c.g_free(uri);
                uris.appendSlice(host.allocator, std.mem.span(@as([*:0]const u8, @ptrCast(uri)))) catch return 0;
                uris.appendSlice(host.allocator, "\r\n") catch return 0;
            }
            if (uris.items.len == 0) return 0;
            host.hostDropIntent(win.surface, p[0], p[1], "text/uri-list", uris.items);
            host.flushHost();
            return 1;
        }
        return 0;
    }

    fn sendKey(win: *Win, keycode: c_uint, state: c.GdkModifierType, pressed: bool) void {
        win.host.stampNow();
        const target = if (win.host.comp.grabbed_popup != 0) win.host.comp.grabbed_popup else win.surface;
        win.host.seatKbdEnter(target);
        // First key toward a newly focused surface: make sure it
        // has a host-clipboard offer to paste from (the focus
        // controller alone is unreliable under bare X).
        if (win.host.offered_focus != win.host.comp.keyboard_focus) {
            win.host.offered_focus = win.host.comp.keyboard_focus;
            win.host.offerSelectionIntent("text/plain;charset=utf-8");
            win.host.offerPrimaryIntent("text/plain;charset=utf-8");
        }
        // GDK's low modifier bits are the X11/xkb mod order the
        // pc105/us keymap uses (shift, lock, ctrl, mod1…).
        win.host.seatMods(@as(u32, @intCast(state)) & 0xff, 0, 0, 0);
        if (keycode >= 8)
            win.host.seatKey(@intCast(keycode - 8), pressed);
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
        win.host.seatKbdEnter(win.surface);
        // Fresh offer per focus: the host clipboard may have changed
        // while the app was unfocused. Empty clipboards just paste
        // empty (the async read answers honestly either way).
        win.host.offered_focus = win.host.comp.keyboard_focus;
        win.host.offerSelectionIntent("text/plain;charset=utf-8");
        win.host.offerPrimaryIntent("text/plain;charset=utf-8");
        win.host.flushHost();
    }

    fn onFocusLeave(_: ?*c.GtkEventControllerFocus, user: ?*anyopaque) callconv(.c) void {
        const win = cast.userData(Win, user);
        win.host.stampNow();
        win.host.seatKbdLeave();
        win.host.flushHost();
    }

    // ── embedded-mode input (controllers on the picture; guarded so
    //    they stay inert after a pop-out returns the picture to the
    //    window, whose own controllers take over) ──────────────────

    fn onEmbedKeyPress(_: ?*c.GtkEventControllerKey, _: c_uint, keycode: c_uint, state: c.GdkModifierType, user: ?*anyopaque) callconv(.c) c.gboolean {
        const win = cast.userData(Win, user);
        if (!win.embedded) return 0;
        sendKey(win, keycode, state, true);
        return 1;
    }

    fn onEmbedKeyRelease(_: ?*c.GtkEventControllerKey, _: c_uint, keycode: c_uint, state: c.GdkModifierType, user: ?*anyopaque) callconv(.c) void {
        const win = cast.userData(Win, user);
        if (!win.embedded) return;
        sendKey(win, keycode, state, false);
    }

    fn onEmbedFocusEnter(_: ?*c.GtkEventControllerFocus, user: ?*anyopaque) callconv(.c) void {
        const win = cast.userData(Win, user);
        if (!win.embedded) return;
        onFocusEnter(null, user);
    }

    fn onEmbedFocusLeave(_: ?*c.GtkEventControllerFocus, user: ?*anyopaque) callconv(.c) void {
        const win = cast.userData(Win, user);
        if (!win.embedded) return;
        onFocusLeave(null, user);
    }

    /// The embed sensor resized: the pane's size is authoritative —
    /// configure the app to draw at it (fresh frames replace the
    /// briefly-stretched FILL picture).
    fn onEmbedResize(_: ?*c.GtkDrawingArea, w: c_int, h: c_int, user: ?*anyopaque) callconv(.c) void {
        const win = cast.userData(Win, user);
        if (!win.embedded) return;
        if (w <= 0 or h <= 0) return;
        // Skip echoes of what the app already drew or what we already
        // asked for (configure storms upset some clients).
        const geo = win.host.geos.get(win.surface) orelse [4]i32{ 0, 0, 0, 0 };
        if ((w == geo[2] and h == geo[3]) or (w == win.sent_w and h == win.sent_h)) return;
        win.sent_w = w;
        win.sent_h = h;
        win.host.configureIntent(win.surface, w, h, .{ .activated = true });
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
        // Latch the relationship — set_parent routinely lands before
        // the window exists (dialogs set it at creation, the window is
        // built on first frame) — then apply if both ends are present.
        self.pending_parents.put(self.allocator, surface, parent) catch {
            std.debug.print("wlapp: OOM latching parent for surface#{d} — dialog will open standalone\n", .{surface});
        };
        self.applyParent(surface);
    }

    /// Set (or clear) a window's transient-for from the latched parent,
    /// once the child window exists. The parent window may still be
    /// absent (frames race) — leave it unset until its winFor sweep
    /// picks up this child.
    fn applyParent(self: *AppHost, surface: u32) void {
        const win = self.windows.get(surface) orelse return;
        const parent = self.pending_parents.get(surface) orelse return;
        if (parent == 0) {
            c.gtk_window_set_transient_for(win.window, null);
            return;
        }
        // Parent window not built yet: keep whatever transient-for the
        // child has — the parent's winFor sweep applies this latch later.
        const p = self.windows.get(parent) orelse return;
        c.gtk_window_set_transient_for(win.window, p.window);
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
        // The surface exists now: apply the app_id's surface-bound
        // parts (Wayland set_application_id / X11 WM_CLASS) that were
        // skipped when it arrived before the first frame. Set before
        // the first commit so the WM reads it on map.
        if (win.app_id) |aid| rw.applyAppId(win.window, aid);
        win.applyIcon();
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
        win.host.configureIntent(win.surface, bw, bh, st);
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

    fn gdkPrimary() ?*c.GdkClipboard {
        const display = c.gdk_display_get_default() orelse return null;
        return c.gdk_display_get_primary_clipboard(display);
    }

    /// App announced a copy: pull the content through the pipe; the
    /// answer lands in onClipData.
    fn onClipOffer(ctx: ?*anyopaque, source: u32, mime: []const u8) void {
        const self = cast.userData(AppHost, ctx);
        self.fetch_kinds.append(self.allocator, 0) catch return;
        self.clipSendIntent(source, mime);
        self.flushHost();
    }

    /// App announced a PRIMARY selection: same fetch pipe, routed to
    /// the host primary clipboard by the fetch-kind FIFO.
    fn onPrimaryOffer(ctx: ?*anyopaque, source: u32, mime: []const u8) void {
        const self = cast.userData(AppHost, ctx);
        self.fetch_kinds.append(self.allocator, 1) catch return;
        self.clipSendIntent(source, mime);
        self.flushHost();
    }

    /// Fetched app selection content → host clipboard (regular or
    /// primary, by the FIFO kind recorded at fetch time).
    fn onClipData(ctx: ?*anyopaque, bytes: []const u8) void {
        const self = cast.userData(AppHost, ctx);
        const kind: u8 = if (self.fetch_kinds.items.len > 0)
            self.fetch_kinds.orderedRemove(0)
        else
            0;
        const clipboard = (if (kind == 1) gdkPrimary() else gdkClipboard()) orelse return;
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
            self.clipDataIntent("");
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
            self.clipDataIntent(bytes);
            self.flushHost();
        }
        self.pending_reads -= 1;
        if (self.doomed and self.pending_reads == 0) self.finalFree();
    }

    /// App wants a PRIMARY paste: async-read the host primary
    /// selection; ALWAYS answer (separate daemon fd FIFO).
    fn onPrimaryRead(ctx: ?*anyopaque, mime: []const u8) void {
        _ = mime; // text-only scope
        const self = cast.userData(AppHost, ctx);
        const clipboard = gdkPrimary() orelse {
            self.primaryDataIntent("");
            self.flushHost();
            return;
        };
        self.pending_reads += 1;
        c.gdk_clipboard_read_text_async(clipboard, null, @ptrCast(&onPrimaryReadDone), self);
    }

    fn onPrimaryReadDone(src: ?*c.GObject, res: ?*c.GAsyncResult, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(AppHost, user);
        const text = c.gdk_clipboard_read_text_finish(@ptrCast(src), res, null);
        defer if (text != null) c.g_free(text);
        if (!self.dead) {
            const bytes: []const u8 = if (text) |tp| std.mem.span(@as([*:0]const u8, @ptrCast(tp))) else "";
            self.primaryDataIntent(bytes);
            self.flushHost();
        }
        self.pending_reads -= 1;
        if (self.doomed and self.pending_reads == 0) self.finalFree();
    }

    /// xdg_popup.reposition landed: move the existing popup area to
    /// its new parent-relative spot (offset math mirrors onPopupNew).
    fn onPopupMoved(ctx: ?*anyopaque, surface: u32, parent: u32, x: i32, y: i32) void {
        const self = cast.userData(AppHost, ctx);
        const popup = self.popups.get(surface) orelse return;
        var px = x;
        var py = y;
        if (self.windows.get(parent) != null) {
            if (builtin.os.tag != .macos) {
                if (self.geos.get(parent)) |g| {
                    px += g[0];
                    py += g[1];
                }
            }
        } else if (self.popups.get(parent)) |pp| {
            px += c.gtk_widget_get_margin_start(pp.area);
            py += c.gtk_widget_get_margin_top(pp.area);
        }
        c.gtk_widget_set_margin_start(popup.area, @max(0, px));
        c.gtk_widget_set_margin_top(popup.area, @max(0, py));
    }

    /// Pointer lock: hide the host cursor over the app while locked
    /// (the app steers via relative_motion), restore on unlock.
    fn onPointerLocked(ctx: ?*anyopaque, surface: u32, locked: bool) void {
        const self = cast.userData(AppHost, ctx);
        const win = self.windows.get(surface) orelse return;
        c.gtk_widget_set_cursor_from_name(win.picture, if (locked) "none" else "default");
    }

    /// xdg-activation activate: present the window.
    fn onRaise(ctx: ?*anyopaque, surface: u32) void {
        const self = cast.userData(AppHost, ctx);
        const win = self.windows.get(surface) orelse return;
        if (!win.embedded) c.gtk_window_present(win.window);
    }

    /// The app toggled its text input: attach/detach the host IM on
    /// every window's key controllers.
    fn onTextInputActive(ctx: ?*anyopaque, active: bool) void {
        const self = cast.userData(AppHost, ctx);
        if (self.text_active == active) return;
        self.text_active = active;
        var it = self.windows.valueIterator();
        while (it.next()) |w| self.applyImRouting(w.*);
    }

    /// Attach or detach the IM context on a window's key controllers
    /// per the current text_active state (idempotent; called on wire
    /// and on state flips).
    fn applyImRouting(self: *AppHost, win: *Win) void {
        if (self.text_active and win.im == null) {
            const im = c.gtk_im_multicontext_new();
            _ = c.g_signal_connect_data(@ptrCast(im), "commit", @ptrCast(&onImCommit), win, null, 0);
            win.im = im;
        }
        const im: ?*c.GtkIMContext = if (self.text_active) win.im else null;
        if (win.key_ctl) |k| c.gtk_event_controller_key_set_im_context(k, im);
        if (win.embed_key_ctl) |k| c.gtk_event_controller_key_set_im_context(k, im);
    }

    /// Host IM committed text (IME result, compose, dead keys) —
    /// deliver it via zwp_text_input_v3.commit_string.
    fn onImCommit(_: ?*c.GtkIMContext, str: ?[*:0]const u8, user: ?*anyopaque) callconv(.c) void {
        const win = cast.userData(Win, user);
        const text = str orelse return;
        win.host.stampNow();
        win.host.textCommitIntent(std.mem.span(text));
        win.host.flushHost();
    }

    fn winStates(win: *Win) @import("wlhost/compositor.zig").Compositor.ToplevelState {
        // Embedded: the hidden GtkWindow is never active — report the
        // app as activated so it renders live chrome in its tab.
        if (win.embedded) return .{ .activated = true };
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
        win.host.configureIntent(win.surface, w, h, st);
        win.host.flushHost();
    }

    /// State-only change (focus in/out): configure at the current
    /// geometry size with fresh states — bypasses the size echo guard.
    fn onWinState(_: ?*c.GtkWindow, _: ?*c.GParamSpec, user: ?*anyopaque) callconv(.c) void {
        const win = cast.userData(Win, user);
        const geo = win.host.geos.get(win.surface) orelse return;
        if (geo[2] <= 0 or geo[3] <= 0) return;
        win.host.configureIntent(win.surface, geo[2], geo[3], winStates(win));
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
        self.requestCloseIntent(win.surface);
        if (self.on_flush) |f| f(self.flush_ctx);
        return 1; // handled; wait for the app
    }
};
