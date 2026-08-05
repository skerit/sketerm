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
    /// UTF-16 code-unit offset of each character; len == n_chars + 1 (last =
    /// total UTF-16 length). AT-SPI ignores this and works in codepoints;
    /// the macOS NSAccessibility bridge needs it because NSRange is in
    /// UTF-16 units (astral chars — emoji — count as 2; BMP, incl. Nerd-font
    /// glyphs, as 1). Pure arithmetic, so it stays in the neutral core.
    char_to_utf16: []u32,
    /// Selection as a character range [sel_start, sel_end), when the
    /// screen has one that maps to a CONTIGUOUS run of this text
    /// (`.normal` / `.line_select`). `.rectangular` stays null: a block
    /// is not a flat range, and reporting one would hand a screen
    /// reader the wrong text. Null also when the selection lies fully
    /// in scrollback (this snapshot is the visible screen only).
    sel_start: ?u32 = null,
    sel_end: ?u32 = null,

    pub fn deinit(self: *Snapshot) void {
        self.allocator.free(self.text);
        self.allocator.free(self.line_starts);
        self.allocator.free(self.char_to_byte);
        self.allocator.free(self.char_to_utf16);
    }

    /// UTF-16 code-unit offset of character `c` (clamped). For mapping the
    /// codepoint offsets used here onto NSRange on macOS.
    pub fn utf16At(self: *const Snapshot, c: u32) u32 {
        return self.char_to_utf16[@min(c, self.n_chars)];
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
    var c2u16: std.ArrayList(u32) = .empty;
    errdefer c2u16.deinit(allocator);

    const nrows: usize = screen.rows;
    var line_starts = try allocator.alloc(u32, nrows);
    errdefer allocator.free(line_starts);

    var n_chars: u32 = 0;
    var n_utf16: u32 = 0;
    var caret: u32 = 0;

    // Grid-space selection endpoints, normalized. `.normal` ends are
    // (row, col) with the end column EXCLUSIVE (matching
    // `Selection.contains`); `.line_select` spans whole rows, expressed
    // as [start of top row, start of the row after bot). Rectangular
    // selections don't map to one flat range and stay unexposed.
    const SelPt = struct { row: i64, col: i64 };
    var sel_a: ?SelPt = null;
    var sel_b: ?SelPt = null;
    if (screen.selection.rect()) |sr| switch (screen.selection.mode) {
        .normal => {
            sel_a = .{ .row = sr.top_row, .col = sr.top_col };
            sel_b = .{ .row = sr.bot_row, .col = sr.bot_col };
        },
        .line_select => {
            sel_a = .{ .row = sr.top_row, .col = 0 };
            sel_b = .{ .row = @as(i64, sr.bot_row) + 1, .col = 0 };
        },
        else => {},
    };
    // A selection entirely above (scrollback) or below the visible
    // grid has no text here to point at.
    if (sel_a != null and (sel_b.?.row < 0 or sel_a.?.row >= @as(i64, @intCast(nrows)))) {
        sel_a = null;
        sel_b = null;
    }
    var sel_start_off: ?u32 = if (sel_a != null and sel_a.?.row < 0) 0 else null;
    var sel_end_off: ?u32 = null;

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
        var sel_a_in_row: ?u32 = null;
        var sel_b_in_row: ?u32 = null;
        const is_sel_a_row = sel_a != null and sel_a.?.row == @as(i64, @intCast(r));
        const is_sel_b_row = sel_b != null and sel_b.?.row == @as(i64, @intCast(r));
        var row_chars: u32 = 0;
        var ci: usize = 0;
        while (ci < cells.len) : (ci += 1) {
            if (is_cursor_row and ci == screen.col) cursor_char_in_row = row_chars;
            if (is_sel_a_row and @as(i64, @intCast(ci)) == sel_a.?.col) sel_a_in_row = row_chars;
            if (is_sel_b_row and @as(i64, @intCast(ci)) == sel_b.?.col) sel_b_in_row = row_chars;
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
            try c2u16.append(allocator, n_utf16);
            try text.appendSlice(allocator, enc[0..n]);
            n_chars += 1;
            n_utf16 += if (cp >= 0x10000) 2 else 1; // surrogate pair for astral
            row_chars += 1;
        }

        if (is_cursor_row) {
            // Cursor in trailing blanks (or past EOL) clamps to line end.
            caret = line_starts[r] + (cursor_char_in_row orelse row_chars);
        }
        // Selection ends in trailing blanks clamp to line end too (the
        // blanks were trimmed from the text).
        if (is_sel_a_row) sel_start_off = line_starts[r] + (sel_a_in_row orelse row_chars);
        if (is_sel_b_row) sel_end_off = line_starts[r] + (sel_b_in_row orelse row_chars);

        // Newline between rows (not after the last row).
        if (r + 1 < nrows) {
            try c2b.append(allocator, @intCast(text.items.len));
            try c2u16.append(allocator, n_utf16);
            try text.append(allocator, '\n');
            n_chars += 1;
            n_utf16 += 1;
        }
    }

    // Sentinel: index n_chars holds the end (text length / total UTF-16 len),
    // so a range ending at the last char (or an end-of-text caret) is defined.
    try c2b.append(allocator, @intCast(text.items.len));
    try c2u16.append(allocator, n_utf16);

    // A selection whose end row sits below the visible grid (or whose
    // end fell on the never-walked row nrows) clamps to end-of-text.
    var sel_s: ?u32 = null;
    var sel_e: ?u32 = null;
    if (sel_a != null) {
        const s = sel_start_off orelse 0;
        const e = sel_end_off orelse n_chars;
        if (e > s) {
            sel_s = s;
            sel_e = e;
        }
    }

    return .{
        .allocator = allocator,
        .text = try text.toOwnedSlice(allocator),
        .n_chars = n_chars,
        .caret = @min(caret, n_chars),
        .line_starts = line_starts,
        .char_to_byte = try c2b.toOwnedSlice(allocator),
        .char_to_utf16 = try c2u16.toOwnedSlice(allocator),
        .sel_start = sel_s,
        .sel_end = sel_e,
    };
}

