//! Waking the assistant: push delivery into its session (a Claude Code
//! channel, `agent-wait --server` followers) and the waiter socket
//! (`agentwait.zig` is its protocol and CLI). Both are consumers of the
//! agent's one queue (`events.Cursor.take`), never a second state.

const std = @import("std");
const c = @import("../c.zig").c;
const mcp = @import("mcp.zig");
const agentwait = @import("agentwait.zig");
const agentpush = @import("agentpush.zig");
const agent_mod = @import("../agent/agent.zig");
const events = @import("../agent/events.zig");
const clock = @import("../util/clock.zig");
const platform = @import("../util/platform.zig");
const pathz = @import("../util/pathz.zig");

const mcp_agent = @import("mcp_agent.zig");
const mcp_agent_results = @import("mcp_agent_results.zig");
const mcp_agent_loop = @import("mcp_agent_loop.zig");

const WAITER_SOCKET = mcp_agent.WAITER_SOCKET;
const INSTRUCTIONS = mcp_agent.INSTRUCTIONS;
const Entry = mcp_agent.Entry;
const MAX_ANY = mcp_agent.MAX_ANY;
const isHeld = mcp_agent.isHeld;
const state = &mcp_agent.state;
const findByName = mcp_agent.findByName;
const findById = mcp_agent.findById;
const conversationOf = mcp_agent_results.conversationOf;
const pollFds = mcp_agent_loop.pollFds;
const service = mcp_agent_loop.service;
const settleOf = mcp_agent_loop.settleOf;
const settledOf = mcp_agent_loop.settledOf;

const MAX_SUBS = 32;

// ── push delivery ────────────────────────────────────────────────

/// Set this MCP session's push route (at `initialize`): `sink` gets each
/// channel notification line once `startPush` ran.
pub fn armPush(route: agentpush.Route, sink: ?*const fn ([]const u8) void) void {
    state.push = route;
    state.push_sink = sink;
    state.push_live = false;
}

/// The session is up (its first tool call): Claude Code registers its
/// channel listener after the handshake, and a push before that is lost.
pub fn startPush() void {
    if (state.push != .none) state.push_live = true;
}

/// Server instructions for an MCP session on push `route`.
pub fn instructions(route: agentpush.Route) []const u8 {
    return switch (route) {
        .channel => INSTRUCTIONS ++ " " ++ PUSH_CHANNEL_NOTE,
        .none => INSTRUCTIONS ++ " " ++ PUSH_NOTE,
    };
}

const PUSH_NOTE = "If agent events are pushed into this session (Claude Code: a <channel source=\"sketerm\"> message; opencode: a <sketerm-agent-event> message from the sketerm agents plugin), rely on them and end your turn instead of running watch_command; otherwise use the waiter.";
const PUSH_CHANNEL_NOTE = "This session receives every agent's events as <channel source=\"sketerm\"> messages that start a new turn (a done carries the job's answer when it is short), so after delegating END YOUR TURN: do not run watch_command, a Monitor or agent_wait to wait for them.";

/// `agent-wait --server` followers connected now (the opencode plugin
/// runs one).
pub fn followers() usize {
    var n: usize = 0;
    for (state.waiter.subs.items) |s| {
        if (s.server and s.subscribed and !s.done) n += 1;
    }
    return n;
}

/// Events reach the session without a waiter: a live channel, or a
/// follower watching every agent.
pub fn pushing() bool {
    return (state.push == .channel and state.push_live) or followers() > 0;
}

/// Keep the filter of the result's watch_command for the pushes.
pub fn rememberFilter(e: *Entry, f: events.Filter) void {
    const owned: ?[]u8 = if (f.match) |m| (e.allocator.dupe(u8, m) catch return) else null;
    if (e.push_match) |old| e.allocator.free(old);
    e.push_match = owned;
    e.push_filter = .{ .messages = f.messages, .retrying = f.retrying, .background = f.background, .match = owned };
}

/// The push for `d`, its answer marked handed out (agent_read and done
/// results do not repeat what the push carried in full).
fn pushOf(arena: std.mem.Allocator, e: *Entry, d: events.Delivery) !agentpush.Push {
    const recs = e.agent.records();
    const p = try agentpush.compose(arena, .{ .agent = e.id, .name = e.name, .conversation = conversationOf(e), .state = e.agent.state() }, d, e.agent.queue(), recs, &e.handed);
    if (p.answer) |i| try e.handed.markRecord(e.allocator, recs[i]);
    return p;
}

