//! Which queued transfers may start next.
//!
//! One destination runs one transfer at a time: parallel writers to the
//! same disk or the same SSH link trade throughput for seek thrash and
//! bandwidth splitting, while unrelated destinations have no reason to
//! wait for each other. A global ceiling still bounds the total.
//!
//! Pure decision function: no queue, no socket and no widget is needed
//! to test the policy.

const std = @import("std");

/// Transfers running at once across all destinations.
pub const MAX_ACTIVE = 4;

pub const State = enum { queued, running };

/// One transfer as the scheduler sees it. `dest` identifies the
/// destination host plus, for local paths, its filesystem device; two
/// slots sharing it are serialized.
pub const Slot = struct {
    dest: u64,
    state: State,
};

/// Indices into `slots` (queue order) that may start now. Writes into
/// `out`; a shorter `out` truncates the same decision.
pub fn admissible(slots: []const Slot, out: []usize) []usize {
    var active: usize = 0;
    for (slots) |s| {
        if (s.state == .running) active += 1;
    }
    var n: usize = 0;
    for (slots, 0..) |s, i| {
        if (n >= out.len or active >= MAX_ACTIVE) break;
        if (s.state != .queued) continue;
        if (destBusy(slots, out[0..n], s.dest)) continue;
        out[n] = i;
        n += 1;
        active += 1;
    }
    return out[0..n];
}

fn destBusy(slots: []const Slot, admitted: []const usize, dest: u64) bool {
    for (slots) |s| {
        if (s.state == .running and s.dest == dest) return true;
    }
    for (admitted) |i| {
        if (slots[i].dest == dest) return true;
    }
    return false;
}

/// Destination identity from a host string and an opaque device id
/// (0 when the destination is remote, where the daemon owns the disk).
pub fn destKey(host: []const u8, device: u64) u64 {
    var h = std.hash.Wyhash.init(0x7f5e);
    h.update(host);
    h.update(std.mem.asBytes(&device));
    return h.final();
}

test "one destination runs one transfer at a time" {
    const t = std.testing;
    var out: [8]usize = undefined;
    const slots = [_]Slot{
        .{ .dest = 1, .state = .queued },
        .{ .dest = 1, .state = .queued },
        .{ .dest = 1, .state = .queued },
    };
    try t.expectEqualSlices(usize, &.{0}, admissible(&slots, &out));
}

test "distinct destinations proceed in parallel" {
    const t = std.testing;
    var out: [8]usize = undefined;
    const slots = [_]Slot{
        .{ .dest = 1, .state = .queued },
        .{ .dest = 2, .state = .queued },
        .{ .dest = 1, .state = .queued },
        .{ .dest = 3, .state = .queued },
    };
    try t.expectEqualSlices(usize, &.{ 0, 1, 3 }, admissible(&slots, &out));
}

test "a running transfer blocks its own destination only" {
    const t = std.testing;
    var out: [8]usize = undefined;
    const slots = [_]Slot{
        .{ .dest = 1, .state = .running },
        .{ .dest = 1, .state = .queued },
        .{ .dest = 2, .state = .queued },
    };
    try t.expectEqualSlices(usize, &.{2}, admissible(&slots, &out));
}

test "the global ceiling is respected" {
    const t = std.testing;
    var out: [16]usize = undefined;
    var slots: [MAX_ACTIVE + 3]Slot = undefined;
    for (&slots, 0..) |*s, i| s.* = .{ .dest = @intCast(i + 1), .state = .queued };
    const started = admissible(&slots, &out);
    try t.expectEqual(@as(usize, MAX_ACTIVE), started.len);

    // Already at the ceiling: nothing else starts, however many
    // distinct destinations wait.
    for (slots[0..MAX_ACTIVE]) |*s| s.state = .running;
    try t.expectEqual(@as(usize, 0), admissible(&slots, &out).len);
}

test "a completed transfer releases its destination and its slot" {
    const t = std.testing;
    var out: [8]usize = undefined;
    var slots = [_]Slot{
        .{ .dest = 7, .state = .running },
        .{ .dest = 7, .state = .queued },
    };
    try t.expectEqual(@as(usize, 0), admissible(&slots, &out).len);
    // The running one finished and left the queue.
    try t.expectEqualSlices(usize, &.{0}, admissible(slots[1..], &out));
}

test "destKey separates hosts and devices" {
    const t = std.testing;
    try t.expectEqual(destKey("", 66), destKey("", 66));
    try t.expect(destKey("", 66) != destKey("", 67));
    try t.expect(destKey("", 66) != destKey("box", 66));
}

test "an over-full queue admits nothing" {
    const t = std.testing;
    var out: [8]usize = undefined;
    var slots: [MAX_ACTIVE + 2]Slot = undefined;
    for (&slots, 0..) |*s, i| s.* = .{ .dest = @intCast(i + 1), .state = .running };
    slots[MAX_ACTIVE + 1].state = .queued;
    try t.expectEqual(@as(usize, 0), admissible(&slots, &out).len);
}
