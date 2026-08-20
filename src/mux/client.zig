//! Mux client connection: blocking helpers shared by the smoke
//! test, the TUI picker, and the GUI attach path (which switches
//! the fd to non-blocking and polls it from the GLib loop).

const std = @import("std");
const c = @import("../c.zig").c;
const wire = @import("wire.zig");
const sockpath = @import("sockpath.zig");
const deploy = @import("deploy.zig");
const rudp = @import("rudp.zig");
/// The one publish/stop/release mechanism for interrupting a blocking
/// socket from another thread; re-exported so SDK consumers can declare
/// the slot these connect helpers take.
pub const FdCancel = @import("../util/fdcancel.zig").FdCancel;

/// A brokered UDP connection ticket: a single-use listener the remote
/// daemon bound for us, reachable with no ssh bootstrap of our own.
pub const UdpTicket = struct {
    port: u16,
    /// rudp key as hex (fixed length — validated at parse).
    key: [rudp.KEY_LEN * 2]u8,

    pub fn keyhex(self: *const UdpTicket) []const u8 {
        return &self.key;
    }
};

/// Parse an `udp_ticket` frame payload; null = refused or malformed.
pub fn parseUdpTicketReply(allocator: std.mem.Allocator, payload: []const u8) ?UdpTicket {
    const Reply = struct { ok: bool = false, port: u16 = 0, key: []const u8 = "" };
    const parsed = std.json.parseFromSlice(Reply, allocator, payload, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();
    if (!parsed.value.ok or parsed.value.port == 0) return null;
    if (parsed.value.key.len != rudp.KEY_LEN * 2) return null;
    if (rudp.keyFromHex(parsed.value.key) == null) return null;
    var ticket = UdpTicket{ .port = parsed.value.port, .key = undefined };
    @memcpy(&ticket.key, parsed.value.key);
    return ticket;
}

pub const Transport = enum { local, ssh, udp };
pub const RemoteMode = enum { auto, ssh, udp };

pub const RemoteSpec = struct {
    host: []const u8,
    mode: RemoteMode,

    pub fn parse(spec: []const u8) RemoteSpec {
        if (std.mem.startsWith(u8, spec, "udp:")) return .{ .host = spec[4..], .mode = .udp };
        if (std.mem.startsWith(u8, spec, "ssh:")) return .{ .host = spec[4..], .mode = .ssh };
        return .{ .host = spec, .mode = .auto };
    }
};

fn monotonicMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.tv_sec) * 1000 + @divTrunc(ts.tv_nsec, 1_000_000);
}

/// Reap a bootstrap SSH that should exit immediately after announcing.
fn reapBootstrapChild(pid: c.pid_t) void {
    var status: c_int = 0;
    var deadline = monotonicMs() + 500;
    while (monotonicMs() < deadline) {
        const r = c.waitpid(pid, &status, c.WNOHANG);
        if (r == pid or (r < 0 and std.posix.errno(r) != .INTR)) return;
        _ = c.usleep(10_000);
    }
    _ = c.kill(pid, c.SIGTERM);
    deadline = monotonicMs() + 250;
    while (monotonicMs() < deadline) {
        const r = c.waitpid(pid, &status, c.WNOHANG);
        if (r == pid or (r < 0 and std.posix.errno(r) != .INTR)) return;
        _ = c.usleep(10_000);
    }
    _ = c.kill(pid, c.SIGKILL);
    while (true) {
        const r = c.waitpid(pid, &status, 0);
        if (r >= 0 or std.posix.errno(r) != .INTR) break;
    }
}

/// Resolve the sketerm-mux binary: sibling of our own executable
/// first (works for `zig build run` trees), then bare name ($PATH).
pub fn findMuxBinary(buf: *[4096:0]u8) [*:0]const u8 {
    const platform = @import("../util/platform.zig");
    // $SKETERM_MUX_BIN pins the binary outright — test rigs run from
    // zig-cache where neither the sibling nor $PATH is the fresh build.
    if (c.getenv("SKETERM_MUX_BIN")) |p| return p;
    if (platform.exePathZ(buf)) |exe_path| {
        if (std.mem.lastIndexOfScalar(u8, exe_path, '/')) |slash| {
            const dir_len = slash + 1;
            const want = "sketerm-mux";
            if (dir_len + want.len < buf.len) {
                @memcpy(buf[dir_len .. dir_len + want.len], want);
                buf[dir_len + want.len] = 0;
                if (c.access(buf, c.X_OK) == 0) return @ptrCast(buf);
            }
        }
    }
    return "sketerm-mux";
}

/// Consume a spawn-time brokered ticket from $SKETERM_UDP_TICKET
/// ("<host> <port> <keyhex>") when it names `host`. Single-use: the
/// variable is cleared on a match — the remote listener serves
/// exactly one connection, so a second consumer would only burn a
/// timeout on it. Main-thread only (getenv/unsetenv are not
/// thread-safe against each other).
pub fn takeTicketFromEnv(host: []const u8) ?UdpTicket {
    const raw = c.getenv("SKETERM_UDP_TICKET") orelse return null;
    const s = std.mem.span(@as([*:0]const u8, @ptrCast(raw)));
    var it = std.mem.tokenizeScalar(u8, s, ' ');
    const h = it.next() orelse return null;
    const port_s = it.next() orelse return null;
    const key = it.next() orelse return null;
    if (it.next() != null) return null;
    if (!std.mem.eql(u8, h, RemoteSpec.parse(host).host)) return null;
    const port = std.fmt.parseInt(u16, port_s, 10) catch return null;
    if (port == 0 or key.len != rudp.KEY_LEN * 2 or rudp.keyFromHex(key) == null) return null;
    var ticket = UdpTicket{ .port = port, .key = undefined };
    @memcpy(&ticket.key, key);
    _ = c.unsetenv("SKETERM_UDP_TICKET");
    return ticket;
}

/// How long a "UDP is down for this host" verdict is trusted before
/// the probe is retried. Long enough that a burst of helper processes
/// (mount, per-file copy jobs) rides one verdict; short enough that a
/// fixed firewall or network change is picked up soon.
const UDP_MEMO_TTL_S: i64 = 600;

/// Stamp path for the per-host UDP memo, under the user cache dir.
fn udpMemoPath(buf: []u8, host: []const u8) ?[:0]const u8 {
    const h = std.hash.Wyhash.hash(0, host);
    if (c.getenv("XDG_CACHE_HOME")) |raw| {
        const base = std.mem.span(@as([*:0]const u8, @ptrCast(raw)));
        return std.fmt.bufPrintZ(buf, "{s}/sketerm/mux/udp-down-{x:0>16}", .{ base, h }) catch null;
    }
    const home_raw = c.getenv("HOME") orelse return null;
    const home = std.mem.span(@as([*:0]const u8, @ptrCast(home_raw)));
    return std.fmt.bufPrintZ(buf, "{s}/.cache/sketerm/mux/udp-down-{x:0>16}", .{ home, h }) catch null;
}

fn udpMemoDown(host: []const u8) bool {
    var buf: [4096]u8 = undefined;
    const path = udpMemoPath(&buf, host) orelse return false;
    var st: c.struct_stat = undefined;
    if (c.stat(path.ptr, &st) != 0) return false;
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_REALTIME, &ts);
    const mtime = if (@hasField(c.struct_stat, "st_mtim")) st.st_mtim.tv_sec else st.st_mtimespec.tv_sec;
    return @as(i64, ts.tv_sec) - @as(i64, mtime) <= UDP_MEMO_TTL_S;
}

fn udpMemoMark(host: []const u8) void {
    var buf: [4096]u8 = undefined;
    const path = udpMemoPath(&buf, host) orelse return;
    // Parent dirs may not exist yet (fresh cache); build them plainly.
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| {
        var dir_buf: [4096:0]u8 = undefined;
        if (std.fmt.bufPrintZ(&dir_buf, "{s}", .{path[0..slash]})) |dir| {
            var i: usize = 1;
            while (i <= dir.len) : (i += 1) {
                if (i == dir.len or dir[i] == '/') {
                    const save = dir[i];
                    dir_buf[i] = 0;
                    _ = c.mkdir(dir.ptr, 0o700);
                    dir_buf[i] = save;
                }
            }
        } else |_| {}
    }
    const fp = c.fopen(path.ptr, "we") orelse return;
    _ = c.fclose(fp);
}

fn udpMemoClear(host: []const u8) void {
    var buf: [4096]u8 = undefined;
    const path = udpMemoPath(&buf, host) orelse return;
    _ = c.unlink(path.ptr);
}

/// Additive attach properties shared by terminal viewers, future GUI panel
/// presenters, and panel-only requesters.
pub const AttachOptions = struct {
    kind: []const u8 = "",
    origin_id: []const u8 = "",
    read_only: bool = false,
    control: bool = false,
    panel_only: bool = false,
    panel_rpc: u8 = 0,
};

pub const AttachIdentity = struct {
    name_buf: [64]u8 = undefined,
    name_len: u8 = 0,
    origin_name_buf: [64]u8 = undefined,
    origin_name_len: u8 = 0,
    origin_id: wire.SessionOriginId = undefined,
    valid: bool = false,

    pub fn name(self: *const AttachIdentity) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn originName(self: *const AttachIdentity) []const u8 {
        return self.origin_name_buf[0..self.origin_name_len];
    }

    pub fn originId(self: *const AttachIdentity) []const u8 {
        return if (self.valid) &self.origin_id else "";
    }

    fn parse(allocator: std.mem.Allocator, payload: []const u8) !AttachIdentity {
        const Meta = struct {
            name: []const u8 = "",
            origin_name: []const u8 = "",
            origin_id: []const u8 = "",
        };
        var parsed = std.json.parseFromSlice(Meta, allocator, payload, .{
            .ignore_unknown_fields = true,
        }) catch return error.MalformedAttachIdentity;
        defer parsed.deinit();
        const meta = parsed.value;
        if (meta.name.len == 0 or meta.name.len > 64 or
            meta.origin_name.len == 0 or meta.origin_name.len > 64 or
            !wire.validSessionOriginId(meta.origin_id))
            return error.MalformedAttachIdentity;
        var identity = AttachIdentity{};
        identity.name_len = @intCast(meta.name.len);
        @memcpy(identity.name_buf[0..meta.name.len], meta.name);
        identity.origin_name_len = @intCast(meta.origin_name.len);
        @memcpy(identity.origin_name_buf[0..meta.origin_name.len], meta.origin_name);
        @memcpy(&identity.origin_id, meta.origin_id);
        identity.valid = true;
        return identity;
    }
};

/// GUI presenter replies share the terminal connection with ordinary traffic.
/// Keep this well below the daemon's 64 MiB relay ceiling so a stalled daemon
/// cannot turn correlated panel replies into a process-sized GTK backlog.
pub const GUI_PANEL_REPLY_BACKLOG: usize = 8 << 20;
pub const DEFAULT_WRITE_TIMEOUT_MS: c_int = 30_000;

