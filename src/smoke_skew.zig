//! Version-skew gate (`zig build test-skew`, a dependency of `test` and
//! `test-core`): real OLD `sketerm-mux` binaries against this build.
//!
//! `dist/test-skew.sh` builds every commit of `dist/skew-baselines.txt`
//! once per machine and passes `<head sketerm-mux> (<sha> <old binary>)...`.
//! Per baseline, each direction on its own short socket and XDG dirs:
//!   forward: the OLD broker spawns a shell session (an old worker) that
//!     prints a marker; this build's client attaches GUI-kind through it,
//!     then hands it over with `upgradeStaleIdle` (exactly the GUI's
//!     upgrade path); this build's sketerm-mux starts on the same socket
//!     and must adopt the old worker (same child pid); a GUI-kind attach
//!     advertising this build's maxima must restore a snapshot holding
//!     the marker and echo typed input; the doctor probe
//!     (`attachprobe.probeAt`) must say `attached`; `.shutdown` must end
//!     the adopted session.
//!   reverse: the roles swapped. This build's broker and worker hand over
//!     (`quit_idle` + `handover` sent directly: both carry the dev build
//!     id, so `upgradeStaleIdle` correctly sees nothing stale), the OLD
//!     broker adopts this build's worker, and the same attach, probe and
//!     shutdown checks run through it.
//!
//! Not exercised, with a printed SKIP: an OLD CLIENT attaching. The old
//! GUI needs its commit's GTK build, and an old sketerm-mux has no
//! attaching client of its own. What an old client would make the old
//! broker hand this build's worker is its own (lower) negotiated
//! version, which the reverse attach already gets, since the old broker
//! caps what it negotiates to its own build; how an old client parses
//! this build's worker's frames is what stays uncovered.
//!
//! Every daemon is exec'd by explicit path (never the installed one) and
//! fenced by `lifetime`, so all of them retire with this process; the
//! only kills are of brokers this process started, by exact pid.

const std = @import("std");
const c = @import("c.zig").c;
const lifetime = @import("util/lifetime.zig");
const platform = @import("util/platform.zig");
const pathz = @import("util/pathz.zig");
const nowMs = @import("util/clock.zig").nowMs;
const muxrig = @import("smoke/muxrig.zig");
const client_mod = @import("mux/client.zig");
const attachprobe = @import("mux/attachprobe.zig");
const Pool = @import("grid/style_pool.zig").Pool;

const RIG = "test-skew";
const SESSION = "skew";
const STEP_MS: i64 = 10_000;

/// What the run is doing now, named by every failure.
var where_buf: [160]u8 = undefined;
var where_len: usize = 0;
/// The current world's dir: a failure dumps its mux.log, then removes it.
var world_dir_buf: [64]u8 = undefined;
var world_dir_len: usize = 0;

fn step(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(&where_buf, fmt, args) catch where_buf[0..];
    where_len = s.len;
    std.debug.print(RIG ++ ": {s}\n", .{s});
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(RIG ++ ": FAIL [{s}]: " ++ fmt ++ "\n", .{where_buf[0..where_len]} ++ args);
    dumpLogTail();
    if (world_dir_len > 0) pathz.removeTree(world_dir_buf[0..world_dir_len]);
    std.process.exit(1);
}

/// The last few KiB of the isolated daemons' shared mux.log.
fn dumpLogTail() void {
    if (world_dir_len == 0) return;
    var path_buf: [320:0]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, "{s}/state/sketerm/mux.log", .{world_dir_buf[0..world_dir_len]}, 0) catch return;
    const fd = c.open(path.ptr, c.O_RDONLY);
    if (fd < 0) return;
    defer _ = c.close(fd);
    const size = c.lseek(fd, 0, c.SEEK_END);
    if (size < 0) return;
    const want: c.off_t = @min(size, 6144);
    _ = c.lseek(fd, size - want, c.SEEK_SET);
    var buf: [6144]u8 = undefined;
    const n = c.read(fd, &buf, @intCast(want));
    if (n <= 0) return;
    std.debug.print(RIG ++ ": --- tail of {s} ---\n{s}\n" ++ RIG ++ ": --- end of mux.log ---\n", .{ path, buf[0..@intCast(n)] });
}

