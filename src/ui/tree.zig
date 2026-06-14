//! Pane-tree model — the toolkit-free source of truth for how a
//! tab's panes are split. One Tree per tab; the GTK widget tree
//! (GtkPaned nesting) is a VIEW of this and must only be mutated
//! together with it (splitLeaf / removeLeaf / replaceLeaf below).
//!
//! Generic over the Leaf type so tests run on plain integers and a
//! future non-GTK frontend can reuse it unchanged. Split nodes carry
//! an opaque `view` handle (the GtkPaned) that the model never
//! dereferences — frontends use it to read live split ratios back
//! into `ratio` before serializing.

const std = @import("std");

pub const Orient = enum { horizontal, vertical };

pub fn Tree(comptime Leaf: type) type {
    return struct {
        const Self = @This();

        pub const Node = union(enum) {
            leaf: Leaf,
            split: *Split,
        };

        pub const Split = struct {
            orientation: Orient,
            ratio: f32,
            children: [2]Node,
            /// Opaque frontend handle (e.g. the GtkPaned widget).
            view: ?*anyopaque = null,
        };

        pub const RemoveResult = struct {
            /// False = the leaf was the root: the tree is now empty
            /// and the caller should close the whole tab.
            collapsed: bool,
            /// First leaf of the surviving sibling subtree — where
            /// focus should land after a close.
            focus_hint: ?Leaf = null,
        };

        allocator: std.mem.Allocator,
        root: Node,
        /// Leaf that last held keyboard focus in this tab. Restored when
        /// the tab is re-selected (null → fall back to the first leaf).
        /// Travels with the tree across cross-window tab drags.
        last_focused: ?Leaf = null,

        pub fn initLeaf(allocator: std.mem.Allocator, leaf: Leaf) Self {
            return .{ .allocator = allocator, .root = .{ .leaf = leaf } };
        }

        pub fn deinit(self: *Self) void {
            freeNode(self.allocator, self.root);
        }

        fn freeNode(allocator: std.mem.Allocator, node: Node) void {
            switch (node) {
                .leaf => {},
                .split => |s| {
                    freeNode(allocator, s.children[0]);
                    freeNode(allocator, s.children[1]);
                    allocator.destroy(s);
                },
            }
        }

        pub fn contains(self: *const Self, leaf: Leaf) bool {
            return nodeContains(self.root, leaf);
        }

        fn nodeContains(node: Node, leaf: Leaf) bool {
            return switch (node) {
                .leaf => |l| l == leaf,
                .split => |s| nodeContains(s.children[0], leaf) or
                    nodeContains(s.children[1], leaf),
            };
        }

        pub fn countLeaves(self: *const Self) usize {
            return nodeCount(self.root);
        }

        fn nodeCount(node: Node) usize {
            return switch (node) {
                .leaf => 1,
                .split => |s| nodeCount(s.children[0]) + nodeCount(s.children[1]),
            };
        }

        pub fn firstLeaf(self: *const Self) Leaf {
            return nodeFirstLeaf(self.root);
        }

        fn nodeFirstLeaf(node: Node) Leaf {
            return switch (node) {
                .leaf => |l| l,
                .split => |s| nodeFirstLeaf(s.children[0]),
            };
        }

        /// Append every leaf, depth-first (visual order).
        pub fn appendLeaves(self: *const Self, allocator: std.mem.Allocator, out: *std.ArrayList(Leaf)) !void {
            try nodeAppendLeaves(self.root, allocator, out);
        }

        fn nodeAppendLeaves(node: Node, allocator: std.mem.Allocator, out: *std.ArrayList(Leaf)) !void {
            switch (node) {
                .leaf => |l| try out.append(allocator, l),
                .split => |s| {
                    try nodeAppendLeaves(s.children[0], allocator, out);
                    try nodeAppendLeaves(s.children[1], allocator, out);
                },
            }
        }

        /// Replace leaf `at` with a split of (at, new) — `new` takes
        /// the second slot, matching "new pane goes end-child".
        pub fn splitLeaf(self: *Self, at: Leaf, new: Leaf, orientation: Orient, ratio: f32, view: ?*anyopaque) !void {
            const slot = findLeafSlot(&self.root, at) orelse return error.LeafNotFound;
            const s = try self.allocator.create(Split);
            s.* = .{
                .orientation = orientation,
                .ratio = ratio,
                .children = .{ .{ .leaf = at }, .{ .leaf = new } },
                .view = view,
            };
            slot.* = .{ .split = s };
        }

        /// Swap one leaf for another in place (mux takeover).
        pub fn replaceLeaf(self: *Self, old: Leaf, new: Leaf) !void {
            const slot = findLeafSlot(&self.root, old) orelse return error.LeafNotFound;
            slot.* = .{ .leaf = new };
        }

        /// Remove a leaf, collapsing its parent split into the
        /// sibling subtree. A root leaf is NOT removed — the caller
        /// closes the tab instead (collapsed=false signals this).
        pub fn removeLeaf(self: *Self, leaf: Leaf) !RemoveResult {
            switch (self.root) {
                .leaf => |l| {
                    if (l != leaf) return error.LeafNotFound;
                    return .{ .collapsed = false };
                },
                .split => {},
            }
            const found = findParentOf(&self.root, leaf) orelse return error.LeafNotFound;
            const s = found.parent.split;
            const sibling = s.children[1 - found.child_idx];
            const hint = nodeFirstLeaf(sibling);
            found.parent.* = sibling;
            self.allocator.destroy(s);
            return .{ .collapsed = true, .focus_hint = hint };
        }

        /// Visit every split node (e.g. to refresh ratios from the
        /// live view handles before serializing).
        pub fn forEachSplit(self: *Self, ctx: anytype, cb: fn (@TypeOf(ctx), *Split) void) void {
            nodeForEachSplit(&self.root, ctx, cb);
        }

        fn nodeForEachSplit(node: *Node, ctx: anytype, cb: fn (@TypeOf(ctx), *Split) void) void {
            switch (node.*) {
                .leaf => {},
                .split => |s| {
                    cb(ctx, s);
                    nodeForEachSplit(&s.children[0], ctx, cb);
                    nodeForEachSplit(&s.children[1], ctx, cb);
                },
            }
        }

        fn findLeafSlot(node: *Node, leaf: Leaf) ?*Node {
            switch (node.*) {
                .leaf => |l| return if (l == leaf) node else null,
                .split => |s| {
                    if (findLeafSlot(&s.children[0], leaf)) |n| return n;
                    return findLeafSlot(&s.children[1], leaf);
                },
            }
        }

        const ParentRef = struct { parent: *Node, child_idx: u1 };

        /// The split node directly holding `leaf`, as a slot pointer
        /// into the tree so it can be overwritten in place.
        fn findParentOf(node: *Node, leaf: Leaf) ?ParentRef {
            switch (node.*) {
                .leaf => return null,
                .split => |s| {
                    for (0..2) |i| {
                        switch (s.children[i]) {
                            .leaf => |l| if (l == leaf) return .{ .parent = node, .child_idx = @intCast(i) },
                            .split => {},
                        }
                    }
                    if (findParentOf(&s.children[0], leaf)) |r| return r;
                    return findParentOf(&s.children[1], leaf);
                },
            }
        }
    };
}

