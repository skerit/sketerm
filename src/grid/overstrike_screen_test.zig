//! Overstrike (mintty `CSI 8:7 m` / DECSET 20) through Screen: the flag's
//! lifecycle, what an overstrike print does to the struck cell and the
//! cursor, and how layers ride the ordinary cell operations. The SGR and
//! DECRQSS side lives in `parser/sgr_conformance_test.zig`.

const std = @import("std");
const testing = std.testing;
const overlay = @import("overlay.zig");
const Harness = @import("../parser/test_harness.zig").Harness;
const Cell = @import("cell.zig").Cell;

const on = "\x1b[8:7m";
const off = "\x1b[28m";

fn layersOf(h: *Harness, cell: Cell) overlay.List {
    return h.pool.overlaysOf(cell.style_ref);
}

fn layersAt(h: *Harness, row: u16, col: u16) overlay.List {
    return layersOf(h, h.screen.line(row).cells[col]);
}

fn countAt(h: *Harness, row: u16, col: u16) usize {
    return overlay.count(layersAt(h, row, col));
}

test "DECSET 20 toggles overstrike; public mode 20 stays LNM; DECRQM reports both" {
    var h = try Harness.init(testing.allocator, 8, 2);
    defer h.deinit();
    h.arm();
    h.feed("\x1b[?20h");
    try testing.expect(h.screen.overstrike and !h.screen.line_feed_mode);
    h.feed("\x1b[?20$p\x1b[20$p");
    try testing.expectEqualStrings("\x1b[?20;1$y\x1b[20;2$y", h.wtc.items);
    h.wtc.clearRetainingCapacity();
    h.feed("\x1b[?20l\x1b[20h");
    try testing.expect(!h.screen.overstrike and h.screen.line_feed_mode);
    h.feed("\x1b[?20$p\x1b[20$p");
    try testing.expectEqualStrings("\x1b[?20;2$y\x1b[20;1$y", h.wtc.items);
}

test "an overstrike keeps the base glyph and rendition, adds a layer in the current one, and advances" {
    var h = try Harness.init(testing.allocator, 8, 2);
    defer h.deinit();
    h.feed("\x1b[31mA\x08\x1b[32;1m" ++ on ++ "/" ++ off);
    const cell = h.screen.line(0).cells[0];
    try testing.expectEqual(@as(u32, 'A'), cell.rune);
    const base = h.pool.get(cell.style_ref);
    try testing.expectEqual(@as(u8, 1), base.fg.palette);
    try testing.expect(!base.attrs.bold);
    const layers = layersOf(&h, cell);
    try testing.expectEqual(@as(usize, 1), overlay.count(layers));
    try testing.expectEqual(@as(u21, '/'), layers[0].cp);
    const r = layers[0].rendition();
    try testing.expectEqual(@as(u8, 2), r.fg.palette);
    try testing.expect(r.attrs.bold);
    try h.expectCursor(0, 1);
    // The current style never carries layers.
    try testing.expectEqual(@as(u16, 0), h.pool.get(h.screen.cur_style).overlay);
    // DECSET 20 is the same flag.
    h.feed("B\x08\x1b[?20h_\x1b[?20l");
    try testing.expectEqual(@as(u32, 'B'), h.screen.line(0).cells[1].rune);
    try testing.expectEqual(@as(u21, '_'), layersAt(&h, 0, 1)[0].cp);
}

test "a blank target keeps its blank base and gains the layer" {
    var h = try Harness.init(testing.allocator, 8, 2);
    defer h.deinit();
    h.feed("\x1b[44m\x1b[1;3H" ++ on ++ "x");
    const cell = h.screen.line(0).cells[2];
    try testing.expectEqual(@as(u32, 0), cell.rune);
    try testing.expectEqual(@as(u21, 'x'), layersOf(&h, cell)[0].cp);
    // The cell's own (default) background stays; the layer remembers the
    // blue it was drawn with but nothing paints it.
    try testing.expect(h.pool.get(cell.style_ref).bg == .default);
    try h.expectCursor(0, 3);
}

