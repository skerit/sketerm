//! Tests ported from kitty/kitty_tests/screen.py — the most
//! comprehensive Screen-behavior battery in their suite. Skips
//! tests that depend on Kitty-specific machinery (PagerHist,
//! semantic_type, render-layer features) and tests that exercise
//! features we explicitly don't implement (DECDHL/DECDWL,
//! VT52, DECCOLM).

const std = @import("std");
const Harness = @import("test_harness.zig").Harness;

// ── test_char_manipulation ────────────────────────────────────────

test "screen.py: insert_characters shifts right + pads with blanks" {
    var h = try Harness.init(std.testing.allocator, 5, 1);
    defer h.deinit();
    h.arm();
    h.feed("abcde\x1b[H"); // cursor home
    h.feed("\x1b[C"); // CUF 1 → col 1
    h.feed("\x1b[2@"); // ICH 2
    const r = try h.line(std.testing.allocator, 0);
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("a  bc", r);
}

test "screen.py: insert_characters with huge n empties row" {
    var h = try Harness.init(std.testing.allocator, 5, 1);
    defer h.deinit();
    h.arm();
    h.feed("abcde\x1b[H");
    h.feed("\x1b[20@");
    const r = try h.line(std.testing.allocator, 0);
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("", r);
}

test "screen.py: delete_characters shifts remainder left" {
    var h = try Harness.init(std.testing.allocator, 5, 1);
    defer h.deinit();
    h.arm();
    h.feed("abcde\x1b[H");
    h.feed("\x1b[C"); // col 1
    h.feed("\x1b[2P");
    const r = try h.line(std.testing.allocator, 0);
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("ade", r);
}

test "screen.py: erase_characters fills with blanks (preserves trailing)" {
    var h = try Harness.init(std.testing.allocator, 5, 1);
    defer h.deinit();
    h.arm();
    h.feed("abcde\x1b[H");
    h.feed("\x1b[C"); // col 1
    h.feed("\x1b[2X");
    const r = try h.line(std.testing.allocator, 0);
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("a  de", r);
}

test "screen.py: erase_in_line modes 0/1/2" {
    // Mode 0 (default): cursor → end.
    {
        var h = try Harness.init(std.testing.allocator, 5, 1);
        defer h.deinit();
        h.arm();
        h.feed("abcde\x1b[H\x1b[C\x1b[K");
        const r = try h.line(std.testing.allocator, 0);
        defer std.testing.allocator.free(r);
        try std.testing.expectEqualStrings("a", r);
    }
    // Mode 1: start → cursor (inclusive).
    {
        var h = try Harness.init(std.testing.allocator, 5, 1);
        defer h.deinit();
        h.arm();
        h.feed("abcde\x1b[H\x1b[C\x1b[C\x1b[1K");
        const r = try h.line(std.testing.allocator, 0);
        defer std.testing.allocator.free(r);
        try std.testing.expectEqualStrings("   de", r);
    }
    // Mode 2: whole line.
    {
        var h = try Harness.init(std.testing.allocator, 5, 1);
        defer h.deinit();
        h.arm();
        h.feed("abcde\x1b[2K");
        const r = try h.line(std.testing.allocator, 0);
        defer std.testing.allocator.free(r);
        try std.testing.expectEqualStrings("", r);
    }
}

// ── test_erase_in_screen ──────────────────────────────────────────

test "screen.py: ED 0 erases cursor → end-of-screen" {
    var h = try Harness.init(std.testing.allocator, 5, 5);
    defer h.deinit();
    h.arm();
    var i: u8 = 0;
    while (i < 5) : (i += 1) {
        h.feed("12345");
        if (i < 4) h.feed("\r\n");
    }
    h.feed("\x1b[2;3H"); // row 1 col 2
    h.feed("\x1b[J"); // ED 0
    const r0 = try h.line(std.testing.allocator, 0);
    defer std.testing.allocator.free(r0);
    try std.testing.expectEqualStrings("12345", r0);
    const r1 = try h.line(std.testing.allocator, 1);
    defer std.testing.allocator.free(r1);
    try std.testing.expectEqualStrings("12", r1);
    const r2 = try h.line(std.testing.allocator, 2);
    defer std.testing.allocator.free(r2);
    try std.testing.expectEqualStrings("", r2);
}

