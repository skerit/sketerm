//! Editor text-core benchmark — `zig build bench-editor`.
//!
//! Measures load, edit and query cost of `editor/rope.zig` +
//! `editor/document.zig` on large and pathologically shaped documents
//! (one 50MB line, millions of empty lines, dense astral emoji, mixed
//! CRLF, NUL bytes). Also reports the rope's leaf-storage amplification
//! (capacity/used): the number that exposes leaf proliferation, which a
//! wall-clock number alone hides until the machine swaps.
//!
//! `--quick` skips the 100MB workloads.

const std = @import("std");
const rope_mod = @import("editor/rope.zig");
const Rope = rope_mod.Rope;
const doc_mod = @import("editor/document.zig");
const Document = doc_mod.Document;
const tr = @import("editor/transaction.zig");

const nowNs = @import("util/clock.zig").nowNs;

fn ms(ns: i128) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

fn row(name: []const u8, ns: i128, note: []const u8) void {
    std.debug.print("  {s:<38} {d:>10.2} ms   {s}\n", .{ name, ms(ns), note });
}

// ---- corpus generators ------------------------------------------------

/// `total` bytes of ASCII text with a newline every `line_len` bytes.
fn genLines(alloc: std.mem.Allocator, total: usize, line_len: usize) ![]u8 {
    const buf = try alloc.alloc(u8, total);
    for (buf, 0..) |*b, i| {
        b.* = if (i % line_len == line_len - 1) '\n' else @intCast('a' + (i % 26));
    }
    return buf;
}

/// One line of `total` bytes with no newline at all.
fn genOneLine(alloc: std.mem.Allocator, total: usize) ![]u8 {
    const buf = try alloc.alloc(u8, total);
    for (buf, 0..) |*b, i| b.* = @intCast('a' + (i % 26));
    return buf;
}

fn genEmptyLines(alloc: std.mem.Allocator, count: usize) ![]u8 {
    const buf = try alloc.alloc(u8, count);
    @memset(buf, '\n');
    return buf;
}

/// Dense astral-plane emoji (4 bytes each), newline every 40 codepoints.
fn genEmoji(alloc: std.mem.Allocator, total: usize) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(alloc);
    var cp: u21 = 0x1F600;
    var n: usize = 0;
    while (list.items.len + 4 <= total) {
        var enc: [4]u8 = undefined;
        const l = std.unicode.utf8Encode(cp, &enc) catch unreachable;
        try list.appendSlice(alloc, enc[0..l]);
        cp += 1;
        if (cp > 0x1F64F) cp = 0x1F600;
        n += 1;
        if (n % 40 == 0) try list.append(alloc, '\n');
    }
    return try list.toOwnedSlice(alloc);
}

/// Alternating CRLF and LF terminated lines.
fn genMixedCrlf(alloc: std.mem.Allocator, total: usize) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(alloc);
    var line: usize = 0;
    while (list.items.len < total) : (line += 1) {
        try list.appendSlice(alloc, "the quick brown fox jumps over the lazy dog");
        if (line % 2 == 0) try list.append(alloc, '\r');
        try list.append(alloc, '\n');
    }
    return try list.toOwnedSlice(alloc);
}

/// Binary-ish: NUL bytes, invalid UTF-8 and the occasional newline.
fn genBinary(alloc: std.mem.Allocator, total: usize) ![]u8 {
    const buf = try alloc.alloc(u8, total);
    var prng = std.Random.DefaultPrng.init(0xb17a12);
    const rand = prng.random();
    for (buf, 0..) |*b, i| {
        b.* = if (i % 997 == 0) '\n' else if (i % 7 == 0) 0 else rand.int(u8);
    }
    return buf;
}

// ---- workloads --------------------------------------------------------

fn shapeNote(buf: *[96]u8, r: *const Rope) []const u8 {
    const s = r.stats();
    return std.fmt.bufPrint(buf, "leaves={d} height={d} amp={d:.2}x", .{
        s.leaves, s.height, s.amplification(),
    }) catch "";
}

