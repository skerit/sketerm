//! Keyboard hints / quick-select mode (kitty "hints kitten", WezTerm
//! QuickSelect). Scans the visible screen for URLs, file paths, and
//! hex hashes, overlays a short label on each, and lets the user pick
//! one by typing its label — open (URLs) or copy (everything else)
//! without touching the mouse.
//!
//! This module is pure logic: scanning, label assignment, text
//! extraction. Window owns the mode state + key handling; GridPass
//! draws the overlays from `Screen.hints_overlay`.

const std = @import("std");
const Screen = @import("../grid/screen.zig").Screen;
const Cell = @import("../grid/cell.zig").Cell;
const url_scan = @import("../grid/url_scan.zig");

pub const Kind = enum { url, path, hash };

pub const Match = struct {
    /// Display row (0..rows-1) at collect time.
    row: u16,
    /// Inclusive start / exclusive end columns.
    col_start: u16,
    col_end: u16,
    kind: Kind,
    /// Extracted text, owned by the caller's allocator. Captured at
    /// collect time so scrolling can't change what gets activated.
    text: []u8,
    /// Assigned label ("a", "fj", ...). All labels in one batch share
    /// the same length, so no label is a prefix of another.
    label: [2]u8 = .{ 0, 0 },
    label_len: u8 = 0,
};

/// Home-row-first label alphabet.
pub const ALPHABET = "asdfghjklqwertyuiopzxcvbnm";

/// Hard cap: 26 single-char + first rows of 2-char labels is far more
/// than ever fits on screen anyway.
pub const MAX_MATCHES = 26 * 26;

pub fn freeMatches(allocator: std.mem.Allocator, matches: []Match) void {
    for (matches) |m| allocator.free(m.text);
}

/// Scan the visible rows of `screen` for hintable items, in reading
/// order. Caller owns the returned slice AND each match's `text`
/// (use `freeMatches`). Labels are already assigned.
pub fn collectVisible(allocator: std.mem.Allocator, screen: *const Screen) ![]Match {
    var out: std.ArrayList(Match) = .empty;
    errdefer {
        freeMatches(allocator, out.items);
        out.deinit(allocator);
    }

    const view_off: i32 = @intCast(@min(screen.view_offset, screen.scrollbackCount()));
    var d: u16 = 0;
    while (d < screen.rows) : (d += 1) {
        const buf_row: i32 = @as(i32, d) - view_off;
        const cells = screen.lineCellsAtPub(buf_row) orelse continue;
        try scanRowAll(allocator, screen, cells, d, &out);
        if (out.items.len >= MAX_MATCHES) break;
    }

    assignLabels(out.items);
    return try out.toOwnedSlice(allocator);
}

