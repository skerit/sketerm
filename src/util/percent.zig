//! Tiny percent-decoder for OSC 7 file:// URLs.
//!
//! `%XX` where XX is two hex digits decodes to the byte 0xXX.
//! Invalid escapes pass through untouched (lenient — better than
//! erroring on a poorly-formed shell-side helper).

const std = @import("std");

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
