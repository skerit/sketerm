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
const pos = @import("position.zig");
const session = @import("session.zig");

/// One queued change, with its inserted text owned by the queue (the
/// transaction's slices die with the transaction).
pub const Queued = struct {
    range: pos.Range,
    text: []u8,
};

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
    /// Set when a change could not be captured exactly (out of memory
    /// building the queue). The next flush then resends the whole
    /// document instead of a broken delta — silently dropping a change
    /// would desynchronise the server for the rest of the session.
    needs_full: bool = false,

    pub fn init(alloc: Allocator) DocSync {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *DocSync) void {
        self.clearQueue();
        self.queue.deinit(self.alloc);
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

    /// Capture one transaction's edits against the PRE-edit document.
    /// Call from `before_apply`; `doc` still holds the old text.
    pub fn noteEdits(self: *DocSync, doc: *const Document, edits: []const tr.Edit, enc: pos.Encoding) void {
        if (!self.open) return;
        if (edits.len == 0) return;
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
                self.clearQueue();
                self.needs_full = false;
                return;
            };
            for (self.queue.items) |q| {
                view.appendAssumeCapacity(.{ .range = q.range, .text = q.text });
            }
            sess.didChange(self.uri, self.version, view.items, full_text);
        }
        self.clearQueue();
        self.needs_full = false;
    }
};

// ======================================================================
// Tests
// ======================================================================

const testing = std.testing;

test "docsync: a transaction's edits queue in descending offset order" {
    var doc = try Document.initFromBytes(testing.allocator, "0123456789");
    defer doc.deinit();
    var ds = DocSync.init(testing.allocator);
    defer ds.deinit();
    ds.open = true;
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
    const edits = [_]tr.Edit{.{ .offset = 4, .deleted_len = 1, .inserted = "" }};
    ds.noteEdits(&doc, &edits, .utf16);
    try testing.expectEqual(@as(u32, 2), ds.queue.items[0].range.start.character);
    ds.clearQueue();
    ds.noteEdits(&doc, &edits, .utf8);
    try testing.expectEqual(@as(u32, 4), ds.queue.items[0].range.start.character);
}
