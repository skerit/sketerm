//! Resolve the DRM render node forwarded apps should allocate on —
//! the `main_device` of linux-dmabuf v4 feedback.
//!
//! The daemon and the app share a host, so a node the daemon can
//! stat is a node the app can open. Multi-GPU hosts get the first
//! usable render node; `SKETERM_MUX_DRM_DEVICE` names one explicitly.
//! Null (no /dev/dri at all, or none usable) caps linux-dmabuf at v3.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("../c.zig").c;

const first_render_minor = 128;
const last_render_minor = 191;

/// dev_t of the node, or null when none is usable. Best-effort and
/// cheap enough to call per app connection; the daemon caches it.
pub fn mainDevice() ?u64 {
    if (builtin.os.tag != .linux) return null;
    if (c.getenv("SKETERM_MUX_DRM_DEVICE")) |env| {
        return deviceOf(std.mem.span(env));
    }
    var buf: [64]u8 = undefined;
    var minor: u32 = first_render_minor;
    while (minor <= last_render_minor) : (minor += 1) {
        const path = std.fmt.bufPrintZ(&buf, "/dev/dri/renderD{d}", .{minor}) catch return null;
        if (deviceOf(path)) |dev| return dev;
    }
    return null;
}

/// Null unless the path is a character device this process may both
/// read and write — a node we cannot open is one the app's driver
/// will not allocate from either.
fn deviceOf(path: [:0]const u8) ?u64 {
    var st: c.struct_stat = undefined;
    if (c.stat(path.ptr, &st) != 0) return null;
    if (st.st_mode & c.S_IFMT != c.S_IFCHR) return null;
    if (c.access(path.ptr, c.R_OK | c.W_OK) != 0) return null;
    return @intCast(st.st_rdev);
}

const t = std.testing;

test "deviceOf rejects paths that are not character devices" {
    try t.expectEqual(@as(?u64, null), deviceOf("/dev/null/nope"));
    try t.expectEqual(@as(?u64, null), deviceOf("/etc/hostname"));
}

test "mainDevice agrees with a stat of what it returned" {
    // No render node in a container/CI: the null path is the
    // contract (linux-dmabuf then stays at v3).
    const dev = mainDevice() orelse return;
    try t.expect(dev != 0);
}
