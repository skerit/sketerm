//! `sketerm mcp agents`: how many sub-agents the calling assistant's
//! sketerm MCP servers run, and how they are doing, for a status line.
//!
//! The servers are found by walking this process's own ancestry
//! (`platform.parentOf`): a Claude Code status line runs as claude -> sh ->
//! node -> sketerm, and every server records the process that started it
//! (`ppid` in `mcp_registry`). Only files are read: no socket, no daemon.
//!
//! `--format json` is a documented contract (docs/mcp.md "Sub-agents"):
//! `{"total","by_attention":{<every vocab.Attention>},"most_urgent","agents":
//! [{"id","app","host","attention","state"}]}`. `host` null = this machine;
//! `attention`/`state` null = unknown (a server that predates publishing
//! them, or a name this build does not know). Every format renders the
//! same `Summary`.

const std = @import("std");
const c = @import("../c.zig").c;
const fdio = @import("../util/fdio.zig");
const platform = @import("../util/platform.zig");
const vocab = @import("../agent/vocab.zig");
const registry = @import("mcp_registry.zig");
const sshroute = @import("../mux/sshroute.zig");
const agentglance = @import("agentglance.zig");
const Attention = vocab.Attention;

/// The argv word after `mcp` that selects this command.
pub const SUBCOMMAND = "agents";

/// The default `line` becomes `compact` when `COLUMNS` is below this.
pub const COMPACT_BELOW_COLUMNS = 100;

/// Ancestors walked at most (a cycle or a runaway chain ends the walk).
const MAX_ANCESTRY = 64;

pub const Format = enum { line, compact, json };

pub const Row = struct {
    id: []const u8,
    app: []const u8,
    /// Null = this machine.
    host: ?[]const u8,
    attention: ?Attention,
    state: ?vocab.State,
};

pub const Summary = struct {
    tally: agentglance.Tally = .{},
    rows: []const Row = &.{},
};

/// The parents of `start`, nearest first, up to (not including) init.
pub fn ancestry(buf: []c.pid_t, start: c.pid_t, parentOf: *const fn (c.pid_t) ?c.pid_t) []c.pid_t {
    var n: usize = 0;
    var pid = start;
    while (n < buf.len) {
        const parent = parentOf(pid) orelse break;
        if (parent <= 1 or parent == pid) break;
        if (std.mem.indexOfScalar(c.pid_t, buf[0..n], parent) != null) break;
        buf[n] = parent;
        n += 1;
        pid = parent;
    }
    return buf[0..n];
}

/// The summary of the agents of every server started by one of `starters`.
/// A server that predates publishing its agents contributes none.
pub fn summarize(arena: std.mem.Allocator, entries: []const registry.Entry, starters: []const c.pid_t) !Summary {
    var s: Summary = .{};
    var rows: std.ArrayList(Row) = .empty;
    for (entries) |e| {
        if (e.ppid <= 0 or std.mem.indexOfScalar(c.pid_t, starters, e.ppid) == null) continue;
        for (e.agents orelse continue) |ag| {
            const st = ag.stateFact();
            const att = ag.attentionOrState();
            const host: ?[]const u8 = if (sshroute.Location.parse(ag.location)) |loc| switch (loc) {
                .host => |h| h,
                .instance, .user => null,
            } else null;
            try rows.append(arena, .{ .id = ag.id, .app = ag.app, .host = host, .attention = att, .state = st });
            s.tally.add(att);
        }
    }
    s.rows = rows.items;
    return s;
}

const Ansi = struct {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const dim = "\x1b[2;37m";

    fn of(a: Attention) []const u8 {
        return switch (a) {
            .working => "\x1b[1;34m",
            .needs_input => "\x1b[1;33m",
            .lost => "\x1b[1;31m",
            .idle => dim,
        };
    }
};

/// The attentions in summary order (`Attention.summaryRank`).
fn summaryOrder() [std.enums.values(Attention).len]Attention {
    var out: [std.enums.values(Attention).len]Attention = undefined;
    for (std.enums.values(Attention)) |a| out[a.summaryRank()] = a;
    return out;
}

