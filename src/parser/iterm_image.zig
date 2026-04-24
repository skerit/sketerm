//! iTerm2 OSC 1337 inline image parser.
//!
//! Format: `OSC 1337 ; File = key=value;... : <base64 payload> ST`
//!
//! v1 supports PNG only via the platform's image decoder (none yet
//! integrated; for now we surface dimensions+payload to the consumer
//! as raw PNG bytes). Real RGBA decode lands in a follow-up.

const std = @import("std");

pub const Decoded = struct {
    /// Decoded RGBA pixel buffer, or empty if format not supported.
    rgba: []u8,
    width: u32,
    height: u32,
    /// Original payload format hint.
    format: Format,
};

pub const Format = enum { png, unsupported };

pub fn decodePayload(allocator: std.mem.Allocator, payload: []const u8) !Decoded {
    // Find the colon separating attrs from base64.
    const colon = std.mem.indexOfScalar(u8, payload, ':') orelse return error.InvalidFormat;
    const attrs_str = payload[0..colon];
    const b64 = payload[colon + 1 ..];

    // Parse attrs (key=val;...). We only consume what we need for v1.
    var width_attr: u32 = 0;
    var height_attr: u32 = 0;
    if (std.mem.startsWith(u8, attrs_str, "File=")) {
        var it = std.mem.tokenizeScalar(u8, attrs_str[5..], ';');
        while (it.next()) |kv| {
            if (std.mem.indexOfScalar(u8, kv, '=')) |eq| {
                const key = kv[0..eq];
                const val = kv[eq + 1 ..];
                if (std.mem.eql(u8, key, "width")) width_attr = parsePxAttr(val);
                if (std.mem.eql(u8, key, "height")) height_attr = parsePxAttr(val);
            }
        }
    }

    // Decode base64. Strip whitespace/newlines.
    var stripped: std.ArrayList(u8) = .{};
    defer stripped.deinit(allocator);
    for (b64) |b| {
        if (b == ' ' or b == '\n' or b == '\r' or b == '\t') continue;
        try stripped.append(allocator, b);
    }
    const decoder = std.base64.standard.Decoder;
    const out_len = decoder.calcSizeForSlice(stripped.items) catch return error.InvalidBase64;
    const decoded = try allocator.alloc(u8, out_len);
    errdefer allocator.free(decoded);
    decoder.decode(decoded, stripped.items) catch return error.InvalidBase64;

    // PNG detection — first 8 bytes are 89 50 4E 47 0D 0A 1A 0A.
    const png_magic = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };
    if (decoded.len < 8 or !std.mem.eql(u8, decoded[0..8], &png_magic)) {
        // Not PNG — return as unsupported but still pass through dimensions.
        return .{
            .rgba = &.{},
            .width = width_attr,
            .height = height_attr,
            .format = .unsupported,
        };
    }

    // Extract dimensions from the IHDR chunk (first chunk after sig).
    // IHDR: 4-byte length, 4-byte type "IHDR", 13 bytes data, 4-byte CRC.
    // Width is bytes 16..20, height bytes 20..24.
    if (decoded.len < 24) {
        allocator.free(decoded);
        return error.InvalidPng;
    }
    const w = std.mem.readInt(u32, decoded[16..20], .big);
    const h = std.mem.readInt(u32, decoded[20..24], .big);

    // For v1 we don't actually decode the PNG to RGBA — that requires
    // libpng or stb_image. Just return the dimensions so the consumer
    // can place a stub. Actual decode is a follow-up integration.
    allocator.free(decoded);
    return .{
        .rgba = &.{},
        .width = w,
        .height = h,
        .format = .png,
    };
}

fn parsePxAttr(s: []const u8) u32 {
    // iTerm2 attrs may end with "px", "%", or be cells. v1: parse digits.
    var n: u32 = 0;
    for (s) |b| {
        if (b >= '0' and b <= '9') n = n * 10 + (b - '0') else break;
    }
    return n;
}

test "extract png dimensions" {
    // Tiny 1x1 PNG (precomputed).
    const png_bytes = [_]u8{
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // signature
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR length + type
        0x00, 0x00, 0x00, 0x05, // width = 5
        0x00, 0x00, 0x00, 0x07, // height = 7
        0x08, 0x06, 0x00, 0x00, 0x00, // bit depth, color, compression, filter, interlace
    };
    var b64_buf: [128]u8 = undefined;
    const enc = std.base64.standard.Encoder;
    const b64 = enc.encode(&b64_buf, &png_bytes);

    var payload: std.ArrayList(u8) = .{};
    defer payload.deinit(std.testing.allocator);
    try payload.appendSlice(std.testing.allocator, "File=name=t.png:");
    try payload.appendSlice(std.testing.allocator, b64);

    const out = try decodePayload(std.testing.allocator, payload.items);
    try std.testing.expectEqual(Format.png, out.format);
    try std.testing.expectEqual(@as(u32, 5), out.width);
    try std.testing.expectEqual(@as(u32, 7), out.height);
}
