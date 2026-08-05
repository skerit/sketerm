//! Per-line VCS change marks for the editor gutter.
//!
//! ## Where the data comes from
//!
//! The GUI never touches the disk and never runs a process, so the
//! committed content of a file cannot be read here. What produces the
//! marks is the daemon's `git_diff` fs job (`mux/fsjob.zig
//! runGitDiff`), which runs
//!
//!     git diff -U0 --no-color --no-ext-diff HEAD -- <name>
//!
//! on the file's OWN host — so a remote document gets its gutter from
//! the remote repository — and parses the result THERE, with
//! `parseUnified` below plus `runsFromLines`. What crosses the wire is
//! therefore a handful of `Run` records (start line, count, kind), not
//! diff text: one parser implementation for every client, and a reply
//! that carries only what a gutter needs. `ui/editorproj.zig` expands
//! the runs straight back into `LineMark`s, so producer and consumer
//! share these types and this file's tests cover both.
//!
//! Neither of the two verbs that sound like they should do this can:
//! `git_status` reports per-FILE status letters only (no line
//! information at all), and `diff` diffs two files that both exist on
//! the host — there is no verb that materializes a committed blob,
//! which is why `git_diff` exists at all.
//!
//! ## Why anchors and not line numbers
//!
//! A refresh is a round trip to the daemon; the user keeps typing
//! during it. Marks are therefore stored as BYTE ANCHORS (the offset of
//! the marked line's first byte) and carried through every edit with
//! `transaction.mapOffset`, exactly like folds, selections and
//! diagnostics. The line a mark paints on is re-derived from its anchor
//! at draw time, so inserting a line above a hunk moves the hunk down
//! for free and nothing flickers between refreshes.

const std = @import("std");
const Document = @import("document.zig").Document;
const tr = @import("transaction.zig");

pub const Kind = enum(u8) {
    /// Lines that exist in the working file and not in HEAD.
    added,
    /// Lines that exist in both but differ.
    modified,
    /// Lines that exist in HEAD and not in the working file. The mark
    /// sits on the line that now occupies the gap.
    deleted,
};

/// One mark in DIFF coordinates (0-based line of the working file).
pub const LineMark = struct {
    line: u32,
    kind: Kind,
};

/// A maximal run of consecutive lines carrying the same kind — the
/// wire form of a gutter. A whole-file rewrite is one record instead
/// of one per line, and a hunk is at most three.
pub const Run = struct {
    /// 0-based first line of the run, in the working file.
    line: u32,
    /// How many lines the run covers. Never 0.
    count: u32,
    kind: Kind,
};

/// Stable wire spelling of a kind. The daemon puts these on the
/// `kind` field of a `git_diff` job event; unknown spellings are
/// dropped by the reader rather than guessed at.
pub fn kindName(kind: Kind) []const u8 {
    return @tagName(kind);
}

pub fn kindFromName(name: []const u8) ?Kind {
    return std.meta.stringToEnum(Kind, name);
}

/// Collapse per-line marks (which `parseUnified` produces in ascending
/// line order) into runs. Sorting is the caller's business: the parser
/// already emits ascending lines, and a `deleted` mark may share a
/// line with the change that follows it, which stays two runs.
pub fn runsFromLines(alloc: std.mem.Allocator, lines: []const LineMark) std.mem.Allocator.Error![]Run {
    var out: std.ArrayList(Run) = .empty;
    errdefer out.deinit(alloc);
    for (lines) |lm| {
        if (out.items.len > 0) {
            const last = &out.items[out.items.len - 1];
            if (last.kind == lm.kind and last.line + last.count == lm.line) {
                last.count += 1;
                continue;
            }
        }
        try out.append(alloc, .{ .line = lm.line, .count = 1, .kind = lm.kind });
    }
    return out.toOwnedSlice(alloc);
}

/// Expand runs back into per-line marks, for `Marks.setFromLines`.
pub fn linesFromRuns(alloc: std.mem.Allocator, runs: []const Run) std.mem.Allocator.Error![]LineMark {
    var total: usize = 0;
    for (runs) |r| total += r.count;
    var out = try alloc.alloc(LineMark, total);
    var w: usize = 0;
    for (runs) |r| {
        for (0..r.count) |i| {
            out[w] = .{ .line = r.line + @as(u32, @intCast(i)), .kind = r.kind };
            w += 1;
        }
    }
    return out;
}

