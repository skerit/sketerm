//! Platform-neutral accessibility view of an editor `Document`.
//!
//! The counterpart of `view.zig` (which does the same job for a
//! terminal `Screen`), and deliberately GTK-free for the same reason:
//! the AT-SPI bridge and a future NSAccessibility one are thin adapters
//! over this.
//!
//! ## Offsets
//!
//! Accessibility APIs speak CHARACTERS (Unicode codepoints); the rope
//! is byte-indexed; LSP is UTF-16. This module owns exactly one
//! conversion, byte <-> codepoint, and nothing here ever sees a UTF-16
//! offset — `lsp/position.zig` remains the only place that convention
//! exists. Every value crossing into the bridge is a character offset,
//! every value crossing into the rope is a byte offset.
//!
//! ## Not materializing the document
//!
//! `view.Snapshot` copies the whole screen plus a `u32` per character;
//! that is fine for 80x24 and absurd for a 64 MB buffer. So there is no
//! document snapshot at all. `Index` keeps only a sparse anchor table —
//! the character offset at every 64 KB byte boundary, `u32` per anchor,
//! 1 KB for a 64 MB file — built by COUNTING lead bytes through
//! `Rope.iterateRange` (zero copies, leaf slices only) and extended
//! lazily, so a query near the top of a huge file never walks past it.
//! Any conversion then costs at most one 64 KB re-count. Every text a
//! query hands back is read out of the rope for the requested range
//! only.
//!
//! The table is keyed on `(document identity, revision)` and is dropped
//! whole when either moves, because nothing at this layer knows WHERE
//! an edit landed (the three `Document.EditObserver` slots are taken by
//! the highlighter, the fold anchors and the LSP client). The cost is
//! that the first conversion after each edit re-counts from byte 0 up
//! to the caret; see the limitations note in the AT-SPI bridge.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Rope = @import("../editor/rope.zig").Rope;
const Document = @import("../editor/document.zig").Document;
const SelectionSet = @import("../editor/selection.zig").SelectionSet;
const vm = @import("../editor/view_model.zig");

/// Bytes between anchors. 64 KB bounds every conversion's re-count and
/// costs 4 bytes of table per 64 KB of document.
pub const BLOCK: usize = 64 * 1024;

/// Lines the change-diff region spans. A caret-anchored block rather
/// than a caret-centred window so the region's identity is STABLE
/// while typing (see `region`).
pub const REGION_LINES: usize = 32;

/// A region longer than this is not diffed at all (a burst then emits
/// caret/selection only). Guards against a block of very long lines
/// turning every keystroke into a megabyte-sized diff.
pub const MAX_REGION_BYTES: usize = 64 * 1024;

/// What the bridge needs from whoever owns the documents: the active
/// document and its selections, or null when there is none (no tab, or
/// one still loading).
pub const Target = struct {
    doc: *const Document,
    sels: *const SelectionSet,
};

pub const Range = struct { start: u32, end: u32 };

fn isCont(b: u8) bool {
    return (b & 0xC0) == 0x80;
}

/// Codepoints in `bytes`, i.e. non-continuation bytes. Splitting a
/// sequence across two calls still totals correctly: the lead byte is
/// counted wherever it lands and continuations never are.
fn countChars(bytes: []const u8) u32 {
    var n: u32 = 0;
    for (bytes) |b| {
        if (!isCont(b)) n += 1;
    }
    return n;
}

