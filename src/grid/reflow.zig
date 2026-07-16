//! Soft-wrap reflow on resize.
//!
//! When the user resizes the window such that columns change, we
//! rebuild the active screen + scrollback so soft-wrapped lines
//! re-flow at the new width: widening rejoins multi-row paragraphs,
//! narrowing splits long lines.
//!
//! Rules:
//!   1. Alt screen never reflows. Apps that use it (vim, less, htop)
//!      handle their own redraw on SIGWINCH.
//!   2. A "logical line" is the maximal run of rows where row 0 has
//!      `continues_above == false` and rows 1..N have `continues_above
//!      == true`. The line's content is the concatenation of all
//!      cells in those rows; trailing blanks at the end of the last
//!      row are content (not padding) only if `continues_above` on
//!      the row that would have followed is true. Otherwise we trim.
//!   3. Re-chunking: split each logical line into pieces of at most
//!      `new_cols` cells. The first piece has `continues_above=false`,
//!      every subsequent piece has `true`.
//!   4. Cursor: track its (logical_idx, col_in_logical) before reflow,
//!      compute its new (row, col) after.
//!
//! Limitations vs. kitty/wezterm:
//!   - We treat every cell width as 1 for trimming purposes (wide-
//!     char continuation cells contribute their physical width).
//!   - No grapheme-cluster-aware reflow.

const std = @import("std");
const Cell = @import("cell.zig").Cell;
const Line = @import("line.zig").Line;

pub const Logical = struct {
    /// Concatenated cells from all rows in this logical line.
    cells: std.ArrayList(Cell) = .empty,
    /// True if the LAST row of this logical line has `continues_above`
    /// = true on the row that would have followed it (i.e. the line
    /// was filled to capacity). When false, the last row's trailing
    /// blanks are padding.
    fully_filled: bool = false,
};

/// Build the list of logical lines from a sequence of rows, in order.
/// `last_continues` is true if the row AFTER the last row has
/// `continues_above` = true (used to know whether to trim the trailing
/// blanks of the last logical line).
pub fn build(
    allocator: std.mem.Allocator,
    rows: []const Line,
    initial_continues: bool,
) !std.ArrayList(Logical) {
    var out: std.ArrayList(Logical) = .empty;
    errdefer {
        for (out.items) |*ll| ll.cells.deinit(allocator);
        out.deinit(allocator);
    }
    if (rows.len == 0) return out;

    // Decide whether each row continues from the previous. The very
    // first row's `continues_above` is intrinsic (set by the
    // autowrap path); but if `initial_continues` is set we treat it
    // as a continuation of an implicit prior line — meaning we'd
    // need to extend that line, but since we're starting fresh, just
    // honor the row's own flag.
    _ = initial_continues;

    for (rows) |row| {
        const want_new = !row.continues_above or out.items.len == 0;
        if (want_new) {
            try out.append(allocator, .{});
        }
        const ll = &out.items[out.items.len - 1];
        try ll.cells.appendSlice(allocator, row.cells);
    }

    // Set `fully_filled` per logical line: a line is filled if the
    // row immediately after its last component had continues_above
    // = true. We can detect that by looking at whether the LAST row
    // of this logical line was filled to capacity — equivalent to
    // the next row in the original buffer (if any) being a
    // continuation. We don't have access to that "next row" here
    // since we consumed it; instead, mark filled if the count of
    // rows in this logical line is > 1 (since the only way to have
    // multiple rows is via autowrap, i.e. all-but-the-last were
    // filled). The very last row's filled-ness is unknowable from
    // this side; trim by trailing-blank heuristic instead.
    return out;
}

/// Trim trailing blank cells from each logical line. Then drop any
/// TRAILING fully-empty logical lines — those represent the bottom-
/// of-active blank padding, not content. Without this, narrowing
/// pushes real content into scrollback as the empty logicals consume
/// active rows.
pub fn trim(logicals: *std.ArrayList(Logical), allocator: std.mem.Allocator) void {
    for (logicals.items) |*ll| {
        var hi = ll.cells.items.len;
        while (hi > 0 and ll.cells.items[hi - 1].rune == 0) hi -= 1;
        ll.cells.shrinkRetainingCapacity(hi);
    }
    // Drop trailing empty logical lines.
    while (logicals.items.len > 0 and
        logicals.items[logicals.items.len - 1].cells.items.len == 0)
    {
        var ll = logicals.pop().?;
        ll.cells.deinit(allocator);
    }
}

