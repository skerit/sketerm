//! Layout — save/restore window topology + per-pane cwd/command.
//!
//! Schema v2: tabs each carry a Tree (pane | split), recursive.
//! v1 saves are still parseable (loader fallback below).

const std = @import("std");
const c = @import("c.zig").c;
const browser_model = @import("filebrowser/model.zig");
const editor_model = @import("editor/model.zig");
const web_model = @import("web/model.zig");
const atomicwrite = @import("util/atomicwrite.zig");

/// Ceiling for a serialized layout, both on save and on load. It is
/// deliberately far above any plausible session: at 1MB a big session
/// (many tabs, long titles, browser/editor state per pane) could reach
/// it, and the shutdown auto-save (`winlayout.saveLayoutQuietly`) then
/// dropped the user's whole session with one stderr line. The refusal
/// past this point stays — the serialize is in-memory, so a runaway is
/// cheap to refuse and expensive to write. Note `atomicwrite` reserves
/// this many bytes up front for the bounded serialize.
pub const MAX_FILE_BYTES: usize = 16 * 1024 * 1024;

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
    /// Transport host for mux panes ("" = local, bare = automatic,
    /// "udp:"/"ssh:" = forced transport).
    mux_host: []const u8 = "",
    /// File-browser face: paths of the browser's internal tabs (in
    /// order). Empty = the pane has no browser. Restore reattaches
    /// the browser with the same tabs; older files parse via
    /// ignore_unknown_fields.
    browser_tabs: []const []const u8 = &.{},
    /// Versioned full browser state. `browser_tabs` remains as the
    /// compatibility reader for layouts written by the first prototype.
    browser: ?browser_model.PaneState = null,
    /// Text-editor face: open file specs + active index + cursors.
    /// Dirty (unsaved) buffers are NOT persisted — see editor/model.zig.
    editor: ?editor_model.PaneState = null,
    /// Web (browser) face: address + page zoom. Null = the pane wears
    /// no web face; older layout files parse into that.
    web: ?web_model.PaneState = null,
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
    /// Tree-style tabs: index (into this layout's `tabs` array) of the
    /// tab this one nests under. null = a root tab — and every tab of
    /// an older layout file, which therefore restores flat.
    tree_parent: ?u32 = null,
    /// Tree-style tabs: whether this tab's subtree was collapsed.
    collapsed: bool = false,
};

pub const Layout = struct {
    version: u32 = 2,
    tabs: []const TabSpec,
};

// NOTE: a `cwdOfPid` used to live here as well as in the daemon, and the
// two drifted — the daemon's copy never grew a macOS branch, which broke
// every file transfer there. There is now exactly one, in
// `util/platform.zig`. Do not reintroduce a local variant.

pub fn save(allocator: std.mem.Allocator, layout: Layout, path: []const u8) !void {
    try makeParentDirs(path);
    try atomicwrite.writeSerialized(
        allocator,
        path,
        MAX_FILE_BYTES,
        0o600,
        layout,
        serialiseForSave,
    );
}

fn serialiseForSave(layout: Layout, w: *std.Io.Writer) !void {
    try std.json.Stringify.value(layout, .{ .whitespace = .indent_2 }, w);
}

