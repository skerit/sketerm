//! Peer addresses: the ONE grammar home, shared by the MCP server and the
//! broker. `name` is a peer on the caller's host, `host/name` a peer
//! reached through federation (phase 2; until then a send to one is
//! refused `federation_unavailable`). `host` is the `[domain.<host>]`
//! name the hub knows. A name is also a mailbox file name, so its
//! charset is closed and it never starts with a dot.

const std = @import("std");

/// The longest name.
pub const NAME_MAX = 64;
/// The longest host part (a DNS name fits).
pub const HOST_MAX = 253;
/// Names under this prefix are minted by the broker for peers without a
/// durable name, and are never durable themselves.
pub const ANON_PREFIX = "anon-";
/// Random characters after `anon-`.
pub const ANON_CHARS = 4;
/// The longest formatted address.
pub const ADDRESS_MAX = HOST_MAX + 1 + NAME_MAX;

pub const Error = error{ Empty, TooLong, BadChar, LeadingDot };

pub const Address = struct {
    /// Null for a peer on the caller's own host.
    host: ?[]const u8 = null,
    name: []const u8,

    /// Parse `name` or `host/name`; the slices borrow `text`.
    pub fn parse(text: []const u8) Error!Address {
        if (std.mem.indexOfScalar(u8, text, '/')) |slash| {
            const host = text[0..slash];
            const name = text[slash + 1 ..];
            try validPart(host, HOST_MAX);
            try validName(name);
            return .{ .host = host, .name = name };
        }
        try validName(text);
        return .{ .name = text };
    }

    /// The canonical text form into `buf`.
    pub fn format(self: Address, buf: []u8) error{NoSpaceLeft}![]const u8 {
        if (self.host) |h| return std.fmt.bufPrint(buf, "{s}/{s}", .{ h, self.name });
        return std.fmt.bufPrint(buf, "{s}", .{self.name});
    }

    /// Whether the name is a broker-minted, never-durable one.
    pub fn isAnon(self: Address) bool {
        return isAnonName(self.name);
    }
};

/// A peer name: 1-64 of [A-Za-z0-9._-], not starting with a dot.
pub fn validName(name: []const u8) Error!void {
    return validPart(name, NAME_MAX);
}

/// Whether `name` carries the reserved `anon-` prefix.
pub fn isAnonName(name: []const u8) bool {
    return std.mem.startsWith(u8, name, ANON_PREFIX);
}

fn validPart(part: []const u8, max: usize) Error!void {
    if (part.len == 0) return error.Empty;
    if (part.len > max) return error.TooLong;
    // AIDEV-NOTE: a leading dot is refused although the charset allows it:
    // the name is a mailbox file name (`.`, `..`, hidden files).
    if (part[0] == '.') return error.LeadingDot;
    for (part) |ch| switch (ch) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '-' => {},
        else => return error.BadChar,
    };
}

const t = std.testing;

test "a local name and a host/name parse and format back" {
    const a = try Address.parse("Zenit");
    try t.expect(a.host == null);
    try t.expectEqualStrings("Zenit", a.name);
    const b = try Address.parse("hohenheim/Qq_2.x-y");
    try t.expectEqualStrings("hohenheim", b.host.?);
    try t.expectEqualStrings("Qq_2.x-y", b.name);
    var buf: [ADDRESS_MAX]u8 = undefined;
    try t.expectEqualStrings("hohenheim/Qq_2.x-y", try b.format(&buf));
    try t.expectEqualStrings("Zenit", try a.format(&buf));
    try t.expect((try Address.parse("anon-k3f9")).isAnon());
    try t.expect(!a.isAnon());
    try t.expectError(error.NoSpaceLeft, b.format(buf[0..3]));
}

test "refused addresses name what is wrong" {
    try t.expectError(error.Empty, Address.parse(""));
    try t.expectError(error.Empty, Address.parse("host/"));
    try t.expectError(error.Empty, Address.parse("/name"));
    try t.expectError(error.BadChar, Address.parse("a/b/c"));
    try t.expectError(error.BadChar, Address.parse("with space"));
    try t.expectError(error.BadChar, Address.parse("caf\xc3\xa9"));
    try t.expectError(error.LeadingDot, Address.parse(".."));
    try t.expectError(error.LeadingDot, Address.parse(".hidden"));
    try t.expectError(error.TooLong, Address.parse("a" ** (NAME_MAX + 1)));
    _ = try Address.parse("a" ** NAME_MAX);
    try t.expectError(error.TooLong, validName("x" ** 65));
}
