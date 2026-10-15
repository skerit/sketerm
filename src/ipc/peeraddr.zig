//! Peer addresses: the ONE grammar home, shared by the MCP server and the
//! broker. `name` is a peer on the caller's host, `host/name` a peer
//! reached through federation. `host` is the `[domain.<host>]` name the
//! hub knows (or the hub's own host name). A name is also a mailbox file
//! name, so its charset is closed and it never starts with a dot.
//!
//! Only the hub rewrites addresses as mail crosses a link (`qualify` on
//! the way in, `localize` on the way out), so a member never needs to
//! know what the hub calls it.

const std = @import("std");
const c = @import("../c.zig").c;
const env = @import("../util/env.zig");

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
/// Rigs override this host's name in peer addresses (default: gethostname).
pub const HOST_ENV = "SKETERM_MUX_PEER_HOST";

/// The host name this daemon announces in peer addresses, into `buf`;
/// empty when it has none.
pub fn selfHost(buf: []u8) []const u8 {
    if (env.nonEmpty(HOST_ENV)) |h| return h;
    if (c.gethostname(buf.ptr, buf.len) != 0) return "";
    return std.mem.sliceTo(buf, 0);
}

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

/// A host part: 1-253 of [A-Za-z0-9._-], not starting with a dot.
pub fn validHost(host: []const u8) Error!void {
    return validPart(host, HOST_MAX);
}

/// `addr` as seen from across the link to `link_host`: a bare name of
/// that host becomes `link_host/name`; a qualified address is kept.
pub fn qualify(buf: []u8, link_host: []const u8, addr: []const u8) error{NoSpaceLeft}![]const u8 {
    if (std.mem.indexOfScalar(u8, addr, '/') != null) return std.fmt.bufPrint(buf, "{s}", .{addr});
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ link_host, addr });
}

/// `addr` (as the hub `self_host` holds it) as the host behind `link_host`
/// must read it: a bare hub name becomes `self_host/name`, the link host's
/// own `link_host/name` becomes `name`, any other host's address is kept.
pub fn localize(buf: []u8, self_host: []const u8, link_host: []const u8, addr: []const u8) error{NoSpaceLeft}![]const u8 {
    const slash = std.mem.indexOfScalar(u8, addr, '/') orelse return std.fmt.bufPrint(buf, "{s}/{s}", .{ self_host, addr });
    if (std.mem.eql(u8, addr[0..slash], link_host)) return std.fmt.bufPrint(buf, "{s}", .{addr[slash + 1 ..]});
    return std.fmt.bufPrint(buf, "{s}", .{addr});
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

test "the hub qualifies what arrives and localizes what leaves" {
    var buf: [ADDRESS_MAX]u8 = undefined;
    // In from link `box`: its bare peers gain the host, others are kept.
    try t.expectEqualStrings("box/alice", try qualify(&buf, "box", "alice"));
    try t.expectEqualStrings("hub/Zenit", try qualify(&buf, "box", "hub/Zenit"));
    // Out to link `box`: hub peers gain the hub's host, box's own lose it,
    // a third host's stay as they are.
    try t.expectEqualStrings("hub/Zenit", try localize(&buf, "hub", "box", "Zenit"));
    try t.expectEqualStrings("alice", try localize(&buf, "hub", "box", "box/alice"));
    try t.expectEqualStrings("lab/bob", try localize(&buf, "hub", "box", "lab/bob"));
    // Round trip: what the hub sends box qualifies back to what it held.
    try t.expectEqualStrings("Zenit", (try Address.parse(try localize(&buf, "hub", "box", "Zenit"))).name);
    try t.expectError(error.NoSpaceLeft, qualify(buf[0..4], "box", "alice"));
    try validHost("hohenheim.local");
    try t.expectError(error.Empty, validHost(""));
    try t.expectError(error.BadChar, validHost("a/b"));
}
