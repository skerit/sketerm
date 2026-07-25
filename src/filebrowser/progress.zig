//! Transfer rate, ETA and stall detection from raw progress samples.
//!
//! Progress arrives irregularly (a daemon job emits every 4 MB, the GUI
//! samples on a timer), so the rate is an exponentially weighted average
//! whose weight follows the sample GAP, not the sample count. Numbers
//! that cannot be known are reported as null rather than guessed: an
//! unknown total has no ETA, and a job that stopped moving reports
//! stalled instead of its last rate.

const std = @import("std");
const fmtSize = @import("format.zig").fmtSize;

/// Rate-history depth; one entry per HISTORY_INTERVAL_MS at most.
pub const HISTORY_LEN = 48;
/// Gap at which a new observation weighs half of the average.
pub const SMOOTHING_MS: f64 = 2000;
/// No byte moved for this long = stalled.
pub const STALL_MS: i64 = 5000;
/// Rate-history resolution.
pub const HISTORY_INTERVAL_MS: i64 = 500;
/// ETA ceiling; beyond this the estimate says nothing useful.
pub const ETA_MAX_S: u64 = 100 * 24 * 3600;

pub const Status = struct {
    /// Smoothed bytes per second; null while unknown or stalled.
    rate_bps: ?u64 = null,
    /// Seconds remaining; null unless total, rate and motion are known.
    eta_s: ?u64 = null,
    /// Nothing moved for at least STALL_MS.
    stalled: bool = false,
};

pub const Sampler = struct {
    started: bool = false,
    /// `done` at the first observation: a resumed transfer starts at a
    /// non-zero offset that was never transferred by this run.
    base_done: u64 = 0,
    /// First observation, for the whole-run average.
    base_ms: i64 = 0,
    last_ms: i64 = 0,
    last_done: u64 = 0,
    /// Last observation at which `done` actually increased.
    moved_ms: i64 = 0,
    rate: f64 = 0,
    have_rate: bool = false,
    history: [HISTORY_LEN]u32 = @splat(0),
    history_len: usize = 0,
    history_ms: i64 = 0,

    /// Fold one (time, bytes-done) observation into the average.
    /// Two observations in the same millisecond are ignored rather than
    /// divided by zero; the next one carries the whole delta.
    pub fn observe(self: *Sampler, now_ms: i64, done: u64) void {
        if (!self.started) {
            self.started = true;
            self.base_done = done;
            self.base_ms = now_ms;
            self.last_done = done;
            self.last_ms = now_ms;
            self.moved_ms = now_ms;
            self.history_ms = now_ms;
            return;
        }
        if (done < self.last_done) {
            // Restarted from an earlier offset (a discarded partial):
            // the measured history describes bytes that no longer count.
            self.base_done = done;
            self.last_done = done;
            self.last_ms = now_ms;
            self.moved_ms = now_ms;
            self.rate = 0;
            self.have_rate = false;
            self.history_len = 0;
            self.history_ms = now_ms;
            self.base_ms = now_ms;
            return;
        }
        const dt = now_ms - self.last_ms;
        if (dt <= 0) return;
        const delta = done - self.last_done;
        const dtf: f64 = @floatFromInt(dt);
        const instant = @as(f64, @floatFromInt(delta)) * 1000.0 / dtf;
        const weight = dtf / (dtf + SMOOTHING_MS);
        if (self.have_rate) {
            self.rate += weight * (instant - self.rate);
        } else {
            self.rate = instant;
            self.have_rate = true;
        }
        if (delta > 0) self.moved_ms = now_ms;
        self.last_ms = now_ms;
        self.last_done = done;
        if (now_ms - self.history_ms >= HISTORY_INTERVAL_MS) {
            self.history_ms = now_ms;
            self.push(if (self.rate > 0) @intFromFloat(@min(self.rate, @as(f64, std.math.maxInt(u32)))) else 0);
        }
    }

    /// Time during which the transfer was not allowed to run (paused,
    /// or waiting in the queue). It is neither a stall nor a slow
    /// stretch, so it must not decay the average or start the stall
    /// clock: the measurement simply skips it.
    pub fn idle(self: *Sampler, now_ms: i64) void {
        if (!self.started) return;
        const gap = now_ms - self.last_ms;
        // Shifting the run's origin by the gap keeps the whole-run
        // average about running time, not wall-clock time.
        if (gap > 0) self.base_ms += gap;
        self.last_ms = now_ms;
        self.moved_ms = now_ms;
        self.history_ms = now_ms;
    }

    /// Bytes per second this run achieved over the time it was allowed
    /// to run; null before a measurable second has passed.
    pub fn average(self: *const Sampler, done: u64) ?u64 {
        if (!self.started) return null;
        const span = self.last_ms - self.base_ms;
        if (span < 1000) return null;
        const bytes = self.moved(done);
        if (bytes == 0) return null;
        return bytes * 1000 / @as(u64, @intCast(span));
    }

    fn push(self: *Sampler, value: u32) void {
        if (self.history_len < HISTORY_LEN) {
            self.history[self.history_len] = value;
            self.history_len += 1;
            return;
        }
        std.mem.copyForwards(u32, self.history[0 .. HISTORY_LEN - 1], self.history[1..HISTORY_LEN]);
        self.history[HISTORY_LEN - 1] = value;
    }

    /// Rate samples oldest-first (empty until the first interval).
    pub fn samples(self: *const Sampler) []const u32 {
        return self.history[0..self.history_len];
    }

    pub fn peak(self: *const Sampler) u32 {
        var top: u32 = 0;
        for (self.samples()) |v| top = @max(top, v);
        return top;
    }

    /// Bytes this run actually moved (a resumed run does not claim the
    /// bytes its predecessor left behind).
    pub fn moved(self: *const Sampler, done: u64) u64 {
        if (!self.started or done < self.base_done) return 0;
        return done - self.base_done;
    }

    pub fn status(self: *const Sampler, now_ms: i64, done: u64, total: u64) Status {
        var out: Status = .{};
        if (!self.started) return out;
        out.stalled = self.have_rate and (now_ms - self.moved_ms) >= STALL_MS;
        // A stalled job's last rate describes the past, not the present.
        if (out.stalled or !self.have_rate) return out;
        if (self.rate < 1) return out;
        out.rate_bps = @intFromFloat(@round(self.rate));
        if (total > done) {
            const seconds = @as(f64, @floatFromInt(total - done)) / self.rate;
            if (seconds < @as(f64, @floatFromInt(ETA_MAX_S))) out.eta_s = @intFromFloat(@ceil(seconds));
        }
        return out;
    }
};

