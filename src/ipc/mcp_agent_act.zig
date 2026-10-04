//! Acting on an agent: prompts (from templates, `promptFrom`), the one
//! send path (`submitPrompt` -> `confirmDelivery`), interrupting before
//! a send (`stopForSend`), recipes (`act`, `runSteps`), the relaunch
//! they may run, and the agent_template_* tools.

const std = @import("std");
const mcp = @import("mcp.zig");
const termdrive = @import("termdrive.zig");
const adapter = @import("../agent/adapter.zig");
const agent_mod = @import("../agent/agent.zig");
const events = @import("../agent/events.zig");
const output = @import("../agent/output.zig");
const launch = @import("../agent/launch.zig");
const opencode = @import("../agent/opencode.zig");
const brief = @import("../agent/brief.zig");
const mcpassets = @import("mcpassets.zig");
const clock = @import("../util/clock.zig");
const Res = mcp.Res;
const errRes = mcp.errRes;
const argStr = mcp.argStr;

const mcp_agent = @import("mcp_agent.zig");
const mcp_agent_results = @import("mcp_agent_results.zig");
const mcp_agent_index = @import("mcp_agent_index.zig");
const mcp_agent_open = @import("mcp_agent_open.zig");

const STEP_WAIT_MS = mcp_agent.STEP_WAIT_MS;
const INTERRUPT_SETTLE_MS = mcp_agent.INTERRUPT_SETTLE_MS;
const DELIVERY_CONFIRM_MS = mcp_agent.DELIVERY_CONFIRM_MS;
const Entry = mcp_agent.Entry;
const QueuedPrompt = mcp_agent.QueuedPrompt;
const state = &mcp_agent.state;
const statusOf = mcp_agent.statusOf;
const service = mcp_agent.service;
const closeHistory = mcp_agent.closeHistory;
const pump = mcp_agent.pump;
const pumpFor = mcp_agent.pumpFor;
const gone = mcp_agent.gone;
const waitReady = mcp_agent.waitReady;
const waitDelivery = mcp_agent.waitDelivery;
const waitStep = mcp_agent.waitStep;
const waitSideAsked = mcp_agent.waitSideAsked;
const waitSideAnswer = mcp_agent.waitSideAnswer;
const Fail = mcp_agent.Fail;
const Delivered = mcp_agent_results.Delivered;
const combine = mcp_agent_results.combine;
const toJson = mcp_agent_results.toJson;
const block = mcp_agent_results.block;
const writeDescriptor = mcp_agent_index.writeDescriptor;
const publishAgents = mcp_agent_index.publishAgents;
const newUuid = mcp_agent_open.newUuid;
const record = mcp_agent_open.record;
const SpawnSpec = mcp_agent_open.SpawnSpec;
const spawnOn = mcp_agent_open.spawnOn;

/// Pause after the keys that clear an input box: an Escape followed at
/// once by text reads as Alt+key to the app.
const CLEAR_SETTLE_MS: i64 = 200;
/// Bound on the app ending after its exit recipe, before it is killed.
const EXIT_WAIT_MS: i64 = 10_000;

// ── acting ───────────────────────────────────────────────────────

/// Why the agent cannot take a prompt or a setting now, or null when it
/// is idle.
pub fn busy(arena: std.mem.Allocator, e: *Entry) !?Fail {
    const st = e.agent.state();
    if (st.takesPrompt()) return null;
    return switch (st) {
        .idle, .waiting_background => null,
        .starting => Fail{ .code = .timeout, .msg = try std.fmt.allocPrint(arena, "agent {s} is not ready yet (state starting); nothing was sent", .{e.id}) },
        .working, .waiting_subagent, .retrying => Fail{ .code = .conflict, .msg = try std.fmt.allocPrint(arena, "agent {s} is busy (state {s}){s}: agent_wait for its turn to finish, or agent_interrupt it", .{ e.id, @tagName(st), if (e.agent.supports(.queue)) "" else try std.fmt.allocPrint(arena, " and the {s} adapter cannot queue a prompt", .{e.loaded.spec.id}) }) },
        .waiting_user => Fail{ .code = .conflict, .msg = try std.fmt.allocPrint(arena, "agent {s} is waiting for an answer: agent_answer its prompt first", .{e.id}) },
        .exited, .disconnected => Fail{ .code = .unavailable, .msg = try std.fmt.allocPrint(arena, "agent {s} is {s}; agent_close it", .{ e.id, @tagName(st) }) },
    };
}

// ── prompts from templates ───────────────────────────────────────

/// A prompt as typed: the caller's text and/or a rendered template.
pub const Prompt = struct {
    text: []const u8,
    /// The template it was rendered from (results name it, never echo it).
    template: ?[]const u8 = null,
};

pub fn refuse(why: *Fail, code: mcp.ErrCode, msg: []const u8) error{Refused} {
    why.* = .{ .code = code, .msg = msg };
    return error.Refused;
}

/// A stored template, checked as at save.
/// @throws Refused with `why` set.
fn loadTemplate(arena: std.mem.Allocator, name: []const u8, why: *Fail) !brief.Template {
    if (!mcpassets.validName(name)) return refuse(why, .invalid_args, TEMPLATE_NAME_RULE);
    const bytes = mcpassets.load(arena, .agent_template, name) catch |err| return switch (err) {
        error.NotFound => refuse(why, .not_found, try std.fmt.allocPrint(arena, "no template '{s}' (agent_templates lists them)", .{name})),
        error.OutOfMemory => error.OutOfMemory,
        else => refuse(why, .io_failed, try std.fmt.allocPrint(arena, "cannot read template '{s}': {s}", .{ name, @errorName(err) })),
    };
    var r: brief.Refusal = undefined;
    return (try brief.parseStored(arena, name, bytes, &r)) orelse refuse(why, .failed, r.msg);
}