/// Sparse byte <-> character index over ONE revision of one document.
pub const Index = struct {
    allocator: Allocator,
    /// Document the table describes; a different pointer invalidates.
    owner: ?*const Document = null,
    revision: u64 = 0,
    /// `anchors[k]` = character offset of byte `k * BLOCK`. Always
    /// `built_bytes / BLOCK + 1` entries, `anchors[0] == 0`.
    anchors: std.ArrayList(u32) = .empty,
    built_bytes: usize = 0,
    built_chars: u32 = 0,

    pub fn init(allocator: Allocator) Index {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Index) void {
        self.anchors.deinit(self.allocator);
    }

    /// Point the table at `doc`'s current revision, discarding it if it
    /// described anything else.
    pub fn sync(self: *Index, doc: *const Document) !void {
        if (self.owner == doc and self.revision == doc.revision and self.anchors.items.len > 0) return;
        self.anchors.clearRetainingCapacity();
        try self.anchors.append(self.allocator, 0);
        self.built_bytes = 0;
        self.built_chars = 0;
        self.owner = doc;
        self.revision = doc.revision;
    }

    /// Count forward until `[0, target)` is indexed.
    fn extendTo(self: *Index, rope: *const Rope, target_in: usize) !void {
        const target = @min(target_in, rope.len());
        if (target <= self.built_bytes) return;
        var it = rope.iterateRange(self.built_bytes, target);
        while (it.next()) |chunk| {
            var off: usize = 0;
            while (off < chunk.len) {
                const to_edge = BLOCK - (self.built_bytes % BLOCK);
                const take = @min(to_edge, chunk.len - off);
                self.built_chars += countChars(chunk[off .. off + take]);
                self.built_bytes += take;
                off += take;
                if (self.built_bytes % BLOCK == 0)
                    try self.anchors.append(self.allocator, self.built_chars);
            }
        }
    }

    /// Character offset of byte offset `byte` (clamped to the rope).
    pub fn byteToChar(self: *Index, doc: *const Document, byte: usize) !u32 {
        try self.sync(doc);
        const rope = &doc.rope;
        const b = @min(byte, rope.len());
        try self.extendTo(rope, b);
        const k = b / BLOCK;
        var chars = self.anchors.items[k];
        const from = k * BLOCK;
        if (b > from) {
            var it = rope.iterateRange(from, b);
            while (it.next()) |chunk| chars += countChars(chunk);
        }
        return chars;
    }

    /// Byte offset where character `ch` starts; the rope length when
    /// `ch` is at or past the end.
    pub fn charToByte(self: *Index, doc: *const Document, ch: u32) !usize {
        try self.sync(doc);
        const rope = &doc.rope;
        // Index strictly PAST `ch`, so the walk below lands on a real
        // lead byte rather than on a block edge mid-sequence.
        while (self.built_chars <= ch and self.built_bytes < rope.len()) {
            const short: usize = ch - self.built_chars;
            try self.extendTo(rope, self.built_bytes + @max(BLOCK, short));
        }
        if (ch >= self.built_chars) return rope.len();

        // Largest k with anchors[k] <= ch.
        var lo: usize = 0;
        var hi: usize = self.anchors.items.len;
        while (lo + 1 < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.anchors.items[mid] <= ch) lo = mid else hi = mid;
        }
        var chars = self.anchors.items[lo];
        var pos = lo * BLOCK;
        const end = @min(pos + BLOCK, self.built_bytes);
        var it = rope.iterateRange(pos, end);
        while (it.next()) |chunk| {
            for (chunk) |b| {
                if (!isCont(b)) {
                    if (chars == ch) return pos;
                    chars += 1;
                }
                pos += 1;
            }
        }
        return end;
    }

    /// Total characters in the document. Walks the whole rope once per
    /// revision (counting only — no copy); an AT asking for
    /// CharacterCount is what forces it.
    pub fn totalChars(self: *Index, doc: *const Document) !u32 {
        try self.sync(doc);
        try self.extendTo(&doc.rope, doc.rope.len());
        return self.built_chars;
    }
};

// ── queries ──────────────────────────────────────────────────────────

/// Character offset of the primary caret's head.
pub fn caret(idx: *Index, t: Target) !u32 {
    return idx.byteToChar(t.doc, t.sels.primary().head);
}

