//! The agent-adapter vocabulary: the ONE declaring home for every closed
//! set of names the adapters, the engine, the event queue and the MCP
//! surface share. Anything that classifies or enumerates one of these
//! reads a fact on the member (an exhaustive switch here) or derives from
//! the enum, so adding a member is one edit or the build breaks.

const std = @import("std");

/// Where an adapter reads the agent from. Adding a screen app is a JSON
/// file; adding a source kind is code.
pub const SourceKind = enum {
    /// The terminal Screen (Claude Code in `--ax-screen-reader` mode).
    screen,
    /// opencode's own HTTP API and SSE event stream.
    opencode_api,
};

pub const State = enum {
    starting,
    working,
    waiting_subagent,
    waiting_user,
    retrying,
    idle,
    exited,
    disconnected,
};

pub const RecordKind = enum {
    user,
    assistant,
    tool,
    /// Compaction, interruption, a finished subagent, a denial the adapter recorded.
    notice,
};

pub const EventKind = enum {
    done,
    needs_input,
    @"error",
    exited,
    connection_lost,
    /// Every completed assistant message (opt-in).
    message,
    /// A completed assistant message containing the caller's text (opt-in).
    match,

    /// Always-on events wake every wait, bypass the rate limiter and can
    /// never be suppressed; the rest are opt-in and rate limited.
    pub fn alwaysOn(self: EventKind) bool {
        return switch (self) {
            .done, .needs_input, .@"error", .exited, .connection_lost => true,
            .message, .match => false,
        };
    }

    /// Repeats of the same kind + class + text within the de-duplication
    /// window collapse into one event with a count. `done` never does: two
    /// turns with the same answer are two turns.
    pub fn coalesces(self: EventKind) bool {
        return switch (self) {
            .@"error", .connection_lost => true,
            .done, .needs_input, .exited, .message, .match => false,
        };
    }
};

pub const ErrorClass = enum {
    /// Usage or rate limit; the event carries the reset time when shown.
    limit,
    auth,
    /// Only surfaced when it persists.
    retrying,
    api,
    crashed,
    unknown,

    /// How long a condition of this class must persist before a source
    /// surfaces it (as an event and, for `retrying`, as the state).
    pub fn surfaceAfterMs(self: ErrorClass) i64 {
        return switch (self) {
            .retrying => 10_000,
            .limit, .auth, .api, .crashed, .unknown => 0,
        };
    }
};

pub const InteractionKind = enum { permission, question, choice };

/// A tool call's progress, as a record reports it.
pub const ToolStatus = enum { pending, running, completed, @"error" };

/// The member names of `E`, in declaration order (for schemas and help text).
pub fn names(comptime E: type) []const []const u8 {
    const fields = @typeInfo(E).@"enum".fields;
    const list = comptime blk: {
        var out: [fields.len][]const u8 = undefined;
        for (fields, 0..) |f, i| out[i] = f.name;
        break :blk out;
    };
    return &list;
}

test "event kinds: always-on and coalescing facts" {
    const t = std.testing;
    var always: usize = 0;
    for (std.enums.values(EventKind)) |k| {
        if (k.alwaysOn()) always += 1;
        // Only always-on kinds bypass the limiter, so only they may coalesce.
        if (k.coalesces()) try t.expect(k.alwaysOn());
    }
    try t.expectEqual(@as(usize, 5), always);
    try t.expect(!EventKind.message.alwaysOn());
    try t.expect(!EventKind.done.coalesces());
}

test "names follow declaration order" {
    const t = std.testing;
    const n = names(State);
    try t.expectEqual(@as(usize, 8), n.len);
    try t.expectEqualStrings("starting", n[0]);
    try t.expectEqualStrings("disconnected", n[7]);
    try t.expectEqualStrings("error", names(EventKind)[2]);
}

test "only retrying waits before it is surfaced" {
    const t = std.testing;
    for (std.enums.values(ErrorClass)) |cls| {
        try t.expectEqual(cls == .retrying, cls.surfaceAfterMs() > 0);
    }
}
