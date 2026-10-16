//! `sketerm peer list|send|read|subject|note|alias`: any program is a peer
//! by running this, a client of the same `peer_*` frames the MCP server
//! speaks (`peerclient.Peer`, no wire of its own). `read --follow`
//! registers a durable address (`n-`, from its name, which it asks for as
//! its alias) and prints each incoming message as it arrives (one JSON
//! line with `--json`), acknowledging it only once the line is written;
//! lines it reads on its stdin are sent from that address. `subject` and
//! `alias` set what a session works on and the name it is reached by:
//! inside an assistant session they find that session's own servers the
//! way `sketerm mcp hook` does and post a presence line; `subject --name`
//! sets it on the broker by alias or address. `note` sets a live peer's
//! own note on the broker, by `--name` or this session's own address. It
//! is also the one home of how a peer list entry reads, for this CLI and
//! the `peer_list` tool alike (`listLine`, `writeList`).

const std = @import("std");
const c = @import("../c.zig").c;
const fdio = @import("../util/fdio.zig");
const platform = @import("../util/platform.zig");
const clock = @import("../util/clock.zig");
const Backoff = @import("../util/backoff.zig").Backoff;
const env = @import("../util/env.zig");
const vocab = @import("../agent/vocab.zig");
const peeraddr = @import("peeraddr.zig");
const agentpush = @import("agentpush.zig");
const muxclient = @import("../mux/client.zig");
const peerclient = @import("../mux/peerclient.zig");
const agentwait = @import("agentwait.zig");
const mcp_hook = @import("mcp_hook.zig");
const peermail = peerclient.peermail;
const peerwake = @import("../mux/peerwake.zig");
const numtext = @import("../util/numtext.zig");
const peer_setup = @import("peer_setup.zig");

/// The argv word that selects this command (`sketerm peer`, `sketerm mcp peer`).
pub const SUBCOMMAND = "peer";
/// The registered app of a CLI peer that declares none.
pub const APP_DEFAULT = "cli";
/// The name when no `--name` is given (the precedence's explicit rule).
pub const ENV_NAME = "SKETERM_PEER_NAME";
pub const REPLY_MS: i64 = 10_000;
/// A one-shot read takes what arrives until this long passes with nothing.
const READ_QUIET_MS: i64 = 300;
const RECONNECT = Backoff{ .min_ms = 1_000, .max_ms = 60_000 };
/// Longest line a follower reads on its stdin (a message plus its JSON).
const STDIN_LINE_MAX: usize = peermail.PEER_TEXT_MAX * 6 + 1024;

// ── one peer list entry, for every surface ──────────────────────

/// One peer as `peer_list` and `sketerm peer list --json` report it.
pub const ListLine = struct {
    address: []const u8,
    /// The name to send to; absent when it has none.
    alias: ?[]const u8 = null,
    host: ?[]const u8 = null,
    app: ?[]const u8 = null,
    state: []const u8,
    /// Its session gets no pushed messages: mail waits for its next turn
    /// or `peer_read`. Absent when it is pushed to, or not known.
    polls: ?bool = null,
    /// No server of it is live, but its session runs (its hooks report):
    /// its MCP server is down. Absent otherwise.
    no_mcp: ?bool = null,
    /// Absent while the state is unknown.
    attention: ?[]const u8 = null,
    /// What its session runs besides its main turn, read off its screen by
    /// its daemon; absent when nothing runs or it is not read.
    work: ?vocab.PeerWork = null,
    live: bool,
    pending: u32,
    last_seen_ms: i64,
    model: ?[]const u8 = null,
    /// What it works on, set by its user; absent when none.
    subject: ?[]const u8 = null,
    /// What it says it is doing, set by its own assistant; absent when
    /// none or stale.
    note: ?[]const u8 = null,
    /// When the note was set (wall ms); absent with it.
    note_ms: ?i64 = null,
    /// Its known facts (`data/agents/facts.json` names).
    facts: ?std.json.Value = null,
    self: ?bool = null,
    cwd: ?[]const u8 = null,
    pid: ?i32 = null,
    durable: ?bool = null,
    name_taken: ?bool = null,
    last_notification: ?[]const u8 = null,
    /// Federation: the host whose link it is reached through.
    via_host: ?[]const u8 = null,
    /// Federation: that link's state.
    link: ?[]const u8 = null,
    /// Federation: why that link is not up (`HostLine.why`).
    link_why: ?[]const u8 = null,
};

/// One federated host as `peer_list` and `sketerm peer list --json` report it.
pub const HostLine = struct {
    host: []const u8,
    link: []const u8,
    last_seen_ms: i64,
    /// Why the link is not up, and what said so; absent while it is.
    why: ?[]const u8 = null,
    detail: ?[]const u8 = null,
    /// The next dial is due in this many ms; absent when none waits here.
    retry_in_ms: ?i64 = null,
    /// A redial is under way (why is the last failure's).
    redialing: ?bool = null,
};

pub fn hostLine(h: peermail.HostInfo) HostLine {
    return .{
        .host = h.host,
        .link = @tagName(h.link),
        .last_seen_ms = h.last_seen_ms,
        .why = if (h.why) |w| @tagName(w) else null,
        .detail = nonEmpty(h.detail),
        .retry_in_ms = if (h.retry_in_ms > 0) h.retry_in_ms else null,
        .redialing = if (h.redialing) true else null,
    };
}

/// Why a host's link is not up, as every text surface reads it: the
/// reason, what said so, and when it is dialed again (nothing while up).
pub fn writeWhy(w: *std.Io.Writer, h: peermail.HostInfo) !void {
    const why = h.why orelse return;
    try w.writeAll(why.label());
    if (h.detail.len > 0) try w.print(": {s}", .{h.detail});
    var buf: [48]u8 = undefined;
    if (h.redialing) try w.writeAll("; redialing now") else if (h.retry_in_ms > 0) try w.print("; retry in {s}", .{clock.span(&buf, h.retry_in_ms, .short)});
}

/// One line: the host (or "the hub" before it said hello), its link
/// state and why it is not up (or why an up link is suspect: flapping),
/// and when it was last heard from then.
pub fn writeHostText(w: *std.Io.Writer, h: peermail.HostInfo) !void {
    try w.print("host {s}: link {s}", .{ if (h.host.len > 0) h.host else "(the hub, not heard from yet)", @tagName(h.link) });
    if (h.why != null) {
        try w.writeAll(" (");
        try writeWhy(w, h);
        try w.writeAll(")");
    }
    switch (h.link) {
        .up => {},
        .down, .unsupported => {
            var buf: [clock.ISO_LEN]u8 = undefined;
            if (h.last_seen_ms > 0) if (clock.isoLocal(&buf, h.last_seen_ms)) |iso| try w.print(", last heard {s}", .{iso});
        },
    }
}

fn nonEmpty(s: []const u8) ?[]const u8 {
    return if (s.len > 0) s else null;
}

pub fn listLine(pi: peermail.PeerInfo, is_self: bool, detail: bool) ListLine {
    var l: ListLine = .{
        .address = pi.address,
        .alias = nonEmpty(pi.alias),
        .host = nonEmpty(pi.host),
        .app = nonEmpty(pi.app),
        .state = @tagName(pi.state),
        .attention = if (pi.state.attention()) |at| @tagName(at) else null,
        .work = if (pi.work) |wk| (if (pi.live and !wk.isEmpty()) wk else null) else null,
        .live = pi.live,
        .polls = if (pi.live and pi.polls) true else null,
        .no_mcp = if (!pi.live and pi.no_mcp) true else null,
        .pending = pi.pending,
        .last_seen_ms = pi.last_seen_ms,
        .model = nonEmpty(pi.model),
        .subject = nonEmpty(pi.subject),
        .note = nonEmpty(pi.note),
        .note_ms = if (pi.note.len > 0) pi.note_ms else null,
        .cwd = nonEmpty(pi.cwd),
        .facts = pi.facts,
        .self = if (is_self) true else null,
        .via_host = nonEmpty(pi.via_host),
        .link = if (pi.link) |k| @tagName(k) else null,
        .link_why = if (pi.link_why) |w| (if (pi.link != null and pi.link.? != .up) @tagName(w) else null) else null,
    };
    if (detail) {
        l.pid = pi.pid;
        l.durable = pi.durable;
        l.name_taken = pi.name_taken;
        l.last_notification = nonEmpty(pi.last_notification);
    }
    return l;
}

/// The session the list is read from, for its one `you:` line.
pub const SelfLine = struct { address: []const u8, alias: []const u8 = "", durable: bool, name_taken: bool };

/// A note older than this shows its age in the list text.
const NOTE_AGE_SHOWN_MS: i64 = 3_600_000;

/// `  note: TEXT` (or `  note 2h ago: TEXT` once it is an hour old); nothing without one.
fn writeNote(w: *std.Io.Writer, pi: peermail.PeerInfo, now_ms: i64) !void {
    if (pi.note.len == 0) return;
    var buf: [48]u8 = undefined;
    if (pi.note_ms > 0 and now_ms - pi.note_ms >= NOTE_AGE_SHOWN_MS)
        try w.print("  note {s}: {s}", .{ clock.ago(&buf, now_ms, pi.note_ms, .short), pi.note })
    else
        try w.print("  note: {s}", .{pi.note});
}

/// Whether `pi` is worth a row: a gone address with nothing pending and
/// no subject is only counted.
fn listed(pi: peermail.PeerInfo) bool {
    return pi.state != .gone or pi.no_mcp or pi.pending > 0 or pi.subject.len > 0;
}

