//! Push delivery: a sub-agent's wake-up sent INTO the orchestrator's
//! session instead of waiting for a waiter it armed. Two routes share the
//! text composed here and the agent's one delivery state: a Claude Code
//! channel notification (`notifications/claude/channel`, written by the
//! MCP server itself) and an `agent-wait --server` follower (the opencode
//! plugin runs one and prompts the session with each wake-up).
//!
//! Claude Code tells a server nothing about channels: it only registers a
//! listener when the session was started with `--channels server:<name>`
//! or `--dangerously-load-development-channels server:<name>`, and drops
//! the notification otherwise. A push marks its events delivered, so the
//! route is armed only when an ancestor's argv names this server's
//! channel; a session without it keeps the waiter route.

const std = @import("std");
const c = @import("../c.zig").c;
const platform = @import("../util/platform.zig");
const events = @import("../agent/events.zig");
const vocab = @import("../agent/vocab.zig");
const output = @import("../agent/output.zig");
const select = @import("../agent/select.zig");
const agentwait = @import("agentwait.zig");

/// The push route of this server's MCP session (`capabilities.agent_push`).
pub const Route = enum { channel, none };

/// The experimental capability a channel server declares.
pub const CHANNEL_CAPABILITY = "claude/channel";
pub const CHANNEL_METHOD = "notifications/claude/channel";
/// `clientInfo.name` of a Claude Code session.
pub const CLAUDE_CODE_CLIENT = "claude-code";
/// The Claude Code options that list a session's channel servers.
pub const CHANNEL_FLAGS = [_][]const u8{ "--channels", "--dangerously-load-development-channels" };
/// The MCP server name a channel entry is matched against by default
/// (`sketerm mcp --channel-name` overrides it).
pub const DEFAULT_CHANNEL_NAME = "sketerm";
/// A `done` carries its job's answer in full below this many characters.
pub const ANSWER_MAX_CHARS = 2000;
/// Ancestors searched for the channel option (a wrapper shell or two
/// may sit between Claude Code and this server).
const ANCESTOR_DEPTH = 8;

/// Whether a NUL-separated argv lists `name`'s channel: `server:<name>`
/// or `plugin:<name>@<marketplace>` after one of `CHANNEL_FLAGS`, which
/// take every following word up to the next option (or `=value`).
pub fn argvNamesChannel(argv: []const u8, name: []const u8) bool {
    var it = std.mem.splitScalar(u8, argv, 0);
    var listing = false;
    while (it.next()) |word| {
        if (word.len > 0 and word[0] == '-') {
            listing = false;
            for (CHANNEL_FLAGS) |flag| {
                if (std.mem.eql(u8, word, flag)) listing = true;
                if (word.len > flag.len and std.mem.startsWith(u8, word, flag) and word[flag.len] == '=') {
                    if (entryNames(word[flag.len + 1 ..], name)) return true;
                }
            }
            continue;
        }
        if (listing and entryNames(word, name)) return true;
    }
    return false;
}

/// One `--channels` entry (Claude Code splits a word on nothing else).
fn entryNames(entry: []const u8, name: []const u8) bool {
    if (std.mem.startsWith(u8, entry, "server:")) return std.mem.eql(u8, entry["server:".len..], name);
    if (std.mem.startsWith(u8, entry, "plugin:")) {
        const rest = entry["plugin:".len..];
        const at = std.mem.indexOfScalar(u8, rest, '@') orelse return false;
        return std.mem.eql(u8, rest[0..at], name);
    }
    return false;
}

/// Whether this process's parent, or one of its nearest ancestors, was
/// started with `name`'s channel. Always false where processes cannot be
/// inspected (`platform.can_inspect_processes`).
pub fn ancestorNamesChannel(name: []const u8) bool {
    var pid = c.getppid();
    var buf: [64 * 1024]u8 = undefined;
    var depth: usize = 0;
    while (depth < ANCESTOR_DEPTH and pid > 1) : (depth += 1) {
        if (platform.argvOfPid(pid, &buf)) |argv| {
            if (argvNamesChannel(argv, name)) return true;
        }
        const info = platform.infoOfPid(pid) orelse return false;
        pid = info.ppid;
    }
    return false;
}

