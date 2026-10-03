//! Per-agent event queue, wait filter and flood protection.
//!
//! The engine pushes occurrences into a `Queue` (ordered, seq-numbered,
//! bounded). A consumer (an `agent_wait`, the waiter socket, any agent_*
//! call returning "events since last time") owns a `Cursor` and calls
//! `Cursor.take`, which never blocks: blocking waits are the caller's loop.
//!
//! Delivery is ONE state per agent, on the events themselves
//! (`Event.delivered`): every consumer hands its output to the same
//! assistant, so an event any of them delivered is delivered for all and
//! no other consumer wakes for it again. A cursor only remembers which
//! opt-in events it examined, so a consumer that did not want a message
//! leaves it for one that does. A cursor built `replay` (an explicit
//! `since`) re-reads everything after it, delivered or not.
//!
//! Default-wake events (`wakesByDefault`: an always-on kind, and for an
//! `error` a class that `vocab.ErrorClass.wakesByDefault`, for a `done` one
//! that settled rather than ran into the background cap) wake every
//! consumer, never rate limited; a quiet one (`Event.quiet`) reaches only a
//! consumer whose `Filter` opts into its kind of quiet; repeats of a coalescing kind within
//! `dedupe_window_ms` fold into the earlier event's `count` at push time.
//! Opt-in messages go through the agent's ONE `TokenBucket` (shared by all
//! its consumers); a blocked one is not dropped but counted into the
//! cursor's digest, which rides the next delivery that has items (the
//! current one included) or is delivered alone once the bucket has a token
//! again. An opted-in `retrying` error bypasses the bucket (it is surfaced
//! once per episode and coalesces).
//!
//! Only `message` occurrences are stored for the opt-in side: `match` is
//! derived at delivery from the consumer's filter, so one stored message
//! can be a `message` for one consumer and a `match` for another.

const std = @import("std");
const vocab = @import("vocab.zig");
const TokenBucket = @import("../util/tokenbucket.zig").TokenBucket;

/// Bytes of an event's text a result shows when the record it announces
/// rides the same result (the text is that record's, never repeated).
pub const PREVIEW_MAX = 120;

/// `s` cut to at most `max` bytes on a UTF-8 boundary.
pub const clip = @import("../util/strz.zig").clipUtf8;

/// The first line of `s`, trimmed.
pub fn firstLine(s: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    const nl = std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len;
    return std.mem.trimEnd(u8, trimmed[0..nl], " \t\r");
}

/// A one-line preview of a record's text.
pub fn preview(s: []const u8) []const u8 {
    return clip(firstLine(s), PREVIEW_MAX);
}

pub const Event = struct {
    seq: u64,
    kind: vocab.EventKind,
    /// First occurrence.
    t_ms: i64,
    /// Latest repeat folded into this event (== t_ms when count is 1).
    last_ms: i64,
    count: u32 = 1,
    class: ?vocab.ErrorClass = null,
    /// Owned by the queue.
    text: []u8,
    /// Owned by the queue; e.g. the reset time of a `limit` error.
    detail: []u8,
    /// `done`: the job whose segment ended (`select.zig`).
    job: ?u32 = null,
    /// `done`: the oldest job it covers (`select.SegmentEnd.first_job`).
    first_job: ?u32 = null,
    /// `done` and `message`: the record whose text `text` is (the job's
    /// answer, the completed message); null for a done without one.
    record: ?u64 = null,
    /// `done` fired at the background cap: background tasks still running,
    /// so the turn is not settled and the done is quiet (`Event.quiet`).
    background_tasks: ?u32 = null,
    /// Handed to the assistant by some consumer.
    delivered: bool = false,
    /// A retry (`retry.zig`) answers what it reports: it wakes nobody
    /// unless the retries give up, and settles no turn meanwhile.
    held: bool = false,

    /// Wakes every consumer without being asked for.
    pub fn wakesByDefault(self: *const Event) bool {
        if (self.held or !self.kind.alwaysOn()) return false;
        if (self.kind == .done and self.background_tasks != null) return false;
        const cls = self.class orelse return true;
        return cls.wakesByDefault();
    }

    /// The opt-in that delivers this always-on event although it does not
    /// wake by default, or null (a done a retry holds is never delivered).
    pub fn quiet(self: *const Event) ?Quiet {
        if (!self.kind.alwaysOn() or self.wakesByDefault()) return null;
        return switch (self.kind) {
            .@"error" => .retrying,
            .done => if (self.held) null else .background,
            .needs_input, .exited, .connection_lost, .connection_restored, .stalled, .message, .match => null,
        };
    }

    /// It ends what a prompt started (`vocab.EventKind.settlesTurn`); an
    /// error the agent recovers from by itself does not.
    pub fn settlesTurn(self: *const Event) bool {
        return self.kind.settlesTurn() and self.wakesByDefault();
    }
};

