//! Tab-forest model — the toolkit-free source of truth for the
//! window-level tab TREE (tree-style tabs): parent/child nesting +
//! per-node collapse state across the tabs of one window.
//!
//! Sibling of `src/ui/tree.zig` (the per-tab PANE tree) and under the
//! same discipline: this model is mutated together with the view
//! (AdwTabView pages / the sidebar), never reconstructed from it.
//! Generic over the Ref type so tests run on plain integers and the
//! GUI instantiates it with `*AdwTabPage`.
//!
//! Ordering: `roots` + each node's `children` define TREE order (what
//! the sidebar shows and tab_tree_next/prev walk). The AdwTabView strip
//! order is allowed to diverge after a strip drag — the strip stays the
//! flat view, the sidebar the tree view (TST behaves the same way).

const std = @import("std");

/// What closing a tab that has children does (config `tab_close_parent`).
pub const ClosePolicy = enum { promote, close_subtree };

/// Where a new child lands among its siblings (config `tab_child_insert`).
pub const InsertPos = enum { last, first };

pub fn Forest(comptime Ref: type) type {
    return struct {
        const Self = @This();

        pub const Node = struct {
            ref: Ref,
            parent: ?*Node = null,
            children: std.ArrayList(*Node) = .empty,
            collapsed: bool = false,
        };

        allocator: std.mem.Allocator,
        roots: std.ArrayList(*Node) = .empty,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            for (self.roots.items) |r| self.freeNode(r);
            self.roots.deinit(self.allocator);
        }

        fn freeNode(self: *Self, node: *Node) void {
            for (node.children.items) |ch| self.freeNode(ch);
            node.children.deinit(self.allocator);
            self.allocator.destroy(node);
        }

        pub fn count(self: *const Self) usize {
            var n: usize = 0;
            for (self.roots.items) |r| n += countNode(r);
            return n;
        }

        fn countNode(node: *const Node) usize {
            var n: usize = 1;
            for (node.children.items) |ch| n += countNode(ch);
            return n;
        }

        pub fn find(self: *const Self, ref: Ref) ?*Node {
            for (self.roots.items) |r| {
                if (findIn(r, ref)) |n| return n;
            }
            return null;
        }

        fn findIn(node: *Node, ref: Ref) ?*Node {
            if (node.ref == ref) return node;
            for (node.children.items) |ch| {
                if (findIn(ch, ref)) |n| return n;
            }
            return null;
        }

        /// Add `ref` as a new root (appended). Error if already present.
        pub fn add(self: *Self, ref: Ref) !*Node {
            if (self.find(ref) != null) return error.AlreadyPresent;
            const n = try self.allocator.create(Node);
            n.* = .{ .ref = ref };
            try self.roots.append(self.allocator, n);
            return n;
        }

        /// Add `ref` as a child of `parent_ref` (opener -> child nesting).
        pub fn addChild(self: *Self, ref: Ref, parent_ref: Ref, pos: InsertPos) !*Node {
            if (self.find(ref) != null) return error.AlreadyPresent;
            const parent = self.find(parent_ref) orelse return error.NotFound;
            const n = try self.allocator.create(Node);
            n.* = .{ .ref = ref, .parent = parent };
            switch (pos) {
                .last => try parent.children.append(self.allocator, n),
                .first => try parent.children.insert(self.allocator, 0, n),
            }
            return n;
        }

        /// Sibling list a node lives in (parent's children, or roots).
        fn siblingsOf(self: *Self, node: *Node) *std.ArrayList(*Node) {
            return if (node.parent) |p| &p.children else &self.roots;
        }

        /// Remove `ref`, PROMOTING its children: they are spliced into
        /// the removed node's position among its siblings, in order
        /// (the TST close-parent-promote shape). Callers wanting the
        /// close-subtree policy close the descendants first (see
        /// `appendSubtree`) so removal always promotes an empty list.
        pub fn remove(self: *Self, ref: Ref) !void {
            const node = self.find(ref) orelse return error.NotFound;
            const sibs = self.siblingsOf(node);
            const idx = indexOf(sibs.items, node) orelse return error.NotFound;
            _ = sibs.orderedRemove(idx);
            // Splice children in at the vacated position.
            var at = idx;
            for (node.children.items) |ch| {
                ch.parent = node.parent;
                try sibs.insert(self.allocator, at, ch);
                at += 1;
            }
            node.children.deinit(self.allocator);
            self.allocator.destroy(node);
        }

        fn indexOf(items: []const *Node, node: *const Node) ?usize {
            for (items, 0..) |it, i| {
                if (it == node) return i;
            }
            return null;
        }

        fn isAncestorOf(node: *const Node, maybe_desc: *const Node) bool {
            var cur: ?*const Node = maybe_desc;
            while (cur) |n| : (cur = n.parent) {
                if (n == node) return true;
            }
            return false;
        }

        /// Move `ref` (subtree and all) under `new_parent_ref`, or to
        /// the root list when null. Rejects a reparent into the node's
        /// own subtree with error.WouldCycle.
        pub fn reparent(self: *Self, ref: Ref, new_parent_ref: ?Ref, pos: InsertPos) !void {
            const node = self.find(ref) orelse return error.NotFound;
            var new_parent: ?*Node = null;
            if (new_parent_ref) |pr| {
                const p = self.find(pr) orelse return error.NotFound;
                if (isAncestorOf(node, p)) return error.WouldCycle;
                new_parent = p;
            }
            // Detach from current siblings.
            const sibs = self.siblingsOf(node);
            const idx = indexOf(sibs.items, node) orelse return error.NotFound;
            _ = sibs.orderedRemove(idx);
            node.parent = new_parent;
            const dest: *std.ArrayList(*Node) = if (new_parent) |p| &p.children else &self.roots;
            switch (pos) {
                .last => try dest.append(self.allocator, node),
                .first => try dest.insert(self.allocator, 0, node),
            }
        }

        pub fn setCollapsed(self: *Self, ref: Ref, v: bool) void {
            if (self.find(ref)) |n| n.collapsed = v;
        }

        pub fn isCollapsed(self: *const Self, ref: Ref) bool {
            const n = self.find(ref) orelse return false;
            return n.collapsed;
        }

        pub fn hasChildren(self: *const Self, ref: Ref) bool {
            const n = self.find(ref) orelse return false;
            return n.children.items.len > 0;
        }

        /// True when any STRICT ancestor is collapsed (the collapsed
        /// node itself stays visible — its subtree hides).
        pub fn isHidden(self: *const Self, ref: Ref) bool {
            const n = self.find(ref) orelse return false;
            var cur = n.parent;
            while (cur) |p| : (cur = p.parent) {
                if (p.collapsed) return true;
            }
            return false;
        }

        pub fn depth(self: *const Self, ref: Ref) usize {
            const n = self.find(ref) orelse return 0;
            var d: usize = 0;
            var cur = n.parent;
            while (cur) |p| : (cur = p.parent) d += 1;
            return d;
        }

        pub fn parentOf(self: *const Self, ref: Ref) ?Ref {
            const n = self.find(ref) orelse return null;
            const p = n.parent orelse return null;
            return p.ref;
        }

        /// Nesting of `kept`, expressed as INDICES INTO `kept` — how a
        /// tree is serialized, since a pointer means nothing to the
        /// next process. `out` must be `kept.len` long and is filled
        /// with each entry's parent index, or null for a root.
        ///
        /// `kept` is deliberately the SERIALIZED order, not every ref
        /// in the forest: both callers skip refs that persist to
        /// nothing (a tab with no root widget, a DevTools-only page),
        /// and using a position in some other order as the index is
        /// exactly the bug this exists to prevent — it restored
        /// children under whatever tab happened to sit at that index.
        /// A ref whose parent was skipped comes back null, i.e. a root,
        /// which is the honest answer: its nesting had nowhere to
        /// attach.
        pub fn parentIndices(self: *const Self, kept: []const Ref, out: []?u32) void {
            for (kept, 0..) |ref, i| {
                if (i >= out.len) return;
                out[i] = null;
                const parent = self.parentOf(ref) orelse continue;
                for (kept, 0..) |other, j| {
                    if (other == parent) {
                        out[i] = @intCast(j);
                        break;
                    }
                }
            }
        }

        /// Append `ref` + every descendant, DFS/tree order.
        pub fn appendSubtree(self: *const Self, allocator: std.mem.Allocator, ref: Ref, out: *std.ArrayList(Ref)) !void {
            const n = self.find(ref) orelse return error.NotFound;
            try appendNode(n, allocator, out, false);
        }

        fn appendNode(node: *const Node, allocator: std.mem.Allocator, out: *std.ArrayList(Ref), skip_collapsed: bool) !void {
            try out.append(allocator, node.ref);
            if (skip_collapsed and node.collapsed) return;
            for (node.children.items) |ch| try appendNode(ch, allocator, out, skip_collapsed);
        }

        /// Every ref, DFS/tree order, collapse ignored.
        pub fn flattenAll(self: *const Self, allocator: std.mem.Allocator, out: *std.ArrayList(Ref)) !void {
            for (self.roots.items) |r| try appendNode(r, allocator, out, false);
        }

        /// Every VISIBLE ref (collapsed subtrees contribute only their
        /// collapsed root), DFS/tree order — sidebar row order.
        pub fn flattenVisible(self: *const Self, allocator: std.mem.Allocator, out: *std.ArrayList(Ref)) !void {
            for (self.roots.items) |r| try appendNode(r, allocator, out, true);
        }

        /// Next/prev visible ref in tree order, wrapping. Null when
        /// `ref` is unknown or hidden.
        pub fn stepVisible(self: *const Self, allocator: std.mem.Allocator, ref: Ref, forward: bool) !?Ref {
            var flat: std.ArrayList(Ref) = .empty;
            defer flat.deinit(allocator);
            try self.flattenVisible(allocator, &flat);
            const n = flat.items.len;
            if (n == 0) return null;
            for (flat.items, 0..) |it, i| {
                if (it == ref) {
                    const j = if (forward) (i + 1) % n else (i + n - 1) % n;
                    return flat.items[j];
                }
            }
            return null;
        }

        /// Structural integrity: parent/child links agree and the
        /// forest is acyclic (every node reached exactly once).
        pub fn validate(self: *const Self) bool {
            var seen: usize = 0;
            for (self.roots.items) |r| {
                if (r.parent != null) return false;
                if (!validateNode(r, &seen, 0)) return false;
            }
            return seen == self.count();
        }

        fn validateNode(node: *const Node, seen: *usize, level: usize) bool {
            if (level > 10_000) return false; // cycle guard
            seen.* += 1;
            for (node.children.items) |ch| {
                if (ch.parent != node) return false;
                if (!validateNode(ch, seen, level + 1)) return false;
            }
            return true;
        }
    };
}

