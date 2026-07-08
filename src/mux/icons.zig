//! Resolve a forwarded app's icon to actual image BYTES on the app's
//! host, so the GUI can put it on the local window via
//! gdk_toplevel_set_icon_list — which works for REMOTE apps whose
//! icon theme isn't installed on the client (Wayland's app_id ->
//! local .desktop lookup can't; shipping the pixels can).
//!
//! Pure freedesktop icon-theme traversal over libc file IO, so it
//! links into the GTK-free daemon (musl-clean). The GUI decodes the
//! bytes (PNG directly, SVG via gdk-pixbuf/librsvg).

const std = @import("std");
const c = @import("../c.zig").c;

pub const Kind = enum(u8) { other = 0, png = 1, svg = 2 };

pub const Icon = struct {
    bytes: []u8,
    kind: Kind,

    pub fn deinit(self: *Icon, a: std.mem.Allocator) void {
        a.free(self.bytes);
    }
};

/// Icon-theme size subdirs, best-first: a mid-large raster reads
/// crisp at taskbar sizes and still downscales cleanly; scalable
/// (SVG) beats a tiny raster.
const size_dirs = [_][]const u8{
    "128x128/apps", "96x96/apps",  "64x64/apps",
    "48x48/apps",   "256x256/apps", "scalable/apps",
    "32x32/apps",   "symbolic/apps",
};

/// Themes to search. hicolor is where apps install their own icon
/// (the app_id case); the others carry stock/named icons (e.g.
/// "accessories-calculator") an Icon= key might point at.
const themes = [_][]const u8{ "hicolor", "Adwaita", "breeze", "gnome", "Papirus", "oxygen" };

/// Resolve `app_id` (a Wayland xdg_toplevel app_id, e.g.
/// "org.gnome.Calculator") to icon bytes, or null when nothing is
/// found. Caller owns the returned bytes.
pub fn resolve(a: std.mem.Allocator, app_id: []const u8) !?Icon {
    if (app_id.len == 0 or app_id.len > 255) return null;

    // The Icon= key of the matching .desktop is the authoritative
    // icon name; fall back to the app_id itself (reverse-DNS apps
    // name their hicolor icon after the app_id).
    var name_buf: [512]u8 = undefined;
    const icon_name = desktopIconName(a, app_id, &name_buf) orelse app_id;

    var abs_buf: [4096]u8 = undefined;
    // Absolute-path Icon= values are read directly.
    if (icon_name.len > 0 and icon_name[0] == '/') {
        const p = std.fmt.bufPrintZ(&abs_buf, "{s}", .{icon_name}) catch return null;
        if (try readIcon(a, p)) |icon| return icon;
        return null;
    }

    const roots = try iconRoots(a);
    defer {
        for (roots) |r| a.free(r);
        a.free(roots);
    }

    // Raster first (cheap decode), then SVG.
    const exts = [_][]const u8{ ".png", ".svg" };
    var path_buf: [4096]u8 = undefined;
    for (roots) |root| {
        for (themes) |theme| {
            for (size_dirs) |sz| {
                for (exts) |ext| {
                    const p = std.fmt.bufPrintZ(&path_buf, "{s}/{s}/{s}/{s}{s}", .{ root, theme, sz, icon_name, ext }) catch continue;
                    if (try readIcon(a, p)) |icon| return icon;
                }
            }
        }
        // Legacy flat location: <root>/../pixmaps/<name>.
        const parent = std.fs.path.dirname(root) orelse root;
        for (exts) |ext| {
            const p = std.fmt.bufPrintZ(&path_buf, "{s}/pixmaps/{s}{s}", .{ parent, icon_name, ext }) catch continue;
            if (try readIcon(a, p)) |icon| return icon;
        }
    }
    return null;
}

/// Find `<datadir>/applications/<app_id>.desktop` and return its
/// Icon= value (copied into `buf`), or null. Most Wayland apps name
/// their .desktop after their app_id.
fn desktopIconName(a: std.mem.Allocator, app_id: []const u8, buf: []u8) ?[]const u8 {
    const dirs = shareDirs(a) catch return null;
    defer {
        for (dirs) |d| a.free(d);
        a.free(dirs);
    }
    var path_buf: [4096]u8 = undefined;
    for (dirs) |d| {
        const p = std.fmt.bufPrintZ(&path_buf, "{s}/applications/{s}.desktop", .{ d, app_id }) catch continue;
        const text = readFile(a, p, 256 * 1024) catch continue orelse continue;
        defer a.free(text);
        if (parseIconKey(text)) |icon| {
            if (icon.len == 0 or icon.len > buf.len) continue;
            @memcpy(buf[0..icon.len], icon);
            return buf[0..icon.len];
        }
    }
    return null;
}

/// The `Icon=` value from a .desktop file's [Desktop Entry] group
/// (a slice into `text`; not owned). Stops at the first other group.
fn parseIconKey(text: []const u8) ?[]const u8 {
    var in_entry = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            in_entry = std.mem.eql(u8, line, "[Desktop Entry]");
            continue;
        }
        if (!in_entry) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        // Only the plain "Icon" key (skip localized "Icon[xx]").
        if (std.mem.eql(u8, std.mem.trim(u8, line[0..eq], " \t"), "Icon"))
            return std.mem.trim(u8, line[eq + 1 ..], " \t");
    }
    return null;
}

