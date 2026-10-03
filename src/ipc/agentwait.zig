//! The agent waiter: how an assistant is WOKEN by a sub-agent instead of
//! polling it. The MCP server serves a unix socket in its instance dir;
//! `sketerm mcp agent-wait` (and `sketerm-mcp agent-wait`) connects,
//! subscribes to one agent with a filter, and prints one line per wake-up.
//!
//! This module is the one home of both halves' shared vocabulary: the
//! subscribe line, the server's wake/end lines, the CLI's argument
//! grammar and the exact `watch_command` a tool result hands out. The
//! server side (which events wake whom) is `mcp_agent.zig` over the same
//! `events.Cursor.take` that `agent_wait` uses.
//!
//! Wire, newline-delimited JSON. Client -> server, once:
//! `{"agent":"claude-1","match":"x","messages":true,"retrying":false,"background":false,"follow":false,"since":7}`,
//! with `"agents":[...]` added for `--any` (`agent` stays the first, so a
//! server that predates `agents` watches that one) and `"server":true`
//! for every agent of the server, later ones included (`--server`, the
//! follower push route: its wakes carry `content` and `meta`, composed by
//! `agentpush.zig`), and `"all":true` beside `agents` for `--all` (one
//! wake once EVERY agent settled). Server -> client:
//! `{"type":"wake","agent":...}` per wake-up, `{"type":"all","results":[...]}`
//! for `--all`, and a final `{"type":"end","reason":"..."}` before it
//! closes. A server that predates `all` reads the line as `--any`.
//!
//! A waiter shares the agent's ONE delivery state with the agent_* tools
//! (`events.Cursor`): what it prints is delivered, so no result repeats
//! it, and a second waiter on the same agent does not wake for it.

const std = @import("std");
const c = @import("../c.zig").c;
const vocab = @import("../agent/vocab.zig");
const events = @import("../agent/events.zig");
const shellquote = @import("../util/shellquote.zig");
const platform = @import("../util/platform.zig");
const clock = @import("../util/clock.zig");
const registry = @import("mcp_registry.zig");

/// The argv word after `mcp` that selects the waiter.
pub const SUBCOMMAND = "agent-wait";

/// Bytes of an event's text carried on the wire (the CLI shows less).
pub const WIRE_TEXT_MAX = 600;
/// Characters of text on one printed wake-up line.
pub const LINE_TEXT_MAX = 160;
/// Longest subscribe line the server reads.
pub const MAX_SUBSCRIBE = 4096;
/// Agents one `--any` waiter (or agent_wait `agents`) watches at most.
pub const MAX_ANY = @import("mcp_tools.zig").AGENT_WAIT_MAX_ANY;

pub const Subscribe = struct {
    agent: []const u8 = "",
    /// `--any`: every agent to watch (the first wake-up of any).
    agents: []const []const u8 = &.{},
    match: ?[]const u8 = null,
    messages: bool = false,
    /// Also wake on errors that do not wake by default (retrying).
    retrying: bool = false,
    /// Also wake on the background cap's quiet done.
    background: bool = false,
    follow: bool = false,
    /// Wake for events after this seq, delivered or not; null = for what
    /// nobody has delivered yet.
    since: ?u64 = null,
    /// Every agent of the server, those opened later included; each wake
    /// carries the pushed text, and a done's answer it carries is handed
    /// out (agent_read does not repeat it).
    server: bool = false,
    /// `--all`: one wake once every agent named settled
    /// (`vocab.State.settled`), with each one's outcome.
    all: bool = false,

    /// The agents it names.
    pub fn names(self: *const Subscribe) []const []const u8 {
        if (self.agents.len > 0) return self.agents;
        if (self.agent.len == 0) return &.{};
        return (&self.agent)[0..1];
    }
};

pub const WireEvent = struct {
    seq: u64,
    kind: []const u8,
    text: []const u8,
    count: u32 = 1,
};

pub const WireDigest = struct { count: u32, latest: []const u8 };

/// A pushed wake-up's facts. Every value is a string: Claude Code's
/// channel `meta` takes nothing else, and its keys must be identifiers.
pub const Meta = struct {
    agent: []const u8,
    name: ?[]const u8 = null,
    /// The kind that decides the wake-up, or `digest`.
    kind: []const u8,
    state: []const u8,
    seq: []const u8,
    record: ?[]const u8 = null,
    job: ?[]const u8 = null,
    conversation: ?[]const u8 = null,
};

