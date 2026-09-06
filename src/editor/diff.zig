//! Minimal-edit diffing for the history-preserving external reload.
//!
//! `reloadFromBytes` applies the on-disk content to an EXISTING
//! Document as ONE transaction instead of replacing the document, so
//! undo walks back through the reload to the pre-reload text and every
//! edit observer (highlighter, folds, LSP, a11y) sees ordinary edits.
//!
//! The diff is common-prefix/suffix trimming (linear, snapped to UTF-8
//! codepoint boundaries) followed by line-granularity Myers on the
//! middle. Myers is O((N+M)*D) time and O(D^2) space with N+M capped
//! at `MAX_DIFF_LINES` and D at `MAX_D`; past either cap the middle
//! collapses to one replace edit, so a 100MB reload costs one linear
//! scan plus bounded constants, never a quadratic blowup.

const std = @import("std");
const Allocator = std.mem.Allocator;
const doc_mod = @import("document.zig");
const Document = doc_mod.Document;
const tr = @import("transaction.zig");
const sel_mod = @import("selection.zig");
const SelectionSet = sel_mod.SelectionSet;

/// Middle-region line-count cap (old + new) for the Myers walk.
pub const MAX_DIFF_LINES: usize = 50_000;
/// Edit-distance cap; the trace stores O(MAX_D^2) words.
pub const MAX_D: usize = 512;

fn isCont(b: u8) bool {
    return b & 0xC0 == 0x80;
}

/// Minimal-ish edit list turning `old` into `new`, sorted and
/// non-overlapping, offsets in `old` coordinates. Inserted slices
/// BORROW `new`. Caller frees the returned slice.
pub fn diff(alloc: Allocator, old: []const u8, new: []const u8) ![]tr.Edit {
    return diffWithLimits(alloc, old, new, MAX_DIFF_LINES, MAX_D);
}

pub fn diffWithLimits(
    alloc: Allocator,
    old: []const u8,
    new: []const u8,
    max_lines: usize,
    max_d: usize,
) ![]tr.Edit {
    // Common prefix, snapped back to a codepoint boundary so no edit
    // offset ever splits a UTF-8 sequence (LSP position conversion and
    // selection mapping both assume valid boundaries).
    const min_len = @min(old.len, new.len);
    var p: usize = 0;
    while (p < min_len and old[p] == new[p]) : (p += 1) {}
    while (p > 0 and p < old.len and isCont(old[p])) : (p -= 1) {}

    // Common suffix over the remainder; the compared bytes are equal,
    // so a boundary snap in `old` is one in `new` too.
    var s: usize = 0;
    while (s < min_len - p and old[old.len - 1 - s] == new[new.len - 1 - s]) : (s += 1) {}
    while (s > 0 and isCont(old[old.len - s])) : (s -= 1) {}

    const mid_old = old[p .. old.len - s];
    const mid_new = new[p .. new.len - s];
    if (mid_old.len == 0 and mid_new.len == 0) return &.{};

    var out: std.ArrayList(tr.Edit) = .empty;
    errdefer out.deinit(alloc);

    if (mid_old.len == 0 or mid_new.len == 0) {
        try out.append(alloc, .{ .offset = p, .deleted_len = mid_old.len, .inserted = mid_new });
        return out.toOwnedSlice(alloc);
    }

    if (try lineMyers(alloc, &out, p, mid_old, mid_new, max_lines, max_d)) {
        return out.toOwnedSlice(alloc);
    }
    // Too large or too different: one honest replace of the middle.
    out.clearRetainingCapacity();
    try out.append(alloc, .{ .offset = p, .deleted_len = mid_old.len, .inserted = mid_new });
    return out.toOwnedSlice(alloc);
}

const Line = struct { start: usize, end: usize, hash: u64 };

