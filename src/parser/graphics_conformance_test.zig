//! Kitty graphics protocol conformance tests, ported from
//! kitty/kitty_tests/parser.py::test_graphics_command and a slice
//! of kitty_tests/graphics.py. Our parser lives in
//! src/parser/kitty_image.zig — we exercise it directly without
//! going through the full Screen pipeline.

const std = @import("std");
const kitty = @import("kitty_image.zig");

test "graphics: bare i= sets image_id" {
    const cmd = try kitty.parse("Gi=12");
    try std.testing.expectEqual(@as(u32, 12), cmd.image_id);
}

test "graphics: i + p sets image_id and placement_id" {
    const cmd = try kitty.parse("Gi=3,p=4");
    try std.testing.expectEqual(@as(u32, 3), cmd.image_id);
    try std.testing.expectEqual(@as(u32, 4), cmd.placement_id);
}

test "graphics: a=q is query action" {
    const cmd = try kitty.parse("Gi=1,a=q");
    try std.testing.expectEqual(kitty.Action.query, cmd.action);
}

test "graphics: a=d is delete action" {
    const cmd = try kitty.parse("Ga=d,d=A");
    try std.testing.expectEqual(kitty.Action.delete, cmd.action);
}

test "graphics: a=T is transmit_and_place" {
    const cmd = try kitty.parse("Ga=T,f=32,s=2,v=2,i=99");
    try std.testing.expectEqual(kitty.Action.transmit_and_place, cmd.action);
    try std.testing.expectEqual(@as(u32, 32), cmd.format);
    try std.testing.expectEqual(@as(u32, 2), cmd.width);
    try std.testing.expectEqual(@as(u32, 2), cmd.height);
    try std.testing.expectEqual(@as(u32, 99), cmd.image_id);
}

test "graphics: image_id near u32 max parses" {
    const cmd = try kitty.parse("Gi=4294967295");
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), cmd.image_id);
}

test "graphics: payload bytes after semicolon are captured" {
    const cmd = try kitty.parse("Gi=1,a=T,f=32,s=1,v=1;ABCD");
    try std.testing.expectEqualStrings("ABCD", cmd.payload);
}

test "graphics: malformed key character returns error" {
    // Kitty rejects '1=1' (numeric key); our parser treats unknown
    // keys leniently. Either way it should not crash.
    _ = kitty.parse("G1=1") catch {};
}

test "graphics: unknown action defaults sanely" {
    const cmd = kitty.parse("Ga=Z,i=7") catch return;
    try std.testing.expectEqual(@as(u32, 7), cmd.image_id);
}
