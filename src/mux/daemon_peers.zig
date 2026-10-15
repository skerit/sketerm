//! Peer messaging on the broker: the `peer_*` frame handlers over the
//! `peermail.Store`, keyed by `Client.id` (never a `*Client`: reap
//! phase 2 deregisters a dying connection by id). A worker holds no
//! peers and refuses every `peer_*` frame, naming why.
//!
//! Federation: on a hub (`peer_hub`) or a call-in member
//! (`peer_hub_domain`) the broker also owns the `peerlink.Links` it dials;
//! a link dialed TO this broker arrives as a client that says
//! `peer_hub_hello` (on a member) or `peer_member_hello` (on a hub, from an
//! inbound domain). The socket is private to the user, so that client is
//! trusted like any same-user client.
//!
//! Subjects: the broker tells each session's worker which peer runs in
//! that session's process tree (`peerInTree`, the ancestry walk
//! `sketerm mcp hook` uses) and its subject, as control `'S'`; the worker
//! pushes it to its viewers as `session_meta` `peer`. A viewer's
//! `peer_subject` comes back the other way as control `'P'`.

const std = @import("std");
const c = @import("../c.zig").c;
const log = @import("log.zig");
const peermail = @import("peermail.zig");
const peerlink = @import("peerlink.zig");
const daemon_control = @import("daemon_control.zig");
const platform = @import("../util/platform.zig");
const agentsline = @import("../ipc/agentsline.zig");
const env = @import("../util/env.zig");
const xdg = @import("../util/xdg.zig");
const clock = @import("../util/clock.zig");
const Config = @import("../config.zig").Config;
const wire = @import("wire.zig");
const dmod = @import("daemon.zig");
const Daemon = dmod.Daemon;
const Client = dmod.Client;
const Worker = dmod.Worker;

/// Rigs override the mail TTL in milliseconds (config is in hours).
pub const TTL_ENV = "SKETERM_MUX_PEER_TTL_MS";
/// Rigs override this host's name in peer addresses (default: gethostname).
pub const HOST_ENV = "SKETERM_MUX_PEER_HOST";
/// The TTL sweep runs at most this often (monotonic ms).
pub const SWEEP_EVERY_MS: i64 = 1000;

/// The broker's peer state; the store exists once the first peer frame
/// arrived or the broker started serving.
pub const State = struct {
    store: ?peermail.Store = null,
    /// Hub only: the links to the federated domains.
    links: ?peerlink.Links = null,
    last_sweep_ms: i64 = 0,
    /// Broker: what each worker was last told its session's peer is.
    told: std.ArrayList(Told) = .empty,
    /// Broker: the store's `roster_gen` and the workers' signature the
    /// last `remap` saw.
    mapped_gen: u32 = 0,
    mapped_sig: u64 = 0,
    /// Worker: the peer in this session's tree, as the broker last said
    /// (owned); null = never said.
    session_peer: ?SessionPeer = null,
};

/// The `'S'` control payload, also the `session_meta` `peer` member.
pub const SessionPeer = peermail.SessionPeer;

const Told = struct { worker_pid: c.pid_t, json: []u8 };

/// Load the durable mailboxes; a broker calls this before serving.
pub fn start(d: *Daemon) void {
    _ = ensure(d);
}

pub fn deinit(d: *Daemon) void {
    if (d.peers.links) |*l| l.deinit();
    d.peers.links = null;
    if (d.peers.store) |*s| s.deinit();
    d.peers.store = null;
    for (d.peers.told.items) |tl| d.allocator.free(tl.json);
    d.peers.told.deinit(d.allocator);
    freeSessionPeer(d);
}

fn freeSessionPeer(d: *Daemon) void {
    const sp = d.peers.session_peer orelse return;
    d.allocator.free(sp.address);
    d.allocator.free(sp.subject);
    d.peers.session_peer = null;
}

/// Connection `id` is going away (reap phase 2).
pub fn clientGone(d: *Daemon, id: u32) void {
    const s = if (d.peers.store) |*st| st else return;
    const now = clock.wallMs();
    s.deregister(id, now);
    if (d.peers.links) |*l| l.clientGone(id);
    s.connGone(id, now);
}

