//! Opt-in retry of a turn a provider overload ended (`agent_open
//! retry_on_overload`): the backoff, the budget per job, and which events
//! of an agent's queue a pending retry holds back.
//!
//! The policy only reads and marks the queue; the MCP layer types the
//! adapter's continue prompt when `Tracker.due_ms` comes. An `error` whose
//! class `vocab.ErrorClass.retriedOnOverload` is held (`events.Event.held`:
//! it wakes nobody) while a retry is pending, and so is the `done` of the
//! turn it ended. A continued turn that ends in a `done` recovers: the held
//! errors stay held (notices in the transcript; a `retrying` opt-in still
//! gets them) and that done covers every job the retries spanned. Running
//! out of retries, another error class or the app's exit gives up: the held
//! errors wake with the error that ended it.

const std = @import("std");
const vocab = @import("vocab.zig");
const events = @import("events.zig");

/// Most retries one job may take.
pub const MAX_RETRIES: u32 = 10;
/// The longest first backoff, and where doubling stops.
pub const BACKOFF_CAP_S: u32 = 600;
pub const DEFAULT_MAX: u32 = 3;
pub const DEFAULT_BACKOFF_S: u32 = 15;

pub const Policy = struct {
    /// Retries per job (a caller's prompt starts a new budget).
    max: u32 = DEFAULT_MAX,
    /// The first wait; each later one doubles, up to `BACKOFF_CAP_S`.
    backoff_s: u32 = DEFAULT_BACKOFF_S,
};

/// The wait before retry `attempt` (1-based).
pub fn delayMs(p: Policy, attempt: u32) i64 {
    var s: u64 = @min(p.backoff_s, BACKOFF_CAP_S);
    var i: u32 = 1;
    while (i < attempt and s < BACKOFF_CAP_S) : (i += 1) s *= 2;
    const capped: u64 = @min(s, BACKOFF_CAP_S);
    return @intCast(capped * 1000);
}

/// Why a retry episode ended without recovering.
pub const GiveUp = enum {
    /// The job's retries are spent.
    exhausted,
    /// The turn ended on an error that is not an overload (a limit).
    other_error,
    /// The app is gone.
    exited,
    /// The policy was turned off.
    off,
};

pub const Step = union(enum) {
    /// Nothing new.
    none,
    /// An overload was held: retry `attempt` of `max` after `delay_ms`.
    scheduled: struct { attempt: u32, max: u32, delay_ms: i64, text: []const u8 },
    /// What was held wakes now (the error that ended it with it).
    gave_up: struct { why: GiveUp, attempts: u32, text: []const u8 },
    /// The continued turn ended (or asks something): the held errors stay quiet.
    recovered: struct { attempts: u32 },
};

