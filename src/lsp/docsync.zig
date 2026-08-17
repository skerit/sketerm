//! Per-document server-sync state: the LSP version counter and the
//! queue of `contentChanges` waiting for the didChange debounce.
//!
//! ## Why the changes are captured in a pre-edit observer
//!
//! An incremental `didChange` needs the range in the coordinates of the
//! text the server currently has, i.e. BEFORE the edit — and once the
//! rope has been mutated those positions are unrecoverable, exactly the
//! problem the incremental highlighter has with Tree-sitter's
//! `old_end_point`. So the queue is filled from
//! `Document.EditObserver.before_apply`, the same hook and the same
//! moment, and the editor's third observer slot exists for it.
//!
//! ## Why a transaction's edits are queued in DESCENDING offset order
//!
//! `Transaction.edits` are sorted ascending in PRE-transaction
//! coordinates; the document applies them back-to-front so earlier
//! edits never shift later ones. LSP `contentChanges`, in contrast, are
//! applied by the server in ARRAY order, each against the text the
//! previous ones produced. Queuing them descending reproduces the
//! document's own back-to-front application exactly, so no range needs
//! adjusting for its predecessors.

const std = @import("std");
const Allocator = std.mem.Allocator;
const tr = @import("../editor/transaction.zig");
const Document = @import("../editor/document.zig").Document;
const Rope = @import("../editor/rope.zig").Rope;
const pos = @import("position.zig");
const session = @import("session.zig");

/// One queued change, with its inserted text owned by the queue (the
/// transaction's slices die with the transaction).
pub const Queued = struct {
    range: pos.Range,
    text: []u8,
};

const MapBatch = struct {
    start: usize,
    len: usize,
};

pub const OffsetRange = struct { start: usize, end: usize };

