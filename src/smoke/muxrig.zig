//! Hosting a real broker from a smoke rig.
//!
//! Every daemon is a broker that forks one worker per session, and
//! `fork` from a process with other threads is a deadlock waiting to
//! happen (a lock held by any other thread at that instant stays held
//! forever in the child). So a rig never hosts the daemon in a thread:
//! `forkBroker` forks it as its own single-threaded process BEFORE the
//! rig starts any thread, and the rig drives it over the socket.
//!
//! The daemon-side leak check that used to run in the rig's own GPA
//! moves with the daemon: the broker child runs on a leak-checked
//! allocator of its own and every worker on another (`worker_entry`),
//! and a leak anywhere becomes a nonzero exit that `waitBroker` turns
//! into a failed rig. `SKETERM_SMOKE_BROKER_BIN=<path>` execs that
//! binary as the broker instead, which is how the static-musl build is
//! driven through the same cycle.

const std = @import("std");
const c = @import("../c.zig").c;
const platform = @import("../util/platform.zig");
const lifetime = @import("../util/lifetime.zig");
const daemon_mod = @import("../mux/daemon.zig");
const client_mod = @import("../mux/client.zig");
const selfexec = @import("../mux/selfexec.zig");
const wire = @import("../mux/wire.zig");
const snapshot = @import("../mux/snapshot.zig");
const Screen = @import("../grid/screen.zig").Screen;
const Pool = @import("../grid/style_pool.zig").Pool;
const SpawnReq = daemon_mod.SpawnReq;
const SessionOriginId = daemon_mod.SessionOriginId;

/// Exit statuses of a rig-hosted broker, decoded by `waitBroker`.
pub const Exit = enum(u8) {
    ok = 0,
    /// `Daemon.init` or the lifetime fence failed.
    init = 3,
    /// `run()` returned an error.
    run = 4,
    /// The broker leaked memory.
    leak = 5,
    /// At least one worker exited nonzero (a leak of its own, or a
    /// failed poll loop); the broker's log names it.
    worker_failed = 6,
    /// A worker leaked memory (the worker's own exit status).
    worker_leak = 7,
    _,
};

/// Environment override: exec this binary as the broker instead of
/// hosting one in-process.
pub const BROKER_BIN_ENV = "SKETERM_SMOKE_BROKER_BIN";

fn fail(comptime rig: []const u8, comptime msg: []const u8) noreturn {
    std.debug.print(rig ++ ": FAIL: " ++ msg ++ "\n", .{});
    std.process.exit(1);
}

/// The rig's worker: the production worker on a fresh leak-checked
/// allocator (the broker's own is a copy-on-write image of the parent's
/// and would report the parent's live objects as leaks).
fn leakCheckedWorker(
    _: std.mem.Allocator,
    control_fd: c_int,
    req: SpawnReq,
    origin_id: SessionOriginId,
    base_dir: []const u8,
    broker_sock: []const u8,
) u8 {
    var gpa: std.heap.DebugAllocator(.{ .safety = true }) = .{};
    const rc = daemon_mod.Daemon.runWorker(gpa.allocator(), control_fd, req, origin_id, base_dir, broker_sock);
    if (gpa.deinit() == .leak) {
        std.debug.print("smoke rig: session worker pid={d} leaked memory (see the GPA report above)\n", .{c.getpid()});
        return @intFromEnum(Exit.worker_leak);
    }
    return rc;
}

