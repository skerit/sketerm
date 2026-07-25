//! Listing groups: the bucket an entry falls into for the active sort
//! key, so a grouped view can draw one collapsible header per bucket.
//!
//! Pure and GTK-free: the renderer walks the ALREADY SORTED entries and
//! starts a new header whenever the returned id changes, which is only
//! correct because every bucket function here is monotonic in its sort
//! key. Date buckets are elapsed-time windows, not calendar days: the
//! daemon ships millisecond timestamps and this module deliberately
//! does not pull in a timezone database.

const std = @import("std");
const model = @import("model.zig");

/// One bucket. `id` is the collapse-state key; it is derived from the
/// label, so it stays stable across re-renders and differs between
/// sort keys (a collapsed "A" does not collapse a size bucket).
pub const Group = struct {
    id: u64 = 0,
    text: [48]u8 = undefined,
    len: u8 = 0,

    pub fn label(self: *const Group) []const u8 {
        return self.text[0..self.len];
    }
};

/// The entry facts a bucket can be computed from (the subset of the
/// listing model this module needs).
pub const Facts = struct {
    name: []const u8 = "",
    kind: []const u8 = "",
    size: u64 = 0,
    mtime_ms: i64 = 0,
    ctime_ms: i64 = 0,
    uid: u32 = 0,
    gid: u32 = 0,
    mode: u32 = 0,
    is_dir: bool = false,
};

const DAY_MS: i64 = 24 * 60 * 60 * 1000;

fn make(comptime fmt: []const u8, args: anytype) Group {
    var g = Group{};
    const written = std.fmt.bufPrint(&g.text, fmt, args) catch blk: {
        // A bucket label that does not fit is a bug, not a user
        // condition; degrade to a stable placeholder.
        break :blk std.fmt.bufPrint(&g.text, "?", .{}) catch unreachable;
    };
    g.len = @intCast(written.len);
    g.id = std.hash.Wyhash.hash(0, written);
    return g;
}

/// The folder bucket, used when dirs-first is on so directories never
/// interleave with the file buckets.
pub fn folders() Group {
    return make("Folders", .{});
}

/// The bucket `f` belongs to under `key`. `now_ms` is injected so the
/// date buckets are testable.
pub fn groupOf(key: model.SortKey, f: Facts, now_ms: i64) Group {
    return switch (key) {
        .name => nameGroup(f.name),
        .size => sizeGroup(f.size),
        .mtime => timeGroup(f.mtime_ms, now_ms),
        .ctime => timeGroup(f.ctime_ms, now_ms),
        .kind => make("{s}", .{if (f.kind.len > 0) f.kind else "unknown"}),
        .owner => make("uid {d}", .{f.uid}),
        .group => make("gid {d}", .{f.gid}),
        .permissions => make("mode {o:0>4}", .{f.mode & 0o7777}),
    };
}

fn nameGroup(name: []const u8) Group {
    const ch: u8 = if (name.len == 0) 0 else name[0];
    if (std.ascii.isAlphabetic(ch)) return make("{c}", .{std.ascii.toUpper(ch)});
    if (std.ascii.isDigit(ch)) return make("0-9", .{});
    return make("#", .{});
}

fn sizeGroup(size: u64) Group {
    if (size == 0) return make("Empty", .{});
    if (size < 100 * 1024) return make("Tiny (under 100 KB)", .{});
    if (size < 1024 * 1024) return make("Small (under 1 MB)", .{});
    if (size < 10 * 1024 * 1024) return make("Medium (under 10 MB)", .{});
    if (size < 100 * 1024 * 1024) return make("Large (under 100 MB)", .{});
    if (size < 1024 * 1024 * 1024) return make("Very large (under 1 GB)", .{});
    return make("Gigantic (1 GB and up)", .{});
}

fn timeGroup(t_ms: i64, now_ms: i64) Group {
    if (t_ms == 0) return make("Unknown date", .{});
    // A clock skew that puts a file in the future reads as fresh
    // rather than as an "older" outlier.
    const age = if (t_ms > now_ms) 0 else now_ms - t_ms;
    if (age < DAY_MS) return make("Today", .{});
    if (age < 7 * DAY_MS) return make("This week", .{});
    if (age < 30 * DAY_MS) return make("This month", .{});
    return make("Older", .{});
}

