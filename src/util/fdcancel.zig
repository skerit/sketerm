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
