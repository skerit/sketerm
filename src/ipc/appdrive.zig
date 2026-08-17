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

const nowMs = @import("../util/clock.zig").nowMs;

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
    origin_id: wire.SessionOriginId = undefined,
    origin_id_valid: bool = false,
    /// Session child pid on the daemon's host (0 = unknown).
    pid: i32 = 0,

    pub fn originId(self: *const AppSessionRef) []const u8 {
        return if (self.origin_id_valid) &self.origin_id else "";
    }
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
            origin_id: []const u8 = "",
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
        var ref = AppSessionRef{ .name = n, .pid = s.pid };
        if (wire.validSessionOriginId(s.origin_id)) {
            @memcpy(&ref.origin_id, s.origin_id);
            ref.origin_id_valid = true;
        }
        refs.append(allocator, ref) catch {
            allocator.free(n);
            return Error.OutOfMemory;
        };
    }
    return refs.toOwnedSlice(allocator) catch Error.OutOfMemory;
}

fn sessionOriginFromList(
    conn: *muxclient.Conn,
    allocator: std.mem.Allocator,
    session_name: []const u8,
    timeout_ms: i64,
) ?wire.SessionOriginId {
    conn.sendFrame(.list, "") catch return null;
    const frame = conn.recvExpectFor(&.{.welcome}, timeout_ms) catch return null;
    defer frame.deinit(allocator);
    const Listing = struct {
        sessions: []const struct {
            name: []const u8 = "",
            origin_name: []const u8 = "",
            origin_id: []const u8 = "",
        } = &.{},
    };
    var parsed = std.json.parseFromSlice(Listing, allocator, frame.payload, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();
    for (parsed.value.sessions) |session| {
        if (!std.mem.eql(u8, session.name, session_name) and
            !std.mem.eql(u8, session.origin_name, session_name)) continue;
        if (!wire.validSessionOriginId(session.origin_id)) return null;
        return session.origin_id[0..wire.SESSION_ORIGIN_ID_LEN].*;
    }
    return null;
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
    /// Latest COMPOSITED pixels (own buffer + every subsurface
    /// layer), tightly packed w*4 (wl_shm layout). What screenshots,
    /// diffs, OCR, templates and recordings all read.
    pixels: std.ArrayList(u8) = .empty,
    /// The root surface's own committed buffer, kept apart so a
    /// subsurface-only repaint can recomposite without it.
    base_pixels: std.ArrayList(u8) = .empty,
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
        self.base_pixels.deinit(a);
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
    fn pctVsBaseline(self: *const Window, region: ?App.Region) f64 {
        if (self.shot_w != self.w or self.shot_h != self.h) return 100.0;
        return pctDiff(self.pixels.items, self.shot_pixels.items, @intCast(@max(self.w, 0)), region);
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

/// Region-scoped pctDiffBuf over tightly-packed w*4 buffers. A rect
/// falling entirely outside the buffer diffs as 0 (never a false
/// "changed" verdict); a partially-outside rect is clamped.
fn pctDiffRegion(cur: []const u8, base: []const u8, full_w: usize, r: App.Region) f64 {
    if (base.len != cur.len or cur.len < 4 or full_w == 0) return 100.0;
    const full_h = cur.len / (full_w * 4);
    if (r.x >= full_w or r.y >= full_h or r.w == 0 or r.h == 0) return 0.0;
    const rw: usize = @min(r.w, full_w - r.x);
    const rh: usize = @min(r.h, full_h - r.y);
    var diff: usize = 0;
    var y: usize = 0;
    while (y < rh) : (y += 1) {
        const row = ((@as(usize, r.y) + y) * full_w + r.x) * 4;
        var i: usize = 0;
        while (i < rw * 4) : (i += 4) {
            if (!std.mem.eql(u8, cur[row + i ..][0..4], base[row + i ..][0..4])) diff += 1;
        }
    }
    return @as(f64, @floatFromInt(diff)) * 100.0 / @as(f64, @floatFromInt(rw * rh));
}

/// Whole-buffer or region diff, per `region`.
fn pctDiff(cur: []const u8, base: []const u8, full_w: usize, region: ?App.Region) f64 {
    const r = region orelse return pctDiffBuf(cur, base);
    return pctDiffRegion(cur, base, full_w, r);
}

/// One wayland_native channel = one app display connection, with its
/// own replica compositor.
const Chan = struct {
    app: *App,
    id: u32,
    comp: wlcomp.Compositor,
    /// Child surfaces are composited into their root window and must
    /// never become independently selectable headless "windows". JBR
    /// uses one for every drop shadow; Firefox renders its ENTIRE UI
    /// into one, so dropping their pixels leaves a window frozen on
    /// its CSD background forever.
    subsurfaces: std.AutoHashMapUnmanaged(u32, SubPix) = .empty,
    /// A daemon resync replay is rebuilding this channel's replica
    /// (repeated chan_open); cleared when `native_sync` lands.
    resyncing: bool = false,

    fn deinit(self: *Chan) void {
        self.clearSubsurfaces();
        self.subsurfaces.deinit(self.app.allocator);
        self.comp.deinit();
    }

    /// Drop every tracked subsurface layer (and its pixels).
    fn clearSubsurfaces(self: *Chan) void {
        var it = self.subsurfaces.valueIterator();
        while (it.next()) |sp| sp.pixels.deinit(self.app.allocator);
        self.subsurfaces.clearRetainingCapacity();
    }
};

/// Latest committed content of one subsurface, held until it can be
/// composited into its root window's image.
const SubPix = struct {
    w: i32 = 0,
    h: i32 = 0,
    format: u32 = 0,
    pixels: std.ArrayList(u8) = .empty,
};

/// Alpha-blend `src` (tightly packed sw*4, wl_shm byte order BGRA
/// with PREMULTIPLIED alpha) onto `dst` (tightly packed dw*4) at
/// (`ox`,`oy`), clipping to the destination. `format` 1 (XRGB8888)
/// carries no alpha: those pixels are copied opaque.
fn blendLayer(
    dst: []u8,
    dw: i32,
    dh: i32,
    src: []const u8,
    sw: i32,
    sh: i32,
    ox: i32,
    oy: i32,
    format: u32,
) void {
    if (dw <= 0 or dh <= 0 or sw <= 0 or sh <= 0) return;
    const opaque_fmt = format == 1;
    var sy: i32 = @max(0, -oy);
    while (sy < sh) : (sy += 1) {
        const dy = oy + sy;
        if (dy >= dh) break;
        const srow = @as(usize, @intCast(sy)) * @as(usize, @intCast(sw)) * 4;
        const drow = @as(usize, @intCast(dy)) * @as(usize, @intCast(dw)) * 4;
        if (srow + @as(usize, @intCast(sw)) * 4 > src.len) break;
        const sx0: i32 = @max(0, -ox);
        const sx1: i32 = @min(sw, dw - ox);
        if (sx1 <= sx0) continue;
        const n: usize = @intCast(sx1 - sx0);
        const s0 = srow + @as(usize, @intCast(sx0)) * 4;
        const d0 = drow + @as(usize, @intCast(ox + sx0)) * 4;
        if (d0 + n * 4 > dst.len or s0 + n * 4 > src.len) break;
        const srun = src[s0..][0 .. n * 4];
        const drun = dst[d0..][0 .. n * 4];
        // Whole-run fast paths: XRGB has no alpha at all, and a fully
        // opaque ARGB run (the common case — an app's content buffer)
        // is a copy. Blending 1.3M pixels per frame by hand is what
        // makes a browser-sized window expensive.
        if (opaque_fmt or allOpaque(srun)) {
            @memcpy(drun, srun);
            if (!opaque_fmt) continue;
            var i: usize = 3;
            while (i < drun.len) : (i += 4) drun[i] = 255;
            continue;
        }
        var i: usize = 0;
        while (i < n * 4) : (i += 4) {
            const a: u32 = srun[i + 3];
            if (a == 255) {
                @memcpy(drun[i..][0..4], srun[i..][0..4]);
                continue;
            }
            if (a == 0) continue;
            const inv = 255 - a;
            inline for (0..4) |k| {
                const under = @as(u32, drun[i + k]) * inv / 255;
                drun[i + k] = @intCast(@min(255, @as(u32, srun[i + k]) + under));
            }
        }
    }
}

/// Whether every pixel of a tightly-packed BGRA run has alpha 255.
fn allOpaque(run: []const u8) bool {
    var i: usize = 3;
    while (i < run.len) : (i += 4) {
        if (run[i] != 255) return false;
    }
    return true;
}

var name_counter: u32 = 0;
/// Monotonic per-process log_get nonce (uniqueness within one
/// connection is all reply matching needs).
var log_nonce_counter: u64 = 0;

pub const App = struct {
    pub const PresentationGone = enum {
        client_disconnected,
        last_toplevel_destroyed,
    };

    allocator: std.mem.Allocator,
    conn: muxclient.Conn,
    name: []u8,
    origin_id: wire.SessionOriginId = undefined,
    origin_id_valid: bool = false,
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
    /// A debugger/diagnostic wrapper can outlive the GUI inferior. Keep
    /// this separate from `exited`: deinit must still kill the wrapper,
    /// while interaction waits treat a vanished last toplevel as final.
    had_toplevel: bool = false,
    presentation_gone: ?PresentationGone = null,
    /// Session child pid ON THE DAEMON'S HOST (0 = unknown). A string
    /// command spawns via `/bin/sh -c`, so this is the shell; argv-array
    /// launches exec directly and the pid IS the app.
    pid: i32 = 0,
    /// Virtual output size the daemon confirmed at spawn (0 = the
    /// daemon predates the field): what the compositor advertises as
    /// the screen, distinct from any window's size.
    output_width: u32 = 0,
    output_height: u32 = 0,
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
        /// Virtual output mode in pixels — what the session compositor
        /// advertises as the screen (DPI/layout tests). The daemon
        /// defaults omitted/zero to 1920x1080; an older daemon ignores
        /// the field (compare App.output_width after launch).
        output_width: u32 = 0,
        output_height: u32 = 0,
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
            // Headless automation: a hang here has no user at a
            // keyboard to investigate it, so let the daemon attach a
            // debugger later (app_backtrace). Decided at spawn because
            // the Yama relaxation is only settable before exec, and an
            // app that has already hung cannot be relaunched to get it.
            .debuggable = true,
            .kb_layout = layout_name,
            .gpu = opts.gpu,
            .no_audio = opts.no_audio,
            .audio_capture = opts.audio_capture orelse "",
            .cwd = opts.cwd,
            .env = opts.env,
            // 0 = "daemon default", but the wire field must be a valid
            // mode (an explicit 0 is rejected), so resolve it here.
            .output_width = if (opts.output_width != 0) opts.output_width else wlcomp.DEFAULT_OUTPUT_WIDTH,
            .output_height = if (opts.output_height != 0) opts.output_height else wlcomp.DEFAULT_OUTPUT_HEIGHT,
        }) catch return Error.SpawnFailed;
        var spawn_pid: i32 = 0;
        var spawn_ow: u32 = 0;
        var spawn_oh: u32 = 0;
        var spawn_origin_id: wire.SessionOriginId = undefined;
        var spawn_origin_id_valid = false;
        {
            const ok = conn.recvExpectFor(&.{.ok}, opts.step_timeout_ms) catch |err| {
                setStepErr("spawn", &conn, err);
                return Error.SpawnFailed;
            };
            defer ok.deinit(allocator);
            const OkReply = struct {
                origin_id: []const u8 = "",
                pid: i32 = 0,
                output_width: u32 = 0,
                output_height: u32 = 0,
            };
            if (std.json.parseFromSlice(OkReply, allocator, ok.payload, .{
                .ignore_unknown_fields = true,
            })) |p| {
                spawn_pid = p.value.pid;
                spawn_ow = p.value.output_width;
                spawn_oh = p.value.output_height;
                if (wire.validSessionOriginId(p.value.origin_id)) {
                    @memcpy(&spawn_origin_id, p.value.origin_id);
                    spawn_origin_id_valid = true;
                }
                p.deinit();
            } else |_| {}
        }
        // MCP drives the seat: ask for the controller lease outright
        // (takeover), which is what every app tool already assumes.
        conn.sendAttach(name, .{
            .origin_id = if (spawn_origin_id_valid) &spawn_origin_id else "",
            .kind = "mcp",
            .control = true,
        }) catch return Error.SpawnFailed;
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
            .origin_id = spawn_origin_id,
            .origin_id_valid = spawn_origin_id_valid,
            .layout = layout,
            .pid = spawn_pid,
            .output_width = spawn_ow,
            .output_height = spawn_oh,
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
        expected_origin_id: ?[]const u8,
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
        var origin_id: wire.SessionOriginId = undefined;
        var origin_id_valid = false;
        if (expected_origin_id) |expected| {
            if (!wire.validSessionOriginId(expected)) return Error.SpawnFailed;
            @memcpy(&origin_id, expected);
            origin_id_valid = true;
        } else if (sessionOriginFromList(&conn, allocator, name, 15_000)) |discovered| {
            origin_id = discovered;
            origin_id_valid = true;
        }
        // MCP drives the seat: ask for the controller lease outright
        // (takeover), which is what every app tool already assumes.
        conn.sendAttach(name, .{
            .origin_id = if (origin_id_valid) &origin_id else "",
            .kind = "mcp",
            .control = true,
        }) catch return Error.SpawnFailed;
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
            .origin_id = origin_id,
            .origin_id_valid = origin_id_valid,
            .layout = layout,
            .local_sock = if (local_sock) |p| allocator.dupe(u8, p) catch null else null,
        };
        layout = null; // ownership moved
        self.applyTermSnapshot(snap.payload);
        return self;
    }

    /// How a `killAndWait` ended, so close_app can report the truth
    /// instead of asserting a kill it never confirmed.
    pub const KillOutcome = enum {
        /// Nothing to do — the process was already gone.
        already_exited,
        /// The daemon acknowledged; the session (and its process
        /// group) is torn down.
        acknowledged,
        /// The frame went out but no acknowledgement came back within
        /// the deadline — the session MAY still be running.
        unconfirmed,
    };

    /// Kill the session and WAIT for the daemon's acknowledgement.
    /// `deinit` alone fires the kill frame into a socket it closes in
    /// the same breath, which reads as success whether or not the
    /// daemon ever acted on it. Callers that report "killed" to a user
    /// must go through here.
    pub fn killAndWait(self: *App, timeout_ms: i64) KillOutcome {
        if (self.exited) return .already_exited;
        self.conn.sendKill(.{
            .name = self.name,
            .origin_id = if (self.origin_id_valid) &self.origin_id else "",
        }) catch return .unconfirmed;
        const f = self.conn.recvExpectFor(&.{ .ok, .gone }, timeout_ms) catch |err| {
            // DaemonError = "no such session": already gone daemon-side.
            return if (err == error.DaemonError) .already_exited else .unconfirmed;
        };
        f.deinit(self.allocator);
        // Suppress deinit's second, unacknowledged kill frame.
        self.exited = true;
        return .acknowledged;
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
            self.conn.sendKill(.{
                .name = self.name,
                .origin_id = if (self.origin_id_valid) &self.origin_id else "",
            }) catch {};
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
    /// (versioned envelope + serialized Screen). Best-effort: a decode
    /// failure just leaves the mirror empty (output unavailable).
    fn applyTermSnapshot(self: *App, payload: []const u8) void {
        const envelope = snapshot.peelEnvelope(payload) catch return;
        const a = self.allocator;
        self.term_seq = envelope.seq;
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
        self.term_screen = snapshot.restore(a, self.term_pool.?, envelope.body) catch null;
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
            // EOF — but the read that hit it may have buffered the final
            // frames (the daemon's post-mortem log push + `.exit`). Peel
            // everything complete BEFORE declaring the stream over:
            // pumpOnce refuses to run once `exited` is set, so anything
            // left unprocessed here (a gdb backtrace) is lost forever.
            while (self.takeOne()) {}
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
        var removed_toplevel = false;
        var i: usize = 0;
        while (i < self.windows.items.len) {
            const w = self.windows.items[i];
            if (!w.resync_seen) {
                _ = self.windows.swapRemove(i);
                removed_toplevel = removed_toplevel or !w.popup;
                w.deinit(self.allocator);
                self.allocator.destroy(w);
                continue;
            }
            i += 1;
        }
        if (removed_toplevel) self.noteToplevelRemoval(.last_toplevel_destroyed);
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
                    existing.clearSubsurfaces();
                    existing.comp = self.makeReplica(existing) catch {
                        // Replica unusable — drop the channel wholesale.
                        _ = self.chans.swapRemove(open.id);
                        self.dropChanWindows(open.id, .client_disconnected);
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
                    self.dropChanWindows(id, .client_disconnected);
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
            self.conn.sendFrame(.log_get, req) catch {
                // The worker is already gone (EPIPE) but may have flushed
                // its post-mortem push before dying — consume the tail of
                // the stream so the stash below serves the final log
                // instead of reporting "no log data".
                _ = self.drainLive(2_000);
                if (self.log_buf.items.len == 0) return Error.NotConnected;
                const json = self.allocator.dupe(u8, self.log_buf.items) catch return Error.OutOfMemory;
                return .{ .json = json, .stale = false };
            };
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
    /// frame backlog is. It negotiates with native/audio/winstream disabled so
    /// no channel replay precedes the reply, and attaches as a non-driver CLI.
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
        conn.sendJson(.hello, .{
            .proto = wire.PROTO_VERSION,
            .min_proto = @as(u32, 1),
            .negotiation = @as(u8, 1),
            .snapshot_max = snapshot.SNAPSHOT_VERSION,
            .native_state_max = @as(u8, 0),
            .audio = false,
            .winstream = false,
            .video = false,
        }) catch return Error.NotConnected;
        (conn.recvExpectFor(&.{.welcome}, @max(deadline - nowMs(), 1)) catch return Error.Timeout).deinit(a);
        // Read-only: this side connection only reads the log ring and
        // must never take the lease off the primary connection.
        conn.sendJson(.attach, .{ .name = self.name, .kind = "cli", .read_only = true }) catch return Error.NotConnected;
        (conn.recvExpectFor(&.{.snapshot}, @max(deadline - nowMs(), 1)) catch return Error.Timeout).deinit(a);
        conn.sendFrame(.log_get, req_json) catch return Error.NotConnected;
        const f = conn.recvExpectFor(&.{.log_data}, @max(deadline - nowMs(), 1)) catch return Error.Timeout;
        defer f.deinit(a);
        return a.dupe(u8, f.payload) catch Error.OutOfMemory;
    }

    fn dropChanWindows(self: *App, chan: u32, reason: PresentationGone) void {
        var removed_toplevel = false;
        var i: usize = 0;
        while (i < self.windows.items.len) {
            if (self.windows.items[i].chan == chan) {
                const w = self.windows.swapRemove(i);
                removed_toplevel = removed_toplevel or !w.popup;
                w.deinit(self.allocator);
                self.allocator.destroy(w);
            } else i += 1;
        }
        if (removed_toplevel) self.noteToplevelRemoval(reason);
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
        if (!popup) {
            self.had_toplevel = true;
            self.presentation_gone = null;
        }
        return w;
    }

    fn noteToplevelRemoval(self: *App, reason: PresentationGone) void {
        if (!self.had_toplevel) return;
        for (self.windows.items) |w| {
            if (!w.popup) return;
        }
        self.presentation_gone = reason;
    }

    /// True once an app that rendered a toplevel has lost its whole GUI.
    pub fn presentationGone(self: *const App) bool {
        return self.presentation_gone != null;
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
            .subsurface_pos = onSubsurfacePos,
            .subsurface_below = onSubsurfaceBelow,
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
        if (!ch.subsurfaces.contains(sid))
            ch.subsurfaces.put(ch.app.allocator, sid, .{}) catch {};
        // Defensive cleanup for a malformed/replayed stream whose
        // frame raced the role notification.
        onSubsurfaceGoneWindow(ch, sid);
    }

    /// A subsurface moved (or restacked): its root window's composite
    /// is stale.
    fn onSubsurfacePos(ctx: ?*anyopaque, sid: u32, x: i32, y: i32) void {
        _ = x;
        _ = y;
        const ch = chanOf(ctx);
        if (!ch.subsurfaces.contains(sid)) return;
        recompositeRootOf(ch, sid);
    }

    fn onSubsurfaceBelow(ctx: ?*anyopaque, sid: u32, below: bool) void {
        _ = below;
        const ch = chanOf(ctx);
        if (!ch.subsurfaces.contains(sid)) return;
        recompositeRootOf(ch, sid);
    }

    /// Recomposite the window whose tree contains `sid`.
    fn recompositeRootOf(ch: *Chan, sid: u32) void {
        const root = ch.comp.rootSurface(sid);
        const win = ch.app.winBySurface(ch.id, root) orelse return;
        recomposite(ch, win);
    }

    /// Rebuild `win.pixels` from the root's own buffer plus every
    /// subsurface layer, bottom to top. A window with no subsurfaces
    /// is a straight copy of the root buffer.
    fn recomposite(ch: *Chan, win: *Window) void {
        const a = ch.app.allocator;
        win.pixels.clearRetainingCapacity();
        if (win.w <= 0 or win.h <= 0) return;
        var layers: std.ArrayList(wlcomp.Compositor.SubLayer) = .empty;
        defer layers.deinit(a);
        ch.comp.subtreeLayers(a, win.sid, &layers) catch {};
        const n_below = wlcomp.Compositor.belowCount(layers.items);
        if (n_below == 0) {
            // Nothing paints under the root: start FROM its buffer
            // instead of blending it over a cleared canvas (the
            // overwhelmingly common shape, and a full-window blend per
            // frame is pure cost).
            win.pixels.appendSlice(a, win.base_pixels.items) catch return;
            if (layers.items.len == 0) return;
        } else {
            const need = @as(usize, @intCast(win.w)) * @as(usize, @intCast(win.h)) * 4;
            win.pixels.appendNTimes(a, 0, need) catch return;
        }
        const paint = struct {
            fn one(chan: *Chan, w: *Window, l: wlcomp.Compositor.SubLayer) void {
                const sp = chan.subsurfaces.getPtr(l.sid) orelse return;
                if (sp.pixels.items.len == 0) return;
                blendLayer(w.pixels.items, w.w, w.h, sp.pixels.items, sp.w, sp.h, l.x, l.y, sp.format);
            }
        }.one;
        if (n_below > 0) {
            for (layers.items[0..n_below]) |l| paint(ch, win, l);
            blendLayer(win.pixels.items, win.w, win.h, win.base_pixels.items, win.w, win.h, 0, 0, win.format);
        }
        for (layers.items[n_below..]) |l| paint(ch, win, l);
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
        // The tree link is already gone by the time this fires, so
        // resolve the root from the parent we still know about.
        const root = ch.comp.rootSurface(sid);
        if (ch.subsurfaces.fetchRemove(sid)) |kv| {
            var sp = kv.value;
            sp.pixels.deinit(ch.app.allocator);
        }
        onSubsurfaceGoneWindow(ch, sid);
        if (ch.app.winBySurface(ch.id, root)) |win| recomposite(ch, win);
    }

    fn onFrame(ctx: ?*anyopaque, sid: u32, w: i32, h: i32, scale: i32, lw: i32, lh: i32, format: u32, pixels: []const u8) void {
        // Headless sessions run at scale 1 (no viewer sends
        // set_scale), so logical == physical here.
        _ = lw;
        _ = lh;
        const ch = chanOf(ctx);
        const win = blk: {
            if (ch.subsurfaces.getPtr(sid)) |sp| {
                // Subsurface content: stash it and recomposite the
                // window it belongs to. This IS the app's repaint for
                // toolkits that render everything into a subsurface
                // (Firefox), so it counts as a window frame.
                sp.w = w;
                sp.h = h;
                sp.format = format;
                sp.pixels.clearRetainingCapacity();
                sp.pixels.appendSlice(ch.app.allocator, pixels) catch {};
                const root = ch.comp.rootSurface(sid);
                const rw = ch.app.winBySurface(ch.id, root) orelse return;
                recomposite(ch, rw);
                break :blk rw;
            }
            const win = ch.app.ensureWindow(ch.id, sid, false) orelse return;
            win.w = w;
            win.h = h;
            win.scale = scale;
            win.format = format;
            win.base_pixels.clearRetainingCapacity();
            win.base_pixels.appendSlice(ch.app.allocator, pixels) catch {};
            recomposite(ch, win);
            break :blk win;
        };
        // A subsurface can commit its content BEFORE the root surface
        // ever attaches a buffer (Firefox does): there is no window
        // image yet, so this is not a presentable frame — counting it
        // would hand waiters a 0x0 window.
        if (win.pixels.items.len == 0) return;
        win.frames += 1;
        win.last_commit_ms = nowMs();
        ch.app.frame_seq += 1;
        ch.app.tickPendingMarkers(win);
        // Recordings take the COMPOSITED window, not the buffer that
        // happened to arrive (a subsurface frame is a fragment of it).
        if (win.id == ch.app.rec_win and win.w > 0 and win.h > 0) {
            const t = nowMs();
            if (ch.app.rec_min_interval_ms <= 0 or t - ch.app.rec_last_add >= ch.app.rec_min_interval_ms) {
                ch.app.rec_last_add = t;
                const wp = win.pixels.items;
                const ww: u32 = @intCast(win.w);
                const wh: u32 = @intCast(win.h);
                if (ch.app.rec) |*r| r.addShmFrame(wp, ww, wh, win.format, t) catch {};
                if (ch.app.vrec) |*r| r.addShmFrame(wp, ww, wh, win.format, t) catch {};
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
        var removed_toplevel = false;
        var i: usize = 0;
        while (i < ch.app.windows.items.len) {
            const w = ch.app.windows.items[i];
            if (w.chan == ch.id and w.sid == sid) {
                _ = ch.app.windows.swapRemove(i);
                removed_toplevel = removed_toplevel or !w.popup;
                w.deinit(ch.app.allocator);
                ch.app.allocator.destroy(w);
                continue;
            }
            i += 1;
        }
        if (removed_toplevel) ch.app.noteToplevelRemoval(.last_toplevel_destroyed);
    }

    // ── waiting ─────────────────────────────────────────────────

    /// Pump until at least one toplevel has pixels (or timeout).
    pub fn waitFirstWindow(self: *App, timeout_ms: i64) bool {
        const deadline = nowMs() + timeout_ms;
        while (nowMs() < deadline) {
            for (self.windows.items) |w| {
                if (!w.popup and w.frames > 0) return true;
            }
            if (self.exited or self.presentationGone()) return false;
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
            if (self.exited or self.presentationGone()) return true;
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

    /// Tell the session's compositor this viewer's display scale x120
    /// (the fractional-scale wire unit: 1.5 -> 180). The brain
    /// re-announces every scale channel, so apps re-render for the new
    /// pixel grid. Test rigs use it to reproduce fractional-scale
    /// desktops on a headless session (which otherwise runs at 1).
    pub fn setViewerScale120(self: *App, scale120: u32) Error!void {
        var pl: [4]u8 = undefined;
        std.mem.writeInt(u32, &pl, scale120, .little);
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(self.allocator);
        wlpipe.appendUnit(&units, self.allocator, .set_scale, &pl) catch return Error.OutOfMemory;
        for (self.chans.keys()) |chan| try self.sendIntents(chan, units.items);
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

    /// Which surface a window-local point belongs to, and the point in
    /// that surface's own coordinates. Window coordinates are the ROOT
    /// surface's, but Wayland input is delivered to the topmost
    /// subsurface under the pointer — Firefox listens on the
    /// subsurface that holds its whole UI, not on the CSD toplevel.
    fn ptrTarget(self: *App, win: *Window, x: f64, y: f64) wlcomp.Compositor.Hit {
        const ch = self.chans.get(win.chan) orelse
            return .{ .sid = win.sid, .x = x, .y = y };
        return ch.comp.hitTest(self.allocator, win.sid, x, y);
    }

    /// Inject enter+motion to (x,y) and move the tracked position.
    fn sendPointer(self: *App, win: *Window, x: f64, y: f64) Error!void {
        const a = self.allocator;
        const hit = self.ptrTarget(win, x, y);
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(a);
        wlpipe.appendSeatEnter(&units, a, hit.sid, hit.x, hit.y) catch return Error.OutOfMemory;
        wlpipe.appendSeatMotion(&units, a, hit.x, hit.y) catch return Error.OutOfMemory;
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
        const hit = self.ptrTarget(win, x, y);
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(a);
        wlpipe.appendSeatEnter(&units, a, hit.sid, hit.x, hit.y) catch return Error.OutOfMemory;
        wlpipe.appendSeatMotion(&units, a, hit.x, hit.y) catch return Error.OutOfMemory;
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
        const hit = self.ptrTarget(win, x, y);
        wlpipe.appendSeatEnter(&units, a, hit.sid, hit.x, hit.y) catch return Error.OutOfMemory;
        // Enter is a no-op when focus is unchanged, so the motion is
        // what actually puts the pointer at the scroll point.
        wlpipe.appendSeatMotion(&units, a, hit.x, hit.y) catch return Error.OutOfMemory;
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
        // The press resolves the target surface; the drag then stays
        // on it (pointer grab), so every motion uses the same offset.
        const hit = self.ptrTarget(win, x1, y1);
        const off_x = x1 - hit.x;
        const off_y = y1 - hit.y;
        wlpipe.appendSeatEnter(&units, a, hit.sid, hit.x, hit.y) catch return Error.OutOfMemory;
        wlpipe.appendSeatMotion(&units, a, hit.x, hit.y) catch return Error.OutOfMemory;
        wlpipe.appendSeatButton(&units, a, evdevButton(button), true) catch return Error.OutOfMemory;
        try self.sendIntents(win.chan, units.items);
        // Real time between the steps, not just a pump. A toolkit
        // DRAG-AND-DROP (as opposed to a pointer-grab drag like a
        // paned divider) is a conversation: the source asks the
        // compositor to start a drag, the destination answers "I accept
        // this", and only an accepted drag turns a button release into a
        // drop. Firing press → motions → release inside one millisecond
        // leaves the client no room to answer, so the release always
        // cancelled instead.
        self.pumpFor(40);
        const dist = @max(@abs(x2 - x1), @abs(y2 - y1));
        const steps: u32 = @intFromFloat(std.math.clamp(dist / 16.0, 8.0, 40.0));
        var i: u32 = 1;
        while (i <= steps) : (i += 1) {
            const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
            units.clearRetainingCapacity();
            wlpipe.appendSeatMotion(&units, a, x1 + (x2 - x1) * t - off_x, y1 + (y2 - y1) * t - off_y) catch return Error.OutOfMemory;
            try self.sendIntents(win.chan, units.items);
            self.pumpFor(12);
        }
        // Settle jiggle: GTK's own drag threshold eats the first ~8px
        // of motion, so a short drag can reach (x2,y2) BEFORE the
        // toolkit calls start_drag — leaving the dnd session zero or
        // one motion events. GTK's drop-target picking never settles
        // on so few (zero -> no target, release cancels the source;
        // one -> an ancestor target can win over the widget under the
        // pointer). A real hand always jitters at the destination, so
        // emulate that: a few sub-pixel-scale motions at the target
        // guarantee the session sees enough movement to pick and
        // accept the right drop target, wherever the threshold fired.
        var j: u32 = 0;
        while (j < 4) : (j += 1) {
            const dy: f64 = if (j % 2 == 0) 1.0 else 0.0;
            units.clearRetainingCapacity();
            wlpipe.appendSeatMotion(&units, a, x2 - off_x, y2 + dy - off_y) catch return Error.OutOfMemory;
            try self.sendIntents(win.chan, units.items);
            self.pumpFor(30);
        }
        self.pumpFor(150);
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

    /// Ask the daemon to attach a debugger to this session's child and
    /// return its raw JSON answer ({ok, pid, tool, text, ...} or
    /// {error}); caller owns it. The daemon is the app's PARENT, which
    /// is the whole reason this round-trip exists: Yama lets it grant a
    /// tracer what a caller in another process tree cannot get.
    ///
    /// `timeout_ms` must exceed the daemon-side debugger deadline this
    /// request carries, or the wait gives up before the reply that is
    /// already on its way.
    pub fn debugBacktrace(self: *App, debugger_ms: i64, timeout_ms: i64) Error![]u8 {
        self.drain();
        if (self.exited) return Error.NotConnected;
        var pbuf: [64]u8 = undefined;
        const payload = std.fmt.bufPrint(&pbuf, "{{\"op\":\"backtrace\",\"timeout_ms\":{d}}}", .{debugger_ms}) catch
            return Error.OutOfMemory;
        self.conn.sendFrame(.app_debug, payload) catch return Error.NotConnected;
        const deadline = nowMs() + timeout_ms;
        while (nowMs() < deadline) {
            const f = self.conn.recvFrameFor(100) catch |err| switch (err) {
                error.Timeout => continue,
                else => return Error.NotConnected,
            };
            defer f.deinit(self.allocator);
            if (f.ftype == .app_debug_data)
                return self.allocator.dupe(u8, f.payload) catch Error.OutOfMemory;
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

    /// Tap raw evdev HARDWARE keycodes on the seat, in order, each as a
    /// press+release with no modifiers.
    ///
    /// The only injection path that can express a key with no codepoint
    /// of its own: `typeText`/`pressKey` map CHARACTERS through
    /// `xkblayout`, which skips every dead keysym, so a dead key is
    /// literally untypable through them. Evdev codes are
    /// keymap-independent — the session keymap decides what each one
    /// means — so `{ 26, 18 }` is `^` then `e` on a Belgian session and
    /// `[` then `e` on a US one.
    pub fn tapKeyCodes(self: *App, win_id: ?u32, codes: []const u32) Error!void {
        const win = try self.resolveKbd(win_id);
        const a = self.allocator;
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(a);
        for (codes) |code| {
            wlpipe.appendSeatKey(&units, a, code, true) catch return Error.OutOfMemory;
            wlpipe.appendSeatKey(&units, a, code, false) catch return Error.OutOfMemory;
        }
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
        /// The window's commit counter for the pixels in this image —
        /// the freshness receipt callers assert against (see
        /// `frameCount` / `waitFrameAfter` / screenshot_app's
        /// `min_frame`).
        frame: u64 = 0,
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
        return self.encodePixelsPng(win.pixels.items, win.w, win.h, win.format, win.frames, max_dim, region, zoom_req, annot);
    }

    /// The crop → mark → zoom → downscale → encode pipeline, over any
    /// shm-layout buffer rather than a live window. Frame timelines
    /// (`watchChanges`) encode STASHED pixels through the same path, so
    /// a thumbnail and a screenshot cannot disagree about geometry.
    pub fn encodePixelsPng(
        self: *App,
        pixels: []const u8,
        pw: i32,
        ph: i32,
        format: u32,
        frame: u64,
        max_dim: u32,
        region: ?Region,
        zoom_req: u32,
        annot: []const marks_mod.Mark,
    ) Error!Shot {
        if (pw <= 0 or ph <= 0 or pixels.len == 0) return Error.NoSuchWindow;
        const uw: u32 = @intCast(pw);
        const uh: u32 = @intCast(ph);
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
            const bytes = png.encodeShm(a, pixels, uw, uh, uw * 4, format) catch
                return Error.OutOfMemory;
            return .{ .png = bytes, .img_w = uw, .img_h = uh, .scale = 1.0, .frame = frame };
        }

        var rgba = png.shmToRgba(a, pixels, uw, uh, uw * 4, format) catch
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
            .frame = frame,
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
    pub fn waitWindowChange(self: *App, win_id: u32, timeout_ms: i64, min_pct: f64, region: ?Region) bool {
        const deadline = nowMs() + timeout_ms;
        while (true) {
            const win = self.winById(win_id) orelse return false;
            if (win.frames != win.shot_frames and
                (min_pct <= 0 or win.pctVsBaseline(region) >= min_pct)) return true;
            if (self.exited or self.presentationGone() or nowMs() >= deadline) return false;
            _ = self.pumpOnce(25);
        }
    }

    /// The window's commit counter (0 = no such window). This is the
    /// frame SEQUENCE NUMBER every observation reports and `min_frame`
    /// asserts against: it only ever increases, so "give me pixels
    /// strictly newer than frame N" becomes expressible instead of
    /// hoping a capture is not stale.
    pub fn frameCount(self: *App, win_id: u32) u64 {
        const win = self.winById(win_id) orelse return 0;
        return win.frames;
    }

    /// Pump until the window's commit counter EXCEEDS `min_frame`
    /// (bounded). False = it never did — the app committed nothing
    /// newer, or it exited. Unlike waitWindowChange/waitChangeSince
    /// this is anchored to a number the caller already holds, so
    /// freshness survives across separate tool calls.
    pub fn waitFrameAfter(self: *App, win_id: u32, min_frame: u64, timeout_ms: i64) bool {
        const deadline = nowMs() + timeout_ms;
        while (true) {
            const win = self.winById(win_id) orelse return false;
            if (win.frames > min_frame) return true;
            if (self.exited or self.presentationGone() or nowMs() >= deadline) return false;
            _ = self.pumpOnce(25);
        }
    }

    /// True when the window no longer exists (destroyed or never
    /// created) — on teardown this flips BEFORE the `.exit` frame is
    /// processed, so pair it with settleExit before judging.
    pub fn windowGone(self: *App, win_id: u32) bool {
        return self.winById(win_id) == null;
    }

    /// Pump briefly so a just-happened teardown's `.exit` frame lands;
    /// true when the session child exited or its last GUI disappeared.
    pub fn settleExit(self: *App, timeout_ms: i64) bool {
        const deadline = nowMs() + timeout_ms;
        while (!self.exited and nowMs() < deadline) _ = self.pumpOnce(25);
        return self.exited or self.presentationGone();
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
    pub fn waitChangeSince(self: *App, win_id: u32, ref: *const FrameRef, timeout_ms: i64, min_pct: f64, region: ?Region) bool {
        const deadline = nowMs() + timeout_ms;
        while (true) {
            if (self.winById(win_id)) |win| {
                if (win.frames != ref.frames) {
                    if (min_pct <= 0 or ref.px.len == 0) return true;
                    if (win.w != ref.w or win.h != ref.h) return true;
                    if (pctDiff(win.pixels.items, ref.px, @intCast(@max(win.w, 0)), region) >= min_pct) return true;
                }
            } else return false;
            if (self.exited or self.presentationGone() or nowMs() >= deadline) return false;
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
            if (self.exited or self.presentationGone()) return true;
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
    pub fn waitVisualSettle(self: *App, win_id: u32, quiet_ms: i64, timeout_ms: i64, max_change_pct: f64, region: ?Region) bool {
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
            if (self.exited or self.presentationGone()) return true;
            _ = self.pumpOnce(25);
            const win = self.winById(win_id) orelse return false;
            if (win.frames != last_frames) {
                last_frames = win.frames;
                const resized = win.w != base_w or win.h != base_h;
                const pct = if (resized) 100.0 else pctDiff(win.pixels.items, base.items, @intCast(@max(win.w, 0)), region);
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

    /// Surface size of a window (null = no such window / never painted).
    pub fn windowSize(self: *App, win_id: u32) ?struct { w: i32, h: i32 } {
        const win = self.winById(win_id) orelse return null;
        if (win.w <= 0 or win.h <= 0) return null;
        return .{ .w = win.w, .h = win.h };
    }

    /// % of pixels currently differing from a `FrameRef`, WITHOUT
    /// waiting and without moving any baseline — the magnitude behind a
    /// `waitChangeSince` that already returned true.
    pub fn peekChangeVs(self: *App, win_id: u32, ref: *const FrameRef, region: ?Region) f64 {
        const win = self.winById(win_id) orelse return 0;
        if (ref.px.len == 0) return 100.0;
        if (win.w != ref.w or win.h != ref.h) return 100.0;
        return pctDiff(win.pixels.items, ref.px, @intCast(@max(win.w, 0)), region);
    }

    /// Monotonic ms at which this window last committed a frame (0 =
    /// no such window, or it has never painted). The pre-input half of
    /// "did my click do nothing, or had the app already stopped
    /// painting before it?" — the same counter the daemon feeds, read
    /// on the caller's clock.
    pub fn lastCommitMs(self: *App, win_id: u32) i64 {
        const win = self.winById(win_id) orelse return 0;
        return win.last_commit_ms;
    }

    /// One recorded change during a `watchChanges` run.
    pub const WatchEvent = struct {
        /// Ms since the watch started.
        at_ms: i64,
        /// The window's commit counter when the change was observed.
        frame: u64,
        /// % of pixels differing from the PREVIOUS recorded event (or
        /// from the watch's opening frame, for the first event).
        pct: f64,
        /// Stashed shm-layout pixels, when thumbnails were asked for.
        /// Empty otherwise. Freed by `WatchResult.deinit`.
        px: []u8 = &.{},
        w: i32 = 0,
        h: i32 = 0,
        format: u32 = 0,
    };

    pub const WatchResult = struct {
        events: []WatchEvent,
        /// Frames the window committed over the whole watch. Nonzero
        /// with no events means it IS painting and the content simply
        /// did not change materially — the distinction that stops
        /// "nothing happened" from being inferred from a still image.
        frames: u64,
        /// The commit counter at the start and at the end.
        frame_first: u64,
        frame_last: u64,
        elapsed_ms: i64,
        /// More changes occurred than `max_events` had room for.
        truncated: bool,
        /// The app exited during the watch.
        exited: bool,

        pub fn deinit(self: *WatchResult, a: std.mem.Allocator) void {
            for (self.events) |e| if (e.px.len > 0) a.free(e.px);
            a.free(self.events);
            self.events = &.{};
        }
    };

    /// Sample a window for `duration_ms`, recording every commit whose
    /// pixels differ from the last recorded one by at least `min_pct`.
    ///
    /// This is the measurement a single screenshot cannot make. An
    /// action with a multi-second pre-roll followed by a short clip is
    /// invisible to sampling — every capture lands before or after it —
    /// and the resulting "nothing happened" reads exactly like a dead
    /// control. A timeline answers "did anything happen, and WHEN"
    /// without knowing in advance what to look for.
    ///
    /// Pixels are stashed for the first `thumbs` events only (a full
    /// window copy each), so a long watch cannot grow without bound.
    pub fn watchChanges(
        self: *App,
        win_id: u32,
        duration_ms: i64,
        min_pct: f64,
        region: ?Region,
        max_events: usize,
        thumbs: usize,
    ) Error!WatchResult {
        const a = self.allocator;
        var events: std.ArrayList(WatchEvent) = .empty;
        errdefer {
            for (events.items) |e| if (e.px.len > 0) a.free(e.px);
            events.deinit(a);
        }
        var base: std.ArrayList(u8) = .empty;
        defer base.deinit(a);
        var base_w: i32 = 0;
        var base_h: i32 = 0;
        var last_frames: u64 = 0;
        var format: u32 = 0;
        {
            const win = self.winById(win_id) orelse return Error.NoSuchWindow;
            base.appendSlice(a, win.pixels.items) catch return Error.OutOfMemory;
            base_w = win.w;
            base_h = win.h;
            last_frames = win.frames;
            format = win.format;
        }
        const first_frame = last_frames;
        const t0 = nowMs();
        const deadline = t0 + duration_ms;
        var truncated = false;
        while (nowMs() < deadline) {
            if (self.exited or self.presentationGone()) break;
            _ = self.pumpOnce(15);
            const win = self.winById(win_id) orelse break;
            if (win.frames == last_frames) continue;
            last_frames = win.frames;
            const resized = win.w != base_w or win.h != base_h;
            const pct = if (resized) 100.0 else pctDiff(win.pixels.items, base.items, @intCast(@max(win.w, 0)), region);
            if (pct < min_pct) continue;
            if (events.items.len >= max_events) {
                truncated = true;
                // Keep sampling: the frame TOTAL stays honest even once
                // the timeline itself is full.
                base.clearRetainingCapacity();
                base.appendSlice(a, win.pixels.items) catch return Error.OutOfMemory;
                base_w = win.w;
                base_h = win.h;
                continue;
            }
            var ev: WatchEvent = .{
                .at_ms = nowMs() - t0,
                .frame = win.frames,
                .pct = pct,
                .w = win.w,
                .h = win.h,
                .format = win.format,
            };
            if (events.items.len < thumbs and win.pixels.items.len > 0)
                ev.px = a.dupe(u8, win.pixels.items) catch &.{};
            events.append(a, ev) catch {
                if (ev.px.len > 0) a.free(ev.px);
                return Error.OutOfMemory;
            };
            base.clearRetainingCapacity();
            base.appendSlice(a, win.pixels.items) catch return Error.OutOfMemory;
            base_w = win.w;
            base_h = win.h;
        }
        const final_frames = self.frameCount(win_id);
        return .{
            .events = events.toOwnedSlice(a) catch return Error.OutOfMemory,
            .frames = final_frames -| first_frame,
            .frame_first = first_frame,
            .frame_last = final_frames,
            .elapsed_ms = nowMs() - t0,
            .truncated = truncated,
            .exited = self.exited,
        };
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
    pub fn peekDiffPct(self: *App, win_id: u32, region: ?Region) f64 {
        const win = self.winById(win_id) orelse return 0;
        // Pixels only change on a commit; same frame counter = same content.
        if (win.frames == win.shot_frames) return 0;
        return win.pctVsBaseline(region);
    }

    /// Cheap "did it change" answer: compare current pixels against the
    /// baseline from the last screenshot/stats call, then move the
    /// baseline forward. No image is encoded.
    pub fn diffStats(self: *App, win_id: u32, region: ?Region) Error!DiffStats {
        const win = self.winById(win_id) orelse return Error.NoSuchWindow;
        if (win.w <= 0 or win.h <= 0 or win.pixels.items.len == 0) return Error.NoSuchWindow;
        const had_baseline = win.shot_pixels.items.len != 0;
        const resized = had_baseline and (win.shot_w != win.w or win.shot_h != win.h);
        const pct = win.pctVsBaseline(region);
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

test "Firefox pattern: subsurface repaints composite into the window image" {
    // The whole UI lives in a subsurface of the CSD toplevel. Dropping
    // those frames (what the replica used to do) left the window frozen
    // on its flat background forever — a black window that never
    // updates. Drive the replica with the real request stream and check
    // the composed image and the input target.
    const t = std.testing;
    const a = t.allocator;
    const wlwire = @import("../wlhost/wire.zig");
    var app = App{ .allocator = a, .conn = undefined, .name = @constCast("test") };
    defer testTeardown(&app);

    var pl: [5]u8 = undefined;
    app.handleFrame(.chan_open, testChanOpenPayload(&pl, 3));
    const ch = app.chans.get(3).?;

    const H = struct {
        fn req(chn: *Chan, msg: []const u8) !void {
            var unit: std.ArrayList(u8) = .empty;
            defer unit.deinit(std.testing.allocator);
            try wlpipe.appendUnit(&unit, std.testing.allocator, .wl_msg, msg);
            try chn.comp.feed(unit.items);
        }
        fn bind(chn: *Chan, name: u32, iface: []const u8, ver: u32, id: u32) !void {
            var buf: [96]u8 = undefined;
            var b = wlwire.Builder.init(&buf, 2, 0);
            b.putUint(name);
            b.putString(iface);
            b.putUint(ver);
            b.putNewId(id);
            try req(chn, try b.finish());
        }
    };
    var buf: [96]u8 = undefined;
    { // get_registry(2)
        var b = wlwire.Builder.init(&buf, 1, 1);
        b.putNewId(2);
        try H.req(ch, try b.finish());
    }
    try H.bind(ch, 1, "wl_compositor", 6, 3);
    try H.bind(ch, 2, "wl_shm", 1, 4);
    try H.bind(ch, 5, "xdg_wm_base", 6, 5);
    try H.bind(ch, 11, "wl_subcompositor", 1, 6);
    { // root surface 7 → xdg_surface 8 → toplevel 9, first commit
        var b = wlwire.Builder.init(&buf, 3, 0);
        b.putNewId(7);
        try H.req(ch, try b.finish());
        var b2 = wlwire.Builder.init(&buf, 5, 2);
        b2.putNewId(8);
        b2.putObject(7);
        try H.req(ch, try b2.finish());
        var b3 = wlwire.Builder.init(&buf, 8, 1);
        b3.putNewId(9);
        try H.req(ch, try b3.finish());
        var b4 = wlwire.Builder.init(&buf, 7, 6);
        try H.req(ch, try b4.finish());
    }
    { // content surface 10 as a subsurface of 7 at (1, 1)
        var b = wlwire.Builder.init(&buf, 3, 0);
        b.putNewId(10);
        try H.req(ch, try b.finish());
        var b2 = wlwire.Builder.init(&buf, 6, 1);
        b2.putNewId(11);
        b2.putObject(10);
        b2.putObject(7);
        try H.req(ch, try b2.finish());
        var b3 = wlwire.Builder.init(&buf, 11, 1);
        b3.putInt(1);
        b3.putInt(1);
        try H.req(ch, try b3.finish());
    }
    { // pool 12 (80 bytes): root 4x4 at 0, content 2x2 at 64
        var b = wlwire.Builder.init(&buf, 4, 0);
        b.putNewId(12);
        b.putInt(80);
        try H.req(ch, try b.finish());
        var px: [80]u8 = undefined;
        var i: usize = 0;
        while (i < 64) : (i += 4) {
            px[i] = 10;
            px[i + 1] = 20;
            px[i + 2] = 30;
            px[i + 3] = 255;
        }
        while (i < 80) : (i += 4) {
            px[i] = 200;
            px[i + 1] = 210;
            px[i + 2] = 220;
            px[i + 3] = 255;
        }
        var unit: std.ArrayList(u8) = .empty;
        defer unit.deinit(a);
        try wlpipe.appendPoolUpdate(&unit, a, 12, 0, &px);
        try ch.comp.feed(unit.items);
        var b2 = wlwire.Builder.init(&buf, 12, 0); // create_buffer(13) root
        b2.putNewId(13);
        b2.putInt(0);
        b2.putInt(4);
        b2.putInt(4);
        b2.putInt(16);
        b2.putUint(0);
        try H.req(ch, try b2.finish());
        var b3 = wlwire.Builder.init(&buf, 12, 0); // create_buffer(14) content
        b3.putNewId(14);
        b3.putInt(64);
        b3.putInt(2);
        b3.putInt(2);
        b3.putInt(8);
        b3.putUint(0);
        try H.req(ch, try b3.finish());
    }
    { // the root attaches its background ONCE
        var b = wlwire.Builder.init(&buf, 7, 1);
        b.putObject(13);
        b.putInt(0);
        b.putInt(0);
        try H.req(ch, try b.finish());
        var b2 = wlwire.Builder.init(&buf, 7, 6);
        try H.req(ch, try b2.finish());
    }
    try t.expectEqual(@as(usize, 1), app.windows.items.len);
    const win = app.windows.items[0];
    try t.expectEqual(@as(i32, 4), win.w);
    try t.expectEqual(@as(u64, 1), win.frames);

    { // ...then only the content subsurface repaints, twice
        var i: usize = 0;
        while (i < 2) : (i += 1) {
            var b = wlwire.Builder.init(&buf, 10, 1);
            b.putObject(14);
            b.putInt(0);
            b.putInt(0);
            try H.req(ch, try b.finish());
            var b2 = wlwire.Builder.init(&buf, 10, 6);
            try H.req(ch, try b2.finish());
        }
    }
    // Those repaints ARE window frames, and there is still exactly one
    // window (the subsurface never becomes selectable).
    try t.expectEqual(@as(usize, 1), app.windows.items.len);
    try t.expectEqual(@as(u64, 3), win.frames);

    // The content landed at (1,1) over the background.
    try t.expectEqual(@as(usize, 64), win.pixels.items.len);
    const px = win.pixels.items;
    const root_rgba = [_]u8{ 10, 20, 30, 255 };
    const sub_rgba = [_]u8{ 200, 210, 220, 255 };
    for (0..4) |y| for (0..4) |x| {
        const off = (y * 4 + x) * 4;
        const want: []const u8 = if (x >= 1 and x <= 2 and y >= 1 and y <= 2)
            &sub_rgba
        else
            &root_rgba;
        try t.expectEqualSlices(u8, want, px[off..][0..4]);
    };

    // Pointer input aims at the subsurface, in ITS coordinates.
    const hit = app.ptrTarget(win, 2, 2);
    try t.expectEqual(@as(u32, 10), hit.sid);
    try t.expectEqual(@as(f64, 1), hit.x);
    try t.expectEqual(@as(f64, 1), hit.y);
    // A point outside it stays on the root.
    const miss = app.ptrTarget(win, 0, 0);
    try t.expectEqual(@as(u32, 7), miss.sid);
}

test "blendLayer: premultiplied alpha, xrgb opacity, clipping" {
    const t = std.testing;
    var dst = [_]u8{0} ** 16; // 2x2 canvas
    // Opaque 1x1 at (1,1).
    const src = [_]u8{ 40, 50, 60, 255 };
    blendLayer(&dst, 2, 2, &src, 1, 1, 1, 1, 0);
    try t.expectEqualSlices(u8, &src, dst[12..16]);
    try t.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0 }, dst[0..4]);

    // Half-transparent (premultiplied) over it: src + dst*(1-a).
    const half = [_]u8{ 10, 10, 10, 128 };
    blendLayer(&dst, 2, 2, &half, 1, 1, 1, 1, 0);
    try t.expectEqual(@as(u8, 10 + 40 * 127 / 255), dst[12]);
    try t.expectEqual(@as(u8, 255), dst[15]);

    // An XRGB source ignores its alpha byte and lands opaque.
    const xrgb = [_]u8{ 1, 2, 3, 0 };
    blendLayer(&dst, 2, 2, &xrgb, 1, 1, 0, 0, 1);
    try t.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 255 }, dst[0..4]);

    // Fully off-canvas offsets touch nothing.
    var before = dst;
    blendLayer(&dst, 2, 2, &src, 1, 1, 9, 9, 0);
    try t.expectEqualSlices(u8, &before, &dst);
    blendLayer(&dst, 2, 2, &src, 1, 1, -9, -9, 0);
    try t.expectEqualSlices(u8, &before, &dst);
    // A partially off-canvas layer clips instead of wrapping.
    const two = [_]u8{ 7, 7, 7, 255, 8, 8, 8, 255 };
    blendLayer(&dst, 2, 2, &two, 2, 1, 1, 0, 0);
    try t.expectEqualSlices(u8, &[_]u8{ 7, 7, 7, 255 }, dst[4..8]);
    before = dst;
    blendLayer(&dst, 2, 2, &two, 2, 1, -1, 0, 0);
    try t.expectEqualSlices(u8, &[_]u8{ 8, 8, 8, 255 }, dst[0..4]);
}

test "presentation lifecycle distinguishes freeze, last toplevel, and client disconnect" {
    const t = std.testing;
    const a = t.allocator;
    var app = App{ .allocator = a, .conn = undefined, .name = @constCast("test") };
    defer testTeardown(&app);

    var pl: [5]u8 = undefined;
    app.handleFrame(.chan_open, testChanOpenPayload(&pl, 9));
    const ch = app.chans.get(9).?;
    const px = [_]u8{ 1, 2, 3, 4 };
    App.onFrame(ch, 1, 1, 1, 1, 1, 1, 0, &px);
    App.onFrame(ch, 2, 1, 1, 1, 1, 1, 0, &px);
    try t.expect(app.had_toplevel);
    try t.expect(!app.presentationGone());

    // No commits is merely a visually frozen app, not a disconnect.
    try t.expect(!app.presentationGone());
    App.onGone(ch, 1);
    try t.expect(!app.presentationGone()); // another toplevel survives
    App.onGone(ch, 2);
    try t.expectEqual(App.PresentationGone.last_toplevel_destroyed, app.presentation_gone.?);

    // A replacement toplevel makes the presentation live again.
    App.onFrame(ch, 3, 1, 1, 1, 1, 1, 0, &px);
    try t.expect(!app.presentationGone());
    var id: [4]u8 = undefined;
    std.mem.writeInt(u32, &id, 9, .little);
    app.handleFrame(.chan_close, &id);
    try t.expectEqual(App.PresentationGone.client_disconnected, app.presentation_gone.?);
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

test "pctDiffRegion: scoped diff, clamping, out-of-bounds rects" {
    const t = std.testing;
    // 4x4 window; base all zero, cur differs in the 2x2 top-left block.
    var base = [_]u8{0} ** (4 * 4 * 4);
    var cur = [_]u8{0} ** (4 * 4 * 4);
    for (0..2) |y| for (0..2) |x| {
        cur[(y * 4 + x) * 4] = 0xff;
    };
    // Whole-buffer diff sees 4/16 = 25%.
    try t.expectApproxEqAbs(@as(f64, 25.0), pctDiffBuf(&cur, &base), 0.001);
    try t.expectApproxEqAbs(@as(f64, 25.0), pctDiff(&cur, &base, 4, null), 0.001);
    // Region covering exactly the changed block: 100%.
    try t.expectApproxEqAbs(@as(f64, 100.0), pctDiffRegion(&cur, &base, 4, .{ .x = 0, .y = 0, .w = 2, .h = 2 }), 0.001);
    // Region covering only unchanged pixels: 0%.
    try t.expectApproxEqAbs(@as(f64, 0.0), pctDiffRegion(&cur, &base, 4, .{ .x = 2, .y = 2, .w = 2, .h = 2 }), 0.001);
    // Partially out-of-bounds rect is clamped (covers the right 2x4
    // strip = 0 changed).
    try t.expectApproxEqAbs(@as(f64, 0.0), pctDiffRegion(&cur, &base, 4, .{ .x = 2, .y = 0, .w = 10, .h = 10 }), 0.001);
    // Fully out-of-bounds rect: 0 (never a false "changed" verdict).
    try t.expectApproxEqAbs(@as(f64, 0.0), pctDiffRegion(&cur, &base, 4, .{ .x = 8, .y = 8, .w = 2, .h = 2 }), 0.001);
    // Mismatched buffers stay 100 regardless of region.
    try t.expectApproxEqAbs(@as(f64, 100.0), pctDiffRegion(cur[0..32], &base, 4, .{ .x = 0, .y = 0, .w = 2, .h = 2 }), 0.001);
}

test "post-mortem log push + exit are peeled when EOF lands in the same read" {
    const t = std.testing;
    const a = t.allocator;
    var fds: [2]c_int = undefined;
    try t.expect(c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &fds) == 0);
    // The whole 16 KiB stream is written below in ONE blocking write,
    // before anything reads — so it has to fit in the socket buffers.
    // Linux's default unix-socket buffer (~208 KiB) swallows it; Darwin's
    // is 8 KiB, which deadlocks the write against a reader that only runs
    // afterwards. Ask for room on both ends and on both directions.
    const bufsize: c_int = 256 * 1024;
    for (fds) |fd| {
        for ([_]c_int{ c.SO_SNDBUF, c.SO_RCVBUF }) |opt| {
            _ = c.setsockopt(fd, c.SOL_SOCKET, opt, &bufsize, @sizeOf(c_int));
        }
    }
    var app = App{
        .allocator = a,
        .conn = .{ .allocator = a, .fd = fds[0] },
        .name = @constCast("test"),
    };
    defer {
        app.log_buf.deinit(a);
        app.conn.rbuf.deinit(a);
        app.conn.wbuf.deinit(a);
        _ = c.close(fds[0]);
        testTeardown(&app);
    }

    // Size the stream to EXACTLY one fillAvailable read buffer (16384):
    // the first read() consumes both frames, the second hits EOF in the
    // SAME fillAvailable call — the branch that used to strand them.
    const read_buf = 16384;
    const exit_frame = 5 + 4;
    const log_payload_len = read_buf - exit_frame - 5;
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(a);
    const head = "{\"lines\":[{\"id\":1,\"t\":0,\"text\":\"SENTINEL-BEFORE-CRASH\"}],\"pad\":\"";
    try payload.appendSlice(a, head);
    while (payload.items.len < log_payload_len - 2) try payload.append(a, 'x');
    try payload.appendSlice(a, "\"}");
    try t.expectEqual(@as(usize, log_payload_len), payload.items.len);

    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(a);
    try wire.appendFrame(&stream, a, .log_data, payload.items);
    var st: [4]u8 = undefined;
    std.mem.writeInt(i32, &st, -11, .little);
    try wire.appendFrame(&stream, a, .exit, &st);
    try t.expectEqual(@as(usize, read_buf), stream.items.len);
    try t.expect(c.write(fds[1], stream.items.ptr, stream.items.len) == stream.items.len);
    _ = c.close(fds[1]);

    while (app.pumpOnce(100)) {}
    try t.expect(app.exited);
    try t.expectEqual(@as(i32, -11), app.exit_status);
    try t.expectEqualSlices(u8, payload.items, app.log_buf.items);
}