/// Why an always-on event is quiet, named as the `Filter` field that opts in.
pub const Quiet = enum {
    /// An `error` the agent recovers from by itself, or one a retry holds.
    retrying,
    /// A `done` fired at `select.BACKGROUND_DONE_CAP_MS` while background
    /// tasks still run: the turn is not settled.
    background,
};

pub const Limits = struct {
    burst: f64 = 3,
    per_sec: f64 = 1.0 / 30.0,
    dedupe_window_ms: i64 = 60_000,
    /// Stored events; the oldest are evicted past it (counted in `evicted`).
    cap: usize = 512,
};

pub const Queue = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    events: std.ArrayList(Event) = .empty,
    next_seq: u64 = 1,
    evicted: u64 = 0,
    /// The agent's opt-in limiter, shared by every consumer.
    bucket: TokenBucket,

    pub fn init(allocator: std.mem.Allocator, limits: Limits) Queue {
        return .{ .allocator = allocator, .limits = limits, .bucket = .init(limits.burst, limits.per_sec) };
    }

    pub fn deinit(self: *Queue) void {
        for (self.events.items) |ev| self.freeEvent(ev);
        self.events.deinit(self.allocator);
    }

    fn freeEvent(self: *Queue, ev: Event) void {
        self.allocator.free(ev.text);
        self.allocator.free(ev.detail);
    }

    /// Record an occurrence.
    /// @return the seq it is (or was folded into).
    pub fn push(self: *Queue, now_ms: i64, kind: vocab.EventKind, class: ?vocab.ErrorClass, text: []const u8, detail: []const u8) !u64 {
        if (kind == .match) return error.MatchIsDerived;
        if (kind.coalesces()) {
            var i = self.events.items.len;
            while (i > 0) {
                i -= 1;
                const ev = &self.events.items[i];
                if (ev.last_ms < now_ms - self.limits.dedupe_window_ms) break;
                // A held one is a retry's: a repeat is the next attempt's.
                if (!ev.held and ev.kind == kind and ev.class == class and std.mem.eql(u8, ev.text, text)) {
                    ev.count +|= 1;
                    ev.last_ms = now_ms;
                    return ev.seq;
                }
            }
        }
        const owned_text = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned_text);
        const owned_detail = try self.allocator.dupe(u8, detail);
        errdefer self.allocator.free(owned_detail);
        const seq = self.next_seq;
        try self.events.append(self.allocator, .{
            .seq = seq,
            .kind = kind,
            .t_ms = now_ms,
            .last_ms = now_ms,
            .class = class,
            .text = owned_text,
            .detail = owned_detail,
        });
        self.next_seq += 1;
        while (self.events.items.len > self.limits.cap) {
            self.freeEvent(self.events.orderedRemove(0));
            self.evicted += 1;
        }
        return seq;
    }

    /// Record that `job`'s segment ended with `text` as its answer.
    /// @return the seq.
    /// @param first_job the oldest job the done covers.
    /// @param record the answer's record, null when the job has none.
    /// @param background_tasks set when it fired with background tasks still running.
    pub fn pushDone(self: *Queue, now_ms: i64, job: u32, first_job: u32, text: []const u8, record: ?u64, background_tasks: ?u32) !u64 {
        const seq = try self.push(now_ms, .done, null, text, "");
        const ev = &self.events.items[self.events.items.len - 1];
        ev.job = job;
        ev.first_job = first_job;
        ev.record = record;
        ev.background_tasks = background_tasks;
        return seq;
    }

    /// Record that assistant message `record` completed with `text`.
    pub fn pushMessage(self: *Queue, now_ms: i64, text: []const u8, record: u64) !u64 {
        const seq = try self.push(now_ms, .message, null, text, "");
        self.events.items[self.events.items.len - 1].record = record;
        return seq;
    }

    /// Default-wake events no consumer has delivered yet.
    pub fn undelivered(self: *const Queue) usize {
        var n: usize = 0;
        for (self.events.items) |*ev| {
            if (!ev.delivered and ev.wakesByDefault()) n += 1;
        }
        return n;
    }

    /// Mark every event announcing a record (`EventKind.announcesRecord`)
    /// delivered: what they announce is history a resumed app reprinted.
    pub fn deliverAnnounced(self: *Queue) void {
        for (self.events.items) |*ev| {
            if (ev.kind.announcesRecord()) ev.delivered = true;
        }
    }

    /// The newest event at or after `from_seq` that settles a turn
    /// (`Event.settlesTurn`), delivered or not; null when none.
    pub fn lastSettle(self: *const Queue, from_seq: u64) ?*const Event {
        var i = self.events.items.len;
        while (i > 0) {
            i -= 1;
            const ev = &self.events.items[i];
            if (ev.seq < from_seq) break;
            if (ev.settlesTurn()) return ev;
        }
        return null;
    }

    /// The stored event with `seq`, or null when evicted or never pushed.
    pub fn bySeq(self: *const Queue, seq: u64) ?*const Event {
        for (self.events.items) |*ev| {
            if (ev.seq == seq) return ev;
        }
        return null;
    }
};