test "name buckets fold case and collect non-letters" {
    const t = std.testing;
    try t.expectEqualStrings("A", groupOf(.name, .{ .name = "apple" }, 0).label());
    try t.expectEqualStrings("A", groupOf(.name, .{ .name = "Anvil" }, 0).label());
    try t.expectEqualStrings("0-9", groupOf(.name, .{ .name = "7zip" }, 0).label());
    try t.expectEqualStrings("#", groupOf(.name, .{ .name = ".config" }, 0).label());
    try t.expectEqualStrings("#", groupOf(.name, .{ .name = "" }, 0).label());
    // Same label means same collapse key; different labels must not
    // collide.
    try t.expectEqual(
        groupOf(.name, .{ .name = "apple" }, 0).id,
        groupOf(.name, .{ .name = "Ant" }, 0).id,
    );
    try t.expect(groupOf(.name, .{ .name = "apple" }, 0).id != groupOf(.name, .{ .name = "beta" }, 0).id);
}

test "size buckets are monotonic across their boundaries" {
    const t = std.testing;
    const sizes = [_]u64{ 0, 1, 100 * 1024 - 1, 100 * 1024, 1024 * 1024, 10 * 1024 * 1024, 100 * 1024 * 1024, 1024 * 1024 * 1024 };
    var last: []const u8 = "";
    var seen: usize = 0;
    var labels: [sizes.len]Group = undefined;
    for (sizes, 0..) |s, i| {
        labels[i] = groupOf(.size, .{ .size = s }, 0);
        if (!std.mem.eql(u8, labels[i].label(), last)) seen += 1;
        last = labels[i].label();
    }
    // Seven distinct buckets: 100 KB - 1 shares "Tiny" with 1 byte,
    // every other listed size crosses a boundary.
    try t.expectEqual(@as(usize, 7), seen);
    try t.expectEqualStrings("Empty", groupOf(.size, .{ .size = 0 }, 0).label());
    try t.expectEqualStrings("Gigantic (1 GB and up)", groupOf(.size, .{ .size = 4 << 30 }, 0).label());
}

test "date buckets window on elapsed time and tolerate clock skew" {
    const t = std.testing;
    const now: i64 = 1_000 * DAY_MS;
    try t.expectEqualStrings("Today", groupOf(.mtime, .{ .mtime_ms = now - 1000 }, now).label());
    try t.expectEqualStrings("This week", groupOf(.mtime, .{ .mtime_ms = now - 3 * DAY_MS }, now).label());
    try t.expectEqualStrings("This month", groupOf(.mtime, .{ .mtime_ms = now - 20 * DAY_MS }, now).label());
    try t.expectEqualStrings("Older", groupOf(.mtime, .{ .mtime_ms = now - 400 * DAY_MS }, now).label());
    try t.expectEqualStrings("Unknown date", groupOf(.mtime, .{ .mtime_ms = 0 }, now).label());
    try t.expectEqualStrings("Today", groupOf(.mtime, .{ .mtime_ms = now + 5 * DAY_MS }, now).label());
    // ctime reads its own field, not mtime.
    try t.expectEqualStrings("Older", groupOf(.ctime, .{ .mtime_ms = now, .ctime_ms = now - 90 * DAY_MS }, now).label());
}

test "the remaining sort keys bucket by their own value" {
    const t = std.testing;
    try t.expectEqualStrings("dir", groupOf(.kind, .{ .kind = "dir" }, 0).label());
    try t.expectEqualStrings("unknown", groupOf(.kind, .{ .kind = "" }, 0).label());
    try t.expectEqualStrings("uid 1000", groupOf(.owner, .{ .uid = 1000 }, 0).label());
    try t.expectEqualStrings("gid 42", groupOf(.group, .{ .gid = 42 }, 0).label());
    try t.expectEqualStrings("mode 0644", groupOf(.permissions, .{ .mode = 0o100644 }, 0).label());
    try t.expectEqualStrings("Folders", folders().label());
}