/// A single contiguous change between two texts, as character ranges:
/// [del_start, del_end) was removed from `old`, [ins_start, ins_end)
/// was inserted into `new` (del_start == ins_start). Null when equal.
/// This is what AT-SPI text-changed notifications want — a terminal
/// redraw rarely IS one contiguous edit, but the common prefix/suffix
/// hull is the tightest single range that covers it, and it keeps a
/// full-screen rewrite from being announced as "everything deleted,
/// everything inserted".
pub const Change = struct {
    del_start: u32,
    del_end: u32,
    ins_start: u32,
    ins_end: u32,
};

/// Common-prefix/suffix diff of two UTF-8 texts, in character offsets.
pub fn diffChars(old: []const u8, new: []const u8) ?Change {
    if (std.mem.eql(u8, old, new)) return null;
    // Byte-wise common prefix, backed off to a codepoint boundary.
    var p: usize = 0;
    const pmax = @min(old.len, new.len);
    while (p < pmax and old[p] == new[p]) p += 1;
    while (p > 0 and (old[p] & 0xC0) == 0x80) p -= 1;
    // Byte-wise common suffix over the remainder, on boundaries.
    var s: usize = 0;
    const smax = @min(old.len, new.len) - p;
    while (s < smax and old[old.len - 1 - s] == new[new.len - 1 - s]) s += 1;
    while (s > 0 and (old[old.len - s] & 0xC0) == 0x80) s -= 1;

    const prefix_chars: u32 = @intCast(std.unicode.utf8CountCodepoints(old[0..p]) catch 0);
    const old_mid: u32 = @intCast(std.unicode.utf8CountCodepoints(old[p .. old.len - s]) catch 0);
    const new_mid: u32 = @intCast(std.unicode.utf8CountCodepoints(new[p .. new.len - s]) catch 0);
    return .{
        .del_start = prefix_chars,
        .del_end = prefix_chars + old_mid,
        .ins_start = prefix_chars,
        .ins_end = prefix_chars + new_mid,
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

test "snapshot: normal selection maps to a char range" {
    const testing = std.testing;
    var pool = try Pool.init(testing.allocator);
    defer pool.deinit();
    const screen = try Screen.init(testing.allocator, &pool, 10, 3);
    defer screen.deinit();

    feed(screen, "hi there\r\n");
    feed(screen, "ab");

    // Select "there" on row 0: cols [3, 8) (end col exclusive).
    screen.selection.start(0, 3, .normal);
    screen.selection.extend(0, 8);

    var snap = try build(screen, testing.allocator);
    defer snap.deinit();
    try testing.expectEqualStrings("there", snap.byteRange(snap.sel_start.?, snap.sel_end.?));

    // Multi-row: from row 0 col 3 through row 1 col 1 — spans the newline.
    screen.selection.start(0, 3, .normal);
    screen.selection.extend(1, 1);
    var snap2 = try build(screen, testing.allocator);
    defer snap2.deinit();
    try testing.expectEqualStrings("there\na", snap2.byteRange(snap2.sel_start.?, snap2.sel_end.?));
}

test "snapshot: line selection spans whole rows incl. newline" {
    const testing = std.testing;
    var pool = try Pool.init(testing.allocator);
    defer pool.deinit();
    const screen = try Screen.init(testing.allocator, &pool, 10, 3);
    defer screen.deinit();
    feed(screen, "one\r\n");
    feed(screen, "two");
    screen.selection.start(0, 0, .line_select);
    screen.selection.extend(0, 0);
    var snap = try build(screen, testing.allocator);
    defer snap.deinit();
    try testing.expectEqualStrings("one\n", snap.byteRange(snap.sel_start.?, snap.sel_end.?));
}

test "snapshot: rectangular and scrollback-only selections stay null" {
    const testing = std.testing;
    var pool = try Pool.init(testing.allocator);
    defer pool.deinit();
    const screen = try Screen.init(testing.allocator, &pool, 10, 3);
    defer screen.deinit();
    feed(screen, "hi there");

    screen.selection.start(0, 1, .rectangular);
    screen.selection.extend(1, 3);
    var snap = try build(screen, testing.allocator);
    defer snap.deinit();
    try testing.expect(snap.sel_start == null);

    // Fully in scrollback (negative rows): nothing visible to select.
    screen.selection.start(-5, 0, .normal);
    screen.selection.extend(-2, 4);
    var snap2 = try build(screen, testing.allocator);
    defer snap2.deinit();
    try testing.expect(snap2.sel_start == null);

    // Straddling scrollback into row 0 clamps to text start.
    screen.selection.start(-2, 4, .normal);
    screen.selection.extend(0, 2);
    var snap3 = try build(screen, testing.allocator);
    defer snap3.deinit();
    try testing.expectEqual(@as(u32, 0), snap3.sel_start.?);
    try testing.expectEqualStrings("hi", snap3.byteRange(snap3.sel_start.?, snap3.sel_end.?));
}

test "diffChars: prefix/suffix hull in codepoints" {
    const testing = std.testing;
    try testing.expect(diffChars("abc", "abc") == null);

    // Pure insert at the end (typing).
    const ins = diffChars("$ ab", "$ abc").?;
    try testing.expectEqual(@as(u32, 4), ins.del_start);
    try testing.expectEqual(@as(u32, 4), ins.del_end);
    try testing.expectEqual(@as(u32, 5), ins.ins_end);

    // Replacement in the middle, multibyte-safe: "é" is 1 char.
    const rep = diffChars("a\xc3\xa9b", "a\xc3\xa8b").?; // aéb -> aèb
    try testing.expectEqual(@as(u32, 1), rep.del_start);
    try testing.expectEqual(@as(u32, 2), rep.del_end);
    try testing.expectEqual(@as(u32, 2), rep.ins_end);

    // Delete-only.
    const del = diffChars("abcd", "ad").?;
    try testing.expectEqual(@as(u32, 1), del.del_start);
    try testing.expectEqual(@as(u32, 3), del.del_end);
    try testing.expectEqual(@as(u32, 1), del.ins_end);
}

test "snapshot: UTF-16 offsets count astral chars as surrogate pairs" {
    const testing = std.testing;
    var pool = try Pool.init(testing.allocator);
    defer pool.deinit();
    const screen = try Screen.init(testing.allocator, &pool, 6, 1);
    defer screen.deinit();

    // "a😀b": BMP 'a' = 1 unit, U+1F600 = 2 units (surrogate pair), 'b' = 1.
    screen.apply(.{ .print = 'a' });
    screen.apply(.{ .print = 0x1F600 });
    screen.apply(.{ .print = 'b' });

    var snap = try build(screen, testing.allocator);
    defer snap.deinit();

    // 3 codepoints; char_to_utf16 maps each char's UTF-16 start offset.
    try testing.expectEqual(@as(u32, 3), snap.n_chars);
    try testing.expectEqual(@as(u32, 0), snap.utf16At(0)); // 'a'
    try testing.expectEqual(@as(u32, 1), snap.utf16At(1)); // emoji starts at 1
    try testing.expectEqual(@as(u32, 3), snap.utf16At(2)); // 'b' after the pair
    try testing.expectEqual(@as(u32, 4), snap.utf16At(3)); // total UTF-16 length
}