/// One wake-up as a push delivers it.
pub const Push = struct {
    /// The waiter's line, then a done's answer when it is short enough.
    content: []const u8,
    meta: agentwait.Meta,
    /// Index into the records of the answer `content` carries in full:
    /// the caller marks it handed out.
    answer: ?usize = null,
};

/// Who the wake-up is about, beyond the delivery itself.
pub const Subject = struct {
    agent: []const u8,
    name: ?[]const u8 = null,
    conversation: ?[]const u8 = null,
    state: vocab.State,
};

/// The delivered item that decides the wake-up (`EventKind.outcomeRank`).
fn decisive(items: []const events.Item) ?events.Item {
    var best: ?events.Item = null;
    for (items) |it| {
        if (best == null or it.kind.outcomeRank() > best.?.kind.outcomeRank()) best = it;
    }
    return best;
}

/// Compose the push for `d`: the waiter's one line, and for a `done` the
/// job's answer in full when under `ANSWER_MAX_CHARS` and not handed out
/// before (else a pointer to agent_read).
pub fn compose(arena: std.mem.Allocator, who: Subject, d: events.Delivery, q: *const events.Queue, records: []const output.Record, handed: *const select.Handed) !Push {
    const m = try agentwait.wakeMessage(arena, who.agent, who.state, d, q);
    var aw: std.Io.Writer.Allocating = .init(arena);
    try agentwait.formatWake(&aw.writer, m);
    const best = decisive(d.items);
    var answer: ?usize = null;
    if (best) |b| if (b.kind == .done) if (b.event.record) |rid| {
        for (records, 0..) |r, i| {
            if (r.id != rid) continue;
            if (handed.has(r) or r.text.len == 0) break;
            const chars = std.unicode.utf8CountCodepoints(r.text) catch r.text.len;
            if (chars < ANSWER_MAX_CHARS) {
                try aw.writer.print("\n\n{s}", .{r.text});
                answer = i;
            } else {
                try aw.writer.print("\n\n(the answer is {d} characters: agent_read {{agent: \"{s}\"}} returns it)", .{ chars, who.agent });
            }
            break;
        }
    };
    var seq_buf: [24]u8 = undefined;
    const seq: u64 = if (best) |b| b.event.seq else if (d.digest) |g| g.latest_seq else 0;
    return .{
        .content = aw.written(),
        .answer = answer,
        .meta = .{
            .agent = who.agent,
            .name = who.name,
            .kind = if (best) |b| @tagName(b.kind) else "digest",
            .state = @tagName(who.state),
            .seq = try arena.dupe(u8, try std.fmt.bufPrint(&seq_buf, "{d}", .{seq})),
            .record = if (best) |b| if (b.event.record) |r| try std.fmt.allocPrint(arena, "{d}", .{r}) else null else null,
            .job = if (best) |b| if (b.event.job) |j| try std.fmt.allocPrint(arena, "{d}", .{j}) else null else null,
            .conversation = who.conversation,
        },
    };
}

/// The channel notification for `p`, one newline-free JSON-RPC line.
pub fn encodeChannel(arena: std.mem.Allocator, p: Push) ![]const u8 {
    const Params = struct { content: []const u8, meta: agentwait.Meta };
    const Note = struct { jsonrpc: []const u8 = "2.0", method: []const u8 = CHANNEL_METHOD, params: Params };
    return std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(Note{ .params = .{ .content = p.content, .meta = p.meta } }, .{ .emit_null_optional_fields = false })});
}

// ── tests ────────────────────────────────────────────────────────

const t = std.testing;

