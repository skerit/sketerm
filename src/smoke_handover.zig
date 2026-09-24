//! Broker-restart stage (`zig build smoke-broker`): session workers
//! survive their broker, and the next broker adopts them.
//!
//! Against its own broker on its own socket it spawns a shell and a
//! `cat`, puts state in the shell (a variable), keeps one client attached
//! throughout, and then replaces the broker twice:
//!   1. a graceful upgrade: `quit_idle` + `handover` retires the broker
//!      while it holds both sessions, and a fresh broker adopts them;
//!   2. a crash: the broker is SIGKILLed and a fresh one adopts them.
//! After each, the still-attached client keeps working, a NEW client
//! reattaches through the new broker, and the shell expands the variable
//! set before the first restart (so it is the same shell, not a respawn).
//! Then the backstops: an adopted worker obeys kill, an explicit
//! `.shutdown` still ends every session, and an orphan whose broker was
//! SIGKILLed under a harness that then exits is reaped by the lifetime
//! fence even though no broker ever adopts it.
//!
//! Must run before the rig starts any thread: it forks brokers.

const std = @import("std");
const c = @import("c.zig").c;
const lifetime = @import("util/lifetime.zig");
const muxrig = @import("smoke/muxrig.zig");
const client_mod = @import("mux/client.zig");
const daemon_mod = @import("mux/daemon.zig");
const Pool = @import("grid/style_pool.zig").Pool;

const RIG = "smoke-handover";

fn fail(comptime msg: []const u8) noreturn {
    std.debug.print(RIG ++ ": FAIL: " ++ msg ++ "\n", .{});
    std.process.exit(1);
}

fn connect(allocator: std.mem.Allocator, sock: []const u8) client_mod.Conn {
    const conn = client_mod.Conn.connect(allocator, sock) catch fail("connect");
    return client_mod.Conn.probe(allocator, conn) catch fail("probe");
}

/// An attached client with a screen mirror.
const Viewer = struct {
    allocator: std.mem.Allocator,
    conn: client_mod.Conn,
    mirror: muxrig.Mirror,

    fn attach(allocator: std.mem.Allocator, sock: []const u8, name: []const u8) *Viewer {
        const v = allocator.create(Viewer) catch fail("oom");
        v.* = .{
            .allocator = allocator,
            .conn = connect(allocator, sock),
            .mirror = .{ .allocator = allocator, .pool = allocator.create(Pool) catch fail("oom") },
        };
        v.mirror.pool.* = Pool.init(allocator) catch fail("pool");
        v.conn.sendJson(.attach, .{ .name = name }) catch fail("attach send");
        const snap = v.conn.recvExpectFor(&.{.snapshot}, 10_000) catch fail("attach snapshot");
        defer snap.deinit(allocator);
        v.mirror.applySnapshot(snap.payload) catch fail("snapshot apply");
        return v;
    }

    fn deinit(v: *Viewer) void {
        v.conn.deinit();
        if (v.mirror.screen) |s| s.deinit();
        v.mirror.pool.deinit();
        v.allocator.destroy(v.mirror.pool);
        v.allocator.destroy(v);
    }

    /// Type `line` and wait until `want` shows on the screen.
    fn expect(v: *Viewer, line: []const u8, want: []const u8, comptime what: []const u8) void {
        v.conn.sendFrame(.input, line) catch fail(what ++ ": input");
        const deadline = @import("util/clock.zig").nowMs() + 10_000;
        while (@import("util/clock.zig").nowMs() < deadline) {
            const f = v.conn.recvExpectFor(&.{ .events, .snapshot }, 10_000) catch fail(what ++ ": stream read");
            defer f.deinit(v.allocator);
            if (f.ftype == .snapshot)
                v.mirror.applySnapshot(f.payload) catch fail(what ++ ": snapshot")
            else
                v.mirror.applyEvents(f.payload) catch fail(what ++ ": events");
            const txt = v.mirror.text() catch fail(what ++ ": text");
            defer v.allocator.free(txt);
            if (std.mem.indexOf(u8, txt, want) != null) return;
        }
        fail(what ++ ": expected text never appeared");
    }
};

const Listing = struct {
    daemon_pid: c.pid_t = 0,
    sessions: []struct { name: []const u8 = "", pid: i32 = 0 } = &.{},
};

/// Child pid of every listed session called `a` / `b` (0 = not listed).
fn listed(allocator: std.mem.Allocator, sock: []const u8, a: []const u8, b: []const u8) struct { a: i32, b: i32, daemon: c.pid_t } {
    var conn = connect(allocator, sock);
    defer conn.deinit();
    conn.sendFrame(.list, "") catch fail("list send");
    const f = conn.recvExpectFor(&.{.welcome}, 10_000) catch fail("list reply");
    defer f.deinit(allocator);
    const parsed = std.json.parseFromSlice(Listing, allocator, f.payload, .{ .ignore_unknown_fields = true }) catch fail("list parse");
    defer parsed.deinit();
    var out: @TypeOf(listed(allocator, sock, a, b)) = .{ .a = 0, .b = 0, .daemon = parsed.value.daemon_pid };
    for (parsed.value.sessions) |s| {
        if (std.mem.eql(u8, s.name, a)) out.a = s.pid;
        if (std.mem.eql(u8, s.name, b)) out.b = s.pid;
    }
    return out;
}

