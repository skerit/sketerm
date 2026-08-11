//! Minimal RFC 1928 SOCKS5 codec: greeting + CONNECT request parsing
//! and the two reply headers. No auth, CONNECT only, atyp domain +
//! ipv4 (+ ipv6 for free). Pure data — no sockets, no allocator, no
//! GTK — so it unit-tests headless in both roots and the transport
//! (`socksbridge.zig`) stays a thin poll loop over it.
//!
//! The parsers are INCREMENTAL: each takes the bytes accumulated so far
//! and returns `null` when the message is not yet complete, an error
//! when it is malformed, or a value carrying `consumed` (how many bytes
//! to drop from the accumulation buffer).

const std = @import("std");

/// Request command byte.
pub const Cmd = enum(u8) { connect = 1, bind = 2, udp_associate = 3, _ };

/// Address type byte.
pub const Atyp = enum(u8) { ipv4 = 1, domain = 3, ipv6 = 4, _ };

/// Reply status byte (the second byte of a CONNECT reply).
pub const Rep = enum(u8) {
    ok = 0,
    general_failure = 1,
    not_allowed = 2,
    net_unreachable = 3,
    host_unreachable = 4,
    conn_refused = 5,
    ttl_expired = 6,
    cmd_not_supported = 7,
    atyp_not_supported = 8,
};

/// The client's method-selection greeting.
pub const Greeting = struct {
    consumed: usize,
    /// Whether the client offered the "no authentication" method (0x00),
    /// the only one this server accepts.
    offers_no_auth: bool,
};

/// Parse the greeting `[ver=5][nmethods][methods...]`. `null` = need
/// more bytes; `error.BadVersion` = not SOCKS5.
pub fn parseGreeting(buf: []const u8) error{BadVersion}!?Greeting {
    if (buf.len < 2) return null;
    if (buf[0] != 0x05) return error.BadVersion;
    const n = buf[1];
    if (buf.len < 2 + @as(usize, n)) return null;
    var no_auth = false;
    for (buf[2 .. 2 + @as(usize, n)]) |m| {
        if (m == 0x00) no_auth = true;
    }
    return .{ .consumed = 2 + @as(usize, n), .offers_no_auth = no_auth };
}

/// The destination of a CONNECT request.
pub const Addr = union(enum) {
    ipv4: [4]u8,
    /// Borrows from the parse buffer.
    domain: []const u8,
    ipv6: [16]u8,
};

pub const Request = struct {
    consumed: usize,
    cmd: Cmd,
    addr: Addr,
    port: u16,
};

pub const RequestError = error{ BadVersion, BadReserved, UnsupportedAtyp };

/// Parse `[ver=5][cmd][rsv=0][atyp][addr][port]`. `null` = need more;
/// `error.UnsupportedAtyp` = a well-formed request for an address type
/// this codec does not decode (answer with `Rep.atyp_not_supported`).
pub fn parseRequest(buf: []const u8) RequestError!?Request {
    if (buf.len < 4) return null;
    if (buf[0] != 0x05) return error.BadVersion;
    if (buf[2] != 0x00) return error.BadReserved;
    const cmd: Cmd = @enumFromInt(buf[1]);
    const atyp: Atyp = @enumFromInt(buf[3]);
    switch (atyp) {
        .ipv4 => {
            if (buf.len < 10) return null;
            return .{
                .consumed = 10,
                .cmd = cmd,
                .addr = .{ .ipv4 = buf[4..8].* },
                .port = std.mem.readInt(u16, buf[8..10], .big),
            };
        },
        .domain => {
            if (buf.len < 5) return null;
            const ln: usize = buf[4];
            if (buf.len < 5 + ln + 2) return null;
            return .{
                .consumed = 5 + ln + 2,
                .cmd = cmd,
                .addr = .{ .domain = buf[5 .. 5 + ln] },
                .port = std.mem.readInt(u16, buf[5 + ln ..][0..2], .big),
            };
        },
        .ipv6 => {
            if (buf.len < 22) return null;
            return .{
                .consumed = 22,
                .cmd = cmd,
                .addr = .{ .ipv6 = buf[4..20].* },
                .port = std.mem.readInt(u16, buf[20..22], .big),
            };
        },
        else => return error.UnsupportedAtyp,
    }
}

/// The method-selection reply: 0x00 (no auth) when accepted, else 0xFF
/// (no acceptable methods — the client then closes).
pub fn methodReply(no_auth: bool) [2]u8 {
    return .{ 0x05, if (no_auth) 0x00 else 0xFF };
}

