//! Large-document regression tests for the editor text core.
//!
//! Two kinds of assertion live here:
//!
//!   * SHAPE — the rope's leaf storage must stay proportional to the
//!     document size. Leaf capacity is MAX_LEAF regardless of fill, so
//!     a rope that never re-merges leaves grows one leaf per edit and
//!     ends up holding kilobytes per stored byte. That is invisible in
//!     a wall-clock number until the machine swaps, so it is asserted
//!     directly (`Rope.stats().amplification()`).
//!
//!   * TIME — deliberately loose wall-clock ceilings (tens of times the
//!     measured cost) whose only job is to fail when an operation turns
//!     from O(log n) into O(n) per edit. `zig build bench-editor`
//!     prints the real numbers.
//!
//! Sizes are kept to a few MB so the normal `zig build test` stays
//! quick; the benchmark covers 10MB/100MB and the pathological shapes.

const std = @import("std");
const testing = std.testing;
const rope_mod = @import("rope.zig");
const Rope = rope_mod.Rope;
const doc_mod = @import("document.zig");
const Document = doc_mod.Document;
const tr = @import("transaction.zig");
const uni = @import("unicode.zig");

fn nowNs() i128 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
}

/// Fails with the measured duration when `ns` exceeds `budget_ms`.
fn expectUnder(label: []const u8, ns: i128, budget_ms: u32) !void {
    const took_ms = @as(f64, @floatFromInt(ns)) / 1e6;
    if (took_ms > @as(f64, @floatFromInt(budget_ms))) {
        std.debug.print("{s}: {d:.1} ms exceeds the {d} ms ceiling\n", .{ label, took_ms, budget_ms });
        return error.TooSlow;
    }
}

fn genLines(alloc: std.mem.Allocator, total: usize, line_len: usize) ![]u8 {
    const buf = try alloc.alloc(u8, total);
    for (buf, 0..) |*b, i| {
        b.* = if (i % line_len == line_len - 1) '\n' else @intCast('a' + (i % 26));
    }
    return buf;
}

const MB = 1024 * 1024;

test "stress: scattered edits do not amplify leaf storage" {
    const alloc = testing.allocator;
    const src = try genLines(alloc, 2 * MB, 72);
    defer alloc.free(src);
    var r = try Rope.initFromBytes(alloc, src);
    defer r.deinit();
    try testing.expect(r.stats().amplification() < 1.1);

    var prng = std.Random.DefaultPrng.init(0x1eaf);
    const rand = prng.random();
    var expect_len = r.len();
    var i: usize = 0;
    while (i < 20_000) : (i += 1) {
        const pos = rand.intRangeAtMost(usize, 0, r.len() - 1);
        if (i % 3 == 0) {
            try r.insert(pos, "q");
            expect_len += 1;
        } else {
            try r.delete(pos, pos + 1);
            expect_len -= 1;
        }
    }
    try testing.expectEqual(expect_len, r.len());
    r.checkInvariants();

    const st = r.stats();
    // Before leaf compaction this run ended around 5x; a rope that
    // re-merges seams stays essentially packed.
    if (st.amplification() > 1.5) {
        std.debug.print("leaf amplification {d:.2}x ({d} leaves for {d} bytes)\n", .{
            st.amplification(), st.leaves, st.used,
        });
        return error.LeafProliferation;
    }
}

test "stress: repeated single-byte insert at offset 0 stays sub-linear" {
    const alloc = testing.allocator;
    const src = try genLines(alloc, 4 * MB, 72);
    defer alloc.free(src);
    var doc = try Document.initFromBytes(alloc, src);
    defer doc.deinit();

    const t0 = nowNs();
    var i: usize = 0;
    while (i < 20_000) : (i += 1) {
        var tx = tr.Transaction.init(doc.revision);
        defer tx.deinit(alloc);
        try tx.addInsert(alloc, 0, "x");
        _ = try doc.applyTransaction(&tx);
    }
    // Per-edit O(n) would move 4MB 20k times: minutes, not seconds.
    try expectUnder("20k inserts at offset 0", nowNs() - t0, 4000);
    try testing.expectEqual(src.len + 20_000, doc.rope.len());
    doc.rope.checkInvariants();
}

test "stress: repeated single-byte insert at end stays sub-linear" {
    const alloc = testing.allocator;
    const src = try genLines(alloc, 4 * MB, 72);
    defer alloc.free(src);
    var doc = try Document.initFromBytes(alloc, src);
    defer doc.deinit();

    const t0 = nowNs();
    var i: usize = 0;
    while (i < 20_000) : (i += 1) {
        var tx = tr.Transaction.init(doc.revision);
        defer tx.deinit(alloc);
        try tx.addInsert(alloc, doc.rope.len(), "y");
        _ = try doc.applyTransaction(&tx);
    }
    try expectUnder("20k inserts at end", nowNs() - t0, 4000);
    try testing.expectEqual(src.len + 20_000, doc.rope.len());
}

