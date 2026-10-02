//! One agent, whichever source runs it. The read side (state, readiness,
//! records since a cursor, the pending interaction, the event queue, the
//! adapter) is common. Acting is not, and the types say so: `driver()`
//! returns a union tagged by `vocab.SourceKind`, so the MCP layer switches
//! once and cannot mix the two up.
//!
//! A screen source's action is a PLAN: the adapter's recipe with its
//! placeholders filled in, which the caller runs against the terminal
//! (text, keys, sleeps, waits, picks). An API source's action is PERFORMED
//! here, over HTTP, before `perform` returns.
//!
//! Gotcha: a driver points into its `Agent`; keep the agent at a stable
//! address (heap-allocate it) while a driver is in use.

const std = @import("std");
const vocab = @import("vocab.zig");
const adapter = @import("adapter.zig");
const events = @import("events.zig");
const output = @import("output.zig");
const screen_source = @import("screen_source.zig");
const grammar = @import("grammar.zig");
const opencode = @import("opencode.zig");

/// The actions an agent takes: the fields of `adapter.Actions`, so a new
/// action is one edit there and every switch here breaks until handled.
pub const ActionKind = std.meta.FieldEnum(adapter.Actions);

pub const Action = union(ActionKind) {
    /// The prompt text.
    submit: []const u8,
    /// A prompt typed while the app works, for its next turn.
    queue: []const u8,
    /// An option label, a 1-based index, or (API permissions) yes/no/always.
    answer: []const u8,
    answer_text: AnswerText,
    interrupt,
    /// A model name as the app takes it (`provider/model` for opencode).
    set_model: []const u8,
    /// An effort level.
    set_effort: []const u8,
};

pub const AnswerText = struct {
    /// Screen sources: the label of the option `screen.text_options` matched.
    option: []const u8,
    text: []const u8,
};

pub const Error = error{
    /// The adapter has no recipe for the action.
    Unsupported,
    NoPendingInteraction,
    NoSuchOption,
};

pub const Agent = struct {
    allocator: std.mem.Allocator,
    loaded: *const adapter.Loaded,
    source: Source,

    pub const Source = union(vocab.SourceKind) {
        screen: screen_source.Engine,
        opencode_api: opencode.Api,
    };

    /// @param loaded a `screen` adapter; must outlive the agent.
    pub fn initScreen(allocator: std.mem.Allocator, loaded: *const adapter.Loaded, limits: events.Limits) !Agent {
        return .{ .allocator = allocator, .loaded = loaded, .source = .{ .screen = try screen_source.Engine.init(allocator, loaded, limits) } };
    }

    /// Not connected yet: `driver().opencode_api.api.connect` opens the
    /// stream and creates or adopts the session.
    /// @param loaded an `opencode_api` adapter; must outlive the agent.
    pub fn initOpencode(allocator: std.mem.Allocator, loaded: *const adapter.Loaded, limits: events.Limits, endpoint: opencode.Endpoint) !Agent {
        return .{ .allocator = allocator, .loaded = loaded, .source = .{ .opencode_api = try opencode.Api.init(allocator, loaded, limits, endpoint) } };
    }

    pub fn deinit(self: *Agent) void {
        switch (self.source) {
            .screen => |*e| e.deinit(),
            .opencode_api => |*a| a.deinit(),
        }
    }

    pub fn kind(self: *const Agent) vocab.SourceKind {
        return std.meta.activeTag(self.source);
    }

    pub fn state(self: *const Agent) vocab.State {
        return switch (self.source) {
            .screen => |*e| e.state,
            .opencode_api => |*a| a.source.state,
        };
    }

    /// Input sent now is not lost (the app is up and listening).
    pub fn ready(self: *const Agent) bool {
        return switch (self.source) {
            .screen => |*e| e.ready,
            .opencode_api => |*a| a.source.ready,
        };
    }

    /// The agent's events (every consumer keeps its own `events.Cursor`).
    pub fn queue(self: *Agent) *events.Queue {
        return switch (self.source) {
            .screen => |*e| &e.queue,
            .opencode_api => |*a| &a.source.queue,
        };
    }

    /// Records with an id above `since`, oldest first. Borrowed: valid
    /// until the source next changes.
    pub fn recordsSince(self: *const Agent, since: u64, out: *std.ArrayList(output.Record), alloc: std.mem.Allocator) !void {
        return switch (self.source) {
            .screen => |*e| e.recordsSince(since, out, alloc),
            .opencode_api => |*a| a.source.recordsSince(since, out, alloc),
        };
    }

    /// Every record in the source's (chronological) order. Borrowed: valid
    /// until the source next changes.
    /// Fold what the app shows now into records, without announcing them
    /// (an adopted conversation's history, printed before the input box).
    pub fn syncHistory(self: *Agent) !void {
        switch (self.source) {
            .screen => |*e| try e.syncHistory(),
            // The API source loads the history when it adopts the session.
            .opencode_api => {},
        }
    }

    pub fn records(self: *const Agent) []const output.Record {
        return switch (self.source) {
            .screen => |*e| e.records.items,
            .opencode_api => |*a| a.source.records.items,
        };
    }

    /// Prompts the app holds queued for a later turn.
    pub fn queuedPrompts(self: *const Agent) u32 {
        return switch (self.source) {
            .screen => |*e| e.queued_visible,
            .opencode_api => |*a| a.source.queuedPrompts(),
        };
    }

    /// When the app last showed or sent anything (monotonic `clock.nowMs`).
    pub fn lastActivityMs(self: *const Agent) i64 {
        return switch (self.source) {
            .screen => |*e| e.last_change_ms,
            .opencode_api => |*a| a.source.activity_ms,
        };
    }

    /// What the app is waiting on the user for, or null. Borrowed: valid
    /// until the source next changes.
    pub fn interaction(self: *const Agent) ?output.Interaction {
        return switch (self.source) {
            .screen => |*e| e.interaction,
            .opencode_api => |*a| a.source.interaction(),
        };
    }

    /// Whether `action` can be taken: a screen adapter needs a recipe for
    /// it; the API source implements every action.
    pub fn supports(self: *const Agent, action: ActionKind) bool {
        return supportsAction(self.loaded, action);
    }

    pub fn driver(self: *Agent) Driver {
        return switch (self.source) {
            .screen => |*e| .{ .screen = .{ .engine = e, .loaded = self.loaded } },
            .opencode_api => |*a| .{ .opencode_api = .{ .api = a } },
        };
    }
};

