//! Cell-border protocol through Screen: the pen lifecycle table, the
//! rectangle commands, reflow and scrollback, and style GC. The payload
//! parser has its own tests in borders.zig.

const std = @import("std");
const testing = std.testing;
const borders = @import("borders.zig");
const Harness = @import("../parser/test_harness.zig").Harness;
const Pool = @import("style_pool.zig").Pool;
const Cell = @import("cell.zig").Cell;

const Segment = borders.Segment;
const group = borders.group;

/// Pen with every segment, inside, below text, palette 2.
const pen_all = "\x1bP1+bcell-border;pen;4095;16;p2;0;0\x1b\\";
const pen_clear = "\x1bP1+bcell-border;pen-clear;4095\x1b\\";

fn maskOf(h: *Harness, cell: Cell) borders.Mask {
    return borders.presentMask(h.pool.bordersOf(cell.style_ref));
}

fn maskAt(h: *Harness, row: u16, col: u16) borders.Mask {
    return maskOf(h, h.screen.line(row).cells[col]);
}

fn strokeAt(h: *Harness, row: u16, col: u16, seg: Segment) borders.Stroke {
    return h.pool.bordersOf(h.screen.line(row).cells[col].style_ref)[@intFromEnum(seg)];
}

fn penMask(h: *Harness) borders.Mask {
    return borders.presentMask(h.pool.bordersOf(h.screen.cur_style));
}

test "printing stamps the pen; SGR 0 clears it, other SGR keeps it" {
    var h = try Harness.init(testing.allocator, 10, 3);
    defer h.deinit();
    h.feed(pen_all ++ "a\x1b[1mb\x1b[0mc");
    try testing.expectEqual(group.all, maskAt(&h, 0, 0));
    try testing.expectEqual(group.all, maskAt(&h, 0, 1));
    try testing.expect(h.pool.get(h.screen.line(0).cells[1].style_ref).attrs.bold);
    try testing.expectEqual(@as(borders.Mask, 0), maskAt(&h, 0, 2));
    try testing.expectEqual(@as(borders.Mask, 0), penMask(&h));

    const stroke = strokeAt(&h, 0, 0, .top_left);
    try testing.expectEqual(@as(u7, 16), stroke.width);
    try testing.expectEqual(borders.Color{ .kind = .palette, .value = 2 }, stroke.color);

    // pen-clear removes only its segments; a malformed command is a no-op.
    h.feed(pen_all ++ "\x1bP1+bcell-border;pen-clear;192\x1b\\\x1bP1+bcell-border;pen;1;0;fg;0;0\x1b\\d");
    try testing.expectEqual(group.all & ~group.left, maskAt(&h, 0, 3));
    // Wrong parameter, intermediate or final: not this protocol at all.
    h.feed(pen_clear ++ "\x1bP2+bcell-border;pen;1;1;fg;0;0\x1b\\\x1bP1$bcell-border;pen;1;1;fg;0;0\x1b\\\x1bP1+ccell-border;pen;1;1;fg;0;0\x1b\\e");
    try testing.expectEqual(@as(borders.Mask, 0), maskAt(&h, 0, 4));
}

test "erases take the pen; an empty pen erases borders" {
    var h = try Harness.init(testing.allocator, 8, 3);
    defer h.deinit();
    h.feed(pen_all ++ "abcdefgh" ++ pen_clear);
    // ECH and EL with an empty pen strip borders.
    h.feed("\x1b[1;2H\x1b[2X\x1b[1;7H\x1b[K");
    try testing.expectEqual(group.all, maskAt(&h, 0, 0));
    try testing.expectEqual(@as(borders.Mask, 0), maskAt(&h, 0, 1));
    try testing.expectEqual(@as(borders.Mask, 0), maskAt(&h, 0, 2));
    try testing.expectEqual(group.all, maskAt(&h, 0, 3));
    try testing.expectEqual(@as(borders.Mask, 0), maskAt(&h, 0, 7));
    // ED 0 with a pen stamps it on every erased cell.
    h.feed("\x1bP1+bcell-border;pen;48;8;fg;1;1\x1b\\\x1b[2;3H\x1b[J");
    try testing.expectEqual(@as(borders.Mask, 0), maskAt(&h, 1, 1));
    try testing.expectEqual(group.bottom, maskAt(&h, 1, 2));
    try testing.expectEqual(group.bottom, maskAt(&h, 2, 0));
    try testing.expectEqual(borders.Placement.centred, strokeAt(&h, 2, 0, .bottom_left).placement);
    try testing.expectEqual(borders.Layer.above_text, strokeAt(&h, 2, 0, .bottom_left).layer);
}

