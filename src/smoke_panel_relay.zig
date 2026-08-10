//! Native-panel mux relay stage shared by monolith and broker smoke rigs.

const std = @import("std");
const c = @import("c.zig").c;
const client_mod = @import("mux/client.zig");
const daemon_mod = @import("mux/daemon.zig");
const wire = @import("mux/wire.zig");
const protocol = @import("ipc/protocol.zig");

fn fail(msg: []const u8) noreturn {
    std.debug.print("smoke-panel-relay: FAIL: {s}\n", .{msg});
    std.process.exit(1);
}

fn attachPresenter(
    allocator: std.mem.Allocator,
    sock_path: []const u8,
    session: []const u8,
) client_mod.Conn {
    var conn = client_mod.Conn.connectProbed(allocator, sock_path) catch fail("presenter connect");
    if (conn.panel_rpc != wire.PANEL_RPC_VERSION) fail("welcome did not negotiate current panel_rpc");
    conn.sendAttach(session, .{
        .kind = "gui",
        .read_only = true,
        .panel_rpc = wire.PANEL_RPC_VERSION,
    }) catch fail("presenter attach send");
    (conn.recvExpectFor(&.{.snapshot}, 5_000) catch fail("presenter did not receive snapshot")).deinit(allocator);
    return conn;
}

/// A released GUI predating panel_rpc: it is a real terminal viewer but not a
/// compatible panel presenter.
fn attachLegacyGui(allocator: std.mem.Allocator, sock_path: []const u8, session: []const u8) client_mod.Conn {
    var conn = client_mod.Conn.connect(allocator, sock_path) catch fail("legacy GUI connect");
    conn.setNonBlocking();
    conn.sendJson(.attach, .{
        .name = session,
        .kind = "gui",
    }) catch fail("legacy GUI attach send");
    (conn.recvExpectFor(&.{.snapshot}, 5_000) catch fail("legacy GUI did not receive snapshot")).deinit(allocator);
    return conn;
}

fn recvEnvelope(allocator: std.mem.Allocator, conn: *client_mod.Conn, ftype: wire.FrameType, timeout_ms: i64) struct {
    id: u64,
    json: []u8,
} {
    const frame = conn.recvExpectFor(&.{ftype}, timeout_ms) catch fail("correlated panel frame not received");
    defer frame.deinit(allocator);
    const decoded = wire.decodePanelEnvelope(frame.payload) catch fail("bad correlated panel envelope");
    return .{
        .id = decoded.id,
        .json = allocator.dupe(u8, decoded.json) catch fail("oom copying panel JSON"),
    };
}

fn expectNoFrame(conn: *client_mod.Conn, ftype: wire.FrameType, timeout_ms: i64, message: []const u8) void {
    if (conn.recvExpectFor(&.{ftype}, timeout_ms)) |frame| {
        frame.deinit(conn.allocator);
        fail(message);
    } else |err| {
        if (err != error.Timeout) fail("unexpected receive failure while proving a frame was absent");
    }
}

fn expectSilence(conn: *client_mod.Conn, timeout_ms: i64, message: []const u8) void {
    if (conn.recvFrameFor(timeout_ms)) |frame| {
        frame.deinit(conn.allocator);
        fail(message);
    } else |err| {
        if (err != error.Timeout) fail("unexpected receive failure while proving panel-only silence");
    }
}

fn waitPeerRoster(conn: *client_mod.Conn, total: u32, guis: u32, drivers: u32, timeout_ms: i64) void {
    const deadline = @import("util/clock.zig").nowMs() + timeout_ms;
    while (true) {
        const remain = deadline - @import("util/clock.zig").nowMs();
        if (remain <= 0) fail("panel requester absent from peer metadata before deadline");
        const peers = conn.recvExpectFor(&.{.peer_info}, remain) catch |err| {
            if (err == error.Timeout) fail("panel requester absent from peer metadata before deadline");
            fail("panel peer metadata receive failed");
        };
        defer peers.deinit(conn.allocator);
        const Roster = struct { total: u32 = 0, guis: u32 = 0, drivers: u32 = 0 };
        var parsed = std.json.parseFromSlice(Roster, conn.allocator, peers.payload, .{
            .ignore_unknown_fields = true,
        }) catch continue;
        defer parsed.deinit();
        if (parsed.value.total == total and parsed.value.guis == guis and parsed.value.drivers == drivers)
            return;
    }
}