pub const DocSync = struct {
    alloc: Allocator,
    /// `file://` URI the server knows this document by. Owned.
    uri: []u8 = &.{},
    /// LSP languageId. Borrowed from the static table in servers.zig.
    language_id: []const u8 = "",
    /// Bumped on every flushed didChange. LSP requires strictly
    /// increasing versions per document.
    version: i64 = 0,
    /// The server has an open document for `uri`.
    open: bool = false,
    /// Changes captured since the last flush.
    queue: std.ArrayList(Queued) = .empty,
    /// Document revision the queue's ranges end at — the revision the
    /// server will be at once the queue is flushed.
    revision: u64 = 0,
    /// Document revision represented by `version` on the server.
    sent_revision: u64 = 0,
    /// Set when a change could not be captured exactly (out of memory
    /// building the queue). The next flush then resends the whole
    /// document instead of a broken delta — silently dropping a change
    /// would desynchronise the server for the rest of the session.
    needs_full: bool = false,
    /// The rope represented by the latest sent LSP version.
    sent_rope: ?Rope = null,
    /// Local edit batches carrying anchors from `sent_revision` to
    /// `revision`; batches stay separate because each transaction's
    /// offsets use the document produced by the preceding transaction.
    map_edits: std.ArrayList(tr.Edit) = .empty,
    map_batches: std.ArrayList(MapBatch) = .empty,
    map_valid: bool = true,

    pub fn init(alloc: Allocator) DocSync {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *DocSync) void {
        self.clearQueue();
        self.queue.deinit(self.alloc);
        self.clearMap();
        self.clearSentRope();
        self.map_edits.deinit(self.alloc);
        self.map_batches.deinit(self.alloc);
        if (self.uri.len > 0) self.alloc.free(self.uri);
        self.uri = &.{};
    }

    pub fn setUri(self: *DocSync, uri: []const u8) Allocator.Error!void {
        if (self.uri.len > 0) self.alloc.free(self.uri);
        self.uri = try self.alloc.dupe(u8, uri);
    }

    pub fn clearQueue(self: *DocSync) void {
        for (self.queue.items) |q| self.alloc.free(q.text);
        self.queue.clearRetainingCapacity();
    }

    pub fn hasPendingChanges(self: *const DocSync) bool {
        return self.queue.items.len > 0 or self.needs_full;
    }

    /// Record the exact editor revision represented by a sent LSP document version.
    pub fn noteSent(self: *DocSync, version: i64, document_revision: u64, text: []const u8) void {
        self.clearQueue();
        self.needs_full = false;
        self.version = version;
        self.revision = document_revision;
        self.sent_revision = document_revision;
        self.clearMap();
        self.replaceSentRope(text);
    }

    /// A numeric workspace edit version is current only for the exact synchronized document state.
    pub fn acceptsEditVersion(self: *const DocSync, version: i64, document_revision: u64) bool {
        return self.open and version == self.version and !self.hasPendingChanges() and
            document_revision == self.sent_revision;
    }

    /// Capture one transaction's edits against the PRE-edit document.
    /// Call from `before_apply`; `doc` still holds the old text.
    pub fn noteEdits(self: *DocSync, doc: *const Document, edits: []const tr.Edit, enc: pos.Encoding) void {
        if (!self.open) return;
        if (edits.len == 0) return;
        self.captureMap(doc, edits);
        // One transaction produces one new document revision, regardless
        // of how many edits it contains.
        self.revision = doc.revision + 1;
        var i = edits.len;
        while (i > 0) {
            i -= 1;
            const e = edits[i];
            const text = self.alloc.dupe(u8, e.inserted) catch {
                self.needs_full = true;
                return;
            };
            self.queue.append(self.alloc, .{
                .range = pos.offsetToRange(&doc.rope, e.offset, e.offset + e.deleted_len, enc),
                .text = text,
            }) catch {
                self.alloc.free(text);
                self.needs_full = true;
                return;
            };
        }
    }

    /// Flush the queue as one `didChange`. `full_text` is used when the
    /// server wants full sync, or when a capture failed.
    pub fn flush(self: *DocSync, sess: *session.Session, full_text: []const u8) void {
        if (!self.open or !self.hasPendingChanges()) return;
        self.version += 1;
        if (self.needs_full) {
            sess.didChange(self.uri, self.version, &.{}, full_text);
        } else {
            // The wire type borrows; a stack copy of the view is enough.
            var view: std.ArrayList(session.ContentChange) = .empty;
            defer view.deinit(self.alloc);
            view.ensureTotalCapacity(self.alloc, self.queue.items.len) catch {
                sess.didChange(self.uri, self.version, &.{}, full_text);
                self.finishFlush(full_text);
                return;
            };
            for (self.queue.items) |q| {
                view.appendAssumeCapacity(.{ .range = q.range, .text = q.text });
            }
            sess.didChange(self.uri, self.version, view.items, full_text);
        }
        self.finishFlush(full_text);
    }

    /// A publication mapper exists only when its ranges have a known source rope and forward edit path.
    pub fn diagnosticMapper(self: *const DocSync, doc: *const Document, published_version: ?i64) ?DiagnosticMapper {
        if (!self.open or doc.revision != self.revision) return null;
        if (published_version) |version| {
            if (version != self.version) return null;
        }
        if (self.revision == self.sent_revision) {
            return .{ .sync = self, .rope = &doc.rope, .revision = doc.revision, .map_pending = false };
        }
        if (!self.map_valid or self.sent_rope == null) return null;
        if (self.sent_revision + @as(u64, @intCast(self.map_batches.items.len)) != self.revision) return null;
        return .{ .sync = self, .rope = &self.sent_rope.?, .revision = doc.revision, .map_pending = true };
    }

    pub const DiagnosticMapper = struct {
        sync: *const DocSync,
        rope: *const Rope,
        revision: u64,
        map_pending: bool,

        /// Convert against the server-visible rope, then carry the anchors through unsent edits.
        pub fn rangeToOffsets(self: DiagnosticMapper, range: pos.Range, enc: pos.Encoding) OffsetRange {
            const source = pos.rangeToOffsets(self.rope, range, enc);
            var out = OffsetRange{ .start = source.start, .end = source.end };
            if (!self.map_pending) return out;
            for (self.sync.map_batches.items) |batch| {
                const edits = self.sync.map_edits.items[batch.start .. batch.start + batch.len];
                out.start = tr.mapOffset(edits, out.start, .other);
                out.end = @max(tr.mapOffset(edits, out.end, .other), out.start);
            }
            return out;
        }
    };

    fn captureMap(self: *DocSync, doc: *const Document, edits: []const tr.Edit) void {
        if (!self.map_valid) return;
        if (doc.revision != self.revision) {
            self.invalidateMap();
            return;
        }
        if (self.sent_rope == null) {
            if (doc.revision != self.sent_revision) {
                self.invalidateMap();
                return;
            }
            const text = doc.textAlloc(self.alloc) catch {
                self.invalidateMap();
                return;
            };
            defer self.alloc.free(text);
            self.sent_rope = Rope.initFromBytes(self.alloc, text) catch {
                self.invalidateMap();
                return;
            };
        }
        self.map_edits.ensureUnusedCapacity(self.alloc, edits.len) catch {
            self.invalidateMap();
            return;
        };
        self.map_batches.ensureUnusedCapacity(self.alloc, 1) catch {
            self.invalidateMap();
            return;
        };
        const start = self.map_edits.items.len;
        for (edits) |edit| {
            const inserted = if (edit.inserted.len > 0)
                self.alloc.dupe(u8, edit.inserted) catch {
                    self.invalidateMap();
                    return;
                }
            else
                &.{};
            self.map_edits.appendAssumeCapacity(.{
                .offset = edit.offset,
                .deleted_len = edit.deleted_len,
                .inserted = inserted,
            });
        }
        self.map_batches.appendAssumeCapacity(.{ .start = start, .len = edits.len });
    }

    fn invalidateMap(self: *DocSync) void {
        self.clearMap();
        self.map_valid = false;
    }

    fn clearMap(self: *DocSync) void {
        for (self.map_edits.items) |edit| {
            if (edit.inserted.len > 0) self.alloc.free(edit.inserted);
        }
        self.map_edits.clearRetainingCapacity();
        self.map_batches.clearRetainingCapacity();
        self.map_valid = true;
    }

    fn finishFlush(self: *DocSync, full_text: []const u8) void {
        self.advanceSentRope(full_text);
        self.clearQueue();
        self.needs_full = false;
        self.sent_revision = self.revision;
        self.clearMap();
    }

    fn advanceSentRope(self: *DocSync, full_text: []const u8) void {
        var advanced = self.map_valid and self.sent_rope != null and
            self.sent_revision + @as(u64, @intCast(self.map_batches.items.len)) == self.revision;
        if (advanced) outer: for (self.map_batches.items) |batch| {
            const edits = self.map_edits.items[batch.start .. batch.start + batch.len];
            var i = edits.len;
            while (i > 0) {
                i -= 1;
                const edit = edits[i];
                self.sent_rope.?.delete(edit.offset, edit.offset + edit.deleted_len) catch {
                    advanced = false;
                    break :outer;
                };
                self.sent_rope.?.insert(edit.offset, edit.inserted) catch {
                    advanced = false;
                    break :outer;
                };
            }
        };
        if (!advanced) self.replaceSentRope(full_text);
    }

    fn replaceSentRope(self: *DocSync, text: []const u8) void {
        const next = Rope.initFromBytes(self.alloc, text) catch {
            self.clearSentRope();
            return;
        };
        self.clearSentRope();
        self.sent_rope = next;
    }

    fn clearSentRope(self: *DocSync) void {
        if (self.sent_rope) |*rope| rope.deinit();
        self.sent_rope = null;
    }
};

