//! Disk-usage result model and treemap layout.

const std = @import("std");

pub const Metric = enum { allocated, apparent };
pub const Kind = enum { file, dir, mount };

pub const Node = struct {
    path: []u8,
    kind: Kind,
    size: u64,
    allocated: u64,
    items: u64,
    errors: u64,
    skipped: u64,
    mtime_ms: i64,

    pub fn value(self: Node, metric: Metric) u64 {
        return switch (metric) {
            .allocated => self.allocated,
            .apparent => self.size,
        };
    }
};

pub const WireNode = struct {
    path: []const u8,
    kind: []const u8,
    size: u64,
    allocated: u64,
    items: u64,
    errors: u64,
    skipped: u64,
    mtime_ms: i64,
};

pub const Model = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(Node) = .empty,
    by_path: std.StringHashMapUnmanaged(usize) = .empty,

    pub fn init(allocator: std.mem.Allocator) Model {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Model) void {
        for (self.nodes.items) |node| self.allocator.free(node.path);
        self.nodes.deinit(self.allocator);
        self.by_path.deinit(self.allocator);
    }

    pub fn clear(self: *Model) void {
        for (self.nodes.items) |node| self.allocator.free(node.path);
        self.nodes.clearRetainingCapacity();
        self.by_path.clearRetainingCapacity();
    }

    pub fn upsert(self: *Model, wire: WireNode) !usize {
        if (self.by_path.get(wire.path)) |index| {
            const path = self.nodes.items[index].path;
            self.nodes.items[index] = fromWire(path, wire);
            return index;
        }
        const path = try self.allocator.dupe(u8, wire.path);
        errdefer self.allocator.free(path);
        const index = self.nodes.items.len;
        try self.nodes.append(self.allocator, fromWire(path, wire));
        errdefer _ = self.nodes.pop();
        try self.by_path.put(self.allocator, path, index);
        return index;
    }

    pub fn get(self: *const Model, path: []const u8) ?*const Node {
        const index = self.by_path.get(path) orelse return null;
        return &self.nodes.items[index];
    }

    pub fn indexOf(self: *const Model, path: []const u8) ?usize {
        return self.by_path.get(path);
    }

    pub fn directChildren(
        self: *const Model,
        parent: []const u8,
        metric: Metric,
        out: *std.ArrayList(usize),
    ) !void {
        out.clearRetainingCapacity();
        for (self.nodes.items, 0..) |node, index| {
            if (std.mem.eql(u8, node.path, parent)) continue;
            const dirname = std.fs.path.dirname(node.path) orelse continue;
            if (std.mem.eql(u8, dirname, parent)) try out.append(self.allocator, index);
        }
        const SortCtx = struct { model: *const Model, metric: Metric };
        std.mem.sort(usize, out.items, SortCtx{ .model = self, .metric = metric }, struct {
            fn less(ctx: SortCtx, a: usize, b: usize) bool {
                const an = ctx.model.nodes.items[a];
                const bn = ctx.model.nodes.items[b];
                const av = an.value(ctx.metric);
                const bv = bn.value(ctx.metric);
                if (av != bv) return av > bv;
                return std.ascii.lessThanIgnoreCase(std.fs.path.basename(an.path), std.fs.path.basename(bn.path));
            }
        }.less);
    }

    pub fn unrepresented(self: *const Model, parent: []const u8, metric: Metric, shown: []const usize) u64 {
        const total = if (self.get(parent)) |node| node.value(metric) else return 0;
        var represented: u64 = 0;
        for (shown) |index| represented +|= self.nodes.items[index].value(metric);
        return total -| represented;
    }

    fn fromWire(path: []u8, wire: WireNode) Node {
        return .{
            .path = path,
            .kind = if (std.mem.eql(u8, wire.kind, "dir"))
                .dir
            else if (std.mem.eql(u8, wire.kind, "mount"))
                .mount
            else
                .file,
            .size = wire.size,
            .allocated = wire.allocated,
            .items = wire.items,
            .errors = wire.errors,
            .skipped = wire.skipped,
            .mtime_ms = wire.mtime_ms,
        };
    }
};

