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
    /// Current row count per line (1 until `note` refines it).
    counts: []u32 = &.{},
    /// Fenwick tree over `counts`, 1-based.
    bit: []u32 = &.{},
    /// Sum of `counts` — the estimated document height in rows.
    total: usize = 0,
    /// Lines whose count is measured rather than estimated (reporting).
    known: usize = 0,

    pub fn init(alloc: std.mem.Allocator) RowIndex {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *RowIndex) void {
        self.free();
    }

    fn free(self: *RowIndex) void {
        if (self.counts.len > 0) self.alloc.free(self.counts);
        if (self.bit.len > 0) self.alloc.free(self.bit);
        self.counts = &.{};
        self.bit = &.{};
        self.total = 0;
        self.known = 0;
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
        self.bit = self.alloc.alloc(u32, n_lines + 1) catch {
            self.alloc.free(self.counts);
            self.counts = &.{};
            self.enabled = false;
            self.total = n_lines;
            return;
        };
        @memset(self.counts, 1);
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

    /// Record a line's measured wrapped-row count.
    pub fn note(self: *RowIndex, line: usize, rows: u32) void {
        if (!self.enabled or line >= self.counts.len) return;
        const r = @max(1, rows);
        const old = self.counts[line];
        if (old == r) return;
        if (old == 1) self.known += 1;
        self.counts[line] = r;
        self.add(line, @as(i64, r) - @as(i64, old));
        self.total = @intCast(@as(i64, @intCast(self.total)) + (@as(i64, r) - @as(i64, old)));
    }

    /// Rows of line `line` (1 when unknown or wrap is off).
    pub fn rowsOf(self: *const RowIndex, line: usize) u32 {
        if (!self.enabled or line >= self.counts.len) return 1;
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
        if (idx >= n_lines) return .{ .line = n_lines - 1, .row = self.rowsOf(n_lines - 1) - 1 };
        return .{ .line = idx, .row = @intCast(@min(remaining, self.rowsOf(idx) - 1)) };
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
