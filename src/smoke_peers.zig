//! Peer messaging stage, shared by smoke-mux and smoke-broker: real
//! `sketerm-mcp` servers message each other through the rig's broker.
//!
//! The servers reach the broker the way they reach the per-user daemon
//! (`connectLocalAutostartAt(null)`): an isolated `XDG_RUNTIME_DIR` whose
//! `sketerm/mux.sock` is a symlink to the rig socket, so no server can
//! reach the user's own daemon. `prepare` runs before the rig forks its
//! broker: the broker reads the mail TTL (`SKETERM_MUX_PEER_TTL_MS`) and
//! its mailbox directory (`XDG_STATE_HOME`) when it starts.

const std = @import("std");
const c = @import("c.zig").c;
const mcpproc = @import("smoke/mcpproc.zig");
const daemon_peers = @import("mux/daemon_peers.zig");
const nowMs = @import("util/clock.zig").nowMs;

fn fail(comptime msg: []const u8) noreturn {
    std.debug.print("smoke peers stage: FAIL: " ++ msg ++ "\n", .{});
    std.process.exit(1);
}

const Mcp = mcpproc.Mcp(fail);

/// The rig broker's mail TTL: long enough for a server restart, short
/// enough to wait out.
const TTL_MS: i64 = 5_000;
const TTL_TEXT = "5000";
/// One sweep period plus scheduling slack past the TTL.
const EXPIRY_BUDGET_MS: i64 = TTL_MS + daemon_peers.SWEEP_EVERY_MS + 4_000;

var root_buf: [64:0]u8 = undefined;
var rt_buf: [80:0]u8 = undefined;
var st_buf: [80:0]u8 = undefined;
var cfg_buf: [80:0]u8 = undefined;
var prepared = false;

fn mkdirOrFail(path: [:0]const u8) void {
    _ = c.mkdir(path.ptr, 0o700);
    if (c.access(path.ptr, c.F_OK) != 0) fail("mkdir of an isolated directory");
}

/// Before the rig forks its broker: a short private root, the broker's
/// state home inside it (mailboxes never land in the user's), the TTL.
pub fn prepare() void {
    const root = std.fmt.bufPrintZ(&root_buf, "/tmp/skp-{d}", .{c.getpid()}) catch unreachable;
    const rt = std.fmt.bufPrintZ(&rt_buf, "{s}/rt", .{root}) catch unreachable;
    const st = std.fmt.bufPrintZ(&st_buf, "{s}/st", .{root}) catch unreachable;
    const cfg = std.fmt.bufPrintZ(&cfg_buf, "{s}/cfg", .{root}) catch unreachable;
    mkdirOrFail(root);
    mkdirOrFail(rt);
    mkdirOrFail(st);
    mkdirOrFail(cfg);
    _ = c.setenv("XDG_STATE_HOME", st.ptr, 1);
    _ = c.setenv(daemon_peers.TTL_ENV, TTL_TEXT, 1);
    prepared = true;
}

/// What would point a server at the developer's own sketerm, or name it.
const UNSET = [_][*:0]const u8{
    "SKETERM_SOCKET",
    "SKETERM_PANE_ID",
    "SKETERM_MUX_SOCKET",
    "SKETERM_SESSION",
    "SKETERM_SESSION_ORIGIN_ID",
    "SKETERM_PEER_NAME",
};