/// Expire queued mail past its TTL (called from reap, next to `ttlSweep`),
/// tick the links, send the presence the links are owed and tell the
/// workers whose session's peer changed.
pub fn sweep(d: *Daemon) void {
    const s = if (d.peers.store) |*st| st else return;
    const now = clock.nowMs();
    const wall = clock.wallMs();
    if (d.peers.links) |*l| l.tick(d, s, now, wall);
    s.tick(wall);
    const sig = workersSignature(d);
    if (s.roster_gen != d.peers.mapped_gen or sig != d.peers.mapped_sig) {
        d.peers.mapped_gen = s.roster_gen;
        d.peers.mapped_sig = sig;
        remap(d, s);
    }
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
    s.uplinkUp(cl.id, parsed.value, .inbound, clock.wallMs()) catch |e| return cl.queueErrFor(switch (e) {
        error.BadAddress => "peer_hub_hello: the hub's host or this host's name is not an address host",
        error.NotLinked, error.NotRegistered, error.OutOfMemory, error.NoEntropy => "peer_hub_hello failed on the broker",
    }, frame);
    log.info("peer federation: hub {s} linked, calling this host {s}", .{ parsed.value.host, parsed.value.as });
}

/// `peer_member_hello`: a call-in member's link announces itself. Accepted
/// only on a hub, for a `[domain.<host>] peers = true` with `peer_link =
/// inbound`; answered by `peer_hub_hello`, and from then on this
/// connection is that domain's link. A newer call-in replaces an older one.
pub fn handleMemberHello(d: *Daemon, cl: *Client, payload: []const u8) void {
    const frame = "peer_member_hello";
    const s = storeFor(d, cl, frame) orelse return;
    const links = (if (s.hub) (if (d.peers.links) |*l| l else null) else null) orelse
        return cl.queueErrFor("peer_member_hello: this daemon is no peer hub; a member calls in only to a hub", frame);
    var parsed = std.json.parseFromSlice(peermail.MemberHello, d.allocator, payload, .{ .ignore_unknown_fields = true }) catch
        return cl.queueErrFor("bad peer_member_hello request", frame);
    defer parsed.deinit();
    const l = links.callin(parsed.value.host) catch |e| return cl.queueErrFor(switch (e) {
        error.UnknownDomain => "peer_member_hello: this hub has no [domain.<host>] peers = true for that host",
        error.NotInbound => "peer_member_hello: that host's [domain] is peer_link = outbound here; the hub dials it, it never calls in",
    }, frame);
    // The hello goes out before `up` relays the domain's queued mail.
    cl.queueJson(.peer_hub_hello, peermail.HubHello{ .host = s.host, .as = l.domain });
    const old = links.acceptCallin(l, cl.id, s, clock.wallMs());
    if (old != 0) if (liveClient(d, old)) |gone| {
        gone.dead = true;
    };
}

/// `peer_hub_relay` (on a member) or `peer_member_relay` (on a hub): one
/// federation item, only on the connection that completed the hello.
pub fn handleRelay(d: *Daemon, cl: *Client, ftype: wire.FrameType, payload: []const u8) void {
    const frame = @tagName(ftype);
    const s = storeFor(d, cl, frame) orelse return;
    if (ftype != peerlink.relayFrame(!s.hub)) return cl.queueErrFor(if (s.hub)
        "peer_hub_relay: this daemon is a peer hub; its members send peer_member_relay"
    else
        "peer_member_relay: this daemon is no peer hub; a hub sends peer_hub_relay", frame);
    var parsed = std.json.parseFromSlice(peermail.Relay, d.allocator, payload, .{ .ignore_unknown_fields = true }) catch
        return cl.queueErrFor("bad relay request", frame);
    defer parsed.deinit();
    s.relayIn(cl.id, parsed.value, clock.wallMs()) catch |e| return cl.queueErrFor(switch (e) {
        error.NotLinked => if (s.hub) "peer_member_relay before peer_member_hello on this connection" else "peer_hub_relay before peer_hub_hello on this connection",
        error.BadAddress, error.NotRegistered, error.OutOfMemory, error.NoEntropy => "a relay failed on the broker",
    }, frame);
}

