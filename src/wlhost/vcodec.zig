//! Video-tile codec layer — the LOSSY / temporal path for HOT regions
//! (src/util/churn.zig decides which). Sibling of pixcodec (lossless):
//! where pixcodec encodes a self-contained region, vcodec encodes a tile
//! as an opaque, possibly inter-frame-predicted bitstream plus the
//! framing a receiver needs to decode it and place it in the window
//! backing buffer.
//!
//! Step 1 (this file) ships ONLY a `stub` backend — raw BGRA passthrough,
//! every tile a keyframe — so the entire transport → decode → composite
//! path is testable with no real codec linked. x264 / AV1 / hardware
//! backends slot behind the same `Encoder`/`Decoder` interface (the way
//! winstream/source.zig swaps Stub for the SCK backend). Pure std,
//! daemon-safe; the future C backends link via extern fn like zstd.

const std = @import("std");
const build_options = @import("build_options");
const yuv = @import("../util/yuv.zig");

/// libx264 is linked (build_options.video). When false the x264 backend
/// collapses to `void`, mirroring winstream/source.zig's SckImpl.
const have_video = build_options.video;
const X264Impl = if (have_video) X264 else void;
const AvDecImpl = if (have_video) AvDec else void;

pub const Error = error{ UnknownCodec, SizeMismatch, Malformed, TooLong, Decode, Unsupported, X264 };

/// Which codec produced a tile's bitstream — tells the receiver which
/// decoder to run, chosen by capability negotiation. Append-only;
/// `stub` is always decodable so it's the universal fallback.
pub const Codec = enum(u8) {
    stub = 0,
    h264 = 1,
    av1 = 2,
    _,
};

// ─── wire framing ───────────────────────────────────────────────
//
// One encoded tile: codec, flags (bit0 = keyframe — self-contained, no
// dependency on a prior frame), the tile's window-space rect, a
// monotonic seq for loss/order detection over UDP, then the opaque
// bitstream. Length-prefixed like the other unit streams so it rides any
// carrier (winstream channel / wayland pipe) and split-resilient peeling
// works the same way.

/// codec(1) + flags(1) + x(4) + y(4) + w(4) + h(4) + seq(4)
pub const header_size = 22;
pub const max_payload = 64 << 20; // a 4K BGRA keyframe worst-case bound

const flag_keyframe: u8 = 1 << 0;

pub const Tile = struct {
    codec: Codec,
    keyframe: bool,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    seq: u32,
    payload: []const u8,
};

/// Append one tile, length-prefixed (u32 total-after-len, then header +
/// payload) so receivers reassemble across carrier-frame splits.
pub fn appendTile(out: *std.ArrayList(u8), a: std.mem.Allocator, tile: Tile) !void {
    const body = header_size + tile.payload.len;
    var hdr: [4 + header_size]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], @intCast(body), .little);
    hdr[4] = @intFromEnum(tile.codec);
    hdr[5] = if (tile.keyframe) flag_keyframe else 0;
    std.mem.writeInt(i32, hdr[6..10], tile.x, .little);
    std.mem.writeInt(i32, hdr[10..14], tile.y, .little);
    std.mem.writeInt(i32, hdr[14..18], tile.w, .little);
    std.mem.writeInt(i32, hdr[18..22], tile.h, .little);
    std.mem.writeInt(u32, hdr[22..26], tile.seq, .little);
    try out.appendSlice(a, &hdr);
    try out.appendSlice(a, tile.payload);
}

/// Split one tile off the front of `bytes`; null when incomplete.
pub fn peelTile(bytes: []const u8) error{ Malformed, TooLong }!?struct { tile: Tile, consumed: usize } {
    if (bytes.len < 4) return null;
    const body = std.mem.readInt(u32, bytes[0..4], .little);
    if (body < header_size) return error.Malformed;
    if (body - header_size > max_payload) return error.TooLong;
    if (bytes.len < 4 + body) return null;
    const h = bytes[4 .. 4 + header_size];
    return .{
        .tile = .{
            .codec = @enumFromInt(h[0]),
            .keyframe = (h[1] & flag_keyframe) != 0,
            .x = std.mem.readInt(i32, h[2..6], .little),
            .y = std.mem.readInt(i32, h[6..10], .little),
            .w = std.mem.readInt(i32, h[10..14], .little),
            .h = std.mem.readInt(i32, h[14..18], .little),
            .seq = std.mem.readInt(u32, h[18..22], .little),
            .payload = bytes[4 + header_size .. 4 + body],
        },
        .consumed = 4 + body,
    };
}