fn setenvZ(name: [*:0]const u8, value: []const u8) void {
    var buf: [512:0]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{value}, 0) catch fail("env value too long", .{});
    if (c.setenv(name, z.ptr, 1) != 0) fail("setenv", .{});
}

fn mkdirZ(path: []const u8) void {
    var buf: [512:0]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{path}, 0) catch fail("path too long", .{});
    if (c.mkdir(z.ptr, 0o700) != 0 and std.posix.errno(-1) != .EXIST) fail("mkdir {s}", .{path});
}

/// One direction's private world: a short socket path and its own XDG dirs.
const World = struct {
    dir_buf: [64]u8 = undefined,
    dir_len: usize = 0,
    sock_buf: [96]u8 = undefined,
    sock_len: usize = 0,

    fn dir(w: *const World) []const u8 {
        return w.dir_buf[0..w.dir_len];
    }

    fn sock(w: *const World) []const u8 {
        return w.sock_buf[0..w.sock_len];
    }

    /// Short on purpose: sockaddr_un caps the socket path near 108 bytes.
    fn init(w: *World, n: usize) void {
        w.dir_len = (std.fmt.bufPrint(&w.dir_buf, "/tmp/skw-{d}-{d}", .{ c.getpid(), n }) catch unreachable).len;
        w.sock_len = (std.fmt.bufPrint(&w.sock_buf, "{s}/sketerm/mux.sock", .{w.dir()}) catch unreachable).len;
        pathz.removeTree(w.dir());
        mkdirZ(w.dir());
        var buf: [128]u8 = undefined;
        inline for (.{ .{ "XDG_STATE_HOME", "state" }, .{ "XDG_CONFIG_HOME", "config" }, .{ "XDG_CACHE_HOME", "cache" }, .{ "XDG_DATA_HOME", "data" } }) |kv| {
            const p = std.fmt.bufPrint(&buf, "{s}/{s}", .{ w.dir(), kv[1] }) catch unreachable;
            mkdirZ(p);
            setenvZ(kv[0], p);
        }
        setenvZ("XDG_RUNTIME_DIR", w.dir());
        @memcpy(world_dir_buf[0..w.dir_len], w.dir());
        world_dir_len = w.dir_len;
    }

    fn deinit(w: *World) void {
        pathz.removeTree(w.dir());
        world_dir_len = 0;
    }
};

fn connect(allocator: std.mem.Allocator, sock: []const u8) client_mod.Conn {
    const raw = client_mod.Conn.connect(allocator, sock) catch |err| fail("connect: {s}", .{@errorName(err)});
    return client_mod.Conn.probe(allocator, raw) catch |err| fail("hello/welcome: {s}", .{@errorName(err)});
}

const Listed = struct { pid: i32 = 0, origin_id: [64]u8 = undefined, origin_len: usize = 0, daemon: c.pid_t = 0 };

/// The listing of `SESSION` (pid 0 when it is not listed) and the answering daemon's pid.
fn listed(allocator: std.mem.Allocator, sock: []const u8) Listed {
    var conn = connect(allocator, sock);
    defer conn.deinit();
    conn.sendFrame(.list, "") catch |err| fail("list send: {s}", .{@errorName(err)});
    const f = conn.recvExpectFor(&.{.welcome}, STEP_MS) catch |err| fail("list reply: {s}", .{@errorName(err)});
    defer f.deinit(allocator);
    const Listing = struct {
        daemon_pid: c.pid_t = 0,
        sessions: []struct { name: []const u8 = "", pid: i32 = 0, origin_id: []const u8 = "" } = &.{},
    };
    const parsed = std.json.parseFromSlice(Listing, allocator, f.payload, .{ .ignore_unknown_fields = true }) catch fail("list parse: {s}", .{f.payload});
    defer parsed.deinit();
    var out = Listed{ .daemon = parsed.value.daemon_pid };
    for (parsed.value.sessions) |s| {
        if (!std.mem.eql(u8, s.name, SESSION)) continue;
        out.pid = s.pid;
        out.origin_len = @min(s.origin_id.len, out.origin_id.len);
        @memcpy(out.origin_id[0..out.origin_len], s.origin_id[0..out.origin_len]);
    }
    return out;
}