/// Every NON-EMPTY selection as a character range, primary first when
/// it is non-empty, the rest in document order (`SelectionSet` keeps
/// itself sorted and non-overlapping).
///
/// Multi-caret editing has no counterpart in AT-SPI's model, which
/// assumes a caret plus a list of selected ranges. Rather than invent
/// one, this reports the truth AT-SPI can express: N ranges, none of
/// them merged or interpolated, with the range a reader that only ever
/// looks at index 0 (Orca) should hear placed first. Bare carets
/// contribute nothing — a caret is a position, not a selection, and
/// `caret` already reports the primary one.
pub fn selections(idx: *Index, t: Target, alloc: Allocator) ![]Range {
    const set = t.sels;
    var n: usize = 0;
    for (set.sels.items) |s| {
        if (!s.isCaret()) n += 1;
    }
    if (n == 0) return &.{};
    const out = try alloc.alloc(Range, n);
    errdefer alloc.free(out);
    var w: usize = 0;
    const prim = set.primary_index;
    if (!set.sels.items[prim].isCaret()) {
        const s = set.sels.items[prim];
        out[0] = .{
            .start = try idx.byteToChar(t.doc, s.start()),
            .end = try idx.byteToChar(t.doc, s.end()),
        };
        w = 1;
    }
    for (set.sels.items, 0..) |s, i| {
        if (i == prim or s.isCaret()) continue;
        out[w] = .{
            .start = try idx.byteToChar(t.doc, s.start()),
            .end = try idx.byteToChar(t.doc, s.end()),
        };
        w += 1;
    }
    return out;
}

/// UTF-8 for character range [c0, c1), read straight out of the rope.
pub fn contents(idx: *Index, t: Target, alloc: Allocator, c0: u32, c1: u32) ![]u8 {
    const b0 = try idx.charToByte(t.doc, c0);
    const b1 = try idx.charToByte(t.doc, @max(c0, c1));
    return t.doc.rope.sliceAlloc(alloc, b0, @max(b0, b1));
}

/// Character range of the line containing `off`, INCLUDING its
/// trailing newline (the AT-SPI line convention, and the same range
/// the editor's own triple-click selection uses).
pub fn lineRange(idx: *Index, t: Target, off: u32) !Range {
    const b = try idx.charToByte(t.doc, off);
    const s = vm.lineRangeAt(t.doc, b);
    return .{
        .start = try idx.byteToChar(t.doc, s.start()),
        .end = try idx.byteToChar(t.doc, s.end()),
    };
}

/// Character range of the word-class run around `off` — the editor's
/// own double-click definition, so what a reader calls a word and what
/// Ctrl+Left jumps over are the same thing.
pub fn wordRange(idx: *Index, t: Target, alloc: Allocator, off: u32) !Range {
    const b = try idx.charToByte(t.doc, off);
    const s = vm.wordRangeAt(alloc, t.doc, b);
    return .{
        .start = try idx.byteToChar(t.doc, s.start()),
        .end = try idx.byteToChar(t.doc, s.end()),
    };
}

/// The character containing `off`, i.e. [off, off+1) clamped.
///
/// Deliberately NOT `@min(off, totalChars())`: a document-length query
/// walks the whole rope, and CHARACTER granularity is the granularity a
/// reader fires per keypress. `charToByte` already indexes exactly as
/// far as `off`, and only pays for the full walk when `off` really is
/// at or past the end.
pub fn charRange(idx: *Index, t: Target, off: u32) !Range {
    const b = try idx.charToByte(t.doc, off);
    if (b >= t.doc.rope.len()) {
        const end = try idx.byteToChar(t.doc, t.doc.rope.len());
        return .{ .start = end, .end = end };
    }
    return .{ .start = off, .end = off + 1 };
}

/// The block of `REGION_LINES` lines the primary caret sits in, for
/// the bridge's change diff.
///
/// Anchored to a fixed line block (`line / REGION_LINES`) rather than
/// centred on the caret, so typing — which is what needs exact
/// text-changed events — keeps producing the SAME region and therefore
/// a real diff. The key pairs the block index with the byte offset that
/// block starts at, so an edit ABOVE the caret (which shifts that
/// offset) invalidates the diff instead of silently reporting a range
/// computed against different text.
pub const Region = struct { text: []u8, char0: u32, key: u64 };

pub fn region(idx: *Index, t: Target, alloc: Allocator) !?Region {
    const rope = &t.doc.rope;
    const caret_b = @min(t.sels.primary().head, rope.len());
    const line = rope.newlinesBefore(caret_b);
    const l0 = (line / REGION_LINES) * REGION_LINES;
    const l1 = l0 + REGION_LINES;
    const b0 = rope.lineToOffset(l0);
    const b1 = if (l1 < rope.lineCount()) rope.lineToOffset(l1) else rope.len();
    if (b1 - b0 > MAX_REGION_BYTES) return null;
    const text = try rope.sliceAlloc(alloc, b0, b1);
    errdefer alloc.free(text);
    var h = std.hash.Wyhash.init(0x5ce7e12);
    h.update(std.mem.asBytes(&l0));
    h.update(std.mem.asBytes(&b0));
    return .{ .text = text, .char0 = try idx.byteToChar(t.doc, b0), .key = h.final() };
}