const TEMPLATE_NAME_RULE = "template names are 1-64 letters, digits, '.', '_' or '-', not starting with '.'";

/// The prompt `args` carry: `key` and/or `template` + `vars` (the caller's
/// text after the rendered template); null when neither is given.
/// @throws Refused with `why` set.
pub fn promptFrom(arena: std.mem.Allocator, args: std.json.Value, key: []const u8, why: *Fail) !?Prompt {
    const text = argStr(args, key);
    if (text) |x| if (std.mem.trim(u8, x, " \t\r\n").len == 0)
        return refuse(why, .invalid_args, try std.fmt.allocPrint(arena, "{s} is empty", .{key}));
    const name = argStr(args, "template");
    const vars = mcp.argValue(args, "vars");
    if (name == null and vars != null) return refuse(why, .invalid_args, "vars fills a template: pass 'template' with it");
    const tpl: ?brief.Template = if (name) |n| try loadTemplate(arena, n, why) else null;
    if (text == null and tpl == null) return null;
    var body: []const u8 = text orelse "";
    if (tpl) |t| {
        var r: brief.Refusal = undefined;
        const rendered = (try brief.render(arena, t, vars, &r)) orelse return refuse(why, .invalid_args, r.msg);
        body = if (text) |x| try std.mem.concat(arena, u8, &.{ rendered, "\n\n", x }) else rendered;
    }
    return .{ .text = body, .template = name };
}

pub fn templateSaveTool(arena: std.mem.Allocator, args: std.json.Value) ![]const u8 {
    const name = argStr(args, "name") orelse return errRes(arena, .invalid_args, "agent_template_save needs 'name'");
    if (!mcpassets.validName(name)) return errRes(arena, .invalid_args, TEMPLATE_NAME_RULE);
    const text = argStr(args, "text") orelse return errRes(arena, .invalid_args, "agent_template_save needs 'text'");
    var r: brief.Refusal = undefined;
    const tpl = (try brief.build(arena, name, text, mcp.argValue(args, "vars"), argStr(args, "description"), &r)) orelse
        return errRes(arena, .invalid_args, r.msg);
    const replaced = if (mcpassets.load(arena, .agent_template, name)) |_| true else |_| false;
    mcpassets.save(arena, .agent_template, name, try brief.serialize(arena, tpl)) catch |err|
        return errRes(arena, .io_failed, try std.fmt.allocPrint(arena, "cannot save template '{s}': {s}", .{ name, @errorName(err) }));
    var names: std.ArrayList([]const u8) = .empty;
    for (tpl.vars) |v| try names.append(arena, v.name);
    var res = Res.init(arena);
    try res.textf("{s} template '{s}' (variables: {s}); agent_send or agent_open take it as template", .{ if (replaced) "replaced" else "saved", name, try brief.varNames(arena, tpl.vars) });
    try res.fact("template", name);
    try res.fact("vars", names.items);
    try res.fact("replaced", replaced);
    return res.finish();
}

const TemplateItem = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    vars: []const []const u8,
};

pub fn templatesTool(arena: std.mem.Allocator, args: std.json.Value) ![]const u8 {
    var why: Fail = undefined;
    if (argStr(args, "name")) |name| {
        const tpl = loadTemplate(arena, name, &why) catch |err| switch (err) {
            error.Refused => return errRes(arena, why.code, why.msg),
            else => return err,
        };
        var vars: std.json.ObjectMap = .empty;
        for (tpl.vars) |v| try vars.put(arena, v.name, if (v.default) |d| .{ .string = d } else .null);
        var res = Res.init(arena);
        try res.textf("template '{s}': variables {s}", .{ name, try brief.varNames(arena, tpl.vars) });
        try res.fact("name", name);
        if (tpl.description) |d| try res.fact("description", d);
        try res.fact("text", tpl.text);
        try res.raw("vars", try toJson(arena, std.json.Value{ .object = vars }));
        if (tpl.description) |d| try block(&res, .{ .name = "description", .body = d });
        try block(&res, .{ .name = "text", .body = tpl.text });
        return res.finish();
    }
    const names = mcpassets.list(arena, .agent_template) catch |err|
        return errRes(arena, .io_failed, try std.fmt.allocPrint(arena, "cannot list templates: {s}", .{@errorName(err)}));
    var items: std.ArrayList(TemplateItem) = .empty;
    var problems: std.ArrayList([]const u8) = .empty;
    var res = Res.init(arena);
    for (names) |n| {
        const tpl = loadTemplate(arena, n, &why) catch |err| switch (err) {
            error.Refused => {
                try problems.append(arena, why.msg);
                continue;
            },
            else => return err,
        };
        var vn: std.ArrayList([]const u8) = .empty;
        for (tpl.vars) |v| try vn.append(arena, v.name);
        try items.append(arena, .{ .name = n, .description = tpl.description, .vars = vn.items });
    }
    try res.textf("{d} template(s){s}", .{ items.items.len, if (problems.items.len > 0) " and stored files that do not load (problems)" else "" });
    for (items.items) |it| try res.textf("{s}: variables {s}", .{ it.name, if (it.vars.len == 0) "none" else try std.mem.join(arena, ", ", it.vars) });
    try res.raw("templates", try toJson(arena, items.items));
    try res.fact("count", items.items.len);
    try res.fact("problems", problems.items);
    return res.finish();
}

