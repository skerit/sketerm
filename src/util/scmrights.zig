//! SCM_RIGHTS control-message layout, packed and walked by hand because
//! the CMSG_* macros do not survive translate-c.
//!
//! On 64-bit glibc and musl the cmsghdr is 16 bytes and
//! CMSG_ALIGN(sizeof cmsghdr) == sizeof cmsghdr, so the descriptors
//! follow the header directly and each message is padded to a multiple
//! of `usize`. libc only; usable from the daemon and the browser helper
//! alike.

const std = @import("std");
const c = @import("cbindings");
const platform = @import("platform.zig");

const hdr_size: usize = @sizeOf(c.struct_cmsghdr);

/// Linux marks received descriptors close-on-exec inside recvmsg; elsewhere (Darwin lacks the flag) `collect` falls back to fcntl, race-free only for a caller that does not fork concurrently.
const atomic_cloexec = platform.is_linux;
const recv_flags: c_int = if (atomic_cloexec) c.MSG_CMSG_CLOEXEC else 0;

/// Write ONE SCM_RIGHTS message carrying `fds` at the start of `cbuf`, which the caller zeroed.
/// @return the `msg_controllen` to send, padding included.
pub fn pack(cbuf: []align(@alignOf(c.struct_cmsghdr)) u8, fds: []const c_int) usize {
    const cmsg: *c.struct_cmsghdr = @ptrCast(cbuf.ptr);
    cmsg.cmsg_len = @intCast(hdr_size + fds.len * @sizeOf(c_int));
    cmsg.cmsg_level = c.SOL_SOCKET;
    cmsg.cmsg_type = c.SCM_RIGHTS;
    for (fds, 0..) |fd, i| {
        @memcpy(cbuf[hdr_size + i * @sizeOf(c_int) ..][0..@sizeOf(c_int)], std.mem.asBytes(&fd));
    }
    return (cmsg.cmsg_len + @sizeOf(usize) - 1) & ~@as(usize, @sizeOf(usize) - 1);
}

/// Append every SCM_RIGHTS descriptor `mh` received to `list`, each close-on-exec.
/// A descriptor that cannot be marked close-on-exec, or that the list cannot take, is closed rather than leaked.
fn collect(mh: *const c.struct_msghdr, allocator: std.mem.Allocator, list: *std.ArrayList(c_int)) void {
    const ctl: [*]const u8 = @ptrCast(mh.msg_control orelse return);
    const clen: usize = @intCast(mh.msg_controllen);
    const alignment: usize = @sizeOf(usize);
    var off: usize = 0;
    while (off + hdr_size <= clen) {
        const hdr: *const c.struct_cmsghdr = @ptrCast(@alignCast(ctl + off));
        const cl: usize = @intCast(hdr.cmsg_len);
        if (cl < hdr_size or off + cl > clen) break;
        if (hdr.cmsg_level == c.SOL_SOCKET and hdr.cmsg_type == c.SCM_RIGHTS) {
            const n_fds = (cl - hdr_size) / @sizeOf(c_int);
            var i: usize = 0;
            while (i < n_fds) : (i += 1) {
                var fd: c_int = undefined;
                @memcpy(std.mem.asBytes(&fd), ctl[off + hdr_size + i * @sizeOf(c_int) ..][0..@sizeOf(c_int)]);
                if (!atomic_cloexec and c.fcntl(fd, c.F_SETFD, c.FD_CLOEXEC) < 0) {
                    _ = c.close(fd);
                    continue;
                }
                list.append(allocator, fd) catch {
                    _ = c.close(fd);
                };
            }
        }
        off += (cl + alignment - 1) & ~(alignment - 1);
    }
}

/// One `recvmsg` into `data`, every descriptor it carried appended to `list` via `collect`.
/// @return recvmsg's result: bytes read, 0 at EOF, negative with errno set.
pub fn recv(fd: c_int, data: []u8, allocator: std.mem.Allocator, list: *std.ArrayList(c_int)) isize {
    var cbuf: [256]u8 align(@alignOf(c.struct_cmsghdr)) = undefined;
    var iov = c.struct_iovec{ .iov_base = data.ptr, .iov_len = data.len };
    var mh = std.mem.zeroes(c.struct_msghdr);
    mh.msg_iov = @ptrCast(&iov);
    mh.msg_iovlen = 1;
    mh.msg_control = &cbuf;
    mh.msg_controllen = cbuf.len;
    const r = c.recvmsg(fd, &mh, recv_flags);
    if (r > 0) collect(&mh, allocator, list);
    return r;
}

/// How a `drain` ended.
pub const Drain = enum {
    /// The socket has no more bytes for now, or the budget ran out (a level-triggered watch fires again).
    open,
    /// The peer closed the connection.
    eof,
    /// recvmsg failed, or `in` could not grow.
    failed,
};

/// Bytes one `drain` reads at most, so a flooding peer cannot starve its caller's event loop or deadline.
pub const drain_budget: usize = 4 * 1024 * 1024;

