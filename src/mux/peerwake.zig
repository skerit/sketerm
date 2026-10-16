//! The wake rules of peer messaging: whether a message may WAKE its
//! recipient (be pushed so the session starts a turn) or becomes slow
//! mail, handed to the session with its next turn. The one home of the
//! thresholds; `peermail.Store` asks `judge` for every message to a live
//! recipient of this host, so the rule is applied where the recipient's
//! presence is known, also for mail a federation link relayed here.
//!
//! No necrocast: waking a session whose prompt cache has expired makes it
//! re-read its whole context. A recipient is dormant when it has been
//! silent (not working) for longer than `DORMANT_SILENCE_MS` AND holds
//! `DORMANT_CONTEXT_TOKENS` or more; under that size it is always woken.
//! A fact the recipient never reported (no status line, so no context
//! size) cannot show it is large, so it is never judged dormant.
//!
//! Loop protection: per ordered pair (sender, recipient) at most
//! `LOOP_WAKES_MAX` wakes in any `LOOP_WINDOW_MS`; past that the sender's
//! messages to that recipient are slow mail until the window slides.

const std = @import("std");
const vocab = @import("../agent/vocab.zig");

const PeerState = vocab.PeerState;
const RefuseReason = vocab.RefuseReason;

/// Silence (wall ms since the recipient last worked) past which a large
/// context makes it dormant.
pub const DORMANT_SILENCE_MS: i64 = 60 * 60_000;
/// Context size (tokens) at or above which a silent recipient is dormant.
pub const DORMANT_CONTEXT_TOKENS: u64 = 300_000;
/// Wakes one sender may cause one recipient within `LOOP_WINDOW_MS`.
pub const LOOP_WAKES_MAX: usize = 6;
/// The sliding window of the loop cap (wall ms).
pub const LOOP_WINDOW_MS: i64 = 10 * 60_000;
/// Sender/recipient pairs the limiter remembers (a bound, not a quota).
pub const LOOP_PAIRS_MAX: usize = 256;
/// The `data/agents/facts.json` fact the context size is read from.
pub const CONTEXT_FACT = "context_used_tokens";
/// Rigs override `DORMANT_SILENCE_MS` (wall ms) through this variable.
pub const SILENCE_ENV = "SKETERM_MUX_PEER_DORMANT_MS";

/// The dormancy thresholds; only rigs change the silence.
pub const Policy = struct {
    silence_ms: i64 = DORMANT_SILENCE_MS,
    context_tokens: u64 = DORMANT_CONTEXT_TOKENS,
};

/// What the broker knows of a live recipient.
pub const Recipient = struct {
    state: PeerState,
    /// Wall ms of its last activity: the last registration reporting it
    /// working (or ending a turn), its last send, else when its server
    /// registered.
    active_ms: i64,
    /// Its context size; null = never reported.
    context_tokens: ?u64 = null,
};

/// A peer in a turn (starting or working): never dormant, and its
/// activity clock runs.
pub fn working(state: PeerState) bool {
    return state.attention() == .working;
}

/// Whether waking `r` now would be a necrocast.
pub fn dormant(p: Policy, r: Recipient, now: i64) bool {
    if (working(r.state)) return false;
    const ctx = r.context_tokens orelse return false;
    return now - r.active_ms > p.silence_ms and ctx >= p.context_tokens;
}

/// The context size in a facts object (`facts.toJson`); null when absent
/// or not a non-negative number.
pub fn contextOf(facts: ?std.json.Value) ?u64 {
    const f = facts orelse return null;
    if (f != .object) return null;
    const v = f.object.get(CONTEXT_FACT) orelse return null;
    return switch (v) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        .float => |x| if (x >= 0 and x < 1e18) @intFromFloat(x) else null,
        else => null,
    };
}

/// Wake it, or hand it as slow mail (`reason` null: the sender asked `quiet`).
pub const Verdict = union(enum) {
    wake,
    slow: ?RefuseReason,
};

