//! Mirrored accessibility tree of one web view, fed by the `a11y`
//! capability's `ev_a11y_tree` / `ev_a11y_loc` frames.
//!
//! GTK-free and engine-free: the consumer (`src/ui/webface.zig`) and
//! the AT-SPI projection read this store, and the unit tests drive it
//! headless in both test roots. Updates are INCREMENTAL — a frame
//! carries only the nodes that changed, each with its full new content
//! and child list — so the store keeps everything by id and prunes
//! what an update made unreachable (an engine reparent implicitly
//! drops a subtree by no longer listing it).

const std = @import("std");
const proto = @import("protocol.zig");

pub const Attr = struct { key: []u8, value: []u8 };

pub const Node = struct {
    id: u32,
    state: u64 = 0,
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
    offset_container: u32 = 0,
    role: []u8 = &.{},
    name: []u8 = &.{},
    value: []u8 = &.{},
    description: []u8 = &.{},
    children: []u32 = &.{},
    attrs: []Attr = &.{},

    fn free(self: *Node, gpa: std.mem.Allocator) void {
        gpa.free(self.role);
        gpa.free(self.name);
        gpa.free(self.value);
        gpa.free(self.description);
        gpa.free(self.children);
        for (self.attrs) |a| {
            gpa.free(a.key);
            gpa.free(a.value);
        }
        gpa.free(self.attrs);
    }

    /// Attribute lookup; slices stay owned by the node.
    pub fn attr(self: *const Node, key: []const u8) ?[]const u8 {
        for (self.attrs) |a| {
            if (std.mem.eql(u8, a.key, key)) return a.value;
        }
        return null;
    }
};