/// Send every agent's pending wake-up as one channel notification each.
pub fn servicePush(now_ms: i64) void {
    if (state.push != .channel or !state.push_live) return;
    const sink = state.push_sink orelse return;
    var arena_state = std.heap.ArenaAllocator.init(state.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (state.entries.items) |e| {
        // A tool call on this agent is under way: its result gets this.
        if (isHeld(e)) continue;
        const d = (e.push_cursor.take(e.agent.queue(), e.push_filter, now_ms, arena) catch continue) orelse continue;
        const p = pushOf(arena, e, d) catch continue;
        sink(agentpush.encodeChannel(arena, p) catch continue);
    }
}

// ── the waiter socket ────────────────────────────────────────────

/// One agent a waiter watches, with its own examined mark.
const Target = struct {
    id: []u8,
    cursor: events.Cursor,
    /// An `all` waiter's agent that closed: settled, as `closed`.
    closed: bool = false,
};

const Sub = struct {
    fd: c_int,
    inbuf: std.ArrayList(u8) = .empty,
    subscribed: bool = false,
    targets: std.ArrayList(Target) = .empty,
    match: ?[]u8 = null,
    messages: bool = false,
    retrying: bool = false,
    background: bool = false,
    follow: bool = false,
    /// Every agent of the server, later ones included, with pushed text.
    server: bool = false,
    /// One wake once every target settled (`--all`).
    all: bool = false,
    /// Its CLI prints the pushed text (`agentwait.Subscribe.content`).
    content: bool = false,
    done: bool = false,

    /// What wakes it for `e`: its own filter, and for a server follower
    /// also what the assistant's last call on `e` asked for.
    fn filterFor(self: *const Sub, e: *const Entry) events.Filter {
        const own: events.Filter = .{ .messages = self.messages, .match = self.match, .retrying = self.retrying, .background = self.background };
        if (!self.server) return own;
        return .{
            .messages = own.messages or e.push_filter.messages,
            .retrying = own.retrying or e.push_filter.retrying,
            .background = own.background or e.push_filter.background,
            .match = own.match orelse e.push_filter.match,
        };
    }

    /// Add every agent it does not watch yet (a server follower).
    fn adoptAll(self: *Sub, a: std.mem.Allocator) void {
        for (state.entries.items) |e| {
            if (self.watches(e.id) != null) continue;
            const id = a.dupe(u8, e.id) catch return;
            self.targets.append(a, .{ .id = id, .cursor = .after(e.cursor.seen) }) catch return a.free(id);
        }
    }

    fn watches(self: *const Sub, id: []const u8) ?usize {
        for (self.targets.items, 0..) |tg, i| if (std.mem.eql(u8, tg.id, id)) return i;
        return null;
    }

    /// Stop watching target `i`.
    fn drop(self: *Sub, a: std.mem.Allocator, i: usize) void {
        a.free(self.targets.items[i].id);
        _ = self.targets.orderedRemove(i);
    }
};

pub const Waiter = struct {
    fd: c_int = -1,
    path: ?[]u8 = null,
    subs: std.ArrayList(*Sub) = .empty,

    pub fn listen(self: *Waiter, a: std.mem.Allocator, dir: []const u8) void {
        const path = std.fmt.allocPrint(a, "{s}/" ++ WAITER_SOCKET, .{dir}) catch return;
        var addr: c.struct_sockaddr_un = undefined;
        @import("../mux/sockpath.zig").fillSockaddrUn(&addr, path) catch return a.free(path);
        var zbuf: [4096]u8 = undefined;
        const pz = std.fmt.bufPrintZ(&zbuf, "{s}", .{path}) catch return a.free(path);
        const fd = platform.socketCloexec(c.AF_UNIX, c.SOCK_STREAM, 0);
        if (fd < 0) return a.free(path);
        _ = c.unlink(pz.ptr);
        if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0 or c.listen(fd, 16) != 0) {
            _ = c.close(fd);
            return a.free(path);
        }
        _ = c.chmod(pz.ptr, 0o600);
        setNonBlocking(fd);
        self.fd = fd;
        self.path = path;
    }

    pub fn close(self: *Waiter, a: std.mem.Allocator, reason: []const u8) void {
        for (self.subs.items) |s| {
            if (s.subscribed and !s.done) endSub(s, reason);
            freeSub(a, s);
        }
        self.subs.deinit(a);
        self.subs = .empty;
        if (self.fd >= 0) _ = c.close(self.fd);
        self.fd = -1;
        if (self.path) |p| {
            pathz.unlinkPath(p);
            a.free(p);
        }
        self.path = null;
    }

    pub fn pollFds(self: *const Waiter, out: []c.struct_pollfd) usize {
        var n: usize = 0;
        if (self.fd >= 0 and n < out.len) {
            out[n] = .{ .fd = self.fd, .events = c.POLLIN, .revents = 0 };
            n += 1;
        }
        for (self.subs.items) |s| {
            if (n >= out.len) break;
            out[n] = .{ .fd = s.fd, .events = c.POLLIN, .revents = 0 };
            n += 1;
        }
        return n;
    }

    pub fn dueIn(self: *const Waiter, now_ms: i64) ?i64 {
        var due: ?i64 = null;
        for (self.subs.items) |s| {
            if (!s.subscribed) continue;
            for (s.targets.items) |*tg| {
                const e = findById(tg.id) orelse continue;
                if (tg.cursor.digestDueIn(e.agent.queue(), now_ms)) |d| due = if (due) |x| @min(x, d) else d;
            }
        }
        return due;
    }

    pub fn service(self: *Waiter, now_ms: i64) void {
        const a = state.allocator;
        self.accept(a);
        var i: usize = 0;
        while (i < self.subs.items.len) {
            const s = self.subs.items[i];
            serviceSub(a, s, now_ms);
            if (s.done) {
                freeSub(a, s);
                _ = self.subs.swapRemove(i);
                continue;
            }
            i += 1;
        }
    }

    fn accept(self: *Waiter, a: std.mem.Allocator) void {
        if (self.fd < 0) return;
        while (self.subs.items.len < MAX_SUBS) {
            const cfd = c.accept(self.fd, null, null);
            if (cfd < 0) return;
            _ = c.fcntl(cfd, c.F_SETFD, c.FD_CLOEXEC);
            setNonBlocking(cfd);
            const s = a.create(Sub) catch {
                _ = c.close(cfd);
                return;
            };
            s.* = .{ .fd = cfd };
            self.subs.append(a, s) catch {
                _ = c.close(cfd);
                a.destroy(s);
                return;
            };
        }
    }
};

