//! Focused state-machine tests for correlated panel routing.

const std = @import("std");
const dmod = @import("daemon.zig");
const daemon_serve = @import("daemon_serve.zig");
const wire = @import("wire.zig");

const Client = dmod.Client;
const Daemon = dmod.Daemon;
const Session = dmod.Session;

fn clearClient(cl: *Client, allocator: std.mem.Allocator) void {
    cl.rbuf.deinit(allocator);
    cl.wbuf.deinit(allocator);
    cl.audio_wbuf.deinit(allocator);
}

fn envelope(allocator: std.mem.Allocator, id: u64, json: []const u8) !std.ArrayList(u8) {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try wire.appendPanelEnvelope(&out, allocator, id, json);
    return out;
}

fn firstEnvelope(cl: *Client, want: wire.FrameType) !wire.PanelEnvelope {
    const peeled = (try wire.peelFrame(cl.wbuf.items)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(want, peeled.frame.ftype);
    return wire.decodePanelEnvelope(peeled.frame.payload);
}

fn panelRequestIds(cl: *Client, out: []u64) ![]u64 {
    var rest = cl.wbuf.items;
    var count: usize = 0;
    while (try wire.peelFrame(rest)) |peeled| {
        if (peeled.frame.ftype == .panel_request) {
            if (count >= out.len) return error.NoSpaceLeft;
            out[count] = (try wire.decodePanelEnvelope(peeled.frame.payload)).id;
            count += 1;
        }
        rest = rest[peeled.consumed..];
    }
    return out[0..count];
}

test "panel relay selects the earliest panel-capable attachment, isolates caller ids, rejects spoofing, and cleans routes" {
    const t = std.testing;
    const a = t.allocator;
    var empty: [0]u8 = .{};
    var daemon = Daemon{ .allocator = a, .listen_fd = -1, .sock_path = empty[0..] };
    defer daemon.clients.deinit(a);
    defer daemon.panel_routes.deinit(a);

    var session: Session = undefined;
    session.exited = false;

    var requester_a = Client{
        .allocator = a,
        .fd = -1,
        .id = 30,
        .attached = &session,
        .kind = .mcp,
        .read_only = true,
        .native_state_max = wire.NATIVE_STATE_VERSION,
        .audio_channels = true,
        .panel_rpc_support = wire.PANEL_RPC_VERSION,
        .panel_rpc = wire.PANEL_RPC_VERSION,
        .panel_only = true,
    };
    defer clearClient(&requester_a, a);
    var requester_b = Client{
        .allocator = a,
        .fd = -1,
        .id = 31,
        .attached = &session,
        .kind = .mcp,
        .read_only = true,
        .native_state_max = wire.NATIVE_STATE_VERSION,
        .audio_channels = true,
        .panel_rpc_support = wire.PANEL_RPC_VERSION,
        .panel_rpc = wire.PANEL_RPC_VERSION,
        .panel_only = true,
    };
    defer clearClient(&requester_b, a);
    var newer_gui = Client{
        .allocator = a,
        .fd = -1,
        .id = 20,
        .attached = &session,
        .kind = .gui,
        .panel_rpc_support = wire.PANEL_RPC_VERSION,
        .panel_rpc = wire.PANEL_RPC_VERSION,
    };
    defer clearClient(&newer_gui, a);
    var older_gui = Client{
        .allocator = a,
        .fd = -1,
        .id = 10,
        .attached = &session,
        .kind = .gui,
        .panel_rpc_support = wire.PANEL_RPC_VERSION,
        .panel_rpc = wire.PANEL_RPC_VERSION,
    };
    defer clearClient(&older_gui, a);

    // List order is deliberately not age order.
    try daemon.clients.append(a, &newer_gui);
    try daemon.clients.append(a, &requester_a);
    try daemon.clients.append(a, &older_gui);
    try daemon.clients.append(a, &requester_b);
    try t.expect(!Daemon.nativeViewer(&requester_a, &session));
    try t.expect(!Daemon.audioViewer(&requester_a, &session));
    try t.expectEqual(@as(u32, 2), daemon.viewerCount(&session));

    var call_a = try envelope(a, 7, "{\"cmd\":\"panel-close\",\"call\":\"a\"}");
    defer call_a.deinit(a);
    var call_b = try envelope(a, 7, "{\"cmd\":\"panel-close\",\"call\":\"b\"}");
    defer call_b.deinit(a);
    daemon.handlePanelRequest(&requester_a, call_a.items);
    daemon.handlePanelRequest(&requester_b, call_b.items);
    try t.expectEqual(@as(usize, 2), daemon.panel_routes.items.len);
    try t.expectEqual(&older_gui, daemon.panel_routes.items[0].presenter);
    try t.expectEqual(&older_gui, daemon.panel_routes.items[1].presenter);
    try t.expect(daemon.panel_routes.items[0].route_id != daemon.panel_routes.items[1].route_id);
    try t.expectEqual(@as(usize, 0), newer_gui.wbuf.items.len);

    const route_a = daemon.panel_routes.items[0].route_id;
    const route_b = daemon.panel_routes.items[1].route_id;
    var spoof = try envelope(a, route_a, "{\"ok\":\"spoof\"}");
    defer spoof.deinit(a);
    daemon.handlePanelReply(&newer_gui, spoof.items);
    try t.expectEqual(@as(usize, 2), daemon.panel_routes.items.len);
    try t.expectEqual(wire.FrameType.err, (try wire.peelFrame(newer_gui.wbuf.items)).?.frame.ftype);

    // Reply in reverse order. Each requester gets its own original id 7.
    var reply_b = try envelope(a, route_b, "{\"ok\":true,\"tag\":\"b\"}");
    defer reply_b.deinit(a);
    daemon.handlePanelReply(&older_gui, reply_b.items);
    try t.expectEqual(@as(u64, 7), (try firstEnvelope(&requester_b, .panel_reply)).id);
    var reply_a = try envelope(a, route_a, "{\"ok\":true,\"tag\":\"a\"}");
    defer reply_a.deinit(a);
    daemon.handlePanelReply(&older_gui, reply_a.items);
    try t.expectEqual(@as(u64, 7), (try firstEnvelope(&requester_a, .panel_reply)).id);
    try t.expectEqual(@as(usize, 0), daemon.panel_routes.items.len);

    // A route still queued behind presenter traffic is definitely
    // pre-delivery. Timeout may be retried and must not claim mutation.
    requester_a.wbuf.clearRetainingCapacity();
    older_gui.wbuf.clearRetainingCapacity();
    daemon.handlePanelRequest(&requester_a, call_a.items);
    daemon.panel_routes.items[0].deadline_ms = 99;
    daemon.panelRoutesTick(99);
    try t.expectEqual(@as(usize, 0), older_gui.wbuf.items.len);
    const unflushed_timeout = try firstEnvelope(&requester_a, .panel_reply);
    try t.expect(std.mem.indexOf(u8, unflushed_timeout.json, "\"failure_class\":\"pre_delivery\"") != null);
    try t.expect(std.mem.indexOf(u8, unflushed_timeout.json, "\"mutation_may_have_applied\":false") != null);
    try t.expect(std.mem.indexOf(u8, unflushed_timeout.json, "\"resend_safe\":true") != null);

    requester_a.wbuf.clearRetainingCapacity();
    older_gui.wbuf.clearRetainingCapacity();
    daemon.handlePanelRequest(&requester_a, call_a.items);
    daemon.panel_routes.items[0].deadline_ms = 100;
    older_gui.normal_bytes_written = daemon.panel_routes.items[0].presenter_stream_start + 1;
    daemon.panelRoutesTick(100);
    try t.expectEqual(@as(usize, 0), daemon.panel_routes.items.len);
    const timed_out = try firstEnvelope(&requester_a, .panel_reply);
    try t.expect(std.mem.indexOf(u8, timed_out.json, "timed out") != null);
    try t.expect(std.mem.indexOf(u8, timed_out.json, "\"failure_class\":\"uncertain_delivery\"") != null);
    try t.expect(std.mem.indexOf(u8, timed_out.json, "\"mutation_may_have_applied\":true") != null);
    try t.expect(std.mem.indexOf(u8, timed_out.json, "\"resend_safe\":false") != null);

    requester_a.wbuf.clearRetainingCapacity();
    older_gui.wbuf.clearRetainingCapacity();
    daemon.handlePanelRequest(&requester_a, call_a.items);
    older_gui.normal_bytes_written = daemon.panel_routes.items[0].presenter_stream_start + 1;
    older_gui.dead = true;
    daemon.panelRoutesTick(0);
    older_gui.dead = false;
    try t.expectEqual(@as(usize, 0), daemon.panel_routes.items.len);
    const disconnected = try firstEnvelope(&requester_a, .panel_reply);
    try t.expect(std.mem.indexOf(u8, disconnected.json, "disconnected") != null);
    try t.expect(std.mem.indexOf(u8, disconnected.json, "\"failure_class\":\"uncertain_delivery\"") != null);
    try t.expect(std.mem.indexOf(u8, disconnected.json, "\"resend_safe\":false") != null);

    requester_a.wbuf.clearRetainingCapacity();
    older_gui.wbuf.clearRetainingCapacity();
    daemon.handlePanelRequest(&requester_a, call_a.items);
    older_gui.normal_bytes_written = daemon.panel_routes.items[0].presenter_stream_start + 1;
    daemon.panelSessionClosed(&session);
    try t.expectEqual(@as(usize, 0), daemon.panel_routes.items.len);
    const session_closed = try firstEnvelope(&requester_a, .panel_reply);
    try t.expect(std.mem.indexOf(u8, session_closed.json, "session closed") != null);
    try t.expect(std.mem.indexOf(u8, session_closed.json, "\"failure_class\":\"uncertain_delivery\"") != null);
    try t.expect(std.mem.indexOf(u8, session_closed.json, "\"mutation_may_have_applied\":true") != null);

    // Once the route id is readable, an invalid presenter envelope resolves
    // the caller immediately with uncertain-delivery wording. It must not sit
    // in the route table until the generic timeout.
    requester_a.wbuf.clearRetainingCapacity();
    older_gui.wbuf.clearRetainingCapacity();
    daemon.handlePanelRequest(&requester_a, call_a.items);
    const malformed_route = daemon.panel_routes.items[0].route_id;
    older_gui.wbuf.clearRetainingCapacity();
    var malformed: [wire.PANEL_ENVELOPE_HEADER]u8 = undefined;
    std.mem.writeInt(u64, &malformed, malformed_route, .little);
    daemon.handlePanelReply(&older_gui, &malformed);
    try t.expectEqual(@as(usize, 0), daemon.panel_routes.items.len);
    const malformed_reply = try firstEnvelope(&requester_a, .panel_reply);
    try t.expect(std.mem.indexOf(u8, malformed_reply.json, "delivery is uncertain") != null);
    try t.expect(std.mem.indexOf(u8, malformed_reply.json, "NOT resent") != null);
    try t.expect(std.mem.indexOf(u8, malformed_reply.json, "mutation_may_have_applied") != null);
    try t.expect(!older_gui.dead);
    try t.expectEqual(wire.PANEL_RPC_VERSION, older_gui.panel_rpc);
    try t.expectEqual(wire.FrameType.err, (try wire.peelFrame(older_gui.wbuf.items)).?.frame.ftype);

    // A bad reply fails its routes without costing the presenter its panel
    // capability: the next request still reaches it.
    requester_a.wbuf.clearRetainingCapacity();
    older_gui.wbuf.clearRetainingCapacity();
    daemon.handlePanelRequest(&requester_a, call_a.items);
    const oversized_route = daemon.panel_routes.items[0].route_id;
    older_gui.wbuf.clearRetainingCapacity();
    const oversized = try a.alloc(u8, wire.PANEL_ENVELOPE_MAX + 1);
    defer a.free(oversized);
    std.mem.writeInt(u64, oversized[0..wire.PANEL_ENVELOPE_HEADER], oversized_route, .little);
    daemon.handlePanelReply(&older_gui, oversized);
    try t.expectEqual(@as(usize, 0), daemon.panel_routes.items.len);
    const oversized_reply = try firstEnvelope(&requester_a, .panel_reply);
    try t.expect(std.mem.indexOf(u8, oversized_reply.json, "oversized") != null);
    try t.expect(std.mem.indexOf(u8, oversized_reply.json, "delivery is uncertain") != null);
    try t.expectEqual(wire.PANEL_RPC_VERSION, older_gui.panel_rpc);

    // The daemon does not interpret panel JSON: a body it could never make
    // sense of is relayed to the requester byte for byte, and validating it
    // is the MCP client's job.
    requester_a.wbuf.clearRetainingCapacity();
    older_gui.wbuf.clearRetainingCapacity();
    var show_call = try envelope(a, 8, "{\"cmd\":\"panel-show\"}");
    defer show_call.deinit(a);
    daemon.handlePanelRequest(&requester_a, show_call.items);
    const opaque_route = daemon.panel_routes.items[0].route_id;
    older_gui.wbuf.clearRetainingCapacity();
    var opaque_reply = try envelope(a, opaque_route, "not json at all");
    defer opaque_reply.deinit(a);
    daemon.handlePanelReply(&older_gui, opaque_reply.items);
    try t.expectEqual(@as(usize, 0), daemon.panel_routes.items.len);
    const relayed = try firstEnvelope(&requester_a, .panel_reply);
    try t.expectEqualStrings("not json at all", relayed.json);
    try t.expectEqual(@as(u64, 8), relayed.id);
    try t.expectEqual(wire.PANEL_RPC_VERSION, older_gui.panel_rpc);

    // A malformed ENVELOPE is the daemon's own business, and it fails the
    // presenter's routes with each route's own delivery class: the replied-to
    // route is proven delivered, the second request is still untouched behind it.
    requester_a.wbuf.clearRetainingCapacity();
    requester_b.wbuf.clearRetainingCapacity();
    older_gui.wbuf.clearRetainingCapacity();
    daemon.handlePanelRequest(&requester_a, call_a.items);
    daemon.handlePanelRequest(&requester_b, call_b.items);
    const invalid_shape_route = daemon.panel_routes.items[0].route_id;
    const sent_request = (try wire.peelFrame(older_gui.wbuf.items)).?;
    const remaining = older_gui.wbuf.items.len - sent_request.consumed;
    std.mem.copyForwards(u8, older_gui.wbuf.items[0..remaining], older_gui.wbuf.items[sent_request.consumed..]);
    older_gui.wbuf.shrinkRetainingCapacity(remaining);
    older_gui.normal_bytes_written += sent_request.consumed;
    // A correlation id with no JSON behind it: decodable enough to name the
    // route, invalid as an envelope.
    var invalid_shape: [wire.PANEL_ENVELOPE_HEADER]u8 = undefined;
    std.mem.writeInt(u64, &invalid_shape, invalid_shape_route, .little);
    daemon.handlePanelReply(&older_gui, &invalid_shape);
    try t.expect(!older_gui.dead);
    try t.expectEqual(wire.PANEL_RPC_VERSION, older_gui.panel_rpc);
    try t.expectEqual(@as(usize, 0), daemon.panel_routes.items.len);
    const invalid_shape_a = try firstEnvelope(&requester_a, .panel_reply);
    try t.expect(std.mem.indexOf(u8, invalid_shape_a.json, "malformed reply") != null);
    try t.expect(std.mem.indexOf(u8, invalid_shape_a.json, "uncertain_delivery") != null);
    const invalid_shape_b = try firstEnvelope(&requester_b, .panel_reply);
    try t.expect(std.mem.indexOf(u8, invalid_shape_b.json, "failed before this route") != null);
    try t.expect(std.mem.indexOf(u8, invalid_shape_b.json, "\"failure_class\":\"pre_delivery\"") != null);
    try t.expect(std.mem.indexOf(u8, invalid_shape_b.json, "\"mutation_may_have_applied\":false") != null);
    try t.expect(std.mem.indexOf(u8, invalid_shape_b.json, "\"resend_safe\":true") != null);

    // There is no requester-to-presenter binding: when the earliest presenter
    // dies, the very next request from the SAME requester attachment simply
    // selects whichever panel-capable attachment is present then.
    requester_a.wbuf.clearRetainingCapacity();
    newer_gui.wbuf.clearRetainingCapacity();
    older_gui.dead = true;
    daemon.handlePanelRequest(&requester_a, call_a.items);
    try t.expectEqual(&newer_gui, daemon.panel_routes.items[0].presenter);
    const abandoned_route = daemon.panel_routes.items[0].route_id;
    requester_a.dead = true;
    daemon.panelClientDetached(&requester_a, "unused");
    try t.expectEqual(@as(usize, 0), daemon.panel_routes.items.len);
    try t.expectEqual(@as(usize, 0), newer_gui.wbuf.items.len);
    newer_gui.wbuf.clearRetainingCapacity();
    var stale = try envelope(a, abandoned_route, "{\"ok\":true}");
    defer stale.deinit(a);
    daemon.handlePanelReply(&newer_gui, stale.items);
    try t.expectEqual(wire.FrameType.err, (try wire.peelFrame(newer_gui.wbuf.items)).?.frame.ftype);
}

test "panel relay cancellation removes exact queued frames and rebases later routes" {
    const t = std.testing;
    const a = t.allocator;
    var empty: [0]u8 = .{};
    var daemon = Daemon{ .allocator = a, .listen_fd = -1, .sock_path = empty[0..] };
    defer daemon.clients.deinit(a);
    defer daemon.panel_routes.deinit(a);
    var session: Session = undefined;
    session.exited = false;

    var presenter = Client{
        .allocator = a,
        .fd = -1,
        .id = 1,
        .attached = &session,
        .kind = .gui,
        .panel_rpc_support = wire.PANEL_RPC_VERSION,
        .panel_rpc = wire.PANEL_RPC_VERSION,
    };
    defer clearClient(&presenter, a);
    var requesters: [3]Client = undefined;
    for (&requesters, 0..) |*requester, i| {
        requester.* = .{
            .allocator = a,
            .fd = -1,
            .id = @intCast(10 + i),
            .attached = &session,
            .kind = .mcp,
            .read_only = true,
            .panel_rpc_support = wire.PANEL_RPC_VERSION,
            .panel_rpc = wire.PANEL_RPC_VERSION,
            .panel_only = true,
        };
    }
    defer for (&requesters) |*requester| clearClient(requester, a);
    try daemon.clients.append(a, &presenter);
    for (&requesters) |*requester| try daemon.clients.append(a, requester);

    presenter.queueFrame(.peer_info, "before");
    var calls: [3]std.ArrayList(u8) = undefined;
    for (&calls, 0..) |*call, i| {
        call.* = try envelope(a, @intCast(100 + i), "{\"cmd\":\"panel-close\"}");
        daemon.handlePanelRequest(&requesters[i], call.items);
    }
    defer for (&calls) |*call| call.deinit(a);
    presenter.queueFrame(.peer_info, "after");
    try t.expectEqual(@as(usize, 3), daemon.panel_routes.items.len);
    const first_route = daemon.panel_routes.items[0].route_id;
    const last_route = daemon.panel_routes.items[2].route_id;
    const last_start_before = daemon.panel_routes.items[2].presenter_stream_start;
    const middle_len = daemon.panel_routes.items[1].presenter_stream_len;

    daemon.panelClientDetached(&requesters[1], "requester detached");
    try t.expectEqual(@as(usize, 2), daemon.panel_routes.items.len);
    var ids_buf: [3]u64 = undefined;
    const after_middle = try panelRequestIds(&presenter, &ids_buf);
    try t.expectEqualSlices(u64, &.{ first_route, last_route }, after_middle);
    var last_start_after: ?u64 = null;
    for (daemon.panel_routes.items) |route| {
        if (route.route_id == last_route) last_start_after = route.presenter_stream_start;
    }
    try t.expectEqual(last_start_before - @as(u64, @intCast(middle_len)), last_start_after.?);

    for (daemon.panel_routes.items) |*route| {
        if (route.route_id == first_route) route.deadline_ms = 1;
    }
    daemon.panelRoutesTick(1);
    const after_first = try panelRequestIds(&presenter, &ids_buf);
    try t.expectEqualSlices(u64, &.{last_route}, after_first);
    const timeout = try firstEnvelope(&requesters[0], .panel_reply);
    try t.expect(std.mem.indexOf(u8, timeout.json, "\"resend_safe\":true") != null);

    daemon.panelClientDetached(&requesters[2], "requester detached");
    try t.expectEqual(@as(usize, 0), daemon.panel_routes.items.len);
    try t.expectEqual(@as(usize, 0), (try panelRequestIds(&presenter, &ids_buf)).len);
    var rest = presenter.wbuf.items;
    for ([_][]const u8{ "before", "after" }) |payload| {
        const peeled = (try wire.peelFrame(rest)).?;
        try t.expectEqual(wire.FrameType.peer_info, peeled.frame.ftype);
        try t.expectEqualStrings(payload, peeled.frame.payload);
        rest = rest[peeled.consumed..];
    }
    try t.expectEqual(@as(usize, 0), rest.len);
}

test "duplicate presenter attachment takes concurrent work after detach" {
    const t = std.testing;
    const a = t.allocator;
    var empty: [0]u8 = .{};
    var daemon = Daemon{ .allocator = a, .listen_fd = -1, .sock_path = empty[0..] };
    defer daemon.clients.deinit(a);
    defer daemon.panel_routes.deinit(a);
    var session: Session = undefined;
    session.exited = false;

    var requester = Client{
        .allocator = a,
        .fd = -1,
        .id = 30,
        .attached = &session,
        .kind = .mcp,
        .read_only = true,
        .panel_rpc_support = wire.PANEL_RPC_VERSION,
        .panel_rpc = wire.PANEL_RPC_VERSION,
        .panel_only = true,
    };
    defer clearClient(&requester, a);
    var first = Client{
        .allocator = a,
        .fd = -1,
        .id = 10,
        .attached = &session,
        .kind = .gui,
        .panel_rpc_support = wire.PANEL_RPC_VERSION,
        .panel_rpc = wire.PANEL_RPC_VERSION,
    };
    defer clearClient(&first, a);
    var duplicate = Client{
        .allocator = a,
        .fd = -1,
        .id = 20,
        .attached = &session,
        .kind = .gui,
        .panel_rpc_support = wire.PANEL_RPC_VERSION,
        .panel_rpc = wire.PANEL_RPC_VERSION,
    };
    defer clearClient(&duplicate, a);
    try daemon.clients.append(a, &duplicate);
    try daemon.clients.append(a, &requester);
    try daemon.clients.append(a, &first);

    var call = try envelope(a, 1, "{\"cmd\":\"panel-list\"}");
    defer call.deinit(a);
    daemon.handlePanelRequest(&requester, call.items);
    try t.expectEqual(&first, daemon.panel_routes.items[0].presenter);

    // Teardown races an already-routed request. Processing detach first must
    // remove this attachment from presenter selection before the requester
    // submits its next call; that call belongs to the surviving duplicate.
    daemon_serve.handleFrame(&daemon, &first, .{ .ftype = .detach, .payload = "" });
    try t.expect(first.attached == null);
    try t.expectEqual(@as(usize, 0), daemon.panel_routes.items.len);
    const canceled = try firstEnvelope(&requester, .panel_reply);
    try t.expect(std.mem.indexOf(u8, canceled.json, "\"failure_class\":\"pre_delivery\"") != null);
    requester.wbuf.clearRetainingCapacity();
    daemon.handlePanelRequest(&requester, call.items);
    try t.expectEqual(&duplicate, daemon.panel_routes.items[0].presenter);
    const duplicate_route = daemon.panel_routes.items[0].route_id;
    var reply = try envelope(a, duplicate_route, "{\"ok\":true,\"panels\":[]}");
    defer reply.deinit(a);
    daemon.handlePanelReply(&duplicate, reply.items);
    try t.expectEqual(@as(u64, 1), (try firstEnvelope(&requester, .panel_reply)).id);

    // A lower-id reconnection becomes the earliest attachment and wins routing.
    var reconnected = Client{
        .allocator = a,
        .fd = -1,
        .id = 5,
        .attached = &session,
        .kind = .gui,
        .panel_rpc_support = wire.PANEL_RPC_VERSION,
        .panel_rpc = wire.PANEL_RPC_VERSION,
    };
    defer clearClient(&reconnected, a);
    try daemon.clients.append(a, &reconnected);
    requester.wbuf.clearRetainingCapacity();
    daemon.handlePanelRequest(&requester, call.items);
    try t.expectEqual(&reconnected, daemon.panel_routes.items[0].presenter);
    daemon.panelClientDetached(&requester, "test complete");
}

test "panel relay reports no compatible GUI with the caller id" {
    const t = std.testing;
    const a = t.allocator;
    var empty: [0]u8 = .{};
    var daemon = Daemon{ .allocator = a, .listen_fd = -1, .sock_path = empty[0..] };
    defer daemon.clients.deinit(a);
    defer daemon.panel_routes.deinit(a);
    var session: Session = undefined;
    session.exited = false;
    var requester = Client{
        .allocator = a,
        .fd = -1,
        .attached = &session,
        .kind = .mcp,
        .read_only = true,
        .panel_rpc_support = wire.PANEL_RPC_VERSION,
        .panel_rpc = wire.PANEL_RPC_VERSION,
        .panel_only = true,
    };
    defer clearClient(&requester, a);
    try daemon.clients.append(a, &requester);
    var call = try envelope(a, 99, "{\"cmd\":\"panel-list\"}");
    defer call.deinit(a);
    daemon.handlePanelRequest(&requester, call.items);
    const result = try firstEnvelope(&requester, .panel_reply);
    try t.expectEqual(@as(u64, 99), result.id);
    try t.expect(std.mem.indexOf(u8, result.json, "no compatible GUI") != null);
    try t.expect(std.mem.indexOf(u8, result.json, "\"error_code\":\"no_compatible_gui\"") != null);
    try t.expect(std.mem.indexOf(u8, result.json, "\"failure_class\":\"pre_delivery\"") != null);
    try t.expect(std.mem.indexOf(u8, result.json, "\"mutation_may_have_applied\":false") != null);
    try t.expect(std.mem.indexOf(u8, result.json, "\"resend_safe\":true") != null);
    try t.expectEqual(@as(usize, 0), daemon.panel_routes.items.len);
}

test "panel route caps report explicit pre-delivery resend safety" {
    const t = std.testing;
    const a = t.allocator;
    var empty: [0]u8 = .{};
    var daemon = Daemon{ .allocator = a, .listen_fd = -1, .sock_path = empty[0..] };
    defer daemon.clients.deinit(a);
    defer daemon.panel_routes.deinit(a);
    var session: Session = undefined;
    session.exited = false;
    var requester = Client{
        .allocator = a,
        .fd = -1,
        .id = 2,
        .attached = &session,
        .kind = .mcp,
        .read_only = true,
        .panel_rpc_support = wire.PANEL_RPC_VERSION,
        .panel_rpc = wire.PANEL_RPC_VERSION,
        .panel_only = true,
    };
    defer clearClient(&requester, a);
    var presenter = Client{
        .allocator = a,
        .fd = -1,
        .id = 1,
        .attached = &session,
        .kind = .gui,
        .panel_rpc_support = wire.PANEL_RPC_VERSION,
        .panel_rpc = wire.PANEL_RPC_VERSION,
    };
    defer clearClient(&presenter, a);
    try daemon.clients.append(a, &presenter);
    try daemon.clients.append(a, &requester);
    const route = dmod.PanelRoute{
        .route_id = 1,
        .caller_id = 1,
        .requester = &requester,
        .presenter = &presenter,
        .session = &session,
        .deadline_ms = 1,
        .presenter_stream_start = 0,
        .presenter_stream_len = 1,
    };
    var call = try envelope(a, 44, "{\"cmd\":\"panel-close\"}");
    defer call.deinit(a);

    for (0..Daemon.PANEL_MAX_PENDING_PER_REQUESTER) |_| try daemon.panel_routes.append(a, route);
    daemon.handlePanelRequest(&requester, call.items);
    var refusal = try firstEnvelope(&requester, .panel_reply);
    try t.expect(std.mem.indexOf(u8, refusal.json, "requester panel route limit") != null);
    try t.expect(std.mem.indexOf(u8, refusal.json, "\"failure_class\":\"pre_delivery\"") != null);
    try t.expect(std.mem.indexOf(u8, refusal.json, "\"mutation_may_have_applied\":false") != null);
    try t.expect(std.mem.indexOf(u8, refusal.json, "\"resend_safe\":true") != null);

    requester.wbuf.clearRetainingCapacity();
    daemon.panel_routes.clearRetainingCapacity();
    for (0..Daemon.PANEL_MAX_PENDING) |_| try daemon.panel_routes.append(a, route);
    daemon.handlePanelRequest(&requester, call.items);
    refusal = try firstEnvelope(&requester, .panel_reply);
    try t.expect(std.mem.indexOf(u8, refusal.json, "daemon panel route limit") != null);
    try t.expect(std.mem.indexOf(u8, refusal.json, "\"failure_class\":\"pre_delivery\"") != null);
    try t.expect(std.mem.indexOf(u8, refusal.json, "\"mutation_may_have_applied\":false") != null);
    try t.expect(std.mem.indexOf(u8, refusal.json, "\"resend_safe\":true") != null);
}

test "panel-only reattach clears viewer replay and audio subscription state" {
    const t = std.testing;
    const a = t.allocator;
    var empty: [0]u8 = .{};
    var daemon = Daemon{ .allocator = a, .listen_fd = -1, .sock_path = empty[0..] };
    defer daemon.sessions.deinit(a);
    defer daemon.clients.deinit(a);
    defer daemon.panel_routes.deinit(a);

    var session: Session = undefined;
    session.name = @constCast("current-name");
    session.origin_name = @constCast("spawn-name");
    session.exited = false;
    try daemon.sessions.append(a, &session);

    var client = Client{
        .allocator = a,
        .fd = -1,
        .proto = wire.PROTO_VERSION,
        .snapshot_version = 1,
        .native_state_max = wire.NATIVE_STATE_VERSION,
        .audio_channels = true,
        .audio_ok = true,
        .audio_opus = true,
        .needs_resync = true,
        .needs_native_resync = true,
        .panel_rpc_support = wire.PANEL_RPC_VERSION,
        .attached = &session,
        .kind = .mcp,
    };
    defer clearClient(&client, a);
    try daemon.clients.append(a, &client);

    client.queueFrame(.snapshot, "old snapshot");
    client.queueFrame(.events, "old events");
    client.queueFrame(.native_gap, "");
    client.queueFrame(.native_sync, "");
    client.queueAudioFrame(.chan_data, "old audio");

    // These are processed in one clientReadable loop when both frames arrive
    // in one read: the detach OK must survive, but no old stream frame may
    // cross the following panel-only attach OK.
    daemon_serve.handleFrame(&daemon, &client, .{ .ftype = .detach, .payload = "" });
    daemon_serve.handleFrame(&daemon, &client, .{
        .ftype = .attach,
        .payload = "{\"name\":\"current-name\",\"kind\":\"mcp\",\"panel_only\":true,\"panel_rpc\":1}",
    });
    try t.expectEqual(&session, client.attached.?);
    try t.expect(client.panel_only);
    try t.expect(!client.needs_resync);
    try t.expect(!client.needs_native_resync);
    try t.expect(client.audio_ok);
    try t.expect(client.audio_opus);
    try t.expect(!Daemon.terminalViewer(&client, &session));
    try t.expectEqual(@as(usize, 0), client.audio_wbuf.items.len);

    var rest = client.wbuf.items;
    var ok_count: usize = 0;
    while (try wire.peelFrame(rest)) |peeled| {
        try t.expectEqual(wire.FrameType.ok, peeled.frame.ftype);
        ok_count += 1;
        rest = rest[peeled.consumed..];
    }
    try t.expectEqual(@as(usize, 0), rest.len);
    try t.expectEqual(@as(usize, 2), ok_count);

    const queued = client.wbuf.items.len;
    daemon.replayNativeChannels(&client, &session);
    try t.expectEqual(queued, client.wbuf.items.len);
}

test "same-name replacement rejects reconnect with the prior lifetime origin" {
    const t = std.testing;
    const a = t.allocator;
    var empty: [0]u8 = .{};
    var daemon = Daemon{ .allocator = a, .listen_fd = -1, .sock_path = empty[0..] };
    defer daemon.sessions.deinit(a);
    var replacement: Session = undefined;
    replacement.name = @constCast("same");
    replacement.origin_name = @constCast("same");
    replacement.origin_id = "20000000000000000000000000000002".*;
    replacement.exited = false;
    try daemon.sessions.append(a, &replacement);
    var client = Client{
        .allocator = a,
        .fd = -1,
        .proto = wire.PROTO_VERSION,
        .snapshot_version = 1,
        .panel_rpc_support = wire.PANEL_RPC_VERSION,
    };
    defer clearClient(&client, a);

    daemon.handleAttach(&client, "{\"name\":\"same\",\"kind\":\"gui\",\"origin_id\":\"10000000000000000000000000000001\",\"panel_rpc\":1,\"identity_first\":true}");
    try t.expect(client.attached == null);
    const refusal = (try wire.peelFrame(client.wbuf.items)) orelse return error.TestUnexpectedResult;
    try t.expectEqual(wire.FrameType.err, refusal.frame.ftype);
    try t.expect(std.mem.indexOf(u8, refusal.frame.payload, "session origin identity changed") != null);
}

test "session teardown signals panel-only clients before clearing attachment identity" {
    const t = std.testing;
    const a = t.allocator;
    var empty: [0]u8 = .{};
    var daemon = Daemon{ .allocator = a, .listen_fd = -1, .sock_path = empty[0..] };
    defer daemon.clients.deinit(a);
    defer daemon.channels.deinit(a);
    defer daemon.panel_routes.deinit(a);
    var session: Session = undefined;
    session.controller = null;
    session.exited = false;
    var requester = Client{
        .allocator = a,
        .fd = -1,
        .attached = &session,
        .kind = .mcp,
        .read_only = true,
        .panel_rpc_support = wire.PANEL_RPC_VERSION,
        .panel_rpc = wire.PANEL_RPC_VERSION,
        .panel_only = true,
    };
    defer clearClient(&requester, a);
    try daemon.clients.append(a, &requester);
    var presenter = Client{
        .allocator = a,
        .fd = -1,
        .id = 2,
        .attached = &session,
        .kind = .gui,
        .panel_rpc_support = wire.PANEL_RPC_VERSION,
        .panel_rpc = wire.PANEL_RPC_VERSION,
    };
    defer clearClient(&presenter, a);
    try daemon.clients.append(a, &presenter);

    daemon.removeSession(&session);
    try t.expect(requester.attached == null);
    try t.expect(!requester.panel_only);
    try t.expectEqual(@as(u8, 0), requester.panel_rpc);
    const frame = (try wire.peelFrame(requester.wbuf.items)) orelse return error.TestUnexpectedResult;
    try t.expectEqual(wire.FrameType.gone, frame.frame.ftype);
    try t.expect(std.mem.indexOf(u8, frame.frame.payload, "session closed") != null);
    try t.expect(presenter.attached == null);
    try t.expectEqual(@as(u8, 0), presenter.panel_rpc);
}