/// `line` or `compact`; nothing at all when there are no agents.
pub fn renderText(w: *std.Io.Writer, s: *const Summary, format: Format, color: bool, hosts: bool) !void {
    if (s.tally.total == 0) return;
    const compact = format == .compact;
    const reset = if (color) Ansi.reset else "";
    const dim = if (color) Ansi.dim else "";
    try w.print("{s}{s}{s}", .{ if (color) Ansi.bold else "", if (compact) "ag" else "agents", reset });
    var first = true;
    for (summaryOrder()) |a| {
        const n = s.tally.count(a);
        if (n == 0) continue;
        try sep(w, &first, compact, dim, reset);
        const col = if (color) Ansi.of(a) else "";
        if (compact) try w.print("{s}{d}{s}{s}", .{ col, n, a.glyph(), reset }) else try w.print("{s}{d} {s}{s}", .{ col, n, a.label(), reset });
    }
    const unknown = s.tally.unknown();
    if (unknown > 0) {
        try sep(w, &first, compact, dim, reset);
        try w.print("{s}{d}{s}{s}", .{ dim, unknown, if (compact) "~" else " unknown", reset });
    }
    if (hosts and !compact) try renderHosts(w, s, dim, reset);
    try w.writeAll("\n");
}

fn sep(w: *std.Io.Writer, first: *bool, compact: bool, dim: []const u8, reset: []const u8) !void {
    if (compact or first.*) {
        try w.writeAll(" ");
    } else try w.print(" {s}\u{00B7}{s} ", .{ dim, reset });
    first.* = false;
}

/// ` (dalaran 2, peregrin 1)`, hosts in first-seen order; this machine is `local`.
fn renderHosts(w: *std.Io.Writer, s: *const Summary, dim: []const u8, reset: []const u8) !void {
    try w.print(" {s}(", .{dim});
    for (s.rows, 0..) |r, i| {
        const seen_before = for (s.rows[0..i]) |p| {
            if (sameHost(p.host, r.host)) break true;
        } else false;
        if (seen_before) continue;
        var n: u32 = 0;
        for (s.rows) |q| if (sameHost(q.host, r.host)) {
            n += 1;
        };
        if (i > 0) try w.writeAll(", ");
        try w.print("{s} {d}", .{ r.host orelse "local", n });
    }
    try w.print("){s}", .{reset});
}

fn sameHost(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

/// The JSON contract (module doc); one line.
pub fn renderJson(w: *std.Io.Writer, s: *const Summary) !void {
    var j: std.json.Stringify = .{ .writer = w };
    try j.beginObject();
    try j.objectField("total");
    try j.write(s.tally.total);
    try j.objectField("by_attention");
    try j.beginObject();
    for (std.enums.values(Attention)) |a| {
        try j.objectField(@tagName(a));
        try j.write(s.tally.count(a));
    }
    try j.endObject();
    try j.objectField("most_urgent");
    try j.write(if (s.tally.mostUrgent()) |a| @tagName(a) else null);
    try j.objectField("agents");
    try j.beginArray();
    for (s.rows) |r| {
        try j.beginObject();
        try j.objectField("id");
        try j.write(r.id);
        try j.objectField("app");
        try j.write(r.app);
        try j.objectField("host");
        try j.write(r.host);
        try j.objectField("attention");
        try j.write(if (r.attention) |a| @tagName(a) else null);
        try j.objectField("state");
        try j.write(if (r.state) |x| @tagName(x) else null);
        try j.endObject();
    }
    try j.endArray();
    try j.endObject();
    try w.writeAll("\n");
}

pub const Cli = struct {
    /// Null = not given: `line`, or `compact` in a narrow terminal.
    format: ?Format = null,
    parent: ?c.pid_t = null,
    hosts: bool = false,
    color: bool = true,
    help: bool = false,

    pub fn parse(args: []const []const u8) error{ UnknownFlag, MissingValue, BadValue }!Cli {
        var o: Cli = .{};
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            const eql = std.mem.eql;
            if (eql(u8, a, "--help") or eql(u8, a, "-h")) {
                o.help = true;
            } else if (eql(u8, a, "--hosts")) {
                o.hosts = true;
            } else if (eql(u8, a, "--no-color")) {
                o.color = false;
            } else if (eql(u8, a, "--format") or eql(u8, a, "--parent")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                const v = args[i];
                if (eql(u8, a, "--format")) {
                    o.format = std.meta.stringToEnum(Format, v) orelse return error.BadValue;
                } else {
                    o.parent = std.fmt.parseInt(c.pid_t, v, 10) catch return error.BadValue;
                    if (o.parent.? <= 0) return error.BadValue;
                }
            } else return error.UnknownFlag;
        }
        return o;
    }

    /// The format to print: an explicit one, else by `columns` (`$COLUMNS`).
    pub fn effectiveFormat(self: Cli, columns: ?[]const u8) Format {
        if (self.format) |f| return f;
        const cols = std.fmt.parseInt(u32, columns orelse return .line, 10) catch return .line;
        return if (cols < COMPACT_BELOW_COLUMNS) .compact else .line;
    }
};

