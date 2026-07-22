//! Headless driver for forwarded Wayland apps: a proto-v5 mux client
//! that spawns app sessions, keeps passive replica compositors per
//! channel (windows render into memory, nothing on any display),
//! captures PNG screenshots, and injects seat input as intent units.
//! GTK-free — usable from `sketerm mcp` without a GUI anywhere.

const std = @import("std");
const c = @import("../c.zig").c;
const muxclient = @import("../mux/client.zig");
const wire = @import("../mux/wire.zig");
const snapshot = @import("../mux/snapshot.zig");
const Screen = @import("../grid/screen.zig").Screen;
const Pool = @import("../grid/style_pool.zig").Pool;
const wlpipe = @import("../wlhost/pipe.zig");
const wlcomp = @import("../wlhost/compositor.zig");
const png = @import("../util/png.zig");
const marks_mod = @import("../util/marks.zig");
const gifrec = @import("../util/gifrec.zig");
const videorec = @import("../util/videorec.zig");
const evkeys = @import("evkeys.zig");
const xkblayout = @import("xkblayout.zig");
const keymaps = @import("../wlhost/keymaps.zig");

fn nowMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.tv_sec) * 1000 + @divTrunc(ts.tv_nsec, 1_000_000);
}

pub const Error = error{
    SpawnFailed,
    NotConnected,
    NoSuchWindow,
    BadKey,
    BadLayout,
    Timeout,
    NoClipboard,
    NotRecording,
    OutOfMemory,
};

/// WHY the last `App.launch`/`attachExisting` failed, human-readable
/// (the daemon's own error message when there was one). Error enums
/// can't carry strings; MCP serves one assistant sequentially, so a
/// module-level slot is safe.
var launch_err_buf: [256]u8 = undefined;
var launch_err_len: usize = 0;

pub fn lastLaunchErr() []const u8 {
    return launch_err_buf[0..launch_err_len];
}

fn setLaunchErr(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(&launch_err_buf, fmt, args) catch {
        launch_err_len = 0;
        return;
    };
    launch_err_len = s.len;
}

/// Describe a handshake-step failure, folding in the daemon's `.err`
/// message and any half-arrived frame ("2.1 MB of 8.3 MB buffered").
fn setStepErr(step: []const u8, conn: *muxclient.Conn, err: anyerror) void {
    if (err == error.DaemonError) {
        setLaunchErr("{s}: {s}", .{ step, conn.lastErr() });
        return;
    }
    if (err == error.Timeout) {
        if (conn.pendingPartial()) |p| {
            setLaunchErr("{s}: timed out mid-frame ({d} of {d} bytes buffered)", .{ step, p.have, p.expected });
        } else {
            setLaunchErr("{s}: timed out waiting for the daemon's reply", .{step});
        }
        return;
    }
    setLaunchErr("{s}: {s}", .{ step, @errorName(err) });
}

/// Query the daemon host's installed GUI apps (name + exec) without
/// spawning anything. `host` null = local autostart daemon. Returns a
/// JSON array string (arena-owned via the passed allocator's arena
/// semantics: caller frees with allocator.free).
pub fn listInstalledApps(allocator: std.mem.Allocator, host: ?[]const u8, local_sock: ?[]const u8) Error![]u8 {
    var conn = blk: {
        if (host) |h| break :blk muxclient.Conn.connectSsh(allocator, h) catch return Error.SpawnFailed;
        break :blk muxclient.Conn.connectLocalAutostartAt(allocator, local_sock) catch return Error.SpawnFailed;
    };
    defer conn.deinit();
    conn.setNonBlocking();
    conn.sendJson(.hello, .{ .proto = wire.PROTO_VERSION }) catch return Error.NotConnected;
    (conn.recvExpectFor(&.{.welcome}, 10_000) catch return Error.NotConnected).deinit(allocator);
    // app_list needs no session attach — the daemon scans its own host.
    conn.sendFrame(.app_list, "") catch return Error.NotConnected;
    const f = conn.recvExpectFor(&.{.app_listing}, 10_000) catch return Error.Timeout;
    defer f.deinit(allocator);
    return allocator.dupe(u8, f.payload) catch return Error.OutOfMemory;
}

/// One live app session in a daemon's `list` reply.
pub const AppSessionRef = struct {
    name: []u8,
    /// Session child pid on the daemon's host (0 = unknown).
    pid: i32 = 0,
};

/// Live app sessions on the daemon at `sock`, WITHOUT autostarting one
/// (no daemon = empty). Caller frees each `.name` and the slice.
pub fn listAppSessions(allocator: std.mem.Allocator, sock: []const u8) Error![]AppSessionRef {
    var conn = muxclient.Conn.connect(allocator, sock) catch return Error.SpawnFailed;
    defer conn.deinit();
    conn.setNonBlocking();
    conn.sendJson(.hello, .{ .proto = wire.PROTO_VERSION }) catch return Error.NotConnected;
    (conn.recvExpectFor(&.{.welcome}, 10_000) catch return Error.NotConnected).deinit(allocator);
    conn.sendFrame(.list, "") catch return Error.NotConnected;
    const f = conn.recvExpectFor(&.{.welcome}, 10_000) catch return Error.Timeout;
    defer f.deinit(allocator);

    const Listing = struct {
        sessions: []const struct {
            name: []const u8,
            app: bool = false,
            exited: bool = false,
            pid: i32 = 0,
        } = &.{},
    };
    const parsed = std.json.parseFromSlice(Listing, allocator, f.payload, .{
        .ignore_unknown_fields = true,
    }) catch return Error.NotConnected;
    defer parsed.deinit();

    var refs: std.ArrayList(AppSessionRef) = .empty;
    errdefer {
        for (refs.items) |r| allocator.free(r.name);
        refs.deinit(allocator);
    }
    for (parsed.value.sessions) |s| {
        if (!s.app or s.exited) continue;
        const n = allocator.dupe(u8, s.name) catch return Error.OutOfMemory;
        refs.append(allocator, .{ .name = n, .pid = s.pid }) catch {
            allocator.free(n);
            return Error.OutOfMemory;
        };
    }
    return refs.toOwnedSlice(allocator) catch Error.OutOfMemory;
}

/// One rendered toplevel (or popup) surface of one app channel.
pub const Window = struct {
    /// Stable public id (MCP-facing), unique within the App.
    id: u32,
    chan: u32,
    sid: u32,
    w: i32 = 0,
    h: i32 = 0,
    scale: i32 = 1,
    format: u32 = 0,
    /// Latest committed pixels, tightly packed w*4 (wl_shm layout).
    pixels: std.ArrayList(u8) = .empty,
    title: ?[]u8 = null,
    app_id: ?[]u8 = null,
    popup: bool = false,
    frames: u64 = 0,
    /// Monotonic ms of the last committed frame — ranks the "primary
    /// content" window (a game's render surface keeps painting while
    /// its frame window sits static).
    last_commit_ms: i64 = 0,
    /// `frames` at the last screenshot of this window — lets a
    /// wait-for-change screenshot block until content actually differs
    /// from what the caller last saw.
    shot_frames: u64 = 0,
    /// Pixel copy taken at the last screenshot / stats observation:
    /// the diff baseline for stats_only and burst min-change gating.
    shot_pixels: std.ArrayList(u8) = .empty,
    shot_w: i32 = 0,
    shot_h: i32 = 0,
    /// Cleared for the channel's windows when a resync replay starts
    /// (repeated chan_open) and set again by any replica callback that
    /// touches the window — windows the replay never re-announces are
    /// pruned when `native_sync` closes it (they died during the gap).
    resync_seen: bool = true,

    fn deinit(self: *Window, a: std.mem.Allocator) void {
        self.pixels.deinit(a);
        self.shot_pixels.deinit(a);
        if (self.title) |s| a.free(s);
        if (self.app_id) |s| a.free(s);
    }

    /// Record the current committed pixels as the observation baseline
    /// (what the caller "last saw"). Best-effort: OOM just leaves the
    /// previous baseline, which only skews a later diff percentage.
    fn rememberShot(self: *Window, a: std.mem.Allocator) void {
        self.shot_frames = self.frames;
        self.shot_pixels.clearRetainingCapacity();
        self.shot_pixels.appendSlice(a, self.pixels.items) catch return;
        self.shot_w = self.w;
        self.shot_h = self.h;
    }

    /// Fraction (0..100) of pixels differing from the baseline; 100
    /// when the window was resized or no baseline exists yet.
    fn pctVsBaseline(self: *const Window) f64 {
        if (self.shot_w != self.w or self.shot_h != self.h) return 100.0;
        return pctDiffBuf(self.pixels.items, self.shot_pixels.items);
    }
};

/// Fraction (0..100) of 4-byte pixels differing between two equally
/// sized buffers; 100 on a length mismatch.
fn pctDiffBuf(cur: []const u8, base: []const u8) f64 {
    const n = cur.len;
    if (base.len != n or n < 4) return 100.0;
    var diff: usize = 0;
    var i: usize = 0;
    while (i + 4 <= n) : (i += 4) {
        if (!std.mem.eql(u8, cur[i..][0..4], base[i..][0..4])) diff += 1;
    }
    return @as(f64, @floatFromInt(diff)) * 100.0 / @as(f64, @floatFromInt(n / 4));
}

/// One wayland_native channel = one app display connection, with its
/// own replica compositor.
const Chan = struct {
    app: *App,
    id: u32,
    comp: wlcomp.Compositor,
    /// Child surfaces are composited into their parent and must never
    /// become independently selectable headless "windows". JBR uses
    /// one such surface for every drop shadow.
    subsurfaces: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// A daemon resync replay is rebuilding this channel's replica
    /// (repeated chan_open); cleared when `native_sync` lands.
    resyncing: bool = false,

    fn deinit(self: *Chan) void {
        self.subsurfaces.deinit(self.app.allocator);
        self.comp.deinit();
    }
};

var name_counter: u32 = 0;
/// Monotonic per-process log_get nonce (uniqueness within one
/// connection is all reply matching needs).
var log_nonce_counter: u64 = 0;

