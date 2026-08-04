//! GTK-free per-view editing operations: caret movement, multi-caret
//! text edits, deletion, naive auto-indent, tab stops, word/line
//! ranges — everything the GTK editor face does that is expressible
//! over Document + SelectionSet alone. Visual-row concerns (up/down,
//! goal column, hit testing) stay in the GTK layer, which owns the
//! Layout.
//!
//! All multi-selection edits build ONE transaction (sorted,
//! overlap-clamped) and map the selections through with `.editor`
//! bias, so undo restores them as a unit.
//!
//! Gotcha: Document's history does not expose its inverse edits, so
//! undo/redo restores selections by CLAMPING to the new length, not
//! by exact mapping.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Document = @import("document.zig").Document;
const tr = @import("transaction.zig");
const sel_mod = @import("selection.zig");
const Selection = sel_mod.Selection;
const SelectionSet = sel_mod.SelectionSet;
const unicode = @import("unicode.zig");

/// Fallback tab width for callers with no config (tests). The GTK face
/// passes `Config.editor_tab_width`.
pub const TAB_WIDTH: usize = 4;

pub const LineBounds = struct {
    /// 0-based line index.
    line: usize,
    /// Byte offset of the line's first byte.
    start: usize,
    /// Byte offset just past the last content byte (newline excluded).
    end: usize,
};

pub fn lineBoundsAt(doc: *const Document, offset: usize) LineBounds {
    const n = doc.rope.len();
    const off = @min(offset, n);
    const lc = doc.rope.offsetToLineCol(off);
    const start = doc.rope.lineToOffset(lc.line);
    const end = if (lc.line + 1 < doc.rope.lineCount())
        doc.rope.lineToOffset(lc.line + 1) - 1
    else
        n;
    return .{ .line = lc.line, .start = start, .end = end };
}

/// Next caret position to the right: grapheme (or word) within the
/// line; a caret at the line's end steps over the newline.
pub fn nextPos(alloc: Allocator, doc: *const Document, offset: usize, word: bool) usize {
    const n = doc.rope.len();
    if (offset >= n) return n;
    const lb = lineBoundsAt(doc, offset);
    if (offset >= lb.end) return @min(offset + 1, n);
    const text = doc.rope.sliceAlloc(alloc, lb.start, lb.end) catch return offset;
    defer alloc.free(text);
    const i = offset - lb.start;
    const next = if (word) unicode.nextWordBoundary(text, i) else unicode.nextGrapheme(text, i);
    return lb.start + next;
}

/// Previous caret position: grapheme (or word) within the line; a
/// caret at a line's start steps back over the newline.
pub fn prevPos(alloc: Allocator, doc: *const Document, offset: usize, word: bool) usize {
    if (offset == 0) return 0;
    const lb = lineBoundsAt(doc, offset);
    if (offset <= lb.start) return lb.start -| 1;
    const text = doc.rope.sliceAlloc(alloc, lb.start, lb.end) catch return offset;
    defer alloc.free(text);
    const i = offset - lb.start;
    const prev = if (word) unicode.prevWordBoundary(text, i) else unicode.prevGrapheme(text, i);
    return lb.start + prev;
}

fn moveHead(sel: *Selection, target: usize, extend: bool) void {
    sel.head = target;
    if (!extend) sel.anchor = target;
}

/// Left/right (dir -1/+1) by grapheme or word; plain arrows collapse
/// a range to its edge (the standard editor behaviour).
pub fn moveHorizontal(alloc: Allocator, doc: *const Document, sels: *SelectionSet, dir: i2, extend: bool, word: bool) void {
    for (sels.sels.items) |*s| {
        if (!extend and !s.isCaret() and !word) {
            const edge = if (dir < 0) s.start() else s.end();
            s.* = Selection.caret(edge);
            continue;
        }
        const target = if (dir < 0)
            prevPos(alloc, doc, s.head, word)
        else
            nextPos(alloc, doc, s.head, word);
        moveHead(s, target, extend);
    }
    sels.normalize();
}

/// Home/End of the caret's LINE (with no soft wrap the line is the
/// visual row).
pub fn moveLineEdge(doc: *const Document, sels: *SelectionSet, to_end: bool, extend: bool) void {
    for (sels.sels.items) |*s| {
        const lb = lineBoundsAt(doc, s.head);
        moveHead(s, if (to_end) lb.end else lb.start, extend);
    }
    sels.normalize();
}

