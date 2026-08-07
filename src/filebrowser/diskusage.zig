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