pub fn load(allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(Layout) {
    var path_z: [4096]u8 = undefined;
    const fp = c.fopen(try pathZ(&path_z, path), "rb") orelse return error.OpenFailed;
    defer _ = c.fclose(fp);
    if (c.fseek(fp, 0, c.SEEK_END) != 0) return error.ReadFailed;
    const size_long = c.ftell(fp);
    if (size_long <= 0 or size_long > MAX_FILE_BYTES) return error.BadFile;
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

test "round trip preserves editor pane state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const real_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&tmp_dir.sub_path});
    const file_path = try std.fmt.allocPrint(a, "{s}/editor.json", .{real_path});

    const cmd = [_][]const u8{"sh"};
    const files = [_]editor_model.FileState{
        .{ .spec = "/tmp/a.txt", .cursor = 7 },
        .{ .spec = "box:/etc/hosts", .cursor = 0 },
    };
    var tabs = [_]TabSpec{.{ .title = "ed", .tree = .{ .pane = .{
        .cwd = "/",
        .command = &cmd,
        .editor = .{ .files = &files, .active = 1 },
    } } }};
    try save(a, Layout{ .tabs = &tabs }, file_path);
    const parsed = try load(a, file_path);
    defer parsed.deinit();
    const state = parsed.value.tabs[0].tree.pane.editor.?;
    try std.testing.expectEqual(@as(u64, 1), state.active);
    try std.testing.expectEqual(@as(usize, 2), state.files.len);
    try std.testing.expectEqualStrings("box:/etc/hosts", state.files[1].spec);
    try std.testing.expectEqual(@as(u64, 7), state.files[0].cursor);
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
    try save(a, layout, file_path);

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
    try save(a, .{ .tabs = &tabs }, file_path);

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
    try save(a, .{ .tabs = &tabs }, file_path);

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
    try save(a, .{ .tabs = &tabs }, file_path);

    const parsed = try load(a, file_path);
    defer parsed.deinit();
    try std.testing.expectEqual(false, parsed.value.tabs[0].show_activity);
    try std.testing.expectEqual(true, parsed.value.tabs[0].warn_inactive);
    // A tab saved with defaults — and any older file lacking the fields —
    // restores with the glow on and the warning off.
    try std.testing.expectEqual(true, parsed.value.tabs[1].show_activity);
    try std.testing.expectEqual(false, parsed.value.tabs[1].warn_inactive);
}

test "round trip preserves tab-tree nesting; old files load flat" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const real_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&tmp_dir.sub_path});
    const file_path = try std.fmt.allocPrint(a, "{s}/tree.json", .{real_path});

    const cmd = [_][]const u8{"sh"};
    var tabs = [_]TabSpec{
        .{ .title = "parent", .tree = .{ .pane = .{ .cwd = "/", .command = &cmd } }, .collapsed = true },
        .{ .title = "child", .tree = .{ .pane = .{ .cwd = "/", .command = &cmd } }, .tree_parent = 0 },
        .{ .title = "root2", .tree = .{ .pane = .{ .cwd = "/", .command = &cmd } } },
    };
    try save(a, .{ .tabs = &tabs }, file_path);

    const parsed = try load(a, file_path);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(?u32, null), parsed.value.tabs[0].tree_parent);
    try std.testing.expectEqual(true, parsed.value.tabs[0].collapsed);
    try std.testing.expectEqual(@as(?u32, 0), parsed.value.tabs[1].tree_parent);
    try std.testing.expectEqual(false, parsed.value.tabs[1].collapsed);
    try std.testing.expectEqual(@as(?u32, null), parsed.value.tabs[2].tree_parent);

    // A pre-tree file (no fields at all) loads flat.
    const old_json =
        \\{ "version": 2, "tabs": [
        \\  { "title": "t",
        \\    "tree": { "pane": { "cwd": "/", "command": ["sh"] } } }
        \\] }
    ;
    const old_path = try std.fmt.allocPrint(a, "{s}/oldtree.json", .{real_path});
    var fp_z: [4096]u8 = undefined;
    if (old_path.len >= fp_z.len) return error.PathTooLong;
    @memcpy(fp_z[0..old_path.len], old_path);
    fp_z[old_path.len] = 0;
    const fp = c.fopen(@ptrCast(&fp_z), "wb") orelse return error.WriteFailed;
    _ = c.fwrite(old_json.ptr, 1, old_json.len, fp);
    _ = c.fclose(fp);
    const old_parsed = try load(a, old_path);
    defer old_parsed.deinit();
    try std.testing.expectEqual(@as(?u32, null), old_parsed.value.tabs[0].tree_parent);
    try std.testing.expectEqual(false, old_parsed.value.tabs[0].collapsed);
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

