//! Hand-rolled URL detector for cell rows. Finds `http://` or
//! `https://` followed by URL-allowed characters; trims trailing
//! sentence punctuation. Bounded, allocation-free per-row.
//!
//! Used by the renderer to draw an underline + change cursor on
//! hover for plain-text URLs that the shell didn't wrap in OSC 8.

const std = @import("std");
const cell_mod = @import("cell.zig");
const Cell = @import("cell.zig").Cell;

pub const Match = struct {
    /// Inclusive start column.
    col_start: u16,
    /// Exclusive end column (col_end - col_start = visible width).
    col_end: u16,
};

/// Scan one logical row of cells for URLs. Caller-provided
/// `out` buffer receives matches; returns the count written.
/// Caller sizes `out` (typical: 8 matches per row is plenty).
///
/// Cells whose `flags & cell_mod.FLAG_HAS_LINK != 0` already carry an OSC 8
/// hyperlink — skip those ranges so we don't double-decorate.
pub fn scanRow(cells: []const Cell, out: []Match) usize {
    var n: usize = 0;
    var col: usize = 0;

    while (col + 7 < cells.len and n < out.len) {
        // Cheap prefilter: the first character has to be 'h'.
        if (cells[col].rune != 'h') {
            col += 1;
            continue;
        }
        // Skip into-OSC-8 hyperlink runs entirely — leave them to the
        // explicit-link rendering path.
        if ((cells[col].flags & cell_mod.FLAG_HAS_LINK) != 0) {
            col += 1;
            continue;
        }
        const scheme_len = matchScheme(cells, col);
        if (scheme_len == 0) {
            col += 1;
            continue;
        }
        const start: u16 = @intCast(col);
        var end: usize = col + scheme_len;
        while (end < cells.len and isUrlChar(cells[end].rune)) : (end += 1) {}
        // Trim trailing sentence punctuation to avoid eating periods
        // and commas that surround URLs in prose.
        while (end > col + scheme_len and isTrailingPunct(cells[end - 1].rune)) {
            end -= 1;
        }
        if (end > col + scheme_len) {
            out[n] = .{ .col_start = start, .col_end = @intCast(end) };
            n += 1;
            col = end;
        } else {
            col += 1;
        }
    }

    return n;
}

/// Returns the length of a matching scheme prefix (`http://` = 7 or
/// `https://` = 8) or 0 if no scheme matches at this column.
fn matchScheme(cells: []const Cell, col: usize) usize {
    if (col + 7 > cells.len) return 0;
    // h t t p
    if (cells[col].rune != 'h') return 0;
    if (cells[col + 1].rune != 't') return 0;
    if (cells[col + 2].rune != 't') return 0;
    if (cells[col + 3].rune != 'p') return 0;
    // Optional 's', then '://'
    if (cells[col + 4].rune == 's') {
        if (col + 8 > cells.len) return 0;
        if (cells[col + 5].rune != ':') return 0;
        if (cells[col + 6].rune != '/') return 0;
        if (cells[col + 7].rune != '/') return 0;
        return 8;
    }
    if (cells[col + 4].rune != ':') return 0;
    if (cells[col + 5].rune != '/') return 0;
    if (cells[col + 6].rune != '/') return 0;
    return 7;
}

/// Characters allowed inside a URL after the scheme. RFC 3986
/// `unreserved` + `pct-encoded` + `sub-delims` + path/query/fragment
/// punctuation.
fn isUrlChar(cp: u32) bool {
    if (cp >= 'A' and cp <= 'Z') return true;
    if (cp >= 'a' and cp <= 'z') return true;
    if (cp >= '0' and cp <= '9') return true;
    return switch (cp) {
        '-', '.', '_', '~', // unreserved
        ':', '/', '?', '#', '[', ']', '@', // gen-delims
        '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=', // sub-delims
        '%', // pct-encoded leader
        => true,
        else => false,
    };
}

/// Punctuation we trim from the end of a matched URL because it's
/// almost always a sentence terminator, not part of the link.
fn isTrailingPunct(cp: u32) bool {
    return switch (cp) {
        '.', ',', ';', ':', '?', '!', ')', ']', '}', '\'', '"' => true,
        else => false,
    };
}

const testing = std.testing;

fn cellsFromAscii(allocator: std.mem.Allocator, ascii: []const u8) ![]Cell {
    const cells = try allocator.alloc(Cell, ascii.len);
    for (ascii, 0..) |b, i| {
        cells[i] = .{ .rune = b };
    }
    return cells;
}

test "scanRow: plain http URL" {
    const ally = testing.allocator;
    const cells = try cellsFromAscii(ally, "see http://example.com today");
    defer ally.free(cells);

    var matches: [4]Match = undefined;
    const n = scanRow(cells, &matches);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(u16, 4), matches[0].col_start);
    try testing.expectEqual(@as(u16, 22), matches[0].col_end);
}

test "scanRow: trailing period trimmed" {
    const ally = testing.allocator;
    const cells = try cellsFromAscii(ally, "Visit https://x.io.");
    defer ally.free(cells);

    var matches: [4]Match = undefined;
    const n = scanRow(cells, &matches);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(u16, 6), matches[0].col_start);
    try testing.expectEqual(@as(u16, 18), matches[0].col_end);
}

test "scanRow: skips OSC 8 cells" {
    const ally = testing.allocator;
    const cells = try cellsFromAscii(ally, "http://a.b/c");
    defer ally.free(cells);
    // Mark the whole range as already OSC-8 linked.
    for (cells) |*ce| ce.flags |= cell_mod.FLAG_HAS_LINK;

    var matches: [4]Match = undefined;
    const n = scanRow(cells, &matches);
    try testing.expectEqual(@as(usize, 0), n);
}

test "scanRow: two matches" {
    const ally = testing.allocator;
    const cells = try cellsFromAscii(ally, "http://a.b and https://c.d");
    defer ally.free(cells);

    var matches: [4]Match = undefined;
    const n = scanRow(cells, &matches);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(u16, 0), matches[0].col_start);
    try testing.expectEqual(@as(u16, 10), matches[0].col_end);
    try testing.expectEqual(@as(u16, 15), matches[1].col_start);
    try testing.expectEqual(@as(u16, 26), matches[1].col_end);
}

test "scanRow: not a URL" {
    const ally = testing.allocator;
    const cells = try cellsFromAscii(ally, "no link here at all");
    defer ally.free(cells);

    var matches: [4]Match = undefined;
    const n = scanRow(cells, &matches);
    try testing.expectEqual(@as(usize, 0), n);
}

test "scanRow: ftp scheme rejected" {
    const ally = testing.allocator;
    const cells = try cellsFromAscii(ally, "ftp://x.y");
    defer ally.free(cells);

    var matches: [4]Match = undefined;
    const n = scanRow(cells, &matches);
    try testing.expectEqual(@as(usize, 0), n);
}