pub const Conn = struct {
    allocator: std.mem.Allocator,
    fd: c_int,
    transport: Transport = .local,
    rbuf: std.ArrayList(u8) = .empty,
    /// Complete frames queued by GUI main-loop producers. These are
    /// flushed incrementally without polling so backpressure cannot freeze
    /// GTK.
    wbuf: std.ArrayList(u8) = .empty,
    /// Message from the last daemon `.err` frame seen by `recvExpect`,
    /// so callers can surface the REAL reason ("no such session", …)
    /// instead of a bare `error.DaemonError`.
    last_err: [192]u8 = undefined,
    last_err_len: usize = 0,
    /// Bound on how long sendFrame waits for a full socket buffer to
    /// drain before failing (a wedged daemon must cost an error, not
    /// a hung caller).
    write_timeout_ms: c_int = DEFAULT_WRITE_TIMEOUT_MS,
    /// Why an `.auto` connection came up on SSH instead of UDP. Null
    /// on a UDP connection, on a forced transport, and on local
    /// sockets. Callers surface it so a downgrade names its cause
    /// instead of reading as an unexplained "UDP unavailable".
    udp_error: ?anyerror = null,
    /// Selected core profile and the daemon's newest profile when advertised.
    proto: u32 = 1,
    server_proto: u32 = 1,
    snapshot_version: u8 = @import("snapshot.zig").LEGACY_SNAPSHOT_VERSION,
    /// Daemon's cross_copy honors delete_src/dial_tries and stamps
    /// dial failures kind:"unreachable" (welcome capability). Gates
    /// daemon-owned moves and direct remote-to-remote coordination.
    cross_move: bool = false,
    /// cross_copy honors client_token and retains terminal jobs until
    /// job_ack, so browser-owned intents can survive view handoff.
    durable_copy: bool = false,
    copy_no_replace: bool = false,
    /// cross_copy serializes cancellation against final installation
    /// and source deletion, including restart recovery.
    durable_copy_v2: bool = false,
    /// The daemon's announced build id (git describe). Empty = a
    /// daemon that predates the announce — stale by definition.
    server_build: [72]u8 = undefined,
    server_build_len: usize = 0,
    /// Daemon answers `udp_ticket_req` (welcome capability). Gates the
    /// request — an older daemon would answer `.err`, which a
    /// multiplexed GUI connection could misattribute.
    udp_tickets: bool = false,
    /// Display output geometry and guarded display-only kill requests.
    display_v2: bool = false,
    /// Daemon enforces KillReq.origin_id before resolving a destructive kill.
    /// Older daemons silently ignore that additive field, so fenced callers
    /// must refuse unless this welcome capability is present.
    kill_origin_fence: bool = false,
    /// Daemon answers `lsp_open` (welcome capability): it can spawn a
    /// language server near the files and bridge its stdio as a byte
    /// channel. Absent = degrade silently, like a missing server.
    lsp_support: bool = false,
    /// Daemon supports cast-playback sessions (SpawnReq.cast_path +
    /// play_control frames). Gates both — an old daemon would spawn a
    /// login shell for the request and `.err` on the control frame.
    cast_playback: bool = false,
    /// Daemon serves `web_op` (welcome capability): history, bookmarks
    /// and per-site settings stored on the daemon's host. Absent =
    /// never send the frame; the client degrades to no persistence.
    web_store: bool = false,
    /// Daemon answers `stream_open` (welcome capability): it can open an
    /// arbitrary-host TCP stream with DNS resolved on the daemon host.
    /// Absent = never send the frame; an old daemon's generic `.err`
    /// cannot be correlated to one of several pending CONNECT requests.
    stream_open: bool = false,
    /// Daemon answers `web_helper_open` (welcome capability): it can
    /// spawn a sketerm-webengine browser helper on ITS host and bridge
    /// the protocol socket as a byte channel. Absent = remote browsing
    /// on this host gets a described "daemon too old" error.
    web_helper: bool = false,
    /// Independent panel relay capability advertised by the daemon.
    panel_rpc: u8 = 0,
    /// The daemon can put immutable session identity before the initial GUI
    /// snapshot when explicitly requested by a panel-capable attachment.
    attach_identity: bool = false,
    attach_identity_pending: bool = false,
    /// Immutable spawn name returned for legacy migration/display metadata.
    panel_origin_name: [64]u8 = undefined,
    panel_origin_name_len: usize = 0,
    /// Lifetime-unique immutable session incarnation returned by attach.
    panel_origin_id: wire.SessionOriginId = undefined,
    panel_origin_id_valid: bool = false,

    pub fn connect(allocator: std.mem.Allocator, sock_path: []const u8) !Conn {
        const fd = @import("../util/platform.zig").socketCloexec(c.AF_UNIX, c.SOCK_STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        errdefer _ = c.close(fd);
        var addr: c.struct_sockaddr_un = undefined;
        try sockpath.fillSockaddrUn(&addr, sock_path);
        if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0) return error.ConnectFailed;
        return .{ .allocator = allocator, .fd = fd };
    }

    /// Connect to a specific daemon socket and complete the
    /// hello/welcome probe (proto negotiation — without it the daemon
    /// treats the client as proto 1 and never streams app channels).
    /// NO autostart and no stale-daemon retire: a failed handshake is
    /// an error and never triggers daemon replacement.
    pub fn connectProbed(allocator: std.mem.Allocator, sock_path: []const u8) !Conn {
        const conn = try Conn.connect(allocator, sock_path);
        return probe(allocator, conn);
    }

    /// Connect to the local daemon, spawning it (sibling binary,
    /// $PATH fallback) and retrying for ~2s when it isn't running.
    /// Sends the hello/welcome probe like the remote transports do —
    /// it announces OUR proto version, which gates whether the
    /// daemon offers byte channels (Wayland app forwarding).
    pub fn connectLocalAutostart(allocator: std.mem.Allocator) !Conn {
        return connectLocalAutostartAt(allocator, null);
    }

    /// Like `connectLocalAutostart`, but against `sock_path` when given —
    /// a PRIVATE daemon instance (its aux sockets live next to the socket),
    /// used by `sketerm mcp` isolation. null = the shared per-user daemon.
    pub fn connectLocalAutostartAt(allocator: std.mem.Allocator, sock_path: ?[]const u8) !Conn {
        const path = if (sock_path) |p|
            try allocator.dupe(u8, p)
        else
            try sockpath.defaultSocketPath(allocator);
        defer allocator.free(path);
        if (Conn.connect(allocator, path)) |conn| {
            return probe(allocator, conn);
        } else |_| {}

        // Process-isolation broker by default: each session runs in its own
        // worker process, so one shell's crash/OOM can't take down the daemon
        // or its siblings. SKETERM_NO_BROKER=1 falls back to the single-process
        // monolith (escape hatch if the broker ever misbehaves in the field).
        const use_broker = c.getenv("SKETERM_NO_BROKER") == null;
        // NUL-terminated socket arg for the child; prepared before fork
        // (no allocation between fork and exec).
        var sock_z_buf: [4096:0]u8 = undefined;
        const sock_z: ?[*:0]const u8 = if (sock_path != null)
            (std.fmt.bufPrintZ(&sock_z_buf, "{s}", .{path}) catch return error.BadPath).ptr
        else
            null;
        const pid = c.fork();
        if (pid == 0) {
            _ = c.setsid();
            // Detach stdio before exec. The daemon outlives the client
            // that autostarted it, so inheriting its stdout/stderr wedges
            // any pipeline or $(...) that client sits in: the shell waits
            // for EVERY writer to close the pipe and the daemon never
            // does, so `sketerm mux spawn x | cat` hangs forever the one
            // time it also has to start the daemon. Nothing is lost —
            // lifecycle and warnings go to mux.log either way.
            const devnull = c.open("/dev/null", c.O_RDWR);
            if (devnull >= 0) {
                _ = c.dup2(devnull, 0);
                _ = c.dup2(devnull, 1);
                _ = c.dup2(devnull, 2);
                if (devnull > 2) _ = c.close(devnull);
            }
            var bin_buf: [4096:0]u8 = undefined;
            const bin = findMuxBinary(&bin_buf);
            var argv: [5:null]?[*:0]const u8 = .{ bin, null, null, null, null };
            var n: usize = 1;
            if (use_broker) {
                argv[n] = "--broker";
                n += 1;
            }
            if (sock_z) |z| {
                argv[n] = "--socket";
                argv[n + 1] = z;
            }
            _ = c.execvp(bin, @ptrCast(@constCast(&argv)));
            c._exit(127);
        }
        var tries: u32 = 0;
        while (tries < 40) : (tries += 1) {
            _ = c.usleep(50_000);
            if (Conn.connect(allocator, path)) |conn| {
                return probe(allocator, conn);
            } else |_| {}
        }
        return error.MuxDaemonUnreachable;
    }

    /// hello → welcome round trip; consumes the welcome so the
    /// stream is clean for the caller's own frames.
    pub fn probe(allocator: std.mem.Allocator, conn_in: Conn) !Conn {
        var conn = conn_in;
        errdefer conn.deinit();
        try conn.sendHello();
        // Bounded: a daemon that accepts but never answers (wedged,
        // swap-thrashing) must fail the connect, not hang the caller.
        const w = try conn.recvExpectFor(&.{.welcome}, 10_000);
        defer w.deinit(allocator);
        conn.applyWelcome(allocator, w.payload);
        return conn;
    }

    fn hello(self: *Conn, comptime queue_only: bool, deadline_ms: ?i64) !void {
        const value = .{
            .proto = wire.PROTO_VERSION,
            .min_proto = @as(u32, 1),
            .negotiation = @as(u8, 1),
            .snapshot_max = @import("snapshot.zig").SNAPSHOT_VERSION,
            .native_state_max = wire.NATIVE_STATE_VERSION,
            .audio = true,
            .winstream = true,
            .video = @import("build_options").video,
            .panel_rpc = wire.PANEL_RPC_VERSION,
        };
        if (queue_only)
            try self.queueJsonUntil(.hello, value, deadline_ms.?)
        else
            try self.sendJson(.hello, value);
    }

    fn sendHello(self: *Conn) !void {
        try self.hello(false, null);
    }

    fn queueHelloUntil(self: *Conn, deadline_ms: i64) !void {
        try self.hello(true, deadline_ms);
    }

    fn applyWelcome(self: *Conn, allocator: std.mem.Allocator, payload: []const u8) void {
        self.proto = 0;
        self.server_proto = 0;
        self.snapshot_version = 0;
        self.udp_tickets = false;
        self.cross_move = false;
        self.durable_copy = false;
        self.copy_no_replace = false;
        self.durable_copy_v2 = false;
        self.display_v2 = false;
        self.kill_origin_fence = false;
        self.lsp_support = false;
        self.cast_playback = false;
        self.web_store = false;
        self.stream_open = false;
        self.web_helper = false;
        self.panel_rpc = 0;
        self.attach_identity = false;
        self.attach_identity_pending = false;
        self.server_build_len = 0;
        const Probe = struct {
            proto: u32 = 1,
            server_proto: ?u32 = null,
            negotiation: u8 = 0,
            snapshot: u8 = 0,
            udp_ticket: bool = false,
            cross_move: bool = false,
            durable_copy: bool = false,
            copy_no_replace: bool = false,
            durable_copy_v2: bool = false,
            display_v2: bool = false,
            kill_origin_fence: bool = false,
            lsp: bool = false,
            cast_playback: bool = false,
            web_store: bool = false,
            stream_open: bool = false,
            web_helper: bool = false,
            panel_rpc: u8 = 0,
            attach_identity: bool = false,
            build: []const u8 = "",
        };
        if (std.json.parseFromSlice(Probe, allocator, payload, .{ .ignore_unknown_fields = true })) |parsed| {
            defer parsed.deinit();
            const reported = parsed.value.proto;
            self.proto = if (parsed.value.negotiation > 0)
                reported
            else if (reported >= 1 and reported <= wire.PROTO_VERSION)
                reported
            else
                0;
            self.server_proto = parsed.value.server_proto orelse reported;
            self.udp_tickets = parsed.value.udp_ticket;
            self.cross_move = parsed.value.cross_move;
            self.durable_copy = parsed.value.durable_copy;
            self.copy_no_replace = parsed.value.copy_no_replace;
            self.durable_copy_v2 = parsed.value.durable_copy_v2;
            self.display_v2 = parsed.value.display_v2;
            self.kill_origin_fence = parsed.value.kill_origin_fence;
            self.lsp_support = parsed.value.lsp;
            self.cast_playback = parsed.value.cast_playback;
            self.web_store = parsed.value.web_store;
            self.stream_open = parsed.value.stream_open;
            self.web_helper = parsed.value.web_helper;
            self.panel_rpc = @min(parsed.value.panel_rpc, wire.PANEL_RPC_VERSION);
            self.attach_identity = parsed.value.attach_identity;
            self.server_build_len = @min(parsed.value.build.len, self.server_build.len);
            @memcpy(self.server_build[0..self.server_build_len], parsed.value.build[0..self.server_build_len]);
            self.snapshot_version = if (parsed.value.snapshot > 0)
                @min(parsed.value.snapshot, @import("snapshot.zig").SNAPSHOT_VERSION)
            else if (self.proto >= 6)
                @import("snapshot.zig").SNAPSHOT_VERSION
            else
                @import("snapshot.zig").LEGACY_SNAPSHOT_VERSION;
        } else |_| {}
    }

    pub fn serverBuild(self: *const Conn) []const u8 {
        return self.server_build[0..self.server_build_len];
    }

    /// The daemon runs an older (or just different) build than this
    /// client. "unknown" local builds (tarball, no git) never claim
    /// staleness; a daemon announcing NO build predates the announce
    /// and is stale by definition.
    pub fn buildStale(self: *const Conn) bool {
        const mine = @import("build_options").commit;
        if (std.mem.eql(u8, mine, "unknown")) return false;
        return !std.mem.eql(u8, self.serverBuild(), mine);
    }

    /// Ask a STALE and provably IDLE daemon (no sessions, no live fs
    /// jobs — both probed over verbs old daemons answer) to shut down
    /// so the caller's reconnect autostarts the freshly deployed
    /// binary. True = the daemon agreed and this connection is spent;
    /// reconnect. Any refusal or uncertainty leaves the connection
    /// usable and returns false. Interrupted fs jobs would not even
    /// be lost (journal respawn), but a running one is a reason not
    /// to bounce the daemon under someone.
    pub fn upgradeStaleIdle(self: *Conn, allocator: std.mem.Allocator) bool {
        if (!self.buildStale()) return false;
        // Sessions? `.list` answers with a welcome-shaped frame
        // carrying `sessions` (the mux CLI's own list path).
        self.sendFrame(.list, "") catch return false;
        {
            const f = self.recvExpectFor(&.{.welcome}, 5_000) catch return false;
            defer f.deinit(allocator);
            const Probe = struct { sessions: []const struct {
                name: []const u8 = "",
            } = &.{} };
            const parsed = std.json.parseFromSlice(Probe, allocator, f.payload, .{
                .ignore_unknown_fields = true,
            }) catch return false;
            defer parsed.deinit();
            if (parsed.value.sessions.len != 0) return false;
        }
        // Live jobs? job_list is req-matched on fs_reply.
        const req: u32 = 0x5f757067; // arbitrary fixed nonce ("_upg")
        self.sendJson(.fs_op, .{ .req = req, .op = "job_list" }) catch return false;
        {
            const f = self.recvExpectFor(&.{.fs_reply}, 5_000) catch return false;
            defer f.deinit(allocator);
            const Probe = struct { req: u32 = 0, ok: bool = false, jobs: []const struct {
                state: []const u8 = "",
            } = &.{} };
            const parsed = std.json.parseFromSlice(Probe, allocator, f.payload, .{
                .ignore_unknown_fields = true,
            }) catch return false;
            defer parsed.deinit();
            if (parsed.value.req != req or !parsed.value.ok) return false;
            for (parsed.value.jobs) |j| {
                if (std.mem.eql(u8, j.state, "running") or std.mem.eql(u8, j.state, "paused"))
                    return false;
            }
        }
        // Idle and stale: the long-standing shutdown verb, so even a
        // daemon from before this mechanism can be replaced.
        self.sendJson(.shutdown, .{}) catch return false;
        if (self.recvExpectFor(&.{.ok}, 5_000)) |f| f.deinit(allocator) else |_| {}
        return true;
    }

    pub fn deinit(self: *Conn) void {
        _ = c.close(self.fd);
        self.fd = -1;
        self.rbuf.deinit(self.allocator);
        self.wbuf.deinit(self.allocator);
    }

    /// Connect to a remote daemon using the requested transport policy.
    ///
    /// Auto mode consults the per-host UDP memo: a host whose UDP probe
    /// failed recently is dialed over ssh IMMEDIATELY instead of every
    /// helper process (mount, cross-copy job) re-burning the probe
    /// budget the GUI already spent. The memo expires, so UDP gets
    /// retried once the network may have changed.
    pub fn connectRemote(allocator: std.mem.Allocator, spec: []const u8, port_range: ?[]const u8) !Conn {
        if (std.mem.startsWith(u8, spec, "sock:")) return connectProbed(allocator, spec[5..]);
        const remote = RemoteSpec.parse(spec);
        if (remote.mode == .auto and udpMemoDown(remote.host)) {
            var conn = try connectSsh(allocator, remote.host);
            conn.udp_error = error.UdpRecentlyUnavailable;
            return conn;
        }
        const conn = try connectRemoteUsing(allocator, spec, port_range, connectUdpAuto, connectUdp, connectSshWithRange);
        if (conn.transport == .udp) {
            udpMemoClear(remote.host);
        } else if (remote.mode == .auto and conn.udp_error != null) {
            udpMemoMark(remote.host);
        }
        return conn;
    }

    const RemoteConnector = *const fn (std.mem.Allocator, []const u8, ?[]const u8) anyerror!Conn;

    fn connectSshWithRange(allocator: std.mem.Allocator, host: []const u8, _: ?[]const u8) !Conn {
        return connectSsh(allocator, host);
    }

    fn connectUdpAuto(allocator: std.mem.Allocator, host: []const u8, port_range: ?[]const u8) !Conn {
        return connectUdpFor(allocator, host, port_range, 6_000);
    }

    fn connectRemoteUsing(
        allocator: std.mem.Allocator,
        spec: []const u8,
        port_range: ?[]const u8,
        auto_udp_connect: RemoteConnector,
        forced_udp_connect: RemoteConnector,
        ssh_connect: RemoteConnector,
    ) !Conn {
        const remote = RemoteSpec.parse(spec);
        if (!validSshHost(remote.host)) return error.BadPath;
        return switch (remote.mode) {
            .udp => forced_udp_connect(allocator, remote.host, port_range),
            .ssh => ssh_connect(allocator, remote.host, port_range),
            .auto => auto_udp_connect(allocator, remote.host, port_range) catch |udp_err| blk: {
                var conn = try ssh_connect(allocator, remote.host, port_range);
                conn.udp_error = udp_err;
                break :blk conn;
            },
        };
    }

    /// Human-readable cause for an automatic UDP -> SSH downgrade.
    pub fn udpErrorText(e: anyerror) []const u8 {
        return switch (e) {
            error.UdpProxiedHost => "ssh reaches it through a ProxyJump/ProxyCommand hop, so it has no directly reachable address",
            error.UdpBridgeUnreachable => "the announced UDP port never answered and the NAT hole punch did not connect (filtered UDP, or symmetric NAT)",
            error.SshTransportFailed => "no UDP announcement came back over ssh (remote sketerm-mux too old, or the bootstrap failed)",
            error.UdpRecentlyUnavailable => "UDP failed for this host moments ago; the probe was skipped and will be retried in a few minutes",
            else => @errorName(e),
        };
    }

    /// What the user's ssh config actually resolves a host spec to.
    /// `hostname` points into the caller's buffer.
    pub const SshTarget = struct {
        hostname: []const u8,
        /// A ProxyJump/ProxyCommand hop means there is no address the
        /// UDP leg can reach directly, however we resolve the name.
        proxied: bool,
    };

    /// Parse `ssh -G` output. Split from the spawn so the parsing is
    /// testable without a live ssh.
    pub fn parseSshConfigOutput(text: []const u8, out: *[256]u8) ?SshTarget {
        var hostname: ?[]const u8 = null;
        var proxied = false;
        var lines = std.mem.tokenizeAny(u8, text, "\r\n");
        while (lines.next()) |line| {
            const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            const key = line[0..sp];
            const val = std.mem.trim(u8, line[sp + 1 ..], " \t");
            if (val.len == 0) continue;
            if (std.mem.eql(u8, key, "hostname")) {
                if (val.len <= out.len) {
                    @memcpy(out[0..val.len], val);
                    hostname = out[0..val.len];
                }
            } else if (std.mem.eql(u8, key, "proxyjump") or std.mem.eql(u8, key, "proxycommand")) {
                // Unset reads as the literal "none" in some versions
                // and is simply absent in others.
                if (!std.mem.eql(u8, val, "none")) proxied = true;
            }
        }
        return .{ .hostname = hostname orelse return null, .proxied = proxied };
    }

    /// Ask ssh itself what a host spec resolves to, so the UDP leg
    /// targets the same machine the SSH leg does.
    ///
    /// `Host` aliases, `HostName` overrides and `Match` blocks all live
    /// in the user's ssh config; sending UDP to the literal spec
    /// resolves nothing when it is an alias, which silently downgraded
    /// every aliased host to SSH. Reimplementing that config parser
    /// here would be a second source of truth, so `ssh -G` is asked
    /// instead -- it only prints the resolved config and never
    /// connects, so an unreachable host costs nothing.
    ///
    /// Null when ssh is missing or too old for `-G`; the caller then
    /// keeps the literal host, which is the pre-existing behaviour.
    fn resolveSshConfig(spec: []const u8, out: *[256]u8, deadline: i64) ?SshTarget {
        var spec_z_buf: [256:0]u8 = undefined;
        const spec_z = std.fmt.bufPrintZ(&spec_z_buf, "{s}", .{spec}) catch return null;

        var pipe_fds: [2]c_int = undefined;
        if (c.pipe(&pipe_fds) != 0) return null;
        for (pipe_fds) |fd| _ = c.fcntl(fd, c.F_SETFD, c.FD_CLOEXEC);

        const ssh_env = c.getenv("SKETERM_SSH");
        const ssh_bin: [*:0]const u8 = if (ssh_env != null) ssh_env else "ssh";

        const pid = c.fork();
        if (pid < 0) {
            _ = c.close(pipe_fds[0]);
            _ = c.close(pipe_fds[1]);
            return null;
        }
        if (pid == 0) {
            _ = c.dup2(pipe_fds[1], 1);
            // Config warnings on stderr are not ours to print.
            const devnull = c.open("/dev/null", c.O_WRONLY);
            if (devnull >= 0) _ = c.dup2(devnull, 2);
            _ = c.close(pipe_fds[0]);
            _ = c.close(pipe_fds[1]);
            var argv = [_:null]?[*:0]const u8{ ssh_bin, "-G", spec_z.ptr, null };
            _ = c.execvp(ssh_bin, @ptrCast(@constCast(&argv)));
            c._exit(127);
        }
        _ = c.close(pipe_fds[1]);

        var buf: [8192]u8 = undefined;
        var len: usize = 0;
        while (len < buf.len) {
            const remain = deadline - monotonicMs();
            if (remain <= 0) break;
            var pfd = c.struct_pollfd{ .fd = pipe_fds[0], .events = c.POLLIN, .revents = 0 };
            const pr = c.poll(&pfd, 1, @intCast(@min(remain, 250)));
            if (pr < 0) {
                if (std.posix.errno(pr) == .INTR) continue;
                break;
            }
            if (pr == 0) continue;
            const n = c.read(pipe_fds[0], buf[len..].ptr, buf.len - len);
            if (n <= 0) break;
            len += @intCast(n);
        }
        _ = c.close(pipe_fds[0]);
        reapBootstrapChild(pid);
        return parseSshConfigOutput(buf[0..len], out);
    }

    /// Mosh-style UDP transport: bootstrap over SSH (run
    /// `sketerm-mux --udp-listen` remotely, read its one-line
    /// "SKETERM-UDP <port> <key>" announcement, ssh exits), then
    /// spawn a local `sketerm-mux --udp-connect` bridge over a
    /// socketpair. Everything downstream is fd-agnostic, same as
    /// the plain SSH transport — but the live connection is
    /// encrypted UDP with roaming + retransmission (rudp.zig).
    /// The bootstrap also carries a best-effort NAT hole punch
    /// (punch.zig): we announce our pre-bound UDP port over ssh
    /// stdin so a NATed remote can probe back at us.
    pub fn connectUdp(allocator: std.mem.Allocator, host: []const u8, port_range: ?[]const u8) !Conn {
        return connectUdpFor(allocator, host, port_range, 20_000);
    }

    fn connectUdpFor(allocator: std.mem.Allocator, host: []const u8, port_range: ?[]const u8, timeout_ms: i64) !Conn {
        if (!validSshHost(host)) return error.BadPath;
        if (port_range) |r| if (!validPortRange(r)) return error.BadPath;

        // 0. Resolve the UDP target through the user's ssh config
        //    FIRST: a proxied host can never work over UDP, and
        //    finding that out now costs one non-connecting `ssh -G`
        //    instead of a portable-mux deployment round-trip plus the
        //    full bootstrap and handshake timeout.
        var resolved_buf: [256]u8 = undefined;
        var udp_host: []const u8 = if (std.mem.indexOfScalar(u8, host, '@')) |at| host[at + 1 ..] else host;
        if (resolveSshConfig(host, &resolved_buf, monotonicMs() + timeout_ms)) |target| {
            if (target.proxied) return error.UdpProxiedHost;
            udp_host = target.hostname;
        }

        var prepared = deploy.prepare(allocator, host);
        defer if (prepared) |*p| p.deinit();
        var command_buf: [4300:0]u8 = undefined;
        const prepared_command: ?[:0]const u8 = if (prepared) |p| blk: {
            if (port_range) |r| {
                break :blk std.fmt.bufPrintZ(&command_buf, "exec \"{s}\" --udp-listen --udp-port {s}", .{ p.path, r }) catch return error.BadPath;
            }
            break :blk std.fmt.bufPrintZ(&command_buf, "exec \"{s}\" --udp-listen", .{p.path}) catch return error.BadPath;
        } else null;
        // The bootstrap budget starts AFTER deployment: an upload on
        // first contact must not eat the announcement deadline.
        const deadline = monotonicMs() + timeout_ms;

        // 0.5. Bind the transport's UDP socket EARLY, so its port can
        //      ride the punch line to the remote (below) and the very
        //      same socket can then be inherited by the bridge child —
        //      the remote's punch probes only help if they hit the
        //      port the bridge actually sends from. CLOEXEC stays set
        //      until just before the bridge spawn so the ssh child
        //      never inherits it. Failure = no punch, not no connect.
        const platform = @import("../util/platform.zig");
        var punch_fd: c_int = platform.socketCloexec(c.AF_INET, c.SOCK_DGRAM, 0);
        var punch_port: u16 = 0;
        if (punch_fd >= 0 and punch_fd < 3) {
            // A GUI daemonized with closed stdio can land this on fd
            // 0/1, where the bridge child's dup2-of-the-socketpair
            // would clobber it. Park it above the stdio range.
            const moved = c.fcntl(punch_fd, c.F_DUPFD_CLOEXEC, @as(c_int, 3));
            _ = c.close(punch_fd);
            punch_fd = if (moved >= 0) moved else -1;
        }
        if (punch_fd >= 0) {
            var ba: c.struct_sockaddr_in = std.mem.zeroes(c.struct_sockaddr_in);
            ba.sin_family = c.AF_INET;
            var ga: c.struct_sockaddr_in = undefined;
            var gl: c.socklen_t = @sizeOf(c.struct_sockaddr_in);
            if (c.bind(punch_fd, @ptrCast(&ba), @sizeOf(c.struct_sockaddr_in)) == 0 and
                c.getsockname(punch_fd, @ptrCast(&ga), &gl) == 0)
            {
                punch_port = std.mem.bigToNative(u16, ga.sin_port);
            } else {
                _ = c.close(punch_fd);
                punch_fd = -1;
            }
        }
        defer if (punch_fd >= 0) {
            _ = c.close(punch_fd);
        };

        // 1. Bootstrap: ssh prints the announcement on a pipe; our
        //    punch line goes out on its stdin.
        var host_z_buf: [256:0]u8 = undefined;
        const host_z = std.fmt.bufPrintZ(&host_z_buf, "{s}", .{host}) catch return error.BadPath;
        var pipe_fds: [2]c_int = undefined;
        if (c.pipe(&pipe_fds) != 0) return error.SocketFailed;
        for (pipe_fds) |fd| _ = c.fcntl(fd, c.F_SETFD, c.FD_CLOEXEC);
        var in_fds: [2]c_int = .{ -1, -1 };
        if (c.pipe(&in_fds) != 0) in_fds = .{ -1, -1 };
        for (in_fds) |fd| {
            if (fd >= 0) _ = c.fcntl(fd, c.F_SETFD, c.FD_CLOEXEC);
        }
        const ssh_env = c.getenv("SKETERM_SSH");
        const ssh_bin: [*:0]const u8 = if (ssh_env != null) ssh_env else "ssh";
        var range_z_buf: [32:0]u8 = undefined;
        const range_z: ?[:0]const u8 = if (port_range) |r|
            std.fmt.bufPrintZ(&range_z_buf, "{s}", .{r}) catch return error.BadPath
        else
            null;
        var argv: [20:null]?[*:0]const u8 = .{null} ** 20;
        var argc: usize = 0;
        const push = struct {
            fn f(buf: *[20:null]?[*:0]const u8, i: *usize, value: ?[*:0]const u8) void {
                buf[i.*] = value;
                i.* += 1;
            }
        }.f;
        push(&argv, &argc, ssh_bin);
        push(&argv, &argc, "-T");
        push(&argv, &argc, "-x");
        push(&argv, &argc, "-o");
        push(&argv, &argc, "BatchMode=yes");
        if (ssh_env == null and deploy.canMultiplex()) {
            push(&argv, &argc, "-o");
            push(&argv, &argc, "ControlMaster=auto");
            push(&argv, &argc, "-o");
            push(&argv, &argc, "ControlPath=~/.ssh/sketerm-%C");
            push(&argv, &argc, "-o");
            push(&argv, &argc, "ControlPersist=120");
        }
        push(&argv, &argc, host_z.ptr);
        if (prepared_command) |command| {
            push(&argv, &argc, command.ptr);
        } else {
            push(&argv, &argc, "sketerm-mux");
            push(&argv, &argc, "--udp-listen");
            if (range_z) |range| {
                push(&argv, &argc, "--udp-port");
                push(&argv, &argc, range.ptr);
            }
        }
        push(&argv, &argc, null);

        const pid = c.fork();
        if (pid < 0) {
            _ = c.close(pipe_fds[0]);
            _ = c.close(pipe_fds[1]);
            for (in_fds) |fd| {
                if (fd >= 0) _ = c.close(fd);
            }
            return error.ForkFailed;
        }
        if (pid == 0) {
            _ = c.dup2(pipe_fds[1], 1);
            _ = c.close(pipe_fds[0]);
            _ = c.close(pipe_fds[1]);
            if (in_fds[0] >= 0) {
                _ = c.dup2(in_fds[0], 0);
                _ = c.close(in_fds[0]);
                _ = c.close(in_fds[1]);
            }
            _ = c.execvp(ssh_bin, @ptrCast(@constCast(&argv)));
            c._exit(127);
        }
        _ = c.close(pipe_fds[1]);
        if (in_fds[0] >= 0) _ = c.close(in_fds[0]);

        // Send the punch line NOW, before the announcement round-trip:
        // by the time the remote reads its stdin the line is already
        // buffered, so a new server pays no wait and an old server
        // simply never reads it. Closing the write end gives the
        // remote a fast EOF (and old-server stdin stays untouched).
        // SIGPIPE is neutered process-wide in every entry point that
        // reaches here, so a dead ssh costs an EPIPE, not the process.
        if (in_fds[1] >= 0) {
            if (punch_port != 0) {
                var pl_buf: [32]u8 = undefined;
                if (@import("punch.zig").formatLine(punch_port, &pl_buf)) |pl| {
                    _ = c.write(in_fds[1], pl.ptr, pl.len);
                }
            }
            _ = c.close(in_fds[1]);
        }

        // Read the announcement line with one absolute deadline; an
        // old remote binary or wedged SSH must reach the SSH fallback.
        var line_buf: [512]u8 = undefined;
        var line_len: usize = 0;
        var announce: ?[]const u8 = null;
        outer: while (line_len < line_buf.len) {
            const remain = deadline - monotonicMs();
            if (remain <= 0) break;
            var pfd = c.struct_pollfd{ .fd = pipe_fds[0], .events = c.POLLIN, .revents = 0 };
            const pr = c.poll(&pfd, 1, @intCast(@min(remain, 250)));
            if (pr < 0) {
                if (std.posix.errno(pr) == .INTR) continue;
                break;
            }
            if (pr == 0) continue;
            const n = c.read(pipe_fds[0], line_buf[line_len..].ptr, line_buf.len - line_len);
            if (n <= 0) break;
            line_len += @intCast(n);
            var start: usize = 0;
            while (std.mem.indexOfScalarPos(u8, line_buf[0..line_len], start, '\n')) |nl| {
                const line = line_buf[start..nl];
                if (std.mem.startsWith(u8, line, "SKETERM-UDP ")) {
                    announce = line;
                    break :outer;
                }
                start = nl + 1;
            }
            if (start > 0) {
                std.mem.copyForwards(u8, line_buf[0 .. line_len - start], line_buf[start..line_len]);
                line_len -= start;
            }
        }
        _ = c.close(pipe_fds[0]);
        reapBootstrapChild(pid);
        const ann = announce orelse return error.SshTransportFailed;
        const parsed_ann = rudp.parseAnnounce(ann) orelse return error.SshTransportFailed;
        var port_buf: [8]u8 = undefined;
        const port = std.fmt.bufPrint(&port_buf, "{d}", .{parsed_ann.port}) catch unreachable;

        // 2. Local UDP bridge child over a socketpair, aimed at the
        // ssh-config-resolved address from step 0.
        return connectUdpBridge(allocator, udp_host, port, parsed_ann.keyhex, punch_fd, deadline);
    }

    /// Spawn the local `--udp-connect` bridge child at
    /// `udp_host:port` and complete the hello/welcome probe.
    /// `punch_fd >= 0` hands the pre-bound punch socket to the
    /// bridge (ssh-bootstrap path only; the ticket path has no punch).
    fn connectUdpBridge(
        allocator: std.mem.Allocator,
        udp_host: []const u8,
        port: []const u8,
        keyhex: []const u8,
        punch_fd: c_int,
        deadline: i64,
    ) !Conn {
        var mux_bin_buf: [4096:0]u8 = undefined;
        const mux_bin = findMuxBinary(&mux_bin_buf);
        var port_z_buf: [16:0]u8 = undefined;
        const port_z = std.fmt.bufPrintZ(&port_z_buf, "{s}", .{port}) catch return error.SshTransportFailed;
        var key_z_buf: [128:0]u8 = undefined;
        const key_z = std.fmt.bufPrintZ(&key_z_buf, "{s}", .{keyhex}) catch return error.SshTransportFailed;
        var bh_z_buf: [256:0]u8 = undefined;
        const bh_z = std.fmt.bufPrintZ(&bh_z_buf, "{s}", .{udp_host}) catch return error.BadPath;

        // Hand the pre-bound punch socket to the bridge (fd number as
        // a 4th positional arg; the fd survives spawnOverSocketpair's
        // dup2-of-0/1 untouched once CLOEXEC is dropped). An OLDER
        // bridge binary ignores trailing --udp-connect args, binds its
        // own socket, and merely loses the punch — never the connect.
        var fd_z_buf: [16:0]u8 = undefined;
        var argv2 = [_:null]?[*:0]const u8{
            mux_bin, "--udp-connect", bh_z.ptr, port_z.ptr, key_z.ptr, null, null,
        };
        if (punch_fd >= 0) {
            if (std.fmt.bufPrintZ(&fd_z_buf, "{d}", .{punch_fd})) |fz| {
                _ = c.fcntl(punch_fd, c.F_SETFD, @as(c_int, 0));
                argv2[5] = fz.ptr;
            } else |_| {}
        }
        var conn = try spawnOverSocketpair(allocator, mux_bin, &argv2);
        errdefer conn.deinit();

        // Past this point the bootstrap/ticket already succeeded, so a
        // failure is the UDP path itself not carrying traffic --
        // distinct from "the remote never announced", and the only
        // thing that distinguishes filtered/NAT-mapped UDP for the
        // fallback message.
        conn.sendHello() catch return error.UdpBridgeUnreachable;
        const remain = deadline - monotonicMs();
        if (remain <= 0) return error.UdpBridgeUnreachable;
        const w = conn.recvExpectFor(&.{.welcome}, remain) catch return error.UdpBridgeUnreachable;
        defer w.deinit(allocator);
        conn.applyWelcome(allocator, w.payload);
        conn.transport = .udp;
        return conn;
    }

    /// Ask the daemon at the other end of THIS connection to mint a
    /// single-use UDP listener (connection-ticket brokering). Blocking
    /// helper for DEDICATED connections only: unrelated frames arriving
    /// during the wait are discarded (recvExpectFor) — a GUI terminal
    /// connection must use its async frame dispatch instead.
    pub fn requestUdpTicket(self: *Conn, port_range: ?[]const u8, timeout_ms: i64) !UdpTicket {
        if (!self.udp_tickets) return error.TicketsUnsupported;
        try self.sendJson(.udp_ticket_req, .{ .range = port_range });
        const f = try self.recvExpectFor(&.{.udp_ticket}, timeout_ms);
        defer f.deinit(self.allocator);
        return parseUdpTicketReply(self.allocator, f.payload) orelse error.TicketRefused;
    }

    /// Connect to `host`'s daemon over UDP with a brokered ticket — NO
    /// ssh bootstrap: the listener already exists on the remote and the
    /// key already traveled over an authenticated channel. `ssh -G`
    /// still resolves host aliases (it never connects). No hole punch
    /// rides this path, so a NATed remote costs one bounded failure;
    /// callers fall back to the normal transports.
    pub fn connectUdpTicket(allocator: std.mem.Allocator, host: []const u8, ticket: UdpTicket) !Conn {
        const bare = RemoteSpec.parse(host).host;
        if (!validSshHost(bare)) return error.BadPath;
        const deadline = monotonicMs() + 10_000;
        var resolved_buf: [256]u8 = undefined;
        var udp_host: []const u8 = if (std.mem.indexOfScalar(u8, bare, '@')) |at| bare[at + 1 ..] else bare;
        if (resolveSshConfig(bare, &resolved_buf, monotonicMs() + 3_000)) |target| {
            if (!target.proxied) udp_host = target.hostname;
        }
        var port_buf: [8]u8 = undefined;
        const port = std.fmt.bufPrint(&port_buf, "{d}", .{ticket.port}) catch unreachable;
        return connectUdpBridge(allocator, udp_host, port, ticket.keyhex(), -1, deadline);
    }

    fn validPortRange(value: []const u8) bool {
        const colon = std.mem.indexOfScalar(u8, value, ':') orelse return false;
        if (colon == 0 or colon + 1 == value.len or std.mem.indexOfScalarPos(u8, value, colon + 1, ':') != null) return false;
        for (value[0..colon]) |byte| if (byte < '0' or byte > '9') return false;
        for (value[colon + 1 ..]) |byte| if (byte < '0' or byte > '9') return false;
        return true;
    }

    /// Connect to a REMOTE host's daemon by running
    /// `ssh -T -o BatchMode=yes <host> sketerm-mux --proxy` over a
    /// socketpair (one fd both ways, so everything downstream is
    /// transport-agnostic). The child is double-forked — it reparents
    /// to init, no zombie to reap. Requires key/agent auth
    /// (BatchMode fails instead of prompting on the protocol pipe).
    /// $SKETERM_SSH overrides the ssh binary (tests fake a remote).
    pub fn connectSsh(allocator: std.mem.Allocator, host: []const u8) !Conn {
        if (!validSshHost(host)) return error.BadPath;
        var prepared = deploy.prepare(allocator, host);
        defer if (prepared) |*p| p.deinit();
        // `sketerm app` opens TWO connections moments apart (the CLI to
        // spawn the session, then the GUI to attach). When the remote
        // sshd is slow to service new connections — a loaded box stalls
        // the banner/key exchange even though TCP connects instantly —
        // each fresh connection is a dice roll. Multiplexing (in
        // connectSshOnce) collapses them onto one master so only the
        // first pays that cost; this retry covers the master setup
        // itself stalling. Both together turn an intermittent failure
        // into a reliable connect.
        var attempt: u32 = 0;
        while (true) : (attempt += 1) {
            // The deployed path is retried alongside the PATH spelling:
            // on a host whose ONLY binary is the deployed one, a
            // transient sshd stall on the first attempt must not
            // demote every remaining attempt to fast "command not
            // found" failures.
            if (prepared) |p| {
                if (connectSshOnceUsing(allocator, host, p.path, 20_000)) |conn| return conn else |_| {}
            }
            if (connectSshOnceUsing(allocator, host, null, 20_000)) |conn| {
                return conn;
            } else |err| {
                if (attempt + 1 >= 3) return err;
                _ = c.usleep(400_000);
            }
        }
    }

    /// Single bounded connect attempt (~20s worst case) — pub for
    /// callers that must not pay connectSsh's 3x retry inline (e.g.
    /// termdrive's transparent reattach inside a drain path).
    pub fn connectSshOnce(allocator: std.mem.Allocator, host: []const u8) !Conn {
        if (!validSshHost(host)) return error.BadPath;
        var prepared = deploy.localPath(allocator);
        defer if (prepared) |*p| p.deinit();
        if (prepared) |p| {
            if (connectSshOnceUsing(allocator, host, p.path, 5_000)) |conn| return conn else |_| {}
        }
        return connectSshOnceUsing(allocator, host, null, 15_000);
    }

    fn connectSshOnceUsing(allocator: std.mem.Allocator, host: []const u8, remote_mux: ?[]const u8, timeout_ms: c_int) !Conn {
        var host_z_buf: [256:0]u8 = undefined;
        const host_z = std.fmt.bufPrintZ(&host_z_buf, "{s}", .{host}) catch return error.BadPath;
        const ssh_env = c.getenv("SKETERM_SSH");
        const ssh_bin: [*:0]const u8 = if (ssh_env != null) ssh_env else "ssh";

        // Connection multiplexing — only with the real ssh (a test rig
        // pointed at by $SKETERM_SSH keeps the plain positional argv).
        // ControlMaster=auto reuses an existing master or becomes one;
        // ControlPersist keeps it briefly after the spawning client
        // exits so the GUI's attach a beat later rides the same master
        // (instant — no second banner exchange). %C is a fixed-length
        // hash, so the socket path stays well under the sun_path limit.
        const mux = ssh_env == null and deploy.canMultiplex();
        var argv_buf: [16]?[*:0]const u8 = undefined;
        var n: usize = 0;
        const push = struct {
            fn f(buf: *[16]?[*:0]const u8, i: *usize, v: ?[*:0]const u8) void {
                buf[i.*] = v;
                i.* += 1;
            }
        }.f;
        push(&argv_buf, &n, ssh_bin);
        push(&argv_buf, &n, "-T");
        // The proxy channel carries the mux binary protocol — never X11.
        // `-x` disables X11 forwarding so a user's `ForwardX11 yes` config
        // can't print "X11 forwarding request failed" onto the terminal
        // (and can't perturb the protocol pipe).
        push(&argv_buf, &n, "-x");
        push(&argv_buf, &n, "-o");
        push(&argv_buf, &n, "BatchMode=yes");
        if (mux) {
            push(&argv_buf, &n, "-o");
            push(&argv_buf, &n, "ControlMaster=auto");
            push(&argv_buf, &n, "-o");
            push(&argv_buf, &n, "ControlPath=~/.ssh/sketerm-%C");
            push(&argv_buf, &n, "-o");
            push(&argv_buf, &n, "ControlPersist=120");
        }
        push(&argv_buf, &n, host_z.ptr);
        var command_buf: [4300:0]u8 = undefined;
        if (remote_mux) |path| {
            const command = std.fmt.bufPrintZ(&command_buf, "exec \"{s}\" --proxy", .{path}) catch return error.BadPath;
            push(&argv_buf, &n, command.ptr);
        } else {
            push(&argv_buf, &n, "sketerm-mux");
            push(&argv_buf, &n, "--proxy");
        }
        push(&argv_buf, &n, null);

        var conn = try spawnOverSocketpair(allocator, ssh_bin, @ptrCast(&argv_buf));
        errdefer conn.deinit();

        // Probe the bridge: hello → welcome proves ssh + remote
        // binary + daemon all came up before we hand the conn out.
        // Bound the welcome wait so a stalled banner surfaces as a
        // retryable error instead of hanging the blocking read forever.
        conn.sendHello() catch return error.SshTransportFailed;
        const deadline = monotonicMs() + timeout_ms;
        try waitReadable(conn.fd, deadline);
        const remain = deadline - monotonicMs();
        if (remain <= 0) return error.SshTransportFailed;
        const w = conn.recvExpectFor(&.{.welcome}, remain) catch return error.SshTransportFailed;
        defer w.deinit(allocator);
        conn.applyWelcome(allocator, w.payload);
        conn.transport = .ssh;
        return conn;
    }

    fn validSshHost(host: []const u8) bool {
        return host.len > 0 and host[0] != '-';
    }

    /// Switch the fd to non-blocking so NO call on this connection can
    /// park forever: sendFrame bounds a full-buffer write with a
    /// write_timeout_ms poll (its EAGAIN path), and reads must go
    /// through recvFrameFor/recvExpectFor/fillAvailable — plain
    /// recvFrame's blocking read() would misread EAGAIN as a hangup.
    pub fn setNonBlockingChecked(self: *Conn) !void {
        const fl = c.fcntl(self.fd, c.F_GETFL);
        if (fl < 0 or c.fcntl(self.fd, c.F_SETFL, fl | c.O_NONBLOCK) != 0)
            return error.NonBlockingFailed;
    }

    pub fn setNonBlocking(self: *Conn) void {
        self.setNonBlockingChecked() catch {};
    }

    /// Poll `fd` for readability, bounded by `timeout_ms`. A timeout or
    /// poll error becomes a retryable SshTransportFailed.
    fn waitReadable(fd: c_int, deadline: i64) !void {
        var pfd = [_]c.struct_pollfd{.{ .fd = fd, .events = c.POLLIN, .revents = 0 }};
        while (true) {
            const remain = deadline - monotonicMs();
            if (remain <= 0) return error.SshTransportFailed;
            const r = c.poll(&pfd, 1, @intCast(remain));
            if (r > 0) return;
            if (r < 0 and std.posix.errno(r) == .INTR) continue;
            return error.SshTransportFailed;
        }
    }

    /// Deliver one frame fully (bounded-blocking on backpressure) — the
    /// historical contract callers like Terminal.deinit's .kill rely on.
    /// When an upload backlog already sits in wbuf, the frame queues
    /// behind it and only the nonblocking flush runs; the upload pump
    /// (or a later flushQueuedFor) finishes the delivery.
    pub fn sendFrame(self: *Conn, ftype: wire.FrameType, payload: []const u8) !void {
        if (self.proto == 0 and ftype != .hello and ftype != .list and
            !(self.panel_rpc > 0 and (ftype == .attach or ftype == .detach or
                ftype == .panel_request or ftype == .panel_reply)))
            return error.NoSharedTerminalProfile;
        const had_backlog = self.wbuf.items.len > 0;
        try wire.appendFrame(&self.wbuf, self.allocator, ftype, payload);
        if (had_backlog) return self.flushQueued();
        return self.flushQueuedFor(self.write_timeout_ms);
    }

    /// Deliver one complete frame against an absolute monotonic deadline.
    pub fn sendFrameUntil(self: *Conn, ftype: wire.FrameType, payload: []const u8, deadline_ms: i64) !void {
        try self.queueFrameUntil(ftype, payload, deadline_ms);
    }

    /// Queue one complete frame and write only what the nonblocking fd
    /// accepts immediately. Partial writes remain resumable in `wbuf`.
    pub fn queueFrame(self: *Conn, ftype: wire.FrameType, payload: []const u8) !void {
        if (self.proto == 0 and ftype != .hello and ftype != .list and
            !(self.panel_rpc > 0 and (ftype == .attach or ftype == .detach or
                ftype == .panel_request or ftype == .panel_reply)))
            return error.NoSharedTerminalProfile;
        try wire.appendFrame(&self.wbuf, self.allocator, ftype, payload);
        try self.flushQueued();
    }

    pub fn flushQueued(self: *Conn) !void {
        var off: usize = 0;
        while (off < self.wbuf.items.len) {
            // MSG_NOSIGNAL: a dead peer must yield EPIPE, not a
            // process-killing SIGPIPE. macOS lacks the flag; callers
            // there rely on a SIGPIPE handler / GSocket's SO_NOSIGPIPE.
            const n = if (comptime @hasDecl(c, "MSG_NOSIGNAL"))
                c.send(self.fd, self.wbuf.items.ptr + off, self.wbuf.items.len - off, c.MSG_NOSIGNAL)
            else
                c.write(self.fd, self.wbuf.items.ptr + off, self.wbuf.items.len - off);
            if (n > 0) {
                off += @intCast(n);
                continue;
            }
            const e = std.posix.errno(n);
            if (e == .INTR) continue;
            if (e == .AGAIN) break;
            return error.WriteFailed;
        }
        wire.compactConsumed(&self.wbuf, off);
    }

    /// Drain queued frames, waiting (bounded) for the fd on backpressure.
    /// Teardown-critical frames (.kill/.detach) queued behind an upload
    /// backlog must reach the daemon before the fd closes.
    pub fn flushQueuedFor(self: *Conn, timeout_ms: c_int) !void {
        while (true) {
            try self.flushQueued();
            if (self.wbuf.items.len == 0) return;
            var pfd = [_]c.struct_pollfd{.{ .fd = self.fd, .events = c.POLLOUT, .revents = 0 }};
            const r = c.poll(&pfd, 1, timeout_ms);
            if (r > 0) continue;
            if (r < 0 and std.posix.errno(r) == .INTR) continue;
            return error.WriteFailed;
        }
    }

    /// Drain queued frames against one absolute deadline.
    fn flushQueuedUntil(self: *Conn, deadline_ms: i64) !void {
        while (true) {
            if (self.wbuf.items.len == 0) return;
            if (deadline_ms - monotonicMs() <= 0) return error.Timeout;
            try self.flushQueued();
            if (self.wbuf.items.len == 0) return;
            const remain = deadline_ms - monotonicMs();
            if (remain <= 0) return error.Timeout;
            var pfd = c.struct_pollfd{ .fd = self.fd, .events = c.POLLOUT, .revents = 0 };
            const r = c.poll(&pfd, 1, @intCast(@min(remain, 100)));
            if (r < 0 and std.posix.errno(r) == .INTR) continue;
            if (r < 0 or pfd.revents & (c.POLLERR | c.POLLHUP | c.POLLNVAL) != 0)
                return error.WriteFailed;
        }
    }

    pub fn sendJson(self: *Conn, ftype: wire.FrameType, value: anytype) !void {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        try std.json.Stringify.value(value, .{}, &aw.writer);
        try self.sendFrame(ftype, aw.written());
    }

    /// Serialize and deliver one JSON frame against an absolute deadline.
    pub fn sendJsonUntil(self: *Conn, ftype: wire.FrameType, value: anytype, deadline_ms: i64) !void {
        try self.queueJsonUntil(ftype, value, deadline_ms);
    }

    /// Send a name-only legacy kill or a negotiated lifetime-fenced kill.
    pub fn sendKill(self: *Conn, req: wire.KillReq) !void {
        if (req.origin_id.len > 0) {
            if (!wire.validSessionOriginId(req.origin_id)) return error.InvalidSessionOriginId;
            if (!self.kill_origin_fence) return error.KillOriginFenceUnsupported;
        }
        try self.sendJson(.kill, req);
    }

    /// Nonblocking `sendKill` variant for GUI teardown paths.
    pub fn queueKill(self: *Conn, req: wire.KillReq) !void {
        if (req.origin_id.len > 0) {
            if (!wire.validSessionOriginId(req.origin_id)) return error.InvalidSessionOriginId;
            if (!self.kill_origin_fence) return error.KillOriginFenceUnsupported;
        }
        try self.queueJson(.kill, req);
    }

    /// queueFrame's JSON twin: never waits on the fd. The caller owns
    /// flushing any wbuf remainder (a POLLOUT watch or pump loop).
    pub fn queueJson(self: *Conn, ftype: wire.FrameType, value: anytype) !void {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        try std.json.Stringify.value(value, .{}, &aw.writer);
        try self.queueFrame(ftype, aw.written());
    }

    fn queueFrameUntil(self: *Conn, ftype: wire.FrameType, payload: []const u8, deadline_ms: i64) !void {
        if (deadline_ms - monotonicMs() <= 0) return error.Timeout;
        if (self.proto == 0 and ftype != .hello and ftype != .list and
            !(self.panel_rpc > 0 and (ftype == .attach or ftype == .detach or
                ftype == .panel_request or ftype == .panel_reply)))
            return error.NoSharedTerminalProfile;
        try wire.appendFrame(&self.wbuf, self.allocator, ftype, payload);
        try self.flushQueuedUntil(deadline_ms);
    }

    fn queueJsonUntil(self: *Conn, ftype: wire.FrameType, value: anytype, deadline_ms: i64) !void {
        if (deadline_ms - monotonicMs() <= 0) return error.Timeout;
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        try std.json.Stringify.value(value, .{}, &aw.writer);
        try self.queueFrameUntil(ftype, aw.written(), deadline_ms);
    }

    /// Send an attach request with explicit additive capabilities.
    pub fn sendAttach(self: *Conn, name: []const u8, opts: AttachOptions) !void {
        if (opts.panel_rpc > self.panel_rpc) return error.PanelRpcUnsupported;
        if (opts.panel_only and opts.panel_rpc == 0) return error.PanelRpcUnsupported;
        const identity_first = self.attach_identity and !opts.panel_only and
            opts.panel_rpc > 0 and std.mem.eql(u8, opts.kind, "gui");
        try self.sendJson(.attach, .{
            .name = name,
            .origin_id = opts.origin_id,
            .kind = opts.kind,
            .read_only = opts.read_only,
            .control = opts.control,
            .panel_only = opts.panel_only,
            .panel_rpc = opts.panel_rpc,
            .identity_first = identity_first,
        });
        self.attach_identity_pending = identity_first;
    }

    /// Send one correlated panel request; JSON remains opaque to this layer.
    pub fn sendPanelRequest(self: *Conn, id: u64, json: []const u8) !void {
        try self.sendPanelEnvelope(.panel_request, id, json);
    }

    /// Send one panel request under the caller's existing absolute deadline.
    pub fn sendPanelRequestUntil(self: *Conn, id: u64, json: []const u8, deadline_ms: i64) !void {
        if (self.panel_rpc == 0) return error.PanelRpcUnsupported;
        if (self.wbuf.items.len != 0) return error.PanelSendPreDelivery;
        if (deadline_ms - monotonicMs() <= 0) return error.PanelSendPreDelivery;

        // Build the complete frame before touching the socket. Size and
        // allocation failures are therefore provably safe to report as
        // pre-delivery rather than being collapsed into a resend-unsafe write.
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.allocator);
        try wire.appendPanelEnvelope(&payload, self.allocator, id, json);
        var frame: std.ArrayList(u8) = .empty;
        defer frame.deinit(self.allocator);
        try wire.appendFrame(&frame, self.allocator, .panel_request, payload.items);

        var sent: usize = 0;
        while (sent < frame.items.len) {
            if (deadline_ms - monotonicMs() <= 0)
                return if (sent == 0) error.PanelSendPreDelivery else error.PanelSendUncertain;
            const n = if (comptime @hasDecl(c, "MSG_NOSIGNAL"))
                c.send(self.fd, frame.items.ptr + sent, frame.items.len - sent, c.MSG_NOSIGNAL)
            else
                c.write(self.fd, frame.items.ptr + sent, frame.items.len - sent);
            if (n > 0) {
                sent += @intCast(n);
                continue;
            }
            const e = std.posix.errno(n);
            if (e == .INTR) continue;
            if (e != .AGAIN)
                return if (sent == 0) error.PanelSendPreDelivery else error.PanelSendUncertain;
            const remain = deadline_ms - monotonicMs();
            if (remain <= 0)
                return if (sent == 0) error.PanelSendPreDelivery else error.PanelSendUncertain;
            var pfd = c.struct_pollfd{ .fd = self.fd, .events = c.POLLOUT, .revents = 0 };
            const polled = c.poll(&pfd, 1, @intCast(@min(remain, 100)));
            if (polled < 0 and std.posix.errno(polled) == .INTR) continue;
            if (polled < 0 or pfd.revents & (c.POLLERR | c.POLLHUP | c.POLLNVAL) != 0)
                return if (sent == 0) error.PanelSendPreDelivery else error.PanelSendUncertain;
        }
    }

    /// Send one correlated presenter reply; JSON remains opaque here too.
    pub fn sendPanelReply(self: *Conn, id: u64, json: []const u8) !void {
        try self.sendPanelEnvelope(.panel_reply, id, json);
    }

    /// Queue one correlated presenter reply without waiting for socket space.
    pub fn queuePanelReply(self: *Conn, id: u64, json: []const u8) !void {
        const frame_bytes = 5 +| wire.PANEL_ENVELOPE_HEADER +| json.len;
        if (self.wbuf.items.len +| frame_bytes > GUI_PANEL_REPLY_BACKLOG)
            return error.PanelReplyBackpressure;
        try self.queuePanelEnvelope(.panel_reply, id, json);
    }

    pub fn panelOrigin(self: *const Conn) []const u8 {
        return self.panel_origin_name[0..self.panel_origin_name_len];
    }

    pub fn panelOriginId(self: *const Conn) []const u8 {
        return if (self.panel_origin_id_valid) &self.panel_origin_id else "";
    }

    /// Return the exact canonical Unix listener path this local connection
    /// reached; custom local daemons must never be mistaken for the default.
    pub fn localDaemonOrigin(self: *const Conn, allocator: std.mem.Allocator) ![]u8 {
        if (self.transport != .local or self.fd < 0) return error.NotLocal;
        var addr = std.mem.zeroes(c.struct_sockaddr_un);
        var addr_len: c.socklen_t = @sizeOf(c.struct_sockaddr_un);
        if (c.getpeername(self.fd, @ptrCast(&addr), &addr_len) != 0) return error.PeerUnavailable;
        if (addr.sun_family != c.AF_UNIX) return error.NotLocal;
        const path = std.mem.sliceTo(addr.sun_path[0..], 0);
        if (path.len == 0 or path[0] != '/') return error.BadPath;
        return allocator.dupe(u8, path);
    }

    fn sendPanelEnvelope(self: *Conn, ftype: wire.FrameType, id: u64, json: []const u8) !void {
        if (self.panel_rpc == 0) return error.PanelRpcUnsupported;
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.allocator);
        try wire.appendPanelEnvelope(&payload, self.allocator, id, json);
        try self.sendFrame(ftype, payload.items);
    }

    fn queuePanelEnvelope(self: *Conn, ftype: wire.FrameType, id: u64, json: []const u8) !void {
        if (self.panel_rpc == 0) return error.PanelRpcUnsupported;
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.allocator);
        try wire.appendPanelEnvelope(&payload, self.allocator, id, json);
        try self.queueFrame(ftype, payload.items);
    }

    /// Spawn `argv` with both stdio ends on one socketpair fd,
    /// double-forked so init reaps it (no zombies, child outlives
    /// nothing it shouldn't). Returns a Conn over our end.
    ///
    /// CLOEXEC on the pair is load-bearing: without it every transport
    /// spawned LATER inherits the sockets of every earlier one, so the peer
    /// of an old connection cannot see EOF until the last of those children
    /// exits - a dead GUI's durable sessions then stay "attached" on the
    /// daemon, streaming into a socket nobody reads. `dup2` clears CLOEXEC
    /// on the copy it makes, so the exec'd child still gets stdin/stdout.
    /// `setsid` keeps a terminal signal aimed at the spawner's process group
    /// (a Ctrl+C or SIGHUP in the shell that launched the GUI) from taking
    /// every session transport down with it.
    fn spawnOverSocketpair(allocator: std.mem.Allocator, bin: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) !Conn {
        var pair: [2]c_int = undefined;
        if (@import("../util/platform.zig").socketpairCloexec(&pair) != 0) return error.SocketFailed;
        errdefer {
            _ = c.close(pair[0]);
            _ = c.close(pair[1]);
        }
        const pid = c.fork();
        if (pid < 0) return error.ForkFailed;
        if (pid == 0) {
            if (c.fork() == 0) {
                _ = c.setsid();
                _ = c.dup2(pair[1], 0);
                _ = c.dup2(pair[1], 1);
                _ = c.close(pair[0]);
                _ = c.close(pair[1]);
                _ = c.execvp(bin, @ptrCast(@constCast(argv)));
            }
            c._exit(0);
        }
        var st: c_int = 0;
        _ = c.waitpid(pid, &st, 0);
        _ = c.close(pair[1]);
        return .{ .allocator = allocator, .fd = pair[0] };
    }

    /// Blocking read of the next complete frame. The returned
    /// payload is heap-owned by `allocator`; caller frees.
    pub const OwnedFrame = struct {
        ftype: wire.FrameType,
        payload: []u8,

        pub fn deinit(self: OwnedFrame, allocator: std.mem.Allocator) void {
            allocator.free(self.payload);
        }
    };

    pub const GuiAttachResult = struct {
        snapshot: OwnedFrame,
        identity: AttachIdentity = .{},
    };

    /// Receive a GUI attach, requiring identity before the snapshot only when
    /// the negotiated daemon capability and sent attach request selected it.
    pub fn recvGuiAttach(self: *Conn) !GuiAttachResult {
        const identity_first = self.attach_identity_pending;
        self.attach_identity_pending = false;
        if (!identity_first) return .{ .snapshot = try self.recvExpect(&.{.snapshot}) };
        const meta = try self.recvExpect(&.{.session_meta});
        defer meta.deinit(self.allocator);
        const identity = try AttachIdentity.parse(self.allocator, meta.payload);
        return .{
            .snapshot = try self.recvExpect(&.{.snapshot}),
            .identity = identity,
        };
    }

    /// Deadline-aware identity-first GUI attach under one absolute timeout.
    pub fn recvGuiAttachFor(self: *Conn, timeout_ms: i64) !GuiAttachResult {
        const identity_first = self.attach_identity_pending;
        self.attach_identity_pending = false;
        const deadline = monotonicMs() + timeout_ms;
        if (!identity_first)
            return .{ .snapshot = try self.recvExpectFor(&.{.snapshot}, @max(deadline - monotonicMs(), 1)) };
        const meta = try self.recvExpectFor(&.{.session_meta}, @max(deadline - monotonicMs(), 1));
        defer meta.deinit(self.allocator);
        const identity = try AttachIdentity.parse(self.allocator, meta.payload);
        return .{
            .snapshot = try self.recvExpectFor(&.{.snapshot}, @max(deadline - monotonicMs(), 1)),
            .identity = identity,
        };
    }

    pub fn recvFrame(self: *Conn) !OwnedFrame {
        while (true) {
            if (try self.takeFrame()) |owned| return owned;
            var tmp: [16384]u8 = undefined;
            const n = c.read(self.fd, &tmp, tmp.len);
            if (n <= 0) return error.Disconnected;
            try self.rbuf.appendSlice(self.allocator, tmp[0..@intCast(n)]);
        }
    }

    /// `recvFrame` with a deadline: error.Timeout when no COMPLETE
    /// frame arrived within `timeout_ms` (partial bytes stay buffered
    /// — inspect `pendingPartial` for a useful diagnostic).
    pub fn recvFrameFor(self: *Conn, timeout_ms: i64) !OwnedFrame {
        var ts: c.struct_timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
        const deadline = @as(i64, ts.tv_sec) * 1000 + @divTrunc(ts.tv_nsec, 1_000_000) + timeout_ms;
        while (true) {
            if (try self.takeFrame()) |owned| return owned;
            _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
            const remain = deadline - (@as(i64, ts.tv_sec) * 1000 + @divTrunc(ts.tv_nsec, 1_000_000));
            if (remain <= 0) return error.Timeout;
            var pfd = c.struct_pollfd{ .fd = self.fd, .events = c.POLLIN, .revents = 0 };
            const pr = c.poll(&pfd, 1, @intCast(@min(remain, 100)));
            if (pr < 0 and std.posix.errno(pr) != .INTR) return error.Disconnected;
            if (pr <= 0) continue;
            var tmp: [16384]u8 = undefined;
            const n = c.read(self.fd, &tmp, tmp.len);
            if (n == 0) return error.Disconnected;
            if (n < 0) {
                const e = std.posix.errno(n);
                if (e == .AGAIN or e == .INTR) continue;
                return error.Disconnected;
            }
            try self.rbuf.appendSlice(self.allocator, tmp[0..@intCast(n)]);
        }
    }

    /// `recvFrame` with an INACTIVITY deadline: error.Timeout means no
    /// bytes arrived for `idle_ms` — a multi-MB frame crawling in over
    /// a slow link keeps the wait alive as long as it keeps moving.
    /// `cap_ms` hard-bounds the whole wait (no-hang invariant).
    pub fn recvFrameProgressive(self: *Conn, idle_ms: i64, cap_ms: i64) !OwnedFrame {
        var ts: c.struct_timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
        var now = @as(i64, ts.tv_sec) * 1000 + @divTrunc(ts.tv_nsec, 1_000_000);
        const cap_deadline = now + cap_ms;
        var idle_deadline = now + idle_ms;
        while (true) {
            if (try self.takeFrame()) |owned| return owned;
            _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
            now = @as(i64, ts.tv_sec) * 1000 + @divTrunc(ts.tv_nsec, 1_000_000);
            const remain = @min(idle_deadline, cap_deadline) - now;
            if (remain <= 0) return error.Timeout;
            var pfd = c.struct_pollfd{ .fd = self.fd, .events = c.POLLIN, .revents = 0 };
            const pr = c.poll(&pfd, 1, @intCast(@min(remain, 100)));
            if (pr < 0 and std.posix.errno(pr) != .INTR) return error.Disconnected;
            if (pr <= 0) continue;
            var tmp: [16384]u8 = undefined;
            const n = c.read(self.fd, &tmp, tmp.len);
            if (n == 0) return error.Disconnected;
            if (n < 0) {
                const e = std.posix.errno(n);
                if (e == .AGAIN or e == .INTR) continue;
                return error.Disconnected;
            }
            try self.rbuf.appendSlice(self.allocator, tmp[0..@intCast(n)]);
            _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
            idle_deadline = @as(i64, ts.tv_sec) * 1000 + @divTrunc(ts.tv_nsec, 1_000_000) + idle_ms;
        }
    }

    /// Half-arrived frame in the receive buffer, if any — for
    /// timeout diagnostics ("2.1 MB of an 8.3 MB frame buffered").
    pub fn pendingPartial(self: *const Conn) ?struct { expected: usize, have: usize } {
        const p = wire.partialInfo(self.rbuf.items) orelse return null;
        return .{ .expected = p.expected, .have = p.have };
    }

    /// Deadline-aware `recvExpect`; error.Timeout applies to the WHOLE
    /// wait, however many unrelated frames arrive meanwhile.
    pub fn recvExpectFor(self: *Conn, want: []const wire.FrameType, timeout_ms: i64) !OwnedFrame {
        var ts: c.struct_timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
        const deadline = @as(i64, ts.tv_sec) * 1000 + @divTrunc(ts.tv_nsec, 1_000_000) + timeout_ms;
        while (true) {
            _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
            const remain = deadline - (@as(i64, ts.tv_sec) * 1000 + @divTrunc(ts.tv_nsec, 1_000_000));
            if (remain <= 0) return error.Timeout;
            const f = try self.recvFrameFor(remain);
            for (want) |w| {
                if (f.ftype == w) return f;
            }
            if (f.ftype == .err) {
                const msg = errFieldOf(f.payload);
                const n = @min(msg.len, self.last_err.len);
                @memcpy(self.last_err[0..n], msg[0..n]);
                self.last_err_len = n;
                f.deinit(self.allocator);
                return error.DaemonError;
            }
            f.deinit(self.allocator);
        }
    }

    /// Peel one complete frame out of the read buffer, or null when what is
    /// buffered so far is only PART of a frame. Never touches the fd, so it
    /// cannot block.
    pub fn takeFrame(self: *Conn) !?OwnedFrame {
        const peeled = (try wire.peelFrame(self.rbuf.items)) orelse return null;
        const owned = try self.allocator.dupe(u8, peeled.frame.payload);
        wire.compactConsumed(&self.rbuf, peeled.consumed);
        // One big frame (a multi-MB window buffer) must not pin its
        // high-water capacity for the connection's lifetime.
        if (self.rbuf.items.len == 0 and self.rbuf.capacity > (4 << 20))
            self.rbuf.clearAndFree(self.allocator);
        return .{ .ftype = peeled.frame.ftype, .payload = owned };
    }

    /// Top the read buffer up with whatever bytes have already arrived, without
    /// blocking. Returns false only if the peer hung up.
    ///
    /// This exists because recvFrame's read() BLOCKS: a big frame (an 8 MB window
    /// buffer, say) arrives in many chunks, so "the fd is readable" does NOT mean a
    /// whole frame is there. A caller that only wants what is already queued must
    /// not be made to wait for a tail that may never come.
    pub fn fillAvailable(self: *Conn) bool {
        // Byte budget: a peer that streams faster than we consume
        // (video-playing app at full tilt) keeps the fd readable
        // FOREVER — without a cap this loop never returns and the
        // caller's own deadline (checked between calls) never fires.
        var budget: usize = 4 << 20;
        while (true) {
            var pfd = c.struct_pollfd{ .fd = self.fd, .events = c.POLLIN, .revents = 0 };
            const polled = c.poll(&pfd, 1, 0);
            if (polled < 0) {
                if (std.posix.errno(polled) == .INTR) continue;
                return false;
            }
            if (polled == 0) return true;
            if ((pfd.revents & (c.POLLIN | c.POLLHUP)) == 0) return true;
            var tmp: [16384]u8 = undefined;
            const n = c.read(self.fd, &tmp, tmp.len);
            if (n == 0) return false;
            if (n < 0) {
                const e = std.posix.errno(n);
                if (e == .INTR) continue;
                if (e == .AGAIN) return true;
                return false;
            }
            self.rbuf.appendSlice(self.allocator, tmp[0..@intCast(n)]) catch return false;
            if (@as(usize, @intCast(n)) < tmp.len) return true; // drained the socket
            if (budget <= @as(usize, @intCast(n))) return true; // cap hit; rest next pump
            budget -= @intCast(n);
        }
    }

    /// Receive frames until one of `want` arrives; frames of other
    /// types are discarded (e.g. EVENTS noise while waiting for an
    /// OK). On an `err` frame (not in `want`) it stashes the daemon's
    /// message in `self.last_err` and returns `error.DaemonError` —
    /// read `lastErr()` to surface WHY instead of a bare error name.
    pub fn recvExpect(self: *Conn, want: []const wire.FrameType) !OwnedFrame {
        while (true) {
            const f = try self.recvFrame();
            for (want) |w| {
                if (f.ftype == w) return f;
            }
            if (f.ftype == .err) {
                const msg = errFieldOf(f.payload);
                const n = @min(msg.len, self.last_err.len);
                @memcpy(self.last_err[0..n], msg[0..n]);
                self.last_err_len = n;
                f.deinit(self.allocator);
                return error.DaemonError;
            }
            f.deinit(self.allocator);
        }
    }

    /// The message from the last `.err` frame `recvExpect` saw.
    pub fn lastErr(self: *const Conn) []const u8 {
        return self.last_err[0..self.last_err_len];
    }
};

