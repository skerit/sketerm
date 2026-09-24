//! The one selection a browser tab owns.
//!
//! Every verb (trash, copy, drag, rename, status counts) reads THIS;
//! the GTK selection models of the list views and the icon FlowBox
//! are derived from it at render time and written back into it on a
//! user gesture -- they are views of the set, never a second copy
//! kept in step by hand. Membership is a hash lookup, so a render
//! that derives the widgets' selection costs one pass over the rows
//! rather than rows times selected paths.
//!
//! One visibility rule lives with the set: `retain` drops the paths a
//! caller can prove HIDDEN, and only those. A path no listing carries
//! yet (a restored selection, a mutation that has not landed, a
//! collapsed branch) stays selected until a listing proves it hidden
//! or a delete proves it gone -- absence from a partial listing is not
//! evidence of either.
//!
//! Unmanaged like the repo's other containers: every mutation takes
//! the allocator the set was filled with.

const std = @import("std");
const dirWithin = @import("paths.zig").dirWithin;

pub const SelectionSet = struct {
    /// The selected paths, in selection order: READ-ONLY for callers
    /// (it mirrors `order.items` after every mutation, and any
    /// mutation invalidates it). Kept as a field so the many readers
    /// iterate it exactly like the list it replaced.
    items: []const []u8 = &.{},
    /// Insertion order, owned paths.
    order: std.ArrayList([]u8) = .empty,
    /// path -> index into `order`.
    index: std.StringHashMapUnmanaged(usize) = .empty,
    /// Bumped on every change, so a render can tell whether the
    /// derived widget state is already current.
    generation: u64 = 0,

    pub const empty: SelectionSet = .{};

    pub fn deinit(self: *SelectionSet, allocator: std.mem.Allocator) void {
        for (self.order.items) |p| allocator.free(p);
        self.order.deinit(allocator);
        self.index.deinit(allocator);
        self.* = .{};
    }

    fn changed(self: *SelectionSet) void {
        self.items = self.order.items;
        self.generation +%= 1;
    }

    pub fn count(self: *const SelectionSet) usize {
        return self.order.items.len;
    }

    pub fn contains(self: *const SelectionSet, path: []const u8) bool {
        return self.index.contains(path);
    }

    /// The one "what does a verb on this row act on" rule: a row that
    /// is part of a MULTI-selection acts on the whole selection; any
    /// other row acts on itself alone.
    pub fn actsOnAll(self: *const SelectionSet, clicked: []const u8) bool {
        return self.order.items.len > 1 and self.index.contains(clicked);
    }

    /// The most recently selected path, if any.
    pub fn last(self: *const SelectionSet) ?[]const u8 {
        if (self.order.items.len == 0) return null;
        return self.order.items[self.order.items.len - 1];
    }

    /// Select `path` (copied). @return true when it was not selected.
    pub fn add(self: *SelectionSet, allocator: std.mem.Allocator, path: []const u8) bool {
        if (self.index.contains(path)) return false;
        const owned = allocator.dupe(u8, path) catch return false;
        return self.adopt(allocator, owned);
    }

    /// Select `owned`, taking ownership of it either way (freed when
    /// it was already selected or cannot be recorded).
    /// @return true when it was not selected.
    pub fn adopt(self: *SelectionSet, allocator: std.mem.Allocator, owned: []u8) bool {
        if (self.index.contains(owned)) {
            allocator.free(owned);
            return false;
        }
        self.order.append(allocator, owned) catch {
            allocator.free(owned);
            return false;
        };
        self.index.put(allocator, owned, self.order.items.len - 1) catch {
            allocator.free(self.order.pop().?);
            self.items = self.order.items;
            return false;
        };
        self.changed();
        return true;
    }

    /// @return true when `path` was selected.
    pub fn remove(self: *SelectionSet, allocator: std.mem.Allocator, path: []const u8) bool {
        const kv = self.index.fetchRemove(path) orelse return false;
        const at = kv.value;
        const owned = self.order.orderedRemove(at);
        allocator.free(owned);
        // Everything after the hole shifted down by one.
        for (self.order.items[at..], at..) |p, i| self.index.putAssumeCapacity(p, i);
        self.changed();
        return true;
    }

    /// @return the new membership.
    pub fn toggle(self: *SelectionSet, allocator: std.mem.Allocator, path: []const u8) bool {
        if (self.remove(allocator, path)) return false;
        return self.add(allocator, path);
    }

    pub fn clear(self: *SelectionSet, allocator: std.mem.Allocator) void {
        if (self.order.items.len == 0) return;
        for (self.order.items) |p| allocator.free(p);
        self.order.clearRetainingCapacity();
        self.index.clearRetainingCapacity();
        self.changed();
    }

    /// Replace the selection with exactly `paths`, in that order
    /// (duplicates collapse).
    pub fn replace(self: *SelectionSet, allocator: std.mem.Allocator, paths: []const []const u8) void {
        self.clear(allocator);
        for (paths) |p| _ = self.add(allocator, p);
    }

    /// Keep only the paths `keep` accepts. One compaction pass; the
    /// index is rebuilt once at the end.
    pub fn retain(self: *SelectionSet, allocator: std.mem.Allocator, ctx: anytype, comptime keep: fn (@TypeOf(ctx), []const u8) bool) void {
        var w: usize = 0;
        var dropped = false;
        for (self.order.items) |p| {
            if (keep(ctx, p)) {
                self.order.items[w] = p;
                w += 1;
            } else {
                allocator.free(p);
                dropped = true;
            }
        }
        if (!dropped) return;
        self.order.shrinkRetainingCapacity(w);
        self.index.clearRetainingCapacity();
        // Capacity is already there for every surviving key.
        for (self.order.items, 0..) |p, i| self.index.putAssumeCapacity(p, i);
        self.changed();
    }

    /// Drop `path` and everything beneath it: an authoritative delete.
    pub fn removeWithin(self: *SelectionSet, allocator: std.mem.Allocator, path: []const u8) void {
        self.retain(allocator, path, struct {
            fn keep(gone: []const u8, p: []const u8) bool {
                return !dirWithin(p, gone);
            }
        }.keep);
    }
};

