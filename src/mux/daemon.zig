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
const wlproto = @import("../wlhost/protocol.zig");
const wlpipe = @import("../wlhost/pipe.zig");
const icons = @import("icons.zig");
const wlpixcodec = @import("../wlhost/pixcodec.zig");
const wlcomp = @import("../wlhost/compositor.zig");
const wlkeymaps = @import("../wlhost/keymaps.zig");
const a11yhub = @import("a11yhub.zig");
const cast_rec = @import("cast.zig");
const logring = @import("logring.zig");
const fsserve = @import("fsserve.zig");
const fsjournal = @import("fsjournal.zig");
const build_options = @import("build_options");
const version = @import("../version.zig");
const wlvcodec = @import("../wlhost/vcodec.zig");
const churnmod = @import("../util/churn.zig");
const contentmod = @import("../util/content.zig");
const wsproto = @import("../winstream/proto.zig");
const wssource = @import("../winstream/source.zig");
const WsSource = wssource.Source;
const snapshot = @import("snapshot.zig");
const shell_util = @import("shell.zig");
const platform = @import("../util/platform.zig");
const Pty = @import("../pty.zig").Pty;
const Parser = @import("../parser/vt.zig").Parser;
const Event = @import("../parser/event.zig").Event;
const Screen = @import("../grid/screen.zig").Screen;
const Pool = @import("../grid/style_pool.zig").Pool;

/// Wall-clock epoch milliseconds — ONLY for log-line timestamps that a
/// client renders as "how long ago"; everything scheduling-related
/// stays on the monotonic clock below.
pub fn wallMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_REALTIME, &ts);
    return @as(i64, ts.tv_sec) * 1000 + @divTrunc(ts.tv_nsec, 1_000_000);
}

/// Monotonic milliseconds — the daemon's own clock. Idle durations are
/// computed daemon-side (never as a client-vs-daemon timestamp diff) so a
/// remote client whose clock differs still sees the right age.
pub fn nowMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @intCast(ts.tv_sec * 1000 + @divTrunc(ts.tv_nsec, 1_000_000));
}

/// The working directory of a session's child via `/proc/<pid>/cwd`. The
/// daemon owns the PID, so this is authoritative even when the shell never
/// emits OSC 7 — clients (which have no local pid for a daemon-backed pane)
/// rely on it for `list` and layout-save. Writes into `buf`, returns the
/// slice or null. Linux-only; harmless elsewhere (readlink fails → null).
pub fn cwdOfPid(pid: c.pid_t, buf: []u8) ?[]const u8 {
    if (pid <= 0) return null;
    var path_buf: [64]u8 = undefined;
    const link = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/cwd", .{pid}) catch return null;
    const n = c.readlink(link.ptr, buf.ptr, buf.len);
    if (n <= 0) return null;
    return buf[0..@intCast(n)];
}

pub const SpawnReq = struct {
    name: []const u8 = "",
    argv: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
    /// Extra child environment, "KEY=VALUE" strings applied after the
    /// daemon's own exports (so they win).
    env: []const []const u8 = &.{},
    rows: u16 = 24,
    cols: u16 = 80,
    /// One-shot forwarded GUI app (`sketerm app -u`), not an
    /// interactive shell — listed differently by clients.
    app: bool = false,
    /// Force the window-stream backend for this session (the
    /// explicit form of SKETERM_WINSTREAM; what `sketerm app`
    /// toward capture-only remotes will set).
    winstream: bool = false,
    /// Run the session under a private XDG_RUNTIME_DIR with the shared
    /// D-Bus session bus dropped (`sketerm app -i`). Isolates
    /// single-instance apps so each forwarded copy renders on its own
    /// client instead of coalescing into the first one.
    isolated: bool = false,
    /// GPU rendering for this session (`sketerm app --gpu`): skip the
    /// LIBGL_ALWAYS_SOFTWARE force and announce linux-dmabuf on the
    /// session's compositor. LINEAR buffers use mmap; modifier-backed
    /// buffers use runtime-loaded EGL/GLES when available.
    gpu: bool = false,
    /// Skip this session's PulseAudio hub (`launch_app audio:"none"`):
    /// PULSE_SERVER stays unset, so clients fall back to their own
    /// null/dummy audio drivers instead of sketerm's sink.
    no_audio: bool = false,
    /// Capture the session's audio to WAV on the DAEMON's host
    /// (`launch_app audio_path`): path base — the first stream lands
    /// at "<base>.wav", later ones at "<base>-N.wav". The sink still
    /// paces/forwards normally; this only tees the PCM. "" = off.
    audio_capture: []const u8 = "",
    /// GUI pane id + IPC socket to export into the child env as
    /// SKETERM_PANE_ID / SKETERM_SOCKET so `sketerm cli --pane self` works
    /// from inside a daemon-backed pane. The GUI passes its own values; they
    /// reflect the spawning client (may go stale after a cross-GUI reattach —
    /// acceptable for the common case). 0 / "" = don't export.
    pane_id: u32 = 0,
    socket: []const u8 = "",
    /// Child TERM / COLORTERM. Empty → Pty.spawn defaults. The GUI passes its
    /// profile's term_env/color_term_env so a daemon-backed local pane gets
    /// the same environment an in-process pane would.
    term: []const u8 = "",
    color_term: []const u8 = "",
    /// xkb layout for forwarded-app keyboards (wlhost/keymaps.zig
    /// names; "" = us). Must match whoever drives the seat.
    kb_layout: []const u8 = "",
    /// Spawn argv[0] as a login shell (leading `-`).
    login_shell: bool = false,
    /// GUI-owned LOCAL session sharing the user's desktop: skip the
    /// wlhost Wayland hub so child GUI apps talk to the real desktop
    /// compositor directly (via `host_wayland_display`) instead of
    /// sketerm's embedded one. Remote/durable sessions leave this
    /// false and get the forwarding hub (which roams with the
    /// session). Only the local ephemeral pane factory sets it.
    local: bool = false,
    /// The GUI's own $WAYLAND_DISPLAY, applied to the child when
    /// `local` is set — the daemon's inherited value may be stale
    /// (it outlives the GUI that started it) or absent. Empty leaves
    /// the child to inherit the daemon's env (X11 / no Wayland).
    host_wayland_display: []const u8 = "",
    /// Auto shell-integration (OSC 7/133 without rc edits). All paths are on
    /// the daemon host; the GUI only fills this for the LOCAL daemon, where
    /// the integration scripts exist. null = off.
    shell_integration: ?SpawnShellIntegration = null,
    /// External display session (`sketerm-mux display create`): the
    /// child is a trivial keeper process (this daemon's own binary,
    /// `--keep`) that just blocks, so the session exists purely to own
    /// a Wayland/PulseAudio hub some OUTSIDE process renders into. The
    /// daemon builds the keeper argv itself — a client cannot know the
    /// daemon host's binary path, and a version mismatch would be a
    /// silent instant exit. Any argv the client sent is ignored.
    display: bool = false,
    /// Seconds with NO attached viewer after which the daemon kills
    /// this session (counted from creation while it has never been
    /// attached). 0 = live forever, the historical behaviour.
    ttl_secs: u32 = 0,
};

