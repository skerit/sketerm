//! Structure-aware editing state: bracket pairs, code folding and the
//! expand/shrink selection stack.
//!
//! GTK-free and tree-sitter-free BY CONSTRUCTION. Everything here is
//! either a plain data type the tree-backed producers in `syntax.zig`
//! fill in, or a documented FALLBACK for the case where there is no
//! parse tree at all (unknown language, `editor_syntax = false`, or a
//! parse that has not caught up yet). `syntax.zig` imports this module;
//! this module must never import `syntax.zig` back.
//!
//! ## Why fold state is anchored to a BYTE OFFSET, not a line number
//!
//! A fold has to survive edits that do not destroy it — typing inside
//! the folded body, adding a line above it, undo/redo. Absolute line
//! numbers fail the first of those the moment a newline is inserted
//! anywhere above, and every editor that tried it grew a pile of
//! ad-hoc "shift the fold list by N" patches that undo/redo then broke
//! again.
//!
//! The offset of the fold header's first non-blank byte is instead
//! mapped through every transaction with `transaction.mapOffset`, i.e.
//! exactly the machinery selections already use, so there is ONE
//! definition of "where did this position go" in the editor and
//! undo/redo are free. After the mapping, the fold is RE-RESOLVED: the
//! producer is asked for the foldable region whose header sits on the
//! anchor's (new) line, and an entry that no longer resolves is
//! dropped. That is what makes "delete the closing brace" unfold
//! rather than hide the wrong lines: the tree stops reporting a region
//! there, so the entry disappears on the next resolve.
//!
//! A fold is therefore anchored to a POSITION plus a live structural
//! query, never to a cached line range.
//!
//! ## What is hidden
//!
//! `FoldRegion` is `(start_line, end_line)` where `start_line` is the
//! HEADER and stays visible; lines `start_line + 1 ..= end_line` are
//! hidden. A region always hides at least one line. Keeping the header
//! visible is why a folded `fn f() {` still shows its signature, and
//! why the producers stop `end_line` one line short of a node's last
//! row (the closing delimiter stays on screen).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Document = @import("document.zig").Document;
const Rope = @import("rope.zig").Rope;
const tr = @import("transaction.zig");
const Selection = @import("selection.zig").Selection;
const SelectionSet = @import("selection.zig").SelectionSet;

// ======================================================================
// Shared plain types
// ======================================================================

/// Half-open byte range.
pub const Range = struct {
    start: usize,
    end: usize,

    pub fn contains(self: Range, off: usize) bool {
        return off >= self.start and off < self.end;
    }
};

/// A matched bracket pair. Both ranges are one byte wide for the ASCII
/// brackets we match.
pub const BracketPair = struct {
    open: Range,
    close: Range,

    /// The pair as an outer range covering both delimiters.
    pub fn outer(self: BracketPair) Range {
        return .{ .start = self.open.start, .end = self.close.end };
    }
};

/// A foldable region. `start_line` is the header and stays visible;
/// `start_line + 1 ..= end_line` are hidden when folded.
pub const FoldRegion = struct {
    start_line: usize,
    end_line: usize,

    pub fn hides(self: FoldRegion, line: usize) bool {
        return line > self.start_line and line <= self.end_line;
    }

    pub fn hiddenCount(self: FoldRegion) usize {
        return self.end_line - self.start_line;
    }
};

// ======================================================================
// Brackets
// ======================================================================

pub const OPENERS = "([{";
pub const CLOSERS = ")]}";

/// Index into OPENERS/CLOSERS, plus which side `ch` is.
pub const BracketKind = struct { idx: usize, opening: bool };

pub fn classifyBracket(ch: u8) ?BracketKind {
    if (std.mem.indexOfScalar(u8, OPENERS, ch)) |i| return .{ .idx = i, .opening = true };
    if (std.mem.indexOfScalar(u8, CLOSERS, ch)) |i| return .{ .idx = i, .opening = false };
    return null;
}