test "ICH and DCH keep shifted borders; new blanks take the pen with default rendition" {
    var h = try Harness.init(testing.allocator, 6, 2);
    defer h.deinit();
    h.feed("\x1b[44m" ++ pen_all ++ "abc" ++ pen_clear ++ "\x1bP1+bcell-border;pen;3;8;fg;0;0\x1b\\");
    h.feed("\x1b[1;1H\x1b[2@");
    try testing.expectEqual(group.top, maskAt(&h, 0, 0));
    try testing.expectEqual(group.top, maskAt(&h, 0, 1));
    try testing.expectEqual(@as(u32, 'a'), h.screen.line(0).cells[2].rune);
    try testing.expectEqual(group.all, maskAt(&h, 0, 2));
    // The ICH fill is not BCE: the new blanks keep the default bg.
    try testing.expect(h.pool.get(h.screen.line(0).cells[0].style_ref).bg == .default);
    h.feed("\x1b[1;1H\x1b[3P");
    try testing.expectEqual(@as(u32, 'b'), h.screen.line(0).cells[0].rune);
    try testing.expectEqual(group.all, maskAt(&h, 0, 0));
    try testing.expectEqual(group.top, maskAt(&h, 0, 5));
}

test "IL, DL, SU, SD and LF at the bottom margin: moved lines keep borders, new lines take the pen" {
    var h = try Harness.init(testing.allocator, 4, 3);
    defer h.deinit();
    h.feed(pen_all ++ "a\r\n" ++ pen_clear ++ "b\r\nc");
    h.feed("\x1bP1+bcell-border;pen;12;8;fg;0;0\x1b\\");
    h.feed("\x1b[1;1H\x1b[L");
    try testing.expectEqual(group.right, maskAt(&h, 0, 0));
    try testing.expectEqual(group.right, maskAt(&h, 0, 3));
    try testing.expectEqual(group.all, maskAt(&h, 1, 0));
    h.feed("\x1b[M");
    try testing.expectEqual(group.all, maskAt(&h, 0, 0));
    try testing.expectEqual(group.right, maskAt(&h, 2, 0));
    h.feed("\x1b[S");
    try testing.expectEqual(@as(u32, 'b'), h.screen.line(0).cells[0].rune);
    try testing.expectEqual(group.right, maskAt(&h, 2, 1));
    h.feed("\x1b[T");
    try testing.expectEqual(group.right, maskAt(&h, 0, 2));
    try testing.expectEqual(@as(u32, 'b'), h.screen.line(1).cells[0].rune);
    // LF at the bottom pushes row 0 to scrollback and opens a pen row.
    const before = h.screen.scrollbackCount();
    h.feed(pen_all ++ "\x1b[1;1Hz" ++ pen_clear ++ "\x1bP1+bcell-border;pen;48;8;fg;0;0\x1b\\\x1b[3;1H\n");
    try testing.expectEqual(before + 1, h.screen.scrollbackCount());
    try testing.expectEqual(group.all, maskOf(&h, h.screen.scrollbackLine(before).cells[0]));
    try testing.expectEqual(group.bottom, maskAt(&h, 2, 3));
}

test "wide characters omit their inner edges; overwriting one half blanks the other with the pen" {
    var h = try Harness.init(testing.allocator, 6, 2);
    defer h.deinit();
    h.feed(pen_all ++ "\u{4E2D}");
    try testing.expectEqual(group.all & ~group.right, maskAt(&h, 0, 0));
    try testing.expectEqual(group.all & ~group.left, maskAt(&h, 0, 1));
    h.feed(pen_clear ++ "\x1bP1+bcell-border;pen;3;8;fg;0;0\x1b\\\x1b[1;2Hx");
    try testing.expectEqual(@as(u32, 0), h.screen.line(0).cells[0].rune);
    try testing.expectEqual(group.top, maskAt(&h, 0, 0));
    try testing.expectEqual(group.top, maskAt(&h, 0, 1));
}