pub const App = struct {
    allocator: std.mem.Allocator,
    conn: muxclient.Conn,
    name: []u8,
    chans: std.AutoArrayHashMapUnmanaged(u32, *Chan) = .empty,
    /// Audio channels (tracked to discard stray data). Headless: we
    /// never subscribe, so the daemon's real-time self-clock paces
    /// the app's playback (samples discarded on schedule).
    audio_ids: std.AutoHashMapUnmanaged(u32, void) = .empty,
    windows: std.ArrayList(*Window) = .empty,
    next_win_id: u32 = 1,
    /// Bumped on every committed frame — the quiescence signal.
    frame_seq: u64 = 0,
    /// The daemon paused app-frame streaming toward us (native_gap):
    /// replica pixels are known-stale until the post-drain replay's
    /// native_sync lands. drainLive() waits this out.
    behind: bool = false,
    /// The last drainLive() hit its deadline without reaching the
    /// live head — replica pixels may lag until a later drain
    /// completes. Captions surface this so a capture never silently
    /// pretends to be current.
    lagging: bool = false,
    exited: bool = false,
    exit_status: i32 = 0,
    /// Session child pid ON THE DAEMON'S HOST (0 = unknown). A string
    /// command spawns via `/bin/sh -c`, so this is the shell; argv-array
    /// launches exec directly and the pid IS the app.
    pid: i32 = 0,
    /// Toplevel the keyboard was last aimed at (0 = none yet).
    kbd_focus: u32 = 0, // public window id
    /// Tracked pointer: last surface-local position injected on the
    /// seat (matches the compositor's relative_motion delta base;
    /// enter on an unchanged focus does NOT reset it). ptr_win 0 =
    /// no motion injected yet.
    ptr_win: u32 = 0,
    ptr_x: f64 = 0,
    ptr_y: f64 = 0,
    /// Latest clipboard selection the app announced (copy source).
    clip_offer: ?ClipOffer = null,
    /// Fetched app-clipboard bytes (answer to a clip_send).
    clip_buf: std.ArrayList(u8) = .empty,
    clip_got: bool = false,
    /// Text we offered as the host clipboard; served on app paste.
    paste_data: ?[]u8 = null,
    /// Parsed session keymap for layout-aware typing (null = the
    /// builtin us tables in evkeys.zig).
    layout: ?xkblayout.Layout = null,
    /// Active recording of one window's frames (app_record_*): GIF or
    /// WebM/VP9. At most one is set at a time.
    rec: ?gifrec.Rec = null,
    vrec: ?videorec.Rec = null,
    rec_win: u32 = 0,
    /// Recording rate cap (`fps` on app_record_start): commits closer
    /// together than this are not fed to the encoder. 0 = every frame.
    rec_min_interval_ms: i64 = 0,
    rec_last_add: i64 = 0,
    /// Client-side Screen mirror of the app session's PTY (the app's
    /// stdout/stderr as a rendered terminal — the "held log tab"),
    /// built from the attach snapshot + the event stream, exactly like
    /// termdrive.Term. This is what `output()` reads.
    term_pool: ?*Pool = null,
    term_screen: ?*Screen = null,
    term_seq: u64 = 0,
    /// Connect target, kept for side connections (logGetFresh): the
    /// private-instance socket path and/or SSH host used at launch.
    local_sock: ?[]u8 = null,
    ssh_host: ?[]u8 = null,
    /// Latest `.log_data` payload (a logGet reply, or the daemon's
    /// unsolicited post-mortem push just before `.exit`).
    log_buf: std.ArrayList(u8) = .empty,
    /// Bumped per received `.log_data` — logGet waits on this.
    log_seq: u64 = 0,
    /// Screenshots stashed when the app emitted the OSC 5522 marker
    /// escape: "the window at that instant", keyed by the marker's
    /// log-line id. Bounded ring, oldest dropped.
    markers: std.ArrayList(MarkerShot) = .empty,

    /// `OSC 5522;+N;label` markers waiting for the primary window's
    /// Nth future commit before stashing.
    pending_markers: std.ArrayList(PendingMarker) = .empty,
    /// Window id + frame counter at the last stash encode — a marker
    /// burst against an unchanged frame reuses the previous PNG
    /// instead of paying another encode.
    last_stash_win: u32 = 0,
    last_stash_frames: u64 = 0,

    pub const MarkerShot = struct {
        id: u64,
        label: []u8,
        /// Full-window PNG at marker time. Null when no window had
        /// rendered — or when `same_as` points at the marker whose
        /// screenshot this one shares (no commit in between, so the
        /// pixels are identical; storing a copy would only burn RAM
        /// and image slots).
        png: ?[]u8,
        same_as: u64 = 0,
    };
    /// Cap on stored IMAGES (png-bearing entries). Shared/imageless
    /// entries are near-free and capped separately, so a same-instant
    /// marker burst cannot evict earlier real screenshots.
    const MAX_MARKER_SHOTS = 8;
    const MAX_MARKER_ENTRIES = 40;
    const PendingMarker = struct { id: u64, label: []u8, remaining: u32 };
    const MAX_PENDING_MARKERS = 32;

    const ClipOffer = struct { chan: u32, source: u32, mime: []u8 };

    /// Optional launch parameters (`launch_app` schema mirrors this).
    pub const LaunchOpts = struct {
        cols: u16 = 80,
        rows: u16 = 24,
        host: ?[]const u8 = null,
        kb_layout: ?[]const u8 = null,
        local_sock: ?[]const u8 = null,
        gpu: bool = false,
        /// Skip the session's PulseAudio hub: PULSE_SERVER stays
        /// unset and the app falls back to its own dummy driver.
        no_audio: bool = false,
        /// WAV-capture path base on the DAEMON's host: the sink tees
        /// every stream's PCM to "<base>.wav" / "<base>-N.wav" while
        /// pacing normally. null = no capture.
        audio_capture: ?[]const u8 = null,
        cwd: ?[]const u8 = null,
        /// "KEY=VALUE" strings for the child environment.
        env: []const []const u8 = &.{},
        /// Per-step handshake deadline; a stalled daemon surfaces as a
        /// described SpawnFailed instead of a hung tool call.
        step_timeout_ms: i64 = 15_000,
    };

    /// Spawn an app session on the local (autostart) daemon, or on
    /// `host` over SSH, and attach as a proto-v5 viewer. `kb_layout`
    /// picks the session keymap (wlhost/keymaps.zig; null/"" = us) —
    /// typing is encoded against the same blob. `local_sock` targets a
    /// private daemon instance (MCP isolation); null = shared daemon.
    /// `gpu` = per-session dmabuf opt-in (real GL driver on the host).
    pub fn launch(
        allocator: std.mem.Allocator,
        argv: []const []const u8,
        opts: LaunchOpts,
    ) Error!*App {
        launch_err_len = 0;
        const layout_name = opts.kb_layout orelse "";
        const blob = keymaps.get(layout_name) orelse return Error.BadLayout;
        var layout: ?xkblayout.Layout = xkblayout.parse(allocator, blob) catch null;
        errdefer if (layout) |*l| l.deinit(allocator);
        var conn = blk: {
            if (opts.host) |h| break :blk muxclient.Conn.connectSsh(allocator, h) catch |err| {
                setLaunchErr("ssh connect to {s}: {s}", .{ h, @errorName(err) });
                return Error.SpawnFailed;
            };
            break :blk muxclient.Conn.connectLocalAutostartAt(allocator, opts.local_sock) catch |err| {
                setLaunchErr("daemon connect: {s}", .{@errorName(err)});
                return Error.SpawnFailed;
            };
        };
        errdefer conn.deinit();
        // Non-blocking: sendFrame then bounds a full-buffer write with
        // its EAGAIN+poll path — a wedged daemon can no longer park an
        // intent/screenshot/log request in write() forever.
        conn.setNonBlocking();

        conn.sendJson(.hello, .{ .proto = wire.PROTO_VERSION }) catch return Error.SpawnFailed;
        (conn.recvExpectFor(&.{.welcome}, opts.step_timeout_ms) catch |err| {
            setStepErr("hello handshake", &conn, err);
            return Error.SpawnFailed;
        }).deinit(allocator);

        name_counter += 1;
        const name = std.fmt.allocPrint(allocator, "mcpapp-{d}-{d}", .{ c.getpid(), name_counter }) catch
            return Error.OutOfMemory;
        errdefer allocator.free(name);

        conn.sendJson(.spawn, .{
            .name = name,
            .argv = argv,
            .rows = opts.rows,
            .cols = opts.cols,
            .app = true,
            .kb_layout = layout_name,
            .gpu = opts.gpu,
            .no_audio = opts.no_audio,
            .audio_capture = opts.audio_capture orelse "",
            .cwd = opts.cwd,
            .env = opts.env,
        }) catch return Error.SpawnFailed;
        var spawn_pid: i32 = 0;
        {
            const ok = conn.recvExpectFor(&.{.ok}, opts.step_timeout_ms) catch |err| {
                setStepErr("spawn", &conn, err);
                return Error.SpawnFailed;
            };
            defer ok.deinit(allocator);
            const OkReply = struct { pid: i32 = 0 };
            if (std.json.parseFromSlice(OkReply, allocator, ok.payload, .{
                .ignore_unknown_fields = true,
            })) |p| {
                spawn_pid = p.value.pid;
                p.deinit();
            } else |_| {}
        }
        conn.sendJson(.attach, .{ .name = name, .kind = "mcp" }) catch return Error.SpawnFailed;
        const snap = conn.recvExpectFor(&.{.snapshot}, opts.step_timeout_ms) catch |err| {
            setStepErr("attach", &conn, err);
            return Error.SpawnFailed;
        };
        defer snap.deinit(allocator);

        const self = allocator.create(App) catch return Error.OutOfMemory;
        self.* = .{
            .allocator = allocator,
            .conn = conn,
            .name = name,
            .layout = layout,
            .pid = spawn_pid,
            .local_sock = if (opts.host == null) (if (opts.local_sock) |p| allocator.dupe(u8, p) catch null else null) else null,
            .ssh_host = if (opts.host) |h| allocator.dupe(u8, h) catch null else null,
        };
        layout = null; // ownership moved
        self.applyTermSnapshot(snap.payload);
        return self;
    }

    /// Attach to an EXISTING app session (named-instance reconnect).
    /// Same wire flow as `launch` minus the spawn — the daemon replays
    /// pool bytes + state_sync, so windows rebuild with pixels. The
    /// session's keymap isn't recoverable from the wire; `kb_layout`
    /// should repeat the launch-time value (null = us).
    pub fn attachExisting(
        allocator: std.mem.Allocator,
        session_name: []const u8,
        kb_layout: ?[]const u8,
        local_sock: ?[]const u8,
    ) Error!*App {
        launch_err_len = 0;
        const layout_name = kb_layout orelse "";
        const blob = keymaps.get(layout_name) orelse return Error.BadLayout;
        var layout: ?xkblayout.Layout = xkblayout.parse(allocator, blob) catch null;
        errdefer if (layout) |*l| l.deinit(allocator);
        var conn = muxclient.Conn.connectLocalAutostartAt(allocator, local_sock) catch |err| {
            setLaunchErr("daemon connect: {s}", .{@errorName(err)});
            return Error.SpawnFailed;
        };
        errdefer conn.deinit();
        conn.setNonBlocking();

        conn.sendJson(.hello, .{ .proto = wire.PROTO_VERSION }) catch return Error.SpawnFailed;
        (conn.recvExpectFor(&.{.welcome}, 15_000) catch |err| {
            setStepErr("hello handshake", &conn, err);
            return Error.SpawnFailed;
        }).deinit(allocator);

        const name = allocator.dupe(u8, session_name) catch return Error.OutOfMemory;
        errdefer allocator.free(name);
        conn.sendJson(.attach, .{ .name = name, .kind = "mcp" }) catch return Error.SpawnFailed;
        const snap = conn.recvExpectFor(&.{.snapshot}, 15_000) catch |err| {
            setStepErr("attach", &conn, err);
            return Error.SpawnFailed;
        };
        defer snap.deinit(allocator);

        const self = allocator.create(App) catch return Error.OutOfMemory;
        self.* = .{
            .allocator = allocator,
            .conn = conn,
            .name = name,
            .layout = layout,
            .local_sock = if (local_sock) |p| allocator.dupe(u8, p) catch null else null,
        };
        layout = null; // ownership moved
        self.applyTermSnapshot(snap.payload);
        return self;
    }

    /// Free the client-side state WITHOUT killing the session — a
    /// durable instance's apps outlive the MCP process.
    pub fn detach(self: *App) void {
        self.exited = true; // suppress deinit's kill frame
        self.deinit();
    }

    /// Kill the session (the app dies with it) and free everything.
    pub fn deinit(self: *App) void {
        const a = self.allocator;
        if (!self.exited) {
            self.conn.sendJson(.kill, .{ .name = self.name }) catch {};
        }
        self.conn.deinit();
        for (self.chans.values()) |ch| {
            ch.deinit();
            a.destroy(ch);
        }
        self.chans.deinit(a);
        self.audio_ids.deinit(a);
        for (self.windows.items) |w| {
            w.deinit(a);
            a.destroy(w);
        }
        self.windows.deinit(a);
        if (self.clip_offer) |o| a.free(o.mime);
        self.clip_buf.deinit(a);
        self.log_buf.deinit(a);
        for (self.markers.items) |m| {
            a.free(m.label);
            if (m.png) |p| a.free(p);
        }
        self.markers.deinit(a);
        for (self.pending_markers.items) |pm| a.free(pm.label);
        self.pending_markers.deinit(a);
        if (self.paste_data) |p| a.free(p);
        if (self.layout) |*l| l.deinit(a);
        if (self.rec) |*r| r.abort();
        if (self.vrec) |*r| r.abort();
        if (self.term_screen) |s| s.deinit();
        if (self.term_pool) |p| {
            p.deinit();
            a.destroy(p);
        }
        if (self.local_sock) |p| a.free(p);
        if (self.ssh_host) |h| a.free(h);
        a.free(self.name);
        a.destroy(self);
    }

    /// Rebuild the terminal mirror from an attach snapshot
    /// ([seq:u64][app:u8] + serialized Screen). Best-effort: a decode
    /// failure just leaves the mirror empty (output unavailable).
    fn applyTermSnapshot(self: *App, payload: []const u8) void {
        if (payload.len < 9) return;
        const a = self.allocator;
        self.term_seq = std.mem.readInt(u64, payload[0..8], .little);
        if (self.term_screen) |s| s.deinit();
        self.term_screen = null;
        if (self.term_pool == null) {
            const p = a.create(Pool) catch return;
            p.* = Pool.init(a) catch {
                a.destroy(p);
                return;
            };
            self.term_pool = p;
        } else {
            self.term_pool.?.deinit();
            self.term_pool.?.* = Pool.init(a) catch {
                a.destroy(self.term_pool.?);
                self.term_pool = null;
                return;
            };
        }
        self.term_screen = snapshot.restore(a, self.term_pool.?, payload[9..]) catch null;
    }

    /// Apply an `.events` frame ([seq:u64][count:u32] + wire events)
    /// to the terminal mirror.
    fn applyTermEvents(self: *App, payload: []const u8) void {
        if (payload.len < 12) return;
        const base = std.mem.readInt(u64, payload[0..8], .little);
        const n = std.mem.readInt(u32, payload[8..12], .little);
        const screen = self.term_screen orelse return;
        var r = wire.Reader.init(payload[12..]);
        while (!r.atEnd()) {
            var ev = r.getEvent(self.allocator) catch break;
            screen.apply(ev);
            ev.deinit(self.allocator);
        }
        self.term_seq = base + n;
    }

    /// The app's PTY output (stdout+stderr as rendered by the
    /// terminal). `scrollback` includes history above the grid.
    /// Caller owns the bytes.
    pub fn output(self: *App, scrollback: bool) Error![]u8 {
        self.drain();
        const screen = self.term_screen orelse return Error.NotConnected;
        return (if (scrollback)
            screen.extractScrollback(self.allocator)
        else
            screen.extractScreen(self.allocator)) catch Error.OutOfMemory;
    }

    // ── stream pumping ──────────────────────────────────────────

    fn pollIn(fd: c_int, ms: i32) bool {
        var pfd = c.struct_pollfd{ .fd = fd, .events = c.POLLIN, .revents = 0 };
        const r = c.poll(&pfd, 1, ms);
        return r > 0 and (pfd.revents & (c.POLLIN | c.POLLHUP)) != 0;
    }

    /// Process at most one incoming frame, waiting up to `wait_ms`.
    /// Returns false when nothing COMPLETE arrived in time (or after exit).
    ///
    /// This must never block past `wait_ms`, which is why it does not call
    /// recvFrame: recvFrame read()s until it has a whole frame, and a big frame (an
    /// 8 MB window buffer) arrives in many chunks. A readable fd therefore does NOT
    /// mean a whole frame is there, and waiting for the tail of one that has not
    /// been sent yet hangs the caller. Partial bytes simply stay in the buffer and
    /// are peeled once the rest lands.
    pub fn pumpOnce(self: *App, wait_ms: i32) bool {
        if (self.exited) return false;

        // Attach-time recvExpect may have buffered frames PAST the
        // snapshot into conn.rbuf (a small dmabuf replay fits in one
        // read); those never make the fd readable again — drain the
        // buffer before polling for new bytes.
        if (self.takeOne()) return true;

        if (!pollIn(self.conn.fd, wait_ms)) return false;
        if (!self.conn.fillAvailable()) {
            self.exited = true;
            return false;
        }
        return self.takeOne();
    }

    /// Handle one complete buffered frame, if there is one.
    fn takeOne(self: *App) bool {
        const f = (self.conn.takeFrame() catch {
            self.exited = true;
            return false;
        }) orelse return false;
        defer f.deinit(self.allocator);
        self.handleFrame(f.ftype, f.payload);
        return true;
    }

    /// A resync replay finished (native_sync): windows the replay
    /// never re-announced died during the withheld gap — prune them
    /// (their surfaces no longer exist, no toplevel_gone will come).
    fn finishResync(self: *App) void {
        var any = false;
        var cit = self.chans.iterator();
        while (cit.next()) |e| {
            if (e.value_ptr.*.resyncing) any = true;
            e.value_ptr.*.resyncing = false;
        }
        if (!any) return;
        var i: usize = 0;
        while (i < self.windows.items.len) {
            const w = self.windows.items[i];
            if (!w.resync_seen) {
                _ = self.windows.swapRemove(i);
                w.deinit(self.allocator);
                self.allocator.destroy(w);
                continue;
            }
            i += 1;
        }
    }

    /// Drain to the LIVE head, bounded by `max_ms`: unlike drain()
    /// (a 100ms box that may only chew part of a backlog), this keeps
    /// pumping until nothing is queued AND no daemon-side resync is
    /// pending (`behind`) — so captures and input baselines reflect
    /// "now", not a screensful-old frame. Terminates on quiet apps
    /// immediately; on continuously-committing apps it is within one
    /// commit of live when the socket goes momentarily quiet.
    /// Returns true when the live head was reached (the socket went
    /// quiet with no pending daemon-side resync); false = deadline hit
    /// while still consuming — `lagging` is set so captures can say so.
    pub fn drainLive(self: *App, max_ms: i64) bool {
        const deadline = nowMs() + max_ms;
        while (!self.exited and nowMs() < deadline) {
            if (self.pumpOnce(0)) continue;
            if (!self.behind) {
                self.lagging = false;
                return true;
            }
            // Backlog consumed but the post-drain replay hasn't landed
            // yet — the daemon queues it the moment its queue empties.
            _ = self.pumpOnce(20);
        }
        if (self.exited) {
            self.lagging = false;
            return true; // final state is by definition current
        }
        self.lagging = true;
        return false;
    }

    /// Drain whatever is queued without blocking — TIME-BOXED. A
    /// flooding app (debug spam on its PTY) produces `.events` frames
    /// at least as fast as we consume them, so an unbounded loop here
    /// never returns and one wedged tool call stalls every MCP request
    /// behind it. The daemon stops streaming events to a backlogged
    /// client and resyncs it with a fresh snapshot once it drains, so
    /// cutting out early loses nothing.
    pub fn drain(self: *App) void {
        const deadline = nowMs() + 100;
        while (self.pumpOnce(0)) {
            if (nowMs() >= deadline) break;
        }
    }

    fn handleFrame(self: *App, ftype: wire.FrameType, payload: []const u8) void {
        switch (ftype) {
            .chan_open => {
                const open = wire.decodeChanOpen(payload) orelse return;
                if (open.kind == .audio) {
                    // Deliberately NOT subscribed: we can't play PCM,
                    // and consuming it here would out-clock the
                    // daemon's real-time sink pacing (mux/pulse.zig
                    // self-clock) — the exact accept-everything-
                    // instantly black hole that hung apps gating
                    // logic on audio progress. Unsubscribed, no PCM
                    // is shipped and the daemon paces the app itself.
                    self.audio_ids.put(self.allocator, open.id, {}) catch {};
                    return;
                }
                if (open.kind != .wayland_native) return;
                if (self.chans.get(open.id)) |existing| {
                    // Daemon resync replay for a channel we already
                    // hold: rebuild the replica IN PLACE. The Window
                    // objects survive (ensureWindow dedupes by
                    // chan+sid), so public window ids stay stable
                    // across the resync; windows the replay never
                    // re-announces are pruned at native_sync.
                    existing.comp.deinit();
                    existing.subsurfaces.clearRetainingCapacity();
                    existing.comp = self.makeReplica(existing) catch {
                        // Replica unusable — drop the channel wholesale.
                        _ = self.chans.swapRemove(open.id);
                        self.dropChanWindows(open.id);
                        existing.subsurfaces.deinit(self.allocator);
                        self.allocator.destroy(existing);
                        return;
                    };
                    existing.resyncing = true;
                    for (self.windows.items) |w| {
                        if (w.chan == open.id) w.resync_seen = false;
                    }
                    return;
                }
                const ch = self.allocator.create(Chan) catch return;
                ch.* = .{ .app = self, .id = open.id, .comp = undefined };
                ch.comp = self.makeReplica(ch) catch {
                    self.allocator.destroy(ch);
                    return;
                };
                self.chans.put(self.allocator, open.id, ch) catch {
                    ch.deinit();
                    self.allocator.destroy(ch);
                };
            },
            .chan_close => {
                const id = wire.decodeChanId(payload) orelse return;
                if (self.chans.fetchSwapRemove(id)) |kv| {
                    self.dropChanWindows(id);
                    kv.value.deinit();
                    self.allocator.destroy(kv.value);
                }
            },
            .chan_data => {
                const id = wire.decodeChanId(payload) orelse return;
                if (self.audio_ids.contains(id)) return; // unsubscribed: ignore strays
                const ch = self.chans.get(id) orelse return;
                ch.comp.feed(payload[4..]) catch |err| {
                    std.debug.print("appdrive: replica feed error: {s}\n", .{@errorName(err)});
                };
                ch.comp.clearOut(); // replica output is discarded
            },
            .snapshot => self.applyTermSnapshot(payload),
            .events => self.applyTermEvents(payload),
            .log_data => {
                self.log_buf.clearRetainingCapacity();
                self.log_buf.appendSlice(self.allocator, payload) catch return;
                self.log_seq += 1;
            },
            .marker => self.stashMarker(payload),
            .native_gap => self.behind = true,
            .native_sync => {
                self.behind = false;
                self.finishResync();
            },
            .exit => {
                self.exited = true;
                self.behind = false; // nothing more will stream
                if (payload.len >= 4) self.exit_status = std.mem.readInt(i32, payload[0..4], .little);
                self.resolvePendingMarkers();
            },
            else => {},
        }
    }

    /// The app emitted the OSC 5522 marker escape. `after` == 0:
    /// stash a screenshot of the primary window NOW; `after` > 0
    /// (the `+N` syntax): wait for that many future commits first.
    fn stashMarker(self: *App, payload: []const u8) void {
        const a = self.allocator;
        const P = struct { id: u64 = 0, label: []const u8 = "", after: u32 = 0 };
        const parsed = std.json.parseFromSlice(P, a, payload, .{
            .ignore_unknown_fields = true,
        }) catch return;
        defer parsed.deinit();
        if (parsed.value.id == 0) return;
        if (parsed.value.after > 0) {
            const label = a.dupe(u8, parsed.value.label) catch return;
            self.pending_markers.append(a, .{
                .id = parsed.value.id,
                .label = label,
                .remaining = parsed.value.after,
            }) catch {
                a.free(label);
                return;
            };
            while (self.pending_markers.items.len > MAX_PENDING_MARKERS) {
                // Resolve rather than lose: the oldest gets the
                // current frame instead of the one it waited for.
                const old = self.pending_markers.orderedRemove(0);
                self.doStash(old.id, old.label);
                a.free(old.label);
            }
            return;
        }
        self.doStash(parsed.value.id, parsed.value.label);
    }

    /// Stash a marker screenshot of the primary window as it is right
    /// now. Markers with NO commit since the previous stash share
    /// that screenshot by reference (`same_as`) — one stored image
    /// per committed frame, however many markers land on it.
    fn doStash(self: *App, id: u64, label: []const u8) void {
        const a = self.allocator;
        var shot_png: ?[]u8 = null;
        var same_as: u64 = 0;
        for (self.windows.items) |w| {
            if (w.popup or w.frames == 0) continue;
            if (self.last_stash_win == w.id and self.last_stash_frames == w.frames) {
                var i = self.markers.items.len;
                while (i > 0) {
                    i -= 1;
                    if (self.markers.items[i].png != null) {
                        same_as = self.markers.items[i].id;
                        break;
                    }
                }
            }
            if (same_as == 0) {
                if (self.encodeWindowPng(w, 1568, null, 1)) |shot| {
                    shot_png = shot.png;
                    self.last_stash_win = w.id;
                    self.last_stash_frames = w.frames;
                } else |_| {}
            }
            break;
        }
        const label_copy = a.dupe(u8, label) catch {
            if (shot_png) |p| a.free(p);
            return;
        };
        self.markers.append(a, .{ .id = id, .label = label_copy, .png = shot_png, .same_as = same_as }) catch {
            a.free(label_copy);
            if (shot_png) |p| a.free(p);
            return;
        };
        self.evictMarkers();
    }

    /// Enforce the marker caps: total entries, and png-bearing
    /// entries separately (images are the expensive part). Oldest go
    /// first; a shared entry whose source image was evicted degrades
    /// to the "aged out" message on fetch.
    fn evictMarkers(self: *App) void {
        const a = self.allocator;
        var png_count: usize = 0;
        for (self.markers.items) |m| {
            if (m.png != null) png_count += 1;
        }
        while (self.markers.items.len > MAX_MARKER_ENTRIES or png_count > MAX_MARKER_SHOTS) {
            const old = self.markers.orderedRemove(0);
            if (old.png != null) png_count -= 1;
            a.free(old.label);
            if (old.png) |p| a.free(p);
        }
    }

    /// Resolve a marker's image, following a shared-frame reference.
    /// `shared_from` != 0 names the marker whose screenshot is served.
    pub fn markerImage(self: *const App, id: u64) ?struct { png: []const u8, shared_from: u64 } {
        const m = self.markerShot(id) orelse return null;
        if (m.png) |p| return .{ .png = p, .shared_from = 0 };
        if (m.same_as != 0) {
            if (self.markerShot(m.same_as)) |src| {
                if (src.png) |p| return .{ .png = p, .shared_from = m.same_as };
            }
        }
        return null;
    }

    /// A frame just committed on `win`: advance `+N` markers when it
    /// is the primary toplevel, stashing those that reach zero.
    fn tickPendingMarkers(self: *App, win: *Window) void {
        if (self.pending_markers.items.len == 0) return;
        for (self.windows.items) |w| {
            if (w.popup or w.frames == 0) continue;
            if (w != win) return; // only the primary's commits count
            break;
        }
        var i: usize = 0;
        while (i < self.pending_markers.items.len) {
            const pm = &self.pending_markers.items[i];
            pm.remaining -= 1;
            if (pm.remaining == 0) {
                const done = self.pending_markers.orderedRemove(i);
                self.doStash(done.id, done.label);
                self.allocator.free(done.label);
                continue;
            }
            i += 1;
        }
    }

    /// The app is gone: `+N` markers that never saw their Nth commit
    /// resolve against the final frame (an id must never dangle).
    fn resolvePendingMarkers(self: *App) void {
        while (self.pending_markers.items.len > 0) {
            const pm = self.pending_markers.orderedRemove(0);
            self.doStash(pm.id, pm.label);
            self.allocator.free(pm.label);
        }
    }

    pub fn markerShot(self: *const App, id: u64) ?*const MarkerShot {
        for (self.markers.items) |*m| {
            if (m.id == id) return m;
        }
        return null;
    }

    pub const LogFetch = struct { json: []u8, stale: bool };

    /// Read the nonce a log_data reply echoes in its HEADER (before
    /// "lines" — line text is arbitrary app output and must not be
    /// scanned). null = no/zero nonce (old daemon or unsolicited push).
    pub fn logNonceOf(json: []const u8) ?u64 {
        const header = if (std.mem.indexOf(u8, json, "\"lines\"")) |i| json[0..i] else json;
        const key = "\"nonce\":";
        const at = std.mem.indexOf(u8, header, key) orelse return null;
        var end = at + key.len;
        while (end < header.len and header[end] >= '0' and header[end] <= '9') end += 1;
        const v = std.fmt.parseInt(u64, header[at + key.len .. end], 10) catch return null;
        return if (v == 0) null else v;
    }

    /// Fetch log lines from the daemon (`req_json` = a LogGetReq
    /// object). For an EXITED app the daemon already pushed the final
    /// log ahead of `.exit`; that stash is served instead (the session
    /// is gone daemon-side). When the fresh reply is still queued
    /// behind streamed frame data at the deadline, the LAST CACHED
    /// reply is served with `stale = true` — partial beats nothing.
    /// Caller owns the returned JSON.
    pub fn logGet(self: *App, req_json: []const u8, timeout_ms: i64) Error!LogFetch {
        self.drain();
        if (!self.exited) {
            // Nonce-stamped request: a reply to an EARLIER request can
            // surface from the frame backlog during this wait and must
            // not be mistaken for ours (a no-nonce reply — old daemon
            // or the unsolicited pre-exit push — is accepted as-is).
            log_nonce_counter += 1;
            const nonce = log_nonce_counter;
            std.debug.assert(req_json.len > 0 and req_json[req_json.len - 1] == '}');
            const req = std.fmt.allocPrint(self.allocator, "{s},\"nonce\":{d}}}", .{
                req_json[0 .. req_json.len - 1], nonce,
            }) catch return Error.OutOfMemory;
            defer self.allocator.free(req);
            var seen = self.log_seq;
            self.conn.sendFrame(.log_get, req) catch return Error.NotConnected;
            const deadline = nowMs() + timeout_ms;
            var matched = false;
            while (nowMs() < deadline) {
                if (self.log_seq != seen) {
                    seen = self.log_seq;
                    const got = logNonceOf(self.log_buf.items);
                    if (got == null or got.? == nonce) {
                        matched = true;
                        break;
                    }
                    // A stray earlier reply — keep waiting for ours.
                }
                if (self.exited) break;
                _ = self.pumpOnce(25);
            }
            if (!matched and !self.exited) {
                // The reply is buried behind frame data queued toward
                // the primary connection (a continuously-committing
                // app deepens that queue between tool calls without
                // bound). A FRESH side connection has an empty queue,
                // so its reply comes right after the attach snapshot.
                if (self.logGetFresh(req_json, timeout_ms)) |json| {
                    self.log_buf.clearRetainingCapacity();
                    self.log_buf.appendSlice(self.allocator, json) catch {};
                    self.log_seq += 1;
                    return .{ .json = json, .stale = false };
                } else |_| {}
                if (self.log_buf.items.len > 0) {
                    const json = self.allocator.dupe(u8, self.log_buf.items) catch return Error.OutOfMemory;
                    return .{ .json = json, .stale = true };
                }
                return Error.Timeout;
            }
        }
        if (self.log_buf.items.len == 0) return Error.NotConnected;
        const json = self.allocator.dupe(u8, self.log_buf.items) catch return Error.OutOfMemory;
        return .{ .json = json, .stale = false };
    }

    /// Fetch log lines over a FRESH side connection: its daemon-side
    /// write queue is empty, so log_data arrives immediately after the
    /// attach snapshot no matter how deep the primary connection's
    /// frame backlog is. Hellos proto 1 (no native-channel replay, no
    /// pool bytes) and attaches kind "cli" (not counted as a driver).
    /// Caller owns the returned JSON.
    fn logGetFresh(self: *App, req_json: []const u8, timeout_ms: i64) Error![]u8 {
        if (self.exited) return Error.NotConnected;
        const a = self.allocator;
        const deadline = nowMs() + timeout_ms;
        var conn = blk: {
            if (self.ssh_host) |h| break :blk muxclient.Conn.connectSsh(a, h) catch return Error.NotConnected;
            break :blk muxclient.Conn.connectLocalAutostartAt(a, self.local_sock) catch return Error.NotConnected;
        };
        defer conn.deinit();
        conn.setNonBlocking();
        conn.sendJson(.hello, .{ .proto = 1 }) catch return Error.NotConnected;
        (conn.recvExpectFor(&.{.welcome}, @max(deadline - nowMs(), 1)) catch return Error.Timeout).deinit(a);
        conn.sendJson(.attach, .{ .name = self.name, .kind = "cli" }) catch return Error.NotConnected;
        (conn.recvExpectFor(&.{.snapshot}, @max(deadline - nowMs(), 1)) catch return Error.Timeout).deinit(a);
        conn.sendFrame(.log_get, req_json) catch return Error.NotConnected;
        const f = conn.recvExpectFor(&.{.log_data}, @max(deadline - nowMs(), 1)) catch return Error.Timeout;
        defer f.deinit(a);
        return a.dupe(u8, f.payload) catch Error.OutOfMemory;
    }

    fn dropChanWindows(self: *App, chan: u32) void {
        var i: usize = 0;
        while (i < self.windows.items.len) {
            if (self.windows.items[i].chan == chan) {
                const w = self.windows.swapRemove(i);
                w.deinit(self.allocator);
                self.allocator.destroy(w);
            } else i += 1;
        }
    }

    fn winBySurface(self: *App, chan: u32, sid: u32) ?*Window {
        for (self.windows.items) |w| {
            if (w.chan == chan and w.sid == sid) return w;
        }
        return null;
    }

    pub fn winById(self: *App, id: u32) ?*Window {
        for (self.windows.items) |w| {
            if (w.id == id) return w;
        }
        return null;
    }

    fn ensureWindow(self: *App, chan: u32, sid: u32, popup: bool) ?*Window {
        if (self.winBySurface(chan, sid)) |w| {
            w.resync_seen = true;
            return w;
        }
        const w = self.allocator.create(Window) catch return null;
        w.* = .{ .id = self.next_win_id, .chan = chan, .sid = sid, .popup = popup };
        self.next_win_id += 1;
        self.windows.append(self.allocator, w) catch {
            self.allocator.destroy(w);
            return null;
        };
        return w;
    }

    // ── replica view callbacks ──────────────────────────────────

    /// Fresh (lenient) replica compositor wired to this channel's
    /// view callbacks — used at chan_open and for in-place resync
    /// rebuilds.
    fn makeReplica(self: *App, ch: *Chan) !wlcomp.Compositor {
        var comp = try wlcomp.Compositor.init(self.allocator, .{
            .ctx = ch,
            .toplevel_new = onNew,
            .toplevel_frame = onFrame,
            .toplevel_title = onTitle,
            .toplevel_app_id = onAppId,
            .toplevel_gone = onGone,
            .popup_new = onPopupNew,
            .popup_gone = onGone,
            .subsurface_new = onSubsurfaceNew,
            .subsurface_gone = onSubsurfaceGone,
            .clipboard_offer = onClipOffer,
            .clipboard_data = onClipData,
            .clipboard_read = onClipRead,
            .primary_read = onPrimaryRead,
        });
        comp.lenient = true;
        return comp;
    }

    fn chanOf(ctx: ?*anyopaque) *Chan {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn onNew(ctx: ?*anyopaque, sid: u32) void {
        const ch = chanOf(ctx);
        _ = ch.app.ensureWindow(ch.id, sid, false);
    }

    fn onPopupNew(ctx: ?*anyopaque, sid: u32, parent: u32, x: i32, y: i32) void {
        _ = parent;
        _ = x;
        _ = y;
        const ch = chanOf(ctx);
        _ = ch.app.ensureWindow(ch.id, sid, true);
    }

    fn onSubsurfaceNew(ctx: ?*anyopaque, sid: u32, parent: u32, x: i32, y: i32) void {
        _ = parent;
        _ = x;
        _ = y;
        const ch = chanOf(ctx);
        ch.subsurfaces.put(ch.app.allocator, sid, {}) catch {};
        // Defensive cleanup for a malformed/replayed stream whose
        // frame raced the role notification.
        onSubsurfaceGoneWindow(ch, sid);
    }

    fn onSubsurfaceGoneWindow(ch: *Chan, sid: u32) void {
        var i: usize = 0;
        while (i < ch.app.windows.items.len) {
            const win = ch.app.windows.items[i];
            if (win.chan == ch.id and win.sid == sid) {
                _ = ch.app.windows.swapRemove(i);
                win.deinit(ch.app.allocator);
                ch.app.allocator.destroy(win);
                continue;
            }
            i += 1;
        }
    }

    fn onSubsurfaceGone(ctx: ?*anyopaque, sid: u32) void {
        const ch = chanOf(ctx);
        _ = ch.subsurfaces.remove(sid);
        onSubsurfaceGoneWindow(ch, sid);
    }

    fn onFrame(ctx: ?*anyopaque, sid: u32, w: i32, h: i32, scale: i32, lw: i32, lh: i32, format: u32, pixels: []const u8) void {
        // Headless sessions run at scale 1 (no viewer sends
        // set_scale), so logical == physical here.
        _ = lw;
        _ = lh;
        const ch = chanOf(ctx);
        if (ch.subsurfaces.contains(sid)) return;
        const win = ch.app.ensureWindow(ch.id, sid, false) orelse return;
        win.w = w;
        win.h = h;
        win.scale = scale;
        win.format = format;
        win.pixels.clearRetainingCapacity();
        win.pixels.appendSlice(ch.app.allocator, pixels) catch {};
        win.frames += 1;
        win.last_commit_ms = nowMs();
        ch.app.frame_seq += 1;
        ch.app.tickPendingMarkers(win);
        if (win.id == ch.app.rec_win and w > 0 and h > 0) {
            const t = nowMs();
            if (ch.app.rec_min_interval_ms <= 0 or t - ch.app.rec_last_add >= ch.app.rec_min_interval_ms) {
                ch.app.rec_last_add = t;
                if (ch.app.rec) |*r| r.addShmFrame(pixels, @intCast(w), @intCast(h), format, t) catch {};
                if (ch.app.vrec) |*r| r.addShmFrame(pixels, @intCast(w), @intCast(h), format, t) catch {};
            }
        }
    }

    fn onTitle(ctx: ?*anyopaque, sid: u32, title: []const u8) void {
        const ch = chanOf(ctx);
        const win = ch.app.ensureWindow(ch.id, sid, false) orelse return;
        const copy = ch.app.allocator.dupe(u8, title) catch return;
        if (win.title) |old| ch.app.allocator.free(old);
        win.title = copy;
    }

    fn onAppId(ctx: ?*anyopaque, sid: u32, app_id: []const u8) void {
        const ch = chanOf(ctx);
        const win = ch.app.ensureWindow(ch.id, sid, false) orelse return;
        const copy = ch.app.allocator.dupe(u8, app_id) catch return;
        if (win.app_id) |old| ch.app.allocator.free(old);
        win.app_id = copy;
    }

    fn onClipOffer(ctx: ?*anyopaque, source: u32, mime: []const u8) void {
        const ch = chanOf(ctx);
        const a = ch.app.allocator;
        const copy = a.dupe(u8, mime) catch return;
        if (ch.app.clip_offer) |old| a.free(old.mime);
        ch.app.clip_offer = .{ .chan = ch.id, .source = source, .mime = copy };
    }

    fn onClipData(ctx: ?*anyopaque, bytes: []const u8) void {
        const ch = chanOf(ctx);
        ch.app.clip_buf.clearRetainingCapacity();
        ch.app.clip_buf.appendSlice(ch.app.allocator, bytes) catch return;
        ch.app.clip_got = true;
    }

    fn onClipRead(ctx: ?*anyopaque, mime: []const u8) void {
        _ = mime;
        const ch = chanOf(ctx);
        const data = ch.app.paste_data orelse "";
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(ch.app.allocator);
        wlpipe.appendUnit(&units, ch.app.allocator, .clip_data, data) catch return;
        ch.app.sendIntents(ch.id, units.items) catch {};
    }

    /// Primary paste: answer the offered text (same buffer as the
    /// regular paste) — the daemon holds a fd until we do.
    fn onPrimaryRead(ctx: ?*anyopaque, mime: []const u8) void {
        _ = mime;
        const ch = chanOf(ctx);
        const data = ch.app.paste_data orelse "";
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(ch.app.allocator);
        wlpipe.appendUnit(&units, ch.app.allocator, .primary_data, data) catch return;
        ch.app.sendIntents(ch.id, units.items) catch {};
    }

    fn onGone(ctx: ?*anyopaque, sid: u32) void {
        const ch = chanOf(ctx);
        var i: usize = 0;
        while (i < ch.app.windows.items.len) {
            const w = ch.app.windows.items[i];
            if (w.chan == ch.id and w.sid == sid) {
                _ = ch.app.windows.swapRemove(i);
                w.deinit(ch.app.allocator);
                ch.app.allocator.destroy(w);
                continue;
            }
            i += 1;
        }
    }

    // ── waiting ─────────────────────────────────────────────────

    /// Pump until at least one toplevel has pixels (or timeout).
    pub fn waitFirstWindow(self: *App, timeout_ms: i64) bool {
        const deadline = nowMs() + timeout_ms;
        while (nowMs() < deadline) {
            for (self.windows.items) |w| {
                if (!w.popup and w.frames > 0) return true;
            }
            if (self.exited) return false;
            _ = self.pumpOnce(50);
        }
        for (self.windows.items) |w| {
            if (!w.popup and w.frames > 0) return true;
        }
        return false;
    }

    /// Pump until no frame arrived for `quiet_ms` (bounded by
    /// `timeout_ms`). Returns true when quiescence was reached.
    pub fn waitIdle(self: *App, quiet_ms: i64, timeout_ms: i64) bool {
        const deadline = nowMs() + timeout_ms;
        var last_seq = self.frame_seq;
        var quiet_since = nowMs();
        while (nowMs() < deadline) {
            _ = self.pumpOnce(25);
            if (self.frame_seq != last_seq) {
                last_seq = self.frame_seq;
                quiet_since = nowMs();
            } else if (nowMs() - quiet_since >= quiet_ms) {
                return true;
            }
            if (self.exited) return true;
        }
        return false;
    }

    // ── input intents ───────────────────────────────────────────

    fn sendIntents(self: *App, chan: u32, units: []const u8) Error!void {
        if (self.exited) return Error.NotConnected;
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.allocator);
        var idb: [4]u8 = undefined;
        std.mem.writeInt(u32, &idb, chan, .little);
        payload.appendSlice(self.allocator, &idb) catch return Error.OutOfMemory;
        payload.appendSlice(self.allocator, units) catch return Error.OutOfMemory;
        self.conn.sendFrame(.chan_data, payload.items) catch return Error.NotConnected;
    }

    /// Left=1 Middle=2 Right=3 (GDK numbering) → evdev BTN_*.
    fn evdevButton(button: u32) u32 {
        return switch (button) {
            2 => 0x112,
            3 => 0x111,
            else => 0x110,
        };
    }

    pub const PtrPos = struct { win: u32, x: f64, y: f64 };

    /// Where the tracked pointer is (null until the first injected
    /// motion/click).
    pub fn pointerPos(self: *const App) ?PtrPos {
        if (self.ptr_win == 0) return null;
        return .{ .win = self.ptr_win, .x = self.ptr_x, .y = self.ptr_y };
    }

    /// Pointer target: explicit id, else the window the pointer is
    /// already on, else the first toplevel.
    fn resolvePtrWin(self: *App, win_id: ?u32) Error!*Window {
        if (win_id) |id| return self.winById(id) orelse Error.NoSuchWindow;
        if (self.ptr_win != 0) {
            if (self.winById(self.ptr_win)) |w| return w;
        }
        for (self.windows.items) |w| {
            if (!w.popup) return w;
        }
        return Error.NoSuchWindow;
    }

    /// Inject enter+motion to (x,y) and move the tracked position.
    fn sendPointer(self: *App, win: *Window, x: f64, y: f64) Error!void {
        const a = self.allocator;
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(a);
        wlpipe.appendSeatEnter(&units, a, win.sid, x, y) catch return Error.OutOfMemory;
        wlpipe.appendSeatMotion(&units, a, x, y) catch return Error.OutOfMemory;
        try self.sendIntents(win.chan, units.items);
        self.rememberPtr(win.id, x, y);
    }

    fn rememberPtr(self: *App, win_id: u32, x: f64, y: f64) void {
        self.ptr_win = win_id;
        self.ptr_x = x;
        self.ptr_y = y;
    }

    /// Move the pointer WITHOUT any button (hover; and the motion
    /// primitive for relative-pointer apps — the compositor derives
    /// relative_motion deltas from successive absolute positions).
    pub fn moveMouse(self: *App, win_id: ?u32, x: f64, y: f64) Error!PtrPos {
        const win = try self.resolvePtrWin(win_id);
        try self.sendPointer(win, x, y);
        return .{ .win = win.id, .x = x, .y = y };
    }

    /// Relative move: delta from the tracked position (window center
    /// when the pointer has not been placed on this window yet).
    /// Deliberately UNCLAMPED — a pointer-locked app only consumes
    /// the deltas, and clamping would silently absorb part of one.
    pub fn moveMouseRel(self: *App, win_id: ?u32, dx: f64, dy: f64) Error!PtrPos {
        const win = try self.resolvePtrWin(win_id);
        var bx = @as(f64, @floatFromInt(win.w)) / 2.0;
        var by = @as(f64, @floatFromInt(win.h)) / 2.0;
        if (self.ptr_win == win.id) {
            bx = self.ptr_x;
            by = self.ptr_y;
        } else {
            // First contact: PLACE the pointer at the base before
            // moving. The brain's enter resets its delta base to the
            // enter coords, so folding the delta into the entering
            // motion derives a relative_motion of (0,0) — a pointer-
            // locked app (the main consumer of relative moves, and
            // the documented dx/dy calibration pattern) would
            // silently see nothing.
            try self.sendPointer(win, bx, by);
        }
        try self.sendPointer(win, bx + dx, by + dy);
        return .{ .win = win.id, .x = bx + dx, .y = by + dy };
    }

    pub fn click(self: *App, win_id: u32, x: f64, y: f64, button: u32) Error!void {
        return self.clickEx(win_id, x, y, button, 0, 1);
    }

    /// Click with a held button and/or repeated presses.
    /// @param hold_ms spans press→release: an app polling per-tick edge
    ///        counts can see an instantaneous press+release collapsed
    ///        into one sample, and press-armed repeat UIs never fire.
    /// @param count packs presses ~80ms apart — inside any double-click
    ///        threshold, which two separate tool calls can never be.
    pub fn clickEx(self: *App, win_id: u32, x: f64, y: f64, button: u32, hold_ms: i64, count: u32) Error!void {
        const win = self.winById(win_id) orelse return Error.NoSuchWindow;
        const a = self.allocator;
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(a);
        wlpipe.appendSeatEnter(&units, a, win.sid, x, y) catch return Error.OutOfMemory;
        wlpipe.appendSeatMotion(&units, a, x, y) catch return Error.OutOfMemory;
        const reps = @max(count, 1);
        var i: u32 = 0;
        while (i < reps) : (i += 1) {
            wlpipe.appendSeatButton(&units, a, evdevButton(button), true) catch return Error.OutOfMemory;
            if (hold_ms > 0) {
                try self.sendIntents(win.chan, units.items);
                units.clearRetainingCapacity();
                self.pumpFor(hold_ms);
            }
            wlpipe.appendSeatButton(&units, a, evdevButton(button), false) catch return Error.OutOfMemory;
            if (i + 1 < reps) {
                try self.sendIntents(win.chan, units.items);
                units.clearRetainingCapacity();
                self.pumpFor(80);
            }
        }
        if (units.items.len > 0) try self.sendIntents(win.chan, units.items);
        self.rememberPtr(win.id, x, y);
    }

    /// Bounded wall-clock delay that keeps pumping frames (a blind
    /// nanosleep would let the daemon-side wbuf back up mid-gesture).
    fn pumpFor(self: *App, ms: i64) void {
        const deadline = nowMs() + ms;
        while (!self.exited) {
            const left = deadline - nowMs();
            if (left <= 0) return;
            _ = self.pumpOnce(@intCast(@min(left, 20)));
        }
    }

    pub fn scroll(self: *App, win_id: u32, x: f64, y: f64, dx: f64, dy: f64) Error!void {
        const win = self.winById(win_id) orelse return Error.NoSuchWindow;
        const a = self.allocator;
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(a);
        wlpipe.appendSeatEnter(&units, a, win.sid, x, y) catch return Error.OutOfMemory;
        // Enter is a no-op when focus is unchanged, so the motion is
        // what actually puts the pointer at the scroll point.
        wlpipe.appendSeatMotion(&units, a, x, y) catch return Error.OutOfMemory;
        if (dy != 0) wlpipe.appendSeatAxis(&units, a, 0, dy * 10.0, @intFromFloat(dy * 120.0)) catch return Error.OutOfMemory;
        if (dx != 0) wlpipe.appendSeatAxis(&units, a, 1, dx * 10.0, @intFromFloat(dx * 120.0)) catch return Error.OutOfMemory;
        try self.sendIntents(win.chan, units.items);
        self.rememberPtr(win.id, x, y);
    }

    /// Press-move-release drag. Motions go out in small bursts with
    /// pumps between so the app sees a gesture, not one event blob.
    pub fn drag(self: *App, win_id: u32, x1: f64, y1: f64, x2: f64, y2: f64, button: u32) Error!void {
        const win = self.winById(win_id) orelse return Error.NoSuchWindow;
        const a = self.allocator;
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(a);
        wlpipe.appendSeatEnter(&units, a, win.sid, x1, y1) catch return Error.OutOfMemory;
        wlpipe.appendSeatMotion(&units, a, x1, y1) catch return Error.OutOfMemory;
        wlpipe.appendSeatButton(&units, a, evdevButton(button), true) catch return Error.OutOfMemory;
        try self.sendIntents(win.chan, units.items);
        const dist = @max(@abs(x2 - x1), @abs(y2 - y1));
        const steps: u32 = @intFromFloat(std.math.clamp(dist / 16.0, 4.0, 40.0));
        var i: u32 = 1;
        while (i <= steps) : (i += 1) {
            const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
            units.clearRetainingCapacity();
            wlpipe.appendSeatMotion(&units, a, x1 + (x2 - x1) * t, y1 + (y2 - y1) * t) catch return Error.OutOfMemory;
            try self.sendIntents(win.chan, units.items);
            if (i % 4 == 0) _ = self.pumpOnce(5);
        }
        units.clearRetainingCapacity();
        wlpipe.appendSeatButton(&units, a, evdevButton(button), false) catch return Error.OutOfMemory;
        try self.sendIntents(win.chan, units.items);
        self.rememberPtr(win.id, x2, y2);
    }

    /// Fetch the app's AT-SPI accessibility tree as JSON (the daemon
    /// reads it from the session's private a11y bus). Caller owns.
    pub fn a11yTree(self: *App, timeout_ms: i64) Error![]u8 {
        return self.a11yRequest("", timeout_ms);
    }

    /// One AT-SPI node op — payload is the JSON op object the daemon
    /// expects ({op, id, ...}). Returns the raw JSON reply
    /// ({"ok":true} or {"error":...}); caller owns it.
    pub fn a11yOp(self: *App, payload: []const u8, timeout_ms: i64) Error![]u8 {
        return self.a11yRequest(payload, timeout_ms);
    }

    fn a11yRequest(self: *App, payload: []const u8, timeout_ms: i64) Error![]u8 {
        self.drain();
        if (self.exited) return Error.NotConnected;
        self.conn.sendFrame(.app_a11y, payload) catch return Error.NotConnected;
        // The reply may take a moment (the daemon walks the bus).
        // recvFrameFor, not recvFrame: a half-arrived frame from a
        // stalled daemon must time out, not block forever.
        const deadline = nowMs() + timeout_ms;
        while (nowMs() < deadline) {
            const f = self.conn.recvFrameFor(100) catch |err| switch (err) {
                error.Timeout => continue,
                else => return Error.NotConnected,
            };
            defer f.deinit(self.allocator);
            if (f.ftype == .app_a11y_tree)
                return self.allocator.dupe(u8, f.payload) catch Error.OutOfMemory;
            // Any other frame (events, chan data) is handled normally.
            self.handleFrame(f.ftype, f.payload);
        }
        return Error.Timeout;
    }

    // ── clipboard ───────────────────────────────────────────────

    /// Fetch what the app last copied. Requires the app to have
    /// announced a selection (clip_offer); pumps until the daemon
    /// pipes the bytes back. Caller owns the result.
    pub fn getClipboard(self: *App, timeout_ms: i64) Error![]u8 {
        self.drain();
        const offer = self.clip_offer orelse return Error.NoClipboard;
        const a = self.allocator;
        self.clip_got = false;
        var pl: std.ArrayList(u8) = .empty;
        defer pl.deinit(a);
        var idb: [4]u8 = undefined;
        std.mem.writeInt(u32, &idb, offer.source, .little);
        pl.appendSlice(a, &idb) catch return Error.OutOfMemory;
        pl.appendSlice(a, offer.mime) catch return Error.OutOfMemory;
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(a);
        wlpipe.appendUnit(&units, a, .clip_send, pl.items) catch return Error.OutOfMemory;
        try self.sendIntents(offer.chan, units.items);
        const deadline = nowMs() + timeout_ms;
        while (!self.clip_got and nowMs() < deadline) {
            if (self.exited) return Error.NotConnected;
            _ = self.pumpOnce(25);
        }
        if (!self.clip_got) return Error.Timeout;
        return a.dupe(u8, self.clip_buf.items) catch Error.OutOfMemory;
    }

    /// Announce `text` as the host clipboard toward every app
    /// connection; served when the app pastes (onClipRead).
    pub fn setClipboard(self: *App, text: []const u8) Error!void {
        const a = self.allocator;
        const copy = a.dupe(u8, text) catch return Error.OutOfMemory;
        if (self.paste_data) |old| a.free(old);
        self.paste_data = copy;
        for (self.chans.values()) |ch| {
            var units: std.ArrayList(u8) = .empty;
            defer units.deinit(a);
            wlpipe.appendUnit(&units, a, .offer_selection, "text/plain;charset=utf-8") catch
                return Error.OutOfMemory;
            self.sendIntents(ch.id, units.items) catch {};
        }
    }

    /// Clipboard-paste text into a window: offer + Ctrl+V. The paste
    /// itself completes during subsequent pumps (waitIdle/drain).
    pub fn pasteText(self: *App, win_id: ?u32, text: []const u8) Error!void {
        try self.setClipboard(text);
        _ = try self.resolveKbd(win_id);
        try self.pressKey(win_id, "ctrl+v");
    }

    /// Aim the keyboard at a window (idempotent).
    fn kbdTarget(self: *App, win_id: u32) Error!*Window {
        const win = self.winById(win_id) orelse return Error.NoSuchWindow;
        const a = self.allocator;
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(a);
        wlpipe.appendSeatKbdEnter(&units, a, win.sid) catch return Error.OutOfMemory;
        try self.sendIntents(win.chan, units.items);
        self.kbd_focus = win_id;
        return win;
    }

    /// Default keyboard target: the explicit id, or the first toplevel.
    fn resolveKbd(self: *App, win_id: ?u32) Error!*Window {
        if (win_id) |id| return self.kbdTarget(id);
        if (self.kbd_focus != 0) {
            if (self.winById(self.kbd_focus)) |w| return w;
        }
        for (self.windows.items) |w| {
            if (!w.popup) return self.kbdTarget(w.id);
        }
        return Error.NoSuchWindow;
    }

    /// Codepoint -> keycode+mods against the session's keymap (or
    /// the builtin us tables when no layout was parsed).
    fn charEntry(self: *App, cp: u21) ?xkblayout.Entry {
        if (cp == '\n') return .{ .code = evkeys.KEY_ENTER };
        if (cp == '\t') return .{ .code = 15 };
        if (self.layout) |*l| return l.lookup(cp);
        if (cp > 127) return null;
        const k = evkeys.charKey(@intCast(cp)) orelse return null;
        return .{ .code = k.code, .shift = k.shift };
    }

    pub fn typeText(self: *App, win_id: ?u32, text: []const u8) Error!void {
        // Anything the keymap can't express goes through the
        // clipboard-paste path instead.
        const view = std.unicode.Utf8View.init(text) catch
            return self.pasteText(win_id, text);
        var probe = view.iterator();
        while (probe.nextCodepoint()) |cp| {
            if (self.charEntry(cp) == null) return self.pasteText(win_id, text);
        }
        const win = try self.resolveKbd(win_id);
        const a = self.allocator;
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(a);
        var held: u32 = 0;
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            const e = self.charEntry(cp) orelse return Error.BadKey;
            const want: u32 = (@as(u32, @intFromBool(e.shift))) | (@as(u32, @intFromBool(e.altgr)) * 128);
            if (want != held) {
                held = want;
                wlpipe.appendSeatMods(&units, a, held, 0, 0, 0) catch return Error.OutOfMemory;
            }
            wlpipe.appendSeatKey(&units, a, e.code, true) catch return Error.OutOfMemory;
            wlpipe.appendSeatKey(&units, a, e.code, false) catch return Error.OutOfMemory;
        }
        if (held != 0) wlpipe.appendSeatMods(&units, a, 0, 0, 0, 0) catch return Error.OutOfMemory;
        try self.sendIntents(win.chan, units.items);
    }

    pub fn pressKey(self: *App, win_id: ?u32, spec: []const u8) Error!void {
        return self.pressKeyHold(win_id, spec, 0);
    }

    /// pressKey with the key held down `hold_ms` before release — the
    /// app's own key-repeat (Wayland repeat is client-side, driven by
    /// how long the key stays down) fires during the hold.
    pub fn pressKeyHold(self: *App, win_id: ?u32, spec: []const u8, hold_ms: i64) Error!void {
        var chord = evkeys.parseChord(spec) orelse return Error.BadKey;
        if (chord.ch) |ch| {
            // Chord letters name CHARACTERS ("ctrl+c" means the key
            // that types 'c'), so they follow the session layout.
            if (self.layout != null) {
                const e = self.charEntry(ch) orelse return Error.BadKey;
                chord.key.code = e.code;
                chord.mods.shift = chord.mods.shift or e.shift;
                chord.mods.altgr = e.altgr;
            }
        }
        const win = try self.resolveKbd(win_id);
        const a = self.allocator;
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(a);
        if (chord.mods.any())
            wlpipe.appendSeatMods(&units, a, chord.mods.bits(), 0, 0, 0) catch return Error.OutOfMemory;
        wlpipe.appendSeatKey(&units, a, chord.key.code, true) catch return Error.OutOfMemory;
        if (hold_ms > 0) {
            try self.sendIntents(win.chan, units.items);
            units.clearRetainingCapacity();
            self.pumpFor(hold_ms);
        }
        wlpipe.appendSeatKey(&units, a, chord.key.code, false) catch return Error.OutOfMemory;
        if (chord.mods.any())
            wlpipe.appendSeatMods(&units, a, 0, 0, 0, 0) catch return Error.OutOfMemory;
        try self.sendIntents(win.chan, units.items);
    }

    pub fn resizeWindow(self: *App, win_id: u32, w: i32, h: i32) Error!void {
        const win = self.winById(win_id) orelse return Error.NoSuchWindow;
        const a = self.allocator;
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(a);
        wlpipe.appendConfigure(&units, a, win.sid, w, h, 1) catch return Error.OutOfMemory;
        try self.sendIntents(win.chan, units.items);
    }

    pub fn closeWindow(self: *App, win_id: u32) Error!void {
        const win = self.winById(win_id) orelse return Error.NoSuchWindow;
        const a = self.allocator;
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(a);
        wlpipe.appendRequestClose(&units, a, win.sid) catch return Error.OutOfMemory;
        try self.sendIntents(win.chan, units.items);
    }

    // ── capture ─────────────────────────────────────────────────

    /// Start recording a window's frames as GIF (`webm` false) or
    /// WebM/VP9 (`webm` true). Replaces any recording in progress.
    /// `fps` caps the capture rate (0 = every committed frame).
    pub fn recordStart(self: *App, win_id: u32, max_dim: u32, webm: bool, fps: u32) Error!void {
        const win = self.winById(win_id) orelse return Error.NoSuchWindow;
        if (self.rec) |*r| r.abort();
        if (self.vrec) |*r| r.abort();
        self.rec = null;
        self.vrec = null;
        self.rec_min_interval_ms = if (fps == 0) 0 else @divTrunc(@as(i64, 1000), @as(i64, fps));
        self.rec_last_add = 0;
        if (webm)
            self.vrec = videorec.Rec.init(self.allocator, max_dim)
        else
            self.rec = gifrec.Rec.init(self.allocator, max_dim);
        self.rec_win = win.id;
        // Seed with the current frame so recording starts from "now".
        if (win.w > 0 and win.pixels.items.len > 0) {
            const t = nowMs();
            self.rec_last_add = t;
            if (self.rec) |*r| r.addShmFrame(win.pixels.items, @intCast(win.w), @intCast(win.h), win.format, t) catch {};
            if (self.vrec) |*r| r.addShmFrame(win.pixels.items, @intCast(win.w), @intCast(win.h), win.format, t) catch {};
        }
    }

    /// Stop recording; returns the encoded bytes (caller owns), the
    /// frame count, and whether it is WebM (else GIF).
    pub fn recordStop(self: *App) Error!struct { data: []u8, frames: usize, webm: bool } {
        if (self.vrec) |vr| {
            var r = vr; // copy out before clearing the optional
            self.vrec = null;
            const frames = r.frames;
            const data = r.finish(nowMs()) catch |err| return switch (err) {
                videorec.Error.OutOfMemory => Error.OutOfMemory,
                else => Error.Timeout,
            };
            return .{ .data = data, .frames = frames, .webm = true };
        }
        var r = self.rec orelse return Error.NotRecording;
        self.rec = null;
        const frames = r.frames + @intFromBool(r.pend != null);
        const gif = r.finish(nowMs()) catch |err| {
            return switch (err) {
                gifrec.Error.OutOfMemory => Error.OutOfMemory,
                else => Error.Timeout, // no frames captured
            };
        };
        return .{ .data = gif, .frames = frames, .webm = false };
    }

    pub const Shot = struct {
        png: []u8,
        /// Emitted image dimensions (after crop/zoom/downscale).
        img_w: u32,
        img_h: u32,
        /// Surface pixels per image pixel; multiply image coords by
        /// this (then add ox/oy) to get click coordinates. 1.0 = 1:1.
        scale: f64,
        /// Surface coordinates of the image's top-left (crop origin).
        ox: u32 = 0,
        oy: u32 = 0,
    };

    /// Sub-rectangle of a window in surface pixels (screenshot crop).
    pub const Region = struct { x: u32, y: u32, w: u32, h: u32 };

    /// Latest committed pixels of one window as a PNG: optional
    /// `region` crop, optional integer `zoom` (nearest-neighbor, for
    /// pixel inspection), then downscaled so neither dimension exceeds
    /// `max_dim` (0 = no bound). Caller owns `.png`. Moves the
    /// wait_change/diff baseline ("what the caller last saw").
    pub fn screenshotPng(self: *App, win_id: u32, max_dim: u32, region: ?Region, zoom_req: u32) Error!Shot {
        return self.screenshotPngMarked(win_id, max_dim, region, zoom_req, &.{});
    }

    /// Screenshot with click/hover markers drawn in (mark positions in
    /// SURFACE coordinates — the same space app_click takes).
    pub fn screenshotPngMarked(self: *App, win_id: u32, max_dim: u32, region: ?Region, zoom_req: u32, annot: []const marks_mod.Mark) Error!Shot {
        const win = self.winById(win_id) orelse return Error.NoSuchWindow;
        if (win.w <= 0 or win.h <= 0 or win.pixels.items.len == 0) return Error.NoSuchWindow;
        win.rememberShot(self.allocator);
        return self.encodeWindowPngMarked(win, max_dim, region, zoom_req, annot);
    }

    /// PNG-encode a window WITHOUT touching the observation baseline
    /// (marker stashes must not eat a pending wait_change).
    fn encodeWindowPng(self: *App, win: *Window, max_dim: u32, region: ?Region, zoom_req: u32) Error!Shot {
        return self.encodeWindowPngMarked(win, max_dim, region, zoom_req, &.{});
    }

    fn encodeWindowPngMarked(self: *App, win: *Window, max_dim: u32, region: ?Region, zoom_req: u32, annot: []const marks_mod.Mark) Error!Shot {
        if (win.w <= 0 or win.h <= 0 or win.pixels.items.len == 0) return Error.NoSuchWindow;
        const uw: u32 = @intCast(win.w);
        const uh: u32 = @intCast(win.h);
        const a = self.allocator;

        var ox: u32 = 0;
        var oy: u32 = 0;
        var cw: u32 = uw;
        var ch: u32 = uh;
        if (region) |r| {
            if (r.x >= uw or r.y >= uh or r.w == 0 or r.h == 0) return Error.NoSuchWindow;
            ox = r.x;
            oy = r.y;
            cw = @min(r.w, uw - r.x);
            ch = @min(r.h, uh - r.y);
        }
        // Clamp the upscaled intermediate to a sane area: zoom 32 on a
        // big region would demand a gigapixel buffer — minutes of CPU
        // and an OOM risk that LOOKS like a hung tool call. The final
        // max_dim bound still applies; Shot.scale reports the truth.
        var zoom: u32 = @max(1, zoom_req);
        const MAX_ZOOM_AREA: u64 = 64 << 20; // pixels
        while (zoom > 1 and @as(u64, cw) * ch * zoom * zoom > MAX_ZOOM_AREA) zoom -= 1;
        const longest = @max(cw, ch) * zoom;

        // Fast path: whole window, no zoom, no marks, within the bound.
        if (annot.len == 0 and region == null and zoom == 1 and (max_dim == 0 or longest <= max_dim)) {
            const bytes = png.encodeShm(a, win.pixels.items, uw, uh, uw * 4, win.format) catch
                return Error.OutOfMemory;
            return .{ .png = bytes, .img_w = uw, .img_h = uh, .scale = 1.0 };
        }

        var rgba = png.shmToRgba(a, win.pixels.items, uw, uh, uw * 4, win.format) catch
            return Error.OutOfMemory;
        var rw: u32 = uw;
        var rh: u32 = uh;
        defer a.free(rgba);

        if (region != null) {
            const crop = a.alloc(u8, @as(usize, cw) * ch * 4) catch return Error.OutOfMemory;
            var y: usize = 0;
            while (y < ch) : (y += 1) {
                const src = ((@as(usize, oy) + y) * uw + ox) * 4;
                @memcpy(crop[y * cw * 4 ..][0 .. @as(usize, cw) * 4], rgba[src..][0 .. @as(usize, cw) * 4]);
            }
            a.free(rgba);
            rgba = crop;
            rw = cw;
            rh = ch;
        }
        if (annot.len > 0) {
            // Marks arrive in surface coordinates; the buffer is at
            // surface scale here (post-crop, pre-zoom/downscale), so
            // only the crop origin shifts them. Zoom/downscale below
            // scales the drawn marker with the pixels.
            var shifted: [32]marks_mod.Mark = undefined;
            const n = @min(annot.len, shifted.len);
            for (annot[0..n], 0..) |m, i| {
                shifted[i] = m;
                shifted[i].x -= @floatFromInt(ox);
                shifted[i].y -= @floatFromInt(oy);
            }
            marks_mod.draw(rgba, rw, rh, shifted[0..n]);
        }
        if (zoom > 1) {
            const big = png.upscaleRgba(a, rgba, rw, rh, zoom) catch return Error.OutOfMemory;
            a.free(rgba);
            rgba = big;
            rw *= zoom;
            rh *= zoom;
        }
        if (max_dim != 0 and @max(rw, rh) > max_dim) {
            const l = @max(rw, rh);
            const dw: u32 = @max(1, rw * max_dim / l);
            const dh: u32 = @max(1, rh * max_dim / l);
            const small = png.downscaleRgba(a, rgba, rw, rh, dw, dh) catch return Error.OutOfMemory;
            a.free(rgba);
            rgba = small;
            rw = dw;
            rh = dh;
        }
        const bytes = png.encodeRgba(a, rgba, rw, rh) catch return Error.OutOfMemory;
        return .{
            .png = bytes,
            .img_w = rw,
            .img_h = rh,
            // Surface px per image px over the CROPPED region.
            .scale = @as(f64, @floatFromInt(cw)) / @as(f64, @floatFromInt(rw)),
            .ox = ox,
            .oy = oy,
        };
    }

    pub const RgbaShot = struct {
        /// Tightly-packed straight RGBA; caller frees.
        px: []u8,
        w: u32,
        h: u32,
        /// Surface coordinates of the top-left (crop origin).
        ox: u32 = 0,
        oy: u32 = 0,
    };

    /// Current committed pixels of a window as straight RGBA, with an
    /// optional crop — the input for template matching and OCR. Does
    /// NOT move the wait_change/diff observation baseline.
    pub fn snapshotRgba(self: *App, win_id: u32, region: ?Region) Error!RgbaShot {
        const win = self.winById(win_id) orelse return Error.NoSuchWindow;
        if (win.w <= 0 or win.h <= 0 or win.pixels.items.len == 0) return Error.NoSuchWindow;
        const a = self.allocator;
        const uw: u32 = @intCast(win.w);
        const uh: u32 = @intCast(win.h);
        var rgba = png.shmToRgba(a, win.pixels.items, uw, uh, uw * 4, win.format) catch
            return Error.OutOfMemory;
        const r = region orelse return .{ .px = rgba, .w = uw, .h = uh };
        if (r.x >= uw or r.y >= uh or r.w == 0 or r.h == 0) {
            a.free(rgba);
            return Error.NoSuchWindow;
        }
        const cw = @min(r.w, uw - r.x);
        const ch = @min(r.h, uh - r.y);
        const crop = a.alloc(u8, @as(usize, cw) * ch * 4) catch {
            a.free(rgba);
            return Error.OutOfMemory;
        };
        var y: usize = 0;
        while (y < ch) : (y += 1) {
            const src = ((@as(usize, r.y) + y) * uw + r.x) * 4;
            @memcpy(crop[y * cw * 4 ..][0 .. @as(usize, cw) * 4], rgba[src..][0 .. @as(usize, cw) * 4]);
        }
        a.free(rgba);
        return .{ .px = crop, .w = cw, .h = ch, .ox = r.x, .oy = r.y };
    }

    /// Pump until this window has committed a frame NEWER than its
    /// last screenshot (bounded). True when new content arrived.
    /// `min_pct > 0` additionally requires that many % of pixels to
    /// differ from the screenshot baseline — a 60Hz software cursor
    /// or blinking caret no longer counts as change. No baseline yet
    /// (never screenshotted) counts as 100% different.
    pub fn waitWindowChange(self: *App, win_id: u32, timeout_ms: i64, min_pct: f64) bool {
        const deadline = nowMs() + timeout_ms;
        while (true) {
            const win = self.winById(win_id) orelse return false;
            if (win.frames != win.shot_frames and
                (min_pct <= 0 or win.pctVsBaseline() >= min_pct)) return true;
            if (self.exited or nowMs() >= deadline) return false;
            _ = self.pumpOnce(25);
        }
    }

    /// Pre-input reference for waitChangeSince: the window's commit
    /// counter — and, when a pixel threshold will gate the wait, a
    /// copy of its pixels — at the instant BEFORE input is injected.
    pub const FrameRef = struct {
        frames: u64,
        px: []u8 = &.{},
        w: i32 = 0,
        h: i32 = 0,

        pub fn deinit(self: *FrameRef, a: std.mem.Allocator) void {
            if (self.px.len > 0) a.free(self.px);
            self.px = &.{};
        }
    };

    /// Capture a FrameRef of this window (null = no such window).
    pub fn frameRef(self: *App, win_id: u32, with_pixels: bool) ?FrameRef {
        const win = self.winById(win_id) orelse return null;
        var px: []u8 = &.{};
        if (with_pixels and win.pixels.items.len > 0) {
            px = self.allocator.dupe(u8, win.pixels.items) catch &.{};
        }
        return .{ .frames = win.frames, .px = px, .w = win.w, .h = win.h };
    }

    /// Pump until the window commits a frame AFTER `ref` was taken —
    /// with `min_pct > 0` (and pixels in the ref), one that also
    /// differs from the ref by at least that % (a repainted-identical
    /// frame or a cursor blink doesn't count). False = no such frame
    /// before the deadline: the input hit a dead area, or the app
    /// reacts without redrawing. Unlike waitWindowChange this ignores
    /// the screenshot baseline entirely, so frames committed BETWEEN
    /// the last screenshot and the input can't satisfy it.
    pub fn waitChangeSince(self: *App, win_id: u32, ref: *const FrameRef, timeout_ms: i64, min_pct: f64) bool {
        const deadline = nowMs() + timeout_ms;
        while (true) {
            if (self.winById(win_id)) |win| {
                if (win.frames != ref.frames) {
                    if (min_pct <= 0 or ref.px.len == 0) return true;
                    if (win.w != ref.w or win.h != ref.h) return true;
                    if (pctDiffBuf(win.pixels.items, ref.px) >= min_pct) return true;
                }
            } else return false;
            if (self.exited or nowMs() >= deadline) return false;
            _ = self.pumpOnce(25);
        }
    }

    /// Pump until the window has committed NO new frame for
    /// `stable_ms` (settle-then-capture), bounded by `timeout_ms`.
    /// False = frames were still landing at the deadline.
    pub fn waitWindowSettle(self: *App, win_id: u32, stable_ms: i64, timeout_ms: i64) bool {
        const deadline = nowMs() + timeout_ms;
        var last: u64 = (self.winById(win_id) orelse return false).frames;
        var quiet_since = nowMs();
        while (nowMs() < deadline) {
            if (self.exited) return true;
            _ = self.pumpOnce(25);
            const win = self.winById(win_id) orelse return false;
            if (win.frames != last) {
                last = win.frames;
                quiet_since = nowMs();
            } else if (nowMs() - quiet_since >= stable_ms) return true;
        }
        return false;
    }

    /// Pump until every new commit changes LESS than `max_change_pct`
    /// of the window's pixels for `quiet_ms` straight (VISUAL
    /// quiescence), bounded by `timeout_ms`. A continuously-repainting
    /// app (a game) never passes frame-commit quiescence, but an
    /// unchanging or tiny-animation scene passes this one: commits
    /// below the threshold do not move the comparison baseline, so a
    /// slow cumulative drift still eventually counts as change.
    pub fn waitVisualSettle(self: *App, win_id: u32, quiet_ms: i64, timeout_ms: i64, max_change_pct: f64) bool {
        const a = self.allocator;
        var base: std.ArrayList(u8) = .empty;
        defer base.deinit(a);
        var base_w: i32 = 0;
        var base_h: i32 = 0;
        var last_frames: u64 = 0;
        {
            const win = self.winById(win_id) orelse return false;
            base.appendSlice(a, win.pixels.items) catch return false;
            base_w = win.w;
            base_h = win.h;
            last_frames = win.frames;
        }
        const deadline = nowMs() + timeout_ms;
        var quiet_since = nowMs();
        while (nowMs() < deadline) {
            if (self.exited) return true;
            _ = self.pumpOnce(25);
            const win = self.winById(win_id) orelse return false;
            if (win.frames != last_frames) {
                last_frames = win.frames;
                const resized = win.w != base_w or win.h != base_h;
                const pct = if (resized) 100.0 else pctDiffBuf(win.pixels.items, base.items);
                if (pct >= max_change_pct) {
                    base.clearRetainingCapacity();
                    base.appendSlice(a, win.pixels.items) catch return false;
                    base_w = win.w;
                    base_h = win.h;
                    quiet_since = nowMs();
                }
            }
            if (nowMs() - quiet_since >= quiet_ms) return true;
        }
        return false;
    }

    pub const DiffStats = struct {
        changed: bool,
        resized: bool,
        diff_pct: f64,
        w: i32,
        h: i32,
        frames: u64,
    };

    /// Changed fraction vs the baseline WITHOUT moving it — burst
    /// capture gates on this before paying for a PNG encode.
    pub fn peekDiffPct(self: *App, win_id: u32) f64 {
        const win = self.winById(win_id) orelse return 0;
        // Pixels only change on a commit; same frame counter = same content.
        if (win.frames == win.shot_frames) return 0;
        return win.pctVsBaseline();
    }

    /// Cheap "did it change" answer: compare current pixels against the
    /// baseline from the last screenshot/stats call, then move the
    /// baseline forward. No image is encoded.
    pub fn diffStats(self: *App, win_id: u32) Error!DiffStats {
        const win = self.winById(win_id) orelse return Error.NoSuchWindow;
        if (win.w <= 0 or win.h <= 0 or win.pixels.items.len == 0) return Error.NoSuchWindow;
        const had_baseline = win.shot_pixels.items.len != 0;
        const resized = had_baseline and (win.shot_w != win.w or win.shot_h != win.h);
        const pct = win.pctVsBaseline();
        const stats = DiffStats{
            .changed = win.frames != win.shot_frames and pct > 0,
            .resized = resized,
            .diff_pct = pct,
            .w = win.w,
            .h = win.h,
            .frames = win.frames,
        };
        win.rememberShot(self.allocator);
        return stats;
    }
};