fn expectNameReserved(allocator: std.mem.Allocator, owner: *client_mod.Conn, name: []const u8) void {
    owner.sendJson(.spawn, .{
        .name = name,
        .argv = [_][]const u8{ "sleep", "1" },
        .rows = @as(u16, 24),
        .cols = @as(u16, 80),
    }) catch fail("name reservation spawn send");
    const collision = owner.recvExpectFor(&.{.err}, 5_000) catch fail("a live session's name was reusable");
    defer collision.deinit(allocator);
    if (std.mem.indexOf(u8, collision.payload, "already exists") == null)
        fail("name collision returned the wrong error");
}

fn listHas(allocator: std.mem.Allocator, conn: *client_mod.Conn, name: []const u8, expected_viewers: ?u32) bool {
    conn.sendFrame(.list, "") catch fail("list send");
    const frame = conn.recvExpectFor(&.{.welcome}, 5_000) catch fail("list reply");
    defer frame.deinit(allocator);
    const Listing = struct {
        sessions: []const struct {
            name: []const u8 = "",
            clients: u32 = 0,
            viewers: u32 = 0,
        } = &.{},
    };
    var parsed = std.json.parseFromSlice(Listing, allocator, frame.payload, .{
        .ignore_unknown_fields = true,
    }) catch fail("list parse");
    defer parsed.deinit();
    for (parsed.value.sessions) |session| {
        if (!std.mem.eql(u8, session.name, name)) continue;
        if (expected_viewers) |want| {
            if (session.viewers != want) fail("panel-only attachment counted as a viewer");
        }
        return true;
    }
    return false;
}

fn listIdentityIs(allocator: std.mem.Allocator, conn: *client_mod.Conn, name: []const u8, origin_name: []const u8) bool {
    conn.sendFrame(.list, "") catch fail("identity list send");
    const frame = conn.recvExpectFor(&.{.welcome}, 5_000) catch fail("identity list reply");
    defer frame.deinit(allocator);
    const Listing = struct {
        sessions: []const struct {
            name: []const u8 = "",
            origin_name: []const u8 = "",
        } = &.{},
    };
    var parsed = std.json.parseFromSlice(Listing, allocator, frame.payload, .{
        .ignore_unknown_fields = true,
    }) catch fail("identity list parse");
    defer parsed.deinit();
    for (parsed.value.sessions) |session| {
        if (std.mem.eql(u8, session.name, name) and std.mem.eql(u8, session.origin_name, origin_name))
            return true;
    }
    return false;
}

fn patternByte(offset: u64) u8 {
    return @truncate(offset *% 31 +% 7);
}

