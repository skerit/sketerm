//! Session lifecycle — spawn/attach, the Wayland/audio hub sockets,
//! and broker-mode forwarding to per-session workers — split out of
//! daemon.zig. Functions take the owning *Daemon and are aliased back
//! into Daemon.

const std = @import("std");
const builtin = @import("builtin");
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
const SessionOriginId = dmod.SessionOriginId;
const daemon_serve = @import("daemon_serve.zig");
const controlSend = daemon_serve.controlSend;
const PassedClient = daemon_serve.PassedClient;
const WORKER_META_BUF = daemon_serve.WORKER_META_BUF;
const runWorker = daemon_serve.runWorker;
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
        if (s.matchesName(name)) return s;
    }
    return null;
}

fn validOutputSize(req: SpawnReq) bool {
    if (req.output_width == 0 or req.output_height == 0) return false;
    if (req.output_width > 16_384 or req.output_height > 16_384) return false;
    return @as(u64, req.output_width) * req.output_height <= 64 * 1024 * 1024;
}

const SpawnNormalizeError = error{
    BadSpawnRequest,
    SpawnNeedsName,
    InvalidTerminalSize,
    InvalidOutputSize,
    OutOfMemory,
};

/// Owns the parsed request and any injected login-shell storage until deinit.
const NormalizedSpawnRequest = struct {
    allocator: std.mem.Allocator,
    parsed: std.json.Parsed(SpawnReq),
    req: SpawnReq,
    owned_shell: ?[]u8 = null,
    owned_argv: ?[][]const u8 = null,

    fn deinit(self: *NormalizedSpawnRequest) void {
        if (self.owned_argv) |argv| self.allocator.free(argv);
        if (self.owned_shell) |shell| self.allocator.free(shell);
        self.parsed.deinit();
    }
};

fn normalizeSpawnRequest(
    allocator: std.mem.Allocator,
    payload: []const u8,
    account_shell: *const fn () []const u8,
) SpawnNormalizeError!NormalizedSpawnRequest {
    var parsed = std.json.parseFromSlice(SpawnReq, allocator, payload, .{
        .ignore_unknown_fields = true,
    }) catch return error.BadSpawnRequest;
    errdefer parsed.deinit();

    var req = parsed.value;
    if (req.name.len == 0 or req.name.len > 64) return error.SpawnNeedsName;
    wire.validateTerminalSize(req.rows, req.cols) catch return error.InvalidTerminalSize;
    if (!validOutputSize(req)) return error.InvalidOutputSize;

    var owned_shell: ?[]u8 = null;
    errdefer if (owned_shell) |shell| allocator.free(shell);
    var owned_argv: ?[][]const u8 = null;
    errdefer if (owned_argv) |argv| allocator.free(argv);

    // Empty argv = "the daemon host's login shell" — remote clients cannot
    // know what's installed here. Displays and casts substitute no shell.
    if (req.argv.len == 0 and !req.display and req.cast_path.len == 0) {
        owned_shell = try allocator.dupe(u8, account_shell());
        owned_argv = try allocator.alloc([]const u8, 1);
        owned_argv.?[0] = owned_shell.?;
        req.argv = owned_argv.?;
        req.login_shell = true;
    }

    return .{
        .allocator = allocator,
        .parsed = parsed,
        .req = req,
        .owned_shell = owned_shell,
        .owned_argv = owned_argv,
    };
}

const SpawnEntry = enum { monolith, broker };

/// Owns a normalized request and records the entry path's namespace lookup.
const PreparedSpawnRequest = struct {
    normalized: NormalizedSpawnRequest,
    name_exists: bool,

    fn deinit(self: *PreparedSpawnRequest) void {
        self.normalized.deinit();
    }
};

fn prepareSpawnRequest(
    self: *Daemon,
    payload: []const u8,
    entry: SpawnEntry,
    account_shell: *const fn () []const u8,
) SpawnNormalizeError!PreparedSpawnRequest {
    var normalized = try normalizeSpawnRequest(self.allocator, payload, account_shell);
    errdefer normalized.deinit();
    const name_exists = switch (entry) {
        .monolith => findSession(self, normalized.req.name) != null,
        .broker => brokerNameInUse(self, normalized.req.name, null),
    };
    return .{ .normalized = normalized, .name_exists = name_exists };
}

fn spawnNormalizeErrorText(err: SpawnNormalizeError) []const u8 {
    return switch (err) {
        error.BadSpawnRequest => "bad spawn request",
        error.SpawnNeedsName => "spawn needs a name",
        error.InvalidTerminalSize => wire.TERMINAL_SIZE_PROTOCOL_ERROR,
        error.InvalidOutputSize => "bad output size (dimensions must be 1..16384 and at most 64 megapixels)",
        error.OutOfMemory => "oom",
    };
}

fn queueSpawnNormalizeError(cl: *Client, err: SpawnNormalizeError) void {
    cl.queueErr(spawnNormalizeErrorText(err));
}

fn nameExistsText(buf: *[192]u8, name: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "session '{s}' already exists (use a different name or destroy it)", .{name}) catch "session name already exists";
}

fn queueNameExists(cl: *Client, name: []const u8) void {
    var buf: [192]u8 = undefined;
    cl.queueErr(nameExistsText(&buf, name));
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
    var prepared = prepareSpawnRequest(self, payload, .monolith, shell_util.accountLoginShell) catch |err| {
        queueSpawnNormalizeError(cl, err);
        return;
    };
    defer prepared.deinit();
    const req = prepared.normalized.req;
    if (prepared.name_exists) {
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
        .origin_name = s.origin_name,
        .origin_id = &s.origin_id,
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
        if (!w.dead and w.matchesName(name)) return w;
    }
    return null;
}