/// The bracket byte the caret at `offset` is "on": the byte AT the
/// caret first (the conventional "cursor sits on the character to its
/// right"), then the byte BEFORE it, so a caret parked just after a
/// closing brace still highlights the pair.
pub fn bracketProbe(rope: *const Rope, offset: usize) ?struct { pos: usize, ch: u8 } {
    if (byteAt(rope, offset)) |ch| {
        if (classifyBracket(ch) != null) return .{ .pos = offset, .ch = ch };
    }
    if (offset > 0) {
        if (byteAt(rope, offset - 1)) |ch| {
            if (classifyBracket(ch) != null) return .{ .pos = offset - 1, .ch = ch };
        }
    }
    return null;
}

pub fn byteAt(rope: *const Rope, offset: usize) ?u8 {
    if (offset >= rope.len()) return null;
    var it = rope.iterateRange(offset, offset + 1);
    const chunk = it.next() orelse return null;
    if (chunk.len == 0) return null;
    return chunk[0];
}

/// How far the fallback scanner looks in either direction before
/// giving up. A pair further away than this is not worth a linear walk
/// on every caret move, and the tree path (which has no such limit) is
/// the primary source anyway.
pub const SCAN_LIMIT: usize = 256 * 1024;

/// Depth-counting bracket scanner — the FALLBACK used only when there
/// is no usable parse tree.
///
/// Documented weakness, deliberately not papered over: it counts
/// brackets inside strings, character literals and comments, because
/// without a tree it has no way to know it is inside one. That is
/// precisely the failure mode the tree path exists to avoid, so the
/// scanner is never consulted when `syntax.zig` can answer.
pub fn scanMatch(rope: *const Rope, offset: usize) ?BracketPair {
    const probe = bracketProbe(rope, offset) orelse return null;
    const kind = classifyBracket(probe.ch).?;
    return if (kind.opening)
        scanForward(rope, probe.pos, kind.idx)
    else
        scanBackward(rope, probe.pos, kind.idx);
}

fn scanForward(rope: *const Rope, pos: usize, idx: usize) ?BracketPair {
    const open = OPENERS[idx];
    const close = CLOSERS[idx];
    var depth: usize = 0;
    const n = rope.len();
    const stop = @min(n, pos + SCAN_LIMIT);
    var it = rope.iterateRange(pos, stop);
    var at = pos;
    while (it.next()) |chunk| {
        for (chunk, 0..) |ch, i| {
            if (ch == open) {
                depth += 1;
            } else if (ch == close) {
                depth -= 1;
                if (depth == 0) {
                    const cp = at + i;
                    return .{
                        .open = .{ .start = pos, .end = pos + 1 },
                        .close = .{ .start = cp, .end = cp + 1 },
                    };
                }
            }
        }
        at += chunk.len;
    }
    return null;
}

fn scanBackward(rope: *const Rope, pos: usize, idx: usize) ?BracketPair {
    const open = OPENERS[idx];
    const close = CLOSERS[idx];
    var depth: usize = 0;
    const floor = pos -| SCAN_LIMIT;
    // Backwards in blocks: the rope iterator only walks forward, so
    // read a window, scan it in reverse, then step the window back.
    const BLOCK: usize = 4096;
    var hi = pos + 1;
    var buf: [BLOCK]u8 = undefined;
    while (hi > floor) {
        const lo = @max(floor, hi -| BLOCK);
        var w: usize = 0;
        var it = rope.iterateRange(lo, hi);
        while (it.next()) |chunk| {
            const take = @min(chunk.len, buf.len - w);
            @memcpy(buf[w .. w + take], chunk[0..take]);
            w += take;
            if (w == buf.len) break;
        }
        var i = w;
        while (i > 0) {
            i -= 1;
            const ch = buf[i];
            if (ch == close) {
                depth += 1;
            } else if (ch == open) {
                depth -= 1;
                if (depth == 0) {
                    const op = lo + i;
                    return .{
                        .open = .{ .start = op, .end = op + 1 },
                        .close = .{ .start = pos, .end = pos + 1 },
                    };
                }
            }
        }
        if (lo == floor) break;
        hi = lo;
    }
    return null;
}

// ======================================================================
// Indentation fallback for folding
// ======================================================================