fn splitLines(alloc: Allocator, text: []const u8) !std.ArrayList(Line) {
    var lines: std.ArrayList(Line) = .empty;
    errdefer lines.deinit(alloc);
    var start: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\n') {
            try lines.append(alloc, .{
                .start = start,
                .end = i + 1,
                .hash = std.hash.Wyhash.hash(0, text[start .. i + 1]),
            });
            start = i + 1;
        }
    }
    if (start < text.len) {
        try lines.append(alloc, .{
            .start = start,
            .end = text.len,
            .hash = std.hash.Wyhash.hash(0, text[start..]),
        });
    }
    return lines;
}

fn linesEq(a_text: []const u8, a: Line, b_text: []const u8, b: Line) bool {
    if (a.hash != b.hash) return false;
    return std.mem.eql(u8, a_text[a.start..a.end], b_text[b.start..b.end]);
}

/// Line-granularity Myers over the trimmed middle. Appends coalesced
/// edits (absolute offsets via `base`) to `out` and returns true, or
/// returns false when a cap is exceeded (caller falls back).
fn lineMyers(
    alloc: Allocator,
    out: *std.ArrayList(tr.Edit),
    base: usize,
    old: []const u8,
    new: []const u8,
    max_lines: usize,
    max_d: usize,
) !bool {
    var a = try splitLines(alloc, old);
    defer a.deinit(alloc);
    var b = try splitLines(alloc, new);
    defer b.deinit(alloc);
    const n = a.items.len;
    const m = b.items.len;
    if (n + m > max_lines) return false;
    const cap = @min(max_d, n + m);

    // Forward Myers with a full trace (one V snapshot per d).
    const width = 2 * cap + 1;
    var trace: std.ArrayList([]isize) = .empty;
    defer {
        for (trace.items) |v| alloc.free(v);
        trace.deinit(alloc);
    }
    var v = try alloc.alloc(isize, width);
    defer alloc.free(v);
    @memset(v, 0);

    const off: isize = @intCast(cap);
    var found_d: ?usize = null;
    var d: usize = 0;
    outer: while (d <= cap) : (d += 1) {
        var k: isize = -@as(isize, @intCast(d));
        while (k <= @as(isize, @intCast(d))) : (k += 2) {
            var x: isize = undefined;
            if (k == -@as(isize, @intCast(d)) or
                (k != @as(isize, @intCast(d)) and v[@intCast(k - 1 + off)] < v[@intCast(k + 1 + off)]))
            {
                x = v[@intCast(k + 1 + off)];
            } else {
                x = v[@intCast(k - 1 + off)] + 1;
            }
            var y = x - k;
            while (x < @as(isize, @intCast(n)) and y < @as(isize, @intCast(m)) and
                linesEq(old, a.items[@intCast(x)], new, b.items[@intCast(y)]))
            {
                x += 1;
                y += 1;
            }
            v[@intCast(k + off)] = x;
            if (x >= @as(isize, @intCast(n)) and y >= @as(isize, @intCast(m))) {
                // The snapshot is only owned once the append takes it;
                // a failing append would otherwise drop it on the floor.
                const snap = try alloc.dupe(isize, v);
                errdefer alloc.free(snap);
                try trace.append(alloc, snap);
                found_d = d;
                break :outer;
            }
        }
        const snap = try alloc.dupe(isize, v);
        errdefer alloc.free(snap);
        try trace.append(alloc, snap);
    }
    const final_d = found_d orelse return false;

    // Backtrack into a reversed op list, then walk it forward building
    // coalesced delete+insert hunks.
    const Op = enum { eq, del, ins };
    var ops: std.ArrayList(Op) = .empty;
    defer ops.deinit(alloc);
    var x: isize = @intCast(n);
    var y: isize = @intCast(m);
    var dd: usize = final_d;
    while (dd > 0) : (dd -= 1) {
        const pv = trace.items[dd - 1];
        const k = x - y;
        const took_down = (k == -@as(isize, @intCast(dd)) or
            (k != @as(isize, @intCast(dd)) and pv[@intCast(k - 1 + off)] < pv[@intCast(k + 1 + off)]));
        const pk = if (took_down) k + 1 else k - 1;
        const px = pv[@intCast(pk + off)];
        const py = px - pk;
        // The snake (equal run) after the step.
        const step_x: isize = if (took_down) px else px + 1;
        const step_y: isize = if (took_down) py + 1 else py;
        while (x > step_x and y > step_y) {
            try ops.append(alloc, .eq);
            x -= 1;
            y -= 1;
        }
        try ops.append(alloc, if (took_down) .ins else .del);
        x = px;
        y = py;
    }
    while (x > 0 and y > 0) {
        try ops.append(alloc, .eq);
        x -= 1;
        y -= 1;
    }
    std.debug.assert(x == 0 and y == 0);
    std.mem.reverse(Op, ops.items);

    var ai: usize = 0;
    var bi: usize = 0;
    var hunk_a0: usize = 0;
    var hunk_b0: usize = 0;
    var in_hunk = false;
    for (ops.items) |op| {
        switch (op) {
            .eq => {
                if (in_hunk) {
                    try appendHunk(alloc, out, base, old, a.items, new, b.items, hunk_a0, ai, hunk_b0, bi);
                    in_hunk = false;
                }
                ai += 1;
                bi += 1;
            },
            .del => {
                if (!in_hunk) {
                    hunk_a0 = ai;
                    hunk_b0 = bi;
                    in_hunk = true;
                }
                ai += 1;
            },
            .ins => {
                if (!in_hunk) {
                    hunk_a0 = ai;
                    hunk_b0 = bi;
                    in_hunk = true;
                }
                bi += 1;
            },
        }
    }
    if (in_hunk) {
        try appendHunk(alloc, out, base, old, a.items, new, b.items, hunk_a0, ai, hunk_b0, bi);
    }
    return true;
}