/// `peer_subject`. On a broker connection: ask, set or clear the subject
/// of `address`, answered by `peer_subject_reply`. On a worker (an
/// attached viewer): handed to the broker for the peer in this session's
/// tree; the `session_meta` push that follows is the answer.
pub fn handleSubject(d: *Daemon, cl: *Client, payload: []const u8) void {
    const frame = "peer_subject";
    var parsed = std.json.parseFromSlice(peermail.SubjectReq, d.allocator, payload, .{ .ignore_unknown_fields = true }) catch
        return cl.queueErrFor("bad peer_subject request", frame);
    defer parsed.deinit();
    const q = parsed.value;
    if (d.isWorker()) {
        if (q.address.len > 0) return cl.queueErrFor("peer_subject on an attached session names no address", frame);
        if (cl.attached == null) return cl.queueErrFor("peer_subject: not attached", frame);
        if (!cl.actsOnSession()) return cl.queueErrFor("a view-only attachment cannot set the subject", frame);
        const subject = q.subject orelse return;
        peermail.checkSubject(subject) catch |e| return cl.queueErrFor(peermail.subjectRefusal(e), frame);
        var buf: [1024]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        w.writeByte('P') catch return;
        std.json.Stringify.value(peermail.SubjectReq{ .subject = subject }, .{}, &w) catch return cl.queueErrFor("peer_subject: the subject does not fit", frame);
        if (!daemon_control.controlSend(d.control_fd, w.buffered(), -1)) cl.queueErrFor("peer_subject could not reach the broker", frame);
        return;
    }
    const s = storeFor(d, cl, frame) orelse return;
    if (q.address.len == 0) return cl.queueErrFor("peer_subject needs the peer's address on a connection that is not attached", frame);
    var reply = peermail.SubjectReply{ .req = q.req, .address = q.address, .found = s.knows(q.address) };
    if (q.subject) |subject| s.setSubject(q.address, subject) catch |e| switch (e) {
        error.SubjectTooLong, error.SubjectNotText => reply.refused = peermail.subjectRefusal(@errorCast(e)),
        error.UnknownAddress => {},
        error.OutOfMemory => return cl.queueErrFor("peer_subject failed on the broker", frame),
    };
    reply.subject = s.subjectOf(q.address);
    cl.queueJson(.peer_subject_reply, reply);
}