/// Visual indent width of `line` in columns, and whether the line is
/// blank. Tabs advance to the next `tab_width` stop.
pub fn indentOf(doc: *const Document, line: usize, tab_width: usize) struct { col: usize, blank: bool } {
    const start = doc.rope.lineToOffset(line);
    const n = doc.rope.len();
    var col: usize = 0;
    var it = doc.rope.iterateRange(start, n);
    while (it.next()) |chunk| {
        for (chunk) |ch| {
            switch (ch) {
                ' ' => col += 1,
                '\t' => col += tab_width - (col % tab_width),
                '\r' => {},
                '\n' => return .{ .col = col, .blank = true },
                else => return .{ .col = col, .blank = false },
            }
        }
    }
    return .{ .col = col, .blank = true };
}

/// Offset of the first non-blank byte of `line` (its end when the line
/// is blank). This is the fold ANCHOR: it tracks the header's content
/// rather than the line's leading whitespace, so re-indenting the
/// header does not lose the fold.
pub fn firstNonBlankOffset(doc: *const Document, line: usize) usize {
    const start = doc.rope.lineToOffset(line);
    const n = doc.rope.len();
    var off = start;
    var it = doc.rope.iterateRange(start, n);
    while (it.next()) |chunk| {
        for (chunk) |ch| {
            if (ch == '\n') return off;
            if (ch != ' ' and ch != '\t' and ch != '\r') return off;
            off += 1;
        }
    }
    return off;
}

/// Indentation-derived foldable region headed by `line`: the run of
/// following lines indented strictly deeper (blank lines carry
/// through), trimmed back to the last non-blank one.
///
/// This is the documented fallback for documents with no grammar. It
/// is deliberately NOT used when a tree is available: indentation
/// disagrees with structure inside multi-line expressions, and the
/// tree does not.
pub fn indentRegionAt(doc: *const Document, line: usize, tab_width: usize) ?FoldRegion {
    const n_lines = doc.rope.lineCount();
    if (line + 1 >= n_lines) return null;
    const head = indentOf(doc, line, tab_width);
    if (head.blank) return null;
    var last_deep: ?usize = null;
    var i = line + 1;
    while (i < n_lines) : (i += 1) {
        const cur = indentOf(doc, i, tab_width);
        if (cur.blank) continue;
        if (cur.col <= head.col) break;
        last_deep = i;
    }
    const end = last_deep orelse return null;
    if (end <= line) return null;
    return .{ .start_line = line, .end_line = end };
}

/// Every indentation region whose header falls in [from_line,
/// to_line]. Sorted by header line, one per header.
pub fn indentRegions(
    alloc: Allocator,
    doc: *const Document,
    from_line: usize,
    to_line: usize,
    tab_width: usize,
) ![]FoldRegion {
    var out: std.ArrayList(FoldRegion) = .empty;
    errdefer out.deinit(alloc);
    const n_lines = doc.rope.lineCount();
    var i = from_line;
    while (i <= to_line and i < n_lines) : (i += 1) {
        if (indentRegionAt(doc, i, tab_width)) |r| try out.append(alloc, r);
    }
    return out.toOwnedSlice(alloc);
}

/// Collapse a raw producer list to at most one region per header line,
/// keeping the NARROWEST, and sort by header line. Both producers
/// (tree and indentation) hand their output through here so the gutter
/// never shows two markers on one line.
///
/// Narrowest, not widest, and that choice is load-bearing. Without
/// per-language `folds.scm` queries the tree producer reports EVERY
/// multi-line node, and several of them share a header line: for
/// `pub fn main() void {` on line 0 the candidates include the
/// grammar's whole-file container as well as the declaration. Taking
/// the widest would fold the entire document from line 0. Taking the
/// narrowest never over-folds, and the outer regions stay reachable
/// because their headers are different lines.
pub fn normalizeRegions(regions: []FoldRegion) []FoldRegion {
    std.mem.sort(FoldRegion, regions, {}, struct {
        fn lt(_: void, a: FoldRegion, b: FoldRegion) bool {
            if (a.start_line != b.start_line) return a.start_line < b.start_line;
            return a.end_line < b.end_line;
        }
    }.lt);
    var w: usize = 0;
    for (regions) |r| {
        if (w > 0 and regions[w - 1].start_line == r.start_line) continue;
        regions[w] = r;
        w += 1;
    }
    return regions[0..w];
}

// ======================================================================
// Fold state
// ======================================================================

