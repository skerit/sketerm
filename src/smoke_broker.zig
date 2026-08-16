//! Broker (process-isolation) end-to-end smoke — `zig build smoke-broker`.
//!
//! Unlike smoke-mux (which runs the daemon in a thread), this forks a REAL
//! broker process so per-session worker forks are genuine child processes.
//! It then drives the broker as a client over the socket and checks:
//!   - spawn forks a worker; attach routes the client fd to it (SCM_RIGHTS);
//!   - input typed at the client echoes back through the worker (fd-passing);
//!   - list reflects the workers' pushed metadata; rename + kill work;
//!   - crash isolation: SIGKILL one worker → broker + the sibling survive,
//!     the dead session drops from list, and no zombie is left behind.
//!
//! Linux-only (the worker-pid scan reads /proc); the broker is a Linux dev
//! feature and this mirrors the manual validation.

const std = @import("std");
const c = @import("c.zig").c;
const daemon_mod = @import("mux/daemon.zig");
const client_mod = @import("mux/client.zig");
const wire = @import("mux/wire.zig");
const snapshot = @import("mux/snapshot.zig");
const Screen = @import("grid/screen.zig").Screen;
const Pool = @import("grid/style_pool.zig").Pool;

fn fail(comptime msg: []const u8) noreturn {
    std.debug.print("smoke-broker: FAIL: " ++ msg ++ "\n", .{});
    std.process.exit(1);
}

/// Client-side mirror: snapshot restore + event application, so we can read
/// the worker's screen text and confirm typed input echoed.
const Mirror = struct {
    allocator: std.mem.Allocator,
    pool: *Pool,
    screen: ?*Screen = null,

    fn applySnapshot(self: *Mirror, payload: []const u8) !void {
        if (payload.len < 9) return error.Truncated; // [seq:u64][app:u8] header
        if (self.screen) |s| s.deinit();
        self.screen = null;
        self.pool.deinit();
        self.pool.* = try Pool.init(self.allocator);
        self.screen = try snapshot.restore(self.allocator, self.pool, (try snapshot.peelEnvelope(payload)).body);
    }

    fn applyEvents(self: *Mirror, payload: []const u8) !void {
        const screen = self.screen orelse return error.NoScreen;
        if (payload.len < 12) return error.Truncated;
        var r = wire.Reader.init(payload[12..]);
        while (!r.atEnd()) {
            var ev = try r.getEvent(self.allocator);
            screen.apply(ev);
            ev.deinit(self.allocator);
        }
    }

    fn text(self: *Mirror) ![]u8 {
        return (self.screen orelse return error.NoScreen).extractScreen(self.allocator);
    }
};

fn helloOk(allocator: std.mem.Allocator, conn: *client_mod.Conn) void {
    conn.sendJson(.hello, .{ .proto = wire.PROTO_VERSION }) catch fail("hello send");
    (conn.recvExpect(&.{.welcome}) catch fail("welcome")).deinit(allocator);
}

fn spawnCat(allocator: std.mem.Allocator, conn: *client_mod.Conn, name: []const u8) void {
    conn.sendJson(.spawn, .{
        .name = name,
        .argv = [_][]const u8{"cat"},
        .rows = @as(u16, 24),
        .cols = @as(u16, 80),
    }) catch fail("spawn send");
    (conn.recvExpect(&.{.ok}) catch fail("spawn ok")).deinit(allocator);
}

/// Attach, type `token`, and confirm it echoes back on the session's screen
/// (cat echoes stdin; the PTY echoes too). Detaches when done.
fn attachAndEcho(allocator: std.mem.Allocator, sock_path: []const u8, name: []const u8, token: []const u8) void {
    var conn = client_mod.Conn.connect(allocator, sock_path) catch fail("echo connect");
    defer conn.deinit();
    helloOk(allocator, &conn);
    conn.sendJson(.attach, .{ .name = name }) catch fail("echo attach");
    const snap = conn.recvExpect(&.{.snapshot}) catch fail("echo snapshot");

    var mirror = Mirror{ .allocator = allocator, .pool = allocator.create(Pool) catch fail("echo pool") };
    mirror.pool.* = Pool.init(allocator) catch fail("echo pool init");
    defer {
        if (mirror.screen) |s| s.deinit();
        mirror.pool.deinit();
        allocator.destroy(mirror.pool);
    }
    mirror.applySnapshot(snap.payload) catch fail("echo snap apply");
    snap.deinit(allocator);

    var line_buf: [128]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, "{s}\n", .{token}) catch unreachable;
    conn.sendFrame(.input, line) catch fail("echo input");

    const tv = c.struct_timeval{ .tv_sec = 5, .tv_usec = 0 };
    _ = c.setsockopt(conn.fd, c.SOL_SOCKET, c.SO_RCVTIMEO, &tv, @sizeOf(c.struct_timeval));
    var tries: usize = 0;
    while (tries < 200) : (tries += 1) {
        const f = conn.recvFrame() catch fail("echo stream read");
        defer f.deinit(allocator);
        if (f.ftype == .events) mirror.applyEvents(f.payload) catch fail("echo events apply");
        const txt = mirror.text() catch fail("echo extract");
        defer allocator.free(txt);
        if (std.mem.indexOf(u8, txt, token) != null) {
            conn.sendJson(.detach, .{}) catch {};
            (conn.recvExpect(&.{.ok}) catch fail("echo detach ok")).deinit(allocator);
            return;
        }
    }
    fail("echo: token never appeared on the session screen");
}

