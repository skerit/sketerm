//! Freedesktop .desktop entry discovery + parsing for the remote app
//! launcher. Pure parsing (testable); directory scanning uses libc so
//! it links into the GTK-free daemon.

const std = @import("std");
const c = @import("../c.zig").c;

/// Zig 0.16 has no std.fmt.allocPrintZ; build a NUL-terminated string.
fn allocPrintZ(a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![:0]u8 {
    const s = try std.fmt.allocPrint(a, fmt ++ "\x00", args);
    return s[0 .. s.len - 1 :0];
}

pub const Entry = struct {
    name: []u8,
    exec: []u8,
    icon: []u8,
    /// Runs in a terminal (Terminal=true) — we skip these for the
    /// GUI-app launcher.
    terminal: bool = false,

    fn deinit(self: *Entry, a: std.mem.Allocator) void {
        a.free(self.name);
        a.free(self.exec);
        a.free(self.icon);
    }
};

/// Strip `%f %u %F %U %i %c %k` field codes from an Exec value (we
/// launch with no arguments). `%%` becomes a literal `%`. Result is
/// trimmed; caller owns it.
pub fn cleanExec(a: std.mem.Allocator, exec: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < exec.len) : (i += 1) {
        if (exec[i] == '%' and i + 1 < exec.len) {
            const code = exec[i + 1];
            i += 1;
            if (code == '%') try out.append(a, '%');
            // all other field codes drop
            continue;
        }
        try out.append(a, exec[i]);
    }
    const trimmed = std.mem.trim(u8, out.items, " \t");
    const owned = try a.dupe(u8, trimmed);
    out.deinit(a);
    return owned;
}

/// Parse one .desktop file's `[Desktop Entry]` group. Returns null
/// when it should not appear in a launcher (NoDisplay/Hidden, missing
/// Name/Exec, or Type != Application). Caller owns the Entry.
pub fn parse(a: std.mem.Allocator, text: []const u8) !?Entry {
    var name: ?[]const u8 = null;
    var exec: ?[]const u8 = null;
    var icon: []const u8 = "";
    var terminal = false;
    var is_app = false;
    var hidden = false;
    var in_group = false;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            in_group = std.mem.eql(u8, line, "[Desktop Entry]");
            continue;
        }
        if (!in_group) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        // Localized keys (Name[de]) are ignored — we take the plain C key.
        if (std.mem.eql(u8, key, "Type")) {
            is_app = std.mem.eql(u8, val, "Application");
        } else if (std.mem.eql(u8, key, "Name")) {
            name = val;
        } else if (std.mem.eql(u8, key, "Exec")) {
            exec = val;
        } else if (std.mem.eql(u8, key, "Icon")) {
            icon = val;
        } else if (std.mem.eql(u8, key, "Terminal")) {
            terminal = std.mem.eql(u8, val, "true");
        } else if (std.mem.eql(u8, key, "NoDisplay") or std.mem.eql(u8, key, "Hidden")) {
            if (std.mem.eql(u8, val, "true")) hidden = true;
        }
    }
    if (hidden or !is_app) return null;
    const nm = name orelse return null;
    const ex = exec orelse return null;
    if (nm.len == 0 or ex.len == 0) return null;
    return Entry{
        .name = try a.dupe(u8, nm),
        .exec = try cleanExec(a, ex),
        .icon = try a.dupe(u8, icon),
        .terminal = terminal,
    };
}

/// Colon-separated $XDG_DATA_DIRS (+ $XDG_DATA_HOME or ~/.local/share),
/// each with `/applications` appended. Writes NUL-terminated paths.
fn dataDirs(a: std.mem.Allocator) ![]const []u8 {
    var dirs: std.ArrayList([]u8) = .empty;
    errdefer {
        for (dirs.items) |d| a.free(d);
        dirs.deinit(a);
    }
    const home_share: []const u8 = blk: {
        if (c.getenv("XDG_DATA_HOME")) |v| {
            const s = std.mem.span(v);
            if (s.len > 0) break :blk s;
        }
        if (c.getenv("HOME")) |h| break :blk try std.fmt.allocPrint(a, "{s}/.local/share", .{std.mem.span(h)});
        break :blk "";
    };
    if (home_share.len > 0)
        try dirs.append(a, try allocPrintZ(a, "{s}/applications", .{home_share}));

    const sys = if (c.getenv("XDG_DATA_DIRS")) |v| blk: {
        const s = std.mem.span(v);
        break :blk if (s.len > 0) s else "/usr/local/share:/usr/share";
    } else "/usr/local/share:/usr/share";
    var it = std.mem.splitScalar(u8, sys, ':');
    while (it.next()) |d| {
        if (d.len == 0) continue;
        try dirs.append(a, try allocPrintZ(a, "{s}/applications", .{d}));
    }
    return dirs.toOwnedSlice(a);
}

