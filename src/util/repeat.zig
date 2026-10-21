//! Comptime string repetition, the job of the `**` operator Zig 0.17 removed.

const std = @import("std");

/// `s` repeated `n` times, NUL-terminated like the string literal `s ** n` was.
/// Repeating a single byte is `&@as([n:0]u8, @splat(c))` instead, as in std.
pub inline fn repeat(comptime s: []const u8, comptime n: usize) *const [s.len * n:0]u8 {
    return comptime build(s, n);
}

fn build(comptime s: []const u8, comptime n: usize) *const [s.len * n:0]u8 {
    comptime {
        @setEvalBranchQuota(1000 + 2 * n);
        var out: [s.len * n:0]u8 = undefined;
        for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
        const final = out;
        return &final;
    }
}

test "repeat matches the old ** result, sentinel included" {
    const r = repeat("ab", 3);
    comptime std.debug.assert(@TypeOf(r) == *const [6:0]u8);
    try std.testing.expectEqualStrings("ababab", r);
    try std.testing.expectEqual(@as(u8, 0), r[6]);
    try std.testing.expectEqual(@as(usize, 0), repeat("xyz", 0).len);
    try std.testing.expectEqual(@as(usize, 2 * 5000), repeat("\xc3\xa9", 5000).len);
}