/// Whether `field` of the rows' peers differs between them (a model or an
/// app every row shares says nothing per row).
fn varies(peers: []const peermail.PeerInfo, self: ?SelfLine, comptime field: []const u8) bool {
    var first: ?[]const u8 = null;
    for (peers) |pi| {
        if (!listed(pi) or isSelf(pi, self)) continue;
        const v = @field(pi, field);
        if (v.len == 0) continue;
        if (first) |f| {
            if (!std.mem.eql(u8, f, v)) return true;
        } else first = v;
    }
    return false;
}

fn isSelf(pi: peermail.PeerInfo, self: ?SelfLine) bool {
    return if (self) |s| std.mem.eql(u8, pi.address, s.address) else false;
}

/// What a row is called: its alias, else its address.
fn label(pi: peermail.PeerInfo) []const u8 {
    return if (pi.alias.len > 0) pi.alias else pi.address;
}

/// The whole list as compact text, for the `peer_list` tool and `sketerm peer
/// list` alike: the reader once (`self`), then one row per peer (its alias,
/// else its address; one state word, `ctx`, its working directory with
/// `~` for home, subject, pending, how long ago it was seen; the address
/// last when an alias led), the federation links, and a count of the gone
/// peers left out. `ctx` is the context the wake rule judges
/// (`peerwake.contextOf`); the account-wide rate limits and the cost stay
/// in the JSON. Model and app show only where they differ between peers;
/// `detail` adds the pid.
pub fn writeList(w: *std.Io.Writer, peers: []const peermail.PeerInfo, hosts: []const peermail.HostInfo, self: ?SelfLine, now_ms: i64, detail: bool) !void {
    if (self) |s| {
        const addr = if (s.address.len > 0) s.address else "(not registered yet)";
        var notes: [3][]const u8 = undefined;
        var n: usize = 0;
        if (s.alias.len > 0) {
            notes[n] = addr;
            n += 1;
        }
        if (s.durable) {
            notes[n] = "durable";
            n += 1;
        }
        if (s.name_taken) {
            notes[n] = "the name it asked for is taken";
            n += 1;
        }
        try w.print("you: {s}", .{if (s.alias.len > 0) s.alias else addr});
        for (notes[0..n], 0..) |note, i| try w.print("{s}{s}", .{ if (i == 0) " (" else ", ", note });
        if (n > 0) try w.writeAll(")");
        for (peers) |pi| if (isSelf(pi, self)) try writeNote(w, pi, now_ms);
        try w.writeAll("\n");
    }
    const show_model = varies(peers, self, "model");
    const show_app = varies(peers, self, "app");
    var width: usize = 0;
    var rows: usize = 0;
    var omitted: usize = 0;
    var unknown = false;
    var polling = false;
    var running_no_mcp = false;
    for (peers) |pi| {
        if (isSelf(pi, self)) continue;
        if (!listed(pi)) {
            omitted += 1;
            continue;
        }
        rows += 1;
        width = @max(width, label(pi).len);
    }
    if (rows == 0 and omitted == 0) try w.writeAll("no other peers\n");
    for (peers) |pi| {
        if (isSelf(pi, self) or !listed(pi)) continue;
        try w.writeAll(label(pi));
        try w.splatByteAll(' ', width - label(pi).len);
        var buf: [48]u8 = undefined;
        if (!pi.live and pi.no_mcp) {
            running_no_mcp = true;
            try w.writeAll("  no_mcp");
        } else if (pi.state == .gone) {
            try w.writeAll("  gone");
            if (pi.last_seen_ms > 0) try w.print(" {s}", .{clock.span(&buf, now_ms - pi.last_seen_ms, .short)});
        } else try w.print("  {s}", .{if (pi.live) @tagName(pi.state) else "offline"});
        if (pi.work) |wk| if (pi.live and !wk.isEmpty()) {
            try w.writeAll("  ");
            try wk.write(w);
        };
        if (pi.live and pi.state == .unknown) unknown = true;
        if (pi.live and pi.polls) {
            polling = true;
            try w.writeAll("  polls");
        }
        if (show_app and pi.app.len > 0) try w.print("  {s}", .{pi.app});
        if (peerwake.contextOf(pi.facts)) |ctx| try w.print("  ctx {s}", .{numtext.count(&buf, ctx)});
        if (show_model and pi.model.len > 0) try w.print("  {s}", .{pi.model});
        if (pi.cwd.len > 0) {
            var cb: [512]u8 = undefined;
            try w.print("  {s}", .{agentpush.shownCwd(&cb, pi.cwd)});
        }
        if (pi.subject.len > 0) try w.print("  subject {s}", .{pi.subject});
        if (pi.pending > 0) try w.print("  {d} pending", .{pi.pending});
        if (pi.state != .gone or pi.no_mcp) {
            const seen = clock.ago(&buf, now_ms, pi.last_seen_ms, .short);
            if (seen.len > 0 and !std.mem.eql(u8, seen, "just now")) try w.print("  seen {s}", .{seen});
        }
        if (pi.link) |k| if (k != .up) {
            try w.print("  link {s}", .{@tagName(k)});
            if (pi.link_why) |why| try w.print(" ({s})", .{why.label()});
        };
        if (detail) {
            if (pi.pid > 0) try w.print("  pid {d}", .{pi.pid});
        }
        if (pi.alias.len > 0) try w.print("  {s}", .{pi.address});
        // Free text last, so every other column keeps its place.
        try writeNote(w, pi, now_ms);
        try w.writeAll("\n");
    }
    if (hosts.len > 0) {
        try w.writeAll("links:");
        for (hosts, 0..) |h, i| {
            try w.print("{s} {s} {s}", .{ if (i > 0) "," else "", if (h.host.len > 0) h.host else "the hub (not heard from yet)", @tagName(h.link) });
            if (h.link != .up and (h.why != null or h.last_seen_ms > 0)) {
                try w.writeAll(" (");
                try writeWhy(w, h);
                var buf: [48]u8 = undefined;
                if (h.last_seen_ms > 0) try w.print("{s}seen {s}", .{ if (h.why != null) "; " else "", clock.ago(&buf, now_ms, h.last_seen_ms, .short) });
                try w.writeAll(")");
            }
        }
        try w.writeAll("\n");
    }
    if (omitted > 0) try w.print("+{d} gone with nothing pending and no subject\n", .{omitted});
    // The state comes only from a peer's own hooks; on a host whose client
    // config never got them, every peer there reads unknown.
    if (unknown) try w.writeAll("unknown = its client sends no presence: run `sketerm mcp setup` on its host, for the config dir it runs with\n");
    if (polling) try w.writeAll(POLLS_LINE ++ "\n");
    if (running_no_mcp) try w.writeAll(NO_MCP_LINE ++ "\n");
}

/// What `polls` in a list means, once per list.
pub const POLLS_LINE = "polls = no message is pushed into its session (Claude Code started without the sketerm channel): mail waits for its next turn or peer_read";
/// What `no_mcp` in a list means, once per list.
pub const NO_MCP_LINE = "no_mcp = its session runs (its hooks report) but its sketerm MCP server is down: mail waits until the server is back (/mcp in that session reconnects it)";

/// One recipient's outcome as a sender reads it, for `peer_send` and
/// `sketerm peer send` alike: the id, the recipient, the outcome and its
/// reason, the recipient's state, and whether it polls.
pub fn sentLine(arena: std.mem.Allocator, id: []const u8, x: peermail.RecipientResult) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.print("{s} to {s}: {s}", .{ if (id.len > 0) id else "message", x.to, @tagName(x.outcome) });
    if (x.reason) |why| try w.print(" ({s}: {s})", .{ @tagName(why), why.describe() });
    if (x.to_no_mcp) {
        try w.writeAll(", it is running with its MCP server down, so this waits until the server is back");
    } else if (x.to_state) |s| try w.print(", it is {s}", .{@tagName(s)});
    if (x.to_polls) try w.writeAll("; it polls (nothing is pushed into its session), so this may wait for its next turn");
    return aw.written();
}

// ── what a received item prints as ──────────────────────────────

const MessageLine = struct {
    kind: []const u8 = "message",
    id: []const u8,
    from: []const u8,
    /// The sender's alias when it sent; reply to it.
    from_alias: ?[]const u8 = null,
    sent_ms: i64,
    age_ms: i64,
    queued: bool,
    sender_live: bool,
    sender_state: []const u8,
    text: []const u8,
    sender_subject: ?[]const u8 = null,
    sender_note: ?[]const u8 = null,
    reply_to: ?[]const u8 = null,
    /// Slow mail (it would not have woken an assistant).
    slow: ?bool = null,
};

const EventLine = struct {
    kind: []const u8 = "event",
    id: []const u8,
    outcome: []const u8,
    reason: ?[]const u8 = null,
    to: []const u8,
    /// The recipient's alias; absent when it has none.
    to_alias: ?[]const u8 = null,
    queued_ms: i64,
};

const ExpiredLine = struct {
    kind: []const u8 = "expired_away",
    id: []const u8,
    from: []const u8,
    /// The sender's alias when it sent; absent when it had none.
    from_alias: ?[]const u8 = null,
    sent_ms: i64,
    expired_ms: i64,
};

const SentLine = struct {
    kind: []const u8 = "sent",
    id: []const u8,
    from: []const u8,
    to: []const u8,
    outcome: []const u8,
    reason: ?[]const u8 = null,
    to_state: ?[]const u8 = null,
    to_polls: ?bool = null,
    to_no_mcp: ?bool = null,
};

