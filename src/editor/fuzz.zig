//! Randomized property tests for the editor text core.
//!
//! Drives `Document` through long sequences of multi-edit transactions
//! interleaved with undo/redo and checks every step against an
//! ArrayList-of-bytes oracle plus recomputed line/Unicode facts. The
//! rope's own fuzz test (rope.zig) covers the tree in isolation; this
//! one covers the layers above it — transaction application order,
//! history, selection mapping and boundary queries.
//!
//! Determinism: every run is seeded and the seed is printed on failure.
//! `SKETERM_EDITOR_FUZZ_SEED` overrides the base seed and
//! `SKETERM_EDITOR_FUZZ_STEPS` the per-seed step count, so a failing
//! case reproduces exactly and a soak run is one env var away:
//!
//!     SKETERM_EDITOR_FUZZ_STEPS=200000 zig build test-core
//!
//! Gotcha: the model tracks undo/redo depth by watching
//! `doc.undo_stack.items.len`, because typing coalescing decides
//! whether a transaction opens a new history entry. That is the ONLY
//! thing read out of the document's internals — the text, line index,
//! selections and boundaries are all checked against independent
//! recomputation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const rope_mod = @import("rope.zig");
const Rope = rope_mod.Rope;
const doc_mod = @import("document.zig");
const Document = doc_mod.Document;
const tr = @import("transaction.zig");
const sel_mod = @import("selection.zig");
const Selection = sel_mod.Selection;
const SelectionSet = sel_mod.SelectionSet;
const uni = @import("unicode.zig");

fn envUsize(name: [*:0]const u8, fallback: usize) usize {
    const raw = std.c.getenv(name) orelse return fallback;
    return std.fmt.parseInt(usize, std.mem.span(raw), 10) catch fallback;
}

/// Insertion payloads: ASCII, newlines, CRLF pairs, 2/3/4-byte
/// sequences, a regional-indicator pair, a combining sequence, NUL and
/// a lone continuation byte (so edits can land mid-sequence).
const PIECES = [_][]const u8{
    "a",           "hello",  " ",          "\n",             "\n\n",
    "\r\n",        "\r",     "\t",         "\u{e9}",         "\u{4e2d}\u{6587}",
    "\u{1F600}",   "e\u{301}", "\u{1F1E7}\u{1F1EA}", "\x00", "\x80",
    "\xff\xfe",    "x\ny\nz", "line of text with spaces\n",
};

/// UTF-8-only subset, for the run that keeps the document valid.
const UTF8_PIECES = [_][]const u8{
    "a",         "hello world", " ",        "\n",       "\n\n",
    "\t",        "\u{e9}",      "\u{4e2d}\u{6587}\u{3053}", "\u{1F600}\u{1F680}",
    "e\u{301}",  "\u{1F1E7}\u{1F1EA}",      "\u{1F469}\u{200D}\u{1F4BB}",
    "\u{d55c}\u{ad6d}\u{c5b4}", "fn main() void {\n    return;\n}\n",
};

const Config = struct {
    /// Keep the document valid UTF-8: edits snap to codepoint
    /// boundaries and only UTF-8 pieces are inserted.
    utf8_only: bool = false,
    steps: usize,
    seed: u64,
    /// Soft cap; when the text grows past this, edits skew to deletes.
    max_len: usize = 24 * 1024,
    /// Start from a CRLF-majority file, so the document runs in .crlf
    /// mode and every step also checks the materialize round trip.
    crlf_seed: bool = false,
};

// ---- oracle -----------------------------------------------------------

const Model = struct {
    alloc: Allocator,
    text: std.ArrayList(u8) = .empty,
    /// Text to return to when undoing entry i (parallel to the
    /// document's undo stack).
    undo_snaps: std.ArrayList([]u8) = .empty,
    /// Text to return to when redoing entry i.
    redo_snaps: std.ArrayList([]u8) = .empty,

    fn deinit(self: *Model) void {
        self.text.deinit(self.alloc);
        for (self.undo_snaps.items) |s| self.alloc.free(s);
        self.undo_snaps.deinit(self.alloc);
        for (self.redo_snaps.items) |s| self.alloc.free(s);
        self.redo_snaps.deinit(self.alloc);
    }

    fn snapshot(self: *Model) ![]u8 {
        return try self.alloc.dupe(u8, self.text.items);
    }

    fn clearRedo(self: *Model) void {
        for (self.redo_snaps.items) |s| self.alloc.free(s);
        self.redo_snaps.clearRetainingCapacity();
    }

    /// Applies the edit list the same way the document must: back to
    /// front, in pre-transaction coordinates.
    fn apply(self: *Model, edits: []const tr.Edit) !void {
        var i = edits.len;
        while (i > 0) {
            i -= 1;
            const e = edits[i];
            try self.text.replaceRange(self.alloc, e.offset, e.deleted_len, e.inserted);
        }
    }
};

