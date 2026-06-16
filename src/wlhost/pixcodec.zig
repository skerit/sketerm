//! Codec-tagged encoding of a pixel region — the shared compression
//! layer under BOTH remote-app pixel paths (Wayland shm-pool mirror in
//! wlhost/pipe.zig, macOS window capture in winstream/proto.zig). Runs
//! in the libc-only daemon, the GUI, AND the musl-static portable
//! binary alike: zstd is the vendored single-file lib (build.zig links
//! vendor/zstd/zstd.c into every artifact), reached via extern fn so no
//! header has to survive both @cImport sets.
//!
//! A region is BGRA bytes laid out as rows of `row_stride` bytes. Two
//! orthogonal axes describe an encoding, stored side by side in the
//! body header:
//!   - Coder:  the entropy stage (raw passthrough, or zstd).
//!   - Filter: a PNG spatial predictor applied first (none/sub/up/paeth).
//! Separating them keeps the body extensible (new coder or filter is a
//! new enum value, not a combinatorial tag). The encoder chooses the
//! filter with PNG's minimum-sum-of-absolute-differences heuristic — a
//! cheap scoring pass, NOT a compress-everything sweep — then runs a
//! single zstd pass, falling back to raw when nothing shrinks.

const std = @import("std");

// Vendored single-file zstd (vendor/zstd/zstd.c), static-linked by
// build.zig into every artifact that pulls this module. Only the
// one-shot simple API is used — no dictionaries, no streaming.
extern fn ZSTD_compress(dst: [*]u8, dst_cap: usize, src: [*]const u8, src_size: usize, level: c_int) usize;
extern fn ZSTD_decompress(dst: [*]u8, dst_cap: usize, src: [*]const u8, src_size: usize) usize;
extern fn ZSTD_compressBound(src_size: usize) usize;
extern fn ZSTD_isError(code: usize) c_uint;

/// Compression level. Low end of the range — this runs on the daemon's
/// poll loop, so speed beats ratio; 3 is zstd's default sweet spot.
const zstd_level: c_int = 3;

pub const Error = error{ UnknownCoder, UnknownFilter, SizeMismatch, Zstd };

/// BGRA — the predictor's left neighbour is one pixel (4 bytes) back.
pub const bpp = 4;

/// Entropy stage. Append-only; receivers reject unknown values.
pub const Coder = enum(u8) {
    /// Bytes verbatim (post-filter) — the floor when nothing shrinks.
    raw = 0,
    /// zstd one-shot.
    zstd = 1,
    _,
};

/// Spatial predictor applied before the coder (PNG filter types, bpp=4,
/// per row). Append-only.
pub const Filter = enum(u8) {
    none = 0,
    /// delta from the pixel to the left.
    sub = 1,
    /// delta from the pixel above.
    up = 2,
    /// PNG Paeth predictor of (left, above, up-left).
    paeth = 3,
    _,
};

// ─── PNG predictors ─────────────────────────────────────────────

