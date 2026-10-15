//! Peer messaging stage, shared by smoke-mux and smoke-broker: real
//! `sketerm-mcp` servers message each other through the rig's broker.
//!
//! The servers reach the broker the way they reach the per-user daemon
//! (`connectLocalAutostartAt(null)`): an isolated `XDG_RUNTIME_DIR` whose
//! `sketerm/mux.sock` is a symlink to the rig socket, so no server can
//! reach the user's own daemon. `prepare` runs before the rig forks its
//! broker: the broker reads the mail TTL (`SKETERM_MUX_PEER_TTL_MS`), its
//! mailbox directory (`XDG_STATE_HOME`) and its config (`XDG_CONFIG_HOME`,
//! isolated so a developer's `peer_hub` never makes a rig broker dial)
//! when it starts.
//!
//! `runFederation` is the phase 2 stage: two more isolated daemons, exec'd
//! from the built sketerm-mux, one the hub, linked through a fake ssh; it
//! ends with a bare local connection acting as a hub's link.

const std = @import("std");
const c = @import("c.zig").c;
const mcpproc = @import("smoke/mcpproc.zig");
const daemon_peers = @import("mux/daemon_peers.zig");
const peermail = @import("mux/peermail.zig");
const muxclient = @import("mux/client.zig");
const nowMs = @import("util/clock.zig").nowMs;
const atomicwrite = @import("util/atomicwrite.zig");
const readfile = @import("util/readfile.zig");
const envutil = @import("util/env.zig");
const facts = @import("agent/facts.zig");

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
    _ = c.setenv("XDG_CONFIG_HOME", cfg.ptr, 1);
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

    /// A server under a parent shell that also runs the scripts dropped
    /// in `runs` (`runInTree`): processes of its client's tree.
    fn serverWithTree(self: *Stage, name: [*:0]const u8, runs: [*:0]const u8) Mcp {
        return Mcp.spawnWith(self.allocator, self.exe, .{
            .under = &.{},
            .runs_dir = runs,
            .unset_env = &UNSET,
            .set_env = self.env(name),
        });
    }
};

/// What a script run inside a server's client tree printed, and its status.
const TreeRun = struct { out: []const u8, rc: []const u8 };

var tree_seq: u32 = 0;

/// Drop `body` (a sh command line; `{exe}` is the sketerm-mcp binary)
/// in `runs` and wait for the parent shell to have run it: its stdout,
/// stderr dropped, and exit status.
fn runInTree(arena: std.mem.Allocator, runs: []const u8, exe: [*:0]const u8, body: []const u8, comptime what: []const u8) TreeRun {
    tree_seq += 1;
    const base = std.fmt.allocPrint(arena, "{s}/r{d}", .{ runs, tree_seq }) catch fail("oom");
    const cmd = std.mem.replaceOwned(u8, arena, body, "{exe}", std.mem.span(exe)) catch fail("oom");
    const script = std.fmt.allocPrint(arena, "{s} > '{s}.out' 2>/dev/null; echo $? > '{s}.rc.tmp'; mv '{s}.rc.tmp' '{s}.rc'\n", .{ cmd, base, base, base, base }) catch fail("oom");
    atomicwrite.writeFile(std.fmt.allocPrint(arena, "{s}.sh", .{base}) catch fail("oom"), script, 0o600) catch fail(what ++ ": write the script");
    const rc_path = std.fmt.allocPrint(arena, "{s}.rc", .{base}) catch fail("oom");
    const deadline = nowMs() + 10_000;
    while (nowMs() < deadline) {
        if (readfile.capped(arena, rc_path, 64)) |rc| {
            const out = readfile.capped(arena, std.fmt.allocPrint(arena, "{s}.out", .{base}) catch fail("oom"), 1 << 20) orelse fail(what ++ ": no output file");
            return .{ .out = out, .rc = std.mem.trimEnd(u8, rc, "\n") };
        }
        _ = c.usleep(20_000);
    }
    fail(what ++ ": the script never ran in the server's tree");
}