/// Connect to one exact daemon and complete the panel-only handshake against
/// one absolute deadline; this path never autostarts or replaces a daemon.
fn connectPanelRequesterUntil(
    allocator: std.mem.Allocator,
    sock_path: []const u8,
    session: []const u8,
    deadline_ms: i64,
    active_fd: ?*FdCancel,
) !Conn {
    return connectPanelRequesterUntilExpected(allocator, sock_path, session, "", deadline_ms, active_fd);
}

/// Publish this connection attempt's fd on the caller's cancellation slot.
///
/// @return error.Canceled when the slot was already stopped, so an
/// operation cancelled between allocating the socket and publishing it
/// gives up here instead of blocking on a descriptor nobody can reach.
fn clearPanelRequesterFd(slot: ?*FdCancel) void {
    const active = slot orelse return;
    active.release();
}

fn publishPanelRequesterFd(slot: ?*FdCancel, source_fd: c_int) !void {
    const active = slot orelse return;
    if (!try active.publish(source_fd)) return error.Canceled;
}

fn classifyPanelRequesterAttachError(conn: *const Conn, err: anyerror) anyerror {
    if (err != error.DaemonError) return err;
    if (std.mem.eql(u8, conn.lastErr(), "no such session")) return error.PanelSessionNotFound;
    if (std.mem.eql(u8, conn.lastErr(), "session origin identity changed"))
        return error.SessionOriginMismatch;
    return err;
}

