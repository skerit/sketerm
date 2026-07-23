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
    /// Explicit per-pane shader pick (path). Empty = none saved
    /// (profile/global resolution applies on restore).
    custom_shader: []const u8 = "",
    /// Shader preset bound to the pane (shader_preset.zig). Restore
    /// re-resolves it by name; the custom_shader path above is the
    /// fallback when the preset file has since been deleted.
    shader_preset: []const u8 = "",
    /// User explicitly cleared this pane's shader (sticky "off").
    /// Persisted so the clear survives a restart, mirroring how an
    /// explicit pick does.
    shader_cleared: bool = false,
    /// Durable mux pane: session name on the daemon. Empty = a
    /// plain local PTY pane. On restore the session is attached if
    /// it still exists, or recreated under the same name.
    mux_session: []const u8 = "",
    /// Transport-prefixed host for mux panes ("" = local daemon,
    /// "user@box" = ssh, "udp:box" = mosh-style UDP).
    mux_host: []const u8 = "",
    /// File-browser face: paths of the browser's internal tabs (in
    /// order). Empty = the pane has no browser. Restore reattaches
    /// the browser with the same tabs; older files parse via
    /// ignore_unknown_fields.
    browser_tabs: []const []const u8 = &.{},
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
    /// Tab colour swatch as "#RRGGBB"; null = none.
    color: ?[]const u8 = null,
    /// Whether the user explicitly renamed the tab (OSC titles must
    /// not overwrite it after restore). null = the file predates the
    /// field; restore treats those titles as renamed, matching the
    /// old behaviour where restored titles never followed OSC.
    title_locked: ?bool = null,
    /// Per-tab "show activity glow" toggle. Defaults true (the new-tab
    /// default) so older layout files restore with the glow on.
    show_activity: bool = true,
    /// Per-tab "warn when inactive" toggle. Defaults false.
    warn_inactive: bool = false,
};

pub const Layout = struct {
    version: u32 = 2,
    tabs: []const TabSpec,
};

/// macOS: query a process's vnode paths (cwd + root) via libproc.
/// Layout of struct proc_vnodepathinfo: two vnode_info_path entries,
/// each { struct vnode_info (152 bytes), char vip_path[MAXPATHLEN] }
/// — pvi_cdir.vip_path therefore sits at offset 152. VERIFIED on
/// hardware (arm64, macOS 26.4 SDK): sizeof(vnode_info)=152,
/// offsetof(vip_path)=152, flavor 9, live call matches getcwd().
extern fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: ?*anyopaque, buffersize: c_int) c_int;

/// Working directory of a live process. Linux: /proc/<pid>/cwd
/// symlink. macOS: proc_pidinfo(PROC_PIDVNODEPATHINFO).
pub fn cwdOfPid(pid: c.pid_t, allocator: std.mem.Allocator) ![]u8 {
    if (@import("util/platform.zig").is_macos) {
        const VNODE_INFO_SIZE = 152;
        const MAXPATHLEN = 1024;
        const PROC_PIDVNODEPATHINFO: c_int = 9;
        var buf: [2 * (VNODE_INFO_SIZE + MAXPATHLEN)]u8 align(8) = undefined;
        const n = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &buf, buf.len);
        if (n <= VNODE_INFO_SIZE) return error.ReadlinkFailed;
        const path_bytes = buf[VNODE_INFO_SIZE .. VNODE_INFO_SIZE + MAXPATHLEN];
        const len = std.mem.indexOfScalar(u8, path_bytes, 0) orelse MAXPATHLEN;
        if (len == 0) return error.ReadlinkFailed;
        return try allocator.dupe(u8, path_bytes[0..len]);
    }
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/proc/{d}/cwd", .{pid});
    var path_z: [128]u8 = undefined;
    if (path.len >= path_z.len) return error.PathTooLong;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;
    var read_buf: [4096]u8 = undefined;
    const n = c.readlink(@ptrCast(&path_z), &read_buf, read_buf.len);
    if (n < 0) return error.ReadlinkFailed;
    return try allocator.dupe(u8, read_buf[0..@intCast(n)]);
}