/// Whether `path` is `root` or lies beneath it, segment-wise.
pub fn within(root: []const u8, path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, root)) return false;
    return path.len == root.len or root.len == 1 or path[root.len] == '/';
}

/// The entry directly under `ancestor` on the way to `descendant`, null
/// unless `descendant` lies strictly beneath `ancestor`.
pub fn childToward(ancestor: []const u8, descendant: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, ancestor, descendant) or !within(ancestor, descendant)) return null;
    const start = if (ancestor.len == 1) 1 else ancestor.len + 1;
    const end = std.mem.indexOfScalarPos(u8, descendant, start, '/') orelse descendant.len;
    return descendant[0..end];
}

/// What one result row shows; a row is rewritten only when this changes,
/// so a re-render with the same numbers touches no widget.
pub const RowFace = struct {
    kind: Kind,
    /// The "Other" remainder row rather than a node.
    other: bool = false,
    value: u64,
    /// Share of the displayed total in tenths of a percent, as printed.
    permille: u32,
    /// Contained entries (directories) as printed in the Contents column.
    items: u64,
    warning: bool,
    /// Children the "Other" row stands for beyond the row cap.
    omitted: usize = 0,

    pub fn eql(a: RowFace, b: RowFace) bool {
        return a.kind == b.kind and a.other == b.other and a.value == b.value and
            a.permille == b.permille and a.items == b.items and a.warning == b.warning and
            a.omitted == b.omitted;
    }
};

/// Rounded share of `total` in tenths of a percent, capped at 100%.
pub fn permilleOf(value: u64, total: u64) u32 {
    if (total == 0) return 0;
    const v: u128 = @min(value, total);
    return @intCast((v * 1000 + total / 2) / total);
}

pub fn nodeFace(node: Node, metric: Metric, total: u64) RowFace {
    const value = node.value(metric);
    return .{
        .kind = node.kind,
        .value = value,
        .permille = permilleOf(value, total),
        .items = if (node.kind == .dir) node.items -| 1 else 1,
        .warning = node.errors > 0,
    };
}

pub fn otherFace(value: u64, total: u64, omitted: usize) RowFace {
    return .{ .kind = .file, .other = true, .value = value, .permille = permilleOf(value, total), .items = 0, .warning = false, .omitted = omitted };
}

/// The folders drilled through and how far each was scrolled, so going
/// back up shows a folder where it was left.
pub const Trail = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,

    pub const Entry = struct { path: []u8, scroll: f64 };

    pub fn init(allocator: std.mem.Allocator) Trail {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Trail) void {
        self.truncate(0);
        self.entries.deinit(self.allocator);
    }

    pub fn truncate(self: *Trail, len: usize) void {
        for (self.entries.items[len..]) |e| self.allocator.free(e.path);
        self.entries.shrinkRetainingCapacity(len);
    }

    /// Leave `from`, scrolled to `scroll`, for `to`.
    /// @return the scroll offset to show `to` at: where it was left when
    /// it is on the trail, else the top.
    pub fn move(self: *Trail, from: []const u8, scroll: f64, to: []const u8) f64 {
        // Only ancestors of the destination stay meaningful.
        var keep: usize = 0;
        while (keep < self.entries.items.len and within(self.entries.items[keep].path, to)) keep += 1;
        if (keep > 0 and std.mem.eql(u8, self.entries.items[keep - 1].path, to)) {
            const back = self.entries.items[keep - 1].scroll;
            self.truncate(keep - 1);
            return back;
        }
        self.truncate(keep);
        if (!std.mem.eql(u8, from, to) and within(from, to)) {
            // Out of memory only forgets where `from` was scrolled.
            const owned = self.allocator.dupe(u8, from) catch return 0;
            self.entries.append(self.allocator, .{ .path = owned, .scroll = scroll }) catch self.allocator.free(owned);
        }
        return 0;
    }
};

pub const TreemapItem = struct { id: usize, value: u64 };
pub const Rect = struct { id: usize, x: f64, y: f64, w: f64, h: f64 };

