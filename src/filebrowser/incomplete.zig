//! Persistent log of interrupted cross-host copies.
//!
//! A copy that failed its retry budget (or was canceled) is
//! remembered here, so a later paste of the same source onto the same
//! destination can offer "Continue copy" instead of a bare
//! replace/merge dialog. Cleared when a matching copy completes.

const std = @import("std");
const c = @import("../c.zig").c;
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
    incomplete: []Entry = &.{},
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
    var pbuf: [4096]u8 = undefined;
    const path = filePath(allocator) catch return null;
    defer allocator.free(path);
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

fn save(allocator: std.mem.Allocator, f: File) void {
    const path = filePath(allocator) catch return;
    defer allocator.free(path);
    pathz.makeParentDirs(path) catch return;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    std.json.Stringify.value(f, .{}, &out.writer) catch return;
    var pbuf: [4096]u8 = undefined;
    const fp = c.fopen(pathz.pathZ(&pbuf, path) catch return, "wb") orelse return;
    defer _ = c.fclose(fp);
    _ = c.fwrite(out.written().ptr, 1, out.written().len, fp);
}

fn eql(e: Entry, src_host: []const u8, src: []const u8, dst_host: []const u8, dst: []const u8) bool {
    return std.mem.eql(u8, e.src_host, src_host) and std.mem.eql(u8, e.src, src) and
        std.mem.eql(u8, e.dst_host, dst_host) and std.mem.eql(u8, e.dst, dst);
}

/// Remember an interrupted copy (idempotent; newest kept).
pub fn record(allocator: std.mem.Allocator, src_host: []const u8, src: []const u8, dst_host: []const u8, dst: []const u8) void {
    var list: std.ArrayList(Entry) = .empty;
    defer list.deinit(allocator);
    const parsed = load(allocator);
    defer if (parsed) |p| p.deinit();
    if (parsed) |p| {
        for (p.value.incomplete) |e| {
            if (!eql(e, src_host, src, dst_host, dst))
                list.append(allocator, e) catch return;
        }
    }
    list.append(allocator, .{ .src_host = src_host, .src = src, .dst_host = dst_host, .dst = dst }) catch return;
    while (list.items.len > CAP) _ = list.orderedRemove(0);
    save(allocator, .{ .incomplete = list.items });
}

/// Forget every entry landing on `dst` (a completed or replaced copy).
pub fn clear(allocator: std.mem.Allocator, dst_host: []const u8, dst: []const u8) void {
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
        list.append(allocator, e) catch return;
    }
    if (dropped) save(allocator, .{ .incomplete = list.items });
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
    record(t.allocator, "gobelijn", "/a", "", "/b");
    try t.expect(match(t.allocator, "gobelijn", "/a", "", "/b"));
    try t.expect(!match(t.allocator, "gobelijn", "/a", "", "/c"));
    // Idempotent record does not grow the list.
    record(t.allocator, "gobelijn", "/a", "", "/b");
    clear(t.allocator, "", "/b");
    try t.expect(!match(t.allocator, "gobelijn", "/a", "", "/b"));
}