test "rectangles clip to the screen, ignore margins, leave the pen and cursor alone" {
    var h = try Harness.init(testing.allocator, 6, 4);
    defer h.deinit();
    h.feed("\x1bP1+bcell-border;pen;3;8;fg;0;0\x1b\\");
    h.feed("\x1b[2;3r\x1b[2;5H\x1bP1+bcell-border;set;12;8;00ff00;1;1;99;99\x1b\\");
    try testing.expectEqual(@as(u16, 1), h.screen.row);
    try testing.expectEqual(@as(u16, 4), h.screen.col);
    try testing.expectEqual(group.top, penMask(&h));
    try testing.expectEqual(@as(borders.Mask, 0), maskAt(&h, 0, 4));
    try testing.expectEqual(@as(borders.Mask, 0), maskAt(&h, 1, 3));
    for (1..4) |r| for (4..6) |c| {
        try testing.expectEqual(group.right, maskAt(&h, @intCast(r), @intCast(c)));
    };
    try testing.expectEqual(borders.Color{ .kind = .rgb, .value = 0x00ff00 }, strokeAt(&h, 3, 5, .right_top).color);
    // `set` merges into what is there; `clear` drops only its segments.
    h.feed("\x1bP1+bcell-border;set;3;8;fg;0;0;1;1\x1b\\");
    try testing.expectEqual(group.right | group.top, maskAt(&h, 1, 4));
    h.feed("\x1bP1+bcell-border;clear;4;2;2\x1b\\");
    try testing.expectEqual(group.top | Segment.right_bottom.mask(), maskAt(&h, 1, 4));
    try testing.expectEqual(Segment.right_bottom.mask(), maskAt(&h, 2, 5));
    try testing.expectEqual(group.right, maskAt(&h, 3, 5));
    try testing.expectEqual(group.top, penMask(&h));
}

test "DECSC/DECRC, 1048 and 1049 save and restore the pen; DECRC with nothing saved clears it" {
    var h = try Harness.init(testing.allocator, 6, 3);
    defer h.deinit();
    h.feed("\x1b8");
    try testing.expectEqual(@as(borders.Mask, 0), penMask(&h));
    h.feed(pen_all ++ "\x1b7" ++ pen_clear);
    try testing.expectEqual(@as(borders.Mask, 0), penMask(&h));
    h.feed("\x1b8");
    try testing.expectEqual(group.all, penMask(&h));
    h.feed("\x1b[?1048h" ++ pen_clear ++ "\x1b[?1048l");
    try testing.expectEqual(group.all, penMask(&h));
    h.feed("\x1b[?1049h" ++ pen_clear ++ "x");
    try testing.expectEqual(@as(borders.Mask, 0), maskAt(&h, 0, 0));
    h.feed("\x1b[?1049l");
    try testing.expectEqual(group.all, penMask(&h));
}

test "DECSTR clears only the pen; RIS clears every border, scrollback included" {
    var h = try Harness.init(testing.allocator, 4, 2);
    defer h.deinit();
    h.feed(pen_all ++ "ab\r\ncd\r\nef\x1b7");
    try testing.expect(h.screen.scrollbackCount() > 0);
    h.feed("\x1b[!p");
    try testing.expectEqual(@as(borders.Mask, 0), penMask(&h));
    try testing.expectEqual(group.all, maskAt(&h, 1, 0));
    h.feed("\x1bc");
    try testing.expectEqual(@as(borders.Mask, 0), penMask(&h));
    try testing.expect(!h.pool.hasBorders());
    for (0..h.screen.scrollbackCount()) |i| {
        for (h.screen.scrollbackLine(@intCast(i)).cells) |cell| {
            try testing.expectEqual(@as(borders.Mask, 0), maskOf(&h, cell));
        }
    }
    // The pen parked by DECSC before RIS does not come back.
    h.feed("\x1b8");
    try testing.expectEqual(@as(borders.Mask, 0), penMask(&h));
}

test "DECCOLM clears borders even with a pen set" {
    var h = try Harness.init(testing.allocator, 80, 2);
    defer h.deinit();
    h.feed("\x1b[?40h" ++ pen_all ++ "ab\x1b[?3h");
    try testing.expectEqual(@as(u16, 132), h.screen.cols);
    try testing.expectEqual(@as(borders.Mask, 0), maskAt(&h, 0, 0));
    try testing.expectEqual(@as(borders.Mask, 0), maskAt(&h, 1, 100));
}

test "DECALN cells take the pen" {
    var h = try Harness.init(testing.allocator, 3, 2);
    defer h.deinit();
    h.feed("\x1b[41m" ++ "\x1bP1+bcell-border;pen;3;8;fg;0;0\x1b\\\x1b#8");
    try testing.expectEqual(@as(u32, 'E'), h.screen.line(1).cells[2].rune);
    try testing.expectEqual(group.top, maskAt(&h, 1, 2));
    try testing.expect(h.pool.get(h.screen.line(1).cells[2].style_ref).bg == .default);
}