test "logNonceOf: header nonce parsed, lines content never scanned" {
    const t = std.testing;
    try t.expectEqual(@as(?u64, 42), App.logNonceOf("{\"next_id\":9,\"dropped\":0,\"markers_dropped\":0,\"nonce\":42,\"lines\":[]}"));
    // Zero / absent = no nonce (old daemon, unsolicited exit push).
    try t.expectEqual(@as(?u64, null), App.logNonceOf("{\"next_id\":9,\"dropped\":0,\"markers_dropped\":0,\"nonce\":0,\"lines\":[]}"));
    try t.expectEqual(@as(?u64, null), App.logNonceOf("{\"next_id\":9,\"dropped\":0,\"lines\":[]}"));
    // A line whose text CONTAINS "nonce": must not be picked up.
    try t.expectEqual(@as(?u64, null), App.logNonceOf("{\"next_id\":9,\"dropped\":0,\"lines\":[{\"id\":1,\"t\":0,\"text\":\"\\\"nonce\\\":777\"}]}"));
}

/// Test scaffold: an App with no live connection (conn undefined or a
/// socketpair end), torn down manually — App.deinit assumes a full
/// launch (name, terminal mirror, markers) the scaffold never builds.
fn testTeardown(app: *App) void {
    const a = app.allocator;
    for (app.windows.items) |w| {
        w.deinit(a);
        a.destroy(w);
    }
    app.windows.deinit(a);
    var it = app.chans.iterator();
    while (it.next()) |e| {
        e.value_ptr.*.deinit();
        a.destroy(e.value_ptr.*);
    }
    app.chans.deinit(a);
    app.audio_ids.deinit(a);
}

