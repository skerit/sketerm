//! A lifetime fence: a pipe whose WRITE end only the owning process holds,
//! so every daemon below that process shuts down when it dies -- by any
//! exit path, including SIGKILL, a panic, or an error that skipped every
//! `defer`.
//!
//! The read end is published by number in `ENV` and left inheritable, so it
//! crosses fork AND exec and reaches daemons the owner never spawned itself:
//! the broker `sketerm mcp` autostarts, the replacement a GUI under test
//! autostarts when its connection drops, a fake-ssh remote daemon, and
//! every worker those brokers fork. The write end is CLOEXEC, so an exec'd
//! child can never hold the fence open. A forked child that does NOT exec
//! is a second owner until it calls `dropWriteEnd`.
//!
//! This complements `platform.dieWithParent`, it does not replace it:
//! PDEATHSIG still kills a wedged daemon whose poll loop never reads the
//! fence, and the fence covers what PDEATHSIG cannot -- descendants that
//! are not our children, clean shutdown instead of SIGKILL, and macOS,
//! where `dieWithParent` is a documented no-op.
//!
//! The user's per-user daemon is never fenced: nothing in a normal desktop
//! session sets `ENV`, and a daemon that finds it set to a descriptor it
//! does not hold refuses to start rather than running unfenced.

const std = @import("std");
const c = @import("../c.zig").c;

/// The read end's descriptor number, decimal.
pub const ENV = "SKETERM_MUX_LIFETIME_FD";

var write_fd: c_int = -1;

/// Owner side: mint the pipe and publish the read end in `ENV`.
/// Idempotent. Returns false only when the pipe or the env could not be
/// set up, in which case nothing is published.
pub fn arm() bool {
    if (write_fd >= 0) return true;
    var fds: [2]c_int = undefined;
    if (c.pipe(&fds) != 0) return false;
    // Inheritable read end, owner-only write end.
    _ = c.fcntl(fds[0], c.F_SETFD, @as(c_int, 0));
    _ = c.fcntl(fds[1], c.F_SETFD, c.FD_CLOEXEC);
    var buf: [16:0]u8 = undefined;
    const s = std.fmt.bufPrintZ(&buf, "{d}", .{fds[0]}) catch unreachable;
    if (c.setenv(ENV, s.ptr, 1) != 0) {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
        return false;
    }
    write_fd = fds[1];
    return true;
}

/// True when this process owns an armed fence.
pub fn armed() bool {
    return write_fd >= 0;
}

/// A forked child that will not exec must drop the write end, or the
/// fence stays held for as long as that child lives.
pub fn dropWriteEnd() void {
    if (write_fd < 0) return;
    _ = c.close(write_fd);
    write_fd = -1;
}

pub const InheritError = error{BadFenceFd};

/// Daemon side: the fence read end named by `ENV`, or -1 when unset.
/// @throws BadFenceFd when the variable names a descriptor this process
/// does not hold: someone armed a fence and something closed it before
/// us, and starting unfenced would be exactly the leak the fence exists
/// to prevent.
pub fn inherited() InheritError!c_int {
    const v = c.getenv(ENV) orelse return -1;
    const s = std.mem.span(@as([*:0]const u8, @ptrCast(v)));
    const fd = std.fmt.parseInt(c_int, s, 10) catch return error.BadFenceFd;
    if (fd < 0 or c.fcntl(fd, c.F_GETFD) < 0) return error.BadFenceFd;
    return fd;
}

/// True once the owner is gone: a poll wake on the read end where read()
/// reports EOF or a hard error. Bytes in the pipe are drained and
/// ignored, so a stray writer cannot trip the fence early.
pub fn tripped(fd: c_int, revents: c_short) bool {
    if (revents & (c.POLLIN | c.POLLHUP | c.POLLERR) == 0) return false;
    var buf: [64]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n == 0) return true;
        if (n < 0) {
            const e = std.posix.errno(n);
            if (e == .INTR) continue;
            return e != .AGAIN;
        }
        // Data, not EOF: leave the rest for the next poll wake.
        if (@as(usize, @intCast(n)) < buf.len) return false;
    }
}

/// One poll round on `fd`, the shape every caller of `tripped` uses.
fn pollOnce(fd: c_int, timeout_ms: c_int) c_short {
    var pfd = c.struct_pollfd{ .fd = fd, .events = c.POLLIN, .revents = 0 };
    _ = c.poll(&pfd, 1, timeout_ms);
    return pfd.revents;
}

test "lifetime: the fence trips on writer close, not on writes" {
    const t = std.testing;
    var fds: [2]c_int = undefined;
    try t.expect(c.pipe(&fds) == 0);
    defer _ = c.close(fds[0]);

    // Quiet pipe: nothing to report.
    try t.expect(!tripped(fds[0], pollOnce(fds[0], 0)));
    // A stray byte is drained, not mistaken for the owner's death.
    try t.expect(c.write(fds[1], "x", 1) == 1);
    try t.expect(!tripped(fds[0], pollOnce(fds[0], 0)));
    // The owner dying closes the last write end: EOF trips it.
    _ = c.close(fds[1]);
    try t.expect(tripped(fds[0], pollOnce(fds[0], 1000)));
}

test "lifetime: inherited() reads the armed fence and refuses a dead one" {
    const t = std.testing;
    const saved = c.getenv(ENV);
    defer if (saved) |v| {
        _ = c.setenv(ENV, v, 1);
    } else {
        _ = c.unsetenv(ENV);
    };

    _ = c.unsetenv(ENV);
    try t.expectEqual(@as(c_int, -1), try inherited());

    try t.expect(arm());
    try t.expect(armed());
    const fd = try inherited();
    try t.expect(fd >= 0);
    // The read end is inheritable, the write end is not.
    try t.expectEqual(@as(c_int, 0), c.fcntl(fd, c.F_GETFD) & c.FD_CLOEXEC);
    try t.expect(c.fcntl(write_fd, c.F_GETFD) & c.FD_CLOEXEC != 0);

    // Dropping the write end (a forked non-exec child's duty) trips it.
    dropWriteEnd();
    try t.expect(!armed());
    try t.expect(tripped(fd, pollOnce(fd, 1000)));
    _ = c.close(fd);

    // A descriptor this process does not hold is an error, never "unfenced".
    try t.expect(c.setenv(ENV, "999999", 1) == 0);
    try t.expectError(error.BadFenceFd, inherited());
    try t.expect(c.setenv(ENV, "nope", 1) == 0);
    try t.expectError(error.BadFenceFd, inherited());
}