fn brokerNameInUse(self: *Daemon, name: []const u8, except: ?*Worker) bool {
    for (self.workers.items) |w| {
        if (w.dead or w == except) continue;
        if (w.matchesName(name)) return true;
    }
    return false;
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

fn workerKeepsFd(fd: c_int, control_fd: c_int, scan_fd: c_int) bool {
    return fd <= 2 or fd == control_fd or fd == log.inheritedFd() or fd == scan_fd;
}

/// Close every descriptor except the worker control channel, stdio, and log.
pub fn closeInheritedBrokerFds(self: *Daemon, control_fd: c_int) void {
    _ = self;
    // Enumerate what is actually open when the OS says: /proc/self/fd
    // on Linux, /dev/fd (fdescfs) on Darwin, which lists this process's
    // descriptors in the same shape. Exact, and O(open fds) rather than
    // O(limit) — which matters more now that the watcher raises the
    // soft limit (fsserve.raiseFileLimit).
    const fd_dir: ?[*:0]const u8 = switch (builtin.os.tag) {
        .linux => "/proc/self/fd",
        .macos => "/dev/fd",
        else => null,
    };
    if (fd_dir) |dir_path| {
        if (c.opendir(dir_path)) |dir| {
            defer _ = c.closedir(dir);
            const scan_fd = c.dirfd(dir);
            while (c.readdir(dir)) |ent| {
                const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
                const fd = std.fmt.parseInt(c_int, name, 10) catch continue;
                if (!workerKeepsFd(fd, control_fd, scan_fd)) _ = c.close(fd);
            }
            return;
        }
    }
    // Fallback sweep. Bound it by the HARD limit rather than
    // sysconf(_SC_OPEN_MAX), which reports the SOFT one: the soft limit
    // is raised at runtime, and anything that lowers it again would
    // leave live descriptors sitting above the sysconf answer — i.e.
    // inherited into a worker, unclosed, invisible.
    const RLimit = extern struct { rlim_cur: u64, rlim_max: u64 };
    const S = struct {
        extern "c" fn getrlimit(resource: c_int, rlim: *RLimit) c_int;
    };
    const RLIMIT_NOFILE: c_int = if (builtin.os.tag == .macos) 8 else 7;
    var bound: u64 = 65_536;
    var rl: RLimit = undefined;
    if (S.getrlimit(RLIMIT_NOFILE, &rl) == 0) {
        // rlim_max is RLIM_INFINITY on Darwin, so clamp: an unbounded
        // sweep is a hang, not thoroughness.
        bound = @max(rl.rlim_cur, @min(rl.rlim_max, 65_536));
    }
    const max_fd: c_int = @intCast(@min(@max(bound, 1024), 262_144));
    var fd: c_int = 3;
    while (fd < max_fd) : (fd += 1) {
        if (!workerKeepsFd(fd, control_fd, -1)) _ = c.close(fd);
    }
}

/// Broker side of spawn: fork a worker process that owns this session.
/// fork-without-exec — the child runs `runWorker` against an inherited
/// (COW) copy of the SpawnReq; it first drops every broker fd it inherited.
pub fn brokerSpawn(self: *Daemon, cl: *Client, payload: []const u8) void {
    var prepared = prepareSpawnRequest(self, payload, .broker, shell_util.accountLoginShell) catch |err| {
        queueSpawnNormalizeError(cl, err);
        return;
    };
    defer prepared.deinit();
    const req = prepared.normalized.req;
    if (prepared.name_exists) {
        queueNameExists(cl, req.name);
        return;
    }
    const origin_id = dmod.newSessionOriginId() catch {
        cl.queueErr("spawn failed: session origin entropy unavailable");
        return;
    };

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
        // before the parent's normalized request is released.
        _ = c.close(sp[0]);
        closeInheritedBrokerFds(self, sp[1]);
        _ = c.setsid();
        applyWorkerLimits();
        // Hand the worker the broker's socket dir so its Wayland display /
        // isolated-rt sockets land in the right runtime dir (the worker has
        // no listen socket of its own to derive it from). COW-valid here.
        const dir_end = std.mem.lastIndexOfScalar(u8, self.sock_path, '/') orelse self.sock_path.len;
        runWorker(self.allocator, sp[1], req, origin_id, self.sock_path[0..dir_end], self.sock_path) catch {};
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
    const origin_owned = self.allocator.dupe(u8, req.name) catch {
        self.allocator.free(name_owned);
        _ = c.close(sp[0]);
        cl.queueErr("oom");
        return;
    };
    const w = self.allocator.create(Worker) catch {
        self.allocator.free(name_owned);
        self.allocator.free(origin_owned);
        _ = c.close(sp[0]);
        cl.queueErr("oom");
        return;
    };
    w.* = .{
        .allocator = self.allocator,
        .name = name_owned,
        .origin_name = origin_owned,
        .origin_id = origin_id,
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

fn testAccountLoginShell() []const u8 {
    return "/test/account-shell";
}

test "spawn preparation normalizes monolith and broker requests identically" {
    const t = std.testing;
    const account_shell = testAccountLoginShell();
    const ExpectedArgv = enum { command, shell, empty };
    const Case = struct {
        label: []const u8,
        payload: []const u8,
        expected_error: ?SpawnNormalizeError = null,
        expected_error_text: []const u8 = "",
        expected_collision: bool = false,
        expected_collision_text: []const u8 = "",
        expected_argv: ExpectedArgv = .command,
        expected_login_shell: bool = false,
        expected_rows: u16 = 24,
        expected_cols: u16 = 80,
        expected_output_width: u32 = wire.DEFAULT_OUTPUT_WIDTH,
        expected_output_height: u32 = wire.DEFAULT_OUTPUT_HEIGHT,
        expected_display: bool = false,
        expected_cast: bool = false,
    };
    const cases = [_]Case{
        .{
            .label = "bad json",
            .payload = "{",
            .expected_error = error.BadSpawnRequest,
            .expected_error_text = "bad spawn request",
        },
        .{
            .label = "empty name",
            .payload = "{}",
            .expected_error = error.SpawnNeedsName,
            .expected_error_text = "spawn needs a name",
        },
        .{
            .label = "long name",
            .payload = "{\"name\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}",
            .expected_error = error.SpawnNeedsName,
            .expected_error_text = "spawn needs a name",
        },
        .{
            .label = "name at boundary",
            .payload = "{\"name\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"argv\":[\"cmd\"]}",
        },
        .{
            .label = "zero grid",
            .payload = "{\"name\":\"grid-zero\",\"argv\":[\"cmd\"],\"rows\":0}",
            .expected_error = error.InvalidTerminalSize,
            .expected_error_text = wire.TERMINAL_SIZE_PROTOCOL_ERROR,
        },
        .{
            .label = "grid axis over boundary",
            .payload = "{\"name\":\"grid-axis-over\",\"argv\":[\"cmd\"],\"rows\":4097,\"cols\":1}",
            .expected_error = error.InvalidTerminalSize,
            .expected_error_text = wire.TERMINAL_SIZE_PROTOCOL_ERROR,
        },
        .{
            .label = "grid cells over boundary",
            .payload = "{\"name\":\"grid-cells-over\",\"argv\":[\"cmd\"],\"rows\":1025,\"cols\":1024}",
            .expected_error = error.InvalidTerminalSize,
            .expected_error_text = wire.TERMINAL_SIZE_PROTOCOL_ERROR,
        },
        .{
            .label = "grid cells at boundary",
            .payload = "{\"name\":\"grid-cells-max\",\"argv\":[\"cmd\"],\"rows\":1024,\"cols\":1024}",
            .expected_rows = 1024,
            .expected_cols = 1024,
        },
        .{
            .label = "grid axis at boundary",
            .payload = "{\"name\":\"grid-axis-max\",\"argv\":[\"cmd\"],\"rows\":4096,\"cols\":1}",
            .expected_rows = 4096,
            .expected_cols = 1,
        },
        .{
            .label = "zero output width",
            .payload = "{\"name\":\"output-zero-width\",\"argv\":[\"cmd\"],\"output_width\":0}",
            .expected_error = error.InvalidOutputSize,
            .expected_error_text = "bad output size (dimensions must be 1..16384 and at most 64 megapixels)",
        },
        .{
            .label = "zero output height",
            .payload = "{\"name\":\"output-zero-height\",\"argv\":[\"cmd\"],\"output_height\":0}",
            .expected_error = error.InvalidOutputSize,
            .expected_error_text = "bad output size (dimensions must be 1..16384 and at most 64 megapixels)",
        },
        .{
            .label = "output axis over boundary",
            .payload = "{\"name\":\"output-axis-over\",\"argv\":[\"cmd\"],\"output_width\":16385,\"output_height\":1}",
            .expected_error = error.InvalidOutputSize,
            .expected_error_text = "bad output size (dimensions must be 1..16384 and at most 64 megapixels)",
        },
        .{
            .label = "output pixels over boundary",
            .payload = "{\"name\":\"output-pixels-over\",\"argv\":[\"cmd\"],\"output_width\":16384,\"output_height\":4097}",
            .expected_error = error.InvalidOutputSize,
            .expected_error_text = "bad output size (dimensions must be 1..16384 and at most 64 megapixels)",
        },
        .{
            .label = "output pixels at boundary",
            .payload = "{\"name\":\"output-pixels-max\",\"argv\":[\"cmd\"],\"output_width\":16384,\"output_height\":4096}",
            .expected_output_width = 16384,
            .expected_output_height = 4096,
        },
        .{
            .label = "empty argv",
            .payload = "{\"name\":\"shell\"}",
            .expected_argv = .shell,
            .expected_login_shell = true,
        },
        .{
            .label = "display empty argv exception",
            .payload = "{\"name\":\"display\",\"display\":true}",
            .expected_argv = .empty,
            .expected_display = true,
        },
        .{
            .label = "cast empty argv exception",
            .payload = "{\"name\":\"cast\",\"cast_path\":\"/tmp/demo.cast\"}",
            .expected_argv = .empty,
            .expected_cast = true,
        },
        .{
            .label = "explicit argv preserves login flag",
            .payload = "{\"name\":\"explicit-login\",\"argv\":[\"cmd\"],\"login_shell\":true}",
            .expected_login_shell = true,
        },
        .{
            .label = "current name collision after shell injection",
            .payload = "{\"name\":\"taken\"}",
            .expected_collision = true,
            .expected_collision_text = "session 'taken' already exists (use a different name or destroy it)",
            .expected_argv = .shell,
            .expected_login_shell = true,
        },
        .{
            .label = "origin name collision",
            .payload = "{\"name\":\"spawned-as\",\"argv\":[\"cmd\"]}",
            .expected_collision = true,
            .expected_collision_text = "session 'spawned-as' already exists (use a different name or destroy it)",
        },
        .{
            .label = "dead broker identity is reusable",
            .payload = "{\"name\":\"dead-taken\",\"argv\":[\"cmd\"]}",
        },
    };

    var monolith_empty: [0]u8 = .{};
    var broker_empty: [0]u8 = .{};
    var monolith = Daemon{ .allocator = t.allocator, .listen_fd = -1, .sock_path = monolith_empty[0..] };
    var broker = Daemon{ .allocator = t.allocator, .listen_fd = -1, .sock_path = broker_empty[0..], .is_broker = true };

    var monolith_current = "taken".*;
    var monolith_origin = "spawned-as".*;
    var collision_session: Session = undefined;
    collision_session.name = monolith_current[0..];
    collision_session.origin_name = monolith_origin[0..];
    var session_items = [_]*Session{&collision_session};
    monolith.sessions = .{ .items = &session_items, .capacity = session_items.len };

    var broker_current = "taken".*;
    var broker_origin = "spawned-as".*;
    var collision_worker: Worker = undefined;
    collision_worker.name = broker_current[0..];
    collision_worker.origin_name = broker_origin[0..];
    collision_worker.dead = false;
    var dead_current = "dead-taken".*;
    var dead_origin = "dead-spawned-as".*;
    var dead_worker: Worker = undefined;
    dead_worker.name = dead_current[0..];
    dead_worker.origin_name = dead_origin[0..];
    dead_worker.dead = true;
    var worker_items = [_]*Worker{ &collision_worker, &dead_worker };
    broker.workers = .{ .items = &worker_items, .capacity = worker_items.len };
    for ([_][]const u8{ "taken", "spawned-as", "dead-taken", "dead-spawned-as", "free" }) |name| {
        try t.expectEqual(brokerFindWorker(&broker, name) != null, brokerNameInUse(&broker, name, null));
    }

    for (cases) |case| {
        var monolith_prepared: ?PreparedSpawnRequest = null;
        var monolith_error: ?SpawnNormalizeError = null;
        monolith_prepared = prepareSpawnRequest(&monolith, case.payload, .monolith, testAccountLoginShell) catch |err| blk: {
            monolith_error = err;
            break :blk null;
        };
        defer if (monolith_prepared) |*prepared| prepared.deinit();

        var broker_prepared: ?PreparedSpawnRequest = null;
        var broker_error: ?SpawnNormalizeError = null;
        broker_prepared = prepareSpawnRequest(&broker, case.payload, .broker, testAccountLoginShell) catch |err| blk: {
            broker_error = err;
            break :blk null;
        };
        defer if (broker_prepared) |*prepared| prepared.deinit();

        try t.expectEqual(monolith_error, broker_error);
        try t.expectEqual(case.expected_error, monolith_error);
        if (monolith_error) |err| {
            try t.expectEqualStrings(case.expected_error_text, spawnNormalizeErrorText(err));
            continue;
        }

        const monolith_ready = &monolith_prepared.?;
        const broker_ready = &broker_prepared.?;
        try t.expectEqual(monolith_ready.name_exists, broker_ready.name_exists);
        try t.expectEqual(case.expected_collision, monolith_ready.name_exists);

        var monolith_json: std.Io.Writer.Allocating = .init(t.allocator);
        defer monolith_json.deinit();
        var broker_json: std.Io.Writer.Allocating = .init(t.allocator);
        defer broker_json.deinit();
        try std.json.Stringify.value(monolith_ready.normalized.req, .{}, &monolith_json.writer);
        try std.json.Stringify.value(broker_ready.normalized.req, .{}, &broker_json.writer);
        try t.expectEqualStrings(monolith_json.written(), broker_json.written());

        const req = monolith_ready.normalized.req;
        try t.expectEqual(case.expected_login_shell, req.login_shell);
        try t.expectEqual(case.expected_rows, req.rows);
        try t.expectEqual(case.expected_cols, req.cols);
        try t.expectEqual(case.expected_output_width, req.output_width);
        try t.expectEqual(case.expected_output_height, req.output_height);
        try t.expectEqual(case.expected_display, req.display);
        try t.expectEqual(case.expected_cast, req.cast_path.len > 0);
        switch (case.expected_argv) {
            .command => {
                try t.expectEqual(@as(usize, 1), req.argv.len);
                try t.expectEqualStrings("cmd", req.argv[0]);
            },
            .shell => {
                try t.expectEqual(@as(usize, 1), req.argv.len);
                try t.expectEqualStrings(account_shell, req.argv[0]);
            },
            .empty => try t.expectEqual(@as(usize, 0), req.argv.len),
        }
        if (case.expected_collision) {
            var monolith_buf: [192]u8 = undefined;
            var broker_buf: [192]u8 = undefined;
            const monolith_text = nameExistsText(&monolith_buf, monolith_ready.normalized.req.name);
            const broker_text = nameExistsText(&broker_buf, broker_ready.normalized.req.name);
            try t.expectEqualStrings(monolith_text, broker_text);
            try t.expectEqualStrings(case.expected_collision_text, monolith_text);
        }
    }
}

test "spawn preparation owns login shell allocations failure-atomically" {
    const t = std.testing;
    const payload = "{\"name\":\"shell-oom\"}";

    for ([_]SpawnEntry{ .monolith, .broker }) |entry| {
        var empty: [0]u8 = .{};
        var baseline_allocator = t.FailingAllocator.init(t.allocator, .{});
        var daemon = Daemon{
            .allocator = baseline_allocator.allocator(),
            .listen_fd = -1,
            .sock_path = empty[0..],
            .is_broker = entry == .broker,
        };
        var prepared = try prepareSpawnRequest(&daemon, payload, entry, testAccountLoginShell);
        prepared.deinit();
        const allocations = baseline_allocator.alloc_index;
        try t.expect(allocations >= 2);

        var parse_oom = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
        daemon.allocator = parse_oom.allocator();
        try t.expectError(error.BadSpawnRequest, prepareSpawnRequest(&daemon, payload, entry, testAccountLoginShell));
        try t.expect(parse_oom.has_induced_failure);
        try t.expectEqualStrings("bad spawn request", spawnNormalizeErrorText(error.BadSpawnRequest));

        for (allocations - 2..allocations) |fail_index| {
            var shell_oom = t.FailingAllocator.init(t.allocator, .{ .fail_index = fail_index });
            daemon.allocator = shell_oom.allocator();
            try t.expectError(error.OutOfMemory, prepareSpawnRequest(&daemon, payload, entry, testAccountLoginShell));
            try t.expect(shell_oom.has_induced_failure);
            try t.expectEqualStrings("oom", spawnNormalizeErrorText(error.OutOfMemory));

            daemon.allocator = t.allocator;
            var retry = try prepareSpawnRequest(&daemon, payload, entry, testAccountLoginShell);
            retry.deinit();
        }
    }
}

test "new workers close every broker descriptor and release stale listeners" {
    const t = std.testing;
    const a = t.allocator;
    var dir_buf: [128]u8 = undefined;
    const dir = try std.fmt.bufPrintZ(&dir_buf, "/tmp/sketerm-worker-fds-{d}", .{c.getpid()});
    _ = c.mkdir(dir.ptr, 0o700);
    defer dmod.removeTreeBestEffort(dir);
    var path_buf: [160]u8 = undefined;
    const socket_path = try std.fmt.bufPrint(&path_buf, "{s}/mux.sock", .{dir});
    const broker = try Daemon.init(a, socket_path);
    broker.is_broker = true;
    defer broker.deinit();

    var client_pair: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), platform.socketpairCloexec(&client_pair));
    defer {
        if (client_pair[1] >= 0) _ = c.close(client_pair[1]);
    }
    const client = try a.create(Client);
    client.* = .{ .allocator = a, .fd = client_pair[0] };
    try broker.clients.append(a, client);

    var worker_pair: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), platform.controlSocketpair(&worker_pair, 4096));
    defer {
        if (worker_pair[1] >= 0) _ = c.close(worker_pair[1]);
    }
    const worker = try a.create(Worker);
    worker.* = Worker{
        .allocator = a,
        .name = try a.dupe(u8, "existing"),
        .origin_name = try a.dupe(u8, "existing"),
        .origin_id = "10000000000000000000000000000001".*,
        .pid = 1,
        .control_fd = worker_pair[0],
    };
    try broker.workers.append(a, worker);

    const udp_fd = platform.socketCloexec(c.AF_INET, c.SOCK_DGRAM, 0);
    try t.expect(udp_fd >= 0);
    var udp_addr = std.mem.zeroes(c.struct_sockaddr_in);
    if (@hasField(c.struct_sockaddr_in, "sin_len")) udp_addr.sin_len = @sizeOf(c.struct_sockaddr_in);
    udp_addr.sin_family = c.AF_INET;
    udp_addr.sin_addr.s_addr = c.htonl(c.INADDR_LOOPBACK);
    try t.expectEqual(@as(c_int, 0), c.bind(udp_fd, @ptrCast(&udp_addr), @sizeOf(c.struct_sockaddr_in)));
    var udp_len: c.socklen_t = @sizeOf(c.struct_sockaddr_in);
    try t.expectEqual(@as(c_int, 0), c.getsockname(udp_fd, @ptrCast(&udp_addr), &udp_len));

    var pipe_server: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), c.pipe(&pipe_server));
    defer {
        if (pipe_server[0] >= 0) _ = c.close(pipe_server[0]);
    }

    var child_control: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), platform.controlSocketpair(&child_control, 4096));
    defer {
        if (child_control[0] >= 0) _ = c.close(child_control[0]);
    }
    defer {
        if (child_control[1] >= 0) _ = c.close(child_control[1]);
    }

    const pid = c.fork();
    try t.expect(pid >= 0);
    if (pid == 0) {
        _ = c.close(child_control[0]);
        closeInheritedBrokerFds(broker, child_control[1]);
        var marker: u8 = 1;
        _ = c.send(child_control[1], &marker, 1, 0);
        _ = c.recv(child_control[1], &marker, 1, 0);
        c._exit(0);
    }
    var child_live = true;
    defer if (child_live) {
        _ = c.kill(pid, c.SIGKILL);
        _ = c.waitpid(pid, null, 0);
    };
    _ = c.close(child_control[1]);
    child_control[1] = -1;
    var marker: u8 = 0;
    try t.expectEqual(@as(isize, 1), c.recv(child_control[0], &marker, 1, 0));

    _ = c.close(broker.listen_fd);
    broker.listen_fd = -1;
    _ = c.close(client.fd);
    client.fd = -1;
    _ = c.close(worker.control_fd);
    worker.control_fd = -1;
    _ = c.close(udp_fd);
    _ = c.close(pipe_server[1]);
    pipe_server[1] = -1;

    // Each peer says "the broker's copy is gone" in its own dialect. A
    // stream socketpair and a pipe read 0 (EOF). The control pair is
    // SOCK_SEQPACKET on Linux, which also EOFs — but SOCK_DGRAM on
    // Darwin, where a closed peer surfaces as -1/ECONNRESET instead.
    // That is the `n <= 0` rule platform.controlSocketpair documents and
    // the production channel already follows; asserting it per peer
    // keeps the other two honest about a real EOF regression.
    const Peer = struct { fd: c_int, eofs: bool };
    for ([_]Peer{
        .{ .fd = client_pair[1], .eofs = true },
        .{ .fd = worker_pair[1], .eofs = platform.is_linux },
        .{ .fd = pipe_server[0], .eofs = true },
    }) |peer| {
        var pfd = c.struct_pollfd{ .fd = peer.fd, .events = c.POLLIN | c.POLLHUP, .revents = 0 };
        try t.expect(c.poll(&pfd, 1, 1_000) > 0);
        const n = c.read(peer.fd, &marker, 1);
        if (peer.eofs) try t.expectEqual(@as(isize, 0), n) else try t.expect(n <= 0);
    }

    const rebound_udp = platform.socketCloexec(c.AF_INET, c.SOCK_DGRAM, 0);
    try t.expect(rebound_udp >= 0);
    defer _ = c.close(rebound_udp);
    try t.expectEqual(@as(c_int, 0), c.bind(rebound_udp, @ptrCast(&udp_addr), @sizeOf(c.struct_sockaddr_in)));

    // The pathname survived the simulated broker crash, but no worker keeps
    // its listening socket live, so normal stale-socket recovery can replace it.
    const replacement = try Daemon.init(a, socket_path);
    defer replacement.deinit();

    try t.expectEqual(@as(isize, 1), c.send(child_control[0], &marker, 1, 0));
    var status: c_int = 0;
    try t.expectEqual(pid, c.waitpid(pid, &status, 0));
    child_live = false;
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
    if (!parsed.value.panel_only and (cl.proto == 0 or cl.snapshot_version == 0)) {
        cl.queueErr("no shared terminal profile; session preserved");
        return;
    }
    if (parsed.value.panel_only and
        (parsed.value.panel_rpc == 0 or parsed.value.panel_rpc > cl.panel_rpc_support))
    {
        cl.queueErr("panel-only attach requires panel_rpc capability");
        return;
    }
    const panel_rpc = @min(cl.panel_rpc_support, parsed.value.panel_rpc);
    const w = brokerFindWorker(self, parsed.value.name) orelse {
        cl.queueErr("no such session");
        return;
    };
    if (parsed.value.origin_id.len > 0 and
        (!dmod.validSessionOriginId(parsed.value.origin_id) or
            !std.mem.eql(u8, parsed.value.origin_id, &w.origin_id)))
    {
        cl.queueErr("session origin identity changed");
        return;
    }
    const kind: Client.Kind = if (std.mem.eql(u8, parsed.value.kind, "gui"))
        .gui
    else if (std.mem.eql(u8, parsed.value.kind, "cli"))
        .cli
    else if (std.mem.eql(u8, parsed.value.kind, "mcp"))
        .mcp
    else
        .unknown;
    const encoded = (PassedClient{
        .proto = cl.proto,
        .video = cl.video,
        .kind = kind,
        .native_state_max = cl.native_state_max,
        .snapshot_version = cl.snapshot_version,
        .audio_channels = cl.audio_channels,
        .winstream_channels = cl.winstream_channels,
        .read_only = parsed.value.read_only,
        .want_control = parsed.value.control,
        .panel_only = parsed.value.panel_only,
        .panel_rpc = panel_rpc,
        .identity_first = parsed.value.identity_first and panel_rpc > 0 and kind == .gui and
            !parsed.value.panel_only,
    }).encode();
    var msg: [1 + PassedClient.WIRE_SIZE]u8 = undefined;
    msg[0] = 'A';
    @memcpy(msg[1..], &encoded);
    // The one control datagram whose loss the client can see: without it the
    // attach silently never lands. Report it instead of dropping the fd.
    if (!controlSend(w.control_fd, &msg, cl.fd)) {
        cl.queueErr("session worker did not accept the client handoff");
        return;
    }
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
            .origin_name = w.origin_name,
            .origin_id = &w.origin_id,
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
    cl.queueJson(.welcome, .{ .proto = cl.proto, .daemon_pid = c.getpid(), .server_proto = wire.PROTO_VERSION, .min_proto = wire.MIN_SERVER_PROTO, .negotiation = @as(u8, 1), .version = version.string, .audio_opus = opuscodec.available(), .video = build_options.video, .sessions = infos.items });
}

