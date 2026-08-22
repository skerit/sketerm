//! Lenient JSON number coercions for LSP and other wire payloads,
//! where a missing field and a wrongly typed field must both degrade
//! to a usable value rather than fail the whole message.

const std = @import("std");

/// @return the value of an `integer` node, null for anything else.
pub fn intOf(v: ?std.json.Value) ?i64 {
    const val = v orelse return null;
    return switch (val) {
        .integer => |i| i,
        else => null,
    };
}

/// An `integer` node as a count: missing, negative or non-integer reads as 0.
pub fn countOf(v: ?std.json.Value) usize {
    const i = intOf(v) orelse return 0;
    return if (i < 0) 0 else @intCast(i);
}

/// A u32 field (an LSP line/character), saturating at both ends.
/// `float` is accepted because JSON has a single number type and some
/// servers serialise positions as `3.0`.
pub fn u32Of(v: ?std.json.Value) u32 {
    const val = v orelse return 0;
    return switch (val) {
        .integer => |i| if (i < 0) 0 else if (i > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(i),
        .float => |f| if (f < 0) 0 else @intFromFloat(@min(f, @as(f64, std.math.maxInt(u32)))),
        else => 0,
    };
}

const t = std.testing;

test "intOf accepts only integer nodes" {
    try t.expectEqual(@as(?i64, null), intOf(null));
    try t.expectEqual(@as(?i64, 7), intOf(.{ .integer = 7 }));
    try t.expectEqual(@as(?i64, -7), intOf(.{ .integer = -7 }));
    try t.expectEqual(@as(?i64, null), intOf(.{ .float = 7.5 }));
    try t.expectEqual(@as(?i64, null), intOf(.{ .string = "7" }));
    try t.expectEqual(@as(?i64, null), intOf(.null));
}

test "countOf floors at zero" {
    try t.expectEqual(@as(usize, 0), countOf(null));
    try t.expectEqual(@as(usize, 0), countOf(.{ .integer = -1 }));
    try t.expectEqual(@as(usize, 5), countOf(.{ .integer = 5 }));
    try t.expectEqual(@as(usize, 0), countOf(.{ .float = 5.0 }));
}

test "u32Of saturates and takes whole floats" {
    const max: u32 = std.math.maxInt(u32);
    try t.expectEqual(@as(u32, 0), u32Of(null));
    try t.expectEqual(@as(u32, 0), u32Of(.{ .integer = -3 }));
    try t.expectEqual(@as(u32, 3), u32Of(.{ .integer = 3 }));
    try t.expectEqual(max, u32Of(.{ .integer = @as(i64, std.math.maxInt(u32)) + 1 }));
    try t.expectEqual(@as(u32, 3), u32Of(.{ .float = 3.7 }));
    try t.expectEqual(@as(u32, 0), u32Of(.{ .float = -3.7 }));
    try t.expectEqual(max, u32Of(.{ .float = 1e12 }));
    try t.expectEqual(@as(u32, 0), u32Of(.{ .string = "3" }));
}
