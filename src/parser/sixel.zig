//! Sixel decoder.
//!
//! Input: the body of a `DCS q ... ST` frame (everything between
//! the final 'q' and the terminator).
//! Output: RGBA8 pixel buffer + dimensions.
//!
//! Subset implemented (covers what chafa, img2sixel, yazi emit):
//!   - `" Pan;Pad;Ph;Pv` raster attributes — Ph/Pv size the buffer,
//!     Pan/Pad set the pixel aspect ratio (overriding DCS P1)
//!   - `# Pc ; Pu ; Px ; Py ; Pz` color register definitions —
//!     RGB (Pu=2) and HLS (Pu=1, converted in `hlsToRgb`)
//!   - `# Pc` color register selection
//!   - `?`..`~` pixel chars (6 vertical pixels)
//!   - `!N` RLE prefix
//!   - `$` carriage return (back to col 0 of current 6-row band)
//!   - `-` line feed (next 6-row band)
//!   - transparency: unpainted pixels stay alpha 0 so the cell
//!     background shows through (the image pass blends them out),
//!     unless `Options.background` asks for a fill
//!
//! The DCS header params P1 (aspect ratio) and P2 (background select)
//! arrive through `Options`; the caller resolves them with
//! `aspectFromP1`. P3 (horizontal grid size) has no effect here or in
//! any other implementation — see `Options.aspect_num`.

const std = @import("std");

pub const Decoded = struct {
    rgba: []u8, // owned
    width: u32,
    height: u32,
};

pub const Options = struct {
    /// Pixel aspect ratio, vertical:horizontal, from DCS P1 via
    /// `aspectFromP1`. A `"` raster attribute in the body overrides it:
    /// P1 is a coarse macro selecting one of nine fixed ratios, while
    /// Pan/Pad state the ratio outright, so the body is the more
    /// specific (and later) statement of intent — which is also what
    /// makes modern encoders' `P1 = 0` harmless, since they all emit
    /// `"1;1;...`.
    ///
    /// DCS P3 (horizontal grid size) has no counterpart here: DEC
    /// defined it for the VT240's device grid and xterm, libsixel and
    /// every other implementation ignore it. We parse past it and drop
    /// it rather than invent a meaning.
    aspect_num: u32 = 1,
    aspect_den: u32 = 1,
    /// Colour for pixels the sixel data never paints (DCS P2 = 0 or 2,
    /// "set to the current background colour"). null leaves them at
    /// alpha 0, which is both P2 = 1 (transparent) and the right answer
    /// for a default background, where "current background" is whatever
    /// the pane paints under the image.
    background: ?[4]u8 = null,
};

/// DCS P1 macro parameter -> pixel aspect ratio, vertical:horizontal.
///
/// Table from the VT330/VT340 Programmer Reference (chapter 14, Sixel
/// Graphics); 0 is the omitted-parameter default and shares 1's row.
/// Values above 9 are not in the table, so they get 1:1 rather than a
/// guess.
pub fn aspectFromP1(p1: u32) [2]u32 {
    return switch (p1) {
        0, 1, 5, 6 => .{ 2, 1 },
        2 => .{ 5, 1 },
        3, 4 => .{ 3, 1 },
        7, 8, 9 => .{ 1, 1 },
        else => .{ 1, 1 },
    };
}

pub const Error = error{
    EmptyImage,
    OutOfMemory,
    UnsupportedColorSpace,
};

const PALETTE_SIZE = 256;

/// Hard cap on decoded sixel dimensions. Raster attrs and pixel data are
/// attacker-controlled (any PTY output); without a cap the width*height*4
/// allocation wraps in u32 → undersized buffer → OOB heap write in
/// paintSixel. 10000 is generous for real terminal sixels and keeps the
/// u32 painting math safe: 10000*10000*4 ≈ 4e8 < 2^32.
const MAX_DIM: u32 = 10000;

/// Hard cap on the decoded canvas in PIXELS. `MAX_DIM` alone is a
/// per-axis bound, and the raster attribute states a size the body need
/// not back with any pixel data: `"5;1;10000;10000#0~` is 19 bytes that
/// ask for a 400 MB buffer, memset it, and then (with a non-1:1 aspect)
/// allocate a second one the same size — all inside the daemon's single
/// poll loop, on behalf of anything holding a PTY. 4096x4096 is past any
/// real terminal graphic; beyond it the canvas is truncated, not
/// rejected, so a merely-large sixel still draws.
const MAX_PIXELS: u32 = 4096 * 4096;

