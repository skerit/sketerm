//! Sixel decoder.
//!
//! Input: the body of a `DCS q ... ST` frame (everything between
//! the final 'q' and the terminator).
//! Output: RGBA8 pixel buffer + dimensions.
//!
//! Subset implemented (covers what chafa, img2sixel, yazi emit):
//!   - `" Pan;Pad;Ph;Pv` raster attributes (parsed; Ph/Pv used as
//!     hints for buffer sizing if present)
//!   - `# Pc ; Pu ; Px ; Py ; Pz` color register definitions, RGB only (Pu=2)
//!   - `# Pc` color register selection
//!   - `?`..`~` pixel chars (6 vertical pixels)
//!   - `!N` RLE prefix
//!   - `$` carriage return (back to col 0 of current 6-row band)
//!   - `-` line feed (next 6-row band)
//!
//! Not implemented: HLS color (Pu=1), private modes (P1-P3),
//! transparency, half-blocks.

const std = @import("std");

pub const Decoded = struct {
    rgba: []u8, // owned
    width: u32,
    height: u32,
};

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

pub fn decode(allocator: std.mem.Allocator, body: []const u8) Error!Decoded {
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
    @memset(rgba, 0);

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
                band += 1;
                i += 1;
            },
            '!' => {
                i += 1;
                // Parse N.
                var n: u32 = 0;
                while (i < body.len and body[i] >= '0' and body[i] <= '9') : (i += 1) {
                    n = n * 10 + (body[i] - '0');
                }
                if (n == 0) n = 1;
                // Next char must be a sixel pixel char.
                if (i < body.len and body[i] >= '?' and body[i] <= '~') {
                    const bits: u8 = body[i] - '?';
                    paintSixel(rgba, dims.width, dims.height, palette[current_color], x, band, bits, n);
                    x += n;
                    i += 1;
                }
            },
            else => {
                if (ch >= '?' and ch <= '~') {
                    const bits: u8 = ch - '?';
                    paintSixel(rgba, dims.width, dims.height, palette[current_color], x, band, bits, 1);
                    x += 1;
                }
                i += 1;
            },
        }
    }

    return .{ .rgba = rgba, .width = dims.width, .height = dims.height };
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
    if (hp < 1) { r = c; g = x; }
    else if (hp < 2) { r = x; g = c; }
    else if (hp < 3) { g = c; b = x; }
    else if (hp < 4) { g = x; b = c; }
    else if (hp < 5) { r = x; b = c; }
    else { r = c; b = x; }
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
    if (x >= width) return;
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

const Dims = struct { width: u32, height: u32 };

fn scanDimensions(body: []const u8) Dims {
    // Look for raster attrs first.
    var raster_w: u32 = 0;
    var raster_h: u32 = 0;
    if (std.mem.indexOfScalar(u8, body, '"')) |q_idx| {
        var i: usize = q_idx + 1;
        var params: [4]u32 = .{ 0, 0, 0, 0 };
        var n: usize = 0;
        var cur: u32 = 0;
        var has_cur = false;
        while (i < body.len and n < params.len) : (i += 1) {
            const ch = body[i];
            if (ch >= '0' and ch <= '9') {
                cur = cur * 10 + (ch - '0');
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
        // params: Pan, Pad, Ph, Pv
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
            '$' => { x = 0; i += 1; },
            '-' => {
                if (saw_band_pixel) band += 1;
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
                    n = n * 10 + (body[i] - '0');
                }
                if (n == 0) n = 1;
                if (i < body.len and body[i] >= '?' and body[i] <= '~') {
                    x += n;
                    if (x > max_x) max_x = x;
                    saw_band_pixel = true;
                    i += 1;
                }
            },
            else => {
                if (ch >= '?' and ch <= '~') {
                    x += 1;
                    if (x > max_x) max_x = x;
                    saw_band_pixel = true;
                }
                i += 1;
            },
        }
    }
    if (saw_band_pixel) band += 1;

    const w = if (raster_w > 0) raster_w else max_x;
    const h = if (raster_h > 0) raster_h else band * 6;
    // Clamp to MAX_DIM so the allocation and paintSixel offset math
    // (computed in u32) cannot overflow on attacker-controlled input.
    return .{ .width = @min(w, MAX_DIM), .height = @min(h, MAX_DIM) };
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
            cur = cur * 10 + (ch - '0');
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
    const out = try decode(std.testing.allocator, body);
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
    const out = try decode(std.testing.allocator, body);
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
    const out = try decode(std.testing.allocator, body);
    defer std.testing.allocator.free(out.rgba);
    try std.testing.expectEqual(@as(u32, 5), out.width);
    try std.testing.expectEqual(@as(u32, 6), out.height);
}

test "raster attrs honored" {
    const body = "\"1;1;10;6#1;2;0;0;100#1~";
    const out = try decode(std.testing.allocator, body);
    defer std.testing.allocator.free(out.rgba);
    try std.testing.expectEqual(@as(u32, 10), out.width);
    try std.testing.expectEqual(@as(u32, 6), out.height);
}
