//! What `agent_*` results hand the assistant: the events and the wait
//! part (`Delivered`, `combine`), the per-agent facts every result writes
//! (`finish`), and the per-job record selection (`writeSelection`).

const std = @import("std");
const mcp = @import("mcp.zig");
const agentwait = @import("agentwait.zig");
const events = @import("../agent/events.zig");
const vocab = @import("../agent/vocab.zig");
const output = @import("../agent/output.zig");
const select = @import("../agent/select.zig");
const launch = @import("../agent/launch.zig");
const clock = @import("../util/clock.zig");
const Res = mcp.Res;

const mcp_agent = @import("mcp_agent.zig");
const mcp_agent_hosts = @import("mcp_agent_hosts.zig");
const mcp_agent_waiter = @import("mcp_agent_waiter.zig");

const Entry = mcp_agent.Entry;
const state = &mcp_agent.state;
const gone = mcp_agent.gone;
const factsOf = mcp_agent_hosts.factsOf;
const pushing = mcp_agent_waiter.pushing;
const rememberFilter = mcp_agent_waiter.rememberFilter;

// ── results ──────────────────────────────────────────────────────

/// What a call hands the assistant: the events it had not been handed,
/// and whether a wait was part of the call.
pub const Delivered = struct {
    items: []const events.Item = &.{},
    digest: ?events.Digest = null,
    wait: ?WaitPart = null,
};

const WaitPart = struct {
    /// Items from here on arrived during the wait; earlier ones were
    /// pending before the call acted.
    post_from: usize,
    timed_out: bool,
    /// The call submitted a prompt (an outcome may be `sent`).
    sent: bool = false,
    /// The prompt went into the app's queue (an outcome may be `queued`).
    queued: bool = false,
};

/// A payload block of the text lane (after the prose).
pub const Block = struct { name: []const u8, body: []const u8 };

/// Events pending before the call plus what `wait` delivered.
pub fn combine(arena: std.mem.Allocator, pre: ?events.Delivery, post: ?events.Delivery, waited: bool, timed_out: bool) !Delivered {
    var items: std.ArrayList(events.Item) = .empty;
    var digest: ?events.Digest = null;
    if (pre) |p| {
        try items.appendSlice(arena, p.items);
        digest = p.digest;
    }
    const post_from = items.items.len;
    if (post) |p| {
        try items.appendSlice(arena, p.items);
        if (p.digest) |d| digest = if (digest) |old| .{ .count = old.count + d.count, .latest_seq = d.latest_seq } else d;
    }
    return .{
        .items = items.items,
        .digest = digest,
        .wait = if (waited) .{ .post_from = post_from, .timed_out = timed_out } else null,
    };
}

/// Pending always-on events, for results that do not wait.
pub fn pending(arena: std.mem.Allocator, e: *Entry) !Delivered {
    return combine(arena, try e.cursor.take(e.agent.queue(), .{}, clock.nowMs(), arena), null, false, false);
}

/// The kind a wake-up reports: the delivered kind of the highest
/// `outcomeRank`, else `exited` for an agent that is gone, else `queued`
/// for a prompt the app still holds for a later turn, else `sent` for a
/// prompt the agent has not started on, else still working.
/// @param sent the call submitted a prompt.
/// @param queued the call queued it and the app has not taken it yet.
pub fn outcomeOf(items: []const events.Item, st: vocab.State, sent: bool, queued: bool) []const u8 {
    var best: ?vocab.EventKind = null;
    for (items) |it| {
        if (best == null or it.kind.outcomeRank() > best.?.outcomeRank()) best = it.kind;
    }
    if (best) |b| return @tagName(b);
    if (st == .exited) return @tagName(vocab.EventKind.exited);
    if (sent and queued) return @tagName(vocab.WaitOutcome.queued);
    if (sent and st.takesPrompt()) return @tagName(vocab.WaitOutcome.sent);
    return @tagName(vocab.WaitOutcome.still_working);
}

pub const EventJson = struct {
    seq: u64,
    kind: []const u8,
    text: []const u8,
    detail: []const u8,
    count: u32,
    class: ?[]const u8 = null,
    job: ?u32 = null,
    record: ?u64 = null,
    background_tasks: ?u32 = null,
};

/// An event's text as a result shows it: a record it announces is
/// referenced by id with a one-line preview, never repeated whole.
fn eventText(it: events.Item) []const u8 {
    return if (it.kind.announcesRecord()) events.preview(it.event.text) else it.event.text;
}

