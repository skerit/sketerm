//! sketerm's own SSH ControlMaster policy: before a NEW connection rides a
//! master, find out which master that would be and how old its login is,
//! and retire sketerm's own one when it is too old (or a fresh login is
//! asked for).
//!
//! A master keeps the credentials of the login that created it (the group
//! list included) for as long as any session uses it, and agent terminals
//! keep sketerm's masters busy for days. `ssh -O stop` (measured, OpenSSH
//! 10.5) unlinks the control socket and stops accepting new multiplex
//! requests while the sessions it already carries keep running, and the
//! stopped master exits after its last one; the next `ControlMaster=auto`
//! connection therefore becomes a fresh master at the same path.
//!
//! Only sketerm's ControlPath (`sshroute.CONTROL_PREFIX` under
//! `sshroute.controlDir`) is ever stopped. A master the user's ssh_config
//! imposes is reported, never touched. libc only: the daemon links it.

const std = @import("std");
const c = @import("../c.zig").c;
const platform = @import("../util/platform.zig");
const clock = @import("../util/clock.zig");
const sshroute = @import("sshroute.zig");

/// The default `mux_ssh_master_max_age_secs`.
pub const DEFAULT_MAX_AGE_S: u64 = 3600;

/// Bound on each local `ssh -G` / `-O check` / `-O stop` (none dials out).
const STEP_MS: i64 = 3_000;

/// Whose master a connection would ride.
pub const Kind = enum {
    /// sketerm's own ControlPath.
    sketerm,
    /// A ControlPath the user's ssh_config sets for this host.
    user_config,
    /// No multiplexing applies.
    none,
    /// The effective options could not be read (no OpenSSH `-G`, a wrapper).
    unknown,
};

pub const Policy = struct {
    /// A sketerm master older than this is stopped first; 0 never stops one.
    max_age_s: u64 = DEFAULT_MAX_AGE_S,
    /// Stop sketerm's master whatever its age.
    fresh: bool = false,
};

pub const Report = struct {
    kind: Kind = .unknown,
    /// A live master serves the connection that follows.
    reused: bool = false,
    /// The age of the master's login; null when none is live or it is unknown.
    age_s: ?u64 = null,
    /// sketerm stopped its old (or a fresh-login-refused) master first.
    stopped: bool = false,
    pid: ?i32 = null,
    path_buf: [512]u8 = undefined,
    path_len: usize = 0,

    /// The effective ControlPath, when one applies.
    pub fn controlPath(self: *const Report) ?[]const u8 {
        return if (self.path_len > 0) self.path_buf[0..self.path_len] else null;
    }
};

/// Inspect, and for sketerm's own master enforce `policy` on, the master a
/// connection to `destination` with `args` would ride. Never fails: what
/// cannot be determined reads as `.unknown`.
pub fn prepare(ssh_bin: [*:0]const u8, args: *const sshroute.Args, destination: []const u8, policy: Policy) Report {
    var r: Report = .{};
    var dest_buf: [256:0]u8 = undefined;
    const dest = std.fmt.bufPrintZ(&dest_buf, "{s}", .{destination}) catch return r;
    var out: [16 * 1024]u8 = undefined;

    const g = run(ssh_bin, args, &.{"-G"}, dest, &out) orelse return r;
    if (g.status != 0) return r;
    const effective = parseConfig(out[0..g.len]);
    // OpenSSH -G omits the key when no ControlPath applies.
    const cp = effective.control_path orelse {
        r.kind = .none;
        return r;
    };
    if (std.mem.eql(u8, cp, "none")) {
        r.kind = .none;
        return r;
    }
    if (cp.len > r.path_buf.len) return r;
    @memcpy(r.path_buf[0..cp.len], cp);
    r.path_len = cp.len;
    r.kind = if (args.multiplexes()) .sketerm else .user_config;

    const chk = run(ssh_bin, args, &.{ "-O", "check" }, dest, &out) orelse return r;
    if (chk.status != 0) return r; // no live master: this connection makes one (or none)
    r.pid = parseMasterPid(out[0..chk.len]) orelse return r;
    r.age_s = socketAge(r.controlPath().?);
    r.reused = true;
    if (r.kind != .sketerm) return r;
    const too_old = if (r.age_s) |age| policy.max_age_s > 0 and age >= policy.max_age_s else false;
    if (!policy.fresh and !too_old) return r;
    const stop = run(ssh_bin, args, &.{ "-O", "stop" }, dest, &out) orelse return r;
    if (stop.status == 0) {
        r.stopped = true;
        r.reused = false;
    }
    return r;
}

/// What `ssh -G` printed that this module reads.
pub const Effective = struct { control_path: ?[]const u8 = null, control_master: ?[]const u8 = null };

pub fn parseConfig(text: []const u8) Effective {
    var e: Effective = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const key = line[0..sp];
        const value = std.mem.trim(u8, line[sp + 1 ..], " ");
        if (std.ascii.eqlIgnoreCase(key, "controlpath")) e.control_path = value;
        if (std.ascii.eqlIgnoreCase(key, "controlmaster")) e.control_master = value;
    }
    return e;
}

/// The pid in `Master running (pid=N)`.
pub fn parseMasterPid(text: []const u8) ?i32 {
    const at = std.mem.indexOf(u8, text, "(pid=") orelse return null;
    const rest = text[at + "(pid=".len ..];
    const end = std.mem.indexOfScalar(u8, rest, ')') orelse return null;
    const pid = std.fmt.parseInt(i32, rest[0..end], 10) catch return null;
    return if (pid > 0) pid else null;
}

