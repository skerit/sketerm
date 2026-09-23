//! Drift guard for vendor/aro_shims.
//!
//! The gdk version-macros shim is a verbatim copy of the system
//! header with only the "#error Only <gdk/gdk.h>..." guard removed;
//! a GTK upgrade can silently change the original. Everything after
//! `#pragma once` must stay byte-identical (bar the GDK_MICRO_VERSION
//! line, which every patch release bumps), or this test fails and
//! the shim needs re-syncing (keep the guard removed).

const std = @import("std");
const c = @import("c.zig").c;
const pathZ = @import("util/pathz.zig").pathZ;

const SHIM = "vendor/aro_shims/gdk/version/gdkversionmacros.h";
const SYSTEM = "/usr/include/gtk-4.0/gdk/version/gdkversionmacros.h";

fn readAll(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    var buf: [4096]u8 = undefined;
    const fp = c.fopen(try pathZ(&buf, path), "rb") orelse return null;
    defer _ = c.fclose(fp);
    if (c.fseek(fp, 0, c.SEEK_END) != 0) return error.ReadFailed;
    const size_long = c.ftell(fp);
    if (size_long < 0 or size_long > 1024 * 1024) return error.ReadFailed;
    if (c.fseek(fp, 0, c.SEEK_SET) != 0) return error.ReadFailed;
    const size: usize = @intCast(size_long);
    const out = try allocator.alloc(u8, size);
    errdefer allocator.free(out);
    if (c.fread(out.ptr, 1, size, fp) != size) return error.ReadFailed;
    return out;
}

fn afterPragmaOnce(body: []const u8) ?[]const u8 {
    // Anchor on line start — the shim's banner comment mentions the
    // directive in prose, which a plain indexOf would match first.
    const idx = std.mem.indexOf(u8, body, "\n#pragma once") orelse return null;
    const nl = std.mem.indexOfScalarPos(u8, body, idx + 1, '\n') orelse return null;
    return body[nl + 1 ..];
}

/// Line-wise equality that skips the GDK_MICRO_VERSION define: a GTK
/// patch release bumps only that number, and no version macro keys on it
/// (major/minor still gate GDK_VERSION_4_x, so they must match).
fn sameIgnoringMicro(a: []const u8, b: []const u8) bool {
    const micro = "#define GDK_MICRO_VERSION";
    var ia = std.mem.splitScalar(u8, a, '\n');
    var ib = std.mem.splitScalar(u8, b, '\n');
    while (true) {
        const la = ia.next();
        const lb = ib.next();
        if (la == null or lb == null) return la == null and lb == null;
        if (std.mem.startsWith(u8, la.?, micro) and std.mem.startsWith(u8, lb.?, micro)) continue;
        if (!std.mem.eql(u8, la.?, lb.?)) return false;
    }
}

test "shim drift check ignores only the micro version" {
    try std.testing.expect(sameIgnoringMicro("x\n#define GDK_MICRO_VERSION (4)\ny", "x\n#define GDK_MICRO_VERSION (5)\ny"));
    try std.testing.expect(!sameIgnoringMicro("#define GDK_MINOR_VERSION (22)", "#define GDK_MINOR_VERSION (24)"));
    try std.testing.expect(!sameIgnoringMicro("x\ny", "x"));
}

test "gdk version-macros shim has not drifted from the system header" {
    const allocator = std.testing.allocator;
    const shim = try readAll(allocator, SHIM) orelse return error.SkipZigTest;
    defer allocator.free(shim);
    const system = try readAll(allocator, SYSTEM) orelse return error.SkipZigTest;
    defer allocator.free(system);

    var shim_body = afterPragmaOnce(shim) orelse return error.MissingPragmaOnce;
    // The shim wraps itself in #ifndef __SKETERM_SHIM_…/#endif (Aro
    // reprocesses text before `#pragma once`); drop the trailing #endif.
    if (std.mem.lastIndexOf(u8, shim_body, "#endif /* __SKETERM_SHIM")) |idx| {
        shim_body = std.mem.trimEnd(u8, shim_body[0..idx], "\n");
    }
    var system_body = afterPragmaOnce(system) orelse return error.MissingPragmaOnce;
    system_body = std.mem.trimEnd(u8, system_body, "\n");
    if (!sameIgnoringMicro(shim_body, system_body)) {
        std.debug.print(
            "\n{s} drifted from {s}: re-copy the body after `#pragma once` (keep the #error guard removed above it)\n",
            .{ SHIM, SYSTEM },
        );
        return error.ShimDrifted;
    }
}