/// Broker side of kill: send the worker a graceful 'K', stop routing its name,
/// and keep polling it until it flushes `.gone` and closes the control channel.
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
    if (parsed.value.origin_id.len > 0 and
        (!dmod.validSessionOriginId(parsed.value.origin_id) or
            !std.mem.eql(u8, parsed.value.origin_id, &w.origin_id)))
    {
        cl.queueErr("session origin identity changed");
        return;
    }
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
    _ = controlSend(w.control_fd, "K", -1);
    w.dead = true;
    cl.queueJson(.ok, .{ .ok = true });
}

test "broker kill origin fence preserves replacements and accepts exact or absent identity" {
    const t = std.testing;
    const a = t.allocator;
    var control: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), platform.controlSocketpair(&control, 4096));
    defer _ = c.close(control[0]);
    defer _ = c.close(control[1]);

    var empty: [0]u8 = .{};
    var broker = Daemon{ .allocator = a, .listen_fd = -1, .sock_path = empty[0..], .is_broker = true };
    defer broker.workers.deinit(a);
    var requester = Client{ .allocator = a, .fd = -1 };
    defer requester.rbuf.deinit(a);
    defer requester.wbuf.deinit(a);
    defer requester.audio_wbuf.deinit(a);
    var replacement = Worker{
        .allocator = a,
        .name = @constCast("same"),
        .origin_name = @constCast("same"),
        .origin_id = "20000000000000000000000000000002".*,
        .pid = 123,
        .control_fd = control[0],
    };
    try broker.workers.append(a, &replacement);

    brokerKill(&broker, &requester, "{\"name\":\"same\",\"origin_id\":\"10000000000000000000000000000001\"}");
    try t.expect(!replacement.dead);
    var reply = (try wire.peelFrame(requester.wbuf.items)) orelse return error.TestUnexpectedResult;
    try t.expectEqual(wire.FrameType.err, reply.frame.ftype);
    try t.expect(std.mem.indexOf(u8, reply.frame.payload, "origin identity changed") != null);
    var pfd = c.struct_pollfd{ .fd = control[1], .events = c.POLLIN, .revents = 0 };
    try t.expectEqual(@as(c_int, 0), c.poll(&pfd, 1, 0));

    requester.wbuf.clearRetainingCapacity();
    brokerKill(&broker, &requester, "{\"name\":\"same\",\"origin_id\":\"not-an-id\"}");
    try t.expect(!replacement.dead);
    reply = (try wire.peelFrame(requester.wbuf.items)) orelse return error.TestUnexpectedResult;
    try t.expectEqual(wire.FrameType.err, reply.frame.ftype);

    requester.wbuf.clearRetainingCapacity();
    brokerKill(&broker, &requester, "{\"name\":\"same\",\"origin_id\":\"20000000000000000000000000000002\"}");
    try t.expect(replacement.dead);
    var marker: [1]u8 = undefined;
    try t.expectEqual(@as(isize, 1), c.recv(control[1], &marker, marker.len, 0));
    try t.expectEqual(@as(u8, 'K'), marker[0]);

    replacement.dead = false;
    requester.wbuf.clearRetainingCapacity();
    brokerKill(&broker, &requester, "{\"name\":\"same\"}");
    try t.expect(replacement.dead);
    try t.expectEqual(@as(isize, 1), c.recv(control[1], &marker, marker.len, 0));
    try t.expectEqual(@as(u8, 'K'), marker[0]);
}

