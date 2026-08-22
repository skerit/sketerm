//! Persisted browser places: bookmarks + recent locations.
//!
//! One JSON file in the state dir, shared by every browser view
//! (last save wins — places are user-global, not per-pane). Specs
//! are host-qualified location strings ("host:/path" or "/path").

const std = @import("std");
const c = @import("../c.zig").c;
const atomicwrite = @import("../util/atomicwrite.zig");
const readfile = @import("../util/readfile.zig");
const profile = @import("../util/profile.zig");

/// Cap on this state file. Past it there is no usable record to read,
/// and the cap is what stops a doctored one exhausting memory.
const STATE_MAX_BYTES = 256 * 1024;

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

/// One user sidebar widget. `kind` decides which of the other fields
/// matter: title/text use `text`; command/graph run `command` (graph
/// plots its numeric first line); image shows the file at `path`.
pub const Widget = struct {
    kind: []const u8 = "title",
    text: []const u8 = "",
    command: []const u8 = "",
    path: []const u8 = "",
    /// Re-run seconds for command/graph output; 0 = once per session.
    interval_secs: u32 = 0,
};

/// A user-named sidebar section housing widgets.
pub const WidgetSection = struct {
    name: []const u8 = "",
    widgets: []const Widget = &.{},
};

pub const Places = struct {
    bookmarks: []const []const u8 = &.{},
    /// Display labels parallel to `bookmarks`; "" (or a missing tail,
    /// for files written before labels existed) = derive from spec.
    bookmark_labels: []const []const u8 = &.{},
    /// Custom icons parallel to `bookmarks`; "" (or a missing tail,
    /// for files written before icons existed) = the default star.
    /// A value is a themed icon name, an emoji, or an absolute
    /// image-file path — resolved at render time, not here.
    bookmark_icons: []const []const u8 = &.{},
    recent: []const []const u8 = &.{},
    /// Visit statistics behind the frecency jump (Ctrl+J): parallel
    /// to nothing, its own capped list.
    frecency: []const FrecEntry = &.{},
    searches: []const SavedSearch = &.{},
    collection: []const CollItem = &.{},
    /// Sidebar section headers the user folded shut, by header text.
    /// Missing (an older file) = everything expanded.
    collapsed: []const []const u8 = &.{},
    /// Sidebar sections hidden entirely, by section KEY (see
    /// `builtin_sections`; "remote" covers every host section,
    /// "widgets:<name>" a user widget section).
    hidden_sections: []const []const u8 = &.{},
    /// Preferred section order, by key. Keys absent here keep the
    /// default order after the listed ones.
    section_order: []const []const u8 = &.{},
    /// User widget sections (rendered between the built-in sections
    /// per `section_order`).
    widget_sections: []const WidgetSection = &.{},
    /// Width of the places sidebar, in pixels (the GtkPaned position).
    sidebar_px: i32 = DEFAULT_SIDEBAR_PX,
    /// Whether the sidebar is shown. `null` = never toggled, so the
    /// default follows the application identity (on in files mode).
    sidebar_open: ?bool = null,
    /// Alternating row background in the list views.
    zebra: bool = false,
    /// Width of the Information panel, in pixels.
    preview_px: i32 = 300,
    /// Compact info card at the bottom of the places sidebar.
    side_info: bool = false,
};

/// Stable identity + display title for each built-in sidebar section.
/// The KEY is what hidden_sections/section_order store; the title is
/// what the header shows (and what fold state keys on, historically).
pub const SectionDef = struct { key: []const u8, title: []const u8 };

pub const builtin_sections = [_]SectionDef{
    .{ .key = "local", .title = "Local Places" },
    .{ .key = "remote", .title = "Remote Places" },
    .{ .key = "registers", .title = "Registers" },
    .{ .key = "bookmarks", .title = "Bookmarks" },
    .{ .key = "searches", .title = "Saved Queries" },
    .{ .key = "recent", .title = "Recent" },
    .{ .key = "devices", .title = "Devices" },
};

pub const WIDGET_KEY_PREFIX = "widgets:";