/// One folded region: the anchor that survives edits plus the region
/// it last resolved to.
pub const FoldEntry = struct {
    anchor: usize,
    region: FoldRegion,
};

/// Resolver handed to `resolve`: "is there a foldable region whose
/// header is `line`?". `syntax.zig` supplies the tree-backed one;
/// `indentResolver` is the fallback.
pub const Resolver = struct {
    ctx: ?*anyopaque,
    at_line: *const fn (ctx: ?*anyopaque, line: usize) ?FoldRegion,
};

/// The folded set for one document, plus the derived hidden-line map.
///
/// Ownership: every list is allocated from `alloc`, which must outlive
/// the state.
pub const FoldState = struct {
    alloc: Allocator,
    entries: std.ArrayList(FoldEntry) = .empty,
    /// Sorted, disjoint, MERGED hidden-line spans derived from
    /// `entries`. `start_line` here is the first HIDDEN line (not the
    /// header) so lookups are a plain interval test.
    hidden: std.ArrayList(FoldRegion) = .empty,

    pub fn init(alloc: Allocator) FoldState {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *FoldState) void {
        self.entries.deinit(self.alloc);
        self.hidden.deinit(self.alloc);
    }

    pub fn isEmpty(self: *const FoldState) bool {
        return self.entries.items.len == 0;
    }

    pub fn clear(self: *FoldState) void {
        self.entries.clearRetainingCapacity();
        self.hidden.clearRetainingCapacity();
    }

    /// Index of the entry headed by `line`, if any.
    pub fn entryAtLine(self: *const FoldState, line: usize) ?usize {
        for (self.entries.items, 0..) |e, i| {
            if (e.region.start_line == line) return i;
        }
        return null;
    }

    /// Fold `region`, anchored at `anchor`. A second fold on the same
    /// header replaces the first (the region may have grown).
    pub fn fold(self: *FoldState, anchor: usize, region: FoldRegion) !void {
        if (region.end_line <= region.start_line) return;
        if (self.entryAtLine(region.start_line)) |i| {
            self.entries.items[i] = .{ .anchor = anchor, .region = region };
        } else {
            try self.entries.append(self.alloc, .{ .anchor = anchor, .region = region });
        }
        try self.rebuildHidden();
    }

    /// Unfold the entry headed by `line`. @return true when one went.
    pub fn unfoldAtLine(self: *FoldState, line: usize) !bool {
        const i = self.entryAtLine(line) orelse return false;
        _ = self.entries.orderedRemove(i);
        try self.rebuildHidden();
        return true;
    }

    /// Unfold whatever hides `line` — the entry whose region covers it,
    /// innermost first. @return the header line that was unfolded.
    pub fn unfoldCovering(self: *FoldState, line: usize) !?usize {
        var best: ?usize = null;
        for (self.entries.items, 0..) |e, i| {
            if (!e.region.hides(line)) continue;
            if (best) |b| {
                if (e.region.start_line > self.entries.items[b].region.start_line) best = i;
            } else best = i;
        }
        const i = best orelse return null;
        const header = self.entries.items[i].region.start_line;
        _ = self.entries.orderedRemove(i);
        try self.rebuildHidden();
        return header;
    }

    /// Unfold every region hiding `line`, so a caret really can land
    /// there (find/replace, goto-line, restoring a saved cursor).
    /// @return true when anything changed.
    pub fn revealLine(self: *FoldState, line: usize) !bool {
        var changed = false;
        while (try self.unfoldCovering(line)) |_| changed = true;
        return changed;
    }

    /// Map every anchor through an applied transaction, exactly like
    /// selections. Call from the same place `SelectionSet.mapThrough`
    /// is called. Regions are NOT mapped — they are re-derived by the
    /// next `resolve`.
    ///
    /// Always the `.editor` bias, whoever produced the edit: an anchor
    /// names the header's first content byte, so text inserted exactly
    /// AT it belongs before it and the anchor must slide past. The
    /// `.other` bias would leave a fold anchored at line 0 stuck on
    /// whatever new line 0 became.
    pub fn mapThrough(self: *FoldState, edits: []const tr.Edit) void {
        for (self.entries.items) |*e| e.anchor = tr.mapOffset(edits, e.anchor, .editor);
    }

    /// Re-derive every entry's region from its (already mapped) anchor.
    /// Entries whose structure is gone are DROPPED, which is how
    /// deleting a closing brace unfolds its region instead of hiding
    /// the wrong lines.
    pub fn resolve(self: *FoldState, doc: *const Document, r: Resolver) !void {
        const n_lines = doc.rope.lineCount();
        var w: usize = 0;
        for (self.entries.items) |e| {
            if (e.anchor > doc.rope.len()) continue;
            const line = doc.rope.offsetToLineCol(e.anchor).line;
            if (line >= n_lines) continue;
            const region = r.at_line(r.ctx, line) orelse continue;
            if (region.end_line <= region.start_line) continue;
            // Two anchors can collapse onto one line after an edit that
            // joined them; keep the first.
            var dup = false;
            for (self.entries.items[0..w]) |k| {
                if (k.region.start_line == region.start_line) dup = true;
            }
            if (dup) continue;
            self.entries.items[w] = .{
                .anchor = firstNonBlankOffset(doc, line),
                .region = region,
            };
            w += 1;
        }
        self.entries.shrinkRetainingCapacity(w);
        try self.rebuildHidden();
    }

    /// Rebuild the merged hidden-line spans. O(n log n) in the number
    /// of folds, which is user-sized (tens), not document-sized.
    pub fn rebuildHidden(self: *FoldState) !void {
        self.hidden.clearRetainingCapacity();
        if (self.entries.items.len == 0) return;
        var spans: std.ArrayList(FoldRegion) = .empty;
        defer spans.deinit(self.alloc);
        for (self.entries.items) |e| {
            try spans.append(self.alloc, .{
                .start_line = e.region.start_line + 1,
                .end_line = e.region.end_line,
            });
        }
        std.mem.sort(FoldRegion, spans.items, {}, struct {
            fn lt(_: void, a: FoldRegion, b: FoldRegion) bool {
                return a.start_line < b.start_line;
            }
        }.lt);
        for (spans.items) |s| {
            if (self.hidden.items.len > 0) {
                const last = &self.hidden.items[self.hidden.items.len - 1];
                if (s.start_line <= last.end_line + 1) {
                    last.end_line = @max(last.end_line, s.end_line);
                    continue;
                }
            }
            try self.hidden.append(self.alloc, s);
        }
    }

    /// Index of the hidden span containing `line`, if any (binary
    /// search — this runs per line of a rendered frame).
    fn spanOf(self: *const FoldState, line: usize) ?usize {
        const items = self.hidden.items;
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (line < items[mid].start_line) {
                hi = mid;
            } else if (line > items[mid].end_line) {
                lo = mid + 1;
            } else return mid;
        }
        return null;
    }

    pub fn isHidden(self: *const FoldState, line: usize) bool {
        return self.spanOf(line) != null;
    }

    /// First visible line at or after `line`. Never returns a hidden
    /// line; may return a line past the end of the document, which
    /// every caller already clamps.
    pub fn nextVisible(self: *const FoldState, line: usize) usize {
        var l = line;
        while (self.spanOf(l)) |i| l = self.hidden.items[i].end_line + 1;
        return l;
    }

    /// Last visible line at or before `line`. Hidden lines fold back to
    /// their header.
    pub fn prevVisible(self: *const FoldState, line: usize) usize {
        var l = line;
        while (self.spanOf(l)) |i| {
            const s = self.hidden.items[i].start_line;
            if (s == 0) return 0;
            l = s - 1;
        }
        return l;
    }

    /// Total hidden lines — the row-count correction the scrollbar
    /// geometry needs when it cannot ask the RowIndex.
    pub fn hiddenLines(self: *const FoldState) usize {
        var n: usize = 0;
        for (self.hidden.items) |s| n += s.end_line - s.start_line + 1;
        return n;
    }
};