const Stage = struct {
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    exe: [*:0]const u8,

    fn env(self: *Stage, name: ?[*:0]const u8) []const [2][*:0]const u8 {
        const base = [_][2][*:0]const u8{
            .{ "XDG_RUNTIME_DIR", &rt_buf },
            .{ "XDG_STATE_HOME", &st_buf },
            .{ "XDG_CONFIG_HOME", &cfg_buf },
        };
        const out = self.arena.alloc([2][*:0]const u8, base.len + 1) catch fail("oom");
        @memcpy(out[0..base.len], &base);
        if (name) |n| {
            out[base.len] = .{ "SKETERM_PEER_NAME", n };
            return out;
        }
        return out[0..base.len];
    }

    /// A server registered under `name` (null: none, anon), started
    /// directly or under a parent shell carrying `under`.
    fn server(self: *Stage, name: ?[*:0]const u8, under: ?[]const [*:0]const u8) Mcp {
        return Mcp.spawnWith(self.allocator, self.exe, .{
            .extra = if (under == null) &.{"--no-record"} else &.{},
            .under = under,
            .unset_env = &UNSET,
            .set_env = self.env(name),
        });
    }
};

/// One tools/call: its structuredContent (skipping notification lines).
fn call(m: *Mcp, arena: std.mem.Allocator, tool: []const u8, args: []const u8, comptime what: []const u8) std.json.ObjectMap {
    m.sendToolAllocated(tool, args);
    const deadline = nowMs() + 20_000;
    while (nowMs() < deadline) {
        const line = arena.dupe(u8, m.recvLine(20_000)) catch fail("oom");
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch fail(what ++ ": reply is not JSON");
        if (v != .object) continue;
        const id = v.object.get("id") orelse continue;
        if (id != .integer or id.integer != m.id) continue;
        const result = (v.object.get("result") orelse fail(what ++ ": no result")).object;
        if (result.get("isError")) |e| if (e == .bool and e.bool) {
            std.debug.print("{s}\n", .{line});
            fail(what ++ ": error result");
        };
        const sc = result.get("structuredContent") orelse fail(what ++ ": no structuredContent");
        return sc.object;
    }
    fail(what ++ ": no reply");
}

fn str(o: std.json.ObjectMap, key: []const u8, comptime what: []const u8) []const u8 {
    const v = o.get(key) orelse fail(what ++ ": a fact is missing");
    if (v != .string) fail(what ++ ": a fact is not a string");
    return v.string;
}

fn boolOf(o: std.json.ObjectMap, key: []const u8, comptime what: []const u8) bool {
    const v = o.get(key) orelse fail(what ++ ": a flag is missing");
    if (v != .bool) fail(what ++ ": a flag is not a bool");
    return v.bool;
}

fn expectStr(o: std.json.ObjectMap, key: []const u8, want: []const u8, comptime what: []const u8) void {
    const got = str(o, key, what);
    if (!std.mem.eql(u8, got, want)) {
        std.debug.print("{s}: got \"{s}\", want \"{s}\"\n", .{ key, got, want });
        fail(what);
    }
}

fn contains(hay: []const u8, needle: []const u8, comptime what: []const u8) void {
    if (std.mem.indexOf(u8, hay, needle) == null) {
        std.debug.print("missing \"{s}\" in:\n{s}\n", .{ needle, hay });
        fail(what);
    }
}

/// `capabilities.peers` once the broker answered the registration.
fn registered(m: *Mcp, arena: std.mem.Allocator, comptime what: []const u8) std.json.ObjectMap {
    const deadline = nowMs() + 10_000;
    while (nowMs() < deadline) {
        const caps = call(m, arena, "capabilities", "{}", what ++ " capabilities");
        const peers = (caps.get("peers") orelse fail(what ++ ": capabilities has no peers")).object;
        if (!boolOf(peers, "available", what)) {
            std.debug.print("peers: {s}\n", .{str(peers, "reason", what)});
            fail(what ++ ": capabilities.peers.available is false");
        }
        if (str(peers, "address", what).len > 0) return peers;
        _ = c.usleep(50_000);
    }
    fail(what ++ ": the broker never answered the registration");
}