/// "12.3 MB/s" into `buf`.
pub fn formatRate(buf: []u8, bps: u64) []const u8 {
    var size: [48:0]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s}/s", .{fmtSize(&size, bps)}) catch "?/s";
}

/// "45s" / "12m 05s" / "3h 07m" into `buf`.
pub fn formatEta(buf: []u8, seconds: u64) []const u8 {
    if (seconds < 60) return std.fmt.bufPrint(buf, "{d}s", .{seconds}) catch "?";
    if (seconds < 3600) return std.fmt.bufPrint(buf, "{d}m {d:0>2}s", .{ seconds / 60, seconds % 60 }) catch "?";
    if (seconds < 24 * 3600) return std.fmt.bufPrint(buf, "{d}h {d:0>2}m", .{ seconds / 3600, (seconds % 3600) / 60 }) catch "?";
    return std.fmt.bufPrint(buf, "{d}d {d:0>2}h", .{ seconds / (24 * 3600), (seconds % (24 * 3600)) / 3600 }) catch "?";
}

test "rate follows the byte delta, not the absolute offset" {
    const t = std.testing;
    var s: Sampler = .{};
    // A resumed transfer starts at a non-zero offset: 5 MB were already
    // on disk, 1 MB/s is being moved now.
    s.observe(0, 5 << 20);
    var at: i64 = 0;
    var done: u64 = 5 << 20;
    while (at < 20_000) {
        at += 1000;
        done += 1 << 20;
        s.observe(at, done);
    }
    const st = s.status(at, done, 0);
    const rate = st.rate_bps orelse return error.NoRate;
    try t.expect(rate > 900 * 1024 and rate < 1200 * 1024);
    try t.expectEqual(@as(u64, 20 << 20), s.moved(done));
    try t.expect(!st.stalled);
    // The whole-run average counts only what this run moved: 20 MB in
    // 20 s, not the 5 MB the resumed partial contributed.
    try t.expectEqual(@as(?u64, 1 << 20), s.average(done));
}

