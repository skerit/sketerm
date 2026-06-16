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

pub const Error = error{ UnknownCodec, SizeMismatch, Malformed, TooLong, Decode };

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

    pub fn initStub(allocator: std.mem.Allocator) Encoder {
        return .{ .stub = .{ .allocator = allocator } };
    }

    pub fn deinit(self: *Encoder) void {
        switch (self.*) {
            .stub => |*s| s.deinit(),
        }
    }

    pub fn codec(self: *const Encoder) Codec {
        return switch (self.*) {
            .stub => .stub,
        };
    }

    /// Encode one tile of tight BGRA (`w*4` stride, len `w*h*4`).
    /// `force_keyframe` requests a self-contained frame (first encode,
    /// scene change, or loss recovery). The returned bytes ALIAS internal
    /// scratch (or `pixels` for the stub) — valid until the next call.
    pub fn encodeTile(self: *Encoder, w: i32, h: i32, pixels: []const u8, force_keyframe: bool) !EncodeResult {
        return switch (self.*) {
            .stub => |*s| s.encodeTile(w, h, pixels, force_keyframe),
        };
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

    pub fn initStub(allocator: std.mem.Allocator) Decoder {
        return .{ .stub = .{ .allocator = allocator } };
    }

    pub fn deinit(self: *Decoder) void {
        switch (self.*) {
            .stub => |*s| s.deinit(),
        }
    }

    /// Decode `tile`'s bitstream into `dst`, which MUST be `w*h*4`.
    pub fn decodeTile(self: *Decoder, tile: Tile, dst: []u8) Error!void {
        return switch (self.*) {
            .stub => |*s| s.decodeTile(tile, dst),
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
