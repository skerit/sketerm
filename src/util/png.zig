//! In-memory PNG encoding on vendored stb_image_write. Importable
//! from both dependency sets (GUI cbindings and the lean mux core
//! set) — libc + stb only, no GTK/GLib.

const std = @import("std");
const c = @import("../c.zig").c;

pub const Error = error{ EncodeFailed, OutOfMemory };

const Sink = struct {
    allocator: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    failed: bool = false,

    fn write(ctx: ?*anyopaque, data: ?*anyopaque, size: c_int) callconv(.c) void {
        const self: *Sink = @ptrCast(@alignCast(ctx.?));
        if (self.failed or size <= 0) return;
        const bytes: [*]const u8 = @ptrCast(data.?);
        self.buf.appendSlice(self.allocator, bytes[0..@intCast(size)]) catch {
            self.failed = true;
        };
    }
};

/// Encode tightly-packed RGBA pixels to PNG. Caller owns the result.
pub fn encodeRgba(allocator: std.mem.Allocator, rgba: []const u8, w: u32, h: u32) Error![]u8 {
    std.debug.assert(rgba.len >= @as(usize, w) * h * 4);
    var sink = Sink{ .allocator = allocator };
    errdefer sink.buf.deinit(allocator);
    const ok = c.stbi_write_png_to_func(
        Sink.write,
        &sink,
        @intCast(w),
        @intCast(h),
        4,
        rgba.ptr,
        @intCast(w * 4),
    );
    if (ok == 0 or sink.failed) {
        sink.buf.deinit(allocator);
        return Error.EncodeFailed;
    }
    return sink.buf.toOwnedSlice(allocator);
}

/// wl_shm buffer formats we mirror (values per the Wayland protocol).
pub const ShmFormat = enum(u32) {
    argb8888 = 0,
    xrgb8888 = 1,
    _,
};

/// Convert a wl_shm ARGB/XRGB buffer (little-endian, so B,G,R,A byte
/// order, ARGB premultiplied) to straight RGBA. `stride` is the input
/// row pitch in bytes (>= w*4). Caller owns the result.
pub fn shmToRgba(
    allocator: std.mem.Allocator,
    pixels: []const u8,
    w: u32,
    h: u32,
    stride: u32,
    format: u32,
) Error![]u8 {
    std.debug.assert(stride >= w * 4);
    std.debug.assert(pixels.len >= @as(usize, stride) * h);
    const opaque_alpha = format == @intFromEnum(ShmFormat.xrgb8888);
    const out = try allocator.alloc(u8, @as(usize, w) * h * 4);
    errdefer allocator.free(out);
    var y: usize = 0;
    while (y < h) : (y += 1) {
        const src_row = pixels[y * stride ..][0 .. @as(usize, w) * 4];
        const dst_row = out[y * @as(usize, w) * 4 ..][0 .. @as(usize, w) * 4];
        var x: usize = 0;
        while (x < w) : (x += 1) {
            const b = src_row[x * 4 + 0];
            const g = src_row[x * 4 + 1];
            const r = src_row[x * 4 + 2];
            const a: u8 = if (opaque_alpha) 255 else src_row[x * 4 + 3];
            if (!opaque_alpha and a != 0 and a != 255) {
                // Un-premultiply so the PNG carries straight alpha.
                dst_row[x * 4 + 0] = @intCast(@min(255, (@as(u32, r) * 255 + a / 2) / a));
                dst_row[x * 4 + 1] = @intCast(@min(255, (@as(u32, g) * 255 + a / 2) / a));
                dst_row[x * 4 + 2] = @intCast(@min(255, (@as(u32, b) * 255 + a / 2) / a));
            } else {
                dst_row[x * 4 + 0] = r;
                dst_row[x * 4 + 1] = g;
                dst_row[x * 4 + 2] = b;
            }
            dst_row[x * 4 + 3] = a;
        }
    }
    return out;
}

