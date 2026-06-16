//! Cheap content classifier for routing: is a BGRA region "flat / texty"
//! (few distinct colours, sharp glyph edges — a lossy DCT codec would
//! ring and smear it, so KEEP IT LOSSLESS) or "photographic /
//! continuous-tone" (many colours — safe to hand to a lossy video
//! codec)? Combined with churn.zig (is the region HOT?) this is what
//! decides the video-vs-lossless route per region.
//!
//! Deliberately biased toward lossless: lossless is always correct, just
//! less compressed, so a false "texty" verdict only costs bandwidth,
//! never legibility. Sampled + quantised so it stays O(region/step) on
//! the daemon poll loop. Pure std, daemon-safe.

const std = @import("std");

pub const Options = struct {
    /// BGRA bytes per row, for completeness (the estimate samples
    /// linearly, so this is unused today but kept for future 2D logic).
    /// Sample one pixel every `sample_step` to bound cost on big regions.
    sample_step: u32 = 4,
    /// Quantise each channel to its top `quant_bits` bits before
    /// counting distinct colours (so anti-aliasing fringe doesn't read
    /// as "many colours"). 4 → a 12-bit / 4096-bucket space.
    quant_bits: u3 = 4,
    /// At/above this many distinct quantised colours, call it
    /// photographic. Text/UI sits well below; photos blow past it.
    color_threshold: u32 = 48,
    /// Regions with fewer than this many sampled pixels are too small to
    /// judge — treated as texty (lossless), the safe default.
    min_samples: u32 = 16,
};

pub const Route = enum { lossless, video };

/// Estimate distinct quantised colours among sampled pixels. `pixels` is
/// BGRA; only whole pixels are considered.
pub fn distinctColors(pixels: []const u8, opts: Options) u32 {
    const npix = pixels.len / 4;
    if (npix == 0) return 0;
    const step = @max(opts.sample_step, 1);
    const shift: u3 = @intCast(8 - @as(u8, opts.quant_bits));

    // 3 channels × quant_bits ≤ 12 bits → ≤ 4096 buckets → 512-byte set.
    var seen = [_]u8{0} ** 512;
    var count: u32 = 0;
    var i: usize = 0;
    while (i < npix) : (i += step) {
        const o = i * 4;
        const b: u32 = pixels[o] >> shift;
        const g: u32 = pixels[o + 1] >> shift;
        const r: u32 = pixels[o + 2] >> shift;
        const key = (b << (@as(u5, opts.quant_bits) * 2)) | (g << @as(u5, opts.quant_bits)) | r;
        const byte = key >> 3;
        const bit: u3 = @intCast(key & 7);
        const mask = @as(u8, 1) << bit;
        if (seen[byte] & mask == 0) {
            seen[byte] |= mask;
            count += 1;
        }
    }
    return count;
}

fn sampleCount(pixels: []const u8, opts: Options) u32 {
    const npix = pixels.len / 4;
    const step = @max(opts.sample_step, 1);
    return @intCast((npix + step - 1) / step);
}

/// True if the region looks photographic (safe for a lossy codec).
pub fn looksPhotographic(pixels: []const u8, opts: Options) bool {
    if (sampleCount(pixels, opts) < opts.min_samples) return false; // too small → lossless
    return distinctColors(pixels, opts) >= opts.color_threshold;
}

/// The routing decision: a region goes to the video codec only if it is
/// BOTH hot (churn) AND photographic. Everything else stays lossless.
pub fn decide(hot: bool, pixels: []const u8, opts: Options) Route {
    if (hot and looksPhotographic(pixels, opts)) return .video;
    return .lossless;
}

// ─── tests ──────────────────────────────────────────────────────

const t = std.testing;

fn fillFlat(px: []u8) void {
    var i: usize = 0;
    while (i + 4 <= px.len) : (i += 4) {
        px[i + 0] = 0x20;
        px[i + 1] = 0x20;
        px[i + 2] = 0x20;
        px[i + 3] = 0xff;
    }
}

test "text-like region (two colours) is not photographic → lossless" {
    var px: [64 * 4]u8 = undefined;
    // Background grey with a few "glyph" pixels in white — 2 colours.
    fillFlat(&px);
    px[10 * 4 + 0] = 0xff;
    px[10 * 4 + 1] = 0xff;
    px[10 * 4 + 2] = 0xff;
    px[11 * 4 + 0] = 0xff;
    px[11 * 4 + 1] = 0xff;
    px[11 * 4 + 2] = 0xff;
    try t.expect(!looksPhotographic(&px, .{}));
    try t.expectEqual(Route.lossless, decide(true, &px, .{})); // even when hot
}

test "photographic region (many colours) is photographic → video when hot" {
    var px: [256 * 4]u8 = undefined;
    var st: u32 = 0x1234567;
    var i: usize = 0;
    while (i < px.len) : (i += 4) {
        st = st *% 1664525 +% 1013904223;
        px[i + 0] = @truncate(st >> 24);
        px[i + 1] = @truncate(st >> 16);
        px[i + 2] = @truncate(st >> 8);
        px[i + 3] = 0xff;
    }
    try t.expect(looksPhotographic(&px, .{}));
    try t.expectEqual(Route.video, decide(true, &px, .{}));
    // Photographic but NOT hot → still lossless (no point coding a still).
    try t.expectEqual(Route.lossless, decide(false, &px, .{}));
}

test "a single flat colour is never photographic" {
    var px: [128 * 4]u8 = undefined;
    fillFlat(&px);
    try t.expectEqual(@as(u32, 1), distinctColors(&px, .{}));
    try t.expect(!looksPhotographic(&px, .{}));
}

test "tiny regions default to lossless (too small to judge)" {
    var px: [4 * 4]u8 = undefined; // 4 px < min_samples even at step 1
    var st: u32 = 99;
    for (&px) |*b| {
        st = st *% 1664525 +% 1013904223;
        b.* = @truncate(st >> 24);
    }
    try t.expect(!looksPhotographic(&px, .{ .sample_step = 1 }));
    try t.expectEqual(Route.lossless, decide(true, &px, .{ .sample_step = 1 }));
}