/// A `Resolver` over the indentation fallback.
pub const IndentResolverCtx = struct {
    doc: *const Document,
    tab_width: usize,

    pub fn resolver(self: *IndentResolverCtx) Resolver {
        return .{ .ctx = self, .at_line = atLine };
    }

    fn atLine(ctx: ?*anyopaque, line: usize) ?FoldRegion {
        const self: *IndentResolverCtx = @ptrCast(@alignCast(ctx.?));
        return indentRegionAt(self.doc, line, self.tab_width);
    }
};

// ======================================================================
// Expand / shrink selection stack
// ======================================================================

/// The undo trail for structural selection.
///
/// Shrink must retrace exactly what expand did rather than re-deriving
/// "the largest child containing the caret" — with several carets the
/// two are not the same set, and re-derivation drifts. So every expand
/// pushes a full snapshot of the selection set and every shrink pops
/// one.
///
/// The stack is invalidated by anything that is not an expand: a plain
/// caret move, an edit, a new document revision. `revision` + an
/// explicit `touch` from the view make that cheap to enforce.
pub const SelectionStack = struct {
    const Frame = struct { sels: []Selection, primary: usize };

    alloc: Allocator,
    frames: std.ArrayList(Frame) = .empty,
    /// Document revision the frames describe.
    revision: u64 = 0,

    pub fn init(alloc: Allocator) SelectionStack {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *SelectionStack) void {
        self.clear();
        self.frames.deinit(self.alloc);
    }

    pub fn depth(self: *const SelectionStack) usize {
        return self.frames.items.len;
    }

    pub fn clear(self: *SelectionStack) void {
        for (self.frames.items) |f| self.alloc.free(f.sels);
        self.frames.clearRetainingCapacity();
    }

    /// Drop the trail when the document moved under it.
    pub fn syncRevision(self: *SelectionStack, revision: u64) void {
        if (self.revision == revision) return;
        self.clear();
        self.revision = revision;
    }

    /// Discard the newest frame — for an expand that turned out to be
    /// a no-op, which must not leave a step shrink would replay.
    pub fn dropTop(self: *SelectionStack) void {
        const f = self.frames.pop() orelse return;
        self.alloc.free(f.sels);
    }

    pub fn push(self: *SelectionStack, sels: *const SelectionSet) !void {
        const copy = try self.alloc.dupe(Selection, sels.sels.items);
        errdefer self.alloc.free(copy);
        try self.frames.append(self.alloc, .{ .sels = copy, .primary = sels.primary_index });
    }

    /// Pop the previous snapshot into `sels`. @return false when empty.
    pub fn pop(self: *SelectionStack, sels: *SelectionSet) !bool {
        const frame = self.frames.pop() orelse return false;
        defer self.alloc.free(frame.sels);
        sels.sels.clearRetainingCapacity();
        try sels.sels.appendSlice(self.alloc, frame.sels);
        sels.primary_index = @min(frame.primary, sels.sels.items.len -| 1);
        return true;
    }
};

