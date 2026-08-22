//! Tests ported from wezterm/term/src/test/{c0,c1}.rs.
//! WezTerm uses k9::snapshot! for full-state diffs which are too
//! noisy to port verbatim — these are the bug-regression intents
//! re-expressed as minimal Zig assertions.

const std = @import("std");
const Harness = @import("test_harness.zig").Harness;

// ── c0.rs ─────────────────────────────────────────────────────────

test "wezterm c0.rs test_bs: BS at col 0 stays at col 0" {
    var h = try Harness.init(std.testing.allocator, 4, 3);
    defer h.deinit();
    h.arm();
    try std.testing.expectEqual(@as(u16, 0), h.screen.col);
    h.feed("\x08");
    try std.testing.expectEqual(@as(u16, 0), h.screen.col);
    h.feed("ab\x08");
    try std.testing.expectEqual(@as(u16, 1), h.screen.col);
}

test "wezterm c0.rs test_lf: LF moves vertically only (no CR)" {
    var h = try Harness.init(std.testing.allocator, 10, 3);
    defer h.deinit();
    h.arm();
    h.feed("hello\n");
    try std.testing.expectEqual(@as(u16, 5), h.screen.col);
    try std.testing.expectEqual(@as(u16, 1), h.screen.row);
}

test "wezterm c0.rs test_cr: CR moves to col 0 on the same row" {
    var h = try Harness.init(std.testing.allocator, 10, 3);
    defer h.deinit();
    h.arm();
    h.feed("hello\r");
    try std.testing.expectEqual(@as(u16, 0), h.screen.col);
    try std.testing.expectEqual(@as(u16, 0), h.screen.row);
}

test "wezterm c0.rs test_tab: HT advances to 8/16/24, clamps at last col" {
    var h = try Harness.init(std.testing.allocator, 25, 3);
    defer h.deinit();
    h.arm();
    h.feed("\t");
    try std.testing.expectEqual(@as(u16, 8), h.screen.col);
    h.feed("\t");
    try std.testing.expectEqual(@as(u16, 16), h.screen.col);
    h.feed("\t");
    try std.testing.expectEqual(@as(u16, 24), h.screen.col);
    h.feed("\t"); // already at cols-1, stays.
    try std.testing.expectEqual(@as(u16, 24), h.screen.col);
}

// ── c1.rs ─────────────────────────────────────────────────────────

test "wezterm c1.rs test_ind: ESC D advances row, scrolls at bottom" {
    var h = try Harness.init(std.testing.allocator, 4, 4);
    defer h.deinit();
    h.arm();
    h.feed("a\r\nb\x1bD");
    try std.testing.expectEqual(@as(u16, 1), h.screen.col);
    try std.testing.expectEqual(@as(u16, 2), h.screen.row);
    h.feed("\x1bD");
    try std.testing.expectEqual(@as(u16, 3), h.screen.row);
    h.feed("\x1bD"); // at bottom — IND scrolls; row stays 3.
    try std.testing.expectEqual(@as(u16, 3), h.screen.row);
    // After the scroll, "a\nb\n" → "b\n\n\n".
    try h.expectLine(0, "b");
}

test "wezterm c1.rs test_nel: ESC E acts as CR + LF" {
    var h = try Harness.init(std.testing.allocator, 4, 4);
    defer h.deinit();
    h.arm();
    h.feed("a\r\nb\x1bE");
    try std.testing.expectEqual(@as(u16, 0), h.screen.col);
    try std.testing.expectEqual(@as(u16, 2), h.screen.row);
    h.feed("\x1bE");
    try h.expectCursor(3, 0);
}

test "wezterm c1.rs test_hts: ESC H sets a tab stop" {
    var h = try Harness.init(std.testing.allocator, 25, 3);
    defer h.deinit();
    h.arm();
    h.feed("boo"); // at col 3
    h.feed("\x1bH"); // HTS at col 3
    h.feed("\r\n"); // → row 1 col 0
    h.feed("\t");
    try std.testing.expectEqual(@as(u16, 3), h.screen.col);
    h.feed("\t"); // → next default 8-col stop
    try std.testing.expectEqual(@as(u16, 8), h.screen.col);
}

test "wezterm c1.rs test_ri: ESC M reverse line feed; scrolls at top" {
    var h = try Harness.init(std.testing.allocator, 2, 4);
    defer h.deinit();
    h.arm();
    h.feed("a\r\nb\r\nc\r\nd.");
    try std.testing.expectEqual(@as(u16, 3), h.screen.row);
    h.feed("\x1bM");
    try std.testing.expectEqual(@as(u16, 2), h.screen.row);
    h.feed("\x1bM");
    try std.testing.expectEqual(@as(u16, 1), h.screen.row);
    h.feed("\x1bM");
    try std.testing.expectEqual(@as(u16, 0), h.screen.row);
    h.feed("\x1bM");
    try std.testing.expectEqual(@as(u16, 0), h.screen.row);
    try h.expectLine(0, "");
    try h.expectLine(1, "a");
}