/// Load + the operations every document shape should survive.
fn runShape(alloc: std.mem.Allocator, name: []const u8, bytes: []const u8, edit_iters: usize) !void {
    std.debug.print("\n{s}  ({d:.1} MB, {d} lines)\n", .{
        name,
        @as(f64, @floatFromInt(bytes.len)) / (1024.0 * 1024.0),
        std.mem.count(u8, bytes, "\n") + 1,
    });

    var t0 = nowNs();
    var doc = try Document.initFromBytes(alloc, bytes);
    defer doc.deinit();
    var note: [96]u8 = undefined;
    row("load (detect + normalize + build)", nowNs() - t0, shapeNote(&note, &doc.rope));

    // Worst case for a rope: repeated single-byte insert at offset 0.
    t0 = nowNs();
    var i: usize = 0;
    while (i < edit_iters) : (i += 1) {
        var tx = tr.Transaction.init(doc.revision);
        defer tx.deinit(alloc);
        try tx.addInsert(alloc, 0, "x");
        _ = try doc.applyTransaction(&tx);
    }
    row("insert 1 byte at start (x iters)", nowNs() - t0, shapeNote(&note, &doc.rope));

    t0 = nowNs();
    i = 0;
    while (i < edit_iters) : (i += 1) {
        var tx = tr.Transaction.init(doc.revision);
        defer tx.deinit(alloc);
        try tx.addInsert(alloc, doc.rope.len(), "y");
        _ = try doc.applyTransaction(&tx);
    }
    row("insert 1 byte at end (x iters)", nowNs() - t0, shapeNote(&note, &doc.rope));

    // Scattered single-byte deletes: the shape that makes a rope whose
    // leaves never merge grow one leaf per edit.
    var prng = std.Random.DefaultPrng.init(0xdefec7);
    const rand = prng.random();
    t0 = nowNs();
    i = 0;
    while (i < edit_iters) : (i += 1) {
        const pos = rand.intRangeAtMost(usize, 0, doc.rope.len() - 1);
        var tx = tr.Transaction.init(doc.revision);
        defer tx.deinit(alloc);
        try tx.addDelete(alloc, pos, 1);
        _ = try doc.applyTransaction(&tx);
    }
    row("scattered 1-byte deletes (x iters)", nowNs() - t0, shapeNote(&note, &doc.rope));

    // Undo everything the three loops above pushed.
    t0 = nowNs();
    var undone: usize = 0;
    while (doc.canUndo()) : (undone += 1) _ = try doc.undo();
    var unote: [96]u8 = undefined;
    row("undo all", nowNs() - t0, std.fmt.bufPrint(&unote, "{d} entries, {s}", .{
        undone, shapeNote(&note, &doc.rope),
    }) catch "");

    // Queries.
    const nlines = doc.rope.lineCount();
    t0 = nowNs();
    var acc: usize = 0;
    i = 0;
    while (i < 100_000) : (i += 1) {
        acc +%= doc.rope.lineToOffset(rand.intRangeLessThan(usize, 0, nlines));
    }
    row("lineToOffset x100k", nowNs() - t0, "");

    t0 = nowNs();
    i = 0;
    while (i < 100_000) : (i += 1) {
        acc +%= doc.rope.offsetToLineCol(rand.intRangeAtMost(usize, 0, doc.rope.len())).line;
    }
    row("offsetToLineCol x100k", nowNs() - t0, "");
    std.mem.doNotOptimizeAway(acc);

    // Whole-document read-out in the on-disk line-ending style.
    t0 = nowNs();
    const out = try doc.materialize(alloc);
    alloc.free(out);
    row("materialize", nowNs() - t0, "");

    // One big multi-edit transaction (2000 scattered replacements) and
    // its undo — the "replace all" / "format document" shape.
    var tx = tr.Transaction.init(doc.revision);
    defer tx.deinit(alloc);
    const step = @max(doc.rope.len() / 2000, 8);
    var off: usize = 0;
    while (off + 4 < doc.rope.len()) : (off += step) {
        try tx.addReplace(alloc, off, 4, "ZZZZZZ");
    }
    const nedits = tx.edits.items.len;
    t0 = nowNs();
    _ = try doc.applyTransaction(&tx);
    var bnote: [96]u8 = undefined;
    row("multi-edit transaction", nowNs() - t0, std.fmt.bufPrint(&bnote, "{d} edits", .{nedits}) catch "");
    t0 = nowNs();
    _ = try doc.undo();
    row("undo of that transaction", nowNs() - t0, shapeNote(&note, &doc.rope));
}

pub fn main(init: std.process.Init.Minimal) !void {
    const alloc = std.heap.c_allocator;
    var quick = false;
    for (init.args.vector) |raw| {
        if (std.mem.eql(u8, std.mem.span(raw), "--quick")) quick = true;
    }

    std.debug.print("=== sketerm editor core benchmark ===\n", .{});
    std.debug.print("MAX_LEAF={d} bytes\n", .{rope_mod.MAX_LEAF});

    {
        const b = try genLines(alloc, 10 * 1024 * 1024, 72);
        defer alloc.free(b);
        try runShape(alloc, "10MB source-like text", b, 20_000);
    }
    if (!quick) {
        const b = try genLines(alloc, 100 * 1024 * 1024, 72);
        defer alloc.free(b);
        try runShape(alloc, "100MB source-like text", b, 20_000);
    }
    {
        const b = try genOneLine(alloc, 50 * 1024 * 1024);
        defer alloc.free(b);
        try runShape(alloc, "50MB single line (no newline)", b, 20_000);
    }
    {
        const b = try genEmptyLines(alloc, 5_000_000);
        defer alloc.free(b);
        try runShape(alloc, "5M empty lines", b, 20_000);
    }
    {
        const b = try genEmoji(alloc, 10 * 1024 * 1024);
        defer alloc.free(b);
        try runShape(alloc, "10MB dense astral emoji", b, 20_000);
    }
    {
        const b = try genMixedCrlf(alloc, 10 * 1024 * 1024);
        defer alloc.free(b);
        try runShape(alloc, "10MB mixed CRLF/LF", b, 20_000);
    }
    {
        const b = try genBinary(alloc, 10 * 1024 * 1024);
        defer alloc.free(b);
        try runShape(alloc, "10MB binary with NUL bytes", b, 20_000);
    }
    std.debug.print("\ndone\n", .{});
}