// ======================================================================
// Tests
// ======================================================================

const testing = std.testing;

fn docOf(text: []const u8) !Document {
    return Document.initFromBytes(testing.allocator, text);
}

test "structure: bracket probe prefers the byte at the caret, then before it" {
    var doc = try docOf("a(b)c");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 1), bracketProbe(&doc.rope, 1).?.pos);
    // Caret between ')' and 'c': the byte at the caret is 'c', so the
    // one before wins.
    try testing.expectEqual(@as(usize, 3), bracketProbe(&doc.rope, 4).?.pos);
    // Caret at 2 ('b'), previous is '(' -> that one.
    try testing.expectEqual(@as(usize, 1), bracketProbe(&doc.rope, 2).?.pos);
    try testing.expect(bracketProbe(&doc.rope, 0) == null);
}

test "structure: fallback scanner matches nested pairs in both directions" {
    const src = "fn f(a, g(b), c) {\n  x[i];\n}\n";
    var doc = try docOf(src);
    defer doc.deinit();
    const open_paren = std.mem.indexOfScalar(u8, src, '(').?;
    const p = scanMatch(&doc.rope, open_paren).?;
    try testing.expectEqual(open_paren, p.open.start);
    // The matching ')' is the one before " {".
    const close_paren = std.mem.indexOf(u8, src, ") {").?;
    try testing.expectEqual(close_paren, p.close.start);

    // Backwards from the closer.
    const back = scanMatch(&doc.rope, close_paren + 1).?;
    try testing.expectEqual(open_paren, back.open.start);
    try testing.expectEqual(close_paren, back.close.start);

    // Braces across lines.
    const ob = std.mem.indexOfScalar(u8, src, '{').?;
    const bp = scanMatch(&doc.rope, ob).?;
    try testing.expectEqual(std.mem.indexOfScalar(u8, src, '}').?, bp.close.start);

    // Unbalanced -> no pair.
    var doc2 = try docOf("((");
    defer doc2.deinit();
    try testing.expect(scanMatch(&doc2.rope, 0) == null);
}

