//! Viewport anchoring for the editor — how "where am I scrolled to" is
//! expressed so that a frame costs O(viewport), never O(document).
//!
//! ## Why an anchor instead of a pixel
//!
//! The v1 renderer stored `scroll_y` in absolute pixels and walked
//! every line from 0 down to the viewport bottom, because with soft
//! wrap on you cannot know how tall line N is without laying it out.
//! Jumping to the end of a 200k-line file therefore laid out 200k
//! lines on the first frame.
//!
//! Scroll position is instead an ANCHOR: `(line, row, offset)` — the
//! logical line at the top of the viewport, which of that line's
//! wrapped rows is the first visible one, and how many pixels of that
//! row are scrolled off the top. Rendering starts AT the anchor, so a
//! frame only ever lays out the lines it draws.
//!
//! ## Scrollbar geometry (the estimate)
//!
//! A scrollbar still needs a document height, which soft wrap makes
//! unknowable without a full layout. `RowIndex` keeps a per-line
//! wrapped-row count, ESTIMATED at 1 row for lines never laid out and
//! REFINED (`note`) as the renderer touches them, in a Fenwick tree so
//! `rowsBefore` (anchor -> scrollbar value) and `anchorAtRow`
//! (scrollbar value -> anchor) are both O(log n).
//!
//! Because the position on the wire is the anchor and not a pixel,
//! refining an estimate moves the scrollbar THUMB but never the text:
//! the classic "the view jumps while you read" bug cannot occur.
//!
//! With soft wrap OFF every line is exactly one row, so the index is
//! not allocated at all and both conversions are pure arithmetic
//! (`enabled == false`).
//!
//! ## Folding
//!
//! A folded region hides lines, which changes the visual-row mapping
//! the anchor is expressed in. Rather than bolt a second correction
//! onto every conversion, a hidden line simply weighs ZERO rows in the
//! Fenwick tree: `counts` keeps the line's real (measured or
//! estimated) row count so unfolding restores it exactly, and `hidden`
//! decides whether that count is summed.
//!
//! Two consequences fall out for free and are relied on:
//! - `rowsBefore` / `anchorAtRow` / `totalRows` are already
//!   fold-correct; the scrollbar shrinks when you fold and no caller
//!   needs to know why.
//! - The Fenwick descent in `anchorAtRow` uses `<=`, so a run of
//!   zero-weight lines is walked THROUGH: converting a row index can
//!   never land on a hidden line.
//!
//! The index must therefore be allocated whenever folds exist, even
//! with soft wrap off (`enabled` is "wrap OR folds", decided by the
//! caller).

const std = @import("std");

/// First visible position: logical line, wrapped row within that line,
/// and pixels of that row scrolled above the viewport top.
pub const Anchor = struct {
    line: usize = 0,
    row: u32 = 0,
    /// 0 <= offset < line_height.
    offset: f32 = 0,
};

