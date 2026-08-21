//! Driving the real `sketerm-mux display` CLI in-process, with its
//! stdout captured.
//!
//! Four rigs (smoke-e2e, smoke-atspi, smoke-lsp-gui, web-measure) need a
//! display session and had a byte-identical copy of this. The capture
//! swaps fd 1 for a pipe rather than shelling out, which is the point:
//! the rig parses exactly the bytes an external caller would see, so it
//! never re-derives `wl-*` socket paths itself (CLAUDE.md forbids that,
//! because their naming differs between monolith and broker mode).

const std = @import("std");
const c = @import("../c.zig").c;
const platform = @import("../util/platform.zig");
const display_cli = @import("../mux/display.zig");

pub const CliResult = struct { code: u8, out: []u8 };

/// fd 1 redirected into a pipe for the duration of one in-process CLI
/// call. Split out of `runDisplayCli` because smoke-e2e captures the
/// `sketerm cli` entry point the same way, and only that rig links it.
pub const Capture = struct {
    read_fd: c_int = -1,
    saved_fd: c_int = -1,

    /// Null when the pipe could not be made; the caller then reports the
    /// failure as an empty capture rather than running uncaptured.
    pub fn begin() ?Capture {
        var pfds: [2]c_int = undefined;
        if (c.pipe(&pfds) != 0) return null;
        const saved = c.dup(1);
        _ = c.dup2(pfds[1], 1);
        _ = c.close(pfds[1]);
        return .{ .read_fd = pfds[0], .saved_fd = saved };
    }

    /// Restore fd 1 and slurp everything the call wrote. Caller owns the
    /// returned bytes.
    pub fn finish(self: Capture, allocator: std.mem.Allocator) []u8 {
        _ = c.fflush(platform.stdout());
        _ = c.dup2(self.saved_fd, 1);
        _ = c.close(self.saved_fd);
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            var buf: [4096]u8 = undefined;
            const n = c.read(self.read_fd, &buf, buf.len);
            if (n <= 0) break;
            out.appendSlice(allocator, buf[0..@intCast(n)]) catch break;
        }
        _ = c.close(self.read_fd);
        return out.toOwnedSlice(allocator) catch &.{};
    }
};

/// Run the real `sketerm-mux display` CLI in-process, stdout captured.
pub fn runDisplayCli(allocator: std.mem.Allocator, argv: []const []const u8) CliResult {
    const cap = Capture.begin() orelse
        return .{ .code = 1, .out = allocator.dupe(u8, "") catch &.{} };
    const code = display_cli.run(allocator, argv);
    return .{ .code = code, .out = cap.finish(allocator) };
}

/// `display create --json` reply. Extra fields are ignored by the
/// callers that only read `WAYLAND_DISPLAY`, so one shape serves all
/// four rigs.
pub const CreateReply = struct {
    session: []const u8 = "",
    environment: struct {
        WAYLAND_DISPLAY: []const u8 = "",
        XDG_RUNTIME_DIR: []const u8 = "",
        PULSE_SERVER: []const u8 = "",
        LIBGL_ALWAYS_SOFTWARE: []const u8 = "",
    } = .{},
};