// ---- generators -------------------------------------------------------

fn isCharBoundary(text: []const u8, i: usize) bool {
    if (i == 0 or i >= text.len) return true;
    return text[i] & 0xC0 != 0x80;
}

fn snapDown(text: []const u8, i: usize) usize {
    var j = @min(i, text.len);
    while (!isCharBoundary(text, j)) j -= 1;
    return j;
}

/// Builds a sorted, non-overlapping edit list over `text`. Offsets are
/// biased toward document start/end, line boundaries and (when not in
/// utf8_only mode) the middles of multi-byte sequences.
fn genEdits(
    arena: Allocator,
    rand: std.Random,
    text: []const u8,
    cfg: Config,
    tx: *tr.Transaction,
) !void {
    const nedits = rand.intRangeAtMost(usize, 1, 4);
    var cursor: usize = 0;
    const shrink = text.len > cfg.max_len;
    var n: usize = 0;
    while (n < nedits and cursor <= text.len) : (n += 1) {
        if (cursor > text.len) break;
        // Pick an offset at or after the cursor.
        var off: usize = switch (rand.intRangeAtMost(u8, 0, 9)) {
            0 => cursor, // adjacent to the previous edit
            1 => text.len, // document end
            2 => blk: { // a line boundary
                var k = rand.intRangeAtMost(usize, cursor, text.len);
                while (k < text.len and text[k] != '\n') k += 1;
                break :blk k;
            },
            else => rand.intRangeAtMost(usize, cursor, text.len),
        };
        if (cfg.utf8_only) off = @max(cursor, snapDown(text, off));
        if (off < cursor) off = cursor;

        const roll = rand.intRangeAtMost(u8, 0, 99);
        var del: usize = 0;
        var ins: []const u8 = "";
        if (roll < 5) {
            // Empty edit: legal, and must be a no-op.
        } else if (roll < (if (shrink) @as(u8, 80) else @as(u8, 35))) {
            const cap: usize = if (shrink) 4000 else 300;
            del = rand.intRangeAtMost(usize, 0, @min(text.len - off, cap));
        } else if (shrink or roll < 85) {
            ins = PIECES[rand.uintLessThan(usize, PIECES.len)];
            if (cfg.utf8_only) ins = UTF8_PIECES[rand.uintLessThan(usize, UTF8_PIECES.len)];
        } else if (roll < 95) {
            // Replace.
            del = rand.intRangeAtMost(usize, 0, @min(text.len - off, 120));
            ins = PIECES[rand.uintLessThan(usize, PIECES.len)];
            if (cfg.utf8_only) ins = UTF8_PIECES[rand.uintLessThan(usize, UTF8_PIECES.len)];
        } else {
            // A big insert, to force multi-leaf rope paths.
            const big = try arena.alloc(u8, rand.intRangeAtMost(usize, 1024, 6000));
            for (big, 0..) |*b, i| b.* = if (i % 71 == 0) '\n' else @intCast('a' + (i % 26));
            ins = big;
        }
        if (cfg.utf8_only and del > 0) {
            var end = snapDown(text, off + del);
            if (end < off) end = off;
            del = end - off;
        }
        try tx.addEdit(arena, .{ .offset = off, .deleted_len = del, .inserted = ins });
        cursor = off + del;
        if (cursor >= text.len) break;
    }
}

// ---- property checks --------------------------------------------------

fn checkText(doc: *const Document, model: *const Model, seed: u64, step: usize) !void {
    const got = try doc.textAlloc(testing.allocator);
    defer testing.allocator.free(got);
    if (!std.mem.eql(u8, got, model.text.items)) {
        std.debug.print("fuzz mismatch: seed={x} step={d}\n", .{ seed, step });
        return error.TextMismatch;
    }
}

