//! Shared style helpers for the render passes.
//!
//! Both `cell_pass.zig` and `grid_pass.zig` resolve a logical
//! `Color` (default / palette index / direct RGB) to a normalized
//! `[4]f32` vec4. The logic was duplicated; this module centralises
//! it so both passes stay byte-identical.

const std = @import("std");
const Color = @import("../grid/style_pool.zig").Color;

/// Resolve a logical Color against the active palette + defaults to
/// a normalized f32 vec4 (RGBA, components in [0,1]). Honours
/// reverse-video for `.default` colors only — the caller is expected
/// to swap fg/bg explicitly for explicit (palette / rgb) colors.
pub fn colorToVec(
    color: Color,
    is_fg: bool,
    reverse: bool,
    default_fg: [4]f32,
    default_bg: [4]f32,
    palette: *const [256][3]u8,
) [4]f32 {
    return switch (color) {
        .default => if (is_fg != reverse) default_fg else default_bg,
        .palette => |p| .{
            @as(f32, @floatFromInt(palette[p][0])) / 255.0,
            @as(f32, @floatFromInt(palette[p][1])) / 255.0,
            @as(f32, @floatFromInt(palette[p][2])) / 255.0,
            1.0,
        },
        .rgb => |r| .{
            @as(f32, @floatFromInt(r.r)) / 255.0,
            @as(f32, @floatFromInt(r.g)) / 255.0,
            @as(f32, @floatFromInt(r.b)) / 255.0,
            1.0,
        },
    };
}

/// Resolve a Color to a normalized f32 vec4 without considering
/// reverse video — the caller swaps fg/bg explicitly to honour
/// reverse on non-default colors too. Equivalent to
/// `colorToVec(color, is_fg, false, ...)`.
pub fn colorToRGBA(
    color: Color,
    is_fg: bool,
    default_fg: [4]f32,
    default_bg: [4]f32,
    palette: *const [256][3]u8,
) [4]f32 {
    return switch (color) {
        .default => if (is_fg) default_fg else default_bg,
        .palette => |p| .{
            @as(f32, @floatFromInt(palette[p][0])) / 255.0,
            @as(f32, @floatFromInt(palette[p][1])) / 255.0,
            @as(f32, @floatFromInt(palette[p][2])) / 255.0,
            1.0,
        },
        .rgb => |r| .{
            @as(f32, @floatFromInt(r.r)) / 255.0,
            @as(f32, @floatFromInt(r.g)) / 255.0,
            @as(f32, @floatFromInt(r.b)) / 255.0,
            1.0,
        },
    };
}

test "colorToVec default fg/bg respects reverse" {
    const pal: [256][3]u8 = std.mem.zeroes([256][3]u8);
    const fg: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 };
    const bg: [4]f32 = .{ 0.0, 0.0, 0.0, 1.0 };
    try std.testing.expectEqual(fg, colorToVec(.default, true, false, fg, bg, &pal));
    try std.testing.expectEqual(bg, colorToVec(.default, false, false, fg, bg, &pal));
    try std.testing.expectEqual(bg, colorToVec(.default, true, true, fg, bg, &pal));
    try std.testing.expectEqual(fg, colorToVec(.default, false, true, fg, bg, &pal));
}

test "colorToVec palette normalizes 0..255 to 0..1" {
    var pal: [256][3]u8 = std.mem.zeroes([256][3]u8);
    pal[5] = .{ 255, 128, 0 };
    const fg: [4]f32 = .{ 0, 0, 0, 1 };
    const bg: [4]f32 = .{ 0, 0, 0, 1 };
    const v = colorToVec(.{ .palette = 5 }, true, false, fg, bg, &pal);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), v[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), v[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), v[2], 1e-6);
    try std.testing.expectEqual(@as(f32, 1.0), v[3]);
}

test "colorToVec rgb normalizes channels" {
    const pal: [256][3]u8 = std.mem.zeroes([256][3]u8);
    const fg: [4]f32 = .{ 0, 0, 0, 1 };
    const bg: [4]f32 = .{ 0, 0, 0, 1 };
    const v = colorToVec(.{ .rgb = .{ .r = 255, .g = 0, .b = 128 } }, true, false, fg, bg, &pal);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), v[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), v[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), v[2], 1e-6);
    try std.testing.expectEqual(@as(f32, 1.0), v[3]);
}

test "colorToRGBA ignores reverse, picks fg/bg from is_fg only" {
    const pal: [256][3]u8 = std.mem.zeroes([256][3]u8);
    const fg: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 };
    const bg: [4]f32 = .{ 0.0, 0.0, 0.0, 1.0 };
    try std.testing.expectEqual(fg, colorToRGBA(.default, true, fg, bg, &pal));
    try std.testing.expectEqual(bg, colorToRGBA(.default, false, fg, bg, &pal));
}
