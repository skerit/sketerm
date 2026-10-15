//! A `sketerm mcp` subprocess driven over its stdio (NDJSON JSON-RPC),
//! shared by the rigs that run MCP servers: smoke-mcp, and the peer stage
//! smoke-mux and smoke-broker run. `Mcp(fail)` takes the rig's own
//! `fail(comptime msg) noreturn`, so a broken pipe or a timeout fails the
//! rig that hit it, with that rig's cleanup.

const std = @import("std");
const c = @import("../c.zig").c;
const unsetEnv = @import("../util/env.zig").unset;
const version = @import("../version.zig");
const nowMs = @import("../util/clock.zig").nowMs;

/// Room for the binary, `mcp` and the extra arguments.
const ARGV_MAX = 16;

pub const Options = struct {
    /// Arguments after `mcp`.
    extra: []const [*:0]const u8 = &.{},
    /// Run under a `/bin/sh` that stays the server's parent and carries
    /// these on its own argv (a Claude Code started with a channel
    /// option, as `agentpush.ancestorNamesChannel` reads it). Takes no
    /// `extra`.
    under: ?[]const [*:0]const u8 = null,
    /// Removed from the child's environment, before `set_env` applies.
    unset_env: []const [*:0]const u8 = &.{},
    set_env: []const [2][*:0]const u8 = &.{},
};