/// Answer whoever asked for a rename: a broker client directly, or the worker
/// that forwarded one of its attached clients' requests.
fn replyBrokerRename(
    self: *Daemon,
    w: *Worker,
    requester_id: u32,
    worker_request_id: u64,
    ok: bool,
    message: []const u8,
    name: []const u8,
) void {
    if (worker_request_id != 0) {
        var msg: [10 + 192]u8 = undefined;
        msg[0] = 'n';
        std.mem.writeInt(u64, msg[1..9], worker_request_id, .little);
        msg[9] = @intFromBool(ok);
        const detail = if (ok) name else message;
        const n = @min(detail.len, msg.len - 10);
        @memcpy(msg[10..][0..n], detail[0..n]);
        _ = controlSend(w.control_fd, msg[0 .. 10 + n], -1);
        return;
    }
    for (self.clients.items) |candidate| {
        if (candidate.id != requester_id or candidate.dead) continue;
        if (ok)
            candidate.queueJson(.ok, .{ .ok = true, .name = name })
        else
            candidate.queueErr(message);
        return;
    }
}

/// The broker owns routing, so it renames its own record and tells the worker.
/// A worker that never receives the 'R' keeps serving the same session under
/// its old display name; nothing routes by that name any more.
fn applyBrokerRename(
    self: *Daemon,
    w: *Worker,
    new_name: []const u8,
    requester_id: u32,
    worker_request_id: u64,
) void {
    if (brokerNameInUse(self, new_name, w)) {
        replyBrokerRename(self, w, requester_id, worker_request_id, false, "session name already exists", "");
        return;
    }
    w.renameTo(new_name) catch {
        replyBrokerRename(self, w, requester_id, worker_request_id, false, "oom", "");
        return;
    };
    var msg: [1 + dmod.MAX_SESSION_NAME]u8 = undefined;
    msg[0] = 'R';
    @memcpy(msg[1..][0..new_name.len], new_name);
    _ = controlSend(w.control_fd, msg[0 .. 1 + new_name.len], -1);
    replyBrokerRename(self, w, requester_id, worker_request_id, true, "", w.name);
}

