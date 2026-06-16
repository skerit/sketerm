//! BGRA ↔ planar YUV 4:2:0 (I420) conversion — the colour-space step
//! every video codec needs (x264/AV1/hardware all take planar YUV, not
//! BGRA). Encode side converts BGRA→I420 before handing tiles to the
//! codec; software decode converts back. Full-range BT.601 (JPEG)
//! coefficients — full range avoids clipping screen content, and the
//! codec is told `fullrange=1` to match.
//!
//! Integer fixed-point (×256) so it's cheap on the daemon poll loop.
//! Dimensions must be even (4:2:0 subsamples chroma 2×2); tiles are 64px
//! so that always holds. Pure std, daemon-safe.

const std = @import("std");

/// Plane byte sizes for a `w`×`h` I420 image (caller allocates).
pub fn ySize(w: u32, h: u32) usize {
    return @as(usize, w) * h;
}
pub fn chromaSize(w: u32, h: u32) usize {
    return @as(usize, w / 2) * (h / 2);
}

fn clamp8(v: i32) u8 {
    return @intCast(std.math.clamp(v, 0, 255));
}

/// BGRA (B,G,R,A bytes) → I420 planes. `y` is w*h, `u`/`v` are
/// (w/2)*(h/2). `w` and `h` must be even.
pub fn bgraToI420(bgra: []const u8, w: u32, h: u32, y: []u8, u: []u8, v: []u8) void {
    std.debug.assert(w % 2 == 0 and h % 2 == 0);
    std.debug.assert(bgra.len >= @as(usize, w) * h * 4);
    std.debug.assert(y.len >= ySize(w, h) and u.len >= chromaSize(w, h) and v.len >= chromaSize(w, h));
    const cw = w / 2;

    var row: u32 = 0;
    while (row < h) : (row += 1) {
        var col: u32 = 0;
        while (col < w) : (col += 1) {
            const o = (@as(usize, row) * w + col) * 4;
            const b: i32 = bgra[o];
            const g: i32 = bgra[o + 1];
            const r: i32 = bgra[o + 2];
            y[@as(usize, row) * w + col] = clamp8((77 * r + 150 * g + 29 * b) >> 8);
        }
    }

    // One chroma sample per 2×2 block, from the averaged RGB.
    var cy: u32 = 0;
    while (cy < h / 2) : (cy += 1) {
        var cx: u32 = 0;
        while (cx < cw) : (cx += 1) {
            const x0 = cx * 2;
            const y0 = cy * 2;
            var rs: i32 = 0;
            var gs: i32 = 0;
            var bs: i32 = 0;
            inline for (.{ 0, 1 }) |dy| inline for (.{ 0, 1 }) |dx| {
                const o = (@as(usize, y0 + dy) * w + (x0 + dx)) * 4;
                bs += bgra[o];
                gs += bgra[o + 1];
                rs += bgra[o + 2];
            };
            const r = @divTrunc(rs, 4);
            const g = @divTrunc(gs, 4);
            const b = @divTrunc(bs, 4);
            u[@as(usize, cy) * cw + cx] = clamp8(((-43 * r - 85 * g + 128 * b) >> 8) + 128);
            v[@as(usize, cy) * cw + cx] = clamp8(((128 * r - 107 * g - 21 * b) >> 8) + 128);
        }
    }
}

/// I420 planes → BGRA (A forced opaque). Inverse of bgraToI420.
pub fn i420ToBgra(y: []const u8, u: []const u8, v: []const u8, w: u32, h: u32, bgra: []u8) void {
    std.debug.assert(w % 2 == 0 and h % 2 == 0);
    std.debug.assert(bgra.len >= @as(usize, w) * h * 4);
    const cw = w / 2;

    var row: u32 = 0;
    while (row < h) : (row += 1) {
        var col: u32 = 0;
        while (col < w) : (col += 1) {
            const yy: i32 = y[@as(usize, row) * w + col];
            const uu: i32 = @as(i32, u[@as(usize, row / 2) * cw + (col / 2)]) - 128;
            const vv: i32 = @as(i32, v[@as(usize, row / 2) * cw + (col / 2)]) - 128;
            const o = (@as(usize, row) * w + col) * 4;
            bgra[o] = clamp8(yy + ((454 * uu) >> 8)); // B
            bgra[o + 1] = clamp8(yy - ((88 * uu) >> 8) - ((183 * vv) >> 8)); // G
            bgra[o + 2] = clamp8(yy + ((359 * vv) >> 8)); // R
            bgra[o + 3] = 255;
        }
    }
}

// ─── tests ──────────────────────────────────────────────────────

const t = std.testing;

test "grayscale survives the round-trip nearly exactly (U=V=128)" {
    const w = 4;
    const h = 4;
    var bgra: [w * h * 4]u8 = undefined;
    for (0..h) |yy| for (0..w) |xx| {
        const o = (yy * w + xx) * 4;
        const g: u8 = @intCast(40 + (yy * w + xx) * 12);
        bgra[o] = g;
        bgra[o + 1] = g;
        bgra[o + 2] = g;
        bgra[o + 3] = 0xff;
    };
    var y: [ySize(w, h)]u8 = undefined;
    var u: [chromaSize(w, h)]u8 = undefined;
    var v: [chromaSize(w, h)]u8 = undefined;
    bgraToI420(&bgra, w, h, &y, &u, &v);
    for (u) |cu| try t.expectApproxEqAbs(@as(f32, 128), @as(f32, @floatFromInt(cu)), 1.5);
    for (v) |cv| try t.expectApproxEqAbs(@as(f32, 128), @as(f32, @floatFromInt(cv)), 1.5);

    var back: [w * h * 4]u8 = undefined;
    i420ToBgra(&y, &u, &v, w, h, &back);
    for (0..w * h) |i| {
        try t.expectApproxEqAbs(@as(f32, @floatFromInt(bgra[i * 4])), @as(f32, @floatFromInt(back[i * 4])), 2);
        try t.expectEqual(@as(u8, 0xff), back[i * 4 + 3]);
    }
}

test "a flat colour round-trips within chroma tolerance" {
    const w = 8;
    const h = 8;
    var bgra: [w * h * 4]u8 = undefined;
    var i: usize = 0;
    while (i < bgra.len) : (i += 4) {
        bgra[i] = 0x20; // B
        bgra[i + 1] = 0x90; // G
        bgra[i + 2] = 0xc0; // R
        bgra[i + 3] = 0xff;
    }
    var y: [ySize(w, h)]u8 = undefined;
    var u: [chromaSize(w, h)]u8 = undefined;
    var v: [chromaSize(w, h)]u8 = undefined;
    bgraToI420(&bgra, w, h, &y, &u, &v);
    var back: [w * h * 4]u8 = undefined;
    i420ToBgra(&y, &u, &v, w, h, &back);
    inline for (.{ 0, 1, 2 }) |ch| {
        try t.expectApproxEqAbs(@as(f32, @floatFromInt(bgra[ch])), @as(f32, @floatFromInt(back[ch])), 3);
    }
}

test "plane sizes for a 64px tile" {
    try t.expectEqual(@as(usize, 64 * 64), ySize(64, 64));
    try t.expectEqual(@as(usize, 32 * 32), chromaSize(64, 64));
}