test "a pending wrap is taken first, except for a zero-width codepoint or with autowrap off" {
    var h = try Harness.init(testing.allocator, 4, 3);
    defer h.deinit();
    h.feed("abcd" ++ on ++ "\u{0301}");
    try testing.expectEqual(@as(u21, 0x301), layersAt(&h, 0, 3)[0].cp);
    try h.expectCursor(0, 3);
    try testing.expect(h.screen.pending_wrap);
    h.feed("X");
    try testing.expectEqual(@as(u21, 'X'), layersAt(&h, 1, 0)[0].cp);
    try testing.expect(h.screen.line(1).continues_above);
    try h.expectCursor(1, 1);

    h.feed(off ++ "\r\nefgh\x1b[?7l" ++ on ++ "Y");
    try testing.expectEqual(@as(u21, 'Y'), layersAt(&h, 2, 3)[0].cp);
    try h.expectCursor(2, 3);
    try testing.expect(!h.screen.pending_wrap);
}

test "a wide right half strikes the base; a wide codepoint advances one column" {
    var h = try Harness.init(testing.allocator, 8, 2);
    defer h.deinit();
    h.feed("\u{4E2D}\x1b[1;2H" ++ on ++ "x");
    try testing.expectEqual(@as(u21, 'x'), layersAt(&h, 0, 0)[0].cp);
    try testing.expectEqual(@as(usize, 0), countAt(&h, 0, 1));
    try h.expectCursor(0, 2);
    h.feed("\u{6587}");
    try testing.expectEqual(@as(u21, 0x6587), layersAt(&h, 0, 2)[0].cp);
    try h.expectCursor(0, 3);
    try h.expectWidePairsWellFormed();
}

test "insert mode does not shift under overstrike" {
    var h = try Harness.init(testing.allocator, 8, 2);
    defer h.deinit();
    h.feed("ab\x1b[4h\x1b[1;1H" ++ on ++ "X");
    try h.expectLine(0, "ab");
    try testing.expectEqual(@as(u21, 'X'), layersAt(&h, 0, 0)[0].cp);
}

test "past the layer bound the oldest layer is dropped" {
    var h = try Harness.init(testing.allocator, 8, 2);
    defer h.deinit();
    h.feed("A" ++ on);
    for ("123456") |c| {
        const seq = [_]u8{ '\x08', c };
        h.feed(&seq);
    }
    const layers = layersAt(&h, 0, 0);
    try testing.expectEqual(@as(usize, overlay.max_layers), overlay.count(layers));
    try testing.expectEqual(@as(u21, '3'), layers[0].cp);
    try testing.expectEqual(@as(u21, '6'), layers[overlay.max_layers - 1].cp);
}

test "an ordinary print or erase drops the layers" {
    var h = try Harness.init(testing.allocator, 8, 2);
    defer h.deinit();
    h.feed("ab\x1b[1;1H" ++ on ++ "//" ++ off);
    try testing.expectEqual(@as(usize, 1), countAt(&h, 0, 0));
    try testing.expectEqual(@as(usize, 1), countAt(&h, 0, 1));
    h.feed("\x1b[1;1HZ");
    try testing.expectEqual(@as(usize, 0), countAt(&h, 0, 0));
    h.feed("\x1b[2K");
    try testing.expectEqual(@as(usize, 0), countAt(&h, 0, 1));
}

test "layers ride ICH, scrolling into scrollback and the alternate screen" {
    var h = try Harness.init(testing.allocator, 6, 2);
    defer h.deinit();
    h.feed("ab" ++ on ++ "\x08\x08//" ++ off ++ "\x1b[1;1H\x1b[@");
    try testing.expectEqual(@as(u32, 'a'), h.screen.line(0).cells[1].rune);
    try testing.expectEqual(@as(usize, 1), countAt(&h, 0, 1));
    try testing.expectEqual(@as(usize, 1), countAt(&h, 0, 2));

    h.feed("\x1b[?1049h\x1b[1;1H" ++ on ++ "q" ++ off ++ "\x1b[?1049l");
    try testing.expectEqual(@as(usize, 1), countAt(&h, 0, 1));
    try testing.expectEqual(@as(usize, 0), countAt(&h, 0, 0));

    h.feed("\x1b[2;1H\r\n\r\n");
    try testing.expectEqual(@as(u32, 2), h.screen.scrollbackCount());
    const sb = h.screen.scrollbackLine(0);
    try testing.expectEqual(@as(usize, 1), overlay.count(layersOf(&h, sb.cells[1])));
}