pub fn templateDeleteTool(arena: std.mem.Allocator, args: std.json.Value) ![]const u8 {
    const name = argStr(args, "name") orelse return errRes(arena, .invalid_args, "agent_template_delete needs 'name'");
    if (!mcpassets.validName(name)) return errRes(arena, .invalid_args, TEMPLATE_NAME_RULE);
    mcpassets.delete(arena, .agent_template, name) catch |err| return switch (err) {
        error.NotFound => errRes(arena, .not_found, try std.fmt.allocPrint(arena, "no template '{s}' (agent_templates lists them)", .{name})),
        else => errRes(arena, .io_failed, try std.fmt.allocPrint(arena, "cannot delete template '{s}': {s}", .{ name, @errorName(err) })),
    };
    var res = Res.init(arena);
    try res.textf("deleted template '{s}'", .{name});
    try res.fact("template", name);
    try res.fact("deleted", true);
    return res.finish();
}

const Sent = union(enum) { ok: Delivered, fail: Fail };

/// @param no_queue a busy agent is refused instead of queued (agent_send
/// interrupt: it was stopped for this prompt).
/// @param requeue prompts an interrupt made the app drop, typed again into
/// its queue once it took `p` and before the wait (what it did: `requeued`).
pub fn submitAndWait(arena: std.mem.Allocator, e: *Entry, p: Prompt, filter: events.Filter, deadline: i64, no_queue: bool, requeue: []const Prompt, requeued: *Requeued) !Sent {
    service(clock.nowMs());
    const pre = try e.cursor.take(e.agent.queue(), .{}, clock.nowMs(), arena);
    const queued = switch (try submitPrompt(arena, e, p, deadline, no_queue)) {
        .fail => |f| return .{ .fail = f },
        .ok => |q| q,
    };
    requeued.* = try requeueDropped(arena, e, requeue, deadline);
    var dv = try waitAfter(arena, e, pre, filter, deadline);
    if (dv.wait) |*w| {
        w.sent = true;
        w.queued = queued;
    }
    return .{ .ok = dv };
}

/// What `requeueDropped` typed again, and the failure that stopped it.
pub const Requeued = struct {
    done: []const Prompt = &.{},
    fail: ?Fail = null,
    /// Prompts after the failure, not typed again (order is kept).
    left: usize = 0,

    /// What was typed again, as results list it.
    pub fn items(self: Requeued, arena: std.mem.Allocator) ![]const RequeuedItem {
        const out = try arena.alloc(RequeuedItem, self.done.len);
        // A rendered template is never echoed: only its name.
        for (self.done, out) |p, *it| it.* = if (p.template) |t| .{ .template = t } else .{ .text = p.text };
        return out;
    }

    /// The facts and the text line a send result carries for it.
    pub fn report(self: Requeued, arena: std.mem.Allocator, res: *Res) !void {
        if (self.done.len == 0 and self.fail == null) return;
        try res.raw("requeued", try toJson(arena, try self.items(arena)));
        if (self.done.len > 0) try res.textf("{d} prompt(s) this server had queued were dropped by the interrupt and queued again behind the new one, in their order", .{self.done.len});
        if (self.fail) |f| {
            try res.raw("requeue_failed", try toJson(arena, .{ .code = @tagName(f.code), .message = f.msg, .not_requeued = self.left }));
            try res.textf("queuing the dropped prompts again stopped ({s}): {d} of them were not typed again: {s}", .{ @tagName(f.code), self.left, f.msg });
        }
    }
};

/// Type `dropped` (prompts THIS server had queued that an interrupt made
/// the app throw away) again, oldest first, after the urgent prompt: into
/// the app's queue while it works on that one. The first failure stops it.
pub fn requeueDropped(arena: std.mem.Allocator, e: *Entry, dropped: []const Prompt, deadline: i64) !Requeued {
    for (dropped, 0..) |p, i| switch (try submitPrompt(arena, e, p, deadline, false)) {
        .ok => {},
        .fail => |f| return .{ .done = dropped[0..i], .fail = f, .left = dropped.len - i },
    };
    return .{ .done = dropped };
}

/// Put `text` in as the agent's next prompt, or into its app's queue
/// while it works (unless `no_queue`); `ok` says whether it was queued.
/// The recipe's keys get at least `STEP_WAIT_MS` to land even when the
/// caller does not wait for the turn.
pub fn submitPrompt(arena: std.mem.Allocator, e: *Entry, p: Prompt, deadline: i64, no_queue: bool) !Submitted {
    const text = p.text;
    // The caller's own prompt starts a new job: a new retry budget.
    if (!state.retry_busy) e.retry.newPrompt();
    _ = waitReady(e, deadline);
    // A busy agent's app queues the prompt for its next turn, when it can.
    const queued = !no_queue and e.agent.state().queuesPrompt() and e.agent.supports(.queue);
    switch (e.agent.driver()) {
        .screen => |d| if (d.sideOpen()) return .{ .fail = .{ .code = .conflict, .msg = try std.fmt.allocPrint(arena, "agent {s} shows a side-question panel, which has the keyboard; nothing was sent (it closes with Escape in its session)", .{e.id}) } },
        .opencode_api => {},
    }
    if (queued) {
        if (try queueRefusal(arena, e)) |f| return .{ .fail = f };
    } else if (try busy(arena, e)) |f| return .{ .fail = f };
    const act_deadline = @max(deadline, clock.nowMs() + STEP_WAIT_MS);
    const from = e.agent.queue().next_seq;
    const before = e.agent.uptake();
    switch (try act(arena, e, if (queued) .{ .queue = text } else .{ .submit = text }, act_deadline)) {
        .fail => |f| return .{ .fail = f },
        .ok => {},
    }
    if (queued) if (try confirmQueued(arena, e, act_deadline)) |f| return .{ .fail = f };
    if (try confirmDelivery(arena, e, before, queued)) |f| return .{ .fail = f };
    e.sent_seq = from;
    if (queued) rememberQueued(e, p);
    // The conversation has a turn now: a relaunch resumes it.
    if (!e.conversed) {
        e.conversed = true;
        writeDescriptor(e);
    }
    return .{ .ok = queued };
}