fn jsonLine(arena: std.mem.Allocator, v: anytype) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(arena, "{f}\n", .{std.json.fmt(v, .{ .emit_null_optional_fields = false })});
}

/// The printed form of one item: a JSON line, or the composed text the
/// MCP routes carry (`agentpush.composePeer`) and a blank line.
pub fn itemText(arena: std.mem.Allocator, item: agentpush.PeerItem, json: bool) ![]const u8 {
    if (!json) return std.fmt.allocPrint(arena, "{s}\n\n", .{(try agentpush.composePeer(arena, item)).content});
    return switch (item) {
        .message => |m| jsonLine(arena, MessageLine{
            .id = m.id,
            .from = m.from.address,
            .from_alias = nonEmpty(m.from.alias),
            .sent_ms = m.sent_ms,
            .age_ms = m.age_ms,
            .queued = m.queued,
            .sender_live = m.sender_live,
            .sender_state = @tagName(m.sender_state orelse if (m.sender_live) vocab.PeerState.unknown else .gone),
            .text = m.text,
            .sender_subject = nonEmpty(m.sender_subject),
            .sender_note = nonEmpty(m.sender_note),
            .reply_to = m.reply_to,
            .slow = if (m.quiet) true else null,
        }),
        .event => |e| jsonLine(arena, EventLine{ .id = e.id, .outcome = @tagName(e.outcome), .reason = if (e.reason) |r| @tagName(r) else null, .to = e.to, .to_alias = nonEmpty(e.to_alias), .queued_ms = e.queued_ms }),
        .expired_away => |x| jsonLine(arena, ExpiredLine{ .id = x.id, .from = x.from, .from_alias = nonEmpty(x.from_alias), .sent_ms = x.sent_ms, .expired_ms = x.expired_ms }),
    };
}

/// What a send printed: one line per recipient (a `to_list` send answers in
/// `results`, one id for all).
fn sentText(arena: std.mem.Allocator, from: []const u8, to: []const u8, r: peermail.SendReply, json: bool) ![]const u8 {
    const one = [_]peermail.RecipientResult{.{ .to = to, .outcome = r.outcome, .reason = r.reason, .to_state = r.to_state, .to_polls = r.to_polls, .to_no_mcp = r.to_no_mcp }};
    const each: []const peermail.RecipientResult = if (r.results.len > 0) r.results else &one;
    var out: std.ArrayList(u8) = .empty;
    for (each) |x| {
        const line = if (json) try jsonLine(arena, SentLine{
            .id = r.id,
            .from = from,
            .to = x.to,
            .outcome = @tagName(x.outcome),
            .reason = if (x.reason) |why| @tagName(why) else null,
            .to_state = if (x.to_state) |st| @tagName(st) else null,
            .to_polls = if (x.to_polls) true else null,
            .to_no_mcp = if (x.to_no_mcp) true else null,
        }) else try std.fmt.allocPrint(arena, "{s}\n", .{try sentLine(arena, r.id, x)});
        try out.appendSlice(arena, line);
    }
    return out.items;
}

/// Whether any recipient refused the send.
fn anyRefused(r: peermail.SendReply) bool {
    if (r.results.len == 0) return r.outcome == .refused;
    for (r.results) |x| if (x.outcome == .refused) return true;
    return false;
}

/// The request for `to`: one address, or a comma-separated list (`to_list`).
fn sendReq(arena: std.mem.Allocator, to: []const u8, text: []const u8, reply_to: ?[]const u8, quiet: bool) !peermail.SendReq {
    if (std.mem.indexOfScalar(u8, to, ',') == null) return .{ .to = to, .text = text, .reply_to = reply_to, .quiet = quiet };
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, to, ',');
    while (it.next()) |a| try list.append(arena, std.mem.trim(u8, a, " "));
    return .{ .to_list = list.items, .text = text, .reply_to = reply_to, .quiet = quiet };
}

// ── arguments ────────────────────────────────────────────────────

pub const Verb = enum { list, send, read, subject, note, alias };

pub const Cli = struct {
    verb: ?Verb = null,
    name: ?[]const u8 = null,
    app: []const u8 = APP_DEFAULT,
    json: bool = false,
    follow: bool = false,
    detail: bool = false,
    /// `subject --clear`, `note --clear`.
    clear: bool = false,
    reply_to: ?[]const u8 = null,
    /// `send --quiet`: slow mail, never waking the recipient.
    quiet: bool = false,
    /// `send`: the address (or a comma-separated list), then the text
    /// (null: read from stdin). `subject`, `note`, `alias`: the text
    /// (null: print the current one; a note is already trimmed).
    to: ?[]const u8 = null,
    text: ?[]const u8 = null,
    help: bool = false,

    pub const ParseError = error{ UnknownFlag, MissingValue, ExtraArgument, UnknownVerb, NoName, NoAddress, BadName, NotForVerb, TooManyAddresses, BadAlias } || peermail.SubjectError || peermail.NoteError;

    /// `env_name` (SKETERM_PEER_NAME) names the peer for send and read; a
    /// subject or note is set on another peer only by an explicit
    /// `--name`, so inside a session it always reaches that session's own
    /// peer, and an alias only ever from inside the session.
    pub fn parse(args: []const []const u8, env_name: ?[]const u8) ParseError!Cli {
        var o: Cli = .{};
        var i: usize = 0;
        var positional: usize = 0;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            const eql = std.mem.eql;
            if (eql(u8, a, "--help") or eql(u8, a, "-h")) {
                o.help = true;
            } else if (eql(u8, a, "--json")) {
                o.json = true;
            } else if (eql(u8, a, "--follow")) {
                o.follow = true;
            } else if (eql(u8, a, "--detail")) {
                o.detail = true;
            } else if (eql(u8, a, "--quiet")) {
                o.quiet = true;
            } else if (eql(u8, a, "--clear")) {
                o.clear = true;
            } else if (eql(u8, a, "--name") or eql(u8, a, "--app") or eql(u8, a, "--reply-to")) {
                if (i + 1 >= args.len) return error.MissingValue;
                i += 1;
                if (eql(u8, a, "--name")) o.name = args[i];
                if (eql(u8, a, "--app")) o.app = args[i];
                if (eql(u8, a, "--reply-to")) o.reply_to = args[i];
            } else if (a.len > 1 and a[0] == '-') {
                return error.UnknownFlag;
            } else {
                switch (positional) {
                    0 => o.verb = std.meta.stringToEnum(Verb, a) orelse return error.UnknownVerb,
                    1 => o.to = a,
                    2 => o.text = a,
                    else => return error.ExtraArgument,
                }
                positional += 1;
            }
        }
        if (o.help) return o;
        const verb = o.verb orelse return error.UnknownVerb;
        if (o.name == null and verb != .subject and verb != .note and verb != .alias) o.name = env_name;
        switch (verb) {
            .list => if (o.to != null) return error.ExtraArgument,
            .read => if (o.to != null) return error.ExtraArgument,
            .send => if (o.to == null) return error.NoAddress,
            .subject, .note => {
                if (o.text != null) return error.ExtraArgument;
                o.text = o.to;
                o.to = null;
                if (o.clear and o.text != null) return error.ExtraArgument;
                if (o.text) |tx| {
                    if (verb == .subject) try peermail.checkSubject(tx) else o.text = try peermail.checkNote(tx);
                }
            },
            .alias => {
                if (o.text != null) return error.ExtraArgument;
                if (o.name != null) return error.NotForVerb;
                o.text = o.to;
                o.to = null;
                if (o.text) |tx| if (!peeraddr.validAlias(tx) or tx.len > peeraddr.SLUG_MAX) return error.BadAlias;
            },
        }
        if (o.follow and verb != .read) return error.NotForVerb;
        if ((o.reply_to != null or o.quiet) and verb != .send) return error.NotForVerb;
        if (verb == .send and std.mem.count(u8, o.to.?, ",") >= peermail.PEER_TO_MAX) return error.TooManyAddresses;
        if (o.clear and verb != .subject and verb != .note) return error.NotForVerb;
        if (verb != .list and verb != .alias) {
            const n = o.name orelse if (verb == .subject or verb == .note) return o else return error.NoName;
            const addr = peeraddr.Address.parse(n) catch return error.BadName;
            if (addr.host != null) return error.BadName;
        }
        return o;
    }
};