test "stress: a 2000-edit transaction and its undo round-trip exactly" {
    const alloc = testing.allocator;
    const src = try genLines(alloc, 4 * MB, 72);
    defer alloc.free(src);
    var doc = try Document.initFromBytes(alloc, src);
    defer doc.deinit();

    var tx = tr.Transaction.init(doc.revision);
    defer tx.deinit(alloc);
    const step = doc.rope.len() / 2000;
    var off: usize = 0;
    while (off + 8 < doc.rope.len()) : (off += step) {
        try tx.addReplace(alloc, off, 8, "REPLACEMENT");
    }
    try testing.expect(tx.edits.items.len >= 1999);

    var t0 = nowNs();
    _ = try doc.applyTransaction(&tx);
    try expectUnder("2000-edit transaction", nowNs() - t0, 4000);
    doc.rope.checkInvariants();

    t0 = nowNs();
    _ = try doc.undo();
    try expectUnder("undo of a 2000-edit transaction", nowNs() - t0, 4000);

    const back = try doc.textAlloc(alloc);
    defer alloc.free(back);
    try testing.expectEqualSlices(u8, src, back);
    doc.rope.checkInvariants();
}

test "stress: five million empty lines" {
    const alloc = testing.allocator;
    const src = try alloc.alloc(u8, 5_000_000);
    defer alloc.free(src);
    @memset(src, '\n');

    var t0 = nowNs();
    var doc = try Document.initFromBytes(alloc, src);
    defer doc.deinit();
    try expectUnder("load 5M empty lines", nowNs() - t0, 4000);
    try testing.expectEqual(@as(usize, 5_000_001), doc.rope.lineCount());

    var prng = std.Random.DefaultPrng.init(0x5e5e);
    const rand = prng.random();
    t0 = nowNs();
    var i: usize = 0;
    while (i < 100_000) : (i += 1) {
        const line = rand.uintLessThan(usize, 5_000_001);
        try testing.expectEqual(line, doc.rope.lineToOffset(line));
    }
    try expectUnder("100k lineToOffset over 5M lines", nowNs() - t0, 4000);

    const lc = doc.rope.offsetToLineCol(4_999_999);
    try testing.expectEqual(@as(usize, 4_999_999), lc.line);
    try testing.expectEqual(@as(usize, 0), lc.col);
}

test "stress: one 8MB line with no newline" {
    const alloc = testing.allocator;
    const src = try alloc.alloc(u8, 8 * MB);
    defer alloc.free(src);
    for (src, 0..) |*b, i| b.* = @intCast('a' + (i % 26));

    var doc = try Document.initFromBytes(alloc, src);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 1), doc.rope.lineCount());

    // Editing in the middle of one enormous line must not be a memmove
    // of the whole line.
    const t0 = nowNs();
    var i: usize = 0;
    while (i < 10_000) : (i += 1) {
        var tx = tr.Transaction.init(doc.revision);
        defer tx.deinit(alloc);
        try tx.addInsert(alloc, doc.rope.len() / 2, "m");
        _ = try doc.applyTransaction(&tx);
    }
    try expectUnder("10k mid-line inserts", nowNs() - t0, 4000);

    const lc = doc.rope.offsetToLineCol(doc.rope.len());
    try testing.expectEqual(@as(usize, 0), lc.line);
    try testing.expectEqual(doc.rope.len(), lc.col);
}

test "stress: dense astral emoji document walks by graphemes" {
    const alloc = testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(alloc);
    var n: usize = 0;
    while (n < 200_000) : (n += 1) try list.appendSlice(alloc, "\u{1F600}");

    var doc = try Document.initFromBytes(alloc, list.items);
    defer doc.deinit();
    const text = try doc.textAlloc(alloc);
    defer alloc.free(text);
    try testing.expectEqualSlices(u8, list.items, text);

    const t0 = nowNs();
    var i: usize = 0;
    var clusters: usize = 0;
    while (i < text.len) {
        const next = uni.nextGrapheme(text, i);
        try testing.expect(next > i);
        i = next;
        clusters += 1;
    }
    try expectUnder("grapheme walk over 800KB of emoji", nowNs() - t0, 4000);
    try testing.expectEqual(@as(usize, 200_000), clusters);
}

test "stress: a large CRLF document round-trips through materialize" {
    const alloc = testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(alloc);
    var n: usize = 0;
    while (n < 40_000) : (n += 1) {
        try list.appendSlice(alloc, "the quick brown fox jumps over the lazy dog\r\n");
    }
    var doc = try Document.initFromBytes(alloc, list.items);
    defer doc.deinit();
    try testing.expectEqual(doc_mod.LineEnding.crlf, doc.line_ending);
    try testing.expectEqual(list.items.len - 40_000, doc.rope.len());

    const out = try doc.materialize(alloc);
    defer alloc.free(out);
    try testing.expectEqualSlices(u8, list.items, out);
}

test "stress: binary content with NUL bytes survives edits and materialize" {
    const alloc = testing.allocator;
    const src = try alloc.alloc(u8, 2 * MB);
    defer alloc.free(src);
    var prng = std.Random.DefaultPrng.init(0xb1a5);
    const rand = prng.random();
    for (src, 0..) |*b, i| {
        b.* = if (i % 997 == 0) '\n' else if (i % 7 == 0) 0 else rand.int(u8);
    }

    var doc = try Document.initFromBytes(alloc, src);
    defer doc.deinit();
    try testing.expectEqual(doc_mod.LineEnding.lf, doc.line_ending);

    var tx = tr.Transaction.init(doc.revision);
    defer tx.deinit(alloc);
    try tx.addReplace(alloc, 100, 10, "\x00\x00\x00");
    _ = try doc.applyTransaction(&tx);
    _ = try doc.undo();

    const out = try doc.materialize(alloc);
    defer alloc.free(out);
    try testing.expectEqualSlices(u8, src, out);
}