fn setNonBlocking(fd: c_int) void {
    const fl = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
    _ = c.fcntl(fd, c.F_SETFL, fl | c.O_NONBLOCK);
}

fn serviceSub(a: std.mem.Allocator, s: *Sub, now_ms: i64) void {
    // Read the subscription, or notice the client leaving.
    var tmp: [1024]u8 = undefined;
    while (true) {
        const n = c.read(s.fd, &tmp, tmp.len);
        if (n == 0) {
            s.done = true;
            return;
        }
        if (n < 0) break;
        if (s.subscribed) continue;
        s.inbuf.appendSlice(a, tmp[0..@intCast(n)]) catch return endSub(s, "out of memory");
        if (s.inbuf.items.len > agentwait.MAX_SUBSCRIBE) return endSub(s, "subscribe line too long");
    }
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!s.subscribed) {
        const nl = std.mem.indexOfScalar(u8, s.inbuf.items, '\n') orelse return;
        s.subscribed = true;
        const sub = std.json.parseFromSliceLeaky(agentwait.Subscribe, arena, s.inbuf.items[0..nl], .{ .ignore_unknown_fields = true }) catch
            return endSub(s, "bad subscribe line");
        const names = sub.names();
        if (names.len == 0 and !sub.server) return endSub(s, "no agent named");
        if (names.len > MAX_ANY) return endSub(s, "too many agents");
        for (names) |name| {
            const e = findByName(name) orelse
                return endSub(s, std.fmt.allocPrint(arena, "no agent {s} on this server", .{name}) catch "no such agent");
            if (s.watches(e.id) != null) continue;
            const id = a.dupe(u8, e.id) catch return endSub(s, "out of memory");
            // Without `since`: whatever nobody delivered yet, and opt-in
            // events the assistant's calls have not examined.
            const cursor = if (sub.since) |n| events.Cursor.replayFrom(n) else events.Cursor.after(e.cursor.seen);
            s.targets.append(a, .{ .id = id, .cursor = cursor }) catch {
                a.free(id);
                return endSub(s, "out of memory");
            };
        }
        if (sub.match) |m| s.match = a.dupe(u8, m) catch return endSub(s, "out of memory");
        s.messages = sub.messages;
        s.retrying = sub.retrying;
        s.background = sub.background;
        s.follow = sub.follow;
        s.server = sub.server;
        s.all = sub.all and !sub.server;
        s.content = sub.content;
    }
    if (s.all) return serviceAll(arena, s);
    if (s.server) s.adoptAll(a);
    var i: usize = 0;
    while (i < s.targets.items.len) {
        const tg = &s.targets.items[i];
        const e = findById(tg.id) orelse {
            s.drop(a, i);
            continue;
        };
        i += 1;
        // A tool call on this agent is under way: its result gets this.
        if (isHeld(e)) continue;
        const d = (tg.cursor.take(e.agent.queue(), s.filterFor(e), now_ms, arena) catch continue) orelse continue;
        // The text a push composes, and what it carries in full handed out:
        // what the waiter prints is the push's text exactly.
        const pushed: ?agentwait.Pushed = if (s.server or s.content) blk: {
            const p = pushOf(arena, e, d) catch continue;
            break :blk .{ .content = p.content, .meta = p.meta };
        } else null;
        sendLine(s, agentwait.encodeWake(arena, e.id, e.agent.state(), d, e.agent.queue(), pushed) catch continue);
        if (!s.follow) {
            s.done = true;
            return;
        }
    }
    // A server follower watches agents not opened yet.
    if (s.targets.items.len == 0 and !s.server) endSub(s, "agent closed");
}