// ─── encoder ────────────────────────────────────────────────────

pub const EncodeResult = struct { keyframe: bool, bytes: []const u8 };

/// Tagged dispatch the daemon holds; real backends become new variants
/// (collapsing to nothing on builds that don't link them). The interface
/// supports stateful inter-frame coding (`force_keyframe`, per-tile
/// reference state) even though the stub is stateless.
pub const Encoder = union(enum) {
    stub: Stub,
    x264: X264Impl,

    pub fn initStub(allocator: std.mem.Allocator) Encoder {
        return .{ .stub = .{ .allocator = allocator } };
    }

    /// Open a fixed-size H.264 encoder for `w`×`h` tiles. Errors with
    /// Unsupported when libx264 isn't linked (build_options.video off).
    pub fn initX264(allocator: std.mem.Allocator, w: i32, h: i32, fps: i32) !Encoder {
        if (comptime have_video) return .{ .x264 = try X264.init(allocator, w, h, fps) };
        return Error.Unsupported;
    }

    pub fn deinit(self: *Encoder) void {
        switch (self.*) {
            .stub => |*s| s.deinit(),
            .x264 => |*s| if (comptime have_video) s.deinit(),
        }
    }

    pub fn codec(self: *const Encoder) Codec {
        return switch (self.*) {
            .stub => .stub,
            .x264 => .h264,
        };
    }

    /// Encode one tile of tight BGRA (`w*4` stride, len `w*h*4`).
    /// `force_keyframe` requests a self-contained frame (first encode,
    /// scene change, or loss recovery). The returned bytes ALIAS internal
    /// scratch (or `pixels` for the stub) — valid until the next call.
    pub fn encodeTile(self: *Encoder, w: i32, h: i32, pixels: []const u8, force_keyframe: bool) !EncodeResult {
        return switch (self.*) {
            .stub => |*s| s.encodeTile(w, h, pixels, force_keyframe),
            .x264 => |*s| if (comptime have_video) s.encodeTile(w, h, pixels, force_keyframe) else Error.Unsupported,
        };
    }
};

/// libx264 backend via vendor/x264_shim.c. Fixed tile geometry (one
/// encoder per tile size); BGRA→I420 through yuv.zig, then low-latency
/// H.264. Compiled only when build_options.video is set.
const X264 = struct {
    allocator: std.mem.Allocator,
    handle: ?*anyopaque,
    w: i32,
    h: i32,
    yp: []u8,
    up: []u8,
    vp: []u8,
    out: std.ArrayList(u8) = .empty,

    extern fn sk_x264_open(width: c_int, height: c_int, fps: c_int) ?*anyopaque;
    extern fn sk_x264_encode(enc: ?*anyopaque, y: [*]const u8, u: [*]const u8, v: [*]const u8, force_kf: c_int, out: *[*]const u8, is_kf: *c_int) c_int;
    extern fn sk_x264_close(enc: ?*anyopaque) void;

    fn init(allocator: std.mem.Allocator, w: i32, h: i32, fps: i32) !X264 {
        if (w <= 0 or h <= 0 or @rem(w, 2) != 0 or @rem(h, 2) != 0) return Error.SizeMismatch;
        const uw: u32 = @intCast(w);
        const uh: u32 = @intCast(h);
        const handle = sk_x264_open(w, h, fps) orelse return Error.X264;
        errdefer sk_x264_close(handle);
        const yp = try allocator.alloc(u8, yuv.ySize(uw, uh));
        errdefer allocator.free(yp);
        const up = try allocator.alloc(u8, yuv.chromaSize(uw, uh));
        errdefer allocator.free(up);
        const vp = try allocator.alloc(u8, yuv.chromaSize(uw, uh));
        return .{ .allocator = allocator, .handle = handle, .w = w, .h = h, .yp = yp, .up = up, .vp = vp };
    }

    fn deinit(self: *X264) void {
        sk_x264_close(self.handle);
        self.allocator.free(self.yp);
        self.allocator.free(self.up);
        self.allocator.free(self.vp);
        self.out.deinit(self.allocator);
    }

    fn encodeTile(self: *X264, w: i32, h: i32, pixels: []const u8, force_keyframe: bool) !EncodeResult {
        if (w != self.w or h != self.h) return Error.SizeMismatch;
        const uw: u32 = @intCast(w);
        const uh: u32 = @intCast(h);
        if (pixels.len != @as(usize, uw) * uh * 4) return Error.SizeMismatch;
        yuv.bgraToI420(pixels, uw, uh, self.yp, self.up, self.vp);

        var out_ptr: [*]const u8 = undefined;
        var is_kf: c_int = 0;
        const n = sk_x264_encode(self.handle, self.yp.ptr, self.up.ptr, self.vp.ptr, if (force_keyframe) 1 else 0, &out_ptr, &is_kf);
        if (n <= 0) return Error.X264; // zerolatency should never buffer
        self.out.clearRetainingCapacity();
        try self.out.appendSlice(self.allocator, out_ptr[0..@intCast(n)]);
        return .{ .keyframe = is_kf != 0, .bytes = self.out.items };
    }
};

