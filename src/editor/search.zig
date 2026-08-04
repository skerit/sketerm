//! Literal document search over the rope's chunk iterator — no regex.
//!
//! The scan never materializes the document: chunks stream out of
//! `Rope.iterateRange` into a small window buffer that retains only
//! `needle.len - 1` bytes across chunk boundaries, so a match spanning
//! two leaves is still found and can never be reported twice (a match
//! needs `needle.len` bytes and every retained byte is within the last
//! `needle.len - 1`).
//!
//! Deliberate simplifications (documented, not accidental):
//! - Case-insensitive matching folds ASCII only. A needle containing
//!   non-ASCII therefore matches case-sensitively for those bytes.
//! - No regex, no multi-line patterns beyond the literal bytes typed
//!   (a needle containing "\n" simply matches a newline).
//! - Whole-word tests the codepoint immediately before/after the match
//!   through `unicode.wordClassOf`, the same classifier double-click
//!   word selection uses.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Document = @import("document.zig").Document;
const unicode = @import("unicode.zig");

pub const Match = struct {
    start: usize,
    end: usize,
};

pub const Options = struct {
    case_sensitive: bool = false,
    whole_word: bool = false,
};

fn foldByte(b: u8, case_sensitive: bool) u8 {
    if (case_sensitive) return b;
    return if (b >= 'A' and b <= 'Z') b + 32 else b;
}

/// Copy up to `buf.len` bytes of the document starting at `off`.
fn readAt(doc: *const Document, off: usize, buf: []u8) []const u8 {
    const n = doc.rope.len();
    if (off >= n) return buf[0..0];
    const end = @min(n, off + buf.len);
    var it = doc.rope.iterateRange(off, end);
    var pos: usize = 0;
    while (it.next()) |chunk| {
        @memcpy(buf[pos .. pos + chunk.len], chunk);
        pos += chunk.len;
    }
    return buf[0..pos];
}

/// Codepoint starting at `off`, or null at/after the end.
fn cpAt(doc: *const Document, off: usize) ?u21 {
    var buf: [4]u8 = undefined;
    const s = readAt(doc, off, &buf);
    if (s.len == 0) return null;
    return unicode.decodeAt(s, 0).cp;
}

/// Codepoint ending at `off`, or null at the document start.
fn cpBefore(doc: *const Document, off: usize) ?u21 {
    if (off == 0) return null;
    var buf: [4]u8 = undefined;
    const start = off -| 4;
    const s = readAt(doc, start, &buf);
    if (s.len == 0) return null;
    // Walk back to the last lead byte.
    var i: usize = s.len;
    while (i > 0) {
        i -= 1;
        if ((s[i] & 0xC0) != 0x80) return unicode.decodeAt(s, i).cp;
    }
    return null;
}

fn isWordCp(cp: u21) bool {
    return unicode.wordClassOf(cp) == .word;
}

fn wholeWordOk(doc: *const Document, m: Match) bool {
    if (cpBefore(doc, m.start)) |cp| {
        if (isWordCp(cp)) return false;
    }
    if (cpAt(doc, m.end)) |cp| {
        if (isWordCp(cp)) return false;
    }
    return true;
}

/// Every occurrence of `needle`, ascending by start offset. Caller
/// frees. An empty needle yields no matches.
pub fn findAll(
    alloc: Allocator,
    doc: *const Document,
    needle: []const u8,
    opts: Options,
) ![]Match {
    var out: std.ArrayList(Match) = .empty;
    errdefer out.deinit(alloc);
    if (needle.len == 0) return out.toOwnedSlice(alloc);
    const doc_len = doc.rope.len();
    if (needle.len > doc_len) return out.toOwnedSlice(alloc);

    // Folded needle, so the inner loop compares byte-for-byte.
    const pat = try alloc.alloc(u8, needle.len);
    defer alloc.free(pat);
    for (needle, 0..) |b, i| pat[i] = foldByte(b, opts.case_sensitive);

    var win: std.ArrayList(u8) = .empty;
    defer win.deinit(alloc);
    // Document offset of win.items[0].
    var base: usize = 0;
    var it = doc.rope.iterateRange(0, doc_len);
    while (it.next()) |chunk| {
        const before = win.items.len;
        try win.resize(alloc, before + chunk.len);
        for (chunk, 0..) |b, i| win.items[before + i] = foldByte(b, opts.case_sensitive);
        try scanWindow(alloc, &out, win.items, base, pat);
        const keep = @min(win.items.len, needle.len - 1);
        const drop = win.items.len - keep;
        if (drop > 0) {
            std.mem.copyForwards(u8, win.items[0..keep], win.items[drop..]);
            win.shrinkRetainingCapacity(keep);
            base += drop;
        }
    }

    if (opts.whole_word) {
        var w: usize = 0;
        for (out.items) |m| {
            if (wholeWordOk(doc, m)) {
                out.items[w] = m;
                w += 1;
            }
        }
        out.shrinkRetainingCapacity(w);
    }
    return out.toOwnedSlice(alloc);
}

fn scanWindow(
    alloc: Allocator,
    out: *std.ArrayList(Match),
    hay: []const u8,
    base: usize,
    pat: []const u8,
) !void {
    if (hay.len < pat.len) return;
    var i: usize = 0;
    const last = hay.len - pat.len;
    while (i <= last) : (i += 1) {
        if (std.mem.eql(u8, hay[i .. i + pat.len], pat)) {
            try out.append(alloc, .{ .start = base + i, .end = base + i + pat.len });
        }
    }
}