/// The master's age from its control socket's mtime: a master binds a fresh
/// socket file and links it into place, and nothing modifies it after. Chosen
/// over `/proc/<pid>/stat` starttime, which is measured against `/proc/uptime`:
/// inside an LXC container lxcfs virtualizes uptime, so a 22 s old master read
/// as 0 s (measured); the mtime also works on macOS, which has no `/proc`.
fn socketAge(path: []const u8) ?u64 {
    var buf: [600]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return null;
    var st: c.struct_stat = undefined;
    if (c.stat(z.ptr, &st) != 0) return null;
    const now = @divTrunc(clock.wallMs(), 1000);
    const born = platform.mtimeSecs(&st);
    return if (now > born) @intCast(now - born) else 0;
}

const Ran = struct { status: u8, len: usize };

/// `ssh <args options> <extra> <dest>` with stdout and stderr captured into
/// `out`, bounded by `STEP_MS`; null when it could not run or timed out.
fn run(ssh_bin: [*:0]const u8, args: *const sshroute.Args, extra: []const [:0]const u8, dest: [:0]const u8, out: []u8) ?Ran {
    var argv: [sshroute.Args.MAX_OPTIONS + 8:null]?[*:0]const u8 = .{null} ** (sshroute.Args.MAX_OPTIONS + 8);
    var n: usize = 0;
    argv[n] = ssh_bin;
    n += 1;
    args.append(&argv, &n) catch return null;
    for (extra) |e| {
        argv[n] = e.ptr;
        n += 1;
    }
    argv[n] = dest.ptr;
    n += 1;
    argv[n] = null;

    var pipe_fds: [2]c_int = undefined;
    if (c.pipe(&pipe_fds) != 0) return null;
    for (pipe_fds) |fd| _ = c.fcntl(fd, c.F_SETFD, c.FD_CLOEXEC);
    const pid = c.fork();
    if (pid < 0) {
        _ = c.close(pipe_fds[0]);
        _ = c.close(pipe_fds[1]);
        return null;
    }
    if (pid == 0) {
        const devnull = c.open("/dev/null", c.O_RDONLY);
        if (devnull >= 0) _ = c.dup2(devnull, 0);
        _ = c.dup2(pipe_fds[1], 1);
        _ = c.dup2(pipe_fds[1], 2);
        _ = c.execvp(ssh_bin, @ptrCast(&argv));
        c._exit(127);
    }
    _ = c.close(pipe_fds[1]);
    defer _ = c.close(pipe_fds[0]);
    const deadline = clock.nowMs() + STEP_MS;
    var len: usize = 0;
    var timed_out = false;
    while (true) {
        const remain = deadline - clock.nowMs();
        if (remain <= 0) {
            timed_out = true;
            break;
        }
        var pfd = c.struct_pollfd{ .fd = pipe_fds[0], .events = c.POLLIN, .revents = 0 };
        const pr = c.poll(&pfd, 1, @intCast(@min(remain, 250)));
        if (pr < 0) {
            if (std.posix.errno(pr) == .INTR) continue;
            break;
        }
        if (pr == 0) continue;
        var scratch: [4096]u8 = undefined;
        const dst: []u8 = if (len < out.len) out[len..] else scratch[0..];
        const got = c.read(pipe_fds[0], dst.ptr, dst.len);
        if (got <= 0) break;
        if (len < out.len) len += @intCast(got);
    }
    if (timed_out) _ = c.kill(pid, c.SIGKILL);
    var status: c_int = 0;
    while (true) {
        const rc = c.waitpid(pid, &status, 0);
        if (rc >= 0) break;
        if (std.posix.errno(rc) != .INTR) return null;
    }
    if (timed_out or !c.WIFEXITED(status)) return null;
    return .{ .status = @intCast(c.WEXITSTATUS(status)), .len = len };
}

const t = std.testing;

test "ssh -G output: the effective ControlPath and ControlMaster" {
    const e = parseConfig("user me\ncontrolmaster auto\r\ncontrolpath /home/me/.ssh/sketerm-52ad\nforwardx11 no\n");
    try t.expectEqualStrings("/home/me/.ssh/sketerm-52ad", e.control_path.?);
    try t.expectEqualStrings("auto", e.control_master.?);
    try t.expect(parseConfig("hostname box\n").control_path == null);
}

test "ssh -O check output: the master's pid, or none" {
    try t.expectEqual(@as(?i32, 1241849), parseMasterPid("Master running (pid=1241849)\r\n"));
    try t.expect(parseMasterPid("Control socket connect(/x): No such file or directory\n") == null);
    try t.expect(parseMasterPid("Master running (pid=0)") == null);
    try t.expect(parseMasterPid("") == null);
}

test "a master that cannot be inspected reads as unknown, never as fresh" {
    // `false` stands in for an ssh without `-G`: nothing is stopped.
    const plan = try sshroute.Plan.init("box", .direct, "127.0.0.1:9050");
    var args = try plan.args(.{});
    const r = prepare("false", &args, "box", .{ .fresh = true });
    try t.expectEqual(Kind.unknown, r.kind);
    try t.expect(!r.reused and !r.stopped and r.age_s == null);
}