/// Broker: control `'P'` from worker `w`, a viewer's `peer_subject`.
pub fn workerSubject(d: *Daemon, w: *Worker, payload: []const u8) void {
    const s = ensure(d) orelse return;
    var parsed = std.json.parseFromSlice(peermail.SubjectReq, d.allocator, payload, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();
    const subject = parsed.value.subject orelse return;
    var arena: std.heap.ArenaAllocator = .init(d.allocator);
    defer arena.deinit();
    const live = livePeers(arena.allocator(), s) catch return;
    const i = peerInTree(live, w.child_pid, platform.parentOf) orelse
        return log.info("peer_subject: no peer runs in session '{s}'", .{w.name});
    s.setSubject(live[i].address, subject) catch |e| log.warn("peer_subject for {s} in session '{s}' refused: {s}", .{ live[i].address, w.name, @errorName(e) });
}

/// Worker: control `'S'`, the peer in this session's tree; every viewer hears it.
pub fn workerApplyPeer(d: *Daemon, payload: []const u8) void {
    var parsed = std.json.parseFromSlice(SessionPeer, d.allocator, payload, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();
    const address = d.allocator.dupe(u8, parsed.value.address) catch return;
    const subject = d.allocator.dupe(u8, parsed.value.subject) catch {
        d.allocator.free(address);
        return;
    };
    freeSessionPeer(d);
    d.peers.session_peer = .{ .address = address, .subject = subject };
    if (d.sessions.items.len == 0) return;
    const session = d.sessions.items[0];
    for (d.clients.items) |cl| {
        if (!cl.dead and Daemon.terminalViewer(cl, session)) queueSessionPeer(d, cl);
    }
}

/// Worker: tell an attaching viewer the session's peer, once known.
pub fn queueSessionPeer(d: *Daemon, cl: *Client) void {
    const sp = d.peers.session_peer orelse return;
    cl.queueJson(.session_meta, .{ .peer = sp });
}

/// The index of the peer whose process runs nearest below `root` (the
/// process itself counts), null when none runs in that tree.
pub fn peerInTree(peers: []const peermail.PeerInfo, root: c.pid_t, parentOf: *const fn (c.pid_t) ?c.pid_t) ?usize {
    if (root <= 0) return null;
    var best: ?usize = null;
    var best_hops: usize = std.math.maxInt(usize);
    for (peers, 0..) |p, i| {
        if (p.pid <= 0) continue;
        const hops: usize = if (p.pid == root) 0 else blk: {
            var buf: [agentsline.MAX_ANCESTRY]c.pid_t = undefined;
            const chain = agentsline.ancestry(&buf, p.pid, parentOf);
            const k = std.mem.indexOfScalar(c.pid_t, chain, root) orelse continue;
            break :blk k + 1;
        };
        if (hops < best_hops) {
            best = i;
            best_hops = hops;
        }
    }
    return best;
}

/// The live peers of this host (no federated entries).
fn livePeers(arena: std.mem.Allocator, s: *peermail.Store) error{OutOfMemory}![]const peermail.PeerInfo {
    var out: std.ArrayList(peermail.PeerInfo) = .empty;
    for (try s.list(arena)) |p| {
        if (p.live and p.via_host.len == 0) try out.append(arena, p);
    }
    return out.items;
}

/// What `remap` depends on besides the store: which workers run which child.
fn workersSignature(d: *Daemon) u64 {
    var h = std.hash.Wyhash.init(0);
    for (d.workers.items) |w| {
        const pids = [3]i64{ w.pid, w.child_pid, @intFromBool(w.dead) };
        h.update(std.mem.asBytes(&pids));
    }
    return h.final();
}

/// Tell every worker whose session's peer (or its subject) changed.
fn remap(d: *Daemon, s: *peermail.Store) void {
    var arena_state: std.heap.ArenaAllocator = .init(d.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const live = livePeers(a, s) catch return;
    for (d.workers.items) |w| {
        if (w.dead or w.child_pid <= 0) continue;
        const sp: SessionPeer = if (peerInTree(live, w.child_pid, platform.parentOf)) |i| .{ .address = live[i].address, .subject = live[i].subject } else .{};
        const json = std.json.Stringify.valueAlloc(a, sp, .{}) catch continue;
        const ti = toldIndex(d, w.pid);
        if (ti) |k| {
            if (std.mem.eql(u8, d.peers.told.items[k].json, json)) continue;
        } else if (sp.address.len == 0) continue;
        const msg = a.alloc(u8, json.len + 1) catch continue;
        msg[0] = 'S';
        @memcpy(msg[1..], json);
        if (!daemon_control.controlSend(w.control_fd, msg, -1)) continue;
        const owned = d.allocator.dupe(u8, json) catch continue;
        if (ti) |k| {
            d.allocator.free(d.peers.told.items[k].json);
            d.peers.told.items[k].json = owned;
        } else d.peers.told.append(d.allocator, .{ .worker_pid = w.pid, .json = owned }) catch d.allocator.free(owned);
    }
    // Forget workers that are gone.
    var i: usize = 0;
    while (i < d.peers.told.items.len) {
        const pid = d.peers.told.items[i].worker_pid;
        const alive = for (d.workers.items) |w| {
            if (w.pid == pid and !w.dead) break true;
        } else false;
        if (alive) {
            i += 1;
            continue;
        }
        d.allocator.free(d.peers.told.items[i].json);
        _ = d.peers.told.swapRemove(i);
    }
}

fn toldIndex(d: *Daemon, worker_pid: c.pid_t) ?usize {
    for (d.peers.told.items, 0..) |tl, i| if (tl.worker_pid == worker_pid) return i;
    return null;
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
    const host: []const u8 = env.nonEmpty(HOST_ENV) orelse if (c.gethostname(&host_buf, host_buf.len) == 0)
        std.mem.sliceTo(&host_buf, 0)
    else
        "";
    var cfg = Config.load(d.allocator);
    defer cfg.deinit();
    // A hub or a call-in member, never both.
    var both = false;
    const callin = cfg.peerHubDomain() catch |e| blk: {
        switch (e) {
            error.HubAndCallin => {
                both = true;
                log.warn("peer federation: peer_hub and peer_hub_domain are both set; a hub never calls in to another, so federation is off", .{});
            },
            error.NoSuchDomain => log.warn("peer federation: peer_hub_domain = {s} names no [domain.<name>] with a host; nothing is dialed", .{cfg.peer_hub_domain}),
        }
        break :blk null;
    };
    // The hub's own peers are `<host>/name` elsewhere: no host, no hub.
    const hub = cfg.peer_hub and !both and blk: {
        @import("../ipc/peeraddr.zig").validHost(host) catch {
            log.warn("peer federation: this host's name \"{s}\" is not an address host; peer_hub is ignored", .{host});
            break :blk false;
        };
        break :blk true;
    };
    if (hub) {
        d.peers.links = peerlink.Links.init(d.allocator, &cfg, host) catch blk: {
            log.warn("peer federation: out of memory reading the domains", .{});
            break :blk null;
        };
    } else if (callin) |dom| {
        d.peers.links = peerlink.Links.initCallin(d.allocator, dom) catch blk: {
            log.warn("peer federation: out of memory reading peer_hub_domain", .{});
            break :blk null;
        };
    }
    var arena: std.heap.ArenaAllocator = .init(d.allocator);
    defer arena.deinit();
    const links: ?*peerlink.Links = if (hub) (if (d.peers.links) |*l| l else null) else null;
    const domains: []const []const u8 = if (links) |l| (l.domains(arena.allocator()) catch &.{}) else &.{};
    const inbound: []const []const u8 = if (links) |l| (l.inbound(arena.allocator()) catch &.{}) else &.{};
    d.peers.store = peermail.Store.init(d.allocator, .{
        .dir = dir,
        .host = host,
        .ttl_ms = ttlMs(&cfg),
        .hub = hub,
        .domains = domains,
        .inbound = inbound,
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
    if (callin) |dom| log.info("peer federation: call-in member {s}, dialing hub domain {s}", .{ host, dom.name });
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
            // A link dialed to this broker: a hub's (on a member) or a
            // call-in member's (on a hub).
            const cl = liveClient(d, conn) orelse return false;
            cl.queueJson(peerlink.relayFrame(if (d.peers.store) |*s| s.hub else false), v);
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

fn fakeParent(pid: c.pid_t) ?c.pid_t {
    // A pane shell (10) runs claude (20), which runs two servers (30, 31);
    // another pane (50) runs a follower (60) under a subshell (55).
    return switch (pid) {
        30, 31 => 20,
        20 => 10,
        60 => 55,
        55 => 50,
        10, 50 => 1,
        else => null,
    };
}

test "a pane's peer is the nearest one in its process tree; a pane without one has none" {
    const t = std.testing;
    const peers = [_]peermail.PeerInfo{
        .{ .address = "far", .pid = 60 },
        .{ .address = "Arcana", .pid = 30 },
        .{ .address = "second", .pid = 31 },
        .{ .address = "unknown-pid", .pid = 0 },
    };
    // 1. The pane shell 10: both servers are two hops below; the first wins.
    try t.expectEqual(@as(?usize, 1), peerInTree(&peers, 10, fakeParent));
    // 2. The other pane finds its follower through the subshell.
    try t.expectEqual(@as(?usize, 0), peerInTree(&peers, 50, fakeParent));
    // 3. A process that is itself the peer is its own nearest.
    try t.expectEqual(@as(?usize, 2), peerInTree(&peers, 31, fakeParent));
    // 4. A pane nothing runs in, and an unknown child pid, have none.
    try t.expectEqual(@as(?usize, null), peerInTree(&peers, 77, fakeParent));
    try t.expectEqual(@as(?usize, null), peerInTree(&peers, 0, fakeParent));
}
