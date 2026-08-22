//! The allocating half of standard base64.
//!
//! `std.base64` encodes into a buffer the caller has already sized, so
//! "encode this slice into a fresh allocation" was written out three
//! times (kitty graphics, the daemon's inline-image rewrite, the glyph
//! protocol). Decoding is deliberately NOT here: every decode site
//! pairs the size calculation with its own cap and its own protocol
//! error, and folding those together would flatten the differences.

const std = @import("std");

/// Standard-alphabet, padded base64 of `bytes` in a fresh allocation.
pub fn encodeAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    const out = try allocator.alloc(u8, encoder.calcSize(bytes.len));
    _ = encoder.encode(out, bytes);
    return out;
}

test "encodeAlloc matches the standard alphabet and pads" {
    const t = std.testing;
    const empty = try encodeAlloc(t.allocator, "");
    defer t.allocator.free(empty);
    try t.expectEqualStrings("", empty);

    const one = try encodeAlloc(t.allocator, "f");
    defer t.allocator.free(one);
    try t.expectEqualStrings("Zg==", one);

    const many = try encodeAlloc(t.allocator, "hello world");
    defer t.allocator.free(many);
    try t.expectEqualStrings("aGVsbG8gd29ybGQ=", many);

    // Round-trips through the matching decoder.
    const decoder = std.base64.standard.Decoder;
    const len = try decoder.calcSizeForSlice(many);
    const back = try t.allocator.alloc(u8, len);
    defer t.allocator.free(back);
    try decoder.decode(back, many);
    try t.expectEqualStrings("hello world", back);
}