/// Whether an adapter can take `action` (for `agent_adapters`).
pub fn supportsAction(loaded: *const adapter.Loaded, action: ActionKind) bool {
    return switch (loaded.spec.source) {
        .screen => recipe(loaded, action).len > 0,
        .opencode_api => true,
    };
}

fn recipe(loaded: *const adapter.Loaded, action: ActionKind) []const adapter.Step {
    return switch (action) {
        inline else => |k| @field(loaded.spec.actions, @tagName(k)),
    };
}

pub const Driver = union(vocab.SourceKind) {
    screen: ScreenDriver,
    opencode_api: ApiDriver,
};

/// Acting on a screen app: plans the caller runs against the terminal.
/// Its inputs (`feed`, `tick`, `noteResync`, ...) are the engine's own.
pub const ScreenDriver = struct {
    engine: *screen_source.Engine,
    loaded: *const adapter.Loaded,

    /// The adapter's recipe for `action` with `{text}`, `{choice}`,
    /// `{model}` and `{effort}` filled in. A `pick` step stays a label: the
    /// caller resolves it with `pickNumber` when it reaches that step,
    /// against the interaction showing then (a recipe waits for a picker
    /// before picking). A `clear_input` step applies only while
    /// `inputEmpty` is false.
    pub fn plan(self: ScreenDriver, allocator: std.mem.Allocator, action: Action) !Plan {
        const steps = recipe(self.loaded, action);
        if (steps.len == 0) return error.Unsupported;
        var values: std.enums.EnumFieldStruct(adapter.Placeholder, ?[]const u8, @as(?[]const u8, null)) = .{};
        switch (action) {
            .submit, .queue => |x| values.text = x,
            .answer => |x| values.choice = x,
            .answer_text => |x| {
                values.choice = x.option;
                values.text = x.text;
            },
            .interrupt => {},
            .set_model => |x| values.model = x,
            .set_effort => |x| values.effort = x,
        }
        return planSteps(allocator, steps, values);
    }

    /// The adapter's `launch.exit` recipe (empty when it has none).
    pub fn exitPlan(self: ScreenDriver, allocator: std.mem.Allocator) !Plan {
        return planSteps(allocator, self.loaded.spec.launch.exit, .{});
    }

    pub fn inputEmpty(self: ScreenDriver) bool {
        return self.engine.input_text.len == 0;
    }

    /// The label of the option a free-text answer goes through in the
    /// interaction showing now (`screen.text_options`), or null.
    pub fn textOption(self: ScreenDriver) ?[]const u8 {
        const it = self.engine.interaction orelse return null;
        const i = grammar.textOption(self.engine.sc, it.kind, it.options) orelse return null;
        return it.options[i].label;
    }

    /// The app's input box is on screen (typing now reaches it).
    pub fn inputShowing(self: ScreenDriver) bool {
        return self.engine.input_row != null;
    }

    /// The number to type for `choice` (label, 1-based index or a unique
    /// part of a label) in the interaction showing now.
    pub fn pickNumber(self: ScreenDriver, choice: []const u8) Error!u32 {
        const it = self.engine.interaction orelse return error.NoPendingInteraction;
        const i = it.pick(choice) orelse return error.NoSuchOption;
        return @intCast(i + 1);
    }

    /// What to type to choose the option `choice` names: its key, else its
    /// 1-based number (written into `buf`).
    pub fn pickKeys(self: ScreenDriver, choice: []const u8, buf: []u8) Error![]const u8 {
        const it = self.engine.interaction orelse return error.NoPendingInteraction;
        const i = it.pick(choice) orelse return error.NoSuchOption;
        if (it.options[i].key.len > 0) return it.options[i].key;
        return std.fmt.bufPrint(buf, "{d}", .{i + 1}) catch error.NoSuchOption;
    }
};