pub const HELP =
    \\Usage: sketerm peer list [--json] [--detail]
    \\       sketerm peer send --name NAME [--json] [--quiet] [--reply-to ID] TO[,TO...] [TEXT]
    \\       sketerm peer read --name NAME [--json] [--follow]
    \\       sketerm peer subject [--name NAME] [TEXT | --clear]
    \\       sketerm peer note [--name NAME] [TEXT | --clear]
    \\       sketerm peer alias [ALIAS]
    \\       sketerm peer hub add NAME [--host SSH_TARGET] [--inbound] [--dry-run]
    \\       sketerm peer hub remove NAME [--dry-run]
    \\       sketerm peer join HUB [--host SSH_TARGET] [--dry-run]
    \\       sketerm peer leave [--dry-run]
    \\       sketerm peer status
    \\       (--app APP on send and read: the app the peer registers as, default cli)
    \\
    \\Takes part in peer messaging (the peer_* tools of `sketerm mcp`) from any
    \\program. NAME (or SKETERM_PEER_NAME) is the alias this program asks
    \\for, and its durable address follows from it; mail for it waits in the
    \\per-user daemon while no reader runs. TO is an alias or an address
    \\(peer_list). send sends TEXT (or stdin when absent) and prints what
    \\became of it, one line per recipient (TO may be a comma-separated list:
    \\one message, one id); --quiet makes it slow mail, which never wakes an
    \\assistant; read prints the messages waiting for NAME and exits; read
    \\--follow keeps NAME registered and prints each message as it arrives
    \\(acknowledged once printed), reconnecting when the daemon goes away,
    \\until SIGINT/SIGTERM or the end of its stdin (when stdin is a pipe,
    \\socket or terminal). While it follows, each line on its stdin
    \\{"to":TO,"text":TEXT,"reply_to":ID?,"quiet":BOOL?} is sent from NAME,
    \\answered with a "sent" line. --json prints one JSON object per line:
    \\messages {"kind":"message","id","from","from_alias"?,"sent_ms","age_ms",
    \\"queued","sender_live","sender_state","sender_subject"?,"sender_note"?,"text",
    \\"reply_to"?,"slow"?}, and "event" / "expired_away" for what became of mail.
    \\
    \\subject sets what a session works on, shown by peer_list, in its peer
    \\messages and on its sketerm tab: at most 200 bytes of text without
    \\control characters; --clear removes it, no TEXT prints it. Run inside an
    \\assistant session (Claude Code: `! sketerm peer subject "..."`) it sets
    \\that session's own peer, found through this process's ancestry; --name
    \\NAME sets the peer NAME (an alias or an address) instead (a `read
    \\--follow` program, or any session). The daemon keeps it with the
    \\address, across server restarts.
    \\
    \\note sets a peer's own note: one line (at most 120 bytes, surrounding
    \\whitespace trimmed) on what it is doing now, shown at the end of its
    \\peer_list row and in its peer messages' headers. It is the
    \\assistant's or program's own word, unlike the subject, which is its
    \\user's (an MCP session sets it with the peer_set_note tool). Inside an
    \\assistant session it sets that session's peer; --name NAME sets the
    \\live peer NAME (a `read --follow` program). The daemon keeps it while
    \\a server of the address is connected and stops showing it 4 hours
    \\after it was last set. --clear removes it, no TEXT prints it.
    \\
    \\alias sets the name this session is reached by: lowercase letters,
    \\digits and single dashes, at most 48 bytes, refused while a live
    \\session holds it (one whose session is gone hands it over, with its
    \\waiting mail). Run inside an assistant session (Claude Code: `!
    \\sketerm peer alias zenit`); no ALIAS prints the current one. A session
    \\otherwise takes its alias from its title, once.
    \\
    \\hub add, hub remove, join and leave set up federation (peers on other
    \\hosts) by editing config.conf in place, keeping every other line and
    \\comment. hub add makes this daemon the hub and links [domain.NAME]:
    \\dialed at SSH_TARGET (default NAME, an existing host is kept), or with
    \\--inbound a member that calls in. hub remove unlinks it. join makes this
    \\daemon a call-in member of the hub HUB, dialed at SSH_TARGET (default
    \\HUB), and prints the hub add line to run on the hub; leave undoes it.
    \\A daemon is never hub and member at once. --dry-run prints the changes
    \\without writing them. The daemon reads these keys only when it starts:
    \\restart it (no sessions attached) afterwards. status prints this host's
    \\role, its federated domains and, from the daemon, each link's state.
    \\
    \\Exit status: 0 done, 1 the daemon could not be reached, the name is held
    \\by another live peer, a send was refused, no server or peer was found
    \\for subject, note or alias, an alias is held by a live session, a note
    \\names no live peer, or a federation edit was refused (hub and member at
    \\once, no such domain); 2 bad usage (a refused subject, note, alias,
    \\name or host too).
    \\
;

// ── the command ──────────────────────────────────────────────────

var quit_flag: bool = false;

fn onQuit(_: c_int) callconv(.c) void {
    @atomicStore(bool, &quit_flag, true, .seq_cst);
}

fn quitting() bool {
    return @atomicLoad(bool, &quit_flag, .seq_cst);
}

fn say(fd: c_int, bytes: []const u8) void {
    _ = fdio.writeAll(fd, bytes);
}

fn fail(comptime fmt: []const u8, args: anytype) u8 {
    var buf: [512]u8 = undefined;
    say(2, std.fmt.bufPrint(&buf, "peer: " ++ fmt ++ "\n", args) catch "peer: failed\n");
    return 1;
}

/// Every verb of `sketerm peer`, from both verb enums.
const UNKNOWN_VERB = blk: {
    const names = std.meta.fieldNames(Verb).* ++ std.meta.fieldNames(peer_setup.Verb).*;
    var s: []const u8 = "peer: say one of";
    for (names, 0..) |n, i| s = s ++ (if (i == 0) " " else ", ") ++ n;
    break :blk s ++ " (see --help)\n";
};

/// `sketerm peer ...`.
/// @return the process exit status.
pub fn cli(allocator: std.mem.Allocator, args: []const []const u8) u8 {
    if (peer_setup.claims(args)) return peer_setup.cli(allocator, args);
    const o = Cli.parse(args, env.nonEmpty(ENV_NAME)) catch |err| {
        say(2, switch (err) {
            error.UnknownFlag => "peer: unknown flag (see --help)\n",
            error.MissingValue => "peer: flag needs a value\n",
            error.ExtraArgument => "peer: too many arguments (see --help)\n",
            error.UnknownVerb => UNKNOWN_VERB,
            error.NoName => "peer: --name NAME (or SKETERM_PEER_NAME) is required: the address this program is reached at\n",
            error.NoAddress => "peer: send needs the address to send to\n",
            error.BadName => "peer: the name must be 1-64 of A-Za-z0-9._- (no host)\n",
            error.NotForVerb => "peer: --follow is for read, --reply-to and --quiet for send, --clear for subject and note\n",
            error.TooManyAddresses => std.fmt.comptimePrint("peer: send takes at most {d} addresses\n", .{peermail.PEER_TO_MAX}),
            error.BadAlias => std.fmt.comptimePrint("peer: an alias is lowercase letters, digits and single dashes, at most {d} bytes\n", .{peeraddr.SLUG_MAX}),
            error.SubjectTooLong, error.SubjectNotText => {
                _ = fail("{s}", .{peermail.subjectRefusal(@errorCast(err))});
                return 2;
            },
            error.NoteTooLong, error.NoteNotText => {
                _ = fail("{s}", .{peermail.noteRefusal(@errorCast(err))});
                return 2;
            },
        });
        return 2;
    };
    if (o.help) {
        say(1, HELP);
        return 0;
    }
    platform.ignoreSigpipe();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (o.verb.? == .read and o.follow) return follow(allocator, o);
    if (o.verb.? == .subject) return subject(allocator, arena, o);
    if (o.verb.? == .note) return noteCmd(allocator, arena, o);
    if (o.verb.? == .alias) return aliasCmd(allocator, arena, o);

    var link = Link.open(allocator) catch |e| return fail("{s}", .{linkError(e)});
    defer link.close();
    switch (o.verb.?) {
        .list => {
            const reply = link.peer.list(arena, REPLY_MS) catch return fail("the daemon did not answer the peer list", .{});
            var aw: std.Io.Writer.Allocating = .init(arena);
            if (o.json) {
                const lines = arena.alloc(ListLine, reply.value.peers.len) catch return 1;
                for (reply.value.peers, lines) |pi, *l| l.* = listLine(pi, false, o.detail);
                const hosts = arena.alloc(HostLine, reply.value.hosts.len) catch return 1;
                for (reply.value.hosts, hosts) |h, *l| l.* = hostLine(h);
                aw.writer.print("{f}\n", .{std.json.fmt(.{ .peers = lines, .hosts = hosts, .federation = @tagName(reply.value.federation) }, .{ .emit_null_optional_fields = false })}) catch return 1;
            } else {
                writeList(&aw.writer, reply.value.peers, reply.value.hosts, null, clock.wallMs(), o.detail) catch return 1;
            }
            say(1, aw.written());
            return 0;
        },
        .send => {
            const text = o.text orelse readAllStdin(arena) orelse return fail("could not read the text from stdin", .{});
            _ = link.register(arena, o) catch |e| return fail("{s}", .{linkError(e)});
            const req = sendReq(arena, o.to.?, text, o.reply_to, o.quiet) catch return 1;
            const reply = link.peer.send(arena, req, REPLY_MS) catch |e| return fail("{s}", .{sendError(e)});
            say(1, sentText(arena, o.name.?, o.to.?, reply.value, o.json) catch return 1);
            return if (anyRefused(reply.value)) 1 else 0;
        },
        .read => {
            _ = link.register(arena, o) catch |e| return fail("{s}", .{linkError(e)});
            // The broker pushes waiting mail right after the registration.
            var ids: std.ArrayList([]const u8) = .empty;
            while (true) {
                const push = (link.peer.nextPush(arena, READ_QUIET_MS) catch break) orelse break;
                const item = itemOf(push) orelse continue;
                if (!fdio.writeAll(1, itemText(arena, item, o.json) catch continue)) break;
                ids.append(arena, idOf(item)) catch break;
            }
            link.peer.ack(ids.items) catch {};
            return 0;
        },
        .subject, .note, .alias => unreachable,
    }
}

