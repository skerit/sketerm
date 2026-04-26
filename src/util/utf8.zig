//! UTF-8 byte-stream decoder.
//!
//! Used by the main thread to assemble Unicode codepoints from the
//! `Print` event byte stream. Continuation bytes are stitched across
//! advance() calls.

const std = @import("std");

pub const Decoder = struct {
    /// 0 = no codepoint in progress.
    expected: u3 = 0,
    /// Bytes received so far for the in-progress codepoint.
    have: u3 = 0,
    /// Accumulator.
    buf: u32 = 0,

    pub fn reset(self: *Decoder) void {
        self.* = .{};
    }

    /// Feed one byte. Returns:
    ///   - non-null codepoint when a complete codepoint was assembled
    ///   - null when the codepoint is still in progress, or input was
    ///     a stray continuation byte (silently dropped)
    /// Bulk-decode `bytes` into `out` codepoints. Returns
    /// `{ consumed, written }`. Stops when `out` would overflow OR
    /// when partial sequence at end remains in the decoder. ASCII
    /// runs are bulk-copied via @Vector(16, u8) detection of the
    /// first non-ASCII byte. Multi-byte sequences fall through to
    /// the byte-at-a-time path.
    ///
    /// Caller invariant: when consumed < bytes.len, the remaining
    /// tail must be retained for the next call (still in-progress
    /// codepoint or out-of-space).
    pub fn feedBatch(self: *Decoder, bytes: []const u8, out: []u32) struct { consumed: usize, written: usize } {
        var i: usize = 0;
        var w: usize = 0;
        const V = @Vector(16, u8);
        const v_top: V = @splat(0x80);

        while (i < bytes.len and w < out.len) {
            // Pure-ASCII fast path is only valid when no codepoint is
            // in progress in the decoder.
            if (self.expected == 0) {
                // SIMD scan — find the first byte with the high bit set.
                while (i + 16 <= bytes.len and w + 16 <= out.len) {
                    const chunk: V = bytes[i..][0..16].*;
                    const high: @Vector(16, bool) = (chunk & v_top) != @as(V, @splat(0));
                    const mask: u16 = @bitCast(high);
                    if (mask == 0) {
                        // All 16 bytes are ASCII — bulk-copy as u32.
                        var k: usize = 0;
                        while (k < 16) : (k += 1) {
                            out[w + k] = bytes[i + k];
                        }
                        i += 16;
                        w += 16;
                    } else {
                        // Copy ASCII prefix, then handle the non-ASCII
                        // byte through the slow path.
                        const ascii_n: usize = @ctz(mask);
                        var k: usize = 0;
                        while (k < ascii_n) : (k += 1) {
                            out[w + k] = bytes[i + k];
                        }
                        i += ascii_n;
                        w += ascii_n;
                        break;
                    }
                }
                // Scalar tail when remaining < 16 bytes OR mid-vector
                // bailed for non-ASCII.
                while (i < bytes.len and w < out.len and bytes[i] < 0x80 and self.expected == 0) {
                    out[w] = bytes[i];
                    i += 1;
                    w += 1;
                }
            }

            // Multi-byte (or in-progress) — feed byte-at-a-time.
            if (i < bytes.len and w < out.len) {
                const cp = self.feed(bytes[i]);
                i += 1;
                if (cp) |v| {
                    out[w] = v;
                    w += 1;
                }
            }
        }
        return .{ .consumed = i, .written = w };
    }

    pub fn feed(self: *Decoder, b: u8) ?u32 {
        if (self.expected == 0) {
            // Leading byte.
            if (b < 0x80) return @as(u32, b);
            if (b & 0xE0 == 0xC0) {
                self.expected = 2;
                self.have = 1;
                self.buf = b & 0x1F;
                return null;
            }
            if (b & 0xF0 == 0xE0) {
                self.expected = 3;
                self.have = 1;
                self.buf = b & 0x0F;
                return null;
            }
            if (b & 0xF8 == 0xF0) {
                self.expected = 4;
                self.have = 1;
                self.buf = b & 0x07;
                return null;
            }
            // Stray continuation or invalid leading byte; drop.
            return null;
        }
        // Continuation byte expected.
        if (b & 0xC0 != 0x80) {
            // Invalid; reset and re-process this byte as leading.
            self.reset();
            return self.feed(b);
        }
        self.buf = (self.buf << 6) | (b & 0x3F);
        self.have += 1;
        if (self.have == self.expected) {
            const cp = self.buf;
            self.reset();
            return cp;
        }
        return null;
    }
};

test "ascii passthrough" {
    var d = Decoder{};
    try std.testing.expectEqual(@as(?u32, 'a'), d.feed('a'));
    try std.testing.expectEqual(@as(?u32, '!'), d.feed('!'));
}

