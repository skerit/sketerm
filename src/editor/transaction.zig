//! Transactions: ordered multi-edit changes against a specific revision.
//!
//! Edit offsets are interpreted against the PRE-transaction text; the
//! document applies them back-to-front so earlier edits never shift
//! later ones. `mapOffset` is the shared position-mapping primitive
//! used by selection.zig and undo bookkeeping.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// One edit: delete `deleted_len` bytes at `offset`, then insert
/// `inserted` there. Offsets are pre-transaction coordinates.
pub const Edit = struct {
    offset: usize,
    deleted_len: usize,
    inserted: []const u8,
};

/// How a position that touches an edit should be mapped.
/// `editor` is the view that performed the edit: a caret at the edit
/// point lands AFTER the inserted text. `other` is any other view of
/// the same document: the position stays put (before the insertion),
/// and positions inside a deleted range clamp to its start.
pub const MapMode = enum { editor, other };

pub const Error = error{
    RevisionMismatch,
    InvalidEdits,
};

/// A change set. `edits` must be sorted by offset and non-overlapping;
/// `validate` checks that plus bounds. The transaction borrows its
/// `inserted` slices — callers keep them alive until applied.
pub const Transaction = struct {
    base_revision: u64,
    edits: std.ArrayList(Edit),

    pub fn init(base_revision: u64) Transaction {
        return .{ .base_revision = base_revision, .edits = .empty };
    }

    pub fn deinit(self: *Transaction, alloc: Allocator) void {
        self.edits.deinit(alloc);
    }

    pub fn addEdit(self: *Transaction, alloc: Allocator, edit: Edit) !void {
        try self.edits.append(alloc, edit);
    }

    pub fn addInsert(self: *Transaction, alloc: Allocator, offset: usize, text: []const u8) !void {
        try self.addEdit(alloc, .{ .offset = offset, .deleted_len = 0, .inserted = text });
    }

    pub fn addDelete(self: *Transaction, alloc: Allocator, offset: usize, deleted_len: usize) !void {
        try self.addEdit(alloc, .{ .offset = offset, .deleted_len = deleted_len, .inserted = "" });
    }

    pub fn addReplace(self: *Transaction, alloc: Allocator, offset: usize, deleted_len: usize, text: []const u8) !void {
        try self.addEdit(alloc, .{ .offset = offset, .deleted_len = deleted_len, .inserted = text });
    }

    /// Sorted, non-overlapping, within `doc_len` — or error.InvalidEdits.
    pub fn validate(self: *const Transaction, doc_len: usize) Error!void {
        try validateEdits(self.edits.items, doc_len);
    }
};

pub fn validateEdits(edits: []const Edit, doc_len: usize) Error!void {
    var prev_end: usize = 0;
    for (edits, 0..) |e, i| {
        // Subtract rather than add: `offset + deleted_len` overflows for
        // a hostile pair and wraps to a small number in ReleaseFast, so
        // the bound check would PASS and `Rope.delete` would then run
        // with an out-of-range end (its own guard is a debug assert).
        if (e.offset > doc_len or e.deleted_len > doc_len - e.offset) return Error.InvalidEdits;
        const end = e.offset + e.deleted_len;
        if (i > 0 and e.offset < prev_end) return Error.InvalidEdits;
        prev_end = end;
    }
}

/// Net byte-length change of a whole edit list.
pub fn lengthDelta(edits: []const Edit) isize {
    var delta: isize = 0;
    for (edits) |e| {
        delta += @as(isize, @intCast(e.inserted.len)) - @as(isize, @intCast(e.deleted_len));
    }
    return delta;
}

/// Maps a pre-transaction byte offset to its post-transaction position.
/// `edits` must be sorted and non-overlapping (pre-transaction coords).
pub fn mapOffset(edits: []const Edit, offset: usize, mode: MapMode) usize {
    var delta: isize = 0;
    for (edits) |e| {
        if (offset < e.offset) break;
        const del_end = e.offset + e.deleted_len;
        if (offset == e.offset and e.deleted_len == 0) {
            // Exactly at a pure insertion point.
            return switch (mode) {
                .editor => applyDelta(offset, delta) + e.inserted.len,
                .other => applyDelta(offset, delta),
            };
        }
        if (offset >= del_end) {
            delta += @as(isize, @intCast(e.inserted.len)) - @as(isize, @intCast(e.deleted_len));
            continue;
        }
        // Strictly inside (or at the start of) a deleted range.
        return switch (mode) {
            .editor => applyDelta(e.offset, delta) + e.inserted.len,
            .other => applyDelta(e.offset, delta),
        };
    }
    return applyDelta(offset, delta);
}

