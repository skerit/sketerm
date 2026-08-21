//! Unix-socket plumbing the rigs need and the standard library does
//! not give them in Zig 0.16.

const std = @import("std");
const c = @import("../c.zig").c;
const clock = @import("../util/clock.zig");

/// sendmsg with one SCM_RIGHTS fd attached. The CMSG_* macros do not
/// translate, so the layout is written out: a 16-byte header on 64-bit
/// glibc/musl (12 on Darwin), the fd, and space padded to the platform's
/// cmsg alignment. XNU rejects a controllen that overshoots the aligned
/// length, which is why the alignment is 4 there and 8 on Linux.
///
/// Shared by smoke-backlog and smoke-mux.
pub fn sendWithFd(sock: c_int, bytes: []const u8, fd: c_int) !void {
    var iov = c.struct_iovec{ .iov_base = @constCast(bytes.ptr), .iov_len = bytes.len };
    var cbuf: [32]u8 align(@alignOf(c.struct_cmsghdr)) = std.mem.zeroes([32]u8);
    const hdr_size: usize = @sizeOf(c.struct_cmsghdr);
    const cmsg: *c.struct_cmsghdr = @ptrCast(&cbuf);
    cmsg.cmsg_len = @intCast(hdr_size + @sizeOf(c_int));
    cmsg.cmsg_level = c.SOL_SOCKET;
    cmsg.cmsg_type = c.SCM_RIGHTS;
    @memcpy(cbuf[hdr_size..][0..@sizeOf(c_int)], std.mem.asBytes(&fd));
    var mh = std.mem.zeroes(c.struct_msghdr);
    mh.msg_iov = @ptrCast(&iov);
    mh.msg_iovlen = 1;
    mh.msg_control = &cbuf;
    const cmsg_align: usize = if (@import("builtin").os.tag == .macos) 4 else 8;
    mh.msg_controllen = @intCast(std.mem.alignForward(usize, hdr_size + @sizeOf(c_int), cmsg_align));
    if (c.sendmsg(sock, &mh, 0) != @as(isize, @intCast(bytes.len))) return error.SendFailed;
}

/// Why a `connectWithRetry` gave up. Kept as distinct members so each
/// rig can keep its own wording (and its own `fail` path).
pub const ConnectError = error{
    PathTooLong,
    Socket,
    PeerExited,
    Timeout,
};

/// Connect to `path`, retrying for `timeout_ms` while the peer starts
/// up. `pid`, when positive, is watched with WNOHANG so a peer that dies
/// before it listens is reported at once instead of after the full
/// timeout. Shared by smoke-web and bench-webreq, which both wait on a
/// CEF helper that takes seconds to bind.
pub fn connectWithRetry(
    path: [*:0]const u8,
    path_len: usize,
    pid: c.pid_t,
    timeout_ms: i64,
) ConnectError!c_int {
    var addr = std.mem.zeroes(c.struct_sockaddr_un);
    addr.sun_family = c.AF_UNIX;
    if (path_len + 1 > @sizeOf(@TypeOf(addr.sun_path))) return error.PathTooLong;
    @memcpy(addr.sun_path[0..path_len], path[0..path_len]);

    const deadline = clock.nowMs() + timeout_ms;
    while (clock.nowMs() < deadline) {
        var status: c_int = 0;
        if (pid > 0 and c.waitpid(pid, &status, c.WNOHANG) == pid) return error.PeerExited;
        const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
        if (fd < 0) return error.Socket;
        if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) == 0) return fd;
        _ = c.close(fd);
        _ = c.usleep(100_000);
    }
    return error.Timeout;
}
