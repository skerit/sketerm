//! Multi-selection model: sorted, non-overlapping anchor/head ranges.
//!
//! A caret is an empty range (anchor == head). `normalize` sorts by
//! range start and merges overlapping/duplicate ranges while keeping
//! track of which merged range the primary landed in. Mapping through
//! a transaction uses transaction.mapOffset with the editor/other bias
//! (see transaction.MapMode).

const std = @import("std");
const Allocator = std.mem.Allocator;
const tr = @import("transaction.zig");

pub const Selection = struct {
    anchor: usize,
    head: usize,

    pub fn caret(pos: usize) Selection {
        return .{ .anchor = pos, .head = pos };
    }

    pub fn start(self: Selection) usize {
        return @min(self.anchor, self.head);
    }

    pub fn end(self: Selection) usize {
        return @max(self.anchor, self.head);
    }

    pub fn isCaret(self: Selection) bool {
        return self.anchor == self.head;
    }

    /// True when the ranges overlap, or when either is a caret touching
    /// the other. Two adjacent non-empty ranges do NOT overlap.
    fn shouldMerge(a: Selection, b: Selection) bool {
        if (b.start() < a.end() and a.start() < b.end()) return true;
        if (a.isCaret() and a.anchor >= b.start() and a.anchor <= b.end()) return true;
        if (b.isCaret() and b.anchor >= a.start() and b.anchor <= a.end()) return true;
        return false;
    }
};

pub const SelectionSet = struct {
    sels: std.ArrayList(Selection),
    primary_index: usize,

    pub fn init() SelectionSet {
        return .{ .sels = .empty, .primary_index = 0 };
    }

    pub fn initSingle(alloc: Allocator, sel: Selection) !SelectionSet {
        var set = SelectionSet.init();
        try set.sels.append(alloc, sel);
        return set;
    }

    pub fn deinit(self: *SelectionSet, alloc: Allocator) void {
        self.sels.deinit(alloc);
    }

    pub fn count(self: *const SelectionSet) usize {
        return self.sels.items.len;
    }

    pub fn primary(self: *const SelectionSet) Selection {
        return self.sels.items[self.primary_index];
    }

    /// Adds a selection, makes it primary, and normalizes.
    pub fn add(self: *SelectionSet, alloc: Allocator, sel: Selection) !void {
        try self.sels.append(alloc, sel);
        self.primary_index = self.sels.items.len - 1;
        self.normalize();
    }

    /// Removes the selection at `index`; the set keeps at least one
    /// selection semantically — removing the last one is the caller's
    /// bug (asserted). Primary is re-aimed if it pointed at `index`.
    pub fn remove(self: *SelectionSet, index: usize) void {
        std.debug.assert(self.sels.items.len > 1);
        _ = self.sels.orderedRemove(index);
        if (self.primary_index >= self.sels.items.len) {
            self.primary_index = self.sels.items.len - 1;
        } else if (self.primary_index > index) {
            self.primary_index -= 1;
        }
    }

    /// Collapses to only the primary selection.
    pub fn keepPrimaryOnly(self: *SelectionSet) void {
        const p = self.primary();
        self.sels.clearRetainingCapacity();
        self.sels.appendAssumeCapacity(p);
        self.primary_index = 0;
    }

    /// Sorts by range start and merges overlaps. Merged ranges span the
    /// union; the merged selection keeps the direction (anchor<=head or
    /// not) of the first range in the merged run. Stable for the
    /// primary: it follows the range it was merged into.
    pub fn normalize(self: *SelectionSet) void {
        const items = self.sels.items;
        if (items.len <= 1) {
            self.primary_index = 0;
            return;
        }
        // Track the primary by tagging: remember its value pre-sort.
        const primary_sel = items[self.primary_index];

        std.mem.sort(Selection, items, {}, struct {
            fn lt(_: void, a: Selection, b: Selection) bool {
                if (a.start() != b.start()) return a.start() < b.start();
                return a.end() < b.end();
            }
        }.lt);

        var w: usize = 0;
        var new_primary: usize = 0;
        var primary_found = false;
        for (items) |s| {
            const is_primary = !primary_found and s.anchor == primary_sel.anchor and s.head == primary_sel.head;
            if (w > 0 and Selection.shouldMerge(items[w - 1], s)) {
                const prev = items[w - 1];
                const ns = @min(prev.start(), s.start());
                const ne = @max(prev.end(), s.end());
                const reversed = prev.anchor > prev.head;
                items[w - 1] = if (reversed)
                    .{ .anchor = ne, .head = ns }
                else
                    .{ .anchor = ns, .head = ne };
                if (is_primary) {
                    new_primary = w - 1;
                    primary_found = true;
                }
            } else {
                items[w] = s;
                if (is_primary) {
                    new_primary = w;
                    primary_found = true;
                }
                w += 1;
            }
        }
        self.sels.shrinkRetainingCapacity(w);
        self.primary_index = if (primary_found) new_primary else 0;
    }

    /// Maps every selection through an applied transaction's edits
    /// (pre-transaction coordinates, sorted, non-overlapping). Use
    /// `.editor` for the view that produced the edit and `.other` for
    /// any other view of the same document, then re-normalizes.
    pub fn mapThrough(self: *SelectionSet, edits: []const tr.Edit, mode: tr.MapMode) void {
        for (self.sels.items) |*s| {
            s.anchor = tr.mapOffset(edits, s.anchor, mode);
            s.head = tr.mapOffset(edits, s.head, mode);
        }
        self.normalize();
    }
};