test "screen.py: ED 1 erases start → cursor" {
    var h = try Harness.init(std.testing.allocator, 5, 5);
    defer h.deinit();
    h.arm();
    var i: u8 = 0;
    while (i < 5) : (i += 1) {
        h.feed("12345");
        if (i < 4) h.feed("\r\n");
    }
    h.feed("\x1b[2;3H");
    h.feed("\x1b[1J");
    const r0 = try h.line(std.testing.allocator, 0);
    defer std.testing.allocator.free(r0);
    try std.testing.expectEqualStrings("", r0);
    const r1 = try h.line(std.testing.allocator, 1);
    defer std.testing.allocator.free(r1);
    try std.testing.expectEqualStrings("   45", r1);
    const r2 = try h.line(std.testing.allocator, 2);
    defer std.testing.allocator.free(r2);
    try std.testing.expectEqualStrings("12345", r2);
}

test "screen.py: ED 2 erases entire screen" {
    var h = try Harness.init(std.testing.allocator, 5, 3);
    defer h.deinit();
    h.arm();
    h.feed("12345\r\n12345\r\n123");
    h.feed("\x1b[2J");
    var r: u16 = 0;
    while (r < 3) : (r += 1) {
        const s = try h.line(std.testing.allocator, r);
        defer std.testing.allocator.free(s);
        try std.testing.expectEqualStrings("", s);
    }
}

// ── test_cursor_movement ──────────────────────────────────────────

test "screen.py: cursor_up clamps + cursor_forward + CHA" {
    var h = try Harness.init(std.testing.allocator, 5, 5);
    defer h.deinit();
    h.arm();
    var i: u8 = 0;
    while (i < 5) : (i += 1) {
        h.feed("12345");
        if (i < 4) h.feed("\r\n");
    }
    h.feed("\x1b[2A"); // CUU 2 from (4,4) → row 2
    try std.testing.expectEqual(@as(u16, 2), h.screen.row);
    try std.testing.expectEqual(@as(u16, 4), h.screen.col);
    h.feed("\x1b[F"); // CPL 1 → row 1 col 0
    try std.testing.expectEqual(@as(u16, 1), h.screen.row);
    try std.testing.expectEqual(@as(u16, 0), h.screen.col);
    h.feed("\x1b[3C"); // CUF 3
    try std.testing.expectEqual(@as(u16, 3), h.screen.col);
    h.feed("\x1b[3G"); // CHA col 3 → 1-indexed → col 2
    try std.testing.expectEqual(@as(u16, 2), h.screen.col);
    try std.testing.expectEqual(@as(u16, 1), h.screen.row);
    h.feed("\x1b[B"); // CUD 1
    try std.testing.expectEqual(@as(u16, 2), h.screen.row);
    h.feed("\x1b[5E"); // CNL 5 (wraps to last row)
    try std.testing.expectEqual(@as(u16, 4), h.screen.row);
    try std.testing.expectEqual(@as(u16, 0), h.screen.col);
}

test "screen.py: ESC D (IND) line feed; ESC M (RI) reverse" {
    var h = try Harness.init(std.testing.allocator, 5, 5);
    defer h.deinit();
    h.arm();
    var i: u8 = 0;
    while (i < 5) : (i += 1) {
        h.feed("12345");
        if (i < 4) h.feed("\r\n");
    }
    // After draws, cursor at (4, 5). IND scrolls.
    h.feed("\x1bD");
    const r4 = try h.line(std.testing.allocator, 4);
    defer std.testing.allocator.free(r4);
    try std.testing.expectEqualStrings("", r4);
    // RI from row 0 also scrolls down (clears row 0).
    h.feed("12345\x1b[H\x1bM");
    const r0 = try h.line(std.testing.allocator, 0);
    defer std.testing.allocator.free(r0);
    try std.testing.expectEqualStrings("", r0);
}

// ── test_backspace ────────────────────────────────────────────────

