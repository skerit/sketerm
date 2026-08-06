//! Debugger jobs — attach a debugger to an app session's own child and
//! hand its output back as `app_debug_data`.
//!
//! This exists because of an asymmetry only the daemon can resolve. On
//! Linux with Yama's default `ptrace_scope=1`, only an ancestor may
//! trace a process, and a headless app's ancestor is THIS daemon, not
//! the assistant's shell — so `gdb -p` from anywhere else answers
//! "Operation not permitted" and a hung app is undiagnosable. A crash
//! dumps a full report into the log ring; a hang used to give nothing.
//!
//! Two halves make it work: the session's child relaxed Yama before
//! exec (`SpawnReq.debuggable` → `platform.allowAnyPtracer`), and the
//! debugger runs HERE, as a daemon subprocess whose stdout pipe is
//! polled per tick like a file job. A gdb attach costs seconds; doing
//! it inline would stall every other session for that long.

const std = @import("std");
const c = @import("../c.zig").c;
const log = @import("log.zig");
const wire = @import("wire.zig");
const dmod = @import("daemon.zig");
const Daemon = dmod.Daemon;
const Client = dmod.Client;
const nowMs = dmod.nowMs;

/// Cap on one debugger job's captured output. A `thread apply all bt
/// full` on a 200-thread JVM runs to megabytes of locals; the head is
/// where the answer is, and an unbounded reply would sit in a client
/// queue that the backlog policy then has to flush.
pub const MAX_OUTPUT: usize = 256 * 1024;
/// Concurrent debugger jobs across the whole daemon. Each one STOPS
/// its target while attached, so this is a throttle as much as a
/// memory bound.
pub const MAX_JOBS: usize = 4;
const DEFAULT_TIMEOUT_MS: i64 = 20_000;
const MIN_TIMEOUT_MS: i64 = 2_000;
const MAX_TIMEOUT_MS: i64 = 120_000;