/// Errors that prove the requested session lifetime is absent at this daemon.
pub fn panelRequesterKnownAbsent(err: anyerror) bool {
    return err == error.PanelSessionNotFound or err == error.SessionOriginMismatch;
}

/// Panel-only attach with an optional immutable lifetime fence.
pub fn connectPanelRequesterUntilExpected(
    allocator: std.mem.Allocator,
    sock_path: []const u8,
    session: []const u8,
    expected_origin_id: []const u8,
    deadline_ms: i64,
    active_fd: ?*FdCancel,
) !Conn {
    if (deadline_ms - monotonicMs() <= 0) return error.Timeout;
    const fd = @import("../util/platform.zig").socketCloexec(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    var fd_owned = true;
    errdefer {
        if (fd_owned) _ = c.close(fd);
    }
    try publishPanelRequesterFd(active_fd, fd);
    defer clearPanelRequesterFd(active_fd);

    const flags = c.fcntl(fd, c.F_GETFL);
    if (flags < 0 or c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK) != 0)
        return error.NonBlockingFailed;
    var addr: c.struct_sockaddr_un = undefined;
    try sockpath.fillSockaddrUn(&addr, sock_path);
    if (deadline_ms - monotonicMs() <= 0) return error.Timeout;
    const rc = c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un));
    if (rc != 0) {
        const connect_errno = std.posix.errno(rc);
        if (connect_errno != .INPROGRESS and connect_errno != .AGAIN and connect_errno != .ALREADY)
            return error.ConnectFailed;
        while (true) {
            const remain = deadline_ms - monotonicMs();
            if (remain <= 0) return error.Timeout;
            var pfd = c.struct_pollfd{ .fd = fd, .events = c.POLLOUT, .revents = 0 };
            const polled = c.poll(&pfd, 1, @intCast(@min(remain, 100)));
            if (polled < 0 and std.posix.errno(polled) == .INTR) continue;
            if (polled < 0) return error.ConnectFailed;
            if (polled == 0) continue;
            break;
        }
    }
    // POLLOUT only means connect completed, not that it succeeded.
    var socket_error: c_int = 0;
    var socket_error_len: c.socklen_t = @sizeOf(c_int);
    if (c.getsockopt(fd, c.SOL_SOCKET, c.SO_ERROR, &socket_error, &socket_error_len) != 0 or socket_error != 0)
        return error.ConnectFailed;

    var conn = Conn{ .allocator = allocator, .fd = fd };
    fd_owned = false;
    errdefer conn.deinit();
    try conn.queueHelloUntil(deadline_ms);
    var remain = deadline_ms - monotonicMs();
    if (remain <= 0) return error.Timeout;
    const welcome = try conn.recvExpectFor(&.{.welcome}, remain);
    defer welcome.deinit(allocator);
    conn.applyWelcome(allocator, welcome.payload);
    const identity_support = panelIdentitySupport(allocator, welcome.payload) catch
        return error.MalformedPanelWelcome;
    if (identity_support == .legacy) return error.LegacyPanelIdentityUnsupported;
    if (identity_support == .unsupported) return error.PanelRpcUnsupported;
    try conn.queueJsonUntil(.attach, .{
        .name = session,
        .origin_id = expected_origin_id,
        .kind = "mcp",
        .read_only = true,
        .control = false,
        .panel_only = true,
        .panel_rpc = wire.PANEL_RPC_VERSION,
    }, deadline_ms);
    remain = deadline_ms - monotonicMs();
    if (remain <= 0) return error.Timeout;
    const ok = conn.recvExpectFor(&.{.ok}, remain) catch |err|
        return classifyPanelRequesterAttachError(&conn, err);
    defer ok.deinit(allocator);
    const Attached = struct {
        ok: bool = false,
        panel_only: bool = false,
        origin_name: ?[]const u8 = null,
        origin_id: ?[]const u8 = null,
    };
    var parsed = std.json.parseFromSlice(Attached, allocator, ok.payload, .{
        .ignore_unknown_fields = true,
    }) catch return error.MalformedPanelAttachMetadata;
    defer parsed.deinit();
    const origin_name = parsed.value.origin_name orelse return error.MalformedPanelAttachMetadata;
    const origin_id = parsed.value.origin_id orelse return error.MalformedPanelAttachMetadata;
    if (!parsed.value.ok or !parsed.value.panel_only or origin_name.len == 0 or
        origin_name.len > conn.panel_origin_name.len or !wire.validSessionOriginId(origin_id))
        return error.MalformedPanelAttachMetadata;
    if (expected_origin_id.len > 0 and !std.mem.eql(u8, expected_origin_id, origin_id))
        return error.SessionOriginMismatch;
    conn.panel_origin_name_len = origin_name.len;
    @memcpy(conn.panel_origin_name[0..conn.panel_origin_name_len], origin_name);
    @memcpy(&conn.panel_origin_id, origin_id);
    conn.panel_origin_id_valid = true;
    return conn;
}