pub const Tracker = struct {
    policy: ?Policy = null,
    /// The highest queue seq examined.
    seen: u64 = 0,
    /// Retries spent since the caller's last prompt.
    used: u32 = 0,
    /// A retry episode runs: an overload is held and not yet answered.
    active: bool = false,
    /// The first seq the episode held (release scope).
    from_seq: u64 = 0,
    /// When the continue prompt is due; null when none is scheduled.
    due_ms: ?i64 = null,
    /// The queue's next seq when the continue prompt went in.
    sent_seq: ?u64 = null,
    /// The oldest job a held done covered.
    first_job: ?u32 = null,
    /// The next done covers this job too (after a recovery or a give-up).
    carry_first_job: ?u32 = null,

    /// Skip everything already in `q` (a tracker armed on a running agent).
    pub fn catchUp(self: *Tracker, q: *const events.Queue) void {
        self.seen = q.next_seq - 1;
    }

    /// The caller sent a prompt (or interrupted): a new job, a new budget.
    /// What a pending retry held stays held, as notices.
    pub fn newPrompt(self: *Tracker) void {
        self.used = 0;
        self.endEpisode();
        self.carry_first_job = null;
    }

    /// The continue prompt went in; `next_seq` is the queue's before it.
    pub fn sent(self: *Tracker, next_seq: u64) void {
        self.due_ms = null;
        self.sent_seq = next_seq;
    }

    /// The continue prompt could not be sent: what was held wakes.
    pub fn abandon(self: *Tracker, q: *events.Queue) void {
        if (self.active) self.release(q);
    }

    fn endEpisode(self: *Tracker) void {
        self.active = false;
        self.due_ms = null;
        self.sent_seq = null;
        self.first_job = null;
        self.from_seq = 0;
    }

    /// Let everything the episode held go: errors wake, a held done becomes
    /// history (the next done covers its jobs).
    fn release(self: *Tracker, q: *events.Queue) void {
        for (q.events.items) |*ev| {
            if (!ev.held or ev.seq < self.from_seq) continue;
            ev.held = false;
            if (ev.kind == .done) ev.delivered = true;
        }
        self.carry_first_job = self.first_job;
        self.endEpisode();
    }

    fn coverJobs(_: *Tracker, ev: *events.Event, first: ?u32) void {
        const f = first orelse return;
        const own = ev.first_job orelse ev.job orelse f;
        ev.first_job = @min(own, f);
    }

    /// Examine the next unexamined events of `q` until one changes the
    /// episode; call it until it returns `none`.
    pub fn next(self: *Tracker, q: *events.Queue, now_ms: i64) Step {
        if (self.active and self.policy == null) {
            const n = self.used;
            self.release(q);
            return .{ .gave_up = .{ .why = .off, .attempts = n, .text = "" } };
        }
        while (self.seen + 1 < q.next_seq) {
            self.seen += 1;
            const ev = bySeq(q, self.seen) orelse continue;
            switch (ev.kind) {
                .@"error" => {
                    const cls = ev.class orelse continue;
                    if (!cls.wakesByDefault()) continue;
                    if (cls.retriedOnOverload() and !ev.delivered) if (self.policy) |p| {
                        if (self.used < p.max) {
                            ev.held = true;
                            self.used += 1;
                            if (!self.active) self.from_seq = ev.seq;
                            self.active = true;
                            const delay = delayMs(p, self.used);
                            self.due_ms = now_ms + delay;
                            self.sent_seq = null;
                            return .{ .scheduled = .{ .attempt = self.used, .max = p.max, .delay_ms = delay, .text = ev.text } };
                        }
                        const n = self.used;
                        if (self.active) self.release(q);
                        return .{ .gave_up = .{ .why = .exhausted, .attempts = n, .text = ev.text } };
                    };
                    if (self.active) {
                        const n = self.used;
                        self.release(q);
                        return .{ .gave_up = .{ .why = .other_error, .attempts = n, .text = ev.text } };
                    }
                },
                .done => {
                    if (!self.active) {
                        self.coverJobs(ev, self.carry_first_job);
                        self.carry_first_job = null;
                        continue;
                    }
                    const continued = if (self.sent_seq) |s| ev.seq >= s else false;
                    if (!continued) {
                        // The turn the overload ended: its done waits for the retry.
                        ev.held = true;
                        const f = ev.first_job orelse ev.job;
                        if (f) |x| self.first_job = if (self.first_job) |y| @min(x, y) else x;
                        continue;
                    }
                    self.coverJobs(ev, self.first_job);
                    const n = self.used;
                    self.endEpisode();
                    return .{ .recovered = .{ .attempts = n } };
                },
                .needs_input => if (self.active and self.sent_seq != null and ev.seq >= self.sent_seq.?) {
                    // The continued turn runs on and asks something.
                    const n = self.used;
                    self.carry_first_job = self.first_job;
                    self.endEpisode();
                    return .{ .recovered = .{ .attempts = n } };
                },
                .exited => if (self.active) {
                    const n = self.used;
                    self.release(q);
                    return .{ .gave_up = .{ .why = .exited, .attempts = n, .text = ev.text } };
                },
                .connection_lost, .connection_restored, .message, .match => {},
            }
        }
        return .none;
    }
};

fn bySeq(q: *events.Queue, seq: u64) ?*events.Event {
    for (q.events.items) |*ev| if (ev.seq == seq) return ev;
    return null;
}