/// What a consumer asked to be woken for besides the default-wake events.
pub const Filter = struct {
    messages: bool = false,
    /// Case-insensitive substring of a completed assistant message.
    match: ?[]const u8 = null,
    /// Also `error` events whose class does not wake by default.
    retrying: bool = false,
    /// Also a `done` the background cap fired (background tasks still run).
    background: bool = false,

    /// The kind a stored message is delivered as, or null when not wanted.
    fn classify(self: Filter, text: []const u8) ?vocab.EventKind {
        if (self.match) |m| {
            if (m.len > 0 and std.ascii.indexOfIgnoreCase(text, m) != null) return .match;
        }
        return if (self.messages) .message else null;
    }

    /// A quiet event (`Event.quiet`) this filter opts into.
    fn wantsQuiet(self: Filter, ev: *const Event) bool {
        const why = ev.quiet() orelse return false;
        return switch (why) {
            .retrying => self.retrying,
            .background => self.background,
        };
    }
};

pub const Digest = struct {
    /// Opt-in events the bucket held back since the last delivery.
    count: u32,
    /// The newest of them (still in the queue unless evicted meanwhile).
    latest_seq: u64,
};

/// One delivered item: the stored event and the kind it is delivered as
/// (`match` for a message the filter matched).
pub const Item = struct {
    kind: vocab.EventKind,
    event: *const Event,
};

pub const Delivery = struct {
    /// Borrowed from the queue: valid until the queue next evicts.
    items: []Item,
    digest: ?Digest,
};