pub const RowIndex = struct {
    alloc: std.mem.Allocator,
    /// Soft wrap on. When false nothing is allocated and every line is
    /// one row.
    enabled: bool = false,
    /// Current row count per line (1 until `note` refines it). Kept
    /// even for hidden lines, so unfolding restores the exact estimate.
    counts: []u32 = &.{},
    /// Folded away — contributes 0 rows to the tree.
    hidden: []bool = &.{},
    /// Fenwick tree over the EFFECTIVE counts (0 for hidden), 1-based.
    bit: []u32 = &.{},
    /// Sum of the effective counts — the visible document height in
    /// rows.
    total: usize = 0,
    /// Lines whose count is measured rather than estimated (reporting).
    known: usize = 0,
    /// Hidden lines, for callers that want the count without a sweep.
    hidden_lines: usize = 0,

    pub fn init(alloc: std.mem.Allocator) RowIndex {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *RowIndex) void {
        self.free();
    }

    fn free(self: *RowIndex) void {
        if (self.counts.len > 0) self.alloc.free(self.counts);
        if (self.hidden.len > 0) self.alloc.free(self.hidden);
        if (self.bit.len > 0) self.alloc.free(self.bit);
        self.counts = &.{};
        self.hidden = &.{};
        self.bit = &.{};
        self.total = 0;
        self.known = 0;
        self.hidden_lines = 0;
    }

    /// (Re)build for `n_lines`, every line estimated at one row. Call
    /// on document change, wrap toggle, or wrap-width change.
    pub fn reset(self: *RowIndex, enabled: bool, n_lines: usize) void {
        self.free();
        self.enabled = enabled;
        if (!enabled or n_lines == 0) {
            self.total = n_lines;
            return;
        }
        self.counts = self.alloc.alloc(u32, n_lines) catch {
            // Out of memory: degrade to the arithmetic path rather
            // than lose the ability to scroll.
            self.enabled = false;
            self.total = n_lines;
            return;
        };
        self.hidden = self.alloc.alloc(bool, n_lines) catch {
            self.alloc.free(self.counts);
            self.counts = &.{};
            self.enabled = false;
            self.total = n_lines;
            return;
        };
        self.bit = self.alloc.alloc(u32, n_lines + 1) catch {
            self.alloc.free(self.counts);
            self.alloc.free(self.hidden);
            self.counts = &.{};
            self.hidden = &.{};
            self.enabled = false;
            self.total = n_lines;
            return;
        };
        @memset(self.counts, 1);
        @memset(self.hidden, false);
        // O(n) Fenwick build for the all-ones array.
        @memset(self.bit, 0);
        var i: usize = 1;
        while (i <= n_lines) : (i += 1) {
            self.bit[i] += 1;
            const j = i + (i & (~i +% 1));
            if (j <= n_lines) self.bit[j] += self.bit[i];
        }
        self.total = n_lines;
    }

    fn add(self: *RowIndex, line: usize, delta: i64) void {
        var i = line + 1;
        while (i < self.bit.len) : (i += i & (~i +% 1)) {
            self.bit[i] = @intCast(@as(i64, @intCast(self.bit[i])) + delta);
        }
    }

    /// Record a line's measured wrapped-row count. A hidden line still
    /// records it (so unfolding is exact) but does not move the tree.
    pub fn note(self: *RowIndex, line: usize, rows: u32) void {
        if (!self.enabled or line >= self.counts.len) return;
        const r = @max(1, rows);
        const old = self.counts[line];
        if (old == r) return;
        if (old == 1) self.known += 1;
        self.counts[line] = r;
        if (self.hidden[line]) return;
        self.add(line, @as(i64, r) - @as(i64, old));
        self.total = @intCast(@as(i64, @intCast(self.total)) + (@as(i64, r) - @as(i64, old)));
    }

    /// Fold/unfold one line. Idempotent.
    pub fn setHidden(self: *RowIndex, line: usize, h: bool) void {
        if (!self.enabled or line >= self.hidden.len) return;
        if (self.hidden[line] == h) return;
        self.hidden[line] = h;
        const rows: i64 = self.counts[line];
        const delta: i64 = if (h) -rows else rows;
        self.add(line, delta);
        self.total = @intCast(@as(i64, @intCast(self.total)) + delta);
        if (h) self.hidden_lines += 1 else self.hidden_lines -= 1;
    }

    pub fn isHidden(self: *const RowIndex, line: usize) bool {
        if (!self.enabled or line >= self.hidden.len) return false;
        return self.hidden[line];
    }

    /// Unfold everything (the caller re-applies the fold set).
    pub fn clearHidden(self: *RowIndex) void {
        if (self.hidden_lines == 0) return;
        var i: usize = 0;
        while (i < self.hidden.len) : (i += 1) self.setHidden(i, false);
    }

    /// EFFECTIVE rows of line `line`: 0 when folded away, 1 when
    /// unknown or wrap is off.
    pub fn rowsOf(self: *const RowIndex, line: usize) u32 {
        if (!self.enabled or line >= self.counts.len) return 1;
        if (self.hidden[line]) return 0;
        return self.counts[line];
    }

    /// Estimated total document height in rows.
    pub fn totalRows(self: *const RowIndex, n_lines: usize) usize {
        return if (self.enabled) self.total else n_lines;
    }

    /// Rows above line `line` (its global first row index).
    pub fn rowsBefore(self: *const RowIndex, line: usize) usize {
        if (!self.enabled) return line;
        var sum: usize = 0;
        var i = @min(line, self.counts.len);
        while (i > 0) : (i -= i & (~i +% 1)) sum += self.bit[i];
        return sum;
    }

    /// Global row index -> anchor (line + row within it). Clamped.
    pub fn anchorAtRow(self: *const RowIndex, n_lines: usize, row: usize) Anchor {
        if (n_lines == 0) return .{};
        if (!self.enabled) {
            const li = @min(row, n_lines - 1);
            return .{ .line = li, .row = 0 };
        }
        // Fenwick descent: largest prefix whose sum is <= row.
        var idx: usize = 0;
        var remaining = row;
        var step: usize = std.math.floorPowerOfTwo(usize, self.counts.len);
        while (step > 0) : (step >>= 1) {
            const next = idx + step;
            if (next < self.bit.len and self.bit[next] <= remaining) {
                idx = next;
                remaining -= self.bit[next];
            }
        }
        // Trailing hidden lines (a fold running to the end of the
        // document) can leave the descent past the last VISIBLE line;
        // walk back to one that carries rows.
        if (idx >= n_lines) idx = n_lines - 1;
        while (idx > 0 and self.rowsOf(idx) == 0) idx -= 1;
        const rows = self.rowsOf(idx);
        if (rows == 0) return .{ .line = idx, .row = 0 };
        return .{ .line = idx, .row = @intCast(@min(remaining, rows - 1)) };
    }
};

/// Global row index of an anchor.
pub fn anchorRow(index: *const RowIndex, a: Anchor) usize {
    return index.rowsBefore(a.line) + a.row;
}

// ======================================================================
// Tests
// ======================================================================

