//! Push delivery: a sub-agent's wake-up (or a peer message) sent INTO the
//! orchestrator's session instead of waiting for a waiter it armed. Two
//! routes share the text composed here and the one delivery state of what
//! they deliver: a Claude Code channel notification
//! (`notifications/claude/channel`, written by the MCP server itself) and
//! an `agent-wait --server` follower (the opencode plugin runs one and
//! prompts the session with each wake-up). The plain waiter prints the same
//! text (`agentwait.Subscribe.content`); `peer_read` returns it too.
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
const peermail = @import("../mux/peermail.zig");
const clock = @import("../util/clock.zig");

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
/// A `done` carries its job's answer (a `message` its text) in full below
/// this many characters.
pub const ANSWER_MAX_CHARS = 2000;
/// Ancestors searched for the channel option (a wrapper shell or two
/// may sit between Claude Code and this server).
const ANCESTOR_DEPTH = 8;

/// Whether a NUL-separated argv lists `name`'s channel: `server:<name>`
/// or `plugin:<name>@<marketplace>` after one of `CHANNEL_FLAGS`, which
/// take every following word up to the next option (or `=value`).
/// @return null when the argv has no channel option at all
pub fn argvNamesChannel(argv: []const u8, name: []const u8) ?bool {
    var it = std.mem.splitScalar(u8, argv, 0);
    var listing = false;
    var lists = false;
    while (it.next()) |word| {
        if (word.len > 0 and word[0] == '-') {
            listing = false;
            for (CHANNEL_FLAGS) |flag| {
                if (std.mem.eql(u8, word, flag)) listing = true;
                if (word.len > flag.len and std.mem.startsWith(u8, word, flag) and word[flag.len] == '=') {
                    lists = true;
                    if (entryNames(word[flag.len + 1 ..], name)) return true;
                }
            }
            lists = lists or listing;
            continue;
        }
        if (listing and entryNames(word, name)) return true;
    }
    return if (lists) false else null;
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

/// Whether the nearest ancestor started with a channel option names
/// `name`'s channel. Farther ancestors are another session (an outer
/// Claude Code), whose channel never reaches this one. Always false where
/// processes cannot be inspected (`platform.can_inspect_processes`).
pub fn ancestorNamesChannel(name: []const u8) bool {
    var pid = c.getppid();
    var buf: [64 * 1024]u8 = undefined;
    var depth: usize = 0;
    while (depth < ANCESTOR_DEPTH and pid > 1) : (depth += 1) {
        if (platform.argvOfPid(pid, &buf)) |argv| {
            if (argvNamesChannel(argv, name)) |named| return named;
        }
        const info = platform.infoOfPid(pid) orelse return false;
        pid = info.ppid;
    }
    return false;
}

/// One wake-up as a push delivers it.
pub const Push = struct {
    /// The waiter's line, then what it cuts short (`compose`).
    content: []const u8,
    meta: agentwait.Meta,
    /// Index into the records of the record `content` carries in full (a
    /// done's answer, a message): the caller marks it handed out.
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

/// Compose the push for `d`: the waiter's one line, then for an event
/// that announces a record (a `done`'s answer, a `message`) that record in
/// full when under `ANSWER_MAX_CHARS` and not handed out before (else a
/// pointer to agent_read), and for any other the text the line cut and
/// its detail (a prompt's options, a limit's reset time).
pub fn compose(arena: std.mem.Allocator, who: Subject, d: events.Delivery, q: *const events.Queue, records: []const output.Record, handed: *const select.Handed) !Push {
    const m = try agentwait.wakeMessage(arena, who.agent, who.state, d, q);
    var aw: std.Io.Writer.Allocating = .init(arena);
    try agentwait.formatWake(&aw.writer, m);
    const best = decisive(d.items);
    var answer: ?usize = null;
    if (best) |b| {
        if (b.kind.announcesRecord()) {
            if (b.event.record) |rid| answer = try carryRecord(&aw.writer, who.agent, records, handed, rid);
        } else try carryText(&aw.writer, b.event);
    }
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
            .at = if (best) |b| try agentwait.eventAt(arena, b.event) else null,
        },
    };
}

