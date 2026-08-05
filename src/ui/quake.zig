//! Quake-mode geometry: which monitor a drop-down window targets and
//! how much of it the window covers.
//!
//! Pure — no GTK, no GDK — so the arithmetic is unit-testable. The
//! GDK half (resolving a spec to a `GdkMonitor`, applying the size)
//! lives in `window.zig`.
//!
//! What the platform allows, and what it does not: GTK4 removed
//! toplevel positioning on every backend (`gtk_window_move` is gone)
//! and Wayland forbids a client placing its own toplevel outright, so
//! the `x`/`y` in the rect below is the placement the configured edge
//! WOULD mean. Nothing sketerm can call applies it. Size and monitor
//! targeting are real: `gtk_window_set_default_size` sizes the
//! window, and `gtk_window_fullscreen_on_monitor` is the one call
//! that names a monitor, which is why full coverage takes that path.

const std = @import("std");

pub const Edge = @import("../config.zig").QuakeEdge;

/// Which monitor to drop onto, parsed from `quake_monitor`.
pub const MonitorSpec = union(enum) {
    /// The monitor the window currently sits on.
    active,
    /// GTK4 has no primary-monitor concept; resolves to the
    /// display's first monitor.
    primary,
    index: u32,
    /// Connector name as GDK reports it ("DP-1", "HDMI-A-2").
    connector: []const u8,
};

pub const Rect = struct { x: i32 = 0, y: i32 = 0, w: i32 = 0, h: i32 = 0 };

/// Empty, "active" and anything unrecognised resolve to `.active`.
pub fn parseMonitor(spec: []const u8) MonitorSpec {
    const s = std.mem.trim(u8, spec, " \t");
    if (s.len == 0 or std.mem.eql(u8, s, "active")) return .active;
    if (std.mem.eql(u8, s, "primary")) return .primary;
    if (std.fmt.parseInt(u32, s, 10) catch null) |i| return .{ .index = i };
    return .{ .connector = s };
}

/// The rectangle a quake window wants on `mon`: `width_pct` /
/// `height_pct` of it, pushed against `edge`. Percentages are
/// clamped to 1..100 and the result is at least 1x1.
pub fn geometry(mon: Rect, width_pct: f32, height_pct: f32, edge: Edge) Rect {
    const wp = std.math.clamp(width_pct, 1.0, 100.0) / 100.0;
    const hp = std.math.clamp(height_pct, 1.0, 100.0) / 100.0;
    const w: i32 = @max(1, @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(mon.w)) * wp))));
    const h: i32 = @max(1, @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(mon.h)) * hp))));
    // The axis the edge does not pin stays centred, which is what
    // every quake terminal does with a partial width.
    return switch (edge) {
        .top => .{ .x = mon.x + @divTrunc(mon.w - w, 2), .y = mon.y, .w = w, .h = h },
        .bottom => .{ .x = mon.x + @divTrunc(mon.w - w, 2), .y = mon.y + mon.h - h, .w = w, .h = h },
        .left => .{ .x = mon.x, .y = mon.y + @divTrunc(mon.h - h, 2), .w = w, .h = h },
        .right => .{ .x = mon.x + mon.w - w, .y = mon.y + @divTrunc(mon.h - h, 2), .w = w, .h = h },
    };
}

/// Whether the requested coverage is the whole monitor — the only
/// case GTK can place exactly, via `gtk_window_fullscreen_on_monitor`.
pub fn coversMonitor(width_pct: f32, height_pct: f32) bool {
    return width_pct >= 100.0 and height_pct >= 100.0;
}

const testing = std.testing;

test "parseMonitor covers every form" {
    try testing.expectEqual(MonitorSpec.active, parseMonitor(""));
    try testing.expectEqual(MonitorSpec.active, parseMonitor(" active "));
    try testing.expectEqual(MonitorSpec.primary, parseMonitor("primary"));
    try testing.expectEqual(@as(u32, 2), parseMonitor("2").index);
    try testing.expectEqualStrings("DP-1", parseMonitor("DP-1").connector);
}

test "geometry: full coverage returns the monitor itself" {
    const mon: Rect = .{ .x = 100, .y = 50, .w = 1920, .h = 1080 };
    const r = geometry(mon, 100, 100, .top);
    try testing.expectEqual(mon, r);
    try testing.expect(coversMonitor(100, 100));
}

test "geometry: a top drop is full width, half height, at the top" {
    const mon: Rect = .{ .x = 0, .y = 0, .w = 1920, .h = 1080 };
    const r = geometry(mon, 100, 50, .top);
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 1920, .h = 540 }, r);
}

test "geometry: bottom / left / right anchor against their edge" {
    const mon: Rect = .{ .x = 0, .y = 0, .w = 1000, .h = 800 };
    try testing.expectEqual(Rect{ .x = 0, .y = 600, .w = 1000, .h = 200 }, geometry(mon, 100, 25, .bottom));
    try testing.expectEqual(Rect{ .x = 0, .y = 200, .w = 300, .h = 400 }, geometry(mon, 30, 50, .left));
    try testing.expectEqual(Rect{ .x = 700, .y = 200, .w = 300, .h = 400 }, geometry(mon, 30, 50, .right));
}

test "geometry: a partial width centres on the unpinned axis and honours the offset" {
    const mon: Rect = .{ .x = 1920, .y = 0, .w = 1000, .h = 800 };
    const r = geometry(mon, 50, 40, .top);
    try testing.expectEqual(Rect{ .x = 2170, .y = 0, .w = 500, .h = 320 }, r);
}

test "geometry: out-of-range percentages clamp instead of collapsing" {
    const mon: Rect = .{ .w = 800, .h = 600 };
    try testing.expectEqual(@as(i32, 8), geometry(mon, 0, 0, .top).w);
    try testing.expectEqual(@as(i32, 600), geometry(mon, 999, 999, .top).h);
    try testing.expect(!coversMonitor(100, 99));
}
