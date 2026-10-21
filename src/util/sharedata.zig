//! The one lookup for files sketerm ships under `share/sketerm/`.

const std = @import("std");
const c = @import("cbindings");
const platform = @import("platform.zig");

/// Where `rel` lives, probed in order: the installed share dir next to
/// the exe (`<exe dir>/../share/sketerm`), the repo's `data/` of a dev
/// tree (`<exe dir>/../../data`), then `/usr/share/sketerm`.
/// @return the readable path (it may hold `..`), aliasing `buf`; null when none is readable.
pub fn find(buf: *[4096]u8, rel: []const u8) ?[:0]const u8 {
    var exe_buf: [4096]u8 = undefined;
    if (platform.exePath(&exe_buf)) |exe_path| {
        const exe_dir = std.fs.path.dirname(exe_path) orelse "/usr/bin";
        for ([_][]const u8{ "/../share/sketerm/", "/../../data/" }) |infix| {
            const cand = std.fmt.bufPrintSentinel(buf, "{s}{s}{s}", .{ exe_dir, infix, rel }, 0) catch continue;
            if (c.access(cand.ptr, c.R_OK) == 0) return cand;
        }
    }
    const sys = std.fmt.bufPrintSentinel(buf, "/usr/share/sketerm/{s}", .{rel}, 0) catch return null;
    return if (c.access(sys.ptr, c.R_OK) == 0) sys else null;
}