/// An `all` waiter: once every target settled (a closed one included),
/// one line with each one's outcome, what it delivers marked delivered.
fn serviceAll(arena: std.mem.Allocator, s: *Sub) void {
    for (s.targets.items) |*tg| {
        if (tg.closed) continue;
        const e = findById(tg.id) orelse {
            tg.closed = true;
            continue;
        };
        // A tool call on it is under way: its result gets what happens.
        if (isHeld(e) or settleOf(e) == null) return;
    }
    const out = arena.alloc(agentwait.Settled, s.targets.items.len) catch return endSub(s, "out of memory");
    for (s.targets.items, out) |*tg, *o| {
        const e = (if (tg.closed) null else findById(tg.id)) orelse {
            o.* = .{ .agent = tg.id, .outcome = "closed", .state = "" };
            continue;
        };
        o.* = settledOf(e, settleOf(e).?);
        // Delivered like any wake-up: no result repeats it.
        if (tg.cursor.take(e.agent.queue(), .{}, clock.nowMs(), arena)) |_| {} else |_| {}
    }
    sendLine(s, agentwait.encodeAll(arena, out) catch return endSub(s, "out of memory"));
    s.done = true;
}

/// Send the end line and let the client go.
fn endSub(s: *Sub, reason: []const u8) void {
    var buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    sendLine(s, agentwait.encodeEnd(fba.allocator(), agentwait.clip(reason, 400)) catch "");
    s.done = true;
}

/// Write a whole line or give the client up: a waiter that does not read
/// its few short lines is gone, and the loop never blocks on it.
fn sendLine(s: *Sub, line: []const u8) void {
    var off: usize = 0;
    while (off < line.len) {
        const n = c.send(s.fd, line[off..].ptr, line.len - off, c.MSG_NOSIGNAL | c.MSG_DONTWAIT);
        if (n <= 0) {
            if (n < 0 and std.posix.errno(n) == .INTR) continue;
            s.done = true;
            return;
        }
        off += @intCast(n);
    }
}

fn freeSub(a: std.mem.Allocator, s: *Sub) void {
    _ = c.close(s.fd);
    s.inbuf.deinit(a);
    for (s.targets.items) |tg| a.free(tg.id);
    s.targets.deinit(a);
    if (s.match) |m| a.free(m);
    a.destroy(s);
}

/// Drop an agent that is going away from every waiter, and end the
/// waiters left watching nothing.
pub fn endWaitersOf(id: []const u8, reason: []const u8) void {
    const a = state.allocator;
    var i: usize = 0;
    while (i < state.waiter.subs.items.len) {
        const s = state.waiter.subs.items[i];
        // An `all` waiter counts a closed agent as settled.
        if (s.subscribed) if (s.watches(id)) |ti| {
            if (s.all) s.targets.items[ti].closed = true else s.drop(a, ti);
        };
        if (s.subscribed and s.targets.items.len == 0 and !s.server) {
            if (!s.done) endSub(s, reason);
            freeSub(a, s);
            _ = state.waiter.subs.swapRemove(i);
            continue;
        }
        i += 1;
    }
}

