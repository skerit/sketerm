//! sketerm-mux daemon core: sessions that outlive GUI clients.
//!
//! Single-threaded poll loop — no GLib, no GTK, no worker threads.
//! Each session owns a PTY + Parser + authoritative Screen. PTY
//! output is parsed once; events are applied to the Screen AND
//! broadcast (wire-serialized) to every attached client. A client
//! that attaches mid-stream gets a full snapshot first, then the
//! live event stream — that is the whole reattach story.
//!
//! Dependencies: libc (PTY, poll) + the GTK-free terminal core.
//! Must stay linkable without GTK so the daemon deploys to servers
//! as one lean binary.

const std = @import("std");
const c = @import("../c.zig").c;
const log = @import("log.zig");
const wire = @import("wire.zig");
const wlwire = @import("../wlhost/wire.zig");
const wltrack = @import("../wlhost/track.zig");
const dmabuf = @import("../wlhost/dmabuf.zig");
const dmabuf_egl = @import("dmabuf_egl.zig");
const pulse = @import("pulse.zig");
const opuscodec = @import("opuscodec.zig");
const wavcap = @import("wavcap.zig");
const xwayland = @import("xwayland.zig");
const wlproto = @import("../wlhost/protocol.zig");
const wlpipe = @import("../wlhost/pipe.zig");
const icons = @import("icons.zig");
const wlpixcodec = @import("../wlhost/pixcodec.zig");
const wlcomp = @import("../wlhost/compositor.zig");
const wlkeymaps = @import("../wlhost/keymaps.zig");
const a11yhub = @import("a11yhub.zig");
const cast_rec = @import("cast.zig");
const daemon_cast = @import("daemon_cast.zig");
const kitty_image = @import("../parser/kitty_image.zig");
const logring = @import("logring.zig");
const fsserve = @import("fsserve.zig");
const fsjournal = @import("fsjournal.zig");
const fs_boundary = @import("fs_boundary.zig");
const build_options = @import("build_options");
const version = @import("../version.zig");
const wlvcodec = @import("../wlhost/vcodec.zig");
const churnmod = @import("../util/churn.zig");
const contentmod = @import("../util/content.zig");
const wsproto = @import("../winstream/proto.zig");
const wssource = @import("../winstream/source.zig");
const WsSource = wssource.Source;
const snapshot = @import("snapshot.zig");
const lsp_proc = @import("../lsp/proc.zig");
const lsp_servers = @import("../lsp/servers.zig");
const webfindbin = @import("../web/findbin.zig");
const webpresence = @import("../web/webpresence.zig");
const shell_util = @import("shell.zig");
const platform = @import("../util/platform.zig");
const lifetime = @import("../util/lifetime.zig");
const Pty = @import("../pty.zig").Pty;
const Parser = @import("../parser/vt.zig").Parser;
const Event = @import("../parser/event.zig").Event;
const Screen = @import("../grid/screen.zig").Screen;
const Pool = @import("../grid/style_pool.zig").Pool;

/// Wall clock — ONLY for log-line timestamps a client renders as "how
/// long ago"; everything scheduling-related stays on `nowMs`.
const wallMs = @import("../util/clock.zig").wallMs;

/// The daemon's own clock. Idle durations are computed daemon-side
/// (never as a client-vs-daemon timestamp diff) so a remote client whose
/// clock differs still sees the right age.
const nowMs = @import("../util/clock.zig").nowMs;

/// The working directory of a session's child via `/proc/<pid>/cwd`. The
/// daemon owns the PID, so this is authoritative even when the shell never
/// emits OSC 7 — clients (which have no local pid for a daemon-backed pane)
/// rely on it for `list` and layout-save. Writes into `buf`, returns the
/// slice or null. Linux-only; harmless elsewhere (readlink fails → null).
/// Working directory of a live session's child. The Linux-vs-macOS
/// split lives in the platform layer — see `platform.cwdOfPid`.
pub const cwdOfPid = platform.cwdOfPid;

// Control-frame JSON payload schemas moved to wire.zig (the
// compatibility surface); re-exported here so daemon-side callers and
// older import paths keep working unchanged.
pub const SpawnReq = wire.SpawnReq;
pub const SpawnShellIntegration = wire.SpawnShellIntegration;
pub const AttachReq = wire.AttachReq;
pub const KillReq = wire.KillReq;
pub const ControlReq = wire.ControlReq;
pub const LogGetReq = wire.LogGetReq;
pub const RenameReq = wire.RenameReq;
pub const SessionInfo = wire.SessionInfo;

/// A session answers to its current mutable name and to the immutable name it
/// was spawned under, so a child that captured `$SKETERM_SESSION` before a
/// rename can still attach. There is deliberately no history beyond that: an
/// unbounded set of names a session answers to is a routing hazard, not a
/// feature anyone asked for.
fn identityMatches(current: []const u8, origin: []const u8, candidate: []const u8) bool {
    return std.mem.eql(u8, current, candidate) or std.mem.eql(u8, origin, candidate);
}

pub const SESSION_ORIGIN_ID_BYTES = wire.SESSION_ORIGIN_ID_BYTES;
pub const SESSION_ORIGIN_ID_LEN = wire.SESSION_ORIGIN_ID_LEN;
pub const SessionOriginId = wire.SessionOriginId;
pub const validSessionOriginId = wire.validSessionOriginId;

/// Mint a process-independent session incarnation identity.
pub fn newSessionOriginId() !SessionOriginId {
    var random: [SESSION_ORIGIN_ID_BYTES]u8 = undefined;
    if (c.getentropy(&random, random.len) != 0) return error.RandomFailed;
    return std.fmt.bytesToHex(random, .lower);
}

/// Upper bound on session names; also sizes the fixed broker/worker
/// rename control datagrams ('R'/'N' buffers).
pub const MAX_SESSION_NAME = wire.MAX_SESSION_NAME;

/// True when a rename target fits the control-channel name bound.
pub fn validSessionName(name: []const u8) bool {
    return name.len >= 1 and name.len <= MAX_SESSION_NAME;
}

/// Replace the mutable name. The immutable origin name and id never move.
fn renameIdentity(allocator: std.mem.Allocator, current: *[]u8, new_name: []const u8) error{OutOfMemory}!void {
    if (std.mem.eql(u8, current.*, new_name)) return;
    const fresh = try allocator.dupe(u8, new_name);
    allocator.free(current.*);
    current.* = fresh;
}

test "session origin IDs are valid and unique across same-name lifetimes" {
    const first = try newSessionOriginId();
    const second = try newSessionOriginId();
    try std.testing.expect(validSessionOriginId(&first));
    try std.testing.expect(validSessionOriginId(&second));
    try std.testing.expect(!std.mem.eql(u8, &first, &second));
}

test "a renamed session still answers to its immutable spawn name" {
    const t = std.testing;
    var current = try t.allocator.dupe(u8, "spawn-name");
    defer t.allocator.free(current);
    const origin = "spawn-name";
    try renameIdentity(t.allocator, &current, "current-name");
    try t.expect(identityMatches(current, origin, "spawn-name"));
    try t.expect(identityMatches(current, origin, "current-name"));
    try t.expect(!identityMatches(current, origin, "unrelated"));
}

test "a dead rename requester frees the pending worker rename slot" {
    const t = std.testing;
    const a = t.allocator;
    var empty: [0]u8 = .{};
    var d = Daemon{ .allocator = a, .listen_fd = -1, .sock_path = empty[0..] };
    defer d.clients.deinit(a);
    const cl = try a.create(Client);
    cl.* = .{ .allocator = a, .fd = -1, .id = 7, .dead = true };
    try d.clients.append(a, cl);
    d.worker_rename_request = .{ .request_id = 3, .requester_id = 7 };
    d.reap();
    try t.expect(d.worker_rename_request == null);
    try t.expectEqual(@as(usize, 0), d.clients.items.len);
}

test "reap drops a dead client's in-flight listing before freeing the client" {
    const t = std.testing;
    const a = t.allocator;
    var empty: [0]u8 = .{};
    var d = Daemon{ .allocator = a, .listen_fd = -1, .sock_path = empty[0..] };
    defer d.clients.deinit(a);
    defer d.fs_listings.deinit(a);

    const cl = try a.create(Client);
    cl.* = .{ .allocator = a, .fd = -1, .id = 11 };
    try d.clients.append(a, cl);

    // A plain `fs_op list` (no view): dropFsViewAt does not cover it,
    // so only reap's own fs_listings sweep can retire it. Without one,
    // pumpFsListings reads listing.client.dead after the free.
    var arena = std.heap.ArenaAllocator.init(a);
    const names = try arena.allocator().alloc([]u8, 0);
    const listing = try a.create(FsListing);
    listing.* = .{
        .allocator = a,
        .arena = arena,
        .client = cl,
        .req = 1,
        .path = try a.dupe(u8, "/tmp"),
        .attrs = try a.dupe(u8, ""),
        .names = names,
        .view = null,
    };
    try d.fs_listings.append(a, listing);

    cl.dead = true;
    d.reap();
    try t.expectEqual(@as(usize, 0), d.fs_listings.items.len);
    try t.expectEqual(@as(usize, 0), d.clients.items.len);
}

pub const Session = struct {
    /// What feeds this session's parser. `.pty` is the normal child
    /// shell/app; `.cast` replays an asciicast file on a timer and
    /// has NO child process — never assume `.pty` (use the helpers
    /// below; `masterFd`/`childPid` degrade to -1 for casts).
    pub const Source = union(enum) {
        pty: Pty,
        cast: *daemon_cast.CastPlayback,
    };

    allocator: std.mem.Allocator,
    name: []u8,
    /// Immutable spawn name exported as SKETERM_SESSION for legacy addressing.
    origin_name: []u8,
    /// Immutable lifetime-unique session incarnation identity.
    origin_id: SessionOriginId,
    source: Source,
    parser: Parser,
    pool: *Pool,
    screen: *Screen,
    /// Sequence number of the NEXT event to be broadcast.
    seq: u64 = 0,
    /// Monotonic-ms timestamp of the last PTY output that produced parser
    /// events (real terminal activity). Drives the active/idle indicator in
    /// `list` — computed daemon-side so detached sessions are observable with
    /// no client attached. Seeded at spawn (a fresh session is "active").
    last_activity_ms: i64 = 0,
    /// Latched by the first kitty image this session dropped, so the
    /// warning explaining a vanished image is logged once per lifetime.
    kitty_drop_warned: bool = false,
    /// Foreground process name on the pty, for the GUI's
    /// `{{ PROGRAM }}` title placeholder. Sampled off the back of PTY
    /// output only (never on a timer), so an idle daemon stays idle;
    /// pushed to attached clients only when it CHANGES.
    fg_program: [32]u8 = undefined,
    fg_program_len: u8 = 0,
    fg_sampled_ms: i64 = 0,
    exited: bool = false,
    exit_status: i32 = 0,
    /// Spawned via `sketerm app -u` — a forwarded GUI app, not a shell.
    app: bool = false,
    /// The child relaxed Yama before exec (SpawnReq.debuggable), so
    /// `app_debug` may attach a debugger to it. False = refuse rather
    /// than spawn a gdb that can only ever report EPERM.
    debuggable: bool = false,
    /// External display session: the child is the `--keep` keeper and
    /// the session exists to own the Wayland/audio hubs for a process
    /// sketerm never spawned.
    display: bool = false,
    /// Optional rootless X11 server attached to this Wayland compositor.
    xwayland: ?xwayland.Instance = null,
    /// Virtual output mode advertised to applications in this session.
    output_width: u32 = wlcomp.DEFAULT_OUTPUT_WIDTH,
    output_height: u32 = wlcomp.DEFAULT_OUTPUT_HEIGHT,
    /// Unoccupied TTL (ms, 0 = none) and the monotonic stamp since the
    /// session last had neither a viewer nor a live external Wayland client.
    /// Zero means occupied. Seeded at spawn so an abandoned session expires.
    ttl_ms: i64 = 0,
    no_viewer_since_ms: i64 = 0,
    /// The attached client currently allowed to drive this session's
    /// Wayland seat (null = nobody). Every other viewer is read-only:
    /// its input-shaped pipe units are dropped daemon-side. Cleared
    /// when that client detaches or dies (see releaseControl).
    controller: ?*Client = null,
    /// GPU opt-in (SpawnReq.gpu): the session's compositor announces
    /// linux-dmabuf and the child keeps its real GL driver.
    gpu: bool = false,
    /// Lowest state-sync version a replica must speak to render this
    /// session's forwarded apps. Raised past the legacy floor by
    /// compositor features an older replica cannot parse: v7 for
    /// modifier-backed dmabufs, v8 for linux-dmabuf v4 feedback. A
    /// viewer below it simply never gets the native channel.
    native_state_min: u8 = wire.LEGACY_NATIVE_STATE_VERSION,
    /// Compiled xkb keymap for this session's app keyboards (points
    /// at an embedded wlhost/keymaps.zig blob; never freed).
    kb_keymap: []const u8 = wlcomp.us_keymap,
    /// Private a11y D-Bus session bus for a forwarded-app session —
    /// the daemon reads the app's AT-SPI tree from it. Null = none.
    a11y: ?a11yhub.Hub = null,
    /// Wayland app forwarding: the daemon IS the Wayland display —
    /// wl_hub_fd listens on the session's display socket itself, sets
    /// the shell's $WAYLAND_DISPLAY, and each app connection is parsed
    /// + shm-mirrored (Channel.native) and tunneled to the attached
    /// client as a byte channel. -1 = no Wayland support this session.
    wl_hub_fd: c_int = -1,
    /// Owned display socket path, unlinked on teardown.
    wl_display_path: ?[]u8 = null,
    /// xdg-foreign handle namespace shared by every Wayland connection
    /// of this session — each connection has its own Compositor, so
    /// only a shared registry lets one client import a handle another
    /// exported (the portal dialog case). Torn down after the session's
    /// channels, which is the order removeSession/reap already use.
    foreign: wlcomp.ForeignRegistry = .{},
    /// Audio hub: the daemon IS the session's PulseAudio server
    /// (mux/pulse.zig). -1 = no audio forwarding for this session.
    pa_hub_fd: c_int = -1,
    /// Owned audio socket path, unlinked on teardown.
    pa_socket_path: ?[]u8 = null,
    /// Owned WAV-capture path base (SpawnReq.audio_capture). Non-null
    /// = tee every stream's PCM to "<base>.wav" / "<base>-N.wav".
    audio_capture_base: ?[]u8 = null,
    /// Next capture-file ordinal (1 = plain "<base>.wav").
    next_capture_id: u32 = 1,
    /// Isolated session (`sketerm app -i`): owned private runtime-dir
    /// path, recursively removed on teardown. null = not isolated.
    runtime_dir_path: ?[]u8 = null,
    /// Window-stream agent (pixel capture, no display protocol):
    /// the macOS backend, or the stub for pipeline testing
    /// (SKETERM_WINSTREAM=stub). Mutually exclusive with Wayland
    /// forwarding.
    winstream: ?*WsSource = null,
    /// Live asciicast v2 recording of this session's PTY output
    /// (rec_start/rec_stop). Survives client detach.
    cast_recorder: ?cast_rec.Rec = null,
    /// Indexed escape-free log of the child's output (log_get / MCP
    /// app_log): one monotonically-increasing id per line, bounded.
    log: logring.LogRing,
    pub fn deinit(self: *Session) void {
        if (self.xwayland) |*xwl| xwl.deinit();
        self.log.deinit();
        if (self.cast_recorder) |*rec| rec.finish();
        if (self.winstream) |ws| {
            ws.deinit();
            self.allocator.destroy(ws);
        }
        if (self.wl_hub_fd >= 0) _ = c.close(self.wl_hub_fd);
        if (self.pa_hub_fd >= 0) _ = c.close(self.pa_hub_fd);
        var z_buf: [4096]u8 = undefined;
        if (self.wl_display_path) |p| {
            if (pathZ(&z_buf, p)) |z| _ = c.unlink(z) else |_| {}
            self.allocator.free(p);
        }
        if (self.pa_socket_path) |p| {
            if (pathZ(&z_buf, p)) |z| _ = c.unlink(z) else |_| {}
            self.allocator.free(p);
        }
        if (self.audio_capture_base) |p| self.allocator.free(p);
        if (self.runtime_dir_path) |p| {
            pathz.removeTree(p);
            self.allocator.free(p);
        }
        if (self.a11y) |*h| h.deinit();
        self.foreign.deinit();
        switch (self.source) {
            .pty => |*p| if (p.closeAndReap()) |code| {
                self.exit_status = code;
            },
            .cast => |cp| cp.destroy(),
        }
        self.parser.deinit();
        self.screen.deinit();
        self.pool.deinit();
        self.allocator.destroy(self.pool);
        self.allocator.free(self.name);
        self.allocator.free(self.origin_name);
        self.allocator.destroy(self);
    }

    /// Screen sink: DSR/DA replies go straight back to the child.
    /// A cast session has no child — replies are safely discarded.
    pub fn sinkWritePty(ctx: ?*anyopaque, bytes: []const u8) void {
        const self: *Session = @ptrCast(@alignCast(ctx.?));
        self.writeToChild(bytes);
    }

    /// Hand bytes to the child's PTY: delivered now, or queued for the
    /// poll loop's POLLOUT drain (`Daemon.flushSessionInput`). The only
    /// refusal is the queue cap, and it is logged once per episode
    /// rather than swallowed. Cast sessions have no child: dropped.
    pub fn writeToChild(self: *Session, bytes: []const u8) void {
        const pty = self.ptyPtr() orelse return;
        const r = pty.writeAll(bytes);
        if (r.first_drop) {
            log.warn("session '{s}': child is not reading its terminal and {d} KiB of input are already waiting; refusing further input until it drains ({d} B dropped)", .{
                self.name, pty.queuedBytes() / 1024, r.dropped,
            });
        }
    }

    pub fn ptyPtr(self: *Session) ?*Pty {
        return switch (self.source) {
            .pty => |*p| p,
            .cast => null,
        };
    }

    pub fn castPtr(self: *Session) ?*daemon_cast.CastPlayback {
        return switch (self.source) {
            .pty => null,
            .cast => |cp| cp,
        };
    }

    pub fn isCast(self: *const Session) bool {
        return self.source == .cast;
    }

    /// -1 for cast sessions (nothing to poll).
    pub fn masterFd(self: *const Session) c_int {
        return switch (self.source) {
            .pty => |p| p.master_fd,
            .cast => -1,
        };
    }

    /// -1 for cast sessions (mirrors a remote pty's "no child").
    pub fn childPid(self: *const Session) c.pid_t {
        return switch (self.source) {
            .pty => |p| p.child_pid,
            .cast => -1,
        };
    }

    pub fn matchesName(self: *const Session, candidate: []const u8) bool {
        return identityMatches(self.name, self.origin_name, candidate);
    }

    pub fn renameTo(self: *Session, new_name: []const u8) !void {
        try renameIdentity(self.allocator, &self.name, new_name);
    }
};

/// Broker-side record of a forked session worker. The broker holds no Screen;
/// it tracks just enough to route clients (control_fd), answer `list` (cached
/// metadata pushed by the worker, filled in B3), and reap (pid + dead).
pub const Worker = struct {
    allocator: std.mem.Allocator,
    name: []u8,
    origin_name: []u8,
    origin_id: SessionOriginId,
    pid: c.pid_t,
    /// Broker end of the broker↔worker control socketpair. Carries passed
    /// client fds (SCM_RIGHTS), kill/rename control bytes, and metadata pushes.
    control_fd: c_int,
    dead: bool = false,
    /// Spawn handshake: the broker defers the spawn `.ok`/`.err` reply until
    /// the worker confirms its session is up ('Y' ready) or dies first
    /// (control EOF before ready = spawn failed). `pending_client` is the
    /// client awaiting that reply (blocked in recvExpect(.ok)); validated
    /// against the live client list before use (the GUI could vanish).
    ready: bool = false,
    pending_client: ?*Client = null,
    /// Cached for `list`, kept current by the worker's metadata pushes ('M'
    /// control datagrams). `last_activity_ms` is on the shared CLOCK_MONOTONIC
    /// clock (same machine), so the broker computes idle_ms straight off it.
    rows: u16 = 24,
    cols: u16 = 80,
    exited: bool = false,
    app: bool = false,
    n_clients: u32 = 0,
    last_activity_ms: i64 = 0,
    /// The SESSION's child pid on this host (not the worker's own pid) —
    /// carried in the 'Y' ready datagram so the spawn `.ok` can ship it.
    child_pid: i32 = 0,
    display: bool = false,
    xwayland: bool = false,
    gpu: bool = false,
    output_width: u32 = wlcomp.DEFAULT_OUTPUT_WIDTH,
    output_height: u32 = wlcomp.DEFAULT_OUTPUT_HEIGHT,
    ttl_secs: u32 = 0,
    viewers: u32 = 0,
    /// Last-pushed audio-playing state (see SessionInfo.audio).
    audio: bool = false,
    audio_streams: []pulse.AudioInfo = &.{},
    /// Owned copies of the worker's last-pushed title / cwd (null = none yet).
    title: ?[]u8 = null,
    cwd: ?[]u8 = null,
    /// Owned session environment paths, learned from the 'Y' ready
    /// datagram (the broker never creates these — the worker owns the
    /// hubs) and refreshed by 'M' pushes so `list` can serve them.
    wl_display: ?[]u8 = null,
    pulse_server: ?[]u8 = null,
    runtime_dir: ?[]u8 = null,
    x_display: ?[]u8 = null,
    xauthority: ?[]u8 = null,
    /// Controller label pushed by the worker ("" / null = nobody).
    controller: ?[]u8 = null,
    /// The worker's reported spawn-failure reason ('E' control datagram,
    /// sent just before it dies), surfaced in the deferred `.err` reply.
    spawn_err: ?[]u8 = null,

    pub fn deinit(self: *Worker) void {
        if (self.control_fd >= 0) _ = c.close(self.control_fd);
        self.allocator.free(self.name);
        self.allocator.free(self.origin_name);
        if (self.title) |t| self.allocator.free(t);
        if (self.cwd) |cw| self.allocator.free(cw);
        if (self.spawn_err) |e| self.allocator.free(e);
        if (self.wl_display) |p| self.allocator.free(p);
        if (self.pulse_server) |p| self.allocator.free(p);
        if (self.runtime_dir) |p| self.allocator.free(p);
        if (self.x_display) |p| self.allocator.free(p);
        if (self.xauthority) |p| self.allocator.free(p);
        if (self.controller) |p| self.allocator.free(p);
        self.freeAudioInfos(self.audio_streams);
        self.allocator.destroy(self);
    }

    pub fn matchesName(self: *const Worker, candidate: []const u8) bool {
        return identityMatches(self.name, self.origin_name, candidate);
    }

    pub fn renameTo(self: *Worker, new_name: []const u8) !void {
        try renameIdentity(self.allocator, &self.name, new_name);
    }

    /// Replace an owned optional string field with a copy of `val`
    /// ("" keeps the field null). Silently keeps the old value on OOM —
    /// stale metadata beats losing the record.
    pub fn setOwned(self: *Worker, slot: *?[]u8, val: []const u8) void {
        if (val.len == 0) return;
        const fresh = self.allocator.dupe(u8, val) catch return;
        if (slot.*) |old| self.allocator.free(old);
        slot.* = fresh;
    }

    fn freeAudioInfos(self: *Worker, infos: []pulse.AudioInfo) void {
        for (infos) |info| {
            if (info.application.len > 0) self.allocator.free(info.application);
            if (info.binary.len > 0) self.allocator.free(info.binary);
            if (info.media.len > 0) self.allocator.free(info.media);
            if (info.icon.len > 0) self.allocator.free(info.icon);
        }
        if (infos.len > 0) self.allocator.free(infos);
    }

    fn cloneAudioInfos(self: *Worker, src: []const pulse.AudioInfo) ![]pulse.AudioInfo {
        if (src.len == 0) return &.{};
        const out = try self.allocator.alloc(pulse.AudioInfo, src.len);
        var filled: usize = 0;
        errdefer {
            for (out[0..filled]) |info| {
                if (info.application.len > 0) self.allocator.free(info.application);
                if (info.binary.len > 0) self.allocator.free(info.binary);
                if (info.media.len > 0) self.allocator.free(info.media);
                if (info.icon.len > 0) self.allocator.free(info.icon);
            }
            self.allocator.free(out);
        }
        for (src) |info| {
            var copy = pulse.AudioInfo{ .pid = info.pid, .running = info.running };
            errdefer {
                if (copy.application.len > 0) self.allocator.free(copy.application);
                if (copy.binary.len > 0) self.allocator.free(copy.binary);
                if (copy.media.len > 0) self.allocator.free(copy.media);
                if (copy.icon.len > 0) self.allocator.free(copy.icon);
            }
            if (info.application.len > 0) copy.application = try self.allocator.dupe(u8, info.application);
            if (info.binary.len > 0) copy.binary = try self.allocator.dupe(u8, info.binary);
            if (info.media.len > 0) copy.media = try self.allocator.dupe(u8, info.media);
            if (info.icon.len > 0) copy.icon = try self.allocator.dupe(u8, info.icon);
            out[filled] = copy;
            filled += 1;
        }
        return out;
    }

    pub fn setAudioInfos(self: *Worker, src: []const pulse.AudioInfo) void {
        const fresh = self.cloneAudioInfos(src) catch return;
        self.freeAudioInfos(self.audio_streams);
        self.audio_streams = fresh;
    }
};

/// Worker-side record of an attached client's rename, forwarded to the broker.
pub const WorkerRenameRequest = struct {
    request_id: u64,
    requester_id: u32,
};

/// Worker→broker 'Y' ready datagram (JSON). Older workers sent a bare
/// decimal pid; `parseWorkerReady` accepts both.
pub const WorkerReady = struct {
    pid: i32 = 0,
    wl: []const u8 = "",
    pa: []const u8 = "",
    rt: []const u8 = "",
    x: []const u8 = "",
    xa: []const u8 = "",
    xwayland: bool = false,
    gpu: bool = false,
    output_width: u32 = wlcomp.DEFAULT_OUTPUT_WIDTH,
    output_height: u32 = wlcomp.DEFAULT_OUTPUT_HEIGHT,
    /// Repeated from the worker so a broker never acknowledges a mismatched
    /// fork-time identity.
    origin_id: []const u8 = "",
};

/// Worker→broker metadata push payload (JSON over the 'M' control datagram).
/// Excludes the session name — that is broker-authoritative (rename updates
/// `Worker.name`; a stale name in a push must never clobber it).
pub const WorkerMeta = struct {
    rows: u16 = 24,
    cols: u16 = 80,
    clients: u32 = 0,
    exited: bool = false,
    app: bool = false,
    activity: i64 = 0,
    child_pid: i32 = 0,
    title: []const u8 = "",
    cwd: []const u8 = "",
    /// Session identity/environment the broker cannot observe itself
    /// (it owns no Screen and creates no hubs) but must answer `list`
    /// with. Paths repeat on every push — cheap, and it keeps the
    /// broker correct after a restart-free worker re-setup.
    display: bool = false,
    xwayland: bool = false,
    gpu: bool = false,
    output_width: u32 = wlcomp.DEFAULT_OUTPUT_WIDTH,
    output_height: u32 = wlcomp.DEFAULT_OUTPUT_HEIGHT,
    ttl_secs: u32 = 0,
    viewers: u32 = 0,
    controller: []const u8 = "",
    /// An uncorked audio stream is playing (see SessionInfo.audio).
    audio: bool = false,
    audio_streams: []const pulse.AudioInfo = &.{},
    wl: []const u8 = "",
    pa: []const u8 = "",
    rt: []const u8 = "",
    x: []const u8 = "",
    xa: []const u8 = "",
};

/// Worker-side throttle state for metadata pushes. Structural changes (client
/// count, size, exit, title) push immediately; bare activity advances are
/// rate-limited (the broker derives idle_ms from `activity` against its own
/// clock, so a small lag costs nothing).
pub const WorkerPush = struct {
    inited: bool = false,
    clients: u32 = 0,
    viewers: u32 = 0,
    exited: bool = false,
    rows: u16 = 0,
    cols: u16 = 0,
    title_hash: u64 = 0,
    controller_hash: u64 = 0,
    activity: i64 = 0,
    audio: bool = false,
    audio_hash: u64 = 0,
    last_push_ms: i64 = 0,
};

pub const Client = struct {
    const WriteLane = enum { none, normal, audio };

    /// Self-declared attach kind (peer roster / driving indicator /
    /// per-kind native backlog policy). Wire values are stable: the
    /// broker ships this as a byte in the 'A' handoff datagram.
    pub const Kind = enum(u8) { unknown = 0, gui = 1, cli = 2, mcp = 3 };

    allocator: std.mem.Allocator,
    fd: c_int,
    /// Per-daemon monotonic connection id. Two jobs: it labels the
    /// controller in list/inspect, and it orders viewers by AGE
    /// (`clients` is swapRemove'd, so list position is not arrival
    /// order) for the controller-death handover.
    id: u32 = 0,
    rbuf: std.ArrayList(u8) = .empty,
    /// Ordinary mux traffic. Audio has its own priority lane so a large
    /// graphical commit cannot strand PCM behind the whole queued backlog.
    wbuf: std.ArrayList(u8) = .empty,
    audio_wbuf: std.ArrayList(u8) = .empty,
    /// Once a frame has been partially written its bytes cannot be
    /// interleaved with another lane. At the next frame boundary audio wins.
    write_lane: WriteLane = .none,
    write_frame_left: usize = 0,
    /// Whether bytes from the selected frame have reached the socket. A role
    /// transition may discard an unstarted frame, but must finish a partial
    /// one to preserve wire framing.
    write_frame_started: bool = false,
    /// Bytes removed from the normal output stream by successful writes.
    /// Panel routes use this to distinguish queued-only from flushed bytes.
    normal_bytes_written: u64 = 0,
    attached: ?*Session = null,
    dead: bool = false,
    /// `Daemon.reap` phase 1 has run this client's one-shot detach and
    /// committed to freeing it at the end of the CURRENT reap. Phase 2
    /// sweeps every collection holding a raw `*Client` before phase 3
    /// frees exactly this set, so a client that phase 2 itself kills
    /// (a sweep can queue a frame past MAX_WBUF) is left unflagged and
    /// waits for the next reap rather than being freed unswept.
    reaping: bool = false,
    /// Negotiated core protocol, capped to this daemon's newest profile.
    /// Clients that never send a hello (the quick CLI send/kill paths of
    /// every released build) get the documented legacy default instead of
    /// the restricted profile 0 — only an explicit no-overlap negotiation
    /// may refuse service. The default is 4, not 1: every daemon that ever
    /// served those hello-less builds framed snapshots with the protocol-4
    /// [seq][app] envelope, so their parsers require the app byte.
    proto: u32 = 4,
    /// Snapshot body selected for this client (zero means no terminal profile).
    snapshot_version: u8 = snapshot.LEGACY_SNAPSHOT_VERSION,
    /// Highest daemon-compositor state version the peer can restore.
    native_state_max: u8 = 0,
    audio_channels: bool = false,
    winstream_channels: bool = false,
    /// The client sent an audio `subscribe` unit: it drains PCM.
    /// Audio units flow only to subscribed clients (a terminal-only
    /// viewer must never be flooded into its output cap).
    audio_ok: bool = false,
    /// Subscribe flags bit0: the client decodes Opus (pcm_opus).
    audio_opus: bool = false,
    /// The client advertised it can decode the video codec (hello
    /// `video`). Gates whether forwarded surfaces route through the lossy
    /// video path — never send a tile a client can't decode.
    video: bool = false,
    /// Self-declared attach kind.
    kind: Kind = .unknown,
    /// The client asked to view only: it never takes the controller
    /// lease, not even when the session has none.
    read_only: bool = false,
    /// Terminal `.events` were withheld because this client's wbuf
    /// exceeded EVENTS_BACKLOG (a flooding session vs a slow/idle
    /// consumer — e.g. an MCP client between tool calls). Once the
    /// wbuf fully drains, a fresh snapshot resyncs the client and
    /// event streaming resumes. Keeps a flooded client's backlog
    /// bounded instead of racing toward the MAX_WBUF reap.
    needs_resync: bool = false,
    /// Consecutive failed attempts to satisfy `needs_resync`. Events are
    /// withheld while a resync is pending, so a snapshot that never
    /// succeeds would freeze this client on a stale grid forever — the
    /// budget below converts that into a reported disconnect.
    resync_attempts: u8 = 0,
    /// Monotonic ms before which the next resync attempt is skipped. A
    /// full grid + scrollback serialization per tick, under the memory
    /// pressure that just failed one, is the opposite of recovery.
    resync_retry_at_ms: i64 = 0,
    /// The retry budget ran out: the client was told, and the connection
    /// is dropped as soon as that notice drains so its next attach starts
    /// from a fresh snapshot.
    resync_gave_up: bool = false,
    /// Native app-channel units were withheld because this MCP
    /// client's wbuf exceeded NATIVE_BACKLOG (it drains only during
    /// tool calls; streaming into the queue meanwhile is unbounded —
    /// AND the client would spend whole tool calls chewing stale
    /// frames instead of seeing "now"). A `native_gap` frame marks
    /// the pause; once the wbuf fully drains, replayNativeChannels
    /// rebuilds its replicas from the live mirrors and `native_sync`
    /// closes the replay.
    needs_native_resync: bool = false,
    /// Panel RPC support negotiated in hello, independent of the core
    /// terminal protocol profile.
    panel_rpc_support: u8 = 0,
    /// Current attachment's presenter/requester capability, where zero means
    /// the attachment is not panel-compatible.
    panel_rpc: u8 = 0,
    /// Session-scoped RPC attachment with no terminal/viewer semantics.
    panel_only: bool = false,

    /// Reset gap state whose meaning is confined to one attachment/session.
    /// Audio subscription survives normal same-connection reattach; queued
    /// old audio is discarded and audioViewer gates panel-only roles.
    pub fn resetAttachmentStreamState(self: *Client) void {
        self.needs_resync = false;
        self.needs_native_resync = false;
        self.resync_attempts = 0;
        self.resync_retry_at_ms = 0;
        self.resync_gave_up = false;
    }

    /// Snapshot attempts allowed for one pending resync before the client
    /// is told and disconnected. Ten attempts with the backoff below span
    /// roughly six seconds — long enough for a transient allocation
    /// failure to clear, short enough that a permanently unserializable
    /// screen does not sit unreported.
    pub const MAX_RESYNC_ATTEMPTS: u8 = 10;
    const RESYNC_RETRY_BASE_MS: i64 = 50;
    const RESYNC_RETRY_MAX_MS: i64 = 1000;

    /// Exponential backoff for attempt `n` (1-based), capped.
    fn resyncBackoffMs(attempt: u8) i64 {
        const shift: u6 = @intCast(@min(attempt -| 1, 5));
        return @min(RESYNC_RETRY_BASE_MS << shift, RESYNC_RETRY_MAX_MS);
    }

    pub fn deinit(self: *Client) void {
        _ = c.close(self.fd);
        self.rbuf.deinit(self.allocator);
        self.wbuf.deinit(self.allocator);
        self.audio_wbuf.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Hard ceiling on queued outbound bytes. A client this far
    /// behind is not draining (dead peer, stalled MCP consumer);
    /// keeping the backlog grows RSS without bound. Dropping it is
    /// safe: a live client reattaches with a fresh snapshot/replay.
    /// Sized above the largest legitimate burst (attach replay of a
    /// multi-window app's pools).
    const MAX_WBUF: usize = 256 << 20;

    /// Queued-bytes threshold past which terminal `.events` stop being
    /// streamed to this client (snapshot resync takes over once it
    /// drains). Matches NATIVE_BACKLOG, the equivalent guard on the
    /// Wayland frame path.
    const EVENTS_BACKLOG: usize = 8 << 20;

    pub fn queueFrame(self: *Client, ftype: wire.FrameType, payload: []const u8) void {
        self.queueFrameIn(&self.wbuf, ftype, payload);
    }

    pub fn queueAudioFrame(self: *Client, ftype: wire.FrameType, payload: []const u8) void {
        self.queueFrameIn(&self.audio_wbuf, ftype, payload);
    }

    fn queueFrameIn(self: *Client, out: *std.ArrayList(u8), ftype: wire.FrameType, payload: []const u8) void {
        if (!self.tryQueueFrameIn(out, ftype, payload) and !self.dead) self.dead = true;
    }

    /// Queue one complete frame while leaving allocation-failure policy to the caller.
    fn tryQueueFrameIn(self: *Client, out: *std.ArrayList(u8), ftype: wire.FrameType, payload: []const u8) bool {
        if (self.dead) return false;
        wire.appendFrame(out, self.allocator, ftype, payload) catch return false;
        if (self.queuedBytes() > MAX_WBUF) {
            self.dead = true;
            return false;
        }
        return true;
    }

    pub fn queuedBytes(self: *const Client) usize {
        return self.wbuf.items.len +| self.audio_wbuf.items.len;
    }

    /// Choose the next complete wire frame. A partially-written frame keeps
    /// its lane; otherwise latency-sensitive audio preempts normal traffic.
    pub fn startNextWriteFrame(self: *Client) bool {
        if (self.write_lane != .none) return true;
        self.write_lane = if (self.audio_wbuf.items.len > 0) .audio else if (self.wbuf.items.len > 0) .normal else return false;
        const selected = if (self.write_lane == .audio) self.audio_wbuf.items else self.wbuf.items;
        if (selected.len < 5) {
            self.dead = true;
            return false;
        }
        const payload_len = std.mem.readInt(u32, selected[0..4], .little);
        const frame_len = @as(usize, payload_len) + 4;
        if (payload_len == 0 or frame_len > selected.len) {
            self.dead = true;
            return false;
        }
        self.write_frame_left = frame_len;
        self.write_frame_started = false;
        return true;
    }

    pub fn queueJson(self: *Client, ftype: wire.FrameType, value: anytype) void {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        std.json.Stringify.value(value, .{}, &aw.writer) catch {
            self.dead = true;
            return;
        };
        self.queueFrame(ftype, aw.written());
    }

    pub fn queueErr(self: *Client, msg: []const u8) void {
        self.queueJson(.err, .{ .@"error" = msg });
    }

    /// An `.err` that names the request it answers.
    ///
    /// `.err` carries no correlation id, so an untagged one is guesswork on
    /// the client: `terminal.zig` attributes it to whichever of its
    /// one-at-a-time requests is outstanding, which silently consumed a
    /// pending rename/record whenever the daemon refused something else.
    /// A tagged error is dispatched on `for` and can never be misread.
    pub fn queueErrFor(self: *Client, msg: []const u8, request: []const u8) void {
        self.queueJson(.err, .{ .@"error" = msg, .@"for" = request });
    }
};

/// One daemon-owned correlation rewrite between a panel-only requester and
/// the single compatible GUI selected for its session.
pub const PanelRoute = struct {
    route_id: u64,
    caller_id: u64,
    requester: *Client,
    presenter: *Client,
    session: *Session,
    /// Minimum presenter capability required by this requester attachment.
    panel_rpc: u8,
    deadline_ms: i64,
    presenter_stream_start: u64,
    presenter_stream_len: usize,
};

test "client audio lane preempts normal traffic only at frame boundaries" {
    const a = std.testing.allocator;
    var cl = Client{ .allocator = a, .fd = -1 };
    defer cl.rbuf.deinit(a);
    defer cl.wbuf.deinit(a);
    defer cl.audio_wbuf.deinit(a);

    cl.queueFrame(.events, "pixels");
    cl.queueAudioFrame(.chan_data, "pcm");
    try std.testing.expect(cl.startNextWriteFrame());
    try std.testing.expectEqual(Client.WriteLane.audio, cl.write_lane);
    try std.testing.expectEqual(@as(usize, 8), cl.write_frame_left);

    // Once bytes of a normal frame are on the stream, newly queued audio
    // cannot split that frame; it wins immediately after the boundary.
    cl.write_lane = .normal;
    cl.write_frame_left = 3;
    try std.testing.expect(cl.startNextWriteFrame());
    try std.testing.expectEqual(Client.WriteLane.normal, cl.write_lane);
    try std.testing.expectEqual(@as(usize, 3), cl.write_frame_left);
}

test "hello-less clients default to the protocol-4 envelope with the legacy snapshot body" {
    const a = std.testing.allocator;
    var cl = Client{ .allocator = a, .fd = -1 };
    defer cl.rbuf.deinit(a);
    defer cl.wbuf.deinit(a);
    defer cl.audio_wbuf.deinit(a);
    // Released hello-less CLI builds (v4/v5 `mux send`/`kill`) parse only
    // the [seq][app] snapshot envelope and reject profile-0 refusals as
    // "no such session" — the default must serve them, not lock them out.
    try std.testing.expect(cl.proto >= 4);
    try std.testing.expect(cl.proto < 5); // no app/audio channels without a hello
    try std.testing.expectEqual(snapshot.LEGACY_SNAPSHOT_VERSION, cl.snapshot_version);
    try std.testing.expectEqual(@as(u8, 0), cl.native_state_max);
    try std.testing.expect(!cl.audio_channels);
    try std.testing.expect(!cl.winstream_channels);
}

const pathz = @import("../util/pathz.zig");
const pathZ = pathz.pathZ;

/// One tunneled byte stream, bridged to clients as chan_* frames:
/// a Wayland app connection (`native` set) or a window-stream session
/// (`native` null, fd -1, frames produced in the daemon).
///
/// Ownership split (proto v5): a NATIVE channel belongs to the
/// SESSION — `client` is null, its unit stream broadcasts to every
/// attached proto>=6 client, and it survives client death (durable
/// GUI apps; the daemon-side brain keeps answering the protocol). A
/// winstream channel keeps the legacy 1:1 client binding.
pub const Channel = struct {
    allocator: std.mem.Allocator,
    id: u32,
    fd: c_int,
    /// Null on a TCP-forward channel (daemon-host scoped, no session).
    session: ?*Session,
    /// Winstream/tcp only; null on native channels (broadcast).
    client: ?*Client,
    /// Raw TCP forward (kind tcp_forward): chan_data is unframed
    /// socket bytes, strictly 1:1 with `client`. LSP channels reuse
    /// this relay (their fd is a socketpair to the child's stdio).
    tcp: bool = false,
    /// LSP channels only (kind lsp): the spawned language server, in
    /// its own process group. The child DIES with the channel — the
    /// daemon SIGTERMs the group when the channel drops (client
    /// disconnect included) and escalates to SIGKILL via `lsp_reaps`.
    child_pid: c.pid_t = -1,
    /// Infrastructure client (currently xwayland-satellite): its surfaces
    /// are forwarded normally, but its persistent connection does not keep
    /// an external display's no-viewer TTL occupied.
    auxiliary: bool = false,
    /// Bytes from the client not yet written to fd (partial writes).
    pending: std.ArrayList(u8) = .empty,
    dead: bool = false,
    /// A fatal Wayland error is queued; stop reading and close once written.
    close_after_flush: bool = false,
    /// Non-null on a Wayland app channel: the app speaks raw Wayland
    /// to us and the byte stream toward the GUI is wlhost/pipe units.
    native: ?*Native = null,
    /// Non-null on an audio channel: the app speaks the PulseAudio
    /// native protocol; the stream toward the GUI is pulse.zig units.
    pa: ?*pulse.Server = null,
    /// Per-stream WAV capture (Session.audio_capture_base set):
    /// stream index → live writer. Finalized here on teardown so the
    /// RIFF sizes get patched even when the app never closed cleanly.
    caps: std.AutoHashMapUnmanaged(u32, wavcap.Writer) = .empty,

    pub fn deinit(self: *Channel) void {
        if (self.native) |nv| nv.deinit();
        if (self.pa) |srv| {
            srv.deinit();
            self.allocator.destroy(srv);
        }
        var cap_it = self.caps.valueIterator();
        while (cap_it.next()) |w| w.close();
        self.caps.deinit(self.allocator);
        _ = c.close(self.fd);
        self.pending.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

/// Per-channel state of the sketerm-native app pipe: the session's
/// app connects straight to the daemon. Owns the protocol tracker
/// and the mmapped shm pool mirrors.
/// Brackets CPU reads, accepting ENOTTY from coherent memfd exporters.
fn dmabufSync(fd: c_int, end: bool) bool {
    const DmaBufSync = extern struct { flags: u64 };
    const DMA_BUF_SYNC_READ: u64 = 1;
    const DMA_BUF_SYNC_END: u64 = 1 << 2;
    var s = DmaBufSync{ .flags = DMA_BUF_SYNC_READ | (if (end) DMA_BUF_SYNC_END else 0) };
    var retries: u8 = 0;
    while (retries < 64) : (retries += 1) {
        const result = c.ioctl(fd, 0x40086200, &s); // DMA_BUF_IOCTL_SYNC = _IOW('b', 0, u64)
        if (result == 0 or std.posix.errno(result) == .NOTTY) return true;
        const errno = std.posix.errno(result);
        if (errno != .INTR and errno != .AGAIN) return false;
    }
    return false;
}

/// Copies padded dma-buf storage into a tight top-down staging image.
fn copyDmabufRows(dst: []u8, src: []const u8, width: u32, height: u32, offset: u32, stride: u32, y_invert: bool) bool {
    const row_bytes = std.math.mul(usize, width, 4) catch return false;
    const staging_size = std.math.mul(usize, row_bytes, height) catch return false;
    if (dst.len != staging_size or stride < row_bytes) return false;
    for (0..height) |dst_row| {
        const src_row = if (y_invert) height - 1 - dst_row else dst_row;
        const src_start = std.math.add(
            usize,
            offset,
            std.math.mul(usize, src_row, stride) catch return false,
        ) catch return false;
        const src_end = std.math.add(usize, src_start, row_bytes) catch return false;
        if (src_end > src.len) return false;
        @memcpy(dst[dst_row * row_bytes ..][0..row_bytes], src[src_start..src_end]);
    }
    return true;
}

test "dmabuf staging copy removes padding and honors Y_INVERT" {
    const source = [_]u8{
        99, 99,
        1,  2,
        3,  4,
        5,  6,
        7,  8,
        90, 90,
        11, 12,
        13, 14,
        15, 16,
        17, 18,
        91, 91,
    };
    var staging: [16]u8 = undefined;

    try std.testing.expect(copyDmabufRows(&staging, &source, 2, 2, 2, 10, false));
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 11, 12, 13, 14, 15, 16, 17, 18 }, &staging);

    try std.testing.expect(copyDmabufRows(&staging, &source, 2, 2, 2, 10, true));
    try std.testing.expectEqualSlices(u8, &.{ 11, 12, 13, 14, 15, 16, 17, 18, 1, 2, 3, 4, 5, 6, 7, 8 }, &staging);
    try std.testing.expect(!copyDmabufRows(&staging, source[0..10], 2, 2, 2, 10, false));
}

pub const SurfaceIconCache = struct {
    map: std.AutoHashMapUnmanaged(u32, icons.Icon) = .empty,

    fn putCopy(self: *SurfaceIconCache, a: std.mem.Allocator, sid: u32, icon: icons.Icon) !void {
        const copy = icons.Icon{ .kind = icon.kind, .bytes = try a.dupe(u8, icon.bytes) };
        errdefer a.free(copy.bytes);
        if (try self.map.fetchPut(a, sid, copy)) |old| {
            var replaced = old.value;
            replaced.deinit(a);
        }
    }

    fn remove(self: *SurfaceIconCache, a: std.mem.Allocator, sid: u32) void {
        if (self.map.fetchRemove(sid)) |old| {
            var icon = old.value;
            icon.deinit(a);
        }
    }

    fn appendReplay(self: *const SurfaceIconCache, out: *std.ArrayList(u8), a: std.mem.Allocator) !void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            try wlpipe.appendToplevelIcon(
                out,
                a,
                entry.key_ptr.*,
                @intFromEnum(entry.value_ptr.kind),
                entry.value_ptr.bytes,
            );
        }
    }

    pub fn deinit(self: *SurfaceIconCache, a: std.mem.Allocator) void {
        var it = self.map.valueIterator();
        while (it.next()) |icon| icon.deinit(a);
        self.map.deinit(a);
    }
};

test "surface icon cache replays every live surface independently" {
    const t = std.testing;
    var cache = SurfaceIconCache{};
    defer cache.deinit(t.allocator);
    var bytes = [_]u8{ 1, 2, 3 };
    const icon = icons.Icon{ .kind = .png, .bytes = &bytes };
    try cache.putCopy(t.allocator, 10, icon);
    try cache.putCopy(t.allocator, 11, icon);

    var units: std.ArrayList(u8) = .empty;
    defer units.deinit(t.allocator);
    try cache.appendReplay(&units, t.allocator);
    var seen_10 = false;
    var seen_11 = false;
    var pos: usize = 0;
    while (try wlpipe.peelUnit(units.items[pos..])) |peeled| {
        try t.expectEqual(wlpipe.Tag.toplevel_icon, peeled.unit.tag);
        const sid = std.mem.readInt(u32, peeled.unit.payload[0..4], .little);
        seen_10 = seen_10 or sid == 10;
        seen_11 = seen_11 or sid == 11;
        pos += peeled.consumed;
    }
    try t.expect(seen_10 and seen_11);

    cache.remove(t.allocator, 10);
    units.clearRetainingCapacity();
    try cache.appendReplay(&units, t.allocator);
    const only = (try wlpipe.peelUnit(units.items)).?;
    try t.expectEqual(@as(u32, 11), std.mem.readInt(u32, only.unit.payload[0..4], .little));
    try t.expect((try wlpipe.peelUnit(units.items[only.consumed..])) == null);
}

test "daemon startup preserves live owners and socket inode ownership" {
    const t = std.testing;
    var path_buf: [256:0]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/sketerm-daemon-owner-{d}.sock", .{c.getpid()});
    var lock_buf: [280:0]u8 = undefined;
    const lock_path = try std.fmt.bufPrintZ(&lock_buf, "{s}.lock", .{path});
    _ = c.unlink(path.ptr);
    _ = c.unlink(lock_path.ptr);
    defer {
        _ = c.unlink(path.ptr);
        _ = c.unlink(lock_path.ptr);
    }

    var first = try Daemon.init(t.allocator, path);
    var first_live = true;
    defer if (first_live) first.deinit();
    try t.expectError(error.AlreadyRunning, Daemon.init(t.allocator, path));

    // Simulate an externally removed path followed by a replacement owner.
    // The old anonymous listener must not unlink the replacement on teardown.
    try t.expectEqual(@as(c_int, 0), c.unlink(path.ptr));
    var replacement = try Daemon.init(t.allocator, path);
    defer replacement.deinit();
    first.deinit();
    first_live = false;
    try t.expectEqual(Daemon.SocketPathState.live, Daemon.socketPathState(path));
}

test "daemon startup recovers a refused stale socket" {
    const t = std.testing;
    var path_buf: [256:0]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/sketerm-daemon-stale-{d}.sock", .{c.getpid()});
    var lock_buf: [280:0]u8 = undefined;
    const lock_path = try std.fmt.bufPrintZ(&lock_buf, "{s}.lock", .{path});
    _ = c.unlink(path.ptr);
    _ = c.unlink(lock_path.ptr);
    defer {
        _ = c.unlink(path.ptr);
        _ = c.unlink(lock_path.ptr);
    }

    const fd = @import("../util/platform.zig").socketCloexec(c.AF_UNIX, c.SOCK_STREAM, 0);
    try t.expect(fd >= 0);
    var addr: c.struct_sockaddr_un = undefined;
    try fillSockaddrUn(&addr, path);
    try t.expectEqual(@as(c_int, 0), c.bind(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)));
    _ = c.close(fd);

    const daemon = try Daemon.init(t.allocator, path);
    daemon.deinit();
    try t.expect(c.access(path.ptr, c.F_OK) != 0);
}

test "a closed lifetime fence stops the daemon on the next tick" {
    const t = std.testing;
    var path_buf: [256:0]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/sketerm-daemon-fence-{d}.sock", .{c.getpid()});
    var lock_buf: [280:0]u8 = undefined;
    const lock_path = try std.fmt.bufPrintZ(&lock_buf, "{s}.lock", .{path});
    _ = c.unlink(path.ptr);
    _ = c.unlink(lock_path.ptr);
    defer {
        _ = c.unlink(path.ptr);
        _ = c.unlink(lock_path.ptr);
    }
    var d = try Daemon.init(t.allocator, path);
    defer d.deinit();

    var fds: [2]c_int = undefined;
    try t.expect(c.pipe(&fds) == 0);
    defer _ = c.close(fds[0]);
    d.lifetime_fd = fds[0];

    // Writer alive: the fence is quiet and the daemon keeps running.
    try d.tick(10);
    try t.expect(d.running);

    // The owner dying closes the last writer: one tick and it is over.
    _ = c.close(fds[1]);
    try d.tick(1000);
    try t.expect(!d.running);
}

test "--idle-exit retires a daemon holding nothing; 0 never does" {
    const t = std.testing;
    var path_buf: [256:0]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/sketerm-daemon-idle-{d}.sock", .{c.getpid()});
    var lock_buf: [280:0]u8 = undefined;
    const lock_path = try std.fmt.bufPrintZ(&lock_buf, "{s}.lock", .{path});
    _ = c.unlink(path.ptr);
    _ = c.unlink(lock_path.ptr);
    defer {
        _ = c.unlink(path.ptr);
        _ = c.unlink(lock_path.ptr);
    }
    var d = try Daemon.init(t.allocator, path);
    defer d.deinit();

    // Default: client-less forever (`reap` is the per-tick sweep the
    // check rides on).
    d.reap();
    _ = c.usleep(5_000);
    d.reap();
    try t.expect(d.running);
    try t.expectEqual(@as(i64, 0), d.idle_since_ms);

    // Armed: the first idle tick starts the clock, a later one past the
    // budget clears `running`. Broker mode counts workers the same way.
    d.idle_exit_ms = 1;
    d.is_broker = true;
    d.reap();
    try t.expect(d.running);
    try t.expect(d.idle_since_ms != 0);
    _ = c.usleep(5_000);
    d.reap();
    try t.expect(!d.running);

    // Something held resets the clock rather than letting it run on.
    d.running = true;
    d.idle_since_ms = nowMs() - 10_000;
    d.is_broker = false;
    var a_client = try t.allocator.create(Client);
    a_client.* = .{ .fd = -1, .allocator = t.allocator, .id = 1 };
    try d.clients.append(t.allocator, a_client);
    d.reap();
    try t.expect(d.running);
    try t.expectEqual(@as(i64, 0), d.idle_since_ms);
    _ = d.clients.pop();
    a_client.deinit();
}

test "lsp_open resolves the root remotely, bridges stdio bytes, and reaps on close" {
    const t = std.testing;
    const muxclient = @import("client.zig");
    var path_buf: [256:0]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/sketerm-daemon-lsp-{d}.sock", .{c.getpid()});
    var lock_buf: [280:0]u8 = undefined;
    const lock_path = try std.fmt.bufPrintZ(&lock_buf, "{s}.lock", .{path});
    _ = c.unlink(path.ptr);
    _ = c.unlink(lock_path.ptr);
    defer {
        _ = c.unlink(path.ptr);
        _ = c.unlink(lock_path.ptr);
    }
    var d = try Daemon.init(t.allocator, path);
    defer d.deinit();

    // A project tree whose marker sits one level above the document:
    // the daemon must answer the MARKER directory as the root.
    var root_buf: [256:0]u8 = undefined;
    const root = try std.fmt.bufPrintZ(&root_buf, "/tmp/sketerm-lsp-root-{d}", .{c.getpid()});
    var sub_buf: [256:0]u8 = undefined;
    const sub = try std.fmt.bufPrintZ(&sub_buf, "{s}/src", .{root});
    var mark_buf: [256:0]u8 = undefined;
    const mark = try std.fmt.bufPrintZ(&mark_buf, "{s}/rootmark", .{root});
    _ = c.mkdir(root.ptr, 0o700);
    _ = c.mkdir(sub.ptr, 0o700);
    {
        const f = c.fopen(mark.ptr, "wb") orelse return error.TestSetupFailed;
        _ = c.fclose(f);
    }
    defer {
        _ = c.unlink(mark.ptr);
        _ = c.rmdir(sub.ptr);
        _ = c.rmdir(root.ptr);
    }

    var conn = try muxclient.Conn.connect(t.allocator, path);
    defer conn.deinit();

    const Pump = struct {
        fn next(dm: *Daemon, cn: *muxclient.Conn) !muxclient.Conn.OwnedFrame {
            var spins: usize = 0;
            while (spins < 4000) : (spins += 1) {
                try dm.tick(0);
                if (!cn.fillAvailable()) return error.Disconnected;
                if (try cn.takeFrame()) |f| return f;
                _ = c.usleep(1000);
            }
            return error.Timeout;
        }
    };

    const Reply = struct {
        req: u32 = 0,
        ok: bool = false,
        chan: u32 = 0,
        name: []const u8 = "",
        root: []const u8 = "",
    };

    // 1. No candidate installed -> silent ok:false, no channel.
    try conn.sendJson(.lsp_open, .{
        .req = @as(u32, 7),
        .dir = @as([]const u8, sub),
        .servers = [_]Daemon.LspOpenSrv{
            .{ .name = "nope", .command = "sketerm-no-such-binary-xyz" },
        },
    });
    {
        const f = try Pump.next(d, &conn);
        defer f.deinit(t.allocator);
        try t.expectEqual(wire.FrameType.lsp_reply, f.ftype);
        var parsed = try std.json.parseFromSlice(Reply, t.allocator, f.payload, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try t.expectEqual(@as(u32, 7), parsed.value.req);
        try t.expect(!parsed.value.ok);
        try t.expectEqual(@as(usize, 0), d.channels.items.len);
    }

    // 2. The first candidate is missing, the second (`cat`) is not: the
    // daemon walks the list, resolves the marker root, spawns, answers
    // chan_open then lsp_reply.
    try conn.sendJson(.lsp_open, .{
        .req = @as(u32, 8),
        .dir = @as([]const u8, sub),
        .servers = [_]Daemon.LspOpenSrv{
            .{ .name = "nope", .command = "sketerm-no-such-binary-xyz" },
            .{ .name = "echo", .command = "cat", .root_files = "rootmark" },
        },
    });
    var chan_id: u32 = 0;
    {
        const f = try Pump.next(d, &conn);
        defer f.deinit(t.allocator);
        try t.expectEqual(wire.FrameType.chan_open, f.ftype);
        const co = wire.decodeChanOpen(f.payload).?;
        try t.expectEqual(wire.ChannelKind.lsp, co.kind);
        chan_id = co.id;
    }
    {
        const f = try Pump.next(d, &conn);
        defer f.deinit(t.allocator);
        try t.expectEqual(wire.FrameType.lsp_reply, f.ftype);
        var parsed = try std.json.parseFromSlice(Reply, t.allocator, f.payload, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try t.expect(parsed.value.ok);
        try t.expectEqual(@as(u32, 8), parsed.value.req);
        try t.expectEqual(chan_id, parsed.value.chan);
        try t.expectEqualStrings("echo", parsed.value.name);
        try t.expectEqualStrings(root, parsed.value.root);
    }

    // 3. Bytes bridge both ways (`cat` echoes its stdin).
    {
        var payload: [4 + 5]u8 = undefined;
        std.mem.writeInt(u32, payload[0..4], chan_id, .little);
        @memcpy(payload[4..], "ping\n");
        try conn.sendFrame(.chan_data, &payload);
        const f = try Pump.next(d, &conn);
        defer f.deinit(t.allocator);
        try t.expectEqual(wire.FrameType.chan_data, f.ftype);
        try t.expectEqual(chan_id, wire.decodeChanId(f.payload).?);
        try t.expectEqualStrings("ping\n", f.payload[4..]);
    }

    // 4. chan_close kills the child (SIGTERM -> reap) and empties both
    // the channel list and the reap list — nothing zombifies.
    {
        var payload: [4]u8 = undefined;
        std.mem.writeInt(u32, payload[0..4], chan_id, .little);
        try conn.sendFrame(.chan_close, &payload);
        var spins: usize = 0;
        while (spins < 4000) : (spins += 1) {
            try d.tick(0);
            if (d.channels.items.len == 0 and d.lsp_reaps.items.len == 0) break;
            _ = c.usleep(1000);
        }
        try t.expectEqual(@as(usize, 0), d.channels.items.len);
        try t.expectEqual(@as(usize, 0), d.lsp_reaps.items.len);
    }
}

test "web_helper_open: missing helper is a described refusal, a spawn bridges a channel" {
    const t = std.testing;
    const muxclient = @import("client.zig");
    var path_buf: [256:0]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/sketerm-daemon-web-{d}.sock", .{c.getpid()});
    var lock_buf: [280:0]u8 = undefined;
    const lock_path = try std.fmt.bufPrintZ(&lock_buf, "{s}.lock", .{path});
    _ = c.unlink(path.ptr);
    _ = c.unlink(lock_path.ptr);
    defer {
        _ = c.unlink(path.ptr);
        _ = c.unlink(lock_path.ptr);
    }
    var d = try Daemon.init(t.allocator, path);
    defer d.deinit();
    var conn = try muxclient.Conn.connect(t.allocator, path);
    defer conn.deinit();

    // The env pin is authoritative (findbin); tests running inside a
    // sketerm pane inherit real env, so save + restore it exactly.
    const saved = if (c.getenv("SKETERM_WEB_BIN")) |v| std.mem.span(v) else null;
    defer {
        if (saved) |v| {
            var buf: [4096:0]u8 = undefined;
            const z = std.fmt.bufPrintZ(&buf, "{s}", .{v}) catch unreachable;
            _ = c.setenv("SKETERM_WEB_BIN", z.ptr, 1);
        } else _ = c.unsetenv("SKETERM_WEB_BIN");
    }

    const Pump = struct {
        fn next(dm: *Daemon, cn: *muxclient.Conn) !muxclient.Conn.OwnedFrame {
            var spins: usize = 0;
            while (spins < 4000) : (spins += 1) {
                try dm.tick(0);
                if (!cn.fillAvailable()) return error.Disconnected;
                if (try cn.takeFrame()) |f| return f;
                _ = c.usleep(1000);
            }
            return error.Timeout;
        }
    };
    const Reply = struct { req: u32 = 0, ok: bool = false, chan: u32 = 0, @"error": []const u8 = "" };

    // 1. No helper on this host: described ok:false, no channel.
    _ = c.setenv("SKETERM_WEB_BIN", "/no/such/sketerm-webengine-test", 1);
    try conn.sendJson(.web_helper_open, .{ .req = @as(u32, 5) });
    {
        const f = try Pump.next(d, &conn);
        defer f.deinit(t.allocator);
        try t.expectEqual(wire.FrameType.web_helper_reply, f.ftype);
        var parsed = try std.json.parseFromSlice(Reply, t.allocator, f.payload, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try t.expectEqual(@as(u32, 5), parsed.value.req);
        try t.expect(!parsed.value.ok);
        try t.expect(std.mem.indexOf(u8, parsed.value.@"error", "not installed") != null);
        try t.expectEqual(@as(usize, 0), d.channels.items.len);
    }

    // 2. An executable helper spawns: chan_open (kind web_helper) then
    // the ok reply; the stand-in exits at once, so the channel EOFs and
    // the daemon retires it (chan_close toward the client).
    //
    // The stand-in is RESOLVED, not hardcoded: macOS ships `true` at
    // /usr/bin only, and `findbin.find` treats a set-but-unusable
    // SKETERM_WEB_BIN as an authoritative refusal (by design). A
    // hardcoded /bin/true therefore turned this into step 1 again —
    // a described ok:false instead of a spawn — and the daemon was
    // never at fault.
    const stand_in = blk: {
        for ([_][*:0]const u8{ "/bin/true", "/usr/bin/true" }) |cand| {
            if (c.access(cand, c.X_OK) == 0) break :blk cand;
        }
        return error.NoTrueBinary;
    };
    _ = c.setenv("SKETERM_WEB_BIN", stand_in, 1);
    try conn.sendJson(.web_helper_open, .{ .req = @as(u32, 6) });
    var chan_id: u32 = 0;
    {
        const f = try Pump.next(d, &conn);
        defer f.deinit(t.allocator);
        try t.expectEqual(wire.FrameType.chan_open, f.ftype);
        const co = wire.decodeChanOpen(f.payload).?;
        try t.expectEqual(wire.ChannelKind.web_helper, co.kind);
        chan_id = co.id;
    }
    {
        const f = try Pump.next(d, &conn);
        defer f.deinit(t.allocator);
        try t.expectEqual(wire.FrameType.web_helper_reply, f.ftype);
        var parsed = try std.json.parseFromSlice(Reply, t.allocator, f.payload, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try t.expect(parsed.value.ok);
        try t.expectEqual(@as(u32, 6), parsed.value.req);
        try t.expectEqual(chan_id, parsed.value.chan);
    }
    {
        const f = try Pump.next(d, &conn);
        defer f.deinit(t.allocator);
        try t.expectEqual(wire.FrameType.chan_close, f.ftype);
        try t.expectEqual(chan_id, wire.decodeChanId(f.payload).?);
    }
    // The dead child is reaped through the lsp grace path; nothing
    // zombifies and no channel lingers.
    var spins: usize = 0;
    while (spins < 4000) : (spins += 1) {
        try d.tick(0);
        if (d.channels.items.len == 0 and d.lsp_reaps.items.len == 0) break;
        _ = c.usleep(1000);
    }
    try t.expectEqual(@as(usize, 0), d.channels.items.len);
    try t.expectEqual(@as(usize, 0), d.lsp_reaps.items.len);
}

test "web_helper_connect: bridges a helper serving beside the daemon socket, describes an absent one" {
    const t = std.testing;
    const muxclient = @import("client.zig");
    var dir_buf: [128:0]u8 = undefined;
    const dir = try std.fmt.bufPrintZ(&dir_buf, "/tmp/sk-webc-{d}", .{c.getpid()});
    _ = c.mkdir(dir.ptr, 0o700);
    var path_buf: [160:0]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "{s}/mux.sock", .{dir});
    var lock_buf: [180:0]u8 = undefined;
    const lock_path = try std.fmt.bufPrintZ(&lock_buf, "{s}.lock", .{path});
    var helper_buf: [160:0]u8 = undefined;
    const helper_path = try std.fmt.bufPrintZ(&helper_buf, "{s}/web.sock", .{dir});
    _ = c.unlink(path.ptr);
    _ = c.unlink(lock_path.ptr);
    _ = c.unlink(helper_path.ptr);
    defer {
        _ = c.unlink(path.ptr);
        _ = c.unlink(lock_path.ptr);
        _ = c.unlink(helper_path.ptr);
        _ = c.rmdir(dir.ptr);
    }
    // A stand-in helper: a listener at the direct route's socket.
    const lfd = platform.socketCloexec(c.AF_UNIX, c.SOCK_STREAM, 0);
    try t.expect(lfd >= 0);
    defer _ = c.close(lfd);
    {
        var addr = std.mem.zeroes(c.struct_sockaddr_un);
        addr.sun_family = c.AF_UNIX;
        @memcpy(addr.sun_path[0..helper_path.len], helper_path);
        try t.expect(c.bind(lfd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) == 0);
        try t.expect(c.listen(lfd, 4) == 0);
        _ = c.fcntl(lfd, c.F_SETFL, c.O_NONBLOCK);
    }
    var d = try Daemon.init(t.allocator, path);
    defer d.deinit();
    var conn = try muxclient.Conn.connect(t.allocator, path);
    defer conn.deinit();
    const Pump = struct {
        fn next(dm: *Daemon, cn: *muxclient.Conn) !muxclient.Conn.OwnedFrame {
            var spins: usize = 0;
            while (spins < 4000) : (spins += 1) {
                try dm.tick(0);
                if (!cn.fillAvailable()) return error.Disconnected;
                if (try cn.takeFrame()) |f| return f;
                _ = c.usleep(1000);
            }
            return error.Timeout;
        }
    };
    const Reply = struct { req: u32 = 0, ok: bool = false, chan: u32 = 0, @"error": []const u8 = "" };

    // 1. The helper answers: chan_open (kind web_helper) then ok, and the
    // stand-in sees the daemon's connection arrive.
    try conn.sendJson(.web_helper_connect, .{ .req = @as(u32, 7), .session = "" });
    var chan_id: u32 = 0;
    {
        const f = try Pump.next(d, &conn);
        defer f.deinit(t.allocator);
        try t.expectEqual(wire.FrameType.chan_open, f.ftype);
        const co = wire.decodeChanOpen(f.payload).?;
        try t.expectEqual(wire.ChannelKind.web_helper, co.kind);
        chan_id = co.id;
    }
    {
        const f = try Pump.next(d, &conn);
        defer f.deinit(t.allocator);
        try t.expectEqual(wire.FrameType.web_helper_reply, f.ftype);
        var parsed = try std.json.parseFromSlice(Reply, t.allocator, f.payload, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try t.expect(parsed.value.ok);
        try t.expectEqual(@as(u32, 7), parsed.value.req);
        try t.expectEqual(chan_id, parsed.value.chan);
    }
    const afd = c.accept(lfd, null, null);
    try t.expect(afd >= 0);
    defer _ = c.close(afd);
    try t.expectEqual(@as(usize, 1), d.channels.items.len);
    // A bridged channel owns no process: nothing to kill on close.
    try t.expectEqual(@as(c.pid_t, -1), d.channels.items[0].child_pid);

    // 2. No helper: a described refusal, no channel.
    _ = c.close(afd);
    _ = c.unlink(helper_path.ptr);
    try conn.sendJson(.web_helper_connect, .{ .req = @as(u32, 8), .session = "web-1-nope" });
    while (true) {
        const f = try Pump.next(d, &conn);
        defer f.deinit(t.allocator);
        if (f.ftype == .chan_close) continue;
        try t.expectEqual(wire.FrameType.web_helper_reply, f.ftype);
        var parsed = try std.json.parseFromSlice(Reply, t.allocator, f.payload, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try t.expectEqual(@as(u32, 8), parsed.value.req);
        try t.expect(!parsed.value.ok);
        try t.expect(std.mem.indexOf(u8, parsed.value.@"error", "not running") != null);
        break;
    }
}

pub const Native = struct {
    allocator: std.mem.Allocator,
    tracker: wltrack.Tracker,
    /// The authoritative compositor answering this app's protocol —
    /// lives HERE so the app runs with zero clients attached and
    /// survives client churn. Fed the request unit stream (minus
    /// pool bytes: its View has no frame callback, so it never needs
    /// pixels); its output is applied straight back to the app.
    /// serializeState() of this instance is what reattaching
    /// replicas restore from.
    brain: *wlcomp.Compositor,
    /// Raw bytes from the app socket; messages may arrive split.
    inbuf: std.ArrayList(u8) = .empty,
    /// SCM_RIGHTS fds awaiting their create_pool message (Wayland
    /// pairs fds with messages in arrival order).
    fds: std.ArrayList(c_int) = .empty,
    /// GUI→app unit stream reassembly (chan_data may split units).
    unitbuf: std.ArrayList(u8) = .empty,
    /// Fds to attach (SCM_RIGHTS) to the NEXT write toward the app.
    /// Early arrival is fine — libwayland queues fds until the
    /// consuming message shows up; late is the only fatal order.
    out_fds: std.ArrayList(c_int) = .empty,
    /// Paste: write-ends from wl_data_offer.receive, tagged with the
    /// offer id. GUI clip_data answers consume front-of-queue (FIFO);
    /// dnd_send / drop_data consume BY OFFER so a dnd transfer can't
    /// steal the fd of a clipboard paste awaiting its async answer.
    clip_paste_fds: std.ArrayList(PasteFd) = .empty,
    /// PRIMARY-selection paste fds, FIFO-paired with primary_data
    /// units (separate queue so interleaved pastes can't swap).
    primary_paste_fds: std.ArrayList(c_int) = .empty,
    /// Copy: read-ends of pipes whose write-ends went to the app
    /// via wl_data_source.send; EOF ships a clip_data unit up.
    clip_reads: std.ArrayList(ClipRead) = .empty,
    /// Paste bytes accepted for an app-supplied fd that the app has
    /// not read yet. The fd belongs to the APP, so its pipe fills at
    /// the app's pace: writing the rest inline would park the whole
    /// single-threaded poll loop — every session on this host — on one
    /// unresponsive client. The remainder drains on POLLOUT instead.
    clip_writes: std.ArrayList(ClipWrite) = .empty,
    /// pool id -> daemon-owned mirror of the CURRENT incarnation under that
    /// id (anonymous memory filled by pread at commit; the client fd is kept
    /// only to read from). Mirrors outlive wl_shm_pool destructors: existing
    /// buffers keep referencing the memory.
    pools: std.AutoHashMapUnmanaged(u32, PoolMirror) = .empty,
    /// Incarnation serial → mirror displaced from `pools` by id reuse
    /// while old buffers still referenced it (Vulkan WSI destroys its
    /// probe pools early; the recycled id must not cross refcounts).
    orphan_pools: std.AutoHashMapUnmanaged(u64, PoolMirror) = .empty,
    /// zwp_linux_buffer_params_v1 id → owned plane fds awaiting create.
    dmabuf_pending: std.AutoHashMapUnmanaged(u32, DmabufPending) = .empty,
    /// Process-wide EGL importer borrowed from the daemon.
    dmabuf_importer: ?*dmabuf_egl.Importer = null,
    /// dmabuf wl_buffer id → source ownership plus committed tight pixels.
    /// Replicas address the staging image by synthetic pool id == buffer id.
    dmabufs: std.AutoHashMapUnmanaged(u32, DmabufMirror) = .empty,
    /// Per-channel scratch keeps the previous LINEAR capture intact until
    /// both DMA_BUF_SYNC brackets and the row copy have succeeded.
    dmabuf_scratch: std.ArrayList(u8) = .empty,
    /// Per-surface lossy-video state (only populated under
    /// build_options.video): a churn tracker + a fixed-resolution
    /// encoder, keyed by surface id. Hot, photographic surfaces route
    /// through here to pool_vtile instead of the lossless pool_update_c.
    vstate: std.AutoHashMapUnmanaged(u32, VideoSurface) = .empty,
    /// Scratch reused across commits: tight full-surface BGRA, and the
    /// encoded vcodec tile blob.
    vscratch: std.ArrayList(u8) = .empty,
    vblob: std.ArrayList(u8) = .empty,
    /// Lossless pixel-encode scratch (filter work buffer + zstd out),
    /// reused across EVERY commit. Persisting it here is both the
    /// leak fix (a per-commit local was never deinit'd — a
    /// continuously-rendering app leaked a frame-sized buffer per
    /// frame) and an allocation-churn win (buffers stay at high
    /// water instead of realloc-per-frame).
    pixscratch: wlpixcodec.Scratch = .{},
    /// Video consensus for this channel: set by `videoOk` when at least
    /// one native viewer of the session is attached and EVERY one of them
    /// advertised video decoding. Recomputed on client churn
    /// (`refreshVideoGates`). While false videoCommit stays dormant:
    /// never emit a tile some attached client cannot decode.
    wants_video: bool = false,
    /// Icon injection back-pointers (set after the Channel exists) so
    /// the brain's toplevel_app_id callback can resolve the app's icon
    /// on THIS host and queue it toward clients.
    daemon: ?*Daemon = null,
    chan: ?*Channel = null,
    /// Last logged commit pixel-path state (see nativeAction .commit)
    /// so the debug log records transitions, not every frame.
    pix_state: u8 = 0,
    /// surface id → damage rows of commits whose PIXEL copy was
    /// skipped (no viewer had queue room). Null value = full buffer.
    /// Merged into the next shipped commit's range so a recovering
    /// viewer isn't left with permanently stale regions the app
    /// never re-damages (partial-damage clients).
    skipped: std.AutoHashMapUnmanaged(u32, ?wltrack.RowRange) = .empty,
    /// Current surface id -> shipped icon bytes for durable reattach.
    surface_icons: SurfaceIconCache = .{},
    /// Resolved xdg-foreign relations owned by THIS channel's surfaces:
    /// child surface id -> (exporting channel id, exported surface id).
    /// Daemon-side only (the brain's handle namespace never crosses the
    /// wire), and replayed to every attaching viewer.
    foreign_parents: std.AutoHashMapUnmanaged(u32, ForeignParent) = .empty,

    pub const ForeignParent = struct { conn: u32, surface: u32 };

    const VideoSurface = struct {
        churn: churnmod.Tracker,
        enc: wlvcodec.Encoder,
        w: i32,
        h: i32,
        seq: u32 = 0,
        needs_kf: bool = true,

        pub fn deinit(self: *VideoSurface) void {
            self.churn.deinit();
            self.enc.deinit();
        }
    };

    const ClipRead = struct {
        fd: c_int,
        buf: std.ArrayList(u8) = .empty,
    };

    pub const ClipWrite = struct {
        fd: c_int,
        buf: std.ArrayList(u8) = .empty,
        off: usize = 0,
    };

    const PasteFd = struct {
        offer: u32,
        fd: c_int,
    };

    pub const PoolMirror = struct {
        fd: c_int,
        ptr: [*]u8,
        size: usize,
        /// Live wl_buffers created from this pool. The mirror (and the
        /// tmpfs pages the open fd pins) is reclaimed only when
        /// this hits 0 on a destroyed pool — wl_shm_pool destructor
        /// semantics keep the memory alive for existing buffers.
        buffers: u32 = 0,
        destroyed: bool = false,
        /// Tracker incarnation serial (0 for dmabuf mirrors).
        serial: u64 = 0,

        pub fn unmap(m: *const PoolMirror) void {
            _ = c.munmap(m.ptr, m.size);
            _ = c.close(m.fd);
        }
    };

    pub const PixelMirror = struct {
        ptr: [*]u8,
        size: usize,
        shm: ?PoolMirror = null,
    };

    const DmabufPending = struct {
        fds: [dmabuf.MAX_PLANES]c_int = .{-1} ** dmabuf.MAX_PLANES,

        pub fn deinit(self: *DmabufPending) void {
            for (&self.fds) |*fd| {
                if (fd.* >= 0) _ = c.close(fd.*);
                fd.* = -1;
            }
        }

        pub fn takeFds(self: *DmabufPending) [dmabuf.MAX_PLANES]c_int {
            const fds = self.fds;
            self.fds = .{-1} ** dmabuf.MAX_PLANES;
            return fds;
        }
    };

    pub const DmabufMirror = struct {
        allocator: std.mem.Allocator,
        source_fds: [dmabuf.MAX_PLANES]c_int,
        linear: ?LinearMap = null,
        imported: ?dmabuf_egl.Buffer = null,
        staging: []u8,
        width: u32,
        height: u32,
        offset: u32,
        stride: u32,
        flags: u32,

        const LinearMap = struct {
            ptr: [*]u8,
            size: usize,
        };

        pub fn deinit(self: *DmabufMirror) void {
            if (self.imported) |*buffer| buffer.deinit();
            if (self.linear) |mapping| _ = c.munmap(mapping.ptr, mapping.size);
            for (&self.source_fds) |*fd| {
                if (fd.* >= 0) _ = c.close(fd.*);
                fd.* = -1;
            }
            self.allocator.free(self.staging);
        }

        pub fn capture(self: *DmabufMirror, scratch: *std.ArrayList(u8)) !void {
            if (self.linear) |mapping| {
                const fd = self.source_fds[0];
                if (fd < 0) return error.MissingFd;
                try scratch.resize(self.allocator, self.staging.len);
                if (!dmabufSync(fd, false)) return error.SyncFailed;
                const copied = copyDmabufRows(
                    scratch.items,
                    mapping.ptr[0..mapping.size],
                    self.width,
                    self.height,
                    self.offset,
                    self.stride,
                    self.flags & dmabuf.FLAG_Y_INVERT != 0,
                );
                if (!dmabufSync(fd, true)) return error.SyncFailed;
                if (!copied) return error.CaptureFailed;
                @memcpy(self.staging, scratch.items);
                return;
            }
            if (self.imported) |*buffer| {
                if (!buffer.readPixels(self.staging)) return error.CaptureFailed;
                return;
            }
            return error.CaptureFailed;
        }
    };

    /// Drop one buffer reference from an orphaned mirror; the last
    /// one frees it (orphans are destroyed by construction).
    pub fn releaseOrphan(nv: *Native, serial: u64) void {
        const om = nv.orphan_pools.getPtr(serial) orelse return;
        if (om.buffers > 0) om.buffers -= 1;
        if (om.buffers == 0) {
            log.debug("orphaned pool serial={d} freed on last buffer destroy", .{serial});
            om.unmap();
            _ = nv.orphan_pools.remove(serial);
        }
    }

    /// Unmap + close a pool mirror and tell replicas to drop their
    /// copy (the pool_destroy pipe unit compositor.zig frees on).
    pub fn reclaimPool(nv: *Native, units: *std.ArrayList(u8), a: std.mem.Allocator, id: u32) !void {
        const kv = nv.pools.fetchRemove(id) orelse return;
        _ = c.munmap(kv.value.ptr, kv.value.size);
        _ = c.close(kv.value.fd);
        try wlpipe.appendPoolMeta(units, a, .pool_destroy, id, 0);
    }

    pub fn deinit(self: *Native) void {
        self.brain.deinit();
        self.allocator.destroy(self.brain);
        var it = self.pools.valueIterator();
        while (it.next()) |p| p.unmap();
        self.pools.deinit(self.allocator);
        var oit = self.orphan_pools.valueIterator();
        while (oit.next()) |p| p.unmap();
        self.orphan_pools.deinit(self.allocator);
        var dbit = self.dmabufs.valueIterator();
        while (dbit.next()) |m| m.deinit();
        self.dmabufs.deinit(self.allocator);
        self.dmabuf_scratch.deinit(self.allocator);
        var dpit = self.dmabuf_pending.valueIterator();
        while (dpit.next()) |pending| pending.deinit();
        self.dmabuf_pending.deinit(self.allocator);
        for (self.fds.items) |fd| _ = c.close(fd);
        self.fds.deinit(self.allocator);
        for (self.out_fds.items) |fd| _ = c.close(fd);
        self.out_fds.deinit(self.allocator);
        for (self.clip_paste_fds.items) |p| _ = c.close(p.fd);
        self.clip_paste_fds.deinit(self.allocator);
        for (self.primary_paste_fds.items) |fd| _ = c.close(fd);
        self.primary_paste_fds.deinit(self.allocator);
        for (self.clip_reads.items) |*cr| {
            _ = c.close(cr.fd);
            cr.buf.deinit(self.allocator);
        }
        self.clip_reads.deinit(self.allocator);
        for (self.clip_writes.items) |*cw| {
            _ = c.close(cw.fd);
            cw.buf.deinit(self.allocator);
        }
        self.clip_writes.deinit(self.allocator);
        self.inbuf.deinit(self.allocator);
        self.unitbuf.deinit(self.allocator);
        var vit = self.vstate.valueIterator();
        while (vit.next()) |v| v.deinit();
        self.vstate.deinit(self.allocator);
        self.skipped.deinit(self.allocator);
        self.vscratch.deinit(self.allocator);
        self.vblob.deinit(self.allocator);
        self.pixscratch.deinit(self.allocator);
        self.surface_icons.deinit(self.allocator);
        self.foreign_parents.deinit(self.allocator);
        self.tracker.deinit();
        self.allocator.destroy(self);
    }

    /// Lossy-video routing for a commit (build_options.video only). Feeds
    /// per-surface churn; when the surface is HOT and looks photographic,
    /// encodes the WHOLE surface as one H.264 tile and emits a pool_vtile,
    /// returning true so the caller skips the lossless path. Any failure
    /// (odd dims, encoder open, mirror too small) returns false → lossless.
    pub fn videoCommit(nv: *Native, units: *std.ArrayList(u8), a: std.mem.Allocator, cm: anytype, mirror: PoolMirror, y0: i64, y1: i64) !bool {
        if (!nv.wants_video) return false; // no client can decode video yet
        const w = cm.info.width;
        const h = cm.info.height;
        if (w <= 0 or h <= 0 or @rem(w, 2) != 0 or @rem(h, 2) != 0) return false; // codec needs even dims
        const stride: usize = @intCast(cm.info.stride);
        const base: usize = @intCast(cm.info.offset);
        const uw: usize = @intCast(w);
        const uh: usize = @intCast(h);
        const tight = uw * 4;
        if (base + (uh - 1) * stride + tight > mirror.size) return false; // whole surface must fit

        const gop = try nv.vstate.getOrPut(nv.allocator, cm.surface);
        if (!gop.found_existing or gop.value_ptr.w != w or gop.value_ptr.h != h) {
            if (gop.found_existing) gop.value_ptr.deinit();
            var enc = wlvcodec.Encoder.initX264(nv.allocator, w, h, 30) catch {
                _ = nv.vstate.remove(cm.surface);
                return false;
            };
            const tracker = churnmod.Tracker.init(nv.allocator, @intCast(w), @intCast(h), .{}) catch {
                enc.deinit();
                _ = nv.vstate.remove(cm.surface);
                return false;
            };
            gop.value_ptr.* = .{ .churn = tracker, .enc = enc, .w = w, .h = h };
        }
        const vs = gop.value_ptr;

        // Advance churn with this commit's damage (full-width rows).
        vs.churn.noteDamage(0, @intCast(y0), w, @intCast(y1 - y0));
        vs.churn.endFrame();
        if (!vs.churn.hot(0, 0, w, h)) return false;

        // Extract the whole surface tightly (drop stride padding).
        try nv.vscratch.resize(nv.allocator, uw * uh * 4);
        for (0..uh) |r| {
            @memcpy(nv.vscratch.items[r * tight ..][0..tight], mirror.ptr[base + r * stride ..][0..tight]);
        }
        if (!contentmod.looksPhotographic(nv.vscratch.items, .{})) return false;

        const res = vs.enc.encodeTile(w, h, nv.vscratch.items, vs.needs_kf) catch return false;
        vs.needs_kf = false;

        nv.vblob.clearRetainingCapacity();
        wlvcodec.appendTile(&nv.vblob, nv.allocator, .{
            .codec = vs.enc.codec(),
            .keyframe = res.keyframe,
            .x = 0,
            .y = 0,
            .w = w,
            .h = h,
            .seq = vs.seq,
            .payload = res.bytes,
        }) catch return false;
        vs.seq +%= 1;

        try wlpipe.appendPoolVtile(units, a, cm.info.pool, @intCast(base), @intCast(stride), nv.vblob.items);
        return true;
    }

    pub fn popFd(self: *Native) ?c_int {
        if (self.fds.items.len == 0) return null;
        return self.fds.orderedRemove(0);
    }
};

pub const fillSockaddrUn = @import("sockpath.zig").fillSockaddrUn;

/// Absolute (cwd-joined) but otherwise verbatim spelling of a socket path,
/// length-checked against sockaddr_un; `canonicalSocketPath`'s first step,
/// which still has to resolve the dots and symlinks preserved here.
fn absoluteSocketSpelling(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (path.len == 0) return error.BadPath;
    const absolute = if (path[0] == '/')
        try allocator.dupe(u8, path)
    else blk: {
        var cwd_buf: [4096]u8 = undefined;
        if (c.getcwd(&cwd_buf, cwd_buf.len) == null) return error.BadPath;
        const cwd = std.mem.sliceTo(&cwd_buf, 0);
        break :blk try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd, path });
    };
    errdefer allocator.free(absolute);
    var addr: c.struct_sockaddr_un = undefined;
    try fillSockaddrUn(&addr, absolute);
    return absolute;
}

/// Resolve equivalent listener spellings to one physical path while allowing
/// the socket leaf itself not to exist yet.
pub fn canonicalSocketPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const absolute = try absoluteSocketSpelling(allocator, path);
    defer allocator.free(absolute);

    const leaf_slash = std.mem.lastIndexOfScalar(u8, absolute, '/') orelse return error.BadPath;
    const leaf = absolute[leaf_slash + 1 ..];
    if (leaf.len == 0 or std.mem.eql(u8, leaf, ".") or std.mem.eql(u8, leaf, ".."))
        return error.BadPath;
    const parent = if (leaf_slash == 0) absolute[0..1] else absolute[0..leaf_slash];

    // Resolve the parent with its original component order. In particular,
    // realpath("link/..") must walk to the symlink target and only then go up;
    // lexically deleting both components first changes POSIX path semantics.
    var prefix_end = parent.len;
    while (prefix_end > 0) {
        var prefix_z_buf: [4096]u8 = undefined;
        const prefix_z = pathZ(&prefix_z_buf, parent[0..prefix_end]) catch return error.BadPath;
        var real_buf: [4096]u8 = undefined;
        if (c.realpath(prefix_z, &real_buf)) |resolved_z| {
            const resolved = std.mem.span(resolved_z);
            const suffix = parent[prefix_end..];
            const unresolved_parent = if (std.mem.eql(u8, resolved, "/"))
                try std.fmt.allocPrint(allocator, "/{s}", .{std.mem.trimStart(u8, suffix, "/")})
            else
                try std.fmt.allocPrint(allocator, "{s}{s}", .{ resolved, suffix });
            defer allocator.free(unresolved_parent);

            // Components after the deepest existing prefix cannot be
            // symlinks yet, so lexical normalization is safe only here.
            var parts: std.ArrayList([]const u8) = .empty;
            defer parts.deinit(allocator);
            var it = std.mem.splitScalar(u8, unresolved_parent, '/');
            while (it.next()) |part| {
                if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
                if (std.mem.eql(u8, part, "..")) {
                    if (parts.items.len > 0) _ = parts.pop();
                    continue;
                }
                try parts.append(allocator, part);
            }
            var canonical_list: std.ArrayList(u8) = .empty;
            defer canonical_list.deinit(allocator);
            for (parts.items) |part| {
                try canonical_list.append(allocator, '/');
                try canonical_list.appendSlice(allocator, part);
            }
            try canonical_list.append(allocator, '/');
            try canonical_list.appendSlice(allocator, leaf);
            const canonical = try canonical_list.toOwnedSlice(allocator);
            errdefer allocator.free(canonical);
            var addr: c.struct_sockaddr_un = undefined;
            try fillSockaddrUn(&addr, canonical);
            return canonical;
        }
        const slash = std.mem.lastIndexOfScalar(u8, parent[0..prefix_end], '/') orelse return error.BadPath;
        prefix_end = if (slash == 0) 1 else slash;
        if (prefix_end == 1) {
            var root_buf: [4096]u8 = undefined;
            if (c.realpath("/", &root_buf) == null) return error.BadPath;
        }
    }
    return error.BadPath;
}

test "daemon listener paths are canonicalized before bind and export" {
    const t = std.testing;
    var cwd_buf: [4096]u8 = undefined;
    try t.expect(c.getcwd(&cwd_buf, cwd_buf.len) != null);
    const cwd = std.mem.sliceTo(&cwd_buf, 0);
    const relative = "relative-runtime/mux.sock";
    const absolute = try canonicalSocketPath(t.allocator, relative);
    defer t.allocator.free(absolute);
    const expected = try std.fmt.allocPrint(t.allocator, "{s}/{s}", .{ cwd, relative });
    defer t.allocator.free(expected);
    try t.expectEqualStrings(expected, absolute);
    try t.expect(absolute[0] == '/');
    var addr: c.struct_sockaddr_un = undefined;
    try fillSockaddrUn(&addr, absolute);
}

test "equivalent dot and symlinked socket spellings share one physical identity" {
    const t = std.testing;
    // Rooted in /tmp, NOT in the repo's .zig-cache: the last assertion
    // is a sockaddr_un length check, and a checkout under a long path
    // (a git worktree, a CI workspace) pushes the canonical path past
    // the ~108-byte cap and fails the test for the wrong reason.
    var root_buf: [64:0]u8 = undefined;
    const root = try std.fmt.bufPrintZ(&root_buf, "/tmp/sk-sockid-{d}", .{c.getpid()});
    _ = c.mkdir(root.ptr, 0o700);
    const real_rel = try std.fmt.allocPrint(t.allocator, "{s}/real", .{root});
    defer t.allocator.free(real_rel);
    const alias_rel = try std.fmt.allocPrint(t.allocator, "{s}/alias", .{root});
    defer t.allocator.free(alias_rel);
    const child_rel = try std.fmt.allocPrint(t.allocator, "{s}/child", .{real_rel});
    defer t.allocator.free(child_rel);
    var real_z_buf: [4096]u8 = undefined;
    var alias_z_buf: [4096]u8 = undefined;
    var child_z_buf: [4096]u8 = undefined;
    const real_z = try pathZ(&real_z_buf, real_rel);
    const alias_z = try pathZ(&alias_z_buf, alias_rel);
    const child_z = try pathZ(&child_z_buf, child_rel);
    try t.expect(c.mkdir(real_z, 0o700) == 0);
    try t.expect(c.mkdir(child_z, 0o700) == 0);
    try t.expect(c.symlink("real/child", alias_z) == 0);
    defer {
        _ = c.unlink(alias_z);
        _ = c.rmdir(child_z);
        _ = c.rmdir(real_z);
        _ = c.rmdir(root.ptr);
    }

    const through_real = try std.fmt.allocPrint(t.allocator, "{s}/mux.sock", .{real_rel});
    defer t.allocator.free(through_real);
    const through_alias = try std.fmt.allocPrint(t.allocator, "{s}/../mux.sock", .{alias_rel});
    defer t.allocator.free(through_alias);
    const canonical_real = try canonicalSocketPath(t.allocator, through_real);
    defer t.allocator.free(canonical_real);
    const canonical_alias = try canonicalSocketPath(t.allocator, through_alias);
    defer t.allocator.free(canonical_alias);
    try t.expectEqualStrings(canonical_real, canonical_alias);
    try t.expect(std.mem.endsWith(u8, canonical_alias, "/real/mux.sock"));
    var addr: c.struct_sockaddr_un = undefined;
    try fillSockaddrUn(&addr, canonical_alias);
}

/// An in-flight file upload from a client. The client streams bytes
/// (file_data frames); we write them straight into a file opened in
/// the session shell's working directory. Lives only for the duration
/// of one transfer — finalized by file_close or dropped with its
/// client. `xfer` is the CLIENT's id (unique per client, not globally).
pub const Upload = struct {
    allocator: std.mem.Allocator,
    client: *Client,
    xfer: u32,
    /// Open destination fd (O_WRONLY), or -1 once closed/aborted.
    fd: c_int,
    /// Bytes written so far — echoed back in file_reply for flow control.
    written: u64 = 0,
    /// Resolved absolute destination path (owned), reported to the client.
    path: []u8,

    pub fn deinit(self: *Upload) void {
        if (self.fd >= 0) _ = c.close(self.fd);
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }
};

/// An in-flight file download to a client. The daemon reads a file
/// from the remote filesystem and streams it out as file_data frames
/// (the reverse of Upload). Paced by `pumpDownloads` against the
/// client's write-buffer high-water mark so a big file can't balloon
/// memory. `xfer` is the CLIENT's id.
pub const Download = struct {
    allocator: std.mem.Allocator,
    client: *Client,
    xfer: u32,
    /// Open source fd (O_RDONLY), or -1 once finished.
    fd: c_int,
    size: u64 = 0,
    sent: u64 = 0,

    pub fn deinit(self: *Download) void {
        if (self.fd >= 0) _ = c.close(self.fd);
        self.allocator.destroy(self);
    }
};

/// One open fs directory view (fs_op open_view): a subscription — the
/// initial listing is followed by inotify-driven fs_delta pushes until
/// close_view or client death. `id` is CLIENT-chosen (client-scoped
/// namespace, no allocation round trip). `wd` is the kernel watch
/// descriptor; equal paths share one wd, so teardown only removes the
/// kernel watch when the last view on it goes (see dropFsView).
/// One in-flight incremental directory listing. Names are read (and
/// sorted) up front — one cheap readdir pass — then pumpFsListings
/// stats and streams entries in bounded, time-boxed batches as the
/// same fs_reply chunk run clients already accumulate. Afterwards the
/// directories among them get their child counts, delivered as
/// idempotent upsert deltas on the open view.
pub const FsListing = struct {
    allocator: std.mem.Allocator,
    /// Owns names, statted entries and per-batch scratch.
    arena: std.heap.ArenaAllocator,
    client: *Client,
    req: u32,
    /// Owned directory path (gpa).
    path: []u8,
    /// Owned attr spec (gpa).
    attrs: []u8,
    /// Sorted entry names (arena).
    names: [][]u8,
    idx: usize = 0,
    dev: u64 = 0,
    truncated: bool = false,
    /// Live view whose snapshot boundary this listing participates in;
    /// null for plain lists from non-view clients.
    view: ?*FsView,
    boundary_open: bool = false,
    /// Directory entries seen while statting (arena); the count phase
    /// re-sends each as an upsert with `children` filled in.
    dirs: std.ArrayList(fsserve.Entry) = .empty,
    count_idx: usize = 0,
    stage: enum { stat, count } = .stat,

    pub fn deinit(self: *FsListing) void {
        self.arena.deinit();
        self.allocator.free(self.path);
        self.allocator.free(self.attrs);
        self.allocator.destroy(self);
    }
};

pub const FsView = struct {
    allocator: std.mem.Allocator,
    client: *Client,
    id: u32,
    /// Canonicalized watched path, owned.
    path: []u8,
    /// Kernel watch descriptor (-1 where inotify is unavailable —
    /// the view then never receives deltas).
    wd: c_int,
    /// The watched directory vanished (IN_DELETE_SELF & co) — the
    /// client got `gone:true`; kept only until it closes the view.
    gone: bool = false,
    /// Comma-separated extended-attribute names this view asked for;
    /// deltas must carry the same attributes as the initial listing.
    attrs: []u8 = &.{},
    boundary: fs_boundary.Server = .{},

    pub fn deinit(self: *FsView) void {
        self.boundary.deinit(self.allocator);
        self.allocator.free(self.path);
        if (self.attrs.len > 0) self.allocator.free(self.attrs);
        self.allocator.destroy(self);
    }
};

/// One subprocess file job (fsjob.zig helper: copy/delete_tree/hash).
/// Daemon-owned and client-independent: the owner pointer only routes
/// the event stream; its death never stops the work (durable
/// transfers — the roadmap's core promise). kill = cancel,
/// SIGSTOP/SIGCONT = pause/resume.
/// In-flight debugger attach (see daemon_debug.zig).
pub const DebugJob = @import("daemon_debug.zig").DebugJob;

pub const FsJob = struct {
    pub const Op = enum { copy, delete_tree, hash, find, grep, extract, archive_create, archive_list, archive_extract, trash, trash_restore, cross_copy, panelize, live_find, thumbnail, preview, dir_size, perm_tree, media_meta, preview_transport, preview_stream, git_status, diff, split, combine, secure_delete, git_diff, disk_usage };

    /// Ops whose result is a daemon-owned scratch file (the `asset`
    /// path) that is unlinked when the job is dropped -- the ONE list
    /// the unlink and the TTL arming both read.
    pub fn producesAsset(op: Op) bool {
        return op == .thumbnail or op == .preview or op == .preview_transport or op == .preview_stream;
    }
    pub const State = enum { running, paused, done, failed, canceled };

    allocator: std.mem.Allocator,
    id: u64,
    op: Op,
    /// Event-stream target; null once the client died.
    owner: ?*Client,
    pid: c.pid_t,
    /// Helper stdout (nonblocking pipe); -1 once the helper exited.
    out_fd: c_int,
    /// Partial-line assembly for the JSON-lines progress stream.
    lbuf: std.ArrayList(u8) = .empty,
    state: State = .running,
    done: u64 = 0,
    total: u64 = 0,
    resumed_from: u64 = 0,
    hash_hex: [64]u8 = undefined,
    has_hash: bool = false,
    message: [192]u8 = undefined,
    message_len: usize = 0,
    /// find/grep: total matches streamed + cap-truncation flag.
    matches: u64 = 0,
    truncated: bool = false,
    /// disk_usage final aggregate fields not shared by transfer jobs.
    usage_items: u64 = 0,
    usage_errors: u64 = 0,
    usage_skipped: u64 = 0,
    usage_mtime_ms: i64 = 0,
    /// panelize: output lines that named nothing on disk, and the
    /// command's own exit status (-1 = it died on a signal). A nonzero
    /// status is reported, not treated as a failed job.
    rejected: u64 = 0,
    exit_status: i64 = 0,
    /// preview_stream: the source's duration, once the helper probed it.
    duration_ms: u64 = 0,
    /// preview_stream: which encoder the helper settled on (sticky,
    /// forwarded on every event), the furthest byte the reader has
    /// fetched from the spool, and whether the encoder is SIGSTOPped
    /// for running too far ahead of it (daemon_fsjobs.spoolThrottle).
    encoder: [16]u8 = undefined,
    encoder_len: usize = 0,
    spool_read_pos: u64 = 0,
    throttled: bool = false,
    /// Entry the helper is working on RIGHT NOW, and how far through
    /// its entry count it is. The helper puts the path on the wire
    /// only when it changes, so this is sticky between updates.
    cur_file: [4096]u8 = undefined,
    cur_file_len: usize = 0,
    files_done: u64 = 0,
    files_total: u64 = 0,
    /// Result paths from the DONE event (trash location + info file,
    /// extracted member path) — forwarded to the owner.
    done_path: [4096]u8 = undefined,
    done_path_len: usize = 0,
    done_text: [4096]u8 = undefined,
    done_text_len: usize = 0,
    /// Structural cause of a terminal error ("unreachable" = a
    /// cross_copy dial failed) — drives the client's coordinator
    /// fallback, so it must survive the forward.
    err_kind: [32]u8 = undefined,
    err_kind_len: usize = 0,
    src: []u8,
    dst: []u8,
    pattern: []u8,
    src_host: []u8,
    dst_host: []u8,
    client_token: []u8,
    /// Stable logical-transfer identity kept across attempts (see
    /// fsjournal.Record.transfer_token); empty for non-transfer jobs.
    transfer_token: []u8,
    /// copy: the per-entry collision policy this job was started with,
    /// kept so a restart after a daemon crash resumes with the SAME
    /// semantics rather than silently overwriting.
    conflict: []u8,
    no_replace: bool = false,
    acknowledged: bool = false,
    ack_req: u32 = 0,
    terminal_pending: bool = false,
    /// A durable move cancel fence is waiting for the helper to restore
    /// an intact quarantine or finish cleanup, then publish terminal state.
    cancel_pending: bool = false,
    /// The daemon never blocks its poll loop on the helper's install/delete
    /// election. This stays set until a nonblocking lock attempt persists
    /// cancellation or observes that the helper already committed.
    cancel_election_pending: bool = false,
    cancel_client: ?*Client = null,
    cancel_req: u32 = 0,
    cancel_reply_start: bool = false,
    /// Helper died after a durable cross-move boundary; reap replaces
    /// it with a recovery helper before exposing a terminal failure.
    restart_pending: bool = false,
    recovery_attempts: u32 = 0,
    resumable: bool = false,
    /// Short-lived client-owned helper: no journal/history and killed
    /// when its requesting client disappears.
    ephemeral: bool = false,
    /// cross_copy move: the helper deletes the verified source.
    /// Journaled — a respawned move must stay a move.
    delete_src: bool = false,
    verify: bool = false,
    /// Durable cross_copy move phase; see fsjournal.Record.phase.
    phase: [24]u8 = undefined,
    phase_len: usize = 0,
    /// Host scratch path in `dst` belongs to this job.
    owns_dst: bool = false,
    /// Host scratch source belongs to this job after its helper exits.
    owns_src: bool = false,
    /// The done path is a PERSISTENT cache file (wire-cache
    /// thumbnails): reaping this job must never unlink it.
    done_kept: bool = false,
    /// Finished temp-producing jobs stay readable until this deadline.
    cleanup_at_ms: i64 = 0,

    pub fn deinit(self: *FsJob, kill_child: bool) void {
        if (kill_child and self.out_fd >= 0 and self.pid > 0) {
            _ = c.kill(-self.pid, c.SIGKILL);
            var st: c_int = 0;
            _ = c.waitpid(self.pid, &st, 0);
        }
        if (self.out_fd >= 0) _ = c.close(self.out_fd);
        self.releaseOwnedSource();
        if (self.owns_dst) self.unlinkOwned(self.dst);
        if (producesAsset(self.op) and self.done_path_len > 0 and !self.done_kept)
            self.unlinkOwned(self.done_path[0..self.done_path_len]);
        self.lbuf.deinit(self.allocator);
        self.allocator.free(self.src);
        self.allocator.free(self.dst);
        self.allocator.free(self.pattern);
        self.allocator.free(self.src_host);
        self.allocator.free(self.dst_host);
        self.allocator.free(self.client_token);
        self.allocator.free(self.transfer_token);
        self.allocator.free(self.conflict);
        self.allocator.destroy(self);
    }

    fn unlinkOwned(self: *FsJob, path: []const u8) void {
        _ = self;
        var z: [4096:0]u8 = undefined;
        const p = std.fmt.bufPrintZ(&z, "{s}", .{path}) catch return;
        _ = c.unlink(p.ptr);
    }

    pub fn releaseOwnedSource(self: *FsJob) void {
        if (!self.owns_src) return;
        self.unlinkOwned(self.src);
        self.owns_src = false;
    }

    pub fn ownsTempPath(self: *const FsJob, path: []const u8) bool {
        const owns_done = (self.op == .thumbnail or self.op == .preview or self.op == .preview_transport) and !self.done_kept;
        return (self.owns_src and std.mem.eql(u8, self.src, path)) or
            (self.owns_dst and std.mem.eql(u8, self.dst, path)) or
            (owns_done and self.done_path_len > 0 and std.mem.eql(u8, self.done_path[0..self.done_path_len], path));
    }

    pub fn releaseTempPath(self: *FsJob, path: []const u8, now_ms: i64) bool {
        const owns_done = (self.op == .thumbnail or self.op == .preview or self.op == .preview_transport) and !self.done_kept;
        var released_src = false;
        var released_dst = false;
        var released_result = false;
        if (self.owns_src and std.mem.eql(u8, self.src, path)) {
            self.owns_src = false;
            released_src = true;
        }
        if (self.owns_dst and std.mem.eql(u8, self.dst, path)) {
            self.owns_dst = false;
            released_dst = true;
        }
        if (owns_done and self.done_path_len > 0 and std.mem.eql(u8, self.done_path[0..self.done_path_len], path)) {
            self.done_path_len = 0;
            released_result = true;
        }
        if (released_result or released_dst or
            (released_src and self.done_path_len == 0 and !self.owns_dst))
            self.cleanup_at_ms = now_ms;
        return released_src or released_dst or released_result;
    }

    pub fn setMessage(self: *FsJob, msg: []const u8) void {
        const n = @min(msg.len, self.message.len);
        @memcpy(self.message[0..n], msg[0..n]);
        self.message_len = n;
    }

    pub fn setPhase(self: *FsJob, phase: []const u8) void {
        const n = @min(phase.len, self.phase.len);
        @memcpy(self.phase[0..n], phase[0..n]);
        self.phase_len = n;
    }

    pub fn finished(self: *const FsJob) bool {
        return self.state == .done or self.state == .failed or self.state == .canceled;
    }

    pub fn retentionReady(self: *const FsJob) bool {
        return self.finished() and !self.cancel_pending and !self.cancel_election_pending and
            !self.terminal_pending and self.out_fd < 0;
    }
};

test "preview temp source release preserves result ownership" {
    const t = std.testing;
    const job = try t.allocator.create(FsJob);
    job.* = .{
        .allocator = t.allocator,
        .id = 1,
        .op = .preview_transport,
        .owner = null,
        .pid = -1,
        .out_fd = -1,
        .src = try t.allocator.dupe(u8, "/tmp/nonexistent-preview-source"),
        .dst = try t.allocator.dupe(u8, ""),
        .pattern = try t.allocator.dupe(u8, ""),
        .src_host = try t.allocator.dupe(u8, ""),
        .dst_host = try t.allocator.dupe(u8, ""),
        .client_token = try t.allocator.dupe(u8, ""),
        .transfer_token = try t.allocator.dupe(u8, ""),
        .conflict = try t.allocator.dupe(u8, ""),
        .owns_src = true,
        .cleanup_at_ms = 500,
    };
    defer job.deinit(false);
    const result = "/tmp/nonexistent-preview-result.jxl";
    @memcpy(job.done_path[0..result.len], result);
    job.done_path_len = result.len;

    try t.expect(job.releaseTempPath(job.src, 100));
    try t.expect(!job.owns_src);
    try t.expectEqual(result.len, job.done_path_len);
    try t.expectEqual(@as(i64, 500), job.cleanup_at_ms);
    try t.expect(job.releaseTempPath(result, 200));
    try t.expectEqual(@as(usize, 0), job.done_path_len);
    try t.expectEqual(@as(i64, 200), job.cleanup_at_ms);
}

test "terminal filesystem jobs are retained until helper EOF" {
    const empty: []u8 = @constCast(&[_]u8{});
    var job = FsJob{
        .allocator = std.testing.allocator,
        .id = 1,
        .op = .copy,
        .owner = null,
        .pid = 42,
        .out_fd = 9,
        .state = .done,
        .src = empty,
        .dst = empty,
        .pattern = empty,
        .src_host = empty,
        .dst_host = empty,
        .client_token = empty,
        .transfer_token = empty,
        .conflict = empty,
    };
    try std.testing.expect(!job.retentionReady());
    job.out_fd = -1;
    try std.testing.expect(job.retentionReady());
    job.terminal_pending = true;
    try std.testing.expect(!job.retentionReady());
}

pub const Daemon = struct {
    allocator: std.mem.Allocator,
    listen_fd: c_int,
    /// Owned socket path; unlinked on deinit.
    sock_path: []u8,
    /// Identity of the bound socket inode; teardown must not unlink a
    /// pathname another daemon acquired later.
    sock_dev: u128 = 0,
    sock_ino: u128 = 0,
    sessions: std.ArrayList(*Session) = .empty,
    clients: std.ArrayList(*Client) = .empty,
    channels: std.ArrayList(*Channel) = .empty,
    /// An xdg-foreign teardown queued events on a brain that is not the
    /// one currently being fed; the next tick flushes every brain with
    /// pending output (see Session.foreign).
    foreign_flush_pending: bool = false,
    /// In-flight file uploads (file_* frames), keyed by (client, xfer).
    uploads: std.ArrayList(*Upload) = .empty,
    /// In-flight file downloads (file_get), keyed by (client, xfer).
    downloads: std.ArrayList(*Download) = .empty,
    /// Open fs directory views (fs_op open_view), keyed by (client,
    /// client-chosen view id). Views die with their client.
    fs_views: std.ArrayList(*FsView) = .empty,
    /// In-flight incremental listings, advanced by pumpFsListings —
    /// bounded work per tick so one slow directory (NFS, huge) can
    /// never stall the poll loop or the other sessions.
    fs_listings: std.ArrayList(*FsListing) = .empty,
    /// Shared inotify fd backing every view (lazy; -1 until the first
    /// open_view, and permanently -1 where inotify doesn't exist).
    fs_watch: fsserve.Watcher = .{},
    /// Subprocess file jobs (copy/delete_tree/hash). Daemon-owned:
    /// they SURVIVE the requesting client (durability) — a dead owner
    /// only stops the event stream, never the work.
    fs_jobs: std.ArrayList(*FsJob) = .empty,
    next_fs_job_id: u64 = 1,
    /// In-flight `app_debug` debugger subprocesses. Unlike file jobs
    /// these are pure observation with a single reply, so a dead
    /// requester means the job is finished and dropped, not orphaned.
    debug_jobs: std.ArrayList(*DebugJob) = .empty,
    /// In-flight correlated panel relays. Payload bytes live only in client
    /// write queues; this table owns no panel document and interprets none.
    panel_routes: std.ArrayList(PanelRoute) = .empty,
    next_panel_route_id: u64 = 1 << 63,
    /// Atomic job records live beside the daemon socket and survive a
    /// daemon restart independently of any GUI client.
    fs_job_dir: []u8 = &.{},
    fs_jobs_restored: bool = false,
    next_chan_id: u32 = 1,
    /// Language-server children whose channel died: SIGTERM was sent,
    /// SIGKILL follows after a grace period, the zombie is reaped here.
    lsp_reaps: std.ArrayList(LspReap) = .empty,
    /// Monotonic client-connection id (controller labels + viewer age).
    next_client_id: u32 = 1,
    /// Monotonic id for per-session Wayland socket paths (session
    /// names are user input — not path-safe).
    next_wl_id: u32 = 1,
    /// Audio hub sockets ("pa-N") — separate counter so wl-N naming
    /// stays sequential (the smoke rigs derive it).
    next_pa_id: u32 = 1,
    /// Monotonic id for isolated sessions' private runtime dirs (same
    /// path-safety reason as next_wl_id).
    next_rt_id: u32 = 1,
    running: bool = true,
    /// Opt-in self-retirement (`--idle-exit N`): once no session (broker:
    /// no worker) and no client has existed for this long, `running`
    /// clears. 0 = live client-less forever, the per-user daemon's
    /// whole point. Workers ignore it; their one session rules them.
    idle_exit_ms: i64 = 0,
    /// When the current client-less, session-less stretch began; 0 = not idle.
    idle_since_ms: i64 = 0,
    /// Lifetime fence (`lifetime.ENV`, inherited by workers): the read end
    /// of a pipe whose writer is the owning test harness. EOF = the owner
    /// is gone by whatever path, and `running` clears. -1 = unfenced,
    /// the per-user daemon's permanent state.
    lifetime_fd: c_int = -1,
    /// Process-isolation mode (Firefox-style). A WORKER process owns exactly
    /// one session and has `control_fd` >= 0 (a socketpair to the broker)
    /// instead of a listen socket — new clients arrive as passed fds, not via
    /// accept(). A BROKER process listens, holds NO sessions, and forks one
    /// worker per session, handing client fds to workers on attach. The
    /// default (both -1 / false) is the legacy monolith — kept working until
    /// the broker path is the proven default.
    control_fd: c_int = -1,
    is_broker: bool = false,
    /// Broker only: forked session workers, by session name.
    workers: std.ArrayList(*Worker) = .empty,
    /// Worker only: an attached client's rename forwarded to the broker (the
    /// routing authority), awaiting its result.
    worker_rename_request: ?WorkerRenameRequest = null,
    next_worker_rename_request: u64 = 1,
    /// Worker only: last metadata signature pushed to the broker, so
    /// `maybePushMeta` only sends on a real change (and throttles activity).
    wpush: WorkerPush = .{},
    /// Worker only: runtime dir (owned) for the session's Wayland display /
    /// isolated rt sockets. A worker has no listen socket, so it can't derive
    /// the dir from `sock_path` ("") the way the monolith/broker does — the
    /// broker hands it the dir at fork time. null in monolith/broker.
    base_dir: ?[]u8 = null,
    /// Worker only: the broker's full listen-socket path (owned). Kept
    /// separately from `sock_path` (empty in workers so deinit never
    /// unlinks the broker's socket); the udp-ticket listener uses it to
    /// aim its bridge back at this daemon instance. null in monolith/broker.
    broker_sock: ?[]u8 = null,
    /// One EGL display/context owner per process. EGL displays are commonly
    /// shared handles, so terminating a per-channel importer could invalidate
    /// every other live app channel.
    dmabuf_importer: ?dmabuf_egl.Importer = null,
    dmabuf_capabilities: std.ArrayList(dmabuf.Capability) = .empty,
    dmabuf_initialized: bool = false,
    /// linux-dmabuf v4 `main_device` (0 = none); see dmabufMainDevice.
    drm_device: u64 = 0,
    drm_device_probed: bool = false,
    /// Worker teardown grace: once its session is gone, a worker with
    /// undelivered client bytes (the post-mortem log push + `.exit`
    /// behind an MCP client's between-tool-calls backlog) keeps
    /// serving until everything drained or this deadline passes.
    drain_deadline_ms: i64 = 0,
    /// Lazily-opened web store (history/bookmarks/site settings) under
    /// $XDG_STATE_HOME/sketerm/web — see daemon_serve.handleWebOp.
    web_store: ?@import("webstore.zig").WebStore = null,
    /// Headless browser-profile stores this daemon OWNS, one per
    /// instance key, opened on the first web_op profile op naming that
    /// key and held (flock included) for the daemon's lifetime — the
    /// whole point: the store's owner must outlive every MCP client so
    /// N of them can share one profile namespace. Broker/monolith only;
    /// workers refuse the ops (daemon_serve.handleWebProfileOp).
    web_profile_stores: std.ArrayList(NamedProfileStore) = .empty,
    /// Browser engines this broker SPAWNED (web_op engine_open). The
    /// engine reaps ITSELF through its linger TTL; this list exists to
    /// answer "is one already running", to waitpid the child once it
    /// has exited, and to hand successors the socket path. Never
    /// killed at daemon teardown: a lingering engine keeps serving its
    /// clients without the broker (it is reparented and self-reaps).
    web_engines: std.ArrayList(WebEngine) = .empty,

    pub const NamedProfileStore = struct {
        /// Owned copy of the instance key the client sent.
        key: []u8,
        store: @import("../ipc/webprofiles.zig").Store,
    };

    pub const WebEngine = struct {
        diagnostic: @import("../web/diagnostic.zig").Capture = .{},
        /// Owned instance key.
        key: []u8,
        pid: c.pid_t,
        /// Owned listening-socket path.
        sock: []u8,
    };

    const SocketPathState = enum { live, stale, unknown };

    fn socketPathState(sock_path: []const u8) SocketPathState {
        const fd = @import("../util/platform.zig").socketCloexec(c.AF_UNIX, c.SOCK_STREAM, 0);
        if (fd < 0) return .unknown;
        defer _ = c.close(fd);
        var addr: c.struct_sockaddr_un = undefined;
        fillSockaddrUn(&addr, sock_path) catch return .unknown;
        const rc = c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un));
        if (rc == 0) return .live;
        return switch (std.posix.errno(rc)) {
            .CONNREFUSED, .NOENT => .stale,
            else => .unknown,
        };
    }

    fn bindSocket(fd: c_int, addr: *c.struct_sockaddr_un) !void {
        const rc = c.bind(fd, @ptrCast(addr), @sizeOf(c.struct_sockaddr_un));
        if (rc == 0) return;
        if (std.posix.errno(rc) == .ADDRINUSE) return error.AlreadyRunning;
        return error.BindFailed;
    }

    /// Where this socket's fs-job journals live: under the STATE dir,
    /// not the runtime dir, so an interrupted transfer's staged data
    /// (and a completed-but-uncleaned move's quarantine identity) can
    /// still be found after a reboot clears $XDG_RUNTIME_DIR. Keyed by
    /// a hash of the CANONICAL socket path — canonicalized here, so any
    /// spelling of one listener (relative, dotted, symlinked) maps to
    /// one journal namespace and external callers (smoke_fs) can pass
    /// the path exactly as they would to `init`.
    pub fn fsJobsDirAlloc(allocator: std.mem.Allocator, sock_path: []const u8) ![]u8 {
        const canonical = try canonicalSocketPath(allocator, sock_path);
        defer allocator.free(canonical);
        const h = std.hash.Fnv1a_64.hash(canonical);
        var state_buf: [4096]u8 = undefined;
        const state: ?[]const u8 = blk: {
            if (std.c.getenv("XDG_STATE_HOME")) |sh| {
                const s = std.mem.span(sh);
                if (s.len > 0) break :blk std.fmt.bufPrint(&state_buf, "{s}/sketerm", .{s}) catch null;
            }
            if (std.c.getenv("HOME")) |home|
                break :blk std.fmt.bufPrint(&state_buf, "{s}/.local/state/sketerm", .{std.mem.span(home)}) catch null;
            break :blk null;
        };
        const base = state orelse {
            // No resolvable state dir: fall back to the socket-sibling
            // location (pre-relocation behavior, reboot-fragile).
            const dir_end = std.mem.lastIndexOfScalar(u8, canonical, '/') orelse return error.BadPath;
            return std.fmt.allocPrint(allocator, "{s}/fsjobs", .{canonical[0..dir_end]});
        };
        return std.fmt.allocPrint(allocator, "{s}/fsjobs/{x:0>16}", .{ base, h });
    }

    /// One-time adoption of journals from the pre-relocation socket-sibling
    /// directory. rename first; the runtime dir is usually a different
    /// filesystem, so EXDEV falls back to a staged copy plus rename, which a
    /// crash can only ever leave behind as a discardable `.part` file.
    /// Best effort: a record that cannot move stays where the old code would
    /// still have found nothing anyway.
    fn migrateLegacyFsJournals(sock_dir: []const u8, new_dir: []const u8) void {
        var legacy_buf: [4096:0]u8 = undefined;
        const legacy = std.fmt.bufPrintZ(&legacy_buf, "{s}/fsjobs", .{sock_dir}) catch return;
        if (std.mem.eql(u8, legacy, new_dir)) return;
        const dir = c.opendir(legacy.ptr) orelse return;
        defer _ = c.closedir(dir);
        var target_ready = false;
        while (c.readdir(dir)) |de| {
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&de.*.d_name)));
            if (!std.mem.endsWith(u8, name, ".json")) continue;
            if (!target_ready) {
                if (!fsjournal.ensureDir(new_dir)) return;
                target_ready = true;
            }
            var from_buf: [4096:0]u8 = undefined;
            var to_buf: [4096:0]u8 = undefined;
            var stage_buf: [4096:0]u8 = undefined;
            const from = std.fmt.bufPrintZ(&from_buf, "{s}/{s}", .{ legacy, name }) catch continue;
            const to = std.fmt.bufPrintZ(&to_buf, "{s}/{s}", .{ new_dir, name }) catch continue;
            if (c.rename(from.ptr, to.ptr) == 0) continue;
            const stage = std.fmt.bufPrintZ(&stage_buf, "{s}/.{s}.{d}.part", .{ new_dir, name, c.getpid() }) catch continue;
            if (copyJournalFile(from.ptr, stage.ptr) and c.rename(stage.ptr, to.ptr) == 0) {
                _ = c.unlink(from.ptr);
            } else _ = c.unlink(stage.ptr);
        }
    }

    /// Byte copy into a staging path; false means nothing usable was written.
    fn copyJournalFile(from: [*:0]const u8, stage: [*:0]const u8) bool {
        _ = c.unlink(stage);
        const in = c.fopen(from, "rb") orelse return false;
        defer _ = c.fclose(in);
        const out = c.fopen(stage, "wb") orelse return false;
        var ok = true;
        var buf: [16 * 1024]u8 = undefined;
        while (true) {
            const n = c.fread(&buf, 1, buf.len, in);
            if (n == 0) break;
            if (c.fwrite(&buf, 1, n, out) != n) {
                ok = false;
                break;
            }
        }
        if (c.fclose(out) != 0) ok = false;
        return ok;
    }

    pub fn init(allocator: std.mem.Allocator, sock_path: []const u8) !*Daemon {
        const absolute_path = try canonicalSocketPath(allocator, sock_path);
        var path_owned = true;
        errdefer if (path_owned) allocator.free(absolute_path);
        const dir_end = std.mem.lastIndexOfScalar(u8, absolute_path, '/') orelse return error.BadPath;
        // mkdir -p the parent (one level is enough in practice:
        // $XDG_RUNTIME_DIR exists; we create the sketerm dir).
        var z_buf: [4096]u8 = undefined;
        _ = c.mkdir(try pathZ(&z_buf, absolute_path[0..dir_end]), 0o700);

        // Serialize stale-socket recovery. Without this lock, two starters can
        // both observe the same stale inode and one can unlink the other's new
        // listener between its bind and listen calls.
        var lock_buf: [4096:0]u8 = undefined;
        const lock_path = std.fmt.bufPrintZ(&lock_buf, "{s}.lock", .{absolute_path}) catch return error.BadPath;
        const lock_fd = c.open(lock_path.ptr, c.O_CREAT | c.O_RDWR | c.O_CLOEXEC, @as(c_uint, 0o600));
        if (lock_fd < 0) return error.LockFailed;
        defer _ = c.close(lock_fd);
        var lock = std.mem.zeroes(c.struct_flock);
        lock.l_type = c.F_WRLCK;
        lock.l_whence = c.SEEK_SET;
        if (c.fcntl(lock_fd, c.F_SETLKW, &lock) < 0) return error.LockFailed;

        const fd = @import("../util/platform.zig").socketCloexec(c.AF_UNIX, c.SOCK_STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        errdefer _ = c.close(fd);
        var addr: c.struct_sockaddr_un = undefined;
        try fillSockaddrUn(&addr, absolute_path);
        bindSocket(fd, &addr) catch |err| switch (err) {
            error.AlreadyRunning => switch (socketPathState(absolute_path)) {
                .live, .unknown => return error.AlreadyRunning,
                .stale => {
                    var st: c.struct_stat = undefined;
                    const path = try pathZ(&z_buf, absolute_path);
                    if (c.lstat(path, &st) != 0 or (st.st_mode & c.S_IFMT) != c.S_IFSOCK)
                        return error.BindFailed;
                    if (c.unlink(path) != 0 and std.posix.errno(-1) != .NOENT)
                        return error.BindFailed;
                    try bindSocket(fd, &addr);
                },
            },
            else => return err,
        };
        if (c.listen(fd, 8) != 0) return error.ListenFailed;
        var bound_st: c.struct_stat = undefined;
        if (c.lstat(try pathZ(&z_buf, absolute_path), &bound_st) != 0) return error.StatFailed;

        const job_dir = try fsJobsDirAlloc(allocator, absolute_path);
        errdefer allocator.free(job_dir);
        const self = try allocator.create(Daemon);
        self.* = .{
            .allocator = allocator,
            .listen_fd = fd,
            .sock_path = absolute_path,
            .sock_dev = @intCast(bound_st.st_dev),
            .sock_ino = @intCast(bound_st.st_ino),
            .fs_job_dir = job_dir,
        };
        path_owned = false;
        // No eager ensureDir: journal saves create the directory on
        // first use, so short-lived isolated daemons leave no empty
        // per-socket litter under the user's state dir.
        migrateLegacyFsJournals(absolute_path[0..dir_end], job_dir);
        return self;
    }

    pub fn deinit(self: *Daemon) void {
        for (self.fs_jobs.items) |j| j.deinit(true);
        self.fs_jobs.deinit(self.allocator);
        for (self.debug_jobs.items) |j| {
            _ = c.kill(-j.pid, c.SIGKILL);
            j.deinit();
        }
        self.debug_jobs.deinit(self.allocator);
        self.panel_routes.deinit(self.allocator);
        for (self.fs_views.items) |v| v.deinit();
        self.fs_views.deinit(self.allocator);
        for (self.fs_listings.items) |l| l.deinit();
        self.fs_listings.deinit(self.allocator);
        self.fs_watch.deinit();
        for (self.uploads.items) |u| u.deinit();
        self.uploads.deinit(self.allocator);
        for (self.downloads.items) |dl| dl.deinit();
        self.downloads.deinit(self.allocator);
        // Language-server children die with the daemon: SIGKILL the
        // groups (no grace at teardown) and reap so nothing zombifies.
        for (self.channels.items) |ch| {
            if (ch.child_pid > 0) {
                _ = c.kill(-ch.child_pid, c.SIGKILL);
                var st: c_int = 0;
                _ = c.waitpid(ch.child_pid, &st, 0);
            }
        }
        for (self.lsp_reaps.items) |r| {
            _ = c.kill(-r.pid, c.SIGKILL);
            var st: c_int = 0;
            _ = c.waitpid(r.pid, &st, 0);
        }
        self.lsp_reaps.deinit(self.allocator);
        for (self.channels.items) |ch| ch.deinit();
        self.channels.deinit(self.allocator);
        if (self.dmabuf_importer) |*importer| importer.deinit();
        self.dmabuf_capabilities.deinit(self.allocator);
        if (self.web_store) |*ws| ws.deinit();
        for (self.web_profile_stores.items) |*nps| {
            nps.store.deinit();
            self.allocator.free(nps.key);
        }
        self.web_profile_stores.deinit(self.allocator);
        // Engines are NOT killed: a lingering engine serves its clients
        // without the broker and self-reaps on its TTL (init adopts and
        // reaps the pid once this process is gone). Only collect the
        // already-exited.
        for (self.web_engines.items) |*e| {
            e.diagnostic.deinit();
            var st: c_int = 0;
            if (e.pid > 0) _ = c.waitpid(e.pid, &st, c.WNOHANG);
            self.allocator.free(e.key);
            self.allocator.free(e.sock);
        }
        self.web_engines.deinit(self.allocator);
        for (self.clients.items) |cl| cl.deinit();
        self.clients.deinit(self.allocator);
        for (self.sessions.items) |s| s.deinit();
        self.sessions.deinit(self.allocator);
        for (self.workers.items) |w| w.deinit();
        self.workers.deinit(self.allocator);
        // Hold the startup lock while closing and unlinking. Otherwise a new
        // daemon can replace the stale pathname between lstat and unlink.
        var lock_fd: c_int = -1;
        var lock_buf: [4096:0]u8 = undefined;
        if (self.sock_path.len > 0) {
            if (std.fmt.bufPrintZ(&lock_buf, "{s}.lock", .{self.sock_path})) |lock_path| {
                const fd = c.open(lock_path.ptr, c.O_CREAT | c.O_RDWR | c.O_CLOEXEC, @as(c_uint, 0o600));
                if (fd >= 0) {
                    var lock = std.mem.zeroes(c.struct_flock);
                    lock.l_type = c.F_WRLCK;
                    lock.l_whence = c.SEEK_SET;
                    if (c.fcntl(fd, c.F_SETLKW, &lock) == 0) lock_fd = fd else _ = c.close(fd);
                }
            } else |_| {}
        }
        if (self.listen_fd >= 0) _ = c.close(self.listen_fd);
        if (self.control_fd >= 0) _ = c.close(self.control_fd);
        if (self.base_dir) |d| self.allocator.free(d);
        if (self.broker_sock) |s| self.allocator.free(s);
        // Only unlink the exact inode this daemon bound. A replaced pathname
        // belongs to another instance and must survive our teardown.
        if (lock_fd >= 0) {
            var z_buf: [4096]u8 = undefined;
            if (pathZ(&z_buf, self.sock_path)) |p| {
                var st: c.struct_stat = undefined;
                if (c.lstat(p, &st) == 0 and
                    @as(u128, @intCast(st.st_dev)) == self.sock_dev and
                    @as(u128, @intCast(st.st_ino)) == self.sock_ino)
                {
                    _ = c.unlink(p);
                }
            } else |_| {}
            _ = c.close(lock_fd);
        }
        self.allocator.free(self.sock_path);
        if (self.fs_job_dir.len > 0) self.allocator.free(self.fs_job_dir);
        self.allocator.destroy(self);
    }

    /// Run until a SHUTDOWN frame arrives or `running` is cleared.
    pub fn run(self: *Daemon) !void {
        log.init();
        self.restoreFsJobs();
        log.info("daemon up v{s} mode={s} socket={s}", .{
            version.string,
            if (self.is_broker) "broker" else if (self.isWorker()) "worker" else "monolith",
            if (self.sock_path.len > 0) self.sock_path else "-",
        });
        while (self.running) try self.tick(500);
        log.info("daemon shutting down", .{});
        // The run loop exits the same tick `running` is cleared, so any frame
        // queued by the shutdown path (`.gone` on `.shutdown`, or a worker's
        // `.gone` on a broker `'K'`) is still sitting in each client's wbuf —
        // POLLOUT for this tick was computed before the frame existed, so
        // `clientWritable` never ran for it. Without a final flush the client
        // sees a bare EOF and the GUI mistakes a clean retire for a crash
        // (sad-face). Drain the small tail before deinit closes the fds; the
        // kernel still delivers it after we close.
        self.flushClientsFinal();
    }

    /// Best-effort final drain of every client's outbound queues before teardown. The
    /// only frames queued at this point are tiny shutdown notices, so a short
    /// bounded POLLOUT wait per round is plenty.
    fn flushClientsFinal(self: *Daemon) void {
        var rounds: usize = 0;
        while (rounds < 8) : (rounds += 1) {
            var pending = false;
            for (self.clients.items) |cl| {
                if (cl.dead or cl.queuedBytes() == 0) continue;
                var pfd = c.struct_pollfd{ .fd = cl.fd, .events = c.POLLOUT, .revents = 0 };
                _ = c.poll(&pfd, 1, 50);
                if (pfd.revents & c.POLLOUT != 0) self.clientWritable(cl);
                if (!cl.dead and cl.queuedBytes() > 0) pending = true;
            }
            if (!pending) break;
        }
    }

    /// Pace self-clocked audio (mux/pulse.zig): advance every audio
    /// channel's stream clocks to now, flush the REQUESTs / drain
    /// replies they emit toward the app, and return the poll timeout
    /// clamped to the nearest audio deadline so pacing stays on time.
    fn pulseTick(self: *Daemon, timeout_ms: i32) i32 {
        var to = timeout_ms;
        const now = nowMs();
        for (self.channels.items) |ch| {
            if (ch.dead) continue;
            const srv = ch.pa orelse continue;
            srv.has_viewer = self.sessionHasReadyAudioViewer(ch.session.?);
            const deadline = srv.tick(now) catch {
                self.closeChannel(ch, true);
                continue;
            };
            const out = srv.takeOut();
            if (out.len > 0) {
                ch.pending.appendSlice(self.allocator, out) catch {
                    self.closeChannel(ch, true);
                    continue;
                };
                srv.clearOut();
                self.channelWritable(ch);
            }
            if (deadline) |d| {
                const rel: i32 = @intCast(std.math.clamp(d - now, 1, 1000));
                if (rel < to) to = rel;
            }
        }
        return to;
    }

    /// One poll iteration. Exposed for tests.
    pub fn tick(self: *Daemon, timeout_ms: i32) !void {
        const tick_now = nowMs();
        self.panelRoutesTick(tick_now);
        self.retryPendingSnapshots();
        var poll_timeout = self.pulseTick(timeout_ms);
        // Cast playback: deliver due events, clamp to the next deadline.
        poll_timeout = self.castTick(poll_timeout);
        // Listing work pending: don't sleep on poll. The pump makes
        // bounded progress per tick, so this converges rather than
        // spins; usually POLLOUT re-wakes the loop anyway, but the
        // count phase can have ticks that emit nothing.
        if (self.fs_listings.items.len > 0) poll_timeout = 0;
        var fds: std.ArrayList(c.struct_pollfd) = .empty;
        defer fds.deinit(self.allocator);

        try fds.append(self.allocator, .{ .fd = self.listen_fd, .events = c.POLLIN, .revents = 0 });
        // Worker: the broker↔worker control channel (passed client fds + kill/
        // rename/metadata). -1 in broker/monolith → ignored by poll.
        const control_idx = fds.items.len;
        try fds.append(self.allocator, .{ .fd = self.control_fd, .events = c.POLLIN, .revents = 0 });
        // Lifetime fence: EOF means the owning harness is gone. -1 when
        // unfenced → ignored by poll.
        const lifetime_idx = fds.items.len;
        try fds.append(self.allocator, .{ .fd = self.lifetime_fd, .events = c.POLLIN, .revents = 0 });
        // Shared inotify fd for fs directory views (-1 until the first
        // open_view → ignored by poll).
        const fs_idx = fds.items.len;
        try fds.append(self.allocator, .{ .fd = self.fs_watch.fd, .events = c.POLLIN, .revents = 0 });
        const client_base = fds.items.len;
        const n_clients_built = self.clients.items.len;
        for (self.clients.items) |cl| {
            var ev: c_short = c.POLLIN;
            if (cl.queuedBytes() > 0) ev |= c.POLLOUT;
            try fds.append(self.allocator, .{ .fd = cl.fd, .events = ev, .revents = 0 });
        }
        const session_base = fds.items.len;
        const n_sessions_built = self.sessions.items.len;
        for (self.sessions.items) |s| {
            // Client input the slave could not take yet waits in the
            // Pty's queue; the master's POLLOUT is what drains it.
            var ev: c_short = c.POLLIN;
            if (s.ptyPtr()) |p| {
                if (p.queuedBytes() > 0) ev |= c.POLLOUT;
            }
            try fds.append(self.allocator, .{
                .fd = if (s.exited) -1 else s.masterFd(),
                .events = ev,
                .revents = 0,
            });
        }
        const hub_base = fds.items.len;
        for (self.sessions.items) |s| {
            try fds.append(self.allocator, .{
                .fd = s.wl_hub_fd, // -1 entries are ignored by poll
                .events = c.POLLIN,
                .revents = 0,
            });
        }
        const pa_base = fds.items.len;
        for (self.sessions.items) |s| {
            try fds.append(self.allocator, .{
                .fd = s.pa_hub_fd, // audio hub listener (-1 = none)
                .events = c.POLLIN,
                .revents = 0,
            });
        }
        // X11 listeners stay daemon-owned across satellite restarts. A
        // pending X client wakes a dead satellite without polling or sleeps.
        const x11_base = fds.items.len;
        for (self.sessions.items) |s| {
            try fds.append(self.allocator, .{
                .fd = if (s.xwayland) |*xwl| xwl.unix_fd else -1,
                .events = c.POLLIN,
                .revents = 0,
            });
            try fds.append(self.allocator, .{
                .fd = if (s.xwayland) |*xwl| xwl.abstract_fd else -1,
                .events = c.POLLIN,
                .revents = 0,
            });
        }
        // Window-stream wakeup pipes: SCK delivers frames on its own
        // dispatch queues — a readable byte here just ends the poll
        // wait early so pumpWinstreams() drains with low latency.
        // No revents handling: the source reads its pipe dry in
        // poll(). Only polled while a live channel exists — without
        // one nothing drains the pipe, and a permanently-readable fd
        // would spin this loop hot.
        for (self.sessions.items) |s| {
            var ws_fd: c_int = -1;
            if (s.winstream) |ws| {
                for (self.channels.items) |ch| {
                    if (ch.session == s and !ch.dead and ch.native == null and ch.client != null and !ch.client.?.dead) {
                        ws_fd = ws.pollFd();
                        break;
                    }
                }
            }
            try fds.append(self.allocator, .{
                .fd = ws_fd,
                .events = c.POLLIN,
                .revents = 0,
            });
        }
        const chan_base = fds.items.len;
        const n_channels_built = self.channels.items.len;
        for (self.channels.items) |ch| {
            var ev: c_short = if (ch.close_after_flush) 0 else c.POLLIN;
            if (ch.pending.items.len > 0) ev |= c.POLLOUT;
            try fds.append(self.allocator, .{
                .fd = if (ch.dead) -1 else ch.fd,
                .events = ev,
                .revents = 0,
            });
        }
        const clip_base = fds.items.len;
        for (self.channels.items) |ch| {
            if (ch.native) |nv| {
                for (nv.clip_reads.items) |cr| {
                    try fds.append(self.allocator, .{
                        .fd = if (ch.dead) -1 else cr.fd,
                        .events = c.POLLIN,
                        .revents = 0,
                    });
                }
            }
        }
        // Paste pipes with bytes the app has not read yet.
        const clipw_base = fds.items.len;
        for (self.channels.items) |ch| {
            if (ch.native) |nv| {
                for (nv.clip_writes.items) |cw| {
                    try fds.append(self.allocator, .{
                        .fd = if (ch.dead) -1 else cw.fd,
                        .events = c.POLLOUT,
                        .revents = 0,
                    });
                }
            }
        }
        // Broker: each worker's control channel — readable = a metadata push
        // ('M'); HUP/error = the worker process exited (reap removes it).
        const worker_base = fds.items.len;
        const n_workers_built = self.workers.items.len;
        for (self.workers.items) |w| {
            try fds.append(self.allocator, .{
                .fd = if (w.dead) -1 else w.control_fd,
                .events = c.POLLIN,
                .revents = 0,
            });
        }
        // File-job helper stdout pipes (-1 once exited → ignored).
        const fsjob_base = fds.items.len;
        const n_fsjobs_built = self.fs_jobs.items.len;
        for (self.fs_jobs.items) |j| {
            try fds.append(self.allocator, .{
                .fd = j.out_fd,
                .events = c.POLLIN,
                .revents = 0,
            });
        }
        // Debugger job pipes.
        const debugjob_base = fds.items.len;
        const n_debugjobs_built = self.debug_jobs.items.len;
        for (self.debug_jobs.items) |j| {
            try fds.append(self.allocator, .{
                .fd = j.out_fd,
                .events = c.POLLIN,
                .revents = 0,
            });
        }
        // A debugger job that never speaks still has to hit its
        // deadline, so don't sleep the loop out past it.
        if (self.debug_jobs.items.len > 0 and (poll_timeout < 0 or poll_timeout > 250)) poll_timeout = 250;
        if (self.panel_routes.items.len > 0 and (poll_timeout < 0 or poll_timeout > 250)) poll_timeout = 250;

        const pr = c.poll(fds.items.ptr, @intCast(fds.items.len), poll_timeout);
        if (pr < 0) return; // EINTR etc — next tick retries

        if (self.listen_fd >= 0 and fds.items[0].revents & c.POLLIN != 0) self.acceptClient();
        if (self.control_fd >= 0 and fds.items[control_idx].revents & (c.POLLIN | c.POLLHUP | c.POLLERR) != 0)
            self.workerOnControl();
        if (self.lifetime_fd >= 0 and lifetime.tripped(self.lifetime_fd, fds.items[lifetime_idx].revents)) {
            log.info("lifetime fence closed: the owning process is gone; shutting down", .{});
            self.running = false;
        }
        if (self.fs_watch.fd >= 0 and fds.items[fs_idx].revents & c.POLLIN != 0)
            self.fsWatchReadable();

        // Snapshot counts: acceptClient/handleSpawn/attach run inside
        // the loops below and APPEND to these lists. Entries appended
        // this tick have no slot in this tick's poll set, so iterating
        // them would read a stale slot (a later base's revents) and
        // could fire a blocking read on a fd that was never polled.
        // They get serviced next tick. Lists only grow during a tick,
        // so n_* <= items.len always holds.
        const n_clients = n_clients_built;
        const n_sessions = n_sessions_built;
        const n_channels = n_channels_built;

        var i: usize = 0;
        while (i < n_clients) : (i += 1) {
            const cl = self.clients.items[i];
            const re = fds.items[client_base + i].revents;
            // POLLIN before POLLHUP: a client that writes its last
            // frame and closes raises both at once, and the data is
            // still readable. Declaring it dead first silently drops
            // that final input (a `mux send`'s Enter, typically).
            // clientReadable flags dead itself once read() hits EOF.
            if (re & c.POLLIN != 0) {
                self.clientReadable(cl);
            } else if (re & (c.POLLHUP | c.POLLERR) != 0) {
                cl.dead = true;
                continue;
            }
            if (re & c.POLLOUT != 0 and !cl.dead) self.clientWritable(cl);
        }

        i = 0;
        while (i < n_sessions) : (i += 1) {
            const s = self.sessions.items[i];
            const re = fds.items[session_base + i].revents;
            if (re & (c.POLLIN | c.POLLHUP | c.POLLERR) != 0) self.drainSession(s);
            // After the read: a dead child raises HUP alongside OUT, and
            // drainSession marks the exit that makes the flush moot.
            if (!s.exited and re & c.POLLOUT != 0) self.flushSessionInput(s);
        }

        i = 0;
        while (i < n_sessions) : (i += 1) {
            const s = self.sessions.items[i];
            if (fds.items[hub_base + i].revents & c.POLLIN != 0) self.acceptWaylandApp(s);
            if (fds.items[pa_base + i].revents & c.POLLIN != 0) self.acceptAudioApp(s);
            if (s.xwayland) |*xwl| {
                xwl.reap();
                const x_re = fds.items[x11_base + i * 2].revents |
                    fds.items[x11_base + i * 2 + 1].revents;
                if (x_re & c.POLLIN != 0) xwl.maybeStart();
            }
        }

        i = 0;
        while (i < n_channels) : (i += 1) {
            const ch = self.channels.items[i];
            const re = fds.items[chan_base + i].revents;
            if (ch.dead) continue;
            if (re & c.POLLIN != 0 and !ch.close_after_flush) self.channelReadable(ch);
            if (!ch.dead and re & c.POLLOUT != 0) self.channelWritable(ch);
            if (!ch.dead and re & (c.POLLHUP | c.POLLERR) != 0 and re & c.POLLIN == 0)
                self.closeChannel(ch, true);
        }

        // Clipboard-fetch pipes (snapshot the count: clip_reads may
        // shrink while we drain, never grow — chan reads above can
        // append, but those fds weren't polled this tick).
        var clip_idx: usize = 0;
        i = 0;
        while (i < n_channels) : (i += 1) {
            const ch = self.channels.items[i];
            const nv = ch.native orelse continue;
            var j: usize = 0;
            while (j < nv.clip_reads.items.len and clip_base + clip_idx < clipw_base) {
                const re = fds.items[clip_base + clip_idx].revents;
                clip_idx += 1;
                if (re & (c.POLLIN | c.POLLHUP) != 0 and !ch.dead) {
                    if (self.clipReadable(ch, j)) continue; // removed; j stays
                }
                j += 1;
            }
        }

        // Paste pipes (same shape as the clipboard reads above: the
        // entry list only shrinks while we drain).
        var clipw_idx: usize = 0;
        i = 0;
        while (i < n_channels) : (i += 1) {
            const ch = self.channels.items[i];
            const nv = ch.native orelse continue;
            var j: usize = 0;
            while (j < nv.clip_writes.items.len and clipw_base + clipw_idx < worker_base) {
                const re = fds.items[clipw_base + clipw_idx].revents;
                clipw_idx += 1;
                if (re & (c.POLLOUT | c.POLLERR | c.POLLHUP) != 0 and !ch.dead) {
                    if (daemon_native.clipWritable(nv, j)) continue; // removed; j stays
                }
                j += 1;
            }
        }

        // Broker: drain worker control channels (metadata pushes + exit).
        i = 0;
        while (i < n_workers_built) : (i += 1) {
            const w = self.workers.items[i];
            if (w.dead) continue;
            const re = fds.items[worker_base + i].revents;
            if (re & c.POLLIN != 0) {
                self.brokerOnWorkerControl(w);
            } else if (re & (c.POLLHUP | c.POLLERR) != 0) {
                // Worker process gone (clean exit or crash) — reap removes it.
                w.dead = true;
            }
        }

        // File-job progress pipes. POLLIN before HUP: an exiting
        // helper's final done-line is still readable at HUP time.
        i = 0;
        while (i < n_fsjobs_built) : (i += 1) {
            const j = self.fs_jobs.items[i];
            if (j.out_fd < 0) continue;
            const re = fds.items[fsjob_base + i].revents;
            if (re & (c.POLLIN | c.POLLHUP | c.POLLERR) != 0) self.fsJobReadable(j);
        }

        // Debugger pipes. Servicing one can REMOVE it from the list, so
        // collect the ready pointers before touching any of them —
        // indexing on after a removal would skip or misattribute a job.
        {
            var ready: [daemon_debug.MAX_JOBS]*DebugJob = undefined;
            var n_ready: usize = 0;
            i = 0;
            while (i < n_debugjobs_built and n_ready < ready.len) : (i += 1) {
                const j = self.debug_jobs.items[i];
                if (j.out_fd < 0) continue;
                const re = fds.items[debugjob_base + i].revents;
                if (re & (c.POLLIN | c.POLLHUP | c.POLLERR) == 0) continue;
                ready[n_ready] = j;
                n_ready += 1;
            }
            for (ready[0..n_ready]) |j| self.debugJobReadable(j);
            self.debugJobsTick();
        }

        self.pumpWinstreams();
        self.pumpDownloads();
        self.pumpFsListings();
        // Worker: tell the broker our latest metadata (throttled).
        if (self.control_fd >= 0 and !self.is_broker) self.maybePushMeta();
        self.refreshDetachedFsJobs();
        self.reap();
        self.flushPendingBrains();
    }

    fn acceptClient(self: *Daemon) void {
        const fd = c.accept(self.listen_fd, null, null);
        if (fd < 0) return;
        _ = c.fcntl(fd, c.F_SETFD, c.FD_CLOEXEC);
        // Non-blocking: the single-threaded poll loop must never block
        // in read() on a silent client (a brand-new accept this tick
        // isn't in the poll set yet, and a stale-slot read could fire).
        const fl = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
        _ = c.fcntl(fd, c.F_SETFL, fl | c.O_NONBLOCK);
        const cl = self.allocator.create(Client) catch {
            _ = c.close(fd);
            return;
        };
        cl.* = .{ .allocator = self.allocator, .fd = fd, .id = self.next_client_id };
        self.next_client_id += 1;
        self.clients.append(self.allocator, cl) catch {
            cl.deinit();
            return;
        };
    }

    // ── Client serving (broker/worker, frames, fs ops): split out to daemon_serve.zig ──
    const daemon_serve = @import("daemon_serve.zig");
    pub const initWorker = daemon_serve.initWorker;
    pub const runWorker = daemon_serve.runWorker;
    const workerOnControl = daemon_serve.workerOnControl;
    const PassedClient = daemon_serve.PassedClient;
    const addPassedClient = daemon_serve.addPassedClient;
    const brokerOnWorkerControl = daemon_serve.brokerOnWorkerControl;
    const workerRequestRename = daemon_serve.workerRequestRename;
    const applyWorkerReady = daemon_serve.applyWorkerReady;
    const replyPendingSpawn = daemon_serve.replyPendingSpawn;
    const maybePushMeta = daemon_serve.maybePushMeta;
    const controlRecv = daemon_serve.controlRecv;
    const clientReadable = daemon_serve.clientReadable;
    const pumpFsListings = daemon_serve.pumpFsListings;
    const clientWritable = daemon_serve.clientWritable;
    const handleFrame = daemon_serve.handleFrame;
    const findChannel = daemon_serve.findChannel;
    const findUpload = daemon_serve.findUpload;
    const fileReply = daemon_serve.fileReply;
    const dropUpload = daemon_serve.dropUpload;
    const uploadBaseName = daemon_serve.uploadBaseName;
    const openUploadDest = daemon_serve.openUploadDest;
    const handleFileOpen = daemon_serve.handleFileOpen;
    const handleFileData = daemon_serve.handleFileData;
    const handleFileClose = daemon_serve.handleFileClose;
    const dropDownload = daemon_serve.dropDownload;
    const handleFileGet = daemon_serve.handleFileGet;
    const handleAppList = daemon_serve.handleAppList;
    const handleAppA11y = daemon_serve.handleAppA11y;
    const handleRecStart = daemon_serve.handleRecStart;
    const ListEntry = daemon_serve.ListEntry;
    const listingError = daemon_serve.listingError;
    const handleFileList = daemon_serve.handleFileList;
    const FsOpReq = daemon_serve.FsOpReq;
    const FsChange = daemon_serve.FsChange;
    const fsReplyErr = daemon_serve.fsReplyErr;
    const handleFsOp = daemon_serve.handleFsOp;
    const millisTimespec = daemon_serve.millisTimespec;
    const fsOpenView = daemon_serve.fsOpenView;
    const fsCloseView = daemon_serve.fsCloseView;
    const dropFsViewAt = daemon_serve.dropFsViewAt;
    const splitAttrs = daemon_serve.splitAttrs;
    const fsStartListing = daemon_serve.fsStartListing;
    const fsStat = daemon_serve.fsStat;
    const fsRead = daemon_serve.fsRead;
    const AppEntry = daemon_serve.AppEntry;
    const fsApps = daemon_serve.fsApps;
    const handleFsWrite = daemon_serve.handleFsWrite;
    const fsWatchReadable = daemon_serve.fsWatchReadable;

    // ── File jobs: split out to daemon_fsjobs.zig ──
    const daemon_fsjobs = @import("daemon_fsjobs.zig");
    pub const fsStartJob = daemon_fsjobs.fsStartJob;
    pub const fsJobOp = daemon_fsjobs.fsJobOp;
    const MAX_FINISHED_JOBS = daemon_fsjobs.MAX_FINISHED_JOBS;
    const MAX_MEDIA_BATCH_BYTES = daemon_fsjobs.MAX_MEDIA_BATCH_BYTES;
    const MAX_TOKEN_JOBS = daemon_fsjobs.MAX_TOKEN_JOBS;
    const ephemeralOp = daemon_fsjobs.ephemeralOp;
    const PermArgs = daemon_fsjobs.PermArgs;
    const CopyArgs = daemon_fsjobs.CopyArgs;
    const FsJobArgs = daemon_fsjobs.FsJobArgs;
    const spawnFsJob = daemon_fsjobs.spawnFsJob;
    const fsOpFromName = daemon_fsjobs.fsOpFromName;
    const journalFsJob = daemon_fsjobs.journalFsJob;
    const saveFsJob = daemon_fsjobs.saveFsJob;
    const deleteFsJobJournal = daemon_fsjobs.deleteFsJobJournal;
    const restoredFsJob = daemon_fsjobs.restoredFsJob;
    const restoreFsJobs = daemon_fsjobs.restoreFsJobs;
    const refreshDetachedFsJobs = daemon_fsjobs.refreshDetachedFsJobs;
    const restartCrashedFsJobs = daemon_fsjobs.restartCrashedFsJobs;
    const pumpFsJobCancelElections = daemon_fsjobs.pumpFsJobCancelElections;
    const fsJobEmit = daemon_fsjobs.fsJobEmit;
    const fsJobReadable = daemon_fsjobs.fsJobReadable;
    const MetaKV = daemon_fsjobs.MetaKV;
    const fsJobLine = daemon_fsjobs.fsJobLine;
    const fsJobExited = daemon_fsjobs.fsJobExited;

    // ── Debugger jobs: split out to daemon_debug.zig ──
    const daemon_debug = @import("daemon_debug.zig");
    pub const handleAppDebug = daemon_debug.handleAppDebug;
    const debugJobReadable = daemon_debug.debugJobReadable;
    const debugJobsTick = daemon_debug.debugJobsTick;

    /// Stream each active download toward its client, bounded by the
    /// client's write-buffer high-water mark (same backpressure rule as
    /// pumpWinstreams). Fills up to the mark each tick, then waits for
    /// the socket to drain (POLLOUT re-wakes the loop).
    fn pumpDownloads(self: *Daemon) void {
        const watermark = 8 << 20;
        const chunk = 256 * 1024;
        var buf: [4 + chunk]u8 = undefined; // reused across downloads/chunks
        var i: usize = 0;
        while (i < self.downloads.items.len) {
            const dl = self.downloads.items[i];
            if (dl.client.dead) {
                i += 1;
                continue;
            }
            var done_or_dropped = false;
            while (dl.client.queuedBytes() < watermark) {
                const n = c.read(dl.fd, buf[4..], chunk);
                if (n < 0) {
                    if (std.posix.errno(n) == .INTR) continue;
                    fileReply(dl.client, dl.xfer, "error", dl.sent, "", "read failed");
                    self.dropDownload(dl);
                    done_or_dropped = true;
                    break;
                }
                if (n == 0) {
                    fileReply(dl.client, dl.xfer, "done", dl.sent, "", "");
                    self.dropDownload(dl);
                    done_or_dropped = true;
                    break;
                }
                _ = wire.putChanHeader(buf[0..4], dl.xfer);
                const len: usize = @intCast(n);
                dl.client.queueFrame(.file_data, buf[0 .. 4 + len]);
                dl.sent += len;
            }
            // dropDownload swap-removed index i — re-check it; otherwise
            // advance past the still-streaming download.
            if (!done_or_dropped) i += 1;
        }
    }

    /// A Wayland app connected to the session's hub. The daemon IS
    /// the compositor (Native.brain) — the connection is accepted
    /// unconditionally, with or without clients to render it.
    fn acceptWaylandApp(self: *Daemon, s: *Session) void {
        const fd = c.accept(s.wl_hub_fd, null, null);
        if (fd < 0) return;
        const auxiliary = if (s.xwayland) |*xwl| xwl.ownsPeer(fd) else false;
        _ = c.fcntl(fd, c.F_SETFD, c.FD_CLOEXEC);
        const fl = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
        _ = c.fcntl(fd, c.F_SETFL, fl | c.O_NONBLOCK);
        self.openAppChannel(s, fd, auxiliary);
    }

    fn acceptAudioApp(self: *Daemon, s: *Session) void {
        const fd = c.accept(s.pa_hub_fd, null, null);
        if (fd < 0) return;
        _ = c.fcntl(fd, c.F_SETFD, c.FD_CLOEXEC);
        const fl = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
        _ = c.fcntl(fd, c.F_SETFL, fl | c.O_NONBLOCK);
        self.openAudioChannel(s, fd);
    }

    fn openAudioChannel(self: *Daemon, s: *Session, fd: c_int) void {
        const srv = self.allocator.create(pulse.Server) catch {
            _ = c.close(fd);
            return;
        };
        srv.* = pulse.Server.init(self.allocator);
        const ch = self.allocator.create(Channel) catch {
            srv.deinit();
            self.allocator.destroy(srv);
            _ = c.close(fd);
            return;
        };
        ch.* = .{
            .allocator = self.allocator,
            .id = self.next_chan_id,
            .fd = fd,
            .session = s,
            .client = null,
            .pa = srv,
        };
        self.next_chan_id += 1;
        self.channels.append(self.allocator, ch) catch {
            ch.deinit();
            return;
        };
        var hdr: [5]u8 = undefined;
        for (self.clients.items) |cl| {
            if (audioViewer(cl, s)) {
                if (cl.audio_ok)
                    cl.queueAudioFrame(.chan_open, wire.encodeChanOpen(&hdr, ch.id, .audio))
                else
                    cl.queueFrame(.chan_open, wire.encodeChanOpen(&hdr, ch.id, .audio));
                // Only a SUBSCRIBED viewer counts as the clock owner:
                // attached-but-deaf clients (MCP) must leave streams
                // on the daemon's real-time self-clock.
                if (cl.audio_ok) srv.has_viewer = true;
            }
        }
    }

    /// PA-app socket readable: feed the protocol server, replies go
    /// back to the app, PCM/stream units toward attached viewers.
    /// Any OTHER audio connection of this session with an uncorked
    /// stream — feeds the v15 sink STATE (a pactl connection has no
    /// streams of its own but must still see the sink RUNNING).
    pub fn sessionAudioRunning(self: *Daemon, s: *Session, except: ?*Channel) bool {
        for (self.channels.items) |ch| {
            if (ch == except or ch.dead or ch.session != s) continue;
            const srv = ch.pa orelse continue;
            var it = srv.streams.valueIterator();
            while (it.next()) |st| {
                if (!st.corked) return true;
            }
        }
        return false;
    }

    pub const MAX_AUDIO_STREAMS: usize = 16;

    /// Bounded snapshot of every Pulse playback stream in one session.
    pub fn sessionAudioInfos(self: *Daemon, s: *Session, allocator: std.mem.Allocator) []pulse.AudioInfo {
        var out: std.ArrayList(pulse.AudioInfo) = .empty;
        channels: for (self.channels.items) |ch| {
            if (ch.dead or ch.session != s) continue;
            const srv = ch.pa orelse continue;
            var it = srv.streams.valueIterator();
            while (it.next()) |stream| {
                out.append(allocator, srv.streamInfo(stream)) catch break :channels;
                if (out.items.len >= MAX_AUDIO_STREAMS) break :channels;
            }
        }
        return out.toOwnedSlice(allocator) catch {
            out.deinit(allocator);
            return &.{};
        };
    }

    /// An attached viewer that explicitly subscribed to playback. Its
    /// consumed reports already bound production to the local sink, so PCM
    /// remains bounded without tying liveness to the graphical backlog.
    pub fn subscribedAudioViewer(cl: *const Client, s: *const Session) bool {
        return audioViewer(cl, s) and cl.audio_ok;
    }

    fn sessionHasReadyAudioViewer(self: *Daemon, s: *Session) bool {
        for (self.clients.items) |cl| {
            if (subscribedAudioViewer(cl, s)) return true;
        }
        return false;
    }

    fn paReadable(self: *Daemon, ch: *Channel) void {
        const srv = ch.pa.?;
        srv.now_ms = nowMs(); // self-clock pace source
        srv.sink_running = self.sessionAudioRunning(ch.session.?, ch);
        srv.has_viewer = false;
        srv.opus_wanted = false;
        for (self.clients.items) |cl| {
            if (!subscribedAudioViewer(cl, ch.session.?)) continue;
            srv.has_viewer = true;
            // Opus units can't be captured (no decoder in the mux
            // graph) — capture forces raw pcm units for everyone.
            if (cl.audio_opus and ch.session.?.audio_capture_base == null)
                srv.opus_wanted = true;
        }
        var buf: [64 * 1024]u8 = undefined;
        var rounds: u32 = 0;
        while (rounds < 16) : (rounds += 1) {
            const n = c.read(ch.fd, &buf, buf.len);
            if (n == 0) {
                self.closeChannel(ch, true);
                return;
            }
            if (n < 0) break; // EAGAIN
            srv.feed(buf[0..@intCast(n)]) catch {
                self.closeChannel(ch, true);
                return;
            };
            if (srv.dead) {
                self.closeChannel(ch, true);
                return;
            }
        }
        const out = srv.takeOut();
        if (out.len > 0) {
            ch.pending.appendSlice(self.allocator, out) catch {
                self.closeChannel(ch, true);
                return;
            };
            srv.clearOut();
        }
        const units = srv.takeUnits();
        if (units.len > 0) {
            if (ch.session.?.audio_capture_base != null) self.captureUnits(ch, units);
            if (srv.has_viewer) self.queueUnits(ch, units);
            srv.clearUnits();
        }
        self.channelWritable(ch);
    }

    /// Tee this channel's audio units into per-stream WAV files
    /// (Session.audio_capture_base). Open/close follow the stream
    /// lifecycle; a stream that never closes is finalized by
    /// Channel.deinit. Failures log once and drop that stream.
    fn captureUnits(self: *Daemon, ch: *Channel, bytes: []const u8) void {
        const s = ch.session.?;
        const base = s.audio_capture_base orelse return;
        var pos: usize = 0;
        while (pulse.peelUnit(bytes[pos..]) catch |err| {
            log.warn("audio capture: malformed unit stream ({s}); rest of this payload dropped", .{@errorName(err)});
            return;
        }) |p| {
            pos += p.consumed;
            switch (p.tag) {
                .open => {
                    if (p.payload.len < 10) continue;
                    const stream = std.mem.readInt(u32, p.payload[0..4], .little);
                    if (ch.caps.contains(stream)) continue;
                    const fmt = p.payload[4];
                    const chans = p.payload[5];
                    const rate = std.mem.readInt(u32, p.payload[6..10], .little);
                    const stem = if (std.mem.endsWith(u8, base, ".wav")) base[0 .. base.len - 4] else base;
                    const id = s.next_capture_id;
                    var path_buf: [4096]u8 = undefined;
                    const path = (if (id <= 1)
                        std.fmt.bufPrintZ(&path_buf, "{s}.wav", .{stem})
                    else
                        std.fmt.bufPrintZ(&path_buf, "{s}-{d}.wav", .{ stem, id })) catch continue;
                    const w = wavcap.Writer.open(path.ptr, fmt, chans, rate) orelse {
                        log.warn("audio capture: cannot open '{s}' (or unmappable PA format {d}) — stream {d} not captured", .{ path, fmt, stream });
                        continue;
                    };
                    ch.caps.put(self.allocator, stream, w) catch {
                        var w2 = w;
                        w2.close();
                        continue;
                    };
                    s.next_capture_id = id + 1;
                    log.info("audio capture: stream {d} ({d} Hz) -> {s}", .{ stream, rate, path });
                },
                .pcm => {
                    if (p.payload.len <= 4) continue;
                    const stream = std.mem.readInt(u32, p.payload[0..4], .little);
                    if (ch.caps.getPtr(stream)) |w| w.write(p.payload[4..]);
                },
                .close => {
                    if (p.payload.len < 4) continue;
                    const stream = std.mem.readInt(u32, p.payload[0..4], .little);
                    if (ch.caps.fetchRemove(stream)) |kv| {
                        var w = kv.value;
                        w.close();
                    }
                },
                else => {},
            }
        }
    }

    /// Viewer → audio channel data (subscribe/consumed/latency).
    pub fn paClientData(self: *Daemon, cl: *Client, ch: *Channel, bytes: []const u8) void {
        const srv = ch.pa.?;
        srv.now_ms = nowMs();
        var pos: usize = 0;
        while (pulse.peelUnit(bytes[pos..]) catch |err| {
            // Viewer-supplied bytes: a corrupt length is that client's
            // bug, not a partial read. Stop, do not spin.
            log.warn("audio: viewer sent a malformed unit stream ({s})", .{@errorName(err)});
            return;
        }) |p| {
            if (p.tag == .subscribe) {
                cl.audio_ok = true;
                srv.has_viewer = true;
                // Flags byte (optional): bit0 = decodes Opus.
                if (p.payload.len >= 1 and p.payload[0] & 1 != 0) cl.audio_opus = true;
                if (ch.session.?.audio_capture_base == null)
                    srv.opus_wanted = srv.opus_wanted or cl.audio_opus;
                // The app may have created streams before this viewer's
                // subscribe reached the daemon. Those units were correctly
                // withheld from an unsubscribed client, so replay their
                // current descriptors now instead of leaving the GUI with
                // audible PCM but no voice/identity to route it into.
                var descriptors: std.ArrayList(u8) = .empty;
                defer descriptors.deinit(self.allocator);
                var it = srv.streams.iterator();
                while (it.next()) |entry| {
                    srv.appendStreamDescriptor(&descriptors, entry.key_ptr.*, entry.value_ptr) catch break;
                }
                if (descriptors.items.len > 0) self.queueAudioUnitsTo(cl, ch, descriptors.items);
            } else {
                srv.applyUnit(p.tag, p.payload) catch {};
            }
            pos += p.consumed;
        }
        const out = srv.takeOut();
        if (out.len > 0) {
            ch.pending.appendSlice(self.allocator, out) catch {
                self.closeChannel(ch, true);
                return;
            };
            srv.clearOut();
        }
        self.channelWritable(ch);
    }

    /// True when `cl` should receive this session's native app units.
    /// Brain saw the app announce its app_id: resolve the app's icon
    /// on THIS host (works for remote apps — the client can't) and
    /// ship the bytes to attached clients + stash for reattach.
    fn onBrainAppId(ctx: ?*anyopaque, sid: u32, app_id: []const u8) void {
        const nv: *Native = @ptrCast(@alignCast(ctx.?));
        const self = nv.daemon orelse return;
        const ch = nv.chan orelse return;
        if (app_id.len == 0) return;
        var icon = (icons.resolve(self.allocator, app_id) catch return) orelse return;
        defer icon.deinit(self.allocator);
        // Cap what we ship (a runaway icon file shouldn't flood the wire).
        if (icon.bytes.len > 2 * 1024 * 1024) return;
        nv.surface_icons.putCopy(self.allocator, sid, icon) catch return;
        var unit: std.ArrayList(u8) = .empty;
        defer unit.deinit(self.allocator);
        wlpipe.appendToplevelIcon(&unit, self.allocator, sid, @intFromEnum(icon.kind), icon.bytes) catch return;
        if (!ch.dead) self.queueUnits(ch, unit.items);
    }

    /// Drop a dead surface's SID-specific replay icon.
    fn onBrainGone(ctx: ?*anyopaque, sid: u32) void {
        const nv: *Native = @ptrCast(@alignCast(ctx.?));
        nv.surface_icons.remove(nv.allocator, sid);
        _ = nv.foreign_parents.remove(sid);
    }

    /// xdg_toplevel.set_parent, logged only. Window parenting is the
    /// one relation with no visible trace when it silently fails ("my
    /// dialog opened as its own taskbar window"), and this is where
    /// both halves of it are observable: an app's own set_parent here,
    /// and the GUI's resulting transient-for when the GUI is itself a
    /// client of a sketerm display session.
    fn onBrainParent(ctx: ?*anyopaque, sid: u32, parent: u32) void {
        const nv: *Native = @ptrCast(@alignCast(ctx.?));
        const ch = nv.chan orelse return;
        log.debug("set_parent: chan={d} surface={d} parent={d} (session '{s}')", .{
            ch.id, sid, parent, if (ch.session) |s| s.name else "?",
        });
    }

    /// xdg-dialog modality, logged only — the twin of onBrainParent
    /// and just as invisible when it silently does not happen.
    fn onBrainModal(ctx: ?*anyopaque, sid: u32, modal: bool) void {
        const nv: *Native = @ptrCast(@alignCast(ctx.?));
        const ch = nv.chan orelse return;
        log.debug("set_modal: chan={d} surface={d} modal={} (session '{s}')", .{
            ch.id, sid, modal, if (ch.session) |s| s.name else "?",
        });
    }

    /// The brain resolved (or dropped) an xdg-foreign parent for one of
    /// this connection's toplevels. Handles never leave the daemon:
    /// the viewer is told the session-wide identity of the parent
    /// window instead — the EXPORTING channel's id plus its surface id,
    /// which is exactly what the viewer knows that window by.
    ///
    /// This fires from inside another channel's feed whenever the
    /// exporting client is the one that moved (a revoked export clears
    /// every importer), so it must not assume `ch` is the channel
    /// currently being served. Queuing toward the mux client is safe
    /// there — unlike brain output, which needs `foreign_flush_pending`.
    fn onBrainForeignParent(ctx: ?*anyopaque, sid: u32, conn: u32, parent: u32) void {
        const nv: *Native = @ptrCast(@alignCast(ctx.?));
        const self = nv.daemon orelse return;
        const ch = nv.chan orelse return;
        if (conn == 0 or parent == 0) {
            if (nv.foreign_parents.fetchRemove(sid) == null) return;
        } else {
            nv.foreign_parents.put(self.allocator, sid, .{ .conn = conn, .surface = parent }) catch return;
        }
        log.debug("xdg-foreign parent: chan={d} surface={d} <- chan={d} surface={d} (session '{s}')", .{
            ch.id, sid, conn, parent, if (ch.session) |s| s.name else "?",
        });
        var unit: std.ArrayList(u8) = .empty;
        defer unit.deinit(self.allocator);
        wlpipe.appendForeignParent(&unit, self.allocator, sid, conn, parent) catch return;
        if (!ch.dead) self.queueUnits(ch, unit.items);
    }

    pub fn nativeViewer(cl: *const Client, s: *const Session) bool {
        return terminalViewer(cl, s) and
            cl.native_state_max >= wire.LEGACY_NATIVE_STATE_VERSION and
            cl.native_state_max >= s.native_state_min;
    }

    pub fn audioViewer(cl: *const Client, s: *const Session) bool {
        return terminalViewer(cl, s) and cl.audio_channels;
    }

    pub fn terminalViewer(cl: *const Client, s: *const Session) bool {
        return cl.attached == s and !cl.dead and !cl.panel_only;
    }

    fn attachmentStreamFrame(self: *const Daemon, s: *const Session, frame: wire.Frame) bool {
        return switch (frame.ftype) {
            .snapshot,
            .events,
            .exit,
            .gone,
            .peer_info,
            .app_a11y_tree,
            .search_hits,
            .log_data,
            .marker,
            .native_gap,
            .native_sync,
            .control_state,
            .session_meta,
            .app_debug_data,
            .play_state,
            .panel_request,
            .panel_reply,
            => true,
            .chan_open => if (wire.decodeChanOpen(frame.payload)) |opened|
                opened.kind == .wayland_native or opened.kind == .winstream or opened.kind == .audio
            else
                false,
            .chan_data, .chan_close => blk: {
                const id = wire.decodeChanId(frame.payload) orelse break :blk false;
                for (self.channels.items) |ch| {
                    if (ch.id == id) break :blk ch.session == s;
                }
                break :blk false;
            },
            else => false,
        };
    }

    fn discardQueuedAttachmentFrames(
        self: *Daemon,
        s: *Session,
        out: *std.ArrayList(u8),
        active_prefix: usize,
    ) void {
        var read_at = @min(active_prefix, out.items.len);
        var write_at = read_at;
        while (read_at < out.items.len) {
            const peeled = wire.peelFrame(out.items[read_at..]) catch {
                // Daemon-produced queues should always be valid. Preserve an
                // unexpected tail rather than corrupting unrelated traffic.
                const tail = out.items[read_at..];
                std.mem.copyForwards(u8, out.items[write_at..][0..tail.len], tail);
                write_at += tail.len;
                break;
            } orelse {
                const tail = out.items[read_at..];
                std.mem.copyForwards(u8, out.items[write_at..][0..tail.len], tail);
                write_at += tail.len;
                break;
            };
            if (!self.attachmentStreamFrame(s, peeled.frame)) {
                const bytes = out.items[read_at..][0..peeled.consumed];
                std.mem.copyForwards(u8, out.items[write_at..][0..bytes.len], bytes);
                write_at += bytes.len;
            }
            read_at += peeled.consumed;
        }
        out.shrinkRetainingCapacity(write_at);
    }

    /// Clear one client's attachment-scoped identity. Every teardown path
    /// (voluntary detach, session kill, session exit) ends here rather than
    /// hand-rolling the field list.
    fn clearClientAttachment(cl: *Client) void {
        cl.attached = null;
        cl.panel_only = false;
        cl.panel_rpc = 0;
        cl.resetAttachmentStreamState();
    }

    /// End one attachment without letting its queued replicas cross into the
    /// next role; unrelated connection-scoped replies remain in FIFO order.
    pub fn detachClientAttachment(self: *Daemon, cl: *Client, presenter_error: []const u8) void {
        const was = cl.attached;
        self.panelClientDetached(cl, presenter_error);
        if (was) |s| {
            if (cl.write_lane == .audio) {
                if (cl.write_frame_started) {
                    cl.audio_wbuf.shrinkRetainingCapacity(@min(cl.write_frame_left, cl.audio_wbuf.items.len));
                } else {
                    cl.write_lane = .none;
                    cl.write_frame_left = 0;
                    cl.write_frame_started = false;
                    cl.audio_wbuf.clearRetainingCapacity();
                }
            } else {
                cl.audio_wbuf.clearRetainingCapacity();
            }

            if (cl.write_lane == .normal and !cl.write_frame_started) {
                cl.write_lane = .none;
                cl.write_frame_left = 0;
            }
            const active_prefix = if (cl.write_lane == .normal and cl.write_frame_started)
                @min(cl.write_frame_left, cl.wbuf.items.len)
            else
                0;
            self.discardQueuedAttachmentFrames(s, &cl.wbuf, active_prefix);
        }
        clearClientAttachment(cl);
        if (was) |s| {
            // Clear attachment first so controller handover cannot select it.
            if (self.releaseControl(s, cl)) self.broadcastControlState(s);
            self.broadcastPeerInfo(s);
            self.refreshVideoGates();
        }
    }

    /// Per-viewer outbound backlog above which the native commit path
    /// stops producing new pixel frames for that viewer — the same
    /// backpressure the winstream path applies (:pumpWinstreams). A
    /// Wayland surface's state lives in the mirror, so a viewer that
    /// falls behind doesn't need every intermediate frame: it catches
    /// up on the NEXT commit it can receive (or via reattach replay).
    const NATIVE_BACKLOG: usize = 8 << 20;

    /// The gap threshold for "mcp"-kind clients is far LOWER: an MCP
    /// client consumes its queue at replica-compose speed (a full
    /// window memcpy per intermediate frame), so queued bytes map
    /// directly onto catch-up latency at the next tool call — 8MB of
    /// backlog is seconds of chewing before a capture is current.
    /// 1MB keeps that under the tool-entry catch-up budget; the
    /// post-drain live-mirror replay covers everything skipped.
    pub const MCP_NATIVE_BACKLOG: usize = 1 << 20;

    fn nativeBacklogCap(cl: *const Client) usize {
        return if (cl.kind == .mcp) MCP_NATIVE_BACKLOG else NATIVE_BACKLOG;
    }

    /// Should the commit path copy+encode this frame at all? True only
    /// when some attached proto>=6 viewer has room in its wbuf. With
    /// no viewer, OR every viewer already backed up, skip: the units
    /// would only pile into a wbuf (growing toward the reap cap) for
    /// frames the viewer can't keep up with. This is what stops a
    /// headless daemon running an animated app from ballooning —
    /// previously each commit encoded a frame nobody drained and a
    /// per-commit scratch leaked on top. Conservative: a channel with
    /// no session (shouldn't happen) reports ready so pixels flow.
    pub fn hasNativeViewer(self: *const Daemon, nv: *const Native) bool {
        const s = (nv.chan orelse return true).session orelse return true;
        for (self.clients.items) |cl| {
            if (nativeViewer(cl, s) and !cl.needs_native_resync and cl.wbuf.items.len < nativeBacklogCap(cl)) return true;
        }
        return false;
    }

    /// Re-evaluate the per-channel video consensus after client churn.
    pub fn refreshVideoGates(self: *Daemon) void {
        for (self.channels.items) |ch| {
            if (ch.dead) continue;
            if (ch.native) |nv| nv.wants_video = self.videoOk(ch.session.?);
        }
    }

    /// Video tiles may only flow when every viewer can decode them
    /// (a tile one client can't decode is a black window there).
    fn videoOk(self: *Daemon, s: *Session) bool {
        var any = false;
        for (self.clients.items) |cl| {
            if (!nativeViewer(cl, s)) continue;
            if (!cl.video) return false;
            any = true;
        }
        return any;
    }

    /// Initializes the process-wide importer once and always preserves the
    /// direct-mmap LINEAR tuples alongside driver-reported modifiers.
    fn dmabufCapabilities(self: *Daemon) []const dmabuf.Capability {
        if (self.dmabuf_initialized)
            return if (self.dmabuf_capabilities.items.len > 0)
                self.dmabuf_capabilities.items
            else
                &dmabuf.linear_capabilities;
        self.dmabuf_capabilities.ensureTotalCapacity(
            self.allocator,
            dmabuf.linear_capabilities.len,
        ) catch return &dmabuf.linear_capabilities;
        dmabuf.appendUnique(
            self.allocator,
            &self.dmabuf_capabilities,
            &dmabuf.linear_capabilities,
        ) catch return &dmabuf.linear_capabilities;
        self.dmabuf_initialized = true;

        // EGL vendors may own background threads and internal locks. A
        // monolith can fork another PTY after this app connects, which makes
        // child-side pre-exec work unsafe; workers never fork another session.
        if (!self.isWorker()) {
            log.info("dmabuf import: modifier path disabled outside an isolated worker", .{});
            return self.dmabuf_capabilities.items;
        }

        if (dmabuf_egl.Importer.init(self.allocator)) |importer_value| {
            var importer = importer_value;
            self.dmabuf_capabilities.ensureTotalCapacity(
                self.allocator,
                self.dmabuf_capabilities.items.len + importer.capabilities().len,
            ) catch {
                importer.deinit();
                return self.dmabuf_capabilities.items;
            };
            dmabuf.appendUnique(
                self.allocator,
                &self.dmabuf_capabilities,
                importer.capabilities(),
            ) catch unreachable;
            self.dmabuf_importer = importer;
        }
        return self.dmabuf_capabilities.items;
    }

    /// dev_t clients should allocate dmabufs on, resolved once per
    /// daemon (0 = none, which keeps linux-dmabuf at v3).
    fn dmabufMainDevice(self: *Daemon) u64 {
        if (!self.drm_device_probed) {
            self.drm_device_probed = true;
            self.drm_device = @import("drmdev.zig").mainDevice() orelse 0;
            if (self.drm_device == 0)
                log.info("dmabuf feedback: no usable DRM render node, announcing linux-dmabuf v3", .{});
        }
        return self.drm_device;
    }

    /// An xdg-foreign event landed in a brain other than the one being
    /// fed. Only latch it: this can fire from inside another channel's
    /// feed, or from a Compositor.deinit during dropDeadChannels.
    fn foreignWake(ctx: ?*anyopaque, comp: *wlcomp.Compositor) void {
        _ = comp;
        const self: *Daemon = @ptrCast(@alignCast(ctx.?));
        self.foreign_flush_pending = true;
    }

    /// Bridge one accepted app connection as a session-owned channel.
    fn openAppChannel(self: *Daemon, s: *Session, fd: c_int, auxiliary: bool) void {
        const native = self.allocator.create(Native) catch {
            _ = c.close(fd);
            return;
        };
        const tracker = wltrack.Tracker.init(self.allocator) catch {
            self.allocator.destroy(native);
            _ = c.close(fd);
            return;
        };
        const brain = self.allocator.create(wlcomp.Compositor) catch {
            var tr = tracker;
            tr.deinit();
            self.allocator.destroy(native);
            _ = c.close(fd);
            return;
        };
        brain.* = wlcomp.Compositor.init(self.allocator, .{}) catch {
            self.allocator.destroy(brain);
            var tr = tracker;
            tr.deinit();
            self.allocator.destroy(native);
            _ = c.close(fd);
            return;
        };
        brain.output_width = s.output_width;
        brain.output_height = s.output_height;
        // xdg-foreign resolves across the session's connections, and a
        // revoked handle queues `destroyed` on a brain nobody is about
        // to feed — flag the sweep instead of flushing re-entrantly.
        s.foreign.wake = foreignWake;
        s.foreign.wake_ctx = self;
        brain.foreign_shared = &s.foreign;
        brain.keymap = s.kb_keymap;
        brain.materialize_dmabuf_pools = false;
        // Opt-in (see get_registry); the softgl force in pty.zig is
        // dropped by the same switches. Per-session via SpawnReq.gpu
        // (`sketerm app --gpu`), daemon-wide via env.
        brain.advertise_dmabuf = s.gpu or c.getenv("SKETERM_MUX_DMABUF") != null;
        native.* = .{ .allocator = self.allocator, .tracker = tracker, .brain = brain };
        if (brain.advertise_dmabuf) {
            brain.dmabuf_capabilities = self.dmabufCapabilities();
            // linux-dmabuf v4 needs a main device to point clients at;
            // without one the brain announces v3 (mpv and other
            // feedback-only clients then fail to bind a video output).
            brain.dmabuf_main_device = self.dmabufMainDevice();
            for (brain.dmabuf_capabilities) |capability| {
                if (capability.modifier != dmabuf.DRM_FORMAT_MOD_LINEAR) {
                    s.native_state_min = @max(s.native_state_min, wire.DMABUF_MODIFIER_STATE_VERSION);
                    break;
                }
            }
            if (self.dmabuf_importer) |*importer| {
                native.dmabuf_importer = importer;
                log.info("dmabuf import: EGL modifier path active ({d} capabilities including LINEAR)", .{brain.dmabuf_capabilities.len});
            } else log.info("dmabuf import: LINEAR mmap path active", .{});
        }

        const ch = self.allocator.create(Channel) catch {
            native.deinit();
            _ = c.close(fd);
            return;
        };
        ch.* = .{
            .allocator = self.allocator,
            .id = self.next_chan_id,
            .fd = fd,
            .session = s,
            .client = null,
            .auxiliary = auxiliary,
            .native = native,
        };
        native.wants_video = self.videoOk(s);
        // Wire the brain to resolve + inject the app's icon when it
        // announces its app_id. Stable pointers (native/ch are heap).
        native.daemon = self;
        native.chan = ch;
        brain.conn_id = ch.id;
        brain.view = .{
            .ctx = native,
            .toplevel_app_id = onBrainAppId,
            .toplevel_gone = onBrainGone,
            .toplevel_parent = onBrainParent,
            .toplevel_foreign_parent = onBrainForeignParent,
            .toplevel_modal = onBrainModal,
        };
        self.next_chan_id += 1;
        self.channels.append(self.allocator, ch) catch {
            ch.deinit();
            return;
        };
        var viewers: usize = 0;
        var hdr: [5]u8 = undefined;
        for (self.clients.items) |cl| {
            if (nativeViewer(cl, s)) {
                cl.queueFrame(.chan_open, wire.encodeChanOpen(&hdr, ch.id, .wayland_native));
                viewers += 1;
            }
        }
        log.info("wayland app connected: session='{s}' chan={d} viewers={d}", .{ s.name, ch.id, viewers });
    }

    /// App-socket bytes toward the client (the parsed sketerm-native
    /// pipe). Winstream channels carry fd = -1 and never land here.
    fn channelReadable(self: *Daemon, ch: *Channel) void {
        if (ch.native != null) self.nativeReadable(ch);
        if (ch.pa != null) self.paReadable(ch);
        if (ch.tcp) {
            var buf: [64 << 10]u8 = undefined;
            const n = c.read(ch.fd, &buf, buf.len);
            if (n <= 0) {
                if (n == 0 or std.posix.errno(n) != .AGAIN) self.closeChannel(ch, true);
                return;
            }
            self.queueUnits(ch, buf[0..@intCast(n)]);
        }
    }

    pub fn channelWritable(self: *Daemon, ch: *Channel) void {
        if (ch.pending.items.len == 0) {
            if (ch.close_after_flush) self.closeChannel(ch, true);
            return;
        }
        const n_raw = if (ch.native != null and ch.native.?.out_fds.items.len > 0)
            self.writeWithFds(ch)
        else
            c.write(ch.fd, ch.pending.items.ptr, ch.pending.items.len);
        if (n_raw < 0) {
            if (std.posix.errno(n_raw) != .AGAIN) self.closeChannel(ch, true);
            return;
        }
        const n: usize = @intCast(n_raw);
        const remaining = ch.pending.items.len - n;
        std.mem.copyForwards(u8, ch.pending.items[0..remaining], ch.pending.items[n..]);
        ch.pending.shrinkRetainingCapacity(remaining);
        if (remaining == 0 and ch.close_after_flush) self.closeChannel(ch, true);
    }

    /// sendmsg with the queued SCM_RIGHTS fds attached. Attaching
    /// to the first available write keeps fds AT OR BEFORE their
    /// message bytes, which is the order Wayland clients require.
    fn writeWithFds(self: *Daemon, ch: *Channel) isize {
        _ = self;
        const nv = ch.native.?;
        const n_fds = @min(nv.out_fds.items.len, 8);
        var iov = c.struct_iovec{
            .iov_base = ch.pending.items.ptr,
            .iov_len = ch.pending.items.len,
        };
        const hdr_size: usize = @sizeOf(c.struct_cmsghdr);
        var cbuf: [128]u8 align(@alignOf(c.struct_cmsghdr)) = std.mem.zeroes([128]u8);
        const cmsg: *c.struct_cmsghdr = @ptrCast(&cbuf);
        cmsg.cmsg_len = @intCast(hdr_size + n_fds * @sizeOf(c_int));
        cmsg.cmsg_level = c.SOL_SOCKET;
        cmsg.cmsg_type = c.SCM_RIGHTS;
        for (nv.out_fds.items[0..n_fds], 0..) |fd, i| {
            @memcpy(cbuf[hdr_size + i * @sizeOf(c_int) ..][0..@sizeOf(c_int)], std.mem.asBytes(&fd));
        }
        var mh = std.mem.zeroes(c.struct_msghdr);
        mh.msg_iov = @ptrCast(&iov);
        mh.msg_iovlen = 1;
        mh.msg_control = &cbuf;
        const space = (cmsg.cmsg_len + @sizeOf(usize) - 1) & ~@as(usize, @sizeOf(usize) - 1);
        mh.msg_controllen = @intCast(space);
        const r = c.sendmsg(ch.fd, &mh, 0);
        if (r > 0) {
            // Kernel duplicated them into the receiver's queue.
            for (nv.out_fds.items[0..n_fds]) |fd| _ = c.close(fd);
            for (0..n_fds) |_| _ = nv.out_fds.orderedRemove(0);
        }
        return r;
    }

    // ── Native app pipe: split out to daemon_native.zig ──
    const daemon_native = @import("daemon_native.zig");
    pub const nativeClientData = daemon_native.nativeClientData;
    const nativeReadable = daemon_native.nativeReadable;
    const collectFds = daemon_native.collectFds;
    const nativeProcess = daemon_native.nativeProcess;
    const flushBrain = daemon_native.flushBrain;
    const flushPendingBrains = daemon_native.flushPendingBrains;
    const POOL_CHUNK = daemon_native.POOL_CHUNK;
    const nativeAction = daemon_native.nativeAction;
    const queueUnits = daemon_native.queueUnits;
    const queueUnitsTo = daemon_native.queueUnitsTo;
    const queueAudioUnitsTo = daemon_native.queueAudioUnitsTo;
    const queueUnitsToLane = daemon_native.queueUnitsToLane;
    const clipReadable = daemon_native.clipReadable;
    const isSeatIntent = daemon_native.isSeatIntent;
    const takePasteFd = daemon_native.takePasteFd;
    const applyAppUnit = daemon_native.applyAppUnit;

    pub fn closeChannel(self: *Daemon, ch: *Channel, notify: bool) void {
        if (ch.dead) return;
        ch.dead = true;
        if (ch.native != null)
            log.info("wayland app channel {d} closed (session '{s}')", .{ ch.id, if (ch.session) |s| s.name else "?" });
        if (!notify) return;
        var hdr: [4]u8 = undefined;
        const frame = wire.putChanHeader(&hdr, ch.id);
        if (ch.native != null or ch.pa != null) {
            for (self.clients.items) |cl| {
                const viewer = if (ch.pa != null) audioViewer(cl, ch.session.?) else nativeViewer(cl, ch.session.?);
                if (viewer) cl.queueFrame(.chan_close, frame);
            }
        } else if (ch.client) |cl| {
            if (!cl.dead) cl.queueFrame(.chan_close, frame);
        }
    }

    // ── Session lifecycle + broker forwarding: split out to daemon_sessions.zig ──
    const daemon_sessions = @import("daemon_sessions.zig");
    // ── Cast playback sessions: split out to daemon_cast.zig ──
    pub const castTick = daemon_cast.castTick;
    pub const castOnAttach = daemon_cast.castOnAttach;
    pub const handlePlayControl = daemon_cast.handlePlayControl;
    pub const spawnCastSessionWithOrigin = daemon_cast.spawnCastSessionWithOrigin;

    pub const isWorker = daemon_sessions.isWorker;
    pub const handleSpawn = daemon_sessions.handleSpawn;
    pub const spawnSession = daemon_sessions.spawnSession;
    pub const spawnSessionWithOrigin = daemon_sessions.spawnSessionWithOrigin;
    pub const handleAttach = daemon_sessions.handleAttach;
    const findSession = daemon_sessions.findSession;
    const brokerFindWorker = daemon_sessions.brokerFindWorker;
    const applyWorkerLimits = daemon_sessions.applyWorkerLimits;
    const brokerSpawn = daemon_sessions.brokerSpawn;
    const brokerAttach = daemon_sessions.brokerAttach;
    const brokerList = daemon_sessions.brokerList;
    const brokerKill = daemon_sessions.brokerKill;
    const brokerRename = daemon_sessions.brokerRename;
    pub const brokerWorkerRename = daemon_sessions.brokerWorkerRename;
    const WaylandHub = daemon_sessions.WaylandHub;
    const runtimeBaseDir = daemon_sessions.runtimeBaseDir;
    const setupWaylandHub = daemon_sessions.setupWaylandHub;
    const setupAudioHub = daemon_sessions.setupAudioHub;
    const setupHubSocket = daemon_sessions.setupHubSocket;
    const winstreamGate = daemon_sessions.winstreamGate;

    // ── controller lease ────────────────────────────────────────────
    //
    // A session's Wayland seat has exactly one driver. Every attached
    // viewer still SEES the app (frames broadcast to all), but only the
    // controller's input-shaped pipe units reach the brain. The first
    // viewer that did not ask read-only takes a free lease; later ones
    // are read-only until they ask for a takeover. The lease is not
    // security — it is arbitration between an automation client and a
    // human operator sharing one app.

    /// Label for the current controller ("<kind>#<id>"), written into
    /// `buf`. Empty when nobody holds the lease. Same shape in monolith
    /// and worker so the broker can pass it through verbatim.
    pub fn controllerLabel(self: *const Daemon, s: *const Session, buf: []u8) []const u8 {
        _ = self;
        const cl = s.controller orelse return "";
        return std.fmt.bufPrint(buf, "{s}#{d}", .{ @tagName(cl.kind), cl.id }) catch "?";
    }

    pub fn viewerCount(self: *const Daemon, s: *const Session) u32 {
        var n: u32 = 0;
        for (self.clients.items) |cl| {
            if (terminalViewer(cl, s)) n += 1;
        }
        return n;
    }

    /// Push the lease state to every attached client. Each recipient's
    /// `controller` field is ITS OWN answer ("do I hold it"), so a
    /// viewer that wanted control and lost the race learns it here
    /// rather than by noticing its input does nothing.
    pub fn broadcastControlState(self: *Daemon, s: *Session) void {
        var buf: [32]u8 = undefined;
        const label = self.controllerLabel(s, &buf);
        const viewers = self.viewerCount(s);
        for (self.clients.items) |cl| {
            if (!terminalViewer(cl, s)) continue;
            cl.queueJson(.control_state, .{
                .controller = s.controller == cl,
                .read_only = cl.read_only,
                .controller_label = label,
                .viewers = viewers,
            });
        }
    }

    /// True when `cl` may drive `s`'s seat.
    pub fn isController(cl: *const Client, s: *const Session) bool {
        return s.controller == cl;
    }

    /// Give `cl` the lease unless it asked read-only. `force` evicts the
    /// current holder; without it a held lease is left alone. Returns
    /// true when the lease CHANGED hands (caller broadcasts).
    pub fn acquireControl(self: *Daemon, s: *Session, cl: *Client, force: bool) bool {
        _ = self;
        if (cl.read_only or cl.panel_only) return false;
        if (s.controller == cl) return false;
        if (s.controller != null and !force) return false;
        s.controller = cl;
        log.info("session '{s}': control -> {s}#{d}{s}", .{
            s.name, @tagName(cl.kind), cl.id, if (force) " (takeover)" else "",
        });
        return true;
    }

    /// Drop `cl`'s lease (if it holds one) and hand it to the OLDEST
    /// remaining eligible viewer — a controller vanishing must not leave
    /// a dead session nobody can drive. Returns true when anything
    /// changed. `cl == null` releases unconditionally.
    pub fn releaseControl(self: *Daemon, s: *Session, cl: ?*Client) bool {
        const holder = s.controller orelse return false;
        if (cl) |c2| {
            if (holder != c2) return false;
        }
        s.controller = null;
        // Oldest = lowest connection id; the clients list is
        // swapRemove'd, so its ORDER says nothing about age.
        var next: ?*Client = null;
        for (self.clients.items) |other| {
            if (other == holder or !terminalViewer(other, s) or other.read_only) continue;
            if (next == null or other.id < next.?.id) next = other;
        }
        if (next) |n| {
            s.controller = n;
            log.info("session '{s}': control -> {s}#{d} (handover)", .{ s.name, @tagName(n.kind), n.id });
        } else {
            log.info("session '{s}': control released (no eligible viewer)", .{s.name});
        }
        return true;
    }

    pub fn handleControlReq(self: *Daemon, cl: *Client, payload: []const u8) void {
        if (cl.panel_only) {
            cl.queueErr("panel-only attachments cannot control a session");
            return;
        }
        const s = cl.attached orelse {
            cl.queueErr("not attached");
            return;
        };
        var parsed = std.json.parseFromSlice(ControlReq, self.allocator, payload, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch {
            cl.queueErr("bad control request");
            return;
        };
        defer parsed.deinit();
        const op = parsed.value.op;
        if (std.mem.eql(u8, op, "acquire") or std.mem.eql(u8, op, "takeover")) {
            // A read-only viewer asking for control is opting back in.
            cl.read_only = false;
            _ = self.acquireControl(s, cl, std.mem.eql(u8, op, "takeover"));
        } else if (std.mem.eql(u8, op, "release")) {
            _ = self.releaseControl(s, cl);
        } else {
            cl.queueErr("unknown control op (want acquire|release|takeover)");
            return;
        }
        // Broadcast even when nothing changed: the requester must learn
        // the outcome, and repeating state to the others is harmless.
        self.broadcastControlState(s);
    }

    /// Push the session's attach roster to every attached client.
    /// Fired on attach, detach and client death so viewers can show
    /// (or drop) the "assistant is driving" indicator promptly.
    pub fn broadcastPeerInfo(self: *Daemon, s: *Session) void {
        var total: u32 = 0;
        var guis: u32 = 0;
        var drivers: u32 = 0;
        for (self.clients.items) |cl| {
            if (cl.dead or cl.attached != s) continue;
            total += 1;
            switch (cl.kind) {
                .gui => guis += 1,
                .mcp => drivers += 1,
                else => {},
            }
        }
        for (self.clients.items) |cl| {
            if (!terminalViewer(cl, s)) continue;
            cl.queueJson(.peer_info, .{ .total = total, .guis = guis, .drivers = drivers });
        }
    }

    // ── correlated panel relay ─────────────────────────────────────

    pub const PANEL_MAX_PENDING_PER_REQUESTER: usize = 8;
    pub const PANEL_MAX_PENDING: usize = 128;
    pub const PANEL_ROUTE_TIMEOUT_MS: i64 = 125_000;
    /// A presenter/requester that already has this much unsent data is not
    /// allowed to accumulate another multi-megabyte panel call.
    pub const PANEL_RELAY_BACKLOG: usize = 64 << 20;

    /// Select THE panel-capable attachment of `s`: the earliest still-attached
    /// one by client id. There is no requester-to-presenter binding — when a
    /// presenter detaches or dies, the next request simply selects whichever
    /// panel-capable attachment is present then.
    fn panelPresenter(self: *Daemon, s: *Session, required_panel_rpc: u8) ?*Client {
        var selected: ?*Client = null;
        for (self.clients.items) |candidate| {
            if (!terminalViewer(candidate, s) or candidate.kind != .gui or
                candidate.panel_rpc < required_panel_rpc)
                continue;
            if (selected == null or candidate.id < selected.?.id) selected = candidate;
        }
        return selected;
    }

    fn panelRouteIdInUse(self: *const Daemon, id: u64) bool {
        for (self.panel_routes.items) |route| if (route.route_id == id) return true;
        return false;
    }

    fn allocPanelRouteId(self: *Daemon) u64 {
        while (true) {
            const id = self.next_panel_route_id;
            self.next_panel_route_id +%= 1;
            if (self.next_panel_route_id == 0) self.next_panel_route_id = 1;
            if (id != 0 and !self.panelRouteIdInUse(id)) return id;
        }
    }

    fn queuePanelEnvelope(self: *Daemon, cl: *Client, ftype: wire.FrameType, id: u64, json: []const u8) !u64 {
        if (cl.dead) return error.ClientGone;
        if (json.len == 0) return error.EmptyJson;
        if (json.len > wire.PANEL_JSON_MAX) return error.TooLong;
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.allocator);
        try wire.appendPanelEnvelope(&payload, self.allocator, id, json);
        var frame: std.ArrayList(u8) = .empty;
        defer frame.deinit(self.allocator);
        try wire.appendFrame(&frame, self.allocator, ftype, payload.items);
        if (cl.queuedBytes() +| frame.items.len > PANEL_RELAY_BACKLOG)
            return error.Backpressure;
        const stream_start = cl.normal_bytes_written +| cl.wbuf.items.len;
        try cl.wbuf.appendSlice(self.allocator, frame.items);
        return stream_start;
    }

    /// How much a failed panel route tells the caller about delivery.
    const PanelFailure = enum {
        /// Nothing reached the presenter: retrying cannot double-apply.
        pre_delivery,
        /// The request was on the wire when it failed. A resend could apply
        /// a mutation twice, so the caller is told never to do it blindly.
        uncertain,
    };

    fn queuePanelFailure(
        self: *Daemon,
        cl: *Client,
        caller_id: u64,
        class: PanelFailure,
        message: []const u8,
        error_code: []const u8,
    ) void {
        if (cl.dead) return;
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        const w = &aw.writer;
        blk: {
            w.writeAll("{\"ok\":false,\"error\":") catch break :blk;
            std.json.Stringify.value(message, .{}, w) catch break :blk;
            if (error_code.len > 0) {
                w.writeAll(",\"error_code\":") catch break :blk;
                std.json.Stringify.value(error_code, .{}, w) catch break :blk;
            }
            switch (class) {
                .pre_delivery => w.writeAll(
                    ",\"failure_class\":\"pre_delivery\",\"mutation_may_have_applied\":false,\"resend_safe\":true",
                ) catch break :blk,
                .uncertain => w.writeAll(
                    ",\"failure_class\":\"uncertain_delivery\",\"mutation_may_have_applied\":true,\"resend_safe\":false",
                ) catch break :blk,
            }
            w.writeAll("}") catch break :blk;
            _ = self.queuePanelEnvelope(cl, .panel_reply, caller_id, aw.written()) catch {};
        }
    }

    fn queuePanelPreDelivery(self: *Daemon, cl: *Client, caller_id: u64, message: []const u8) void {
        self.queuePanelFailure(cl, caller_id, .pre_delivery, message, "");
    }

    fn queuePanelPreDeliveryCode(self: *Daemon, cl: *Client, caller_id: u64, message: []const u8, error_code: []const u8) void {
        self.queuePanelFailure(cl, caller_id, .pre_delivery, message, error_code);
    }

    fn queuePanelUncertain(self: *Daemon, cl: *Client, caller_id: u64, message: []const u8) void {
        self.queuePanelFailure(cl, caller_id, .uncertain, message, "");
    }

    /// Remove a route whose complete frame is still provably unsent.
    fn cancelQueuedPanelRoute(self: *Daemon, route: PanelRoute) bool {
        const presenter = route.presenter;
        if (presenter.normal_bytes_written > route.presenter_stream_start) return false;
        const relative_u64 = route.presenter_stream_start - presenter.normal_bytes_written;
        const relative = std.math.cast(usize, relative_u64) orelse return false;
        const end = std.math.add(usize, relative, route.presenter_stream_len) catch return false;
        if (end > presenter.wbuf.items.len) return false;
        const peeled = (wire.peelFrame(presenter.wbuf.items[relative..end]) catch return false) orelse return false;
        if (peeled.consumed != route.presenter_stream_len or peeled.frame.ftype != .panel_request) return false;
        const envelope = wire.decodePanelEnvelope(peeled.frame.payload) catch return false;
        if (envelope.id != route.route_id) return false;

        if (relative == 0 and presenter.write_lane == .normal) {
            if (presenter.write_frame_started) return false;
            presenter.write_lane = .none;
            presenter.write_frame_left = 0;
            presenter.write_frame_started = false;
        }
        const tail = presenter.wbuf.items[end..];
        std.mem.copyForwards(u8, presenter.wbuf.items[relative..][0..tail.len], tail);
        presenter.wbuf.shrinkRetainingCapacity(presenter.wbuf.items.len - route.presenter_stream_len);

        // Absolute starts are coordinates in the shrinking normal stream.
        for (self.panel_routes.items) |*other| {
            if (other.presenter == presenter and other.presenter_stream_start > route.presenter_stream_start)
                other.presenter_stream_start -= route.presenter_stream_len;
        }
        return true;
    }

    /// Fail every route belonging to a presenter that answered badly,
    /// classified from each route's own stream offset. A reply ID proves that
    /// one route was delivered even if a synthetic/test transport did not
    /// advance counters.
    ///
    /// The presenter KEEPS its panel capability: one malformed reply is a bug
    /// in one handler, and silently demoting the user's GUI to "panels no
    /// longer work here" until they reattach hides it instead of surfacing it.
    /// Each subsequent call fails on its own with its own message.
    fn failPanelPresenterRoutes(
        self: *Daemon,
        presenter: *Client,
        proven_route_id: ?u64,
        message: []const u8,
    ) void {
        var i: usize = 0;
        while (i < self.panel_routes.items.len) {
            const route = self.panel_routes.items[i];
            if (route.presenter != presenter) {
                i += 1;
                continue;
            }
            const proven = proven_route_id != null and proven_route_id.? == route.route_id;
            const canceled = !proven and self.cancelQueuedPanelRoute(route);
            _ = self.panel_routes.swapRemove(i);
            if (!canceled)
                self.queuePanelUncertain(route.requester, route.caller_id, message)
            else
                self.queuePanelPreDelivery(
                    route.requester,
                    route.caller_id,
                    "the panel presenter failed before this route's first request byte; safe to resend",
                );
        }
    }

    pub fn handlePanelRequest(self: *Daemon, requester: *Client, payload: []const u8) void {
        if (!requester.panel_only or requester.panel_rpc == 0) {
            requester.queueErr("panel_request requires a panel-only attachment");
            return;
        }
        const s = requester.attached orelse {
            requester.queueErr("not attached");
            return;
        };
        const envelope = wire.decodePanelEnvelope(payload) catch |err| {
            if (wire.decodePanelEnvelopeId(payload)) |caller_id| {
                self.queuePanelPreDelivery(requester, caller_id, if (err == error.TooLong)
                    "panel request is too large before delivery"
                else
                    "bad panel request envelope before delivery");
            } else requester.queueErr(if (err == error.TooLong)
                "panel request is too large"
            else
                "bad panel request envelope");
            return;
        };
        if (self.panel_routes.items.len >= PANEL_MAX_PENDING) {
            self.queuePanelPreDelivery(requester, envelope.id, "daemon panel route limit reached before request delivery");
            return;
        }
        var requester_pending: usize = 0;
        for (self.panel_routes.items) |route| {
            if (route.requester == requester) requester_pending += 1;
        }
        if (requester_pending >= PANEL_MAX_PENDING_PER_REQUESTER) {
            self.queuePanelPreDelivery(requester, envelope.id, "requester panel route limit reached before request delivery");
            return;
        }
        const presenter = self.panelPresenter(s, requester.panel_rpc) orelse {
            self.queuePanelPreDeliveryCode(
                requester,
                envelope.id,
                "no compatible GUI is attached to this session",
                "no_compatible_gui",
            );
            return;
        };
        if (presenter.queuedBytes() +| payload.len +| 5 > PANEL_RELAY_BACKLOG) {
            self.queuePanelPreDelivery(requester, envelope.id, "panel presenter is backpressured before request delivery");
            return;
        }
        self.panel_routes.ensureUnusedCapacity(self.allocator, 1) catch {
            self.queuePanelPreDelivery(requester, envelope.id, "daemon could not allocate a panel route before delivery");
            return;
        };
        const route_id = self.allocPanelRouteId();
        const stream_start = self.queuePanelEnvelope(presenter, .panel_request, route_id, envelope.json) catch |err| {
            self.queuePanelPreDelivery(requester, envelope.id, switch (err) {
                error.TooLong => "panel request is too large before presenter delivery",
                error.OutOfMemory => "daemon could not allocate panel delivery before any bytes were sent",
                error.Backpressure => "panel presenter is backpressured before request delivery",
                else => "panel presenter disconnected before request delivery",
            });
            return;
        };
        self.panel_routes.appendAssumeCapacity(.{
            .route_id = route_id,
            .caller_id = envelope.id,
            .requester = requester,
            .presenter = presenter,
            .session = s,
            .panel_rpc = requester.panel_rpc,
            .deadline_ms = nowMs() + PANEL_ROUTE_TIMEOUT_MS,
            .presenter_stream_start = stream_start,
            .presenter_stream_len = payload.len + 5,
        });
    }

    pub fn handlePanelReply(self: *Daemon, presenter: *Client, payload: []const u8) void {
        if (presenter.panel_only or presenter.kind != .gui or presenter.panel_rpc == 0) {
            presenter.queueErr("panel_reply requires a presenter attachment");
            return;
        }
        const envelope = wire.decodePanelEnvelope(payload) catch |err| {
            const message = if (err == error.TooLong)
                "panel presenter returned an oversized reply after request delivery; delivery is uncertain, the mutation may have applied, and the request was NOT resent"
            else
                "panel presenter returned a malformed reply after request delivery; delivery is uncertain, the mutation may have applied, and the request was NOT resent";
            const route_id = wire.decodePanelEnvelopeId(payload) orelse {
                presenter.queueErr("bad panel reply envelope");
                self.failPanelPresenterRoutes(presenter, null, message);
                return;
            };
            for (self.panel_routes.items) |route| {
                if (route.route_id != route_id) continue;
                if (route.presenter != presenter or presenter.attached != route.session) {
                    presenter.queueErr("malformed panel reply came from the wrong presenter");
                    self.failPanelPresenterRoutes(presenter, route_id, message);
                    return;
                }
                presenter.queueErr(if (err == error.TooLong)
                    "oversized panel reply rejected"
                else
                    "malformed panel reply rejected");
                self.failPanelPresenterRoutes(presenter, route_id, message);
                return;
            }
            presenter.queueErr("unknown or expired panel route");
            self.failPanelPresenterRoutes(presenter, route_id, message);
            return;
        };
        var i: usize = 0;
        while (i < self.panel_routes.items.len) : (i += 1) {
            const route = self.panel_routes.items[i];
            if (route.route_id != envelope.id) continue;
            if (route.presenter != presenter or presenter.attached != route.session) {
                presenter.queueErr("panel reply came from the wrong presenter");
                return;
            }
            _ = self.panel_routes.swapRemove(i);
            if (!route.requester.dead and route.requester.attached == route.session)
                _ = self.queuePanelEnvelope(route.requester, .panel_reply, route.caller_id, envelope.json) catch {};
            return;
        }
        presenter.queueErr("unknown or expired panel route");
    }

    /// Remove requester routes and fail routes whose selected presenter left.
    pub fn panelClientDetached(self: *Daemon, cl: *Client, presenter_error: []const u8) void {
        var i: usize = 0;
        while (i < self.panel_routes.items.len) {
            const route = self.panel_routes.items[i];
            if (route.requester == cl) {
                _ = self.cancelQueuedPanelRoute(route);
                _ = self.panel_routes.swapRemove(i);
                continue;
            }
            if (route.presenter == cl) {
                const canceled = self.cancelQueuedPanelRoute(route);
                _ = self.panel_routes.swapRemove(i);
                if (!canceled)
                    self.queuePanelUncertain(route.requester, route.caller_id, presenter_error)
                else
                    self.queuePanelPreDelivery(route.requester, route.caller_id, "panel presenter disconnected before request delivery; safe to resend");
                continue;
            }
            i += 1;
        }
    }

    pub fn panelSessionClosed(self: *Daemon, s: *Session) void {
        var i: usize = 0;
        while (i < self.panel_routes.items.len) {
            const route = self.panel_routes.items[i];
            if (route.session != s) {
                i += 1;
                continue;
            }
            const canceled = self.cancelQueuedPanelRoute(route);
            _ = self.panel_routes.swapRemove(i);
            if (!canceled)
                self.queuePanelUncertain(route.requester, route.caller_id, "session closed after panel request delivery; delivery is uncertain, the mutation may have applied, and the request was NOT resent")
            else
                self.queuePanelPreDelivery(route.requester, route.caller_id, "session closed before panel request delivery; safe to resend");
        }
    }

    pub fn panelRoutesTick(self: *Daemon, now: i64) void {
        var i: usize = 0;
        while (i < self.panel_routes.items.len) {
            const route = self.panel_routes.items[i];
            if (route.requester.dead or route.requester.attached != route.session or
                !route.requester.panel_only or route.requester.panel_rpc < route.panel_rpc)
            {
                _ = self.cancelQueuedPanelRoute(route);
                _ = self.panel_routes.swapRemove(i);
                continue;
            }
            const message: ?[]const u8 = if (route.session.exited)
                "session closed"
            else if (route.presenter.dead or route.presenter.attached != route.session or
                route.presenter.panel_only or route.presenter.kind != .gui or
                route.presenter.panel_rpc < route.panel_rpc)
                "panel presenter disconnected"
            else if (now >= route.deadline_ms)
                "panel request timed out"
            else
                null;
            if (message) |msg| {
                const canceled = self.cancelQueuedPanelRoute(route);
                _ = self.panel_routes.swapRemove(i);
                if (!canceled) {
                    var buf: [256]u8 = undefined;
                    const uncertain = std.fmt.bufPrint(&buf, "{s} after request delivery; delivery is uncertain, the mutation may have applied, and the request was NOT resent", .{msg}) catch msg;
                    self.queuePanelUncertain(route.requester, route.caller_id, uncertain);
                } else {
                    var buf: [160]u8 = undefined;
                    const safe = std.fmt.bufPrint(&buf, "{s} before request delivery; safe to resend", .{msg}) catch msg;
                    self.queuePanelPreDelivery(route.requester, route.caller_id, safe);
                }
                continue;
            }
            i += 1;
        }
    }

    /// A proto>=6 client just attached: for every live native app
    /// channel on `s`, announce the channel and rebuild its replica —
    /// current pool bytes from the mirrors, then the brain's
    /// serialized protocol state. Windows reappear with current
    /// pixels (durable GUI apps, multi-viewer).
    pub fn replayNativeChannels(self: *Daemon, cl: *Client, s: *Session) void {
        if (!terminalViewer(cl, s)) return;
        // A full replay makes the client current — any pending
        // withheld-frames state is superseded by it.
        cl.needs_native_resync = false;
        if (cl.audio_channels) {
            // Audio channels are independent of graphical state support.
            for (self.channels.items) |ch| {
                if (ch.session != s or ch.dead) continue;
                const srv = ch.pa orelse continue;
                var hdr: [5]u8 = undefined;
                if (cl.audio_ok)
                    cl.queueAudioFrame(.chan_open, wire.encodeChanOpen(&hdr, ch.id, .audio))
                else
                    cl.queueFrame(.chan_open, wire.encodeChanOpen(&hdr, ch.id, .audio));
                if (cl.audio_ok) srv.has_viewer = true;
                var units: std.ArrayList(u8) = .empty;
                defer units.deinit(self.allocator);
                var it = srv.streams.iterator();
                while (it.next()) |e| {
                    srv.appendStreamDescriptor(&units, e.key_ptr.*, e.value_ptr) catch break;
                }
                if (units.items.len > 0) {
                    if (cl.audio_ok)
                        self.queueAudioUnitsTo(cl, ch, units.items)
                    else
                        self.queueUnitsTo(cl, ch, units.items);
                }
            }
        }
        if (cl.native_state_max < wire.LEGACY_NATIVE_STATE_VERSION or
            cl.native_state_max < s.native_state_min) return;
        for (self.channels.items) |ch| {
            if (ch.session != s or ch.dead) continue;
            const nv = ch.native orelse continue;
            var hdr: [5]u8 = undefined;
            cl.queueFrame(.chan_open, wire.encodeChanOpen(&hdr, ch.id, .wayland_native));
            var units: std.ArrayList(u8) = .empty;
            defer units.deinit(self.allocator);
            var ok = true;
            var it = nv.pools.iterator();
            while (it.next()) |e| {
                const pool_id = e.key_ptr.*;
                const mirror = e.value_ptr.*;
                wlpipe.appendPoolMeta(&units, self.allocator, .pool_create, pool_id, @intCast(mirror.size)) catch {
                    ok = false;
                    break;
                };
                // The replica must adopt this incarnation's serial
                // BEFORE state_sync binds buffers to it.
                wlpipe.appendPoolSerial(&units, self.allocator, pool_id, mirror.serial) catch {
                    ok = false;
                    break;
                };
                var off: usize = 0;
                while (off < mirror.size) {
                    const len = @min(POOL_CHUNK, mirror.size - off);
                    const raw = mirror.ptr[off..][0..len];
                    var sc: wlpixcodec.Scratch = .{};
                    defer sc.deinit(self.allocator);
                    const enc = wlpixcodec.encodeRegion(&sc, self.allocator, raw, len) catch
                        wlpixcodec.Encoded{ .coder = .raw, .filter = .none, .bytes = raw };
                    wlpipe.appendPoolUpdateC(&units, self.allocator, pool_id, @intCast(off), enc, @intCast(len), @intCast(len)) catch {
                        ok = false;
                        break;
                    };
                    off += len;
                }
                if (!ok) break;
            }
            // Orphaned incarnations still referenced by live buffers:
            // without them a reattached replica freezes (or blacks)
            // every window whose client commits displaced storage.
            if (ok) {
                var oit = nv.orphan_pools.iterator();
                while (oit.next()) |e| {
                    const serial = e.key_ptr.*;
                    const mirror = e.value_ptr.*;
                    wlpipe.appendPoolOrphan(&units, self.allocator, serial, @intCast(mirror.size)) catch {
                        ok = false;
                        break;
                    };
                    var off: usize = 0;
                    while (off < mirror.size) {
                        const len = @min(POOL_CHUNK, mirror.size - off);
                        const raw = mirror.ptr[off..][0..len];
                        var sc: wlpixcodec.Scratch = .{};
                        defer sc.deinit(self.allocator);
                        const enc = wlpixcodec.encodeRegion(&sc, self.allocator, raw, len) catch
                            wlpixcodec.Encoded{ .coder = .raw, .filter = .none, .bytes = raw };
                        wlpipe.appendPoolUpdateS(&units, self.allocator, serial, @intCast(off), enc, @intCast(len), @intCast(len)) catch {
                            ok = false;
                            break;
                        };
                        off += len;
                    }
                    if (!ok) break;
                }
            }
            // Dmabuf mirrors replay as their synthetic pools (pool id
            // == buffer id) so a reattaching replica has pixels for
            // the restored buffers. Staging is the last pre-release
            // capture; replay must never touch the producer's source.
            if (ok) {
                var dit = nv.dmabufs.iterator();
                while (dit.next()) |e| {
                    const pool_id = e.key_ptr.*;
                    const mirror = e.value_ptr.*;
                    if (nv.pools.contains(pool_id)) {
                        log.warn("dmabuf synthetic pool {d} collides with a live shm pool", .{pool_id});
                        ok = false;
                        break;
                    }
                    wlpipe.appendPoolMeta(&units, self.allocator, .pool_create, pool_id, @intCast(mirror.staging.len)) catch {
                        ok = false;
                        break;
                    };
                    var off: usize = 0;
                    while (off < mirror.staging.len) {
                        const len = @min(POOL_CHUNK, mirror.staging.len - off);
                        const raw = mirror.staging[off..][0..len];
                        var sc: wlpixcodec.Scratch = .{};
                        defer sc.deinit(self.allocator);
                        const enc = wlpixcodec.encodeRegion(&sc, self.allocator, raw, len) catch
                            wlpixcodec.Encoded{ .coder = .raw, .filter = .none, .bytes = raw };
                        wlpipe.appendPoolUpdateC(&units, self.allocator, pool_id, @intCast(off), enc, @intCast(len), @intCast(len)) catch {
                            ok = false;
                            break;
                        };
                        off += len;
                    }
                    if (!ok) break;
                }
            }
            if (ok) {
                if (nv.brain.serializeStateVersion(self.allocator, cl.native_state_max)) |blob| {
                    defer self.allocator.free(blob);
                    wlpipe.appendUnit(&units, self.allocator, .state_sync, blob) catch {
                        ok = false;
                    };
                } else |_| ok = false;
            }
            // Icons are daemon-injected, not part of brain state.
            if (ok) nv.surface_icons.appendReplay(&units, self.allocator) catch {
                ok = false;
            };
            // Neither are foreign parents: they resolve against the
            // brain's handle namespace, which never crosses the wire.
            // The parent may live on a channel this client has not been
            // told about yet — the viewer latches unresolved relations
            // and applies them when that window appears.
            if (ok) {
                var fit = nv.foreign_parents.iterator();
                while (fit.next()) |e| {
                    wlpipe.appendForeignParent(
                        &units,
                        self.allocator,
                        e.key_ptr.*,
                        e.value_ptr.conn,
                        e.value_ptr.surface,
                    ) catch {
                        ok = false;
                        break;
                    };
                }
            }
            if (!ok) {
                cl.dead = true;
                return;
            }
            self.queueUnitsTo(cl, ch, units.items);
        }
    }

    /// Window-stream channels have no fd (frames originate in the
    /// daemon) — fd = -1 is ignored by poll; the channel exists for
    /// id allocation and client routing.
    pub fn openWinstreamChan(self: *Daemon, s: *Session, cl: *Client) void {
        for (self.channels.items) |ch| {
            if (ch.session == s and !ch.dead and ch.native == null and s.winstream != null) return; // one per session
        }
        const ch = self.allocator.create(Channel) catch return;
        ch.* = .{
            .allocator = self.allocator,
            .id = self.next_chan_id,
            .fd = -1,
            .session = s,
            .client = cl,
        };
        self.next_chan_id += 1;
        self.channels.append(self.allocator, ch) catch {
            ch.deinit();
            return;
        };
        var hdr: [5]u8 = undefined;
        cl.queueFrame(.chan_open, wire.encodeChanOpen(&hdr, ch.id, .winstream));
        // Windows opened while nobody was attached (or for a prior
        // client) must be replayed for this one. Route windows through the
        // lossy video coder only if THIS client can decode it (mirrors the
        // Wayland `native.wants_video = cl.video`).
        if (s.winstream) |ws| {
            ws.setWantsVideo(cl.video);
            ws.reannounce();
        }
    }

    /// Pump every live window-stream session: frames toward the
    /// attached client, bounded by the poll cadence.
    fn pumpWinstreams(self: *Daemon) void {
        const now_ms: u64 = @intCast(nowMs());
        for (self.channels.items) |ch| {
            if (ch.dead or ch.native != null) continue;
            const chs = ch.session orelse continue;
            const ws = chs.winstream orelse continue;
            const cl = ch.client orelse continue;
            if (!terminalViewer(cl, chs)) continue;
            // Backpressure: a slow link must not balloon the client
            // write buffer — skip frame production until it drains
            // (the source keeps streaming; only emission pauses).
            if (cl.queuedBytes() > 8 << 20) continue;
            var units: std.ArrayList(u8) = .empty;
            defer units.deinit(self.allocator);
            ws.poll(&units, self.allocator, now_ms) catch continue;
            if (units.items.len > 0) self.queueUnits(ch, units.items);
        }
    }

    /// Serve `log_get`: a slice of the attached session's log ring as
    /// a `log_data` JSON frame. Also used at session exit to push the
    /// final log toward clients before the `.exit` frame (post-mortem
    /// without a round trip — the exit force-detaches them).
    fn queueLogData(self: *Daemon, cl: *Client, s: *Session, req: LogGetReq) void {
        const ring = &s.log;
        const items = ring.lines.items;
        var start: usize = 0;
        var end: usize = items.len;
        if (req.id != 0) {
            if (ring.indexOfId(req.id)) |i| {
                if (items[i].id == req.id) {
                    start = i;
                    end = i + 1;
                } else {
                    start = end; // dropped / never emitted
                }
            } else start = end;
        } else if (req.from_id != 0) {
            start = ring.indexOfId(req.from_id) orelse end;
            end = @min(end, start + 500);
        } else {
            const tail: usize = @min(@max(req.tail, 1), 500);
            if (end > tail) start = end - tail;
        }
        // Single-line fetches return the FULL stored line.
        const max_chars: usize = if (req.id != 0) 0 else req.max_chars;

        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        const w = &aw.writer;
        // nonce stays BEFORE "lines": clients scan only the header for
        // it (line text is arbitrary app output and could contain it).
        w.print("{{\"next_id\":{d},\"dropped\":{d},\"markers_dropped\":{d},\"nonce\":{d},\"lines\":[", .{
            ring.next_id, ring.dropped, ring.markers_dropped, req.nonce,
        }) catch return;
        var first = true;
        for (items[start..end]) |l| {
            if (!first) w.writeAll(",") catch return;
            first = false;
            var text = l.bytes;
            var cut = false;
            if (max_chars != 0 and text.len > max_chars) {
                // Cut on a UTF-8 boundary (bytes are scrubbed-valid).
                var n = max_chars;
                while (n > 0 and (text[n] & 0xC0) == 0x80) n -= 1;
                text = text[0..n];
                cut = true;
            }
            w.print("{{\"id\":{d},\"t\":{d},\"text\":", .{ l.id, l.t_ms }) catch return;
            std.json.Stringify.value(text, .{}, w) catch return;
            if (l.truncated) w.writeAll(",\"truncated\":true") catch return;
            if (cut) w.writeAll(",\"cut\":true") catch return;
            if (l.marker) w.writeAll(",\"marker\":true") catch return;
            w.writeAll("}") catch return;
        }
        w.writeAll("]}") catch return;
        cl.queueFrame(.log_data, aw.written());
    }

    pub fn handleLogGet(self: *Daemon, cl: *Client, payload: []const u8) void {
        const s = cl.attached orelse {
            cl.queueErr("not attached");
            return;
        };
        var req = LogGetReq{};
        if (payload.len > 0) {
            if (std.json.parseFromSlice(LogGetReq, self.allocator, payload, .{
                .ignore_unknown_fields = true,
            })) |p| {
                req = p.value;
                p.deinit();
            } else |_| {}
        }
        self.queueLogData(cl, s, req);
    }

    pub fn queueAttachIdentity(_: *Daemon, cl: *Client, s: *Session) void {
        cl.queueJson(.session_meta, .{
            .name = s.name,
            .origin_name = s.origin_name,
            .origin_id = &s.origin_id,
        });
    }

    /// Account one failed snapshot attempt against the client's resync
    /// budget, scheduling a backed-off retry or giving up loudly.
    ///
    /// Giving up is what keeps a permanently unserializable screen from
    /// freezing a viewer: `ingestFinish` withholds `.events` for as long
    /// as `needs_resync` is set, so without a terminal state the client
    /// would receive nothing at all and never be told why.
    fn noteResyncFailure(_: *Daemon, cl: *Client, s: *Session, what: []const u8) void {
        if (cl.dead or cl.resync_gave_up) return;
        cl.resync_attempts +|= 1;
        if (cl.resync_attempts >= Client.MAX_RESYNC_ATTEMPTS) {
            cl.resync_gave_up = true;
            log.warn("{s}; giving up after {d} attempts, dropping client (session '{s}')", .{ what, cl.resync_attempts, s.name });
            cl.queueErr("snapshot resync failed repeatedly; reconnect for a fresh screen");
            return;
        }
        const delay = Client.resyncBackoffMs(cl.resync_attempts);
        cl.resync_retry_at_ms = nowMs() + delay;
        // Only the first failure is a warning: warnings also hit stderr,
        // and a per-tick warn on a shared log is how this used to become
        // a second failure mode on top of the frozen session.
        if (cl.resync_attempts == 1)
            log.warn("{s}; retrying (session '{s}')", .{ what, s.name })
        else
            log.debug("{s}; retry #{d} in {d}ms (session '{s}')", .{ what, cl.resync_attempts, delay, s.name });
    }

    pub fn queueSnapshot(self: *Daemon, cl: *Client, s: *Session) void {
        if (!terminalViewer(cl, s)) return;
        if (cl.resync_gave_up) return;
        cl.needs_resync = true;
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        // Protocol 1-3 used [seq:u64]; protocol 4 added the app byte.
        var seq_hdr: [9]u8 = undefined;
        std.mem.writeInt(u64, seq_hdr[0..8], s.seq, .little);
        seq_hdr[8] = if (s.app) 1 else 0;
        const header = if (cl.proto >= 4) seq_hdr[0..9] else seq_hdr[0..8];
        buf.appendSlice(self.allocator, header) catch {
            self.noteResyncFailure(cl, s, "snapshot header allocation failed");
            return;
        };
        snapshot.serializeVersion(s.screen, &buf, self.allocator, cl.snapshot_version) catch {
            self.noteResyncFailure(cl, s, "snapshot serialization failed");
            return;
        };
        // A body past MAX_FRAME is not a big snapshot: it is a frame no
        // peer can peel, so queueing it would hand the client a fatal
        // protocol error instead of a screen. snapshot.zig budgets the
        // unbounded sections; this is the backstop for a grid whose
        // MANDATORY part alone cannot fit.
        if (buf.items.len + wire.header_size > wire.MAX_FRAME) {
            self.noteResyncFailure(cl, s, "snapshot exceeds the wire frame limit");
            return;
        }
        if (!cl.tryQueueFrameIn(&cl.wbuf, .snapshot, buf.items)) {
            self.noteResyncFailure(cl, s, "snapshot frame allocation failed");
            return;
        }
        // A full snapshot supersedes any withheld events once the complete
        // frame is in FIFO order ahead of every event accepted from now on.
        cl.needs_resync = false;
        cl.resync_attempts = 0;
        cl.resync_retry_at_ms = 0;
        var cwd_buf: [4096]u8 = undefined;
        // A newly attached client has no facts yet, so sample the
        // foreground program now rather than making it wait for the
        // session's next output.
        var fg_buf: [32]u8 = undefined;
        const fg = if (s.ptyPtr()) |p|
            platform.foregroundProgram(p.master_fd, &fg_buf) orelse ""
        else
            "";
        cl.queueJson(.session_meta, .{
            .cwd = cwdOfPid(s.childPid(), &cwd_buf) orelse "",
            .program = fg,
            .name = s.name,
            .origin_name = s.origin_name,
            .origin_id = &s.origin_id,
        });
        // A cast viewer needs the playback state to render controls.
        if (s.castPtr()) |cp| daemon_cast.queuePlayState(cl, cp);
    }

    fn retryPendingSnapshots(self: *Daemon) void {
        const now = nowMs();
        for (self.clients.items) |cl| {
            if (cl.dead or !cl.needs_resync) continue;
            if (cl.resync_gave_up) {
                // The give-up notice is the last frame this client gets;
                // drop the connection once it has drained so the client's
                // own reconnect starts from a fresh snapshot.
                if (cl.queuedBytes() == 0 and cl.write_lane == .none) cl.dead = true;
                continue;
            }
            if (cl.queuedBytes() != 0 or cl.write_lane != .none) continue;
            if (now < cl.resync_retry_at_ms) continue;
            if (cl.attached) |s| self.queueSnapshot(cl, s);
        }
    }

    fn requireSnapshot(self: *Daemon, cl: *Client, s: *Session) void {
        if (cl.dead or cl.resync_gave_up or !terminalViewer(cl, s)) return;
        cl.needs_resync = true;
        if (cl.queuedBytes() == 0 and cl.write_lane == .none and nowMs() >= cl.resync_retry_at_ms)
            self.queueSnapshot(cl, s);
    }

    /// Minimum gap between two foreground-program samples for one
    /// session. A busy session produces output continuously, and the
    /// title only needs to keep up with a human's reading speed.
    const FG_SAMPLE_INTERVAL_MS: i64 = 500;

    /// Re-read the pty's foreground process name and, if it moved,
    /// push it to attached clients.
    ///
    /// Called ONLY from the PTY drain, so this costs nothing on an
    /// idle daemon: no timer, no extra poll wakeup. The rate limit
    /// keeps a flooding session to two `tcgetpgrp` + `/proc` reads a
    /// second, and the change check keeps the wire quiet — running
    /// `ls` in a loop re-reports `bash` once, not once per command.
    pub fn sampleForeground(self: *Daemon, s: *Session) void {
        const pty = s.ptyPtr() orelse return;
        const now = nowMs();
        if (now - s.fg_sampled_ms < FG_SAMPLE_INTERVAL_MS) return;
        s.fg_sampled_ms = now;

        var buf: [32]u8 = undefined;
        const name = platform.foregroundProgram(pty.master_fd, &buf) orelse "";
        const len: u8 = @intCast(@min(name.len, s.fg_program.len));
        if (len == s.fg_program_len and std.mem.eql(u8, s.fg_program[0..len], name[0..len])) return;
        @memcpy(s.fg_program[0..len], name[0..len]);
        s.fg_program_len = len;

        for (self.clients.items) |cl| {
            if (!terminalViewer(cl, s)) continue;
            cl.queueJson(.session_meta, .{ .program = s.fg_program[0..len] });
        }
    }

    pub fn broadcastSnapshot(self: *Daemon, s: *Session) void {
        for (self.clients.items) |cl| {
            if (terminalViewer(cl, s)) self.queueSnapshot(cl, s);
        }
    }

    /// Publish mutable display identity without changing the snapshot format.
    pub fn broadcastSessionIdentity(self: *Daemon, s: *Session) void {
        for (self.clients.items) |cl| {
            if (!terminalViewer(cl, s)) continue;
            cl.queueJson(.session_meta, .{
                .name = s.name,
                .origin_name = s.origin_name,
                .origin_id = &s.origin_id,
            });
        }
    }

    pub fn handleList(self: *Daemon, cl: *Client) void {
        if (self.is_broker) return self.brokerList(cl);
        var infos: std.ArrayList(SessionInfo) = .empty;
        defer infos.deinit(self.allocator);
        // Per-session cwd strings, owned for the life of this call (the
        // SessionInfo slices must stay valid through queueJson). One scratch
        // buffer per session, kept alive in `cwd_bufs`.
        var cwd_bufs: std.ArrayList([]u8) = .empty;
        defer {
            for (cwd_bufs.items) |b| self.allocator.free(b);
            cwd_bufs.deinit(self.allocator);
        }
        // Controller labels, one small buffer per session, alive for the
        // whole call (SessionInfo holds slices into them).
        var ctrl_bufs: std.ArrayList([]u8) = .empty;
        defer {
            for (ctrl_bufs.items) |b| self.allocator.free(b);
            ctrl_bufs.deinit(self.allocator);
        }
        var audio_sets: std.ArrayList([]pulse.AudioInfo) = .empty;
        defer {
            for (audio_sets.items) |set| self.allocator.free(set);
            audio_sets.deinit(self.allocator);
        }
        const now = nowMs();
        for (self.sessions.items) |s| {
            var n_clients: u32 = 0;
            for (self.clients.items) |c2| {
                if (!c2.dead and c2.attached == s) n_clients += 1;
            }
            var controller: []const u8 = "";
            {
                var lbuf: [32]u8 = undefined;
                const label = self.controllerLabel(s, &lbuf);
                if (label.len > 0) {
                    if (self.allocator.dupe(u8, label)) |owned| {
                        ctrl_bufs.append(self.allocator, owned) catch {};
                        controller = owned;
                    } else |_| {}
                }
            }
            var cwd: []const u8 = "";
            var scratch: [4096]u8 = undefined;
            if (cwdOfPid(s.childPid(), &scratch)) |cw| {
                if (self.allocator.dupe(u8, cw)) |owned| {
                    cwd_bufs.append(self.allocator, owned) catch {};
                    cwd = owned;
                } else |_| {}
            }
            const audio_streams = self.sessionAudioInfos(s, self.allocator);
            // Both appends answer instead of returning: the client is
            // blocked in recvExpect(.welcome), so a dropped reply is a
            // hang on its side. `.err` resolves that wait.
            audio_sets.append(self.allocator, audio_streams) catch {
                self.allocator.free(audio_streams);
                cl.queueErr("list failed: out of memory");
                return;
            };
            infos.append(self.allocator, .{
                .name = s.name,
                .origin_name = s.origin_name,
                .origin_id = &s.origin_id,
                .rows = s.screen.rows,
                .cols = s.screen.cols,
                .clients = n_clients,
                .exited = s.exited,
                .title = if (s.screen.last_title) |t| t else "",
                .app = s.app,
                .idle_ms = now - s.last_activity_ms,
                .cwd = cwd,
                .pid = s.childPid(),
                .audio = self.sessionAudioRunning(s, null),
                .audio_streams = audio_streams,
                .display = s.display,
                .xwayland = s.xwayland != null,
                .x_display = if (s.xwayland) |*xwl| xwl.display_name else "",
                .xauthority = if (s.xwayland) |*xwl| xwl.auth_path else "",
                .gpu = s.gpu,
                .output_width = s.output_width,
                .output_height = s.output_height,
                .wl_display = if (s.wl_display_path) |p| p else "",
                .pulse_server = if (s.pa_socket_path) |p| p else "",
                .runtime_dir = if (s.runtime_dir_path) |p| p else "",
                .ttl_secs = @intCast(@divTrunc(s.ttl_ms, 1000)),
                .viewers = self.viewerCount(s),
                .controller = controller,
            }) catch {
                cl.queueErr("list failed: out of memory");
                return;
            };
        }
        cl.queueJson(.welcome, .{ .proto = cl.proto, .daemon_pid = c.getpid(), .server_proto = wire.PROTO_VERSION, .min_proto = wire.MIN_SERVER_PROTO, .negotiation = @as(u8, 1), .version = version.string, .audio_opus = opuscodec.available(), .video = build_options.video, .sessions = infos.items });
    }

    const ForwardReq = struct { port: u16 };

    /// TCP forward toward 127.0.0.1:<port> on THIS host. Loopback
    /// only (same trust boundary as the shell the socket already
    /// grants); nonblocking connect — a refused port surfaces as
    /// POLLERR → chan_close, exactly like a mid-stream drop.
    pub fn handleForward(self: *Daemon, cl: *Client, payload: []const u8) void {
        var parsed = std.json.parseFromSlice(ForwardReq, self.allocator, payload, .{
            .ignore_unknown_fields = true,
        }) catch {
            cl.queueErr("bad forward request");
            return;
        };
        defer parsed.deinit();
        const port = parsed.value.port;
        if (port == 0) {
            cl.queueErr("bad forward port");
            return;
        }

        const fd = @import("../util/platform.zig").socketCloexec(c.AF_INET, c.SOCK_STREAM, 0);
        if (fd < 0) {
            cl.queueErr("forward: socket failed");
            return;
        }
        const fl = c.fcntl(fd, c.F_GETFL);
        _ = c.fcntl(fd, c.F_SETFL, fl | c.O_NONBLOCK);
        var sa = std.mem.zeroes(c.struct_sockaddr_in);
        sa.sin_family = c.AF_INET;
        sa.sin_port = std.mem.nativeToBig(u16, port);
        sa.sin_addr.s_addr = std.mem.nativeToBig(u32, c.INADDR_LOOPBACK);
        const r = c.connect(fd, @ptrCast(&sa), @sizeOf(c.struct_sockaddr_in));
        if (r != 0 and std.posix.errno(r) != .INPROGRESS) {
            _ = c.close(fd);
            cl.queueErr("forward: connect failed");
            return;
        }

        const ch = self.allocator.create(Channel) catch {
            _ = c.close(fd);
            cl.queueErr("forward: out of memory");
            return;
        };
        ch.* = .{
            .allocator = self.allocator,
            .id = self.next_chan_id,
            .fd = fd,
            .session = null,
            .client = cl,
            .tcp = true,
        };
        self.next_chan_id += 1;
        self.channels.append(self.allocator, ch) catch {
            ch.deinit();
            cl.queueErr("forward: out of memory");
            return;
        };
        var ob: [5]u8 = undefined;
        cl.queueFrame(.chan_open, wire.encodeChanOpen(&ob, ch.id, .tcp_forward));
    }

    const StreamReq = struct { req: u32 = 0, host: []const u8 = "", port: u16 = 0 };

    /// Open a TCP stream to an ARBITRARY host:port FROM this daemon's
    /// host, resolving the hostname HERE (remote DNS). This is the
    /// egress primitive behind per-container "browse via server X": a
    /// local SOCKS5 bridge relays each connection through here, so the
    /// browser's traffic leaves from — and its names resolve at — the
    /// remote host the user picked.
    ///
    /// getaddrinfo is BLOCKING and runs on the poll loop, so a slow DNS
    /// server briefly stalls this daemon's other sessions; acceptable
    /// for a v1 egress path (the alternative is an async resolver, a far
    /// larger lift). The connect itself is nonblocking — a refused peer
    /// surfaces as POLLERR -> chan_close, exactly like `forward_open`.
    pub fn handleStream(self: *Daemon, cl: *Client, payload: []const u8) void {
        var parsed = std.json.parseFromSlice(StreamReq, self.allocator, payload, .{
            .ignore_unknown_fields = true,
        }) catch {
            cl.queueJson(.stream_reply, .{ .req = @as(u32, 0), .ok = false, .@"error" = "bad stream request" });
            return;
        };
        defer parsed.deinit();
        const req = parsed.value;
        if (req.host.len == 0 or req.host.len > 255 or req.port == 0) {
            cl.queueJson(.stream_reply, .{ .req = req.req, .ok = false, .@"error" = "bad host/port" });
            return;
        }

        // Resolve on THIS host (remote DNS). NUL-terminate the borrowed
        // host slice for getaddrinfo.
        var hostz: [256]u8 = undefined;
        @memcpy(hostz[0..req.host.len], req.host);
        hostz[req.host.len] = 0;
        var portz: [8]u8 = undefined;
        const ports = std.fmt.bufPrintZ(&portz, "{d}", .{req.port}) catch {
            cl.queueJson(.stream_reply, .{ .req = req.req, .ok = false, .@"error" = "bad port" });
            return;
        };
        var hints = std.mem.zeroes(c.struct_addrinfo);
        hints.ai_family = c.AF_UNSPEC;
        hints.ai_socktype = c.SOCK_STREAM;
        var res: ?*c.struct_addrinfo = null;
        if (c.getaddrinfo(&hostz, ports.ptr, &hints, &res) != 0 or res == null) {
            cl.queueJson(.stream_reply, .{ .req = req.req, .ok = false, .@"error" = "name resolution failed" });
            return;
        }
        defer c.freeaddrinfo(res);

        // Try each resolved address until a nonblocking connect starts.
        var fd: c_int = -1;
        var ai: ?*c.struct_addrinfo = res;
        while (ai) |a| : (ai = a.ai_next) {
            const s = @import("../util/platform.zig").socketCloexec(a.ai_family, a.ai_socktype, a.ai_protocol);
            if (s < 0) continue;
            const fl = c.fcntl(s, c.F_GETFL);
            _ = c.fcntl(s, c.F_SETFL, fl | c.O_NONBLOCK);
            const r = c.connect(s, a.ai_addr, a.ai_addrlen);
            if (r == 0 or std.posix.errno(r) == .INPROGRESS) {
                fd = s;
                break;
            }
            _ = c.close(s);
        }
        if (fd < 0) {
            cl.queueJson(.stream_reply, .{ .req = req.req, .ok = false, .@"error" = "connect failed" });
            return;
        }

        const ch = self.allocator.create(Channel) catch {
            _ = c.close(fd);
            cl.queueJson(.stream_reply, .{ .req = req.req, .ok = false, .@"error" = "out of memory" });
            return;
        };
        ch.* = .{
            .allocator = self.allocator,
            .id = self.next_chan_id,
            .fd = fd,
            .session = null,
            .client = cl,
            .tcp = true,
        };
        self.next_chan_id += 1;
        self.channels.append(self.allocator, ch) catch {
            ch.deinit();
            cl.queueJson(.stream_reply, .{ .req = req.req, .ok = false, .@"error" = "out of memory" });
            return;
        };
        var ob: [5]u8 = undefined;
        cl.queueFrame(.chan_open, wire.encodeChanOpen(&ob, ch.id, .tcp_forward));
        cl.queueJson(.stream_reply, .{ .req = req.req, .ok = true, .chan = ch.id });
    }

    pub const LspOpenSrv = struct {
        name: []const u8 = "",
        command: []const u8 = "",
        args: []const u8 = "",
        root_files: []const u8 = "",
    };
    const LspOpenReq = struct {
        req: u32 = 0,
        /// Directory of the document (on THIS host's filesystem).
        dir: []const u8 = "",
        /// Ordered candidates from the client's config; first installed
        /// one wins — same policy as the local attach path.
        servers: []const LspOpenSrv = &.{},
    };

    fn lspRootExists(_: ?*anyopaque, dir: []const u8, name: []const u8) bool {
        var buf: [4096]u8 = undefined;
        const full = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ dir, name }) catch return false;
        return c.access(full.ptr, c.F_OK) == 0;
    }

    /// Spawn a language server NEAR THE FILES: resolve the first
    /// installed candidate on THIS host's PATH, walk `dir` up for its
    /// root markers on THIS host's filesystem, fork it with stdio on a
    /// socketpair, and bridge that fd as an ordinary byte channel. The
    /// daemon relays the raw JSON-RPC bytes and never parses them —
    /// the LSP client stays in the GUI. ok:false is SILENT degradation
    /// ("no server on this host"), never an `.err` frame.
    pub fn handleLspOpen(self: *Daemon, cl: *Client, payload: []const u8) void {
        var parsed = std.json.parseFromSlice(LspOpenReq, self.allocator, payload, .{
            .ignore_unknown_fields = true,
        }) catch {
            cl.queueErr("bad lsp_open request");
            return;
        };
        defer parsed.deinit();
        const req = parsed.value;
        if (req.dir.len == 0 or req.dir[0] != '/') {
            cl.queueJson(.lsp_reply, .{ .req = req.req, .ok = false, .@"error" = "bad dir" });
            return;
        }
        for (req.servers) |srv| {
            if (srv.command.len == 0) continue;
            if (!lsp_proc.onPath(self.allocator, srv.command)) continue;
            const root = lsp_servers.findRoot(req.dir, srv.root_files, lspRootExists, null);
            var argv: std.ArrayList([]const u8) = .empty;
            defer argv.deinit(self.allocator);
            lsp_proc.splitArgs(self.allocator, srv.args, &argv) catch {};
            const child = lsp_proc.spawnSock(self.allocator, srv.command, argv.items, root) catch {
                log.warn("lsp_open: spawn of '{s}' failed", .{srv.command});
                continue;
            };
            const ch = self.allocator.create(Channel) catch {
                _ = c.kill(-child.pid, c.SIGKILL);
                _ = c.close(child.fd);
                var st: c_int = 0;
                _ = c.waitpid(child.pid, &st, 0);
                cl.queueJson(.lsp_reply, .{ .req = req.req, .ok = false, .@"error" = "oom" });
                return;
            };
            ch.* = .{
                .allocator = self.allocator,
                .id = self.next_chan_id,
                .fd = child.fd,
                .session = null,
                .client = cl,
                .tcp = true,
                .child_pid = child.pid,
            };
            self.next_chan_id += 1;
            self.channels.append(self.allocator, ch) catch {
                ch.dead = true; // dropDeadChannels won't see it; kill directly
                _ = c.kill(-child.pid, c.SIGKILL);
                var st: c_int = 0;
                _ = c.waitpid(child.pid, &st, 0);
                ch.child_pid = -1;
                ch.deinit();
                cl.queueJson(.lsp_reply, .{ .req = req.req, .ok = false, .@"error" = "oom" });
                return;
            };
            log.debug("lsp_open: '{s}' pid {d} root '{s}' -> channel {d}", .{ srv.command, child.pid, root, ch.id });
            var ob: [5]u8 = undefined;
            cl.queueFrame(.chan_open, wire.encodeChanOpen(&ob, ch.id, .lsp));
            cl.queueJson(.lsp_reply, .{
                .req = req.req,
                .ok = true,
                .chan = ch.id,
                .name = srv.name,
                .root = root,
            });
            return;
        }
        // No candidate installed here: the client degrades silently,
        // exactly like a missing local server.
        cl.queueJson(.lsp_reply, .{ .req = req.req, .ok = false });
    }

    const WebHelperReq = struct { req: u32 = 0 };

    /// Spawn a `sketerm-webengine --frames-inline` on THIS host with its
    /// client connection on a socketpair, and bridge that fd as an
    /// ordinary byte channel — the remote-browsing primitive. The daemon
    /// relays the raw helper-protocol bytes and never parses them; the
    /// helper never gets a listening socket (no connect-retry, no stale
    /// socket file) and dies with the channel exactly like an lsp child.
    /// A missing binary is a DESCRIBED ok:false, never a hang: the GUI
    /// shows the message on the pane.
    pub fn handleWebHelperOpen(self: *Daemon, cl: *Client, payload: []const u8) void {
        var parsed = std.json.parseFromSlice(WebHelperReq, self.allocator, payload, .{
            .ignore_unknown_fields = true,
        }) catch {
            cl.queueErr("bad web_helper_open request");
            return;
        };
        defer parsed.deinit();
        const req = parsed.value;
        var bin_buf: [4096:0]u8 = undefined;
        const bin = webfindbin.find(&bin_buf) orelse {
            cl.queueJson(.web_helper_reply, .{
                .req = req.req,
                .ok = false,
                .@"error" = "sketerm-webengine is not installed on this host",
            });
            return;
        };
        var pair: [2]c_int = .{ -1, -1 };
        if (c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &pair) != 0) {
            cl.queueJson(.web_helper_reply, .{ .req = req.req, .ok = false, .@"error" = "socketpair failed" });
            return;
        }
        // Park both ends above the stdio range and mark OUR end
        // cloexec: a daemonized parent can have fds 0-2 closed, and the
        // child's stdio rewiring below must not clobber its own end.
        for (&pair) |*fd| {
            if (fd.* < 3) {
                const moved = c.fcntl(fd.*, c.F_DUPFD, @as(c_int, 3));
                _ = c.close(fd.*);
                fd.* = if (moved < 0) -1 else moved;
            }
        }
        if (pair[0] < 0 or pair[1] < 0) {
            for (pair) |fd| if (fd >= 0) {
                _ = c.close(fd);
            };
            cl.queueJson(.web_helper_reply, .{ .req = req.req, .ok = false, .@"error" = "socketpair failed" });
            return;
        }
        _ = c.fcntl(pair[0], c.F_SETFD, c.FD_CLOEXEC);
        // The child's argv, NUL-terminated before the fork (no
        // allocation between fork and exec).
        var fd_arg: [16:0]u8 = undefined;
        const fd_str = std.fmt.bufPrintZ(&fd_arg, "{d}", .{pair[1]}) catch unreachable;
        const pid = c.fork();
        if (pid < 0) {
            _ = c.close(pair[0]);
            _ = c.close(pair[1]);
            cl.queueJson(.web_helper_reply, .{ .req = req.req, .ok = false, .@"error" = "fork failed" });
            return;
        }
        if (pid == 0) {
            // Own process group, so channel teardown can kill CEF's
            // whole subprocess tree (the lsp discipline).
            _ = c.setpgid(0, 0);
            const devnull = c.open("/dev/null", c.O_RDWR);
            if (devnull >= 0) {
                _ = c.dup2(devnull, 0);
                _ = c.dup2(devnull, 1);
                _ = c.dup2(devnull, 2);
                if (devnull > 2) _ = c.close(devnull);
            }
            var argv: [6:null]?[*:0]const u8 = .{ bin, "--socket-fd", fd_str.ptr, "--frames-inline", null, null };
            _ = c.execv(bin, @ptrCast(@constCast(&argv)));
            c._exit(127);
        }
        _ = c.close(pair[1]);
        const ch = self.allocator.create(Channel) catch {
            _ = c.close(pair[0]);
            _ = c.kill(-pid, c.SIGKILL);
            var st: c_int = 0;
            _ = c.waitpid(pid, &st, 0);
            cl.queueJson(.web_helper_reply, .{ .req = req.req, .ok = false, .@"error" = "oom" });
            return;
        };
        const fl = c.fcntl(pair[0], c.F_GETFL, @as(c_int, 0));
        _ = c.fcntl(pair[0], c.F_SETFL, fl | c.O_NONBLOCK);
        ch.* = .{
            .allocator = self.allocator,
            .id = self.next_chan_id,
            .fd = pair[0],
            .session = null,
            .client = cl,
            .tcp = true,
            .child_pid = pid,
        };
        self.next_chan_id += 1;
        self.channels.append(self.allocator, ch) catch {
            ch.dead = true;
            _ = c.kill(-pid, c.SIGKILL);
            var st: c_int = 0;
            _ = c.waitpid(pid, &st, 0);
            ch.child_pid = -1;
            ch.deinit();
            cl.queueJson(.web_helper_reply, .{ .req = req.req, .ok = false, .@"error" = "oom" });
            return;
        };
        log.debug("web_helper_open: pid {d} -> channel {d}", .{ pid, ch.id });
        var ob: [5]u8 = undefined;
        cl.queueFrame(.chan_open, wire.encodeChanOpen(&ob, ch.id, .web_helper));
        cl.queueJson(.web_helper_reply, .{ .req = req.req, .ok = true, .chan = ch.id });
    }

    const WebHelperConnectReq = struct { req: u32 = 0, session: []const u8 = "" };

    /// Bridge a browser helper ALREADY serving beside this daemon's
    /// socket (`web_helper_connect`): the assistant's helper of the MCP
    /// instance this daemon belongs to, resolved through the presence
    /// files exactly as the local GUI resolves it (`webpresence.zig`).
    /// The channel owns no process: closing it closes a client of the
    /// helper and nothing more, so the assistant's browser is never
    /// killed by a viewer leaving.
    pub fn handleWebHelperConnect(self: *Daemon, cl: *Client, payload: []const u8) void {
        var parsed = std.json.parseFromSlice(WebHelperConnectReq, self.allocator, payload, .{
            .ignore_unknown_fields = true,
        }) catch {
            cl.queueErr("bad web_helper_connect request");
            return;
        };
        defer parsed.deinit();
        const req = parsed.value;
        var sock_buf: [webpresence.MAX_PATH]u8 = undefined;
        const sock = webpresence.helperSocketFor(&sock_buf, self.sock_path, req.session) orelse {
            cl.queueJson(.web_helper_reply, .{ .req = req.req, .ok = false, .@"error" = "no browser helper socket beside this daemon" });
            return;
        };
        var addr = std.mem.zeroes(c.struct_sockaddr_un);
        if (sock.len + 1 > addr.sun_path.len) {
            cl.queueJson(.web_helper_reply, .{ .req = req.req, .ok = false, .@"error" = "helper socket path too long" });
            return;
        }
        addr.sun_family = c.AF_UNIX;
        @memcpy(addr.sun_path[0..sock.len], sock);
        const fd = platform.socketCloexec(c.AF_UNIX, c.SOCK_STREAM, 0);
        if (fd < 0) {
            cl.queueJson(.web_helper_reply, .{ .req = req.req, .ok = false, .@"error" = "socket failed" });
            return;
        }
        if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0) {
            _ = c.close(fd);
            cl.queueJson(.web_helper_reply, .{ .req = req.req, .ok = false, .@"error" = "the assistant's browser helper is not running (its socket does not answer)" });
            return;
        }
        const fl = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
        _ = c.fcntl(fd, c.F_SETFL, fl | c.O_NONBLOCK);
        const ch = self.allocator.create(Channel) catch {
            _ = c.close(fd);
            cl.queueJson(.web_helper_reply, .{ .req = req.req, .ok = false, .@"error" = "oom" });
            return;
        };
        ch.* = .{
            .allocator = self.allocator,
            .id = self.next_chan_id,
            .fd = fd,
            .session = null,
            .client = cl,
            .tcp = true,
        };
        self.next_chan_id += 1;
        self.channels.append(self.allocator, ch) catch {
            ch.dead = true;
            ch.deinit();
            cl.queueJson(.web_helper_reply, .{ .req = req.req, .ok = false, .@"error" = "oom" });
            return;
        };
        log.debug("web_helper_connect: {s} -> channel {d}", .{ sock, ch.id });
        var ob: [5]u8 = undefined;
        cl.queueFrame(.chan_open, wire.encodeChanOpen(&ob, ch.id, .web_helper));
        cl.queueJson(.web_helper_reply, .{ .req = req.req, .ok = true, .chan = ch.id });
    }

    const SearchReq = struct { pattern: []const u8, max: u32 = 50 };

    /// Case-insensitive substring search over the attached session's
    /// scrollback + live grid. Attach-scoped so it runs in whichever
    /// process owns the Screen (worker, in broker mode). `back` is
    /// display lines up from the bottom at search time.
    pub fn handleSearch(self: *Daemon, cl: *Client, payload: []const u8) void {
        const s = cl.attached orelse {
            cl.queueErr("not attached");
            return;
        };
        var parsed = std.json.parseFromSlice(SearchReq, self.allocator, payload, .{
            .ignore_unknown_fields = true,
        }) catch {
            cl.queueErr("bad search request");
            return;
        };
        defer parsed.deinit();
        const req = parsed.value;
        if (req.pattern.len == 0 or req.pattern.len > 512) {
            cl.queueErr("bad pattern length");
            return;
        }
        const max = @min(req.max, 500);

        const text = s.screen.extractScrollback(self.allocator) catch {
            cl.queueErr("search: out of memory");
            return;
        };
        defer self.allocator.free(text);

        var n_lines: u32 = 0;
        {
            var it = std.mem.splitScalar(u8, text, '\n');
            while (it.next()) |_| n_lines += 1;
        }

        const Hit = struct { back: u32, text: []const u8 };
        var hits: std.ArrayList(Hit) = .empty;
        defer hits.deinit(self.allocator);
        var total: u32 = 0;
        var idx: u32 = 0;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| : (idx += 1) {
            if (line.len == 0) continue;
            if (std.ascii.indexOfIgnoreCase(line, req.pattern) == null) continue;
            total += 1;
            if (hits.items.len < max) {
                // Cap hit lines; back off a mid-UTF-8 cut so the JSON
                // string stays valid.
                var end: usize = @min(line.len, 500);
                if (end < line.len) {
                    while (end > 0 and (line[end] & 0xC0) == 0x80) end -= 1;
                }
                hits.append(self.allocator, .{ .back = n_lines - 1 - idx, .text = line[0..end] }) catch break;
            }
        }
        cl.queueJson(.search_hits, .{ .hits = hits.items, .total = total });
    }

    pub fn handleKill(self: *Daemon, cl: *Client, payload: []const u8) void {
        if (self.is_broker) return self.brokerKill(cl, payload);
        var parsed = std.json.parseFromSlice(KillReq, self.allocator, payload, .{
            .ignore_unknown_fields = true,
        }) catch {
            cl.queueErr("bad kill request");
            return;
        };
        defer parsed.deinit();
        const s = self.findSession(parsed.value.name) orelse {
            cl.queueErr("no such session");
            return;
        };
        if (parsed.value.origin_id.len > 0 and
            (!validSessionOriginId(parsed.value.origin_id) or
                !std.mem.eql(u8, parsed.value.origin_id, &s.origin_id)))
        {
            cl.queueErr("session origin identity changed");
            return;
        }
        if (parsed.value.require_display and !s.display) {
            cl.queueErr("session is not a display session");
            return;
        }
        if (parsed.value.expected_pid != 0 and parsed.value.expected_pid != s.childPid()) {
            cl.queueErr("display session identity changed");
            return;
        }
        if (parsed.value.expected_wl_display.len > 0 and
            (s.wl_display_path == null or !std.mem.eql(u8, parsed.value.expected_wl_display, s.wl_display_path.?)))
        {
            cl.queueErr("display session identity changed");
            return;
        }
        self.removeSession(s);
        cl.queueJson(.ok, .{ .ok = true });
    }

    test "direct kill origin fence preserves replacements and accepts exact or absent identity" {
        const t = std.testing;
        const a = t.allocator;
        var empty: [0]u8 = .{};
        var daemon = Daemon{ .allocator = a, .listen_fd = -1, .sock_path = empty[0..] };
        defer daemon.sessions.deinit(a);
        defer daemon.clients.deinit(a);
        defer daemon.channels.deinit(a);
        defer daemon.panel_routes.deinit(a);
        var requester = Client{ .allocator = a, .fd = -1 };
        defer requester.rbuf.deinit(a);
        defer requester.wbuf.deinit(a);
        defer requester.audio_wbuf.deinit(a);
        var replacement: Session = undefined;
        replacement.name = @constCast("same");
        replacement.origin_name = @constCast("same");
        replacement.origin_id = "20000000000000000000000000000002".*;
        replacement.controller = null;
        replacement.exited = false;
        try daemon.sessions.append(a, &replacement);

        daemon.handleKill(&requester, "{\"name\":\"same\",\"origin_id\":\"10000000000000000000000000000001\"}");
        try t.expect(!replacement.exited);
        var reply = (try wire.peelFrame(requester.wbuf.items)) orelse return error.TestUnexpectedResult;
        try t.expectEqual(wire.FrameType.err, reply.frame.ftype);
        try t.expect(std.mem.indexOf(u8, reply.frame.payload, "origin identity changed") != null);

        requester.wbuf.clearRetainingCapacity();
        daemon.handleKill(&requester, "{\"name\":\"same\",\"origin_id\":\"not-an-id\"}");
        try t.expect(!replacement.exited);
        reply = (try wire.peelFrame(requester.wbuf.items)) orelse return error.TestUnexpectedResult;
        try t.expectEqual(wire.FrameType.err, reply.frame.ftype);

        requester.wbuf.clearRetainingCapacity();
        daemon.handleKill(&requester, "{\"name\":\"same\",\"origin_id\":\"20000000000000000000000000000002\"}");
        try t.expect(replacement.exited);
        reply = (try wire.peelFrame(requester.wbuf.items)) orelse return error.TestUnexpectedResult;
        try t.expectEqual(wire.FrameType.ok, reply.frame.ftype);

        replacement.exited = false;
        requester.wbuf.clearRetainingCapacity();
        daemon.handleKill(&requester, "{\"name\":\"same\"}");
        try t.expect(replacement.exited);
        reply = (try wire.peelFrame(requester.wbuf.items)) orelse return error.TestUnexpectedResult;
        try t.expectEqual(wire.FrameType.ok, reply.frame.ftype);
    }

    pub fn handleRename(self: *Daemon, cl: *Client, payload: []const u8) void {
        if (self.is_broker) return self.brokerRename(cl, payload);
        var parsed = std.json.parseFromSlice(RenameReq, self.allocator, payload, .{
            .ignore_unknown_fields = true,
        }) catch {
            cl.queueErr("bad rename request");
            return;
        };
        defer parsed.deinit();
        const req = parsed.value;
        if (!validSessionName(req.new_name)) {
            cl.queueErr("rename needs a name (1-64 chars)");
            return;
        }
        const s = self.findSession(req.name) orelse {
            cl.queueErr("no such session");
            return;
        };
        if (self.findSession(req.new_name)) |other| {
            if (other != s) {
                cl.queueErr("session name already exists");
                return;
            }
        }
        if (self.isWorker()) {
            self.workerRequestRename(cl, req.new_name);
            return;
        }
        s.renameTo(req.new_name) catch {
            cl.queueErr("oom");
            return;
        };
        self.broadcastSessionIdentity(s);
        cl.queueJson(.ok, .{ .ok = true, .name = s.name });
    }

    pub fn removeSession(self: *Daemon, s: *Session) void {
        s.controller = null;
        self.panelSessionClosed(s);
        for (self.clients.items) |cl| {
            if (cl.attached == s) {
                cl.queueJson(.gone, .{ .reason = "session closed" });
                clearClientAttachment(cl);
            }
        }
        for (self.channels.items) |ch| {
            if (ch.session == s) self.closeChannel(ch, true);
        }
        // Mark only — removeSession runs mid-tick (kill frames), and
        // dropping list entries here would desync the pollfd array
        // built at tick start. Marking exited makes this tick poll the
        // session fd as -1 (see tick()) so it stops draining
        // immediately, and reap() at tick end removes it via
        // swapRemove + s.deinit() — which calls pty.closeAndReap() to
        // SIGHUP/SIGTERM/SIGKILL and reap the child. The kill still
        // feels immediate: the client's .ok is queued by the caller
        // and the session is gone within this same tick.
        s.exited = true;
    }

    fn dropDeadChannels(self: *Daemon) void {
        var i: usize = 0;
        while (i < self.channels.items.len) {
            const ch = self.channels.items[i];
            if (ch.dead) {
                // A dying LSP channel takes its server down: SIGTERM
                // the group now (build tooling included), SIGKILL via
                // the reap list if it lingers past the grace period.
                if (ch.child_pid > 0) {
                    _ = c.kill(-ch.child_pid, c.SIGTERM);
                    self.lsp_reaps.append(self.allocator, .{
                        .pid = ch.child_pid,
                        .kill_at_ms = nowMs() + LSP_KILL_GRACE_MS,
                    }) catch {
                        _ = c.kill(-ch.child_pid, c.SIGKILL);
                        var st: c_int = 0;
                        _ = c.waitpid(ch.child_pid, &st, 0);
                    };
                }
                _ = self.channels.swapRemove(i);
                ch.deinit();
            } else {
                i += 1;
            }
        }
    }

    pub const LspReap = struct { pid: c.pid_t, kill_at_ms: i64, killed: bool = false };
    /// How long a language server gets between SIGTERM and SIGKILL —
    /// same grace the GUI gives a local server (editorlsp.zig).
    const LSP_KILL_GRACE_MS: i64 = 1500;

    /// Non-blocking sweep of dying language-server children. Zombies
    /// are reaped by exact pid (never waitpid(-1) — PTY sessions own
    /// their own children).
    fn reapLspChildren(self: *Daemon) void {
        var i: usize = 0;
        while (i < self.lsp_reaps.items.len) {
            const r = &self.lsp_reaps.items[i];
            var st: c_int = 0;
            const w = c.waitpid(r.pid, &st, c.WNOHANG);
            if (w == r.pid or w < 0) {
                _ = self.lsp_reaps.swapRemove(i);
                continue;
            }
            if (!r.killed and nowMs() >= r.kill_at_ms) {
                _ = c.kill(-r.pid, c.SIGKILL);
                r.killed = true;
            }
            i += 1;
        }
    }

    /// Start an ingestion batch for `s`: events applied to the
    /// authoritative Screen and serialized for broadcast in one pass.
    /// Shared by the PTY drain and cast playback — pair with
    /// `ingestFinish`, feeding bytes via `ingestBytes` in between.
    pub fn ingestBegin(self: *Daemon, s: *Session) EventCollector {
        return .{
            .allocator = self.allocator,
            .screen = s.screen,
            .writer = wire.Writer.init(self.allocator),
            .ring = &s.log,
            .wall_ms = wallMs(),
            // A cast file is untrusted content: kitty file/tempfile/
            // shm APCs are dropped before they can read this host's
            // filesystem (see EventCollector.emit).
            .untrusted = s.isCast(),
            .session_name = s.name,
            .kitty_drop_warned = &s.kitty_drop_warned,
        };
    }

    /// Read whatever the PTY has, parse, apply to the authoritative
    /// Screen, and broadcast the serialized events to attached
    /// clients in one EVENTS frame.
    /// POLLOUT on a session's master: push queued client input into
    /// the slave. Closes the drop episode `Session.writeToChild` opened
    /// with the total, so a refusal is bracketed in the log, not lost.
    fn flushSessionInput(self: *Daemon, s: *Session) void {
        _ = self;
        const pty = s.ptyPtr() orelse return;
        switch (pty.flushQueue()) {
            .blocked => {},
            .drained => |dropped| if (dropped > 0) {
                log.warn("session '{s}': child is reading again; {d} B of input were dropped while its queue was full", .{ s.name, dropped });
            },
            .failed => |lost| log.warn("session '{s}': terminal write failed; {d} B of queued input discarded", .{ s.name, lost }),
        }
    }

    fn drainSession(self: *Daemon, s: *Session) void {
        const pty = s.ptyPtr() orelse return;
        var chunk: [32768]u8 = undefined;
        var total_events = self.ingestBegin(s);

        var rounds: u8 = 0;
        while (rounds < 8) : (rounds += 1) {
            const n_raw = c.read(pty.master_fd, &chunk, chunk.len);
            if (n_raw < 0) {
                // EAGAIN = drained; anything else (EIO) = child gone.
                if (std.posix.errno(n_raw) != .AGAIN) self.sessionExited(s);
                break;
            }
            if (n_raw == 0) {
                self.sessionExited(s);
                break;
            }
            const n: usize = @intCast(n_raw);
            if (s.cast_recorder) |*rec| rec.output(nowMs(), chunk[0..n]);
            ingestBytes(s, &total_events, chunk[0..n]);
            if (n < chunk.len) break;
        }
        self.ingestFinish(s, &total_events, true);
    }

    /// Finish an ingestion batch: broadcast the collected events and
    /// markers to attached clients (unless `broadcast` is false — the
    /// silent seek-replay path applies to the Screen only) and always
    /// release the collector.
    pub fn ingestFinish(self: *Daemon, s: *Session, total_events: *EventCollector, broadcast: bool) void {
        defer total_events.writer.deinit();
        defer total_events.deinitMarkers();

        const n_events = total_events.count;
        if (n_events == 0 and !total_events.serialization_failed and total_events.markers.items.len == 0) return;
        if (!broadcast) return;
        // Real terminal output this drain → the session is active now.
        s.last_activity_ms = nowMs();
        var any_attached = false;
        for (self.clients.items) |cl| {
            if (terminalViewer(cl, s)) {
                any_attached = true;
                break;
            }
        }
        if (any_attached) self.sampleForeground(s);
        publish: {
            if (total_events.serialization_failed) {
                for (self.clients.items) |cl| self.requireSnapshot(cl, s);
                log.warn("event serialization failed; snapshot resync scheduled (session '{s}')", .{s.name});
                break :publish;
            }
            if (n_events == 0) break :publish;

            const next_seq = std.math.add(u64, s.seq, @as(u64, n_events)) catch {
                for (self.clients.items) |cl| self.requireSnapshot(cl, s);
                log.warn("event sequence exhausted; snapshot resync scheduled (session '{s}')", .{s.name});
                break :publish;
            };
            if (!any_attached) {
                s.seq = next_seq;
                break :publish;
            }

            var payload: std.ArrayList(u8) = .empty;
            defer payload.deinit(self.allocator);
            var hdr: [12]u8 = undefined;
            std.mem.writeInt(u64, hdr[0..8], s.seq, .little);
            std.mem.writeInt(u32, hdr[8..12], n_events, .little);
            payload.appendSlice(self.allocator, &hdr) catch {
                for (self.clients.items) |cl| self.requireSnapshot(cl, s);
                log.warn("events header allocation failed; snapshot resync scheduled (session '{s}')", .{s.name});
                break :publish;
            };
            payload.appendSlice(self.allocator, total_events.writer.buf.items) catch {
                for (self.clients.items) |cl| self.requireSnapshot(cl, s);
                log.warn("events payload allocation failed; snapshot resync scheduled (session '{s}')", .{s.name});
                break :publish;
            };

            // Once a complete shared payload exists, its sequence is committed.
            // A client-specific frame allocation failure recovers from a snapshot
            // stamped with this new value while successful peers keep streaming.
            s.seq = next_seq;
            for (self.clients.items) |cl| {
                if (!terminalViewer(cl, s)) continue;
                // Backpressure: a client this far behind (flooding
                // session, consumer idle between MCP tool calls) stops
                // receiving events — clientWritable resyncs it with a
                // fresh snapshot once its wbuf drains. Without this a
                // sustained flood grows wbuf to the MAX_WBUF reap.
                if (cl.needs_resync) continue;
                if (cl.queuedBytes() > Client.EVENTS_BACKLOG) {
                    cl.needs_resync = true;
                    log.debug("client queues {d}B over events backlog; snapshot resync scheduled (session '{s}')", .{ cl.queuedBytes(), s.name });
                    continue;
                }
                if (!cl.tryQueueFrameIn(&cl.wbuf, .events, payload.items)) {
                    if (!cl.dead) self.requireSnapshot(cl, s);
                }
            }
        }
        // Markers push to every attached client regardless of the
        // events backpressure — they are tiny and time-sensitive (the
        // viewer stashes "the app right now" against them).
        for (total_events.markers.items) |m| {
            for (self.clients.items) |cl| {
                if (terminalViewer(cl, s))
                    cl.queueJson(.marker, .{ .id = m.id, .label = m.label, .t = total_events.wall_ms, .after = m.after });
            }
            log.debug("marker #{d} '{s}' after={d} (session '{s}')", .{ m.id, m.label, m.after, s.name });
        }
    }

    fn sessionExited(self: *Daemon, s: *Session) void {
        if (s.exited) return;
        s.exited = true;
        // Nothing will ever drive this session again; keeping the
        // pointer would only risk a dangle past the client reap.
        s.controller = null;
        self.panelSessionClosed(s);
        log.info("session '{s}' exited", .{s.name});
        // We reach here on PTY EOF/EIO: the child has exited but may
        // not be waitpid-able for another scheduler tick, and a single
        // WNOHANG try races it — the .exit frame then ships the
        // default 0 even for a SIGSEGV death (reported by MCP users as
        // "segfault exited 0"). Retry briefly; EOF implies the exit
        // already happened, so this converges in microseconds. The
        // bound only bites when a child closed its stdio and lives on.
        if (s.ptyPtr()) |pty| {
            var tries: u32 = 0;
            while (tries < 50) : (tries += 1) {
                if (pty.reap()) |code| {
                    s.exit_status = code;
                    break;
                }
                _ = c.usleep(1000);
            }
        }
        var st: [4]u8 = undefined;
        std.mem.writeInt(i32, &st, s.exit_status, .little);
        // A crash mid-line must keep the tail in the log ring.
        s.log.flush(wallMs());
        // Deliver the exit, then force-detach: nothing will ever flow
        // on this session again, and a client that vanished without a
        // clean goodbye (UDP peer roamed away for good) must not pin
        // the dead session in the list forever.
        for (self.clients.items) |cl| {
            if (cl.attached == s) {
                if (!cl.dead) {
                    if (cl.panel_only) {
                        cl.queueJson(.gone, .{ .reason = "session exited" });
                        clearClientAttachment(cl);
                        continue;
                    }
                    // A backlogged client had events withheld; clients
                    // stop pumping after `.exit`, so the resync snapshot
                    // (the FINAL screen — the crash post-mortem) must go
                    // out ahead of the exit frame, not after.
                    if (cl.needs_resync) self.queueSnapshot(cl, s);
                    // Post-mortem log push: the exit force-detaches the
                    // client, so a later log_get would find no session.
                    self.queueLogData(cl, s, .{ .tail = 300, .max_chars = 1000 });
                    cl.queueFrame(.exit, &st);
                }
                clearClientAttachment(cl);
            }
        }
    }

    /// Kill sessions whose idle TTL has run out. An attached mux viewer or
    /// live external Wayland client resets the clock; a session that has
    /// never had either counts from spawn.
    /// In broker mode this runs in the WORKER (which owns the session
    /// and knows its viewers); its exit is what retires the record.
    fn ttlSweep(self: *Daemon) void {
        const now = nowMs();
        for (self.sessions.items) |s| {
            if (s.ttl_ms == 0 or s.exited) continue;
            var occupied = false;
            for (self.clients.items) |cl| {
                if (terminalViewer(cl, s)) {
                    occupied = true;
                    break;
                }
            }
            if (!occupied and s.display) {
                for (self.channels.items) |ch| {
                    if (!ch.dead and ch.session == s and ch.native != null and
                        (!ch.auxiliary or ch.native.?.brain.hasToplevels()))
                    {
                        occupied = true;
                        break;
                    }
                }
            }
            if (occupied) {
                s.no_viewer_since_ms = 0;
                continue;
            }
            if (s.no_viewer_since_ms == 0) {
                s.no_viewer_since_ms = now;
                continue;
            }
            if (now - s.no_viewer_since_ms < s.ttl_ms) continue;
            log.info("session '{s}': ttl expired ({d}s unoccupied)", .{ s.name, @divTrunc(s.ttl_ms, 1000) });
            self.removeSession(s);
        }
    }

    /// One-shot teardown of a dead client's session-scoped identity,
    /// run by `reap` phase 1 while the client is still IN
    /// `self.clients` and still pointed at by every dependent
    /// collection.
    ///
    /// Its broadcasts can queue frames, and `Client.queueFrame` marks a
    /// recipient past `MAX_WBUF` dead, which is exactly why phase 1
    /// iterates to a fixpoint and the sweeps come after it. Leaving the
    /// client in `self.clients` costs nothing: every roster helper
    /// filters on `terminalViewer`, which excludes `dead`.
    fn detachDeadClient(self: *Daemon, cl: *Client) void {
        // A dying client's TCP forwards die with it (native and audio
        // channels are session-owned and survive).
        for (self.channels.items) |ch| {
            if (ch.tcp and ch.client == cl) ch.dead = true;
        }
        const was = cl.attached;
        if (was) |s| log.info("client gone (session '{s}')", .{s.name});
        self.panelClientDetached(cl, "panel presenter disconnected after request delivery; delivery is uncertain, the mutation may have applied, and the request was NOT resent");
        // A pending broker rename whose requester died must free
        // the slot, or every later rename on this worker fails
        // "already in progress" (the 'n' reply would find no live
        // requester to answer anyway).
        if (self.worker_rename_request) |pending| {
            if (pending.requester_id == cl.id) self.worker_rename_request = null;
        }
        // Release BEFORE the client is freed: the handover scan
        // compares against this pointer, and s.controller would
        // otherwise dangle.
        const lease_moved = if (was) |s| self.releaseControl(s, cl) else false;
        // Duplicate rosters (several deaths, one session) are
        // harmless; correctness beats coalescing here.
        if (was) |s| {
            if (!s.exited) {
                if (lease_moved) self.broadcastControlState(s);
                self.broadcastPeerInfo(s);
            }
        }
    }

    /// Retire dead clients in three ordered phases; the order is the
    /// whole point and a future edit must not collapse it.
    ///
    /// Phase 1 detaches every dead client (`detachDeadClient`),
    /// repeating until no NEW client dies: its roster broadcasts queue
    /// frames and a recipient past `MAX_WBUF` dies right there. Phase 2
    /// sweeps EVERY collection that holds a raw `*Client` (channels,
    /// uploads, downloads, fs views, fs listings, fs jobs) against the
    /// full dead set. Phase 3 frees exactly the clients phase 1
    /// flagged. Freeing a client the sweeps have not seen leaves a
    /// dangling `*Client` that the next tick dereferences, which is
    /// what an interleaved detach-and-free loop did.
    fn reap(self: *Daemon) void {
        self.reapLspChildren();

        // -- phase 1: detach, to a fixpoint ------------------------
        var detached_any = true;
        while (detached_any) {
            detached_any = false;
            for (self.clients.items) |cl| {
                if (!cl.dead or cl.reaping) continue;
                cl.reaping = true;
                detached_any = true;
                self.detachDeadClient(cl);
            }
        }

        // -- phase 2: sweep every holder of a raw *Client -----------
        // A dying client takes its WINSTREAM channels down. Native
        // channels are session-owned and deliberately survive client
        // death — the daemon brain keeps the app alive for the next
        // attach (durable GUI apps). They die only with the session
        // or on app-socket EOF.
        for (self.channels.items) |ch| {
            if (ch.client) |cl| {
                if (cl.dead) ch.dead = true;
            }
        }
        // Client churn changes the video-decode consensus.
        var any_client_died = false;
        for (self.clients.items) |cl| {
            if (cl.dead) any_client_died = true;
        }
        if (any_client_died) self.refreshVideoGates();
        self.dropDeadChannels();
        // A dying client abandons its uploads: close the partial file
        // (it stays on disk under its chosen name — no auto-delete; a
        // half-written upload is the user's to discard).
        {
            var i: usize = 0;
            while (i < self.uploads.items.len) {
                if (self.uploads.items[i].client.dead) {
                    self.uploads.swapRemove(i).deinit();
                } else i += 1;
            }
        }
        {
            var i: usize = 0;
            while (i < self.downloads.items.len) {
                if (self.downloads.items[i].client.dead) {
                    self.downloads.swapRemove(i).deinit();
                } else i += 1;
            }
        }
        // A dying client's fs views die with it (dropFsViewAt keeps
        // shared kernel watches alive for surviving views).
        {
            var i: usize = 0;
            while (i < self.fs_views.items.len) {
                if (self.fs_views.items[i].client.dead) {
                    self.dropFsViewAt(i);
                } else i += 1;
            }
        }
        // An in-flight listing outlives the fs_reply chunk it is
        // streaming, so a plain `fs_op list` from a client that dies
        // mid-listing kept a raw `*Client` that pumpFsListings then
        // dereferenced on the next tick. Runs AFTER the view sweep,
        // which already took every listing bound to a dying view with
        // it: what survives here is view-less, and only a view-bound
        // listing can hold a snapshot boundary to close.
        {
            var i: usize = 0;
            while (i < self.fs_listings.items.len) {
                const listing = self.fs_listings.items[i];
                if (listing.client.dead) {
                    _ = self.fs_listings.swapRemove(i);
                    listing.deinit();
                } else i += 1;
            }
        }
        // Jobs OUTLIVE their client (durable transfers) — only the
        // event route dies with it. Finished jobs are retained for
        // job_list, bounded, oldest dropped first.
        {
            self.pumpFsJobCancelElections();
            self.restartCrashedFsJobs();
            for (self.fs_jobs.items) |j| {
                if (j.cancel_client) |cancel_client| {
                    if (cancel_client.dead) {
                        j.cancel_client = null;
                        j.cancel_req = 0;
                        j.cancel_reply_start = false;
                    }
                }
                if (j.owner) |o| {
                    if (o.dead) {
                        // pid > 0 is load-bearing: kill(-0) would signal
                        // the daemon's OWN process group.
                        if (j.ephemeral and !j.finished() and j.pid > 0) {
                            _ = c.kill(-j.pid, c.SIGKILL);
                            j.state = .canceled;
                        }
                        if (j.cleanup_at_ms > 0) j.cleanup_at_ms = nowMs();
                        j.owner = null;
                    }
                }
            }
            for (self.fs_jobs.items) |j| {
                if (j.out_fd >= 0 or (!j.terminal_pending and j.ack_req == 0)) continue;
                const emit_terminal = j.terminal_pending;
                if (j.ack_req != 0) j.acknowledged = true;
                self.saveFsJob(j) catch {
                    if (j.ack_req != 0) j.acknowledged = false;
                    continue;
                };
                if (emit_terminal) {
                    j.terminal_pending = false;
                    self.fsJobEmit(j, switch (j.state) {
                        .done => "done",
                        .canceled => "canceled",
                        else => "error",
                    });
                }
                if (j.ack_req != 0) {
                    if (j.owner) |owner| if (!owner.dead)
                        owner.queueJson(.fs_reply, .{ .req = j.ack_req, .ok = true });
                    j.ack_req = 0;
                }
            }
            var finished_count: usize = 0;
            var token_count: usize = 0;
            for (self.fs_jobs.items) |j| {
                if (!j.ephemeral and j.retentionReady()) {
                    if (j.client_token.len > 0) {
                        if (j.acknowledged) token_count += 1;
                    } else finished_count += 1;
                }
            }
            var i: usize = 0;
            const cleanup_now = nowMs();
            while (i < self.fs_jobs.items.len) {
                const j = self.fs_jobs.items[i];
                if (j.ephemeral and j.finished() and j.out_fd < 0 and
                    (j.cleanup_at_ms == 0 or j.cleanup_at_ms <= cleanup_now))
                {
                    _ = self.fs_jobs.orderedRemove(i);
                    j.deinit(false);
                } else i += 1;
            }
            i = 0;
            while (finished_count > MAX_FINISHED_JOBS and i < self.fs_jobs.items.len) {
                const j = self.fs_jobs.items[i];
                // Ephemeral jobs were not counted above and may be
                // TTL-held preview producers/sidecars a client is
                // about to consume; only the TTL sweep removes them.
                if (!j.ephemeral and j.retentionReady() and j.client_token.len == 0) {
                    self.deleteFsJobJournal(j.id);
                    _ = self.fs_jobs.orderedRemove(i);
                    j.deinit(false);
                    finished_count -= 1;
                } else i += 1;
            }
            i = 0;
            while (token_count > MAX_TOKEN_JOBS and i < self.fs_jobs.items.len) {
                const j = self.fs_jobs.items[i];
                if (j.retentionReady() and j.client_token.len > 0 and j.acknowledged) {
                    self.deleteFsJobJournal(j.id);
                    _ = self.fs_jobs.orderedRemove(i);
                    j.deinit(false);
                    token_count -= 1;
                } else i += 1;
            }
        }
        // -- phase 3: free exactly what phase 1 flagged -------------
        // `reaping` and not merely `dead`: a client one of the sweeps
        // above just killed has references they had already walked
        // past, so it waits for the next reap.
        var i: usize = 0;
        while (i < self.clients.items.len) {
            const cl = self.clients.items[i];
            if (cl.reaping) {
                _ = self.clients.swapRemove(i);
                cl.deinit();
            } else {
                i += 1;
            }
        }
        // No-viewer TTL (SpawnReq.ttl_secs): runs before the removal
        // sweep below so an expiring session is gone within this same
        // reap. Dead clients were dropped just above, so the viewer
        // count here is live.
        self.ttlSweep();
        // Exited sessions are removed outright — sessionExited
        // already detached every client (defensively re-checked here
        // so a dangling cl.attached is impossible). Live sessions are
        // NEVER reaped, attached or not: surviving client-less for
        // days is the whole point of the daemon.
        i = 0;
        while (i < self.sessions.items.len) {
            const s = self.sessions.items[i];
            if (s.exited) {
                for (self.clients.items) |cl| {
                    if (cl.attached == s) cl.attached = null;
                }
                // Session-owned channels must not outlive the session
                // (ch.session would dangle in the poll loop).
                for (self.channels.items) |ch| {
                    if (ch.session == s) self.closeChannel(ch, true);
                }
                self.dropDeadChannels();
                _ = self.sessions.swapRemove(i);
                s.deinit();
                continue;
            }
            i += 1;
        }
        // A worker exists only to serve its one session. Once that session is
        // gone (shell exited on its own, or was killed), the worker has no
        // reason to live — tear it down so the broker sees control EOF and
        // reaps it (otherwise it polls forever, orphaned, and `list` keeps a
        // stale entry). The `.exit`/`.gone` already queued to the client is
        // delivered by run()'s flushClientsFinal before we close. The monolith
        // (no control_fd) keeps running client-less — that's its whole point.
        if (self.isWorker() and self.sessions.items.len == 0) {
            // Don't exit while a live client still has queued bytes: the
            // post-mortem log push + `.exit` may sit behind megabytes of
            // withheld events an MCP client only reads at its NEXT tool
            // call — run()'s 8x50ms final flush cannot cover that gap,
            // and a socket buffer holds far less than the backlog. Keep
            // ticking (bounded) so the crash log outlives the app; a
            // client that never reads costs one 10s grace, not forever.
            var pending = false;
            for (self.clients.items) |cl| {
                if (!cl.dead and cl.queuedBytes() > 0) pending = true;
            }
            if (!pending) {
                self.running = false;
            } else if (self.drain_deadline_ms == 0) {
                self.drain_deadline_ms = nowMs() + 10_000;
                log.debug("worker lingering for client drain (post-mortem delivery)", .{});
            } else if (nowMs() >= self.drain_deadline_ms) {
                self.running = false;
            }
        }
        // Broker: a dead worker (control EOF or killed) is removed once its
        // process has been waitpid'd — otherwise it lingers as a zombie. We
        // hold the record (with its pid) until the reap succeeds; WNOHANG==0
        // means "not exited yet", retry next tick. ECHILD (<0) → already gone.
        i = 0;
        while (i < self.workers.items.len) {
            const w = self.workers.items[i];
            if (w.dead) {
                var status: c_int = 0;
                const r = c.waitpid(w.pid, &status, c.WNOHANG);
                if (r == 0) {
                    i += 1; // still alive; check again next tick
                    continue;
                }
                _ = self.workers.swapRemove(i);
                w.deinit();
                continue;
            }
            i += 1;
        }
        self.idleExitCheck();
    }

    /// `--idle-exit`: retire a daemon that has held nothing for anyone
    /// long enough. Counts are taken AFTER the reaps above, so a session
    /// exiting and its viewer leaving in the same tick start the clock
    /// together.
    fn idleExitCheck(self: *Daemon) void {
        if (self.idle_exit_ms <= 0 or self.isWorker()) return;
        const held = if (self.is_broker) self.workers.items.len else self.sessions.items.len;
        if (held > 0 or self.clients.items.len > 0) {
            self.idle_since_ms = 0;
            return;
        }
        const now = nowMs();
        if (self.idle_since_ms == 0) {
            self.idle_since_ms = now;
            return;
        }
        if (now - self.idle_since_ms >= self.idle_exit_ms) {
            log.info("idle for {d}s with no sessions or clients; exiting (--idle-exit)", .{@divTrunc(self.idle_exit_ms, 1000)});
            self.running = false;
        }
    }
};

/// Feed raw terminal bytes into an ingestion batch (parser -> Screen
/// + wire serialization). The cast playback engine calls this with
/// decoded cast output; the PTY drain with PTY reads.
pub fn ingestBytes(s: *Session, total_events: *EventCollector, bytes: []const u8) void {
    s.parser.advance(bytes, EventCollector.emit, @ptrCast(total_events));
}

/// Per-drain context: applies each event to the Screen and
/// serializes it for broadcast in the same pass.
pub const EventCollector = struct {
    allocator: std.mem.Allocator,
    screen: *Screen,
    writer: wire.Writer,
    count: u32 = 0,
    /// The current batch cannot be represented as a contiguous event stream.
    serialization_failed: bool = false,
    /// Session log ring to feed (escape-free lines); null = don't.
    ring: ?*logring.LogRing = null,
    /// Wall-clock stamp for lines committed during this drain.
    wall_ms: i64 = 0,
    /// Untrusted content (cast playback): kitty file/tempfile/shm
    /// APCs never reach `kitty_inline.rewrite`, so nothing in the
    /// recording can make the daemon open (or for t=t DELETE) a path
    /// of its choosing on this host. They are dropped like any other
    /// un-inlined file-medium APC, so they do not reach the wire
    /// either.
    untrusted: bool = false,
    /// Session name for log lines; empty when the collector has no session.
    session_name: []const u8 = "",
    /// The session's once-per-lifetime "a kitty image was dropped"
    /// warning latch; null = never warn (test collectors).
    kitty_drop_warned: ?*bool = null,
    /// OSC 5522 markers seen this drain; drainSession pushes them to
    /// attached clients and frees the labels.
    markers: std.ArrayList(Marker) = .empty,

    const Marker = struct { id: u64, label: []u8, after: u32 };

    /// Hard bound on `+N` frame delays (a runaway value must not arm
    /// a capture that effectively never fires).
    const MAX_MARKER_AFTER: u32 = 600;
    /// Pushed-label bound; the full label still lands in the ring
    /// line (4KB line cap), this only caps the `.marker` frame.
    const MAX_MARKER_LABEL: usize = 256;

    fn emit(user: ?*anyopaque, ev: Event) void {
        const self: *EventCollector = @ptrCast(@alignCast(user.?));
        // parse_error was historically added to an event stream whose records
        // have no lengths. Keep it daemon-local so protocol 1/2 readers never
        // encounter an unknown tag that would desynchronize the whole batch.
        if (ev == .parse_error) {
            self.screen.apply(ev);
            var mut = ev;
            mut.deinit(self.allocator);
            return;
        }
        // sketerm marker escape: private — swallowed rather than
        // forwarded. `OSC 5522;label` = a labelled log-ring line and a
        // `.marker` push so viewers stash a screenshot of "the app
        // right now"; `OSC 5522;+N;label` asks viewers to capture the
        // Nth FUTURE commit instead. Admission is token-bucket gated
        // (LogRing.admitMarker) so a cat'ed log full of these can't
        // evict real lines or flood viewers with encode work.
        if (ev == .osc) {
            const bytes = ev.osc.bytes;
            if (std.mem.eql(u8, bytes, "5522") or std.mem.startsWith(u8, bytes, "5522;")) {
                if (self.ring) |r| {
                    if (r.admitMarker(self.wall_ms)) {
                        var label = if (bytes.len > 5) bytes[5..] else "";
                        var after: u32 = 0;
                        if (label.len > 1 and label[0] == '+') parse: {
                            const semi = std.mem.indexOfScalar(u8, label, ';') orelse label.len;
                            const n = std.fmt.parseInt(u32, label[1..semi], 10) catch break :parse;
                            after = @min(n, MAX_MARKER_AFTER);
                            label = if (semi < label.len) label[semi + 1 ..] else "";
                        }
                        const id = r.addMarker(label, self.wall_ms);
                        const pushed = label[0..@min(label.len, MAX_MARKER_LABEL)];
                        if (self.allocator.dupe(u8, pushed)) |copy| {
                            self.markers.append(self.allocator, .{ .id = id, .label = copy, .after = after }) catch
                                self.allocator.free(copy);
                        } else |_| {}
                    }
                }
                var mut = ev;
                mut.deinit(self.allocator);
                return;
            }
        }
        // Kitty file/tempfile/shm transmissions reference THIS
        // host's filesystem — fetch and inline them so the client
        // (which can't read our disk) gets the data. Apply the
        // rewritten event locally too, keeping the authoritative
        // screen identical to what clients see. A file-medium APC
        // that could NOT be inlined is DROPPED, never forwarded:
        // `grid/kitty_images.zig` resolves the path on whatever host
        // the viewer runs on and, for `t=t`, unlinks it there, so a
        // forwarded `t=t` naming a path this host does not have (or
        // one over `kitty_inline.MAX_RAW_BYTES`, or a chunked
        // transmission `rewrite` refuses) is a remote file-deletion
        // primitive aimed at every attached client. Untrusted input
        // (cast playback) skips the fetch entirely and takes the same
        // drop, so it never touches the filesystem at all.
        var fwd = ev;
        var owned: ?[]u8 = null;
        defer if (owned) |b| self.allocator.free(b);
        if (ev == .apc and kittyFileMedium(ev.apc.bytes)) {
            const kitty_inline = @import("kitty_inline.zig");
            const result: kitty_inline.Result = if (self.untrusted)
                .{ .refused = .{ .why = .unreadable } }
            else
                kitty_inline.rewrite(self.allocator, ev.apc.bytes);
            switch (result) {
                .inlined => |nb| {
                    owned = nb;
                    fwd = .{ .apc = .{ .bytes = nb } };
                },
                .refused => |refused| {
                    if (!self.untrusted) {
                        // A capability probe still gets its answer. `a=q`
                        // returns from Screen.onApc before the medium is
                        // looked at, so applying it opens nothing, and
                        // mirror screens are `mute_responses`, so this
                        // authoritative Screen is the ONLY thing that
                        // would ever have answered the app.
                        if (kittyQuery(ev.apc.bytes)) self.screen.apply(ev);
                        self.noteKittyDrop(refused);
                    }
                    var mut = ev;
                    mut.deinit(self.allocator);
                    return;
                },
            }
        }
        if (self.ring) |r| switch (fwd) {
            .print => |cp| r.feedCodepoint(cp),
            .print_byte => |b| r.feedBytes(&.{b}),
            .print_run => |run| r.feedBytes(run.bytes[0..run.len]),
            .execute => |b| r.feedControl(b, self.wall_ms),
            else => {},
        };
        if (!self.serialization_failed) {
            self.writer.putEvent(fwd) catch {
                self.serialization_failed = true;
                self.writer.buf.clearRetainingCapacity();
                self.count = 0;
            };
            if (!self.serialization_failed) self.count += 1;
        }
        self.screen.apply(fwd);
        var mut = ev;
        mut.deinit(self.allocator);
    }

    fn deinitMarkers(self: *EventCollector) void {
        for (self.markers.items) |m| self.allocator.free(m.label);
        self.markers.deinit(self.allocator);
    }

    /// True for a kitty graphics APC that names a local path rather
    /// than carrying its pixels (t=f file, t=t tempfile, t=s shm).
    ///
    /// `emit` uses it both to decide what to try to inline and to
    /// decide what must never cross the wire; the set itself is
    /// declared once, in `kitty_image.isFileMedium`.
    pub fn kittyFileMedium(apc_bytes: []const u8) bool {
        const cmd = kitty_image.parse(apc_bytes) catch return false;
        return kitty_image.isFileMedium(cmd.medium);
    }

    /// Explain a dropped image where a user will find it: the FIRST
    /// drop of a session is a warning naming the file, the reason and
    /// the cap; later ones are debug-gated so a stream of them cannot
    /// flood the log. `kitty_drop_warned` lives on the Session because
    /// a collector is per drain.
    fn noteKittyDrop(self: *EventCollector, refused: @import("kitty_inline.zig").Refused) void {
        const first = if (self.kitty_drop_warned) |flag| !flag.* else false;
        if (first) {
            self.kitty_drop_warned.?.* = true;
            log.warn(
                "session '{s}': kitty image dropped, t={c} '{s}': {s} ({d} bytes, inline cap {d}); later drops this session are logged at debug level",
                .{ self.session_name, refused.medium, refused.path(), refused.why.describe(), refused.size, @import("kitty_inline.zig").MAX_RAW_BYTES },
            );
        } else {
            log.debug(
                "session '{s}': kitty image dropped, t={c} '{s}': {s} ({d} bytes)",
                .{ self.session_name, refused.medium, refused.path(), refused.why.describe(), refused.size },
            );
        }
    }

    /// True for a kitty graphics capability probe (`a=q`), which
    /// `Screen.onApc` answers and returns from before it ever looks at
    /// the transmission medium, so a probe is answerable even when
    /// the transmission it names is refused.
    pub fn kittyQuery(apc_bytes: []const u8) bool {
        const cmd = kitty_image.parse(apc_bytes) catch return false;
        return cmd.action == .query;
    }
};

const EventIngestTestHarness = struct {
    allocator: std.mem.Allocator,
    daemon: Daemon,
    pool: Pool,
    screen: *Screen,
    session: Session,
    clients: [2]Client,

    fn init(allocator: std.mem.Allocator) !*EventIngestTestHarness {
        const self = try allocator.create(EventIngestTestHarness);
        errdefer allocator.destroy(self);
        self.allocator = allocator;
        self.pool = try Pool.init(allocator);
        errdefer self.pool.deinit();
        self.screen = try Screen.init(allocator, &self.pool, 80, 4);
        errdefer self.screen.deinit();
        self.session = .{
            .allocator = allocator,
            .name = @constCast("event-ingest-test"),
            .origin_name = @constCast("event-ingest-test"),
            .origin_id = .{'0'} ** SESSION_ORIGIN_ID_LEN,
            .source = .{ .pty = .{ .master_fd = -1, .child_pid = -1 } },
            .parser = Parser.init(allocator),
            .pool = &self.pool,
            .screen = self.screen,
            .log = logring.LogRing.init(allocator),
        };
        self.daemon = .{ .allocator = allocator, .listen_fd = -1, .sock_path = &.{} };
        self.clients = .{
            .{ .allocator = allocator, .fd = -1, .attached = &self.session },
            .{ .allocator = allocator, .fd = -1, .attached = &self.session },
        };
        errdefer {
            self.session.log.deinit();
            self.session.parser.deinit();
        }
        try self.daemon.clients.append(allocator, &self.clients[0]);
        errdefer self.daemon.clients.deinit(allocator);
        try self.daemon.clients.append(allocator, &self.clients[1]);
        return self;
    }

    fn deinit(self: *EventIngestTestHarness) void {
        for (&self.clients) |*cl| {
            cl.rbuf.deinit(self.allocator);
            cl.wbuf.deinit(self.allocator);
            cl.audio_wbuf.deinit(self.allocator);
        }
        self.daemon.clients.deinit(self.allocator);
        self.session.log.deinit();
        self.session.parser.deinit();
        self.screen.deinit();
        self.pool.deinit();
        self.allocator.destroy(self);
    }

    fn clearFrames(self: *EventIngestTestHarness) void {
        for (&self.clients) |*cl| cl.wbuf.clearRetainingCapacity();
    }
};

const EventIngestFrameSummary = struct {
    snapshots: usize = 0,
    events: usize = 0,
};

fn expectSnapshotFrames(
    allocator: std.mem.Allocator,
    cl: *Client,
    expected_seq: u64,
    expected_prefix: []const u8,
) !EventIngestFrameSummary {
    const t = std.testing;
    var summary = EventIngestFrameSummary{};
    var offset: usize = 0;
    while (offset < cl.wbuf.items.len) {
        const peeled = (try wire.peelFrame(cl.wbuf.items[offset..])) orelse return error.TestUnexpectedResult;
        offset += peeled.consumed;
        switch (peeled.frame.ftype) {
            .snapshot => {
                summary.snapshots += 1;
                const envelope = try snapshot.peelEnvelope(peeled.frame.payload);
                try t.expectEqual(expected_seq, envelope.seq);
                var pool = try Pool.init(allocator);
                defer pool.deinit();
                const restored = try snapshot.restore(allocator, &pool, envelope.body);
                defer restored.deinit();
                for (expected_prefix, 0..) |byte, col| {
                    try t.expectEqual(@as(u32, byte), restored.active[0].cells[col].rune);
                }
            },
            .events => summary.events += 1,
            else => {},
        }
    }
    try t.expectEqual(cl.wbuf.items.len, offset);
    return summary;
}

const EventIngestProbe = struct {
    bytes: [128]u8 = undefined,
    len: usize = 0,

    fn apply(self: *EventIngestProbe, ev: Event) void {
        switch (ev) {
            .print => |cp| if (cp <= 0x7f and self.len < self.bytes.len) {
                self.bytes[self.len] = @intCast(cp);
                self.len += 1;
            },
            .print_byte => |byte| if (self.len < self.bytes.len) {
                self.bytes[self.len] = byte;
                self.len += 1;
            },
            .print_run => |run| {
                const n = @min(run.len, self.bytes.len - self.len);
                @memcpy(self.bytes[self.len..][0..n], run.bytes[0..n]);
                self.len += n;
            },
            else => {},
        }
    }
};

fn expectEventFrames(
    allocator: std.mem.Allocator,
    cl: *Client,
    expected_base: u64,
    expected_next: u64,
    expected_bytes: []const u8,
) !EventIngestFrameSummary {
    const t = std.testing;
    var summary = EventIngestFrameSummary{};
    var offset: usize = 0;
    while (offset < cl.wbuf.items.len) {
        const peeled = (try wire.peelFrame(cl.wbuf.items[offset..])) orelse return error.TestUnexpectedResult;
        offset += peeled.consumed;
        switch (peeled.frame.ftype) {
            .snapshot => summary.snapshots += 1,
            .events => {
                summary.events += 1;
                var probe = EventIngestProbe{};
                try t.expectEqual(
                    expected_next,
                    try wire.applyEventFrame(
                        peeled.frame.payload,
                        expected_base,
                        allocator,
                        &probe,
                        EventIngestProbe.apply,
                    ),
                );
                try t.expectEqualStrings(expected_bytes, probe.bytes[0..probe.len]);
            },
            else => {},
        }
    }
    try t.expectEqual(cl.wbuf.items.len, offset);
    return summary;
}

test "event collector serialization failure snapshots every client before later events" {
    const t = std.testing;
    const harness = try EventIngestTestHarness.init(t.allocator);
    defer harness.deinit();

    var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    var failed_batch = harness.daemon.ingestBegin(&harness.session);
    failed_batch.writer.allocator = failing.allocator();
    EventCollector.emit(@ptrCast(&failed_batch), .{ .print = 'A' });
    EventCollector.emit(@ptrCast(&failed_batch), .{ .print = 'B' });
    try t.expect(failing.has_induced_failure);
    try t.expect(failed_batch.serialization_failed);
    try t.expectEqual(@as(u32, 0), failed_batch.count);
    harness.daemon.ingestFinish(&harness.session, &failed_batch, true);

    try t.expectEqual(@as(u64, 0), harness.session.seq);
    for (&harness.clients) |*cl| {
        try t.expect(!cl.needs_resync);
        const summary = try expectSnapshotFrames(t.allocator, cl, 0, "AB");
        try t.expectEqual(@as(usize, 1), summary.snapshots);
        try t.expectEqual(@as(usize, 0), summary.events);
    }

    harness.clearFrames();
    var next_batch = harness.daemon.ingestBegin(&harness.session);
    EventCollector.emit(@ptrCast(&next_batch), .{ .print = 'C' });
    harness.daemon.ingestFinish(&harness.session, &next_batch, true);
    try t.expectEqual(@as(u64, 1), harness.session.seq);
    for (&harness.clients) |*cl| {
        const summary = try expectEventFrames(t.allocator, cl, 0, 1, "C");
        try t.expectEqual(@as(usize, 0), summary.snapshots);
        try t.expectEqual(@as(usize, 1), summary.events);
    }
}

fn runEventsPayloadAllocationFailure(fail_index: ?usize) !usize {
    const t = std.testing;
    const harness = try EventIngestTestHarness.init(t.allocator);
    defer harness.deinit();

    var run: Event.PrintRun = .{};
    run.len = run.bytes.len;
    @memset(&run.bytes, 'x');
    var batch = harness.daemon.ingestBegin(&harness.session);
    EventCollector.emit(@ptrCast(&batch), .{ .print_run = run });

    var config: t.FailingAllocator.Config = .{};
    if (fail_index) |index| config.fail_index = index;
    var failing = t.FailingAllocator.init(t.allocator, config);
    harness.daemon.allocator = failing.allocator();
    harness.daemon.ingestFinish(&harness.session, &batch, true);
    harness.daemon.allocator = t.allocator;
    if (fail_index != null) {
        // Skip the failure backoff; recovery, not its pacing, is under test.
        for (&harness.clients) |*cl| cl.resync_retry_at_ms = 0;
        harness.daemon.retryPendingSnapshots();
    }

    if (fail_index) |_| {
        try t.expect(failing.has_induced_failure);
        try t.expectEqual(@as(u64, 0), harness.session.seq);
        for (&harness.clients) |*cl| {
            const summary = try expectSnapshotFrames(t.allocator, cl, 0, run.bytes[0..run.len]);
            try t.expectEqual(@as(usize, 1), summary.snapshots);
            try t.expectEqual(@as(usize, 0), summary.events);
        }
    } else {
        try t.expect(!failing.has_induced_failure);
        try t.expectEqual(@as(u64, 1), harness.session.seq);
        for (&harness.clients) |*cl| {
            const summary = try expectEventFrames(t.allocator, cl, 0, 1, run.bytes[0..run.len]);
            try t.expectEqual(@as(usize, 0), summary.snapshots);
            try t.expectEqual(@as(usize, 1), summary.events);
        }
    }
    return failing.alloc_index;
}

test "events payload allocation failures snapshot every client" {
    const t = std.testing;
    const allocations = try runEventsPayloadAllocationFailure(null);
    try t.expect(allocations > 0);
    for (0..allocations) |fail_index| {
        _ = try runEventsPayloadAllocationFailure(fail_index);
    }
}

test "list answers every allocation failure instead of dropping the welcome" {
    const t = std.testing;
    const harness = try EventIngestTestHarness.init(t.allocator);
    defer harness.deinit();
    defer harness.daemon.sessions.deinit(t.allocator);
    try harness.daemon.sessions.append(t.allocator, &harness.session);
    const cl = &harness.clients[0];

    // The client is blocked in recvExpect(.welcome), so a reply the
    // daemon never queues is a hang on its side: every allocation the
    // reply path can make must still end in a frame it can read.
    for (0..8) |fail_index| {
        cl.wbuf.clearRetainingCapacity();
        var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = fail_index });
        harness.daemon.allocator = failing.allocator();
        harness.daemon.handleList(cl);
        harness.daemon.allocator = t.allocator;
        const reply = (try wire.peelFrame(cl.wbuf.items)) orelse return error.TestUnexpectedResult;
        try t.expect(reply.frame.ftype == .welcome or reply.frame.ftype == .err);
        try t.expect(!cl.dead);
    }

    cl.wbuf.clearRetainingCapacity();
    harness.daemon.handleList(cl);
    const ok = (try wire.peelFrame(cl.wbuf.items)) orelse return error.TestUnexpectedResult;
    try t.expectEqual(wire.FrameType.welcome, ok.frame.ftype);
    try t.expect(std.mem.indexOf(u8, ok.frame.payload, "event-ingest-test") != null);
}

/// Emit one APC through the collector; `emit` takes ownership of the bytes.
fn emitOwnedApc(batch: *EventCollector, apc: []const u8) !void {
    const owned = try batch.allocator.dupe(u8, apc);
    EventCollector.emit(@ptrCast(batch), .{ .apc = .{ .bytes = owned } });
}

test "kittyFileMedium classifies exactly the path-naming transmission media" {
    const t = std.testing;
    try t.expect(EventCollector.kittyFileMedium("Ga=T,f=100,t=f;L3RtcC94"));
    try t.expect(EventCollector.kittyFileMedium("Ga=T,f=100,t=t;L3RtcC94"));
    try t.expect(EventCollector.kittyFileMedium("Ga=T,f=100,t=s;L3RtcC94"));
    // Chunked first chunk: still names a path, still classified.
    try t.expect(EventCollector.kittyFileMedium("Ga=T,f=100,t=t,m=1;L3Rt"));
    // Direct data, absent `t=` (defaults to d) and non-kitty APCs are not.
    try t.expect(!EventCollector.kittyFileMedium("Ga=T,f=100,t=d;QUJD"));
    try t.expect(!EventCollector.kittyFileMedium("Ga=T,f=100;QUJD"));
    try t.expect(!EventCollector.kittyFileMedium("Xnot-kitty"));
    try t.expect(!EventCollector.kittyFileMedium(""));
}

test "an un-inlinable file-medium kitty APC never reaches the wire" {
    const t = std.testing;
    const harness = try EventIngestTestHarness.init(t.allocator);
    defer harness.deinit();

    // The payloads are base64("/no/such/sketerm-test-file"): a path
    // this host does not have, so kitty_inline.rewrite cannot inline
    // it. Forwarded, the client would resolve it against ITS OWN
    // filesystem and, for t=t, unlink it there.
    var batch = harness.daemon.ingestBegin(&harness.session);
    defer harness.daemon.ingestFinish(&harness.session, &batch, false);
    try emitOwnedApc(&batch, "Ga=T,f=100,t=f;L25vL3N1Y2gvc2tldGVybS10ZXN0LWZpbGU=");
    try emitOwnedApc(&batch, "Ga=T,f=100,t=t;L25vL3N1Y2gvc2tldGVybS10ZXN0LWZpbGU=");
    try emitOwnedApc(&batch, "Ga=T,f=100,t=s;L25vL3N1Y2gvc2tldGVybS10ZXN0LWZpbGU=");
    // A chunked t=t is what `rewrite` refuses outright.
    try emitOwnedApc(&batch, "Ga=T,f=100,t=t,m=1;L25vL3N1Y2gv");
    try t.expectEqual(@as(u32, 0), batch.count);
    try t.expectEqual(@as(usize, 0), batch.writer.buf.items.len);

    // A non-kitty APC still passes through untouched.
    try emitOwnedApc(&batch, "Xhello");
    try t.expectEqual(@as(u32, 1), batch.count);
}

const WritePtyProbe = struct {
    buf: [128]u8 = undefined,
    len: usize = 0,

    fn write(ctx: ?*anyopaque, bytes: []const u8) void {
        const self: *WritePtyProbe = @ptrCast(@alignCast(ctx.?));
        const n = @min(bytes.len, self.buf.len - self.len);
        @memcpy(self.buf[self.len..][0..n], bytes[0..n]);
        self.len += n;
    }
};

test "a refused file-medium kitty query is still answered by the daemon screen" {
    const t = std.testing;
    const harness = try EventIngestTestHarness.init(t.allocator);
    defer harness.deinit();
    var probe = WritePtyProbe{};
    harness.screen.sink = .{ .ctx = &probe, .on_write_pty = WritePtyProbe.write };

    var batch = harness.daemon.ingestBegin(&harness.session);
    defer harness.daemon.ingestFinish(&harness.session, &batch, false);
    // `a=q` probing t=f support, naming a path this host lacks. The
    // transmission is refused for the wire, but the mirror screens are
    // mute_responses, so dropping the answer too would hang the app.
    try emitOwnedApc(&batch, "Ga=q,i=31,t=f,f=100;L25vL3N1Y2gvc2tldGVybS10ZXN0LWZpbGU=");
    try t.expectEqual(@as(u32, 0), batch.count);
    try t.expectEqualStrings("\x1b_Gi=31;OK\x1b\\", probe.buf[0..probe.len]);
}

test "untrusted ingestion drops file-medium kitty APCs without reading the file" {
    const t = std.testing;
    const harness = try EventIngestTestHarness.init(t.allocator);
    defer harness.deinit();

    // A real, readable file: an untrusted batch must neither inline it
    // nor (for t=t) delete it.
    // The name carries the spec marker, so a trusted read WOULD delete
    // it: the file surviving proves the untrusted gate, not the marker.
    var tmpl = "/tmp/sketerm-untrusted-tty-graphics-protocol-XXXXXX".*;
    const fd = c.mkstemp(&tmpl);
    try t.expect(fd >= 0);
    try t.expectEqual(@as(isize, 7), c.write(fd, "PNGDATA", 7));
    _ = c.close(fd);
    defer _ = c.unlink(@ptrCast(&tmpl));
    const path = std.mem.sliceTo(&tmpl, 0);

    const path_b64 = try @import("../util/b64.zig").encodeAlloc(t.allocator, path);
    defer t.allocator.free(path_b64);
    const apc = try std.fmt.allocPrint(t.allocator, "Ga=T,f=100,t=t;{s}", .{path_b64});
    defer t.allocator.free(apc);

    var batch = harness.daemon.ingestBegin(&harness.session);
    batch.untrusted = true;
    defer harness.daemon.ingestFinish(&harness.session, &batch, false);
    try emitOwnedApc(&batch, apc);
    try t.expectEqual(@as(u32, 0), batch.count);
    // Untrusted content never reached the filesystem: the file lives.
    try t.expectEqual(@as(c_int, 0), c.access(@ptrCast(&tmpl), c.F_OK));
}

test "one client frame allocation failure snapshots only that client" {
    const t = std.testing;
    const harness = try EventIngestTestHarness.init(t.allocator);
    defer harness.deinit();

    var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    try harness.clients[0].wbuf.ensureTotalCapacityPrecise(t.allocator, 5);
    harness.clients[0].allocator = failing.allocator();
    var run: Event.PrintRun = .{};
    run.len = run.bytes.len;
    @memset(&run.bytes, 'y');
    var batch = harness.daemon.ingestBegin(&harness.session);
    EventCollector.emit(@ptrCast(&batch), .{ .print_run = run });
    harness.daemon.ingestFinish(&harness.session, &batch, true);
    harness.clients[0].allocator = t.allocator;
    // Skip the failure backoff; recovery, not its pacing, is under test.
    harness.clients[0].resync_retry_at_ms = 0;
    harness.daemon.retryPendingSnapshots();

    try t.expect(failing.has_induced_failure);
    try t.expectEqual(@as(u64, 1), harness.session.seq);
    const recovered = try expectSnapshotFrames(t.allocator, &harness.clients[0], 1, run.bytes[0..run.len]);
    try t.expectEqual(@as(usize, 1), recovered.snapshots);
    try t.expectEqual(@as(usize, 0), recovered.events);
    const streamed = try expectEventFrames(t.allocator, &harness.clients[1], 0, 1, run.bytes[0..run.len]);
    try t.expectEqual(@as(usize, 0), streamed.snapshots);
    try t.expectEqual(@as(usize, 1), streamed.events);

    harness.clearFrames();
    var next_batch = harness.daemon.ingestBegin(&harness.session);
    EventCollector.emit(@ptrCast(&next_batch), .{ .print = 'Z' });
    harness.daemon.ingestFinish(&harness.session, &next_batch, true);
    try t.expectEqual(@as(u64, 2), harness.session.seq);
    for (&harness.clients) |*cl| {
        const summary = try expectEventFrames(t.allocator, cl, 1, 2, "Z");
        try t.expectEqual(@as(usize, 0), summary.snapshots);
        try t.expectEqual(@as(usize, 1), summary.events);
    }
}

/// Fails every allocation, unlike `std.testing.FailingAllocator`, which
/// fails exactly one index. A snapshot that can NEVER be produced is the
/// state that used to freeze a client forever.
const AlwaysOom = struct {
    fn alloc(_: *anyopaque, _: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
        return null;
    }
    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }
    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }
    fn free(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {}
    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };
    fn allocator() std.mem.Allocator {
        return .{ .ptr = undefined, .vtable = &vtable };
    }
};

fn countFrames(cl: *Client, ftype: wire.FrameType) !usize {
    var found: usize = 0;
    var offset: usize = 0;
    while (offset < cl.wbuf.items.len) {
        const peeled = (try wire.peelFrame(cl.wbuf.items[offset..])) orelse return error.TestUnexpectedResult;
        offset += peeled.consumed;
        if (peeled.frame.ftype == ftype) found += 1;
    }
    return found;
}

test "a snapshot that never succeeds tells the client instead of freezing it" {
    const t = std.testing;
    const harness = try EventIngestTestHarness.init(t.allocator);
    defer harness.deinit();

    const cl = &harness.clients[0];
    harness.daemon.allocator = AlwaysOom.allocator();
    var attempt: usize = 0;
    while (attempt < Client.MAX_RESYNC_ATTEMPTS) : (attempt += 1) {
        // Skip the backoff wall clock; the budget is what is under test.
        cl.resync_retry_at_ms = 0;
        harness.daemon.queueSnapshot(cl, &harness.session);
        try t.expect(cl.needs_resync);
    }
    harness.daemon.allocator = t.allocator;

    // Told, not frozen: the budget ran out and the client holds an .err.
    try t.expect(cl.resync_gave_up);
    try t.expectEqual(@as(usize, 0), try countFrames(cl, .snapshot));
    try t.expectEqual(@as(usize, 1), try countFrames(cl, .err));

    // Retrying stops, and the connection drops once the notice drains so
    // the client's own reconnect starts from a fresh snapshot.
    try t.expect(!cl.dead);
    harness.daemon.retryPendingSnapshots();
    try t.expect(!cl.dead);
    cl.wbuf.clearRetainingCapacity();
    harness.daemon.retryPendingSnapshots();
    try t.expect(cl.dead);
}

test "resync retries back off instead of re-serializing every tick" {
    const t = std.testing;
    const harness = try EventIngestTestHarness.init(t.allocator);
    defer harness.deinit();

    const cl = &harness.clients[0];
    harness.daemon.allocator = AlwaysOom.allocator();
    harness.daemon.queueSnapshot(cl, &harness.session);
    harness.daemon.allocator = t.allocator;
    try t.expectEqual(@as(u8, 1), cl.resync_attempts);
    try t.expect(cl.resync_retry_at_ms > nowMs());

    // A tick inside the backoff window must not re-serialize the grid.
    harness.daemon.retryPendingSnapshots();
    try t.expectEqual(@as(u8, 1), cl.resync_attempts);
    try t.expectEqual(@as(usize, 0), try countFrames(cl, .snapshot));

    // Once due, the retry runs and a success clears the budget.
    cl.resync_retry_at_ms = 0;
    harness.daemon.retryPendingSnapshots();
    try t.expect(!cl.needs_resync);
    try t.expectEqual(@as(u8, 0), cl.resync_attempts);
    try t.expectEqual(@as(usize, 1), try countFrames(cl, .snapshot));
}

pub const defaultSocketPath = @import("sockpath.zig").defaultSocketPath;