fn alive(pid: i32) bool {
    return pid > 0 and c.kill(pid, 0) == 0;
}

/// A fresh broker must list both sessions with the SAME child pids.
fn expectAdopted(allocator: std.mem.Allocator, sock: []const u8, broker: c.pid_t, shell_pid: i32, cat_pid: i32, comptime what: []const u8) void {
    const l = listed(allocator, sock, "keep", "second");
    if (l.daemon != broker) fail(what ++ ": list not answered by the new broker");
    if (l.a != shell_pid) fail(what ++ ": the shell session was not adopted (or is a different process)");
    if (l.b != cat_pid) fail(what ++ ": the cat session was not adopted");
}

pub fn run(allocator: std.mem.Allocator) void {
    var path_buf: [128]u8 = undefined;
    const sock = std.fmt.bufPrint(&path_buf, "/tmp/sketerm-ho-{d}/mux.sock", .{c.getpid()}) catch unreachable;

    const a_pid = muxrig.forkBroker(RIG, sock);
    {
        var conn = connect(allocator, sock);
        defer conn.deinit();
        if (!conn.caps.worker_handover) fail("broker does not advertise worker_handover");
        conn.sendJson(.spawn, .{
            .name = "keep",
            .argv = [_][]const u8{ "sh", "-i" },
            .rows = @as(u16, 24),
            .cols = @as(u16, 100),
        }) catch fail("spawn shell");
        (conn.recvExpectFor(&.{.ok}, 10_000) catch fail("spawn shell ok")).deinit(allocator);
        muxrig.spawnCat(RIG, allocator, &conn, "second");
    }
    const holder = Viewer.attach(allocator, sock, "keep");
    defer holder.deinit();
    holder.expect("HVX=HV-STATE-91; echo ${HVX}Z\n", "HV-STATE-91Z", "shell state");
    var pids = listed(allocator, sock, "keep", "second");
    const shell_pid = pids.a;
    const cat_pid = pids.b;
    if (!alive(shell_pid) or !alive(cat_pid)) fail("session child pids not listed");

    // ── 1. graceful upgrade: hand over, then a new broker adopts ──
    {
        var conn = connect(allocator, sock);
        defer conn.deinit();
        conn.sendJson(.quit_idle, .{ .handover = true }) catch fail("handover send");
        const f = conn.recvExpectFor(&.{.ok}, 5_000) catch fail("handover reply");
        defer f.deinit(allocator);
        if (std.mem.indexOf(u8, f.payload, "\"ok\":true") == null) {
            std.debug.print(RIG ++ ": handover reply: {s}\n", .{f.payload});
            fail("broker refused a handover it should grant");
        }
    }
    muxrig.waitBroker(RIG, a_pid, 10_000);
    if (!alive(shell_pid) or !alive(cat_pid)) fail("handover: a session died with its broker");
    holder.expect("echo ${HVX}Y\n", "HV-STATE-91Y", "handover: attached client while no broker runs");
    const b_pid = muxrig.forkBroker(RIG, sock);
    expectAdopted(allocator, sock, b_pid, shell_pid, cat_pid, "handover");
    {
        const v = Viewer.attach(allocator, sock, "keep");
        defer v.deinit();
        v.expect("echo ${HVX}W\n", "HV-STATE-91W", "handover: reattach through the new broker");
    }
    holder.expect("echo ${HVX}X\n", "HV-STATE-91X", "handover: attached client after adoption");
    std.debug.print(RIG ++ ": graceful upgrade handover + adoption + reattach ok\n", .{});

    // ── 2. crash: SIGKILL the broker, a new one adopts ──
    _ = c.kill(b_pid, c.SIGKILL);
    var st: c_int = 0;
    _ = c.waitpid(b_pid, &st, 0);
    if (!alive(shell_pid) or !alive(cat_pid)) fail("sigkill: a session died with its broker");
    holder.expect("echo ${HVX}V\n", "HV-STATE-91V", "sigkill: attached client while no broker runs");
    const c_pid = muxrig.forkBroker(RIG, sock);
    expectAdopted(allocator, sock, c_pid, shell_pid, cat_pid, "sigkill");
    {
        const v = Viewer.attach(allocator, sock, "keep");
        defer v.deinit();
        v.expect("echo ${HVX}U\n", "HV-STATE-91U", "sigkill: reattach through the new broker");
    }
    std.debug.print(RIG ++ ": broker SIGKILL + adoption + reattach ok\n", .{});

    // ── an adopted worker obeys kill; an explicit shutdown still ends
    // every session ──
    {
        var conn = connect(allocator, sock);
        defer conn.deinit();
        conn.sendJson(.kill, .{ .name = "second" }) catch fail("kill send");
        (conn.recvExpectFor(&.{.ok}, 5_000) catch fail("kill ok")).deinit(allocator);
    }
    var waited: usize = 0;
    while (waited < 250 and (alive(cat_pid) or listed(allocator, sock, "keep", "second").b != 0)) : (waited += 1) _ = c.usleep(20_000);
    if (alive(cat_pid)) fail("kill: adopted worker's session survived kill");
    pids = listed(allocator, sock, "keep", "second");
    if (pids.b != 0) fail("kill: adopted worker still listed");
    {
        var conn = client_mod.Conn.connect(allocator, sock) catch fail("shutdown connect");
        defer conn.deinit();
        conn.sendFrame(.shutdown, "") catch fail("shutdown send");
    }
    muxrig.waitBroker(RIG, c_pid, 10_000);
    waited = 0;
    while (waited < 250 and alive(shell_pid)) : (waited += 1) _ = c.usleep(20_000);
    if (alive(shell_pid)) fail("shutdown: the adopted session outlived an explicit shutdown");
    std.debug.print(RIG ++ ": adopted kill + shutdown end sessions ok\n", .{});

    orphanReapedByFence(allocator);
    std.debug.print(RIG ++ ": orphan reaped by the lifetime fence ok\n", .{});
}

