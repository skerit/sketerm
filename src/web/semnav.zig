//! Semantic navigation state shared by cefhost callbacks and core tests.

const std = @import("std");

pub const State = struct {
    generation: u32 = 1,
    loading: bool = false,
    waiting_load_start: bool = false,
    stop_requested: bool = false,

    pub fn start(self: *State, expect_load_start: bool) void {
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
        self.loading = true;
        self.waiting_load_start = expect_load_start;
        self.stop_requested = false;
    }

    /// True when this callback belongs to a navigation already started
    /// explicitly; false means cefhost must start a page-driven one.
    pub fn takeExpectedLoadStart(self: *State) bool {
        if (!self.waiting_load_start) return false;
        self.waiting_load_start = false;
        self.stop_requested = false;
        return true;
    }

    pub fn rearmed(self: *State) void {
        self.loading = false;
        self.waiting_load_start = false;
        self.stop_requested = false;
    }

    pub fn requestStop(self: *State) void {
        self.stop_requested = true;
    }

    /// Consume the stop marker once, whether ERR_ABORTED arrived inside
    /// `stop_load` or cefhost has to finish the transition afterwards.
    pub fn takeStopRequest(self: *State) bool {
        if (!self.stop_requested) return false;
        self.stop_requested = false;
        return true;
    }
};

test "explicit and page-driven load starts advance exactly once" {
    var state = State{};
    state.start(true);
    const explicit_generation = state.generation;
    try std.testing.expect(state.takeExpectedLoadStart());
    try std.testing.expectEqual(explicit_generation, state.generation);
    try std.testing.expect(!state.takeExpectedLoadStart());
    state.start(false);
    try std.testing.expect(state.generation != explicit_generation);
}

test "stop and rearm clear every loading edge" {
    var state = State{};
    state.start(true);
    state.requestStop();
    try std.testing.expect(state.takeStopRequest());
    try std.testing.expect(!state.takeStopRequest());
    state.rearmed();
    try std.testing.expect(!state.loading);
    try std.testing.expect(!state.waiting_load_start);
    try std.testing.expect(!state.stop_requested);
}
