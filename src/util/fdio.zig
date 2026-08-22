//! Raw fd write loops.
//!
//! `write(2)` is allowed to write less than it was given and to fail
//! with EINTR, so "write these bytes" is always a loop. This is the
//! BLOCKING one: it is for fds that block (a regular file, a pipe, a
//! socket left in blocking mode), where a short write means only that
//! the kernel took part of the buffer.
//!
//! The non-blocking sibling lives in `mux/dbusconn.zig`: it waits on
//! POLLOUT against a deadline and belongs to the clients that have a
//! deadline to wait against. Do not use this one on a non-blocking fd
//! -- EAGAIN would read as a hard failure.

const std = @import("std");
const c = @import("cbindings");

/// Write every byte of `bytes` to `fd`, retrying EINTR.
/// @return false on the first real write error, with an unknown number
/// of bytes already written -- the caller's stream is then unusable.
pub fn writeAll(fd: c_int, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(fd, bytes.ptr + off, bytes.len - off);
        if (n <= 0) {
            if (n < 0 and std.posix.errno(n) == .INTR) continue;
            return false;
        }
        off += @intCast(n);
    }
    return true;
}

test "writeAll writes everything, and reports a closed fd" {
    const t = std.testing;
    var fds: [2]c_int = undefined;
    if (c.pipe(&fds) != 0) return error.SkipZigTest;
    defer _ = c.close(fds[0]);

    try t.expect(writeAll(fds[1], "hello"));
    try t.expect(writeAll(fds[1], ""));
    var buf: [8]u8 = undefined;
    const n = c.read(fds[0], &buf, buf.len);
    try t.expectEqual(@as(isize, 5), n);
    try t.expectEqualStrings("hello", buf[0..5]);

    _ = c.close(fds[1]);
    try t.expect(!writeAll(fds[1], "gone"));
}
