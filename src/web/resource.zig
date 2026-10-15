//! Engine-agnostic request resource classes, shared by the filter engine, the
//! network policies and the helper wire's `rtype` byte.

const std = @import("std");

/// The integer values ARE the wire byte; never renumber a member.
pub const Resource = enum(u8) {
    other = 0,
    document = 1,
    subdocument = 2,
    stylesheet = 3,
    script = 4,
    image = 5,
    font = 6,
    xhr = 7,
    media = 8,
    websocket = 9,
    ping = 10,

    /// Every class's bit set.
    pub const all_mask: u16 = blk: {
        var m: u16 = 0;
        for (std.enums.values(Resource)) |r| m |= r.bit();
        break :blk m;
    };

    pub fn bit(self: Resource) u16 {
        return @as(u16, 1) << @as(u4, @intCast(@intFromEnum(self)));
    }

    /// A wire byte this build does not know (a newer helper's class) reads as `other`.
    pub fn fromWire(b: u8) Resource {
        return std.enums.fromInt(Resource, b) orelse .other;
    }
};

test "wire values are pinned, unknown bytes read as other, mask covers every class" {
    const t = std.testing;
    const pinned = [_]struct { Resource, u8 }{
        .{ .other, 0 },  .{ .document, 1 }, .{ .subdocument, 2 }, .{ .stylesheet, 3 },
        .{ .script, 4 }, .{ .image, 5 },    .{ .font, 6 },        .{ .xhr, 7 },
        .{ .media, 8 },  .{ .websocket, 9 }, .{ .ping, 10 },
    };
    try t.expectEqual(std.enums.values(Resource).len, pinned.len);
    for (pinned) |p| {
        try t.expectEqual(p[1], @intFromEnum(p[0]));
        try t.expectEqual(p[0], Resource.fromWire(p[1]));
    }
    try t.expectEqual(Resource.other, Resource.fromWire(11));
    try t.expectEqual(Resource.other, Resource.fromWire(255));
    try t.expectEqual(@as(u16, 0x7ff), Resource.all_mask);
}