/// What a `server` subscription's wake carries besides the events.
pub const Pushed = struct { content: []const u8, meta: Meta };

/// One agent of an `all` wake: how it settled.
pub const Settled = struct {
    agent: []const u8,
    /// The event kind that settled it, else its state, or `closed`.
    outcome: []const u8,
    state: []const u8,
    /// The settling event's text (a done: a preview of its answer).
    text: []const u8 = "",
    /// A done's answer record (agent_read final returns it whole).
    record: ?u64 = null,
};

/// Every server line; `type` is "wake", "all" or "end".
pub const Message = struct {
    type: []const u8,
    agent: []const u8 = "",
    state: []const u8 = "",
    events: []const WireEvent = &.{},
    digest: ?WireDigest = null,
    reason: []const u8 = "",
    /// `server` subscriptions: the pushed text and its facts.
    content: ?[]const u8 = null,
    meta: ?Meta = null,
    /// `all`: every agent waited on.
    results: []const Settled = &.{},
};

/// The `all` line: every agent settled, `results` in the order named.
pub fn encodeAll(arena: std.mem.Allocator, results: []const Settled) ![]const u8 {
    const clipped = try arena.alloc(Settled, results.len);
    for (results, clipped) |r, *o| {
        o.* = r;
        o.text = clip(r.text, WIRE_TEXT_MAX);
    }
    return std.fmt.allocPrint(arena, "{f}\n", .{std.json.fmt(Message{ .type = "all", .results = clipped }, .{ .emit_null_optional_fields = false })});
}

/// The printed `all` wake-up: a header line, then one line per agent.
pub fn formatAll(w: *std.Io.Writer, m: Message) !void {
    try w.print("all {d} agent(s) settled", .{m.results.len});
    for (m.results) |r| {
        try w.print("\n{s} {s}", .{ r.agent, r.outcome });
        const first = firstLine(r.text);
        if (first.len > 0) {
            try w.writeAll(": ");
            try writeClipped(w, first, LINE_TEXT_MAX);
        }
        if (r.record) |id| try w.print(" [record {d}]", .{id});
        if (r.state.len > 0) try w.print(" [state {s}]", .{r.state});
    }
}

pub const clip = events.clip;
const firstLine = events.firstLine;

/// The wake line for `d`, newline-terminated.
/// @param push the pushed text and facts (`server` subscriptions), or null.
pub fn encodeWake(arena: std.mem.Allocator, agent: []const u8, state: vocab.State, d: events.Delivery, q: *const events.Queue, push: ?Pushed) ![]const u8 {
    var msg = try wakeMessage(arena, agent, state, d, q);
    if (push) |p| {
        msg.content = p.content;
        msg.meta = p.meta;
    }
    return std.fmt.allocPrint(arena, "{f}\n", .{std.json.fmt(msg, .{ .emit_null_optional_fields = false })});
}

/// The wake message for `d` (what `formatWake` prints).
pub fn wakeMessage(arena: std.mem.Allocator, agent: []const u8, state: vocab.State, d: events.Delivery, q: *const events.Queue) !Message {
    const evs = try arena.alloc(WireEvent, d.items.len);
    for (d.items, evs) |it, *w| w.* = .{
        .seq = it.event.seq,
        .kind = @tagName(it.kind),
        .text = clip(it.event.text, WIRE_TEXT_MAX),
        .count = it.event.count,
    };
    const digest: ?WireDigest = if (d.digest) |g| .{
        .count = g.count,
        .latest = if (q.bySeq(g.latest_seq)) |ev| clip(ev.text, WIRE_TEXT_MAX) else "",
    } else null;
    return .{ .type = "wake", .agent = agent, .state = @tagName(state), .events = evs, .digest = digest };
}

pub fn encodeEnd(arena: std.mem.Allocator, reason: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{f}\n", .{std.json.fmt(Message{ .type = "end", .reason = reason }, .{ .emit_null_optional_fields = false })});
}