const TF = Forest(u32);
const ta = std.testing.allocator;

test "add roots + addChild first/last ordering" {
    var f = TF.init(ta);
    defer f.deinit();
    _ = try f.add(1);
    _ = try f.add(2);
    _ = try f.addChild(3, 1, .last);
    _ = try f.addChild(4, 1, .last);
    _ = try f.addChild(5, 1, .first);
    try std.testing.expectEqual(@as(usize, 5), f.count());
    try std.testing.expectEqual(@as(?u32, 1), f.parentOf(3));
    try std.testing.expectEqual(@as(usize, 1), f.depth(4));

    var flat: std.ArrayList(u32) = .empty;
    defer flat.deinit(ta);
    try f.flattenAll(ta, &flat);
    try std.testing.expectEqualSlices(u32, &.{ 1, 5, 3, 4, 2 }, flat.items);
    try std.testing.expectError(error.AlreadyPresent, f.add(1));
    try std.testing.expectError(error.NotFound, f.addChild(9, 42, .last));
    try std.testing.expect(f.validate());
}

test "remove promotes children in place" {
    var f = TF.init(ta);
    defer f.deinit();
    _ = try f.add(1);
    _ = try f.add(2);
    _ = try f.addChild(3, 1, .last);
    _ = try f.addChild(4, 3, .last);
    _ = try f.addChild(5, 3, .last);
    // Remove mid node 3: 4 and 5 promote to children of 1, in order.
    try f.remove(3);
    try std.testing.expectEqual(@as(?u32, 1), f.parentOf(4));
    try std.testing.expectEqual(@as(?u32, 1), f.parentOf(5));
    var flat: std.ArrayList(u32) = .empty;
    defer flat.deinit(ta);
    try f.flattenAll(ta, &flat);
    try std.testing.expectEqualSlices(u32, &.{ 1, 4, 5, 2 }, flat.items);
    // Remove root 1: children promote to roots at its position.
    try f.remove(1);
    flat.clearRetainingCapacity();
    try f.flattenAll(ta, &flat);
    try std.testing.expectEqualSlices(u32, &.{ 4, 5, 2 }, flat.items);
    try std.testing.expectEqual(@as(?u32, null), f.parentOf(4));
    try std.testing.expectError(error.NotFound, f.remove(99));
    try std.testing.expect(f.validate());
}