/// Keep `p`, which the app now holds queued, for `stopForSend` to retype
/// should an interrupt throw the queue away. Best effort: a prompt that
/// cannot be kept is only not retyped.
fn rememberQueued(e: *Entry, p: Prompt) void {
    const a = e.allocator;
    const text = a.dupe(u8, p.text) catch return;
    const tpl: ?[]u8 = if (p.template) |t| (a.dupe(u8, t) catch {
        a.free(text);
        return;
    }) else null;
    e.queued_sent.append(a, .{ .text = text, .template = tpl }) catch (QueuedPrompt{ .text = text, .template = tpl }).free(a);
}

/// A screen app showed it took the prompt typed at `before`
/// (`agent_mod.Uptake.tookBy`); `not_delivered`, with its state and screen,
/// when nothing shows within `DELIVERY_CONFIRM_MS`. Never retyped: a late
/// uptake would submit it twice. An API source's HTTP acceptance (a 2xx,
/// else `act` failed) is the app's own evidence.
fn confirmDelivery(arena: std.mem.Allocator, e: *Entry, before: agent_mod.Uptake, queued: bool) !?Fail {
    if (e.agent.kind() != .screen) return null;
    const until = clock.nowMs() + DELIVERY_CONFIRM_MS;
    service(clock.nowMs());
    while (!before.tookBy(e.agent.uptake(), e.agent.state(), queued)) {
        if (gone(e) or clock.nowMs() >= until) return Fail{ .code = .not_delivered, .msg = try std.fmt.allocPrint(arena, "agent {s} did not take the prompt: no turn started, no user record{s} within {d} ms after it was typed (state {s}); it is NOT delivered and was not typed again (a late uptake would submit it twice): look at the agent (agent_list, or watch its session) before sending again; the screen shows:\n{s}", .{
            e.id, if (queued) " and no queue preview" else "", DELIVERY_CONFIRM_MS, @tagName(e.agent.state()), try screenTail(arena, e),
        }) };
        pump(until - clock.nowMs());
    }
    return null;
}

/// A failed send as its error result: `not_delivered` carries the agent,
/// its state and the bound as details.
pub fn sendFailRes(arena: std.mem.Allocator, e: *Entry, f: Fail) ![]const u8 {
    if (f.code != .not_delivered) return errRes(arena, f.code, f.msg);
    return mcp.errResDetails(arena, f.code, f.msg, @as(?struct { agent: []const u8, state: []const u8, waited_ms: i64 }, .{
        .agent = e.id,
        .state = @tagName(e.agent.state()),
        .waited_ms = DELIVERY_CONFIRM_MS,
    }));
}

/// What agent_send `interrupt` did to one agent before its prompt.
pub const Stopped = struct {
    interrupted: bool = false,
    /// Prompts the app held queued that the interrupt discarded.
    queued_dropped: u32 = 0,
    /// The ones of them THIS server had typed, oldest first: `requeue`
    /// types them again behind the urgent prompt (owned by the call's arena).
    dropped_sent: []const Prompt = &.{},
    fail: ?Fail = null,
};

/// Whether `interrupt` must stop `e` before a prompt can go in as a new
/// one: it works, or a prompt waits on the user.
fn needsInterrupt(e: *Entry) bool {
    const st = e.agent.state();
    return st.queuesPrompt() or st == .waiting_user;
}

/// agent_send `interrupt`: interrupt every busy one of `list` at once, then
/// wait (bounded, `STEP_WAIT_MS`) until each takes a prompt; one that does
/// not gets a failure, never a prompt queued behind its turn.
pub fn stopForSend(arena: std.mem.Allocator, list: []const *Entry, out: []Stopped) !void {
    for (list, out) |e, *o| {
        o.* = .{};
        if (!needsInterrupt(e)) continue;
        o.queued_dropped = e.agent.queuedPrompts();
        const mine = try arena.alloc(Prompt, e.queued_sent.items.len);
        for (e.queued_sent.items, mine) |q, *m| m.* = .{ .text = try arena.dupe(u8, q.text), .template = if (q.template) |t| try arena.dupe(u8, t) else null };
        o.dropped_sent = mine;
        switch (try act(arena, e, .interrupt, clock.nowMs() + STEP_WAIT_MS)) {
            .fail => |f| o.fail = f,
            .ok => o.interrupted = true,
        }
    }
    const until = clock.nowMs() + STEP_WAIT_MS;
    while (true) {
        service(clock.nowMs());
        var waiting = false;
        for (list, out) |e, o| {
            if (o.interrupted and !e.agent.state().takesPrompt() and !gone(e)) waiting = true;
        }
        if (!waiting or clock.nowMs() >= until) break;
        pump(until - clock.nowMs());
    }
    for (list, out) |e, *o| {
        if (!o.interrupted) {
            o.dropped_sent = &.{};
            continue;
        }
        o.queued_dropped -|= e.agent.queuedPrompts();
        // Only an app that let its whole queue go dropped sketerm's prompts
        // (`service` then forgets them on its own).
        if (e.agent.queuedPrompts() != 0) o.dropped_sent = &.{};
        const st = e.agent.state();
        if (!st.takesPrompt()) o.fail = .{ .code = .timeout, .msg = try std.fmt.allocPrint(arena, "agent {s} was interrupted but did not become idle within {d} ms (state {s}); nothing was sent{s}", .{
            e.id, STEP_WAIT_MS, @tagName(st), if (o.dropped_sent.len > 0) try std.fmt.allocPrint(arena, ", and the {d} prompt(s) this server had queued that its app dropped were not typed again", .{o.dropped_sent.len}) else "",
        }) };
    }
}