/// Ctrl+Home / Ctrl+End: document edges (collapses to one caret when
/// not extending, which is what every editor does).
pub fn moveDocEdge(doc: *const Document, sels: *SelectionSet, to_end: bool, extend: bool) void {
    const target = if (to_end) doc.rope.len() else 0;
    if (!extend) {
        sels.keepPrimaryOnly();
        sels.sels.items[0] = Selection.caret(target);
        return;
    }
    for (sels.sels.items) |*s| moveHead(s, target, true);
    sels.normalize();
}

pub fn selectAll(doc: *const Document, sels: *SelectionSet) void {
    sels.keepPrimaryOnly();
    sels.sels.items[0] = .{ .anchor = 0, .head = doc.rope.len() };
}

/// Escape: collapse to the primary caret.
pub fn collapseToPrimary(sels: *SelectionSet) void {
    sels.keepPrimaryOnly();
    const p = sels.sels.items[0];
    sels.sels.items[0] = Selection.caret(p.head);
}

pub fn clampSelections(doc: *const Document, sels: *SelectionSet) void {
    const n = doc.rope.len();
    for (sels.sels.items) |*s| {
        s.anchor = @min(s.anchor, n);
        s.head = @min(s.head, n);
    }
    sels.normalize();
}

// ---- edits -----------------------------------------------------------

/// Build + apply one transaction that replaces every selection with
/// `texts[i]` (texts.len == 1 reuses that text for all). Selections
/// end up as carets after their insertions.
fn replaceSelections(alloc: Allocator, doc: *Document, sels: *SelectionSet, texts: []const []const u8) !void {
    if (sels.sels.items.len == 0) return;
    var tx = tr.Transaction.init(doc.revision);
    defer tx.deinit(alloc);
    var prev_end: usize = 0;
    for (sels.sels.items, 0..) |s, i| {
        const text = texts[if (texts.len == 1) 0 else i];
        var start = s.start();
        var end = s.end();
        // Defensive overlap clamp (normalized sets should never need it).
        if (start < prev_end) start = prev_end;
        if (end < start) end = start;
        prev_end = end;
        try tx.addReplace(alloc, start, end - start, text);
    }
    _ = try doc.applyTransaction(&tx);
    sels.mapThrough(tx.edits.items, .editor);
}

/// Insert `text` at every selection (replacing ranges). Multi-caret
/// paste = the same text at each caret.
pub fn insertText(alloc: Allocator, doc: *Document, sels: *SelectionSet, text: []const u8) !void {
    try replaceSelections(alloc, doc, sels, &.{text});
}

/// Enter: newline + a copy of the current line's leading whitespace
/// (clipped to the caret column so mid-indent Enter can't duplicate
/// text to the caret's right).
pub fn insertNewlineIndent(alloc: Allocator, doc: *Document, sels: *SelectionSet) !void {
    if (sels.sels.items.len == 0) return;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var texts: std.ArrayList([]const u8) = .empty;
    for (sels.sels.items) |s| {
        const lb = lineBoundsAt(doc, s.start());
        const line = try doc.rope.sliceAlloc(a, lb.start, lb.end);
        var ws: usize = 0;
        const caret_col = s.start() - lb.start;
        while (ws < line.len and ws < caret_col and (line[ws] == ' ' or line[ws] == '\t')) ws += 1;
        const t = try a.alloc(u8, 1 + ws);
        t[0] = '\n';
        @memcpy(t[1..], line[0..ws]);
        try texts.append(a, t);
    }
    try replaceSelections(alloc, doc, sels, texts.items);
}

/// Tab: with `spaces`, pad to the next `width` stop counted in BYTES
/// from the line start (naive: a line already containing tabs or wide
/// characters pads by byte column, not by rendered column); otherwise
/// insert one literal tab.
pub fn insertTabStop(alloc: Allocator, doc: *Document, sels: *SelectionSet, width: usize, spaces: bool) !void {
    if (sels.sels.items.len == 0) return;
    if (!spaces) return insertText(alloc, doc, sels, "\t");
    const w = @max(1, width);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var texts: std.ArrayList([]const u8) = .empty;
    for (sels.sels.items) |s| {
        const lb = lineBoundsAt(doc, s.start());
        const col = s.start() - lb.start;
        const n = w - (col % w);
        const t = try a.alloc(u8, n);
        @memset(t, ' ');
        try texts.append(a, t);
    }
    try replaceSelections(alloc, doc, sels, texts.items);
}