fn paethPredictor(a: u8, b: u8, c: u8) u8 {
    const ia: i32 = a;
    const ib: i32 = b;
    const ic: i32 = c;
    const p = ia + ib - ic;
    const pa = @abs(p - ia);
    const pb = @abs(p - ib);
    const pc = @abs(p - ic);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

/// Predicted value for byte `i` from its already-available neighbours.
/// Missing neighbours (first row / first column) read as 0, per PNG.
fn predict(filter: Filter, buf: []const u8, i: usize, stride: usize) u8 {
    const col = i % stride;
    const left: u8 = if (col >= bpp) buf[i - bpp] else 0;
    const above: u8 = if (i >= stride) buf[i - stride] else 0;
    const upleft: u8 = if (col >= bpp and i >= stride) buf[i - stride - bpp] else 0;
    return switch (filter) {
        .sub => left,
        .up => above,
        .paeth => paethPredictor(left, above, upleft),
        else => 0,
    };
}

fn effStride(buf_len: usize, row_stride: usize) usize {
    return if (row_stride == 0) buf_len else row_stride;
}

/// Forward filter, IN PLACE. Walks right-to-left so each predictor reads
/// ORIGINAL neighbours (all at smaller indices, not yet rewritten).
fn applyFilter(filter: Filter, buf: []u8, row_stride: usize) void {
    if (filter == .none or buf.len == 0) return;
    const stride = effStride(buf.len, row_stride);
    var i: usize = buf.len;
    while (i > 0) {
        i -= 1;
        buf[i] -%= predict(filter, buf, i, stride);
    }
}

/// Inverse filter, IN PLACE. Walks left-to-right so each predictor reads
/// already-RECONSTRUCTED neighbours.
fn unapplyFilter(filter: Filter, buf: []u8, row_stride: usize) Error!void {
    switch (filter) {
        .none => return,
        .sub, .up, .paeth => {},
        else => return Error.UnknownFilter,
    }
    if (buf.len == 0) return;
    const stride = effStride(buf.len, row_stride);
    var i: usize = 0;
    while (i < buf.len) : (i += 1) {
        buf[i] +%= predict(filter, buf, i, stride);
    }
}

/// PNG minimum-sum-of-absolute-differences score for a filter: the sum
/// of min(v, 256-v) over the would-be filtered bytes (small deltas are
/// cheap to entropy-code). Reads `buf` without mutating it.
fn filterCost(filter: Filter, buf: []const u8, stride: usize) u64 {
    var sum: u64 = 0;
    var i: usize = 0;
    while (i < buf.len) : (i += 1) {
        const f: u8 = buf[i] -% predict(filter, buf, i, stride);
        const fu: u16 = f;
        sum += @min(fu, 256 - fu);
    }
    return sum;
}

/// Pick the filter whose MSAD score is lowest. Four cheap scoring passes,
/// no compression — the actual zstd pass runs once, on the winner.
fn pickFilter(buf: []const u8, row_stride: usize) Filter {
    if (buf.len == 0) return .none;
    const stride = effStride(buf.len, row_stride);
    var best: Filter = .none;
    var best_cost = filterCost(.none, buf, stride);
    inline for (.{ Filter.sub, Filter.up, Filter.paeth }) |f| {
        const cost = filterCost(f, buf, stride);
        if (cost < best_cost) {
            best_cost = cost;
            best = f;
        }
    }
    return best;
}

// ─── encode / decode ────────────────────────────────────────────

/// Result of `encodeRegion`: `bytes` ALIASES Scratch (or `pixels` for
/// `.raw`) and is valid only until the next use of that Scratch.
pub const Encoded = struct { coder: Coder, filter: Filter, bytes: []const u8 };

/// Caller-owned scratch so the poll loop allocates once and reuses.
pub const Scratch = struct {
    work: std.ArrayList(u8) = .empty,
    z: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *Scratch, a: std.mem.Allocator) void {
        self.work.deinit(a);
        self.z.deinit(a);
    }
};

/// Encode `pixels` (rows of `row_stride` bytes): pick the best filter,
/// zstd it once, and keep that only if it beats the raw size — so the
/// result never exceeds `pixels.len`.
pub fn encodeRegion(s: *Scratch, a: std.mem.Allocator, pixels: []const u8, row_stride: usize) !Encoded {
    const filter = pickFilter(pixels, row_stride);

    var src: []const u8 = pixels;
    if (filter != .none) {
        try s.work.resize(a, pixels.len);
        @memcpy(s.work.items, pixels);
        applyFilter(filter, s.work.items, row_stride);
        src = s.work.items;
    }

    try s.z.resize(a, ZSTD_compressBound(src.len));
    const zlen = ZSTD_compress(s.z.items.ptr, s.z.items.len, src.ptr, src.len, zstd_level);
    if (ZSTD_isError(zlen) == 0 and zlen < pixels.len) {
        return .{ .coder = .zstd, .filter = filter, .bytes = s.z.items[0..zlen] };
    }
    // Nothing shrank (or zstd errored): send the original verbatim.
    return .{ .coder = .raw, .filter = .none, .bytes = pixels };
}

