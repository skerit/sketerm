//! Session lifecycle — spawn/attach, the Wayland/audio hub sockets,
//! and broker-mode forwarding to per-session workers — split out of
//! daemon.zig. Functions take the owning *Daemon and are aliased back
//! into Daemon.

const std = @import("std");
const c = @import("../c.zig").c;
const log = @import("log.zig");
const wire = @import("wire.zig");
const platform = @import("../util/platform.zig");
const dmod = @import("daemon.zig");
const Daemon = dmod.Daemon;
const Client = dmod.Client;
const Session = dmod.Session;
const Worker = dmod.Worker;
const SpawnReq = dmod.SpawnReq;
const AttachReq = dmod.AttachReq;
const KillReq = dmod.KillReq;
const wlkeymaps = @import("../wlhost/keymaps.zig");
const wlcomp = @import("../wlhost/compositor.zig");
const logring = @import("logring.zig");
const WsSource = @import("../winstream/source.zig").Source;
const nowMs = dmod.nowMs;
const shell_util = @import("shell.zig");
const wssource = @import("../winstream/source.zig");
const pathZ = @import("../util/pathz.zig").pathZ;
const removeTreeBestEffort = dmod.removeTreeBestEffort;
const SessionInfo = dmod.SessionInfo;
const RenameReq = dmod.RenameReq;
const controlSend = @import("daemon_serve.zig").controlSend;
const WORKER_META_BUF = @import("daemon_serve.zig").WORKER_META_BUF;
const runWorker = @import("daemon_serve.zig").runWorker;
const version = @import("../version.zig");
const a11yhub = @import("a11yhub.zig");
const fillSockaddrUn = dmod.fillSockaddrUn;
const opuscodec = @import("opuscodec.zig");
const Pty = @import("../pty.zig").Pty;
const Pool = @import("../grid/style_pool.zig").Pool;
const Screen = @import("../grid/screen.zig").Screen;
const Parser = @import("../parser/vt.zig").Parser;
const build_options = @import("build_options");
const xwayland = @import("xwayland.zig");

pub fn findSession(self: *Daemon, name: []const u8) ?*Session {
    for (self.sessions.items) |s| {
        if (std.mem.eql(u8, s.name, name)) return s;
    }
    return null;
}

fn validOutputSize(req: SpawnReq) bool {
    if (req.output_width == 0 or req.output_height == 0) return false;
    if (req.output_width > 16_384 or req.output_height > 16_384) return false;
    return @as(u64, req.output_width) * req.output_height <= 64 * 1024 * 1024;
}

fn queueNameExists(cl: *Client, name: []const u8) void {
    var buf: [192]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "session '{s}' already exists (use a different name or destroy it)", .{name}) catch "session name already exists";
    cl.queueErr(msg);
}

pub fn handleSpawn(self: *Daemon, cl: *Client, payload: []const u8) void {
    if (cl.proto == 0 or cl.snapshot_version == 0) {
        cl.queueErr("no shared terminal profile; daemon and sessions preserved");
        return;
    }
    if (self.is_broker) return brokerSpawn(self, cl, payload);
    if (self.isWorker()) {
        cl.queueErr("session workers cannot spawn another session");
        return;
    }
    var parsed = std.json.parseFromSlice(SpawnReq, self.allocator, payload, .{
        .ignore_unknown_fields = true,
    }) catch {
        cl.queueErr("bad spawn request");
        return;
    };
    defer parsed.deinit();
    var req = parsed.value;
    if (req.name.len == 0 or req.name.len > 64) {
        cl.queueErr("spawn needs a name");
        return;
    }
    if (!validOutputSize(req)) {
        cl.queueErr("bad output size (dimensions must be 1..16384 and at most 64 megapixels)");
        return;
    }
    // Empty argv = "the daemon host's login shell" — remote
    // clients can't know what's installed here. Display sessions
    // (keeper argv substituted) and cast playback (no child at all)
    // are exempt.
    const default_shell: []const []const u8 = &.{shell_util.accountLoginShell()};
    if (req.argv.len == 0 and !req.display and req.cast_path.len == 0) {
        req.argv = default_shell;
        req.login_shell = true;
    }
    if (findSession(self, req.name) != null) {
        queueNameExists(cl, req.name);
        return;
    }
    const s = spawnSession(self, req) catch |err| {
        var ebuf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&ebuf, "spawn failed: {s}", .{@errorName(err)}) catch "spawn failed";
        cl.queueErr(msg);
        return;
    };
    self.sessions.append(self.allocator, s) catch {
        s.deinit();
        cl.queueErr("oom");
        return;
    };
    cl.queueJson(.ok, .{
        .ok = true,
        .name = s.name,
        .pid = s.childPid(),
        // The session's environment: an external renderer must be
        // handed these, never left to derive a wl-w<pid> path.
        .wl_display = if (s.wl_display_path) |p| p else "",
        .pulse_server = if (s.pa_socket_path) |p| p else "",
        .runtime_dir = if (s.runtime_dir_path) |p| p else "",
        .xwayland = s.xwayland != null,
        .x_display = if (s.xwayland) |*xwl| xwl.display_name else "",
        .xauthority = if (s.xwayland) |*xwl| xwl.auth_path else "",
        .gpu = s.gpu,
        .output_width = s.output_width,
        .output_height = s.output_height,
    });
}