/// Record `rid` in full below the line, or a pointer when it is too long.
/// @return its index when carried in full; null when handed out before,
/// empty, too long or not found.
fn carryRecord(w: *std.Io.Writer, agent: []const u8, records: []const output.Record, handed: *const select.Handed, rid: u64) !?usize {
    for (records, 0..) |r, i| {
        if (r.id != rid) continue;
        if (handed.has(r) or r.text.len == 0) return null;
        const chars = select.chars(r.text);
        if (chars < ANSWER_MAX_CHARS) {
            try w.print("\n\n{s}", .{r.text});
            return i;
        }
        try w.print("\n\n(the answer is {d} characters: agent_read {{agent: \"{s}\"}} returns it)", .{ chars, agent });
        return null;
    }
    return null;
}

/// What the one line cut of `ev`'s text (more lines, or a first line past
/// `agentwait.LINE_TEXT_MAX`), then its detail.
fn carryText(w: *std.Io.Writer, ev: *const events.Event) !void {
    const text = std.mem.trim(u8, ev.text, " \t\r\n");
    const first = events.firstLine(ev.text);
    if (text.len > first.len or first.len > agentwait.LINE_TEXT_MAX) try w.print("\n\n{s}", .{events.clip(text, ANSWER_MAX_CHARS * 4)});
    const detail = std.mem.trim(u8, ev.detail, " \t\r\n");
    if (detail.len > 0) try w.print("\n\n{s}", .{events.clip(detail, ANSWER_MAX_CHARS * 4)});
}

/// What a peer push is about (`composePeer`).
pub const PeerItem = union(enum) {
    /// A message for this session.
    message: peermail.Deliver,
    /// What became of a message this session sent.
    event: peermail.Event,
    /// A message for this address that expired before any server of it read it.
    expired_away: peermail.Expired,
};

/// A peer message shows its age from this much on.
pub const PEER_AGE_SHOWN_MS: i64 = 60_000;

/// Compose the push for one peer item: the same `Push` the agent wake-ups
/// use, so both routes and `peer_read` carry this text and nothing else.
/// The sender's presence is its `PeerState` as the broker reported it at
/// delivery; a broker that predates `sender_state`: `gone` when the
/// sender's server is not live, else `unknown`.
pub fn composePeer(arena: std.mem.Allocator, item: PeerItem) !Push {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    switch (item) {
        .message => |m| {
            // The sender reads as its alias (what a reply goes to), its
            // address beside it; an older broker's sender has no alias.
            const who = if (m.from.alias.len > 0) m.from.alias else m.from.address;
            try w.print("Peer message from {s} (", .{who});
            if (m.from.alias.len > 0) try w.print("{s}, ", .{m.from.address});
            try w.writeAll(if (m.from.app.len > 0) m.from.app else "unknown app");
            if (m.from.host.len > 0) try w.print(" on {s}", .{m.from.host});
            if (m.from.cwd.len > 0) try w.print(", {s}", .{m.from.cwd});
            const presence = senderState(m);
            try w.print(", {s}", .{@tagName(presence)});
            if (m.sender_subject.len > 0) try w.print("; subject: {s}", .{m.sender_subject});
            try w.writeAll(")");
            const aged = m.age_ms >= PEER_AGE_SHOWN_MS;
            if (aged or m.queued) try w.writeAll(", sent");
            if (aged) {
                try w.writeAll(" ");
                try writeAge(w, m.age_ms);
                try w.writeAll(" ago");
            }
            if (m.queued) try w.writeAll(" while you were offline");
            try w.print(". id {s}.", .{m.id});
            if (m.reply_to) |r| try w.print(" In reply to {s}.", .{r});
            try w.print(" Reply with peer_send to \"{s}\".", .{who});
            try w.print("\n\n{s}", .{m.text});
        },
        .event => |e| {
            try w.print("Your peer message {s} to {s} ", .{ e.id, e.to });
            if (e.outcome == .refused) {
                try w.print("was refused there: {s}.", .{if (e.reason) |r| r.describe() else "no reason given"});
            } else if (e.reason) |r| {
                try w.print("ended unread: {s}.", .{r.describe()});
            } else if (e.outcome == .expired) {
                try w.writeAll("expired unread after ");
                try writeAge(w, e.queued_ms);
                try w.writeAll(".");
            } else try w.print("is {s}.", .{@tagName(e.outcome)});
        },
        .expired_away => |x| {
            try w.print("Peer message {s} from {s} expired unread while you were away (", .{ x.id, x.from });
            try writeAge(w, x.expired_ms - x.sent_ms);
            try w.writeAll(" after it was sent).");
        },
    }
    return .{ .content = aw.written(), .meta = try peerMeta(arena, item) };
}

