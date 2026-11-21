//! The transfers popover's presentation rules: the row-state and tone
//! vocabularies, the popover's order, its summary line, the header
//! ring's aggregate, and each card's title. GTK-free, so both test
//! roots pin them; `ui/browser/jobpanel.zig` is the only consumer.

const std = @import("std");
const JobOp = @import("jobop.zig").JobOp;

/// What one transfer row is doing right now.
pub const State = enum {
    queued,
    waiting_retry,
    running,
    paused,
    finished,
    failed,
    canceled,

    /// Still going to move: anything not settled.
    pub fn active(self: State) bool {
        return switch (self) {
            .queued, .waiting_retry, .running, .paused => true,
            .finished, .failed, .canceled => false,
        };
    }
};

/// Paint vocabulary shared by the ring, the bars and the state icons.
pub const Tone = enum(u8) { accent, ok, err, warn, dim };

/// One top-level row as the pure rules see it.
pub const Item = struct {
    state: State,
    /// 0..1 progress; ignored when `known` is false.
    fraction: f64 = 0,
    /// False when the row cannot say how far along it is yet.
    known: bool = true,
    stalled: bool = false,
    /// First-seen sequence; higher is newer.
    order: u64 = 0,
};

/// The header button's ring.
pub const Ring = struct {
    fraction: f64 = 0,
    indeterminate: bool = false,
    tone: Tone = .dim,
    /// A failure the live ring would otherwise hide; null otherwise.
    attention: ?Tone = null,
};

/// Aggregate of the ACTIVE rows (settled ones only tint a full ring),
/// so finished history never drags the progress of live work up.
pub fn ring(items: []const Item) Ring {
    var out: Ring = .{};
    var sum: f64 = 0;
    var n: usize = 0;
    var any_known = false;
    var running = false;
    var stalled = false;
    var failed = false;
    var finished = false;
    for (items) |item| {
        switch (item.state) {
            .failed => failed = true,
            .finished => finished = true,
            else => {},
        }
        if (!item.state.active()) continue;
        n += 1;
        if (item.state == .running) running = true;
        if (item.stalled) stalled = true;
        if (item.known) {
            any_known = true;
            sum += std.math.clamp(item.fraction, 0.0, 1.0);
        }
    }
    // Alone, a failure tints the whole ring; the dot is for a failure
    // hiding behind live work.
    if (failed and n > 0) out.attention = .err;
    if (n > 0) {
        out.fraction = sum / @as(f64, @floatFromInt(n));
        out.indeterminate = !any_known;
        out.tone = if (stalled) .warn else if (running) .accent else .dim;
    } else if (failed) {
        out.fraction = 1;
        out.tone = .err;
    } else if (finished) {
        out.fraction = 1;
        out.tone = .ok;
    }
    return out;
}

/// Popover order: live work first, then failures (they want an answer),
/// then the rest; newest first inside each group.
pub fn lessThan(_: void, a: Item, b: Item) bool {
    const ra = rank(a.state);
    const rb = rank(b.state);
    if (ra != rb) return ra < rb;
    return a.order > b.order;
}

fn rank(state: State) u8 {
    if (state.active()) return 0;
    return if (state == .failed) 1 else 2;
}

/// The popover header's count line, e.g. "2 running, 1 queued".
pub fn summary(buf: []u8, items: []const Item) []const u8 {
    var counts = std.EnumArray(State, usize).initFill(0);
    for (items) |item| counts.getPtr(item.state).* += 1;
    const parts = [_]struct { n: usize, label: []const u8 }{
        .{ .n = counts.get(.running), .label = "running" },
        .{ .n = counts.get(.paused), .label = "paused" },
        .{ .n = counts.get(.queued) + counts.get(.waiting_retry), .label = "queued" },
        .{ .n = counts.get(.failed), .label = "failed" },
        .{ .n = counts.get(.finished), .label = "finished" },
        .{ .n = counts.get(.canceled), .label = "canceled" },
    };
    var w = std.Io.Writer.fixed(buf);
    for (parts) |part| {
        if (part.n == 0) continue;
        if (w.buffered().len > 0) w.writeAll(", ") catch {};
        w.print("{d} {s}", .{ part.n, part.label }) catch {};
    }
    if (w.buffered().len == 0) w.writeAll("No transfers") catch {};
    return w.buffered();
}

