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
//! session and frees the struct. The bar chrome is the shared
//! `Playbar` widget (`playbar.zig`), which follows the same contract.

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
const Playbar = @import("playbar.zig").Playbar;

/// Session-name counter (names are `cast<pid>-<n>`, JSON-safe).
var next_cast_id: u32 = 1;

/// Minimum gap between seek frames while the slider is dragged — every
/// seek is a full daemon-side replay, so a drag must not stream one
/// per pixel.
const SEEK_THROTTLE_MS: c_uint = 250;
/// After a user seek, ignore programmatic slider updates this long so
/// a stale throttled play_state can't snap the thumb back.
const SEEK_GUARD_US: i64 = 1_000_000;
/// How long an unconfirmed transport command outranks the daemon's
/// last pushed state (backstop for a command the daemon folds into
/// something else, e.g. a pause landing mid-seek).
const EXPECT_TRUST_US: i64 = 2_000_000;

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

    /// Shared transport-bar chrome; owns the throttle/guard machinery.
    playbar: *Playbar,

    /// Playback kind the last transport command asked the daemon for,
    /// held until the daemon confirms it (see `playKind`).
    expected_kind: ?Terminal.PlayState.Kind = null,
    /// Monotonic µs of that command.
    expected_us: i64 = 0,

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

        const terminal = try Terminal.initRemote(allocator, conn, name, snap.payload, .{}, loc.host, "", false, false);
        conn_owned = false; // moved into the Terminal
        errdefer terminal.deinit();
        if (terminal.remote) |r| r.ephemeral = true; // destroying the box kills the session

        const self = try allocator.create(CastPlayerBox);
        errdefer allocator.destroy(self);

        // Transport bar: the shared Playbar with the cast policy —
        // seeks are daemon replays, so throttle + guard are on.
        const playbar = try Playbar.create(allocator, .{
            .ctx = @ptrCast(self),
            .toggle = &srcToggle,
            .restart = &srcRestart,
            .seek_to_ms = &srcSeekToMs,
            .set_speed = &srcSetSpeed,
        }, .{
            .restart_button = true,
            .speed_dropdown = true,
            .seek_throttle_ms = SEEK_THROTTLE_MS,
            .seek_guard_us = SEEK_GUARD_US,
        });
        errdefer playbar.destroy();

        self.* = .{
            .allocator = allocator,
            .terminal = terminal,
            .surface = undefined,
            .config = Config.load(allocator),
            .callbacks = callbacks,
            .playbar = playbar,
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
        terminal.on_image_animation = onImageAnimationEvent;
        terminal.on_glyph_coverage = onGlyphCoverage;
        terminal.on_title = onTitleEvent;
        terminal.on_play_state = onPlayState;

        self.emitTitle(terminal.screen.last_title orelse std.fs.path.basename(loc.path));
        // Snapshot-restored image placements (a cast that finished
        // before we attached) replay into the freshly wired sink.
        terminal.replayRetainedImages();
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
        return self.playbar.widget();
    }

    /// Fence everything that can fire into widgets or this struct
    /// between widget teardown and destroy(). Idempotent.
    pub fn severLive(self: *CastPlayerBox) void {
        if (self.severed) return;
        self.severed = true;
        self.playbar.sever();
        self.surface.stopVisualSources();
        self.terminal.clearSinks();
    }

    /// Free the box and kill the ephemeral session (Terminal.deinit
    /// sends the kill). The widgets must already be dead.
    pub fn destroy(self: *CastPlayerBox) void {
        self.severLive();
        self.playbar.destroy();
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

    fn onImageAnimationEvent(ctx: ?*anyopaque) void {
        const self = cast.userData(CastPlayerBox, ctx);
        self.surface.imageAnimationChanged();
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

        // The command this state confirms is no longer outstanding;
        // an unrelated push (a throttled position, or the state of an
        // EARLIER command) leaves the expectation standing.
        if (self.expected_kind) |k| {
            if (st.kind == k) self.expected_kind = null;
        }

        // Markers first: a state push that brings duration + markers
        // together must have the stored set before the bar's
        // duration-change redraw runs.
        if (st.markers.len != self.playbar.markerCount()) {
            if (self.allocator.alloc(u64, st.markers.len)) |ms| {
                defer self.allocator.free(ms);
                for (st.markers, ms) |m, *slot| slot.* = m.ms;
                self.playbar.setMarkers(ms);
            } else |_| {}
        }

        self.playbar.setState(.{
            .kind = switch (st.kind) {
                .playing => .playing,
                .paused => .paused,
                .seeking => .seeking,
                .finished => .finished,
            },
            .position_ms = st.position_ms,
            .duration_ms = st.duration_ms,
        });

        if (self.callbacks.on_state) |cb| cb(self.callbacks.ctx, st);
    }

    // ── transport controls ───────────────────────────────────────

    fn playKind(self: *CastPlayerBox) Terminal.PlayState.Kind {
        // A command we already sent outranks the last state the daemon
        // pushed until that command is confirmed: two Space presses a
        // few ms apart both reach the key handler before the first
        // one's play_state has been read off the socket, and a toggle
        // computed from the stale state would send `pause` twice
        // instead of pause/resume.
        if (self.expected_kind) |k| {
            if (c.g_get_monotonic_time() - self.expected_us < EXPECT_TRUST_US) return k;
            self.expected_kind = null;
        }
        // Sessions auto-play on first attach, so "no state yet" reads
        // as playing.
        const st = self.terminal.last_play_state orelse return .playing;
        return st.kind;
    }

    /// Remember what the last transport command asked for, so the next
    /// toggle reverses it even if the daemon's confirming push has not
    /// been read off the socket yet.
    fn expect(self: *CastPlayerBox, kind: Terminal.PlayState.Kind) void {
        self.expected_kind = kind;
        self.expected_us = c.g_get_monotonic_time();
    }

    pub fn togglePlay(self: *CastPlayerBox) void {
        switch (self.playKind()) {
            .playing, .seeking => {
                self.expect(.paused);
                self.terminal.sendPlayControl(.pause, 0, 0);
            },
            .paused => {
                self.expect(.playing);
                self.terminal.sendPlayControl(.play, 0, 0);
            },
            .finished => {
                self.expect(.playing);
                self.terminal.sendPlayControl(.restart, 0, 0);
            },
        }
    }

    pub fn restart(self: *CastPlayerBox) void {
        self.expect(.playing);
        self.terminal.sendPlayControl(.restart, 0, 0);
    }

    /// Keyboard seeks route through the playbar so its guard timestamp
    /// keeps stale throttled play_state pushes off the thumb.
    pub fn seekRelative(self: *CastPlayerBox, delta_ms: i64) void {
        self.playbar.seekRelative(delta_ms);
    }

    // ── playbar source vtable ────────────────────────────────────

    fn srcToggle(ctx: ?*anyopaque) void {
        const self = cast.userData(CastPlayerBox, ctx);
        self.togglePlay();
    }

    fn srcRestart(ctx: ?*anyopaque) void {
        const self = cast.userData(CastPlayerBox, ctx);
        self.restart();
    }

    fn srcSeekToMs(ctx: ?*anyopaque, target_ms: u64) void {
        const self = cast.userData(CastPlayerBox, ctx);
        self.terminal.sendPlayControl(.seek, target_ms, 0);
    }

    fn srcSetSpeed(ctx: ?*anyopaque, speed: f64) void {
        const self = cast.userData(CastPlayerBox, ctx);
        self.terminal.sendPlayControl(.speed, 0, speed);
    }
};
