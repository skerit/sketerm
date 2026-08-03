//! Document: rope + revision counter + line-ending style + undo history.
//!
//! CRLF handling: `initFromBytes` detects the dominant line-ending
//! style, normalizes the in-memory text to LF, and `materialize`
//! re-applies CRLF on the way out when that was the loaded style.
//! All offsets in the public API are therefore LF-normalized bytes.
//!
//! Undo grouping: consecutive single-codepoint pure insertions typed at
//! the end of the previous one coalesce into one undo unit; the group
//! breaks when a whitespace character follows a non-whitespace one, on
//! `breakUndoGroup`, and on any non-typing transaction or undo/redo.
//!
//! Gotcha: `isDirty` compares revision numbers, so undoing back to the
//! saved state still reads dirty (revisions only grow).

const std = @import("std");
const Allocator = std.mem.Allocator;
const rope_mod = @import("rope.zig");
const Rope = rope_mod.Rope;
const tr = @import("transaction.zig");

pub const LineEnding = enum { lf, crlf };

pub const Error = tr.Error || Allocator.Error || error{NothingToUndo};

/// One stored history change: edits in the coordinates of the revision
/// they apply to, with owned inserted-text buffers.
const OwnedEdit = struct {
    offset: usize,
    deleted_len: usize,
    inserted: []u8,
};

const HistEntry = struct {
    edits: std.ArrayList(OwnedEdit),

    fn deinitFree(self: *HistEntry, alloc: Allocator) void {
        for (self.edits.items) |e| alloc.free(e.inserted);
        self.edits.deinit(alloc);
    }
};

const Typing = struct {
    /// Byte offset just past the last typed character.
    end: usize,
    /// The last typed codepoint (for the whitespace word-break rule).
    last_cp: u21,
};