/// Why a prompt cannot be typed into a busy screen app's queue now, or
/// null: the input box must show and be empty (a human may be typing).
fn queueRefusal(arena: std.mem.Allocator, e: *Entry) !?Fail {
    const d = switch (e.agent.driver()) {
        .screen => |d| d,
        .opencode_api => return null,
    };
    service(clock.nowMs());
    if (!d.inputShowing())
        return Fail{ .code = .timeout, .msg = try std.fmt.allocPrint(arena, "agent {s} is busy and its input box is not showing; nothing was sent", .{e.id}) };
    if (!d.inputEmpty())
        return Fail{ .code = .conflict, .msg = try std.fmt.allocPrint(arena, "agent {s} is busy and its input box holds text someone is typing; nothing was sent (it would merge with theirs)", .{e.id}) };
    return null;
}

/// A screen app took the queued prompt out of its input box; the failure
/// when it is still there (bounded), saying what the screen shows.
fn confirmQueued(arena: std.mem.Allocator, e: *Entry, deadline: i64) !?Fail {
    const d = switch (e.agent.driver()) {
        .screen => |d| d,
        .opencode_api => return null,
    };
    const until = @min(deadline, clock.nowMs() + STEP_WAIT_MS);
    service(clock.nowMs());
    while (!d.inputEmpty()) {
        if (gone(e) or clock.nowMs() >= until)
            return Fail{ .code = .timeout, .msg = try std.fmt.allocPrint(arena, "the app did not take the queued prompt: it is still in the input box; the screen shows:\n{s}", .{try screenTail(arena, e)}) };
        pump(until - clock.nowMs());
    }
    return null;
}

/// The wait that follows an action, combined with what was pending
/// before it.
pub fn waitAfter(arena: std.mem.Allocator, e: *Entry, pre: ?events.Delivery, filter: events.Filter, deadline: i64) !Delivered {
    const post = try waitDelivery(e, filter, deadline, arena);
    return combine(arena, pre, post, true, post == null and !gone(e));
}

/// What an action came to.
const Acted = union(enum) {
    ok: Outcome,
    fail: Fail,
};

const Outcome = struct {
    /// The app's line confirming the action (a recipe's `confirm`).
    confirmation: ?[]const u8 = null,
    /// The app was restarted with the change (a recipe's `relaunch`).
    relaunched: bool = false,
    /// A side question's answer (a recipe's `wait: side_answer`), owned by
    /// the call's arena.
    answer: ?[]const u8 = null,
    /// A recipe's `close_side` closed the panel (false: it still shows).
    side_closed: ?bool = null,
};

/// Take `action` through the agent's source: an API call, or the
/// adapter's recipe run against the terminal.
pub fn act(arena: std.mem.Allocator, e: *Entry, action: agent_mod.Action, deadline: i64) anyerror!Acted {
    e.acting += 1;
    defer e.acting -= 1;
    // A prompt or an answer starts what the resumed app does next: from
    // here on what it shows is news.
    switch (action) {
        .submit, .queue, .answer, .answer_text => closeHistory(e),
        // A side question leaves no trace in the conversation.
        .interrupt, .set_model, .set_effort, .side_question => {},
    }
    switch (e.agent.driver()) {
        .opencode_api => |d| {
            d.perform(action) catch |err| return .{ .fail = try apiFail(arena, d.api, err) };
            return .{ .ok = .{} };
        },
        .screen => |d| {
            var plan = d.plan(state.allocator, action) catch |err| switch (err) {
                error.Unsupported => return .{ .fail = .{ .code = .refused, .msg = try std.fmt.allocPrint(arena, "the {s} adapter has no recipe for {s}", .{ e.loaded.spec.id, @tagName(std.meta.activeTag(action)) }) } },
                else => return err,
            };
            defer plan.deinit();
            return runSteps(arena, e, action, plan.steps, deadline);
        },
    }
}

/// A setting through `act`; the failure, if any (agent_open's notes).
pub fn applySet(arena: std.mem.Allocator, e: *Entry, action: agent_mod.Action, deadline: i64) !?Fail {
    return switch (try act(arena, e, action, deadline)) {
        .ok => |o| blk: {
            try noteSetting(arena, e, action, o);
            break :blk null;
        },
        .fail => |f| f,
    };
}

fn apiFail(arena: std.mem.Allocator, api: *opencode.Api, err: anyerror) !Fail {
    const code: mcp.ErrCode = switch (err) {
        error.UnknownModel, error.AmbiguousModel, error.UnknownEffort, error.NoCurrentModel, error.NoSuchOption, error.NoFreeText => .invalid_args,
        error.NoPendingInteraction => .conflict,
        error.NoSession => .unavailable,
        error.OutOfMemory => return err,
        else => .failed,
    };
    const why = if (api.problem().len > 0) api.problem() else @errorName(err);
    return .{ .code = code, .msg = try arena.dupe(u8, why) };
}