/// Box-filter downscale of tightly-packed RGBA to dst_w x dst_h
/// (each destination pixel averages its full source footprint, so
/// thin UI lines darken instead of vanishing). Caller owns the result.
pub fn downscaleRgba(
    allocator: std.mem.Allocator,
    rgba: []const u8,
    w: u32,
    h: u32,
    dst_w: u32,
    dst_h: u32,
) Error![]u8 {
    std.debug.assert(dst_w > 0 and dst_h > 0 and dst_w <= w and dst_h <= h);
    std.debug.assert(rgba.len >= @as(usize, w) * h * 4);
    const out = try allocator.alloc(u8, @as(usize, dst_w) * dst_h * 4);
    errdefer allocator.free(out);
    var dy: u32 = 0;
    while (dy < dst_h) : (dy += 1) {
        const sy0: u32 = @intCast(@as(u64, dy) * h / dst_h);
        var sy1: u32 = @intCast((@as(u64, dy) + 1) * h / dst_h);
        if (sy1 <= sy0) sy1 = sy0 + 1;
        var dx: u32 = 0;
        while (dx < dst_w) : (dx += 1) {
            const sx0: u32 = @intCast(@as(u64, dx) * w / dst_w);
            var sx1: u32 = @intCast((@as(u64, dx) + 1) * w / dst_w);
            if (sx1 <= sx0) sx1 = sx0 + 1;
            var acc = [4]u64{ 0, 0, 0, 0 };
            var sy = sy0;
            while (sy < sy1) : (sy += 1) {
                var sx = sx0;
                while (sx < sx1) : (sx += 1) {
                    const o = (@as(usize, sy) * w + sx) * 4;
                    acc[0] += rgba[o];
                    acc[1] += rgba[o + 1];
                    acc[2] += rgba[o + 2];
                    acc[3] += rgba[o + 3];
                }
            }
            const n: u64 = @as(u64, sy1 - sy0) * (sx1 - sx0);
            const d = (@as(usize, dy) * dst_w + dx) * 4;
            out[d] = @intCast((acc[0] + n / 2) / n);
            out[d + 1] = @intCast((acc[1] + n / 2) / n);
            out[d + 2] = @intCast((acc[2] + n / 2) / n);
            out[d + 3] = @intCast((acc[3] + n / 2) / n);
        }
    }
    return out;
}

/// Nearest-neighbor integer upscale (pixel-inspection zoom — no
/// smoothing, every source pixel becomes a zoom x zoom block).
/// Caller owns the result.
pub fn upscaleRgba(
    allocator: std.mem.Allocator,
    rgba: []const u8,
    w: u32,
    h: u32,
    zoom: u32,
) Error![]u8 {
    std.debug.assert(zoom >= 1);
    std.debug.assert(rgba.len >= @as(usize, w) * h * 4);
    const dw: usize = @as(usize, w) * zoom;
    const dh: usize = @as(usize, h) * zoom;
    const out = try allocator.alloc(u8, dw * dh * 4);
    errdefer allocator.free(out);
    var dy: usize = 0;
    while (dy < dh) : (dy += 1) {
        const sy = dy / zoom;
        var dx: usize = 0;
        while (dx < dw) : (dx += 1) {
            const sx = dx / zoom;
            const s = (sy * w + sx) * 4;
            const d = (dy * dw + dx) * 4;
            @memcpy(out[d..][0..4], rgba[s..][0..4]);
        }
    }
    return out;
}

/// shmToRgba + encodeRgba in one step. Caller owns the result.
pub fn encodeShm(
    allocator: std.mem.Allocator,
    pixels: []const u8,
    w: u32,
    h: u32,
    stride: u32,
    format: u32,
) Error![]u8 {
    const rgba = try shmToRgba(allocator, pixels, w, h, stride, format);
    defer allocator.free(rgba);
    return encodeRgba(allocator, rgba, w, h);
}