test "round trip preserves web pane state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const real_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&tmp_dir.sub_path});
    const file_path = try std.fmt.allocPrint(a, "{s}/web.json", .{real_path});

    const cmd = [_][]const u8{"sh"};
    const kids = [_]Tree{
        .{ .pane = .{ .cwd = "/", .command = &cmd, .web = .{
            .url = "https://example.com/docs",
            .zoom_level_x100 = 200,
        } } },
        // A blank web tab: face present, no address yet.
        .{ .pane = .{ .cwd = "/", .command = &cmd, .web = .{} } },
    };
    const tabs = [_]TabSpec{.{ .title = "web", .tree = .{ .split = .{
        .orientation = .vertical,
        .ratio = 0.5,
        .children = &kids,
    } } }};
    try save(a, .{ .tabs = &tabs }, file_path);

    const parsed = try load(a, file_path);
    defer parsed.deinit();
    const restored = parsed.value.tabs[0].tree.split.children;
    const left = restored[0].pane.web.?;
    try std.testing.expectEqualStrings("https://example.com/docs", left.url);
    try std.testing.expectEqual(@as(i16, 200), left.zoom_level_x100);
    const right = restored[1].pane.web.?;
    try std.testing.expectEqualStrings("", right.url);
    try std.testing.expectEqual(@as(i16, 0), right.zoom_level_x100);
}

test "load tolerates a layout written before the web field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const real_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&tmp_dir.sub_path});
    const file_path = try std.fmt.allocPrint(a, "{s}/preweb.json", .{real_path});

    // No "web" key at all, and a "zoom" key the schema never had —
    // an old file must load, and an unknown field must not fail it.
    const old_json =
        \\{ "version": 2, "tabs": [
        \\  { "title": "t", "tree": { "pane": {
        \\      "cwd": "/", "command": ["sh"], "zoom": 3 } } }
        \\] }
    ;
    var fp_z: [4096]u8 = undefined;
    if (file_path.len >= fp_z.len) return error.PathTooLong;
    @memcpy(fp_z[0..file_path.len], file_path);
    fp_z[file_path.len] = 0;
    const fp = c.fopen(@ptrCast(&fp_z), "wb") orelse return error.WriteFailed;
    _ = c.fwrite(old_json.ptr, 1, old_json.len, fp);
    _ = c.fclose(fp);

    const parsed = try load(a, file_path);
    defer parsed.deinit();
    // No web face is restored for a pane that never had one.
    try std.testing.expect(parsed.value.tabs[0].tree.pane.web == null);
}

test "round trip preserves full browser pane state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const real_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&tmp_dir.sub_path});
    const file_path = try std.fmt.allocPrint(a, "{s}/browser.json", .{real_path});
    const refs = [_]browser_model.FileRef{.{ .host = "box", .path = "/old" }};
    const btabs = [_]browser_model.TabState{.{
        .location = .{ .host = "box", .path = "/work" },
        .back = &refs,
        .expanded = &refs,
        .show_hidden = true,
        .view = .miller,
    }};
    const cmd = [_][]const u8{"sh"};
    const tabs = [_]TabSpec{.{ .title = "files", .tree = .{ .pane = .{
        .cwd = "/",
        .command = &cmd,
        .browser = .{ .tabs = &btabs },
    } } }};
    try save(a, .{ .tabs = &tabs }, file_path);
    const parsed = try load(a, file_path);
    defer parsed.deinit();
    const state = parsed.value.tabs[0].tree.pane.browser.?;
    try std.testing.expectEqual(browser_model.ViewMode.miller, state.tabs[0].view);
    try std.testing.expectEqualStrings("box", state.tabs[0].location.host);
    try std.testing.expect(state.tabs[0].show_hidden);
}

