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
//!      `new_cols` cells without splitting wide-cell pairs. The first
//!      piece has `continues_above=false`, every subsequent piece has
//!      `true`.
//!   4. Cursor: track its (logical_idx, col_in_logical) before reflow,
//!      compute its new (row, col) after.
//!
//! Combining codepoints live in Screen's side table; Screen remaps
//! those coordinates with the same position helpers used for the cursor.

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

const wide_left: u8 = 0b0000_0001;
const wide_cont: u8 = 0b0000_0010;

fn isWideLeft(cell: Cell) bool {
    return cell.flags & (wide_left | wide_cont) == wide_left;
}

fn isWideCont(cell: Cell) bool {
    return cell.flags & (wide_left | wide_cont) == wide_cont;
}

fn isValidWidePair(cells: []const Cell, left: usize) bool {
    if (left >= cells.len or left + 1 >= cells.len) return false;
    return isWideLeft(cells[left]) and cells[left].rune != 0 and
        isWideCont(cells[left + 1]) and cells[left + 1].rune == 0;
}

/// Exclude the structural blank left when a wide pair wrapped early.
fn logicalRowLen(rows: []const Line, row: usize) usize {
    const cells = rows[row].cells;
    if (cells.len == 0 or row + 1 >= rows.len) return cells.len;
    const next = rows[row + 1];
    if (!next.continues_above or !isValidWidePair(next.cells, 0)) return cells.len;
    const last = cells[cells.len - 1];
    if (last.rune == 0 and last.flags == 0) return cells.len - 1;
    return cells.len;
}

/// Blank malformed pair halves so they cannot survive reflow as ghosts.
fn repairMalformedWideCells(cells: []Cell) void {
    var i: usize = 0;
    while (i < cells.len) {
        if (isValidWidePair(cells, i)) {
            i += 2;
            continue;
        }
        if (cells[i].flags & (wide_left | wide_cont) != 0) cells[i] = .{};
        i += 1;
    }
}

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

    for (rows, 0..) |row, row_idx| {
        const want_new = !row.continues_above or out.items.len == 0;
        if (want_new) {
            try out.append(allocator, .{});
        }
        const ll = &out.items[out.items.len - 1];
        try ll.cells.appendSlice(allocator, row.cells[0..logicalRowLen(rows, row_idx)]);
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
        repairMalformedWideCells(ll.cells.items);
        var hi = ll.cells.items.len;
        while (hi > 0 and ll.cells.items[hi - 1].rune == 0) {
            if (hi >= 2 and isValidWidePair(ll.cells.items, hi - 2)) break;
            hi -= 1;
        }
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
    if (new_cols == 0) return error.InvalidColumns;
    const width: usize = new_cols;

    var rows: std.ArrayList(Line) = .empty;
    errdefer {
        for (rows.items) |*r| r.deinit(allocator);
        rows.deinit(allocator);
    }

    for (logicals) |ll| {
        if (ll.cells.items.len == 0) {
            // Empty logical line → one empty row.
            const cells = try allocator.alloc(Cell, new_cols);
            errdefer allocator.free(cells);
            @memset(cells, .{});
            try rows.append(allocator, .{ .cells = cells, .continues_above = false, .dirty = true });
            continue;
        }
        var i: usize = 0;
        var first = true;
        while (i < ll.cells.items.len) {
            const cells = try allocator.alloc(Cell, new_cols);
            errdefer allocator.free(cells);
            @memset(cells, .{});

            var col: usize = 0;
            while (i < ll.cells.items.len and col < width) {
                if (isValidWidePair(ll.cells.items, i)) {
                    if (width - col < 2) {
                        if (col == 0) return error.WideGlyphTooWide;
                        break;
                    }
                    cells[col] = ll.cells.items[i];
                    cells[col + 1] = ll.cells.items[i + 1];
                    i += 2;
                    col += 2;
                    continue;
                }

                const cell = ll.cells.items[i];
                cells[col] = if (cell.flags & (wide_left | wide_cont) != 0) .{} else cell;
                i += 1;
                col += 1;
            }
            try rows.append(allocator, .{
                .cells = cells,
                .continues_above = !first,
                .dirty = true,
            });
            first = false;
        }
    }

    return try rows.toOwnedSlice(allocator);
}

