//! Relays a descriptor (the MCP server's stdin) into a pipe on a thread
//! of its own, so the owner learns the input closed while it is busy.
//!
//! The server reads stdin only between calls; a caller that closed the
//! pipe during a long call went unnoticed until that call answered. The
//! relay reads the source continuously, hands every byte on in order,
//! and reports EOF the moment it reads it — before the bytes still
//! queued ahead of it have reached the owner. The owner polls and reads
//! `read_fd` exactly as it read the source, and sees EOF there after the
//! last relayed byte.

const std = @import("std");
const c = @import("../c.zig").c;

/// Bytes held for the owner before the relay stops reading the source.
/// Past it the source is back-pressured as a plain pipe would be, and an
/// EOF behind that backlog is seen only once the owner drains it.
pub const BACKLOG_MAX: usize = 8 << 20;

pub const Relay = struct {
    /// Poll and read this in place of the source; non-blocking, CLOEXEC.
    read_fd: c_int,

    /// Start relaying `src`. `on_eof` runs on the relay thread when the
    /// source reads EOF (or fails), before `read_fd` reaches its own EOF.
    pub fn start(src: c_int, on_eof: *const fn () void) !Relay {
        var fds: [2]c_int = undefined;
        if (c.pipe(&fds) != 0) return error.RelayPipe;
        for (fds) |fd| {
            _ = c.fcntl(fd, c.F_SETFD, c.FD_CLOEXEC);
            _ = c.fcntl(fd, c.F_SETFL, c.fcntl(fd, c.F_GETFL) | c.O_NONBLOCK);
        }
        const thread = std.Thread.spawn(.{}, run, .{ src, fds[1], on_eof }) catch {
            _ = c.close(fds[0]);
            _ = c.close(fds[1]);
            return error.RelayThread;
        };
        thread.detach();
        return .{ .read_fd = fds[0] };
    }
};

fn run(src: c_int, out: c_int, on_eof: *const fn () void) void {
    defer _ = c.close(out);
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(std.heap.c_allocator);
    var src_open = true;
    while (src_open or pending.items.len > 0) {
        var pfds = [2]c.struct_pollfd{
            .{ .fd = if (src_open and pending.items.len < BACKLOG_MAX) src else -1, .events = c.POLLIN, .revents = 0 },
            .{ .fd = if (pending.items.len > 0) out else -1, .events = c.POLLOUT, .revents = 0 },
        };
        const rc = c.poll(&pfds, 2, -1);
        if (rc < 0) {
            if (std.posix.errno(rc) == .INTR) continue;
            break;
        }
        if (pfds[0].revents != 0) {
            var buf: [65536]u8 = undefined;
            const got = c.read(src, &buf, buf.len);
            if (got > 0) {
                pending.appendSlice(std.heap.c_allocator, buf[0..@intCast(got)]) catch {
                    // Out of memory: the input can no longer be relayed
                    // whole, so it ends here rather than arrive cut.
                    src_open = false;
                    on_eof();
                    break;
                };
            } else if (got == 0 or !retryable(got)) {
                src_open = false;
                on_eof();
            }
        }
        if (pfds[1].revents != 0) {
            const put = c.write(out, pending.items.ptr, pending.items.len);
            if (put > 0) {
                const n: usize = @intCast(put);
                std.mem.copyForwards(u8, pending.items[0 .. pending.items.len - n], pending.items[n..]);
                pending.shrinkRetainingCapacity(pending.items.len - n);
            } else if (!retryable(put)) break; // the owner closed its end
        }
    }
    // A source still open here means the owner went away first; nothing
    // is left to tell.
}

fn retryable(rc: isize) bool {
    return switch (std.posix.errno(rc)) {
        .INTR, .AGAIN => true,
        else => false,
    };
}

const t = std.testing;

var test_eofs: std.atomic.Value(u32) = .init(0);
fn testOnEof() void {
    _ = test_eofs.fetchAdd(1, .acq_rel);
}

fn readAll(fd: c_int, out: *std.ArrayList(u8)) !void {
    while (true) {
        var pfd = c.struct_pollfd{ .fd = fd, .events = c.POLLIN, .revents = 0 };
        if (c.poll(&pfd, 1, 5000) <= 0) return error.TestTimeout;
        var buf: [4096]u8 = undefined;
        const got = c.read(fd, &buf, buf.len);
        if (got == 0) return;
        if (got < 0) {
            if (retryable(got)) continue;
            return error.TestRead;
        }
        try out.appendSlice(t.allocator, buf[0..@intCast(got)]);
    }
}

test "EOF is reported while the owner has not read, then every byte arrives in order" {
    test_eofs.store(0, .release);
    var src: [2]c_int = undefined;
    try t.expect(c.pipe(&src) == 0);
    const relay = try Relay.start(src[0], testOnEof);
    defer _ = c.close(relay.read_fd);
    defer _ = c.close(src[0]);

    // More than a pipe buffer, so part of it must wait in the relay.
    var sent: std.ArrayList(u8) = .empty;
    defer sent.deinit(t.allocator);
    for (0..20_000) |i| try sent.print(t.allocator, "{{\"line\":{d}}}\n", .{i});
    var off: usize = 0;
    while (off < sent.items.len) {
        const put = c.write(src[1], sent.items.ptr + off, sent.items.len - off);
        try t.expect(put > 0);
        off += @intCast(put);
    }
    _ = c.close(src[1]);

    // The owner reads nothing yet; the hangup is reported anyway.
    var waited: u32 = 0;
    while (test_eofs.load(.acquire) == 0 and waited < 500) : (waited += 1) _ = c.usleep(10_000);
    try t.expectEqual(@as(u32, 1), test_eofs.load(.acquire));

    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(t.allocator);
    try readAll(relay.read_fd, &got);
    try t.expectEqualStrings(sent.items, got.items);
    try t.expectEqual(@as(u32, 1), test_eofs.load(.acquire));
}

test "an open source with nothing written reports no EOF" {
    test_eofs.store(0, .release);
    var src: [2]c_int = undefined;
    try t.expect(c.pipe(&src) == 0);
    const relay = try Relay.start(src[0], testOnEof);
    defer _ = c.close(relay.read_fd);
    defer _ = c.close(src[0]);
    _ = c.write(src[1], "x\n", 2);
    var got: [8]u8 = undefined;
    var pfd = c.struct_pollfd{ .fd = relay.read_fd, .events = c.POLLIN, .revents = 0 };
    try t.expect(c.poll(&pfd, 1, 5000) == 1);
    try t.expectEqual(@as(isize, 2), c.read(relay.read_fd, &got, got.len));
    _ = c.usleep(50_000);
    try t.expectEqual(@as(u32, 0), test_eofs.load(.acquire));
    _ = c.close(src[1]);
    var waited: u32 = 0;
    while (test_eofs.load(.acquire) == 0 and waited < 500) : (waited += 1) _ = c.usleep(10_000);
    try t.expectEqual(@as(u32, 1), test_eofs.load(.acquire));
}
