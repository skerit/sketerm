//! GTK-free rules behind the Open With chooser: search matching, section
//! dedupe, custom command lines, the host section's state and the
//! encoded opener every local launch path carries.

const std = @import("std");
const mimeListContains = @import("desktop.zig").mimeListContains;

/// Marks an opener string as a custom command line rather than a
/// desktop id. It rides the same `app_id` field the transfer ledger
/// persists, so an older build reading it finds no such desktop id and
/// falls back to the default handler instead of failing.
pub const COMMAND_PREFIX = "sketerm-cmdline:";

/// What a local launch opens the file with.
pub const Opener = union(enum) {
    default,
    desktop_id: []const u8,
    command: []const u8,
};

pub fn parseOpener(app_id: ?[]const u8) Opener {
    const s = app_id orelse return .default;
    if (s.len == 0) return .default;
    if (std.mem.startsWith(u8, s, COMMAND_PREFIX)) {
        const cmd = s[COMMAND_PREFIX.len..];
        return if (cmd.len == 0) .default else .{ .command = cmd };
    }
    return .{ .desktop_id = s };
}

/// @return the opener string for a custom command line, owned by the caller.
pub fn encodeCommand(allocator: std.mem.Allocator, cmdline: []const u8) ![]u8 {
    return std.mem.concat(allocator, u8, &.{ COMMAND_PREFIX, cmdline });
}

/// The command a typed custom command launches as: trimmed, null when
/// blank. Nothing is appended here because GIO's
/// `g_app_info_create_from_commandline` always appends ` %f` itself,
/// and that code expands to nothing once a user-written %f/%u has
/// taken the one file.
pub fn customCommand(typed: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, typed, " \t\r\n");
    return if (t.len == 0) null else t;
}

/// The program an Exec / command line runs, without its directory, so
/// "vi" finds an app whose Exec is `/usr/bin/vim %F`.
pub fn execProgram(exec: []const u8) []const u8 {
    var it = std.mem.tokenizeAny(u8, exec, " \t");
    while (it.next()) |word| {
        // `env VAR=x prog` launchers name the program later.
        if (std.mem.eql(u8, word, "env") or std.mem.endsWith(u8, word, "/env")) continue;
        if (std.mem.indexOfScalar(u8, word, '=') != null) continue;
        return std.fs.path.basename(std.mem.trim(u8, word, "\"'"));
    }
    return "";
}

/// Case-insensitive substring match of the trimmed `query` against any
/// of `fields`; a blank query matches everything.
pub fn matches(query: []const u8, fields: []const []const u8) bool {
    const q = std.mem.trim(u8, query, " \t");
    if (q.len == 0) return true;
    for (fields) |f| {
        if (std.ascii.findIgnoreCase(f, q) != null) return true;
    }
    return false;
}

/// Desktop ids already listed by an earlier section; keys are owned.
pub const IdSet = struct {
    map: std.StringHashMapUnmanaged(void) = .empty,

    /// @return true when `id` was new (and is now recorded).
    pub fn add(self: *IdSet, allocator: std.mem.Allocator, id: []const u8) !bool {
        if (self.map.contains(id)) return false;
        const key = try allocator.dupe(u8, id);
        errdefer allocator.free(key);
        try self.map.put(allocator, key, {});
        return true;
    }

    pub fn contains(self: *const IdSet, id: []const u8) bool {
        return self.map.contains(id);
    }

    pub fn deinit(self: *IdSet, allocator: std.mem.Allocator) void {
        var it = self.map.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        self.map.deinit(allocator);
    }
};

pub fn nameLess(_: void, a: []const u8, b: []const u8) bool {
    return std.ascii.lessThanIgnoreCase(a, b);
}

/// What the "On <host>" section shows.
pub const HostState = enum {
    /// A local file: no host section at all.
    hidden,
    loading,
    not_connected,
    /// The daemon refused or failed the `apps` query.
    unavailable,
    /// The query answered with nothing to offer.
    empty,
    ready,

    /// The one-row text for every state that has no app rows.
    pub fn message(self: HostState) ?[]const u8 {
        return switch (self) {
            .loading => "Looking for applications on the host…",
            .not_connected => "Not connected to the host",
            .unavailable => "The host could not list its applications",
            .empty => "No applications found on the host",
            .hidden, .ready => null,
        };
    }
};

pub const HostReply = struct { ok: bool, shown: usize };

pub fn hostState(remote: bool, connected: bool, reply: ?HostReply) HostState {
    if (!remote) return .hidden;
    const r = reply orelse return if (connected) .loading else .not_connected;
    if (!r.ok) return .unavailable;
    return if (r.shown == 0) .empty else .ready;
}

/// Indices of the host apps to list for `mime`: those declaring it,
/// else every app (a host whose .desktop files declare nothing useful
/// must still offer something). `apps` elements need a `mimes` field.
pub fn pickHostApps(allocator: std.mem.Allocator, apps: anytype, mime: []const u8, out: *std.ArrayList(usize)) !void {
    if (mime.len > 0) {
        for (apps, 0..) |app, i| {
            if (mimeListContains(app.mimes, mime)) try out.append(allocator, i);
        }
    }
    if (out.items.len > 0) return;
    for (apps, 0..) |_, i| try out.append(allocator, i);
}

