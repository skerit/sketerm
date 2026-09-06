//! The blocking SOCKS5 server half every smoke rig's proxy fixture
//! needs: read a greeting and a CONNECT off an accepted socket with
//! the `ipc/socks5.zig` codec, dial a loopback upstream, and relay
//! bytes both ways until either side closes. smoke-web's `ProxyProbe`
//! and smoke-e2e's Tor stub differ only in what they RECORD about the
//! CONNECT and which upstream they choose; that is the caller's
//! `handle`, and everything below it lives here once.
//!
//! Every read has a deadline: a fixture that blocks forever on a
//! client that went away is a rig that hangs instead of failing.

const std = @import("std");
const c = @import("../c.zig").c;
const socks5 = @import("../ipc/socks5.zig");
const clock = @import("../util/clock.zig");

/// Accumulator for the handshake bytes; a greeting plus a CONNECT
/// never approach this.
pub const Acc = struct {
    buf: [1024]u8 = undefined,
    len: usize = 0,

    /// The bytes after `consumed`, moved to the front: what the
    /// client sent past the frame just parsed (a CONNECT after the
    /// greeting, or the first request bytes after the CONNECT).
    pub fn drop(self: *Acc, consumed: usize) void {
        std.mem.copyForwards(u8, self.buf[0 .. self.len - consumed], self.buf[consumed..self.len]);
        self.len -= consumed;
    }

    pub fn bytes(self: *const Acc) []const u8 {
        return self.buf[0..self.len];
    }

    /// One poll + read into the accumulator. False when the client is
    /// gone or the accumulator is full; true on data OR on a timeout,
    /// so the caller's deadline is what ends a silent client.
    fn fill(self: *Acc, afd: c_int) bool {
        var pfd = c.struct_pollfd{ .fd = afd, .events = c.POLLIN, .revents = 0 };
        if (c.poll(@ptrCast(&pfd), 1, 500) <= 0) return true;
        if (self.len >= self.buf.len) return false;
        const n = c.read(afd, self.buf[self.len..].ptr, self.buf.len - self.len);
        if (n <= 0) return false;
        self.len += @intCast(n);
        return true;
    }
};

pub fn readGreeting(afd: c_int, acc: *Acc, timeout_ms: i64) ?socks5.Greeting {
    const deadline = clock.nowMs() + timeout_ms;
    while (clock.nowMs() < deadline) {
        if (socks5.parseGreeting(acc.bytes()) catch return null) |g| return g;
        if (!acc.fill(afd)) return null;
    }
    return null;
}

pub fn readRequest(afd: c_int, acc: *Acc, timeout_ms: i64) ?socks5.Request {
    const deadline = clock.nowMs() + timeout_ms;
    while (clock.nowMs() < deadline) {
        if (socks5.parseRequest(acc.bytes()) catch return null) |r| return r;
        if (!acc.fill(afd)) return null;
    }
    return null;
}

pub fn connectLoopback(port: u16) ?c_int {
    const fd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
    if (fd < 0) return null;
    var sa = std.mem.zeroes(c.struct_sockaddr_in);
    sa.sin_family = c.AF_INET;
    sa.sin_port = std.mem.nativeToBig(u16, port);
    sa.sin_addr.s_addr = std.mem.nativeToBig(u32, c.INADDR_LOOPBACK);
    if (c.connect(fd, @ptrCast(&sa), @sizeOf(c.struct_sockaddr_in)) != 0) {
        _ = c.close(fd);
        return null;
    }
    return fd;
}

pub fn writeAll(fd: c_int, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(fd, bytes.ptr + off, bytes.len - off);
        if (n < 0 and std.c._errno().* == c.EINTR) continue;
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

/// Bytes the CLIENT sends through the tunnel, before they are
/// forwarded: how a probe reads the request line without touching it.
pub const Observer = *const fn (ctx: ?*anyopaque, bytes: []const u8) void;

/// Pump `client` <-> `upstream` until both directions closed or
/// `max_ms` passed. `initial` is whatever request bytes arrived glued
/// to the CONNECT. Closes neither fd.
pub fn relay(client: c_int, upstream: c_int, initial: []const u8, observer: ?Observer, ctx: ?*anyopaque, max_ms: i64) void {
    if (initial.len != 0) {
        if (observer) |ob| ob(ctx, initial);
        if (!writeAll(upstream, initial)) return;
    }
    var client_open = true;
    var upstream_open = true;
    const deadline = clock.nowMs() + max_ms;
    var buf: [16 * 1024]u8 = undefined;
    while ((client_open or upstream_open) and clock.nowMs() < deadline) {
        var pfds = [_]c.struct_pollfd{
            .{ .fd = client, .events = if (client_open) c.POLLIN else 0, .revents = 0 },
            .{ .fd = upstream, .events = if (upstream_open) c.POLLIN else 0, .revents = 0 },
        };
        if (c.poll(@ptrCast(&pfds), pfds.len, 200) <= 0) continue;
        if (client_open and pfds[0].revents != 0) {
            const n = c.read(client, &buf, buf.len);
            if (n <= 0) {
                client_open = false;
                _ = c.shutdown(upstream, c.SHUT_WR);
            } else {
                const bytes = buf[0..@intCast(n)];
                if (observer) |ob| ob(ctx, bytes);
                if (!writeAll(upstream, bytes)) client_open = false;
            }
        }
        if (upstream_open and pfds[1].revents != 0) {
            const n = c.read(upstream, &buf, buf.len);
            if (n <= 0) {
                upstream_open = false;
                _ = c.shutdown(client, c.SHUT_WR);
            } else if (!writeAll(client, buf[0..@intCast(n)])) {
                upstream_open = false;
            }
        }
    }
}
