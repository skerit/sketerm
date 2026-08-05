//! Bracket matching over the display buffer, for copy mode's `%`.
//!
//! Works in display-row coordinates (negative = scrollback), the same
//! convention as Selection and SearchMatch, so the caller can hand it
//! a copy-mode cursor unchanged.

const std = @import("std");
const Screen = @import("screen.zig").Screen;

/// Bracket pairs, opener immediately followed by its closer.
const pairs = "()[]{}<>";

pub const Pos = struct { row: i32, col: u16 };

/// The bracket pairing with the one at (`row`, `col`), or null when
/// that cell is not a bracket, the pair is unbalanced, or the search
/// ran past `max_rows` rows in either direction. The row budget keeps
/// a stray bracket in a long scrollback from turning one keystroke
/// into a full-buffer scan on the main loop.
pub fn matchAt(screen: *const Screen, row: i32, col: u16, max_rows: i32) ?Pos {
    const cells = screen.lineCellsAtPub(row) orelse return null;
    if (col >= cells.len) return null;
    const here = cells[col].rune;

    var at: ?usize = null;
    for (pairs, 0..) |p, i| {
        if (p == here) at = i;
    }
    const idx = at orelse return null;
    const opening = idx % 2 == 0;
    const want: u32 = if (opening) pairs[idx + 1] else pairs[idx - 1];
    const dir: i32 = if (opening) 1 else -1;

    const sb: i32 = if (screen.use_alt) 0 else @intCast(screen.scrollbackCount());
    const last_row: i32 = @as(i32, @intCast(screen.rows)) - 1;

    var depth: i32 = 0;
    var r = row;
    var c: i32 = col;
    var line = cells;
    var rows_left = max_rows;
    while (true) {
        while (c >= 0 and c < @as(i32, @intCast(line.len))) : (c += dir) {
            const cp = line[@intCast(c)].rune;
            if (cp == here) {
                depth += 1;
            } else if (cp == want) {
                depth -= 1;
                if (depth == 0) return .{ .row = r, .col = @intCast(c) };
            }
        }
        if (rows_left == 0) return null;
        rows_left -= 1;
        r += dir;
        if (r < -sb or r > last_row) return null;
        line = screen.lineCellsAtPub(r) orelse return null;
        c = if (dir > 0) 0 else @as(i32, @intCast(line.len)) - 1;
    }
}

// ── Tests ─────────────────────────────────────────────────────────

const Pool = @import("style_pool.zig").Pool;

fn writeRow(s: *Screen, row: u16, text: []const u8) void {
    s.row = row;
    s.col = 0;
    for (text) |ch| s.printCp(ch);
}

test "matchAt pairs brackets forwards and backwards on one line" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 20, 4);
    defer s.deinit();
    writeRow(s, 0, "a(b[c]d)e");

    // The outer pair, from each end.
    try std.testing.expectEqual(Pos{ .row = 0, .col = 7 }, matchAt(s, 0, 1, 8).?);
    try std.testing.expectEqual(Pos{ .row = 0, .col = 1 }, matchAt(s, 0, 7, 8).?);
    // The inner pair, which the outer scan must not stop on.
    try std.testing.expectEqual(Pos{ .row = 0, .col = 5 }, matchAt(s, 0, 3, 8).?);
    // A cell that is not a bracket at all.
    try std.testing.expectEqual(@as(?Pos, null), matchAt(s, 0, 0, 8));
}

test "matchAt counts nesting across rows" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 20, 4);
    defer s.deinit();
    writeRow(s, 0, "fn x() {");
    writeRow(s, 1, "  if (y) {");
    writeRow(s, 2, "  }");
    writeRow(s, 3, "}");

    try std.testing.expectEqual(Pos{ .row = 3, .col = 0 }, matchAt(s, 0, 7, 8).?);
    try std.testing.expectEqual(Pos{ .row = 2, .col = 2 }, matchAt(s, 1, 9, 8).?);
    try std.testing.expectEqual(Pos{ .row = 0, .col = 7 }, matchAt(s, 3, 0, 8).?);
}

test "matchAt gives up on an unbalanced bracket and on a long scan" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 20, 4);
    defer s.deinit();
    writeRow(s, 0, "(unclosed");
    try std.testing.expectEqual(@as(?Pos, null), matchAt(s, 0, 0, 8));

    writeRow(s, 0, "(");
    writeRow(s, 3, ")");
    // Enough rows to reach it...
    try std.testing.expect(matchAt(s, 0, 0, 8) != null);
    // ...and not enough.
    try std.testing.expectEqual(@as(?Pos, null), matchAt(s, 0, 0, 1));
}