// ======================================================================
// Tests
// ======================================================================

const testing = std.testing;

fn noteSentDoc(ds: *DocSync, version: i64, doc: *const Document) !void {
    const text = try doc.textAlloc(testing.allocator);
    defer testing.allocator.free(text);
    ds.noteSent(version, doc.revision, text);
}

test "docsync: a transaction's edits queue in descending offset order" {
    var doc = try Document.initFromBytes(testing.allocator, "0123456789");
    defer doc.deinit();
    var ds = DocSync.init(testing.allocator);
    defer ds.deinit();
    ds.open = true;
    try noteSentDoc(&ds, 1, &doc);
    const edits = [_]tr.Edit{
        .{ .offset = 1, .deleted_len = 2, .inserted = "AB" },
        .{ .offset = 6, .deleted_len = 0, .inserted = "X" },
    };
    ds.noteEdits(&doc, &edits, .utf16);
    try testing.expectEqual(@as(usize, 2), ds.queue.items.len);
    // Descending: the offset-6 edit is queued FIRST so applying them in
    // order never invalidates the second range.
    try testing.expectEqual(@as(u32, 6), ds.queue.items[0].range.start.character);
    try testing.expectEqualStrings("X", ds.queue.items[0].text);
    try testing.expectEqual(@as(u32, 1), ds.queue.items[1].range.start.character);
    try testing.expectEqual(@as(u32, 3), ds.queue.items[1].range.end.character);
    try testing.expectEqualStrings("AB", ds.queue.items[1].text);
}