// ── tests ────────────────────────────────────────────────────────

const testing = std.testing;
const mcp_agent_testkit = @import("mcp_agent_testkit.zig");
const mcp_agent_open = @import("mcp_agent_open.zig");
const mcp_agent_talk = @import("mcp_agent_talk.zig");
const hold = mcp_agent.hold;
const adapters = mcp_agent.adapters;
const waiterTemplate = mcp_agent.waiterTemplate;
const ToolRig = mcp_agent_testkit.ToolRig;
const expectError = mcp_agent_testkit.expectError;
const shaped = mcp_agent_testkit.shaped;
const newEntry = mcp_agent_open.newEntry;
const closeTool = mcp_agent_talk.closeTool;

test "the waiter socket: subscribe, wake once, and end when the agent closes" {
    var rig: ToolRig = undefined;
    try rig.init();
    defer rig.deinit();
    const set = try adapters();
    const e = try newEntry(set.get("claude").?, "claude-1", "agent-claude-1", "/bin/claude", "/");
    const ag = try state.allocator.create(agent_mod.Agent);
    ag.* = try agent_mod.Agent.initScreen(state.allocator, set.get("claude").?, .{});
    e.agent = ag;
    e.visible = .{ .borrowed = 4242 };
    try state.entries.append(state.allocator, e);

    const connectSub = struct {
        fn f(line: []const u8) !c_int {
            const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
            var addr: c.struct_sockaddr_un = undefined;
            try @import("../mux/sockpath.zig").fillSockaddrUn(&addr, state.waiter.path.?);
            if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0) return error.ConnectFailed;
            _ = c.write(fd, line.ptr, line.len);
            return fd;
        }
    }.f;
    const readLine = struct {
        fn f(fd: c_int, buf: []u8) ![]const u8 {
            return readLineFor(fd, buf, 3000);
        }
    }.f;

    // Unknown agent: an end line at once.
    const bad = try connectSub("{\"agent\":\"nope-1\"}\n");
    defer _ = c.close(bad);
    var buf: [4096]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, try readLine(bad, &buf), "\"type\":\"end\"") != null);

    // The terminal id names nothing, so the first service reports the
    // connection lost; the assistant takes that, and a subscriber without
    // `since` starts after what the assistant was handed.
    service(clock.nowMs());
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expect((try e.cursor.take(e.agent.queue(), .{}, clock.nowMs(), arena_state.allocator())) != null);

    // A one-shot subscriber wakes on done, then is let go.
    const one = try connectSub("{\"agent\":\"claude-1\"}\n");
    defer _ = c.close(one);
    service(clock.nowMs());
    _ = try ag.source.screen.queue.push(clock.nowMs(), .done, null, "all done", "");
    const woke = try readLine(one, &buf);
    try testing.expect(std.mem.indexOf(u8, woke, "\"kind\":\"done\"") != null);
    try testing.expect(std.mem.indexOf(u8, woke, "connection_lost") == null);
    try testing.expect(std.mem.indexOf(u8, woke, "all done") != null);

    // ONE delivery state: the done the waiter printed went into the same
    // assistant's context, so no agent_* result hands it out again.
    try testing.expectEqual(@as(usize, 0), e.agent.queue().undelivered());
    try testing.expect((try e.cursor.take(e.agent.queue(), .{}, clock.nowMs(), arena_state.allocator())) == null);

    // The same watch command, run again later, waits for what is new: it
    // never re-wakes on an event already delivered (a baked-in cursor went
    // stale). Two waiters armed on one agent: the first delivers, the
    // other keeps waiting.
    const tmpl = (try waiterTemplate(arena_state.allocator())).?;
    try testing.expect(std.mem.indexOf(u8, tmpl, "--since") == null);
    const again = try connectSub("{\"agent\":\"claude-1\"}\n");
    defer _ = c.close(again);
    const twin = try connectSub("{\"agent\":\"claude-1\"}\n");
    defer _ = c.close(twin);
    try testing.expectError(error.Timeout, readLineFor(again, &buf, 400));
    _ = try ag.source.screen.queue.push(clock.nowMs(), .done, null, "second turn", "");
    service(clock.nowMs());
    var woken: usize = 0;
    for ([_]c_int{ again, twin }) |fd| {
        if (readLineFor(fd, &buf, 300)) |line| {
            woken += 1;
            try testing.expect(std.mem.indexOf(u8, line, "second turn") != null);
            try testing.expect(std.mem.indexOf(u8, line, "all done") == null);
        } else |_| {}
    }
    try testing.expectEqual(@as(usize, 1), woken);

    // A tool call on the agent holds its waiters: the call's own result
    // gets what happens meanwhile, never both.
    hold(e);
    _ = try ag.source.screen.queue.push(clock.nowMs(), .needs_input, null, "permission: rm", "");
    service(clock.nowMs());
    try testing.expect((try e.cursor.take(e.agent.queue(), .{}, clock.nowMs(), arena_state.allocator())) != null);
    state.held_len = 0;

    // A follower from seq 0 re-reads everything, delivered or not, then
    // gets the end on close.
    const follow = try connectSub("{\"agent\":\"agent-claude-1\",\"follow\":true,\"since\":0}\n");
    defer _ = c.close(follow);
    const all = try readLine(follow, &buf);
    try testing.expect(std.mem.indexOf(u8, all, "connection_lost") != null);
    try testing.expect(std.mem.indexOf(u8, all, "all done") != null);
    try testing.expect(std.mem.indexOf(u8, all, "second turn") != null);

    _ = try closeTool(arena_state.allocator(), .null, e);
    // The follower re-reads (since 0), so its later wake lines come first.
    var used: usize = 0;
    const deadline = clock.nowMs() + 3000;
    while (std.mem.indexOf(u8, buf[0..used], "agent closed") == null) {
        if (clock.nowMs() > deadline) return error.Timeout;
        var pfd = c.struct_pollfd{ .fd = follow, .events = c.POLLIN, .revents = 0 };
        if (c.poll(&pfd, 1, 50) <= 0) continue;
        const n = c.read(follow, buf[used..].ptr, buf.len - used);
        if (n <= 0) break;
        used += @intCast(n);
    }
    try testing.expect(std.mem.indexOf(u8, buf[0..used], "agent closed") != null);
}

