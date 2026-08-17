//! Persistent log of interrupted cross-host copies.
//!
//! A copy that failed its retry budget (or was canceled) is
//! remembered here, so a later paste of the same source onto the same
//! destination can offer "Continue copy" instead of a bare
//! replace/merge dialog. Cleared when a matching copy completes.

const std = @import("std");
const c = @import("../c.zig").c;
const atomicwrite = @import("../util/atomicwrite.zig");
const pathz = @import("../util/pathz.zig");
const profile = @import("../util/profile.zig");

/// Bounded: drop-oldest past this. Interrupted copies are rare.
const CAP = 64;

pub const Entry = struct {
    src_host: []const u8 = "",
    src: []const u8 = "",
    dst_host: []const u8 = "",
    dst: []const u8 = "",
};

const File = struct {
    incomplete: []const Entry = &.{},
};

pub fn filePath(allocator: std.mem.Allocator) ![]u8 {
    if (profile.getenv("XDG_STATE_HOME")) |xs| {
        return std.fmt.allocPrint(allocator, "{s}/sketerm/incomplete-copies.json", .{xs});
    }
    if (profile.getenv("HOME")) |home| {
        return std.fmt.allocPrint(allocator, "{s}/.local/state/sketerm/incomplete-copies.json", .{home});
    }
    return std.fmt.allocPrint(allocator, "/tmp/sketerm-incomplete-copies.json", .{});
}

fn load(allocator: std.mem.Allocator) ?std.json.Parsed(File) {
    const path = filePath(allocator) catch return null;
    defer allocator.free(path);
    return loadFromPath(allocator, path);
}

fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) ?std.json.Parsed(File) {
    var pbuf: [4096]u8 = undefined;
    const fp = c.fopen(pathz.pathZ(&pbuf, path) catch return null, "rb") orelse return null;
    defer _ = c.fclose(fp);
    var bytes: [256 * 1024]u8 = undefined;
    const n = c.fread(&bytes, 1, bytes.len, fp);
    if (n == 0) return null;
    return std.json.parseFromSlice(File, allocator, bytes[0..n], .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch null;
}

fn save(allocator: std.mem.Allocator, f: File) !void {
    const path = try filePath(allocator);
    defer allocator.free(path);
    try saveToPath(allocator, path, f);
}

/// The app owns this file, so its mode is FORCED: a copy an older build
/// created 0644 must be narrowed, not preserved forever.
fn saveToPath(allocator: std.mem.Allocator, path: []const u8, f: File) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(f, .{}, &out.writer);
    try pathz.makeParentDirs(path);
    try atomicwrite.writeFileExact(path, out.written(), 0o600);
}

fn eql(e: Entry, src_host: []const u8, src: []const u8, dst_host: []const u8, dst: []const u8) bool {
    return std.mem.eql(u8, e.src_host, src_host) and std.mem.eql(u8, e.src, src) and
        std.mem.eql(u8, e.dst_host, dst_host) and std.mem.eql(u8, e.dst, dst);
}

/// Remember an interrupted copy (idempotent; newest kept).
pub fn record(allocator: std.mem.Allocator, src_host: []const u8, src: []const u8, dst_host: []const u8, dst: []const u8) !void {
    var list: std.ArrayList(Entry) = .empty;
    defer list.deinit(allocator);
    const parsed = load(allocator);
    defer if (parsed) |p| p.deinit();
    if (parsed) |p| {
        for (p.value.incomplete) |e| {
            if (!eql(e, src_host, src, dst_host, dst))
                try list.append(allocator, e);
        }
    }
    try list.append(allocator, .{ .src_host = src_host, .src = src, .dst_host = dst_host, .dst = dst });
    while (list.items.len > CAP) _ = list.orderedRemove(0);
    try save(allocator, .{ .incomplete = list.items });
}

/// Forget every entry landing on `dst` (a completed or replaced copy).
pub fn clear(allocator: std.mem.Allocator, dst_host: []const u8, dst: []const u8) !void {
    const parsed = load(allocator) orelse return;
    defer parsed.deinit();
    var list: std.ArrayList(Entry) = .empty;
    defer list.deinit(allocator);
    var dropped = false;
    for (parsed.value.incomplete) |e| {
        if (std.mem.eql(u8, e.dst_host, dst_host) and std.mem.eql(u8, e.dst, dst)) {
            dropped = true;
            continue;
        }
        try list.append(allocator, e);
    }
    if (dropped) try save(allocator, .{ .incomplete = list.items });
}