/// Merge a saved order with the full current key set: saved keys that
/// still exist come first (in saved order), then every remaining key
/// in `all` order. Caller frees the returned slice (the strings are
/// borrowed from `all`).
pub fn orderSections(
    allocator: std.mem.Allocator,
    saved: []const []const u8,
    all: []const []const u8,
) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);
    for (saved) |k| {
        const exists = for (all) |a| {
            if (std.mem.eql(u8, a, k)) break true;
        } else false;
        if (!exists) continue;
        const dup = for (out.items) |o| {
            if (std.mem.eql(u8, o, k)) break true;
        } else false;
        if (dup) continue;
        // Borrow the canonical string, not the saved one: `saved`
        // may be freed before the result.
        for (all) |a| {
            if (std.mem.eql(u8, a, k)) {
                try out.append(allocator, a);
                break;
            }
        }
    }
    for (all) |a| {
        const seen = for (out.items) |o| {
            if (std.mem.eql(u8, o, a)) break true;
        } else false;
        if (!seen) try out.append(allocator, a);
    }
    return out.toOwnedSlice(allocator);
}

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
    const path = filePath(allocator) catch return null;
    defer allocator.free(path);
    return loadFromPath(allocator, path);
}

fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) ?std.json.Parsed(Places) {
    return readfile.json(Places, allocator, path, STATE_MAX_BYTES);
}

pub fn save(allocator: std.mem.Allocator, p: Places) !void {
    const path = try filePath(allocator);
    defer allocator.free(path);
    try saveToPath(allocator, path, p);
}

/// The app owns this file, so its mode is FORCED: a copy an older build
/// created 0644 must be narrowed, not preserved forever.
fn saveToPath(allocator: std.mem.Allocator, path: []const u8, p: Places) !void {
    try atomicwrite.writeJsonExact(allocator, path, p, 0o600);
}

/// Front-insert `spec` into an owned-string list, deduping and
/// trimming to `cap`. The list owns its strings via `allocator`.
pub fn recordRecent(
    allocator: std.mem.Allocator,
    list: *std.ArrayList([]u8),
    spec: []const u8,
    cap: usize,
) void {
    var normalized_buf: [4300]u8 = undefined;
    const normalized = normalizeRecentSpec(spec, &normalized_buf);
    var i: usize = 0;
    while (i < list.items.len) {
        var existing_buf: [4300]u8 = undefined;
        const existing = normalizeRecentSpec(list.items[i], &existing_buf);
        if (std.mem.eql(u8, existing, normalized)) {
            allocator.free(list.items[i]);
            _ = list.orderedRemove(i);
        } else i += 1;
    }
    const owned = allocator.dupe(u8, normalized) catch return;
    list.insert(allocator, 0, owned) catch {
        allocator.free(owned);
        return;
    };
    while (list.items.len > cap) {
        const last = list.pop() orelse break;
        allocator.free(last);
    }
}

/// Canonicalize an old host-only recent to the explicit root form.
pub fn normalizeRecentSpec(spec: []const u8, buf: []u8) []const u8 {
    if (spec.len < 2 or spec[spec.len - 1] != ':') return spec;
    return std.fmt.bufPrint(buf, "{s}/", .{spec}) catch spec;
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
    try std.json.Stringify.value(Places{ .sidebar_px = 245, .sidebar_open = false, .zebra = true }, .{}, &out.writer);
    const parsed = try std.json.parseFromSlice(Places, t.allocator, out.written(), .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    try t.expectEqual(@as(i32, 245), parsed.value.sidebar_px);
    try t.expectEqual(@as(?bool, false), parsed.value.sidebar_open);
    try t.expectEqual(true, parsed.value.zebra);
}

test "places save replaces a complete file and loads the replacement" {
    const t = std.testing;
    var tmpl = "/tmp/sketerm-places-save-XXXXXX".*;
    const dir = c.mkdtemp(&tmpl) orelse return error.SkipZigTest;
    defer _ = c.rmdir(dir);
    const base = std.mem.span(@as([*:0]u8, @ptrCast(dir)));
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/places.json", .{base});
    var path_z_buf: [512:0]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_z_buf, "{s}", .{path});
    defer _ = c.unlink(path_z.ptr);

    try saveToPath(t.allocator, path, .{ .sidebar_px = 201 });
    try saveToPath(t.allocator, path, .{ .sidebar_px = 287, .zebra = true });
    const parsed = loadFromPath(t.allocator, path) orelse return error.TestUnexpectedResult;
    defer parsed.deinit();
    try t.expectEqual(@as(i32, 287), parsed.value.sidebar_px);
    try t.expect(parsed.value.zebra);
}