test "reflow keeps layers, and a blank cell with a layer is content" {
    var h = try Harness.init(testing.allocator, 6, 4);
    defer h.deinit();
    h.feed("ab" ++ on ++ "\x08\x08/" ++ off ++ "\x1b[1;6H" ++ on ++ "!" ++ off);
    try h.screen.resize(3, 4);
    try testing.expectEqual(@as(usize, 1), countAt(&h, 0, 0));
    try testing.expectEqual(@as(u21, '!'), layersAt(&h, 1, 2)[0].cp);
    try h.screen.resize(6, 4);
    try testing.expectEqual(@as(usize, 1), countAt(&h, 0, 0));
    try testing.expectEqual(@as(u21, '!'), layersAt(&h, 0, 5)[0].cp);
}

test "copy and selection return the base text" {
    var h = try Harness.init(testing.allocator, 8, 1);
    defer h.deinit();
    h.feed("A" ++ on ++ "\x08/" ++ off ++ "B");
    h.select(0, 0, 0, 7);
    try h.expectSelection("AB");
}

test "DECSC/DECRC and 1048 save and restore the flag; DECSTR and RIS clear it" {
    var h = try Harness.init(testing.allocator, 6, 2);
    defer h.deinit();
    h.feed("\x1b8");
    try testing.expect(!h.screen.overstrike);
    h.feed(on ++ "\x1b7" ++ off);
    try testing.expect(!h.screen.overstrike);
    h.feed("\x1b8");
    try testing.expect(h.screen.overstrike);
    h.feed("\x1b[?1048h" ++ off ++ "\x1b[?1048l");
    try testing.expect(h.screen.overstrike);
    h.feed("\x1b[!p");
    try testing.expect(!h.screen.overstrike);
    h.feed("\x1b8");
    try testing.expect(h.screen.overstrike);
    h.feed("\x1bc\x1b8");
    try testing.expect(!h.screen.overstrike);
}

test "style GC collects layer lists nothing uses and keeps live ones in place" {
    var h = try Harness.init(testing.allocator, 4, 1);
    defer h.deinit();
    h.feed("ab" ++ on ++ "\x08\x0812" ++ off);
    try testing.expectEqual(@as(usize, 2), h.pool.overlay_table.slots.items.len);
    const live_id = h.pool.get(h.screen.line(0).cells[1].style_ref).overlay;
    h.feed("\x1b[1;1Hx");
    h.screen.compactStylePool();
    try testing.expectEqual(@as(usize, 1), h.pool.overlay_table.free.items.len);
    try testing.expectEqual(live_id, h.pool.get(h.screen.line(0).cells[1].style_ref).overlay);
    try testing.expectEqual(@as(u21, '2'), layersAt(&h, 0, 1)[0].cp);
    h.feed("\x1b[2K");
    h.screen.compactStylePool();
    try testing.expect(!h.pool.hasOverlays());
}

test "a pool full of dead styles is reclaimed for an overstrike" {
    var h = try Harness.init(testing.allocator, 4, 1);
    defer h.deinit();
    h.feed("a");
    var n: u32 = 0;
    while (h.pool.intern(.{ .fg = .{ .rgb = .{ .r = @truncate(n), .g = @truncate(n >> 8), .b = 1 } } })) |_| : (n += 1) {} else |_| {}
    h.feed("\x08" ++ on ++ "/");
    try testing.expectEqual(@as(u21, '/'), layersAt(&h, 0, 0)[0].cp);
    try testing.expectEqual(@as(u32, 'a'), h.screen.line(0).cells[0].rune);
    try testing.expect(h.pool.entries.items.len < 0xFFFF);
}