/// Write `bytes` to `<runs>/<name>`; its path.
fn inputFile(arena: std.mem.Allocator, runs: []const u8, name: []const u8, bytes: []const u8) []const u8 {
    const p = std.fmt.allocPrint(arena, "{s}/{s}", .{ runs, name }) catch fail("oom");
    atomicwrite.writeFile(p, bytes, 0o600) catch fail("write an input file");
    return p;
}

/// Poll `m`'s peer_list until `address` shows `state`.
fn awaitState(m: *Mcp, arena: std.mem.Allocator, address: []const u8, state: []const u8, comptime what: []const u8) std.json.ObjectMap {
    const deadline = nowMs() + 10_000;
    while (nowMs() < deadline) {
        if (listed(m, arena, address, what)) |p| {
            if (std.mem.eql(u8, str(p, "state", what), state)) return p;
        }
        _ = c.usleep(50_000);
    }
    fail(what ++ ": the peer never showed the state its hook reported");
}

/// A hook or status line run printed nothing and exited 0.
fn expectSilentOk(r: TreeRun, comptime what: []const u8) void {
    if (r.out.len != 0) fail(what ++ ": printed on stdout");
    if (!std.mem.eql(u8, r.rc, "0")) fail(what ++ ": did not exit 0");
}

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
    // alice's parent shell stands in for her Claude Code: the hook and
    // status line runs of section h are processes of its tree.
    const runs = std.fmt.allocPrintSentinel(arena, "{s}/runs", .{std.mem.sliceTo(&root_buf, 0)}, 0) catch fail("oom");
    mkdirOrFail(runs);
    var alice = stage.serverWithTree("alice", runs.ptr);
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

    // -- h. presence from the session's own hooks and status line --
    const hook_in = struct {
        const prompt = "{\"session_id\":\"s\",\"cwd\":\"/w\",\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"hi\"}";
        const permission = "{\"session_id\":\"s\",\"cwd\":\"/w\",\"hook_event_name\":\"Notification\",\"message\":\"Claude needs your permission to use Bash\",\"notification_type\":\"permission_prompt\"}";
        const stop = "{\"session_id\":\"s\",\"cwd\":\"/w\",\"hook_event_name\":\"Stop\",\"stop_hook_active\":false}";
    };
    const prompt_in = inputFile(arena, runs, "prompt.json", hook_in.prompt);
    const permission_in = inputFile(arena, runs, "permission.json", hook_in.permission);
    const stop_in = inputFile(arena, runs, "stop.json", hook_in.stop);
    const status_in = inputFile(arena, runs, "status.json", facts.CLAUDE_SAMPLE);
    // 21. UserPromptSubmit in alice's client tree: bob2 sees her working;
    //     the hook printed nothing and exited 0.
    expectSilentOk(runInTree(arena, runs, exe, std.fmt.allocPrint(arena, "'{{exe}}' mcp hook < '{s}'", .{prompt_in}) catch fail("oom"), "21. hook"), "21. hook");
    expectStr(awaitState(&bob2, arena, "alice", "working", "21. alice working"), "attention", "working", "21. attention");
    // 22. A permission prompt: waiting on her user, attention needs_input,
    //     the notification type recorded.
    expectSilentOk(runInTree(arena, runs, exe, std.fmt.allocPrint(arena, "'{{exe}}' mcp hook < '{s}'", .{permission_in}) catch fail("oom"), "22. hook"), "22. hook");
    {
        const p = awaitState(&bob2, arena, "alice", "waiting_user", "22. alice waiting");
        expectStr(p, "attention", "needs_input", "22. attention");
        expectStr(p, "last_notification", "permission_prompt", "22. last_notification");
    }
    // 23. Stop: idle again.
    expectSilentOk(runInTree(arena, runs, exe, std.fmt.allocPrint(arena, "'{{exe}}' mcp hook < '{s}'", .{stop_in}) catch fail("oom"), "23. hook"), "23. hook");
    _ = awaitState(&bob2, arena, "alice", "idle", "23. alice idle");
    // 24. The status line: the user's command's output byte for byte, and
    //     alice's context use and model in bob2's list; her capabilities
    //     report presence.
    {
        const r = runInTree(arena, runs, exe, std.fmt.allocPrint(arena, "'{{exe}}' mcp statusline --user-command \"printf 'ctx|'\" < '{s}'", .{status_in}) catch fail("oom"), "24. statusline");
        if (!std.mem.eql(u8, r.out, "ctx|")) fail("24. the user command's output was not passed through byte for byte");
        const deadline = nowMs() + 10_000;
        while (true) {
            const p = listed(&bob2, arena, "alice", "24.") orelse fail("24. alice not listed");
            if (p.get("facts")) |f| {
                const pct = f.object.get("context_used_percent") orelse fail("24. no context_used_percent");
                if (pct != .integer or pct.integer != 14) fail("24. context_used_percent is not the document's 14");
                expectStr(p, "model", "Haiku 4.5", "24. model");
                break;
            }
            if (nowMs() > deadline) fail("24. alice's facts never reached peer_list");
            _ = c.usleep(50_000);
        }
        if (!boolOf(registered(&alice, arena, "24. alice caps"), "presence", "24.")) fail("24. capabilities.peers.presence is false after a presence post");
    }
    // 25. The forwarder as its own user command stops at once (no loop);
    //     with no user command anywhere (an empty home) it prints nothing.
    expectSilentOk(runInTree(arena, runs, exe, std.fmt.allocPrint(arena, "'{{exe}}' mcp statusline --user-command \"'{{exe}}' mcp statusline\" < '{s}'", .{status_in}) catch fail("oom"), "25. recursion"), "25. recursion");
    expectSilentOk(runInTree(arena, runs, exe, std.fmt.allocPrint(arena, "env -u CLAUDE_CONFIG_DIR HOME='{s}' '{{exe}}' mcp statusline < '{s}'", .{ runs, status_in }) catch fail("oom"), "25. no user command"), "25. no user command");
    // 26. A hook with no server of its own (--parent 1) or with garbage on
    //     stdin still prints nothing and exits 0; alice stays idle.
    expectSilentOk(runInTree(arena, runs, exe, std.fmt.allocPrint(arena, "'{{exe}}' mcp hook --parent 1 < '{s}'", .{prompt_in}) catch fail("oom"), "26. no server"), "26. no server");
    expectSilentOk(runInTree(arena, runs, exe, "echo garbage | '{exe}' mcp hook", "26. garbage"), "26. garbage");
    expectStr(listed(&bob2, arena, "alice", "26.") orelse fail("26. alice not listed"), "state", "idle", "26. alice still idle");
    // 27. Her messages now carry her state.
    expectStr(send(&alice, arena, "bob", "with presence", "27. send"), "outcome", "delivered", "27. outcome");
    contains(str(readOne(&bob2, arena, 5_000, "27. bob2 peer_read"), "content", "27."), ", idle). id m-", "27. the sender's state in the composed line");
    std.debug.print("smoke: peers: hook and status line presence ok\n", .{});

    // -- i. a non-MCP peer: sketerm peer --
    // 28. `peer read --follow --json --name webapp` as a child: once it is
    //     listed, alice's message arrives on its stdout as one JSON line.
    {
        var follower = Mcp.spawnWith(allocator, exe, .{
            .extra = &.{ "peer", "read", "--follow", "--json", "--name", "webapp" },
            .unset_env = &UNSET,
            .set_env = stage.env(null),
        });
        {
            const deadline = nowMs() + 10_000;
            while (true) {
                if (listed(&alice, arena, "webapp", "28.")) |p| if (boolOf(p, "live", "28.")) break;
                if (nowMs() > deadline) fail("28. the follower never registered webapp");
                _ = c.usleep(50_000);
            }
        }
        expectStr(send(&alice, arena, "webapp", "hello web app", "28. send"), "outcome", "delivered", "28. outcome");
        const line = follower.recvLineOrNull(10_000) orelse fail("28. the follower printed nothing");
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, arena.dupe(u8, line) catch fail("oom"), .{}) catch fail("28. the follower's line is not JSON");
        expectStr(v.object, "kind", "message", "28. kind");
        expectStr(v.object, "from", "alice", "28. from");
        expectStr(v.object, "text", "hello web app", "28. text");
        expectStr(v.object, "sender_state", "idle", "28. sender_state");
        if (boolOf(v.object, "queued", "28.")) fail("28. a live delivery reads as queued");
        // 29. Killed (its exact pid): webapp goes offline, mail queues.
        follower.terminate();
    }
    awaitOffline(&alice, arena, "webapp", false, "29. webapp offline");
    expectStr(send(&alice, arena, "webapp", "while you were down", "29. send"), "outcome", "queued", "29. outcome");
    // 30. A one-shot `peer read` returns it, queued.
    {
        var reader = Mcp.spawnWith(allocator, exe, .{ .extra = &.{ "peer", "read", "--json", "--name", "webapp" }, .unset_env = &UNSET, .set_env = stage.env(null) });
        const line = reader.recvLineOrNull(10_000) orelse fail("30. peer read printed nothing");
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, arena.dupe(u8, line) catch fail("oom"), .{}) catch fail("30. not JSON");
        expectStr(v.object, "text", "while you were down", "30. text");
        if (!boolOf(v.object, "queued", "30.")) fail("30. queued mail is not marked queued");
        reader.closeStdinWait();
    }
    // 31. `peer send --name webapp --json` to alice: delivered, and alice
    //     reads it from webapp, app cli.
    {
        var sender = Mcp.spawnWith(allocator, exe, .{ .extra = &.{ "peer", "send", "--json", "--name", "webapp", "alice", "reply from the web app" }, .unset_env = &UNSET, .set_env = stage.env(null) });
        const line = sender.recvLineOrNull(10_000) orelse fail("31. peer send printed nothing");
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, arena.dupe(u8, line) catch fail("oom"), .{}) catch fail("31. not JSON");
        expectStr(v.object, "outcome", "delivered", "31. outcome");
        sender.closeStdinWait();
        const it = readOne(&alice, arena, 5_000, "31. alice peer_read");
        expectStr(it, "from", "webapp", "31. from");
        expectStr(it, "text", "reply from the web app", "31. text");
        contains(str(it, "content", "31."), "Peer message from webapp (cli", "31. app cli");
    }
    std.debug.print("smoke: peers: sketerm peer follow, read and send ok\n", .{});

    dave.closeStdinWait();
    bob2.closeStdinWait();
    alice.closeStdinWait();
    std.debug.print("smoke: peers stage ok ({d} ms)\n", .{nowMs() - started});
}