pub const Document = struct {
    alloc: Allocator,
    rope: Rope,
    revision: u64,
    saved_revision: u64,
    line_ending: LineEnding,
    undo_stack: std.ArrayList(HistEntry),
    redo_stack: std.ArrayList(HistEntry),
    typing: ?Typing,

    pub fn initEmpty(alloc: Allocator) Document {
        return .{
            .alloc = alloc,
            .rope = Rope.init(alloc),
            .revision = 0,
            .saved_revision = 0,
            .line_ending = .lf,
            .undo_stack = .empty,
            .redo_stack = .empty,
            .typing = null,
        };
    }

    /// Detects the line-ending style and loads an LF-normalized copy.
    /// Lone \r bytes are left untouched — only \r\n pairs normalize.
    pub fn initFromBytes(alloc: Allocator, bytes: []const u8) !Document {
        var crlf: usize = 0;
        var lone_lf: usize = 0;
        var i: usize = 0;
        while (i < bytes.len) : (i += 1) {
            if (bytes[i] == '\n') {
                if (i > 0 and bytes[i - 1] == '\r') crlf += 1 else lone_lf += 1;
            }
        }
        const style: LineEnding = if (crlf > 0 and crlf >= lone_lf) .crlf else .lf;

        var doc = initEmpty(alloc);
        errdefer doc.deinit();
        doc.line_ending = style;
        if (crlf == 0) {
            doc.rope = try Rope.initFromBytes(alloc, bytes);
        } else {
            const norm = try alloc.alloc(u8, bytes.len - crlf);
            defer alloc.free(norm);
            var w: usize = 0;
            i = 0;
            while (i < bytes.len) : (i += 1) {
                if (bytes[i] == '\r' and i + 1 < bytes.len and bytes[i + 1] == '\n') continue;
                norm[w] = bytes[i];
                w += 1;
            }
            std.debug.assert(w == norm.len);
            doc.rope = try Rope.initFromBytes(alloc, norm);
        }
        return doc;
    }

    pub fn deinit(self: *Document) void {
        self.rope.deinit();
        for (self.undo_stack.items) |*e| e.deinitFree(self.alloc);
        self.undo_stack.deinit(self.alloc);
        for (self.redo_stack.items) |*e| e.deinitFree(self.alloc);
        self.redo_stack.deinit(self.alloc);
    }

    pub fn isDirty(self: *const Document) bool {
        return self.revision != self.saved_revision;
    }

    pub fn markSaved(self: *Document) void {
        self.saved_revision = self.revision;
    }

    /// Caller-owned bytes in the document's on-disk line-ending style.
    pub fn materialize(self: *const Document, alloc: Allocator) ![]u8 {
        const n = self.rope.len();
        switch (self.line_ending) {
            .lf => return try self.rope.sliceAlloc(alloc, 0, n),
            .crlf => {
                const out = try alloc.alloc(u8, n + self.rope.newlineCount());
                errdefer alloc.free(out);
                var w: usize = 0;
                var it = self.rope.iterateRange(0, n);
                while (it.next()) |chunk| {
                    for (chunk) |b| {
                        if (b == '\n') {
                            out[w] = '\r';
                            w += 1;
                        }
                        out[w] = b;
                        w += 1;
                    }
                }
                std.debug.assert(w == out.len);
                return out;
            },
        }
    }

    /// Convenience: whole LF-normalized text, caller-owned.
    pub fn textAlloc(self: *const Document, alloc: Allocator) ![]u8 {
        return try self.rope.sliceAlloc(alloc, 0, self.rope.len());
    }

    // ---- transactions -------------------------------------------------

    /// Applies `tx` atomically and returns the new revision. Edits are
    /// pre-transaction coordinates, applied back-to-front internally.
    pub fn applyTransaction(self: *Document, tx: *const tr.Transaction) Error!u64 {
        if (tx.base_revision != self.revision) return Error.RevisionMismatch;
        try tx.validate(self.rope.len());

        const typing_cp = self.typingCandidate(tx);
        if (typing_cp == null) self.typing = null;

        var inverse = try self.applyEdits(tx.edits.items);
        errdefer freeEntryList(self.alloc, &inverse);

        self.clearRedo();
        self.revision += 1;

        if (typing_cp) |cp| {
            const edit = tx.edits.items[0];
            const new_end = edit.offset + edit.inserted.len;
            if (self.typing) |t| {
                const breaks = isSpaceCp(cp) and !isSpaceCp(t.last_cp);
                if (!breaks and t.end == edit.offset and self.undo_stack.items.len > 0) {
                    // Coalesce: extend the top entry's inverse delete.
                    const top = &self.undo_stack.items[self.undo_stack.items.len - 1];
                    std.debug.assert(top.edits.items.len == 1);
                    top.edits.items[0].deleted_len += edit.inserted.len;
                    self.typing = .{ .end = new_end, .last_cp = cp };
                    freeEntryList(self.alloc, &inverse);
                    return self.revision;
                }
            }
            self.typing = .{ .end = new_end, .last_cp = cp };
        }

        try self.undo_stack.append(self.alloc, .{ .edits = inverse });
        return self.revision;
    }

    /// Undoes the top history entry; error.NothingToUndo when empty.
    pub fn undo(self: *Document) Error!u64 {
        if (self.undo_stack.items.len == 0) return Error.NothingToUndo;
        self.typing = null;
        var entry = self.undo_stack.pop().?;
        defer entry.deinitFree(self.alloc);
        var redo_entry = try self.applyOwned(entry.edits.items);
        errdefer freeEntryList(self.alloc, &redo_entry);
        try self.redo_stack.append(self.alloc, .{ .edits = redo_entry });
        self.revision += 1;
        return self.revision;
    }

    pub fn redo(self: *Document) Error!u64 {
        if (self.redo_stack.items.len == 0) return Error.NothingToUndo;
        self.typing = null;
        var entry = self.redo_stack.pop().?;
        defer entry.deinitFree(self.alloc);
        var undo_entry = try self.applyOwned(entry.edits.items);
        errdefer freeEntryList(self.alloc, &undo_entry);
        try self.undo_stack.append(self.alloc, .{ .edits = undo_entry });
        self.revision += 1;
        return self.revision;
    }

    pub fn canUndo(self: *const Document) bool {
        return self.undo_stack.items.len > 0;
    }

    pub fn canRedo(self: *const Document) bool {
        return self.redo_stack.items.len > 0;
    }

    /// Ends the current typing coalescing group.
    pub fn breakUndoGroup(self: *Document) void {
        self.typing = null;
    }

    // ---- internals ----------------------------------------------------

    /// Non-null iff `tx` is a lone single-codepoint pure insertion.
    fn typingCandidate(self: *const Document, tx: *const tr.Transaction) ?u21 {
        _ = self;
        if (tx.edits.items.len != 1) return null;
        const e = tx.edits.items[0];
        if (e.deleted_len != 0 or e.inserted.len == 0) return null;
        const seq_len = std.unicode.utf8ByteSequenceLength(e.inserted[0]) catch return null;
        if (seq_len != e.inserted.len) return null;
        return std.unicode.utf8Decode(e.inserted) catch null;
    }

    fn clearRedo(self: *Document) void {
        for (self.redo_stack.items) |*e| e.deinitFree(self.alloc);
        self.redo_stack.clearRetainingCapacity();
    }

    fn freeEntryList(alloc: Allocator, list: *std.ArrayList(OwnedEdit)) void {
        for (list.items) |e| alloc.free(e.inserted);
        list.deinit(alloc);
    }

    fn applyOwned(self: *Document, edits: []const OwnedEdit) Allocator.Error!std.ArrayList(OwnedEdit) {
        var view: std.ArrayList(tr.Edit) = .empty;
        defer view.deinit(self.alloc);
        for (edits) |e| {
            try view.append(self.alloc, .{
                .offset = e.offset,
                .deleted_len = e.deleted_len,
                .inserted = e.inserted,
            });
        }
        return try self.applyEdits(view.items);
    }

    /// Applies sorted non-overlapping edits back-to-front and returns
    /// the inverse edit list in post-apply coordinates.
    fn applyEdits(self: *Document, edits: []const tr.Edit) Allocator.Error!std.ArrayList(OwnedEdit) {
        var inverse: std.ArrayList(OwnedEdit) = .empty;
        errdefer freeEntryList(self.alloc, &inverse);

        // Build inverse entries in ascending order first (they need the
        // pre-apply text for the deleted bytes and the cumulative delta
        // of EARLIER edits for post-apply offsets).
        var delta: isize = 0;
        for (edits) |e| {
            const deleted = try self.rope.sliceAlloc(self.alloc, e.offset, e.offset + e.deleted_len);
            errdefer self.alloc.free(deleted);
            const post_off: usize = @intCast(@as(isize, @intCast(e.offset)) + delta);
            try inverse.append(self.alloc, .{
                .offset = post_off,
                .deleted_len = e.inserted.len,
                .inserted = deleted,
            });
            delta += @as(isize, @intCast(e.inserted.len)) - @as(isize, @intCast(e.deleted_len));
        }

        // Apply back-to-front so pre-transaction offsets stay valid.
        var i = edits.len;
        while (i > 0) {
            i -= 1;
            const e = edits[i];
            try self.rope.delete(e.offset, e.offset + e.deleted_len);
            try self.rope.insert(e.offset, e.inserted);
        }
        return inverse;
    }
};

