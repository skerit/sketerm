//! The environment an untrusted browser helper tree must not inherit, and
//! the values it is pinned to. The launcher (`ipc/webdrive.zig`) filters
//! the child's envp with it before exec, and the helper (`web/main.zig`)
//! applies it to itself again, so a direct launch is held to the same list.

const std = @import("std");

/// Endpoints that would let a compromised page reach the user's desktop,
/// bus, agents or sketerm instances. `SKETERM_WEB_*` tuning knobs stay;
/// every other `SKETERM_*` (sockets, pane/session identity, lifetime fds)
/// goes, as do the helper's own supervisor/presenter arming variables.
pub fn dropped(name: []const u8) bool {
    const exact = [_][]const u8{
        "SKETERM_WEB_SUPERVISED",  "SKETERM_WEB_PRESENTER", "WAYLAND_DISPLAY", "WAYLAND_SOCKET",
        "DISPLAY",                 "XAUTHORITY",            "PULSE_SERVER",    "DBUS_SESSION_BUS_ADDRESS",
        "DBUS_SYSTEM_BUS_ADDRESS", "SSH_AUTH_SOCK",         "GPG_AGENT_INFO",  "XDG_SESSION_TYPE",
    };
    for (exact) |n| if (std.mem.eql(u8, n, name)) return true;
    return std.mem.startsWith(u8, name, "SKETERM_") and !std.mem.startsWith(u8, name, "SKETERM_WEB_");
}

/// Pinned values: software rendering, no GPU process, no display.
pub const sets = [_][2][]const u8{
    .{ "SKETERM_WEB_OZONE", "headless" },
    .{ "SKETERM_WEB_GPU", "0" },
    .{ "LIBGL_ALWAYS_SOFTWARE", "1" },
};

test "untrusted env drops endpoints and sketerm identity but keeps web tuning knobs" {
    for ([_][]const u8{ "SKETERM_MUX_SOCKET", "SKETERM_UNIT_KEEP", "DBUS_SESSION_BUS_ADDRESS", "WAYLAND_DISPLAY", "SSH_AUTH_SOCK", "SKETERM_WEB_SUPERVISED", "SKETERM_WEB_PRESENTER" }) |n|
        try std.testing.expect(dropped(n));
    for ([_][]const u8{ "SKETERM_WEB_WREQ_TIMEOUT_MS", "SKETERM_WEB_GPU", "PATH", "LANG", "SKETERM" }) |n|
        try std.testing.expect(!dropped(n));
}