pub const SpawnShellIntegration = struct {
    kind: []const u8 = "", // "zsh" | "fish" | "bash"
    script: []const u8 = "",
    shim_dir: []const u8 = "",
};

pub const AttachReq = struct {
    name: []const u8 = "",
    /// Client self-identification for the peer roster: "gui", "cli",
    /// "mcp" (headless assistant driver) or "" (unknown).
    kind: []const u8 = "",
    /// Never drive the session's Wayland seat: this viewer stays out of
    /// the controller lease entirely (it neither acquires a free lease
    /// nor is eligible for the controller-death handover).
    read_only: bool = false,
    /// Force the controller lease on attach, evicting whoever holds it.
    /// Without this an attach only acquires a FREE lease.
    control: bool = false,
};

/// `control_req` payload. Unknown ops are ignored (append-only).
pub const ControlReq = struct {
    op: []const u8 = "",
};

/// `log_get` request. Exactly one selector applies, in this order:
/// `id` (one line, full bytes) > `from_id` (up to 500 lines from that
/// id) > `tail` (last N lines). `max_chars` bounds each line in the
/// reply (0 = full stored bytes).
pub const LogGetReq = struct {
    tail: u32 = 100,
    from_id: u64 = 0,
    id: u64 = 0,
    max_chars: u32 = 300,
    /// Echoed in the reply header (when nonzero) so a client can match
    /// replies to requests — a reply buried behind a frame backlog can
    /// surface during a LATER request's wait.
    nonce: u64 = 0,
};

pub const RenameReq = struct {
    name: []const u8 = "",
    new_name: []const u8 = "",
};

pub const SessionInfo = struct {
    name: []const u8,
    rows: u16,
    cols: u16,
    clients: u32,
    exited: bool,
    title: []const u8 = "",
    app: bool = false,
    /// Milliseconds since this session last produced output, computed on the
    /// daemon's own clock at list time (never a client-vs-daemon timestamp
    /// diff — a remote daemon's monotonic clock differs from the caller's).
    idle_ms: i64 = 0,
    /// Child's current working directory (from /proc, daemon-resolved). Empty
    /// if unavailable. Lets `list` show it and gives layout-save a cwd source
    /// for daemon-backed panes (which have no local pid).
    cwd: []const u8 = "",
    /// The session child's pid ON THE DAEMON'S HOST (0 = unknown). For a
    /// string-command spawn this is the wrapping `/bin/sh`, not the app.
    pid: i32 = 0,
    /// External display session (`display create`) — its child is the
    /// keeper, so the "terminal" is meaningless; what matters is the
    /// environment below.
    display: bool = false,
    /// Absolute path of the session's Wayland display socket, its
    /// PULSE_SERVER value and its private runtime dir (empty = none).
    /// An external renderer needs these and must never guess them.
    wl_display: []const u8 = "",
    pulse_server: []const u8 = "",
    runtime_dir: []const u8 = "",
    /// No-viewer TTL in seconds (0 = none).
    ttl_secs: u32 = 0,
    /// Attached viewers, and a label for the one holding the controller
    /// lease ("" = nobody). The label is "<kind>#<client id>" — stable
    /// for the life of the connection, meaningless across daemons.
    viewers: u32 = 0,
    controller: []const u8 = "",
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    name: []u8,
    pty: Pty,
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
    exited: bool = false,
    exit_status: i32 = 0,
    /// Spawned via `sketerm app -u` — a forwarded GUI app, not a shell.
    app: bool = false,
    /// External display session: the child is the `--keep` keeper and
    /// the session exists to own the Wayland/audio hubs for a process
    /// sketerm never spawned.
    display: bool = false,
    /// No-viewer TTL (ms, 0 = none) and the monotonic stamp since when
    /// this session has had no attached viewer (0 = one is attached
    /// right now). Seeded at spawn so a session nobody ever attaches to
    /// still expires.
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
    cast: ?cast_rec.Rec = null,
    /// Indexed escape-free log of the child's output (log_get / MCP
    /// app_log): one monotonically-increasing id per line, bounded.
    log: logring.LogRing,
    pub fn deinit(self: *Session) void {
        self.log.deinit();
        if (self.cast) |*rec| rec.finish();
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
            removeTreeBestEffort(p);
            self.allocator.free(p);
        }
        if (self.a11y) |*h| h.deinit();
        if (self.pty.closeAndReap()) |code| self.exit_status = code;
        self.parser.deinit();
        self.screen.deinit();
        self.pool.deinit();
        self.allocator.destroy(self.pool);
        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }

    /// Screen sink: DSR/DA replies go straight back to the child.
    pub fn sinkWritePty(ctx: ?*anyopaque, bytes: []const u8) void {
        const self: *Session = @ptrCast(@alignCast(ctx.?));
        _ = self.pty.writeAll(bytes);
    }
};