/// All scanners for one row, deduplicated: OSC 8 link runs win over
/// plain URLs win over paths win over hashes (checked via overlap
/// against matches already collected for this row).
fn scanRowAll(
    allocator: std.mem.Allocator,
    screen: *const Screen,
    cells: []const Cell,
    row: u16,
    out: *std.ArrayList(Match),
) !void {
    const row_first = out.items.len;

    // 1. OSC 8 hyperlink runs (consecutive cells with the link flag
    //    and the same link id).
    {
        var col: usize = 0;
        while (col < cells.len) {
            if ((cells[col].flags & 0b0000_0100) == 0 or cells[col].reserved == 0) {
                col += 1;
                continue;
            }
            const id = cells[col].reserved;
            const start = col;
            while (col < cells.len and (cells[col].flags & 0b0000_0100) != 0 and cells[col].reserved == id) : (col += 1) {}
            if (screen.linkUri(id)) |uri| {
                try out.append(allocator, .{
                    .row = row,
                    .col_start = @intCast(start),
                    .col_end = @intCast(col),
                    .kind = .url,
                    .text = try allocator.dupe(u8, uri),
                });
            }
        }
    }

    // 2. Plain-text URLs.
    {
        var buf: [16]url_scan.Match = undefined;
        const n = url_scan.scanRow(cells, &buf);
        for (buf[0..n]) |m| {
            if (overlaps(out.items[row_first..], m.col_start, m.col_end)) continue;
            try out.append(allocator, .{
                .row = row,
                .col_start = m.col_start,
                .col_end = m.col_end,
                .kind = .url,
                .text = try extractCells(allocator, cells[m.col_start..m.col_end]),
            });
        }
    }

    // 3. File paths: a token containing '/' made of path characters,
    //    anchored at a word boundary. Catches `/abs/path`, `~/x`,
    //    `./rel`, and `src/ui/pane.zig:123` alike.
    {
        var col: usize = 0;
        while (col < cells.len) {
            if (!isPathChar(cells[col].rune) or (col > 0 and isPathChar(cells[col - 1].rune))) {
                col += 1;
                continue;
            }
            const start = col;
            var has_slash = false;
            while (col < cells.len and isPathChar(cells[col].rune)) : (col += 1) {
                if (cells[col].rune == '/') has_slash = true;
            }
            var end = col;
            // Trim trailing sentence punctuation (`.`, `,`, `:`, …).
            while (end > start and isTrailingPunct(cells[end - 1].rune)) end -= 1;
            if (!has_slash or end - start < 3) continue;
            // A lone slash-and-punct run ("///", "/.") isn't a path.
            var alnum: usize = 0;
            for (cells[start..end]) |cl| {
                if (isAlnum(cl.rune)) alnum += 1;
            }
            if (alnum < 2) continue;
            if (overlaps(out.items[row_first..], @intCast(start), @intCast(end))) continue;
            try out.append(allocator, .{
                .row = row,
                .col_start = @intCast(start),
                .col_end = @intCast(end),
                .kind = .path,
                .text = try extractCells(allocator, cells[start..end]),
            });
        }
    }

    // 4. Hex hashes (git SHAs etc.): 7-64 hex digits at word
    //    boundaries, requiring at least one letter so plain numbers
    //    ("12345678") don't light up.
    {
        var col: usize = 0;
        while (col < cells.len) {
            if (!isHexChar(cells[col].rune) or (col > 0 and isWordChar(cells[col - 1].rune))) {
                col += 1;
                continue;
            }
            const start = col;
            while (col < cells.len and isHexChar(cells[col].rune)) : (col += 1) {}
            const end = col;
            const len = end - start;
            // Reject when the run continues with word chars (it's an
            // identifier, not a hash).
            if (end < cells.len and isWordChar(cells[end].rune)) continue;
            if (len < 7 or len > 64) continue;
            var has_alpha = false;
            for (cells[start..end]) |cl| {
                if (cl.rune >= 'a' and cl.rune <= 'f') has_alpha = true;
            }
            if (!has_alpha) continue;
            if (overlaps(out.items[row_first..], @intCast(start), @intCast(end))) continue;
            try out.append(allocator, .{
                .row = row,
                .col_start = @intCast(start),
                .col_end = @intCast(end),
                .kind = .hash,
                .text = try extractCells(allocator, cells[start..end]),
            });
        }
    }
}

fn overlaps(row_matches: []const Match, lo: u16, hi: u16) bool {
    for (row_matches) |m| {
        if (lo < m.col_end and m.col_start < hi) return true;
    }
    return false;
}

fn extractCells(allocator: std.mem.Allocator, cells: []const Cell) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (cells) |cl| {
        if (cl.flags & 0b0000_0010 != 0) continue; // wide continuation
        if (cl.rune == 0) continue;
        var ub: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(cl.rune), &ub) catch continue;
        try out.appendSlice(allocator, ub[0..n]);
    }
    return try out.toOwnedSlice(allocator);
}

/// Assign labels in reading order. ≤26 matches get single-char
/// labels; more get uniform two-char labels (uniform length keeps the
/// set prefix-free).
pub fn assignLabels(matches: []Match) void {
    if (matches.len <= ALPHABET.len) {
        for (matches, 0..) |*m, i| {
            m.label[0] = ALPHABET[i];
            m.label_len = 1;
        }
    } else {
        for (matches, 0..) |*m, i| {
            m.label[0] = ALPHABET[(i / ALPHABET.len) % ALPHABET.len];
            m.label[1] = ALPHABET[i % ALPHABET.len];
            m.label_len = 2;
        }
    }
}