/// One printed line for a wake-up: the agent, the kind that decides it
/// (`vocab.EventKind.outcomeRank`) and its text's first line, then what
/// else arrived with it.
pub fn formatWake(w: *std.Io.Writer, m: Message) !void {
    var best: ?WireEvent = null;
    var best_rank: i32 = -1;
    for (m.events) |ev| {
        const kind = std.meta.stringToEnum(vocab.EventKind, ev.kind) orelse continue;
        const rank: i32 = kind.outcomeRank();
        if (rank > best_rank) {
            best_rank = rank;
            best = ev;
        }
    }
    try w.writeAll(m.agent);
    if (best) |b| {
        try w.print(" {s}", .{b.kind});
        const first = firstLine(b.text);
        if (first.len > 0) {
            try w.writeAll(": ");
            try writeClipped(w, first, LINE_TEXT_MAX);
        }
        if (b.count > 1) try w.print(" (x{d})", .{b.count});
        if (m.events.len > 1) {
            try w.print(" (+{d} more:", .{m.events.len - 1});
            var skipped = false;
            for (m.events) |ev| {
                if (!skipped and ev.seq == b.seq) {
                    skipped = true;
                    continue;
                }
                try w.print(" {s}", .{ev.kind});
            }
            try w.writeAll(")");
        }
    } else try w.writeAll(" digest");
    if (m.digest) |g| {
        try w.print(" [{d} more held back", .{g.count});
        const latest = firstLine(g.latest);
        if (latest.len > 0) {
            try w.writeAll("; latest: ");
            try writeClipped(w, latest, LINE_TEXT_MAX);
        }
        try w.writeAll("]");
    }
    if (m.state.len > 0) try w.print(" [state {s}]", .{m.state});
}

/// `s`, or when longer than `max` its head cut at the last space (a
/// character boundary when it has none nearby) and an explicit `...`: a
/// cut inside a word reads as a value of the line's own fields.
fn writeClipped(w: *std.Io.Writer, s: []const u8, max: usize) !void {
    if (s.len <= max) return w.writeAll(s);
    const head = clip(s, max);
    const space = std.mem.lastIndexOfScalar(u8, head, ' ');
    const cut = if (space) |sp| (if (sp >= max / 2) sp else head.len) else head.len;
    try w.writeAll(std.mem.trimEnd(u8, head[0..cut], " "));
    try w.writeAll(" ...");
}

/// How a waiter on several agents wakes.
pub const Several = enum {
    /// `--any`: the first wake-up of any of them.
    any,
    /// `--all`: once, when every one of them settled.
    all,
};

/// The exact command that waits on `agents` (several: `--any` or `--all`)
/// with `filter`: the running executable, absolute, with every argument
/// shell-quoted. It carries no cursor, so it never goes stale: it wakes
/// for events nobody delivered when it subscribes, however many calls
/// later it runs. `--all` takes no filter (it waits for settling only).
pub fn watchCommand(arena: std.mem.Allocator, exe: []const u8, socket: []const u8, agents: []const []const u8, filter: events.Filter, several: Several) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try shellquote.appendQuoted(&out, arena, exe);
    try out.appendSlice(arena, " mcp " ++ SUBCOMMAND ++ " --socket ");
    try shellquote.appendQuoted(&out, arena, socket);
    if (several == .all) {
        try out.appendSlice(arena, " --all");
    } else {
        if (filter.match) |m| {
            try out.appendSlice(arena, " --match ");
            try shellquote.appendQuoted(&out, arena, m);
        }
        if (filter.messages) try out.appendSlice(arena, " --messages");
        if (filter.retrying) try out.appendSlice(arena, " --retrying");
        if (filter.background) try out.appendSlice(arena, " --background");
        if (agents.len > 1) try out.appendSlice(arena, " --any");
    }
    for (agents) |agent| {
        try out.append(arena, ' ');
        try shellquote.appendQuoted(&out, arena, agent);
    }
    return out.items;
}

// ── the CLI ──────────────────────────────────────────────────────