/// The rope's line index must agree with a naive recount, at random
/// offsets and lines.
fn checkLineIndex(doc: *const Document, model: *const Model, rand: std.Random) !void {
    const text = model.text.items;
    const expect_lines = std.mem.count(u8, text, "\n") + 1;
    try testing.expectEqual(expect_lines, doc.rope.lineCount());
    try testing.expectEqual(text.len, doc.rope.len());

    var probe: usize = 0;
    while (probe < 4) : (probe += 1) {
        const off = rand.intRangeAtMost(usize, 0, text.len);
        const expect_line = std.mem.count(u8, text[0..off], "\n");
        try testing.expectEqual(expect_line, doc.rope.newlinesBefore(off));
        const lc = doc.rope.offsetToLineCol(off);
        try testing.expectEqual(expect_line, lc.line);
        var start = off;
        while (start > 0 and text[start - 1] != '\n') start -= 1;
        try testing.expectEqual(start, doc.rope.lineToOffset(lc.line));
        try testing.expectEqual(off - start, lc.col);

        // lineToOffset is the inverse for line starts.
        const line = rand.uintLessThan(usize, expect_lines);
        const lstart = doc.rope.lineToOffset(line);
        try testing.expect(lstart <= text.len);
        try testing.expectEqual(line, doc.rope.newlinesBefore(lstart));
    }
}

/// Byte content around an untouched position is preserved by the
/// mapping — an independent property, not a re-implementation of
/// `mapOffset`.
fn checkMappingContent(
    old: []const u8,
    new: []const u8,
    edits: []const tr.Edit,
    p: usize,
) !void {
    // Untouched gap [gs, ge) containing p, in pre-edit coordinates.
    var gs: usize = 0;
    var ge: usize = old.len;
    for (edits) |e| {
        // A pure insertion AT p ends the gap: `.other` maps p to just
        // before the inserted bytes, so the comparison must stop here
        // even though the edit deletes nothing.
        if (e.deleted_len == 0 and e.offset == p) {
            ge = p;
            break;
        }
        const end = e.offset + e.deleted_len;
        if (end <= p) {
            gs = end;
            continue;
        }
        if (e.offset > p) {
            ge = e.offset;
            break;
        }
        // p is inside a deleted range: the mapping clamps and there is
        // no surviving content to compare.
        return;
    }
    if (ge < gs) return;

    const q = tr.mapOffset(edits, p, .other);
    try testing.expect(q <= new.len);
    const left = p - gs;
    const right = ge - p;
    try testing.expect(q >= left and q + right <= new.len);
    if (!std.mem.eql(u8, old[gs..p], new[q - left .. q]) or
        !std.mem.eql(u8, old[p..ge], new[q .. q + right]))
    {
        std.debug.print(
            "mapping content mismatch: p={d} q={d} gap=[{d},{d}) old_len={d} new_len={d}\n",
            .{ p, q, gs, ge, old.len, new.len },
        );
        for (edits) |e| std.debug.print(
            "  edit off={d} del={d} ins={d}\n",
            .{ e.offset, e.deleted_len, e.inserted.len },
        );
        return error.MappingContentMismatch;
    }

    // The editor bias never moves left of the neutral one, and stays in
    // range.
    const qe = tr.mapOffset(edits, p, .editor);
    try testing.expect(qe >= q and qe <= new.len);
}

/// Mapping must be monotone in the probed offset, and a selection set
/// mapped through the edits must stay sorted, non-overlapping and in
/// range.
fn checkSelectionMapping(
    old: []const u8,
    new: []const u8,
    edits: []const tr.Edit,
    rand: std.Random,
) !void {
    var probes: [8]usize = undefined;
    for (&probes) |*p| p.* = rand.intRangeAtMost(usize, 0, old.len);
    std.mem.sort(usize, &probes, {}, std.sort.asc(usize));

    var prev_other: usize = 0;
    var prev_editor: usize = 0;
    for (probes) |p| {
        try checkMappingContent(old, new, edits, p);
        const o = tr.mapOffset(edits, p, .other);
        const e = tr.mapOffset(edits, p, .editor);
        try testing.expect(o >= prev_other);
        try testing.expect(e >= prev_editor);
        prev_other = o;
        prev_editor = e;
    }

    var set = SelectionSet.init();
    defer set.deinit(testing.allocator);
    var i: usize = 0;
    while (i + 1 < probes.len) : (i += 2) {
        try set.sels.append(testing.allocator, .{ .anchor = probes[i], .head = probes[i + 1] });
    }
    set.normalize();
    set.mapThrough(edits, .other);
    var prev_end: usize = 0;
    for (set.sels.items, 0..) |s, idx| {
        try testing.expect(s.end() <= new.len);
        if (idx > 0) try testing.expect(s.start() >= prev_end);
        prev_end = s.end();
    }
    try testing.expect(set.primary_index < set.count());
}

