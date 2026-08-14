//! Exactly-once state machine for the tree-sidebar config debounce.

const std = @import("std");

pub const State = struct {
    source: u32 = 0,
    pending: bool = false,

    pub fn scheduled(self: *State, source: u32) void {
        self.source = source;
        self.pending = true;
    }

    pub fn fired(self: *State) bool {
        self.source = 0;
        return self.consume();
    }

    pub fn teardown(self: *State) struct { source: u32, persist: bool } {
        const source = self.source;
        self.source = 0;
        return .{ .source = source, .persist = self.consume() };
    }

    fn consume(self: *State) bool {
        if (!self.pending) return false;
        self.pending = false;
        return true;
    }
};

test "timeout and teardown consume one pending sidebar write exactly once" {
    var fired_first = State{};
    fired_first.scheduled(41);
    try std.testing.expect(fired_first.fired());
    try std.testing.expect(!fired_first.teardown().persist);

    var teardown_first = State{};
    teardown_first.scheduled(42);
    const flush = teardown_first.teardown();
    try std.testing.expectEqual(@as(u32, 42), flush.source);
    try std.testing.expect(flush.persist);
    try std.testing.expect(!teardown_first.fired());
}

test "rescheduling keeps one pending sidebar write" {
    var state = State{};
    state.scheduled(1);
    state.scheduled(2);
    const flush = state.teardown();
    try std.testing.expectEqual(@as(u32, 2), flush.source);
    try std.testing.expect(flush.persist);
    try std.testing.expect(!state.teardown().persist);
}