pub fn brokerRename(self: *Daemon, cl: *Client, payload: []const u8) void {
    var parsed = std.json.parseFromSlice(RenameReq, self.allocator, payload, .{
        .ignore_unknown_fields = true,
    }) catch {
        cl.queueErr("bad rename request");
        return;
    };
    defer parsed.deinit();
    const req = parsed.value;
    if (!dmod.validSessionName(req.new_name)) {
        cl.queueErr("rename needs a name (1-64 chars)");
        return;
    }
    const w = brokerFindWorker(self, req.name) orelse {
        cl.queueErr("no such session");
        return;
    };
    applyBrokerRename(self, w, req.new_name, cl.id, 0);
}

/// Broker side of an attached-client rename request from the owning worker.
pub fn brokerWorkerRename(self: *Daemon, w: *Worker, payload: []const u8) void {
    if (payload.len < 9) return;
    const request_id = std.mem.readInt(u64, payload[1..9], .little);
    if (request_id == 0) return;
    const new_name = payload[9..];
    if (!dmod.validSessionName(new_name)) {
        replyBrokerRename(self, w, 0, request_id, false, "rename needs a name (1-64 chars)", "");
        return;
    }
    if (w.dead) {
        replyBrokerRename(self, w, 0, request_id, false, "session worker is no longer routable", "");
        return;
    }
    applyBrokerRename(self, w, new_name, 0, request_id);
}