/// One mark in DOCUMENT coordinates.
pub const Mark = struct {
    /// Byte offset of the marked line's first byte.
    anchor: usize,
    kind: Kind,
};

/// Parse a unified diff into per-line marks, in the NEW file's
/// coordinates.
///
/// Any context width works (`-U0` is merely what the editor asks for).
/// The hunk header's counts bound the body, so a payload line that
/// happens to start with `---` or `diff ` can never be mistaken for
/// framing.
///
/// A `-` run immediately followed by a `+` run reads as MODIFIED for as
/// many lines as both have; the surplus is added or deleted. That is
/// the convention every editor gutter uses, and it is the reason this
/// is a parser rather than a line count.
pub fn parseUnified(alloc: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error![]LineMark {
    var out: std.ArrayList(LineMark) = .empty;
    errdefer out.deinit(alloc);

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const hdr = parseHunkHeader(line) orelse continue;
        var new_line: u32 = hdr.new_start;
        var old_left: u32 = hdr.old_count;
        var new_left: u32 = hdr.new_count;
        var del_pending: u32 = 0;
        while (old_left > 0 or new_left > 0) {
            const body_raw = it.next() orelse break;
            const body = std.mem.trimEnd(u8, body_raw, "\r");
            // "\ No newline at end of file" annotates the previous line
            // and consumes no budget.
            if (body.len > 0 and body[0] == '\\') continue;
            const tag: u8 = if (body.len == 0) ' ' else body[0];
            switch (tag) {
                '+' => {
                    if (new_left == 0) break;
                    new_left -= 1;
                    const kind: Kind = if (del_pending > 0) blk: {
                        del_pending -= 1;
                        break :blk .modified;
                    } else .added;
                    try out.append(alloc, .{ .line = new_line, .kind = kind });
                    new_line += 1;
                },
                '-' => {
                    if (old_left == 0) break;
                    old_left -= 1;
                    del_pending += 1;
                },
                ' ' => {
                    if (del_pending > 0) {
                        try out.append(alloc, .{ .line = new_line, .kind = .deleted });
                        del_pending = 0;
                    }
                    if (old_left > 0) old_left -= 1;
                    if (new_left > 0) new_left -= 1;
                    new_line += 1;
                },
                else => break,
            }
        }
        if (del_pending > 0) {
            // Deletion at the hunk's tail: the gap is where the next
            // line now starts. A deletion at end-of-file leaves an
            // anchor one past the last line, which `anchorInto` clamps.
            try out.append(alloc, .{ .line = new_line, .kind = .deleted });
        }
    }
    return out.toOwnedSlice(alloc);
}

const Header = struct {
    old_start: u32,
    old_count: u32,
    new_start: u32,
    new_count: u32,
};

/// `@@ -12,3 +12,4 @@ trailing context` -> counts, or null.
/// Start lines come back 0-BASED; a `,0` range starts at the line
/// AFTER the printed one, which is git's convention for "nothing here".
fn parseHunkHeader(line: []const u8) ?Header {
    if (!std.mem.startsWith(u8, line, "@@ ")) return null;
    const close = std.mem.indexOf(u8, line, " @@") orelse return null;
    var body = line[3..close];
    const minus = std.mem.indexOfScalar(u8, body, '-') orelse return null;
    body = body[minus + 1 ..];
    const space = std.mem.indexOfScalar(u8, body, ' ') orelse return null;
    const old = parseRange(body[0..space]) orelse return null;
    var rest = body[space + 1 ..];
    if (rest.len == 0 or rest[0] != '+') return null;
    rest = rest[1..];
    const new = parseRange(rest) orelse return null;
    return .{
        .old_start = old.start,
        .old_count = old.count,
        .new_start = new.start,
        .new_count = new.count,
    };
}

const Range = struct { start: u32, count: u32 };

fn parseRange(s: []const u8) ?Range {
    const comma = std.mem.indexOfScalar(u8, s, ',');
    const start_txt = if (comma) |i| s[0..i] else s;
    const count_txt = if (comma) |i| s[i + 1 ..] else "1";
    const start = std.fmt.parseInt(u32, start_txt, 10) catch return null;
    const count = std.fmt.parseInt(u32, count_txt, 10) catch return null;
    // 1-based on the wire; an empty range prints the line BEFORE the
    // gap, so its 0-based first line is that same number.
    if (count == 0) return .{ .start = start, .count = 0 };
    return .{ .start = if (start == 0) 0 else start - 1, .count = count };
}

