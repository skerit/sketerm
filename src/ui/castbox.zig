//! Shared asciicast playback component (surface + transport bar).
//!
//! A CastPlayerBox owns a Terminal attached to a daemon cast-playback
//! session and renders it through a TerminalSurface in `fixed_grid`
//! geometry, plus the transport bar (play/pause, restart, seek slider
//! with markers, speed) and all play_state/seek/speed logic. The
//! session is spawned ephemeral, so destroying the box kills playback.
//! Hosts: the standalone `sketerm play` window (`castview.zig`) and the
//! Sketerm Viewer's cast content (`viewer.zig`).
//!
//! Widget ownership: the host parents `surfaceWidget()` and
//! `barWidget()` wherever it wants (castview keeps the bar as an Adw
//! bottom bar; the viewer stacks them in its content area). Teardown
//! contract, in order: `severLive()` (fences every timer and sink),
//! then let the widgets die (window destroy, or explicit removal from
//! their containers), then `destroy()` — which kills the ephemeral
//! session and frees the struct. The transport-bar signal handlers
//! carry a raw *CastPlayerBox with no destroy-notify; that is safe
//! because both hosts guarantee the widgets are gone before destroy()
//! runs (mechanism 2 of the signal-lifetime rules: a single teardown
//! choke point).

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