/// Clamp a canvas to `MAX_DIM` per axis and `MAX_PIXELS` in total,
/// keeping the width and truncating the height.
fn clampCanvas(w_in: u32, h_in: u32) [2]u32 {
    const w: u32 = @min(w_in, MAX_DIM);
    var h: u32 = @min(h_in, MAX_DIM);
    if (w > 0 and @as(u64, w) * @as(u64, h) > MAX_PIXELS) h = MAX_PIXELS / w;
    return .{ w, h };
}

pub fn decode(allocator: std.mem.Allocator, body: []const u8, opts: Options) Error!Decoded {
    // Pass 1: scan dimensions, clamped to MAX_DIM before any sizing/painting.
    const dims = scanDimensions(body);
    if (dims.width == 0 or dims.height == 0) return Error.EmptyImage;

    // Default palette is black.
    var palette: [PALETTE_SIZE][4]u8 = undefined;
    var k: usize = 0;
    while (k < PALETTE_SIZE) : (k += 1) palette[k] = .{ 0, 0, 0, 255 };

    // usize multiply so the size cannot overflow even before the clamp
    // (belt-and-suspenders; scanDimensions already caps each dim to MAX_DIM).
    const size: usize = @as(usize, dims.width) * @as(usize, dims.height) * 4;
    const rgba = try allocator.alloc(u8, size);
    if (opts.background) |bg| {
        var p: usize = 0;
        while (p < size) : (p += 4) rgba[p..][0..4].* = bg;
    } else @memset(rgba, 0);

    var x: u32 = 0;
    var band: u32 = 0;
    var current_color: u8 = 0;

    var i: usize = 0;
    while (i < body.len) {
        const ch = body[i];
        switch (ch) {
            '"' => {
                // raster attrs — already scanned in pass 1; skip.
                i += 1;
                while (i < body.len) : (i += 1) {
                    const c2 = body[i];
                    if (!(c2 >= '0' and c2 <= '9') and c2 != ';') break;
                }
            },
            '#' => {
                i += 1;
                const params = parseParams(body, &i);
                if (params.len == 1) {
                    current_color = @intCast(@min(params[0], PALETTE_SIZE - 1));
                } else if (params.len >= 5 and params[1] == 2) {
                    // RGB
                    const idx: u8 = @intCast(@min(params[0], PALETTE_SIZE - 1));
                    palette[idx] = .{
                        scaleColor(params[2]),
                        scaleColor(params[3]),
                        scaleColor(params[4]),
                        255,
                    };
                    current_color = idx;
                } else if (params.len >= 5 and params[1] == 1) {
                    // HLS — convert (rough)
                    const idx: u8 = @intCast(@min(params[0], PALETTE_SIZE - 1));
                    const rgb = hlsToRgb(params[2], params[3], params[4]);
                    palette[idx] = .{ rgb[0], rgb[1], rgb[2], 255 };
                    current_color = idx;
                }
            },
            '$' => {
                x = 0;
                i += 1;
            },
            '-' => {
                x = 0;
                band +|= 1;
                i += 1;
            },
            '!' => {
                i += 1;
                // Parse N.
                var n: u32 = 0;
                while (i < body.len and body[i] >= '0' and body[i] <= '9') : (i += 1) {
                    n = n *| 10 +| (body[i] - '0');
                }
                if (n == 0) n = 1;
                // Next char must be a sixel pixel char.
                if (i < body.len and body[i] >= '?' and body[i] <= '~') {
                    const bits: u8 = body[i] - '?';
                    paintSixel(rgba, dims.width, dims.height, palette[current_color], x, band, bits, n);
                    x +|= n;
                    i += 1;
                }
            },
            else => {
                if (ch >= '?' and ch <= '~') {
                    const bits: u8 = ch - '?';
                    paintSixel(rgba, dims.width, dims.height, palette[current_color], x, band, bits, 1);
                    x +|= 1;
                }
                i += 1;
            },
        }
    }

    // The raster attribute wins over P1 when it carries a ratio.
    const num = if (dims.aspect_num > 0 and dims.aspect_den > 0) dims.aspect_num else opts.aspect_num;
    const den = if (dims.aspect_num > 0 and dims.aspect_den > 0) dims.aspect_den else opts.aspect_den;
    return applyAspect(allocator, rgba, dims.width, dims.height, num, den);
}

