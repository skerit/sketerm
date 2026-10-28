//! A parsed JSON value copied whole into another allocator, so it can
//! outlive the arena it was parsed in.

const std = @import("std");

/// Every string, array and object of `v`, freshly allocated in `a`.
pub fn clone(a: std.mem.Allocator, v: std.json.Value) error{OutOfMemory}!std.json.Value {
    const text = std.json.Stringify.valueAlloc(a, v, .{}) catch return error.OutOfMemory;
    return std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch error.OutOfMemory;
}

test "a clone survives the arena of the original" {
    var copy_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer copy_arena.deinit();
    const copy = blk: {
        var src = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer src.deinit();
        const v = try std.json.parseFromSliceLeaky(std.json.Value, src.allocator(), "{\"pane\":7,\"wait\":{\"for\":\"selector\",\"arg\":\"#a\"}}", .{});
        break :blk try clone(copy_arena.allocator(), v);
    };
    try std.testing.expectEqual(@as(i64, 7), copy.object.get("pane").?.integer);
    try std.testing.expectEqualStrings("#a", copy.object.get("wait").?.object.get("arg").?.string);
}
