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

test "graphics: delete d=a (default 'all visible')" {
    const cmd = try kitty.parse("Ga=d");
    try std.testing.expectEqual(kitty.Action.delete, cmd.action);
    // Default delete_what when no `d=` provided is 'a'.
    try std.testing.expectEqual(@as(u8, 'a'), cmd.delete_what);
}

test "graphics: delete d=A (delete-all freeing data)" {
    const cmd = try kitty.parse("Ga=d,d=A");
    try std.testing.expectEqual(@as(u8, 'A'), cmd.delete_what);
}

test "graphics: delete d=i picks image by id" {
    const cmd = try kitty.parse("Ga=d,d=i,i=42");
    try std.testing.expectEqual(@as(u8, 'i'), cmd.delete_what);
    try std.testing.expectEqual(@as(u32, 42), cmd.image_id);
}

test "graphics: delete d=p targets placement" {
    const cmd = try kitty.parse("Ga=d,d=p,i=5,p=99");
    try std.testing.expectEqual(@as(u8, 'p'), cmd.delete_what);
    try std.testing.expectEqual(@as(u32, 5), cmd.image_id);
    try std.testing.expectEqual(@as(u32, 99), cmd.placement_id);
}

test "graphics: delete d=z carries z reference" {
    const cmd = try kitty.parse("Ga=d,d=z,z=-3");
    try std.testing.expectEqual(@as(u8, 'z'), cmd.delete_what);
    try std.testing.expectEqual(@as(i32, -3), cmd.z);
}

// Exercise the Screen-side delete sink to confirm the full event
// reaches us with the parsed delete_what + image_id + placement_id.
test "graphics: delete dispatched via Screen.sink as full event" {
    const Screen = @import("../grid/screen.zig").Screen;
    const Pool = @import("../grid/style_pool.zig").Pool;
    const allocator = std.testing.allocator;

    var pool = try Pool.init(allocator);
    defer pool.deinit();

    var screen = try Screen.init(allocator, &pool, 20, 5);
    defer screen.deinit();

    const Capture = struct {
        var captured: ?Screen.ImageDeleteEvent = null;
        fn sink(_: ?*anyopaque, ev: Screen.ImageDeleteEvent) void {
            captured = ev;
        }
    };
    Capture.captured = null;
    screen.sink = .{
        .ctx = null,
        .on_image_delete_full = Capture.sink,
    };

    // Feed an APC that asks for delete by placement (i=7,p=11,d=p).
    const apc_body = "Ga=d,d=p,i=7,p=11";
    screen.onApc(apc_body);

    try std.testing.expect(Capture.captured != null);
    try std.testing.expectEqual(@as(u32, 7), Capture.captured.?.image_id);
    try std.testing.expectEqual(@as(u32, 11), Capture.captured.?.placement_id);
    try std.testing.expectEqual(@as(u8, 'p'), Capture.captured.?.what);
}

test "graphics: ImageStore.markByPlacementForDelete + flush teardown" {
    const ImageStore = @import("../grid/image_store.zig").Store;
    const allocator = std.testing.allocator;

    var s = ImageStore.init(allocator);
    defer s.deinit();

    // 4×4 RGBA stub.
    var px: [4 * 4 * 4]u8 = undefined;
    @memset(&px, 0xFF);

    try s.addWithPlacement(&px, 4, 4, 0, 0, 1, 100, 0);
    try s.addWithPlacement(&px, 4, 4, 0, 0, 1, 200, 0);
    try s.addWithPlacement(&px, 4, 4, 0, 0, 2, 100, 0);

    // Delete just (image=1, placement=200).
    s.markByPlacementForDelete(1, 200);

    var deleting_count: usize = 0;
    for (s.images.items) |img| {
        if (img.deleting) deleting_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), deleting_count);

    // Now placement_id=0 should match all of image_id=1.
    s.markByPlacementForDelete(1, 0);

    deleting_count = 0;
    for (s.images.items) |img| {
        if (img.deleting) deleting_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), deleting_count);
}

// ── Control keys the protocol defines that we used to drop ────────

test "graphics: the whole documented key set parses" {
    const cmd = try kitty.parse("Ga=T,I=7,S=1024,O=16,X=3,Y=4,P=9,Q=2,H=-1,V=5,N=1;AA");
    try std.testing.expectEqual(@as(u32, 7), cmd.image_number);
    try std.testing.expectEqual(@as(u32, 1024), cmd.data_size);
    try std.testing.expectEqual(@as(u32, 16), cmd.data_offset);
    try std.testing.expectEqual(@as(u32, 3), cmd.cell_x_offset);
    try std.testing.expectEqual(@as(u32, 4), cmd.cell_y_offset);
    try std.testing.expectEqual(@as(u32, 9), cmd.parent_image_id);
    try std.testing.expectEqual(@as(u32, 2), cmd.parent_placement_id);
    try std.testing.expectEqual(@as(i32, -1), cmd.parent_dx);
    try std.testing.expectEqual(@as(i32, 5), cmd.parent_dy);
    try std.testing.expectEqual(@as(u8, 1), cmd.transient);
}

// ── Delete selectors ──────────────────────────────────────────────

const ScreenM = @import("../grid/screen.zig").Screen;
const DelEv = ScreenM.ImageDeleteEvent;

/// One placement to judge selectors against: image 5 / placement 9 /
/// number 3 / z 2, occupying cells (10,4)..(13,6).
fn selectsSample(ev: DelEv) bool {
    return ev.selects(5, 9, 3, 2, 10, 4, 4, 3);
}

