//! Peer messaging on the broker: the `peer_*` frame handlers over the
//! `peermail.Store`, keyed by `Client.id` (never a `*Client`: reap
//! phase 2 deregisters a dying connection by id). A worker holds no
//! peers and refuses every `peer_*` frame, naming why.
//!
//! Federation: on a hub (`peer_hub`) the broker also owns the
//! `peerlink.Links` to its domains; on any other broker a hub's link
//! arrives as a client that says `peer_hub_hello`. The socket is private
//! to the user, so that client is trusted like any same-user client.

const std = @import("std");
const c = @import("../c.zig").c;
const log = @import("log.zig");
const peermail = @import("peermail.zig");
const peerlink = @import("peerlink.zig");
const env = @import("../util/env.zig");
const xdg = @import("../util/xdg.zig");
const clock = @import("../util/clock.zig");
const Config = @import("../config.zig").Config;
const dmod = @import("daemon.zig");
const Daemon = dmod.Daemon;
const Client = dmod.Client;

/// Rigs override the mail TTL in milliseconds (config is in hours).
pub const TTL_ENV = "SKETERM_MUX_PEER_TTL_MS";
/// The TTL sweep runs at most this often (monotonic ms).
pub const SWEEP_EVERY_MS: i64 = 1000;

/// The broker's peer state; the store exists once the first peer frame
/// arrived or the broker started serving.
pub const State = struct {
    store: ?peermail.Store = null,
    /// Hub only: the links to the federated domains.
    links: ?peerlink.Links = null,
    last_sweep_ms: i64 = 0,
};

/// Load the durable mailboxes; a broker calls this before serving.
pub fn start(d: *Daemon) void {
    _ = ensure(d);
}

pub fn deinit(d: *Daemon) void {
    if (d.peers.links) |*l| l.deinit();
    d.peers.links = null;
    if (d.peers.store) |*s| s.deinit();
    d.peers.store = null;
}

/// Connection `id` is going away (reap phase 2).
pub fn clientGone(d: *Daemon, id: u32) void {
    const s = if (d.peers.store) |*st| st else return;
    const now = clock.wallMs();
    s.deregister(id, now);
    s.connGone(id, now);
}

/// Expire queued mail past its TTL (called from reap, next to `ttlSweep`),
/// tick the links and send the presence the links are owed.
pub fn sweep(d: *Daemon) void {
    const s = if (d.peers.store) |*st| st else return;
    const now = clock.nowMs();
    const wall = clock.wallMs();
    if (d.peers.links) |*l| l.tick(d, s, now, wall);
    s.tick(wall);
    if (now - d.peers.last_sweep_ms < SWEEP_EVERY_MS) return;
    d.peers.last_sweep_ms = now;
    s.sweep(wall);
}

/// Append the links' pollfds; @return how many (serve them with `servicePoll`).
pub fn appendPoll(d: *Daemon, fds: *std.ArrayList(c.struct_pollfd)) error{OutOfMemory}!usize {
    const l = if (d.peers.links) |*ll| ll else return 0;
    return l.appendPoll(fds);
}

/// Serve the pollfds `appendPoll` added this tick.
pub fn servicePoll(d: *Daemon, polled: []const c.struct_pollfd) void {
    const l = if (d.peers.links) |*ll| ll else return;
    const s = if (d.peers.store) |*st| st else return;
    l.service(polled, s, clock.nowMs(), clock.wallMs());
}

/// `peer_register`: answered with an unsolicited `peer_list` (req 0)
/// carrying `self`, then the connection's pending mail is pushed.
pub fn handleRegister(d: *Daemon, cl: *Client, payload: []const u8) void {
    const s = storeFor(d, cl, "peer_register") orelse return;
    var parsed = std.json.parseFromSlice(peermail.RegisterReq, d.allocator, payload, .{ .ignore_unknown_fields = true }) catch
        return cl.queueErrFor("bad peer_register request", "peer_register");
    defer parsed.deinit();
    const now = clock.wallMs();
    s.register(cl.id, parsed.value, now) catch |e| return cl.queueErrFor(switch (e) {
        error.BadAddress => "peer_register: the address is not a peer name (1-64 of A-Za-z0-9._-, no host)",
        error.NotRegistered, error.OutOfMemory, error.NoEntropy => "peer_register failed on the broker",
    }, "peer_register");
    queueList(d, s, cl, 0);
    s.flush(cl.id, now);
}

/// `peer_list_req`: every known peer, echoing `req`.
pub fn handleListReq(d: *Daemon, cl: *Client, payload: []const u8) void {
    const s = storeFor(d, cl, "peer_list_req") orelse return;
    var parsed = std.json.parseFromSlice(peermail.ListReq, d.allocator, payload, .{ .ignore_unknown_fields = true }) catch
        return cl.queueErrFor("bad peer_list_req request", "peer_list_req");
    defer parsed.deinit();
    queueList(d, s, cl, parsed.value.req);
}