test "a set holds each path once, in order, with O(1) membership" {
    const t = std.testing;
    const a = t.allocator;
    var s: SelectionSet = .empty;
    defer s.deinit(a);
    try t.expect(s.add(a, "/a"));
    try t.expect(s.add(a, "/b"));
    try t.expect(!s.add(a, "/a"));
    try t.expectEqual(@as(usize, 2), s.count());
    try t.expectEqual(@as(usize, 2), s.items.len);
    try t.expect(s.contains("/a"));
    try t.expect(!s.contains("/c"));
    try t.expectEqualStrings("/b", s.last().?);
    try t.expect(s.remove(a, "/a"));
    try t.expect(!s.remove(a, "/a"));
    try t.expectEqualStrings("/b", s.items[0]);
    try t.expect(s.contains("/b"));
    try t.expect(s.toggle(a, "/c"));
    try t.expect(!s.toggle(a, "/c"));
    s.replace(a, &.{ "/x", "/y", "/x" });
    try t.expectEqual(@as(usize, 2), s.count());
    try t.expectEqualStrings("/y", s.items[1]);
    try t.expect(s.actsOnAll("/x"));
    try t.expect(!s.actsOnAll("/q"));
    try t.expect(!s.adopt(a, try a.dupe(u8, "/x")));
    try t.expect(s.adopt(a, try a.dupe(u8, "/z")));
    try t.expectEqualStrings("/z", s.last().?);
}

test "retain and removeWithin keep the index consistent" {
    const t = std.testing;
    const a = t.allocator;
    var s: SelectionSet = .empty;
    defer s.deinit(a);
    _ = s.add(a, "/d/a");
    _ = s.add(a, "/d/b");
    _ = s.add(a, "/e");
    _ = s.add(a, "/d");
    _ = s.add(a, "/dd/x");
    s.removeWithin(a, "/d");
    try t.expectEqual(@as(usize, 2), s.count());
    try t.expectEqualStrings("/e", s.items[0]);
    try t.expectEqualStrings("/dd/x", s.items[1]);
    try t.expect(s.contains("/dd/x"));
    try t.expect(!s.contains("/d/a"));
    // A later remove after the compaction finds the right slot.
    try t.expect(s.remove(a, "/e"));
    try t.expectEqualStrings("/dd/x", s.items[0]);
    try t.expect(s.contains("/dd/x"));
    const gen = s.generation;
    s.retain(a, {}, struct {
        fn keep(_: void, _: []const u8) bool {
            return true;
        }
    }.keep);
    try t.expectEqual(gen, s.generation);
}

test "a large folder derives in linear time" {
    // 60k rows, 30k selected: the derive pass (one membership lookup
    // per row) and a pruning pass must both stay far under the old
    // rows-times-selected cost (~1.8e9 compares). The bound is generous
    // for a loaded test host; the point is the shape, not the constant.
    const t = std.testing;
    const a = t.allocator;
    const clock = @import("../util/clock.zig");
    var s: SelectionSet = .empty;
    defer s.deinit(a);
    var buf: [64]u8 = undefined;
    var i: usize = 0;
    while (i < 60_000) : (i += 2) {
        _ = s.add(a, try std.fmt.bufPrint(&buf, "/big/entry-{d}", .{i}));
    }
    try t.expectEqual(@as(usize, 30_000), s.count());
    const t0 = clock.nowMs();
    var hits: usize = 0;
    i = 0;
    while (i < 60_000) : (i += 1) {
        if (s.contains(try std.fmt.bufPrint(&buf, "/big/entry-{d}", .{i}))) hits += 1;
    }
    try t.expectEqual(@as(usize, 30_000), hits);
    s.retain(a, {}, struct {
        fn keep(_: void, p: []const u8) bool {
            return p.len % 2 == 0;
        }
    }.keep);
    try t.expect(clock.nowMs() - t0 < 5000);
    try t.expect(s.count() < 30_000);
}
