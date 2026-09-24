//! The daemon's tag index: which paths on this host carry which tags,
//! so "every tag in use" is one read instead of a walk of the disk.
//!
//! Tags themselves live in each file's `user.sketerm.tags` xattr
//! (`fsserve.TAGS_XATTR`) and travel with it; the index is only a
//! cache of where `tag_set` put them. It can go stale (a tagged file
//! moved or deleted behind our back, a tag set by another tool), so a
//! reader VERIFIES every line against the xattr it names and the file
//! rewrites itself without the lines that no longer hold. Search does
//! not depend on it: the `tag_find` job walks and reads the xattrs.
//!
//! Format: `$XDG_STATE_HOME/sketerm/tags.idx`, one `<tags>\t<path>\n`
//! line per tagged path (tags comma-separated; a path cannot hold NUL
//! but can hold a tab, so the path is everything after the FIRST tab).
//! libc only: compiled into `sketerm-mux`.

const std = @import("std");
const c = @import("../c.zig").c;
const xdg = @import("../util/xdg.zig");
const pathz = @import("../util/pathz.zig");

pub const FILE = "tags.idx";
/// Bound on the index file we are willing to read.
pub const MAX_BYTES: usize = 4 << 20;

/// Whether the comma-separated `tags` list names `tag`
/// (case-insensitive, surrounding blanks ignored).
pub fn hasTag(tags: []const u8, tag: []const u8) bool {
    var it = std.mem.splitScalar(u8, tags, ',');
    while (it.next()) |raw| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, raw, " \t"), tag)) return true;
    }
    return false;
}