pub const Cursor = struct {
    /// Highest seq this consumer examined: opt-in events at or below it
    /// are not examined again (a default-wake one is, until delivered).
    seen: u64 = 0,
    /// Re-read everything after `seen` once, delivered or not (an
    /// explicit `since`).
    replay: bool = false,
    digest: ?Digest = null,

    /// A consumer that wakes for undelivered events, and for opt-in ones
    /// after `seen`.
    pub fn after(seen: u64) Cursor {
        return .{ .seen = seen };
    }

    /// A consumer that wants every event after `since`, delivered or not.
    pub fn replayFrom(since: u64) Cursor {
        return .{ .seen = since, .replay = true };
    }

    /// Everything that wakes this consumer and nobody delivered yet (a
    /// replaying one: everything after its mark), or null. What it returns
    /// is marked delivered for every consumer of the queue.
    /// @param alloc owns the returned `items` slice.
    pub fn take(self: *Cursor, q: *Queue, filter: Filter, now_ms: i64, alloc: std.mem.Allocator) !?Delivery {
        var items: std.ArrayList(Item) = .empty;
        errdefer items.deinit(alloc);
        for (q.events.items) |*ev| {
            const fresh = ev.seq > self.seen;
            if (self.replay) {
                if (!fresh) continue;
            } else if (ev.delivered) continue;
            if (ev.wakesByDefault() or (fresh and filter.wantsQuiet(ev))) {
                try items.append(alloc, .{ .kind = ev.kind, .event = ev });
                continue;
            }
            if (!fresh or ev.kind.alwaysOn()) continue;
            const as = filter.classify(ev.text) orelse continue;
            if (q.bucket.take(now_ms)) {
                try items.append(alloc, .{ .kind = as, .event = ev });
            } else {
                const n: u32 = if (self.digest) |d| d.count + 1 else 1;
                self.digest = .{ .count = n, .latest_seq = ev.seq };
            }
        }
        self.seen = q.next_seq - 1;
        for (items.items) |it| @constCast(it.event).delivered = true;
        if (items.items.len == 0) {
            items.deinit(alloc);
            // A held-back digest is delivered alone once a token is back.
            const d = self.digest orelse return null;
            if (!q.bucket.take(now_ms)) return null;
            self.digest = null;
            return .{ .items = &.{}, .digest = d };
        }
        const d = self.digest;
        self.digest = null;
        return .{ .items = try items.toOwnedSlice(alloc), .digest = d };
    }

    /// Milliseconds until a held digest can be delivered alone, or null
    /// when none is held (the caller's wait deadline).
    pub fn digestDueIn(self: *const Cursor, q: *Queue, now_ms: i64) ?i64 {
        if (self.digest == null) return null;
        return q.bucket.msUntilToken(now_ms);
    }
};

// ── tests ────────────────────────────────────────────────────────

const t = std.testing;

fn freeDelivery(d: ?Delivery) void {
    if (d) |x| t.allocator.free(x.items);
}

test "always-on events are delivered in order and advance the cursor" {
    var q = Queue.init(t.allocator, .{});
    defer q.deinit();
    var c: Cursor = .{};
    _ = try q.push(0, .needs_input, null, "Do you want to proceed?", "");
    _ = try q.push(5, .done, null, "final answer", "");
    try t.expectEqual(@as(usize, 2), q.undelivered());
    const d = (try c.take(&q, .{}, 10, t.allocator)).?;
    defer t.allocator.free(d.items);
    try t.expectEqual(@as(usize, 0), q.undelivered());
    try t.expectEqual(@as(usize, 2), d.items.len);
    try t.expectEqual(vocab.EventKind.needs_input, d.items[0].kind);
    try t.expectEqual(@as(u64, 2), d.items[1].event.seq);
    try t.expect(d.digest == null);
    try t.expect((try c.take(&q, .{}, 20, t.allocator)) == null);
}

test "messages wake only consumers that asked, match is case-insensitive" {
    var q = Queue.init(t.allocator, .{});
    defer q.deinit();
    _ = try q.push(0, .message, null, "Build FINISHED with 0 errors", "");
    var plain: Cursor = .{};
    try t.expect((try plain.take(&q, .{}, 1, t.allocator)) == null);

    var m: Cursor = .{};
    const d = (try m.take(&q, .{ .match = "finished" }, 1, t.allocator)).?;
    defer t.allocator.free(d.items);
    try t.expectEqual(vocab.EventKind.match, d.items[0].kind);

    var miss: Cursor = .{};
    try t.expect((try miss.take(&q, .{ .match = "failed" }, 1, t.allocator)) == null);
    try t.expectError(error.MatchIsDerived, q.push(0, .match, null, "x", ""));
}