test "an event announcing a record carries its id and a one-line preview, never the text again" {
    var rig: ToolRig = undefined;
    try rig.init();
    defer rig.deinit();
    const a = rig.arena.allocator();
    const set = try adapters();
    const e = try newEntry(set.get("claude").?, "claude-1", "agent-claude-1", "/bin/claude", "/");
    const ag = try state.allocator.create(agent_mod.Agent);
    ag.* = try agent_mod.Agent.initScreen(state.allocator, set.get("claude").?, .{});
    e.agent = ag;
    e.visible = .{ .borrowed = 4242 };
    try state.entries.append(state.allocator, e);
    const long = "first line of a long report\n" ++ "x" ** 3000;
    _ = try ag.source.screen.queue.pushDone(clock.nowMs(), 0, 0, long, 42, null);
    _ = try ag.source.screen.queue.push(clock.nowMs(), .needs_input, null, "permission: rm", "1. Yes");
    const read = try mcp.expectToolResultShape(a, "agent_read", try rig.call(.agent_read, "{}"));
    const sc = read.object.get("structuredContent").?.object;
    var saw_done = false;
    for (sc.get("events").?.array.items) |ev| {
        const kind = ev.object.get("kind").?.string;
        if (!std.mem.eql(u8, kind, "done")) continue;
        saw_done = true;
        try testing.expectEqualStrings("first line of a long report", ev.object.get("text").?.string);
        try testing.expectEqual(@as(i64, 42), ev.object.get("record").?.integer);
    }
    try testing.expect(saw_done);
    // Nothing of the long text anywhere in the result.
    const raw = try std.json.Stringify.valueAlloc(a, read, .{});
    try testing.expect(std.mem.indexOf(u8, raw, "xxxxxxxxxx") == null);
}