test "docsync: nothing is captured for a document the server has not opened" {
    var doc = try Document.initFromBytes(testing.allocator, "abc");
    defer doc.deinit();
    var ds = DocSync.init(testing.allocator);
    defer ds.deinit();
    const edits = [_]tr.Edit{.{ .offset = 0, .deleted_len = 0, .inserted = "z" }};
    ds.noteEdits(&doc, &edits, .utf16);
    try testing.expect(!ds.hasPendingChanges());
}

test "docsync: ranges use the negotiated encoding" {
    var doc = try Document.initFromBytes(testing.allocator, "\u{1F600}xy");
    defer doc.deinit();
    var ds = DocSync.init(testing.allocator);
    defer ds.deinit();
    ds.open = true;
    try noteSentDoc(&ds, 1, &doc);
    const edits = [_]tr.Edit{.{ .offset = 4, .deleted_len = 1, .inserted = "" }};
    ds.noteEdits(&doc, &edits, .utf16);
    try testing.expectEqual(@as(u32, 2), ds.queue.items[0].range.start.character);
    try noteSentDoc(&ds, 1, &doc);
    ds.noteEdits(&doc, &edits, .utf8);
    try testing.expectEqual(@as(u32, 4), ds.queue.items[0].range.start.character);
}

test "docsync: workspace edit rejects a mismatched numeric version" {
    var doc = try Document.initFromBytes(testing.allocator, "abc");
    defer doc.deinit();
    var ds = DocSync.init(testing.allocator);
    defer ds.deinit();
    ds.open = true;
    try noteSentDoc(&ds, 7, &doc);

    try testing.expect(!ds.acceptsEditVersion(6, doc.revision));
    try testing.expect(!ds.acceptsEditVersion(8, doc.revision));
}

test "docsync: unchanged synchronized document accepts its numeric version" {
    var doc = try Document.initFromBytes(testing.allocator, "abc");
    defer doc.deinit();
    var ds = DocSync.init(testing.allocator);
    defer ds.deinit();
    ds.open = true;
    try noteSentDoc(&ds, 7, &doc);

    try testing.expect(ds.acceptsEditVersion(7, doc.revision));

    var tx = tr.Transaction.init(doc.revision);
    defer tx.deinit(testing.allocator);
    try tx.addInsert(testing.allocator, 0, "x");
    ds.noteEdits(&doc, tx.edits.items, .utf16);
    _ = try doc.applyTransaction(&tx);
    try testing.expect(!ds.acceptsEditVersion(7, doc.revision));
}

