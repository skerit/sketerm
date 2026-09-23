//! Shared style helpers for the render passes.
//!
//! Both `cell_pass.zig` and `grid_pass.zig` turn a style entry into
//! the colours and line decorations they draw. Every rule of that
//! lives here once: `Resolver` is the colour resolution (bold-bright,
//! reverse, dim, min-contrast, SGR 58), and the decoration geometry
//! below is mirrored into `DECO_GLSL` for both shader pairs. Each of
//! these had been written per pass and had drifted.

const std = @import("std");
const Color = @import("../grid/style_pool.zig").Color;
const Attrs = @import("../grid/style_pool.zig").Attrs;
const Entry = @import("../grid/style_pool.zig").Entry;

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

/// Per-channel attenuation of the text colour under SGR 2 (dim).
pub const DIM_FG_SCALE: f32 = 0.65;

/// The one style-entry-to-colours resolution, used by every pass.
///
/// Order matters and is fixed here: bold-is-bright lifts palette 0-7
/// of the entry's FG first, then reverse video swaps fg and bg (so a
/// bold reversed cell gets the bright colour as its bg, xterm's
/// behaviour), dim attenuates whatever is drawn as text after the
/// swap, and min-contrast snaps that text colour against the bg it
/// really sits on. The decoration colour is SGR 58 when set (undimmed
/// and unsnapped: a diagnostic squiggle keeps its colour) and the
/// fully resolved text colour otherwise.
pub const Resolver = struct {
    default_fg: [4]f32,
    default_bg: [4]f32,
    palette: *const [256][3]u8,
    /// Already folded with the pass's `allow_bold`.
    bold_is_bright: bool,
    /// WCAG ratio floor for text over its effective bg; <= 1 disables.
    min_contrast: f32,

    pub const Resolved = struct {
        fg: [4]f32,
        bg: [4]f32,
        /// The cell paints its own bg (explicit colour or reverse).
        has_bg: bool,
        /// The bg text really sits on: `bg` when `has_bg`, else the
        /// pane clear colour.
        eff_bg: [4]f32,
        /// Underline / strikethrough / overline colour.
        deco: [4]f32,
    };

    fn rgba(self: Resolver, color: Color, is_fg: bool) [4]f32 {
        return colorToRGBA(color, is_fg, self.default_fg, self.default_bg, self.palette);
    }

    pub fn resolve(self: Resolver, style: Entry) Resolved {
        var fg_color = style.fg;
        if (style.attrs.bold and self.bold_is_bright) {
            if (fg_color == .palette and fg_color.palette < 8) {
                fg_color = .{ .palette = fg_color.palette + 8 };
            }
        }
        var fg = self.rgba(fg_color, true);
        var bg = self.rgba(style.bg, false);
        var has_bg = style.bg != .default;
        if (style.attrs.reverse) {
            std.mem.swap([4]f32, &fg, &bg);
            has_bg = true;
        }
        if (style.attrs.dim) {
            for (fg[0..3]) |*ch| ch.* *= DIM_FG_SCALE;
        }
        const eff_bg = if (has_bg) bg else self.default_bg;
        fg = applyMinContrast(fg, eff_bg, self.min_contrast);
        const deco = switch (style.underline_color) {
            .default => fg,
            else => self.rgba(style.underline_color, true),
        };
        return .{ .fg = fg, .bg = bg, .has_bg = has_bg, .eff_bg = eff_bg, .deco = deco };
    }
};

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
//
//   dotted     Same strip as the single underline, lit `thin` px,
//   dashed     dark `thin` px (dotted) or lit 3*thin, dark 2*thin
//              (dashed), the pattern restarting at every cell's left
//              edge so both passes agree on the phase. In `thin`s so
//              the pattern scales with the line: at a 14px font (thin
//              1px, cells ~8px wide) a dot is one pixel with a
//              one-pixel gap and a dash three with two; at 28px (thin
//              2px, ~16px cells) they double, and a dash still gets
//              two gaps per cell. Kitty and ghostty draw the same two
//              shapes at these proportions. Both passes light the
//              pattern through `sk_patternCoverage`, the CPU twin of
//              which is `decoPatternLit`.