const PanelIdentitySupport = enum { current, legacy, unsupported };

/// Classify a valid daemon welcome without treating malformed capability data as legacy.
fn panelIdentitySupport(allocator: std.mem.Allocator, payload: []const u8) !PanelIdentitySupport {
    const Welcome = struct {
        proto: ?u32 = null,
        panel_rpc: ?u8 = null,
        attach_identity: ?bool = null,
    };
    var parsed = try std.json.parseFromSlice(Welcome, allocator, payload, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    if (parsed.value.proto == null) return error.MalformedPanelWelcome;
    const panel_rpc = parsed.value.panel_rpc orelse 0;
    if (panel_rpc >= wire.PANEL_RPC_VERSION) return .current;
    if (!(parsed.value.attach_identity orelse false)) return .legacy;
    return .unsupported;
}

test "panel identity support requires a valid positive capability classification" {
    const t = std.testing;
    try t.expectEqual(
        PanelIdentitySupport.legacy,
        try panelIdentitySupport(t.allocator, "{\"proto\":6,\"server_proto\":6,\"negotiation\":1}"),
    );
    try t.expectEqual(
        PanelIdentitySupport.unsupported,
        try panelIdentitySupport(t.allocator, "{\"proto\":6,\"panel_rpc\":0,\"attach_identity\":true}"),
    );
    try t.expectEqual(
        PanelIdentitySupport.unsupported,
        try panelIdentitySupport(t.allocator, "{\"proto\":6,\"panel_rpc\":1,\"attach_identity\":true}"),
    );
    try t.expectEqual(
        PanelIdentitySupport.current,
        try panelIdentitySupport(t.allocator, "{\"proto\":6,\"panel_rpc\":2,\"attach_identity\":true}"),
    );
    try t.expectError(error.MalformedPanelWelcome, panelIdentitySupport(t.allocator, "{}"));
    try t.expectError(error.SyntaxError, panelIdentitySupport(t.allocator, "not-json"));
}

/// Relative-time convenience wrapper for non-MCP callers.
pub fn connectPanelRequester(allocator: std.mem.Allocator, sock_path: []const u8, session: []const u8, timeout_ms: i64) !Conn {
    var active: FdCancel = .{};
    // The connect helper releases the slot itself; this local exists
    // only because these callers have no watchdog to hand it.
    return connectPanelRequesterUntil(allocator, sock_path, session, monotonicMs() + @max(timeout_ms, 0), &active);
}

test "panel requester connect, hello, and attach share one absolute deadline" {
    const t = std.testing;
    var path_buf: [256:0]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/sketerm-panel-connect-deadline-{d}.sock", .{c.getpid()});
    _ = c.unlink(path.ptr);
    defer _ = c.unlink(path.ptr);
    const listener = @import("../util/platform.zig").socketCloexec(c.AF_UNIX, c.SOCK_STREAM, 0);
    try t.expect(listener >= 0);
    defer _ = c.close(listener);
    var addr: c.struct_sockaddr_un = undefined;
    try sockpath.fillSockaddrUn(&addr, path);
    try t.expectEqual(@as(c_int, 0), c.bind(listener, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)));
    try t.expectEqual(@as(c_int, 0), c.listen(listener, 1));

    const Stall = struct {
        fd: c_int,
        fn run(self: @This()) void {
            const accepted = c.accept(self.fd, null, null);
            if (accepted < 0) return;
            defer _ = c.close(accepted);
            var buf: [256]u8 = undefined;
            _ = c.read(accepted, &buf, buf.len);
            _ = c.usleep(250_000);
        }
    };
    const thread = try std.Thread.spawn(.{}, Stall.run, .{Stall{ .fd = listener }});
    defer thread.join();
    var active: FdCancel = .{};
    const start = monotonicMs();
    try t.expectError(
        error.Timeout,
        connectPanelRequesterUntil(t.allocator, path, "session", start + 75, &active),
    );
    try t.expect(monotonicMs() - start < 500);
    try t.expectEqual(@as(c_int, -1), active.fd.load(.acquire));
}

