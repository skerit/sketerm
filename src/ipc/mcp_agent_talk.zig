//! The `agent_*` tools on a running agent: send (one or several), wait
//! (one, any, all), answer, set, interrupt, ask, read, list and close.

const std = @import("std");
const mcp = @import("mcp.zig");
const agentwait = @import("agentwait.zig");
const agent_mod = @import("../agent/agent.zig");
const events = @import("../agent/events.zig");
const vocab = @import("../agent/vocab.zig");
const select = @import("../agent/select.zig");
const launch = @import("../agent/launch.zig");
const opencode = @import("../agent/opencode.zig");
const output = @import("../agent/output.zig");
const retry_mod = @import("../agent/retry.zig");
const clock = @import("../util/clock.zig");
const agentindex = @import("agentindex.zig");
const Res = mcp.Res;
const errRes = mcp.errRes;
const argStr = mcp.argStr;
const argInt = mcp.argInt;
const argBool = mcp.argBool;

const mcp_agent = @import("mcp_agent.zig");
const mcp_agent_hosts = @import("mcp_agent_hosts.zig");
const mcp_agent_results = @import("mcp_agent_results.zig");
const mcp_agent_waiter = @import("mcp_agent_waiter.zig");
const mcp_agent_index = @import("mcp_agent_index.zig");
const mcp_agent_act = @import("mcp_agent_act.zig");
const mcp_agent_open = @import("mcp_agent_open.zig");
const mcp_agent_loop = @import("mcp_agent_loop.zig");

const DEFAULT_WAIT_MS = mcp_agent.DEFAULT_WAIT_MS;
const INTERRUPT_SETTLE_MS = mcp_agent.INTERRUPT_SETTLE_MS;
const Entry = mcp_agent.Entry;
const MAX_ANY = mcp_agent.MAX_ANY;
const hold = mcp_agent.hold;
const state = &mcp_agent.state;
const findByName = mcp_agent.findByName;
const lockPath = mcp_agent.lockPath;
const Fail = mcp_agent.Fail;
const idList = mcp_agent.idList;
const filterFrom = mcp_agent.filterFrom;
const deadlineFrom = mcp_agent.deadlineFrom;
const HOST_LIST_WAIT_MS = mcp_agent_hosts.HOST_LIST_WAIT_MS;
const readHosts = mcp_agent_hosts.readHosts;
const hostsReport = mcp_agent_hosts.hostsReport;
const factsOf = mcp_agent_hosts.factsOf;
const Block = mcp_agent_results.Block;
const combine = mcp_agent_results.combine;
const pending = mcp_agent_results.pending;
const outcomeOf = mcp_agent_results.outcomeOf;
const EventJson = mcp_agent_results.EventJson;
const toJson = mcp_agent_results.toJson;
const finish = mcp_agent_results.finish;
const conversationOf = mcp_agent_results.conversationOf;
const permissionsValue = mcp_agent_results.permissionsValue;
const relaunchableOf = mcp_agent_results.relaunchableOf;
const block = mcp_agent_results.block;
const eventsJson = mcp_agent_results.eventsJson;
const isoAt = mcp_agent_results.isoAt;
const writeSelection = mcp_agent_results.writeSelection;
const pushing = mcp_agent_waiter.pushing;
const rememberFilter = mcp_agent_waiter.rememberFilter;
const writeDescriptor = mcp_agent_index.writeDescriptor;
const busy = mcp_agent_act.busy;
const Prompt = mcp_agent_act.Prompt;
const refuse = mcp_agent_act.refuse;
const promptFrom = mcp_agent_act.promptFrom;
const submitAndWait = mcp_agent_act.submitAndWait;
const Requeued = mcp_agent_act.Requeued;
const requeueDropped = mcp_agent_act.requeueDropped;
const submitPrompt = mcp_agent_act.submitPrompt;
const sendFailRes = mcp_agent_act.sendFailRes;
const Stopped = mcp_agent_act.Stopped;
const stopForSend = mcp_agent_act.stopForSend;
const waitAfter = mcp_agent_act.waitAfter;
const act = mcp_agent_act.act;
const noteSetting = mcp_agent_act.noteSetting;
const optionList = mcp_agent_act.optionList;
const RequeuedItem = mcp_agent_act.RequeuedItem;
const Submitted = mcp_agent_act.Submitted;
const retryPolicyFrom = mcp_agent_open.retryPolicyFrom;
const stallFrom = mcp_agent_open.stallFrom;
const setRetryPolicy = mcp_agent_open.setRetryPolicy;
const effortRefusal = mcp_agent_open.effortRefusal;
const discard = mcp_agent_open.discard;
const service = mcp_agent_loop.service;
const reconnectIfLost = mcp_agent_loop.reconnectIfLost;
const pump = mcp_agent_loop.pump;
const pumpFor = mcp_agent_loop.pumpFor;
const gone = mcp_agent_loop.gone;
const waitReady = mcp_agent_loop.waitReady;
const waitAny = mcp_agent_loop.waitAny;
const settleOf = mcp_agent_loop.settleOf;
const settledOf = mcp_agent_loop.settledOf;

/// Records one agent_read returns by default, and at most.
const READ_DEFAULT: usize = 100;
const READ_MAX: usize = 500;
/// agent_read detail "activity": tool calls listed by default, and at most.
const ACTIVITY_DEFAULT: usize = 10;
const ACTIVITY_MAX: usize = 50;

// ── agent_send / agent_wait / agent_answer / agent_set / ... ─────

/// agent_send's `text`, or why it is refused.
/// agent_send's prompt: `text` and/or `template`.
fn sendPrompt(arena: std.mem.Allocator, args: std.json.Value, why: *Fail) !Prompt {
    return (try promptFrom(arena, args, "text", why)) orelse refuse(why, .invalid_args, "agent_send needs 'text' or 'template'");
}

pub fn sendTool(arena: std.mem.Allocator, args: std.json.Value, e: *Entry) ![]const u8 {
    var why: Fail = undefined;
    const text = sendPrompt(arena, args, &why) catch |err| switch (err) {
        error.Refused => return errRes(arena, why.code, why.msg),
        else => return err,
    };
    const filter = filterFrom(args);
    const interrupt = argBool(args, "interrupt");
    var stop = [1]Stopped{.{}};
    if (interrupt) {
        const one = [1]*Entry{e};
        try stopForSend(arena, &one, &stop);
        if (stop[0].fail) |f| return errRes(arena, f.code, f.msg);
    }
    var requeued: Requeued = .{};
    switch (try submitAndWait(arena, e, text, filter, deadlineFrom(args, DEFAULT_WAIT_MS), interrupt, stop[0].dropped_sent, &requeued)) {
        .fail => |f| return sendFailRes(arena, e, f),
        .ok => |dv| {
            var res = Res.init(arena);
            try requeued.report(arena, &res);
            const queued = if (dv.wait) |w| w.queued else false;
            try res.fact("queued", queued);
            if (interrupt) try res.fact("interrupted", stop[0].interrupted);
            if (stop[0].queued_dropped > 0) try res.fact("queued_dropped", stop[0].queued_dropped);
            if (stop[0].interrupted) try res.textf("{s} was busy: interrupted it first, then sent the prompt as a new one{s}", .{ e.id, if (stop[0].queued_dropped > 0) " (its app dropped the prompts it held queued)" else "" });
            if (queued) try res.textf("{s} was busy: the prompt went into its queue for its next turn", .{e.id});
            return finish(arena, &res, e, dv, .{ .filter = filter, .template = text.template }, &.{});
        },
    }
}

