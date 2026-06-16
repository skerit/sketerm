//! Platform-neutral accessibility view of a terminal screen.
//!
//! Turns the authoritative `Screen` cell grid into the flat text + caret +
//! line model that every platform accessibility API speaks (AT-SPI on Linux
//! via `GtkAccessibleText`, NSAccessibility on macOS later). No GTK, no
//! platform types here on purpose: this is the shared core, and the
//! per-platform bridge is a thin adapter over `Snapshot`.
//!
//! Offsets are in CHARACTERS (Unicode codepoints), matching what AT-SPI /
//! GtkAccessibleText expect; `byteRange` converts a character span back to
//! the UTF-8 bytes for the actual contents.

const std = @import("std");
const Screen = @import("../grid/screen.zig").Screen;
const Cell = @import("../grid/cell.zig").Cell;

/// Cell flag bits (mirrors the grid's `Cell.flags`).
const FLAG_WIDE: u8 = 0b0000_0001;
const FLAG_WIDE_CONT: u8 = 0b0000_0010;

pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    /// Visible screen as UTF-8, rows joined by '\n', trailing blanks trimmed.
    text: []u8,
    /// Total codepoints (newlines included).
    n_chars: u32,
    /// Character offset of the cursor.
    caret: u32,
    /// Character offset where each visible row begins (len == row count).
    line_starts: []u32,
    /// Byte offset of each character; len == n_chars + 1 (last = text.len).
    char_to_byte: []u32,

    pub fn deinit(self: *Snapshot) void {
        self.allocator.free(self.text);
        self.allocator.free(self.line_starts);
        self.allocator.free(self.char_to_byte);
    }

    /// UTF-8 bytes for the character range [c0, c1), clamped.
    pub fn byteRange(self: *const Snapshot, c0: u32, c1: u32) []const u8 {
        const a = self.char_to_byte[@min(c0, self.n_chars)];
        const b = self.char_to_byte[@min(@max(c1, c0), self.n_chars)];
        return self.text[a..b];
    }

    /// Character range of the line containing `offset`, INCLUDING its
    /// trailing newline (AT-SPI line convention). Returns [start, end).
    pub fn lineRange(self: *const Snapshot, offset: u32) struct { start: u32, end: u32 } {
        const off = @min(offset, self.n_chars);
        var i: usize = self.line_starts.len;
        while (i > 0) {
            i -= 1;
            if (self.line_starts[i] <= off) {
                const start = self.line_starts[i];
                const end = if (i + 1 < self.line_starts.len) self.line_starts[i + 1] else self.n_chars;
                return .{ .start = start, .end = end };
            }
        }
        return .{ .start = 0, .end = self.n_chars };
    }

    /// Character range of the word containing `offset` (whitespace- and
    /// newline-delimited). Used for WORD granularity.
    pub fn wordRange(self: *const Snapshot, offset: u32) struct { start: u32, end: u32 } {
        if (self.n_chars == 0) return .{ .start = 0, .end = 0 };
        const off = @min(offset, self.n_chars - 1);
        if (isWordBoundary(self.charAt(off))) {
            // On a separator: return just that single character.
            return .{ .start = off, .end = off + 1 };
        }
        var s = off;
        while (s > 0 and !isWordBoundary(self.charAt(s - 1))) s -= 1;
        var e = off + 1;
        while (e < self.n_chars and !isWordBoundary(self.charAt(e))) e += 1;
        return .{ .start = s, .end = e };
    }

    /// The codepoint at character offset `i` (for boundary tests).
    fn charAt(self: *const Snapshot, i: u32) u21 {
        const a = self.char_to_byte[i];
        return std.unicode.utf8Decode(self.text[a..self.char_to_byte[i + 1]]) catch ' ';
    }
};

fn isWordBoundary(cp: u21) bool {
    return cp == ' ' or cp == '\n' or cp == '\t';
}

