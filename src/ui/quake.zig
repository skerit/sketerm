//! Quake-mode placement: which monitor a drop-down window targets,
//! how much of it the window covers, and which edge it hangs from.
//!
//! Pure -- no GTK, no GDK -- so the arithmetic is unit-testable. The
//! GDK half (resolving a spec to a `GdkMonitor`, driving the layer
//! surface or the toplevel) lives in `winquake.zig`.
//!
//! Two paths consume one `Placement`. With wlr-layer-shell (KWin,
//! wlroots compositors; `gtk_layer_is_supported` decides at runtime)
//! the primary window is a layer surface and the edge, the monitor
//! and the size are all applied exactly: the configured edge is
//! anchored, a 100% axis anchors both of its edges (the compositor
//! stretches the surface between them), and the protocol centres a
//! surface anchored to a single edge along it, which is the
//! "centred on the unpinned axis" every quake terminal does. Without
//! layer-shell (GNOME, X11, a compositor without the protocol) the
//! window stays an xdg-toplevel, which GTK4 cannot position on any
//! backend and Wayland forbids placing outright: only the size is
//! applied, plus `gtk_window_fullscreen_on_monitor` at full coverage
//! (the one GTK4 call that names a monitor). `Placement.rect` is the
//! placement the edge means on that path; nothing there can apply its
//! x/y.

const std = @import("std");

const config_mod = @import("../config.zig");
pub const Edge = config_mod.QuakeEdge;
const Config = config_mod.Config;

/// Which monitor to drop onto, parsed from `quake_monitor`.
pub const MonitorSpec = union(enum) {
    /// The monitor the window currently sits on. Under layer-shell
    /// this is the compositor's own choice (a null output), which is
    /// the focused output on KWin and wlroots.
    active,
    /// GTK4 has no primary-monitor concept; resolves to the
    /// display's first monitor.
    primary,
    index: u32,
    /// Connector name as GDK reports it ("DP-1", "HDMI-A-2").
    connector: []const u8,
};

pub const Rect = struct { x: i32 = 0, y: i32 = 0, w: i32 = 0, h: i32 = 0 };

/// One flag per monitor edge, in wlr-layer-shell's terms: anchoring
/// opposite edges stretches the surface between them, anchoring one
/// edge centres the surface along it.
pub const Anchors = struct {
    left: bool = false,
    right: bool = false,
    top: bool = false,
    bottom: bool = false,

    /// Every edge anchored: the surface is the whole monitor.
    pub fn full(self: Anchors) bool {
        return self.left and self.right and self.top and self.bottom;
    }
};

/// One placement in the two vocabularies the two paths speak. `rect`
/// is the target in monitor coordinates (the fallback applies its
/// size only); `anchors` plus `layer_w`/`layer_h` are the layer-shell
/// request that produces the same rect, with 0 on an axis the anchors
/// stretch, since a size request on a stretched axis is ignored.
pub const Placement = struct {
    rect: Rect,
    anchors: Anchors,
    layer_w: i32,
    layer_h: i32,

    /// Whole-monitor coverage: the fallback's fullscreen case.
    pub fn coversMonitor(self: Placement) bool {
        return self.anchors.full();
    }
};

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

/// `geometry` plus the layer-shell request that yields it. Fullness
/// is decided on pixels, not percentages: a percentage that rounds to
/// the monitor's width IS full width, and anchoring both edges then
/// asks the compositor for exactly what the rect says.
pub fn place(mon: Rect, width_pct: f32, height_pct: f32, edge: Edge) Placement {
    const rect = geometry(mon, width_pct, height_pct, edge);
    const full_w = rect.w >= mon.w;
    const full_h = rect.h >= mon.h;
    var anchors: Anchors = .{};
    switch (edge) {
        .top => anchors.top = true,
        .bottom => anchors.bottom = true,
        .left => anchors.left = true,
        .right => anchors.right = true,
    }
    if (full_w) {
        anchors.left = true;
        anchors.right = true;
    }
    if (full_h) {
        anchors.top = true;
        anchors.bottom = true;
    }
    return .{
        .rect = rect,
        .anchors = anchors,
        .layer_w = if (full_w) 0 else rect.w,
        .layer_h = if (full_h) 0 else rect.h,
    };
}

