//! WebM/VP9 video recorder for app windows — the higher-quality
//! sibling of gifrec.zig. Feeds committed wl_shm frames through a
//! BGRA→I420 conversion, the libvpx VP9 encoder (vendor/vpxenc_shim.c)
//! and a live WebM muxer (webm.zig). GUI-side only: the daemon links
//! no libvpx, so nothing here may be imported by the mux graph.

const std = @import("std");
const png = @import("png.zig");
const webm = @import("webm.zig");

extern fn sk_vpxenc_open(w: c_int, h: c_int, fps: c_int, bitrate_kbps: c_int) ?*anyopaque;
extern fn sk_vpxenc_encode(enc: ?*anyopaque, i420: [*]const u8, force_kf: c_int, out: *[*]const u8, out_size: *usize, is_kf: *c_int) c_int;
extern fn sk_vpxenc_flush(enc: ?*anyopaque, out: *[*]const u8, out_size: *usize, is_kf: *c_int) c_int;
extern fn sk_vpxenc_close(enc: ?*anyopaque) void;

pub const Error = error{ EncodeFailed, OutOfMemory };

pub const Rec = struct {
    allocator: std.mem.Allocator,
    mux: webm.Muxer,
    enc: ?*anyopaque = null,
    /// Encoding dims (even), fixed by the first frame after downscale.
    w: u32 = 0,
    h: u32 = 0,
    /// Source dims of the first frame (resize detector).
    src_w: u32 = 0,
    src_h: u32 = 0,
    max_dim: u32 = 0,
    start_ms: i64 = 0,
    frames: usize = 0,
    dropped: usize = 0,
    first: bool = true,

    pub fn init(allocator: std.mem.Allocator, max_dim: u32) Rec {
        return .{ .allocator = allocator, .mux = webm.Muxer.init(allocator), .max_dim = max_dim };
    }

    /// Feed one committed wl_shm frame (BGRA/XRGB, stride = w*4).
    pub fn addShmFrame(self: *Rec, pixels: []const u8, w: u32, h: u32, format: u32, now_ms: i64) Error!void {
        if (w == 0 or h == 0) return;
        if (self.first) {
            self.src_w = w;
            self.src_h = h;
        } else if (w != self.src_w or h != self.src_h) {
            self.dropped += 1; // one stream size only; skip resized frames
            return;
        }

        // Target (even) dims after optional downscale.
        var fw = w;
        var fh = h;
        const longest = @max(w, h);
        if (self.max_dim != 0 and longest > self.max_dim) {
            fw = @max(2, w * self.max_dim / longest);
            fh = @max(2, h * self.max_dim / longest);
        }
        fw &= ~@as(u32, 1);
        fh &= ~@as(u32, 1);
        if (fw < 2 or fh < 2) return;

        var rgba = png.shmToRgba(self.allocator, pixels, w, h, w * 4, format) catch |e| switch (e) {
            // A frame whose buffer disagrees with its geometry is
            // skipped like a degenerate-size frame, not a fatal error.
            error.BadGeometry => return,
            else => return Error.OutOfMemory,
        };
        defer self.allocator.free(rgba);
        if (fw != w or fh != h) {
            const small = png.downscaleRgba(self.allocator, rgba, w, h, fw, fh) catch return Error.OutOfMemory;
            self.allocator.free(rgba);
            rgba = small;
        }

        if (self.first) {
            self.first = false;
            self.w = fw;
            self.h = fh;
            self.start_ms = now_ms;
            self.enc = sk_vpxenc_open(@intCast(fw), @intCast(fh), 30, targetBitrate(fw, fh));
            if (self.enc == null) return Error.EncodeFailed;
            self.mux.writeHeader(fw, fh) catch return Error.EncodeFailed;
        }

        const yuv = self.allocator.alloc(u8, fw * fh + 2 * (fw / 2) * (fh / 2)) catch return Error.OutOfMemory;
        defer self.allocator.free(yuv);
        rgbaToI420(rgba, fw, fh, yuv);

        const force_kf: c_int = if (self.frames == 0) 1 else 0;
        var out: [*]const u8 = undefined;
        var out_size: usize = 0;
        var is_kf: c_int = 0;
        const r = sk_vpxenc_encode(self.enc, yuv.ptr, force_kf, &out, &out_size, &is_kf);
        if (r < 0) return Error.EncodeFailed;
        if (r == 1) {
            self.mux.addFrame(out[0..out_size], now_ms - self.start_ms, is_kf != 0) catch return Error.EncodeFailed;
        }
        self.frames += 1;
    }

    /// Flush the encoder and return the finished WebM bytes (caller owns).
    pub fn finish(self: *Rec, now_ms: i64) Error![]u8 {
        if (self.enc) |enc| {
            while (true) {
                var out: [*]const u8 = undefined;
                var out_size: usize = 0;
                var is_kf: c_int = 0;
                const r = sk_vpxenc_flush(enc, &out, &out_size, &is_kf);
                if (r != 1) break;
                self.mux.addFrame(out[0..out_size], now_ms - self.start_ms, is_kf != 0) catch break;
            }
            sk_vpxenc_close(enc);
            self.enc = null;
        }
        if (self.frames == 0) return Error.EncodeFailed;
        const bytes = self.mux.finish() catch return Error.EncodeFailed;
        return bytes;
    }

    pub fn abort(self: *Rec) void {
        if (self.enc) |enc| {
            sk_vpxenc_close(enc);
            self.enc = null;
        }
        self.mux.deinit();
    }
};