// ── tests ────────────────────────────────────────────────────────

const t = std.testing;

/// Drain the tracker; the last non-none step.
fn run(tr: *Tracker, q: *events.Queue, now: i64) Step {
    var last: Step = .none;
    while (true) {
        const s = tr.next(q, now);
        if (s == .none) return last;
        last = s;
    }
}

/// What a plain consumer is woken with now: the kinds, in order.
fn wakes(q: *events.Queue, buf: []vocab.EventKind) ![]vocab.EventKind {
    var c: events.Cursor = .{};
    const d = (try c.take(q, .{}, 0, t.allocator)) orelse return buf[0..0];
    defer t.allocator.free(d.items);
    for (d.items, 0..) |it, i| buf[i] = it.kind;
    return buf[0..d.items.len];
}

test "the backoff doubles from backoff_s and stops at the cap" {
    const p = Policy{ .max = 5, .backoff_s = 10 };
    try t.expectEqual(@as(i64, 10_000), delayMs(p, 1));
    try t.expectEqual(@as(i64, 20_000), delayMs(p, 2));
    try t.expectEqual(@as(i64, 40_000), delayMs(p, 3));
    try t.expectEqual(@as(i64, BACKOFF_CAP_S * 1000), delayMs(p, 9));
    try t.expectEqual(@as(i64, BACKOFF_CAP_S * 1000), delayMs(.{ .backoff_s = 5000 }, 1));
}

test "an overload is held and retried; the continued turn's done recovers, the error never wakes" {
    var q = events.Queue.init(t.allocator, .{});
    defer q.deinit();
    var tr = Tracker{ .policy = .{ .max = 2, .backoff_s = 10 } };
    // Job 0's turn ends on an overload: the error, then its done.
    _ = try q.push(1000, .@"error", .overloaded, "APIError 503: Service Unavailable", "");
    _ = try q.pushDone(1000, 0, 0, "partial", null, null);
    const s = run(&tr, &q, 1000);
    try t.expectEqual(@as(u32, 1), s.scheduled.attempt);
    try t.expectEqual(@as(?i64, 11_000), tr.due_ms);
    var buf: [8]vocab.EventKind = undefined;
    try t.expectEqual(@as(usize, 0), (try wakes(&q, &buf)).len);
    try t.expectEqual(@as(usize, 0), q.undelivered());
    // A held done settles no turn.
    try t.expect(q.lastSettle(0) == null);
    // The continue goes in (job 1) and its turn ends well.
    tr.sent(q.next_seq);
    _ = try q.pushDone(12_000, 1, 1, "all done", 7, null);
    const r = run(&tr, &q, 12_000);
    try t.expectEqual(@as(u32, 1), r.recovered.attempts);
    const got = try wakes(&q, &buf);
    try t.expectEqual(@as(usize, 1), got.len);
    try t.expectEqual(vocab.EventKind.done, got[0]);
    // The done covers the job the overload ended too.
    try t.expectEqual(@as(?u32, 0), q.bySeq(3).?.first_job);
    // A consumer that opts into quiet errors still learns of the overload.
    var opted = events.Cursor.replayFrom(0);
    const d = (try opted.take(&q, .{ .retrying = true }, 0, t.allocator)).?;
    defer t.allocator.free(d.items);
    try t.expectEqual(vocab.EventKind.@"error", d.items[0].kind);
}

