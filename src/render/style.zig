//! Shared style helpers for the render passes.
//!
//! Both `cell_pass.zig` and `grid_pass.zig` resolve a logical
//! `Color` (default / palette index / direct RGB) to a normalized
//! `[4]f32` vec4. The logic was duplicated; this module centralises
//! it so both passes stay byte-identical.

const std = @import("std");
const Color = @import("../grid/style_pool.zig").Color;
const Attrs = @import("../grid/style_pool.zig").Attrs;

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

// ── Line-decoration geometry ────────────────────────────────────────
//
// SGR line decorations are drawn by TWO passes: `cell_pass.zig`
// rasterises them in-shader for plain rows, `grid_pass.zig` emits flat
// quads for overlay rows (bidi / complex script / DW-DH). The same
// text therefore has to get the same underline on either path, so the
// geometry has exactly ONE home: the constants below, the `deco*`
// functions built on them, and `DECO_GLSL` — a GLSL mirror generated
// from those very constants, so the shader cannot drift from the CPU
// side.
//
// All of it is expressed in cell-local pixels: `y` counts DOWN from
// the cell's top edge, `ch` is the cell height.
//
// Policy, chosen once (the two passes previously disagreed on every
// line of it):
//
//   thickness  `max(1, round(ch/14))`. The old CellPass rule
//              (`max(2, ch/12)`) never draws thinner than 2px, which
//              is a heavy slab under a 14px font (ch ~ 17) and reads
//              as bold-underline everywhere; ch/14 tracks the ~1/14em
//              stem weight fonts themselves report and lands on 1px
//              up to ch = 20, 2px through ch = 34, 3px beyond — the
//              same 1/2/3 progression as font-metric-driven
//              renderers. Rounding (instead of the old raw divide)
//              keeps the strip on whole pixels so a line is crisp and
//              both passes rasterise identical rows.
//
//   underline  Bottom-aligned with a 1px clearance:
//   position   `y = ch - thin - 1`. Flush against the cell bottom
//              (the old CellPass rule) makes the underlines of two
//              vertically adjacent underlined rows touch the row
//              boundary and read as one thick band; the clearance
//              also keeps the line off the descender of the row
//              below. Fully inside the cell by construction.
//
//   double     Two `thin` lines separated by a `thin` gap, the LOWER
//              one sitting exactly where the single underline sits.
//              That makes the strip 3*thin tall, i.e. exact thirds —
//              which is why the fragment shader can split it at 1/3
//              and 2/3 and get the two sub-lines for free.
//
//   strike     Centred on `0.55 * ch`. For a typical monospace face
//              the baseline sits near 0.78*ch and the x-height is
//              about 0.42*ch, putting the middle of lowercase at
//              ~0.57*ch: 0.55 crosses lowercase letters through their
//              middle, while the old GridPass 0.5 rides above them
//              and clips into ascenders.
//
//   curly      The wave needs vertical room, so its strip is
//              `max(CURLY_STRIP_MIN_PX, round(ch/CURLY_STRIP_DIV))`
//              tall, bottom-aligned with the same 1px clearance (the
//              strip used to sit flush; the clearance is the same
//              argument as for the straight underline). Both passes
//              rasterise the wave itself through `sk_curlyCoverage`,
//              so amplitude, period and phase are shared too.

/// Line-decoration kind. The numeric values are the `a_deco` vertex
/// attribute CellPass ships to its shader; keep them in sync with the
/// `sk_decoStrip` branches in `DECO_GLSL`.
pub const Deco = enum(u8) {
    none = 0,
    underline = 1,
    double_underline = 2,
    curly = 3,
    strikethrough = 4,
    overline = 5,
};

/// A decoration strip in cell-local pixels: `y` from the cell top.
pub const DecoRect = struct { y: f32, h: f32 };

