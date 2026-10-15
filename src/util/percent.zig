//! The percent-codec: `%XX` escapes for URL query components and
//! file:// URIs, and the lenient decoder every URI reader shares.
//!
//! `%XX` where XX is two hex digits decodes to the byte 0xXX.
//! Invalid escapes pass through untouched (lenient — better than
//! erroring on a poorly-formed shell-side helper).

const std = @import("std");

/// Which bytes an encoding keeps literal; every other byte, UTF-8 included, becomes uppercase `%XX`.
pub const SafeSet = enum {
    /// RFC 3986 unreserved (ALPHA / DIGIT / `-._~`): a query component, spaces as `%20` never `+`.
    query,
    /// Unreserved plus `/`: what `g_filename_to_uri` keeps, so thumbnail keys and trash `Path=` lines
    /// hash and compare identically to GLib's. Never widen it: every cached thumbnail key would change.
    file_uri,
    /// Every RFC 3986 path character (unreserved, sub-delims, `:`, `@`, `/`): LSP document URIs, since
    /// over-escaping makes URIs some language servers fail to match against their own.
    uri_path,

    pub fn keeps(self: SafeSet, b: u8) bool {
        if (std.ascii.isAlphanumeric(b)) return true;
        return switch (b) {
            '-', '.', '_', '~' => true,
            '/' => switch (self) {
                .query => false,
                .file_uri, .uri_path => true,
            },
            '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=', ':', '@' => switch (self) {
                .query, .file_uri => false,
                .uri_path => true,
            },
            else => false,
        };
    }
};

/// Percent-encode `s` into `w`, keeping the bytes `set` keeps.
pub fn encode(w: *std.Io.Writer, set: SafeSet, s: []const u8) std.Io.Writer.Error!void {
    const hex = "0123456789ABCDEF";
    for (s) |b| {
        if (set.keeps(b)) {
            try w.writeByte(b);
        } else {
            try w.writeAll(&.{ '%', hex[b >> 4], hex[b & 0xf] });
        }
    }
}

/// Decode `s` into `out`, stopping early when `out` fills; never longer than `s`.
/// @return the decoded prefix of `out`.
pub fn decodeInto(out: []u8, s: []const u8) []u8 {
    var w: usize = 0;
    var i: usize = 0;
    while (i < s.len and w < out.len) {
        if (escapedByte(s[i..])) |b| {
            out[w] = b;
            i += 3;
        } else {
            out[w] = s[i];
            i += 1;
        }
        w += 1;
    }
    return out[0..w];
}

/// The byte a well-formed `%XX` at the start of `s` stands for.
fn escapedByte(s: []const u8) ?u8 {
    if (s.len < 3 or s[0] != '%') return null;
    const hi = std.fmt.charToDigit(s[1], 16) catch return null;
    const lo = std.fmt.charToDigit(s[2], 16) catch return null;
    return hi << 4 | lo;
}

/// Decode `s` into a caller-owned slice.
pub fn decode(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, s.len);
    errdefer allocator.free(out);
    const n = decodeInto(out, s).len;
    return try allocator.realloc(out, n);
}

fn expectEncoded(set: SafeSet, s: []const u8, want: []const u8) !void {
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try encode(&w, set, s);
    try std.testing.expectEqualStrings(want, w.buffered());
}

test "ascii passthrough" {
    const out = try decode(std.testing.allocator, "/home/foo");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("/home/foo", out);
}

test "decode space" {
    const out = try decode(std.testing.allocator, "/home/foo%20bar");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("/home/foo bar", out);
}

test "decode utf8" {
    const out = try decode(std.testing.allocator, "%E4%B8%AD"); // 中
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("\xE4\xB8\xAD", out);
}

test "lenient on bad escape" {
    const out = try decode(std.testing.allocator, "100% sure");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("100% sure", out);
}

test "query encoding escapes reserved bytes and spaces" {
    try expectEncoded(.query, "plain-word_1.2~x", "plain-word_1.2~x");
    try expectEncoded(.query, "two words", "two%20words");
    try expectEncoded(.query, "a&b=c?d/e+f", "a%26b%3Dc%3Fd%2Fe%2Bf");
    try expectEncoded(.query, "\xE4\xB8\xAD", "%E4%B8%AD");
}

test "encode reports a too-small buffer" {
    var tiny: [2]u8 = undefined;
    var w = std.Io.Writer.fixed(&tiny);
    try std.testing.expectError(error.WriteFailed, encode(&w, .query, "abc"));
    w = std.Io.Writer.fixed(&tiny);
    try std.testing.expectError(error.WriteFailed, encode(&w, .query, "&"));
}

test "each safe set keeps exactly its bytes" {
    const t = std.testing;
    for ("abzABZ059-._~") |b| {
        for (std.enums.values(SafeSet)) |set| try t.expect(set.keeps(b));
    }
    try t.expect(!SafeSet.query.keeps('/'));
    try t.expect(SafeSet.file_uri.keeps('/') and SafeSet.uri_path.keeps('/'));
    for ("!$&'()*+,;=:@") |b| {
        try t.expect(!SafeSet.query.keeps(b));
        try t.expect(!SafeSet.file_uri.keeps(b));
        try t.expect(SafeSet.uri_path.keeps(b));
    }
    // The bytes no set keeps, on either boundary of the ranges.
    for ("% ?#\"<>[]{}|\\^`\t\n\x00\x7f\x80\xff") |b| {
        for (std.enums.values(SafeSet)) |set| try t.expect(!set.keeps(b));
    }
    try expectEncoded(.file_uri, "/a b/\xc3\xa9+", "/a%20b/%C3%A9%2B");
    try expectEncoded(.uri_path, "/a b/\xc3\xa9+:@", "/a%20b/%C3%A9+:@");
}

test "decodeInto is lenient and stops when the buffer fills" {
    const t = std.testing;
    var buf: [8]u8 = undefined;
    try t.expectEqualStrings("a b", decodeInto(&buf, "a%20b"));
    try t.expectEqualStrings("%4g%", decodeInto(&buf, "%4g%"));
    try t.expectEqualStrings("%2", decodeInto(&buf, "%2"));
    try t.expectEqualStrings("\xab", decodeInto(&buf, "%aB"));
    var small: [3]u8 = undefined;
    try t.expectEqualStrings("a b", decodeInto(&small, "a%20bcdef"));
}