const InteractionJson = struct {
    kind: []const u8,
    title: []const u8,
    detail: []const u8,
    hint: []const u8,
    options: []const output.Option,
    free_text: bool,
};

pub fn toJson(arena: std.mem.Allocator, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(arena, value, .{ .emit_null_optional_fields = false });
}

/// What a result's watch_command waits for.
pub const Watch = struct {
    filter: events.Filter = .{},
    /// Several agents (agent_wait `agents`, agent_send `agents`).
    any: []const []const u8 = &.{},
    /// How the command wakes on several: the first of any, or once all settled.
    several: agentwait.Several = .any,
    /// The template the call's prompt was rendered from (the `template` fact).
    template: ?[]const u8 = null,
};

/// The facts and prose every per-agent result shares, then the payload
/// blocks (`extra` first) and the finished result.
pub fn finish(arena: std.mem.Allocator, res: *Res, e: *Entry, dv: Delivered, watch: Watch, extra: []const Block) ![]const u8 {
    const st = e.agent.state();
    const q = e.agent.queue();
    rememberFilter(e, watch.filter);
    try res.fact("agent", e.id);
    if (e.name) |n| try res.fact("name", n);
    try res.fact("app", e.loaded.spec.id);
    try res.fact("source", @tagName(e.agent.kind()));
    try res.fact("state", @tagName(st));
    try res.fact("ready", e.agent.ready());
    try res.fact("session", e.session);
    if (e.server_session) |s| try res.fact("server_session", s);
    if (e.host) |h| try res.fact("host", h);
    if (conversationOf(e)) |cv| try res.fact("conversation", cv);
    try res.fact("transport", @tagName(e.transport));
    try goneFacts(arena, res, e);
    try retryFacts(res, e);
    if (e.stall.after_min) |m| try res.fact("stall_after_min", m);
    const fr = try factsOf(arena, e);
    if (fr.json) |j| try res.raw("facts", try toJson(arena, j));

    var message: ?[]const u8 = null;
    var job_block: ?Block = null;
    if (dv.wait) |w| {
        const post = dv.items[w.post_from..];
        const outcome = outcomeOf(post, st, w.sent, w.queued and e.agent.queuedPrompts() > 0);
        try res.fact("outcome", outcome);
        var job: ?u32 = null;
        var first: ?u32 = null;
        var background: ?u32 = null;
        for (post) |it| if (it.kind == .done) {
            message = it.event.text;
            job = it.event.job;
            background = it.event.background_tasks;
        };
        // A done covers every job since the previous one that woke (one a
        // queued prompt superseded has none of its own), a done that rode
        // along before the wait included.
        for (dv.items) |it| if (it.kind == .done) {
            const f = it.event.first_job orelse it.event.job orelse continue;
            first = if (first) |x| @min(x, f) else f;
        };
        // The finished job(s) as agent_read would return them, without
        // what the assistant was handed before: no extra read, no repeat.
        if (job) |j| {
            const lo = @min(first orelse j, j);
            const recs = e.agent.records();
            var jobs: std.ArrayList(u32) = .empty;
            for (try select.jobsAfter(arena, recs, 0)) |x| if (x >= lo and x < j) try jobs.append(arena, x);
            try jobs.append(arena, j);
            const fresh = if (select.answerIndex(recs, j)) |i| !e.handed.has(recs[i]) else false;
            if (!fresh) message = null;
            const sel = try select.select(arena, recs, jobs.items, .{ .handed = &e.handed, .keep_empty = true });
            job_block = .{ .name = try jobsName(arena, sel.jobs), .body = try writeSelection(arena, res, recs, sel) };
            try e.handed.markSelection(e.allocator, recs, sel);
        }
        if (message) |m| try res.fact("message", m);
        try res.fact("timed_out", w.timed_out and !state.no_wait);
        try res.textf("{s}: {s} (state {s})", .{ e.id, outcome, @tagName(st) });
        if (background) |n|
            try res.textf("a quiet done (background): {d} minutes idle with {d} background task(s) still running; the turn is not settled, and its done wakes you once they end", .{ @divTrunc(select.BACKGROUND_DONE_CAP_MS, 60_000), n });
        if (w.timed_out and pushing()) {
            try res.textf("{s}: its events are pushed into this session as they happen, so end your turn here; no watch_command, Monitor or agent_wait is needed", .{outcome});
        } else if (w.timed_out) {
            if (std.mem.eql(u8, outcome, @tagName(vocab.WaitOutcome.queued)))
                try res.text("queued; the agent was busy and takes the prompt when its current turn ends: run watch_command in the background (or as a Monitor with --follow) to be woken once it has answered it")
            else if (std.mem.eql(u8, outcome, @tagName(vocab.WaitOutcome.sent)))
                try res.text("sent; the agent had not started on it when the call returned: run watch_command in the background (or as a Monitor with --follow) to be woken instead of polling")
            else
                try res.text("still working when the wait ran out: run watch_command in the background (or as a Monitor with --follow) to be woken instead of polling");
        }
    } else try res.textf("{s}: state {s}", .{ e.id, @tagName(st) });
    if (fr.line) |l| try res.textf("{s}: {s}", .{ e.id, l });
    if (watch.template) |x| try res.fact("template", x);

    try res.raw("events", try toJson(arena, try eventsJson(arena, dv.items)));
    if (dv.digest) |g| {
        const latest = if (q.bySeq(g.latest_seq)) |ev| events.preview(ev.text) else "";
        try res.raw("digest", try toJson(arena, .{ .count = g.count, .latest = latest }));
        try res.textf("{d} more opt-in event(s) held back by the rate limit", .{g.count});
    }
    const it = e.agent.interaction();
    if (it) |x| try res.raw("interaction", try toJson(arena, InteractionJson{
        .kind = @tagName(x.kind),
        .title = x.title,
        .detail = x.detail,
        .hint = x.hint,
        .options = x.options,
        .free_text = x.free_text,
    }));
    var cmd: ?[]const u8 = null;
    if (state.exe) |exe| {
        if (state.waiter.path) |sock| {
            const one = [1][]const u8{e.id};
            cmd = try agentwait.watchCommand(arena, exe, sock, if (watch.any.len > 0) watch.any else &one, watch.filter, watch.several);
            try res.fact("watch_command", cmd.?);
        }
    }

    for (extra) |b| try block(res, b);
    // The job block holds the message among its selected ones.
    if (job_block) |b| try block(res, b) else if (message) |m| try block(res, .{ .name = "message", .body = m });
    if (dv.items.len > 0) {
        var aw: std.Io.Writer.Allocating = .init(arena);
        for (dv.items, 0..) |ev, i| {
            if (i > 0) try aw.writer.writeAll("\n");
            try aw.writer.print("{d} {s}", .{ ev.event.seq, @tagName(ev.kind) });
            if (ev.event.count > 1) try aw.writer.print(" (x{d})", .{ev.event.count});
            if (ev.event.record) |id| try aw.writer.print(" [{d}]", .{id});
            if (ev.event.text.len > 0) try aw.writer.print(": {s}", .{agentwait.clip(eventText(ev), 300)});
        }
        try block(res, .{ .name = "events", .body = aw.written() });
    }
    if (it) |x| {
        var aw: std.Io.Writer.Allocating = .init(arena);
        try aw.writer.print("{s}: {s}", .{ @tagName(x.kind), x.title });
        if (x.detail.len > 0) try aw.writer.print("\n{s}", .{x.detail});
        for (x.options, 1..) |o, n| try aw.writer.print("\n{d}. {s}{s}", .{ n, o.label, if (o.selected) " (selected)" else "" });
        if (x.hint.len > 0) try aw.writer.print("\n{s}", .{x.hint});
        if (x.free_text) try aw.writer.writeAll("\n(a free-text answer is accepted: agent_answer text)");
        try block(res, .{ .name = "prompt", .body = aw.written() });
    }
    if (cmd) |x| try block(res, .{ .name = "watch_command", .body = x });
    return res.finish();
}