pub fn Mcp(comptime fail: anytype) type {
    return struct {
        const Self = @This();

        pid: c.pid_t,
        to_child: c_int, // we write child's stdin
        from_child: c_int, // we read child's stdout
        id: u32 = 0,
        rbuf: std.ArrayList(u8) = .empty,
        allocator: std.mem.Allocator,

        /// The last line `recvLine` returned; valid until its next call.
        var scratch: [1 << 20]u8 = undefined;
        var scratch_len: usize = 0;

        /// Spawn `sketerm mcp <extra...>`.
        pub fn spawn(allocator: std.mem.Allocator, exe: [*:0]const u8, extra: []const [*:0]const u8) Self {
            return spawnWith(allocator, exe, .{ .extra = extra });
        }

        /// Spawn `sketerm mcp` under a `/bin/sh` carrying `parent_args`.
        pub fn spawnUnder(allocator: std.mem.Allocator, exe: [*:0]const u8, parent_args: []const [*:0]const u8) Self {
            return spawnWith(allocator, exe, .{ .under = parent_args });
        }

        pub fn spawnWith(allocator: std.mem.Allocator, exe: [*:0]const u8, opts: Options) Self {
            // Build argv before fork (no allocation between fork and exec).
            var argv_buf: [ARGV_MAX:null]?[*:0]const u8 = @splat(null);
            var path: [*:0]const u8 = exe;
            if (opts.under) |parent_args| {
                if (opts.extra.len > 0) fail("mcpproc: a server under a parent shell takes no extra arguments");
                if (parent_args.len + 4 > ARGV_MAX) fail("mcpproc: too many parent arguments");
                path = "/bin/sh";
                argv_buf[0] = "/bin/sh";
                argv_buf[1] = "-c";
                // Not the last command, so sh does not exec it away.
                argv_buf[2] = "\"$0\" mcp; :";
                argv_buf[3] = exe;
                for (parent_args, 0..) |e, i| argv_buf[4 + i] = e;
            } else {
                if (opts.extra.len + 2 > ARGV_MAX) fail("mcpproc: too many arguments");
                argv_buf[0] = exe;
                argv_buf[1] = "mcp";
                for (opts.extra, 0..) |e, i| argv_buf[2 + i] = e;
            }
            return spawnArgv(allocator, path, &argv_buf, opts);
        }

        fn spawnArgv(allocator: std.mem.Allocator, path: [*:0]const u8, argv_buf: *const [ARGV_MAX:null]?[*:0]const u8, opts: Options) Self {
            var in_pipe: [2]c_int = undefined; // parent->child stdin
            var out_pipe: [2]c_int = undefined; // child->parent stdout
            if (c.pipe(&in_pipe) != 0 or c.pipe(&out_pipe) != 0) fail("pipe");
            const pid = c.fork();
            if (pid < 0) fail("fork");
            if (pid == 0) {
                _ = c.dup2(in_pipe[0], 0);
                _ = c.dup2(out_pipe[1], 1);
                _ = c.close(in_pipe[0]);
                _ = c.close(in_pipe[1]);
                _ = c.close(out_pipe[0]);
                _ = c.close(out_pipe[1]);
                for (opts.unset_env) |k| _ = unsetEnv(k);
                for (opts.set_env) |kv| _ = c.setenv(kv[0], kv[1], 1);
                _ = c.execv(path, @ptrCast(@constCast(argv_buf)));
                c._exit(127);
            }
            _ = c.close(in_pipe[0]);
            _ = c.close(out_pipe[1]);
            // CLOEXEC on our ends: a LATER spawn's child must not inherit
            // this child's stdin write end, or closing it here never
            // reaches EOF while the sibling lives (two concurrent clients).
            _ = c.fcntl(in_pipe[1], c.F_SETFD, c.FD_CLOEXEC);
            _ = c.fcntl(out_pipe[0], c.F_SETFD, c.FD_CLOEXEC);
            return .{ .pid = pid, .to_child = in_pipe[1], .from_child = out_pipe[0], .allocator = allocator };
        }

        pub fn send(self: *Self, line: []const u8) void {
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
        pub fn recvLine(self: *Self, timeout_ms: i64) []const u8 {
            return self.recvLineOrNull(timeout_ms) orelse fail("timeout waiting for child reply");
        }

        /// `recvLine`, or null when no whole line arrived within `timeout_ms`.
        pub fn recvLineOrNull(self: *Self, timeout_ms: i64) ?[]const u8 {
            const deadline = nowMs() + timeout_ms;
            while (true) {
                if (std.mem.indexOfScalar(u8, self.rbuf.items, '\n')) |nl| {
                    const line = self.rbuf.items[0..nl];
                    // A stable copy in the scratch buffer FIRST: the shift
                    // below overwrites `line` whenever a second reply arrived
                    // in the same read (deferred replies do that).
                    scratch_len = @min(line.len, scratch.len);
                    @memcpy(scratch[0..scratch_len], line[0..scratch_len]);
                    // Shift the remainder down for the next call.
                    const rest = self.rbuf.items[nl + 1 ..];
                    std.mem.copyForwards(u8, self.rbuf.items[0..rest.len], rest);
                    self.rbuf.shrinkRetainingCapacity(rest.len);
                    return scratch[0..scratch_len];
                }
                if (nowMs() > deadline) return null;
                var pfd = c.struct_pollfd{ .fd = self.from_child, .events = c.POLLIN, .revents = 0 };
                if (c.poll(&pfd, 1, 200) <= 0) continue;
                var tmp: [65536]u8 = undefined;
                const n = c.read(self.from_child, &tmp, tmp.len);
                if (n <= 0) fail("child closed stdout early");
                self.rbuf.appendSlice(self.allocator, tmp[0..@intCast(n)]) catch fail("oom");
            }
        }

        /// Issue a tools/call and return the first reply line.
        pub fn callTool(self: *Self, name: []const u8, args_json: []const u8) []const u8 {
            self.sendTool(name, args_json);
            return self.recvLine(15_000);
        }

        /// `callTool` with a reply budget of its own.
        pub fn callToolTimeout(self: *Self, name: []const u8, args_json: []const u8, timeout_ms: i64) []const u8 {
            self.sendTool(name, args_json);
            return self.recvLine(timeout_ms);
        }

        /// Issue a tools/call WITHOUT reading the reply, for calls that
        /// make the server talk to a socket this process must serve first.
        pub fn sendTool(self: *Self, name: []const u8, args_json: []const u8) void {
            self.id += 1;
            var buf: [4096]u8 = undefined;
            const req = std.fmt.bufPrint(&buf, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"tools/call\",\"params\":{{\"name\":\"{s}\",\"arguments\":{s}}}}}", .{ self.id, name, args_json }) catch fail("req too long");
            self.send(req);
        }

        pub fn sendToolAllocated(self: *Self, name: []const u8, args_json: []const u8) void {
            self.id += 1;
            const req = std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"tools/call\",\"params\":{{\"name\":\"{s}\",\"arguments\":{s}}}}}", .{ self.id, name, args_json }) catch
                fail("large request allocation");
            defer self.allocator.free(req);
            self.send(req);
        }

        /// Issue tools/list and return the raw reply line.
        pub fn listTools(self: *Self) []const u8 {
            self.id += 1;
            var buf: [256]u8 = undefined;
            const req = std.fmt.bufPrint(&buf, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"tools/list\"}}", .{self.id}) catch unreachable;
            self.send(req);
            return self.recvLine(15_000);
        }

        pub fn initialize(self: *Self) void {
            _ = self.initializeAs("smoke");
        }

        /// `initialize` as the client `client_name`. @return the reply line.
        pub fn initializeAs(self: *Self, client_name: []const u8) []const u8 {
            self.id += 1;
            var buf: [512]u8 = undefined;
            const req = std.fmt.bufPrint(&buf, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"initialize\",\"params\":{{\"protocolVersion\":\"{s}\",\"capabilities\":{{}},\"clientInfo\":{{\"name\":\"{s}\",\"version\":\"0\"}}}}}}", .{ self.id, version.mcp_protocol, client_name }) catch fail("initialize too long");
            self.send(req);
            return self.recvLine(10_000);
        }

        pub fn closeStdinWait(self: *Self) void {
            _ = c.close(self.to_child);
            var st: c_int = 0;
            // Give teardown a moment; then reap.
            var tries: u32 = 0;
            while (tries < 100) : (tries += 1) {
                if (c.waitpid(self.pid, &st, c.WNOHANG) == self.pid) break;
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

        /// Stop a child that does not read its stdin (an `agent-wait`
        /// follower): SIGTERM to its exact pid, reaped.
        pub fn terminate(self: *Self) void {
            _ = c.close(self.to_child);
            _ = c.kill(self.pid, c.SIGTERM);
            var st: c_int = 0;
            _ = c.waitpid(self.pid, &st, 0);
            _ = c.close(self.from_child);
            self.rbuf.deinit(self.allocator);
        }
    };
}