const TestTree = Tree(u32);

test "single leaf basics" {
    var t = TestTree.initLeaf(std.testing.allocator, 1);
    defer t.deinit();
    try std.testing.expect(t.contains(1));
    try std.testing.expect(!t.contains(2));
    try std.testing.expectEqual(@as(usize, 1), t.countLeaves());
    try std.testing.expectEqual(@as(u32, 1), t.firstLeaf());
}

test "removeLeaf on root leaf signals tab close" {
    var t = TestTree.initLeaf(std.testing.allocator, 1);
    defer t.deinit();
    const r = try t.removeLeaf(1);
    try std.testing.expect(!r.collapsed);
    try std.testing.expectError(error.LeafNotFound, t.removeLeaf(9));
}

test "split then remove collapses back" {
    var t = TestTree.initLeaf(std.testing.allocator, 1);
    defer t.deinit();
    try t.splitLeaf(1, 2, .horizontal, 0.5, null);
    try std.testing.expectEqual(@as(usize, 2), t.countLeaves());
    try std.testing.expect(t.contains(2));

    const r = try t.removeLeaf(1);
    try std.testing.expect(r.collapsed);
    try std.testing.expectEqual(@as(u32, 2), r.focus_hint.?);
    try std.testing.expectEqual(@as(usize, 1), t.countLeaves());
    try std.testing.expectEqual(@as(u32, 2), t.firstLeaf());
}

test "nested splits, deep removal, leaf order" {
    var t = TestTree.initLeaf(std.testing.allocator, 1);
    defer t.deinit();
    // 1 | 2  →  split 2 into 2/3 vertically  → (1 | (2 / 3))
    try t.splitLeaf(1, 2, .horizontal, 0.5, null);
    try t.splitLeaf(2, 3, .vertical, 0.5, null);
    try std.testing.expectEqual(@as(usize, 3), t.countLeaves());

    var leaves: std.ArrayList(u32) = .empty;
    defer leaves.deinit(std.testing.allocator);
    try t.appendLeaves(std.testing.allocator, &leaves);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, leaves.items);

    // Removing 2 collapses the inner split; 3 takes its place.
    const r = try t.removeLeaf(2);
    try std.testing.expect(r.collapsed);
    try std.testing.expectEqual(@as(u32, 3), r.focus_hint.?);
    try std.testing.expectEqual(@as(usize, 2), t.countLeaves());

    // Removing 3 leaves the root leaf 1.
    const r2 = try t.removeLeaf(3);
    try std.testing.expect(r2.collapsed);
    try std.testing.expectEqual(@as(u32, 1), r2.focus_hint.?);
    switch (t.root) {
        .leaf => |l| try std.testing.expectEqual(@as(u32, 1), l),
        .split => return error.TestUnexpectedResult,
    }
}

test "replaceLeaf swaps in place" {
    var t = TestTree.initLeaf(std.testing.allocator, 1);
    defer t.deinit();
    try t.splitLeaf(1, 2, .horizontal, 0.5, null);
    try t.replaceLeaf(1, 7);
    try std.testing.expect(t.contains(7));
    try std.testing.expect(!t.contains(1));
    try std.testing.expectEqual(@as(usize, 2), t.countLeaves());
}

test "forEachSplit visits every split" {
    var t = TestTree.initLeaf(std.testing.allocator, 1);
    defer t.deinit();
    try t.splitLeaf(1, 2, .horizontal, 0.3, null);
    try t.splitLeaf(2, 3, .vertical, 0.7, null);
    const Counter = struct {
        n: u32 = 0,
        fn visit(self: *@This(), _: *TestTree.Split) void {
            self.n += 1;
        }
    };
    var counter: Counter = .{};
    t.forEachSplit(&counter, Counter.visit);
    try std.testing.expectEqual(@as(u32, 2), counter.n);
}