pub const HELP =
    \\Usage: sketerm mcp agent-wait --socket PATH [--match TEXT] [--messages]
    \\                              [--retrying] [--background] [--follow]
    \\                              [--timeout SECONDS]
    \\                              [--since SEQ] AGENT
    \\       sketerm mcp agent-wait --socket PATH [...] --any AGENT AGENT...
    \\       sketerm mcp agent-wait --socket PATH [--timeout SECONDS] [--json]
    \\                              --all AGENT AGENT...
    \\       sketerm mcp agent-wait (--socket PATH | --parent PID) --server
    \\                              [--follow] [--json] [...]
    \\
    \\Waits for an agent that an MCP server (`sketerm mcp`) runs, and prints
    \\one line per wake-up: the agent, the event that woke it and a short
    \\text. It wakes on done (the agent settled: idle with no subagents or
    \\background tasks), needs_input, error, exited and connection_lost,
    \\plus every completed message with --messages or a message containing
    \\TEXT with --match (rate limited: the rest are summarised), and on the
    \\errors an agent recovers from by itself (retrying) with --retrying.
    \\An agent idle for 30 minutes with background tasks still running
    \\raises a quiet done (with their count) that wakes only --background;
    \\its turn is not settled, and the done once they end wakes everyone.
    \\--any watches several agents and wakes on the first of them. --all
    \\wakes ONCE, when every agent named has settled (done, needs_input, an
    \\error, exited or closed), and prints a line per agent with how it
    \\settled; an agent already settled counts, unless a prompt it was sent
    \\has not settled yet. Exits
    \\after the first wake-up unless --follow; always prints `watch ended:
    \\REASON` when the server goes away, the agents close or --timeout runs
    \\out.
    \\It wakes for events no one has delivered yet when it connects (so the
    \\same command can be run again later), and what it prints is delivered:
    \\the agent_* tools and other waiters do not repeat it. --since SEQ
    \\wakes for every event after SEQ instead, delivered or not.
    \\The agent_* tools hand out the exact command as `watch_command`.
    \\
    \\--server follows every agent of the server, those opened later too,
    \\and prints each wake-up as the text a push delivers: the line, and for
    \\a done the job's answer when it is short (agent_read then does not
    \\repeat it). --parent PID finds the server that process started (how
    \\an MCP client's plugin finds its own server) instead of --socket.
    \\--json prints every server line as it arrives, one JSON object each.
    \\
    \\Exit status: 0 woken or ended normally, 1 the server went away (or
    \\--parent found none, or several), 2 bad usage, 3 timed out.
    \\
;

pub const Cli = struct {
    socket: ?[]const u8 = null,
    agent_buf: [MAX_ANY][]const u8 = undefined,
    agent_count: usize = 0,
    any: bool = false,
    all: bool = false,
    match: ?[]const u8 = null,
    messages: bool = false,
    retrying: bool = false,
    background: bool = false,
    follow: bool = false,
    timeout_s: ?u32 = null,
    since: ?u64 = null,
    server: bool = false,
    /// `--parent`: find the server this process started.
    parent: ?i32 = null,
    json: bool = false,
    help: bool = false,

    pub const ParseError = error{ UnknownFlag, MissingValue, BadNumber, ExtraArgument, Conflicting };

    pub fn agents(self: *const Cli) []const []const u8 {
        return self.agent_buf[0..self.agent_count];
    }

    pub fn parse(args: []const []const u8) ParseError!Cli {
        var o = Cli{};
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            const eql = std.mem.eql;
            if (eql(u8, a, "--help") or eql(u8, a, "-h")) {
                o.help = true;
            } else if (eql(u8, a, "--messages")) {
                o.messages = true;
            } else if (eql(u8, a, "--retrying")) {
                o.retrying = true;
            } else if (eql(u8, a, "--background")) {
                o.background = true;
            } else if (eql(u8, a, "--any")) {
                o.any = true;
            } else if (eql(u8, a, "--all")) {
                o.all = true;
            } else if (eql(u8, a, "--follow")) {
                o.follow = true;
            } else if (eql(u8, a, "--server")) {
                o.server = true;
            } else if (eql(u8, a, "--json")) {
                o.json = true;
            } else if (eql(u8, a, "--socket") or eql(u8, a, "--match") or eql(u8, a, "--timeout") or eql(u8, a, "--since") or eql(u8, a, "--parent")) {
                if (i + 1 >= args.len) return error.MissingValue;
                i += 1;
                const v = args[i];
                if (eql(u8, a, "--socket")) o.socket = v;
                if (eql(u8, a, "--match")) o.match = v;
                if (eql(u8, a, "--timeout")) o.timeout_s = std.fmt.parseInt(u32, v, 10) catch return error.BadNumber;
                if (eql(u8, a, "--since")) o.since = std.fmt.parseInt(u64, v, 10) catch return error.BadNumber;
                if (eql(u8, a, "--parent")) o.parent = std.fmt.parseInt(i32, v, 10) catch return error.BadNumber;
            } else if (a.len > 0 and a[0] == '-') {
                return error.UnknownFlag;
            } else {
                if (o.agent_count == MAX_ANY) return error.ExtraArgument;
                o.agent_buf[o.agent_count] = a;
                o.agent_count += 1;
            }
        }
        // Several agents only with --any or --all (a typo is not a second
        // agent); --server names none, it watches them all. --all wakes
        // once and waits for settling only: no filter, no --follow.
        if (o.all and (o.any or o.server or o.follow or o.messages or o.retrying or o.background or o.match != null or o.since != null)) return error.Conflicting;
        if (o.agent_count > 1 and !o.any and !o.all) return error.ExtraArgument;
        if (o.server and o.agent_count > 0) return error.ExtraArgument;
        return o;
    }
};