// ── csi.rs ────────────────────────────────────────────────────────

test "wezterm csi.rs test_vpa: VPA (CSI d) absolute row" {
    var h = try Harness.init(std.testing.allocator, 4, 3);
    defer h.deinit();
    h.arm();
    h.feed("a\r\nb\r\nc"); // row 2 col 1
    h.feed("\x1b[d"); // VPA default → row 0 (1-indexed col 1 → 0)
    try std.testing.expectEqual(@as(u16, 0), h.screen.row);
    h.feed("\x1b[2d"); // VPA 2 → row 1
    try std.testing.expectEqual(@as(u16, 1), h.screen.row);
}

test "wezterm csi.rs test_rep: REP (CSI b) repeats prior glyph" {
    var h = try Harness.init(std.testing.allocator, 4, 3);
    defer h.deinit();
    h.arm();
    // wezterm test_rep does cup(1, 0) which is (col=1, row=0); CSI
    // is row;col 1-indexed → "\x1b[1;2H".
    h.feed("h\x1b[1;2H\x1b[2ba");
    try h.expectLine(0, "hhha");
}

test "wezterm csi.rs test_irm: IRM (CSI 4 h) inserts" {
    var h = try Harness.init(std.testing.allocator, 8, 3);
    defer h.deinit();
    h.arm();
    h.feed("foo\x1b[1;1H\x1b[4hBAR");
    try h.expectLine(0, "BARfoo");
}

test "wezterm csi.rs test_ich: ICH (CSI @) shifts right" {
    var h = try Harness.init(std.testing.allocator, 4, 3);
    defer h.deinit();
    h.arm();
    h.feed("hey!wat?"); // wraps: row0='hey!', row1='wat?'
    h.feed("\x1b[1;2H"); // row 0 col 1
    h.feed("\x1b[2@");
    try h.expectLine(0, "h  e");
}

test "wezterm csi.rs test_ech: ECH (CSI X) blanks without shift" {
    var h = try Harness.init(std.testing.allocator, 4, 3);
    defer h.deinit();
    h.arm();
    h.feed("hey!wat?");
    h.feed("\x1b[1;2H");
    h.feed("\x1b[2X");
    try h.expectLine(0, "h  !");
}

test "wezterm csi.rs test_dch: DCH (CSI P) shifts left" {
    var h = try Harness.init(std.testing.allocator, 11, 1);
    defer h.deinit();
    h.arm();
    h.feed("hello world\x1b[1;2H");
    h.feed("\x1b[P"); // DCH 1
    try h.expectLine(0, "hllo world");
}

test "wezterm csi.rs test_cup: CUP clamps to last cell" {
    var h = try Harness.init(std.testing.allocator, 3, 5);
    defer h.deinit();
    h.arm();
    h.feed("\x1b[2;2H");
    try h.expectCursor(1, 1);
    h.feed("\x1b[500;500H");
    try h.expectCursor(4, 2);
}

test "wezterm csi.rs test_dl: DL (CSI M) deletes lines" {
    var h = try Harness.init(std.testing.allocator, 4, 3);
    defer h.deinit();
    h.arm();
    h.feed("a\r\nb\r\nc");
    h.feed("\x1b[2;1H"); // row 1 col 0
    h.feed("\x1b[M"); // DL 1
    try h.expectLine(0, "a");
    try h.expectLine(1, "c");
}

test "wezterm csi.rs test_cha: CHA (CSI G) absolute column" {
    var h = try Harness.init(std.testing.allocator, 5, 3);
    defer h.deinit();
    h.arm();
    h.feed("\x1b[2;2H");
    h.feed("\x1b[G"); // default → col 0
    try std.testing.expectEqual(@as(u16, 0), h.screen.col);
    try std.testing.expectEqual(@as(u16, 1), h.screen.row);
    h.feed("\x1b[3G"); // col 2 (1-indexed)
    try std.testing.expectEqual(@as(u16, 2), h.screen.col);
}

test "wezterm csi.rs test_ed_erase_scrollback: CSI 3 J wipes scrollback" {
    var h = try Harness.init(std.testing.allocator, 3, 2);
    defer h.deinit();
    h.arm();
    // Force some lines into scrollback.
    h.feed("a\r\nb\r\nc\r\nd\r\ne\r\nf");
    try std.testing.expect(h.screen.scrollbackCount() > 0);
    h.feed("\x1b[3J");
    try std.testing.expectEqual(@as(u32, 0), h.screen.scrollbackCount());
}
