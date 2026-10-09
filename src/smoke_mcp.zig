//! `zig build smoke-mcp` — end-to-end smoke for the MCP server's
//! isolation model and headless terminal tools. Spawns
//! `zig-out/bin/sketerm mcp` as a subprocess, speaks NDJSON JSON-RPC
//! over its stdio, and asserts: the handshake + tool inventory, that a
//! private daemon is created under an isolated runtime dir (and the
//! shared mux.sock is NOT), that headless term tools run a real shell,
//! that an ephemeral instance is torn down on exit, and that a named
//! durable instance's daemon survives an MCP restart. Uses only /bin/sh
//! so it runs anywhere (no GUI apps / display / a11y bus needed).

const std = @import("std");
const c = @import("c.zig").c;
const tcpserver = @import("smoke/tcpserver.zig");
const pathz = @import("util/pathz.zig");
const lifetime = @import("util/lifetime.zig");
const muxclient = @import("mux/client.zig");
const wire = @import("mux/wire.zig");
const panelstore = @import("ipc/panelstore.zig");
const protocol = @import("ipc/protocol.zig");
const webproto = @import("web/protocol.zig");
const webstream = @import("web/stream.zig");
const frameflow = @import("web/frameflow.zig");
const frameenc = @import("web/frameenc.zig");
const vcodec = @import("wlhost/vcodec.zig");
const opuscodec = @import("mux/opuscodec.zig");
const netpolicy = @import("web/netpolicy.zig");
const version = @import("version.zig");
const smoke_tls = @import("smoke_tls.zig");
const appdrive = @import("ipc/appdrive.zig");
const platform = @import("util/platform.zig");
const testserver = @import("agent/testserver.zig");
const facts = @import("agent/facts.zig");
const readfile = @import("util/readfile.zig");
const SpinLock = @import("util/spinlock.zig").SpinLock;
const termdrive = @import("ipc/termdrive.zig");
const sshroute = @import("mux/sshroute.zig");

fn say(msg: []const u8) void {
    _ = c.write(2, msg.ptr, msg.len);
    _ = c.write(2, "\n", 1);
}

/// The isolated runtime dir of this run, once main has minted it: the
/// handle `fail` needs to retire the daemons `exit` would otherwise
/// skip every `defer` for. Every failed run used to leave its five
/// brokers alive until the host rebooted.
var g_rt: ?[]const u8 = null;

/// The browser helper the real-engine stages run, from `--web-bin`.
///
/// build.zig passes the artifact it just built, so the stage can never
/// measure a STALE `zig-out/bin/sketerm-webengine` against a freshly
/// built client: a mid-refactor helper left there reads as a live
/// protocol failure — every semantic op timing out while load and title
/// events keep arriving — and the smoke blames the wrong side. Null
/// when the smoke binary is run by hand; the install path is then the
/// fallback.
var g_web_bin: ?[*:0]const u8 = null;

/// The helper to drive, or null when none is built.
fn resolveWebBin(buf: *[4096:0]u8) ?[*:0]const u8 {
    if (g_web_bin) |p| return if (c.access(p, c.X_OK) == 0) p else null;
    const p = c.realpath("zig-out/bin/sketerm-webengine", buf) orelse return null;
    return if (c.access(p, c.X_OK) == 0) p else null;
}

fn fail(comptime msg: []const u8) noreturn {
    say("smoke-mcp: FAIL " ++ msg);
    if (g_rt) |rt| {
        killDaemonsUnderRt(rt, std.heap.page_allocator);
        say("smoke-mcp: runtime dir kept for inspection:");
        say(rt);
    }
    std.process.exit(1);
}

const nowMs = @import("util/clock.zig").nowMs;

/// A running `sketerm mcp` subprocess plus its stdio pipes.
const Mcp = struct {
    pid: c.pid_t,
    to_child: c_int, // we write child's stdin
    from_child: c_int, // we read child's stdout
    id: u32 = 0,
    rbuf: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,

    /// Spawn `sketerm mcp <extra...>`. `extra` is a null-terminated
    /// list of extra argv entries (e.g. {"--name", "smoke1"}).
    fn spawn(allocator: std.mem.Allocator, exe: [*:0]const u8, extra: []const [*:0]const u8) Mcp {
        // Build argv before fork (no allocation between fork and exec).
        var argv_buf: [8:null]?[*:0]const u8 = @splat(null);
        argv_buf[0] = exe;
        argv_buf[1] = "mcp";
        for (extra, 0..) |e, i| argv_buf[2 + i] = e;
        return spawnArgv(allocator, exe, &argv_buf);
    }

    /// Spawn `sketerm mcp` under a `/bin/sh` that stays its parent and
    /// carries `parent_args` on its own argv (a Claude Code started with
    /// a channel option, as `agentpush.ancestorNamesChannel` reads it).
    fn spawnUnder(allocator: std.mem.Allocator, exe: [*:0]const u8, parent_args: []const [*:0]const u8) Mcp {
        var argv_buf: [8:null]?[*:0]const u8 = @splat(null);
        argv_buf[0] = "/bin/sh";
        argv_buf[1] = "-c";
        // Not the last command, so sh does not exec it away.
        argv_buf[2] = "\"$0\" mcp; :";
        argv_buf[3] = exe;
        for (parent_args, 0..) |e, i| argv_buf[4 + i] = e;
        return spawnArgv(allocator, "/bin/sh", &argv_buf);
    }

    fn spawnArgv(allocator: std.mem.Allocator, path: [*:0]const u8, argv_buf: *const [8:null]?[*:0]const u8) Mcp {
        var in_pipe: [2]c_int = undefined; // parent→child stdin
        var out_pipe: [2]c_int = undefined; // child→parent stdout
        if (c.pipe(&in_pipe) != 0 or c.pipe(&out_pipe) != 0) fail("pipe");
        const exe = path;
        const pid = c.fork();
        if (pid < 0) fail("fork");
        if (pid == 0) {
            _ = c.dup2(in_pipe[0], 0);
            _ = c.dup2(out_pipe[1], 1);
            _ = c.close(in_pipe[0]);
            _ = c.close(in_pipe[1]);
            _ = c.close(out_pipe[0]);
            _ = c.close(out_pipe[1]);
            _ = c.execv(exe, @ptrCast(@constCast(argv_buf)));
            c._exit(127);
        }
        _ = c.close(in_pipe[0]);
        _ = c.close(out_pipe[1]);
        // CLOEXEC on our ends: a LATER Mcp.spawn's child must not
        // inherit this child's stdin write end, or closing it here
        // never reaches EOF while the sibling lives — exactly the
        // two-concurrent-clients shape the shared-profile stage runs.
        _ = c.fcntl(in_pipe[1], c.F_SETFD, c.FD_CLOEXEC);
        _ = c.fcntl(out_pipe[0], c.F_SETFD, c.FD_CLOEXEC);
        return .{ .pid = pid, .to_child = in_pipe[1], .from_child = out_pipe[0], .allocator = allocator };
    }

    fn send(self: *Mcp, line: []const u8) void {
        var off: usize = 0;
        while (off < line.len) {
            const n = c.write(self.to_child, line.ptr + off, line.len - off);
            if (n <= 0) fail("write to child");
            off += @intCast(n);
        }
        _ = c.write(self.to_child, "\n", 1);
    }

    /// Read one newline-terminated JSON line (caller owns nothing; the
    /// slice is valid until the next call).
    fn recvLine(self: *Mcp, timeout_ms: i64) []const u8 {
        const deadline = nowMs() + timeout_ms;
        while (true) {
            if (std.mem.indexOfScalar(u8, self.rbuf.items, '\n')) |nl| {
                const line = self.rbuf.items[0..nl];
                // Shift the remainder down for the next call.
                const rest = self.rbuf.items[nl + 1 ..];
                std.mem.copyForwards(u8, self.rbuf.items[0..rest.len], rest);
                self.rbuf.shrinkRetainingCapacity(rest.len);
                // Return a stable copy in a scratch buffer.
                scratch_len = @min(line.len, scratch.len);
                @memcpy(scratch[0..scratch_len], line[0..scratch_len]);
                return scratch[0..scratch_len];
            }
            if (nowMs() > deadline) fail("timeout waiting for child reply");
            var pfd = c.struct_pollfd{ .fd = self.from_child, .events = c.POLLIN, .revents = 0 };
            if (c.poll(&pfd, 1, 200) <= 0) continue;
            var tmp: [65536]u8 = undefined;
            const n = c.read(self.from_child, &tmp, tmp.len);
            if (n <= 0) fail("child closed stdout early");
            self.rbuf.appendSlice(self.allocator, tmp[0..@intCast(n)]) catch fail("oom");
        }
    }

    /// Issue a tools/call and return the first content text (substring
    /// checks are enough for a smoke).
    fn callTool(self: *Mcp, name: []const u8, args_json: []const u8) []const u8 {
        self.sendTool(name, args_json);
        return self.recvLine(15_000);
    }

    /// Issue a tools/call WITHOUT reading the reply — for calls that
    /// make the server talk to a socket this process must serve first.
    fn sendTool(self: *Mcp, name: []const u8, args_json: []const u8) void {
        self.id += 1;
        var buf: [4096]u8 = undefined;
        const req = std.fmt.bufPrint(&buf, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"tools/call\",\"params\":{{\"name\":\"{s}\",\"arguments\":{s}}}}}", .{ self.id, name, args_json }) catch fail("req too long");
        self.send(req);
    }

    fn sendToolAllocated(self: *Mcp, name: []const u8, args_json: []const u8) void {
        self.id += 1;
        const req = std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"tools/call\",\"params\":{{\"name\":\"{s}\",\"arguments\":{s}}}}}", .{ self.id, name, args_json }) catch
            fail("large request allocation");
        defer self.allocator.free(req);
        self.send(req);
    }

    /// Issue tools/list and return the raw reply line.
    fn listTools(self: *Mcp) []const u8 {
        self.id += 1;
        var buf: [256]u8 = undefined;
        const req = std.fmt.bufPrint(&buf, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"tools/list\"}}", .{self.id}) catch unreachable;
        self.send(req);
        return self.recvLine(15_000);
    }

    fn initialize(self: *Mcp) void {
        self.id += 1;
        var buf: [512]u8 = undefined;
        const req = std.fmt.bufPrint(&buf, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"initialize\",\"params\":{{\"protocolVersion\":\"{s}\",\"capabilities\":{{}},\"clientInfo\":{{\"name\":\"smoke\",\"version\":\"0\"}}}}}}", .{ self.id, version.mcp_protocol }) catch unreachable;
        self.send(req);
        _ = self.recvLine(10_000);
    }

    fn closeStdinWait(self: *Mcp) void {
        _ = c.close(self.to_child);
        var st: c_int = 0;
        // Give teardown a moment; then reap.
        var tries: u32 = 0;
        while (tries < 100) : (tries += 1) {
            if (c.waitpid(self.pid, &st, 1) == self.pid) break; // WNOHANG=1
            _ = c.usleep(50_000);
        }
        if (tries >= 100) {
            _ = c.kill(self.pid, c.SIGKILL);
            _ = c.waitpid(self.pid, &st, 0);
            fail("mcp did not exit after stdin close");
        }
        _ = c.close(self.from_child);
        self.rbuf.deinit(self.allocator);
    }
};

var scratch: [1 << 20]u8 = undefined;
var scratch_len: usize = 0;

/// THE isolation vocabulary: every variable that would point a child
/// spawned here at the developer's OWN running sketerm. Mcp.spawn
/// execv's, so the child inherits this process's environment — an
/// entry missing from this list is a real daemon leaking into a smoke
/// run. $SKETERM_MUX_SOCKET is the trap: it holds an ABSOLUTE path, so
/// resetting $XDG_RUNTIME_DIR cannot redirect it and it must be unset
/// by name (a reachable daemon there answered the ui stage's
/// "no origin" probe with a live session refusal instead).
fn clearInheritedOrigin() void {
    for ([_][*:0]const u8{
        "SKETERM_SOCKET",
        "SKETERM_PANE_ID",
        "SKETERM_MUX_SOCKET",
        // The panel stage's SESSIONLESS calls must really have no
        // session: run from inside a sketerm pane, the inherited
        // $SKETERM_SESSION would scope them to that pane instead.
        "SKETERM_SESSION",
        "SKETERM_SESSION_ORIGIN_ID",
    }) |key| _ = c.unsetenv(key);
}

fn fileExists(path: []const u8) bool {
    var z: [4096]u8 = undefined;
    const p = std.fmt.bufPrintZ(&z, "{s}", .{path}) catch return false;
    return c.access(p.ptr, c.F_OK) == 0;
}

/// Run `sketerm doctor` with stdout captured into `buf`.
fn doctorOutput(exe: [*:0]const u8, buf: []u8) []const u8 {
    var pipe: [2]c_int = undefined;
    if (c.pipe(&pipe) != 0) fail("doctor pipe");
    const pid = c.fork();
    if (pid < 0) fail("doctor fork");
    if (pid == 0) {
        _ = c.dup2(pipe[1], 1);
        _ = c.close(pipe[0]);
        _ = c.close(pipe[1]);
        var argv: [3:null]?[*:0]const u8 = .{ exe, "doctor", null };
        _ = c.execv(exe, @ptrCast(@constCast(&argv)));
        c._exit(127);
    }
    _ = c.close(pipe[1]);
    defer _ = c.close(pipe[0]);
    var used: usize = 0;
    const deadline = nowMs() + 20_000;
    while (used < buf.len) {
        var pfd = c.struct_pollfd{ .fd = pipe[0], .events = c.POLLIN, .revents = 0 };
        const ready = c.poll(&pfd, 1, 200);
        if (ready > 0) {
            const n = c.read(pipe[0], buf[used..].ptr, buf.len - used);
            if (n == 0) break;
            if (n > 0) used += @intCast(n);
        }
        if (nowMs() >= deadline) {
            _ = c.kill(pid, c.SIGKILL);
            _ = c.waitpid(pid, null, 0);
            fail("doctor timed out");
        }
    }
    var status: c_int = 0;
    // Doctor also inventories unrelated processes; warnings have exit status 1.
    if (c.waitpid(pid, &status, 0) != pid or (status != 0 and status != 256)) {
        say(buf[0..used]);
        fail("doctor failed");
    }
    return buf[0..used];
}

/// Locate `<state>/sketerm/mcp-casts/<any>/<name>` and read it.
fn findCast(state_dir: []const u8, name: []const u8, buf: []u8) ?[]const u8 {
    var base_buf: [4096]u8 = undefined;
    const base = std.fmt.bufPrintZ(&base_buf, "{s}/sketerm/mcp-casts", .{state_dir}) catch return null;
    const d = c.opendir(base.ptr) orelse return null;
    defer _ = c.closedir(d);
    while (c.readdir(d)) |ent| {
        const sub = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
        if (sub.len == 0 or sub[0] == '.') continue;
        var path_buf: [4096]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}/{s}", .{ base, sub, name }) catch continue;
        const f = c.fopen(path.ptr, "rb") orelse continue;
        defer _ = c.fclose(f);
        const n = c.fread(buf.ptr, 1, buf.len, f);
        if (n > 0) return buf[0..n];
    }
    return null;
}

/// PIDs of sketerm-mux daemons whose /proc environ carries `rt`.
fn daemonUnderRt(allocator: std.mem.Allocator, rt: []const u8) bool {
    const d = c.opendir("/proc") orelse return false;
    defer _ = c.closedir(d);
    var needle_buf: [4096]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "XDG_RUNTIME_DIR={s}", .{rt}) catch return false;
    while (c.readdir(d)) |ent| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
        if (name.len == 0 or name[0] < '0' or name[0] > '9') continue;
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "/proc/{s}/environ", .{name}) catch continue;
        const f = c.fopen(path.ptr, "rb") orelse continue;
        defer _ = c.fclose(f);
        var content: std.ArrayList(u8) = .empty;
        defer content.deinit(allocator);
        var tmp: [4096]u8 = undefined;
        while (true) {
            const n = c.fread(&tmp, 1, tmp.len, f);
            if (n == 0) break;
            content.appendSlice(allocator, tmp[0..n]) catch break;
        }
        // environ is NUL-separated; search the raw bytes.
        if (std.mem.indexOf(u8, content.items, needle) != null) {
            // Confirm it's a sketerm-mux by comm.
            var comm_buf: [256]u8 = undefined;
            const comm_path = std.fmt.bufPrintZ(&comm_buf, "/proc/{s}/comm", .{name}) catch continue;
            const cf = c.fopen(comm_path.ptr, "rb") orelse continue;
            defer _ = c.fclose(cf);
            var cb: [64]u8 = undefined;
            const cn = c.fread(&cb, 1, cb.len, cf);
            if (std.mem.indexOf(u8, cb[0..cn], "sketerm-mux") != null) return true;
        }
    }
    return false;
}

fn killDaemonsUnderRt(rt: []const u8, allocator: std.mem.Allocator) void {
    killUnderRt(rt, allocator, c.SIGTERM);
}

/// Signal every process whose XDG_RUNTIME_DIR starts with `rt`.
fn killUnderRt(rt: []const u8, allocator: std.mem.Allocator, sig: c_int) void {
    const d = c.opendir("/proc") orelse return;
    defer _ = c.closedir(d);
    var needle_buf: [4096]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "XDG_RUNTIME_DIR={s}", .{rt}) catch return;
    while (c.readdir(d)) |ent| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
        if (name.len == 0 or name[0] < '0' or name[0] > '9') continue;
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "/proc/{s}/environ", .{name}) catch continue;
        const f = c.fopen(path.ptr, "rb") orelse continue;
        defer _ = c.fclose(f);
        var content: std.ArrayList(u8) = .empty;
        defer content.deinit(allocator);
        var tmp: [4096]u8 = undefined;
        while (true) {
            const n = c.fread(&tmp, 1, tmp.len, f);
            if (n == 0) break;
            content.appendSlice(allocator, tmp[0..n]) catch break;
        }
        if (std.mem.indexOf(u8, content.items, needle) != null) {
            const pid = std.fmt.parseInt(c.pid_t, name, 10) catch continue;
            _ = c.kill(pid, sig);
        }
    }
}

/// A stand-in for the GUI's control socket: one JSON line in, one
/// canned JSON line out. Enough to prove what the ui_* tools SEND —
/// which for ui_show_files (a server-side document generator) is the
/// whole point, and needs no GTK.
const FakeGui = struct {
    fd: c_int,

    fn listen(path: [:0]const u8) FakeGui {
        _ = c.unlink(path.ptr);
        const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
        if (fd < 0) fail("fake gui: socket");
        var addr: c.struct_sockaddr_un = std.mem.zeroes(c.struct_sockaddr_un);
        addr.sun_family = c.AF_UNIX;
        if (path.len >= addr.sun_path.len) fail("fake gui: socket path too long");
        @memcpy(addr.sun_path[0..path.len], path);
        if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0) fail("fake gui: bind");
        if (c.listen(fd, 4) != 0) fail("fake gui: listen");
        return .{ .fd = fd };
    }

    /// Accept one connection, read its request line, answer with
    /// `reply`, close. Returns the request (valid until the next call).
    fn serveOne(self: *FakeGui, reply: []const u8, timeout_ms: i64) []const u8 {
        const deadline = nowMs() + timeout_ms;
        var conn: c_int = -1;
        while (true) {
            var pfd = c.struct_pollfd{ .fd = self.fd, .events = c.POLLIN, .revents = 0 };
            if (c.poll(&pfd, 1, 200) > 0) {
                conn = c.accept(self.fd, null, null);
                if (conn >= 0) break;
            }
            if (nowMs() > deadline) fail("fake gui: no connection from the mcp server");
        }
        defer _ = c.close(conn);
        gui_req_len = 0;
        while (true) {
            if (std.mem.indexOfScalar(u8, gui_req[0..gui_req_len], '\n') != null) break;
            var pfd = c.struct_pollfd{ .fd = conn, .events = c.POLLIN, .revents = 0 };
            if (c.poll(&pfd, 1, 200) > 0) {
                const n = c.read(conn, gui_req[gui_req_len..].ptr, gui_req.len - gui_req_len);
                if (n <= 0) break;
                gui_req_len += @intCast(n);
            }
            if (nowMs() > deadline) fail("fake gui: request line never arrived");
        }
        _ = c.write(conn, reply.ptr, reply.len);
        _ = c.write(conn, "\n", 1);
        return gui_req[0..gui_req_len];
    }

    fn expectNoConnection(self: *FakeGui, timeout_ms: i64) void {
        var pfd = c.struct_pollfd{ .fd = self.fd, .events = c.POLLIN, .revents = 0 };
        if (c.poll(&pfd, 1, @intCast(timeout_ms)) > 0)
            fail("fake gui received a request despite lower transport precedence");
    }

    /// Socket discovery proves liveness with one connect that sends no JSON.
    fn acceptDiscoveryProbe(self: *FakeGui, timeout_ms: i64) void {
        var pfd = c.struct_pollfd{ .fd = self.fd, .events = c.POLLIN, .revents = 0 };
        if (c.poll(&pfd, 1, @intCast(timeout_ms)) <= 0)
            fail("fake gui received no socket-discovery liveness probe");
        const conn = c.accept(self.fd, null, null);
        if (conn < 0) fail("fake gui could not accept discovery probe");
        defer _ = c.close(conn);
        var peer = c.struct_pollfd{ .fd = conn, .events = c.POLLIN, .revents = 0 };
        if (c.poll(&peer, 1, 250) > 0) {
            var byte: [1]u8 = undefined;
            if (c.read(conn, &byte, 1) > 0)
                fail("socket-discovery liveness probe unexpectedly sent a request");
        }
    }

    fn deinit(self: *FakeGui) void {
        _ = c.close(self.fd);
    }
};

var gui_req: [4 << 20]u8 = undefined;
var gui_req_len: usize = 0;

/// An old daemon that answers hello/welcome without panel_rpc.
const FakeLegacyMux = struct {
    fd: c_int,

    fn listen(path: [:0]const u8) FakeLegacyMux {
        _ = c.unlink(path.ptr);
        const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
        if (fd < 0) fail("fake mux: socket");
        var addr: c.struct_sockaddr_un = std.mem.zeroes(c.struct_sockaddr_un);
        addr.sun_family = c.AF_UNIX;
        if (path.len >= addr.sun_path.len) fail("fake mux: socket path too long");
        @memcpy(addr.sun_path[0..path.len], path);
        if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0) fail("fake mux: bind");
        if (c.listen(fd, 4) != 0) fail("fake mux: listen");
        return .{ .fd = fd };
    }

    fn serveProbe(self: *FakeLegacyMux, timeout_ms: i64) void {
        const deadline = nowMs() + timeout_ms;
        var accepted: c_int = -1;
        while (nowMs() < deadline) {
            var pfd = c.struct_pollfd{ .fd = self.fd, .events = c.POLLIN, .revents = 0 };
            if (c.poll(&pfd, 1, 100) <= 0) continue;
            accepted = c.accept(self.fd, null, null);
            if (accepted >= 0) break;
        }
        if (accepted < 0) fail("fake mux: no probe connection");
        var conn = muxclient.Conn{ .allocator = std.heap.c_allocator, .fd = accepted };
        defer conn.deinit();
        conn.setNonBlocking();
        (conn.recvExpectFor(&.{.hello}, 2_000) catch fail("fake mux: no hello")).deinit(std.heap.c_allocator);
        conn.sendFrame(.welcome, "{\"proto\":1,\"server_proto\":1,\"negotiation\":1}") catch
            fail("fake mux: welcome write");
    }

    fn deinit(self: *FakeLegacyMux) void {
        _ = c.close(self.fd);
    }
};

const PanelCall = struct {
    id: u64,
    json: []u8,

    fn deinit(self: PanelCall, allocator: std.mem.Allocator) void {
        allocator.free(self.json);
    }
};

fn attachPanelPresenter(allocator: std.mem.Allocator, socket: []const u8, session: []const u8) muxclient.Conn {
    var conn = muxclient.Conn.connectProbed(allocator, socket) catch fail("panel presenter connect");
    conn.setNonBlocking();
    if (conn.panel_rpc != wire.PANEL_RPC_VERSION) fail("origin daemon lacks panel_rpc");
    conn.sendAttach(session, .{
        .kind = "gui",
        .read_only = true,
        .panel_rpc = wire.PANEL_RPC_VERSION,
    }) catch fail("panel presenter attach send");
    (conn.recvExpectFor(&.{.snapshot}, 5_000) catch fail("panel presenter attach reply")).deinit(allocator);
    return conn;
}

/// A released GUI predating panel_rpc: a real terminal viewer, never a
/// compatible panel presenter.
fn attachLegacyPanelViewer(allocator: std.mem.Allocator, socket: []const u8, session: []const u8) muxclient.Conn {
    var conn = muxclient.Conn.connectProbed(allocator, socket) catch fail("legacy panel viewer connect");
    conn.setNonBlocking();
    conn.sendAttach(session, .{
        .kind = "gui",
        .read_only = true,
    }) catch fail("legacy panel viewer attach send");
    (conn.recvExpectFor(&.{.snapshot}, 5_000) catch fail("legacy panel viewer attach reply")).deinit(allocator);
    return conn;
}

fn recvPanelCall(allocator: std.mem.Allocator, presenter: *muxclient.Conn, timeout_ms: i64) PanelCall {
    const frame = presenter.recvExpectFor(&.{.panel_request}, timeout_ms) catch
        fail("panel presenter received no request");
    defer frame.deinit(allocator);
    const envelope = wire.decodePanelEnvelope(frame.payload) catch
        fail("panel presenter received a malformed envelope");
    return .{
        .id = envelope.id,
        .json = allocator.dupe(u8, envelope.json) catch fail("panel request copy oom"),
    };
}

fn replyPanel(presenter: *muxclient.Conn, call: PanelCall, json: []const u8) void {
    presenter.sendPanelReply(call.id, json) catch fail("panel presenter reply failed");
}

fn expectNoPanelCall(presenter: *muxclient.Conn, timeout_ms: i64) void {
    if (presenter.recvExpectFor(&.{.panel_request}, timeout_ms)) |frame| {
        frame.deinit(presenter.allocator);
        fail("lower-precedence mux presenter received a panel request");
    } else |err| {
        if (err != error.Timeout) fail("lower-precedence mux presenter disconnected");
    }
}

fn sessionCount(allocator: std.mem.Allocator, owner: *muxclient.Conn) usize {
    owner.sendFrame(.list, "") catch fail("origin list send");
    const frame = owner.recvExpectFor(&.{.welcome}, 5_000) catch fail("origin list reply");
    defer frame.deinit(allocator);
    const Listing = struct { sessions: []const std.json.Value = &.{} };
    var parsed = std.json.parseFromSlice(Listing, allocator, frame.payload, .{
        .ignore_unknown_fields = true,
    }) catch fail("origin list parse");
    defer parsed.deinit();
    return parsed.value.sessions.len;
}

pub fn main(init: std.process.Init.Minimal) u8 {
    var gpa = std.heap.DebugAllocator(.{}){};
    const allocator = gpa.allocator();

    // The web-session stage points SKETERM_WEB_BIN at THIS binary: a
    // protocol-v1-speaking fake webengine that records its environment,
    // so the session plumbing is provable with no CEF installed. The
    // env guard keeps a plain smoke run out of this branch.
    if (c.getenv("SKETERM_FAKE_WEBENGINE") != null) {
        for (init.args.vector, 0..) |a, i| {
            if (std.mem.eql(u8, std.mem.span(a), "--socket") and i + 1 < init.args.vector.len)
                return fakeWebengine(allocator, std.mem.span(init.args.vector[i + 1]));
        }
    }
    // The web_gui stage points SKETERM_GUI_BIN at THIS binary: invoked
    // as `<bin> web` (the browser identity `sketerm mcp` spawns) it
    // stands in for a GUI's control socket, so the spawn path is
    // provable with no display.
    if (c.getenv(FAKE_GUI_ENV)) |rt_dir| {
        if (init.args.vector.len >= 2 and std.mem.eql(u8, std.mem.span(init.args.vector[1]), "web"))
            return fakeGui(std.mem.span(rt_dir));
    }

    // The agent stage points agent_open's `binary` at THIS binary: run as
    // `<bin> --ax-screen-reader` it is a fake Claude Code, as `<bin> serve`
    // a fake `opencode serve`, as `<bin> attach` opencode's attached TUI.
    // agent_open's `args` come first (a wrapper's own options), so the
    // mode is the first argument naming one; every start is recorded.
    if (c.getenv(FAKE_AGENT_ENV) != null and init.args.vector.len >= 2) fake: {
        const v = init.args.vector;
        const self_name = std.fs.path.basename(std.mem.span(v[0]));
        if (std.mem.eql(u8, self_name, "ssh") or std.mem.eql(u8, self_name, "scp")) break :fake;
        // The adapters' `version_args`: agent_open reports this line.
        if (v.len == 2 and std.mem.eql(u8, std.mem.span(v[1]), "--version")) {
            say(FAKE_AGENT_VERSION);
            return 0;
        }
        for (v[1..], 1..) |arg, k| {
            const mode = std.mem.span(arg);
            if (std.mem.eql(u8, mode, "--ax-screen-reader")) {
                fcRecordStart("claude", v[1..]);
                return fakeClaude(allocator, v[1..]);
            }
            if (std.mem.eql(u8, mode, "serve")) {
                fcRecordStart("serve", v[1..]);
                return fakeOpencodeServe(allocator, v[k..]);
            }
            if (std.mem.eql(u8, mode, "attach")) {
                fcRecordStart("attach", v[1..]);
                return fakeOpencodeAttach(v[k..]);
            }
        }
    }

    // The ssh-tools stage puts THIS binary on PATH as `ssh` and `scp`:
    // a local stand-in for a remote host, so scp_get/scp_put and the
    // port forwards are provable with no sshd.
    if (c.getenv(FAKE_SSH_ENV) != null) {
        const name = std.fs.path.basename(std.mem.span(init.args.vector[0]));
        if (std.mem.eql(u8, name, "ssh")) return fakeSsh(init.args.vector[1..]);
        if (std.mem.eql(u8, name, "scp")) return fakeScp(init.args.vector[1..]);
    }

    // `--web-bin <path>`: the helper THIS build produced, handed over by
    // build.zig. Without it the stages fall back to the installed
    // `zig-out/bin/sketerm-webengine`.
    for (init.args.vector, 0..) |a, i| {
        if (std.mem.eql(u8, std.mem.span(a), "--web-bin") and i + 1 < init.args.vector.len)
            g_web_bin = init.args.vector[i + 1];
    }

    // Every daemon below this process -- the ones `sketerm mcp` autostarts,
    // named/durable ones included, and their workers -- dies with it, by
    // whatever exit path. `fail`'s kill sweep is the orderly version; the
    // fence is what holds for SIGKILL, a panic, or ctrl-C.
    if (!lifetime.arm()) fail("lifetime fence");

    // Isolated runtime dir so nothing touches the user's real daemon.
    var rt_buf: [256]u8 = undefined;
    const rt = std.fmt.bufPrintZ(&rt_buf, "/tmp/sketerm-smoke-mcp-{d}", .{c.getpid()}) catch return 1;
    _ = c.mkdir(rt.ptr, 0o700);
    _ = c.setenv("XDG_RUNTIME_DIR", rt.ptr, 1);
    // Auto asciicast recordings must land under the isolated state
    // dir, not the developer's real one.
    _ = c.setenv("XDG_STATE_HOME", rt.ptr, 1);
    // The headless bash must not source the developer's real rc files:
    // a prompt manager there (oh-my-posh, starship) replaces the prompt
    // hooks and silently breaks the injected OSC 133 marks the
    // command-mode stages assert on. Empty HOME = stock bash.
    var home_buf: [280]u8 = undefined;
    const home = std.fmt.bufPrintZ(&home_buf, "{s}/home", .{rt}) catch return 1;
    _ = c.mkdir(home.ptr, 0o700);
    _ = c.setenv("HOME", home.ptr, 1);
    // `sketerm mcp` reads config.conf on every start (tool policy and
    // the web_gui grant); the developer's real one must not decide a
    // smoke's verdicts.
    var cfg_home_buf: [280]u8 = undefined;
    const cfg_home = std.fmt.bufPrintZ(&cfg_home_buf, "{s}/config", .{rt}) catch return 1;
    _ = c.mkdir(cfg_home.ptr, 0o700);
    _ = c.setenv("XDG_CONFIG_HOME", cfg_home.ptr, 1);
    // Later fake agents inherit the first default broker's environment.
    _ = c.setenv("SKETERM_SMOKE_FAKE_AGENT", "1", 1);
    var fake_exe_buf: [4096:0]u8 = undefined;
    const fake_exe = platform.exePathZ(&fake_exe_buf) orelse fail("fake SSH executable path");
    const fake_bin = std.fmt.allocPrintSentinel(allocator, "{s}/fakebin", .{rt}, 0) catch fail("fake SSH directory");
    defer allocator.free(fake_bin);
    _ = c.mkdir(fake_bin.ptr, 0o700);
    for ([_][]const u8{ "ssh", "scp" }) |name| {
        const link = std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ fake_bin, name }, 0) catch fail("fake SSH link");
        defer allocator.free(link);
        if (c.symlink(fake_exe.ptr, link.ptr) != 0) fail("could not link the fake SSH executable");
    }
    const prior_path = if (c.getenv("PATH")) |p| std.mem.span(p) else "/usr/bin:/bin";
    const fixture_path = std.fmt.allocPrintSentinel(allocator, "{s}:{s}", .{ fake_bin, prior_path }, 0) catch fail("fake SSH PATH");
    defer allocator.free(fixture_path);
    _ = c.setenv("PATH", fixture_path.ptr, 1);
    _ = c.setenv(FAKE_SSH_ENV, "1", 1);
    clearInheritedOrigin();
    g_rt = rt;
    defer killDaemonsUnderRt(rt, allocator);

    const exe = "zig-out/bin/sketerm";
    if (c.access(exe, c.X_OK) != 0) fail("zig-out/bin/sketerm missing (build first)");
    _ = c.setenv("SKETERM_MUX_BIN", "zig-out/bin/sketerm-mux", 1);
    defer _ = c.unsetenv("SKETERM_MUX_BIN");
    if (c.getenv("SKETERM_SMOKE_MCP_WEBSTARTUP_ONLY") != null) {
        var bin_buf: [4096:0]u8 = undefined;
        const web_bin = resolveWebBin(&bin_buf) orelse fail("sketerm-webengine missing for cold-start regression");
        _ = c.setenv("SKETERM_WEB_BIN", web_bin, 1);
        defer _ = c.unsetenv("SKETERM_WEB_BIN");
        _ = c.setenv("SKETERM_WEB_BROKER_ENGINE", "0", 1);
        defer _ = c.unsetenv("SKETERM_WEB_BROKER_ENGINE");
        webStartupStage(allocator, exe);
        say("smoke-mcp: focused fresh-cache browser startup ok");
        return 0;
    }
    if (c.getenv("SKETERM_SMOKE_MCP_WEB_ONLY") != null) {
        // The client-spawn lane (sessions); see the full run's note.
        _ = c.setenv("SKETERM_WEB_BROKER_ENGINE", "0", 1);
        defer _ = c.unsetenv("SKETERM_WEB_BROKER_ENGINE");
        return webOnly(allocator, exe, rt);
    }
    if (c.getenv("SKETERM_SMOKE_MCP_WEBSESSION_ONLY") != null) {
        _ = c.setenv("SKETERM_WEB_BROKER_ENGINE", "0", 1);
        defer _ = c.unsetenv("SKETERM_WEB_BROKER_ENGINE");
        webSessionFakeStage(allocator, exe, rt);
        say("smoke-mcp: focused watchable web session ok");
        return 0;
    }
    if (c.getenv("SKETERM_SMOKE_MCP_WEBPROFILE_ONLY") != null) {
        _ = c.setenv("SKETERM_WEB_BROKER_ENGINE", "0", 1);
        defer _ = c.unsetenv("SKETERM_WEB_BROKER_ENGINE");
        webProfileFakeStage(allocator, exe, rt);
        say("smoke-mcp: focused headless browsing profiles ok");
        return 0;
    }
    if (c.getenv("SKETERM_SMOKE_MCP_WEBPOLICY_ONLY") != null) {
        _ = c.setenv("SKETERM_WEB_BROKER_ENGINE", "0", 1);
        defer _ = c.unsetenv("SKETERM_WEB_BROKER_ENGINE");
        webPolicyFakeStage(allocator, exe, rt);
        say("smoke-mcp: focused network policy (fake helper) ok");
        return 0;
    }
    if (c.getenv("SKETERM_SMOKE_MCP_WEBSHARED_ONLY") != null) {
        var bin_buf: [4096:0]u8 = undefined;
        const web_bin = resolveWebBin(&bin_buf) orelse {
            say("smoke-mcp: SKIP focused shared-profile stage (sketerm-webengine not built)");
            return 0;
        };
        _ = c.setenv("SKETERM_WEB_BIN", web_bin, 1);
        defer _ = c.unsetenv("SKETERM_WEB_BIN");
        webSharedProfileStage(allocator, exe, rt);
        say("smoke-mcp: focused shared-profile stage ok");
        return 0;
    }
    if (c.getenv("SKETERM_SMOKE_MCP_WEBCAPTURE_ONLY") != null) {
        var bin_buf: [4096:0]u8 = undefined;
        const web_bin = resolveWebBin(&bin_buf) orelse fail("sketerm-webengine not built for the capture stage");
        _ = c.setenv("SKETERM_WEB_BIN", web_bin, 1);
        defer _ = c.unsetenv("SKETERM_WEB_BIN");
        _ = c.setenv("SKETERM_WEB_BROKER_ENGINE", "0", 1);
        defer _ = c.unsetenv("SKETERM_WEB_BROKER_ENGINE");
        webCaptureStage(allocator, exe, rt);
        say("smoke-mcp: focused response-body capture ok");
        return 0;
    }
    if (c.getenv("SKETERM_SMOKE_MCP_WEBTABS_ONLY") != null) {
        var bin_buf: [4096:0]u8 = undefined;
        const web_bin = resolveWebBin(&bin_buf) orelse fail("sketerm-webengine not built for the tab-targeting stage");
        _ = c.setenv("SKETERM_WEB_BIN", web_bin, 1);
        defer _ = c.unsetenv("SKETERM_WEB_BIN");
        _ = c.setenv("SKETERM_WEB_BROKER_ENGINE", "0", 1);
        defer _ = c.unsetenv("SKETERM_WEB_BROKER_ENGINE");
        webTabsStage(allocator, exe, rt);
        say("smoke-mcp: focused shared-browser tab targeting ok");
        return 0;
    }
    if (c.getenv("SKETERM_SMOKE_MCP_WEBSTREAM_ONLY") != null) {
        var bin_buf: [4096:0]u8 = undefined;
        const web_bin = resolveWebBin(&bin_buf) orelse fail("built sketerm-webengine missing for the stream stage");
        _ = c.setenv("SKETERM_WEB_BIN", web_bin, 1);
        defer _ = c.unsetenv("SKETERM_WEB_BIN");
        webStreamStage(allocator, exe, rt);
        say("smoke-mcp: focused pushed web stream ok");
        return 0;
    }
    if (c.getenv("SKETERM_SMOKE_MCP_WEBPRESENTER_ONLY") != null) {
        var bin_buf: [4096:0]u8 = undefined;
        const web_bin = resolveWebBin(&bin_buf) orelse {
            say("smoke-mcp: SKIP focused presenter stage (sketerm-webengine not built)");
            return 0;
        };
        _ = c.setenv("SKETERM_WEB_BIN", web_bin, 1);
        defer _ = c.unsetenv("SKETERM_WEB_BIN");
        webPresenterStage(allocator, exe, rt);
        say("smoke-mcp: focused watch-along presenter stage ok");
        return 0;
    }
    if (c.getenv("SKETERM_SMOKE_MCP_AGENTSSH_ONLY") != null) {
        agentSshStage(allocator, exe, rt);
        say("smoke-mcp: focused sub-agents over ssh stage ok");
        killDaemonsUnderRt(rt, allocator);
        _ = c.usleep(500_000);
        g_rt = null;
        pathz.removeTree(rt);
        return 0;
    }
    // Focused only, by design: routes + the daemon's assistants report.
    if (c.getenv("SKETERM_SMOKE_MCP_ROUTE_ONLY") != null) {
        routeStage(allocator, exe, rt);
        say("smoke-mcp: focused routes and assistants report stage ok");
        killDaemonsUnderRt(rt, allocator);
        _ = c.usleep(500_000);
        g_rt = null;
        pathz.removeTree(rt);
        return 0;
    }
    if (c.getenv("SKETERM_SMOKE_MCP_AGENT_ONLY") != null) {
        agentStage(allocator, exe, rt);
        say("smoke-mcp: focused sub-agent stage ok");
        killDaemonsUnderRt(rt, allocator);
        _ = c.usleep(500_000);
        g_rt = null;
        pathz.removeTree(rt);
        return 0;
    }
    if (c.getenv("SKETERM_SMOKE_MCP_WEBENGINE_ONLY") != null) {
        var bin_buf: [4096:0]u8 = undefined;
        const web_bin = resolveWebBin(&bin_buf) orelse {
            say("smoke-mcp: SKIP focused engine-lifecycle stage (sketerm-webengine not built)");
            return 0;
        };
        _ = c.setenv("SKETERM_WEB_BIN", web_bin, 1);
        defer _ = c.unsetenv("SKETERM_WEB_BIN");
        webEngineLifecycleStage(allocator, exe, rt);
        say("smoke-mcp: focused engine-lifecycle stage ok");
        return 0;
    }

    // ── Stage 1: ephemeral isolation + headless terminal ──────────
    {
        var m = Mcp.spawn(allocator, exe, &.{});
        m.initialize();
        var doctor_buf: [64 * 1024]u8 = undefined;
        const before_mux = doctorOutput(exe, &doctor_buf);
        var pid_buf: [64]u8 = undefined;
        const pid_text = std.fmt.bufPrint(&pid_buf, "pid {d}", .{m.pid}) catch unreachable;
        if (std.mem.indexOf(u8, before_mux, "mcp       1 active server(s)") == null or
            std.mem.indexOf(u8, before_mux, pid_text) == null or
            std.mem.indexOf(u8, before_mux, "isolated") == null or
            std.mem.indexOf(u8, before_mux, "mux not started") == null)
            fail("doctor did not show the live lazy MCP server");
        if (std.mem.indexOfScalar(u8, before_mux, 0x1b) != null)
            fail("doctor emitted color while stdout was not a terminal");

        const tools = m.callTool("term_list", "{}"); // any term tool proves routing
        if (std.mem.indexOf(u8, tools, "\"terms\":[]") == null or
            std.mem.indexOf(u8, tools, "\"count\":0") == null)
            fail("term_list did not return an empty structured list");

        const open = m.callTool("term_open", "{\"command\":[\"/bin/bash\"],\"cols\":80,\"rows\":24}");
        if (std.mem.indexOf(u8, open, "opened headless terminal") == null) fail("term_open failed");
        if (std.mem.indexOf(u8, open, "recording: ") == null or
            std.mem.indexOf(u8, open, "term-1.cast") == null)
            fail("term_open did not announce its auto asciicast recording");

        // Private daemon socket exists; shared one does NOT.
        var priv_buf: [512]u8 = undefined;
        const priv = std.fmt.bufPrint(&priv_buf, "{s}/sketerm/mcp-tmp-{d}/mux.sock", .{ rt, m.pid }) catch unreachable;
        if (!fileExists(priv)) fail("private daemon socket not created");
        var shared_buf: [512]u8 = undefined;
        const shared = std.fmt.bufPrint(&shared_buf, "{s}/sketerm/mux.sock", .{rt}) catch unreachable;
        if (fileExists(shared)) fail("shared mux.sock was created (isolation breach)");

        const after_mux = doctorOutput(exe, &doctor_buf);
        if (std.mem.indexOf(u8, after_mux, pid_text) == null or
            std.mem.indexOf(u8, after_mux, "mux pid ") == null or
            std.mem.indexOf(u8, after_mux, "1 session(s), 0 app") == null or
            std.mem.indexOf(u8, after_mux, "[pre-registry]") != null)
            fail("doctor did not show the MCP private daemon and session count");

        const run = m.callTool("term_run", "{\"command\":\"echo SMOKE-MCP-OK\"}");
        if (std.mem.indexOf(u8, run, "SMOKE-MCP-OK") == null) fail("term_run did not capture output");

        // Backward-compatible idle mode must still return while a
        // silent foreground command is running. Proven semantically,
        // not by wall clock (loaded machines made a timing bound
        // flaky): if idle mode returned early, the command's OSC 133 C
        // zone is still open, so a command-mode send must see busy.
        const idle_run = m.callTool("term_run", "{\"command\":\"sleep 1.5 >/dev/null 2>&1\",\"quiet_ms\":100,\"timeout_ms\":3000}");
        if (std.mem.indexOf(u8, idle_run, "output_only unavailable") != null) fail("plain idle-mode term_run changed output shape");
        const idle_probe = m.callTool("term_run", "{\"command\":\"echo MUST-NOT-RUN-IDLE\",\"wait_for\":\"command\"}");
        if (std.mem.indexOf(u8, idle_probe, "\"command_sent\":false") == null or
            std.mem.indexOf(u8, idle_probe, "outside command mode") == null)
        {
            std.debug.print("DEBUG idle_run: {s}\n", .{idle_run});
            std.debug.print("DEBUG idle_probe: {s}\n", .{idle_probe});
            fail("term_run idle mode waited for command completion");
        }
        const idle = m.callTool("term_wait_idle", "{\"quiet_ms\":100,\"timeout_ms\":500}");
        if (std.mem.indexOf(u8, idle, "idle") == null) fail("term_wait_idle no longer reports output quiescence");
        _ = c.usleep(1_600_000);

        const silent_ok = m.callTool("term_run", "{\"command\":\"sleep 0.1 >/dev/null 2>&1\",\"wait_for\":\"command\",\"output_only\":true}");
        if (std.mem.indexOf(u8, silent_ok, "\"state\":\"completed") == null or
            std.mem.indexOf(u8, silent_ok, "\"exit_status\":0") == null or
            std.mem.indexOf(u8, silent_ok, "shell_integration") == null)
            fail("silent successful command did not complete via OSC 133");

        const status_124 = m.callTool("term_run", "{\"command\":\"timeout 0.1 sh -c 'sleep 1' >/dev/null 2>&1\",\"wait_for\":\"command\",\"output_only\":true}");
        if (std.mem.indexOf(u8, status_124, "\"exit_status\":124") == null)
            fail("silent timeout command did not return status 124");

        const delayed = m.callTool("term_run", "{\"command\":\"sleep 0.2; printf 'MCP-DELAYED-OUTPUT\\\\n'\",\"wait_for\":\"command\",\"output_only\":true}");
        if (std.mem.indexOf(u8, delayed, "MCP-DELAYED-OUTPUT") == null or
            std.mem.indexOf(u8, delayed, "\"state\":\"completed") == null)
            fail("command completion missed delayed output");

        const command_timeout = m.callTool("term_run", "{\"command\":\"sleep 0.6 >/dev/null 2>&1\",\"wait_for\":\"command\",\"timeout_ms\":100}");
        if (std.mem.indexOf(u8, command_timeout, "\"state\":\"running") == null or
            std.mem.indexOf(u8, command_timeout, "\"timed_out\":true") == null or
            std.mem.indexOf(u8, command_timeout, "\"completion_source\":\"none") == null)
            fail("command timeout did not report a still-running command");
        const duplicate = m.callTool("term_run", "{\"command\":\"echo MUST-NOT-BE-SENT\",\"wait_for\":\"command\"}");
        if (std.mem.indexOf(u8, duplicate, "term_wait_command") == null or
            std.mem.indexOf(u8, duplicate, "\"command_sent\":false") == null)
            fail("second command was not rejected while completion remained pending");
        _ = c.usleep(650_000);
        const waited = m.callTool("term_wait_command", "{\"timeout_ms\":1000,\"output_only\":true}");
        if (std.mem.indexOf(u8, waited, "\"state\":\"completed") == null or
            std.mem.indexOf(u8, waited, "\"exit_status\":0") == null)
            fail("term_wait_command did not finish a timed-out command");

        const no_integration = m.callTool("term_open", "{\"command\":[\"/bin/sh\"]}");
        if (std.mem.indexOf(u8, no_integration, "opened headless terminal 2") == null) fail("plain sh terminal failed");
        const unsupported = m.callTool("term_run", "{\"term\":2,\"command\":\"echo MUST-NOT-RUN\",\"wait_for\":\"command\"}");
        if (std.mem.indexOf(u8, unsupported, "\"state\":\"unsupported") == null or
            std.mem.indexOf(u8, unsupported, "\"command_sent\":false") == null or
            std.mem.indexOf(u8, unsupported, "\"exit_status\":null") == null)
            fail("shell-integration absence was not reported safely");

        const signaled = m.callTool("term_run", "{\"term\":1,\"command\":\"exec sh -c 'kill -TERM $$'\",\"wait_for\":\"command\",\"timeout_ms\":3000}");
        if (std.mem.indexOf(u8, signaled, "\"exit_status\":-15") == null or
            std.mem.indexOf(u8, signaled, "process_tracking") == null)
            fail("signal-killed command did not use tracked process status");

        // Command mode straight after term_open: the first prompt mark
        // may not have rendered yet — the bounded wait must cover the
        // race instead of misreporting "unsupported".
        const fresh = m.callTool("term_open", "{\"command\":[\"/bin/bash\"],\"cols\":80,\"rows\":24}");
        if (std.mem.indexOf(u8, fresh, "opened headless terminal 3") == null) fail("fresh bash terminal failed");
        const fresh_run = m.callTool("term_run", "{\"term\":3,\"command\":\"true\",\"wait_for\":\"command\"}");
        if (std.mem.indexOf(u8, fresh_run, "\"state\":\"completed") == null or
            std.mem.indexOf(u8, fresh_run, "\"exit_status\":0") == null)
            fail("command mode raced the first prompt mark on a fresh terminal");

        // A foreground command started in idle mode must block a
        // command-mode send (its D would be misattributed), and the
        // rejection must not send the command.
        _ = m.callTool("term_run", "{\"term\":3,\"command\":\"sleep 0.5 >/dev/null 2>&1\",\"quiet_ms\":100,\"timeout_ms\":2000}");
        const busy = m.callTool("term_run", "{\"term\":3,\"command\":\"echo MUST-NOT-BE-SENT-BUSY\",\"wait_for\":\"command\"}");
        if (std.mem.indexOf(u8, busy, "\"command_sent\":false") == null or
            std.mem.indexOf(u8, busy, "outside command mode") == null)
            fail("busy shell did not reject a command-mode send");
        _ = c.usleep(600_000);
        const after_busy = m.callTool("term_run", "{\"term\":3,\"command\":\"echo BUSY-CLEARED\",\"wait_for\":\"command\",\"output_only\":true}");
        if (std.mem.indexOf(u8, after_busy, "BUSY-CLEARED") == null or
            std.mem.indexOf(u8, after_busy, "\"state\":\"completed") == null)
            fail("command mode did not recover once the busy command finished");

        // ── capabilities preflight ────────────────────────────────
        const caps = m.callTool("capabilities", "{}");
        if (std.mem.indexOf(u8, caps, "\"mode\":\"isolated\"") == null or
            std.mem.indexOf(u8, caps, "\"headless_terminals\":true") == null or
            std.mem.indexOf(u8, caps, "\"ocr\":") == null)
            fail("capabilities report incomplete");
        // A server with a browser backend names the engine's lifecycle
        // and owner as facts; consumers must never infer either.
        if (std.mem.indexOf(u8, caps, "\"web\":true") != null and
            (std.mem.indexOf(u8, caps, "\"web_engine_broker\":") == null or
                std.mem.indexOf(u8, caps, "\"web_engine_owner\":\"") == null))
            fail("capabilities has a web backend but no web_engine_broker/web_engine_owner facts");

        // ── file_* tools (fsdrive against the private daemon) ─────
        {
            var fsd_buf: [512]u8 = undefined;
            const fsd = std.fmt.bufPrint(&fsd_buf, "{s}/fs-tools", .{rt}) catch unreachable;
            var jb: [1024]u8 = undefined;
            _ = m.callTool("file_mkdir", std.fmt.bufPrint(&jb, "{{\"path\":\"{s}\"}}", .{fsd}) catch unreachable);
            const wr = m.callTool("file_write", std.fmt.bufPrint(&jb, "{{\"path\":\"{s}/a.txt\",\"content\":\"MCP-FS-PAYLOAD\"}}", .{fsd}) catch unreachable);
            if (std.mem.indexOf(u8, wr, "14 bytes written") == null) fail("file_write failed");
            const ls = m.callTool("file_list", std.fmt.bufPrint(&jb, "{{\"path\":\"{s}\"}}", .{fsd}) catch unreachable);
            if (std.mem.indexOf(u8, ls, "a.txt") == null or std.mem.indexOf(u8, ls, "1 entries") == null)
                fail("file_list missing the written file");
            const rd = m.callTool("file_read", std.fmt.bufPrint(&jb, "{{\"path\":\"{s}/a.txt\"}}", .{fsd}) catch unreachable);
            if (std.mem.indexOf(u8, rd, "MCP-FS-PAYLOAD") == null or std.mem.indexOf(u8, rd, "eof") == null)
                fail("file_read did not return the content");
            const cp = m.callTool("file_copy", std.fmt.bufPrint(&jb, "{{\"src\":\"{s}/a.txt\",\"dst\":\"{s}/b.txt\"}}", .{ fsd, fsd }) catch unreachable);
            if (std.mem.indexOf(u8, cp, "done: 14 bytes") == null) fail("file_copy job failed");
            const h1 = m.callTool("file_hash", std.fmt.bufPrint(&jb, "{{\"path\":\"{s}/a.txt\"}}", .{fsd}) catch unreachable);
            const h2 = m.callTool("file_hash", std.fmt.bufPrint(&jb, "{{\"path\":\"{s}/b.txt\"}}", .{fsd}) catch unreachable);
            // The digest is a machine fact now; the text lane repeats it.
            const key = "\"sha256\":\"";
            const hx1 = std.mem.indexOf(u8, h1, key) orelse fail("file_hash missing digest");
            const hx2 = std.mem.indexOf(u8, h2, key) orelse fail("file_hash missing digest 2");
            if (!std.mem.eql(u8, h1[hx1 + key.len .. hx1 + key.len + 64], h2[hx2 + key.len .. hx2 + key.len + 64]))
                fail("copy hash mismatch");
            const jl = m.callTool("file_jobs", "{}");
            if (std.mem.indexOf(u8, jl, "copy done") == null) fail("file_jobs missing the finished copy");
            // Existing destinations are refused unless overwrite:true.
            _ = m.callTool("file_write", std.fmt.bufPrint(&jb, "{{\"path\":\"{s}/c.txt\",\"content\":\"KEEP\"}}", .{fsd}) catch unreachable);
            const cp_again = m.callTool("file_copy", std.fmt.bufPrint(&jb, "{{\"src\":\"{s}/a.txt\",\"dst\":\"{s}/c.txt\"}}", .{ fsd, fsd }) catch unreachable);
            if (std.mem.indexOf(u8, cp_again, "\"code\":\"conflict\"") == null) {
                std.debug.print("smoke-mcp: file_copy reply: {s}\n", .{cp_again});
                fail("file_copy onto an existing file was not refused");
            }
            const mv_onto = m.callTool("file_rename", std.fmt.bufPrint(&jb, "{{\"from\":\"{s}/b.txt\",\"to\":\"{s}/c.txt\"}}", .{ fsd, fsd }) catch unreachable);
            if (std.mem.indexOf(u8, mv_onto, "\"code\":\"conflict\"") == null) fail("file_rename onto an existing file was not refused");
            const kept = m.callTool("file_read", std.fmt.bufPrint(&jb, "{{\"path\":\"{s}/c.txt\"}}", .{fsd}) catch unreachable);
            if (std.mem.indexOf(u8, kept, "KEEP") == null) fail("a refused copy/rename changed the destination");
            const cp_over = m.callTool("file_copy", std.fmt.bufPrint(&jb, "{{\"src\":\"{s}/a.txt\",\"dst\":\"{s}/c.txt\",\"overwrite\":true}}", .{ fsd, fsd }) catch unreachable);
            if (std.mem.indexOf(u8, cp_over, "done: 14 bytes") == null) fail("file_copy overwrite:true failed");
            const mv_over = m.callTool("file_rename", std.fmt.bufPrint(&jb, "{{\"from\":\"{s}/c.txt\",\"to\":\"{s}/b.txt\",\"overwrite\":true}}", .{ fsd, fsd }) catch unreachable);
            if (std.mem.indexOf(u8, mv_over, "\"renamed\":true") == null) fail("file_rename overwrite:true failed");
            const del = m.callTool("file_delete", std.fmt.bufPrint(&jb, "{{\"path\":\"{s}/b.txt\"}}", .{fsd}) catch unreachable);
            if (std.mem.indexOf(u8, del, "deleted") == null) fail("file_delete failed");
            // Error honesty: missing path is an isError reply, not a lie.
            const missing = m.callTool("file_stat", std.fmt.bufPrint(&jb, "{{\"path\":\"{s}/nope\"}}", .{fsd}) catch unreachable);
            if (std.mem.indexOf(u8, missing, "isError") == null) fail("file_stat of missing path not an error");
            std.debug.print("smoke-mcp: file_* tools ok\n", .{});
        }

        // ── new_tab falls back to a headless terminal (no GUI) ────
        const nt = m.callTool("new_tab", "{}");
        if (std.mem.indexOf(u8, nt, "\"headless\":true") == null or
            std.mem.indexOf(u8, nt, "\"term\":") == null)
            fail("new_tab did not fall back to a headless terminal");

        // ── pane tools without a GUI drive that headless terminal ─
        {
            const lt = m.callTool("list_terminals", "{}");
            if (std.mem.indexOf(u8, lt, "\"headless\":true") == null)
                fail("list_terminals without a GUI did not list the headless terminals");
            const st = m.callTool("send_text", "{\"pane\":3,\"text\":\"echo PANE-HEADLESS-$((6*7))\",\"enter\":true}");
            if (std.mem.indexOf(u8, st, "isError") != null or std.mem.indexOf(u8, st, "\"headless\":true") == null)
                fail("send_text did not reach the headless terminal by its pane id");
            _ = m.callTool("wait_idle", "{\"pane\":3,\"quiet_ms\":300,\"timeout_ms\":10000}");
            var seen = false;
            var tries: u32 = 0;
            while (tries < 20 and !seen) : (tries += 1) {
                const rs = m.callTool("read_screen", "{\"pane\":3}");
                seen = std.mem.indexOf(u8, rs, "PANE-HEADLESS-42") != null;
                if (!seen) _ = c.usleep(200_000);
            }
            if (!seen) fail("read_screen on the headless pane never showed the command's output");
            const rc = m.callTool("run_command", "{\"pane\":3,\"command\":\"echo RUN-HEADLESS-$((6*9))\",\"quiet_ms\":300,\"timeout_ms\":15000}");
            if (std.mem.indexOf(u8, rc, "RUN-HEADLESS-54") == null)
                fail("run_command on the headless pane did not return the command's output");
            const shot = m.callTool("screenshot_pane", "{\"pane\":3}");
            if (std.mem.indexOf(u8, shot, "\"code\":\"unavailable\"") == null)
                fail("screenshot_pane without a GUI did not answer the unavailable code");
        }

        // ── term_exec: sentinel-based structured exec ─────────────
        const ex1 = m.callTool("term_exec", "{\"term\":3,\"command\":\"echo EXEC-STRUCT; false\"}");
        if (std.mem.indexOf(u8, ex1, "\"completed\":true") == null or
            std.mem.indexOf(u8, ex1, "\"exit_status\":1") == null or
            std.mem.indexOf(u8, ex1, "EXEC-STRUCT") == null)
            fail("term_exec did not return structured output + status");
        // Works without shell integration too (plain /bin/sh, term 2).
        const ex2 = m.callTool("term_exec", "{\"term\":2,\"command\":\"echo SH-EXEC-OK\"}");
        if (std.mem.indexOf(u8, ex2, "\"completed\":true") == null or
            std.mem.indexOf(u8, ex2, "\"exit_status\":0") == null or
            std.mem.indexOf(u8, ex2, "SH-EXEC-OK") == null)
            fail("term_exec failed on an integration-less shell");
        // subshell=true keeps state out of the session.
        _ = m.callTool("term_exec", "{\"term\":3,\"command\":\"SMOKE_LEAK=xyz\",\"subshell\":true}");
        const leak = m.callTool("term_exec", "{\"term\":3,\"command\":\"echo LEAK=[$SMOKE_LEAK]\"}");
        if (std.mem.indexOf(u8, leak, "LEAK=[]") == null or std.mem.indexOf(u8, leak, "LEAK=[xyz]") != null)
            fail("subshell exec leaked state into the session");
        // set -e in the session must not kill it when a command fails
        // (the feedback scenario: a probe curl closed the whole SSH
        // connection).
        _ = m.callTool("term_exec", "{\"term\":3,\"command\":\"set -e\",\"subshell\":false}");
        const under_e = m.callTool("term_exec", "{\"term\":3,\"command\":\"false\",\"subshell\":false}");
        if (std.mem.indexOf(u8, under_e, "\"completed\":true") == null or
            std.mem.indexOf(u8, under_e, "\"exit_status\":1") == null)
            fail("failing command under set -e did not report status 1");
        const survived = m.callTool("term_exec", "{\"term\":3,\"command\":\"echo STILL-ALIVE\",\"subshell\":false}");
        if (std.mem.indexOf(u8, survived, "STILL-ALIVE") == null)
            fail("shell died from a failing command under set -e");
        // Persistent-mode state (cwd) is visible to later isolated
        // execs (the sh child inherits the session's cwd).
        _ = m.callTool("term_exec", "{\"term\":3,\"command\":\"cd /tmp\",\"subshell\":false}");
        const cwd = m.callTool("term_exec", "{\"term\":3,\"command\":\"pwd\"}");
        if (std.mem.indexOf(u8, cwd, "/tmp") == null)
            fail("persistent-mode cd did not stick in the session");
        // Interactive-prompt observability: a command waiting for
        // keyboard input returns EARLY with pending + the live screen
        // + interactive_prompt, the tracker survives, an answer via
        // term_send_text completes it, and term_exec_wait reattaches.
        const blocked = m.callTool("term_exec", "{\"term\":3,\"command\":\"printf 'Continue? [y/N] '; read ans; echo GOT:$ans\",\"timeout_ms\":15000}");
        if (std.mem.indexOf(u8, blocked, "\"pending\":true") == null or
            std.mem.indexOf(u8, blocked, "\"interactive_prompt\":true") == null or
            std.mem.indexOf(u8, blocked, "\"tracker\":\"") == null or
            std.mem.indexOf(u8, blocked, "\"screen\":\"") == null or
            std.mem.indexOf(u8, blocked, "Continue?") == null)
            fail("blocked interactive command did not surface pending state + screen");
        if (std.mem.indexOf(u8, blocked, "\"timed_out\":true") != null)
            fail("interactive early-return was misreported as a timeout");
        _ = m.callTool("term_send_text", "{\"term\":3,\"text\":\"y\",\"enter\":true}");
        const resumed = m.callTool("term_exec_wait", "{\"term\":3,\"timeout_ms\":10000}");
        if (std.mem.indexOf(u8, resumed, "\"completed\":true") == null or
            std.mem.indexOf(u8, resumed, "\"exit_status\":0") == null or
            std.mem.indexOf(u8, resumed, "GOT:y") == null)
            fail("term_exec_wait did not resume the answered command");
        // output_file: full output to a local file, tail inline.
        var of_buf: [640]u8 = undefined;
        const of_args = std.fmt.bufPrint(&of_buf, "{{\"term\":3,\"command\":\"seq 1 500\",\"output_file\":\"{s}/exec-out.txt\"}}", .{rt}) catch unreachable;
        const filed = m.callTool("term_exec", of_args);
        if (std.mem.indexOf(u8, filed, "\"output_file\":") == null or
            std.mem.indexOf(u8, filed, "\"output_bytes\":") == null)
            fail("term_exec output_file was not honored");
        var of_path_buf: [512]u8 = undefined;
        const of_path = std.fmt.bufPrint(&of_path_buf, "{s}/exec-out.txt", .{rt}) catch unreachable;
        if (!fileExists(of_path)) fail("term_exec output_file missing on disk");
        // shell option: bash-only semantics (pipefail) work when asked
        // for, and the plain-sh default rejects them.
        const pf = m.callTool("term_exec", "{\"term\":3,\"command\":\"set -o pipefail && false | cat; echo PF:$?\",\"shell\":\"bash\"}");
        if (std.mem.indexOf(u8, pf, "PF:1") == null)
            fail("shell=bash did not provide pipefail semantics");
        const badsh = m.callTool("term_exec", "{\"term\":3,\"command\":\"true\",\"shell\":\"bash; rm -rf /\"}");
        if (std.mem.indexOf(u8, badsh, "invalid 'shell'") == null)
            fail("shell metacharacters were not rejected");
        // ps-safety: the command line never appears in any process's
        // argv — only the grep that searches for it matches itself,
        // so the count is exactly 1 (the old sh -c transport made 2+).
        const psq = m.callTool("term_exec", "{\"term\":3,\"command\":\"ps -eo args | grep -c SK_PS_CANARY_42\",\"timeout_ms\":15000}");
        if (std.mem.indexOf(u8, psq, "\"exit_status\":0") == null or
            std.mem.indexOf(u8, psq, "\"output\":\"1\\n") == null)
            fail("the exec transport leaked the command onto a process command line (ps saw it)");

        // ── term_wait_exit: real process exit, not output idle ────
        const t4 = m.callTool("term_open", "{\"command\":[\"sh\",\"-c\",\"sleep 0.3; exit 7\"]}");
        if (std.mem.indexOf(u8, t4, "opened headless terminal") == null) fail("short-lived term_open failed");
        const wexit = m.callTool("term_wait_exit", "{\"term\":5,\"timeout_ms\":5000}");
        if (std.mem.indexOf(u8, wexit, "\"exited\":true") == null or
            std.mem.indexOf(u8, wexit, "\"exit_status\":7") == null)
            fail("term_wait_exit missed the real exit status");
        const listing = m.callTool("term_list", "{}");
        if (std.mem.indexOf(u8, listing, "\"exit_status\":7") == null)
            fail("term_list does not show the exit status");
        const post_read = m.callTool("term_read", "{\"term\":5}");
        if (std.mem.indexOf(u8, post_read, "process exited with status 7") == null)
            fail("term_read on an exited terminal lacks the exit banner");

        // ── scp_put (local): checksum + atomic rename ────────────
        var src_buf: [512]u8 = undefined;
        var dst_buf: [512]u8 = undefined;
        const xsrc = std.fmt.bufPrintZ(&src_buf, "{s}/xfer-src.bin", .{rt}) catch unreachable;
        const xdst = std.fmt.bufPrint(&dst_buf, "{s}/xfer-dst.bin", .{rt}) catch unreachable;
        const xf = c.fopen(xsrc.ptr, "wb") orelse fail("cannot create transfer source");
        _ = c.fwrite("transfer-payload", 1, 16, xf);
        _ = c.fclose(xf);
        var xargs_buf: [1200]u8 = undefined;
        const xargs = std.fmt.bufPrint(&xargs_buf, "{{\"local_path\":\"{s}\",\"remote_path\":\"{s}\"}}", .{ xsrc, xdst }) catch unreachable;
        const up = m.callTool("scp_put", xargs);
        if (std.mem.indexOf(u8, up, "\"direction\":\"upload\"") == null or
            std.mem.indexOf(u8, up, "\"verified\":true") == null or
            std.mem.indexOf(u8, up, "\"atomic\":true") == null)
            fail("local scp_put did not verify");
        if (!fileExists(xdst)) fail("scp_put destination missing");

        // ── automatic asciicast recording of terminal 1 ───────────
        {
            var cast_buf: [1 << 18]u8 = undefined;
            const cast = findCast(rt, "term-1.cast", &cast_buf) orelse
                fail("term-1.cast not found under the isolated state dir");
            if (std.mem.indexOf(u8, cast, "{\"version\": 2,") == null)
                fail("cast file has no asciicast v2 header");
            if (std.mem.indexOf(u8, cast, "SMOKE-MCP-OK") == null)
                fail("cast file does not contain the recorded output");
        }

        // Ephemeral teardown on stdin close removes the private dir.
        var dir_buf: [512]u8 = undefined;
        const dir = std.fmt.bufPrint(&dir_buf, "{s}/sketerm/mcp-tmp-{d}", .{ rt, m.pid }) catch unreachable;
        m.closeStdinWait();
        _ = c.usleep(500_000);
        if (fileExists(dir)) fail("ephemeral instance dir not removed on exit");
        say("smoke-mcp: ephemeral isolation + headless terminal ok");
    }

    // ── Stage 2: named durable daemon survives an MCP restart ─────
    {
        var m = Mcp.spawn(allocator, exe, &.{ "--name", "smoke1" });
        m.initialize();
        const open = m.callTool("term_open", "{\"command\":[\"/bin/sh\"]}");
        if (std.mem.indexOf(u8, open, "opened headless terminal") == null) fail("durable term_open failed");
        var named_buf: [512]u8 = undefined;
        const named = std.fmt.bufPrint(&named_buf, "{s}/sketerm/mcp-smoke1/mux.sock", .{rt}) catch unreachable;
        if (!fileExists(named)) fail("named daemon socket not created");
        m.closeStdinWait();
        _ = c.usleep(500_000);
        // Durable: the dir and daemon survive.
        var dir_buf: [512]u8 = undefined;
        const dir = std.fmt.bufPrint(&dir_buf, "{s}/sketerm/mcp-smoke1", .{rt}) catch unreachable;
        if (!fileExists(dir)) fail("durable instance dir removed (should persist)");
        if (!daemonUnderRt(allocator, rt)) fail("durable daemon did not survive MCP exit");

        // Reconnect: a fresh MCP with the same name reaches the SAME
        // daemon (no new daemon spawned, the socket already exists).
        // Terminals themselves are per-MCP, so open a fresh one and
        // prove it runs against the surviving daemon.
        var m2 = Mcp.spawn(allocator, exe, &.{ "--name", "smoke1" });
        m2.initialize();
        const open2 = m2.callTool("term_open", "{\"command\":[\"/bin/sh\"]}");
        if (std.mem.indexOf(u8, open2, "opened headless terminal") == null) fail("reconnected term_open failed");
        const run = m2.callTool("term_run", "{\"command\":\"echo DURABLE-OK\"}");
        if (std.mem.indexOf(u8, run, "DURABLE-OK") == null) fail("reconnected durable term_run failed");
        m2.closeStdinWait();
        say("smoke-mcp: named durable daemon survives restart ok");
    }

    // ── Stage 2b: bare --durable is the instance named "default" ──
    // It used to fall through to the pid-based mcp-tmp-<pid> dir, which
    // no later run can name and the startup sweep reaps.
    {
        var m = Mcp.spawn(allocator, exe, &.{"--durable"});
        m.initialize();
        const open = m.callTool("term_open", "{\"command\":[\"/bin/sh\"]}");
        if (std.mem.indexOf(u8, open, "opened headless terminal") == null) fail("bare --durable term_open failed");
        var dir_buf: [512]u8 = undefined;
        const dir = std.fmt.bufPrint(&dir_buf, "{s}/sketerm/mcp-default", .{rt}) catch unreachable;
        if (!fileExists(dir)) fail("bare --durable did not use the mcp-default instance dir");
        var tmp_buf: [512]u8 = undefined;
        const tmp_dir = std.fmt.bufPrint(&tmp_buf, "{s}/sketerm/mcp-tmp-{d}", .{ rt, m.pid }) catch unreachable;
        if (fileExists(tmp_dir)) fail("bare --durable used an ephemeral pid dir");
        m.closeStdinWait();
        _ = c.usleep(500_000);
        if (!fileExists(dir)) fail("bare --durable instance dir removed (should persist)");
        // A second bare --durable finds the same instance again.
        var m2 = Mcp.spawn(allocator, exe, &.{"--durable"});
        m2.initialize();
        const run = m2.callTool("term_open", "{\"command\":[\"/bin/sh\"]}");
        if (std.mem.indexOf(u8, run, "opened headless terminal") == null) fail("reconnected bare --durable term_open failed");
        m2.closeStdinWait();
        say("smoke-mcp: bare --durable is the \"default\" instance ok");
    }

    // ── Stage 3: tool exposure policy (SKETERM_MCP_TOOLS) ─────────
    // Filtering tools/list is presentation; the load-bearing half is
    // that tools/call refuses a withheld tool a client learned about
    // some other way, with an error that says why.
    {
        _ = c.setenv("SKETERM_MCP_TOOLS", "app:ro, term_list", 1);
        defer _ = c.unsetenv("SKETERM_MCP_TOOLS");
        var m = Mcp.spawn(allocator, exe, &.{});
        m.initialize();

        const listed = m.listTools();
        // The reply must be complete (recvLine truncates at 1MB, and a
        // truncated list would read as a successfully filtered one).
        if (!std.mem.endsWith(u8, listed, "}")) fail("tools/list reply truncated");
        if (std.mem.indexOf(u8, listed, "\"screenshot_app\"") == null or
            std.mem.indexOf(u8, listed, "\"app_a11y_tree\"") == null)
            fail("tools/list dropped an allowed read-only app tool");
        if (std.mem.indexOf(u8, listed, "\"capabilities\"") == null)
            fail("tools/list dropped the always-on capabilities tool");
        if (std.mem.indexOf(u8, listed, "\"term_list\"") == null)
            fail("tools/list dropped the single-tool allow term");
        if (std.mem.indexOf(u8, listed, "\"app_click\"") != null)
            fail("tools/list kept a mutating tool under a :ro group term");
        if (std.mem.indexOf(u8, listed, "\"run_command\"") != null or
            std.mem.indexOf(u8, listed, "\"file_write\"") != null or
            std.mem.indexOf(u8, listed, "\"term_open\"") != null)
            fail("tools/list kept a tool from a suppressed group");

        // Enforcement.
        const refused = m.callTool("term_open", "{\"command\":[\"/bin/sh\"]}");
        if (std.mem.indexOf(u8, refused, "isError") == null or
            std.mem.indexOf(u8, refused, "EXISTS but is not enabled") == null or
            std.mem.indexOf(u8, refused, "--tools term") == null)
            fail("tools/call did not refuse a withheld tool with a helpful error");
        if (std.mem.indexOf(u8, refused, "opened headless terminal") != null)
            fail("a withheld tool RAN (tools/list filtering is not enforcement)");

        // An allowed tool still works, including the single-tool term.
        const allowed = m.callTool("term_list", "{}");
        if (std.mem.indexOf(u8, allowed, "isError") != null)
            fail("an allowed tool was refused");

        // capabilities explains the policy from inside the session.
        const caps = m.callTool("capabilities", "{}");
        if (std.mem.indexOf(u8, caps, "\"tool_policy\"") == null or
            std.mem.indexOf(u8, caps, "app:ro, term_list") == null or
            std.mem.indexOf(u8, caps, "SKETERM_MCP_TOOLS") == null or
            std.mem.indexOf(u8, caps, "\"groups_suppressed\"") == null or
            std.mem.indexOf(u8, caps, "\"panes\"") == null or
            std.mem.indexOf(u8, caps, "\"files\"") == null)
            fail("capabilities does not report the active tool policy");
        m.closeStdinWait();
        say("smoke-mcp: tool exposure policy ok");
    }

    // ── Stage 4: an invalid policy fails loudly at startup ────────
    {
        _ = c.setenv("SKETERM_MCP_TOOLS", "app, browzer", 1);
        defer _ = c.unsetenv("SKETERM_MCP_TOOLS");
        var err_pipe: [2]c_int = undefined;
        if (c.pipe(&err_pipe) != 0) fail("pipe");
        const pid = c.fork();
        if (pid < 0) fail("fork");
        if (pid == 0) {
            _ = c.dup2(err_pipe[1], 2);
            _ = c.close(err_pipe[0]);
            _ = c.close(err_pipe[1]);
            var argv: [3:null]?[*:0]const u8 = .{ exe, "mcp", null };
            _ = c.execv(exe, @ptrCast(&argv));
            c._exit(127);
        }
        _ = c.close(err_pipe[1]);
        var buf: [4096]u8 = undefined;
        const n = c.read(err_pipe[0], &buf, buf.len);
        _ = c.close(err_pipe[0]);
        var st: c_int = 0;
        _ = c.waitpid(pid, &st, 0);
        const errtxt = if (n > 0) buf[0..@intCast(n)] else "";
        if (std.mem.indexOf(u8, errtxt, "browzer") == null or
            std.mem.indexOf(u8, errtxt, "groups:") == null)
            fail("a typo'd tool policy did not name the offending term + the valid groups");
        if (st == 0) fail("a typo'd tool policy did not fail the startup");
        say("smoke-mcp: invalid tool policy refuses to start ok");
    }

    // ── Stage 5: the ui_* panel tools under a `ui` policy ─────────
    // No session origin or direct GUI here on purpose: this proves the
    // group is reachable on its own, that the live-panel half refuses
    // honestly instead of hanging, and that the saved half works
    // regardless — including for a session name with a space in it,
    // which the store used to reject outright.
    {
        _ = c.setenv("SKETERM_MCP_TOOLS", "ui", 1);
        defer _ = c.unsetenv("SKETERM_MCP_TOOLS");
        var m = Mcp.spawn(allocator, exe, &.{});
        m.initialize();

        const listed = m.listTools();
        if (!std.mem.endsWith(u8, listed, "}")) fail("tools/list reply truncated");
        // Panels no longer need --shared, so nothing may still ask for it.
        if (std.mem.indexOf(u8, listed, "--shared") != null or
            std.mem.indexOf(u8, listed, "relays through that session's own mux daemon") == null or
            std.mem.indexOf(u8, listed, "decoded by the GUI") == null)
            fail("ui tool descriptions do not describe the session relay and remote image hydration");
        for ([_][]const u8{ "ui_show", "ui_show_files", "ui_patch", "ui_wait_event", "ui_panels", "ui_save", "ui_close", "ui_delete" }) |tool| {
            var nb: [64]u8 = undefined;
            const quoted = std.fmt.bufPrint(&nb, "\"{s}\"", .{tool}) catch unreachable;
            if (std.mem.indexOf(u8, listed, quoted) == null) fail("tools/list dropped a ui tool under --tools ui");
        }
        if (std.mem.indexOf(u8, listed, "\"term_open\"") != null or
            std.mem.indexOf(u8, listed, "\"run_command\"") != null or
            std.mem.indexOf(u8, listed, "\"file_write\"") != null)
            fail("tools/list kept a non-ui tool under --tools ui");

        const refused = m.callTool("term_open", "{\"command\":[\"/bin/sh\"]}");
        if (std.mem.indexOf(u8, refused, "EXISTS but is not enabled") == null or
            std.mem.indexOf(u8, refused, "--tools term") == null)
            fail("a terminal tool was not refused under --tools ui");
        if (std.mem.indexOf(u8, refused, "opened headless terminal") != null)
            fail("a withheld terminal tool RAN under --tools ui");

        // A present session is type-strict for every ui tool. None may treat
        // null or another JSON type as absence and inherit SKETERM_SESSION.
        for ([_][]const u8{ "ui_show", "ui_show_files", "ui_patch", "ui_wait_event", "ui_panels", "ui_save", "ui_close", "ui_delete" }) |tool| {
            for ([_][]const u8{ "null", "0", "1.5", "{}", "[]", "true", "false" }) |bad_session| {
                var args_buf: [96]u8 = undefined;
                const arguments = std.fmt.bufPrint(&args_buf, "{{\"session\":{s}}}", .{bad_session}) catch
                    fail("invalid-session smoke arguments too long");
                const invalid_session = m.callTool(tool, arguments);
                if (std.mem.indexOf(u8, invalid_session, "isError") == null or
                    std.mem.indexOf(u8, invalid_session, "must be a string when present") == null)
                    fail("a ui tool accepted a present non-string session");
            }
        }

        // The live half: no origin daemon or GUI socket, so a described
        // refusal naming the missing transport -- never a hang.
        const no_gui = m.callTool("ui_show", "{\"name\":\"p\",\"session\":\"smoke ui\",\"document\":{\"root\":\"t\",\"components\":{\"t\":{\"type\":\"text\",\"text\":\"hi\"}}}}");
        if (std.mem.indexOf(u8, no_gui, "isError") == null or
            std.mem.indexOf(u8, no_gui, "origin mux daemon") == null)
            fail("ui_show without a panel origin did not explain the missing transport");
        const no_session = m.callTool("ui_show", "{\"name\":\"anon-live\",\"document\":{\"root\":\"t\",\"components\":{\"t\":{\"type\":\"text\",\"text\":\"hi\"}}}}");
        if (std.mem.indexOf(u8, no_session, "isError") == null or
            std.mem.indexOf(u8, no_session, "no live panel transport") == null)
            fail("sessionless ui_show without a direct socket was not refused honestly");

        // The saved half works anyway, under a session with a space.
        const saved = m.callTool("ui_save", "{\"name\":\"vsr\",\"session\":\"smoke ui\",\"document\":{\"title\":\"Epoch 41\",\"root\":\"c\",\"components\":{\"c\":{\"type\":\"column\",\"children\":[\"h\"]},\"h\":{\"type\":\"heading\",\"text\":\"Epoch 41\",\"level\":2}}}}");
        if (std.mem.indexOf(u8, saved, "isError") != null) fail("ui_save failed without a GUI");
        var pbuf: [512]u8 = undefined;
        const panel_file = std.fmt.bufPrint(&pbuf, "{s}/sketerm/panels/by-session/smoke%20ui/vsr.json", .{rt}) catch unreachable;
        if (!fileExists(panel_file)) fail("ui_save did not percent-encode the session into one directory under by-session/");

        // A sessionless save is a different PARENT directory, not a
        // session with a reserved name: nothing a real session can be
        // called reaches it, and it does not reach any session.
        const anon = m.callTool("ui_save", "{\"name\":\"anon\",\"document\":{\"title\":\"No session\",\"root\":\"t\",\"components\":{\"t\":{\"type\":\"text\",\"text\":\"hi\"}}}}");
        if (std.mem.indexOf(u8, anon, "isError") != null) fail("a sessionless ui_save failed");
        var nbuf: [512]u8 = undefined;
        const anon_file = std.fmt.bufPrint(&nbuf, "{s}/sketerm/panels/no-session/anon.json", .{rt}) catch unreachable;
        if (!fileExists(anon_file)) fail("a sessionless ui_save did not land in panels/no-session/");
        // The old sentinel is now an ordinary session name, filed with
        // every other session and blind to the sessionless bucket.
        const sentinel = m.callTool("ui_panels", "{\"session\":\"_no-session\"}");
        if (std.mem.indexOf(u8, sentinel, "No session") != null)
            fail("a session named _no-session can still see the sessionless panels");
        const anon_list = m.callTool("ui_panels", "{}");
        if (std.mem.indexOf(u8, anon_list, "No session") == null or
            std.mem.indexOf(u8, anon_list, "Epoch 41") != null)
            fail("the sessionless list is not exactly the sessionless panels");
        const anon_deleted = m.callTool("ui_delete", "{\"name\":\"anon\"}");
        if (std.mem.indexOf(u8, anon_deleted, "isError") != null) fail("a sessionless ui_delete failed");
        if (fileExists(anon_file)) fail("a sessionless ui_delete left the document on disk");

        const panels = m.callTool("ui_panels", "{\"session\":\"smoke ui\"}");
        if (std.mem.indexOf(u8, panels, "Epoch 41") == null or
            std.mem.indexOf(u8, panels, "\"live\":null") == null or
            std.mem.indexOf(u8, panels, "origin mux daemon") == null)
            fail("ui_panels did not separate the saved list from the unavailable live list");
        const other = m.callTool("ui_panels", "{\"session\":\"someone-else\"}");
        if (std.mem.indexOf(u8, other, "Epoch 41") != null)
            fail("a saved panel leaked into another session's list");

        // An invalid document is refused with the parser's message and
        // nothing is written.
        const bad = m.callTool("ui_save", "{\"name\":\"nope\",\"session\":\"smoke ui\",\"document\":{\"root\":\"r\",\"components\":{\"r\":{\"type\":\"webview\"}}}}");
        if (std.mem.indexOf(u8, bad, "isError") == null or std.mem.indexOf(u8, bad, "webview") == null)
            fail("ui_save accepted (or silently mangled) an invalid document");

        const caps = m.callTool("capabilities", "{}");
        if (std.mem.indexOf(u8, caps, "\"panels\":false") == null or
            std.mem.indexOf(u8, caps, "\"panels_store\":true") == null or
            std.mem.indexOf(u8, caps, "\"scope\":\"sessionless\"") == null or
            std.mem.indexOf(u8, caps, "\"state\":\"no_session_origin\"") == null or
            std.mem.indexOf(u8, caps, "\"gui_socket\":false") == null or
            std.mem.indexOf(u8, caps, "\"ui\"") == null)
            fail("capabilities does not report panel availability + the ui group");

        const deleted = m.callTool("ui_delete", "{\"name\":\"vsr\",\"session\":\"smoke ui\"}");
        if (std.mem.indexOf(u8, deleted, "isError") != null) fail("ui_delete failed");
        if (fileExists(panel_file)) fail("ui_delete left the saved document on disk");
        m.closeStdinWait();
        say("smoke-mcp: ui_* panel tools ok");
    }

    // ── Stage 6: isolated MCP relays panels to its origin session ─
    {
        var origin_dir_buf: [320]u8 = undefined;
        const origin_dir = std.fmt.bufPrintZ(&origin_dir_buf, "{s}/panel-origin", .{rt}) catch return 1;
        _ = c.mkdir(origin_dir.ptr, 0o700);
        var origin_sock_buf: [360]u8 = undefined;
        const origin_sock = std.fmt.bufPrintZ(&origin_sock_buf, "{s}/mux.sock", .{origin_dir}) catch return 1;
        var owner = muxclient.Conn.connectLocalAutostartAt(allocator, origin_sock) catch
            fail("could not start origin mux daemon");
        defer owner.deinit();
        owner.setNonBlocking();
        owner.sendJson(.spawn, .{
            .name = "panel-origin",
            .argv = [_][]const u8{ "sleep", "60" },
            .rows = @as(u16, 24),
            .cols = @as(u16, 80),
        }) catch fail("origin session spawn send");
        (owner.recvExpectFor(&.{.ok}, 5_000) catch fail("origin session spawn reply")).deinit(allocator);
        var presenter = attachPanelPresenter(allocator, origin_sock, "panel-origin");
        var presenter_live = true;
        defer if (presenter_live) presenter.deinit();
        var identity_probe = muxclient.connectPanelRequester(allocator, origin_sock, "panel-origin", 5_000) catch
            fail("could not read panel origin identity");
        defer identity_probe.deinit();
        const origin_id = allocator.dupeZ(u8, identity_probe.panelOriginId()) catch
            fail("could not retain panel origin identity");
        defer allocator.free(origin_id);
        if (origin_id.len != 32) fail("panel attach did not expose a valid lifetime origin_id");

        _ = c.setenv("SKETERM_SESSION", "panel-origin", 1);
        _ = c.setenv("SKETERM_MUX_SOCKET", origin_sock.ptr, 1);
        _ = c.setenv("SKETERM_SESSION_ORIGIN_ID", origin_id.ptr, 1);
        defer _ = c.unsetenv("SKETERM_SESSION");
        defer _ = c.unsetenv("SKETERM_MUX_SOCKET");
        defer _ = c.unsetenv("SKETERM_SESSION_ORIGIN_ID");

        var m = Mcp.spawn(allocator, exe, &.{});
        m.initialize();

        // Capability probing itself uses a read-only panel-list relay and
        // must distinguish it from the absent direct GUI socket.
        m.sendTool("capabilities", "{}");
        const cap_call = recvPanelCall(allocator, &presenter, 15_000);
        if (std.mem.indexOf(u8, cap_call.json, "\"cmd\":\"panel-list\"") == null)
            fail("capabilities did not probe the panel relay");
        replyPanel(&presenter, cap_call, "{\"ok\":true,\"panels\":[]}");
        cap_call.deinit(allocator);
        const caps = m.recvLine(15_000);
        if (std.mem.indexOf(u8, caps, "\"panels\":true") == null or
            std.mem.indexOf(u8, caps, "\"panels_store\":true") == null or
            std.mem.indexOf(u8, caps, "\"scope\":\"origin\"") == null or
            std.mem.indexOf(u8, caps, "\"gui_socket\":false") == null or
            std.mem.indexOf(u8, caps, "\"selected\":\"mux_relay\"") == null or
            std.mem.indexOf(u8, caps, "SKETERM_MUX_SOCKET") == null)
            fail("capabilities did not separate relay panels from gui_socket");

        // A store the filesystem refuses is reported by the call that
        // actually writes, exactly and without a partial document. The
        // preflight deliberately does not probe it: `capabilities` must stay
        // cheap and must not create or write anything.
        const origin_scope = panelstore.Scope{ .origin = .{
            .daemon_origin = origin_sock,
            .origin_id = origin_id,
        } };
        const capability_dir = panelstore.scopeDir(allocator, origin_scope) catch
            fail("could not resolve capability panel scope");
        defer allocator.free(capability_dir);
        // The preflight above must not have created the store it reports on.
        if (fileExists(capability_dir))
            fail("capabilities created the panel store scope directory");
        var cap_dir_z: [4096]u8 = undefined;
        const cap_dir_path = std.fmt.bufPrintZ(&cap_dir_z, "{s}", .{capability_dir}) catch
            fail("capability panel scope path too long");
        // One real save creates the scope on disk and proves the ordinary
        // path; the store is then made read-only under the server's feet.
        const stored = m.callTool(
            "ui_save",
            "{\"name\":\"writable\",\"document\":{\"root\":\"t\",\"components\":{\"t\":{\"type\":\"text\",\"text\":\"x\"}}}}",
        );
        if (std.mem.indexOf(u8, stored, "isError") != null)
            fail("a writable origin-qualified panel store refused an ordinary save");
        if (c.chmod(cap_dir_path.ptr, 0o500) != 0)
            fail("could not make the capability panel scope read-only");
        const refused = m.callTool(
            "ui_save",
            "{\"name\":\"unwritable\",\"document\":{\"root\":\"t\",\"components\":{\"t\":{\"type\":\"text\",\"text\":\"x\"}}}}",
        );
        _ = c.chmod(cap_dir_path.ptr, 0o700);
        if (std.mem.indexOf(u8, refused, "isError") == null or
            std.mem.indexOf(u8, refused, "PermissionDenied") == null or
            std.mem.indexOf(u8, refused, "mutation_may_have_applied=false") == null or
            std.mem.indexOf(u8, refused, "resend_safe=true") == null)
            fail("an unwritable panel store was not reported by the write itself");

        // Default isolated MCP, no --shared and no --socket: ui_show must
        // reach the presenter attached to the inherited origin session.
        m.sendTool("ui_show", "{\"name\":\"relayed\",\"document\":{\"root\":\"t\",\"components\":{\"t\":{\"type\":\"text\",\"text\":\"through mux\"}}}}");
        const show_call = recvPanelCall(allocator, &presenter, 15_000);
        if (std.mem.indexOf(u8, show_call.json, "\"cmd\":\"panel-show\"") == null or
            std.mem.indexOf(u8, show_call.json, "\"session\":\"panel-origin\"") == null or
            std.mem.indexOf(u8, show_call.json, "through mux") == null)
            fail("isolated ui_show did not route through the origin mux session");
        replyPanel(&presenter, show_call, "{\"ok\":true,\"panel_id\":41}");
        show_call.deinit(allocator);
        const shown = m.recvLine(15_000);
        if (std.mem.indexOf(u8, shown, "isError") != null or
            std.mem.indexOf(u8, shown, "\"panel_id\":41") == null)
            fail("relayed ui_show did not return the presenter result");

        // Both mixed live/store operations use the same chosen relay.
        m.sendTool("ui_panels", "{}");
        const list_call = recvPanelCall(allocator, &presenter, 15_000);
        if (std.mem.indexOf(u8, list_call.json, "\"cmd\":\"panel-list\"") == null)
            fail("ui_panels did not use the origin relay");
        replyPanel(&presenter, list_call, "{\"ok\":true,\"panels\":[{\"panel_id\":41,\"name\":\"relayed\",\"title\":\"Relay\",\"target\":\"tab\"}]}");
        list_call.deinit(allocator);
        const listed_live = m.recvLine(15_000);
        if (std.mem.indexOf(u8, listed_live, "relayed") == null or
            std.mem.indexOf(u8, listed_live, "\"live\":[") == null)
            fail("ui_panels did not return the relayed live inventory");

        m.sendTool("ui_save", "{\"name\":\"relayed\",\"panel_id\":41}");
        const get_call = recvPanelCall(allocator, &presenter, 15_000);
        if (std.mem.indexOf(u8, get_call.json, "\"cmd\":\"panel-get\"") == null)
            fail("ui_save without document did not use the origin relay");
        replyPanel(&presenter, get_call, "{\"ok\":true,\"document\":\"{\\\"title\\\":\\\"Relay live\\\",\\\"root\\\":\\\"t\\\",\\\"components\\\":{\\\"t\\\":{\\\"type\\\":\\\"text\\\",\\\"text\\\":\\\"through mux\\\"}}}\"}");
        get_call.deinit(allocator);
        const saved_live = m.recvLine(15_000);
        if (std.mem.indexOf(u8, saved_live, "isError") != null or
            std.mem.indexOf(u8, saved_live, "\"saved\":\"relayed\"") == null)
            fail("ui_save without document did not persist the relayed live document");
        var origin_saved_buf: [1024]u8 = undefined;
        const origin_saved = std.fmt.bufPrint(&origin_saved_buf, "{s}/relayed.json", .{capability_dir}) catch
            fail("origin-qualified panel path too long");
        if (!fileExists(origin_saved)) fail("relayed ui_save did not use the origin-qualified store");
        var legacy_saved_buf: [512]u8 = undefined;
        const legacy_saved = std.fmt.bufPrint(&legacy_saved_buf, "{s}/sketerm/panels/by-session/panel-origin/relayed.json", .{rt}) catch unreachable;
        if (fileExists(legacy_saved)) fail("relayed ui_save also wrote the legacy session-only namespace");

        // Rename changes only display identity. An explicit new alias must
        // attach to the same immutable origin and load the same saved file.
        owner.sendJson(.rename, .{ .name = "panel-origin", .new_name = "panel-renamed" }) catch
            fail("origin session rename send");
        (owner.recvExpectFor(&.{.ok}, 5_000) catch fail("origin session rename reply")).deinit(allocator);
        m.sendTool("ui_show", "{\"name\":\"after-rename\",\"session\":\"panel-renamed\",\"load\":\"relayed\"}");
        const renamed_call = recvPanelCall(allocator, &presenter, 15_000);
        if (std.mem.indexOf(u8, renamed_call.json, "Relay live") == null)
            fail("renamed session did not retain its origin-qualified saved panel");
        replyPanel(&presenter, renamed_call, "{\"ok\":true,\"panel_id\":42}");
        renamed_call.deinit(allocator);
        const renamed_show = m.recvLine(15_000);
        if (std.mem.indexOf(u8, renamed_show, "\"panel_id\":42") == null or
            std.mem.indexOf(u8, renamed_show, "isError") != null)
            fail("renamed session could not show its saved panel");

        // Repeated event polls reuse the same panel-only connection. The
        // first empty reply must not lose the event returned by the next.
        m.sendTool("ui_wait_event", "{\"panel_id\":41,\"timeout_ms\":2000}");
        // The read is the non-destructive panel-events-reliable: a poll
        // acknowledges only what an EARLIER reply delivered.
        const poll1 = recvPanelCall(allocator, &presenter, 15_000);
        if (std.mem.indexOf(u8, poll1.json, "\"cmd\":\"panel-events-reliable\"") == null)
            fail("ui_wait_event did not use the reliable event read");
        replyPanel(&presenter, poll1, "{\"ok\":true,\"event_epoch\":\"10000000000000000000000000000001\",\"events\":[],\"cursor\":0,\"dropped_total\":1}");
        poll1.deinit(allocator);
        const poll2 = recvPanelCall(allocator, &presenter, 15_000);
        replyPanel(&presenter, poll2, "{\"ok\":true,\"event_epoch\":\"10000000000000000000000000000001\",\"events\":[{\"seq\":2,\"component\":\"t\",\"kind\":\"click\",\"value\":\"ok\",\"ts\":42}],\"cursor\":2,\"dropped_total\":1}");
        poll2.deinit(allocator);
        const waited = m.recvLine(15_000);
        if (std.mem.indexOf(u8, waited, "\"value\":\"ok\"") == null or
            std.mem.indexOf(u8, waited, "\"dropped\":1") == null)
            fail("repeated relayed ui_wait_event polls lost state");
        // The next wait acknowledges what that reply handed over.
        m.sendTool("ui_wait_event", "{\"panel_id\":41,\"timeout_ms\":2000}");
        const poll3 = recvPanelCall(allocator, &presenter, 15_000);
        if (std.mem.indexOf(u8, poll3.json, "\"ack\":2") == null or
            std.mem.indexOf(u8, poll3.json, "10000000000000000000000000000001") == null)
            fail("ui_wait_event did not acknowledge the events it returned");
        replyPanel(&presenter, poll3, "{\"ok\":true,\"event_epoch\":\"10000000000000000000000000000001\",\"events\":[{\"seq\":3,\"component\":\"t\",\"kind\":\"click\",\"value\":\"again\",\"ts\":43}],\"cursor\":3,\"dropped_total\":1}");
        poll3.deinit(allocator);
        const waited_again = m.recvLine(15_000);
        if (std.mem.indexOf(u8, waited_again, "\"value\":\"again\"") == null or
            std.mem.indexOf(u8, waited_again, "\"dropped\":0") == null)
            fail("the acknowledged ui_wait_event misreported events or drops");

        // The daemon can correlate an envelope whose opaque JSON is invalid;
        // MCP must call that uncertain delivery explicitly and never resend.
        m.sendTool("ui_patch", "{\"panel_id\":41,\"patch\":[{\"op\":\"title\",\"value\":\"bad-json\"}]}");
        const invalid_json_call = recvPanelCall(allocator, &presenter, 15_000);
        replyPanel(&presenter, invalid_json_call, "not-json");
        invalid_json_call.deinit(allocator);
        const invalid_json = m.recvLine(15_000);
        if (std.mem.indexOf(u8, invalid_json, "isError") == null or
            std.mem.indexOf(u8, invalid_json, "uncertain") == null or
            std.mem.indexOf(u8, invalid_json, "NOT resent automatically") == null or
            std.mem.indexOf(u8, invalid_json, "mutation may have applied") == null)
            fail("invalid presenter JSON did not report uncertain no-resend semantics");

        // Valid JSON can still violate the presenter protocol. A missing
        // panel id must invalidate the pooled requester and cannot become
        // success.
        presenter.deinit();
        presenter = attachPanelPresenter(allocator, origin_sock, "panel-renamed");
        m.sendTool("ui_show", "{\"name\":\"missing-id\",\"document\":{\"root\":\"t\",\"components\":{\"t\":{\"type\":\"text\",\"text\":\"missing\"}}}}");
        const missing_call = recvPanelCall(allocator, &presenter, 15_000);
        replyPanel(&presenter, missing_call, "{\"ok\":true}");
        missing_call.deinit(allocator);
        const missing_result = m.recvLine(15_000);
        if (std.mem.indexOf(u8, missing_result, "isError") == null or
            std.mem.indexOf(u8, missing_result, "mutation may have applied") == null or
            std.mem.indexOf(u8, missing_result, "NOT resent automatically") == null or
            std.mem.indexOf(u8, missing_result, "\"showing\":true") != null)
            fail("missing panel_id presenter success was not rejected as uncertain delivery");

        // Zero is invalid for the same operation-specific field.
        presenter.deinit();
        presenter = attachPanelPresenter(allocator, origin_sock, "panel-renamed");
        m.sendTool("ui_show", "{\"name\":\"zero\",\"document\":{\"root\":\"t\",\"components\":{\"t\":{\"type\":\"text\",\"text\":\"zero\"}}}}");
        const zero_call = recvPanelCall(allocator, &presenter, 15_000);
        replyPanel(&presenter, zero_call, "{\"ok\":true,\"panel_id\":0}");
        zero_call.deinit(allocator);
        const zero_result = m.recvLine(15_000);
        if (std.mem.indexOf(u8, zero_result, "isError") == null or
            std.mem.indexOf(u8, zero_result, "mutation may have applied") == null or
            std.mem.indexOf(u8, zero_result, "NOT resent automatically") == null or
            std.mem.indexOf(u8, zero_result, "\"showing\":true") != null)
            fail("panel_id 0 presenter success was not rejected as uncertain delivery");

        // The invalid reply retired both daemon presenter and MCP pool entry;
        // a fresh presenter and fresh request must recover normally.
        presenter.deinit();
        presenter = attachPanelPresenter(allocator, origin_sock, "panel-renamed");
        m.sendTool("ui_show", "{\"name\":\"recovered\",\"document\":{\"root\":\"t\",\"components\":{\"t\":{\"type\":\"text\",\"text\":\"fresh-route\"}}}}");
        const recovered_call = recvPanelCall(allocator, &presenter, 15_000);
        if (std.mem.indexOf(u8, recovered_call.json, "fresh-route") == null)
            fail("pooled panel relay was not replaced after invalid presenter reply");
        replyPanel(&presenter, recovered_call, "{\"ok\":true,\"panel_id\":43}");
        recovered_call.deinit(allocator);
        const recovered = m.recvLine(15_000);
        if (std.mem.indexOf(u8, recovered, "\"panel_id\":43") == null)
            fail("fresh pooled panel relay did not recover");

        // A real long-lived app tool still starts the MCP private daemon, not
        // the panel origin. Inspect it while alive so a fast /bin/true cannot
        // make the isolation assertion pass after all state has disappeared.
        const app = m.callTool("launch_app", "{\"command\":[\"/bin/sh\",\"-c\",\"sleep 30\"],\"wait_for\":\"exit\",\"wait_ms\":100,\"stable_ms\":0}");
        // The app facts live in structuredContent now; the text lane
        // carries the same story as prose.
        if (std.mem.indexOf(u8, app, "\"structuredContent\":{") == null or
            std.mem.indexOf(u8, app, "\"app\":1") == null or
            std.mem.indexOf(u8, app, "\"pid\":") == null or
            std.mem.indexOf(u8, app, "\"exited\":false") == null)
            fail("long-lived private launch_app probe was not alive");
        if (std.mem.indexOf(u8, app, "app 1 (") == null)
            fail("launch_app text lane did not name the app session");
        const live_apps = m.callTool("list_apps", "{}");
        if (std.mem.indexOf(u8, live_apps, "\"app\":1") == null or
            std.mem.indexOf(u8, live_apps, "\"pid\":") == null or
            std.mem.indexOf(u8, live_apps, "\"count\":1") == null or
            std.mem.indexOf(u8, live_apps, "\"exited\":false") == null)
            fail("list_apps could not inspect the private app while alive");
        var private_buf: [512]u8 = undefined;
        const private_sock = std.fmt.bufPrint(&private_buf, "{s}/sketerm/mcp-tmp-{d}/mux.sock", .{ rt, m.pid }) catch unreachable;
        if (!fileExists(private_sock)) fail("app tool did not start the MCP private daemon");
        if (sessionCount(allocator, &owner) != 1)
            fail("app tool leaked its session onto the panel origin daemon");
        const closed_app = m.callTool("close_app", "{\"app\":1}");
        if (std.mem.indexOf(u8, closed_app, "isError") != null or
            std.mem.indexOf(u8, closed_app, "\"outcome\":\"acknowledged\"") == null)
            fail("long-lived private app cleanup failed");

        // Losing the GUI is reported honestly and nothing is delivered: with
        // no presenter binding to fall back on, an absent GUI is simply
        // `no_compatible_gui`, pre-delivery and resend-safe.
        presenter.deinit();
        presenter_live = false;
        _ = c.usleep(300_000);
        const no_viewer = m.callTool("ui_show", "{\"name\":\"none\",\"document\":{\"root\":\"t\",\"components\":{\"t\":{\"type\":\"text\",\"text\":\"x\"}}}}");
        if (std.mem.indexOf(u8, no_viewer, "isError") == null or
            std.mem.indexOf(u8, no_viewer, "no compatible GUI") == null or
            std.mem.indexOf(u8, no_viewer, "before presenter delivery") == null)
            fail("missing GUI was not reported honestly");
        // The store half must stay usable throughout.
        const absent_caps = m.callTool("capabilities", "{}");
        if (std.mem.indexOf(u8, absent_caps, "\"state\":\"no_compatible_gui\"") == null or
            std.mem.indexOf(u8, absent_caps, "\"panels\":false") == null or
            std.mem.indexOf(u8, absent_caps, "\"panels_store\":true") == null or
            std.mem.indexOf(u8, absent_caps, "\"scope\":\"origin\"") == null)
            fail("capabilities did not report the panel transport honestly after the GUI left");

        // Restarting the GUI is an ordinary thing to do. A NEW GUI process
        // must be picked up by the very next call, with no invalidate dance:
        // the daemon simply routes to whichever presenter is attached now.
        var restarted = attachPanelPresenter(allocator, origin_sock, "panel-renamed");
        m.sendTool("ui_show", "{\"name\":\"after-restart\",\"document\":{\"root\":\"t\",\"components\":{\"t\":{\"type\":\"text\",\"text\":\"rebound\"}}}}");
        const restart_call = recvPanelCall(allocator, &restarted, 15_000);
        if (std.mem.indexOf(u8, restart_call.json, "rebound") == null)
            fail("a restarted GUI never received the rebound panel request");
        replyPanel(&restarted, restart_call, "{\"ok\":true,\"panel_id\":51}");
        restart_call.deinit(allocator);
        const rebound = m.recvLine(15_000);
        if (std.mem.indexOf(u8, rebound, "\"panel_id\":51") == null)
            fail("the panel requester did not reach a restarted GUI");
        // Leave exactly one presenter for the stages below, which each attach
        // their own and rely on being the only compatible candidate.
        restarted.deinit();
        _ = c.usleep(300_000);

        // Presenter disconnect after receiving a mutation is a correlated
        // error, not a retry through another transport.
        var disconnecting = attachPanelPresenter(allocator, origin_sock, "panel-origin");
        m.sendTool("ui_patch", "{\"panel_id\":41,\"patch\":[{\"op\":\"title\",\"value\":\"once\"}]}");
        const disconnect_call = recvPanelCall(allocator, &disconnecting, 15_000);
        disconnect_call.deinit(allocator);
        disconnecting.deinit();
        const disconnected = m.recvLine(15_000);
        if (std.mem.indexOf(u8, disconnected, "isError") == null or
            std.mem.indexOf(u8, disconnected, "mutation may have applied") == null or
            std.mem.indexOf(u8, disconnected, "NOT resent automatically") == null)
            fail("viewer disconnect did not report post-delivery uncertainty");

        // A silent viewer hits the client deadline. The response must say
        // delivery was uncertain and that the mutating call was not resent.
        var silent = attachPanelPresenter(allocator, origin_sock, "panel-origin");
        m.sendTool("ui_show", "{\"name\":\"timeout\",\"document\":{\"root\":\"t\",\"components\":{\"t\":{\"type\":\"text\",\"text\":\"once\"}}}}");
        const silent_call = recvPanelCall(allocator, &silent, 15_000);
        silent_call.deinit(allocator);
        // Remote image hydration gives live panel calls a 40s budget; wait
        // beyond that here so this intentionally silent presenter reaches the
        // MCP deadline rather than the smoke harness's shorter read deadline.
        const timed_out = m.recvLine(45_000);
        if (std.mem.indexOf(u8, timed_out, "isError") == null or
            std.mem.indexOf(u8, timed_out, "NOT resent automatically") == null or
            std.mem.indexOf(u8, timed_out, "reply_timeout") == null)
            fail("viewer timeout did not report uncertain no-resend semantics");
        silent.deinit();
        _ = c.usleep(300_000);

        const no_viewer_caps = m.callTool("capabilities", "{}");
        if (std.mem.indexOf(u8, no_viewer_caps, "\"panels\":false") == null or
            std.mem.indexOf(u8, no_viewer_caps, "no_compatible_gui") == null)
            fail("capabilities hid the missing compatible GUI");

        m.closeStdinWait();
        owner.sendJson(.kill, .{ .name = "panel-renamed" }) catch fail("origin cleanup kill send");
        (owner.recvExpectFor(&.{.ok}, 5_000) catch fail("origin cleanup kill reply")).deinit(allocator);

        // Reusing the spawn name creates a different storage identity and
        // cannot inherit the previous lifetime's saved panel.
        owner.sendJson(.spawn, .{
            .name = "panel-origin",
            .argv = [_][]const u8{ "sleep", "60" },
            .rows = @as(u16, 24),
            .cols = @as(u16, 80),
        }) catch fail("reincarnated origin session spawn send");
        (owner.recvExpectFor(&.{.ok}, 5_000) catch fail("reincarnated origin session spawn reply")).deinit(allocator);
        var fenced_active: muxclient.FdCancel = .{};
        if (muxclient.connectPanelRequesterUntilExpected(
            allocator,
            origin_sock,
            "panel-origin",
            origin_id,
            nowMs() + 5_000,
            &fenced_active,
        )) |wrong_lifetime| {
            var unexpected = wrong_lifetime;
            unexpected.deinit();
            fail("old origin_id attached to a same-name reincarnation");
        } else |err| if (err != error.SessionOriginMismatch) {
            fail("same-name reincarnation origin fence failed unexpectedly");
        }
        var reincarnated = muxclient.connectPanelRequester(allocator, origin_sock, "panel-origin", 5_000) catch
            fail("could not attach to reincarnated origin session");
        defer reincarnated.deinit();
        const reincarnated_id = reincarnated.panelOriginId();
        if (reincarnated_id.len != 32 or std.mem.eql(u8, reincarnated_id, origin_id))
            fail("same-name reincarnation reused its panel origin_id");
        const reincarnated_scope = panelstore.Scope{ .origin = .{
            .daemon_origin = origin_sock,
            .origin_id = reincarnated_id,
        } };
        if (panelstore.existsScoped(allocator, reincarnated_scope, "relayed"))
            fail("same-name reincarnation inherited the prior lifetime's saved panel");
        owner.sendJson(.kill, .{ .name = "panel-origin" }) catch fail("reincarnated origin cleanup kill send");
        (owner.recvExpectFor(&.{.ok}, 5_000) catch fail("reincarnated origin cleanup kill reply")).deinit(allocator);
        say("smoke-mcp: isolated origin-session panel relay ok");
    }

    // ── Stage 7: exact missing and unsupported origin handling ─────
    {
        _ = c.setenv("SKETERM_SESSION", "missing-origin", 1);
        var missing_buf: [320]u8 = undefined;
        const missing = std.fmt.bufPrintZ(&missing_buf, "{s}/missing-origin.sock", .{rt}) catch return 1;
        _ = c.unlink(missing.ptr);
        _ = c.setenv("SKETERM_MUX_SOCKET", missing.ptr, 1);
        var m = Mcp.spawn(allocator, exe, &.{});
        m.initialize();
        const result = m.callTool("ui_show", "{\"name\":\"x\",\"document\":{\"root\":\"t\",\"components\":{\"t\":{\"type\":\"text\",\"text\":\"x\"}}}}");
        if (std.mem.indexOf(u8, result, "origin mux daemon") == null or
            std.mem.indexOf(u8, result, "not autostarted") == null or
            fileExists(missing))
            fail("missing exact origin was autostarted, redirected, or poorly reported");
        const caps = m.callTool("capabilities", "{}");
        if (std.mem.indexOf(u8, caps, "origin_unreachable") == null or
            std.mem.indexOf(u8, caps, "\"panels_store\":false") == null or
            std.mem.indexOf(u8, caps, "\"scope\":\"unavailable\"") == null or
            std.mem.indexOf(u8, caps, "refusing to downgrade") == null)
            fail("capabilities hid the missing origin daemon");
        const store_only = m.callTool("ui_save", "{\"name\":\"must-not-downgrade\",\"document\":{\"root\":\"t\",\"components\":{\"t\":{\"type\":\"text\",\"text\":\"x\"}}}}");
        if (std.mem.indexOf(u8, store_only, "isError") == null or
            std.mem.indexOf(u8, store_only, "refusing to downgrade") == null)
            fail("store-only exact missing origin silently selected reusable storage");
        m.closeStdinWait();
        _ = c.unsetenv("SKETERM_MUX_SOCKET");
        _ = c.unsetenv("SKETERM_SESSION");
    }

    {
        var legacy_buf: [320]u8 = undefined;
        const legacy_sock = std.fmt.bufPrintZ(&legacy_buf, "{s}/legacy-mux.sock", .{rt}) catch return 1;
        var legacy = FakeLegacyMux.listen(legacy_sock);
        defer legacy.deinit();
        _ = c.setenv("SKETERM_SESSION", "legacy", 1);
        _ = c.setenv("SKETERM_MUX_SOCKET", legacy_sock.ptr, 1);
        defer _ = c.unsetenv("SKETERM_SESSION");
        defer _ = c.unsetenv("SKETERM_MUX_SOCKET");

        // No direct GUI: unsupported stays an honest failure.
        var old = Mcp.spawn(allocator, exe, &.{});
        old.initialize();
        old.sendTool("ui_show", "{\"name\":\"old\",\"document\":{\"root\":\"t\",\"components\":{\"t\":{\"type\":\"text\",\"text\":\"old\"}}}}");
        legacy.serveProbe(15_000);
        const unsupported = old.recvLine(15_000);
        if (std.mem.indexOf(u8, unsupported, "does not support panel relay") == null)
            fail("unsupported origin daemon was not reported");
        old.sendTool("ui_save", "{\"name\":\"old-daemon-scope\",\"document\":{\"root\":\"t\",\"components\":{\"t\":{\"type\":\"text\",\"text\":\"old\"}}}}");
        legacy.serveProbe(15_000);
        const legacy_saved = old.recvLine(15_000);
        if (std.mem.indexOf(u8, legacy_saved, "isError") != null)
            fail("positively identified pre-ID daemon did not receive disjoint legacy-origin storage");
        old.sendTool("ui_delete", "{\"name\":\"old-daemon-scope\"}");
        legacy.serveProbe(15_000);
        const legacy_deleted = old.recvLine(15_000);
        if (std.mem.indexOf(u8, legacy_deleted, "isError") != null)
            fail("positively identified pre-ID daemon legacy-origin cleanup failed");
        old.closeStdinWait();

        // Exact origin is still tried first, but an unsupported capability is
        // proven pre-delivery. Only the explicitly named GUI may then serve as
        // the requested legacy fallback.
        var gui_buf: [320]u8 = undefined;
        const gui_sock = std.fmt.bufPrintZ(&gui_buf, "{s}/legacy-gui.sock", .{rt}) catch return 1;
        var gui = FakeGui.listen(gui_sock);
        defer gui.deinit();
        var exact = Mcp.spawn(allocator, exe, &.{ "--socket", gui_sock });
        exact.initialize();
        exact.sendTool("ui_show", "{\"name\":\"legacy\",\"document\":{\"root\":\"t\",\"components\":{\"t\":{\"type\":\"text\",\"text\":\"exact\"}}}}");
        legacy.serveProbe(15_000);
        const fallback_sent = gui.serveOne("{\"ok\":true,\"panel_id\":76}", 15_000);
        const exact_result = exact.recvLine(15_000);
        if (std.mem.indexOf(u8, fallback_sent, "\"cmd\":\"panel-show\"") == null or
            std.mem.indexOf(u8, fallback_sent, "\"session\":\"legacy\"") == null or
            std.mem.indexOf(u8, exact_result, "\"panel_id\":76") == null or
            std.mem.indexOf(u8, exact_result, "isError") != null)
            fail("unsupported exact origin did not recover through the explicit direct GUI socket");
        exact.closeStdinWait();

        // Without an exact environment socket, explicit GUI control wins
        // before the canonical-default compatibility probe.
        _ = c.unsetenv("SKETERM_MUX_SOCKET");
        var direct = Mcp.spawn(allocator, exe, &.{ "--socket", gui_sock });
        direct.initialize();
        direct.sendTool("capabilities", "{}");
        const cap_sent = gui.serveOne("{\"ok\":true,\"panels\":[]}", 15_000);
        if (std.mem.indexOf(u8, cap_sent, "\"cmd\":\"panel-list\"") == null)
            fail("explicit GUI capability probe did not use direct IPC");
        const direct_caps = direct.recvLine(15_000);
        if (std.mem.indexOf(u8, direct_caps, "gui_socket_explicit") == null)
            fail("capabilities hid the explicit GUI transport source");
        direct.sendTool("ui_show", "{\"name\":\"legacy\",\"document\":{\"root\":\"t\",\"components\":{\"t\":{\"type\":\"text\",\"text\":\"direct\"}}}}");
        const sent = gui.serveOne("{\"ok\":true,\"panel_id\":77}", 15_000);
        if (std.mem.indexOf(u8, sent, "\"cmd\":\"panel-show\"") == null)
            fail("explicit direct socket did not receive panel-show");
        const result = direct.recvLine(15_000);
        if (std.mem.indexOf(u8, result, "\"panel_id\":77") == null or std.mem.indexOf(u8, result, "isError") != null) {
            std.debug.print("smoke-mcp: explicit direct result: {s}\n", .{result});
            fail("explicit direct transport did not return its result");
        }
        direct.closeStdinWait();
        say("smoke-mcp: missing/unsupported exact origin + explicit precedence ok");
    }

    // A current daemon can still have only pre-panel_rpc GUI viewers.
    // That is a proven pre-delivery incompatibility, so an explicitly named
    // direct GUI socket is the one permitted mixed-version fallback.
    {
        var mixed_dir_buf: [320]u8 = undefined;
        const mixed_dir = std.fmt.bufPrintZ(&mixed_dir_buf, "{s}/panel-mixed", .{rt}) catch return 1;
        _ = c.mkdir(mixed_dir.ptr, 0o700);
        var mixed_sock_buf: [360]u8 = undefined;
        const mixed_sock = std.fmt.bufPrintZ(&mixed_sock_buf, "{s}/mux.sock", .{mixed_dir}) catch return 1;
        var owner = muxclient.Conn.connectLocalAutostartAt(allocator, mixed_sock) catch
            fail("could not start mixed-version mux daemon");
        defer owner.deinit();
        owner.setNonBlocking();
        owner.sendJson(.spawn, .{
            .name = "mixed-version",
            .argv = [_][]const u8{ "sleep", "60" },
            .rows = @as(u16, 24),
            .cols = @as(u16, 80),
        }) catch fail("mixed-version session spawn send");
        (owner.recvExpectFor(&.{.ok}, 5_000) catch fail("mixed-version session spawn reply")).deinit(allocator);
        var legacy_viewer = attachLegacyPanelViewer(allocator, mixed_sock, "mixed-version");

        var gui_buf: [320]u8 = undefined;
        const gui_sock = std.fmt.bufPrintZ(&gui_buf, "{s}/mixed-version-gui.sock", .{rt}) catch return 1;
        var gui = FakeGui.listen(gui_sock);
        defer gui.deinit();
        _ = c.setenv("SKETERM_SESSION", "mixed-version", 1);
        _ = c.setenv("SKETERM_MUX_SOCKET", mixed_sock.ptr, 1);
        defer _ = c.unsetenv("SKETERM_SESSION");
        defer _ = c.unsetenv("SKETERM_MUX_SOCKET");

        var m = Mcp.spawn(allocator, exe, &.{ "--socket", gui_sock });
        m.initialize();
        m.sendTool("ui_show", "{\"name\":\"mixed\",\"document\":{\"root\":\"t\",\"components\":{\"t\":{\"type\":\"text\",\"text\":\"mixed fallback\"}}}}");
        const sent = gui.serveOne("{\"ok\":true,\"panel_id\":78}", 15_000);
        const result = m.recvLine(15_000);
        if (std.mem.indexOf(u8, sent, "\"cmd\":\"panel-show\"") == null or
            std.mem.indexOf(u8, sent, "\"session\":\"mixed-version\"") == null or
            std.mem.indexOf(u8, result, "\"panel_id\":78") == null or
            std.mem.indexOf(u8, result, "isError") != null)
            fail("current daemon with only a legacy GUI did not use explicit direct fallback");
        expectNoPanelCall(&legacy_viewer, 250);
        m.closeStdinWait();
        legacy_viewer.deinit();
        owner.sendJson(.kill, .{ .name = "mixed-version" }) catch fail("mixed-version cleanup send");
        (owner.recvExpectFor(&.{.ok}, 5_000) catch fail("mixed-version cleanup reply")).deinit(allocator);
        say("smoke-mcp: current daemon + legacy GUI explicit fallback ok");
    }

    // ── Stage 8: exact/default/discovered transport collision ─────
    {
        _ = c.unsetenv("SKETERM_MUX_SOCKET");
        _ = c.setenv("SKETERM_SESSION", "panel-collision", 1);
        defer _ = c.unsetenv("SKETERM_SESSION");

        // Two real daemons deliberately own the same session name. One is the
        // canonical default; the other is the exact inherited origin.
        var default_owner = muxclient.Conn.connectLocalAutostart(allocator) catch fail("default mux start");
        defer default_owner.deinit();
        default_owner.setNonBlocking();
        default_owner.sendJson(.spawn, .{
            .name = "panel-collision",
            .argv = [_][]const u8{ "sleep", "60" },
            .rows = @as(u16, 24),
            .cols = @as(u16, 80),
        }) catch fail("default collision session spawn");
        (default_owner.recvExpectFor(&.{.ok}, 5_000) catch fail("default collision spawn reply")).deinit(allocator);
        var default_sock_buf: [320]u8 = undefined;
        const default_sock = std.fmt.bufPrint(&default_sock_buf, "{s}/sketerm/mux.sock", .{rt}) catch unreachable;
        var default_presenter = attachPanelPresenter(allocator, default_sock, "panel-collision");
        defer default_presenter.deinit();
        var default_identity = muxclient.connectPanelRequester(allocator, default_sock, "panel-collision", 5_000) catch
            fail("default collision identity attach");
        defer default_identity.deinit();

        var exact_dir_buf: [320]u8 = undefined;
        const exact_dir = std.fmt.bufPrintZ(&exact_dir_buf, "{s}/panel-exact", .{rt}) catch return 1;
        _ = c.mkdir(exact_dir.ptr, 0o700);
        var exact_sock_buf: [360]u8 = undefined;
        const exact_sock = std.fmt.bufPrintZ(&exact_sock_buf, "{s}/mux.sock", .{exact_dir}) catch return 1;
        var exact_owner = muxclient.Conn.connectLocalAutostartAt(allocator, exact_sock) catch fail("exact mux start");
        defer exact_owner.deinit();
        exact_owner.setNonBlocking();
        exact_owner.sendJson(.spawn, .{
            .name = "panel-collision",
            .argv = [_][]const u8{ "sleep", "60" },
            .rows = @as(u16, 24),
            .cols = @as(u16, 80),
        }) catch fail("exact collision session spawn");
        (exact_owner.recvExpectFor(&.{.ok}, 5_000) catch fail("exact collision spawn reply")).deinit(allocator);
        var exact_presenter = attachPanelPresenter(allocator, exact_sock, "panel-collision");
        defer exact_presenter.deinit();
        var exact_identity = muxclient.connectPanelRequester(allocator, exact_sock, "panel-collision", 5_000) catch
            fail("exact collision identity attach");
        defer exact_identity.deinit();

        _ = c.setenv("SKETERM_MUX_SOCKET", exact_sock.ptr, 1);
        var exact_mcp = Mcp.spawn(allocator, exe, &.{});
        exact_mcp.initialize();
        exact_mcp.sendTool("ui_show", "{\"name\":\"exact\",\"document\":{\"root\":\"t\",\"components\":{\"t\":{\"type\":\"text\",\"text\":\"exact-daemon\"}}}}");
        const exact_call = recvPanelCall(allocator, &exact_presenter, 15_000);
        if (std.mem.indexOf(u8, exact_call.json, "exact-daemon") == null) fail("exact daemon received wrong panel JSON");
        replyPanel(&exact_presenter, exact_call, "{\"ok\":true,\"panel_id\":81}");
        exact_call.deinit(allocator);
        const exact_reply = exact_mcp.recvLine(15_000);
        if (std.mem.indexOf(u8, exact_reply, "\"panel_id\":81") == null)
            fail("exact same-name daemon did not answer the panel call");
        const exact_saved = exact_mcp.callTool("ui_save", "{\"name\":\"same-name\",\"document\":{\"title\":\"Exact origin\",\"root\":\"t\",\"components\":{\"t\":{\"type\":\"text\",\"text\":\"exact\"}}}}");
        if (std.mem.indexOf(u8, exact_saved, "isError") != null)
            fail("exact daemon origin save failed");
        expectNoPanelCall(&default_presenter, 250);
        exact_mcp.sendTool("capabilities", "{}");
        const exact_cap_call = recvPanelCall(allocator, &exact_presenter, 15_000);
        replyPanel(&exact_presenter, exact_cap_call, "{\"ok\":true,\"panels\":[]}");
        exact_cap_call.deinit(allocator);
        const exact_caps = exact_mcp.recvLine(15_000);
        if (std.mem.indexOf(u8, exact_caps, "SKETERM_MUX_SOCKET") == null)
            fail("capabilities hid exact-origin source in a same-name collision");
        exact_mcp.closeStdinWait();

        // No exact socket and no explicit GUI: connect-only canonical default
        // compatibility is safe and succeeds without autostarting anything.
        _ = c.unsetenv("SKETERM_MUX_SOCKET");
        var compat = Mcp.spawn(allocator, exe, &.{});
        compat.initialize();
        compat.sendTool("capabilities", "{}");
        const compat_cap_call = recvPanelCall(allocator, &default_presenter, 15_000);
        replyPanel(&default_presenter, compat_cap_call, "{\"ok\":true,\"panels\":[]}");
        compat_cap_call.deinit(allocator);
        const compat_caps = compat.recvLine(15_000);
        if (std.mem.indexOf(u8, compat_caps, "default_socket_connect_only") == null)
            fail("capabilities hid canonical-default compatibility source");
        compat.sendTool("ui_show", "{\"name\":\"default\",\"document\":{\"root\":\"t\",\"components\":{\"t\":{\"type\":\"text\",\"text\":\"default-daemon\"}}}}");
        const default_call = recvPanelCall(allocator, &default_presenter, 15_000);
        replyPanel(&default_presenter, default_call, "{\"ok\":true,\"panel_id\":82}");
        default_call.deinit(allocator);
        const default_reply = compat.recvLine(15_000);
        if (std.mem.indexOf(u8, default_reply, "\"panel_id\":82") == null)
            fail("canonical-default panel relay failed");
        const default_saved = compat.callTool("ui_save", "{\"name\":\"same-name\",\"document\":{\"title\":\"Default origin\",\"root\":\"t\",\"components\":{\"t\":{\"type\":\"text\",\"text\":\"default\"}}}}");
        if (std.mem.indexOf(u8, default_saved, "isError") != null)
            fail("default daemon origin save failed");
        compat.closeStdinWait();

        // Identical `(session,name)` values on two exact daemons are distinct
        // persistence scopes and cannot read or overwrite one another.
        const exact_scope = panelstore.Scope{ .origin = .{
            .daemon_origin = exact_sock,
            .origin_id = exact_identity.panelOriginId(),
        } };
        const default_scope = panelstore.Scope{ .origin = .{
            .daemon_origin = default_sock,
            .origin_id = default_identity.panelOriginId(),
        } };
        var exact_doc = panelstore.loadScoped(allocator, exact_scope, "same-name", null) catch
            fail("exact origin saved panel could not be loaded");
        defer exact_doc.deinit();
        var default_doc = panelstore.loadScoped(allocator, default_scope, "same-name", null) catch
            fail("default origin saved panel could not be loaded");
        defer default_doc.deinit();
        if (!std.mem.eql(u8, exact_doc.title, "Exact origin") or
            !std.mem.eql(u8, default_doc.title, "Default origin"))
            fail("same session/name persistence collided across daemon origins");

        // Shared-mode discovery yields a GUI socket for terminal tools, but a
        // sessionful panel still uses the canonical daemon and cannot mutate a
        // same-named session in whichever GUI happened to be discovered.
        var discovered_buf: [360]u8 = undefined;
        const discovered_sock = std.fmt.bufPrintZ(&discovered_buf, "{s}/sketerm/77777.sock", .{rt}) catch return 1;
        var discovered_gui = FakeGui.listen(discovered_sock);
        defer discovered_gui.deinit();
        var discovered = Mcp.spawn(allocator, exe, &.{"--shared"});
        discovered_gui.acceptDiscoveryProbe(5_000);
        discovered.initialize();
        discovered.sendTool("capabilities", "{}");
        const discovered_cap_call = recvPanelCall(allocator, &default_presenter, 15_000);
        replyPanel(&default_presenter, discovered_cap_call, "{\"ok\":true,\"panels\":[]}");
        discovered_cap_call.deinit(allocator);
        const discovered_caps = discovered.recvLine(15_000);
        if (std.mem.indexOf(u8, discovered_caps, "default_socket_connect_only") == null or
            std.mem.indexOf(u8, discovered_caps, "\"gui_socket_source\":\"discovered\"") == null)
            fail("capabilities confused discovered GUI and default panel transports");
        discovered.sendTool("ui_show", "{\"name\":\"discovered\",\"document\":{\"root\":\"t\",\"components\":{\"t\":{\"type\":\"text\",\"text\":\"must-use-default\"}}}}");
        const discovered_show = recvPanelCall(allocator, &default_presenter, 15_000);
        if (std.mem.indexOf(u8, discovered_show.json, "must-use-default") == null)
            fail("discovered GUI displaced the canonical panel relay");
        replyPanel(&default_presenter, discovered_show, "{\"ok\":true,\"panel_id\":83}");
        discovered_show.deinit(allocator);
        const discovered_show_reply = discovered.recvLine(15_000);
        if (std.mem.indexOf(u8, discovered_show_reply, "\"panel_id\":83") == null)
            fail("session mutation did not complete through canonical panel relay");
        discovered_gui.expectNoConnection(250);
        discovered.closeStdinWait();

        // An explicitly requested GUI socket has higher precedence than the
        // default compatibility daemon when no exact environment origin is
        // present, and capabilities names that decision.
        var explicit = Mcp.spawn(allocator, exe, &.{ "--socket", discovered_sock });
        explicit.initialize();
        explicit.sendTool("capabilities", "{}");
        const explicit_cap_call = discovered_gui.serveOne("{\"ok\":true,\"panels\":[]}", 15_000);
        if (std.mem.indexOf(u8, explicit_cap_call, "\"cmd\":\"panel-list\"") == null)
            fail("explicit GUI did not receive capability panel-list");
        const explicit_caps = explicit.recvLine(15_000);
        if (std.mem.indexOf(u8, explicit_caps, "gui_socket_explicit") == null)
            fail("capabilities did not name explicit GUI precedence");
        expectNoPanelCall(&default_presenter, 250);
        explicit.closeStdinWait();

        exact_owner.sendJson(.kill, .{ .name = "panel-collision" }) catch fail("exact collision cleanup send");
        (exact_owner.recvExpectFor(&.{.ok}, 5_000) catch fail("exact collision cleanup reply")).deinit(allocator);
        default_owner.sendJson(.kill, .{ .name = "panel-collision" }) catch fail("default collision cleanup send");
        (default_owner.recvExpectFor(&.{.ok}, 5_000) catch fail("default collision cleanup reply")).deinit(allocator);
        say("smoke-mcp: exact/default/discovered collision precedence ok");
    }

    // ── Stage 9: ui_show_files, against a stand-in GUI socket ─────
    // ui_show_files is a document GENERATOR over ui_show's path, so the
    // load-bearing assertion is what it SENDS: a stand-in socket
    // answers panel-show and the stage reads the document off the wire.
    {
        _ = c.setenv("SKETERM_MCP_TOOLS", "ui", 1);
        defer _ = c.unsetenv("SKETERM_MCP_TOOLS");
        var sock_buf: [320]u8 = undefined;
        const sock = std.fmt.bufPrintZ(&sock_buf, "{s}/gui.sock", .{rt}) catch return 1;
        var gui = FakeGui.listen(sock);
        defer gui.deinit();
        // Two real files; a third path deliberately never exists.
        for ([_][]const u8{ "e40.png", "e41.png" }) |nm| {
            var f_buf: [320]u8 = undefined;
            const p = std.fmt.bufPrintZ(&f_buf, "{s}/{s}", .{ rt, nm }) catch return 1;
            const f = c.fopen(p.ptr, "wb") orelse fail("cannot create smoke image file");
            _ = c.fwrite("x", 1, 1, f);
            _ = c.fclose(f);
        }

        var m = Mcp.spawn(allocator, exe, &.{ "--socket", sock });
        m.initialize();
        const listed = m.listTools();
        if (std.mem.indexOf(u8, listed, "\"ui_show_files\"") == null)
            fail("tools/list dropped ui_show_files under --tools ui");

        // compare:true + exactly two files: ONE image_compare, the
        // captions as its side labels, over the same panel-show ui_show
        // uses, under the default panel name.
        var args_buf: [1024]u8 = undefined;
        const cmp_args = std.fmt.bufPrint(&args_buf, "{{\"session\":\"vsr\",\"title\":\"E41 vs E40\",\"compare\":true,\"files\":[{{\"path\":\"{s}/e40.png\",\"caption\":\"epoch 40\"}},{{\"path\":\"{s}/e41.png\",\"caption\":\"epoch 41\"}}]}}", .{ rt, rt }) catch unreachable;
        m.sendTool("ui_show_files", cmp_args);
        const sent = gui.serveOne("{\"ok\":true,\"panel_id\":4}", 15_000);
        if (std.mem.indexOf(u8, sent, "\"cmd\":\"panel-show\"") == null or
            std.mem.indexOf(u8, sent, "\"name\":\"files\"") == null or
            std.mem.indexOf(u8, sent, "\"session\":\"vsr\"") == null or
            std.mem.indexOf(u8, sent, "image_compare") == null or
            std.mem.indexOf(u8, sent, "epoch 40") == null or
            std.mem.indexOf(u8, sent, "epoch 41") == null)
            fail("ui_show_files did not send an image_compare document over panel-show");
        const cmp_reply = m.recvLine(15_000);
        if (std.mem.indexOf(u8, cmp_reply, "isError") != null or
            std.mem.indexOf(u8, cmp_reply, "\"panel_id\":4") == null or
            std.mem.indexOf(u8, cmp_reply, "image_compare") == null)
            fail("ui_show_files did not report the shown compare panel");

        // Stacked, with one unreadable path: still shown (the renderer
        // draws a placeholder), and the reply NAMES the file.
        const stack_args = std.fmt.bufPrint(&args_buf, "{{\"session\":\"vsr\",\"name\":\"epoch42\",\"files\":[\"{s}/e40.png\",\"{s}/ghost.png\"]}}", .{ rt, rt }) catch unreachable;
        m.sendTool("ui_show_files", stack_args);
        const sent2 = gui.serveOne("{\"ok\":true,\"panel_id\":5}", 15_000);
        if (std.mem.indexOf(u8, sent2, "\"name\":\"epoch42\"") == null or
            std.mem.indexOf(u8, sent2, "image_compare") != null or
            std.mem.indexOf(u8, sent2, "e40.png") == null or
            std.mem.indexOf(u8, sent2, "ghost.png") == null)
            fail("ui_show_files did not stack the images it was given");
        const stack_reply = m.recvLine(15_000);
        if (std.mem.indexOf(u8, stack_reply, "stacked_images") == null or
            std.mem.indexOf(u8, stack_reply, "unreadable") == null or
            std.mem.indexOf(u8, stack_reply, "ghost.png") == null)
            fail("ui_show_files hid an unreadable file instead of naming it");

        // Bad arity: refused clearly, and NOTHING is shown (the fake GUI
        // would still be waiting — the next served call proves it).
        const arity = m.callTool("ui_show_files", std.fmt.bufPrint(&args_buf, "{{\"compare\":true,\"files\":[\"{s}/e40.png\",\"{s}/e41.png\",\"{s}/e40.png\"]}}", .{ rt, rt, rt }) catch unreachable);
        if (std.mem.indexOf(u8, arity, "isError") == null or
            std.mem.indexOf(u8, arity, "exactly two") == null)
            fail("compare:true with three files was not refused clearly");

        // Nothing readable at all: refused rather than shown as a wall
        // of placeholders.
        const gone = m.callTool("ui_show_files", std.fmt.bufPrint(&args_buf, "{{\"files\":[\"{s}/ghost1.png\",\"{s}/ghost2.png\"]}}", .{ rt, rt }) catch unreachable);
        if (std.mem.indexOf(u8, gone, "isError") == null or
            std.mem.indexOf(u8, gone, "none of the 2 file(s) can be read") == null)
            fail("an all-unreadable file set was not refused");

        // A relative path is refused too (documents are persisted).
        const rel = m.callTool("ui_show_files", "{\"files\":[\"rel.png\"]}");
        if (std.mem.indexOf(u8, rel, "isError") == null or
            std.mem.indexOf(u8, rel, "ABSOLUTE") == null)
            fail("a relative image path was not refused");

        // The generic tool still works on the same socket: the refusals
        // above did not leave the connection or the server wedged.
        m.sendTool("ui_show", "{\"name\":\"plain\",\"session\":\"vsr\",\"document\":{\"root\":\"t\",\"components\":{\"t\":{\"type\":\"text\",\"text\":\"hi\"}}}}");
        const sent3 = gui.serveOne("{\"ok\":true,\"panel_id\":6}", 15_000);
        if (std.mem.indexOf(u8, sent3, "\"name\":\"plain\"") == null)
            fail("ui_show stopped working after ui_show_files refusals");
        _ = m.recvLine(15_000);

        // Exactly 1 MiB remains the document parser boundary, while the
        // direct control request is larger because the document becomes an
        // escaped JSON string. Exercise the real Unix socket, not just codecs.
        const doc_prefix = "{\"root\":\"t\",\"components\":{\"t\":{\"type\":\"text\",\"text\":\"ok\"}},\"padding\":\"";
        const doc_suffix = "\"}";
        const max_doc = allocator.alloc(u8, 1 << 20) catch fail("maximum direct document allocation");
        defer allocator.free(max_doc);
        @memcpy(max_doc[0..doc_prefix.len], doc_prefix);
        const max_body = max_doc[doc_prefix.len .. max_doc.len - doc_suffix.len];
        var max_i: usize = 0;
        while (max_i + 1 < max_body.len) : (max_i += 2) {
            max_body[max_i] = '\\';
            max_body[max_i + 1] = '"';
        }
        if (max_i < max_body.len) max_body[max_i] = 'x';
        @memcpy(max_doc[max_doc.len - doc_suffix.len ..], doc_suffix);
        const max_args = std.fmt.allocPrint(allocator, "{{\"name\":\"max-boundary\",\"session\":\"vsr\",\"document\":{s}}}", .{max_doc}) catch
            fail("maximum direct arguments allocation");
        defer allocator.free(max_args);
        m.sendToolAllocated("ui_show", max_args);
        const max_sent = gui.serveOne("{\"ok\":true,\"panel_id\":7}", 30_000);
        if (max_sent.len <= (1 << 20) or max_sent.len > protocol.MAX_LINE)
            fail("maximum direct request did not cross the expanded bounded transport");
        var max_parsed = protocol.parseRequest(allocator, std.mem.trimEnd(u8, max_sent, "\n")) catch
            fail("maximum direct GUI request did not parse");
        defer max_parsed.deinit();
        if (max_parsed.value.document == null or max_parsed.value.document.?.len != max_doc.len or
            !std.mem.eql(u8, max_parsed.value.document.?, max_doc))
            fail("maximum direct panel document changed across GUI IPC");
        const max_result = m.recvLine(30_000);
        if (std.mem.indexOf(u8, max_result, "\"panel_id\":7") == null or
            std.mem.indexOf(u8, max_result, "isError") != null)
            fail("maximum direct panel request did not complete");

        m.closeStdinWait();
        say("smoke-mcp: ui_show_files ok");
    }

    // The four client-spawn-lane stages below assert what THAT lane
    // provides (the watchable Wayland session above all), so they pin
    // the escape hatch rather than the default broker lane — which the
    // shared-profile and engine-lifecycle stages cover.
    _ = c.setenv("SKETERM_WEB_BROKER_ENGINE", "0", 1);

    // ── watchable web session plumbing (no CEF needed) ─────────────
    webSessionFakeStage(allocator, exe, rt);
    say("smoke-mcp: watchable web session plumbing ok");

    // ── headless browsing profiles (no CEF needed) ─────────────────
    webProfileFakeStage(allocator, exe, rt);
    say("smoke-mcp: headless browsing profiles (fake helper) ok");

    // ── enforced network policy (no CEF needed) ────────────────────
    webPolicyFakeStage(allocator, exe, rt);
    say("smoke-mcp: enforced network policy (fake helper) ok");

    // -- the web_gui grant: the user's OWN browser for web_* only --
    webGuiGrantStage(allocator, exe, rt);
    say("smoke-mcp: web_gui grant (discover, spawn, fail closed) ok");

    // -- scp/port forwards through the real ssh tool paths ------------
    sshToolsStage(allocator, exe, rt);
    say("smoke-mcp: scp_get/scp_put and port_forward_* over a fake ssh ok");

    // -- sub-agents: agent_* against a fake Claude Code and opencode ----
    agentStage(allocator, exe, rt);
    say("smoke-mcp: agent_* tools against fake Claude Code and opencode ok");
    agentSshStage(allocator, exe, rt);
    say("smoke-mcp: agent_* tools on an SSH host (both transports) ok");

    // -- app_* against a real GTK app on the private headless display --
    appToolsStage(allocator, exe, rt);
    say("smoke-mcp: app_* tools against a real windowed app ok");

    // ── web_* headless: isolated mode, NO GUI, no --shared ─────────
    //
    // The regression this guards: the web tools once hard-failed with
    // "no GUI control socket ... restart with --shared" in the DEFAULT
    // mode — the mode assistants actually run in. They must work
    // against the MCP server's own sketerm-webengine instead. Gated on
    // the helper being built (CEF is optional): a clean SKIP, never a
    // silent pass.
    {
        var bin_buf: [4096:0]u8 = undefined;
        const web_bin = resolveWebBin(&bin_buf);
        if (web_bin == null) {
            say("smoke-mcp: SKIP web stage (sketerm-webengine not built; `zig build web`)");
        } else {
            _ = c.setenv("SKETERM_WEB_BIN", web_bin.?, 1);
            defer _ = c.unsetenv("SKETERM_WEB_BIN");
            webStartupStage(allocator, exe);
            webStage(allocator, exe, rt);
            say("smoke-mcp: headless web tools ok");
            webPolicyStage(allocator, exe, rt);
            say("smoke-mcp: enforced network policy (real CEF) ok");
            webCaptureStage(allocator, exe, rt);
            say("smoke-mcp: response-body capture (real CEF) ok");
            webTabsStage(allocator, exe, rt);
            say("smoke-mcp: shared-browser tab targeting (real CEF) ok");
            _ = c.unsetenv("SKETERM_WEB_BROKER_ENGINE");
            webSharedProfileStage(allocator, exe, rt);
            say("smoke-mcp: broker-owned shared profiles (real CEF) ok");
            webEngineLifecycleStage(allocator, exe, rt);
            say("smoke-mcp: broker-owned engine lifecycle (real CEF) ok");
            webPresenterStage(allocator, exe, rt);
            say("smoke-mcp: watch-along presenter (real CEF) ok");
        }
    }

    // Retire the durable daemon we started, then the dir: a passing run
    // leaves nothing in /tmp (a failing one keeps it, see `fail`).
    killDaemonsUnderRt(rt, allocator);
    _ = c.usleep(500_000);
    g_rt = null;
    pathz.removeTree(rt);

    say("smoke-mcp: PASS");
    return 0;
}

// -- the web_gui grant ------------------------------------------------

/// Env that turns this binary, run as `<bin> web`, into a fake GUI
/// control socket under the named runtime dir.
const FAKE_GUI_ENV = "SKETERM_SMOKE_FAKE_GUI";

/// A stand-in `sketerm web`: binds `<rt>/sketerm/<pid>.sock` (exactly
/// where a GUI publishes its control socket), records its pid and
/// every request line it answers, and serves `web-list`/`web-open`
/// for a while. It also writes to ITS stdout at start and notes
/// whether the daemon idle-exit hint reached it, so the stage can
/// prove the spawn neither inherited the MCP's JSON-RPC stream nor
/// leaked the private-daemon setting toward the user's real one.
fn fakeGui(rt: []const u8) u8 {
    _ = c.write(1, "FAKE-GUI-STDOUT-LEAK\n", 21);
    var dir_buf: [300]u8 = undefined;
    const dir = std.fmt.bufPrintZ(&dir_buf, "{s}/sketerm", .{rt}) catch return 1;
    _ = c.mkdir(dir.ptr, 0o700);
    var sock_buf: [340]u8 = undefined;
    const sock = std.fmt.bufPrintZ(&sock_buf, "{s}/{d}.sock", .{ dir, c.getpid() }) catch return 1;
    var log_buf: [340]u8 = undefined;
    const log_path = std.fmt.bufPrintZ(&log_buf, "{s}/fakegui-{d}.log", .{ rt, c.getpid() }) catch return 1;
    const log = c.fopen(log_path.ptr, "w") orelse return 1;
    defer _ = c.fclose(log);
    {
        var line: [200]u8 = undefined;
        const s = std.fmt.bufPrint(&line, "idle_exit={s}\n", .{if (c.getenv(muxclient.Conn.IDLE_EXIT_ENV)) |v| std.mem.span(@as([*:0]const u8, v)) else "<absent>"}) catch return 1;
        _ = c.fwrite(s.ptr, 1, s.len, log);
        _ = c.fflush(log);
    }
    var pids_buf: [340]u8 = undefined;
    const pids_path = std.fmt.bufPrintZ(&pids_buf, "{s}/fakegui.pids", .{rt}) catch return 1;
    if (c.fopen(pids_path.ptr, "a")) |pf| {
        var line: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&line, "{d}\n", .{c.getpid()}) catch return 1;
        _ = c.fwrite(s.ptr, 1, s.len, pf);
        _ = c.fclose(pf);
    }

    var addr = std.mem.zeroes(c.struct_sockaddr_un);
    if (sock.len + 1 > addr.sun_path.len) return 1;
    addr.sun_family = c.AF_UNIX;
    @memcpy(addr.sun_path[0..sock.len], sock);
    const lfd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (lfd < 0) return 1;
    if (c.bind(lfd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0) return 1;
    if (c.listen(lfd, 8) != 0) return 1;
    defer _ = c.unlink(sock.ptr);

    var next_pane: u32 = 41;
    var open_urls: [8][512]u8 = undefined;
    var open_lens: [8]usize = @splat(0);
    var open_n: usize = 0;
    const deadline = nowMs() + 90_000;
    while (nowMs() < deadline) {
        var pfd = c.struct_pollfd{ .fd = lfd, .events = c.POLLIN, .revents = 0 };
        if (c.poll(&pfd, 1, 200) <= 0) continue;
        const fd = c.accept(lfd, null, null);
        if (fd < 0) continue;
        defer _ = c.close(fd);
        var req: [8192]u8 = undefined;
        var req_len: usize = 0;
        const line_deadline = nowMs() + 2_000;
        while (std.mem.indexOfScalar(u8, req[0..req_len], '\n') == null and nowMs() < line_deadline) {
            var cp = c.struct_pollfd{ .fd = fd, .events = c.POLLIN, .revents = 0 };
            if (c.poll(&cp, 1, 100) <= 0) continue;
            const n = c.read(fd, req[req_len..].ptr, req.len - req_len);
            if (n <= 0) break;
            req_len += @intCast(n);
        }
        // A liveness probe connects and sends nothing: not a request.
        if (req_len == 0) continue;
        const line = req[0..req_len];
        _ = c.fwrite(line.ptr, 1, line.len, log);
        if (line[line.len - 1] != '\n') _ = c.fwrite("\n", 1, 1, log);
        _ = c.fflush(log);
        var out: [8192]u8 = undefined;
        var w = std.Io.Writer.fixed(&out);
        if (std.mem.indexOf(u8, line, "\"cmd\":\"web-list\"") != null) {
            w.writeAll("{\"ok\":true,\"helper\":\"ready\",\"views\":[") catch return 1;
            for (0..open_n) |i| {
                if (i > 0) w.writeAll(",") catch return 1;
                w.print("{{\"pane\":{d},\"view\":{d},\"url\":\"{s}\",\"title\":\"fake gui\",\"loading\":false,\"load_seq\":1,\"visible\":true,\"focused\":true}}", .{ 41 + i, 41 + i, open_urls[i][0..open_lens[i]] }) catch return 1;
            }
            w.writeAll("]}") catch return 1;
        } else if (std.mem.indexOf(u8, line, "\"cmd\":\"web-open\"") != null) {
            const key = "\"data\":\"";
            var url: []const u8 = "about:blank";
            if (std.mem.indexOf(u8, line, key)) |at| {
                const rest = line[at + key.len ..];
                if (std.mem.indexOfScalar(u8, rest, '"')) |end| url = rest[0..end];
            }
            if (open_n < open_urls.len) {
                const n = @min(url.len, 512);
                @memcpy(open_urls[open_n][0..n], url[0..n]);
                open_lens[open_n] = n;
                open_n += 1;
            }
            w.print("{{\"ok\":true,\"pane\":{d}}}", .{next_pane}) catch return 1;
            next_pane += 1;
        } else {
            w.writeAll("{\"ok\":false,\"error\":\"fake gui: unsupported command\"}") catch return 1;
        }
        w.writeAll("\n") catch return 1;
        _ = c.write(fd, w.buffered().ptr, w.buffered().len);
    }
    return 0;
}

/// Start a fake GUI as our own child (the "already running" case) and
/// wait for its control socket. Returns its pid.
fn startFakeGui(self_exe: [*:0]const u8, rt: [:0]const u8) c.pid_t {
    const pid = c.fork();
    if (pid < 0) fail("fake gui fork");
    if (pid == 0) {
        _ = c.setenv(FAKE_GUI_ENV, rt.ptr, 1);
        const devnull = c.open("/dev/null", c.O_RDWR);
        if (devnull >= 0) {
            _ = c.dup2(devnull, 1);
            _ = c.close(devnull);
        }
        var argv: [3:null]?[*:0]const u8 = .{ self_exe, "web", null };
        _ = c.execv(self_exe, @ptrCast(@constCast(&argv)));
        c._exit(127);
    }
    var sock_buf: [340]u8 = undefined;
    const sock = std.fmt.bufPrint(&sock_buf, "{s}/sketerm/{d}.sock", .{ rt, pid }) catch unreachable;
    const deadline = nowMs() + 10_000;
    while (!fileExists(sock)) {
        if (nowMs() > deadline) fail("fake gui never published its control socket");
        _ = c.usleep(50_000);
    }
    return pid;
}

/// Read `<rt>/fakegui-<pid>.log` (the fake GUI's request journal).
fn fakeGuiLog(rt: []const u8, pid: c.pid_t, buf: []u8) []const u8 {
    var p_buf: [340]u8 = undefined;
    const p = std.fmt.bufPrintZ(&p_buf, "{s}/fakegui-{d}.log", .{ rt, pid }) catch return "";
    const f = c.fopen(p.ptr, "rb") orelse return "";
    defer _ = c.fclose(f);
    const n = c.fread(buf.ptr, 1, buf.len, f);
    return buf[0..n];
}

/// Pids the fake GUIs appended to `<rt>/fakegui.pids`, newest last.
fn fakeGuiPids(rt: []const u8, out: []c.pid_t) []const c.pid_t {
    var p_buf: [340]u8 = undefined;
    const p = std.fmt.bufPrintZ(&p_buf, "{s}/fakegui.pids", .{rt}) catch return out[0..0];
    const f = c.fopen(p.ptr, "rb") orelse return out[0..0];
    defer _ = c.fclose(f);
    var buf: [4096]u8 = undefined;
    const n = c.fread(&buf, 1, buf.len, f);
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, buf[0..n], '\n');
    while (it.next()) |line| {
        if (line.len == 0 or count >= out.len) continue;
        out[count] = std.fmt.parseInt(c.pid_t, line, 10) catch continue;
        count += 1;
    }
    return out[0..count];
}

/// Kill one fake GUI by its exact pid (our own child or a detached
/// descendant; never by name) and remove its socket.
fn stopFakeGui(rt: []const u8, pid: c.pid_t) void {
    _ = c.kill(pid, c.SIGKILL);
    _ = c.waitpid(pid, null, 0);
    var sock_buf: [340]u8 = undefined;
    const sock = std.fmt.bufPrintZ(&sock_buf, "{s}/sketerm/{d}.sock", .{ rt, pid }) catch return;
    _ = c.unlink(sock.ptr);
}

/// Write `<rt>/config/sketerm/config.conf`.
fn writeSmokeConfig(rt: []const u8, body: []const u8) void {
    var dir_buf: [340]u8 = undefined;
    const dir = std.fmt.bufPrintZ(&dir_buf, "{s}/config/sketerm", .{rt}) catch fail("config path");
    _ = c.mkdir(dir.ptr, 0o700);
    var p_buf: [360]u8 = undefined;
    const p = std.fmt.bufPrintZ(&p_buf, "{s}/config.conf", .{dir}) catch fail("config path");
    const f = c.fopen(p.ptr, "w") orelse fail("cannot write smoke config.conf");
    _ = c.fwrite(body.ptr, 1, body.len, f);
    _ = c.fclose(f);
}

fn removeSmokeConfig(rt: []const u8) void {
    var p_buf: [360]u8 = undefined;
    const p = std.fmt.bufPrintZ(&p_buf, "{s}/config/sketerm/config.conf", .{rt}) catch return;
    _ = c.unlink(p.ptr);
}

/// The three web_gui facts, exactly as `capabilities` writes them.
fn expectWebGuiFacts(caps: []const u8, granted: bool, source: []const u8, transport: []const u8, comptime what: []const u8) void {
    var buf: [256]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "\"web_gui\":{s},\"web_gui_source\":\"{s}\",\"web_gui_transport\":\"{s}\"", .{ if (granted) "true" else "false", source, transport }) catch unreachable;
    if (std.mem.indexOf(u8, caps, needle) == null) {
        std.debug.print("smoke-mcp: capabilities: {s}\n", .{caps});
        fail("capabilities web_gui facts wrong: " ++ what);
    }
}

/// One granted server against a RUNNING fake GUI: capabilities carries
/// the grant lazily (transport none, no connection yet), then web_open
/// lands on the GUI socket and the transport reads discovered.
fn webGuiOpenThroughGui(m: *Mcp, rt: []const u8, gui_pid: c.pid_t, source: []const u8, comptime what: []const u8) void {
    // The GUI journal is cumulative across the servers of this stage,
    // so every assertion is on what THIS server added to it.
    var log_buf: [16384]u8 = undefined;
    const journal_before = fakeGuiLog(rt, gui_pid, &log_buf).len;
    m.initialize();
    const before = m.callTool("capabilities", "{}");
    expectWebGuiFacts(before, true, source, "none", what ++ " (before any web call)");
    if (std.mem.indexOf(u8, before, "\"web_backend\":\"gui\"") == null)
        fail("granted server did not report web_backend gui: " ++ what);
    if (fakeGuiLog(rt, gui_pid, &log_buf).len != journal_before)
        fail("capabilities touched the GUI socket (the transport must be lazy): " ++ what);

    const url = "http://grant.example/" ++ what;
    const opened = m.callTool("web_open", "{\"url\":\"" ++ url ++ "\",\"snapshot\":\"none\"}");
    if (std.mem.indexOf(u8, opened, "isError") != null or
        std.mem.indexOf(u8, opened, "\"pane\":") == null or
        std.mem.indexOf(u8, opened, "\"backend\":\"gui\"") == null)
    {
        std.debug.print("smoke-mcp: web_open: {s}\n", .{opened});
        fail("web_open under the grant did not open a GUI pane: " ++ what);
    }
    const log = fakeGuiLog(rt, gui_pid, &log_buf)[journal_before..];
    if (std.mem.indexOf(u8, log, "\"cmd\":\"web-open\"") == null or
        std.mem.indexOf(u8, log, url) == null)
        fail("the fake GUI never received web-open: " ++ what);
    const after = m.callTool("capabilities", "{}");
    expectWebGuiFacts(after, true, source, "discovered", what ++ " (after web_open)");
}

fn webGuiGrantStage(allocator: std.mem.Allocator, exe: [*:0]const u8, rt: [:0]const u8) void {
    var self_buf: [4096]u8 = undefined;
    const self_n = c.readlink("/proc/self/exe", &self_buf, self_buf.len - 1);
    if (self_n <= 0) fail("readlink /proc/self/exe");
    self_buf[@intCast(self_n)] = 0;
    const self_exe: [*:0]const u8 = @ptrCast(&self_buf);
    // The web tools need a helper PATH to report a backend at all;
    // nothing here runs it (the GUI is what would), so any executable
    // stands in and no CEF is needed.
    _ = c.setenv("SKETERM_WEB_BIN", "/bin/true", 1);
    defer _ = c.unsetenv("SKETERM_WEB_BIN");
    defer _ = c.unsetenv(mcpWebGuiEnv());
    defer _ = c.unsetenv("SKETERM_GUI_BIN");
    defer removeSmokeConfig(rt);

    var log_buf: [16384]u8 = undefined;

    // A: no grant, GUI running -> nothing changes: the facts are the
    // pre-grant ones and the GUI socket is never approached.
    const running = startFakeGui(self_exe, rt);
    {
        var m = Mcp.spawn(allocator, exe, &.{});
        m.initialize();
        const caps = m.callTool("capabilities", "{}");
        expectWebGuiFacts(caps, false, "none", "none", "no grant");
        if (std.mem.indexOf(u8, caps, "\"web_backend\":\"gui\"") != null)
            fail("without the grant the web backend must not be the user's GUI");
        if (std.mem.indexOf(u8, caps, "web_gui: not granted") == null)
            fail("capabilities text lane did not say how to grant web_gui");
        m.closeStdinWait();
        if (std.mem.indexOf(u8, fakeGuiLog(rt, running, &log_buf), "\"cmd\"") != null)
            fail("an ungranted server connected to the user's GUI");
    }

    // B: granted via each source, GUI running.
    {
        var m = Mcp.spawn(allocator, exe, &.{"--web-gui"});
        webGuiOpenThroughGui(&m, rt, running, "flag", "--web-gui");
        // The OTHER tools stay on the private daemon: a terminal and an
        // app land there, and the GUI journal gains nothing.
        var before_buf: [16384]u8 = undefined;
        const gui_before = fakeGuiLog(rt, running, &before_buf);
        const term = m.callTool("term_open", "{\"command\":[\"/bin/sh\"],\"cols\":80,\"rows\":24}");
        if (std.mem.indexOf(u8, term, "opened headless terminal") == null) fail("term_open under the grant did not open a headless terminal");
        const app = m.callTool("launch_app", "{\"command\":[\"/bin/sh\",\"-c\",\"sleep 30\"],\"wait_for\":\"exit\",\"wait_ms\":100,\"stable_ms\":0}");
        if (std.mem.indexOf(u8, app, "\"app\":1") == null or std.mem.indexOf(u8, app, "\"exited\":false") == null)
            fail("launch_app under the grant did not run on the private daemon");
        var private_buf: [512]u8 = undefined;
        const private_sock = std.fmt.bufPrint(&private_buf, "{s}/sketerm/mcp-tmp-{d}/mux.sock", .{ rt, m.pid }) catch unreachable;
        if (!fileExists(private_sock)) fail("the grant made the terminal/app tools leave the private daemon");
        const gui_after = fakeGuiLog(rt, running, &log_buf);
        if (gui_after.len != gui_before.len)
            fail("a terminal or app tool reached the user's GUI under the web-only grant");
        if (std.mem.indexOf(u8, gui_after, "term") != null or std.mem.indexOf(u8, gui_after, "launch") != null)
            fail("the GUI journal shows a non-web command");
        // Profiles are refused in GUI mode, and the refusal names the
        // grant rather than only --shared.
        const prof = m.callTool("web_open", "{\"url\":\"http://grant.example/p2\",\"profile\":\"work\"}");
        if (std.mem.indexOf(u8, prof, "isError") == null or std.mem.indexOf(u8, prof, "web_gui grant") == null)
            fail("the GUI-mode profile refusal did not name the web_gui grant");
        _ = m.callTool("close_app", "{\"app\":1}");
        m.closeStdinWait();
    }
    {
        _ = c.setenv(mcpWebGuiEnv(), "1", 1);
        var m = Mcp.spawn(allocator, exe, &.{});
        webGuiOpenThroughGui(&m, rt, running, "env", "SKETERM_MCP_WEB_GUI=1");
        m.closeStdinWait();
        // env=0 beats a config grant.
        writeSmokeConfig(rt, "[mcp]\nweb_gui = true\n");
        _ = c.setenv(mcpWebGuiEnv(), "0", 1);
        var off = Mcp.spawn(allocator, exe, &.{});
        off.initialize();
        expectWebGuiFacts(off.callTool("capabilities", "{}"), false, "env", "none", "env 0 over config true");
        off.closeStdinWait();
        _ = c.unsetenv(mcpWebGuiEnv());
        // and the flag beats env=0.
        _ = c.setenv(mcpWebGuiEnv(), "0", 1);
        var flag = Mcp.spawn(allocator, exe, &.{"--web-gui"});
        flag.initialize();
        expectWebGuiFacts(flag.callTool("capabilities", "{}"), true, "flag", "none", "flag over env 0");
        flag.closeStdinWait();
        _ = c.unsetenv(mcpWebGuiEnv());
    }
    {
        writeSmokeConfig(rt, "[mcp]\nweb_gui = true\n");
        var m = Mcp.spawn(allocator, exe, &.{});
        webGuiOpenThroughGui(&m, rt, running, "config", "config [mcp] without --profile");
        m.closeStdinWait();
    }
    {
        writeSmokeConfig(rt, "[mcp]\nweb_gui = false\n\n[mcp.assistant]\ntools = all\nweb_gui = true\n\n[mcp.quiet]\ntools = all\n");
        var m = Mcp.spawn(allocator, exe, &.{ "--profile", "assistant" });
        webGuiOpenThroughGui(&m, rt, running, "config", "config [mcp.assistant] via --profile");
        m.closeStdinWait();
        // A profile that does not state web_gui inherits the bare value.
        var quiet = Mcp.spawn(allocator, exe, &.{ "--profile", "quiet" });
        quiet.initialize();
        expectWebGuiFacts(quiet.callTool("capabilities", "{}"), false, "config", "none", "[mcp.quiet] inherits [mcp] false");
        quiet.closeStdinWait();
        removeSmokeConfig(rt);
    }
    // A bad env value is a startup error, like a bad tool policy.
    {
        _ = c.setenv(mcpWebGuiEnv(), "maybe", 1);
        var bad = Mcp.spawn(allocator, exe, &.{});
        _ = c.unsetenv(mcpWebGuiEnv());
        var st: c_int = 0;
        const deadline = nowMs() + 10_000;
        while (c.waitpid(bad.pid, &st, 1) != bad.pid) {
            if (nowMs() > deadline) fail("mcp with a bad SKETERM_MCP_WEB_GUI value did not exit");
            _ = c.usleep(50_000);
        }
        if (!(st & 0x7f == 0 and (st >> 8) & 0xff == 2)) fail("a bad SKETERM_MCP_WEB_GUI value must exit 2");
        _ = c.close(bad.to_child);
        _ = c.close(bad.from_child);
        bad.rbuf.deinit(allocator);
    }

    // C: no GUI running -> the first web call SPAWNS `sketerm web`
    // (detached, stdio not inherited), and a GUI that vanishes is
    // spawned again on the next call.
    stopFakeGui(rt, running);
    _ = c.setenv("SKETERM_GUI_BIN", self_exe, 1);
    _ = c.setenv(FAKE_GUI_ENV, rt.ptr, 1);
    defer _ = c.unsetenv(FAKE_GUI_ENV);
    {
        var pid_buf: [32]c.pid_t = undefined;
        const pids_before = fakeGuiPids(rt, &pid_buf).len;
        var m = Mcp.spawn(allocator, exe, &.{"--web-gui"});
        m.initialize();
        expectWebGuiFacts(m.callTool("capabilities", "{}"), true, "flag", "none", "spawn path, before any web call");
        if (fakeGuiPids(rt, &pid_buf).len != pids_before) fail("capabilities spawned a GUI (the transport must be lazy)");
        const opened = m.callTool("web_open", "{\"url\":\"http://grant.example/spawned\",\"snapshot\":\"none\"}");
        if (std.mem.indexOf(u8, opened, "\"jsonrpc\"") == null)
            fail("the spawned GUI's stdout leaked into the MCP JSON-RPC stream");
        if (std.mem.indexOf(u8, opened, "isError") != null or std.mem.indexOf(u8, opened, "\"pane\":") == null) {
            std.debug.print("smoke-mcp: web_open (spawn): {s}\n", .{opened});
            fail("web_open did not spawn a GUI and open through it");
        }
        const pids = fakeGuiPids(rt, &pid_buf);
        if (pids.len != pids_before + 1) fail("web_open did not spawn exactly one GUI");
        const spawned = pids[pids.len - 1];
        expectWebGuiFacts(m.callTool("capabilities", "{}"), true, "flag", "spawned", "after the spawn");
        const jl = fakeGuiLog(rt, spawned, &log_buf);
        if (std.mem.indexOf(u8, jl, "idle_exit=<absent>") == null)
            fail("the spawned GUI inherited the private-daemon idle-exit setting");
        if (std.mem.indexOf(u8, jl, "grant.example/spawned") == null)
            fail("the spawned GUI never received web-open");
        // Reparented away from the MCP server: not our child either.
        if (c.waitpid(spawned, null, 1) == spawned) fail("the spawned GUI was not detached");

        // The GUI goes away mid-session: the next web call re-spawns.
        stopFakeGui(rt, spawned);
        const again = m.callTool("web_open", "{\"url\":\"http://grant.example/respawn\",\"snapshot\":\"none\"}");
        if (std.mem.indexOf(u8, again, "isError") != null or std.mem.indexOf(u8, again, "\"pane\":") == null) {
            std.debug.print("smoke-mcp: web_open (respawn): {s}\n", .{again});
            fail("web_open after the GUI vanished did not re-spawn one");
        }
        const pids2 = fakeGuiPids(rt, &pid_buf);
        if (pids2.len != pids_before + 2) fail("the vanished GUI was not replaced by exactly one spawn");
        expectWebGuiFacts(m.callTool("capabilities", "{}"), true, "flag", "spawned", "after the re-spawn");
        m.closeStdinWait();
        stopFakeGui(rt, pids2[pids2.len - 1]);
    }

    // D: granted, no GUI, and none can be started -> the call fails
    // CLOSED with the described 'unavailable' error; no headless view.
    {
        _ = c.setenv("SKETERM_GUI_BIN", "/bin/true", 1);
        var m = Mcp.spawn(allocator, exe, &.{"--web-gui"});
        m.initialize();
        m.sendTool("web_open", "{\"url\":\"http://grant.example/never\",\"snapshot\":\"none\"}");
        const refused = m.recvLine(40_000);
        if (std.mem.indexOf(u8, refused, "\"isError\":true") == null or
            std.mem.indexOf(u8, refused, "\"code\":\"unavailable\"") == null or
            std.mem.indexOf(u8, refused, "within 15s") == null or
            std.mem.indexOf(u8, refused, "nothing was opened headlessly") == null or
            std.mem.indexOf(u8, refused, "\"pane\":") != null or
            std.mem.indexOf(u8, refused, "\"view\":") != null)
        {
            std.debug.print("smoke-mcp: web_open (no GUI): {s}\n", .{refused});
            fail("a granted server with no reachable GUI did not fail closed");
        }
        expectWebGuiFacts(m.callTool("capabilities", "{}"), true, "flag", "none", "after the failed spawn");
        // The private instance dir holds no helper socket: no headless
        // engine was started as a fallback.
        var web_sock_buf: [512]u8 = undefined;
        const web_sock = std.fmt.bufPrint(&web_sock_buf, "{s}/sketerm/mcp-tmp-{d}/web.sock", .{ rt, m.pid }) catch unreachable;
        if (fileExists(web_sock)) fail("a headless helper was started despite the grant");
        m.closeStdinWait();
    }
}

/// The env switch `sketerm mcp` reads (`mcp_webgui.ENV`); a literal
/// because this GTK-free binary cannot import that module. The stage
/// proves the name by behaviour: a wrong one fails the env cases.
fn mcpWebGuiEnv() [*:0]const u8 {
    return "SKETERM_MCP_WEB_GUI";
}

/// The `[id]` immediately preceding `needle` on its snapshot line —
/// how a caller reads "the node id of the button named X" out of an
/// (escaped) tool reply.
fn nodeIdBefore(hay: []const u8, needle: []const u8) ?u32 {
    const at = std.mem.indexOf(u8, hay, needle) orelse return null;
    var i = at;
    while (i > 0) {
        i -= 1;
        if (hay[i] == '[') break;
        if (hay[i] == '\n') return null;
    }
    if (hay[i] != '[') return null;
    var j = i + 1;
    var v: u32 = 0;
    var any = false;
    while (j < hay.len and hay[j] >= '0' and hay[j] <= '9') : (j += 1) {
        v = v * 10 + (hay[j] - '0');
        any = true;
    }
    if (!any or j >= hay.len or hay[j] != ']') return null;
    return v;
}

/// Entity id in the rich web_read record whose text contains `needle`.
fn readerIdBefore(hay: []const u8, needle: []const u8) ?u32 {
    const at = std.mem.lastIndexOf(u8, hay, needle) orelse return null;
    const before = hay[0..at];
    // The entity list rides structuredContent now, so its keys are
    // ordinary JSON in the NDJSON line rather than an escaped string.
    const key = "\"id\":";
    const id_at = std.mem.lastIndexOf(u8, before, key) orelse return null;
    var i = id_at + key.len;
    var value: u32 = 0;
    var any = false;
    while (i < hay.len and std.ascii.isDigit(hay[i])) : (i += 1) {
        value = value * 10 + hay[i] - '0';
        any = true;
    }
    return if (any) value else null;
}

/// A one-page loopback HTTP server, purely so the profile checks have a
/// real ORIGIN to test with.
///
/// `file://` cannot carry cookies at all in Chromium — `document.cookie`
/// there is a silent no-op — so an isolation test written against the
/// smoke page's file URL would pass on an engine that isolates nothing.
const TinyHttp = struct {
    fd: c_int = -1,
    port: u16 = 0,
    thread: ?std.Thread = null,
    /// The one document served, whatever the path; a stage that needs
    /// its own page sets it before `spawn`.
    body: []const u8 = BODY,
    /// One path served as a DOWNLOADABLE attachment (octet-stream +
    /// Content-Disposition) instead of a document; empty = none. The
    /// download stage needs a url the engine downloads rather than
    /// renders, which is a property of the response, not of the url.
    dl_path: []const u8 = "",
    dl_body: []const u8 = "",

    const BODY =
        "<html><head><title>Profile Origin</title></head><body>" ++
        "<h1>PROFILE-ORIGIN</h1><p id=p>cookie probe page</p></body></html>";

    fn start() ?TinyHttp {
        var self = TinyHttp{};
        self.fd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
        if (self.fd < 0) return null;
        var one: c_int = 1;
        _ = c.setsockopt(self.fd, c.SOL_SOCKET, c.SO_REUSEADDR, &one, @sizeOf(c_int));
        var sa = std.mem.zeroes(c.struct_sockaddr_in);
        sa.sin_family = c.AF_INET;
        sa.sin_port = 0;
        sa.sin_addr.s_addr = std.mem.nativeToBig(u32, c.INADDR_LOOPBACK);
        if (c.bind(self.fd, @ptrCast(&sa), @sizeOf(c.struct_sockaddr_in)) != 0 or
            c.listen(self.fd, 16) != 0)
        {
            _ = c.close(self.fd);
            return null;
        }
        var got = std.mem.zeroes(c.struct_sockaddr_in);
        var glen: c.socklen_t = @sizeOf(c.struct_sockaddr_in);
        if (c.getsockname(self.fd, @ptrCast(&got), &glen) != 0) {
            _ = c.close(self.fd);
            return null;
        }
        self.port = std.mem.bigToNative(u16, got.sin_port);
        return self;
    }

    fn spawn(self: *TinyHttp) void {
        self.thread = std.Thread.spawn(.{}, serve, .{self}) catch null;
    }

    /// One connection at a time is plenty: the browser asks for one
    /// document per view. Ends when `deinit` closes the listener.
    fn serve(self: *TinyHttp) void {
        while (true) {
            const cfd = c.accept(self.fd, null, null);
            if (cfd < 0) return;
            var req: [4096]u8 = undefined;
            const got = c.read(cfd, &req, req.len);
            const line = if (got > 0) req[0..@intCast(got)] else "";
            const want_dl = self.dl_path.len != 0 and std.mem.indexOf(u8, line, self.dl_path) != null;
            const payload = if (want_dl) self.dl_body else self.body;
            var head: [320]u8 = undefined;
            const hdr = if (want_dl)
                std.fmt.bufPrint(
                    &head,
                    "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=\"served.bin\"\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
                    .{payload.len},
                ) catch return
            else
                std.fmt.bufPrint(
                    &head,
                    "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
                    .{payload.len},
                ) catch return;
            // MSG_NOSIGNAL, never write(2): the browser closes a
            // connection it already has the bytes for (favicon probes
            // especially), and the SIGPIPE that follows would kill the
            // smoke process rather than this one request.
            _ = c.send(cfd, hdr.ptr, hdr.len, c.MSG_NOSIGNAL);
            _ = c.send(cfd, payload.ptr, payload.len, c.MSG_NOSIGNAL);
            _ = c.close(cfd);
        }
    }

    fn deinit(self: *TinyHttp) void {
        if (self.fd >= 0) {
            _ = c.shutdown(self.fd, c.SHUT_RDWR);
            _ = c.close(self.fd);
            self.fd = -1;
        }
        if (self.thread) |t| t.detach();
        self.thread = null;
    }
};

/// Route-aware loopback fixture for the ENFORCED-policy stage. Every
/// path keeps a HIT COUNTER: "the server was never touched" is the
/// proof standard here — a page error alone proves nothing about
/// whether the request left the process.
const PolicyHttp = struct {
    fd: c_int = -1,
    port: u16 = 0,

    const PATHS = [_][]const u8{
        "/doc",         "/doc2",        "/offsite-page",  "/img.png",        "/imgs",
        "/blocked.png", "/sub.js",      "/redir-offsite", "/offsite-target", "/many",
        "/r0",          "/r1",          "/r2",            "/r3",             "/r4",
        "/r5",          "/r6",          "/r7",            "/r8",             "/r9",
        "/slow",        "/favicon.ico",
    };
    var hits: [PATHS.len]std.atomic.Value(u32) = @splat(std.atomic.Value(u32).init(0));

    fn idx(path: []const u8) ?usize {
        for (PATHS, 0..) |p, i| {
            if (std.mem.eql(u8, p, path)) return i;
        }
        return null;
    }

    fn hitsFor(path: []const u8) u32 {
        return hits[idx(path).?].load(.acquire);
    }

    fn start() ?PolicyHttp {
        for (&hits) |*h| h.store(0, .release);
        var self = PolicyHttp{};
        self.fd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
        if (self.fd < 0) return null;
        var one: c_int = 1;
        _ = c.setsockopt(self.fd, c.SOL_SOCKET, c.SO_REUSEADDR, &one, @sizeOf(c_int));
        var sa = std.mem.zeroes(c.struct_sockaddr_in);
        sa.sin_family = c.AF_INET;
        sa.sin_port = 0;
        sa.sin_addr.s_addr = std.mem.nativeToBig(u32, c.INADDR_LOOPBACK);
        if (c.bind(self.fd, @ptrCast(&sa), @sizeOf(c.struct_sockaddr_in)) != 0 or
            c.listen(self.fd, 32) != 0)
        {
            _ = c.close(self.fd);
            return null;
        }
        var got = std.mem.zeroes(c.struct_sockaddr_in);
        var glen: c.socklen_t = @sizeOf(c.struct_sockaddr_in);
        if (c.getsockname(self.fd, @ptrCast(&got), &glen) != 0) {
            _ = c.close(self.fd);
            return null;
        }
        self.port = std.mem.bigToNative(u16, got.sin_port);
        const t = std.Thread.spawn(.{}, acceptLoop, .{ self.fd, self.port }) catch {
            _ = c.close(self.fd);
            return null;
        };
        t.detach();
        return self;
    }

    fn acceptLoop(lfd: c_int, port: u16) void {
        while (true) {
            const cfd = c.accept(lfd, null, null);
            if (cfd < 0) return;
            // A thread per connection: /slow must not starve the
            // browser's parallel subresource fetches.
            const t = std.Thread.spawn(.{}, serveOne, .{ cfd, port }) catch {
                _ = c.close(cfd);
                continue;
            };
            t.detach();
        }
    }

    fn serveOne(cfd: c_int, port: u16) void {
        defer _ = c.close(cfd);
        var req: [4096]u8 = undefined;
        const n = c.read(cfd, &req, req.len);
        if (n <= 0) return;
        const line = req[0..@intCast(n)];
        const sp1 = std.mem.indexOfScalar(u8, line, ' ') orelse return;
        const rest = line[sp1 + 1 ..];
        const sp2 = std.mem.indexOfScalar(u8, rest, ' ') orelse return;
        var path = rest[0..sp2];
        if (std.mem.indexOfScalar(u8, path, '?')) |q| path = path[0..q];
        if (idx(path)) |i| _ = hits[i].fetchAdd(1, .acq_rel);

        var body_buf: [2048]u8 = undefined;
        var body: []const u8 = "<html><title>policy</title><body>ok</body></html>";
        var ctype: []const u8 = "text/html";
        var status: []const u8 = "200 OK";
        var location_buf: [128]u8 = undefined;
        var location: []const u8 = "";
        if (std.mem.eql(u8, path, "/offsite-page")) {
            // The img lives on ANOTHER HOST (localhost vs 127.0.0.1 —
            // same machine, different host STRING, which is all a host
            // allow-list can see); the script is same-host.
            body = std.fmt.bufPrint(&body_buf, "<html><title>offsite sub</title><body><img src=\"http://localhost:{d}/img.png\"><script src=\"/sub.js\"></script><p>SUBHOST-PAGE</p></body></html>", .{port}) catch return;
        } else if (std.mem.eql(u8, path, "/imgs")) {
            body = "<html><title>imgs</title><body><img src=\"/blocked.png\"><p>TYPEBLOCK-PAGE</p></body></html>";
        } else if (std.mem.eql(u8, path, "/many")) {
            body = "<html><title>many</title><body>" ++
                "<img src=\"/r0\"><img src=\"/r1\"><img src=\"/r2\"><img src=\"/r3\"><img src=\"/r4\">" ++
                "<img src=\"/r5\"><img src=\"/r6\"><img src=\"/r7\"><img src=\"/r8\"><img src=\"/r9\">" ++
                "<p>MANY-PAGE</p></body></html>";
        } else if (std.mem.eql(u8, path, "/redir-offsite")) {
            status = "302 Found";
            location = std.fmt.bufPrint(&location_buf, "http://localhost:{d}/offsite-target", .{port}) catch return;
            body = "";
        } else if (std.mem.eql(u8, path, "/slow")) {
            // Long enough for a 1500ms deadline to latch mid-load.
            _ = c.usleep(4_000_000);
        } else if (std.mem.endsWith(u8, path, ".png") or std.mem.startsWith(u8, path, "/r")) {
            ctype = "image/png";
            body = "\x89PNG-not-really";
        } else if (std.mem.eql(u8, path, "/sub.js")) {
            ctype = "text/javascript";
            body = "window.SUB_OK=1;";
        }

        var head: [512]u8 = undefined;
        const hdr = if (location.len > 0)
            std.fmt.bufPrint(&head, "HTTP/1.1 {s}\r\nLocation: {s}\r\nContent-Length: 0\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", .{ status, location }) catch return
        else
            std.fmt.bufPrint(&head, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", .{ status, ctype, body.len }) catch return;
        _ = c.send(cfd, hdr.ptr, hdr.len, c.MSG_NOSIGNAL);
        if (body.len > 0) _ = c.send(cfd, body.ptr, body.len, c.MSG_NOSIGNAL);
    }

    fn deinit(self: *PolicyHttp) void {
        if (self.fd >= 0) {
            _ = c.shutdown(self.fd, c.SHUT_RDWR);
            _ = c.close(self.fd);
            self.fd = -1;
        }
    }
};

/// Isolated `sketerm mcp` (no GUI, no --shared) driving a real page
/// end to end through the headless web backend.
/// The 64-hex fingerprint a refusal reported, or null.
fn fingerprintOf(reply: []const u8) ?[]const u8 {
    const key = "\"fingerprint\":\"";
    const at = std.mem.indexOf(u8, reply, key) orelse return null;
    const start = at + key.len;
    if (reply.len < start + 64) return null;
    return reply[start .. start + 64];
}

/// The `"view":N` handle in a reply's structuredContent, or 0.
fn viewHandleOf(reply: []const u8) u32 {
    const key = "\"view\":";
    const at = std.mem.indexOf(u8, reply, key) orelse return 0;
    var i = at + key.len;
    var v: u32 = 0;
    while (i < reply.len and reply[i] >= '0' and reply[i] <= '9') : (i += 1) v = v * 10 + (reply[i] - '0');
    return v;
}

/// The payload the loopback server hands out at `/served.bin`. Short,
/// distinctive, and asserted byte for byte: "the download reported
/// success" is exactly the claim that used to be false.
const DOWNLOAD_PAYLOAD = "SKETERM-DOWNLOAD-PAYLOAD-0123456789";

/// Downloads, end to end against REAL CEF. This is the stage that
/// exists because the whole thing silently did nothing: a headless
/// client ignored the download frames, the engine held every target
/// decision forever, a page's `a.click()` reported success, and no file
/// was written anywhere with no error on any side.
///
/// Three claims, each of which was false before:
///   1. `web_download` fetches a url through the view's own browser and
///      the bytes are on disk at the path the caller named.
///   2. A download the PAGE starts lands in the user's XDG download
///      directory — the one user-dirs.dirs names, not a hard-coded
///      `$HOME/Downloads` the user does not have.
///   3. Either one is REPORTABLE afterwards (`web_download` with no url).
fn webDownloadStage(m: *Mcp, rt: []const u8, port: u16) void {
    var args_buf: [1024]u8 = undefined;
    var path_buf: [512]u8 = undefined;

    // The user's own download directory, exactly the shape that broke:
    // xdg-user-dirs pointing at a LOWERCASE `downloads`.
    const dl_dir = std.fmt.bufPrint(&path_buf, "{s}/home/downloads", .{rt}) catch unreachable;
    {
        var z: [512:0]u8 = undefined;
        const zp = std.fmt.bufPrintZ(&z, "{s}", .{dl_dir}) catch unreachable;
        _ = c.mkdir(zp.ptr, 0o700);
        var cfg_buf: [512:0]u8 = undefined;
        const cfg = std.fmt.bufPrintZ(&cfg_buf, "{s}/config/user-dirs.dirs", .{rt}) catch unreachable;
        const f = c.fopen(cfg.ptr, "wb") orelse fail("cannot write user-dirs.dirs");
        var body_buf: [640]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf, "XDG_DOWNLOAD_DIR=\"{s}\"\n", .{dl_dir}) catch unreachable;
        _ = c.fwrite(body.ptr, 1, body.len, f);
        _ = c.fclose(f);
    }

    var origin_buf: [64]u8 = undefined;
    const origin = std.fmt.bufPrint(&origin_buf, "http://127.0.0.1:{d}/", .{port}) catch unreachable;
    m.sendTool("web_open", std.fmt.bufPrint(&args_buf, "{{\"url\":\"{s}\",\"snapshot\":\"none\"}}", .{origin}) catch unreachable);
    const opened = m.recvLine(60_000);
    if (std.mem.indexOf(u8, opened, "isError") != null) fail("download stage: could not open the loopback origin");

    // capabilities must PREFLIGHT this, not leave it to be discovered.
    const caps = m.callTool("capabilities", "{}");
    if (std.mem.indexOf(u8, caps, "\"web_downloads\":true") == null)
        fail("capabilities does not report that web_download works here");

    // (1) A url downloaded through the view, to the caller's path.
    var got_buf: [512]u8 = undefined;
    const got = std.fmt.bufPrint(&got_buf, "{s}/home/got.bin", .{rt}) catch unreachable;
    const dl = m.callTool("web_download", std.fmt.bufPrint(
        &args_buf,
        "{{\"url\":\"http://127.0.0.1:{d}/served.bin\",\"path\":\"{s}\",\"timeout_ms\":30000}}",
        .{ port, got },
    ) catch unreachable);
    if (std.mem.indexOf(u8, dl, "isError") != null) {
        std.debug.print("smoke-mcp: web_download: {s}\n", .{dl});
        fail("web_download failed against the loopback server");
    }
    if (std.mem.indexOf(u8, dl, "\"state\":\"done\"") == null)
        fail("web_download did not report the transfer as done");
    if (std.mem.indexOf(u8, dl, "\"sha256\":\"") == null)
        fail("web_download did not report the file's digest");
    var read_buf: [256]u8 = undefined;
    const on_disk = readSmall(got, &read_buf);
    if (!std.mem.eql(u8, on_disk, DOWNLOAD_PAYLOAD)) {
        std.debug.print("smoke-mcp: on disk: '{s}'\n", .{on_disk});
        fail("web_download reported success but the file's bytes are not the payload");
    }

    // (2) A download the PAGE starts: the exact field repro, an anchor
    // clicked from script. It must land in the XDG download directory.
    const clicked = m.callTool("web_eval", std.fmt.bufPrint(
        &args_buf,
        "{{\"body\":\"const a=document.createElement('a');a.href='http://127.0.0.1:{d}/served.bin';a.download='page.bin';document.body.appendChild(a);a.click();return 'clicked';\"}}",
        .{port},
    ) catch unreachable);
    if (std.mem.indexOf(u8, clicked, "clicked") == null)
        fail("the page-initiated download click did not run");
    var landed: []const u8 = "";
    var page_path_buf: [512]u8 = undefined;
    // The engine names the file, and a `Content-Disposition` filename
    // outranks the anchor's `download` attribute — so the assertion is
    // "the payload is in the XDG download directory", not "under the
    // name the page asked for".
    const page_path = std.fmt.bufPrint(&page_path_buf, "{s}/served.bin", .{dl_dir}) catch unreachable;
    const deadline = nowMs() + 30_000;
    while (nowMs() < deadline) {
        const listed = m.callTool("web_download", "{}");
        if (std.mem.indexOf(u8, listed, "isError") != null) fail("web_download listing failed");
        if (fileExists(page_path)) {
            landed = readSmall(page_path, &read_buf);
            if (std.mem.eql(u8, landed, DOWNLOAD_PAYLOAD)) break;
        }
        _ = c.usleep(200_000);
    }
    if (!std.mem.eql(u8, landed, DOWNLOAD_PAYLOAD)) {
        std.debug.print("smoke-mcp: expected {s}, got '{s}'\n", .{ page_path, landed });
        fail("a page-initiated download did not land in the XDG download directory (the silent-discard bug)");
    }

    // (3) Both are reportable afterwards, with their paths.
    const listing = m.callTool("web_download", "{}");
    if (std.mem.indexOf(u8, listing, "\"listing\":true") == null)
        fail("web_download with no url did not report a listing");
    if (std.mem.indexOf(u8, listing, page_path) == null)
        fail("web_download's listing does not name the page-initiated download's path");

    _ = m.callTool("web_close", "{}");
}

/// The eval result-size contract. A 40000-character string used to come
/// back as 4046 bytes of perfectly valid JSON — cut in the PAGE, so
/// total_chars reported the cut length, strict:true never fired, and
/// web_expand paged the capture rather than the value. Every one of
/// those is asserted here against a real engine.
fn webEvalSizeStage(m: *Mcp, rt: []const u8) void {
    var args_buf: [1024]u8 = undefined;
    const BIG = 40_000;
    var code_buf: [256]u8 = undefined;
    const code = std.fmt.bufPrint(&code_buf, "'x'.repeat({d})", .{BIG}) catch unreachable;

    m.sendTool("web_open", "{\"url\":\"data:text/html,<h1>size</h1>\",\"snapshot\":\"none\"}");
    if (std.mem.indexOf(u8, m.recvLine(60_000), "isError") != null)
        fail("eval-size stage: could not open a view");

    // The whole string, inline, when the caller asks for the room.
    const whole = m.callTool("web_eval", std.fmt.bufPrint(
        &args_buf,
        "{{\"code\":\"{s}\",\"max_chars\":60000}}",
        .{code},
    ) catch unreachable);
    if (std.mem.indexOf(u8, whole, "isError") != null) fail("web_eval of a 40000-char string failed");
    if (std.mem.indexOf(u8, whole, "\"truncated\":true") != null)
        fail("web_eval truncated a result that fits inside the max_chars it was given");
    if (std.mem.indexOf(u8, whole, "\"__kind\":\"string\"") != null)
        fail("the page cut the string even though the caller's budget covered it (the 4000-char slice is back)");

    // The default inline limit: TRUNCATED, and the length it reports is
    // the WHOLE length, not the length of what the page happened to
    // serialize.
    const cut = m.callTool("web_eval", std.fmt.bufPrint(&args_buf, "{{\"code\":\"{s}\"}}", .{code}) catch unreachable);
    if (std.mem.indexOf(u8, cut, "\"truncated\":true") == null)
        fail("a 40000-char result was not reported as truncated at the default inline limit");
    var want_total: [64]u8 = undefined;
    // 40002 = the string plus its JSON quotes, inside {"value":...}.
    if (std.mem.indexOf(u8, cut, std.fmt.bufPrint(&want_total, "\"total_chars\":{d}", .{BIG + 12}) catch unreachable) == null) {
        std.debug.print("smoke-mcp: web_eval cut reply: {s}\n", .{cut[0..@min(cut.len, 600)]});
        fail("web_eval's total_chars is not the whole result's length (the page-side cut is being reported as the total)");
    }

    // strict:true refuses instead of handing back a prefix.
    const strict = m.callTool("web_eval", std.fmt.bufPrint(&args_buf, "{{\"code\":\"{s}\",\"strict\":true}}", .{code}) catch unreachable);
    if (std.mem.indexOf(u8, strict, "\"isError\":true") == null)
        fail("strict:true truncated instead of erroring");
    if (std.mem.indexOf(u8, strict, "too large for strict inline return") == null)
        fail("the strict refusal does not say why");

    // out_file: the whole thing on disk, nothing in the reply.
    var out_buf: [512]u8 = undefined;
    const out_path = std.fmt.bufPrint(&out_buf, "{s}/home/eval.txt", .{rt}) catch unreachable;
    const to_file = m.callTool("web_eval", std.fmt.bufPrint(
        &args_buf,
        "{{\"code\":\"{s}\",\"out_file\":\"{s}\"}}",
        .{ code, out_path },
    ) catch unreachable);
    if (std.mem.indexOf(u8, to_file, "isError") != null) fail("web_eval out_file failed");
    if (std.mem.indexOf(u8, to_file, "\"format\":\"text\"") == null)
        fail("web_eval out_file did not write a string value as text");
    var size_buf: [64]u8 = undefined;
    if (std.mem.indexOf(u8, to_file, std.fmt.bufPrint(&size_buf, "\"bytes\":{d}", .{BIG}) catch unreachable) == null) {
        std.debug.print("smoke-mcp: out_file reply: {s}\n", .{to_file[0..@min(to_file.len, 600)]});
        fail("web_eval out_file did not write the whole 40000-character string");
    }
    if (std.mem.indexOf(u8, to_file, "\"truncated\":true") != null)
        fail("web_eval out_file reported a truncation for a result it wrote whole");

    // web_expand pages the REAL value, not the capture: the tail of the
    // string is reachable.
    const tail = m.callTool("web_expand", "{\"id\":0,\"offset\":39000,\"len\":2000}");
    if (std.mem.indexOf(u8, tail, "isError") != null) fail("web_expand id=0 failed after a truncated eval");
    if (std.mem.indexOf(u8, tail, std.fmt.bufPrint(&want_total, "\"total_chars\":{d}", .{BIG + 12}) catch unreachable) == null)
        fail("web_expand pages something shorter than the whole result (the page-side capture, not the value)");
    // Offset 39000 is far past the old 4046-byte capture: an empty
    // page here IS the bug this stage exists for.
    if (std.mem.indexOf(u8, tail, "\"text\":\"xxx") == null)
        fail("web_expand returned nothing at offset 39000 - the tail of the result is unreachable");

    // A `body` with top-level await runs (the wrapper is async).
    const awaited = m.callTool("web_eval", "{\"body\":\"const v = await Promise.resolve(7); return v + 1;\"}");
    if (std.mem.indexOf(u8, awaited, "\"value\":8") == null) {
        std.debug.print("smoke-mcp: async body reply: {s}\n", .{awaited[0..@min(awaited.len, 400)]});
        fail("a body with top-level await did not run (the wrapper is not async)");
    }

    _ = m.callTool("web_close", "{}");
}

/// A self-signed loopback server: the open that used to HANG. The
/// headless client dropped `ev_cert_error`, so the helper held the
/// request forever and web_open sat on `loading:true` for its whole
/// timeout with no reason (a router's own certificate, in the field).
/// Now the hold is answered at once, fail closed: the reply comes back
/// in seconds carrying the verdict and fingerprint, web_wait refuses
/// instead of timing out, and naming that fingerprint loads the page.
fn certStage(m: *Mcp, rt: []const u8) void {
    var dir_buf: [512]u8 = undefined;
    const dir = std.fmt.bufPrintZ(&dir_buf, "{s}/tls", .{rt}) catch unreachable;
    _ = c.mkdir(dir.ptr, 0o700);
    if (!smoke_tls.writeFile(dir, "index.html", "<html><head><title>Bad Cert Page</title></head><body><p>BADCERT-MARKER</p></body></html>"))
        fail("cannot write the tls page");
    const server = smoke_tls.start(dir) orelse {
        say("smoke-mcp: SKIP refused-certificate stage (no usable openssl s_server on this host)");
        return;
    };
    defer server.stop();
    var url_buf: [128]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "https://127.0.0.1:{d}/index.html", .{server.port}) catch unreachable;
    var args_buf: [1024]u8 = undefined;

    // Nobody opted in: refused, promptly, with the way out named.
    const t0 = nowMs();
    m.sendTool("web_open", std.fmt.bufPrint(&args_buf, "{{\"url\":\"{s}\"}}", .{url}) catch unreachable);
    const refused = m.recvLine(40_000);
    const took = nowMs() - t0;
    if (std.mem.indexOf(u8, refused, "isError") != null) fail("web_open on a self-signed host errored instead of reporting the refusal");
    if (std.mem.indexOf(u8, refused, "\"settled\":false") == null) fail("web_open reported a refused certificate as settled");
    if (std.mem.indexOf(u8, refused, "\"cert\":{\"state\":\"refused\"") == null) fail("web_open did not report the refused certificate as a fact");
    if (std.mem.indexOf(u8, refused, "certificate REFUSED on 127.0.0.1") == null) fail("web_open's text does not say the certificate was refused");
    if (std.mem.indexOf(u8, refused, "\"load_error\":{") == null) fail("the refusal's load failure is not reported");
    if (took > 15_000) fail("web_open sat on the held certificate instead of answering it (the hang is back)");
    const fp = fingerprintOf(refused) orelse fail("the refusal carries no fingerprint");
    const refused_view = viewHandleOf(refused);
    if (refused_view == 0) fail("the refused open minted no view handle");

    // web_wait for the load: an error now, not a 15s timeout.
    const t1 = nowMs();
    const waited = m.callTool("web_wait", "{\"for\":\"load\",\"timeout_ms\":14000}");
    if (std.mem.indexOf(u8, waited, "isError") == null or std.mem.indexOf(u8, waited, "REFUSED") == null)
        fail("web_wait for:load on a refused certificate did not refuse");
    if (nowMs() - t1 > 5_000) fail("web_wait burned its timeout on a load that could never arrive");

    // A string that cannot be a fingerprint is refused at the call.
    const bad = m.callTool("web_open", std.fmt.bufPrint(&args_buf, "{{\"url\":\"{s}\",\"accept_cert\":\"nope\"}}", .{url}) catch unreachable);
    if (std.mem.indexOf(u8, bad, "isError") == null or std.mem.indexOf(u8, bad, "invalid_args") == null)
        fail("a malformed accept_cert was not refused");

    // Naming exactly that certificate loads the page, and the reply
    // says what the page stands on.
    m.sendTool("web_open", std.fmt.bufPrint(&args_buf, "{{\"url\":\"{s}\",\"accept_cert\":\"{s}\"}}", .{ url, fp }) catch unreachable);
    const accepted = m.recvLine(40_000);
    if (std.mem.indexOf(u8, accepted, "isError") != null) fail("web_open with the right accept_cert failed");
    if (std.mem.indexOf(u8, accepted, "\"settled\":true") == null) fail("web_open with accept_cert did not settle");
    if (std.mem.indexOf(u8, accepted, "\"cert\":{\"state\":\"accepted\"") == null) {
        say(accepted);
        fail("the accepted certificate is not reported as a fact");
    }
    if (std.mem.indexOf(u8, accepted, "BADCERT-MARKER") == null) fail("the accepted open's snapshot is not the page");
    const accepted_view = viewHandleOf(accepted);

    var close_buf: [64]u8 = undefined;
    _ = m.callTool("web_close", std.fmt.bufPrint(&close_buf, "{{\"pane\":{d}}}", .{accepted_view}) catch unreachable);
    _ = m.callTool("web_close", std.fmt.bufPrint(&close_buf, "{{\"pane\":{d}}}", .{refused_view}) catch unreachable);
    say("smoke-mcp: refused-certificate stage ok");
}

fn webReviewStage(m: *Mcp, rt: []const u8) void {
    var path_buf: [512:0]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/review.html", .{rt}) catch unreachable;
    const html =
        "<!doctype html><title>Review fixture</title><div role=main id=outer><main id=inner>" ++
        "<pl-button id=wrapper aria-expanded=false aria-controls=menu></pl-button>" ++
        "<div id=wide style='width:200px;overflow:auto'><div style='width:400px'>Overflow</div></div>" ++
        "<div id=menu>Menu</div></main></div><script>" ++
        "const host=document.querySelector('pl-button');const root=host.attachShadow({mode:'open'});" ++
        "root.innerHTML='<button id=actual>Toggle menu</button>';const b=root.querySelector('button');b.focus();" ++
        "b.onclick=()=>{history.pushState({},'', '#spa');console.error('review-console-error');" ++
        "setTimeout(()=>{document.body.dataset.done='yes';throw new Error('review-uncaught-error')},20)};" ++
        "</script>";
    @import("util/atomicwrite.zig").writeFileExact(path, html, 0o600) catch fail("cannot write review fixture");
    var args: [2048]u8 = undefined;
    m.sendTool("web_open", std.fmt.bufPrint(&args, "{{\"url\":\"file://{s}\",\"ephemeral\":true}}", .{path}) catch unreachable);
    const opened = m.recvLine(60_000);
    if (std.mem.indexOf(u8, opened, "isError") != null) fail("review fixture failed to open");
    const view = viewHandleOf(opened);
    const inspected = m.callTool("web_inspect", "{}");
    for ([_][]const u8{ "nested_main", "disclosure_on_wrapper", "horizontal_overflow", "actual", "Toggle menu" }) |needle| {
        if (std.mem.indexOf(u8, inspected, needle) == null) {
            say(inspected);
            fail("inspection missed a required defect or focused shadow control");
        }
    }
    const scoped = m.callTool("web_inspect", "{\"selector\":\"#wide\"}");
    if (std.mem.indexOf(u8, scoped, "horizontal_overflow") == null or std.mem.indexOf(u8, scoped, "nested_main") != null)
        fail("inspection selector did not bound findings");
    const checkpoint = m.callTool("web_checkpoint", "{}");
    var id_buf: [64]u8 = undefined;
    const id = presenceField(checkpoint, "checkpoint", &id_buf) orelse fail("checkpoint id missing");
    // Trusted keyboard interaction, not a monkey-patched navigation function.
    const key = m.callTool("web_key", "{\"keys\":\"Enter\"}");
    if (std.mem.indexOf(u8, key, "isError") != null) fail("review fixture trusted key failed");
    const spa = m.callTool("web_checkpoint", std.fmt.bufPrint(&args, "{{\"id\":\"{s}\",\"ready_selector\":\"body[data-done=yes]\"}}", .{id}) catch unreachable);
    for ([_][]const u8{ "\"document_preserved\":true", "\"passed\":true", "review-console-error", "review-uncaught-error" }) |needle| {
        if (std.mem.indexOf(u8, spa, needle) == null) {
            say(spa);
            fail("soft navigation checkpoint lost document identity or new errors");
        }
    }
    _ = m.callTool("web_navigate", "{\"action\":\"reload\"}");
    const reload = m.callTool("web_checkpoint", std.fmt.bufPrint(&args, "{{\"id\":\"{s}\",\"expect_preserved\":false,\"screenshot\":true,\"out_dir\":\"{s}/review-evidence\"}}", .{ id, rt }) catch unreachable);
    if (std.mem.indexOf(u8, reload, "\"document_preserved\":false") == null or
        std.mem.indexOf(u8, reload, "\"passed\":true") == null or std.mem.indexOf(u8, reload, "\"artifacts\":") == null)
    {
        say(reload);
        fail("full reload checkpoint or evidence export failed");
    }
    _ = m.callTool("web_close", std.fmt.bufPrint(&args, "{{\"pane\":{d}}}", .{view}) catch unreachable);
    var report_buf: [65536]u8 = undefined;
    const report = readSmall(std.fmt.bufPrint(&args, "{s}/review-evidence/report.md", .{rt}) catch unreachable, &report_buf);
    for ([_][]const u8{ "document_preserved", "captured_at_ms", "viewport", "nested_main", "screenshot.png" }) |needle|
        if (std.mem.indexOf(u8, report, needle) == null) fail("exported evidence is not self-contained after view close");
    if (!fileExists(std.fmt.bufPrint(&args, "{s}/review-evidence/screenshot.png", .{rt}) catch unreachable)) fail("exported screenshot missing");
    say("smoke-mcp: review inspection, shadow controls, SPA/reload checkpoints and durable export ok");
}

/// The unsigned number after `"key":` in a reply, or null when absent.
fn uintField(json: []const u8, key: []const u8) ?u64 {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":", .{key}) catch return null;
    const at = std.mem.indexOf(u8, json, needle) orelse return null;
    var i = at + needle.len;
    if (i >= json.len or json[i] < '0' or json[i] > '9') return null;
    var v: u64 = 0;
    while (i < json.len and json[i] >= '0' and json[i] <= '9') : (i += 1) v = v * 10 + (json[i] - '0');
    return v;
}

/// Driving a page by hand against the REAL helper: web_frame long-polls
/// painted frames (and answers unchanged on a still page), web_input's
/// pointer edges, a held Shift, text at the caret and a wheel step reach
/// the page as trusted input the page itself observes.
fn webHandStage(m: *Mcp, rt: []const u8) void {
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/hand-fixture.html", .{rt}) catch unreachable;
    const html =
        "<!doctype html><html><head><title>hand</title></head><body style='margin:0;height:4000px'>" ++
        "<div id=pad style='position:fixed;left:0;top:0;width:200px;height:100px;background:#00ff00'></div>" ++
        "<input id=field style='position:fixed;left:0;top:150px;width:200px;height:30px'><script>" ++
        "const pad=document.getElementById('pad');" ++
        "pad.addEventListener('pointerdown',e=>{document.title='down '+e.clientX+','+e.clientY+(e.shiftKey?' shift':'')+(e.isTrusted?' trusted':'');pad.style.background='#ff0000'});" ++
        "pad.addEventListener('pointerup',()=>{document.title+=' up'});" ++
        "addEventListener('keydown',e=>{if(e.key==='Shift')document.body.dataset.shift='held'});" ++
        "addEventListener('keyup',e=>{if(e.key==='Shift')document.body.dataset.shift='released'});" ++
        "</script></body></html>";
    @import("util/atomicwrite.zig").writeFileExact(path, html, 0o600) catch fail("cannot write hand fixture");
    var args: [2048]u8 = undefined;
    m.sendTool("web_open", std.fmt.bufPrint(&args, "{{\"url\":\"file://{s}\",\"ephemeral\":true,\"width\":800,\"height\":600}}", .{path}) catch unreachable);
    const opened = m.recvLine(60_000);
    if (std.mem.indexOf(u8, opened, "isError") != null) fail("hand fixture failed to open");
    const view = viewHandleOf(opened);

    // 1. The first frame comes back as a JPEG of the logical viewport.
    const first = m.callTool("web_frame", "{\"timeout_ms\":5000}");
    if (std.mem.indexOf(u8, first, "\"mimeType\":\"image/jpeg\"") == null or
        std.mem.indexOf(u8, first, "\"unchanged\":false") == null or
        std.mem.indexOf(u8, first, "\"viewport_width\":800") == null)
    {
        say(first[0..@min(first.len, 600)]);
        fail("web_frame did not return the first frame as a JPEG of the viewport");
    }
    var serial = uintField(first, "frame") orelse fail("web_frame named no frame serial");
    if (serial == 0) fail("web_frame answered a frame with serial 0");

    // 2. Once the page has settled, asking past the frame already drawn answers unchanged, never that frame
    //    again; a late layout paint is simply the next frame to draw.
    var still_seen = false;
    var settle: usize = 0;
    while (settle < 10 and !still_seen) : (settle += 1) {
        const still = m.callTool("web_frame", std.fmt.bufPrint(&args, "{{\"since\":{d},\"timeout_ms\":400}}", .{serial}) catch unreachable);
        if (std.mem.indexOf(u8, still, "\"unchanged\":true") != null) {
            if (std.mem.indexOf(u8, still, "image/") != null) fail("an unchanged web_frame carried an image");
            still_seen = true;
        } else {
            const next = uintField(still, "frame") orelse fail("web_frame named no frame serial");
            if (next == serial) fail("web_frame answered the frame it was told was already drawn");
            serial = next;
        }
    }
    if (!still_seen) fail("web_frame never answered unchanged on a still page");

    // 3. Shift held across a click on the pad: the page sees a trusted shift-click and the release.
    // One line: the transport is newline-delimited JSON-RPC.
    const clicked = m.callTool("web_input", "{\"events\":[{\"type\":\"key\",\"action\":\"down\",\"key\":\"Shift\"}," ++
        "{\"type\":\"pointer\",\"action\":\"move\",\"x\":50,\"y\":40,\"modifiers\":[\"shift\"]}," ++
        "{\"type\":\"pointer\",\"action\":\"down\",\"x\":50,\"y\":40,\"modifiers\":[\"shift\"]}," ++
        "{\"type\":\"pointer\",\"action\":\"up\",\"x\":50,\"y\":40,\"modifiers\":[\"shift\"]}," ++
        "{\"type\":\"key\",\"action\":\"up\",\"key\":\"Shift\"}]}");
    if (std.mem.indexOf(u8, clicked, "\"sent\":5") == null) {
        say(clicked[0..@min(clicked.len, 600)]);
        fail("web_input did not send the shift-click batch");
    }
    var seen = false;
    var tries: usize = 0;
    while (tries < 40 and !seen) : (tries += 1) {
        const title = m.callTool("web_eval", "{\"code\":\"document.title + '|' + document.body.dataset.shift\"}");
        seen = std.mem.indexOf(u8, title, "down 50,40 shift trusted up|released") != null;
        if (!seen) _ = c.usleep(50_000);
    }
    if (!seen) fail("the page did not observe a trusted shift-click at 50,40 and the Shift release");

    // 4. The click repainted the pad: the next frame is newer than the still one.
    const after = m.callTool("web_frame", std.fmt.bufPrint(&args, "{{\"since\":{d},\"timeout_ms\":3000,\"format\":\"png\",\"max_width\":400}}", .{serial}) catch unreachable);
    if (std.mem.indexOf(u8, after, "\"unchanged\":false") == null or
        std.mem.indexOf(u8, after, "\"mimeType\":\"image/png\"") == null or
        std.mem.indexOf(u8, after, "\"width\":400") == null)
    {
        say(after[0..@min(after.len, 600)]);
        fail("web_frame did not answer the repaint the click caused, downscaled as asked");
    }
    if ((uintField(after, "frame") orelse 0) == serial) fail("web_frame answered the frame it was told was already drawn");

    // 5. Text lands at the caret of the field a click focused.
    const typed = m.callTool("web_input", "{\"events\":[{\"type\":\"pointer\",\"action\":\"down\",\"x\":100,\"y\":165}," ++
        "{\"type\":\"pointer\",\"action\":\"up\",\"x\":100,\"y\":165}," ++
        "{\"type\":\"text\",\"text\":\"h\\u00e9llo\"},{\"type\":\"key\",\"key\":\"!\"}]}");
    if (std.mem.indexOf(u8, typed, "isError") != null) {
        say(typed[0..@min(typed.len, 600)]);
        fail("web_input could not type into the field");
    }
    var value_ok = false;
    tries = 0;
    while (tries < 40 and !value_ok) : (tries += 1) {
        const value = m.callTool("web_eval", "{\"code\":\"document.getElementById('field').value\"}");
        value_ok = std.mem.indexOf(u8, value, "h\u{e9}llo!") != null;
        if (!value_ok) _ = c.usleep(50_000);
    }
    if (!value_ok) fail("text and a typed key did not land in the focused field");

    // 6. A wheel step over the page scrolls the document.
    _ = m.callTool("web_input", "{\"events\":[{\"type\":\"wheel\",\"x\":400,\"y\":400,\"dy\":600}]}");
    var scrolled = false;
    tries = 0;
    while (tries < 40 and !scrolled) : (tries += 1) {
        const y = m.callTool("web_eval", "{\"code\":\"String(scrollY > 0)\"}");
        scrolled = std.mem.indexOf(u8, y, "true") != null;
        if (!scrolled) _ = c.usleep(50_000);
    }
    if (!scrolled) fail("a web_input wheel step did not scroll the page");

    // 7. A refused batch sends nothing and says which event was wrong.
    const refused = m.callTool("web_input", "{\"events\":[{\"type\":\"pointer\",\"x\":1,\"y\":1},{\"type\":\"pointer\",\"action\":\"hover\",\"x\":1,\"y\":1}]}");
    if (std.mem.indexOf(u8, refused, "\"code\":\"invalid_args\"") == null or std.mem.indexOf(u8, refused, "events[1]") == null)
        fail("a bad web_input event was not refused by index");

    _ = m.callTool("web_close", std.fmt.bufPrint(&args, "{{\"pane\":{d}}}", .{view}) catch unreachable);
    say("smoke-mcp: hand-driven input (pointer, held keys, text, wheel) and the pulled frame stream ok");
}

const StreamRig = struct {
    allocator: std.mem.Allocator,
    fd: c_int = -1,
    packet: []u8 = &.{},
    pixels: []u8 = &.{},
    w: u32 = 0,
    h: u32 = 0,
    serial: u64 = 0,
    damage: frameflow.Damage = .{},
    cursor_seen: bool = false,
    audio_packets: usize = 0,
    audio_signal: bool = false,
    audio_pts: u64 = 0,
    decoder: ?opuscodec.Decoder = null,
    /// Surface the next SURFACE frame must announce: pixel w/h, logical w/h.
    expect: [4]u32 = .{ 800, 600, 800, 600 },
    /// The stream was opened encoded: ENCODED frames are expected and RAW
    /// damage is a failure (and the other way round).
    encoded: bool = false,
    recv: frameenc.Receiver = .{},
    video_parts: usize = 0,
    video_dropped: usize = 0,
    lossless_parts: usize = 0,
    /// Serial of the logical frame whose messages are still arriving.
    open_serial: ?u64 = null,

    fn connect(allocator: std.mem.Allocator, path: []const u8) StreamRig {
        var addr = std.mem.zeroes(c.struct_sockaddr_un);
        if (path.len >= addr.sun_path.len) fail("stream socket path too long");
        addr.sun_family = c.AF_UNIX;
        @memcpy(addr.sun_path[0..path.len], path);
        const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
        if (fd < 0) fail("stream socket");
        _ = c.fcntl(fd, c.F_SETFD, c.FD_CLOEXEC);
        _ = c.fcntl(fd, c.F_SETFL, c.O_NONBLOCK);
        const rc = c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un));
        if (rc != 0 and std.posix.errno(rc) != .INPROGRESS) fail("connect to helper stream");
        var pfd = c.struct_pollfd{ .fd = fd, .events = c.POLLOUT, .revents = 0 };
        if (c.poll(&pfd, 1, 3000) <= 0) fail("stream connect deadline");
        var err: c_int = 0;
        var len: c.socklen_t = @sizeOf(c_int);
        if (c.getsockopt(fd, c.SOL_SOCKET, c.SO_ERROR, &err, &len) != 0 or err != 0) fail("stream connect refused");
        return .{ .allocator = allocator, .fd = fd };
    }

    fn deinit(self: *StreamRig) void {
        self.disconnect();
        if (self.decoder) |*d| d.deinit();
        self.recv.deinit(self.allocator);
        self.allocator.free(self.packet);
        self.allocator.free(self.pixels);
    }

    fn disconnect(self: *StreamRig) void {
        if (self.fd >= 0) _ = c.close(self.fd);
        self.fd = -1;
    }

    fn send(self: *StreamRig, tag: webstream.Tag, body: []const u8) void {
        const bytes = self.allocator.alloc(u8, webstream.HEADER + body.len) catch fail("stream send allocation");
        defer self.allocator.free(bytes);
        std.mem.writeInt(u32, bytes[0..4], @intCast(body.len + 1), .little);
        bytes[4] = @intFromEnum(tag);
        @memcpy(bytes[5..], body);
        // The same strict codec validates every smoke input before it is sent.
        _ = webstream.decode(bytes[4], body) catch fail("invalid smoke stream input");
        var off: usize = 0;
        const deadline = nowMs() + 3000;
        while (off < bytes.len) {
            const n = c.write(self.fd, bytes.ptr + off, bytes.len - off);
            if (n > 0) {
                off += @intCast(n);
                continue;
            }
            if (n == 0 or nowMs() >= deadline) fail("stream send did not finish");
            const err = std.posix.errno(n);
            if (err != .AGAIN and err != .INTR) fail("stream send failed");
            var pfd = c.struct_pollfd{ .fd = self.fd, .events = c.POLLOUT, .revents = 0 };
            _ = c.poll(&pfd, 1, 20);
        }
    }

    fn readExact(self: *StreamRig, dst: []u8, deadline: i64) bool {
        var off: usize = 0;
        while (off < dst.len) {
            const n = c.recv(self.fd, dst.ptr + off, dst.len - off, 0);
            if (n > 0) {
                off += @intCast(n);
                continue;
            }
            if (n == 0) fail("stream closed during a frame");
            const err = std.posix.errno(n);
            if (err != .AGAIN and err != .INTR) fail("stream receive failed");
            const left = deadline - nowMs();
            if (left <= 0) {
                if (off != 0) fail("partial stream frame exceeded deadline");
                return false;
            }
            var pfd = c.struct_pollfd{ .fd = self.fd, .events = c.POLLIN, .revents = 0 };
            _ = c.poll(&pfd, 1, @intCast(@min(left, 100)));
        }
        return true;
    }

    fn next(self: *StreamRig, timeout_ms: i64) ?webstream.Tag {
        const deadline = nowMs() + timeout_ms;
        var head: [4]u8 = undefined;
        if (!self.readExact(&head, deadline)) return null;
        const n = std.mem.readInt(u32, &head, .little);
        if (n == 0 or n > webstream.MAX_FRAME) fail("invalid stream frame length");
        self.allocator.free(self.packet);
        self.packet = self.allocator.alloc(u8, 4 + @as(usize, n)) catch fail("stream frame allocation");
        @memcpy(self.packet[0..4], &head);
        if (!self.readExact(self.packet[4..], deadline)) fail("missing stream frame body");
        const raw = (webstream.split(self.packet) catch fail("invalid stream framing")) orelse fail("incomplete stream frame");
        const b = raw.body;
        const tag: webstream.Tag = @enumFromInt(raw.tag);
        switch (tag) {
            .surface => {
                if (self.open_serial != null) fail("SURFACE arrived inside an ENCODED logical frame");
                if (b.len != webstream.SURFACE_BODY or b[16] != webstream.FORMAT_BGRA_PREMUL) fail("invalid stream surface");
                self.w = std.mem.readInt(u32, b[0..4], .little);
                self.h = std.mem.readInt(u32, b[4..8], .little);
                if (self.w != self.expect[0] or self.h != self.expect[1] or std.mem.readInt(u32, b[8..12], .little) != self.expect[2] or
                    std.mem.readInt(u32, b[12..16], .little) != self.expect[3]) fail("stream surface coordinate spaces differ from requested viewport");
                self.allocator.free(self.pixels);
                self.pixels = self.allocator.alloc(u8, @as(usize, self.w) * self.h * 4) catch fail("stream pixels allocation");
                @memset(self.pixels, 0);
            },
            .encoded => {
                if (!self.encoded) fail("a raw stream sent an ENCODED frame");
                if (self.pixels.len == 0) fail("encoded frame before surface");
                const fe = webproto.FrameEncoded.decodeAlloc(b, self.allocator) catch fail("malformed ENCODED frame");
                defer self.allocator.free(fe.parts);
                if (fe.w != self.w or fe.h != self.h) fail("ENCODED frame geometry differs from the announced surface");
                if (self.open_serial) |open| {
                    if (fe.serial != open) fail("ENCODED messages of one logical frame changed serial");
                } else if (fe.serial <= self.serial) fail("ENCODED logical frame serials do not increase");
                for (fe.parts) |p| {
                    switch (p.kind) {
                        webproto.encoded_video => self.video_parts += 1,
                        webproto.encoded_lossless => self.lossless_parts += 1,
                        else => fail("unknown ENCODED part kind"),
                    }
                    const got = self.recv.apply(self.allocator, self.pixels, @intCast(self.w), @intCast(self.h), p) catch fail("ENCODED part decode allocation");
                    switch (got) {
                        .rect => |r| self.damage.add(r),
                        .dropped => self.video_dropped += 1,
                        .malformed => fail("ENCODED part does not describe pixels of the surface"),
                    }
                }
                if (fe.last == 0) {
                    self.open_serial = fe.serial;
                } else {
                    self.open_serial = null;
                    self.serial = fe.serial;
                    // The final message closes a logical frame exactly as
                    // FRAME_END closes a raw one.
                    return .frame_end;
                }
            },
            .damage => {
                if (self.encoded) fail("an encoded stream sent raw DAMAGE");
                if (b.len < webstream.DAMAGE_HEAD or self.pixels.len == 0) fail("damage before surface");
                const r = frameflow.Rect{
                    .x = std.mem.readInt(u32, b[0..4], .little),
                    .y = std.mem.readInt(u32, b[4..8], .little),
                    .w = std.mem.readInt(u32, b[8..12], .little),
                    .h = std.mem.readInt(u32, b[12..16], .little),
                };
                if (r.empty() or @as(u64, r.x) + r.w > self.w or @as(u64, r.y) + r.h > self.h or
                    b.len != webstream.DAMAGE_HEAD + @as(usize, r.w) * r.h * 4 or b.len - webstream.DAMAGE_HEAD > webstream.MAX_BAND_BYTES)
                    fail("stream damage is out of bounds or not tightly packed BGRA");
                const stride = @as(usize, r.w) * 4;
                for (0..r.h) |y| {
                    const off = ((@as(usize, r.y) + y) * self.w + r.x) * 4;
                    @memcpy(self.pixels[off..][0..stride], b[webstream.DAMAGE_HEAD + y * stride ..][0..stride]);
                }
                self.damage.add(r);
            },
            .frame_end => {
                if (self.encoded) fail("an encoded stream sent raw FRAME_END");
                if (b.len != webstream.FRAME_END_BODY) fail("invalid stream frame end");
                const serial = std.mem.readInt(u64, b[0..8], .little);
                if (serial != self.serial + 1) fail("stream frame serials are not contiguous");
                self.serial = serial;
            },
            .cursor => {
                if (b.len < 4 or b[0] > 1 or b[1] > 1) fail("invalid stream cursor");
                if (b[1] == 0) {
                    const len = std.mem.readInt(u16, b[2..4], .little);
                    if (b.len != 4 + @as(usize, len)) fail("invalid named cursor length");
                    if (b[0] == 1 and std.mem.eql(u8, b[4..], "crosshair")) self.cursor_seen = true;
                } else {
                    if (b.len < webstream.CURSOR_IMAGE_HEAD) fail("invalid image cursor length");
                    const w = std.mem.readInt(u32, b[2..6], .little);
                    const h = std.mem.readInt(u32, b[6..10], .little);
                    if (w > webstream.MAX_CURSOR_DIM or h > webstream.MAX_CURSOR_DIM or b.len != webstream.CURSOR_IMAGE_HEAD + @as(usize, w) * h * 4)
                        fail("invalid image cursor dimensions");
                }
            },
            .audio => {
                if (b.len <= webstream.AUDIO_HEAD or b.len > webstream.AUDIO_HEAD + opuscodec.MAX_PACKET) fail("invalid stream audio packet size");
                const pts = std.mem.readInt(u64, b[0..8], .little);
                const rate = std.mem.readInt(u32, b[8..12], .little);
                const samples = std.mem.readInt(u16, b[13..15], .little);
                if (rate != 48_000 or b[12] != 2 or samples != 960 or
                    (self.audio_packets != 0 and pts <= self.audio_pts)) fail("invalid stream audio format or monotonic capture time");
                self.audio_pts = pts;
                if (self.decoder == null) self.decoder = opuscodec.Decoder.init(rate, b[12]) orelse fail("advertised stream audio cannot be decoded with runtime Opus");
                var pcm: [opuscodec.MAX_DECODE_SAMPLES]i16 = undefined;
                const decoded = self.decoder.?.decode(b[15..], &pcm) orelse fail("stream Opus decode failed");
                if (decoded.len != 960 * 2 * 2) fail("stream Opus packet did not decode to 20ms stereo");
                for (pcm[0 .. decoded.len / 2]) |sample| if (@abs(@as(i32, sample)) > 200) {
                    self.audio_signal = true;
                    break;
                };
                self.audio_packets += 1;
            },
            else => fail("unexpected helper-to-client stream tag"),
        }
        return tag;
    }

    fn frame(self: *StreamRig) frameflow.Rect {
        const deadline = nowMs() + 5000;
        while (nowMs() < deadline) {
            if (self.next(@max(1, deadline - nowMs()))) |tag| if (tag == .frame_end)
                return self.damage.takeBounds() orelse fail("stream frame end had no damage");
        }
        fail("helper did not push the next painted stream frame");
    }

    fn ack(self: *StreamRig) void {
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, self.serial, .little);
        self.send(.ack, &b);
    }

    fn pointer(self: *StreamRig, action: webstream.PointerAction, x: i32, y: i32, mods: u32) void {
        var b: [15]u8 = undefined;
        b[0] = @intFromEnum(action);
        std.mem.writeInt(i32, b[1..5], x, .little);
        std.mem.writeInt(i32, b[5..9], y, .little);
        b[9] = 0;
        b[10] = 1;
        std.mem.writeInt(u32, b[11..15], mods, .little);
        self.send(.pointer, &b);
    }

    fn key(self: *StreamRig, action: webstream.KeyAction, name: []const u8, mods: u32) void {
        var b: [7 + webstream.MAX_KEY_NAME]u8 = undefined;
        b[0] = @intFromEnum(action);
        std.mem.writeInt(u32, b[1..5], mods, .little);
        std.mem.writeInt(u16, b[5..7], @intCast(name.len), .little);
        @memcpy(b[7..][0..name.len], name);
        self.send(.key, b[0 .. 7 + name.len]);
    }

    fn ended(self: *StreamRig) void {
        const deadline = nowMs() + 5000;
        var bytes: [65536]u8 = undefined;
        while (nowMs() < deadline) {
            const n = c.recv(self.fd, &bytes, bytes.len, 0);
            if (n == 0) return;
            if (n < 0 and std.posix.errno(n) != .AGAIN and std.posix.errno(n) != .INTR) return;
            var pfd = c.struct_pollfd{ .fd = self.fd, .events = c.POLLIN, .revents = 0 };
            _ = c.poll(&pfd, 1, 50);
        }
        fail("stream socket survived its owning view or MCP server");
    }
};

fn streamOffer(m: *Mcp, arena: std.mem.Allocator) std.json.ObjectMap {
    const deadline = nowMs() + 3000;
    while (nowMs() < deadline) {
        const line = m.callTool("web_stream", "{}");
        if (std.mem.indexOf(u8, line, "\"isError\":true") == null) return capSc(arena, line, "web_stream", false);
        if (std.mem.indexOf(u8, line, "\"code\":\"conflict\"") == null) {
            say(line);
            fail("real helper refused a supported web stream");
        }
        _ = c.usleep(20_000);
    }
    fail("closed stream never released its view slot");
}

fn streamPaint(m: *Mcp, color: []const u8) void {
    var args: [512]u8 = undefined;
    const line = m.callTool("web_eval", std.fmt.bufPrint(&args, "{{\"body\":\"block.style.background='{s}';await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));return true\"}}", .{color}) catch unreachable);
    if (std.mem.indexOf(u8, line, "isError") != null) fail("stream fixture mutation failed");
}

fn streamBlock(rig: *StreamRig, damage: frameflow.Rect, before: []const u8, bgra: [4]u8) void {
    if (damage.x != 40 or damage.y != 40 or damage.w != 20 or damage.h != 20) {
        std.debug.print("smoke-mcp: stream damage {d},{d} {d}x{d}\n", .{ damage.x, damage.y, damage.w, damage.h });
        fail("20x20 mutation did not produce exact stream damage");
    }
    var changed: usize = 0;
    for (0..rig.h) |y| for (0..rig.w) |x| {
        const off = (y * rig.w + x) * 4;
        const px = rig.pixels[off..][0..4];
        if (x >= 40 and x < 60 and y >= 40 and y < 60) {
            if (!std.mem.eql(u8, px, &bgra)) fail("stream damage did not carry the newest exact BGRA pixel");
        } else if (!std.mem.eql(u8, px, before[off..][0..4])) fail("stream changed pixels outside the 20x20 mutation");
        if (!std.mem.eql(u8, px, before[off..][0..4])) changed += 1;
    };
    if (changed != 400) fail("20x20 stream mutation did not change exactly 400 pixels");
}

fn streamInputEvidence(m: *Mcp, arena: std.mem.Allocator, wait_reply: []const u8) void {
    const line = m.callTool("web_eval", "{\"code\":\"({checks:window.streamChecks(),observed:window.seen,field_value:window.field.value,scroll_y:scrollY,active_element:document.activeElement.id||document.activeElement.tagName,goal:window.streamGoal,title:document.title})\",\"strict\":true,\"max_chars\":60000}");
    const result = capSc(arena, line, "stream input evidence", false);
    const value = result.get("value").?.object.get("value").?.object;
    const checks = value.get("checks").?.object;
    var failed = std.mem.indexOf(u8, wait_reply, "\"isError\":true") != null;
    const required = [_][]const u8{ "pointer_down", "pointer_up", "shift_down", "shift_up", "click", "field_down", "field_up", "text", "wheel", "scroll", "focus" };
    const release_phase = std.mem.eql(u8, value.get("goal").?.string, "stream-release-ok");
    for (required[0..if (release_phase) 4 else required.len]) |name| {
        const ok = if (checks.get(name)) |check| check == .bool and check.bool else false;
        if (!ok) {
            std.debug.print("smoke-mcp: stream input requirement failed: {s}\n", .{name});
            failed = true;
        }
    }
    if (!failed) return;
    say(wait_reply);
    say(line);
    fail("page did not observe every trusted stream input requirement");
}

const StreamPixelDiff = struct {
    count: usize = 0,
    bounds: ?frameflow.Rect = null,
};

fn streamPixelDiff(w: u32, h: u32, before: []const u8, after: []const u8, region: frameflow.Rect) StreamPixelDiff {
    const r = region.clip(w, h);
    var diff = StreamPixelDiff{};
    for (r.y..r.y + r.h) |y| for (r.x..r.x + r.w) |x| {
        const off = (y * w + x) * 4;
        if (std.mem.eql(u8, before[off..][0..4], after[off..][0..4])) continue;
        const pixel = frameflow.Rect{ .x = @intCast(x), .y = @intCast(y), .w = 1, .h = 1 };
        diff.count += 1;
        diff.bounds = if (diff.bounds) |b| b.unite(pixel) else pixel;
    };
    return diff;
}

/// Pixels of `px` (4 bytes each, `w` wide) equal to `want`, and their bounds.
fn streamColorBounds(px: []const u8, w: u32, h: u32, want: [4]u8) StreamPixelDiff {
    var out = StreamPixelDiff{};
    for (0..h) |y| for (0..w) |x| {
        if (!std.mem.eql(u8, px[(y * w + x) * 4 ..][0..4], &want)) continue;
        const r = frameflow.Rect{ .x = @intCast(x), .y = @intCast(y), .w = 1, .h = 1 };
        out.count += 1;
        out.bounds = if (out.bounds) |b| b.unite(r) else r;
    };
    return out;
}

/// The fixture's 20x20 logical green block must be exactly 40x40 at (80,80).
fn streamScaledBlock(px: []const u8, w: u32, h: u32, want: [4]u8, comptime what: []const u8) void {
    const g = streamColorBounds(px, w, h, want);
    const b = g.bounds orelse fail(what ++ ": the green block is missing at device scale 2");
    if (g.count != 1600 or b.x != 80 or b.y != 80 or b.w != 40 or b.h != 40) {
        std.debug.print("smoke-mcp: {s}: {d} green pixels, bounds {d},{d} {d}x{d}\n", .{ what, g.count, b.x, b.y, b.w, b.h });
        fail(what ++ ": the 20x20 logical block is not 40x40 physical pixels at (80,80)");
    }
}

/// The WebGL canvas occupies a distinct 64x64 logical rectangle, not a CSS colour substitute.
fn streamWebglPixels(px: []const u8, w: u32, h: u32, scale: u32, comptime what: []const u8) void {
    if (@import("builtin").os.tag != .linux) return;
    const g = streamColorBounds(px, w, h, .{ 255, 0, 255, 255 });
    const b = g.bounds orelse fail(what ++ ": WebGL pixels are missing");
    if (g.count != 4096 * scale * scale or b.x != 500 * scale or b.y != 40 * scale or b.w != 64 * scale or b.h != 64 * scale)
        fail(what ++ ": WebGL canvas does not contain the exact known-colour rectangle");
}

/// The primary helper serving `socket` (its CEF subprocesses carry `--type=`).
fn streamHelperPid(socket: []const u8) c.pid_t {
    var want_buf: [4200]u8 = undefined;
    const want = std.fmt.bufPrint(&want_buf, "--socket\x00{s}\x00", .{socket}) catch fail("helper socket path");
    const d = c.opendir("/proc") orelse fail("cannot list /proc");
    defer _ = c.closedir(d);
    while (c.readdir(d)) |ent| {
        const pid = std.fmt.parseInt(c.pid_t, std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name))), 10) catch continue;
        var path: [64]u8 = undefined;
        var buf: [16384]u8 = undefined;
        const argv = readSmall(std.fmt.bufPrint(&path, "/proc/{d}/cmdline", .{pid}) catch continue, &buf);
        if (std.mem.indexOf(u8, argv, want) != null and std.mem.indexOf(u8, argv, "--type=") == null) return pid;
    }
    fail("the stream's helper process was not found");
}

/// utime + stime of `pid`, in clock ticks.
fn procCpuTicks(pid: c.pid_t) u64 {
    var path: [64]u8 = undefined;
    var buf: [4096]u8 = undefined;
    const stat = readSmall(std.fmt.bufPrint(&path, "/proc/{d}/stat", .{pid}) catch unreachable, &buf);
    var it = std.mem.tokenizeScalar(u8, stat[(std.mem.lastIndexOfScalar(u8, stat, ')') orelse fail("helper stat")) + 1 ..], ' ');
    var ticks: u64 = 0;
    var i: usize = 0;
    while (it.next()) |field| : (i += 1) {
        if (i == 11 or i == 12) ticks += std.fmt.parseInt(u64, field, 10) catch fail("helper stat");
    }
    return ticks;
}

fn procRssKib(pid: c.pid_t) u64 {
    var path: [64]u8 = undefined;
    var buf: [8192]u8 = undefined;
    const status = readSmall(std.fmt.bufPrint(&path, "/proc/{d}/status", .{pid}) catch unreachable, &buf);
    const at = std.mem.indexOf(u8, status, "VmRSS:") orelse fail("helper has no VmRSS");
    const line = std.mem.sliceTo(status[at + 6 ..], '\n');
    return std.fmt.parseInt(u64, std.mem.trim(u8, line, " \tkB"), 10) catch fail("helper VmRSS");
}

fn procFds(pid: c.pid_t) usize {
    var path: [64:0]u8 = undefined;
    const d = c.opendir((std.fmt.bufPrintZ(&path, "/proc/{d}/fd", .{pid}) catch unreachable).ptr) orelse fail("helper fd list");
    defer _ = c.closedir(d);
    var n: usize = 0;
    while (c.readdir(d)) |_| n += 1;
    return n;
}

/// Read logical frames for `ms`, ACKing each; how many arrived.
fn streamPump(rig: *StreamRig, ms: i64) u32 {
    var n: u32 = 0;
    const end = nowMs() + ms;
    while (nowMs() < end) {
        const tag = rig.next(@max(1, @min(100, end - nowMs()))) orelse continue;
        if (tag != .frame_end) continue;
        _ = rig.damage.takeBounds();
        rig.ack();
        n += 1;
    }
    return n;
}

/// `encoding:"encoded"`: frames decode back to the exact page, animation
/// arrives (as video tiles when a codec was negotiated), lossless pixels
/// return when it stops, and a helper without the capability answers raw.
fn streamEncodedStage(allocator: std.mem.Allocator, arena: std.mem.Allocator, m: *Mcp, exe: [*:0]const u8, rt: []const u8, caps: std.json.ObjectMap) void {
    if (!caps.get("web_stream_encoded").?.bool) fail("built real helper did not negotiate stream-encoded");
    const path = std.fmt.allocPrint(arena, "{s}/stream-encoded.html", .{rt}) catch unreachable;
    // A solid page with an exact 20x20 block, and a whole-viewport canvas
    // that paints noise every animation frame while go() runs (hot AND
    // photographic: the video route when a codec was negotiated).
    const html = "<!doctype html><style>body{margin:0;overflow:hidden;background:#112233}#b{position:fixed;left:40px;top:40px;width:20px;height:20px;background:#00ff00}" ++
        "#c{position:fixed;left:0;top:0;display:none}</style><div id=b></div><canvas id=c width=800 height=600></canvas><script>" ++
        "const x=c.getContext('2d'),d=x.createImageData(800,600),u=new Uint32Array(d.data.buffer);let run=false;" ++
        "function tick(){if(!run)return;for(let i=0;i<u.length;i++)u[i]=(Math.random()*16777215)|0xff000000;x.putImageData(d,0,0);requestAnimationFrame(tick)}" ++
        "window.go=()=>{run=true;c.style.display='block';requestAnimationFrame(tick)};window.halt=()=>{run=false;c.style.display='none'};</script>";
    @import("util/atomicwrite.zig").writeFileExact(path, html, 0o600) catch fail("write encoded stream fixture");
    var args: [1024]u8 = undefined;
    m.sendTool("web_open", std.fmt.bufPrint(&args, "{{\"url\":\"file://{s}\",\"width\":800,\"height\":600,\"snapshot\":\"none\"}}", .{path}) catch unreachable);
    _ = capSc(arena, m.recvLine(60_000), "encoded stream fixture open", false);

    // Offer every codec this process decodes, in vcodec's default order.
    var names: [vcodec.CodecList.cap][]const u8 = undefined;
    const decodable = vcodec.decodableHere();
    var list: []const u8 = "";
    for (decodable.names(&names), 0..) |n, i| list = std.fmt.allocPrint(arena, "{s}{s}\"{s}\"", .{ list, if (i > 0) "," else "", n }) catch unreachable;
    const offer = capSc(arena, m.callTool("web_stream", std.fmt.bufPrint(&args, "{{\"audio\":false,\"encoding\":\"encoded\",\"video_codecs\":[{s}]}}", .{list}) catch unreachable), "encoded web_stream", false);
    if (!std.mem.eql(u8, offer.get("encoding").?.string, "encoded")) fail("a stream-encoded helper answered an encoded open with a raw stream");
    const codec = offer.get("video_codec").?;
    if (codec != .null and vcodec.codecFromName(codec.string) == null) fail("encoded stream named an unknown video codec");
    if (codec != .null and !decodable.contains(vcodec.codecFromName(codec.string).?)) fail("encoded stream picked a codec the consumer did not offer");
    std.debug.print("smoke-mcp: encoded stream offered [{s}], helper picked {s}\n", .{ list, if (codec == .null) "lossless only" else codec.string });

    var rig = StreamRig.connect(allocator, offer.get("socket_path").?.string);
    defer rig.deinit();
    rig.encoded = true;
    rig.send(.auth, offer.get("token").?.string);
    const full = rig.frame();
    if (full.x != 0 or full.y != 0 or full.w != 800 or full.h != 600) fail("first encoded frame is not the whole surface");
    rig.ack();
    _ = streamPump(&rig, 600);
    if (!std.mem.eql(u8, rig.pixels[0..4], &.{ 0x33, 0x22, 0x11, 0xff })) fail("encoded frames did not decode to the page's solid colour");
    const green = streamColorBounds(rig.pixels, rig.w, rig.h, .{ 0, 255, 0, 255 });
    if (green.count != 400 or green.bounds.?.x != 40 or green.bounds.?.y != 40) fail("encoded frames did not decode the exact 20x20 block");

    // Animated content arrives, and keeps arriving under the ACK window.
    _ = capSc(arena, m.callTool("web_eval", "{\"code\":\"go(),true\"}"), "start encoded animation", false);
    const before = allocator.dupe(u8, rig.pixels) catch fail("encoded baseline");
    defer allocator.free(before);
    const frames = streamPump(&rig, 3000);
    const moved = streamPixelDiff(rig.w, rig.h, before, rig.pixels, .{ .x = 0, .y = 0, .w = 800, .h = 600 });
    std.debug.print("smoke-mcp: encoded animation: {d} logical frames in 3s, {d} video parts ({d} dropped), {d} lossless parts\n", .{ frames, rig.video_parts, rig.video_dropped, rig.lossless_parts });
    if (frames < 10 or moved.count < 800 * 600 / 2) fail("animated content did not arrive on the encoded stream");
    if (codec != .null and (rig.video_parts == 0 or rig.video_dropped == rig.video_parts)) fail("a negotiated codec produced no decodable video tile for animated noise");
    // Video is lossy: once the animation stops, the first lossless frame
    // repaints the whole surface and the page is exact again.
    _ = capSc(arena, m.callTool("web_eval", "{\"code\":\"halt(),true\"}"), "stop encoded animation", false);
    _ = streamPump(&rig, 1500);
    if (!std.mem.eql(u8, rig.pixels[0..4], &.{ 0x33, 0x22, 0x11, 0xff }) or
        !std.mem.eql(u8, rig.pixels[(599 * 800 + 799) * 4 ..][0..4], &.{ 0x33, 0x22, 0x11, 0xff }) or
        streamColorBounds(rig.pixels, rig.w, rig.h, .{ 0, 255, 0, 255 }).count != 400)
        fail("the stream did not settle back to exact lossless pixels after the animation");
    rig.disconnect();
    _ = capSc(arena, m.callTool("web_close", "{}"), "encoded stream view close", false);

    // A helper without the capability ignores the request: raw, and said so.
    _ = c.setenv("SKETERM_WEB_DISABLE_STREAM_ENCODED", "1", 1);
    defer _ = c.unsetenv("SKETERM_WEB_DISABLE_STREAM_ENCODED");
    var old = Mcp.spawn(allocator, exe, &.{});
    defer old.closeStdinWait();
    old.initialize();
    old.sendTool("web_open", std.fmt.bufPrint(&args, "{{\"url\":\"file://{s}\",\"width\":800,\"height\":600,\"snapshot\":\"none\"}}", .{path}) catch unreachable);
    _ = capSc(arena, old.recvLine(60_000), "raw-only helper open", false);
    if (capSc(arena, old.callTool("capabilities", "{}"), "raw-only preflight", false).get("web_stream_encoded").?.bool) fail("withheld stream-encoded was still reported");
    const raw_line = old.callTool("web_stream", "{\"audio\":false,\"encoding\":\"encoded\"}");
    const raw_offer = capSc(arena, raw_line, "encoded open on a raw-only helper", false);
    if (!std.mem.eql(u8, raw_offer.get("encoding").?.string, "raw") or std.mem.indexOf(u8, raw_line, "RAW BGRA") == null) fail("a raw-only helper's stream was not reported raw");
    var raw_rig = StreamRig.connect(allocator, raw_offer.get("socket_path").?.string);
    defer raw_rig.deinit();
    raw_rig.send(.auth, raw_offer.get("token").?.string);
    _ = raw_rig.frame();
    if (!std.mem.eql(u8, raw_rig.pixels[0..4], &.{ 0x33, 0x22, 0x11, 0xff })) fail("raw fallback stream is not the page");
    raw_rig.disconnect();
    _ = capSc(arena, old.callTool("web_close", "{}"), "raw-only view close", false);
    say("smoke-mcp: REAL encoded stream: exact solid colour and block decoded, animation arrived, lossless settle, raw fallback on a helper without stream-encoded ok");
}

/// Device scale 2 on the CPU path: DPR, screenshot, stream surface and pixels, then resize.
fn streamScaleStage(allocator: std.mem.Allocator, arena: std.mem.Allocator, m: *Mcp, path: []const u8) void {
    var args: [1024]u8 = undefined;
    m.sendTool("web_open", std.fmt.bufPrint(&args, "{{\"url\":\"file://{s}\",\"ephemeral\":true,\"width\":800,\"height\":600,\"device_scale_factor\":2,\"snapshot\":\"none\"}}", .{path}) catch unreachable);
    _ = capSc(arena, m.recvLine(60_000), "scale 2 stream fixture open", false);
    const dpr_code = "{\"code\":\"[devicePixelRatio,innerWidth,innerHeight].join('x')\"}";
    const dpr = capSc(arena, m.callTool("web_eval", dpr_code), "scale 2 page metrics", false);
    const dpr_s = dpr.get("value").?.object.get("value").?.string;
    if (!std.mem.eql(u8, dpr_s, "2x800x600")) {
        std.debug.print("smoke-mcp: scale 2 page metrics {s}\n", .{dpr_s});
        fail("scale 2 page does not lay out at DPR 2 over an 800x600 viewport");
    }

    inline for (.{ "web_screenshot", "web_frame" }) |tool| {
        const shot_line = m.callTool(tool, if (std.mem.eql(u8, tool, "web_frame")) "{\"format\":\"png\",\"max_width\":1600,\"timeout_ms\":5000}" else "{}");
        _ = capSc(arena, shot_line, "scale 2 " ++ tool, false);
        const shot = std.json.parseFromSliceLeaky(std.json.Value, arena, shot_line, .{}) catch fail("scale 2 image: reply is not JSON");
        var png_bytes: ?[]u8 = null;
        for (shot.object.get("result").?.object.get("content").?.array.items) |item| {
            if (!std.mem.eql(u8, item.object.get("type").?.string, "image")) continue;
            const b64 = item.object.get("data").?.string;
            const dec = std.base64.standard.Decoder;
            const buf = arena.alloc(u8, dec.calcSizeForSlice(b64) catch fail("scale 2 screenshot base64")) catch fail("scale 2 screenshot allocation");
            dec.decode(buf, b64) catch fail("scale 2 screenshot base64");
            png_bytes = buf;
        }
        const img = @import("util/png.zig").decodeRgba(arena, png_bytes orelse fail("scale 2 screenshot carried no image")) catch fail("scale 2 screenshot PNG decode");
        if (img.w != 1600 or img.h != 1200) {
            std.debug.print("smoke-mcp: scale 2 screenshot {d}x{d}\n", .{ img.w, img.h });
            fail("scale 2 screenshot is not 1600x1200 physical pixels");
        }
        streamScaledBlock(img.rgba, img.w, img.h, .{ 0, 255, 0, 255 }, "scale 2 " ++ tool);
        streamWebglPixels(img.rgba, img.w, img.h, 2, "scale 2 " ++ tool);
    }

    const offer = streamOffer(m, arena);
    var rig = StreamRig.connect(allocator, offer.get("socket_path").?.string);
    defer rig.deinit();
    rig.expect = .{ 1600, 1200, 800, 600 };
    rig.send(.auth, offer.get("token").?.string);
    const full = rig.frame();
    if (full.x != 0 or full.y != 0 or full.w != 1600 or full.h != 1200) fail("scale 2 first stream frame is not the full 1600x1200 surface");
    rig.ack();
    while (rig.next(300)) |tag| if (tag == .frame_end) {
        _ = rig.damage.takeBounds();
        rig.ack();
    };
    if (!std.mem.eql(u8, rig.pixels[0..4], &.{ 0x33, 0x22, 0x11, 0xff })) fail("scale 2 stream frame is not the real page");
    streamScaledBlock(rig.pixels, rig.w, rig.h, .{ 0, 255, 0, 255 }, "scale 2 stream");
    streamWebglPixels(rig.pixels, rig.w, rig.h, 2, "scale 2 stream");

    // A resize keeps the scale: a 400x300 viewport is an 800x600 surface.
    rig.expect = .{ 800, 600, 400, 300 };
    const resized = m.callTool("web_resize", "{\"width\":400,\"height\":300}");
    _ = capSc(arena, resized, "scale 2 resize", false);
    const deadline = nowMs() + 5000;
    var settled = false;
    while (!settled and nowMs() < deadline) {
        const tag = rig.next(300) orelse continue;
        if (tag != .frame_end) continue;
        _ = rig.damage.takeBounds();
        rig.ack();
        settled = rig.w == 800 and streamColorBounds(rig.pixels, rig.w, rig.h, .{ 0, 255, 0, 255 }).count == 1600;
    }
    if (rig.w != 800 or rig.h != 600) fail("scale 2 resize did not announce an 800x600 stream surface");
    streamScaledBlock(rig.pixels, rig.w, rig.h, .{ 0, 255, 0, 255 }, "scale 2 resized stream");
    const after = capSc(arena, m.callTool("web_eval", dpr_code), "scale 2 resized page metrics", false);
    if (!std.mem.eql(u8, after.get("value").?.object.get("value").?.string, "2x400x300"))
        fail("scale 2 page did not keep DPR 2 over a 400x300 viewport after resize");
    _ = capSc(arena, m.callTool("web_close", "{}"), "scale 2 view teardown", false);
    rig.ended();
    say("smoke-mcp: REAL scale 2 CPU view: DPR 2, 1600x1200 screenshot/frame/stream pixels, resize to 800x600 at DPR 2 ok");
}

/// The existing binary reader measures CEF's cap, not a client-side timer or a JSON frame rate.
fn streamFpsStage(allocator: std.mem.Allocator, arena: std.mem.Allocator, m: *Mcp, exe: [*:0]const u8, rt: []const u8) void {
    const path = std.fmt.allocPrint(arena, "{s}/stream-fps.html", .{rt}) catch unreachable;
    @import("util/atomicwrite.zig").writeFileExact(path, "<!doctype html><style>body{margin:0;background:#112233}div{width:50px;height:50px;background:red;animation:slide 1s linear infinite}@keyframes slide{to{transform:translateX(200px)}}</style><div></div>", 0o600) catch fail("write FPS fixture");
    var args: [1024]u8 = undefined;
    var views: [3]u32 = undefined;
    for ([_]u16{ 15, 30, 60 }, 0..) |fps, i| {
        m.sendTool("web_open", std.fmt.bufPrint(&args, "{{\"url\":\"file://{s}\",\"width\":800,\"height\":600,\"snapshot\":\"none\",\"max_fps\":{d}}}", .{ path, fps }) catch unreachable);
        const opened = capSc(arena, m.recvLine(60_000), "FPS fixture open", false);
        if (capInt(opened, "max_fps") != fps) fail("open did not report the requested CEF cap");
        views[i] = @intCast(capInt(opened, "view"));
    }
    // All three animated views stay alive while each stream is sampled.
    for ([_]u16{ 15, 30, 60 }, 0..) |fps, i| {
        const line = m.callTool("web_stream", std.fmt.bufPrint(&args, "{{\"pane\":{d},\"audio\":false}}", .{views[i]}) catch unreachable);
        const offer = capSc(arena, line, "FPS stream offer", false);
        if (capInt(offer, "max_fps") != fps) fail("stream did not preserve its view's cap");
        var rig = StreamRig.connect(allocator, offer.get("socket_path").?.string);
        rig.send(.auth, offer.get("token").?.string);
        _ = rig.frame();
        rig.ack();
        const start = nowMs();
        var count: u32 = 0;
        while (nowMs() - start < 2100) {
            const tag = rig.next(100) orelse continue;
            if (tag != .frame_end) continue;
            _ = rig.damage.takeBounds();
            rig.ack();
            count += 1;
        }
        const actual = @as(f64, @floatFromInt(count)) * 1000 / @as(f64, @floatFromInt(nowMs() - start));
        std.debug.print("smoke-mcp: CSS stream view {d}: cap {d}, measured {d:.2} FPS\n", .{ views[i], fps, actual });
        if (actual < @as(f64, @floatFromInt(fps)) * 0.75 or actual > @as(f64, @floatFromInt(fps)) * 1.2) fail("CSS stream FPS does not match the per-view CEF cap");
        rig.deinit();
    }
    for (views) |view| _ = capSc(arena, m.callTool("web_close", std.fmt.bufPrint(&args, "{{\"pane\":{d}}}", .{view}) catch unreachable), "FPS view close", false);

    const config = std.fmt.allocPrint(arena, "{s}/config/sketerm/config.conf", .{rt}) catch unreachable;
    @import("util/pathz.zig").makeParentDirs(config) catch fail("FPS config parent");
    @import("util/atomicwrite.zig").writeFileExact(config, "[mcp]\nweb_max_fps = 30\n[mcp.streamfps]\nweb_max_fps = 15\n", 0o600) catch fail("write FPS config");
    var z: [4096:0]u8 = undefined;
    defer _ = c.unlink(pathz.pathZ(&z, config) catch unreachable);
    var configured = Mcp.spawn(allocator, exe, &.{ "--profile", "streamfps" });
    configured.initialize();
    const caps = capSc(arena, configured.callTool("capabilities", "{}"), "configured FPS preflight", false);
    if (capInt(caps, "web_default_max_fps") != 15) fail("named MCP FPS profile did not override the bare config");
    configured.sendTool("web_open", std.fmt.bufPrint(&args, "{{\"url\":\"file://{s}\",\"width\":800,\"height\":600,\"snapshot\":\"none\"}}", .{path}) catch unreachable);
    if (capInt(capSc(arena, configured.recvLine(60_000), "configured FPS open", false), "max_fps") != 15) fail("configured FPS did not propagate into the new view");
    _ = capSc(arena, configured.callTool("web_close", "{}"), "configured FPS close", false);
    configured.closeStdinWait();
    _ = c.unlink(pathz.pathZ(&z, config) catch unreachable);
    _ = c.setenv("SKETERM_WEB_DISABLE_MAX_FPS", "1", 1);
    defer _ = c.unsetenv("SKETERM_WEB_DISABLE_MAX_FPS");
    var unsupported = Mcp.spawn(allocator, exe, &.{});
    unsupported.initialize();
    const refused = capSc(arena, unsupported.callTool("web_open", "{\"url\":\"about:blank\",\"max_fps\":15,\"snapshot\":\"none\"}"), "unsupported FPS open", true);
    if (!std.mem.eql(u8, refused.get("error").?.object.get("code").?.string, "unavailable")) fail("unsupported FPS open did not fail closed");
    if (capInt(capSc(arena, unsupported.callTool("web_tabs", "{}"), "unsupported FPS empty views", false), "count") != 0) fail("unsupported FPS request minted a view");
    unsupported.sendTool("web_open", "{\"url\":\"about:blank\",\"snapshot\":\"none\"}");
    _ = capSc(arena, unsupported.recvLine(60_000), "legacy helper default open", false);
    const stream_refused = capSc(arena, unsupported.callTool("web_stream", "{\"max_fps\":30}"), "unsupported FPS stream", true);
    if (!std.mem.eql(u8, stream_refused.get("error").?.object.get("code").?.string, "unavailable")) fail("unsupported FPS stream did not fail closed");
    _ = capSc(arena, unsupported.callTool("web_close", "{}"), "legacy FPS close", false);
    unsupported.closeStdinWait();
    say("smoke-mcp: per-view FPS, config/profile propagation and unsupported-helper refusals ok");
}

/// Real CEF streams keep painting and accepting trusted input while MCP itself is waiting.
fn webStreamStage(allocator: std.mem.Allocator, exe: [*:0]const u8, rt: []const u8) void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var m = Mcp.spawn(allocator, exe, if (c.getenv("SKETERM_SMOKE_MCP_WEBSTREAM_NAMED") != null) &.{ "--name", "stream-webgl" } else &.{});
    m.initialize();
    const before_caps = capSc(arena, m.callTool("capabilities", "{}"), "stream preflight", false);
    if (!before_caps.get("web_stream").?.bool or before_caps.get("web_stream_audio").? != .null or before_caps.get("web_software_webgl").? != .null)
        fail("stream preflight fabricated negotiated audio before startup");
    var args: [2048]u8 = undefined;
    const path = std.fmt.allocPrint(arena, "{s}/stream-fixture.html", .{rt}) catch fail("stream fixture path");
    const html = "<!doctype html><html><head><title>stream-ready</title><style>body{margin:0;height:4000px;background:#112233}" ++
        "#block{position:fixed;left:40px;top:40px;width:20px;height:20px;background:#00ff00}" ++
        "#pad{position:fixed;left:200px;top:40px;width:80px;height:60px;background:#445566;cursor:crosshair}" ++
        "#field{position:fixed;left:40px;top:150px;width:180px;height:30px}" ++
        "#gl{position:fixed;left:500px;top:40px;width:64px;height:64px}" ++
        "#select{position:fixed;left:300px;top:150px;width:180px;height:30px}</style></head><body>" ++
        "<canvas id=gl width=64 height=64></canvas><div id=block></div><div id=pad></div><input id=field><select id=select><option>first</option><option>second</option><option>third</option></select><script>" ++
        "window.gl=document.getElementById('gl').getContext('webgl',{preserveDrawingBuffer:true});" ++
        "if(window.gl){gl.clearColor(1,0,1,1);gl.clear(gl.COLOR_BUFFER_BIT);gl.finish()}" ++
        "window.block=document.getElementById('block');window.pad=document.getElementById('pad');window.field=document.getElementById('field');" ++
        "window.seen={pad_down:null,pad_up:null,click:null,field_down:null,field_up:null,shift_down:null,shift_up:null,wheel:null," ++
        "pad_down_count:0,pad_up_count:0,field_down_count:0,field_up_count:0,shift_down_count:0,shift_up_count:0,text_events:0,text_trusted:true,scroll_events:0,events:[]};" ++
        "window.streamGoal='stream-input-ok';window.streamInitialScrollY=scrollY;" ++
        "window.streamChecks=()=>{const s=window.seen,down=s.pad_down,up=s.pad_up,kd=s.shift_down,ku=s.shift_up;" ++
        "const base=window.streamReleaseBase||{pad_down:0,pad_up:0,shift_down:0,shift_up:0};const c={" ++
        "pointer_down:s.pad_down_count===base.pad_down+1&&!!down&&down.trusted&&down.shift&&down.x===230&&down.y===60&&down.button===0&&down.buttons===1," ++
        "pointer_up:s.pad_up_count===base.pad_up+1&&!!up&&up.trusted&&up.x===230&&up.y===60&&up.button===0&&up.buttons===0," ++
        "shift_down:s.shift_down_count===base.shift_down+1&&!!kd&&kd.trusted&&kd.key==='Shift'&&kd.shift," ++
        "shift_up:s.shift_up_count===base.shift_up+1&&!!ku&&ku.trusted&&ku.key==='Shift'&&!ku.shift};" ++
        "if(window.streamGoal==='stream-release-ok')return c;" ++
        "const click=s.click,fd=s.field_down,fu=s.field_up,w=s.wheel;return Object.assign(c,{" ++
        "click:!!click&&click.trusted&&click.shift&&click.x===230&&click.y===60&&click.button===0," ++
        "field_down:s.field_down_count===1&&!!fd&&fd.trusted&&fd.x===100&&fd.y===165&&!fd.shift&&fd.buttons===1," ++
        "field_up:s.field_up_count===1&&!!fu&&fu.trusted&&fu.x===100&&fu.y===165&&!fu.shift&&fu.buttons===0," ++
        "text:s.text_events>0&&s.text_trusted&&window.field.value==='stream text'," ++
        "wheel:!!w&&w.trusted&&w.x===400&&w.y===400&&w.dy>0&&!w.shift&&w.buttons===0," ++
        "scroll:s.scroll_events>0&&scrollY>window.streamInitialScrollY,focus:document.activeElement===window.field})};" ++
        "function done(){if(Object.values(window.streamChecks()).every(Boolean))document.title=window.streamGoal}" ++
        "function remember(e){const r={type:e.type,target:e.target.id||e.target.nodeName||'window',trusted:e.isTrusted," ++
        "x:e.clientX??null,y:e.clientY??null,key:e.key||'',shift:!!e.shiftKey,button:e.button??null,buttons:e.buttons??null," ++
        "dx:e.deltaX??null,dy:e.deltaY??null,value:window.field.value,scroll_y:scrollY};" ++
        "window.seen.events.push(r);if(window.seen.events.length>64)window.seen.events.shift();return r}" ++
        "for(const type of ['pointerdown','pointerup','click','keydown','keyup','input','wheel','scroll','focusin'])addEventListener(type,e=>{" ++
        "const s=window.seen,r=remember(e);if(e.target===window.pad){" ++
        "if(type==='pointerdown'){s.pad_down=r;s.pad_down_count++}if(type==='pointerup'){s.pad_up=r;s.pad_up_count++}if(type==='click')s.click=r}" ++
        "if(e.target===window.field){if(type==='pointerdown'){s.field_down=r;s.field_down_count++}if(type==='pointerup'){s.field_up=r;s.field_up_count++}" ++
        "if(type==='input'){s.text_events++;s.text_trusted=s.text_trusted&&e.isTrusted}}" ++
        "if(e.key==='Shift'){if(type==='keydown'){s.shift_down=r;s.shift_down_count++}if(type==='keyup'){s.shift_up=r;s.shift_up_count++}}" ++
        "if(type==='wheel')s.wheel=r;if(type==='scroll')s.scroll_events++;done()},true);" ++
        "pad.addEventListener('click',e=>{if(e.isTrusted&&!window.audio){window.audio=new AudioContext({sampleRate:48000});" ++
        "const o=audio.createOscillator(),g=audio.createGain();g.gain.value=.25;o.frequency.value=440;o.connect(g).connect(audio.destination);o.start();audio.resume()}});" ++
        "</script></body></html>";
    @import("util/atomicwrite.zig").writeFileExact(path, html, 0o600) catch fail("write stream fixture");
    m.sendTool("web_open", std.fmt.bufPrint(&args, "{{\"url\":\"file://{s}\",\"ephemeral\":true,\"width\":800,\"height\":600,\"snapshot\":\"none\"}}", .{path}) catch unreachable);
    _ = capSc(arena, m.recvLine(60_000), "stream fixture open", false);
    const default_rate = capSc(arena, m.callTool("capabilities", "{}"), "default FPS preflight", false);
    if (!default_rate.get("web_max_fps").?.bool or capInt(default_rate, "web_default_max_fps") != 60) fail("headless default is not the configured CEF cap of 60 FPS");
    if (@import("builtin").os.tag == .linux) {
        const gl_probe = m.callTool("web_eval", "{\"body\":\"if(!window.gl)return {webgl:false};const d=gl.getExtension('WEBGL_debug_renderer_info');return {webgl:true,renderer:d?gl.getParameter(d.UNMASKED_RENDERER_WEBGL):gl.getParameter(gl.RENDERER),version:gl.getParameter(gl.VERSION)}\",\"strict\":true}");
        const gl_value = capSc(arena, gl_probe, "WebGL renderer", false).get("value").?.object.get("value").?.object;
        if (!gl_value.get("webgl").?.bool) {
            say(gl_probe);
            fail("ordinary MCP CPU view lost WebGL");
        }
        const renderer = gl_value.get("renderer").?.string;
        std.debug.print("smoke-mcp: WebGL renderer: {s}; version: {s}\n", .{ renderer, gl_value.get("version").?.string });
        if (std.mem.indexOf(u8, renderer, "SwiftShader") == null) fail("MCP WebGL did not use the requested software renderer");
    }
    const caps = capSc(arena, m.callTool("capabilities", "{}"), "stream handshake", false);
    if (!caps.get("web_stream").?.bool) fail("built real helper did not negotiate web-stream");
    if (@import("builtin").os.tag == .linux and !caps.get("web_software_webgl").?.bool) fail("ordinary helper did not report its software WebGL policy");
    const audio = caps.get("web_stream_audio").?.bool;
    const offer = streamOffer(&m, arena);
    if (offer.get("audio").?.bool != audio or capInt(offer, "protocol_version") != 1 or capInt(offer, "max_unacked_frames") != 2 or
        !std.mem.eql(u8, offer.get("pixel_format").?.string, "bgra-premultiplied")) fail("web_stream result differs from negotiated V1 contract");
    // The default stays the raw V1 stream; StreamRig fails on any ENCODED frame.
    if (!std.mem.eql(u8, offer.get("encoding").?.string, "raw") or offer.get("video_codec") != null) fail("a default web_stream is not raw");
    const socket_path = offer.get("socket_path").?.string;
    const token = offer.get("token").?.string;
    const helper_socket = caps.get("web_socket").?.string;
    const dir_end = std.mem.lastIndexOfScalar(u8, helper_socket, '/') orelse fail("helper has no instance socket directory");
    if (!std.mem.startsWith(u8, socket_path, helper_socket[0 .. dir_end + 1]) or
        std.mem.indexOfScalar(u8, socket_path[dir_end + 1 ..], '/') != null)
        fail("stream socket was not placed directly in this MCP instance directory");
    if (!webstream.isToken(token)) fail("web_stream returned an invalid token");
    var rig = StreamRig.connect(allocator, socket_path);
    defer rig.deinit();
    rig.send(.auth, token);
    const full = rig.frame();
    if (full.x != 0 or full.y != 0 or full.w != 800 or full.h != 600 or !std.mem.eql(u8, rig.pixels[0..4], &.{ 0x33, 0x22, 0x11, 0xff }))
        fail("first stream frame was not the full real page");
    rig.ack();
    // Late layout paints are consumed before the exact damage assertion.
    while (rig.next(300)) |tag| if (tag == .frame_end) {
        _ = rig.damage.takeBounds();
        rig.ack();
    };
    const linux = @import("builtin").os.tag == .linux;
    const helper = if (linux) streamHelperPid(helper_socket) else 0;
    if (linux) {
        // A still page streams nothing and costs the helper almost no CPU.
        const ticks = procCpuTicks(helper);
        const idle_end = nowMs() + 1500;
        while (nowMs() < idle_end) if (rig.next(idle_end - nowMs())) |tag| if (tag == .damage or tag == .frame_end) fail("a still page pushed a stream frame");
        const idle = procCpuTicks(helper) - ticks;
        std.debug.print("smoke-mcp: idle stream helper CPU: {d} ticks in 1.5s\n", .{idle});
        if (idle >= 30) fail("the helper spins while its stream is idle");
    }
    if (linux) {
        streamWebglPixels(rig.pixels, rig.w, rig.h, 1, "binary stream");
        inline for (.{ "web_screenshot", "web_frame" }) |tool| {
            const line = m.callTool(tool, if (std.mem.eql(u8, tool, "web_frame")) "{\"format\":\"png\",\"max_width\":800,\"timeout_ms\":5000}" else "{}");
            _ = capSc(arena, line, "WebGL " ++ tool, false);
            const result = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch fail("WebGL image JSON");
            var checked = false;
            for (result.object.get("result").?.object.get("content").?.array.items) |item| {
                if (!std.mem.eql(u8, item.object.get("type").?.string, "image")) continue;
                const b64 = item.object.get("data").?.string;
                const dec = std.base64.standard.Decoder;
                const bytes = arena.alloc(u8, dec.calcSizeForSlice(b64) catch fail("WebGL PNG base64")) catch fail("WebGL PNG allocation");
                dec.decode(bytes, b64) catch fail("WebGL PNG base64");
                const img = @import("util/png.zig").decodeRgba(arena, bytes) catch fail("WebGL PNG decode");
                streamWebglPixels(img.rgba, img.w, img.h, 1, tool);
                checked = true;
            }
            if (!checked) fail("WebGL screenshot/frame had no image");
        }
        // A subsequent WebGL clear must reach the existing pushed damage path too.
        _ = capSc(arena, m.callTool("web_eval", "{\"body\":\"gl.clearColor(0,1,1,1);gl.clear(gl.COLOR_BUFFER_BIT);gl.finish();await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));return true\"}"), "WebGL repaint", false);
        const gl_deadline = nowMs() + 5000;
        var gl_repaint = false;
        while (!gl_repaint and nowMs() < gl_deadline) {
            const tag = rig.next(100) orelse continue;
            if (tag != .frame_end) continue;
            _ = rig.damage.takeBounds();
            rig.ack();
            gl_repaint = std.mem.eql(u8, rig.pixels[(40 * rig.w + 500) * 4 ..][0..4], &.{ 255, 255, 0, 255 });
        }
        if (!gl_repaint) fail("WebGL repaint never reached binary stream CPU pixels");
        say("smoke-mcp: REAL SwiftShader WebGL: exact 64x64 magenta screenshot/frame/stream, subsequent cyan stream repaint ok");
    } else say("smoke-mcp: SwiftShader WebGL policy is Linux-only; existing stream journey still runs");
    if (fileExists(socket_path)) fail("stream token authentication did not unlink its single-use listener");
    const conflict = capSc(arena, m.callTool("web_stream", "{}"), "second stream conflict", true);
    if (!std.mem.eql(u8, conflict.get("error").?.object.get("code").?.string, "conflict")) fail("second stream was not refused as conflict");

    const baseline = allocator.dupe(u8, rig.pixels) catch fail("stream baseline");
    defer allocator.free(baseline);
    streamPaint(&m, "#ff0000");
    streamBlock(&rig, rig.frame(), baseline, .{ 0, 0, 255, 255 });
    // Withhold both frame ACKs; newer paints must merge without a third send.
    streamPaint(&m, "#0000ff");
    const second = rig.frame();
    if (second.x != 40 or second.y != 40 or second.w != 20 or second.h != 20) fail("second stream mutation damage differs");
    streamPaint(&m, "#00ffff");
    streamPaint(&m, "#ffff00");
    while (rig.next(300)) |tag| if (tag == .damage or tag == .frame_end or tag == .surface)
        fail("stream sent a third frame while two were unacknowledged");
    rig.ack();
    streamBlock(&rig, rig.frame(), baseline, .{ 0, 255, 255, 255 });
    rig.ack();
    if (linux) {
        // A reader that stopped ACKing under a fast-painting page costs the helper bounded memory.
        _ = capSc(arena, m.callTool("web_eval", "{\"body\":\"let h=0;window.iv=setInterval(()=>{block.style.background='hsl('+(h=(h+7)%360)+',80%,50%)'},5);return true\"}"), "stall painter", false);
        _ = rig.frame();
        _ = rig.frame();
        const rss = procRssKib(helper);
        var peak = rss;
        const stall_end = nowMs() + 3000;
        while (nowMs() < stall_end) {
            if (rig.next(250)) |tag| if (tag == .damage or tag == .frame_end or tag == .surface) fail("stream sent a third frame while two were unacknowledged");
            peak = @max(peak, procRssKib(helper));
        }
        _ = capSc(arena, m.callTool("web_eval", "{\"body\":\"clearInterval(window.iv);return true\"}"), "stall painter stop", false);
        rig.ack();
        while (rig.next(300)) |tag| if (tag == .frame_end) {
            _ = rig.damage.takeBounds();
            rig.ack();
        };
        std.debug.print("smoke-mcp: stalled stream helper RSS growth: {d} KiB\n", .{peak - rss});
        if (peak - rss >= 64 * 1024) fail("a stalled stream reader grew the helper");
    }

    // No more MCP requests can be dispatched until this wait finishes.
    m.sendTool("web_wait", "{\"for\":\"title\",\"arg\":\"stream-input-ok\",\"timeout_ms\":10000}");
    var pending = c.struct_pollfd{ .fd = m.from_child, .events = c.POLLIN, .revents = 0 };
    if (c.poll(&pending, 1, 200) > 0) fail("stream input wait completed before any stream input");
    rig.send(.focus, &.{1});
    rig.key(.down, "Shift", webstream.CEF_SHIFT);
    rig.pointer(.move, 230, 60, webstream.CEF_SHIFT);
    // Leave time for the crosshair callback before moving to the text field.
    const cursor_deadline = nowMs() + 2000;
    while (!rig.cursor_seen and nowMs() < cursor_deadline) {
        if (rig.next(100)) |tag| if (tag == .frame_end) {
            _ = rig.damage.takeBounds();
            rig.ack();
        };
    }
    if (!rig.cursor_seen) fail("CSS crosshair was not pushed on the stream");
    rig.pointer(.down, 230, 60, webstream.CEF_SHIFT);
    rig.pointer(.up, 230, 60, webstream.CEF_SHIFT);
    rig.key(.up, "Shift", 0);
    rig.pointer(.move, 100, 165, 0);
    rig.pointer(.down, 100, 165, 0);
    rig.pointer(.up, 100, 165, 0);
    rig.send(.text, "stream text");
    var wheel: [20]u8 = undefined;
    std.mem.writeInt(i32, wheel[0..4], 400, .little);
    std.mem.writeInt(i32, wheel[4..8], 400, .little);
    std.mem.writeInt(i32, wheel[8..12], 0, .little);
    std.mem.writeInt(i32, wheel[12..16], 600, .little);
    std.mem.writeInt(u32, wheel[16..20], 0, .little);
    rig.pointer(.move, 400, 400, 0);
    rig.send(.wheel, &wheel);
    const input_wait = arena.dupe(u8, m.recvLine(12_000)) catch fail("stream input wait reply");
    streamInputEvidence(&m, arena, input_wait);
    if (audio) {
        const deadline = nowMs() + 5000;
        while ((!rig.audio_signal or rig.audio_packets < 3) and nowMs() < deadline) {
            if (rig.next(100)) |tag| if (tag == .frame_end) {
                _ = rig.damage.takeBounds();
                rig.ack();
            };
        }
        if (!rig.audio_signal or rig.audio_packets < 3) fail("advertised stream audio produced no decoded WebAudio oscillator signal");
        say("smoke-mcp: stream WebAudio oscillator decoded as non-silent 20ms stereo Opus");
    } else say("smoke-mcp: stream audio unavailable at runtime (reported false, audio decode skipped)");

    rig.pointer(.move, 350, 165, 0);
    const focus = capSc(arena, m.callTool("web_eval", "{\"body\":\"window.field.blur();if(window.audio)await audio.suspend();document.getElementById('select').focus();await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));return document.activeElement.id\"}"), "focus closed select before popup baseline", false);
    if (!std.mem.eql(u8, focus.get("value").?.object.get("value").?.string, "select")) fail("popup baseline could not focus the closed select");
    // Match the keyboard focus indication Escape leaves after popup close.
    rig.key(.down, "Escape", 0);
    rig.key(.up, "Escape", 0);
    const settle_deadline = nowMs() + 3000;
    while (nowMs() < settle_deadline) {
        const tag = rig.next(300) orelse break;
        if (tag == .frame_end) {
            _ = rig.damage.takeBounds();
            rig.ack();
        }
    }
    const popup_base = allocator.dupe(u8, rig.pixels) catch fail("popup baseline");
    defer allocator.free(popup_base);
    const popup_roi = frameflow.Rect{ .x = 300, .y = 180, .w = 180, .h = 60 };
    rig.pointer(.down, 350, 165, 0);
    rig.pointer(.up, 350, 165, 0);
    var popup_seen = false;
    const popup_deadline = nowMs() + 5000;
    while (!popup_seen and nowMs() < popup_deadline) {
        const tag = rig.next(100) orelse continue;
        if (tag != .frame_end) continue;
        _ = rig.damage.takeBounds();
        rig.ack();
        const diff = streamPixelDiff(rig.w, rig.h, popup_base, rig.pixels, popup_roi);
        // A thin control focus/pressed border is not proof of a popup.
        popup_seen = diff.count > 100 and diff.bounds.?.h >= 10;
    }
    if (!popup_seen) fail("native select popup was not composed into pushed stream pixels");
    rig.key(.down, "Escape", 0);
    rig.key(.up, "Escape", 0);
    var popup_gone = false;
    const close_deadline = nowMs() + 5000;
    while (!popup_gone and nowMs() < close_deadline) {
        const tag = rig.next(100) orelse continue;
        if (tag != .frame_end) continue;
        _ = rig.damage.takeBounds();
        rig.ack();
        popup_gone = streamPixelDiff(rig.w, rig.h, popup_base, rig.pixels, popup_roi).count == 0;
    }
    if (!popup_gone) fail("native popup close did not restore the page below it");

    // Disconnect releases a held modifier and mouse button on the real page.
    _ = capSc(arena, m.callTool("web_eval", "{\"body\":\"window.streamReleaseBase={pad_down:window.seen.pad_down_count,pad_up:window.seen.pad_up_count,shift_down:window.seen.shift_down_count,shift_up:window.seen.shift_up_count};window.streamGoal='stream-release-ok';document.title='stream-release-pending';return true\"}"), "start release phase", false);
    m.sendTool("web_wait", "{\"for\":\"title\",\"arg\":\"stream-release-ok\",\"timeout_ms\":10000}");
    pending.revents = 0;
    if (c.poll(&pending, 1, 200) > 0) fail("stream release wait completed before held input was released");
    rig.key(.down, "Shift", webstream.CEF_SHIFT);
    rig.pointer(.move, 230, 60, webstream.CEF_SHIFT);
    rig.pointer(.down, 230, 60, webstream.CEF_SHIFT);
    _ = c.usleep(100_000);
    rig.disconnect();
    const release_wait = arena.dupe(u8, m.recvLine(12_000)) catch fail("stream release wait reply");
    streamInputEvidence(&m, arena, release_wait);
    // Repeated streams leak no helper descriptors.
    var fds: usize = 0;
    for (0..9) |round| {
        const o = streamOffer(&m, arena);
        if (round == 1 and linux) fds = procFds(helper);
        var cycle = StreamRig.connect(allocator, o.get("socket_path").?.string);
        cycle.send(.auth, o.get("token").?.string);
        _ = cycle.frame();
        cycle.deinit();
    }
    const next_offer = streamOffer(&m, arena);
    if (linux and procFds(helper) > fds + 2) {
        std.debug.print("smoke-mcp: helper descriptors {d} -> {d}\n", .{ fds, procFds(helper) });
        fail("repeated stream open/close leaked helper descriptors");
    }

    // Wrong AUTH consumes its token, then a replayed AUTH ends a fresh stream.
    var wrong = StreamRig.connect(allocator, next_offer.get("socket_path").?.string);
    defer wrong.deinit();
    var bad = next_offer.get("token").?.string[0..webstream.TOKEN_LEN].*;
    bad[0] = if (bad[0] == '0') '1' else '0';
    wrong.send(.auth, &bad);
    wrong.ended();
    if (fileExists(next_offer.get("socket_path").?.string)) fail("wrong AUTH left the listener reusable");
    const replay_offer = streamOffer(&m, arena);
    var replay = StreamRig.connect(allocator, replay_offer.get("socket_path").?.string);
    defer replay.deinit();
    replay.send(.auth, replay_offer.get("token").?.string);
    _ = replay.frame();
    replay.send(.auth, replay_offer.get("token").?.string);
    replay.ended();
    const view_offer = streamOffer(&m, arena);
    var view_end = StreamRig.connect(allocator, view_offer.get("socket_path").?.string);
    defer view_end.deinit();
    view_end.send(.auth, view_offer.get("token").?.string);
    _ = view_end.frame();
    _ = capSc(arena, m.callTool("web_close", "{}"), "stream view teardown", false);
    view_end.ended();
    streamEncodedStage(allocator, arena, &m, exe, rt, caps);
    streamScaleStage(allocator, arena, &m, path);
    streamFpsStage(allocator, arena, &m, exe, rt);

    m.sendTool("web_open", "{\"url\":\"about:blank\",\"snapshot\":\"none\",\"width\":800,\"height\":600}");
    _ = capSc(arena, m.recvLine(60_000), "server teardown view", false);
    const server_offer = streamOffer(&m, arena);
    var server_end = StreamRig.connect(allocator, server_offer.get("socket_path").?.string);
    defer server_end.deinit();
    server_end.send(.auth, server_offer.get("token").?.string);
    _ = server_end.frame();
    m.closeStdinWait();
    server_end.ended();
    if (fileExists(server_offer.get("socket_path").?.string)) fail("MCP server teardown leaked a stream socket");
    say("smoke-mcp: REAL pushed stream full paint, exact damage, two-ACK backpressure, popup/cursor, trusted input during web_wait, auth and teardown ok");
}

/// Fresh roots in both launch modes: a warm cache hides Chromium's first-run
/// path, which used to hang before the helper could bind its control socket.
/// A second client of the MCP server's browser helper that WATCHES one
/// page, the way the GUI's Watch does (capability "observe").
const Watcher = struct {
    fd: c_int,
    gpa: std.mem.Allocator,
    in: std.ArrayList(u8) = .empty,
    /// Latest announced target whose url contains the wanted marker.
    target: u32 = 0,
    subscribed: bool = false,

    fn connect(gpa: std.mem.Allocator, path: []const u8) Watcher {
        const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
        if (fd < 0) fail("watcher socket");
        var addr = std.mem.zeroes(c.struct_sockaddr_un);
        addr.sun_family = c.AF_UNIX;
        if (path.len >= addr.sun_path.len) fail("watcher socket path too long");
        @memcpy(addr.sun_path[0..path.len], path);
        if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0) fail("watcher could not connect to the helper socket");
        var w = Watcher{ .fd = fd, .gpa = gpa };
        w.send(webproto.Hello{ .proto = webproto.PROTO_VERSION, .client_name = "smoke-mcp-watch" });
        w.send(webproto.ObserveEnable{ .enable = 1 });
        return w;
    }

    fn send(self: *Watcher, value: anytype) void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        webproto.encode(self.gpa, &out, value) catch fail("watcher encode");
        var off: usize = 0;
        while (off < out.items.len) {
            const n = c.write(self.fd, out.items.ptr + off, out.items.len - off);
            if (n <= 0) fail("watcher write");
            off += @intCast(n);
        }
    }

    /// Read for `ms`, remembering the target announced with `marker` in
    /// its url and whether our subscription was acknowledged.
    fn pump(self: *Watcher, ms: i64, marker: []const u8) void {
        const deadline = nowMs() + ms;
        while (nowMs() < deadline) {
            var pfd = c.struct_pollfd{ .fd = self.fd, .events = c.POLLIN, .revents = 0 };
            if (c.poll(&pfd, 1, 50) <= 0) continue;
            var tmp: [65536]u8 = undefined;
            const n = c.read(self.fd, &tmp, tmp.len);
            if (n <= 0) fail("the helper closed the watcher connection");
            self.in.appendSlice(self.gpa, tmp[0..@intCast(n)]) catch fail("oom");
            var reader = webproto.Reader.init(self.in.items);
            while (reader.next() catch fail("watcher frame")) |frame| switch (frame.tag) {
                .ev_observe_view => {
                    const ev = webproto.decode(webproto.EvObserveView, frame.payload) catch fail("ev_observe_view");
                    if (ev.state == webproto.observe_view_present and std.mem.indexOf(u8, ev.url, marker) != null) self.target = ev.target;
                },
                .ev_observe_state => {
                    const ev = webproto.decode(webproto.EvObserveState, frame.payload) catch fail("ev_observe_state");
                    if (ev.state == webproto.observe_subscribed) self.subscribed = true;
                },
                else => {},
            };
            const used = reader.consumed();
            std.mem.copyForwards(u8, self.in.items[0 .. self.in.items.len - used], self.in.items[used..]);
            self.in.shrinkRetainingCapacity(self.in.items.len - used);
        }
    }

    fn close(self: *Watcher) void {
        _ = c.close(self.fd);
        self.in.deinit(self.gpa);
    }
};

/// Stage wt: several callers sharing one server's browser. Two tabs make
/// a handle-less call a refusal that lists them; labels tag and bulk
/// close tabs; ids are random and never come back; every reply echoes
/// the tab and its url; a rename or identity switch of the live browser
/// is refused; an idle tab closes itself unless someone watches it.
fn webTabsStage(allocator: std.mem.Allocator, exe: [*:0]const u8, rt: []const u8) void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A short idle time, from config like a user would set it.
    var cfg_dir_buf: [300]u8 = undefined;
    const cfg_dir = std.fmt.bufPrintZ(&cfg_dir_buf, "{s}/config/sketerm", .{rt}) catch unreachable;
    _ = c.mkdir(cfg_dir.ptr, 0o700);
    var cfg_buf: [320]u8 = undefined;
    const cfg_path = std.fmt.bufPrintZ(&cfg_buf, "{s}/config.conf", .{cfg_dir}) catch unreachable;
    @import("util/atomicwrite.zig").writeFileExact(cfg_path, "[mcp]\nweb_idle_close_secs = 8\n", 0o600) catch fail("write idle config");
    defer _ = c.unlink(cfg_path.ptr);

    var m = Mcp.spawn(allocator, exe, &.{});
    m.initialize();
    var a: [512]u8 = undefined;
    var b: [512]u8 = undefined;

    m.sendTool("web_open", "{\"url\":\"data:text/html,<title>wt-a</title>tab-a\",\"label\":\"scan-a\",\"name\":\"Scan\",\"snapshot\":\"none\"}");
    const open_a = capSc(arena, m.recvLine(60_000), "wt: open a", false);
    const va: u32 = @intCast(capInt(open_a, "view"));
    expectFact(open_a, "label", "scan-a", "wt: web_open does not echo its label");
    if (std.mem.indexOf(u8, scStr(open_a, "url", "wt url"), "wt-a") == null) fail("wt: web_open does not echo the tab's url");
    m.sendTool("web_open", "{\"url\":\"data:text/html,<title>wt-b</title>tab-b\",\"label\":\"scan-b\",\"snapshot\":\"none\"}");
    const vb: u32 = @intCast(capInt(capSc(arena, m.recvLine(60_000), "wt: open b", false), "view"));
    if (va == vb or va == 0 or vb == 0) fail("wt: two tabs did not get two handles");

    // (1) No target with two tabs: refused, listing both with labels.
    const refused = capSc(arena, m.callTool("web_snapshot", "{}"), "wt: handle-less snapshot", true);
    const err = refused.get("error").?.object;
    expectFact(err, "code", "target_required", "wt: a handle-less call with two tabs is not target_required");
    const listed = err.get("details").?.object.get("tabs").?.array.items;
    if (listed.len != 2) fail("wt: the refusal does not list both tabs");
    var saw_a = false;
    for (listed) |tab| {
        if (tab.object.get("view").?.integer == va) {
            saw_a = true;
            if (!std.mem.eql(u8, tab.object.get("label").?.string, "scan-a")) fail("wt: the refusal lost tab a's label");
        }
    }
    if (!saw_a) fail("wt: the refusal does not list tab a");
    say("smoke-mcp: wt1 a handle-less call with two tabs is refused as target_required, listing them");

    // (2) Every reply echoes the tab and its current url.
    const snap_b = capSc(arena, m.callTool("web_snapshot", std.fmt.bufPrint(&a, "{{\"pane\":{d}}}", .{vb}) catch unreachable), "wt: snapshot b", false);
    if (capInt(snap_b, "view") != vb or std.mem.indexOf(u8, scStr(snap_b, "url", "wt url b"), "wt-b") == null)
        fail("wt: a tab-acting reply does not echo its tab and url");
    expectFact(snap_b, "label", "scan-b", "wt: a tab-acting reply does not echo its label");
    say("smoke-mcp: wt2 replies echo the tab id, url and label");

    // (3) The live browser cannot be renamed or switch identity.
    const rename = capSc(arena, m.callTool("web_open", "{\"name\":\"Other\",\"snapshot\":\"none\"}"), "wt: rename", true);
    expectFact(rename.get("error").?.object, "code", "conflict", "wt: a rename of the live browser was not a conflict");
    if (std.mem.indexOf(u8, scStr(rename.get("error").?.object, "message", "wt rename msg"), "'Scan'") == null) fail("wt: the rename refusal does not name the browser");
    const ident = capSc(arena, m.callTool("web_open", "{\"name\":\"Scan\",\"ephemeral\":true,\"snapshot\":\"none\"}"), "wt: identity switch", true);
    expectFact(ident.get("error").?.object, "code", "conflict", "wt: an identity switch under the browser's name was not a conflict");
    const tabs_now = capSc(arena, m.callTool("web_tabs", "{}"), "wt: tabs after refusals", false);
    if (capInt(tabs_now, "count") != 2) fail("wt: a refused web_open opened a tab anyway");
    if (!tabs_now.get("target_required").?.bool or capInt(tabs_now, "idle_close_secs") != 8) fail("wt: web_tabs does not state target_required / idle_close_secs from config");
    say("smoke-mcp: wt3 renaming the live browser or switching its identity is refused, nothing opened");

    // (4) Bulk close by label, and ids never come back.
    var seen: [16]u32 = undefined;
    var n_seen: usize = 0;
    seen[0] = va;
    seen[1] = vb;
    n_seen = 2;
    var round: usize = 0;
    while (round < 3) : (round += 1) {
        // Keep tab a in use: this part is not about idle closing.
        _ = capSc(arena, m.callTool("web_read", std.fmt.bufPrint(&b, "{{\"pane\":{d}}}", .{va}) catch unreachable), "wt: touch a", false);
        m.sendTool("web_open", "{\"url\":\"data:text/html,<title>wt-b2</title>b2\",\"label\":\"scan-b\",\"snapshot\":\"none\"}");
        const v = capInt(capSc(arena, m.recvLine(60_000), "wt: open b2", false), "view");
        for (seen[0..n_seen]) |old| if (old == v) fail("wt: a tab id was handed out twice");
        seen[n_seen] = @intCast(v);
        n_seen += 1;
        const bulk = capSc(arena, m.callTool("web_close", "{\"label\":\"scan-b\"}"), "wt: close by label", false);
        if (capInt(bulk, "count") != @as(i64, if (round == 0) 2 else 1)) fail("wt: web_close label did not close exactly the labelled tabs");
        if (capInt(bulk, "remaining") != 1 or capInt(bulk, "current") != va) fail("wt: web_close label touched another tab or misreports what is left");
    }
    var big = false;
    for (seen[0..n_seen]) |v| if (v > 1000) {
        big = true;
    };
    if (!big) fail("wt: tab ids look like a small counter");
    say("smoke-mcp: wt4 web_close label closes exactly its tabs; ids are random and never reused");

    // (5) Idle close spares a watched tab. Tab a is watched by a second
    // helper client (the GUI's Watch); tab d is not.
    _ = capSc(arena, m.callTool("web_read", std.fmt.bufPrint(&b, "{{\"pane\":{d}}}", .{va}) catch unreachable), "wt: touch a", false);
    m.sendTool("web_open", "{\"url\":\"data:text/html,<title>wt-d</title>tab-d\",\"label\":\"idle-d\",\"snapshot\":\"none\"}");
    const vd: u32 = @intCast(capInt(capSc(arena, m.recvLine(60_000), "wt: open d", false), "view"));
    const caps = capSc(arena, m.callTool("capabilities", "{}"), "wt: caps", false);
    const rules = caps.get("web_tab_rules").?.object;
    if (!rules.get("target_required").?.bool or rules.get("idle_close_watch_aware").? != .bool or !rules.get("idle_close_watch_aware").?.bool)
        fail("wt: capabilities.web_tab_rules does not report a watch-aware idle close");
    expectFact(rules, "ids", "random", "wt: web_tab_rules.ids is not random");
    const sock = scStr(caps, "web_socket", "wt web_socket");
    var w = Watcher.connect(allocator, sock);
    defer w.close();
    w.pump(3000, "wt-a");
    if (w.target == 0) fail("wt: the watcher was not announced tab a");
    w.send(webproto.ObserveSubscribe{ .view = 1, .target = w.target, .control = 0 });
    w.pump(1000, "wt-a");
    if (!w.subscribed) fail("wt: the watcher's subscription was refused");
    const watched = capSc(arena, m.callTool("web_tabs", "{}"), "wt: tabs watched", false);
    for (watched.get("views").?.array.items) |tab| {
        const id = tab.object.get("view").?.integer;
        const wv = tab.object.get("watched").?;
        if (id == va and (wv != .bool or !wv.bool)) fail("wt: web_tabs does not report the watched tab");
        if (id == vd and (wv != .bool or wv.bool or tab.object.get("closes_in_ms").? != .integer)) fail("wt: the unwatched tab has no idle countdown");
    }
    // Wait past the idle time without touching either tab.
    w.pump(11_000, "wt-a");
    const after_idle = capSc(arena, m.callTool("web_tabs", "{}"), "wt: tabs after idle", false);
    if (capInt(after_idle, "count") != 1 or after_idle.get("views").?.array.items[0].object.get("view").?.integer != va)
        fail("wt: idle close did not close exactly the unwatched tab");
    const late = capSc(arena, m.callTool("web_read", std.fmt.bufPrint(&b, "{{\"pane\":{d}}}", .{vd}) catch unreachable), "wt: late call on idle tab", true);
    if (std.mem.indexOf(u8, scStr(late.get("error").?.object, "message", "wt late msg"), "closed automatically") == null)
        fail("wt: a call on an idle-closed tab is not told why it is gone");
    // The watch ends: the countdown starts then, and the tab goes.
    w.send(webproto.ViewDestroy{ .view = 1 });
    w.pump(12_000, "wt-a");
    const gone = capSc(arena, m.callTool("web_tabs", "{}"), "wt: tabs after unwatch", false);
    if (capInt(gone, "count") != 0) fail("wt: the formerly watched tab did not close after its watch ended");
    say("smoke-mcp: wt5 an idle tab closes itself, a watched one is spared until its watch ends");

    m.closeStdinWait();
}

fn webStartupStage(allocator: std.mem.Allocator, exe: [*:0]const u8) void {
    defer _ = c.unsetenv("SKETERM_WEB_SESSION");
    for ([_][*:0]const u8{ "cold-headless", "cold-session" }, 0..) |name, index| {
        _ = c.setenv("SKETERM_WEB_SESSION", if (index == 0) "0" else "1", 1);
        var m = Mcp.spawn(allocator, exe, &.{ "--name", name });
        m.initialize();
        m.sendTool("web_open", "{\"url\":\"about:blank\",\"snapshot\":\"none\"}");
        const opened = m.recvLine(45_000);
        if (std.mem.indexOf(u8, opened, "isError") != null or
            std.mem.indexOf(u8, opened, "\"url\":\"about:blank\"") == null)
        {
            std.debug.print("smoke-mcp: cold start {s}: {s}\n", .{ name, opened });
            fail("fresh-cache helper did not open a blank page");
        }
        const nav = m.callTool("web_navigate", "{\"url\":\"data:text/html,<title>Cold Start</title><h1>Fresh browser ready</h1>\",\"snapshot\":\"full\"}");
        if (std.mem.indexOf(u8, nav, "isError") != null or std.mem.indexOf(u8, nav, "Fresh browser ready") == null)
            fail("cold-start helper did not render the requested page");
        const shot = m.callTool("web_screenshot", "{}");
        if (std.mem.indexOf(u8, shot, "\"type\":\"image\"") == null)
            fail("cold-start helper did not produce a screenshot");
        _ = m.callTool("web_close", "{}");
        m.closeStdinWait();
    }
}

fn webStage(allocator: std.mem.Allocator, exe: [*:0]const u8, rt: []const u8) void {
    // A local page with a button that mutates a paragraph: enough for
    // snapshot ids, a trusted click, the delta and reader extraction.
    var page_buf: [512]u8 = undefined;
    const page_path = std.fmt.bufPrintZ(&page_buf, "{s}/web-smoke.html", .{rt}) catch unreachable;
    {
        const f = c.fopen(page_path.ptr, "wb") orelse fail("cannot write web smoke page");
        const html =
            "<html><head><title>Headless Smoke</title></head><body>" ++
            "<article><h1>Headless Article</h1><p>HEADLESS-READ-MARKER prose for the reader tool. " ++
            "<a id=reader href=#reader onclick=\"document.title='reader:mcp:'+event.isTrusted;return false\">" ++
            "Activate Reader Target</a></p></article>" ++
            "<button id=b onclick=\"document.getElementById('p').textContent='AFTERCLICK'\">PressMe</button>" ++
            "<p id=p>BEFORECLICK</p></body></html>";
        _ = c.fwrite(html.ptr, 1, html.len, f);
        _ = c.fclose(f);
    }

    var m = Mcp.spawn(allocator, exe, &.{});
    m.initialize();

    // capabilities must say the tools work HERE, headlessly — the old
    // report steered assistants to --shared / launch_app instead.
    // Before any web call there is no engine, so the backend is NOT
    // yet decided: session-vs-headless depends on a helper that has
    // not started. Reporting the guess as fact once sent a session
    // down a whole mirroring workaround built on a web_watch:false
    // that flipped to true the moment a view opened.
    const caps = m.callTool("capabilities", "{}");
    if (std.mem.indexOf(u8, caps, "\"web\":true") == null)
        fail("capabilities does not report that the web tools work here");
    if (std.mem.indexOf(u8, caps, "\"web_backend\":\"not_yet_determined\"") == null or
        std.mem.indexOf(u8, caps, "\"web_engine_started\":false") == null or
        std.mem.indexOf(u8, caps, "\"web_watch\":null") == null)
        fail("capabilities reports a browser backend as fact before any engine exists");

    // web_open: spawns the helper lazily, loads the page, returns a
    // first snapshot with stable node ids.
    var args_buf: [1024]u8 = undefined;
    m.sendTool("web_open", std.fmt.bufPrint(&args_buf, "{{\"url\":\"file://{s}\"}}", .{page_path}) catch unreachable);
    const opened = m.recvLine(60_000);
    if (std.mem.indexOf(u8, opened, "isError") != null) fail("web_open failed headlessly (the NoGuiSocket regression)");
    const view1 = viewHandleOf(opened);
    if (view1 == 0) fail("web_open did not hand back a headless view handle in structuredContent");
    if (std.mem.indexOf(u8, opened, "PressMe") == null or std.mem.indexOf(u8, opened, "BEFORECLICK") == null)
        fail("web_open's first snapshot is missing the page's nodes");
    const btn = nodeIdBefore(opened, "PressMe") orelse fail("cannot read the button's node id from the snapshot");

    // The instance dir carries the discoverable helper socket and the
    // presence file (the future view-along contract).
    var probe_buf: [512]u8 = undefined;
    if (!fileExists(std.fmt.bufPrint(&probe_buf, "{s}/sketerm/mcp-tmp-{d}/web.sock", .{ rt, m.pid }) catch unreachable))
        fail("helper socket is not at the well-known instance-dir path");
    if (!fileExists(std.fmt.bufPrint(&probe_buf, "{s}/sketerm/mcp-tmp-{d}/web.json", .{ rt, m.pid }) catch unreachable))
        fail("web.json presence file missing next to the helper socket");

    // Session mode is best-effort with an automatic headless fallback
    // (a CEF build that cannot start against the session compositor
    // must not cost the web tools). Report which mode a REAL helper
    // engaged; when the session engaged, both capability and presence
    // reporting must name it.
    {
        const caps_open = m.callTool("capabilities", "{}");
        if (std.mem.indexOf(u8, caps_open, "\"web_engine_started\":true") == null)
            fail("capabilities still says no engine has started after a view was opened");
        if (std.mem.indexOf(u8, caps_open, "\"web_backend\":\"not_yet_determined\"") != null)
            fail("capabilities left the backend undetermined after the engine started");
        if (std.mem.indexOf(u8, caps_open, "\"web_backend\":\"session\"") != null) {
            if (std.mem.indexOf(u8, caps_open, "\"web_session\":\"web-") == null)
                fail("session web backend reported without a session name");
            var wj_buf: [8192]u8 = undefined;
            const wj = readSmall(std.fmt.bufPrint(&probe_buf, "{s}/sketerm/mcp-tmp-{d}/web.json", .{ rt, m.pid }) catch unreachable, &wj_buf);
            if (std.mem.indexOf(u8, wj, "\"session\":\"web-") == null)
                fail("session mode engaged but web.json does not name the session");
            say("smoke-mcp: REAL helper engaged web session mode (CEF on the instance daemon's Wayland session)");
        } else {
            say("smoke-mcp: REAL helper fell back to plain headless (CEF did not start against the session compositor)");
        }
    }

    // web_act: a trusted click, whose reply carries the DELTA showing
    // the paragraph the click mutated.
    const acted = m.callTool("web_act", std.fmt.bufPrint(&args_buf, "{{\"id\":{d},\"action\":\"click\"}}", .{btn}) catch unreachable);
    if (std.mem.indexOf(u8, acted, "\"acted\":true") == null)
        fail("web_act click did not act");
    if (std.mem.indexOf(u8, acted, "AFTERCLICK") == null)
        fail("web_act's delta does not show the mutated paragraph");

    // Mutate via eval, then prove a FOLLOW-UP web_snapshot returns a
    // delta containing exactly the changed node.
    const evald = m.callTool("web_eval", "{\"code\":\"document.getElementById('p').textContent='EVALMUTATION'; 40+2\"}");
    if (std.mem.indexOf(u8, evald, "\"evaluated\":true") == null or
        std.mem.indexOf(u8, evald, "\"value\":42") == null)
        fail("web_eval did not run in the page, or its value is not machine-readable");
    const snap = m.callTool("web_snapshot", "{}");
    if (std.mem.indexOf(u8, snap, "\"kind\":\"delta\"") == null or
        std.mem.indexOf(u8, snap, "EVALMUTATION") == null)
        fail("the follow-up snapshot's delta does not carry the changed node");

    // web_read: reader-mode extraction of the article.
    const read = m.callTool("web_read", "{}");
    if (std.mem.indexOf(u8, read, "HEADLESS-READ-MARKER") == null)
        fail("web_read did not extract the article text");
    if (std.mem.indexOf(u8, read, "\"entities\":[") == null or
        std.mem.indexOf(u8, read, "\"reader_ids\":true") == null)
        fail("web_read did not return the negotiated reader entity envelope");
    const reader_id = readerIdBefore(read, "Activate Reader Target") orelse
        fail("web_read did not make its reader link addressable");
    const reader_act = m.callTool("web_act", std.fmt.bufPrint(&args_buf, "{{\"id\":{d},\"action\":\"click\"}}", .{reader_id}) catch unreachable);
    if (std.mem.indexOf(u8, reader_act, "\"acted\":true") == null)
        fail("web_act did not accept the fresh reader entity id");
    const reader_title = m.callTool("web_eval", "{\"code\":\"document.title\"}");
    if (std.mem.indexOf(u8, reader_title, "reader:mcp:true") == null)
        fail("the reader entity id did not activate its exact trusted link");
    const guarded_again = m.callTool("web_read", "{}");
    const stale_id = readerIdBefore(guarded_again, "Activate Reader Target") orelse
        fail("the second web_read did not restore the reader action guard");
    const retarget = m.callTool("web_eval", "{\"code\":\"document.getElementById('reader').href='#changed';'retargeted'\"}");
    if (std.mem.indexOf(u8, retarget, "retargeted") == null)
        fail("could not retarget the reader link before the stale-action check");
    const stale = m.callTool("web_act", std.fmt.bufPrint(&args_buf, "{{\"id\":{d},\"action\":\"click\"}}", .{stale_id}) catch unreachable);
    if (std.mem.indexOf(u8, stale, "stale reader id") == null or
        std.mem.indexOf(u8, stale, "isError") == null)
        fail("headless MCP web_act did not refuse a stale reader entity");

    // web_screenshot: a real PNG from the helper's software frame
    // (base64 "iVBOR..." is the PNG magic).
    const shot = m.callTool("web_screenshot", "{}");
    if (std.mem.indexOf(u8, shot, "\"type\":\"image\"") == null)
        fail("web_screenshot returned no image block");
    if (std.mem.indexOf(u8, shot, "iVBOR") == null)
        fail("web_screenshot's payload is not a PNG");
    // The pixel facts ride the machine lane beside the image block.
    if (std.mem.indexOf(u8, shot, "\"width\":") == null or std.mem.indexOf(u8, shot, "\"height\":") == null)
        fail("web_screenshot did not report its pixel size in structuredContent");

    // The web_open settle regression: a page that takes SECONDS to
    // finish loading must still come back as ITSELF. The blocking
    // script below keeps the document loading long past the moment a
    // create-then-navigate helper would have finished about:blank, and
    // the old settle ("some url is loaded and nothing is in flight")
    // was satisfied by that blank document — web_open then answered
    // with a snapshot of an empty page and the caller believed the
    // requested page was blank.
    var slow_buf: [512]u8 = undefined;
    const slow_path = std.fmt.bufPrintZ(&slow_buf, "{s}/web-slow.html", .{rt}) catch unreachable;
    {
        const f = c.fopen(slow_path.ptr, "wb") orelse fail("cannot write the slow web smoke page");
        const html =
            "<html><head><title>Slow</title>" ++
            "<script>var t=Date.now();while(Date.now()-t<3000);</script></head>" ++
            "<body><h1>SLOWMARKER heading</h1><p>slow page body</p></body></html>";
        _ = c.fwrite(html.ptr, 1, html.len, f);
        _ = c.fclose(f);
    }
    m.sendTool("web_open", std.fmt.bufPrint(&args_buf, "{{\"url\":\"file://{s}\"}}", .{slow_path}) catch unreachable);
    const slow = m.recvLine(60_000);
    if (std.mem.indexOf(u8, slow, "isError") != null) fail("web_open on a slow page failed");
    if (std.mem.indexOf(u8, slow, "\"settled\":true") == null)
        fail("web_open reported the slow page as unsettled");
    if (std.mem.indexOf(u8, slow, "SLOWMARKER") == null)
        fail("web_open's first snapshot is not the requested page (the about:blank settle race)");
    if (std.mem.indexOf(u8, slow, "about:blank") != null)
        fail("web_open answered with a blank document");
    // doc 1: the view has only ever held THIS page, so no blank
    // document was created for it at all (the view_create_url path).
    if (std.mem.indexOf(u8, slow, "\"document\":1") == null)
        fail("the slow page is not the view's FIRST document (a blank one was minted first)");

    // Two views exist now: a handle-less call would be a guess, so it
    // is refused and web_tabs says every call must name its tab.
    const view2 = viewHandleOf(slow);
    if (view2 == 0) fail("the slow web_open returned no view handle");
    if (view2 == view1) fail("two views share one handle");
    const tabs2 = m.callTool("web_tabs", "{}");
    if (std.mem.indexOf(u8, tabs2, std.fmt.bufPrint(&probe_buf, "\"view\":{d}", .{view2}) catch unreachable) == null)
        fail("web_tabs does not list the second headless view");
    if (std.mem.indexOf(u8, tabs2, "\"target_required\":true") == null or std.mem.indexOf(u8, tabs2, "\"current\":true") != null)
        fail("web_tabs still names a current view while two are open");
    const guessed = m.callTool("web_read", "{}");
    if (std.mem.indexOf(u8, guessed, "\"target_required\"") == null)
        fail("a handle-less web_read with two tabs open was not refused");
    const back1 = m.callTool("web_read", std.fmt.bufPrint(&args_buf, "{{\"pane\":{d}}}", .{view1}) catch unreachable);
    if (std.mem.indexOf(u8, back1, "HEADLESS-READ-MARKER") == null)
        fail("web_read against an explicit handle did not reach that view");
    // Back to one tab: the rest of this stage addresses it implicitly.
    const closed2 = m.callTool("web_close", std.fmt.bufPrint(&args_buf, "{{\"pane\":{d}}}", .{view2}) catch unreachable);
    if (std.mem.indexOf(u8, closed2, "web-slow.html") == null) fail("web_close did not echo the url it closed");
    const tabs3 = m.callTool("web_tabs", "{}");
    if (std.mem.indexOf(u8, tabs3, "\"current\":true") == null)
        fail("web_tabs does not mark the one open view as current");

    // web_tabs names the backend and the handle kind honestly.
    const tabs = m.callTool("web_tabs", "{}");
    if (std.mem.indexOf(u8, tabs, "\"backend\":\"headless\"") == null or
        std.mem.indexOf(u8, tabs, std.fmt.bufPrint(&probe_buf, "\"view\":{d}", .{view1}) catch unreachable) == null)
        fail("web_tabs does not list the headless view");
    // The nested stages each open and drive one tab of their own.
    _ = m.callTool("web_close", std.fmt.bufPrint(&args_buf, "{{\"pane\":{d}}}", .{view1}) catch unreachable);

    webReviewStage(&m, rt);
    webHandStage(&m, rt);
    webStreamStage(allocator, exe, rt);

    // ── named profiles against REAL CEF ─────────────────────────────
    //
    // The one thing only a real engine can prove: that an isolated
    // identity context actually keeps its cookies, on disk, across a
    // web_close AND across a whole MCP server restart.
    const COOKIE = "document.cookie='smoke=inprofile; max-age=86400; path=/'";
    var jar_buf: [512]u8 = undefined;
    var jar_id: []const u8 = "";
    // file:// carries no cookies in Chromium, so the isolation checks
    // need a real origin or they would pass against an engine that
    // isolates nothing.
    var http = TinyHttp.start() orelse fail("could not bind a loopback HTTP server for the profile checks");
    defer http.deinit();
    http.dl_path = "/served.bin";
    http.dl_body = DOWNLOAD_PAYLOAD;
    http.spawn();
    var origin_buf: [64]u8 = undefined;
    const origin = std.fmt.bufPrint(&origin_buf, "http://127.0.0.1:{d}/", .{http.port}) catch unreachable;
    {
        m.sendTool("web_open", std.fmt.bufPrint(&args_buf, "{{\"url\":\"{s}\",\"profile\":\"smoke\"}}", .{origin}) catch unreachable);
        const opened_p = m.recvLine(60_000);
        if (std.mem.indexOf(u8, opened_p, "isError") != null) {
            // A CEF build without the contexts capability must REFUSE,
            // never silently share the jar; that is still a pass for
            // the fail-closed contract, but the rest cannot run.
            if (std.mem.indexOf(u8, opened_p, "\"code\":\"unavailable\"") == null)
                fail("web_open with a profile failed for a reason other than a missing capability");
            say("smoke-mcp: SKIP real-CEF profile checks (this helper advertises no identity contexts; the refusal was correct)");
        } else {
            if (std.mem.indexOf(u8, opened_p, "\"profile\":\"smoke\"") == null or
                std.mem.indexOf(u8, opened_p, "\"profile_kind\":\"named\"") == null)
                fail("web_open did not report the profile its view lives in");
            var pa: [256]u8 = undefined;
            const p1 = viewHandleOf(opened_p);
            const wrote = m.callTool("web_eval", std.fmt.bufPrint(&pa, "{{\"pane\":{d},\"code\":\"" ++ COOKIE ++ "\"}}", .{p1}) catch unreachable);
            if (std.mem.indexOf(u8, wrote, "isError") != null) fail("could not write a cookie in the profile view");

            // The jar is a real directory named {profile}-{id} under the
            // durable store — the id is half the path, which is why it
            // has to be persisted at all.
            const listed = m.callTool("web_profiles", "{}");
            // Scoped to OUR row: the store is shared with the fake
            // stage's profiles, so the first "context" in the reply is
            // not necessarily this one's.
            const row = std.mem.indexOf(u8, listed, "\"name\":\"smoke\"") orelse
                fail("web_profiles does not list the profile just opened");
            const idx = row + (std.mem.indexOf(u8, listed[row..], "\"context\":") orelse
                fail("web_profiles reports no context id"));
            const after_idx = listed[idx + "\"context\":".len ..];
            const end = std.mem.indexOfAny(u8, after_idx, ",}") orelse fail("malformed web_profiles reply");
            jar_id = std.fmt.bufPrint(&jar_buf, "{s}", .{after_idx[0..end]}) catch unreachable;
            var jar_path_buf: [1024]u8 = undefined;
            const jar = std.fmt.bufPrint(&jar_path_buf, "{s}/sketerm/web-profiles/anon/profile-smoke-{s}", .{ rt, jar_id }) catch unreachable;
            if (!fileExists(jar)) fail("the profile's cookie jar directory does not exist on disk");

            // Close and reopen the SAME profile: the cookie survives.
            const closed = m.callTool("web_close", std.fmt.bufPrint(&pa, "{{\"pane\":{d}}}", .{p1}) catch unreachable);
            if (std.mem.indexOf(u8, closed, "\"profile\":\"smoke\"") == null or
                std.mem.indexOf(u8, closed, "\"profile_released\":false") == null)
                fail("web_close did not report that a named profile keeps its storage");
            m.sendTool("web_open", std.fmt.bufPrint(&args_buf, "{{\"url\":\"{s}\",\"profile\":\"smoke\"}}", .{origin}) catch unreachable);
            const reopened = m.recvLine(60_000);
            if (std.mem.indexOf(u8, reopened, "isError") != null) fail("could not reopen the profile");
            const p2 = viewHandleOf(reopened);
            const reread = m.callTool("web_eval", std.fmt.bufPrint(&pa, "{{\"pane\":{d},\"code\":\"document.cookie\"}}", .{p2}) catch unreachable);
            if (std.mem.indexOf(u8, reread, "smoke=inprofile") == null)
                fail("the profile's cookie did not survive web_close (its jar is not persistent)");

            // Isolation: the DEFAULT jar has never seen that cookie.
            m.sendTool("web_open", std.fmt.bufPrint(&args_buf, "{{\"url\":\"{s}\"}}", .{origin}) catch unreachable);
            const plain_open = m.recvLine(60_000);
            if (std.mem.indexOf(u8, plain_open, "isError") != null) fail("could not open a default-jar view");
            const pd = viewHandleOf(plain_open);
            const plain = m.callTool("web_eval", std.fmt.bufPrint(&pa, "{{\"pane\":{d},\"code\":\"document.cookie\"}}", .{pd}) catch unreachable);
            if (std.mem.indexOf(u8, plain, "smoke=inprofile") != null)
                fail("a profile's cookie leaked into the shared default jar");

            // An ephemeral identity is isolated too, and goes away with
            // its view.
            m.sendTool("web_open", std.fmt.bufPrint(&args_buf, "{{\"url\":\"{s}\",\"ephemeral\":true}}", .{origin}) catch unreachable);
            const eph = m.recvLine(60_000);
            if (std.mem.indexOf(u8, eph, "isError") != null) fail("could not open an ephemeral view");
            if (std.mem.indexOf(u8, eph, "\"profile_kind\":\"ephemeral\"") == null)
                fail("web_open did not report the ephemeral identity");
            const pe = viewHandleOf(eph);
            const eph_cookie = m.callTool("web_eval", std.fmt.bufPrint(&pa, "{{\"pane\":{d},\"code\":\"document.cookie\"}}", .{pe}) catch unreachable);
            if (std.mem.indexOf(u8, eph_cookie, "smoke=inprofile") != null)
                fail("a profile's cookie leaked into an ephemeral identity");
            const eph_closed = m.callTool("web_close", std.fmt.bufPrint(&pa, "{{\"pane\":{d}}}", .{pe}) catch unreachable);
            if (std.mem.indexOf(u8, eph_closed, "\"profile_released\":true") == null)
                fail("closing the last ephemeral view did not destroy its identity");

            // Reset is refused while the profile is open...
            const busy = m.callTool("web_profile_reset", "{\"profile\":\"smoke\"}");
            if (std.mem.indexOf(u8, busy, "\"code\":\"conflict\"") == null)
                fail("web_profile_reset erased a profile that was in use");
            // The stages below drive one tab of their own each.
            _ = m.callTool("web_close", std.fmt.bufPrint(&pa, "{{\"pane\":{d}}}", .{p2}) catch unreachable);
            _ = m.callTool("web_close", std.fmt.bufPrint(&pa, "{{\"pane\":{d}}}", .{pd}) catch unreachable);
        }
    }

    webDownloadStage(&m, rt, http.port);
    webEvalSizeStage(&m, rt);

    certStage(&m, rt);

    m.closeStdinWait();
    // Ephemeral teardown must have reaped the helper's instance dir.
    if (fileExists(std.fmt.bufPrint(&probe_buf, "{s}/sketerm/mcp-tmp-{d}", .{ rt, m.pid }) catch unreachable))
        fail("instance dir (with the web helper's socket) survived teardown");
    // ...but the DURABLE store outlives it: that is the whole point.
    if (jar_id.len > 0) {
        var jar_path_buf: [1024]u8 = undefined;
        const jar = std.fmt.bufPrint(&jar_path_buf, "{s}/sketerm/web-profiles/anon/profile-smoke-{s}", .{ rt, jar_id }) catch unreachable;
        if (!fileExists(jar)) fail("the profile store did not survive the MCP server it was created by");

        // A WHOLE NEW SERVER, a whole new browser process: the cookie
        // is still there. Only the durable path can do this.
        var restarted = Mcp.spawn(allocator, exe, &.{});
        restarted.initialize();
        restarted.sendTool("web_open", std.fmt.bufPrint(&args_buf, "{{\"url\":\"{s}\",\"profile\":\"smoke\"}}", .{origin}) catch unreachable);
        if (std.mem.indexOf(u8, restarted.recvLine(60_000), "isError") != null)
            fail("a restarted MCP server could not reopen the profile");
        const survived = restarted.callTool("web_eval", "{\"code\":\"document.cookie\"}");
        if (std.mem.indexOf(u8, survived, "smoke=inprofile") == null)
            fail("the profile's cookie did not survive an MCP server restart");

        // Reset, then a fresh jar: a NEW id, and no cookie.
        _ = restarted.callTool("web_close", "{}");
        const reset = restarted.callTool("web_profile_reset", "{\"profile\":\"smoke\"}");
        if (std.mem.indexOf(u8, reset, "\"deleted\":true") == null)
            fail("web_profile_reset did not erase the freed profile");
        if (fileExists(jar)) fail("web_profile_reset left the old jar directory behind");
        restarted.sendTool("web_open", std.fmt.bufPrint(&args_buf, "{{\"url\":\"{s}\",\"profile\":\"smoke\"}}", .{origin}) catch unreachable);
        if (std.mem.indexOf(u8, restarted.recvLine(60_000), "isError") != null)
            fail("could not reopen the profile after a reset");
        const empty = restarted.callTool("web_eval", "{\"code\":\"document.cookie\"}");
        if (std.mem.indexOf(u8, empty, "smoke=inprofile") != null)
            fail("a reset profile still serves its old cookies");
        const relisted = restarted.callTool("web_profiles", "{}");
        const row = std.mem.indexOf(u8, relisted, "\"name\":\"smoke\"") orelse
            fail("web_profiles lost the profile after a reset + reopen");
        var old_buf: [64]u8 = undefined;
        const old_ctx = std.fmt.bufPrint(&old_buf, "\"context\":{s},", .{jar_id}) catch unreachable;
        if (std.mem.indexOf(u8, relisted[row..], old_ctx) != null)
            fail("a reset profile kept its old context id (its jar path would be the old one)");
        restarted.closeStdinWait();
    }

    // Suppress only the capability advertisement to emulate an older
    // helper: the MCP adapter must choose sem_read and keep JSON-shaped
    // page bytes as markdown rather than guessing a rich envelope.
    _ = c.setenv("SKETERM_WEB_DISABLE_READER_IDS", "1", 1);
    defer _ = c.unsetenv("SKETERM_WEB_DISABLE_READER_IDS");
    _ = c.setenv("SKETERM_WEB_DISABLE_SEMANTIC_REQUEST_IDS", "1", 1);
    defer _ = c.unsetenv("SKETERM_WEB_DISABLE_SEMANTIC_REQUEST_IDS");
    var legacy = Mcp.spawn(allocator, exe, &.{});
    legacy.initialize();
    legacy.sendTool("web_open", std.fmt.bufPrint(&args_buf, "{{\"url\":\"file://{s}\"}}", .{page_path}) catch unreachable);
    const legacy_open = legacy.recvLine(60_000);
    if (std.mem.indexOf(u8, legacy_open, "isError") != null)
        fail("the capability-suppressed helper could not open the reader page");
    const legacy_read = legacy.callTool("web_read", "{}");
    if (std.mem.indexOf(u8, legacy_read, "HEADLESS-READ-MARKER") == null or
        std.mem.indexOf(u8, legacy_read, "lacks the reader-ids capability") == null)
        fail("web_read did not report the negotiated old-helper fallback");
    if (std.mem.indexOf(u8, legacy_read, "\"entities\":") != null or
        std.mem.indexOf(u8, legacy_read, "\"reader_ids\":false") == null)
        fail("the old-helper fallback fabricated rich reader entities");
    legacy.closeStdinWait();
}

/// Real-CEF proof of the ENFORCED network policy: every assertion here
/// is a server-side HIT COUNTER, because the whole point is that a
/// refused request never touches a socket.
// -- response-body capture, end to end through the MCP tools ----------

/// The page, its fetches, and a JSON a request body round-trips through.
const CapHttp = struct {
    lis: tcpserver.Listener = .{ .backlog = 32, .poll_ms = 100 },

    const page =
        \\<!doctype html><html><head><title>cap-mcp</title></head><body>
        \\<script>
        \\fetch("/api/first").then(r => r.text()).then(() => fetch("/api/gql", { method: "POST",
        \\  headers: { "content-type": "application/json" },
        \\  body: JSON.stringify({ operationName: "fetchPlaylist", variables: { offset: 25 } }) }))
        \\  .then(r => r.text()).then(() => fetch("/api/raw.bin")).then(r => r.text())
        \\  .then(() => { document.title = "cap-mcp-done"; });
        \\</script></body></html>
    ;
    const first = "{\"items\":[\"one\",\"two\"],\"next\":25}";
    const gql = "{\"data\":{\"playlist\":{\"tracks\":[\"A\",\"B\"]}}}";
    const later = "{\"items\":[\"three\"],\"next\":null}";

    fn start(self: *CapHttp) bool {
        return self.lis.start(self, &onConn);
    }

    fn onConn(_: ?*anyopaque, afd: c_int) bool {
        var buf: [8192]u8 = undefined;
        var n: usize = 0;
        // Headers, then a Content-Length body: a POST's body may come in
        // its own packet.
        while (n < buf.len) {
            var pfd = c.struct_pollfd{ .fd = afd, .events = c.POLLIN, .revents = 0 };
            if (c.poll(@ptrCast(&pfd), 1, 3000) <= 0) break;
            const r = c.read(afd, &buf[n], buf.len - n);
            if (r <= 0) break;
            n += @intCast(r);
            const end = std.mem.indexOf(u8, buf[0..n], "\r\n\r\n") orelse continue;
            const cl_at = std.ascii.indexOfIgnoreCase(buf[0..end], "content-length:") orelse break;
            const line_end = std.mem.indexOfPos(u8, buf[0..end], cl_at, "\r\n") orelse end;
            const want = std.fmt.parseInt(usize, std.mem.trim(u8, buf[cl_at + 15 .. line_end], " "), 10) catch 0;
            if (n >= end + 4 + want) break;
        }
        const raw = buf[0..n];
        const path_start = (std.mem.indexOfScalar(u8, raw, ' ') orelse return false) + 1;
        const path_end = std.mem.indexOfScalarPos(u8, raw, path_start, ' ') orelse return false;
        const path = raw[path_start..path_end];
        const eq = std.mem.eql;
        if (eq(u8, path, "/page")) tcpserver.respondOk(afd, "text/html", page, "") else if (std.mem.startsWith(u8, path, "/api/first")) tcpserver.respondOk(afd, "application/json", first, "") else if (eq(u8, path, "/api/gql")) tcpserver.respondOk(afd, "application/json", gql, "") else if (eq(u8, path, "/api/later")) tcpserver.respondOk(afd, "application/json", later, "") else if (eq(u8, path, "/api/raw.bin")) tcpserver.respondOk(afd, "application/octet-stream", "\x00\x01\x02", "") else tcpserver.respondOk(afd, "text/plain", "?", "");
        return false;
    }
};

/// structuredContent of one tools/call reply line; fails the stage on an
/// error result unless `want_error`.
fn capSc(arena: std.mem.Allocator, line: []const u8, comptime what: []const u8, comptime want_error: bool) std.json.ObjectMap {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch fail(what ++ ": reply is not JSON");
    const result = v.object.get("result") orelse fail(what ++ ": no result");
    const is_err = if (result.object.get("isError")) |e| e == .bool and e.bool else false;
    if (is_err != want_error) {
        say(line);
        fail(what ++ (if (want_error) ": expected an error result" else ": unexpected error result"));
    }
    return result.object.get("structuredContent").?.object;
}

fn capInt(o: std.json.ObjectMap, key: []const u8) i64 {
    const v = o.get(key) orelse return -1;
    return if (v == .integer) v.integer else -1;
}

/// Stage wc: web_open capture, web_capture (list, body, out_file,
/// out_dir), web_wait for:"response", web_capture_set, the web_network
/// join and the capabilities fact, against the real helper; then the
/// fail-closed refusal against a helper that withholds the capability.
fn webCaptureStage(allocator: std.mem.Allocator, exe: [*:0]const u8, rt: []const u8) void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var http = CapHttp{};
    if (!http.start()) fail("could not bind the loopback capture fixture");
    defer http.lis.deinit();
    var args_buf: [2048]u8 = undefined;

    var m = Mcp.spawn(allocator, exe, &.{});
    m.initialize();

    {
        const caps = capSc(arena, m.callTool("capabilities", "{}"), "capabilities", false);
        const f = caps.get("web_capture") orelse fail("capabilities has no web_capture fact");
        if (f != .bool or !f.bool) fail("capabilities reports web_capture false on a headless server with a capable helper");
    }

    // A bad pattern is refused before anything is opened.
    {
        const bad = capSc(arena, m.callTool("web_open", "{\"url\":\"about:blank\",\"capture\":{\"url_regex\":\"(x[\"}}"), "bad capture", true);
        _ = bad;
        const tabs = capSc(arena, m.callTool("web_tabs", "{}"), "web_tabs", false);
        if (capInt(tabs, "count") != 0) fail("a refused captured open still opened a view");
    }

    m.sendTool("web_open", std.fmt.bufPrint(&args_buf, "{{\"url\":\"http://127.0.0.1:{d}/page\",\"snapshot\":\"none\",\"timeout_ms\":20000,\"capture\":{{\"url_contains\":\"/api/\",\"mime_prefixes\":[\"application/json\"],\"max_body_bytes\":65536,\"max_total_bytes\":1048576}}}}", .{http.lis.port}) catch unreachable);
    const opened = capSc(arena, m.recvLine(60_000), "captured web_open", false);
    if (opened.get("capture_active").? != .bool or !opened.get("capture_active").?.bool) fail("web_open does not report capture_active");
    const echo = opened.get("capture").?.object;
    if (echo.get("types").?.array.items.len != 1 or !std.mem.eql(u8, echo.get("types").?.array.items[0].string, "xhr"))
        fail("the capture echo does not show the xhr default");

    // The page's own POST, waited for from the start of the view.
    m.sendTool("web_wait", "{\"for\":\"response\",\"since\":0,\"response\":{\"url_contains\":\"/api/gql\",\"methods\":[\"POST\"]},\"timeout_ms\":20000}");
    const gql = capSc(arena, m.recvLine(40_000), "web_wait for the gql response", false);
    const gql_ex = gql.get("response").?.object;
    const gql_seq = capInt(gql_ex, "seq");
    if (!gql_ex.get("complete").?.bool) fail("the waited-for response is not complete");

    {
        const body = capSc(arena, m.callTool("web_capture", std.fmt.bufPrint(&args_buf, "{{\"seq\":{d}}}", .{gql_seq}) catch unreachable), "gql body", false);
        if (!std.mem.eql(u8, body.get("body").?.string, CapHttp.gql)) fail("web_capture does not return the gql response body the page received");
        if (!std.mem.eql(u8, body.get("encoding").?.string, "utf8")) fail("a JSON body is not reported as utf8 text");
        if (body.get("headers").?.array.items.len == 0) fail("the response headers are missing");
        const req = capSc(arena, m.callTool("web_capture", std.fmt.bufPrint(&args_buf, "{{\"seq\":{d},\"part\":\"request\"}}", .{gql_seq}) catch unreachable), "gql request body", false);
        if (!std.mem.eql(u8, req.get("body").?.string, "{\"operationName\":\"fetchPlaylist\",\"variables\":{\"offset\":25}}"))
            fail("web_capture part:request does not return the POST body the page sent");
    }

    // The listing: exactly the two json /api/ fetches (raw.bin is
    // octet-stream, the document is not xhr).
    {
        // raw.bin finishes last; wait for the page to say it is done.
        _ = capSc(arena, m.callTool("web_wait", "{\"for\":\"title\",\"arg\":\"cap-mcp-done\",\"timeout_ms\":15000}"), "page done", false);
        const list = capSc(arena, m.callTool("web_capture", "{}"), "web_capture list", false);
        const ex = list.get("exchanges").?.array.items;
        if (ex.len != 2) {
            say(m.callTool("web_capture", "{}"));
            fail("the capture did not keep exactly the two JSON /api/ fetches");
        }
        if (!std.mem.eql(u8, list.get("capture_state").?.string, "active")) fail("capture_state is not active");
        // Every seq joins its web_network row.
        const net = m.callTool("web_network", "{\"max\":128}");
        for (ex) |e| {
            const want = std.fmt.allocPrint(arena, "\"seq\":{d},", .{capInt(e.object, "seq")}) catch fail("oom");
            const at = std.mem.indexOf(u8, net, want) orelse fail("a captured seq has no web_network row");
            const row_end = std.mem.indexOfScalarPos(u8, net, at, '}') orelse fail("web_network row");
            if (std.mem.indexOf(u8, net[at..row_end], e.object.get("url").?.string) == null) fail("a captured seq names a different web_network url");
        }

        // out_file and out_dir.
        const first_seq = capInt(ex[0].object, "seq");
        const path = std.fmt.allocPrint(arena, "{s}/cap-first.json", .{rt}) catch fail("oom");
        const wrote = capSc(arena, m.callTool("web_capture", std.fmt.bufPrint(&args_buf, "{{\"seq\":{d},\"out_file\":\"{s}\"}}", .{ first_seq, path }) catch unreachable), "out_file", false);
        if (wrote.get("body") != null) fail("an out_file read also returned the body inline");
        if (capInt(wrote, "bytes") != CapHttp.first.len) fail("out_file reports the wrong size");
        const on_disk = readFileAlloc(arena, path) orelse fail("out_file was not written");
        if (!std.mem.eql(u8, on_disk, CapHttp.first)) fail("out_file does not hold the body");
        const dir = std.fmt.allocPrint(arena, "{s}/cap-bodies", .{rt}) catch fail("oom");
        const dumped = capSc(arena, m.callTool("web_capture", std.fmt.bufPrint(&args_buf, "{{\"out_dir\":\"{s}\"}}", .{dir}) catch unreachable), "out_dir", false);
        for (dumped.get("exchanges").?.array.items) |e| {
            const p = e.object.get("path") orelse fail("an out_dir exchange lacks its path");
            const bytes = readFileAlloc(arena, p.string) orelse fail("an out_dir body file is missing");
            if (bytes.len != @as(usize, @intCast(capInt(e.object, "body_bytes")))) fail("an out_dir file does not hold the whole body");
        }
    }

    // Scroll-then-wait: something the page fetches LATER is what a
    // default (after-now) wait sees.
    {
        _ = capSc(arena, m.callTool("web_eval", "{\"code\":\"setTimeout(() => fetch('/api/later').then(r => r.text()), 1500), 1\"}"), "schedule a later fetch", false);
        m.sendTool("web_wait", "{\"for\":\"response\",\"response\":{\"url_contains\":\"/api/later\"},\"timeout_ms\":15000}");
        const later = capSc(arena, m.recvLine(30_000), "web_wait after now", false);
        if (!std.mem.endsWith(u8, later.get("response").?.object.get("url").?.string, "/api/later")) fail("the after-now wait returned the wrong exchange");
        const nothing = m.callTool("web_wait", "{\"for\":\"response\",\"response\":{\"url_contains\":\"/api/never\"},\"timeout_ms\":1500}");
        const err = capSc(arena, nothing, "a wait that never holds", true);
        if (!std.mem.eql(u8, err.get("error").?.object.get("code").?.string, "timeout")) fail("a response wait that never held is not a timeout");

        // A body the page never reads: in flight, listed on request.
        _ = capSc(arena, m.callTool("web_eval", "{\"code\":\"fetch('/api/first?unread=1'), 1\"}"), "an unread fetch", false);
        var seen = false;
        var tries: u32 = 0;
        while (!seen and tries < 50) : (tries += 1) {
            const lst = capSc(arena, m.callTool("web_capture", "{\"include_in_flight\":true}"), "include_in_flight", false);
            for (lst.get("exchanges").?.array.items) |e| {
                if (!std.mem.endsWith(u8, e.object.get("url").?.string, "unread=1")) continue;
                if (capInt(e.object, "cursor") != 0 or e.object.get("complete").?.bool) fail("an unread exchange is listed as finished");
                if (capInt(e.object, "body_bytes") == CapHttp.first.len) seen = true;
            }
            if (!seen) _ = c.usleep(100_000);
        }
        if (!seen) fail("include_in_flight never listed the unread exchange with its whole body");
    }

    // Narrowing only.
    {
        const refused = capSc(arena, m.callTool("web_capture_set", "{\"action\":\"enable\"}"), "a widening", true);
        if (!std.mem.eql(u8, refused.get("error").?.object.get("code").?.string, "refused")) fail("a widening was not refused");
        const before = capSc(arena, m.callTool("web_capture", "{}"), "list before clear", false);
        const cleared = capSc(arena, m.callTool("web_capture_set", "{\"action\":\"clear\",\"upto\":1}"), "clear upto 1", false);
        if (capInt(cleared, "stored_bytes") >= capInt(before, "stored_bytes")) fail("clear did not give bytes back");
        const after = capSc(arena, m.callTool("web_capture", "{}"), "list after clear", false);
        if (after.get("exchanges").?.array.items.len + 1 != before.get("exchanges").?.array.items.len) fail("clear upto 1 did not free exactly one exchange");
        const disabled = capSc(arena, m.callTool("web_capture_set", "{\"action\":\"disable\"}"), "disable", false);
        if (!std.mem.eql(u8, disabled.get("capture_state").?.string, "disabled")) fail("disable did not report state disabled");
    }
    _ = m.callTool("web_close", "{}");

    // A view without a capture says so.
    {
        m.sendTool("web_open", std.fmt.bufPrint(&args_buf, "{{\"url\":\"http://127.0.0.1:{d}/page\",\"snapshot\":\"none\"}}", .{http.lis.port}) catch unreachable);
        _ = capSc(arena, m.recvLine(60_000), "plain web_open", false);
        const none = capSc(arena, m.callTool("web_capture", "{}"), "web_capture without a capture", true);
        if (!std.mem.eql(u8, none.get("error").?.object.get("code").?.string, "conflict")) fail("web_capture on an uncaptured view is not a conflict");
        _ = m.callTool("web_close", "{}");
    }
    m.closeStdinWait();

    // Fail closed: a helper that withholds the capability opens nothing.
    {
        _ = c.setenv("SKETERM_WEB_DISABLE_CAPTURE", "1", 1);
        defer _ = c.unsetenv("SKETERM_WEB_DISABLE_CAPTURE");
        _ = c.setenv("SKETERM_WEB_BROKER_ENGINE", "0", 1);
        var w = Mcp.spawn(allocator, exe, &.{});
        w.initialize();
        w.sendTool("web_open", std.fmt.bufPrint(&args_buf, "{{\"url\":\"http://127.0.0.1:{d}/page\",\"capture\":{{}}}}", .{http.lis.port}) catch unreachable);
        const refused = capSc(arena, w.recvLine(60_000), "captured open on a helper without capture", true);
        if (!std.mem.eql(u8, refused.get("error").?.object.get("code").?.string, "unavailable")) fail("the capture refusal is not 'unavailable'");
        const tabs = capSc(arena, w.callTool("web_tabs", "{}"), "web_tabs after refusal", false);
        if (capInt(tabs, "count") != 0) fail("a refused captured open left a view behind");
        const caps = capSc(arena, w.callTool("capabilities", "{}"), "capabilities after", false);
        if (caps.get("web_capture").?.bool) fail("capabilities reports web_capture on a helper that withholds it");
        w.closeStdinWait();
    }
}

fn readFileAlloc(arena: std.mem.Allocator, path: []const u8) ?[]u8 {
    var pbuf: [4096]u8 = undefined;
    const z = std.fmt.bufPrintZ(&pbuf, "{s}", .{path}) catch return null;
    const f = c.fopen(z.ptr, "rb") orelse return null;
    defer _ = c.fclose(f);
    var out: std.ArrayList(u8) = .empty;
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = c.fread(&buf, 1, buf.len, f);
        if (n == 0) break;
        out.appendSlice(arena, buf[0..n]) catch return null;
    }
    return out.items;
}

fn webPolicyStage(allocator: std.mem.Allocator, exe: [*:0]const u8, rt: []const u8) void {
    _ = rt;
    var http = PolicyHttp.start() orelse fail("could not bind the loopback policy fixture");
    defer http.deinit();
    var args_buf: [2048]u8 = undefined;

    var m = Mcp.spawn(allocator, exe, &.{});
    m.initialize();

    // (17) The private-address default: 127.0.0.1 is refused BEFORE the
    // socket is touched, even though the host is allow-listed.
    {
        m.sendTool("web_open", std.fmt.bufPrint(&args_buf, "{{\"url\":\"http://127.0.0.1:{d}/doc\",\"timeout_ms\":4000,\"policy\":{{\"allow_hosts\":[\"127.0.0.1\"]}}}}", .{http.port}) catch unreachable);
        const opened = m.recvLine(60_000);
        if (std.mem.indexOf(u8, opened, "\"isError\":true") != null)
            fail("a policied web_open failed outright (the view should open; its LOAD is refused)");
        if (std.mem.indexOf(u8, opened, "\"settled\":false") == null)
            fail("a private-refused document still settled");
        if (PolicyHttp.hitsFor("/doc") != 0)
            fail("the private-address refusal happened AFTER the socket was touched");
        const pol = m.callTool("web_policy", "{}");
        if (std.mem.indexOf(u8, pol, "\"private_address\":") == null)
            fail("web_policy does not count the private-address refusal");
        _ = m.callTool("web_close", "{}");
    }

    // (18) Host allow-list, both halves: an allowed document with a
    // same-host script, an offsite (localhost) image cancelled before
    // the wire — and a disallowed DOCUMENT refused as its own verdict.
    {
        m.sendTool("web_open", std.fmt.bufPrint(&args_buf, "{{\"url\":\"http://127.0.0.1:{d}/offsite-page\",\"timeout_ms\":8000,\"policy\":{{\"allow_hosts\":[\"127.0.0.1\"],\"allow_private_addresses\":true}}}}", .{http.port}) catch unreachable);
        const opened = m.recvLine(60_000);
        if (std.mem.indexOf(u8, opened, "\"isError\":true") != null)
            fail("the allow-listed document did not open");
        if (std.mem.indexOf(u8, opened, "SUBHOST-PAGE") == null)
            fail("the offsite-sub page did not render");
        if (PolicyHttp.hitsFor("/offsite-page") != 1 or PolicyHttp.hitsFor("/sub.js") != 1)
            fail("the allowed document/script did not reach the server exactly once");
        if (PolicyHttp.hitsFor("/img.png") != 0)
            fail("the offsite subresource reached the server (sub_host must cancel pre-wire)");
        const net = m.callTool("web_network", "{}");
        if (std.mem.indexOf(u8, net, "\"reason\":\"sub_host\"") == null)
            fail("web_network does not name the sub_host refusal");
        _ = m.callTool("web_close", "{}");

        // The disallowed initial url: the DOCUMENT request itself
        // carries a policy verdict (the install won the create race).
        m.sendTool("web_open", std.fmt.bufPrint(&args_buf, "{{\"url\":\"http://localhost:{d}/doc2\",\"timeout_ms\":4000,\"policy\":{{\"allow_hosts\":[\"127.0.0.1\"],\"allow_private_addresses\":true}}}}", .{http.port}) catch unreachable);
        _ = m.recvLine(60_000);
        if (PolicyHttp.hitsFor("/doc2") != 0)
            fail("a disallowed initial document still reached the server");
        const pol = m.callTool("web_policy", "{}");
        if (std.mem.indexOf(u8, pol, "\"top_host\":") == null)
            fail("web_policy does not count the top_host refusal");
        _ = m.callTool("web_close", "{}");
    }

    // (19) Resource-type blocking: the same-host image never leaves.
    {
        m.sendTool("web_open", std.fmt.bufPrint(&args_buf, "{{\"url\":\"http://127.0.0.1:{d}/imgs\",\"timeout_ms\":8000,\"policy\":{{\"allow_hosts\":[\"127.0.0.1\"],\"allow_private_addresses\":true,\"block_types\":[\"image\"]}}}}", .{http.port}) catch unreachable);
        const opened = m.recvLine(60_000);
        if (std.mem.indexOf(u8, opened, "TYPEBLOCK-PAGE") == null)
            fail("the type-block page did not render");
        if (PolicyHttp.hitsFor("/imgs") != 1) fail("the type-block document did not load exactly once");
        if (PolicyHttp.hitsFor("/blocked.png") != 0)
            fail("a blocked resource TYPE still reached the server");
        const net = m.callTool("web_network", "{}");
        if (std.mem.indexOf(u8, net, "\"reason\":\"resource_type\"") == null)
            fail("web_network does not name the resource_type refusal");
        _ = m.callTool("web_close", "{}");
    }

    // (20) A 302 to a disallowed host: the target is never fetched.
    // Step-0 measurement: CEF re-enters on_before_resource_load for the
    // redirected request (same request id), so the ordinary gate IS the
    // redirect defence — this stage is what holds that measurement true.
    {
        m.sendTool("web_open", std.fmt.bufPrint(&args_buf, "{{\"url\":\"http://127.0.0.1:{d}/redir-offsite\",\"timeout_ms\":4000,\"policy\":{{\"allow_hosts\":[\"127.0.0.1\"],\"allow_private_addresses\":true}}}}", .{http.port}) catch unreachable);
        _ = m.recvLine(60_000);
        if (PolicyHttp.hitsFor("/redir-offsite") != 1)
            fail("the redirecting document did not load exactly once");
        if (PolicyHttp.hitsFor("/offsite-target") != 0)
            fail("a redirect to a disallowed host reached the server");
        const net = m.callTool("web_network", "{}");
        if (std.mem.indexOf(u8, net, "\"reason\":\"redirect_host\"") == null)
            fail("web_network does not name the redirect_host refusal");
        _ = m.callTool("web_close", "{}");
    }

    // (21) The request cap: exactly 3 requests leave the process (the
    // document included — favicon probes and subresources compete for
    // the remaining 2), then everything latches and navigation refuses.
    {
        m.sendTool("web_open", std.fmt.bufPrint(&args_buf, "{{\"url\":\"http://127.0.0.1:{d}/many\",\"timeout_ms\":8000,\"policy\":{{\"allow_hosts\":[\"127.0.0.1\"],\"allow_private_addresses\":true,\"max_requests\":3}}}}", .{http.port}) catch unreachable);
        _ = m.recvLine(60_000);
        var sub_hits: u32 = 0;
        for ([_][]const u8{ "/r0", "/r1", "/r2", "/r3", "/r4", "/r5", "/r6", "/r7", "/r8", "/r9" }) |p|
            sub_hits += PolicyHttp.hitsFor(p);
        // The favicon is deliberately OUTSIDE this sum: the browser-path
        // favicon request is denied (the log proves it), but CEF's
        // favicon fetcher ALSO probes through a browserless URLRequest,
        // which is the documented unpoliced slot-less path (measured
        // here: exactly one /favicon.ico hit despite the denial).
        const total = PolicyHttp.hitsFor("/many") + sub_hits;
        if (PolicyHttp.hitsFor("/many") != 1) fail("the capped document did not load exactly once");
        if (total > 3) {
            std.debug.print("smoke-mcp: request-cap counters: many={d} subs={d} favicon={d}\n", .{
                PolicyHttp.hitsFor("/many"), sub_hits, PolicyHttp.hitsFor("/favicon.ico"),
            });
            fail("more requests reached the server than max_requests allows");
        }
        const pol = m.callTool("web_policy", "{}");
        if (std.mem.indexOf(u8, pol, "\"exhausted_reason\":\"request_cap\"") == null or
            std.mem.indexOf(u8, pol, "\"requests\":3") == null)
            fail("web_policy does not report the latched request cap");
        const nav = m.callTool("web_navigate", std.fmt.bufPrint(&args_buf, "{{\"url\":\"http://127.0.0.1:{d}/doc\"}}", .{http.port}) catch unreachable);
        if (std.mem.indexOf(u8, nav, "\"code\":\"refused\"") == null)
            fail("an exhausted view still navigates");
        // Reads keep answering, loudly.
        const shot = m.callTool("web_snapshot", "{}");
        if (std.mem.indexOf(u8, shot, "\"policy_exhausted\":true") == null)
            fail("a read on the exhausted view does not carry the exhausted fact");
        _ = m.callTool("web_close", "{}");
    }

    // (22) The deadline: latched by the sweep mid-load, one stop_load,
    // and the accounting says so.
    {
        m.sendTool("web_open", std.fmt.bufPrint(&args_buf, "{{\"url\":\"http://127.0.0.1:{d}/slow\",\"timeout_ms\":4000,\"policy\":{{\"allow_hosts\":[\"127.0.0.1\"],\"allow_private_addresses\":true,\"deadline_ms\":1500}}}}", .{http.port}) catch unreachable);
        _ = m.recvLine(60_000);
        if (PolicyHttp.hitsFor("/slow") != 1) fail("the slow document was never requested");
        const pol = m.callTool("web_policy", "{}");
        if (std.mem.indexOf(u8, pol, "\"exhausted_reason\":\"deadline\"") == null)
            fail("web_policy does not report the latched deadline");
        _ = m.callTool("web_close", "{}");
    }
    m.closeStdinWait();

    // (23) The capability kill-switch: a helper started without
    // net-policy refuses a policied open outright, minting nothing.
    {
        _ = c.setenv("SKETERM_WEB_DISABLE_NET_POLICY", "1", 1);
        defer _ = c.unsetenv("SKETERM_WEB_DISABLE_NET_POLICY");
        var suppressed = Mcp.spawn(allocator, exe, &.{});
        suppressed.initialize();
        suppressed.sendTool("web_open", std.fmt.bufPrint(&args_buf, "{{\"url\":\"http://127.0.0.1:{d}/doc\",\"policy\":{{\"allow_hosts\":[\"127.0.0.1\"],\"allow_private_addresses\":true}}}}", .{http.port}) catch unreachable);
        const refused = suppressed.recvLine(60_000);
        if (std.mem.indexOf(u8, refused, "\"isError\":true") == null or
            std.mem.indexOf(u8, refused, "net-policy capability") == null)
            fail("a helper without net-policy did not refuse the policied open");
        const tabs = suppressed.callTool("web_tabs", "{}");
        if (std.mem.indexOf(u8, tabs, "\"count\":0") == null)
            fail("the suppressed-capability refusal still minted a view");
        suppressed.closeStdinWait();
    }
}

/// Read a small file fully; empty slice when missing/unreadable.
fn readSmall(path: []const u8, buf: []u8) []const u8 {
    var z: [4096:0]u8 = undefined;
    const p = std.fmt.bufPrintZ(&z, "{s}", .{path}) catch return "";
    const f = c.fopen(p.ptr, "rb") orelse return "";
    defer _ = c.fclose(f);
    const n = c.fread(buf.ptr, 1, buf.len, f);
    return buf[0..n];
}

/// Why a `.list` produced no welcome. Distinguishing these from an
/// empty-but-valid listing is load-bearing: a caller asserting that
/// something is ABSENT from the listing passes vacuously when the daemon
/// was simply unreachable.
const ListFailure = error{
    ListConnect,
    ListSend,
    ListReply,
    ListTruncated,
};

/// `.list` a daemon's sessions as the raw welcome JSON.
fn listSessionsRaw(allocator: std.mem.Allocator, sock: []const u8, buf: []u8) ListFailure![]const u8 {
    var conn = muxclient.Conn.connect(allocator, sock) catch return error.ListConnect;
    defer conn.deinit();
    conn.sendFrame(.list, "") catch return error.ListSend;
    const frame = conn.recvExpectFor(&.{.welcome}, 15_000) catch return error.ListReply;
    defer frame.deinit(allocator);
    // A clipped welcome is the same vacuity hazard as no welcome at all.
    if (frame.payload.len > buf.len) return error.ListTruncated;
    @memcpy(buf[0..frame.payload.len], frame.payload);
    return buf[0..frame.payload.len];
}

/// `listSessionsRaw` plus the well-formedness control every assertion
/// over the listing depends on: this really is a daemon's welcome, so
/// "X is not in it" means X is absent rather than that nothing was read.
fn listSessionsChecked(allocator: std.mem.Allocator, sock: []const u8, buf: []u8, what: []const u8) []const u8 {
    const listing = listSessionsRaw(allocator, sock, buf) catch |e| {
        say(what);
        say(sock);
        say(@errorName(e));
        fail("the daemon could not be listed, so nothing may be concluded from its listing");
    };
    if (std.mem.indexOf(u8, listing, "\"daemon_pid\":") == null or
        std.mem.indexOf(u8, listing, "\"sessions\":") == null)
    {
        say(what);
        say(listing);
        fail("the list reply is not a daemon welcome");
    }
    return listing;
}

/// Append one line to `$SKETERM_FAKE_WEB_FRAMES`, the fake helper's
/// record of what the client actually put on the wire. Context
/// publication has no ack, so the FRAMES are the only evidence that the
/// right id was sent, in the right order, to the right helper.
fn fakeFrameLog(comptime fmt: []const u8, args: anytype) void {
    const path = c.getenv("SKETERM_FAKE_WEB_FRAMES") orelse return;
    const f = c.fopen(path, "a") orelse return;
    defer _ = c.fclose(f);
    var line: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&line, fmt, args) catch return;
    _ = c.fwrite(s.ptr, 1, s.len, f);
}

/// A minimal `sketerm-webengine` stand-in speaking protocol v1: dumps
/// the environment webdrive handed it, answers the handshake, and
/// serves just enough (nav events + a full snapshot) for `web_open` to
/// settle. `SKETERM_FAKE_WEB_EXIT=1` = die on startup instead, the
/// broken-CEF shape the session fallback must absorb.
/// Two NAMED MCP servers, one instance, one engine, one broker-owned
/// profile store: the Phase 2 acceptance. Client A writes a cookie in
/// named profile "shared"; client B — connected AT THE SAME TIME —
/// reads it back from the SAME live context; A's exit costs B nothing;
/// the store flock is held by the daemon, not by either client.
fn webSharedProfileStage(allocator: std.mem.Allocator, exe: [*:0]const u8, rt: []const u8) void {
    // The broker spawns the engine with this linger (Phase 3); the
    // stage's tail waits out the TTL reap rather than an
    // exit-with-last-client that no longer happens.
    _ = c.setenv("SKETERM_WEB_LINGER_MS", "3000", 1);
    defer _ = c.unsetenv("SKETERM_WEB_LINGER_MS");
    var http = TinyHttp.start() orelse fail("could not bind a loopback HTTP server for the shared-profile stage");
    defer http.deinit();
    http.spawn();
    var origin_buf: [64]u8 = undefined;
    const origin = std.fmt.bufPrint(&origin_buf, "http://127.0.0.1:{d}/", .{http.port}) catch unreachable;
    var args_buf: [1024]u8 = undefined;

    var a = Mcp.spawn(allocator, exe, &.{ "--name", "smokeshared" });
    a.initialize();
    a.sendTool("web_open", std.fmt.bufPrint(&args_buf, "{{\"url\":\"{s}\",\"profile\":\"shared\"}}", .{origin}) catch unreachable);
    if (std.mem.indexOf(u8, a.recvLine(60_000), "isError") != null)
        fail("client A could not open a named profile on a named instance");
    if (std.mem.indexOf(u8, a.callTool("web_eval", "{\"code\":\"document.cookie='shared=acrossclients; max-age=86400; path=/'; document.cookie\"}"), "shared=acrossclients") == null)
        fail("client A could not write the profile cookie");

    // The store flock belongs to the DAEMON: its lock file names a pid
    // that is neither client and is a live sketerm-mux.
    {
        var lock_buf: [512]u8 = undefined;
        var content: [8192]u8 = undefined;
        const lock_path = std.fmt.bufPrint(&lock_buf, "{s}/sketerm/web-profiles/smokeshared/lock", .{rt}) catch unreachable;
        const text = std.mem.trim(u8, readSmall(lock_path, &content), " \t\r\n");
        const holder = std.fmt.parseInt(c.pid_t, text, 10) catch fail("the profile store lock file does not name a pid");
        if (holder == a.pid) fail("the profile store flock is held by client A, not the broker");
        var comm_buf: [256]u8 = undefined;
        var comm_data: [8192]u8 = undefined;
        const comm_path = std.fmt.bufPrint(&comm_buf, "/proc/{d}/comm", .{holder}) catch unreachable;
        if (std.mem.indexOf(u8, readSmall(comm_path, &comm_data), "sketerm-mux") == null)
            fail("the profile store flock holder is not the mux daemon");
    }

    // Client B, SAME instance, while A is live: profiles must work (the
    // old shape refused the second client outright) and the cookie must
    // be visible — same store, same id, same LIVE engine context.
    var b = Mcp.spawn(allocator, exe, &.{ "--name", "smokeshared" });
    b.initialize();
    b.sendTool("web_open", std.fmt.bufPrint(&args_buf, "{{\"url\":\"{s}\",\"profile\":\"shared\"}}", .{origin}) catch unreachable);
    if (std.mem.indexOf(u8, b.recvLine(60_000), "isError") != null)
        fail("client B was refused a named profile while A holds one (the pre-broker single-owner behavior)");
    if (std.mem.indexOf(u8, b.callTool("web_eval", "{\"code\":\"document.cookie\"}"), "shared=acrossclients") == null)
        fail("client B does not see A's cookie: the named profile is not one shared live context");

    // One engine serves both: exactly one primary sketerm-webengine
    // (the --socket owner; CEF's own subprocesses carry --type=).
    if (countPrimaryWebengines(allocator, rt) != 1)
        fail("the two clients are not sharing one webengine process");

    // A leaves; B keeps its live session AND the engine.
    a.closeStdinWait();
    if (std.mem.indexOf(u8, b.callTool("web_eval", "{\"code\":\"document.cookie\"}"), "shared=acrossclients") == null)
        fail("client A's exit broke client B's live profile context");
    if (countPrimaryWebengines(allocator, rt) != 1)
        fail("the engine did not survive client A's exit");

    // B leaves; the broker-owned engine LINGERS past its last client
    // (Phase 3) and then reaps ITSELF through the graceful drain (the
    // path that runs cef_shutdown and flushes the jar).
    b.closeStdinWait();
    _ = c.usleep(700_000);
    if (countPrimaryWebengines(allocator, rt) != 1)
        fail("the broker-owned engine did not linger past its last client");
    var tries: u32 = 0;
    while (tries < 400) : (tries += 1) {
        if (countPrimaryWebengines(allocator, rt) == 0) break;
        _ = c.usleep(50_000);
    }
    if (tries >= 400) fail("the lingering engine never reaped itself after its TTL");
}

/// The page the presenter stage serves: a solid colour a frame can be
/// checked against, and a title that answers a click and a key, so
/// seat input injected by a VIEWER is proven to reach the page.
const PRESENTER_BODY =
    "<html><head><title>PRESENTER-PAGE</title>" ++
    "<style>html,body{margin:0;height:100%;background:#3060c0}</style></head>" ++
    "<body onclick=\"document.title='PRESENTER-CLICKED'\">" ++
    "<script>document.addEventListener('keydown',function(e){document.title='PRESENTER-KEY-'+e.key});</script>" ++
    "</body></html>";

/// The page colour above, in wl_shm byte order (B, G, R).
const PRESENTER_BGR = [3]u8{ 0xc0, 0x60, 0x30 };

fn presenterCenterMatches(px: [4]u8) bool {
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const d = @as(i32, px[i]) - @as(i32, PRESENTER_BGR[i]);
        if (d > 8 or d < -8) return false;
    }
    return true;
}

fn presenterAwait(app: *appdrive.App, title: []const u8, deadline_ms: i64) ?u32 {
    while (true) {
        for (app.windows.items) |win| {
            if (win.frames == 0 or win.w <= 0 or win.h <= 0 or
                !std.mem.eql(u8, win.title orelse "", title)) continue;
            const off = (@as(usize, @intCast(@divTrunc(win.h, 2))) * @as(usize, @intCast(win.w)) +
                @as(usize, @intCast(@divTrunc(win.w, 2)))) * 4;
            if (off + 4 <= win.pixels.items.len and presenterCenterMatches(win.pixels.items[off..][0..4].*)) return win.id;
        }
        if (nowMs() >= deadline_ms or app.exited) return null;
        _ = app.pumpOnce(@intCast(@min(200, @max(0, deadline_ms - nowMs()))));
    }
}

/// A JSON string field's value out of `web.json` (no escapes in the
/// values written there: a daemon-validated name and a path we minted).
fn presenceField(json: []const u8, key: []const u8, buf: []u8) ?[]const u8 {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":\"", .{key}) catch return null;
    const at = std.mem.indexOf(u8, json, needle) orelse return null;
    const start = at + needle.len;
    const end = std.mem.indexOfScalarPos(u8, json, start, '"') orelse return null;
    const v = json[start..end];
    if (v.len > buf.len) return null;
    @memcpy(buf[0..v.len], v);
    return buf[0..v.len];
}

/// Watch-along, end to end against the REAL helper: the MCP opens a
/// solid-colour page; a viewer attached to the web session sees a
/// toplevel titled after the page and painted in its colour; a click
/// and a key injected through the viewer's seat reach the page (its
/// title answers), and the assistant's own tools still work after.
fn webPresenterStage(allocator: std.mem.Allocator, exe: [*:0]const u8, rt: []const u8) void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var http = TinyHttp.start() orelse fail("could not bind a loopback HTTP server for the presenter stage");
    defer http.deinit();
    http.body = PRESENTER_BODY;
    http.spawn();
    var url_buf: [96]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/presenter", .{http.port}) catch unreachable;

    var m = Mcp.spawn(allocator, exe, &.{});
    m.initialize();
    var args_buf: [512]u8 = undefined;
    m.sendTool("web_open", std.fmt.bufPrint(&args_buf, "{{\"url\":\"{s}\"}}", .{url}) catch unreachable);
    if (std.mem.indexOf(u8, m.recvLine(60_000), "isError") != null)
        fail("presenter: web_open failed against the session-mode helper");

    // The facts a human needs come from `capabilities`, reported, not
    // inferred: session backend, the presenter armed, the socket.
    const caps = m.callTool("capabilities", "{}");
    if (std.mem.indexOf(u8, caps, "\"web_backend\":\"session\"") == null)
        fail("presenter: the helper did not run in session mode (web_backend is not \"session\")");
    if (std.mem.indexOf(u8, caps, "\"web_watch\":true") == null)
        fail("presenter: capabilities did not report web_watch:true (the helper did not advertise the presenter)");
    if (std.mem.indexOf(u8, caps, "\"mux_socket\":\"") == null)
        fail("presenter: capabilities did not report the private mux socket");

    var wj_path: [512]u8 = undefined;
    const wj = std.fmt.bufPrint(&wj_path, "{s}/sketerm/mcp-tmp-{d}/web.json", .{ rt, m.pid }) catch unreachable;
    var wj_buf: [8192]u8 = undefined;
    const presence = readSmall(wj, &wj_buf);
    var session_buf: [64]u8 = undefined;
    const session = presenceField(presence, "session", &session_buf) orelse fail("presenter: web.json names no session");
    var sock_buf: [512]u8 = undefined;
    const mux_sock = presenceField(presence, "mux_socket", &sock_buf) orelse fail("presenter: web.json names no mux_socket");

    const viewer = appdrive.App.attachExisting(allocator, session, null, mux_sock, null) catch
        fail("presenter: could not attach the multi-channel viewer");
    defer viewer.detach();
    const win_id = presenterAwait(viewer, "PRESENTER-PAGE", nowMs() + 30_000) orelse
        fail("presenter: no toplevel titled PRESENTER-PAGE painted in the page colour reached the viewer");
    const win = viewer.winById(win_id) orelse fail("presenter: the page window vanished");
    const chan = win.chan;
    const sid = win.sid;
    viewer.clickEx(win_id, @floatFromInt(@divTrunc(win.w, 2)), @floatFromInt(@divTrunc(win.h, 2)), 1, 100, 1) catch
        fail("presenter: could not inject the viewer's click");
    if (presenterAwait(viewer, "PRESENTER-CLICKED", nowMs() + 15_000) == null) {
        std.debug.print("smoke-mcp: presenter input channel={d} surface={d}\n", .{ chan, sid });
        say(m.callTool("web_wait", "{\"for\":\"title\",\"arg\":\"PRESENTER-CLICKED\",\"timeout_ms\":1000}"));
        fail("presenter: the viewer did not receive the clicked page title");
    }
    const clicked = capSc(arena, m.callTool("web_wait", "{\"for\":\"title\",\"arg\":\"PRESENTER-CLICKED\",\"timeout_ms\":1000}"), "presenter page click", false);
    if (!clicked.get("settled").?.bool or !std.mem.eql(u8, clicked.get("title").?.string, "PRESENTER-CLICKED"))
        fail("presenter: the page did not confirm the viewer's click");
    viewer.pressKey(win_id, "a") catch fail("presenter: could not inject the viewer's key");
    if (presenterAwait(viewer, "PRESENTER-KEY-a", nowMs() + 15_000) == null)
        fail("presenter: the viewer did not receive the keyed page title");

    // The assistant's own tools keep working underneath the viewer.
    if (std.mem.indexOf(u8, m.callTool("web_eval", "{\"code\":\"document.title\"}"), "PRESENTER-KEY-a") == null)
        fail("presenter: web_eval does not see the title the viewer's input produced");

    m.closeStdinWait();
}

/// Phase 3, the broker-owned engine LIFECYCLE across client
/// GENERATIONS: a cookie written by one MCP client survives into a
/// client that starts after the first has fully exited (same live
/// engine, warm start), and survives the engine's own TTL reap onto
/// disk (read back by a third generation's fresh engine).
fn webEngineLifecycleStage(allocator: std.mem.Allocator, exe: [*:0]const u8, rt: []const u8) void {
    _ = c.setenv("SKETERM_WEB_LINGER_MS", "4000", 1);
    defer _ = c.unsetenv("SKETERM_WEB_LINGER_MS");
    var http = TinyHttp.start() orelse fail("could not bind a loopback HTTP server for the engine-lifecycle stage");
    defer http.deinit();
    http.spawn();
    var origin_buf: [64]u8 = undefined;
    const origin = std.fmt.bufPrint(&origin_buf, "http://127.0.0.1:{d}/", .{http.port}) catch unreachable;
    var args_buf: [1024]u8 = undefined;

    // Generation A: cold engine, write the cookie, leave.
    var a = Mcp.spawn(allocator, exe, &.{ "--name", "smokeengine" });
    a.initialize();
    const cold_t0 = nowMs();
    a.sendTool("web_open", std.fmt.bufPrint(&args_buf, "{{\"url\":\"{s}\",\"profile\":\"keep\"}}", .{origin}) catch unreachable);
    if (std.mem.indexOf(u8, a.recvLine(60_000), "isError") != null)
        fail("generation A could not open its profile");
    const cold_ms = nowMs() - cold_t0;
    if (std.mem.indexOf(u8, a.callTool("web_eval", "{\"code\":\"document.cookie='gen=alpha; max-age=86400; path=/'; document.cookie\"}"), "gen=alpha") == null)
        fail("generation A could not write its cookie");
    const engine_a = primaryWebenginePid(allocator, rt);
    if (engine_a == 0) fail("no engine serving generation A");
    a.closeStdinWait();

    // The engine outlives the whole CLIENT GENERATION.
    _ = c.usleep(700_000);
    if (primaryWebenginePid(allocator, rt) != engine_a)
        fail("the engine did not survive generation A's exit");

    // Generation B: same engine (warm), same live jar.
    var b = Mcp.spawn(allocator, exe, &.{ "--name", "smokeengine" });
    b.initialize();
    const warm_t0 = nowMs();
    b.sendTool("web_open", std.fmt.bufPrint(&args_buf, "{{\"url\":\"{s}\",\"profile\":\"keep\"}}", .{origin}) catch unreachable);
    if (std.mem.indexOf(u8, b.recvLine(60_000), "isError") != null)
        fail("generation B could not open the surviving profile");
    const warm_ms = nowMs() - warm_t0;
    if (primaryWebenginePid(allocator, rt) != engine_a)
        fail("generation B was served by a different engine (no warm adoption)");
    if (std.mem.indexOf(u8, b.callTool("web_eval", "{\"code\":\"document.cookie\"}"), "gen=alpha") == null)
        fail("generation B does not see generation A's live session");
    var lat_buf: [128]u8 = undefined;
    say(std.fmt.bufPrint(&lat_buf, "smoke-mcp: [phase3] web_open cold {d}ms, warm {d}ms", .{ cold_ms, warm_ms }) catch "smoke-mcp: [phase3] latency printed");
    b.closeStdinWait();

    // Nobody comes back: TTL reap (graceful by construction).
    var tries: u32 = 0;
    while (tries < 400) : (tries += 1) {
        if (countPrimaryWebengines(allocator, rt) == 0) break;
        _ = c.usleep(50_000);
    }
    if (tries >= 400) fail("the engine never reaped itself after its TTL");

    // Generation C: fresh engine, the cookie CAME BACK FROM DISK — the
    // reap was the graceful flushing path.
    var cgen = Mcp.spawn(allocator, exe, &.{ "--name", "smokeengine" });
    cgen.initialize();
    cgen.sendTool("web_open", std.fmt.bufPrint(&args_buf, "{{\"url\":\"{s}\",\"profile\":\"keep\"}}", .{origin}) catch unreachable);
    if (std.mem.indexOf(u8, cgen.recvLine(60_000), "isError") != null)
        fail("generation C could not reopen the profile");
    if (std.mem.indexOf(u8, cgen.callTool("web_eval", "{\"code\":\"document.cookie\"}"), "gen=alpha") == null)
        fail("the TTL reap lost the jar: generation C read no cookie from disk");
    cgen.closeStdinWait();
    tries = 0;
    while (tries < 400) : (tries += 1) {
        if (countPrimaryWebengines(allocator, rt) == 0) break;
        _ = c.usleep(50_000);
    }
    if (tries >= 400) fail("generation C's engine never reaped itself");
}

/// Pid of the single primary webengine under `rt`, or 0.
fn primaryWebenginePid(allocator: std.mem.Allocator, rt: []const u8) c.pid_t {
    var pid: c.pid_t = 0;
    var count: usize = 0;
    scanPrimaryWebengines(allocator, rt, &pid, &count);
    return if (count == 1) pid else 0;
}

/// Primary webengine processes under `rt`: cmdline names the binary
/// AND `--socket` (CEF's zygote/renderer subprocesses carry --type=
/// and must not count).
fn countPrimaryWebengines(allocator: std.mem.Allocator, rt: []const u8) usize {
    var pid: c.pid_t = 0;
    var count: usize = 0;
    scanPrimaryWebengines(allocator, rt, &pid, &count);
    return count;
}

fn scanPrimaryWebengines(allocator: std.mem.Allocator, rt: []const u8, first_pid: *c.pid_t, count_out: *usize) void {
    first_pid.* = 0;
    count_out.* = 0;
    const d = c.opendir("/proc") orelse return;
    defer _ = c.closedir(d);
    var needle_buf: [4096]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "XDG_RUNTIME_DIR={s}", .{rt}) catch return;
    while (c.readdir(d)) |ent| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
        if (name.len == 0 or name[0] < '0' or name[0] > '9') continue;
        var path_buf: [256]u8 = undefined;
        var data: std.ArrayList(u8) = .empty;
        defer data.deinit(allocator);
        {
            const path = std.fmt.bufPrintZ(&path_buf, "/proc/{s}/cmdline", .{name}) catch continue;
            const f = c.fopen(path.ptr, "rb") orelse continue;
            defer _ = c.fclose(f);
            var tmp: [4096]u8 = undefined;
            while (true) {
                const n = c.fread(&tmp, 1, tmp.len, f);
                if (n == 0) break;
                data.appendSlice(allocator, tmp[0..n]) catch break;
            }
        }
        if (std.mem.indexOf(u8, data.items, "sketerm-webengine") == null) continue;
        if (std.mem.indexOf(u8, data.items, "--socket") == null) continue;
        if (std.mem.indexOf(u8, data.items, "--type=") != null) continue;
        var env_data: std.ArrayList(u8) = .empty;
        defer env_data.deinit(allocator);
        {
            const path = std.fmt.bufPrintZ(&path_buf, "/proc/{s}/environ", .{name}) catch continue;
            const f = c.fopen(path.ptr, "rb") orelse continue;
            defer _ = c.fclose(f);
            var tmp: [4096]u8 = undefined;
            while (true) {
                const n = c.fread(&tmp, 1, tmp.len, f);
                if (n == 0) break;
                env_data.appendSlice(allocator, tmp[0..n]) catch break;
            }
        }
        if (std.mem.indexOf(u8, env_data.items, needle) == null) continue;
        if (count_out.* == 0) {
            first_pid.* = std.fmt.parseInt(c.pid_t, name, 10) catch 0;
        }
        count_out.* += 1;
    }
}

fn fakeWebengine(allocator: std.mem.Allocator, sock_path: []const u8) u8 {
    if (c.getenv("SKETERM_FAKE_WEB_ENV")) |out_path| {
        const f = c.fopen(out_path, "w");
        if (f) |fp| {
            defer _ = c.fclose(fp);
            for ([_][*:0]const u8{ "WAYLAND_DISPLAY", "XDG_RUNTIME_DIR", "XDG_SESSION_TYPE", "PULSE_SERVER", "LIBGL_ALWAYS_SOFTWARE", "SKETERM_WEB_OZONE", "SKETERM_WEB_GPU", "WAYLAND_SOCKET", "DISPLAY" }) |key| {
                const val = if (c.getenv(key)) |v| std.mem.span(@as([*:0]const u8, v)) else "";
                var line: [4300]u8 = undefined;
                const s = std.fmt.bufPrint(&line, "{s}={s}\n", .{ key, val }) catch continue;
                _ = c.fwrite(s.ptr, 1, s.len, fp);
            }
        }
    }
    if (c.getenv("SKETERM_FAKE_WEB_EXIT") != null) {
        say("Authorization: Bearer DO-NOT-EXPOSE-STARTUP-SECRET");
        say("FATAL startup fixture: shutdown: Operation not permitted (1)");
        return 23;
    }

    var addr = std.mem.zeroes(c.struct_sockaddr_un);
    if (sock_path.len + 1 > addr.sun_path.len) return 1;
    addr.sun_family = c.AF_UNIX;
    @memcpy(addr.sun_path[0..sock_path.len], sock_path);
    const lfd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (lfd < 0) return 1;
    if (c.bind(lfd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0) return 1;
    if (c.listen(lfd, 1) != 0) return 1;
    const fd = c.accept(lfd, null, null);
    if (fd < 0) return 1;
    _ = c.close(lfd);

    var in: std.ArrayList(u8) = .empty;
    defer in.deinit(allocator);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var url_buf: [2048]u8 = undefined;
    var url_len: usize = 0;
    // The last received policy per view (tiny: the stages open few).
    var pol_views: [8]u32 = @splat(0);
    var pol_serials: [8]u32 = @splat(0);
    var pol_n: usize = 0;
    const policy_ack = c.getenv("SKETERM_FAKE_WEB_POLICY") != null and c.getenv("SKETERM_FAKE_WEB_POLICY_LEGACY") == null;
    while (true) {
        var tmp: [65536]u8 = undefined;
        const n = c.read(fd, &tmp, tmp.len);
        if (n <= 0) return 0; // client gone = normal helper exit
        in.appendSlice(allocator, tmp[0..@intCast(n)]) catch return 1;
        var reader = webproto.Reader.init(in.items);
        while (reader.next() catch return 1) |frame| {
            out.clearRetainingCapacity();
            switch (frame.tag) {
                .hello => {
                    // Identity contexts are OPT-IN here: the default
                    // fake is an old helper, which is exactly what the
                    // fail-closed regression guard needs.
                    const with_contexts = c.getenv("SKETERM_FAKE_WEB_CONTEXTS") != null;
                    const with_policy = c.getenv("SKETERM_FAKE_WEB_POLICY") != null;
                    const base = [_][]const u8{ webproto.CAP_FRAMES_SHM, webproto.CAP_SEMANTIC, webproto.CAP_VIEW_CREATE_URL };
                    const ctx = base ++ [_][]const u8{ webproto.CAP_CONTEXTS, webproto.CAP_CONTEXTS_FAIL_CLOSED };
                    const legacy_pol = base ++ [_][]const u8{webproto.CAP_NET_POLICY};
                    const legacy_both = ctx ++ [_][]const u8{webproto.CAP_NET_POLICY};
                    const pol = legacy_pol ++ [_][]const u8{webproto.CAP_NET_POLICY_ACK};
                    const both = legacy_both ++ [_][]const u8{webproto.CAP_NET_POLICY_ACK};
                    const caps: []const []const u8 = if (with_contexts and with_policy)
                        (if (policy_ack) &both else &legacy_both)
                    else if (with_contexts)
                        &ctx
                    else if (with_policy)
                        (if (policy_ack) &pol else &legacy_pol)
                    else
                        &base;
                    webproto.encode(allocator, &out, webproto.HelloAck{
                        .proto = webproto.PROTO_VERSION,
                        .engine_name = "fake",
                        .engine_version = "0",
                        .caps = caps,
                    }) catch return 1;
                },
                .net_policy_set => {
                    const req = webproto.NetPolicySet.decodeAlloc(frame.payload, allocator) catch return 1;
                    defer allocator.free(req.allow_top);
                    defer allocator.free(req.allow_sub);
                    fakeFrameLog("net_policy_set view={d} serial={d} top={d} max_requests={d} schemes={d} private={d}\n", .{
                        req.view,          req.serial,
                        req.allow_top.len, req.max_requests,
                        req.allow_schemes, @intFromBool(req.flags & webproto.NetPolicySet.flag_allow_private != 0),
                    });
                    if (pol_n < pol_views.len) {
                        pol_views[pol_n] = req.view;
                        pol_serials[pol_n] = req.serial;
                        pol_n += 1;
                    }
                    if (policy_ack) {
                        webproto.encode(allocator, &out, webproto.EvNetPolicy{
                            .view = req.view,
                            .serial = req.serial,
                            .active = 1,
                            .exhausted = 0,
                            .requests = 0,
                            .bytes = 0,
                            .navigations = 0,
                            .ms_left = 0,
                            .denied = @splat(0),
                        }) catch return 1;
                        fakeFrameLog("net_policy_ack view={d} serial={d}\n", .{ req.view, req.serial });
                    }
                },
                .net_policy_req => {
                    const req = webproto.decode(webproto.NetPolicyReq, frame.payload) catch return 1;
                    var serial: u32 = 0;
                    for (pol_views[0..pol_n], pol_serials[0..pol_n]) |v, s| {
                        if (v == req.view) serial = s;
                    }
                    const active = serial != 0;
                    if (req.serial != 0) serial = req.serial;
                    const exhausted = c.getenv("SKETERM_FAKE_WEB_POLICY_EXHAUST") != null;
                    webproto.encode(allocator, &out, webproto.EvNetPolicy{
                        .view = req.view,
                        .serial = serial,
                        .active = @intFromBool(active),
                        .exhausted = if (exhausted) @intFromEnum(webproto.NetReason.request_cap) else 0,
                        .requests = if (exhausted) 5 else 1,
                        .bytes = 100,
                        .navigations = 1,
                        .ms_left = 0,
                        .denied = @splat(0),
                    }) catch return 1;
                },
                .context_create => {
                    const req = webproto.decode(webproto.ContextCreate, frame.payload) catch return 1;
                    fakeFrameLog("context_create id={d} ephemeral={d} name={s}\n", .{ req.id, req.ephemeral, req.name });
                },
                .context_destroy => {
                    const req = webproto.decode(webproto.ContextDestroy, frame.payload) catch return 1;
                    fakeFrameLog("context_destroy id={d}\n", .{req.id});
                },
                .view_create_url => {
                    const req = webproto.decode(webproto.ViewCreateUrl, frame.payload) catch return 1;
                    fakeFrameLog("view_create_url view={d} context={d}\n", .{ req.view, req.context });
                    // The one negative signal a context request has:
                    // the view never comes up, and the client must
                    // report that instead of navigating anywhere.
                    if (req.context != 0 and c.getenv("SKETERM_FAKE_WEB_CONTEXT_FAIL") != null) {
                        webproto.encode(allocator, &out, webproto.EvViewCreateFailed{
                            .view = req.view,
                            .context = req.context,
                            .reason = "requested browser context does not exist",
                        }) catch return 1;
                    } else {
                        url_len = @min(req.url.len, url_buf.len);
                        @memcpy(url_buf[0..url_len], req.url[0..url_len]);
                        webproto.encode(allocator, &out, webproto.EvNavState{
                            .view = req.view,
                            .can_back = 0,
                            .can_fwd = 0,
                            .loading = 0,
                            .url = url_buf[0..url_len],
                        }) catch return 1;
                        webproto.encode(allocator, &out, webproto.EvLoad{
                            .view = req.view,
                            .state = @intFromEnum(webproto.LoadState.finished),
                            .url = url_buf[0..url_len],
                        }) catch return 1;
                        // A policied view under the exhaust switch
                        // latches immediately: the client's settle pump
                        // sees the event with no extra round trip.
                        if (c.getenv("SKETERM_FAKE_WEB_POLICY_EXHAUST") != null) {
                            var serial: u32 = 0;
                            for (pol_views[0..pol_n], pol_serials[0..pol_n]) |v, s| {
                                if (v == req.view) serial = s;
                            }
                            if (serial != 0) {
                                webproto.encode(allocator, &out, webproto.EvNetPolicy{
                                    .view = req.view,
                                    .serial = serial,
                                    .active = 1,
                                    .exhausted = @intFromEnum(webproto.NetReason.request_cap),
                                    .requests = 5,
                                    .bytes = 100,
                                    .navigations = 1,
                                    .ms_left = 0,
                                    .denied = @splat(0),
                                }) catch return 1;
                            }
                        }
                    }
                },
                .sem_snapshot_req => {
                    const req = webproto.decode(webproto.SemSnapshotReq, frame.payload) catch return 1;
                    webproto.encode(allocator, &out, webproto.SemSnapshot{
                        .view = req.view,
                        .doc_gen = 1,
                        .rev = 1,
                        .kind = @intFromEnum(webproto.SnapKind.full),
                        .payload = .{ .s = "[1] FAKE-SESSION-DOC\n" },
                    }) catch return 1;
                },
                else => {},
            }
            var off: usize = 0;
            while (off < out.items.len) {
                const wn = c.write(fd, out.items.ptr + off, out.items.len - off);
                if (wn <= 0) return 0;
                off += @intCast(wn);
            }
        }
        const used = reader.consumed();
        if (used != 0 and used <= in.items.len) {
            const rest = in.items.len - used;
            std.mem.copyForwards(u8, in.items[0..rest], in.items[used..]);
            in.shrinkRetainingCapacity(rest);
        }
    }
}

/// CEF-free proof of the watchable web session: the fake helper above
/// stands in for sketerm-webengine, and the stage asserts the session
/// exists on the instance daemon, that its exact environment reached
/// the helper, that capabilities + web.json name it, that a
/// helper-startup failure falls back headless WITHOUT leaking the
/// session, and that SKETERM_WEB_SESSION=0 opts out.
fn webSessionFakeStage(allocator: std.mem.Allocator, exe: [*:0]const u8, rt: []const u8) void {
    // Resolve OUR OWN binary here: "/proc/self/exe" would resolve in
    // the MCP process and hand webdrive `sketerm` as its "helper".
    var self_buf: [4096:0]u8 = undefined;
    const self_len = c.readlink("/proc/self/exe", &self_buf, self_buf.len - 1);
    if (self_len <= 0) fail("cannot resolve the smoke binary path");
    self_buf[@intCast(self_len)] = 0;
    _ = c.setenv("SKETERM_WEB_BIN", &self_buf, 1);
    defer _ = c.unsetenv("SKETERM_WEB_BIN");
    _ = c.setenv("SKETERM_FAKE_WEBENGINE", "1", 1);
    defer _ = c.unsetenv("SKETERM_FAKE_WEBENGINE");
    var envout_buf: [512]u8 = undefined;
    const envout = std.fmt.bufPrintZ(&envout_buf, "{s}/fake-web-env.txt", .{rt}) catch unreachable;
    _ = c.setenv("SKETERM_FAKE_WEB_ENV", envout.ptr, 1);
    defer _ = c.unsetenv("SKETERM_FAKE_WEB_ENV");
    var args_buf: [256]u8 = undefined;
    var probe_buf: [512]u8 = undefined;
    var file_buf: [8192]u8 = undefined;
    var list_buf: [128 * 1024]u8 = undefined;

    {
        var m = Mcp.spawn(allocator, exe, &.{});
        m.initialize();
        m.sendTool("web_open", "{\"url\":\"https://smoke.invalid/session\"}");
        const opened = m.recvLine(60_000);
        if (std.mem.indexOf(u8, opened, "isError") != null)
            fail("web_open failed against the fake session helper");
        if (std.mem.indexOf(u8, opened, "FAKE-SESSION-DOC") == null)
            fail("web_open's snapshot did not come from the fake helper");

        const caps = m.callTool("capabilities", "{}");
        if (std.mem.indexOf(u8, caps, "\"web_backend\":\"session\"") == null or
            std.mem.indexOf(u8, caps, "\"web_session\":\"web-") == null)
            fail("capabilities does not report the watchable web session");

        const pj = readSmall(std.fmt.bufPrint(&probe_buf, "{s}/sketerm/mcp-tmp-{d}/web.json", .{ rt, m.pid }) catch unreachable, &file_buf);
        if (std.mem.indexOf(u8, pj, "\"session\":\"web-") == null or
            std.mem.indexOf(u8, pj, "mux.sock") == null)
            fail("web.json does not name the watchable session + daemon socket");

        // The instance daemon really hosts it, as a display session.
        const priv = std.fmt.bufPrint(&args_buf, "{s}/sketerm/mcp-tmp-{d}/mux.sock", .{ rt, m.pid }) catch unreachable;
        const listing = listSessionsChecked(allocator, priv, &list_buf, "web session listing");
        if (std.mem.indexOf(u8, listing, "web-") == null or
            std.mem.indexOf(u8, listing, "\"display\":true") == null)
            fail("the instance daemon does not list the web session as a display session");

        // The helper got the DAEMON'S environment, never a derived one.
        const env = readSmall(envout, &file_buf);
        const wl_at = std.mem.indexOf(u8, env, "WAYLAND_DISPLAY=") orelse fail("fake helper recorded no environment");
        const wl_line = env[wl_at + "WAYLAND_DISPLAY=".len ..];
        const wl_end = std.mem.indexOfScalar(u8, wl_line, '\n') orelse fail("malformed env dump");
        const wl = wl_line[0..wl_end];
        if (wl.len == 0) fail("helper started without the session's WAYLAND_DISPLAY");
        if (std.mem.indexOf(u8, listing, wl) == null)
            fail("the helper's WAYLAND_DISPLAY is not the daemon-reported session display");
        if (std.mem.indexOf(u8, env, "SKETERM_WEB_OZONE=wayland\n") == null or
            std.mem.indexOf(u8, env, "LIBGL_ALWAYS_SOFTWARE=1\n") == null or
            std.mem.indexOf(u8, env, "SKETERM_WEB_GPU=0\n") == null or
            std.mem.indexOf(u8, env, "WAYLAND_SOCKET=\n") == null or
            std.mem.indexOf(u8, env, "DISPLAY=\n") == null)
            fail("session helper environment is missing the forced software-wayland recipe");
        m.closeStdinWait();
    }

    // A helper that dies on startup must cost the session, not the web
    // tools' error clarity — and must not leak the session.
    for ([_]bool{ false, true }) |broker| {
        _ = c.setenv("SKETERM_WEB_BROKER_ENGINE", if (broker) "1" else "0", 1);
        defer _ = c.setenv("SKETERM_WEB_BROKER_ENGINE", "0", 1);
        _ = c.setenv("SKETERM_FAKE_WEB_EXIT", "1", 1);
        defer _ = c.unsetenv("SKETERM_FAKE_WEB_EXIT");
        var m = Mcp.spawn(allocator, exe, if (broker) &.{ "--name", "diagnostic-failure" } else &.{});
        m.initialize();
        m.sendTool("web_open", "{\"url\":\"https://smoke.invalid/broken\"}");
        const failed = m.recvLine(60_000);
        if (std.mem.indexOf(u8, failed, "isError") == null or
            std.mem.indexOf(u8, failed, "before establishing its connection") == null or
            std.mem.indexOf(u8, failed, "\"exit_code\":23") == null or
            std.mem.indexOf(u8, failed, "Operation not permitted") == null or
            std.mem.indexOf(u8, failed, "DO-NOT-EXPOSE-STARTUP-SECRET") != null)
            fail("a startup-dead helper did not surface as the described startup error");
        if (broker and std.mem.indexOf(u8, failed, "broker's browser helper") == null)
            fail("broker startup failure was masked by a client-spawn fallback");
        var diagnostic_id: [64]u8 = undefined;
        const did = presenceField(failed, "id", &diagnostic_id) orelse fail("startup failure has no diagnostic id");
        const details = m.callTool("web_diagnostic", std.fmt.bufPrint(&args_buf, "{{\"id\":\"{s}\"}}", .{did}) catch unreachable);
        if (std.mem.indexOf(u8, details, "Operation not permitted") == null or
            std.mem.indexOf(u8, details, "\"stage\":\"connecting\"") == null or
            std.mem.indexOf(u8, details, "DO-NOT-EXPOSE-STARTUP-SECRET") != null)
            fail("diagnostic follow-up lost the evidence or exposed a secret");
        const priv = if (broker)
            std.fmt.bufPrint(&args_buf, "{s}/sketerm/mcp-diagnostic-failure/mux.sock", .{rt}) catch unreachable
        else
            std.fmt.bufPrint(&args_buf, "{s}/sketerm/mcp-tmp-{d}/mux.sock", .{ rt, m.pid }) catch unreachable;
        // The POSITIVE control is inside listSessionsChecked: an
        // unreachable daemon used to pass this leak check vacuously,
        // since an empty listing contains no "web-" either.
        const listing = listSessionsChecked(allocator, priv, &list_buf, "startup-dead helper leak check");
        if (std.mem.indexOf(u8, listing, "web-") != null)
            fail("the fallback leaked the web session on the instance daemon");
        m.closeStdinWait();
    }

    // Explicit opt-out: plain headless, no session anywhere.
    {
        _ = c.setenv("SKETERM_WEB_SESSION", "0", 1);
        defer _ = c.unsetenv("SKETERM_WEB_SESSION");
        var m = Mcp.spawn(allocator, exe, &.{});
        m.initialize();
        m.sendTool("web_open", "{\"url\":\"https://smoke.invalid/optout\"}");
        const opened = m.recvLine(60_000);
        if (std.mem.indexOf(u8, opened, "isError") != null)
            fail("web_open failed with the session opted out");
        const caps = m.callTool("capabilities", "{}");
        if (std.mem.indexOf(u8, caps, "\"web_backend\":\"headless\"") == null)
            fail("opt-out did not fall back to the plain headless backend");
        const pj = readSmall(std.fmt.bufPrint(&probe_buf, "{s}/sketerm/mcp-tmp-{d}/web.json", .{ rt, m.pid }) catch unreachable, &file_buf);
        // POSITIVE control first: `readSmall` answers "" for a missing
        // file, and a missing presence file names no session either.
        if (std.mem.indexOf(u8, pj, "\"mcp_pid\":") == null)
            fail("no presence file was written for the opted-out helper");
        if (presenceField(pj, "session", &args_buf)) |session| {
            if (session.len != 0) fail("opt-out still advertised a session in web.json");
        }
        m.closeStdinWait();
    }
}

/// CEF-free proof of the headless PROFILE lane. The fake helper stands
/// in for sketerm-webengine, so this runs everywhere and guards the
/// parts a real-CEF stage cannot see: the exact frames the client puts
/// on the wire, and what happens with a helper that lacks the caps.
///
/// Must run with the same `SKETERM_WEB_BIN`/`SKETERM_FAKE_WEBENGINE`
/// setup `webSessionFakeStage` establishes.
fn webProfileFakeStage(allocator: std.mem.Allocator, exe: [*:0]const u8, rt: []const u8) void {
    var self_buf: [4096:0]u8 = undefined;
    const self_len = c.readlink("/proc/self/exe", &self_buf, self_buf.len - 1);
    if (self_len <= 0) fail("cannot resolve the smoke binary path");
    self_buf[@intCast(self_len)] = 0;
    _ = c.setenv("SKETERM_WEB_BIN", &self_buf, 1);
    defer _ = c.unsetenv("SKETERM_WEB_BIN");
    _ = c.setenv("SKETERM_FAKE_WEBENGINE", "1", 1);
    defer _ = c.unsetenv("SKETERM_FAKE_WEBENGINE");
    // A session would add a Wayland compositor to every spawn here and
    // proves nothing about profiles.
    _ = c.setenv("SKETERM_WEB_SESSION", "0", 1);
    defer _ = c.unsetenv("SKETERM_WEB_SESSION");

    var probe_buf: [512]u8 = undefined;
    var file_buf: [64 * 1024]u8 = undefined;

    // (a) The fail-closed regression guard: an old helper (no context
    // caps) must REFUSE a profile and leave ZERO views behind. A
    // fallback to the shared jar would look like success here.
    {
        var m = Mcp.spawn(allocator, exe, &.{});
        m.initialize();
        m.sendTool("web_open", "{\"url\":\"https://smoke.invalid/p\",\"profile\":\"work\"}");
        const refused = m.recvLine(60_000);
        if (std.mem.indexOf(u8, refused, "\"isError\":true") == null or
            std.mem.indexOf(u8, refused, "\"code\":\"unavailable\"") == null)
            fail("a helper without the context caps did not refuse a profile");
        if (std.mem.indexOf(u8, refused, "no fallback to the shared cookie jar") == null)
            fail("the profile refusal does not state that nothing was opened");
        const tabs = m.callTool("web_tabs", "{}");
        if (std.mem.indexOf(u8, tabs, "\"count\":0") == null)
            fail("a refused profile still minted a view (the fail-closed regression)");
        // The same server must still open a NORMAL view: only the
        // profile is unavailable, not the browser.
        m.sendTool("web_open", "{\"url\":\"https://smoke.invalid/plain\"}");
        if (std.mem.indexOf(u8, m.recvLine(60_000), "\"isError\":true") != null)
            fail("a capless helper refused a plain web_open too");
        // profile+ephemeral together is a caller error, not a helper one.
        const both = m.callTool("web_open", "{\"profile\":\"work\",\"ephemeral\":true}");
        if (std.mem.indexOf(u8, both, "\"code\":\"invalid_args\"") == null)
            fail("web_open accepted 'profile' and ephemeral:true together");
        m.closeStdinWait();
    }

    _ = c.setenv("SKETERM_FAKE_WEB_CONTEXTS", "1", 1);
    defer _ = c.unsetenv("SKETERM_FAKE_WEB_CONTEXTS");
    var frames_buf: [512]u8 = undefined;
    const frames = std.fmt.bufPrintZ(&frames_buf, "{s}/fake-web-frames.txt", .{rt}) catch unreachable;
    _ = c.unlink(frames.ptr);
    _ = c.setenv("SKETERM_FAKE_WEB_FRAMES", frames.ptr, 1);
    defer _ = c.unsetenv("SKETERM_FAKE_WEB_FRAMES");

    // (b) With the caps, the context is published BEFORE the view that
    // names it, the id is persisted, and a WHOLE MCP RESTART re-sends
    // the SAME id — which is the only reason a profile's cookies are
    // still there afterwards.
    var first_id_buf: [32]u8 = undefined;
    var first_id: []const u8 = "";
    {
        var m = Mcp.spawn(allocator, exe, &.{});
        m.initialize();
        m.sendTool("web_open", "{\"url\":\"https://smoke.invalid/p\",\"profile\":\"work\"}");
        const opened = m.recvLine(60_000);
        // Read now: the reply lives in the shared scratch buffer.
        const first_view = viewHandleOf(opened);
        if (std.mem.indexOf(u8, opened, "\"isError\":true") != null)
            fail("web_open with a profile failed against the context-capable fake");
        if (std.mem.indexOf(u8, opened, "\"profile\":\"work\"") == null or
            std.mem.indexOf(u8, opened, "\"profile_kind\":\"named\"") == null)
            fail("web_open did not report the identity its view lives in");

        const log = readSmall(frames, &file_buf);
        const cc = std.mem.indexOf(u8, log, "context_create id=") orelse
            fail("no context_create reached the helper");
        const vc = std.mem.indexOf(u8, log, "view_create_url view=") orelse
            fail("no view_create_url reached the helper");
        // Frame ORDER is the whole contract: context_create has no ack.
        if (cc > vc) fail("the view was created before its identity context");
        if (std.mem.indexOf(u8, log, "ephemeral=0 name=profile-work") == null)
            fail("the published context is not the named persistent one");
        const id_start = cc + "context_create id=".len;
        const id_end = std.mem.indexOfScalar(u8, log[id_start..], ' ') orelse fail("malformed frame log");
        first_id = std.fmt.bufPrint(&first_id_buf, "{s}", .{log[id_start .. id_start + id_end]}) catch unreachable;
        // The view really carries that context, not 0 (the shared jar).
        if (std.mem.indexOf(u8, log[vc..], "context=0\n") != null)
            fail("the profile view was created in the SHARED default jar");

        // The store is where the docs say it is, and holds that id.
        const store = std.fmt.bufPrint(&probe_buf, "{s}/sketerm/web-profiles/anon/profiles.json", .{rt}) catch unreachable;
        const json = readSmall(store, &file_buf);
        if (std.mem.indexOf(u8, json, "\"name\":\"work\"") == null)
            fail("the profile was not persisted to profiles.json");

        const listed = m.callTool("web_profiles", "{}");
        if (std.mem.indexOf(u8, listed, "\"name\":\"work\"") == null or
            std.mem.indexOf(u8, listed, "\"contexts_supported\":true") == null)
            fail("web_profiles does not list the profile it just opened");
        if (std.mem.indexOf(u8, listed, "web-profiles/anon") == null)
            fail("web_profiles does not report where the storage lives");

        // capabilities is the discoverability half of fail-closed.
        const caps = m.callTool("capabilities", "{}");
        if (std.mem.indexOf(u8, caps, "\"web_profiles\":true") == null or
            std.mem.indexOf(u8, caps, "\"web_profile_store\":") == null)
            fail("capabilities does not advertise browser profiles");

        // (e) web_close removes the named view; with one left, that one
        // is what a handle-less call means again.
        m.sendTool("web_open", "{\"url\":\"https://smoke.invalid/second\"}");
        const second_view = viewHandleOf(m.recvLine(60_000));
        if (std.mem.indexOf(u8, m.callTool("web_close", "{}"), "\"target_required\"") == null)
            fail("a handle-less web_close with two tabs open was not refused");
        var close_buf: [96]u8 = undefined;
        const closed = m.callTool("web_close", std.fmt.bufPrint(&close_buf, "{{\"pane\":{d}}}", .{second_view}) catch unreachable);
        var want_buf2: [96]u8 = undefined;
        if (std.mem.indexOf(u8, closed, std.fmt.bufPrint(&want_buf2, "\"closed\":{d}", .{second_view}) catch unreachable) == null or
            std.mem.indexOf(u8, closed, std.fmt.bufPrint(&close_buf, "\"current\":{d}", .{first_view}) catch unreachable) == null)
            fail("web_close did not close the named view and name the one left");
        const after = m.callTool("web_tabs", "{}");
        if (std.mem.indexOf(u8, after, "\"count\":1") == null or
            std.mem.indexOf(u8, after, std.fmt.bufPrint(&close_buf, "\"view\":{d},", .{second_view}) catch unreachable) != null)
            fail("the closed view is still listed");
        m.closeStdinWait();
    }

    // The restart half of (b): a brand-new server, a brand-new helper,
    // and the SAME persisted id back on the wire.
    {
        _ = c.unlink(frames.ptr);
        var m = Mcp.spawn(allocator, exe, &.{});
        m.initialize();
        m.sendTool("web_open", "{\"url\":\"https://smoke.invalid/p\",\"profile\":\"work\"}");
        if (std.mem.indexOf(u8, m.recvLine(60_000), "\"isError\":true") != null)
            fail("the restarted server could not reopen the profile");
        const log = readSmall(frames, &file_buf);
        var want_buf: [64]u8 = undefined;
        const want = std.fmt.bufPrint(&want_buf, "context_create id={s} ephemeral=0 name=profile-work", .{first_id}) catch unreachable;
        if (std.mem.indexOf(u8, log, want) == null)
            fail("a restarted MCP server minted a NEW context id for the same profile (its jar would be empty)");

        // Reset is refused while a view uses it, and works once free.
        const busy = m.callTool("web_profile_reset", "{\"profile\":\"work\"}");
        if (std.mem.indexOf(u8, busy, "\"code\":\"conflict\"") == null)
            fail("web_profile_reset erased a profile that was in use");
        _ = m.callTool("web_close", "{}");
        const reset = m.callTool("web_profile_reset", "{\"profile\":\"work\"}");
        if (std.mem.indexOf(u8, reset, "\"deleted\":true") == null)
            fail("web_profile_reset did not erase the freed profile");
        const gone = m.callTool("web_profile_reset", "{\"profile\":\"work\"}");
        if (std.mem.indexOf(u8, gone, "\"code\":\"not_found\"") == null)
            fail("resetting an unknown profile is not a not_found");
        m.closeStdinWait();
    }

    // (d) Two servers, one instance key: the second cannot take the
    // store, says who has it, and still browses without a profile.
    {
        var owner = Mcp.spawn(allocator, exe, &.{});
        owner.initialize();
        owner.sendTool("web_open", "{\"url\":\"https://smoke.invalid/owner\",\"profile\":\"work\"}");
        if (std.mem.indexOf(u8, owner.recvLine(60_000), "\"isError\":true") != null)
            fail("the store owner could not open its profile");

        var second = Mcp.spawn(allocator, exe, &.{});
        second.initialize();
        second.sendTool("web_open", "{\"url\":\"https://smoke.invalid/second\",\"profile\":\"work\"}");
        const refused = second.recvLine(60_000);
        if (std.mem.indexOf(u8, refused, "\"isError\":true") == null)
            fail("a second MCP server shared the browser profile store");
        if (std.mem.indexOf(u8, refused, "owns the browser profile store") == null or
            std.mem.indexOf(u8, refused, "--name") == null)
            fail("the store-lock refusal does not name the owner or the way out");
        second.sendTool("web_open", "{\"url\":\"https://smoke.invalid/plain\"}");
        if (std.mem.indexOf(u8, second.recvLine(60_000), "\"isError\":true") != null)
            fail("a locked-out server lost its ordinary web tools too");
        second.closeStdinWait();
        owner.closeStdinWait();
    }

    // (c) The helper answers ev_view_create_failed: the ONLY negative
    // signal a context request has. Nothing may be left behind, and
    // nothing may have been loaded in the shared jar.
    {
        _ = c.setenv("SKETERM_FAKE_WEB_CONTEXT_FAIL", "1", 1);
        defer _ = c.unsetenv("SKETERM_FAKE_WEB_CONTEXT_FAIL");
        var m = Mcp.spawn(allocator, exe, &.{});
        m.initialize();
        m.sendTool("web_open", "{\"url\":\"https://smoke.invalid/p\",\"profile\":\"fails\"}");
        const failed = m.recvLine(60_000);
        if (std.mem.indexOf(u8, failed, "\"isError\":true") == null or
            std.mem.indexOf(u8, failed, "refused the identity context") == null)
            fail("a helper-refused context did not surface as an error");
        if (std.mem.indexOf(u8, failed, "NO page was loaded in the shared cookie jar") == null)
            fail("the context-refusal error does not say the shared jar was untouched");
        const tabs = m.callTool("web_tabs", "{}");
        if (std.mem.indexOf(u8, tabs, "\"count\":0") == null)
            fail("the view survived its context's refusal");
        m.closeStdinWait();
    }
}

/// CEF-free proof of the ENFORCED network-policy lane: the exact wire
/// order, the capability-less fail-closed refusal, and the exhausted
/// contract (traffic refused, reads loud). Same fake-helper setup as
/// `webProfileFakeStage`.
fn webPolicyFakeStage(allocator: std.mem.Allocator, exe: [*:0]const u8, rt: []const u8) void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var self_buf: [4096:0]u8 = undefined;
    const self_len = c.readlink("/proc/self/exe", &self_buf, self_buf.len - 1);
    if (self_len <= 0) fail("cannot resolve the smoke binary path");
    self_buf[@intCast(self_len)] = 0;
    _ = c.setenv("SKETERM_WEB_BIN", &self_buf, 1);
    defer _ = c.unsetenv("SKETERM_WEB_BIN");
    _ = c.setenv("SKETERM_FAKE_WEBENGINE", "1", 1);
    defer _ = c.unsetenv("SKETERM_FAKE_WEBENGINE");
    _ = c.setenv("SKETERM_WEB_SESSION", "0", 1);
    defer _ = c.unsetenv("SKETERM_WEB_SESSION");

    var file_buf: [64 * 1024]u8 = undefined;

    // (14) Fail closed: a helper without the capability refuses a
    // policied open and leaves ZERO views — an unpoliced fallback would
    // look like success here.
    {
        var m = Mcp.spawn(allocator, exe, &.{});
        m.initialize();
        m.sendTool("web_open", "{\"url\":\"https://smoke.invalid/p\",\"policy\":{\"allow_hosts\":[\"smoke.invalid\"]}}");
        const refused = m.recvLine(60_000);
        if (std.mem.indexOf(u8, refused, "\"isError\":true") == null or
            std.mem.indexOf(u8, refused, "\"code\":\"unavailable\"") == null or
            std.mem.indexOf(u8, refused, "net-policy capability") == null)
            fail("a helper without net-policy did not refuse a policied open");
        const tabs = m.callTool("web_tabs", "{}");
        if (std.mem.indexOf(u8, tabs, "\"count\":0") == null)
            fail("a refused policy still minted a view (the fail-closed regression)");
        // A malformed policy is a caller error, before any helper talk.
        const bad = m.callTool("web_open", "{\"url\":\"https://smoke.invalid/\",\"policy\":{\"allow_hosts\":[\"*\"]}}");
        if (std.mem.indexOf(u8, bad, "\"code\":\"invalid_args\"") == null)
            fail("web_open accepted a wildcard host entry");
        m.closeStdinWait();
    }

    _ = c.setenv("SKETERM_FAKE_WEB_POLICY", "1", 1);
    defer _ = c.unsetenv("SKETERM_FAKE_WEB_POLICY");
    var frames_buf: [512]u8 = undefined;
    const frames = std.fmt.bufPrintZ(&frames_buf, "{s}/fake-web-policy-frames.txt", .{rt}) catch unreachable;
    _ = c.unlink(frames.ptr);
    _ = c.setenv("SKETERM_FAKE_WEB_FRAMES", frames.ptr, 1);
    defer _ = c.unsetenv("SKETERM_FAKE_WEB_FRAMES");

    // (15) The capable fake acknowledges installation before the first view.
    {
        var m = Mcp.spawn(allocator, exe, &.{});
        m.initialize();
        m.sendTool("web_open", "{\"url\":\"https://smoke.invalid/p\",\"policy\":{\"allow_hosts\":[\"smoke.invalid\"],\"max_requests\":5}}");
        const opened = m.recvLine(60_000);
        if (std.mem.indexOf(u8, opened, "\"isError\":true") != null)
            fail("a policied web_open failed against the policy-capable fake");
        if (std.mem.indexOf(u8, opened, "\"policy_active\":true") == null or
            std.mem.indexOf(u8, opened, "\"policy_source\":\"call\"") == null or
            std.mem.indexOf(u8, opened, "\"max_requests\":5") == null)
            fail("web_open does not echo the enforced policy");
        const caps_reply = m.callTool("capabilities", "{}");
        const caps = capSc(arena, caps_reply, "capable policy preflight", false);
        if (caps.get("web_policy_ack").? != .bool or !caps.get("web_policy_ack").?.bool) {
            say(caps_reply);
            fail("policy-capable fake did not advertise correlated acknowledgements");
        }
        const log = readSmall(frames, &file_buf);
        const ps = std.mem.indexOf(u8, log, "net_policy_set view=1") orelse
            fail("no net_policy_set reached the helper");
        const vc = std.mem.indexOf(u8, log, "view_create_url view=1") orelse
            fail("no view_create_url reached the helper");
        if (ps > vc) fail("the view was created before its policy was installed");
        if (std.mem.indexOf(u8, log, "top=1 max_requests=5") == null)
            fail("the policy frame does not carry the declared limits");

        // web_policy freshens from the helper and reports the source.
        const pol = m.callTool("web_policy", "{}");
        if (std.mem.indexOf(u8, pol, "\"policy_active\":true") == null or
            std.mem.indexOf(u8, pol, "\"policy_source\":\"call\"") == null or
            std.mem.indexOf(u8, pol, "\"durable\":false") == null)
            fail("web_policy does not report the live policy");
        m.closeStdinWait();
    }

    // Older helpers can install policies, but cannot acknowledge live updates.
    {
        _ = c.setenv("SKETERM_FAKE_WEB_POLICY_LEGACY", "1", 1);
        defer _ = c.unsetenv("SKETERM_FAKE_WEB_POLICY_LEGACY");
        var m = Mcp.spawn(allocator, exe, &.{});
        m.initialize();
        m.sendTool("web_open", "{\"url\":\"https://smoke.invalid/p\",\"policy\":{\"allow_hosts\":[\"smoke.invalid\"],\"max_requests\":9}}");
        _ = capSc(arena, m.recvLine(60_000), "legacy policy open", false);
        const caps = capSc(arena, m.callTool("capabilities", "{}"), "legacy policy preflight", false);
        if (caps.get("web_policy_ack").? != .bool or caps.get("web_policy_ack").?.bool)
            fail("legacy policy fake incorrectly advertised correlated acknowledgements");
        const reply = m.callTool("web_policy_set", "{\"policy\":{\"max_requests\":3}}");
        const refusal = capSc(arena, reply, "legacy live policy update", true).get("error").?.object;
        if (!std.mem.eql(u8, refusal.get("code").?.string, "unavailable") or
            std.mem.indexOf(u8, refusal.get("message").?.string, "net-policy-ack") == null)
        {
            say(reply);
            fail("legacy live policy update did not report its missing ACK capability");
        }
        const after_reply = m.callTool("web_policy", "{}");
        const after = capSc(arena, after_reply, "legacy policy after refused update", false);
        if (capInt(after.get("policy").?.object, "max_requests") != 9) {
            say(after_reply);
            fail("legacy live policy refusal changed the installed budget");
        }
        m.closeStdinWait();
    }

    // (16) Exhaustion: traffic tools are REFUSED with the budget named,
    // read tools still answer carrying the exhausted facts.
    {
        _ = c.setenv("SKETERM_FAKE_WEB_POLICY_EXHAUST", "1", 1);
        defer _ = c.unsetenv("SKETERM_FAKE_WEB_POLICY_EXHAUST");
        var m = Mcp.spawn(allocator, exe, &.{});
        m.initialize();
        m.sendTool("web_open", "{\"url\":\"https://smoke.invalid/p\",\"policy\":{\"allow_hosts\":[\"smoke.invalid\"],\"max_requests\":5}}");
        if (std.mem.indexOf(u8, m.recvLine(60_000), "\"isError\":true") != null)
            fail("the exhaust fixture could not open its view");
        const nav = m.callTool("web_navigate", "{\"url\":\"https://smoke.invalid/next\"}");
        if (std.mem.indexOf(u8, nav, "\"code\":\"refused\"") == null or
            std.mem.indexOf(u8, nav, "request_cap") == null)
            fail("an exhausted view still navigates");
        const shot = m.callTool("web_snapshot", "{}");
        if (std.mem.indexOf(u8, shot, "\"isError\":true") != null)
            fail("an exhausted view refused a READ tool");
        if (std.mem.indexOf(u8, shot, "\"policy_exhausted\":true") == null or
            std.mem.indexOf(u8, shot, "\"policy_exhausted_reason\":\"request_cap\"") == null)
            fail("a read on an exhausted view does not carry the exhausted facts");
        const pol = m.callTool("web_policy", "{}");
        if (std.mem.indexOf(u8, pol, "\"exhausted\":true") == null or
            std.mem.indexOf(u8, pol, "\"exhausted_reason\":\"request_cap\"") == null)
            fail("web_policy does not report the latched budget");
        m.closeStdinWait();
    }

    // A profile SESSION DEFAULT applies to its own web_open only, and
    // web_policy_set refuses a pure loosening on a live view.
    {
        _ = c.setenv("SKETERM_FAKE_WEB_CONTEXTS", "1", 1);
        defer _ = c.unsetenv("SKETERM_FAKE_WEB_CONTEXTS");
        var m = Mcp.spawn(allocator, exe, &.{});
        m.initialize();
        const set = m.callTool("web_policy_set", "{\"profile\":\"work\",\"policy\":{\"allow_hosts\":[\"smoke.invalid\"],\"max_requests\":9}}");
        if (std.mem.indexOf(u8, set, "\"policy_source\":\"profile_default\"") == null or
            std.mem.indexOf(u8, set, "\"durable\":false") == null)
            fail("web_policy_set did not register the profile default");
        m.sendTool("web_open", "{\"url\":\"https://smoke.invalid/p\",\"profile\":\"work\"}");
        const opened = m.recvLine(60_000);
        if (std.mem.indexOf(u8, opened, "\"policy_source\":\"profile_default\"") == null or
            std.mem.indexOf(u8, opened, "\"max_requests\":9") == null)
            fail("the profile default did not ride its web_open");
        const loosen = m.callTool("web_policy_set", "{\"policy\":{\"max_requests\":5000}}");
        const refusal = capSc(arena, loosen, "pure policy loosening", true).get("error").?.object;
        if (!std.mem.eql(u8, refusal.get("code").?.string, "refused") or
            std.mem.indexOf(u8, refusal.get("message").?.string, "LOOSEN") == null or
            std.mem.indexOf(u8, refusal.get("message").?.string, "max_requests") == null)
        {
            say(loosen);
            fail("web_policy_set applied (or silently ignored) a pure loosening");
        }
        const after_reply = m.callTool("web_policy", "{}");
        const after = capSc(arena, after_reply, "live policy after refused loosening", false);
        if (capInt(after.get("policy").?.object, "max_requests") != 9) {
            say(after_reply);
            fail("refused pure loosening still changed the live policy budget");
        }
        const tighten = m.callTool("web_policy_set", "{\"policy\":{\"max_requests\":3}}");
        if (std.mem.indexOf(u8, tighten, "\"tightened\":[\"max_requests\"]") == null)
            fail("web_policy_set did not tighten the live view's budget");
        // The update was acknowledged; its wire log must show the tighter limit.
        var tries: u32 = 0;
        while (tries < 100) : (tries += 1) {
            if (std.mem.indexOf(u8, readSmall(frames, &file_buf), "max_requests=3") != null) break;
            _ = c.usleep(20_000);
        }
        if (tries >= 100)
            fail("the tightened policy never reached the helper");
        m.closeStdinWait();
    }

    // web_policy_set is a PATCH: a live view allowing ws/wss and private
    // addresses keeps both when only max_requests is tightened — the
    // response names just the budget, and the re-sent wire policy still
    // carries the wider scheme mask and the private flag. Explicitly
    // saying the fields then tightens them; asking for them back is
    // refused by name.
    {
        var m = Mcp.spawn(allocator, exe, &.{});
        m.initialize();
        const ws_mask: u16 = netpolicy.default_schemes | netpolicy.schemeBit("ws").? | netpolicy.schemeBit("wss").?;
        m.sendTool("web_open", "{\"url\":\"https://smoke.invalid/p\",\"policy\":{\"allow_hosts\":[\"smoke.invalid\"],\"allow_schemes\":[\"http\",\"https\",\"ws\",\"wss\"],\"allow_private_addresses\":true,\"max_requests\":50}}");
        const opened = m.recvLine(60_000);
        if (std.mem.indexOf(u8, opened, "\"policy_source\":\"call\"") == null)
            fail("the wide policied open did not report its policy");
        const partial = m.callTool("web_policy_set", "{\"policy\":{\"max_requests\":4}}");
        if (std.mem.indexOf(u8, partial, "\"tightened\":[\"max_requests\"]") == null)
            fail("a budget-only web_policy_set did not tighten exactly the budget");
        if (std.mem.indexOf(u8, partial, "\"ws\"") == null or std.mem.indexOf(u8, partial, "\"wss\"") == null or
            std.mem.indexOf(u8, partial, "\"allow_private_addresses\":true") == null)
            fail("a budget-only web_policy_set reset schemes or allow_private_addresses (the partial-update regression)");
        var want_buf: [96]u8 = undefined;
        const want = std.fmt.bufPrint(&want_buf, "max_requests=4 schemes={d} private=1", .{ws_mask}) catch unreachable;
        var tries: u32 = 0;
        while (tries < 100) : (tries += 1) {
            if (std.mem.indexOf(u8, readSmall(frames, &file_buf), want) != null) break;
            _ = c.usleep(20_000);
        }
        if (tries >= 100)
            fail("the re-sent policy on the wire lost the untouched schemes/private fields");
        const explicit = m.callTool("web_policy_set", "{\"policy\":{\"allow_schemes\":[\"https\"],\"allow_private_addresses\":false}}");
        if (std.mem.indexOf(u8, explicit, "allow_schemes") == null or
            std.mem.indexOf(u8, explicit, "allow_private_addresses") == null or
            std.mem.indexOf(u8, explicit, "\"ws\"") != null or
            std.mem.indexOf(u8, explicit, "\"allow_private_addresses\":false") == null)
            fail("explicit scheme/private fields did not tighten");
        const widen = m.callTool("web_policy_set", "{\"policy\":{\"allow_schemes\":[\"https\",\"ws\"],\"allow_private_addresses\":true,\"allow_hosts\":[\"smoke.invalid\",\"other.invalid\"],\"max_requests\":400}}");
        if (std.mem.indexOf(u8, widen, "\"code\":\"refused\"") == null or
            std.mem.indexOf(u8, widen, "allow_schemes") == null or
            std.mem.indexOf(u8, widen, "allow_private_addresses") == null or
            std.mem.indexOf(u8, widen, "allow_hosts") == null or
            std.mem.indexOf(u8, widen, "max_requests") == null)
            fail("a widening web_policy_set was not refused naming every field");
        m.closeStdinWait();
    }
}

/// Run only the optional browser stage for focused E2E validation.
fn webOnly(allocator: std.mem.Allocator, exe: [*:0]const u8, rt: [:0]const u8) u8 {
    var bin_buf: [4096:0]u8 = undefined;
    const web_bin = resolveWebBin(&bin_buf) orelse
        fail("sketerm-webengine not built for --web-only");
    _ = c.setenv("XDG_RUNTIME_DIR", rt.ptr, 1);
    _ = c.setenv("XDG_STATE_HOME", rt.ptr, 1);
    _ = c.setenv("HOME", rt.ptr, 1);
    clearInheritedOrigin();
    _ = c.setenv("SKETERM_MUX_BIN", "zig-out/bin/sketerm-mux", 1);
    _ = c.setenv("SKETERM_WEB_BIN", web_bin, 1);
    g_rt = rt;
    webStartupStage(allocator, exe);
    webStage(allocator, exe, rt);
    say("smoke-mcp: focused headless web tools ok");
    webPolicyStage(allocator, exe, rt);
    say("smoke-mcp: focused enforced network policy ok");
    webCaptureStage(allocator, exe, rt);
    say("smoke-mcp: focused response-body capture ok");
    webTabsStage(allocator, exe, rt);
    say("smoke-mcp: focused shared-browser tab targeting ok");
    killDaemonsUnderRt(rt, allocator);
    _ = c.usleep(500_000);
    g_rt = null;
    pathz.removeTree(rt);
    return 0;
}

// -- ssh tools over a fake ssh ---------------------------------------

/// Env that turns this binary, run as `ssh` or `scp`, into a local
/// stand-in for a remote host.
const FAKE_SSH_ENV = "SKETERM_SMOKE_FAKE_SSH";

/// The fake host whose remote commands see `$SKETERM_SMOKE_NORSYNC_BIN`
/// (a failing `rsync`) first on PATH.
const NORSYNC_HOST = "fakehost-norsync";
const NORSYNC_BIN_ENV = "SKETERM_SMOKE_NORSYNC_BIN";

/// Options of ssh/scp that take a value (the rest are flags).
fn sshOptTakesValue(opt: []const u8) bool {
    if (opt.len != 2) return false;
    return std.mem.indexOfScalar(u8, "oLRDipFJlSWcbeEmOQw", opt[1]) != null;
}

/// A stand-in `ssh`: `-L lp_spec` with `-N` serves the forward locally;
/// otherwise the remote command runs here under /bin/sh.
fn fakeSsh(args: []const [*:0]const u8) u8 {
    var forward: ?[]const u8 = null;
    var no_cmd = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = std.mem.span(args[i]);
        if (a.len == 0 or a[0] != '-') break;
        if (std.mem.eql(u8, a, "-N")) no_cmd = true;
        if (sshOptTakesValue(a)) {
            if (i + 1 >= args.len) return 255;
            if (std.mem.eql(u8, a, "-L")) forward = std.mem.span(args[i + 1]);
            i += 1;
        }
    }
    if (i >= args.len) return 255; // no host
    const host_name = std.mem.span(args[i]);
    i += 1; // the host: this machine stands in for it
    if (no_cmd) {
        const spec = forward orelse return 255;
        return fakeForward(spec);
    }
    var line: std.ArrayList(u8) = .empty;
    for (args[i..], 0..) |a, k| {
        if (k > 0) line.append(std.heap.c_allocator, ' ') catch return 255;
        line.appendSlice(std.heap.c_allocator, std.mem.span(a)) catch return 255;
    }
    line.append(std.heap.c_allocator, 0) catch return 255;
    const argv = [_:null]?[*:0]const u8{ "sh", "-c", @ptrCast(line.items.ptr) };
    // The remote command runs in a child, so a dropped "connection"
    // (SIGTERM to this ssh) ends it the way a real one does: the remote
    // side goes, and ssh exits 255.
    const child = c.fork();
    if (child < 0) return 255;
    if (child == 0) {
        // `fakehost-norsync` is a host whose rsync does not work, which is
        // how file_sync's tar mode is reached through the real probe.
        if (std.mem.eql(u8, host_name, NORSYNC_HOST)) if (c.getenv(NORSYNC_BIN_ENV)) |nb| {
            var pbuf: [8192]u8 = undefined;
            const old_path: [*:0]const u8 = if (c.getenv("PATH")) |p| p else "/usr/bin:/bin";
            const np = std.fmt.bufPrintZ(&pbuf, "{s}:{s}", .{ std.mem.span(@as([*:0]const u8, @ptrCast(nb))), std.mem.span(old_path) }) catch c._exit(127);
            _ = c.setenv("PATH", np.ptr, 1);
        };
        _ = c.execv("/bin/sh", @ptrCast(&argv));
        c._exit(127);
    }
    // No SA_RESTART: waitpid must return EINTR when the drop arrives.
    const act = std.posix.Sigaction{
        .handler = .{ .handler = &fakeSshDropped },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
    var status: c_int = 0;
    while (c.waitpid(child, &status, 0) < 0) {
        if (fake_ssh_dropped) {
            _ = c.kill(child, c.SIGKILL);
            _ = c.waitpid(child, null, 0);
            return 255;
        }
    }
    if (fake_ssh_dropped) return 255;
    if ((status & 0x7f) == 0) return @intCast((status >> 8) & 0xff);
    return 255;
}

var fake_ssh_dropped: bool = false;

fn fakeSshDropped(_: @TypeOf(std.posix.SIG.TERM)) callconv(.c) void {
    fake_ssh_dropped = true;
}

/// `[bind:]lport:host:rport`: listen on 127.0.0.1:lport and relay each
/// connection to 127.0.0.1:rport until killed.
fn fakeForward(spec: []const u8) u8 {
    var parts: [4][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, spec, ':');
    while (it.next()) |p| {
        if (n == parts.len) return 255;
        parts[n] = p;
        n += 1;
    }
    if (n < 3) return 255;
    const lport = std.fmt.parseInt(u16, parts[n - 3], 10) catch return 255;
    const rport = std.fmt.parseInt(u16, parts[n - 1], 10) catch return 255;
    const lfd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
    if (lfd < 0) return 255;
    var one: c_int = 1;
    _ = c.setsockopt(lfd, c.SOL_SOCKET, c.SO_REUSEADDR, &one, @sizeOf(c_int));
    var addr = loopbackAddr(lport);
    if (c.bind(lfd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_in)) != 0) return 255;
    if (c.listen(lfd, 8) != 0) return 255;
    while (true) {
        const cfd = c.accept(lfd, null, null);
        if (cfd < 0) continue;
        const pid = c.fork();
        if (pid == 0) {
            _ = c.close(lfd);
            relay(cfd, rport);
            c._exit(0);
        }
        _ = c.close(cfd);
    }
}

fn loopbackAddr(port: u16) c.struct_sockaddr_in {
    var addr = std.mem.zeroes(c.struct_sockaddr_in);
    addr.sin_family = c.AF_INET;
    addr.sin_port = std.mem.nativeToBig(u16, port);
    addr.sin_addr.s_addr = std.mem.nativeToBig(u32, 0x7f000001);
    return addr;
}

/// Copy bytes both ways between `cfd` and a fresh connection to
/// 127.0.0.1:`rport` until either side closes.
fn relay(cfd: c_int, rport: u16) void {
    const rfd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
    if (rfd < 0) return;
    var addr = loopbackAddr(rport);
    if (c.connect(rfd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_in)) != 0) return;
    var fds = [2]c.struct_pollfd{
        .{ .fd = cfd, .events = c.POLLIN, .revents = 0 },
        .{ .fd = rfd, .events = c.POLLIN, .revents = 0 },
    };
    var buf: [16384]u8 = undefined;
    while (c.poll(&fds, 2, -1) > 0) {
        for (0..2) |k| {
            if (fds[k].revents == 0) continue;
            const n = c.read(fds[k].fd, &buf, buf.len);
            if (n <= 0) return;
            const out = fds[1 - k].fd;
            var off: usize = 0;
            while (off < @as(usize, @intCast(n))) {
                const w = c.write(out, buf[off..].ptr, @as(usize, @intCast(n)) - off);
                if (w <= 0) return;
                off += @intCast(w);
            }
        }
    }
}

/// A stand-in `scp`: `host:path` names a path on this machine.
fn fakeScp(args: []const [*:0]const u8) u8 {
    var paths: [2][]const u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = std.mem.span(args[i]);
        if (a.len > 0 and a[0] == '-') {
            if (sshOptTakesValue(a)) i += 1;
            continue;
        }
        if (n == paths.len) return 1;
        paths[n] = if (a.len > 0 and a[0] != '/' and std.mem.indexOfScalar(u8, a, ':') != null)
            a[std.mem.indexOfScalar(u8, a, ':').? + 1 ..]
        else
            a;
        n += 1;
    }
    if (n != 2) return 1;
    var src_z: [4096]u8 = undefined;
    var dst_z: [4096]u8 = undefined;
    const src = std.fmt.bufPrintZ(&src_z, "{s}", .{paths[0]}) catch return 1;
    const dst = std.fmt.bufPrintZ(&dst_z, "{s}", .{paths[1]}) catch return 1;
    const in = c.open(src.ptr, c.O_RDONLY);
    if (in < 0) return 1;
    defer _ = c.close(in);
    const out = c.open(dst.ptr, c.O_WRONLY | c.O_CREAT | c.O_TRUNC, @as(c_uint, 0o644));
    if (out < 0) return 1;
    defer _ = c.close(out);
    var buf: [65536]u8 = undefined;
    while (true) {
        const r = c.read(in, &buf, buf.len);
        if (r < 0) return 1;
        if (r == 0) return 0;
        if (c.write(out, &buf, @intCast(r)) != r) return 1;
    }
}

/// A one-connection TCP service on 127.0.0.1: answers every
/// connection with a banner the relayed side must read back.
const Banner = struct {
    fd: c_int,
    port: u16,

    fn start() Banner {
        const fd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
        if (fd < 0) fail("banner socket");
        var addr = loopbackAddr(0);
        if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_in)) != 0) fail("banner bind");
        if (c.listen(fd, 8) != 0) fail("banner listen");
        var len: c.socklen_t = @sizeOf(c.struct_sockaddr_in);
        if (c.getsockname(fd, @ptrCast(&addr), &len) != 0) fail("banner getsockname");
        return .{ .fd = fd, .port = std.mem.bigToNative(u16, addr.sin_port) };
    }

    fn serve(fd: c_int) void {
        while (true) {
            const cfd = c.accept(fd, null, null);
            if (cfd < 0) return;
            _ = c.write(cfd, "SK-FWD-OK\n", 10);
            _ = c.close(cfd);
        }
    }
};

/// Read what 127.0.0.1:`port` sends first (bounded).
fn readBanner(port: u16, out: []u8) []const u8 {
    const fd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
    if (fd < 0) return "";
    defer _ = c.close(fd);
    var addr = loopbackAddr(port);
    if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_in)) != 0) return "";
    var pfd = c.struct_pollfd{ .fd = fd, .events = c.POLLIN, .revents = 0 };
    var got: usize = 0;
    while (got < out.len and c.poll(&pfd, 1, 5_000) > 0) {
        const n = c.read(fd, out[got..].ptr, out.len - got);
        if (n <= 0) break;
        got += @intCast(n);
        if (std.mem.indexOfScalar(u8, out[0..got], '\n') != null) break;
    }
    return out[0..got];
}

/// scp_get / scp_put with a host, and the port_forward_* lifecycle,
/// through the real tool paths (a daemon terminal running `ssh`/`scp`),
/// with THIS binary standing in for both on PATH.
fn sshToolsStage(allocator: std.mem.Allocator, exe: [*:0]const u8, rt: [:0]const u8) void {
    var self_buf: [4096]u8 = undefined;
    const self_n = c.readlink("/proc/self/exe", &self_buf, self_buf.len - 1);
    if (self_n <= 0) fail("readlink /proc/self/exe");
    self_buf[@intCast(self_n)] = 0;
    var bin_buf: [512]u8 = undefined;
    const bin = std.fmt.bufPrintZ(&bin_buf, "{s}/fakebin", .{rt}) catch fail("fakebin path");
    _ = c.mkdir(bin.ptr, 0o700);
    for ([_][]const u8{ "ssh", "scp" }) |name| {
        var link_buf: [600]u8 = undefined;
        const link = std.fmt.bufPrintZ(&link_buf, "{s}/{s}", .{ bin, name }) catch fail("fakebin link");
        _ = c.unlink(link.ptr);
        if (c.symlink(@ptrCast(&self_buf), link.ptr) != 0) fail("could not link the fake ssh/scp");
    }
    const old_path: []const u8 = if (c.getenv("PATH")) |p| std.mem.span(@as([*:0]const u8, @ptrCast(p))) else "/usr/bin:/bin";
    var saved_path_buf: [4096]u8 = undefined;
    const saved_path = std.fmt.bufPrintZ(&saved_path_buf, "{s}", .{old_path}) catch fail("PATH too long");
    var path_buf: [4700]u8 = undefined;
    const new_path = std.fmt.bufPrintZ(&path_buf, "{s}:{s}", .{ bin, old_path }) catch fail("PATH too long");
    _ = c.setenv("PATH", new_path.ptr, 1);
    _ = c.setenv(FAKE_SSH_ENV, "1", 1);
    defer {
        _ = c.setenv("PATH", saved_path.ptr, 1);
        _ = c.setenv(FAKE_SSH_ENV, "1", 1);
    }

    const banner = Banner.start();
    const th = std.Thread.spawn(.{}, Banner.serve, .{banner.fd}) catch fail("banner thread");
    th.detach();

    var m = Mcp.spawn(allocator, exe, &.{});
    m.initialize();
    defer m.closeStdinWait();

    // scp_get: remote file -> staged partial -> sha256 verified -> moved.
    var src_buf: [512]u8 = undefined;
    const src = std.fmt.bufPrintZ(&src_buf, "{s}/remote-src.txt", .{rt}) catch fail("src path");
    {
        const f = c.fopen(src.ptr, "w") orelse fail("could not write the remote-side file");
        _ = c.fputs("SCP-GET-PAYLOAD\n", f);
        _ = c.fclose(f);
    }
    var jb: [1400]u8 = undefined;
    const got = m.callTool("scp_get", std.fmt.bufPrint(&jb, "{{\"host\":\"fakehost\",\"remote_path\":\"{s}\",\"local_path\":\"{s}/got.txt\"}}", .{ src, rt }) catch unreachable);
    if (std.mem.indexOf(u8, got, "\"verified\":true") == null or std.mem.indexOf(u8, got, "isError") != null) {
        std.debug.print("smoke-mcp: scp_get reply: {s}\n", .{got});
        fail("scp_get over ssh did not verify and move the download");
    }
    const read_back = m.callTool("file_read", std.fmt.bufPrint(&jb, "{{\"path\":\"{s}/got.txt\"}}", .{rt}) catch unreachable);
    if (std.mem.indexOf(u8, read_back, "SCP-GET-PAYLOAD") == null) fail("scp_get wrote the wrong bytes");

    // scp_put: the upload is verified on the "remote" and moved there.
    const put = m.callTool("scp_put", std.fmt.bufPrint(&jb, "{{\"host\":\"fakehost\",\"local_path\":\"{s}/got.txt\",\"remote_path\":\"{s}/put.txt\"}}", .{ rt, rt }) catch unreachable);
    if (std.mem.indexOf(u8, put, "\"verified\":true") == null or std.mem.indexOf(u8, put, "isError") != null) {
        std.debug.print("smoke-mcp: scp_put reply: {s}\n", .{put});
        fail("scp_put over ssh did not verify and move the upload");
    }

    // port_forward_open: readiness is a TCP connect; a connection through
    // the forward must reach the service behind it.
    const opened = m.callTool("port_forward_open", std.fmt.bufPrint(&jb, "{{\"host\":\"fakehost\",\"remote_port\":{d}}}", .{banner.port}) catch unreachable);
    if (std.mem.indexOf(u8, opened, "isError") != null) {
        std.debug.print("smoke-mcp: port_forward_open reply: {s}\n", .{opened});
        fail("port_forward_open failed over the fake ssh");
    }
    const lp_at = std.mem.indexOf(u8, opened, "\"local_port\":") orelse fail("port_forward_open reported no local_port");
    var end = lp_at + "\"local_port\":".len;
    while (end < opened.len and std.ascii.isDigit(opened[end])) end += 1;
    const lport = std.fmt.parseInt(u16, opened[lp_at + "\"local_port\":".len .. end], 10) catch fail("bad local_port");
    var banner_buf: [64]u8 = undefined;
    if (std.mem.indexOf(u8, readBanner(lport, &banner_buf), "SK-FWD-OK") == null)
        fail("a connection through the forward did not reach the service behind it");
    const listed = m.callTool("port_forward_list", "{}");
    if (std.mem.indexOf(u8, listed, "\"alive\":true") == null) fail("port_forward_list did not show the live forward");
    const checked = m.callTool("port_forward_check", "{\"forward\":1}");
    if (std.mem.indexOf(u8, checked, "\"listening\":true") == null) fail("port_forward_check did not see the forward listening");
    const closed = m.callTool("port_forward_close", "{\"forward\":1}");
    if (std.mem.indexOf(u8, closed, "\"closed\":true") == null) fail("port_forward_close did not close the forward");
}

/// The app_* tools against a REAL windowed app on the private daemon's
/// headless display: `sketerm view` on a generated image (no GUI, no
/// --shared). Launch waits for the first window; the reads, inputs and
/// waits then run on that live toplevel, and close_app retires it.
fn appToolsStage(allocator: std.mem.Allocator, exe: [*:0]const u8, rt: [:0]const u8) void {
    var png_buf: [512]u8 = undefined;
    const png = std.fmt.bufPrintZ(&png_buf, "{s}/app-fixture.png", .{rt}) catch fail("fixture path");
    if (!writeSolidPngFile(png, 0x20, 0xc0, 0x40)) fail("could not write the app fixture image");

    var m = Mcp.spawn(allocator, exe, &.{});
    m.initialize();
    defer m.closeStdinWait();
    var jb: [2048]u8 = undefined;
    const launch = std.fmt.bufPrint(
        &jb,
        "{{\"command\":[\"{s}\",\"view\",\"{s}\"],\"env\":{{\"SKETERM_APP_ID\":\"dev.sker.sketerm.smokemcp\",\"GTK_A11Y\":\"none\"}},\"wait_for\":\"window\",\"wait_ms\":30000,\"stable_ms\":0}}",
        .{ std.mem.span(exe), png },
    ) catch fail("launch args");
    const opened = m.callTool("launch_app", launch);
    if (std.mem.indexOf(u8, opened, "isError") != null) {
        std.debug.print("smoke-mcp: launch_app reply: {s}\n", .{opened[0..@min(opened.len, 600)]});
        fail("launch_app of a real windowed app failed");
    }
    if (std.mem.indexOf(u8, opened, "\"type\":\"image\"") == null)
        fail("launch_app wait_for:window did not reply with the window's screenshot");

    const state = m.callTool("get_app_state", "{\"app\":1}");
    if (std.mem.indexOf(u8, state, "isError") != null or std.mem.indexOf(u8, state, "\"exited\":false") == null)
        fail("get_app_state did not report the live app");
    const shot = m.callTool("screenshot_app", "{\"app\":1}");
    if (std.mem.indexOf(u8, shot, "\"type\":\"image\"") == null or std.mem.indexOf(u8, shot, "\"image_w\":") == null)
        fail("screenshot_app returned no image with its size");
    const win_at = std.mem.indexOf(u8, shot, "\"window\":") orelse fail("screenshot_app named no window");
    var win_end = win_at + "\"window\":".len;
    while (win_end < shot.len and std.ascii.isDigit(shot[win_end])) win_end += 1;
    const win = std.fmt.parseInt(u32, shot[win_at + "\"window\":".len .. win_end], 10) catch fail("bad window id");
    const probe = m.callTool("screenshot_app", "{\"app\":1,\"stats_only\":true}");
    if (std.mem.indexOf(u8, probe, "isError") != null) fail("screenshot_app stats_only failed");
    var ib: [256]u8 = undefined;
    const clicked = m.callTool("app_click", std.fmt.bufPrint(&ib, "{{\"app\":1,\"window\":{d},\"x\":40,\"y\":40,\"mark\":false,\"settle_ms\":0}}", .{win}) catch unreachable);
    if (std.mem.indexOf(u8, clicked, "isError") != null) {
        std.debug.print("smoke-mcp: app_click reply: {s}\n", .{clicked[0..@min(clicked.len, 600)]});
        fail("app_click on the live window failed");
    }
    const moved = m.callTool("app_mouse_move", std.fmt.bufPrint(&ib, "{{\"app\":1,\"window\":{d},\"x\":60,\"y\":60}}", .{win}) catch unreachable);
    if (std.mem.indexOf(u8, moved, "isError") != null) {
        std.debug.print("smoke-mcp: app_mouse_move reply: {s}\n", .{moved[0..@min(moved.len, 600)]});
        fail("app_mouse_move failed");
    }
    const keyed = m.callTool("app_key", std.fmt.bufPrint(&ib, "{{\"app\":1,\"window\":{d},\"keys\":\"right\"}}", .{win}) catch unreachable);
    if (std.mem.indexOf(u8, keyed, "isError") != null) {
        std.debug.print("smoke-mcp: app_key reply: {s}\n", .{keyed[0..@min(keyed.len, 600)]});
        fail("app_key failed");
    }
    const waited = m.callTool("app_wait", "{\"app\":1,\"quiet_ms\":300,\"timeout_ms\":10000}");
    if (std.mem.indexOf(u8, waited, "isError") != null) fail("app_wait on the live window failed");
    const logged = m.callTool("app_log", "{\"app\":1}");
    if (std.mem.indexOf(u8, logged, "isError") != null) fail("app_log failed");
    const listed = m.callTool("list_apps", "{}");
    if (std.mem.indexOf(u8, listed, "\"app\":1") == null) fail("list_apps did not list the running app");
    const closed = m.callTool("close_app", "{\"app\":1}");
    if (std.mem.indexOf(u8, closed, "isError") != null) {
        std.debug.print("smoke-mcp: close_app reply: {s}\n", .{closed[0..@min(closed.len, 600)]});
        fail("close_app did not retire the app");
    }
}

/// A 64x64 opaque PNG of one colour.
fn writeSolidPngFile(path: [:0]const u8, r: u8, g: u8, b: u8) bool {
    var px: [64 * 64 * 4]u8 = undefined;
    var i: usize = 0;
    while (i < px.len) : (i += 4) {
        px[i] = r;
        px[i + 1] = g;
        px[i + 2] = b;
        px[i + 3] = 0xff;
    }
    const png = @import("util/png.zig").encodeRgba(std.heap.c_allocator, &px, 64, 64) catch return false;
    defer std.heap.c_allocator.free(png);
    const f = c.fopen(path.ptr, "wb") orelse return false;
    defer _ = c.fclose(f);
    return c.fwrite(png.ptr, 1, png.len, f) == png.len;
}

// ── sub-agents: fake Claude Code and opencode, and the agent_* tools ──

/// Env under which THIS binary, run with an agent app's argv, is that app.
const FAKE_AGENT_ENV = "SKETERM_SMOKE_FAKE_AGENT";
/// What the fake agents print for `--version`.
const FAKE_AGENT_VERSION = "sk-fake-agent 0.0.0 (smoke)";

fn writeOut(bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(1, bytes[off..].ptr, bytes.len - off);
        if (n <= 0) {
            if (n < 0 and std.posix.errno(n) == .INTR) continue;
            return;
        }
        off += @intCast(n);
    }
}

/// Claude Code's ax-mode live region (status block, mode line, input).
const FC_LIVE = "[Haiku 4.5] repo:smoke\r\n[\xe2\x96\xa0\xe2\x96\xa1] 21%\r\nmanual mode on\r\n$";
/// Erase the live region (4 rows) before drawing above it.
const FC_ERASE = "\x1b[2K\x1b[1A\x1b[2K\x1b[1A\x1b[2K\x1b[1A\x1b[2K\x1b[G";
const FC_BUSY = "\x1b]0;\xe2\x97\x90 Working\x07";
const FC_IDLE = "\x1b]0;\xe2\x9c\xb3 Claude Code\x07";
/// A turn end: OSC 133 C + D + BEL together, the idle glyph, the footer.
const FC_END = "\x1b]133;C\x07\x1b]133;D\x07\x07" ++ FC_IDLE ++ FC_ERASE ++ "Brewed for 1s \xc2\xb7 done\r\n" ++ FC_LIVE;
const FC_PERMISSION = FC_ERASE ++ "tool: Bash (rm notes.md)\r\nPermission Required: Bash command\r\n> rm notes.md\r\n" ++
    "Do you want to proceed?\r\n1. Yes\r\n2. No\r\nSelect with numbers [1-2]. Then Enter to submit or Escape to cancel:\x07";

/// `history`: the late part of a resumed conversation's reprint, dropped
/// once a prompt is typed (the real one reprints before its first turn).
/// `side`: a step of the `/btw` panel, which fires while the panel holds
/// back the turn's own steps; `side_erase` is the panel's erase count once
/// it fired (`FcSide.erase`).
const FcStep = struct { at_ms: i64, bytes: []u8, picker: bool = false, history: bool = false, side: bool = false, side_erase: ?usize = null };

/// The `/btw` panel the fake shows, as Claude Code 2.1.288 draws it in ax
/// mode (measured): below a running turn, above its live block (busy); or
/// after a `you: /btw` echo, in place of the live block (idle).
const FcSide = struct {
    /// Rows to erase from the cursor to take the panel away, the live block
    /// included while it shows (busy, or before an idle panel opened).
    erase: usize,
};

const FC_SIDE_FOOTER_BUSY = "\xe2\x86\x91/\xe2\x86\x93 to scroll \xc2\xb7 c to copy \xc2\xb7 f to fork \xc2\xb7 Esc to close";
const FC_SIDE_FOOTER_IDLE_PENDING = "\xe2\x87\xa7\xe2\x86\x90/\xe2\x86\x92 to browse \xc2\xb7 x to clear history \xc2\xb7 Esc to close";
const FC_SIDE_FOOTER_IDLE = "\xe2\x87\xa7\xe2\x86\x90/\xe2\x86\x92 to browse \xc2\xb7 c to copy \xc2\xb7 f to fork \xc2\xb7 x to clear history \xc2\xb7 Esc to close";

/// `n` rows erased upward from the cursor's, the cursor left at the top one.
fn fcEraseRows(a: std.mem.Allocator, n: usize) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (1..n) |_| out.appendSlice(a, "\x1b[2K\x1b[1A") catch return "";
    out.appendSlice(a, "\x1b[2K\x1b[G") catch return "";
    return out.items;
}

/// Open the `/btw` panel for `text` (the typed line): pending first, its
/// answer a moment later. A busy panel answers about the running turn, an
/// idle one in two paragraphs and lists the earlier questions above it.
fn fcSideOpen(allocator: std.mem.Allocator, steps: *std.ArrayList(FcStep), history: []const []const u8, text: []const u8, busy: bool) FcSide {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const asked = text["/btw ".len..];
    if (busy) {
        writeOut(std.fmt.allocPrint(a, FC_ERASE ++ "{s}\r\nAnswering\xe2\x80\xa6\r\nEsc to close\r\n" ++ FC_LIVE, .{text}) catch return .{ .erase = 4 });
        const answer = std.fmt.allocPrint(a, "{s}{s}\r\nside answer to: {s}\r\nwhile working on the current turn\r\n" ++ FC_SIDE_FOOTER_BUSY ++ "\r\n" ++ FC_LIVE, .{ fcEraseRows(a, 7), text, asked }) catch return .{ .erase = 7 };
        fcScheduleSide(allocator, steps, 400, answer, 8);
        return .{ .erase = 7 };
    }
    writeOut(std.fmt.allocPrint(a, FC_ERASE ++ "you: {s}\r\nPerambulating\xe2\x80\xa6\r\n" ++ FC_LIVE, .{text}) catch return .{ .erase = 6 });
    var open: std.ArrayList(u8) = .empty;
    open.appendSlice(a, fcEraseRows(a, 5)) catch return .{ .erase = 6 };
    for (history) |h| open.print(a, "{s}\r\n", .{h}) catch return .{ .erase = 6 };
    open.print(a, "{s}\r\nAnswering\xe2\x80\xa6\r\n" ++ FC_SIDE_FOOTER_IDLE_PENDING, .{text}) catch return .{ .erase = 6 };
    fcScheduleSide(allocator, steps, 100, open.items, history.len + 4);
    const answer = std.fmt.allocPrint(a, "\x1b[2K\x1b[1A\x1b[2K\x1b[Gside answer to: {s}\r\n\r\nnothing is running\r\n" ++ FC_SIDE_FOOTER_IDLE, .{asked}) catch return .{ .erase = 6 };
    fcScheduleSide(allocator, steps, 600, answer, history.len + 6);
    return .{ .erase = 6 };
}

fn fcScheduleSide(allocator: std.mem.Allocator, steps: *std.ArrayList(FcStep), delay_ms: i64, bytes: []const u8, erase: usize) void {
    const owned = allocator.dupe(u8, bytes) catch return;
    steps.append(allocator, .{ .at_ms = nowMs() + delay_ms, .bytes = owned, .side = true, .side_erase = erase }) catch allocator.free(owned);
}

/// Where the fake Claude Code keeps what a real one keeps in ~/.claude:
/// one transcript per conversation id, every launch's argv, and a marker
/// for anything that would have saved the user's defaults.
const FC_DIR = ".fake-claude";
const FC_LAUNCHES = "launches";
const FC_SETTINGS_WRITTEN = "settings-written";

/// `$HOME/.fake-claude/<name>`.
fn fcPath(buf: []u8, name: []const u8) [:0]const u8 {
    const home = if (c.getenv("HOME")) |h| std.mem.span(@as([*:0]const u8, @ptrCast(h))) else "/tmp";
    return std.fmt.bufPrintZ(buf, "{s}/" ++ FC_DIR ++ "/{s}", .{ home, name }) catch "/tmp/.fake-claude-overflow";
}

fn fcAppend(name: []const u8, line: []const u8) void {
    var buf: [1024]u8 = undefined;
    const path = fcPath(&buf, name);
    var dir_buf: [1024]u8 = undefined;
    const dir = fcPath(&dir_buf, "");
    _ = c.mkdir(dir.ptr, 0o700);
    const f = c.fopen(path.ptr, "a") orelse return;
    defer _ = c.fclose(f);
    _ = c.fwrite(line.ptr, 1, line.len, f);
    _ = c.fputc('\n', f);
}

/// Every start of a fake app, one line each: the app's tag, its argv
/// after argv[0] and `env=` with SMOKE_EXTRA_ENV's value, NUL-separated
/// (agent_open refuses control characters, so none occurs inside).
const FC_STARTS = "starts";
/// A CLAUDE* name: agent_open's `env` must survive Claude Code's unset_env.
const SMOKE_EXTRA_ENV = "CLAUDE_SMOKE_EXTRA";

fn fcRecordStart(tag: []const u8, args: []const [*:0]const u8) void {
    const a = std.heap.c_allocator;
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(a);
    line.appendSlice(a, tag) catch return;
    for (args) |x| {
        line.append(a, 0) catch return;
        line.appendSlice(a, std.mem.span(x)) catch return;
    }
    line.appendSlice(a, "\x00env=") catch return;
    line.appendSlice(a, if (c.getenv(SMOKE_EXTRA_ENV)) |v| std.mem.span(@as([*:0]const u8, @ptrCast(v))) else "<unset>") catch return;
    fcAppend(FC_STARTS, line.items);
}

/// The conversation file of the session id this launch names.
/// Set in an agent_open's `env`: the fake runs the status line command of
/// its `--settings` (it never does otherwise, so the developer's own
/// command is never run by the smoke).
const FC_STATUS_ENV = "SKETERM_SMOKE_FC_STATUS";
/// What that command printed, one entry per run.
const FC_STATUS_OUT = "status-out";

/// Run the `statusLine.command` of `--settings` with a status document on
/// stdin, as Claude Code 2.1.288 does in ax mode at startup (before any
/// prompt: usage null, no rate limits) and after each turn (`after`).
fn fcStatus(allocator: std.mem.Allocator, args: []const [*:0]const u8, after: bool) void {
    if (c.getenv(FC_STATUS_ENV) == null) return;
    const settings = argAfter(args, "--settings") orelse return;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const doc = std.json.parseFromSliceLeaky(std.json.Value, a, settings, .{}) catch return;
    const sl = (if (doc == .object) doc.object.get("statusLine") else null) orelse return;
    const cmd = (if (sl == .object) sl.object.get("command") else null) orelse return;
    if (cmd != .string) return;
    var in_buf: [1024]u8 = undefined;
    const in_name = std.fmt.bufPrint(&in_buf, "status-in-{d}.json", .{c.getpid()}) catch return;
    var path_buf: [1024]u8 = undefined;
    const in_path = fcPath(&path_buf, in_name);
    {
        const f = c.fopen(in_path.ptr, "w") orelse return;
        const json = if (after) facts.CLAUDE_SAMPLE else facts.CLAUDE_SAMPLE_FRESH;
        _ = c.fwrite(json.ptr, 1, json.len, f);
        _ = c.fclose(f);
    }
    defer _ = c.unlink(in_path.ptr);
    const line = std.fmt.allocPrintSentinel(a, "( {s} ) < '{s}'", .{ cmd.string, in_path }, 0) catch return;
    const p = c.popen(line.ptr, "r") orelse return;
    var out: std.ArrayList(u8) = .empty;
    var buf: [1024]u8 = undefined;
    while (true) {
        const n = c.fread(&buf, 1, buf.len, p);
        if (n == 0) break;
        out.appendSlice(a, buf[0..n]) catch break;
    }
    _ = c.pclose(p);
    fcAppend(FC_STATUS_OUT, out.items);
}

fn fcConversation(buf: []u8, id: []const u8) [:0]const u8 {
    var nbuf: [200]u8 = undefined;
    const name = std.fmt.bufPrint(&nbuf, "conv-{s}", .{id}) catch "conv-x";
    return fcPath(buf, name);
}

/// A fake Claude Code in ax mode, enough for the adapter: typed input in
/// a `$` box, `you:`/`claude:`/`tool:` lines, busy/idle title glyphs,
/// OSC 133 turn marks with BEL, a numbered permission prompt that waits
/// for its answer, a subagent wait, a message flood, the `/model` picker
/// (applied a moment after `s`, as the real one does), `/exit`,
/// conversations kept per `--session-id` that `--resume` reprints, and
/// `go deaf`, after which it swallows all input as a wedged one did. It
/// refuses to start with a CLAUDE* variable a nested Claude Code must not
/// inherit, and marks anything that would save the user's defaults
/// (`/effort`, a picker's Enter).
fn fakeClaude(allocator: std.mem.Allocator, args: []const [*:0]const u8) u8 {
    for ([_][*:0]const u8{ "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CONFIG_DIR" }) |k| {
        if (c.getenv(k) != null) {
            writeOut("fake claude: ENV LEAK ");
            writeOut(std.mem.span(k));
            writeOut("\r\n");
            _ = c.usleep(2_000_000);
            return 3;
        }
    }
    {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(allocator);
        for (args, 0..) |a, i| {
            if (i > 0) line.append(allocator, ' ') catch {};
            line.appendSlice(allocator, std.mem.span(a)) catch {};
        }
        fcAppend(FC_LAUNCHES, line.items);
    }
    const resumed = argAfter(args, "--resume");
    const conv_id = resumed orelse argAfter(args, "--session-id") orelse "none";
    var conv_buf: [1024]u8 = undefined;
    const conv_path = fcConversation(&conv_buf, conv_id);
    var tio: c.struct_termios = undefined;
    if (c.tcgetattr(0, &tio) == 0) {
        c.cfmakeraw(&tio);
        _ = c.tcsetattr(0, c.TCSANOW, &tio);
    }
    _ = c.usleep(300_000);
    var steps: std.ArrayList(FcStep) = .empty;
    if (resumed) |id| {
        const past = readfile.cappedAlloc(allocator, conv_path, 1 << 20) catch {
            writeOut("No conversation found with session ID: ");
            writeOut(id);
            writeOut("\r\n");
            _ = c.usleep(500_000);
            return 1;
        };
        defer allocator.free(past);
        writeOut(FC_IDLE ++ "Claude Code v0.0.0 (smoke fake, resumed)\r\n");
        // Each past turn reprinted with its footer, as the real one does;
        // the last one only a while after the input box shows, which is how
        // a long reprint reaches a reader that already saw the app ready.
        var turns: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, past, "\n"), '\n');
        while (it.next()) |l| turns.append(allocator, l) catch return 1;
        const split = if (turns.items.len >= 4) turns.items.len - 2 else turns.items.len;
        for (turns.items[0..split]) |l| {
            writeOut(l);
            writeOut("\r\n");
            if (std.mem.startsWith(u8, l, "claude: ")) writeOut("Baked for 1s \xc2\xb7 done\r\n");
        }
        writeOut(FC_LIVE);
        if (split < turns.items.len) {
            var late: std.ArrayList(u8) = .empty;
            late.appendSlice(allocator, FC_ERASE) catch return 1;
            for (turns.items[split..]) |l| {
                late.appendSlice(allocator, l) catch return 1;
                late.appendSlice(allocator, "\r\n") catch return 1;
                if (std.mem.startsWith(u8, l, "claude: ")) late.appendSlice(allocator, "Baked for 1s \xc2\xb7 done\r\n") catch return 1;
            }
            late.appendSlice(allocator, FC_LIVE) catch return 1;
            steps.append(allocator, .{ .at_ms = nowMs() + 2500, .bytes = late.toOwnedSlice(allocator) catch return 1, .history = true }) catch return 1;
        }
        turns.deinit(allocator);
    } else writeOut(FC_IDLE ++ "Claude Code v0.0.0 (smoke fake)\r\n" ++ FC_LIVE);
    fcStatus(allocator, args, false);

    var input: std.ArrayList(u8) = .empty;
    var picker = false;
    var choice: u8 = 0;
    var model_picker = false;
    var model_choice: u8 = 0;
    // `go deaf` answered: every later byte is swallowed, nothing is drawn.
    var deaf = false;
    // The `/btw` panel while it shows (it has the keyboard), and the
    // questions asked so far (an idle panel lists them).
    var side: ?FcSide = null;
    var btw_history: std.ArrayList([]const u8) = .empty;
    while (true) {
        const now = nowMs();
        var i: usize = 0;
        while (i < steps.items.len) {
            // The turn goes on behind the panel and draws once it closed.
            const held = side != null and !steps.items[i].side and !steps.items[i].history;
            if (steps.items[i].at_ms > now or held) {
                i += 1;
                continue;
            }
            const s = steps.orderedRemove(i);
            writeOut(s.bytes);
            if (s.side_erase) |n| if (side) |*sd| {
                sd.erase = n;
            };
            if (s.picker) picker = true;
            if (std.mem.indexOf(u8, s.bytes, "\x1b]133;D") != null) fcStatus(allocator, args, true);
            allocator.free(s.bytes);
        }
        var pfd = c.struct_pollfd{ .fd = 0, .events = c.POLLIN, .revents = 0 };
        if (c.poll(&pfd, 1, 20) <= 0) continue;
        var buf: [1024]u8 = undefined;
        const n = c.read(0, &buf, buf.len);
        if (n == 0) return 0;
        if (n < 0) continue;
        for (buf[0..@intCast(n)]) |b| {
            if (deaf) continue;
            if (side) |sd| {
                // Only Escape reaches the panel's owner; it closes the panel
                // and nothing else (the real one's c/f/x are not modelled).
                if (b != 0x1b) continue;
                var k: usize = 0;
                while (k < steps.items.len) {
                    if (!steps.items[k].side) {
                        k += 1;
                        continue;
                    }
                    allocator.free(steps.orderedRemove(k).bytes);
                }
                var eb: [64 * 16]u8 = undefined;
                var fba = std.heap.FixedBufferAllocator.init(&eb);
                writeOut(fcEraseRows(fba.allocator(), sd.erase));
                writeOut(FC_LIVE);
                side = null;
                continue;
            }
            if (model_picker) {
                const label = if (model_choice == 1) "Sonnet 4.5" else "Haiku 4.5";
                switch (b) {
                    '1'...'9' => model_choice = b - '0',
                    's' => {
                        model_picker = false;
                        const done = std.fmt.allocPrint(allocator, "\r\x1b[4A\x1b[JSet model to {s} for this session only\r\n" ++ FC_LIVE ++ "\x1b]133;C\x07\x1b]133;D\x07\x07", .{label}) catch return 1;
                        defer allocator.free(done);
                        // Applied a moment later, like the real one.
                        fcSchedule(allocator, &steps, 600, done, false);
                    },
                    '\r' => {
                        model_picker = false;
                        fcAppend(FC_SETTINGS_WRITTEN, "model picker Enter");
                        writeOut("\r\x1b[4A\x1b[JSet model to default (saved as your default for new sessions)\r\n" ++ FC_LIVE);
                    },
                    0x1b => {
                        model_picker = false;
                        writeOut("\r\x1b[4A\x1b[J" ++ FC_LIVE);
                    },
                    else => {},
                }
                continue;
            }
            if (picker) {
                if (b >= '1' and b <= '9') choice = b - '0';
                if (b != '\r') continue;
                picker = false;
                const label = switch (choice) {
                    1 => "Yes",
                    2 => "No",
                    else => "nothing",
                };
                const answer = std.fmt.allocPrint(allocator, "\r\x1b[5A\x1b[Jclaude: permission answered {s}\r\n" ++ FC_LIVE, .{label}) catch return 1;
                writeOut(answer);
                allocator.free(answer);
                fcSchedule(allocator, &steps, 200, FC_END, false);
                continue;
            }
            switch (b) {
                '\r' => {
                    if (input.items.len == 0) continue;
                    var k: usize = 0;
                    while (k < steps.items.len) {
                        if (!steps.items[k].history) {
                            k += 1;
                            continue;
                        }
                        allocator.free(steps.orderedRemove(k).bytes);
                    }
                    const text = input.items;
                    if (std.mem.startsWith(u8, text, "/btw ")) {
                        var turn_running = false;
                        for (steps.items) |st| turn_running = turn_running or (!st.history and !st.side);
                        side = fcSideOpen(allocator, &steps, if (turn_running) &.{} else btw_history.items, text, turn_running);
                        btw_history.append(allocator, allocator.dupe(u8, text) catch "") catch {};
                    } else if (std.mem.eql(u8, text, "/model")) {
                        model_picker = true;
                        writeOut("\x1b]133;A\x07" ++ FC_ERASE ++ "you: /model\r\nSelect model\r\n1. Sonnet 4.5\r\n2. Haiku 4.5 (selected)\r\n" ++
                            "Select with numbers [1-2]. Then Enter to submit or Escape to cancel:\r\nEnter to set as default \xc2\xb7 s to use this session only \xc2\xb7 Esc to cancel");
                    } else if (std.mem.eql(u8, text, "/exit")) {
                        writeOut(FC_ERASE ++ "you: /exit\r\nGoodbye!\r\n");
                        return 0;
                    } else if (std.mem.startsWith(u8, text, "/effort")) {
                        fcAppend(FC_SETTINGS_WRITTEN, text);
                        const saved = std.fmt.allocPrint(allocator, FC_ERASE ++ "you: {s}\r\nSet effort level to {s} (saved as your default for new sessions)\r\n" ++ FC_LIVE, .{ text, std.mem.trim(u8, text["/effort".len..], " ") }) catch return 1;
                        writeOut(saved);
                        allocator.free(saved);
                    } else if (std.mem.eql(u8, text, "go deaf")) {
                        fcTurn(allocator, &steps, text, conv_path);
                        deaf = true;
                    } else fcTurn(allocator, &steps, text, conv_path);
                    input.clearRetainingCapacity();
                },
                0x1b => {
                    input.clearRetainingCapacity();
                    // Escape during a turn interrupts it, as the real one does:
                    // what was still to come is dropped and the turn ends.
                    var turn_running = false;
                    for (steps.items) |st| turn_running = turn_running or !st.history;
                    if (turn_running) {
                        for (steps.items) |st| allocator.free(st.bytes);
                        steps.clearRetainingCapacity();
                        writeOut(FC_ERASE ++ "Interrupted \xc2\xb7 What should Claude do instead?\r\n" ++ FC_LIVE ++ FC_END);
                    } else writeOut("\r\x1b[2K$");
                },
                0x7f => {
                    _ = input.pop();
                    fcInput(input.items);
                },
                else => if (b >= 0x20) {
                    input.append(allocator, b) catch return 1;
                    fcInput(input.items);
                },
            }
        }
    }
}

/// The smoke brief template's marker, which no result may echo.
const BRIEF_MARK = "RULES-BLOCK-7 ";

/// A rendered smoke brief without its marker, so a fake agent's answer
/// proves the substitution without echoing the prompt.
fn briefTail(text: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, text, BRIEF_MARK) orelse return null;
    return text[at + BRIEF_MARK.len ..];
}

/// Redraw the input box on its one row: a long prompt (a rendered template)
/// shows its tail, as a real one-row box scrolls, instead of wrapping rows
/// of stale copies onto the screen.
fn fcInput(text: []const u8) void {
    writeOut("\r\x1b[2K$ ");
    writeOut(text[text.len -| 100..]);
}

fn fcSchedule(allocator: std.mem.Allocator, steps: *std.ArrayList(FcStep), delay_ms: i64, bytes: []const u8, picker: bool) void {
    const owned = allocator.dupe(u8, bytes) catch return;
    steps.append(allocator, .{ .at_ms = nowMs() + delay_ms, .bytes = owned, .picker = picker }) catch allocator.free(owned);
}

/// One turn of the fake: the prompt's words pick the script. Plain turns
/// are kept in the conversation file (`recall` answers with its first
/// prompt, which is how a resumed conversation proves it is the same one).
fn fcTurn(allocator: std.mem.Allocator, steps: *std.ArrayList(FcStep), text: []const u8, conv_path: [:0]const u8) void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const start = std.fmt.allocPrint(a, "\x1b]133;A\x07" ++ FC_BUSY ++ FC_ERASE ++ "you: {s}\r\n" ++ FC_LIVE, .{text}) catch return;
    writeOut(start);
    const has = struct {
        fn f(hay: []const u8, needle: []const u8) bool {
            return std.mem.indexOf(u8, hay, needle) != null;
        }
    }.f;
    if (has(text, "permission")) {
        fcSchedule(allocator, steps, 300, FC_PERMISSION, true);
    } else if (has(text, "two parts")) {
        // A turn end while a background agent still runs, then the
        // continuation turn once it finished.
        fcSchedule(allocator, steps, 300, FC_ERASE ++ "claude: part one\r\n" ++ FC_LIVE ++ "\x1b]133;C\x07\x1b]133;D\x07\x07" ++
            FC_ERASE ++ "Waiting for 1 background agent to finish\r\n" ++ FC_LIVE, false);
        fcSchedule(allocator, steps, 3500, FC_BUSY ++ "\x1b]133;A\x07" ++ FC_ERASE ++ " Agent \"helper\" finished \xc2\xb7 3s\r\nclaude: part two\r\n" ++ FC_LIVE ++ FC_END, false);
    } else if (std.mem.startsWith(u8, text, "flood ")) {
        const count = std.fmt.parseInt(u32, text["flood ".len..], 10) catch 3;
        var body: std.ArrayList(u8) = .empty;
        body.appendSlice(a, FC_ERASE) catch return;
        var k: u32 = 1;
        while (k <= count) : (k += 1) body.print(a, "claude: flood message {d}\r\ntool: Step {d}\r\n", .{ k, k }) catch return;
        body.appendSlice(a, FC_LIVE) catch return;
        fcSchedule(allocator, steps, 300, body.items, false);
        fcSchedule(allocator, steps, 400, FC_END, false);
    } else {
        const reply: []const u8 = if (std.mem.eql(u8, text, "recall")) blk: {
            const past = readfile.cappedAlloc(a, conv_path, 1 << 20) catch break :blk "first prompt was: (none)";
            var lines = std.mem.splitScalar(u8, past, '\n');
            while (lines.next()) |l| {
                if (std.mem.startsWith(u8, l, "you: ")) break :blk std.fmt.allocPrint(a, "first prompt was: {s}", .{l["you: ".len..]}) catch return;
            }
            break :blk "first prompt was: (none)";
        } else if (briefTail(text)) |tail|
            std.fmt.allocPrint(a, "brief: {s}", .{tail}) catch return
        else
            std.fmt.allocPrint(a, "echo: {s}", .{text}) catch return;
        {
            const f = c.fopen(conv_path.ptr, "a");
            if (f) |file| {
                defer _ = c.fclose(file);
                const rec = std.fmt.allocPrint(a, "you: {s}\nclaude: {s}\n", .{ text, reply }) catch return;
                _ = c.fwrite(rec.ptr, 1, rec.len, file);
            }
        }
        const delay: i64 = if (has(text, "glacial")) 12_000 else if (has(text, "slow")) 1500 else 300;
        const answer = std.fmt.allocPrint(a, FC_ERASE ++ "claude: {s}\r\n" ++ FC_LIVE, .{reply}) catch return;
        fcSchedule(allocator, steps, delay, answer, false);
        fcSchedule(allocator, steps, delay + 100, FC_END, false);
    }
}

/// opencode's API for one session, served by the agent tests' scripted
/// server with a hook for what fixed routes cannot answer: a prompt's
/// turn (echoing the model and variant it was sent with), a permission
/// and its reply, and a turn with two messages.
const FakeOc = struct {
    allocator: std.mem.Allocator,
    lock: SpinLock = .init,
    turn: u32 = 0,
    /// Turns still to end on a provider overload (`overload N` sets it).
    overload_left: u32 = 0,
    due: [256]Due = undefined,
    n_due: usize = 0,

    const SES = "ses_fake1";
    const Due = struct { at_ms: i64, json: []u8 };

    /// Queue `json` (owned) for the event stream in `delay_ms`.
    fn later(self: *FakeOc, delay_ms: i64, json: []u8) void {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.n_due == self.due.len) return;
        self.due[self.n_due] = .{ .at_ms = nowMs() + delay_ms, .json = json };
        self.n_due += 1;
    }

    fn flush(self: *FakeOc, srv: *testserver.Server) void {
        var ready: [256][]u8 = undefined;
        var n: usize = 0;
        self.lock.lock();
        const now = nowMs();
        var i: usize = 0;
        while (i < self.n_due) {
            if (self.due[i].at_ms > now) {
                i += 1;
                continue;
            }
            ready[n] = self.due[i].json;
            n += 1;
            std.mem.copyForwards(Due, self.due[i .. self.n_due - 1], self.due[i + 1 .. self.n_due]);
            self.n_due -= 1;
        }
        self.lock.unlock();
        for (ready[0..n]) |json| {
            srv.pushEvent(json);
            self.allocator.free(json);
        }
    }

    fn ev(self: *FakeOc, delay_ms: i64, comptime fmt: []const u8, args: anytype) void {
        const json = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        self.later(delay_ms, json);
    }

    fn status(self: *FakeOc, delay_ms: i64, kind: []const u8) void {
        self.ev(delay_ms, "{{\"type\":\"session.status\",\"properties\":{{\"sessionID\":\"" ++ SES ++ "\",\"status\":{{\"type\":\"{s}\"}}}}}}", .{kind});
    }

    /// A completed assistant message `id` with one text part.
    fn answer(self: *FakeOc, delay_ms: i64, id: []const u8, text: []const u8) void {
        self.ev(delay_ms, "{{\"type\":\"message.updated\",\"properties\":{{\"sessionID\":\"" ++ SES ++ "\",\"info\":{{\"id\":\"{s}\",\"role\":\"assistant\",\"sessionID\":\"" ++ SES ++ "\"}}}}}}", .{id});
        self.ev(delay_ms, "{{\"type\":\"message.part.updated\",\"properties\":{{\"sessionID\":\"" ++ SES ++ "\",\"part\":{{\"type\":\"text\",\"text\":{f},\"messageID\":\"{s}\",\"sessionID\":\"" ++ SES ++ "\",\"id\":\"prt_{s}\",\"time\":{{\"start\":1,\"end\":2}}}}}}}}", .{ std.json.fmt(text, .{}), id, id });
        self.ev(delay_ms, "{{\"type\":\"message.updated\",\"properties\":{{\"sessionID\":\"" ++ SES ++ "\",\"info\":{{\"id\":\"{s}\",\"role\":\"assistant\",\"sessionID\":\"" ++ SES ++ "\",\"providerID\":\"fakeprov\",\"modelID\":\"m1\"," ++
            "\"tokens\":{{\"input\":1000,\"output\":200,\"reasoning\":0,\"cache\":{{\"read\":8800,\"write\":0}}}},\"time\":{{\"created\":1,\"completed\":2}}}}}}}}", .{id});
    }

    fn hook(ctx: ?*anyopaque, _: *testserver.Server, method: []const u8, path: []const u8, body: []const u8) ?testserver.Reply {
        const self: *FakeOc = @ptrCast(@alignCast(ctx.?));
        if (!std.mem.eql(u8, method, "POST")) return null;
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        if (std.mem.eql(u8, path, "/session/" ++ SES ++ "/prompt_async")) {
            const Prompt = struct {
                parts: []const struct { text: []const u8 = "" } = &.{},
                model: ?struct { providerID: []const u8, modelID: []const u8 } = null,
                variant: ?[]const u8 = null,
            };
            const p = std.json.parseFromSliceLeaky(Prompt, a, body, .{ .ignore_unknown_fields = true }) catch return .{ .status = 400 };
            const text = if (p.parts.len > 0) p.parts[0].text else "";
            self.lock.lock();
            self.turn += 1;
            const n = self.turn;
            if (std.mem.startsWith(u8, text, "overload ")) self.overload_left = std.fmt.parseInt(u32, text["overload ".len..], 10) catch 1;
            const overloaded = self.overload_left > 0;
            if (overloaded) self.overload_left -= 1;
            self.lock.unlock();
            const model = if (p.model) |m| std.fmt.allocPrint(a, "{s}/{s}", .{ m.providerID, m.modelID }) catch "?" else "default";
            self.ev(0, "{{\"type\":\"message.updated\",\"properties\":{{\"sessionID\":\"" ++ SES ++ "\",\"info\":{{\"id\":\"msg_u{d}\",\"role\":\"user\",\"sessionID\":\"" ++ SES ++ "\"}}}}}}", .{n});
            self.ev(0, "{{\"type\":\"message.part.updated\",\"properties\":{{\"sessionID\":\"" ++ SES ++ "\",\"part\":{{\"type\":\"text\",\"text\":{f},\"messageID\":\"msg_u{d}\",\"sessionID\":\"" ++ SES ++ "\",\"id\":\"prt_u{d}\"}}}}}}", .{ std.json.fmt(text, .{}), n, n });
            self.status(0, "busy");
            const id1 = std.fmt.allocPrint(a, "msg_a{d}_1", .{n}) catch return .{ .status = 500 };
            if (overloaded) {
                // The provider gave up on the turn: opencode's APIError.
                self.ev(200, "{{\"type\":\"message.updated\",\"properties\":{{\"sessionID\":\"" ++ SES ++ "\",\"info\":{{\"id\":\"{s}\",\"role\":\"assistant\",\"sessionID\":\"" ++ SES ++ "\",\"time\":{{\"created\":1,\"completed\":2}},\"error\":{{\"name\":\"APIError\",\"data\":{{\"message\":\"Service Unavailable\",\"statusCode\":503}}}}}}}}}}", .{id1});
                self.status(300, "idle");
            } else if (std.mem.indexOf(u8, text, "two questions") != null) {
                self.ev(200, "{{\"type\":\"question.asked\",\"properties\":{{\"id\":\"que_{d}\",\"sessionID\":\"" ++ SES ++ "\",\"questions\":[" ++
                    "{{\"question\":\"Which file?\",\"header\":\"File\",\"options\":[{{\"label\":\"a.zig\"}},{{\"label\":\"b.zig\"}}]}}," ++
                    "{{\"question\":\"Which checks?\",\"header\":\"Checks\",\"multiple\":true,\"custom\":false,\"options\":[{{\"label\":\"lint\"}},{{\"label\":\"test\"}}]}}]}}}}", .{n});
            } else if (std.mem.indexOf(u8, text, "permission") != null) {
                self.ev(200, "{{\"type\":\"permission.asked\",\"properties\":{{\"id\":\"per_{d}\",\"sessionID\":\"" ++ SES ++ "\",\"permission\":\"bash\",\"patterns\":[\"rm notes.md\"]}}}}", .{n});
            } else if (briefTail(text)) |tail| {
                const reply = std.fmt.allocPrint(a, "brief: {s}", .{tail}) catch return .{ .status = 500 };
                self.answer(200, id1, reply);
                self.status(300, "idle");
            } else if (std.mem.indexOf(u8, text, "two messages") != null) {
                self.answer(200, id1, "alpha one");
                const id2 = std.fmt.allocPrint(a, "msg_a{d}_2", .{n}) catch return .{ .status = 500 };
                self.answer(1500, id2, "beta two");
                self.status(1600, "idle");
            } else {
                const reply = std.fmt.allocPrint(a, "echo: {s} model={s} variant={s}", .{ text, model, p.variant orelse "default" }) catch return .{ .status = 500 };
                self.answer(200, id1, reply);
                self.status(300, "idle");
            }
            return .{ .status = 204 };
        }
        if (std.mem.startsWith(u8, path, "/permission/") and std.mem.endsWith(u8, path, "/reply")) {
            const id = path["/permission/".len .. path.len - "/reply".len];
            const Reply = struct { reply: []const u8 = "" };
            const r = std.json.parseFromSliceLeaky(Reply, a, body, .{ .ignore_unknown_fields = true }) catch return .{ .status = 400 };
            self.ev(0, "{{\"type\":\"permission.replied\",\"properties\":{{\"sessionID\":\"" ++ SES ++ "\",\"requestID\":{f},\"reply\":{f}}}}}", .{ std.json.fmt(id, .{}), std.json.fmt(r.reply, .{}) });
            const msg_id = std.fmt.allocPrint(a, "msg_{s}", .{id}) catch return .{ .status = 500 };
            const text = std.fmt.allocPrint(a, "permission {s}", .{r.reply}) catch return .{ .status = 500 };
            self.answer(100, msg_id, text);
            self.status(200, "idle");
            return .{ .body = "true" };
        }
        if (std.mem.startsWith(u8, path, "/question/") and std.mem.endsWith(u8, path, "/reply")) {
            const id = path["/question/".len .. path.len - "/reply".len];
            const Reply = struct { answers: []const []const []const u8 = &.{} };
            const r = std.json.parseFromSliceLeaky(Reply, a, body, .{ .ignore_unknown_fields = true }) catch return .{ .status = 400 };
            self.ev(0, "{{\"type\":\"question.replied\",\"properties\":{{\"sessionID\":\"" ++ SES ++ "\",\"requestID\":{f}}}}}", .{std.json.fmt(id, .{})});
            var text: std.ArrayList(u8) = .empty;
            text.appendSlice(a, "answers") catch return .{ .status = 500 };
            for (r.answers) |one| {
                text.appendSlice(a, " |") catch return .{ .status = 500 };
                for (one) |x| text.print(a, " {s}", .{x}) catch return .{ .status = 500 };
            }
            const msg_id = std.fmt.allocPrint(a, "msg_{s}", .{id}) catch return .{ .status = 500 };
            self.answer(100, msg_id, text.items);
            self.status(200, "idle");
            return .{ .body = "true" };
        }
        return null;
    }
};

/// Milliseconds a fake `opencode serve` stays deaf after it listens.
const FAKE_OC_DEAF_ENV = "SKETERM_SMOKE_OC_DEAF_MS";
/// Every password a fake server was started with, one per line.
const FAKE_OC_PASSWORDS = "oc-passwords";
/// The OPENCODE_CONFIG_CONTENT each fake server was started with, one per line.
const FAKE_OC_CONFIG = "oc-config";

const FAKE_OC_PROVIDERS =
    \\{"all":[{"id":"fakeprov","models":{"m1":{"name":"Fake One","limit":{"context":100000,"output":32000},"variants":{"low":{},"high":{}}}}}],"connected":["fakeprov"]}
;

fn argAfter(args: []const [*:0]const u8, flag: []const u8) ?[]const u8 {
    for (args, 0..) |a, i| {
        if (std.mem.eql(u8, std.mem.span(a), flag) and i + 1 < args.len) return std.mem.span(args[i + 1]);
    }
    return null;
}

/// The password reaches the app through its environment and nowhere
/// else: no argv element may carry it.
fn fakeAgentPassword(args: []const [*:0]const u8) ?[]const u8 {
    const raw = c.getenv("OPENCODE_SERVER_PASSWORD") orelse {
        writeOut("fake opencode: no OPENCODE_SERVER_PASSWORD in the environment\r\n");
        return null;
    };
    const pw = std.mem.span(@as([*:0]const u8, @ptrCast(raw)));
    for (args) |a| {
        if (std.mem.indexOf(u8, std.mem.span(a), pw) != null) {
            writeOut("fake opencode: the password is on the argv\r\n");
            return null;
        }
    }
    return pw;
}

/// `opencode serve --port P`: basic auth with the environment's password,
/// SSE events, and the routes the API source uses.
fn fakeOpencodeServe(allocator: std.mem.Allocator, args: []const [*:0]const u8) u8 {
    const pw = fakeAgentPassword(args) orelse {
        _ = c.usleep(2_000_000);
        return 3;
    };
    const port = std.fmt.parseInt(u16, argAfter(args, "--port") orelse "0", 10) catch 0;
    const pair = std.fmt.allocPrint(allocator, "opencode:{s}", .{pw}) catch return 1;
    const enc = std.base64.standard.Encoder;
    const b64 = allocator.alloc(u8, enc.calcSize(pair.len)) catch return 1;
    _ = enc.encode(b64, pair);
    const auth = std.fmt.allocPrint(allocator, "Basic {s}", .{b64}) catch return 1;
    // Where the stage reads the password back, to prove no process of the
    // run ever carried it on its argv (a test fake writes it; opencode
    // never would).
    {
        var dir_buf: [1024]u8 = undefined;
        const dir = fcPath(&dir_buf, "");
        _ = c.mkdir(dir.ptr, 0o700);
        fcAppend(FAKE_OC_PASSWORDS, pw);
        // The config document it was handed (agent_open permissions).
        fcAppend(FAKE_OC_CONFIG, if (c.getenv("OPENCODE_CONFIG_CONTENT")) |v| std.mem.span(@as([*:0]const u8, @ptrCast(v))) else "<unset>");
    }
    var oc = FakeOc{ .allocator = allocator };
    var srv: testserver.Server = .{};
    srv.auth = auth;
    // A starting opencode accepts connections seconds before it answers,
    // and never answers what it got in between.
    if (c.getenv(FAKE_OC_DEAF_ENV)) |ms| {
        const deaf = std.fmt.parseInt(i64, std.mem.span(@as([*:0]const u8, @ptrCast(ms))), 10) catch 0;
        srv.deaf_until_ms = nowMs() + deaf;
    }
    srv.route("GET /global/health", .{ .body = "{\"healthy\":true,\"version\":\"smoke\"}" });
    srv.hook = FakeOc.hook;
    srv.hook_ctx = &oc;
    srv.route("POST /session", .{ .body = "{\"id\":\"" ++ FakeOc.SES ++ "\"}" });
    srv.route("GET /session/" ++ FakeOc.SES, .{ .body = "{\"id\":\"" ++ FakeOc.SES ++ "\"}" });
    srv.route("GET /session/" ++ FakeOc.SES ++ "/message", .{ .body = "[]" });
    srv.route("GET /session/status", .{ .body = "{}" });
    srv.route("GET /permission", .{ .body = "[]" });
    srv.route("GET /question", .{ .body = "[]" });
    srv.route("GET /provider", .{ .body = FAKE_OC_PROVIDERS });
    srv.route("POST /session/" ++ FakeOc.SES ++ "/abort", .{ .body = "true" });
    srv.startOn(allocator, port) catch {
        writeOut("fake opencode: cannot listen\r\n");
        _ = c.usleep(2_000_000);
        return 5;
    };
    var line_buf: [96]u8 = undefined;
    writeOut(std.fmt.bufPrint(&line_buf, "fake opencode server listening on 127.0.0.1:{d}\r\n", .{port}) catch "listening\r\n");
    // Until the session is killed.
    while (true) {
        oc.flush(&srv);
        _ = c.usleep(10_000);
    }
}

/// `opencode attach URL --dir D -s SESSION`: the visible TUI a human
/// watches; the fake just names its session and waits.
fn fakeOpencodeAttach(args: []const [*:0]const u8) u8 {
    _ = fakeAgentPassword(args) orelse {
        _ = c.usleep(2_000_000);
        return 3;
    };
    writeOut("fake opencode attach: session ");
    writeOut(argAfter(args, "-s") orelse "?");
    writeOut("\r\n");
    var buf: [256]u8 = undefined;
    while (c.read(0, &buf, buf.len) > 0) {}
    return 0;
}

/// agent_ask against the fake Claude Code `claude-1` (idle when called):
/// answered from its panel, idle and behind a running turn, without a
/// record, a job, an event or a state change, the turn keeping its done.
fn sideQuestions(m: *Mcp, arena: std.mem.Allocator, caps: std.json.ObjectMap) void {
    const sq = (caps.get("agent_side_question") orelse fail("capabilities: no agent_side_question")).object;
    if (!sq.get("available").?.bool) fail("capabilities: agent_side_question is not available");
    var claude_side = false;
    for (sq.get("apps").?.array.items) |x| {
        if (std.mem.eql(u8, x.string, "opencode")) fail("capabilities: agent_side_question names opencode");
        claude_side = claude_side or std.mem.eql(u8, x.string, "claude");
    }
    if (!claude_side) fail("capabilities: agent_side_question does not name claude");
    const recordCount = struct {
        fn f(mm: *Mcp, ar: std.mem.Allocator) usize {
            return agentCall(mm, ar, "agent_read", "{\"agent\":\"claude-1\",\"since\":0,\"detail\":\"all\",\"limit\":500}", "agent_read all", false, 15_000).get("records").?.array.items.len;
        }
    }.f;
    const recs_before = recordCount(m, arena);

    // Idle: the echo looks like a prompt and is none; the answer keeps its
    // blank line; the panel is closed again.
    const idle = agentCall(m, arena, "agent_ask", "{\"agent\":\"claude-1\",\"text\":\"which command did you just run?\",\"timeout_ms\":20000}", "agent_ask idle", false, 45_000);
    expectFact(idle, "answer", "side answer to: which command did you just run?\n\nnothing is running", "agent_ask idle: answer");
    expectFact(idle, "state", "idle", "agent_ask idle: state");
    if (!idle.get("panel_closed").?.bool) fail("agent_ask idle: the panel was not closed");
    if (idle.get("watch_command") != null or idle.get("events") != null) fail("agent_ask: a side question handed out a watch_command or events");
    const quiet = agentCall(m, arena, "agent_wait", "{\"agent\":\"claude-1\",\"timeout_ms\":1500}", "agent_wait after agent_ask", false, 15_000);
    expectFact(quiet, "outcome", "still_working", "agent_wait after agent_ask: a side question raised a wake-up");
    if (quiet.get("events").?.array.items.len != 0) fail("agent_wait after agent_ask: a side question raised an event");
    if (recordCount(m, arena) != recs_before) fail("agent_ask idle: the side question left a record");

    // Busy: a long turn runs; the question does not interrupt it, the
    // agent stays working, and the turn ends with its own done.
    const glacial = agentCall(m, arena, "agent_send", "{\"agent\":\"claude-1\",\"text\":\"glacial side work\",\"timeout_ms\":0}", "agent_send glacial", false, 15_000);
    expectSentOrWorking(glacial, "agent_send glacial: outcome");
    const busy = agentCall(m, arena, "agent_ask", "{\"agent\":\"claude-1\",\"text\":\"what are you doing right now?\",\"timeout_ms\":20000}", "agent_ask busy", false, 45_000);
    expectFact(busy, "answer", "side answer to: what are you doing right now?\nwhile working on the current turn", "agent_ask busy: answer");
    expectFact(busy, "state", "working", "agent_ask busy: the agent did not stay working");
    if (!busy.get("panel_closed").?.bool) fail("agent_ask busy: the panel was not closed");
    const fin = agentCall(m, arena, "agent_wait", "{\"agent\":\"claude-1\",\"timeout_ms\":30000}", "agent_wait glacial", false, 45_000);
    expectFact(fin, "outcome", "done", "agent_wait glacial: the turn behind the side question did not finish");
    expectFact(fin, "message", "echo: glacial side work", "agent_wait glacial: final message");
    const all = agentCall(m, arena, "agent_read", "{\"agent\":\"claude-1\",\"since\":0,\"detail\":\"all\",\"limit\":500}", "agent_read after agent_ask", false, 15_000);
    for (all.get("records").?.array.items) |r| {
        const tx = r.object.get("text").?.string;
        if (std.mem.indexOf(u8, tx, "/btw") != null or std.mem.indexOf(u8, tx, "side answer") != null) {
            say(tx);
            fail("agent_read: a side question reached the transcript");
        }
    }
    // Refusals: several agents at once, a multi-line question.
    _ = agentCall(m, arena, "agent_ask", "{\"agents\":[\"claude-1\"],\"text\":\"how far?\"}", "agent_ask agents", true, 15_000);
    _ = agentCall(m, arena, "agent_ask", "{\"agent\":\"claude-1\",\"text\":\"one\\ntwo\"}", "agent_ask two lines", true, 15_000);
    say("smoke-mcp: agents: agent_ask side questions (idle, busy behind a turn that keeps its done, no record or event) ok");
}

/// One agent_* call: its structuredContent, the reply line kept in `arena`.
fn agentCall(m: *Mcp, arena: std.mem.Allocator, name: []const u8, args_json: []const u8, comptime what: []const u8, comptime want_error: bool, timeout_ms: i64) std.json.ObjectMap {
    m.sendToolAllocated(name, args_json);
    const line = arena.dupe(u8, m.recvLine(timeout_ms)) catch fail(what ++ ": oom");
    return capSc(arena, line, what, want_error);
}

/// `s` without the ` at HH:MM` a wake line puts after its kind.
fn untimed(arena: std.mem.Allocator, s: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (i + 9 <= s.len and std.mem.startsWith(u8, s[i..], " at ") and std.ascii.isDigit(s[i + 4]) and std.ascii.isDigit(s[i + 5]) and s[i + 6] == ':' and std.ascii.isDigit(s[i + 7]) and std.ascii.isDigit(s[i + 8])) {
            i += 9;
            continue;
        }
        out.append(arena, s[i]) catch fail("oom");
        i += 1;
    }
    return out.items;
}

fn scStr(o: std.json.ObjectMap, key: []const u8, comptime what: []const u8) []const u8 {
    const v = o.get(key) orelse fail(what ++ ": a fact is missing");
    if (v != .string) fail(what ++ ": a fact is not a string");
    return v.string;
}

fn expectFact(o: std.json.ObjectMap, key: []const u8, want: []const u8, comptime what: []const u8) void {
    const got = scStr(o, key, what);
    if (!std.mem.eql(u8, got, want)) {
        say(key);
        say(got);
        fail(what);
    }
}

/// A waiter started from a watch_command, its stdout on a pipe.
const Waiter = struct {
    pid: c.pid_t,
    fd: c_int,
    out: std.ArrayList(u8) = .empty,
    status: c_int = -1,

    fn start(cmd: []const u8) Waiter {
        var pipe: [2]c_int = undefined;
        if (c.pipe(&pipe) != 0) fail("waiter pipe");
        var cmd_buf: [8192]u8 = undefined;
        const cmd_z = std.fmt.bufPrintZ(&cmd_buf, "{s}", .{cmd}) catch fail("waiter command too long");
        const pid = c.fork();
        if (pid < 0) fail("waiter fork");
        if (pid == 0) {
            _ = c.dup2(pipe[1], 1);
            _ = c.close(pipe[0]);
            _ = c.close(pipe[1]);
            var argv: [4:null]?[*:0]const u8 = .{ "/bin/sh", "-c", cmd_z.ptr, null };
            _ = c.execv("/bin/sh", @ptrCast(&argv));
            c._exit(127);
        }
        _ = c.close(pipe[1]);
        return .{ .pid = pid, .fd = pipe[0] };
    }

    /// Whether it printed `needle` at least `count` times within `timeout_ms`.
    fn waitFor(self: *Waiter, allocator: std.mem.Allocator, needle: []const u8, count: usize, timeout_ms: i64) bool {
        const deadline = nowMs() + timeout_ms;
        while (std.mem.count(u8, self.out.items, needle) < count) {
            if (nowMs() > deadline) return false;
            var pfd = c.struct_pollfd{ .fd = self.fd, .events = c.POLLIN, .revents = 0 };
            if (c.poll(&pfd, 1, 100) <= 0) continue;
            var buf: [4096]u8 = undefined;
            const n = c.read(self.fd, &buf, buf.len);
            if (n <= 0) {
                _ = c.usleep(50_000);
                continue;
            }
            self.out.appendSlice(allocator, buf[0..@intCast(n)]) catch fail("oom");
        }
        return true;
    }

    /// End it (this pid only) whether or not it exited by itself.
    fn stop(self: *Waiter) void {
        _ = c.kill(self.pid, c.SIGKILL);
        _ = c.waitpid(self.pid, &self.status, 0);
        _ = c.close(self.fd);
    }

    /// Everything it printed until it exited, or fail at the deadline.
    fn finish(self: *Waiter, allocator: std.mem.Allocator, timeout_ms: i64, comptime what: []const u8) []const u8 {
        const deadline = nowMs() + timeout_ms;
        while (true) {
            var pfd = c.struct_pollfd{ .fd = self.fd, .events = c.POLLIN, .revents = 0 };
            if (c.poll(&pfd, 1, 100) > 0) {
                var buf: [4096]u8 = undefined;
                const n = c.read(self.fd, &buf, buf.len);
                if (n == 0) break;
                if (n > 0) self.out.appendSlice(allocator, buf[0..@intCast(n)]) catch fail("oom");
            }
            if (nowMs() > deadline) {
                _ = c.kill(self.pid, c.SIGKILL);
                _ = c.waitpid(self.pid, null, 0);
                say(self.out.items);
                fail(what ++ ": the waiter did not exit");
            }
        }
        _ = c.close(self.fd);
        _ = c.waitpid(self.pid, &self.status, 0);
        return self.out.items;
    }
};

fn sessionListed(allocator: std.mem.Allocator, sock: []const u8, name: []const u8) bool {
    var buf: [64 * 1024]u8 = undefined;
    const listing = listSessionsChecked(allocator, sock, &buf, "agent sessions");
    var needle_buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{name}) catch return false;
    return std.mem.indexOf(u8, listing, needle) != null;
}

fn waitUnlisted(allocator: std.mem.Allocator, sock: []const u8, name: []const u8, comptime what: []const u8) void {
    const deadline = nowMs() + 8_000;
    while (sessionListed(allocator, sock, name)) {
        if (nowMs() > deadline) fail(what ++ ": the session is still on the daemon");
        _ = c.usleep(100_000);
    }
}

/// A send that returned at once: `sent` while the agent had not started
/// on the prompt yet, `still_working` once it had.
fn expectSentOrWorking(o: std.json.ObjectMap, comptime what: []const u8) void {
    const got = scStr(o, "outcome", what);
    if (!std.mem.eql(u8, got, "sent") and !std.mem.eql(u8, got, "still_working")) {
        say(got);
        fail(what);
    }
}

fn eventKinds(o: std.json.ObjectMap, kind: []const u8) usize {
    var n: usize = 0;
    for (o.get("events").?.array.items) |ev| {
        if (std.mem.eql(u8, ev.object.get("kind").?.string, kind)) n += 1;
    }
    return n;
}

/// The agent_* tools end to end against the REAL server, with this binary
/// as the agent apps: a fake Claude Code (screen source) and a fake
/// opencode server plus its attached TUI (API source).
/// agent_open `args`/`env` the stages pass: every byte a shell treats
/// specially must reach the fake app exactly.
const EXTRA_ARGS = [_][]const u8{ "--wrap-opt", "a b 'c' \"d\" $HOME ;e `f` *g \\h caf\xc3\xa9 & | <i> #j $(id)" };
const EXTRA_ENV_VALUE = "x y 'z' \"q\" $HOME;`id` *w \\v $(id)";

/// `,"args":[...],"env":{...}` for an agent_open request.
fn extraJson(arena: std.mem.Allocator) []const u8 {
    return std.fmt.allocPrint(arena, ",\"args\":{f},\"env\":{{\"" ++ SMOKE_EXTRA_ENV ++ "\":{f}}}", .{
        std.json.fmt(EXTRA_ARGS, .{}), std.json.fmt(EXTRA_ENV_VALUE, .{}),
    }) catch fail("oom");
}

fn resetStarts() void {
    var buf: [1024]u8 = undefined;
    _ = c.unlink(fcPath(&buf, FC_STARTS).ptr);
}

/// agent_open reports the args and the env NAMES, never a value.
fn expectExtraFacts(arena: std.mem.Allocator, opened: std.json.ObjectMap, comptime what: []const u8) void {
    const args = (opened.get("args") orelse fail(what ++ ": no args fact")).array.items;
    if (args.len != EXTRA_ARGS.len) fail(what ++ ": args fact has the wrong length");
    for (EXTRA_ARGS, args) |w, g| if (!std.mem.eql(u8, w, g.string)) fail(what ++ ": args fact differs");
    const names = (opened.get("env_names") orelse fail(what ++ ": no env_names fact")).array.items;
    if (names.len != 1 or !std.mem.eql(u8, names[0].string, SMOKE_EXTRA_ENV)) fail(what ++ ": env_names fact differs");
    const all = std.json.Stringify.valueAlloc(arena, std.json.Value{ .object = opened }, .{}) catch fail("oom");
    if (std.mem.indexOf(u8, all, "x y 'z'") != null) fail(what ++ ": an env value was echoed");
}

/// Exactly `n` recorded starts of `tag` (a process started a moment ago
/// is waited for), each with the extra args first (byte-exact) and the
/// extra env value.
fn expectStarts(arena: std.mem.Allocator, tag: []const u8, n: usize, comptime what: []const u8) void {
    const until = nowMs() + 5_000;
    while (true) {
        const seen = countStarts(arena, tag, what);
        if (seen == n) return;
        if (seen > n or nowMs() > until) {
            say(std.fmt.allocPrint(arena, "{s}: {d} start(s), expected {d}", .{ tag, seen, n }) catch "?");
            fail(what ++ ": wrong number of starts");
        }
        _ = c.usleep(100_000);
    }
}

fn countStarts(arena: std.mem.Allocator, tag: []const u8, comptime what: []const u8) usize {
    var buf: [1024]u8 = undefined;
    const log = readfile.cappedAlloc(arena, fcPath(&buf, FC_STARTS), 1 << 20) catch return 0;
    var seen: usize = 0;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, log, "\n"), '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, 0);
        if (!std.mem.eql(u8, fields.next() orelse continue, tag)) continue;
        seen += 1;
        for (EXTRA_ARGS) |want| {
            const got = fields.next() orelse "";
            if (!std.mem.eql(u8, got, want)) {
                say(std.fmt.allocPrint(arena, "{s}: start argument {f}, expected {f}", .{ tag, std.json.fmt(got, .{}), std.json.fmt(want, .{}) }) catch "?");
                fail(what ++ ": the args did not arrive byte-exact right after the binary");
            }
        }
        var last: []const u8 = "";
        while (fields.next()) |f| last = f;
        if (!std.mem.startsWith(u8, last, "env=") or !std.mem.eql(u8, last["env=".len..], EXTRA_ENV_VALUE)) {
            say(std.fmt.allocPrint(arena, "{s}: {f}", .{ tag, std.json.fmt(last, .{}) }) catch "?");
            fail(what ++ ": the env value did not arrive byte-exact (or unset_env removed it)");
        }
    }
    return seen;
}

/// The user's own status line command the facts checks chain: it prints
/// how many bytes of JSON it got on stdin.
const FACTS_USER_SETTINGS =
    \\{"statusLine":{"type":"command","command":"printf 'USER-STATUS %s' \"$(wc -c | tr -d ' ')\"","padding":0}}
;

/// The `facts` object of agent `id` in a compact agent_list, and the list's
/// raw reply (its text lane carries the one-line form).
fn listedFacts(m: *Mcp, arena: std.mem.Allocator, id: []const u8) struct { facts: ?std.json.ObjectMap, raw: []const u8 } {
    m.sendToolAllocated("agent_list", "{}");
    const raw = arena.dupe(u8, m.recvLine(20_000)) catch fail("oom");
    const sc = capSc(arena, raw, "agent_list facts", false);
    for (sc.get("agents").?.array.items) |item| {
        if (!std.mem.eql(u8, item.object.get("agent").?.string, id)) continue;
        const f = item.object.get("facts") orelse return .{ .facts = null, .raw = raw };
        return .{ .facts = f.object, .raw = raw };
    }
    fail("agent_list facts: the agent is not listed");
}

fn factNum(o: ?std.json.ObjectMap, key: []const u8) ?f64 {
    const v = (o orelse return null).get(key) orelse return null;
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

/// Claude Code's facts through its status line: the fake runs the status
/// command sketerm put in `--settings` with a document before any prompt
/// (window size known, usage and rate limits unknown) and after each turn;
/// `agent_list` reads unknown first, then 14% and the 7-day limit, and the
/// user's own command (a project-local setting here, never the
/// developer's) still ran with the same JSON. `place` is the JSON tail
/// that puts the agent somewhere (`"binary":...` or `"host":...`).
fn agentFactsCheck(m: *Mcp, arena: std.mem.Allocator, rt: []const u8, place: []const u8, local: bool, comptime what: []const u8) void {
    const proj = std.fmt.allocPrint(arena, "{s}/factsproj", .{rt}) catch fail("oom");
    const dot = std.fmt.allocPrintSentinel(arena, "{s}/.claude", .{proj}, 0) catch fail("oom");
    pathz.makeDirs(dot, 0o700) catch fail(what ++ ": mkdir factsproj");
    {
        const p = std.fmt.allocPrintSentinel(arena, "{s}/settings.local.json", .{dot}, 0) catch fail("oom");
        const f = c.fopen(p.ptr, "w") orelse fail(what ++ ": write settings.local.json");
        _ = c.fwrite(FACTS_USER_SETTINGS.ptr, 1, FACTS_USER_SETTINGS.len, f);
        _ = c.fclose(f);
    }
    var out_buf: [1024]u8 = undefined;
    _ = c.unlink(fcPath(&out_buf, FC_STATUS_OUT).ptr);
    const opened = agentCall(m, arena, "agent_open", std.fmt.allocPrint(arena, "{{\"app\":\"claude\",\"name\":\"facts-1\",\"cwd\":\"{s}\",\"env\":{{\"" ++ FC_STATUS_ENV ++ "\":\"1\"}},\"timeout_ms\":45000,{s}}}", .{ proj, place }) catch fail("oom"), what ++ ": agent_open", false, 60_000);
    const id = arena.dupe(u8, scStr(opened, "agent", what ++ ": agent_open")) catch fail("oom");
    if (factNum(if (opened.get("facts")) |f| f.object else null, "context_used_percent") != null) fail(what ++ ": agent_open reports a context percent before any prompt");

    // Before the first prompt: the window size, never a 0 percent.
    const deadline = nowMs() + 25_000;
    var before: ?std.json.ObjectMap = null;
    while (nowMs() < deadline) {
        before = listedFacts(m, arena, id).facts;
        if (factNum(before, "context_window_tokens") != null) break;
        _ = c.usleep(500_000);
    }
    if (factNum(before, "context_window_tokens") != 200000) fail(what ++ ": agent_list never showed the context window size the status line reported");
    if (factNum(before, "context_used_percent") != null or factNum(before, "rate_7d_used_percent") != null)
        fail(what ++ ": agent_list shows usage before the first prompt (unknown must be absent, never 0)");
    if (factNum(before, "cost_usd") != 0) fail(what ++ ": the reported cost of 0 is missing");

    const sent = agentCall(m, arena, "agent_send", std.fmt.allocPrint(arena, "{{\"agent\":\"{s}\",\"text\":\"facts please\",\"timeout_ms\":20000}}", .{id}) catch fail("oom"), what ++ ": agent_send", false, 45_000);
    expectFact(sent, "outcome", "done", what ++ ": agent_send outcome");
    var after: ?std.json.ObjectMap = null;
    var raw: []const u8 = "";
    const deadline2 = nowMs() + 25_000;
    while (nowMs() < deadline2) {
        const l = listedFacts(m, arena, id);
        after = l.facts;
        raw = l.raw;
        if (factNum(after, "context_used_percent") != null) break;
        _ = c.usleep(500_000);
    }
    if (factNum(after, "context_used_percent") != 14) fail(what ++ ": agent_list never showed the 14% the status line reported after the turn");
    if (factNum(after, "context_used_tokens") != 27656) fail(what ++ ": context_used_tokens is not the summed current usage");
    if (factNum(after, "rate_7d_used_percent") != 98 or factNum(after, "rate_7d_resets_at") != 1791169200) fail(what ++ ": the 7-day rate limit facts are wrong");
    if (std.mem.indexOf(u8, raw, "context 14%, 7d limit 98%") == null) {
        say(raw);
        fail(what ++ ": the compact line does not show the context percent and the 7-day limit");
    }
    // The per-agent results carry them too.
    const read = agentCall(m, arena, "agent_read", std.fmt.allocPrint(arena, "{{\"agent\":\"{s}\"}}", .{id}) catch fail("oom"), what ++ ": agent_read", false, 15_000);
    if (factNum(if (read.get("facts")) |f| f.object else null, "context_used_percent") != 14) fail(what ++ ": agent_read carries no facts");

    // The user's own command ran on both documents, stdin intact.
    const log = readfile.cappedAlloc(arena, fcPath(&out_buf, FC_STATUS_OUT), 1 << 16) catch fail(what ++ ": the status command never ran");
    for ([_][]const u8{ facts.CLAUDE_SAMPLE_FRESH, facts.CLAUDE_SAMPLE }) |doc| {
        if (std.mem.indexOf(u8, log, std.fmt.allocPrint(arena, "USER-STATUS {d}\n", .{doc.len}) catch fail("oom")) == null) {
            say(log);
            fail(what ++ ": the user's status command did not get the whole document");
        }
    }
    const file = std.fmt.allocPrintSentinel(arena, "{s}/sketerm/agent-facts/{s}.json", .{ rt, id }, 0) catch fail("oom");
    if (local and c.access(file.ptr, c.F_OK) != 0) fail(what ++ ": no facts file under the runtime dir");
    _ = agentCall(m, arena, "agent_close", std.fmt.allocPrint(arena, "{{\"agent\":\"{s}\"}}", .{id}) catch fail("oom"), what ++ ": agent_close", false, 15_000);
    if (local and c.access(file.ptr, c.F_OK) == 0) fail(what ++ ": agent_close left the facts file");
    say("smoke-mcp: " ++ what ++ ": facts unknown before the first prompt, then 14% and the 7-day limit; the user's status command still ran ok");
}

fn agentStage(allocator: std.mem.Allocator, exe: [*:0]const u8, rt: []const u8) void {
    var self_buf: [4096]u8 = undefined;
    const self_exe = platform.exePath(&self_buf) orelse fail("agent stage: own executable path");
    _ = c.setenv(FAKE_AGENT_ENV, "1", 1);
    // What a nested Claude Code must never inherit; the fake refuses to
    // start with either (the adapter's unset_env removes CLAUDE*).
    _ = c.setenv("CLAUDE_CODE_CHILD_SESSION", "1", 1);
    _ = c.setenv("CLAUDE_CONFIG_DIR", "/nonexistent-smoke-claude", 1);
    // Like the real one: listening long before it answers, and a request
    // in between is never answered (agent_open's event stream used to be
    // exactly that request, and timed out).
    _ = c.setenv(FAKE_OC_DEAF_ENV, "4500", 1);
    defer {
        _ = c.unsetenv(FAKE_AGENT_ENV);
        _ = c.unsetenv("CLAUDE_CODE_CHILD_SESSION");
        _ = c.unsetenv("CLAUDE_CONFIG_DIR");
        _ = c.unsetenv(FAKE_OC_DEAF_ENV);
    }
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bin_json = std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(self_exe, .{})}) catch fail("oom");

    {
        var m = Mcp.spawn(allocator, exe, &.{});
        m.id += 1;
        const init_req = std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"initialize\",\"params\":{{\"protocolVersion\":\"{s}\",\"capabilities\":{{}}}}}}", .{ m.id, version.mcp_protocol }) catch fail("oom");
        m.send(init_req);
        const init_reply = m.recvLine(10_000);
        if (std.mem.indexOf(u8, init_reply, "\"instructions\"") == null or std.mem.indexOf(u8, init_reply, "agent_open") == null or
            std.mem.indexOf(u8, init_reply, "watch_command") == null)
            fail("initialize carries no instructions about agent_open and watch_command");

        const caps = agentCall(&m, arena, "capabilities", "{}", "capabilities", false, 15_000);
        if (!caps.get("agents").?.bool) fail("capabilities: agents is false in isolated mode");
        // Agents run on SSH hosts wherever an ssh client is installed.
        if (caps.get("agent_ssh").?.bool != caps.get("ssh").?.bool) fail("capabilities: agent_ssh disagrees with the ssh client's presence");
        var ids = std.ArrayList(u8).empty;
        for (caps.get("agent_adapters").?.array.items) |v| ids.appendSlice(arena, v.string) catch {};
        if (std.mem.indexOf(u8, ids.items, "claude") == null or std.mem.indexOf(u8, ids.items, "opencode") == null)
            fail("capabilities: agent_adapters lacks claude or opencode");
        if (std.mem.indexOf(u8, scStr(caps, "agent_waiter", "capabilities"), " mcp agent-wait --socket ") == null)
            fail("capabilities: agent_waiter is not the waiter command");
        // Agents run on the PER-USER daemon of this (isolated) runtime dir.
        const mux_sock = std.fmt.allocPrint(arena, "{s}/sketerm/mux.sock", .{rt}) catch fail("oom");
        if (!caps.get("agent_resume_by_id").?.bool) fail("capabilities: agent_resume_by_id is false");
        if (caps.get("agent_idle_ttl_hours").?.integer != 24) fail("capabilities: agent_idle_ttl_hours is not the default 24");

        const ad = agentCall(&m, arena, "agent_adapters", "{}", "agent_adapters", false, 15_000);
        if (ad.get("count").?.integer < 2) fail("agent_adapters lists fewer than two adapters");

        // Facts: the vocabulary and each adapter's share.
        {
            const af = (caps.get("agent_facts") orelse fail("capabilities: no agent_facts")).object;
            if (af.get("facts").?.object.get("context_used_percent") == null) fail("capabilities: agent_facts lacks context_used_percent");
            const per = af.get("adapters").?.object;
            var claude_has = false;
            for (per.get("claude").?.array.items) |n| claude_has = claude_has or std.mem.eql(u8, n.string, "rate_7d_used_percent");
            var oc_derived = false;
            for (per.get("opencode").?.array.items) |n| oc_derived = oc_derived or std.mem.eql(u8, n.string, "context_used_percent");
            if (!claude_has or !oc_derived) fail("capabilities: agent_facts does not name claude's rate limit or opencode's derived context percent");
        }

        // ── Claude Code (screen source) ─────────────────────────────
        // A wrapper's args and env: byte-exact, the CLAUDE* one kept while
        // the others are removed (the fake refuses to start with those).
        resetStarts();
        // Named after the ids older builds minted: every call below uses it.
        const opened = agentCall(&m, arena, "agent_open", std.fmt.allocPrint(arena, "{{\"app\":\"claude\",\"name\":\"claude-1\",\"binary\":{s},\"timeout_ms\":30000{s}}}", .{ bin_json, extraJson(arena) }) catch fail("oom"), "agent_open claude", false, 45_000);
        expectExtraFacts(arena, opened, "agent_open claude");
        expectStarts(arena, "claude", 1, "agent_open claude");
        expectFact(opened, "name", "claude-1", "agent_open: agent name");
        const c1 = arena.dupe(u8, scStr(opened, "agent", "agent_open")) catch fail("oom");
        if (!std.mem.startsWith(u8, c1, "claude-") or c1.len != "claude-".len + 4) fail("agent_open: the id is not <app>-xxxx");
        const c1_session = std.fmt.allocPrint(arena, "agent-{s}", .{c1}) catch fail("oom");
        expectFact(opened, "session", c1_session, "agent_open: session name");
        // A name is unique among this machine's live agents.
        _ = agentCall(&m, arena, "agent_open", std.fmt.allocPrint(arena, "{{\"app\":\"claude\",\"name\":\"claude-1\",\"binary\":{s}}}", .{bin_json}) catch fail("oom"), "agent_open taken name", true, 15_000);
        // The conversation it runs is a fact, for a resume after a restart.
        if (scStr(opened, "conversation", "agent_open: conversation").len != 36) fail("agent_open: the conversation fact is not the --session-id it was started with");
        if (!opened.get("ready").?.bool) fail("agent_open: the fake Claude Code never became ready (an unset_env leak makes it refuse to start)");
        if (std.mem.indexOf(u8, scStr(opened, "watch_command", "agent_open"), " agent-wait ") == null) fail("agent_open: no watch_command");
        // A cursor baked into the command went stale with the next call.
        if (std.mem.indexOf(u8, scStr(opened, "watch_command", "agent_open"), "--since") != null) fail("agent_open: watch_command carries a cursor");
        if (!sessionListed(allocator, mux_sock, c1_session)) fail("the agent is not a session on the per-user daemon");
        // Recorded like every other headless terminal, at an absolute path.
        const recs_opened = (opened.get("recordings") orelse fail("agent_open: no recordings fact")).array.items;
        if (recs_opened.len != 1 or recs_opened[0].string[0] != '/' or !std.mem.endsWith(u8, recs_opened[0].string, std.fmt.allocPrint(arena, "/{s}.cast", .{c1_session}) catch fail("oom")))
            fail("agent_open: the agent's terminal is not recorded at an absolute path");
        const claude_cast = arena.dupe(u8, recs_opened[0].string) catch fail("oom");

        const sent = agentCall(&m, arena, "agent_send", "{\"agent\":\"claude-1\",\"text\":\"hello there\",\"timeout_ms\":20000}", "agent_send", false, 45_000);
        expectFact(sent, "outcome", "done", "agent_send: outcome");
        expectFact(sent, "message", "echo: hello there", "agent_send: final message");

        // The done carried its job's selection: the answer, not the prompt.
        const sent_recs = (sent.get("records") orelse fail("agent_send: no records with the done")).array.items;
        if (sent_recs.len != 1 or !std.mem.eql(u8, sent_recs[0].object.get("text").?.string, "echo: hello there")) fail("agent_send: the done's records are not its job's answer");
        // Delivery is per record: the done handed the answer out, so a read
        // right after has nothing new (it used to repeat the whole job).
        const read = agentCall(&m, arena, "agent_read", "{\"agent\":\"claude-1\"}", "agent_read", false, 15_000);
        if (read.get("records").?.array.items.len != 0 or read.get("jobs").?.array.items.len != 0)
            fail("agent_read: repeated what the done result already handed out");
        // A deliberate re-read returns it: the answer, never the prompt.
        const reread = agentCall(&m, arena, "agent_read", "{\"agent\":\"claude-1\",\"since\":0}", "agent_read since 0", false, 15_000);
        const recs = reread.get("records").?.array.items;
        if (recs.len != 1) fail("agent_read since 0: expected the one assistant record of one job");
        if (!std.mem.eql(u8, recs[0].object.get("kind").?.string, "assistant") or !std.mem.eql(u8, recs[0].object.get("text").?.string, "echo: hello there"))
            fail("agent_read since 0: wrong records");
        if (reread.get("jobs").?.array.items.len != 1) fail("agent_read since 0: expected one job");
        const since = read.get("next_since").?.integer;

        // A permission prompt waits for its answer.
        const asked = agentCall(&m, arena, "agent_send", "{\"agent\":\"claude-1\",\"text\":\"please ask permission\",\"timeout_ms\":20000}", "agent_send permission", false, 45_000);
        expectFact(asked, "outcome", "needs_input", "agent_send: permission outcome");
        const it = asked.get("interaction") orelse fail("agent_send: no interaction with needs_input");
        if (!std.mem.eql(u8, it.object.get("kind").?.string, "permission")) fail("agent_send: the interaction is not a permission");
        if (it.object.get("options").?.array.items.len != 2) fail("agent_send: the permission has not two options");
        const answered = agentCall(&m, arena, "agent_answer", "{\"agent\":\"claude-1\",\"choice\":\"No\",\"timeout_ms\":20000}", "agent_answer", false, 45_000);
        expectFact(answered, "answered", "No", "agent_answer: answered");
        expectFact(answered, "outcome", "done", "agent_answer: outcome");
        expectFact(answered, "message", "permission answered No", "agent_answer: final message");
        const after = agentCall(&m, arena, "agent_read", std.fmt.allocPrint(arena, "{{\"agent\":\"claude-1\",\"since\":{d}}}", .{since}) catch fail("oom"), "agent_read after the permission", false, 15_000);
        var saw_notice = false;
        for (after.get("records").?.array.items) |r| {
            if (std.mem.eql(u8, r.object.get("kind").?.string, "notice") and std.mem.indexOf(u8, r.object.get("text").?.string, "answered: No") != null) saw_notice = true;
        }
        if (!saw_notice) fail("agent_read: the answered permission left no notice record");

        // match: a message of an unfinished turn (a background agent runs).
        const matched = agentCall(&m, arena, "agent_send", "{\"agent\":\"claude-1\",\"text\":\"two parts\",\"match\":\"PART ONE\",\"timeout_ms\":20000}", "agent_send match", false, 45_000);
        expectFact(matched, "outcome", "match", "agent_send: match outcome");
        const rest = agentCall(&m, arena, "agent_wait", "{\"agent\":\"claude-1\",\"timeout_ms\":20000}", "agent_wait", false, 45_000);
        expectFact(rest, "outcome", "done", "agent_wait: outcome");
        expectFact(rest, "message", "part two", "agent_wait: final message");

        sideQuestions(&m, arena, caps);

        // An opt-in flood: a few messages, the rest as a digest.
        const flood = agentCall(&m, arena, "agent_send", "{\"agent\":\"claude-1\",\"text\":\"flood 7\",\"messages\":true,\"timeout_ms\":20000}", "agent_send flood", false, 45_000);
        expectFact(flood, "outcome", "done", "agent_send flood: outcome");
        const msgs = eventKinds(flood, "message");
        const digest = flood.get("digest") orelse fail("agent_send flood: no digest");
        if (msgs > 3 or msgs + @as(usize, @intCast(digest.object.get("count").?.integer)) != 7) fail("agent_send flood: messages + digest do not add up to the 7 messages");

        // The loop observes agents between calls, and a turn that ended
        // while an unrelated call blocked the loop reads correctly after.
        const slow = agentCall(&m, arena, "agent_send", "{\"agent\":\"claude-1\",\"text\":\"slow reply\",\"timeout_ms\":0}", "agent_send slow", false, 15_000);
        expectSentOrWorking(slow, "agent_send slow: outcome");
        // Everything before the slow turn, handed out now.
        const before_slow = agentCall(&m, arena, "agent_read", "{\"agent\":\"claude-1\"}", "agent_read before slow", false, 15_000).get("next_since").?.integer;
        var one_shot = Waiter.start(scStr(slow, "watch_command", "agent_send slow"));
        const term = agentCall(&m, arena, "term_open", "{}", "term_open", false, 30_000);
        const term_id = term.get("term").?.integer;
        _ = agentCall(&m, arena, "term_exec", std.fmt.allocPrint(arena, "{{\"term\":{d},\"command\":\"sleep 3\",\"timeout_ms\":20000}}", .{term_id}) catch fail("oom"), "term_exec sleep", false, 45_000);
        const woke = one_shot.finish(arena, 15_000, "one-shot waiter");
        // The plain waiter prints the push's text: the line, then the answer.
        if (std.mem.indexOf(u8, untimed(arena, woke), std.fmt.allocPrint(arena, "{s} done: echo: slow reply [state idle]\n\necho: slow reply\n", .{c1}) catch fail("oom")) == null or
            std.mem.indexOf(u8, woke, " done at ") == null)
        {
            say(woke);
            fail("the one-shot waiter did not print the done wake-up with its answer in full");
        }
        if (one_shot.status != 0) fail("the one-shot waiter did not exit 0");
        // ONE delivery state: the waiter's line went into the assistant's
        // context, so agent_wait does not wake for that done again...
        const slow_done = agentCall(&m, arena, "agent_wait", "{\"agent\":\"claude-1\",\"timeout_ms\":1500}", "agent_wait slow", false, 15_000);
        expectFact(slow_done, "outcome", "still_working", "agent_wait slow: the waiter's done woke the tool again");
        if (eventKinds(slow_done, "done") != 0) fail("agent_wait slow: repeated the done the waiter delivered");
        // ...and the answer it printed is handed out like a push's: the read
        // has nothing new, and a deliberate re-read returns exactly that
        // answer, captured once though observed late.
        const slow_read = agentCall(&m, arena, "agent_read", "{\"agent\":\"claude-1\"}", "agent_read slow", false, 15_000);
        if (slow_read.get("records").?.array.items.len != 0) fail("agent_read: repeated the answer the waiter printed");
        const slow_again = agentCall(&m, arena, "agent_read", std.fmt.allocPrint(arena, "{{\"agent\":\"claude-1\",\"since\":{d}}}", .{before_slow}) catch fail("oom"), "agent_read slow since", false, 15_000);
        const slow_recs = slow_again.get("records").?.array.items;
        if (slow_recs.len != 1 or !std.mem.eql(u8, slow_recs[0].object.get("text").?.string, "echo: slow reply")) {
            say(std.json.Stringify.valueAlloc(arena, slow_again.get("records").?, .{}) catch "?");
            fail("agent_read: the late-observed turn is not exactly its answer");
        }
        _ = agentCall(&m, arena, "term_close", std.fmt.allocPrint(arena, "{{\"term\":{d}}}", .{term_id}) catch fail("oom"), "term_close", false, 15_000);

        // Two waiters armed on one agent: the first delivers, the other
        // keeps waiting.
        const lone_cmd = scStr(slow_done, "watch_command", "agent_wait slow");
        var twin_a = Waiter.start(lone_cmd);
        var twin_b = Waiter.start(lone_cmd);
        _ = c.usleep(300_000);
        _ = agentCall(&m, arena, "agent_send", "{\"agent\":\"claude-1\",\"text\":\"slow twins\",\"timeout_ms\":0}", "agent_send twins", false, 15_000);
        const c1_done = std.fmt.allocPrint(arena, "{s} done", .{c1}) catch fail("oom");
        const a_woke = twin_a.waitFor(arena, c1_done, 1, 8_000);
        const b_woke = twin_b.waitFor(arena, c1_done, 1, if (a_woke) 2_000 else 8_000);
        if (a_woke == b_woke) {
            say(twin_a.out.items);
            say(twin_b.out.items);
            fail("two waiters on one agent: expected exactly one to wake");
        }
        twin_a.stop();
        twin_b.stop();

        // --follow: one line per wake-up (turns that end between calls; a
        // call on the agent gets its own), then `watch ended` on close.
        const follow_cmd = std.fmt.allocPrint(arena, "{s} --follow", .{scStr(slow_done, "watch_command", "agent_wait slow")}) catch fail("oom");
        var follower = Waiter.start(follow_cmd);
        _ = c.usleep(300_000);
        for (1..3) |n| {
            // Distinct prompts: the same prompt and answer again would read
            // as the app reprinting its last turn.
            const bg = agentCall(&m, arena, "agent_send", std.fmt.allocPrint(arena, "{{\"agent\":\"claude-1\",\"text\":\"slow again {d}\",\"timeout_ms\":0}}", .{n}) catch fail("oom"), "agent_send slow again", false, 15_000);
            expectSentOrWorking(bg, "agent_send slow again: outcome");
            if (!follower.waitFor(arena, c1_done, n, 15_000)) {
                say(follower.out.items);
                fail("the --follow waiter missed a turn that ended between calls");
            }
        }
        _ = agentCall(&m, arena, "agent_read", "{\"agent\":\"claude-1\"}", "agent_read after follow", false, 15_000);
        const again = agentCall(&m, arena, "agent_send", "{\"agent\":\"claude-1\",\"text\":\"hello again\",\"timeout_ms\":20000}", "agent_send again", false, 45_000);
        expectFact(again, "outcome", "done", "agent_send again: outcome");
        const more = agentCall(&m, arena, "agent_send", "{\"agent\":\"claude-1\",\"text\":\"and once more\",\"timeout_ms\":20000}", "agent_send more", false, 45_000);
        expectFact(more, "outcome", "done", "agent_send more: outcome");

        // The model picker: agent_set returns once the app CONFIRMED the
        // change (the fake applies it 600 ms after `s`), so the very next
        // call finds the agent idle instead of `waiting for an answer`.
        const before_set = agentCall(&m, arena, "agent_read", "{\"agent\":\"claude-1\"}", "agent_read before set", false, 15_000).get("next_since").?.integer;
        const set_model = agentCall(&m, arena, "agent_set", "{\"agent\":\"claude-1\",\"model\":\"Haiku\",\"timeout_ms\":20000}", "agent_set model", false, 45_000);
        expectFact(set_model, "confirmation", "Set model to Haiku 4.5 for this session only", "agent_set model: the app's confirmation");
        expectFact(set_model, "state", "idle", "agent_set model: idle once confirmed");
        const right_after = agentCall(&m, arena, "agent_send", "{\"agent\":\"claude-1\",\"text\":\"right after the model\",\"timeout_ms\":20000}", "agent_send after set", false, 45_000);
        expectFact(right_after, "outcome", "done", "agent_send after agent_set: outcome");
        // The adapter's command is a notice, not `user: /model`.
        const set_read = agentCall(&m, arena, "agent_read", std.fmt.allocPrint(arena, "{{\"agent\":\"claude-1\",\"since\":{d}}}", .{before_set}) catch fail("oom"), "agent_read after set", false, 15_000);
        const set_recs = set_read.get("records").?.array.items;
        if (set_recs.len != 2 or !std.mem.eql(u8, set_recs[0].object.get("kind").?.string, "notice") or
            std.mem.indexOf(u8, set_recs[0].object.get("text").?.string, "model set to Haiku") == null)
        {
            say(std.json.Stringify.valueAlloc(arena, set_read.get("records").?, .{}) catch "?");
            fail("agent_read: the model change is not one notice record before the next turn");
        }
        for (set_recs) |r| if (std.mem.indexOf(u8, r.object.get("text").?.string, "/model") != null) fail("agent_read: the adapter's /model reached the transcript");

        // Effort is a launch value (Claude Code's /effort saves the user's
        // default): the app is restarted with --effort and resumes ITS
        // conversation, which `recall` proves.
        const set_effort = agentCall(&m, arena, "agent_set", "{\"agent\":\"claude-1\",\"effort\":\"high\",\"timeout_ms\":30000}", "agent_set effort", false, 60_000);
        if (!set_effort.get("relaunched").?.bool) fail("agent_set effort: not a relaunch");
        expectFact(set_effort, "state", "idle", "agent_set effort: idle after the relaunch");
        const recalled = agentCall(&m, arena, "agent_send", "{\"agent\":\"claude-1\",\"text\":\"recall\",\"timeout_ms\":20000}", "agent_send recall", false, 45_000);
        expectFact(recalled, "message", "first prompt was: hello there", "agent_send recall: the relaunch resumed the same conversation");
        {
            var lb: [1024]u8 = undefined;
            const launches = readfile.cappedAlloc(arena, fcPath(&lb, FC_LAUNCHES), 1 << 20) catch fail("the fake Claude Code logged no launch");
            var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, launches, "\n"), '\n');
            const first = lines.next() orelse fail("no first launch");
            // The refused resume (`nope-1234`) launched the fake in between.
            var second = lines.next() orelse fail("agent_set effort: no second launch");
            if (std.mem.indexOf(u8, second, "--resume nope-1234") != null) second = lines.next() orelse fail("agent_set effort: no relaunch after the refused resume");
            const sid_at = std.mem.indexOf(u8, first, "--session-id ") orelse fail("the first launch named no conversation id");
            const sid = first[sid_at + "--session-id ".len ..][0..36];
            const want = std.fmt.allocPrint(arena, "--resume {s}", .{sid}) catch fail("oom");
            if (std.mem.indexOf(u8, second, want) == null or std.mem.indexOf(u8, second, "--effort high") == null) {
                say(launches);
                fail("the relaunch did not resume the conversation with --effort high");
            }
            // The relaunch started the wrapper with the same args and env.
            expectStarts(arena, "claude", 2, "agent_set effort relaunch");
            var sb: [1024]u8 = undefined;
            if (fileExists(fcPath(&sb, FC_SETTINGS_WRITTEN))) fail("something wrote the user's default settings (/effort or a picker's Enter)");
        }

        // A conversation the app does not have fails the open, naming it,
        // and leaves no agent behind (the fake prints what claude prints).
        // Its launch carries no wrapper args: the starts log is reset below.
        {
            const refused = agentCall(&m, arena, "agent_open", std.fmt.allocPrint(arena, "{{\"app\":\"claude\",\"resume\":\"nope-1234\",\"binary\":{s},\"timeout_ms\":15000}}", .{bin_json}) catch fail("oom"), "agent_open unknown resume", true, 30_000);
            const err = (refused.get("error") orelse fail("agent_open unknown resume: no error object")).object;
            expectFact(err, "code", "not_found", "agent_open unknown resume: code");
            if (std.mem.indexOf(u8, scStr(err, "message", "agent_open unknown resume"), "nope-1234") == null) fail("agent_open unknown resume: the error does not name the id");
            const left = agentCall(&m, arena, "agent_list", "{}", "agent_list after a refused resume", false, 15_000).get("agents").?.array.items;
            for (left) |a| if (a.object.get("conversation")) |cv| if (std.mem.eql(u8, cv.string, "nope-1234")) fail("agent_open unknown resume: an agent was left behind");
        }

        // Several agents: agent_wait `agents` hands out one --any command,
        // which wakes on the first of them and names it.
        const second = agentCall(&m, arena, "agent_open", std.fmt.allocPrint(arena, "{{\"app\":\"claude\",\"name\":\"claude-2\",\"binary\":{s},\"timeout_ms\":30000{s}}}", .{ bin_json, extraJson(arena) }) catch fail("oom"), "agent_open claude-2", false, 45_000);
        expectFact(second, "name", "claude-2", "agent_open: second agent name");
        const c2 = arena.dupe(u8, scStr(second, "agent", "agent_open claude-2")) catch fail("oom");
        const both = agentCall(&m, arena, "agent_wait", "{\"agents\":[\"claude-1\",\"claude-2\"],\"timeout_ms\":0}", "agent_wait agents", false, 15_000);
        expectFact(both, "outcome", "still_working", "agent_wait agents: outcome");
        if (both.get("agents").?.array.items.len != 2) fail("agent_wait agents: the agents fact");
        const any_cmd = scStr(both, "watch_command", "agent_wait agents");
        if (std.mem.indexOf(u8, any_cmd, " --any ") == null or !std.mem.endsWith(u8, any_cmd, std.fmt.allocPrint(arena, " {s} {s}", .{ c1, c2 }) catch fail("oom"))) {
            say(any_cmd);
            fail("agent_wait agents: watch_command is not an --any waiter on both");
        }
        var any_waiter = Waiter.start(any_cmd);
        _ = c.usleep(300_000);
        _ = agentCall(&m, arena, "agent_send", "{\"agent\":\"claude-2\",\"text\":\"slow from two\",\"timeout_ms\":0}", "agent_send claude-2", false, 15_000);
        const any_out = any_waiter.finish(arena, 15_000, "--any waiter");
        if (std.mem.indexOf(u8, untimed(arena, any_out), std.fmt.allocPrint(arena, "{s} done: echo: slow from two", .{c2}) catch fail("oom")) == null) {
            say(any_out);
            fail("the --any waiter did not wake on the second agent, by name");
        }
        // Delivery is confirmed: every send above needed the app's evidence
        // (a turn, a record), and a prompt the app swallows (the fake goes
        // deaf, as a wedged Claude Code did) fails as not_delivered, on the
        // one-agent path with timeout_ms 0 and on the agents path, never
        // as `sent`.
        const deafened = agentCall(&m, arena, "agent_send", "{\"agent\":\"claude-2\",\"text\":\"go deaf\",\"timeout_ms\":20000}", "agent_send go deaf", false, 45_000);
        expectFact(deafened, "outcome", "done", "agent_send go deaf: outcome");
        const caps_d = agentCall(&m, arena, "capabilities", "{}", "capabilities delivery", false, 15_000);
        const deliv = (caps_d.get("agent_delivery") orelse fail("capabilities: no agent_delivery")).object;
        expectFact(deliv, "error_code", "not_delivered", "capabilities: agent_delivery error code");
        {
            const t0 = nowMs();
            const lost = agentCall(&m, arena, "agent_send", "{\"agent\":\"claude-2\",\"text\":\"are you there\",\"timeout_ms\":0}", "agent_send to a deaf app", true, 45_000);
            const err = (lost.get("error") orelse fail("agent_send to a deaf app: no error")).object;
            expectFact(err, "code", "not_delivered", "agent_send to a deaf app: code");
            const details = (err.get("details") orelse fail("agent_send to a deaf app: no details")).object;
            expectFact(details, "state", "idle", "agent_send to a deaf app: the state it was left in");
            if (nowMs() - t0 < deliv.get("confirm_ms").?.integer) fail("agent_send to a deaf app: failed before the confirmation bound");
            const many_lost = agentCall(&m, arena, "agent_send", "{\"agents\":[\"claude-2\"],\"text\":\"still there\"}", "agent_send agents to a deaf app", false, 45_000);
            const r0 = many_lost.get("results").?.array.items[0].object;
            expectFact(r0, "outcome", "failed", "agent_send agents to a deaf app: outcome");
            expectFact(r0.get("error").?.object, "code", "not_delivered", "agent_send agents to a deaf app: code");
        }
        _ = agentCall(&m, arena, "agent_close", "{\"agent\":\"claude-2\"}", "agent_close claude-2", false, 15_000);

        // The follower push route (the opencode plugin's): found by the
        // pid that started the server, it follows agents opened after it,
        // and a done carries its short answer, which agent_read then does
        // not repeat.
        {
            const follow_server = std.fmt.allocPrint(arena, "'{s}' mcp agent-wait --server --follow --json --parent {d}", .{ std.mem.span(exe), c.getpid() }) catch fail("oom");
            var pushed = Waiter.start(follow_server);
            const push_deadline = nowMs() + 8_000;
            while (agentCall(&m, arena, "capabilities", "{}", "capabilities followers", false, 15_000).get("agent_push_followers").?.integer != 1) {
                if (nowMs() > push_deadline) fail("capabilities: the --server follower is not counted");
                _ = c.usleep(100_000);
            }
            const third = agentCall(&m, arena, "agent_open", std.fmt.allocPrint(arena, "{{\"app\":\"claude\",\"name\":\"claude-3\",\"binary\":{s},\"timeout_ms\":30000{s}}}", .{ bin_json, extraJson(arena) }) catch fail("oom"), "agent_open claude-3", false, 45_000);
            const c3 = arena.dupe(u8, scStr(third, "agent", "agent_open claude-3")) catch fail("oom");
            m.sendToolAllocated("agent_send", "{\"agent\":\"claude-3\",\"text\":\"push to three\",\"timeout_ms\":0}");
            const bg3 = arena.dupe(u8, m.recvLine(15_000)) catch fail("oom");
            _ = capSc(arena, bg3, "agent_send claude-3", false);
            // Pushed: the prose says to end the turn, not to arm a waiter.
            if (std.mem.indexOf(u8, bg3, "pushed into this session") == null) {
                say(bg3);
                fail("agent_send with a follower: the prose still asks for a waiter");
            }
            const want = std.fmt.allocPrint(arena, "\"content\":\"{s} done at ", .{c3}) catch fail("oom");
            if (!pushed.waitFor(arena, want, 1, 15_000) or std.mem.indexOf(u8, untimed(arena, pushed.out.items), ": echo: push to three [state idle]\\n\\necho: push to three\"") == null) {
                say(pushed.out.items);
                fail("the --server follower did not push the later agent's done with its answer");
            }
            if (std.mem.indexOf(u8, pushed.out.items, "\"meta\":{\"agent\":") == null) fail("the --server follower's wake carries no meta");
            const after_push = agentCall(&m, arena, "agent_read", "{\"agent\":\"claude-3\"}", "agent_read after push", false, 15_000);
            if (after_push.get("records").?.array.items.len != 0) fail("agent_read: repeated the answer the push carried");
            _ = agentCall(&m, arena, "agent_close", "{\"agent\":\"claude-3\"}", "agent_close claude-3", false, 15_000);
            // A server follower outlives the agents it watched.
            _ = c.usleep(300_000);
            if (std.mem.indexOf(u8, pushed.out.items, "\"type\":\"end\"") != null) fail("the --server follower ended when its agent closed");
            pushed.stop();
        }

        const closed = agentCall(&m, arena, "agent_close", "{\"agent\":\"claude-1\"}", "agent_close claude", false, 15_000);
        if (!closed.get("closed").?.bool or closed.get("sessions").?.array.items.len != 1) fail("agent_close: did not close the one session");
        const followed = follower.finish(arena, 15_000, "follow waiter");
        if (std.mem.count(u8, followed, c1_done) < 2 or std.mem.indexOf(u8, followed, "watch ended: agent closed") == null) {
            say(followed);
            fail("the --follow waiter did not print each turn and then watch ended");
        }
        // The adapter's own picker and the restart woke nobody.
        if (std.mem.indexOf(u8, followed, "needs_input") != null or std.mem.indexOf(u8, followed, "exited") != null or
            std.mem.indexOf(u8, followed, "connection_lost") != null)
        {
            say(followed);
            fail("the --follow waiter was woken by the adapter's own picker or restart");
        }
        waitUnlisted(allocator, mux_sock, c1_session, "agent_close claude");
        if (!fileExists(claude_cast)) fail("the agent's recording does not exist");
        say("smoke-mcp: agents: fake Claude Code (open, send, read once per record, permission, match, flood, shared waiter delivery, two waiters, --any, late backlog, model, effort relaunch, recording, close) ok");

        // The channel push route: a Claude Code session started with this
        // server's channel gets every wake-up as a notification line, a
        // done with its answer, once; without the option nothing is pushed.
        {
            var ch = Mcp.spawnUnder(allocator, exe, &.{ "--dangerously-load-development-channels", "server:sketerm" });
            ch.id += 1;
            ch.send(std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"initialize\",\"params\":{{\"protocolVersion\":\"{s}\",\"capabilities\":{{}},\"clientInfo\":{{\"name\":\"claude-code\",\"version\":\"2\"}}}}}}", .{ ch.id, version.mcp_protocol }) catch fail("oom"));
            const ch_init = arena.dupe(u8, ch.recvLine(10_000)) catch fail("oom");
            if (std.mem.indexOf(u8, ch_init, "\"experimental\":{\"claude/channel\":{}}") == null) fail("initialize: no claude/channel capability");
            if (std.mem.indexOf(u8, ch_init, "END YOUR TURN") == null) fail("initialize: the instructions do not say the channel delivers events");
            ch.send("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}");
            expectFact(agentCall(&ch, arena, "capabilities", "{}", "capabilities channel", false, 15_000), "agent_push", "channel", "capabilities: agent_push under a channel session");
            const pc = agentCall(&ch, arena, "agent_open", std.fmt.allocPrint(arena, "{{\"app\":\"claude\",\"name\":\"claude-ch\",\"binary\":{s},\"timeout_ms\":30000{s}}}", .{ bin_json, extraJson(arena) }) catch fail("oom"), "agent_open channel", false, 45_000);
            const pid_ch = arena.dupe(u8, scStr(pc, "agent", "agent_open channel")) catch fail("oom");
            _ = agentCall(&ch, arena, "agent_send", "{\"agent\":\"claude-ch\",\"text\":\"channel ping\",\"timeout_ms\":0}", "agent_send channel", false, 15_000);
            const note = arena.dupe(u8, ch.recvLine(15_000)) catch fail("oom");
            const want_note = std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"method\":\"notifications/claude/channel\",\"params\":{{\"content\":\"{s} done: echo: channel ping [state idle]\\n\\necho: channel ping\",\"meta\":{{\"agent\":\"{s}\",\"name\":\"claude-ch\",\"kind\":\"done\"", .{ pid_ch, pid_ch }) catch fail("oom");
            if (!std.mem.startsWith(u8, untimed(arena, note), want_note) or std.mem.indexOf(u8, note, " done at ") == null) {
                say(note);
                fail("the channel notification is not the done with its answer");
            }
            // Delivered once: neither a wait nor a read repeats it.
            const ch_after = agentCall(&ch, arena, "agent_wait", "{\"agent\":\"claude-ch\",\"timeout_ms\":1500}", "agent_wait after channel", false, 15_000);
            if (eventKinds(ch_after, "done") != 0) fail("agent_wait: repeated the done the channel delivered");
            if (agentCall(&ch, arena, "agent_read", "{\"agent\":\"claude-ch\"}", "agent_read after channel", false, 15_000).get("records").?.array.items.len != 0)
                fail("agent_read: repeated the answer the channel carried");
            _ = agentCall(&ch, arena, "agent_close", "{\"agent\":\"claude-ch\"}", "agent_close channel", false, 15_000);
            ch.closeStdinWait();
            // Another server's channel is not ours: no capability is withheld, but nothing is pushed.
            var other = Mcp.spawnUnder(allocator, exe, &.{ "--channels", "server:telegram" });
            other.id += 1;
            other.send(std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"initialize\",\"params\":{{\"protocolVersion\":\"{s}\",\"capabilities\":{{}},\"clientInfo\":{{\"name\":\"claude-code\",\"version\":\"2\"}}}}}}", .{ other.id, version.mcp_protocol }) catch fail("oom"));
            _ = other.recvLine(10_000);
            expectFact(agentCall(&other, arena, "capabilities", "{}", "capabilities other channel", false, 15_000), "agent_push", "none", "capabilities: agent_push for another server's channel");
            other.closeStdinWait();
            say("smoke-mcp: agents: push routes (channel notification with the answer once, --server follower with later agents) ok");
        }

        // Claude Code's facts through its status line command (after the
        // checks above that read the fake's launch log from its start).
        agentFactsCheck(&m, arena, rt, std.fmt.allocPrint(arena, "\"binary\":{s}", .{bin_json}) catch fail("oom"), true, "facts (local)");

        // ── opencode (API source) ───────────────────────────────────
        resetStarts();
        // The attached TUI is off by default (capabilities.agent_tui): asked for here.
        {
            const caps_tui = (agentCall(&m, arena, "capabilities", "{}", "capabilities agent_tui", false, 15_000).get("agent_tui") orelse fail("capabilities: no agent_tui")).object;
            const apps = caps_tui.get("apps").?.array.items;
            if (!caps_tui.get("available").?.bool or apps.len != 1 or !std.mem.eql(u8, apps[0].string, "opencode") or caps_tui.get("on_by_default").?.array.items.len != 0)
                fail("capabilities.agent_tui: not opencode alone, off by default");
        }
        const oc = agentCall(&m, arena, "agent_open", std.fmt.allocPrint(arena, "{{\"app\":\"opencode\",\"name\":\"opencode-1\",\"binary\":{s},\"tui\":true,\"timeout_ms\":30000{s}}}", .{ bin_json, extraJson(arena) }) catch fail("oom"), "agent_open opencode", false, 45_000);
        if (!oc.get("tui").?.bool) fail("agent_open opencode tui:true: tui is not true");
        const o1 = arena.dupe(u8, scStr(oc, "agent", "agent_open opencode")) catch fail("oom");
        const o1_session = std.fmt.allocPrint(arena, "agent-{s}", .{o1}) catch fail("oom");
        const o1_server = std.fmt.allocPrint(arena, "agent-{s}-server", .{o1}) catch fail("oom");
        expectFact(oc, "session", o1_session, "agent_open opencode: session");
        expectFact(oc, "server_session", o1_server, "agent_open opencode: server session");
        // opencode's API has no side question: refused, nothing sent.
        {
            const refused = agentCall(&m, arena, "agent_ask", "{\"agent\":\"opencode-1\",\"text\":\"how far are you?\"}", "agent_ask opencode", true, 15_000);
            expectFact((refused.get("error") orelse fail("agent_ask opencode: no error")).object, "code", "invalid_args", "agent_ask opencode: code");
        }
        // The fake server swallowed every request of its first 4.5 s: the
        // open waited it out on health probes instead of failing.
        if (!oc.get("ready").?.bool) fail("agent_open opencode: not ready");
        // Both processes started with the binary got the args and env.
        expectExtraFacts(arena, oc, "agent_open opencode");
        expectStarts(arena, "serve", 1, "agent_open opencode server");
        expectStarts(arena, "attach", 1, "agent_open opencode TUI");
        if (!sessionListed(allocator, mux_sock, o1_session) or !sessionListed(allocator, mux_sock, o1_server))
            fail("the opencode sessions are not on the per-user daemon");
        expectPasswordsHidden(arena, (oc.get("recordings") orelse fail("agent_open opencode: no recordings")).array.items, "local opencode");
        const set = agentCall(&m, arena, "agent_set", "{\"agent\":\"opencode-1\",\"model\":\"fakeprov/m1\",\"effort\":\"high\"}", "agent_set opencode", false, 30_000);
        expectFact(set, "current_model", "fakeprov/m1", "agent_set: current model");
        expectFact(set, "current_effort", "high", "agent_set: current effort");
        const oc_sent = agentCall(&m, arena, "agent_send", "{\"agent\":\"opencode-1\",\"text\":\"what model\",\"timeout_ms\":20000}", "agent_send opencode", false, 45_000);
        expectFact(oc_sent, "outcome", "done", "agent_send opencode: outcome");
        expectFact(oc_sent, "message", "echo: what model model=fakeprov/m1 variant=high", "agent_send opencode: the model and variant reached the server");
        // Facts from the API: the answer's tokens against its model's
        // context limit, the percent derived through facts.json.
        {
            const f = if (oc_sent.get("facts")) |v| v.object else fail("agent_send opencode: no facts");
            if (factNum(f, "context_used_tokens") != 10000 or factNum(f, "context_window_tokens") != 100000 or factNum(f, "context_used_percent") != 10) {
                say(std.json.Stringify.valueAlloc(arena, std.json.Value{ .object = f }, .{}) catch "?");
                fail("agent_send opencode: facts are not the answer's tokens over the model's limit");
            }
            if (f.get("rate_7d_used_percent") != null) fail("agent_send opencode: a fact opencode never reports is present");
        }
        const oc_match = agentCall(&m, arena, "agent_send", "{\"agent\":\"opencode-1\",\"text\":\"two messages\",\"match\":\"alpha\",\"timeout_ms\":20000}", "agent_send opencode match", false, 45_000);
        expectFact(oc_match, "outcome", "match", "agent_send opencode: match outcome");
        const oc_rest = agentCall(&m, arena, "agent_wait", "{\"agent\":\"opencode-1\",\"timeout_ms\":20000}", "agent_wait opencode", false, 45_000);
        expectFact(oc_rest, "outcome", "done", "agent_wait opencode: outcome");
        expectFact(oc_rest, "message", "beta two", "agent_wait opencode: message");
        const oc_perm = agentCall(&m, arena, "agent_send", "{\"agent\":\"opencode-1\",\"text\":\"needs permission\",\"timeout_ms\":20000}", "agent_send opencode permission", false, 45_000);
        expectFact(oc_perm, "outcome", "needs_input", "agent_send opencode permission: outcome");
        const oc_ans = agentCall(&m, arena, "agent_answer", "{\"agent\":\"opencode-1\",\"choice\":\"Reject\",\"timeout_ms\":20000}", "agent_answer opencode", false, 45_000);
        expectFact(oc_ans, "answered", "Reject", "agent_answer opencode: answered");
        expectFact(oc_ans, "outcome", "done", "agent_answer opencode: outcome");
        expectFact(oc_ans, "message", "permission reject", "agent_answer opencode: message");
        // Several questions in one prompt: a one-line answer is refused
        // with every question and what it takes; a send is refused toward
        // agent_answer; one line per question answers.
        {
            const q_asked = agentCall(&m, arena, "agent_send", "{\"agent\":\"opencode-1\",\"text\":\"ask two questions\",\"timeout_ms\":20000}", "agent_send opencode questions", false, 45_000);
            expectFact(q_asked, "outcome", "needs_input", "agent_send opencode questions: outcome");
            const one = agentCall(&m, arena, "agent_answer", "{\"agent\":\"opencode-1\",\"choice\":\"a.zig\"}", "agent_answer opencode one line", true, 15_000);
            const one_msg = scStr((one.get("error") orelse fail("agent_answer one line: no error")).object, "message", "agent_answer one line");
            for ([_][]const u8{ "asks 2 questions and the answer has 1 line", "\n1. Which file? options: 1. a.zig, 2. b.zig (free text accepted)", "\n2. Which checks? options: 1. lint, 2. test (several, comma-separated)" }) |want| {
                if (std.mem.indexOf(u8, one_msg, want) == null) {
                    say(one_msg);
                    fail("agent_answer opencode one line: the refusal does not list the questions");
                }
            }
            const q_sent = agentCall(&m, arena, "agent_send", "{\"agent\":\"opencode-1\",\"text\":\"hello\"}", "agent_send opencode while asked", true, 15_000);
            const sent_msg = scStr((q_sent.get("error") orelse fail("agent_send while asked: no error")).object, "message", "agent_send while asked");
            if (std.mem.indexOf(u8, sent_msg, "answer it with agent_answer") == null or std.mem.indexOf(u8, sent_msg, "pending question: \"Which file?\"") == null) {
                say(sent_msg);
                fail("agent_send while asked: the refusal does not point at agent_answer with the prompt");
            }
            const q_both = agentCall(&m, arena, "agent_answer", "{\"agent\":\"opencode-1\",\"choice\":\"2\\nlint, test\",\"timeout_ms\":20000}", "agent_answer opencode two lines", false, 45_000);
            expectFact(q_both, "outcome", "done", "agent_answer opencode two lines: outcome");
            expectFact(q_both, "message", "answers | b.zig | lint test", "agent_answer opencode two lines: the answers reached the server");
        }
        // The TUI stops and starts on a live agent; the agent is driven over
        // the API either way, and what the user watches follows it.
        {
            const off = agentCall(&m, arena, "agent_set", "{\"agent\":\"opencode-1\",\"tui\":false}", "agent_set tui false", false, 15_000);
            if (off.get("tui").?.bool) fail("agent_set tui:false: tui is still true");
            expectFact(off, "session", o1_server, "agent_set tui:false: the session to watch is the server's");
            waitUnlisted(allocator, mux_sock, o1_session, "agent_set tui:false");
            const no_tui = agentCall(&m, arena, "agent_send", "{\"agent\":\"opencode-1\",\"text\":\"no tui here\",\"timeout_ms\":20000}", "agent_send without tui", false, 45_000);
            expectFact(no_tui, "outcome", "done", "agent_send without the TUI: outcome");
            const on = agentCall(&m, arena, "agent_set", "{\"agent\":\"opencode-1\",\"tui\":true}", "agent_set tui true", false, 30_000);
            if (!on.get("tui").?.bool) fail("agent_set tui:true: tui is not true");
            expectFact(on, "session", o1_session, "agent_set tui:true: the session to watch is the TUI's");
            expectStarts(arena, "attach", 2, "agent_set tui:true: the TUI started again");
            if (!sessionListed(allocator, mux_sock, o1_session)) fail("agent_set tui:true: no TUI session on the daemon");
        }
        const oc_closed = agentCall(&m, arena, "agent_close", "{\"agent\":\"opencode-1\"}", "agent_close opencode", false, 15_000);
        if (oc_closed.get("sessions").?.array.items.len != 2) fail("agent_close opencode: not both sessions");
        waitUnlisted(allocator, mux_sock, o1_session, "agent_close opencode");
        waitUnlisted(allocator, mux_sock, o1_server, "agent_close opencode server");
        // By default: no TUI process at all, the server's session is the
        // one to watch, and close ends just that.
        {
            const plain = agentCall(&m, arena, "agent_open", std.fmt.allocPrint(arena, "{{\"app\":\"opencode\",\"name\":\"opencode-2\",\"binary\":{s},\"timeout_ms\":30000}}", .{bin_json}) catch fail("oom"), "agent_open opencode without tui", false, 45_000);
            if (plain.get("tui").?.bool) fail("agent_open opencode: a TUI by default");
            expectFact(plain, "session", scStr(plain, "server_session", "agent_open opencode without tui"), "agent_open opencode without tui: session");
            expectStarts(arena, "attach", 2, "agent_open opencode without tui: an attach was started");
            const said = agentCall(&m, arena, "agent_send", "{\"agent\":\"opencode-2\",\"text\":\"headless\",\"timeout_ms\":20000}", "agent_send opencode without tui", false, 45_000);
            expectFact(said, "message", "echo: headless model=default variant=default", "agent_send opencode without tui: message");
            for (agentCall(&m, arena, "agent_list", "{\"detail\":true}", "agent_list opencode without tui", false, 15_000).get("agents").?.array.items) |li| if (std.mem.eql(u8, li.object.get("name").?.string, "opencode-2") and li.object.get("sessions").?.array.items.len != 1) fail("agent_list opencode without tui: the server session listed twice");
            const closed2 = agentCall(&m, arena, "agent_close", "{\"agent\":\"opencode-2\"}", "agent_close opencode without tui", false, 15_000);
            if (closed2.get("sessions").?.array.items.len != 1) fail("agent_close opencode without tui: not the one server session");
        }
        say("smoke-mcp: agents: fake opencode (open, set, send, match, permission, TUI on/off, no TUI by default, close) ok");
        m.closeStdinWait();
    }

    // ── several agents: a one-call hand-off, a send to several with
    // interrupt, a wait for all, the final message, the compact list ──
    {
        var m = Mcp.spawn(allocator, exe, &.{});
        m.initialize();
        const caps = agentCall(&m, arena, "capabilities", "{}", "capabilities several", false, 15_000);
        for ([_][]const u8{ "agent_wait_all", "agent_send_many", "agent_send_interrupt", "agent_read_final", "agent_list_compact", "agent_relaunch", "agent_open_handoff", "term_exec_shell_default" }) |k| {
            const v = caps.get(k) orelse {
                say(k);
                fail("capabilities: a fact of the several-agents package is missing");
            };
            if (v != .bool or !v.bool) fail("capabilities: a fact of the several-agents package is not true");
        }
        // timeout_ms 0 with a prompt: started, waited for, prompt sent, back at once.
        const fa = agentCall(&m, arena, "agent_open", std.fmt.allocPrint(arena, "{{\"app\":\"claude\",\"name\":\"fan-a\",\"binary\":{s},\"prompt\":\"handed off\",\"timeout_ms\":0}}", .{bin_json}) catch fail("oom"), "agent_open hand-off", false, 90_000);
        if (!fa.get("prompt_sent").?.bool) fail("agent_open timeout_ms 0: the prompt was not sent");
        expectSentOrWorking(fa, "agent_open hand-off: outcome");
        if (fa.get("timed_out").?.bool) fail("agent_open hand-off: timed_out although it was asked not to wait");
        const a_id = arena.dupe(u8, scStr(fa, "agent", "agent_open hand-off")) catch fail("oom");
        const fb = agentCall(&m, arena, "agent_open", std.fmt.allocPrint(arena, "{{\"app\":\"claude\",\"name\":\"fan-b\",\"binary\":{s},\"timeout_ms\":30000}}", .{bin_json}) catch fail("oom"), "agent_open fan-b", false, 45_000);
        const b_id = arena.dupe(u8, scStr(fb, "agent", "agent_open fan-b")) catch fail("oom");

        // all: fan-a once its handed-off turn is done, fan-b (never sent
        // anything, idle) at once.
        const both = agentCall(&m, arena, "agent_wait", "{\"agents\":[\"fan-a\",\"fan-b\"],\"all\":true,\"timeout_ms\":20000}", "agent_wait all", false, 45_000);
        expectFact(both, "outcome", "all_settled", "agent_wait all: outcome");
        const rs = both.get("results").?.array.items;
        if (rs.len != 2) fail("agent_wait all: not one result per agent");
        expectFact(rs[0].object, "outcome", "done", "agent_wait all: fan-a settled by its done");
        expectFact(rs[0].object, "text", "echo: handed off", "agent_wait all: fan-a's answer preview");
        expectFact(rs[1].object, "outcome", "idle", "agent_wait all: fan-b was idle all along");
        if (std.mem.indexOf(u8, scStr(both, "watch_command", "agent_wait all"), " --all ") == null) fail("agent_wait all: watch_command is not an --all waiter");

        // final: just the last message, once; then a pointer; since re-reads.
        const fin = agentCall(&m, arena, "agent_read", "{\"agent\":\"fan-a\",\"final\":true}", "agent_read final", false, 15_000);
        const fin_recs = fin.get("records").?.array.items;
        if (fin_recs.len != 1 or !std.mem.eql(u8, fin_recs[0].object.get("text").?.string, "echo: handed off")) fail("agent_read final: not exactly the last message");
        const fin_again = agentCall(&m, arena, "agent_read", "{\"agent\":\"fan-a\",\"final\":true}", "agent_read final again", false, 15_000);
        if (fin_again.get("records").?.array.items.len != 0) fail("agent_read final: repeated a record handed out");
        if (fin_again.get("jobs").?.array.items.len != 1 or fin_again.get("jobs").?.array.items[0].object.get("earlier") == null) fail("agent_read final: no pointer at the message handed out before");
        if (agentCall(&m, arena, "agent_read", "{\"agent\":\"fan-a\",\"final\":true,\"since\":0}", "agent_read final since 0", false, 15_000).get("records").?.array.items.len != 1)
            fail("agent_read final since 0: no re-read");
        _ = agentCall(&m, arena, "agent_read", "{\"agent\":\"fan-a\",\"final\":true,\"detail\":\"all\"}", "agent_read final + all", true, 15_000);

        // One text to both, fan-a busy on a long turn: interrupted first,
        // then sent as a new prompt; an unknown name fails alone.
        const glacial = agentCall(&m, arena, "agent_send", "{\"agent\":\"fan-a\",\"text\":\"glacial work\",\"timeout_ms\":0}", "agent_send glacial", false, 15_000);
        expectSentOrWorking(glacial, "agent_send glacial: outcome");
        _ = c.usleep(500_000);
        const many = agentCall(&m, arena, "agent_send", "{\"agents\":[\"fan-a\",\"fan-b\",\"nope-x\"],\"text\":\"fan out\",\"interrupt\":true,\"timeout_ms\":20000}", "agent_send agents interrupt", false, 45_000);
        const mr = many.get("results").?.array.items;
        if (mr.len != 3 or many.get("failed").?.integer != 1) fail("agent_send agents: not three results with one failure");
        expectFact(mr[0].object, "agent", a_id, "agent_send agents: fan-a's result");
        if (!mr[0].object.get("interrupted").?.bool) fail("agent_send agents: the busy fan-a was not interrupted");
        if (mr[1].object.get("interrupted").?.bool) fail("agent_send agents: the idle fan-b was interrupted");
        for (mr[0..2]) |r| expectSentOrWorking(r.object, "agent_send agents: outcome");
        expectFact(mr[2].object, "outcome", "failed", "agent_send agents: the unknown agent");
        expectFact(mr[2].object.get("error").?.object, "code", "not_found", "agent_send agents: the unknown agent's code");
        const all_cmd = scStr(many, "watch_command", "agent_send agents");
        if (std.mem.indexOf(u8, all_cmd, " --all ") == null or !std.mem.endsWith(u8, all_cmd, std.fmt.allocPrint(arena, " {s} {s}", .{ a_id, b_id }) catch fail("oom"))) {
            say(all_cmd);
            fail("agent_send agents: watch_command is not an --all waiter on the two sent");
        }
        var all_waiter = Waiter.start(all_cmd);
        const all_out = all_waiter.finish(arena, 20_000, "--all waiter");
        for ([_][]const u8{ a_id, b_id }) |id| {
            if (std.mem.indexOf(u8, untimed(arena, all_out), std.fmt.allocPrint(arena, "{s} done: echo: fan out", .{id}) catch fail("oom")) == null) {
                say(all_out);
                fail("the --all waiter did not report each agent's done");
            }
        }
        if (std.mem.indexOf(u8, all_out, "all 2 agent(s) settled") == null or std.mem.indexOf(u8, all_out, "glacial") != null or all_waiter.status != 0) {
            say(all_out);
            fail("the --all waiter: no header, the interrupted turn's answer, or a bad exit");
        }
        // The waiter marked no record: final returns the new answer.
        const fin2 = agentCall(&m, arena, "agent_read", "{\"agent\":\"fan-a\",\"final\":true}", "agent_read final after fan out", false, 15_000);
        const fin2_recs = fin2.get("records").?.array.items;
        if (fin2_recs.len != 1 or !std.mem.eql(u8, fin2_recs[0].object.get("text").?.string, "echo: fan out")) fail("agent_read final: not the answer to the prompt sent after the interrupt");
        // interrupt on one idle agent just sends.
        const solo = agentCall(&m, arena, "agent_send", "{\"agent\":\"fan-b\",\"text\":\"solo\",\"interrupt\":true,\"timeout_ms\":20000}", "agent_send interrupt idle", false, 45_000);
        expectFact(solo, "outcome", "done", "agent_send interrupt on an idle agent: outcome");
        if (solo.get("interrupted").?.bool) fail("agent_send interrupt: an idle agent was interrupted");

        // The compact list by default, every fact with detail.
        const compact = agentCall(&m, arena, "agent_list", "{}", "agent_list compact", false, 15_000);
        const ca = compact.get("agents").?.array.items;
        if (ca.len != 2 or compact.get("detail").?.bool) fail("agent_list: not the two agents, compact");
        expectFact(ca[0].object, "host", "local", "agent_list compact: host");
        if (ca[0].object.get("queued") == null or ca[0].object.get("idle_s") == null or ca[0].object.get("recordings") != null or ca[0].object.get("sessions") != null)
            fail("agent_list compact: wrong facts");
        const full = agentCall(&m, arena, "agent_list", "{\"detail\":true}", "agent_list detail", false, 15_000);
        if (full.get("agents").?.array.items[0].object.get("recordings") == null) fail("agent_list detail: no recordings");
        // Both in one call, by selector: every live agent here.
        const shut = agentCall(&m, arena, "agent_close", "{\"agents\":\"*\"}", "agent_close agents *", false, 15_000);
        if (shut.get("count").?.integer != 2 or shut.get("failed").?.integer != 0) fail("agent_close agents *: not both closed");
        for (shut.get("results").?.array.items) |r| if (r.object.get("sessions").?.array.items.len == 0) fail("agent_close agents *: a session was not killed");

        // term_open exec_shell: term_exec's shell unless a call names one.
        _ = agentCall(&m, arena, "term_open", "{\"exec_shell\":\"bash;x\"}", "term_open bad exec_shell", true, 15_000);
        const bt = agentCall(&m, arena, "term_open", "{\"exec_shell\":\"bash\"}", "term_open exec_shell", false, 30_000);
        expectFact(bt, "exec_shell", "bash", "term_open: exec_shell fact");
        const bt_id = bt.get("term").?.integer;
        const by_default = agentCall(&m, arena, "term_exec", std.fmt.allocPrint(arena, "{{\"term\":{d},\"command\":\"cat /proc/$$/comm\",\"timeout_ms\":20000}}", .{bt_id}) catch fail("oom"), "term_exec exec_shell", false, 45_000);
        if (std.mem.indexOf(u8, scStr(by_default, "output", "term_exec exec_shell"), "bash") == null) fail("term_exec: the terminal's exec_shell was not used");
        const named = agentCall(&m, arena, "term_exec", std.fmt.allocPrint(arena, "{{\"term\":{d},\"command\":\"cat /proc/$$/comm\",\"shell\":\"sh\",\"timeout_ms\":20000}}", .{bt_id}) catch fail("oom"), "term_exec shell sh", false, 45_000);
        if (std.mem.indexOf(u8, scStr(named, "output", "term_exec shell sh"), "bash") != null) fail("term_exec: a call's own shell did not win over exec_shell");
        const tl = agentCall(&m, arena, "term_list", "{}", "term_list exec_shell", false, 15_000);
        const tl_json = std.json.Stringify.valueAlloc(arena, std.json.Value{ .object = tl }, .{}) catch fail("oom");
        if (std.mem.indexOf(u8, tl_json, "\"exec_shell\":\"bash\"") == null) fail("term_list: no exec_shell");
        _ = agentCall(&m, arena, "term_close", std.fmt.allocPrint(arena, "{{\"term\":{d}}}", .{bt_id}) catch fail("oom"), "term_close exec_shell", false, 15_000);
        m.closeStdinWait();
        say("smoke-mcp: agents: one-call hand-off, send to several with interrupt, wait all (tool and --all), read final, compact list, term exec_shell ok");
    }

    // ── a gone agent is relaunched under its id, resuming its conversation ──
    {
        const user_sock = std.fmt.allocPrint(arena, "{s}/sketerm/mux.sock", .{rt}) catch fail("oom");
        var r1 = Mcp.spawn(allocator, exe, &.{});
        r1.initialize();
        resetStarts();
        const opened = agentCall(&r1, arena, "agent_open", std.fmt.allocPrint(arena, "{{\"app\":\"claude\",\"name\":\"phoenix\",\"binary\":{s},\"prompt\":\"before the reboot\",\"timeout_ms\":30000{s}}}", .{ bin_json, extraJson(arena) }) catch fail("oom"), "relaunch: agent_open", false, 45_000);
        expectFact(opened, "message", "echo: before the reboot", "relaunch: the first answer");
        const id = arena.dupe(u8, scStr(opened, "agent", "relaunch: agent_open")) catch fail("oom");
        const conv = arena.dupe(u8, scStr(opened, "conversation", "relaunch: agent_open")) catch fail("oom");
        const session = std.fmt.allocPrint(arena, "agent-{s}", .{id}) catch fail("oom");
        _ = c.kill(r1.pid, c.SIGKILL);
        _ = c.waitpid(r1.pid, null, 0);
        // The host goes down: the session ends without anyone closing the agent.
        {
            var conn = muxclient.Conn.connectProbed(allocator, user_sock) catch fail("relaunch: cannot reach the per-user daemon");
            defer conn.deinit();
            conn.sendKill(.{ .name = session }) catch fail("relaunch: kill");
        }
        waitUnlisted(allocator, user_sock, session, "relaunch: the session was not ended");
        var r2 = Mcp.spawn(allocator, exe, &.{});
        r2.initialize();
        const gone = agentCall(&r2, arena, "agent_attach", "{\"agent\":\"phoenix\"}", "relaunch: attach a gone agent", false, 30_000);
        expectFact(gone, "attach", "gone", "relaunch: without relaunch it is gone");
        if (!gone.get("relaunchable").?.bool) fail("relaunch: the gone agent is not relaunchable");
        resetStarts();
        const back = agentCall(&r2, arena, "agent_attach", "{\"agent\":\"phoenix\",\"relaunch\":true,\"timeout_ms\":30000}", "relaunch: agent_attach relaunch", false, 60_000);
        expectFact(back, "attach", "relaunched", "relaunch: outcome");
        expectFact(back, "agent", id, "relaunch: the same id");
        expectFact(back, "name", "phoenix", "relaunch: the same name");
        expectFact(back, "conversation", conv, "relaunch: the same conversation");
        // The same wrapper args and env, byte-exact.
        expectStarts(arena, "claude", 1, "relaunch");
        const recalled = agentCall(&r2, arena, "agent_send", "{\"agent\":\"phoenix\",\"text\":\"recall\",\"timeout_ms\":20000}", "relaunch: recall", false, 45_000);
        expectFact(recalled, "message", "first prompt was: before the reboot", "relaunch: the conversation was resumed");
        _ = agentCall(&r2, arena, "agent_close", "{\"agent\":\"phoenix\"}", "relaunch: agent_close", false, 15_000);
        var desc_buf: [512]u8 = undefined;
        const desc = std.fmt.bufPrintZ(&desc_buf, "{s}/sketerm/agents/{s}.json", .{ rt, id }) catch fail("path");
        var st: c.struct_stat = undefined;
        if (c.stat(desc.ptr, &st) == 0) fail("relaunch: agent_close left the descriptor in the index");
        r2.closeStdinWait();
        say("smoke-mcp: agents: a gone agent is relaunchable, relaunch keeps its id, name, wrapper and conversation ok");
    }

    // ── an agent outlives its server: another one resumes it by name ──
    {
        const user_sock = std.fmt.allocPrint(arena, "{s}/sketerm/mux.sock", .{rt}) catch fail("oom");
        var s1 = Mcp.spawn(allocator, exe, &.{});
        s1.initialize();
        const opened = agentCall(&s1, arena, "agent_open", std.fmt.allocPrint(arena, "{{\"app\":\"claude\",\"name\":\"probe\",\"binary\":{s},\"prompt\":\"before the restart\",\"timeout_ms\":30000}}", .{bin_json}) catch fail("oom"), "resume: agent_open", false, 45_000);
        expectFact(opened, "message", "echo: before the restart", "resume: agent_open prompt answer");
        const id = arena.dupe(u8, scStr(opened, "agent", "resume: agent_open")) catch fail("oom");
        const session = std.fmt.allocPrint(arena, "agent-{s}", .{id}) catch fail("oom");
        var desc_buf: [512]u8 = undefined;
        const desc = std.fmt.bufPrintZ(&desc_buf, "{s}/sketerm/agents/{s}.json", .{ rt, id }) catch fail("path");
        var st: c.struct_stat = undefined;
        if (c.stat(desc.ptr, &st) != 0 or (st.st_mode & 0o777) != 0o600) fail("resume: no 0600 descriptor in the per-user index");
        // The server goes away for good (not a clean exit): the agent runs on.
        _ = c.kill(s1.pid, c.SIGKILL);
        _ = c.waitpid(s1.pid, null, 0);
        if (!sessionListed(allocator, user_sock, session)) fail("resume: the agent did not outlive its server");

        var s2 = Mcp.spawn(allocator, exe, &.{});
        s2.initialize();
        if (agentCall(&s2, arena, "agent_list", "{}", "resume: agent_list", false, 15_000).get("count").?.integer != 0)
            fail("resume: an isolated server re-attached an agent on its own");
        const back = agentCall(&s2, arena, "agent_attach", "{\"agent\":\"probe\"}", "resume: agent_attach", false, 30_000);
        expectFact(back, "attach", "reattached", "resume: agent_attach outcome");
        expectFact(back, "agent", id, "resume: agent_attach id");
        const after = agentCall(&s2, arena, "agent_send", "{\"agent\":\"probe\",\"text\":\"after the restart\",\"timeout_ms\":20000}", "resume: agent_send", false, 45_000);
        expectFact(after, "message", "echo: after the restart", "resume: the resumed agent answers");

        // A third server: refused while s2 holds it, then takeover moves it.
        var s3 = Mcp.spawn(allocator, exe, &.{});
        s3.initialize();
        const held = agentCall(&s3, arena, "agent_attach", std.fmt.allocPrint(arena, "{{\"agent\":\"{s}\"}}", .{id}) catch fail("oom"), "resume: attach while held", true, 30_000);
        if (!std.mem.eql(u8, held.get("error").?.object.get("code").?.string, "conflict")) fail("resume: attach of an agent another live server holds is not conflict");
        const took = agentCall(&s3, arena, "agent_attach", "{\"agent\":\"probe\",\"takeover\":true}", "resume: takeover", false, 30_000);
        expectFact(took, "attach", "reattached", "resume: takeover outcome");
        _ = c.usleep(1_500_000);
        if (agentCall(&s2, arena, "agent_list", "{}", "resume: loser agent_list", false, 15_000).get("count").?.integer != 0)
            fail("resume: the server that was taken over still lists the agent");
        s2.closeStdinWait();

        // Closed: gone, with the daemon's reason.
        _ = agentCall(&s3, arena, "agent_close", "{\"agent\":\"probe\"}", "resume: agent_close", false, 15_000);
        if (c.stat(desc.ptr, &st) == 0) fail("resume: agent_close left the descriptor in the index");
        waitUnlisted(allocator, user_sock, session, "resume: agent_close");
        // Any server asking for it now: gone, with the daemon's reason.
        var s4 = Mcp.spawn(allocator, exe, &.{});
        s4.initialize();
        const gone = agentCall(&s4, arena, "agent_attach", "{\"agent\":\"probe\"}", "resume: attach a closed agent", false, 15_000);
        expectFact(gone, "attach", "gone", "resume: a closed agent is gone");
        expectFact(gone, "reason", "closed", "resume: the daemon remembers it was closed");
        s4.closeStdinWait();
        s3.closeStdinWait();
        say("smoke-mcp: agents: an agent outlives its server, agent_attach resumes it by name, refuses a held one, takeover moves it ok");
    }

    // ── a durable instance picks its agents up again ─────────────────
    {
        var d1 = Mcp.spawn(allocator, exe, &.{ "--name", "agentdur" });
        d1.initialize();
        const opened = agentCall(&d1, arena, "agent_open", std.fmt.allocPrint(arena, "{{\"app\":\"claude\",\"name\":\"claude-1\",\"binary\":{s},\"prompt\":\"before restart\",\"timeout_ms\":30000{s}}}", .{ bin_json, extraJson(arena) }) catch fail("oom"), "durable agent_open", false, 45_000);
        expectFact(opened, "outcome", "done", "durable agent_open: prompt outcome");
        expectFact(opened, "message", "echo: before restart", "durable agent_open: prompt answer");
        d1.closeStdinWait();
        var desc_buf: [512]u8 = undefined;
        const desc = std.fmt.bufPrintZ(&desc_buf, "{s}/sketerm/agents/{s}.json", .{ rt, scStr(opened, "agent", "durable agent_open") }) catch fail("path");
        var st: c.struct_stat = undefined;
        if (c.stat(desc.ptr, &st) != 0) fail("durable: no agent descriptor in the per-user index");
        if ((st.st_mode & 0o777) != 0o600) fail("durable: the agent descriptor is not 0600");

        var d2 = Mcp.spawn(allocator, exe, &.{ "--name", "agentdur" });
        d2.initialize();
        const listed = agentCall(&d2, arena, "agent_list", "{}", "durable agent_list", false, 15_000);
        if (listed.get("count").?.integer != 1) fail("durable: the restarted server did not pick its agent up");
        const back = agentCall(&d2, arena, "agent_send", "{\"agent\":\"claude-1\",\"text\":\"after restart\",\"timeout_ms\":20000}", "durable agent_send", false, 45_000);
        expectFact(back, "outcome", "done", "durable agent_send: outcome");
        expectFact(back, "message", "echo: after restart", "durable agent_send: message");
        // The descriptor kept the wrapper's args and env: a relaunch after
        // the reattach still uses them.
        resetStarts();
        const relaunched = agentCall(&d2, arena, "agent_set", "{\"agent\":\"claude-1\",\"effort\":\"low\",\"timeout_ms\":30000}", "durable agent_set effort", false, 60_000);
        if (!relaunched.get("relaunched").?.bool) fail("durable agent_set effort: not a relaunch");
        expectStarts(arena, "claude", 1, "durable relaunch after reattach");
        _ = agentCall(&d2, arena, "agent_close", "{\"agent\":\"claude-1\"}", "durable agent_close", false, 15_000);
        if (c.stat(desc.ptr, &st) == 0) fail("durable: agent_close left the descriptor behind");
        d2.closeStdinWait();
        say("smoke-mcp: agents: a durable instance re-attaches its running agent ok");
    }

    // ── an opencode agent without its TUI re-attaches, and its TUI setting
    // (agent_set tui) survives the next re-attach ──
    {
        const mux_sock = std.fmt.allocPrint(arena, "{s}/sketerm/mux.sock", .{rt}) catch fail("oom");
        var d1 = Mcp.spawn(allocator, exe, &.{ "--name", "ocdur" });
        d1.initialize();
        const opened = agentCall(&d1, arena, "agent_open", std.fmt.allocPrint(arena, "{{\"app\":\"opencode\",\"name\":\"oc-dur\",\"binary\":{s},\"prompt\":\"before restart\",\"timeout_ms\":30000}}", .{bin_json}) catch fail("oom"), "durable opencode agent_open", false, 45_000);
        const server = arena.dupe(u8, scStr(opened, "server_session", "durable opencode agent_open")) catch fail("oom");
        const tui_session = std.fmt.allocPrint(arena, "agent-{s}", .{scStr(opened, "agent", "durable opencode agent_open")}) catch fail("oom");
        expectFact(opened, "session", server, "durable opencode: no TUI, the server's session");
        d1.closeStdinWait();
        var d2 = Mcp.spawn(allocator, exe, &.{ "--name", "ocdur" });
        d2.initialize();
        const back = agentCall(&d2, arena, "agent_send", "{\"agent\":\"oc-dur\",\"text\":\"after restart\",\"timeout_ms\":20000}", "durable opencode agent_send", false, 45_000);
        expectFact(back, "message", "echo: after restart model=default variant=default", "durable opencode: the re-attached agent answers");
        expectFact(back, "session", server, "durable opencode: re-attached without a TUI");
        if (back.get("tui").?.bool) fail("durable opencode: a TUI appeared on re-attach");
        const on = agentCall(&d2, arena, "agent_set", "{\"agent\":\"oc-dur\",\"tui\":true}", "durable opencode agent_set tui", false, 30_000);
        expectFact(on, "session", tui_session, "durable opencode: agent_set tui started it");
        d2.closeStdinWait();
        var d3 = Mcp.spawn(allocator, exe, &.{ "--name", "ocdur" });
        d3.initialize();
        const again = agentCall(&d3, arena, "agent_list", "{\"detail\":true}", "durable opencode agent_list", false, 15_000).get("agents").?.array.items;
        if (again.len != 1 or !std.mem.eql(u8, again[0].object.get("session").?.string, tui_session)) fail("durable opencode: the TUI was not re-attached");
        const closed = agentCall(&d3, arena, "agent_close", "{\"agent\":\"oc-dur\"}", "durable opencode agent_close", false, 15_000);
        if (closed.get("sessions").?.array.items.len != 2) fail("durable opencode agent_close: not the TUI and the server");
        waitUnlisted(allocator, mux_sock, tui_session, "durable opencode agent_close TUI");
        waitUnlisted(allocator, mux_sock, server, "durable opencode agent_close server");
        d3.closeStdinWait();
        say("smoke-mcp: agents: an opencode agent without its TUI re-attaches; agent_set tui survives the next ok");
    }

    // ── a permission policy per app, and retry on overload ───────────
    {
        var m = Mcp.spawn(allocator, exe, &.{});
        m.initialize();
        const caps = agentCall(&m, arena, "capabilities", "{}", "capabilities permissions", false, 15_000);
        if (!caps.get("agent_permissions").?.bool) fail("capabilities: agent_permissions is false");
        if (!caps.get("agent_gone_on_reconnect").?.bool) fail("capabilities: agent_gone_on_reconnect is false");
        const rc = caps.get("agent_retry_on_overload").?.object;
        if (!rc.get("available").?.bool or rc.get("classes").?.array.items.len != 1 or !std.mem.eql(u8, rc.get("classes").?.array.items[0].string, "overloaded"))
            fail("capabilities: agent_retry_on_overload does not name the overloaded class");

        // A name the app does not take is refused, naming the ones it does.
        const bad = agentCall(&m, arena, "agent_open", std.fmt.allocPrint(arena, "{{\"app\":\"opencode\",\"binary\":{s},\"permissions\":{{\"Bash\":\"allow\"}}}}", .{bin_json}) catch fail("oom"), "agent_open unknown permission", true, 15_000);
        const bad_msg = bad.get("error").?.object.get("message").?.string;
        if (std.mem.indexOf(u8, bad_msg, "external_directory") == null) {
            say(bad_msg);
            fail("agent_open permissions: the refusal does not name what opencode takes");
        }
        // Claude Code's own --settings in args is never overwritten.
        _ = agentCall(&m, arena, "agent_open", std.fmt.allocPrint(arena, "{{\"app\":\"claude\",\"binary\":{s},\"args\":[\"--settings\",\"{{}}\"],\"permissions\":{{\"Edit\":\"deny\"}}}}", .{bin_json}) catch fail("oom"), "agent_open clobbered settings", true, 15_000);

        // Claude Code: --settings permissions lists on its argv.
        resetStarts();
        const cl = agentCall(&m, arena, "agent_open", std.fmt.allocPrint(arena, "{{\"app\":\"claude\",\"name\":\"perm-claude\",\"binary\":{s},\"permissions\":{{\"Bash(git *)\":\"allow\",\"Edit\":\"deny\"}},\"timeout_ms\":30000}}", .{bin_json}) catch fail("oom"), "agent_open claude permissions", false, 45_000);
        if (!std.mem.eql(u8, cl.get("permissions").?.object.get("Edit").?.string, "deny")) fail("agent_open claude: no permissions fact");
        {
            var buf: [1024]u8 = undefined;
            const starts = readfile.cappedAlloc(arena, fcPath(&buf, FC_STARTS), 1 << 20) catch fail("no starts recorded");
            // ONE settings document: the policy and the facts' status command.
            if (std.mem.indexOf(u8, starts, "\x00--settings\x00{\"permissions\":{\"allow\":[\"Bash(git *)\"],\"deny\":[\"Edit\"]},\"statusLine\":{\"type\":\"command\",\"command\":\"/bin/sh -c ") == null or
                std.mem.count(u8, starts, "\x00--settings\x00") != 1)
            {
                say(starts);
                fail("agent_open claude permissions: --settings did not reach Claude Code's argv");
            }
        }
        _ = agentCall(&m, arena, "agent_close", "{\"agent\":\"perm-claude\"}", "agent_close perm-claude", false, 15_000);

        // opencode: merged into the caller's own config document.
        const oc = agentCall(&m, arena, "agent_open", std.fmt.allocPrint(arena, "{{\"app\":\"opencode\",\"name\":\"retry-oc\",\"binary\":{s},\"env\":{{\"OPENCODE_CONFIG_CONTENT\":\"{{\\\"model\\\":\\\"fakeprov/m1\\\"}}\"}},\"permissions\":{{\"external_directory\":\"allow\",\"bash\":\"ask\"}},\"retry_on_overload\":{{\"max\":2,\"backoff_s\":1}},\"timeout_ms\":30000}}", .{bin_json}) catch fail("oom"), "agent_open opencode permissions", false, 45_000);
        if (!std.mem.eql(u8, oc.get("permissions").?.object.get("external_directory").?.string, "allow")) fail("agent_open opencode: no permissions fact");
        if (oc.get("retry_on_overload").?.object.get("max").?.integer != 2) fail("agent_open opencode: no retry_on_overload fact");
        {
            var buf: [1024]u8 = undefined;
            const cfg = readfile.cappedAlloc(arena, fcPath(&buf, FAKE_OC_CONFIG), 1 << 20) catch fail("no opencode config recorded");
            const want = "{\"model\":\"fakeprov/m1\",\"permission\":{\"external_directory\":\"allow\",\"bash\":\"ask\"}}\n";
            if (!std.mem.endsWith(u8, cfg, want)) {
                say(cfg);
                fail("agent_open opencode permissions: the server's OPENCODE_CONFIG_CONTENT is not the caller's document with the policy merged in");
            }
        }
        // One overload: retried after 1 s, the turn goes on, and the
        // error reads as a notice, never a wake.
        const once = agentCall(&m, arena, "agent_send", "{\"agent\":\"retry-oc\",\"text\":\"overload 1\",\"timeout_ms\":30000}", "agent_send overload once", false, 45_000);
        expectFact(once, "outcome", "done", "retry on overload: the retried turn's done");
        expectFact(once, "message", "echo: continue model=default variant=default", "retry on overload: the continue prompt's answer");
        if (eventKinds(once, "error") != 0) fail("retry on overload: a retried overload woke the caller");
        {
            const all = agentCall(&m, arena, "agent_read", "{\"agent\":\"retry-oc\",\"detail\":\"all\",\"since\":0}", "agent_read retry notices", false, 15_000);
            const json = std.json.Stringify.valueAlloc(arena, all.get("records").?, .{}) catch fail("oom");
            if (std.mem.indexOf(u8, json, "retry 1 of 2") == null or std.mem.indexOf(u8, json, "went on after 1 retry") == null) {
                say(json);
                fail("retry on overload: no notice records of the retry");
            }
        }
        // More overloads than retries: it gives up and every error wakes.
        const many = agentCall(&m, arena, "agent_send", "{\"agent\":\"retry-oc\",\"text\":\"overload 5\",\"timeout_ms\":30000}", "agent_send overload many", false, 45_000);
        expectFact(many, "outcome", "error", "retry on overload: giving up wakes with the error");
        if (eventKinds(many, "error") != 3) fail("retry on overload: not the first error and both retries' errors");
        // agent_set turns it off.
        const off = agentCall(&m, arena, "agent_set", "{\"agent\":\"retry-oc\",\"retry_on_overload\":null}", "agent_set retry off", false, 15_000);
        if (off.get("retry_on_overload") != null) fail("agent_set retry_on_overload null: still on");
        _ = agentCall(&m, arena, "agent_close", "{\"agent\":\"retry-oc\"}", "agent_close retry-oc", false, 15_000);
        m.closeStdinWait();
        say("smoke-mcp: agents: permissions (claude --settings, opencode config merged, refusals) and retry on overload (recovered, gave up, off) ok");
    }

    // ── brief templates ───────────────────────────────────────────────
    {
        var m = Mcp.spawn(allocator, exe, &.{});
        m.initialize();
        const caps = agentCall(&m, arena, "capabilities", "{}", "capabilities templates", false, 15_000);
        if (!caps.get("agent_templates").?.bool) fail("capabilities: agent_templates is false");

        // Refusals: a name is refused, never cleaned up; a lone brace is
        // refused with what is wrong.
        _ = agentCall(&m, arena, "agent_template_save", "{\"name\":\"a b\",\"text\":\"x\"}", "template bad name", true, 15_000);
        _ = agentCall(&m, arena, "agent_template_save", "{\"name\":\"t\",\"text\":\"json {\\\"a\\\":1}\"}", "template lone brace", true, 15_000);

        const saved = agentCall(&m, arena, "agent_template_save", "{\"name\":\"smoke-brief\",\"description\":\"smoke brief\",\"text\":\"" ++ BRIEF_MARK ++ "for {target}: {task} {{literal}}\",\"vars\":{\"target\":\"the repo\"}}", "template save", false, 15_000);
        if (saved.get("vars").?.array.items.len != 2 or saved.get("replaced").?.bool) fail("template save: wrong facts");
        const listed = agentCall(&m, arena, "agent_templates", "{}", "templates list", false, 15_000);
        if (listed.get("count").?.integer != 1) fail("agent_templates: not one template");
        const item = listed.get("templates").?.array.items[0].object;
        if (!std.mem.eql(u8, item.get("name").?.string, "smoke-brief") or item.get("vars").?.array.items.len != 2) fail("agent_templates: wrong item");
        const shown = agentCall(&m, arena, "agent_templates", "{\"name\":\"smoke-brief\"}", "templates show", false, 15_000);
        expectFact(shown, "text", BRIEF_MARK ++ "for {target}: {task} {{literal}}", "agent_templates name: text");
        const sv = shown.get("vars").?.object;
        if (!std.mem.eql(u8, sv.get("target").?.string, "the repo") or sv.get("task").? != .null) fail("agent_templates name: vars and defaults differ");

        // Claude Code: refusals by name, then a rendered brief.
        _ = agentCall(&m, arena, "agent_open", std.fmt.allocPrint(arena, "{{\"app\":\"claude\",\"name\":\"brief-claude\",\"binary\":{s},\"timeout_ms\":30000}}", .{bin_json}) catch fail("oom"), "agent_open brief-claude", false, 45_000);
        const missing = agentCall(&m, arena, "agent_send", "{\"agent\":\"brief-claude\",\"template\":\"smoke-brief\"}", "template missing var", true, 15_000);
        if (std.mem.indexOf(u8, missing.get("error").?.object.get("message").?.string, "'task'") == null) fail("template send: the refusal does not name the missing variable");
        const unknown = agentCall(&m, arena, "agent_send", "{\"agent\":\"brief-claude\",\"template\":\"smoke-brief\",\"vars\":{\"task\":\"x\",\"bogus\":\"y\"}}", "template unknown var", true, 15_000);
        if (std.mem.indexOf(u8, unknown.get("error").?.object.get("message").?.string, "'bogus'") == null) fail("template send: the refusal does not name the unknown variable");
        _ = agentCall(&m, arena, "agent_send", "{\"agent\":\"brief-claude\",\"template\":\"no-such\",\"vars\":{\"task\":\"x\"}}", "template not found", true, 15_000);
        _ = agentCall(&m, arena, "agent_send", "{\"agent\":\"brief-claude\",\"vars\":{\"task\":\"x\"}}", "vars without template", true, 15_000);

        const good = agentCall(&m, arena, "agent_send", "{\"agent\":\"brief-claude\",\"template\":\"smoke-brief\",\"vars\":{\"task\":\"fix-it\"},\"timeout_ms\":20000}", "claude brief", false, 45_000);
        expectBrief(arena, good, "brief: for the repo: fix-it {literal}", "claude brief");
        const plain = agentCall(&m, arena, "agent_send", "{\"agent\":\"brief-claude\",\"text\":\"hello again\",\"timeout_ms\":20000}", "claude plain after brief", false, 45_000);
        expectFact(plain, "outcome", "done", "claude plain after brief: outcome");
        if (plain.get("template") != null) fail("a plain prompt after a templated one names a template");
        _ = agentCall(&m, arena, "agent_close", "{\"agent\":\"brief-claude\"}", "agent_close brief-claude", false, 15_000);

        // opencode: the template on agent_open's prompt, a default overridden.
        const oc = agentCall(&m, arena, "agent_open", std.fmt.allocPrint(arena, "{{\"app\":\"opencode\",\"name\":\"brief-oc\",\"binary\":{s},\"template\":\"smoke-brief\",\"vars\":{{\"task\":\"ship-it\",\"target\":\"the docs\"}},\"timeout_ms\":30000}}", .{bin_json}) catch fail("oom"), "opencode brief", false, 45_000);
        expectBrief(arena, oc, "brief: for the docs: ship-it {literal}", "opencode brief");
        _ = agentCall(&m, arena, "agent_close", "{\"agent\":\"brief-oc\"}", "agent_close brief-oc", false, 15_000);

        const del = agentCall(&m, arena, "agent_template_delete", "{\"name\":\"smoke-brief\"}", "template delete", false, 15_000);
        if (!del.get("deleted").?.bool) fail("agent_template_delete: not deleted");
        _ = agentCall(&m, arena, "agent_template_delete", "{\"name\":\"smoke-brief\"}", "template delete again", true, 15_000);
        if (agentCall(&m, arena, "agent_templates", "{}", "templates after delete", false, 15_000).get("count").?.integer != 0) fail("agent_templates: the deleted template is still listed");
        m.closeStdinWait();
        say("smoke-mcp: agents: brief templates (save, list, show, delete, refusals; claude and opencode) ok");
    }
}

/// A done result of a templated prompt: the agent's answer to the rendered
/// brief, the template fact, and never the rendered prompt itself.
fn expectBrief(arena: std.mem.Allocator, o: std.json.ObjectMap, answer: []const u8, comptime what: []const u8) void {
    expectFact(o, "outcome", "done", what ++ ": outcome");
    const all = std.json.Stringify.valueAlloc(arena, std.json.Value{ .object = o }, .{}) catch fail("oom");
    if (std.mem.indexOf(u8, all, BRIEF_MARK) != null) {
        say(all);
        fail(what ++ ": the rendered prompt was echoed");
    }
    expectFact(o, "message", answer, what ++ ": message");
    expectFact(o, "template", "smoke-brief", what ++ ": template");
}

// ── sub-agents on an SSH host: both transports, a faked remote ──────

/// Read `/proc/<pid>/<file>` into `out` (bounded); "" when unreadable.
fn procRead(pid: []const u8, file: []const u8, out: []u8) []const u8 {
    var path_buf: [128]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/proc/{s}/{s}", .{ pid, file }) catch return "";
    const f = c.fopen(path.ptr, "rb") orelse return "";
    defer _ = c.fclose(f);
    return out[0..c.fread(out.ptr, 1, out.len, f)];
}

/// The pids whose argv contains every one of `needles` and whose
/// environment carries `env_needle` (this run's isolated dirs).
fn findProcs(needles: []const []const u8, env_needle: []const u8, out: []c.pid_t) []c.pid_t {
    var n: usize = 0;
    const d = c.opendir("/proc") orelse return out[0..0];
    defer _ = c.closedir(d);
    while (c.readdir(d)) |ent| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
        if (name.len == 0 or name[0] < '0' or name[0] > '9') continue;
        var cbuf: [16384]u8 = undefined;
        const cmd = procRead(name, "cmdline", &cbuf);
        var ok = cmd.len > 0;
        for (needles) |x| {
            if (std.mem.indexOf(u8, cmd, x) == null) ok = false;
        }
        if (!ok) continue;
        var ebuf: [65536]u8 = undefined;
        if (std.mem.indexOf(u8, procRead(name, "environ", &ebuf), env_needle) == null) continue;
        if (n == out.len) break;
        out[n] = std.fmt.parseInt(c.pid_t, name, 10) catch continue;
        n += 1;
    }
    return out[0..n];
}

/// Fail when any process this user can see carries `secret` on its argv.
fn expectNoArgvCarries(secret: []const u8, comptime what: []const u8) void {
    const d = c.opendir("/proc") orelse fail("cannot list /proc");
    defer _ = c.closedir(d);
    var seen: usize = 0;
    while (c.readdir(d)) |ent| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
        if (name.len == 0 or name[0] < '0' or name[0] > '9') continue;
        var cbuf: [65536]u8 = undefined;
        const cmd = procRead(name, "cmdline", &cbuf);
        if (cmd.len == 0) continue;
        seen += 1;
        if (std.mem.indexOf(u8, cmd, secret) != null) {
            say(name);
            fail(what ++ ": a password is on a process argv");
        }
    }
    if (seen < 5) fail(what ++ ": too few readable argvs to conclude anything");
}

/// The passwords the fake opencode servers of this run were started with.
fn fakeOcPasswords(arena: std.mem.Allocator) []const []const u8 {
    var pb: [1024]u8 = undefined;
    const all = readfile.cappedAlloc(arena, fcPath(&pb, FAKE_OC_PASSWORDS), 1 << 16) catch return &.{};
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, all, "\n"), '\n');
    while (it.next()) |l| if (l.len > 0) list.append(arena, l) catch {};
    return list.items;
}

/// No argv and no recording of the run carries a fake server's password.
fn expectPasswordsHidden(arena: std.mem.Allocator, casts: []const std.json.Value, comptime what: []const u8) void {
    const pws = fakeOcPasswords(arena);
    if (pws.len == 0) fail(what ++ ": no fake opencode server recorded its password");
    for (pws) |pw| {
        if (pw.len < 16) fail(what ++ ": an implausible password");
        expectNoArgvCarries(pw, what);
        for (casts) |p| {
            const bytes = readfile.cappedAlloc(arena, p.string, 16 << 20) catch continue;
            if (std.mem.indexOf(u8, bytes, pw) != null) fail(what ++ ": a recording carries the password");
        }
    }
}

/// Run `argv` with stdout+stderr captured, bounded; the exit status in `status`.
fn runCapture(argv: []const ?[*:0]const u8, buf: []u8, status: *c_int, timeout_ms: i64) []const u8 {
    var pipe: [2]c_int = undefined;
    if (c.pipe(&pipe) != 0) fail("capture pipe");
    const pid = c.fork();
    if (pid < 0) fail("capture fork");
    if (pid == 0) {
        _ = c.dup2(pipe[1], 1);
        _ = c.dup2(pipe[1], 2);
        _ = c.close(pipe[0]);
        _ = c.close(pipe[1]);
        _ = c.execv(argv[0].?, @ptrCast(argv.ptr));
        c._exit(127);
    }
    _ = c.close(pipe[1]);
    defer _ = c.close(pipe[0]);
    var used: usize = 0;
    const deadline = nowMs() + timeout_ms;
    while (used < buf.len) {
        var pfd = c.struct_pollfd{ .fd = pipe[0], .events = c.POLLIN, .revents = 0 };
        if (c.poll(&pfd, 1, 200) > 0) {
            const n = c.read(pipe[0], buf[used..].ptr, buf.len - used);
            if (n <= 0) break;
            used += @intCast(n);
        }
        if (nowMs() >= deadline) {
            _ = c.kill(pid, c.SIGKILL);
            _ = c.waitpid(pid, null, 0);
            fail("a captured command timed out");
        }
    }
    _ = c.waitpid(pid, status, 0);
    return buf[0..used];
}

/// Start a per-user daemon for one fake host (its own runtime dir).
fn startHostDaemon(rt_host: [:0]const u8) c.pid_t {
    const pid = c.fork();
    if (pid < 0) fail("fork host daemon");
    if (pid == 0) {
        _ = c.setenv("XDG_RUNTIME_DIR", rt_host.ptr, 1);
        _ = c.setenv("XDG_STATE_HOME", rt_host.ptr, 1);
        _ = c.setenv("XDG_CONFIG_HOME", rt_host.ptr, 1);
        const argv = [_:null]?[*:0]const u8{ "sketerm-mux", "--broker", null };
        _ = c.execv("zig-out/bin/sketerm-mux", @ptrCast(@constCast(&argv)));
        c._exit(127);
    }
    var sock_buf: [512]u8 = undefined;
    const sock = std.fmt.bufPrint(&sock_buf, "{s}/sketerm/mux.sock", .{rt_host}) catch fail("oom");
    const deadline = nowMs() + 10_000;
    while (!fileExists(sock)) {
        if (nowMs() > deadline) fail("a fake host's daemon socket never appeared");
        _ = c.usleep(50_000);
    }
    return pid;
}

/// A session of `conn`'s daemon: present, with its lifetime id.
fn listedOrigin(allocator: std.mem.Allocator, conn: *muxclient.Conn, name: []const u8) ?wire.SessionOriginId {
    conn.sendFrame(.list, "") catch fail("route list send");
    const frame = conn.recvExpectFor(&.{.welcome}, 10_000) catch fail("route list reply");
    defer frame.deinit(allocator);
    const Listing = struct { sessions: []const struct { name: []const u8 = "", origin_id: []const u8 = "" } = &.{} };
    const parsed = std.json.parseFromSlice(Listing, allocator, frame.payload, .{ .ignore_unknown_fields = true }) catch fail("route list parse");
    defer parsed.deinit();
    for (parsed.value.sessions) |s| {
        if (!std.mem.eql(u8, s.name, name)) continue;
        if (!wire.validSessionOriginId(s.origin_id)) return null;
        var id: wire.SessionOriginId = undefined;
        @memcpy(&id, s.origin_id);
        return id;
    }
    return null;
}

/// Watch an agent along `route` the way a viewer does: list it there,
/// attach, read the fake Claude Code's screen, type a prompt and see its
/// answer, detach (never kill: the agent belongs to its MCP server).
fn watchAlong(allocator: std.mem.Allocator, route: []const u8, session: []const u8, prompt: []const u8, comptime what: []const u8) void {
    var conn = muxclient.Conn.connectRemote(allocator, route, .{}) catch {
        say(muxclient.routeFailure());
        fail(what ++ ": the route did not connect");
    };
    const origin = listedOrigin(allocator, &conn, session) orelse {
        conn.deinit();
        fail(what ++ ": the agent's session is not listed along the route");
    };
    conn.setNonBlocking();
    const term = termdrive.Term.attachConn(allocator, &conn, session, origin) catch fail(what ++ ": attach along the route failed");
    defer term.detach();
    const deadline = nowMs() + 15_000;
    var typed = false;
    var answer_buf: [128]u8 = undefined;
    const answer = std.fmt.bufPrint(&answer_buf, "echo: {s}", .{prompt}) catch fail("oom");
    while (true) {
        const text = term.readScreen(false) catch fail(what ++ ": the attached screen is unreadable");
        defer allocator.free(text);
        if (!typed and std.mem.indexOf(u8, text, "Claude Code v0.0.0") != null) {
            var line_buf: [128]u8 = undefined;
            term.sendText(std.fmt.bufPrint(&line_buf, "{s}\r", .{prompt}) catch fail("oom")) catch fail(what ++ ": input along the route failed");
            typed = true;
        }
        if (typed and std.mem.indexOf(u8, text, answer) != null) return;
        if (nowMs() > deadline) {
            say(text);
            if (typed) fail(what ++ ": the typed prompt never reached the agent");
            fail(what ++ ": the agent's screen never showed");
        }
        _ = c.usleep(100_000);
    }
}

/// Expect `route` to fail fast with `want` in the client's sentence.
fn expectRouteRefused(allocator: std.mem.Allocator, route: []const u8, want_err: anyerror, want: []const u8, comptime what: []const u8) void {
    const started = nowMs();
    if (muxclient.Conn.connectRemote(allocator, route, .{})) |conn| {
        var cc = conn;
        cc.deinit();
        fail(what ++ ": the route connected");
    } else |err| {
        const took = nowMs() - started;
        const why = muxclient.routeFailure();
        if (err != want_err or std.mem.indexOf(u8, why, want) == null) {
            say(@errorName(err));
            say(why);
            fail(what ++ ": the wrong failure");
        }
        if (took > 10_000) fail(what ++ ": the failure was not prompt");
        var line_buf: [512]u8 = undefined;
        say(std.fmt.bufPrint(&line_buf, "smoke-mcp: route {s} refused in {d}ms: {s}", .{ route, took, why }) catch "smoke-mcp: route refused");
    }
}

/// Routes and the assistants report, across fake hosts: `$SKETERM_SSH` is
/// a script that runs each "host" here under its OWN runtime dir (hosta,
/// hostb, oldhost whose sketerm-mux predates routes). A real `sketerm mcp`
/// runs on hosta with one sub-agent there and one on hostb's daemon; from
/// this side hosta's daemon reports both, and routes derived by
/// `sshroute.watchSpec` list, attach and type into each.
fn routeStage(allocator: std.mem.Allocator, exe: [*:0]const u8, rt: []const u8) void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var self_buf: [4096]u8 = undefined;
    const self_exe = platform.exePath(&self_buf) orelse fail("route stage: own executable path");
    var mux_abs_buf: [4096]u8 = undefined;
    const mux_abs = std.mem.span(@as([*:0]const u8, @ptrCast(c.realpath("zig-out/bin/sketerm-mux", &mux_abs_buf) orelse fail("zig-out/bin/sketerm-mux missing"))));

    // The sub-agent binaries live where an ssh login's PATH does not look.
    const home = std.mem.span(@as([*:0]const u8, @ptrCast(c.getenv("HOME") orelse fail("no HOME"))));
    const local_bin = std.fmt.allocPrintSentinel(arena, "{s}/.local/bin", .{home}, 0) catch fail("oom");
    _ = c.system((std.fmt.allocPrintSentinel(arena, "mkdir -p '{s}'", .{local_bin}, 0) catch fail("oom")).ptr);
    {
        const link = std.fmt.allocPrintSentinel(arena, "{s}/claude", .{local_bin}, 0) catch fail("oom");
        _ = c.unlink(link.ptr);
        if (c.symlink((arena.dupeZ(u8, self_exe) catch fail("oom")).ptr, link.ptr) != 0) fail("route stage: fake claude link");
    }
    const fakebin = std.fmt.allocPrintSentinel(arena, "{s}/fakebin", .{rt}, 0) catch fail("oom");
    _ = c.mkdir(fakebin.ptr, 0o700);
    {
        const link = std.fmt.allocPrintSentinel(arena, "{s}/ssh", .{fakebin}, 0) catch fail("oom");
        _ = c.unlink(link.ptr);
        if (c.symlink((arena.dupeZ(u8, self_exe) catch fail("oom")).ptr, link.ptr) != 0) fail("route stage: fake ssh link");
    }

    // Three hosts, each its own runtime dir; `sketerm-mux` on each one's
    // PATH is this build, except on oldhost, where it predates routes.
    const hosts = [_][]const u8{ "a", "b", "o" };
    var host_rt: [3][:0]const u8 = undefined;
    for (hosts, 0..) |h, i| {
        host_rt[i] = std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ rt, h }, 0) catch fail("oom");
        _ = c.mkdir(host_rt[i].ptr, 0o700);
        const bin = std.fmt.allocPrintSentinel(arena, "{s}/bin", .{host_rt[i]}, 0) catch fail("oom");
        _ = c.mkdir(bin.ptr, 0o700);
        const mux = std.fmt.allocPrintSentinel(arena, "{s}/sketerm-mux", .{bin}, 0) catch fail("oom");
        _ = c.unlink(mux.ptr);
        if (i < 2) {
            if (c.symlink((arena.dupeZ(u8, mux_abs) catch fail("oom")).ptr, mux.ptr) != 0) fail("route stage: mux link");
        } else {
            // What every sketerm-mux before routes does with a flag it
            // does not know: name it on stderr and exit 2.
            const body = std.fmt.allocPrint(arena,
                \\#!/bin/sh
                \\[ "$1" = "--proxy" ] && exec '{s}' --proxy
                \\echo "sketerm-mux: unknown argument: $1" >&2
                \\exit 2
                \\
            , .{mux_abs}) catch fail("oom");
            writeExecutable(mux, body);
        }
    }
    const ssh_script = std.fmt.allocPrintSentinel(arena, "{s}/route-ssh", .{rt}, 0) catch fail("oom");
    {
        const body = std.fmt.allocPrint(arena,
            \\#!/bin/sh
            \\if [ "$1" = "-G" ]; then printf 'hostname 127.0.0.1\n'; exit 0; fi
            \\while [ $# -gt 0 ]; do
            \\  case "$1" in
            \\    -o|-L|-R|-D|-i|-p|-F|-J|-l) shift 2 ;;
            \\    -*) shift ;;
            \\    *) break ;;
            \\  esac
            \\done
            \\host="$1"; shift
            \\case "$host" in
            \\  hosta) h='{s}' ;;
            \\  hostb) h='{s}' ;;
            \\  oldhost) h='{s}' ;;
            \\  *) echo "ssh: Could not resolve hostname $host: Name or service not known" >&2; exit 255 ;;
            \\esac
            \\export XDG_RUNTIME_DIR="$h" XDG_STATE_HOME="$h" XDG_CONFIG_HOME="$h" PATH="$h/bin:$PATH"
            \\exec /bin/sh -c "$*"
            \\
        , .{ host_rt[0], host_rt[1], host_rt[2] }) catch fail("oom");
        writeExecutable(ssh_script, body);
    }

    const old_path: []const u8 = if (c.getenv("PATH")) |p| std.mem.span(@as([*:0]const u8, @ptrCast(p))) else "/usr/bin:/bin";
    const saved_path = arena.dupeZ(u8, old_path) catch fail("oom");
    const saved_rt = arena.dupeZ(u8, std.mem.span(@as([*:0]const u8, @ptrCast(c.getenv("XDG_RUNTIME_DIR").?)))) catch fail("oom");
    _ = c.setenv("PATH", (std.fmt.allocPrintSentinel(arena, "{s}:/usr/bin:/bin", .{fakebin}, 0) catch fail("oom")).ptr, 1);
    _ = c.setenv(FAKE_SSH_ENV, "1", 1);
    _ = c.setenv(FAKE_AGENT_ENV, "1", 1);
    _ = c.setenv("SKETERM_SSH", ssh_script.ptr, 1);
    defer {
        _ = c.setenv("PATH", saved_path.ptr, 1);
        _ = c.setenv("XDG_RUNTIME_DIR", saved_rt.ptr, 1);
        _ = c.setenv(FAKE_SSH_ENV, "1", 1);
        _ = c.unsetenv(FAKE_AGENT_ENV);
        _ = c.unsetenv("SKETERM_SSH");
    }
    // The per-user daemons of hosta and hostb, started here so their pids are ours.
    const pid_a = startHostDaemon(host_rt[0]);
    const pid_b = startHostDaemon(host_rt[1]);
    defer for ([_]c.pid_t{ pid_a, pid_b }) |p| {
        _ = c.kill(p, c.SIGTERM);
        _ = c.waitpid(p, null, 0);
    };

    // ── hosta runs `sketerm mcp` with an agent there and one on hostb ──
    _ = c.setenv("XDG_RUNTIME_DIR", host_rt[0].ptr, 1);
    var m = Mcp.spawn(allocator, exe, &.{});
    // A durable instance that has exited: its directory stays, no live server.
    var dead = Mcp.spawn(allocator, exe, &.{ "--name", "deadone" });
    _ = c.setenv("XDG_RUNTIME_DIR", saved_rt.ptr, 1);
    dead.initialize();
    dead.closeStdinWait();
    m.initialize();
    const bin_json = std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(self_exe, .{})}) catch fail("oom");
    const local = agentCall(&m, arena, "agent_open", std.fmt.allocPrint(arena, "{{\"app\":\"claude\",\"binary\":{s},\"timeout_ms\":30000}}", .{bin_json}) catch fail("oom"), "route stage: agent_open on hosta", false, 45_000);
    expectFact(local, "transport", "local", "route stage: the hosta agent is local");
    const remote = agentCall(&m, arena, "agent_open", "{\"app\":\"claude\",\"host\":\"hostb\",\"timeout_ms\":45000}", "route stage: agent_open host hostb", false, 60_000);
    expectFact(remote, "transport", "sketerm-mux", "route stage: the hostb agent is on hostb's daemon");
    const local_session = scStr(local, "session", "route stage: local session");
    const remote_session = scStr(remote, "session", "route stage: remote session");
    // What still lives on the server's private instance daemon: its terminals.
    _ = agentCall(&m, arena, "term_open", "{\"command\":[\"/bin/sh\"]}", "route stage: term_open on hosta", false, 30_000);
    const term_prefix = std.fmt.allocPrint(arena, "mcpterm-{d}-", .{m.pid}) catch fail("oom");

    // ── from here: hosta's daemon reports the assistant and both agents ──
    const Report = @import("ipc/mcp_registry.zig").Report;
    var instance_key: []const u8 = "";
    var local_route: [:0]const u8 = "";
    {
        var conn = muxclient.Conn.connectRemote(allocator, "ssh:hosta", .{}) catch fail("route stage: ssh to hosta");
        defer conn.deinit();
        if (!conn.caps.assistants) fail("route stage: hosta's daemon does not advertise assistants");
        conn.sendFrame(.list, "") catch fail("route stage: list send");
        const frame = conn.recvExpectFor(&.{.welcome}, 10_000) catch fail("route stage: list reply");
        defer frame.deinit(allocator);
        const Listing = struct { assistants: []const Report = &.{} };
        const parsed = std.json.parseFromSlice(Listing, arena, frame.payload, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch fail("route stage: list parse");
        if (parsed.value.assistants.len != 1) {
            say(frame.payload);
            fail("route stage: hosta's daemon must report exactly its one live MCP server");
        }
        const rep = parsed.value.assistants[0];
        var want_buf: [32]u8 = undefined;
        if (!std.mem.eql(u8, rep.instance, std.fmt.bufPrint(&want_buf, "tmp-{d}", .{m.pid}) catch fail("oom"))) fail("route stage: the reported instance key is not the server's");
        instance_key = rep.instance;
        const agents = rep.agents orelse fail("route stage: the report carries no agents");
        if (agents.len != 2) fail("route stage: the report must carry both agents");
        var buf: [256]u8 = undefined;
        for (agents) |ag| {
            const where = sshroute.Location.parse(ag.location) orelse fail("route stage: unparseable agent location");
            const route = sshroute.watchSpec(&buf, "ssh:hosta", rep.instance, "", where) catch fail("route stage: no watch route derived");
            const want_route = if (std.mem.eql(u8, ag.sessions[0], local_session))
                "hosta"
            else if (std.mem.eql(u8, ag.sessions[0], remote_session))
                "route:hosta/hostb"
            else
                fail("route stage: a reported agent's session is unknown");
            if (!std.mem.eql(u8, route, want_route)) {
                say(route);
                fail("route stage: the derived watch route is wrong");
            }
            if (std.mem.eql(u8, ag.sessions[0], local_session)) {
                // A local agent lives on hosta's per-user daemon.
                if (!std.mem.eql(u8, ag.location, "user")) fail("route stage: the report does not place the hosta agent on the per-user daemon");
                local_route = arena.dupeZ(u8, route) catch fail("oom");
            }
        }
        say("smoke-mcp: route stage: hosta's daemon reports the assistant, both agents and their locations");
    }

    // ── the CLI takes a route as its host: the agent's derived one, and
    // the instance route to the server's own daemon, which holds its
    // terminals and no longer its agents ──
    const inst_route = std.fmt.allocPrintSentinel(arena, "route:hosta#{s}", .{instance_key}, 0) catch fail("oom");
    {
        var out_buf: [16 * 1024]u8 = undefined;
        var status: c_int = 0;
        const argv_user = [_]?[*:0]const u8{ exe, "mux", local_route.ptr, "list", null };
        const out_user = runCapture(&argv_user, &out_buf, &status, 60_000);
        if (status != 0 or std.mem.indexOf(u8, out_user, local_session) == null) {
            say(out_user);
            fail("route stage: `sketerm mux <agent route> list` did not list the hosta agent");
        }
        const argv = [_]?[*:0]const u8{ exe, "mux", inst_route.ptr, "list", null };
        const out = runCapture(&argv, &out_buf, &status, 60_000);
        if (status != 0 or std.mem.indexOf(u8, out, term_prefix) == null or std.mem.indexOf(u8, out, local_session) != null) {
            say(out);
            fail("route stage: `sketerm mux <instance route> list` did not list exactly the instance's terminal");
        }
        const argv2 = [_]?[*:0]const u8{ exe, "mux", "route:hosta#nosuch", "list", null };
        const out2 = runCapture(&argv2, &out_buf, &status, 60_000);
        if (status == 0 or std.mem.indexOf(u8, out2, "no MCP instance 'nosuch'") == null) {
            say(out2);
            fail("route stage: the CLI did not name the unknown instance");
        }
    }

    // ── watch along both routes ──
    watchAlong(allocator, local_route, local_session, "via hosta", "route stage: hosta per-user daemon");
    watchAlong(allocator, "route:hosta/hostb", remote_session, "via hostb", "route stage: hosta -> hostb");
    say("smoke-mcp: route stage: both agents listed, attached, read and typed into along their routes");

    // ── refusals: named, prompt, never a hang ──
    expectRouteRefused(allocator, "route:hosta#deadone", error.RouteRefused, "is not running", "route stage: dead instance");
    expectRouteRefused(allocator, "route:hosta#nosuch", error.RouteRefused, "no MCP instance 'nosuch'", "route stage: unknown instance");
    expectRouteRefused(allocator, "route:oldhost/hostb", error.RouteHopTooOld, "sketerm-mux on oldhost is too old for routes", "route stage: an old first hop");
    expectRouteRefused(allocator, "route:hosta/oldhost#x", error.RouteHopTooOld, "sketerm-mux on oldhost is too old for routes", "route stage: an old later hop");
    expectRouteRefused(allocator, "route:hosta/nohost", error.RouteHopUnreachable, "Could not resolve hostname nohost", "route stage: an unreachable hop");

    const close_remote = std.fmt.allocPrint(arena, "{{\"agent\":\"{s}\"}}", .{scStr(remote, "agent", "route stage: hostb agent id")}) catch fail("oom");
    _ = agentCall(&m, arena, "agent_close", close_remote, "route stage: close hostb agent", false, 15_000);
    const close_local = std.fmt.allocPrint(arena, "{{\"agent\":\"{s}\"}}", .{scStr(local, "agent", "route stage: hosta agent id")}) catch fail("oom");
    _ = agentCall(&m, arena, "agent_close", close_local, "route stage: close hosta agent", false, 15_000);
    m.closeStdinWait();
}

fn writeExecutable(path: [:0]const u8, body: []const u8) void {
    const f = c.fopen(path.ptr, "w") orelse fail("cannot write a fake executable");
    _ = c.fwrite(body.ptr, 1, body.len, f);
    _ = c.fclose(f);
    if (c.chmod(path.ptr, 0o755) != 0) fail("chmod a fake executable");
}

/// The agent_* tools with `host`, against this machine standing in for
/// the remote: `ssh` on PATH is this binary (remote commands run here,
/// `-N -L` forwards locally) and `$SKETERM_SSH` bridges to a second
/// private daemon, the "remote" one. Proves both transports, remote
/// binary resolution through the candidates, the typed (never argv)
/// opencode password, the port forward and its revival, connection loss
/// and recovery, and a durable re-attach over SSH.
/// The fake remote host's daemon, its dirs under `rrt`; returns once
/// `rsock` exists.
fn startRemoteDaemon(rrt: [:0]const u8, rsock: []const u8) c.pid_t {
    const pid = c.fork();
    if (pid < 0) fail("fork remote daemon");
    if (pid == 0) {
        _ = c.setenv("XDG_RUNTIME_DIR", rrt.ptr, 1);
        _ = c.setenv("XDG_STATE_HOME", rrt.ptr, 1);
        _ = c.setenv("XDG_CONFIG_HOME", rrt.ptr, 1);
        const argv = [_:null]?[*:0]const u8{ "sketerm-mux", "--broker", null };
        _ = c.execv("zig-out/bin/sketerm-mux", @ptrCast(@constCast(&argv)));
        c._exit(127);
    }
    const deadline = nowMs() + 10_000;
    while (!fileExists(rsock)) {
        if (nowMs() > deadline) fail("the remote daemon's socket never appeared");
        _ = c.usleep(50_000);
    }
    return pid;
}

/// Cut the agents' link to the fake host and make it refuse until `down`
/// is removed.
fn cutRemoteLink(down: [:0]const u8, rt_env: []const u8) void {
    const f = c.fopen(down.ptr, "w") orelse fail("flag");
    _ = c.fclose(f);
    var pids_buf: [32]c.pid_t = undefined;
    const proxies = findProcs(&.{"--proxy"}, rt_env, &pids_buf);
    if (proxies.len == 0) fail("no ssh bridge to the remote daemon to cut");
    for (proxies) |p| _ = c.kill(p, c.SIGKILL);
}

fn syncWrite(arena: std.mem.Allocator, path: []const u8, body: []const u8, mtime: ?i64) void {
    const z = arena.dupeZ(u8, path) catch fail("oom");
    const f = c.fopen(z.ptr, "wb") orelse fail("file_sync: cannot write a fixture file");
    _ = c.fwrite(body.ptr, 1, body.len, f);
    _ = c.fclose(f);
    if (mtime) |t| {
        const cmd = std.fmt.allocPrintSentinel(arena, "touch -m -d @{d} '{s}'", .{ t, path }, 0) catch fail("oom");
        if (c.system(cmd.ptr) != 0) fail("file_sync: touch failed");
    }
}

fn syncExpect(arena: std.mem.Allocator, path: []const u8, want: ?[]const u8, comptime what: []const u8) void {
    const got = readFileAlloc(arena, path);
    if (want) |w| {
        if (got == null or !std.mem.eql(u8, got.?, w)) {
            say(path);
            say(got orelse "(missing)");
            fail("file_sync: " ++ what);
        }
    } else if (got != null) {
        say(path);
        fail("file_sync: " ++ what);
    }
}

fn syncTargets(r: std.json.ObjectMap) []std.json.Value {
    return (r.get("targets") orelse fail("file_sync: no targets fact")).array.items;
}

fn syncField(item: std.json.Value, key: []const u8) std.json.Value {
    return item.object.get(key) orelse fail("file_sync: a target fact is missing");
}

fn syncPath(a: std.mem.Allocator, dir: []const u8, rel: []const u8) []const u8 {
    return std.fmt.allocPrint(a, "{s}/{s}", .{ dir, rel }) catch fail("oom");
}

fn syncCall(m: *Mcp, a: std.mem.Allocator, json: []const u8, comptime what: []const u8) std.json.ObjectMap {
    const r = agentCall(m, a, "file_sync", json, "file_sync " ++ what, false, 110_000);
    for (syncTargets(r)) |item| {
        const st = syncField(item, "status");
        if (st == .string and std.mem.eql(u8, st.string, "failed"))
            say(std.json.Stringify.valueAlloc(a, item, .{}) catch "?");
    }
    return r;
}

/// file_sync over two fake hosts (`fakehost` syncs by rsync,
/// `fakehost-norsync` by the verified tar stream) and one local directory:
/// the first sync, keep_newer against a newer remote copy, a failing
/// target alone, dry_run changing nothing, and delete scoped to the target.
fn fileSyncStage(m: *Mcp, arena: std.mem.Allocator, rt: []const u8) void {
    if (c.getenv(NORSYNC_BIN_ENV) == null) fail("file_sync: the no-rsync fake host was not set up before the server started");
    const src = std.fmt.allocPrint(arena, "{s}/sync-src", .{rt}) catch fail("oom");
    for ([_][]const u8{ "", "/sub", "/sub/deep" }) |d| {
        const z = std.fmt.allocPrintSentinel(arena, "{s}{s}", .{ src, d }, 0) catch fail("oom");
        _ = c.mkdir(z.ptr, 0o755);
    }
    const now: i64 = @intCast(c.time(null));
    syncWrite(arena, syncPath(arena, src, "a.txt"), "A1\n", now - 600);
    syncWrite(arena, syncPath(arena, src, "keep.txt"), "K1\n", now - 600);
    syncWrite(arena, syncPath(arena, src, "sub/b.txt"), "B1\n", null);
    syncWrite(arena, syncPath(arena, src, "sub/deep/c.txt"), "C1\n", null);
    syncWrite(arena, syncPath(arena, src, "skip.tmp"), "TMP\n", null);
    // The tar-mode target is two levels below an existing directory.
    const dests = [_][]const u8{ syncPath(arena, rt, "sync-r1"), syncPath(arena, rt, "sync-r2/nested"), syncPath(arena, rt, "sync-l") };
    const bad = syncPath(arena, rt, "sync-notdir");
    syncWrite(arena, bad, "a file, not a directory\n", null);
    const outside = syncPath(arena, rt, "sync-outside.txt");
    syncWrite(arena, outside, "OUTSIDE\n", null);
    const targets_json = std.fmt.allocPrint(arena, "[{{\"host\":\"fakehost\",\"path\":\"{s}\"}},{{\"host\":\"" ++ NORSYNC_HOST ++ "\",\"path\":\"{s}\"}},{{\"path\":\"{s}\"}}", .{ dests[0], dests[1], dests[2] }) catch fail("oom");

    // 1. First sync, plus one target that is a file: it fails alone.
    {
        const r = syncCall(m, arena, std.fmt.allocPrint(arena, "{{\"local_dir\":\"{s}\",\"exclude\":[\"*.tmp\"],\"targets\":{s},{{\"host\":\"fakehost\",\"path\":\"{s}\"}}]}}", .{ src, targets_json, bad }) catch fail("oom"), "first sync");
        if (capInt(r, "total") != 4 or capInt(r, "succeeded") != 3 or capInt(r, "failed") != 1) fail("file_sync: expected 3 ok and the not-a-directory target failed");
        const items = syncTargets(r);
        for (items[0..3], [_][]const u8{ "rsync", "tar", "rsync" }) |item, want| {
            if (!std.mem.eql(u8, syncField(item, "method").string, want)) {
                say(want);
                fail("file_sync: a target used the wrong method");
            }
            if (syncField(item, "sent").integer != 4) fail("file_sync: the first sync did not send the 4 files");
        }
        if (!std.mem.eql(u8, syncField(items[1], "verification").string, "sha256_manifest")) fail("file_sync: tar mode did not report its sha256 verification");
        if (!std.mem.eql(u8, syncField(items[3], "status").string, "failed")) fail("file_sync: the not-a-directory target did not fail");
        for (dests) |d| {
            syncExpect(arena, syncPath(arena, d, "a.txt"), "A1\n", "a.txt did not arrive");
            syncExpect(arena, syncPath(arena, d, "sub/deep/c.txt"), "C1\n", "the nested file did not arrive");
            syncExpect(arena, syncPath(arena, d, "skip.tmp"), null, "an excluded file was synced");
        }
        say("smoke-mcp: file_sync: rsync, tar and local targets synced; the broken one failed alone");
    }

    // 2. keep_newer: a.txt changed here, keep.txt changed LATER on every target.
    syncWrite(arena, syncPath(arena, src, "a.txt"), "A2\n", now - 60);
    for (dests) |d| syncWrite(arena, syncPath(arena, d, "keep.txt"), "K-REMOTE\n", now + 600);
    {
        const r = syncCall(m, arena, std.fmt.allocPrint(arena, "{{\"local_dir\":\"{s}\",\"exclude\":[\"*.tmp\"],\"targets\":{s}]}}", .{ src, targets_json }) catch fail("oom"), "keep_newer");
        if (capInt(r, "succeeded") != 3) fail("file_sync: the keep_newer sync did not succeed everywhere");
        for (syncTargets(r)) |item| {
            if (syncField(item, "sent").integer != 1) fail("file_sync: keep_newer should send exactly the changed file");
            const sk = syncField(item, "skipped");
            if (sk != .integer or sk.integer < 1) fail("file_sync: keep_newer reported no skipped file");
        }
        for (dests) |d| {
            syncExpect(arena, syncPath(arena, d, "a.txt"), "A2\n", "the changed file did not arrive");
            syncExpect(arena, syncPath(arena, d, "keep.txt"), "K-REMOTE\n", "keep_newer overwrote a newer remote file");
        }
        say("smoke-mcp: file_sync: keep_newer kept the newer remote file and sent the changed one");
    }

    // 3. dry_run with delete: reports, changes nothing.
    syncWrite(arena, syncPath(arena, src, "a.txt"), "A3\n", now - 30);
    for (dests) |d| {
        syncWrite(arena, syncPath(arena, d, "extra.txt"), "EXTRA\n", null);
        syncWrite(arena, syncPath(arena, d, "local.tmp"), "EXCLUDED\n", null);
    }
    {
        const r = syncCall(m, arena, std.fmt.allocPrint(arena, "{{\"local_dir\":\"{s}\",\"exclude\":[\"*.tmp\"],\"delete\":true,\"dry_run\":true,\"targets\":{s}]}}", .{ src, targets_json }) catch fail("oom"), "dry_run");
        if (capInt(r, "succeeded") != 3) fail("file_sync: the dry run did not succeed everywhere");
        for (syncTargets(r)) |item| {
            if (syncField(item, "sent").integer != 1 or syncField(item, "deleted").integer != 1) fail("file_sync: the dry run should report 1 to send and 1 to delete");
        }
        for (dests) |d| {
            syncExpect(arena, syncPath(arena, d, "a.txt"), "A2\n", "dry_run changed a file");
            syncExpect(arena, syncPath(arena, d, "extra.txt"), "EXTRA\n", "dry_run deleted a file");
        }
        say("smoke-mcp: file_sync: dry_run reported the changes and made none");
    }

    // 4. delete: only inside the target, never an excluded file; a missing
    //    target directory refuses delete alone.
    {
        const absent = syncPath(arena, rt, "sync-absent");
        const r = syncCall(m, arena, std.fmt.allocPrint(arena, "{{\"local_dir\":\"{s}\",\"exclude\":[\"*.tmp\"],\"delete\":true,\"targets\":{s},{{\"host\":\"fakehost\",\"path\":\"{s}\"}}]}}", .{ src, targets_json, absent }) catch fail("oom"), "delete");
        if (capInt(r, "succeeded") != 3 or capInt(r, "failed") != 1) fail("file_sync: delete: expected 3 ok and the absent target refused");
        const items = syncTargets(r);
        for (items[0..3]) |item| if (syncField(item, "deleted").integer != 1) fail("file_sync: delete did not remove exactly the one extra file");
        if (!std.mem.eql(u8, syncField(syncField(items[3], "error"), "code").string, "refused")) fail("file_sync: delete into a missing directory was not refused");
        if (fileExists(absent)) fail("file_sync: a refused delete target was created");
        for (dests) |d| {
            syncExpect(arena, syncPath(arena, d, "extra.txt"), null, "delete left the extra file");
            syncExpect(arena, syncPath(arena, d, "local.tmp"), "EXCLUDED\n", "delete removed an excluded file");
            syncExpect(arena, syncPath(arena, d, "a.txt"), "A3\n", "the delete run did not send the change");
        }
        syncExpect(arena, outside, "OUTSIDE\n", "delete reached outside the target");
        say("smoke-mcp: file_sync: delete stayed inside the target and spared excluded files");
    }
}

fn agentSshStage(allocator: std.mem.Allocator, exe: [*:0]const u8, rt: []const u8) void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var self_buf: [4096]u8 = undefined;
    const self_exe = platform.exePath(&self_buf) orelse fail("agent ssh stage: own executable path");

    // The "remote" home: the app binaries live where an ssh login's PATH
    // does not look (~/.local/bin), so only the candidates find them.
    const home = std.mem.span(@as([*:0]const u8, @ptrCast(c.getenv("HOME") orelse fail("no HOME"))));
    const local_bin = std.fmt.allocPrintSentinel(arena, "{s}/.local/bin", .{home}, 0) catch fail("oom");
    _ = c.system((std.fmt.allocPrintSentinel(arena, "mkdir -p '{s}'", .{local_bin}, 0) catch fail("oom")).ptr);
    for ([_][]const u8{ "claude", "sk-fake-opencode" }) |name| {
        const link = std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ local_bin, name }, 0) catch fail("oom");
        _ = c.unlink(link.ptr);
        const target = std.fmt.allocPrintSentinel(arena, "{s}", .{self_exe}, 0) catch fail("oom");
        if (c.symlink(target.ptr, link.ptr) != 0) fail("could not place the fake agent binaries");
    }

    // `ssh`/`scp` on PATH: plain transport, the binary probe, forwards.
    const bin = std.fmt.allocPrintSentinel(arena, "{s}/fakebin", .{rt}, 0) catch fail("oom");
    _ = c.mkdir(bin.ptr, 0o700);
    for ([_][]const u8{ "ssh", "scp" }) |name| {
        const link = std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ bin, name }, 0) catch fail("oom");
        _ = c.unlink(link.ptr);
        if (c.symlink((std.fmt.allocPrintSentinel(arena, "{s}", .{self_exe}, 0) catch fail("oom")).ptr, link.ptr) != 0) fail("could not link the fake ssh");
    }
    const old_path: []const u8 = if (c.getenv("PATH")) |p| std.mem.span(@as([*:0]const u8, @ptrCast(p))) else "/usr/bin:/bin";
    const saved_path = arena.dupeZ(u8, old_path) catch fail("oom");
    // A system PATH only: the developer's own ~/.local/bin holds a REAL
    // claude the candidates must never find in this stage.
    _ = c.setenv("PATH", (std.fmt.allocPrintSentinel(arena, "{s}:/usr/bin:/bin", .{bin}, 0) catch fail("oom")).ptr, 1);
    _ = c.setenv(FAKE_SSH_ENV, "1", 1);
    _ = c.setenv(FAKE_AGENT_ENV, "1", 1);
    _ = c.setenv(FAKE_OC_DEAF_ENV, "3000", 1);
    // What a nested Claude Code must never inherit, on the "remote" host too.
    _ = c.setenv("CLAUDE_CODE_CHILD_SESSION", "1", 1);
    // file_sync's tar mode: `fakehost-norsync` sees a failing rsync first
    // on PATH. Set before any server starts, since the daemon that runs
    // the fake ssh inherits its environment then.
    const norsync_bin = std.fmt.allocPrintSentinel(arena, "{s}/norsync-bin", .{rt}, 0) catch fail("oom");
    _ = c.mkdir(norsync_bin.ptr, 0o700);
    writeExecutable(std.fmt.allocPrintSentinel(arena, "{s}/rsync", .{norsync_bin}, 0) catch fail("oom"), "#!/bin/sh\nexit 127\n");
    _ = c.setenv(NORSYNC_BIN_ENV, norsync_bin.ptr, 1);
    defer {
        _ = c.unsetenv(NORSYNC_BIN_ENV);
        _ = c.setenv("PATH", saved_path.ptr, 1);
        _ = c.setenv(FAKE_SSH_ENV, "1", 1);
        _ = c.unsetenv(FAKE_AGENT_ENV);
        _ = c.unsetenv(FAKE_OC_DEAF_ENV);
        _ = c.unsetenv("CLAUDE_CODE_CHILD_SESSION");
        _ = c.unsetenv("SKETERM_SSH");
    }

    // The "remote" daemon, and the `$SKETERM_SSH` bridge to it. A flag
    // file makes the bridge refuse, like a host that went away.
    const rrt = std.fmt.allocPrintSentinel(arena, "{s}/r", .{rt}, 0) catch fail("oom");
    _ = c.mkdir(rrt.ptr, 0o700);
    var mux_abs_buf: [4096]u8 = undefined;
    const mux_abs = std.mem.span(@as([*:0]const u8, @ptrCast(c.realpath("zig-out/bin/sketerm-mux", &mux_abs_buf) orelse fail("zig-out/bin/sketerm-mux missing"))));
    const rsock = std.fmt.allocPrint(arena, "{s}/sketerm/mux.sock", .{rrt}) catch fail("oom");
    var rpid = startRemoteDaemon(rrt, rsock);
    const down = std.fmt.allocPrintSentinel(arena, "{s}/ssh-down", .{rt}, 0) catch fail("oom");
    const bridge = std.fmt.allocPrintSentinel(arena, "{s}/fake-mux-ssh", .{rt}, 0) catch fail("oom");
    {
        const body = std.fmt.allocPrint(arena,
            \\#!/bin/sh
            \\if [ "$1" = "-G" ]; then printf 'hostname 127.0.0.1\n'; exit 0; fi
            \\case " $* " in *" downhost "*) echo 'ssh: connect to host downhost port 22: Connection timed out' >&2; exit 255;; esac
            \\[ -e '{s}' ] && exit 255
            \\export XDG_RUNTIME_DIR='{s}' XDG_STATE_HOME='{s}' XDG_CONFIG_HOME='{s}' SKETERM_MUX_BIN='{s}'
            \\exec '{s}' --proxy
            \\
        , .{ down, rrt, rrt, rrt, mux_abs, mux_abs }) catch fail("oom");
        const f = c.fopen(bridge.ptr, "w") orelse fail("cannot write the fake mux ssh");
        _ = c.fwrite(body.ptr, 1, body.len, f);
        _ = c.fclose(f);
        if (c.chmod(bridge.ptr, 0o755) != 0) fail("chmod fake mux ssh");
    }
    _ = c.setenv("SKETERM_SSH", bridge.ptr, 1);
    const rt_env = std.fmt.allocPrint(arena, "XDG_RUNTIME_DIR={s}", .{rrt}) catch fail("oom");

    // ── the host's own daemon (transport sketerm-mux) ───────────────
    {
        var m = Mcp.spawn(allocator, exe, &.{});
        m.initialize();
        const caps = agentCall(&m, arena, "capabilities", "{}", "capabilities", false, 15_000);
        if (!caps.get("agent_ssh").?.bool) fail("capabilities: agent_ssh is false with an ssh client on PATH");
        if (!caps.get("agent_login_shell").?.bool) fail("capabilities: agent_login_shell is false with an ssh client on PATH");
        if (capInt(caps, "scp_put_targets") != 32) fail("capabilities: scp_put_targets is not 32");
        if (capInt(caps, "ssh_connect_timeout_s") != 10) fail("capabilities: ssh_connect_timeout_s is not 10");

        // A host ssh cannot reach fails term_open at once, naming the host
        // and what ssh said, instead of falling back to a plain ssh session.
        {
            const t0 = nowMs();
            const refused = agentCall(&m, arena, "term_open", "{\"host\":\"downhost\"}", "term_open to a down host", true, 60_000);
            const err = (refused.get("error") orelse fail("term_open to a down host: no error")).object;
            expectFact(err, "code", "host_unreachable", "term_open to a down host: code");
            const details = (err.get("details") orelse fail("term_open to a down host: no details")).object;
            expectFact(details, "host", "downhost", "term_open to a down host: host");
            if (std.mem.indexOf(u8, scStr(details, "ssh_error", "term_open to a down host"), "Connection timed out") == null) fail("term_open to a down host: ssh's message is missing");
            if (nowMs() - t0 > 10_000) fail("term_open to a down host: not fast (it retried, or fell back to plain ssh)");
            say("smoke-mcp: term_open to an unreachable host fails fast as host_unreachable with ssh's message ok");
        }

        // scp_put to several targets: each verified and moved on its own,
        // a failing one (its directory does not exist) stops none of the others.
        {
            const src = std.fmt.allocPrintSentinel(arena, "{s}/multi-src.txt", .{rt}, 0) catch fail("oom");
            const f = c.fopen(src.ptr, "w") orelse fail("could not write the upload source");
            _ = c.fputs("MULTI-TARGET-PAYLOAD\n", f);
            _ = c.fclose(f);
            const put = agentCall(&m, arena, "scp_put", std.fmt.allocPrint(arena, "{{\"local_path\":\"{s}\",\"targets\":[{{\"host\":\"fakehost\",\"path\":\"{s}/multi-1.txt\"}},{{\"host\":\"fakehost\",\"path\":\"{s}/no-such-dir/multi-2.txt\"}},{{\"host\":\"fakehost\",\"path\":\"{s}/multi-3.txt\"}}]}}", .{ src, rt, rt, rt }) catch fail("oom"), "scp_put targets", false, 90_000);
            if (capInt(put, "total") != 3 or capInt(put, "succeeded") != 2 or capInt(put, "failed") != 1) {
                say(std.json.Stringify.valueAlloc(arena, put.get("targets").?, .{}) catch "?");
                fail("scp_put targets: expected 2 ok and 1 failed");
            }
            const items = put.get("targets").?.array.items;
            const sha = scStr(put, "sha256", "scp_put targets: the local sha256");
            for (items, [_][]const u8{ "ok", "failed", "ok" }) |item, want| {
                if (!std.mem.eql(u8, item.object.get("status").?.string, want)) fail("scp_put targets: a target has the wrong status");
                if (std.mem.eql(u8, want, "ok") and !std.mem.eql(u8, item.object.get("sha256").?.string, sha))
                    fail("scp_put targets: an ok target's sha256 is not the local one");
            }
            for ([_][]const u8{ "multi-1.txt", "multi-3.txt" }) |name| {
                const p = std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ rt, name }, 0) catch fail("oom");
                if (c.access(p.ptr, c.F_OK) != 0) fail("scp_put targets: an ok target's file is missing");
            }
            say("smoke-mcp: scp_put targets: 2 verified and moved, the broken one failed alone");
        }
        fileSyncStage(&m, arena, rt);
        // One probe on the host: claude is found through ~/.local/bin.
        const ad = agentCall(&m, arena, "agent_adapters", "{\"host\":\"fakehost\"}", "agent_adapters host", false, 45_000);
        expectFact(ad, "host", "fakehost", "agent_adapters host: host fact");
        var claude_bin: ?[]const u8 = null;
        for (ad.get("adapters").?.array.items) |item| {
            if (!std.mem.eql(u8, item.object.get("id").?.string, "claude")) continue;
            if (item.object.get("binary").? == .string) claude_bin = item.object.get("binary").?.string;
        }
        const want_bin = std.fmt.allocPrint(arena, "{s}/claude", .{local_bin}) catch fail("oom");
        if (claude_bin == null or !std.mem.eql(u8, claude_bin.?, want_bin)) {
            say(std.json.Stringify.valueAlloc(arena, ad.get("adapters").?, .{}) catch "?");
            fail("agent_adapters host: claude not resolved through the ~/.local/bin candidate");
        }
        // A remote agent's facts file rides its host's probe.
        agentFactsCheck(&m, arena, rt, "\"host\":\"fakehost\"", false, "facts (remote)");

        resetStarts();
        const opened = agentCall(&m, arena, "agent_open", std.fmt.allocPrint(arena, "{{\"app\":\"claude\",\"name\":\"claude-1\",\"host\":\"fakehost\",\"timeout_ms\":45000{s}}}", .{extraJson(arena)}) catch fail("oom"), "agent_open claude on host", false, 60_000);
        expectExtraFacts(arena, opened, "agent_open claude on host");
        expectStarts(arena, "claude", 1, "agent_open claude on the host daemon");
        expectFact(opened, "transport", "sketerm-mux", "agent_open host: the host's own daemon");
        expectFact(opened, "host", "fakehost", "agent_open host: host fact");
        expectFact(opened, "binary", want_bin, "agent_open host: the remote binary from the candidates");
        expectFact(opened, "binary_version", FAKE_AGENT_VERSION, "agent_open host: the binary's version line");
        if (!opened.get("ready").?.bool) fail("agent_open host: the remote fake Claude Code never became ready");
        const r_session = arena.dupe(u8, scStr(opened, "session", "agent_open claude on host")) catch fail("oom");
        if (!sessionListed(allocator, rsock, r_session)) fail("the agent is not a session on the remote daemon");
        const hello = agentCall(&m, arena, "agent_send", "{\"agent\":\"claude-1\",\"text\":\"hello from afar\",\"timeout_ms\":20000}", "agent_send remote", false, 45_000);
        expectFact(hello, "message", "echo: hello from afar", "agent_send remote: message");

        // The link drops and the host refuses for a while: connection_lost.
        {
            const f = c.fopen(down.ptr, "w") orelse fail("flag");
            _ = c.fclose(f);
        }
        var pids_buf: [32]c.pid_t = undefined;
        const proxies = findProcs(&.{"--proxy"}, rt_env, &pids_buf);
        if (proxies.len == 0) fail("no ssh bridge to the remote daemon to cut");
        for (proxies) |p| _ = c.kill(p, c.SIGKILL);
        const lost = agentCall(&m, arena, "agent_wait", "{\"agent\":\"claude-1\",\"timeout_ms\":20000}", "agent_wait lost", false, 45_000);
        expectFact(lost, "outcome", "connection_lost", "agent_wait: the lost link is connection_lost");
        expectFact(lost, "state", "disconnected", "agent_wait: state after the drop");
        // The host answers again: the background retry reconnects and
        // resyncs, and says so (connection_restored wakes a waiter).
        _ = c.unlink(down.ptr);
        _ = c.usleep(5_500_000);
        const back = agentCall(&m, arena, "agent_wait", "{\"agent\":\"claude-1\",\"timeout_ms\":3000}", "agent_wait recovered", false, 30_000);
        expectFact(back, "state", "idle", "agent_wait: idle again after the reconnect");
        if (eventKinds(back, "connection_restored") != 1) fail("agent_wait: the reconnect raised no connection_restored");
        const after = agentCall(&m, arena, "agent_send", "{\"agent\":\"claude-1\",\"text\":\"after the drop\",\"timeout_ms\":20000}", "agent_send after drop", false, 45_000);
        expectFact(after, "message", "echo: after the drop", "agent_send after the reconnect");
        // The resync is a wipe: nothing captured twice.
        const all = agentCall(&m, arena, "agent_read", "{\"agent\":\"claude-1\",\"detail\":\"all\",\"since\":0}", "agent_read remote", false, 15_000);
        var hellos: usize = 0;
        for (all.get("records").?.array.items) |r| {
            if (std.mem.eql(u8, r.object.get("text").?.string, "echo: hello from afar")) hellos += 1;
        }
        if (hellos != 1) fail("agent_read: the resync captured a turn twice");

        // Effort on the host: restarted there, the conversation resumed.
        const eff = agentCall(&m, arena, "agent_set", "{\"agent\":\"claude-1\",\"effort\":\"low\",\"timeout_ms\":30000}", "agent_set effort remote", false, 60_000);
        if (!eff.get("relaunched").?.bool) fail("agent_set effort on the host: not a relaunch");
        const recall = agentCall(&m, arena, "agent_send", "{\"agent\":\"claude-1\",\"text\":\"recall\",\"timeout_ms\":20000}", "agent_send recall remote", false, 45_000);
        expectFact(recall, "message", "first prompt was: hello from afar", "agent_send recall on the host");
        expectStarts(arena, "claude", 2, "agent_set effort relaunch on the host");

        // opencode on the host: password typed, server behind a forward.
        // With its attached TUI, asked for: the password typed into it too.
        const oc = agentCall(&m, arena, "agent_open", "{\"app\":\"opencode\",\"name\":\"opencode-1\",\"host\":\"fakehost\",\"binary\":\"sk-fake-opencode\",\"tui\":true,\"timeout_ms\":45000}", "agent_open opencode on host", false, 60_000);
        expectFact(oc, "transport", "sketerm-mux", "agent_open opencode host: transport");
        if (!oc.get("ready").?.bool) fail("agent_open opencode host: not ready");
        const r_server = arena.dupe(u8, scStr(oc, "server_session", "agent_open opencode on host")) catch fail("oom");
        if (!sessionListed(allocator, rsock, r_server)) fail("the opencode server is not a session on the remote daemon");
        const r_tui = arena.dupe(u8, scStr(oc, "session", "agent_open opencode on host")) catch fail("oom");
        if (std.mem.eql(u8, r_tui, r_server) or !oc.get("tui").?.bool or !sessionListed(allocator, rsock, r_tui)) fail("the remote opencode's TUI is not a session on the remote daemon");
        const oc_sent = agentCall(&m, arena, "agent_send", "{\"agent\":\"opencode-1\",\"text\":\"over the forward\",\"timeout_ms\":20000}", "agent_send opencode remote", false, 45_000);
        expectFact(oc_sent, "outcome", "done", "agent_send opencode on the host: outcome");
        expectPasswordsHidden(arena, &.{}, "opencode on the host's daemon");
        // The forward dies: it is re-established and the API comes back.
        const fwd = findProcs(&.{ "-N", "-L" }, std.fmt.allocPrint(arena, "XDG_RUNTIME_DIR={s}\x00", .{rt}) catch fail("oom"), &pids_buf);
        if (fwd.len == 0) fail("no port forward process to kill");
        for (fwd) |p| _ = c.kill(-p, c.SIGKILL);
        _ = c.usleep(5_000_000);
        const oc_again = agentCall(&m, arena, "agent_send", "{\"agent\":\"opencode-1\",\"text\":\"after the forward died\",\"timeout_ms\":30000}", "agent_send after forward", false, 45_000);
        expectFact(oc_again, "outcome", "done", "agent_send after the forward was re-established");

        _ = agentCall(&m, arena, "agent_close", "{\"agent\":\"opencode-1\"}", "agent_close opencode remote", false, 15_000);
        _ = agentCall(&m, arena, "agent_close", "{\"agent\":\"claude-1\"}", "agent_close claude remote", false, 15_000);
        waitUnlisted(allocator, rsock, r_session, "agent_close remote claude");
        waitUnlisted(allocator, rsock, r_server, "agent_close remote opencode");
        waitUnlisted(allocator, rsock, r_tui, "agent_close remote opencode TUI");
        m.closeStdinWait();
        say("smoke-mcp: agents over ssh: host daemon (probe, open, send, drop + recovery, effort relaunch, opencode forward + revival, password hidden, close) ok");
    }

    // ── plain ssh (transport ssh) ───────────────────────────────────
    {
        var m = Mcp.spawn(allocator, exe, &.{});
        m.initialize();
        const oc = agentCall(&m, arena, "agent_open", "{\"app\":\"opencode\",\"name\":\"opencode-1\",\"host\":\"fakehost\",\"transport\":\"ssh\",\"binary\":\"sk-fake-opencode\",\"timeout_ms\":45000}", "agent_open opencode over ssh", false, 60_000);
        expectFact(oc, "transport", "ssh", "agent_open opencode over plain ssh: transport");
        const oc_sent = agentCall(&m, arena, "agent_send", "{\"agent\":\"opencode-1\",\"text\":\"plain ssh\",\"timeout_ms\":20000}", "agent_send opencode over ssh", false, 45_000);
        expectFact(oc_sent, "outcome", "done", "agent_send opencode over plain ssh");
        // Its server terminal is recorded here, and was typed the password.
        const recs = (oc.get("recordings") orelse fail("no recordings")).array.items;
        if (recs.len == 0) fail("agent_open over plain ssh: not recorded");
        expectPasswordsHidden(arena, recs, "opencode over plain ssh");
        _ = agentCall(&m, arena, "agent_close", "{\"agent\":\"opencode-1\"}", "agent_close opencode ssh", false, 15_000);

        resetStarts();
        const cl = agentCall(&m, arena, "agent_open", std.fmt.allocPrint(arena, "{{\"app\":\"claude\",\"name\":\"claude-1\",\"host\":\"fakehost\",\"transport\":\"ssh\",\"timeout_ms\":45000{s}}}", .{extraJson(arena)}) catch fail("oom"), "agent_open claude over ssh", false, 60_000);
        expectExtraFacts(arena, cl, "agent_open claude over plain ssh");
        expectStarts(arena, "claude", 1, "agent_open claude over plain ssh");
        expectFact(cl, "transport", "ssh", "agent_open claude over plain ssh: transport");
        const sent = agentCall(&m, arena, "agent_send", "{\"agent\":\"claude-1\",\"text\":\"plain hello\",\"timeout_ms\":20000}", "agent_send claude over ssh", false, 45_000);
        expectFact(sent, "message", "echo: plain hello", "agent_send claude over plain ssh");
        // ssh loses the connection: the remote process is gone with it.
        var pids_buf: [32]c.pid_t = undefined;
        const env_rt = std.fmt.allocPrint(arena, "XDG_RUNTIME_DIR={s}\x00", .{rt}) catch fail("oom");
        // The closed opencode agent's ssh sessions may take a moment to go.
        var sshs = findProcs(&.{"-tt"}, env_rt, &pids_buf);
        const until = nowMs() + 5_000;
        while (sshs.len != 1 and nowMs() < until) {
            _ = c.usleep(100_000);
            sshs = findProcs(&.{"-tt"}, env_rt, &pids_buf);
        }
        if (sshs.len != 1) fail("expected exactly the claude agent's ssh -tt");
        _ = c.kill(sshs[0], c.SIGTERM);
        const lost = agentCall(&m, arena, "agent_wait", "{\"agent\":\"claude-1\",\"timeout_ms\":20000}", "agent_wait ssh lost", false, 45_000);
        var kinds: [2]bool = .{ false, false };
        for (lost.get("events").?.array.items) |ev| {
            const k = ev.object.get("kind").?.string;
            if (std.mem.eql(u8, k, "connection_lost")) kinds[0] = true;
            if (std.mem.eql(u8, k, "exited")) kinds[1] = true;
        }
        if (!kinds[0] or !kinds[1]) fail("a dropped plain ssh is not connection_lost + exited");
        _ = agentCall(&m, arena, "agent_close", "{\"agent\":\"claude-1\"}", "agent_close claude ssh", false, 15_000);
        m.closeStdinWait();
        say("smoke-mcp: agents over ssh: plain ssh (opencode with a typed password, claude, drop) ok");
    }

    // ── the host view and the per-host cap ──────────────────────────
    {
        writeSmokeConfig(rt, "mcp_agent_max_per_host = 1\n");
        defer removeSmokeConfig(rt);
        var m = Mcp.spawn(allocator, exe, &.{});
        m.initialize();
        const caps = agentCall(&m, arena, "capabilities", "{}", "capabilities caps", false, 15_000);
        if (capInt(caps.get("agent_caps").?.object, "max_per_host") != 1) fail("capabilities: agent_caps.max_per_host is not the configured 1");
        _ = agentCall(&m, arena, "agent_open", "{\"app\":\"claude\",\"name\":\"cap-1\",\"host\":\"fakehost\",\"timeout_ms\":45000}", "cap: first agent_open", false, 60_000);
        const over = agentCall(&m, arena, "agent_open", "{\"app\":\"claude\",\"name\":\"cap-2\",\"host\":\"fakehost\",\"timeout_ms\":45000}", "cap: second agent_open", true, 60_000);
        const err = (over.get("error") orelse fail("cap: no error")).object;
        expectFact(err, "code", "refused", "cap: code");
        if (std.mem.indexOf(u8, scStr(err, "message", "cap"), "mcp_agent_max_per_host") == null) fail("cap: the refusal does not name the cap");
        // One line per host: its agents, memory and load (the fake host is
        // this Linux machine, so the numbers are known).
        var known = false;
        var tries: usize = 0;
        while (!known and tries < 5) : (tries += 1) {
            const l = agentCall(&m, arena, "agent_list", "{}", "cap: agent_list hosts", false, 30_000);
            for (l.get("hosts").?.array.items) |h| {
                if (!std.mem.eql(u8, h.object.get("host").?.string, "fakehost")) continue;
                if (h.object.get("agents").?.integer != 1) fail("cap: agent_list hosts counts the wrong number of agents");
                known = h.object.get("mem_available_mb").? == .integer and h.object.get("load").? == .array;
            }
        }
        if (!known) fail("cap: agent_list never read the host's memory and load");
        _ = agentCall(&m, arena, "agent_close", "{\"agent\":\"cap-1\"}", "cap: agent_close", false, 15_000);
        m.closeStdinWait();
        say("smoke-mcp: agents over ssh: agent_list's host lines and the per-host cap ok");
    }

    // ── a durable instance re-attaches a remote agent over ssh ───────
    {
        var d1 = Mcp.spawn(allocator, exe, &.{ "--name", "agentssh" });
        d1.initialize();
        const opened = agentCall(&d1, arena, "agent_open", "{\"app\":\"claude\",\"name\":\"claude-1\",\"host\":\"fakehost\",\"prompt\":\"before restart\",\"timeout_ms\":45000}", "durable remote agent_open", false, 60_000);
        expectFact(opened, "transport", "sketerm-mux", "durable remote: transport");
        expectFact(opened, "message", "echo: before restart", "durable remote: prompt answer");
        d1.closeStdinWait();
        var d2 = Mcp.spawn(allocator, exe, &.{ "--name", "agentssh" });
        d2.initialize();
        const listed = agentCall(&d2, arena, "agent_list", "{\"detail\":true}", "durable remote agent_list", false, 30_000);
        if (listed.get("count").?.integer != 1) fail("durable remote: the restarted server did not pick its remote agent up");
        const item = listed.get("agents").?.array.items[0].object;
        if (!std.mem.eql(u8, item.get("transport").?.string, "sketerm-mux")) fail("durable remote: re-attached over another transport");
        const back = agentCall(&d2, arena, "agent_send", "{\"agent\":\"claude-1\",\"text\":\"after restart\",\"timeout_ms\":20000}", "durable remote agent_send", false, 45_000);
        expectFact(back, "message", "echo: after restart", "durable remote: the re-attached agent answers");
        _ = agentCall(&d2, arena, "agent_close", "{\"agent\":\"claude-1\"}", "durable remote agent_close", false, 15_000);
        d2.closeStdinWait();
        say("smoke-mcp: agents over ssh: a durable instance re-attaches its remote agent ok");
    }

    // ── a lost link that comes back to find the session gone ─────────
    {
        var m = Mcp.spawn(allocator, exe, &.{});
        m.initialize();
        const opened = agentCall(&m, arena, "agent_open", "{\"app\":\"claude\",\"name\":\"claude-gone\",\"host\":\"fakehost\",\"prompt\":\"before the loss\",\"timeout_ms\":45000}", "gone: agent_open", false, 60_000);
        expectFact(opened, "transport", "sketerm-mux", "gone: transport");
        const session = arena.dupe(u8, scStr(opened, "session", "gone: agent_open")) catch fail("oom");
        cutRemoteLink(down, rt_env);
        const lost = agentCall(&m, arena, "agent_wait", "{\"agent\":\"claude-gone\",\"timeout_ms\":20000}", "gone: agent_wait lost", false, 45_000);
        expectFact(lost, "outcome", "connection_lost", "gone: the lost link is connection_lost");
        // An unreachable host: still disconnected (every call retries it at once).
        _ = c.usleep(2_500_000);
        const still = agentCall(&m, arena, "agent_read", "{\"agent\":\"claude-gone\"}", "gone: agent_read while unreachable", false, 30_000);
        expectFact(still, "state", "disconnected", "gone: an unreachable host stays disconnected");
        if (still.get("relaunchable") != null) fail("gone: a disconnected agent reads as gone");
        // Meanwhile its session is closed on the host.
        {
            var conn = muxclient.Conn.connectProbed(allocator, rsock) catch fail("gone: cannot reach the remote daemon");
            defer conn.deinit();
            conn.sendKill(.{ .name = session }) catch fail("gone: kill");
        }
        waitUnlisted(allocator, rsock, session, "gone: the remote session was not closed");
        _ = c.unlink(down.ptr);
        const ended = agentCall(&m, arena, "agent_wait", "{\"agent\":\"claude-gone\",\"timeout_ms\":30000}", "gone: agent_wait after the host answers", false, 45_000);
        expectFact(ended, "outcome", "exited", "gone: a reconnect that finds no session ends the agent");
        expectFact(ended, "state", "exited", "gone: state");
        expectFact(ended, "gone_reason", "closed", "gone: the daemon's tombstone reason");
        if (!ended.get("relaunchable").?.bool) fail("gone: not relaunchable");
        if (eventKinds(ended, "exited") != 1) fail("gone: not exactly one exited event");
        // Compact: the gone agent is on the one gone line, not a full entry.
        // By default a gone agent is only counted; include_exited lists it.
        const hiding = agentCall(&m, arena, "agent_list", "{}", "gone: agent_list default", false, 15_000);
        if (hiding.get("agents").?.array.items.len != 0 or hiding.get("gone").?.array.items.len != 0 or hiding.get("exited_hidden").?.integer != 1)
            fail("gone: the default agent_list does not leave the gone agent out as a count");
        const listed = agentCall(&m, arena, "agent_list", "{\"include_exited\":true}", "gone: agent_list", false, 15_000);
        if (listed.get("agents").?.array.items.len != 0) fail("gone: compact agent_list still lists the gone agent in full");
        const gone_item = listed.get("gone").?.array.items[0].object;
        if (!std.mem.eql(u8, gone_item.get("name").?.string, "claude-gone") or !gone_item.get("relaunchable").?.bool)
            fail("gone: compact agent_list's gone line does not name it relaunchable");
        const listed_full = agentCall(&m, arena, "agent_list", "{\"detail\":true,\"include_exited\":true}", "gone: agent_list detail", false, 15_000);
        const item = listed_full.get("agents").?.array.items[0].object;
        if (!std.mem.eql(u8, item.get("state").?.string, "exited") or !item.get("relaunchable").?.bool or !std.mem.eql(u8, item.get("gone_reason").?.string, "closed"))
            fail("gone: agent_list detail does not say exited, relaunchable, closed");
        // Its name stays its own: agent_open names the gone agent and the relaunch.
        {
            const clash = agentCall(&m, arena, "agent_open", "{\"app\":\"claude\",\"name\":\"claude-gone\",\"host\":\"fakehost\",\"timeout_ms\":5000}", "gone: agent_open with the gone agent's name", true, 30_000);
            const err = (clash.get("error") orelse fail("gone: name clash: no error")).object;
            expectFact(err, "code", "conflict", "gone: name clash: code");
            const msg = scStr(err, "message", "gone: name clash");
            if (std.mem.indexOf(u8, msg, "is gone") == null or std.mem.indexOf(u8, msg, "relaunch: true") == null) fail("gone: the name clash does not name the gone agent and its relaunch");
        }
        // agent_attach relaunch starts it again on the host under its id.
        const back = agentCall(&m, arena, "agent_attach", "{\"agent\":\"claude-gone\",\"relaunch\":true,\"timeout_ms\":45000}", "gone: relaunch", false, 60_000);
        expectFact(back, "attach", "relaunched", "gone: relaunched");
        const recalled = agentCall(&m, arena, "agent_send", "{\"agent\":\"claude-gone\",\"text\":\"recall\",\"timeout_ms\":20000}", "gone: recall", false, 45_000);
        expectFact(recalled, "message", "first prompt was: before the loss", "gone: the relaunch resumed the conversation");

        // An opencode agent on the same host: its API rides this server's
        // own port forward, which outlives the host's reboot.
        const oc = agentCall(&m, arena, "agent_open", "{\"app\":\"opencode\",\"name\":\"oc-gone\",\"host\":\"fakehost\",\"binary\":\"sk-fake-opencode\",\"timeout_ms\":45000}", "gone: agent_open opencode", false, 60_000);
        if (!oc.get("ready").?.bool) fail("gone: the remote opencode is not ready");
        const oc_id = arena.dupe(u8, scStr(oc, "agent", "gone: agent_open opencode")) catch fail("oom");
        const oc_sent = agentCall(&m, arena, "agent_send", "{\"agent\":\"oc-gone\",\"text\":\"before the reboot\",\"timeout_ms\":20000}", "gone: opencode prompt", false, 45_000);
        expectFact(oc_sent, "outcome", "done", "gone: opencode answers before the reboot");

        // The host reboots while the link is down: a fresh daemon that has
        // neither the session nor a record of it.
        cutRemoteLink(down, rt_env);
        const lost2 = agentCall(&m, arena, "agent_wait", "{\"agent\":\"claude-gone\",\"timeout_ms\":20000}", "gone: agent_wait lost again", false, 45_000);
        expectFact(lost2, "outcome", "connection_lost", "gone: lost again");
        killUnderRt(rrt, allocator, c.SIGKILL);
        _ = c.waitpid(rpid, null, 0);
        _ = c.usleep(500_000);
        _ = c.unlink((std.fmt.allocPrintSentinel(arena, "{s}", .{rsock}, 0) catch fail("oom")).ptr);
        rpid = startRemoteDaemon(rrt, rsock);
        _ = c.unlink(down.ptr);
        const rebooted = agentCall(&m, arena, "agent_wait", "{\"agent\":\"claude-gone\",\"timeout_ms\":30000}", "gone: agent_wait after the reboot", false, 45_000);
        expectFact(rebooted, "outcome", "exited", "gone: a rebooted host's fresh daemon ends the agent");
        expectFact(rebooted, "gone_reason", "unknown", "gone: a fresh daemon keeps no record");
        if (!rebooted.get("relaunchable").?.bool) fail("gone: not relaunchable after the reboot");
        {
            const until = nowMs() + 30_000;
            while (true) {
                const l = agentCall(&m, arena, "agent_list", "{\"detail\":true,\"include_exited\":true}", "gone: agent_list after the reboot", false, 15_000);
                var oc_exited = false;
                for (l.get("agents").?.array.items) |it| {
                    if (std.mem.eql(u8, it.object.get("agent").?.string, oc_id) and std.mem.eql(u8, it.object.get("state").?.string, "exited")) oc_exited = true;
                }
                if (oc_exited) break;
                if (nowMs() > until) fail("gone: the remote opencode never read as exited after the reboot");
                _ = c.usleep(500_000);
            }
        }
        // Relaunched under the same id and name, its forward set up again
        // (the dead agent's forward session still held the name).
        const oc_back = agentCall(&m, arena, "agent_attach", "{\"agent\":\"oc-gone\",\"relaunch\":true,\"timeout_ms\":45000}", "gone: relaunch opencode", false, 60_000);
        expectFact(oc_back, "attach", "relaunched", "gone: opencode relaunched");
        expectFact(oc_back, "agent", oc_id, "gone: opencode keeps its id");
        expectFact(oc_back, "name", "oc-gone", "gone: opencode keeps its name");
        const oc_after = agentCall(&m, arena, "agent_send", "{\"agent\":\"oc-gone\",\"text\":\"after the reboot\",\"timeout_ms\":20000}", "gone: opencode prompt after relaunch", false, 45_000);
        expectFact(oc_after, "outcome", "done", "gone: the relaunched opencode answers");
        // This server's own gone entry never blocks its relaunch: no takeover.
        const cl_back = agentCall(&m, arena, "agent_attach", "{\"agent\":\"claude-gone\",\"relaunch\":true,\"timeout_ms\":45000}", "gone: relaunch claude after the reboot", false, 60_000);
        expectFact(cl_back, "attach", "relaunched", "gone: claude relaunched without takeover");
        if (eventKinds(cl_back, "done") != 0) fail("gone: the relaunch result replays an old done");
        // The fake reprints its last past turn only after it is ready.
        _ = c.usleep(3_500_000);
        const old_final = agentCall(&m, arena, "agent_read", "{\"agent\":\"claude-gone\",\"final\":true}", "gone: agent_read final after relaunch", false, 15_000);
        if (old_final.get("records").?.array.items.len != 0 or eventKinds(old_final, "done") != 0) {
            say(std.json.Stringify.valueAlloc(arena, old_final.get("records").?, .{}) catch "?");
            fail("gone: agent_read final after a relaunch hands out an old message as new");
        }
        // What it answers next is news again.
        const fresh = agentCall(&m, arena, "agent_send", "{\"agent\":\"claude-gone\",\"text\":\"after the reboot\",\"timeout_ms\":20000}", "gone: claude prompt after relaunch", false, 45_000);
        expectFact(fresh, "message", "echo: after the reboot", "gone: the relaunched claude's answer is delivered");
        _ = agentCall(&m, arena, "agent_close", "{\"agent\":\"oc-gone\"}", "gone: agent_close opencode", false, 15_000);
        _ = agentCall(&m, arena, "agent_close", "{\"agent\":\"claude-gone\"}", "gone: agent_close", false, 15_000);
        m.closeStdinWait();
        say("smoke-mcp: agents over ssh: a reconnect that finds the session closed, or a rebooted host, ends the agent as relaunchable; an unreachable host stays disconnected; both apps relaunch after a reboot under their id and name, nothing old handed out ok");
    }
    _ = c.kill(rpid, c.SIGTERM);
    _ = c.waitpid(rpid, null, 0);
}