test "the plain waiter prints the push text: a done's answer in full, then handed out" {
    var rig: ToolRig = undefined;
    try rig.init();
    defer rig.deinit();
    const a = rig.arena.allocator();
    const set = try adapters();
    const e = try newEntry(set.get("claude").?, "claude-1", "agent-claude-1", "/bin/claude", "/");
    const ag = try state.allocator.create(agent_mod.Agent);
    ag.* = try agent_mod.Agent.initScreen(state.allocator, set.get("claude").?, .{});
    e.agent = ag;
    e.visible = .{ .borrowed = 4242 };
    try state.entries.append(state.allocator, e);
    service(clock.nowMs());
    _ = try e.cursor.take(e.agent.queue(), .{}, clock.nowMs(), a);
    const eng = &ag.source.screen;
    const answer = "Both fixes are in and the suite is green; the flaky socket test was a real ordering bug.";
    try eng.records.append(state.allocator, .{ .id = 7, .kind = .assistant, .text = try state.allocator.dupe(u8, answer), .job = 0 });
    // The compact list's preview is a glance: it hands nothing out.
    const listed = try shaped(a, "agent_list", try rig.call(.agent_list, "{}"));
    try testing.expectEqualStrings(answer, listed.get("agents").?.array.items[0].object.get("preview").?.string);
    try testing.expect(!e.handed.has(eng.records.items[0]));

    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    defer _ = c.close(fd);
    var addr: c.struct_sockaddr_un = undefined;
    try @import("../mux/sockpath.zig").fillSockaddrUn(&addr, state.waiter.path.?);
    try testing.expect(c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) == 0);
    const line = "{\"agent\":\"claude-1\",\"content\":true}\n";
    _ = c.write(fd, line, line.len);
    var buf: [8192]u8 = undefined;
    try testing.expectError(error.Timeout, readLineFor(fd, &buf, 200));
    _ = try eng.queue.pushDone(clock.nowMs(), 0, 0, answer, 7, null);
    const woke = try readLineFor(fd, &buf, 3000);
    const m = try std.json.parseFromSliceLeaky(agentwait.Message, a, std.mem.trimEnd(u8, woke, "\n"), .{ .ignore_unknown_fields = true });
    var printed: std.Io.Writer.Allocating = .init(a);
    try agentwait.formatPrinted(&printed.writer, m);
    try testing.expectEqualStrings("claude-1 done: " ++ answer ++ " [state disconnected]\n\n" ++ answer, printed.written());
    // Printed in full: handed out, so the default read does not repeat it.
    try testing.expect(e.handed.has(eng.records.items[0]));
    const read = try shaped(a, "agent_read", try rig.call(.agent_read, "{}"));
    try testing.expectEqual(@as(usize, 0), read.get("records").?.array.items.len);
}

test "the background cap's done is quiet: only background:true gets it, and its watch_command keeps the opt-in" {
    var rig: ToolRig = undefined;
    try rig.init();
    defer rig.deinit();
    const a = rig.arena.allocator();
    const set = try adapters();
    const e = try newEntry(set.get("claude").?, "claude-1", "agent-claude-1", "/bin/claude", "/");
    const ag = try state.allocator.create(agent_mod.Agent);
    ag.* = try agent_mod.Agent.initScreen(state.allocator, set.get("claude").?, .{});
    e.agent = ag;
    e.visible = .{ .borrowed = 4242 };
    try state.entries.append(state.allocator, e);
    // The terminal names nothing: take the connection_lost first.
    service(clock.nowMs());
    _ = try e.cursor.take(e.agent.queue(), .{}, clock.nowMs(), a);
    _ = try ag.source.screen.queue.pushDone(clock.nowMs(), 0, 0, "the build runs in the background", null, 2);
    const plain = try shaped(a, "agent_wait", try rig.call(.agent_wait, "{\"timeout_ms\":0}"));
    try testing.expectEqualStrings("still_working", plain.get("outcome").?.string);
    try testing.expectEqual(@as(usize, 0), plain.get("events").?.array.items.len);
    // The results' cursor examined that one without wanting it (as for a
    // retrying error); the next quiet done reaches a call that opts in.
    _ = try ag.source.screen.queue.pushDone(clock.nowMs(), 0, 0, "the build runs in the background", null, 2);
    const opted = try shaped(a, "agent_wait", try rig.call(.agent_wait, "{\"background\":true,\"timeout_ms\":0}"));
    try testing.expectEqualStrings("done", opted.get("outcome").?.string);
    try testing.expectEqual(@as(i64, 2), opted.get("events").?.array.items[0].object.get("background_tasks").?.integer);
    try testing.expect(std.mem.indexOf(u8, opted.get("watch_command").?.string, " --background ") != null);
    try testing.expect(e.push_filter.background);
}