test "opt-in flood: burst passes, the rest coalesce into a digest, nothing is lost" {
    var q = Queue.init(t.allocator, .{});
    defer q.deinit();
    var c: Cursor = .{};
    var i: usize = 0;
    while (i < 7) : (i += 1) {
        var buf: [16]u8 = undefined;
        _ = try q.push(1000, .message, null, try std.fmt.bufPrint(&buf, "msg {d}", .{i}), "");
    }
    // One wake-up: the burst, plus a digest of the rest.
    const first_opt = try c.take(&q, .{ .messages = true }, 1000, t.allocator);
    try t.expect(first_opt != null);
    const first = first_opt.?;
    defer t.allocator.free(first.items);
    try t.expectEqual(@as(usize, 3), first.items.len);
    try t.expect(first.digest != null);
    try t.expectEqual(@as(u32, 4), first.digest.?.count);
    try t.expectEqualStrings("msg 6", q.bySeq(first.digest.?.latest_seq).?.text);
    try t.expect(c.digest == null);

    // The flood goes on with the bucket empty: no wake-up, a digest waits,
    // and the caller knows when to come back.
    _ = try q.push(2000, .message, null, "msg 7", "");
    _ = try q.push(2000, .message, null, "msg 8", "");
    try t.expect((try c.take(&q, .{ .messages = true }, 2000, t.allocator)) == null);
    try t.expect((try c.take(&q, .{ .messages = true }, 5000, t.allocator)) == null);
    const due = c.digestDueIn(&q, 5000) orelse return error.TestExpectedDigest;
    try t.expect(due >= 25_999 and due <= 26_001);

    // Token refilled: the digest is delivered alone.
    const later_opt = try c.take(&q, .{ .messages = true }, 31_001, t.allocator);
    try t.expect(later_opt != null);
    const later = later_opt.?;
    defer t.allocator.free(later.items);
    try t.expectEqual(@as(usize, 0), later.items.len);
    try t.expect(later.digest != null);
    try t.expectEqual(@as(u32, 2), later.digest.?.count);
    try t.expect(c.digest == null);
}

test "an always-on event bypasses the empty bucket and carries the pending digest" {
    var q = Queue.init(t.allocator, .{ .burst = 1 });
    defer q.deinit();
    var c: Cursor = .{};
    _ = try q.push(0, .message, null, "one", "");
    const a_opt = try c.take(&q, .{ .messages = true }, 0, t.allocator);
    try t.expect(a_opt != null);
    t.allocator.free(a_opt.?.items);
    _ = try q.push(0, .message, null, "two", "");
    try t.expect((try c.take(&q, .{ .messages = true }, 0, t.allocator)) == null);
    try t.expect(c.digest != null);
    _ = try q.push(1, .@"error", .limit, "Usage limit reached", "resets 5pm");
    const b_opt = try c.take(&q, .{ .messages = true }, 1, t.allocator);
    try t.expect(b_opt != null);
    const b = b_opt.?;
    defer t.allocator.free(b.items);
    try t.expectEqual(@as(usize, 1), b.items.len);
    try t.expectEqual(vocab.EventKind.@"error", b.items[0].kind);
    try t.expectEqualStrings("resets 5pm", b.items[0].event.detail);
    try t.expect(b.digest != null);
    try t.expectEqual(@as(u32, 1), b.digest.?.count);
}

test "one delivery state: what one consumer delivered never wakes another" {
    var q = Queue.init(t.allocator, .{});
    defer q.deinit();
    // The assistant's tool calls and two waiters on the same agent.
    var tool: Cursor = .{};
    var w1: Cursor = .{};
    var w2: Cursor = .{};
    _ = try q.push(0, .done, null, "first", "");
    const a = (try w1.take(&q, .{}, 0, t.allocator)).?;
    defer t.allocator.free(a.items);
    try t.expectEqual(@as(usize, 1), a.items.len);
    // Delivered by the first waiter: the other waiter and the tool keep waiting.
    try t.expect((try w2.take(&q, .{}, 0, t.allocator)) == null);
    try t.expect((try tool.take(&q, .{}, 0, t.allocator)) == null);
    // The next one goes to whoever takes first, once.
    _ = try q.push(1, .needs_input, null, "permission: rm", "");
    const b = (try tool.take(&q, .{}, 1, t.allocator)).?;
    defer t.allocator.free(b.items);
    try t.expectEqual(@as(usize, 1), b.items.len);
    try t.expect((try w1.take(&q, .{}, 1, t.allocator)) == null);
    try t.expect((try w2.take(&q, .{}, 1, t.allocator)) == null);
    // A message the tool did not ask for is left for a waiter that did.
    _ = try q.push(2, .message, null, "progress", "");
    try t.expect((try tool.take(&q, .{}, 2, t.allocator)) == null);
    const m = (try w2.take(&q, .{ .messages = true }, 2, t.allocator)).?;
    defer t.allocator.free(m.items);
    try t.expectEqual(vocab.EventKind.message, m.items[0].kind);
    try t.expect((try w1.take(&q, .{ .messages = true }, 2, t.allocator)) == null);
    // An explicit since re-reads everything after it, delivered or not.
    var again = Cursor.replayFrom(0);
    const r = (try again.take(&q, .{}, 3, t.allocator)).?;
    defer t.allocator.free(r.items);
    try t.expectEqual(@as(usize, 2), r.items.len);
    try t.expect((try again.take(&q, .{}, 3, t.allocator)) == null);
}