/// peer_send's structuredContent.
fn send(m: *Mcp, arena: std.mem.Allocator, to: []const u8, text: []const u8, comptime what: []const u8) std.json.ObjectMap {
    const args = std.fmt.allocPrint(arena, "{{\"to\":{f},\"text\":{f}}}", .{ std.json.fmt(to, .{}), std.json.fmt(text, .{}) }) catch fail("oom");
    const r = call(m, arena, "peer_send", args, what);
    if (!boolOf(r, "available", what)) fail(what ++ ": peer_send says peers are unavailable");
    return r;
}

fn expectRefused(m: *Mcp, arena: std.mem.Allocator, to: []const u8, text: []const u8, reason: []const u8, comptime what: []const u8) void {
    const r = send(m, arena, to, text, what);
    expectStr(r, "outcome", "refused", what ++ ": outcome");
    expectStr(r, "reason", reason, what ++ ": reason");
}

fn items(m: *Mcp, arena: std.mem.Allocator, comptime what: []const u8) []std.json.Value {
    const r = call(m, arena, "peer_read", "{}", what);
    return (r.get("items") orelse fail(what ++ ": peer_read has no items")).array.items;
}

/// peer_read until it returns something (bounded); exactly one item.
fn readOne(m: *Mcp, arena: std.mem.Allocator, budget_ms: i64, comptime what: []const u8) std.json.ObjectMap {
    const deadline = nowMs() + budget_ms;
    while (nowMs() < deadline) {
        const got = items(m, arena, what);
        if (got.len > 1) fail(what ++ ": more than the one item expected");
        if (got.len == 1) return got[0].object;
        _ = c.usleep(100_000);
    }
    fail(what ++ ": nothing arrived");
}

fn expectNothing(m: *Mcp, arena: std.mem.Allocator, comptime what: []const u8) void {
    if (items(m, arena, what).len != 0) fail(what ++ ": an item was handed out twice");
}

/// The peer_list line for `address`, or null.
fn listed(m: *Mcp, arena: std.mem.Allocator, address: []const u8, comptime what: []const u8) ?std.json.ObjectMap {
    const r = call(m, arena, "peer_list", "{\"detail\":true}", what);
    for ((r.get("peers") orelse fail(what ++ ": no peers")).array.items) |p| {
        if (std.mem.eql(u8, str(p.object, "address", what), address)) return p.object;
    }
    return null;
}

/// Poll `m`'s peer_list until `address` is offline (`gone_entirely`:
/// not listed at all).
fn awaitOffline(m: *Mcp, arena: std.mem.Allocator, address: []const u8, gone_entirely: bool, comptime what: []const u8) void {
    const deadline = nowMs() + 10_000;
    while (nowMs() < deadline) {
        if (listed(m, arena, address, what)) |p| {
            if (!gone_entirely and !boolOf(p, "live", what)) return;
        } else if (gone_entirely) return;
        _ = c.usleep(50_000);
    }
    fail(what ++ ": the stopped server is still listed live");
}

fn expectLiveDurable(m: *Mcp, arena: std.mem.Allocator, address: []const u8, comptime what: []const u8) void {
    const p = listed(m, arena, address, what) orelse fail(what ++ ": a live peer is not listed");
    if (!boolOf(p, "live", what)) fail(what ++ ": a live peer is listed offline");
    if (!boolOf(p, "durable", what)) fail(what ++ ": a named peer is not durable");
    expectStr(p, "state", "unknown", what ++ ": a peer without hooks reports a state");
}