// ─── self-describing body ───────────────────────────────────────
//
// What both pixel carriers (pool_update_c, win_frame_c) embed. Carrying
// raw_len + row_stride here — not in the carrier — lets a receiver
// reverse ANY region from the body alone, which the Wayland pool path
// needs since the GUI decodes a pool offset without knowing the buffer's
// stride.

/// u8 coder + u8 filter + u32 raw_len + u32 row_stride.
pub const body_header = 10;

pub const Body = struct {
    coder: Coder,
    filter: Filter,
    /// Decoded size — the receiver sizes its destination by this.
    raw_len: u32,
    /// Bytes per row, for the filter's inverse (ignored when none).
    row_stride: u32,
    bytes: []const u8,
};

pub fn appendBody(out: *std.ArrayList(u8), a: std.mem.Allocator, enc: Encoded, raw_len: u32, row_stride: u32) !void {
    var hdr: [body_header]u8 = undefined;
    hdr[0] = @intFromEnum(enc.coder);
    hdr[1] = @intFromEnum(enc.filter);
    std.mem.writeInt(u32, hdr[2..6], raw_len, .little);
    std.mem.writeInt(u32, hdr[6..10], row_stride, .little);
    try out.appendSlice(a, &hdr);
    try out.appendSlice(a, enc.bytes);
}

pub fn peelBody(src: []const u8) ?Body {
    if (src.len < body_header) return null;
    return .{
        .coder = @enumFromInt(src[0]),
        .filter = @enumFromInt(src[1]),
        .raw_len = std.mem.readInt(u32, src[2..6], .little),
        .row_stride = std.mem.readInt(u32, src[6..10], .little),
        .bytes = src[body_header..],
    };
}

/// Reverse a body into `dst`, which MUST be exactly `body.raw_len` long.
pub fn decodeBody(body: Body, dst: []u8) Error!void {
    if (dst.len != body.raw_len) return Error.SizeMismatch;
    switch (body.coder) {
        .raw => {
            if (body.bytes.len != dst.len) return Error.SizeMismatch;
            @memcpy(dst, body.bytes);
        },
        .zstd => {
            const n = ZSTD_decompress(dst.ptr, dst.len, body.bytes.ptr, body.bytes.len);
            if (ZSTD_isError(n) != 0 or n != dst.len) return Error.Zstd;
        },
        else => return Error.UnknownCoder,
    }
    try unapplyFilter(body.filter, dst, body.row_stride);
}

// ─── tests ──────────────────────────────────────────────────────

const t = std.testing;

test "every filter round-trips in place (incl. partial last row)" {
    const a = t.allocator;
    inline for (.{ Filter.sub, Filter.up, Filter.paeth }) |filter| {
        var buf = [_]u8{
            10, 20, 30, 40, 15, 25, 35, 45,
            11, 21, 31, 41, 99, 88, 77, 66,
            50, 60, 70, 80, 52, 62, 72, 82,
            1,  2,  3,  4, // partial last row (one pixel)
        };
        const orig = try a.dupe(u8, &buf);
        defer a.free(orig);
        applyFilter(filter, &buf, 8);
        try unapplyFilter(filter, &buf, 8);
        try t.expectEqualSlices(u8, orig, &buf);
    }
}

test "paeth predictor matches the PNG spec on hand cases" {
    try t.expectEqual(@as(u8, 10), paethPredictor(10, 20, 20)); // p=10 → a
    try t.expectEqual(@as(u8, 20), paethPredictor(10, 20, 10)); // p=20 → b
    try t.expectEqual(@as(u8, 0), paethPredictor(0, 0, 0));
}

