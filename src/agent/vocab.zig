//! The agent-adapter vocabulary: the ONE declaring home for every closed
//! set of names the adapters, the engine, the event queue and the MCP
//! surface share. Anything that classifies or enumerates one of these
//! reads a fact on the member (an exhaustive switch here) or derives from
//! the enum, so adding a member is one edit or the build breaks.

const std = @import("std");
const reflect = @import("../util/reflect.zig");

/// Where an adapter reads the agent from. Adding a screen app is a JSON
/// file; adding a source kind is code.
pub const SourceKind = enum {
    /// The terminal Screen (Claude Code in `--ax-screen-reader` mode).
    screen,
    /// opencode's own HTTP API and SSE event stream.
    opencode_api,
};

/// How an agent is doing, as a human glancing at it needs to know: the
/// registry record, `sketerm mcp agents` and the GUI's badges all read it.
/// Declaration order IS the urgency order, most urgent first.
pub const Attention = enum {
    needs_input,
    lost,
    working,
    idle,

    /// The words a person reads for it ("2 needs input").
    pub fn label(self: Attention) []const u8 {
        return switch (self) {
            .needs_input => "needs input",
            .lost => "disconnected",
            .working => "working",
            .idle => "idle",
        };
    }

    /// Its one-character mark where a label does not fit ("2▶ 1?").
    pub fn glyph(self: Attention) []const u8 {
        return switch (self) {
            .needs_input => "?",
            .lost => "\u{2717}",
            .working => "\u{25B6}",
            .idle => "\u{2713}",
        };
    }

    /// Position in a one-line summary, which reads "2 working · 1 needs
    /// input" (the busy count first), unlike the urgency order.
    pub fn summaryRank(self: Attention) u8 {
        return switch (self) {
            .working => 0,
            .needs_input => 1,
            .lost => 2,
            .idle => 3,
        };
    }

    /// Ranks above `other` (needs it sooner).
    pub fn moreUrgent(self: Attention, other: Attention) bool {
        return @intFromEnum(self) < @intFromEnum(other);
    }
};

/// How a peer (one MCP client session) is doing, as its own hooks and
/// statusline report it; never read off its screen.
pub const PeerState = enum {
    starting,
    working,
    idle,
    waiting_user,
    /// The peer reports no presence (no hooks installed); never guessed.
    unknown,
    /// Its server is gone (a durable address with no live server).
    gone,

    /// @return null for `unknown`: there is nothing to rank.
    pub fn attention(self: PeerState) ?Attention {
        return switch (self) {
            .starting, .working => .working,
            .idle => .idle,
            .waiting_user => .needs_input,
            .gone => .lost,
            .unknown => null,
        };
    }
};

/// What a peer's session runs besides its main turn, as the daemon reads
/// it off the session's screen (`grammar.work`): every field is a count
/// named in the plural, and its singular (the name without its last `s`,
/// `_` read as a space) is the noun the screen and the text use.
pub const PeerWork = struct {
    subagents: u32 = 0,
    shells: u32 = 0,
    monitors: u32 = 0,
    /// Background work the screen counts under a noun no field names.
    other_tasks: u32 = 0,

    pub fn isEmpty(self: PeerWork) bool {
        inline for (reflect.fields(PeerWork)) |f| if (@field(self, f.name) != 0) return false;
        return true;
    }

    pub fn eql(a: PeerWork, b: PeerWork) bool {
        return std.meta.eql(a, b);
    }

    /// Add `n` to the field whose noun `word` is (singular or plural).
    /// @return false when no field names it.
    pub fn addTerm(self: *PeerWork, n: u32, word: []const u8) bool {
        inline for (reflect.fields(PeerWork)) |f| {
            const one = comptime singular(f.name);
            if (std.mem.eql(u8, word, one) or (word.len == one.len + 1 and std.mem.startsWith(u8, word, one) and word[one.len] == 's')) {
                @field(self, f.name) +|= n;
                return true;
            }
        }
        return false;
    }

    /// `2 subagents, 1 shell`: the counts that are not 0, in field order.
    pub fn write(self: PeerWork, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var first = true;
        inline for (reflect.fields(PeerWork)) |f| {
            const n = @field(self, f.name);
            if (n != 0) {
                if (!first) try w.writeAll(", ");
                first = false;
                const noun = comptime spaced(f.name);
                try w.print("{d} {s}", .{ n, if (n == 1) noun[0 .. noun.len - 1] else noun });
            }
        }
    }

    fn spaced(comptime name: []const u8) []const u8 {
        comptime {
            var out: [name.len]u8 = undefined;
            for (name, 0..) |ch, i| out[i] = if (ch == '_') ' ' else ch;
            const final = out;
            return &final;
        }
    }

    fn singular(comptime name: []const u8) []const u8 {
        const s = spaced(name);
        return s[0 .. s.len - 1];
    }
};