test "a panel connect that lost the stop race is cancelled before it dials" {
    const t = std.testing;
    // The watchdog fired between allocating this call's socket and
    // publishing it. Without the stop latch the duplicate is published
    // into a slot nobody will ever claim again and the connect runs on
    // to its full deadline unreachable by any cancel.
    var active: FdCancel = .{};
    active.stop();
    var path_buf: [256:0]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/sketerm-panel-stopped-{d}.sock", .{c.getpid()});
    _ = c.unlink(path.ptr);
    defer _ = c.unlink(path.ptr);
    const listener = try panelAttachListener(path);
    defer _ = c.close(listener);
    try t.expectError(
        error.Canceled,
        connectPanelRequesterUntil(t.allocator, path, "session", monotonicMs() + 5_000, &active),
    );
    try t.expectEqual(@as(c_int, -1), active.fd.load(.acquire));
}

test "expired panel deadlines cannot connect flush or send initial bytes" {
    const t = std.testing;
    var active: FdCancel = .{};
    try t.expectError(
        error.Timeout,
        connectPanelRequesterUntil(t.allocator, "/tmp/expired-panel.sock", "session", monotonicMs() - 1, &active),
    );
    try t.expectEqual(@as(c_int, -1), active.fd.load(.acquire));

    var pair: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &pair));
    defer _ = c.close(pair[1]);
    var conn = Conn{
        .allocator = t.allocator,
        .fd = pair[0],
        .panel_rpc = wire.PANEL_RPC_VERSION,
    };
    defer conn.deinit();
    conn.setNonBlocking();

    try wire.appendFrame(&conn.wbuf, t.allocator, .hello, "queued-before-expiry");
    try t.expectError(error.Timeout, conn.flushQueuedUntil(monotonicMs() - 1));
    var pfd = c.struct_pollfd{ .fd = pair[1], .events = c.POLLIN, .revents = 0 };
    try t.expectEqual(@as(c_int, 0), c.poll(&pfd, 1, 0));
    conn.wbuf.clearRetainingCapacity();

    try t.expectError(
        error.PanelSendPreDelivery,
        conn.sendPanelRequestUntil(7, "{\"cmd\":\"panel-events\"}", monotonicMs() - 1),
    );
    pfd.revents = 0;
    try t.expectEqual(@as(c_int, 0), c.poll(&pfd, 1, 0));
}