test "places serialization failure preserves the prior valid file" {
    const t = std.testing;
    var tmpl = "/tmp/sketerm-places-serialize-XXXXXX".*;
    const dir = c.mkdtemp(&tmpl) orelse return error.SkipZigTest;
    defer _ = c.rmdir(dir);
    const base = std.mem.span(@as([*:0]u8, @ptrCast(dir)));
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/places.json", .{base});
    var path_z_buf: [512:0]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_z_buf, "{s}", .{path});
    defer _ = c.unlink(path_z.ptr);

    try saveToPath(t.allocator, path, .{ .sidebar_px = 211 });
    var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    try t.expectError(error.WriteFailed, saveToPath(failing.allocator(), path, .{ .sidebar_px = 333 }));
    const parsed = loadFromPath(t.allocator, path) orelse return error.TestUnexpectedResult;
    defer parsed.deinit();
    try t.expectEqual(@as(i32, 211), parsed.value.sidebar_px);
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

test "orderSections: saved-first, leftovers in default order, stale keys dropped" {
    const t = std.testing;
    const all = [_][]const u8{ "local", "remote", "bookmarks", "widgets:Mine" };
    const saved = [_][]const u8{ "bookmarks", "gone", "local", "bookmarks" };
    const out = try orderSections(t.allocator, &saved, &all);
    defer t.allocator.free(out);
    try t.expectEqual(@as(usize, 4), out.len);
    try t.expectEqualStrings("bookmarks", out[0]);
    try t.expectEqualStrings("local", out[1]);
    try t.expectEqualStrings("remote", out[2]);
    try t.expectEqualStrings("widgets:Mine", out[3]);
}