/// One agent's line of a multi-agent agent_send.
const SendResult = struct {
    agent: []const u8,
    name: ?[]const u8 = null,
    /// sent, queued, still_working (`outcomeOf`), or failed.
    outcome: []const u8 = "failed",
    state: ?[]const u8 = null,
    queued: bool = false,
    interrupted: bool = false,
    queued_dropped: ?u32 = null,
    /// The prompts this server had queued that the interrupt made the app
    /// drop, queued again behind this one (`requeueDropped`).
    requeued: ?[]const RequeuedItem = null,
    requeue_failed: ?struct { code: []const u8, message: []const u8, not_requeued: usize } = null,
    /// Events no result had handed out, taken with the send.
    events: ?[]const EventJson = null,
    @"error": ?struct { code: []const u8, message: []const u8 } = null,
};

/// agent_send with `agents`: the same prompt to each (interrupting the busy
/// ones first with `interrupt`), one result per agent; a failure is that
/// agent's, never the call's. It does not wait for the turns.
pub fn sendManyTool(arena: std.mem.Allocator, args: std.json.Value, list: []const std.json.Value) ![]const u8 {
    var why: Fail = undefined;
    const text = sendPrompt(arena, args, &why) catch |err| switch (err) {
        error.Refused => return errRes(arena, why.code, why.msg),
        else => return err,
    };
    if (list.len == 0) return errRes(arena, .invalid_args, "agents is empty: name at least one agent");
    if (list.len > MAX_ANY) return errRes(arena, .invalid_args, try std.fmt.allocPrint(arena, "agents names at most {d} agents", .{MAX_ANY}));
    const interrupt = argBool(args, "interrupt");
    const deadline = deadlineFrom(args, DEFAULT_WAIT_MS);
    var results: std.ArrayList(SendResult) = .empty;
    var entries: std.ArrayList(*Entry) = .empty;
    var slots: std.ArrayList(usize) = .empty;
    for (list) |v| {
        if (v != .string) {
            try results.append(arena, .{ .agent = "", .@"error" = .{ .code = @tagName(mcp.ErrCode.invalid_args), .message = "not an agent id or name (a string)" } });
            continue;
        }
        const e = findByName(v.string) orelse {
            try results.append(arena, .{ .agent = v.string, .@"error" = .{ .code = @tagName(mcp.ErrCode.not_found), .message = try std.fmt.allocPrint(arena, "no agent '{s}' on this server (open: {s})", .{ v.string, try idList(arena) }) } });
            continue;
        };
        if (std.mem.indexOfScalar(*Entry, entries.items, e) != null) continue;
        hold(e);
        try entries.append(arena, e);
        try slots.append(arena, results.items.len);
        try results.append(arena, .{ .agent = e.id, .name = e.name });
    }
    for (entries.items) |e| reconnectIfLost(e);
    service(clock.nowMs());
    const stops = try arena.alloc(Stopped, entries.items.len);
    @memset(stops, .{});
    if (interrupt) try stopForSend(arena, entries.items, stops);
    var sent: std.ArrayList([]const u8) = .empty;
    for (entries.items, slots.items, stops) |e, slot, stop| {
        const r = &results.items[slot];
        r.interrupted = stop.interrupted;
        if (stop.queued_dropped > 0) r.queued_dropped = stop.queued_dropped;
        // What no result handed out yet rides with this agent's line.
        if (try e.cursor.take(e.agent.queue(), .{}, clock.nowMs(), arena)) |d| r.events = try eventsJson(arena, d.items);
        const outcome = if (stop.fail) |f| Submitted{ .fail = f } else try submitPrompt(arena, e, text, deadline, interrupt);
        switch (outcome) {
            .fail => {},
            .ok => {
                const rq = try requeueDropped(arena, e, stop.dropped_sent, deadline);
                if (rq.done.len > 0) r.requeued = try rq.items(arena);
                if (rq.fail) |f| r.requeue_failed = .{ .code = @tagName(f.code), .message = f.msg, .not_requeued = rq.left };
            },
        }
        r.state = @tagName(e.agent.state());
        switch (outcome) {
            .fail => |f| r.@"error" = .{ .code = @tagName(f.code), .message = f.msg },
            .ok => |queued| {
                r.queued = queued;
                r.outcome = outcomeOf(&.{}, e.agent.state(), true, queued and e.agent.queuedPrompts() > 0);
                rememberFilter(e, .{});
                try sent.append(arena, e.id);
            },
        }
    }

    var res = Res.init(arena);
    const failed = results.items.len - sent.items.len;
    try res.textf("sent to {d} of {d} agent(s){s}", .{ sent.items.len, results.items.len, if (interrupt) ", the busy ones interrupted first" else "" });
    var ids: std.ArrayList([]const u8) = .empty;
    for (entries.items) |e| try ids.append(arena, e.id);
    try res.fact("agents", ids.items);
    try res.raw("results", try toJson(arena, results.items));
    try res.fact("count", results.items.len);
    try res.fact("failed", failed);
    if (text.template) |x| try res.fact("template", x);
    for (results.items) |r| {
        if (r.@"error") |er|
            try res.textf("{s}: failed ({s}): {s}", .{ if (r.agent.len > 0) r.agent else "?", er.code, er.message })
        else
            try res.textf("{s}: {s}{s}{s}", .{ r.agent, r.outcome, if (r.interrupted) " (interrupted first)" else "", if (r.queued_dropped != null) "; its app dropped the prompts it held queued" else "" });
    }
    var cmd: ?[]const u8 = null;
    if (sent.items.len > 0) if (state.exe) |exe| if (state.waiter.path) |sock| {
        cmd = try agentwait.watchCommand(arena, exe, sock, sent.items, .{}, if (sent.items.len > 1) .all else .any);
        try res.fact("watch_command", cmd.?);
    };
    if (sent.items.len > 0) {
        if (pushing())
            try res.text("their events are pushed into this session as they happen, so end your turn here; no watch_command, Monitor or agent_wait is needed")
        else if (sent.items.len > 1)
            try res.text("run watch_command in the background to be woken ONCE when every one of them has settled (agent-wait --all; --any wakes on the first), then agent_read final per agent")
        else
            try res.text("run watch_command in the background to be woken when it has answered");
    }
    if (cmd) |x| try block(&res, .{ .name = "watch_command", .body = x });
    return res.finish();
}

pub fn waitTool(arena: std.mem.Allocator, args: std.json.Value, e: *Entry) ![]const u8 {
    const filter = filterFrom(args);
    const dv = try waitAfter(arena, e, null, filter, deadlineFrom(args, DEFAULT_WAIT_MS));
    var res = Res.init(arena);
    return finish(arena, &res, e, dv, .{ .filter = filter }, &.{});
}