/// One recipe run's state the failure path needs.
const Run = struct {
    /// The adapter command typed last (`confirm` looks below it).
    command: ?[]const u8 = null,
    /// The text typed last (`wait: side_asked` looks for it in the panel).
    typed: ?[]const u8 = null,
};

/// Run recipe `steps` (of `action`, or the exit recipe for null) against
/// the agent's terminal. A command recipe that fails is cleaned up: the
/// picker it opened is cancelled, and announced if it will not go.
fn runSteps(arena: std.mem.Allocator, e: *Entry, action: ?agent_mod.Action, steps: []const adapter.Step, deadline: i64) anyerror!Acted {
    var run: Run = .{};
    const result = try runStepsIn(arena, e, action, steps, deadline, &run);
    const eng = &e.agent.source.screen;
    // A recipe that fails with the side panel it opened still showing
    // closes it (its close_side keys are safe exactly then): a panel left
    // open would take every key typed at the agent afterwards.
    if (result == .fail and eng.sideOpen() and e.visibleTerm() != null) {
        for (steps) |st| if (st == .close_side) {
            _ = try runStepsIn(arena, e, action, &.{st}, clock.nowMs() + STEP_WAIT_MS, &run);
        };
    }
    if (run.command != null) {
        if (result == .fail and e.agent.interaction() != null and e.visibleTerm() != null) {
            if (e.loaded.spec.actions.interrupt.len > 0) {
                var cancel = try e.agent.driver().screen.plan(state.allocator, .interrupt);
                defer cancel.deinit();
                _ = try runStepsIn(arena, e, agent_mod.Action.interrupt, cancel.steps, clock.nowMs() + STEP_WAIT_MS, &run);
                pumpFor(INTERRUPT_SETTLE_MS);
            }
        }
        try eng.endCommand(clock.nowMs());
    }
    return result;
}

fn runStepsIn(arena: std.mem.Allocator, e: *Entry, action: ?agent_mod.Action, steps: []const adapter.Step, deadline: i64, run: *Run) anyerror!Acted {
    const d = e.agent.driver().screen;
    const what: []const u8 = if (action) |x| @tagName(std.meta.activeTag(x)) else "exit";
    const gone_fail = Acted{ .fail = .{ .code = .unavailable, .msg = "the agent's terminal is gone" } };
    // The prompt showing now: `wait answered` waits for it to go.
    const asked: ?u64 = if (e.agent.interaction()) |it| it.hash() else null;
    var out: Outcome = .{};
    for (steps) |step| {
        const t = e.visibleTerm() orelse return gone_fail;
        const step_deadline = @min(deadline, clock.nowMs() + STEP_WAIT_MS);
        switch (step) {
            .text => |s| {
                t.sendText(s) catch return gone_fail;
                run.typed = s;
            },
            .command => |s| {
                try d.engine.beginCommand(s);
                run.command = s;
                t.sendText(s) catch return gone_fail;
            },
            .key => |k| t.sendKeys(k) catch |err| return .{ .fail = try keyFail(arena, err, k) },
            .sleep_ms => |ms| pumpFor(ms),
            .clear_input => |ks| {
                service(clock.nowMs());
                if (!d.inputEmpty()) {
                    for (ks) |k| {
                        t.sendKeys(k) catch |err| return .{ .fail = try keyFail(arena, err, k) };
                        pumpFor(50);
                    }
                    pumpFor(CLEAR_SETTLE_MS);
                }
            },
            .close_side => |ks| {
                service(clock.nowMs());
                if (d.sideOpen()) {
                    for (ks) |k| {
                        t.sendKeys(k) catch |err| return .{ .fail = try keyFail(arena, err, k) };
                        pumpFor(50);
                    }
                    const until = clock.nowMs() + STEP_WAIT_MS;
                    while (d.sideOpen() and !gone(e) and clock.nowMs() < until) pump(until - clock.nowMs());
                }
                out.side_closed = !d.sideOpen();
            },
            .wait => |w| switch (w) {
                .side_asked => if (!try waitSideAsked(arena, e, run.typed orelse "")) return .{ .fail = .{
                    .code = .not_delivered,
                    .msg = try std.fmt.allocPrint(arena, "agent {s} did not take the side question: its panel did not show it within {d} ms after it was typed (state {s}); it is NOT delivered and was not typed again; the screen shows:\n{s}", .{ e.id, DELIVERY_CONFIRM_MS, @tagName(e.agent.state()), try screenTail(arena, e) }),
                } },
                .side_answer => out.answer = (try waitSideAnswer(arena, e, run.typed orelse "", if (w.stepBounded()) step_deadline else deadline)) orelse return .{ .fail = .{
                    .code = .timeout,
                    .msg = try std.fmt.allocPrint(arena, "agent {s} took the side question but showed no settled answer in time; the screen shows:\n{s}", .{ e.id, try screenTail(arena, e) }),
                } },
                .ready, .choice, .idle, .answered => if (!waitStep(e, w, asked, if (w.stepBounded()) step_deadline else deadline))
                    return .{ .fail = .{ .code = .timeout, .msg = try std.fmt.allocPrint(arena, "the agent did not become {s} while running its {s} recipe; the screen shows:\n{s}", .{ @tagName(w), what, try screenTail(arena, e) }) } },
            },
            .pick => |choice| {
                service(clock.nowMs());
                var nb: [16]u8 = undefined;
                const keys = d.pickKeys(choice, &nb) catch |err| return .{ .fail = try pickFail(arena, e, choice, err) };
                t.sendText(keys) catch return gone_fail;
            },
            .confirm => |r| {
                const m = try adapter.compileLine(arena, r);
                out.confirmation = (try waitConfirm(arena, e, m, run.command.?, step_deadline)) orelse
                    return .{ .fail = .{ .code = .timeout, .msg = try std.fmt.allocPrint(arena, "the app did not confirm {s}: no confirmation below `{s}` within {d} ms, so the change may not have taken effect; the screen shows:\n{s}", .{ what, run.command.?, STEP_WAIT_MS, try screenTail(arena, e) }) } };
            },
            .relaunch => return relaunch(arena, e, action orelse return gone_fail, deadline),
        }
    }
    return .{ .ok = out };
}