/// Re-chunk into rows of `new_cols`. Returns a freshly-allocated
/// slice of Line; caller owns. The `continues_above` flag is
/// false on the first chunk of each logical line and true thereafter.
pub fn rechunk(
    allocator: std.mem.Allocator,
    logicals: []const Logical,
    new_cols: u16,
) ![]Line {
    var rows: std.ArrayList(Line) = .empty;
    errdefer {
        for (rows.items) |*r| r.deinit(allocator);
        rows.deinit(allocator);
    }

    for (logicals) |ll| {
        if (ll.cells.items.len == 0) {
            // Empty logical line → one empty row.
            const cells = try allocator.alloc(Cell, new_cols);
            @memset(cells, .{});
            try rows.append(allocator, .{ .cells = cells, .continues_above = false, .dirty = true });
            continue;
        }
        var i: usize = 0;
        var first = true;
        while (i < ll.cells.items.len) {
            const remaining = ll.cells.items.len - i;
            const take = @min(remaining, @as(usize, new_cols));
            const cells = try allocator.alloc(Cell, new_cols);
            @memcpy(cells[0..take], ll.cells.items[i .. i + take]);
            if (take < new_cols) @memset(cells[take..], .{});
            try rows.append(allocator, .{
                .cells = cells,
                .continues_above = !first,
                .dirty = true,
            });
            i += take;
            first = false;
        }
    }

    return try rows.toOwnedSlice(allocator);
}

/// Compute the (logical_index, col_within_logical) of a position
/// (row, col) in the original buffer.
pub fn positionInLogicals(rows: []const Line, row: u16, col: u16) struct { idx: usize, col: u32 } {
    var idx: usize = 0;
    var col_in: u32 = 0;
    var r: u16 = 0;
    while (r <= row and r < rows.len) : (r += 1) {
        if (r > 0 and !rows[r].continues_above) {
            idx += 1;
            col_in = 0;
        }
        if (r == row) {
            col_in += col;
            break;
        } else {
            col_in += @intCast(rows[r].cells.len);
        }
    }
    return .{ .idx = idx, .col = col_in };
}