/// Stretch the painted buffer so one sixel pixel occupies `num`:`den`
/// device pixels (vertical:horizontal), by whole-pixel replication —
/// the same thing the VT240's scan converter did, and all a nearest
/// neighbour blit would do anyway. Takes ownership of `rgba`.
fn applyAspect(
    allocator: std.mem.Allocator,
    rgba: []u8,
    width: u32,
    height: u32,
    num: u32,
    den: u32,
) Error!Decoded {
    const sy = ratioScale(num, den);
    const sx = ratioScale(den, num);
    if (sx == 1 and sy == 1) return .{ .rgba = rgba, .width = width, .height = height };

    const scaled = clampCanvas(width *| sx, height *| sy);
    const out_w = scaled[0];
    const out_h = scaled[1];
    const out = allocator.alloc(u8, @as(usize, out_w) * @as(usize, out_h) * 4) catch {
        allocator.free(rgba);
        return Error.OutOfMemory;
    };
    defer allocator.free(rgba);

    var y: u32 = 0;
    while (y < out_h) : (y += 1) {
        const src_y = @min(y / sy, height - 1);
        var x: u32 = 0;
        while (x < out_w) : (x += 1) {
            const src_x = @min(x / sx, width - 1);
            const src = (@as(usize, src_y) * width + src_x) * 4;
            const dst = (@as(usize, y) * out_w + x) * 4;
            out[dst..][0..4].* = rgba[src..][0..4].*;
        }
    }
    return .{ .rgba = out, .width = out_w, .height = out_h };
}

/// Whole-pixel replication factor for `a`:`b`, rounded to nearest and
/// never below 1 (a ratio below 1:1 scales the other axis instead).
fn ratioScale(a: u32, b: u32) u32 {
    if (a == 0 or b == 0 or a <= b) return 1;
    return @max(1, (a + b / 2) / b);
}

fn scaleColor(p: u32) u8 {
    // Sixel color values are 0..100 (percentage).
    const clipped: u32 = @min(p, 100);
    const scaled: u32 = (clipped * 255) / 100;
    return @intCast(scaled);
}

fn hlsToRgb(h_in: u32, l_in: u32, s_in: u32) [3]u8 {
    // Quick HLS → RGB. Sixel HLS uses H 0..360, L 0..100, S 0..100.
    const h: f32 = @as(f32, @floatFromInt(h_in % 360));
    const l: f32 = @as(f32, @floatFromInt(@min(l_in, 100))) / 100.0;
    const s: f32 = @as(f32, @floatFromInt(@min(s_in, 100))) / 100.0;
    const c = (1.0 - @abs(2.0 * l - 1.0)) * s;
    const hp = h / 60.0;
    const x = c * (1.0 - @abs(@mod(hp, 2.0) - 1.0));
    var r: f32 = 0;
    var g: f32 = 0;
    var b: f32 = 0;
    if (hp < 1) {
        r = c;
        g = x;
    } else if (hp < 2) {
        r = x;
        g = c;
    } else if (hp < 3) {
        g = c;
        b = x;
    } else if (hp < 4) {
        g = x;
        b = c;
    } else if (hp < 5) {
        r = x;
        b = c;
    } else {
        r = c;
        b = x;
    }
    const m = l - c / 2.0;
    return .{
        @intFromFloat(@max(0.0, @min(255.0, (r + m) * 255.0))),
        @intFromFloat(@max(0.0, @min(255.0, (g + m) * 255.0))),
        @intFromFloat(@max(0.0, @min(255.0, (b + m) * 255.0))),
    };
}

fn paintSixel(
    rgba: []u8,
    width: u32,
    height: u32,
    color: [4]u8,
    x: u32,
    band: u32,
    bits: u8,
    repeat: u32,
) void {
    if (x >= width or band >= (height + 5) / 6) return;
    const max_run = @min(repeat, width - x);
    var run: u32 = 0;
    while (run < max_run) : (run += 1) {
        const px = x + run;
        var bit: u3 = 0;
        while (bit < 6) : (bit += 1) {
            if ((bits >> bit) & 1 == 0) continue;
            const py = band * 6 + bit;
            if (py >= height) continue;
            const off = (py * width + px) * 4;
            rgba[off + 0] = color[0];
            rgba[off + 1] = color[1];
            rgba[off + 2] = color[2];
            rgba[off + 3] = color[3];
        }
    }
}

const Dims = struct {
    width: u32,
    height: u32,
    /// Raster attribute Pan/Pad. Both 0 = no ratio stated, use P1.
    aspect_num: u32 = 0,
    aspect_den: u32 = 0,
};

