//! Peer addresses and aliases: the ONE grammar home, shared by the MCP
//! server, the CLI and the broker. An address is the opaque identity mail
//! and subject are kept under; an alias is the lowercase slug people use
//! (`slugify`), assigned by the broker (`peermail.Store`, the one home of
//! the alias rules) and accepted wherever an address is. For addresses,
//! `name` is a peer on the caller's host, `host/name` a peer
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
const wire = @import("../mux/wire.zig");

/// The longest name.
pub const NAME_MAX = 64;
/// The longest host part (a DNS name fits).
pub const HOST_MAX = 253;
/// Names under this prefix are minted by the broker for peers without a
/// durable name, and are never durable themselves.
pub const ANON_PREFIX = "anon-";
/// Random characters after `anon-`.
pub const ANON_CHARS = 4;
/// Names under this prefix are derived from the session origin id of the
/// sketerm pane a server runs in (`paneName`), so they are durable per
/// pane and never follow its name; nothing else may claim one.
pub const PANE_PREFIX = "p-";
/// Origin-id hex characters after `p-`.
pub const PANE_CHARS = 8;
/// A pane-derived name's length.
pub const PANE_NAME_LEN = PANE_PREFIX.len + PANE_CHARS;
/// Names under this prefix are derived from a program's requested alias
/// (`namedAddress`: `sketerm peer --name`, `SKETERM_PEER_NAME` outside a
/// sketerm pane), so the same name is the same durable address.
pub const NAMED_PREFIX = "n-";
/// Hash hex characters after `n-`.
pub const NAMED_CHARS = 8;
pub const NAMED_NAME_LEN = NAMED_PREFIX.len + NAMED_CHARS;
/// The longest slug a title or name yields; a suffix (`-1` .. `-999`)
/// stays within `ALIAS_MAX`, itself a valid name length.
pub const SLUG_MAX = 48;
/// The highest suffix tried before an alias is given up.
pub const ALIAS_SUFFIX_MAX: u32 = 999;
pub const ALIAS_MAX = SLUG_MAX + 4;
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

/// Whether `name` carries the reserved `n-` prefix.
pub fn isNamedName(name: []const u8) bool {
    return std.mem.startsWith(u8, name, NAMED_PREFIX);
}

/// Whether `name` carries the reserved `p-` prefix.
pub fn isPaneName(name: []const u8) bool {
    return std.mem.startsWith(u8, name, PANE_PREFIX);
}

/// Whether `name` lies in a space only sketerm mints (`anon-`, `p-`,
/// `n-`), which an explicit name or an alias must not claim.
pub fn isReservedName(name: []const u8) bool {
    return isAnonName(name) or isPaneName(name) or isNamedName(name);
}

/// The name of a server in the pane whose session origin id is
/// `origin_id`, written into `buf`; null when that is no valid origin id.
pub fn paneName(buf: *[PANE_NAME_LEN]u8, origin_id: []const u8) ?[]const u8 {
    if (!wire.validSessionOriginId(origin_id)) return null;
    @memcpy(buf[0..PANE_PREFIX.len], PANE_PREFIX);
    @memcpy(buf[PANE_PREFIX.len..], origin_id[0..PANE_CHARS]);
    return buf;
}

/// The slug of `text`: ASCII letters and digits lowercased, every other
/// run (spaces, punctuation, non-ASCII bytes) one `-`, no `-` at either
/// end, cut to `SLUG_MAX`. Null when nothing is left or the slug lies in
/// a reserved space (it would read as an address).
pub fn slugify(buf: *[SLUG_MAX]u8, text: []const u8) ?[]const u8 {
    var n: usize = 0;
    var dash = false;
    for (text) |ch| {
        const lower = std.ascii.toLower(ch);
        if (std.ascii.isAlphanumeric(ch) and ch < 0x80) {
            if (dash and n > 0) {
                if (n + 1 >= SLUG_MAX) break;
                buf[n] = '-';
                n += 1;
            }
            dash = false;
            if (n >= SLUG_MAX) break;
            buf[n] = lower;
            n += 1;
        } else dash = true;
    }
    const slug = buf[0..n];
    if (slug.len == 0 or isReservedName(slug)) return null;
    return slug;
}

/// Whether `text` is an alias as the broker assigns them: a slug,
/// possibly suffixed, at most `ALIAS_MAX` bytes.
pub fn validAlias(text: []const u8) bool {
    if (text.len == 0 or text.len > ALIAS_MAX) return false;
    if (text[0] == '-' or text[text.len - 1] == '-' or isReservedName(text)) return false;
    for (text, 0..) |ch, i| switch (ch) {
        'a'...'z', '0'...'9' => {},
        '-' => if (text[i - 1] == '-') return false,
        else => return false,
    };
    return true;
}

/// Candidate `k` for `base`: `base` itself, then `base-1`, `base-2`, ...
pub fn aliasCandidate(buf: *[ALIAS_MAX]u8, base: []const u8, k: u32) []const u8 {
    if (k == 0) return std.fmt.bufPrint(buf, "{s}", .{base[0..@min(base.len, ALIAS_MAX)]}) catch unreachable;
    const b = base[0..@min(base.len, SLUG_MAX)];
    return std.fmt.bufPrint(buf, "{s}-{d}", .{ b, @min(k, ALIAS_SUFFIX_MAX) }) catch unreachable;
}