pub const Tree = struct {
    gpa: std.mem.Allocator,
    nodes: std.AutoHashMapUnmanaged(u32, Node) = .empty,
    root_id: u32 = 0,
    focus_id: u32 = 0,
    /// Bumped on every applied frame; a projection republishing to a
    /// platform API can use it as a cheap "anything changed" probe.
    generation: u32 = 0,

    pub fn init(gpa: std.mem.Allocator) Tree {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Tree) void {
        var it = self.nodes.valueIterator();
        while (it.next()) |n| n.free(self.gpa);
        self.nodes.deinit(self.gpa);
    }

    pub fn get(self: *const Tree, id: u32) ?*const Node {
        return self.nodes.getPtr(id);
    }

    pub fn count(self: *const Tree) usize {
        return self.nodes.count();
    }

    /// Apply one `ev_a11y_tree` frame. A decode error drops the frame
    /// and leaves the store at its previous consistent state.
    pub fn applyTree(self: *Tree, ev: proto.EvA11yTree) !void {
        if (ev.node_id_to_clear != 0) self.dropDescendants(ev.node_id_to_clear);
        var it = proto.A11yNodeIter.init(ev.nodes.s);
        while (try it.next()) |wire| {
            var n = Node{ .id = wire.id };
            n.state = wire.state;
            n.x = wire.x;
            n.y = wire.y;
            n.w = wire.w;
            n.h = wire.h;
            n.offset_container = wire.offset_container;
            n.role = try self.gpa.dupe(u8, wire.role);
            errdefer self.gpa.free(n.role);
            n.name = try self.gpa.dupe(u8, wire.name);
            errdefer self.gpa.free(n.name);
            n.value = try self.gpa.dupe(u8, wire.value);
            errdefer self.gpa.free(n.value);
            n.description = try self.gpa.dupe(u8, wire.description);
            errdefer self.gpa.free(n.description);
            n.children = try self.gpa.alloc(u32, wire.nchildren);
            errdefer self.gpa.free(n.children);
            for (n.children, 0..) |*cid, i| cid.* = wire.childAt(i);
            var attrs: std.ArrayList(Attr) = .empty;
            errdefer {
                for (attrs.items) |a| {
                    self.gpa.free(a.key);
                    self.gpa.free(a.value);
                }
                attrs.deinit(self.gpa);
            }
            var ai = wire.attrs();
            while (try ai.next()) |a| {
                const k = try self.gpa.dupe(u8, a.key);
                errdefer self.gpa.free(k);
                const v = try self.gpa.dupe(u8, a.value);
                try attrs.append(self.gpa, .{ .key = k, .value = v });
            }
            n.attrs = try attrs.toOwnedSlice(self.gpa);

            const slot = try self.nodes.getOrPut(self.gpa, wire.id);
            if (slot.found_existing) slot.value_ptr.free(self.gpa);
            slot.value_ptr.* = n;
        }
        if (ev.root_id != 0) self.root_id = ev.root_id;
        self.focus_id = ev.focus_id;
        self.prune();
        self.generation +%= 1;
    }

    /// Apply one `ev_a11y_loc` frame (geometry only; unknown ids are
    /// skipped — the node may have been pruned already).
    pub fn applyLoc(self: *Tree, ev: proto.EvA11yLoc) !void {
        var it = proto.A11yLocIter.init(ev.locs.s);
        while (try it.next()) |l| {
            const n = self.nodes.getPtr(l.id) orelse continue;
            n.x = l.x;
            n.y = l.y;
            n.w = l.w;
            n.h = l.h;
            n.offset_container = l.offset_container;
        }
        self.generation +%= 1;
    }

    /// Remove everything below `id` (not `id` itself).
    fn dropDescendants(self: *Tree, id: u32) void {
        const n = self.nodes.getPtr(id) orelse return;
        // The child list is snapshotted because removal mutates the map.
        const kids = self.gpa.dupe(u32, n.children) catch return;
        defer self.gpa.free(kids);
        for (kids) |cid| self.removeSubtree(cid);
    }

    fn removeSubtree(self: *Tree, id: u32) void {
        var entry = self.nodes.fetchRemove(id) orelse return;
        const kids = self.gpa.dupe(u32, entry.value.children) catch {
            entry.value.free(self.gpa);
            return;
        };
        entry.value.free(self.gpa);
        defer self.gpa.free(kids);
        for (kids) |cid| self.removeSubtree(cid);
    }

    /// Drop every node unreachable from the root: the incremental
    /// format never lists removed subtrees, it just stops referencing
    /// them.
    fn prune(self: *Tree) void {
        if (self.root_id == 0) return;
        var live: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer live.deinit(self.gpa);
        self.mark(&live, self.root_id) catch return; // OOM: skip the sweep
        var dead: std.ArrayList(u32) = .empty;
        defer dead.deinit(self.gpa);
        var it = self.nodes.keyIterator();
        while (it.next()) |k| {
            if (!live.contains(k.*)) dead.append(self.gpa, k.*) catch return;
        }
        for (dead.items) |id| {
            var entry = self.nodes.fetchRemove(id) orelse continue;
            entry.value.free(self.gpa);
        }
    }

    fn mark(self: *Tree, live: *std.AutoHashMapUnmanaged(u32, void), id: u32) !void {
        if (live.contains(id)) return;
        const n = self.nodes.getPtr(id) orelse return;
        try live.put(self.gpa, id, {});
        for (n.children) |cid| try self.mark(live, cid);
    }
};

// ── tests ────────────────────────────────────────────────────────────

const t = std.testing;

fn encodeNodes(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), specs: []const proto.A11yNodeSpec) !void {
    var w = proto.A11yNodeWriter{ .gpa = gpa, .buf = buf };
    for (specs) |s| try w.put(s);
}

test "a full update builds the tree; an incremental one reshapes and prunes it" {
    const gpa = t.allocator;
    var tree = Tree.init(gpa);
    defer tree.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try encodeNodes(gpa, &buf, &.{
        .{ .id = 1, .role = "document", .name = "Page", .children = &.{ 2, 3 } },
        .{ .id = 2, .role = "heading", .name = "Hello", .attributes = &.{.{ .key = "level", .value = "1" }} },
        .{ .id = 3, .role = "generic", .children = &.{4} },
        .{ .id = 4, .role = "button", .name = "Go", .state = proto.ax_focusable },
    });
    try tree.applyTree(.{ .view = 1, .root_id = 1, .node_id_to_clear = 0, .focus_id = 4, .nodes = .{ .s = buf.items } });

    try t.expectEqual(@as(usize, 4), tree.count());
    try t.expectEqual(@as(u32, 1), tree.root_id);
    try t.expectEqual(@as(u32, 4), tree.focus_id);
    try t.expectEqualStrings("Hello", tree.get(2).?.name);
    try t.expectEqualStrings("1", tree.get(2).?.attr("level").?);
    try t.expectEqual(proto.ax_focusable, tree.get(4).?.state);

    // The engine drops the container: the root now lists only the
    // heading, so the container AND its button must be pruned.
    buf.clearRetainingCapacity();
    try encodeNodes(gpa, &buf, &.{
        .{ .id = 1, .role = "document", .name = "Page", .children = &.{2} },
    });
    try tree.applyTree(.{ .view = 1, .root_id = 1, .node_id_to_clear = 0, .focus_id = 0, .nodes = .{ .s = buf.items } });
    try t.expectEqual(@as(usize, 2), tree.count());
    try t.expectEqual(@as(?*const Node, null), tree.get(3));
    try t.expectEqual(@as(?*const Node, null), tree.get(4));
    // The heading node itself was untouched by the second frame.
    try t.expectEqualStrings("Hello", tree.get(2).?.name);
}