fn say(fd: c_int, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(fd, bytes[off..].ptr, bytes.len - off);
        if (n <= 0) {
            if (n < 0 and std.posix.errno(n) == .INTR) continue;
            return;
        }
        off += @intCast(n);
    }
}

fn ended(reason: []const u8, status: u8) u8 {
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "watch ended: {s}\n", .{clip(reason, 400)}) catch "watch ended\n";
    say(1, line);
    return status;
}

/// `sketerm mcp agent-wait ...`.
/// @return the process exit status.
pub fn cli(allocator: std.mem.Allocator, args: []const []const u8) u8 {
    const o = Cli.parse(args) catch |err| {
        const msg = switch (err) {
            error.UnknownFlag => "agent-wait: unknown flag (see --help)\n",
            error.MissingValue => "agent-wait: flag needs a value\n",
            error.BadNumber => "agent-wait: --timeout, --since and --parent take a whole number\n",
            error.ExtraArgument => std.fmt.comptimePrint("agent-wait: exactly one AGENT, or --any/--all with up to {d}, or none with --server\n", .{MAX_ANY}),
            error.Conflicting => "agent-wait: --all wakes once on settling: it takes no --any, --server, --follow, --since or filter\n",
        };
        say(2, msg);
        return 2;
    };
    if (o.help) {
        say(1, HELP);
        return 0;
    }
    if (o.socket == null and (o.parent == null or !o.server)) {
        say(2, "agent-wait: --socket is required (the agent_* tools return the exact command as watch_command), or --parent with --server\n");
        return 2;
    }
    const names = o.agents();
    if (names.len == 0 and !o.server) {
        say(2, "agent-wait: name the AGENT to wait for\n");
        return 2;
    }
    platform.ignoreSigpipe();
    var found: ?[]u8 = null;
    defer if (found) |f| allocator.free(f);
    const sock = o.socket orelse sock: {
        found = registry.agentSocketOf(allocator, o.parent.?) catch |err| return ended(switch (err) {
            error.Ambiguous => "several sketerm MCP servers were started by that process",
            else => "no sketerm MCP server with an agent socket was started by that process",
        }, 1);
        break :sock found.?;
    };

    const fd = platform.socketCloexec(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (fd < 0) return ended("cannot create a socket", 1);
    defer _ = c.close(fd);
    var addr: c.struct_sockaddr_un = undefined;
    @import("../mux/sockpath.zig").fillSockaddrUn(&addr, sock) catch return ended("socket path too long", 1);
    if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0)
        return ended("the MCP server is not running (cannot connect to its agent socket)", 1);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const sub = Subscribe{
        .agent = if (names.len > 0) names[0] else "",
        .agents = if (names.len > 1) names else &.{},
        .match = o.match,
        .messages = o.messages,
        .retrying = o.retrying,
        .background = o.background,
        .follow = o.follow,
        .since = o.since,
        .server = o.server,
        .all = o.all,
    };
    const line = std.fmt.allocPrint(arena, "{f}\n", .{std.json.fmt(sub, .{ .emit_null_optional_fields = false })}) catch return ended("out of memory", 1);
    say(fd, line);

    const deadline: ?i64 = if (o.timeout_s) |s| clock.nowMs() + @as(i64, s) * 1000 else null;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    while (true) {
        while (std.mem.indexOfScalar(u8, buf.items, '\n')) |nl| {
            var line_arena = std.heap.ArenaAllocator.init(allocator);
            defer line_arena.deinit();
            const la = line_arena.allocator();
            const raw_line = la.dupe(u8, buf.items[0..nl]) catch return ended("out of memory", 1);
            std.mem.copyForwards(u8, buf.items[0 .. buf.items.len - nl - 1], buf.items[nl + 1 ..]);
            buf.shrinkRetainingCapacity(buf.items.len - nl - 1);
            const m = std.json.parseFromSliceLeaky(Message, la, raw_line, .{ .ignore_unknown_fields = true }) catch continue;
            const is_end = std.mem.eql(u8, m.type, "end");
            if (o.json) {
                say(1, raw_line);
                say(1, "\n");
                if (is_end or !o.follow) return 0;
                continue;
            }
            if (is_end) return ended(m.reason, 0);
            var aw: std.Io.Writer.Allocating = .init(la);
            if (std.mem.eql(u8, m.type, "all")) {
                formatAll(&aw.writer, m) catch continue;
            } else if (std.mem.eql(u8, m.type, "wake")) {
                if (m.content) |text| aw.writer.writeAll(text) catch continue else formatWake(&aw.writer, m) catch continue;
                // A server that predates --all read the line as --any.
                if (o.all) aw.writer.writeAll("\n(this MCP server predates --all: it woke on the first agent only)") catch continue;
            } else continue;
            aw.writer.writeAll("\n") catch continue;
            say(1, aw.written());
            if (!o.follow) return 0;
        }
        var wait_ms: c_int = -1;
        if (deadline) |d| {
            const left = d - clock.nowMs();
            if (left <= 0) {
                var tb: [64]u8 = undefined;
                return ended(std.fmt.bufPrint(&tb, "timeout after {d}s", .{o.timeout_s.?}) catch "timeout", 3);
            }
            wait_ms = @intCast(@min(left, 60_000));
        }
        var pfd = c.struct_pollfd{ .fd = fd, .events = c.POLLIN, .revents = 0 };
        const rc = c.poll(&pfd, 1, wait_ms);
        if (rc < 0) {
            if (std.posix.errno(rc) == .INTR) continue;
            return ended("poll failed", 1);
        }
        if (rc == 0) continue;
        var tmp: [8192]u8 = undefined;
        const n = c.read(fd, &tmp, tmp.len);
        if (n < 0) {
            if (std.posix.errno(n) == .INTR) continue;
            return ended("the MCP server went away", 1);
        }
        if (n == 0) return ended("the MCP server went away", 1);
        buf.appendSlice(allocator, tmp[0..@intCast(n)]) catch return ended("out of memory", 1);
    }
}