/// Broker-side record of a forked session worker. The broker holds no Screen;
/// it tracks just enough to route clients (control_fd), answer `list` (cached
/// metadata pushed by the worker, filled in B3), and reap (pid + dead).
pub const Worker = struct {
    allocator: std.mem.Allocator,
    name: []u8,
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
    ttl_secs: u32 = 0,
    viewers: u32 = 0,
    /// Owned copies of the worker's last-pushed title / cwd (null = none yet).
    title: ?[]u8 = null,
    cwd: ?[]u8 = null,
    /// Owned session environment paths, learned from the 'Y' ready
    /// datagram (the broker never creates these — the worker owns the
    /// hubs) and refreshed by 'M' pushes so `list` can serve them.
    wl_display: ?[]u8 = null,
    pulse_server: ?[]u8 = null,
    runtime_dir: ?[]u8 = null,
    /// Controller label pushed by the worker ("" / null = nobody).
    controller: ?[]u8 = null,
    /// The worker's reported spawn-failure reason ('E' control datagram,
    /// sent just before it dies), surfaced in the deferred `.err` reply.
    spawn_err: ?[]u8 = null,

    pub fn deinit(self: *Worker) void {
        if (self.control_fd >= 0) _ = c.close(self.control_fd);
        self.allocator.free(self.name);
        if (self.title) |t| self.allocator.free(t);
        if (self.cwd) |cw| self.allocator.free(cw);
        if (self.spawn_err) |e| self.allocator.free(e);
        if (self.wl_display) |p| self.allocator.free(p);
        if (self.pulse_server) |p| self.allocator.free(p);
        if (self.runtime_dir) |p| self.allocator.free(p);
        if (self.controller) |p| self.allocator.free(p);
        self.allocator.destroy(self);
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
};

/// Worker→broker 'Y' ready datagram (JSON). Older workers sent a bare
/// decimal pid; `parseWorkerReady` accepts both.
pub const WorkerReady = struct {
    pid: i32 = 0,
    wl: []const u8 = "",
    pa: []const u8 = "",
    rt: []const u8 = "",
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
    ttl_secs: u32 = 0,
    viewers: u32 = 0,
    controller: []const u8 = "",
    wl: []const u8 = "",
    pa: []const u8 = "",
    rt: []const u8 = "",
};

/// Worker-side throttle state for metadata pushes. Structural changes (client
/// count, size, exit, title) push immediately; bare activity advances are
/// rate-limited (the broker derives idle_ms from `activity` against its own
/// clock, so a small lag costs nothing).
pub const WorkerPush = struct {
    inited: bool = false,
    clients: u32 = 0,
    exited: bool = false,
    rows: u16 = 0,
    cols: u16 = 0,
    title_hash: u64 = 0,
    controller_hash: u64 = 0,
    activity: i64 = 0,
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
    attached: ?*Session = null,
    dead: bool = false,
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
    /// Native app-channel units were withheld because this MCP
    /// client's wbuf exceeded NATIVE_BACKLOG (it drains only during
    /// tool calls; streaming into the queue meanwhile is unbounded —
    /// AND the client would spend whole tool calls chewing stale
    /// frames instead of seeing "now"). A `native_gap` frame marks
    /// the pause; once the wbuf fully drains, replayNativeChannels
    /// rebuilds its replicas from the live mirrors and `native_sync`
    /// closes the replay.
    needs_native_resync: bool = false,

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
        if (self.dead) return;
        wire.appendFrame(out, self.allocator, ftype, payload) catch {
            self.dead = true;
            return;
        };
        if (self.queuedBytes() > MAX_WBUF) self.dead = true;
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

const pathZ = @import("../util/pathz.zig").pathZ;

/// Recursively remove `path` and everything under it, best-effort:
/// every failure is ignored (the dir lives on a tmpfs runtime dir that
/// the OS reclaims at logout anyway). Used to tear down an isolated
/// session's private XDG_RUNTIME_DIR, which apps fill with sockets and
/// the odd subdir (dbus-1/, pulse/) we don't track individually.
pub fn removeTreeBestEffort(path: []const u8) void {
    var z_buf: [4096]u8 = undefined;
    const zpath = pathZ(&z_buf, path) catch return;
    if (c.opendir(zpath)) |dir| {
        while (c.readdir(dir)) |ent| {
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            var child_buf: [4096]u8 = undefined;
            const child = std.fmt.bufPrintZ(&child_buf, "{s}/{s}", .{ path, name }) catch continue;
            // unlinkat fails on a directory (EISDIR/EPERM) → recurse,
            // then drop the now-empty dir with AT_REMOVEDIR.
            if (c.unlinkat(c.AT_FDCWD, child.ptr, 0) != 0) {
                removeTreeBestEffort(child);
                _ = c.unlinkat(c.AT_FDCWD, child.ptr, c.AT_REMOVEDIR);
            }
        }
        _ = c.closedir(dir);
    }
    _ = c.rmdir(zpath);
}

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
    /// socket bytes, strictly 1:1 with `client`.
    tcp: bool = false,
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
    /// pool id → mmapped mirror of the CURRENT incarnation under that
    /// id. Mirrors outlive wl_shm_pool destructors: existing buffers
    /// keep referencing the memory.
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
    /// Set once the attached client advertises it can decode the video
    /// codec (capability negotiation — not yet implemented). Until then
    /// videoCommit stays dormant: never emit a tile no client can decode.
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

    const PasteFd = struct {
        offer: u32,
        fd: c_int,
    };

    const PoolMirror = struct {
        fd: c_int,
        ptr: [*]u8,
        size: usize,
        /// Live wl_buffers created from this pool. The mmap (and the
        /// tmpfs pages it pins via the open fd) is reclaimed only when
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
        self.tracker.deinit();
        self.allocator.destroy(self);
    }

    /// Lossy-video routing for a commit (build_options.video only). Feeds
    /// per-surface churn; when the surface is HOT and looks photographic,
    /// encodes the WHOLE surface as one H.264 tile and emits a pool_vtile,
    /// returning true so the caller skips the lossless path. Any failure
    /// (odd dims, encoder open, mirror too small) returns false → lossless.
    fn videoCommit(nv: *Native, units: *std.ArrayList(u8), a: std.mem.Allocator, cm: anytype, mirror: PoolMirror, y0: i64, y1: i64) !bool {
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

/// Bind + listen on a fresh Unix socket. Shared with client.zig's
/// connect for the sockaddr_un fill.
pub fn fillSockaddrUn(addr: *c.struct_sockaddr_un, path: []const u8) error{BadPath}!void {
    addr.* = std.mem.zeroes(c.struct_sockaddr_un);
    addr.sun_family = c.AF_UNIX;
    if (path.len >= addr.sun_path.len) return error.BadPath;
    @memcpy(addr.sun_path[0..path.len], path);
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

    pub fn deinit(self: *FsView) void {
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
pub const FsJob = struct {
    pub const Op = enum { copy, delete_tree, hash, find, grep, extract, archive_create, archive_list, archive_extract, trash, trash_restore, cross_copy, panelize, live_find, thumbnail, preview, dir_size, perm_tree, media_meta };
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
    /// panelize: output lines that named nothing on disk, and the
    /// command's own exit status (-1 = it died on a signal). A nonzero
    /// status is reported, not treated as a failed job.
    rejected: u64 = 0,
    exit_status: i64 = 0,
    /// Entry the helper is working on RIGHT NOW, and how far through
    /// its entry count it is. The helper puts the path on the wire
    /// only when it changes, so this is sticky between updates.
    cur_file: [512]u8 = undefined,
    cur_file_len: usize = 0,
    files_done: u64 = 0,
    files_total: u64 = 0,
    /// Result paths from the DONE event (trash location + info file,
    /// extracted member path) — forwarded to the owner.
    done_path: [4096]u8 = undefined,
    done_path_len: usize = 0,
    done_text: [4096]u8 = undefined,
    done_text_len: usize = 0,
    src: []u8,
    dst: []u8,
    pattern: []u8,
    src_host: []u8,
    dst_host: []u8,
    client_token: []u8,
    /// copy: the per-entry collision policy this job was started with,
    /// kept so a restart after a daemon crash resumes with the SAME
    /// semantics rather than silently overwriting.
    conflict: []u8,
    acknowledged: bool = false,
    ack_req: u32 = 0,
    terminal_pending: bool = false,
    resumable: bool = false,
    /// Short-lived client-owned helper: no journal/history and killed
    /// when its requesting client disappears.
    ephemeral: bool = false,

    pub fn deinit(self: *FsJob, kill_child: bool) void {
        if (kill_child and self.out_fd >= 0 and self.pid > 0) {
            _ = c.kill(-self.pid, c.SIGKILL);
            var st: c_int = 0;
            _ = c.waitpid(self.pid, &st, 0);
        }
        if (self.out_fd >= 0) _ = c.close(self.out_fd);
        self.lbuf.deinit(self.allocator);
        self.allocator.free(self.src);
        self.allocator.free(self.dst);
        self.allocator.free(self.pattern);
        self.allocator.free(self.src_host);
        self.allocator.free(self.dst_host);
        self.allocator.free(self.client_token);
        self.allocator.free(self.conflict);
        self.allocator.destroy(self);
    }

    pub fn setMessage(self: *FsJob, msg: []const u8) void {
        const n = @min(msg.len, self.message.len);
        @memcpy(self.message[0..n], msg[0..n]);
        self.message_len = n;
    }

    pub fn finished(self: *const FsJob) bool {
        return self.state == .done or self.state == .failed or self.state == .canceled;
    }
};

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
    /// In-flight file uploads (file_* frames), keyed by (client, xfer).
    uploads: std.ArrayList(*Upload) = .empty,
    /// In-flight file downloads (file_get), keyed by (client, xfer).
    downloads: std.ArrayList(*Download) = .empty,
    /// Open fs directory views (fs_op open_view), keyed by (client,
    /// client-chosen view id). Views die with their client.
    fs_views: std.ArrayList(*FsView) = .empty,
    /// Shared inotify fd backing every view (lazy; -1 until the first
    /// open_view, and permanently -1 where inotify doesn't exist).
    fs_watch: fsserve.Watcher = .{},
    /// Subprocess file jobs (copy/delete_tree/hash). Daemon-owned:
    /// they SURVIVE the requesting client (durability) — a dead owner
    /// only stops the event stream, never the work.
    fs_jobs: std.ArrayList(*FsJob) = .empty,
    next_fs_job_id: u64 = 1,
    /// Atomic job records live beside the daemon socket and survive a
    /// daemon restart independently of any GUI client.
    fs_job_dir: []u8 = &.{},
    fs_jobs_restored: bool = false,
    next_chan_id: u32 = 1,
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
    /// Worker only: last metadata signature pushed to the broker, so
    /// `maybePushMeta` only sends on a real change (and throttles activity).
    wpush: WorkerPush = .{},
    /// Worker only: runtime dir (owned) for the session's Wayland display /
    /// isolated rt sockets. A worker has no listen socket, so it can't derive
    /// the dir from `sock_path` ("") the way the monolith/broker does — the
    /// broker hands it the dir at fork time. null in monolith/broker.
    base_dir: ?[]u8 = null,
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

    pub fn init(allocator: std.mem.Allocator, sock_path: []const u8) !*Daemon {
        const dir_end = std.mem.lastIndexOfScalar(u8, sock_path, '/') orelse return error.BadPath;
        // mkdir -p the parent (one level is enough in practice:
        // $XDG_RUNTIME_DIR exists; we create the sketerm dir).
        var z_buf: [4096]u8 = undefined;
        _ = c.mkdir(try pathZ(&z_buf, sock_path[0..dir_end]), 0o700);

        // Serialize stale-socket recovery. Without this lock, two starters can
        // both observe the same stale inode and one can unlink the other's new
        // listener between its bind and listen calls.
        var lock_buf: [4096:0]u8 = undefined;
        const lock_path = std.fmt.bufPrintZ(&lock_buf, "{s}.lock", .{sock_path}) catch return error.BadPath;
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
        try fillSockaddrUn(&addr, sock_path);
        bindSocket(fd, &addr) catch |err| switch (err) {
            error.AlreadyRunning => switch (socketPathState(sock_path)) {
                .live, .unknown => return error.AlreadyRunning,
                .stale => {
                    var st: c.struct_stat = undefined;
                    const path = try pathZ(&z_buf, sock_path);
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
        if (c.lstat(try pathZ(&z_buf, sock_path), &bound_st) != 0) return error.StatFailed;

        const self = try allocator.create(Daemon);
        const job_dir = try std.fmt.allocPrint(allocator, "{s}/fsjobs", .{sock_path[0..dir_end]});
        self.* = .{
            .allocator = allocator,
            .listen_fd = fd,
            .sock_path = try allocator.dupe(u8, sock_path),
            .sock_dev = @intCast(bound_st.st_dev),
            .sock_ino = @intCast(bound_st.st_ino),
            .fs_job_dir = job_dir,
        };
        _ = fsjournal.ensureDir(job_dir);
        return self;
    }

    pub fn deinit(self: *Daemon) void {
        for (self.fs_jobs.items) |j| j.deinit(true);
        self.fs_jobs.deinit(self.allocator);
        for (self.fs_views.items) |v| v.deinit();
        self.fs_views.deinit(self.allocator);
        self.fs_watch.deinit();
        for (self.uploads.items) |u| u.deinit();
        self.uploads.deinit(self.allocator);
        for (self.downloads.items) |dl| dl.deinit();
        self.downloads.deinit(self.allocator);
        for (self.channels.items) |ch| ch.deinit();
        self.channels.deinit(self.allocator);
        if (self.dmabuf_importer) |*importer| importer.deinit();
        self.dmabuf_capabilities.deinit(self.allocator);
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
        const poll_timeout = self.pulseTick(timeout_ms);
        var fds: std.ArrayList(c.struct_pollfd) = .empty;
        defer fds.deinit(self.allocator);

        try fds.append(self.allocator, .{ .fd = self.listen_fd, .events = c.POLLIN, .revents = 0 });
        // Worker: the broker↔worker control channel (passed client fds + kill/
        // rename/metadata). -1 in broker/monolith → ignored by poll.
        const control_idx = fds.items.len;
        try fds.append(self.allocator, .{ .fd = self.control_fd, .events = c.POLLIN, .revents = 0 });
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
            try fds.append(self.allocator, .{
                .fd = if (s.exited) -1 else s.pty.master_fd,
                .events = c.POLLIN,
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

        const pr = c.poll(fds.items.ptr, @intCast(fds.items.len), poll_timeout);
        if (pr < 0) return; // EINTR etc — next tick retries

        if (self.listen_fd >= 0 and fds.items[0].revents & c.POLLIN != 0) self.acceptClient();
        if (self.control_fd >= 0 and fds.items[control_idx].revents & (c.POLLIN | c.POLLHUP | c.POLLERR) != 0)
            self.workerOnControl();
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
        }

        i = 0;
        while (i < n_sessions) : (i += 1) {
            const s = self.sessions.items[i];
            if (fds.items[hub_base + i].revents & c.POLLIN != 0) self.acceptWaylandApp(s);
            if (fds.items[pa_base + i].revents & c.POLLIN != 0) self.acceptAudioApp(s);
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
            while (j < nv.clip_reads.items.len and clip_base + clip_idx < fds.items.len) {
                const re = fds.items[clip_base + clip_idx].revents;
                clip_idx += 1;
                if (re & (c.POLLIN | c.POLLHUP) != 0 and !ch.dead) {
                    if (self.clipReadable(ch, j)) continue; // removed; j stays
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

        self.pumpWinstreams();
        self.pumpDownloads();
        // Worker: tell the broker our latest metadata (throttled).
        if (self.control_fd >= 0 and !self.is_broker) self.maybePushMeta();
        self.refreshDetachedFsJobs();
        self.reap();
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
    const applyWorkerReady = daemon_serve.applyWorkerReady;
    const replyPendingSpawn = daemon_serve.replyPendingSpawn;
    const maybePushMeta = daemon_serve.maybePushMeta;
    const controlRecv = daemon_serve.controlRecv;
    const controlSend = daemon_serve.controlSend;
    const clientReadable = daemon_serve.clientReadable;
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
    const fsSendListing = daemon_serve.fsSendListing;
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
    const fsJobEmit = daemon_fsjobs.fsJobEmit;
    const fsJobReadable = daemon_fsjobs.fsJobReadable;
    const MetaKV = daemon_fsjobs.MetaKV;
    const fsJobLine = daemon_fsjobs.fsJobLine;
    const fsJobExited = daemon_fsjobs.fsJobExited;

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
        _ = c.fcntl(fd, c.F_SETFD, c.FD_CLOEXEC);
        const fl = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
        _ = c.fcntl(fd, c.F_SETFL, fl | c.O_NONBLOCK);
        self.openAppChannel(s, fd);
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
    fn sessionAudioRunning(self: *Daemon, s: *Session, except: *Channel) bool {
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
        while (pulse.peelUnit(bytes[pos..])) |p| {
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
        while (pulse.peelUnit(bytes[pos..])) |p| {
            if (p.tag == .subscribe) {
                cl.audio_ok = true;
                srv.has_viewer = true;
                // Flags byte (optional): bit0 = decodes Opus.
                if (p.payload.len >= 1 and p.payload[0] & 1 != 0) cl.audio_opus = true;
                if (ch.session.?.audio_capture_base == null)
                    srv.opus_wanted = srv.opus_wanted or cl.audio_opus;
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
    }

    pub fn nativeViewer(cl: *const Client, s: *const Session) bool {
        return cl.attached == s and !cl.dead and
            cl.native_state_max >= wire.LEGACY_NATIVE_STATE_VERSION and
            cl.native_state_max >= s.native_state_min;
    }

    pub fn audioViewer(cl: *const Client, s: *const Session) bool {
        return cl.attached == s and !cl.dead and cl.audio_channels;
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

    /// Bridge one accepted app connection as a session-owned channel.
    fn openAppChannel(self: *Daemon, s: *Session, fd: c_int) void {
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
            .native = native,
        };
        native.wants_video = self.videoOk(s);
        // Wire the brain to resolve + inject the app's icon when it
        // announces its app_id. Stable pointers (native/ch are heap).
        native.daemon = self;
        native.chan = ch;
        brain.view = .{
            .ctx = native,
            .toplevel_app_id = onBrainAppId,
            .toplevel_gone = onBrainGone,
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
    const POOL_CHUNK = daemon_native.POOL_CHUNK;
    const queueDmabufProtocolError = daemon_native.queueDmabufProtocolError;
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
    pub const isWorker = daemon_sessions.isWorker;
    pub const handleSpawn = daemon_sessions.handleSpawn;
    pub const spawnSession = daemon_sessions.spawnSession;
    pub const handleAttach = daemon_sessions.handleAttach;
    const findSession = daemon_sessions.findSession;
    const brokerFindWorker = daemon_sessions.brokerFindWorker;
    const applyWorkerLimits = daemon_sessions.applyWorkerLimits;
    const brokerSpawn = daemon_sessions.brokerSpawn;
    const brokerAttach = daemon_sessions.brokerAttach;
    const brokerList = daemon_sessions.brokerList;
    const brokerKill = daemon_sessions.brokerKill;
    const brokerRename = daemon_sessions.brokerRename;
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

    fn viewerCount(self: *const Daemon, s: *const Session) u32 {
        var n: u32 = 0;
        for (self.clients.items) |cl| {
            if (!cl.dead and cl.attached == s) n += 1;
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
            if (cl.dead or cl.attached != s) continue;
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
        if (cl.read_only) return false;
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
            if (other == holder or other.dead or other.attached != s or other.read_only) continue;
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
            if (cl.dead or cl.attached != s) continue;
            cl.queueJson(.peer_info, .{ .total = total, .guis = guis, .drivers = drivers });
        }
    }

    /// A proto>=6 client just attached: for every live native app
    /// channel on `s`, announce the channel and rebuild its replica —
    /// current pool bytes from the mirrors, then the brain's
    /// serialized protocol state. Windows reappear with current
    /// pixels (durable GUI apps, multi-viewer).
    pub fn replayNativeChannels(self: *Daemon, cl: *Client, s: *Session) void {
        // A full replay makes the client current — any pending
        // withheld-frames state is superseded by it.
        cl.needs_native_resync = false;
        if (cl.audio_channels) {
            // Audio channels are independent of graphical state support.
            for (self.channels.items) |ch| {
                if (ch.session != s or ch.dead) continue;
                const srv = ch.pa orelse continue;
                var hdr: [5]u8 = undefined;
                cl.queueFrame(.chan_open, wire.encodeChanOpen(&hdr, ch.id, .audio));
                if (cl.audio_ok) srv.has_viewer = true;
                var units: std.ArrayList(u8) = .empty;
                defer units.deinit(self.allocator);
                var it = srv.streams.iterator();
                while (it.next()) |e| {
                    var pl: [10]u8 = undefined;
                    std.mem.writeInt(u32, pl[0..4], e.key_ptr.*, .little);
                    pl[4] = e.value_ptr.format;
                    pl[5] = e.value_ptr.channels;
                    std.mem.writeInt(u32, pl[6..10], e.value_ptr.rate, .little);
                    pulse.appendUnit(&units, self.allocator, .open, &pl) catch break;
                }
                if (units.items.len > 0) self.queueUnitsTo(cl, ch, units.items);
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
        var ts: c.struct_timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
        const now_ms: u64 = @intCast(ts.tv_sec * 1000 + @divTrunc(ts.tv_nsec, 1_000_000));
        for (self.channels.items) |ch| {
            if (ch.dead or ch.native != null) continue;
            const chs = ch.session orelse continue;
            const ws = chs.winstream orelse continue;
            const cl = ch.client orelse continue;
            if (cl.dead) continue;
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

    pub fn queueSnapshot(self: *Daemon, cl: *Client, s: *Session) void {
        // A full snapshot supersedes any withheld events — whatever
        // triggered it (attach, resize, resync), the client is current
        // again once this lands.
        cl.needs_resync = false;
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        // Protocol 1-3 used [seq:u64]; protocol 4 added the app byte.
        var seq_hdr: [9]u8 = undefined;
        std.mem.writeInt(u64, seq_hdr[0..8], s.seq, .little);
        seq_hdr[8] = if (s.app) 1 else 0;
        const header = if (cl.proto >= 4) seq_hdr[0..9] else seq_hdr[0..8];
        buf.appendSlice(self.allocator, header) catch {
            cl.dead = true;
            return;
        };
        snapshot.serializeVersion(s.screen, &buf, self.allocator, cl.snapshot_version) catch {
            cl.queueErr("snapshot failed");
            return;
        };
        cl.queueFrame(.snapshot, buf.items);
    }

    pub fn broadcastSnapshot(self: *Daemon, s: *Session) void {
        for (self.clients.items) |cl| {
            if (cl.attached == s and !cl.dead) self.queueSnapshot(cl, s);
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
        const now = nowMs();
        for (self.sessions.items) |s| {
            var n_clients: u32 = 0;
            for (self.clients.items) |c2| {
                if (c2.attached == s) n_clients += 1;
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
            if (cwdOfPid(s.pty.child_pid, &scratch)) |cw| {
                if (self.allocator.dupe(u8, cw)) |owned| {
                    cwd_bufs.append(self.allocator, owned) catch {};
                    cwd = owned;
                } else |_| {}
            }
            infos.append(self.allocator, .{
                .name = s.name,
                .rows = s.screen.rows,
                .cols = s.screen.cols,
                .clients = n_clients,
                .exited = s.exited,
                .title = if (s.screen.last_title) |t| t else "",
                .app = s.app,
                .idle_ms = now - s.last_activity_ms,
                .cwd = cwd,
                .pid = s.pty.child_pid,
                .display = s.display,
                .wl_display = if (s.wl_display_path) |p| p else "",
                .pulse_server = if (s.pa_socket_path) |p| p else "",
                .runtime_dir = if (s.runtime_dir_path) |p| p else "",
                .ttl_secs = @intCast(@divTrunc(s.ttl_ms, 1000)),
                .viewers = n_clients,
                .controller = controller,
            }) catch return;
        }
        cl.queueJson(.welcome, .{ .proto = cl.proto, .server_proto = wire.PROTO_VERSION, .min_proto = wire.MIN_SERVER_PROTO, .negotiation = @as(u8, 1), .version = version.string, .audio_opus = opuscodec.available(), .video = build_options.video, .sessions = infos.items });
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
        var parsed = std.json.parseFromSlice(AttachReq, self.allocator, payload, .{
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
        self.removeSession(s);
        cl.queueJson(.ok, .{ .ok = true });
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
        if (req.new_name.len == 0 or req.new_name.len > 64) {
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
        const fresh = self.allocator.dupe(u8, req.new_name) catch {
            cl.queueErr("oom");
            return;
        };
        self.allocator.free(s.name);
        s.name = fresh;
        cl.queueJson(.ok, .{ .ok = true, .name = s.name });
    }

    pub fn removeSession(self: *Daemon, s: *Session) void {
        s.controller = null;
        for (self.clients.items) |cl| {
            if (cl.attached == s) {
                cl.attached = null;
                cl.queueJson(.gone, .{ .reason = "session closed" });
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
                _ = self.channels.swapRemove(i);
                ch.deinit();
            } else {
                i += 1;
            }
        }
    }

    /// Read whatever the PTY has, parse, apply to the authoritative
    /// Screen, and broadcast the serialized events to attached
    /// clients in one EVENTS frame.
    fn drainSession(self: *Daemon, s: *Session) void {
        var chunk: [32768]u8 = undefined;
        var total_events = EventCollector{
            .allocator = self.allocator,
            .screen = s.screen,
            .writer = wire.Writer.init(self.allocator),
            .ring = &s.log,
            .wall_ms = wallMs(),
        };
        defer total_events.writer.deinit();
        defer total_events.deinitMarkers();

        var rounds: u8 = 0;
        while (rounds < 8) : (rounds += 1) {
            const n_raw = c.read(s.pty.master_fd, &chunk, chunk.len);
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
            if (s.cast) |*rec| rec.output(nowMs(), chunk[0..n]);
            s.parser.advance(chunk[0..n], EventCollector.emit, @ptrCast(&total_events));
            if (n < chunk.len) break;
        }

        const n_events = total_events.count;
        if (n_events == 0 and total_events.markers.items.len == 0) return;
        // Real terminal output this drain → the session is active now.
        s.last_activity_ms = nowMs();
        var any_attached = false;
        for (self.clients.items) |cl| {
            if (cl.attached == s and !cl.dead) {
                any_attached = true;
                break;
            }
        }
        if (any_attached and n_events > 0) {
            var payload: std.ArrayList(u8) = .empty;
            defer payload.deinit(self.allocator);
            var hdr: [12]u8 = undefined;
            std.mem.writeInt(u64, hdr[0..8], s.seq, .little);
            std.mem.writeInt(u32, hdr[8..12], n_events, .little);
            payload.appendSlice(self.allocator, &hdr) catch return;
            payload.appendSlice(self.allocator, total_events.writer.buf.items) catch return;
            for (self.clients.items) |cl| {
                if (cl.attached != s or cl.dead) continue;
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
                cl.queueFrame(.events, payload.items);
            }
        }
        // Markers push to every attached client regardless of the
        // events backpressure — they are tiny and time-sensitive (the
        // viewer stashes "the app right now" against them).
        for (total_events.markers.items) |m| {
            for (self.clients.items) |cl| {
                if (cl.attached == s and !cl.dead)
                    cl.queueJson(.marker, .{ .id = m.id, .label = m.label, .t = total_events.wall_ms, .after = m.after });
            }
            log.debug("marker #{d} '{s}' after={d} (session '{s}')", .{ m.id, m.label, m.after, s.name });
        }
        s.seq += n_events;
    }

    fn sessionExited(self: *Daemon, s: *Session) void {
        if (s.exited) return;
        s.exited = true;
        // Nothing will ever drive this session again; keeping the
        // pointer would only risk a dangle past the client reap.
        s.controller = null;
        log.info("session '{s}' exited", .{s.name});
        // We reach here on PTY EOF/EIO: the child has exited but may
        // not be waitpid-able for another scheduler tick, and a single
        // WNOHANG try races it — the .exit frame then ships the
        // default 0 even for a SIGSEGV death (reported by MCP users as
        // "segfault exited 0"). Retry briefly; EOF implies the exit
        // already happened, so this converges in microseconds. The
        // bound only bites when a child closed its stdio and lives on.
        var tries: u32 = 0;
        while (tries < 50) : (tries += 1) {
            if (s.pty.reap()) |code| {
                s.exit_status = code;
                break;
            }
            _ = c.usleep(1000);
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
                cl.attached = null;
            }
        }
    }

    /// Kill sessions whose no-viewer TTL has run out. A session with an
    /// attached viewer keeps resetting the clock; one that has NEVER
    /// been attached counts from spawn (see no_viewer_since_ms), so an
    /// abandoned `display create` cannot leak a Wayland hub forever.
    /// In broker mode this runs in the WORKER (which owns the session
    /// and knows its viewers); its exit is what retires the record.
    fn ttlSweep(self: *Daemon) void {
        const now = nowMs();
        for (self.sessions.items) |s| {
            if (s.ttl_ms == 0 or s.exited) continue;
            var attached = false;
            for (self.clients.items) |cl| {
                if (!cl.dead and cl.attached == s) {
                    attached = true;
                    break;
                }
            }
            if (attached) {
                s.no_viewer_since_ms = 0;
                continue;
            }
            if (s.no_viewer_since_ms == 0) {
                s.no_viewer_since_ms = now;
                continue;
            }
            if (now - s.no_viewer_since_ms < s.ttl_ms) continue;
            log.info("session '{s}': ttl expired ({d}s with no viewer)", .{ s.name, @divTrunc(s.ttl_ms, 1000) });
            self.removeSession(s);
        }
    }

    fn reap(self: *Daemon) void {
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
        // Jobs OUTLIVE their client (durable transfers) — only the
        // event route dies with it. Finished jobs are retained for
        // job_list, bounded, oldest dropped first.
        {
            for (self.fs_jobs.items) |j| {
                if (j.owner) |o| {
                    if (o.dead) {
                        // pid > 0 is load-bearing: kill(-0) would signal
                        // the daemon's OWN process group.
                        if (j.ephemeral and !j.finished() and j.pid > 0) {
                            _ = c.kill(-j.pid, c.SIGKILL);
                            j.state = .canceled;
                        }
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
                if (!j.ephemeral and j.finished() and !j.terminal_pending) {
                    if (j.client_token.len > 0) {
                        if (j.acknowledged) token_count += 1;
                    } else finished_count += 1;
                }
            }
            var i: usize = 0;
            while (i < self.fs_jobs.items.len) {
                const j = self.fs_jobs.items[i];
                if (j.ephemeral and j.finished() and j.out_fd < 0) {
                    _ = self.fs_jobs.orderedRemove(i);
                    j.deinit(false);
                } else i += 1;
            }
            i = 0;
            while (finished_count > MAX_FINISHED_JOBS and i < self.fs_jobs.items.len) {
                const j = self.fs_jobs.items[i];
                if (j.finished() and !j.terminal_pending and j.client_token.len == 0) {
                    _ = self.fs_jobs.orderedRemove(i);
                    j.deinit(false);
                    finished_count -= 1;
                } else i += 1;
            }
            i = 0;
            while (token_count > MAX_TOKEN_JOBS and i < self.fs_jobs.items.len) {
                const j = self.fs_jobs.items[i];
                if (j.finished() and j.client_token.len > 0 and j.acknowledged) {
                    var record_buf: [4096]u8 = undefined;
                    if (std.fmt.bufPrintZ(&record_buf, "{s}/{d}.json", .{ self.fs_job_dir, j.id })) |record| {
                        _ = c.unlink(record.ptr);
                    } else |_| {}
                    _ = self.fs_jobs.orderedRemove(i);
                    j.deinit(false);
                    token_count -= 1;
                } else i += 1;
            }
        }
        var i: usize = 0;
        while (i < self.clients.items.len) {
            const cl = self.clients.items[i];
            if (cl.dead) {
                // A dying client's TCP forwards die with it (native
                // and audio channels are session-owned and survive).
                for (self.channels.items) |ch| {
                    if (ch.tcp and ch.client == cl) ch.dead = true;
                }
                const was = cl.attached;
                if (was) |s| log.info("client gone (session '{s}')", .{s.name});
                // Release BEFORE the client is freed and removed: the
                // handover scan compares against this pointer, and
                // s.controller would otherwise dangle.
                const lease_moved = if (was) |s| self.releaseControl(s, cl) else false;
                _ = self.clients.swapRemove(i);
                cl.deinit();
                // Duplicate rosters (several deaths, one session) are
                // harmless; correctness beats coalescing here.
                if (was) |s| {
                    if (!s.exited) {
                        if (lease_moved) self.broadcastControlState(s);
                        self.broadcastPeerInfo(s);
                    }
                }
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
    }
};

/// Per-drain context: applies each event to the Screen and
/// serializes it for broadcast in the same pass.
pub const EventCollector = struct {
    allocator: std.mem.Allocator,
    screen: *Screen,
    writer: wire.Writer,
    count: u32 = 0,
    /// Session log ring to feed (escape-free lines); null = don't.
    ring: ?*logring.LogRing = null,
    /// Wall-clock stamp for lines committed during this drain.
    wall_ms: i64 = 0,
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
        // screen identical to what clients see.
        var fwd = ev;
        var owned: ?[]u8 = null;
        defer if (owned) |b| self.allocator.free(b);
        if (ev == .apc) {
            if (@import("kitty_inline.zig").rewrite(self.allocator, ev.apc.bytes)) |nb| {
                owned = nb;
                fwd = .{ .apc = .{ .bytes = nb } };
            }
        }
        if (self.ring) |r| switch (fwd) {
            .print => |cp| r.feedCodepoint(cp),
            .print_byte => |b| r.feedBytes(&.{b}),
            .print_run => |run| r.feedBytes(run.bytes[0..run.len]),
            .execute => |b| r.feedControl(b, self.wall_ms),
            else => {},
        };
        self.writer.putEvent(fwd) catch {};
        self.screen.apply(fwd);
        self.count += 1;
        var mut = ev;
        mut.deinit(self.allocator);
    }

    fn deinitMarkers(self: *EventCollector) void {
        for (self.markers.items) |m| self.allocator.free(m.label);
        self.markers.deinit(self.allocator);
    }
};

pub fn defaultSocketPath(allocator: std.mem.Allocator) ![]u8 {
    const rt = @import("../util/platform.zig").runtimeDir();
    return std.fmt.allocPrint(allocator, "{s}/sketerm/mux.sock", .{rt});
}