/// Lays out size-sorted items with balanced recursive partitions.
pub fn layoutTreemap(items: []const TreemapItem, bounds: Rect, out: []Rect) usize {
    if (items.len == 0 or out.len == 0 or bounds.w <= 0 or bounds.h <= 0) return 0;
    return layoutRange(items, bounds, out);
}

fn layoutRange(items: []const TreemapItem, bounds: Rect, out: []Rect) usize {
    if (items.len == 0 or out.len == 0) return 0;
    if (items.len == 1) {
        if (items[0].value == 0) return 0;
        out[0] = .{ .id = items[0].id, .x = bounds.x, .y = bounds.y, .w = bounds.w, .h = bounds.h };
        return 1;
    }
    var total: u64 = 0;
    for (items) |item| total +|= item.value;
    if (total == 0) return 0;

    var left: u64 = 0;
    var split: usize = 1;
    var best = total;
    for (items[0 .. items.len - 1], 0..) |item, i| {
        left +|= item.value;
        const twice = left +| left;
        const distance = if (twice > total) twice - total else total - twice;
        if (distance <= best) {
            best = distance;
            split = i + 1;
        } else break;
    }
    var left_total: u64 = 0;
    for (items[0..split]) |item| left_total +|= item.value;
    const fraction = @as(f64, @floatFromInt(left_total)) / @as(f64, @floatFromInt(total));
    var first = bounds;
    var second = bounds;
    if (bounds.w >= bounds.h) {
        first.w = bounds.w * fraction;
        second.x += first.w;
        second.w -= first.w;
    } else {
        first.h = bounds.h * fraction;
        second.y += first.h;
        second.h -= first.h;
    }
    const n = layoutRange(items[0..split], first, out);
    return n + layoutRange(items[split..], second, out[n..]);
}

test "disk usage model sorts direct children and computes the hidden remainder" {
    const t = std.testing;
    var model = Model.init(t.allocator);
    defer model.deinit();
    _ = try model.upsert(.{ .path = "/scan", .kind = "dir", .size = 1000, .allocated = 1200, .items = 4, .errors = 0, .skipped = 0, .mtime_ms = 0 });
    _ = try model.upsert(.{ .path = "/scan/small", .kind = "file", .size = 10, .allocated = 512, .items = 1, .errors = 0, .skipped = 0, .mtime_ms = 0 });
    _ = try model.upsert(.{ .path = "/scan/large", .kind = "dir", .size = 700, .allocated = 600, .items = 2, .errors = 0, .skipped = 0, .mtime_ms = 0 });
    _ = try model.upsert(.{ .path = "/scan/large/nested", .kind = "file", .size = 700, .allocated = 600, .items = 1, .errors = 0, .skipped = 0, .mtime_ms = 0 });

    var children: std.ArrayList(usize) = .empty;
    defer children.deinit(t.allocator);
    try model.directChildren("/scan", .allocated, &children);
    try t.expectEqual(@as(usize, 2), children.items.len);
    try t.expectEqualStrings("/scan/large", model.nodes.items[children.items[0]].path);
    try t.expectEqualStrings("/scan/small", model.nodes.items[children.items[1]].path);
    try t.expectEqual(@as(u64, 88), model.unrepresented("/scan", .allocated, children.items));
}

test "balanced treemap preserves bounds and positive area" {
    const t = std.testing;
    const items = [_]TreemapItem{
        .{ .id = 1, .value = 50 },
        .{ .id = 2, .value = 30 },
        .{ .id = 3, .value = 20 },
    };
    var rects: [3]Rect = undefined;
    const count = layoutTreemap(&items, .{ .id = 0, .x = 0, .y = 0, .w = 100, .h = 80 }, &rects);
    try t.expectEqual(@as(usize, 3), count);
    var area: f64 = 0;
    for (rects[0..count]) |rect| {
        try t.expect(rect.w > 0 and rect.h > 0);
        try t.expect(rect.x >= 0 and rect.y >= 0);
        try t.expect(rect.x + rect.w <= 100.0001);
        try t.expect(rect.y + rect.h <= 80.0001);
        area += rect.w * rect.h;
    }
    try t.expectApproxEqAbs(@as(f64, 8000), area, 0.01);
}