const PanelAttachReplyScript = struct {
    listener: c_int,
    reply: []const u8,
    ftype: wire.FrameType = .ok,

    fn run(self: PanelAttachReplyScript) void {
        const accepted = c.accept(self.listener, null, null);
        if (accepted < 0) return;
        var peer = Conn{ .allocator = std.heap.c_allocator, .fd = accepted };
        defer peer.deinit();
        const hello = peer.recvExpect(&.{.hello}) catch return;
        hello.deinit(peer.allocator);
        peer.sendFrame(.welcome, "{\"proto\":0,\"server_proto\":6,\"negotiation\":1,\"panel_rpc\":2}") catch return;
        const attach = peer.recvExpect(&.{.attach}) catch return;
        attach.deinit(peer.allocator);
        peer.sendFrame(self.ftype, self.reply) catch return;
    }
};

fn panelAttachListener(path: [:0]const u8) !c_int {
    const listener = @import("../util/platform.zig").socketCloexec(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (listener < 0) return error.SocketFailed;
    errdefer _ = c.close(listener);
    var addr: c.struct_sockaddr_un = undefined;
    try sockpath.fillSockaddrUn(&addr, path);
    if (c.bind(listener, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0)
        return error.BindFailed;
    if (c.listen(listener, 1) != 0) return error.ListenFailed;
    return listener;
}

test "panel-only attach rejects missing empty and truncated immutable origin metadata" {
    const t = std.testing;
    const replies = [_][]const u8{
        "{\"ok\":true,\"panel_only\":true}",
        "{\"ok\":true,\"panel_only\":true,\"origin_name\":\"valid\"}",
        "{\"ok\":true,\"panel_only\":true,\"origin_name\":\"\",\"origin_id\":\"00000000000000000000000000000001\"}",
        "{\"ok\":true,\"panel_only\":true,\"origin_name\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"origin_id\":\"00000000000000000000000000000001\"}",
        "{\"ok\":true,\"panel_only\":false,\"origin_name\":\"valid\",\"origin_id\":\"00000000000000000000000000000001\"}",
    };
    for (replies, 0..) |reply, i| {
        var path_buf: [256:0]u8 = undefined;
        const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/sketerm-panel-metadata-{d}-{d}.sock", .{ c.getpid(), i });
        _ = c.unlink(path.ptr);
        defer _ = c.unlink(path.ptr);
        const listener = try panelAttachListener(path);
        defer _ = c.close(listener);
        const thread = try std.Thread.spawn(.{}, PanelAttachReplyScript.run, .{PanelAttachReplyScript{
            .listener = listener,
            .reply = reply,
        }});
        var active: FdCancel = .{};
        try t.expectError(
            error.MalformedPanelAttachMetadata,
            connectPanelRequesterUntil(t.allocator, path, "requested-alias", monotonicMs() + 2_000, &active),
        );
        thread.join();
        try t.expectEqual(@as(c_int, -1), active.fd.load(.acquire));
    }
}

test "panel-only attach reports a valid unexpected origin id as an identity mismatch" {
    const t = std.testing;
    var path_buf: [256:0]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/sketerm-panel-id-mismatch-{d}.sock", .{c.getpid()});
    _ = c.unlink(path.ptr);
    defer _ = c.unlink(path.ptr);
    const listener = try panelAttachListener(path);
    defer _ = c.close(listener);
    const thread = try std.Thread.spawn(.{}, PanelAttachReplyScript.run, .{PanelAttachReplyScript{
        .listener = listener,
        .reply = "{\"ok\":true,\"panel_only\":true,\"origin_name\":\"replacement\",\"origin_id\":\"20000000000000000000000000000002\"}",
    }});
    var active: FdCancel = .{};
    try t.expectError(
        error.SessionOriginMismatch,
        connectPanelRequesterUntilExpected(
            t.allocator,
            path,
            "reused",
            "10000000000000000000000000000001",
            monotonicMs() + 2_000,
            &active,
        ),
    );
    thread.join();
    try t.expectEqual(@as(c_int, -1), active.fd.load(.acquire));
}

test "panel-only attach returns a typed no-such-session error" {
    const t = std.testing;
    var path_buf: [256:0]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/sketerm-panel-no-session-{d}.sock", .{c.getpid()});
    _ = c.unlink(path.ptr);
    defer _ = c.unlink(path.ptr);
    const listener = try panelAttachListener(path);
    defer _ = c.close(listener);
    const thread = try std.Thread.spawn(.{}, PanelAttachReplyScript.run, .{PanelAttachReplyScript{
        .listener = listener,
        .reply = "{\"error\":\"no such session\"}",
        .ftype = .err,
    }});
    var active: FdCancel = .{};
    try t.expectError(
        error.PanelSessionNotFound,
        connectPanelRequesterUntilExpected(
            t.allocator,
            path,
            "gone",
            "10000000000000000000000000000001",
            monotonicMs() + 2_000,
            &active,
        ),
    );
    thread.join();
    try t.expectEqual(@as(c_int, -1), active.fd.load(.acquire));
}

test "panel requester attach errors preserve daemon diagnostics and classify known absence" {
    const t = std.testing;
    var pair: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &pair));
    var conn = Conn{ .allocator = t.allocator, .fd = pair[0] };
    defer conn.deinit();
    var peer = Conn{ .allocator = t.allocator, .fd = pair[1] };
    defer peer.deinit();
    try peer.sendFrame(.err, "{\"error\":\"no such session\"}");
    var recv_err: ?anyerror = null;
    if (conn.recvExpectFor(&.{.ok}, 1_000)) |frame| {
        frame.deinit(t.allocator);
        return error.TestUnexpectedResult;
    } else |err| recv_err = err;
    try t.expectEqual(error.DaemonError, recv_err.?);
    try t.expectEqualStrings("no such session", conn.lastErr());
    const classified = classifyPanelRequesterAttachError(&conn, recv_err.?);
    try t.expectEqual(error.PanelSessionNotFound, classified);
    try t.expect(panelRequesterKnownAbsent(classified));
    try t.expectEqualStrings("no such session", conn.lastErr());

    conn.last_err_len = "session origin identity changed".len;
    @memcpy(conn.last_err[0..conn.last_err_len], "session origin identity changed");
    const mismatch = classifyPanelRequesterAttachError(&conn, error.DaemonError);
    try t.expectEqual(error.SessionOriginMismatch, mismatch);
    try t.expect(panelRequesterKnownAbsent(mismatch));
    try t.expectEqualStrings("session origin identity changed", conn.lastErr());
    try t.expect(!panelRequesterKnownAbsent(error.DaemonError));
}

test "panel-only attach preserves an exact maximum-length immutable origin" {
    const t = std.testing;
    const reply = "{\"ok\":true,\"panel_only\":true,\"origin_name\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"origin_id\":\"00000000000000000000000000000001\"}";
    var path_buf: [256:0]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/sketerm-panel-metadata-max-{d}.sock", .{c.getpid()});
    _ = c.unlink(path.ptr);
    defer _ = c.unlink(path.ptr);
    const listener = try panelAttachListener(path);
    defer _ = c.close(listener);
    const thread = try std.Thread.spawn(.{}, PanelAttachReplyScript.run, .{PanelAttachReplyScript{
        .listener = listener,
        .reply = reply,
    }});
    var conn = try connectPanelRequester(t.allocator, path, "requested-alias", 2_000);
    defer conn.deinit();
    thread.join();
    try t.expectEqual(@as(usize, 64), conn.panelOrigin().len);
    try t.expectEqualStrings("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", conn.panelOrigin());
    try t.expectEqualStrings("00000000000000000000000000000001", conn.panelOriginId());
}

test "local daemon origin is the exact connected listener, never a default guess" {
    const t = std.testing;
    var path_buf: [256:0]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/sketerm-panel-peer-{d}.sock", .{c.getpid()});
    _ = c.unlink(path.ptr);
    defer _ = c.unlink(path.ptr);
    const listener = @import("../util/platform.zig").socketCloexec(c.AF_UNIX, c.SOCK_STREAM, 0);
    try t.expect(listener >= 0);
    defer _ = c.close(listener);
    var addr: c.struct_sockaddr_un = undefined;
    try sockpath.fillSockaddrUn(&addr, path);
    try t.expectEqual(@as(c_int, 0), c.bind(listener, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)));
    try t.expectEqual(@as(c_int, 0), c.listen(listener, 1));

    var conn = try Conn.connect(t.allocator, path);
    defer conn.deinit();
    const accepted = c.accept(listener, null, null);
    try t.expect(accepted >= 0);
    defer _ = c.close(accepted);
    const origin = try conn.localDaemonOrigin(t.allocator);
    defer t.allocator.free(origin);
    try t.expectEqualStrings(path, origin);

    var pair: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &pair));
    var unnamed = Conn{ .allocator = t.allocator, .fd = pair[0] };
    defer unnamed.deinit();
    defer _ = c.close(pair[1]);
    try t.expectError(error.BadPath, unnamed.localDaemonOrigin(t.allocator));
}

/// True when `fd` appears in a child's `ls /dev/fd` listing, i.e. the
/// child inherited it across exec.
fn listingHasFd(listing: []const u8, fd: c_int) bool {
    var it = std.mem.tokenizeAny(u8, listing, " \t\r\n");
    while (it.next()) |tok| {
        const n = std.fmt.parseInt(c_int, tok, 10) catch continue;
        if (n == fd) return true;
    }
    return false;
}

test "transport fd is close-on-exec so it cannot leak into a later child" {
    // Regression: socketpair() without SOCK_CLOEXEC handed every transport
    // socket to every child spawned afterwards (proxy N held N-1 foreign
    // sockets, confirmed via /proc/<pid>/fd). The peer of an old connection
    // then cannot see EOF until the last of those children exits, so a dead
    // GUI's durable sessions stay attached on the daemon.
    //
    // The stand-in is RESOLVED, not hardcoded: macOS ships `true` at
    // /usr/bin only. With /bin/true the execvp simply failed here, the
    // parent still got its socketpair back, and the FD_CLOEXEC assertion
    // passed with NO CHILD EVER RUNNING -- green for the wrong reason.
    // So the test now also spawns a real child and reads what it
    // inherited: the flag bit is the mechanism, the listing is the
    // consequence, and only the second one is what the regression broke.
    const t = std.testing;
    const a = t.allocator;
    const stand_in = blk: {
        for ([_][*:0]const u8{ "/bin/true", "/usr/bin/true" }) |cand| {
            if (c.access(cand, c.X_OK) == 0) break :blk cand;
        }
        return error.NoTrueBinary;
    };
    var conn = try Conn.spawnOverSocketpair(a, stand_in, &[_:null]?[*:0]const u8{ stand_in, null });
    defer conn.deinit();
    const flags = c.fcntl(conn.fd, c.F_GETFD);
    try t.expect(flags >= 0);
    try t.expect(flags & c.FD_CLOEXEC != 0);

    // Two dups of that same socket, parked at fd numbers no shell will
    // reuse: one left inheritable, one marked cloexec. A later child must
    // see the first and not the second. The inheritable one is the
    // POSITIVE CONTROL -- without it, "absent from the listing" could just
    // mean the listing never worked. Low fd numbers cannot be used for
    // this: the child's own `ls` opens a directory fd and would land on
    // whatever number the cloexec'd socket vacated.
    const leaked = c.fcntl(conn.fd, c.F_DUPFD, @as(c_int, 60));
    try t.expect(leaked >= 60);
    defer _ = c.close(leaked);
    const guarded = c.fcntl(conn.fd, c.F_DUPFD, @as(c_int, 70));
    try t.expect(guarded >= 70);
    defer _ = c.close(guarded);
    try t.expectEqual(@as(c_int, 0), c.fcntl(guarded, c.F_SETFD, c.FD_CLOEXEC));

    const sh: [*:0]const u8 = "/bin/sh";
    var probe = try Conn.spawnOverSocketpair(a, sh, &[_:null]?[*:0]const u8{ sh, "-c", "ls /dev/fd", null });
    defer probe.deinit();
    var buf: [8192]u8 = undefined;
    var used: usize = 0;
    while (used < buf.len) {
        const n = c.read(probe.fd, buf[used..].ptr, buf.len - used);
        if (n <= 0) break;
        used += @intCast(n);
    }
    const listing = buf[0..used];
    try t.expect(listingHasFd(listing, leaked));
    try t.expect(!listingHasFd(listing, guarded));
}

test "remote transport specs default to auto and preserve forced modes" {
    const t = std.testing;
    const automatic = RemoteSpec.parse("user@box");
    try t.expectEqual(RemoteMode.auto, automatic.mode);
    try t.expectEqualStrings("user@box", automatic.host);
    const udp = RemoteSpec.parse("udp:user@box");
    try t.expectEqual(RemoteMode.udp, udp.mode);
    try t.expectEqualStrings("user@box", udp.host);
    const ssh = RemoteSpec.parse("ssh:user@box");
    try t.expectEqual(RemoteMode.ssh, ssh.mode);
    try t.expectEqualStrings("user@box", ssh.host);
}

fn fakeUdpSuccess(allocator: std.mem.Allocator, host: []const u8, _: ?[]const u8) !Conn {
    if (!std.mem.eql(u8, host, "box")) return error.BadPath;
    return .{ .allocator = allocator, .fd = -1, .transport = .udp };
}

fn fakeUdpFailure(_: std.mem.Allocator, _: []const u8, _: ?[]const u8) !Conn {
    return error.SshTransportFailed;
}

fn fakeSshSuccess(allocator: std.mem.Allocator, host: []const u8, _: ?[]const u8) !Conn {
    if (!std.mem.eql(u8, host, "box")) return error.BadPath;
    return .{ .allocator = allocator, .fd = -1, .transport = .ssh };
}

test "automatic remote transport prefers UDP and falls back to SSH" {
    const t = std.testing;
    const udp = try Conn.connectRemoteUsing(t.allocator, "box", null, fakeUdpSuccess, fakeUdpSuccess, fakeSshSuccess);
    try t.expectEqual(Transport.udp, udp.transport);
    const ssh = try Conn.connectRemoteUsing(t.allocator, "box", null, fakeUdpFailure, fakeUdpFailure, fakeSshSuccess);
    try t.expectEqual(Transport.ssh, ssh.transport);
}

test "explicit remote transport never falls back" {
    const t = std.testing;
    try t.expectError(
        error.SshTransportFailed,
        Conn.connectRemoteUsing(t.allocator, "udp:box", null, fakeUdpFailure, fakeUdpFailure, fakeSshSuccess),
    );
    const ssh = try Conn.connectRemoteUsing(t.allocator, "ssh:box", null, fakeUdpSuccess, fakeUdpSuccess, fakeSshSuccess);
    try t.expectEqual(Transport.ssh, ssh.transport);
}

test "auto fallback records why UDP was not used" {
    const t = std.testing;
    const ssh = try Conn.connectRemoteUsing(t.allocator, "box", null, fakeUdpFailure, fakeUdpFailure, fakeSshSuccess);
    try t.expectEqual(Transport.ssh, ssh.transport);
    try t.expectEqual(@as(?anyerror, error.SshTransportFailed), ssh.udp_error);

    // A UDP connection and a forced transport must not claim a cause.
    const udp = try Conn.connectRemoteUsing(t.allocator, "box", null, fakeUdpSuccess, fakeUdpSuccess, fakeSshSuccess);
    try t.expectEqual(@as(?anyerror, null), udp.udp_error);
    const forced = try Conn.connectRemoteUsing(t.allocator, "ssh:box", null, fakeUdpSuccess, fakeUdpSuccess, fakeSshSuccess);
    try t.expectEqual(@as(?anyerror, null), forced.udp_error);
}

test "ssh -G output resolves an alias to its real hostname" {
    const t = std.testing;
    var buf: [256]u8 = undefined;
    // Trimmed but faithful `ssh -G vastai` output: the alias the user
    // typed appears nowhere, only the resolved HostName.
    const out = Conn.parseSshConfigOutput(
        \\user root
        \\hostname ssh5.vast.ai
        \\port 41234
        \\forwardagent no
        \\
    , &buf) orelse return error.TestUnexpectedResult;
    try t.expectEqualStrings("ssh5.vast.ai", out.hostname);
    try t.expect(!out.proxied);
}