pub fn brokerFindWorker(self: *Daemon, name: []const u8) ?*Worker {
    for (self.workers.items) |w| {
        if (!w.dead and std.mem.eql(u8, w.name, name)) return w;
    }
    return null;
}

/// Apply per-worker resource limits in the freshly forked child, before it
/// becomes a worker. Opt-in via SKETERM_WORKER_MEM_MB (megabytes of address
/// space, RLIMIT_AS); unset or 0 = no cap. A capped worker that runs away
/// hits ENOMEM and dies alone — the broker just sees it exit (containment),
/// so a single OOM never reaches the machine's global OOM killer. Off by
/// default because RLIMIT_AS bounds VIRTUAL space, which heavy-image
/// sessions can legitimately reserve; the knob is for hosts that want a
/// hard ceiling.
pub fn applyWorkerLimits() void {
    const env = std.c.getenv("SKETERM_WORKER_MEM_MB") orelse return;
    const mb = std.fmt.parseInt(u64, std.mem.span(env), 10) catch {
        log.warn("ignoring unparseable SKETERM_WORKER_MEM_MB={s}", .{std.mem.span(env)});
        return;
    };
    if (mb == 0) return;
    const bytes = mb * 1024 * 1024;
    // Hand-declared instead of the translate-c types: <sys/resource.h>
    // is only in the CORE cimport set, and this function is reachable
    // from code the GUI test root compiles too (Daemon.tick).
    const RLimit = extern struct { rlim_cur: u64, rlim_max: u64 };
    const S = struct {
        extern "c" fn setrlimit(resource: c_int, rlim: *const RLimit) c_int;
    };
    const RLIMIT_AS: c_int = if (@import("builtin").os.tag == .macos) 5 else 9;
    const rl = RLimit{ .rlim_cur = bytes, .rlim_max = bytes };
    _ = S.setrlimit(RLIMIT_AS, &rl);
}

/// Broker side of spawn: fork a worker process that owns this session.
/// fork-without-exec — the child runs `runWorker` against an inherited
/// (COW) copy of the SpawnReq; it first drops every broker fd it inherited.
pub fn brokerSpawn(self: *Daemon, cl: *Client, payload: []const u8) void {
    var parsed = std.json.parseFromSlice(SpawnReq, self.allocator, payload, .{
        .ignore_unknown_fields = true,
    }) catch {
        cl.queueErr("bad spawn request");
        return;
    };
    defer parsed.deinit();
    var req = parsed.value;
    if (req.name.len == 0 or req.name.len > 64) {
        cl.queueErr("spawn needs a name");
        return;
    }
    if (!validOutputSize(req)) {
        cl.queueErr("bad output size (dimensions must be 1..16384 and at most 64 megapixels)");
        return;
    }
    const default_shell: []const []const u8 = &.{shell_util.accountLoginShell()};
    if (req.argv.len == 0 and !req.display and req.cast_path.len == 0) {
        req.argv = default_shell;
        req.login_shell = true;
    }
    if (brokerFindWorker(self, req.name) != null) {
        queueNameExists(cl, req.name);
        return;
    }

    // A datagram channel, so each control message (and its SCM_RIGHTS
    // fd) stays one clean unit on the broker↔worker channel — sized to
    // carry the largest metadata push. See platform.controlSocketpair
    // for the Linux-vs-Darwin split behind it.
    var sp: [2]c_int = undefined;
    if (platform.controlSocketpair(&sp, WORKER_META_BUF) != 0) {
        cl.queueErr("spawn failed: socketpair (fd exhaustion?)");
        return;
    }
    const pid = c.fork();
    if (pid < 0) {
        _ = c.close(sp[0]);
        _ = c.close(sp[1]);
        cl.queueErr("spawn failed: fork (process/memory limit?)");
        return;
    }
    if (pid == 0) {
        // Worker child: drop every inherited broker fd, then become a
        // single-session worker. `req` is valid here via COW; we _exit
        // before the parent's `defer parsed.deinit()` matters to us.
        _ = c.close(sp[0]);
        if (self.listen_fd >= 0) _ = c.close(self.listen_fd);
        for (self.clients.items) |cc| _ = c.close(cc.fd);
        for (self.workers.items) |w| {
            if (w.control_fd >= 0) _ = c.close(w.control_fd);
        }
        _ = c.setsid();
        applyWorkerLimits();
        // Hand the worker the broker's socket dir so its Wayland display /
        // isolated-rt sockets land in the right runtime dir (the worker has
        // no listen socket of its own to derive it from). COW-valid here.
        const dir_end = std.mem.lastIndexOfScalar(u8, self.sock_path, '/') orelse self.sock_path.len;
        runWorker(self.allocator, sp[1], req, self.sock_path[0..dir_end], self.sock_path) catch {};
        c._exit(0);
    }
    // Broker parent.
    _ = c.close(sp[1]);
    _ = c.fcntl(sp[0], c.F_SETFD, c.FD_CLOEXEC);
    const name_owned = self.allocator.dupe(u8, req.name) catch {
        _ = c.close(sp[0]);
        cl.queueErr("oom");
        return;
    };
    const w = self.allocator.create(Worker) catch {
        self.allocator.free(name_owned);
        _ = c.close(sp[0]);
        cl.queueErr("oom");
        return;
    };
    w.* = .{
        .allocator = self.allocator,
        .name = name_owned,
        .pid = pid,
        .control_fd = sp[0],
        .app = req.app,
        // Seeded from the request so `list` is right before the
        // worker's first 'M' push lands.
        .display = req.display,
        .gpu = req.gpu,
        .output_width = req.output_width,
        .output_height = req.output_height,
        .ttl_secs = req.ttl_secs,
        .pending_client = cl,
    };
    self.workers.append(self.allocator, w) catch {
        w.deinit();
        cl.queueErr("oom");
        return;
    };
    log.info("worker forked pid={d} session='{s}' kind={s}", .{ pid, w.name, if (req.app) "app" else "shell" });
    // Reply is deferred: `brokerOnWorkerControl` sends `.ok` when the
    // worker reports 'Y' (session up), or `.err` if the worker dies first
    // (spawnSession failed). The client is blocked in recvExpect(.ok).
}

