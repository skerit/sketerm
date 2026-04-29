//! Layout — save/restore window topology + per-pane cwd/command.
//!
//! Schema v2: tabs each carry a Tree (pane | split), recursive.
//! v1 saves are still parseable (loader fallback below).

const std = @import("std");
const c = @import("c.zig").c;

pub const Orient = enum { horizontal, vertical };

pub const PaneSpec = struct {
    cwd: []const u8,
    command: []const []const u8,
    /// Optional per-pane font override — set when the user has
    /// changed the font size for this pane via Ctrl+= / Ctrl+-.
    font_size: ?u16 = null,
    /// Optional profile name to spawn this pane under. Empty = no
    /// profile (use global Config). Default keeps older JSON files
    /// parseable via `ignore_unknown_fields`.
    profile: []const u8 = "",
};

pub const SplitSpec = struct {
    orientation: Orient,
    ratio: f32,
    children: []const Tree, // length must be 2
};

pub const Tree = union(enum) {
    pane: PaneSpec,
    split: SplitSpec,
};

pub const TabSpec = struct {
    title: []const u8,
    tree: Tree,
    /// Whether the tab was pinned at save time. Defaults to false so
    /// older layout files still parse via `ignore_unknown_fields`.
    pinned: bool = false,
};

pub const Layout = struct {
    version: u32 = 2,
    tabs: []const TabSpec,
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

pub fn defaultSavePath(allocator: std.mem.Allocator) ![]u8 {
    if (std.posix.getenv("XDG_STATE_HOME")) |xs| {
        return std.fmt.allocPrint(allocator, "{s}/sketerm/last.json", .{xs});
    }
    if (std.posix.getenv("HOME")) |home| {
        return std.fmt.allocPrint(allocator, "{s}/.local/state/sketerm/last.json", .{home});
    }
    return std.fmt.allocPrint(allocator, "/tmp/sketerm-last.json", .{});
}

/// Path to the user-saved "default layout" — auto-loaded on every
/// startup when no --layout / --restore was passed. Distinct from
/// `defaultSavePath` (last.json), which is the auto-save-on-exit
/// snapshot used by --restore.
pub fn defaultLayoutPath(allocator: std.mem.Allocator) ![]u8 {
    if (std.posix.getenv("XDG_STATE_HOME")) |xs| {
        return std.fmt.allocPrint(allocator, "{s}/sketerm/default.json", .{xs});
    }
    if (std.posix.getenv("HOME")) |home| {
        return std.fmt.allocPrint(allocator, "{s}/.local/state/sketerm/default.json", .{home});
    }
    return std.fmt.allocPrint(allocator, "/tmp/sketerm-default.json", .{});
}

test "round trip with split tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const real_path = try tmp_dir.dir.realpathAlloc(a, ".");
    const file_path = try std.fmt.allocPrint(a, "{s}/lay.json", .{real_path});

    const cmd1 = [_][]const u8{ "bash", "-l" };
    const cmd2 = [_][]const u8{ "nvim", "." };
    const left = Tree{ .pane = .{ .cwd = "/tmp", .command = &cmd1 } };
    const right = Tree{ .pane = .{ .cwd = "/home", .command = &cmd2 } };
    const split_kids = [_]Tree{ left, right };
    const split_tab_tree = Tree{ .split = .{
        .orientation = .horizontal,
        .ratio = 0.5,
        .children = &split_kids,
    } };
    var tabs = [_]TabSpec{
        .{ .title = "split", .tree = split_tab_tree },
        .{ .title = "single", .tree = .{ .pane = .{ .cwd = "/var", .command = &cmd1 } } },
    };
    const layout = Layout{ .tabs = &tabs };
    try save(layout, file_path);

    const parsed = try load(a, file_path);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 2), parsed.value.version);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.tabs.len);
    try std.testing.expectEqualStrings("split", parsed.value.tabs[0].title);
    switch (parsed.value.tabs[0].tree) {
        .split => |s| {
            try std.testing.expectEqual(Orient.horizontal, s.orientation);
            try std.testing.expectEqual(@as(usize, 2), s.children.len);
        },
        else => try std.testing.expect(false),
    }
}