fn proveAttachedAssetRead(allocator: std.mem.Allocator, presenter: *client_mod.Conn) void {
    var path_buf: [160]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/tmp/sketerm-panel-relay-asset-{d}.bin", .{c.getpid()}) catch
        fail("asset smoke path");
    defer _ = c.unlink(path.ptr);
    const fd = c.open(path.ptr, c.O_WRONLY | c.O_CREAT | c.O_TRUNC | c.O_CLOEXEC, @as(c.mode_t, 0o600));
    if (fd < 0) fail("asset smoke create");
    var chunk: [64 << 10]u8 = undefined;
    var written: u64 = 0;
    const total: u64 = 512 << 10;
    while (written < total) {
        for (&chunk, 0..) |*byte, i| byte.* = patternByte(written + i);
        const n = c.write(fd, &chunk, @min(chunk.len, total - written));
        if (n <= 0) fail("asset smoke write");
        written += @intCast(n);
    }
    _ = c.close(fd);

    const req: u32 = 0xface0001;
    presenter.sendJson(.fs_op, .{
        .req = req,
        .op = "read",
        .path = path,
        .off = @as(u64, 0),
        .len = @as(u32, @intCast(total)),
    }) catch fail("attached asset read send");

    var saw_data = false;
    var saw_reply = false;
    var saw_events = false;
    var checks: usize = 0;
    while (!(saw_data and saw_reply and saw_events) and checks < 100) : (checks += 1) {
        const frame = presenter.recvFrameFor(200) catch |err| {
            if (err == error.Timeout) continue;
            fail("attached asset read receive");
        };
        defer frame.deinit(allocator);
        switch (frame.ftype) {
            .events => saw_events = true,
            .fs_data => {
                if (frame.payload.len < 12 or std.mem.readInt(u32, frame.payload[0..4], .little) != req)
                    fail("attached asset data header");
                const off = std.mem.readInt(u64, frame.payload[4..12], .little);
                for (frame.payload[12..], 0..) |byte, i| {
                    if (byte != patternByte(off + i)) fail("attached asset bytes changed in transport");
                }
                saw_data = true;
            },
            .fs_reply => {
                const Reply = struct { req: u32 = 0, ok: bool = false, size: u64 = 0, eof: bool = false };
                var parsed = std.json.parseFromSlice(Reply, allocator, frame.payload, .{
                    .ignore_unknown_fields = true,
                }) catch fail("attached asset reply parse");
                defer parsed.deinit();
                if (parsed.value.req == req) {
                    if (!parsed.value.ok or parsed.value.size != total or !parsed.value.eof)
                        fail("attached asset reply identity");
                    saw_reply = true;
                }
            },
            else => {},
        }
    }
    if (!saw_data or !saw_reply) fail("attached GUI connection did not fetch daemon-host asset bytes");
    if (!saw_events) fail("terminal frames stopped while the attached GUI fetched an asset");
}

