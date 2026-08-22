//! End-to-end reflow tests via Screen.resize. The reflow.zig
//! module has unit tests for build/trim/rechunk/positionInLogicals;
//! this file exercises the integration: Screen ingests bytes,
//! resize() is called with new cols, the result must preserve
//! soft-wrapped text correctly.

const std = @import("std");
const cell_mod = @import("cell.zig");
const Harness = @import("../parser/test_harness.zig").Harness;
const Screen = @import("screen.zig").Screen;

const wide_left: u8 = cell_mod.FLAG_WIDE_LEFT;
const wide_cont: u8 = cell_mod.FLAG_WIDE_CONT;

fn expectLineWidePairsValid(cells: []const @import("cell.zig").Cell) !void {
    for (cells, 0..) |cell, col| {
        const pair_flags = cell.flags & (wide_left | wide_cont);
        if (pair_flags == wide_left) {
            try std.testing.expect(cell.rune != 0);
            try std.testing.expect(col + 1 < cells.len);
            try std.testing.expectEqual(wide_cont, cells[col + 1].flags & (wide_left | wide_cont));
            try std.testing.expectEqual(@as(u32, 0), cells[col + 1].rune);
        } else if (pair_flags == wide_cont) {
            try std.testing.expect(col > 0);
            try std.testing.expectEqual(wide_left, cells[col - 1].flags & (wide_left | wide_cont));
            try std.testing.expect(cells[col - 1].rune != 0);
        } else {
            try std.testing.expectEqual(@as(u8, 0), pair_flags);
        }
    }
}

fn expectAllWidePairsValid(screen: *Screen) !void {
    for (screen.active) |line| try expectLineWidePairsValid(line.cells);
    var i: u32 = 0;
    while (i < screen.scrollbackCount()) : (i += 1) {
        try expectLineWidePairsValid(screen.scrollbackLine(i).cells);
    }
}

fn expectWidePair(screen: *Screen, row: u16, col: u16, rune: u32) !void {
    const cells = screen.line(row).cells;
    try std.testing.expect(col + 1 < cells.len);
    try std.testing.expectEqual(rune, cells[col].rune);
    try std.testing.expectEqual(wide_left, cells[col].flags & (wide_left | wide_cont));
    try std.testing.expectEqual(@as(u32, 0), cells[col + 1].rune);
    try std.testing.expectEqual(wide_cont, cells[col + 1].flags & (wide_left | wide_cont));
}

fn expectClusterForRune(screen: *Screen, rune: u32, expected: []const u32) !void {
    var found = false;
    for (screen.active, 0..) |line, row| {
        for (line.cells, 0..) |cell, col| {
            if (cell.rune != rune) continue;
            found = true;
            try std.testing.expectEqualSlices(u32, expected, screen.clusterAt(@intCast(row), @intCast(col)));
        }
    }
    try std.testing.expect(found);
}

test "reflow: widening rejoins soft-wrapped logical line" {
    var h = try Harness.init(std.testing.allocator, 5, 4);
    defer h.deinit();
    h.arm();
    // "hellowor" wraps in 5-col screen: row0="hello", row1="wor"
    h.feed("hellowor");
    try h.expectLine(0, "hello");
    try h.expectLine(1, "wor");
    // Widen to 10 cols — should rejoin into a single row.
    try h.screen.resize(10, 4);
    try h.expectLine(0, "hellowor");
}

test "reflow: narrowing splits a long line into multiple rows" {
    var h = try Harness.init(std.testing.allocator, 10, 4);
    defer h.deinit();
    h.arm();
    h.feed("hellowor");
    try h.screen.resize(5, 4);
    try h.expectLine(0, "hello");
    try h.expectLine(1, "wor");
}

test "reflow: trimming preserves a wide pair in the final old columns" {
    var h = try Harness.init(std.testing.allocator, 4, 6);
    defer h.deinit();
    h.arm();
    h.feed("ab\xe7\x95\x8c");

    try expectWidePair(h.screen, 0, 2, 0x754C);
    try h.screen.resize(6, 6);
    try expectWidePair(h.screen, 0, 2, 0x754C);
    try expectAllWidePairsValid(h.screen);

    try h.expectLine(0, "ab\xe7\x95\x8c");
}

test "reflow: a wide glyph moves when only one column remains" {
    var h = try Harness.init(std.testing.allocator, 5, 6);
    defer h.deinit();
    h.arm();
    h.feed("abcd\xe7\x95\x8cx");

    try std.testing.expectEqual(@as(u32, 0), h.screen.line(0).cells[4].rune);
    try expectWidePair(h.screen, 1, 0, 0x754C);
    try std.testing.expect(h.screen.line(1).continues_above);

    try h.screen.resize(6, 6);
    try expectWidePair(h.screen, 0, 4, 0x754C);
    try std.testing.expectEqual(@as(u32, 'x'), h.screen.line(1).cells[0].rune);
    try std.testing.expect(h.screen.line(1).continues_above);

    try h.screen.resize(5, 6);
    try std.testing.expectEqual(@as(u32, 0), h.screen.line(0).cells[4].rune);
    try expectWidePair(h.screen, 1, 0, 0x754C);
    try std.testing.expectEqual(@as(u32, 'x'), h.screen.line(1).cells[2].rune);
    try expectAllWidePairsValid(h.screen);
}