// ── federation ───────────────────────────────────────────────────

/// The federation daemons' mail TTL: past one link cut and redial, short
/// enough to wait out.
const FED_TTL_MS: i64 = 8_000;
const FED_TTL_TEXT = "8000";
/// The hub's name for the member host.
const FED_DOMAIN = "fedbox";

/// One isolated daemon's directories.
const FedHost = struct {
    rt: [:0]const u8,
    st: [:0]const u8,
    cfg: [:0]const u8,

    fn make(arena: std.mem.Allocator, root: []const u8, name: []const u8) FedHost {
        const base = std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ root, name }, 0) catch fail("oom");
        mkdirOrFail(base);
        const h = FedHost{
            .rt = std.fmt.allocPrintSentinel(arena, "{s}/rt", .{base}, 0) catch fail("oom"),
            .st = std.fmt.allocPrintSentinel(arena, "{s}/st", .{base}, 0) catch fail("oom"),
            .cfg = std.fmt.allocPrintSentinel(arena, "{s}/cfg", .{base}, 0) catch fail("oom"),
        };
        mkdirOrFail(h.rt);
        mkdirOrFail(h.st);
        mkdirOrFail(h.cfg);
        mkdirOrFail(std.fmt.allocPrintSentinel(arena, "{s}/sketerm", .{h.cfg}, 0) catch fail("oom"));
        return h;
    }

    fn env(self: *const FedHost, arena: std.mem.Allocator, name: [*:0]const u8) []const [2][*:0]const u8 {
        const out = arena.alloc([2][*:0]const u8, 4) catch fail("oom");
        out[0] = .{ "XDG_RUNTIME_DIR", self.rt.ptr };
        out[1] = .{ "XDG_STATE_HOME", self.st.ptr };
        out[2] = .{ "XDG_CONFIG_HOME", self.cfg.ptr };
        out[3] = .{ "SKETERM_PEER_NAME", name };
        return out;
    }

    fn server(self: *const FedHost, allocator: std.mem.Allocator, arena: std.mem.Allocator, exe: [*:0]const u8, name: [*:0]const u8) Mcp {
        return Mcp.spawnWith(allocator, exe, .{ .extra = &.{"--no-record"}, .unset_env = &UNSET, .set_env = self.env(arena, name) });
    }
};