fn appendHunk(
    alloc: Allocator,
    out: *std.ArrayList(tr.Edit),
    base: usize,
    old: []const u8,
    a: []const Line,
    new: []const u8,
    b: []const Line,
    a0: usize,
    a1: usize,
    b0: usize,
    b1: usize,
) !void {
    const del_start = if (a0 < a.len) a[a0].start else old.len;
    const del_end = if (a1 > a0) a[a1 - 1].end else del_start;
    const ins_start = if (b0 < b.len) b[b0].start else new.len;
    const ins_end = if (b1 > b0) b[b1 - 1].end else ins_start;
    try out.append(alloc, .{
        .offset = base + del_start,
        .deleted_len = del_end - del_start,
        .inserted = new[ins_start..ins_end],
    });
}

// ---- the reload itself ------------------------------------------------

/// Replace `doc`'s content with raw file bytes `raw` as ONE undoable
/// transaction. Detects the new line-ending style (the style is
/// document metadata and is NOT covered by undo), maps `sels` through
/// the edits when given, and re-baselines the saved revision — the
/// buffer reads clean afterwards, and dirty again after an undo.
/// @return whether anything changed.
pub fn reloadFromBytes(
    alloc: Allocator,
    doc: *Document,
    raw: []const u8,
    sels: ?*SelectionSet,
) !bool {
    const style = Document.detectStyle(raw);
    const norm = try Document.normalizeBytes(alloc, raw, style);
    defer alloc.free(norm);
    const old = try doc.textAlloc(alloc);
    defer alloc.free(old);

    const edits = try diff(alloc, old, norm);
    defer if (edits.len > 0) alloc.free(edits);
    if (edits.len == 0) {
        doc.line_ending = style;
        doc.markSaved();
        return false;
    }

    // A reload must be its own undo unit: never let a live typing
    // group swallow a single-insert diff.
    doc.breakUndoGroup();
    var tx = tr.Transaction.init(doc.revision);
    defer tx.deinit(alloc);
    for (edits) |e| try tx.addEdit(alloc, e);
    const snap: ?doc_mod.SelSnapshot = if (sels) |set|
        .{ .sels = set.sels.items, .primary = set.primary_index }
    else
        null;
    _ = try doc.applyTransactionSel(&tx, snap);
    // Only now: a failure above leaves the OLD content, and switching
    // the style anyway would have made the next save rewrite every line
    // ending of a file the user never edited.
    doc.line_ending = style;
    if (sels) |set| set.mapThrough(edits, .other);
    doc.markSaved();
    return true;
}