/// `sketerm peer subject`: set (`o.text`), clear (`o.clear`) or print the
/// subject of `o.name`, else of this process's own session.
fn subject(allocator: std.mem.Allocator, arena: std.mem.Allocator, o: Cli) u8 {
    const value: ?[]const u8 = if (o.clear) "" else o.text;
    if (o.name) |name| {
        var link = Link.open(allocator) catch |e| return fail("{s}", .{linkError(e)});
        defer link.close();
        if (!link.peer.subjects()) return fail("the per-user sketerm daemon predates peer subjects (restart it idle)", .{});
        const r = link.peer.subject(arena, name, value, REPLY_MS) catch return fail("the daemon did not answer the subject request", .{});
        if (r.value.refused) |why| return fail("{s}", .{why});
        if (!r.value.found) return fail("no peer {s} here: neither a live peer nor a durable address this daemon knows", .{name});
        say(1, setText(arena, "subject", name, value, r.value.subject) catch return 1);
        return 0;
    }
    const own = mcp_hook.serversOfThisClient(arena, null);
    if (own.len == 0) return fail("no sketerm MCP server in this process's ancestry: run it inside an assistant session (Claude Code: ! sketerm peer subject ...), or name a peer with --name", .{});
    if (value) |v| {
        const line = agentwait.encodePresence(arena, .{ .event = agentwait.SUBJECT_EVENT, .subject = v }) catch return 1;
        var took: usize = 0;
        for (own) |e| took += @intFromBool(agentwait.postPresence(e.agent_socket, line));
        if (took == 0) return fail("this session's server did not take the subject", .{});
    }
    // The broker names the server's peer (its registration carries the pid).
    const me = ownPeer(allocator, arena, own) orelse {
        if (value == null) return fail("this session's server is not registered as a peer with the per-user daemon", .{});
        say(1, setText(arena, "subject", "this session", value, "") catch return 1);
        return 0;
    };
    say(1, setText(arena, "subject", if (me.alias.len > 0) me.alias else me.address, value, me.subject) catch return 1);
    return 0;
}

/// `sketerm peer note`: set (`o.text`), clear (`o.clear`) or print the
/// note of the live peer `o.name`, else of this process's own session's
/// peer (found as `subject` finds it).
fn noteCmd(allocator: std.mem.Allocator, arena: std.mem.Allocator, o: Cli) u8 {
    const value: ?[]const u8 = if (o.clear) "" else o.text;
    var target: []const u8 = undefined;
    var shown: []const u8 = undefined;
    if (o.name) |name| {
        target = name;
        shown = name;
    } else {
        const own = mcp_hook.serversOfThisClient(arena, null);
        if (own.len == 0) return fail("no sketerm MCP server in this process's ancestry: run it inside an assistant session (Claude Code: ! sketerm peer note ...), or name a live peer with --name", .{});
        const me = ownPeer(allocator, arena, own) orelse return fail("this session's server is not registered as a peer with the per-user daemon", .{});
        target = me.address;
        shown = if (me.alias.len > 0) me.alias else me.address;
    }
    var link = Link.open(allocator) catch |e| return fail("{s}", .{linkError(e)});
    defer link.close();
    if (!link.peer.notes()) return fail("the per-user sketerm daemon predates peer notes (restart it idle)", .{});
    const r = link.peer.note(arena, target, value, REPLY_MS) catch return fail("the daemon did not answer the note request", .{});
    if (r.value.refused) |why| return fail("{s}", .{why});
    if (!r.value.found) return fail("no peer {s} here: neither a live peer nor a durable address this daemon knows", .{target});
    say(1, setText(arena, "note", shown, value, r.value.note) catch return 1);
    return 0;
}

/// What `subject` and `note` print (`what` names the field): the
/// confirmation of a set or clear, or the current value alone (nothing
/// when there is none).
fn setText(arena: std.mem.Allocator, comptime what: []const u8, address: []const u8, value: ?[]const u8, current: []const u8) ![]const u8 {
    const v = value orelse return if (current.len > 0) std.fmt.allocPrint(arena, "{s}\n", .{current}) else "";
    if (v.len == 0) return std.fmt.allocPrint(arena, what ++ " of {s} cleared\n", .{address});
    return std.fmt.allocPrint(arena, what ++ " of {s}: {s}\n", .{ address, v });
}

/// The live peer of this host one of `own` registered (by its pid).
fn ownPeer(allocator: std.mem.Allocator, arena: std.mem.Allocator, own: []const @import("mcp_registry.zig").Entry) ?struct { address: []const u8, subject: []const u8, alias: []const u8 } {
    var link = Link.open(allocator) catch return null;
    defer link.close();
    const reply = link.peer.list(arena, REPLY_MS) catch return null;
    for (reply.value.peers) |pi| {
        if (!pi.live or pi.via_host.len > 0) continue;
        for (own) |e| if (e.pid == pi.pid) return .{ .address = pi.address, .subject = pi.subject, .alias = pi.alias };
    }
    return null;
}

/// How long `alias` waits for the daemon to give the asked alias.
const ALIAS_WAIT_MS: i64 = 3_000;

/// `sketerm peer alias`: set (`o.text`) or print the alias of this
/// process's own session, refused while a live session holds it.
fn aliasCmd(allocator: std.mem.Allocator, arena: std.mem.Allocator, o: Cli) u8 {
    const own = mcp_hook.serversOfThisClient(arena, null);
    if (own.len == 0) return fail("no sketerm MCP server in this process's ancestry: run it inside an assistant session (Claude Code: ! sketerm peer alias ...)", .{});
    var link = Link.open(allocator) catch |e| return fail("{s}", .{linkError(e)});
    defer link.close();
    if (!link.peer.aliases()) return fail("the per-user sketerm daemon predates aliases (restart it idle)", .{});
    const me = ownPeer(allocator, arena, own) orelse return fail("this session's server is not registered as a peer with the per-user daemon", .{});
    const want = o.text orelse {
        if (me.alias.len > 0) say(1, std.fmt.allocPrint(arena, "{s}\n", .{me.alias}) catch return 1);
        return 0;
    };
    if (std.mem.eql(u8, me.alias, want)) {
        say(1, std.fmt.allocPrint(arena, "alias of {s}: {s}\n", .{ me.address, want }) catch return 1);
        return 0;
    }
    const reply = link.peer.list(arena, REPLY_MS) catch return fail("the daemon did not answer the peer list", .{});
    for (reply.value.peers) |pi| {
        if (pi.live and std.mem.eql(u8, pi.alias, want) and !std.mem.eql(u8, pi.address, me.address))
            return fail("{s} is held by a live session ({s}); pick another", .{ want, pi.address });
    }
    const line = agentwait.encodePresence(arena, .{ .event = agentwait.ALIAS_EVENT, .alias = want }) catch return 1;
    var took: usize = 0;
    for (own) |e| took += @intFromBool(agentwait.postPresence(e.agent_socket, line));
    if (took == 0) return fail("this session's server did not take the alias", .{});
    const deadline = clock.nowMs() + ALIAS_WAIT_MS;
    while (clock.nowMs() < deadline) {
        _ = c.poll(null, 0, 100);
        const now = ownPeer(allocator, arena, own) orelse continue;
        if (std.mem.eql(u8, now.alias, want)) {
            say(1, std.fmt.allocPrint(arena, "alias of {s}: {s}\n", .{ now.address, want }) catch return 1);
            return 0;
        }
    }
    return fail("the daemon did not give {s} (a live session may have taken it meanwhile)", .{want});
}

pub const LinkError = error{ Unreachable, NoPeers, NameTaken, NoAnswer };

fn linkError(e: LinkError) []const u8 {
    return switch (e) {
        error.Unreachable => "the per-user sketerm daemon cannot be reached",
        error.NoPeers => "the per-user sketerm daemon predates peer messaging (restart it idle)",
        error.NameTaken => "that name is held by another live peer (a running `peer read --follow` sends what its stdin says)",
        error.NoAnswer => "the daemon did not answer the registration",
    };
}

/// One connection to the per-user daemon.
pub const Link = struct {
    allocator: std.mem.Allocator,
    conn: *muxclient.Conn,
    peer: peerclient.Peer,

    pub fn open(allocator: std.mem.Allocator) LinkError!Link {
        const conn = allocator.create(muxclient.Conn) catch return error.Unreachable;
        conn.* = muxclient.Conn.connectLocalAutostartAt(allocator, null) catch {
            allocator.destroy(conn);
            return error.Unreachable;
        };
        var l: Link = .{ .allocator = allocator, .conn = conn, .peer = peerclient.Peer.init(conn) };
        if (!l.peer.available()) {
            l.close();
            return error.NoPeers;
        }
        return l;
    }

    pub fn close(self: *Link) void {
        self.peer.deinit();
        self.conn.deinit();
        self.allocator.destroy(self.conn);
    }

    /// Register `o.name` and wait for the broker's answer: with aliases,
    /// at the durable `n-` address of its slug, asking for the name as its
    /// alias; from an older daemon, at the name itself.
    /// @return the alias the broker gave ("" = none), in `arena`.
    fn register(self: *Link, arena: std.mem.Allocator, o: Cli) LinkError![]const u8 {
        var cwd_buf: [4096]u8 = undefined;
        const cwd: []const u8 = if (c.getcwd(&cwd_buf, cwd_buf.len)) |p| std.mem.span(@as([*:0]u8, @ptrCast(p))) else "";
        var nb: [peeraddr.NAMED_NAME_LEN]u8 = undefined;
        const name = o.name.?;
        const named: ?[]const u8 = if (self.peer.aliases()) peeraddr.namedAddress(&nb, name) else null;
        self.peer.register(.{ .address = named orelse name, .durable = true, .app = o.app, .cwd = cwd, .pid = @intCast(c.getpid()), .slow_mail = true, .alias = if (named != null) name else null }) catch return error.Unreachable;
        const deadline = clock.nowMs() + REPLY_MS;
        while (clock.nowMs() < deadline) {
            const push = (self.peer.nextPush(arena, deadline - clock.nowMs()) catch return error.Unreachable) orelse break;
            switch (push) {
                .registered => |r| {
                    const s = r.value.self orelse continue;
                    if (s.name_taken) return error.NameTaken;
                    return arena.dupe(u8, s.alias) catch "";
                },
                else => {},
            }
        }
        return error.NoAnswer;
    }
};