/// The app conversation `e` runs (what `agent_open resume` takes), or null
/// while unknown: a screen app's session id, an API source's session.
pub fn conversationOf(e: *Entry) ?[]const u8 {
    return switch (e.agent.source) {
        .opencode_api => |*api| api.sessionId(),
        .screen => e.conversation,
    };
}

/// A permission policy as the `permissions` fact: name to action.
pub fn permissionsValue(arena: std.mem.Allocator, perms: []const launch.Permission) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    for (perms) |p| try obj.put(arena, p.name, .{ .string = @tagName(p.action) });
    return .{ .object = obj };
}

/// Whether a gone agent can be started again, as agent_attach answers it:
/// its descriptor was kept (`ended_ms`).
pub fn relaunchableOf(e: *const Entry) ?bool {
    return if (gone(e)) e.ended_ms != 0 else null;
}

/// A gone agent's `relaunchable` and, when a reconnect found its session
/// gone, `gone_reason`, with a line saying what to do.
fn goneFacts(arena: std.mem.Allocator, res: *Res, e: *Entry) !void {
    const can = relaunchableOf(e) orelse return;
    try res.fact("relaunchable", can);
    if (e.gone_why) |g| try res.fact("gone_reason", g.reasonName());
    const key = e.name orelse e.id;
    if (can)
        try res.textf("{s} is gone{s}{s}{s}: agent_attach with agent \"{s}\" and relaunch: true starts it again with its launch settings, resuming its conversation", .{
            e.id, if (e.gone_why != null) " (" else "", if (e.gone_why) |g| g.reasonName() else "", if (e.gone_why != null) ")" else "", key,
        })
    else
        try res.textf("{s} is gone and cannot be relaunched{s}; agent_open a new one", .{ e.id, if (e.gone_why) |g| try std.fmt.allocPrint(arena, " ({s})", .{g.reasonName()}) else "" });
}

