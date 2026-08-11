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
const muxclient = @import("mux/client.zig");
const wire = @import("mux/wire.zig");
const panelstore = @import("ipc/panelstore.zig");
const protocol = @import("ipc/protocol.zig");
const version = @import("version.zig");

fn say(msg: []const u8) void {
    _ = c.write(2, msg.ptr, msg.len);
    _ = c.write(2, "\n", 1);
}

fn fail(comptime msg: []const u8) noreturn {
    say("smoke-mcp: FAIL " ++ msg);
    std.process.exit(1);
}

fn nowMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.tv_sec) * 1000 + @divTrunc(ts.tv_nsec, 1_000_000);
}

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

pub fn main() u8 {
    var gpa = std.heap.DebugAllocator(.{}){};
    const allocator = gpa.allocator();

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
    // App/GUI socket auto-discovery must not find anything; keep the
    // env clean.
    _ = c.unsetenv("SKETERM_SOCKET");
    _ = c.unsetenv("SKETERM_PANE_ID");
    // ...and the panel stage's SESSIONLESS calls must really have no
    // session: run from inside a sketerm pane, the inherited
    // $SKETERM_SESSION would scope them to that pane instead.
    _ = c.unsetenv("SKETERM_SESSION");
    _ = c.unsetenv("SKETERM_SESSION_ORIGIN_ID");
    defer killDaemonsUnderRt(rt, allocator);

    const exe = "zig-out/bin/sketerm";
    if (c.access(exe, c.X_OK) != 0) fail("zig-out/bin/sketerm missing (build first)");
    _ = c.setenv("SKETERM_MUX_BIN", "zig-out/bin/sketerm-mux", 1);
    defer _ = c.unsetenv("SKETERM_MUX_BIN");

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
        if (std.mem.indexOf(u8, tools, "error") != null and std.mem.indexOf(u8, tools, "[]") == null)
            fail("term_list did not return a list");

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
        if (std.mem.indexOf(u8, idle_probe, "\\\"command_sent\\\":false") == null or
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
        if (std.mem.indexOf(u8, silent_ok, "\\\"state\\\":\\\"completed") == null or
            std.mem.indexOf(u8, silent_ok, "\\\"exit_status\\\":0") == null or
            std.mem.indexOf(u8, silent_ok, "shell_integration") == null)
            fail("silent successful command did not complete via OSC 133");

        const status_124 = m.callTool("term_run", "{\"command\":\"timeout 0.1 sh -c 'sleep 1' >/dev/null 2>&1\",\"wait_for\":\"command\",\"output_only\":true}");
        if (std.mem.indexOf(u8, status_124, "\\\"exit_status\\\":124") == null)
            fail("silent timeout command did not return status 124");

        const delayed = m.callTool("term_run", "{\"command\":\"sleep 0.2; printf 'MCP-DELAYED-OUTPUT\\\\n'\",\"wait_for\":\"command\",\"output_only\":true}");
        if (std.mem.indexOf(u8, delayed, "MCP-DELAYED-OUTPUT") == null or
            std.mem.indexOf(u8, delayed, "\\\"state\\\":\\\"completed") == null)
            fail("command completion missed delayed output");

        const command_timeout = m.callTool("term_run", "{\"command\":\"sleep 0.6 >/dev/null 2>&1\",\"wait_for\":\"command\",\"timeout_ms\":100}");
        if (std.mem.indexOf(u8, command_timeout, "\\\"state\\\":\\\"running") == null or
            std.mem.indexOf(u8, command_timeout, "\\\"timed_out\\\":true") == null or
            std.mem.indexOf(u8, command_timeout, "\\\"completion_source\\\":\\\"none") == null)
            fail("command timeout did not report a still-running command");
        const duplicate = m.callTool("term_run", "{\"command\":\"echo MUST-NOT-BE-SENT\",\"wait_for\":\"command\"}");
        if (std.mem.indexOf(u8, duplicate, "term_wait_command") == null or
            std.mem.indexOf(u8, duplicate, "\\\"command_sent\\\":false") == null)
            fail("second command was not rejected while completion remained pending");
        _ = c.usleep(650_000);
        const waited = m.callTool("term_wait_command", "{\"timeout_ms\":1000,\"output_only\":true}");
        if (std.mem.indexOf(u8, waited, "\\\"state\\\":\\\"completed") == null or
            std.mem.indexOf(u8, waited, "\\\"exit_status\\\":0") == null)
            fail("term_wait_command did not finish a timed-out command");

        const no_integration = m.callTool("term_open", "{\"command\":[\"/bin/sh\"]}");
        if (std.mem.indexOf(u8, no_integration, "opened headless terminal 2") == null) fail("plain sh terminal failed");
        const unsupported = m.callTool("term_run", "{\"term\":2,\"command\":\"echo MUST-NOT-RUN\",\"wait_for\":\"command\"}");
        if (std.mem.indexOf(u8, unsupported, "\\\"state\\\":\\\"unsupported") == null or
            std.mem.indexOf(u8, unsupported, "\\\"command_sent\\\":false") == null or
            std.mem.indexOf(u8, unsupported, "\\\"exit_status\\\":null") == null)
            fail("shell-integration absence was not reported safely");

        const signaled = m.callTool("term_run", "{\"term\":1,\"command\":\"exec sh -c 'kill -TERM $$'\",\"wait_for\":\"command\",\"timeout_ms\":3000}");
        if (std.mem.indexOf(u8, signaled, "\\\"exit_status\\\":-15") == null or
            std.mem.indexOf(u8, signaled, "process_tracking") == null)
            fail("signal-killed command did not use tracked process status");

        // Command mode straight after term_open: the first prompt mark
        // may not have rendered yet — the bounded wait must cover the
        // race instead of misreporting "unsupported".
        const fresh = m.callTool("term_open", "{\"command\":[\"/bin/bash\"],\"cols\":80,\"rows\":24}");
        if (std.mem.indexOf(u8, fresh, "opened headless terminal 3") == null) fail("fresh bash terminal failed");
        const fresh_run = m.callTool("term_run", "{\"term\":3,\"command\":\"true\",\"wait_for\":\"command\"}");
        if (std.mem.indexOf(u8, fresh_run, "\\\"state\\\":\\\"completed") == null or
            std.mem.indexOf(u8, fresh_run, "\\\"exit_status\\\":0") == null)
            fail("command mode raced the first prompt mark on a fresh terminal");

        // A foreground command started in idle mode must block a
        // command-mode send (its D would be misattributed), and the
        // rejection must not send the command.
        _ = m.callTool("term_run", "{\"term\":3,\"command\":\"sleep 0.5 >/dev/null 2>&1\",\"quiet_ms\":100,\"timeout_ms\":2000}");
        const busy = m.callTool("term_run", "{\"term\":3,\"command\":\"echo MUST-NOT-BE-SENT-BUSY\",\"wait_for\":\"command\"}");
        if (std.mem.indexOf(u8, busy, "\\\"command_sent\\\":false") == null or
            std.mem.indexOf(u8, busy, "outside command mode") == null)
            fail("busy shell did not reject a command-mode send");
        _ = c.usleep(600_000);
        const after_busy = m.callTool("term_run", "{\"term\":3,\"command\":\"echo BUSY-CLEARED\",\"wait_for\":\"command\",\"output_only\":true}");
        if (std.mem.indexOf(u8, after_busy, "BUSY-CLEARED") == null or
            std.mem.indexOf(u8, after_busy, "\\\"state\\\":\\\"completed") == null)
            fail("command mode did not recover once the busy command finished");

        // ── capabilities preflight ────────────────────────────────
        const caps = m.callTool("capabilities", "{}");
        if (std.mem.indexOf(u8, caps, "\\\"mode\\\":\\\"isolated\\\"") == null or
            std.mem.indexOf(u8, caps, "\\\"headless_terminals\\\":true") == null or
            std.mem.indexOf(u8, caps, "\\\"ocr\\\":") == null)
            fail("capabilities report incomplete");

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
            const hx1 = std.mem.indexOf(u8, h1, "sha256=") orelse fail("file_hash missing digest");
            const hx2 = std.mem.indexOf(u8, h2, "sha256=") orelse fail("file_hash missing digest 2");
            if (!std.mem.eql(u8, h1[hx1 + 7 .. hx1 + 71], h2[hx2 + 7 .. hx2 + 71]))
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
        if (std.mem.indexOf(u8, nt, "\\\"headless\\\":true") == null or
            std.mem.indexOf(u8, nt, "\\\"term\\\":") == null)
            fail("new_tab did not fall back to a headless terminal");

        // ── term_exec: sentinel-based structured exec ─────────────
        const ex1 = m.callTool("term_exec", "{\"term\":3,\"command\":\"echo EXEC-STRUCT; false\"}");
        if (std.mem.indexOf(u8, ex1, "\\\"completed\\\":true") == null or
            std.mem.indexOf(u8, ex1, "\\\"exit_status\\\":1") == null or
            std.mem.indexOf(u8, ex1, "EXEC-STRUCT") == null)
            fail("term_exec did not return structured output + status");
        // Works without shell integration too (plain /bin/sh, term 2).
        const ex2 = m.callTool("term_exec", "{\"term\":2,\"command\":\"echo SH-EXEC-OK\"}");
        if (std.mem.indexOf(u8, ex2, "\\\"completed\\\":true") == null or
            std.mem.indexOf(u8, ex2, "\\\"exit_status\\\":0") == null or
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
        if (std.mem.indexOf(u8, under_e, "\\\"completed\\\":true") == null or
            std.mem.indexOf(u8, under_e, "\\\"exit_status\\\":1") == null)
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
        if (std.mem.indexOf(u8, blocked, "\\\"pending\\\":true") == null or
            std.mem.indexOf(u8, blocked, "\\\"interactive_prompt\\\":true") == null or
            std.mem.indexOf(u8, blocked, "\\\"tracker\\\":\\\"") == null or
            std.mem.indexOf(u8, blocked, "\\\"screen\\\":\\\"") == null or
            std.mem.indexOf(u8, blocked, "Continue?") == null)
            fail("blocked interactive command did not surface pending state + screen");
        if (std.mem.indexOf(u8, blocked, "\\\"timed_out\\\":true") != null)
            fail("interactive early-return was misreported as a timeout");
        _ = m.callTool("term_send_text", "{\"term\":3,\"text\":\"y\",\"enter\":true}");
        const resumed = m.callTool("term_exec_wait", "{\"term\":3,\"timeout_ms\":10000}");
        if (std.mem.indexOf(u8, resumed, "\\\"completed\\\":true") == null or
            std.mem.indexOf(u8, resumed, "\\\"exit_status\\\":0") == null or
            std.mem.indexOf(u8, resumed, "GOT:y") == null)
            fail("term_exec_wait did not resume the answered command");
        // output_file: full output to a local file, tail inline.
        var of_buf: [640]u8 = undefined;
        const of_args = std.fmt.bufPrint(&of_buf, "{{\"term\":3,\"command\":\"seq 1 500\",\"output_file\":\"{s}/exec-out.txt\"}}", .{rt}) catch unreachable;
        const filed = m.callTool("term_exec", of_args);
        if (std.mem.indexOf(u8, filed, "\\\"output_file\\\":") == null or
            std.mem.indexOf(u8, filed, "\\\"output_bytes\\\":") == null)
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
        if (std.mem.indexOf(u8, psq, "\\\"exit_status\\\":0") == null or
            std.mem.indexOf(u8, psq, "\\\"output\\\":\\\"1\\\\n") == null)
            fail("the exec transport leaked the command onto a process command line (ps saw it)");

        // ── term_wait_exit: real process exit, not output idle ────
        const t4 = m.callTool("term_open", "{\"command\":[\"sh\",\"-c\",\"sleep 0.3; exit 7\"]}");
        if (std.mem.indexOf(u8, t4, "opened headless terminal") == null) fail("short-lived term_open failed");
        const wexit = m.callTool("term_wait_exit", "{\"term\":5,\"timeout_ms\":5000}");
        if (std.mem.indexOf(u8, wexit, "\\\"exited\\\":true") == null or
            std.mem.indexOf(u8, wexit, "\\\"exit_status\\\":7") == null)
            fail("term_wait_exit missed the real exit status");
        const listing = m.callTool("term_list", "{}");
        if (std.mem.indexOf(u8, listing, "\\\"exit_status\\\":7") == null)
            fail("term_list does not show the exit status");
        const post_read = m.callTool("term_read", "{\"term\":5}");
        if (std.mem.indexOf(u8, post_read, "process exited with status 7") == null)
            fail("term_read on an exited terminal lacks the exit banner");

        // ── upload_file (local): checksum + atomic rename ─────────
        var src_buf: [512]u8 = undefined;
        var dst_buf: [512]u8 = undefined;
        const xsrc = std.fmt.bufPrintZ(&src_buf, "{s}/xfer-src.bin", .{rt}) catch unreachable;
        const xdst = std.fmt.bufPrint(&dst_buf, "{s}/xfer-dst.bin", .{rt}) catch unreachable;
        const xf = c.fopen(xsrc.ptr, "wb") orelse fail("cannot create transfer source");
        _ = c.fwrite("transfer-payload", 1, 16, xf);
        _ = c.fclose(xf);
        var xargs_buf: [1200]u8 = undefined;
        const xargs = std.fmt.bufPrint(&xargs_buf, "{{\"local_path\":\"{s}\",\"remote_path\":\"{s}\"}}", .{ xsrc, xdst }) catch unreachable;
        const up = m.callTool("upload_file", xargs);
        if (std.mem.indexOf(u8, up, "\\\"ok\\\":true") == null or
            std.mem.indexOf(u8, up, "\\\"verified\\\":true") == null or
            std.mem.indexOf(u8, up, "\\\"atomic\\\":true") == null)
            fail("local upload_file did not verify");
        if (!fileExists(xdst)) fail("upload_file destination missing");

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
        if (std.mem.indexOf(u8, caps, "\\\"tool_policy\\\"") == null or
            std.mem.indexOf(u8, caps, "app:ro, term_list") == null or
            std.mem.indexOf(u8, caps, "SKETERM_MCP_TOOLS") == null or
            std.mem.indexOf(u8, caps, "\\\"groups_suppressed\\\"") == null or
            std.mem.indexOf(u8, caps, "\\\"panes\\\"") == null or
            std.mem.indexOf(u8, caps, "\\\"files\\\"") == null)
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
            std.mem.indexOf(u8, panels, "\\\"live\\\":null") == null or
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
        if (std.mem.indexOf(u8, caps, "\\\"panels\\\":false") == null or
            std.mem.indexOf(u8, caps, "\\\"panels_store\\\":true") == null or
            std.mem.indexOf(u8, caps, "\\\"scope\\\":\\\"sessionless\\\"") == null or
            std.mem.indexOf(u8, caps, "\\\"state\\\":\\\"no_session_origin\\\"") == null or
            std.mem.indexOf(u8, caps, "\\\"gui_socket\\\":false") == null or
            std.mem.indexOf(u8, caps, "\\\"ui\\\"") == null)
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
        if (std.mem.indexOf(u8, caps, "\\\"panels\\\":true") == null or
            std.mem.indexOf(u8, caps, "\\\"panels_store\\\":true") == null or
            std.mem.indexOf(u8, caps, "\\\"scope\\\":\\\"origin\\\"") == null or
            std.mem.indexOf(u8, caps, "\\\"gui_socket\\\":false") == null or
            std.mem.indexOf(u8, caps, "\\\"selected\\\":\\\"mux_relay\\\"") == null or
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
            std.mem.indexOf(u8, refused, "\\\"mutation_may_have_applied\\\":false") == null or
            std.mem.indexOf(u8, refused, "\\\"resend_safe\\\":true") == null)
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
            std.mem.indexOf(u8, shown, "\\\"panel_id\\\":41") == null)
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
            std.mem.indexOf(u8, listed_live, "\\\"live\\\":[") == null)
            fail("ui_panels did not return the relayed live inventory");

        m.sendTool("ui_save", "{\"name\":\"relayed\",\"panel_id\":41}");
        const get_call = recvPanelCall(allocator, &presenter, 15_000);
        if (std.mem.indexOf(u8, get_call.json, "\"cmd\":\"panel-get\"") == null)
            fail("ui_save without document did not use the origin relay");
        replyPanel(&presenter, get_call, "{\"ok\":true,\"document\":\"{\\\"title\\\":\\\"Relay live\\\",\\\"root\\\":\\\"t\\\",\\\"components\\\":{\\\"t\\\":{\\\"type\\\":\\\"text\\\",\\\"text\\\":\\\"through mux\\\"}}}\"}");
        get_call.deinit(allocator);
        const saved_live = m.recvLine(15_000);
        if (std.mem.indexOf(u8, saved_live, "isError") != null or
            std.mem.indexOf(u8, saved_live, "\\\"saved\\\":\\\"relayed\\\"") == null)
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
        if (std.mem.indexOf(u8, renamed_show, "\\\"panel_id\\\":42") == null or
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
        if (std.mem.indexOf(u8, waited, "\\\"value\\\":\\\"ok\\\"") == null or
            std.mem.indexOf(u8, waited, "\\\"dropped\\\":1") == null)
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
            std.mem.indexOf(u8, missing_result, "\\\"showing\\\":true") != null)
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
            std.mem.indexOf(u8, zero_result, "\\\"showing\\\":true") != null)
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
        if (std.mem.indexOf(u8, recovered, "\\\"panel_id\\\":43") == null)
            fail("fresh pooled panel relay did not recover");

        // A real long-lived app tool still starts the MCP private daemon, not
        // the panel origin. Inspect it while alive so a fast /bin/true cannot
        // make the isolation assertion pass after all state has disappeared.
        const app = m.callTool("launch_app", "{\"command\":[\"/bin/sh\",\"-c\",\"sleep 30\"],\"wait_for\":\"exit\",\"wait_ms\":100,\"stable_ms\":0}");
        if (std.mem.indexOf(u8, app, "\\\"app\\\":1") == null or
            std.mem.indexOf(u8, app, "\\\"pid\\\"") == null or
            std.mem.indexOf(u8, app, "\\\"exited\\\":true") != null)
            fail("long-lived private launch_app probe was not alive");
        const live_apps = m.callTool("list_apps", "{}");
        if (std.mem.indexOf(u8, live_apps, "\\\"app\\\":1") == null or
            std.mem.indexOf(u8, live_apps, "\\\"pid\\\"") == null or
            std.mem.indexOf(u8, live_apps, "\\\"exited\\\":true") != null)
            fail("list_apps could not inspect the private app while alive");
        var private_buf: [512]u8 = undefined;
        const private_sock = std.fmt.bufPrint(&private_buf, "{s}/sketerm/mcp-tmp-{d}/mux.sock", .{ rt, m.pid }) catch unreachable;
        if (!fileExists(private_sock)) fail("app tool did not start the MCP private daemon");
        if (sessionCount(allocator, &owner) != 1)
            fail("app tool leaked its session onto the panel origin daemon");
        const closed_app = m.callTool("close_app", "{\"app\":1}");
        if (std.mem.indexOf(u8, closed_app, "isError") != null)
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
        if (std.mem.indexOf(u8, absent_caps, "\\\"state\\\":\\\"no_compatible_gui\\\"") == null or
            std.mem.indexOf(u8, absent_caps, "\\\"panels\\\":false") == null or
            std.mem.indexOf(u8, absent_caps, "\\\"panels_store\\\":true") == null or
            std.mem.indexOf(u8, absent_caps, "\\\"scope\\\":\\\"origin\\\"") == null)
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
        if (std.mem.indexOf(u8, rebound, "\\\"panel_id\\\":51") == null)
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
        if (std.mem.indexOf(u8, no_viewer_caps, "\\\"panels\\\":false") == null or
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
        var fenced_active: std.atomic.Value(c_int) = .init(-1);
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
            std.mem.indexOf(u8, caps, "\\\"panels_store\\\":false") == null or
            std.mem.indexOf(u8, caps, "\\\"scope\\\":\\\"unavailable\\\"") == null or
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
            std.mem.indexOf(u8, exact_result, "\\\"panel_id\\\":76") == null or
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
        if (std.mem.indexOf(u8, result, "\\\"panel_id\\\":77") == null or std.mem.indexOf(u8, result, "isError") != null) {
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
            std.mem.indexOf(u8, result, "\\\"panel_id\\\":78") == null or
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
        if (std.mem.indexOf(u8, exact_reply, "\\\"panel_id\\\":81") == null)
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
        if (std.mem.indexOf(u8, default_reply, "\\\"panel_id\\\":82") == null)
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
            std.mem.indexOf(u8, discovered_caps, "\\\"gui_socket_source\\\":\\\"discovered\\\"") == null)
            fail("capabilities confused discovered GUI and default panel transports");
        discovered.sendTool("ui_show", "{\"name\":\"discovered\",\"document\":{\"root\":\"t\",\"components\":{\"t\":{\"type\":\"text\",\"text\":\"must-use-default\"}}}}");
        const discovered_show = recvPanelCall(allocator, &default_presenter, 15_000);
        if (std.mem.indexOf(u8, discovered_show.json, "must-use-default") == null)
            fail("discovered GUI displaced the canonical panel relay");
        replyPanel(&default_presenter, discovered_show, "{\"ok\":true,\"panel_id\":83}");
        discovered_show.deinit(allocator);
        const discovered_show_reply = discovered.recvLine(15_000);
        if (std.mem.indexOf(u8, discovered_show_reply, "\\\"panel_id\\\":83") == null)
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
            std.mem.indexOf(u8, cmp_reply, "\\\"panel_id\\\":4") == null or
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
        if (std.mem.indexOf(u8, max_result, "\\\"panel_id\\\":7") == null or
            std.mem.indexOf(u8, max_result, "isError") != null)
            fail("maximum direct panel request did not complete");

        m.closeStdinWait();
        say("smoke-mcp: ui_show_files ok");
    }

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
        const web_bin = c.realpath("zig-out/bin/sketerm-webengine", &bin_buf);
        if (web_bin == null or c.access("zig-out/bin/sketerm-webengine", c.X_OK) != 0) {
            say("smoke-mcp: SKIP web stage (sketerm-webengine not built; `zig build web`)");
        } else {
            _ = c.setenv("SKETERM_WEB_BIN", web_bin, 1);
            defer _ = c.unsetenv("SKETERM_WEB_BIN");
            webStage(allocator, exe, rt);
            say("smoke-mcp: headless web tools ok");
        }
    }

    // Retire the durable daemon we started.
    killDaemonsUnderRt(rt, allocator);
    _ = c.usleep(500_000);

    say("smoke-mcp: PASS");
    return 0;
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