fn scanDimensions(body: []const u8) Dims {
    // Look for raster attrs first.
    var raster_w: u32 = 0;
    var raster_h: u32 = 0;
    var raster_num: u32 = 0;
    var raster_den: u32 = 0;
    if (std.mem.indexOfScalar(u8, body, '"')) |q_idx| {
        var i: usize = q_idx + 1;
        var params: [4]u32 = .{ 0, 0, 0, 0 };
        var n: usize = 0;
        var cur: u32 = 0;
        var has_cur = false;
        while (i < body.len and n < params.len) : (i += 1) {
            const ch = body[i];
            if (ch >= '0' and ch <= '9') {
                cur = cur *| 10 +| (ch - '0');
                has_cur = true;
            } else if (ch == ';') {
                if (has_cur) {
                    params[n] = cur;
                    n += 1;
                }
                cur = 0;
                has_cur = false;
            } else {
                if (has_cur and n < params.len) {
                    params[n] = cur;
                    n += 1;
                }
                break;
            }
        }
        // params: Pan, Pad, Ph, Pv. Ph/Pv only count when both are
        // there; Pan/Pad are usable on their own (a `"2;1` prefix with
        // no size is legal and states nothing but the ratio).
        if (n >= 2) {
            raster_num = params[0];
            raster_den = params[1];
        }
        if (n >= 4) {
            raster_w = params[2];
            raster_h = params[3];
        }
    }

    // Fall back to scanning pixel data.
    var x: u32 = 0;
    var band: u32 = 0;
    var max_x: u32 = 0;
    var saw_band_pixel: bool = false;
    var i: usize = 0;
    while (i < body.len) {
        const ch = body[i];
        switch (ch) {
            '$' => {
                x = 0;
                i += 1;
            },
            '-' => {
                if (saw_band_pixel) band +|= 1;
                saw_band_pixel = false;
                x = 0;
                i += 1;
            },
            '#', '"' => {
                // skip params
                i += 1;
                while (i < body.len) {
                    const c2 = body[i];
                    if (!(c2 >= '0' and c2 <= '9') and c2 != ';') break;
                    i += 1;
                }
            },
            '!' => {
                i += 1;
                var n: u32 = 0;
                while (i < body.len and body[i] >= '0' and body[i] <= '9') : (i += 1) {
                    n = n *| 10 +| (body[i] - '0');
                }
                if (n == 0) n = 1;
                if (i < body.len and body[i] >= '?' and body[i] <= '~') {
                    x +|= n;
                    if (x > max_x) max_x = x;
                    saw_band_pixel = true;
                    i += 1;
                }
            },
            else => {
                if (ch >= '?' and ch <= '~') {
                    x +|= 1;
                    if (x > max_x) max_x = x;
                    saw_band_pixel = true;
                }
                i += 1;
            },
        }
    }
    if (saw_band_pixel) band +|= 1;

    const w = if (raster_w > 0) raster_w else max_x;
    const h = if (raster_h > 0) raster_h else band *| 6;
    // Clamp so the allocation and paintSixel offset math (computed in
    // u32) cannot overflow on attacker-controlled input, and so a raster
    // attribute cannot name a canvas no body could ever fill.
    const canvas = clampCanvas(w, h);
    return .{
        .width = canvas[0],
        .height = canvas[1],
        .aspect_num = raster_num,
        .aspect_den = raster_den,
    };
}

fn parseParams(body: []const u8, i: *usize) []u32 {
    const Storage = struct {
        var slots: [16]u32 = .{0} ** 16;
    };
    var n: usize = 0;
    var cur: u32 = 0;
    var has_cur = false;
    while (i.* < body.len and n < Storage.slots.len) {
        const ch = body[i.*];
        if (ch >= '0' and ch <= '9') {
            cur = cur *| 10 +| (ch - '0');
            has_cur = true;
            i.* += 1;
        } else if (ch == ';') {
            Storage.slots[n] = if (has_cur) cur else 0;
            n += 1;
            cur = 0;
            has_cur = false;
            i.* += 1;
        } else break;
    }
    if (has_cur and n < Storage.slots.len) {
        Storage.slots[n] = cur;
        n += 1;
    }
    return Storage.slots[0..n];
}

// ── tests ────────────────────────────────────────────────────────