test "reparent moves whole subtree and rejects cycles" {
    var f = TF.init(ta);
    defer f.deinit();
    _ = try f.add(1);
    _ = try f.add(2);
    _ = try f.addChild(3, 1, .last);
    _ = try f.addChild(4, 3, .last);
    // 3 (with its child 4) moves under 2.
    try f.reparent(3, 2, .last);
    try std.testing.expectEqual(@as(?u32, 2), f.parentOf(3));
    try std.testing.expectEqual(@as(?u32, 3), f.parentOf(4));
    try std.testing.expectEqual(@as(usize, 2), f.depth(4));
    // Into own subtree: rejected.
    try std.testing.expectError(error.WouldCycle, f.reparent(2, 4, .last));
    try std.testing.expectError(error.WouldCycle, f.reparent(3, 3, .last));
    // To root.
    try f.reparent(3, null, .first);
    try std.testing.expectEqual(@as(?u32, null), f.parentOf(3));
    var flat: std.ArrayList(u32) = .empty;
    defer flat.deinit(ta);
    try f.flattenAll(ta, &flat);
    try std.testing.expectEqualSlices(u32, &.{ 3, 4, 1, 2 }, flat.items);
    try std.testing.expect(f.validate());
}

test "collapse hides descendants, not the collapsed node" {
    var f = TF.init(ta);
    defer f.deinit();
    _ = try f.add(1);
    _ = try f.addChild(2, 1, .last);
    _ = try f.addChild(3, 2, .last);
    _ = try f.add(4);
    f.setCollapsed(1, true);
    try std.testing.expect(f.isCollapsed(1));
    try std.testing.expect(!f.isHidden(1));
    try std.testing.expect(f.isHidden(2));
    try std.testing.expect(f.isHidden(3));
    try std.testing.expect(!f.isHidden(4));
    var flat: std.ArrayList(u32) = .empty;
    defer flat.deinit(ta);
    try f.flattenVisible(ta, &flat);
    try std.testing.expectEqualSlices(u32, &.{ 1, 4 }, flat.items);
    // Inner collapse alone hides only below it.
    f.setCollapsed(1, false);
    f.setCollapsed(2, true);
    try std.testing.expect(!f.isHidden(2));
    try std.testing.expect(f.isHidden(3));
    flat.clearRetainingCapacity();
    try f.flattenVisible(ta, &flat);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 4 }, flat.items);
}

