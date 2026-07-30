//! UDP connection-ticket brokering stage, run against a monolith
//! (smoke-mux) AND a real broker (smoke-broker). The broker run is
//! load-bearing: an ATTACHED client's frames are served by the
//! WORKER, whose Daemon has an empty `sock_path` and must mint
//! through `broker_sock` — monolith-only coverage would miss exactly
//! that hop (the native-backlog lesson). Requires $SKETERM_MUX_BIN:
//! the daemon spawns the ticket listener and the client spawns the
//! --udp-connect bridge from it (both rigs host the Daemon inside a
//! smoke binary that answers neither).

const std = @import("std");
const c = @import("c.zig").c;
const client_mod = @import("mux/client.zig");
const wire = @import("mux/wire.zig");

fn fail(msg: []const u8) noreturn {
    std.debug.print("smoke-ticket: FAIL: {s}\n", .{msg});
    std.process.exit(1);
}

/// Dial the brokered listener over loopback UDP — no ssh bootstrap
/// exists in this rig at all, so a working connection IS the proof —
/// and run one list round trip over the sealed channel.
fn dialTicket(allocator: std.mem.Allocator, ticket: client_mod.UdpTicket, label: []const u8) void {
    var conn = client_mod.Conn.connectUdpTicket(allocator, "127.0.0.1", ticket) catch
        fail("ticket connect (is UDP loopback blocked?)");
    defer conn.deinit();
    if (conn.transport != .udp) fail("ticket transport is not udp");
    conn.sendFrame(.list, "") catch fail("ticket list send");
    (conn.recvExpectFor(&.{.welcome}, 10_000) catch fail("ticket list reply")).deinit(allocator);
    std.debug.print("smoke-ticket: {s} ok\n", .{label});
}

pub fn run(allocator: std.mem.Allocator, sock_path: []const u8) void {
    if (c.getenv("SKETERM_MUX_BIN") == null)
        fail("SKETERM_MUX_BIN not set (the rig must pass the built sketerm-mux)");

    // 1. Unattached client — served by the BROKER in broker mode
    //    (non-empty sock_path branch).
    var conn = client_mod.Conn.connectProbed(allocator, sock_path) catch fail("connect");
    defer conn.deinit();
    if (!conn.udp_tickets) fail("welcome does not advertise udp_ticket");
    const t1 = conn.requestUdpTicket(null, 15_000) catch fail("unattached mint");
    dialTicket(allocator, t1, "unattached (broker-served) ticket");

    // A pinned range must be honored (and a bad one refused).
    const t2 = conn.requestUdpTicket("61300:61399", 15_000) catch fail("ranged mint");
    if (t2.port < 61300 or t2.port > 61399) fail("ranged mint ignored the range");
    conn.sendJson(.udp_ticket_req, .{ .range = "junk" }) catch fail("bad-range send");
    const bad = conn.recvExpectFor(&.{.udp_ticket}, 10_000) catch fail("bad-range reply");
    defer bad.deinit(allocator);
    if (client_mod.parseUdpTicketReply(allocator, bad.payload) != null) fail("bad range not refused");

    // 2. Attached client — served by the WORKER in broker mode, which
    //    must mint through `broker_sock`.
    var att = client_mod.Conn.connectProbed(allocator, sock_path) catch fail("attach connect");
    defer att.deinit();
    att.sendJson(.spawn, .{
        .name = "ticket-stage",
        .argv = [_][]const u8{"cat"},
        .rows = @as(u16, 24),
        .cols = @as(u16, 80),
    }) catch fail("spawn send");
    (att.recvExpect(&.{.ok}) catch fail("spawn ok")).deinit(allocator);
    att.sendJson(.attach, .{ .name = "ticket-stage" }) catch fail("attach send");
    (att.recvExpect(&.{.snapshot}) catch fail("attach snapshot")).deinit(allocator);
    const t3 = att.requestUdpTicket(null, 15_000) catch fail("attached mint");
    dialTicket(allocator, t3, "attached (worker-served) ticket");

    att.sendJson(.kill, .{ .name = "ticket-stage" }) catch fail("kill send");
    (att.recvExpect(&.{ .ok, .gone }) catch fail("kill ok")).deinit(allocator);
}
