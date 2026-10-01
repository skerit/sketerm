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
//! `{"agent":"claude-1","match":"x","messages":true,"retrying":false,"follow":false,"since":7}`,
//! with `"agents":[...]` added for `--any` (`agent` stays the first, so a
//! server that predates `agents` watches that one). Server -> client:
//! `{"type":"wake","agent":...}` per wake-up and a final
//! `{"type":"end","reason":"..."}` before it closes.
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
    follow: bool = false,
    /// Wake for events after this seq, delivered or not; null = for what
    /// nobody has delivered yet.
    since: ?u64 = null,

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

/// Every server line; `type` is "wake" or "end".
pub const Message = struct {
    type: []const u8,
    agent: []const u8 = "",
    state: []const u8 = "",
    events: []const WireEvent = &.{},
    digest: ?WireDigest = null,
    reason: []const u8 = "",
};

pub const clip = events.clip;
const firstLine = events.firstLine;

/// The wake line for `d`, newline-terminated.
pub fn encodeWake(arena: std.mem.Allocator, agent: []const u8, state: vocab.State, d: events.Delivery, q: *const events.Queue) ![]const u8 {
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
    const msg = Message{ .type = "wake", .agent = agent, .state = @tagName(state), .events = evs, .digest = digest };
    return std.fmt.allocPrint(arena, "{f}\n", .{std.json.fmt(msg, .{ .emit_null_optional_fields = false })});
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
        if (first.len > 0) try w.print(": {s}", .{clip(first, LINE_TEXT_MAX)});
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
        if (latest.len > 0) try w.print("; latest: {s}", .{clip(latest, LINE_TEXT_MAX)});
        try w.writeAll("]");
    }
    if (m.state.len > 0) try w.print(" [state {s}]", .{m.state});
}

/// The exact command that waits on `agents` (several: `--any`, the first
/// wake-up of any) with `filter`: the running executable, absolute, with
/// every argument shell-quoted. It carries no cursor, so it never goes
/// stale: it wakes for events nobody delivered when it subscribes,
/// however many calls later it runs.
pub fn watchCommand(arena: std.mem.Allocator, exe: []const u8, socket: []const u8, agents: []const []const u8, filter: events.Filter) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try shellquote.appendQuoted(&out, arena, exe);
    try out.appendSlice(arena, " mcp " ++ SUBCOMMAND ++ " --socket ");
    try shellquote.appendQuoted(&out, arena, socket);
    if (filter.match) |m| {
        try out.appendSlice(arena, " --match ");
        try shellquote.appendQuoted(&out, arena, m);
    }
    if (filter.messages) try out.appendSlice(arena, " --messages");
    if (filter.retrying) try out.appendSlice(arena, " --retrying");
    if (agents.len > 1) try out.appendSlice(arena, " --any");
    for (agents) |agent| {
        try out.append(arena, ' ');
        try shellquote.appendQuoted(&out, arena, agent);
    }
    return out.items;
}

// ── the CLI ──────────────────────────────────────────────────────

pub const HELP =
    \\Usage: sketerm mcp agent-wait --socket PATH [--match TEXT] [--messages]
    \\                              [--retrying] [--follow] [--timeout SECONDS]
    \\                              [--since SEQ] AGENT
    \\       sketerm mcp agent-wait --socket PATH [...] --any AGENT AGENT...
    \\
    \\Waits for an agent that an MCP server (`sketerm mcp`) runs, and prints
    \\one line per wake-up: the agent, the event that woke it and a short
    \\text. It wakes on done (the agent settled: idle with no subagents or
    \\background tasks), needs_input, error, exited and connection_lost,
    \\plus every completed message with --messages or a message containing
    \\TEXT with --match (rate limited: the rest are summarised), and on the
    \\errors an agent recovers from by itself (retrying) with --retrying.
    \\--any watches several agents and wakes on the first of them. Exits
    \\after the first wake-up unless --follow; always prints `watch ended:
    \\REASON` when the server goes away, the agents close or --timeout runs
    \\out.
    \\It wakes for events no one has delivered yet when it connects (so the
    \\same command can be run again later), and what it prints is delivered:
    \\the agent_* tools and other waiters do not repeat it. --since SEQ
    \\wakes for every event after SEQ instead, delivered or not.
    \\The agent_* tools hand out the exact command as `watch_command`.
    \\
    \\Exit status: 0 woken or ended normally, 1 the server went away,
    \\2 bad usage, 3 timed out.
    \\
;