fn isSpaceCp(cp: u21) bool {
    return switch (cp) {
        ' ', '\t', '\n', '\r', 0x0B, 0x0C, 0xA0 => true,
        else => false,
    };
}

// ======================================================================
// Tests
// ======================================================================

const testing = std.testing;

fn expectText(doc: *const Document, expected: []const u8) !void {
    const got = try doc.textAlloc(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "document CRLF detect, normalize, and round-trip" {
    var doc = try Document.initFromBytes(testing.allocator, "one\r\ntwo\r\nthree");
    defer doc.deinit();
    try testing.expectEqual(LineEnding.crlf, doc.line_ending);
    try expectText(&doc, "one\ntwo\nthree");

    const out = try doc.materialize(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("one\r\ntwo\r\nthree", out);
}

test "document LF input stays LF" {
    var doc = try Document.initFromBytes(testing.allocator, "a\nb\n");
    defer doc.deinit();
    try testing.expectEqual(LineEnding.lf, doc.line_ending);
    const out = try doc.materialize(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a\nb\n", out);
}

test "document mixed endings pick the majority, lone CR preserved" {
    var doc = try Document.initFromBytes(testing.allocator, "a\r\nb\r\nc\nd\rx");
    defer doc.deinit();
    try testing.expectEqual(LineEnding.crlf, doc.line_ending);
    try expectText(&doc, "a\nb\nc\nd\rx");
    const out = try doc.materialize(testing.allocator);
    defer testing.allocator.free(out);
    // Materialize normalizes every logical newline to the style.
    try testing.expectEqualStrings("a\r\nb\r\nc\r\nd\rx", out);
}

test "document CRLF edits round-trip through materialize" {
    var doc = try Document.initFromBytes(testing.allocator, "x\r\ny");
    defer doc.deinit();
    var tx = tr.Transaction.init(doc.revision);
    defer tx.deinit(testing.allocator);
    try tx.addInsert(testing.allocator, 2, "mid\n");
    _ = try doc.applyTransaction(&tx);
    const out = try doc.materialize(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("x\r\nmid\r\ny", out);
}

test "document multi-edit transaction is atomic and pre-offset based" {
    var doc = try Document.initFromBytes(testing.allocator, "0123456789");
    defer doc.deinit();
    var tx = tr.Transaction.init(0);
    defer tx.deinit(testing.allocator);
    try tx.addReplace(testing.allocator, 1, 2, "AB"); // "12" -> "AB"
    try tx.addInsert(testing.allocator, 5, "X");
    try tx.addDelete(testing.allocator, 8, 1); // deletes "8"
    const rev = try doc.applyTransaction(&tx);
    try testing.expectEqual(@as(u64, 1), rev);
    try expectText(&doc, "0AB34X5679");
    try testing.expect(doc.isDirty());
}

test "document revision mismatch is rejected" {
    var doc = try Document.initFromBytes(testing.allocator, "abc");
    defer doc.deinit();
    var tx = tr.Transaction.init(7);
    defer tx.deinit(testing.allocator);
    try tx.addInsert(testing.allocator, 0, "x");
    try testing.expectError(Error.RevisionMismatch, doc.applyTransaction(&tx));
}

test "document undo and redo restore exact text" {
    var doc = try Document.initFromBytes(testing.allocator, "hello world");
    defer doc.deinit();
    var tx = tr.Transaction.init(0);
    defer tx.deinit(testing.allocator);
    try tx.addReplace(testing.allocator, 0, 5, "goodbye");
    try tx.addDelete(testing.allocator, 5, 1); // the space
    _ = try doc.applyTransaction(&tx);
    try expectText(&doc, "goodbyeworld");

    _ = try doc.undo();
    try expectText(&doc, "hello world");
    try testing.expect(!doc.canUndo());
    _ = try doc.redo();
    try expectText(&doc, "goodbyeworld");
    _ = try doc.undo();
    try expectText(&doc, "hello world");
    try testing.expectError(Error.NothingToUndo, doc.undo());
}

fn typeChar(doc: *Document, offset: usize, ch: []const u8) !void {
    var tx = tr.Transaction.init(doc.revision);
    defer tx.deinit(testing.allocator);
    try tx.addInsert(testing.allocator, offset, ch);
    _ = try doc.applyTransaction(&tx);
}

test "document typing coalesces into one undo unit" {
    var doc = Document.initEmpty(testing.allocator);
    defer doc.deinit();
    for ("hello", 0..) |_, i| try typeChar(&doc, i, "hello"[i .. i + 1]);
    try expectText(&doc, "hello");
    try testing.expectEqual(@as(usize, 1), doc.undo_stack.items.len);
    _ = try doc.undo();
    try expectText(&doc, "");
    _ = try doc.redo();
    try expectText(&doc, "hello");
}

test "document whitespace after word breaks the undo group" {
    var doc = Document.initEmpty(testing.allocator);
    defer doc.deinit();
    const input = "hi there";
    for (input, 0..) |_, i| try typeChar(&doc, i, input[i .. i + 1]);
    // Groups: "hi", " there" (space after non-space starts a new group).
    try testing.expectEqual(@as(usize, 2), doc.undo_stack.items.len);
    _ = try doc.undo();
    try expectText(&doc, "hi");
    _ = try doc.undo();
    try expectText(&doc, "");
}

test "document breakUndoGroup splits typing" {
    var doc = Document.initEmpty(testing.allocator);
    defer doc.deinit();
    try typeChar(&doc, 0, "a");
    try typeChar(&doc, 1, "b");
    doc.breakUndoGroup();
    try typeChar(&doc, 2, "c");
    try testing.expectEqual(@as(usize, 2), doc.undo_stack.items.len);
    _ = try doc.undo();
    try expectText(&doc, "ab");
}

test "document non-contiguous typing does not coalesce" {
    var doc = Document.initEmpty(testing.allocator);
    defer doc.deinit();
    try typeChar(&doc, 0, "a");
    try typeChar(&doc, 1, "b");
    try typeChar(&doc, 0, "z"); // typed elsewhere
    try testing.expectEqual(@as(usize, 2), doc.undo_stack.items.len);
    _ = try doc.undo();
    try expectText(&doc, "ab");
}

test "document multibyte typed codepoints coalesce" {
    var doc = Document.initEmpty(testing.allocator);
    defer doc.deinit();
    try typeChar(&doc, 0, "\u{e9}"); // é (2 bytes)
    try typeChar(&doc, 2, "\u{e8}"); // è
    try testing.expectEqual(@as(usize, 1), doc.undo_stack.items.len);
    _ = try doc.undo();
    try expectText(&doc, "");
}

test "document applyTransaction clears redo and typing continues correctly after undo" {
    var doc = Document.initEmpty(testing.allocator);
    defer doc.deinit();
    try typeChar(&doc, 0, "a");
    _ = try doc.undo();
    try testing.expect(doc.canRedo());
    try typeChar(&doc, 0, "b");
    try testing.expect(!doc.canRedo());
    try expectText(&doc, "b");
    // The pre-undo group must not have been extended.
    _ = try doc.undo();
    try expectText(&doc, "");
}

test "document markSaved clears dirty" {
    var doc = try Document.initFromBytes(testing.allocator, "x");
    defer doc.deinit();
    try testing.expect(!doc.isDirty());
    try typeChar(&doc, 1, "y");
    try testing.expect(doc.isDirty());
    doc.markSaved();
    try testing.expect(!doc.isDirty());
}