pub const HELP =
    \\Usage: sketerm mcp agents [--format line|compact|json] [--parent PID]
    \\                          [--hosts] [--no-color]
    \\
    \\Summarizes the sub-agents of the sketerm MCP servers your process tree
    \\started (each server records the process that started it; the calling
    \\process's ancestors are matched, so a status line run by Claude Code
    \\finds that Claude Code's servers). --parent PID matches only servers PID
    \\started. Reads the per-user registry files only.
    \\
    \\  line     agents 2 working · 1 needs input · 1 idle (the default;
    \\           compact when $COLUMNS is below 100). Nothing when there are
    \\           no agents. --hosts appends (dalaran 2, local 1).
    \\  compact  ag 2▶ 1? 1✗ 1✓
    \\  json     {"total":N,"by_attention":{"needs_input":n,"lost":n,"working":n,
    \\           "idle":n},"most_urgent":"needs_input"|...|null,"agents":[{"id",
    \\           "app","host" (null = this machine),"attention","state"}]};
    \\           attention/state null = unknown (an older server).
    \\
    \\Exit status: 0, or 2 for bad usage.
    \\
;

/// `sketerm mcp agents ...`.
/// @return the process exit status.
pub fn cli(allocator: std.mem.Allocator, args: []const []const u8) u8 {
    const o = Cli.parse(args) catch |err| {
        _ = fdio.writeAll(2, switch (err) {
            error.UnknownFlag => "agents: unknown flag (see --help)\n",
            error.MissingValue => "agents: flag needs a value\n",
            error.BadValue => "agents: --format takes line, compact or json; --parent a pid\n",
        });
        return 2;
    };
    if (o.help) {
        _ = fdio.writeAll(1, HELP);
        return 0;
    }
    platform.ignoreSigpipe();
    const columns: ?[]const u8 = if (c.getenv("COLUMNS")) |v| std.mem.span(v) else null;
    const format = o.effectiveFormat(columns);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var pid_buf: [MAX_ANCESTRY]c.pid_t = undefined;
    const starters: []const c.pid_t = if (o.parent) |*p| p[0..1] else ancestry(&pid_buf, c.getpid(), platform.parentOf);
    // An unreadable registry reads as no agents: a status line must not fail.
    const entries = registry.list(arena, false) catch &.{};
    const summary = summarize(arena, entries, starters) catch Summary{};

    var aw: std.Io.Writer.Allocating = .init(arena);
    (switch (format) {
        .json => renderJson(&aw.writer, &summary),
        .line, .compact => renderText(&aw.writer, &summary, format, o.color, o.hosts),
    }) catch return 0;
    _ = fdio.writeAll(1, aw.written());
    return 0;
}

// ── tests ────────────────────────────────────────────────────────

const t = std.testing;

fn fakeParent(pid: c.pid_t) ?c.pid_t {
    // node (40) -> sh (30) -> claude (20) -> systemd --user (10) -> init.
    return switch (pid) {
        50 => 40,
        40 => 30,
        30 => 20,
        20 => 10,
        10 => 1,
        // A cycle must end the walk.
        7 => 8,
        8 => 7,
        else => null,
    };
}

test "ancestry walks to init, nearest first, and survives a cycle" {
    var buf: [MAX_ANCESTRY]c.pid_t = undefined;
    try t.expectEqualSlices(c.pid_t, &.{ 40, 30, 20, 10 }, ancestry(&buf, 50, fakeParent));
    try t.expectEqual(@as(usize, 0), ancestry(&buf, 99, fakeParent).len);
    try t.expectEqualSlices(c.pid_t, &.{ 8, 7 }, ancestry(&buf, 7, fakeParent));
    var small: [2]c.pid_t = undefined;
    try t.expectEqualSlices(c.pid_t, &.{ 40, 30 }, ancestry(&small, 50, fakeParent));
    // The real walk from this test process reaches at least its parent.
    const real = ancestry(&buf, c.getpid(), platform.parentOf);
    if (c.getppid() > 1) try t.expectEqual(c.getppid(), real[0]);
}

fn entry(pid: c.pid_t, ppid: c.pid_t, agents: ?[]registry.Agent) registry.Entry {
    return .{ .pid = pid, .mode = .isolated, .name = &.{}, .profile = &.{}, .log_dir = &.{}, .mux_socket = &.{}, .ppid = ppid, .agents = agents };
}

/// Three servers: two started by claude (20), one by someone else.
fn fixture(arena: std.mem.Allocator) ![]registry.Entry {
    const a = try arena.dupe(registry.Agent, &.{
        .{ .id = "claude-a1", .app = "claude", .location = "instance", .attention = "working", .state = "working" },
        .{ .id = "claude-a2", .app = "claude", .location = "host:dalaran", .attention = "needs_input", .state = "waiting_user" },
        .{ .id = "opencode-a3", .app = "opencode", .location = "host:dalaran", .attention = "working", .state = "waiting_subagent" },
    });
    const b = try arena.dupe(registry.Agent, &.{
        .{ .id = "claude-b1", .app = "claude", .location = "host:peregrin", .attention = "idle", .state = "idle" },
        // An older server's agent: attention unknown.
        .{ .id = "claude-b2", .app = "claude", .location = "user" },
    });
    const other = try arena.dupe(registry.Agent, &.{
        .{ .id = "claude-x", .app = "claude", .location = "instance", .attention = "lost", .state = "exited" },
    });
    return arena.dupe(registry.Entry, &.{ entry(100, 20, a), entry(101, 20, b), entry(102, 999, other), entry(103, 20, null) });
}

fn render(arena: std.mem.Allocator, s: *const Summary, format: Format, color: bool, hosts: bool) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    switch (format) {
        .json => try renderJson(&aw.writer, s),
        else => try renderText(&aw.writer, s, format, color, hosts),
    }
    return aw.written();
}

