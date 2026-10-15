//! `sketerm peer list|send|read`: any program is a peer by running this,
//! a client of the same `peer_*` frames the MCP server speaks
//! (`peerclient.Peer`, no wire of its own). `read --follow` registers a
//! durable address and prints each incoming message as it arrives (one
//! JSON line with `--json`), acknowledging it only once the line is
//! written; lines it reads on its stdin are sent from that address. It
//! is also the one home of how a peer list entry reads, for this CLI and
//! the `peer_list` tool alike (`listLine`, `writeListText`).

const std = @import("std");
const c = @import("../c.zig").c;
const fdio = @import("../util/fdio.zig");
const platform = @import("../util/platform.zig");
const clock = @import("../util/clock.zig");
const Backoff = @import("../util/backoff.zig").Backoff;
const env = @import("../util/env.zig");
const vocab = @import("../agent/vocab.zig");
const facts = @import("../agent/facts.zig");
const peeraddr = @import("peeraddr.zig");
const agentpush = @import("agentpush.zig");
const muxclient = @import("../mux/client.zig");
const peerclient = @import("../mux/peerclient.zig");
const peermail = peerclient.peermail;

/// The argv word that selects this command (`sketerm peer`, `sketerm mcp peer`).
pub const SUBCOMMAND = "peer";
/// The registered app of a CLI peer that declares none.
pub const APP_DEFAULT = "cli";
/// The name when no `--name` is given (the precedence's explicit rule).
pub const ENV_NAME = "SKETERM_PEER_NAME";
const REPLY_MS: i64 = 10_000;
/// A one-shot read takes what arrives until this long passes with nothing.
const READ_QUIET_MS: i64 = 300;
const RECONNECT = Backoff{ .min_ms = 1_000, .max_ms = 60_000 };
/// Longest line a follower reads on its stdin (a message plus its JSON).
const STDIN_LINE_MAX: usize = peermail.PEER_TEXT_MAX * 6 + 1024;

// ── one peer list entry, for every surface ──────────────────────

/// One peer as `peer_list` and `sketerm peer list --json` report it.
pub const ListLine = struct {
    address: []const u8,
    host: ?[]const u8 = null,
    app: ?[]const u8 = null,
    state: []const u8,
    /// Absent while the state is unknown.
    attention: ?[]const u8 = null,
    live: bool,
    pending: u32,
    last_seen_ms: i64,
    model: ?[]const u8 = null,
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
};

/// One federated host as `peer_list` and `sketerm peer list --json` report it.
pub const HostLine = struct {
    host: []const u8,
    link: []const u8,
    last_seen_ms: i64,
};

pub fn hostLine(h: peermail.HostInfo) HostLine {
    return .{ .host = h.host, .link = @tagName(h.link), .last_seen_ms = h.last_seen_ms };
}

/// One line: the host (or "the hub" before it said hello), its link
/// state, and when it was last heard from while not up.
pub fn writeHostText(w: *std.Io.Writer, h: peermail.HostInfo) !void {
    try w.print("host {s}: link {s}", .{ if (h.host.len > 0) h.host else "(the hub, not heard from yet)", @tagName(h.link) });
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
        .host = nonEmpty(pi.host),
        .app = nonEmpty(pi.app),
        .state = @tagName(pi.state),
        .attention = if (pi.state.attention()) |at| @tagName(at) else null,
        .live = pi.live,
        .pending = pi.pending,
        .last_seen_ms = pi.last_seen_ms,
        .model = nonEmpty(pi.model),
        .facts = pi.facts,
        .self = if (is_self) true else null,
        .via_host = nonEmpty(pi.via_host),
        .link = if (pi.link) |k| @tagName(k) else null,
    };
    if (detail) {
        l.cwd = pi.cwd;
        l.pid = pi.pid;
        l.durable = pi.durable;
        l.name_taken = pi.name_taken;
        l.last_notification = nonEmpty(pi.last_notification);
    }
    return l;
}