/// Exec `mux_bin --broker` under `h`'s directories (and `ssh`, the fake
/// ssh, when set); wait for its socket. @return its pid.
fn startFedDaemon(arena: std.mem.Allocator, h: *const FedHost, mux_bin: [*:0]const u8, ssh: ?[*:0]const u8) c.pid_t {
    const sock = std.fmt.allocPrintSentinel(arena, "{s}/sketerm/mux.sock", .{h.rt}, 0) catch fail("oom");
    const pid = c.fork();
    if (pid < 0) fail("fork a federation daemon");
    if (pid == 0) {
        for (UNSET) |k| _ = envutil.unset(k);
        _ = c.setenv("XDG_RUNTIME_DIR", h.rt.ptr, 1);
        _ = c.setenv("XDG_STATE_HOME", h.st.ptr, 1);
        _ = c.setenv("XDG_CONFIG_HOME", h.cfg.ptr, 1);
        _ = c.setenv(daemon_peers.TTL_ENV, FED_TTL_TEXT, 1);
        if (ssh) |s| _ = c.setenv("SKETERM_SSH", s, 1) else _ = envutil.unset("SKETERM_SSH");
        const argv = [_:null]?[*:0]const u8{ "sketerm-mux", "--broker", null };
        _ = c.execv(mux_bin, @ptrCast(@constCast(&argv)));
        c._exit(127);
    }
    const deadline = nowMs() + 10_000;
    while (c.access(sock.ptr, c.F_OK) != 0) {
        if (nowMs() > deadline) fail("a federation daemon's socket never appeared");
        _ = c.usleep(50_000);
    }
    return pid;
}

