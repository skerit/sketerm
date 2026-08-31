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
const pathz = @import("util/pathz.zig");
const lifetime = @import("util/lifetime.zig");
const muxclient = @import("mux/client.zig");
const wire = @import("mux/wire.zig");
const panelstore = @import("ipc/panelstore.zig");
const protocol = @import("ipc/protocol.zig");
const webproto = @import("web/protocol.zig");
const netpolicy = @import("web/netpolicy.zig");
const version = @import("version.zig");
const smoke_tls = @import("smoke_tls.zig");
const wlcomp = @import("wlhost/compositor.zig");
const wlpipe = @import("wlhost/pipe.zig");

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
        var in_pipe: [2]c_int = undefined; // parent→child stdin
        var out_pipe: [2]c_int = undefined; // child→parent stdout
        if (c.pipe(&in_pipe) != 0 or c.pipe(&out_pipe) != 0) fail("pipe");
        // Build argv before fork (no allocation between fork and exec).
        var argv_buf: [8:null]?[*:0]const u8 = @splat(null);
        argv_buf[0] = exe;
        argv_buf[1] = "mcp";
        for (extra, 0..) |e, i| argv_buf[2 + i] = e;
        const pid = c.fork();
        if (pid < 0) fail("fork");
        if (pid == 0) {
            _ = c.dup2(in_pipe[0], 0);
            _ = c.dup2(out_pipe[1], 1);
            _ = c.close(in_pipe[0]);
            _ = c.close(in_pipe[1]);
            _ = c.close(out_pipe[0]);
            _ = c.close(out_pipe[1]);
            _ = c.execv(exe, @ptrCast(@constCast(&argv_buf)));
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
    if (c.waitpid(pid, &status, 0) != pid or status != 0) fail("doctor failed");
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
            _ = c.kill(pid, c.SIGTERM);
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
    clearInheritedOrigin();
    g_rt = rt;
    defer killDaemonsUnderRt(rt, allocator);

    const exe = "zig-out/bin/sketerm";
    if (c.access(exe, c.X_OK) != 0) fail("zig-out/bin/sketerm missing (build first)");
    _ = c.setenv("SKETERM_MUX_BIN", "zig-out/bin/sketerm-mux", 1);
    defer _ = c.unsetenv("SKETERM_MUX_BIN");
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
        const poll1 = recvPanelCall(allocator, &presenter, 15_000);
        replyPanel(&presenter, poll1, "{\"ok\":true,\"events\":[],\"dropped\":1}");
        poll1.deinit(allocator);
        const poll2 = recvPanelCall(allocator, &presenter, 15_000);
        replyPanel(&presenter, poll2, "{\"ok\":true,\"events\":[{\"component\":\"t\",\"kind\":\"click\",\"value\":\"ok\",\"ts\":42}],\"dropped\":0}");
        poll2.deinit(allocator);
        const waited = m.recvLine(15_000);
        if (std.mem.indexOf(u8, waited, "\"value\":\"ok\"") == null or
            std.mem.indexOf(u8, waited, "\"dropped\":1") == null)
            fail("repeated relayed ui_wait_event polls lost state");

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
            webStage(allocator, exe, rt);
            say("smoke-mcp: headless web tools ok");
            webPolicyStage(allocator, exe, rt);
            say("smoke-mcp: enforced network policy (real CEF) ok");
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
    if (std.mem.indexOf(u8, opened, "\"view\":1") == null)
        fail("web_open did not hand back a headless view handle in structuredContent");
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

    // Two views exist now, and the newest is what a handle-less call
    // means: web_tabs must SAY so rather than leaving it to be guessed.
    const tabs2 = m.callTool("web_tabs", "{}");
    if (std.mem.indexOf(u8, tabs2, "\"view\":2") == null)
        fail("web_tabs does not list the second headless view");
    if (std.mem.indexOf(u8, tabs2, "\"current\":true") == null)
        fail("web_tabs does not mark the current view");
    if (std.mem.indexOf(u8, tabs2, "* = the view a web_* call with no 'pane' addresses") == null)
        fail("web_tabs does not say which view a handle-less call addresses");
    // Addressing the FIRST view explicitly makes it current again.
    const back1 = m.callTool("web_read", "{\"pane\":1}");
    if (std.mem.indexOf(u8, back1, "HEADLESS-READ-MARKER") == null)
        fail("web_read against an explicit handle did not reach that view");
    const tabs3 = m.callTool("web_tabs", "{}");
    const cur_at = std.mem.indexOf(u8, tabs3, "\"current\":true") orelse
        fail("web_tabs stopped marking a current view");
    if (std.mem.lastIndexOf(u8, tabs3[0..cur_at], "\"view\":1") == null)
        fail("an explicit handle did not become the current view");

    // web_tabs names the backend and the handle kind honestly.
    const tabs = m.callTool("web_tabs", "{}");
    if (std.mem.indexOf(u8, tabs, "\"backend\":\"headless\"") == null or
        std.mem.indexOf(u8, tabs, "\"view\":1") == null)
        fail("web_tabs does not list the headless view");

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
            const wrote = m.callTool("web_eval", "{\"code\":\"" ++ COOKIE ++ "\"}");
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
            const closed = m.callTool("web_close", "{}");
            if (std.mem.indexOf(u8, closed, "\"profile\":\"smoke\"") == null or
                std.mem.indexOf(u8, closed, "\"profile_released\":false") == null)
                fail("web_close did not report that a named profile keeps its storage");
            m.sendTool("web_open", std.fmt.bufPrint(&args_buf, "{{\"url\":\"{s}\",\"profile\":\"smoke\"}}", .{origin}) catch unreachable);
            if (std.mem.indexOf(u8, m.recvLine(60_000), "isError") != null) fail("could not reopen the profile");
            const reread = m.callTool("web_eval", "{\"code\":\"document.cookie\"}");
            if (std.mem.indexOf(u8, reread, "smoke=inprofile") == null)
                fail("the profile's cookie did not survive web_close (its jar is not persistent)");

            // Isolation: the DEFAULT jar has never seen that cookie.
            m.sendTool("web_open", std.fmt.bufPrint(&args_buf, "{{\"url\":\"{s}\"}}", .{origin}) catch unreachable);
            if (std.mem.indexOf(u8, m.recvLine(60_000), "isError") != null) fail("could not open a default-jar view");
            const plain = m.callTool("web_eval", "{\"code\":\"document.cookie\"}");
            if (std.mem.indexOf(u8, plain, "smoke=inprofile") != null)
                fail("a profile's cookie leaked into the shared default jar");

            // An ephemeral identity is isolated too, and goes away with
            // its view.
            m.sendTool("web_open", std.fmt.bufPrint(&args_buf, "{{\"url\":\"{s}\",\"ephemeral\":true}}", .{origin}) catch unreachable);
            const eph = m.recvLine(60_000);
            if (std.mem.indexOf(u8, eph, "isError") != null) fail("could not open an ephemeral view");
            if (std.mem.indexOf(u8, eph, "\"profile_kind\":\"ephemeral\"") == null)
                fail("web_open did not report the ephemeral identity");
            const eph_cookie = m.callTool("web_eval", "{\"code\":\"document.cookie\"}");
            if (std.mem.indexOf(u8, eph_cookie, "smoke=inprofile") != null)
                fail("a profile's cookie leaked into an ephemeral identity");
            const eph_closed = m.callTool("web_close", "{}");
            if (std.mem.indexOf(u8, eph_closed, "\"profile_released\":true") == null)
                fail("closing the last ephemeral view did not destroy its identity");

            // Reset is refused while the profile is open...
            const busy = m.callTool("web_profile_reset", "{\"profile\":\"smoke\"}");
            if (std.mem.indexOf(u8, busy, "\"code\":\"conflict\"") == null)
                fail("web_profile_reset erased a profile that was in use");
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

/// A viewer of the MCP's web session: a replica compositor fed from
/// the attach's `wayland_native` channel, recording what the presenter
/// showed. The same shape the GUI's app host and appdrive use.
const PresenterWatch = struct {
    allocator: std.mem.Allocator,
    replica: wlcomp.Compositor,
    chan: u32 = 0,
    sid: u32 = 0,
    frames: usize = 0,
    w: i32 = 0,
    h: i32 = 0,
    center: [4]u8 = .{ 0, 0, 0, 0 },
    title: [128]u8 = undefined,
    title_len: usize = 0,

    fn init(allocator: std.mem.Allocator) PresenterWatch {
        var replica = wlcomp.Compositor.init(allocator, .{}) catch fail("presenter watch: replica init");
        replica.lenient = true;
        return .{ .allocator = allocator, .replica = replica };
    }

    /// Register the callbacks once the struct sits at its final address.
    fn bind(self: *PresenterWatch) void {
        self.replica.view = .{ .ctx = self, .toplevel_frame = onFrame, .toplevel_title = onTitle };
    }

    fn deinit(self: *PresenterWatch) void {
        self.replica.deinit();
    }

    fn onFrame(ctx: ?*anyopaque, surface: u32, w: i32, h: i32, _: i32, _: i32, _: i32, _: u32, pixels: []const u8) void {
        const self: *PresenterWatch = @ptrCast(@alignCast(ctx.?));
        self.sid = surface;
        self.frames += 1;
        self.w = w;
        self.h = h;
        if (w <= 0 or h <= 0) return;
        const cx: usize = @intCast(@divTrunc(w, 2));
        const cy: usize = @intCast(@divTrunc(h, 2));
        const off = (cy * @as(usize, @intCast(w)) + cx) * 4;
        if (off + 4 <= pixels.len) @memcpy(&self.center, pixels[off..][0..4]);
    }

    fn onTitle(ctx: ?*anyopaque, _: u32, title: []const u8) void {
        const self: *PresenterWatch = @ptrCast(@alignCast(ctx.?));
        self.title_len = @min(title.len, self.title.len);
        @memcpy(self.title[0..self.title_len], title[0..self.title_len]);
    }

    fn titleSlice(self: *const PresenterWatch) []const u8 {
        return self.title[0..self.title_len];
    }

    /// One mux frame from the viewer connection.
    fn feed(self: *PresenterWatch, f: muxclient.Conn.OwnedFrame) void {
        switch (f.ftype) {
            .chan_open => {
                const open = wire.decodeChanOpen(f.payload) orelse return;
                if (open.kind != .wayland_native) return;
                self.chan = open.id;
                self.replica.conn_id = open.id;
            },
            .chan_data => {
                if (self.chan == 0 or f.payload.len < 4) return;
                if ((wire.decodeChanId(f.payload) orelse return) != self.chan) return;
                self.replica.feed(f.payload[4..]) catch fail("presenter watch: the replica refused a unit");
                self.replica.clearOut();
            },
            else => {},
        }
    }

    /// Ship seat intents toward the session's brain.
    fn intents(self: *PresenterWatch, conn: *muxclient.Conn, units: []const u8) void {
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.allocator);
        var idb: [4]u8 = undefined;
        std.mem.writeInt(u32, &idb, self.chan, .little);
        payload.appendSlice(self.allocator, &idb) catch fail("oom");
        payload.appendSlice(self.allocator, units) catch fail("oom");
        conn.sendFrame(.chan_data, payload.items) catch fail("presenter watch: could not send seat intents");
    }
};