pub fn save(layout: Layout, path: []const u8) !void {
    try makeParentDirs(path);

    var path_z: [4096]u8 = undefined;
    if (path.len + 4 >= path_z.len) return error.PathTooLong;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    var tmp_z: [4096]u8 = undefined;
    @memcpy(tmp_z[0..path.len], path);
    @memcpy(tmp_z[path.len .. path.len + 4], ".tmp");
    tmp_z[path.len + 4] = 0;

    const fp = c.fopen(@ptrCast(&tmp_z), "wb") orelse return error.WriteFailed;
    var write_buf: [16384]u8 = undefined;
    var w = std.Io.Writer.fixed(&write_buf);
    std.json.Stringify.value(layout, .{ .whitespace = .indent_2 }, &w) catch |err| {
        _ = c.fclose(fp);
        return err;
    };
    const bytes = w.buffered();
    if (c.fwrite(bytes.ptr, 1, bytes.len, fp) != bytes.len) {
        _ = c.fclose(fp);
        return error.WriteFailed;
    }
    if (c.fclose(fp) != 0) return error.WriteFailed;
    if (c.rename(@ptrCast(&tmp_z), @ptrCast(&path_z)) != 0) {
        _ = c.unlink(@ptrCast(&tmp_z));
        return error.WriteFailed;
    }
}

pub fn load(allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(Layout) {
    var path_z: [4096]u8 = undefined;
    const fp = c.fopen(try pathZ(&path_z, path), "rb") orelse return error.OpenFailed;
    defer _ = c.fclose(fp);
    if (c.fseek(fp, 0, c.SEEK_END) != 0) return error.ReadFailed;
    const size_long = c.ftell(fp);
    if (size_long <= 0 or size_long > 1024 * 1024) return error.BadFile;
    if (c.fseek(fp, 0, c.SEEK_SET) != 0) return error.ReadFailed;
    const size: usize = @intCast(size_long);
    const bytes = try allocator.alloc(u8, size);
    defer allocator.free(bytes);
    if (c.fread(bytes.ptr, 1, size, fp) != size) return error.ShortRead;
    return try std.json.parseFromSlice(Layout, allocator, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

const pathz_util = @import("util/pathz.zig");
const makeParentDirs = pathz_util.makeParentDirs;
const pathZ = pathz_util.pathZ;

pub fn defaultSavePath(allocator: std.mem.Allocator) ![]u8 {
    if (@import("util/profile.zig").getenv("XDG_STATE_HOME")) |xs| {
        return std.fmt.allocPrint(allocator, "{s}/sketerm/last.json", .{xs});
    }
    if (@import("util/profile.zig").getenv("HOME")) |home| {
        return std.fmt.allocPrint(allocator, "{s}/.local/state/sketerm/last.json", .{home});
    }
    return std.fmt.allocPrint(allocator, "/tmp/sketerm-last.json", .{});
}

/// Path to the user-saved "default layout" — auto-loaded on every
/// startup when no --layout / --restore was passed. Distinct from
/// `defaultSavePath` (last.json), which is the auto-save-on-exit
/// snapshot used by --restore.
pub fn defaultLayoutPath(allocator: std.mem.Allocator) ![]u8 {
    if (@import("util/profile.zig").getenv("XDG_STATE_HOME")) |xs| {
        return std.fmt.allocPrint(allocator, "{s}/sketerm/default.json", .{xs});
    }
    if (@import("util/profile.zig").getenv("HOME")) |home| {
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

    const real_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&tmp_dir.sub_path});
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

test "round trip preserves PaneSpec.profile" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const real_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&tmp_dir.sub_path});
    const file_path = try std.fmt.allocPrint(a, "{s}/profile.json", .{real_path});

    const cmd = [_][]const u8{ "bash", "-l" };
    var tabs = [_]TabSpec{
        .{ .title = "dev", .tree = .{ .pane = .{
            .cwd = "/tmp",
            .command = &cmd,
            .profile = "ssh-prod",
        } } },
    };
    try save(.{ .tabs = &tabs }, file_path);

    const parsed = try load(a, file_path);
    defer parsed.deinit();
    switch (parsed.value.tabs[0].tree) {
        .pane => |p| try std.testing.expectEqualStrings("ssh-prod", p.profile),
        else => try std.testing.expect(false),
    }
}