/// SIGTERM the daemon `pid` this stage started, reap it (SIGKILL after 10 s).
fn stopFedDaemon(pid: c.pid_t) void {
    _ = c.kill(pid, c.SIGTERM);
    const deadline = nowMs() + 10_000;
    var st: c_int = 0;
    while (nowMs() < deadline) {
        if (c.waitpid(pid, &st, c.WNOHANG) == pid) return;
        _ = c.usleep(50_000);
    }
    _ = c.kill(pid, c.SIGKILL);
    _ = c.waitpid(pid, &st, 0);
}

fn writeFileOrFail(path: [:0]const u8, body: []const u8, mode: c_uint) void {
    atomicwrite.writeFile(path, body, 0o600) catch fail("write a federation file");
    if (c.chmod(path.ptr, mode) != 0) fail("chmod a federation file");
}

/// Poll `m`'s peer_list until `address` is listed with `link` (null: any).
fn awaitListed(m: *Mcp, arena: std.mem.Allocator, address: []const u8, link: ?[]const u8, budget_ms: i64, comptime what: []const u8) std.json.ObjectMap {
    const deadline = nowMs() + budget_ms;
    while (nowMs() < deadline) {
        if (listed(m, arena, address, what)) |p| {
            const l = if (p.get("link")) |v| v.string else "";
            if (link == null or std.mem.eql(u8, l, link.?)) return p;
        }
        _ = c.usleep(200_000);
    }
    std.debug.print("{s}: {s} never listed (link {s})\n", .{ what, address, link orelse "any" });
    fail(what ++ ": the federated peer never showed as expected");
}