fn presenterCenterMatches(px: [4]u8) bool {
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const d = @as(i32, px[i]) - @as(i32, PRESENTER_BGR[i]);
        if (d > 8 or d < -8) return false;
    }
    return true;
}

/// Pump the viewer until `cond` holds or the deadline passes.
fn presenterPumpUntil(
    conn: *muxclient.Conn,
    watch: *PresenterWatch,
    allocator: std.mem.Allocator,
    deadline_ms: i64,
    comptime cond: fn (*const PresenterWatch) bool,
) bool {
    while (nowMs() < deadline_ms) {
        if (cond(watch)) return true;
        const f = conn.recvFrameFor(200) catch continue;
        defer f.deinit(allocator);
        watch.feed(f);
    }
    return cond(watch);
}

fn presenterHasChan(w: *const PresenterWatch) bool {
    return w.chan != 0;
}

fn presenterPainted(w: *const PresenterWatch) bool {
    return w.frames > 0 and presenterCenterMatches(w.center) and std.mem.eql(u8, w.titleSlice(), "PRESENTER-PAGE");
}

fn presenterClicked(w: *const PresenterWatch) bool {
    return std.mem.eql(u8, w.titleSlice(), "PRESENTER-CLICKED");
}

fn presenterKeyed(w: *const PresenterWatch) bool {
    return std.mem.eql(u8, w.titleSlice(), "PRESENTER-KEY-a");
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

    // A viewer, the way the GUI's Watch button attaches: hello, attach
    // with the controller lease (kind mcp, control) so its seat intents
    // are applied rather than dropped.
    var conn = muxclient.Conn.connectProbed(allocator, mux_sock) catch fail("presenter: could not connect a viewer to the private daemon");
    defer conn.deinit();
    conn.setNonBlocking();
    conn.sendJson(.hello, .{ .proto = wire.PROTO_VERSION }) catch fail("presenter: viewer hello");
    (conn.recvExpectFor(&.{.welcome}, 15_000) catch fail("presenter: viewer got no welcome")).deinit(allocator);
    conn.sendAttach(session, .{ .kind = "mcp", .control = true }) catch fail("presenter: viewer attach");
    (conn.recvExpectFor(&.{.snapshot}, 15_000) catch fail("presenter: viewer attach got no snapshot")).deinit(allocator);

    var watch = PresenterWatch.init(allocator);
    defer watch.deinit();
    watch.bind();
    if (!presenterPumpUntil(&conn, &watch, allocator, nowMs() + 20_000, presenterHasChan))
        fail("presenter: the web session announced no wayland_native channel to the viewer");
    if (!presenterPumpUntil(&conn, &watch, allocator, nowMs() + 30_000, presenterPainted)) {
        std.debug.print("smoke-mcp: presenter watch: frames={d} size={d}x{d} center=({d},{d},{d}) title=\"{s}\"\n", .{
            watch.frames, watch.w, watch.h, watch.center[2], watch.center[1], watch.center[0], watch.titleSlice(),
        });
        fail("presenter: no toplevel titled PRESENTER-PAGE painted in the page colour reached the viewer");
    }

    // Click the page through the viewer's seat: enter + motion at the
    // centre, press and release the left button.
    {
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(allocator);
        const cx: f64 = @floatFromInt(@divTrunc(watch.w, 2));
        const cy: f64 = @floatFromInt(@divTrunc(watch.h, 2));
        wlpipe.appendSeatEnter(&units, allocator, watch.sid, cx, cy) catch fail("oom");
        wlpipe.appendSeatMotion(&units, allocator, cx, cy) catch fail("oom");
        wlpipe.appendSeatButton(&units, allocator, 0x110, true) catch fail("oom");
        wlpipe.appendSeatButton(&units, allocator, 0x110, false) catch fail("oom");
        watch.intents(&conn, units.items);
    }
    if (!presenterPumpUntil(&conn, &watch, allocator, nowMs() + 15_000, presenterClicked))
        fail("presenter: a click injected through the viewer's seat never reached the page (title stayed put)");

    // A key, through the hub's keymap: evdev 30 is `a` on every layout
    // the hub ships.
    {
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(allocator);
        wlpipe.appendSeatKbdEnter(&units, allocator, watch.sid) catch fail("oom");
        wlpipe.appendSeatKey(&units, allocator, 30, true) catch fail("oom");
        wlpipe.appendSeatKey(&units, allocator, 30, false) catch fail("oom");
        watch.intents(&conn, units.items);
    }
    if (!presenterPumpUntil(&conn, &watch, allocator, nowMs() + 15_000, presenterKeyed))
        fail("presenter: a key injected through the viewer's seat never reached the page");

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
    if (c.getenv("SKETERM_FAKE_WEB_EXIT") != null) return 1;

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
                    const pol = base ++ [_][]const u8{webproto.CAP_NET_POLICY};
                    const both = ctx ++ [_][]const u8{webproto.CAP_NET_POLICY};
                    const caps: []const []const u8 = if (with_contexts and with_policy)
                        &both
                    else if (with_contexts)
                        &ctx
                    else if (with_policy)
                        &pol
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
                },
                .net_policy_req => {
                    const req = webproto.decode(webproto.NetPolicyReq, frame.payload) catch return 1;
                    var serial: u32 = 0;
                    for (pol_views[0..pol_n], pol_serials[0..pol_n]) |v, s| {
                        if (v == req.view) serial = s;
                    }
                    const exhausted = c.getenv("SKETERM_FAKE_WEB_POLICY_EXHAUST") != null;
                    webproto.encode(allocator, &out, webproto.EvNetPolicy{
                        .view = req.view,
                        .serial = serial,
                        .active = if (serial != 0) 1 else 0,
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
    {
        _ = c.setenv("SKETERM_FAKE_WEB_EXIT", "1", 1);
        defer _ = c.unsetenv("SKETERM_FAKE_WEB_EXIT");
        var m = Mcp.spawn(allocator, exe, &.{});
        m.initialize();
        m.sendTool("web_open", "{\"url\":\"https://smoke.invalid/broken\"}");
        const failed = m.recvLine(60_000);
        if (std.mem.indexOf(u8, failed, "isError") == null or
            std.mem.indexOf(u8, failed, "exited during startup") == null)
            fail("a startup-dead helper did not surface as the described startup error");
        const priv = std.fmt.bufPrint(&args_buf, "{s}/sketerm/mcp-tmp-{d}/mux.sock", .{ rt, m.pid }) catch unreachable;
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
        if (std.mem.indexOf(u8, pj, "\"session\"") != null)
            fail("opt-out still advertised a session in web.json");
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

        // (e) web_close removes the view and RE-HOMES current.
        m.sendTool("web_open", "{\"url\":\"https://smoke.invalid/second\"}");
        _ = m.recvLine(60_000);
        const closed = m.callTool("web_close", "{}");
        if (std.mem.indexOf(u8, closed, "\"closed\":2") == null or
            std.mem.indexOf(u8, closed, "\"current\":1") == null)
            fail("web_close did not close the current view and re-home 'current'");
        const after = m.callTool("web_tabs", "{}");
        if (std.mem.indexOf(u8, after, "\"count\":1") == null or
            std.mem.indexOf(u8, after, "\"view\":2") != null)
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

    // (15) With the capability: net_policy_set travels STRICTLY before
    // the view_create_url naming the same view (there is no ack; frame
    // order is the entire install-before-first-request guarantee).
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
        if (std.mem.indexOf(u8, loosen, "\"code\":\"refused\"") == null or
            std.mem.indexOf(u8, loosen, "LOOSEN") == null)
            fail("web_policy_set applied (or silently ignored) a pure loosening");
        const tighten = m.callTool("web_policy_set", "{\"policy\":{\"max_requests\":3}}");
        if (std.mem.indexOf(u8, tighten, "\"tightened\":[\"max_requests\"]") == null)
            fail("web_policy_set did not tighten the live view's budget");
        // The re-sent, tightened policy is on the wire with a new
        // serial. The send is fire-and-forget (no ack by design), so
        // give the helper a bounded moment to log it.
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
    webStage(allocator, exe, rt);
    say("smoke-mcp: focused headless web tools ok");
    webPolicyStage(allocator, exe, rt);
    say("smoke-mcp: focused enforced network policy ok");
    killDaemonsUnderRt(rt, allocator);
    _ = c.usleep(500_000);
    g_rt = null;
    pathz.removeTree(rt);
    return 0;
}