test "decode all-on single column" {
    // Body: define color 1 as red, select it, '~' = all 6 pixels.
    const body = "#1;2;100;0;0#1~";
    const out = try decode(std.testing.allocator, body, .{});
    defer std.testing.allocator.free(out.rgba);
    try std.testing.expectEqual(@as(u32, 1), out.width);
    try std.testing.expectEqual(@as(u32, 6), out.height);
    try std.testing.expectEqual(@as(u8, 255), out.rgba[0]); // r
    try std.testing.expectEqual(@as(u8, 0), out.rgba[1]); // g
    try std.testing.expectEqual(@as(u8, 0), out.rgba[2]); // b
}

test "decode 4-wide red bar" {
    // Define color 2 = green; select; print 4 columns of 'O' = bits 5..0?
    // 'O' = 0x4F - 0x3F = 0x10 = 16 = bit 4 → only the 5th pixel (y=4).
    const body = "#2;2;0;100;0#2OOOO";
    const out = try decode(std.testing.allocator, body, .{});
    defer std.testing.allocator.free(out.rgba);
    try std.testing.expectEqual(@as(u32, 4), out.width);
    try std.testing.expectEqual(@as(u32, 6), out.height);
    // Pixel (x=0, y=4) should be green.
    const off = (4 * 4 + 0) * 4;
    try std.testing.expectEqual(@as(u8, 0), out.rgba[off]); // r
    try std.testing.expectEqual(@as(u8, 255), out.rgba[off + 1]); // g
    try std.testing.expectEqual(@as(u8, 0), out.rgba[off + 2]); // b
}

test "RLE expansion" {
    // Define green; select; !5~ should produce 5 columns all-on green.
    const body = "#2;2;0;100;0#2!5~";
    const out = try decode(std.testing.allocator, body, .{});
    defer std.testing.allocator.free(out.rgba);
    try std.testing.expectEqual(@as(u32, 5), out.width);
    try std.testing.expectEqual(@as(u32, 6), out.height);
}

test "oversized RLE and raster numbers saturate before dimension clamp" {
    const rle = scanDimensions("!999999999999999999999999~");
    try std.testing.expectEqual(MAX_DIM, rle.width);
    try std.testing.expectEqual(@as(u32, 6), rle.height);
    const raster = scanDimensions("\"1;1;999999999999999999999;2~");
    try std.testing.expectEqual(MAX_DIM, raster.width);
    try std.testing.expectEqual(@as(u32, 2), raster.height);
}

test "raster attrs honored" {
    const body = "\"1;1;10;6#1;2;0;0;100#1~";
    const out = try decode(std.testing.allocator, body, .{});
    defer std.testing.allocator.free(out.rgba);
    try std.testing.expectEqual(@as(u32, 10), out.width);
    try std.testing.expectEqual(@as(u32, 6), out.height);
}

test "P1 macro parameter maps to the VT330 aspect table" {
    try std.testing.expectEqual([2]u32{ 2, 1 }, aspectFromP1(0));
    try std.testing.expectEqual([2]u32{ 2, 1 }, aspectFromP1(1));
    try std.testing.expectEqual([2]u32{ 5, 1 }, aspectFromP1(2));
    try std.testing.expectEqual([2]u32{ 3, 1 }, aspectFromP1(3));
    try std.testing.expectEqual([2]u32{ 3, 1 }, aspectFromP1(4));
    try std.testing.expectEqual([2]u32{ 2, 1 }, aspectFromP1(5));
    try std.testing.expectEqual([2]u32{ 2, 1 }, aspectFromP1(6));
    try std.testing.expectEqual([2]u32{ 1, 1 }, aspectFromP1(7));
    try std.testing.expectEqual([2]u32{ 1, 1 }, aspectFromP1(8));
    try std.testing.expectEqual([2]u32{ 1, 1 }, aspectFromP1(9));
    // Off the end of the table: no invented ratio.
    try std.testing.expectEqual([2]u32{ 1, 1 }, aspectFromP1(10));
    try std.testing.expectEqual([2]u32{ 1, 1 }, aspectFromP1(65535));
}

test "P1 aspect ratio stretches the image vertically" {
    // One all-on column, 1 x 6 sixel pixels, at 3:1 -> 1 x 18 device.
    const body = "#1;2;100;0;0#1~";
    const out = try decode(std.testing.allocator, body, .{ .aspect_num = 3, .aspect_den = 1 });
    defer std.testing.allocator.free(out.rgba);
    try std.testing.expectEqual(@as(u32, 1), out.width);
    try std.testing.expectEqual(@as(u32, 18), out.height);
    // Every replicated row carries the source pixel.
    var y: u32 = 0;
    while (y < 18) : (y += 1) {
        try std.testing.expectEqual(@as(u8, 255), out.rgba[y * 4 + 0]);
        try std.testing.expectEqual(@as(u8, 255), out.rgba[y * 4 + 3]);
    }
}

