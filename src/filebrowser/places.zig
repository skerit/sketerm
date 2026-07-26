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
    /// Sidebar section headers the user folded shut, by header text.
    /// Missing (an older file) = everything expanded.
    collapsed: []const []const u8 = &.{},
    /// Width of the places sidebar, in pixels (the GtkPaned position).
    sidebar_px: i32 = DEFAULT_SIDEBAR_PX,
    /// Whether the sidebar is shown. `null` = never toggled, so the
    /// default follows the application identity (on in files mode).
    sidebar_open: ?bool = null,
};

pub const DEFAULT_SIDEBAR_PX: i32 = 190;
pub const MIN_SIDEBAR_PX: i32 = 120;
pub const MAX_SIDEBAR_PX: i32 = 900;

/// Keep a persisted sidebar width usable: a file written by a crashed
/// drag (or hand-edited) must not be able to hide the sidebar or eat
/// the listing.
pub fn clampSidebarPx(px: i32) i32 {
    if (px < MIN_SIDEBAR_PX) return DEFAULT_SIDEBAR_PX;
    if (px > MAX_SIDEBAR_PX) return MAX_SIDEBAR_PX;
    return px;
}

/// A recent location split for display: the leading path (shown
/// dimmed) and the final component.
pub const RecentLabel = struct {
    /// Everything before the final component, trailing slash kept.
    parent: []const u8 = "",
    name: []const u8 = "",
};

/// Split a recent-location spec into its dimmed lead and its final
/// component. The "local:" scheme is dropped (it is the default);
/// a remote spec keeps its "user@host:" in the parent part.
pub fn splitRecentLabel(spec: []const u8) RecentLabel {
    var rest = spec;
    if (std.mem.startsWith(u8, rest, "local:")) rest = rest["local:".len..];
    if (rest.len == 0) return .{ .name = spec };
    var end = rest.len;
    while (end > 1 and rest[end - 1] == '/') end -= 1;
    const trimmed = rest[0..end];
    const slash = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse
        return .{ .name = trimmed };
    const name = trimmed[slash + 1 ..];
    if (name.len == 0) return .{ .name = trimmed };
    return .{ .parent = trimmed[0 .. slash + 1], .name = name };
}

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

test "splitRecentLabel dims the lead and drops the local scheme" {
    const t = std.testing;
    const a = splitRecentLabel("local:/home/skerit/projects/foo");
    try t.expectEqualStrings("/home/skerit/projects/", a.parent);
    try t.expectEqualStrings("foo", a.name);
    const b = splitRecentLabel("/home/skerit");
    try t.expectEqualStrings("/home/", b.parent);
    try t.expectEqualStrings("skerit", b.name);
    // A remote spec keeps its host visible, as part of the lead.
    const d = splitRecentLabel("user@box:/srv/www");
    try t.expectEqualStrings("user@box:/srv/", d.parent);
    try t.expectEqualStrings("www", d.name);
    // Roots and trailing slashes never yield an empty name.
    const e = splitRecentLabel("local:/");
    try t.expectEqualStrings("", e.parent);
    try t.expectEqualStrings("/", e.name);
    const f = splitRecentLabel("/home/skerit/");
    try t.expectEqualStrings("/home/", f.parent);
    try t.expectEqualStrings("skerit", f.name);
    const g = splitRecentLabel("register:marks");
    try t.expectEqualStrings("", g.parent);
    try t.expectEqualStrings("register:marks", g.name);
}

test "sidebar fields default for a file written before they existed" {
    const t = std.testing;
    const old = "{\"bookmarks\":[],\"recent\":[],\"searches\":[],\"collection\":[],\"collapsed\":[]}";
    const parsed = try std.json.parseFromSlice(Places, t.allocator, old, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    try t.expectEqual(DEFAULT_SIDEBAR_PX, parsed.value.sidebar_px);
    try t.expectEqual(@as(?bool, null), parsed.value.sidebar_open);
}

test "sidebar fields round-trip through the saved JSON" {
    const t = std.testing;
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    try std.json.Stringify.value(Places{ .sidebar_px = 245, .sidebar_open = false }, .{}, &out.writer);
    const parsed = try std.json.parseFromSlice(Places, t.allocator, out.written(), .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    try t.expectEqual(@as(i32, 245), parsed.value.sidebar_px);
    try t.expectEqual(@as(?bool, false), parsed.value.sidebar_open);
}

test "clampSidebarPx rejects widths that would break the layout" {
    const t = std.testing;
    try t.expectEqual(DEFAULT_SIDEBAR_PX, clampSidebarPx(0));
    try t.expectEqual(DEFAULT_SIDEBAR_PX, clampSidebarPx(-40));
    try t.expectEqual(DEFAULT_SIDEBAR_PX, clampSidebarPx(MIN_SIDEBAR_PX - 1));
    try t.expectEqual(MIN_SIDEBAR_PX, clampSidebarPx(MIN_SIDEBAR_PX));
    try t.expectEqual(@as(i32, 245), clampSidebarPx(245));
    try t.expectEqual(MAX_SIDEBAR_PX, clampSidebarPx(10_000));
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
