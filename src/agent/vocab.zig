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
    /// Idle at its prompt while background tasks it started (a shell run
    /// in the background) still run: its turn is not settled, so no `done`.
    waiting_background,
    waiting_user,
    retrying,
    idle,
    exited,
    disconnected,

    /// A prompt typed now is taken as the next one (not refused as busy).
    pub fn takesPrompt(self: State) bool {
        return switch (self) {
            .idle, .waiting_background => true,
            .starting, .working, .waiting_subagent, .waiting_user, .retrying, .exited, .disconnected => false,
        };
    }

    /// Busy, but a prompt sent now goes into the app's queue for its next
    /// turn. A prompt waiting on the user is not: its keys would answer it.
    pub fn queuesPrompt(self: State) bool {
        return switch (self) {
            .working, .waiting_subagent, .retrying => true,
            .starting, .waiting_background, .waiting_user, .idle, .exited, .disconnected => false,
        };
    }

    /// Nothing more happens without the caller (`agent_wait all`, `agent-wait
    /// --all`): its turn is over, it asks something, or it is gone. A
    /// lost link may come back, and background tasks still end the turn.
    pub fn settled(self: State) bool {
        return switch (self) {
            .idle, .waiting_user, .exited => true,
            .starting, .working, .waiting_subagent, .waiting_background, .retrying, .disconnected => false,
        };
    }

    /// Long silence here is worth a `stalled` event (`stall_after_min`): the
    /// agent should be doing something. A lost link raises its own events.
    pub fn stallWatched(self: State) bool {
        return switch (self) {
            .starting, .working, .waiting_subagent, .waiting_background, .retrying => true,
            .idle, .waiting_user, .exited, .disconnected => false,
        };
    }
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
    /// A lost link to the agent's session is back (always on, so a waiter
    /// learns it without polling).
    connection_restored,
    /// No screen or record change for the caller's `stall_after_min` while
    /// the agent should be working (`State.stallWatched`); once per silence.
    stalled,
    /// Every completed assistant message (opt-in).
    message,
    /// A completed assistant message containing the caller's text (opt-in).
    match,

    /// Always-on events wake every wait, bypass the rate limiter and can
    /// never be suppressed; the rest are opt-in and rate limited.
    pub fn alwaysOn(self: EventKind) bool {
        return switch (self) {
            .done, .needs_input, .@"error", .exited, .connection_lost, .connection_restored, .stalled => true,
            .message, .match => false,
        };
    }

    /// Repeats of the same kind + class + text within the de-duplication
    /// window collapse into one event with a count. `done` never does: two
    /// turns with the same answer are two turns.
    pub fn coalesces(self: EventKind) bool {
        return switch (self) {
            .@"error", .connection_lost, .connection_restored => true,
            .done, .needs_input, .exited, .stalled, .message, .match => false,
        };
    }

    /// Its text is a record's (a completed message, a job's answer): a
    /// result that carries records refers to it rather than repeat it.
    pub fn announcesRecord(self: EventKind) bool {
        return switch (self) {
            .done, .message, .match => true,
            .needs_input, .@"error", .exited, .connection_lost, .connection_restored, .stalled => false,
        };
    }

    /// Which kind a wake-up reports as its outcome when several arrive
    /// together: the highest rank wins (an agent that is gone outranks a
    /// prompt waiting for an answer, which outranks a finished turn).
    pub fn outcomeRank(self: EventKind) u8 {
        return switch (self) {
            .exited => 8,
            .connection_lost => 7,
            .needs_input => 6,
            .@"error" => 5,
            .stalled => 4,
            .done => 3,
            .connection_restored => 2,
            .match => 1,
            .message => 0,
        };
    }

    /// It ends what a prompt started (`agent_wait all`): the turn settled,
    /// asks the user, failed or the app is gone. An `error` counts only
    /// when its class wakes by default (`events.Event.settlesTurn`).
    pub fn settlesTurn(self: EventKind) bool {
        return switch (self) {
            .done, .needs_input, .@"error", .exited => true,
            .connection_lost, .connection_restored, .stalled, .message, .match => false,
        };
    }
};

/// The outcome of a wait that no event decided (every other outcome is
/// the `EventKind` delivered).
pub const WaitOutcome = enum {
    /// The agent is working and the wait ran out.
    still_working,
    /// A prompt went in, and the call returned before the agent started on it.
    sent,
    /// The agent was busy: the app queued the prompt for its next turn, and
    /// the call returned before the app took it.
    queued,
    /// `agent_wait all`: every agent waited on settled.
    all_settled,
};