/// One line: address, app and host, state (and its attention when that
/// reads differently), the facts' compact labels, model, pending, and
/// when an offline peer was last seen.
pub fn writeListText(w: *std.Io.Writer, arena: std.mem.Allocator, pi: peermail.PeerInfo, is_self: bool) !void {
    try w.print("{s}{s} {s} on {s}, {s}", .{
        pi.address,
        if (is_self) " (you)" else "",
        if (pi.app.len > 0) pi.app else "unknown app",
        if (pi.host.len > 0) pi.host else "this host",
        @tagName(pi.state),
    });
    if (pi.state.attention()) |at| {
        if (!std.mem.eql(u8, at.label(), @tagName(pi.state))) try w.print(" ({s})", .{at.label()});
    }
    if (pi.facts) |f| if (facts.shipped()) |v| {
        if (try facts.compactLine(arena, v, try facts.fromJson(arena, v, f))) |line| try w.print(", {s}", .{line});
    } else |_| {};
    if (pi.model.len > 0) try w.print(", {s}", .{pi.model});
    try w.print(", pending {d}", .{pi.pending});
    if (!pi.live) {
        try w.writeAll(", offline");
        var buf: [clock.ISO_LEN]u8 = undefined;
        if (pi.last_seen_ms > 0) if (clock.isoLocal(&buf, pi.last_seen_ms)) |iso| try w.print(", last seen {s}", .{iso});
    }
    if (pi.via_host.len > 0) try w.print(", via {s}", .{pi.via_host});
    if (pi.link) |k| switch (k) {
        .up => {},
        .down, .unsupported => try w.print(", link {s} (last known state)", .{@tagName(k)}),
    };
}

// ── what a received item prints as ──────────────────────────────

const MessageLine = struct {
    kind: []const u8 = "message",
    id: []const u8,
    from: []const u8,
    sent_ms: i64,
    age_ms: i64,
    queued: bool,
    sender_live: bool,
    sender_state: []const u8,
    text: []const u8,
    reply_to: ?[]const u8 = null,
};

const EventLine = struct {
    kind: []const u8 = "event",
    id: []const u8,
    outcome: []const u8,
    reason: ?[]const u8 = null,
    to: []const u8,
    queued_ms: i64,
};

const ExpiredLine = struct {
    kind: []const u8 = "expired_away",
    id: []const u8,
    from: []const u8,
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
            .sent_ms = m.sent_ms,
            .age_ms = m.age_ms,
            .queued = m.queued,
            .sender_live = m.sender_live,
            .sender_state = @tagName(m.sender_state orelse if (m.sender_live) vocab.PeerState.unknown else .gone),
            .text = m.text,
            .reply_to = m.reply_to,
        }),
        .event => |e| jsonLine(arena, EventLine{ .id = e.id, .outcome = @tagName(e.outcome), .reason = if (e.reason) |r| @tagName(r) else null, .to = e.to, .queued_ms = e.queued_ms }),
        .expired_away => |x| jsonLine(arena, ExpiredLine{ .id = x.id, .from = x.from, .sent_ms = x.sent_ms, .expired_ms = x.expired_ms }),
    };
}

fn sentText(arena: std.mem.Allocator, from: []const u8, to: []const u8, r: peermail.SendReply, json: bool) ![]const u8 {
    if (json) return jsonLine(arena, SentLine{
        .id = r.id,
        .from = from,
        .to = to,
        .outcome = @tagName(r.outcome),
        .reason = if (r.reason) |why| @tagName(why) else null,
        .to_state = if (r.to_state) |st| @tagName(st) else null,
    });
    if (r.reason) |why| return std.fmt.allocPrint(arena, "{s} to {s}: {s} ({s}: {s})\n", .{ if (r.id.len > 0) r.id else "message", to, @tagName(r.outcome), @tagName(why), why.describe() });
    return std.fmt.allocPrint(arena, "{s} to {s}: {s}\n", .{ r.id, to, @tagName(r.outcome) });
}

// ── arguments ────────────────────────────────────────────────────

pub const Verb = enum { list, send, read };

