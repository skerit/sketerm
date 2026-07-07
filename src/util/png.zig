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