/// A sub-harness with its OWN fence forks a broker, spawns a session,
/// SIGKILLs the broker and exits. Nobody adopts the orphan; the fence
/// must still end it.
fn orphanReapedByFence(allocator: std.mem.Allocator) void {
    var report: [2]c_int = undefined;
    if (c.pipe(&report) != 0) fail("report pipe");
    const sub = c.fork();
    if (sub < 0) fail("fork sub-harness");
    if (sub == 0) {
        _ = c.close(report[0]);
        // Not the rig's fence owner any more; own a fresh fence instead.
        lifetime.dropWriteEnd();
        var fence: [2]c_int = undefined;
        if (c.pipe(&fence) != 0) c._exit(10);
        _ = c.fcntl(fence[1], c.F_SETFD, c.FD_CLOEXEC);
        var num: [16:0]u8 = undefined;
        const s = std.fmt.bufPrintZ(&num, "{d}", .{fence[0]}) catch unreachable;
        _ = c.setenv(lifetime.ENV, s.ptr, 1);
        var path_buf: [128]u8 = undefined;
        const sock = std.fmt.bufPrint(&path_buf, "/tmp/sketerm-ho-{d}/mux.sock", .{c.getpid()}) catch unreachable;
        const broker = c.fork();
        if (broker < 0) c._exit(11);
        if (broker == 0) {
            _ = c.close(fence[1]);
            @import("util/platform.zig").ignoreSigpipe();
            const d = daemon_mod.Daemon.init(std.heap.c_allocator, sock) catch c._exit(12);
            d.lifetime_fd = lifetime.inherited() catch c._exit(13);
            d.run() catch c._exit(14);
            c._exit(0);
        }
        var tries: usize = 0;
        var conn = while (tries < 250) : (tries += 1) {
            if (client_mod.Conn.connect(std.heap.c_allocator, sock)) |cn| {
                break client_mod.Conn.probe(std.heap.c_allocator, cn) catch c._exit(15);
            } else |_| {}
            _ = c.usleep(20_000);
        } else c._exit(16);
        conn.sendJson(.spawn, .{
            .name = "orphan",
            .argv = [_][]const u8{ "sh", "-c", "sleep 60" },
            .rows = @as(u16, 24),
            .cols = @as(u16, 80),
        }) catch c._exit(17);
        const ok = conn.recvExpectFor(&.{.ok}, 10_000) catch c._exit(18);
        const Pid = struct { pid: i32 = 0 };
        const parsed = std.json.parseFromSlice(Pid, std.heap.c_allocator, ok.payload, .{ .ignore_unknown_fields = true }) catch c._exit(19);
        const child = parsed.value.pid;
        conn.deinit();
        _ = c.kill(broker, c.SIGKILL);
        var st: c_int = 0;
        _ = c.waitpid(broker, &st, 0);
        _ = c.usleep(300_000);
        // The orphan must still be alive here: only the fence may end it.
        if (c.kill(child, 0) != 0) c._exit(20);
        _ = c.write(report[1], std.mem.asBytes(&child), @sizeOf(i32));
        c._exit(0); // closes the fence's only write end
    }
    _ = c.close(report[1]);
    var child: i32 = 0;
    const n = c.read(report[0], std.mem.asBytes(&child), @sizeOf(i32));
    _ = c.close(report[0]);
    var st: c_int = 0;
    _ = c.waitpid(sub, &st, 0);
    if (!c.WIFEXITED(st) or c.WEXITSTATUS(st) != 0) {
        std.debug.print(RIG ++ ": sub-harness exit status {d}\n", .{if (c.WIFEXITED(st)) c.WEXITSTATUS(st) else 255});
        fail("orphan sub-harness failed (status 20 = the orphan died with its broker)");
    }
    if (n != @sizeOf(i32) or child <= 0) fail("orphan sub-harness reported no session");
    var waited: usize = 0;
    while (waited < 250 and alive(child)) : (waited += 1) _ = c.usleep(20_000);
    if (alive(child)) {
        _ = c.kill(child, c.SIGKILL);
        fail("orphaned worker outlived its harness's lifetime fence");
    }
    _ = allocator;
}
