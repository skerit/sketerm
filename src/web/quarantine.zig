//! The legacy-reply quarantine rule shared by every client of the
//! semantic protocol (the GUI face and the headless webdrive).
//!
//! A helper without `semantic-request-ids` answers with frames carrying
//! NO request id, so a reply cannot be attributed to the operation that
//! asked for it. Once a client gives up on such an operation, the one
//! uncorrelated reply still on its way would otherwise satisfy the NEXT
//! request of that kind with the previous request's answer. The kind is
//! therefore quarantined at abandon time and stays unusable until that
//! one late reply has been consumed, or the connection resets.

const std = @import("std");

/// Per-operation-kind quarantine flags. `n` is the client's own kind
/// count — the two clients enumerate different kind sets, and the rule
/// is about the INDEX they hand in, not about a shared enum.
pub fn LegacyQuarantine(comptime n: usize) type {
    return struct {
        const Self = @This();

        held: [n]bool = @splat(false),

        /// Whether a reply for `idx` may still be accepted.
        ///
        /// A quarantined kind consumes the late reply here and refuses
        /// it; a correlated reply (non-zero `request`) is never
        /// quarantined, since its id already tells the two apart.
        pub fn consume(self: *Self, idx: usize, request: u32) bool {
            if (request != 0) return true;
            if (!self.held[idx]) return true;
            self.held[idx] = false;
            return false;
        }

        /// Quarantine `idx`: an uncorrelated operation was abandoned.
        pub fn mark(self: *Self, idx: usize) void {
            self.held[idx] = true;
        }

        /// Whether `idx` is still waiting for its late reply, which is
        /// also what makes the kind busy for a new request.
        pub fn isHeld(self: *const Self, idx: usize) bool {
            return self.held[idx];
        }

        /// Forget everything: the connection reset, so no reply from
        /// the old one can arrive at all.
        pub fn reset(self: *Self) void {
            self.held = @splat(false);
        }
    };
}

test "a quarantined kind consumes exactly one uncorrelated reply" {
    var q: LegacyQuarantine(3) = .{};
    q.mark(1);
    try std.testing.expect(q.isHeld(1));
    try std.testing.expect(!q.consume(1, 0));
    try std.testing.expect(!q.isHeld(1));
    try std.testing.expect(q.consume(1, 0));
}

test "a correlated reply is never quarantined" {
    var q: LegacyQuarantine(3) = .{};
    q.mark(2);
    try std.testing.expect(q.consume(2, 7));
    try std.testing.expect(q.isHeld(2));
}

test "reset clears every kind" {
    var q: LegacyQuarantine(3) = .{};
    q.mark(0);
    q.mark(2);
    q.reset();
    try std.testing.expect(!q.isHeld(0));
    try std.testing.expect(!q.isHeld(2));
}