/// The single decoration a one-strip-per-cell pass draws for these
/// attributes, most specific first. CellPass ships exactly one strip
/// per cell, so a cell that is both underlined and struck through
/// shows the underline there; GridPass, which emits independent
/// quads, draws both.
pub fn decoKind(attrs: Attrs) Deco {
    if (attrs.curly_underline) return .curly;
    if (attrs.double_underline) return .double_underline;
    if (attrs.underline) return .underline;
    if (attrs.strikethrough) return .strikethrough;
    if (attrs.overline) return .overline;
    return .none;
}

/// Cell height per unit of decoration thickness.
pub const deco_thin_divisor: f32 = 14.0;
/// Pixels kept clear between an underline and the cell's bottom edge.
pub const deco_bottom_gap: f32 = 1.0;
/// Gap between the two sub-lines of a double underline, in `thin`s.
pub const deco_double_gap_thins: f32 = 1.0;
/// Fraction of the cell height the strikethrough is centred on.
pub const deco_strike_center: f32 = 0.55;
/// Floor on the curly strip height — below it the wave has no room.
pub const CURLY_STRIP_MIN_PX: f32 = 3.0;
/// Cell height per unit of curly-underline strip height.
pub const CURLY_STRIP_DIV: f32 = 6.0;
/// Wave amplitude as a fraction of the strip height (0.5 = full).
pub const CURLY_AMPLITUDE: f32 = 0.45;
/// Stroke thickness of the wave, in pixels.
pub const CURLY_THICKNESS_PX: f32 = 1.5;

/// Round half away from zero. Spelled `@floor(x + 0.5)` rather than
/// `@round` because GLSL's `round()` picks its .5 direction per
/// implementation, and the GLSL mirror has to agree exactly.
fn decoRound(x: f32) f32 {
    return @floor(x + 0.5);
}

/// Thickness of a thin decoration line (under / strike / over), px.
pub fn decoThin(ch: f32) f32 {
    return @max(1.0, decoRound(ch / deco_thin_divisor));
}

/// Height of the strip a curly underline waves inside, px.
pub fn curlyStripHeight(cell_h: f32) f32 {
    return @max(CURLY_STRIP_MIN_PX, decoRound(cell_h / CURLY_STRIP_DIV));
}

/// The strip a decoration occupies within its cell. For every kind
/// but `.double_underline` and `.curly` the strip IS the drawn line;
/// for those two it is the band the shader rasterises inside.
pub fn decoStrip(kind: Deco, ch: f32) DecoRect {
    const thin = decoThin(ch);
    return switch (kind) {
        .none => .{ .y = 0, .h = 0 },
        .underline => .{ .y = @max(0.0, ch - thin - deco_bottom_gap), .h = thin },
        .double_underline => blk: {
            const h = (2.0 + deco_double_gap_thins) * thin;
            break :blk .{ .y = @max(0.0, ch - h - deco_bottom_gap), .h = h };
        },
        .curly => blk: {
            const h = curlyStripHeight(ch);
            break :blk .{ .y = @max(0.0, ch - h - deco_bottom_gap), .h = h };
        },
        .strikethrough => .{ .y = decoRound(ch * deco_strike_center - thin * 0.5), .h = thin },
        .overline => .{ .y = 0, .h = thin },
    };
}

/// The two sub-lines of a double underline, top one first. Equivalent
/// to splitting `decoStrip(.double_underline, ch)` the way the
/// CellPass fragment shader does.
pub fn decoDoubleLines(ch: f32) [2]DecoRect {
    const thin = decoThin(ch);
    const strip = decoStrip(.double_underline, ch);
    return .{
        .{ .y = strip.y, .h = thin },
        .{ .y = strip.y + strip.h - thin, .h = thin },
    };
}