test "encode→decode round-trips across content shapes" {
    const a = t.allocator;
    var s: Scratch = .{};
    defer s.deinit(a);

    const w = 32;
    const h = 16;
    const stride = w * bpp;

    // horizontal gradient (sub wins), vertical gradient (up wins),
    // flat fill (anything compresses), and pseudo-random (raw fallback).
    inline for (.{ "hgrad", "vgrad", "flat", "rand" }) |kind| {
        var px: [stride * h]u8 = undefined;
        var st: u32 = 0x9E3779B9;
        for (0..h) |y| for (0..w) |x| {
            const i = (y * w + x) * bpp;
            switch (kind[0]) {
                'h' => { // hgrad
                    px[i + 0] = @truncate(x * 7 + y * 101);
                    px[i + 1] = @truncate(x * 3);
                    px[i + 2] = @truncate(x * 5);
                },
                'v' => { // vgrad
                    px[i + 0] = @truncate(y * 7 + x * 101);
                    px[i + 1] = @truncate(y * 3);
                    px[i + 2] = @truncate(y * 5);
                },
                'f' => { // flat
                    px[i + 0] = 0x33;
                    px[i + 1] = 0x66;
                    px[i + 2] = 0x99;
                    px[i + 3] = 0xff;
                },
                else => { // rand — ALL four channels, else a constant
                    // alpha plane would let zstd shrink it.
                    st = st *% 1664525 +% 1013904223;
                    px[i + 0] = @truncate(st >> 24);
                    px[i + 1] = @truncate(st >> 16);
                    px[i + 2] = @truncate(st >> 8);
                    px[i + 3] = @truncate(st);
                },
            }
            if (kind[0] != 'r' and kind[0] != 'f') px[i + 3] = 0xff;
        };

        const enc = try encodeRegion(&s, a, &px, stride);
        if (std.mem.eql(u8, kind, "rand")) {
            try t.expectEqual(Coder.raw, enc.coder);
        } else {
            try t.expectEqual(Coder.zstd, enc.coder);
            try t.expect(enc.bytes.len < px.len);
        }

        // Round-trip through the wire body.
        const wire = try a.dupe(u8, enc.bytes);
        defer a.free(wire);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(a);
        try appendBody(&out, a, .{ .coder = enc.coder, .filter = enc.filter, .bytes = wire }, px.len, stride);
        const body = peelBody(out.items).?;
        var dst: [stride * h]u8 = undefined;
        try decodeBody(body, &dst);
        try t.expectEqualSlices(u8, &px, &dst);
    }
}

test "vertical gradient actually selects the up filter" {
    // A column ramp with per-column offsets: 'up' delta is near-constant,
    // 'sub' is not — pickFilter must choose up.
    const w = 16;
    const h = 16;
    const stride = w * bpp;
    var px: [stride * h]u8 = undefined;
    for (0..h) |y| for (0..w) |x| {
        const i = (y * w + x) * bpp;
        px[i + 0] = @truncate(y * 9 + x * 101);
        px[i + 1] = 0;
        px[i + 2] = 0;
        px[i + 3] = 0xff;
    };
    try t.expectEqual(Filter.up, pickFilter(&px, stride));
}

test "body: size mismatch, truncation, unknown coder/filter are errors" {
    const a = t.allocator;
    var s: Scratch = .{};
    defer s.deinit(a);

    var px: [64]u8 = undefined;
    for (&px, 0..) |*b, i| b.* = @intCast((i / 4) % 7);
    const enc = try encodeRegion(&s, a, &px, 16);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try appendBody(&out, a, enc, px.len, 16);
    const body = peelBody(out.items).?;

    var small: [8]u8 = undefined;
    try t.expectError(Error.SizeMismatch, decodeBody(body, &small));
    try t.expectEqual(@as(?Body, null), peelBody(out.items[0..5]));

    var dst: [64]u8 = undefined;
    try t.expectError(Error.UnknownCoder, decodeBody(.{ .coder = @enumFromInt(200), .filter = .none, .raw_len = 64, .row_stride = 16, .bytes = "" }, &dst));
    try t.expectError(Error.UnknownFilter, decodeBody(.{ .coder = .raw, .filter = @enumFromInt(200), .raw_len = 64, .row_stride = 16, .bytes = &px }, &dst));
}