fn applyDelta(offset: usize, delta: isize) usize {
    return @intCast(@as(isize, @intCast(offset)) + delta);
}

// ======================================================================
// Tests
// ======================================================================

const testing = std.testing;

test "transaction validate rejects overlap and out-of-bounds" {
    var tx = Transaction.init(0);
    defer tx.deinit(testing.allocator);
    try tx.addDelete(testing.allocator, 2, 3);
    try tx.addDelete(testing.allocator, 4, 2); // overlaps [2,5)
    try testing.expectError(Error.InvalidEdits, tx.validate(100));

    var tx2 = Transaction.init(0);
    defer tx2.deinit(testing.allocator);
    try tx2.addDelete(testing.allocator, 8, 5);
    try testing.expectError(Error.InvalidEdits, tx2.validate(10));

    var tx3 = Transaction.init(0);
    defer tx3.deinit(testing.allocator);
    try tx3.addReplace(testing.allocator, 0, 2, "xy");
    try tx3.addInsert(testing.allocator, 2, "z");
    try tx3.validate(10);
}

test "transaction validate rejects a length that would overflow the end" {
    // offset + deleted_len wraps to 4 here; an additive bound check
    // accepts it and Rope.delete then runs unguarded (ReleaseFast has
    // no debug asserts).
    const edits = [_]Edit{.{ .offset = 10, .deleted_len = std.math.maxInt(usize) - 5, .inserted = "" }};
    try testing.expectError(Error.InvalidEdits, validateEdits(&edits, 100));
    // An offset past the end alone is still refused.
    const past = [_]Edit{.{ .offset = 101, .deleted_len = 0, .inserted = "" }};
    try testing.expectError(Error.InvalidEdits, validateEdits(&past, 100));
    // …and the exact end is still accepted.
    const at_end = [_]Edit{.{ .offset = 100, .deleted_len = 0, .inserted = "x" }};
    try validateEdits(&at_end, 100);
}

test "mapOffset before, inside, after an edit" {
    // Replace [5,8) with "ab" (net -1).
    const edits = [_]Edit{.{ .offset = 5, .deleted_len = 3, .inserted = "ab" }};
    try testing.expectEqual(@as(usize, 3), mapOffset(&edits, 3, .other));
    try testing.expectEqual(@as(usize, 3), mapOffset(&edits, 3, .editor));
    try testing.expectEqual(@as(usize, 5), mapOffset(&edits, 5, .other));
    try testing.expectEqual(@as(usize, 7), mapOffset(&edits, 5, .editor));
    try testing.expectEqual(@as(usize, 5), mapOffset(&edits, 6, .other));
    try testing.expectEqual(@as(usize, 7), mapOffset(&edits, 6, .editor));
    try testing.expectEqual(@as(usize, 7), mapOffset(&edits, 8, .other));
    try testing.expectEqual(@as(usize, 7), mapOffset(&edits, 8, .editor));
    try testing.expectEqual(@as(usize, 9), mapOffset(&edits, 10, .other));
}

test "mapOffset pure insertion point bias" {
    const edits = [_]Edit{.{ .offset = 4, .deleted_len = 0, .inserted = "hi" }};
    try testing.expectEqual(@as(usize, 4), mapOffset(&edits, 4, .other));
    try testing.expectEqual(@as(usize, 6), mapOffset(&edits, 4, .editor));
    try testing.expectEqual(@as(usize, 7), mapOffset(&edits, 5, .other));
}

test "mapOffset accumulates deltas across multiple edits" {
    const edits = [_]Edit{
        .{ .offset = 0, .deleted_len = 2, .inserted = "" }, // -2
        .{ .offset = 5, .deleted_len = 0, .inserted = "xxxx" }, // +4
        .{ .offset = 9, .deleted_len = 1, .inserted = "y" }, // 0
    };
    try testing.expectEqual(@as(usize, 14), mapOffset(&edits, 12, .other));
    try testing.expectEqual(@as(usize, 3), mapOffset(&edits, 5, .other));
    try testing.expectEqual(@as(usize, 7), mapOffset(&edits, 5, .editor));
    try testing.expectEqual(@as(usize, 9), mapOffset(&edits, 7, .other));
    try testing.expectEqual(@as(isize, 2), lengthDelta(&edits));
}
