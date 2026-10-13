//! Where sketerm's per-user state lives: `$XDG_STATE_HOME/sketerm`,
//! else `$HOME/.local/state/sketerm`. THE one rule -- every state
//! file the file browser owns resolves through here.
//!
//! There is deliberately no world-writable fallback. The copies this
//! replaced each ended in a shared `/tmp/sketerm-<name>.json`, which
//! another user on the machine can plant before we write it or read
//! after; a host that names neither directory gets no state file at
//! all, and the caller degrades to in-memory state.

const std = @import("std");
const env = @import("env.zig");

pub const Error = error{ NoStateDir, OutOfMemory };

/// The state directory itself, without a trailing slash.
/// @return null when neither variable names a directory (an EMPTY
/// variable counts as unset, as the XDG spec says).
pub fn stateDir(buf: []u8) ?[]const u8 {
    return stateDirFrom(buf, env.nonEmpty("XDG_STATE_HOME"), env.nonEmpty("HOME"));
}

/// `stateDir` for variables passed by value, so a caller can resolve ANOTHER process's.
pub fn stateDirFrom(buf: []u8, xdg_state_home: ?[]const u8, home: ?[]const u8) ?[]const u8 {
    if (xdg_state_home) |xs| if (xs.len > 0)
        return std.fmt.bufPrint(buf, "{s}/sketerm", .{xs}) catch null;
    if (home) |h| if (h.len > 0)
        return std.fmt.bufPrint(buf, "{s}/.local/state/sketerm", .{h}) catch null;
    return null;
}

/// The user's sketerm config directory (`$XDG_CONFIG_HOME/sketerm`, else
/// `$HOME/.config/sketerm`), without a trailing slash.
/// @return null when neither variable names a directory.
pub fn configDir(buf: []u8) ?[]const u8 {
    if (env.nonEmpty("XDG_CONFIG_HOME")) |xc|
        return std.fmt.bufPrint(buf, "{s}/sketerm", .{xc}) catch null;
    if (env.nonEmpty("HOME")) |home|
        return std.fmt.bufPrint(buf, "{s}/.config/sketerm", .{home}) catch null;
    return null;
}

/// The user's sketerm data directory (`$XDG_DATA_HOME/sketerm`, else
/// `$HOME/.local/share/sketerm`), without a trailing slash.
/// @return null when neither variable names a directory.
pub fn dataDir(buf: []u8) ?[]const u8 {
    if (env.nonEmpty("XDG_DATA_HOME")) |xd|
        return std.fmt.bufPrint(buf, "{s}/sketerm", .{xd}) catch null;
    if (env.nonEmpty("HOME")) |home|
        return std.fmt.bufPrint(buf, "{s}/.local/share/sketerm", .{home}) catch null;
    return null;
}

/// `<data dir>/<rel>`, allocated, e.g. `webext` or `userscripts`.
/// @return null when no data directory can be named.
pub fn dataPath(allocator: std.mem.Allocator, rel: []const u8) error{OutOfMemory}!?[]u8 {
    var buf: [4096]u8 = undefined;
    const dir = dataDir(&buf) orelse return null;
    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, rel });
}

/// `<state dir>/<rel>`, allocated. `rel` is a relative path such as
/// `places.json` or `file-transfers.d`.
pub fn statePath(allocator: std.mem.Allocator, rel: []const u8) Error![]u8 {
    var buf: [4096]u8 = undefined;
    const dir = stateDir(&buf) orelse return Error.NoStateDir;
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, rel }) catch return Error.OutOfMemory;
}

test "statePath prefers XDG_STATE_HOME, falls back to HOME, and never to /tmp" {
    const c = @import("../c.zig").c;
    const t = std.testing;
    var saved_state: env.Saved = .{};
    try saved_state.override("XDG_STATE_HOME", "/xs");
    defer saved_state.restore();
    var saved_home: env.Saved = .{};
    try saved_home.override("HOME", "/home/u");
    defer saved_home.restore();
    const a = try statePath(t.allocator, "places.json");
    defer t.allocator.free(a);
    try t.expectEqualStrings("/xs/sketerm/places.json", a);

    _ = c.setenv("XDG_STATE_HOME", "", 1);
    const b = try statePath(t.allocator, "file-transfers.d");
    defer t.allocator.free(b);
    try t.expectEqualStrings("/home/u/.local/state/sketerm/file-transfers.d", b);

    _ = c.unsetenv("XDG_STATE_HOME");
    _ = c.unsetenv("HOME");
    try t.expectError(Error.NoStateDir, statePath(t.allocator, "x"));
}

test "configDir prefers XDG_CONFIG_HOME, falls back to HOME" {
    const c = @import("../c.zig").c;
    const t = std.testing;
    var saved_cfg: env.Saved = .{};
    try saved_cfg.override("XDG_CONFIG_HOME", "/xc");
    defer saved_cfg.restore();
    var saved_home: env.Saved = .{};
    try saved_home.override("HOME", "/home/u");
    defer saved_home.restore();
    var buf: [256]u8 = undefined;
    try t.expectEqualStrings("/xc/sketerm", configDir(&buf).?);
    _ = c.setenv("XDG_CONFIG_HOME", "", 1);
    try t.expectEqualStrings("/home/u/.config/sketerm", configDir(&buf).?);
    _ = c.unsetenv("XDG_CONFIG_HOME");
    _ = c.unsetenv("HOME");
    try t.expect(configDir(&buf) == null);
}

test "dataPath prefers XDG_DATA_HOME, falls back to HOME, and is null with neither" {
    const c = @import("../c.zig").c;
    const t = std.testing;
    var saved_data: env.Saved = .{};
    try saved_data.override("XDG_DATA_HOME", "/xd");
    defer saved_data.restore();
    var saved_home: env.Saved = .{};
    try saved_home.override("HOME", "/home/u");
    defer saved_home.restore();
    const a = (try dataPath(t.allocator, "webext")).?;
    defer t.allocator.free(a);
    try t.expectEqualStrings("/xd/sketerm/webext", a);
    _ = c.setenv("XDG_DATA_HOME", "", 1);
    const b = (try dataPath(t.allocator, "userscripts")).?;
    defer t.allocator.free(b);
    try t.expectEqualStrings("/home/u/.local/share/sketerm/userscripts", b);
    _ = c.unsetenv("XDG_DATA_HOME");
    _ = c.unsetenv("HOME");
    try t.expect((try dataPath(t.allocator, "x")) == null);
}
