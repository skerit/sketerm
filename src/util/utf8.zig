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
