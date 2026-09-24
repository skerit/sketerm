//! Idle-upgrade race stage, shared by smoke-mux and smoke-broker.
//!
//! An upgrading client used to probe `.list` + `job_list` and then send
//! the unconditional `.shutdown`, so a session spawned between the probe
//! and the shutdown died with the daemon. `quit_idle` decides in one
//! frame dispatch: this stage re-enacts the old probe, spawns a session
//! in the window, and proves the request is refused while that session
//! lives on. Runs with no other session present; the positive path
//! (retire when idle) is unit-tested daemon- and client-side.

const std = @import("std");
const c = @import("c.zig").c;
const client_mod = @import("mux/client.zig");
const wire = @import("mux/wire.zig");

fn fail(comptime msg: []const u8) noreturn {
    std.debug.print("smoke quit-idle stage: FAIL: " ++ msg ++ "\n", .{});
    std.process.exit(1);
}

const SESSION = "late-spawn";

fn connect(allocator: std.mem.Allocator, sock_path: []const u8) client_mod.Conn {
    var conn = client_mod.Conn.connect(allocator, sock_path) catch fail("connect");
    conn = client_mod.Conn.probe(allocator, conn) catch fail("probe");
    return conn;
}

const Listing = struct {
    sessions: []struct { name: []const u8 = "" } = &.{},
};

/// Number of listed sessions, and whether `name` is among them.
fn listing(allocator: std.mem.Allocator, conn: *client_mod.Conn, name: []const u8) struct { count: usize, has: bool } {
    conn.sendFrame(.list, "") catch fail("list send");
    const f = conn.recvExpectFor(&.{.welcome}, 10_000) catch fail("list reply");
    defer f.deinit(allocator);
    const parsed = std.json.parseFromSlice(Listing, allocator, f.payload, .{ .ignore_unknown_fields = true }) catch fail("list parse");
    defer parsed.deinit();
    var has = false;
    for (parsed.value.sessions) |s| {
        if (std.mem.eql(u8, s.name, name)) has = true;
    }
    return .{ .count = parsed.value.sessions.len, .has = has };
}

fn listed(allocator: std.mem.Allocator, conn: *client_mod.Conn, name: []const u8) bool {
    return listing(allocator, conn, name).has;
}

pub fn run(allocator: std.mem.Allocator, sock_path: []const u8) void {
    var upgrader = connect(allocator, sock_path);
    defer upgrader.deinit();
    if (!upgrader.caps.quit_idle) {
        // Only a daemon from before the flag lacks it (a rig pointed at
        // an old binary through SKETERM_SMOKE_BROKER_BIN): prove the
        // kept fallback instead, which must not bounce a busy daemon.
        return oldDaemonFallback(allocator, sock_path, &upgrader);
    }

    // The old client's first probe: nothing held. The rigs run this
    // stage once their earlier sessions are gone; a broker lists a
    // killed worker until it has reaped it, so wait for that, bounded.
    var settle: usize = 0;
    while (settle < 200 and listing(allocator, &upgrader, SESSION).count != 0) : (settle += 1) _ = c.usleep(20_000);
    if (listing(allocator, &upgrader, SESSION).count != 0) fail("stage precondition: the daemon still holds sessions");

    // Somebody else starts a session inside the upgrade window.
    var spawner = connect(allocator, sock_path);
    defer spawner.deinit();
    spawner.sendJson(.spawn, .{
        .name = SESSION,
        .argv = [_][]const u8{ "sleep", "30" },
        .rows = @as(u16, 24),
        .cols = @as(u16, 80),
    }) catch fail("spawn send");
    (spawner.recvExpectFor(&.{.ok}, 10_000) catch fail("spawn ok")).deinit(allocator);

    // The upgrader's decision is taken against the daemon's state NOW,
    // not against its stale probe: refused, session intact, daemon up.
    upgrader.sendJson(.quit_idle, .{}) catch fail("quit_idle send");
    {
        const f = upgrader.recvExpectFor(&.{.ok}, 10_000) catch fail("quit_idle reply");
        defer f.deinit(allocator);
        const Reply = struct { ok: bool = true, @"error": []const u8 = "" };
        const parsed = std.json.parseFromSlice(Reply, allocator, f.payload, .{ .ignore_unknown_fields = true }) catch fail("quit_idle parse");
        defer parsed.deinit();
        if (parsed.value.ok) fail("quit_idle retired a daemon that had just spawned a session");
        if (std.mem.indexOf(u8, parsed.value.@"error", "session") == null) fail("refusal does not name the session it protects");
    }
    if (!listed(allocator, &spawner, SESSION)) fail("the late session did not survive the refused upgrade");

    // The same path through the client helper: the connection stays
    // usable and reports "not upgraded".
    if (upgrader.buildStale()) {
        if (upgrader.upgradeStaleIdle(allocator)) fail("upgradeStaleIdle bounced a busy daemon");
    }

    spawner.sendJson(.kill, .{ .name = SESSION }) catch fail("kill send");
    (spawner.recvExpectFor(&.{.ok}, 10_000) catch fail("kill ok")).deinit(allocator);
    var tries: usize = 0;
    while (tries < 200 and listed(allocator, &spawner, SESSION)) : (tries += 1) _ = c.usleep(20_000);
    if (listed(allocator, &spawner, SESSION)) fail("killed session still listed");
    std.debug.print("smoke: quit_idle refuses a session spawned in the upgrade window ok\n", .{});
}

/// Against a daemon without `quit_idle`: the client's probe-then-shutdown
/// fallback sees a held session and leaves the daemon (and the session)
/// alone. Its racy window is exactly what `quit_idle` closes; the
/// fallback only has to be as safe as it ever was.
fn oldDaemonFallback(allocator: std.mem.Allocator, sock_path: []const u8, upgrader: *client_mod.Conn) void {
    if (!upgrader.buildStale()) fail("an old daemon must read as a stale build");
    var spawner = connect(allocator, sock_path);
    defer spawner.deinit();
    spawner.sendJson(.spawn, .{
        .name = SESSION,
        .argv = [_][]const u8{ "sleep", "30" },
        .rows = @as(u16, 24),
        .cols = @as(u16, 80),
    }) catch fail("spawn send");
    (spawner.recvExpectFor(&.{.ok}, 10_000) catch fail("spawn ok")).deinit(allocator);
    if (upgrader.upgradeStaleIdle(allocator)) fail("the probe fallback bounced a busy old daemon");
    if (!listed(allocator, &spawner, SESSION)) fail("the session did not survive the refused fallback upgrade");
    spawner.sendJson(.kill, .{ .name = SESSION }) catch fail("kill send");
    (spawner.recvExpectFor(&.{.ok}, 10_000) catch fail("kill ok")).deinit(allocator);
    var tries: usize = 0;
    while (tries < 200 and listed(allocator, &spawner, SESSION)) : (tries += 1) _ = c.usleep(20_000);
    if (listed(allocator, &spawner, SESSION)) fail("killed session still listed");
    std.debug.print("smoke: old daemon without quit_idle: probe fallback leaves a busy daemon up ok\n", .{});
}