test "the waiter --any: the first wake-up of several agents names its agent; a closed one is dropped" {
    var rig: ToolRig = undefined;
    try rig.init();
    defer rig.deinit();
    const set = try adapters();
    var ags: [2]*agent_mod.Agent = undefined;
    for ([_][]const u8{ "claude-1", "claude-2" }, 0..) |id, i| {
        const e = try newEntry(set.get("claude").?, id, id, "/bin/claude", "/");
        const ag = try state.allocator.create(agent_mod.Agent);
        ag.* = try agent_mod.Agent.initScreen(state.allocator, set.get("claude").?, .{});
        e.agent = ag;
        e.visible = .{ .borrowed = 4242 };
        try state.entries.append(state.allocator, e);
        ags[i] = ag;
    }
    // The terminals name nothing: take the connection_lost both report.
    service(clock.nowMs());
    for (state.entries.items) |e| _ = try e.cursor.take(e.agent.queue(), .{}, clock.nowMs(), rig.arena.allocator());

    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    defer _ = c.close(fd);
    var addr: c.struct_sockaddr_un = undefined;
    try @import("../mux/sockpath.zig").fillSockaddrUn(&addr, state.waiter.path.?);
    try testing.expect(c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) == 0);
    const line = "{\"agent\":\"claude-1\",\"agents\":[\"claude-1\",\"claude-2\"],\"follow\":true}\n";
    _ = c.write(fd, line, line.len);
    var buf: [4096]u8 = undefined;
    try testing.expectError(error.Timeout, readLineFor(fd, &buf, 300));
    _ = try ags[1].source.screen.queue.push(clock.nowMs(), .done, null, "two finished", "");
    const woke = try readLineFor(fd, &buf, 3000);
    try testing.expect(std.mem.indexOf(u8, woke, "\"agent\":\"claude-2\"") != null);
    try testing.expect(std.mem.indexOf(u8, woke, "two finished") != null);
    // Closing one leaves the waiter on the other.
    _ = try closeTool(rig.arena.allocator(), .null, state.entries.items[1]);
    _ = try ags[0].source.screen.queue.push(clock.nowMs(), .done, null, "one finished", "");
    const next = try readLineFor(fd, &buf, 3000);
    try testing.expect(std.mem.indexOf(u8, next, "\"agent\":\"claude-1\"") != null);
    // agent_wait agents: the same first-wins rule, through the tool.
    _ = try ags[0].source.screen.queue.push(clock.nowMs(), .needs_input, null, "permission: x", "");
    const waited = try shaped(rig.arena.allocator(), "agent_wait", try rig.call(.agent_wait, "{\"agents\":[\"claude-1\"],\"timeout_ms\":0}"));
    try testing.expectEqualStrings("claude-1", waited.get("agent").?.string);
    try testing.expectEqual(@as(usize, 1), waited.get("agents").?.array.items.len);
    try expectError(rig.arena.allocator(), "agent_wait", try rig.call(.agent_wait, "{\"agents\":[\"nope-9\"]}"), "not_found");
    try expectError(rig.arena.allocator(), "agent_wait", try rig.call(.agent_wait, "{\"agents\":\"claude-1\"}"), "invalid_args");
    // "*" is every live agent of this server: the one left open.
    _ = try ags[0].source.screen.queue.push(clock.nowMs(), .needs_input, null, "permission: y", "");
    const star = try shaped(rig.arena.allocator(), "agent_wait", try rig.call(.agent_wait, "{\"agents\":\"*\",\"timeout_ms\":0}"));
    try testing.expectEqual(@as(usize, 1), star.get("agents").?.array.items.len);
    try testing.expectEqualStrings("claude-1", star.get("agents").?.array.items[0].string);
    try testing.expectEqualStrings("needs_input", star.get("outcome").?.string);
}

/// Read one waiter line within `ms`, servicing the server meanwhile.
fn readLineFor(fd: c_int, buf: []u8, ms: i64) ![]const u8 {
    var used: usize = 0;
    const deadline = clock.nowMs() + ms;
    while (clock.nowMs() < deadline) {
        service(clock.nowMs());
        var pfd = c.struct_pollfd{ .fd = fd, .events = c.POLLIN, .revents = 0 };
        if (c.poll(&pfd, 1, 20) <= 0) continue;
        const n = c.read(fd, buf[used..].ptr, buf.len - used);
        if (n <= 0) return buf[0..used];
        used += @intCast(n);
        if (std.mem.indexOfScalar(u8, buf[0..used], '\n') != null) return buf[0..used];
    }
    return error.Timeout;
}