/// agent_wait with `agents`: the first wake-up of any of them; the result
/// is that agent's (the first listed one's when none woke).
/// agent_wait's `agents`, each once, held; or the refusal.
const Waited = struct { entries: []*Entry, ids: []const []const u8 };

fn waitedOf(arena: std.mem.Allocator, list: []const std.json.Value) !union(enum) { ok: Waited, fail: Fail } {
    if (list.len == 0) return .{ .fail = .{ .code = .invalid_args, .msg = "agents is empty: name at least one agent id" } };
    if (list.len > MAX_ANY) return .{ .fail = .{ .code = .invalid_args, .msg = try std.fmt.allocPrint(arena, "agents names at most {d} agents", .{MAX_ANY}) } };
    var entries: std.ArrayList(*Entry) = .empty;
    var ids: std.ArrayList([]const u8) = .empty;
    for (list) |v| {
        if (v != .string) return .{ .fail = .{ .code = .invalid_args, .msg = "agents must be an array of agent ids" } };
        const e = findByName(v.string) orelse
            return .{ .fail = .{ .code = .not_found, .msg = try std.fmt.allocPrint(arena, "no agent '{s}' (open: {s})", .{ v.string, try idList(arena) }) } };
        if (std.mem.indexOfScalar(*Entry, entries.items, e) != null) continue;
        try entries.append(arena, e);
        try ids.append(arena, e.id);
        hold(e);
    }
    for (entries.items) |e| reconnectIfLost(e);
    return .{ .ok = .{ .entries = entries.items, .ids = ids.items } };
}

/// agent_wait `agents` + `all`: wait until every one settled (`settleOf`),
/// then one line each with how it settled, what it delivers marked
/// delivered like a waiter's.
pub fn waitAllTool(arena: std.mem.Allocator, args: std.json.Value, list: []const std.json.Value) ![]const u8 {
    const w = switch (try waitedOf(arena, list)) {
        .fail => |f| return errRes(arena, f.code, f.msg),
        .ok => |x| x,
    };
    const deadline = deadlineFrom(args, DEFAULT_WAIT_MS);
    service(clock.nowMs());
    var settled: usize = 0;
    while (true) {
        settled = 0;
        for (w.entries) |e| {
            if (settleOf(e) != null) settled += 1;
        }
        if (settled == w.entries.len or clock.nowMs() >= deadline) break;
        pump(deadline - clock.nowMs());
    }
    const Item = struct {
        agent: []const u8,
        name: ?[]const u8,
        outcome: []const u8,
        state: []const u8,
        settled: bool,
        text: []const u8,
        record: ?u64,
        conversation: ?[]const u8,
        events: []const EventJson,
    };
    const items = try arena.alloc(Item, w.entries.len);
    const all = settled == w.entries.len;
    var res = Res.init(arena);
    if (all)
        try res.textf("all {d} agent(s) settled", .{w.entries.len})
    else
        try res.textf("{d} of {d} agent(s) settled when the wait ran out", .{ settled, w.entries.len });
    for (w.entries, items) |e, *o| {
        const st = e.agent.state();
        o.* = .{ .agent = e.id, .name = e.name, .outcome = outcomeOf(&.{}, st, e.sent_seq != null, false), .state = @tagName(st), .settled = false, .text = "", .record = null, .conversation = conversationOf(e), .events = &.{} };
        if (settleOf(e)) |s| {
            const line = try settledOf(arena, e, s);
            o.outcome = line.outcome;
            o.text = line.text;
            o.record = line.record;
            o.settled = true;
            if (try e.cursor.take(e.agent.queue(), .{}, clock.nowMs(), arena)) |d| o.events = try eventsJson(arena, d.items);
        }
        try res.textf("{s}: {s}{s}{s}", .{ e.id, o.outcome, if (o.text.len > 0) ": " else "", agentwait.clip(events.firstLine(o.text), 160) });
    }
    try res.fact("agents", w.ids);
    try res.fact("outcome", if (all) @tagName(vocab.WaitOutcome.all_settled) else @tagName(vocab.WaitOutcome.still_working));
    try res.fact("timed_out", !all and !state.no_wait);
    try res.raw("results", try toJson(arena, items));
    if (all) try res.text("agent_read with final: true returns each one's final message whole");
    if (!all and pushing())
        try res.text("their events are pushed into this session as they happen, so end your turn here")
    else if (!all)
        try res.text("run watch_command in the background to be woken once every one of them has settled");
    if (state.exe) |exe| if (state.waiter.path) |sock| {
        const cmd = try agentwait.watchCommand(arena, exe, sock, w.ids, .{}, .all);
        try res.fact("watch_command", cmd);
        try block(&res, .{ .name = "watch_command", .body = cmd });
    };
    return res.finish();
}

pub fn waitAnyTool(arena: std.mem.Allocator, args: std.json.Value, list: []const std.json.Value) ![]const u8 {
    const w = switch (try waitedOf(arena, list)) {
        .fail => |f| return errRes(arena, f.code, f.msg),
        .ok => |x| x,
    };
    const entries = w.entries;
    const ids = w.ids;
    const filter = filterFrom(args);
    const got = try waitAny(entries, filter, deadlineFrom(args, DEFAULT_WAIT_MS), arena);
    const e = if (got) |g| g.entry else entries[0];
    const dv = try combine(arena, null, if (got) |g| g.delivery else null, true, got == null and !gone(e));
    var res = Res.init(arena);
    try res.fact("agents", ids);
    if (got != null) try res.textf("{s} woke first of {d} agent(s)", .{ e.id, ids.len });
    return finish(arena, &res, e, dv, .{ .filter = filter, .any = ids }, &.{});
}

