const std = @import("std");

/// Maximum image axis accepted by the terminal image pipeline.
pub const max_dimension: u32 = 16 * 1024;
/// Maximum decoded bytes retained for one image, independent of configuration.
pub const max_decoded_bytes: usize = 256 * 1024 * 1024;

pub const Error = error{
    InvalidDimensions,
    TooLarge,
};

/// Returns the checked byte length for tightly packed image data.
pub fn byteLen(width: u32, height: u32, channels: usize) Error!usize {
    if (width == 0 or height == 0 or channels == 0) return Error.InvalidDimensions;
    const pixels = std.math.mul(usize, @intCast(width), @intCast(height)) catch return Error.TooLarge;
    const bytes = std.math.mul(usize, pixels, channels) catch return Error.TooLarge;
    if (width > max_dimension or height > max_dimension or bytes > max_decoded_bytes) return Error.TooLarge;
    return bytes;
}

/// Returns the effective per-image decoded-byte cap.
pub fn decodedLimit(budget_bytes: usize) usize {
    if (budget_bytes == 0) return max_decoded_bytes;
    return @min(budget_bytes, max_decoded_bytes);
}
