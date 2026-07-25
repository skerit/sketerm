//! Persisted browser places: bookmarks + recent locations.
//!
//! One JSON file in the state dir, shared by every browser view
//! (last save wins — places are user-global, not per-pane). Specs
//! are host-qualified location strings ("host:/path" or "/path").

const std = @import("std");
const c = @import("../c.zig").c;
const pathz = @import("../util/pathz.zig");
const profile = @import("../util/profile.zig");

pub const RECENT_CAP = 12;

pub const SavedSearch = struct {
    /// Host-qualified root spec the search runs from.
    spec: []const u8 = "",
    pattern: []const u8 = "",
    content: bool = false,
};

/// A pre-register collection-shelf item. Kept only so a file written
/// by an older build can be migrated into the register store; new
/// saves always write this list empty.
pub const CollItem = struct {
    spec: []const u8 = "",
    dir: bool = false,
};

pub const Places = struct {
    bookmarks: []const []const u8 = &.{},
    recent: []const []const u8 = &.{},
    searches: []const SavedSearch = &.{},
    collection: []const CollItem = &.{},
};

pub fn filePath(allocator: std.mem.Allocator) ![]u8 {
    if (profile.getenv("XDG_STATE_HOME")) |xs| {
        return std.fmt.allocPrint(allocator, "{s}/sketerm/places.json", .{xs});
    }
    if (profile.getenv("HOME")) |home| {
        return std.fmt.allocPrint(allocator, "{s}/.local/state/sketerm/places.json", .{home});
    }
    return std.fmt.allocPrint(allocator, "/tmp/sketerm-places.json", .{});
}

pub fn load(allocator: std.mem.Allocator) ?std.json.Parsed(Places) {
    var pbuf: [4096]u8 = undefined;
    const path = filePath(allocator) catch return null;
    defer allocator.free(path);
    const fp = c.fopen(pathz.pathZ(&pbuf, path) catch return null, "rb") orelse return null;
    defer _ = c.fclose(fp);
    var bytes: [256 * 1024]u8 = undefined;
    const n = c.fread(&bytes, 1, bytes.len, fp);
    if (n == 0) return null;
    return std.json.parseFromSlice(Places, allocator, bytes[0..n], .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch null;
}

pub fn save(allocator: std.mem.Allocator, p: Places) void {
    const path = filePath(allocator) catch return;
    defer allocator.free(path);
    pathz.makeParentDirs(path) catch return;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    std.json.Stringify.value(p, .{}, &out.writer) catch return;
    var pbuf: [4096]u8 = undefined;
    const fp = c.fopen(pathz.pathZ(&pbuf, path) catch return, "wb") orelse return;
    defer _ = c.fclose(fp);
    _ = c.fwrite(out.written().ptr, 1, out.written().len, fp);
}

/// Front-insert `spec` into an owned-string list, deduping and
/// trimming to `cap`. The list owns its strings via `allocator`.
pub fn recordRecent(
    allocator: std.mem.Allocator,
    list: *std.ArrayList([]u8),
    spec: []const u8,
    cap: usize,
) void {
    var i: usize = 0;
    while (i < list.items.len) {
        if (std.mem.eql(u8, list.items[i], spec)) {
            allocator.free(list.items[i]);
            _ = list.orderedRemove(i);
        } else i += 1;
    }
    const owned = allocator.dupe(u8, spec) catch return;
    list.insert(allocator, 0, owned) catch {
        allocator.free(owned);
        return;
    };
    while (list.items.len > cap) {
        const last = list.pop() orelse break;
        allocator.free(last);
    }
}

test "recordRecent dedupes, front-inserts, and trims" {
    const t = std.testing;
    var list: std.ArrayList([]u8) = .empty;
    defer {
        for (list.items) |s| t.allocator.free(s);
        list.deinit(t.allocator);
    }
    recordRecent(t.allocator, &list, "/a", 3);
    recordRecent(t.allocator, &list, "/b", 3);
    recordRecent(t.allocator, &list, "/a", 3);
    try t.expectEqual(@as(usize, 2), list.items.len);
    try t.expectEqualStrings("/a", list.items[0]);
    recordRecent(t.allocator, &list, "/c", 3);
    recordRecent(t.allocator, &list, "/d", 3);
    try t.expectEqual(@as(usize, 3), list.items.len);
    try t.expectEqualStrings("/d", list.items[0]);
    try t.expectEqualStrings("/a", list.items[2]);
}
