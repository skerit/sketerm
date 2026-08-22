//! Conformance tests ported from kitty/kitty_tests/parser.py and
//! wezterm/term/src/test/csi.rs. The pattern mirrors Kitty's
//! `parse_bytes_dump`: build a screen, feed bytes, assert on
//! observable state. The Harness lives in test_harness.zig.

const std = @import("std");
const Harness = @import("test_harness.zig").Harness;

// ──────────────────────────────────────────────────────────────────
// Originally ported batch
// ──────────────────────────────────────────────────────────────────

test "kitty parser.py: simple parsing — text wraps, CR/LF, UTF-8" {
    var h = try Harness.init(std.testing.allocator, 5, 4);
    defer h.deinit();
    h.arm();

    h.feed("12");
    try h.expectLine(0, "12");
    try std.testing.expectEqual(@as(u16, 2), h.screen.col);

    h.feed("3456");
    try h.expectLine(0, "12345");
    try h.expectLine(1, "6");

    h.feed("\n123\n\r45");
    try h.expectLine(2, " 123");
    try h.expectLine(3, "45");
}

test "kitty parser.py: CSI ICH (CSI @) with various param shapes" {
    var h = try Harness.init(std.testing.allocator, 5, 1);
    defer h.deinit();
    h.arm();
    h.feed("abcde");
    h.feed("\x1b[H");
    h.feed("x\x1b[2@y");
    try h.expectLine(0, "xy bc");
}

test "kitty parser.py: CSI CUP edge cases" {
    var h = try Harness.init(std.testing.allocator, 80, 24);
    defer h.deinit();
    h.arm();
    h.feed("\x1b[H");
    try h.expectCursor(0, 0);
    h.feed("\x1b[4H");
    try h.expectCursor(3, 0);
    h.feed("\x1b[3;2H");
    try h.expectCursor(2, 1);
    h.feed("\x1b[00000000003;0000000000000002H");
    try h.expectCursor(2, 1);
    h.feed("\x1b[999;999H");
    try h.expectCursor(23, 79);
}

test "kitty parser.py: DSR 5n + 6n responses" {
    var h = try Harness.init(std.testing.allocator, 80, 24);
    defer h.deinit();
    h.arm();
    h.feed("\x1b[5n");
    try std.testing.expectEqualStrings("\x1b[0n", h.wtc.items);
    h.wtc.clearRetainingCapacity();
    h.feed("\x1b[6n");
    try std.testing.expectEqualStrings("\x1b[1;1R", h.wtc.items);
    h.wtc.clearRetainingCapacity();
    h.feed("12345");
    h.feed("\x1b[6n");
    try std.testing.expectEqualStrings("\x1b[1;6R", h.wtc.items);
}

test "wezterm csi.rs issue 789: DCH shifts remaining left" {
    var h = try Harness.init(std.testing.allocator, 8, 1);
    defer h.deinit();
    h.arm();
    h.feed("\x1b[40m\x1b[Kfoo\x1b[H\x1b[2P");
    try h.expectLine(0, "o");
}

test "kitty parser.py: SGR truecolor parses both 38;2 and 38:2 forms" {
    var h = try Harness.init(std.testing.allocator, 5, 2);
    defer h.deinit();
    h.arm();
    h.feed("\x1b[38;2;255;128;0;48;2;0;0;0mA");
    const c0 = h.screen.cellAt(0, 0);
    const style = h.screen.pool.get(c0.style_ref);
    try std.testing.expect(style.fg == .rgb);
    try std.testing.expectEqual(@as(u8, 255), style.fg.rgb.r);
    try std.testing.expectEqual(@as(u8, 128), style.fg.rgb.g);
    try std.testing.expectEqual(@as(u8, 0), style.fg.rgb.b);
    h.feed("\r\n");
    h.feed("\x1b[38:2:0:255:0;48:2:0:0:0mB");
    const c1 = h.screen.cellAt(1, 0);
    const style1 = h.screen.pool.get(c1.style_ref);
    try std.testing.expect(style1.fg == .rgb);
    try std.testing.expectEqual(@as(u8, 0), style1.fg.rgb.r);
    try std.testing.expectEqual(@as(u8, 255), style1.fg.rgb.g);
    try std.testing.expectEqual(@as(u8, 0), style1.fg.rgb.b);
}

test "kitty parser.py (variant): CSI with invalid byte doesn't crash" {
    var h = try Harness.init(std.testing.allocator, 10, 1);
    defer h.deinit();
    h.arm();
    h.feed("x\x1b[2-3@y");
    const r = try h.line(std.testing.allocator, 0);
    defer std.testing.allocator.free(r);
    const ok = std.mem.eql(u8, r, "xy") or std.mem.eql(u8, r, "x@y");
    try std.testing.expect(ok);
}

test "kitty parser.py: DECSCM 25 hides + shows cursor" {
    var h = try Harness.init(std.testing.allocator, 10, 5);
    defer h.deinit();
    h.arm();
    try std.testing.expect(h.screen.cursor_visible);
    h.feed("\x1b[?25l");
    try std.testing.expect(!h.screen.cursor_visible);
    h.feed("\x1b[?25h");
    try std.testing.expect(h.screen.cursor_visible);
}

test "kitty parser.py: ESC c (RIS) resets cursor + style" {
    var h = try Harness.init(std.testing.allocator, 10, 5);
    defer h.deinit();
    h.arm();
    h.feed("hello\x1b[H\x1b[31m");
    h.feed("\x1bc");
    try h.expectCursor(0, 0);
    try std.testing.expectEqual(@as(u16, 0), h.screen.cur_style);
}

test "kitty parser.py: C1 controls (8-bit) handled as printable" {
    var h = try Harness.init(std.testing.allocator, 20, 1);
    defer h.deinit();
    h.arm();
    h.feed("\x84\x85\x88\x8d\x8e\x8f\x90\x96\x97\x98\x9a\x9b\x9c\x9d\x9e\x9f");
    try h.expectCursor(0, 0);
}

test "kitty parser.py: incomplete UTF-8 split across feed() calls" {
    var h = try Harness.init(std.testing.allocator, 5, 1);
    defer h.deinit();
    h.arm();
    h.feed("\xF0\x9F\x98");
    try std.testing.expectEqual(@as(u16, 0), h.screen.col);
    h.feed("\x80");
    try std.testing.expectEqual(@as(u16, 2), h.screen.col);
}

test "OSC payload with UTF-8 bytes containing 0x9C is not truncated" {
    // ✳ is E2 9C B3 — the 0x9C continuation byte must NOT be treated
    // as an 8-bit ST. The pre-fix behaviour cut the title there and
    // printed " Claude Code" into the grid at the cursor (the exact
    // "ghost text" seen with Claude Code, whose title/spinner glyphs
    // ✳/✓ all carry 0x9C). Only BEL / ESC \ terminate.
    var h = try Harness.init(std.testing.allocator, 40, 2);
    defer h.deinit();
    h.arm();
    h.feed("\x1b]0;\xE2\x9C\xB3 Claude Code\x07");
    // Nothing printed: cursor untouched, row empty.
    try h.expectCursor(0, 0);
    try h.expectLine(0, "");
    // Ground state: following text prints normally.
    h.feed("ok");
    try h.expectLine(0, "ok");
}

test "OSC with ESC backslash terminator still dispatches cleanly" {
    var h = try Harness.init(std.testing.allocator, 40, 2);
    defer h.deinit();
    h.arm();
    h.feed("\x1b]2;title \xE2\x9C\x93 done\x1b\\after");
    try h.expectLine(0, "after");
}