/// Grapheme and word queries must make progress, stay in range and —
/// on valid UTF-8 — never land inside a sequence.
fn checkBoundaries(text: []const u8, rand: std.Random, utf8_only: bool) !void {
    if (text.len == 0) return;
    var probe: usize = 0;
    while (probe < 6) : (probe += 1) {
        const i = rand.intRangeAtMost(usize, 0, text.len);
        const ng = uni.nextGrapheme(text, i);
        try testing.expect(ng <= text.len);
        try testing.expect(ng > i or i >= text.len);
        const pg = uni.prevGrapheme(text, i);
        try testing.expect(pg <= text.len);
        try testing.expect(pg < i or i == 0);
        const nw = uni.nextWordBoundary(text, i);
        const pw = uni.prevWordBoundary(text, i);
        try testing.expect(nw >= i and nw <= text.len);
        try testing.expect(pw <= i);
        if (utf8_only) {
            for ([_]usize{ ng, pg, nw, pw }) |o| {
                if (!isCharBoundary(text, o)) return error.SplitUtf8Sequence;
            }
        }
        // Walking the whole document by graphemes terminates exactly on
        // the end and only ever lands on boundaries.
        if (text.len < 4096) {
            var j: usize = 0;
            while (j < text.len) {
                const next = uni.nextGrapheme(text, j);
                try testing.expect(next > j);
                if (utf8_only and !isCharBoundary(text, next)) return error.SplitUtf8Sequence;
                j = next;
            }
            try testing.expectEqual(text.len, j);
        }
    }
}

/// Every LF in a .crlf document must come back out as CRLF, and
/// nothing else may change.
fn checkMaterialize(doc: *const Document, model: *const Model) !void {
    const alloc = testing.allocator;
    const out = try doc.materialize(alloc);
    defer alloc.free(out);
    var want: std.ArrayList(u8) = .empty;
    defer want.deinit(alloc);
    for (model.text.items) |b| {
        if (b == '\n') try want.append(alloc, '\r');
        try want.append(alloc, b);
    }
    try testing.expectEqualSlices(u8, want.items, out);
}

// ---- the driver -------------------------------------------------------