// ── tests ────────────────────────────────────────────────────────

const t = std.testing;

test "cli arguments: flags anywhere, one agent, numbers checked" {
    const o = try Cli.parse(&.{ "--socket", "/run/x.sock", "claude-1", "--match", "all done", "--messages", "--follow", "--timeout", "30", "--since", "7" });
    try t.expectEqualStrings("/run/x.sock", o.socket.?);
    try t.expectEqualStrings("claude-1", o.agents()[0]);
    try t.expectEqual(@as(usize, 1), o.agents().len);
    try t.expectEqualStrings("all done", o.match.?);
    try t.expect(o.messages and o.follow and !o.retrying);
    try t.expectEqual(@as(u32, 30), o.timeout_s.?);
    try t.expectEqual(@as(u64, 7), o.since.?);
    try t.expectError(error.ExtraArgument, Cli.parse(&.{ "a", "b" }));
    // --any takes several, anywhere among the flags.
    const any = try Cli.parse(&.{ "--socket", "s", "claude-1", "--any", "opencode-2", "--retrying", "claude-3" });
    try t.expectEqual(@as(usize, 3), any.agents().len);
    try t.expectEqualStrings("claude-3", any.agents()[2]);
    try t.expect(any.any and any.retrying);
    try t.expectError(error.BadNumber, Cli.parse(&.{ "--timeout", "soon" }));
    try t.expectError(error.MissingValue, Cli.parse(&.{"--match"}));
    try t.expectError(error.UnknownFlag, Cli.parse(&.{"--bogus"}));
    // --server follows them all: it names none, and --parent may replace --socket.
    const srv = try Cli.parse(&.{ "--server", "--follow", "--json", "--parent", "4242" });
    try t.expect(srv.server and srv.follow and srv.json and srv.socket == null);
    try t.expectEqual(@as(?i32, 4242), srv.parent);
    try t.expectError(error.ExtraArgument, Cli.parse(&.{ "--server", "claude-1" }));
    try t.expectError(error.BadNumber, Cli.parse(&.{ "--parent", "me" }));
}