/// Compute the (logical_index, col_within_logical) of a position
/// (row, col) in the original buffer.
/// `row` indexes scrollback + active together, so it is `usize`: a large
/// `scrollback` setting puts it past 65535 and a `u16` counter would wrap
/// into an infinite loop.
pub fn positionInLogicals(rows: []const Line, row: usize, col: u16) struct { idx: usize, col: u32 } {
    var idx: usize = 0;
    var col_in: u32 = 0;
    var r: usize = 0;
    while (r <= row and r < rows.len) : (r += 1) {
        if (r > 0 and !rows[r].continues_above) {
            idx += 1;
            col_in = 0;
        }
        if (r == row) {
            col_in += @intCast(@min(@as(usize, col), logicalRowLen(rows, r)));
            break;
        } else {
            col_in += @intCast(logicalRowLen(rows, r));
        }
    }
    return .{ .idx = idx, .col = col_in };
}

/// Inverse: given (logical_idx, col_in_logical), find which post-
/// rechunk row + col it lands at.
pub fn positionAfterRechunk(
    logicals: []const Logical,
    rechunked: []const Line,
    target_idx: usize,
    target_col: u32,
    new_cols: u16,
) struct { row: usize, col: u16 } {
    if (rechunked.len == 0 or new_cols == 0) return .{ .row = 0, .col = 0 };
    if (target_idx >= logicals.len) {
        return .{ .row = rechunked.len - 1, .col = @intCast(@min(new_cols - 1, target_col)) };
    }

    var logical_idx: usize = 0;
    var start_row: usize = 0;
    var found = false;
    for (rechunked, 0..) |line, r| {
        if (r == 0 or !line.continues_above) {
            if (logical_idx == target_idx) {
                start_row = r;
                found = true;
                break;
            }
            logical_idx += 1;
        }
    }
    if (!found) return .{ .row = rechunked.len - 1, .col = new_cols - 1 };

    const cells = logicals[target_idx].cells.items;
    const width: usize = new_cols;
    var source: usize = 0;
    var row = start_row;
    var col: usize = 0;
    while (source < cells.len) {
        if (isValidWidePair(cells, source)) {
            if (width - col < 2) {
                row += 1;
                col = 0;
            }
            if (target_col == @as(u32, @intCast(source))) return .{ .row = row, .col = @intCast(col) };
            if (target_col == @as(u32, @intCast(source + 1))) return .{ .row = row, .col = @intCast(col + 1) };
            source += 2;
            col += 2;
        } else {
            if (target_col == @as(u32, @intCast(source))) return .{ .row = row, .col = @intCast(col) };
            source += 1;
            col += 1;
        }
        if (col == width and source < cells.len) {
            row += 1;
            col = 0;
        }
    }

    const beyond = target_col -| @as(u32, @intCast(cells.len));
    const end_col = if (col >= width) width - 1 else @min(width - 1, col + @as(usize, beyond));
    return .{ .row = @min(row, rechunked.len - 1), .col = @intCast(end_col) };
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

fn putWide(cells: []Cell, col: usize, rune: u32) void {
    cells[col] = .{ .rune = rune, .flags = wide_left };
    cells[col + 1] = .{ .flags = wide_cont };
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

test "trim preserves a wide pair in the final old columns" {
    const a = testing.allocator;
    var row = try makeRow(a, "ab", 4, false);
    defer row.deinit(a);
    putWide(row.cells, 2, 0x754C);

    var logicals = try build(a, &.{row}, false);
    defer {
        for (logicals.items) |*ll| ll.cells.deinit(a);
        logicals.deinit(a);
    }
    trim(&logicals, a);

    try testing.expectEqual(@as(usize, 4), logicals.items[0].cells.items.len);
    try testing.expect(isValidWidePair(logicals.items[0].cells.items, 2));
}

test "build removes only the blank inserted before a wrapped wide pair" {
    const a = testing.allocator;
    var rows = [_]Line{
        try makeRow(a, "ab", 3, false),
        try makeRow(a, "", 3, true),
    };
    defer for (&rows) |*row| row.deinit(a);
    putWide(rows[1].cells, 0, 0x754C);
    rows[1].cells[2].rune = 'c';

    var logicals = try build(a, &rows, false);
    defer {
        for (logicals.items) |*ll| ll.cells.deinit(a);
        logicals.deinit(a);
    }
    trim(&logicals, a);

    const cells = logicals.items[0].cells.items;
    try testing.expectEqual(@as(usize, 5), cells.len);
    try testing.expectEqual(@as(u32, 'a'), cells[0].rune);
    try testing.expectEqual(@as(u32, 'b'), cells[1].rune);
    try testing.expect(isValidWidePair(cells, 2));
    try testing.expectEqual(@as(u32, 'c'), cells[4].rune);
}

test "rechunk places a wide pair at exact and off-by-one boundaries" {
    const a = testing.allocator;
    var row = try makeRow(a, "ab", 5, false);
    defer row.deinit(a);
    putWide(row.cells, 2, 0x754C);
    row.cells[4].rune = 'c';

    var logicals = try build(a, &.{row}, false);
    defer {
        for (logicals.items) |*ll| ll.cells.deinit(a);
        logicals.deinit(a);
    }
    trim(&logicals, a);

    const exact = try rechunk(a, logicals.items, 4);
    defer {
        for (exact) |*line| line.deinit(a);
        a.free(exact);
    }
    try testing.expectEqual(@as(usize, 2), exact.len);
    try testing.expect(isValidWidePair(exact[0].cells, 2));
    try testing.expectEqual(@as(u32, 'c'), exact[1].cells[0].rune);
    try testing.expect(exact[1].continues_above);

    const off_by_one = try rechunk(a, logicals.items, 3);
    defer {
        for (off_by_one) |*line| line.deinit(a);
        a.free(off_by_one);
    }
    try testing.expectEqual(@as(usize, 2), off_by_one.len);
    try testing.expectEqual(@as(u32, 0), off_by_one[0].cells[2].rune);
    try testing.expect(isValidWidePair(off_by_one[1].cells, 0));
    try testing.expectEqual(@as(u32, 'c'), off_by_one[1].cells[2].rune);

    const position = positionAfterRechunk(logicals.items, off_by_one, 0, 4, 3);
    try testing.expectEqual(@as(usize, 1), position.row);
    try testing.expectEqual(@as(u16, 2), position.col);
}

test "rechunk repairs malformed wide halves and rejects an impossible width" {
    const a = testing.allocator;
    var row = try makeRow(a, "", 3, false);
    defer row.deinit(a);
    row.cells[0] = .{ .flags = wide_cont };
    row.cells[1] = .{ .rune = 'x' };
    row.cells[2] = .{ .rune = 0x754C, .flags = wide_left };

    var logicals = try build(a, &.{row}, false);
    defer {
        for (logicals.items) |*ll| ll.cells.deinit(a);
        logicals.deinit(a);
    }
    const repaired = try rechunk(a, logicals.items, 2);
    defer {
        for (repaired) |*line| line.deinit(a);
        a.free(repaired);
    }
    try testing.expectEqual(@as(u8, 0), repaired[0].cells[0].flags);
    try testing.expectEqual(@as(u32, 'x'), repaired[0].cells[1].rune);
    try testing.expectEqual(@as(u8, 0), repaired[1].cells[0].flags);

    var valid_row = try makeRow(a, "", 2, false);
    defer valid_row.deinit(a);
    putWide(valid_row.cells, 0, 0x754C);
    var valid = try build(a, &.{valid_row}, false);
    defer {
        for (valid.items) |*ll| ll.cells.deinit(a);
        valid.deinit(a);
    }
    try testing.expectError(error.WideGlyphTooWide, rechunk(a, valid.items, 1));
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
    var logicals = try build(a, &rows, false);
    defer {
        for (logicals.items) |*ll| ll.cells.deinit(a);
        logicals.deinit(a);
    }
    trim(&logicals, a);
    const p = positionAfterRechunk(logicals.items, &rows, 0, 7, 10);
    try testing.expectEqual(@as(usize, 0), p.row);
    try testing.expectEqual(@as(u16, 7), p.col);
}