test "docsync: diagnostics during unsent edits map from the sent rope" {
    for ([_]pos.Encoding{ .utf8, .utf16 }) |enc| {
        var doc = try Document.initFromBytes(testing.allocator, "\u{1F600} BAD");
        defer doc.deinit();
        var ds = DocSync.init(testing.allocator);
        defer ds.deinit();
        ds.open = true;
        try noteSentDoc(&ds, 1, &doc);

        var tx = tr.Transaction.init(doc.revision);
        defer tx.deinit(testing.allocator);
        try tx.addInsert(testing.allocator, 0, "x");
        ds.noteEdits(&doc, tx.edits.items, enc);
        _ = try doc.applyTransaction(&tx);

        const start: u32 = if (enc == .utf8) 5 else 3;
        const mapper = ds.diagnosticMapper(&doc, 1) orelse return error.TestExpectedMapper;
        const offsets = mapper.rangeToOffsets(.{
            .start = .{ .line = 0, .character = start },
            .end = .{ .line = 0, .character = start + 3 },
        }, enc);
        try testing.expectEqual(@as(usize, 6), offsets.start);
        try testing.expectEqual(@as(usize, 9), offsets.end);
        try testing.expectEqual(doc.revision, mapper.revision);
    }
}

test "docsync: in-order diagnostic versions use their sent revision" {
    var doc = try Document.initFromBytes(testing.allocator, "A\nBAD\n");
    defer doc.deinit();
    var ds = DocSync.init(testing.allocator);
    defer ds.deinit();
    ds.open = true;
    try noteSentDoc(&ds, 1, &doc);

    var tx = tr.Transaction.init(doc.revision);
    defer tx.deinit(testing.allocator);
    try tx.addInsert(testing.allocator, 0, "x\n");
    ds.noteEdits(&doc, tx.edits.items, .utf16);
    _ = try doc.applyTransaction(&tx);

    var tx2 = tr.Transaction.init(doc.revision);
    defer tx2.deinit(testing.allocator);
    try tx2.addInsert(testing.allocator, 0, "y\n");
    ds.noteEdits(&doc, tx2.edits.items, .utf16);
    _ = try doc.applyTransaction(&tx2);

    const pending = ds.diagnosticMapper(&doc, 1) orelse return error.TestExpectedMapper;
    const pending_offsets = pending.rangeToOffsets(.{
        .start = .{ .line = 1, .character = 0 },
        .end = .{ .line = 1, .character = 3 },
    }, .utf16);
    try testing.expectEqual(@as(usize, 6), pending_offsets.start);

    try noteSentDoc(&ds, 2, &doc);
    const current = ds.diagnosticMapper(&doc, 2) orelse return error.TestExpectedMapper;
    const current_offsets = current.rangeToOffsets(.{
        .start = .{ .line = 3, .character = 0 },
        .end = .{ .line = 3, .character = 3 },
    }, .utf16);
    try testing.expectEqual(@as(usize, 6), current_offsets.start);
}

test "docsync: v1 diagnostics arriving after v2 are stale" {
    var doc = try Document.initFromBytes(testing.allocator, "BAD");
    defer doc.deinit();
    var ds = DocSync.init(testing.allocator);
    defer ds.deinit();
    ds.open = true;
    try noteSentDoc(&ds, 1, &doc);
    try noteSentDoc(&ds, 2, &doc);

    try testing.expect(ds.diagnosticMapper(&doc, 1) == null);
    try testing.expect(ds.diagnosticMapper(&doc, 2) != null);
    try testing.expect(ds.diagnosticMapper(&doc, 3) == null);
}

test "docsync: unversioned diagnostics map conservatively through unsent edits" {
    var doc = try Document.initFromBytes(testing.allocator, "A\nBAD");
    defer doc.deinit();
    var ds = DocSync.init(testing.allocator);
    defer ds.deinit();
    ds.open = true;
    try noteSentDoc(&ds, 1, &doc);

    var tx = tr.Transaction.init(doc.revision);
    defer tx.deinit(testing.allocator);
    try tx.addInsert(testing.allocator, 0, "x\n");
    ds.noteEdits(&doc, tx.edits.items, .utf16);
    _ = try doc.applyTransaction(&tx);

    const mapper = ds.diagnosticMapper(&doc, null) orelse return error.TestExpectedMapper;
    const offsets = mapper.rangeToOffsets(.{
        .start = .{ .line = 1, .character = 0 },
        .end = .{ .line = 1, .character = 3 },
    }, .utf16);
    try testing.expectEqual(@as(usize, 4), offsets.start);
}