// ======================================================================
// Tests
// ======================================================================

const testing = std.testing;

fn applyEditsToString(alloc: Allocator, old: []const u8, edits: []const tr.Edit) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var pos: usize = 0;
    for (edits) |e| {
        try out.appendSlice(alloc, old[pos..e.offset]);
        try out.appendSlice(alloc, e.inserted);
        pos = e.offset + e.deleted_len;
    }
    try out.appendSlice(alloc, old[pos..]);
    return out.toOwnedSlice(alloc);
}

fn expectDiffRoundTrip(old: []const u8, new: []const u8, max_edits: ?usize) !usize {
    const a = testing.allocator;
    const edits = try diff(a, old, new);
    defer if (edits.len > 0) a.free(edits);
    try tr.validateEdits(edits, old.len);
    const got = try applyEditsToString(a, old, edits);
    defer a.free(got);
    try testing.expectEqualStrings(new, got);
    if (max_edits) |cap| try testing.expect(edits.len <= cap);
    return edits.len;
}

test "diff: identical text yields no edits" {
    try testing.expectEqual(@as(usize, 0), try expectDiffRoundTrip("abc\ndef\n", "abc\ndef\n", null));
    try testing.expectEqual(@as(usize, 0), try expectDiffRoundTrip("", "", null));
}

test "diff: single-line change is one local edit" {
    const old = "one\ntwo\nthree\nfour\n";
    const new = "one\nTWO!\nthree\nfour\n";
    const n = try expectDiffRoundTrip(old, new, 1);
    try testing.expectEqual(@as(usize, 1), n);
    // And the edit really is local: it must not span the untouched tail.
    const edits = try diff(testing.allocator, old, new);
    defer testing.allocator.free(edits);
    try testing.expect(edits[0].offset >= 4);
    try testing.expect(edits[0].offset + edits[0].deleted_len <= 9);
}

test "diff: insertions, deletions, edge lines" {
    _ = try expectDiffRoundTrip("a\nb\nc\n", "a\nX\nb\nc\n", 1);
    _ = try expectDiffRoundTrip("a\nb\nc\n", "b\nc\n", 1);
    _ = try expectDiffRoundTrip("a\nb\nc\n", "a\nb\n", 1);
    _ = try expectDiffRoundTrip("", "hello\n", 1);
    _ = try expectDiffRoundTrip("hello\n", "", 1);
    _ = try expectDiffRoundTrip("no trailing newline", "no trailing newline!", 1);
}

test "diff: two separated changes stay two edits" {
    const old = "l1\nl2\nl3\nl4\nl5\nl6\n";
    const new = "l1\nXX\nl3\nl4\nYY\nl6\n";
    const n = try expectDiffRoundTrip(old, new, 2);
    try testing.expectEqual(@as(usize, 2), n);
}

test "diff: multibyte boundary is never split" {
    // The prefix scan stops INSIDE the é (C3 A9 vs C3 A8 share C3).
    const old = "caf\u{e9} au lait";
    const new = "caf\u{e8} au lait";
    const a = testing.allocator;
    const edits = try diff(a, old, new);
    defer a.free(edits);
    for (edits) |e| {
        try testing.expect(!isCont(old[e.offset]));
        if (e.offset + e.deleted_len < old.len)
            try testing.expect(!isCont(old[e.offset + e.deleted_len]));
    }
    const got = try applyEditsToString(a, old, edits);
    defer a.free(got);
    try testing.expectEqualStrings(new, got);
}