fn alive(pid: i32) bool {
    return pid > 0 and c.kill(pid, 0) == 0;
}

/// Reap broker `pid` (a child of this process) within `ms`, else SIGKILL it and fail.
fn waitExit(pid: c.pid_t, ms: i64, comptime what: []const u8) void {
    const deadline = nowMs() + ms;
    var status: c_int = 0;
    while (nowMs() < deadline) {
        if (c.waitpid(pid, &status, c.WNOHANG) == pid) return;
        _ = c.usleep(20_000);
    }
    _ = c.kill(pid, c.SIGKILL);
    _ = c.waitpid(pid, &status, 0);
    fail(what ++ ": broker pid {d} did not exit within {d}ms", .{ pid, ms });
}

fn spawnShell(allocator: std.mem.Allocator, sock: []const u8, marker: []const u8) Listed {
    var conn = connect(allocator, sock);
    defer conn.deinit();
    var script_buf: [96]u8 = undefined;
    const script = std.fmt.bufPrint(&script_buf, "echo {s}; exec sh -i", .{marker}) catch unreachable;
    conn.sendJson(.spawn, .{
        .name = SESSION,
        .argv = [_][]const u8{ "sh", "-c", script },
        .rows = @as(u16, 24),
        .cols = @as(u16, 100),
    }) catch |err| fail("spawn send: {s}", .{@errorName(err)});
    const ok = conn.recvExpectFor(&.{.ok}, STEP_MS) catch |err| fail("spawn: {s}", .{conn.attachFailure(err)});
    ok.deinit(allocator);
    const l = listed(allocator, sock);
    if (!alive(l.pid)) fail("spawned session is not listed with a live child pid", .{});
    return l;
}

/// GUI-kind attach exactly as the GUI sends it, then the marker on the
/// restored snapshot and `echo` output (computed by the shell, so typed
/// text cannot fake it) in the event stream. `fresh`: the session was
/// just spawned, so its marker may still be on its way as events.
fn guiAttach(allocator: std.mem.Allocator, sock: []const u8, marker: []const u8, round: u32, fresh: bool) void {
    var conn = connect(allocator, sock);
    defer conn.deinit();
    conn.sendAttach(SESSION, .{ .kind = "gui", .panel_rpc = conn.panel_rpc }) catch |err| fail("attach send: {s}", .{@errorName(err)});
    const got = conn.recvGuiAttachFor(STEP_MS) catch |err| switch (err) {
        error.DaemonError => fail("attach refused: {s}", .{conn.lastErr()}),
        error.Disconnected => fail("client dropped before any snapshot (negotiated snapshot v{d}): {s}", .{ conn.snapshot_version, conn.attachFailure(err) }),
        error.Timeout => fail("no snapshot within {d}ms", .{STEP_MS}),
        else => fail("attach: {s}", .{conn.attachFailure(err)}),
    };
    var mirror = muxrig.Mirror{ .allocator = allocator, .pool = allocator.create(Pool) catch fail("oom", .{}) };
    mirror.pool.* = Pool.init(allocator) catch fail("pool", .{});
    defer {
        if (mirror.screen) |s| s.deinit();
        mirror.pool.deinit();
        allocator.destroy(mirror.pool);
    }
    mirror.applySnapshot(got.snapshot.payload) catch |err| fail("snapshot does not restore: {s}", .{@errorName(err)});
    got.snapshot.deinit(allocator);
    if (fresh) {
        awaitText(allocator, &conn, &mirror, marker, "the session's marker");
    } else {
        const txt = mirror.text() catch fail("snapshot text", .{});
        defer allocator.free(txt);
        if (std.mem.indexOf(u8, txt, marker) == null) fail("restored snapshot lacks the marker {s}; screen:\n{s}", .{ marker, std.mem.trimEnd(u8, txt, " \n") });
    }
    var line_buf: [64]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, "echo SKEW-{d}-$((6*7))\n", .{round}) catch unreachable;
    var want_buf: [32]u8 = undefined;
    const want = std.fmt.bufPrint(&want_buf, "SKEW-{d}-42", .{round}) catch unreachable;
    conn.sendFrame(.input, line) catch |err| fail("input send: {s}", .{@errorName(err)});
    awaitText(allocator, &conn, &mirror, want, "the typed echo's output");
    conn.sendFrame(.detach, "") catch {};
}