pub const ErrorClass = enum {
    /// Usage or rate limit; the event carries the reset time when shown.
    limit,
    auth,
    /// Only surfaced when it persists.
    retrying,
    /// The provider was overloaded or unavailable (a 5xx), or the
    /// connection to it dropped, and the turn ended on it: what
    /// `retry_on_overload` answers with a continue prompt.
    overloaded,
    api,
    crashed,
    unknown,

    /// How long a condition of this class must persist before a source
    /// surfaces it (as an event and, for `retrying`, as the state).
    pub fn surfaceAfterMs(self: ErrorClass) i64 {
        return switch (self) {
            .retrying => 10_000,
            .limit, .auth, .overloaded, .api, .crashed, .unknown => 0,
        };
    }

    /// An `error` of this class wakes every wait like the other always-on
    /// events; one that does not is delivered only to a consumer that
    /// opted in (`events.Filter.retrying`): the app recovers by itself.
    pub fn wakesByDefault(self: ErrorClass) bool {
        return switch (self) {
            .retrying => false,
            .limit, .auth, .overloaded, .api, .crashed, .unknown => true,
        };
    }

    /// A turn that ended on it may be continued by `retry_on_overload`;
    /// a usage limit or an auth failure never is.
    pub fn retriedOnOverload(self: ErrorClass) bool {
        return switch (self) {
            .overloaded => true,
            .limit, .auth, .retrying, .api, .crashed, .unknown => false,
        };
    }
};

/// What a permission policy says about one tool or permission name
/// (`agent_open permissions`), mapped to each app by its adapter.
pub const PermissionAction = enum { allow, ask, deny };

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
    try t.expectEqual(@as(usize, 7), always);
    try t.expect(EventKind.connection_restored.alwaysOn());
    try t.expect(!EventKind.message.alwaysOn());
    try t.expect(!EventKind.done.coalesces());
}

test "outcome ranks are distinct and put an ended agent first" {
    const t = std.testing;
    var seen = std.StaticBitSet(9).initEmpty();
    for (std.enums.values(EventKind)) |k| {
        try t.expect(!seen.isSet(k.outcomeRank()));
        seen.set(k.outcomeRank());
        if (k != .exited) try t.expect(k.outcomeRank() < EventKind.exited.outcomeRank());
    }
    try t.expect(EventKind.needs_input.outcomeRank() > EventKind.done.outcomeRank());
    // A link that is back says less than a finished turn arriving with it.
    try t.expect(EventKind.connection_restored.outcomeRank() < EventKind.done.outcomeRank());
}

test "names follow declaration order" {
    const t = std.testing;
    const n = names(State);
    try t.expectEqual(@as(usize, 9), n.len);
    try t.expectEqualStrings("starting", n[0]);
    try t.expectEqualStrings("disconnected", n[8]);
    try t.expectEqualStrings("error", names(EventKind)[2]);
}

test "only retrying waits before it is surfaced, and only it does not wake by default" {
    const t = std.testing;
    for (std.enums.values(ErrorClass)) |cls| {
        try t.expectEqual(cls == .retrying, cls.surfaceAfterMs() > 0);
        try t.expectEqual(cls != .retrying, cls.wakesByDefault());
        // A retried class always wakes once retries give up; limits and
        // auth failures are never retried.
        if (cls.retriedOnOverload()) try t.expect(cls.wakesByDefault());
    }
    try t.expect(!ErrorClass.limit.retriedOnOverload());
    try t.expect(!ErrorClass.auth.retriedOnOverload());
}

test "a wait outcome never shares a name with an event kind" {
    const t = std.testing;
    for (names(WaitOutcome)) |w| {
        try t.expect(std.meta.stringToEnum(EventKind, w) == null);
    }
}

test "an idle agent and one with background tasks take prompts; a busy one does not" {
    const t = std.testing;
    try t.expect(State.idle.takesPrompt());
    try t.expect(State.waiting_background.takesPrompt());
    try t.expect(!State.working.takesPrompt());
    try t.expect(!State.waiting_user.takesPrompt());
    // A state never both takes a prompt and queues one.
    for (std.enums.values(State)) |s| try t.expect(!(s.takesPrompt() and s.queuesPrompt()));
    // A settled agent is never busy; one with background tasks is not settled.
    for (std.enums.values(State)) |s| if (s.settled()) try t.expect(!s.queuesPrompt());
    try t.expect(!State.waiting_background.settled());
    try t.expect(State.waiting_user.settled());
    // Only always-on kinds settle a turn.
    for (std.enums.values(EventKind)) |k| if (k.settlesTurn()) try t.expect(k.alwaysOn());
    try t.expect(State.working.queuesPrompt());
    try t.expect(!State.waiting_user.queuesPrompt());
    // A settled agent is never watched for a stall; a stall settles nothing.
    for (std.enums.values(State)) |s| if (s.settled()) try t.expect(!s.stallWatched());
    try t.expect(State.waiting_background.stallWatched());
    try t.expect(!EventKind.stalled.settlesTurn());
}