test "structure: fallback scanner counts brackets inside strings (documented)" {
    // This is the known weakness the tree path exists to avoid.
    const src = "f(\")\")";
    var doc = try docOf(src);
    defer doc.deinit();
    const p = scanMatch(&doc.rope, 1).?;
    // It stops at the ')' inside the string literal, at index 3.
    try testing.expectEqual(@as(usize, 3), p.close.start);
}

test "structure: indentation fallback regions" {
    const src =
        \\fn a():
        \\    one
        \\    two
        \\
        \\    three
        \\fn b():
        \\    x
        \\done
        \\
    ;
    var doc = try docOf(src);
    defer doc.deinit();
    const r0 = indentRegionAt(&doc, 0, 4).?;
    try testing.expectEqual(@as(usize, 0), r0.start_line);
    // Blank line 3 carries through; the region ends at line 4.
    try testing.expectEqual(@as(usize, 4), r0.end_line);
    const r5 = indentRegionAt(&doc, 5, 4).?;
    try testing.expectEqual(@as(usize, 6), r5.end_line);
    // A line with nothing deeper under it is not foldable.
    try testing.expect(indentRegionAt(&doc, 1, 4) == null);
    try testing.expect(indentRegionAt(&doc, 7, 4) == null);

    const all = try indentRegions(testing.allocator, &doc, 0, 8, 4);
    defer testing.allocator.free(all);
    try testing.expectEqual(@as(usize, 2), all.len);
}

test "structure: normalizeRegions keeps the narrowest per header" {
    var regs = [_]FoldRegion{
        .{ .start_line = 5, .end_line = 7 },
        .{ .start_line = 1, .end_line = 3 },
        .{ .start_line = 5, .end_line = 20 },
    };
    const out = normalizeRegions(&regs);
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqual(@as(usize, 1), out[0].start_line);
    try testing.expectEqual(@as(usize, 5), out[1].start_line);
    try testing.expectEqual(@as(usize, 7), out[1].end_line);
}

test "structure: hidden spans merge and answer visibility queries" {
    var fs = FoldState.init(testing.allocator);
    defer fs.deinit();
    try fs.fold(0, .{ .start_line = 2, .end_line = 6 });
    try fs.fold(0, .{ .start_line = 10, .end_line = 12 });
    // Nested inside the first: merges away.
    try fs.fold(0, .{ .start_line = 3, .end_line = 5 });

    try testing.expect(!fs.isHidden(2));
    try testing.expect(fs.isHidden(3));
    try testing.expect(fs.isHidden(6));
    try testing.expect(!fs.isHidden(7));
    try testing.expect(fs.isHidden(11));

    try testing.expectEqual(@as(usize, 7), fs.nextVisible(3));
    try testing.expectEqual(@as(usize, 7), fs.nextVisible(7));
    try testing.expectEqual(@as(usize, 2), fs.prevVisible(5));
    try testing.expectEqual(@as(usize, 13), fs.nextVisible(12));
    // 3..6 (4 lines) + 11..12 (2 lines).
    try testing.expectEqual(@as(usize, 6), fs.hiddenLines());
}

test "structure: unfolding by covering line takes the innermost" {
    var fs = FoldState.init(testing.allocator);
    defer fs.deinit();
    try fs.fold(0, .{ .start_line = 0, .end_line = 20 });
    try fs.fold(0, .{ .start_line = 5, .end_line = 9 });
    const header = (try fs.unfoldCovering(7)).?;
    try testing.expectEqual(@as(usize, 5), header);
    try testing.expectEqual(@as(usize, 1), fs.entries.items.len);
    // Still hidden by the outer one; revealLine clears both.
    try testing.expect(fs.isHidden(7));
    try testing.expect(try fs.revealLine(7));
    try testing.expect(!fs.isHidden(7));
    try testing.expectEqual(@as(usize, 0), fs.entries.items.len);
}