/// Federation end to end: a hub daemon (`peer_hub`, `[domain.fedbox]
/// peers = true`) dials a member daemon through a fake ssh that execs the
/// real `sketerm-mux --proxy`; one MCP server on each side (plus a durable
/// member name that left) exercise presence, mail both ways with reply
/// routing, a cut link with mail queued in between, far refusals and TTL
/// expiry across the link, then the member's trust rule on its socket.
pub fn runFederation(allocator: std.mem.Allocator, exe: [*:0]const u8) void {
    if (!prepared) fail("prepare() must run before the federation stage");
    const started = nowMs();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const mux_bin: [*:0]const u8 = c.getenv("SKETERM_MUX_BIN") orelse fail("the rig must export SKETERM_MUX_BIN (the built sketerm-mux)");
    const root = std.mem.sliceTo(&root_buf, 0);
    const hub = FedHost.make(arena, root, "fh");
    const mem = FedHost.make(arena, root, "fm");
    var host_buf: [256]u8 = undefined;
    if (c.gethostname(&host_buf, host_buf.len) != 0) fail("gethostname");
    const hub_host = std.mem.sliceTo(&host_buf, 0);
    if (std.mem.eql(u8, hub_host, FED_DOMAIN)) fail("this machine is called " ++ FED_DOMAIN ++ ", the stage's member domain");

    // The fake ssh: refuses while `link-down` exists, else records its pid
    // and becomes the member host's `sketerm-mux --proxy`.
    const down = std.fmt.allocPrintSentinel(arena, "{s}/link-down", .{root}, 0) catch fail("oom");
    const pid_file = std.fmt.allocPrint(arena, "{s}/link.pid", .{root}) catch fail("oom");
    const ssh = std.fmt.allocPrintSentinel(arena, "{s}/fake-fed-ssh", .{root}, 0) catch fail("oom");
    writeFileOrFail(ssh, std.fmt.allocPrint(arena,
        \\#!/bin/sh
        \\if [ "$1" = "-G" ]; then printf 'hostname 127.0.0.1\n'; exit 0; fi
        \\[ -e '{s}' ] && exit 255
        \\echo $$ > '{s}.tmp' && mv '{s}.tmp' '{s}'
        \\export XDG_RUNTIME_DIR='{s}' XDG_STATE_HOME='{s}' XDG_CONFIG_HOME='{s}'
        \\exec '{s}' --proxy
        \\
    , .{ down, pid_file, pid_file, pid_file, mem.rt, mem.st, mem.cfg, std.mem.span(mux_bin) }) catch fail("oom"), 0o700);
    writeFileOrFail(std.fmt.allocPrintSentinel(arena, "{s}/sketerm/config.conf", .{hub.cfg}, 0) catch fail("oom"),
        "peer_hub = true\n\n[domain." ++ FED_DOMAIN ++ "]\nhost = " ++ FED_DOMAIN ++ "\ntransport = ssh\npeers = true\n", 0o600);

    const mem_pid = startFedDaemon(arena, &mem, mux_bin, null);
    const hub_pid = startFedDaemon(arena, &hub, mux_bin, ssh.ptr);
    const zed_on_mem = std.fmt.allocPrint(arena, "{s}/zed", .{hub_host}) catch fail("oom");
    const mia_on_hub = FED_DOMAIN ++ "/mia";

    // 1. mike registers on the member and leaves: a durable name there.
    {
        var mike = mem.server(allocator, arena, exe, "mike");
        mike.initialize();
        expectStr(registered(&mike, arena, "f1. mike"), "address", "mike", "f1. mike's address");
        mike.closeStdinWait();
    }
    var zed = hub.server(allocator, arena, exe, "zed");
    zed.initialize();
    var mia = mem.server(allocator, arena, exe, "mia");
    mia.initialize();
    // 2. Each side's capabilities name its part; each lists the other's
    //    peer under its host, via that host, link up.
    expectStr(registered(&zed, arena, "f2. zed"), "federation", "hub", "f2. zed federation");
    _ = registered(&mia, arena, "f2. mia");
    {
        const p = awaitListed(&zed, arena, mia_on_hub, "up", 60_000, "f2. zed lists mia");
        expectStr(p, "via_host", FED_DOMAIN, "f2. via_host on the hub");
        const q = awaitListed(&mia, arena, zed_on_mem, "up", 20_000, "f2. mia lists zed");
        expectStr(q, "via_host", hub_host, "f2. via_host on the member");
        const caps = call(&mia, arena, "capabilities", "{}", "f2. mia capabilities");
        expectStr((caps.get("peers") orelse fail("f2. no peers")).object, "federation", "member", "f2. mia federation");
    }
    std.debug.print("smoke: peers: federation presence on both sides ok\n", .{});

    // 3. mia -> zed: delivered; zed reads it from fedbox/mia and replies to
    //    that address; mia reads the reply from <hub>/zed.
    {
        expectStr(send(&mia, arena, zed_on_mem, "ping across", "f3. send"), "outcome", "delivered", "f3. outcome");
        const it = readOne(&zed, arena, 10_000, "f3. zed peer_read");
        expectStr(it, "from", mia_on_hub, "f3. from");
        expectStr(it, "text", "ping across", "f3. text");
        contains(str(it, "content", "f3."), "Reply with peer_send to \"" ++ mia_on_hub ++ "\"", "f3. reply hint");
        const args = std.fmt.allocPrint(arena, "{{\"to\":\"{s}\",\"text\":\"pong back\",\"reply_to\":\"{s}\"}}", .{ mia_on_hub, str(it, "id", "f3.") }) catch fail("oom");
        expectStr(call(&zed, arena, "peer_send", args, "f3. reply"), "outcome", "delivered", "f3. reply outcome");
        const back = readOne(&mia, arena, 10_000, "f3. mia peer_read");
        expectStr(back, "from", zed_on_mem, "f3. reply from");
        expectStr(back, "reply_to", str(it, "id", "f3."), "f3. reply_to");
    }
    std.debug.print("smoke: peers: federation mail both ways with reply routing ok\n", .{});

    // 4. The link is cut (the fake ssh's proxy, by its exact pid) and kept
    //    down: mia stays listed with link down; a send is queued
    //    host_unreachable; restored, it arrives once.
    {
        writeFileOrFail(down, "", 0o600);
        const pid_text = readfile.capped(arena, pid_file, 64) orelse fail("f4. the fake ssh left no pid");
        const link_pid = std.fmt.parseInt(c.pid_t, std.mem.trim(u8, pid_text, " \n"), 10) catch fail("f4. the fake ssh pid is not a number");
        if (c.kill(link_pid, c.SIGTERM) != 0) fail("f4. could not stop the link's proxy");
        _ = awaitListed(&zed, arena, mia_on_hub, "down", 20_000, "f4. zed lists mia down");
        const r = send(&zed, arena, mia_on_hub, "sent while the link was down", "f4. send");
        expectStr(r, "outcome", "queued", "f4. outcome");
        expectStr(r, "reason", "host_unreachable", "f4. reason");
        if (c.unlink(down.ptr) != 0) fail("f4. could not restore the link");
        const it = readOne(&mia, arena, 90_000, "f4. mia peer_read after the link is back");
        expectStr(it, "text", "sent while the link was down", "f4. text");
        expectStr(it, "from", zed_on_mem, "f4. from");
        if (it.get("age_s") == null) fail("f4. the delivery has no age");
        expectNothing(&mia, arena, "f4. delivered once");
        _ = awaitListed(&zed, arena, mia_on_hub, "up", 20_000, "f4. zed lists mia up again");
    }
    std.debug.print("smoke: peers: federation link cut, queued, restored, delivered once ok\n", .{});

    // 5. A name the member does not know: the far broker's refusal comes
    //    back as the answer, both ways; an unknown host is refused on the hub.
    expectRefused(&zed, arena, FED_DOMAIN ++ "/Nobody", "?", "unknown_address", "f5. unknown far name");
    expectRefused(&mia, arena, "nohost/x", "?", "unknown_address", "f5. unknown host via the hub");
    expectRefused(&zed, arena, "nohost/x", "?", "unknown_address", "f5. unknown host on the hub");

    // 6. zed -> fedbox/mike (away): queued over there; past the TTL the
    //    expiry event crosses back to zed.
    {
        const r = send(&zed, arena, FED_DOMAIN ++ "/mike", "you will not read this", "f6. send");
        expectStr(r, "outcome", "queued", "f6. outcome");
        const sent_at = nowMs();
        const ev = readOne(&zed, arena, FED_TTL_MS + daemon_peers.SWEEP_EVERY_MS + 10_000, "f6. zed's expiry event");
        if (nowMs() - sent_at < FED_TTL_MS - 500) fail("f6. the expiry came before the TTL");
        expectStr(ev, "outcome", "expired", "f6. event outcome");
        expectStr(ev, "to", FED_DOMAIN ++ "/mike", "f6. event to");
    }
    std.debug.print("smoke: peers: federation TTL expiry reaches the sender across the link ok\n", .{});

    // 7. The member trusts its private socket, not the far process: a
    //    relay on a plain local connection without hello is refused; a
    //    plain local connection that says hello is a link, and its mail
    //    is stored and delivered.
    {
        const sock = std.fmt.allocPrint(arena, "{s}/sketerm/mux.sock", .{mem.rt}) catch fail("oom");
        var bare = muxclient.Conn.connectProbed(allocator, sock) catch fail("f7. connect to the member");
        defer bare.deinit();
        bare.sendJson(.peer_hub_relay, peermail.Relay{ .kind = .mail, .id = "m-f7nohelo", .from = .{ .address = "lochub/lena" }, .to = "mia", .text = "relayed without hello" }) catch fail("f7. send a relay without hello");
        const refusal = bare.recvExpectFor(&.{.err}, 10_000) catch fail("f7. a relay without hello was not refused");
        defer refusal.deinit(allocator);
        contains(refusal.payload, "before peer_hub_hello", "f7. the refusal names the missing hello");

        var link = muxclient.Conn.connectProbed(allocator, sock) catch fail("f7. connect to the member again");
        defer link.deinit();
        link.sendJson(.peer_hub_hello, peermail.HubHello{ .host = "lochub", .as = FED_DOMAIN }) catch fail("f7. send hello");
        link.sendJson(.peer_hub_relay, peermail.Relay{ .kind = .mail, .id = "m-f7hello1", .from = .{ .address = "lochub/lena" }, .to = "mia", .text = "relayed after a local hello" }) catch fail("f7. send a relay after hello");
        const deadline = nowMs() + 10_000;
        while (true) {
            if (nowMs() > deadline) fail("f7. the member never answered stored on the local link");
            const f = link.recvExpectFor(&.{.peer_member_relay}, deadline - nowMs()) catch fail("f7. the member refused the local link or its relay");
            defer f.deinit(allocator);
            if (std.mem.indexOf(u8, f.payload, "\"stored\"") != null and std.mem.indexOf(u8, f.payload, "m-f7hello1") != null) break;
        }
        const it = readOne(&mia, arena, 10_000, "f7. mia reads the locally relayed mail");
        expectStr(it, "from", "lochub/lena", "f7. from");
        expectStr(it, "text", "relayed after a local hello", "f7. text");
    }
    std.debug.print("smoke: peers: federation trusts a local hello and refuses a relay without one ok\n", .{});

    mia.closeStdinWait();
    zed.closeStdinWait();
    stopFedDaemon(hub_pid);
    stopFedDaemon(mem_pid);
    std.debug.print("smoke: peers federation stage ok ({d} ms)\n", .{nowMs() - started});
}