pub const Cli = struct {
    socket: ?[]const u8 = null,
    agent_buf: [MAX_ANY][]const u8 = undefined,
    agent_count: usize = 0,
    any: bool = false,
    match: ?[]const u8 = null,
    messages: bool = false,
    retrying: bool = false,
    follow: bool = false,
    timeout_s: ?u32 = null,
    since: ?u64 = null,
    help: bool = false,

    pub const ParseError = error{ UnknownFlag, MissingValue, BadNumber, ExtraArgument };

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
            } else if (eql(u8, a, "--any")) {
                o.any = true;
            } else if (eql(u8, a, "--follow")) {
                o.follow = true;
            } else if (eql(u8, a, "--socket") or eql(u8, a, "--match") or eql(u8, a, "--timeout") or eql(u8, a, "--since")) {
                if (i + 1 >= args.len) return error.MissingValue;
                i += 1;
                const v = args[i];
                if (eql(u8, a, "--socket")) o.socket = v;
                if (eql(u8, a, "--match")) o.match = v;
                if (eql(u8, a, "--timeout")) o.timeout_s = std.fmt.parseInt(u32, v, 10) catch return error.BadNumber;
                if (eql(u8, a, "--since")) o.since = std.fmt.parseInt(u64, v, 10) catch return error.BadNumber;
            } else if (a.len > 0 and a[0] == '-') {
                return error.UnknownFlag;
            } else {
                if (o.agent_count == MAX_ANY) return error.ExtraArgument;
                o.agent_buf[o.agent_count] = a;
                o.agent_count += 1;
            }
        }
        // Several agents only with --any (a typo is not a second agent).
        if (o.agent_count > 1 and !o.any) return error.ExtraArgument;
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
            error.BadNumber => "agent-wait: --timeout and --since take a whole number\n",
            error.ExtraArgument => std.fmt.comptimePrint("agent-wait: exactly one AGENT, or --any with up to {d}\n", .{MAX_ANY}),
        };
        say(2, msg);
        return 2;
    };
    if (o.help) {
        say(1, HELP);
        return 0;
    }
    const sock = o.socket orelse {
        say(2, "agent-wait: --socket is required (the agent_* tools return the exact command as watch_command)\n");
        return 2;
    };
    const names = o.agents();
    if (names.len == 0) {
        say(2, "agent-wait: name the AGENT to wait for\n");
        return 2;
    }
    platform.ignoreSigpipe();

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
        .agent = names[0],
        .agents = if (names.len > 1) names else &.{},
        .match = o.match,
        .messages = o.messages,
        .retrying = o.retrying,
        .follow = o.follow,
        .since = o.since,
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
            const parsed = std.json.parseFromSliceLeaky(Message, la, buf.items[0..nl], .{ .ignore_unknown_fields = true }) catch null;
            std.mem.copyForwards(u8, buf.items[0 .. buf.items.len - nl - 1], buf.items[nl + 1 ..]);
            buf.shrinkRetainingCapacity(buf.items.len - nl - 1);
            const m = parsed orelse continue;
            if (std.mem.eql(u8, m.type, "end")) return ended(m.reason, 0);
            if (!std.mem.eql(u8, m.type, "wake")) continue;
            var aw: std.Io.Writer.Allocating = .init(la);
            formatWake(&aw.writer, m) catch continue;
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
}

test "the watch command round-trips through the cli grammar and bakes in no cursor" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cmd = try watchCommand(a, "/usr/bin/sketerm", "/run/user/1/sketerm/mcp-tmp-9/agents.sock", &.{"claude-1"}, .{ .match = "it's done", .messages = true });
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
    const many = try watchCommand(a, "/x/sketerm-mcp", "/s.sock", &.{ "claude-1", "opencode-1" }, .{ .retrying = true });
    try t.expectEqualStrings("/x/sketerm-mcp mcp agent-wait --socket /s.sock --retrying --any claude-1 opencode-1", many);
    const p = try Cli.parse(&.{ "--socket", "/s.sock", "--retrying", "--any", "claude-1", "opencode-1" });
    const sub = Subscribe{ .agent = p.agents()[0], .agents = p.agents(), .retrying = p.retrying };
    const line = try std.fmt.allocPrint(a, "{f}", .{std.json.fmt(sub, .{ .emit_null_optional_fields = false })});
    const back = try std.json.parseFromSliceLeaky(Subscribe, a, line, .{ .ignore_unknown_fields = true });
    try t.expectEqual(@as(usize, 2), back.names().len);
    try t.expectEqualStrings("opencode-1", back.names()[1]);
    try t.expect(back.retrying);
    // An old CLI's line: one agent.
    const old = try std.json.parseFromSliceLeaky(Subscribe, a, "{\"agent\":\"claude-1\"}", .{ .ignore_unknown_fields = true });
    try t.expectEqual(@as(usize, 1), old.names().len);
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
    const line = try encodeWake(a, "claude-1", .idle, d, &q);
    try t.expect(std.mem.endsWith(u8, line, "}\n"));
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, line, "\n"));
    const m = try std.json.parseFromSliceLeaky(Message, a, line[0 .. line.len - 1], .{ .ignore_unknown_fields = true });
    try t.expectEqualStrings("wake", m.type);
    try t.expectEqual(@as(usize, 2), m.events.len);
    var aw: std.Io.Writer.Allocating = .init(a);
    try formatWake(&aw.writer, m);
    try t.expectEqualStrings("claude-1 done: All done. (+1 more: message) [1 more held back; latest: second] [state idle]", aw.written());

    const end = try encodeEnd(a, "agent closed");
    const e = try std.json.parseFromSliceLeaky(Message, a, end[0 .. end.len - 1], .{ .ignore_unknown_fields = true });
    try t.expectEqualStrings("end", e.type);
    try t.expectEqualStrings("agent closed", e.reason);
    try t.expectEqualStrings("ab", clip("ab\xc3\xa9", 3));
}