fn runFuzz(cfg: Config) !void {
    const alloc = testing.allocator;
    var prng = std.Random.DefaultPrng.init(cfg.seed);
    const rand = prng.random();

    var model = Model{ .alloc = alloc };
    defer model.deinit();
    const seed_text = if (cfg.crlf_seed)
        "the quick brown fox\r\njumps over\r\nthe \u{1F98A} dog\r\n"
    else
        "the quick brown fox\njumps over\nthe \u{1F98A} dog\n";

    var doc = try Document.initFromBytes(alloc, seed_text);
    defer doc.deinit();
    try testing.expectEqual(
        if (cfg.crlf_seed) doc_mod.LineEnding.crlf else doc_mod.LineEnding.lf,
        doc.line_ending,
    );
    // A CRLF document lives LF-normalized in memory, so the model
    // starts from what the document actually holds. Everything inserted
    // later is raw bytes for both.
    const start_text = try doc.textAlloc(alloc);
    defer alloc.free(start_text);
    try model.text.appendSlice(alloc, start_text);

    const original = try model.snapshot();
    defer alloc.free(original);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();

    var step: usize = 0;
    while (step < cfg.steps) : (step += 1) {
        const roll = rand.intRangeAtMost(u8, 0, 99);
        if (roll < 12 and doc.canUndo()) {
            const before = try model.snapshot();
            errdefer alloc.free(before);
            const rev = doc.revision;
            const change = try doc.undo();
            try testing.expectEqual(rev + 1, doc.revision);
            try testing.expectEqual(doc.revision, change.revision);
            const target = model.undo_snaps.pop().?;
            defer alloc.free(target);
            model.text.clearRetainingCapacity();
            try model.text.appendSlice(alloc, target);
            try model.redo_snaps.append(alloc, before);
        } else if (roll < 20 and doc.canRedo()) {
            const before = try model.snapshot();
            errdefer alloc.free(before);
            _ = try doc.redo();
            const target = model.redo_snaps.pop().?;
            defer alloc.free(target);
            model.text.clearRetainingCapacity();
            try model.text.appendSlice(alloc, target);
            try model.undo_snaps.append(alloc, before);
        } else if (roll < 23) {
            doc.breakUndoGroup();
            continue;
        } else {
            _ = arena_state.reset(.retain_capacity);
            const arena = arena_state.allocator();
            var tx = tr.Transaction.init(doc.revision);
            try genEdits(arena, rand, model.text.items, cfg, &tx);
            // The generator itself must produce legal edit lists; a
            // failure here is a bug in the test, so dump the list.
            tx.validate(model.text.items.len) catch |err| {
                std.debug.print("generated an invalid edit list (doc_len={d}):\n", .{model.text.items.len});
                for (tx.edits.items) |e| std.debug.print(
                    "  off={d} del={d} ins={d}\n",
                    .{ e.offset, e.deleted_len, e.inserted.len },
                );
                return err;
            };

            const pre_text = try model.snapshot();
            defer alloc.free(pre_text);
            const pre_undo_depth = doc.undo_stack.items.len;
            const rev = doc.revision;

            // A stale base revision must be refused without side effects.
            if (rand.intRangeAtMost(u8, 0, 19) == 0) {
                var stale = tr.Transaction.init(doc.revision +% 7);
                defer stale.deinit(alloc);
                try stale.addInsert(alloc, 0, "zzz");
                try testing.expectError(tr.Error.RevisionMismatch, doc.applyTransaction(&stale));
                try testing.expectEqual(rev, doc.revision);
            }

            const snap = try model.snapshot();
            errdefer alloc.free(snap);
            _ = try doc.applyTransaction(&tx);
            try testing.expectEqual(rev + 1, doc.revision);
            try model.apply(tx.edits.items);
            model.clearRedo();
            const grew = doc.undo_stack.items.len > pre_undo_depth;
            // A transaction opens at most one history entry.
            try testing.expect(doc.undo_stack.items.len <= pre_undo_depth + 1);
            if (grew) {
                try model.undo_snaps.append(alloc, snap);
            } else {
                // Coalesced into the open typing group, which only ever
                // happens for a lone single-codepoint insertion.
                try testing.expectEqual(@as(usize, 1), tx.edits.items.len);
                try testing.expectEqual(@as(usize, 0), tx.edits.items[0].deleted_len);
                alloc.free(snap);
            }

            try checkSelectionMapping(pre_text, model.text.items, tx.edits.items, rand);
        }

        try testing.expectEqual(model.undo_snaps.items.len, doc.undo_stack.items.len);
        try testing.expectEqual(model.redo_snaps.items.len, doc.redo_stack.items.len);
        try checkText(&doc, &model, cfg.seed, step);
        try checkLineIndex(&doc, &model, rand);
        if (step % 16 == 0) {
            doc.rope.checkInvariants();
            try checkBoundaries(model.text.items, rand, cfg.utf8_only);
            // Leaf storage must not drift away from the byte count.
            const st = doc.rope.stats();
            if (st.used > 8 * rope_mod.MAX_LEAF and st.amplification() > 8.0) {
                std.debug.print("leaf amplification {d:.2}x at seed={x} step={d}\n", .{
                    st.amplification(), cfg.seed, step,
                });
                return error.LeafProliferation;
            }
        }
    }

    // Undo everything: the document must return to the exact original
    // bytes, and each undo must move the revision forward.
    const pre_undo = try model.snapshot();
    defer alloc.free(pre_undo);
    var depth: usize = 0;
    while (doc.canUndo()) : (depth += 1) {
        const before = try model.snapshot();
        errdefer alloc.free(before);
        const rev = doc.revision;
        _ = try doc.undo();
        try testing.expectEqual(rev + 1, doc.revision);
        const target = model.undo_snaps.pop().?;
        defer alloc.free(target);
        model.text.clearRetainingCapacity();
        try model.text.appendSlice(alloc, target);
        try model.redo_snaps.append(alloc, before);
        checkText(&doc, &model, cfg.seed, depth) catch |err| {
            std.debug.print("divergence while undoing entry {d}\n", .{depth});
            return err;
        };
    }
    const undone = try doc.textAlloc(alloc);
    defer alloc.free(undone);
    try testing.expectEqualSlices(u8, original, undone);

    // Redo exactly as many entries as were undone: that is the state
    // the undo-all started from. (Redoing further would replay
    // whatever was already on the redo stack when the loop ended.)
    const undo_count = depth;
    depth = 0;
    while (depth < undo_count) : (depth += 1) {
        try testing.expect(doc.canRedo());
        _ = try doc.redo();
        const target = model.redo_snaps.pop().?;
        defer alloc.free(target);
        model.text.clearRetainingCapacity();
        try model.text.appendSlice(alloc, target);
        checkText(&doc, &model, cfg.seed, depth) catch |err| {
            std.debug.print("divergence while redoing entry {d}\n", .{depth});
            return err;
        };
    }
    if (cfg.crlf_seed) try checkMaterialize(&doc, &model);

    const redone = try doc.textAlloc(alloc);
    defer alloc.free(redone);
    if (!std.mem.eql(u8, pre_undo, redone)) {
        std.debug.print("redo-all mismatch: pre_undo={d} redone={d} model={d} leftover_redo_snaps={d} redo_stack={d} undo_stack={d}\n", .{
            pre_undo.len, redone.len, model.text.items.len, model.redo_snaps.items.len, doc.redo_stack.items.len, doc.undo_stack.items.len,
        });
        return error.RedoAllMismatch;
    }
    doc.rope.checkInvariants();
}