test "diff: capped input falls back to one replace, still correct" {
    const a = testing.allocator;
    // Force the fallback with tiny limits.
    const old = "a\nb\nc\nd\ne\n";
    const new = "e\nd\nc\nb\na\n";
    const edits = try diffWithLimits(a, old, new, 4, 1);
    defer a.free(edits);
    try testing.expectEqual(@as(usize, 1), edits.len);
    const got = try applyEditsToString(a, old, edits);
    defer a.free(got);
    try testing.expectEqualStrings(new, got);
}

test "diff: randomized round-trips" {
    const a = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xd1ff);
    const rand = prng.random();
    var round: usize = 0;
    while (round < 50) : (round += 1) {
        var old_buf: std.ArrayList(u8) = .empty;
        defer old_buf.deinit(a);
        var new_buf: std.ArrayList(u8) = .empty;
        defer new_buf.deinit(a);
        const lines = 1 + rand.uintLessThan(usize, 30);
        var i: usize = 0;
        while (i < lines) : (i += 1) {
            var line_buf: [8]u8 = undefined;
            const line = std.fmt.bufPrint(&line_buf, "l{d}\n", .{rand.uintLessThan(usize, 9)}) catch unreachable;
            try old_buf.appendSlice(a, line);
            if (rand.uintLessThan(usize, 4) != 0) try new_buf.appendSlice(a, line);
            if (rand.uintLessThan(usize, 4) == 0) try new_buf.appendSlice(a, "n\n");
        }
        const edits = try diff(a, old_buf.items, new_buf.items);
        defer if (edits.len > 0) a.free(edits);
        try tr.validateEdits(edits, old_buf.items.len);
        const got = try applyEditsToString(a, old_buf.items, edits);
        defer a.free(got);
        try testing.expectEqualStrings(new_buf.items, got);
    }
}

test "reloadFromBytes: undo restores the pre-reload text exactly" {
    const a = testing.allocator;
    var doc = try Document.initFromBytes(a, "alpha\nbeta\ngamma\n");
    defer doc.deinit();

    const changed = try reloadFromBytes(a, &doc, "alpha\nBETA\ngamma\ndelta\n", null);
    try testing.expect(changed);
    try testing.expect(!doc.isDirty());
    {
        const txt = try doc.textAlloc(a);
        defer a.free(txt);
        try testing.expectEqualStrings("alpha\nBETA\ngamma\ndelta\n", txt);
    }
    // ONE undo unit, no matter how many hunks the diff produced.
    _ = try doc.undo();
    {
        const txt = try doc.textAlloc(a);
        defer a.free(txt);
        try testing.expectEqualStrings("alpha\nbeta\ngamma\n", txt);
    }
    try testing.expect(doc.isDirty()); // the pre-reload text is not on disk
    // Redo returns to the reloaded content.
    _ = try doc.redo();
    {
        const txt = try doc.textAlloc(a);
        defer a.free(txt);
        try testing.expectEqualStrings("alpha\nBETA\ngamma\ndelta\n", txt);
    }
}

test "reloadFromBytes: prior undo history survives the reload" {
    const a = testing.allocator;
    var doc = try Document.initFromBytes(a, "one\ntwo\n");
    defer doc.deinit();
    var tx = tr.Transaction.init(doc.revision);
    defer tx.deinit(a);
    try tx.addInsert(a, 8, "three\n");
    _ = try doc.applyTransaction(&tx);

    _ = try reloadFromBytes(a, &doc, "ONE\ntwo\nthree\n", null);
    _ = try doc.undo(); // the reload
    _ = try doc.undo(); // the user's own edit
    const txt = try doc.textAlloc(a);
    defer a.free(txt);
    try testing.expectEqualStrings("one\ntwo\n", txt);
}