test "summary keeps only servers an ancestor started, and every format renders it" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const entries = try fixture(arena);
    var buf: [MAX_ANCESTRY]c.pid_t = undefined;
    const s = try summarize(arena, entries, ancestry(&buf, 50, fakeParent));
    try t.expectEqual(@as(u32, 5), s.tally.total);
    try t.expectEqual(@as(u32, 2), s.tally.count(.working));
    try t.expectEqual(@as(u32, 1), s.tally.count(.needs_input));
    try t.expectEqual(@as(u32, 0), s.tally.count(.lost));
    try t.expectEqual(@as(u32, 1), s.tally.unknown());
    try t.expectEqual(@as(?Attention, .needs_input), s.tally.mostUrgent());

    try t.expectEqualStrings("agents 2 working \u{00B7} 1 needs input \u{00B7} 1 idle \u{00B7} 1 unknown\n", try render(arena, &s, .line, false, false));
    try t.expectEqualStrings("agents 2 working \u{00B7} 1 needs input \u{00B7} 1 idle \u{00B7} 1 unknown (local 2, dalaran 2, peregrin 1)\n", try render(arena, &s, .line, false, true));
    try t.expectEqualStrings("ag 2\u{25B6} 1? 1\u{2713} 1~\n", try render(arena, &s, .compact, false, false));
    try t.expectEqualStrings("\x1b[1magents\x1b[0m \x1b[1;34m2 working\x1b[0m \x1b[2;37m\u{00B7}\x1b[0m \x1b[1;33m1 needs input\x1b[0m" ++
        " \x1b[2;37m\u{00B7}\x1b[0m \x1b[2;37m1 idle\x1b[0m \x1b[2;37m\u{00B7}\x1b[0m \x1b[2;37m1 unknown\x1b[0m\n", try render(arena, &s, .line, true, false));

    // The JSON contract: exact keys, in order.
    try t.expectEqualStrings(
        "{\"total\":5,\"by_attention\":{\"needs_input\":1,\"lost\":0,\"working\":2,\"idle\":1},\"most_urgent\":\"needs_input\",\"agents\":[" ++
            "{\"id\":\"claude-a1\",\"app\":\"claude\",\"host\":null,\"attention\":\"working\",\"state\":\"working\"}," ++
            "{\"id\":\"claude-a2\",\"app\":\"claude\",\"host\":\"dalaran\",\"attention\":\"needs_input\",\"state\":\"waiting_user\"}," ++
            "{\"id\":\"opencode-a3\",\"app\":\"opencode\",\"host\":\"dalaran\",\"attention\":\"working\",\"state\":\"waiting_subagent\"}," ++
            "{\"id\":\"claude-b1\",\"app\":\"claude\",\"host\":\"peregrin\",\"attention\":\"idle\",\"state\":\"idle\"}," ++
            "{\"id\":\"claude-b2\",\"app\":\"claude\",\"host\":null,\"attention\":null,\"state\":null}]}\n",
        try render(arena, &s, .json, false, false),
    );

    // --parent: exactly the servers that process started.
    const other = try summarize(arena, entries, &.{999});
    try t.expectEqualStrings("ag 1\u{2717}\n", try render(arena, &other, .compact, false, false));
    try t.expectEqualStrings("agents 1 disconnected\n", try render(arena, &other, .line, false, false));
}

