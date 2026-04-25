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
    const r0 = try h.line(std.testing.allocator, 0);
    defer std.testing.allocator.free(r0);
    try std.testing.expectEqualStrings("b", r0);
}

test "wezterm c1.rs test_nel: ESC E acts as CR + LF" {
    var h = try Harness.init(std.testing.allocator, 4, 4);
    defer h.deinit();
    h.arm();
    h.feed("a\r\nb\x1bE");
    try std.testing.expectEqual(@as(u16, 0), h.screen.col);
    try std.testing.expectEqual(@as(u16, 2), h.screen.row);
    h.feed("\x1bE");
    try std.testing.expectEqual(@as(u16, 3), h.screen.row);
    try std.testing.expectEqual(@as(u16, 0), h.screen.col);
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
    // Now at row 3, col 1.
    try std.testing.expectEqual(@as(u16, 3), h.screen.row);
    h.feed("\x1bM");
    try std.testing.expectEqual(@as(u16, 2), h.screen.row);
    h.feed("\x1bM");
    try std.testing.expectEqual(@as(u16, 1), h.screen.row);
    h.feed("\x1bM");
    try std.testing.expectEqual(@as(u16, 0), h.screen.row);
    // RI at row 0 scrolls down (clears row 0). The 'd.' was on
    // row 3; after one scroll-down it moves to row 4 → off-screen.
    h.feed("\x1bM");
    try std.testing.expectEqual(@as(u16, 0), h.screen.row);
    const r0 = try h.line(std.testing.allocator, 0);
    defer std.testing.allocator.free(r0);
    try std.testing.expectEqualStrings("", r0);
    const r1 = try h.line(std.testing.allocator, 1);
    defer std.testing.allocator.free(r1);
    try std.testing.expectEqualStrings("a", r1);
}