fn defaultSteps(fallback: usize) usize {
    return envUsize("SKETERM_EDITOR_FUZZ_STEPS", fallback);
}

fn baseSeed() u64 {
    return @intCast(envUsize("SKETERM_EDITOR_FUZZ_SEED", 0x3d17_10ad));
}

test "fuzz: document history against a byte-array oracle" {
    const steps = defaultSteps(320);
    var s: u64 = 0;
    while (s < 3) : (s += 1) {
        try runFuzz(.{ .seed = baseSeed() +% s *% 0x9E37_79B9, .steps = steps });
    }
}

test "fuzz: a CRLF document stays materializable through history" {
    try runFuzz(.{ .seed = baseSeed() +% 0xc12f, .steps = defaultSteps(320), .crlf_seed = true });
}

test "fuzz: UTF-8-preserving edits keep boundary queries sane" {
    const steps = defaultSteps(320);
    var s: u64 = 0;
    while (s < 2) : (s += 1) {
        try runFuzz(.{
            .seed = baseSeed() +% 0xbeef +% s *% 0x9E37_79B9,
            .steps = steps,
            .utf8_only = true,
        });
    }
}

test "fuzz: edits landing inside multi-byte sequences never corrupt bytes" {
    // A targeted variant: every edit deliberately cuts a 4-byte astral
    // sequence in half. The document is byte-oriented, so the only
    // promise is byte-exactness against the oracle plus queries that
    // stay in range.
    const alloc = testing.allocator;
    var prng = std.Random.DefaultPrng.init(baseSeed() +% 0x5151);
    const rand = prng.random();

    var oracle: std.ArrayList(u8) = .empty;
    defer oracle.deinit(alloc);
    var i: usize = 0;
    while (i < 400) : (i += 1) try oracle.appendSlice(alloc, "\u{1F600}");

    var doc = try Document.initFromBytes(alloc, oracle.items);
    defer doc.deinit();

    var step: usize = 0;
    while (step < defaultSteps(300)) : (step += 1) {
        // Offsets 1..3 modulo 4 are inside a sequence.
        const cp_index = rand.uintLessThan(usize, @max(oracle.items.len / 4, 1));
        const off = @min(cp_index * 4 + rand.intRangeAtMost(usize, 1, 3), oracle.items.len);
        var tx = tr.Transaction.init(doc.revision);
        defer tx.deinit(alloc);
        if (rand.boolean() and off < oracle.items.len) {
            const del = @min(rand.intRangeAtMost(usize, 1, 6), oracle.items.len - off);
            try tx.addDelete(alloc, off, del);
            _ = try doc.applyTransaction(&tx);
            try oracle.replaceRange(alloc, off, del, "");
        } else {
            const piece = "\u{1F680}\u{301}x";
            try tx.addInsert(alloc, off, piece);
            _ = try doc.applyTransaction(&tx);
            try oracle.replaceRange(alloc, off, 0, piece);
        }
        const got = try doc.textAlloc(alloc);
        defer alloc.free(got);
        try testing.expectEqualSlices(u8, oracle.items, got);
        try checkBoundaries(oracle.items, rand, false);
        if (oracle.items.len == 0) break;
    }
    doc.rope.checkInvariants();
}
