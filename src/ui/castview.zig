//! Standalone asciicast playback window (`sketerm play <file.cast>`).
//!
//! A CastView owns a Terminal attached to a daemon cast-playback
//! session and renders it through a TerminalSurface in `fixed_grid`
//! geometry — the recording's dimensions drive the grid, the window
//! letterboxes around it. The session is spawned ephemeral, so closing
//! the window kills the playback session.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const paths = @import("../filebrowser/paths.zig");
const mux_client = @import("../mux/client.zig");
const mux_cli = @import("../ipc/mux_cli.zig");
const Terminal = @import("../terminal.zig").Terminal;
const TerminalSurface = @import("terminal_surface.zig").TerminalSurface;
const Config = @import("../config.zig").Config;
const platform = @import("../util/platform.zig");

const CAST_QDATA = "sketerm-cast-view";
/// Session-name counter (names are `cast<pid>-<n>`, JSON-safe).
var next_cast_id: u32 = 1;

/// Playback speeds offered by the dropdown; index 2 = 1x default.
const SPEEDS = [_]f64{ 0.25, 0.5, 1.0, 1.5, 2.0, 4.0 };
const SPEED_LABELS = [_:null]?[*:0]const u8{ "0.25x", "0.5x", "1x", "1.5x", "2x", "4x", null };
/// Minimum gap between seek frames while the slider is dragged — every
/// seek is a full daemon-side replay, so a drag must not stream one
/// per pixel.
const SEEK_THROTTLE_MS: c_uint = 250;
/// After a user seek, ignore programmatic slider updates this long so
/// a stale throttled play_state can't snap the thumb back.
const SEEK_GUARD_US: i64 = 1_000_000;

