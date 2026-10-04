//! `stall_after_min`: ONE `stalled` event when an agent that should be
//! doing something (`vocab.State.stallWatched`) has shown nothing for that
//! long. Silence is the only signal: no process is inspected, so an agent
//! that thinks for an hour without drawing reads exactly like a wedged one,
//! which is why it is opt-in.

const std = @import("std");
const vocab = @import("vocab.zig");
const events = @import("events.zig");
const clock = @import("../util/clock.zig");

/// The longest silence `stall_after_min` takes (a day).
pub const MAX_MIN: u32 = 24 * 60;

pub const Tracker = struct {
    /// Minutes of silence that raise the event; null = off.
    after_min: ?u32 = null,
    /// When the policy was set: silence before it does not count.
    armed_ms: i64 = 0,
    /// The activity mark it fired at: it re-arms only once the app shows
    /// something newer.
    fired_at: ?i64 = null,

    /// Turn it on (`after_min` > 0) or off (null), counting from `now_ms`.
    pub fn set(self: *Tracker, after_min: ?u32, now_ms: i64) void {
        self.* = .{ .after_min = after_min, .armed_ms = now_ms };
    }

    /// Milliseconds until `check` fires, or null while it cannot.
    /// @param activity_ms when the app last showed anything (monotonic).
    pub fn dueIn(self: *const Tracker, st: vocab.State, activity_ms: i64, now_ms: i64) ?i64 {
        const min = self.after_min orelse return null;
        if (!st.stallWatched()) return null;
        if (self.fired_at) |f| if (f == activity_ms) return null;
        const since = @max(activity_ms, self.armed_ms);
        return @max(0, since + @as(i64, min) * 60_000 - now_ms);
    }

    /// `check` would push now (what to say is only worth working out then).
    pub fn isDue(self: *const Tracker, st: vocab.State, activity_ms: i64, now_ms: i64) bool {
        return if (self.dueIn(st, activity_ms, now_ms)) |d| d == 0 else false;
    }

    /// What the event says the agent last did, when known.
    pub const Last = struct {
        /// Wall time (`clock.wallMs`) of its last activity; 0 = unknown.
        activity_wall_ms: i64 = 0,
        /// Its newest tool call's tool.
        tool: ?[]const u8 = null,
    };

    /// Push the `stalled` event once it is due.
    /// @return whether it pushed one.
    pub fn check(self: *Tracker, q: *events.Queue, st: vocab.State, activity_ms: i64, now_ms: i64, last: Last) !bool {
        const due = self.dueIn(st, activity_ms, now_ms) orelse return false;
        if (due > 0) return false;
        self.fired_at = activity_ms;
        const silent_min = @divTrunc(now_ms - @max(activity_ms, self.armed_ms), 60_000);
        var iso: [clock.ISO_LEN]u8 = undefined;
        const since = if (last.activity_wall_ms > 0) clock.isoLocal(&iso, last.activity_wall_ms) else null;
        var buf: [320]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "silent for {d} minutes while {s}{s}{s}{s}{s}: no screen or record change (stall_after_min {d})", .{
            silent_min,
            @tagName(st),
            if (since != null) ", last activity " else "",
            since orelse "",
            if (last.tool != null) ", last tool " else "",
            events.clip(last.tool orelse "", 60),
            self.after_min.?,
        }) catch "silent while busy (stall_after_min)";
        _ = try q.push(now_ms, .stalled, null, text, @tagName(st));
        return true;
    }
};

// ── tests ────────────────────────────────────────────────────────

const t = std.testing;

test "one stalled event per silence, re-armed only by new activity, never while settled" {
    var q = events.Queue.init(t.allocator, .{});
    defer q.deinit();
    var s: Tracker = .{};
    // Off: nothing, however long.
    try t.expect(!(try s.check(&q, .working, 0, 10 * 3_600_000, .{})));
    s.set(15, 1000);
    const min15: i64 = 15 * 60_000;
    // Silence counts from the later of the last activity and the arming.
    try t.expectEqual(@as(?i64, min15), s.dueIn(.working, 0, 1000));
    try t.expect(!(try s.check(&q, .working, 0, 1000 + min15 - 1, .{})));
    try t.expect(try s.check(&q, .working, 0, 1000 + min15, .{ .activity_wall_ms = 1_000_000_000_000, .tool = "Bash" }));
    const ev = q.events.items[0];
    try t.expectEqual(vocab.EventKind.stalled, ev.kind);
    try t.expect(ev.wakesByDefault());
    try t.expect(!ev.settlesTurn());
    try t.expect(std.mem.indexOf(u8, ev.text, "15 minutes while working, last activity ") != null);
    var iso: [clock.ISO_LEN]u8 = undefined;
    try t.expect(std.mem.indexOf(u8, ev.text, clock.isoLocal(&iso, 1_000_000_000_000).?) != null);
    try t.expect(std.mem.indexOf(u8, ev.text, ", last tool Bash: no screen") != null);
    try t.expectEqualStrings("working", ev.detail);
    // Once: still silent, no second event.
    try t.expect(s.dueIn(.working, 0, 1000 + 3 * min15) == null);
    try t.expect(!(try s.check(&q, .working, 0, 1000 + 3 * min15, .{})));
    // The screen changes: re-armed from that change.
    const moved = 1000 + 4 * min15;
    try t.expect(!(try s.check(&q, .waiting_background, moved, moved + min15 - 1, .{})));
    try t.expect(try s.check(&q, .waiting_background, moved, moved + min15, .{}));
    try t.expectEqual(@as(usize, 2), q.events.items.len);
    // Unknown: neither is named.
    try t.expect(std.mem.indexOf(u8, q.events.items[1].text, "last ") == null);
    // An idle agent, or one asking the user, is never stalled.
    s.set(1, 0);
    for ([_]vocab.State{ .idle, .waiting_user, .exited, .disconnected }) |st| try t.expect(!(try s.check(&q, st, 0, 10 * 3_600_000, .{})));
    try t.expectEqual(@as(usize, 2), q.events.items.len);
}