/// Broker side of attach: hand the client's socket fd to the session's
/// worker (SCM_RIGHTS) and drop our copy — the worker serves it directly.
pub fn brokerAttach(self: *Daemon, cl: *Client, payload: []const u8) void {
    var parsed = std.json.parseFromSlice(AttachReq, self.allocator, payload, .{
        .ignore_unknown_fields = true,
    }) catch {
        cl.queueErr("bad attach request");
        return;
    };
    defer parsed.deinit();
    const w = brokerFindWorker(self, parsed.value.name) orelse {
        cl.queueErr("no such session");
        return;
    };
    const kind: Client.Kind = if (std.mem.eql(u8, parsed.value.kind, "gui"))
        .gui
    else if (std.mem.eql(u8, parsed.value.kind, "cli"))
        .cli
    else if (std.mem.eql(u8, parsed.value.kind, "mcp"))
        .mcp
    else
        .unknown;
    const msg = [_]u8{
        'A',
        @truncate(cl.proto),
        @intFromBool(cl.video),
        @intFromEnum(kind),
        cl.native_state_max,
        cl.snapshot_version,
        @intFromBool(cl.audio_channels),
        @intFromBool(cl.winstream_channels),
        // Controller-lease intent. The worker owns the lease (it
        // owns the session), so these MUST ride the handoff — the
        // broker's own Client is discarded a few lines below.
        @intFromBool(parsed.value.read_only),
        @intFromBool(parsed.value.control),
    };
    controlSend(w.control_fd, &msg, cl.fd);
    // Handed off: the kernel duplicated the fd into the worker. Drop our
    // copy + the Client (reap closes the broker's fd; the worker's stays).
    //
    // ASSUMPTION: the client is synchronous — it sends `.attach` and then
    // blocks on the snapshot, so nothing is pipelined behind `.attach`. If
    // it ever weren't, bytes the broker already pulled into `cl.rbuf` would
    // be stranded here (the kernel buffer the worker inherits no longer has
    // them). Revisit (forward leftover rbuf in the 'A' frame) before any
    // client starts streaming input ahead of the snapshot.
    cl.dead = true;
}

/// Broker side of list: answer from each worker's pushed metadata cache.
/// The broker holds no Screen, so every field here came over a worker 'M'
/// push; idle_ms is computed against the broker's own (shared) clock.
pub fn brokerList(self: *Daemon, cl: *Client) void {
    var infos: std.ArrayList(SessionInfo) = .empty;
    defer infos.deinit(self.allocator);
    const now = nowMs();
    for (self.workers.items) |w| {
        if (w.dead) continue;
        infos.append(self.allocator, .{
            .name = w.name,
            .rows = w.rows,
            .cols = w.cols,
            .clients = w.n_clients,
            .exited = w.exited,
            .title = if (w.title) |t| t else "",
            .app = w.app,
            // A worker that has never pushed (activity==0) reads as idle 0
            // rather than a bogus multi-decade idle.
            .idle_ms = if (w.last_activity_ms == 0) 0 else now - w.last_activity_ms,
            .cwd = if (w.cwd) |cw| cw else "",
            .pid = w.child_pid,
            .audio = w.audio,
            .audio_streams = w.audio_streams,
            .display = w.display,
            .xwayland = w.xwayland,
            .x_display = if (w.x_display) |p| p else "",
            .xauthority = if (w.xauthority) |p| p else "",
            .gpu = w.gpu,
            .output_width = w.output_width,
            .output_height = w.output_height,
            .wl_display = if (w.wl_display) |p| p else "",
            .pulse_server = if (w.pulse_server) |p| p else "",
            .runtime_dir = if (w.runtime_dir) |p| p else "",
            .ttl_secs = w.ttl_secs,
            .viewers = w.viewers,
            .controller = if (w.controller) |p| p else "",
        }) catch return;
    }
    cl.queueJson(.welcome, .{ .proto = cl.proto, .server_proto = wire.PROTO_VERSION, .min_proto = wire.MIN_SERVER_PROTO, .negotiation = @as(u8, 1), .version = version.string, .audio_opus = opuscodec.available(), .video = build_options.video, .sessions = infos.items });
}