/// Apply the stream to `mirror` until `want` shows on its screen (it may already).
fn awaitText(allocator: std.mem.Allocator, conn: *client_mod.Conn, mirror: *muxrig.Mirror, want: []const u8, comptime what: []const u8) void {
    const deadline = nowMs() + STEP_MS;
    while (true) {
        {
            const txt = mirror.text() catch fail("screen text", .{});
            defer allocator.free(txt);
            if (std.mem.indexOf(u8, txt, want) != null) return;
            if (nowMs() >= deadline)
                fail(what ++ " ({s}) never appeared; screen:\n{s}", .{ want, std.mem.trimEnd(u8, txt, " \n") });
        }
        const f = conn.recvExpectFor(&.{ .events, .snapshot }, @max(deadline - nowMs(), 1)) catch |err| {
            if (err == error.Timeout) continue;
            fail("event stream: {s}", .{conn.attachFailure(err)});
        };
        defer f.deinit(allocator);
        if (f.ftype == .snapshot)
            mirror.applySnapshot(f.payload) catch |err| fail("resent snapshot does not restore: {s}", .{@errorName(err)})
        else
            mirror.applyEvents(f.payload) catch |err| fail("events do not apply: {s}", .{@errorName(err)});
    }
}

fn doctorProbe(allocator: std.mem.Allocator, sock: []const u8, l: Listed) void {
    const r = attachprobe.probeAt(allocator, sock, SESSION, l.origin_id[0..l.origin_len], STEP_MS);
    if (!r.outcome.healthy()) fail("doctor attach probe: {s} ({s})", .{ @tagName(r.outcome), r.reason() });
}

fn handoverReply(allocator: std.mem.Allocator, sock: []const u8) void {
    var conn = connect(allocator, sock);
    defer conn.deinit();
    if (!conn.caps.worker_handover) fail("broker does not advertise worker_handover", .{});
    conn.sendJson(.quit_idle, .{ .handover = true }) catch |err| fail("handover send: {s}", .{@errorName(err)});
    const f = conn.recvExpectFor(&.{.ok}, STEP_MS) catch |err| fail("handover reply: {s}", .{conn.attachFailure(err)});
    defer f.deinit(allocator);
    if (std.mem.indexOf(u8, f.payload, "\"ok\":true") == null) fail("handover refused: {s}", .{f.payload});
}

fn adopted(allocator: std.mem.Allocator, sock: []const u8, broker: c.pid_t, before: Listed) Listed {
    const deadline = nowMs() + STEP_MS;
    while (true) {
        const l = listed(allocator, sock);
        if (l.daemon != broker) fail("list answered by pid {d}, not the new broker {d}", .{ l.daemon, broker });
        if (l.pid == before.pid) return l;
        if (nowMs() > deadline) fail("the new broker did not adopt the session (listed child pid {d}, want {d})", .{ l.pid, before.pid });
        _ = c.usleep(50_000);
    }
}

fn shutdown(allocator: std.mem.Allocator, sock: []const u8, broker: c.pid_t, child: i32) void {
    {
        var conn = client_mod.Conn.connect(allocator, sock) catch |err| fail("shutdown connect: {s}", .{@errorName(err)});
        defer conn.deinit();
        conn.sendFrame(.shutdown, "") catch |err| fail("shutdown send: {s}", .{@errorName(err)});
    }
    waitExit(broker, STEP_MS, "shutdown");
    const deadline = nowMs() + STEP_MS;
    while (alive(child)) {
        if (nowMs() > deadline) fail("the adopted session (child pid {d}) outlived an explicit shutdown", .{child});
        _ = c.usleep(20_000);
    }
}

