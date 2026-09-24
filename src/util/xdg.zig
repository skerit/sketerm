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
    if (env.nonEmpty("XDG_STATE_HOME")) |xs|
        return std.fmt.bufPrint(buf, "{s}/sketerm", .{xs}) catch null;
    if (env.nonEmpty("HOME")) |home|
        return std.fmt.bufPrint(buf, "{s}/.local/state/sketerm", .{home}) catch null;
    return null;
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
    const old_state = env.get("XDG_STATE_HOME");
    const old_home = env.get("HOME");
    defer {
        restore("XDG_STATE_HOME", old_state);
        restore("HOME", old_home);
    }
    _ = c.setenv("XDG_STATE_HOME", "/xs", 1);
    _ = c.setenv("HOME", "/home/u", 1);
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

fn restore(name: [*:0]const u8, value: ?[]const u8) void {
    const c = @import("../c.zig").c;
    if (value) |v| {
        var z: [4096:0]u8 = undefined;
        if (std.fmt.bufPrintZ(&z, "{s}", .{v})) |s| _ = c.setenv(name, s.ptr, 1) else |_| {}
    } else _ = c.unsetenv(name);
}