/// Broker side of kill: send the worker a graceful 'K' (it flushes `.gone`
/// to its clients and exits) and mark it dead so the name frees at once.
/// The buffered 'K' datagram is delivered to the worker even though reap
/// closes the broker's control end this tick.
pub fn brokerKill(self: *Daemon, cl: *Client, payload: []const u8) void {
    var parsed = std.json.parseFromSlice(KillReq, self.allocator, payload, .{
        .ignore_unknown_fields = true,
    }) catch {
        cl.queueErr("bad kill request");
        return;
    };
    defer parsed.deinit();
    const w = brokerFindWorker(self, parsed.value.name) orelse {
        cl.queueErr("no such session");
        return;
    };
    if (parsed.value.require_display and !w.display) {
        cl.queueErr("session is not a display session");
        return;
    }
    if (parsed.value.expected_pid != 0 and parsed.value.expected_pid != w.child_pid) {
        cl.queueErr("display session identity changed");
        return;
    }
    if (parsed.value.expected_wl_display.len > 0 and
        (w.wl_display == null or !std.mem.eql(u8, parsed.value.expected_wl_display, w.wl_display.?)))
    {
        cl.queueErr("display session identity changed");
        return;
    }
    controlSend(w.control_fd, "K", -1);
    w.dead = true;
    cl.queueJson(.ok, .{ .ok = true });
}

/// Broker side of rename: the broker is the routing authority, so update
/// `Worker.name` here, and forward an 'R' to the worker so its own session
/// state stays consistent.
pub fn brokerRename(self: *Daemon, cl: *Client, payload: []const u8) void {
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
    const w = brokerFindWorker(self, req.name) orelse {
        cl.queueErr("no such session");
        return;
    };
    if (brokerFindWorker(self, req.new_name)) |other| {
        if (other != w) {
            cl.queueErr("session name already exists");
            return;
        }
    }
    const fresh = self.allocator.dupe(u8, req.new_name) catch {
        cl.queueErr("oom");
        return;
    };
    self.allocator.free(w.name);
    w.name = fresh;
    var msg: [1 + 64]u8 = undefined;
    msg[0] = 'R';
    @memcpy(msg[1..][0..req.new_name.len], req.new_name);
    controlSend(w.control_fd, msg[0 .. 1 + req.new_name.len], -1);
    cl.queueJson(.ok, .{ .ok = true, .name = w.name });
}

pub const WaylandHub = struct {
    fd: c_int,
    display_path: []u8,
};

/// Create a session's Wayland display socket next to the daemon
/// socket and listen on it — the daemon IS the display, so the
/// listening socket is the one the shell's $WAYLAND_DISPLAY points
/// at. Null on any failure (the session still spawns, just without
/// Wayland forwarding).
/// True in a forked session worker (owns one session over a control_fd,
/// no listen socket). Broker and monolith both have control_fd == -1.
pub inline fn isWorker(self: *const Daemon) bool {
    return self.control_fd >= 0;
}

/// Directory the session's auxiliary sockets (Wayland display, isolated rt
/// dir) live in. The monolith/broker derive it from their listen socket
/// path; a worker was handed it at fork (it has no listen socket). Null if
/// neither is available.
pub fn runtimeBaseDir(self: *const Daemon) ?[]const u8 {
    if (self.base_dir) |d| return d;
    const dir_end = std.mem.lastIndexOfScalar(u8, self.sock_path, '/') orelse return null;
    return self.sock_path[0..dir_end];
}

pub fn setupWaylandHub(self: *Daemon) ?WaylandHub {
    const id = if (self.isWorker()) 0 else blk: {
        const v = self.next_wl_id;
        self.next_wl_id += 1;
        break :blk v;
    };
    return setupHubSocket(self, "wl", id);
}

/// PulseAudio hub: same listener shape, "pa-N" socket (its own
/// counter — the rigs rely on sequential "wl-N"). Each app
/// connection becomes an `audio` channel (mux/pulse.zig server).
pub fn setupAudioHub(self: *Daemon) ?WaylandHub {
    const id = if (self.isWorker()) 0 else blk: {
        const v = self.next_pa_id;
        self.next_pa_id += 1;
        break :blk v;
    };
    return setupHubSocket(self, "pa", id);
}

