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
        const req = std.fmt.bufPrint(&buf, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"initialize\",\"params\":{{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{{}},\"clientInfo\":{{\"name\":\"smoke\",\"version\":\"0\"}}}}}}", .{self.id}) catch unreachable;
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

    fn deinit(self: *FakeGui) void {
        _ = c.close(self.fd);
    }
};

var gui_req: [1 << 18]u8 = undefined;
var gui_req_len: usize = 0;

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
    defer killDaemonsUnderRt(rt, allocator);

    const exe = "zig-out/bin/sketerm";
    if (c.access(exe, c.X_OK) != 0) fail("zig-out/bin/sketerm missing (build first)");

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
    // No GUI here on purpose: this proves the group is reachable on its
    // own, that the live-panel half refuses HONESTLY (naming --shared)
    // instead of hanging or lying, and that the saved half works
    // regardless — including for a session name with a space in it,
    // which the store used to reject outright.
    {
        _ = c.setenv("SKETERM_MCP_TOOLS", "ui", 1);
        defer _ = c.unsetenv("SKETERM_MCP_TOOLS");
        var m = Mcp.spawn(allocator, exe, &.{});
        m.initialize();

        const listed = m.listTools();
        if (!std.mem.endsWith(u8, listed, "}")) fail("tools/list reply truncated");
        for ([_][]const u8{ "ui_show", "ui_patch", "ui_wait_event", "ui_panels", "ui_save", "ui_close", "ui_delete" }) |tool| {
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

        // The live half: no GUI socket, so a described refusal naming
        // the flag that would fix it — never a hang.
        const no_gui = m.callTool("ui_show", "{\"name\":\"p\",\"session\":\"smoke ui\",\"document\":{\"root\":\"t\",\"components\":{\"t\":{\"type\":\"text\",\"text\":\"hi\"}}}}");
        if (std.mem.indexOf(u8, no_gui, "isError") == null or
            std.mem.indexOf(u8, no_gui, "--shared") == null)
            fail("ui_show without a GUI socket did not explain that panels need --shared");

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
            std.mem.indexOf(u8, panels, "--shared") == null)
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
            std.mem.indexOf(u8, caps, "panels_hint") == null or
            std.mem.indexOf(u8, caps, "\\\"ui\\\"") == null)
            fail("capabilities does not report panel availability + the ui group");

        const deleted = m.callTool("ui_delete", "{\"name\":\"vsr\",\"session\":\"smoke ui\"}");
        if (std.mem.indexOf(u8, deleted, "isError") != null) fail("ui_delete failed");
        if (fileExists(panel_file)) fail("ui_delete left the saved document on disk");
        m.closeStdinWait();
        say("smoke-mcp: ui_* panel tools ok");
    }

    // ── Stage 6: ui_show_files, against a stand-in GUI socket ─────
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

        m.closeStdinWait();
        say("smoke-mcp: ui_show_files ok");
    }

    // Retire the durable daemon we started.
    killDaemonsUnderRt(rt, allocator);
    _ = c.usleep(500_000);

    say("smoke-mcp: PASS");
    return 0;
}
