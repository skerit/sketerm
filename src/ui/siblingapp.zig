//! Cross-identity handoff: launch one of sketerm's sibling application
//! identities as its own process.
//!
//! This is the Viewer's `revealCurrent` mechanism generalized. Spawning
//! the sibling BINARY (falling back to `<exe> <subcommand>` when the
//! alias is not installed next to us) is deliberate and not replaceable
//! by IPC: each identity is a separate GApplication, so there is no
//! running instance of the target to talk to, and argv[0] is what gives
//! the new window its own app id, taskbar group and icon.

const std = @import("std");
const c = @import("../c.zig").c;
const platform = @import("../util/platform.zig");
const paths = @import("../filebrowser/paths.zig");

/// Resolve `<dir-of-our-exe>/<name>`, or null when it is not there
/// (running from a build tree that only installed `sketerm`).
fn siblingBinary(name: []const u8, exe: [:0]const u8, buf: *[4096:0]u8) ?[*:0]const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, exe, '/') orelse return null;
    const candidate = std.fmt.bufPrintZ(buf, "{s}/{s}", .{ exe[0..slash], name }) catch return null;
    if (c.access(candidate.ptr, c.X_OK) != 0) return null;
    return candidate.ptr;
}

/// Spawn a sibling identity with `args` after the program name.
/// @return false when the spawn itself failed.
fn spawnSibling(binary: []const u8, subcommand: [*:0]const u8, args: []const [*:0]const u8) bool {
    if (args.len > 4) return false;
    var exe_buf: [4096:0]u8 = undefined;
    const exe = platform.exePathZ(&exe_buf) orelse return false;
    var sibling_buf: [4096:0]u8 = undefined;
    const sibling = siblingBinary(binary, exe, &sibling_buf);

    var argv: [7]?[*:0]u8 = @splat(null);
    var at: usize = 0;
    argv[at] = @constCast(if (sibling) |bin| bin else exe.ptr);
    at += 1;
    if (sibling == null) {
        argv[at] = @constCast(subcommand);
        at += 1;
    }
    for (args) |a| {
        argv[at] = @constCast(a);
        at += 1;
    }
    var gerr: [*c]c.GError = null;
    if (c.g_spawn_async(null, @ptrCast(&argv), null, @intCast(c.G_SPAWN_DEFAULT), null, null, null, &gerr) == 0) {
        if (gerr != null) c.g_error_free(gerr);
        return false;
    }
    return true;
}

pub const EditorOpen = struct {
    /// Insist on a window of its own. Without it the running Sketerm
    /// Editor instance adds the document as a tab of its window.
    new_window: bool = false,
};

/// Open `spec` in the Sketerm Editor application, optionally with the
/// caret at 1-based `line`: a tab of the running instance's window,
/// or a fresh window when there is none or `opts.new_window` asks.
pub fn openInEditor(spec: []const u8, line: ?usize, opts: EditorOpen) bool {
    if (spec.len >= 4096) return false;
    var spec_buf: [4096:0]u8 = undefined;
    const spec_z = std.fmt.bufPrintZ(&spec_buf, "{s}", .{spec}) catch return false;
    var line_buf: [32:0]u8 = undefined;
    var args: [4][*:0]const u8 = undefined;
    var n: usize = 0;
    if (opts.new_window) {
        args[n] = "--new-window";
        n += 1;
    }
    if (line) |l| {
        const line_z = std.fmt.bufPrintZ(&line_buf, "--line={d}", .{l}) catch return false;
        args[n] = line_z.ptr;
        n += 1;
    }
    args[n] = spec_z.ptr;
    n += 1;
    return spawnSibling("sketerm-editor", "edit", args[0..n]);
}

/// Show `spec` (a file) selected inside a Sketerm Files window.
pub fn showInFiles(spec: []const u8) bool {
    const loc = paths.parseSpec(spec);
    if (loc.path.len >= 3800) return false;
    const parent = std.fs.path.dirname(loc.path) orelse "/";
    var parent_buf: [paths.SPEC_BUF_LEN]u8 = undefined;
    const parent_spec = paths.formatSpec(&parent_buf, loc.host, parent);
    var parent_z_buf: [4096:0]u8 = undefined;
    const parent_z = std.fmt.bufPrintZ(&parent_z_buf, "{s}", .{parent_spec}) catch return false;
    var select_buf: [4200:0]u8 = undefined;
    const select = std.fmt.bufPrintZ(&select_buf, "--select={s}", .{spec}) catch return false;
    return spawnSibling("sketerm-files", "files", &.{ parent_z.ptr, select.ptr });
}
