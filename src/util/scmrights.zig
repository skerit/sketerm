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

const hdr_size: usize = @sizeOf(c.struct_cmsghdr);

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

/// Append every SCM_RIGHTS descriptor `mh` received to `list`, each marked FD_CLOEXEC.
/// A descriptor the list cannot take is closed rather than leaked.
pub fn collect(mh: *const c.struct_msghdr, allocator: std.mem.Allocator, list: *std.ArrayList(c_int)) void {
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
                _ = c.fcntl(fd, c.F_SETFD, c.FD_CLOEXEC);
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
    // No MSG_CMSG_CLOEXEC: Darwin lacks it; `collect` sets FD_CLOEXEC,
    // which is race-free only for a caller that does not fork concurrently.
    const r = c.recvmsg(fd, &mh, 0);
    if (r > 0) collect(&mh, allocator, list);
    return r;
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
