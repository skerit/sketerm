//! Word-motion helpers for copy mode (w / b) and word selection.
//!
//! Pure functions over a cells slice + the per-screen `word_chars`
//! punctuation set, so the vim-style motions are unit-testable
//! without a Screen.

const std = @import("std");
const Cell = @import("cell.zig").Cell;

/// Word-class membership. Mirrors xterm's default: ASCII alnum,
/// any non-ASCII codepoint, plus the configurable `word_chars`
/// punctuation set. Blank (rune 0) and space are separators.
pub fn isWordChar(word_chars: []const u8, cp: u32) bool {
    if (cp == ' ' or cp == 0) return false;
    if (cp >= 'a' and cp <= 'z') return true;
    if (cp >= 'A' and cp <= 'Z') return true;
    if (cp >= '0' and cp <= '9') return true;
    if (cp >= 0x80) return true; // any non-ASCII codepoint
    for (word_chars) |b| if (b == cp) return true;
    return false;
}

/// Column of the next word start strictly after `col`, or null when
/// no further word begins on this line.
pub fn nextWordStart(cells: []const Cell, word_chars: []const u8, col: usize) ?usize {
    var i = col;
    // Skip the remainder of the current word (no-op on a separator).
    while (i < cells.len and isWordChar(word_chars, cells[i].rune)) i += 1;
    // Skip separators up to the next word.
    while (i < cells.len and !isWordChar(word_chars, cells[i].rune)) i += 1;
    if (i >= cells.len) return null;
    return i;
}

/// Column of the previous word start strictly before `col`, or null.
/// A cursor mid-word lands on that word's own start first (vim `b`).
pub fn prevWordStart(cells: []const Cell, word_chars: []const u8, col: usize) ?usize {
    if (cells.len == 0 or col == 0) return null;
    var i: usize = @min(col, cells.len) - 1;
    while (!isWordChar(word_chars, cells[i].rune)) {
        if (i == 0) return null;
        i -= 1;
    }
    while (i > 0 and isWordChar(word_chars, cells[i - 1].rune)) i -= 1;
    return i;
}

/// Start of the first word on the line (used when `w` wraps down).
pub fn firstWordStart(cells: []const Cell, word_chars: []const u8) ?usize {
    if (cells.len == 0) return null;
    if (isWordChar(word_chars, cells[0].rune)) return 0;
    return nextWordStart(cells, word_chars, 0);
}

/// Start of the last word on the line (used when `b` wraps up).
pub fn lastWordStart(cells: []const Cell, word_chars: []const u8) ?usize {
    return prevWordStart(cells, word_chars, cells.len);
}

// ── Tests ─────────────────────────────────────────────────────────

const test_word_chars = "-_.,/?:@&=+%~";

fn cellsFrom(comptime s: []const u8) [s.len]Cell {
    var out: [s.len]Cell = undefined;
    for (s, 0..) |b, i| out[i] = .{ .rune = b };
    return out;
}

test "nextWordStart skips current word and separators" {
    const cells = cellsFrom("foo  bar baz");
    try std.testing.expectEqual(@as(?usize, 5), nextWordStart(&cells, test_word_chars, 0));
    try std.testing.expectEqual(@as(?usize, 5), nextWordStart(&cells, test_word_chars, 2));
    try std.testing.expectEqual(@as(?usize, 5), nextWordStart(&cells, test_word_chars, 3)); // on a space
    try std.testing.expectEqual(@as(?usize, 9), nextWordStart(&cells, test_word_chars, 5));
    try std.testing.expectEqual(@as(?usize, null), nextWordStart(&cells, test_word_chars, 9));
}

test "prevWordStart lands on word starts walking left" {
    const cells = cellsFrom("foo  bar baz");
    try std.testing.expectEqual(@as(?usize, 9), prevWordStart(&cells, test_word_chars, 11));
    try std.testing.expectEqual(@as(?usize, 5), prevWordStart(&cells, test_word_chars, 9));
    try std.testing.expectEqual(@as(?usize, 5), prevWordStart(&cells, test_word_chars, 7)); // mid-word → own start
    try std.testing.expectEqual(@as(?usize, 0), prevWordStart(&cells, test_word_chars, 5));
    try std.testing.expectEqual(@as(?usize, null), prevWordStart(&cells, test_word_chars, 0));
}

test "word_chars punctuation joins words" {
    const cells = cellsFrom("a/b.c x");
    // The path chars are word chars, so "a/b.c" is one word.
    try std.testing.expectEqual(@as(?usize, 6), nextWordStart(&cells, test_word_chars, 0));
    try std.testing.expectEqual(@as(?usize, 0), prevWordStart(&cells, test_word_chars, 4));
}

test "first/last word start, blank tails, empty line" {
    const cells = cellsFrom("  hi there  ");
    try std.testing.expectEqual(@as(?usize, 2), firstWordStart(&cells, test_word_chars));
    try std.testing.expectEqual(@as(?usize, 5), lastWordStart(&cells, test_word_chars));
    const blank = cellsFrom("    ");
    try std.testing.expectEqual(@as(?usize, null), firstWordStart(&blank, test_word_chars));
    try std.testing.expectEqual(@as(?usize, null), lastWordStart(&blank, test_word_chars));
    try std.testing.expectEqual(@as(?usize, null), firstWordStart(&.{}, test_word_chars));
}