fn planSteps(allocator: std.mem.Allocator, steps: []const adapter.Step, values: std.enums.EnumFieldStruct(adapter.Placeholder, ?[]const u8, @as(?[]const u8, null))) !Plan {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const out = try a.alloc(adapter.Step, steps.len);
    for (steps, out) |s, *o| o.* = switch (s) {
        .text => |x| .{ .text = try adapter.expand(a, x, values) },
        .command => |x| .{ .command = try adapter.expand(a, x, values) },
        .pick => |x| .{ .pick = try adapter.expand(a, x, values) },
        .key, .sleep_ms, .clear_input, .wait, .confirm, .relaunch => s,
    };
    return .{ .arena = arena, .steps = out };
}

pub const Plan = struct {
    arena: std.heap.ArenaAllocator,
    /// Owned by `arena` (keys and waits borrow from the adapter).
    steps: []const adapter.Step,

    pub fn deinit(self: *Plan) void {
        self.arena.deinit();
    }
};

/// Acting on an API app: `perform` does it now. The rest of the API
/// (connect, service, pollFds, models, commands, problem) is `api`'s.
pub const ApiDriver = struct {
    api: *opencode.Api,

    /// Take `action` over the API. On `error.Rejected` (and most others)
    /// `api.problem()` says why.
    pub fn perform(self: ApiDriver, action: Action) !void {
        switch (action) {
            // The server queues a prompt sent while it works.
            .submit, .queue => |x| try self.api.submit(x, null),
            .answer => |x| try self.api.answer(x),
            .answer_text => |x| try self.api.answerText(x.text),
            .interrupt => try self.api.interrupt(),
            .set_model => |x| try self.api.setModel(x),
            .set_effort => |x| try self.api.setEffort(x),
        }
    }
};

// ── tests ────────────────────────────────────────────────────────

const t = std.testing;
const testserver = @import("testserver.zig");
const clock = @import("../util/clock.zig");

test "screen: a plan is the adapter's recipe with placeholders filled, picks resolved later" {
    var set = adapter.Set.init(t.allocator);
    defer set.deinit();
    try set.loadShipped();
    var agent = try Agent.initScreen(t.allocator, set.get("claude").?, .{});
    defer agent.deinit();
    try t.expectEqual(vocab.SourceKind.screen, agent.kind());
    try t.expectEqual(vocab.State.starting, agent.state());
    try t.expect(!agent.ready());
    const d = switch (agent.driver()) {
        .screen => |s| s,
        .opencode_api => return error.TestUnexpectedDriver,
    };

    var submit = try d.plan(t.allocator, .{ .submit = "say hi" });
    defer submit.deinit();
    try t.expectEqual(@as(usize, 4), submit.steps.len);
    try t.expectEqualStrings("say hi", submit.steps[1].text);
    try t.expectEqualStrings("enter", submit.steps[3].key);
    try t.expect(d.inputEmpty());

    var model = try d.plan(t.allocator, .{ .set_model = "opus" });
    defer model.deinit();
    try t.expectEqual(adapter.WaitFor.choice, model.steps[3].wait);
    try t.expectEqualStrings("opus", model.steps[4].pick);

    try t.expectError(error.NoPendingInteraction, d.pickNumber("opus"));
    d.engine.interaction = .{
        .kind = .choice,
        .title = "Select model",
        .detail = "",
        .hint = "",
        .options = &.{ .{ .label = "Default (Sonnet)", .selected = true }, .{ .label = "Opus", .selected = false } },
    };
    try t.expectEqual(@as(u32, 2), try d.pickNumber("opus"));
    try t.expectEqual(@as(u32, 1), try d.pickNumber("1"));
    try t.expectError(error.NoSuchOption, d.pickNumber("haiku"));
    d.engine.interaction = null;
}