fn peerMeta(arena: std.mem.Allocator, item: PeerItem) !agentwait.Meta {
    return switch (item) {
        .message => |m| .{
            .kind = "peer_message",
            .from = m.from.address,
            .host = nonEmpty(m.from.host),
            .app = nonEmpty(m.from.app),
            .cwd = nonEmpty(m.from.cwd),
            .message = m.id,
            .reply_to = m.reply_to,
            .queued = if (m.queued) "true" else "false",
            .age_s = try std.fmt.allocPrint(arena, "{d}", .{@divTrunc(@max(m.age_ms, 0), 1000)}),
            .sender_state = @tagName(senderState(m)),
            .sender_subject = nonEmpty(m.sender_subject),
            .from_alias = nonEmpty(m.from.alias),
            .at = try wallAt(arena, m.sent_ms),
        },
        .event => |e| .{
            .kind = try std.fmt.allocPrint(arena, "peer_{s}", .{@tagName(e.outcome)}),
            .message = e.id,
        },
        .expired_away => |x| .{
            .kind = "peer_expired_away",
            .from = x.from,
            .message = x.id,
            .at = try wallAt(arena, x.sent_ms),
        },
    };
}

fn senderState(m: peermail.Deliver) vocab.PeerState {
    return m.sender_state orelse if (m.sender_live) .unknown else .gone;
}

fn nonEmpty(s: []const u8) ?[]const u8 {
    return if (s.len > 0) s else null;
}

fn wallAt(arena: std.mem.Allocator, wall_ms: i64) !?[]const u8 {
    if (wall_ms <= 0) return null;
    var buf: [clock.ISO_LEN]u8 = undefined;
    return if (clock.isoLocal(&buf, wall_ms)) |s| try arena.dupe(u8, s) else null;
}

/// `5 min`, `3 h`, `2 days`: minutes below two hours, hours below two days.
fn writeAge(w: *std.Io.Writer, ms: i64) !void {
    const mins = @divTrunc(@max(ms, 0), 60_000);
    if (mins < 120) return w.print("{d} min", .{mins});
    const hours = @divTrunc(mins, 60);
    if (hours < 48) return w.print("{d} h", .{hours});
    try w.print("{d} days", .{@divTrunc(hours, 24)});
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
    try t.expectEqual(@as(?bool, true), argvNamesChannel("claude\x00--dangerously-load-development-channels\x00server:sketerm", name));
    try t.expectEqual(@as(?bool, true), argvNamesChannel("claude\x00--channels\x00server:tg\x00server:sketerm\x00--model\x00haiku", name));
    try t.expectEqual(@as(?bool, true), argvNamesChannel("claude\x00--channels=plugin:sketerm@market", name));
    try t.expectEqual(@as(?bool, true), argvNamesChannel("claude\x00--channels\x00plugin:sketerm@m", name));
    // Another server's channel, a bare name, or the entry after the list
    // ended: a session with channels, not ours, so the walk stops there.
    try t.expectEqual(@as(?bool, false), argvNamesChannel("claude\x00--channels\x00server:telegram", name));
    try t.expectEqual(@as(?bool, false), argvNamesChannel("claude\x00--channels=server:telegram", name));
    try t.expectEqual(@as(?bool, false), argvNamesChannel("claude\x00--channels\x00sketerm", name));
    try t.expectEqual(@as(?bool, false), argvNamesChannel("claude\x00--channels\x00server:tg\x00--model\x00server:sketerm", name));
    try t.expectEqual(@as(?bool, false), argvNamesChannel("claude\x00--channels\x00server:sketerm2", name));
    try t.expectEqual(@as(?bool, false), argvNamesChannel("claude\x00--channels\x00plugin:sketerm", name));
    // No channel option: a wrapper, the walk goes on.
    try t.expectEqual(@as(?bool, null), argvNamesChannel("claude\x00--model\x00server:sketerm", name));
    try t.expectEqual(@as(?bool, null), argvNamesChannel("/bin/sh\x00-c\x00exec sketerm mcp", name));
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

test "a wake carries what its line cuts: a message in full, a prompt's options, a long error" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var q = events.Queue.init(t.allocator, .{});
    defer q.deinit();
    var handed: select.Handed = .{};
    defer handed.deinit(t.allocator);
    var text = "Halfway: the parser is fixed.\nNow the tests.".*;
    const recs = [_]output.Record{.{ .id = 4, .kind = .assistant, .text = &text, .job = 1 }};
    var cur: events.Cursor = .{};

    // An opt-in message: its record in full, to be marked handed.
    _ = try q.pushMessage(0, &text, 4);
    const dm = (try cur.take(&q, .{ .messages = true }, 0, a)).?;
    const pm = try compose(a, .{ .agent = "claude-k3f9", .state = .working }, dm, &q, &recs, &handed);
    try t.expectEqualStrings("claude-k3f9 message: Halfway: the parser is fixed. [state working]\n\nHalfway: the parser is fixed.\nNow the tests.", pm.content);
    try t.expectEqual(@as(?usize, 0), pm.answer);

    // A prompt: its options, which the line never shows.
    _ = try q.push(0, .needs_input, null, "permission: Bash (rm notes.md)", "1. Yes\n2. No");
    const dn = (try cur.take(&q, .{}, 1, a)).?;
    const pn = try compose(a, .{ .agent = "claude-k3f9", .state = .waiting_user }, dn, &q, &recs, &handed);
    try t.expectEqualStrings("claude-k3f9 needs_input: permission: Bash (rm notes.md) [state waiting_user]\n\n1. Yes\n2. No", pn.content);
    try t.expect(pn.answer == null);

    // An error the line cuts: its whole text; a short one adds nothing.
    const long = "API Error: " ++ "x" ** 200;
    _ = try q.push(0, .@"error", .api, long, "");
    const de = (try cur.take(&q, .{}, 2, a)).?;
    const pe = try compose(a, .{ .agent = "claude-k3f9", .state = .idle }, de, &q, &recs, &handed);
    try t.expect(std.mem.endsWith(u8, pe.content, "[state idle]\n\n" ++ long));
    _ = try q.push(0, .exited, null, "", "");
    const dx = (try cur.take(&q, .{}, 3, a)).?;
    const px = try compose(a, .{ .agent = "claude-k3f9", .state = .exited }, dx, &q, &recs, &handed);
    try t.expectEqualStrings("claude-k3f9 exited [state exited]", px.content);
}