test "screen.py: backspace at col 0 doesn't move past margin" {
    var h = try Harness.init(std.testing.allocator, 5, 2);
    defer h.deinit();
    h.arm();
    h.feed("abcde"); // cursor wraps logically at right edge
    h.feed("f"); // forces wrap → row 1, col 1
    try std.testing.expectEqual(@as(u16, 1), h.screen.row);
    try std.testing.expectEqual(@as(u16, 1), h.screen.col);
    h.feed("\x1b[100D"); // CUB huge → clamp to col 0
    try std.testing.expectEqual(@as(u16, 0), h.screen.col);
    try std.testing.expectEqual(@as(u16, 1), h.screen.row);
}

// ── test_tab_stops ────────────────────────────────────────────────

test "screen.py: HT advances to next 8-col stop" {
    var h = try Harness.init(std.testing.allocator, 30, 1);
    defer h.deinit();
    h.arm();
    h.feed("\t"); // → col 8
    try std.testing.expectEqual(@as(u16, 8), h.screen.col);
    h.feed("\t"); // → col 16
    try std.testing.expectEqual(@as(u16, 16), h.screen.col);
    h.feed("\t"); // → col 24
    try std.testing.expectEqual(@as(u16, 24), h.screen.col);
    h.feed("\t"); // → cols-1 = 29 (last col)
    try std.testing.expectEqual(@as(u16, 29), h.screen.col);
}

test "screen.py: HTS sets stop, CSI g clears" {
    var h = try Harness.init(std.testing.allocator, 30, 1);
    defer h.deinit();
    h.arm();
    h.feed("\x1b[3g"); // clear all
    h.feed("\x1b[6G"); // CHA 6 → col 5
    h.feed("\x1bH"); // HTS at col 5
    h.feed("\r");
    h.feed("\t"); // → col 5
    try std.testing.expectEqual(@as(u16, 5), h.screen.col);
}

// ── test_sgr ──────────────────────────────────────────────────────

test "screen.py: SGR bold + blink + 256-color palette" {
    var h = try Harness.init(std.testing.allocator, 5, 1);
    defer h.deinit();
    h.arm();
    h.feed("\x1b[0;1;5;37;42mA");
    const c = h.screen.cellAt(0, 0);
    const style = h.screen.pool.get(c.style_ref);
    try std.testing.expect(style.attrs.bold);
    try std.testing.expect(style.attrs.blink);
    try std.testing.expect(style.fg == .palette);
    try std.testing.expectEqual(@as(u8, 7), style.fg.palette);
    try std.testing.expect(style.bg == .palette);
    try std.testing.expectEqual(@as(u8, 2), style.bg.palette);
}

test "screen.py: SGR 0 resets" {
    var h = try Harness.init(std.testing.allocator, 5, 1);
    defer h.deinit();
    h.arm();
    h.feed("\x1b[1;31mA\x1b[0mB");
    const a = h.screen.cellAt(0, 0);
    const sa = h.screen.pool.get(a.style_ref);
    try std.testing.expect(sa.attrs.bold);
    const b = h.screen.cellAt(0, 1);
    const sb = h.screen.pool.get(b.style_ref);
    try std.testing.expect(!sb.attrs.bold);
    try std.testing.expect(sb.fg == .default);
}

test "screen.py: SGR empty == SGR 0" {
    var h = try Harness.init(std.testing.allocator, 5, 1);
    defer h.deinit();
    h.arm();
    h.feed("\x1b[1mA\x1b[mB");
    const b = h.screen.cellAt(0, 1);
    const sb = h.screen.pool.get(b.style_ref);
    try std.testing.expect(!sb.attrs.bold);
}

// ── test_cursor_hidden (mode 25 with alt screen) ──────────────────

test "screen.py: cursor_visible state survives alt screen toggle" {
    var h = try Harness.init(std.testing.allocator, 10, 5);
    defer h.deinit();
    h.arm();
    h.feed("\x1b[?1049h"); // → alt
    h.feed("\x1b[?25l"); // hide
    try std.testing.expect(!h.screen.cursor_visible);
    h.feed("\x1b[?1049l"); // → main
    // Kitty's behavior: cursor_visible state persists. Our 1049
    // does cursor save/restore but cursor_visible isn't part of
    // the saved set — it stays as last-set.
    try std.testing.expect(!h.screen.cursor_visible);
}

