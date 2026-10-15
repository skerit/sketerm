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

inline fn paethPredictor(a: u8, b: u8, c: u8) u8 {
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

/// Predicted value for byte `x` of row `cur`, given `up`, the row above
/// (ignored without `has_up`); missing neighbours read as 0, per PNG.
/// Row-wise with the filter comptime because the filters run over every
/// damaged byte on the daemon's poll loop: a per-byte `i % stride` and
/// filter switch cost a third of each encode.
inline fn predictAt(comptime filter: Filter, comptime has_up: bool, cur: []const u8, up: []const u8, x: usize) u8 {
    return switch (filter) {
        .sub => if (x >= bpp) cur[x - bpp] else 0,
        .up => if (has_up) up[x] else 0,
        .paeth => paethPredictor(
            if (x >= bpp) cur[x - bpp] else 0,
            if (has_up) up[x] else 0,
            if (has_up and x >= bpp) up[x - bpp] else 0,
        ),
        else => 0,
    };
}

fn effStride(buf_len: usize, row_stride: usize) usize {
    return if (row_stride == 0) buf_len else row_stride;
}

fn Row(comptime Bytes: type) type {
    return struct { cur: Bytes, up: []const u8 };
}

/// The row starting at `start` (the last may be short) and the row above it.
fn rowAt(buf: anytype, stride: usize, start: usize) Row(@TypeOf(buf)) {
    const cur = buf[start..@min(start + stride, buf.len)];
    return .{ .cur = cur, .up = if (start >= stride) buf[start - stride ..][0..cur.len] else &.{} };
}

/// Forward filter, IN PLACE. Bottom row first, each right-to-left, so
/// every predictor reads ORIGINAL neighbours (not yet rewritten).
fn applyFilter(filter: Filter, buf: []u8, row_stride: usize) void {
    if (buf.len == 0) return;
    switch (filter) {
        inline .sub, .up, .paeth => |f| {
            const stride = effStride(buf.len, row_stride);
            var start = (buf.len - 1) / stride * stride;
            while (true) : (start -= stride) {
                const row = rowAt(buf, stride, start);
                if (start == 0) return filterRow(f, false, row.cur, row.up);
                filterRow(f, true, row.cur, row.up);
            }
        },
        else => {},
    }
}

fn filterRow(comptime filter: Filter, comptime has_up: bool, cur: []u8, up: []const u8) void {
    var x = cur.len;
    while (x > 0) {
        x -= 1;
        cur[x] -%= predictAt(filter, has_up, cur, up, x);
    }
}

/// Inverse filter, IN PLACE. Top row first, each left-to-right, so every
/// predictor reads already-RECONSTRUCTED neighbours.
fn unapplyFilter(filter: Filter, buf: []u8, row_stride: usize) Error!void {
    switch (filter) {
        .none => return,
        inline .sub, .up, .paeth => |f| {
            if (buf.len == 0) return;
            const stride = effStride(buf.len, row_stride);
            var start: usize = 0;
            while (start < buf.len) : (start += stride) {
                const row = rowAt(buf, stride, start);
                if (start == 0) unfilterRow(f, false, row.cur, row.up) else unfilterRow(f, true, row.cur, row.up);
            }
        },
        else => return Error.UnknownFilter,
    }
}

fn unfilterRow(comptime filter: Filter, comptime has_up: bool, cur: []u8, up: []const u8) void {
    for (0..cur.len) |x| cur[x] +%= predictAt(filter, has_up, cur, up, x);
}

/// The filters `pickFilter` scores, in tie-break order (the first wins).
const candidates = [_]Filter{ .none, .sub, .up, .paeth };

/// PNG minimum-sum-of-absolute-differences score of one filtered byte:
/// min(v, 256-v), since small deltas are cheap to entropy-code.
inline fn msad(residual: u8) u64 {
    const r: u16 = residual;
    return @min(r, 256 - r);
}

/// Every candidate's MSAD score in ONE pass over `buf`, read-only.
fn filterCosts(buf: []const u8, stride: usize) [candidates.len]u64 {
    var sums: [candidates.len]u64 = @splat(0);
    var start: usize = 0;
    while (start < buf.len) : (start += stride) {
        const row = rowAt(buf, stride, start);
        if (start == 0) rowCosts(false, row.cur, row.up, &sums) else rowCosts(true, row.cur, row.up, &sums);
    }
    return sums;
}

fn rowCosts(comptime has_up: bool, cur: []const u8, up: []const u8, sums: *[candidates.len]u64) void {
    var s = sums.*;
    for (cur, 0..) |v, x| {
        inline for (candidates, 0..) |f, k| s[k] += msad(v -% predictAt(f, has_up, cur, up, x));
    }
    sums.* = s;
}

/// Pick the filter whose MSAD score is lowest. One scoring pass, no
/// compression — the actual zstd pass runs once, on the winner.
fn pickFilter(buf: []const u8, row_stride: usize) Filter {
    if (buf.len == 0) return .none;
    const costs = filterCosts(buf, effStride(buf.len, row_stride));
    var best: usize = 0;
    for (costs[1..], 1..) |cost, k| {
        if (cost < costs[best]) best = k;
    }
    return candidates[best];
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

/// `encodeRegion` that never fails: any error (scratch allocation
/// included) ships `pixels` verbatim, which every receiver decodes.
pub fn encodeOrRaw(s: *Scratch, a: std.mem.Allocator, pixels: []const u8, row_stride: usize) Encoded {
    return encodeRegion(s, a, pixels, row_stride) catch .{ .coder = .raw, .filter = .none, .bytes = pixels };
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

test "every filter writes the PNG residuals, then round-trips in place (incl. partial last row)" {
    const a = t.allocator;
    // The wire format: residuals as PNG defines them (bpp 4, stride 8,
    // missing neighbours 0), pinned so a faster filter loop cannot drift.
    const Case = struct { filter: Filter, filtered: [28]u8 };
    inline for (.{
        Case{ .filter = .sub, .filtered = .{ 10, 20, 30, 40, 5, 5, 5, 5, 11, 21, 31, 41, 88, 67, 46, 25, 50, 60, 70, 80, 2, 2, 2, 2, 1, 2, 3, 4 } },
        Case{ .filter = .up, .filtered = .{ 10, 20, 30, 40, 15, 25, 35, 45, 1, 1, 1, 1, 84, 63, 42, 21, 39, 39, 39, 39, 209, 230, 251, 16, 207, 198, 189, 180 } },
        Case{ .filter = .paeth, .filtered = .{ 10, 20, 30, 40, 5, 5, 5, 5, 1, 1, 1, 1, 84, 63, 42, 21, 39, 39, 39, 39, 209, 230, 251, 2, 207, 198, 189, 180 } },
    }) |case| {
        var buf = [_]u8{
            10, 20, 30, 40, 15, 25, 35, 45,
            11, 21, 31, 41, 99, 88, 77, 66,
            50, 60, 70, 80, 52, 62, 72, 82,
            1,  2,  3,  4, // partial last row (one pixel)
        };
        const orig = try a.dupe(u8, &buf);
        defer a.free(orig);
        applyFilter(case.filter, &buf, 8);
        try t.expectEqualSlices(u8, &case.filtered, &buf);
        try unapplyFilter(case.filter, &buf, 8);
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