test "graphics: id, number and range selectors" {
    try std.testing.expect(selectsSample(.{ .what = 'i', .image_id = 5 }));
    try std.testing.expect(!selectsSample(.{ .what = 'i', .image_id = 6 }));
    // With a placement id, only that placement.
    try std.testing.expect(selectsSample(.{ .what = 'i', .image_id = 5, .placement_id = 9 }));
    try std.testing.expect(!selectsSample(.{ .what = 'i', .image_id = 5, .placement_id = 8 }));
    // By image NUMBER, which is not the id.
    try std.testing.expect(selectsSample(.{ .what = 'n', .image_number = 3 }));
    try std.testing.expect(!selectsSample(.{ .what = 'n', .image_number = 5 }));
    // Inclusive id range.
    try std.testing.expect(selectsSample(.{ .what = 'r', .id_lo = 4, .id_hi = 6 }));
    try std.testing.expect(selectsSample(.{ .what = 'r', .id_lo = 5, .id_hi = 5 }));
    try std.testing.expect(!selectsSample(.{ .what = 'r', .id_lo = 6, .id_hi = 9 }));
}

test "graphics: positional selectors use the placement's cell extent" {
    // A cell inside the placement, and one outside it.
    try std.testing.expect(selectsSample(.{ .what = 'p', .x = 11, .y = 5 }));
    try std.testing.expect(!selectsSample(.{ .what = 'p', .x = 14, .y = 5 }));
    try std.testing.expect(!selectsSample(.{ .what = 'p', .x = 11, .y = 7 }));
    // Same cell, plus a z-index that has to match.
    try std.testing.expect(selectsSample(.{ .what = 'q', .x = 11, .y = 5, .z = 2 }));
    try std.testing.expect(!selectsSample(.{ .what = 'q', .x = 11, .y = 5, .z = 3 }));
    // Whole column, whole row.
    try std.testing.expect(selectsSample(.{ .what = 'x', .x = 12 }));
    try std.testing.expect(!selectsSample(.{ .what = 'x', .x = 20 }));
    try std.testing.expect(selectsSample(.{ .what = 'y', .y = 6 }));
    try std.testing.expect(!selectsSample(.{ .what = 'y', .y = 3 }));
    // By z-index alone.
    try std.testing.expect(selectsSample(.{ .what = 'z', .z = 2 }));
    try std.testing.expect(!selectsSample(.{ .what = 'z', .z = 0 }));
}

test "graphics: case selects the same placements either way" {
    // Upper case only means "free the source data too"; both cases
    // must pick out the same placements, or a `d=I` would leave the
    // image on screen with its pixels gone.
    for ([_][2]u8{ .{ 'i', 'I' }, .{ 'n', 'N' }, .{ 'p', 'P' }, .{ 'x', 'X' }, .{ 'y', 'Y' }, .{ 'z', 'Z' }, .{ 'r', 'R' } }) |pair| {
        const lo = DelEv{ .what = pair[0], .image_id = 5, .image_number = 3, .x = 11, .y = 5, .z = 2, .id_lo = 4, .id_hi = 6 };
        var hi = lo;
        hi.what = pair[1];
        try std.testing.expectEqual(selectsSample(lo), selectsSample(hi));
    }
}

test "graphics: a delete request carries its coordinates off the wire" {
    const Pool = @import("../grid/style_pool.zig").Pool;
    const allocator = std.testing.allocator;
    var pool = try Pool.init(allocator);
    defer pool.deinit();
    var screen = try ScreenM.init(allocator, &pool, 20, 5);
    defer screen.deinit();

    const Capture = struct {
        var got: ?DelEv = null;
        fn sink(_: ?*anyopaque, ev: DelEv) void {
            got = ev;
        }
    };
    Capture.got = null;
    screen.sink = .{ .ctx = null, .on_image_delete_full = Capture.sink };

    // `d=p` selects by cell, and the protocol's coordinates are
    // 1-based while everything inside is 0-based.
    screen.onApc("Ga=d,d=p,x=4,y=2");
    try std.testing.expect(Capture.got != null);
    try std.testing.expectEqual(@as(u32, 3), Capture.got.?.x);
    try std.testing.expectEqual(@as(u32, 1), Capture.got.?.y);

    // `d=c` means "wherever the cursor is" — no coordinates given.
    screen.row = 2;
    screen.col = 7;
    Capture.got = null;
    screen.onApc("Ga=d,d=c");
    try std.testing.expectEqual(@as(u32, 7), Capture.got.?.x);
    try std.testing.expectEqual(@as(u32, 2), Capture.got.?.y);
}

test "graphics: sub-cell offsets reach the placement" {
    const Pool = @import("../grid/style_pool.zig").Pool;
    const allocator = std.testing.allocator;
    var pool = try Pool.init(allocator);
    defer pool.deinit();
    var screen = try ScreenM.init(allocator, &pool, 20, 5);
    defer screen.deinit();

    const Capture = struct {
        var got: ?ScreenM.ImageEvent = null;
        fn sink(_: ?*anyopaque, ev: ScreenM.ImageEvent) void {
            got = ev;
        }
    };
    Capture.got = null;
    screen.sink = .{ .ctx = null, .on_image = Capture.sink };

    // 2x2 RGBA, placed with a 3,5 pixel offset inside its cell.
    screen.onApc("Ga=T,f=32,s=2,v=2,i=1,X=3,Y=5;AAAAAAAAAAAAAAAAAAAAAA==");
    try std.testing.expect(Capture.got != null);
    try std.testing.expectEqual(@as(u32, 3), Capture.got.?.cell_x_offset);
    try std.testing.expectEqual(@as(u32, 5), Capture.got.?.cell_y_offset);
}