/// `peer_send`: the broker stamps `from` and `sent_ms` and answers the
/// outcome with `peer_send_reply`, echoing `req`.
pub fn handleSend(d: *Daemon, cl: *Client, payload: []const u8) void {
    const s = storeFor(d, cl, "peer_send") orelse return;
    var parsed = std.json.parseFromSlice(peermail.SendReq, d.allocator, payload, .{ .ignore_unknown_fields = true }) catch
        return cl.queueErrFor("bad peer_send request", "peer_send");
    defer parsed.deinit();
    var id_buf: [peermail.ID_LEN]u8 = undefined;
    const r = s.send(cl.id, parsed.value, clock.wallMs(), &id_buf) catch |e| return cl.queueErrFor(switch (e) {
        error.NotRegistered => "peer_send before peer_register",
        error.BadAddress, error.OutOfMemory, error.NoEntropy => "peer_send failed on the broker",
    }, "peer_send");
    if (r.deferred) return;
    cl.queueJson(.peer_send_reply, peermail.SendReply{
        .req = parsed.value.req,
        .id = r.id,
        .outcome = r.outcome,
        .reason = r.reason,
        .to_state = r.to_state,
    });
}

/// `peer_ack`: the ids leave this connection's mailbox; no reply.
pub fn handleAck(d: *Daemon, cl: *Client, payload: []const u8) void {
    const s = storeFor(d, cl, "peer_ack") orelse return;
    var parsed = std.json.parseFromSlice(peermail.AckReq, d.allocator, payload, .{ .ignore_unknown_fields = true }) catch
        return cl.queueErrFor("bad peer_ack request", "peer_ack");
    defer parsed.deinit();
    _ = s.ack(cl.id, parsed.value.ids);
}

/// `peer_hub_hello`: a hub's link announces itself. Accepted only on a
/// broker that is no hub; from then on this connection carries
/// `peer_hub_relay`.
pub fn handleHubHello(d: *Daemon, cl: *Client, payload: []const u8) void {
    const frame = "peer_hub_hello";
    const s = storeFor(d, cl, frame) orelse return;
    if (s.hub) return cl.queueErrFor("peer_hub_hello: this daemon is a peer hub; a hub never joins another", frame);
    var parsed = std.json.parseFromSlice(peermail.HubHello, d.allocator, payload, .{ .ignore_unknown_fields = true }) catch
        return cl.queueErrFor("bad peer_hub_hello request", frame);
    defer parsed.deinit();
    s.uplinkUp(cl.id, parsed.value, clock.wallMs()) catch |e| return cl.queueErrFor(switch (e) {
        error.BadAddress => "peer_hub_hello: the hub's host or this host's name is not an address host",
        error.NotLinked, error.NotRegistered, error.OutOfMemory, error.NoEntropy => "peer_hub_hello failed on the broker",
    }, frame);
    log.info("peer federation: hub {s} linked, calling this host {s}", .{ parsed.value.host, parsed.value.as });
}

/// `peer_hub_relay`: one federation item, only after `peer_hub_hello`.
pub fn handleHubRelay(d: *Daemon, cl: *Client, payload: []const u8) void {
    const frame = "peer_hub_relay";
    const s = storeFor(d, cl, frame) orelse return;
    var parsed = std.json.parseFromSlice(peermail.Relay, d.allocator, payload, .{ .ignore_unknown_fields = true }) catch
        return cl.queueErrFor("bad peer_hub_relay request", frame);
    defer parsed.deinit();
    s.relayIn(cl.id, parsed.value, clock.wallMs()) catch |e| return cl.queueErrFor(switch (e) {
        error.NotLinked => "peer_hub_relay before peer_hub_hello on this connection",
        error.BadAddress, error.NotRegistered, error.OutOfMemory, error.NoEntropy => "peer_hub_relay failed on the broker",
    }, frame);
}

fn storeFor(d: *Daemon, cl: *Client, frame: []const u8) ?*peermail.Store {
    if (d.isWorker()) {
        cl.queueErrFor("peers are served by the broker, not by a session worker", frame);
        return null;
    }
    return ensure(d) orelse {
        cl.queueErrFor("peer messaging could not start on this daemon", frame);
        return null;
    };
}