test "widget sections and hidden sections round-trip; old files default empty" {
    const t = std.testing;
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    const w = [_]Widget{.{ .kind = "command", .text = "Load", .command = "uptime", .interval_secs = 30 }};
    const ws = [_]WidgetSection{.{ .name = "Mine", .widgets = &w }};
    try std.json.Stringify.value(Places{
        .hidden_sections = &.{"recent"},
        .section_order = &.{ "bookmarks", "local" },
        .widget_sections = &ws,
        .bookmark_labels = &.{"Projects"},
    }, .{}, &out.writer);
    const parsed = try std.json.parseFromSlice(Places, t.allocator, out.written(), .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    try t.expectEqualStrings("recent", parsed.value.hidden_sections[0]);
    try t.expectEqualStrings("bookmarks", parsed.value.section_order[0]);
    try t.expectEqualStrings("Mine", parsed.value.widget_sections[0].name);
    try t.expectEqualStrings("uptime", parsed.value.widget_sections[0].widgets[0].command);
    try t.expectEqual(@as(u32, 30), parsed.value.widget_sections[0].widgets[0].interval_secs);
    try t.expectEqualStrings("Projects", parsed.value.bookmark_labels[0]);

    const old = "{\"bookmarks\":[\"/x\"]}";
    const p2 = try std.json.parseFromSlice(Places, t.allocator, old, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer p2.deinit();
    try t.expectEqual(@as(usize, 0), p2.value.widget_sections.len);
    try t.expectEqual(@as(usize, 0), p2.value.hidden_sections.len);
    try t.expectEqual(@as(usize, 0), p2.value.bookmark_labels.len);
}

test "bookmark icons round-trip; old files default to no icons" {
    const t = std.testing;
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    try std.json.Stringify.value(Places{
        .bookmarks = &.{ "/music", "/pics" },
        .bookmark_icons = &.{ "folder-music-symbolic", "🎨" },
    }, .{}, &out.writer);
    const parsed = try std.json.parseFromSlice(Places, t.allocator, out.written(), .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    try t.expectEqual(@as(usize, 2), parsed.value.bookmark_icons.len);
    try t.expectEqualStrings("folder-music-symbolic", parsed.value.bookmark_icons[0]);
    try t.expectEqualStrings("🎨", parsed.value.bookmark_icons[1]);

    // A file written before icons existed: the list defaults empty and
    // the loader pads per-bookmark with "" (= default icon).
    const old = "{\"bookmarks\":[\"/x\",\"/y\"],\"bookmark_labels\":[\"X\"]}";
    const p2 = try std.json.parseFromSlice(Places, t.allocator, old, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer p2.deinit();
    try t.expectEqual(@as(usize, 0), p2.value.bookmark_icons.len);
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

test "host-only recents normalize to a remote root" {
    const t = std.testing;
    var list: std.ArrayList([]u8) = .empty;
    defer {
        for (list.items) |s| t.allocator.free(s);
        list.deinit(t.allocator);
    }
    recordRecent(t.allocator, &list, "archdev:", 3);
    try t.expectEqualStrings("archdev:/", list.items[0]);
    recordRecent(t.allocator, &list, "archdev:/", 3);
    try t.expectEqual(@as(usize, 1), list.items.len);
    try t.expectEqualStrings("archdev:/", list.items[0]);
}

/// One frecency record: how often and how recently a location spec
/// was visited.
pub const FrecEntry = struct {
    spec: []const u8 = "",
    count: u32 = 0,
    last_ms: i64 = 0,
};

/// Owned mirror of FrecEntry the view keeps.
pub const FrecOwned = struct { spec: []u8, count: u32, last_ms: i64 };

pub const FRECENCY_CAP = 200;

/// zoxide-style recency buckets: frequency weighted by how recently
/// the location was last visited.
pub fn frecencyScore(count: u32, last_ms: i64, now_ms: i64) u64 {
    const age: i64 = @max(0, now_ms -| last_ms);
    const n: u64 = count;
    if (age < 3_600_000) return n * 4000;
    if (age < 86_400_000) return n * 2000;
    if (age < 7 * 86_400_000) return n * 500;
    return n * 250;
}

/// Count a visit; over `cap` the lowest-scoring record makes room.
pub fn recordVisit(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(FrecOwned),
    spec: []const u8,
    now_ms: i64,
    cap: usize,
) void {
    if (spec.len == 0) return;
    for (list.items) |*e| {
        if (std.mem.eql(u8, e.spec, spec)) {
            e.count +|= 1;
            e.last_ms = now_ms;
            return;
        }
    }
    const owned = allocator.dupe(u8, spec) catch return;
    list.append(allocator, .{ .spec = owned, .count = 1, .last_ms = now_ms }) catch {
        allocator.free(owned);
        return;
    };
    if (list.items.len > cap) {
        var worst: usize = 0;
        var worst_score: u64 = std.math.maxInt(u64);
        for (list.items, 0..) |e, i| {
            const sc = frecencyScore(e.count, e.last_ms, now_ms);
            if (sc < worst_score) {
                worst_score = sc;
                worst = i;
            }
        }
        allocator.free(list.items[worst].spec);
        _ = list.orderedRemove(worst);
    }
}

/// Indices of entries whose spec contains `filter` (case-insensitive,
/// "" matches all), best score first. Returns the used prefix of
/// `out`.
pub fn frecencyRank(list: []const FrecOwned, filter: []const u8, now_ms: i64, out: []usize) []usize {
    var n: usize = 0;
    for (list, 0..) |e, i| {
        if (n >= out.len) break;
        if (filter.len > 0 and std.ascii.indexOfIgnoreCase(e.spec, filter) == null) continue;
        out[n] = i;
        n += 1;
    }
    const ranked = out[0..n];
    const Ctx = struct { list: []const FrecOwned, now: i64 };
    std.mem.sort(usize, ranked, Ctx{ .list = list, .now = now_ms }, struct {
        fn lt(ctx: Ctx, a: usize, b: usize) bool {
            return frecencyScore(ctx.list[a].count, ctx.list[a].last_ms, ctx.now) >
                frecencyScore(ctx.list[b].count, ctx.list[b].last_ms, ctx.now);
        }
    }.lt);
    return ranked;
}

test "recordVisit counts, caps by score, and frecencyRank orders" {
    const t = std.testing;
    var list: std.ArrayList(FrecOwned) = .empty;
    defer {
        for (list.items) |e| t.allocator.free(e.spec);
        list.deinit(t.allocator);
    }
    const now: i64 = 1_000_000_000_000;
    recordVisit(t.allocator, &list, "local:/rare", now - 8 * 86_400_000, 3);
    recordVisit(t.allocator, &list, "local:/often", now, 3);
    recordVisit(t.allocator, &list, "local:/often", now, 3);
    recordVisit(t.allocator, &list, "host:/mid", now - 2 * 3_600_000, 3);
    try t.expectEqual(@as(usize, 3), list.items.len);
    // Cap eviction drops the lowest score (the stale rare one).
    recordVisit(t.allocator, &list, "local:/new", now, 3);
    try t.expectEqual(@as(usize, 3), list.items.len);
    for (list.items) |e| try t.expect(!std.mem.eql(u8, e.spec, "local:/rare"));
    var idx: [8]usize = undefined;
    const ranked = frecencyRank(list.items, "", now, &idx);
    try t.expectEqualStrings("local:/often", list.items[ranked[0]].spec);
    // Substring filter, case-insensitive.
    const only = frecencyRank(list.items, "OFT", now, &idx);
    try t.expectEqual(@as(usize, 1), only.len);
}