/// Wait until no interaction shows and the app printed a line matching
/// `rule` below `command`, then (still bounded) until the agent is idle
/// again, so the next call is not refused as busy; the line (owned by
/// `arena`), or null when it never showed.
fn waitConfirm(arena: std.mem.Allocator, e: *Entry, rule: adapter.Matcher, command: []const u8, deadline: i64) !?[]const u8 {
    const eng = &e.agent.source.screen;
    service(clock.nowMs());
    var seen: ?[]const u8 = null;
    while (true) {
        if (seen == null and e.agent.interaction() == null) {
            if (eng.confirmLine(rule, command)) |line| seen = try arena.dupe(u8, line);
        }
        if (seen != null and e.agent.state() == .idle) return seen;
        if (gone(e) or clock.nowMs() >= deadline) return seen;
        pump(deadline - clock.nowMs());
    }
}

/// The last lines of the agent's terminal, for a failure that must say
/// what the app shows.
fn screenTail(arena: std.mem.Allocator, e: *Entry) ![]const u8 {
    const t = e.visibleTerm() orelse return "(no terminal)";
    const text = t.readScreen(false) catch return "(the screen could not be read)";
    defer t.allocator.free(text);
    return arena.dupe(u8, mcp.tailLines(std.mem.trimEnd(u8, text, "\n "), 12));
}

/// Restart a screen app with `action`'s value as a launch value (the
/// effort Claude Code only takes at launch: its /effort saves the user's
/// default), in the same session, resuming its conversation.
fn relaunch(arena: std.mem.Allocator, e: *Entry, action: agent_mod.Action, deadline: i64) anyerror!Acted {
    const old = switch (e.visible orelse return .{ .fail = .{ .code = .unavailable, .msg = "the agent's terminal is gone" } }) {
        .owned => |t| t,
        .borrowed => return .{ .fail = .{ .code = .refused, .msg = "this agent runs on a term_open terminal (agent_attach): it cannot be restarted with new launch settings; agent_open it instead" } },
    };
    var model: ?[]const u8 = e.launch_model;
    var effort: ?[]const u8 = e.launch_effort;
    switch (action) {
        .set_effort => |x| effort = x,
        .set_model => |x| model = x,
        .submit, .queue, .answer, .answer_text, .interrupt, .side_question => return .{ .fail = .{ .code = .refused, .msg = "the adapter relaunches for an action that is no launch value" } },
    }
    // A conversation with a turn is resumed; an empty one starts afresh
    // under a new id (the old id may already be taken by the app).
    const resumed = e.conversed and e.conversation != null;
    const conversation: ?[]const u8 = if (resumed) e.conversation else if (e.conversation != null) try newUuid(arena) else null;

    // 1. End the app the way a user would, then make sure it is gone.
    e.relaunching = true;
    defer e.relaunching = false;
    var exit_plan = try e.agent.driver().screen.exitPlan(state.allocator);
    defer exit_plan.deinit();
    _ = try runSteps(arena, e, null, exit_plan.steps, clock.nowMs() + STEP_WAIT_MS);
    const exit_until = clock.nowMs() + EXIT_WAIT_MS;
    while (!old.exited and clock.nowMs() < exit_until) {
        old.drain();
        if (!old.exited) _ = old.pumpOnce(100);
    }
    const ended = old.exited;
    e.visible = null;
    if (ended) old.detach() else old.deinit();

    // 2. Start it again in the same session name, with every launch value.
    const new_t = startAgain(arena, e, model, effort, conversation, if (resumed) .resumed else .fresh, deadline) catch |err| switch (err) {
        error.Refused => return .{ .fail = .{ .code = .failed, .msg = try std.fmt.allocPrint(arena, "the app was ended to apply the change and could not be started again; agent_close it and agent_open a new one", .{}) } },
        else => return err,
    };
    e.visible = .{ .owned = new_t };
    e.seen_snapshots = new_t.snapshots;
    e.agent.source.screen.noteRestart();
    e.relaunches += 1;
    const cast_name = try std.fmt.allocPrint(arena, "{s}-r{d}", .{ e.session, e.relaunches });
    record(e, new_t, cast_name);
    if (conversation) |cv| if (!resumed) {
        if (e.conversation) |prev| e.allocator.free(prev);
        e.conversation = try e.allocator.dupe(u8, cv);
    };
    try replaceOwned(e, &e.launch_model, model);
    try replaceOwned(e, &e.launch_effort, effort);
    e.relaunching = false;
    writeDescriptor(e);
    publishAgents();

    // 3. It is back once its input box shows again.
    if (!waitReady(e, deadline))
        return .{ .fail = .{ .code = .timeout, .msg = try std.fmt.allocPrint(arena, "the app was restarted with the new setting but did not become ready in time; the screen shows:\n{s}", .{try screenTail(arena, e)}) } };
    // A model chosen in the app since the launch is not a launch value.
    if (e.picked_model) |m| if (action != .set_model) {
        const again = try arena.dupe(u8, m);
        switch (try act(arena, e, .{ .set_model = again }, deadline)) {
            .ok => {},
            .fail => |f| return .{ .fail = .{ .code = f.code, .msg = try std.fmt.allocPrint(arena, "restarted with the new setting, but the model chosen before ({s}) could not be chosen again: {s}", .{ again, f.msg }) } },
        }
    };
    return .{ .ok = .{ .relaunched = true } };
}