test "reflow: wide pair honors exact and off-by-one boundaries" {
    var h = try Harness.init(std.testing.allocator, 8, 6);
    defer h.deinit();
    h.arm();
    h.feed("ab\xe7\x95\x8cc");

    try h.screen.resize(4, 6);
    try expectWidePair(h.screen, 0, 2, 0x754C);
    try std.testing.expectEqual(@as(u32, 'c'), h.screen.line(1).cells[0].rune);
    try std.testing.expect(h.screen.line(1).continues_above);
    try h.expectCursor(1, 1);

    try h.screen.resize(3, 6);
    try std.testing.expectEqual(@as(u32, 0), h.screen.line(0).cells[2].rune);
    try expectWidePair(h.screen, 1, 0, 0x754C);
    try std.testing.expectEqual(@as(u32, 'c'), h.screen.line(1).cells[2].rune);
    try h.expectCursor(1, 2);

    try h.screen.resize(5, 6);
    try expectWidePair(h.screen, 0, 2, 0x754C);
    try std.testing.expectEqual(@as(u32, 'c'), h.screen.line(0).cells[4].rune);
    try expectAllWidePairsValid(h.screen);
}

test "reflow: CJK emoji and combining clusters survive round trips" {
    const text = "a\xe7\x95\x8c\xcc\x81\xf0\x9f\x99\x82\xef\xb8\x8fb";
    var h = try Harness.init(std.testing.allocator, 8, 10);
    defer h.deinit();
    h.arm();
    h.feed(text);

    const widths = [_]u16{ 4, 6, 3, 5, 8, 4, 7, 3, 8 };
    for (widths) |width| {
        try h.screen.resize(width, 10);
        try expectAllWidePairsValid(h.screen);
        try expectClusterForRune(h.screen, 0x754C, &.{0x0301});
        try expectClusterForRune(h.screen, 0x1F642, &.{0xFE0F});

        const extracted = try h.screen.extractScrollback(std.testing.allocator);
        defer std.testing.allocator.free(extracted);
        try std.testing.expect(std.mem.startsWith(u8, extracted, text));
    }
}

test "reflow: separate logical lines stay separate" {
    var h = try Harness.init(std.testing.allocator, 10, 4);
    defer h.deinit();
    h.arm();
    h.feed("foo\r\nbar\r\nbaz");
    try h.screen.resize(20, 4);
    try h.expectLine(0, "foo");
    try h.expectLine(1, "bar");
    try h.expectLine(2, "baz");
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
    try h.expectCursor(1, 3);
    try h.screen.resize(10, 4);
    // After widening, cursor should be at row 0 col 8 (after the 'r'
    // in "hellowor").
    try h.expectCursor(0, 8);
}

test "reflow: cursor follows its logical position on narrow" {
    var h = try Harness.init(std.testing.allocator, 10, 4);
    defer h.deinit();
    h.arm();
    h.feed("hellowor"); // cursor at row 0 col 8
    try h.screen.resize(5, 4);
    // After narrowing, cursor should be at row 1 col 3.
    try h.expectCursor(1, 3);
}

test "reflow: rows-only resize doesn't reflow content" {
    var h = try Harness.init(std.testing.allocator, 5, 4);
    defer h.deinit();
    h.arm();
    h.feed("hellowor");
    try h.screen.resize(5, 6);
    // Same content, just more rows now.
    try h.expectLine(0, "hello");
    try h.expectLine(1, "wor");
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
    try h.expectLine(0, "hello");
    try h.expectLine(1, "wor");
}

test "reflow: scrollback past 65535 rows keeps cursor and clusters placed" {
    // Regression: reflowMain used to hand `positionInLogicals` a u16 row
    // index. `scrollback` is a u32 config key, so once scrollback + rows
    // exceeds 65535 the index truncated (illegal behaviour under
    // ReleaseFast) and both the cursor and every cluster key were
    // remapped against the wrong logical line.
    const Cell = @import("cell.zig").Cell;
    var h = try Harness.init(std.testing.allocator, 5, 4);
    defer h.deinit();
    h.arm();

    const sb_lines: usize = 65_600;
    h.screen.scrollback_capacity = sb_lines;
    try h.screen.reserveScrollbackPushes(sb_lines);
    var pushed: usize = 0;
    while (pushed < sb_lines) : (pushed += 1) {
        const cells = try std.testing.allocator.alloc(Cell, h.screen.cols);
        @memset(cells, .{});
        switch (h.screen.pushScrollbackTakeOld(cells, h.screen.nextLineId(), false)) {
            .retained => {},
            .caller_owned => |old| std.testing.allocator.free(old),
        }
    }
    try std.testing.expectEqual(@as(u32, sb_lines), h.screen.scrollbackCount());

    // "hellowor" wraps to rows 0-1; the combining acute attaches to 'r'.
    h.feed("hellowor\xcc\x81");
    try h.expectCursor(1, 3);
    try std.testing.expectEqual(@as(usize, 1), h.screen.clusterAt(1, 2).len);

    try h.screen.resize(10, 4);

    // The blanks stay their own logical lines, so the rejoined
    // "hellowor" is the last of sb_lines + 1 rows: active row 3.
    try h.expectCursor(3, 8);
    try std.testing.expectEqual(@as(u32, 'r'), h.screen.cellAt(3, 7).rune);
    try std.testing.expectEqual(@as(usize, 1), h.screen.clusterAt(3, 7).len);
}