test "no agents: no text at all, and a JSON document with total 0" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const entries = try fixture(arena);
    const none = try summarize(arena, entries, &.{4242});
    try t.expectEqualStrings("", try render(arena, &none, .line, true, true));
    try t.expectEqualStrings("", try render(arena, &none, .compact, true, false));
    try t.expectEqualStrings("{\"total\":0,\"by_attention\":{\"needs_input\":0,\"lost\":0,\"working\":0,\"idle\":0},\"most_urgent\":null,\"agents\":[]}\n", try render(arena, &none, .json, false, false));
    // A server that predates publishing agents contributes none.
    const old = try summarize(arena, entries[3..4], &.{20});
    try t.expectEqual(@as(u32, 0), old.tally.total);
}

test "an attention name this build does not know falls back to the state's" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ags = try arena.dupe(registry.Agent, &.{
        .{ .id = "a", .app = "claude", .location = "instance", .attention = "pondering", .state = "idle" },
        .{ .id = "b", .app = "claude", .location = "instance", .attention = "pondering", .state = "dreaming" },
    });
    const s = try summarize(arena, &.{entry(1, 20, ags)}, &.{20});
    try t.expectEqual(@as(?Attention, .idle), s.rows[0].attention);
    try t.expectEqual(@as(?Attention, null), s.rows[1].attention);
    try t.expectEqual(@as(?vocab.State, null), s.rows[1].state);
}

test "cli grammar and the narrow-terminal default" {
    const o = try Cli.parse(&.{ "--format", "json", "--parent", "4242", "--hosts", "--no-color" });
    try t.expectEqual(@as(?Format, .json), o.format);
    try t.expectEqual(@as(?c.pid_t, 4242), o.parent);
    try t.expect(o.hosts and !o.color);
    try t.expectError(error.BadValue, Cli.parse(&.{ "--format", "fancy" }));
    try t.expectError(error.BadValue, Cli.parse(&.{ "--parent", "me" }));
    try t.expectError(error.BadValue, Cli.parse(&.{ "--parent", "0" }));
    try t.expectError(error.MissingValue, Cli.parse(&.{"--format"}));
    try t.expectError(error.UnknownFlag, Cli.parse(&.{"--watch"}));

    const d = try Cli.parse(&.{});
    try t.expectEqual(Format.line, d.effectiveFormat(null));
    try t.expectEqual(Format.compact, d.effectiveFormat("80"));
    try t.expectEqual(Format.line, d.effectiveFormat("100"));
    try t.expectEqual(Format.line, d.effectiveFormat("wide"));
    // An explicit format wins over the terminal width.
    try t.expectEqual(Format.line, (try Cli.parse(&.{ "--format", "line" })).effectiveFormat("80"));
    try t.expectEqual(Format.json, o.effectiveFormat("80"));
}
