//! Gives the per-user daemon a systemd unit of its own, out of its launcher's.
//!
//! An autostarted daemon lands in the cgroup of whatever started it, on a
//! desktop the GUI's launcher unit, and every session lands there with it.
//! systemd defaults units to `OOMPolicy=stop`, which turns ONE kernel OOM
//! kill anywhere in the cgroup into SIGTERM for all of it: the kernel killed
//! a 34 GB python in a pane and systemd then ended the daemon, every other
//! session and the GUI. A scope with `OOMPolicy=continue` keeps the kill to
//! the process the kernel chose, and leaves the GUI outside it entirely.
//!
//! `busctl` keeps this binary libc-only. Every failure leaves the daemon
//! where it was, which is how it ran before this module existed.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("../c.zig").c;
const clock = @import("../util/clock.zig");
const log = @import("log.zig");

/// Prefix of a unit that is already the daemon's: our scope, or a service
/// the user wrote for it, whose main process must not walk out of it.
pub const UNIT_PREFIX = "sketerm-mux";

/// Hard limit on the `busctl` child; its own `--timeout` covers only the call.
const BUSCTL_LIMIT_MS: i64 = 3_000;

/// How long the move may take to land once the job is queued.
const MOVE_LIMIT_MS: i64 = 1_000;

/// The cgroup v2 path in `/proc/<pid>/cgroup` content.
fn cgroupPath(content: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "0::")) return line[3..];
    }
    return null;
}

/// Whether `/proc/self/cgroup` content puts this process in a user manager's unit that is not its own.
pub fn shouldMove(content: []const u8) bool {
    const path = cgroupPath(content) orelse return false;
    // Anything else (a login session's scope, a container's "/") is no
    // user manager we could ask, and is not a launcher unit either.
    if (std.mem.indexOf(u8, path, "/user@") == null) return false;
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return false;
    const leaf = path[slash + 1..];
    return !std.mem.startsWith(u8, leaf, UNIT_PREFIX) and !std.mem.startsWith(u8, leaf, "user@");
}

fn readOwnCgroup(buf: []u8) []const u8 {
    const fd = c.open("/proc/self/cgroup", c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return "";
    defer _ = c.close(fd);
    const n = c.read(fd, buf.ptr, buf.len);
    return if (n > 0) buf[0..@intCast(n)] else "";
}

/// Moves this process into `sketerm-mux-<pid>.scope`; must run before the first fork, since children already forked stay behind.
pub fn ensure() void {
    if (builtin.os.tag != .linux) return;
    var cgroup_buf: [8192]u8 = undefined;
    if (!shouldMove(readOwnCgroup(&cgroup_buf))) return;

    var unit_buf: [64:0]u8 = undefined;
    var pid_buf: [32:0]u8 = undefined;
    const unit = std.fmt.bufPrintSentinel(&unit_buf, "{s}-{d}.scope", .{ UNIT_PREFIX, c.getpid() }, 0) catch return;
    const pid_z = std.fmt.bufPrintSentinel(&pid_buf, "{d}", .{c.getpid()}, 0) catch return;
    const argv = [_:null]?[*:0]const u8{
        "busctl",                            "--user",                   "--timeout=2",
        "call",                              "org.freedesktop.systemd1", "/org/freedesktop/systemd1",
        "org.freedesktop.systemd1.Manager",  "StartTransientUnit",       "ssa(sv)a(sa(sv))",
        unit.ptr,                            "fail",                     "5",
        "PIDs",                              "au",                       "1",
        pid_z.ptr,                           "Slice",                    "s",
        "app.slice",                         "OOMPolicy",                "s",
        "continue",                          "CollectMode",              "s",
        "inactive-or-failed",                "Description",              "s",
        "sketerm session daemon",            "0",
    };

    const child = c.fork();
    if (child < 0) {
        log.warn("own unit: fork failed; staying in the launcher's unit", .{});
        return;
    }
    if (child == 0) {
        const devnull = c.open("/dev/null", c.O_RDWR);
        if (devnull >= 0) {
            _ = c.dup2(devnull, 0);
            _ = c.dup2(devnull, 1);
            _ = c.dup2(devnull, 2);
        }
        _ = c.execvp("busctl", @ptrCast(@constCast(&argv)));
        c._exit(127);
    }

    var status: c_int = 0;
    const deadline = clock.nowMs() + BUSCTL_LIMIT_MS;
    while (true) {
        const reaped = c.waitpid(child, &status, c.WNOHANG);
        if (reaped == child and status != 0) {
            log.warn("own unit: busctl failed (wait status {d}); staying in the launcher's unit", .{status});
            return;
        }
        // Also -1: an inherited SIGCHLD=SIG_IGN reaps it for us, and
        // the cgroup below is the real answer either way.
        if (reaped != 0) break;
        if (clock.nowMs() >= deadline) {
            _ = c.kill(child, c.SIGKILL);
            _ = c.waitpid(child, &status, 0);
            log.warn("own unit: busctl timed out; staying in the launcher's unit", .{});
            return;
        }
        _ = c.usleep(2_000);
    }

    // The call returns with the job queued, not done, and a worker forked
    // before it lands would stay behind in the launcher's unit.
    const landed_by = clock.nowMs() + MOVE_LIMIT_MS;
    while (true) {
        const path = cgroupPath(readOwnCgroup(&cgroup_buf)) orelse "";
        if (std.mem.endsWith(u8, path, unit)) {
            log.info("daemon runs in its own unit {s}", .{unit});
            return;
        }
        if (clock.nowMs() >= landed_by) break;
        _ = c.usleep(2_000);
    }
    log.warn("own unit: {s} never took this process; staying in the launcher's unit", .{unit});
}

test "a launcher's unit under a user manager is left" {
    const t = std.testing;
    try t.expect(shouldMove("0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-dev.sker.sketerm@b70a.service\n"));
    try t.expect(shouldMove("1:net_cls:/\n0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-gnome-x-1234.scope\n"));
    try t.expect(shouldMove("0::/user.slice/user-1000.slice/user@1000.service/session.slice/plasma-foo.service"));
}

test "the daemon's own unit is kept" {
    const t = std.testing;
    try t.expect(!shouldMove("0::/user.slice/user-1000.slice/user@1000.service/app.slice/sketerm-mux-123.scope\n"));
    try t.expect(!shouldMove("0::/user.slice/user-1000.slice/user@1000.service/app.slice/sketerm-mux.service\n"));
}

test "a cgroup with no user manager above it is left alone" {
    const t = std.testing;
    try t.expect(!shouldMove("0::/user.slice/user-1000.slice/session-5.scope\n"));
    try t.expect(!shouldMove("0::/system.slice/sshd.service\n"));
    try t.expect(!shouldMove("0::/\n"));
    try t.expect(!shouldMove("0::/user.slice/user-1000.slice/user@1000.service\n"));
    // cgroup v1 only: no unified line, and an unreadable file reads as empty.
    try t.expect(!shouldMove("1:name=systemd:/user.slice\n"));
    try t.expect(!shouldMove(""));
}