test "disk usage containment rejects sibling prefixes" {
    try std.testing.expect(within("/srv/data", "/srv/data/a"));
    try std.testing.expect(within("/srv/data", "/srv/data"));
    try std.testing.expect(within("/", "/var"));
    try std.testing.expect(!within("/srv/data", "/srv/database"));
}

test "disk usage names the child on the way down" {
    const t = std.testing;
    try t.expectEqualStrings("/r/a", childToward("/r", "/r/a/b/c").?);
    try t.expectEqualStrings("/r/a", childToward("/r", "/r/a").?);
    try t.expectEqualStrings("/var", childToward("/", "/var/log").?);
    try t.expect(childToward("/r", "/r") == null);
    try t.expect(childToward("/r/a", "/r") == null);
    try t.expect(childToward("/r", "/rx/a") == null);
}

test "disk usage row faces change only with what a row prints" {
    const t = std.testing;
    var path = "/scan/a".*;
    const node: Node = .{ .path = &path, .kind = .dir, .size = 300, .allocated = 400, .items = 5, .errors = 0, .skipped = 0, .mtime_ms = 0 };
    const a = nodeFace(node, .allocated, 1000);
    try t.expectEqual(@as(u32, 400), a.permille);
    try t.expectEqual(@as(u64, 4), a.items);
    // A total that moves by less than the printed precision is the same face.
    try t.expect(a.eql(nodeFace(node, .allocated, 1001)));
    try t.expect(!a.eql(nodeFace(node, .allocated, 2000)));
    try t.expect(!a.eql(nodeFace(node, .apparent, 1000)));
    var warned = node;
    warned.errors = 1;
    try t.expect(!a.eql(nodeFace(warned, .allocated, 1000)));
    try t.expect(!otherFace(10, 100, 0).eql(otherFace(10, 100, 3)));
    try t.expectEqual(@as(u32, 0), permilleOf(5, 0));
    try t.expectEqual(@as(u32, 1000), permilleOf(7, 5));
    try t.expectEqual(@as(u32, 1), permilleOf(1, 1999));
}

test "disk usage trail restores the scroll of the folders it drilled through" {
    const t = std.testing;
    var trail = Trail.init(t.allocator);
    defer trail.deinit();
    try t.expectEqual(@as(f64, 0), trail.move("/r", 300, "/r/a"));
    try t.expectEqual(@as(f64, 0), trail.move("/r/a", 50, "/r/a/b"));
    try t.expectEqual(@as(f64, 50), trail.move("/r/a/b", 9, "/r/a"));
    try t.expectEqual(@as(f64, 300), trail.move("/r/a", 0, "/r"));
    try t.expectEqual(@as(usize, 0), trail.entries.items.len);
    // A jump sideways forgets the branch it left, not the shared root.
    _ = trail.move("/r", 120, "/r/a");
    _ = trail.move("/r/a", 40, "/r/a/b");
    try t.expectEqual(@as(f64, 0), trail.move("/r/a/b", 0, "/r/c"));
    try t.expectEqual(@as(usize, 1), trail.entries.items.len);
    try t.expectEqual(@as(f64, 120), trail.move("/r/c", 0, "/r"));
    // Re-entering a remembered folder from above starts at the top.
    _ = trail.move("/r", 80, "/r/a");
    try t.expectEqual(@as(f64, 0), trail.move("/r/a", 0, "/r/a/b"));
    try t.expectEqual(@as(usize, 2), trail.entries.items.len);
}

test "disk usage trail survives allocation failure" {
    const testalloc = @import("../util/testalloc.zig");
    // Index 0 fails the path copy, 1 the list growth: either way the
    // trail only forgets, it never leaks or keeps a dangling entry.
    for (0..2) |fail_index| {
        var failing = std.testing.FailingAllocator.init(testalloc.no_resize, .{ .fail_index = fail_index });
        var trail = Trail.init(failing.allocator());
        defer trail.deinit();
        try std.testing.expectEqual(@as(f64, 0), trail.move("/r", 300, "/r/a"));
        try std.testing.expectEqual(@as(usize, 0), trail.entries.items.len);
        try std.testing.expectEqual(@as(f64, 0), trail.move("/r/a", 0, "/r"));
    }
}