test "round trip preserves TabSpec.pinned" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const real_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&tmp_dir.sub_path});
    const file_path = try std.fmt.allocPrint(a, "{s}/pinned.json", .{real_path});

    const cmd = [_][]const u8{"bash"};
    var tabs = [_]TabSpec{
        .{ .title = "pinned-tab", .tree = .{ .pane = .{
            .cwd = "/",
            .command = &cmd,
        } }, .pinned = true, .title_locked = false },
        .{ .title = "regular", .tree = .{ .pane = .{
            .cwd = "/",
            .command = &cmd,
        } } }, // pinned defaults to false
    };
    try save(.{ .tabs = &tabs }, file_path);

    const parsed = try load(a, file_path);
    defer parsed.deinit();
    try std.testing.expectEqual(true, parsed.value.tabs[0].pinned);
    try std.testing.expectEqual(false, parsed.value.tabs[1].pinned);
    try std.testing.expectEqual(@as(?bool, false), parsed.value.tabs[0].title_locked);
}

test "round trip preserves per-tab effect toggles, defaults on old files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const real_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&tmp_dir.sub_path});
    const file_path = try std.fmt.allocPrint(a, "{s}/fx.json", .{real_path});

    const cmd = [_][]const u8{"bash"};
    var tabs = [_]TabSpec{
        // Non-default: glow off, warning on.
        .{ .title = "watched", .tree = .{ .pane = .{ .cwd = "/", .command = &cmd } }, .show_activity = false, .warn_inactive = true },
        // Defaults.
        .{ .title = "plain", .tree = .{ .pane = .{ .cwd = "/", .command = &cmd } } },
    };
    try save(.{ .tabs = &tabs }, file_path);

    const parsed = try load(a, file_path);
    defer parsed.deinit();
    try std.testing.expectEqual(false, parsed.value.tabs[0].show_activity);
    try std.testing.expectEqual(true, parsed.value.tabs[0].warn_inactive);
    // A tab saved with defaults — and any older file lacking the fields —
    // restores with the glow on and the warning off.
    try std.testing.expectEqual(true, parsed.value.tabs[1].show_activity);
    try std.testing.expectEqual(false, parsed.value.tabs[1].warn_inactive);
}

test "load tolerates older JSON without profile / pinned fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const real_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&tmp_dir.sub_path});
    const file_path = try std.fmt.allocPrint(a, "{s}/old.json", .{real_path});

    // Hand-write a minimal v2 layout missing the new fields. Should
    // still parse via ignore_unknown_fields semantics (strictly a
    // missing-fields case here, the defaults fill in).
    const old_json =
        \\{ "version": 2, "tabs": [
        \\  { "title": "t",
        \\    "tree": { "pane": { "cwd": "/", "command": ["sh"] } } }
        \\] }
    ;
    // Write the hand-crafted JSON via libc — Zig 0.16's std.fs APIs
    // require an Io we don't have here.
    var fp_z: [4096]u8 = undefined;
    if (file_path.len >= fp_z.len) return error.PathTooLong;
    @memcpy(fp_z[0..file_path.len], file_path);
    fp_z[file_path.len] = 0;
    const fp = c.fopen(@ptrCast(&fp_z), "wb") orelse return error.WriteFailed;
    _ = c.fwrite(old_json.ptr, 1, old_json.len, fp);
    _ = c.fclose(fp);

    const parsed = try load(a, file_path);
    defer parsed.deinit();
    try std.testing.expectEqual(false, parsed.value.tabs[0].pinned);
    // Pre-title_locked file: null means "treat as renamed" on restore.
    try std.testing.expectEqual(@as(?bool, null), parsed.value.tabs[0].title_locked);
    switch (parsed.value.tabs[0].tree) {
        .pane => |p| try std.testing.expectEqualStrings("", p.profile),
        else => try std.testing.expect(false),
    }
}