/// `old` with `path`'s line replaced by `tags` (removed when empty).
pub fn update(allocator: std.mem.Allocator, old: []const u8, path: []const u8, tags: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var it = std.mem.splitScalar(u8, old, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        if (std.mem.eql(u8, line[tab + 1 ..], path)) continue;
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }
    const clean = std.mem.trim(u8, tags, " \t,");
    if (clean.len > 0 and std.mem.indexOfAny(u8, clean, "\t\n") == null and std.mem.indexOfScalar(u8, path, '\n') == null) {
        try out.appendSlice(allocator, clean);
        try out.append(allocator, '\t');
        try out.appendSlice(allocator, path);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

pub const TagCount = struct { name: []const u8, count: u32 };

/// Every tag named in `text` with how many paths carry it, sorted by
/// name. `current` answers a path's live tags (null = gone); lines
/// whose live tags differ are counted by their LIVE tags and reported
/// through `stale` so the caller can rewrite the file.
pub fn aggregate(
    arena: std.mem.Allocator,
    text: []const u8,
    ctx: anytype,
    comptime current: fn (@TypeOf(ctx), std.mem.Allocator, []const u8) ?[]const u8,
    stale: *bool,
) ![]TagCount {
    var map: std.StringArrayHashMapUnmanaged(u32) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse {
            stale.* = true;
            continue;
        };
        const recorded = line[0..tab];
        const live = current(ctx, arena, line[tab + 1 ..]) orelse {
            stale.* = true;
            continue;
        };
        if (!std.mem.eql(u8, live, recorded)) stale.* = true;
        var tags = std.mem.splitScalar(u8, live, ',');
        while (tags.next()) |raw| {
            const name = std.mem.trim(u8, raw, " \t");
            if (name.len == 0) continue;
            const gop = try map.getOrPut(arena, name);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
        }
    }
    const out = try arena.alloc(TagCount, map.count());
    for (map.keys(), map.values(), out) |k, v, *slot| slot.* = .{ .name = k, .count = v };
    std.mem.sort(TagCount, out, {}, struct {
        fn less(_: void, a: TagCount, b: TagCount) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.less);
    return out;
}

// -- file IO (daemon side) ------------------------------------------

fn readAll(allocator: std.mem.Allocator, path: [:0]const u8) ?[]u8 {
    const f = c.fopen(path.ptr, "rb") orelse return null;
    defer _ = c.fclose(f);
    var out: std.ArrayList(u8) = .empty;
    var buf: [16384]u8 = undefined;
    while (out.items.len < MAX_BYTES) {
        const n = c.fread(&buf, 1, buf.len, f);
        if (n == 0) break;
        out.appendSlice(allocator, buf[0..n]) catch {
            out.deinit(allocator);
            return null;
        };
    }
    return out.toOwnedSlice(allocator) catch null;
}

fn writeAll(allocator: std.mem.Allocator, path: [:0]const u8, bytes: []const u8) bool {
    pathz.makeParentDirs(path) catch return false;
    const tmp = std.fmt.allocPrintSentinel(allocator, "{s}.tmp{d}", .{ path, c.getpid() }, 0) catch return false;
    defer allocator.free(tmp);
    const f = c.fopen(tmp.ptr, "wb") orelse return false;
    const ok = c.fwrite(bytes.ptr, 1, bytes.len, f) == bytes.len;
    if (c.fclose(f) != 0 or !ok) {
        _ = c.unlink(tmp.ptr);
        return false;
    }
    if (c.rename(tmp.ptr, path.ptr) != 0) {
        _ = c.unlink(tmp.ptr);
        return false;
    }
    return true;
}

fn indexPath(allocator: std.mem.Allocator) ?[:0]u8 {
    const p = xdg.statePath(allocator, FILE) catch return null;
    defer allocator.free(p);
    return allocator.dupeZ(u8, p) catch null;
}

/// Record `tags` for `path` (after a successful tag_set). Best effort:
/// the xattr is the truth, the index only a cache.
pub fn record(allocator: std.mem.Allocator, path: []const u8, tags: []const u8) void {
    const ip = indexPath(allocator) orelse return;
    defer allocator.free(ip);
    const old = readAll(allocator, ip) orelse (allocator.alloc(u8, 0) catch return);
    defer allocator.free(old);
    const new = update(allocator, old, path, tags) catch return;
    defer allocator.free(new);
    _ = writeAll(allocator, ip, new);
}

/// Every indexed tag with its live count, verified against `current`;
/// a stale index is rewritten from the live answers.
pub fn list(
    arena: std.mem.Allocator,
    ctx: anytype,
    comptime current: fn (@TypeOf(ctx), std.mem.Allocator, []const u8) ?[]const u8,
) []TagCount {
    const ip = indexPath(arena) orelse return &.{};
    const text = readAll(arena, ip) orelse return &.{};
    var stale = false;
    const out = aggregate(arena, text, ctx, current, &stale) catch return &.{};
    if (stale) {
        var fixed: std.ArrayList(u8) = .empty;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
            const live = current(ctx, arena, line[tab + 1 ..]) orelse continue;
            if (live.len == 0) continue;
            fixed.print(arena, "{s}\t{s}\n", .{ live, line[tab + 1 ..] }) catch return out;
        }
        _ = writeAll(arena, ip, fixed.items);
    }
    return out;
}

const tst = std.testing;

test "update replaces one path's line and drops it when cleared" {
    const a = tst.allocator;
    const one = try update(a, "", "/d/a", "red,blue");
    defer a.free(one);
    try tst.expectEqualStrings("red,blue\t/d/a\n", one);
    const two = try update(a, one, "/d/b\tc", "red");
    defer a.free(two);
    const three = try update(a, two, "/d/a", " green ");
    defer a.free(three);
    try tst.expectEqualStrings("red\t/d/b\tc\ngreen\t/d/a\n", three);
    const four = try update(a, three, "/d/b\tc", "");
    defer a.free(four);
    try tst.expectEqualStrings("green\t/d/a\n", four);
}

test "aggregate counts live tags and flags stale lines" {
    var arena_state = std.heap.ArenaAllocator.init(tst.allocator);
    defer arena_state.deinit();
    const Live = struct {
        fn get(_: void, _: std.mem.Allocator, path: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, path, "/gone")) return null;
            if (std.mem.eql(u8, path, "/moved-tag")) return "blue";
            return "red,blue";
        }
    };
    var stale = false;
    const out = try aggregate(arena_state.allocator(), "red,blue\t/a\nred,blue\t/b\n", {}, Live.get, &stale);
    try tst.expect(!stale);
    try tst.expectEqual(@as(usize, 2), out.len);
    try tst.expectEqualStrings("blue", out[0].name);
    try tst.expectEqual(@as(u32, 2), out[1].count);
    stale = false;
    const out2 = try aggregate(arena_state.allocator(), "red\t/gone\nred\t/moved-tag\n", {}, Live.get, &stale);
    try tst.expect(stale);
    try tst.expectEqual(@as(usize, 1), out2.len);
    try tst.expectEqualStrings("blue", out2[0].name);
    try tst.expect(hasTag("a, Red ,b", "red"));
    try tst.expect(!hasTag("reddish", "red"));
}