pub fn answerTool(arena: std.mem.Allocator, args: std.json.Value, e: *Entry) ![]const u8 {
    if (argStr(args, "text")) |text| {
        if (argStr(args, "choice") != null) return errRes(arena, .invalid_args, "pass either 'choice' or 'text', not both");
        return answerTextTool(arena, args, e, text);
    }
    const choice = argStr(args, "choice") orelse return errRes(arena, .invalid_args, "agent_answer needs 'choice' (an option label, its 1-based number or a unique part of a label) or 'text' (a free-text answer)");
    const filter = filterFrom(args);
    const deadline = deadlineFrom(args, DEFAULT_WAIT_MS);
    const pre = try e.cursor.take(e.agent.queue(), .{}, clock.nowMs(), arena);
    const it = e.agent.interaction() orelse
        return errRes(arena, .conflict, try std.fmt.allocPrint(arena, "agent {s} has no pending prompt (state {s})", .{ e.id, @tagName(e.agent.state()) }));
    // Copied now: the interaction is gone once answered.
    const kind = it.kind;
    const title = try arena.dupe(u8, it.title);
    const label: []const u8 = switch (e.agent.kind()) {
        .screen => blk: {
            const i = it.pick(choice) orelse return noSuchOption(arena, e, it, choice);
            break :blk try arena.dupe(u8, it.options[i].label);
        },
        .opencode_api => switch (kind) {
            .permission => if (opencode.PermissionReply.fromChoice(it, choice)) |r| r.label() else return noSuchOption(arena, e, it, choice),
            .question => blk: {
                // Checked before acting: the refusal lists every question.
                const qs = e.agent.driver().opencode_api.api.source.pendingRequest().?.questions;
                _ = opencode.questionAnswers(arena, qs, choice) catch |err| switch (err) {
                    error.NoSuchOption => return errRes(arena, .invalid_args, try opencode.questionsHelp(arena, qs, choice)),
                    else => return err,
                };
                break :blk try arena.dupe(u8, choice);
            },
            .choice => try arena.dupe(u8, choice),
        },
    };
    // A prompt before the app is ready (Claude Code's trust dialog): the
    // answer leads to the app getting ready, not to a turn.
    const startup = !e.agent.ready();
    const from = e.agent.queue().next_seq;
    switch (try act(arena, e, .{ .answer = choice }, deadline)) {
        .fail => |f| return errRes(arena, f.code, f.msg),
        .ok => {},
    }
    // The turn goes on: it has not settled until something after this does.
    if (!startup) e.sent_seq = from;
    if (startup) {
        const ready = waitReady(e, deadline);
        var res = Res.init(arena);
        try res.textf("answered the {s} prompt{s}", .{ @tagName(kind), if (ready) "; the agent is ready" else "" });
        try res.fact("answered", label);
        return finish(arena, &res, e, try combine(arena, pre, try e.cursor.take(e.agent.queue(), .{}, clock.nowMs(), arena), false, false), .{ .filter = filter }, &.{.{ .name = "answer", .body = try std.fmt.allocPrint(arena, "{s}\n-> {s}", .{ title, label }) }});
    }
    // A denied call leaves no trace on a screen app: the adapter keeps one.
    if (kind == .permission) switch (e.agent.source) {
        .screen => |*eng| try eng.addNotice(try std.fmt.allocPrint(arena, "permission \"{s}\" answered: {s}", .{ title, label })),
        .opencode_api => {},
    };
    const dv = try waitAfter(arena, e, pre, filter, deadline);
    var res = Res.init(arena);
    try res.textf("answered the {s} prompt", .{@tagName(kind)});
    try res.fact("answered", label);
    const answer = try std.fmt.allocPrint(arena, "{s}\n-> {s}", .{ title, label });
    return finish(arena, &res, e, dv, .{ .filter = filter }, &.{.{ .name = "answer", .body = answer }});
}

/// The refusal of a choice that names no option of `it`.
fn noSuchOption(arena: std.mem.Allocator, e: *Entry, it: output.Interaction, choice: []const u8) ![]const u8 {
    return errRes(arena, .invalid_args, try std.fmt.allocPrint(arena, "'{s}' names none of the options ({s}); answer with {s}", .{ choice, try optionList(arena, it), mcp_agent_act.answerForms(e, it) }));
}

/// agent_answer `text`: a free-text answer through the route the app
/// offers (Claude Code: the option `screen.text_options` names, then the
/// text as its next prompt; opencode: a reject's message, a custom answer).
fn answerTextTool(arena: std.mem.Allocator, args: std.json.Value, e: *Entry, text: []const u8) ![]const u8 {
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return errRes(arena, .invalid_args, "text is empty");
    const filter = filterFrom(args);
    const deadline = deadlineFrom(args, DEFAULT_WAIT_MS);
    const pre = try e.cursor.take(e.agent.queue(), .{}, clock.nowMs(), arena);
    const it = e.agent.interaction() orelse
        return errRes(arena, .conflict, try std.fmt.allocPrint(arena, "agent {s} has no pending prompt (state {s})", .{ e.id, @tagName(e.agent.state()) }));
    // Never a silent pick: no route for text means the caller chooses.
    if (!it.free_text or !e.agent.supports(.answer_text))
        return errRes(arena, .invalid_args, try std.fmt.allocPrint(arena, "this {s} prompt takes no free-text answer; answer with choice, one of: {s}", .{ @tagName(it.kind), try optionList(arena, it) }));
    const kind = it.kind;
    const title = try arena.dupe(u8, it.title);
    const label: []const u8 = switch (e.agent.driver()) {
        .screen => |d| try arena.dupe(u8, d.textOption() orelse
            return errRes(arena, .invalid_args, try std.fmt.allocPrint(arena, "this {s} prompt takes no free-text answer; answer with choice, one of: {s}", .{ @tagName(kind), try optionList(arena, it) }))),
        .opencode_api => if (kind == .permission) opencode.PermissionReply.reject.label() else "free text",
    };
    switch (try act(arena, e, .{ .answer_text = .{ .option = label, .text = text } }, deadline)) {
        .fail => |f| return errRes(arena, f.code, f.msg),
        .ok => {},
    }
    // After the recipe: the turn the option ended settled inside it.
    e.sent_seq = e.agent.queue().next_seq;
    // What the recipe's own steps caused (the turn the option ended going
    // idle) rides along; the wait is for what the text brings.
    const mid = try e.cursor.take(e.agent.queue(), .{}, clock.nowMs(), arena);
    switch (e.agent.source) {
        .screen => |*eng| {
            if (kind == .permission) try eng.addNotice(try std.fmt.allocPrint(arena, "permission \"{s}\" answered: {s}, with a message", .{ title, label }));
            if (!e.conversed) {
                e.conversed = true;
                writeDescriptor(e);
            }
        },
        .opencode_api => {},
    }
    const dv = try waitAfter(arena, e, try joinDeliveries(arena, pre, mid), filter, deadline);
    var res = Res.init(arena);
    try res.textf("answered the {s} prompt with text", .{@tagName(kind)});
    try res.fact("answered", label);
    try res.fact("free_text", true);
    const answer = try std.fmt.allocPrint(arena, "{s}\n-> {s}: {s}", .{ title, label, text });
    return finish(arena, &res, e, dv, .{ .filter = filter }, &.{.{ .name = "answer", .body = answer }});
}

/// Two deliveries as one (oldest first), digests added.
fn joinDeliveries(arena: std.mem.Allocator, a: ?events.Delivery, b: ?events.Delivery) !?events.Delivery {
    const x = a orelse return b;
    const y = b orelse return a;
    const items = try std.mem.concat(arena, events.Item, &.{ x.items, y.items });
    var digest = x.digest;
    if (y.digest) |d| digest = if (digest) |old| .{ .count = old.count + d.count, .latest_seq = d.latest_seq } else d;
    return .{ .items = items, .digest = digest };
}

