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

/// Which alphabet a motion runs over. `word` is the punctuation-aware
/// class above; `big` is vim's WORD — anything that is not blank, so
/// `foo/bar.baz` counts as one.
pub const Kind = enum { word, big };

fn member(kind: Kind, word_chars: []const u8, cp: u32) bool {
    return switch (kind) {
        .word => isWordChar(word_chars, cp),
        .big => cp != 0 and cp != ' ',
    };
}

/// Column of the next word start strictly after `col`, or null when
/// no further word begins on this line.
pub fn nextWordStart(cells: []const Cell, word_chars: []const u8, col: usize) ?usize {
    return nextStart(cells, word_chars, col, .word);
}

pub fn nextStart(cells: []const Cell, word_chars: []const u8, col: usize, kind: Kind) ?usize {
    var i = col;
    // Skip the remainder of the current word (no-op on a separator).
    while (i < cells.len and member(kind, word_chars, cells[i].rune)) i += 1;
    // Skip separators up to the next word.
    while (i < cells.len and !member(kind, word_chars, cells[i].rune)) i += 1;
    if (i >= cells.len) return null;
    return i;
}

/// Column of the previous word start strictly before `col`, or null.
/// A cursor mid-word lands on that word's own start first (vim `b`).
pub fn prevWordStart(cells: []const Cell, word_chars: []const u8, col: usize) ?usize {
    return prevStart(cells, word_chars, col, .word);
}

pub fn prevStart(cells: []const Cell, word_chars: []const u8, col: usize, kind: Kind) ?usize {
    if (cells.len == 0 or col == 0) return null;
    var i: usize = @min(col, cells.len) - 1;
    while (!member(kind, word_chars, cells[i].rune)) {
        if (i == 0) return null;
        i -= 1;
    }
    while (i > 0 and member(kind, word_chars, cells[i - 1].rune)) i -= 1;
    return i;
}

/// Column of the next word END strictly after `col` (vim `e`), or
/// null. A cursor already sitting on a word's last character moves on
/// to the following word rather than standing still.
pub fn nextEnd(cells: []const Cell, word_chars: []const u8, col: usize, kind: Kind) ?usize {
    if (cells.len == 0) return null;
    var i = col + 1;
    while (i < cells.len and !member(kind, word_chars, cells[i].rune)) i += 1;
    if (i >= cells.len) return null;
    while (i + 1 < cells.len and member(kind, word_chars, cells[i + 1].rune)) i += 1;
    return i;
}

/// Column of the previous word end strictly before `col`, or null.
pub fn prevEnd(cells: []const Cell, word_chars: []const u8, col: usize, kind: Kind) ?usize {
    if (cells.len == 0 or col == 0) return null;
    var i: usize = @min(col, cells.len) - 1;
    while (!member(kind, word_chars, cells[i].rune)) {
        if (i == 0) return null;
        i -= 1;
    }
    // `i` is now inside a word; if that word reaches `col` it is the
    // one the cursor is in, so skip back over it to the one before.
    if (i + 1 == @min(col, cells.len)) {
        while (i > 0 and member(kind, word_chars, cells[i - 1].rune)) i -= 1;
        if (i == 0) return null;
        i -= 1;
        while (!member(kind, word_chars, cells[i].rune)) {
            if (i == 0) return null;
            i -= 1;
        }
    }
    return i;
}

/// Start of the first word on the line (used when `w` wraps down).
pub fn firstWordStart(cells: []const Cell, word_chars: []const u8) ?usize {
    return firstStart(cells, word_chars, .word);
}

pub fn firstStart(cells: []const Cell, word_chars: []const u8, kind: Kind) ?usize {
    if (cells.len == 0) return null;
    if (member(kind, word_chars, cells[0].rune)) return 0;
    return nextStart(cells, word_chars, 0, kind);
}

/// Start of the last word on the line (used when `b` wraps up).
pub fn lastWordStart(cells: []const Cell, word_chars: []const u8) ?usize {
    return prevStart(cells, word_chars, cells.len, .word);
}

pub fn lastStart(cells: []const Cell, word_chars: []const u8, kind: Kind) ?usize {
    return prevStart(cells, word_chars, cells.len, kind);
}

/// End of the first word on the line (used when `e` wraps down).
pub fn firstEnd(cells: []const Cell, word_chars: []const u8, kind: Kind) ?usize {
    if (cells.len == 0) return null;
    if (member(kind, word_chars, cells[0].rune)) {
        var i: usize = 0;
        while (i + 1 < cells.len and member(kind, word_chars, cells[i + 1].rune)) i += 1;
        return i;
    }
    return nextEnd(cells, word_chars, 0, kind);
}