test "broker rename renames the worker record and forwards one authoritative name" {
    const t = std.testing;
    const a = t.allocator;
    var control: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), platform.controlSocketpair(&control, 4096));
    defer _ = c.close(control[1]);

    var empty: [0]u8 = .{};
    var broker = Daemon{ .allocator = a, .listen_fd = -1, .sock_path = empty[0..], .is_broker = true };
    defer broker.clients.deinit(a);
    defer broker.workers.deinit(a);
    var requester = Client{ .allocator = a, .fd = -1, .id = 77 };
    defer requester.rbuf.deinit(a);
    defer requester.wbuf.deinit(a);
    defer requester.audio_wbuf.deinit(a);
    try broker.clients.append(a, &requester);

    const worker = try a.create(Worker);
    worker.* = .{
        .allocator = a,
        .name = try a.dupe(u8, "current"),
        .origin_name = try a.dupe(u8, "origin"),
        .origin_id = "70000000000000000000000000000007".*,
        .pid = 123,
        .control_fd = control[0],
        .ready = true,
    };
    defer worker.deinit();
    try broker.workers.append(a, worker);

    brokerRename(&broker, &requester, "{\"name\":\"current\",\"new_name\":\"fresh\"}");
    try t.expectEqualStrings("fresh", worker.name);
    // The immutable spawn name still resolves, so a child that captured it
    // before the rename can still attach.
    try t.expect(worker.matchesName("origin"));
    try t.expect(worker.matchesName("fresh"));
    try t.expect(!worker.matchesName("current"));
    const reply = (try wire.peelFrame(requester.wbuf.items)) orelse return error.TestUnexpectedResult;
    try t.expectEqual(wire.FrameType.ok, reply.frame.ftype);
    try t.expect(std.mem.indexOf(u8, reply.frame.payload, "fresh") != null);

    var buf: [128]u8 = undefined;
    var passed: c_int = -1;
    const n = daemon_serve.controlRecv(control[1], &buf, &passed);
    try t.expect(n > 1);
    try t.expectEqual(@as(u8, 'R'), buf[0]);
    try t.expectEqualStrings("fresh", buf[1..@intCast(n)]);

    // A name another worker already answers to is refused outright.
    var other_control: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), platform.controlSocketpair(&other_control, 4096));
    defer _ = c.close(other_control[1]);
    const other = try a.create(Worker);
    other.* = .{
        .allocator = a,
        .name = try a.dupe(u8, "taken"),
        .origin_name = try a.dupe(u8, "taken"),
        .origin_id = "80000000000000000000000000000008".*,
        .pid = 124,
        .control_fd = other_control[0],
        .ready = true,
    };
    defer other.deinit();
    try broker.workers.append(a, other);

    requester.wbuf.clearRetainingCapacity();
    brokerRename(&broker, &requester, "{\"name\":\"fresh\",\"new_name\":\"taken\"}");
    try t.expectEqualStrings("fresh", worker.name);
    const refusal = (try wire.peelFrame(requester.wbuf.items)) orelse return error.TestUnexpectedResult;
    try t.expectEqual(wire.FrameType.err, refusal.frame.ftype);
    try t.expect(std.mem.indexOf(u8, refusal.frame.payload, "already exists") != null);
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
    return spawnSessionWithOrigin(self, req_in, try dmod.newSessionOriginId());
}