fn isPathChar(cp: u32) bool {
    return switch (cp) {
        'a'...'z', 'A'...'Z', '0'...'9' => true,
        '/', '.', '_', '-', '~', '+', '@', '%', ':', '#' => true,
        else => false,
    };
}

fn isTrailingPunct(cp: u32) bool {
    return switch (cp) {
        '.', ',', ':', ';', '!', '?', ')', ']', '}', '\'', '"' => true,
        else => false,
    };
}

fn isAlnum(cp: u32) bool {
    return switch (cp) {
        'a'...'z', 'A'...'Z', '0'...'9' => true,
        else => false,
    };
}

fn isHexChar(cp: u32) bool {
    return switch (cp) {
        '0'...'9', 'a'...'f' => true,
        else => false,
    };
}

fn isWordChar(cp: u32) bool {
    return switch (cp) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.', '/' => true,
        else => false,
    };
}

// ── Tests ──────────────────────────────────────────────────────────

const StylePool = @import("../grid/style_pool.zig").Pool;

fn feedStr(s: *Screen, text: []const u8) void {
    for (text) |b| s.apply(.{ .print_byte = b });
}

test "collectVisible finds URL, path, and hash with labels" {
    var pool = try StylePool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 80, 6);
    defer s.deinit();
    feedStr(s, "see https://example.com/x and /etc/passwd plus deadbeef123");

    const matches = try collectVisible(std.testing.allocator, s);
    defer {
        freeMatches(std.testing.allocator, matches);
        std.testing.allocator.free(matches);
    }
    try std.testing.expectEqual(@as(usize, 3), matches.len);
    try std.testing.expectEqual(Kind.url, matches[0].kind);
    try std.testing.expectEqualStrings("https://example.com/x", matches[0].text);
    try std.testing.expectEqual(Kind.path, matches[1].kind);
    try std.testing.expectEqualStrings("/etc/passwd", matches[1].text);
    try std.testing.expectEqual(Kind.hash, matches[2].kind);
    try std.testing.expectEqualStrings("deadbeef123", matches[2].text);
    // Labels: single char, home-row order.
    try std.testing.expectEqual(@as(u8, 'a'), matches[0].label[0]);
    try std.testing.expectEqual(@as(u8, 's'), matches[1].label[0]);
    try std.testing.expectEqual(@as(u8, 'd'), matches[2].label[0]);
}

test "path with line suffix and relative path detected; identifiers not hashed" {
    var pool = try StylePool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 80, 4);
    defer s.deinit();
    feedStr(s, "src/ui/pane.zig:123 abcdef12345ghi");

    const matches = try collectVisible(std.testing.allocator, s);
    defer {
        freeMatches(std.testing.allocator, matches);
        std.testing.allocator.free(matches);
    }
    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqual(Kind.path, matches[0].kind);
    try std.testing.expectEqualStrings("src/ui/pane.zig:123", matches[0].text);
}

test "URL is not double-reported as path" {
    var pool = try StylePool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 80, 4);
    defer s.deinit();
    feedStr(s, "https://host/a/b.html");

    const matches = try collectVisible(std.testing.allocator, s);
    defer {
        freeMatches(std.testing.allocator, matches);
        std.testing.allocator.free(matches);
    }
    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqual(Kind.url, matches[0].kind);
}

test "two-char labels are uniform when >26 matches" {
    var ms: [30]Match = undefined;
    for (&ms) |*m| m.* = .{ .row = 0, .col_start = 0, .col_end = 1, .kind = .hash, .text = &.{} };
    assignLabels(&ms);
    for (ms) |m| try std.testing.expectEqual(@as(u8, 2), m.label_len);
    try std.testing.expectEqual(@as(u8, 'a'), ms[0].label[0]);
    try std.testing.expectEqual(@as(u8, 'a'), ms[0].label[1]);
    try std.testing.expectEqual(@as(u8, 's'), ms[27].label[1]);
}
