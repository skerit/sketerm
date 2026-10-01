//! Per-agent event queue, wait filter and flood protection.
//!
//! The engine pushes occurrences into a `Queue` (ordered, seq-numbered,
//! bounded). A consumer (an `agent_wait`, the waiter socket, any agent_*
//! call returning "events since last time") owns a `Cursor` and calls
//! `Cursor.take`, which never blocks: blocking waits are the caller's loop.
//!
//! Always-on kinds (`vocab.EventKind.alwaysOn`) are delivered to every
//! consumer, never rate limited; repeats of a coalescing kind within
//! `dedupe_window_ms` fold into the earlier event's `count` at push time.
//! Opt-in kinds go through the agent's ONE `TokenBucket` (shared by all its
//! consumers); a blocked one is not dropped but counted into the cursor's
//! digest, which rides the next delivery that has items (the current one
//! included) or is delivered alone once the bucket has a token again.
//!
//! Only `message` occurrences are stored for the opt-in side: `match` is
//! derived at delivery from the consumer's filter, so one stored message
//! can be a `message` for one consumer and a `match` for another.

const std = @import("std");
const vocab = @import("vocab.zig");
const TokenBucket = @import("../util/tokenbucket.zig").TokenBucket;

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
                if (ev.kind == kind and ev.class == class and std.mem.eql(u8, ev.text, text)) {
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
    pub fn pushDone(self: *Queue, now_ms: i64, job: u32, text: []const u8) !u64 {
        const seq = try self.push(now_ms, .done, null, text, "");
        self.events.items[self.events.items.len - 1].job = job;
        return seq;
    }

    /// The stored event with `seq`, or null when evicted or never pushed.
    pub fn bySeq(self: *const Queue, seq: u64) ?*const Event {
        for (self.events.items) |*ev| {
            if (ev.seq == seq) return ev;
        }
        return null;
    }
};

/// What a consumer asked to be woken for besides the always-on kinds.
pub const Filter = struct {
    messages: bool = false,
    /// Case-insensitive substring of a completed assistant message.
    match: ?[]const u8 = null,

    /// The kind a stored message is delivered as, or null when not wanted.
    fn classify(self: Filter, text: []const u8) ?vocab.EventKind {
        if (self.match) |m| {
            if (m.len > 0 and std.ascii.indexOfIgnoreCase(text, m) != null) return .match;
        }
        return if (self.messages) .message else null;
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
    /// Highest seq examined.
    seen: u64 = 0,
    digest: ?Digest = null,

    /// Everything undelivered that wakes this consumer, or null.
    /// @param alloc owns the returned `items` slice.
    pub fn take(self: *Cursor, q: *Queue, filter: Filter, now_ms: i64, alloc: std.mem.Allocator) !?Delivery {
        var items: std.ArrayList(Item) = .empty;
        errdefer items.deinit(alloc);
        for (q.events.items) |*ev| {
            if (ev.seq <= self.seen) continue;
            if (ev.kind.alwaysOn()) {
                try items.append(alloc, .{ .kind = ev.kind, .event = ev });
                continue;
            }
            const as = filter.classify(ev.text) orelse continue;
            if (q.bucket.take(now_ms)) {
                try items.append(alloc, .{ .kind = as, .event = ev });
            } else {
                const n: u32 = if (self.digest) |d| d.count + 1 else 1;
                self.digest = .{ .count = n, .latest_seq = ev.seq };
            }
        }
        self.seen = q.next_seq - 1;
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

    /// Always-on events this consumer has not been handed yet, without
    /// taking them (a listing reports the count and leaves the delivery).
    pub fn pendingAlwaysOn(self: *const Cursor, q: *const Queue) usize {
        var n: usize = 0;
        for (q.events.items) |ev| {
            if (ev.seq > self.seen and ev.kind.alwaysOn()) n += 1;
        }
        return n;
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
    try t.expectEqual(@as(usize, 2), c.pendingAlwaysOn(&q));
    const d = (try c.take(&q, .{}, 10, t.allocator)).?;
    defer t.allocator.free(d.items);
    try t.expectEqual(@as(usize, 0), c.pendingAlwaysOn(&q));
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
