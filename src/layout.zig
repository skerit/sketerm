//! Layout — save/restore window topology + per-pane cwd/command.
//!
//! Format: JSON for v1 simplicity; schema-versioned. Plan calls
//! for ZON post-v1; same fields just different encoding.

const std = @import("std");
const c = @import("c.zig").c;

pub const Layout = struct {
    version: u32 = 1,
    tabs: []TabSpec,
};

pub const TabSpec = struct {
    title: []const u8,
    cwd: []const u8,
    /// argv. argv[0] is the binary to exec.
    command: []const []const u8,
};

/// Read `/proc/<pid>/cwd` symlink target.
pub fn cwdOfPid(pid: c.pid_t, allocator: std.mem.Allocator) ![]u8 {
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/proc/{d}/cwd", .{pid});
    var read_buf: [4096]u8 = undefined;
    const target = try std.posix.readlink(path, &read_buf);
    return try allocator.dupe(u8, target);
}

pub fn save(layout: Layout, path: []const u8) !void {
    var dir = try ensureParentDir(path);
    defer dir.close();
    const basename = std.fs.path.basename(path);

    // Write to .tmp + rename for atomicity.
    var tmp_buf: [256]u8 = undefined;
    const tmp_name = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{basename});
    var tmp = try dir.createFile(tmp_name, .{ .truncate = true });
    defer tmp.close();

    var write_buf: [4096]u8 = undefined;
    var w = tmp.writer(&write_buf);
    try std.json.Stringify.value(layout, .{ .whitespace = .indent_2 }, &w.interface);
    try w.interface.flush();

    try dir.rename(tmp_name, basename);
}

pub fn load(allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(Layout) {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const bytes = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(bytes);
    return try std.json.parseFromSlice(Layout, allocator, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

fn ensureParentDir(path: []const u8) !std.fs.Dir {
    const dirname = std.fs.path.dirname(path) orelse ".";
    return std.fs.cwd().makeOpenPath(dirname, .{});
}

/// Default save destination: $XDG_STATE_HOME/sketerm/last.json
/// or $HOME/.local/state/sketerm/last.json fallback.
pub fn defaultSavePath(allocator: std.mem.Allocator) ![]u8 {
    if (std.posix.getenv("XDG_STATE_HOME")) |xs| {
        return std.fmt.allocPrint(allocator, "{s}/sketerm/last.json", .{xs});
    }
    if (std.posix.getenv("HOME")) |home| {
        return std.fmt.allocPrint(allocator, "{s}/.local/state/sketerm/last.json", .{home});
    }
    return std.fmt.allocPrint(allocator, "/tmp/sketerm-last.json", .{});
}

test "round trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const real_path = try tmp_dir.dir.realpathAlloc(a, ".");
    const file_path = try std.fmt.allocPrint(a, "{s}/lay.json", .{real_path});

    const cmd1 = [_][]const u8{ "bash", "-l" };
    const cmd2 = [_][]const u8{ "nvim", "." };
    var tabs = [_]TabSpec{
        .{ .title = "shell", .cwd = "/tmp", .command = &cmd1 },
        .{ .title = "edit", .cwd = "/home", .command = &cmd2 },
    };
    const layout = Layout{ .tabs = &tabs };
    try save(layout, file_path);

    const parsed = try load(a, file_path);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 1), parsed.value.version);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.tabs.len);
    try std.testing.expectEqualStrings("shell", parsed.value.tabs[0].title);
    try std.testing.expectEqualStrings("/tmp", parsed.value.tabs[0].cwd);
    try std.testing.expectEqualStrings("nvim", parsed.value.tabs[1].command[0]);
}