/// What became of one peer message; `peer_send` answers with one and
/// every later `peer_event` reuses it.
pub const PeerOutcome = enum {
    /// Handed to the recipient's live server, which pushes it into the
    /// session (a Claude Code channel message starts a turn).
    delivered,
    /// Waiting in a durable address's mailbox for its next server.
    queued,
    /// Not accepted; `RefuseReason` says why.
    refused,
    /// Its time-to-live passed while it waited (expiry IS the bounce).
    expired,
    /// Slow mail: handed to the recipient's live server, which does NOT
    /// wake the session with it; the session gets it with its next turn
    /// (or `peer_read`). The sender asked `quiet`, or the reason says why
    /// (`dormant`, `loop_limited`).
    queued_slow,

    /// What a client that predates `queued_slow` reads instead: such a
    /// client fails to parse a member it does not know.
    pub fn compat(self: PeerOutcome) PeerOutcome {
        return switch (self) {
            .queued_slow => .delivered,
            .delivered, .queued, .refused, .expired => self,
        };
    }
};

/// Why a peer message was refused, why a queued one ended unread
/// (`not_durable_gone`, or any refusal a far broker made of relayed mail),
/// or (the `queues` reasons) why it waits.
pub const RefuseReason = enum {
    unknown_address,
    not_durable_gone,
    too_large,
    mailbox_full,
    self,
    federation_unavailable,
    name_taken_ambiguous,
    host_unreachable,
    /// `queued_slow`: the recipient is dormant (silent past the threshold
    /// with a large context), so waking it would re-read its whole context.
    dormant,
    /// `queued_slow`: this sender already woke this recipient the maximum
    /// number of times in the loop window.
    loop_limited,

    /// The sentence a sender reads.
    pub fn describe(self: RefuseReason) []const u8 {
        return switch (self) {
            .unknown_address => "no peer of that address is known on that host",
            .not_durable_gone => "that peer's address was not durable and its server is gone",
            .too_large => "the text is larger than 64 KiB",
            .mailbox_full => "the recipient's mailbox is full",
            .self => "a peer cannot message itself",
            .federation_unavailable => "host/name addresses need federation, which this daemon (or that host's) does not offer",
            .name_taken_ambiguous => "that name's owner is offline while another live server claims it",
            .host_unreachable => "the link to that host is down; the message waits on this side until it is back",
            .dormant => "that session has been silent for a long time with a large context; it is not woken, and reads this when its user next talks to it",
            .loop_limited => "you already woke that session the maximum number of times recently; it reads this with its next turn",
        };
    }

    /// Whether this reason comes with a non-refused outcome (the message
    /// waits: `queued` or `queued_slow`) rather than with `refused` or an
    /// ended message.
    pub fn queues(self: RefuseReason) bool {
        return switch (self) {
            .host_unreachable, .dormant, .loop_limited => true,
            .unknown_address, .not_durable_gone, .too_large, .mailbox_full, .self, .federation_unavailable, .name_taken_ambiguous => false,
        };
    }

    /// What a client that predates slow mail reads instead (null: no reason).
    pub fn compat(self: RefuseReason) ?RefuseReason {
        return switch (self) {
            .dormant, .loop_limited => null,
            .unknown_address, .not_durable_gone, .too_large, .mailbox_full, .self, .federation_unavailable, .name_taken_ambiguous, .host_unreachable => self,
        };
    }
};