/// Line-decoration kind. The numeric values are the `a_deco` vertex
/// attribute CellPass ships to its shader and the strip kind GridPass
/// ships for its shaded strips; keep them in sync with the
/// `sk_decoStrip` and `sk_patternCoverage` branches in `DECO_GLSL`.
pub const Deco = enum(u8) {
    none = 0,
    underline = 1,
    double_underline = 2,
    curly = 3,
    strikethrough = 4,
    overline = 5,
    dotted = 6,
    dashed = 7,

    /// Kinds whose strip the fragment stage rasterises (wave or
    /// on/off pattern) instead of filling solid.
    pub fn shaded(self: Deco) bool {
        return self == .curly or decoPatternThins(self) != null;
    }
};

/// A decoration strip in cell-local pixels: `y` from the cell top.
pub const DecoRect = struct { y: f32, h: f32 };

/// The decoration these attrs' underline style draws as, `.none`
/// without one; `Attrs.underlineStyle` owns the precedence.
pub fn underlineKind(attrs: Attrs) Deco {
    return switch (attrs.underlineStyle()) {
        .none => .none,
        .single => .underline,
        .double => .double_underline,
        .curly => .curly,
        .dotted => .dotted,
        .dashed => .dashed,
    };
}

/// The single decoration a one-strip-per-cell pass draws for these
/// attributes, most specific first. CellPass ships exactly one strip
/// per cell, so a cell that is both underlined and struck through
/// shows the underline there; GridPass, which emits independent
/// quads, draws both.
pub fn decoKind(attrs: Attrs) Deco {
    const ul = underlineKind(attrs);
    if (ul != .none) return ul;
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
/// Lit length of a dot (SGR 4:4), in `thin`s.
pub const DOT_ON_THINS: f32 = 1.0;
/// Gap after a dot, in `thin`s.
pub const DOT_OFF_THINS: f32 = 1.0;
/// Lit length of a dash (SGR 4:5), in `thin`s.
pub const DASH_ON_THINS: f32 = 3.0;
/// Gap after a dash, in `thin`s.
pub const DASH_OFF_THINS: f32 = 2.0;

/// On/off pattern of a patterned underline, in `thin`s or pixels.
pub const Pattern = struct { on: f32, period: f32 };

/// The pattern `kind` repeats along the cell, in `thin`s; null for
/// every kind drawn solid. The one list of the patterned kinds.
pub fn decoPatternThins(kind: Deco) ?Pattern {
    return switch (kind) {
        .dotted => .{ .on = DOT_ON_THINS, .period = DOT_ON_THINS + DOT_OFF_THINS },
        .dashed => .{ .on = DASH_ON_THINS, .period = DASH_ON_THINS + DASH_OFF_THINS },
        else => null,
    };
}

/// `decoPatternThins` scaled to whole pixels for a cell `ch` tall.
pub fn decoPattern(kind: Deco, ch: f32) ?Pattern {
    const thins = decoPatternThins(kind) orelse return null;
    const thin = decoThin(ch);
    return .{ .on = thins.on * thin, .period = thins.period * thin };
}

/// Whether pixel column `x_px` (cell-local: the pattern restarts at
/// every cell) is lit for `kind`. Solid kinds are lit everywhere.
/// CPU twin of `sk_patternCoverage`.
pub fn decoPatternLit(kind: Deco, x_px: f32, ch: f32) bool {
    const pat = decoPattern(kind, ch) orelse return true;
    return @mod(@floor(x_px), pat.period) < pat.on;
}

/// A lit run of a decoration, in cell-local pixels.
pub const Segment = struct { x: f32, w: f32 };

/// The lit runs of `kind` across a `cell_w`-wide cell, left to right:
/// one run spanning the cell for a solid kind, one per pattern period
/// otherwise. `buf` bounds the count; a cell wider than
/// `buf.len * period` is truncated.
pub fn decoSegments(kind: Deco, ch: f32, cell_w: f32, buf: []Segment) []Segment {
    const pat = decoPattern(kind, ch) orelse {
        buf[0] = .{ .x = 0, .w = cell_w };
        return buf[0..1];
    };
    var n: usize = 0;
    var x: f32 = 0;
    while (x < cell_w and n < buf.len) : (x += pat.period) {
        buf[n] = .{ .x = x, .w = @min(pat.on, cell_w - x) };
        n += 1;
    }
    return buf[0..n];
}

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

/// The strip a decoration occupies within its cell. For the solid
/// kinds the strip IS the drawn line; for `.double_underline` and the
/// `shaded` kinds it is the band the shader rasterises inside.
pub fn decoStrip(kind: Deco, ch: f32) DecoRect {
    const thin = decoThin(ch);
    return switch (kind) {
        .none => .{ .y = 0, .h = 0 },
        .underline, .dotted, .dashed => .{ .y = @max(0.0, ch - thin - deco_bottom_gap), .h = thin },
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
/// split the double underline at `SK_DECO_DOUBLE_LO/HI`, draw the
/// undercurl with `sk_curlyCoverage` and light the dotted / dashed
/// pattern with `sk_patternCoverage`. Carries no `#version` line:
/// `gl.zig compileShader` injects the per-API header.
///
/// `sk_curlyCoverage` returns UN-corrected edge coverage in [0,1]; 0
/// means the fragment is off the wave and the caller should discard.
/// The caller applies `sk_correctCoverage` itself, since only it
/// knows its bg. The wave phase restarts at every cell (local x), so
/// both passes share the per-cell phase and a row rendered half by
/// CellPass and half by GridPass matches.
///
/// `sk_patternCoverage` is binary (1 lit, 0 discard) and takes the
/// fragment's x inside its cell in PIXELS plus `thin`, which the
/// caller derives from the cell height with `sk_decoThin` or ships
/// from the CPU's `decoThin`; the pattern restarts at every cell too.
pub const DECO_GLSL = std.fmt.comptimePrint(
    \\const float SK_DECO_THIN_DIV = {d:.6};
    \\const float SK_DECO_BOTTOM_GAP = {d:.6};
    \\const float SK_DECO_DOUBLE_GAP = {d:.6};
    \\const float SK_DECO_STRIKE_CENTER = {d:.6};
    \\const float SK_CURLY_STRIP_MIN_PX = {d:.6};
    \\const float SK_CURLY_STRIP_DIV = {d:.6};
    \\const float SK_CURLY_AMPLITUDE = {d:.6};
    \\const float SK_CURLY_THICKNESS_PX = {d:.6};
    \\const float SK_DOT_ON_THINS = {d:.6};
    \\const float SK_DOT_OFF_THINS = {d:.6};
    \\const float SK_DASH_ON_THINS = {d:.6};
    \\const float SK_DASH_OFF_THINS = {d:.6};
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
    \\// Lit test for the dotted (kind 6) and dashed (kind 7) patterns:
    \\// `x_px` is the fragment's x inside its cell in pixels, `thin`
    \\// the line thickness. Whole-pixel arithmetic on the pixel index,
    \\// so the CPU's decoPatternLit lights exactly the same columns.
    \\float sk_patternCoverage(float kind, float x_px, float thin) {{
    \\    float on = SK_DASH_ON_THINS;
    \\    float off = SK_DASH_OFF_THINS;
    \\    if (kind < 6.5) {{ on = SK_DOT_ON_THINS; off = SK_DOT_OFF_THINS; }}
    \\    float period = (on + off) * thin;
    \\    return (mod(floor(x_px), period) < on * thin) ? 1.0 : 0.0;
    \\}}
    \\
    \\// Strip for decoration `kind` (see style.zig `Deco`) in a cell of
    \\// height `ch`: (y from the cell top, height), both in pixels.
    \\// Kinds 1, 6 and 7 (single, dotted, dashed) share the underline
    \\// strip.
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
    \\    if (kind >= 4.5 && kind < 5.5) return vec2(0.0, thin);
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
    DOT_ON_THINS,
    DOT_OFF_THINS,
    DASH_ON_THINS,
    DASH_OFF_THINS,
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

/// A resolver over a palette whose entries 0-15 are distinct greys
/// (index n -> n/16 brightness) so lifts and swaps are observable.
fn testResolver(pal: *[256][3]u8, bold_is_bright: bool, min_contrast: f32) Resolver {
    for (0..16) |i| {
        const v: u8 = @intCast(i * 16);
        pal[i] = .{ v, v, v };
    }
    return .{
        .default_fg = .{ 0.9, 0.9, 0.9, 1.0 },
        .default_bg = .{ 0.1, 0.1, 0.1, 1.0 },
        .palette = pal,
        .bold_is_bright = bold_is_bright,
        .min_contrast = min_contrast,
    };
}

test "Resolver: plain entry is default fg over the clear colour" {
    var pal: [256][3]u8 = std.mem.zeroes([256][3]u8);
    const r = testResolver(&pal, true, 1.0);
    const out = r.resolve(.{});
    try std.testing.expectEqual(r.default_fg, out.fg);
    try std.testing.expect(!out.has_bg);
    try std.testing.expectEqual(r.default_bg, out.eff_bg);
    try std.testing.expectEqual(out.fg, out.deco);
}

test "Resolver: bold-is-bright lifts palette 0-7 only when enabled" {
    var pal: [256][3]u8 = std.mem.zeroes([256][3]u8);
    const lifted = testResolver(&pal, true, 1.0).resolve(.{ .fg = .{ .palette = 1 }, .attrs = .{ .bold = true } });
    try std.testing.expectApproxEqAbs(@as(f32, 9.0 * 16.0 / 255.0), lifted.fg[0], 1e-6);
    const kept = testResolver(&pal, false, 1.0).resolve(.{ .fg = .{ .palette = 1 }, .attrs = .{ .bold = true } });
    try std.testing.expectApproxEqAbs(@as(f32, 16.0 / 255.0), kept.fg[0], 1e-6);
    // 8-15 and non-palette colours are never lifted.
    const high = testResolver(&pal, true, 1.0).resolve(.{ .fg = .{ .palette = 9 }, .attrs = .{ .bold = true } });
    try std.testing.expectApproxEqAbs(@as(f32, 9.0 * 16.0 / 255.0), high.fg[0], 1e-6);
}

test "Resolver: reverse swaps after the lift, so a bold cell's bg is bright" {
    var pal: [256][3]u8 = std.mem.zeroes([256][3]u8);
    const r = testResolver(&pal, true, 1.0);
    const out = r.resolve(.{ .fg = .{ .palette = 2 }, .bg = .{ .palette = 5 }, .attrs = .{ .bold = true, .reverse = true } });
    try std.testing.expect(out.has_bg);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0 * 16.0 / 255.0), out.bg[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0 * 16.0 / 255.0), out.fg[0], 1e-6);
    try std.testing.expectEqual(out.bg, out.eff_bg);
    // Reverse with default colours flips the defaults.
    const flipped = r.resolve(.{ .attrs = .{ .reverse = true } });
    try std.testing.expectEqual(r.default_bg, flipped.fg);
    try std.testing.expectEqual(r.default_fg, flipped.bg);
    try std.testing.expect(flipped.has_bg);
}

test "Resolver: dim attenuates the drawn text colour, even the reversed one" {
    var pal: [256][3]u8 = std.mem.zeroes([256][3]u8);
    const r = testResolver(&pal, true, 1.0);
    const dim = r.resolve(.{ .fg = .{ .palette = 8 }, .attrs = .{ .dim = true } });
    try std.testing.expectApproxEqAbs(@as(f32, 8.0 * 16.0 / 255.0 * DIM_FG_SCALE), dim.fg[0], 1e-6);
    try std.testing.expectEqual(@as(f32, 1.0), dim.fg[3]);
    const rev = r.resolve(.{ .bg = .{ .palette = 8 }, .attrs = .{ .dim = true, .reverse = true } });
    try std.testing.expectApproxEqAbs(@as(f32, 8.0 * 16.0 / 255.0 * DIM_FG_SCALE), rev.fg[0], 1e-6);
}

test "Resolver: min-contrast snaps against the effective bg" {
    var pal: [256][3]u8 = std.mem.zeroes([256][3]u8);
    const r = testResolver(&pal, true, 4.5);
    // Dark grey text on the dark clear colour snaps to white.
    const on_clear = r.resolve(.{ .fg = .{ .palette = 2 } });
    try std.testing.expectEqual(@as(f32, 1.0), on_clear.fg[0]);
    // Light grey text on a light explicit bg snaps to black instead.
    const on_light = r.resolve(.{ .fg = .{ .palette = 14 }, .bg = .{ .palette = 15 } });
    try std.testing.expectEqual(@as(f32, 0.0), on_light.fg[0]);
    // Disabled floor leaves the colour alone.
    const off = testResolver(&pal, true, 1.0).resolve(.{ .fg = .{ .palette = 2 } });
    try std.testing.expectApproxEqAbs(@as(f32, 2.0 * 16.0 / 255.0), off.fg[0], 1e-6);
}

test "Resolver: decoration colour follows the resolved fg unless SGR 58 sets it" {
    var pal: [256][3]u8 = std.mem.zeroes([256][3]u8);
    const r = testResolver(&pal, true, 4.5);
    // Default: the fg AFTER dim and the contrast snap.
    const follow = r.resolve(.{ .fg = .{ .palette = 2 }, .attrs = .{ .dim = true } });
    try std.testing.expectEqual(follow.fg, follow.deco);
    try std.testing.expectEqual(@as(f32, 1.0), follow.deco[0]);
    // Explicit: the raw colour, neither dimmed nor snapped.
    const explicit = r.resolve(.{ .fg = .{ .palette = 2 }, .underline_color = .{ .palette = 3 }, .attrs = .{ .dim = true } });
    try std.testing.expectApproxEqAbs(@as(f32, 3.0 * 16.0 / 255.0), explicit.deco[0], 1e-6);
    const rgb = r.resolve(.{ .underline_color = .{ .rgb = .{ .r = 255, .g = 0, .b = 0 } } });
    try std.testing.expectEqual([4]f32{ 1.0, 0.0, 0.0, 1.0 }, rgb.deco);
}

test "underlineKind and decoKind cover every underline style" {
    var a = Attrs{};
    try std.testing.expectEqual(Deco.none, underlineKind(a));
    try std.testing.expectEqual(Deco.none, decoKind(a));
    inline for (.{
        .{ Attrs.UnderlineStyle.single, Deco.underline },
        .{ Attrs.UnderlineStyle.double, Deco.double_underline },
        .{ Attrs.UnderlineStyle.curly, Deco.curly },
        .{ Attrs.UnderlineStyle.dotted, Deco.dotted },
        .{ Attrs.UnderlineStyle.dashed, Deco.dashed },
    }) |pair| {
        a.setUnderlineStyle(pair[0]);
        try std.testing.expectEqual(pair[1], underlineKind(a));
        // The one strip CellPass draws prefers the underline over
        // strike and overline.
        a.strikethrough = true;
        a.overline = true;
        try std.testing.expectEqual(pair[1], decoKind(a));
    }
    a.setUnderlineStyle(.none);
    try std.testing.expectEqual(Deco.strikethrough, decoKind(a));
    a.strikethrough = false;
    try std.testing.expectEqual(Deco.overline, decoKind(a));
}

test "dotted and dashed share the single underline's strip" {
    var ch: f32 = 8;
    while (ch <= 48) : (ch += 1) {
        try std.testing.expectEqual(decoStrip(.underline, ch), decoStrip(.dotted, ch));
        try std.testing.expectEqual(decoStrip(.underline, ch), decoStrip(.dashed, ch));
    }
}

test "only curly, dotted and dashed are shaded strips" {
    for (std.enums.values(Deco)) |kind| {
        const expect = kind == .curly or kind == .dotted or kind == .dashed;
        try std.testing.expectEqual(expect, kind.shaded());
        try std.testing.expectEqual(kind == .dotted or kind == .dashed, decoPattern(kind, 17) != null);
    }
}

test "pattern segments stay inside the cell, in whole pixels, and match decoPatternLit" {
    var buf: [64]Segment = undefined;
    var ch: f32 = 8;
    while (ch <= 48) : (ch += 1) {
        var cell_w: f32 = 4;
        while (cell_w <= 30) : (cell_w += 1) {
            for ([_]Deco{ .dotted, .dashed }) |kind| {
                const segs = decoSegments(kind, ch, cell_w, &buf);
                try std.testing.expect(segs.len >= 1);
                var prev_end: f32 = -1;
                for (segs) |s| {
                    try std.testing.expect(s.x >= 0 and s.w > 0 and s.x + s.w <= cell_w);
                    try std.testing.expect(s.x > prev_end); // a gap before every run
                    try std.testing.expectEqual(s.x, @floor(s.x));
                    try std.testing.expectEqual(s.w, @floor(s.w));
                    prev_end = s.x + s.w;
                }
                // Pixel by pixel, the runs are exactly the lit columns.
                var px: f32 = 0;
                while (px < cell_w) : (px += 1) {
                    var in_run = false;
                    for (segs) |s| if (px >= s.x and px < s.x + s.w) {
                        in_run = true;
                    };
                    try std.testing.expectEqual(in_run, decoPatternLit(kind, px + 0.5, ch));
                }
            }
            // A solid kind is one run spanning the cell.
            const solid = decoSegments(.underline, ch, cell_w, &buf);
            try std.testing.expectEqual(@as(usize, 1), solid.len);
            try std.testing.expectEqual(Segment{ .x = 0, .w = cell_w }, solid[0]);
        }
    }
}

test "dotted and dashed patterns scale with thin and differ from each other" {
    // 14px font: thin 1 -> dot 1 on 1 off, dash 3 on 2 off.
    try std.testing.expectEqual(Pattern{ .on = 1, .period = 2 }, decoPattern(.dotted, 17).?);
    try std.testing.expectEqual(Pattern{ .on = 3, .period = 5 }, decoPattern(.dashed, 17).?);
    // 28px font: thin 2 -> everything doubles.
    try std.testing.expectEqual(Pattern{ .on = 2, .period = 4 }, decoPattern(.dotted, 34).?);
    try std.testing.expectEqual(Pattern{ .on = 6, .period = 10 }, decoPattern(.dashed, 34).?);
    // Both leave a dark column in every 8px cell and start lit.
    for ([_]Deco{ .dotted, .dashed }) |kind| {
        try std.testing.expect(decoPatternLit(kind, 0.5, 17));
        var dark: usize = 0;
        var px: f32 = 0;
        while (px < 8) : (px += 1) dark += @intFromBool(!decoPatternLit(kind, px + 0.5, 17));
        try std.testing.expect(dark >= 2);
    }
    // And they are not the same pattern.
    var differ = false;
    var px: f32 = 0;
    while (px < 8) : (px += 1) {
        if (decoPatternLit(.dotted, px + 0.5, 17) != decoPatternLit(.dashed, px + 0.5, 17)) differ = true;
    }
    try std.testing.expect(differ);
}

test "every decoration strip stays inside its cell" {
    var ch: f32 = 8;
    while (ch <= 48) : (ch += 1) {
        for ([_]Deco{ .underline, .double_underline, .curly, .strikethrough, .overline, .dotted, .dashed }) |kind| {
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
    try std.testing.expect(std.mem.indexOf(u8, DECO_GLSL, "SK_DOT_ON_THINS = 1.000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, DECO_GLSL, "SK_DOT_OFF_THINS = 1.000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, DECO_GLSL, "SK_DASH_ON_THINS = 3.000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, DECO_GLSL, "SK_DASH_OFF_THINS = 2.000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, DECO_GLSL, "float sk_patternCoverage(float kind, float x_px, float thin)") != null);
    // The strip function's kind thresholds bracket the enum values.
    try std.testing.expectEqual(@as(u8, 5), @intFromEnum(Deco.overline));
    try std.testing.expect(std.mem.indexOf(u8, DECO_GLSL, "kind >= 4.5 && kind < 5.5") != null);
    try std.testing.expectEqual(@as(u8, 6), @intFromEnum(Deco.dotted));
    try std.testing.expectEqual(@as(u8, 7), @intFromEnum(Deco.dashed));
    try std.testing.expect(std.mem.indexOf(u8, DECO_GLSL, "if (kind < 6.5)") != null);
}