fn queueList(d: *Daemon, s: *peermail.Store, cl: *Client, req: u32) void {
    var arena: std.heap.ArenaAllocator = .init(d.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const peers = s.list(a) catch return cl.queueErrFor("peer list failed on the broker", "peer_list_req");
    const hosts = s.hostList(a) catch return cl.queueErrFor("peer list failed on the broker", "peer_list_req");
    const me = if (req == 0) (s.selfInfo(a, cl.id) catch null) else null;
    cl.queueJson(.peer_list, peermail.ListReply{ .req = req, .self = me, .peers = peers, .hosts = hosts, .federation = s.federation() });
}

fn ensure(d: *Daemon) ?*peermail.Store {
    if (d.peers.store) |*s| return s;
    if (d.isWorker()) return null;
    const dir = mailDirAlloc(d.allocator, d.sock_path) catch null;
    defer if (dir) |p| d.allocator.free(p);
    if (dir == null) log.warn("peermail: no state directory; mailboxes are kept in memory only", .{});
    var host_buf: [256]u8 = undefined;
    const host: []const u8 = if (c.gethostname(&host_buf, host_buf.len) == 0)
        std.mem.sliceTo(&host_buf, 0)
    else
        "";
    var cfg = Config.load(d.allocator);
    defer cfg.deinit();
    // The hub's own peers are `<host>/name` elsewhere: no host, no hub.
    const hub = cfg.peer_hub and blk: {
        @import("../ipc/peeraddr.zig").validHost(host) catch {
            log.warn("peer federation: this host's name \"{s}\" is not an address host; peer_hub is ignored", .{host});
            break :blk false;
        };
        break :blk true;
    };
    if (hub) d.peers.links = peerlink.Links.init(d.allocator, &cfg, host) catch blk: {
        log.warn("peer federation: out of memory reading the domains", .{});
        break :blk null;
    };
    var arena: std.heap.ArenaAllocator = .init(d.allocator);
    defer arena.deinit();
    const domains: []const []const u8 = if (d.peers.links) |*l| (l.domains(arena.allocator()) catch &.{}) else &.{};
    d.peers.store = peermail.Store.init(d.allocator, .{
        .dir = dir,
        .host = host,
        .ttl_ms = ttlMs(&cfg),
        .hub = hub,
        .domains = domains,
        .emit = .{ .ctx = d, .func = emit },
    }) catch {
        log.warn("peermail: out of memory starting the store", .{});
        if (d.peers.links) |*l| l.deinit();
        d.peers.links = null;
        return null;
    };
    const s = &d.peers.store.?;
    s.load();
    if (hub) log.info("peer federation: hub {s}, {d} domain(s)", .{ host, domains.len });
    return s;
}

/// `<state dir>/peermail/<socket namespace>`: rigs and private instance
/// daemons share the state home, so mailboxes are per listening socket.
pub fn mailDirAlloc(allocator: std.mem.Allocator, canonical_sock: []const u8) error{ NoStateDir, OutOfMemory }![]u8 {
    var buf: [4096]u8 = undefined;
    const state = xdg.stateDir(&buf) orelse return error.NoStateDir;
    return std.fmt.allocPrint(allocator, "{s}/peermail/{x:0>16}", .{ state, Daemon.socketNamespace(canonical_sock) });
}

/// The env override when set and valid, else config `peer_mail_ttl_hours`.
fn ttlMs(cfg: *const Config) i64 {
    if (env.nonEmpty(TTL_ENV)) |v| {
        if (parseTtlMs(v)) |ms| return ms;
        log.warn("peermail: ignoring {s}={s}: not a non-negative integer", .{ TTL_ENV, v });
    }
    return @as(i64, cfg.peer_mail_ttl_hours) * 3_600_000;
}

fn parseTtlMs(text: []const u8) ?i64 {
    const v = std.fmt.parseInt(i64, text, 10) catch return null;
    return if (v < 0) null else v;
}

fn emit(ctx: *anyopaque, conn: u32, out: peermail.Out) bool {
    const d: *Daemon = @ptrCast(@alignCast(ctx));
    switch (out) {
        .warn => |w| {
            log.warn("{s}", .{w});
            return false;
        },
        .deliver => |v| {
            const cl = liveClient(d, conn) orelse return false;
            cl.queueJson(.peer_deliver, v);
            return true;
        },
        .event => |v| {
            const cl = liveClient(d, conn) orelse return false;
            cl.queueJson(.peer_event, v);
            return true;
        },
        .reply => |v| {
            const cl = liveClient(d, conn) orelse return false;
            cl.queueJson(.peer_send_reply, v);
            return true;
        },
        .relay => |v| {
            if (conn >= peerlink.LINK_ID_BASE) return if (d.peers.links) |*l| l.queue(conn, v) else false;
            const cl = liveClient(d, conn) orelse return false;
            cl.queueJson(.peer_member_relay, v);
            return true;
        },
    }
}

fn liveClient(d: *Daemon, id: u32) ?*Client {
    for (d.clients.items) |cl| if (cl.id == id and !cl.dead) return cl;
    return null;
}

test "the TTL override accepts only non-negative integers" {
    const t = std.testing;
    try t.expectEqual(@as(?i64, 1500), parseTtlMs("1500"));
    try t.expectEqual(@as(?i64, 0), parseTtlMs("0"));
    try t.expectEqual(@as(?i64, null), parseTtlMs("-1"));
    try t.expectEqual(@as(?i64, null), parseTtlMs("6h"));
}