test "reloadFromBytes: a live typing group is not extended" {
    const a = testing.allocator;
    var doc = Document.initEmpty(a);
    defer doc.deinit();
    for ("abc", 0..) |_, i| {
        var tx = tr.Transaction.init(doc.revision);
        defer tx.deinit(a);
        try tx.addInsert(a, i, "abc"[i .. i + 1]);
        _ = try doc.applyTransaction(&tx);
    }
    // Disk gained one character at the exact typing end — the shape
    // that would coalesce if the reload did not break the group.
    _ = try reloadFromBytes(a, &doc, "abcd", null);
    _ = try doc.undo();
    {
        const txt = try doc.textAlloc(a);
        defer a.free(txt);
        try testing.expectEqualStrings("abc", txt);
    }
    _ = try doc.undo();
    const txt = try doc.textAlloc(a);
    defer a.free(txt);
    try testing.expectEqualStrings("", txt);
}

test "reloadFromBytes: selections map through, style re-detected" {
    const a = testing.allocator;
    const Selection = sel_mod.Selection;
    var doc = try Document.initFromBytes(a, "aaa\nbbb\nccc\n");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, Selection.caret(9)); // in "ccc"
    defer sels.deinit(a);

    // The new file inserts a line above the caret and is CRLF.
    _ = try reloadFromBytes(a, &doc, "aaa\r\nNEW\r\nbbb\r\nccc\r\n", &sels);
    try testing.expectEqual(doc_mod.LineEnding.crlf, doc.line_ending);
    // Caret still sits at the 'c' line start (+4 for the inserted line).
    try testing.expectEqual(@as(usize, 13), sels.primary().head);
    const out = try doc.materialize(a);
    defer a.free(out);
    try testing.expectEqualStrings("aaa\r\nNEW\r\nbbb\r\nccc\r\n", out);
}

test "reloadFromBytes: a failed reload keeps the old style with the old text" {
    // The style was assigned before the fallible diff+apply, so a
    // failure left LF content declared CRLF and the next save rewrote
    // every line ending of a file the user never edited.
    // Backed by an arena, not the testing allocator: `Rope.insert` and
    // `Rope.delete` null the root before their fallible split/join and
    // are therefore NOT allocation-atomic, which is a separate defect
    // this test is not about. The arena keeps that from masquerading as
    // a leak here.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var idx: usize = 0;
    var saw_failure = false;
    while (idx < 60) : (idx += 1) {
        var failing = std.testing.FailingAllocator.init(arena.allocator(), .{ .fail_index = idx });
        const a = failing.allocator();
        var doc = Document.initFromBytes(a, "alpha\nbeta\ngamma\n") catch continue;
        defer doc.deinit();
        const before = doc.textAlloc(testing.allocator) catch continue;
        defer testing.allocator.free(before);

        _ = reloadFromBytes(a, &doc, "alpha\r\nBETA\r\ngamma\r\n", null) catch {
            saw_failure = true;
            const after = doc.textAlloc(testing.allocator) catch continue;
            defer testing.allocator.free(after);
            // Whatever failed, style and content must still agree.
            if (std.mem.eql(u8, before, after))
                try testing.expectEqual(doc_mod.LineEnding.lf, doc.line_ending);
            continue;
        };
        try testing.expectEqual(doc_mod.LineEnding.crlf, doc.line_ending);
    }
    try testing.expect(saw_failure);
}

test "reloadFromBytes: identical content is a no-op that re-baselines" {
    const a = testing.allocator;
    var doc = try Document.initFromBytes(a, "same\n");
    defer doc.deinit();
    const rev = doc.revision;
    try testing.expect(!try reloadFromBytes(a, &doc, "same\n", null));
    try testing.expectEqual(rev, doc.revision);
    try testing.expect(!doc.canUndo());
}