test "structure: fold anchors survive an insert above and die with the region" {
    const src =
        \\fn a():
        \\    one
        \\    two
        \\    three
        \\end
        \\
    ;
    var doc = try docOf(src);
    defer doc.deinit();
    var fs = FoldState.init(testing.allocator);
    defer fs.deinit();
    var ctx = IndentResolverCtx{ .doc = &doc, .tab_width = 4 };

    const anchor = firstNonBlankOffset(&doc, 0);
    try fs.fold(anchor, indentRegionAt(&doc, 0, 4).?);
    try testing.expect(fs.isHidden(2));

    // Insert two lines above: absolute line numbers would be wrong, the
    // mapped anchor is not.
    var tx = tr.Transaction.init(doc.revision);
    defer tx.deinit(testing.allocator);
    try tx.addInsert(testing.allocator, 0, "// hdr\n// hdr2\n");
    fs.mapThrough(tx.edits.items);
    _ = try doc.applyTransaction(&tx);
    try fs.resolve(&doc, ctx.resolver());
    try testing.expectEqual(@as(usize, 1), fs.entries.items.len);
    try testing.expectEqual(@as(usize, 2), fs.entries.items[0].region.start_line);
    try testing.expect(fs.isHidden(4));
    try testing.expect(!fs.isHidden(2));

    // Now destroy the region by un-indenting its body: nothing resolves
    // at the header line any more, so the fold goes.
    var doc2 = try docOf("fn a():\nflat\n");
    defer doc2.deinit();
    var ctx2 = IndentResolverCtx{ .doc = &doc2, .tab_width = 4 };
    var fs2 = FoldState.init(testing.allocator);
    defer fs2.deinit();
    try fs2.fold(0, .{ .start_line = 0, .end_line = 1 });
    try fs2.resolve(&doc2, ctx2.resolver());
    try testing.expectEqual(@as(usize, 0), fs2.entries.items.len);
    try testing.expect(!fs2.isHidden(1));
}

test "structure: selection stack retraces expand exactly" {
    const a = testing.allocator;
    var stack = SelectionStack.init(a);
    defer stack.deinit();
    var sels = try SelectionSet.initSingle(a, Selection.caret(5));
    defer sels.deinit(a);

    try stack.push(&sels);
    sels.sels.items[0] = .{ .anchor = 4, .head = 8 };
    try stack.push(&sels);
    sels.sels.items[0] = .{ .anchor = 0, .head = 20 };
    try testing.expectEqual(@as(usize, 2), stack.depth());

    try testing.expect(try stack.pop(&sels));
    try testing.expectEqual(@as(usize, 4), sels.sels.items[0].anchor);
    try testing.expectEqual(@as(usize, 8), sels.sels.items[0].head);
    try testing.expect(try stack.pop(&sels));
    try testing.expect(sels.sels.items[0].isCaret());
    try testing.expectEqual(@as(usize, 5), sels.sels.items[0].head);
    try testing.expect(!try stack.pop(&sels));

    // A revision change invalidates the trail.
    try stack.push(&sels);
    stack.syncRevision(7);
    try testing.expectEqual(@as(usize, 0), stack.depth());
}

test "structure: selection stack keeps several carets together" {
    const a = testing.allocator;
    var stack = SelectionStack.init(a);
    defer stack.deinit();
    var sels = try SelectionSet.initSingle(a, Selection.caret(3));
    defer sels.deinit(a);
    try sels.add(a, Selection.caret(30));
    try testing.expectEqual(@as(usize, 2), sels.count());

    try stack.push(&sels);
    sels.sels.items[0] = .{ .anchor = 0, .head = 10 };
    sels.sels.items[1] = .{ .anchor = 25, .head = 40 };
    try testing.expect(try stack.pop(&sels));
    try testing.expectEqual(@as(usize, 2), sels.count());
    try testing.expect(sels.sels.items[0].isCaret());
    try testing.expect(sels.sels.items[1].isCaret());
    try testing.expectEqual(@as(usize, 3), sels.sels.items[0].head);
    try testing.expectEqual(@as(usize, 30), sels.sels.items[1].head);
}