test "history a resumed app reprints is delivered, a prompt it shows is not" {
    var q = Queue.init(t.allocator, .{});
    defer q.deinit();
    _ = try q.pushDone(0, 0, 0, "an answer from hours ago", 7, null);
    _ = try q.pushMessage(0, "an older message", 5);
    _ = try q.push(0, .needs_input, null, "trust this folder?", "");
    q.deliverAnnounced();
    var c: Cursor = .{};
    const d = (try c.take(&q, .{ .messages = true }, 0, t.allocator)).?;
    defer t.allocator.free(d.items);
    try t.expectEqual(@as(usize, 1), d.items.len);
    try t.expectEqual(vocab.EventKind.needs_input, d.items[0].kind);
}

test "a retrying error wakes only a consumer that opted in; other errors always" {
    var q = Queue.init(t.allocator, .{});
    defer q.deinit();
    _ = try q.push(0, .@"error", .retrying, "servers overloaded", "");
    try t.expectEqual(@as(usize, 0), q.undelivered());
    var plain: Cursor = .{};
    try t.expect((try plain.take(&q, .{}, 0, t.allocator)) == null);
    var opted: Cursor = .{};
    const d = (try opted.take(&q, .{ .retrying = true }, 0, t.allocator)).?;
    defer t.allocator.free(d.items);
    try t.expectEqual(vocab.ErrorClass.retrying, d.items[0].event.class.?);
    try t.expect((try opted.take(&q, .{ .retrying = true }, 0, t.allocator)) == null);
    // The retry turned into a real error: that wakes everyone.
    _ = try q.push(1, .@"error", .api, "Repeated 529 Overloaded errors", "");
    const e = (try plain.take(&q, .{}, 1, t.allocator)).?;
    defer t.allocator.free(e.items);
    try t.expectEqual(vocab.ErrorClass.api, e.items[0].event.class.?);
}

test "a done fired at the background cap wakes only a consumer that opted in, and settles no turn" {
    var q = Queue.init(t.allocator, .{});
    defer q.deinit();
    _ = try q.pushDone(0, 3, 3, "build started in the background", 9, 2);
    const capped = &q.events.items[0];
    try t.expect(!capped.wakesByDefault());
    try t.expectEqual(Quiet.background, capped.quiet().?);
    try t.expect(!capped.settlesTurn());
    try t.expectEqual(@as(usize, 0), q.undelivered());
    try t.expect(q.lastSettle(0) == null);
    var plain: Cursor = .{};
    try t.expect((try plain.take(&q, .{}, 0, t.allocator)) == null);
    // The retrying opt-in is another quiet kind: it does not reach this one.
    var retrying: Cursor = .{};
    try t.expect((try retrying.take(&q, .{ .retrying = true }, 0, t.allocator)) == null);
    var opted: Cursor = .{};
    const d = (try opted.take(&q, .{ .background = true }, 0, t.allocator)).?;
    defer t.allocator.free(d.items);
    try t.expectEqual(@as(?u32, 2), d.items[0].event.background_tasks);
    // The settled done of the same job wakes everyone and settles the turn.
    _ = try q.pushDone(1, 3, 3, "build green", 11, null);
    try t.expect(q.events.items[1].quiet() == null);
    const e = (try plain.take(&q, .{}, 1, t.allocator)).?;
    defer t.allocator.free(e.items);
    try t.expectEqualStrings("build green", e.items[0].event.text);
    try t.expectEqual(vocab.EventKind.done, q.lastSettle(0).?.kind);
    // A done a retry holds reaches no filter at all.
    _ = try q.pushDone(2, 4, 4, "partial", null, null);
    q.events.items[2].held = true;
    try t.expect(q.events.items[2].quiet() == null);
    var all: Cursor = .{};
    try t.expect((try all.take(&q, .{ .background = true, .retrying = true }, 2, t.allocator)) == null);
}