/// The state of the link to one federated host.
pub const PeerLink = enum {
    up,
    /// Not connected now (never yet, or dropped): its peers show their
    /// last state and its mail waits in the outbound mailbox.
    down,
    /// That host's daemon predates federation (no welcome flag
    /// `peer_federation`): sends to it are refused `federation_unavailable`.
    unsupported,
};

/// Why a federation link is not up, as the side that dials or awaits it
/// saw it fail (`peerlink`); shown beside every non-up `PeerLink`.
pub const PeerLinkWhy = enum {
    /// A dial is under way.
    dialing,
    /// The transport could not reach the host (detail: ssh's own line).
    @"unreachable",
    /// ssh reached the host and refused the login (detail: ssh's line).
    auth_failed,
    /// The dial failed otherwise (detail: ssh's last line, or the error).
    dial_failed,
    /// That host's daemon predates federation or call-ins (detail: its version).
    unsupported,
    /// The far daemon refused the link (detail: its own words).
    refused,
    /// The link was up and dropped (detail: how).
    dropped,
    /// The far side dials this link (a hub's call-in member, or a member's
    /// hub) and has not (yet, or again).
    awaiting_dial,
    /// A dialed link waiting for the far side to accept its hello.
    greeting,
    /// Another daemon of the same host holds the link and is live: this
    /// one was refused (detail: the far side's words, naming the holder)
    /// and dials again later (`peerhold.HELD_RETRY_MS`).
    taken,
    /// The link is up but keeps being replaced by daemons of one host
    /// taking turns (detail: how often, and which daemons); shown while up.
    flapping,

    /// The words a list shows (its detail follows after a colon).
    pub fn label(self: PeerLinkWhy) []const u8 {
        return switch (self) {
            .dialing => "dialing",
            .@"unreachable" => "unreachable",
            .auth_failed => "auth failed",
            .dial_failed => "dial failed",
            .unsupported => "its daemon is too old",
            .refused => "refused",
            .dropped => "dropped",
            .awaiting_dial => "waiting for it to dial in",
            .greeting => "waiting for hello acceptance",
            .taken => "another daemon of that host holds the link",
            .flapping => "flapping: two daemons keep replacing each other",
        };
    }
};

/// This daemon's part in peer federation.
pub const PeerFederation = enum {
    /// Config `peer_hub`: it dials every outbound `[domain.<name>] peers =
    /// true` and takes the call-ins of the inbound ones.
    hub,
    /// A hub's link said hello to it (now or before), whichever side dialed.
    member,
    off,
};

/// Which side dials a federation link, as this daemon sees it: a hub
/// domain's config `peer_link`, and `direction` in `peer_list` `hosts`.
pub const PeerLinkDirection = enum {
    /// This daemon dials it: a hub's domain by default, a call-in member's hub.
    outbound,
    /// The far daemon dials this one: a call-in member (`peer_hub_domain`).
    inbound,
};

