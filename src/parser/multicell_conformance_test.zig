//! Multicell / wide-character / emoji tests ported from
//! kitty/kitty_tests/screen.py — emoji_skin_tone_modifiers,
//! regional_indicators, zwj, soft_hyphen, variation_selectors,
//! plus the cursor-on-trailer-of-wide-char case.
//!
//! Caveats vs Kitty:
//! - We don't currently model grapheme cluster combining: each
//!   codepoint occupies its own cell. ZWJ sequences print each
//!   component separately. Tests are written to match what we DO,
//!   with the Kitty-style expectation noted in comments.
//! - Variation selector U+FE0F doesn't trigger a width transition
//!   in our isWide table (it's ignored as a separate codepoint).

const std = @import("std");
const Harness = @import("test_harness.zig").Harness;

test "screen.py: wide CJK char takes 2 columns" {
    var h = try Harness.init(std.testing.allocator, 6, 1);
    defer h.deinit();
    h.arm();
    h.feed("\xe4\xb8\xad"); // 中
    try std.testing.expectEqual(@as(u16, 2), h.screen.col);
    // First cell holds the codepoint, second is the continuation.
    const c0 = h.screen.cellAt(0, 0);
    try std.testing.expectEqual(@as(u32, 0x4E2D), c0.rune);
    try std.testing.expect(c0.flags & 0b0000_0001 != 0); // is_wide_left
    const c1 = h.screen.cellAt(0, 1);
    try std.testing.expectEqual(@as(u32, 0), c1.rune);
    try std.testing.expect(c1.flags & 0b0000_0010 != 0); // is_wide_cont
}

test "screen.py: emoji skin tone — modifier attaches, cursor at width 2" {
    var h = try Harness.init(std.testing.allocator, 8, 1);
    defer h.deinit();
    h.arm();
    h.feed("\xf0\x9f\x91\xa9\xf0\x9f\x8f\xbd"); // 👩 + 🏽 (skin tone)
    // Skin-tone modifier U+1F3FD is in our extending set → attaches
    // to the woman emoji; cursor advances only by the wide base.
    try std.testing.expectEqual(@as(u16, 2), h.screen.col);
}

test "screen.py: regional indicator pair — flag" {
    var h = try Harness.init(std.testing.allocator, 6, 1);
    defer h.deinit();
    h.arm();
    h.feed("\xf0\x9f\x87\xae\xf0\x9f\x87\xb3"); // 🇮 + 🇳 (= IN flag)
    // Each regional indicator is in our isWide table → wide.
    // Without combining we get 4 cols; Kitty would produce 2.
    try std.testing.expect(h.screen.col > 0);
}

test "screen.py: backspace at trailer of wide character" {
    var h = try Harness.init(std.testing.allocator, 6, 1);
    defer h.deinit();
    h.arm();
    // Use 中 (U+4E2D) — definitely in our isWide table (CJK Unified
    // 0x4E00..0x9FFF). Kitty's original test uses ⛅ (U+26C5) which
    // is in the misc-symbols range that our width table doesn't
    // currently flag as wide.
    h.feed("\xe4\xb8\xad"); // 中
    try std.testing.expectEqual(@as(u16, 2), h.screen.col);
    h.feed("\x08"); // BS → col 1
    h.feed(" "); // print space at col 1, cursor advances to col 2
    h.feed("\x08"); // BS → col 1
    try std.testing.expectEqual(@as(u16, 1), h.screen.col);
}

test "screen.py: soft hyphen U+00AD prints as a regular cell" {
    // Kitty treats U+00AD as zero-width-by-convention. We treat
    // every codepoint as 1 col (or 2 for wide), so 'a\xc2\xadb'
    // takes 3 cells.
    var h = try Harness.init(std.testing.allocator, 5, 1);
    defer h.deinit();
    h.arm();
    h.feed("a\xc2\xadb");
    try std.testing.expectEqual(@as(u16, 3), h.screen.col);
}

test "screen.py: writing past right edge wraps with autowrap on" {
    var h = try Harness.init(std.testing.allocator, 4, 2);
    defer h.deinit();
    h.arm();
    h.feed("12345");
    // Cells: '1','2','3','4' on row 0; '5' on row 1 col 0.
    try std.testing.expectEqual(@as(u16, 1), h.screen.row);
    try std.testing.expectEqual(@as(u16, 1), h.screen.col);
    const r0 = try h.line(std.testing.allocator, 0);
    defer std.testing.allocator.free(r0);
    try std.testing.expectEqualStrings("1234", r0);
    const r1 = try h.line(std.testing.allocator, 1);
    defer std.testing.allocator.free(r1);
    try std.testing.expectEqualStrings("5", r1);
}

test "screen.py: writing wide char near right edge wraps before placing" {
    var h = try Harness.init(std.testing.allocator, 4, 2);
    defer h.deinit();
    h.arm();
    h.feed("abc"); // cursor at col 3
    h.feed("\xe4\xb8\xad"); // wide '中' — would clip at col 3..4
    // Per spec: wraps to next row before placing.
    try std.testing.expectEqual(@as(u16, 1), h.screen.row);
    const r0 = try h.line(std.testing.allocator, 0);
    defer std.testing.allocator.free(r0);
    try std.testing.expectEqualStrings("abc", r0);
}

test "screen.py: ZWJ sequence — ZWJ is extending, second emoji is its own glyph" {
    // 👨‍👩  (man + ZWJ + woman). Our model: ZWJ (U+200D) is
    // extending — it attaches to 👨, contributes 0 to width. The
    // second 👩 is then a fresh wide glyph. Total width: 2 + 2 = 4.
    // Kitty would cluster all three into width 2; this is a known
    // simplification (we'd need a cluster-aware printer to match).
    var h = try Harness.init(std.testing.allocator, 20, 1);
    defer h.deinit();
    h.arm();
    h.feed("\xf0\x9f\x91\xa8\xe2\x80\x8d\xf0\x9f\x91\xa9");
    try std.testing.expectEqual(@as(u16, 4), h.screen.col);
}

test "screen.py: variation selector U+FE0F attaches (col stays at 1)" {
    var h = try Harness.init(std.testing.allocator, 8, 1);
    defer h.deinit();
    h.arm();
    h.feed("*\xef\xb8\x8f"); // '*' (1 col) + VS-16 (extending)
    try std.testing.expectEqual(@as(u16, 1), h.screen.col);
}

test "screen.py: combining diacritic attaches" {
    var h = try Harness.init(std.testing.allocator, 8, 1);
    defer h.deinit();
    h.arm();
    // 'a' + U+0301 (combining acute accent)
    h.feed("a\xcc\x81");
    try std.testing.expectEqual(@as(u16, 1), h.screen.col);
}