/// Inverse: given (logical_idx, col_in_logical), find which post-
/// rechunk row + col it lands at.
pub fn positionAfterRechunk(
    rechunked: []const Line,
    target_idx: usize,
    target_col: u32,
    new_cols: u16,
) struct { row: usize, col: u16 } {
    // Walk the rechunked rows, tracking which logical index we're in.
    var idx: usize = 0;
    var col_acc: u32 = 0;
    var r: usize = 0;
    while (r < rechunked.len) : (r += 1) {
        if (r > 0 and !rechunked[r].continues_above) {
            idx += 1;
            col_acc = 0;
        }
        if (idx == target_idx) {
            const row_end = col_acc + new_cols;
            if (target_col >= col_acc and target_col < row_end) {
                return .{ .row = r, .col = @intCast(target_col - col_acc) };
            }
            // The target_col might fall past the last chunk of this
            // logical line — clamp to the last cell of the last chunk.
        } else if (idx > target_idx) {
            return .{ .row = r - 1, .col = new_cols - 1 };
        }
        col_acc += new_cols;
    }
    // Fell off the end — clamp to last row.
    if (rechunked.len == 0) return .{ .row = 0, .col = 0 };
    return .{ .row = rechunked.len - 1, .col = @intCast(@min(new_cols - 1, target_col)) };
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

fn makeRow(allocator: std.mem.Allocator, text: []const u8, cols: u16, continues: bool) !Line {
    const cells = try allocator.alloc(Cell, cols);
    @memset(cells, .{});
    for (text, 0..) |b, i| {
        if (i >= cols) break;
        cells[i] = .{ .rune = b };
    }
    return .{ .cells = cells, .continues_above = continues, .dirty = true };
}

test "build groups continuations into logical lines" {
    const a = testing.allocator;
    var rows = [_]Line{
        try makeRow(a, "hello", 5, false),
        try makeRow(a, "world", 5, true), // soft-wrap continuation
        try makeRow(a, "next", 5, false),
    };
    defer for (&rows) |*r| r.deinit(a);
    var logicals = try build(a, &rows, false);
    defer {
        for (logicals.items) |*ll| ll.cells.deinit(a);
        logicals.deinit(a);
    }
    try testing.expectEqual(@as(usize, 2), logicals.items.len);
    try testing.expectEqual(@as(usize, 10), logicals.items[0].cells.items.len);
    try testing.expectEqual(@as(u32, 'h'), logicals.items[0].cells.items[0].rune);
    try testing.expectEqual(@as(u32, 'w'), logicals.items[0].cells.items[5].rune);
    try testing.expectEqual(@as(usize, 5), logicals.items[1].cells.items.len);
}

test "trim drops trailing blank cells from each logical line" {
    const a = testing.allocator;
    var rows = [_]Line{
        try makeRow(a, "hi", 5, false),
        try makeRow(a, "x", 5, false),
    };
    defer for (&rows) |*r| r.deinit(a);
    var logicals = try build(a, &rows, false);
    defer {
        for (logicals.items) |*ll| ll.cells.deinit(a);
        logicals.deinit(a);
    }
    try testing.expectEqual(@as(usize, 5), logicals.items[0].cells.items.len);
    trim(&logicals, a);
    try testing.expectEqual(@as(usize, 2), logicals.items.len);
    try testing.expectEqual(@as(usize, 2), logicals.items[0].cells.items.len);
    try testing.expectEqual(@as(usize, 1), logicals.items[1].cells.items.len);
}

test "rechunk widens — 'hellowor' in 5-col rows becomes 1 row at 10 cols" {
    const a = testing.allocator;
    var rows = [_]Line{
        try makeRow(a, "hello", 5, false),
        try makeRow(a, "wor", 5, true),
    };
    defer for (&rows) |*r| r.deinit(a);
    var logicals = try build(a, &rows, false);
    defer {
        for (logicals.items) |*ll| ll.cells.deinit(a);
        logicals.deinit(a);
    }
    trim(&logicals, a);
    const out = try rechunk(a, logicals.items, 10);
    defer {
        for (out) |*r| r.deinit(a);
        a.free(out);
    }
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqual(@as(u32, 'h'), out[0].cells[0].rune);
    try testing.expectEqual(@as(u32, 'r'), out[0].cells[7].rune);
    try testing.expect(!out[0].continues_above);
}

test "rechunk narrows — 'hellowor' in 8-col row becomes 2 rows at 4 cols" {
    const a = testing.allocator;
    var rows = [_]Line{
        try makeRow(a, "hellowor", 8, false),
    };
    defer for (&rows) |*r| r.deinit(a);
    var logicals = try build(a, &rows, false);
    defer {
        for (logicals.items) |*ll| ll.cells.deinit(a);
        logicals.deinit(a);
    }
    trim(&logicals, a);
    const out = try rechunk(a, logicals.items, 4);
    defer {
        for (out) |*r| r.deinit(a);
        a.free(out);
    }
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expect(!out[0].continues_above);
    try testing.expect(out[1].continues_above);
    try testing.expectEqual(@as(u32, 'h'), out[0].cells[0].rune);
    // "hellowor" split at width 4: row 0 = "hell", row 1 = "owor"
    try testing.expectEqual(@as(u32, 'o'), out[1].cells[0].rune);
    try testing.expectEqual(@as(u32, 'r'), out[1].cells[3].rune);
}

test "positionInLogicals: row 1 col 2 in a 2-row logical line → idx 0 col 7" {
    const a = testing.allocator;
    var rows = [_]Line{
        try makeRow(a, "hello", 5, false),
        try makeRow(a, "world", 5, true),
    };
    defer for (&rows) |*r| r.deinit(a);
    const p = positionInLogicals(&rows, 1, 2);
    try testing.expectEqual(@as(usize, 0), p.idx);
    try testing.expectEqual(@as(u32, 7), p.col);
}

test "positionAfterRechunk: idx 0 col 7 → row 0 col 7 at new_cols=10" {
    const a = testing.allocator;
    var rows = [_]Line{
        try makeRow(a, "helloworld", 10, false),
    };
    defer for (&rows) |*r| r.deinit(a);
    const p = positionAfterRechunk(&rows, 0, 7, 10);
    try testing.expectEqual(@as(usize, 0), p.row);
    try testing.expectEqual(@as(u16, 7), p.col);
}