/// GLSL mirror of the geometry above, generated from the same
/// constants. Prepended to BOTH shader pairs: the CellPass vertex
/// stage places its strip with `sk_decoStrip`, both fragment stages
/// split the double underline at `SK_DECO_DOUBLE_LO/HI` and draw the
/// undercurl with `sk_curlyCoverage`. Carries no `#version` line:
/// `gl.zig compileShader` injects the per-API header.
///
/// `sk_curlyCoverage` returns UN-corrected edge coverage in [0,1]; 0
/// means the fragment is off the wave and the caller should discard.
/// The caller applies `sk_correctCoverage` itself, since only it
/// knows its bg. The wave phase restarts at every cell (local x), so
/// both passes share the per-cell phase and a row rendered half by
/// CellPass and half by GridPass matches.
pub const DECO_GLSL = std.fmt.comptimePrint(
    \\const float SK_DECO_THIN_DIV = {d:.6};
    \\const float SK_DECO_BOTTOM_GAP = {d:.6};
    \\const float SK_DECO_DOUBLE_GAP = {d:.6};
    \\const float SK_DECO_STRIKE_CENTER = {d:.6};
    \\const float SK_CURLY_STRIP_MIN_PX = {d:.6};
    \\const float SK_CURLY_STRIP_DIV = {d:.6};
    \\const float SK_CURLY_AMPLITUDE = {d:.6};
    \\const float SK_CURLY_THICKNESS_PX = {d:.6};
    \\const float SK_WAVE_TWO_PI = 6.2831853;
    \\// Thirds of the double-underline strip: [0, LO) is the upper
    \\// sub-line, [LO, HI) the gap, [HI, 1] the lower sub-line.
    \\const float SK_DECO_DOUBLE_LO = {d:.6};
    \\const float SK_DECO_DOUBLE_HI = {d:.6};
    \\
    \\float sk_decoRound(float x) {{ return floor(x + 0.5); }}
    \\float sk_decoThin(float ch) {{ return max(1.0, sk_decoRound(ch / SK_DECO_THIN_DIV)); }}
    \\float sk_curlyStripH(float cell_h) {{
    \\    return max(SK_CURLY_STRIP_MIN_PX, sk_decoRound(cell_h / SK_CURLY_STRIP_DIV));
    \\}}
    \\
    \\float sk_curlyCoverage(vec2 local, float cell_w_px) {{
    \\    float x = local.x * cell_w_px;
    \\    float period = max(8.0, cell_w_px / SK_CURLY_THICKNESS_PX);
    \\    float yc = 0.5 + SK_CURLY_AMPLITUDE * sin(x * SK_WAVE_TWO_PI / period);
    \\    float dist = abs(local.y - yc);
    \\    // Strip height in px, approximated from the cell WIDTH: the
    \\    // fragment stage has no cell height, and for a roughly 1:2
    \\    // monospace cell the two are close enough for a 1.5px stroke.
    \\    // Both passes call THIS function with the same argument, so
    \\    // the approximation cannot make them disagree.
    \\    float strip_px = max(SK_CURLY_STRIP_MIN_PX, cell_w_px / SK_CURLY_STRIP_DIV);
    \\    float thickness = SK_CURLY_THICKNESS_PX / strip_px;
    \\    if (dist > thickness) return 0.0;
    \\    return clamp((thickness - dist) / (thickness * 0.5), 0.0, 1.0);
    \\}}
    \\
    \\// Strip for decoration `kind` (see style.zig `Deco`) in a cell of
    \\// height `ch`: (y from the cell top, height), both in pixels.
    \\vec2 sk_decoStrip(float kind, float ch) {{
    \\    float thin = sk_decoThin(ch);
    \\    if (kind >= 1.5 && kind < 2.5) {{
    \\        float h = (2.0 + SK_DECO_DOUBLE_GAP) * thin;
    \\        return vec2(max(0.0, ch - h - SK_DECO_BOTTOM_GAP), h);
    \\    }}
    \\    if (kind >= 2.5 && kind < 3.5) {{
    \\        float h = sk_curlyStripH(ch);
    \\        return vec2(max(0.0, ch - h - SK_DECO_BOTTOM_GAP), h);
    \\    }}
    \\    if (kind >= 3.5 && kind < 4.5)
    \\        return vec2(sk_decoRound(ch * SK_DECO_STRIKE_CENTER - thin * 0.5), thin);
    \\    if (kind >= 4.5) return vec2(0.0, thin);
    \\    return vec2(max(0.0, ch - thin - SK_DECO_BOTTOM_GAP), thin);
    \\}}
    \\
, .{
    deco_thin_divisor,
    deco_bottom_gap,
    deco_double_gap_thins,
    deco_strike_center,
    CURLY_STRIP_MIN_PX,
    CURLY_STRIP_DIV,
    CURLY_AMPLITUDE,
    CURLY_THICKNESS_PX,
    1.0 / (2.0 + deco_double_gap_thins),
    (1.0 + deco_double_gap_thins) / (2.0 + deco_double_gap_thins),
});

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