fn itemOf(push: peerclient.Push) ?agentpush.PeerItem {
    return switch (push) {
        .deliver => |d| .{ .message = d.value },
        .event => |e| .{ .event = e.value },
        .registered => null,
    };
}

fn idOf(item: agentpush.PeerItem) []const u8 {
    return switch (item) {
        .message => |m| m.id,
        .event => |e| e.id,
        .expired_away => |x| x.id,
    };
}

fn readAllStdin(arena: std.mem.Allocator) ?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var tmp: [8192]u8 = undefined;
    while (out.items.len <= peermail.PEER_TEXT_MAX) {
        const n = c.read(0, &tmp, tmp.len);
        if (n == 0) return out.items;
        if (n < 0) {
            if (std.posix.errno(n) == .INTR) continue;
            return null;
        }
        out.appendSlice(arena, tmp[0..@intCast(n)]) catch return null;
    }
    // Above the cap: the broker refuses it `too_large`, the outcome says so.
    return out.items;
}

/// Whether the end of stdin means "stop": a pipe, socket or terminal
/// (a parent that closes it is gone); /dev/null or a file is not watched.
fn stdinWatched() bool {
    if (c.isatty(0) == 1) return true;
    var st: c.struct_stat = undefined;
    if (c.fstat(0, &st) != 0) return false;
    const fmt = st.st_mode & c.S_IFMT;
    return fmt == c.S_IFIFO or fmt == c.S_IFSOCK;
}

/// A line a follower read on its stdin.
const SendLine = struct { to: []const u8 = "", text: []const u8 = "", reply_to: ?[]const u8 = null, quiet: bool = false };

/// Why a send got no answer.
fn sendError(e: anyerror) []const u8 {
    return if (e == error.Unsupported) "the daemon predates slow mail and address lists (--quiet, TO,TO); restart it idle with a newer build" else "the daemon did not answer the send";
}

/// `read --follow`: until a quit signal or the end of a watched stdin.
fn follow(allocator: std.mem.Allocator, o: Cli) u8 {
    var sa: c.struct_sigaction = std.mem.zeroes(c.struct_sigaction);
    platform.setSigHandler(&sa, onQuit);
    // No SA_RESTART: a blocked poll returns at once.
    _ = c.sigaction(c.SIGTERM, &sa, null);
    _ = c.sigaction(c.SIGINT, &sa, null);
    var watch_stdin = stdinWatched();
    var inbuf: std.ArrayList(u8) = .empty;
    defer inbuf.deinit(allocator);
    var backoff = RECONNECT;
    while (!quitting()) {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var link = Link.open(allocator) catch |e| {
            if (backoff.delay_ms == 0) _ = fail("{s}; retrying", .{linkError(e)});
            if (!pause(backoff.fail(clock.nowMs()), watch_stdin)) break;
            continue;
        };
        defer link.close();
        const got = link.register(arena, o) catch |e| {
            if (e == error.NameTaken) return fail("{s}", .{linkError(e)});
            if (!pause(backoff.fail(clock.nowMs()), watch_stdin)) break;
            continue;
        };
        // A live session holding the name suffixes this program's alias.
        var sb: [peeraddr.SLUG_MAX]u8 = undefined;
        if (got.len > 0) if (peeraddr.slugify(&sb, o.name.?)) |slug| if (!std.mem.eql(u8, got, slug)) {
            _ = fail("{s} is held by a live session; this program is reached as {s}", .{ slug, got });
        };
        backoff.reset();
        // Serve this connection until it drops, a signal, or stdin ends.
        while (!quitting()) {
            // What already arrived first (the registration's mail included).
            while (true) {
                var item_arena = std.heap.ArenaAllocator.init(allocator);
                defer item_arena.deinit();
                const ia = item_arena.allocator();
                const push = (link.peer.nextPush(ia, 0) catch break) orelse break;
                const item = itemOf(push) orelse continue;
                // Written whole (an unbuffered write), then acknowledged.
                if (!fdio.writeAll(1, itemText(ia, item, o.json) catch continue)) return 0;
                link.peer.ack(&.{idOf(item)}) catch break;
            }
            var pfds = [2]c.struct_pollfd{
                .{ .fd = link.conn.fd, .events = c.POLLIN, .revents = 0 },
                .{ .fd = 0, .events = c.POLLIN, .revents = 0 },
            };
            const rc = c.poll(&pfds, if (watch_stdin) 2 else 1, 1000);
            if (rc < 0) {
                if (std.posix.errno(rc) == .INTR) continue;
                return fail("poll failed", .{});
            }
            if (watch_stdin and pfds[1].revents != 0) {
                var tmp: [8192]u8 = undefined;
                const n = c.read(0, &tmp, tmp.len);
                if (n == 0) return 0;
                if (n < 0) {
                    if (std.posix.errno(n) != .INTR and std.posix.errno(n) != .AGAIN) watch_stdin = false;
                } else {
                    inbuf.appendSlice(allocator, tmp[0..@intCast(n)]) catch return fail("out of memory", .{});
                    if (!sendLines(arena, &link, o, &inbuf)) break;
                    if (inbuf.items.len > STDIN_LINE_MAX) {
                        _ = fail("a stdin line longer than {d} bytes was dropped", .{STDIN_LINE_MAX});
                        inbuf.clearRetainingCapacity();
                    }
                }
            }
            if (pfds[0].revents != 0 and !link.conn.fillAvailable()) break;
        }
        if (!quitting()) _ = fail("the daemon went away; reconnecting", .{});
    }
    return 0;
}

/// Send every complete line in `inbuf`, printing each outcome.
/// @return false when the connection failed.
fn sendLines(arena: std.mem.Allocator, link: *Link, o: Cli, inbuf: *std.ArrayList(u8)) bool {
    while (std.mem.indexOfScalar(u8, inbuf.items, '\n')) |nl| {
        const raw = arena.dupe(u8, std.mem.trim(u8, inbuf.items[0..nl], " \r\t")) catch return false;
        std.mem.copyForwards(u8, inbuf.items[0 .. inbuf.items.len - nl - 1], inbuf.items[nl + 1 ..]);
        inbuf.shrinkRetainingCapacity(inbuf.items.len - nl - 1);
        if (raw.len == 0) continue;
        const line = std.json.parseFromSliceLeaky(SendLine, arena, raw, .{ .ignore_unknown_fields = true }) catch {
            _ = fail("a stdin line is not {{\"to\":...,\"text\":...}} JSON; skipped", .{});
            continue;
        };
        if (line.to.len == 0) {
            _ = fail("a stdin line names no \"to\"; skipped", .{});
            continue;
        }
        const reply = link.peer.send(arena, .{ .to = line.to, .text = line.text, .reply_to = line.reply_to, .quiet = line.quiet }, REPLY_MS) catch |e| {
            if (e != error.Unsupported) return false;
            _ = fail("{s}", .{sendError(e)});
            continue;
        };
        say(1, sentText(arena, o.name.?, line.to, reply.value, o.json) catch continue);
    }
    return true;
}

/// Wait `ms` (a reconnect's backoff), ending early on a quit signal.
/// @return false when the follower should stop (a signal, or the end of a watched stdin).
fn pause(ms: i64, watch_stdin: bool) bool {
    const deadline = clock.nowMs() + ms;
    while (!quitting()) {
        const left = deadline - clock.nowMs();
        if (left <= 0) return true;
        var pfd = c.struct_pollfd{ .fd = 0, .events = c.POLLIN, .revents = 0 };
        const rc = c.poll(&pfd, if (watch_stdin) 1 else 0, @intCast(@min(left, 1000)));
        if (rc > 0 and watch_stdin) {
            var tmp: [1]u8 = undefined;
            // Lines sent while no daemon answers are not kept.
            if (c.read(0, &tmp, 1) == 0) return false;
        }
    }
    return false;
}

// ── tests ────────────────────────────────────────────────────────

const t = std.testing;