/// Backspace: delete the selection, or one grapheme (word with Ctrl)
/// before each caret.
pub fn deleteBackward(alloc: Allocator, doc: *Document, sels: *SelectionSet, word: bool) !void {
    try deleteDirectional(alloc, doc, sels, word, true);
}

/// Delete: forward variant of deleteBackward.
pub fn deleteForward(alloc: Allocator, doc: *Document, sels: *SelectionSet, word: bool) !void {
    try deleteDirectional(alloc, doc, sels, word, false);
}

fn deleteDirectional(alloc: Allocator, doc: *Document, sels: *SelectionSet, word: bool, backward: bool) !void {
    if (sels.sels.items.len == 0) return;
    var tx = tr.Transaction.init(doc.revision);
    defer tx.deinit(alloc);
    var prev_end: usize = 0;
    for (sels.sels.items) |s| {
        var start: usize = undefined;
        var end: usize = undefined;
        if (!s.isCaret()) {
            start = s.start();
            end = s.end();
        } else if (backward) {
            start = prevPos(alloc, doc, s.head, word);
            end = s.head;
        } else {
            start = s.head;
            end = nextPos(alloc, doc, s.head, word);
        }
        // Overlap clamp: two close carets may compute overlapping
        // word deletions.
        if (start < prev_end) start = prev_end;
        if (end <= start) continue;
        prev_end = end;
        try tx.addDelete(alloc, start, end - start);
    }
    if (tx.edits.items.len == 0) return;
    _ = try doc.applyTransaction(&tx);
    sels.mapThrough(tx.edits.items, .editor);
}

pub fn undo(doc: *Document, sels: *SelectionSet) !void {
    _ = try doc.undo();
    clampSelections(doc, sels);
}

pub fn redo(doc: *Document, sels: *SelectionSet) !void {
    _ = try doc.redo();
    clampSelections(doc, sels);
}

// ---- ranges + clipboard text ----------------------------------------

/// Concatenated text of every non-caret selection, "\n"-joined.
/// Caller frees. Empty slice when nothing is selected.
pub fn selectedText(alloc: Allocator, doc: *const Document, sels: *const SelectionSet) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var first = true;
    for (sels.sels.items) |s| {
        if (s.isCaret()) continue;
        if (!first) try out.append(alloc, '\n');
        first = false;
        const piece = try doc.rope.sliceAlloc(alloc, s.start(), s.end());
        defer alloc.free(piece);
        try out.appendSlice(alloc, piece);
    }
    return out.toOwnedSlice(alloc);
}

/// The word-class run around `offset` (double-click selection).
pub fn wordRangeAt(alloc: Allocator, doc: *const Document, offset: usize) Selection {
    const lb = lineBoundsAt(doc, offset);
    if (lb.end == lb.start) return Selection.caret(lb.start);
    const text = doc.rope.sliceAlloc(alloc, lb.start, lb.end) catch return Selection.caret(offset);
    defer alloc.free(text);
    var i = @min(offset - lb.start, text.len - 1);
    while (i > 0 and (text[i] & 0xC0) == 0x80) i -= 1;
    const cls = unicode.wordClassOf(unicode.decodeAt(text, i).cp);
    var s = i;
    while (s > 0) {
        var p = s - 1;
        while (p > 0 and (text[p] & 0xC0) == 0x80) p -= 1;
        if (unicode.wordClassOf(unicode.decodeAt(text, p).cp) != cls) break;
        s = p;
    }
    var e = i + unicode.decodeAt(text, i).len;
    while (e < text.len) {
        const d = unicode.decodeAt(text, e);
        if (unicode.wordClassOf(d.cp) != cls) break;
        e += d.len;
    }
    return .{ .anchor = lb.start + s, .head = lb.start + e };
}

/// The whole line containing `offset`, trailing newline included
/// (triple-click selection).
pub fn lineRangeAt(doc: *const Document, offset: usize) Selection {
    const lb = lineBoundsAt(doc, offset);
    const end = @min(lb.end + 1, doc.rope.len());
    return .{ .anchor = lb.start, .head = end };
}

