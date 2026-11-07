//! Image preview sizing policy shared by the daemon's preview jobs and
//! the viewer. Pure arithmetic: importable from both dependency sets.
//!
//! The numbers come from `zig build bench-preview` (docs/SESSION.md has
//! the table): a display-sized preview of a flat UI screenshot costs
//! about as many bytes as its original PNG, and stb's PNG encoder costs
//! about 10x the CPU of its baseline JPEG at equal geometry.

const std = @import("std");

/// The historical (and freedesktop x-large tier) preview bound; a
/// request without a bound gets exactly this, PNG and cached as before.
pub const DEFAULT_BOUND: u32 = 512;
/// Largest preview a sized request may ask for (16 Mpx RGBA, 64 MiB).
pub const MAX_BOUND: u32 = 4096;
/// Smallest sized preview: below it the legacy tier is as good.
pub const MIN_BOUND: u32 = 256;
/// Display bound used when the viewer has no allocation yet.
pub const UNKNOWN_DISPLAY_BOUND: u32 = 2048;
/// An original at or under this many bytes is fetched as-is instead
/// of being previewed: it is the preview byte cap itself, so no
/// preview could have been larger, and it skips the host decode and
/// re-encode while arriving at full resolution.
pub const ORIGINAL_DIRECT_BYTES: u64 = 2 << 20;
/// Codecs a sized preview asks for: baseline JPEG for opaque images
/// (an order of magnitude cheaper to encode than stb PNG, decodable
/// everywhere), PNG when the image carries alpha.
pub const SIZED_CODECS = "jpeg,png";
/// JPEG quality for previews. At 90 and below stb subsamples chroma
/// (4:2:0); 92 keeps it whole but costs 30-50% more bytes, which on a
/// 10 Mbit/s link is most of a second at display size.
pub const JPEG_QUALITY: u8 = 90;

pub const Size = struct { w: u32, h: u32 };

/// Scale `w`x`h` down so its longest side is at most `bound`; never upscales.
pub fn fitWithin(w: u32, h: u32, bound: u32) Size {
    const max_dim = @max(w, h);
    if (bound == 0 or max_dim <= bound) return .{ .w = w, .h = h };
    // Multiply before dividing: bound/max first truncates 289 * (35 / 289) to 34.
    const b: f64 = @floatFromInt(bound);
    const m: f64 = @floatFromInt(max_dim);
    return .{
        .w = @intFromFloat(@max(1.0, @as(f64, @floatFromInt(w)) * b / m)),
        .h = @intFromFloat(@max(1.0, @as(f64, @floatFromInt(h)) * b / m)),
    };
}

/// The bound a preview job honors for a requested one (0 = legacy request).
pub fn jobBound(requested: u32) u32 {
    if (requested == 0) return DEFAULT_BOUND;
    return std.math.clamp(requested, MIN_BOUND, MAX_BOUND);
}

/// Preview bound for a viewer area of `width`x`height` logical px at
/// integer `scale`; an unallocated area gets UNKNOWN_DISPLAY_BOUND.
pub fn displayBound(width: i64, height: i64, scale: i64) u32 {
    const longest = @max(width, height) * @max(scale, 1);
    if (longest <= 0) return UNKNOWN_DISPLAY_BOUND;
    return @intCast(std.math.clamp(longest, DEFAULT_BOUND, MAX_BOUND));
}

pub const LoadInput = struct {
    source_bytes: u64,
    /// The receiver decodes this file type itself (images, not posters).
    client_decodes_original: bool,
    /// The host's daemon advertises the `preview_bound` capability.
    sized_previews: bool,
    /// Longest side of the area the image is shown in, device px.
    display_bound: u32,
    /// The file lives on another host, so bytes cost link time.
    remote: bool = false,
};

pub const Plan = union(enum) {
    /// Fetch the file itself.
    original,
    /// Ask the host for a preview; bound 0 = the legacy request.
    /// `quick_first`: also ask for a DEFAULT_BOUND one and show it while
    /// the sized one crosses a slow link.
    preview: struct { codecs: []const u8, bound: u32, quick_first: bool = false },
};

/// How a viewer should fetch an image for first display. Posters
/// (video, audio, pdf) keep the legacy request: their generators are
/// external tools with their own sizing, out of this policy's scope.
pub fn planLoad(in: LoadInput) Plan {
    const legacy: Plan = .{ .preview = .{ .codecs = "png", .bound = 0 } };
    if (!in.client_decodes_original) return legacy;
    if (in.source_bytes <= ORIGINAL_DIRECT_BYTES) return .original;
    if (!in.sized_previews) return legacy;
    const bound = std.math.clamp(in.display_bound, DEFAULT_BOUND, MAX_BOUND);
    // Twice the quick bound is four times its pixels: below that the
    // quick image would arrive barely sooner than the real one.
    return .{ .preview = .{ .codecs = SIZED_CODECS, .bound = bound, .quick_first = in.remote and bound >= 2 * DEFAULT_BOUND } };
}