pub fn setupHubSocket(self: *Daemon, comptime prefix: []const u8, id: u32) ?WaylandHub {
    const dir = runtimeBaseDir(self) orelse return null;
    // Workers share the runtime dir, each with one session, so a per-worker
    // counter would collide ("wl-1" in every worker) — name by pid instead.
    // The monolith keeps the sequential "wl-N" the rigs expect.
    const display_path = if (self.isWorker())
        std.fmt.allocPrint(self.allocator, "{s}/" ++ prefix ++ "-w{d}", .{ dir, c.getpid() }) catch return null
    else
        std.fmt.allocPrint(self.allocator, "{s}/" ++ prefix ++ "-{d}", .{ dir, id }) catch return null;
    var ok = false;
    defer if (!ok) self.allocator.free(display_path);

    var z_buf: [4096]u8 = undefined;
    if (pathZ(&z_buf, display_path)) |z| _ = c.unlink(z) else |_| return null;

    const fd = @import("../util/platform.zig").socketCloexec(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (fd < 0) return null;
    var addr: c.struct_sockaddr_un = undefined;
    fillSockaddrUn(&addr, display_path) catch {
        _ = c.close(fd);
        return null;
    };
    if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0 or c.listen(fd, 8) != 0) {
        _ = c.close(fd);
        return null;
    }
    ok = true;
    return .{ .fd = fd, .display_path = display_path };
}

/// Window-stream backend policy for a spawn. On macOS builds
/// with the ScreenCaptureKit backend, app sessions capture
/// automatically (their apps have no forwardable display
/// protocol). The SKETERM_WINSTREAM env is the rig override:
/// "stub" = test pattern for app sessions, "all" = test pattern
/// for every session, "sck" = real capture for every session. Any
/// value but "sck" forces the stub so smoke-mux and Linux rigs get
/// a deterministic pattern.
/// `hosts_apps` = this session would forward GUI apps on Linux
/// (interactive command, forwarding not disabled). On macOS,
/// winstream IS that forwarding mechanism, so capture turns on for
/// ANY such session — a GUI app launched from a durable Mac shell
/// streams exactly like one launched from a Linux durable shell
/// ($WAYLAND_DISPLAY). Env overrides for the test rigs: "off"
/// suppresses the macOS auto gate (Linux-like behaviour),
/// "all"/"sck" widen to every session, "stub"/other force the
/// test pattern.
pub fn winstreamGate(req: SpawnReq, hosts_apps: bool) struct { want: bool, use_sck: bool } {
    const env = std.c.getenv("SKETERM_WINSTREAM");
    const val: ?[]const u8 = if (env) |e| std.mem.span(e) else null;
    const eq = struct {
        fn f(v: ?[]const u8, s: []const u8) bool {
            return v != null and std.mem.eql(u8, v.?, s);
        }
    }.f;
    const off = eq(val, "off");
    const widen = eq(val, "all") or eq(val, "sck");
    // macOS apps have no display protocol to forward — winstream
    // is the only mechanism, so it stands in for Wayland
    // forwarding on any app-hosting session.
    const auto_mac = (comptime wssource.have_sck) and !off and hosts_apps;
    return .{
        .want = req.winstream or (val != null and !off and (req.app or widen)) or auto_mac,
        .use_sck = (comptime wssource.have_sck) and (val == null or eq(val, "sck")),
    };
}