/// The ordered pairs' recent wakes.
pub const Limiter = struct {
    pairs: std.ArrayList(*Pair) = .empty,

    const Pair = struct {
        key: []u8,
        from_len: usize,
        /// The newest `LOOP_WAKES_MAX` wake times, oldest first.
        times: [LOOP_WAKES_MAX]i64 = undefined,
        n: usize = 0,

        fn newest(self: *const Pair) i64 {
            return if (self.n == 0) 0 else self.times[self.n - 1];
        }

        fn full(self: *const Pair, now: i64) bool {
            return self.n == LOOP_WAKES_MAX and now - self.times[0] < LOOP_WINDOW_MS;
        }

        fn add(self: *Pair, now: i64) void {
            if (self.n == LOOP_WAKES_MAX) {
                std.mem.copyForwards(i64, self.times[0 .. LOOP_WAKES_MAX - 1], self.times[1..]);
                self.n -= 1;
            }
            self.times[self.n] = now;
            self.n += 1;
        }
    };

    pub fn deinit(self: *Limiter, allocator: std.mem.Allocator) void {
        for (self.pairs.items) |p| free(allocator, p);
        self.pairs.deinit(allocator);
    }

    /// `from` already woke `to` the maximum number of times in the window.
    pub fn limited(self: *const Limiter, from: []const u8, to: []const u8, now: i64) bool {
        const p = self.find(from, to) orelse return false;
        return p.full(now);
    }

    /// `from` woke `to` at `now`. Out of memory forgets the wake (fails
    /// open: one more wake, never a lost message).
    pub fn record(self: *Limiter, allocator: std.mem.Allocator, from: []const u8, to: []const u8, now: i64) void {
        const p = self.find(from, to) orelse self.insert(allocator, from, to, now) orelse return;
        p.add(now);
    }

    fn find(self: *const Limiter, from: []const u8, to: []const u8) ?*Pair {
        for (self.pairs.items) |p| {
            if (p.from_len == from.len and std.mem.eql(u8, p.key[0..p.from_len], from) and std.mem.eql(u8, p.key[p.from_len..], to)) return p;
        }
        return null;
    }

    fn insert(self: *Limiter, allocator: std.mem.Allocator, from: []const u8, to: []const u8, now: i64) ?*Pair {
        if (self.pairs.items.len >= LOOP_PAIRS_MAX) {
            // Pairs quiet for a whole window limit nothing; else the stalest goes.
            var i: usize = 0;
            while (i < self.pairs.items.len) {
                if (now - self.pairs.items[i].newest() >= LOOP_WINDOW_MS) {
                    free(allocator, self.pairs.swapRemove(i));
                } else i += 1;
            }
            if (self.pairs.items.len >= LOOP_PAIRS_MAX) {
                var stalest: usize = 0;
                for (self.pairs.items, 0..) |p, k| if (p.newest() < self.pairs.items[stalest].newest()) {
                    stalest = k;
                };
                free(allocator, self.pairs.swapRemove(stalest));
            }
        }
        const p = allocator.create(Pair) catch return null;
        const key = std.mem.concat(allocator, u8, &.{ from, to }) catch {
            allocator.destroy(p);
            return null;
        };
        p.* = .{ .key = key, .from_len = from.len };
        self.pairs.append(allocator, p) catch {
            free(allocator, p);
            return null;
        };
        return p;
    }

    fn free(allocator: std.mem.Allocator, p: *Pair) void {
        allocator.free(p.key);
        allocator.destroy(p);
    }
};

/// The verdict for one message from `from` to the live recipient `r`
/// (`to`); a wake is recorded against the pair.
pub fn judge(p: Policy, limiter: *Limiter, allocator: std.mem.Allocator, quiet: bool, from: []const u8, to: []const u8, r: Recipient, now: i64) Verdict {
    if (quiet) return .{ .slow = null };
    if (dormant(p, r, now)) return .{ .slow = .dormant };
    if (limiter.limited(from, to, now)) return .{ .slow = .loop_limited };
    limiter.record(allocator, from, to, now);
    return .wake;
}

/// `SILENCE_ENV`'s value as a silence in ms; null when not a non-negative integer.
pub fn parseSilence(text: []const u8) ?i64 {
    const v = std.fmt.parseInt(i64, text, 10) catch return null;
    return if (v < 0) null else v;
}

// --------------------------------------------------------------- tests

const t = std.testing;
const MIN: i64 = 60_000;