const testing = std.testing;

test "viewport: wrap off is pure arithmetic and allocates nothing" {
    var idx = RowIndex.init(testing.allocator);
    defer idx.deinit();
    idx.reset(false, 200_000);
    try testing.expectEqual(@as(usize, 0), idx.counts.len);
    try testing.expectEqual(@as(usize, 200_000), idx.totalRows(200_000));
    try testing.expectEqual(@as(usize, 12345), idx.rowsBefore(12345));
    const a = idx.anchorAtRow(200_000, 12345);
    try testing.expectEqual(@as(usize, 12345), a.line);
    try testing.expectEqual(@as(u32, 0), a.row);
}

test "viewport: wrap on estimates 1 row and refines" {
    var idx = RowIndex.init(testing.allocator);
    defer idx.deinit();
    idx.reset(true, 10);
    try testing.expectEqual(@as(usize, 10), idx.totalRows(10));
    try testing.expectEqual(@as(usize, 3), idx.rowsBefore(3));

    idx.note(2, 4); // line 2 wraps to 4 rows
    try testing.expectEqual(@as(usize, 13), idx.totalRows(10));
    try testing.expectEqual(@as(usize, 2), idx.rowsBefore(2));
    try testing.expectEqual(@as(usize, 6), idx.rowsBefore(3));
    try testing.expectEqual(@as(usize, 1), idx.known);

    // Row 4 is the third row of line 2.
    const a = idx.anchorAtRow(10, 4);
    try testing.expectEqual(@as(usize, 2), a.line);
    try testing.expectEqual(@as(u32, 2), a.row);
    // Round-trip.
    try testing.expectEqual(@as(usize, 4), anchorRow(&idx, a));

    // Refining down works too.
    idx.note(2, 1);
    try testing.expectEqual(@as(usize, 10), idx.totalRows(10));
    try testing.expectEqual(@as(usize, 3), idx.rowsBefore(3));
}

test "viewport: hidden lines weigh zero rows and unfold exactly" {
    var idx = RowIndex.init(testing.allocator);
    defer idx.deinit();
    // Folds force the index on even with wrap off.
    idx.reset(true, 10);
    idx.note(2, 3); // line 2 is 3 rows tall
    try testing.expectEqual(@as(usize, 12), idx.totalRows(10));

    // Fold lines 2..4 away (3 + 1 + 1 rows).
    idx.setHidden(2, true);
    idx.setHidden(3, true);
    idx.setHidden(4, true);
    try testing.expectEqual(@as(usize, 7), idx.totalRows(10));
    try testing.expectEqual(@as(usize, 3), idx.hidden_lines);
    try testing.expectEqual(@as(u32, 0), idx.rowsOf(2));
    try testing.expectEqual(@as(usize, 2), idx.rowsBefore(2));
    try testing.expectEqual(@as(usize, 2), idx.rowsBefore(5));

    // A row index inside the folded run resolves to the first VISIBLE
    // line after it, never to a hidden one.
    const a = idx.anchorAtRow(10, 2);
    try testing.expectEqual(@as(usize, 5), a.line);
    try testing.expectEqual(@as(u32, 0), a.row);
    try testing.expectEqual(@as(usize, 2), anchorRow(&idx, a));

    // Measuring a hidden line still records it for later.
    idx.note(3, 4);
    try testing.expectEqual(@as(usize, 7), idx.totalRows(10));
    idx.setHidden(3, false);
    try testing.expectEqual(@as(usize, 11), idx.totalRows(10));

    idx.clearHidden();
    try testing.expectEqual(@as(usize, 0), idx.hidden_lines);
    try testing.expectEqual(@as(usize, 15), idx.totalRows(10));
}

test "viewport: a fold running to the end of the document clamps back" {
    var idx = RowIndex.init(testing.allocator);
    defer idx.deinit();
    idx.reset(true, 6);
    var i: usize = 2;
    while (i < 6) : (i += 1) idx.setHidden(i, true);
    try testing.expectEqual(@as(usize, 2), idx.totalRows(6));
    const a = idx.anchorAtRow(6, 5);
    try testing.expect(!idx.isHidden(a.line));
    try testing.expectEqual(@as(usize, 1), a.line);
}

test "viewport: anchorAtRow round-trips across a large refined index" {
    var idx = RowIndex.init(testing.allocator);
    defer idx.deinit();
    const n = 5000;
    idx.reset(true, n);
    var i: usize = 0;
    while (i < n) : (i += 7) idx.note(i, @intCast(2 + (i % 5)));

    var row: usize = 0;
    while (row < idx.totalRows(n)) : (row += 97) {
        const a = idx.anchorAtRow(n, row);
        try testing.expectEqual(row, anchorRow(&idx, a));
        try testing.expect(a.row < idx.rowsOf(a.line));
    }
    // Past the end clamps to the last row of the last line.
    const last = idx.anchorAtRow(n, idx.totalRows(n) + 50);
    try testing.expectEqual(@as(usize, n - 1), last.line);
}