/// Isolated `sketerm mcp` (no GUI, no --shared) driving a real page
/// end to end through the headless web backend.
fn webStage(allocator: std.mem.Allocator, exe: [*:0]const u8, rt: []const u8) void {
    // A local page with a button that mutates a paragraph: enough for
    // snapshot ids, a trusted click, the delta and reader extraction.
    var page_buf: [512]u8 = undefined;
    const page_path = std.fmt.bufPrintZ(&page_buf, "{s}/web-smoke.html", .{rt}) catch unreachable;
    {
        const f = c.fopen(page_path.ptr, "wb") orelse fail("cannot write web smoke page");
        const html =
            "<html><head><title>Headless Smoke</title></head><body>" ++
            "<article><h1>Headless Article</h1><p>HEADLESS-READ-MARKER prose for the reader tool.</p></article>" ++
            "<button id=b onclick=\"document.getElementById('p').textContent='AFTERCLICK'\">PressMe</button>" ++
            "<p id=p>BEFORECLICK</p></body></html>";
        _ = c.fwrite(html.ptr, 1, html.len, f);
        _ = c.fclose(f);
    }

    var m = Mcp.spawn(allocator, exe, &.{});
    m.initialize();

    // capabilities must say the tools work HERE, headlessly — the old
    // report steered assistants to --shared / launch_app instead.
    const caps = m.callTool("capabilities", "{}");
    if (std.mem.indexOf(u8, caps, "\\\"web\\\":true") == null or
        std.mem.indexOf(u8, caps, "\\\"web_backend\\\":\\\"headless\\\"") == null)
        fail("capabilities does not report the headless web backend");

    // web_open: spawns the helper lazily, loads the page, returns a
    // first snapshot with stable node ids.
    var args_buf: [1024]u8 = undefined;
    m.sendTool("web_open", std.fmt.bufPrint(&args_buf, "{{\"url\":\"file://{s}\"}}", .{page_path}) catch unreachable);
    const opened = m.recvLine(60_000);
    if (std.mem.indexOf(u8, opened, "isError") != null) fail("web_open failed headlessly (the NoGuiSocket regression)");
    if (std.mem.indexOf(u8, opened, "\\\"view\\\":1") == null)
        fail("web_open did not hand back a headless view handle");
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

    // web_act: a trusted click, whose reply carries the DELTA showing
    // the paragraph the click mutated.
    const acted = m.callTool("web_act", std.fmt.bufPrint(&args_buf, "{{\"id\":{d},\"action\":\"click\"}}", .{btn}) catch unreachable);
    if (std.mem.indexOf(u8, acted, "\\\"acted\\\":true") == null)
        fail("web_act click did not act");
    if (std.mem.indexOf(u8, acted, "AFTERCLICK") == null)
        fail("web_act's delta does not show the mutated paragraph");

    // Mutate via eval, then prove a FOLLOW-UP web_snapshot returns a
    // delta containing exactly the changed node.
    const evald = m.callTool("web_eval", "{\"code\":\"document.getElementById('p').textContent='EVALMUTATION'; 40+2\"}");
    if (std.mem.indexOf(u8, evald, "\\\"evaluated\\\":true") == null or
        std.mem.indexOf(u8, evald, "42") == null)
        fail("web_eval did not run in the page");
    const snap = m.callTool("web_snapshot", "{}");
    if (std.mem.indexOf(u8, snap, "\\\"kind\\\":\\\"delta\\\"") == null or
        std.mem.indexOf(u8, snap, "EVALMUTATION") == null)
        fail("the follow-up snapshot's delta does not carry the changed node");

    // web_read: reader-mode extraction of the article.
    const read = m.callTool("web_read", "{}");
    if (std.mem.indexOf(u8, read, "HEADLESS-READ-MARKER") == null)
        fail("web_read did not extract the article text");

    // web_screenshot: a real PNG from the helper's software frame
    // (base64 "iVBOR..." is the PNG magic).
    const shot = m.callTool("web_screenshot", "{}");
    if (std.mem.indexOf(u8, shot, "\\\"image\\\"") == null and std.mem.indexOf(u8, shot, "\"image\"") == null)
        fail("web_screenshot returned no image block");
    if (std.mem.indexOf(u8, shot, "iVBOR") == null)
        fail("web_screenshot's payload is not a PNG");

    // web_tabs names the backend and the handle kind honestly.
    const tabs = m.callTool("web_tabs", "{}");
    if (std.mem.indexOf(u8, tabs, "\\\"backend\\\":\\\"headless\\\"") == null or
        std.mem.indexOf(u8, tabs, "\\\"view\\\":1") == null)
        fail("web_tabs does not list the headless view");

    m.closeStdinWait();
    // Ephemeral teardown must have reaped the helper's instance dir.
    if (fileExists(std.fmt.bufPrint(&probe_buf, "{s}/sketerm/mcp-tmp-{d}", .{ rt, m.pid }) catch unreachable))
        fail("instance dir (with the web helper's socket) survived teardown");
}