pub fn spawnSessionWithOrigin(self: *Daemon, req_in: SpawnReq, origin_id: SessionOriginId) !*Session {
    try wire.validateTerminalSize(req_in.rows, req_in.cols);
    const allocator = self.allocator;

    // Cast playback: no child, no hubs, no PTY — its own spawn path.
    // Works identically in monolith and (via runWorker) broker mode.
    if (req_in.cast_path.len > 0) return self.spawnCastSessionWithOrigin(req_in, origin_id);

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
    const origin_id_z = try allocator.dupeZ(u8, &origin_id);
    defer allocator.free(origin_id_z);
    const owning_mux_socket = if (self.sock_path.len > 0)
        self.sock_path
    else if (self.broker_sock) |path|
        path
    else
        "";
    const mux_socket_z: ?[:0]u8 = if (owning_mux_socket.len > 0)
        allocator.dupeZ(u8, owning_mux_socket) catch null
    else
        null;
    defer if (mux_socket_z) |z| allocator.free(z);
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
        .session_origin_id = origin_id_z.ptr,
        .mux_socket_path = if (mux_socket_z) |z| z.ptr else null,
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
    const session_name = try allocator.dupe(u8, req.name);
    errdefer allocator.free(session_name);
    const origin_name = try allocator.dupe(u8, req.name);
    errdefer allocator.free(origin_name);
    s.* = .{
        .allocator = allocator,
        .name = session_name,
        .origin_name = origin_name,
        .origin_id = origin_id,
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
    if (self.is_broker) return brokerAttach(self, cl, payload);
    var parsed = std.json.parseFromSlice(AttachReq, self.allocator, payload, .{
        .ignore_unknown_fields = true,
    }) catch {
        cl.queueErr("bad attach request");
        return;
    };
    defer parsed.deinit();
    if (!parsed.value.panel_only and (cl.proto == 0 or cl.snapshot_version == 0)) {
        cl.queueErr("no shared terminal profile; session preserved");
        return;
    }
    if (parsed.value.panel_only and
        (parsed.value.panel_rpc == 0 or parsed.value.panel_rpc > cl.panel_rpc_support))
    {
        cl.queueErr("panel-only attach requires panel_rpc capability");
        return;
    }
    const panel_rpc = @min(cl.panel_rpc_support, parsed.value.panel_rpc);
    // A REFUSED attach used to log nothing at all, which made the log
    // unable to answer the one question a GUI post-mortem needs: did the
    // client even get as far as asking? Log both refusals.
    const s = findSession(self, parsed.value.name) orelse {
        log.info("client attach REFUSED session='{s}' kind={s}: no such session", .{ parsed.value.name, parsed.value.kind });
        cl.queueErr("no such session");
        return;
    };
    if (parsed.value.origin_id.len > 0 and
        (!dmod.validSessionOriginId(parsed.value.origin_id) or
            !std.mem.eql(u8, parsed.value.origin_id, &s.origin_id)))
    {
        cl.queueErr("session origin identity changed");
        return;
    }
    if (s.exited) {
        // The corpse only lingers until the next reap; attaching
        // to it would wedge the client on a dead screen.
        log.info("client attach REFUSED session='{s}' kind={s}: session has exited", .{ parsed.value.name, parsed.value.kind });
        cl.queueErr("session has exited");
        return;
    }
    const kind: Client.Kind = if (std.mem.eql(u8, parsed.value.kind, "gui"))
        .gui
    else if (std.mem.eql(u8, parsed.value.kind, "cli"))
        .cli
    else if (std.mem.eql(u8, parsed.value.kind, "mcp"))
        .mcp
    else
        .unknown;
    self.detachClientAttachment(cl, "panel presenter reattached after request delivery; delivery is uncertain, the mutation may have applied, and the request was NOT resent");
    cl.attached = s;
    cl.panel_only = parsed.value.panel_only;
    cl.panel_rpc = panel_rpc;
    cl.read_only = parsed.value.read_only or parsed.value.panel_only;
    cl.kind = kind;
    log.info("client attach session='{s}' kind={s} proto={d} panel_only={} panel_rpc={d}", .{
        s.name, parsed.value.kind, cl.proto, cl.panel_only, cl.panel_rpc,
    });
    if (cl.panel_only) {
        cl.queueJson(.ok, .{
            .ok = true,
            .panel_only = true,
            .name = s.name,
            .origin_name = s.origin_name,
            .origin_id = &s.origin_id,
        });
        self.broadcastPeerInfo(s);
        return;
    }
    if (parsed.value.identity_first and panel_rpc > 0 and cl.kind == .gui)
        self.queueAttachIdentity(cl, s);
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