const SessList = struct {
    proto: u32 = 0,
    daemon_pid: c.pid_t = 0,
    sessions: []struct {
        name: []const u8 = "",
        rows: u16 = 0,
        cols: u16 = 0,
        clients: u32 = 0,
        exited: bool = false,
    } = &.{},
};

/// Fetch the broker's session list; caller must call `.deinit()`.
fn listSessions(allocator: std.mem.Allocator, sock_path: []const u8) std.json.Parsed(SessList) {
    var conn = client_mod.Conn.connect(allocator, sock_path) catch fail("list connect");
    defer conn.deinit();
    helloOk(allocator, &conn);
    conn.sendFrame(.list, "") catch fail("list send");
    const f = conn.recvExpect(&.{.welcome}) catch fail("list welcome");
    defer f.deinit(allocator);
    // alloc_always: copy every string into the Parsed's arena so the result
    // stays valid after we free `f` (the frame payload) below.
    return std.json.parseFromSlice(SessList, allocator, f.payload, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch fail("list parse");
}

fn hasSession(sock_path: []const u8, allocator: std.mem.Allocator, name: []const u8) bool {
    var lst = listSessions(allocator, sock_path);
    defer lst.deinit();
    for (lst.value.sessions) |s| {
        if (std.mem.eql(u8, s.name, name)) return true;
    }
    return false;
}

fn sessionCount(sock_path: []const u8, allocator: std.mem.Allocator) usize {
    var lst = listSessions(allocator, sock_path);
    defer lst.deinit();
    return lst.value.sessions.len;
}

/// ppid of `pid` from /proc/<pid>/stat, or -1. comm (field 2) is wrapped in
/// parens and may contain spaces, so parse after the last ')'.
fn ppidOf(pid: c.pid_t) c.pid_t {
    var path_buf: [64]u8 = undefined;
    const sp = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/stat", .{pid}) catch return -1;
    const fp = c.fopen(sp.ptr, "r") orelse return -1;
    defer _ = c.fclose(fp);
    var buf: [512]u8 = undefined;
    const n = c.fread(&buf, 1, buf.len - 1, fp);
    if (n == 0) return -1;
    const stat = buf[0..n];
    const rp = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return -1;
    if (rp + 1 >= stat.len) return -1;
    var it = std.mem.tokenizeScalar(u8, stat[rp + 1 ..], ' ');
    _ = it.next() orelse return -1; // state
    const ppid_str = it.next() orelse return -1; // ppid
    return std.fmt.parseInt(c.pid_t, ppid_str, 10) catch -1;
}

/// First child process of `ppid`, via /proc (Linux). -1 if none.
fn firstChildOf(ppid: c.pid_t) c.pid_t {
    const dir = c.opendir("/proc") orelse return -1;
    defer _ = c.closedir(dir);
    while (true) {
        const ent = c.readdir(dir);
        if (ent == null) break;
        const nm = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
        const pid = std.fmt.parseInt(c.pid_t, nm, 10) catch continue;
        if (ppidOf(pid) == ppid) return pid;
    }
    return -1;
}

fn waitForSocket(sock_path: []const u8, allocator: std.mem.Allocator) void {
    var tries: usize = 0;
    while (tries < 100) : (tries += 1) {
        if (client_mod.Conn.connect(allocator, sock_path)) |conn| {
            var cc = conn;
            cc.deinit();
            return;
        } else |_| {}
        _ = c.usleep(20_000);
    }
    fail("broker socket never came up");
}

pub fn main(init: std.process.Init.Minimal) u8 {
    // This binary HOSTS a daemon (forked broker + its workers), so a
    // display session's keeper is /proc/self/exe --keep = us. Answer it,
    // or the keeper would re-run the whole smoke.
    if (@import("mux/keep.zig").wanted(init.args.vector)) return @import("mux/keep.zig").serve();
    // The built sketerm-mux binary (argv[1], from build.zig) — the
    // ticket stage's listener/bridge children need a real mux binary.
    if (init.args.vector.len > 1)
        _ = c.setenv("SKETERM_MUX_BIN", init.args.vector[1], 1);
    var gpa_state: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    // Linux-equivalent paths (no macOS winstream auto-gate diverting Wayland).
    _ = c.setenv("SKETERM_WINSTREAM", "off", 1);

    var path_buf: [128]u8 = undefined;
    const sock_path = std.fmt.bufPrint(&path_buf, "/tmp/sketerm-broker-smoke-{d}/mux.sock", .{c.getpid()}) catch unreachable;

    const bpid = c.fork();
    if (bpid < 0) fail("fork broker");
    if (bpid == 0) {
        // Broker child: a real process that forks one worker per session.
        const child_alloc = std.heap.page_allocator;
        const d = daemon_mod.Daemon.init(child_alloc, sock_path) catch c._exit(3);
        d.is_broker = true;
        d.run() catch {};
        c._exit(0);
    }

    waitForSocket(sock_path, allocator);
    {
        var initial = listSessions(allocator, sock_path);
        defer initial.deinit();
        if (initial.value.daemon_pid != bpid) fail("list: daemon_pid is not the broker PID");
    }
    std.debug.print("smoke-broker: daemon PID metadata ok\n", .{});

    @import("smoke_spawn_limits.zig").runRejected(allocator, sock_path);
    if (firstChildOf(bpid) > 0) fail("spawn limits: rejected request forked a worker");
    @import("smoke_spawn_limits.zig").runAcceptedMaximum(allocator, sock_path);
    var limit_wait: usize = 0;
    while (limit_wait < 100 and firstChildOf(bpid) > 0) : (limit_wait += 1)
        _ = c.usleep(20_000);
    if (firstChildOf(bpid) > 0) fail("spawn limits: accepted-boundary worker was not reaped");
    std.debug.print("smoke-broker: spawn dimension limits before worker fork ok\n", .{});

    // ── clean-exit reaping: a worker whose shell exits on its own must tear
    //    down and be reaped (no orphan, no stale `list` entry) — nobody kills
    //    it. Done first, on a clean slate, so the ephemeral worker is the
    //    broker's only child and `firstChildOf` finds it unambiguously. ──
    {
        var conn = client_mod.Conn.connect(allocator, sock_path) catch fail("eph connect");
        defer conn.deinit();
        helloOk(allocator, &conn);
        conn.sendJson(.spawn, .{
            .name = "ephemeral",
            .argv = [_][]const u8{ "sh", "-c", "sleep 0.4" },
            .rows = @as(u16, 24),
            .cols = @as(u16, 80),
        }) catch fail("eph spawn send");
        (conn.recvExpect(&.{.ok}) catch fail("eph spawn ok")).deinit(allocator);
    }
    _ = c.usleep(150_000); // still sleeping
    const eph_pid = firstChildOf(bpid);
    if (eph_pid <= 0) fail("eph: no worker process while alive");
    if (!hasSession(sock_path, allocator, "ephemeral")) fail("eph: not listed while alive");
    _ = c.usleep(1_200_000); // past the 0.4s sleep + broker reap
    if (hasSession(sock_path, allocator, "ephemeral")) fail("eph: clean-exited session not dropped from list");
    if (ppidOf(eph_pid) == bpid) fail("eph: clean-exited worker not reaped (still a child of the broker)");
    std.debug.print("smoke-broker: clean-exit reaping ok\n", .{});

    // ── spawn two sessions; each forks a worker ──
    {
        var conn = client_mod.Conn.connect(allocator, sock_path) catch fail("spawn connect");
        defer conn.deinit();
        helloOk(allocator, &conn);
        spawnCat(allocator, &conn, "alpha");
        spawnCat(allocator, &conn, "beta");
    }
    _ = c.usleep(300_000); // let workers push their first metadata
    if (sessionCount(sock_path, allocator) != 2) fail("list: expected 2 sessions after spawn");
    std.debug.print("smoke-broker: spawn x2 + list ok\n", .{});

    // ── attach + input echo through the broker (fd-passing) ──
    attachAndEcho(allocator, sock_path, "alpha", "ALPHA-ECHO-42");
    attachAndEcho(allocator, sock_path, "beta", "BETA-ECHO-99");
    std.debug.print("smoke-broker: attach + input echo via worker ok\n", .{});

    // ── rename from an ATTACHED client. Its fd is worker-owned, so the worker
    // forwards 'N' to the broker, which owns the name table and answers 'n';
    // the rename is broker-authoritative and single-step. ──
    {
        var conn = client_mod.Conn.connect(allocator, sock_path) catch fail("rename connect");
        defer conn.deinit();
        helloOk(allocator, &conn);
        conn.sendJson(.attach, .{ .name = "alpha", .kind = "gui" }) catch fail("rename attach");
        (conn.recvExpect(&.{.snapshot}) catch fail("rename snapshot")).deinit(allocator);
        conn.sendJson(.rename, .{ .name = "alpha", .new_name = "alpha2" }) catch fail("rename send");
        (conn.recvExpect(&.{.ok}) catch fail("rename ok")).deinit(allocator);
        conn.sendJson(.rename, .{ .name = "alpha2", .new_name = "beta" }) catch fail("duplicate rename send");
        (conn.recvExpect(&.{.err}) catch fail("duplicate rename not refused")).deinit(allocator);
    }
    if (hasSession(sock_path, allocator, "alpha")) fail("rename: old name still present");
    if (!hasSession(sock_path, allocator, "alpha2")) fail("rename: new name missing");
    if (!hasSession(sock_path, allocator, "beta")) fail("rename: duplicate refusal disturbed sibling");
    attachAndEcho(allocator, sock_path, "alpha2", "RENAMED-RECONNECT-17");
    std.debug.print("smoke-broker: attached-client broker-authoritative rename + reconnect ok\n", .{});

    // ── graceful kill ──
    {
        var conn = client_mod.Conn.connect(allocator, sock_path) catch fail("kill connect");
        defer conn.deinit();
        helloOk(allocator, &conn);
        conn.sendJson(.kill, .{ .name = "beta" }) catch fail("kill send");
        (conn.recvExpect(&.{.ok}) catch fail("kill ok")).deinit(allocator);
    }
    _ = c.usleep(300_000);
    if (hasSession(sock_path, allocator, "beta")) fail("kill: session still listed");
    if (sessionCount(sock_path, allocator) != 1) fail("kill: expected 1 session left");
    std.debug.print("smoke-broker: graceful kill ok\n", .{});

    // ── crash isolation: spawn a victim, SIGKILL its worker, confirm the
    //    broker + the surviving session keep working and no zombie is left ──
    {
        var conn = client_mod.Conn.connect(allocator, sock_path) catch fail("victim connect");
        defer conn.deinit();
        helloOk(allocator, &conn);
        spawnCat(allocator, &conn, "victim");
    }
    _ = c.usleep(300_000);
    if (sessionCount(sock_path, allocator) != 2) fail("victim spawn: expected 2 sessions");

    // Find a worker process (child of the broker) and SIGKILL it.
    const victim_pid = firstChildOf(bpid);
    if (victim_pid <= 0) fail("could not find a worker process to kill");
    _ = c.kill(victim_pid, c.SIGKILL);
    _ = c.usleep(500_000);

    // Broker still alive?
    if (c.kill(bpid, 0) != 0) fail("broker died when a worker was SIGKILLed");
    // Down to one session (the killed worker dropped via control EOF).
    if (sessionCount(sock_path, allocator) != 1) fail("isolation: dead worker not dropped from list");
    // No zombie left behind (the broker's waitpid reaping ran). A reaped pid
    // returns -1 from ppidOf (no /proc entry); a zombie would still be a child
    // of the broker — so simply assert it's no longer the broker's child.
    if (ppidOf(victim_pid) == bpid) fail("isolation: killed worker still a live child of the broker");

    // The surviving session still echoes (proves it was unaffected).
    const survivor = blk: {
        var lst = listSessions(allocator, sock_path);
        defer lst.deinit();
        if (lst.value.sessions.len == 0) fail("isolation: no surviving session");
        break :blk allocator.dupe(u8, lst.value.sessions[0].name) catch fail("oom");
    };
    defer allocator.free(survivor);
    attachAndEcho(allocator, sock_path, survivor, "SURVIVOR-OK-7");
    std.debug.print("smoke-broker: crash isolation (SIGKILL worker) ok\n", .{});

    // ── mcp backlog gap + live-mirror resync THROUGH THE BROKER ──
    // The attach kind must survive the 'A' worker handoff or the
    // whole mcp streaming policy silently never engages (the
    // stale-screenshot bug reproduced only in broker mode).
    @import("smoke_backlog.zig").run(allocator, sock_path);
    std.debug.print("smoke-broker: mcp backlog gap + resync via worker ok\n", .{});

    // ── external display sessions + the controller lease THROUGH THE
    // BROKER. The hub paths ride the worker's 'Y' datagram and the
    // lease intent rides the 'A' handoff; either omitted and this is
    // silently broken while the monolith stage passes. ──
    @import("smoke_display.zig").run(allocator, sock_path);
    std.debug.print("smoke-broker: display sessions + controller lease via worker ok\n", .{});

    // ── correlated native-panel relay THROUGH THE BROKER. Both
    // panel_only and panel_rpc ride the append-only 'A' fd handoff. ──
    @import("smoke_panel_relay.zig").run(allocator, sock_path);
    std.debug.print("smoke-broker: panel relay + panel-only attach via worker ok\n", .{});

    // ── UDP connection tickets THROUGH THE BROKER: an attached
    // client's mint is served by the WORKER, whose Daemon has an
    // empty sock_path and must aim the listener via `broker_sock` —
    // omitted, and the monolith stage stays green while the real GUI
    // path fails. ──
    @import("smoke_ticket.zig").run(allocator, sock_path);
    std.debug.print("smoke-broker: udp connection tickets via worker ok\n", .{});

    // ── post-mortem delivery: a worker whose session died must NOT exit
    //    before a backlogged, non-reading MCP client has been sent the
    //    final log push + `.exit`. 2MB of output far exceeds the socket
    //    buffer, and the client sleeps past the old 8x50ms final flush —
    //    only the bounded worker linger gets the tail across. ──
    {
        var conn = client_mod.Conn.connect(allocator, sock_path) catch fail("pm connect");
        defer conn.deinit();
        helloOk(allocator, &conn);
        conn.sendJson(.spawn, .{
            .name = "pm",
            .argv = [_][]const u8{ "sh", "-c", "dd if=/dev/zero bs=1000 count=2000 2>/dev/null | tr '\\0' x; echo; echo SKLOG-SENTINEL; exit 7" },
            .rows = @as(u16, 24),
            .cols = @as(u16, 80),
        }) catch fail("pm spawn send");
        (conn.recvExpect(&.{.ok}) catch fail("pm spawn ok")).deinit(allocator);
        conn.sendJson(.attach, .{ .name = "pm", .kind = "mcp" }) catch fail("pm attach");
        (conn.recvExpect(&.{.snapshot}) catch fail("pm snapshot")).deinit(allocator);
        // Do not read anything: the backlog piles up worker-side.
        _ = c.usleep(2_500_000);
        var got_log = false;
        var got_exit = false;
        var exit_status: i32 = 0;
        var log_json: std.ArrayList(u8) = .empty;
        defer log_json.deinit(allocator);
        while (conn.recvFrame()) |f| {
            defer f.deinit(allocator);
            switch (f.ftype) {
                .log_data => {
                    got_log = true;
                    log_json.clearRetainingCapacity();
                    log_json.appendSlice(allocator, f.payload) catch fail("pm oom");
                },
                .exit => {
                    got_exit = true;
                    if (f.payload.len >= 4) exit_status = std.mem.readInt(i32, f.payload[0..4], .little);
                },
                else => {},
            }
            if (got_exit) break;
        } else |_| {}
        if (!got_log) fail("pm: post-mortem log push lost in worker teardown");
        if (std.mem.indexOf(u8, log_json.items, "SKLOG-SENTINEL") == null) fail("pm: sentinel missing from final log");
        if (!got_exit) fail("pm: exit frame lost in worker teardown");
        if (exit_status != 7) fail("pm: wrong exit status");
    }
    std.debug.print("smoke-broker: post-mortem log outlives worker teardown ok\n", .{});

    // ── clean shutdown ──
    {
        var conn = client_mod.Conn.connect(allocator, sock_path) catch fail("shutdown connect");
        defer conn.deinit();
        conn.sendFrame(.shutdown, "") catch {};
    }
    var status: c_int = 0;
    var waited: usize = 0;
    while (waited < 100) : (waited += 1) {
        if (c.waitpid(bpid, &status, c.WNOHANG) == bpid) break;
        _ = c.usleep(20_000);
    }
    // Best-effort: make sure the broker is gone.
    _ = c.kill(bpid, c.SIGKILL);
    _ = c.waitpid(bpid, &status, 0);

    std.debug.print("smoke-broker: PASS\n", .{});
    return 0;
}