/// The retry policy and where its episode stands, when one is set.
fn retryFacts(res: *Res, e: *const Entry) !void {
    const p = e.retry.policy orelse return;
    try res.fact("retry_on_overload", .{
        .max = p.max,
        .backoff_s = p.backoff_s,
        .used = e.retry.used,
        .pending = e.retry.active,
        .next_in_ms = if (e.retry.due_ms) |d| @max(0, d - clock.nowMs()) else null,
    });
}

/// A job block's header: the jobs it holds (`job 3`, `jobs 2, 4`, `jobs 2-4`).
fn jobsName(arena: std.mem.Allocator, jobs: []const select.JobSummary) ![]const u8 {
    if (jobs.len == 0) return "jobs";
    if (jobs.len == 1) return std.fmt.allocPrint(arena, "job {d}", .{jobs[0].job});
    var contiguous = true;
    for (jobs[1..], 0..) |s, i| {
        if (s.job != jobs[i].job + 1) contiguous = false;
    }
    if (contiguous) return std.fmt.allocPrint(arena, "jobs {d}-{d}", .{ jobs[0].job, jobs[jobs.len - 1].job });
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "jobs ");
    for (jobs, 0..) |s, i| try out.print(arena, "{s}{d}", .{ if (i > 0) ", " else "", s.job });
    return out.items;
}

pub fn block(res: *Res, b: Block) !void {
    try res.textf("--- {s} ---", .{b.name});
    try res.text(b.body);
}

/// Delivered events as results list them (`finish`'s `events`).
pub fn eventsJson(arena: std.mem.Allocator, items: []const events.Item) ![]const EventJson {
    const evs = try arena.alloc(EventJson, items.len);
    for (items, evs) |it, *out| out.* = .{
        .seq = it.event.seq,
        .kind = @tagName(it.kind),
        .text = eventText(it),
        .record = it.event.record,
        .detail = it.event.detail,
        .count = it.event.count,
        .class = if (it.event.class) |cls| @tagName(cls) else null,
        .job = it.event.job,
        .background_tasks = it.event.background_tasks,
    };
    return evs;
}

const RecordJson = struct {
    id: u64,
    kind: []const u8,
    text: []const u8,
    job: u32,
    synthetic: bool,
    tool: ?struct { name: []const u8, input: []const u8, status: []const u8, output: []const u8 } = null,
};