// ======================================================================
// Tests
// ======================================================================

const testing = std.testing;

fn docOf(text: []const u8) !Document {
    return try Document.initFromBytes(testing.allocator, text);
}

fn expectText(doc: *const Document, expected: []const u8) !void {
    const got = try doc.textAlloc(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "view_model horizontal movement crosses lines and graphemes" {
    const a = testing.allocator;
    var doc = try docOf("ab\ne\u{301}f");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, Selection.caret(2));
    defer sels.deinit(a);

    moveHorizontal(a, &doc, &sels, 1, false, false); // over the newline
    try testing.expectEqual(@as(usize, 3), sels.primary().head);
    moveHorizontal(a, &doc, &sels, 1, false, false); // over e-acute (3 bytes)
    try testing.expectEqual(@as(usize, 6), sels.primary().head);
    moveHorizontal(a, &doc, &sels, -1, false, false);
    try testing.expectEqual(@as(usize, 3), sels.primary().head);
    moveHorizontal(a, &doc, &sels, -1, false, false);
    try testing.expectEqual(@as(usize, 2), sels.primary().head);
}

test "view_model plain arrow collapses a range to its edge" {
    const a = testing.allocator;
    var doc = try docOf("hello");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, .{ .anchor = 1, .head = 4 });
    defer sels.deinit(a);
    moveHorizontal(a, &doc, &sels, -1, false, false);
    try testing.expect(sels.primary().isCaret());
    try testing.expectEqual(@as(usize, 1), sels.primary().head);
}

test "view_model word movement and line edges" {
    const a = testing.allocator;
    var doc = try docOf("foo bar\nbaz");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, Selection.caret(0));
    defer sels.deinit(a);
    moveHorizontal(a, &doc, &sels, 1, false, true);
    try testing.expect(sels.primary().head >= 3);
    moveLineEdge(&doc, &sels, true, false);
    try testing.expectEqual(@as(usize, 7), sels.primary().head);
    moveLineEdge(&doc, &sels, false, false);
    try testing.expectEqual(@as(usize, 0), sels.primary().head);
    moveDocEdge(&doc, &sels, true, false);
    try testing.expectEqual(@as(usize, 11), sels.primary().head);
}

test "view_model multi-caret insert applies once per caret" {
    const a = testing.allocator;
    var doc = try docOf("one two three");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, Selection.caret(0));
    defer sels.deinit(a);
    try sels.add(a, Selection.caret(4));
    try sels.add(a, Selection.caret(8));
    try insertText(a, &doc, &sels, "X");
    try expectText(&doc, "Xone Xtwo Xthree");
    // Carets landed after their inserts.
    try testing.expectEqual(@as(usize, 3), sels.count());
    try testing.expectEqual(@as(usize, 1), sels.sels.items[0].head);
    try testing.expectEqual(@as(usize, 6), sels.sels.items[1].head);
    try testing.expectEqual(@as(usize, 11), sels.sels.items[2].head);
    // One undo unit for the whole multi-edit.
    try undo(&doc, &sels);
    try expectText(&doc, "one two three");
}

test "view_model insert replaces selected ranges" {
    const a = testing.allocator;
    var doc = try docOf("aaa bbb");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, .{ .anchor = 0, .head = 3 });
    defer sels.deinit(a);
    try sels.add(a, .{ .anchor = 4, .head = 7 });
    try insertText(a, &doc, &sels, "z");
    try expectText(&doc, "z z");
}

test "view_model backspace variants" {
    const a = testing.allocator;
    var doc = try docOf("foo bar");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, Selection.caret(7));
    defer sels.deinit(a);
    try deleteBackward(a, &doc, &sels, false);
    try expectText(&doc, "foo ba");
    try deleteBackward(a, &doc, &sels, true);
    try expectText(&doc, "foo ");
    // Backspace at line start joins lines.
    var doc2 = try docOf("x\ny");
    defer doc2.deinit();
    var sels2 = try SelectionSet.initSingle(a, Selection.caret(2));
    defer sels2.deinit(a);
    try deleteBackward(a, &doc2, &sels2, false);
    try expectText(&doc2, "xy");
    try testing.expectEqual(@as(usize, 1), sels2.primary().head);
}