// ======================================================================
// Tests
// ======================================================================

const testing = std.testing;

fn setOf(sels: []const Selection) !SelectionSet {
    var set = SelectionSet.init();
    for (sels) |s| try set.sels.append(testing.allocator, s);
    return set;
}

test "selection normalize sorts and merges overlaps" {
    var set = try setOf(&.{
        .{ .anchor = 10, .head = 20 },
        .{ .anchor = 0, .head = 5 },
        .{ .anchor = 15, .head = 25 }, // overlaps [10,20)
    });
    defer set.deinit(testing.allocator);
    set.primary_index = 2;
    set.normalize();
    try testing.expectEqual(@as(usize, 2), set.count());
    try testing.expectEqual(@as(usize, 0), set.sels.items[0].start());
    try testing.expectEqual(@as(usize, 5), set.sels.items[0].end());
    try testing.expectEqual(@as(usize, 10), set.sels.items[1].start());
    try testing.expectEqual(@as(usize, 25), set.sels.items[1].end());
    // Primary followed its merged range.
    try testing.expectEqual(@as(usize, 1), set.primary_index);
}

test "selection adjacent ranges stay separate, coincident carets merge" {
    var set = try setOf(&.{
        .{ .anchor = 0, .head = 5 },
        .{ .anchor = 5, .head = 9 },
    });
    defer set.deinit(testing.allocator);
    set.normalize();
    try testing.expectEqual(@as(usize, 2), set.count());

    var carets = try setOf(&.{ Selection.caret(3), Selection.caret(3), Selection.caret(7) });
    defer carets.deinit(testing.allocator);
    carets.normalize();
    try testing.expectEqual(@as(usize, 2), carets.count());
}

test "selection caret inside a range merges into it" {
    var set = try setOf(&.{
        .{ .anchor = 2, .head = 8 },
        Selection.caret(5),
    });
    defer set.deinit(testing.allocator);
    set.normalize();
    try testing.expectEqual(@as(usize, 1), set.count());
    try testing.expectEqual(@as(usize, 2), set.sels.items[0].start());
    try testing.expectEqual(@as(usize, 8), set.sels.items[0].end());
}

test "selection reversed direction preserved through merge" {
    var set = try setOf(&.{
        .{ .anchor = 20, .head = 10 }, // reversed
        .{ .anchor = 15, .head = 25 },
    });
    defer set.deinit(testing.allocator);
    set.normalize();
    try testing.expectEqual(@as(usize, 1), set.count());
    const s = set.sels.items[0];
    try testing.expect(s.anchor > s.head);
    try testing.expectEqual(@as(usize, 10), s.start());
    try testing.expectEqual(@as(usize, 25), s.end());
}