// ── test_dirty_lines (subset — we have row-level dirty bit) ───────

test "screen.py: drawing marks affected lines dirty" {
    var h = try Harness.init(std.testing.allocator, 5, 5);
    defer h.deinit();
    h.arm();
    // Reset all dirty bits to start clean.
    var r: u16 = 0;
    while (r < 5) : (r += 1) h.screen.line(r).dirty = false;
    h.feed("aaaaaaaaa"); // wraps row 0 → 1
    try std.testing.expect(h.screen.line(0).dirty);
    try std.testing.expect(h.screen.line(1).dirty);
    try std.testing.expect(!h.screen.line(2).dirty);
}

// ── test_da1 ──────────────────────────────────────────────────────

test "screen.py: DA1 reply mentions VT220 + ANSI color (we add sixel)" {
    var h = try Harness.init(std.testing.allocator, 5, 1);
    defer h.deinit();
    h.arm();
    h.feed("\x1b[c");
    // We advertise VT220 (62), sixel (4), ANSI color (22).
    try std.testing.expectEqualStrings("\x1b[?62;4;22c", h.wtc.items);
}

// ── test_resize (truncate-pad behavior; we don't reflow yet) ──────

test "screen.py: resize preserves content (truncate/pad mode)" {
    var h = try Harness.init(std.testing.allocator, 5, 3);
    defer h.deinit();
    h.arm();
    h.feed("abcde\r\n12345");
    try h.screen.resize(7, 3);
    const r0 = try h.line(std.testing.allocator, 0);
    defer std.testing.allocator.free(r0);
    try std.testing.expectEqualStrings("abcde", r0);
    const r1 = try h.line(std.testing.allocator, 1);
    defer std.testing.allocator.free(r1);
    try std.testing.expectEqualStrings("12345", r1);
}

test "screen.py: resize clamps cursor inside new bounds" {
    var h = try Harness.init(std.testing.allocator, 10, 10);
    defer h.deinit();
    h.arm();
    h.feed("\x1b[8;8H"); // cursor at (7,7)
    try h.screen.resize(5, 5);
    try std.testing.expect(h.screen.row < 5);
    try std.testing.expect(h.screen.col < 5);
}

// ── test_hyperlinks (OSC 8) ───────────────────────────────────────

test "screen.py: OSC 8 stamps link_id on cells" {
    var h = try Harness.init(std.testing.allocator, 10, 1);
    defer h.deinit();
    h.arm();
    h.feed("\x1b]8;;https://example.com\x1b\\link\x1b]8;;\x1b\\");
    var col: u16 = 0;
    while (col < 4) : (col += 1) {
        const cell = h.screen.cellAt(0, col);
        try std.testing.expect(cell.flags & 0b0000_0100 != 0); // has link
        try std.testing.expect(cell.reserved != 0);
    }
    // After end-link, no link on subsequent cells.
    h.feed("X");
    const c = h.screen.cellAt(0, 4);
    try std.testing.expect(c.flags & 0b0000_0100 == 0);
}

// ── test_charsets (DEC special graphics) ──────────────────────────

test "parser.py: ESC ( 0 + 0x0e (SO) translates ASCII to box-drawing" {
    var h = try Harness.init(std.testing.allocator, 5, 1);
    defer h.deinit();
    h.arm();
    h.feed("\x1b)0\x0e/_"); // designate G1 = dec_graphics, then SO
    // '/' (0x2F) is below 0x5F → unchanged, '_' (0x5F) → space.
    const c0 = h.screen.cellAt(0, 0);
    try std.testing.expectEqual(@as(u32, '/'), c0.rune);
    const c1 = h.screen.cellAt(0, 1);
    // '_' maps to space (rune 0x20).
    try std.testing.expectEqual(@as(u32, 0x20), c1.rune);
}