test "view_model delete forward and range delete" {
    const a = testing.allocator;
    var doc = try docOf("abcdef");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, .{ .anchor = 1, .head = 3 });
    defer sels.deinit(a);
    try deleteForward(a, &doc, &sels, false);
    try expectText(&doc, "adef");
    try testing.expectEqual(@as(usize, 1), sels.primary().head);
    try deleteForward(a, &doc, &sels, false);
    try expectText(&doc, "aef");
}

test "view_model newline auto-indent copies leading whitespace" {
    const a = testing.allocator;
    var doc = try docOf("    code");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, Selection.caret(8));
    defer sels.deinit(a);
    try insertNewlineIndent(a, &doc, &sels);
    try expectText(&doc, "    code\n    ");
    try testing.expectEqual(@as(usize, 13), sels.primary().head);
    // Enter before the indent's end only copies up to the caret.
    var doc2 = try docOf("  x");
    defer doc2.deinit();
    var sels2 = try SelectionSet.initSingle(a, Selection.caret(1));
    defer sels2.deinit(a);
    try insertNewlineIndent(a, &doc2, &sels2);
    try expectText(&doc2, " \n  x");
}

test "view_model tab stops pad to the next multiple" {
    const a = testing.allocator;
    var doc = try docOf("ab");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, Selection.caret(2));
    defer sels.deinit(a);
    try insertTabStop(a, &doc, &sels, TAB_WIDTH, true);
    try expectText(&doc, "ab  ");
    try insertTabStop(a, &doc, &sels, TAB_WIDTH, true);
    try expectText(&doc, "ab      ");
}

test "view_model tab honours width and literal-tab mode" {
    const a = testing.allocator;
    var doc = try docOf("ab");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, Selection.caret(2));
    defer sels.deinit(a);
    try insertTabStop(a, &doc, &sels, 8, true);
    try expectText(&doc, "ab      "); // 6 spaces to column 8
    try insertTabStop(a, &doc, &sels, 8, false);
    try expectText(&doc, "ab      \t");
    try testing.expectEqual(@as(usize, 9), sels.primary().head);
}

test "view_model select all, collapse, clamp" {
    const a = testing.allocator;
    var doc = try docOf("hello");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, Selection.caret(2));
    defer sels.deinit(a);
    selectAll(&doc, &sels);
    try testing.expectEqual(@as(usize, 0), sels.primary().start());
    try testing.expectEqual(@as(usize, 5), sels.primary().end());
    collapseToPrimary(&sels);
    try testing.expect(sels.primary().isCaret());
    sels.sels.items[0] = Selection.caret(99);
    clampSelections(&doc, &sels);
    try testing.expectEqual(@as(usize, 5), sels.primary().head);
}

test "view_model selected text joins ranges" {
    const a = testing.allocator;
    var doc = try docOf("one two three");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, .{ .anchor = 0, .head = 3 });
    defer sels.deinit(a);
    try sels.add(a, .{ .anchor = 8, .head = 13 });
    const text = try selectedText(a, &doc, &sels);
    defer a.free(text);
    try testing.expectEqualStrings("one\nthree", text);
}

test "view_model word and line ranges" {
    const a = testing.allocator;
    var doc = try docOf("foo bar\nnext");
    defer doc.deinit();
    const w = wordRangeAt(a, &doc, 5);
    try testing.expectEqual(@as(usize, 4), w.start());
    try testing.expectEqual(@as(usize, 7), w.end());
    const l = lineRangeAt(&doc, 5);
    try testing.expectEqual(@as(usize, 0), l.start());
    try testing.expectEqual(@as(usize, 8), l.end()); // newline included
    const l2 = lineRangeAt(&doc, 10);
    try testing.expectEqual(@as(usize, 8), l2.start());
    try testing.expectEqual(@as(usize, 12), l2.end());
}

test "view_model undo clamps selections" {
    const a = testing.allocator;
    var doc = try docOf("ab");
    defer doc.deinit();
    var sels = try SelectionSet.initSingle(a, Selection.caret(2));
    defer sels.deinit(a);
    try insertText(a, &doc, &sels, "cdefgh");
    try testing.expectEqual(@as(usize, 8), sels.primary().head);
    try undo(&doc, &sels);
    try expectText(&doc, "ab");
    try testing.expect(sels.primary().head <= 2);
    try redo(&doc, &sels);
    try expectText(&doc, "abcdefgh");
}