test "a preview is the first line, cut on a UTF-8 boundary at PREVIEW_MAX bytes" {
    try t.expectEqualStrings("first line", preview("  first line \nsecond"));
    const long = "\xc3\xa9" ** 100;
    const p = preview(long);
    try t.expect(p.len <= PREVIEW_MAX);
    try t.expect(std.unicode.utf8ValidateSlice(p));
    var q = Queue.init(t.allocator, .{});
    defer q.deinit();
    _ = try q.pushMessage(0, "msg", 7);
    _ = try q.pushDone(0, 2, 1, "msg", 7, null);
    try t.expectEqual(@as(?u64, 7), q.events.items[0].record);
    try t.expectEqual(@as(?u64, 7), q.events.items[1].record);
    try t.expectEqual(@as(?u32, 2), q.events.items[1].job);
}

test "coalescing kinds fold repeats within the window, done never does" {
    var q = Queue.init(t.allocator, .{ .dedupe_window_ms = 1000 });
    defer q.deinit();
    const s1 = try q.push(0, .@"error", .retrying, "Retrying in 5s", "");
    const s2 = try q.push(500, .@"error", .retrying, "Retrying in 5s", "");
    try t.expectEqual(s1, s2);
    try t.expectEqual(@as(u32, 2), q.bySeq(s1).?.count);
    // Different class or text is a different event.
    try t.expect(try q.push(600, .@"error", .api, "Retrying in 5s", "") != s1);
    // Outside the window: a new event.
    try t.expect(try q.push(3000, .@"error", .retrying, "Retrying in 5s", "") != s1);
    const d1 = try q.push(3000, .done, null, "same", "");
    const d2 = try q.push(3001, .done, null, "same", "");
    try t.expect(d1 != d2);
}

test "the last settling event from a seq: delivered or not, never a quiet error or a message" {
    var q = Queue.init(t.allocator, .{});
    defer q.deinit();
    _ = try q.push(0, .done, null, "old", "");
    const from = q.next_seq;
    try t.expect(q.lastSettle(from) == null);
    _ = try q.push(1, .message, null, "progress", "");
    _ = try q.push(2, .@"error", .retrying, "overloaded", "");
    _ = try q.push(3, .connection_lost, null, "lost", "");
    try t.expect(q.lastSettle(from) == null);
    _ = try q.push(4, .needs_input, null, "permission", "");
    var c: Cursor = .{};
    const d = (try c.take(&q, .{}, 5, t.allocator)).?;
    defer t.allocator.free(d.items);
    try t.expectEqual(vocab.EventKind.needs_input, q.lastSettle(from).?.kind);
    // The newest one wins; an older range still sees it.
    try t.expectEqual(vocab.EventKind.needs_input, q.lastSettle(0).?.kind);
}

test "the cap evicts the oldest events and counts them" {
    var q = Queue.init(t.allocator, .{ .cap = 2 });
    defer q.deinit();
    _ = try q.push(0, .done, null, "a", "");
    _ = try q.push(0, .done, null, "b", "");
    _ = try q.push(0, .done, null, "c", "");
    try t.expectEqual(@as(usize, 2), q.events.items.len);
    try t.expectEqual(@as(u64, 1), q.evicted);
    try t.expect(q.bySeq(1) == null);
    var c: Cursor = .{};
    const d = (try c.take(&q, .{}, 0, t.allocator)).?;
    defer freeDelivery(d);
    try t.expectEqualStrings("b", d.items[0].event.text);
}
