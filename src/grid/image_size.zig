const std = @import("std");

/// Axis size a GL texture upload is assumed to accept before a context
/// exists to ask. It is NOT a rejection threshold: `image_store` queries
/// the real `GL_MAX_TEXTURE_SIZE` and downscales the texture past it, so
/// a wide strip (spectrogram, git graph, panorama) still renders.
pub const max_dimension: u32 = 16 * 1024;
/// Maximum decoded bytes retained for one image. A hard safety ceiling,
/// deliberately independent of `image_memory_mb` — that knob drives
/// FIFO eviction, never rejection.
pub const max_decoded_bytes: usize = 256 * 1024 * 1024;

pub const Error = error{
    InvalidDimensions,
    TooLarge,
};

/// Returns the checked byte length for tightly packed image data.
/// Bounded by total bytes only: a single axis may exceed `max_dimension`
/// as long as the whole image fits under the hard ceiling.
pub fn byteLen(width: u32, height: u32, channels: usize) Error!usize {
    if (width == 0 or height == 0 or channels == 0) return Error.InvalidDimensions;
    const pixels = std.math.mul(usize, @intCast(width), @intCast(height)) catch return Error.TooLarge;
    const bytes = std.math.mul(usize, pixels, channels) catch return Error.TooLarge;
    if (bytes > max_decoded_bytes) return Error.TooLarge;
    return bytes;
}

test "byteLen bounds by total bytes, not by a single axis" {
    // A 20000x10 RGBA strip is 800KB — well under any budget — and must
    // survive decoding even though one axis exceeds max_dimension.
    try std.testing.expectEqual(@as(usize, 20000 * 10 * 4), try byteLen(20000, 10, 4));
    try std.testing.expectEqual(@as(usize, max_dimension) * 4, try byteLen(max_dimension, 1, 4));
    try std.testing.expectError(Error.InvalidDimensions, byteLen(0, 4, 4));
    try std.testing.expectError(Error.TooLarge, byteLen(std.math.maxInt(u32), std.math.maxInt(u32), 4));
    // The hard ceiling still holds: 8192*8192*4 is exactly at it.
    try std.testing.expectEqual(max_decoded_bytes, try byteLen(8192, 8192, 4));
    try std.testing.expectError(Error.TooLarge, byteLen(8192, 8193, 4));
}