test "node_id_to_clear drops a subtree before the update lands" {
    const gpa = t.allocator;
    var tree = Tree.init(gpa);
    defer tree.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try encodeNodes(gpa, &buf, &.{
        .{ .id = 1, .role = "document", .children = &.{2} },
        .{ .id = 2, .role = "list", .children = &.{ 3, 4 } },
        .{ .id = 3, .role = "listitem", .name = "a" },
        .{ .id = 4, .role = "listitem", .name = "b" },
    });
    try tree.applyTree(.{ .view = 1, .root_id = 1, .node_id_to_clear = 0, .focus_id = 0, .nodes = .{ .s = buf.items } });
    try t.expectEqual(@as(usize, 4), tree.count());

    buf.clearRetainingCapacity();
    try encodeNodes(gpa, &buf, &.{
        .{ .id = 2, .role = "list", .children = &.{5} },
        .{ .id = 5, .role = "listitem", .name = "c" },
    });
    try tree.applyTree(.{ .view = 1, .root_id = 1, .node_id_to_clear = 2, .focus_id = 0, .nodes = .{ .s = buf.items } });
    try t.expectEqual(@as(usize, 3), tree.count());
    try t.expectEqualStrings("c", tree.get(5).?.name);
    try t.expectEqual(@as(?*const Node, null), tree.get(3));
}

test "location deltas move geometry without touching structure" {
    const gpa = t.allocator;
    var tree = Tree.init(gpa);
    defer tree.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try encodeNodes(gpa, &buf, &.{
        .{ .id = 1, .role = "document", .children = &.{2} },
        .{ .id = 2, .role = "button", .name = "Go", .x = 10, .y = 10, .w = 50, .h = 20 },
    });
    try tree.applyTree(.{ .view = 1, .root_id = 1, .node_id_to_clear = 0, .focus_id = 0, .nodes = .{ .s = buf.items } });

    var locs: std.ArrayList(u8) = .empty;
    defer locs.deinit(gpa);
    try proto.putA11yLoc(gpa, &locs, .{ .id = 2, .offset_container = 1, .x = 10, .y = 300, .w = 50, .h = 20 });
    try proto.putA11yLoc(gpa, &locs, .{ .id = 99, .offset_container = 0, .x = 0, .y = 0, .w = 0, .h = 0 });
    try tree.applyLoc(.{ .view = 1, .locs = .{ .s = locs.items } });
    try t.expectEqual(@as(i32, 300), tree.get(2).?.y);
    try t.expectEqualStrings("Go", tree.get(2).?.name);
    try t.expectEqual(@as(usize, 2), tree.count());
}

test "a truncated node payload leaves the store consistent" {
    const gpa = t.allocator;
    var tree = Tree.init(gpa);
    defer tree.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try encodeNodes(gpa, &buf, &.{
        .{ .id = 1, .role = "document", .children = &.{} },
    });
    try tree.applyTree(.{ .view = 1, .root_id = 1, .node_id_to_clear = 0, .focus_id = 0, .nodes = .{ .s = buf.items } });
    const err = tree.applyTree(.{
        .view = 1,
        .root_id = 1,
        .node_id_to_clear = 0,
        .focus_id = 0,
        .nodes = .{ .s = buf.items[0 .. buf.items.len - 2] },
    });
    try t.expectError(error.Truncated, err);
    try t.expectEqual(@as(usize, 1), tree.count());
}
