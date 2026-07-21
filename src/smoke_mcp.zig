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
        self.id += 1;
        var buf: [4096]u8 = undefined;
        const req = std.fmt.bufPrint(&buf, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"tools/call\",\"params\":{{\"name\":\"{s}\",\"arguments\":{s}}}}}", .{ self.id, name, args_json }) catch fail("req too long");
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
    // App/GUI socket auto-discovery must not find anything; keep the
    // env clean.
    _ = c.unsetenv("SKETERM_SOCKET");
    defer killDaemonsUnderRt(rt, allocator);

    const exe = "zig-out/bin/sketerm";
    if (c.access(exe, c.X_OK) != 0) fail("zig-out/bin/sketerm missing (build first)");

    // ── Stage 1: ephemeral isolation + headless terminal ──────────
    {
        var m = Mcp.spawn(allocator, exe, &.{});
        m.initialize();
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
            fail("term_run idle mode waited for command completion");
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

    // Retire the durable daemon we started.
    killDaemonsUnderRt(rt, allocator);
    _ = c.usleep(500_000);

    say("smoke-mcp: PASS");
    return 0;
}