test "retries give up after max per job: every held error wakes with the last" {
    var q = events.Queue.init(t.allocator, .{});
    defer q.deinit();
    var tr = Tracker{ .policy = .{ .max = 2, .backoff_s = 1 } };
    var job: u32 = 0;
    var attempts: u32 = 0;
    while (attempts < 3) : (attempts += 1) {
        _ = try q.push(@as(i64, job) * 10_000, .@"error", .overloaded, "Repeated 529 Overloaded errors", "");
        _ = try q.pushDone(@as(i64, job) * 10_000, job, job, "", null, null);
        const s = run(&tr, &q, @as(i64, job) * 10_000);
        if (attempts < 2) {
            try t.expectEqual(attempts + 1, s.scheduled.attempt);
            try t.expectEqual(delayMs(tr.policy.?, attempts + 1), s.scheduled.delay_ms);
            tr.sent(q.next_seq);
        } else try t.expectEqual(GiveUp.exhausted, s.gave_up.why);
        job += 1;
    }
    var buf: [8]vocab.EventKind = undefined;
    const got = try wakes(&q, &buf);
    // Three errors and the last turn's done (the held dones are history).
    try t.expectEqual(@as(usize, 4), got.len);
    try t.expectEqual(vocab.EventKind.done, got[3]);
    try t.expectEqual(@as(?u32, 0), q.events.items[q.events.items.len - 1].first_job);
    // A new prompt is a new job with a new budget.
    tr.newPrompt();
    _ = try q.push(100_000, .@"error", .overloaded, "APIError 529: Overloaded", "");
    try t.expectEqual(@as(u32, 1), run(&tr, &q, 100_000).scheduled.attempt);
}

test "limits, auth failures and other errors are never retried, and end a pending retry" {
    var q = events.Queue.init(t.allocator, .{});
    defer q.deinit();
    var tr = Tracker{ .policy = .{} };
    _ = try q.push(0, .@"error", .limit, "Usage limit reached", "resets 5pm");
    _ = try q.push(0, .@"error", .auth, "Please run /login", "");
    try t.expect(run(&tr, &q, 0) == .none);
    try t.expectEqual(@as(usize, 2), q.undelivered());
    var c: events.Cursor = .{};
    if (try c.take(&q, .{}, 0, t.allocator)) |d| t.allocator.free(d.items);
    // An overload held, then a limit in the continued turn: both wake.
    _ = try q.push(1, .@"error", .overloaded, "APIError 503", "");
    try t.expect(run(&tr, &q, 1) == .scheduled);
    tr.sent(q.next_seq);
    _ = try q.push(2, .@"error", .limit, "You've hit your limit", "");
    try t.expectEqual(GiveUp.other_error, run(&tr, &q, 2).gave_up.why);
    try t.expectEqual(@as(usize, 2), q.undelivered());
    // Without a policy an overload is an ordinary error.
    var off = Tracker{};
    _ = try q.push(3, .@"error", .overloaded, "APIError 502", "");
    try t.expect(run(&off, &q, 3) == .none);
    try t.expectEqual(@as(usize, 3), q.undelivered());
}

test "the app exiting, or the policy turned off, gives a pending retry up" {
    var q = events.Queue.init(t.allocator, .{});
    defer q.deinit();
    var tr = Tracker{ .policy = .{} };
    _ = try q.push(0, .@"error", .overloaded, "APIError 503", "");
    try t.expect(run(&tr, &q, 0) == .scheduled);
    _ = try q.push(1, .exited, null, "", "");
    try t.expectEqual(GiveUp.exited, run(&tr, &q, 1).gave_up.why);
    try t.expectEqual(@as(usize, 2), q.undelivered());

    var q2 = events.Queue.init(t.allocator, .{});
    defer q2.deinit();
    var tr2 = Tracker{ .policy = .{} };
    _ = try q2.push(0, .@"error", .overloaded, "APIError 503", "");
    try t.expect(run(&tr2, &q2, 0) == .scheduled);
    tr2.policy = null;
    try t.expectEqual(GiveUp.off, run(&tr2, &q2, 1).gave_up.why);
    try t.expectEqual(@as(usize, 1), q2.undelivered());
}

test "a repeat of a held error is a new event, the next attempt's" {
    var q = events.Queue.init(t.allocator, .{});
    defer q.deinit();
    var tr = Tracker{ .policy = .{ .max = 3 } };
    const a = try q.push(0, .@"error", .overloaded, "APIError 503: Service Unavailable", "");
    try t.expect(run(&tr, &q, 0) == .scheduled);
    tr.sent(q.next_seq);
    const b = try q.push(10, .@"error", .overloaded, "APIError 503: Service Unavailable", "");
    try t.expect(a != b);
    try t.expectEqual(@as(u32, 2), run(&tr, &q, 10).scheduled.attempt);
}