test "the channel option is read the way Claude Code parses it" {
    const name = "sketerm";
    try t.expect(argvNamesChannel("claude\x00--dangerously-load-development-channels\x00server:sketerm", name));
    try t.expect(argvNamesChannel("claude\x00--channels\x00server:tg\x00server:sketerm\x00--model\x00haiku", name));
    try t.expect(argvNamesChannel("claude\x00--channels=plugin:sketerm@market", name));
    try t.expect(argvNamesChannel("claude\x00--channels\x00plugin:sketerm@m", name));
    // Another server's channel, a bare name, or the entry after the list ended.
    try t.expect(!argvNamesChannel("claude\x00--channels\x00server:telegram", name));
    try t.expect(!argvNamesChannel("claude\x00--channels\x00sketerm", name));
    try t.expect(!argvNamesChannel("claude\x00--channels\x00server:tg\x00--model\x00server:sketerm", name));
    try t.expect(!argvNamesChannel("claude\x00--model\x00server:sketerm", name));
    try t.expect(!argvNamesChannel("claude\x00--channels\x00server:sketerm2", name));
    try t.expect(!argvNamesChannel("claude\x00--channels\x00plugin:sketerm", name));
}

test "a done push carries its short answer once, a long one by pointer" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var q = events.Queue.init(t.allocator, .{});
    defer q.deinit();
    var text = "The fix is in.\nTests pass.".*;
    const recs = [_]output.Record{.{ .id = 7, .kind = .assistant, .text = &text, .job = 2 }};
    var handed: select.Handed = .{};
    defer handed.deinit(t.allocator);
    _ = try q.pushDone(0, 2, 2, &text, 7, null);
    var cur: events.Cursor = .{};
    const d = (try cur.take(&q, .{}, 0, a)).?;
    const p = try compose(a, .{ .agent = "claude-k3f9", .conversation = "abc", .state = .idle }, d, &q, &recs, &handed);
    try t.expectEqualStrings("claude-k3f9 done: The fix is in. [state idle]\n\nThe fix is in.\nTests pass.", p.content);
    try t.expectEqual(@as(?usize, 0), p.answer);
    try t.expectEqualStrings("done", p.meta.kind);
    try t.expectEqualStrings("7", p.meta.record.?);
    try t.expectEqualStrings("2", p.meta.job.?);
    const line = try encodeChannel(a, p);
    try t.expect(std.mem.indexOfScalar(u8, line, '\n') == null);
    try t.expect(std.mem.startsWith(u8, line, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/claude/channel\",\"params\":{\"content\":"));
    try t.expect(std.mem.indexOf(u8, line, "\"meta\":{\"agent\":\"claude-k3f9\",\"kind\":\"done\",\"state\":\"idle\",\"seq\":\"1\",\"record\":\"7\",\"job\":\"2\",\"conversation\":\"abc\"}") != null);

    // Handed out already: the line alone.
    try handed.markRecord(t.allocator, recs[0]);
    const again = try compose(a, .{ .agent = "claude-k3f9", .state = .idle }, d, &q, &recs, &handed);
    try t.expectEqualStrings("claude-k3f9 done: The fix is in. [state idle]", again.content);
    try t.expect(again.answer == null);

    // Too long to push: a pointer, never the text.
    const long = try a.alloc(u8, ANSWER_MAX_CHARS);
    @memset(long, 'x');
    const big = [_]output.Record{.{ .id = 9, .kind = .assistant, .text = long, .job = 3 }};
    _ = try q.pushDone(1, 3, 3, long, 9, null);
    const d2 = (try cur.take(&q, .{}, 1, a)).?;
    const p2 = try compose(a, .{ .agent = "claude-k3f9", .state = .idle }, d2, &q, &big, &handed);
    try t.expect(p2.answer == null);
    try t.expect(std.mem.endsWith(u8, p2.content, "(the answer is 2000 characters: agent_read {agent: \"claude-k3f9\"} returns it)"));
}
