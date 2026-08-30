//! Letterbox geometry for an OBSERVED browser view (capability
//! "observe"): the frame arrives at the OWNER's size and the watching
//! pane is whatever size it is, so the frame is fitted inside the area
//! (never stretched, never upscaled past 1:1) and pointer input is
//! mapped back into the owner's logical coordinates. Pure, so the GUI
//! face and the rigs share one formula; the unit tests below are the
//! contract.

const std = @import("std");

/// Where a `frame_w x frame_h` frame sits inside an `area_w x area_h`
/// widget: offset, drawn size, and the drawn/frame ratio.
pub const Fit = struct {
    x: u16,
    y: u16,
    w: u16,
    h: u16,
    /// Drawn pixels per frame pixel, in (0, 1].
    scale: f64,

    /// Widget-space point -> frame-space point, clamped to the frame.
    pub fn toFrame(self: Fit, px: f64, py: f64, frame_w: u16, frame_h: u16) struct { x: i32, y: i32 } {
        const fx = (px - @as(f64, @floatFromInt(self.x))) / self.scale;
        const fy = (py - @as(f64, @floatFromInt(self.y))) / self.scale;
        const max_x: f64 = @floatFromInt(@as(u32, frame_w) -| 1);
        const max_y: f64 = @floatFromInt(@as(u32, frame_h) -| 1);
        return .{
            .x = @intFromFloat(@round(std.math.clamp(fx, 0, max_x))),
            .y = @intFromFloat(@round(std.math.clamp(fy, 0, max_y))),
        };
    }
};

/// Fit `frame_w x frame_h` into `area_w x area_h`, centred, shrinking
/// uniformly when it does not fit and never enlarging (1:1 texels stay
/// 1:1 whenever there is room). A zero dimension anywhere yields a
/// zero-sized fit at the origin.
pub fn fit(area_w: u16, area_h: u16, frame_w: u16, frame_h: u16) Fit {
    if (area_w == 0 or area_h == 0 or frame_w == 0 or frame_h == 0)
        return .{ .x = 0, .y = 0, .w = 0, .h = 0, .scale = 1 };
    const sx = @as(f64, @floatFromInt(area_w)) / @as(f64, @floatFromInt(frame_w));
    const sy = @as(f64, @floatFromInt(area_h)) / @as(f64, @floatFromInt(frame_h));
    const s = @min(@min(sx, sy), 1.0);
    const w: u16 = @intFromFloat(@max(1, @floor(@as(f64, @floatFromInt(frame_w)) * s)));
    const h: u16 = @intFromFloat(@max(1, @floor(@as(f64, @floatFromInt(frame_h)) * s)));
    return .{
        .x = (area_w - @min(w, area_w)) / 2,
        .y = (area_h - @min(h, area_h)) / 2,
        .w = w,
        .h = h,
        // The ratio the DRAWN size realises, so pointer mapping and
        // the picture agree exactly rather than through two roundings.
        .scale = @as(f64, @floatFromInt(w)) / @as(f64, @floatFromInt(frame_w)),
    };
}

test "a frame that fits is drawn 1:1 and centred" {
    const f = fit(1000, 800, 640, 480);
    try std.testing.expectEqual(@as(u16, 640), f.w);
    try std.testing.expectEqual(@as(u16, 480), f.h);
    try std.testing.expectEqual(@as(u16, 180), f.x);
    try std.testing.expectEqual(@as(u16, 160), f.y);
    try std.testing.expectApproxEqAbs(@as(f64, 1), f.scale, 1e-9);
    const p = f.toFrame(180 + 10, 160 + 20, 640, 480);
    try std.testing.expectEqual(@as(i32, 10), p.x);
    try std.testing.expectEqual(@as(i32, 20), p.y);
}

test "a frame wider than the area shrinks uniformly and input scales back" {
    const f = fit(500, 500, 1000, 400);
    try std.testing.expectEqual(@as(u16, 500), f.w);
    try std.testing.expectEqual(@as(u16, 200), f.h);
    try std.testing.expectEqual(@as(u16, 0), f.x);
    try std.testing.expectEqual(@as(u16, 150), f.y);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), f.scale, 1e-9);
    const p = f.toFrame(250, 250, 1000, 400);
    try std.testing.expectEqual(@as(i32, 500), p.x);
    try std.testing.expectEqual(@as(i32, 200), p.y);
}

test "points outside the drawn frame clamp to its edges" {
    const f = fit(300, 300, 100, 100);
    const p = f.toFrame(0, 299, 100, 100);
    try std.testing.expectEqual(@as(i32, 0), p.x);
    try std.testing.expectEqual(@as(i32, 99), p.y);
}

test "a degenerate size fits to nothing rather than dividing by zero" {
    const f = fit(0, 100, 100, 100);
    try std.testing.expectEqual(@as(u16, 0), f.w);
    const g = fit(100, 100, 0, 100);
    try std.testing.expectEqual(@as(u16, 0), g.w);
}