test "png round-trips through stb_image decode" {
    const allocator = std.testing.allocator;
    // 3x2 test card: distinct corner colors catch channel swaps.
    const w = 3;
    const h = 2;
    var rgba = [_]u8{0} ** (w * h * 4);
    const put = struct {
        fn px(buf: []u8, x: usize, y: usize, r: u8, g: u8, b: u8, a: u8) void {
            const o = (y * w + x) * 4;
            buf[o] = r;
            buf[o + 1] = g;
            buf[o + 2] = b;
            buf[o + 3] = a;
        }
    }.px;
    put(&rgba, 0, 0, 255, 0, 0, 255);
    put(&rgba, 1, 0, 0, 255, 0, 255);
    put(&rgba, 2, 0, 0, 0, 255, 255);
    put(&rgba, 0, 1, 10, 20, 30, 255);
    put(&rgba, 1, 1, 200, 100, 50, 255);
    put(&rgba, 2, 1, 255, 255, 255, 255);

    const png = try encodeRgba(allocator, &rgba, w, h);
    defer allocator.free(png);
    try std.testing.expect(png.len > 8);
    // PNG magic.
    try std.testing.expectEqualSlices(u8, &.{ 0x89, 'P', 'N', 'G' }, png[0..4]);

    var dw: c_int = 0;
    var dh: c_int = 0;
    var comp: c_int = 0;
    const decoded = c.stbi_load_from_memory(png.ptr, @intCast(png.len), &dw, &dh, &comp, 4);
    try std.testing.expect(decoded != null);
    defer c.stbi_image_free(decoded);
    try std.testing.expectEqual(@as(c_int, w), dw);
    try std.testing.expectEqual(@as(c_int, h), dh);
    try std.testing.expectEqualSlices(u8, &rgba, decoded[0 .. w * h * 4]);
}

test "downscaleRgba box-averages the full source footprint" {
    const allocator = std.testing.allocator;
    // 4x2 -> 2x1: each output pixel averages a 2x2 block.
    var src = [_]u8{0} ** (4 * 2 * 4);
    // Left 2x2 block: two black + two white pixels -> mid gray.
    src[0 * 4] = 255;
    src[0 * 4 + 1] = 255;
    src[0 * 4 + 2] = 255;
    src[4 * 4] = 255;
    src[4 * 4 + 1] = 255;
    src[4 * 4 + 2] = 255;
    for (0..8) |i| src[i * 4 + 3] = 255;
    const out = try downscaleRgba(allocator, &src, 4, 2, 2, 1);
    defer allocator.free(out);
    try std.testing.expectEqual(@as(u8, 128), out[0]);
    try std.testing.expectEqual(@as(u8, 255), out[3]);
    // Right block was all black.
    try std.testing.expectEqual(@as(u8, 0), out[4]);
}

test "shmToRgba swizzles BGRA and forces xrgb opaque" {
    const allocator = std.testing.allocator;
    // 2x1, stride padded to 12 bytes: pixel0 = red opaque, pixel1 =
    // half-transparent green premultiplied (argb) / junk alpha (xrgb).
    const src = [_]u8{
        0, 0, 255, 255, // B G R A -> red
        0, 128, 0, 128, // premultiplied half green
        0xAA, 0xBB, 0xCC, 0xDD, // stride padding, must be ignored
    } ++ [_]u8{0} ** 0;

    const argb = try shmToRgba(allocator, &src, 2, 1, 12, @intFromEnum(ShmFormat.argb8888));
    defer allocator.free(argb);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, argb[0..4]);
    // Un-premultiplied: 128*255/128 = 255.
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 128 }, argb[4..8]);

    const xrgb = try shmToRgba(allocator, &src, 2, 1, 12, @intFromEnum(ShmFormat.xrgb8888));
    defer allocator.free(xrgb);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, xrgb[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 128, 0, 255 }, xrgb[4..8]);
}

test "upscaleRgba blocks pixels without smoothing" {
    const allocator = std.testing.allocator;
    // 2x1: red then green.
    const src = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 255 };
    const big = try upscaleRgba(allocator, &src, 2, 1, 3);
    defer allocator.free(big);
    try std.testing.expectEqual(@as(usize, 6 * 3 * 4), big.len);
    // First 3 columns of every row red, next 3 green — exact copies.
    for (0..3) |row| {
        for (0..3) |x| {
            const o = (row * 6 + x) * 4;
            try std.testing.expectEqual(@as(u8, 255), big[o]);
            try std.testing.expectEqual(@as(u8, 0), big[o + 1]);
        }
        for (3..6) |x| {
            const o = (row * 6 + x) * 4;
            try std.testing.expectEqual(@as(u8, 0), big[o]);
            try std.testing.expectEqual(@as(u8, 255), big[o + 1]);
        }
    }
}
