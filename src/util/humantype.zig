//! Human-typing emulation: UTF-8 keystroke chunking + randomized
//! inter-key delays. Pure logic, no IO — `sketerm cli type-text`
//! and `sketerm mux send --type` drive their sockets with it.

const std = @import("std");

/// Splits text into single-keystroke chunks: one UTF-8 codepoint
/// each; invalid bytes pass through one at a time.
pub const Chunks = struct {
    text: []const u8,
    pos: usize = 0,

    pub fn next(self: *Chunks) ?[]const u8 {
        if (self.pos >= self.text.len) return null;
        const len = std.unicode.utf8ByteSequenceLength(self.text[self.pos]) catch 1;
        const end = @min(self.pos + len, self.text.len);
        const s = self.text[self.pos..end];
        self.pos = end;
        return s;
    }
};

/// Randomized keystroke pacing. LCG-seeded so tests are
/// deterministic; callers seed from the clock.
pub const Pacer = struct {
    base_ms: u32,
    jitter_ms: u32,
    state: u64,

    pub fn init(base_ms: u32, jitter_ms: u32, seed: u64) Pacer {
        return .{ .base_ms = base_ms, .jitter_ms = jitter_ms, .state = seed ^ 0x9E3779B97F4A7C15 };
    }

    fn rand(self: *Pacer) u32 {
        self.state = self.state *% 6364136223846793005 +% 1442695040888963407;
        return @truncate(self.state >> 33);
    }

    /// Delay to sleep BEFORE sending `chunk`. Enter gets an extra
    /// pause — humans hesitate before committing a line.
    pub fn delayMs(self: *Pacer, chunk: []const u8) u32 {
        var d = self.base_ms;
        if (self.jitter_ms > 0) d += self.rand() % (self.jitter_ms + 1);
        if (chunk.len == 1 and (chunk[0] == '\n' or chunk[0] == '\r')) d += self.base_ms * 2;
        return d;
    }
};

test "chunks: ascii, multibyte, invalid bytes" {
    var it = Chunks{ .text = "a\xc3\xa9\xf0\x9f\x98\x80\xff!" };
    try std.testing.expectEqualStrings("a", it.next().?);
    try std.testing.expectEqualStrings("\xc3\xa9", it.next().?); // é
    try std.testing.expectEqualStrings("\xf0\x9f\x98\x80", it.next().?); // 😀
    try std.testing.expectEqualStrings("\xff", it.next().?); // invalid → single byte
    try std.testing.expectEqualStrings("!", it.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), it.next());
}

test "chunks: truncated multibyte tail doesn't read past the end" {
    var it = Chunks{ .text = "x\xf0\x9f" }; // 4-byte lead, only 2 left
    try std.testing.expectEqualStrings("x", it.next().?);
    try std.testing.expectEqualStrings("\xf0\x9f", it.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), it.next());
}

test "pacer: bounds, variation, enter pause, determinism" {
    var p = Pacer.init(60, 90, 12345);
    var seen_different = false;
    var prev: u32 = 0;
    for (0..32) |i| {
        const d = p.delayMs("a");
        try std.testing.expect(d >= 60 and d <= 150);
        if (i > 0 and d != prev) seen_different = true;
        prev = d;
    }
    try std.testing.expect(seen_different);

    const enter = p.delayMs("\r");
    try std.testing.expect(enter >= 60 + 120 and enter <= 150 + 120);

    // Same seed → same sequence.
    var p1 = Pacer.init(60, 90, 7);
    var p2 = Pacer.init(60, 90, 7);
    for (0..8) |_| try std.testing.expectEqual(p1.delayMs("a"), p2.delayMs("a"));

    // jitter 0 → constant.
    var p3 = Pacer.init(50, 0, 99);
    try std.testing.expectEqual(@as(u32, 50), p3.delayMs("a"));
    try std.testing.expectEqual(@as(u32, 150), p3.delayMs("\n"));
}