/// What a relaunch of `e` spawns: its binary with every launch value,
/// the caller's `args`/`env` included.
const Restart = struct { argv: []const []const u8, spec: SpawnSpec };

pub fn restartOf(arena: std.mem.Allocator, e: *const Entry, model: ?[]const u8, effort: ?[]const u8, conversation: ?[]const u8, start: launch.Start) !Restart {
    const x = try launch.applySettings(arena, &e.loaded.spec, e.extra, try statusOf(arena, e.loaded, e.facts_file, e.status_user));
    return .{
        .argv = try launch.startArgv(arena, e.loaded.spec.launch, e.binary, x, .{
            .model = model,
            .effort = effort,
            .cwd = e.cwd,
            .session = conversation,
        }, .{ .main = start }),
        .spec = .{ .name = e.session, .cwd = e.cwd, .extra = x, .title = e.name orelse "" },
    };
}

/// Spawn the agent's app again on its host as its session, for a relaunch.
fn startAgain(arena: std.mem.Allocator, e: *Entry, model: ?[]const u8, effort: ?[]const u8, conversation: ?[]const u8, start: launch.Start, deadline: i64) !*termdrive.Term {
    const r = try restartOf(arena, e, model, effort, conversation, start);
    var where = e.where();
    var why: Fail = undefined;
    // The ended session may hold its name a moment longer.
    const until = @min(deadline, clock.nowMs() + EXIT_WAIT_MS);
    while (true) {
        if (spawnOn(arena, &where, .auto, r.argv, r.spec, &why)) |t| return t else |err| {
            if (err != error.Refused or clock.nowMs() >= until) return err;
        }
        pumpFor(200);
    }
}

fn replaceOwned(e: *Entry, slot: *?[]u8, value: ?[]const u8) !void {
    const fresh: ?[]u8 = if (value) |v| try e.allocator.dupe(u8, v) else null;
    if (slot.*) |old| e.allocator.free(old);
    slot.* = fresh;
}

/// A setting the app took: what the adapter did goes into the transcript
/// as a notice (the app's own echo of an adapter command is hidden), and
/// a model chosen in the app is kept for a later relaunch.
pub fn noteSetting(arena: std.mem.Allocator, e: *Entry, action: agent_mod.Action, o: Outcome) !void {
    switch (e.agent.source) {
        .screen => |*eng| {
            const text = switch (action) {
                .set_model => |m| blk: {
                    if (!o.relaunched) try replaceOwned(e, &e.picked_model, m);
                    break :blk try std.fmt.allocPrint(arena, "model set to {s} for this session{s}{s}", .{ m, if (o.confirmation != null) ": " else "", o.confirmation orelse "" });
                },
                .set_effort => |x| try std.fmt.allocPrint(arena, "effort set to {s} for this session{s}", .{ x, if (o.relaunched) " (the app was restarted with it and the conversation resumed)" else "" }),
                .submit, .queue, .answer, .answer_text, .interrupt, .side_question => return,
            };
            try eng.addNotice(text);
            writeDescriptor(e);
        },
        .opencode_api => {},
    }
}

fn keyFail(arena: std.mem.Allocator, err: anyerror, key: []const u8) !Fail {
    if (err == error.BadKey) return .{ .code = .failed, .msg = try std.fmt.allocPrint(arena, "the adapter names an unknown key '{s}'", .{key}) };
    return .{ .code = .unavailable, .msg = "the agent's terminal is gone" };
}

fn pickFail(arena: std.mem.Allocator, e: *Entry, choice: []const u8, err: anyerror) !Fail {
    if (err == error.NoPendingInteraction) return .{ .code = .conflict, .msg = try std.fmt.allocPrint(arena, "agent {s} shows no prompt to answer", .{e.id}) };
    return .{ .code = .invalid_args, .msg = try std.fmt.allocPrint(arena, "'{s}' names none of the options ({s})", .{ choice, try optionList(arena, e.agent.interaction()) }) };
}

pub fn optionList(arena: std.mem.Allocator, it: ?output.Interaction) ![]const u8 {
    const x = it orelse return "none";
    var out: std.ArrayList(u8) = .empty;
    for (x.options, 1..) |o, n| {
        if (n > 1) try out.appendSlice(arena, ", ");
        try out.print(arena, "{d}. {s}", .{ n, o.label });
    }
    return out.items;
}

/// A prompt typed again after an interrupt, as results list it: its text,
/// or for a rendered template only the template's name.
pub const RequeuedItem = struct { text: ?[]const u8 = null, template: ?[]const u8 = null };

/// A prompt that went in (queued or not), or why not.
pub const Submitted = union(enum) { ok: bool, fail: Fail };