fn forward(allocator: std.mem.Allocator, n: usize, short: []const u8, old_bin: [:0]const u8, head_bin: [:0]const u8) void {
    var w: World = .{};
    w.init(n);
    defer w.deinit();
    var marker_buf: [32]u8 = undefined;
    const marker = std.fmt.bufPrint(&marker_buf, "SKEW-MARK-{s}-F", .{short}) catch unreachable;

    step("{s} forward: old broker + old worker", .{short});
    const old_pid = muxrig.execBroker(RIG, old_bin, w.sock());
    const before = spawnShell(allocator, w.sock(), marker);
    step("{s} forward: this build's GUI attach through the old broker", .{short});
    guiAttach(allocator, w.sock(), marker, 1, true);

    step("{s} forward: this build's client hands the old broker over", .{short});
    {
        var conn = connect(allocator, w.sock());
        defer conn.deinit();
        if (!conn.caps.worker_handover) fail("old broker does not advertise worker_handover", .{});
        if (!conn.upgradeStaleIdle(allocator)) fail("upgradeStaleIdle did not retire the old broker (server build '{s}')", .{conn.serverBuild()});
    }
    waitExit(old_pid, STEP_MS, "handover");
    if (!alive(before.pid)) fail("the session died with the old broker", .{});

    step("{s} forward: this build's broker adopts the old worker", .{short});
    const head_pid = muxrig.execBroker(RIG, head_bin, w.sock());
    const l = adopted(allocator, w.sock(), head_pid, before);
    step("{s} forward: GUI attach to the adopted old worker", .{short});
    guiAttach(allocator, w.sock(), marker, 2, false);
    step("{s} forward: doctor attach probe", .{short});
    doctorProbe(allocator, w.sock(), l);
    step("{s} forward: shutdown ends the adopted session", .{short});
    shutdown(allocator, w.sock(), head_pid, before.pid);
}

fn reverse(allocator: std.mem.Allocator, n: usize, short: []const u8, old_bin: [:0]const u8, head_bin: [:0]const u8) void {
    var w: World = .{};
    w.init(n);
    defer w.deinit();
    var marker_buf: [32]u8 = undefined;
    const marker = std.fmt.bufPrint(&marker_buf, "SKEW-MARK-{s}-R", .{short}) catch unreachable;

    step("{s} reverse: this build's broker + worker", .{short});
    const head_pid = muxrig.execBroker(RIG, head_bin, w.sock());
    const before = spawnShell(allocator, w.sock(), marker);
    step("{s} reverse: this build's broker hands over", .{short});
    handoverReply(allocator, w.sock());
    waitExit(head_pid, STEP_MS, "handover");
    if (!alive(before.pid)) fail("the session died with this build's broker", .{});

    step("{s} reverse: the old broker adopts this build's worker", .{short});
    const old_pid = muxrig.execBroker(RIG, old_bin, w.sock());
    const l = adopted(allocator, w.sock(), old_pid, before);
    step("{s} reverse: GUI attach through the old broker", .{short});
    guiAttach(allocator, w.sock(), marker, 3, false);
    step("{s} reverse: doctor attach probe", .{short});
    doctorProbe(allocator, w.sock(), l);
    std.debug.print(RIG ++ ": SKIP [{s} reverse]: an old client attaching (no old client binary is built; see the rig header)\n", .{short});
    step("{s} reverse: shutdown ends the adopted session", .{short});
    shutdown(allocator, w.sock(), old_pid, before.pid);
}

pub fn main(init: std.process.Init.Minimal) u8 {
    const argv = init.args.vector;
    if (argv.len < 4 or (argv.len - 2) % 2 != 0) {
        std.debug.print("usage: {s} <head sketerm-mux> (<sha> <old sketerm-mux>)...\n", .{argv[0]});
        return 2;
    }
    if (!lifetime.arm()) fail("lifetime fence", .{});
    platform.ignoreSigpipe();
    var gpa_state: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    const head_bin = std.mem.span(argv[1]);
    var i: usize = 2;
    var n: usize = 0;
    while (i < argv.len) : (i += 2) {
        const sha = std.mem.span(argv[i]);
        const short = sha[0..@min(sha.len, 8)];
        const old_bin = std.mem.span(argv[i + 1]);
        forward(allocator, n, short, old_bin, head_bin);
        reverse(allocator, n + 1, short, old_bin, head_bin);
        std.debug.print(RIG ++ ": PASS {s}: old->head handover + adoption + GUI attach + probe, head->old likewise\n", .{short});
        n += 2;
    }
    std.debug.print(RIG ++ ": PASS: {d} baseline(s)\n", .{(argv.len - 2) / 2});
    return 0;
}