test "appendSubtree + stepVisible wraps in tree order" {
    var f = TF.init(ta);
    defer f.deinit();
    _ = try f.add(1);
    _ = try f.addChild(2, 1, .last);
    _ = try f.addChild(3, 2, .last);
    _ = try f.add(4);
    var sub: std.ArrayList(u32) = .empty;
    defer sub.deinit(ta);
    try f.appendSubtree(ta, 1, &sub);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, sub.items);

    try std.testing.expectEqual(@as(?u32, 2), try f.stepVisible(ta, 1, true));
    try std.testing.expectEqual(@as(?u32, 1), try f.stepVisible(ta, 4, true)); // wrap
    try std.testing.expectEqual(@as(?u32, 4), try f.stepVisible(ta, 1, false)); // wrap back
    // Collapsed subtree is skipped over.
    f.setCollapsed(1, true);
    try std.testing.expectEqual(@as(?u32, 4), try f.stepVisible(ta, 1, true));
    try std.testing.expectEqual(@as(?u32, null), try f.stepVisible(ta, 3, true)); // hidden ref
}

test "parentIndices maps nesting onto the SERIALIZED order, not the model's" {
    var f = TF.init(ta);
    defer f.deinit();
    // View order 1,2,3,4 with 3 nested under 2 and 4 under 3.
    _ = try f.add(1);
    _ = try f.add(2);
    _ = try f.addChild(3, 2, .last);
    _ = try f.addChild(4, 3, .last);

    // Nothing skipped: indices are the positions.
    var out: [4]?u32 = undefined;
    f.parentIndices(&.{ 1, 2, 3, 4 }, &out);
    try std.testing.expectEqual(@as(?u32, null), out[0]);
    try std.testing.expectEqual(@as(?u32, null), out[1]);
    try std.testing.expectEqual(@as(?u32, 1), out[2]);
    try std.testing.expectEqual(@as(?u32, 2), out[3]);

    // Tab 1 is skipped (no root widget / all-transient): every later
    // tab shifts down one. A position-based index would now name the
    // WRONG parent — 3 would claim parent 1, which is tab 2's slot.
    var out3: [3]?u32 = undefined;
    f.parentIndices(&.{ 2, 3, 4 }, &out3);
    try std.testing.expectEqual(@as(?u32, null), out3[0]);
    try std.testing.expectEqual(@as(?u32, 0), out3[1]);
    try std.testing.expectEqual(@as(?u32, 1), out3[2]);

    // A skipped PARENT leaves its child a root rather than pointing at
    // a stranger.
    var out2: [2]?u32 = undefined;
    f.parentIndices(&.{ 1, 4 }, &out2);
    try std.testing.expectEqual(@as(?u32, null), out2[0]);
    try std.testing.expectEqual(@as(?u32, null), out2[1]);
}