pub const DebugJob = struct {
    allocator: std.mem.Allocator,
    /// Requesting client. Resolved by ID at completion — the client may
    /// have died while the debugger ran, and a raw pointer would dangle.
    client_id: u64,
    /// The debugger's pid, and the app child it is attached to.
    pid: c.pid_t,
    target_pid: c.pid_t,
    out_fd: c_int,
    /// Static name of the debugger binary ("gdb" / "lldb").
    tool: []const u8,
    buf: std.ArrayList(u8) = .empty,
    truncated: bool = false,
    deadline_ms: i64,
    started_ms: i64,
    /// Set when the deadline killed the debugger, so the reply says
    /// "the debugger itself timed out" rather than reporting a
    /// truncated dump as if it were complete.
    timed_out: bool = false,

    pub fn deinit(self: *DebugJob) void {
        if (self.out_fd >= 0) _ = c.close(self.out_fd);
        self.buf.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

/// First of `names` that resolves to an executable on PATH. Returns a
/// NUL-terminated absolute path in `buf`.
fn whichBin(names: []const []const u8, buf: []u8) ?[:0]const u8 {
    const path = c.getenv("PATH") orelse return null;
    const path_s = std.mem.span(path);
    for (names) |name| {
        var it = std.mem.splitScalar(u8, path_s, ':');
        while (it.next()) |dir| {
            if (dir.len == 0) continue;
            const full = std.fmt.bufPrintZ(buf, "{s}/{s}", .{ dir, name }) catch continue;
            if (c.access(full.ptr, c.X_OK) == 0) return full;
        }
    }
    return null;
}

fn replyErr(cl: *Client, msg: []const u8) void {
    cl.queueJson(.app_debug_data, .{ .@"error" = msg });
}

/// Serve an `app_debug` request: validate, then spawn the debugger and
/// leave the reply to `debugJobReadable`. Never blocks.
pub fn handleAppDebug(self: *Daemon, cl: *Client, payload: []const u8) void {
    const Req = struct {
        op: []const u8 = "backtrace",
        timeout_ms: i64 = DEFAULT_TIMEOUT_MS,
    };
    var req: Req = .{};
    var parsed: ?std.json.Parsed(Req) = null;
    defer if (parsed) |p| p.deinit();
    if (payload.len > 0) {
        parsed = std.json.parseFromSlice(Req, self.allocator, payload, .{
            .ignore_unknown_fields = true,
        }) catch return replyErr(cl, "bad app_debug request");
        req = parsed.?.value;
    }
    if (!std.mem.eql(u8, req.op, "backtrace"))
        return replyErr(cl, "unknown app_debug op (only 'backtrace')");

    const s = cl.attached orelse return replyErr(cl, "not attached");
    if (s.exited)
        return replyErr(cl, "the session's process has already exited — its crash report, if any, is in the log ring");
    if (!s.debuggable)
        return replyErr(cl, "this session was not spawned debuggable, so no debugger can attach to it (Yama restricts tracing to ancestors). Sessions launched through the MCP/appdrive app tools are debuggable; a GUI pane is not.");
    const target = s.childPid();
    if (target <= 0) return replyErr(cl, "the session has no live child process");

    // One job per client at a time: a second attach to the same stopped
    // target would serialize behind the first anyway, and the replies
    // are indistinguishable to the caller.
    for (self.debug_jobs.items) |j| {
        if (j.client_id == cl.id)
            return replyErr(cl, "a debugger is already running for this client — wait for its reply");
    }
    if (self.debug_jobs.items.len >= MAX_JOBS)
        return replyErr(cl, "too many debugger jobs already running on this daemon");

    var pathbuf: [4096]u8 = undefined;
    const exe = whichBin(&.{ "gdb", "lldb" }, &pathbuf) orelse
        return replyErr(cl, "no debugger on the daemon host's PATH (install gdb)");
    const is_lldb = std.mem.endsWith(u8, exe, "/lldb");
    const tool: []const u8 = if (is_lldb) "lldb" else "gdb";

    var pidbuf: [24]u8 = undefined;
    const pid_s = std.fmt.bufPrintZ(&pidbuf, "{d}", .{target}) catch
        return replyErr(cl, "oom");

    var out_pipe: [2]c_int = undefined;
    if (c.pipe(&out_pipe) != 0) return replyErr(cl, "pipe failed");

    const job = self.allocator.create(DebugJob) catch {
        _ = c.close(out_pipe[0]);
        _ = c.close(out_pipe[1]);
        return replyErr(cl, "oom");
    };

    const pid = c.fork();
    if (pid < 0) {
        self.allocator.destroy(job);
        _ = c.close(out_pipe[0]);
        _ = c.close(out_pipe[1]);
        return replyErr(cl, "fork failed");
    }
    if (pid == 0) {
        // Own process group: the deadline kill must not reach the
        // daemon, and gdb spawns helpers of its own.
        _ = c.setpgid(0, 0);
        // stderr too — gdb reports an attach failure there, and that
        // message ("Operation not permitted") IS the diagnosis.
        _ = c.dup2(out_pipe[1], 1);
        _ = c.dup2(out_pipe[1], 2);
        for ([_]c_int{ out_pipe[0], out_pipe[1] }) |fd| if (fd > 2) {
            _ = c.close(fd);
        };
        if (is_lldb) {
            const argv = [_:null]?[*:0]const u8{
                exe.ptr,           "-b",
                "-p",              pid_s.ptr,
                "-o",              "thread list",
                "-o",              "thread backtrace all",
                "-o",              "detach",
                null,
            };
            _ = c.execv(exe.ptr, @ptrCast(@constCast(&argv)));
        } else {
            // -nx: the user's ~/.gdbinit must not change what a tool
            // call returns. Reporting every thread matters as much as
            // in the crash wrapper — the spinning thread is usually not
            // the one gdb selects.
            //
            // The settings are `-iex` (before the attach), not `-ex`:
            // gdb prints one "[New LWP N]" per thread AND a debuginfod
            // consent banner DURING the attach, which on a 30-thread
            // app buries the actual backtrace under 40 lines of chatter
            // — and the first lines are exactly what a caller reading a
            // truncated dump sees.
            const argv = [_:null]?[*:0]const u8{
                exe.ptr,
                "-batch",
                "-nx",
                "-iex",
                "set pagination off",
                "-iex",
                "set confirm off",
                "-iex",
                "set debuginfod enabled off",
                "-iex",
                "set print thread-events off",
                "-p",
                pid_s.ptr,
                "-ex",
                "info threads",
                "-ex",
                "thread apply all bt full",
                "-ex",
                "info registers",
                null,
            };
            _ = c.execv(exe.ptr, @ptrCast(@constCast(&argv)));
        }
        c._exit(127);
    }
    _ = c.setpgid(pid, pid);
    _ = c.close(out_pipe[1]);
    const fl = c.fcntl(out_pipe[0], c.F_GETFL);
    _ = c.fcntl(out_pipe[0], c.F_SETFL, fl | c.O_NONBLOCK);
    _ = c.fcntl(out_pipe[0], c.F_SETFD, c.FD_CLOEXEC);

    const timeout = std.math.clamp(req.timeout_ms, MIN_TIMEOUT_MS, MAX_TIMEOUT_MS);
    job.* = .{
        .allocator = self.allocator,
        .client_id = cl.id,
        .pid = pid,
        .target_pid = target,
        .out_fd = out_pipe[0],
        .tool = tool,
        .started_ms = nowMs(),
        .deadline_ms = nowMs() + timeout,
    };
    self.debug_jobs.append(self.allocator, job) catch {
        job.deinit();
        return replyErr(cl, "oom");
    };
    log.info("app_debug: {s} attaching to pid {d} for client {d}", .{ tool, target, cl.id });
}

/// Drain the debugger's pipe (called when its fd polls readable).
pub fn debugJobReadable(self: *Daemon, job: *DebugJob) void {
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = c.read(job.out_fd, &buf, buf.len);
        if (n < 0) return; // EAGAIN — more next tick
        if (n == 0) return finishJob(self, job);
        const chunk = buf[0..@intCast(n)];
        const room = MAX_OUTPUT -| job.buf.items.len;
        if (room == 0) {
            job.truncated = true;
            continue; // keep draining so the debugger can exit
        }
        job.buf.appendSlice(self.allocator, chunk[0..@min(room, chunk.len)]) catch return;
        if (chunk.len > room) job.truncated = true;
    }
}

/// Kill debugger jobs past their deadline; their pipes then hit EOF and
/// `debugJobReadable` finishes them with `timed_out` set.
pub fn debugJobsTick(self: *Daemon) void {
    const now = nowMs();
    for (self.debug_jobs.items) |j| {
        if (j.timed_out or now < j.deadline_ms) continue;
        j.timed_out = true;
        _ = c.kill(-j.pid, c.SIGKILL);
    }
}

fn finishJob(self: *Daemon, job: *DebugJob) void {
    var status: c_int = 0;
    _ = c.waitpid(job.pid, &status, 0);
    // Resolve the client by id: it may have disconnected while the
    // debugger ran, and the reply then has nowhere to go.
    var target_client: ?*Client = null;
    for (self.clients.items) |cl| {
        if (cl.id == job.client_id and !cl.dead) target_client = cl;
    }
    if (target_client) |cl| {
        if (job.timed_out) {
            cl.queueJson(.app_debug_data, .{
                .ok = false,
                .pid = job.target_pid,
                .tool = job.tool,
                .timed_out = true,
                .text = job.buf.items,
                .truncated = job.truncated,
                .@"error" = "the debugger did not finish before the timeout and was killed (partial output below)",
            });
        } else {
            cl.queueJson(.app_debug_data, .{
                .ok = true,
                .pid = job.target_pid,
                .tool = job.tool,
                .took_ms = nowMs() - job.started_ms,
                .text = job.buf.items,
                .truncated = job.truncated,
            });
        }
    }
    var i: usize = 0;
    while (i < self.debug_jobs.items.len) : (i += 1) {
        if (self.debug_jobs.items[i] == job) {
            _ = self.debug_jobs.orderedRemove(i);
            break;
        }
    }
    job.deinit();
}

test "whichBin finds a binary that exists and rejects one that does not" {
    var buf: [4096]u8 = undefined;
    // `sh` is required by POSIX to be on PATH in any environment this
    // daemon can run in.
    const found = whichBin(&.{"sh"}, &buf);
    try std.testing.expect(found != null);
    try std.testing.expect(std.mem.endsWith(u8, found.?, "/sh"));
    try std.testing.expect(whichBin(&.{"sketerm-no-such-binary-xyzzy"}, &buf) == null);
}