pub fn run(allocator: std.mem.Allocator, sock_path: []const u8, exe: [*:0]const u8) void {
    if (!prepared) fail("prepare() must run before the broker is forked");
    const started = nowMs();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var stage = Stage{ .allocator = allocator, .arena = arena, .exe = exe };

    // The isolated runtime dir's per-user socket IS the rig broker.
    {
        var dir_buf: [96:0]u8 = undefined;
        const dir = std.fmt.bufPrintZ(&dir_buf, "{s}/sketerm", .{std.mem.sliceTo(&rt_buf, 0)}) catch unreachable;
        mkdirOrFail(dir);
        var link_buf: [112:0]u8 = undefined;
        const link = std.fmt.bufPrintZ(&link_buf, "{s}/mux.sock", .{dir}) catch unreachable;
        var target_buf: [256:0]u8 = undefined;
        const target = std.fmt.bufPrintZ(&target_buf, "{s}", .{sock_path}) catch fail("socket path too long");
        _ = c.unlink(link.ptr);
        if (c.symlink(target.ptr, link.ptr) != 0) fail("symlink the per-user socket to the rig broker");
    }

    // 1. carol registers once and leaves: her durable address is known
    //    from now on (the expiry case mails her while she is away).
    {
        var carol = stage.server("carol", null);
        carol.initialize();
        expectStr(registered(&carol, arena, "carol"), "address", "carol", "1. carol's address");
        carol.closeStdinWait();
    }

    // -- a. two named servers see each other --
    // 2. alice and bob register under SKETERM_PEER_NAME: capabilities
    //    report peers available, durable, at that address.
    var alice = stage.server("alice", null);
    alice.initialize();
    var bob = stage.server("bob", null);
    bob.initialize();
    for ([_]struct { m: *Mcp, name: []const u8 }{ .{ .m = &alice, .name = "alice" }, .{ .m = &bob, .name = "bob" } }) |s| {
        const caps = registered(s.m, arena, "2. registration");
        expectStr(caps, "address", s.name, "2. capabilities.peers.address");
        if (!boolOf(caps, "durable", "2.")) fail("2. a named server is not durable");
        if (boolOf(caps, "name_taken", "2.")) fail("2. a free name reads as taken");
    }
    // 3. each one's peer_list shows both, live, durable, state unknown.
    for ([_]*Mcp{ &alice, &bob }) |m| {
        expectLiveDurable(m, arena, "alice", "3. peer_list alice");
        expectLiveDurable(m, arena, "bob", "3. peer_list bob");
    }
    std.debug.print("smoke: peers: two named servers list each other ok\n", .{});

    // -- b. delivery to a live server, handed out once --
    // 4. alice -> bob: delivered.
    const hello = send(&alice, arena, "bob", "hello bob, this is the body", "4. send to live bob");
    expectStr(hello, "outcome", "delivered", "4. outcome to a live server");
    const hello_id = str(hello, "id", "4.");
    // 5. bob's peer_read returns it with the composed text.
    {
        const it = readOne(&bob, arena, 5_000, "5. bob peer_read");
        expectStr(it, "kind", "message", "5. kind");
        expectStr(it, "id", hello_id, "5. id");
        expectStr(it, "from", "alice", "5. from");
        expectStr(it, "text", "hello bob, this is the body", "5. text");
        const content = str(it, "content", "5.");
        contains(content, "Peer message from alice (", "5. the composed sender line");
        contains(content, "Reply with peer_send to \"alice\".", "5. the reply hint");
        contains(content, "\n\nhello bob, this is the body", "5. the body after a blank line");
        if (std.mem.indexOf(u8, content, "while you were offline") != null) fail("5. live delivery reads as offline");
    }
    // 6. a second read hands out nothing.
    expectNothing(&bob, arena, "6. bob peer_read again");
    std.debug.print("smoke: peers: live delivery, read once ok\n", .{});

    // -- c. a durable address while its server is away --
    // 7. bob stops; alice's list shows him offline.
    bob.closeStdinWait();
    awaitOffline(&alice, arena, "bob", false, "7. bob offline");
    // 8. alice -> bob: queued.
    const away = send(&alice, arena, "bob", "sent while you were away", "8. send to offline bob");
    expectStr(away, "outcome", "queued", "8. outcome to an offline durable address");
    const away_id = str(away, "id", "8.");
    // 9. a new bob (under a parent shell, for the follower below) gets it,
    //    worded as offline mail.
    var bob2 = stage.server("bob", &.{});
    bob2.initialize();
    {
        const caps = registered(&bob2, arena, "9. bob again");
        expectStr(caps, "address", "bob", "9. the restarted server's address");
        if (boolOf(caps, "name_taken", "9.")) fail("9. the restarted server found its own old name taken");
        const it = readOne(&bob2, arena, 5_000, "9. bob2 peer_read");
        expectStr(it, "id", away_id, "9. id");
        if (!boolOf(it, "queued", "9.")) fail("9. queued mail is not marked queued");
        const content = str(it, "content", "9.");
        contains(content, "while you were offline", "9. offline wording");
        contains(content, "\n\nsent while you were away", "9. body");
    }
    expectNothing(&bob2, arena, "9. bob2 peer_read again");
    // 10. refusals: a never-seen name, oneself, an oversized text.
    expectRefused(&alice, arena, "nobody-here", "hi", "unknown_address", "10. unknown address");
    expectRefused(&alice, arena, "alice", "hi", "self", "10. self");
    {
        const big = arena.alloc(u8, 70 * 1024) catch fail("oom");
        @memset(big, 'x');
        expectRefused(&alice, arena, "bob", big, "too_large", "10. too large");
    }
    std.debug.print("smoke: peers: queued for an offline durable name, offline wording, refusals ok\n", .{});

    // -- f. the opencode route: an agent-wait --server follower --
    // 11. the plugin's own argv against bob2's parent (the shell).
    {
        var pid_buf: [16:0]u8 = undefined;
        const parent = std.fmt.bufPrintZ(&pid_buf, "{d}", .{bob2.pid}) catch unreachable;
        var follower = Mcp.spawnWith(allocator, exe, .{
            .extra = &.{ "agent-wait", "--server", "--follow", "--json", "--parent", parent.ptr },
            .unset_env = &UNSET,
            .set_env = stage.env(null),
        });
        // 12. alice -> bob: the follower prints the composed line once.
        const via = send(&alice, arena, "bob", "pushed to the follower", "12. send to followed bob");
        expectStr(via, "outcome", "delivered", "12. outcome");
        const deadline = nowMs() + 10_000;
        var woke: ?std.json.ObjectMap = null;
        while (woke == null) {
            const line = follower.recvLineOrNull(deadline - nowMs()) orelse fail("12. the follower printed no wake-up");
            const v = std.json.parseFromSliceLeaky(std.json.Value, arena, arena.dupe(u8, line) catch fail("oom"), .{}) catch continue;
            if (v != .object) continue;
            const ty = v.object.get("type") orelse continue;
            if (ty == .string and std.mem.eql(u8, ty.string, "end")) fail("12. the follower ended before the wake-up");
            if (ty == .string and std.mem.eql(u8, ty.string, "wake")) woke = v.object;
        }
        const content = str(woke.?, "content", "12.");
        contains(content, "Peer message from alice (", "12. the follower's composed line");
        contains(content, "\n\npushed to the follower", "12. the follower's body");
        // 13. handed out by the follower: peer_read does not repeat it.
        expectNothing(&bob2, arena, "13. bob2 peer_read after the follower");
        follower.terminate();
    }
    std.debug.print("smoke: peers: agent-wait --server follower delivery (the opencode route) ok\n", .{});

    // -- d. a non-durable server --
    // 14. no name, no session: an anon address, not durable; mail to it
    //     is delivered while it lives.
    var anon = stage.server(null, null);
    anon.initialize();
    const anon_addr = blk: {
        const caps = registered(&anon, arena, "14. anon");
        const a = arena.dupe(u8, str(caps, "address", "14.")) catch fail("oom");
        if (!std.mem.startsWith(u8, a, "anon-")) fail("14. an unnamed server's address is not anon-");
        if (boolOf(caps, "durable", "14.")) fail("14. an anon address is durable");
        break :blk a;
    };
    expectStr(send(&alice, arena, anon_addr, "to the anon peer", "14. send to anon"), "outcome", "delivered", "14. outcome to a live anon");
    expectStr(readOne(&anon, arena, 5_000, "14. anon peer_read"), "text", "to the anon peer", "14. anon text");
    // 15. once it is gone, its address is refused not_durable_gone.
    anon.closeStdinWait();
    awaitOffline(&alice, arena, anon_addr, true, "15. anon gone");
    expectRefused(&alice, arena, anon_addr, "too late", "not_durable_gone", "15. gone anon");
    std.debug.print("smoke: peers: anon address delivered while live, not_durable_gone after ok\n", .{});

    // -- e. expiry --
    // 16. alice -> carol (away since step 1): queued; past the TTL the
    //     sweep expires it and alice's peer_read gets the event.
    const late = send(&alice, arena, "carol", "you will never read this", "16. send to away carol");
    expectStr(late, "outcome", "queued", "16. outcome");
    const late_id = str(late, "id", "16.");
    {
        const sent_at = nowMs();
        const ev = readOne(&alice, arena, EXPIRY_BUDGET_MS, "16. alice peer_read the expiry");
        if (nowMs() - sent_at < TTL_MS - 500) fail("16. the expiry came before the TTL");
        expectStr(ev, "kind", "event", "16. kind");
        expectStr(ev, "id", late_id, "16. id");
        expectStr(ev, "outcome", "expired", "16. outcome");
        expectStr(ev, "to", "carol", "16. to");
        contains(str(ev, "content", "16."), "expired unread after", "16. wording");
    }
    // 17. the next carol learns it expired while she was away.
    {
        var carol2 = stage.server("carol", null);
        carol2.initialize();
        _ = registered(&carol2, arena, "17. carol again");
        const it = readOne(&carol2, arena, 5_000, "17. carol2 peer_read");
        expectStr(it, "kind", "expired_away", "17. kind");
        expectStr(it, "id", late_id, "17. id");
        expectStr(it, "from", "alice", "17. from");
        contains(str(it, "content", "17."), "expired unread while you were away", "17. wording");
        carol2.closeStdinWait();
    }
    std.debug.print("smoke: peers: TTL expiry reaches the sender and the recipient's next server ok\n", .{});

    // -- g. the Claude Code channel route --
    // 18. a server under a parent carrying the development-channels
    //     option, initialized as claude-code: the channel is armed after
    //     its first tool call.
    var dave = stage.server("dave", &.{ "--dangerously-load-development-channels", "server:sketerm" });
    contains(dave.initializeAs("claude-code"), "\"claude/channel\"", "18. initialize declares claude/channel");
    dave.send("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}");
    {
        const caps = registered(&dave, arena, "18. dave");
        expectStr(caps, "address", "dave", "18. address");
        if (!boolOf(caps, "channel_armed", "18.")) fail("18. the channel is not armed");
    }
    // 19. alice -> dave: a notifications/claude/channel line on dave's stdout.
    expectStr(send(&alice, arena, "dave", "over the channel", "19. send to dave"), "outcome", "delivered", "19. outcome");
    {
        const deadline = nowMs() + 10_000;
        while (true) {
            const line = dave.recvLineOrNull(deadline - nowMs()) orelse fail("19. no channel notification");
            if (std.mem.indexOf(u8, line, "\"notifications/claude/channel\"") == null) continue;
            contains(line, "Peer message from alice (", "19. the channel's composed line");
            contains(line, "over the channel", "19. the channel's body");
            break;
        }
    }
    // 20. handed out by the channel: peer_read does not repeat it.
    expectNothing(&dave, arena, "20. dave peer_read after the channel");
    std.debug.print("smoke: peers: Claude Code channel delivery ok\n", .{});

    dave.closeStdinWait();
    bob2.closeStdinWait();
    alice.closeStdinWait();
    std.debug.print("smoke: peers stage ok ({d} ms)\n", .{nowMs() - started});
}