/// Scan all data dirs and collect launcher entries, de-duplicated by
/// desktop-file basename (earlier dirs win, per XDG precedence),
/// GUI apps only (Terminal=false), sorted by Name. Caller owns.
pub fn scan(a: std.mem.Allocator, max: usize) ![]Entry {
    var seen = std.StringHashMap(void).init(a);
    defer {
        var kit = seen.keyIterator();
        while (kit.next()) |k| a.free(k.*);
        seen.deinit();
    }
    var entries: std.ArrayList(Entry) = .empty;
    errdefer {
        for (entries.items) |*e| e.deinit(a);
        entries.deinit(a);
    }

    const dirs = try dataDirs(a);
    defer {
        for (dirs) |d| a.free(d);
        a.free(dirs);
    }

    for (dirs) |dir| {
        const dp = c.opendir(dir.ptr) orelse continue;
        defer _ = c.closedir(dp);
        while (c.readdir(dp)) |ent| {
            const nm = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
            if (!std.mem.endsWith(u8, nm, ".desktop")) continue;
            if (seen.contains(nm)) continue;
            const key = try a.dupe(u8, nm);
            seen.put(key, {}) catch {
                a.free(key);
                continue;
            };
            const full = allocPrintZ(a, "{s}/{s}", .{ dir, nm }) catch continue;
            defer a.free(full);
            const text = readFile(a, full) catch continue orelse continue;
            defer a.free(text);
            const maybe = parse(a, text) catch continue;
            if (maybe) |e| {
                if (e.terminal) {
                    var ee = e;
                    ee.deinit(a);
                    continue;
                }
                entries.append(a, e) catch {
                    var ee = e;
                    ee.deinit(a);
                    break;
                };
                if (entries.items.len >= max) break;
            }
        }
        if (entries.items.len >= max) break;
    }

    std.mem.sort(Entry, entries.items, {}, struct {
        fn lt(_: void, x: Entry, y: Entry) bool {
            return std.ascii.lessThanIgnoreCase(x.name, y.name);
        }
    }.lt);
    return entries.toOwnedSlice(a);
}

pub fn freeEntries(a: std.mem.Allocator, entries: []Entry) void {
    for (entries) |*e| e.deinit(a);
    a.free(entries);
}

fn readFile(a: std.mem.Allocator, path: [:0]const u8) !?[]u8 {
    const f = c.fopen(path.ptr, "rb") orelse return null;
    defer _ = c.fclose(f);
    _ = c.fseek(f, 0, c.SEEK_END);
    const sz = c.ftell(f);
    if (sz <= 0 or sz > (1 << 20)) return null;
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

test "parse: GUI app with field codes" {
    const a = t.allocator;
    const text =
        \\[Desktop Entry]
        \\Type=Application
        \\Name=Text Editor
        \\Name[de]=Texteditor
        \\Exec=gedit %U --new-window
        \\Icon=org.gnome.gedit
        \\Terminal=false
    ;
    var e = (try parse(a, text)).?;
    defer e.deinit(a);
    try t.expectEqualStrings("Text Editor", e.name);
    try t.expectEqualStrings("gedit  --new-window", e.exec);
    try t.expectEqualStrings("org.gnome.gedit", e.icon);
    try t.expect(!e.terminal);
}

test "parse: NoDisplay and non-Application rejected" {
    const a = t.allocator;
    try t.expectEqual(@as(?Entry, null), try parse(a,
        \\[Desktop Entry]
        \\Type=Application
        \\Name=Hidden
        \\Exec=foo
        \\NoDisplay=true
    ));
    try t.expectEqual(@as(?Entry, null), try parse(a,
        \\[Desktop Entry]
        \\Type=Link
        \\Name=Bookmark
        \\URL=http://x
    ));
    // Keys outside [Desktop Entry] must not count.
    try t.expectEqual(@as(?Entry, null), try parse(a,
        \\[Desktop Action new]
        \\Name=New
        \\Exec=foo --new
    ));
}

test "cleanExec strips codes and keeps literal percent" {
    const a = t.allocator;
    const out = try cleanExec(a, "app %F --flag %%d %i");
    defer a.free(out);
    try t.expectEqualStrings("app  --flag %d", out);
}