// ── tests ────────────────────────────────────────────────────────────

const testing = std.testing;
const Selection = @import("../editor/selection.zig").Selection;

fn targetOf(doc: *const Document, sels: *const SelectionSet) Target {
    return .{ .doc = doc, .sels = sels };
}

test "docview: byte<->char round-trips across multibyte text" {
    var doc = try Document.initFromBytes(testing.allocator, "ab\u{e9}c\n\u{1F600}xy\n");
    defer doc.deinit();
    var idx = Index.init(testing.allocator);
    defer idx.deinit();

    // "ab é c \n 😀 x y \n" = 9 characters, 13 bytes.
    try testing.expectEqual(@as(u32, 9), try idx.totalChars(&doc));
    try testing.expectEqual(@as(u32, 2), try idx.byteToChar(&doc, 2)); // before é
    try testing.expectEqual(@as(u32, 3), try idx.byteToChar(&doc, 4)); // after é
    try testing.expectEqual(@as(usize, 2), try idx.charToByte(&doc, 2));
    try testing.expectEqual(@as(usize, 4), try idx.charToByte(&doc, 3));
    // The emoji is one character, four bytes.
    try testing.expectEqual(@as(usize, 6), try idx.charToByte(&doc, 5));
    try testing.expectEqual(@as(usize, 10), try idx.charToByte(&doc, 6));
    // Past the end clamps to the rope length.
    try testing.expectEqual(@as(usize, 13), try idx.charToByte(&doc, 99));
}

test "docview: the index is dropped when the revision moves" {
    var doc = try Document.initFromBytes(testing.allocator, "hello\n");
    defer doc.deinit();
    var idx = Index.init(testing.allocator);
    defer idx.deinit();
    try testing.expectEqual(@as(u32, 6), try idx.totalChars(&doc));

    var sels = try SelectionSet.initSingle(testing.allocator, Selection.caret(0));
    defer sels.deinit(testing.allocator);
    try vm.insertText(testing.allocator, &doc, &sels, "\u{e9}\u{e9}");
    // Two 2-byte characters added: 8 characters, 10 bytes.
    try testing.expectEqual(@as(u32, 8), try idx.totalChars(&doc));
    try testing.expectEqual(@as(usize, 4), try idx.charToByte(&doc, 2));
}

test "docview: index survives a document longer than one anchor block" {
    // Two full blocks plus a tail, with a multibyte character sitting
    // ON the second block boundary so the split-sequence path runs.
    const pad = BLOCK - 1;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try buf.appendNTimes(testing.allocator, 'a', pad);
    try buf.appendSlice(testing.allocator, "\u{e9}"); // straddles byte BLOCK
    try buf.appendNTimes(testing.allocator, 'b', BLOCK);
    try buf.appendSlice(testing.allocator, "tail");

    var doc = try Document.initFromBytes(testing.allocator, buf.items);
    defer doc.deinit();
    var idx = Index.init(testing.allocator);
    defer idx.deinit();

    const total = try idx.totalChars(&doc);
    try testing.expectEqual(@as(u32, @intCast(buf.items.len - 1)), total);
    // The character after the straddling é starts at byte pad+2.
    try testing.expectEqual(@as(u32, @intCast(pad + 1)), try idx.byteToChar(&doc, pad + 2));
    try testing.expectEqual(@as(usize, pad + 2), try idx.charToByte(&doc, @intCast(pad + 1)));
    // And the last character round-trips through the second block.
    try testing.expectEqual(@as(usize, buf.items.len - 1), try idx.charToByte(&doc, total - 1));
}