/// Is this exact src -> dst pair a known interrupted copy?
pub fn match(allocator: std.mem.Allocator, src_host: []const u8, src: []const u8, dst_host: []const u8, dst: []const u8) bool {
    const parsed = load(allocator) orelse return false;
    defer parsed.deinit();
    for (parsed.value.incomplete) |e| {
        if (eql(e, src_host, src, dst_host, dst)) return true;
    }
    return false;
}

test "incomplete-copy save replaces and loads the complete list" {
    const t = std.testing;
    var tmpl = "/tmp/sketerm-incomplete-save-XXXXXX".*;
    const dir = c.mkdtemp(&tmpl) orelse return error.SkipZigTest;
    defer _ = c.rmdir(dir);
    const base = std.mem.span(@as([*:0]u8, @ptrCast(dir)));
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/incomplete.json", .{base});
    var path_z_buf: [512:0]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_z_buf, "{s}", .{path});
    defer _ = c.unlink(path_z.ptr);

    const first = [_]Entry{.{ .src = "/one", .dst = "/target" }};
    try saveToPath(t.allocator, path, .{ .incomplete = &first });
    const second = [_]Entry{
        .{ .src = "/one", .dst = "/target" },
        .{ .src_host = "box", .src = "/two", .dst = "/other" },
    };
    try saveToPath(t.allocator, path, .{ .incomplete = &second });

    // The app owns this file, so a copy an older build left world-readable
    // must be narrowed on the next save, not preserved forever.
    try t.expect(c.chmod(path_z.ptr, @as(c.mode_t, 0o644)) == 0);
    try saveToPath(t.allocator, path, .{ .incomplete = &second });
    var st: c.struct_stat = undefined;
    try t.expect(c.stat(path_z.ptr, &st) == 0);
    try t.expectEqual(@as(c_uint, 0o600), @as(c_uint, @intCast(st.st_mode & 0o777)));

    const loaded = loadFromPath(t.allocator, path) orelse return error.TestUnexpectedResult;
    defer loaded.deinit();
    try t.expectEqual(@as(usize, 2), loaded.value.incomplete.len);
    try t.expectEqualStrings("box", loaded.value.incomplete[1].src_host);
    try t.expectEqualStrings("/other", loaded.value.incomplete[1].dst);
}

test "incomplete: record, match, clear round-trip" {
    const t = std.testing;
    var tmp_buf: [128]u8 = undefined;
    const dir = std.fmt.bufPrintZ(&tmp_buf, "/tmp/sk-incomplete-{d}", .{c.getpid()}) catch unreachable;
    _ = c.mkdir(dir.ptr, 0o700);
    defer {
        var rm_buf: [160]u8 = undefined;
        const f = std.fmt.bufPrintZ(&rm_buf, "{s}/sketerm/incomplete-copies.json", .{dir}) catch unreachable;
        _ = c.unlink(f.ptr);
        const d = std.fmt.bufPrintZ(&rm_buf, "{s}/sketerm", .{dir}) catch unreachable;
        _ = c.rmdir(d.ptr);
        _ = c.rmdir(dir.ptr);
    }
    const old = profile.getenv("XDG_STATE_HOME");
    _ = c.setenv("XDG_STATE_HOME", dir.ptr, 1);
    defer if (old) |o| {
        var ob: [4096:0]u8 = undefined;
        if (std.fmt.bufPrintZ(&ob, "{s}", .{o})) |z| {
            _ = c.setenv("XDG_STATE_HOME", z.ptr, 1);
        } else |_| {}
    } else {
        _ = c.unsetenv("XDG_STATE_HOME");
    };

    try t.expect(!match(t.allocator, "gobelijn", "/a", "", "/b"));
    try record(t.allocator, "gobelijn", "/a", "", "/b");
    try t.expect(match(t.allocator, "gobelijn", "/a", "", "/b"));
    try t.expect(!match(t.allocator, "gobelijn", "/a", "", "/c"));
    // Idempotent record does not grow the list.
    try record(t.allocator, "gobelijn", "/a", "", "/b");
    try clear(t.allocator, "", "/b");
    try t.expect(!match(t.allocator, "gobelijn", "/a", "", "/b"));
}
