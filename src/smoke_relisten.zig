//! Runtime-dir removal stage (`zig build smoke-mux`, alone with
//! `SKETERM_SMOKE_MUX_RELISTEN_ONLY=1`): a daemon whose socket path was
//! removed gets it back, and no client starts a second daemon meanwhile.
//!
//! The darkshire sequence, against an isolated `XDG_RUNTIME_DIR`: the real
//! autostart path starts a daemon, a session gets a marker on its screen,
//! the whole runtime dir is `rm -rf`ed and recreated empty (what logind does
//! at the last logout and the next login), and the real autostart path
//! connects again. Then the same with the dir absent for a while (the
//! daemon re-binds by itself, nobody prompts it), through the remote
//! bootstrap (`sketerm-mux --proxy`, what `sketerm mux <host>` runs on the
//! far side), and with a foreign live listener on the path (never stolen,
//! taken back once it goes). Every reconnect must reach the ORIGINAL
//! daemon with the session and its marker, and mux.log must show exactly
//! one daemon start: a second daemon would have to log either its start
//! or its refused bind.

const std = @import("std");
const c = @import("c.zig").c;
const platform = @import("util/platform.zig");
const pathz = @import("util/pathz.zig");
const clock = @import("util/clock.zig");
const muxrig = @import("smoke/muxrig.zig");
const client_mod = @import("mux/client.zig");
const relisten = @import("mux/relisten.zig");
const procinv = @import("procinv.zig");
const Pool = @import("grid/style_pool.zig").Pool;

const RIG = "smoke-relisten";
const SESSION = "keep";
const MARKER = "RELISTEN-MARK-5150";

fn fail(comptime msg: []const u8) noreturn {
    std.debug.print(RIG ++ ": FAIL: " ++ msg ++ "\n", .{});
    std.process.exit(1);
}

const Env = struct {
    const names = [_][:0]const u8{ "XDG_RUNTIME_DIR", "XDG_STATE_HOME", "XDG_CONFIG_HOME", "SKETERM_MUX_LOG" };
    saved: [names.len]?[:0]u8 = .{null} ** names.len,

    fn save(self: *Env, allocator: std.mem.Allocator) void {
        for (names, 0..) |n, i| {
            const v = c.getenv(n.ptr) orelse continue;
            self.saved[i] = allocator.dupeZ(u8, std.mem.span(@as([*:0]const u8, @ptrCast(v)))) catch fail("oom");
        }
    }

    fn restore(self: *Env, allocator: std.mem.Allocator) void {
        for (names, 0..) |n, i| {
            if (self.saved[i]) |v| {
                _ = c.setenv(n.ptr, v.ptr, 1);
                allocator.free(v);
            } else _ = c.unsetenv(n.ptr);
        }
    }
};

fn setenvFmt(name: [:0]const u8, comptime fmt: []const u8, args: anytype) void {
    var buf: [256:0]u8 = undefined;
    const v = std.fmt.bufPrintZ(&buf, fmt, args) catch fail("env value too long");
    _ = c.setenv(name.ptr, v.ptr, 1);
}

fn mkdirZ(comptime fmt: []const u8, args: anytype) void {
    var buf: [256:0]u8 = undefined;
    const p = std.fmt.bufPrintZ(&buf, fmt, args) catch fail("path too long");
    if (c.mkdir(p.ptr, 0o700) != 0) fail("mkdir");
}

const Listing = struct {
    daemon_pid: c.pid_t = 0,
    sessions: []struct { name: []const u8 = "" } = &.{},
};

/// The daemon that answers `conn`, and whether it lists the session.
fn listOn(allocator: std.mem.Allocator, conn: *client_mod.Conn) struct { daemon: c.pid_t, has_session: bool } {
    conn.sendFrame(.list, "") catch fail("list send");
    const f = conn.recvExpectFor(&.{.welcome}, 10_000) catch fail("list reply");
    defer f.deinit(allocator);
    const parsed = std.json.parseFromSlice(Listing, allocator, f.payload, .{ .ignore_unknown_fields = true }) catch fail("list parse");
    defer parsed.deinit();
    var has = false;
    for (parsed.value.sessions) |s| has = has or std.mem.eql(u8, s.name, SESSION);
    return .{ .daemon = parsed.value.daemon_pid, .has_session = has };
}

