//! Client-side provenance for stable IDs returned by rich reader results.

const std = @import("std");
const proto = @import("protocol.zig");

pub const Entry = struct {
    id: u32,
    doc_gen: u32,
    rev: u32,
    guard: u64,
};

pub const Store = struct {
    entries: std.ArrayList(Entry) = .empty,
    latest_request: u32 = 0,

    pub fn deinit(self: *Store, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
    }

    pub fn get(self: *const Store, id: u32) ?Entry {
        for (self.entries.items) |entry| {
            if (entry.id == id) return entry;
        }
        return null;
    }

    /// Preserve typed provenance while making every retained ID stale.
    pub fn invalidate(self: *Store) void {
        for (self.entries.items) |*entry|
            entry.* = .{ .id = entry.id, .doc_gen = 0, .rev = 0, .guard = 0 };
    }

    /// Forget everything for a new helper epoch: a restarted helper
    /// restarts sid allocation at 1, so a remembered dead-epoch id
    /// would collide with a fresh snapshot id and route ordinary
    /// actions through the guarded path with zero guards forever.
    pub fn resetEpoch(self: *Store) void {
        self.entries.clearRetainingCapacity();
        self.latest_request = 0;
    }

    /// Refresh from a result unless a newer correlated read already won.
    pub fn apply(self: *Store, allocator: std.mem.Allocator, request: u32, result: proto.SemReadIdsResult) !bool {
        if (request != 0 and self.latest_request != 0 and requestPrecedes(request, self.latest_request)) {
            try self.entries.ensureTotalCapacity(allocator, self.entries.items.len + result.entities.len);
            for (result.entities) |entity| {
                for (self.entries.items) |entry| {
                    if (entry.id == entity.id) break;
                } else self.entries.appendAssumeCapacity(.{
                    .id = entity.id,
                    .doc_gen = 0,
                    .rev = 0,
                    .guard = 0,
                });
            }
            return false;
        }
        try self.entries.ensureTotalCapacity(allocator, self.entries.items.len + result.entities.len);
        self.invalidate();
        for (result.entities) |entity| {
            for (self.entries.items) |*entry| {
                if (entry.id != entity.id) continue;
                entry.* = .{
                    .id = entity.id,
                    .doc_gen = result.doc_gen,
                    .rev = result.rev,
                    .guard = entity.guard,
                };
                break;
            } else self.entries.appendAssumeCapacity(.{
                .id = entity.id,
                .doc_gen = result.doc_gen,
                .rev = result.rev,
                .guard = entity.guard,
            });
        }
        if (request != 0) self.latest_request = request;
        return true;
    }
};

fn requestPrecedes(request: u32, latest: u32) bool {
    return request != latest and request -% latest > std.math.maxInt(u32) / 2;
}

test "newer rich reads own the active guard table" {
    const allocator = std.testing.allocator;
    var store: Store = .{};
    defer store.deinit(allocator);

    const first = [_]proto.ReaderEntity{
        .{ .id = 7, .guard = 70, .kind = "link", .text = "seven", .url = "#7" },
        .{ .id = 8, .guard = 80, .kind = "link", .text = "eight", .url = "#8" },
    };
    try std.testing.expect(try store.apply(allocator, 10, .{
        .view = 1,
        .doc_gen = 3,
        .rev = 4,
        .markdown = .{ .s = "first" },
        .entities = &first,
    }));

    const newest = [_]proto.ReaderEntity{
        .{ .id = 8, .guard = 81, .kind = "link", .text = "eight", .url = "#new" },
    };
    try std.testing.expect(try store.apply(allocator, 12, .{
        .view = 1,
        .doc_gen = 3,
        .rev = 4,
        .markdown = .{ .s = "newest" },
        .entities = &newest,
    }));
    try std.testing.expectEqual(@as(u64, 0), store.get(7).?.guard);
    try std.testing.expectEqual(@as(u64, 81), store.get(8).?.guard);

    const late = [_]proto.ReaderEntity{
        .{ .id = 7, .guard = 71, .kind = "link", .text = "seven", .url = "#late" },
        .{ .id = 9, .guard = 90, .kind = "link", .text = "nine", .url = "#late-only" },
    };
    try std.testing.expect(!try store.apply(allocator, 11, .{
        .view = 1,
        .doc_gen = 3,
        .rev = 4,
        .markdown = .{ .s = "late" },
        .entities = &late,
    }));
    try std.testing.expectEqual(@as(u64, 0), store.get(7).?.guard);
    try std.testing.expectEqual(@as(u64, 81), store.get(8).?.guard);
    try std.testing.expectEqual(@as(u64, 0), store.get(9).?.guard);
}

test "invalidation retains provenance and helper reset accepts a fresh sequence" {
    const allocator = std.testing.allocator;
    var store: Store = .{};
    defer store.deinit(allocator);

    const entities = [_]proto.ReaderEntity{
        .{ .id = 7, .guard = 70, .kind = "link", .text = "seven", .url = "#7" },
    };
    try std.testing.expect(try store.apply(allocator, std.math.maxInt(u32), .{
        .view = 1,
        .doc_gen = 9,
        .rev = 2,
        .markdown = .{ .s = "old helper" },
        .entities = &entities,
    }));
    store.invalidate();
    try std.testing.expectEqual(@as(u64, 0), store.get(7).?.guard);

    store.resetEpoch();
    try std.testing.expect(try store.apply(allocator, 1, .{
        .view = 1,
        .doc_gen = 1,
        .rev = 1,
        .markdown = .{ .s = "new helper" },
        .entities = &entities,
    }));
    try std.testing.expectEqual(@as(u64, 70), store.get(7).?.guard);
}

test "helper reset forgets dead-epoch ids so fresh sid reuse stays unguarded" {
    const allocator = std.testing.allocator;
    var store: Store = .{};
    defer store.deinit(allocator);

    const entities = [_]proto.ReaderEntity{
        .{ .id = 1, .guard = 10, .kind = "link", .text = "one", .url = "#1" },
        .{ .id = 2, .guard = 20, .kind = "link", .text = "two", .url = "#2" },
    };
    try std.testing.expect(try store.apply(allocator, 5, .{
        .view = 1,
        .doc_gen = 4,
        .rev = 6,
        .markdown = .{ .s = "old helper" },
        .entities = &entities,
    }));

    // The helper restarts: sid 1 will be minted again for an unrelated
    // element, so nothing remembered may survive as a (dead) guard.
    store.resetEpoch();
    try std.testing.expectEqual(@as(usize, 0), store.entries.items.len);
    try std.testing.expect(store.get(1) == null);
    try std.testing.expect(store.get(2) == null);
}

test "request ordering crosses the u32 wrap" {
    const allocator = std.testing.allocator;
    var store: Store = .{};
    defer store.deinit(allocator);

    const before = [_]proto.ReaderEntity{
        .{ .id = 7, .guard = 70, .kind = "link", .text = "before", .url = "#before" },
    };
    try std.testing.expect(try store.apply(allocator, std.math.maxInt(u32), .{
        .view = 1,
        .doc_gen = 1,
        .rev = 1,
        .markdown = .{ .s = "before" },
        .entities = &before,
    }));
    const after = [_]proto.ReaderEntity{
        .{ .id = 7, .guard = 71, .kind = "link", .text = "after", .url = "#after" },
    };
    try std.testing.expect(try store.apply(allocator, 1, .{
        .view = 1,
        .doc_gen = 1,
        .rev = 1,
        .markdown = .{ .s = "after" },
        .entities = &after,
    }));
    try std.testing.expectEqual(@as(u64, 71), store.get(7).?.guard);
}