pub const CastView = struct {
    allocator: std.mem.Allocator,
    window: *c.GtkWidget,
    terminal: *Terminal,
    surface: TerminalSurface,
    /// Per-view Config (fonts). Owned; freed in the finalizer.
    config: Config,

    play_button: *c.GtkWidget,
    scale: *c.GtkWidget,
    position_label: *c.GtkLabel,
    speed_drop: *c.GtkWidget,

    /// Latest daemon-reported duration (0 = unknown, seek disabled).
    duration_ms: u64 = 0,
    /// Markers currently drawn on the scale (re-drawn on count change).
    marker_count: usize = 0,
    /// Monotonic µs of the last user slider interaction.
    user_seek_us: i64 = 0,
    /// Slider seek throttle: latest target, sent by `seek_timer`.
    pending_seek: ?u64 = null,
    seek_timer: c_uint = 0,
    /// True once severLive ran (window destroyed); makes it idempotent.
    severed: bool = false,

    /// Spawn a cast-playback session for `spec` (local path or
    /// host:/path) and open a playback window on it. Prints a readable
    /// reason to stderr on every failure path.
    pub fn open(allocator: std.mem.Allocator, app: ?*c.GtkApplication, spec: []const u8) !*CastView {
        const loc = paths.parseSpec(spec);

        var conn = connectFor(allocator, loc.host) orelse return error.ConnectFailed;
        var conn_owned = true;
        errdefer if (conn_owned) conn.deinit();
        if (!conn.cast_playback) {
            _ = c.fprintf(platform.stderr(), "sketerm play: the daemon is too old for cast playback (update sketerm-mux%s)\n", @as([*:0]const u8, if (loc.host != null) " on the remote host" else ""));
            return error.DaemonTooOld;
        }

        var name_buf: [64]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "cast{d}-{d}", .{ c.getpid(), next_cast_id }) catch unreachable;
        next_cast_id += 1;

        conn.sendJson(.spawn, .{ .name = name, .cast_path = loc.path }) catch return error.SpawnFailed;
        const ok = conn.recvExpect(&.{.ok}) catch |err| {
            if (err == error.DaemonError) {
                const why = conn.lastErr();
                _ = c.fprintf(platform.stderr(), "sketerm play: %.*s: %.*s\n", @as(c_int, @intCast(loc.path.len)), loc.path.ptr, @as(c_int, @intCast(why.len)), why.ptr);
            } else {
                _ = c.fprintf(platform.stderr(), "sketerm play: spawn failed: %s\n", @errorName(err).ptr);
            }
            return error.SpawnFailed;
        };
        ok.deinit(allocator);
        conn.sendJson(.attach, .{ .name = name, .kind = "gui" }) catch return error.AttachFailed;
        const snap = conn.recvExpect(&.{.snapshot}) catch return error.AttachFailed;
        defer snap.deinit(allocator);

        const terminal = try Terminal.initRemote(allocator, conn, name, snap.payload, loc.host, "", false, false);
        conn_owned = false; // moved into the Terminal
        errdefer terminal.deinit();
        if (terminal.remote) |r| r.ephemeral = true; // closing the window kills the session

        const self = try allocator.create(CastView);
        errdefer allocator.destroy(self);

        const window = c.adw_application_window_new(app) orelse return error.OutOfMemory;
        errdefer c.gtk_window_destroy(@ptrCast(window));
        c.gtk_window_set_default_size(@ptrCast(window), 960, 640);

        const toolbar = c.adw_toolbar_view_new().?;
        const header = c.adw_header_bar_new().?;
        c.adw_toolbar_view_add_top_bar(@ptrCast(toolbar), header);

        // Transport bar.
        const bar = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8).?;
        c.gtk_widget_set_margin_start(bar, 10);
        c.gtk_widget_set_margin_end(bar, 10);
        c.gtk_widget_set_margin_top(bar, 6);
        c.gtk_widget_set_margin_bottom(bar, 8);
        const play_button = c.gtk_button_new_from_icon_name("media-playback-pause-symbolic").?;
        c.gtk_widget_set_tooltip_text(play_button, "Play / Pause (Space)");
        const restart_button = c.gtk_button_new_from_icon_name("media-skip-backward-symbolic").?;
        c.gtk_widget_set_tooltip_text(restart_button, "Restart (R)");
        const position_label = c.gtk_label_new("0:00 / --:--").?;
        c.gtk_widget_add_css_class(position_label, "numeric");
        const scale = c.gtk_scale_new_with_range(c.GTK_ORIENTATION_HORIZONTAL, 0, 1, 100).?;
        c.gtk_scale_set_draw_value(@ptrCast(scale), 0);
        c.gtk_widget_set_hexpand(scale, 1);
        c.gtk_widget_set_sensitive(scale, 0); // until duration_ms is known
        c.gtk_widget_set_tooltip_text(scale, "Seek (Left/Right: 5s, Shift: 30s)");
        const speed_drop = c.gtk_drop_down_new_from_strings(@ptrCast(@constCast(&SPEED_LABELS))).?;
        c.gtk_drop_down_set_selected(@ptrCast(speed_drop), 2); // 1x
        c.gtk_widget_set_tooltip_text(speed_drop, "Playback speed");
        c.gtk_box_append(@ptrCast(bar), play_button);
        c.gtk_box_append(@ptrCast(bar), restart_button);
        c.gtk_box_append(@ptrCast(bar), scale);
        c.gtk_box_append(@ptrCast(bar), @ptrCast(@alignCast(position_label)));
        c.gtk_box_append(@ptrCast(bar), speed_drop);
        c.adw_toolbar_view_add_bottom_bar(@ptrCast(toolbar), bar);

        self.* = .{
            .allocator = allocator,
            .window = window,
            .terminal = terminal,
            .surface = undefined,
            .config = Config.load(allocator),
            .play_button = play_button,
            .scale = scale,
            .position_label = @ptrCast(@alignCast(position_label)),
            .speed_drop = speed_drop,
        };
        TerminalSurface.initInPlace(&self.surface, allocator, terminal);
        self.surface.geometry = .{ .fixed_grid = .{
            .cols = terminal.screen.cols,
            .rows = terminal.screen.rows,
        } };
        // Fonts honour the user's config; visuals otherwise stay at the
        // renderer defaults (no profile machinery here).
        const s = self.config.settings;
        self.surface.font_size = s.font_size;
        self.surface.font_path = s.font_path;
        self.surface.font_family = if (s.font_family.len > 0) s.font_family else null;
        self.surface.font_features = if (s.font_features.len > 0) s.font_features else null;
        self.surface.setFocused(true); // solid cursor, no inactive dim
        c.adw_toolbar_view_set_content(@ptrCast(toolbar), self.surface.widget());
        c.adw_application_window_set_content(@ptrCast(window), toolbar);

        // ── sink wiring: PASSIVE VIEWER POLICY ─────────────────────
        // The cast is UNTRUSTED recorded content, so only what
        // rendering and the transport bar need is wired: render
        // requests, images, glyph coverage, title, play_state.
        // Deliberately NOT wired: clipboard set/get, notifications,
        // pointer shape, cwd, command status, bell side effects,
        // profile switches — a recording must not be able to reach
        // any of those. (No input/resize is ever sent either; this
        // view has no input path to the terminal at all.)
        terminal.user_ctx = @ptrCast(self);
        terminal.on_render_request = onRenderRequest;
        terminal.on_image = onImageEvent;
        terminal.on_image_delete_full = onImageDeleteEvent;
        terminal.on_glyph_coverage = onGlyphCoverage;
        terminal.on_title = onTitleEvent;
        terminal.on_play_state = onPlayState;

        self.applyTitle(terminal.screen.last_title orelse std.fs.path.basename(loc.path));
        // Snapshot-restored image placements (a cast that finished
        // before we attached) replay into the freshly wired sink.
        terminal.replayRetainedImages();

        c.g_object_set_data_full(@ptrCast(window), CAST_QDATA, @ptrCast(self), @ptrCast(&destroyView));
        // Surface timers and terminal sinks reach into widgets; fence
        // them the moment the window starts dying, not at finalize.
        _ = c.g_signal_connect_data(window, "destroy", @ptrCast(&onWindowDestroy), @ptrCast(self), null, c.G_CONNECT_DEFAULT);

        _ = c.g_signal_connect_data(play_button, "clicked", @ptrCast(&onPlayClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(restart_button, "clicked", @ptrCast(&onRestartClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        // change-value fires on USER interaction only (set_value does
        // not emit it), so no feedback-loop guard is needed here.
        _ = c.g_signal_connect_data(scale, "change-value", @ptrCast(&onScaleChangeValue), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(speed_drop, "notify::selected", @ptrCast(&onSpeedChanged), @ptrCast(self), null, c.G_CONNECT_DEFAULT);

        const keys = c.gtk_event_controller_key_new();
        c.gtk_event_controller_set_propagation_phase(@ptrCast(keys), c.GTK_PHASE_CAPTURE);
        _ = c.g_signal_connect_data(keys, "key-pressed", @ptrCast(&onKey), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(window, @ptrCast(keys));

        c.gtk_window_present(@ptrCast(window));
        return self;
    }

    fn connectFor(allocator: std.mem.Allocator, host: ?[]const u8) ?mux_client.Conn {
        if (host != null) return mux_cli.muxConnect(allocator, host);
        return mux_client.Conn.connectLocalAutostart(allocator) catch {
            _ = c.fprintf(platform.stderr(), "sketerm play: cannot start the local sketerm-mux daemon\n");
            return null;
        };
    }

    /// Fence everything that can fire into widgets or this struct
    /// between window destroy and finalize. Idempotent.
    fn severLive(self: *CastView) void {
        if (self.severed) return;
        self.severed = true;
        if (self.seek_timer != 0) {
            _ = c.g_source_remove(self.seek_timer);
            self.seek_timer = 0;
        }
        self.surface.stopVisualSources();
        self.terminal.clearSinks();
    }

    /// GDestroyNotify at window finalize: free the view and kill the
    /// ephemeral session (Terminal.deinit sends the kill).
    fn destroyView(user: ?*anyopaque) callconv(.c) void {
        const self: *CastView = @ptrCast(@alignCast(user.?));
        self.severLive();
        self.surface.deinit();
        self.terminal.deinit();
        self.config.deinit();
        self.allocator.destroy(self);
    }

    fn onWindowDestroy(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(CastView, user);
        self.severLive();
    }

    fn applyTitle(self: *CastView, name: []const u8) void {
        var buf: [512:0]u8 = undefined;
        const t = std.fmt.bufPrintZ(&buf, "{s} - Sketerm Play", .{name}) catch "Sketerm Play";
        c.gtk_window_set_title(@ptrCast(self.window), t.ptr);
    }

    // ── terminal sinks ───────────────────────────────────────────

    fn onRenderRequest(ctx: ?*anyopaque) void {
        const self = cast.userData(CastView, ctx);
        // A recorded resize reaches us as a snapshot swap; track the
        // grid dimensions into the fixed_grid geometry.
        const screen = self.terminal.screen;
        switch (self.surface.geometry) {
            .fixed_grid => |fg| if (fg.cols != screen.cols or fg.rows != screen.rows) {
                self.surface.geometry = .{ .fixed_grid = .{ .cols = screen.cols, .rows = screen.rows } };
            },
            .live_terminal => {},
        }
        self.surface.queueRender();
    }

    fn onImageEvent(ctx: ?*anyopaque, img: @import("../grid/screen.zig").Screen.ImageEvent) void {
        const self = cast.userData(CastView, ctx);
        self.surface.addImage(img);
    }

    fn onImageDeleteEvent(ctx: ?*anyopaque, ev: @import("../grid/screen.zig").Screen.ImageDeleteEvent) void {
        const self = cast.userData(CastView, ctx);
        self.surface.deleteImages(ev);
    }

    fn onGlyphCoverage(ctx: ?*anyopaque, cp: u32) bool {
        const self = cast.userData(CastView, ctx);
        return self.surface.hasGlyph(cp);
    }

    fn onTitleEvent(ctx: ?*anyopaque, title: []const u8) void {
        const self = cast.userData(CastView, ctx);
        self.applyTitle(title);
    }

    fn onPlayState(ctx: ?*anyopaque, st: Terminal.PlayState) void {
        const self = cast.userData(CastView, ctx);
        const playing = st.kind == .playing or st.kind == .seeking;
        c.gtk_button_set_icon_name(
            @ptrCast(self.play_button),
            if (playing) "media-playback-pause-symbolic" else "media-playback-start-symbolic",
        );

        if (st.duration_ms) |d| {
            const dur = @max(d, 1);
            if (self.duration_ms != dur) {
                self.duration_ms = dur;
                c.gtk_range_set_range(@ptrCast(self.scale), 0, @floatFromInt(dur));
                c.gtk_widget_set_sensitive(self.scale, 1);
                self.redrawMarkers(st.markers);
            }
        }
        if (st.markers.len != self.marker_count) self.redrawMarkers(st.markers);

        // Keep the thumb off the user's fingers: skip programmatic
        // updates right after a user seek (a throttled play_state may
        // still carry the pre-seek position).
        const now = c.g_get_monotonic_time();
        if (self.duration_ms > 0 and now - self.user_seek_us > SEEK_GUARD_US) {
            c.gtk_range_set_value(@ptrCast(self.scale), @floatFromInt(st.position_ms));
        }

        var buf: [64:0]u8 = undefined;
        const text = if (st.kind == .seeking)
            std.fmt.bufPrintZ(&buf, "seeking...", .{}) catch return
        else if (st.duration_ms) |d|
            std.fmt.bufPrintZ(&buf, "{d}:{d:0>2} / {d}:{d:0>2}", .{
                st.position_ms / 60_000, (st.position_ms / 1000) % 60,
                d / 60_000,              (d / 1000) % 60,
            }) catch return
        else
            std.fmt.bufPrintZ(&buf, "{d}:{d:0>2} / --:--", .{
                st.position_ms / 60_000, (st.position_ms / 1000) % 60,
            }) catch return;
        c.gtk_label_set_text(self.position_label, text.ptr);
    }

    fn redrawMarkers(self: *CastView, markers: []const Terminal.PlayState.Marker) void {
        c.gtk_scale_clear_marks(@ptrCast(self.scale));
        if (self.duration_ms == 0) {
            self.marker_count = markers.len;
            return;
        }
        for (markers) |m| {
            c.gtk_scale_add_mark(@ptrCast(self.scale), @floatFromInt(m.ms), c.GTK_POS_BOTTOM, null);
        }
        self.marker_count = markers.len;
    }

    // ── transport controls ───────────────────────────────────────

    fn playKind(self: *CastView) Terminal.PlayState.Kind {
        // Sessions auto-play on first attach, so "no state yet" reads
        // as playing.
        const st = self.terminal.last_play_state orelse return .playing;
        return st.kind;
    }

    fn togglePlay(self: *CastView) void {
        switch (self.playKind()) {
            .playing, .seeking => self.terminal.sendPlayControl(.pause, 0, 0),
            .paused => self.terminal.sendPlayControl(.play, 0, 0),
            .finished => self.terminal.sendPlayControl(.restart, 0, 0),
        }
    }

    fn seekRelative(self: *CastView, delta_ms: i64) void {
        const pos: i64 = if (self.terminal.last_play_state) |st| @intCast(st.position_ms) else 0;
        var target = pos + delta_ms;
        if (target < 0) target = 0;
        self.user_seek_us = c.g_get_monotonic_time();
        self.terminal.sendPlayControl(.seek, @intCast(target), 0);
    }

    fn onPlayClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(CastView, user);
        self.togglePlay();
    }

    fn onRestartClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(CastView, user);
        self.terminal.sendPlayControl(.restart, 0, 0);
    }

    fn onSpeedChanged(_: *c.GObject, _: ?*c.GParamSpec, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(CastView, user);
        const idx = c.gtk_drop_down_get_selected(@ptrCast(self.speed_drop));
        if (idx >= SPEEDS.len) return;
        self.terminal.sendPlayControl(.speed, 0, SPEEDS[idx]);
    }

    /// Slider interaction: throttle to one seek per SEEK_THROTTLE_MS —
    /// every seek is a full daemon replay from byte zero.
    fn onScaleChangeValue(_: *c.GtkRange, _: c.GtkScrollType, value: f64, user: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast.userData(CastView, user);
        if (self.duration_ms == 0) return 0;
        const clamped = std.math.clamp(value, 0, @as(f64, @floatFromInt(self.duration_ms)));
        self.user_seek_us = c.g_get_monotonic_time();
        self.pending_seek = @intFromFloat(clamped);
        if (self.seek_timer == 0) {
            self.flushSeek();
            self.seek_timer = c.g_timeout_add(SEEK_THROTTLE_MS, @ptrCast(&onSeekTimer), @ptrCast(self));
        }
        return 0; // let the range update visually
    }

    fn flushSeek(self: *CastView) void {
        const target = self.pending_seek orelse return;
        self.pending_seek = null;
        self.terminal.sendPlayControl(.seek, target, 0);
    }

    fn onSeekTimer(user: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast.userData(CastView, user);
        if (self.pending_seek == null) {
            self.seek_timer = 0;
            return 0; // G_SOURCE_REMOVE
        }
        self.flushSeek();
        return 1; // keep throttling while the drag continues
    }

    fn onKey(
        _: *c.GtkEventControllerKey,
        keyval: c.guint,
        _: c.guint,
        state: c.GdkModifierType,
        user: ?*anyopaque,
    ) callconv(.c) c.gboolean {
        const self = cast.userData(CastView, user);
        const shift = (state & c.GDK_SHIFT_MASK) != 0;
        const step: i64 = if (shift) 30_000 else 5_000;
        switch (keyval) {
            c.GDK_KEY_space => self.togglePlay(),
            c.GDK_KEY_Left => self.seekRelative(-step),
            c.GDK_KEY_Right => self.seekRelative(step),
            c.GDK_KEY_r, c.GDK_KEY_R => self.terminal.sendPlayControl(.restart, 0, 0),
            c.GDK_KEY_q, c.GDK_KEY_Escape => c.gtk_window_close(@ptrCast(self.window)),
            else => return 0,
        }
        return 1;
    }
};