/// Fork the broker serving `sock_path` and wait until it listens. The
/// caller must have armed the lifetime fence (the broker and its workers
/// then retire when the rig dies by any path) and must not have started
/// a thread yet.
pub fn forkBroker(comptime rig: []const u8, sock_path: []const u8) c.pid_t {
    if (!lifetime.armed()) fail(rig, "the lifetime fence must be armed before the broker is forked");
    var bin_buf: [4096:0]u8 = undefined;
    const exec_bin: ?[:0]const u8 = if (c.getenv(BROKER_BIN_ENV)) |v|
        std.fmt.bufPrintZ(&bin_buf, "{s}", .{std.mem.span(@as([*:0]const u8, @ptrCast(v)))}) catch fail(rig, BROKER_BIN_ENV ++ " is too long")
    else
        null;
    var sock_z_buf: [4096:0]u8 = undefined;
    const sock_z = std.fmt.bufPrintZ(&sock_z_buf, "{s}", .{sock_path}) catch fail(rig, "socket path too long");

    const pid = c.fork();
    if (pid < 0) fail(rig, "fork broker");
    if (pid == 0) {
        if (exec_bin) |bin| {
            // The fence read end is inheritable and named in the
            // environment, so the exec'd daemon fences itself.
            const argv = [_:null]?[*:0]const u8{ selfexec.BINARY, selfexec.SOCKET_FLAG, sock_z.ptr, null };
            _ = c.execv(bin.ptr, @ptrCast(@constCast(&argv)));
            c._exit(@intFromEnum(Exit.init));
        }
        // A forked (non-exec) child inherited the fence's WRITE end too:
        // drop it, or this child keeps its own fence alive.
        lifetime.dropWriteEnd();
        // Every real daemon entry point neuters SIGPIPE; a forked broker
        // that skips it dies of signal 13 the first time a worker or a
        // client drops its socket mid-write.
        platform.ignoreSigpipe();
        var gpa: std.heap.DebugAllocator(.{ .safety = true }) = .{};
        const d = daemon_mod.Daemon.init(gpa.allocator(), sock_path) catch c._exit(@intFromEnum(Exit.init));
        d.lifetime_fd = lifetime.inherited() catch c._exit(@intFromEnum(Exit.init));
        d.worker_entry = leakCheckedWorker;
        d.run() catch |err| {
            std.debug.print(rig ++ ": broker run error: {s}\n", .{@errorName(err)});
            c._exit(@intFromEnum(Exit.run));
        };
        const failures = d.worker_failures;
        d.deinit();
        if (gpa.deinit() == .leak) {
            std.debug.print(rig ++ ": broker leaked memory (see the GPA report above)\n", .{});
            c._exit(@intFromEnum(Exit.leak));
        }
        if (failures != 0) c._exit(@intFromEnum(Exit.worker_failed));
        c._exit(0);
    }
    waitForSocket(rig, sock_path);
    return pid;
}

fn waitForSocket(comptime rig: []const u8, sock_path: []const u8) void {
    var tries: usize = 0;
    while (tries < 250) : (tries += 1) {
        if (client_mod.Conn.connect(std.heap.page_allocator, sock_path)) |conn| {
            var cc = conn;
            cc.deinit();
            return;
        } else |_| {}
        _ = c.usleep(20_000);
    }
    fail(rig, "broker socket never came up");
}

/// After the rig's shutdown frame: the broker must exit by itself,
/// cleanly, within `timeout_ms`. Reaching the SIGKILL backstop is itself
/// a failure, and so is any nonzero status (decoded by `Exit`).
pub fn waitBroker(comptime rig: []const u8, pid: c.pid_t, timeout_ms: u32) void {
    var status: c_int = 0;
    var waited: u32 = 0;
    while (waited < timeout_ms) : (waited += 20) {
        if (c.waitpid(pid, &status, c.WNOHANG) == pid) break;
        _ = c.usleep(20_000);
    } else {
        _ = c.kill(pid, c.SIGKILL);
        var killed: c_int = 0;
        _ = c.waitpid(pid, &killed, 0);
        fail(rig, "broker still alive after the shutdown frame (the SIGKILL backstop was needed)");
    }
    if (c.WIFSIGNALED(status)) {
        std.debug.print(rig ++ ": broker died on signal {d}\n", .{c.WTERMSIG(status)});
        fail(rig, "broker died on a signal instead of shutting down");
    }
    const code = c.WEXITSTATUS(status);
    if (code == 0) return;
    const why: []const u8 = switch (@as(Exit, @enumFromInt(code))) {
        .init => "init or lifetime fence failed",
        .run => "run() returned an error",
        .leak => "the broker leaked memory",
        .worker_failed => "a session worker exited nonzero (leak or failed poll loop; see mux.log)",
        .worker_leak => "a session worker leaked memory",
        else => "unknown",
    };
    std.debug.print(rig ++ ": broker exit code {d}: {s}\n", .{ code, why });
    fail(rig, "broker exited nonzero");
}

const SessionList = struct {
    sessions: []struct {
        name: []const u8 = "",
        wl_display: []const u8 = "",
    } = &.{},
};