/// Raw passthrough: payload IS the BGRA, every tile a keyframe. Exists
/// so the transport/decode/composite pipeline is exercised end-to-end
/// without a codec — exactly the role winstream's Stub source plays.
pub const Stub = struct {
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Stub) void {
        _ = self;
    }

    pub fn encodeTile(self: *Stub, w: i32, h: i32, pixels: []const u8, force_keyframe: bool) !EncodeResult {
        _ = self;
        _ = force_keyframe; // raw is always self-contained
        if (w <= 0 or h <= 0) return Error.SizeMismatch;
        const need = @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4;
        if (pixels.len != need) return Error.SizeMismatch;
        return .{ .keyframe = true, .bytes = pixels };
    }
};

// ─── decoder ────────────────────────────────────────────────────

pub const Decoder = union(enum) {
    stub: Stub_,
    avcodec: AvDecImpl,

    pub fn initStub(allocator: std.mem.Allocator) Decoder {
        return .{ .stub = .{ .allocator = allocator } };
    }

    /// Open a fixed-size H.264 software decoder (libavcodec) for `w`×`h`
    /// tiles. Errors Unsupported without -Dvideo.
    pub fn initAvcodec(allocator: std.mem.Allocator, w: i32, h: i32) !Decoder {
        if (comptime have_video) return .{ .avcodec = try AvDec.init(allocator, w, h) };
        return Error.Unsupported;
    }

    pub fn deinit(self: *Decoder) void {
        switch (self.*) {
            .stub => |*s| s.deinit(),
            .avcodec => |*s| if (comptime have_video) s.deinit(),
        }
    }

    /// Decode `tile`'s bitstream into `dst`, which MUST be `w*h*4`.
    pub fn decodeTile(self: *Decoder, tile: Tile, dst: []u8) Error!void {
        return switch (self.*) {
            .stub => |*s| s.decodeTile(tile, dst),
            .avcodec => |*s| if (comptime have_video) s.decodeTile(tile, dst) else Error.Unsupported,
        };
    }

    /// The Stub decoder accepts only `stub`-coded tiles; real decoders
    /// are added as variants and chosen to match the negotiated codec.
    pub const Stub_ = struct {
        allocator: std.mem.Allocator,

        pub fn deinit(self: *Stub_) void {
            _ = self;
        }

        pub fn decodeTile(self: *Stub_, tile: Tile, dst: []u8) Error!void {
            _ = self;
            if (tile.codec != .stub) return Error.UnknownCodec;
            if (tile.w <= 0 or tile.h <= 0) return Error.SizeMismatch;
            const need = @as(usize, @intCast(tile.w)) * @as(usize, @intCast(tile.h)) * 4;
            if (dst.len != need or tile.payload.len != need) return Error.SizeMismatch;
            @memcpy(dst, tile.payload);
        }
    };
};