/// A CONNECT reply with a zeroed IPv4 bound address (RFC 1928 permits
/// reporting BND.ADDR as 0.0.0.0:0 when it is not meaningful, which it
/// never is for a tunnelled connection).
pub fn connectReply(rep: Rep) [10]u8 {
    return .{ 0x05, @intFromEnum(rep), 0x00, 0x01, 0, 0, 0, 0, 0, 0 };
}

/// Render a parsed address as the host STRING the mux `stream_open`
/// verb resolves — a domain passes through verbatim (so DNS happens at
/// the egress end), an IP is formatted numeric. Returns a slice of
/// `buf` (or the borrowed domain slice).
pub fn formatHost(addr: Addr, buf: []u8) []const u8 {
    return switch (addr) {
        .domain => |d| d,
        .ipv4 => |ip| std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] }) catch "0.0.0.0",
        .ipv6 => |ip| blk: {
            // Full (uncompressed) 8-group form; getaddrinfo(AI) parses
            // it numerically — no need to implement `::` compression.
            var g: [8]u16 = undefined;
            for (0..8) |i| g[i] = std.mem.readInt(u16, ip[i * 2 ..][0..2], .big);
            break :blk std.fmt.bufPrint(buf, "{x}:{x}:{x}:{x}:{x}:{x}:{x}:{x}", .{
                g[0], g[1], g[2], g[3], g[4], g[5], g[6], g[7],
            }) catch "::1";
        },
    };
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

test "greeting: incremental and no-auth detection" {
    try std.testing.expectEqual(@as(?Greeting, null), try parseGreeting(&.{0x05}));
    // ver 5, 1 method (0x00) but method byte missing yet
    try std.testing.expectEqual(@as(?Greeting, null), try parseGreeting(&.{ 0x05, 0x01 }));
    const g = (try parseGreeting(&.{ 0x05, 0x02, 0x00, 0x02 })).?;
    try std.testing.expectEqual(@as(usize, 4), g.consumed);
    try std.testing.expect(g.offers_no_auth);
    const g2 = (try parseGreeting(&.{ 0x05, 0x01, 0x02 })).?;
    try std.testing.expect(!g2.offers_no_auth);
    try std.testing.expectError(error.BadVersion, parseGreeting(&.{ 0x04, 0x01, 0x00 }));
}

test "request: ipv4 CONNECT" {
    // ver cmd rsv atyp | 93.184.216.34 | 443
    const buf = [_]u8{ 0x05, 0x01, 0x00, 0x01, 93, 184, 216, 34, 0x01, 0xBB };
    const r = (try parseRequest(&buf)).?;
    try std.testing.expectEqual(Cmd.connect, r.cmd);
    try std.testing.expectEqual(@as(u16, 443), r.port);
    try std.testing.expectEqual(@as(usize, 10), r.consumed);
    var hb: [64]u8 = undefined;
    try std.testing.expectEqualStrings("93.184.216.34", formatHost(r.addr, &hb));
}

test "request: domain CONNECT, incremental" {
    const full = [_]u8{ 0x05, 0x01, 0x00, 0x03, 0x0b } ++ "example.com".* ++ [_]u8{ 0x00, 0x50 };
    // one byte short = need more
    try std.testing.expectEqual(@as(?Request, null), try parseRequest(full[0 .. full.len - 1]));
    const r = (try parseRequest(&full)).?;
    try std.testing.expectEqual(@as(u16, 80), r.port);
    try std.testing.expectEqual(full.len, r.consumed);
    var hb: [64]u8 = undefined;
    try std.testing.expectEqualStrings("example.com", formatHost(r.addr, &hb));
}

test "request: reserved byte and unsupported atyp" {
    try std.testing.expectError(error.BadReserved, parseRequest(&.{ 0x05, 0x01, 0x01, 0x01 }));
    // atyp 0x07 is well-formed framing but unknown -> reportable
    try std.testing.expectError(error.UnsupportedAtyp, parseRequest(&.{ 0x05, 0x01, 0x00, 0x07 }));
}

test "reply headers" {
    try std.testing.expectEqualSlices(u8, &.{ 0x05, 0x00 }, &methodReply(true));
    try std.testing.expectEqualSlices(u8, &.{ 0x05, 0xFF }, &methodReply(false));
    try std.testing.expectEqualSlices(u8, &.{ 0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0 }, &connectReply(.ok));
    try std.testing.expectEqual(@as(u8, 5), connectReply(.conn_refused)[1]);
}