test "screen: an action without a recipe is unsupported" {
    const json =
        \\{ "id": "bare", "name": "Bare", "source": "screen",
        \\  "launch": { "binary": "bare", "candidates": ["$PATH"] },
        \\  "screen": { "input_prefix": "> ", "busy_title": ["*"], "records": [ { "kind": "user", "prefix": "you: " } ],
        \\              "choice_prompt": { "prefix": "Select" } },
        \\  "actions": { "submit": [ { "text": "{text}" }, { "key": "enter" } ] } }
    ;
    var problem: ?[]u8 = null;
    const loaded = try adapter.load(t.allocator, "bare.json", json, .user, &problem);
    defer loaded.destroy(t.allocator);
    var agent = try Agent.initScreen(t.allocator, loaded, .{});
    defer agent.deinit();
    try t.expect(agent.supports(.submit));
    try t.expect(!agent.supports(.set_effort));
    try t.expectError(error.Unsupported, agent.driver().screen.plan(t.allocator, .{ .set_effort = "high" }));
    var set = adapter.Set.init(t.allocator);
    defer set.deinit();
    try set.loadShipped();
    for (std.enums.values(ActionKind)) |k| try t.expect(supportsAction(set.get("opencode").?, k));
}

test "api: the common read side and performed actions over HTTP" {
    var srv: testserver.Server = .{};
    try srv.start(t.allocator);
    defer srv.deinit();
    srv.route("POST /session", .{ .body = "{\"id\":\"ses_a\"}" });
    srv.route("GET /session/status", .{ .body = "{}" });
    srv.route("GET /permission", .{ .body = "[]" });
    srv.route("GET /question", .{ .body = "[]" });
    srv.route("POST /session/ses_a/prompt_async", .{ .status = 204, .events = &.{
        "{\"type\":\"message.updated\",\"properties\":{\"sessionID\":\"ses_a\",\"info\":{\"id\":\"msg_u1\",\"role\":\"user\",\"sessionID\":\"ses_a\"}}}",
        "{\"type\":\"message.part.updated\",\"properties\":{\"sessionID\":\"ses_a\",\"part\":{\"type\":\"text\",\"text\":\"ping\",\"messageID\":\"msg_u1\",\"sessionID\":\"ses_a\",\"id\":\"prt_u1\"}}}",
        "{\"type\":\"session.status\",\"properties\":{\"sessionID\":\"ses_a\",\"status\":{\"type\":\"busy\"}}}",
    } });
    srv.route("POST /session/ses_a/abort", .{ .body = "true" });

    var set = adapter.Set.init(t.allocator);
    defer set.deinit();
    try set.loadShipped();
    const agent = try t.allocator.create(Agent);
    defer t.allocator.destroy(agent);
    agent.* = try Agent.initOpencode(t.allocator, set.get("opencode").?, .{}, .{ .port = srv.port(), .password = "pw" });
    defer agent.deinit();
    const d = switch (agent.driver()) {
        .opencode_api => |x| x,
        .screen => return error.TestUnexpectedDriver,
    };
    try d.api.connect(null, clock.nowMs());
    try t.expect(agent.ready());
    try t.expectEqual(vocab.State.idle, agent.state());

    try d.perform(.{ .submit = "ping" });
    const deadline = clock.nowMs() + 3000;
    while (agent.state() != .working and clock.nowMs() < deadline) {
        var pfds: [8]@import("../c.zig").c.struct_pollfd = undefined;
        const n = d.api.pollFds(&pfds);
        _ = @import("../c.zig").c.poll(&pfds, @intCast(n), 20);
        try d.api.service(clock.nowMs());
    }
    try t.expectEqual(vocab.State.working, agent.state());
    var recs: std.ArrayList(output.Record) = .empty;
    defer recs.deinit(t.allocator);
    try agent.recordsSince(0, &recs, t.allocator);
    try t.expectEqual(@as(usize, 1), recs.items.len);
    try t.expectEqualStrings("ping", recs.items[0].text);
    try t.expect(agent.interaction() == null);
    try t.expectError(error.NoPendingInteraction, d.perform(.{ .answer = "yes" }));
    try d.perform(.interrupt);
    try t.expect(srv.lastRequest("POST /session/ses_a/abort") != null);
    try t.expectEqual(@as(usize, 0), agent.queue().events.items.len);
}