test "reflow keeps bordered trailing blanks as content" {
    var h = try Harness.init(testing.allocator, 8, 3);
    defer h.deinit();
    h.feed("ab\x1b[1;5H\x1bP1+bcell-border;set;12;8;fg;0;0;1;2\x1b\\");
    try h.screen.resize(4, 3);
    // "ab" + two blanks + the two bordered blanks wrap onto row 1.
    try testing.expect(h.screen.active[1].continues_above or h.screen.scrollbackCount() > 0);
    var found: usize = 0;
    for (h.screen.active) |ln| {
        for (ln.cells) |cell| {
            if (maskOf(&h, cell) == group.right) found += 1;
        }
    }
    try testing.expectEqual(@as(usize, 2), found);
    try h.screen.resize(8, 3);
    try testing.expectEqual(group.right, maskAt(&h, 0, 4));
    try testing.expectEqual(group.right, maskAt(&h, 0, 5));
}

test "borders are never copied as text" {
    var h = try Harness.init(testing.allocator, 8, 1);
    defer h.deinit();
    h.feed("a\x1bP1+bcell-border;set;4095;8;fg;0;0;1;5\x1b\\" ++ pen_all ++ "\x1b[1;3Hb");
    h.select(0, 0, 0, 7);
    try h.expectSelection("a b");
}

test "the capability query is answered by an unmuted screen only" {
    var h = try Harness.init(testing.allocator, 4, 1);
    defer h.deinit();
    h.arm();
    h.feed("\x1bP1+bcell-border;q\x1b\\\x1b[c");
    try testing.expect(std.mem.startsWith(u8, h.wtc.items, borders.query_reply));
    h.wtc.clearRetainingCapacity();
    h.screen.mute_responses = true;
    h.feed("\x1bP1+bcell-border;q\x1b\\");
    try testing.expectEqual(@as(usize, 0), h.wtc.items.len);
}

test "style GC collects border sets nothing uses, and keeps the live ones" {
    var h = try Harness.init(testing.allocator, 4, 1);
    defer h.deinit();
    h.feed("\x1bP1+bcell-border;pen;1;8;ff0000;0;0\x1b\\a\x1bP1+bcell-border;pen;1;8;00ff00;0;0\x1b\\b");
    try testing.expectEqual(@as(usize, 2), h.pool.border_table.slots.items.len);
    // Overwrite the red cell with no pen; the green one stays live.
    h.feed(pen_clear ++ "\x1b[1;1Hx");
    h.screen.compactStylePool();
    try testing.expectEqual(@as(usize, 1), h.pool.border_table.free.items.len);
    try testing.expectEqual(@as(u24, 0x00ff00), strokeAt(&h, 0, 1, .top_left).color.value);
    // The freed slot is reused, and the live set kept its ID.
    const live_id = h.pool.get(h.screen.line(0).cells[1].style_ref).border;
    h.feed("\x1bP1+bcell-border;pen;1;8;0000ff;0;0\x1b\\\x1b[1;4Hc");
    try testing.expectEqual(@as(usize, 2), h.pool.border_table.slots.items.len);
    try testing.expectEqual(live_id, h.pool.get(h.screen.line(0).cells[1].style_ref).border);
    h.feed(pen_clear ++ "\x1b[1;1H\x1b[2K");
    h.screen.compactStylePool();
    try testing.expect(!h.pool.hasBorders());
}

test "a pool full of dead styles is reclaimed for a pen" {
    var h = try Harness.init(testing.allocator, 4, 1);
    defer h.deinit();
    var n: u32 = 0;
    while (h.pool.intern(.{ .fg = .{ .rgb = .{ .r = @truncate(n), .g = @truncate(n >> 8), .b = 1 } } })) |_| : (n += 1) {} else |_| {}
    h.feed(pen_all ++ "a");
    try testing.expectEqual(group.all, penMask(&h));
    try testing.expectEqual(group.all, maskAt(&h, 0, 0));
    try testing.expect(h.pool.entries.items.len < 0xFFFF);
}

test "a pool full of live styles backs off instead of rescanning per cell" {
    var h = try Harness.init(testing.allocator, 256, 256);
    defer h.deinit();
    // Every possible style index referenced by a cell.
    var n: u32 = 1;
    for (h.screen.active) |ln| for (ln.cells) |*cell| {
        const idx = h.pool.intern(.{ .fg = .{ .rgb = .{ .r = @truncate(n), .g = @truncate(n >> 8), .b = 7 } } }) catch break;
        cell.style_ref = idx;
        n += 1;
    };
    try testing.expectEqual(@as(usize, 0xFFFF), h.pool.entries.items.len);
    h.feed(pen_all);
    try testing.expectEqual(@as(borders.Mask, 0), penMask(&h));
    try testing.expectEqual(Pool.reclaim_backoff, h.pool.reclaim_cooldown);
    h.feed("\x1bP1+bcell-border;set;1;8;fg;0;0;3;3\x1b\\");
    try testing.expectEqual(Pool.reclaim_backoff - 1, h.pool.reclaim_cooldown);
}