/// Every line of a file that is not in the index at all.
pub fn allAdded(alloc: std.mem.Allocator, doc: *const Document) std.mem.Allocator.Error![]LineMark {
    const n = doc.rope.lineCount();
    var out = try alloc.alloc(LineMark, n);
    for (0..n) |i| out[i] = .{ .line = @intCast(i), .kind = .added };
    return out;
}

/// Anchored, edit-carrying mark set for one document.
pub const Marks = struct {
    allocator: std.mem.Allocator,
    list: std.ArrayList(Mark) = .empty,
    /// Set while a refresh is in flight, so a UI can show it.
    refreshing: bool = false,
    /// True once a refresh has answered — an empty list then means
    /// "clean", not "unknown".
    known: bool = false,

    pub fn init(allocator: std.mem.Allocator) Marks {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Marks) void {
        self.list.deinit(self.allocator);
        self.list = .empty;
    }

    pub fn clear(self: *Marks) void {
        self.list.clearRetainingCapacity();
        self.known = false;
    }

    pub fn isEmpty(self: *const Marks) bool {
        return self.list.items.len == 0;
    }

    /// Replace the set from line-coordinate marks resolved against
    /// `doc`. Sorted by anchor and deduplicated (a line can only carry
    /// one mark; a `deleted` sharing a line with a change loses, since
    /// the change is the more informative of the two).
    pub fn setFromLines(
        self: *Marks,
        doc: *const Document,
        lines: []const LineMark,
    ) std.mem.Allocator.Error!void {
        self.list.clearRetainingCapacity();
        const n = doc.rope.lineCount();
        try self.list.ensureTotalCapacity(self.allocator, lines.len);
        for (lines) |lm| {
            const line = @min(lm.line, n -| 1);
            const anchor = doc.rope.lineToOffset(line);
            self.list.appendAssumeCapacity(.{ .anchor = anchor, .kind = lm.kind });
        }
        std.mem.sort(Mark, self.list.items, {}, lessByAnchor);
        var w: usize = 0;
        for (self.list.items) |m| {
            if (w > 0 and self.list.items[w - 1].anchor == m.anchor) {
                if (self.list.items[w - 1].kind == .deleted and m.kind != .deleted)
                    self.list.items[w - 1] = m;
                continue;
            }
            self.list.items[w] = m;
            w += 1;
        }
        self.list.shrinkRetainingCapacity(w);
        self.known = true;
    }

    fn lessByAnchor(_: void, a: Mark, b: Mark) bool {
        if (a.anchor != b.anchor) return a.anchor < b.anchor;
        return @intFromEnum(a.kind) < @intFromEnum(b.kind);
    }

    /// Carry every anchor through one edit list. `.other` mode: a mark
    /// is a view of the document, not the thing that typed.
    pub fn mapThrough(self: *Marks, edits: []const tr.Edit) void {
        if (self.list.items.len == 0 or edits.len == 0) return;
        for (self.list.items) |*m| m.anchor = tr.mapOffset(edits, m.anchor, .other);
    }

    /// Anchor of the first mark of the next hunk (a maximal run of
    /// marks on consecutive lines) strictly after / before `offset`.
    pub fn nextHunk(self: *const Marks, doc: *const Document, offset: usize, forward: bool) ?usize {
        if (self.list.items.len == 0) return null;
        const line_o = doc.rope.offsetToLineCol(@min(offset, doc.rope.len())).line;
        var best: ?usize = null;
        var first: ?usize = null;
        var last: ?usize = null;
        for (0..self.list.items.len) |i| {
            if (!self.isHunkStart(doc, i)) continue;
            const a = self.list.items[i].anchor;
            if (first == null) first = a;
            last = a;
            const line_a = doc.rope.offsetToLineCol(a).line;
            if (forward) {
                if (line_a > line_o and best == null) best = a;
            } else {
                if (line_a < line_o) best = a;
            }
        }
        if (best) |b| return b;
        // Past the end (or before the start): wrap around.
        return if (forward) first else last;
    }

    /// True when mark `i` opens a hunk — a maximal run of marks on
    /// consecutive lines.
    fn isHunkStart(self: *const Marks, doc: *const Document, i: usize) bool {
        if (i == 0) return true;
        const prev = doc.rope.offsetToLineCol(self.list.items[i - 1].anchor).line;
        const cur = doc.rope.offsetToLineCol(self.list.items[i].anchor).line;
        return cur > prev + 1;
    }

    /// How many hunks the set holds (for a status line).
    pub fn hunkCount(self: *const Marks, doc: *const Document) usize {
        var n: usize = 0;
        for (0..self.list.items.len) |i| {
            if (self.isHunkStart(doc, i)) n += 1;
        }
        return n;
    }
};

