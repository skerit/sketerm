//! The sketerm binaries a smoke rig drives. build.zig installs the
//! dev-profile builds into a `bin/`-shaped dir (exe-relative `../share`
//! and `../../data` lookups resolve as for an install) and names it
//! with `--bin-dir <dir>`; a rig run by hand drives `zig-out/bin`.

const std = @import("std");

pub const DEFAULT_DIR = "zig-out/bin";

/// A binary under test; the tag is its file name.
pub const Bin = enum { sketerm, @"sketerm-mux", @"sketerm-lsp-stub" };

const PATH_MAX = 4096;

var g_paths: std.EnumArray(Bin, [*:0]const u8) = blk: {
    var paths: std.EnumArray(Bin, [*:0]const u8) = undefined;
    for (std.enums.values(Bin)) |bin| paths.set(bin, DEFAULT_DIR ++ "/" ++ @tagName(bin));
    break :blk paths;
};
var g_bufs: std.EnumArray(Bin, [PATH_MAX:0]u8) = undefined;

/// Take `--bin-dir <dir>` from the rig's argv; call once, before any thread or child starts.
/// @return false, having said why, when a path under `dir` does not fit.
pub fn init(argv: []const [*:0]const u8) bool {
    for (argv, 0..) |a, i| {
        if (i + 1 >= argv.len or !std.mem.eql(u8, std.mem.span(a), "--bin-dir")) continue;
        const dir = std.mem.span(argv[i + 1]);
        for (std.enums.values(Bin)) |bin| {
            const p = std.fmt.bufPrintZ(g_bufs.getPtr(bin), "{s}/{s}", .{ dir, @tagName(bin) }) catch {
                std.debug.print("smoke rig: --bin-dir {s} is too long a path\n", .{dir});
                return false;
            };
            g_paths.set(bin, p.ptr);
        }
    }
    return true;
}

pub fn path(bin: Bin) [*:0]const u8 {
    return g_paths.get(bin);
}

test "bin paths default to the install and follow --bin-dir" {
    const t = std.testing;
    const saved = g_paths;
    defer g_paths = saved;
    try t.expectEqualStrings("zig-out/bin/sketerm-mux", std.mem.span(path(.@"sketerm-mux")));
    const argv = [_][*:0]const u8{ "rig", "--bin-dir", "/x/dev-bin" };
    try t.expect(init(&argv));
    try t.expectEqualStrings("/x/dev-bin/sketerm", std.mem.span(path(.sketerm)));
    try t.expectEqualStrings("/x/dev-bin/sketerm-lsp-stub", std.mem.span(path(.@"sketerm-lsp-stub")));
}