/// End of the last word on the line (used when a backwards end-motion
/// wraps up).
pub fn lastEnd(cells: []const Cell, word_chars: []const u8, kind: Kind) ?usize {
    if (cells.len == 0) return null;
    var i: usize = cells.len - 1;
    while (!member(kind, word_chars, cells[i].rune)) {
        if (i == 0) return null;
        i -= 1;
    }
    return i;
}

/// Column of `needle` on this line, searching forward from `col`
/// exclusive (vim `f`). `till` stops one cell short (vim `t`).
pub fn findForward(cells: []const Cell, col: usize, needle: u32, till: bool) ?usize {
    var i = col + 1;
    // `t` would otherwise never leave a cell already adjacent to a
    // match, so it starts one further along.
    if (till) i += 1;
    while (i < cells.len) : (i += 1) {
        if (cells[i].rune == needle) return if (till) i - 1 else i;
    }
    return null;
}

/// Column of `needle` searching backward from `col` exclusive (vim
/// `F`). `till` stops one cell short (vim `T`).
pub fn findBackward(cells: []const Cell, col: usize, needle: u32, till: bool) ?usize {
    if (col == 0) return null;
    var i: usize = @min(col, cells.len);
    while (i > 0) {
        i -= 1;
        if (cells[i].rune != needle) continue;
        if (!till) return i;
        // A match immediately behind the cursor would put `T` back
        // where it started, so keep looking.
        if (i + 1 < col) return i + 1;
    }
    return null;
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

test "nextEnd lands on the last character of each word" {
    const cells = cellsFrom("foo  bar baz");
    try std.testing.expectEqual(@as(?usize, 2), nextEnd(&cells, test_word_chars, 0, .word));
    // Already on an end: move on rather than stand still.
    try std.testing.expectEqual(@as(?usize, 7), nextEnd(&cells, test_word_chars, 2, .word));
    try std.testing.expectEqual(@as(?usize, 7), nextEnd(&cells, test_word_chars, 5, .word));
    try std.testing.expectEqual(@as(?usize, 11), nextEnd(&cells, test_word_chars, 7, .word));
    try std.testing.expectEqual(@as(?usize, null), nextEnd(&cells, test_word_chars, 11, .word));
}

test "prevEnd skips the word the cursor is inside" {
    const cells = cellsFrom("foo  bar baz");
    try std.testing.expectEqual(@as(?usize, 7), prevEnd(&cells, test_word_chars, 11, .word));
    try std.testing.expectEqual(@as(?usize, 7), prevEnd(&cells, test_word_chars, 9, .word));
    try std.testing.expectEqual(@as(?usize, 2), prevEnd(&cells, test_word_chars, 7, .word));
    try std.testing.expectEqual(@as(?usize, null), prevEnd(&cells, test_word_chars, 2, .word));
}

test "big-word motions ignore punctuation" {
    const cells = cellsFrom("a/b.c x");
    // Both classes agree here, because the punctuation happens to be
    // in the word_chars set...
    try std.testing.expectEqual(@as(?usize, 6), nextStart(&cells, test_word_chars, 0, .big));
    // ...but a WORD is anything non-blank, whatever the set says, so
    // "a(b)" is one WORD and two words.
    const punct = cellsFrom("a(b) c");
    try std.testing.expectEqual(@as(?usize, 5), nextStart(&punct, test_word_chars, 0, .big));
    try std.testing.expectEqual(@as(?usize, 2), nextStart(&punct, test_word_chars, 0, .word));
    try std.testing.expectEqual(@as(?usize, 3), nextEnd(&punct, test_word_chars, 0, .big));
}

test "find forward and backward, with and without till" {
    const cells = cellsFrom("abcabc");
    try std.testing.expectEqual(@as(?usize, 3), findForward(&cells, 0, 'a', false));
    try std.testing.expectEqual(@as(?usize, 2), findForward(&cells, 0, 'a', true));
    try std.testing.expectEqual(@as(?usize, null), findForward(&cells, 3, 'a', false));
    try std.testing.expectEqual(@as(?usize, 0), findBackward(&cells, 3, 'a', false));
    try std.testing.expectEqual(@as(?usize, 1), findBackward(&cells, 3, 'a', true));
    try std.testing.expectEqual(@as(?usize, null), findBackward(&cells, 0, 'a', false));
    // `t` repeated must not stall on the cell it already reached.
    const line = cellsFrom("a..b..c");
    try std.testing.expectEqual(@as(?usize, 2), findForward(&line, 0, 'b', true));
    try std.testing.expectEqual(@as(?usize, 5), findForward(&line, 2, 'c', true));
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