test "dormancy: a working peer never; silence past an hour only with 300k context or more; unknown facts never" {
    const p: Policy = .{};
    const now: i64 = 100 * 60 * MIN;
    // Working (or starting) is never dormant, however long and large.
    for ([_]PeerState{ .working, .starting }) |st|
        try t.expect(!dormant(p, .{ .state = st, .active_ms = 0, .context_tokens = 900_000 }, now));
    // Idle 59 minutes with a huge context: still awake.
    try t.expect(!dormant(p, .{ .state = .idle, .active_ms = now - 59 * MIN, .context_tokens = 900_000 }, now));
    // Idle 61 minutes: 299k is woken, 300k is dormant.
    try t.expect(!dormant(p, .{ .state = .idle, .active_ms = now - 61 * MIN, .context_tokens = 299_999 }, now));
    try t.expect(dormant(p, .{ .state = .idle, .active_ms = now - 61 * MIN, .context_tokens = 300_000 }, now));
    // Waiting on its user, or presence unknown, counts as silent.
    try t.expect(dormant(p, .{ .state = .waiting_user, .active_ms = now - 61 * MIN, .context_tokens = 300_000 }, now));
    try t.expect(dormant(p, .{ .state = .unknown, .active_ms = now - 61 * MIN, .context_tokens = 300_000 }, now));
    // No context fact: it cannot be shown large, so it is woken.
    try t.expect(!dormant(p, .{ .state = .unknown, .active_ms = 0, .context_tokens = null }, now));
    // Exactly the threshold is not past it.
    try t.expect(!dormant(p, .{ .state = .idle, .active_ms = now - 60 * MIN, .context_tokens = 300_000 }, now));
    // A rig's shorter silence.
    try t.expect(dormant(.{ .silence_ms = 1000 }, .{ .state = .idle, .active_ms = now - 1001, .context_tokens = 300_000 }, now));
}

test "the context fact is read from a facts object" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"context_used_tokens\":312000,\"cost_usd\":1.5}", .{});
    try t.expectEqual(@as(?u64, 312_000), contextOf(v));
    try t.expectEqual(@as(?u64, 4), contextOf(try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"context_used_tokens\":4.5}", .{})));
    try t.expectEqual(@as(?u64, null), contextOf(try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"context_used_percent\":90}", .{})));
    try t.expectEqual(@as(?u64, null), contextOf(try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"context_used_tokens\":-1}", .{})));
    try t.expectEqual(@as(?u64, null), contextOf(null));
}

test "the loop cap: six wakes per pair in ten minutes, then slow until the window slides" {
    var l: Limiter = .{};
    defer l.deinit(t.allocator);
    const awake: Recipient = .{ .state = .idle, .active_ms = 0 };
    const p: Policy = .{};
    var now: i64 = 1_000_000;
    for (0..LOOP_WAKES_MAX) |_| {
        try t.expectEqual(Verdict.wake, judge(p, &l, t.allocator, false, "alice", "bob", awake, now));
        now += MIN;
    }
    // The seventh within ten minutes of the first is slow, and is not counted.
    try t.expectEqual(Verdict{ .slow = .loop_limited }, judge(p, &l, t.allocator, false, "alice", "bob", awake, now));
    // Other pairs are their own: the reverse direction, another sender.
    try t.expectEqual(Verdict.wake, judge(p, &l, t.allocator, false, "bob", "alice", awake, now));
    try t.expectEqual(Verdict.wake, judge(p, &l, t.allocator, false, "carol", "bob", awake, now));
    // The first wake leaves the window: one more is allowed, then slow again.
    now = 1_000_000 + LOOP_WINDOW_MS;
    try t.expectEqual(Verdict.wake, judge(p, &l, t.allocator, false, "alice", "bob", awake, now));
    try t.expectEqual(Verdict{ .slow = .loop_limited }, judge(p, &l, t.allocator, false, "alice", "bob", awake, now));
    // quiet is slow without a reason; dormant comes before the cap.
    try t.expectEqual(Verdict{ .slow = null }, judge(p, &l, t.allocator, true, "zed", "bob", awake, now));
    try t.expectEqual(Verdict{ .slow = .dormant }, judge(p, &l, t.allocator, false, "zed", "bob", .{ .state = .idle, .active_ms = now - 2 * DORMANT_SILENCE_MS, .context_tokens = 400_000 }, now));
    // A key is (from, to), not their concatenation.
    try t.expect(!l.limited("alic", "ebob", now));
}

test "the context fact is one the shipped facts vocabulary declares" {
    const v = try @import("../agent/facts.zig").shipped();
    try t.expect(v.index(CONTEXT_FACT) != null);
}

test "the limiter stays bounded" {
    var l: Limiter = .{};
    defer l.deinit(t.allocator);
    var buf: [16]u8 = undefined;
    for (0..LOOP_PAIRS_MAX + 10) |i| l.record(t.allocator, try std.fmt.bufPrint(&buf, "s{d}", .{i}), "bob", @intCast(i));
    try t.expectEqual(LOOP_PAIRS_MAX, l.pairs.items.len);
    try t.expectEqual(@as(?i64, 1500), parseSilence("1500"));
    try t.expectEqual(@as(?i64, null), parseSilence("-1"));
}