test "fitWithin puts the longest side on the bound and never upscales" {
    const t = std.testing;
    try t.expectEqual(Size{ .w = 425, .h = 512 }, fitWithin(2918, 3508, 512));
    try t.expectEqual(Size{ .w = 512, .h = 256 }, fitWithin(1024, 512, 512));
    try t.expectEqual(Size{ .w = 300, .h = 200 }, fitWithin(300, 200, 512));
    try t.expectEqual(Size{ .w = 1, .h = 512 }, fitWithin(10, 10000, 512));
    try t.expectEqual(Size{ .w = 35, .h = 1 }, fitWithin(289, 10, 35));
    try t.expectEqual(Size{ .w = 300, .h = 200 }, fitWithin(300, 200, 0));
}

test "jobBound keeps legacy requests at 512 and clamps sized ones" {
    const t = std.testing;
    try t.expectEqual(@as(u32, 512), jobBound(0));
    try t.expectEqual(@as(u32, MIN_BOUND), jobBound(10));
    try t.expectEqual(@as(u32, 1800), jobBound(1800));
    try t.expectEqual(@as(u32, MAX_BOUND), jobBound(100_000));
}

test "displayBound scales the longest side and falls back when unallocated" {
    const t = std.testing;
    try t.expectEqual(@as(u32, 1600), displayBound(1600, 900, 1));
    try t.expectEqual(@as(u32, 3200), displayBound(1600, 900, 2));
    try t.expectEqual(@as(u32, MAX_BOUND), displayBound(3840, 2160, 2));
    try t.expectEqual(@as(u32, DEFAULT_BOUND), displayBound(200, 100, 1));
    try t.expectEqual(UNKNOWN_DISPLAY_BOUND, displayBound(0, 0, 2));
}

test "planLoad fetches small decodable originals and sizes the rest" {
    const t = std.testing;
    // The user's report: a 2918x3508 UI PNG of well under 2 MiB.
    try t.expectEqual(Plan.original, planLoad(.{ .source_bytes = 600_000, .client_decodes_original = true, .sized_previews = true, .display_bound = 1600 }));
    try t.expectEqual(Plan.original, planLoad(.{ .source_bytes = ORIGINAL_DIRECT_BYTES, .client_decodes_original = true, .sized_previews = false, .display_bound = 0 }));
    // A poster-only file (video, pdf) is never fetched whole, and keeps the legacy request.
    const poster = planLoad(.{ .source_bytes = 1000, .client_decodes_original = false, .sized_previews = true, .display_bound = 1600 });
    try t.expectEqualStrings("png", poster.preview.codecs);
    try t.expectEqual(@as(u32, 0), poster.preview.bound);
    const sized = planLoad(.{ .source_bytes = 6 << 20, .client_decodes_original = true, .sized_previews = true, .display_bound = 1600 });
    try t.expectEqualStrings(SIZED_CODECS, sized.preview.codecs);
    try t.expectEqual(@as(u32, 1600), sized.preview.bound);
    // Local bytes are free: no quick preview. Remote ones get it once
    // the sized preview is big enough to be worth waiting for.
    try t.expect(!sized.preview.quick_first);
    const remote = planLoad(.{ .source_bytes = 6 << 20, .client_decodes_original = true, .sized_previews = true, .display_bound = 1600, .remote = true });
    try t.expect(remote.preview.quick_first);
    const small_window = planLoad(.{ .source_bytes = 6 << 20, .client_decodes_original = true, .sized_previews = true, .display_bound = 900, .remote = true });
    try t.expect(!small_window.preview.quick_first);
    // A big file against an old daemon: exactly the legacy request.
    const legacy = planLoad(.{ .source_bytes = 12 << 20, .client_decodes_original = true, .sized_previews = false, .display_bound = 1600 });
    try t.expectEqualStrings("png", legacy.preview.codecs);
    try t.expectEqual(@as(u32, 0), legacy.preview.bound);
    const big = planLoad(.{ .source_bytes = 12 << 20, .client_decodes_original = true, .sized_previews = true, .display_bound = 9000, .remote = true });
    try t.expectEqual(MAX_BOUND, big.preview.bound);
    try t.expect(big.preview.quick_first);
}