/// The reconnect reached the original daemon, which still holds the session with the marker on screen.
fn expectOriginal(allocator: std.mem.Allocator, conn: *client_mod.Conn, original: c.pid_t, comptime what: []const u8) void {
    const l = listOn(allocator, conn);
    if (l.daemon != original) {
        std.debug.print(RIG ++ ": " ++ what ++ ": answered by pid {d}, original {d}\n", .{ l.daemon, original });
        fail(what ++ ": not the original daemon");
    }
    if (!l.has_session) fail(what ++ ": the original session is not listed");
    conn.sendJson(.attach, .{ .name = SESSION }) catch fail(what ++ ": attach send");
    const snap = conn.recvExpectFor(&.{.snapshot}, 10_000) catch fail(what ++ ": attach snapshot");
    defer snap.deinit(allocator);
    var mirror = muxrig.Mirror{ .allocator = allocator, .pool = allocator.create(Pool) catch fail("oom") };
    mirror.pool.* = Pool.init(allocator) catch fail("pool");
    defer {
        if (mirror.screen) |s| s.deinit();
        mirror.pool.deinit();
        allocator.destroy(mirror.pool);
    }
    mirror.applySnapshot(snap.payload) catch fail(what ++ ": snapshot apply");
    const txt = mirror.text() catch fail(what ++ ": text");
    defer allocator.free(txt);
    if (std.mem.indexOf(u8, txt, MARKER) == null) fail(what ++ ": the marker is gone from the session's screen");
}

/// Every daemon-role process whose own environment names `rt`; exactly `original` must be one.
fn expectOneDaemon(allocator: std.mem.Allocator, rt: []const u8, original: c.pid_t, comptime what: []const u8) void {
    if (!platform.can_inspect_processes) return;
    var inv = procinv.scan(allocator, c.getpid()) catch fail("process scan");
    defer inv.deinit();
    const env_buf = allocator.alloc(u8, 1 << 16) catch fail("oom");
    defer allocator.free(env_buf);
    var n: usize = 0;
    var saw_original = false;
    for (inv.procs) |*p| {
        if (!p.isDaemon()) continue;
        const env = platform.environOfPid(p.pid, env_buf) orelse continue;
        const v = platform.environBlockValue(env, "XDG_RUNTIME_DIR") orelse continue;
        if (!std.mem.eql(u8, v, rt)) continue;
        n += 1;
        saw_original = saw_original or p.pid == original;
    }
    if (n != 1 or !saw_original) {
        std.debug.print(RIG ++ ": " ++ what ++ ": {d} daemon(s) under the isolated runtime dir\n", .{n});
        fail(what ++ ": exactly the original daemon must run");
    }
}

/// Broker starts and refused starts logged so far; every daemon start writes one of the two.
fn daemonStarts(log_path: []const u8) struct { up: usize, refused: usize } {
    var z_buf: [4096]u8 = undefined;
    const z = pathz.pathZ(&z_buf, log_path) catch fail("log path");
    const f = c.fopen(z, "rb") orelse return .{ .up = 0, .refused = 0 };
    defer _ = c.fclose(f);
    var buf: [1 << 18]u8 = undefined;
    const n = c.fread(&buf, 1, buf.len, f);
    const text = buf[0..n];
    return .{
        .up = std.mem.count(u8, text, "daemon up") - std.mem.count(u8, text, "mode=worker"),
        .refused = std.mem.count(u8, text, "not starting:"),
    };
}

fn expectSingleStart(log_path: []const u8, comptime what: []const u8) void {
    const s = daemonStarts(log_path);
    if (s.up != 1 or s.refused != 0) {
        std.debug.print(RIG ++ ": " ++ what ++ ": mux.log shows {d} broker start(s), {d} refused start(s)\n", .{ s.up, s.refused });
        fail(what ++ ": a second daemon was spawned");
    }
}

/// Wait for `sock` to answer without starting anything, then connect.
fn waitServed(allocator: std.mem.Allocator, sock: []const u8, ms: i64, comptime what: []const u8) client_mod.Conn {
    const deadline = clock.nowMs() + ms;
    while (clock.nowMs() < deadline) {
        if (relisten.socketPathState(sock) == .live) {
            const raw = client_mod.Conn.connect(allocator, sock) catch fail(what ++ ": connect");
            return client_mod.Conn.probe(allocator, raw) catch fail(what ++ ": probe");
        }
        _ = c.usleep(25_000);
    }
    fail(what ++ ": the daemon never re-bound its socket");
}