// ======================================================================
// Tests
// ======================================================================

const testing = std.testing;

fn expectMarks(text: []const u8, want: []const LineMark) !void {
    const got = try parseUnified(testing.allocator, text);
    defer testing.allocator.free(got);
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| {
        try testing.expectEqual(w.line, g.line);
        try testing.expectEqual(w.kind, g.kind);
    }
}

test "gitdiff: pure insertion is added" {
    try expectMarks(
        \\diff --git a/x b/x
        \\--- a/x
        \\+++ b/x
        \\@@ -3,0 +4,2 @@
        \\+one
        \\+two
        \\
    , &.{
        .{ .line = 3, .kind = .added },
        .{ .line = 4, .kind = .added },
    });
}

test "gitdiff: pure deletion marks the surviving line" {
    try expectMarks(
        \\@@ -5,2 +4,0 @@
        \\-gone
        \\-also gone
        \\
    , &.{.{ .line = 4, .kind = .deleted }});
}

test "gitdiff: a replaced line is modified, not added plus deleted" {
    try expectMarks(
        \\@@ -7,1 +7,1 @@
        \\-old
        \\+new
        \\
    , &.{.{ .line = 6, .kind = .modified }});
}

test "gitdiff: surplus new lines after a replacement are added" {
    try expectMarks(
        \\@@ -7,1 +7,3 @@
        \\-old
        \\+new
        \\+extra
        \\+more
        \\
    , &.{
        .{ .line = 6, .kind = .modified },
        .{ .line = 7, .kind = .added },
        .{ .line = 8, .kind = .added },
    });
}

test "gitdiff: surplus removed lines leave a deletion mark" {
    try expectMarks(
        \\@@ -7,3 +7,1 @@
        \\-a
        \\-b
        \\-c
        \\+one
        \\
    , &.{
        .{ .line = 6, .kind = .modified },
        .{ .line = 7, .kind = .deleted },
    });
}

test "gitdiff: context lines are counted but never marked" {
    try expectMarks(
        \\@@ -1,4 +1,4 @@
        \\ keep
        \\-old
        \\+new
        \\ keep
        \\ keep
        \\
    , &.{.{ .line = 1, .kind = .modified }});
}

test "gitdiff: payload that looks like framing stays payload" {
    // The hunk counts bound the body, so "--- x" and "+++ y" inside it
    // are a removed and an added line, not file headers.
    try expectMarks(
        \\@@ -1,1 +1,1 @@
        \\--- x
        \\+++ y
        \\@@ -9,0 +10,1 @@
        \\+tail
        \\
    , &.{
        .{ .line = 0, .kind = .modified },
        .{ .line = 9, .kind = .added },
    });
}

test "gitdiff: no-newline annotation does not consume the budget" {
    try expectMarks(
        \\@@ -1,1 +1,1 @@
        \\-a
        \\\ No newline at end of file
        \\+b
        \\
    , &.{.{ .line = 0, .kind = .modified }});
}

test "gitdiff: an empty or non-diff payload yields nothing" {
    try expectMarks("", &.{});
    try expectMarks("fatal: not a git repository\n", &.{});
}

test "gitdiff: runs collapse consecutive same-kind lines and round-trip" {
    const lines = try parseUnified(testing.allocator,
        \\@@ -7,1 +7,3 @@
        \\-old
        \\+new
        \\+extra
        \\+more
        \\@@ -20,2 +22,0 @@
        \\-a
        \\-b
        \\
    );
    defer testing.allocator.free(lines);
    const runs = try runsFromLines(testing.allocator, lines);
    defer testing.allocator.free(runs);
    // modified@6 x1, added@7 x2, deleted@22 x1 — three records for
    // four marks, and the two added lines never travel separately.
    try testing.expectEqual(@as(usize, 3), runs.len);
    try testing.expectEqual(Run{ .line = 6, .count = 1, .kind = .modified }, runs[0]);
    try testing.expectEqual(Run{ .line = 7, .count = 2, .kind = .added }, runs[1]);
    try testing.expectEqual(Kind.deleted, runs[2].kind);
    try testing.expectEqual(@as(u32, 1), runs[2].count);

    const back = try linesFromRuns(testing.allocator, runs);
    defer testing.allocator.free(back);
    try testing.expectEqual(lines.len, back.len);
    for (lines, back) |a, b| {
        try testing.expectEqual(a.line, b.line);
        try testing.expectEqual(a.kind, b.kind);
    }
}