test "a server subscription and its pushed wake round-trip" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const line = try std.fmt.allocPrint(a, "{f}", .{std.json.fmt(Subscribe{ .server = true, .follow = true }, .{ .emit_null_optional_fields = false })});
    const back = try std.json.parseFromSliceLeaky(Subscribe, a, line, .{ .ignore_unknown_fields = true });
    try t.expect(back.server and back.follow and back.names().len == 0);
    var q = events.Queue.init(t.allocator, .{});
    defer q.deinit();
    _ = try q.push(0, .done, null, "ok", "");
    var cur: events.Cursor = .{};
    const d = (try cur.take(&q, .{}, 0, a)).?;
    const wake = try encodeWake(a, "claude-1", .idle, d, &q, .{ .content = "claude-1 done: ok [state idle]\n\nok", .meta = .{ .agent = "claude-1", .kind = "done", .state = "idle", .seq = "1" } });
    const m = try std.json.parseFromSliceLeaky(Message, a, wake[0 .. wake.len - 1], .{ .ignore_unknown_fields = true });
    try t.expectEqualStrings("claude-1 done: ok [state idle]\n\nok", m.content.?);
    try t.expectEqualStrings("done", m.meta.?.kind);
}

test "the watch command round-trips through the cli grammar and bakes in no cursor" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cmd = try watchCommand(a, "/usr/bin/sketerm", "/run/user/1/sketerm/mcp-tmp-9/agents.sock", &.{"claude-1"}, .{ .match = "it's done", .messages = true }, .any);
    try t.expectEqualStrings("/usr/bin/sketerm mcp agent-wait --socket /run/user/1/sketerm/mcp-tmp-9/agents.sock --match 'it'\\''s done' --messages claude-1", cmd);
    // A cursor baked in went stale with the next tool call: a reused
    // command woke on an event the assistant already had.
    try t.expect(std.mem.indexOf(u8, cmd, "--since") == null);
    // What sh would hand the cli after `mcp agent-wait`.
    const o = try Cli.parse(&.{ "--socket", "/run/user/1/sketerm/mcp-tmp-9/agents.sock", "--match", "it's done", "--messages", "claude-1" });
    try t.expectEqualStrings("it's done", o.match.?);
    try t.expect(o.since == null);
    // --since stays an explicit option.
    try t.expectEqual(@as(u64, 12), (try Cli.parse(&.{ "--since", "12", "claude-1" })).since.?);

    // Several agents: --any, and the subscribe line names them all while
    // `agent` keeps the first for a server that predates `agents`.
    const many = try watchCommand(a, "/x/sketerm-mcp", "/s.sock", &.{ "claude-1", "opencode-1" }, .{ .retrying = true, .background = true }, .any);
    try t.expectEqualStrings("/x/sketerm-mcp mcp agent-wait --socket /s.sock --retrying --background --any claude-1 opencode-1", many);
    const p = try Cli.parse(&.{ "--socket", "/s.sock", "--retrying", "--background", "--any", "claude-1", "opencode-1" });
    try t.expect(p.background);
    const sub = Subscribe{ .agent = p.agents()[0], .agents = p.agents(), .retrying = p.retrying, .background = p.background };
    const line = try std.fmt.allocPrint(a, "{f}", .{std.json.fmt(sub, .{ .emit_null_optional_fields = false })});
    const back = try std.json.parseFromSliceLeaky(Subscribe, a, line, .{ .ignore_unknown_fields = true });
    try t.expectEqual(@as(usize, 2), back.names().len);
    try t.expectEqualStrings("opencode-1", back.names()[1]);
    try t.expect(back.retrying and back.background);
    // An old CLI's line: one agent.
    const old = try std.json.parseFromSliceLeaky(Subscribe, a, "{\"agent\":\"claude-1\"}", .{ .ignore_unknown_fields = true });
    try t.expectEqual(@as(usize, 1), old.names().len);

    // --all: no filter rides along, and the grammar takes it back.
    const all = try watchCommand(a, "/x/sketerm", "/s.sock", &.{ "claude-1", "opencode-1" }, .{ .messages = true }, .all);
    try t.expectEqualStrings("/x/sketerm mcp agent-wait --socket /s.sock --all claude-1 opencode-1", all);
    const pa = try Cli.parse(&.{ "--socket", "/s.sock", "--all", "claude-1", "opencode-1" });
    try t.expect(pa.all and !pa.any);
    try t.expectEqual(@as(usize, 2), pa.agents().len);
    try t.expectError(error.Conflicting, Cli.parse(&.{ "--all", "--follow", "a", "b" }));
    try t.expectError(error.Conflicting, Cli.parse(&.{ "--all", "--any", "a", "b" }));
    try t.expectError(error.Conflicting, Cli.parse(&.{ "--all", "--messages", "a" }));
    try t.expectError(error.Conflicting, Cli.parse(&.{ "--all", "--background", "a", "b" }));
}