pub const Cli = struct {
    verb: ?Verb = null,
    name: ?[]const u8 = null,
    app: []const u8 = APP_DEFAULT,
    json: bool = false,
    follow: bool = false,
    detail: bool = false,
    reply_to: ?[]const u8 = null,
    /// `send`: the address, then the text (null: read from stdin).
    to: ?[]const u8 = null,
    text: ?[]const u8 = null,
    help: bool = false,

    pub const ParseError = error{ UnknownFlag, MissingValue, ExtraArgument, UnknownVerb, NoName, NoAddress, BadName, NotForVerb };

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
        if (o.name == null) o.name = env_name;
        switch (verb) {
            .list => if (o.to != null) return error.ExtraArgument,
            .read => if (o.to != null) return error.ExtraArgument,
            .send => if (o.to == null) return error.NoAddress,
        }
        if (o.follow and verb != .read) return error.NotForVerb;
        if (o.reply_to != null and verb != .send) return error.NotForVerb;
        if (verb != .list) {
            const n = o.name orelse return error.NoName;
            const addr = peeraddr.Address.parse(n) catch return error.BadName;
            if (addr.host != null) return error.BadName;
        }
        return o;
    }
};

pub const HELP =
    \\Usage: sketerm peer list [--json] [--detail]
    \\       sketerm peer send --name NAME [--json] [--reply-to ID] TO [TEXT]
    \\       sketerm peer read --name NAME [--json] [--follow]
    \\       (--app APP on send and read: the app the peer registers as, default cli)
    \\
    \\Takes part in peer messaging (the peer_* tools of `sketerm mcp`) from any
    \\program. NAME (or SKETERM_PEER_NAME) is the durable address this program
    \\is reached at; mail for it waits in the per-user daemon while no reader
    \\runs. send sends TEXT (or stdin when absent) and prints what became of it;
    \\read prints the messages waiting for NAME and exits; read --follow keeps
    \\NAME registered and prints each message as it arrives (acknowledged once
    \\printed), reconnecting when the daemon goes away, until SIGINT/SIGTERM or
    \\the end of its stdin (when stdin is a pipe, socket or terminal). While it
    \\follows, each line on its stdin {"to":ADDR,"text":TEXT,"reply_to":ID?}
    \\is sent from NAME, answered with a "sent" line. --json prints one JSON
    \\object per line: messages {"kind":"message","id","from","sent_ms",
    \\"age_ms","queued","sender_live","sender_state","text","reply_to"?}, and
    \\"event" / "expired_away" for what became of mail.
    \\
    \\Exit status: 0 done, 1 the daemon could not be reached, the name is held
    \\by another live peer, or a send was refused; 2 bad usage.
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