test "parser.py: ESC ( 0 designates G0; print 'q' as ─" {
    var h = try Harness.init(std.testing.allocator, 5, 1);
    defer h.deinit();
    h.arm();
    h.feed("\x1b(0q"); // G0 ← dec_graphics, then 'q' → ─
    const c0 = h.screen.cellAt(0, 0);
    try std.testing.expectEqual(@as(u32, 0x2500), c0.rune);
}

// ── test_osc_codes (subset we implement) ──────────────────────────

test "parser.py: OSC 0 / OSC 2 set title (BEL terminated)" {
    var h = try Harness.init(std.testing.allocator, 10, 1);
    defer h.deinit();
    h.arm();
    h.feed("a\x1b]2;hello\x07b");
    try std.testing.expect(h.titles.items.len > 0);
    try std.testing.expectEqualStrings("hello", h.titles.items[0]);
}

test "parser.py: OSC 2 with ST terminator" {
    var h = try Harness.init(std.testing.allocator, 10, 1);
    defer h.deinit();
    h.arm();
    h.feed("\x1b]2;world\x1b\\");
    try std.testing.expect(h.titles.items.len > 0);
    try std.testing.expectEqualStrings("world", h.titles.items[0]);
}

test "parser.py: OSC 8 malformed (no second ;) ignored" {
    var h = try Harness.init(std.testing.allocator, 10, 1);
    defer h.deinit();
    h.arm();
    h.feed("\x1b]8moo\x07X");
    // No link should be active; the 'X' has no link flag.
    const c = h.screen.cellAt(0, 0);
    try std.testing.expect(c.flags & 0b0000_0100 == 0);
}

// ── test_csi_code_rep (REP) ───────────────────────────────────────

test "parser.py: REP repeats last printed glyph" {
    var h = try Harness.init(std.testing.allocator, 10, 1);
    defer h.deinit();
    h.arm();
    h.feed("x\x1b[7b"); // print x, REP 7 → x repeated 7 more
    const r = try h.line(std.testing.allocator, 0);
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("xxxxxxxx", r);
}

test "parser.py: REP without prior print is a no-op" {
    var h = try Harness.init(std.testing.allocator, 10, 1);
    defer h.deinit();
    h.arm();
    h.feed("\x1b[5b"); // no last-printed → nothing
    const r = try h.line(std.testing.allocator, 0);
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("", r);
}

test "parser.py: REP after a TAB is a no-op (TAB isn't a glyph)" {
    var h = try Harness.init(std.testing.allocator, 10, 1);
    defer h.deinit();
    h.arm();
    h.feed("\t\x1b[3b");
    const r = try h.line(std.testing.allocator, 0);
    defer std.testing.allocator.free(r);
    // Tab moves cursor; REP has no glyph to repeat. No printed
    // characters appear on the line.
    try std.testing.expectEqualStrings("", r);
}

// ── test_oth_codes (PM / SOS unrecognized) ────────────────────────

test "parser.py: PM (ESC ^ ... ESC \\) is silently consumed" {
    var h = try Harness.init(std.testing.allocator, 10, 1);
    defer h.deinit();
    h.arm();
    h.feed("a\x1b^+\\+\x1b\\b");
    const r = try h.line(std.testing.allocator, 0);
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("ab", r);
}

test "parser.py: APC with unrecognized command consumed silently" {
    var h = try Harness.init(std.testing.allocator, 10, 1);
    defer h.deinit();
    h.arm();
    h.feed("a\x1b_+\\+\x1b\\b");
    const r = try h.line(std.testing.allocator, 0);
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("ab", r);
}

// ── test_bottom_margin / test_top_and_bottom_margin (DECSTBM) ─────