/// The chooser's location line: `host:dir` for a remote file, the
/// directory with `home` folded to `~` for a local one.
pub fn displayLocation(buf: []u8, host: ?[]const u8, dir: []const u8, home: ?[]const u8) []const u8 {
    if (host) |h| return std.fmt.bufPrint(buf, "{s}:{s}", .{ h, dir }) catch dir;
    if (home) |hm| {
        if (hm.len > 1 and std.mem.startsWith(u8, dir, hm) and
            (dir.len == hm.len or dir[hm.len] == '/'))
            return std.fmt.bufPrint(buf, "~{s}", .{dir[hm.len..]}) catch dir;
    }
    return dir;
}

test "parseOpener tells desktop ids, commands and the default apart" {
    const t = std.testing;
    try t.expect(parseOpener(null) == .default);
    try t.expect(parseOpener("") == .default);
    try t.expectEqualStrings("org.gnome.gedit.desktop", parseOpener("org.gnome.gedit.desktop").desktop_id);
    const enc = try encodeCommand(t.allocator, "gimp %f");
    defer t.allocator.free(enc);
    try t.expectEqualStrings("gimp %f", parseOpener(enc).command);
    try t.expect(parseOpener(COMMAND_PREFIX) == .default);
}

test "customCommand trims and refuses blanks" {
    const t = std.testing;
    try t.expect(customCommand("   ") == null);
    try t.expect(customCommand("") == null);
    try t.expectEqualStrings("gimp", customCommand("  gimp \n").?);
    try t.expectEqualStrings("sh -c 'echo %f > /tmp/x'", customCommand("sh -c 'echo %f > /tmp/x'").?);
}

test "matches is case-insensitive over name, id and program" {
    const t = std.testing;
    const fields = [_][]const u8{ "Text Editor", "org.gnome.TextEditor.desktop", execProgram("/usr/bin/gnome-text-editor %U") };
    try t.expect(matches("", &fields));
    try t.expect(matches("  edit ", &fields));
    try t.expect(matches("TEXTEDITOR", &fields));
    try t.expect(matches("gnome-text", &fields));
    try t.expect(!matches("gimp", &fields));
    try t.expectEqualStrings("vim", execProgram("/usr/bin/vim %F"));
    try t.expectEqualStrings("mpv", execProgram("env LANG=C /usr/bin/mpv --player-operation-mode=pseudo-gui -- %U"));
    try t.expectEqualStrings("", execProgram("   "));
}

test "IdSet dedupes across sections and owns its keys" {
    const t = std.testing;
    var set: IdSet = .{};
    defer set.deinit(t.allocator);
    var buf = "vim.desktop".*;
    try t.expect(try set.add(t.allocator, &buf));
    buf[0] = 'x';
    try t.expect(set.contains("vim.desktop"));
    try t.expect(!(try set.add(t.allocator, "vim.desktop")));
    try t.expect(try set.add(t.allocator, "kate.desktop"));
}

test "nameLess sorts by name ignoring case" {
    var names = [_][]const u8{ "vim", "Atom", "emacs", "Blender" };
    std.mem.sort([]const u8, &names, {}, nameLess);
    try std.testing.expectEqualStrings("Atom", names[0]);
    try std.testing.expectEqualStrings("Blender", names[1]);
    try std.testing.expectEqualStrings("vim", names[3]);
}

test "hostState covers every host-section state" {
    const t = std.testing;
    try t.expectEqual(HostState.hidden, hostState(false, true, null));
    try t.expectEqual(HostState.loading, hostState(true, true, null));
    try t.expectEqual(HostState.not_connected, hostState(true, false, null));
    try t.expectEqual(HostState.unavailable, hostState(true, true, .{ .ok = false, .shown = 0 }));
    try t.expectEqual(HostState.empty, hostState(true, true, .{ .ok = true, .shown = 0 }));
    try t.expectEqual(HostState.ready, hostState(true, true, .{ .ok = true, .shown = 3 }));
    try t.expect(HostState.ready.message() == null);
    try t.expect(HostState.loading.message() != null);
}

test "pickHostApps prefers MIME matches and falls back to everything" {
    const t = std.testing;
    const App = struct { mimes: []const u8 };
    const apps = [_]App{ .{ .mimes = "image/png;" }, .{ .mimes = "text/markdown;text/plain;" }, .{ .mimes = "" } };
    var out: std.ArrayList(usize) = .empty;
    defer out.deinit(t.allocator);
    try pickHostApps(t.allocator, &apps, "text/markdown", &out);
    try t.expectEqualSlices(usize, &.{1}, out.items);
    out.clearRetainingCapacity();
    try pickHostApps(t.allocator, &apps, "video/mp4", &out);
    try t.expectEqualSlices(usize, &.{ 0, 1, 2 }, out.items);
    out.clearRetainingCapacity();
    try pickHostApps(t.allocator, &apps, "", &out);
    try t.expectEqual(@as(usize, 3), out.items.len);
}

test "displayLocation qualifies remote dirs and folds home" {
    const t = std.testing;
    var buf: [128]u8 = undefined;
    try t.expectEqualStrings("archdev:/srv/www", displayLocation(&buf, "archdev", "/srv/www", "/home/u"));
    try t.expectEqualStrings("~/Projects", displayLocation(&buf, null, "/home/u/Projects", "/home/u"));
    try t.expectEqualStrings("~", displayLocation(&buf, null, "/home/u", "/home/u"));
    try t.expectEqualStrings("/home/user2", displayLocation(&buf, null, "/home/user2", "/home/u"));
}