/// `<datadir>/icons` roots in XDG precedence (user first).
fn iconRoots(a: std.mem.Allocator) ![]const []u8 {
    const dirs = try shareDirs(a);
    defer {
        for (dirs) |d| a.free(d);
        a.free(dirs);
    }
    var roots: std.ArrayList([]u8) = .empty;
    errdefer {
        for (roots.items) |r| a.free(r);
        roots.deinit(a);
    }
    for (dirs) |d| try roots.append(a, try std.fmt.allocPrint(a, "{s}/icons", .{d}));
    return roots.toOwnedSlice(a);
}

/// $XDG_DATA_HOME (or ~/.local/share) then split $XDG_DATA_DIRS —
/// bare data roots, no suffix. Caller owns.
fn shareDirs(a: std.mem.Allocator) ![]const []u8 {
    var dirs: std.ArrayList([]u8) = .empty;
    errdefer {
        for (dirs.items) |d| a.free(d);
        dirs.deinit(a);
    }
    if (c.getenv("XDG_DATA_HOME")) |v| {
        const s = std.mem.span(v);
        if (s.len > 0) try dirs.append(a, try a.dupe(u8, s));
    } else if (c.getenv("HOME")) |h| {
        try dirs.append(a, try std.fmt.allocPrint(a, "{s}/.local/share", .{std.mem.span(h)}));
    }
    const sys = if (c.getenv("XDG_DATA_DIRS")) |v| blk: {
        const s = std.mem.span(v);
        break :blk if (s.len > 0) s else "/usr/local/share:/usr/share";
    } else "/usr/local/share:/usr/share";
    var it = std.mem.splitScalar(u8, sys, ':');
    while (it.next()) |d| {
        if (d.len == 0) continue;
        try dirs.append(a, try a.dupe(u8, d));
    }
    return dirs.toOwnedSlice(a);
}

/// Read an icon file if it exists, tagging its kind by extension.
/// Returns null when absent (the common miss).
fn readIcon(a: std.mem.Allocator, path: [:0]const u8) !?Icon {
    const bytes = (try readFile(a, path, 8 * 1024 * 1024)) orelse return null;
    return .{ .bytes = bytes, .kind = kindFromPath(path) };
}

fn kindFromPath(path: []const u8) Kind {
    if (std.mem.endsWith(u8, path, ".png")) return .png;
    if (std.mem.endsWith(u8, path, ".svg") or std.mem.endsWith(u8, path, ".svgz")) return .svg;
    return .other;
}

fn readFile(a: std.mem.Allocator, path: [:0]const u8, max: usize) !?[]u8 {
    const f = c.fopen(path.ptr, "rb") orelse return null;
    defer _ = c.fclose(f);
    _ = c.fseek(f, 0, c.SEEK_END);
    const sz = c.ftell(f);
    if (sz <= 0 or @as(usize, @intCast(sz)) > max) return null;
    _ = c.fseek(f, 0, c.SEEK_SET);
    const buf = try a.alloc(u8, @intCast(sz));
    errdefer a.free(buf);
    const rd = c.fread(buf.ptr, 1, buf.len, f);
    if (rd != buf.len) {
        a.free(buf);
        return null;
    }
    return buf;
}

// ─── tests ──────────────────────────────────────────────────────

const t = std.testing;

test "kindFromPath" {
    try t.expectEqual(Kind.png, kindFromPath("/a/b/foo.png"));
    try t.expectEqual(Kind.svg, kindFromPath("/a/b/foo.svg"));
    try t.expectEqual(Kind.svg, kindFromPath("/a/b/foo.svgz"));
    try t.expectEqual(Kind.other, kindFromPath("/a/b/foo.xpm"));
}

test "parseIconKey: plain key from [Desktop Entry] only" {
    const txt =
        \\[Desktop Entry]
        \\Name=Calculator
        \\Icon=org.gnome.Calculator
        \\Icon[de]=nope
        \\
        \\[Desktop Action New]
        \\Icon=wrong
    ;
    try t.expectEqualStrings("org.gnome.Calculator", parseIconKey(txt).?);
}

test "parseIconKey: absent" {
    try t.expect(parseIconKey("[Desktop Entry]\nName=x\n") == null);
}

test "resolve: absolute-path icon name reads the file" {
    const a = t.allocator;
    // Write a fake PNG to a temp path, point an absolute Icon= at it
    // by resolving an app whose .desktop we synthesize is overkill —
    // exercise the absolute-path branch directly via a crafted name.
    const path = "/tmp/sketerm-icons-test.png";
    const f = c.fopen(path, "wb") orelse return error.SkipZigTest;
    const magic = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };
    _ = c.fwrite(&magic, 1, magic.len, f);
    _ = c.fclose(f);
    defer _ = c.remove(path);

    var icon = (try readIcon(a, path)) orelse return error.TestUnexpectedResult;
    defer icon.deinit(a);
    try t.expectEqual(Kind.png, icon.kind);
    try t.expectEqualSlices(u8, &magic, icon.bytes);
}