/// Build a snapshot of the screen's visible (active-buffer) rows + cursor.
pub fn build(screen: *const Screen, allocator: std.mem.Allocator) !Snapshot {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(allocator);
    var c2b: std.ArrayList(u32) = .empty;
    errdefer c2b.deinit(allocator);

    const nrows: usize = screen.rows;
    var line_starts = try allocator.alloc(u32, nrows);
    errdefer allocator.free(line_starts);

    var n_chars: u32 = 0;
    var caret: u32 = 0;

    var r: usize = 0;
    while (r < nrows) : (r += 1) {
        line_starts[r] = n_chars;
        const is_cursor_row = r == screen.row;
        const cells = screen.lineCellsAtPub(@intCast(r)) orelse &[_]Cell{};

        // Last non-blank column, so trailing blanks are trimmed (a screen
        // reader shouldn't recite a row of spaces).
        var last_nonblank: i64 = -1;
        for (cells, 0..) |cell, ci| {
            if (cell.flags & FLAG_WIDE_CONT != 0) continue;
            const cp: u32 = if (cell.rune == 0) ' ' else cell.rune;
            if (cp != ' ') last_nonblank = @intCast(ci);
        }

        var cursor_char_in_row: ?u32 = null;
        var row_chars: u32 = 0;
        var ci: usize = 0;
        while (ci < cells.len) : (ci += 1) {
            if (is_cursor_row and ci == screen.col) cursor_char_in_row = row_chars;
            const cell = cells[ci];
            if (cell.flags & FLAG_WIDE_CONT != 0) continue;
            if (@as(i64, @intCast(ci)) > last_nonblank) break; // trim trailing blanks
            const cp: u32 = if (cell.rune == 0) ' ' else cell.rune;
            var enc: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(@intCast(cp), &enc) catch blk: {
                enc[0] = ' ';
                break :blk 1;
            };
            try c2b.append(allocator, @intCast(text.items.len));
            try text.appendSlice(allocator, enc[0..n]);
            n_chars += 1;
            row_chars += 1;
        }

        if (is_cursor_row) {
            // Cursor in trailing blanks (or past EOL) clamps to line end.
            caret = line_starts[r] + (cursor_char_in_row orelse row_chars);
        }

        // Newline between rows (not after the last row).
        if (r + 1 < nrows) {
            try c2b.append(allocator, @intCast(text.items.len));
            try text.append(allocator, '\n');
            n_chars += 1;
        }
    }

    // Sentinel: char_to_byte[n_chars] == text length, so byteRange of the
    // final char (and an end-of-text caret) is well-defined.
    try c2b.append(allocator, @intCast(text.items.len));

    return .{
        .allocator = allocator,
        .text = try text.toOwnedSlice(allocator),
        .n_chars = n_chars,
        .caret = @min(caret, n_chars),
        .line_starts = line_starts,
        .char_to_byte = try c2b.toOwnedSlice(allocator),
    };
}

// ── tests ────────────────────────────────────────────────────────────

const Pool = @import("../grid/style_pool.zig").Pool;

fn feed(screen: *Screen, s: []const u8) void {
    for (s) |ch| switch (ch) {
        '\r', '\n' => screen.apply(.{ .execute = ch }),
        else => screen.apply(.{ .print = ch }),
    };
}

test "snapshot: text, caret, and line/word ranges" {
    const testing = std.testing;
    var pool = try Pool.init(testing.allocator);
    defer pool.deinit();
    const screen = try Screen.init(testing.allocator, &pool, 10, 3);
    defer screen.deinit();

    feed(screen, "hi there\r\n");
    feed(screen, "ab"); // cursor parked after "ab" on row 1

    var snap = try build(screen, testing.allocator);
    defer snap.deinit();

    // Three rows -> three line starts; trailing blanks trimmed.
    try testing.expectEqual(@as(usize, 3), snap.line_starts.len);
    try testing.expectEqualStrings("hi there\nab\n", snap.text);

    // Caret sits after "ab" on row 1: "hi there\n" = 9 chars, + "ab" = 11.
    try testing.expectEqual(@as(u32, 11), snap.caret);

    // Line containing the caret is "ab\n".
    const lr = snap.lineRange(snap.caret);
    try testing.expectEqualStrings("ab\n", snap.byteRange(lr.start, lr.end));

    // Word at offset 3 ("there") spans the whole word.
    const wr = snap.wordRange(3);
    try testing.expectEqualStrings("there", snap.byteRange(wr.start, wr.end));
}

test "snapshot: empty screen is well-formed" {
    const testing = std.testing;
    var pool = try Pool.init(testing.allocator);
    defer pool.deinit();
    const screen = try Screen.init(testing.allocator, &pool, 5, 2);
    defer screen.deinit();
    var snap = try build(screen, testing.allocator);
    defer snap.deinit();
    try testing.expectEqual(@as(u32, 0), snap.caret);
    // Two blank rows -> a single newline between them, nothing else.
    try testing.expectEqualStrings("\n", snap.text);
    try testing.expectEqual(@as(u32, @intCast(snap.text.len)), snap.char_to_byte[snap.n_chars]);
}