/// rm -rf the runtime dir, as logind does, and optionally recreate it empty.
fn dropRuntimeDir(rt: [:0]const u8, recreate: bool) void {
    pathz.removeTree(rt);
    if (c.access(rt.ptr, c.F_OK) == 0) fail("runtime dir survived removal");
    if (recreate and c.mkdir(rt.ptr, 0o700) != 0) fail("recreate runtime dir");
}

pub fn run(allocator: std.mem.Allocator) void {
    if (!platform.can_inspect_processes) {
        std.debug.print(RIG ++ ": skipped (no process inventory on this platform)\n", .{});
        return;
    }
    var env = Env{};
    env.save(allocator);
    defer env.restore(allocator);

    var root_buf: [64:0]u8 = undefined;
    const root = std.fmt.bufPrintZ(&root_buf, "/tmp/skrl-{d}", .{c.getpid()}) catch unreachable;
    pathz.removeTree(root);
    if (c.mkdir(root.ptr, 0o700) != 0) fail("mkdir root");
    defer pathz.removeTree(root);
    mkdirZ("{s}/st", .{root});
    mkdirZ("{s}/cfg", .{root});
    var rt_buf: [96:0]u8 = undefined;
    const rt = std.fmt.bufPrintZ(&rt_buf, "{s}/rt", .{root}) catch unreachable;
    if (c.mkdir(rt.ptr, 0o700) != 0) fail("mkdir rt");
    var log_buf: [96]u8 = undefined;
    const log_path = std.fmt.bufPrint(&log_buf, "{s}/st/mux.log", .{root}) catch unreachable;
    setenvFmt("XDG_RUNTIME_DIR", "{s}", .{rt});
    setenvFmt("XDG_STATE_HOME", "{s}/st", .{root});
    setenvFmt("XDG_CONFIG_HOME", "{s}/cfg", .{root});
    setenvFmt("SKETERM_MUX_LOG", "{s}", .{log_path});
    if (c.getenv("SKETERM_MUX_BIN") == null) fail("SKETERM_MUX_BIN unset: the autostart would run the installed daemon");
    var sock_buf: [128]u8 = undefined;
    const sock = std.fmt.bufPrint(&sock_buf, "{s}/sketerm/mux.sock", .{rt}) catch unreachable;

    // ── the real autostart path starts the daemon; a session gets a marker ──
    var original: c.pid_t = 0;
    {
        var conn = client_mod.Conn.connectLocalAutostart(allocator) catch fail("first autostart");
        defer conn.deinit();
        original = listOn(allocator, &conn).daemon;
        if (original <= 0) fail("daemon pid not listed");
        muxrig.spawnCat(RIG, allocator, &conn, SESSION);
        muxrig.attachAndEcho(RIG, allocator, &conn, SESSION, MARKER);
    }
    // The broker publishes its recovery record once it serves.
    {
        const deadline = clock.nowMs() + 5_000;
        while (relisten.support(original, null) != .recovers) {
            if (clock.nowMs() > deadline) fail("the daemon never published its recovery record");
            _ = c.usleep(25_000);
        }
    }

    // ── 1. logout + login: rm -rf, recreated empty, a client connects at once ──
    dropRuntimeDir(rt, true);
    {
        const t0 = clock.nowMs();
        var conn = client_mod.Conn.connectLocalAutostart(allocator) catch fail("reconnect after runtime-dir removal");
        defer conn.deinit();
        expectOriginal(allocator, &conn, original, "prompted reconnect");
        std.debug.print(RIG ++ ": reconnect reached the original daemon in {d}ms\n", .{clock.nowMs() - t0});
    }
    expectOneDaemon(allocator, rt, original, "prompted reconnect");
    expectSingleStart(log_path, "prompted reconnect");
    // The session's worker binds its adoption listener again too, so a
    // later broker restart can still adopt it.
    {
        var dir_buf: [160:0]u8 = undefined;
        const dir = std.fmt.bufPrintZ(&dir_buf, "{s}.w", .{sock}) catch unreachable;
        const deadline = clock.nowMs() + 5_000;
        while (true) {
            var entries: usize = 0;
            if (c.opendir(dir.ptr)) |d| {
                defer _ = c.closedir(d);
                while (c.readdir(d)) |ent| {
                    if (@import("mux/wire.zig").validSessionOriginId(std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name))))) entries += 1;
                }
            }
            if (entries == 1) break;
            if (clock.nowMs() > deadline) fail("the worker never re-bound its adoption listener");
            _ = c.usleep(50_000);
        }
    }
    std.debug.print(RIG ++ ": runtime dir removed + recreated: the client prompt reached the original daemon ok\n", .{});

    // ── 2. the dir stays absent a while; the daemon re-binds unprompted ──
    dropRuntimeDir(rt, false);
    _ = c.usleep(2_500_000);
    if (c.access(rt.ptr, c.F_OK) == 0) fail("something recreated the runtime dir itself");
    if (c.mkdir(rt.ptr, 0o700) != 0) fail("recreate runtime dir");
    {
        var conn = waitServed(allocator, sock, 4_000, "unprompted re-bind");
        defer conn.deinit();
        expectOriginal(allocator, &conn, original, "unprompted re-bind");
    }
    expectOneDaemon(allocator, rt, original, "unprompted re-bind");
    expectSingleStart(log_path, "unprompted re-bind");
    std.debug.print(RIG ++ ": runtime dir absent for 2.5s: the daemon re-bound by itself ok\n", .{});

    // ── 3. the remote bootstrap: `sketerm-mux --proxy` on the far side ──
    dropRuntimeDir(rt, true);
    {
        var sp: [2]c_int = undefined;
        if (platform.socketpairCloexec(&sp) != 0) fail("socketpair");
        const bin: [*:0]const u8 = @ptrCast(c.getenv("SKETERM_MUX_BIN").?);
        const pid = c.fork();
        if (pid < 0) fail("fork proxy");
        if (pid == 0) {
            _ = c.dup2(sp[1], 0);
            _ = c.dup2(sp[1], 1);
            const argv = [_:null]?[*:0]const u8{ bin, "--proxy", null };
            _ = c.execv(bin, @ptrCast(&argv));
            c._exit(127);
        }
        _ = c.close(sp[1]);
        var conn = client_mod.Conn.probe(allocator, .{ .allocator = allocator, .fd = sp[0] }) catch fail("proxy probe");
        expectOriginal(allocator, &conn, original, "remote bootstrap");
        conn.deinit();
        var st: c_int = 0;
        _ = c.waitpid(pid, &st, 0);
    }
    expectOneDaemon(allocator, rt, original, "remote bootstrap");
    expectSingleStart(log_path, "remote bootstrap");
    std.debug.print(RIG ++ ": remote bootstrap (--proxy) reached the original daemon ok\n", .{});

    // ── 4. a live listener someone else bound is never taken over ──
    dropRuntimeDir(rt, true);
    mkdirZ("{s}/sketerm", .{rt});
    const foreign = relisten.bindListener(sock, .wait) catch fail("foreign listener");
    if (c.kill(original, @intFromEnum(relisten.PROMPT_SIGNAL)) != 0) fail("prompt the daemon");
    _ = c.usleep(2_500_000);
    if (relisten.pathState(sock, foreign.id) != .ours) fail("the daemon took over a live listener");
    if (c.kill(original, 0) != 0) fail("the daemon died while its path was taken");
    _ = c.close(foreign.fd);
    {
        var z_buf: [4096]u8 = undefined;
        _ = c.unlink(pathz.pathZ(&z_buf, sock) catch unreachable);
    }
    {
        var conn = waitServed(allocator, sock, 4_000, "after the foreign listener left");
        defer conn.deinit();
        expectOriginal(allocator, &conn, original, "after the foreign listener left");
    }
    expectSingleStart(log_path, "after the foreign listener left");
    std.debug.print(RIG ++ ": a foreign live listener was left alone, then the path taken back ok\n", .{});

    // The daemon is this process's own child (the autostart forks it): stop and reap it.
    {
        var conn = client_mod.Conn.connect(allocator, sock) catch fail("shutdown connect");
        defer conn.deinit();
        conn.sendFrame(.shutdown, "") catch fail("shutdown send");
    }
    muxrig.waitBroker(RIG, original, 10_000);
    if (relisten.support(original, null) != .old_build) fail("a stopped daemon's record still reads as live");
    std.debug.print(RIG ++ ": PASS\n", .{});
}