/// Index of the match to select when searching from `from` (a caret
/// offset). Forward picks the first match starting at or after `from`;
/// backward picks the last match ending at or before `from`. Both wrap
/// around. Null only when there are no matches.
pub fn pick(matches: []const Match, from: usize, forward: bool) ?usize {
    if (matches.len == 0) return null;
    if (forward) {
        for (matches, 0..) |m, i| {
            if (m.start >= from) return i;
        }
        return 0;
    }
    var i: usize = matches.len;
    while (i > 0) {
        i -= 1;
        if (matches[i].end <= from) return i;
    }
    return matches.len - 1;
}

/// Index of the match exactly covering [start,end), if any (used to
/// keep "3 of 17" stable when the caret already sits on a match).
pub fn indexOfRange(matches: []const Match, start: usize, end: usize) ?usize {
    for (matches, 0..) |m, i| {
        if (m.start == start and m.end == end) return i;
    }
    return null;
}

// ======================================================================
// Tests
// ======================================================================

const testing = std.testing;

fn docOf(text: []const u8) !Document {
    return try Document.initFromBytes(testing.allocator, text);
}

test "search: literal matches, case folding, empty needle" {
    const a = testing.allocator;
    var doc = try docOf("Foo foo FOO bar");
    defer doc.deinit();

    {
        const m = try findAll(a, &doc, "foo", .{});
        defer a.free(m);
        try testing.expectEqual(@as(usize, 3), m.len);
        try testing.expectEqual(@as(usize, 0), m[0].start);
        try testing.expectEqual(@as(usize, 4), m[1].start);
        try testing.expectEqual(@as(usize, 8), m[2].start);
        try testing.expectEqual(@as(usize, 3), m[0].end);
    }
    {
        const m = try findAll(a, &doc, "foo", .{ .case_sensitive = true });
        defer a.free(m);
        try testing.expectEqual(@as(usize, 1), m.len);
        try testing.expectEqual(@as(usize, 4), m[0].start);
    }
    {
        const m = try findAll(a, &doc, "", .{});
        defer a.free(m);
        try testing.expectEqual(@as(usize, 0), m.len);
    }
}

test "search: whole word filters substrings" {
    const a = testing.allocator;
    var doc = try docOf("cat category cat.dog scatter");
    defer doc.deinit();
    const all = try findAll(a, &doc, "cat", .{});
    defer a.free(all);
    try testing.expectEqual(@as(usize, 4), all.len);
    const ww = try findAll(a, &doc, "cat", .{ .whole_word = true });
    defer a.free(ww);
    try testing.expectEqual(@as(usize, 2), ww.len);
    try testing.expectEqual(@as(usize, 0), ww[0].start);
    try testing.expectEqual(@as(usize, 13), ww[1].start);
}

test "search: matches spanning rope leaf boundaries are found once" {
    const a = testing.allocator;
    // Build a document large enough to hold many leaves, with the
    // needle placed at many offsets so some straddle a boundary.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(a);
    var i: usize = 0;
    while (i < 4000) : (i += 1) {
        try text.appendSlice(a, "abcdefg");
        if (i % 7 == 0) try text.appendSlice(a, "NEEDLE");
    }
    var doc = try Document.initFromBytes(a, text.items);
    defer doc.deinit();
    const m = try findAll(a, &doc, "NEEDLE", .{});
    defer a.free(m);
    const expected = (4000 + 6) / 7;
    try testing.expectEqual(expected, m.len);
    // Strictly ascending, non-overlapping.
    var prev: usize = 0;
    for (m, 0..) |x, k| {
        if (k > 0) try testing.expect(x.start >= prev);
        prev = x.end;
        try testing.expectEqual(@as(usize, 6), x.end - x.start);
    }
    // And each really is the needle.
    const first = try doc.rope.sliceAlloc(a, m[0].start, m[0].end);
    defer a.free(first);
    try testing.expectEqualStrings("NEEDLE", first);
}

test "search: pick wraps in both directions" {
    const m = [_]Match{
        .{ .start = 5, .end = 8 },
        .{ .start = 20, .end = 23 },
    };
    try testing.expectEqual(@as(usize, 0), pick(&m, 0, true).?);
    try testing.expectEqual(@as(usize, 1), pick(&m, 9, true).?);
    try testing.expectEqual(@as(usize, 0), pick(&m, 99, true).?); // wrapped
    try testing.expectEqual(@as(usize, 1), pick(&m, 99, false).?);
    try testing.expectEqual(@as(usize, 0), pick(&m, 20, false).?);
    try testing.expectEqual(@as(usize, 1), pick(&m, 0, false).?); // wrapped
    try testing.expectEqual(@as(?usize, null), pick(&.{}, 0, true));
}

test "search: multi-line needle" {
    const a = testing.allocator;
    var doc = try docOf("one\ntwo\nthree\ntwo\n");
    defer doc.deinit();
    const m = try findAll(a, &doc, "two\n", .{});
    defer a.free(m);
    try testing.expectEqual(@as(usize, 2), m.len);
    try testing.expectEqual(@as(usize, 4), m[0].start);
    try testing.expectEqual(@as(usize, 14), m[1].start);
}