test "selection add and remove manage primary" {
    var set = try SelectionSet.initSingle(testing.allocator, Selection.caret(0));
    defer set.deinit(testing.allocator);
    try set.add(testing.allocator, Selection.caret(10));
    try testing.expectEqual(@as(usize, 10), set.primary().head);
    try set.add(testing.allocator, Selection.caret(5));
    try testing.expectEqual(@as(usize, 3), set.count());
    try testing.expectEqual(@as(usize, 5), set.primary().head);
    set.remove(0);
    try testing.expectEqual(@as(usize, 2), set.count());
    try testing.expectEqual(@as(usize, 5), set.primary().head);
    set.keepPrimaryOnly();
    try testing.expectEqual(@as(usize, 1), set.count());
    try testing.expectEqual(@as(usize, 5), set.primary().head);
}

test "selection mapping across an insert before, at, and after" {
    // Insert "XX" at offset 5.
    const edits = [_]tr.Edit{.{ .offset = 5, .deleted_len = 0, .inserted = "XX" }};

    var set = try setOf(&.{
        .{ .anchor = 0, .head = 3 }, // before: unchanged
        Selection.caret(5), // at the insert point
        .{ .anchor = 7, .head = 9 }, // after: +2
    });
    defer set.deinit(testing.allocator);
    set.mapThrough(&edits, .other);
    try testing.expectEqual(@as(usize, 0), set.sels.items[0].anchor);
    try testing.expectEqual(@as(usize, 3), set.sels.items[0].head);
    try testing.expectEqual(@as(usize, 5), set.sels.items[1].head);
    try testing.expectEqual(@as(usize, 9), set.sels.items[2].anchor);
    try testing.expectEqual(@as(usize, 11), set.sels.items[2].head);

    var set2 = try setOf(&.{Selection.caret(5)});
    defer set2.deinit(testing.allocator);
    set2.mapThrough(&edits, .editor);
    try testing.expectEqual(@as(usize, 7), set2.sels.items[0].head);
}

test "selection mapping across a delete straddling ranges" {
    // Delete [4, 10).
    const edits = [_]tr.Edit{.{ .offset = 4, .deleted_len = 6, .inserted = "" }};
    var set = try setOf(&.{
        .{ .anchor = 2, .head = 6 }, // head inside deletion -> clamps to 4
        .{ .anchor = 8, .head = 14 }, // anchor inside -> 4, head 14 -> 8
        Selection.caret(20), // -6
    });
    defer set.deinit(testing.allocator);
    set.mapThrough(&edits, .other);
    try testing.expectEqual(@as(usize, 2), set.sels.items[0].anchor);
    try testing.expectEqual(@as(usize, 4), set.sels.items[0].head);
    try testing.expectEqual(@as(usize, 4), set.sels.items[1].anchor);
    try testing.expectEqual(@as(usize, 8), set.sels.items[1].head);
    try testing.expectEqual(@as(usize, 14), set.sels.items[2].head);
}

test "selection collapsed by a covering delete merges away" {
    // Delete [0, 10) collapses both selections to caret 0.
    const edits = [_]tr.Edit{.{ .offset = 0, .deleted_len = 10, .inserted = "" }};
    var set = try setOf(&.{
        .{ .anchor = 1, .head = 4 },
        .{ .anchor = 6, .head = 9 },
    });
    defer set.deinit(testing.allocator);
    set.mapThrough(&edits, .other);
    try testing.expectEqual(@as(usize, 1), set.count());
    try testing.expect(set.sels.items[0].isCaret());
    try testing.expectEqual(@as(usize, 0), set.sels.items[0].head);
}

test "selection mapping through a multi-edit transaction" {
    const edits = [_]tr.Edit{
        .{ .offset = 0, .deleted_len = 3, .inserted = "A" }, // -2
        .{ .offset = 10, .deleted_len = 0, .inserted = "BB" }, // +2
    };
    var set = try setOf(&.{
        Selection.caret(5), // -2 -> 3
        Selection.caret(12), // -2 +2 -> 12
    });
    defer set.deinit(testing.allocator);
    set.mapThrough(&edits, .other);
    try testing.expectEqual(@as(usize, 3), set.sels.items[0].head);
    try testing.expectEqual(@as(usize, 12), set.sels.items[1].head);
}