test "ssh -G output flags proxied hosts as UDP-ineligible" {
    const t = std.testing;
    var buf: [256]u8 = undefined;
    const jump = Conn.parseSshConfigOutput(
        "hostname inner.example\nproxyjump bastion\n",
        &buf,
    ) orelse return error.TestUnexpectedResult;
    try t.expect(jump.proxied);

    const cmd = Conn.parseSshConfigOutput(
        "hostname inner.example\nproxycommand nc %h %p\n",
        &buf,
    ) orelse return error.TestUnexpectedResult;
    try t.expect(cmd.proxied);

    // "none" is how some OpenSSH versions spell "unset".
    const none = Conn.parseSshConfigOutput(
        "hostname plain.example\nproxycommand none\n",
        &buf,
    ) orelse return error.TestUnexpectedResult;
    try t.expect(!none.proxied);
    try t.expectEqualStrings("plain.example", none.hostname);
}

test "ssh config resolution spawns ssh and reads back the hostname" {
    // Covers the fork/exec/read half that the parser tests cannot:
    // SKETERM_SSH swaps in a fake that answers -G like OpenSSH.
    var path_buf: [128:0]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/tmp/sketerm-fake-ssh-{d}", .{c.getpid()}) catch unreachable;
    const f = c.fopen(path.ptr, "w") orelse return error.SkipZigTest;
    _ = c.fputs("#!/bin/sh\nif [ \"$1\" = \"-G\" ]; then printf 'user root\\nhostname 10.1.2.3\\nport 2222\\n'; fi\n", f);
    _ = c.fclose(f);
    if (c.chmod(path.ptr, 0o755) != 0) return error.SkipZigTest;
    defer _ = c.unlink(path.ptr);

    _ = c.setenv("SKETERM_SSH", path.ptr, 1);
    defer _ = c.unsetenv("SKETERM_SSH");

    var buf: [256]u8 = undefined;
    const target = Conn.resolveSshConfig("some-alias", &buf, monotonicMs() + 5_000) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("10.1.2.3", target.hostname);
    try std.testing.expect(!target.proxied);
}

test "UDP bootstrap sends the punch line with the pre-bound port on ssh stdin" {
    // Fake ssh: answers -G, then captures one stdin line and prints
    // no announcement — connectUdpFor must fail SshTransportFailed
    // AFTER having already written "SKETERM-PUNCH <port>".
    var cap_buf: [128:0]u8 = undefined;
    const cap = std.fmt.bufPrintZ(&cap_buf, "/tmp/sketerm-punch-cap-{d}", .{c.getpid()}) catch unreachable;
    var path_buf: [128:0]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/tmp/sketerm-fake-ssh-punch-{d}", .{c.getpid()}) catch unreachable;
    const f = c.fopen(path.ptr, "w") orelse return error.SkipZigTest;
    var script_buf: [512:0]u8 = undefined;
    const script = std.fmt.bufPrintZ(
        &script_buf,
        "#!/bin/sh\nif [ \"$1\" = \"-G\" ]; then printf 'hostname 127.0.0.1\\n'; exit 0; fi\nIFS= read -r line\nprintf '%s\\n' \"$line\" > {s}\n",
        .{cap},
    ) catch unreachable;
    _ = c.fputs(script.ptr, f);
    _ = c.fclose(f);
    if (c.chmod(path.ptr, 0o755) != 0) return error.SkipZigTest;
    defer _ = c.unlink(path.ptr);
    defer _ = c.unlink(cap.ptr);

    _ = c.setenv("SKETERM_SSH", path.ptr, 1);
    defer _ = c.unsetenv("SKETERM_SSH");

    try std.testing.expectError(
        error.SshTransportFailed,
        Conn.connectUdpFor(std.testing.allocator, "punch-test-host", null, 1_000),
    );

    const cf = c.fopen(cap.ptr, "r") orelse return error.TestUnexpectedResult;
    defer _ = c.fclose(cf);
    var line: [64]u8 = undefined;
    const n = c.fread(&line, 1, line.len, cf);
    const punch = @import("punch.zig");
    const nl = std.mem.indexOfScalar(u8, line[0..n], '\n') orelse return error.TestUnexpectedResult;
    const port = punch.parseLine(line[0 .. nl + 1]) orelse return error.TestUnexpectedResult;
    try std.testing.expect(port != 0);
}

test "ssh -G output without a hostname yields no target" {
    var buf: [256]u8 = undefined;
    try std.testing.expect(Conn.parseSshConfigOutput("user root\nport 22\n", &buf) == null);
}

test "remote transports reject option-shaped hosts" {
    try std.testing.expectError(
        error.BadPath,
        Conn.connectRemoteUsing(std.testing.allocator, "-oProxyCommand=bad", null, fakeUdpSuccess, fakeUdpSuccess, fakeSshSuccess),
    );
}

test "welcome records older and future daemon profiles without rejecting either" {
    const a = std.testing.allocator;
    var conn = Conn{ .allocator = a, .fd = -1 };
    conn.applyWelcome(a, "{\"proto\":5}");
    try std.testing.expectEqual(@as(u32, 5), conn.proto);
    try std.testing.expectEqual(@as(u32, 5), conn.server_proto);
    conn.applyWelcome(a, "{\"proto\":6,\"server_proto\":9,\"negotiation\":1}");
    try std.testing.expectEqual(@as(u32, 6), conn.proto);
    try std.testing.expectEqual(@as(u32, 9), conn.server_proto);
    try std.testing.expect(!conn.durable_copy);
    try std.testing.expect(!conn.kill_origin_fence);
    conn.applyWelcome(a, "{\"proto\":6,\"server_proto\":9,\"negotiation\":1,\"durable_copy\":true,\"copy_no_replace\":true,\"durable_copy_v2\":true}");
    try std.testing.expect(conn.durable_copy);
    try std.testing.expect(conn.copy_no_replace);
    try std.testing.expect(conn.durable_copy_v2);
    conn.applyWelcome(a, "{\"proto\":6,\"server_proto\":9,\"negotiation\":1,\"kill_origin_fence\":true}");
    try std.testing.expect(conn.kill_origin_fence);
    conn.applyWelcome(a, "{\"proto\":0,\"server_proto\":9,\"negotiation\":1}");
    try std.testing.expectEqual(@as(u32, 0), conn.proto);
    try std.testing.expectEqual(@as(u8, 0), conn.panel_rpc);
    conn.applyWelcome(a, "{\"proto\":0,\"server_proto\":9,\"negotiation\":1,\"panel_rpc\":1,\"attach_identity\":true}");
    try std.testing.expectEqual(@as(u32, 0), conn.proto);
    try std.testing.expectEqual(@as(u8, 1), conn.panel_rpc);
    try std.testing.expect(conn.attach_identity);
    conn.applyWelcome(a, "{\"proto\":0,\"server_proto\":9,\"negotiation\":1,\"panel_rpc\":2,\"attach_identity\":true}");
    try std.testing.expectEqual(wire.PANEL_RPC_VERSION, conn.panel_rpc);
    try std.testing.expect(conn.attach_identity);
    conn.applyWelcome(a, "{\"proto\":9}");
    try std.testing.expectEqual(@as(u32, 0), conn.proto);
    try std.testing.expectEqual(@as(u32, 9), conn.server_proto);
    try std.testing.expectError(error.NoSharedTerminalProfile, conn.sendFrame(.attach, "{}"));
    try std.testing.expectError(error.NoSharedTerminalProfile, conn.queueFrame(.kill, "{}"));
    conn.applyWelcome(a, "{");
    try std.testing.expectEqual(@as(u32, 0), conn.proto);
}

test "stream_open welcome capability is strict and resets across reconnects" {
    const t = std.testing;
    const a = t.allocator;
    var conn = Conn{ .allocator = a, .fd = -1 };

    conn.applyWelcome(a, "{\"proto\":6,\"negotiation\":1}");
    try t.expect(!conn.stream_open);
    conn.applyWelcome(a, "{\"proto\":6,\"negotiation\":1,\"stream_open\":true}");
    try t.expect(conn.stream_open);
    conn.applyWelcome(a, "{\"proto\":6,\"negotiation\":1,\"stream_open\":false}");
    try t.expect(!conn.stream_open);

    // A malformed capability invalidates the welcome rather than being
    // interpreted as support, and a later reconnect starts from false.
    conn.applyWelcome(a, "{\"proto\":6,\"negotiation\":1,\"stream_open\":\"yes\"}");
    try t.expect(!conn.stream_open);
    try t.expectEqual(@as(u32, 0), conn.proto);
    conn.applyWelcome(a, "{\"proto\":6,\"negotiation\":1,\"stream_open\":true}");
    try t.expect(conn.stream_open);
    conn.applyWelcome(a, "{\"proto\":6,\"negotiation\":1}");
    try t.expect(!conn.stream_open);
}

test "fenced kill refuses old daemons before sending bytes" {
    const t = std.testing;
    var pair: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), @import("../util/platform.zig").socketpairCloexec(&pair));
    var conn = Conn{ .allocator = t.allocator, .fd = pair[0], .proto = wire.PROTO_VERSION };
    defer conn.deinit();
    var peer = Conn{ .allocator = t.allocator, .fd = pair[1], .proto = wire.PROTO_VERSION };
    defer peer.deinit();

    const req = wire.KillReq{
        .name = "same",
        .origin_id = "10000000000000000000000000000001",
    };
    try t.expectError(error.KillOriginFenceUnsupported, conn.sendKill(req));
    var pfd = c.struct_pollfd{ .fd = peer.fd, .events = c.POLLIN, .revents = 0 };
    try t.expectEqual(@as(c_int, 0), c.poll(&pfd, 1, 0));

    conn.kill_origin_fence = true;
    try conn.sendKill(req);
    const frame = try peer.recvExpectFor(&.{.kill}, 1_000);
    defer frame.deinit(t.allocator);
    var parsed = try std.json.parseFromSlice(wire.KillReq, t.allocator, frame.payload, .{});
    defer parsed.deinit();
    try t.expectEqualStrings(req.origin_id, parsed.value.origin_id);
}

test "identity-first GUI attach survives loss before trailing metadata and fences reincarnation" {
    const t = std.testing;
    const a = t.allocator;
    const origin_id = "10000000000000000000000000000001";
    var pair: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), @import("../util/platform.zig").socketpairCloexec(&pair));
    var conn = Conn{
        .allocator = a,
        .fd = pair[0],
        .proto = wire.PROTO_VERSION,
        .panel_rpc = wire.PANEL_RPC_VERSION,
        .attach_identity = true,
        .attach_identity_pending = true,
    };
    defer conn.deinit();
    var peer = Conn{ .allocator = a, .fd = pair[1], .proto = wire.PROTO_VERSION };
    try peer.sendFrame(.session_meta, "{\"name\":\"renamed\",\"origin_name\":\"same\",\"origin_id\":\"10000000000000000000000000000001\"}");
    try peer.sendFrame(.snapshot, "snapshot-before-loss");
    // This is the audited failure point: the ordinary post-snapshot metadata
    // never arrives, but the lifetime fence was already received.
    peer.deinit();
    const attached = try conn.recvGuiAttach();
    defer attached.snapshot.deinit(a);
    try t.expectEqualStrings("snapshot-before-loss", attached.snapshot.payload);
    try t.expectEqualStrings("renamed", attached.identity.name());
    try t.expectEqualStrings("same", attached.identity.originName());
    try t.expectEqualStrings(origin_id, attached.identity.originId());

    var reconnect_pair: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), @import("../util/platform.zig").socketpairCloexec(&reconnect_pair));
    var reconnect = Conn{
        .allocator = a,
        .fd = reconnect_pair[0],
        .proto = wire.PROTO_VERSION,
        .panel_rpc = wire.PANEL_RPC_VERSION,
        .attach_identity = true,
    };
    defer reconnect.deinit();
    var replacement = Conn{ .allocator = a, .fd = reconnect_pair[1], .proto = wire.PROTO_VERSION };
    defer replacement.deinit();
    try reconnect.sendAttach("same", .{
        .kind = "gui",
        .origin_id = attached.identity.originId(),
        .panel_rpc = wire.PANEL_RPC_VERSION,
    });
    const request = try replacement.recvExpectFor(&.{.attach}, 1_000);
    defer request.deinit(a);
    var parsed = try std.json.parseFromSlice(wire.AttachReq, a, request.payload, .{});
    defer parsed.deinit();
    try t.expectEqualStrings(origin_id, parsed.value.origin_id);
    try t.expect(parsed.value.identity_first);
    try t.expect(!std.mem.eql(u8, parsed.value.origin_id, "20000000000000000000000000000002"));
}

test "GUI panel reply queue refuses its bounded backlog before appending" {
    const a = std.testing.allocator;
    var conn = Conn{ .allocator = a, .fd = -1, .panel_rpc = wire.PANEL_RPC_VERSION };
    defer conn.wbuf.deinit(a);
    const frame_bytes = 5 + wire.PANEL_ENVELOPE_HEADER + 2;
    try conn.wbuf.resize(a, GUI_PANEL_REPLY_BACKLOG - frame_bytes + 1);
    const before = conn.wbuf.items.len;
    try std.testing.expectError(
        error.PanelReplyBackpressure,
        conn.queuePanelReply(1, "{}"),
    );
    try std.testing.expectEqual(before, conn.wbuf.items.len);
}

/// Pull the `error` string out of a daemon err payload (`{"error":"…"}`)
/// without a full JSON parse. Falls back to the raw payload.
fn errFieldOf(payload: []const u8) []const u8 {
    const key = "\"error\":\"";
    const i = std.mem.indexOf(u8, payload, key) orelse return payload;
    const rest = payload[i + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return payload;
    return rest[0..end];
}

test "udp ticket reply parses and rejects refusals and bad keys" {
    const a = std.testing.allocator;
    var key: [rudp.KEY_LEN]u8 = @splat(9);
    var hexbuf: [rudp.KEY_LEN * 2]u8 = undefined;
    const hex = rudp.keyToHex(key, &hexbuf);
    var payload_buf: [256]u8 = undefined;
    const payload = try std.fmt.bufPrint(&payload_buf, "{{\"ok\":true,\"port\":61000,\"key\":\"{s}\"}}", .{hex});
    const ticket = parseUdpTicketReply(a, payload) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 61000), ticket.port);
    try std.testing.expectEqualStrings(hex, ticket.keyhex());
    try std.testing.expect(parseUdpTicketReply(a, "{\"ok\":false,\"error\":\"nope\"}") == null);
    try std.testing.expect(parseUdpTicketReply(a, "{\"ok\":true,\"port\":0,\"key\":\"beef\"}") == null);
    try std.testing.expect(parseUdpTicketReply(a, "{\"ok\":true,\"port\":1,\"key\":\"zz\"}") == null);
    try std.testing.expect(parseUdpTicketReply(a, "not json") == null);
    key[0] = 0;
}

test "env ticket is host-matched and single-use" {
    var key: [rudp.KEY_LEN]u8 = @splat(3);
    var hexbuf: [rudp.KEY_LEN * 2]u8 = undefined;
    const hex = rudp.keyToHex(key, &hexbuf);
    var val_buf: [128:0]u8 = undefined;
    const val = try std.fmt.bufPrintZ(&val_buf, "boxy 61111 {s}", .{hex});
    _ = c.setenv("SKETERM_UDP_TICKET", val.ptr, 1);
    defer _ = c.unsetenv("SKETERM_UDP_TICKET");
    // A mismatched host must neither match nor consume.
    try std.testing.expect(takeTicketFromEnv("otherbox") == null);
    try std.testing.expect(c.getenv("SKETERM_UDP_TICKET") != null);
    // Prefixed spellings normalize to the same bare host; a match
    // clears the variable (the listener serves exactly one connection).
    const ticket = takeTicketFromEnv("udp:boxy") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 61111), ticket.port);
    try std.testing.expectEqualStrings(hex, ticket.keyhex());
    try std.testing.expect(c.getenv("SKETERM_UDP_TICKET") == null);
    try std.testing.expect(takeTicketFromEnv("boxy") == null);
    key[0] = 0;
}
