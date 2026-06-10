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

/// WCAG relative luminance of a normalized sRGB color.
fn relativeLuminance(rgba: [4]f32) f32 {
    var lin: [3]f32 = undefined;
    for (0..3) |i| {
        const ch = rgba[i];
        lin[i] = if (ch <= 0.04045) ch / 12.92 else std.math.pow(f32, (ch + 0.055) / 1.055, 2.4);
    }
    return 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2];
}

/// WCAG contrast ratio between two colors, in [1, 21].
pub fn contrastRatio(a: [4]f32, b: [4]f32) f32 {
    const la = relativeLuminance(a);
    const lb = relativeLuminance(b);
    const hi = @max(la, lb);
    const lo = @min(la, lb);
    return (hi + 0.05) / (lo + 0.05);
}

/// Enforce a minimum WCAG contrast ratio between fg and bg.
/// Below the threshold, fg snaps to white or black — whichever
/// contrasts more against bg — keeping fg's alpha. `min_ratio`
/// <= 1.0 disables the check (1.0 is the ratio of identical
/// colors, so nothing can fall below it).
pub fn applyMinContrast(fg: [4]f32, bg: [4]f32, min_ratio: f32) [4]f32 {
    if (min_ratio <= 1.0) return fg;
    if (contrastRatio(fg, bg) >= min_ratio) return fg;
    const white: [4]f32 = .{ 1.0, 1.0, 1.0, fg[3] };
    const black: [4]f32 = .{ 0.0, 0.0, 0.0, fg[3] };
    return if (contrastRatio(white, bg) >= contrastRatio(black, bg)) white else black;
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

test "contrastRatio black vs white is 21" {
    const w: [4]f32 = .{ 1, 1, 1, 1 };
    const b: [4]f32 = .{ 0, 0, 0, 1 };
    try std.testing.expectApproxEqAbs(@as(f32, 21.0), contrastRatio(w, b), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), contrastRatio(w, w), 1e-6);
}

test "applyMinContrast snaps low-contrast fg, keeps alpha" {
    const bg: [4]f32 = .{ 0.10, 0.10, 0.10, 1.0 };
    const fg: [4]f32 = .{ 0.12, 0.12, 0.12, 0.9 }; // near-invisible on bg
    const out = applyMinContrast(fg, bg, 3.0);
    try std.testing.expectEqual(@as(f32, 1.0), out[0]); // snapped to white
    try std.testing.expectEqual(@as(f32, 0.9), out[3]);
    // Already-readable fg passes through untouched.
    const good: [4]f32 = .{ 0.9, 0.9, 0.9, 1.0 };
    try std.testing.expectEqual(good, applyMinContrast(good, bg, 3.0));
    // Disabled threshold is a no-op.
    try std.testing.expectEqual(fg, applyMinContrast(fg, bg, 1.0));
}

test "colorToRGBA ignores reverse, picks fg/bg from is_fg only" {
    const pal: [256][3]u8 = std.mem.zeroes([256][3]u8);
    const fg: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 };
    const bg: [4]f32 = .{ 0.0, 0.0, 0.0, 1.0 };
    try std.testing.expectEqual(fg, colorToRGBA(.default, true, fg, bg, &pal));
    try std.testing.expectEqual(bg, colorToRGBA(.default, false, fg, bg, &pal));
}