pub fn setTool(arena: std.mem.Allocator, args: std.json.Value, e: *Entry) ![]const u8 {
    const model = argStr(args, "model");
    const effort = argStr(args, "effort");
    const retry_arg = mcp.argValue(args, "retry_on_overload");
    const stall_arg = mcp.argValue(args, "stall_after_min");
    if (model == null and effort == null and retry_arg == null and stall_arg == null) return errRes(arena, .invalid_args, "agent_set needs 'model', 'effort', 'retry_on_overload' and/or 'stall_after_min'");
    inline for (.{ "model", "effort" }) |key| {
        if (argStr(args, key)) |v| if (!launch.validValue(v)) return errRes(arena, .invalid_args, key ++ " must be 1-256 printable characters");
    }
    // Refused before anything is typed, stopped or restarted.
    if (effort) |x| if (!launch.validEffort(e.loaded.spec.launch, x)) return errRes(arena, .invalid_args, try effortRefusal(arena, e.loaded));
    // The settings that apply at any time: both checked before either is set.
    if (retry_arg != null or stall_arg != null) {
        var why: Fail = undefined;
        const p = if (retry_arg) |v| retryPolicyFrom(arena, v, &why) catch |err| switch (err) {
            error.Refused => return errRes(arena, why.code, why.msg),
            else => return err,
        } else null;
        const stall = if (stall_arg) |v| stallFrom(arena, v, &why) catch |err| switch (err) {
            error.Refused => return errRes(arena, why.code, why.msg),
            else => return err,
        } else null;
        if (retry_arg != null) setRetryPolicy(e, p);
        if (stall_arg != null) e.stall.set(stall, clock.nowMs());
        writeDescriptor(e);
        service(clock.nowMs());
        if (model == null and effort == null) {
            var res = Res.init(arena);
            if (retry_arg != null) {
                if (p) |x|
                    try res.textf("{s}: retry_on_overload on: up to {d} retr{s} per job, the first after {d} s, doubling", .{ e.id, x.max, if (x.max == 1) "y" else "ies", x.backoff_s })
                else
                    try res.textf("{s}: retry_on_overload off", .{e.id});
            }
            if (stall_arg != null) {
                if (stall) |m|
                    try res.textf("{s}: stall_after_min {d}: one stalled event when it shows nothing for {d} minutes while busy", .{ e.id, m, m })
                else
                    try res.textf("{s}: stall_after_min off", .{e.id});
            }
            try res.fact("relaunched", false);
            return finish(arena, &res, e, try pending(arena, e), .{}, &.{});
        }
    }
    const deadline = deadlineFrom(args, DEFAULT_WAIT_MS);
    // A screen app is typed at: only while it is idle.
    if (e.agent.kind() == .screen) {
        _ = waitReady(e, deadline);
        if (try busy(arena, e)) |f| return errRes(arena, f.code, f.msg);
    }
    var confirmations: std.ArrayList([]const u8) = .empty;
    var relaunched = false;
    for ([_]?agent_mod.Action{
        if (model) |m| agent_mod.Action{ .set_model = m } else null,
        if (effort) |x| agent_mod.Action{ .set_effort = x } else null,
    }) |maybe| {
        const action = maybe orelse continue;
        switch (try act(arena, e, action, deadline)) {
            .fail => |f| return errRes(arena, f.code, f.msg),
            .ok => |o| {
                if (o.confirmation) |line| try confirmations.append(arena, line);
                relaunched = relaunched or o.relaunched;
                try noteSetting(arena, e, action, o);
            },
        }
    }
    service(clock.nowMs());
    var res = Res.init(arena);
    try res.textf("{s}: {s} set for this session only{s}", .{
        e.id,
        if (model != null and effort != null) "model and effort" else if (model != null) "model" else "effort",
        if (relaunched) " (restarted with it; the conversation was resumed)" else "",
    });
    if (model) |m| try res.fact("model", m);
    if (effort) |x| try res.fact("effort", x);
    if (confirmations.items.len > 0) try res.fact("confirmation", try std.mem.join(arena, "\n", confirmations.items));
    try res.fact("relaunched", relaunched);
    switch (e.agent.source) {
        .opencode_api => |*api| {
            if (api.currentModel()) |m| try res.fact("current_model", try std.fmt.allocPrint(arena, "{s}/{s}", .{ m.provider, m.model }));
            if (api.currentEffort()) |x| try res.fact("current_effort", x);
        },
        .screen => {},
    }
    const blocks = [1]Block{.{ .name = "confirmation", .body = try std.mem.join(arena, "\n", confirmations.items) }};
    return finish(arena, &res, e, try pending(arena, e), .{}, blocks[0..@intFromBool(confirmations.items.len > 0)]);
}

pub fn interruptTool(arena: std.mem.Allocator, args: std.json.Value, e: *Entry) ![]const u8 {
    service(clock.nowMs());
    // An interrupted turn is not continued behind the caller's back.
    e.retry.newPrompt();
    const deadline = deadlineFrom(args, DEFAULT_WAIT_MS);
    const queued_before = e.agent.queuedPrompts();
    const mine = try mcp_agent_act.queuedSnapshot(arena, e);
    switch (try act(arena, e, .interrupt, deadline)) {
        .fail => |f| return errRes(arena, f.code, f.msg),
        .ok => {},
    }
    pumpFor(INTERRUPT_SETTLE_MS);
    // Claude Code's Escape throws its queue away with the turn: the ones
    // this server queued are typed again, as agent_send interrupt does;
    // never leave the caller believing the others still wait.
    const dropped = queued_before -| e.agent.queuedPrompts();
    const requeued = try requeueDropped(arena, e, mcp_agent_act.droppedOf(e, mine), deadline);
    var res = Res.init(arena);
    try res.textf("{s}: interrupted", .{e.id});
    const lost = dropped -| @as(u32, @intCast(requeued.done.len));
    if (lost > 0) try res.textf("{d} queued prompt(s) were dropped by the interrupt and not typed again (the app discards its queue with the turn): agent_send them again", .{lost});
    try requeued.report(arena, &res);
    try res.fact("interrupted", true);
    try res.fact("queued_dropped", dropped);
    return finish(arena, &res, e, try pending(arena, e), .{}, &.{});
}

