//! Auto shell-integration resolution, shared by the GUI (window.zig)
//! and the headless MCP terminal driver (termdrive.zig). Locates the
//! shipped script directory and picks the per-shell injection setup.
//! GTK-free: libc + platform util only.

const std = @import("std");
const c = @import("../c.zig").c;
const platform = @import("platform.zig");

/// Locate the shell-integration script directory: env override →
/// installed share dir next to the exe → repo data/ (dev tree) →
/// /usr/share. Null = feature unavailable. The result aliases `buf`.
pub fn baseDir(buf: *[4096]u8) ?[]const u8 {
    if (c.getenv("SKETERM_SHELL_INTEGRATION_DIR")) |env| {
        const s = std.mem.span(@as([*:0]const u8, @ptrCast(env)));
        if (s.len < buf.len) {
            @memcpy(buf[0..s.len], s);
            return buf[0..s.len];
        }
        return null;
    }
    var exe_buf: [4096]u8 = undefined;
    if (platform.exePath(&exe_buf)) |exe_path| {
        const exe_dir = std.fs.path.dirname(exe_path) orelse "/usr/bin";
        const candidates = [_][]const u8{
            "/../share/sketerm/shell-integration",
            "/../../data/shell-integration",
        };
        for (candidates) |suffix| {
            const cand = std.fmt.bufPrintZ(buf, "{s}{s}/sketerm.zsh", .{ exe_dir, suffix }) catch continue;
            if (c.access(cand.ptr, c.R_OK) == 0) {
                return buf[0 .. exe_dir.len + suffix.len];
            }
        }
    }
    const sys = "/usr/share/sketerm/shell-integration";
    const sys_probe = std.fmt.bufPrintZ(buf, "{s}/sketerm.zsh", .{sys}) catch return null;
    if (c.access(sys_probe.ptr, c.R_OK) == 0) {
        @memcpy(buf[0..sys.len], sys);
        return buf[0..sys.len];
    }
    return null;
}

/// Per-shell injection setup: `kind` is the SpawnReq wire string,
/// `script` the integration script, `shim` the shell-specific
/// injection vehicle (zsh: ZDOTDIR dir; fish: XDG_DATA_DIRS dir;
/// bash: the --rcfile FILE). Strings are allocated; free with
/// `Resolved.deinit`.
pub const Resolved = struct {
    kind: []const u8, // static
    script: [:0]u8,
    shim: [:0]u8,

    pub fn deinit(self: Resolved, allocator: std.mem.Allocator) void {
        allocator.free(self.script);
        allocator.free(self.shim);
    }
};

/// Resolve the auto-integration setup for the shell named by
/// `argv0`, or null for shells we don't auto-integrate (or when the
/// script directory is missing).
pub fn resolve(allocator: std.mem.Allocator, argv0: []const u8) ?Resolved {
    const base_name = std.fs.path.basename(argv0);
    const Setup = struct { kind: []const u8, script: []const u8, shim: []const u8 };
    const setup: Setup = if (std.mem.eql(u8, base_name, "zsh"))
        .{ .kind = "zsh", .script = "sketerm.zsh", .shim = "zsh" }
    else if (std.mem.eql(u8, base_name, "fish"))
        .{ .kind = "fish", .script = "sketerm.fish", .shim = "fish-xdg" }
    else if (std.mem.eql(u8, base_name, "bash"))
        .{ .kind = "bash", .script = "sketerm.bash", .shim = "bash/sketerm-rc.bash" }
    else
        return null;

    var buf: [4096]u8 = undefined;
    const base = baseDir(&buf) orelse return null;
    const script = std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ base, setup.script }, 0) catch return null;
    const shim = std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ base, setup.shim }, 0) catch {
        allocator.free(script);
        return null;
    };
    return .{ .kind = setup.kind, .script = script, .shim = shim };
}

test "resolve picks per-shell setups and rejects unknown shells" {
    const t = std.testing;
    // The dev tree ships the scripts, so resolution succeeds here.
    if (resolve(t.allocator, "/bin/bash")) |r| {
        defer r.deinit(t.allocator);
        try t.expectEqualStrings("bash", r.kind);
        try t.expect(std.mem.endsWith(u8, r.script, "/sketerm.bash"));
        try t.expect(std.mem.endsWith(u8, r.shim, "/bash/sketerm-rc.bash"));
    }
    if (resolve(t.allocator, "zsh")) |r| {
        defer r.deinit(t.allocator);
        try t.expectEqualStrings("zsh", r.kind);
    }
    try t.expectEqual(@as(?Resolved, null), resolve(t.allocator, "/bin/dash"));
}
