const std = @import("std");
const c = @import("../c.zig").c;

/// Publishes a duplicate that another thread can safely claim to interrupt IO.
pub const FdCancel = struct {
    stopped: std.atomic.Value(bool) = .init(false),
    fd: std.atomic.Value(c_int) = .init(-1),

    /// Publish `source_fd` or interrupt it immediately when stop already won.
    pub fn publish(self: *FdCancel, source_fd: c_int) !bool {
        const duplicate = c.fcntl(source_fd, c.F_DUPFD_CLOEXEC, @as(c_int, 3));
        if (duplicate < 0) return error.CancelFdFailed;
        const previous = self.fd.swap(duplicate, .acq_rel);
        if (previous >= 0) _ = c.close(previous);
        if (!self.stopped.load(.acquire)) return true;
        self.interrupt();
        return false;
    }

    /// Mark stopped and interrupt a currently published socket, if any.
    pub fn stop(self: *FdCancel) void {
        self.stopped.store(true, .release);
        self.interrupt();
    }

    pub fn isStopped(self: *const FdCancel) bool {
        return self.stopped.load(.acquire);
    }

    /// Clear the stop latch so the slot serves a fresh operation.
    ///
    /// A slot reused across operations (an MCP watchdog covers one tool
    /// call at a time) would otherwise interrupt every later publish.
    /// Whatever is published stays published — a long-lived connection
    /// keeps its duplicate across re-arms; call `release` first to drop it.
    pub fn arm(self: *FdCancel) void {
        self.stopped.store(false, .release);
    }

    /// Retire the duplicate after normal worker completion without shutdown.
    pub fn release(self: *FdCancel) void {
        const fd = self.fd.swap(-1, .acq_rel);
        if (fd >= 0) _ = c.close(fd);
    }

    fn interrupt(self: *FdCancel) void {
        const fd = self.fd.swap(-1, .acq_rel);
        if (fd < 0) return;
        _ = c.shutdown(fd, c.SHUT_RDWR);
        _ = c.close(fd);
    }
};

test "stop before publish interrupts the late socket without double close" {
    const t = std.testing;
    var pair: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &pair));
    defer _ = c.close(pair[0]);
    defer _ = c.close(pair[1]);
    var cancel = FdCancel{};
    cancel.stop();
    try t.expect(!try cancel.publish(pair[0]));
    cancel.release();
    var byte: u8 = 0;
    try t.expectEqual(@as(isize, 0), c.read(pair[1], &byte, 1));
}

test "cancellation claims its duplicate before the descriptor is reused" {
    const t = std.testing;
    var original: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &original));
    defer _ = c.close(original[1]);
    const worker_fd = original[0];
    var cancel = FdCancel{};
    try t.expect(try cancel.publish(worker_fd));
    const cancel_fd = cancel.fd.load(.acquire);
    try t.expect(cancel_fd >= 0 and cancel_fd != worker_fd);

    // The worker closes and something else takes the number back; the
    // duplicate must be what gets shut down, never the new owner.
    _ = c.close(worker_fd);
    var replacement: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &replacement));
    defer _ = c.close(replacement[0]);
    defer _ = c.close(replacement[1]);
    try t.expectEqual(worker_fd, replacement[0]);

    cancel.stop();
    try t.expectEqual(@as(c_int, -1), cancel.fd.load(.acquire));
    var byte: u8 = 0x5a;
    try t.expectEqual(@as(isize, 1), c.write(replacement[0], &byte, 1));
    byte = 0;
    try t.expectEqual(@as(isize, 1), c.read(replacement[1], &byte, 1));
    try t.expectEqual(@as(u8, 0x5a), byte);
    try t.expectEqual(@as(isize, 0), c.read(original[1], &byte, 1));
}

test "arm clears the stop latch so a reused slot serves the next operation" {
    const t = std.testing;
    var stopped_pair: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &stopped_pair));
    defer _ = c.close(stopped_pair[0]);
    defer _ = c.close(stopped_pair[1]);
    var cancel = FdCancel{};
    cancel.stop();
    try t.expect(!try cancel.publish(stopped_pair[0]));

    // Without arm, the next operation's socket is interrupted the
    // instant it publishes, forever.
    cancel.arm();
    try t.expect(!cancel.isStopped());
    var next: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &next));
    defer _ = c.close(next[0]);
    defer _ = c.close(next[1]);
    try t.expect(try cancel.publish(next[0]));
    cancel.release();
    var byte: u8 = 0x11;
    try t.expectEqual(@as(isize, 1), c.write(next[0], &byte, 1));
    byte = 0;
    try t.expectEqual(@as(isize, 1), c.read(next[1], &byte, 1));
    try t.expectEqual(@as(u8, 0x11), byte);
}
