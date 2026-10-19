//! Numbers as a person (or a model) reads them in one line of text:
//! rounded to what matters, never 16 digits of float. libc-free, so both
//! dependency sets import it.

const std = @import("std");

const Unit = struct { div: u64, suffix: []const u8 };
const UNITS = [_]Unit{
    .{ .div = 1_000, .suffix = "k" },
    .{ .div = 1_000_000, .suffix = "M" },
    .{ .div = 1_000_000_000, .suffix = "G" },
};

/// `n` as a compact count: exact below 1000, then one decimal below 10 of
/// a unit ("1.2k"; a ".0" is dropped), whole units above ("194k").
pub fn count(buf: []u8, n: u64) []const u8 {
    if (n < 1000) return std.fmt.bufPrint(buf, "{d}", .{n}) catch "?";
    for (UNITS, 0..) |u, i| {
        const whole = (n + u.div / 2) / u.div;
        // 999.6k reads as 1M, never as 1000k.
        if (whole >= 1000 and i + 1 < UNITS.len) continue;
        const tenths = (n * 10 + u.div / 2) / u.div;
        if (tenths < 100 and tenths % 10 != 0)
            return std.fmt.bufPrint(buf, "{d}.{d}{s}", .{ tenths / 10, tenths % 10, u.suffix }) catch "?";
        return std.fmt.bufPrint(buf, "{d}{s}", .{ whole, u.suffix }) catch "?";
    }
    unreachable;
}

const BYTE_UNITS = [_][]const u8{ "KiB", "MiB", "GiB", "TiB" };

/// `n` bytes in binary units with one decimal below 10 of a unit ("1.2 MiB",
/// "340 KiB"); exact bytes below 1 KiB, so a small file never reads "0 KiB".
pub fn bytes(buf: []u8, n: u64) []const u8 {
    if (n < 1024) return std.fmt.bufPrint(buf, "{d} B", .{n}) catch "?";
    var div: u64 = 1024;
    for (BYTE_UNITS, 0..) |suffix, i| {
        const whole = (n + div / 2) / div;
        // 1023.6 KiB reads as 1 MiB, never as 1024 KiB.
        if (whole >= 1024 and i + 1 < BYTE_UNITS.len) {
            div *= 1024;
            continue;
        }
        const tenths = (n * 10 + div / 2) / div;
        if (tenths < 100 and tenths % 10 != 0)
            return std.fmt.bufPrint(buf, "{d}.{d} {s}", .{ tenths / 10, tenths % 10, suffix }) catch "?";
        return std.fmt.bufPrint(buf, "{d} {s}", .{ whole, suffix }) catch "?";
    }
    unreachable;
}

test "count rounds to what a reader needs" {
    const t = std.testing;
    var buf: [24]u8 = undefined;
    try t.expectEqualStrings("0", count(&buf, 0));
    try t.expectEqualStrings("999", count(&buf, 999));
    try t.expectEqualStrings("1k", count(&buf, 1000));
    try t.expectEqualStrings("1.2k", count(&buf, 1249));
    try t.expectEqualStrings("9.9k", count(&buf, 9949));
    try t.expectEqualStrings("10k", count(&buf, 9950));
    try t.expectEqualStrings("194k", count(&buf, 194_029));
    try t.expectEqualStrings("1M", count(&buf, 999_600));
    try t.expectEqualStrings("1.5M", count(&buf, 1_480_000));
    try t.expectEqualStrings("1.5G", count(&buf, 1_480_000_000));
}

test "bytes reads in binary units, exact under 1 KiB" {
    const t = std.testing;
    var buf: [24]u8 = undefined;
    try t.expectEqualStrings("0 B", bytes(&buf, 0));
    try t.expectEqualStrings("1023 B", bytes(&buf, 1023));
    try t.expectEqualStrings("1 KiB", bytes(&buf, 1024));
    try t.expectEqualStrings("1.5 KiB", bytes(&buf, 1536));
    try t.expectEqualStrings("340 KiB", bytes(&buf, 340 * 1024));
    try t.expectEqualStrings("1 MiB", bytes(&buf, 1024 * 1024 - 100));
    try t.expectEqualStrings("1.2 MiB", bytes(&buf, 1258291));
    try t.expectEqualStrings("3 GiB", bytes(&buf, 3 << 30));
}