test "arguments: a name for send and read (flag or SKETERM_PEER_NAME), none for list; subject's text or --clear" {
    const r = try Cli.parse(&.{ "read", "--follow", "--json", "--name", "webapp" }, null);
    try t.expectEqual(Verb.read, r.verb.?);
    try t.expect(r.follow and r.json);
    try t.expectEqualStrings("webapp", r.name.?);
    try t.expectEqualStrings(APP_DEFAULT, r.app);
    const s = try Cli.parse(&.{ "send", "alice", "hello there", "--reply-to", "m-1", "--app", "tavern" }, "webapp");
    try t.expectEqualStrings("webapp", s.name.?);
    try t.expectEqualStrings("alice", s.to.?);
    try t.expectEqualStrings("hello there", s.text.?);
    try t.expectEqualStrings("tavern", s.app);
    try t.expect((try Cli.parse(&.{ "send", "alice" }, "w")).text == null);
    try t.expect((try Cli.parse(&.{"list"}, null)).name == null);
    try t.expectError(error.NoName, Cli.parse(&.{"read"}, null));
    try t.expectError(error.NoAddress, Cli.parse(&.{ "send", "--name", "w" }, null));
    try t.expectError(error.BadName, Cli.parse(&.{ "read", "--name", "host/w" }, null));
    try t.expectError(error.NotForVerb, Cli.parse(&.{ "send", "--follow", "--name", "w", "x" }, null));
    try t.expectError(error.UnknownVerb, Cli.parse(&.{"drain"}, null));
    try t.expectError(error.UnknownFlag, Cli.parse(&.{ "list", "--bogus" }, null));
    try t.expectError(error.ExtraArgument, Cli.parse(&.{ "read", "--name", "w", "extra" }, null));
    // subject: the text, --clear or nothing (print); SKETERM_PEER_NAME never
    // redirects it, only --name does.
    const set = try Cli.parse(&.{ "subject", "template links" }, "env-name");
    try t.expectEqual(Verb.subject, set.verb.?);
    try t.expectEqualStrings("template links", set.text.?);
    try t.expect(set.name == null and set.to == null and !set.clear);
    const clr = try Cli.parse(&.{ "subject", "--clear", "--name", "webapp" }, null);
    try t.expect(clr.clear and clr.text == null);
    try t.expectEqualStrings("webapp", clr.name.?);
    const ask = try Cli.parse(&.{"subject"}, null);
    try t.expect(ask.text == null and !ask.clear);
    try t.expectError(error.ExtraArgument, Cli.parse(&.{ "subject", "--clear", "x" }, null));
    try t.expectError(error.ExtraArgument, Cli.parse(&.{ "subject", "a", "b" }, null));
    try t.expectError(error.SubjectTooLong, Cli.parse(&.{ "subject", "x" ** (peermail.SUBJECT_MAX + 1) }, null));
    try t.expectError(error.SubjectNotText, Cli.parse(&.{ "subject", "two\nlines" }, null));
    try t.expectError(error.BadName, Cli.parse(&.{ "subject", "--name", "h/w", "x" }, null));
    try t.expectError(error.NotForVerb, Cli.parse(&.{ "list", "--clear" }, null));
    // alias: a valid alias or nothing (print), only for this session.
    const al = try Cli.parse(&.{ "alias", "zenit-2" }, "env-name");
    try t.expectEqual(Verb.alias, al.verb.?);
    try t.expectEqualStrings("zenit-2", al.text.?);
    try t.expect(al.name == null);
    try t.expect((try Cli.parse(&.{"alias"}, null)).text == null);
    try t.expectError(error.BadAlias, Cli.parse(&.{ "alias", "Zenit" }, null));
    try t.expectError(error.BadAlias, Cli.parse(&.{ "alias", "p-1" }, null));
    try t.expectError(error.NotForVerb, Cli.parse(&.{ "alias", "--name", "x", "y" }, null));
    // note: like subject (only --name redirects it), the text trimmed; one
    // line of at most NOTE_MAX bytes.
    const nt = try Cli.parse(&.{ "note", "  landing M015; holding the zenit-cms push\n" }, "env-name");
    try t.expectEqual(Verb.note, nt.verb.?);
    try t.expectEqualStrings("landing M015; holding the zenit-cms push", nt.text.?);
    try t.expect(nt.name == null);
    const nc = try Cli.parse(&.{ "note", "--clear", "--name", "webapp" }, null);
    try t.expect(nc.clear and nc.text == null);
    try t.expectEqualStrings("webapp", nc.name.?);
    try t.expect((try Cli.parse(&.{"note"}, null)).text == null);
    try t.expectError(error.NoteTooLong, Cli.parse(&.{ "note", "x" ** (peermail.NOTE_MAX + 1) }, null));
    try t.expectError(error.NoteNotText, Cli.parse(&.{ "note", "two\nlines" }, null));
    try t.expectError(error.ExtraArgument, Cli.parse(&.{ "note", "--clear", "x" }, null));
}

test "send: --quiet and a comma list of addresses, one line per recipient; the cap" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const o = try Cli.parse(&.{ "send", "--quiet", "--name", "w", "alice, bob", "hi" }, null);
    try t.expect(o.quiet);
    const req = try sendReq(a, o.to.?, o.text.?, null, o.quiet);
    try t.expectEqual(@as(usize, 2), req.to_list.len);
    try t.expectEqualStrings("bob", req.to_list[1]);
    try t.expect(req.quiet);
    try t.expectEqualStrings("alice", (try sendReq(a, "alice", "hi", null, false)).to);
    try t.expectError(error.NotForVerb, Cli.parse(&.{ "read", "--quiet", "--name", "w" }, null));
    var many: std.ArrayList(u8) = .empty;
    for (0..peermail.PEER_TO_MAX + 1) |i| try many.print(a, "{s}p{d}", .{ if (i == 0) "" else ",", i });
    try t.expectError(error.TooManyAddresses, Cli.parse(&.{ "send", "--name", "w", many.items, "hi" }, null));
    const r: peermail.SendReply = .{ .id = "m-1", .results = &.{ .{ .to = "alice", .outcome = .queued_slow, .reason = .dormant }, .{ .to = "bob", .outcome = .refused, .reason = .unknown_address } } };
    const text = try sentText(a, "w", "alice,bob", r, false);
    try t.expect(std.mem.startsWith(u8, text, "m-1 to alice: queued_slow (dormant: "));
    try t.expect(std.mem.indexOf(u8, text, "\nm-1 to bob: refused (unknown_address: ") != null);
    try t.expect(anyRefused(r));
    // A recipient that polls: delivered, and the sender reads that it may wait.
    const polled = try sentText(a, "w", "zenit", .{ .id = "m-2", .outcome = .delivered, .to_state = .idle, .to_polls = true }, false);
    try t.expectEqualStrings("m-2 to zenit: delivered, it is idle; it polls (nothing is pushed into its session), so this may wait for its next turn\n", polled);
    try t.expect(std.mem.indexOf(u8, try sentText(a, "w", "zenit", .{ .id = "m-2", .outcome = .delivered, .to_polls = true }, true), "\"to_polls\":true") != null);
}

test "subject and note print a confirmation, or the current value alone" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try t.expectEqualStrings("subject of Arcana: template links\n", try setText(a, "subject", "Arcana", "template links", ""));
    try t.expectEqualStrings("subject of Arcana cleared\n", try setText(a, "subject", "Arcana", "", "old"));
    try t.expectEqualStrings("template links\n", try setText(a, "subject", "Arcana", null, "template links"));
    try t.expectEqualStrings("", try setText(a, "subject", "Arcana", null, ""));
    try t.expectEqualStrings("note of zenit: landing M015\n", try setText(a, "note", "zenit", "landing M015", ""));
    try t.expectEqualStrings("note of zenit cleared\n", try setText(a, "note", "zenit", "", "x"));
}

test "the help names the note's bounds as peermail keeps them" {
    try t.expect(std.mem.indexOf(u8, HELP, std.fmt.comptimePrint("at most {d} bytes", .{peermail.NOTE_MAX})) != null);
    try t.expect(std.mem.indexOf(u8, HELP, std.fmt.comptimePrint("stops showing it {d} hours", .{@divExact(peermail.NOTE_STALE_MS, 3_600_000)})) != null);
}

test "the list: a peer's own note ends its row, with its age from an hour on; the reader's own on its you line" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const now: i64 = 10_000_000_000;
    const peers = [_]peermail.PeerInfo{
        .{ .address = "p-3fa9c2e1", .alias = "zenit", .state = .working, .live = true, .last_seen_ms = now, .subject = "Folio", .note = "landing M015; holding the zenit-cms push", .note_ms = now - 5 * 60_000 },
        .{ .address = "p-9c04e2d7", .alias = "qq", .state = .idle, .live = true, .last_seen_ms = now, .note = "waiting on zenit's review", .note_ms = now - 2 * 3_600_000 },
        .{ .address = "p-00000009", .alias = "me", .state = .idle, .live = true, .last_seen_ms = now, .note = "reviewing qq", .note_ms = now },
    };
    var aw: std.Io.Writer.Allocating = .init(a);
    try writeList(&aw.writer, &peers, &.{}, .{ .address = "p-00000009", .alias = "me", .durable = true, .name_taken = false }, now, false);
    try t.expectEqualStrings(
        \\you: me (p-00000009, durable)  note: reviewing qq
        \\zenit  working  subject Folio  p-3fa9c2e1  note: landing M015; holding the zenit-cms push
        \\qq     idle  p-9c04e2d7  note 2h ago: waiting on zenit's review
        \\
    , aw.written());
    const l = listLine(peers[0], false, false);
    try t.expectEqualStrings("landing M015; holding the zenit-cms push", l.note.?);
    try t.expectEqual(now - 5 * 60_000, l.note_ms.?);
    try t.expect(listLine(.{ .address = "carol" }, false, false).note == null);
    // A received message's JSON line carries the sender's note.
    const line = try itemText(a, .{ .message = .{ .id = "m-1", .from = .{ .address = "zenit" }, .text = "x", .sender_note = "landing M015" } }, true);
    try t.expect(std.mem.indexOf(u8, line, "\"sender_note\":\"landing M015\"") != null);
}