test "docview: line, word and character granularity in character offsets" {
    var doc = try Document.initFromBytes(testing.allocator, "let \u{e9}toile = 1;\nsecond line\n");
    defer doc.deinit();
    var idx = Index.init(testing.allocator);
    defer idx.deinit();
    var sels = try SelectionSet.initSingle(testing.allocator, Selection.caret(0));
    defer sels.deinit(testing.allocator);
    const t = targetOf(&doc, &sels);

    const lr = try lineRange(&idx, t, 2);
    const line_text = try contents(&idx, t, testing.allocator, lr.start, lr.end);
    defer testing.allocator.free(line_text);
    try testing.expectEqualStrings("let \u{e9}toile = 1;\n", line_text);

    // Offset 4 is 'é' (the accented character is ONE offset).
    const wr = try wordRange(&idx, t, testing.allocator, 4);
    const word = try contents(&idx, t, testing.allocator, wr.start, wr.end);
    defer testing.allocator.free(word);
    try testing.expectEqualStrings("\u{e9}toile", word);

    const cr = try charRange(&idx, t, 4);
    const ch = try contents(&idx, t, testing.allocator, cr.start, cr.end);
    defer testing.allocator.free(ch);
    try testing.expectEqualStrings("\u{e9}", ch);

    // The second line starts right after the first line's newline.
    const lr2 = try lineRange(&idx, t, lr.end);
    const line2 = try contents(&idx, t, testing.allocator, lr2.start, lr2.end);
    defer testing.allocator.free(line2);
    try testing.expectEqualStrings("second line\n", line2);
}

test "docview: caret and multi-selection reporting" {
    var doc = try Document.initFromBytes(testing.allocator, "\u{e9}abcdefghij");
    defer doc.deinit();
    var idx = Index.init(testing.allocator);
    defer idx.deinit();

    // Three ranges: a bare caret, and two real selections. The primary
    // is the LAST added, which sorts second in document order.
    var sels = try SelectionSet.initSingle(testing.allocator, Selection.caret(1));
    defer sels.deinit(testing.allocator);
    try sels.add(testing.allocator, .{ .anchor = 3, .head = 5 });
    try sels.add(testing.allocator, .{ .anchor = 8, .head = 10 });
    const t = targetOf(&doc, &sels);

    // Caret = the primary's head, in characters (é is one char, two
    // bytes, so byte 10 is character 9).
    try testing.expectEqual(@as(u32, 9), try caret(&idx, t));

    const ranges = try selections(&idx, t, testing.allocator);
    defer testing.allocator.free(ranges);
    // The bare caret is not a selection; the primary comes first.
    try testing.expectEqual(@as(usize, 2), ranges.len);
    try testing.expectEqual(@as(u32, 7), ranges[0].start);
    try testing.expectEqual(@as(u32, 9), ranges[0].end);
    try testing.expectEqual(@as(u32, 2), ranges[1].start);
    try testing.expectEqual(@as(u32, 4), ranges[1].end);

    // Collapsing to carets only reports nothing at all.
    var carets = try SelectionSet.initSingle(testing.allocator, Selection.caret(3));
    defer carets.deinit(testing.allocator);
    const none = try selections(&idx, targetOf(&doc, &carets), testing.allocator);
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "docview: the diff region is stable while typing on a line" {
    var doc = try Document.initFromBytes(testing.allocator, "one\ntwo\nthree\n");
    defer doc.deinit();
    var idx = Index.init(testing.allocator);
    defer idx.deinit();
    var sels = try SelectionSet.initSingle(testing.allocator, Selection.caret(5));
    defer sels.deinit(testing.allocator);

    const r0 = (try region(&idx, targetOf(&doc, &sels), testing.allocator)).?;
    defer testing.allocator.free(r0.text);
    try testing.expectEqual(@as(u32, 0), r0.char0);
    try testing.expectEqualStrings("one\ntwo\nthree\n", r0.text);

    try vm.insertText(testing.allocator, &doc, &sels, "X");
    const r1 = (try region(&idx, targetOf(&doc, &sels), testing.allocator)).?;
    defer testing.allocator.free(r1.text);
    // Same block, same origin: the bridge may diff these two.
    try testing.expectEqual(r0.key, r1.key);
    try testing.expectEqual(r0.char0, r1.char0);
    try testing.expectEqualStrings("one\ntXwo\nthree\n", r1.text);
}