/// libavcodec H.264 software decoder via vendor/avdec_shim.c. Fixed tile
/// geometry; decodes an Annex-B tile to I420 then yuv.zig → BGRA. The
/// daemon never instantiates this (it encodes); it's the GUI/compositor
/// receive path. Compiled only when build_options.video is set.
const AvDec = struct {
    allocator: std.mem.Allocator,
    handle: ?*anyopaque,
    w: i32,
    h: i32,
    yp: []u8,
    up: []u8,
    vp: []u8,

    extern fn sk_avdec_open() ?*anyopaque;
    extern fn sk_avdec_decode(dec: ?*anyopaque, data: [*]const u8, len: c_int, exp_w: c_int, exp_h: c_int, y: [*]u8, u: [*]u8, v: [*]u8) c_int;
    extern fn sk_avdec_close(dec: ?*anyopaque) void;

    fn init(allocator: std.mem.Allocator, w: i32, h: i32) !AvDec {
        if (w <= 0 or h <= 0 or @rem(w, 2) != 0 or @rem(h, 2) != 0) return Error.SizeMismatch;
        const uw: u32 = @intCast(w);
        const uh: u32 = @intCast(h);
        const handle = sk_avdec_open() orelse return Error.Decode;
        errdefer sk_avdec_close(handle);
        const yp = try allocator.alloc(u8, yuv.ySize(uw, uh));
        errdefer allocator.free(yp);
        const up = try allocator.alloc(u8, yuv.chromaSize(uw, uh));
        errdefer allocator.free(up);
        const vp = try allocator.alloc(u8, yuv.chromaSize(uw, uh));
        return .{ .allocator = allocator, .handle = handle, .w = w, .h = h, .yp = yp, .up = up, .vp = vp };
    }

    fn deinit(self: *AvDec) void {
        sk_avdec_close(self.handle);
        self.allocator.free(self.yp);
        self.allocator.free(self.up);
        self.allocator.free(self.vp);
    }

    fn decodeTile(self: *AvDec, tile: Tile, dst: []u8) Error!void {
        if (tile.codec != .h264) return Error.UnknownCodec;
        if (tile.w != self.w or tile.h != self.h) return Error.SizeMismatch;
        const uw: u32 = @intCast(self.w);
        const uh: u32 = @intCast(self.h);
        if (dst.len != @as(usize, uw) * uh * 4) return Error.SizeMismatch;
        const n = sk_avdec_decode(self.handle, tile.payload.ptr, @intCast(tile.payload.len), self.w, self.h, self.yp.ptr, self.up.ptr, self.vp.ptr);
        if (n != 1) return Error.Decode; // 0 = no frame yet, <0 = error
        yuv.i420ToBgra(self.yp, self.up, self.vp, uw, uh, dst);
    }
};

// ─── tests ──────────────────────────────────────────────────────

const t = std.testing;

test "tile wire round-trips and peels across split points" {
    const a = t.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);

    var px: [4 * 2 * 4]u8 = undefined;
    for (&px, 0..) |*b, i| b.* = @intCast(i);
    try appendTile(&out, a, .{ .codec = .stub, .keyframe = true, .x = 10, .y = 20, .w = 4, .h = 2, .seq = 7, .payload = &px });

    // Partial buffers peel to null, never error, up to the full unit.
    var cut: usize = 0;
    while (cut < out.items.len) : (cut += 1) {
        try t.expect((try peelTile(out.items[0..cut])) == null);
    }
    const p = (try peelTile(out.items)).?;
    try t.expectEqual(out.items.len, p.consumed);
    try t.expectEqual(Codec.stub, p.tile.codec);
    try t.expect(p.tile.keyframe);
    try t.expectEqual(@as(i32, 10), p.tile.x);
    try t.expectEqual(@as(i32, 2), p.tile.h);
    try t.expectEqual(@as(u32, 7), p.tile.seq);
    try t.expectEqualSlices(u8, &px, p.tile.payload);
}

test "malformed and over-long headers are rejected" {
    // body < header_size.
    const bad = [_]u8{ 5, 0, 0, 0, 0 };
    try t.expectError(error.Malformed, peelTile(&bad));
    // body claims an absurd payload.
    var big: [4]u8 = undefined;
    std.mem.writeInt(u32, &big, header_size + max_payload + 1, .little);
    try t.expectError(error.TooLong, peelTile(&big));
}

test "stub encode → wire → stub decode reproduces the tile" {
    const a = t.allocator;
    var enc = Encoder.initStub(a);
    defer enc.deinit();
    var dec = Decoder.initStub(a);
    defer dec.deinit();

    const w = 8;
    const h = 5;
    var px: [w * h * 4]u8 = undefined;
    for (&px, 0..) |*b, i| b.* = @truncate(i * 7 + 3);

    const r = try enc.encodeTile(w, h, &px, false);
    try t.expect(r.keyframe); // stub is always self-contained

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try appendTile(&out, a, .{ .codec = enc.codec(), .keyframe = r.keyframe, .x = 0, .y = 0, .w = w, .h = h, .seq = 1, .payload = r.bytes });

    const p = (try peelTile(out.items)).?;
    var dst: [w * h * 4]u8 = undefined;
    try dec.decodeTile(p.tile, &dst);
    try t.expectEqualSlices(u8, &px, &dst);
}

