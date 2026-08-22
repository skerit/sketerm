//! Tiny percent-codec: decoder for OSC 7 file:// URLs, encoder for
//! URL query components (web-search strings).
//!
//! `%XX` where XX is two hex digits decodes to the byte 0xXX.
//! Invalid escapes pass through untouched (lenient — better than
//! erroring on a poorly-formed shell-side helper).

const std = @import("std");

/// Percent-encode `s` as an RFC 3986 query component into `out`.
///
/// Everything outside the unreserved set (ALPHA / DIGIT / `-._~`) is
/// escaped, spaces included (`%20`, not `+`).
/// @return null when `out` is too small for the encoded form.
pub fn encodeQueryInto(out: []u8, s: []const u8) ?[]const u8 {
    const hex = "0123456789ABCDEF";
    var w: usize = 0;
    for (s) |b| {
        const unreserved = std.ascii.isAlphanumeric(b) or
            b == '-' or b == '.' or b == '_' or b == '~';
        if (unreserved) {
            if (w >= out.len) return null;
            out[w] = b;
            w += 1;
        } else {
            if (w + 3 > out.len) return null;
            out[w] = '%';
            out[w + 1] = hex[b >> 4];
            out[w + 2] = hex[b & 0xf];
            w += 3;
        }
    }
    return out[0..w];
}

/// A byte a file:// URI keeps literal: the RFC 3986 unreserved set
/// (ALPHA / DIGIT / `-._~`) plus the path separator. Everything else,
/// UTF-8 bytes included, is %XX-escaped -- which is what
/// `g_filename_to_uri` does, so thumbnail keys hash identically.
pub fn isFileUriByte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or switch (b) {
        '-', '.', '_', '~', '/' => true,
        else => false,
    };
}

pub fn decode(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = try allocator.alloc(u8, s.len);
    errdefer allocator.free(out);
    var w: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch {
                out[w] = s[i];
                w += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch {
                out[w] = s[i];
                w += 1;
                continue;
            };
            out[w] = (hi << 4) | lo;
            w += 1;
            i += 2;
        } else {
            out[w] = s[i];
            w += 1;
        }
    }
    return try allocator.realloc(out, w);
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

test "encodeQueryInto escapes reserved bytes and spaces" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("plain-word_1.2~x", encodeQueryInto(&buf, "plain-word_1.2~x").?);
    try std.testing.expectEqualStrings("two%20words", encodeQueryInto(&buf, "two words").?);
    try std.testing.expectEqualStrings("a%26b%3Dc%3Fd%2Fe%2Bf", encodeQueryInto(&buf, "a&b=c?d/e+f").?);
    try std.testing.expectEqualStrings("%E4%B8%AD", encodeQueryInto(&buf, "\xE4\xB8\xAD").?);
}

test "encodeQueryInto reports a too-small buffer" {
    var tiny: [2]u8 = undefined;
    try std.testing.expect(encodeQueryInto(&tiny, "abc") == null);
    try std.testing.expect(encodeQueryInto(&tiny, "&") == null);
}

test "isFileUriByte covers the unreserved set plus the separator" {
    const t = std.testing;
    for ("abzABZ059-._~/") |b| try t.expect(isFileUriByte(b));
    // The reserved and unsafe bytes on either boundary of the ranges.
    for ("%+ ?#&=:@,;'\"<>[]{}|\\^`\t\n") |b| try t.expect(!isFileUriByte(b));
    try t.expect(!isFileUriByte(0));
    try t.expect(!isFileUriByte(0x7f));
    try t.expect(!isFileUriByte(0x80));
    try t.expect(!isFileUriByte(0xff));
}
