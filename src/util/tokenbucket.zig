//! The one token-bucket rate limiter: a burst allowance that refills at a
//! steady rate. Pure arithmetic over a caller-supplied millisecond clock,
//! so every user tests it with fake time and it compiles into any
//! dependency set (the daemon's log ring, the MCP process's agent events).
//!
//! The first `take` anchors the refill clock: a bucket that has never been
//! asked starts full whenever it is first used, not at construction.

const std = @import("std");

pub const TokenBucket = struct {
    burst: f64,
    per_sec: f64,
    tokens: f64,
    /// Refill anchor; null until the first `take`/`available`.
    last_ms: ?i64 = null,

    /// A full bucket of `burst` tokens refilling at `per_sec`.
    pub fn init(burst: f64, per_sec: f64) TokenBucket {
        return .{ .burst = burst, .per_sec = per_sec, .tokens = burst };
    }

    fn refill(self: *TokenBucket, now_ms: i64) void {
        const last = self.last_ms orelse {
            self.last_ms = now_ms;
            return;
        };
        const elapsed = now_ms - last;
        if (elapsed <= 0) return;
        self.tokens = @min(self.burst, self.tokens + @as(f64, @floatFromInt(elapsed)) * self.per_sec / 1000.0);
        self.last_ms = now_ms;
    }

    /// Consume one token at `now_ms`.
    /// @return false when the bucket is empty (nothing is consumed).
    pub fn take(self: *TokenBucket, now_ms: i64) bool {
        self.refill(now_ms);
        if (self.tokens < 1.0) return false;
        self.tokens -= 1.0;
        return true;
    }

    /// Whether a `take` at `now_ms` would succeed, without consuming.
    pub fn available(self: *TokenBucket, now_ms: i64) bool {
        self.refill(now_ms);
        return self.tokens >= 1.0;
    }

    /// Milliseconds from `now_ms` until one token is available (0 when one is).
    pub fn msUntilToken(self: *TokenBucket, now_ms: i64) i64 {
        self.refill(now_ms);
        if (self.tokens >= 1.0) return 0;
        if (self.per_sec <= 0) return std.math.maxInt(i64);
        return @intFromFloat(@ceil((1.0 - self.tokens) * 1000.0 / self.per_sec));
    }
};

test "burst admits, then refills at the configured rate" {
    const t = std.testing;
    var b = TokenBucket.init(3, 1.0 / 30.0);
    try t.expect(b.take(1000));
    try t.expect(b.take(1000));
    try t.expect(b.take(1000));
    try t.expect(!b.take(1000));
    try t.expect(!b.available(20_000));
    const wait = b.msUntilToken(20_000);
    try t.expect(wait >= 10_999 and wait <= 11_001);
    try t.expect(b.take(31_000));
    try t.expect(!b.take(31_000));
}

test "refill never exceeds the burst and a backwards clock is ignored" {
    const t = std.testing;
    var b = TokenBucket.init(2, 2);
    try t.expect(b.take(0));
    try t.expect(b.take(0));
    try t.expect(b.take(10_000));
    try t.expect(b.take(10_000));
    try t.expect(!b.take(10_000));
    try t.expect(!b.take(5_000));
    try t.expectEqual(@as(i64, 500), b.msUntilToken(10_000));
}