pub fn spawnSession(self: *Daemon, req_in: SpawnReq) !*Session {
    const allocator = self.allocator;

    // Cast playback: no child, no hubs, no PTY — its own spawn path.
    // Works identically in monolith and (via runWorker) broker mode.
    if (req_in.cast_path.len > 0) return self.spawnCastSession(req_in);

    // External display session: the child is OUR OWN binary in
    // `--keep` mode. Resolved daemon-side on purpose — a client
    // (possibly on another host, over SSH) cannot know this host's
    // binary path, and a mismatched build would exit instantly and
    // take the session with it.
    var req = req_in;
    var keep_exe: [4096:0]u8 = undefined;
    var keep_argv: [2][]const u8 = undefined;
    if (req.display) {
        const exe = platform.selfExecPathZ(&keep_exe) orelse return error.NoSelfExePath;
        keep_argv = .{ exe, "--keep" };
        req.argv = &keep_argv;
    }

    // Wayland forwarding: the daemon IS the session's display —
    // it listens on the display socket itself and parses each app
    // connection. SKETERM_MUX_NO_WAYLAND=1 disables app forwarding.
    // hosts_apps: forwarding enabled with an actual command —
    // drives BOTH Wayland forwarding (Linux) and winstream capture
    // (macOS), the same notion of "a session whose child apps
    // should appear on the client".
    const hosts_apps = std.c.getenv("SKETERM_MUX_NO_WAYLAND") == null and
        req.argv.len > 0;

    // Window-stream backend (pixel capture): policy in winstreamGate.
    const ws_gate = winstreamGate(req, hosts_apps);

    // A local GUI-owned session passes its apps through to the
    // real desktop compositor — no embedded hub for it.
    const want_wayland = !ws_gate.want and hosts_apps and !req.local;
    var hub: ?WaylandHub = if (want_wayland) setupWaylandHub(self) else null;
    errdefer if (hub) |h| {
        _ = c.close(h.fd);
        allocator.free(h.display_path);
    };
    if (req.display and hub == null) return error.WaylandDisplayUnavailable;

    // Remote audio rides the same gate: the daemon IS the
    // session's PulseAudio server (SKETERM_MUX_NO_AUDIO=1 opts out).
    var audio_hub: ?WaylandHub = if (want_wayland and !req.no_audio and std.c.getenv("SKETERM_MUX_NO_AUDIO") == null)
        setupAudioHub(self)
    else
        null;
    errdefer if (audio_hub) |h| {
        _ = c.close(h.fd);
        allocator.free(h.display_path);
    };

    var argv_z: std.ArrayList([:0]u8) = .empty;
    defer {
        for (argv_z.items) |a| allocator.free(a);
        argv_z.deinit(allocator);
    }
    var argv_ptrs: std.ArrayList([*:0]const u8) = .empty;
    defer argv_ptrs.deinit(allocator);
    for (req.argv) |a| {
        const z = try allocator.dupeZ(u8, a);
        try argv_z.append(allocator, z);
        try argv_ptrs.append(allocator, z.ptr);
    }

    // The daemon is the display, so it sets the child's
    // WAYLAND_DISPLAY (= the hub's display socket).
    var wl_disp_z: ?[:0]u8 = null;
    defer if (wl_disp_z) |z| allocator.free(z);
    if (hub) |h| {
        wl_disp_z = try allocator.dupeZ(u8, h.display_path);
    } else if (req.local and req.host_wayland_display.len > 0) {
        // Local passthrough: point the child at the host compositor.
        wl_disp_z = try allocator.dupeZ(u8, req.host_wayland_display);
    }
    // Likewise the audio server: PULSE_SERVER=unix:<hub socket>.
    var pa_env_z: ?[:0]u8 = null;
    defer if (pa_env_z) |z| allocator.free(z);
    if (audio_hub) |h| {
        pa_env_z = try std.fmt.allocPrintSentinel(allocator, "unix:{s}", .{h.display_path}, 0);
    }

    // Isolated session: a private runtime dir (sibling of the wl
    // sockets) so single-instance apps can't coalesce across
    // clients. The wl socket stays in the shared dir — its absolute
    // path in WAYLAND_DISPLAY is unaffected by XDG_RUNTIME_DIR.
    var rt_dir_z: ?[:0]u8 = null;
    defer if (rt_dir_z) |z| allocator.free(z);
    var rt_dir_owned: ?[]u8 = null;
    errdefer if (rt_dir_owned) |p| {
        removeTreeBestEffort(p);
        allocator.free(p);
    };
    if (req.isolated) {
        const dir = runtimeBaseDir(self) orelse "";
        const p = if (self.isWorker())
            try std.fmt.allocPrint(allocator, "{s}/rt-w{d}", .{ dir, c.getpid() })
        else blk: {
            const id = self.next_rt_id;
            self.next_rt_id += 1;
            break :blk try std.fmt.allocPrint(allocator, "{s}/rt-{d}", .{ dir, id });
        };
        rt_dir_owned = p;
        var z_buf: [4096]u8 = undefined;
        _ = c.mkdir(try pathZ(&z_buf, p), 0o700);
        rt_dir_z = try allocator.dupeZ(u8, p);
    }

    var xwl: ?xwayland.Instance = null;
    errdefer if (xwl) |*instance| instance.deinit();
    if (req.display and req.xwayland and hub != null) {
        const base = runtimeBaseDir(self) orelse platform.runtimeDir();
        const runtime = if (rt_dir_owned) |p| p else platform.runtimeDir();
        xwl = xwayland.Instance.setup(allocator, base, hub.?.display_path, runtime, req.gpu) catch |err| blk: {
            if (req.require_xwayland) return err;
            log.warn("rootless Xwayland setup failed for '{s}': {s}; continuing Wayland-only", .{ req.name, @errorName(err) });
            break :blk null;
        };
        if (xwl == null and req.require_xwayland) return error.XwaylandUnavailable;
    }

    // Forwarded-app sessions get a private D-Bus session bus so
    // the daemon can read their AT-SPI tree (disable with
    // SKETERM_NO_A11Y=1). Best-effort: null if dbus-daemon absent.
    var a11y_hub: ?a11yhub.Hub = null;
    errdefer if (a11y_hub) |*h| h.deinit();
    if (req.app and c.getenv("SKETERM_NO_A11Y") == null) {
        if (runtimeBaseDir(self)) |dir| {
            var idbuf: [32]u8 = undefined;
            const idstr = if (self.isWorker())
                std.fmt.bufPrint(&idbuf, "w{d}", .{c.getpid()}) catch "app"
            else blk: {
                const id = self.next_wl_id;
                break :blk std.fmt.bufPrint(&idbuf, "{d}", .{id}) catch "app";
            };
            a11y_hub = a11yhub.Hub.setup(allocator, dir, idstr);
            if (a11y_hub == null)
                log.warn("a11y hub setup failed for session '{s}' — app_a11y_tree will be empty (dbus-daemon / at-spi2-registryd missing?)", .{req.name});
        }
    }
    const a11y_addr_z: ?[:0]const u8 = if (a11y_hub) |h| h.bus_addr_z else null;

    // Null-terminated copies of the GUI-supplied env/identity strings,
    // freed after spawn (the child has its own env copy by then). All
    // optional — empty/absent falls back to Pty.spawn's defaults.
    const sock_z: ?[:0]u8 = if (req.socket.len > 0) allocator.dupeZ(u8, req.socket) catch null else null;
    defer if (sock_z) |z| allocator.free(z);
    // The daemon owns the session name, so it (not the GUI) exports the
    // stable SKETERM_SESSION identity — no plumbing through the client.
    const name_z: ?[:0]u8 = if (req.name.len > 0) allocator.dupeZ(u8, req.name) catch null else null;
    defer if (name_z) |z| allocator.free(z);
    const term_z: ?[:0]u8 = if (req.term.len > 0) allocator.dupeZ(u8, req.term) catch null else null;
    defer if (term_z) |z| allocator.free(z);
    const cterm_z: ?[:0]u8 = if (req.color_term.len > 0) allocator.dupeZ(u8, req.color_term) catch null else null;
    defer if (cterm_z) |z| allocator.free(z);
    var si_script_z: ?[:0]u8 = null;
    var si_shim_z: ?[:0]u8 = null;
    defer if (si_script_z) |z| allocator.free(z);
    defer if (si_shim_z) |z| allocator.free(z);
    const PtyMod = @import("../pty.zig");
    const shell_integration: ?PtyMod.ShellIntegration = blk: {
        const si = req.shell_integration orelse break :blk null;
        const kind: PtyMod.ShellIntegration.Kind =
            if (std.mem.eql(u8, si.kind, "zsh")) .zsh else if (std.mem.eql(u8, si.kind, "fish")) .fish else if (std.mem.eql(u8, si.kind, "bash")) .bash else break :blk null;
        si_script_z = allocator.dupeZ(u8, si.script) catch break :blk null;
        si_shim_z = allocator.dupeZ(u8, si.shim_dir) catch break :blk null;
        break :blk .{ .kind = kind, .script = si_script_z.?.ptr, .shim_dir = si_shim_z.?.ptr };
    };
    var env_z: std.ArrayList([:0]u8) = .empty;
    defer {
        for (env_z.items) |e| allocator.free(e);
        env_z.deinit(allocator);
    }
    var env_ptrs: std.ArrayList([*:0]const u8) = .empty;
    defer env_ptrs.deinit(allocator);
    for (req.env) |kv| {
        if (std.mem.indexOfScalar(u8, kv, '=') == null) continue; // not K=V
        const z = try allocator.dupeZ(u8, kv);
        try env_z.append(allocator, z);
        try env_ptrs.append(allocator, z.ptr);
    }

    var pty = try Pty.spawn(.{
        .argv = argv_ptrs.items,
        .cwd = req.cwd,
        .env = env_ptrs.items,
        .rows = req.rows,
        .cols = req.cols,
        .term = if (term_z) |z| z.ptr else "xterm-256color",
        .color_term = if (cterm_z) |z| z.ptr else "truecolor",
        .login_shell = req.login_shell,
        .pane_id = req.pane_id,
        .socket_path = if (sock_z) |z| z.ptr else null,
        .session_name = if (name_z) |z| z.ptr else null,
        .shell_integration = shell_integration,
        .wayland_display = if (wl_disp_z) |z| z.ptr else null,
        .pulse_server = if (pa_env_z) |z| z.ptr else null,
        // No hub for this session (audio:"none" / disabled /
        // setup failed): scrub any PULSE_SERVER the daemon itself
        // inherited. Local desktop panes keep their inheritance —
        // that's the user's own environment.
        .clear_pulse_server = pa_env_z == null and !req.local,
        .runtime_dir = if (rt_dir_z) |z| z.ptr else null,
        .a11y_bus_addr = if (a11y_addr_z) |z| z.ptr else null,
        .gpu = req.gpu,
        .debuggable = req.debuggable,
    });
    errdefer _ = pty.closeAndReap();
    // The poll loop does bounded read rounds — master must not
    // block (the GUI's dedicated reader thread blocks; we can't).
    const fl = c.fcntl(pty.master_fd, c.F_GETFL, @as(c_int, 0));
    _ = c.fcntl(pty.master_fd, c.F_SETFL, fl | c.O_NONBLOCK);

    const pool = try allocator.create(Pool);
    errdefer allocator.destroy(pool);
    pool.* = try Pool.init(allocator);
    errdefer pool.deinit();
    const screen = try Screen.init(allocator, pool, req.cols, req.rows);
    errdefer screen.deinit();
    // Keep image placements for the attach snapshot — there's no
    // per-pane ImageStore on the daemon side to remember them.
    screen.retain_images = true;
    // Queries only the GUI can answer (clipboard read, color
    // scheme) are left for the attached mirror to reply to.
    screen.defer_gui_queries = true;

    const s = try allocator.create(Session);
    errdefer allocator.destroy(s);
    s.* = .{
        .allocator = allocator,
        .name = try allocator.dupe(u8, req.name),
        .source = .{ .pty = pty },
        .parser = Parser.init(allocator),
        .pool = pool,
        .screen = screen,
        .app = req.app,
        .debuggable = req.debuggable,
        .display = req.display,
        .xwayland = null,
        .output_width = req.output_width,
        .output_height = req.output_height,
        .ttl_ms = @as(i64, req.ttl_secs) * 1000,
        // A session nobody ever attaches to must still expire, so
        // the no-viewer clock starts now rather than at first detach.
        .no_viewer_since_ms = nowMs(),
        .gpu = req.gpu,
        .kb_keymap = wlkeymaps.get(req.kb_layout) orelse blk: {
            log.warn("unknown kb_layout '{s}' (have: {s}) — using us", .{ req.kb_layout, wlkeymaps.names });
            break :blk wlcomp.us_keymap;
        },
        .last_activity_ms = nowMs(),
        .log = logring.LogRing.init(allocator),
    };
    if (hub) |h| {
        s.wl_hub_fd = h.fd;
        s.wl_display_path = h.display_path;
        hub = null; // ownership moved to the session
    }
    if (xwl) |instance| {
        s.xwayland = instance;
        xwl = null;
    }
    if (audio_hub) |h| {
        s.pa_hub_fd = h.fd;
        s.pa_socket_path = h.display_path;
        audio_hub = null; // ownership moved to the session
    }
    // WAV capture rides the hub: without one no PCM ever reaches
    // the daemon, so silently dropping the request would lie.
    if (req.audio_capture.len > 0 and s.pa_hub_fd >= 0)
        s.audio_capture_base = allocator.dupe(u8, req.audio_capture) catch null;
    if (rt_dir_owned) |p| {
        s.runtime_dir_path = p;
        rt_dir_owned = null; // ownership moved to the session
    }
    if (a11y_hub) |h| {
        s.a11y = h;
        a11y_hub = null; // ownership moved to the session
    }
    if (ws_gate.want) create_ws: {
        const w = allocator.create(WsSource) catch break :create_ws;
        if (ws_gate.use_sck) {
            w.* = WsSource.initSck(allocator, s.childPid()) catch |err| {
                log.warn("window capture init failed ({s}) — session '{s}' has no app streaming", .{ @errorName(err), req.name });
                allocator.destroy(w);
                break :create_ws;
            };
        } else {
            w.* = WsSource.initStub(allocator);
        }
        s.winstream = w;
    }
    screen.sink = .{ .ctx = @ptrCast(s), .on_write_pty = Session.sinkWritePty };
    log.info("session '{s}' spawned kind={s} child_pid={d} {d}x{d} wl={s} a11y={s}", .{
        req.name,
        if (req.app) "app" else "shell",
        s.childPid(),
        req.cols,
        req.rows,
        s.wl_display_path orelse "-",
        if (s.a11y != null) "on" else "off",
    });
    return s;
}

