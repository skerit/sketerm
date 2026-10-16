//! Retry waits: double from a floor up to a ceiling on each failure,
//! back to nothing on success. The one home for that rule, so a link
//! never grows a private sleep loop or its own doubling formula.

const std = @import("std");

pub const Backoff = struct {
    min_ms: i64,
    max_ms: i64,
    /// Failures after which `exhausted` holds; 0 = never.
    limit: u32 = 0,
    /// Consecutive failures since the last success.
    attempts: u32 = 0,
    /// The wait the latest failure imposed; 0 = none since the last success.
    delay_ms: i64 = 0,
    /// Monotonic ms before which no retry is due.
    retry_at_ms: i64 = 0,

    /// The wait the `n`th consecutive failure imposes (1-based), for a
    /// caller that keeps its own attempt count.
    pub fn waitAt(self: *const Backoff, n: u32) i64 {
        var w = self.min_ms;
        var i: u32 = 1;
        while (i < n and w < self.max_ms) : (i += 1) w *= 2;
        return @min(w, self.max_ms);
    }

    /// The wait one more failure would impose.
    pub fn next(self: *const Backoff) i64 {
        if (self.delay_ms >= self.max_ms) return self.max_ms;
        return self.waitAt(self.attempts + 1);
    }

    /// One more failure at monotonic `now`.
    /// @return the wait it imposes.
    pub fn fail(self: *Backoff, now: i64) i64 {
        self.delay_ms = self.next();
        self.attempts +|= 1;
        self.retry_at_ms = now + self.delay_ms;
        return self.delay_ms;
    }

    /// A failure that will not change soon (a peer too old for the
    /// request): wait the ceiling at once.
    pub fn failLong(self: *Backoff, now: i64) i64 {
        self.delay_ms = self.max_ms;
        self.attempts +|= 1;
        self.retry_at_ms = now + self.delay_ms;
        return self.delay_ms;
    }

    /// A failure that must not be retried before `floor_ms` (another
    /// party holds what was asked for): the usual wait, but at least that.
    pub fn failAtLeast(self: *Backoff, now: i64, floor_ms: i64) i64 {
        self.delay_ms = @max(self.next(), floor_ms);
        self.attempts +|= 1;
        self.retry_at_ms = now + self.delay_ms;
        return self.delay_ms;
    }

    pub fn reset(self: *Backoff) void {
        self.attempts = 0;
        self.delay_ms = 0;
        self.retry_at_ms = 0;
    }

    pub fn due(self: *const Backoff, now: i64) bool {
        return now >= self.retry_at_ms;
    }

    /// Whether the failures reached `limit`.
    pub fn exhausted(self: *const Backoff) bool {
        return self.limit != 0 and self.attempts >= self.limit;
    }
};

test "the wait doubles from the floor to the ceiling and resets on success" {
    const t = std.testing;
    var b = Backoff{ .min_ms = 2_000, .max_ms = 60_000 };
    try t.expect(b.due(0));
    try t.expectEqual(@as(i64, 2_000), b.fail(100));
    try t.expect(!b.due(2_099));
    try t.expect(b.due(2_100));
    try t.expectEqual(@as(i64, 4_000), b.fail(0));
    for (0..30) |_| _ = b.fail(0);
    try t.expectEqual(@as(i64, 60_000), b.delay_ms);
    try t.expectEqual(@as(u32, 32), b.attempts);
    try t.expect(!b.exhausted());
    b.reset();
    try t.expectEqual(@as(i64, 2_000), b.next());
    try t.expectEqual(@as(i64, 60_000), b.failLong(10));
    try t.expectEqual(@as(i64, 60_010), b.retry_at_ms);
    try t.expectEqual(@as(i64, 60_000), b.next());
    // A floor below the usual wait changes nothing; above it, it wins.
    b.reset();
    try t.expectEqual(@as(i64, 20_000), b.failAtLeast(0, 20_000));
    try t.expectEqual(@as(i64, 20_000), b.retry_at_ms);
    for (0..5) |_| _ = b.fail(0);
    try t.expectEqual(@as(i64, 60_000), b.failAtLeast(0, 20_000));
}

test "a limited backoff is exhausted after its failures; waitAt matches fail" {
    const t = std.testing;
    var b = Backoff{ .min_ms = 1_000, .max_ms = 30_000, .limit = 6 };
    const want = [_]i64{ 1_000, 2_000, 4_000, 8_000, 16_000, 30_000 };
    for (want, 1..) |w, n| {
        try t.expect(!b.exhausted());
        try t.expectEqual(w, b.waitAt(@intCast(n)));
        try t.expectEqual(w, b.fail(0));
    }
    try t.expect(b.exhausted());
    try t.expectEqual(@as(i64, 30_000), b.waitAt(1000));
    // A floor above the ceiling waits the ceiling.
    try t.expectEqual(@as(i64, 600), (Backoff{ .min_ms = 5_000, .max_ms = 600 }).waitAt(1));
}
