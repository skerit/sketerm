//! Redial waits: double from a floor up to a ceiling on each failure,
//! back to nothing on success. The one home for that rule, so a link
//! never grows a private sleep loop or its own doubling formula.

const std = @import("std");

pub const Backoff = struct {
    min_ms: i64,
    max_ms: i64,
    /// The wait the latest failure imposed; 0 = none since the last success.
    delay_ms: i64 = 0,
    /// Monotonic ms before which no retry is due.
    retry_at_ms: i64 = 0,

    /// The wait one more failure would impose.
    pub fn next(self: *const Backoff) i64 {
        if (self.delay_ms <= 0) return self.min_ms;
        return @min(self.delay_ms * 2, self.max_ms);
    }

    /// One more failure at monotonic `now`.
    /// @return the wait it imposes.
    pub fn fail(self: *Backoff, now: i64) i64 {
        self.delay_ms = self.next();
        self.retry_at_ms = now + self.delay_ms;
        return self.delay_ms;
    }

    /// A failure that will not change soon (a peer too old for the
    /// request): wait the ceiling at once.
    pub fn failLong(self: *Backoff, now: i64) i64 {
        self.delay_ms = self.max_ms;
        self.retry_at_ms = now + self.delay_ms;
        return self.delay_ms;
    }

    pub fn reset(self: *Backoff) void {
        self.delay_ms = 0;
        self.retry_at_ms = 0;
    }

    pub fn due(self: *const Backoff, now: i64) bool {
        return now >= self.retry_at_ms;
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
    b.reset();
    try t.expectEqual(@as(i64, 2_000), b.next());
    try t.expectEqual(@as(i64, 60_000), b.failLong(10));
    try t.expectEqual(@as(i64, 60_010), b.retry_at_ms);
}