test "a peer message reads as the plan's sentence: age from a minute on, offline only when queued" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const from: peermail.From = .{ .address = "Zenit", .host = "hohenheim", .cwd = "/home/u/zenit-workspace", .app = "claude-code", .pid = 7 };

    // Fresh and live: no age, no offline clause.
    const fresh = try composePeer(a, .{ .message = .{ .id = "m-k3f9x2qa", .from = from, .to = "Qq", .text = "Who owns the migration?", .age_ms = 4_000, .sender_live = true } });
    try t.expectEqualStrings("Peer message from Zenit (claude-code on hohenheim, /home/u/zenit-workspace, unknown). id m-k3f9x2qa. Reply with peer_send to \"Zenit\".\n\nWho owns the migration?", fresh.content);
    try t.expectEqualStrings("peer_message", fresh.meta.kind);
    try t.expectEqualStrings("Zenit", fresh.meta.from.?);
    try t.expectEqualStrings("m-k3f9x2qa", fresh.meta.message.?);
    try t.expectEqualStrings("false", fresh.meta.queued.?);
    try t.expectEqualStrings("4", fresh.meta.age_s.?);
    try t.expect(fresh.meta.agent == null and fresh.meta.seq == null);
    try t.expectEqualStrings("unknown", fresh.meta.sender_state.?);
    // The broker's sender_state wins (hooks report presence).
    const busy = try composePeer(a, .{ .message = .{ .id = "m-9", .from = from, .text = "x", .sender_live = true, .sender_state = .working } });
    try t.expect(std.mem.startsWith(u8, busy.content, "Peer message from Zenit (claude-code on hohenheim, /home/u/zenit-workspace, working). id m-9."));
    try t.expectEqualStrings("working", busy.meta.sender_state.?);
    try t.expect(busy.meta.sender_subject == null);
    // The sender's user-set subject follows its state.
    const about = try composePeer(a, .{ .message = .{ .id = "m-8", .from = from, .text = "x", .sender_live = true, .sender_state = .idle, .sender_subject = "template links" } });
    try t.expect(std.mem.startsWith(u8, about.content, "Peer message from Zenit (claude-code on hohenheim, /home/u/zenit-workspace, idle; subject: template links). id m-8."));
    try t.expectEqualStrings("template links", about.meta.sender_subject.?);
    // A sender with an alias reads as it, its address beside it.
    var aliased = from;
    aliased.address = "p-3fa9c2e1";
    aliased.alias = "zenit";
    const named = try composePeer(a, .{ .message = .{ .id = "m-7", .from = aliased, .text = "x", .sender_live = true, .sender_state = .idle } });
    try t.expectEqualStrings("Peer message from zenit (p-3fa9c2e1, claude-code on hohenheim, /home/u/zenit-workspace, idle). id m-7. Reply with peer_send to \"zenit\".\n\nx", named.content);
    try t.expectEqualStrings("p-3fa9c2e1", named.meta.from.?);
    try t.expectEqualStrings("zenit", named.meta.from_alias.?);

    // Aged but delivered live: the age alone.
    const aged = try composePeer(a, .{ .message = .{ .id = "m-1", .from = from, .text = "x", .age_ms = 5 * 60_000 + 10, .sender_live = true } });
    try t.expect(std.mem.startsWith(u8, aged.content, "Peer message from Zenit (claude-code on hohenheim, /home/u/zenit-workspace, unknown), sent 5 min ago. id m-1."));

    // Queued while offline, sender gone since, and an answer to another.
    const queued = try composePeer(a, .{ .message = .{ .id = "m-2", .from = from, .text = "x", .age_ms = 5 * 60_000, .queued = true, .reply_to = "m-1" } });
    try t.expectEqualStrings("Peer message from Zenit (claude-code on hohenheim, /home/u/zenit-workspace, gone), sent 5 min ago while you were offline. id m-2. In reply to m-1. Reply with peer_send to \"Zenit\".\n\nx", queued.content);
    try t.expectEqualStrings("true", queued.meta.queued.?);
    try t.expectEqualStrings("m-1", queued.meta.reply_to.?);

    // Queued but fresh: offline without an age; an unregistered app and host.
    const quick = try composePeer(a, .{ .message = .{ .id = "m-3", .from = .{ .address = "anon-ab12" }, .text = "x", .age_ms = 30_000, .queued = true, .sender_live = true } });
    try t.expect(std.mem.startsWith(u8, quick.content, "Peer message from anon-ab12 (unknown app, unknown), sent while you were offline. id m-3."));
    try t.expect(quick.meta.host == null and quick.meta.cwd == null);

    // Hours past two hours; the channel line stays newline-free.
    const old = try composePeer(a, .{ .message = .{ .id = "m-4", .from = from, .text = "line1\nline2", .age_ms = 3 * 3600_000 } });
    try t.expect(std.mem.indexOf(u8, old.content, "sent 3 h ago. id m-4.") != null);
    const note = try encodeChannel(a, old);
    try t.expect(std.mem.indexOfScalar(u8, note, '\n') == null);
    try t.expect(std.mem.indexOf(u8, note, "\"meta\":{\"kind\":\"peer_message\",") != null);
    try t.expect(std.mem.indexOf(u8, note, "\"agent\"") == null);
}

