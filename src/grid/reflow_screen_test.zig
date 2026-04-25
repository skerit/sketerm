//! End-to-end reflow tests via Screen.resize. The reflow.zig
//! module has unit tests for build/trim/rechunk/positionInLogicals;
//! this file exercises the integration: Screen ingests bytes,
//! resize() is called with new cols, the result must preserve
//! soft-wrapped text correctly.

const std = @import("std");
const Harness = @import("../parser/test_harness.zig").Harness;

test "reflow: widening rejoins soft-wrapped logical line" {
    var h = try Harness.init(std.testing.allocator, 5, 4);
    defer h.deinit();
    h.arm();
    // "hellowor" wraps in 5-col screen: row0="hello", row1="wor"
    h.feed("hellowor");
    {
        const r0 = try h.line(std.testing.allocator, 0);
        defer std.testing.allocator.free(r0);
        try std.testing.expectEqualStrings("hello", r0);
        const r1 = try h.line(std.testing.allocator, 1);
        defer std.testing.allocator.free(r1);
        try std.testing.expectEqualStrings("wor", r1);
    }
    // Widen to 10 cols — should rejoin into a single row.
    try h.screen.resize(10, 4);
    const r0 = try h.line(std.testing.allocator, 0);
    defer std.testing.allocator.free(r0);
    try std.testing.expectEqualStrings("hellowor", r0);
}

test "reflow: narrowing splits a long line into multiple rows" {
    var h = try Harness.init(std.testing.allocator, 10, 4);
    defer h.deinit();
    h.arm();
    h.feed("hellowor");
    try h.screen.resize(5, 4);
    const r0 = try h.line(std.testing.allocator, 0);
    defer std.testing.allocator.free(r0);
    try std.testing.expectEqualStrings("hello", r0);
    const r1 = try h.line(std.testing.allocator, 1);
    defer std.testing.allocator.free(r1);
    try std.testing.expectEqualStrings("wor", r1);
}

test "reflow: separate logical lines stay separate" {
    var h = try Harness.init(std.testing.allocator, 10, 4);
    defer h.deinit();
    h.arm();
    h.feed("foo\r\nbar\r\nbaz");
    try h.screen.resize(20, 4);
    const r0 = try h.line(std.testing.allocator, 0);
    defer std.testing.allocator.free(r0);
    try std.testing.expectEqualStrings("foo", r0);
    const r1 = try h.line(std.testing.allocator, 1);
    defer std.testing.allocator.free(r1);
    try std.testing.expectEqualStrings("bar", r1);
    const r2 = try h.line(std.testing.allocator, 2);
    defer std.testing.allocator.free(r2);
    try std.testing.expectEqualStrings("baz", r2);
}

test "reflow: widening rejoins scrollback content too" {
    var h = try Harness.init(std.testing.allocator, 5, 2);
    defer h.deinit();
    h.arm();
    // "abcdefghij" wraps to 2 rows, then '\n' pushes them to scrollback.
    h.feed("abcdefghij\r\n");
    try std.testing.expect(h.screen.scrollbackCount() > 0);
    try h.screen.resize(10, 2);
    // After widening, the wrapped pair rejoins into one logical line.
    // Where it ends up depends on scrollback pressure, but the joined
    // text should be retrievable.
    var found_abc = false;
    var i: u32 = 0;
    while (i < h.screen.scrollbackCount()) : (i += 1) {
        const sb = h.screen.scrollbackLine(i);
        var col: usize = 0;
        while (col < sb.cells.len) : (col += 1) {
            if (sb.cells[col].rune == 'a') {
                // Check the whole word follows.
                if (col + 9 < sb.cells.len and
                    sb.cells[col + 9].rune == 'j')
                {
                    found_abc = true;
                }
            }
        }
    }
    // It might also be on the active screen depending on row count.
    if (!found_abc) {
        const r = try h.line(std.testing.allocator, 0);
        defer std.testing.allocator.free(r);
        if (std.mem.indexOf(u8, r, "abcdefghij") != null) found_abc = true;
    }
    try std.testing.expect(found_abc);
}

test "reflow: cursor follows its logical position on widen" {
    var h = try Harness.init(std.testing.allocator, 5, 4);
    defer h.deinit();
    h.arm();
    h.feed("hellowor"); // cursor at row 1 col 3 (after 'r')
    try std.testing.expectEqual(@as(u16, 1), h.screen.row);
    try std.testing.expectEqual(@as(u16, 3), h.screen.col);
    try h.screen.resize(10, 4);
    // After widening, cursor should be at row 0 col 8 (after the 'r'
    // in "hellowor").
    try std.testing.expectEqual(@as(u16, 0), h.screen.row);
    try std.testing.expectEqual(@as(u16, 8), h.screen.col);
}

test "reflow: cursor follows its logical position on narrow" {
    var h = try Harness.init(std.testing.allocator, 10, 4);
    defer h.deinit();
    h.arm();
    h.feed("hellowor"); // cursor at row 0 col 8
    try h.screen.resize(5, 4);
    // After narrowing, cursor should be at row 1 col 3.
    try std.testing.expectEqual(@as(u16, 1), h.screen.row);
    try std.testing.expectEqual(@as(u16, 3), h.screen.col);
}

test "reflow: rows-only resize doesn't reflow content" {
    var h = try Harness.init(std.testing.allocator, 5, 4);
    defer h.deinit();
    h.arm();
    h.feed("hellowor");
    try h.screen.resize(5, 6);
    // Same content, just more rows now.
    const r0 = try h.line(std.testing.allocator, 0);
    defer std.testing.allocator.free(r0);
    try std.testing.expectEqualStrings("hello", r0);
    const r1 = try h.line(std.testing.allocator, 1);
    defer std.testing.allocator.free(r1);
    try std.testing.expectEqualStrings("wor", r1);
}

test "reflow: alt screen does NOT reflow" {
    var h = try Harness.init(std.testing.allocator, 5, 4);
    defer h.deinit();
    h.arm();
    h.feed("\x1b[?1049h"); // → alt
    h.feed("hellowor");
    try h.screen.resize(10, 4);
    // Alt screen truncates/pads — content stays at original width
    // (each row is just widened to 10 cols with trailing blanks),
    // soft-wrap is NOT rejoined.
    const r0 = try h.line(std.testing.allocator, 0);
    defer std.testing.allocator.free(r0);
    try std.testing.expectEqualStrings("hello", r0);
    const r1 = try h.line(std.testing.allocator, 1);
    defer std.testing.allocator.free(r1);
    try std.testing.expectEqualStrings("wor", r1);
}
