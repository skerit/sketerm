//! Raw-deflate helpers for pool updates on the native app pipe.
//! Pure std (std.compress.flate) — links nothing, runs in the
//! libc-only daemon and the GUI alike.

const std = @import("std");
const flate = std.compress.flate;

/// Compress src into dst (raw deflate, fastest level — pixel rows
/// are long runs; ratio over speed is the wrong trade on a poll
/// loop). Null when the result wouldn't shrink or doesn't fit dst —
/// callers fall back to the raw bytes.
pub fn compress(src: []const u8, dst: []u8) ?[]const u8 {
    var window: [flate.max_window_len]u8 = undefined;
    var out = std.Io.Writer.fixed(dst);
    var comp = flate.Compress.init(&out, &window, .raw, .fastest) catch return null;
    comp.writer.writeAll(src) catch return null;
    comp.finish() catch return null;
    const result = out.buffered();
    if (result.len == 0 or result.len >= src.len) return null;
    return result;
}

pub const Error = error{Corrupt};

/// Inflate src into dst; the caller knows the exact raw length and
/// sizes dst accordingly. Errors on any mismatch.
pub fn decompress(src: []const u8, dst: []u8) Error![]const u8 {
    var in = std.Io.Reader.fixed(src);
    var window: [flate.max_window_len]u8 = undefined;
    var d = flate.Decompress.init(&in, .raw, &window);
    const n = d.reader.readSliceShort(dst) catch return Error.Corrupt;
    if (n != dst.len) return Error.Corrupt;
    // The stream must END here — more data means the sender's
    // raw_len lied and we'd silently truncate.
    var probe: [1]u8 = undefined;
    const extra = d.reader.readSliceShort(&probe) catch 1;
    if (extra != 0) return Error.Corrupt;
    return dst[0..n];
}

// ─── tests ──────────────────────────────────────────────────────

const t = std.testing;

test "round-trip, incompressible fallback, corrupt input" {
    // Compressible: a pixel-row-like pattern.
    var src: [4096]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast((i / 64) % 7);
    var cbuf: [4096]u8 = undefined;
    const z = compress(&src, &cbuf).?;
    try t.expect(z.len < src.len / 4);

    var back: [4096]u8 = undefined;
    const raw = try decompress(z, &back);
    try t.expectEqualSlices(u8, &src, raw);

    // Random bytes don't shrink → null (caller sends raw).
    var rnd: [512]u8 = undefined;
    var state: u32 = 0x12345678;
    for (&rnd) |*b| {
        state = state *% 1664525 +% 1013904223;
        b.* = @truncate(state >> 24);
    }
    try t.expectEqual(@as(?[]const u8, null), compress(&rnd, &cbuf));

    // Corrupt stream errors instead of crashing.
    var garbage = [_]u8{ 0xde, 0xad, 0xbe, 0xef, 0x01 };
    try t.expectError(Error.Corrupt, decompress(&garbage, &back));

    // Wrong expected length errors.
    var short: [10]u8 = undefined;
    try t.expectError(Error.Corrupt, decompress(z, &short));
}