test "gitdiff: kind names survive the wire spelling" {
    for ([_]Kind{ .added, .modified, .deleted }) |k| {
        try testing.expectEqual(k, kindFromName(kindName(k)).?);
    }
    try testing.expectEqual(@as(?Kind, null), kindFromName("renamed"));
    try testing.expectEqual(@as(?Kind, null), kindFromName(""));
}

fn openDoc(bytes: []const u8) !Document {
    return Document.initFromBytes(testing.allocator, bytes);
}

test "gitdiff: marks anchor to line starts and dedupe per line" {
    var doc = try openDoc("aaa\nbbb\nccc\nddd\n");
    defer doc.deinit();
    var marks = Marks.init(testing.allocator);
    defer marks.deinit();
    try marks.setFromLines(&doc, &.{
        .{ .line = 2, .kind = .deleted },
        .{ .line = 2, .kind = .modified },
        .{ .line = 0, .kind = .added },
    });
    try testing.expect(marks.known);
    try testing.expectEqual(@as(usize, 2), marks.list.items.len);
    try testing.expectEqual(@as(usize, 0), marks.list.items[0].anchor);
    try testing.expectEqual(Kind.added, marks.list.items[0].kind);
    try testing.expectEqual(@as(usize, 8), marks.list.items[1].anchor);
    // The informative kind wins over the deletion tick on a shared line.
    try testing.expectEqual(Kind.modified, marks.list.items[1].kind);
}

test "gitdiff: marks past the end clamp onto the last line" {
    var doc = try openDoc("one\ntwo\n");
    defer doc.deinit();
    var marks = Marks.init(testing.allocator);
    defer marks.deinit();
    try marks.setFromLines(&doc, &.{.{ .line = 99, .kind = .deleted }});
    try testing.expectEqual(@as(usize, 1), marks.list.items.len);
    try testing.expect(marks.list.items[0].anchor <= doc.rope.len());
}

test "gitdiff: an edit above a mark carries it down" {
    var doc = try openDoc("aaa\nbbb\nccc\n");
    defer doc.deinit();
    var marks = Marks.init(testing.allocator);
    defer marks.deinit();
    try marks.setFromLines(&doc, &.{.{ .line = 2, .kind = .modified }});
    const before = marks.list.items[0].anchor;
    const edits = [_]tr.Edit{.{ .offset = 0, .deleted_len = 0, .inserted = "zz\n" }};
    marks.mapThrough(&edits);
    try testing.expectEqual(before + 3, marks.list.items[0].anchor);
}

test "gitdiff: hunk navigation groups consecutive lines and wraps" {
    var doc = try openDoc("l0\nl1\nl2\nl3\nl4\nl5\nl6\n");
    defer doc.deinit();
    var marks = Marks.init(testing.allocator);
    defer marks.deinit();
    try marks.setFromLines(&doc, &.{
        .{ .line = 1, .kind = .added },
        .{ .line = 2, .kind = .added },
        .{ .line = 5, .kind = .modified },
    });
    try testing.expectEqual(@as(usize, 2), marks.hunkCount(&doc));
    const l1 = doc.rope.lineToOffset(1);
    const l5 = doc.rope.lineToOffset(5);
    try testing.expectEqual(l1, marks.nextHunk(&doc, 0, true).?);
    try testing.expectEqual(l5, marks.nextHunk(&doc, l1, true).?);
    // Past the last hunk, forward wraps to the first.
    try testing.expectEqual(l1, marks.nextHunk(&doc, doc.rope.len(), true).?);
    try testing.expectEqual(l1, marks.nextHunk(&doc, l5, false).?);
    // Before the first hunk, backward wraps to the last.
    try testing.expectEqual(l5, marks.nextHunk(&doc, 0, false).?);
}

test "gitdiff: allAdded covers every line of an untracked file" {
    var doc = try openDoc("a\nb\nc\n");
    defer doc.deinit();
    const marks = try allAdded(testing.allocator, &doc);
    defer testing.allocator.free(marks);
    try testing.expectEqual(doc.rope.lineCount(), marks.len);
    try testing.expectEqual(Kind.added, marks[0].kind);
}