/// agent_ask: a side question answered from the agent's current context
/// without a turn. Nothing is recorded, no event is raised or taken, the
/// handed-out state and the remembered waiter filter stay as they were.
pub fn askTool(arena: std.mem.Allocator, args: std.json.Value, e: *Entry) ![]const u8 {
    const text = argStr(args, "text") orelse return errRes(arena, .invalid_args, "agent_ask needs 'text', the question");
    if (std.mem.trim(u8, text, " \t").len == 0) return errRes(arena, .invalid_args, "text is empty");
    for (text) |ch| if (ch < 0x20 or ch == 0x7f)
        return errRes(arena, .invalid_args, "a side question is one line of text (no line breaks or control characters)");
    if (!e.agent.supports(.side_question))
        return errRes(arena, .invalid_args, try std.fmt.allocPrint(arena, "the {s} adapter has no side questions (capabilities.agent_side_question lists the apps that do); agent_send asks it as a prompt", .{e.loaded.spec.id}));
    if (e.loaded.spec.screen) |sc| if (sc.paste) |p| if (p.collapses(text))
        return errRes(arena, .invalid_args, try std.fmt.allocPrint(arena, "a side question is at most {d} bytes (the app would collapse a longer one into a paste its panel cannot show)", .{p.over_chars}));
    service(clock.nowMs());
    const st = e.agent.state();
    if (!st.takesSideQuestion()) return switch (st) {
        .waiting_user => errRes(arena, .conflict, (try busy(arena, e)).?.msg),
        .starting => errRes(arena, .conflict, try std.fmt.allocPrint(arena, "agent {s} is not ready yet (state starting); nothing was typed", .{e.id})),
        else => errRes(arena, .unavailable, try std.fmt.allocPrint(arena, "agent {s} is {s}; agent_close it", .{ e.id, @tagName(st) })),
    };
    const d = e.agent.driver().screen;
    if (d.sideOpen())
        return errRes(arena, .conflict, try std.fmt.allocPrint(arena, "agent {s} already shows a side panel (someone else's question) and it has the keyboard; nothing was typed", .{e.id}));
    if (!d.inputShowing())
        return errRes(arena, .conflict, try std.fmt.allocPrint(arena, "agent {s} shows no input box; nothing was typed", .{e.id}));
    if (!d.inputEmpty())
        return errRes(arena, .conflict, try std.fmt.allocPrint(arena, "agent {s}'s input box holds text someone is typing; nothing was typed (it would merge with theirs)", .{e.id}));
    const t0 = clock.nowMs();
    const o = switch (try act(arena, e, .{ .side_question = text }, deadlineFrom(args, DEFAULT_WAIT_MS))) {
        .fail => |f| {
            if (!d.sideOpen()) return sendFailRes(arena, e, f);
            return sendFailRes(arena, e, .{ .code = f.code, .msg = try std.fmt.allocPrint(arena, "{s}\n(its side panel still shows and has the keyboard: Escape in its session closes it)", .{f.msg}) });
        },
        .ok => |o| o,
    };
    service(clock.nowMs());
    const answer = o.answer orelse "";
    const closed = o.side_closed orelse !d.sideOpen();
    var res = Res.init(arena);
    try res.textf("{s} answered the side question from its current context: no turn, nothing recorded (state {s})", .{ e.id, @tagName(e.agent.state()) });
    if (!closed) try res.textf("its side panel did not close and has the keyboard: {s} takes no input until it does (Escape in its session closes it)", .{e.id});
    try res.fact("agent", e.id);
    if (e.name) |n| try res.fact("name", n);
    try res.fact("app", e.loaded.spec.id);
    try res.fact("state", @tagName(e.agent.state()));
    try res.fact("question", text);
    try res.fact("answer", answer);
    try res.fact("panel_closed", closed);
    try res.fact("waited_ms", clock.nowMs() - t0);
    try block(&res, .{ .name = "answer", .body = answer });
    return res.finish();
}

pub fn readTool(arena: std.mem.Allocator, args: std.json.Value, e: *Entry) ![]const u8 {
    const detail = if (argStr(args, "detail")) |d|
        std.meta.stringToEnum(select.Detail, d) orelse return errRes(arena, .invalid_args, "detail must be one of: " ++ comptime enumList(select.Detail))
    else
        select.Detail.selected;
    if (!detail.selects()) return activityRead(arena, args, e);
    const explicit = argInt(args, "since");
    // Only the newest job's last assistant message.
    const final = argBool(args, "final");
    if (final and detail == .all) return errRes(arena, .invalid_args, "final returns one message: it does not combine with detail \"all\"");
    const limit: usize = @intCast(std.math.clamp(argInt(args, "limit") orelse READ_DEFAULT, 1, READ_MAX));
    const recs = e.agent.records();
    // The default read: every job, minus what was handed out before. An
    // explicit `since` or `all` is a deliberate re-read of what it names.
    const delivery = detail == .selected and explicit == null;
    const base: u64 = if (explicit) |s| @intCast(@max(s, 0)) else if (delivery) 0 else e.read_cursor;
    const after = try select.jobsAfter(arena, recs, base);
    const jobs = if (final and after.len > 0) after[after.len - 1 ..] else after;
    const sel = try select.select(arena, recs, jobs, .{
        .detail = detail,
        .include_tools = argBool(args, "include_tools"),
        .limit = limit,
        .since = base,
        .handed = if (delivery) &e.handed else null,
        // A final read names its job even with nothing new, to point at it.
        .keep_empty = final,
        .final_only = final,
    });
    try e.handed.markSelection(e.allocator, recs, sel);
    var high = base;
    for (recs) |r| high = @max(high, r.id);
    // A paged `all` read goes on after its last record; any other covers everything.
    const next: u64 = if (sel.more) recs[sel.picked[sel.picked.len - 1]].id else high;
    // Only `all` pages; the default read's delivery is per record.
    if (detail == .all) e.read_cursor = @max(e.read_cursor, next);

    var res = Res.init(arena);
    const body = try writeSelection(arena, &res, recs, sel);
    if (final) try res.fact("final", true);
    if (recs.len == 0)
        try res.text("no records yet")
    else if (final and sel.jobs.len > 0) {
        const j = sel.jobs[0];
        if (sel.picked.len > 0)
            try res.textf("job {d}'s final message [{d}]; next_since {d}", .{ j.job, recs[sel.picked[0]].id, next })
        else if (j.earlier) |x|
            try res.textf("job {d}'s final message [{d}] was returned before (final with since 0 re-reads it)", .{ j.job, x.id })
        else
            try res.textf("job {d} has no assistant message yet (state {s})", .{ j.job, @tagName(e.agent.state()) });
    } else if (sel.jobs.len == 0)
        try res.textf("nothing new since the last read; next_since {d}", .{next})
    else
        try res.textf("{d} record(s) of job(s) {d}-{d}; next_since {d}{s}", .{
            sel.picked.len,
            sel.jobs[0].job,
            sel.jobs[sel.jobs.len - 1].job,
            next,
            if (sel.more) " (more follow)" else "",
        });
    try res.fact("detail", @tagName(detail));
    try res.fact("next_since", next);
    try res.fact("more", sel.more);
    const blocks = [1]Block{.{ .name = "records", .body = body }};
    return finish(arena, &res, e, try pending(arena, e), .{}, blocks[0..@intFromBool(sel.jobs.len > 0)]);
}

/// `E`'s member names, comma-separated (an error naming the choices).
fn enumList(comptime E: type) []const u8 {
    var out: []const u8 = "";
    for (std.meta.fieldNames(E), 0..) |n, i| out = out ++ (if (i > 0) ", " else "") ++ n;
    return out;
}