fn testChanOpenPayload(buf: *[5]u8, id: u32) []const u8 {
    return wire.encodeChanOpen(buf, id, .wayland_native);
}

test "resync replay: chan_open replace keeps window identity, native_sync prunes gone windows" {
    const t = std.testing;
    const a = t.allocator;
    var app = App{ .allocator = a, .conn = undefined, .name = @constCast("test") };
    defer testTeardown(&app);

    var pl: [5]u8 = undefined;
    app.handleFrame(.chan_open, testChanOpenPayload(&pl, 7));
    const ch = app.chans.get(7).?;

    // Two live toplevels with committed pixels.
    const px_a = [_]u8{ 1, 2, 3, 4 };
    App.onFrame(ch, 1, 1, 1, 1, 1, 1, 0, &px_a);
    App.onFrame(ch, 2, 1, 1, 1, 1, 1, 0, &px_a);
    try t.expectEqual(@as(usize, 2), app.windows.items.len);
    const win1 = app.winBySurface(7, 1).?;
    try t.expectEqual(@as(u32, 1), win1.id);
    try t.expectEqual(@as(u64, 1), win1.frames);

    // Daemon paused streaming, then replays: gap → chan_open again.
    app.handleFrame(.native_gap, "");
    try t.expect(app.behind);
    app.handleFrame(.chan_open, testChanOpenPayload(&pl, 7));
    const ch2 = app.chans.get(7).?;
    try t.expectEqual(ch, ch2); // same Chan object, replica rebuilt
    try t.expect(ch2.resyncing);
    try t.expect(!win1.resync_seen);

    // Replay re-announces only surface 1, with CURRENT pixels.
    const px_b = [_]u8{ 9, 9, 9, 9 };
    App.onFrame(ch2, 1, 1, 1, 1, 1, 1, 0, &px_b);
    try t.expectEqual(win1, app.winBySurface(7, 1).?); // identity kept
    try t.expectEqualSlices(u8, &px_b, win1.pixels.items);

    // native_sync closes the replay: surface 2 died during the gap.
    app.handleFrame(.native_sync, "");
    try t.expect(!app.behind);
    try t.expect(!ch2.resyncing);
    try t.expectEqual(@as(usize, 1), app.windows.items.len);
    try t.expectEqual(win1, app.windows.items[0]);
}