test "what became of a sent message, and mail that expired while away, read as one sentence" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const exp = try composePeer(a, .{ .event = .{ .id = "m-5", .to = "Qq", .queued_ms = 6 * 3600_000 } });
    try t.expectEqualStrings("Your peer message m-5 to Qq expired unread after 6 h.", exp.content);
    try t.expectEqualStrings("peer_expired", exp.meta.kind);
    const gone = try composePeer(a, .{ .event = .{ .id = "m-6", .to = "anon-x1y2", .reason = .not_durable_gone } });
    try t.expectEqualStrings("Your peer message m-6 to anon-x1y2 ended unread: that peer's address was not durable and its server is gone.", gone.content);
    const away = try composePeer(a, .{ .expired_away = .{ .id = "m-7", .from = "Zenit", .sent_ms = 1_000, .expired_ms = 1_000 + 7 * 3600_000 } });
    try t.expectEqualStrings("Peer message m-7 from Zenit expired unread while you were away (7 h after it was sent).", away.content);
    try t.expectEqualStrings("peer_expired_away", away.meta.kind);
    // A far broker's refusal of mail queued for a federated host.
    const far = try composePeer(a, .{ .event = .{ .id = "m-8", .outcome = .refused, .to = "box/Nobody", .reason = .unknown_address } });
    try t.expectEqualStrings("Your peer message m-8 to box/Nobody was refused there: no peer of that address is known on that host.", far.content);
    try t.expectEqualStrings("peer_refused", far.meta.kind);
}