test "decoThin is whole-pixel and follows ch/14" {
    try std.testing.expectEqual(@as(f32, 1.0), decoThin(10));
    try std.testing.expectEqual(@as(f32, 1.0), decoThin(17)); // 14px font
    try std.testing.expectEqual(@as(f32, 1.0), decoThin(20));
    try std.testing.expectEqual(@as(f32, 2.0), decoThin(21));
    try std.testing.expectEqual(@as(f32, 2.0), decoThin(34));
    try std.testing.expectEqual(@as(f32, 3.0), decoThin(35));
    try std.testing.expectEqual(@as(f32, 3.0), decoThin(40));
}

test "every decoration strip stays inside its cell" {
    var ch: f32 = 8;
    while (ch <= 48) : (ch += 1) {
        for ([_]Deco{ .underline, .double_underline, .curly, .strikethrough, .overline }) |kind| {
            const r = decoStrip(kind, ch);
            try std.testing.expect(r.y >= 0);
            try std.testing.expect(r.h > 0);
            try std.testing.expect(r.y + r.h <= ch);
        }
        for (decoDoubleLines(ch)) |l| {
            try std.testing.expect(l.y >= 0);
            try std.testing.expect(l.y + l.h <= ch);
        }
        // The curly strip has to hold a full wave: amplitude is a
        // fraction of the strip, so the strip must be at least the
        // stroke plus that swing.
        const strip = decoStrip(.curly, ch);
        try std.testing.expect(strip.h >= CURLY_THICKNESS_PX * 2.0);
    }
}

test "double underline lower sub-line sits on the single underline" {
    var ch: f32 = 8;
    while (ch <= 48) : (ch += 1) {
        const single = decoStrip(.underline, ch);
        const lines = decoDoubleLines(ch);
        try std.testing.expectEqual(single.y, lines[1].y);
        try std.testing.expectEqual(single.h, lines[1].h);
        // Gap of exactly `thin` between the two sub-lines — the
        // fragment shader's thirds split depends on it.
        const thin = decoThin(ch);
        try std.testing.expectEqual(lines[0].y + 2.0 * thin, lines[1].y);
    }
}

test "double underline strip splits into exact thirds" {
    // What SK_DECO_DOUBLE_LO / HI encode for the fragment shader.
    const lo = 1.0 / (2.0 + deco_double_gap_thins);
    const hi = (1.0 + deco_double_gap_thins) / (2.0 + deco_double_gap_thins);
    var ch: f32 = 8;
    while (ch <= 48) : (ch += 1) {
        const strip = decoStrip(.double_underline, ch);
        const lines = decoDoubleLines(ch);
        try std.testing.expectApproxEqAbs(lines[0].h / strip.h, lo, 1e-6);
        try std.testing.expectApproxEqAbs((lines[1].y - strip.y) / strip.h, hi, 1e-6);
    }
}

test "strikethrough is centred near 0.55 of the cell height" {
    var ch: f32 = 8;
    while (ch <= 48) : (ch += 1) {
        const r = decoStrip(.strikethrough, ch);
        const center = r.y + r.h * 0.5;
        try std.testing.expect(@abs(center - ch * deco_strike_center) <= 1.0);
    }
}

test "DECO_GLSL carries no version line and mirrors the constants" {
    try std.testing.expect(std.mem.indexOf(u8, DECO_GLSL, "#version") == null);
    try std.testing.expect(std.mem.indexOf(u8, DECO_GLSL, "SK_DECO_THIN_DIV = 14.000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, DECO_GLSL, "sk_decoStrip") != null);
}
