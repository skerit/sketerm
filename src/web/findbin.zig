//! Locating the `sketerm-webengine` helper binary — shared by the GUI
//! face (src/ui/webface.zig) and the headless MCP driver
//! (src/ipc/webdrive.zig), so the two can never disagree on which
//! helper they run. GTK-free: libc + platform only.

const std = @import("std");
const c = @import("../c.zig").c;
const platform = @import("../util/platform.zig");

pub const HELPER_NAME = "sketerm-webengine";

/// The helper next to our own executable (installed layout and
/// `zig build` trees both), then the dev build tree, then the cwd.
/// `$SKETERM_WEB_BIN` pins it outright, which is what test rigs use.
pub fn find(buf: *[4096:0]u8) ?[*:0]const u8 {
    if (c.getenv("SKETERM_WEB_BIN")) |p| {
        if (c.access(p, c.X_OK) == 0) return p;
    }
    if (platform.exePathZ(buf)) |exe_path| {
        if (std.mem.lastIndexOfScalar(u8, exe_path, '/')) |slash| {
            const dir = exe_path[0 .. slash + 1];
            // Installed / `zig build` layout: a sibling of the GUI.
            if (writeCandidate(buf, dir, HELPER_NAME)) |p| return p;
            // A dev run straight out of a source checkout, where the
            // GUI was started from somewhere else in the tree.
            if (writeCandidate(buf, dir, "../zig-out/bin/" ++ HELPER_NAME)) |p| return p;
        }
    }
    if (c.access("zig-out/bin/" ++ HELPER_NAME, c.X_OK) == 0) return "zig-out/bin/" ++ HELPER_NAME;
    return null;
}

fn writeCandidate(buf: *[4096:0]u8, dir: []const u8, name: []const u8) ?[*:0]const u8 {
    if (dir.len + name.len + 1 >= buf.len) return null;
    // `dir` aliases `buf`; only the tail after it is written.
    @memcpy(buf[dir.len .. dir.len + name.len], name);
    buf[dir.len + name.len] = 0;
    if (c.access(buf, c.X_OK) != 0) return null;
    return @ptrCast(buf);
}