/// The Wayland display socket of the session called `name`, as the
/// daemon lists it. Sockets are named by the owning worker's pid, so
/// this is the ONLY way a rig may learn one.
pub fn sessionWlDisplay(comptime rig: []const u8, allocator: std.mem.Allocator, sock_path: []const u8, name: []const u8, out: *[256]u8) []const u8 {
    var conn = client_mod.Conn.connect(allocator, sock_path) catch fail(rig, "wl lookup connect");
    defer conn.deinit();
    conn = client_mod.Conn.probe(allocator, conn) catch fail(rig, "wl lookup probe");
    conn.sendFrame(.list, "") catch fail(rig, "wl lookup list send");
    const f = conn.recvExpectFor(&.{.welcome}, 10_000) catch fail(rig, "wl lookup list reply");
    defer f.deinit(allocator);
    const parsed = std.json.parseFromSlice(SessionList, allocator, f.payload, .{ .ignore_unknown_fields = true }) catch fail(rig, "wl lookup list parse");
    defer parsed.deinit();
    for (parsed.value.sessions) |s| {
        if (!std.mem.eql(u8, s.name, name)) continue;
        if (s.wl_display.len == 0) fail(rig, "session lists no Wayland display socket");
        if (s.wl_display.len > out.len) fail(rig, "Wayland display path too long");
        @memcpy(out[0..s.wl_display.len], s.wl_display);
        return out[0..s.wl_display.len];
    }
    fail(rig, "session not listed while looking up its Wayland display");
}

/// Client-side mirror: snapshot restore + event application, so a rig
/// can read a session's screen text and confirm typed input echoed.
pub const Mirror = struct {
    allocator: std.mem.Allocator,
    pool: *Pool,
    screen: ?*Screen = null,

    pub fn applySnapshot(self: *Mirror, payload: []const u8) !void {
        if (payload.len < 9) return error.Truncated; // [seq:u64][app:u8] header
        if (self.screen) |s| s.deinit();
        self.screen = null;
        self.pool.deinit();
        self.pool.* = try Pool.init(self.allocator);
        self.screen = try snapshot.restore(self.allocator, self.pool, (try snapshot.peelEnvelope(payload)).body);
    }

    pub fn applyEvents(self: *Mirror, payload: []const u8) !void {
        const screen = self.screen orelse return error.NoScreen;
        if (payload.len < 12) return error.Truncated;
        var r = wire.Reader.init(payload[12..]);
        while (!r.atEnd()) {
            var ev = try r.getEvent(self.allocator);
            screen.apply(ev);
            ev.deinit(self.allocator);
        }
    }

    pub fn text(self: *Mirror) ![]u8 {
        return (self.screen orelse return error.NoScreen).extractScreen(self.allocator);
    }
};

/// Spawn a `cat` session called `name` on a welcomed connection.
pub fn spawnCat(comptime rig: []const u8, allocator: std.mem.Allocator, conn: *client_mod.Conn, name: []const u8) void {
    conn.sendJson(.spawn, .{
        .name = name,
        .argv = [_][]const u8{"cat"},
        .rows = @as(u16, 24),
        .cols = @as(u16, 80),
    }) catch fail(rig, "spawn send");
    (conn.recvExpectFor(&.{.ok}, 10_000) catch fail(rig, "spawn ok")).deinit(allocator);
}

/// Attach a welcomed connection to `name`, type `token`, and confirm it
/// echoes back on the session's screen (cat echoes stdin; the PTY
/// echoes too), then detach. Any transport: the reads are deadline
/// reads, never a socket timeout option.
pub fn attachAndEcho(comptime rig: []const u8, allocator: std.mem.Allocator, conn: *client_mod.Conn, name: []const u8, token: []const u8) void {
    conn.sendJson(.attach, .{ .name = name }) catch fail(rig, "echo attach");
    const snap = conn.recvExpectFor(&.{.snapshot}, 10_000) catch fail(rig, "echo snapshot");

    var mirror = Mirror{ .allocator = allocator, .pool = allocator.create(Pool) catch fail(rig, "echo pool") };
    mirror.pool.* = Pool.init(allocator) catch fail(rig, "echo pool init");
    defer {
        if (mirror.screen) |s| s.deinit();
        mirror.pool.deinit();
        allocator.destroy(mirror.pool);
    }
    mirror.applySnapshot(snap.payload) catch fail(rig, "echo snap apply");
    snap.deinit(allocator);

    var line_buf: [128]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, "{s}\n", .{token}) catch unreachable;
    conn.sendFrame(.input, line) catch fail(rig, "echo input");

    var tries: usize = 0;
    while (tries < 200) : (tries += 1) {
        const f = conn.recvExpectFor(&.{.events}, 5_000) catch fail(rig, "echo stream read");
        defer f.deinit(allocator);
        mirror.applyEvents(f.payload) catch fail(rig, "echo events apply");
        const txt = mirror.text() catch fail(rig, "echo extract");
        defer allocator.free(txt);
        if (std.mem.indexOf(u8, txt, token) != null) {
            conn.sendJson(.detach, .{}) catch {};
            (conn.recvExpectFor(&.{.ok}, 5_000) catch fail(rig, "echo detach ok")).deinit(allocator);
            return;
        }
    }
    fail(rig, "echo: token never appeared on the session screen");
}