test "two observations in the same millisecond never divide by zero" {
    const t = std.testing;
    var s: Sampler = .{};
    s.observe(1000, 0);
    s.observe(1000, 1 << 20);
    s.observe(1000, 2 << 20);
    // Nothing measurable yet, and no crash or absurd rate.
    try t.expectEqual(@as(?u64, null), s.status(1000, 2 << 20, 0).rate_bps);
    // The next real gap carries the whole delta.
    s.observe(2000, 2 << 20);
    const rate = s.status(2000, 2 << 20, 0).rate_bps orelse return error.NoRate;
    try t.expectEqual(@as(u64, 2 << 20), rate);
}

test "an unknown total yields no ETA" {
    const t = std.testing;
    var s: Sampler = .{};
    s.observe(0, 0);
    s.observe(1000, 1 << 20);
    const st = s.status(1000, 1 << 20, 0);
    try t.expect(st.rate_bps != null);
    try t.expectEqual(@as(?u64, null), st.eta_s);
    // A known total does produce one.
    const known = s.status(1000, 1 << 20, 11 << 20);
    try t.expectEqual(@as(?u64, 10), known.eta_s);
}

test "a stalled transfer withholds its stale rate and ETA" {
    const t = std.testing;
    var s: Sampler = .{};
    s.observe(0, 0);
    s.observe(1000, 4 << 20);
    try t.expect(s.status(1000, 4 << 20, 8 << 20).rate_bps != null);
    var at: i64 = 1000;
    while (at < 1000 + STALL_MS) {
        at += 500;
        s.observe(at, 4 << 20);
    }
    const st = s.status(at, 4 << 20, 8 << 20);
    try t.expect(st.stalled);
    try t.expectEqual(@as(?u64, null), st.rate_bps);
    try t.expectEqual(@as(?u64, null), st.eta_s);
}

test "a pause neither stalls nor decays the average" {
    const t = std.testing;
    var s: Sampler = .{};
    s.observe(0, 0);
    s.observe(1000, 4 << 20);
    const before = s.status(1000, 4 << 20, 0).rate_bps orelse return error.NoRate;
    // Paused for a minute: idle ticks keep the clock honest.
    var at: i64 = 1000;
    while (at < 61_000) {
        at += 500;
        s.idle(at);
    }
    const after = s.status(at, 4 << 20, 0);
    try t.expect(!after.stalled);
    try t.expectEqual(before, after.rate_bps.?);
    // The minute of pause is not counted as slow transfer time.
    try t.expectEqual(@as(?u64, 4 << 20), s.average(4 << 20));
    // Progress resumes at the same speed and the average holds.
    s.observe(at + 1000, 8 << 20);
    const resumed = s.status(at + 1000, 8 << 20, 0).rate_bps orelse return error.NoRate;
    try t.expect(resumed > 3 << 20);
}

test "a restart from a lower offset drops the old average" {
    const t = std.testing;
    var s: Sampler = .{};
    s.observe(0, 0);
    s.observe(1000, 100 << 20);
    try t.expect(s.status(1000, 100 << 20, 0).rate_bps != null);
    s.observe(2000, 0);
    try t.expectEqual(@as(?u64, null), s.status(2000, 0, 0).rate_bps);
    try t.expectEqual(@as(usize, 0), s.samples().len);
    try t.expectEqual(@as(u64, 0), s.moved(0));
}

test "history is bounded and time-spaced" {
    const t = std.testing;
    var s: Sampler = .{};
    s.observe(0, 0);
    var at: i64 = 0;
    var done: u64 = 0;
    // 100 observations 100 ms apart = 10 s, so at most 20 history slots.
    while (at < 10_000) {
        at += 100;
        done += 1 << 20;
        s.observe(at, done);
    }
    try t.expect(s.samples().len <= HISTORY_LEN);
    try t.expect(s.samples().len <= 21);
    try t.expect(s.peak() > 0);
}

test "formatters stay compact" {
    const t = std.testing;
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("1.0 MB/s", formatRate(&buf, 1 << 20));
    try t.expectEqualStrings("512 B/s", formatRate(&buf, 512));
    try t.expectEqualStrings("45s", formatEta(&buf, 45));
    try t.expectEqualStrings("12m 05s", formatEta(&buf, 725));
    try t.expectEqualStrings("3h 07m", formatEta(&buf, 11220));
    try t.expectEqualStrings("2d 03h", formatEta(&buf, 2 * 86400 + 3 * 3600));
}