test "decoder rejects wrong codec and mismatched sizes" {
    const a = t.allocator;
    var dec = Decoder.initStub(a);
    defer dec.deinit();
    var dst: [16]u8 = undefined;

    var px: [16]u8 = undefined;
    try dec.decodeTile(.{ .codec = .stub, .keyframe = true, .x = 0, .y = 0, .w = 2, .h = 2, .seq = 0, .payload = &px }, &dst); // ok

    try t.expectError(Error.UnknownCodec, dec.decodeTile(.{ .codec = .h264, .keyframe = true, .x = 0, .y = 0, .w = 2, .h = 2, .seq = 0, .payload = &px }, &dst));
    var small: [4]u8 = undefined;
    try t.expectError(Error.SizeMismatch, dec.decodeTile(.{ .codec = .stub, .keyframe = true, .x = 0, .y = 0, .w = 2, .h = 2, .seq = 0, .payload = &px }, &small));
}

test "stub encoder rejects a pixel buffer that isn't w*h*4" {
    const a = t.allocator;
    var enc = Encoder.initStub(a);
    defer enc.deinit();
    var px: [10]u8 = undefined;
    try t.expectError(Error.SizeMismatch, enc.encodeTile(2, 2, &px, true)); // needs 16
}

test "x264 backend encodes a keyframe Annex-B stream (when libx264 linked)" {
    if (!have_video) return error.SkipZigTest;
    const a = t.allocator;
    const w = 64;
    const h = 64;
    var enc = try Encoder.initX264(a, w, h, 30);
    defer enc.deinit();
    try t.expectEqual(Codec.h264, enc.codec());

    var px: [w * h * 4]u8 = undefined;
    for (0..h) |yy| for (0..w) |xx| {
        const o = (yy * w + xx) * 4;
        px[o + 0] = @truncate(xx * 3);
        px[o + 1] = @truncate(yy * 3);
        px[o + 2] = @truncate((xx + yy) * 2);
        px[o + 3] = 0xff;
    };
    const r = try enc.encodeTile(w, h, &px, true);
    try t.expect(r.keyframe);
    // Real Annex-B H.264 begins with a start code (00 00 00 01 / 00 00 01).
    try t.expect(r.bytes.len >= 4);
    try t.expectEqual(@as(u8, 0), r.bytes[0]);
    try t.expectEqual(@as(u8, 0), r.bytes[1]);
    // A second frame (non-forced) still encodes without error.
    const r2 = try enc.encodeTile(w, h, &px, false);
    try t.expect(r2.bytes.len > 0);

    // Wrong tile size is rejected.
    try t.expectError(Error.SizeMismatch, enc.encodeTile(32, 32, &px, false));
}

test "x264 encode → avcodec decode round-trips a frame (-Dvideo)" {
    if (!have_video) return error.SkipZigTest;
    const a = t.allocator;
    const w = 64;
    const h = 64;
    var enc = try Encoder.initX264(a, w, h, 30);
    defer enc.deinit();
    var dec = try Decoder.initAvcodec(a, w, h);
    defer dec.deinit();
    try t.expectEqual(Codec.h264, enc.codec());

    // Smooth grayscale gradient: neutral chroma + low frequency, so the
    // lossy 4:2:0 H.264 round-trip stays close.
    var px: [w * h * 4]u8 = undefined;
    for (0..h) |yy| for (0..w) |xx| {
        const o = (yy * w + xx) * 4;
        const v: u8 = @truncate(40 + xx + yy);
        px[o] = v;
        px[o + 1] = v;
        px[o + 2] = v;
        px[o + 3] = 0xff;
    };
    const r = try enc.encodeTile(w, h, &px, true);
    try t.expect(r.keyframe);

    var dst: [w * h * 4]u8 = undefined;
    try dec.decodeTile(.{ .codec = enc.codec(), .keyframe = r.keyframe, .x = 0, .y = 0, .w = w, .h = h, .seq = 0, .payload = r.bytes }, &dst);

    // Lossy → compare by mean absolute error over RGB; alpha forced opaque.
    var sum: u64 = 0;
    for (0..w * h) |i| {
        inline for (.{ 0, 1, 2 }) |ch| {
            const dv: i32 = @as(i32, px[i * 4 + ch]) - @as(i32, dst[i * 4 + ch]);
            sum += @abs(dv);
        }
        try t.expectEqual(@as(u8, 0xff), dst[i * 4 + 3]);
    }
    const mae = @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(w * h * 3));
    try t.expect(mae < 15.0);
}