test "moveMouseRel first contact places the pointer before the delta motion" {
    const t = std.testing;
    const a = t.allocator;
    var fds: [2]c_int = undefined;
    try t.expect(c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &fds) == 0);
    defer _ = c.close(fds[1]);
    var app = App{
        .allocator = a,
        .conn = .{ .allocator = a, .fd = fds[0] },
        .name = @constCast("test"),
    };
    defer {
        app.conn.rbuf.deinit(a);
        app.conn.wbuf.deinit(a);
        _ = c.close(fds[0]);
        testTeardown(&app);
    }

    var pl: [5]u8 = undefined;
    app.handleFrame(.chan_open, testChanOpenPayload(&pl, 3));
    const ch = app.chans.get(3).?;
    const px = [_]u8{0} ** (100 * 80 * 4);
    App.onFrame(ch, 5, 100, 80, 1, 100, 80, 0, &px);

    // First contact: base = window center (50, 40).
    const pos = try app.moveMouseRel(null, 10, -5);
    try t.expectEqual(@as(f64, 60), pos.x);
    try t.expectEqual(@as(f64, 35), pos.y);

    // Read the sent chan_data frames and collect the seat units.
    var raw: [4096]u8 = undefined;
    const n = c.read(fds[1], &raw, raw.len);
    try t.expect(n > 0);
    const Motion = struct { x: f64, y: f64 };
    var motions: std.ArrayList(Motion) = .empty;
    defer motions.deinit(a);
    var enters: usize = 0;
    var off: usize = 0;
    const bytes = raw[0..@intCast(n)];
    while (try wire.peelFrame(bytes[off..])) |pf| {
        off += pf.consumed;
        try t.expectEqual(wire.FrameType.chan_data, pf.frame.ftype);
        var upos: usize = 4; // skip channel id
        while (try wlpipe.peelUnit(pf.frame.payload[upos..])) |pu| {
            upos += pu.consumed;
            switch (pu.unit.tag) {
                .seat_enter => enters += 1,
                .seat_motion => try motions.append(a, .{
                    .x = @bitCast(std.mem.readInt(u64, pu.unit.payload[0..8], .little)),
                    .y = @bitCast(std.mem.readInt(u64, pu.unit.payload[8..16], .little)),
                }),
                else => {},
            }
        }
    }
    // Placement motion at the base FIRST (the brain's enter resets
    // its delta base, so this one derives 0,0), then the real move —
    // its derived relative_motion is exactly (dx, dy).
    try t.expect(enters >= 1);
    try t.expectEqual(@as(usize, 2), motions.items.len);
    try t.expectEqual(@as(f64, 50), motions.items[0].x);
    try t.expectEqual(@as(f64, 40), motions.items[0].y);
    try t.expectEqual(@as(f64, 60), motions.items[1].x);
    try t.expectEqual(@as(f64, 35), motions.items[1].y);

    // Second move: pointer tracked — a single motion, no placement.
    motions.clearRetainingCapacity();
    _ = try app.moveMouseRel(null, -20, 2);
    const n2 = c.read(fds[1], &raw, raw.len);
    try t.expect(n2 > 0);
    off = 0;
    const bytes2 = raw[0..@intCast(n2)];
    while (try wire.peelFrame(bytes2[off..])) |pf| {
        off += pf.consumed;
        var upos: usize = 4;
        while (try wlpipe.peelUnit(pf.frame.payload[upos..])) |pu| {
            upos += pu.consumed;
            if (pu.unit.tag == .seat_motion) try motions.append(a, .{
                .x = @bitCast(std.mem.readInt(u64, pu.unit.payload[0..8], .little)),
                .y = @bitCast(std.mem.readInt(u64, pu.unit.payload[8..16], .little)),
            });
        }
    }
    try t.expectEqual(@as(usize, 1), motions.items.len);
    try t.expectEqual(@as(f64, 40), motions.items[0].x);
    try t.expectEqual(@as(f64, 37), motions.items[0].y);
}