/// A rough VBR target scaling with pixel count (kbps).
fn targetBitrate(w: u32, h: u32) c_int {
    const px = w * h;
    // ~2 bits per pixel-ish at 30fps, clamped to a sane band.
    const kbps = @max(500, @min(8000, px / 256));
    return @intCast(kbps);
}

/// BT.601 limited-range RGBA→I420. Chroma is 2x2-averaged.
fn rgbaToI420(rgba: []const u8, w: u32, h: u32, out: []u8) void {
    const y_plane = out[0 .. w * h];
    const u_plane = out[w * h .. w * h + (w / 2) * (h / 2)];
    const v_plane = out[w * h + (w / 2) * (h / 2) ..];

    var yy: u32 = 0;
    while (yy < h) : (yy += 1) {
        var xx: u32 = 0;
        while (xx < w) : (xx += 1) {
            const i = (yy * w + xx) * 4;
            const r: i32 = rgba[i];
            const g: i32 = rgba[i + 1];
            const b: i32 = rgba[i + 2];
            const y = ((66 * r + 129 * g + 25 * b + 128) >> 8) + 16;
            y_plane[yy * w + xx] = @intCast(std.math.clamp(y, 0, 255));
        }
    }
    // Chroma: average each 2x2 block.
    const cw = w / 2;
    const ch = h / 2;
    var cy: u32 = 0;
    while (cy < ch) : (cy += 1) {
        var cx: u32 = 0;
        while (cx < cw) : (cx += 1) {
            var rs: i32 = 0;
            var gs: i32 = 0;
            var bs: i32 = 0;
            var dy: u32 = 0;
            while (dy < 2) : (dy += 1) {
                var dx: u32 = 0;
                while (dx < 2) : (dx += 1) {
                    const px = (cx * 2 + dx);
                    const py = (cy * 2 + dy);
                    const i = (py * w + px) * 4;
                    rs += rgba[i];
                    gs += rgba[i + 1];
                    bs += rgba[i + 2];
                }
            }
            const r = @divTrunc(rs, 4);
            const g = @divTrunc(gs, 4);
            const b = @divTrunc(bs, 4);
            const u = ((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128;
            const v = ((112 * r - 94 * g - 18 * b + 128) >> 8) + 128;
            u_plane[cy * cw + cx] = @intCast(std.math.clamp(u, 0, 255));
            v_plane[cy * cw + cx] = @intCast(std.math.clamp(v, 0, 255));
        }
    }
}

test "rgbaToI420 dimensions and mid-gray" {
    const a = std.testing.allocator;
    const w = 4;
    const h = 4;
    const rgba = try a.alloc(u8, w * h * 4);
    defer a.free(rgba);
    @memset(rgba, 128);
    const yuv = try a.alloc(u8, w * h + 2 * (w / 2) * (h / 2));
    defer a.free(yuv);
    rgbaToI420(rgba, w, h, yuv);
    // Mid gray → Y ~125, U/V ~128.
    try std.testing.expect(yuv[0] > 115 and yuv[0] < 135);
    const u_val = yuv[w * h];
    try std.testing.expect(u_val > 120 and u_val < 136);
}