/// Why this MCP server's peer tools cannot reach the broker now.
pub const PeerUnavailable = enum {
    /// The per-user daemon predates peers (no welcome flag `peers`).
    daemon_without_peers,
    /// No daemon answered (or the link was lost); the next peer tool
    /// call reconnects once its backoff passed.
    daemon_unreachable,
    /// The operator's tool policy withholds the peer group.
    withheld,

    /// The sentence a caller reads.
    pub fn describe(self: PeerUnavailable) []const u8 {
        return switch (self) {
            .daemon_without_peers => "the per-user sketerm daemon predates peer messaging; restart it idle with a newer build",
            .daemon_unreachable => "the per-user sketerm daemon is not reachable now; the next peer tool call reconnects",
            .withheld => "the tool policy withholds the peer tools",
        };
    }
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

    /// What this state asks of a person; an exited agent counts as lost
    /// until it is closed.
    pub fn attention(self: State) Attention {
        return switch (self) {
            .waiting_user => .needs_input,
            .disconnected, .exited => .lost,
            .starting, .working, .waiting_subagent, .waiting_background, .retrying => .working,
            .idle => .idle,
        };
    }

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

    /// A side question can be asked now: the app is up, and no prompt of
    /// its own holds the keyboard (a permission dialog would take the keys).
    pub fn takesSideQuestion(self: State) bool {
        return switch (self) {
            .idle, .waiting_background, .working, .waiting_subagent, .retrying => true,
            .starting, .waiting_user, .exited, .disconnected => false,
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
    const fields = reflect.fields(E);
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
    var seen = std.StaticBitSet(9).empty;
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

test "attention: every state classified, urgency follows declaration order" {
    const t = std.testing;
    try t.expectEqual(Attention.needs_input, State.waiting_user.attention());
    try t.expectEqual(Attention.lost, State.disconnected.attention());
    try t.expectEqual(Attention.lost, State.exited.attention());
    try t.expectEqual(Attention.idle, State.idle.attention());
    for ([_]State{ .starting, .working, .waiting_subagent, .waiting_background, .retrying }) |s|
        try t.expectEqual(Attention.working, s.attention());
    // Every attention is reachable from some state.
    var seen = std.EnumSet(Attention).empty;
    for (std.enums.values(State)) |s| seen.insert(s.attention());
    try t.expectEqual(@as(usize, std.enums.values(Attention).len), seen.count());
    try t.expect(Attention.needs_input.moreUrgent(.lost));
    try t.expect(Attention.lost.moreUrgent(.working));
    try t.expect(Attention.working.moreUrgent(.idle));
    try t.expect(!Attention.idle.moreUrgent(.idle));
    try t.expectEqualStrings("disconnected", Attention.lost.label());
    try t.expectEqualStrings("needs input", Attention.needs_input.label());
    // Summary ranks are a permutation.
    var ranks = std.StaticBitSet(std.enums.values(Attention).len).empty;
    for (std.enums.values(Attention)) |a| {
        try t.expect(!ranks.isSet(a.summaryRank()));
        ranks.set(a.summaryRank());
    }
}

test "peer vocabulary: every state ranked except unknown, every reason described" {
    const t = std.testing;
    try t.expectEqual(@as(?Attention, .needs_input), PeerState.waiting_user.attention());
    try t.expectEqual(@as(?Attention, .lost), PeerState.gone.attention());
    try t.expectEqual(@as(?Attention, null), PeerState.unknown.attention());
    for (std.enums.values(RefuseReason)) |r| try t.expect(r.describe().len > 0);
    for (std.enums.values(PeerUnavailable)) |r| try t.expect(r.describe().len > 0);
    for (std.enums.values(PeerLinkWhy)) |w| try t.expect(w.label().len > 0);
    try t.expectEqualStrings("waiting_user", names(PeerState)[3]);
    try t.expectEqual(@as(usize, 5), names(PeerOutcome).len);
    try t.expect(RefuseReason.host_unreachable.queues());
    try t.expect(RefuseReason.dormant.queues() and RefuseReason.loop_limited.queues());
    try t.expect(!RefuseReason.unknown_address.queues());
    // An old client never sees a member it predates.
    for (std.enums.values(PeerOutcome)) |o| try t.expect(o.compat() != .queued_slow);
    for (std.enums.values(RefuseReason)) |r| if (r.compat()) |x| try t.expect(x != .dormant and x != .loop_limited);
    try t.expectEqualStrings("unsupported", names(PeerLink)[2]);
    try t.expectEqualStrings("member", names(PeerFederation)[1]);
    try t.expectEqualStrings("inbound", names(PeerLinkDirection)[1]);
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
