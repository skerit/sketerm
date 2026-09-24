//! The one transfer state machine.
//!
//! A transfer is identified by its ledger token for its whole life,
//! across attempts, coordinators, daemon restarts and browser faces.
//! Its phase vocabulary is the ledger's `State` (transfers.zig owns
//! that, since it is on disk); THIS module owns which phase changes
//! are legal, what "still in flight" means, and how admission is
//! decided once for the whole process rather than once per view.
//! The GUI's lists (queue, deferred, pending, jobs, retries) are
//! working sets that each hold a token in ONE phase; the answer to
//! "where is transfer X" is the ledger record, never a scan of them.

const std = @import("std");
const store = @import("transfers.zig");
const xferqueue = @import("xferqueue.zig");

pub const State = store.State;

/// A transfer that has not reached a terminal phase.
pub fn active(s: State) bool {
    return switch (s) {
        .queued, .submitting, .running, .waiting_retry => true,
        .done, .failed, .canceled => false,
    };
}

/// Whether a record may move from `from` to `to`. Same-phase writes
/// are legal no-ops (a repeated loss keeps `waiting_retry`); the only
/// ways out of a terminal phase are the user's Retry (`failed` →
/// `queued`/`waiting_retry`), dismissal (`failed` → `canceled`) and
/// a re-paste adopting a canceled record (`canceled` → `queued`).
pub fn legal(from: State, to: State) bool {
    if (from == to) return true;
    return switch (from) {
        .queued => to == .submitting or to == .running or to == .waiting_retry or to == .failed or to == .canceled,
        // A resubmitted idempotent token can answer with a job that
        // already finished: the reply's phase lands directly.
        .submitting => to == .running or to == .done or to == .waiting_retry or to == .failed or to == .canceled or to == .queued,
        // A relay fallback re-submits a running transfer through
        // another coordinator: it passes through `submitting` again.
        .running => to == .submitting or to == .done or to == .failed or to == .canceled or to == .waiting_retry,
        .waiting_retry => to == .queued or to == .submitting or to == .running or to == .failed or to == .canceled,
        .failed => to == .queued or to == .waiting_retry or to == .canceled,
        .canceled => to == .queued,
        .done => false,
    };
}

/// What a record says about its own liveness, independent of any
/// view's working set.
pub const Liveness = struct {
    state: State,
    /// A browser face currently drives it (owns the attempt).
    claimed: bool,
    /// Finished; kept only to carry a pending acknowledgment.
    retired: bool,

    /// Still in flight somewhere: the logical transfer is not over.
    pub fn live(self: Liveness) bool {
        return !self.retired and active(self.state);
    }

    /// In flight AND owned by a face: starting it again would run
    /// the same copy twice.
    pub fn driven(self: Liveness) bool {
        return self.live() and self.claimed;
    }
};

/// One process-wide admission decision: the caller's own slots (its
/// queued items plus the transfers it runs) merged with every OTHER
/// running transfer in the process, keyed by destination. The result
/// indexes the caller's `own` slice, so a queued item is admitted only
/// when no window anywhere is already writing to its destination.
pub fn admissible(own: []const xferqueue.Slot, foreign_running: []const u64, scratch: []xferqueue.Slot, out: []usize) []usize {
    const total = own.len + foreign_running.len;
    if (scratch.len < total) return out[0..0];
    @memcpy(scratch[0..own.len], own);
    for (foreign_running, own.len..) |dest, i| scratch[i] = .{ .dest = dest, .state = .running };
    const admitted = xferqueue.admissible(scratch[0..total], out);
    // Foreign slots are all running and therefore never admitted, so
    // every index already refers to `own`.
    return admitted;
}

test "phases: active vs terminal, and the legal moves" {
    const t = std.testing;
    try t.expect(active(.queued) and active(.running) and active(.waiting_retry) and active(.submitting));
    try t.expect(!active(.done) and !active(.failed) and !active(.canceled));
    try t.expect(legal(.queued, .submitting));
    try t.expect(legal(.submitting, .running));
    try t.expect(legal(.running, .waiting_retry));
    try t.expect(legal(.waiting_retry, .queued));
    try t.expect(legal(.failed, .queued));
    try t.expect(legal(.canceled, .queued));
    try t.expect(legal(.waiting_retry, .waiting_retry));
    try t.expect(!legal(.done, .running));
    try t.expect(!legal(.done, .queued));
    try t.expect(!legal(.canceled, .running));
    try t.expect(!legal(.queued, .done));
    try t.expect(!legal(.failed, .running));
    try t.expect(legal(.running, .submitting));
    try t.expect(legal(.submitting, .done));
    try t.expect(!legal(.canceled, .done));
}

test "liveness: a claimed active record is driven, a retired one is not live" {
    const t = std.testing;
    try t.expect((Liveness{ .state = .running, .claimed = true, .retired = false }).driven());
    try t.expect(!(Liveness{ .state = .running, .claimed = false, .retired = false }).driven());
    try t.expect((Liveness{ .state = .waiting_retry, .claimed = false, .retired = false }).live());
    try t.expect(!(Liveness{ .state = .done, .claimed = true, .retired = false }).live());
    try t.expect(!(Liveness{ .state = .running, .claimed = true, .retired = true }).live());
    try t.expect(!(Liveness{ .state = .failed, .claimed = true, .retired = false }).live());
}

test "admission: another window's running copy to the same disk blocks ours" {
    const t = std.testing;
    var scratch: [8]xferqueue.Slot = undefined;
    var out: [8]usize = undefined;
    const own = [_]xferqueue.Slot{
        .{ .dest = 1, .state = .queued },
        .{ .dest = 2, .state = .queued },
    };
    // Nothing foreign: both start.
    try t.expectEqualSlices(usize, &.{ 0, 1 }, admissible(&own, &.{}, &scratch, &out));
    // A foreign copy already writes to disk 1: only disk 2 starts.
    try t.expectEqualSlices(usize, &.{1}, admissible(&own, &.{1}, &scratch, &out));
    // The foreign run fills the global ceiling: nothing starts.
    const busy = [_]u64{ 10, 11, 12, 13 };
    try t.expectEqual(@as(usize, 0), admissible(&own, &busy, &scratch, &out).len);
    // Scratch too small: refuse rather than mis-decide.
    var tiny: [1]xferqueue.Slot = undefined;
    try t.expectEqual(@as(usize, 0), admissible(&own, &.{}, &tiny, &out).len);
}