pub fn run(allocator: std.mem.Allocator, sock_path: []const u8) void {
    var owner = client_mod.Conn.connectProbed(allocator, sock_path) catch fail("owner connect");
    defer owner.deinit();
    if (owner.panel_rpc != wire.PANEL_RPC_VERSION) fail("welcome lacks current panel_rpc");
    owner.sendJson(.spawn, .{
        .name = "panel-stage",
        .argv = [_][]const u8{
            "sh",
            "-c",
            "printf 'MUXENV=[%s] SESSION=[%s]\\n' \"$SKETERM_MUX_SOCKET\" \"$SKETERM_SESSION\"; while :; do echo PANEL-STREAM; sleep 0.05; done",
        },
        .rows = @as(u16, 24),
        .cols = @as(u16, 80),
    }) catch fail("spawn send");
    (owner.recvExpectFor(&.{.ok}, 5_000) catch fail("spawn reply")).deinit(allocator);

    var requester_a = client_mod.connectPanelRequester(allocator, sock_path, "panel-stage", 5_000) catch
        fail("panel-only requester attach");
    defer requester_a.deinit();
    if (c.fcntl(requester_a.fd, c.F_GETFL) & c.O_NONBLOCK == 0)
        fail("panel requester fd is blocking after its connect-only handshake");
    // The child continuously emits output. A panel-only peer must still see
    // no snapshot or events after its single attach OK.
    expectSilence(&requester_a, 300, "panel-only attach received terminal/native/audio traffic after OK");

    requester_a.sendPanelRequest(11, "{\"cmd\":\"smoke\",\"op\":\"no-presenter\"}") catch fail("no-presenter request");
    const no_gui = recvEnvelope(allocator, &requester_a, .panel_reply, 5_000);
    defer allocator.free(no_gui.json);
    if (no_gui.id != 11 or std.mem.indexOf(u8, no_gui.json, "no compatible GUI") == null)
        fail("no-compatible-GUI result was not correlated");
    if (std.mem.indexOf(u8, no_gui.json, "uncertain_delivery") != null)
        fail("pre-delivery no-viewer failure was classified as uncertain");

    // One socket write carries detach + panel-only reattach. Old terminal
    // events already queued daemon-side must be discarded before the second
    // OK, and the new role must remain silent while the child keeps printing.
    var transition = attachPresenter(allocator, sock_path, "panel-stage");
    transition.queueJson(.detach, .{}) catch fail("pipelined detach queue");
    transition.queueJson(.attach, .{
        .name = "panel-stage",
        .kind = "mcp",
        .panel_only = true,
        .panel_rpc = wire.PANEL_RPC_VERSION,
    }) catch fail("pipelined panel attach queue");
    transition.flushQueued() catch fail("pipelined transition flush");
    (transition.recvExpectFor(&.{.ok}, 5_000) catch fail("pipelined detach reply")).deinit(allocator);
    (transition.recvExpectFor(&.{.ok}, 5_000) catch fail("pipelined panel attach reply")).deinit(allocator);
    expectSilence(&transition, 300, "pipelined panel-only reattach received old or live stream traffic");
    transition.deinit();

    var legacy_gui = attachLegacyGui(allocator, sock_path, "panel-stage");
    requester_a.sendPanelRequest(12, "{\"cmd\":\"smoke\",\"op\":\"legacy-gui\"}") catch fail("legacy-GUI request");
    const unsupported_gui = recvEnvelope(allocator, &requester_a, .panel_reply, 5_000);
    defer allocator.free(unsupported_gui.json);
    if (unsupported_gui.id != 12 or std.mem.indexOf(u8, unsupported_gui.json, "no compatible GUI") == null)
        fail("an attached GUI without panel_rpc was treated as compatible");
    legacy_gui.deinit();

    // A hostile peer can bypass the client helper and send an envelope over
    // the panel-specific cap while remaining under MAX_FRAME. It must receive
    // a bounded, size-specific refusal, and the connection must remain usable.
    const oversized_len = wire.PANEL_ENVELOPE_HEADER + wire.PANEL_JSON_MAX + 1;
    const oversized = allocator.alloc(u8, oversized_len) catch fail("oversized panel request allocation");
    defer allocator.free(oversized);
    std.mem.writeInt(u64, oversized[0..wire.PANEL_ENVELOPE_HEADER], 13, .little);
    @memset(oversized[wire.PANEL_ENVELOPE_HEADER..], 'x');
    requester_a.sendFrame(.panel_request, oversized) catch fail("oversized panel request send");
    const oversized_reply = recvEnvelope(allocator, &requester_a, .panel_reply, 5_000);
    defer allocator.free(oversized_reply.json);
    if (oversized_reply.id != 13 or std.mem.indexOf(u8, oversized_reply.json, "too large") == null or
        std.mem.indexOf(u8, oversized_reply.json, "\"failure_class\":\"pre_delivery\"") == null or
        std.mem.indexOf(u8, oversized_reply.json, "\"mutation_may_have_applied\":false") == null or
        std.mem.indexOf(u8, oversized_reply.json, "\"resend_safe\":true") == null)
        fail("oversized panel request was not a correlated safe pre-delivery failure");

    var older_gui = attachPresenter(allocator, sock_path, "panel-stage");
    var older_live = true;
    defer if (older_live) older_gui.deinit();
    proveAttachedAssetRead(allocator, &older_gui);
    var newer_gui = attachPresenter(allocator, sock_path, "panel-stage");
    defer newer_gui.deinit();

    // The document parser accepts exactly 1 MiB. Its outer request string is
    // larger because every escaped quote is escaped again; the real relay must
    // carry that exact boundary without weakening the parser's own cap.
    const doc_prefix = "{\"root\":\"t\",\"components\":{\"t\":{\"type\":\"text\",\"text\":\"ok\"}},\"padding\":\"";
    const doc_suffix = "\"}";
    const max_doc = allocator.alloc(u8, 1 << 20) catch fail("maximum panel document allocation");
    defer allocator.free(max_doc);
    @memcpy(max_doc[0..doc_prefix.len], doc_prefix);
    const max_body = max_doc[doc_prefix.len .. max_doc.len - doc_suffix.len];
    var max_i: usize = 0;
    while (max_i + 1 < max_body.len) : (max_i += 2) {
        max_body[max_i] = '\\';
        max_body[max_i + 1] = '"';
    }
    if (max_i < max_body.len) max_body[max_i] = 'x';
    @memcpy(max_doc[max_doc.len - doc_suffix.len ..], doc_suffix);
    var max_aw: std.Io.Writer.Allocating = .init(allocator);
    defer max_aw.deinit();
    std.json.Stringify.value(protocol.Request{
        .cmd = "panel-show",
        .session = "panel-stage",
        .name = "max-boundary",
        .target = "tab",
        .document = max_doc,
    }, .{}, &max_aw.writer) catch fail("maximum panel request encoding");
    const max_line = max_aw.written();
    if (max_line.len <= (1 << 20) or max_line.len > protocol.MAX_LINE or max_line.len > wire.PANEL_JSON_MAX)
        fail("maximum panel request did not exercise the expanded transport boundary");
    requester_a.sendPanelRequest(41, max_line) catch fail("maximum panel relay request send");
    const max_call = recvEnvelope(allocator, &older_gui, .panel_request, 5_000);
    defer allocator.free(max_call.json);
    var max_parsed = protocol.parseRequest(allocator, max_call.json) catch fail("maximum relayed request parse");
    defer max_parsed.deinit();
    if (max_parsed.value.document == null or max_parsed.value.document.?.len != max_doc.len or
        !std.mem.eql(u8, max_parsed.value.document.?, max_doc))
        fail("maximum panel document changed through the real relay");
    older_gui.sendPanelReply(max_call.id, "{\"ok\":true,\"panel_id\":90}") catch fail("maximum panel relay reply");
    const max_reply = recvEnvelope(allocator, &requester_a, .panel_reply, 5_000);
    defer allocator.free(max_reply.json);
    if (max_reply.id != 41 or std.mem.indexOf(u8, max_reply.json, "\"panel_id\":90") == null)
        fail("maximum panel relay did not restore the caller response");

    requester_a.sendPanelRequest(42, "{\"cmd\":\"smoke\",\"op\":\"oldest\"}") catch fail("oldest request");
    const routed = recvEnvelope(allocator, &older_gui, .panel_request, 5_000);
    defer allocator.free(routed.json);
    if (routed.id == 42) fail("daemon did not rewrite the caller correlation id");
    expectNoFrame(&newer_gui, .panel_request, 250, "panel request was broadcast to a second GUI");

    newer_gui.sendPanelReply(routed.id, "{\"ok\":true,\"tag\":\"spoof\"}") catch fail("spoof reply send");
    (newer_gui.recvExpectFor(&.{.err}, 5_000) catch fail("wrong responder was not rejected")).deinit(allocator);
    older_gui.sendPanelReply(routed.id, "{\"ok\":true,\"tag\":\"oldest\"}") catch fail("presenter reply send");
    const restored = recvEnvelope(allocator, &requester_a, .panel_reply, 5_000);
    defer allocator.free(restored.json);
    if (restored.id != 42 or std.mem.indexOf(u8, restored.json, "oldest") == null)
        fail("presenter result did not restore the caller id");

    // A malformed reply with a decodable route id must fail the requester
    // now, not leave it waiting for the route timeout.
    requester_a.sendPanelRequest(43, "{\"cmd\":\"smoke\",\"op\":\"malformed-reply\"}") catch fail("malformed request");
    const malformed_call = recvEnvelope(allocator, &older_gui, .panel_request, 5_000);
    defer allocator.free(malformed_call.json);
    var malformed: [wire.PANEL_ENVELOPE_HEADER]u8 = undefined;
    std.mem.writeInt(u64, &malformed, malformed_call.id, .little);
    older_gui.sendFrame(.panel_reply, &malformed) catch fail("malformed reply send");
    const malformed_result = recvEnvelope(allocator, &requester_a, .panel_reply, 5_000);
    defer allocator.free(malformed_result.json);
    if (malformed_result.id != 43 or
        std.mem.indexOf(u8, malformed_result.json, "delivery is uncertain") == null or
        std.mem.indexOf(u8, malformed_result.json, "NOT resent") == null or
        std.mem.indexOf(u8, malformed_result.json, "\"failure_class\":\"uncertain_delivery\"") == null)
        fail("malformed presenter reply did not resolve its route immediately");
    (older_gui.recvExpectFor(&.{.err}, 5_000) catch fail("malformed presenter was not refused")).deinit(allocator);
    // A structurally broken presenter loses panel capability for that
    // connection. Recovery requires fresh presenters; no pending call is
    // replayed through either replacement.
    older_gui.deinit();
    newer_gui.deinit();
    older_gui = attachPresenter(allocator, sock_path, "panel-stage");
    newer_gui = attachPresenter(allocator, sock_path, "panel-stage");

    var requester_b = client_mod.connectPanelRequester(allocator, sock_path, "panel-stage", 5_000) catch
        fail("second panel-only requester attach");
    defer requester_b.deinit();
    waitPeerRoster(&older_gui, 4, 2, 2, 5_000);

    requester_a.sendPanelRequest(77, "{\"cmd\":\"smoke\",\"who\":\"a\"}") catch fail("caller A request");
    requester_b.sendPanelRequest(77, "{\"cmd\":\"smoke\",\"who\":\"b\"}") catch fail("caller B request");
    const call_one = recvEnvelope(allocator, &older_gui, .panel_request, 5_000);
    defer allocator.free(call_one.json);
    const call_two = recvEnvelope(allocator, &older_gui, .panel_request, 5_000);
    defer allocator.free(call_two.json);
    if (call_one.id == call_two.id) fail("two requesters collided on one daemon route id");
    const route_a = if (std.mem.indexOf(u8, call_one.json, "\"a\"") != null) call_one.id else call_two.id;
    const route_b = if (route_a == call_one.id) call_two.id else call_one.id;
    older_gui.sendPanelReply(route_b, "{\"ok\":true,\"result\":\"b\"}") catch fail("caller B reply");
    older_gui.sendPanelReply(route_a, "{\"ok\":true,\"result\":\"a\"}") catch fail("caller A reply");
    const result_a = recvEnvelope(allocator, &requester_a, .panel_reply, 5_000);
    defer allocator.free(result_a.json);
    const result_b = recvEnvelope(allocator, &requester_b, .panel_reply, 5_000);
    defer allocator.free(result_b.json);
    if (result_a.id != 77 or std.mem.indexOf(u8, result_a.json, "\"a\"") == null)
        fail("requester A received a collided result");
    if (result_b.id != 77 or std.mem.indexOf(u8, result_b.json, "\"b\"") == null)
        fail("requester B received a collided result");

    _ = c.usleep(300_000);
    if (!listHas(allocator, &owner, "panel-stage", 2)) fail("panel-stage missing from list");

    // The shell proves both ownership coordinates came from the daemon. In
    // broker mode the socket must be the broker listener, not control_fd.
    newer_gui.sendJson(.log_get, .{ .tail = @as(u32, 100), .max_chars = @as(u32, 4096) }) catch fail("environment log request");
    const log_frame = newer_gui.recvExpectFor(&.{.log_data}, 5_000) catch fail("environment log reply");
    var expected_buf: [512]u8 = undefined;
    const expected = std.fmt.bufPrint(&expected_buf, "MUXENV=[{s}] SESSION=[panel-stage]", .{sock_path}) catch fail("environment expectation too long");
    if (std.mem.indexOf(u8, log_frame.payload, expected) == null) fail("PTY did not receive the exact owning SKETERM_MUX_SOCKET");
    log_frame.deinit(allocator);

    requester_a.sendPanelRequest(88, "{\"cmd\":\"smoke\",\"op\":\"disconnect\"}") catch fail("disconnect request");
    const disconnect_call = recvEnvelope(allocator, &older_gui, .panel_request, 5_000);
    defer allocator.free(disconnect_call.json);
    older_gui.deinit();
    older_live = false;
    const disconnected = recvEnvelope(allocator, &requester_a, .panel_reply, 5_000);
    defer allocator.free(disconnected.json);
    if (disconnected.id != 88 or std.mem.indexOf(u8, disconnected.json, "disconnected") == null)
        fail("presenter disconnect did not fail its pending route");
    if (std.mem.indexOf(u8, disconnected.json, "\"failure_class\":\"uncertain_delivery\"") == null or
        std.mem.indexOf(u8, disconnected.json, "\"resend_safe\":false") == null)
        fail("presenter disconnect lacked machine-readable uncertainty");

    // There is no requester-to-presenter binding: with the first presenter
    // gone, the SAME requester attachment's very next call selects whichever
    // panel-capable attachment is present now — no reconnect, no memory of
    // the dead presenter.
    requester_a.sendPanelRequest(90, "{\"cmd\":\"smoke\",\"op\":\"survivor\"}") catch fail("surviving-presenter request");
    const survivor_call = recvEnvelope(allocator, &newer_gui, .panel_request, 5_000);
    defer allocator.free(survivor_call.json);
    if (survivor_call.id == disconnect_call.id)
        fail("a presenter failover reused a stale daemon route id");
    newer_gui.sendPanelReply(survivor_call.id, "{\"ok\":true,\"tag\":\"survivor\"}") catch fail("surviving-presenter reply");
    const survivor_reply = recvEnvelope(allocator, &requester_a, .panel_reply, 5_000);
    defer allocator.free(survivor_reply.json);
    if (survivor_reply.id != 90 or std.mem.indexOf(u8, survivor_reply.json, "survivor") == null)
        fail("the same requester attachment did not fail over to the surviving presenter");

    var abandoned = client_mod.connectPanelRequester(allocator, sock_path, "panel-stage", 5_000) catch
        fail("abandoned requester attach");
    abandoned.sendPanelRequest(93, "{\"cmd\":\"smoke\",\"op\":\"abandon\"}") catch fail("abandoned request");
    const abandoned_call = recvEnvelope(allocator, &newer_gui, .panel_request, 5_000);
    defer allocator.free(abandoned_call.json);
    abandoned.deinit();
    _ = c.usleep(300_000);
    newer_gui.sendPanelReply(abandoned_call.id, "{\"ok\":true}") catch fail("stale route reply send");
    (newer_gui.recvExpectFor(&.{.err}, 5_000) catch fail("requester disconnect did not remove its route")).deinit(allocator);

    // The child keeps its spawn-time SKETERM_SESSION after any number of
    // user-visible renames. Exactly two names attach: the CURRENT one and the
    // immutable spawn name. There is no alias history, so an intermediate name
    // a rename moved away from is neither attachable nor reserved.
    owner.sendJson(.rename, .{ .name = "panel-stage", .new_name = "panel-stage-middle" }) catch fail("first rename send");
    (owner.recvExpectFor(&.{.ok}, 5_000) catch fail("first rename reply")).deinit(allocator);
    owner.sendJson(.rename, .{ .name = "panel-stage-middle", .new_name = "panel-stage-current" }) catch fail("second rename send");
    (owner.recvExpectFor(&.{.ok}, 5_000) catch fail("second rename reply")).deinit(allocator);
    _ = c.usleep(300_000);
    if (!listIdentityIs(allocator, &owner, "panel-stage-current", "panel-stage"))
        fail("list lost the current or immutable origin session name");

    // The immutable spawn name stays reserved for the session's lifetime; an
    // intermediate name a rename moved away from does not.
    expectNameReserved(allocator, &owner, "panel-stage");

    var inherited = client_mod.connectPanelRequester(allocator, sock_path, "panel-stage", 5_000) catch
        fail("spawn-time identity no longer attaches after multiple renames");
    defer inherited.deinit();
    inherited.sendPanelRequest(91, "{\"cmd\":\"smoke\",\"op\":\"origin-alias\"}") catch fail("origin-alias panel request");
    const inherited_call = recvEnvelope(allocator, &newer_gui, .panel_request, 5_000);
    defer allocator.free(inherited_call.json);
    newer_gui.sendPanelReply(inherited_call.id, "{\"ok\":true,\"tag\":\"origin-alias\"}") catch fail("origin-alias panel reply");
    const inherited_reply = recvEnvelope(allocator, &inherited, .panel_reply, 5_000);
    defer allocator.free(inherited_reply.json);
    if (inherited_reply.id != 91 or std.mem.indexOf(u8, inherited_reply.json, "origin-alias") == null)
        fail("panel relay did not survive attachment through immutable origin identity");

    // The immutable spawn name keeps working; the intermediate name a rename
    // moved away from does not. There is deliberately no alias history.
    if (client_mod.connectPanelRequester(allocator, sock_path, "panel-stage-middle", 5_000)) |stale| {
        var attached = stale;
        attached.deinit();
        fail("a name the session was renamed away from still attached");
    } else |_| {}

    // A panel-only attachment must not keep a TTL session occupied.
    owner.sendJson(.spawn, .{
        .name = "panel-ttl",
        .argv = [_][]const u8{ "sleep", "30" },
        .rows = @as(u16, 24),
        .cols = @as(u16, 80),
        .ttl_secs = @as(u32, 1),
    }) catch fail("ttl spawn send");
    (owner.recvExpectFor(&.{.ok}, 5_000) catch fail("ttl spawn reply")).deinit(allocator);
    var ttl_requester = client_mod.connectPanelRequester(allocator, sock_path, "panel-ttl", 5_000) catch
        fail("ttl panel-only attach");
    defer ttl_requester.deinit();
    _ = c.usleep(1_800_000);
    if (listHas(allocator, &owner, "panel-ttl", null)) fail("panel-only requester kept display TTL occupied");

    // Session teardown after presenter delivery must resolve the route before
    // worker/monolith teardown closes the requester connection.
    requester_a.sendPanelRequest(92, "{\"cmd\":\"smoke\",\"op\":\"session-teardown\"}") catch fail("teardown panel request");
    const teardown_call = recvEnvelope(allocator, &newer_gui, .panel_request, 5_000);
    defer allocator.free(teardown_call.json);
    owner.sendJson(.kill, .{ .name = "panel-stage" }) catch fail("cleanup kill send");
    (owner.recvExpectFor(&.{.ok}, 5_000) catch fail("cleanup kill reply")).deinit(allocator);
    const teardown = recvEnvelope(allocator, &requester_a, .panel_reply, 5_000);
    defer allocator.free(teardown.json);
    if (teardown.id != 92 or std.mem.indexOf(u8, teardown.json, "session closed") == null or
        std.mem.indexOf(u8, teardown.json, "\"failure_class\":\"uncertain_delivery\"") == null or
        std.mem.indexOf(u8, teardown.json, "\"resend_safe\":false") == null)
        fail("session teardown lacked correlated machine-readable uncertainty");
    std.debug.print("smoke-panel-relay: correlated relay + attached asset read + panel-only isolation ok\n", .{});
}
