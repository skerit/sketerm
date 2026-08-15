//! Pure ozone-platform decision for `sketerm-webengine` — extracted
//! from main.zig's buildCefArgv so the choice is testable without CEF.
//!
//! `SKETERM_WEB_OZONE=wayland` is how webdrive forces the helper onto a
//! mux session's Wayland display even on a GPU-less host: the render
//! node veto is skipped, and with the GPU off the browser gets
//! `--disable-gpu` so frames stay on the software shm path (webdrive
//! cannot consume dma-buf frames). An unreachable compositor still
//! falls back to headless — wayland ozone is not
//! optional-with-fallback inside Chromium, and a wrong pick costs the
//! whole process.

const std = @import("std");

pub const Choice = struct {
    platform: []const u8,
    /// Append `--disable-gpu`: a forced-wayland software helper must
    /// not spawn a GPU process whose dma-buf frames nobody can read.
    disable_gpu: bool = false,
    /// What cefhost.setAccelerated is handed.
    accelerated: bool = false,
};

/// @param explicit an `--ozone-platform=` value already on argv (wins,
///        passed through untouched — the smoke rig pins modes this way)
/// @param env_override `$SKETERM_WEB_OZONE`, or null
/// @param gpu_wanted `$SKETERM_WEB_GPU` != off
/// @param wayland_reachable a real connect() succeeded
/// @param render_node a /dev/dri/renderD* opened
pub fn choose(
    explicit: ?[]const u8,
    env_override: ?[]const u8,
    gpu_wanted: bool,
    wayland_reachable: bool,
    render_node: bool,
) Choice {
    if (explicit) |p| return .{ .platform = p, .accelerated = std.mem.eql(u8, p, "wayland") };
    if (env_override) |o| {
        if (std.mem.eql(u8, o, "wayland") and wayland_reachable)
            return .{ .platform = "wayland", .disable_gpu = !gpu_wanted, .accelerated = gpu_wanted };
        if (std.mem.eql(u8, o, "headless"))
            return .{ .platform = "headless" };
        // Unknown value, or a forced compositor that is gone: probe.
    }
    if (gpu_wanted and wayland_reachable and render_node)
        return .{ .platform = "wayland", .accelerated = true };
    return .{ .platform = "headless" };
}

test "explicit --ozone-platform wins untouched" {
    const t = std.testing;
    const x11 = choose("x11", "wayland", true, true, true);
    try t.expectEqualStrings("x11", x11.platform);
    try t.expect(!x11.accelerated and !x11.disable_gpu);
    const wl = choose("wayland", null, false, false, false);
    try t.expect(wl.accelerated);
}

test "forced session mode reaches wayland without a render node, GPU-less" {
    const t = std.testing;
    const soft = choose(null, "wayland", false, true, false);
    try t.expectEqualStrings("wayland", soft.platform);
    try t.expect(soft.disable_gpu and !soft.accelerated);
    const gpu = choose(null, "wayland", true, true, false);
    try t.expect(gpu.accelerated and !gpu.disable_gpu);
}

test "a forced compositor that is unreachable falls back to the probe chain" {
    const t = std.testing;
    const gone = choose(null, "wayland", true, false, false);
    try t.expectEqualStrings("headless", gone.platform);
    const forced_off = choose(null, "headless", true, true, true);
    try t.expectEqualStrings("headless", forced_off.platform);
}

test "the default probe chain is unchanged" {
    const t = std.testing;
    const full = choose(null, null, true, true, true);
    try t.expectEqualStrings("wayland", full.platform);
    try t.expect(full.accelerated and !full.disable_gpu);
    try t.expectEqualStrings("headless", choose(null, null, true, true, false).platform);
    try t.expectEqualStrings("headless", choose(null, null, false, true, true).platform);
    try t.expectEqualStrings("headless", choose(null, null, true, false, true).platform);
}