test "a raster attribute ratio overrides P1" {
    // P1 = 2 asks for 5:1; the body says 1:1 and wins.
    const body = "\"1;1;1;6#1;2;100;0;0#1~";
    const a = aspectFromP1(2);
    const out = try decode(std.testing.allocator, body, .{ .aspect_num = a[0], .aspect_den = a[1] });
    defer std.testing.allocator.free(out.rgba);
    try std.testing.expectEqual(@as(u32, 6), out.height);

    // And the reverse: a 2:1 raster attribute stretches even though
    // P1 = 7 asks for 1:1.
    const b = aspectFromP1(7);
    const out2 = try decode(std.testing.allocator, "\"2;1;1;6#1;2;100;0;0#1~", .{ .aspect_num = b[0], .aspect_den = b[1] });
    defer std.testing.allocator.free(out2.rgba);
    try std.testing.expectEqual(@as(u32, 12), out2.height);
}

test "a raster attribute wider than tall stretches horizontally" {
    const out = try decode(std.testing.allocator, "\"1;2;1;6#1;2;100;0;0#1~", .{});
    defer std.testing.allocator.free(out.rgba);
    try std.testing.expectEqual(@as(u32, 2), out.width);
    try std.testing.expectEqual(@as(u32, 6), out.height);
}

test "aspect scaling stays inside MAX_DIM" {
    // 6000 rows at 5:1 would be 30000 tall. Pan/Pad = 0 states no
    // ratio, so P1 is the one in force.
    const out = try decode(std.testing.allocator, "\"0;0;2;6000#1;2;100;0;0#1~", .{ .aspect_num = 5, .aspect_den = 1 });
    defer std.testing.allocator.free(out.rgba);
    try std.testing.expectEqual(MAX_DIM, out.height);
}

test "background select fills only the pixels the data misses" {
    // 2x6 image, left column all-on red, right column never painted.
    const body = "\"1;1;2;6#1;2;100;0;0#1~?";
    const out = try decode(std.testing.allocator, body, .{ .background = .{ 0, 0, 255, 255 } });
    defer std.testing.allocator.free(out.rgba);
    try std.testing.expectEqual(@as(u32, 2), out.width);
    // Painted pixel keeps its own colour, not the background.
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, out.rgba[0..4]);
    // Untouched neighbour took the background, opaque.
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, out.rgba[4..8]);
}

test "no background select leaves untouched pixels transparent" {
    const body = "\"1;1;2;6#1;2;100;0;0#1~?";
    const out = try decode(std.testing.allocator, body, .{});
    defer std.testing.allocator.free(out.rgba);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, out.rgba[0..4]);
    try std.testing.expectEqual(@as(u8, 0), out.rgba[7]); // alpha
}

test "a raster attribute alone cannot demand an unbounded canvas" {
    // 19 bytes of DCS body asking for 10000x10000 RGBA = 400 MB, painted
    // and (with a non-1:1 ratio) copied into a second buffer the same
    // size — inside the daemon's single-threaded poll loop.
    const d = scanDimensions("\"5;1;10000;10000#0~");
    try std.testing.expect(@as(u64, d.width) * @as(u64, d.height) <= MAX_PIXELS);
    // Ordinary sixels are untouched by the cap.
    const small = scanDimensions("\"1;1;640;480#0~");
    try std.testing.expectEqual(@as(u32, 640), small.width);
    try std.testing.expectEqual(@as(u32, 480), small.height);
}

test "aspect scaling stays inside the pixel budget" {
    const out = clampCanvas(MAX_DIM, MAX_DIM);
    try std.testing.expect(@as(u64, out[0]) * @as(u64, out[1]) <= MAX_PIXELS);
    try std.testing.expectEqual(MAX_DIM, out[0]);
}

test "background fill survives aspect scaling" {
    const out = try decode(std.testing.allocator, "#1;2;100;0;0#1~?", .{
        .aspect_num = 2,
        .aspect_den = 1,
        .background = .{ 7, 8, 9, 255 },
    });
    defer std.testing.allocator.free(out.rgba);
    try std.testing.expectEqual(@as(u32, 12), out.height);
    // Row 11, column 1 is still background.
    const off = (11 * 2 + 1) * 4;
    try std.testing.expectEqualSlices(u8, &.{ 7, 8, 9, 255 }, out.rgba[off .. off + 4]);
}