test "layout save accepts the load limit and preserves the old file on rejection" {
    const t = std.testing;
    var tmpl = "/tmp/sketerm-layout-size-XXXXXX".*;
    const dir = c.mkdtemp(&tmpl) orelse return error.SkipZigTest;
    defer _ = c.rmdir(dir);
    const base = std.mem.span(@as([*:0]u8, @ptrCast(dir)));
    var path_buf: [512:0]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "{s}/layout.json", .{base});
    defer _ = c.unlink(path.ptr);

    const command = [_][]const u8{"sh"};
    var tabs = [_]TabSpec{.{
        .title = "",
        .tree = .{ .pane = .{ .cwd = "/", .command = &command } },
    }};
    var overhead_buf: [1024]u8 = undefined;
    var overhead_writer = std.Io.Writer.fixed(&overhead_buf);
    try serialiseForSave(.{ .tabs = &tabs }, &overhead_writer);
    const overhead = overhead_writer.buffered().len;

    const targets = [_]usize{
        16 * 1024,
        16 * 1024 + 1,
        MAX_FILE_BYTES - 1,
        MAX_FILE_BYTES,
    };
    for (targets) |target| {
        const title = try t.allocator.alloc(u8, target - overhead);
        defer t.allocator.free(title);
        @memset(title, 'x');
        tabs[0].title = title;
        try save(t.allocator, .{ .tabs = &tabs }, path);

        var st: c.struct_stat = undefined;
        try t.expect(c.stat(path.ptr, &st) == 0);
        try t.expectEqual(target, @as(usize, @intCast(st.st_size)));
        const parsed = try load(t.allocator, path);
        defer parsed.deinit();
        try t.expectEqual(title.len, parsed.value.tabs[0].title.len);
        try t.expect(std.mem.allEqual(u8, parsed.value.tabs[0].title, 'x'));
    }

    const too_large_title = try t.allocator.alloc(u8, MAX_FILE_BYTES + 1 - overhead);
    defer t.allocator.free(too_large_title);
    @memset(too_large_title, 'y');
    tabs[0].title = too_large_title;
    try t.expectError(error.OutputTooLarge, save(t.allocator, .{ .tabs = &tabs }, path));

    var allocator_config: t.FailingAllocator.Config = .{};
    allocator_config.fail_index = 0;
    var failing = t.FailingAllocator.init(t.allocator, allocator_config);
    try t.expectError(error.OutOfMemory, save(failing.allocator(), .{ .tabs = &tabs }, path));
    try t.expect(failing.has_induced_failure);

    const preserved = try load(t.allocator, path);
    defer preserved.deinit();
    try t.expectEqual(MAX_FILE_BYTES - overhead, preserved.value.tabs[0].title.len);
    try t.expect(std.mem.allEqual(u8, preserved.value.tabs[0].title, 'x'));
}

test "a session far larger than any real one stays inside the size ceiling" {
    // The ceiling exists to refuse a runaway, not to lose a session: the
    // shutdown auto-save (winlayout.saveLayoutQuietly) cannot report a
    // refusal beyond one stderr line, so the headroom must be provable
    // rather than assumed. 200 tabs x 8 durable panes with long paths,
    // commands, titles and session names is already implausible.
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const tab_count = 200;
    const panes_per_tab = 8;
    const command = [_][]const u8{ "/usr/bin/env", "bash", "-lc", "cd \"$PWD\" && exec \"$SHELL\" -l" };

    const tabs = try a.alloc(TabSpec, tab_count);
    for (tabs, 0..) |*tab, i| {
        var tree: Tree = undefined;
        for (0..panes_per_tab) |p| {
            const pane: Tree = .{ .pane = .{
                .cwd = try std.fmt.allocPrint(a, "/home/username/projects/some-long-monorepo/services/backend/src/tab{d}/pane{d}", .{ i, p }),
                .command = &command,
                .profile = "a-profile-name",
                .custom_shader = "/home/username/.config/sketerm/shaders/crt-with-a-long-name.glsl",
                .shader_preset = "crt-with-a-long-name",
                .mux_session = try std.fmt.allocPrint(a, "durable-session-tab{d}-pane{d}", .{ i, p }),
                .mux_host = "udp:build-box.internal.example.com",
            } };
            if (p == 0) {
                tree = pane;
                continue;
            }
            const children = try a.alloc(Tree, 2);
            children[0] = tree;
            children[1] = pane;
            tree = .{ .split = .{ .orientation = .horizontal, .ratio = 0.5, .children = children } };
        }
        tab.* = .{
            .title = try std.fmt.allocPrint(a, "tab {d}: a reasonably long human-written tab title", .{i}),
            .tree = tree,
            .color = "#ff8800",
        };
    }

    var out = std.Io.Writer.Allocating.init(a);
    defer out.deinit();
    try serialiseForSave(.{ .tabs = tabs }, &out.writer);
    const size = out.written().len;
    try t.expect(size > 1024 * 1024); // past the ceiling this used to have
    try t.expect(size < MAX_FILE_BYTES / 2); // and still half the cap away
}