/// A card's sentence: "Copying 312 items to archdev", "Copied notes.txt".
/// `dest_host` is display-ready and empty for this computer; `items`
/// above one replaces the name with a count.
pub fn title(buf: []u8, op: JobOp, state: State, name: []const u8, items: usize, dest_host: []const u8) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    const verb = if (state == .finished) op.doneVerb() else op.activeVerb();
    if (items > 1) {
        w.print("{s} {d} items", .{ verb, items }) catch {};
    } else {
        w.print("{s} {s}", .{ verb, name }) catch {};
    }
    if (dest_host.len > 0 and state != .finished) w.print(" to {s}", .{dest_host}) catch {};
    return w.buffered();
}

test "the ring averages live rows only and tints settled history" {
    const t = std.testing;
    const live = [_]Item{
        .{ .state = .running, .fraction = 0.5 },
        .{ .state = .queued },
        .{ .state = .finished, .fraction = 1 },
    };
    const r = ring(&live);
    try t.expectApproxEqAbs(@as(f64, 0.25), r.fraction, 0.0001);
    try t.expectEqual(Tone.accent, r.tone);
    try t.expect(!r.indeterminate);
    try t.expect(r.attention == null);

    const queued_only = [_]Item{.{ .state = .queued, .known = false }};
    const q = ring(&queued_only);
    try t.expectEqual(Tone.dim, q.tone);
    try t.expect(q.indeterminate);

    const stalled = [_]Item{.{ .state = .running, .fraction = 0.1, .stalled = true }};
    try t.expectEqual(Tone.warn, ring(&stalled).tone);

    const done = [_]Item{ .{ .state = .finished }, .{ .state = .canceled } };
    const d = ring(&done);
    try t.expectEqual(Tone.ok, d.tone);
    try t.expectEqual(@as(f64, 1), d.fraction);

    // A failure beside live work keeps the live ring and raises attention.
    const mixed = [_]Item{ .{ .state = .running, .fraction = 0.4 }, .{ .state = .failed } };
    const m = ring(&mixed);
    try t.expectEqual(Tone.accent, m.tone);
    try t.expectEqual(Tone.err, m.attention.?);
    try t.expectApproxEqAbs(@as(f64, 0.4), m.fraction, 0.0001);

    const failed = [_]Item{ .{ .state = .failed }, .{ .state = .finished } };
    try t.expectEqual(Tone.err, ring(&failed).tone);
    try t.expect(ring(&failed).attention == null);

    try t.expectEqual(Tone.dim, ring(&.{}).tone);
}

test "popover order is live first, then failures, newest first in each" {
    var items = [_]Item{
        .{ .state = .finished, .order = 9 },
        .{ .state = .running, .order = 1 },
        .{ .state = .failed, .order = 2 },
        .{ .state = .queued, .order = 5 },
        .{ .state = .canceled, .order = 3 },
        .{ .state = .paused, .order = 4 },
    };
    std.mem.sort(Item, &items, {}, lessThan);
    const want = [_]u64{ 5, 4, 1, 2, 9, 3 };
    for (items, want) |item, order| try std.testing.expectEqual(order, item.order);
}

test "summary counts each state once and says when there is nothing" {
    var buf: [128]u8 = undefined;
    const items = [_]Item{
        .{ .state = .running },
        .{ .state = .running },
        .{ .state = .queued },
        .{ .state = .waiting_retry },
        .{ .state = .failed },
    };
    try std.testing.expectEqualStrings("2 running, 2 queued, 1 failed", summary(&buf, &items));
    try std.testing.expectEqualStrings("No transfers", summary(&buf, &.{}));
}

test "titles name the work, its count and a remote destination" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Copying 312 items to archdev",
        title(&buf, .copy, .running, "Copy 312 items", 312, "archdev"),
    );
    try std.testing.expectEqualStrings("Moving demo.webm", title(&buf, .move, .queued, "demo.webm", 1, ""));
    try std.testing.expectEqualStrings("Copied 2 items", title(&buf, .copy, .finished, "Copy 2 items", 2, "archdev"));
    try std.testing.expectEqualStrings("Copying site.db", title(&buf, .copy, .failed, "site.db", 1, ""));
    try std.testing.expectEqualStrings("Trashing old", title(&buf, .trash, .running, "old", 0, ""));
}