/// Whether a config apply moved any `quake_*` key, so the window
/// re-places itself only then (a font-size reload must not remap a
/// layer surface or re-force a fallback window's size).
pub fn settingsChanged(old: *const Config, new: *const Config) bool {
    return old.quake_enabled != new.quake_enabled or
        old.quake_edge != new.quake_edge or
        old.quake_width_percent != new.quake_width_percent or
        old.quake_height_percent != new.quake_height_percent or
        !std.mem.eql(u8, old.quake_monitor, new.quake_monitor);
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
    try testing.expect(place(mon, 100, 100, .top).coversMonitor());
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
    try testing.expect(!place(mon, 100, 99, .top).coversMonitor());
}

test "place: a partial drop anchors its edge only and requests both sizes" {
    const mon: Rect = .{ .x = 0, .y = 0, .w = 1000, .h = 800 };
    const top = place(mon, 60, 40, .top);
    try testing.expectEqual(Anchors{ .top = true }, top.anchors);
    try testing.expectEqual(@as(i32, 600), top.layer_w);
    try testing.expectEqual(@as(i32, 320), top.layer_h);
    try testing.expectEqual(geometry(mon, 60, 40, .top), top.rect);
    try testing.expectEqual(Anchors{ .bottom = true }, place(mon, 60, 40, .bottom).anchors);
    try testing.expectEqual(Anchors{ .left = true }, place(mon, 60, 40, .left).anchors);
    try testing.expectEqual(Anchors{ .right = true }, place(mon, 60, 40, .right).anchors);
    try testing.expect(!top.coversMonitor());
}

test "place: a full axis anchors both of its edges and leaves that size to the compositor" {
    const mon: Rect = .{ .x = 0, .y = 0, .w = 1920, .h = 1080 };
    const top = place(mon, 100, 50, .top);
    try testing.expectEqual(Anchors{ .left = true, .right = true, .top = true }, top.anchors);
    try testing.expectEqual(@as(i32, 0), top.layer_w);
    try testing.expectEqual(@as(i32, 540), top.layer_h);
    try testing.expect(!top.coversMonitor());
    const left = place(mon, 30, 100, .left);
    try testing.expectEqual(Anchors{ .left = true, .top = true, .bottom = true }, left.anchors);
    try testing.expectEqual(@as(i32, 576), left.layer_w);
    try testing.expectEqual(@as(i32, 0), left.layer_h);
    const bottom = place(mon, 100, 100, .bottom);
    try testing.expectEqual(Anchors{ .left = true, .right = true, .top = true, .bottom = true }, bottom.anchors);
    try testing.expectEqual(@as(i32, 0), bottom.layer_w);
    try testing.expectEqual(@as(i32, 0), bottom.layer_h);
    try testing.expect(bottom.coversMonitor());
}

test "place: clamps follow geometry, so 0% is 1% and 999% is full" {
    const mon: Rect = .{ .w = 800, .h = 600 };
    const tiny = place(mon, 0, 0, .right);
    try testing.expectEqual(Anchors{ .right = true }, tiny.anchors);
    try testing.expectEqual(@as(i32, 8), tiny.layer_w);
    try testing.expectEqual(@as(i32, 6), tiny.layer_h);
    const huge = place(mon, 999, 999, .right);
    try testing.expect(huge.coversMonitor());
    // Fullness is a pixel fact: a width that rounds up to the
    // monitor's is anchored to both sides like an exact 100.
    try testing.expect(place(mon, 99.99, 50, .top).anchors.right);
}

test "settingsChanged: only the five quake keys count" {
    var a: Config = .{};
    var b: Config = .{};
    try testing.expect(!settingsChanged(&a, &b));
    b.settings.font_size = a.settings.font_size + 1;
    try testing.expect(!settingsChanged(&a, &b));
    b.quake_enabled = true;
    try testing.expect(settingsChanged(&a, &b));
    b = .{};
    b.quake_edge = .bottom;
    try testing.expect(settingsChanged(&a, &b));
    b = .{};
    b.quake_width_percent = 80;
    try testing.expect(settingsChanged(&a, &b));
    b = .{};
    b.quake_height_percent = 80;
    try testing.expect(settingsChanged(&a, &b));
    b = .{};
    b.quake_monitor = "DP-1";
    try testing.expect(settingsChanged(&a, &b));
    a.quake_monitor = "DP-1";
    try testing.expect(!settingsChanged(&a, &b));
}