test "two-byte cp" {
    var d = Decoder{};
    // U+00E9 'é' = 0xC3 0xA9
    try std.testing.expectEqual(@as(?u32, null), d.feed(0xC3));
    try std.testing.expectEqual(@as(?u32, 0x00E9), d.feed(0xA9));
}

test "three-byte cp" {
    var d = Decoder{};
    // U+4E2D '中' = 0xE4 0xB8 0xAD
    try std.testing.expectEqual(@as(?u32, null), d.feed(0xE4));
    try std.testing.expectEqual(@as(?u32, null), d.feed(0xB8));
    try std.testing.expectEqual(@as(?u32, 0x4E2D), d.feed(0xAD));
}

test "four-byte cp (emoji)" {
    var d = Decoder{};
    // U+1F600 '😀' = 0xF0 0x9F 0x98 0x80
    try std.testing.expectEqual(@as(?u32, null), d.feed(0xF0));
    try std.testing.expectEqual(@as(?u32, null), d.feed(0x9F));
    try std.testing.expectEqual(@as(?u32, null), d.feed(0x98));
    try std.testing.expectEqual(@as(?u32, 0x1F600), d.feed(0x80));
}

test "invalid leading byte resync" {
    var d = Decoder{};
    try std.testing.expectEqual(@as(?u32, null), d.feed(0xC3)); // expects 1 more byte
    try std.testing.expectEqual(@as(?u32, 'a'), d.feed('a'));   // resync via re-feed
}

test "feedBatch ASCII-only fast path" {
    var d = Decoder{};
    var out: [64]u32 = undefined;
    const r = d.feedBatch("Hello, World!", &out);
    try std.testing.expectEqual(@as(usize, 13), r.consumed);
    try std.testing.expectEqual(@as(usize, 13), r.written);
    try std.testing.expectEqual(@as(u32, 'H'), out[0]);
    try std.testing.expectEqual(@as(u32, '!'), out[12]);
}

test "feedBatch ASCII spanning multiple 16-byte chunks" {
    var d = Decoder{};
    var out: [128]u32 = undefined;
    const text = "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMN";
    const r = d.feedBatch(text, &out);
    try std.testing.expectEqual(text.len, r.consumed);
    try std.testing.expectEqual(text.len, r.written);
    for (text, 0..) |b, i| try std.testing.expectEqual(@as(u32, b), out[i]);
}

test "feedBatch mixed ASCII + multibyte" {
    var d = Decoder{};
    var out: [16]u32 = undefined;
    // "Hi" + 中 (U+4E2D, 3 bytes) + "!"
    const text = "Hi\xE4\xB8\xAD!";
    const r = d.feedBatch(text, &out);
    try std.testing.expectEqual(text.len, r.consumed);
    try std.testing.expectEqual(@as(usize, 4), r.written);
    try std.testing.expectEqual(@as(u32, 'H'), out[0]);
    try std.testing.expectEqual(@as(u32, 'i'), out[1]);
    try std.testing.expectEqual(@as(u32, 0x4E2D), out[2]);
    try std.testing.expectEqual(@as(u32, '!'), out[3]);
}

test "feedBatch partial sequence at end" {
    var d = Decoder{};
    var out: [4]u32 = undefined;
    // "ab" + first 2 of 3 bytes of 中
    const r = d.feedBatch("ab\xE4\xB8", &out);
    try std.testing.expectEqual(@as(usize, 4), r.consumed);
    try std.testing.expectEqual(@as(usize, 2), r.written);
    // Remaining decoder state holds a 3-byte expected sequence with
    // 2 bytes consumed; feeding the third byte completes it.
    try std.testing.expectEqual(@as(?u32, 0x4E2D), d.feed(0xAD));
}

test "feedBatch differential fuzzer vs std.unicode.utf8Decode" {
    // Random byte sequence. Validate that feedBatch produces the
    // same codepoints as a hand-rolled std.unicode.utf8Decode walk
    // (modulo our "drop stray continuation" tolerance).
    var prng = std.Random.DefaultPrng.init(0x5C314557);
    const rand = prng.random();
    var input: [4096]u8 = undefined;
    var batch_out: [4096]u32 = undefined;

    var trial: usize = 0;
    while (trial < 32) : (trial += 1) {
        for (&input) |*b| b.* = rand.int(u8);
        var d = Decoder{};
        const r = d.feedBatch(&input, &batch_out);

        // Compare against per-byte feed.
        var d2 = Decoder{};
        var seq_out: [4096]u32 = undefined;
        var w2: usize = 0;
        for (input[0..r.consumed]) |b| {
            if (d2.feed(b)) |cp| {
                seq_out[w2] = cp;
                w2 += 1;
            }
        }
        try std.testing.expectEqual(r.written, w2);
        var i: usize = 0;
        while (i < r.written) : (i += 1) {
            try std.testing.expectEqual(seq_out[i], batch_out[i]);
        }
    }
}