test "an all wake: one line, then one line per agent with how it settled" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const line = try encodeAll(a, &.{
        .{ .agent = "claude-1", .outcome = "done", .state = "idle", .text = "All green.\nDetails.", .record = 12 },
        .{ .agent = "opencode-2", .outcome = "needs_input", .state = "waiting_user", .text = "permission: bash" },
        .{ .agent = "claude-3", .outcome = "closed", .state = "" },
    });
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, line, "\n"));
    const m = try std.json.parseFromSliceLeaky(Message, a, line[0 .. line.len - 1], .{ .ignore_unknown_fields = true });
    try t.expectEqualStrings("all", m.type);
    var aw: std.Io.Writer.Allocating = .init(a);
    try formatAll(&aw.writer, m);
    try t.expectEqualStrings("all 3 agent(s) settled\nclaude-1 done: All green. [record 12] [state idle]\nopencode-2 needs_input: permission: bash [state waiting_user]\nclaude-3 closed", aw.written());
    // The subscribe line carries all beside agents; an old line has none.
    const sub = try std.json.parseFromSliceLeaky(Subscribe, a, "{\"agent\":\"a\",\"agents\":[\"a\",\"b\"],\"all\":true}", .{ .ignore_unknown_fields = true });
    try t.expect(sub.all and sub.names().len == 2);
}

test "wake lines: encode, parse, and one compact printed line" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var q = events.Queue.init(t.allocator, .{ .burst = 1 });
    defer q.deinit();
    _ = try q.push(0, .message, null, "first\nmore", "");
    _ = try q.push(0, .message, null, "second", "");
    _ = try q.push(0, .done, null, "All done.\nDetails follow.", "");
    var cur: events.Cursor = .{};
    const d = (try cur.take(&q, .{ .messages = true }, 0, a)).?;
    const line = try encodeWake(a, "claude-1", .idle, d, &q, null);
    try t.expect(std.mem.endsWith(u8, line, "}\n"));
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, line, "\n"));
    const m = try std.json.parseFromSliceLeaky(Message, a, line[0 .. line.len - 1], .{ .ignore_unknown_fields = true });
    try t.expectEqualStrings("wake", m.type);
    try t.expectEqual(@as(usize, 2), m.events.len);
    var aw: std.Io.Writer.Allocating = .init(a);
    try formatWake(&aw.writer, m);
    try t.expectEqualStrings("claude-1 done: All done. (+1 more: message) [1 more held back; latest: second] [state idle]", aw.written());
    // A long digest text is cut between words with an explicit ellipsis,
    // never inside a value its own brackets would make look like a field.
    const long = "Waiting for the zenit red run; it reports " ++ "[state \"idle\"] " ** 12;
    var aw2: std.Io.Writer.Allocating = .init(a);
    try formatWake(&aw2.writer, .{ .type = "wake", .agent = "claude-1", .state = "idle", .digest = .{ .count = 2, .latest = long } });
    const out = aw2.written();
    try t.expect(std.mem.indexOf(u8, out, " ...] [state idle]") != null);
    try t.expect(std.mem.indexOf(u8, out, "\"idl]") == null);
    try t.expect(std.mem.indexOf(u8, out, "\"idl ...") == null);

    const end = try encodeEnd(a, "agent closed");
    const e = try std.json.parseFromSliceLeaky(Message, a, end[0 .. end.len - 1], .{ .ignore_unknown_fields = true });
    try t.expectEqualStrings("end", e.type);
    try t.expectEqualStrings("agent closed", e.reason);
    try t.expectEqualStrings("ab", clip("ab\xc3\xa9", 3));
}