/// `sketerm peer ...`.
/// @return the process exit status.
pub fn cli(allocator: std.mem.Allocator, args: []const []const u8) u8 {
    const o = Cli.parse(args, env.nonEmpty(ENV_NAME)) catch |err| {
        say(2, switch (err) {
            error.UnknownFlag => "peer: unknown flag (see --help)\n",
            error.MissingValue => "peer: flag needs a value\n",
            error.ExtraArgument => "peer: too many arguments (see --help)\n",
            error.UnknownVerb => "peer: say list, send or read (see --help)\n",
            error.NoName => "peer: --name NAME (or SKETERM_PEER_NAME) is required: the address this program is reached at\n",
            error.NoAddress => "peer: send needs the address to send to\n",
            error.BadName => "peer: the name must be 1-64 of A-Za-z0-9._- (no host)\n",
            error.NotForVerb => "peer: --follow is for read, --reply-to for send\n",
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
                for (reply.value.peers) |pi| {
                    writeListText(&aw.writer, arena, pi, false) catch return 1;
                    aw.writer.writeAll("\n") catch return 1;
                }
                for (reply.value.hosts) |h| {
                    writeHostText(&aw.writer, h) catch return 1;
                    aw.writer.writeAll("\n") catch return 1;
                }
            }
            say(1, aw.written());
            return 0;
        },
        .send => {
            const text = o.text orelse readAllStdin(arena) orelse return fail("could not read the text from stdin", .{});
            link.register(arena, o) catch |e| return fail("{s}", .{linkError(e)});
            const reply = link.peer.send(arena, o.to.?, text, o.reply_to, REPLY_MS) catch return fail("the daemon did not answer the send", .{});
            say(1, sentText(arena, o.name.?, o.to.?, reply.value, o.json) catch return 1);
            return if (reply.value.outcome == .refused) 1 else 0;
        },
        .read => {
            link.register(arena, o) catch |e| return fail("{s}", .{linkError(e)});
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
    }
}

const LinkError = error{ Unreachable, NoPeers, NameTaken, NoAnswer };

fn linkError(e: LinkError) []const u8 {
    return switch (e) {
        error.Unreachable => "the per-user sketerm daemon cannot be reached",
        error.NoPeers => "the per-user sketerm daemon predates peer messaging (restart it idle)",
        error.NameTaken => "that name is held by another live peer (a running `peer read --follow` sends what its stdin says)",
        error.NoAnswer => "the daemon did not answer the registration",
    };
}

/// One connection to the per-user daemon.
const Link = struct {
    allocator: std.mem.Allocator,
    conn: *muxclient.Conn,
    peer: peerclient.Peer,

    fn open(allocator: std.mem.Allocator) LinkError!Link {
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

    fn close(self: *Link) void {
        self.peer.deinit();
        self.conn.deinit();
        self.allocator.destroy(self.conn);
    }

    /// Register `o.name` durable and wait for the broker's answer.
    fn register(self: *Link, arena: std.mem.Allocator, o: Cli) LinkError!void {
        var cwd_buf: [4096]u8 = undefined;
        const cwd: []const u8 = if (c.getcwd(&cwd_buf, cwd_buf.len)) |p| std.mem.span(@as([*:0]u8, @ptrCast(p))) else "";
        self.peer.register(.{ .address = o.name.?, .durable = true, .app = o.app, .cwd = cwd, .pid = @intCast(c.getpid()) }) catch return error.Unreachable;
        const deadline = clock.nowMs() + REPLY_MS;
        while (clock.nowMs() < deadline) {
            const push = (self.peer.nextPush(arena, deadline - clock.nowMs()) catch return error.Unreachable) orelse break;
            switch (push) {
                .registered => |r| {
                    const s = r.value.self orelse continue;
                    if (s.name_taken) return error.NameTaken;
                    return;
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
const SendLine = struct { to: []const u8 = "", text: []const u8 = "", reply_to: ?[]const u8 = null };

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
        link.register(arena, o) catch |e| {
            if (e == error.NameTaken) return fail("{s}", .{linkError(e)});
            if (!pause(backoff.fail(clock.nowMs()), watch_stdin)) break;
            continue;
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
        const reply = link.peer.send(arena, line.to, line.text, line.reply_to, REPLY_MS) catch return false;
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

test "arguments: a name for send and read (flag or SKETERM_PEER_NAME), none for list" {
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

test "a list entry: compact facts by their labels, attention only where it reads differently" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const f = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"context_used_percent\":14,\"rate_7d_used_percent\":98}", .{});
    var aw: std.Io.Writer.Allocating = .init(a);
    try writeListText(&aw.writer, a, .{ .address = "alice", .app = "claude-code", .host = "h", .state = .waiting_user, .live = true, .pending = 2, .facts = f, .model = "Opus 4.7" }, true);
    try t.expectEqualStrings("alice (you) claude-code on h, waiting_user (needs input), context 14%, 7d limit 98%, Opus 4.7, pending 2", aw.written());
    aw.clearRetainingCapacity();
    try writeListText(&aw.writer, a, .{ .address = "bob", .state = .working, .live = true }, false);
    try t.expectEqualStrings("bob unknown app on this host, working, pending 0", aw.written());
    const l = listLine(.{ .address = "bob", .state = .unknown, .live = false, .last_notification = "idle_prompt" }, false, true);
    try t.expect(l.attention == null);
    try t.expectEqualStrings("idle_prompt", l.last_notification.?);
    try t.expect(listLine(.{ .address = "bob", .last_notification = "x" }, false, false).last_notification == null);
}