pub fn handleAttach(self: *Daemon, cl: *Client, payload: []const u8) void {
    if (cl.proto == 0 or cl.snapshot_version == 0) {
        cl.queueErr("no shared terminal profile; session preserved");
        return;
    }
    if (self.is_broker) return brokerAttach(self, cl, payload);
    var parsed = std.json.parseFromSlice(AttachReq, self.allocator, payload, .{
        .ignore_unknown_fields = true,
    }) catch {
        cl.queueErr("bad attach request");
        return;
    };
    defer parsed.deinit();
    // A REFUSED attach used to log nothing at all, which made the log
    // unable to answer the one question a GUI post-mortem needs: did the
    // client even get as far as asking? Log both refusals.
    const s = findSession(self, parsed.value.name) orelse {
        log.info("client attach REFUSED session='{s}' kind={s}: no such session", .{ parsed.value.name, parsed.value.kind });
        cl.queueErr("no such session");
        return;
    };
    if (s.exited) {
        // The corpse only lingers until the next reap; attaching
        // to it would wedge the client on a dead screen.
        log.info("client attach REFUSED session='{s}' kind={s}: session has exited", .{ parsed.value.name, parsed.value.kind });
        cl.queueErr("session has exited");
        return;
    }
    cl.attached = s;
    log.info("client attach session='{s}' kind={s} proto={d}", .{ s.name, parsed.value.kind, cl.proto });
    cl.read_only = parsed.value.read_only;
    cl.kind = if (std.mem.eql(u8, parsed.value.kind, "gui"))
        .gui
    else if (std.mem.eql(u8, parsed.value.kind, "cli"))
        .cli
    else if (std.mem.eql(u8, parsed.value.kind, "mcp"))
        .mcp
    else
        .unknown;
    // A (re)attaching client has no prior video reference frames, so
    // force the next video tile on every live surface to be a
    // keyframe. No-op unless video is active (vstate is otherwise
    // empty). rudp makes the transport reliable, so this — not
    // loss-recovery — is the only keyframe trigger needed.
    for (self.channels.items) |ch| {
        if (ch.session == s) {
            if (ch.native) |nv| {
                var vit = nv.vstate.valueIterator();
                while (vit.next()) |v| v.needs_kf = true;
            }
        }
    }
    self.queueSnapshot(cl, s);
    // Cast playback auto-starts once its first viewer arrives.
    self.castOnAttach(s, nowMs());
    if (cl.winstream_channels and s.winstream != null) self.openWinstreamChan(s, cl);
    if (cl.native_state_max >= wire.LEGACY_NATIVE_STATE_VERSION or cl.audio_channels) self.replayNativeChannels(cl, s);
    self.refreshVideoGates();
    _ = self.acquireControl(s, cl, parsed.value.control);
    self.broadcastControlState(s);
    self.broadcastPeerInfo(s);
}