/// agent_read detail "activity": the state, the time since the last
/// activity and the newest `limit` tool calls as name + time. A glance:
/// it takes no event and hands no record out.
fn activityRead(arena: std.mem.Allocator, args: std.json.Value, e: *Entry) ![]const u8 {
    if (argBool(args, "final") or argInt(args, "since") != null or argBool(args, "include_tools"))
        return errRes(arena, .invalid_args, "detail \"activity\" takes only limit (the tool calls to list)");
    const limit: usize = @intCast(std.math.clamp(argInt(args, "limit") orelse ACTIVITY_DEFAULT, 1, ACTIVITY_MAX));
    const Tool = struct { name: []const u8, at: ?[]const u8 };
    const recs = e.agent.records();
    var tools: std.ArrayList(Tool) = .empty;
    var i = recs.len;
    while (i > 0 and tools.items.len < limit) {
        i -= 1;
        const r = recs[i];
        if (r.kind != .tool) continue;
        const iso = if (r.at_ms > 0) try isoAt(arena, r.at_ms) else null;
        try tools.append(arena, .{ .name = r.toolName(), .at = if (iso) |s| clock.isoTime(s) else null });
    }
    std.mem.reverse(Tool, tools.items);
    const act_ms = e.agent.lastActivityMs();
    const st = e.agent.state();
    var res = Res.init(arena);
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.print("{s} {s}", .{ e.id, @tagName(st) });
    const last_at = if (act_ms > 0) try isoAt(arena, clock.wallOfMono(act_ms)) else null;
    const idle_s: ?i64 = if (act_ms > 0) @divTrunc(@max(0, clock.nowMs() - act_ms), 1000) else null;
    if (idle_s) |s| try w.print(", last activity {s} ({d}s ago)", .{ clock.isoTime(last_at orelse ""), s }) else try w.writeAll(", no activity yet");
    try w.writeAll(if (tools.items.len == 0) "; no tool calls" else "; tools:");
    for (tools.items) |t| try w.print(" {s} {s},", .{ t.name, t.at orelse "?" });
    try res.text(std.mem.trimEnd(u8, aw.written(), ","));
    // The keys every agent_read declares, kept small: no records, no
    // events taken (a glance delivers nothing).
    try res.fact("agent", e.id);
    try res.fact("app", e.loaded.spec.id);
    try res.fact("source", @tagName(e.agent.kind()));
    try res.fact("state", @tagName(st));
    try res.fact("ready", e.agent.ready());
    try res.fact("session", e.session);
    try res.fact("transport", @tagName(e.transport));
    try res.raw("events", "[]");
    try res.raw("records", "[]");
    try res.raw("jobs", "[]");
    try res.raw("cut_ids", "[]");
    try res.fact("detail", @tagName(select.Detail.activity));
    try res.fact("next_since", e.read_cursor);
    try res.fact("more", false);
    if (idle_s) |x| try res.fact("idle_s", x);
    if (last_at) |x| try res.fact("last_activity_at", x);
    try res.raw("tools", try toJson(arena, tools.items));
    return res.finish();
}

pub fn listTool(arena: std.mem.Allocator, args: std.json.Value) ![]const u8 {
    service(clock.nowMs());
    // One bounded read of every host, for `hosts` and for remote facts.
    const until = clock.nowMs() + HOST_LIST_WAIT_MS;
    _ = try readHosts(arena, until);
    if (!argBool(args, "detail")) return listCompact(arena, until);
    const Item = struct {
        agent: []const u8,
        name: ?[]const u8,
        app: []const u8,
        source: []const u8,
        state: []const u8,
        ready: bool,
        /// The SSH host; null = this machine.
        host: ?[]const u8,
        transport: []const u8,
        cwd: []const u8,
        binary: []const u8,
        model: ?[]const u8,
        effort: ?[]const u8,
        session: []const u8,
        server_session: ?[]const u8,
        sessions: []const []const u8,
        started_ms: i64,
        last_activity_ms: ?i64,
        last_activity_at: ?[]const u8,
        pending_events: usize,
        waiting_on_user: bool,
        queued_prompts: u32,
        conversation: ?[]const u8,
        recordings: []const []const u8,
        permissions: ?std.json.Value,
        retry_on_overload: ?retry_mod.Policy,
        stall_after_min: ?u32,
        relaunchable: ?bool,
        gone_reason: ?[]const u8,
        facts: ?std.json.Value,
        facts_unknown: ?[]const u8,
    };
    const items = try arena.alloc(Item, state.entries.items.len);
    var res = Res.init(arena);
    try res.textf("{d} agent(s)", .{items.len});
    const wall = clock.wallMs();
    const mono = clock.nowMs();
    for (state.entries.items, items) |e, *out| {
        var model: ?[]const u8 = e.picked_model orelse e.launch_model;
        var effort: ?[]const u8 = e.launch_effort;
        switch (e.agent.source) {
            .opencode_api => |*api| {
                if (api.currentModel()) |m| model = try std.fmt.allocPrint(arena, "{s}/{s}", .{ m.provider, m.model });
                effort = api.currentEffort();
            },
            .screen => {},
        }
        var sessions: std.ArrayList([]const u8) = .empty;
        try sessions.append(arena, e.session);
        if (e.server_session) |s| try sessions.append(arena, s);
        const act_ms = e.agent.lastActivityMs();
        const fr = try factsOf(arena, e);
        out.* = .{
            .facts = fr.json,
            .facts_unknown = fr.unknown,
            .agent = e.id,
            .name = e.name,
            .app = e.loaded.spec.id,
            .source = @tagName(e.agent.kind()),
            .state = @tagName(e.agent.state()),
            .ready = e.agent.ready(),
            .host = e.host,
            .transport = @tagName(e.transport),
            .cwd = e.cwd,
            .binary = e.binary,
            .model = model,
            .effort = effort,
            .session = e.session,
            .server_session = e.server_session,
            .sessions = sessions.items,
            .started_ms = e.started_ms,
            .last_activity_ms = if (act_ms > 0) wall - @max(0, mono - act_ms) else null,
            .last_activity_at = if (act_ms > 0) try isoAt(arena, wall - @max(0, mono - act_ms)) else null,
            .pending_events = e.agent.queue().undelivered(),
            .waiting_on_user = e.agent.interaction() != null,
            .queued_prompts = e.agent.queuedPrompts(),
            .conversation = conversationOf(e),
            .recordings = e.recordings.items,
            .permissions = if (e.extra.permissions.len > 0) try permissionsValue(arena, e.extra.permissions) else null,
            .retry_on_overload = e.retry.policy,
            .stall_after_min = e.stall.after_min,
            .relaunchable = relaunchableOf(e),
            .gone_reason = if (e.gone_why) |g| g.reasonName() else null,
        };
        try res.textf("{s} ({s}{s}{s}): {s} on {s} in {s}, up {d}s, active {s} ago, {d} undelivered event(s)", .{
            out.agent,                         out.app,                    if (model != null) ", " else "",                          model orelse "",
            out.state,                         e.host orelse "this machine", out.cwd,                                                   @divTrunc(@max(0, wall - e.started_ms), 1000),
            if (out.last_activity_ms) |x| try std.fmt.allocPrint(arena, "{d}s", .{@divTrunc(@max(0, wall - x), 1000)}) else "never", out.pending_events,
        });
        if (fr.line) |l| try res.textf("{s}: {s}", .{ out.agent, l });
    }
    try hostsReport(arena, &res, until);
    try res.raw("agents", try toJson(arena, items));
    try res.fact("count", items.len);
    try res.fact("detail", true);
    return res.finish();
}