/// Read a non-blocking socket into `in` until it would block, a read comes up short, or `drain_budget` is spent,
/// appending passed descriptors to `fds`.
pub fn drain(fd: c_int, allocator: std.mem.Allocator, in: *std.ArrayList(u8), fds: *std.ArrayList(c_int)) Drain {
    var buf: [64 * 1024]u8 = undefined;
    var budget: usize = drain_budget;
    while (budget > 0) {
        const n = recv(fd, &buf, allocator, fds);
        if (n == 0) return .eof;
        if (n < 0) {
            const e = std.c._errno().*;
            if (e == c.EAGAIN or e == c.EWOULDBLOCK) return .open;
            if (e == c.EINTR) continue;
            return .failed;
        }
        const got: usize = @intCast(n);
        in.appendSlice(allocator, buf[0..got]) catch return .failed;
        budget -|= got;
        if (got < buf.len) return .open;
    }
    return .open;
}

test "pack and recv carry two descriptors across a socketpair" {
    const t = std.testing;
    var pair: [2]c_int = undefined;
    if (c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &pair) != 0) return error.SkipZigTest;
    defer _ = c.close(pair[0]);
    defer _ = c.close(pair[1]);
    var pipe_fds: [2]c_int = undefined;
    if (c.pipe(&pipe_fds) != 0) return error.SkipZigTest;
    defer _ = c.close(pipe_fds[0]);
    defer _ = c.close(pipe_fds[1]);

    var byte: u8 = 'x';
    var iov = c.struct_iovec{ .iov_base = &byte, .iov_len = 1 };
    var cbuf: [64]u8 align(@alignOf(c.struct_cmsghdr)) = std.mem.zeroes([64]u8);
    var mh = std.mem.zeroes(c.struct_msghdr);
    mh.msg_iov = @ptrCast(&iov);
    mh.msg_iovlen = 1;
    mh.msg_control = &cbuf;
    mh.msg_controllen = @intCast(pack(&cbuf, &pipe_fds));
    try t.expectEqual(@as(usize, 24), @as(usize, @intCast(mh.msg_controllen)));
    try t.expectEqual(@as(isize, 1), c.sendmsg(pair[0], &mh, 0));

    var list: std.ArrayList(c_int) = .empty;
    defer list.deinit(t.allocator);
    defer for (list.items) |fd| {
        _ = c.close(fd);
    };
    var got: [4]u8 = undefined;
    try t.expectEqual(@as(isize, 1), recv(pair[1], &got, t.allocator, &list));
    try t.expectEqual(@as(u8, 'x'), got[0]);
    try t.expectEqual(@as(usize, 2), list.items.len);
    for (list.items) |fd| try t.expect(c.fcntl(fd, c.F_GETFD) & c.FD_CLOEXEC != 0);
}

test "drain reads to EAGAIN, keeps every descriptor of one message, and reports eof" {
    const t = std.testing;
    var pair: [2]c_int = undefined;
    if (c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &pair) != 0) return error.SkipZigTest;
    defer _ = c.close(pair[1]);
    var tx_open = true;
    defer if (tx_open) {
        _ = c.close(pair[0]);
    };
    _ = c.fcntl(pair[1], c.F_SETFL, c.fcntl(pair[1], c.F_GETFL) | c.O_NONBLOCK);
    var pipe_fds: [2]c_int = undefined;
    if (c.pipe(&pipe_fds) != 0) return error.SkipZigTest;
    defer _ = c.close(pipe_fds[0]);
    defer _ = c.close(pipe_fds[1]);

    var bytes = "hello".*;
    var iov = c.struct_iovec{ .iov_base = &bytes, .iov_len = bytes.len };
    var cbuf: [64]u8 align(@alignOf(c.struct_cmsghdr)) = std.mem.zeroes([64]u8);
    var mh = std.mem.zeroes(c.struct_msghdr);
    mh.msg_iov = @ptrCast(&iov);
    mh.msg_iovlen = 1;
    mh.msg_control = &cbuf;
    mh.msg_controllen = @intCast(pack(&cbuf, &pipe_fds));
    try t.expectEqual(@as(isize, bytes.len), c.sendmsg(pair[0], &mh, 0));

    var in: std.ArrayList(u8) = .empty;
    defer in.deinit(t.allocator);
    var fds: std.ArrayList(c_int) = .empty;
    defer fds.deinit(t.allocator);
    defer for (fds.items) |fd| {
        _ = c.close(fd);
    };
    // 1. Bytes then EAGAIN: the connection stays open, both descriptors arrive close-on-exec.
    try t.expectEqual(Drain.open, drain(pair[1], t.allocator, &in, &fds));
    try t.expectEqualStrings("hello", in.items);
    try t.expectEqual(@as(usize, 2), fds.items.len);
    for (fds.items) |fd| try t.expect(c.fcntl(fd, c.F_GETFD) & c.FD_CLOEXEC != 0);
    // 2. Nothing pending: still open, nothing appended.
    try t.expectEqual(Drain.open, drain(pair[1], t.allocator, &in, &fds));
    try t.expectEqual(@as(usize, 5), in.items.len);
    // 3. The peer hangs up: eof.
    _ = c.close(pair[0]);
    tx_open = false;
    try t.expectEqual(Drain.eof, drain(pair[1], t.allocator, &in, &fds));
    // 4. recvmsg fails outright: failed.
    try t.expectEqual(Drain.failed, drain(-1, t.allocator, &in, &fds));
}