pub const CastPlayerBox = struct {
    /// Host hooks. `on_title` receives the recording title (cast/OSC
    /// title when known, else the file's basename); `on_state` fires
    /// after every play_state, AFTER the transport bar updated —
    /// `st.markers` is only valid inside the call.
    pub const Callbacks = struct {
        ctx: ?*anyopaque = null,
        on_title: ?*const fn (?*anyopaque, []const u8) void = null,
        on_state: ?*const fn (?*anyopaque, Terminal.PlayState) void = null,
    };

    allocator: std.mem.Allocator,
    terminal: *Terminal,
    surface: TerminalSurface,
    /// Per-box Config (fonts). Owned; freed in destroy().
    config: Config,
    callbacks: Callbacks,

    play_button: *c.GtkWidget,
    bar: *c.GtkWidget,
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
    /// True once severLive ran; makes it idempotent.
    severed: bool = false,

    /// Spawn a cast-playback session for `spec` (local path or
    /// host:/path) and build the playback widgets on it. `log_prefix`
    /// tags stderr failure reports ("sketerm play", "sketerm view").
    pub fn create(
        allocator: std.mem.Allocator,
        spec: []const u8,
        log_prefix: [*:0]const u8,
        callbacks: Callbacks,
    ) !*CastPlayerBox {
        const loc = paths.parseSpec(spec);

        var conn = connectFor(allocator, loc.host, log_prefix) orelse return error.ConnectFailed;
        var conn_owned = true;
        errdefer if (conn_owned) conn.deinit();
        if (!conn.cast_playback) {
            _ = c.fprintf(platform.stderr(), "%s: the daemon is too old for cast playback (update sketerm-mux%s)\n", log_prefix, @as([*:0]const u8, if (loc.host != null) " on the remote host" else ""));
            return error.DaemonTooOld;
        }

        var name_buf: [64]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "cast{d}-{d}", .{ c.getpid(), next_cast_id }) catch unreachable;
        next_cast_id += 1;

        conn.sendJson(.spawn, .{ .name = name, .cast_path = loc.path }) catch return error.SpawnFailed;
        const ok = conn.recvExpect(&.{.ok}) catch |err| {
            if (err == error.DaemonError) {
                const why = conn.lastErr();
                _ = c.fprintf(platform.stderr(), "%s: %.*s: %.*s\n", log_prefix, @as(c_int, @intCast(loc.path.len)), loc.path.ptr, @as(c_int, @intCast(why.len)), why.ptr);
            } else {
                _ = c.fprintf(platform.stderr(), "%s: spawn failed: %s\n", log_prefix, @errorName(err).ptr);
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
        if (terminal.remote) |r| r.ephemeral = true; // destroying the box kills the session

        const self = try allocator.create(CastPlayerBox);
        errdefer allocator.destroy(self);

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
        c.gtk_widget_set_tooltip_text(scale, "Seek");
        const speed_drop = c.gtk_drop_down_new_from_strings(@ptrCast(@constCast(&SPEED_LABELS))).?;
        c.gtk_drop_down_set_selected(@ptrCast(speed_drop), 2); // 1x
        c.gtk_widget_set_tooltip_text(speed_drop, "Playback speed");
        c.gtk_box_append(@ptrCast(bar), play_button);
        c.gtk_box_append(@ptrCast(bar), restart_button);
        c.gtk_box_append(@ptrCast(bar), scale);
        c.gtk_box_append(@ptrCast(bar), @ptrCast(@alignCast(position_label)));
        c.gtk_box_append(@ptrCast(bar), speed_drop);

        self.* = .{
            .allocator = allocator,
            .terminal = terminal,
            .surface = undefined,
            .config = Config.load(allocator),
            .callbacks = callbacks,
            .play_button = play_button,
            .bar = bar,
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

        // ── sink wiring: PASSIVE VIEWER POLICY ─────────────────────
        // The cast is UNTRUSTED recorded content, so only what
        // rendering and the transport bar need is wired: render
        // requests, images, glyph coverage, title, play_state.
        // Deliberately NOT wired: clipboard set/get, notifications,
        // pointer shape, cwd, command status, bell side effects,
        // profile switches — a recording must not be able to reach
        // any of those. (No input/resize is ever sent either; this
        // component has no input path to the terminal at all.)
        terminal.user_ctx = @ptrCast(self);
        terminal.on_render_request = onRenderRequest;
        terminal.on_image = onImageEvent;
        terminal.on_image_delete_full = onImageDeleteEvent;
        terminal.on_glyph_coverage = onGlyphCoverage;
        terminal.on_title = onTitleEvent;
        terminal.on_play_state = onPlayState;

        self.emitTitle(terminal.screen.last_title orelse std.fs.path.basename(loc.path));
        // Snapshot-restored image placements (a cast that finished
        // before we attached) replay into the freshly wired sink.
        terminal.replayRetainedImages();

        _ = c.g_signal_connect_data(play_button, "clicked", @ptrCast(&onPlayClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(restart_button, "clicked", @ptrCast(&onRestartClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        // change-value fires on USER interaction only (set_value does
        // not emit it), so no feedback-loop guard is needed here.
        _ = c.g_signal_connect_data(scale, "change-value", @ptrCast(&onScaleChangeValue), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(speed_drop, "notify::selected", @ptrCast(&onSpeedChanged), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        return self;
    }

    fn connectFor(allocator: std.mem.Allocator, host: ?[]const u8, log_prefix: [*:0]const u8) ?mux_client.Conn {
        if (host != null) return mux_cli.muxConnect(allocator, host);
        return mux_client.Conn.connectLocalAutostart(allocator) catch {
            _ = c.fprintf(platform.stderr(), "%s: cannot start the local sketerm-mux daemon\n", log_prefix);
            return null;
        };
    }

    /// The rendering widget (the GtkGLArea-backed TerminalSurface).
    pub fn surfaceWidget(self: *CastPlayerBox) *c.GtkWidget {
        return self.surface.widget();
    }

    /// The transport bar (play/restart/seek/position/speed).
    pub fn barWidget(self: *CastPlayerBox) *c.GtkWidget {
        return self.bar;
    }

    /// Fence everything that can fire into widgets or this struct
    /// between widget teardown and destroy(). Idempotent.
    pub fn severLive(self: *CastPlayerBox) void {
        if (self.severed) return;
        self.severed = true;
        if (self.seek_timer != 0) {
            _ = c.g_source_remove(self.seek_timer);
            self.seek_timer = 0;
        }
        self.surface.stopVisualSources();
        self.terminal.clearSinks();
    }

    /// Free the box and kill the ephemeral session (Terminal.deinit
    /// sends the kill). The widgets must already be dead.
    pub fn destroy(self: *CastPlayerBox) void {
        self.severLive();
        self.surface.deinit();
        self.terminal.deinit();
        self.config.deinit();
        self.allocator.destroy(self);
    }

    fn emitTitle(self: *CastPlayerBox, title: []const u8) void {
        const cb = self.callbacks.on_title orelse return;
        cb(self.callbacks.ctx, title);
    }

    // ── terminal sinks ───────────────────────────────────────────

    fn onRenderRequest(ctx: ?*anyopaque) void {
        const self = cast.userData(CastPlayerBox, ctx);
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
        const self = cast.userData(CastPlayerBox, ctx);
        self.surface.addImage(img);
    }

    fn onImageDeleteEvent(ctx: ?*anyopaque, ev: @import("../grid/screen.zig").Screen.ImageDeleteEvent) void {
        const self = cast.userData(CastPlayerBox, ctx);
        self.surface.deleteImages(ev);
    }

    fn onGlyphCoverage(ctx: ?*anyopaque, cp: u32) bool {
        const self = cast.userData(CastPlayerBox, ctx);
        return self.surface.hasGlyph(cp);
    }

    fn onTitleEvent(ctx: ?*anyopaque, title: []const u8) void {
        const self = cast.userData(CastPlayerBox, ctx);
        self.emitTitle(title);
    }

    fn onPlayState(ctx: ?*anyopaque, st: Terminal.PlayState) void {
        const self = cast.userData(CastPlayerBox, ctx);
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

        // Keep the thumb off the user's fingers: right after a user
        // seek, a THROTTLED position push (kind .playing) may still
        // carry the pre-seek position — skip only those. Event-driven
        // pushes (seeking/paused/finished — seek completions included)
        // always carry the fresh position and must land, or the thumb
        // sticks wherever the user left it.
        const now = c.g_get_monotonic_time();
        const guard = st.kind == .playing and now - self.user_seek_us < SEEK_GUARD_US;
        if (self.duration_ms > 0 and !guard) {
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

        if (self.callbacks.on_state) |cb| cb(self.callbacks.ctx, st);
    }

    fn redrawMarkers(self: *CastPlayerBox, markers: []const Terminal.PlayState.Marker) void {
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

    fn playKind(self: *CastPlayerBox) Terminal.PlayState.Kind {
        // Sessions auto-play on first attach, so "no state yet" reads
        // as playing.
        const st = self.terminal.last_play_state orelse return .playing;
        return st.kind;
    }

    pub fn togglePlay(self: *CastPlayerBox) void {
        switch (self.playKind()) {
            .playing, .seeking => self.terminal.sendPlayControl(.pause, 0, 0),
            .paused => self.terminal.sendPlayControl(.play, 0, 0),
            .finished => self.terminal.sendPlayControl(.restart, 0, 0),
        }
    }

    pub fn restart(self: *CastPlayerBox) void {
        self.terminal.sendPlayControl(.restart, 0, 0);
    }

    pub fn seekRelative(self: *CastPlayerBox, delta_ms: i64) void {
        const pos: i64 = if (self.terminal.last_play_state) |st| @intCast(st.position_ms) else 0;
        var target = pos + delta_ms;
        if (target < 0) target = 0;
        self.user_seek_us = c.g_get_monotonic_time();
        self.terminal.sendPlayControl(.seek, @intCast(target), 0);
    }

    fn onPlayClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(CastPlayerBox, user);
        self.togglePlay();
    }

    fn onRestartClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(CastPlayerBox, user);
        self.restart();
    }

    fn onSpeedChanged(_: *c.GObject, _: ?*c.GParamSpec, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(CastPlayerBox, user);
        const idx = c.gtk_drop_down_get_selected(@ptrCast(self.speed_drop));
        if (idx >= SPEEDS.len) return;
        self.terminal.sendPlayControl(.speed, 0, SPEEDS[idx]);
    }

    /// Slider interaction: throttle to one seek per SEEK_THROTTLE_MS —
    /// every seek is a full daemon replay from byte zero.
    fn onScaleChangeValue(_: *c.GtkRange, _: c.GtkScrollType, value: f64, user: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast.userData(CastPlayerBox, user);
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

    fn flushSeek(self: *CastPlayerBox) void {
        const target = self.pending_seek orelse return;
        self.pending_seek = null;
        self.terminal.sendPlayControl(.seek, target, 0);
    }

    fn onSeekTimer(user: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast.userData(CastPlayerBox, user);
        if (self.pending_seek == null) {
            self.seek_timer = 0;
            return 0; // G_SOURCE_REMOVE
        }
        self.flushSeek();
        return 1; // keep throttling while the drag continues
    }
};