/// agent_list's default: what an orchestrator of many agents scans each
/// turn (with 17 agents the full facts cost ~5k tokens), one line each.
fn listCompact(arena: std.mem.Allocator, until: i64) ![]const u8 {
    const Pending = struct { kind: []const u8, title: []const u8 };
    const Item = struct {
        agent: []const u8,
        name: ?[]const u8,
        app: []const u8,
        state: []const u8,
        /// The SSH host, or "local".
        host: []const u8,
        cwd: []const u8,
        /// Seconds since the app last drew or sent anything.
        idle_s: ?i64,
        /// The local HH:MM of that activity.
        active_at: ?[]const u8,
        queued: u32,
        pending: ?Pending,
        conversation: ?[]const u8,
        relaunchable: ?bool,
        gone_reason: ?[]const u8,
        /// The newest job's last assistant message, first line, clipped.
        preview: ?[]const u8,
        facts: ?std.json.Value,
    };
    // Gone agents are one line together: id, name and whether a relaunch
    // starts them again (detail:true lists them in full).
    const Gone = struct { agent: []const u8, name: ?[]const u8, relaunchable: bool };
    var gone_list: std.ArrayList(Gone) = .empty;
    var running: std.ArrayList(*Entry) = .empty;
    for (state.entries.items) |e| {
        if (gone(e)) try gone_list.append(arena, .{ .agent = e.id, .name = e.name, .relaunchable = e.ended_ms > 0 }) else try running.append(arena, e);
    }
    const items = try arena.alloc(Item, running.items.len);
    var res = Res.init(arena);
    try res.textf("{d} agent(s){s}", .{ state.entries.items.len, if (gone_list.items.len > 0) try std.fmt.allocPrint(arena, ", {d} of them gone", .{gone_list.items.len}) else "" });
    const mono = clock.nowMs();
    for (running.items, items) |e, *out| {
        const act_ms = e.agent.lastActivityMs();
        const it = e.agent.interaction();
        const fr = try factsOf(arena, e);
        out.* = .{
            .facts = fr.json,
            .agent = e.id,
            .name = e.name,
            .app = e.loaded.spec.id,
            .state = @tagName(e.agent.state()),
            .host = e.host orelse "local",
            .cwd = e.cwd,
            .idle_s = if (act_ms > 0) @divTrunc(@max(0, mono - act_ms), 1000) else null,
            .active_at = if (act_ms > 0) if (try isoAt(arena, clock.wallOfMono(act_ms))) |iso| clock.isoClock(iso) else null else null,
            .queued = e.agent.queuedPrompts(),
            .pending = if (it) |x| .{ .kind = @tagName(x.kind), .title = x.title } else null,
            .conversation = conversationOf(e),
            .relaunchable = relaunchableOf(e),
            .gone_reason = if (e.gone_why) |g| g.reasonName() else null,
            // A glance, never a delivery: nothing is marked handed.
            .preview = if (select.newestFinal(e.agent.records())) |i| events.preview(e.agent.records()[i].text) else null,
        };
        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        try w.print("{s}", .{e.id});
        if (e.name) |n| try w.print(" ({s})", .{n});
        try w.print(" {s} {s} on {s} in {s}", .{ out.app, out.state, out.host, out.cwd });
        if (out.gone_reason) |r| try w.print(" (gone: {s})", .{r});
        if (out.relaunchable) |can| try w.print(", {s}", .{if (can) "relaunchable (agent_attach relaunch: true)" else "not relaunchable"});
        if (out.idle_s) |x| try w.print(", idle {d}s", .{x});
        if (out.active_at) |hm| try w.print(" (since {s})", .{hm});
        if (out.queued > 0) try w.print(", {d} queued", .{out.queued});
        if (fr.line) |l| try w.print(", {s}", .{l});
        if (out.pending) |p| try w.print(", pending {s}: {s}", .{ p.kind, agentwait.clip(events.firstLine(p.title), 80) });
        if (out.preview) |p| try w.print("; last: {s}", .{p});
        try res.text(aw.written());
    }
    if (gone_list.items.len > 0) {
        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        try w.writeAll("gone:");
        for (gone_list.items, 0..) |g, i| {
            try w.print("{s} {s}", .{ if (i > 0) "," else "", g.agent });
            if (g.name) |n| try w.print(" ({s})", .{n});
            if (g.relaunchable) try w.writeAll(" relaunchable");
        }
        try w.writeAll(" (agent_attach {agent, relaunch: true} starts a relaunchable one again; agent_close forgets one)");
        try res.text(aw.written());
    }
    try hostsReport(arena, &res, until);
    try res.raw("agents", try toJson(arena, items));
    try res.raw("gone", try toJson(arena, gone_list.items));
    try res.fact("count", state.entries.items.len);
    try res.fact("detail", false);
    return res.finish();
}

pub fn closeTool(arena: std.mem.Allocator, _: std.json.Value, e: *Entry) ![]const u8 {
    const id = try arena.dupe(u8, e.id);
    var sessions: std.ArrayList([]const u8) = .empty;
    if (e.visible) |l| if (l == .owned) try sessions.append(arena, try arena.dupe(u8, e.session));
    if (e.server_session) |s| try sessions.append(arena, try arena.dupe(u8, s));
    discard(e);
    var res = Res.init(arena);
    try res.textf("closed {s}{s}", .{ id, if (sessions.items.len == 0) " (its terminal belongs to term_open and stays)" else "" });
    try res.fact("agent", id);
    try res.fact("closed", true);
    try res.fact("sessions", sessions.items);
    return res.finish();
}

/// agent_close of an agent this server does not hold: a GONE one in the
/// index is forgotten (descriptor, password, lock), which frees its name;
/// anything else is not found here, as before.
pub fn closeGoneTool(arena: std.mem.Allocator, key: []const u8) ![]const u8 {
    const dir = state.index_dir orelse return notFoundKey(arena, key);
    const d = (try agentindex.resolve(arena, dir, key)) orelse return notFoundKey(arena, key);
    if (d.gone_ms == 0) return notFoundKey(arena, key);
    const lp = try lockPath(arena, d.id);
    var claimed = agentindex.claim(lp, false) catch |err| switch (err) {
        error.Held => return errRes(arena, .conflict, try std.fmt.allocPrint(arena, "agent {s} is held by another live MCP server; agent_close it there", .{d.id})),
        error.LockFailed => return errRes(arena, .io_failed, "could not lock the agent in the index"),
    };
    agentindex.remove(arena, dir, d.id);
    claimed.release(lp, true);
    var res = Res.init(arena);
    try res.textf("forgot gone agent {s}{s}{s}{s}: it is out of the index and its name is free", .{ d.id, if (d.name != null) " (" else "", d.name orelse "", if (d.name != null) ")" else "" });
    try res.fact("agent", d.id);
    try res.fact("closed", true);
    try res.fact("sessions", @as([]const []const u8, &.{}));
    return res.finish();
}

fn notFoundKey(arena: std.mem.Allocator, key: []const u8) ![]const u8 {
    return errRes(arena, .not_found, try std.fmt.allocPrint(arena, "no agent '{s}' on this server (open: {s})", .{ key, try idList(arena) }));
}