test "a received message prints as one JSON line with the documented fields" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const line = try itemText(a, .{ .message = .{ .id = "m-00000001", .from = .{ .address = "alice", .app = "claude-code" }, .to = "webapp", .sent_ms = 1000, .text = "hi\nthere", .age_ms = 20, .sender_live = true, .sender_state = .working, .queued = true } }, true);
    try t.expect(std.mem.endsWith(u8, line, "\n") and std.mem.count(u8, line, "\n") == 1);
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, line, .{});
    for ([_][]const u8{ "id", "from", "sent_ms", "age_ms", "queued", "sender_live", "sender_state", "text" }) |k| try t.expect(v.object.get(k) != null);
    try t.expectEqualStrings("hi\nthere", v.object.get("text").?.string);
    try t.expectEqualStrings("working", v.object.get("sender_state").?.string);
    try t.expect(v.object.get("queued").?.bool);
    try t.expect(v.object.get("reply_to") == null);
    // Without --json: the composed text the MCP routes carry.
    const text = try itemText(a, .{ .message = .{ .id = "m-2", .from = .{ .address = "alice" }, .text = "x", .sender_live = true } }, false);
    try t.expect(std.mem.startsWith(u8, text, "Peer message from alice ("));
}

test "the list: a live peer's subagents and background work follow its state; a gone one shows none" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const now: i64 = 10_000_000_000;
    const peers = [_]peermail.PeerInfo{
        .{ .address = "p-3fa9c2e1", .alias = "zenit", .state = .idle, .live = true, .last_seen_ms = now, .work = .{ .subagents = 2, .shells = 1 } },
        .{ .address = "p-9c04e2d7", .alias = "qq", .state = .gone, .pending = 1, .last_seen_ms = now, .work = .{ .subagents = 1 } },
    };
    var aw: std.Io.Writer.Allocating = .init(a);
    try writeList(&aw.writer, &peers, &.{}, null, now, false);
    try t.expectEqualStrings("zenit  idle  2 subagents, 1 shell  p-3fa9c2e1\nqq     gone 0s  1 pending  p-9c04e2d7\n", aw.written());
    try t.expectEqual(@as(u32, 2), listLine(peers[0], false, false).work.?.subagents);
    try t.expect(listLine(peers[1], false, false).work == null);
}

test "the list: you once, one state word, rounded facts, gone peers counted, links last" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const f = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"context_used_percent\":19,\"context_used_tokens\":194029,\"rate_7d_used_percent\":71,\"cost_usd\":4.757664899999999}", .{});
    const now: i64 = 10_000_000_000;
    const min: i64 = 60_000;
    const peers = [_]peermail.PeerInfo{
        .{ .address = "Zenit1", .app = "claude-code", .host = "h", .state = .waiting_user, .live = true, .pending = 1, .facts = f, .model = "Opus 5.5", .last_seen_ms = now },
        .{ .address = "p-da26a6b5", .app = "claude-code", .host = "h", .state = .idle, .live = true, .facts = f, .model = "Opus 5.5", .last_seen_ms = now },
        .{ .address = "Artefacts", .host = "h", .state = .gone, .pending = 1, .subject = "Folio", .last_seen_ms = now - 18 * min },
        .{ .address = "Nib", .host = "h", .state = .gone, .last_seen_ms = now - 3 * min },
        .{ .address = "dalaran/p-b1e7d4aa", .app = "claude-code", .host = "dalaran", .state = .working, .live = true, .model = "Opus 5.5", .last_seen_ms = now - 16 * min, .via_host = "dalaran", .link = .down, .link_why = .@"unreachable" },
    };
    const hosts = [_]peermail.HostInfo{ .{ .host = "dalaran", .link = .down, .last_seen_ms = now - 15 * min, .why = .@"unreachable", .detail = "ssh: connect to host dalaran port 22: Connection refused", .retry_in_ms = 40_000 }, .{ .host = "aeor", .link = .up, .last_seen_ms = now } };
    var aw: std.Io.Writer.Allocating = .init(a);
    try writeList(&aw.writer, &peers, &hosts, .{ .address = "p-da26a6b5", .durable = true, .name_taken = false }, now, false);
    try t.expectEqualStrings(
        \\you: p-da26a6b5 (durable)
        \\Zenit1              waiting_user  ctx 194k  1 pending
        \\Artefacts           gone 18m  subject Folio  1 pending
        \\dalaran/p-b1e7d4aa  working  seen 16m ago  link down (unreachable)
        \\links: dalaran down (unreachable: ssh: connect to host dalaran port 22: Connection refused; retry in 40s; seen 15m ago), aeor up
        \\+1 gone with nothing pending and no subject
        \\
    , aw.written());
    // A model or an app shows only where the peers differ; the working
    // directory always shows, after the facts; detail adds the pid.
    var other = peers;
    other[4].model = "Haiku 4.5";
    other[4].cwd = "/w/zenit-workspace";
    other[4].pid = 42;
    aw.clearRetainingCapacity();
    try writeList(&aw.writer, other[1..], &.{}, null, now, false);
    try t.expectEqualStrings("p-da26a6b5          idle  ctx 194k  Opus 5.5\nArtefacts           gone 18m  subject Folio  1 pending\ndalaran/p-b1e7d4aa  working  Haiku 4.5  /w/zenit-workspace  seen 16m ago  link down (unreachable)\n+1 gone with nothing pending and no subject\n", aw.written());
    try t.expectEqualStrings("/w/zenit-workspace", listLine(other[4], false, false).cwd.?);
    aw.clearRetainingCapacity();
    try writeList(&aw.writer, other[4..], &.{}, null, now, true);
    try t.expectEqualStrings("dalaran/p-b1e7d4aa  working  /w/zenit-workspace  seen 16m ago  link down (unreachable)  pid 42\n", aw.written());
    // Every reason reads the same on a host line (`sketerm peer status`):
    // an old daemon names its version; a redial keeps the last failure.
    aw.clearRetainingCapacity();
    try writeHostText(&aw.writer, .{ .host = "dalaran", .link = .unsupported, .why = .unsupported, .detail = "it runs 0.2.2, which predates peer federation (no peer_federation)", .retry_in_ms = 60_000 });
    try t.expectEqualStrings("host dalaran: link unsupported (its daemon is too old: it runs 0.2.2, which predates peer federation (no peer_federation); retry in 60s)", aw.written());
    aw.clearRetainingCapacity();
    try writeWhy(&aw.writer, .{ .host = "aeor", .link = .down, .why = .auth_failed, .detail = "me@aeor: Permission denied (publickey).", .redialing = true });
    try t.expectEqualStrings("auth failed: me@aeor: Permission denied (publickey).; redialing now", aw.written());
    try t.expectEqualStrings("unreachable", listLine(peers[4], false, false).link_why.?);
    aw.clearRetainingCapacity();
    try writeList(&aw.writer, &.{}, &.{}, null, now, false);
    try t.expectEqualStrings("no other peers\n", aw.written());
    // Aliases lead, the address follows last; the reader's own too.
    aw.clearRetainingCapacity();
    const aliased = [_]peermail.PeerInfo{
        .{ .address = "p-3fa9c2e1", .alias = "zenit", .state = .idle, .live = true, .last_seen_ms = now },
        .{ .address = "p-da26a6b5", .alias = "qq", .state = .gone, .pending = 12, .subject = "Folio", .last_seen_ms = now - 18 * min },
        .{ .address = "dalaran/p-b1e7d4aa", .alias = "zenit-1", .state = .working, .live = true, .last_seen_ms = now, .via_host = "dalaran", .link = .up },
        .{ .address = "p-00000009", .alias = "me", .state = .idle, .live = true, .last_seen_ms = now },
    };
    try writeList(&aw.writer, &aliased, &.{}, .{ .address = "p-00000009", .alias = "me", .durable = true, .name_taken = false }, now, false);
    try t.expectEqualStrings(
        \\you: me (p-00000009, durable)
        \\zenit    idle  p-3fa9c2e1
        \\qq       gone 18m  subject Folio  12 pending  p-da26a6b5
        \\zenit-1  working  dalaran/p-b1e7d4aa
        \\
    , aw.written());
    try t.expectEqualStrings("zenit", listLine(aliased[0], false, false).alias.?);
    // A live peer with no presence says why once.
    aw.clearRetainingCapacity();
    try writeList(&aw.writer, &.{.{ .address = "aeor/s85382-4", .state = .unknown, .live = true, .last_seen_ms = now }}, &.{}, null, now, false);
    try t.expect(std.mem.startsWith(u8, aw.written(), "aeor/s85382-4  unknown\nunknown = its client sends no presence"));
    // The JSON lines keep every fact.
    const l = listLine(.{ .address = "bob", .state = .unknown, .live = false, .last_notification = "idle_prompt" }, false, true);
    try t.expect(l.attention == null);
    try t.expectEqualStrings("idle_prompt", l.last_notification.?);
    try t.expect(listLine(.{ .address = "bob", .last_notification = "x" }, false, false).last_notification == null);
    try t.expectEqualStrings("template links", listLine(.{ .address = "carol", .subject = "template links" }, false, false).subject.?);
    try t.expect(listLine(.{ .address = "carol" }, false, false).subject == null);
    // A peer that polls is marked, and the mark explained once.
    aw.clearRetainingCapacity();
    try writeList(&aw.writer, &.{ .{ .address = "zenit", .state = .idle, .live = true, .polls = true, .last_seen_ms = now }, .{ .address = "qq", .state = .idle, .live = true, .polls = true, .last_seen_ms = now } }, &.{}, null, now, false);
    try t.expectEqualStrings("zenit  idle  polls\nqq     idle  polls\n" ++ POLLS_LINE ++ "\n", aw.written());
    try t.expect(listLine(.{ .address = "zenit", .live = true, .polls = true }, false, false).polls.?);
    try t.expect(listLine(.{ .address = "zenit", .live = false, .polls = true }, false, false).polls == null);
}