/// Write a selection's facts (`records`, `jobs`, `cut_ids`).
/// @return its text block: per job a marker line, then its records.
pub fn writeSelection(arena: std.mem.Allocator, res: *Res, recs: []const output.Record, sel: select.Selection) ![]const u8 {
    const out = try arena.alloc(RecordJson, sel.picked.len);
    for (sel.picked, out) |i, *j| {
        const r = recs[i];
        j.* = .{
            .id = r.id,
            .kind = @tagName(r.kind),
            .text = r.text,
            .job = r.job,
            .synthetic = r.synthetic,
            .tool = if (r.tool) |tc| .{ .name = tc.name, .input = tc.input, .status = @tagName(tc.status), .output = tc.output } else null,
        };
    }
    try res.raw("records", try toJson(arena, out));
    try res.raw("jobs", try toJson(arena, sel.jobs));
    try res.fact("cut_ids", sel.cut);
    if (sel.jobs_pending > 0) try res.fact("jobs_pending", sel.jobs_pending);

    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    for (sel.jobs, 0..) |s, n| {
        if (n > 0) try w.writeAll("\n");
        try w.print("== job {d}", .{s.job});
        if (s.omitted_messages > 0 or s.omitted_tools > 0) {
            try w.writeAll(" (");
            if (s.omitted_messages > 0) try w.print("{d} more message{s}", .{ s.omitted_messages, if (s.omitted_messages == 1) "" else "s" });
            if (s.omitted_messages > 0 and s.omitted_tools > 0) try w.writeAll(", ");
            if (s.omitted_tools > 0) try w.print("{d} tool call{s}", .{ s.omitted_tools, if (s.omitted_tools == 1) "" else "s" });
            try w.writeAll(")");
        }
        try w.writeAll(" ==");
        for (sel.picked) |i| {
            const r = recs[i];
            if (r.job == s.job) try w.print("\n[{d}] {s}: {s}", .{ r.id, @tagName(r.kind), r.text });
        }
        // What was handed out before is never repeated: one pointer.
        if (s.earlier) |x| {
            try w.print("\nearlier in job {d}: [{d}] {s}, ", .{ s.job, x.id, @tagName(x.kind) });
            if (x.chars >= 1000) try w.print("{d}.{d}k chars", .{ x.chars / 1000, x.chars % 1000 / 100 }) else try w.print("{d} chars", .{x.chars});
            try w.writeAll(", returned before");
            if (s.returned_before > 1) try w.print(" (with {d} more)", .{s.returned_before - 1});
        }
    }
    if (sel.cut.len > 0) {
        try w.print("\n{d} selected record(s) left out by the {d}-character cap, ids", .{ sel.cut.len, select.READ_CAP_CHARS });
        for (sel.cut) |id| try w.print(" {d}", .{id});
        try w.writeAll(": the next agent_read returns them");
    }
    if (sel.jobs_pending > 0)
        try w.print("\n{d} more job(s) with new records the cap kept out entirely: the next agent_read returns them", .{sel.jobs_pending});
    return aw.written();
}

// ── tests ────────────────────────────────────────────────────────

const testing = std.testing;

test "the outcome of a wake-up is its highest-ranked kind" {
    var q = events.Queue.init(testing.allocator, .{});
    defer q.deinit();
    _ = try q.push(0, .message, null, "part", "");
    _ = try q.push(0, .done, null, "final", "");
    _ = try q.push(0, .needs_input, null, "permission: rm?", "");
    var cur: events.Cursor = .{};
    const d = (try cur.take(&q, .{ .messages = true }, 0, testing.allocator)).?;
    defer testing.allocator.free(d.items);
    try testing.expectEqualStrings("needs_input", outcomeOf(d.items, .waiting_user, false, false));
    try testing.expectEqualStrings("done", outcomeOf(d.items[0..2], .idle, false, false));
    try testing.expectEqualStrings("message", outcomeOf(d.items[0..1], .working, false, false));
    try testing.expectEqualStrings("still_working", outcomeOf(&.{}, .working, false, false));
    try testing.expectEqualStrings("exited", outcomeOf(&.{}, .exited, true, false));
    // A prompt the agent has not started on yet is sent, not working.
    try testing.expectEqualStrings("sent", outcomeOf(&.{}, .idle, true, false));
    try testing.expectEqualStrings("still_working", outcomeOf(&.{}, .working, true, false));
    try testing.expectEqualStrings("still_working", outcomeOf(&.{}, .idle, false, false));
    // A prompt queued behind a busy agent's turn and not taken yet.
    try testing.expectEqualStrings("queued", outcomeOf(&.{}, .working, true, true));
    // Taken: it is the turn now, and a wake-up still outranks it.
    try testing.expectEqualStrings("still_working", outcomeOf(&.{}, .working, true, false));
    try testing.expectEqualStrings("needs_input", outcomeOf(d.items, .waiting_user, true, true));
}

test "a job block names exactly the jobs it holds" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("job 2", try jobsName(a, &.{.{ .job = 2 }}));
    try testing.expectEqualStrings("jobs 1-3", try jobsName(a, &.{ .{ .job = 1 }, .{ .job = 2 }, .{ .job = 3 } }));
    try testing.expectEqualStrings("jobs 0, 2", try jobsName(a, &.{ .{ .job = 0 }, .{ .job = 2 } }));
}