/// `alias` without a suffix `aliasCandidate` adds (`-` and 1-3 digits),
/// so a re-suffixed alias counts from its base again.
pub fn aliasBase(alias: []const u8) []const u8 {
    const dash = std.mem.lastIndexOfScalar(u8, alias, '-') orelse return alias;
    const digits = alias[dash + 1 ..];
    if (dash == 0 or digits.len == 0 or digits.len > 3) return alias;
    for (digits) |ch| if (!std.ascii.isDigit(ch)) return alias;
    return alias[0..dash];
}

/// The durable address of a program that asked for the alias `name`:
/// `n-` and 8 hex of its slug's hash; null when `name` has no slug.
pub fn namedAddress(buf: *[NAMED_NAME_LEN]u8, name: []const u8) ?[]const u8 {
    var sb: [SLUG_MAX]u8 = undefined;
    const slug = slugify(&sb, name) orelse return null;
    const h: u32 = @truncate(std.hash.Wyhash.hash(0, slug));
    _ = std.fmt.bufPrint(buf, NAMED_PREFIX ++ "{x:0>8}", .{h}) catch unreachable;
    return buf;
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

test "a pane name is p- and the origin id's first 8 hex; both reserved spaces are recognised" {
    var buf: [PANE_NAME_LEN]u8 = undefined;
    const name = paneName(&buf, "3fa9c2e17b0d4e5f8a6b1c2d3e4f5a6b").?;
    try t.expectEqualStrings("p-3fa9c2e1", name);
    try validName(name);
    try t.expect(isPaneName(name) and isReservedName(name));
    try t.expect(isReservedName("anon-k3f9"));
    try t.expect(!isReservedName("Zenit") and !isReservedName("pane-1"));
    // Not an origin id: wrong length, uppercase, not hex.
    try t.expect(paneName(&buf, "3fa9c2e1") == null);
    try t.expect(paneName(&buf, "3FA9C2E17B0D4E5F8A6B1C2D3E4F5A6B") == null);
    try t.expect(paneName(&buf, "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz") == null);
    try t.expect(paneName(&buf, "") == null);
}

test "slugs: lowercase alphanumerics, one dash per run, trimmed, cut, never reserved" {
    var b: [SLUG_MAX]u8 = undefined;
    try t.expectEqualStrings("zenit", slugify(&b, "Zenit").?);
    try t.expectEqualStrings("template-links", slugify(&b, "  Template links!! ").?);
    try t.expectEqualStrings("caf-work", slugify(&b, "Caf\u{e9} work").?);
    try t.expectEqualStrings("qq", slugify(&b, "Qq").?);
    try t.expect(slugify(&b, "") == null);
    try t.expect(slugify(&b, "--- !!") == null);
    // A slug that reads as an address is no alias.
    try t.expect(slugify(&b, "p-3fa9c2e1") == null);
    try t.expect(slugify(&b, "Anon-x") == null);
    try t.expect(slugify(&b, "n-1") == null);
    // Cut to SLUG_MAX, never ending in a dash.
    const long = slugify(&b, "a" ** 47 ++ " bcd").?;
    try t.expectEqual(@as(usize, 47), long.len);
    try t.expectEqual(@as(usize, SLUG_MAX), slugify(&b, "x" ** 80).?.len);
    // Every slug is a valid alias and a valid name.
    try t.expect(validAlias("template-links"));
    try validName(slugify(&b, "x" ** 80).?);
    try t.expect(!validAlias("Zenit") and !validAlias("a--b") and !validAlias("-a") and !validAlias("p-1") and !validAlias(""));
}

test "alias candidates suffix from the base; the base strips a suffix again" {
    var b: [ALIAS_MAX]u8 = undefined;
    try t.expectEqualStrings("zenit", aliasCandidate(&b, "zenit", 0));
    try t.expectEqualStrings("zenit-1", aliasCandidate(&b, "zenit", 1));
    try t.expectEqualStrings("zenit-12", aliasCandidate(&b, "zenit", 12));
    try t.expect(validAlias(aliasCandidate(&b, "x" ** SLUG_MAX, ALIAS_SUFFIX_MAX)));
    try validName(aliasCandidate(&b, "x" ** SLUG_MAX, ALIAS_SUFFIX_MAX));
    try t.expectEqualStrings("zenit", aliasBase("zenit-1"));
    try t.expectEqualStrings("zenit", aliasBase("zenit-999"));
    try t.expectEqualStrings("build-2024", aliasBase("build-2024"));
    try t.expectEqualStrings("zenit", aliasBase("zenit"));
    try t.expectEqualStrings("-1", aliasBase("-1"));
}

test "a named address is n- and the hash of the name's slug: same slug, same address" {
    var b1: [NAMED_NAME_LEN]u8 = undefined;
    var b2: [NAMED_NAME_LEN]u8 = undefined;
    const a = namedAddress(&b1, "webapp").?;
    try t.expect(isNamedName(a) and isReservedName(a));
    try validName(a);
    try t.expectEqual(@as(usize, NAMED_NAME_LEN), a.len);
    try t.expectEqualStrings(a, namedAddress(&b2, "WebApp").?);
    try t.expect(!std.mem.eql(u8, a, namedAddress(&b2, "other").?));
    try t.expect(namedAddress(&b2, "!!") == null);
}