test "screen.py: DECSTBM bottom-margin scroll" {
    var h = try Harness.init(std.testing.allocator, 10, 6);
    defer h.deinit();
    h.arm();
    // CSI 1;5 r — top=1, bottom=5 (1-indexed) → 0..4 inclusive.
    h.feed("\x1b[1;5r");
    var i: u8 = 0;
    while (i < 6) : (i += 1) {
        var b: [1]u8 = .{ '0' + i };
        h.feed(&b);
        h.feed("\r\n");
    }
    // Inside-region rows scroll while writing more.
    var j: u8 = 6;
    while (j < 8) : (j += 1) {
        var b: [1]u8 = .{ '0' + j };
        h.feed(&b);
        h.feed("\r\n");
    }
    // Row 5 (outside region) should still hold whatever was there
    // when we last touched it. Inside-region rows show '4','5','6','7'.
    const r0 = try h.line(std.testing.allocator, 0);
    defer std.testing.allocator.free(r0);
    try std.testing.expectEqualStrings("4", r0);
    const r1 = try h.line(std.testing.allocator, 1);
    defer std.testing.allocator.free(r1);
    try std.testing.expectEqualStrings("5", r1);
    const r2 = try h.line(std.testing.allocator, 2);
    defer std.testing.allocator.free(r2);
    try std.testing.expectEqualStrings("6", r2);
    const r3 = try h.line(std.testing.allocator, 3);
    defer std.testing.allocator.free(r3);
    try std.testing.expectEqualStrings("7", r3);
}

// ── test_osc_52 (more thorough, from screen.py) ───────────────────

test "screen.py: OSC 52 with non-base64 chars rejected" {
    var h = try Harness.init(std.testing.allocator, 5, 1);
    defer h.deinit();
    h.arm();
    // Capture the clipboard set sink.
    const Spy = struct {
        var captured: [16]u8 = undefined;
        var captured_len: usize = 0;
        fn cb(_: ?*anyopaque, t: []const u8) void {
            const n = @min(t.len, captured.len);
            @memcpy(captured[0..n], t[0..n]);
            captured_len = n;
        }
    };
    Spy.captured_len = 0;
    h.screen.sink.on_clipboard_set = Spy.cb;
    h.feed("\x1b]52;c;@@@@@\x07");
    try std.testing.expectEqual(@as(usize, 0), Spy.captured_len);
}

// ── test_dirty_lines: cursor-only moves don't dirty rows ──────────

test "screen.py: cursor-only moves don't dirty unaffected rows" {
    var h = try Harness.init(std.testing.allocator, 5, 5);
    defer h.deinit();
    h.arm();
    // Reset all dirty bits.
    var r: u16 = 0;
    while (r < 5) : (r += 1) h.screen.line(r).dirty = false;
    // Cursor moves only — no draw.
    h.feed("\x1b[3;3H\x1b[5;5H");
    // None of the rows should have been marked dirty by cursor moves.
    r = 0;
    while (r < 5) : (r += 1) {
        try std.testing.expect(!h.screen.line(r).dirty);
    }
}

// ── DECRQM private mode query ────────────────────────────────────

test "parser.py: DECRQM (CSI ? Pa $ p) reports cursor visible" {
    var h = try Harness.init(std.testing.allocator, 5, 1);
    defer h.deinit();
    h.arm();
    h.feed("\x1b[?25$p");
    // Reply: ESC [ ? 25 ; Ps $ y where Ps=1 (set, default visible).
    try std.testing.expectEqualStrings("\x1b[?25;1$y", h.wtc.items);
    h.wtc.clearRetainingCapacity();
    h.feed("\x1b[?25l");
    h.feed("\x1b[?25$p");
    try std.testing.expectEqualStrings("\x1b[?25;2$y", h.wtc.items);
}

// ── test_da1 with DECID (ESC Z) ──────────────────────────────────

test "parser.py: DECID (ESC Z) emits DA1 reply" {
    var h = try Harness.init(std.testing.allocator, 5, 1);
    defer h.deinit();
    h.arm();
    h.feed("\x1bZ");
    try std.testing.expectEqualStrings("\x1b[?62;4;22c", h.wtc.items);
}

// ── ENQ (0x05) — answerback (we send empty) ──────────────────────

test "parser.py: ENQ (0x05) is silently consumed" {
    var h = try Harness.init(std.testing.allocator, 5, 1);
    defer h.deinit();
    h.arm();
    h.feed("\x05");
    // No response bytes from us (answerback string is empty).
    try std.testing.expectEqual(@as(usize, 0), h.wtc.items.len);
}
