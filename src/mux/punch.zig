//! NAT hole-punch helpers for the UDP bootstrap.
//!
//! A new client announces its own UDP port over the ssh channel
//! ("SKETERM-PUNCH <port>"), the remote combines it with the client
//! address in $SSH_CONNECTION and pre-aims its rudp channel there.
//! The channel's own sealed keepalives then double as punch probes:
//! the first outbound one opens this side's NAT so the client's
//! retransmitted hello can get in, and roaming (which only ever
//! follows AUTHENTICATED packets) latches the true endpoints on both
//! sides. Everything here is the parsing/IO half, kept pure or
//! fd-parameterized so it is unit-testable without ssh or a network.

const std = @import("std");
const c = @import("../c.zig").c;

pub const LINE_PREFIX = "SKETERM-PUNCH ";

/// IPv4 endpoint in wire order-agnostic form: `ip` bytes are in
/// address order (a.b.c.d), `port` is host byte order.
pub const Endpoint = struct {
    ip: [4]u8,
    port: u16,
};

/// Render the client's punch announcement, newline included.
pub fn formatLine(port: u16, buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, LINE_PREFIX ++ "{d}\n", .{port}) catch null;
}

/// Parse "SKETERM-PUNCH <port>". Null for anything else, including
/// port 0 (an unbound client cannot be punched toward).
pub fn parseLine(line: []const u8) ?u16 {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, LINE_PREFIX)) return null;
    const port = std.fmt.parseInt(u16, trimmed[LINE_PREFIX.len..], 10) catch return null;
    return if (port == 0) null else port;
}

/// Dotted-quad parser that also accepts sshd's IPv4-mapped spelling
/// ("::ffff:1.2.3.4"). Plain IPv6 yields null — the UDP leg is
/// IPv4-only today, and a wrong-family probe helps nobody.
pub fn parseIpv4(s: []const u8) ?[4]u8 {
    var rest = s;
    if (std.mem.startsWith(u8, rest, "::ffff:")) rest = rest["::ffff:".len..];
    var out: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, rest, '.');
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) {
        if (i == 4) return null;
        out[i] = std.fmt.parseInt(u8, part, 10) catch return null;
    }
    return if (i == 4) out else null;
}

/// The client's public address as sshd observed it: the first token
/// of $SSH_CONNECTION ("client_ip client_port server_ip server_port").
pub fn clientEndpoint(ssh_connection: []const u8, port: u16) ?Endpoint {
    var it = std.mem.tokenizeAny(u8, ssh_connection, " \t");
    const ip_s = it.next() orelse return null;
    const ip = parseIpv4(ip_s) orelse return null;
    return .{ .ip = ip, .port = port };
}

fn monotonicMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.tv_sec) * 1000 + @divTrunc(ts.tv_nsec, 1_000_000);
}

/// Bounded single-line read: first '\n'-terminated line within
/// `timeout_ms`, or null on EOF/timeout/overflow. New clients send
/// the punch line before they even read the announcement, so it is
/// normally already buffered and this returns immediately; an old
/// client's ssh dies right after the announcement and the resulting
/// EOF ends the wait early rather than costing the full timeout.
pub fn readLine(fd: c_int, timeout_ms: i64, buf: []u8) ?[]const u8 {
    const deadline = monotonicMs() + timeout_ms;
    var len: usize = 0;
    while (len < buf.len) {
        const remain = deadline - monotonicMs();
        if (remain <= 0) return null;
        var pfd = c.struct_pollfd{ .fd = fd, .events = c.POLLIN, .revents = 0 };
        const pr = c.poll(&pfd, 1, @intCast(@min(remain, 250)));
        if (pr < 0) {
            if (std.posix.errno(pr) == .INTR) continue;
            return null;
        }
        if (pr == 0) continue;
        const n = c.read(fd, buf[len..].ptr, buf.len - len);
        if (n <= 0) return null;
        len += @intCast(n);
        if (std.mem.indexOfScalar(u8, buf[0..len], '\n')) |nl| return buf[0..nl];
    }
    return null;
}

test "punch line round-trips through format and parse" {
    var buf: [32]u8 = undefined;
    const line = formatLine(61234, &buf) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("SKETERM-PUNCH 61234\n", line);
    try std.testing.expectEqual(@as(?u16, 61234), parseLine(line));
}

test "punch line parser rejects garbage, port zero, and huge ports" {
    try std.testing.expectEqual(@as(?u16, null), parseLine("SKETERM-UDP 1234 abcd"));
    try std.testing.expectEqual(@as(?u16, null), parseLine("SKETERM-PUNCH 0"));
    try std.testing.expectEqual(@as(?u16, null), parseLine("SKETERM-PUNCH 70000"));
    try std.testing.expectEqual(@as(?u16, null), parseLine("SKETERM-PUNCH"));
    try std.testing.expectEqual(@as(?u16, null), parseLine("hello world"));
    try std.testing.expectEqual(@as(?u16, 443), parseLine("SKETERM-PUNCH 443\r\n"));
}

test "ipv4 parser handles plain, mapped, and rejects v6/garbage" {
    try std.testing.expectEqual(@as(?[4]u8, .{ 203, 0, 113, 9 }), parseIpv4("203.0.113.9"));
    try std.testing.expectEqual(@as(?[4]u8, .{ 203, 0, 113, 9 }), parseIpv4("::ffff:203.0.113.9"));
    try std.testing.expectEqual(@as(?[4]u8, null), parseIpv4("2001:db8::1"));
    try std.testing.expectEqual(@as(?[4]u8, null), parseIpv4("1.2.3"));
    try std.testing.expectEqual(@as(?[4]u8, null), parseIpv4("1.2.3.4.5"));
    try std.testing.expectEqual(@as(?[4]u8, null), parseIpv4("1.2.3.999"));
    try std.testing.expectEqual(@as(?[4]u8, null), parseIpv4(""));
}

test "SSH_CONNECTION yields the client endpoint" {
    const ep = clientEndpoint("198.51.100.7 54321 10.0.0.2 22", 61000) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual([4]u8{ 198, 51, 100, 7 }, ep.ip);
    try std.testing.expectEqual(@as(u16, 61000), ep.port);
    try std.testing.expect(clientEndpoint("2001:db8::1 54321 2001:db8::2 22", 61000) == null);
    try std.testing.expect(clientEndpoint("", 61000) == null);
}

test "readLine returns a buffered line immediately and null on EOF" {
    var fds: [2]c_int = undefined;
    try std.testing.expect(c.pipe(&fds) == 0);
    defer _ = c.close(fds[0]);
    const msg = "SKETERM-PUNCH 5000\n";
    try std.testing.expect(c.write(fds[1], msg.ptr, msg.len) == @as(isize, msg.len));
    _ = c.close(fds[1]);
    var buf: [64]u8 = undefined;
    const line = readLine(fds[0], 1_000, &buf) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("SKETERM-PUNCH 5000", line);
    // Drained + writer closed: the next read hits EOF, not the timeout.
    const start = monotonicMs();
    try std.testing.expect(readLine(fds[0], 5_000, &buf) == null);
    try std.testing.expect(monotonicMs() - start < 1_000);
}
