//! Federation links: on the peer hub one per federated domain
//! (`[domain.<name>] peers = true` under `peer_hub = true`); on a call-in
//! member (`peer_hub_domain`) the one link it dials to its hub. Held by
//! the BROKER and polled in its loop, never in a worker.
//!
//! A dial is `Conn.connectRemote` (the same SSH/UDP/Tor transports every
//! client uses), which blocks, so it runs in a forked dialer child that
//! hands the welcomed socket back over a socketpair (SCM_RIGHTS) with one
//! JSON `DialResult`, then exits. The broker then speaks the link
//! nonblocking: a hub sends `peer_hub_hello`; a call-in member sends
//! `peer_member_hello` and waits for the hub's `peer_hub_hello` back.
//! Relays then flow as on any link: `peer_hub_relay` from the hub,
//! `peer_member_relay` from the member, all through `peermail.Store`.
//! A failed or dropped link redials after a 2-60 s `Backoff`; a daemon
//! without the flags it needs is marked unsupported and retried at the
//! ceiling. An inbound domain (`peer_link = inbound`) is never dialed:
//! its member's call-in arrives as a broker client (`callin`), which
//! then is that domain's link, through the same `up` step.

const std = @import("std");
const c = @import("../c.zig").c;
const log = @import("log.zig");
const muxclient = @import("client.zig");
const peermail = @import("peermail.zig");
const peeraddr = @import("../ipc/peeraddr.zig");
const wire = @import("wire.zig");
const scmrights = @import("../util/scmrights.zig");
const platform = @import("../util/platform.zig");
const Backoff = @import("../util/backoff.zig").Backoff;
const Config = @import("../config.zig").Config;
const Domain = @import("../config.zig").Domain;
const PeerLinkDirection = peermail.PeerLinkDirection;
const dmod = @import("daemon.zig");
const daemon_sessions = @import("daemon_sessions.zig");
const Daemon = dmod.Daemon;

/// Link connection ids start here, above every `Client.id`, so the
/// store's sink can tell a link from a client.
pub const LINK_ID_BASE: u32 = 0x8000_0000;
/// Redial waits.
pub const RECONNECT = Backoff{ .min_ms = 2_000, .max_ms = 60_000 };
/// A dialer still busy after this long (monotonic ms) is killed.
pub const DIAL_TIMEOUT_MS: i64 = 120_000;
/// A link whose unsent bytes pass this is dropped rather than buffered on.
pub const WBUF_MAX: usize = 8 << 20;

/// What the dialer child reports beside the socket.
pub const DialResult = struct {
    ok: bool = false,
    @"error": []const u8 = "",
    proto: u32 = 0,
    server_proto: u32 = 0,
    peers: bool = false,
    peer_federation: bool = false,
    peer_callin: bool = false,
    peer_slow_mail: bool = false,
};

pub const Verdict = enum { federate, unsupported, failed };

/// A welcomed daemon federates only when it advertises both flags; a
/// call-in member (`callin`) also needs its hub's `peer_callin`.
pub fn verdict(r: DialResult, callin: bool) Verdict {
    if (!r.ok) return .failed;
    if (!r.peers or !r.peer_federation) return .unsupported;
    if (callin and !r.peer_callin) return .unsupported;
    return .federate;
}

/// The frame a relay leaves this broker in, whichever side dialed.
pub fn relayFrame(hub: bool) wire.FrameType {
    return if (hub) .peer_hub_relay else .peer_member_relay;
}

/// `greeting`: a call-in member's dialed link waiting for the hub's hello.
const Phase = enum { waiting, dialing, greeting, up };

pub const Link = struct {
    domain: []u8,
    /// The dial spec; "" for an inbound domain, which is never dialed.
    spec: []u8,
    direction: PeerLinkDirection = .outbound,
    phase: Phase = .waiting,
    backoff: Backoff = RECONNECT,
    dial_pid: c.pid_t = -1,
    dial_fd: c_int = -1,
    dial_started_ms: i64 = 0,
    /// The dialed connection; null for an inbound link (its broker client
    /// is the connection, `conn_id` its client id).
    conn: ?muxclient.Conn = null,
    conn_id: u32 = 0,
    /// A queue failed inside the store's sink; dropped on the next tick.
    broken: bool = false,
    /// The far broker reads slow mail (its welcome or hello said so).
    far_slow: bool = false,
};

pub const Links = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(*Link) = .empty,
    next_id: u32 = 0,
    /// The hub's links, or a call-in member's one link to its hub.
    hub: bool,

    /// Hub: one link per federated domain of `cfg`. A domain whose name is
    /// no address host, or is this host's own name, is skipped with a warning.
    pub fn init(allocator: std.mem.Allocator, cfg: *const Config, self_host: []const u8) error{OutOfMemory}!Links {
        var self: Links = .{ .allocator = allocator, .hub = true };
        errdefer self.deinit();
        for (cfg.domains.items) |*dom| {
            if (!dom.peers) continue;
            switch (dom.peer_link) {
                .outbound => if (dom.host.len == 0) continue,
                .inbound => {},
            }
            peeraddr.validHost(dom.name) catch {
                log.warn("peer federation: [domain.{s}] is not usable in peer addresses (A-Za-z0-9._-); skipped", .{dom.name});
                continue;
            };
            if (std.mem.eql(u8, dom.name, self_host)) {
                log.warn("peer federation: [domain.{s}] is this host's own name; skipped", .{dom.name});
                continue;
            }
            try self.add(dom);
        }
        return self;
    }

    /// Call-in member: the one link to its hub's `dom` (`peer_hub_domain`).
    pub fn initCallin(allocator: std.mem.Allocator, dom: *const Domain) error{OutOfMemory}!Links {
        var self: Links = .{ .allocator = allocator, .hub = false };
        errdefer self.deinit();
        try self.add(dom);
        return self;
    }

    fn add(self: *Links, dom: *const Domain) error{OutOfMemory}!void {
        const l = try self.allocator.create(Link);
        errdefer self.allocator.destroy(l);
        const domain = try self.allocator.dupe(u8, dom.name);
        errdefer self.allocator.free(domain);
        // A member always dials its hub; only a hub's domain can be inbound.
        const direction: PeerLinkDirection = if (self.hub) dom.peer_link else .outbound;
        const spec = switch (direction) {
            .outbound => try dom.hostSpec(self.allocator),
            .inbound => try self.allocator.dupe(u8, ""),
        };
        errdefer self.allocator.free(spec);
        l.* = .{ .domain = domain, .spec = spec, .direction = direction };
        try self.items.append(self.allocator, l);
    }

    pub fn deinit(self: *Links) void {
        for (self.items.items) |l| {
            if (l.conn) |*conn| conn.deinit();
            if (l.dial_fd >= 0) _ = c.close(l.dial_fd);
            if (l.dial_pid > 0) {
                _ = c.kill(l.dial_pid, c.SIGKILL);
                var st: c_int = 0;
                _ = c.waitpid(l.dial_pid, &st, 0);
            }
            self.allocator.free(l.domain);
            self.allocator.free(l.spec);
            self.allocator.destroy(l);
        }
        self.items.deinit(self.allocator);
    }

    /// The domains, for the store's routes; borrowed from the links.
    pub fn domains(self: *const Links, allocator: std.mem.Allocator) error{OutOfMemory}![]const []const u8 {
        return self.named(allocator, null);
    }

    /// The inbound domains, for the store's routes; borrowed from the links.
    pub fn inbound(self: *const Links, allocator: std.mem.Allocator) error{OutOfMemory}![]const []const u8 {
        return self.named(allocator, .inbound);
    }

    fn named(self: *const Links, allocator: std.mem.Allocator, only: ?PeerLinkDirection) error{OutOfMemory}![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (self.items.items) |l| {
            if (only == null or only.? == l.direction) try out.append(allocator, l.domain);
        }
        return out.items;
    }

    /// Reap finished dialers, drop broken links, start the dials now due.
    pub fn tick(self: *Links, d: *Daemon, store: *peermail.Store, now: i64, wall: i64) void {
        for (self.items.items) |l| {
            if (l.dial_pid > 0) {
                var st: c_int = 0;
                if (c.waitpid(l.dial_pid, &st, c.WNOHANG) != 0) l.dial_pid = -1;
            }
            if (l.broken) self.drop(l, store, now, wall, "its connection stopped taking data");
            if (l.phase == .dialing and now - l.dial_started_ms > DIAL_TIMEOUT_MS) {
                if (l.dial_pid > 0) _ = c.kill(l.dial_pid, c.SIGKILL);
                self.dialFailed(l, now, "the dial timed out");
            }
            if (l.phase == .greeting and now - l.dial_started_ms > DIAL_TIMEOUT_MS) self.drop(l, store, now, wall, "the hub never answered the hello");
            switch (l.direction) {
                .outbound => if (l.phase == .waiting and l.dial_pid < 0 and l.backoff.due(now)) self.startDial(d, l, now),
                .inbound => {},
            }
        }
    }

    /// Hub: the inbound link a member at `host` calls in on.
    /// @return error.UnknownDomain when no federated domain is called that,
    /// error.NotInbound when the hub dials that domain itself.
    pub fn callin(self: *Links, host: []const u8) error{ UnknownDomain, NotInbound }!*Link {
        for (self.items.items) |l| {
            if (!std.mem.eql(u8, l.domain, host)) continue;
            return switch (l.direction) {
                .inbound => l,
                .outbound => error.NotInbound,
            };
        }
        return error.UnknownDomain;
    }

    /// Hub: broker client `client_id` is `l`'s call-in now (its
    /// `peer_hub_hello` already queued), its hello saying whether it reads
    /// slow mail. @return the client id of the link it replaces, or 0.
    pub fn acceptCallin(self: *Links, l: *Link, client_id: u32, far_slow: bool, store: *peermail.Store, wall: i64) u32 {
        const old: u32 = if (l.phase == .up) l.conn_id else 0;
        if (old != 0) {
            store.connGone(old, wall);
            log.warn("peer federation: {s} called in again; its older link is closed", .{l.domain});
        }
        l.far_slow = far_slow;
        self.up(l, client_id, store, wall);
        return old;
    }

    /// Broker client `id` went away: an inbound link it carried is down
    /// (the store learns it from the same `clientGone`).
    pub fn clientGone(self: *Links, id: u32) void {
        for (self.items.items) |l| {
            if (l.direction != .inbound or l.conn_id != id or id == 0) continue;
            l.conn_id = 0;
            l.phase = .waiting;
            log.warn("peer federation: link to {s} down (the member hung up); waiting for it to call in", .{l.domain});
        }
    }

    /// The one "a link is up" step, whichever side dialed: on a hub the
    /// domain's mail now routes over `conn_id`; a member's store already
    /// took the hub's hello.
    fn up(self: *Links, l: *Link, conn_id: u32, store: *peermail.Store, wall: i64) void {
        l.conn_id = conn_id;
        l.phase = .up;
        l.broken = false;
        l.backoff.reset();
        log.info("peer federation: link to {s} up ({s})", .{ l.domain, @tagName(l.direction) });
        if (self.hub) store.linkUp(l.domain, conn_id, l.far_slow, wall);
    }

    /// One pollfd per link, in link order (fd -1 when it has none now).
    pub fn appendPoll(self: *Links, fds: *std.ArrayList(c.struct_pollfd)) error{OutOfMemory}!usize {
        for (self.items.items) |l| {
            var p = c.struct_pollfd{ .fd = -1, .events = c.POLLIN, .revents = 0 };
            switch (l.phase) {
                .waiting => {},
                .dialing => p.fd = l.dial_fd,
                .greeting, .up => if (l.conn) |*conn| {
                    p.fd = conn.fd;
                    if (conn.wbuf.items.len > 0) p.events |= c.POLLOUT;
                },
            }
            try fds.append(self.allocator, p);
        }
        return self.items.items.len;
    }

    /// Serve the pollfds `appendPoll` added this tick (same order).
    pub fn service(self: *Links, polled: []const c.struct_pollfd, store: *peermail.Store, now: i64, wall: i64) void {
        for (self.items.items[0..@min(polled.len, self.items.items.len)], polled[0..@min(polled.len, self.items.items.len)]) |l, p| {
            if (p.fd < 0 or p.revents == 0) continue;
            switch (l.phase) {
                .waiting => {},
                .dialing => if (p.fd == l.dial_fd) self.dialDone(l, store, now, wall),
                .greeting, .up => if (l.conn != null and l.conn.?.fd == p.fd) self.serviceUp(l, p.revents, store, now, wall),
            }
        }
    }

    /// Queue one relay on dialed link `conn_id`; false when it has no live link.
    pub fn queue(self: *Links, conn_id: u32, relay: peermail.Relay) bool {
        for (self.items.items) |l| {
            if (l.conn_id != conn_id or l.broken) continue;
            const conn = if (l.conn) |*cc| cc else return false;
            conn.queueJson(relayFrame(self.hub), relay) catch {
                l.broken = true;
                return false;
            };
            if (conn.wbuf.items.len > WBUF_MAX) l.broken = true;
            return !l.broken;
        }
        return false;
    }

    fn startDial(self: *Links, d: *Daemon, l: *Link, now: i64) void {
        var sp: [2]c_int = undefined;
        if (platform.socketpairCloexec(&sp) != 0) return self.dialFailed(l, now, "socketpair failed");
        const pid = c.fork();
        if (pid < 0) {
            _ = c.close(sp[0]);
            _ = c.close(sp[1]);
            return self.dialFailed(l, now, "fork failed");
        }
        if (pid == 0) {
            daemon_sessions.closeInheritedBrokerFds(d, sp[1]);
            dialChild(l.spec, sp[1]);
        }
        _ = c.close(sp[1]);
        const fl = c.fcntl(sp[0], c.F_GETFL);
        _ = c.fcntl(sp[0], c.F_SETFL, fl | c.O_NONBLOCK);
        l.dial_pid = pid;
        l.dial_fd = sp[0];
        l.dial_started_ms = now;
        l.phase = .dialing;
    }

    fn dialDone(self: *Links, l: *Link, store: *peermail.Store, now: i64, wall: i64) void {
        var buf: [2048]u8 = undefined;
        var got: std.ArrayList(c_int) = .empty;
        defer got.deinit(self.allocator);
        const n = scmrights.recv(l.dial_fd, &buf, self.allocator, &got);
        if (n < 0 and std.posix.errno(n) == .AGAIN) return;
        _ = c.close(l.dial_fd);
        l.dial_fd = -1;
        var fd: c_int = -1;
        for (got.items, 0..) |f, i| {
            if (i == 0) fd = f else _ = c.close(f);
        }
        if (n <= 0) {
            if (fd >= 0) _ = c.close(fd);
            return self.dialFailed(l, now, "the dialer exited without an answer");
        }
        const parsed = std.json.parseFromSlice(DialResult, self.allocator, buf[0..@intCast(n)], .{ .ignore_unknown_fields = true }) catch {
            if (fd >= 0) _ = c.close(fd);
            return self.dialFailed(l, now, "the dialer's answer did not parse");
        };
        defer parsed.deinit();
        const res = parsed.value;
        switch (verdict(res, !self.hub)) {
            .failed => {
                if (fd >= 0) _ = c.close(fd);
                return self.dialFailed(l, now, res.@"error");
            },
            .unsupported => {
                if (fd >= 0) _ = c.close(fd);
                l.phase = .waiting;
                _ = l.backoff.failLong(now);
                store.linkUnsupported(l.domain, wall);
                log.warn("peer federation: {s}'s daemon predates {s}; retrying in {d} s", .{ l.domain, if (self.hub) "federation (no peer_federation)" else "call-in members (no peer_callin)", @divTrunc(l.backoff.delay_ms, 1000) });
            },
            .federate => {
                if (fd < 0) return self.dialFailed(l, now, "the dialer sent no socket");
                const fl = c.fcntl(fd, c.F_GETFL);
                _ = c.fcntl(fd, c.F_SETFL, fl | c.O_NONBLOCK);
                self.next_id +%= 1;
                var id = LINK_ID_BASE | (self.next_id & (LINK_ID_BASE - 1));
                if (id == LINK_ID_BASE) id += 1;
                l.conn_id = id;
                l.conn = .{ .allocator = self.allocator, .fd = fd, .transport = .ssh, .proto = res.proto, .server_proto = res.server_proto };
                l.conn.?.caps.peers = res.peers;
                l.conn.?.caps.peer_federation = res.peer_federation;
                l.conn.?.caps.peer_callin = res.peer_callin;
                l.conn.?.caps.peer_slow_mail = res.peer_slow_mail;
                l.far_slow = res.peer_slow_mail;
                const hello = if (self.hub)
                    l.conn.?.queueJson(.peer_hub_hello, peermail.HubHello{ .host = store.host, .as = l.domain, .slow_mail = true })
                else
                    l.conn.?.queueJson(.peer_member_hello, peermail.MemberHello{ .host = store.host, .slow_mail = true });
                hello catch return self.drop(l, store, now, wall, "the hello could not be sent");
                if (self.hub) return self.up(l, id, store, wall);
                l.phase = .greeting;
                l.dial_started_ms = now;
                log.info("peer federation: called in to {s}; waiting for its hello", .{l.domain});
            },
        }
    }

    fn serviceUp(self: *Links, l: *Link, revents: c_short, store: *peermail.Store, now: i64, wall: i64) void {
        const conn = if (l.conn) |*cc| cc else return;
        if (revents & c.POLLOUT != 0) conn.flushQueued() catch return self.drop(l, store, now, wall, "a write failed");
        if (revents & (c.POLLIN | c.POLLHUP | c.POLLERR) == 0) return;
        const alive = conn.fillAvailable();
        while (true) {
            const f = conn.takeFrame() catch return self.drop(l, store, now, wall, "a malformed frame arrived");
            const frame = f orelse break;
            defer frame.deinit(self.allocator);
            switch (frame.ftype) {
                .peer_member_relay, .peer_hub_relay => {
                    if (frame.ftype != relayFrame(!self.hub)) {
                        log.warn("peer federation: a {s} from {s} dropped: it never travels this way", .{ @tagName(frame.ftype), l.domain });
                        continue;
                    }
                    const parsed = std.json.parseFromSlice(peermail.Relay, self.allocator, frame.payload, .{ .ignore_unknown_fields = true }) catch {
                        log.warn("peer federation: an unreadable relay from {s} dropped", .{l.domain});
                        continue;
                    };
                    defer parsed.deinit();
                    store.relayIn(l.conn_id, parsed.value, wall) catch |e| log.warn("peer federation: a relay from {s} failed: {s}", .{ l.domain, @errorName(e) });
                },
                // A call-in member's hub answers its hello; the member's
                // store takes it exactly as a hub-dialed hello.
                .peer_hub_hello => {
                    if (self.hub) continue;
                    const parsed = std.json.parseFromSlice(peermail.HubHello, self.allocator, frame.payload, .{ .ignore_unknown_fields = true }) catch
                        return self.drop(l, store, now, wall, "the hub's hello did not parse");
                    defer parsed.deinit();
                    store.uplinkUp(l.conn_id, parsed.value, .outbound, wall) catch |e|
                        return self.drop(l, store, now, wall, @errorName(e));
                    log.info("peer federation: hub {s} linked, calling this host {s}", .{ parsed.value.host, parsed.value.as });
                    self.up(l, l.conn_id, store, wall);
                },
                .err => {
                    log.warn("peer federation: {s} refused the link: {s}", .{ l.domain, frame.payload[0..@min(frame.payload.len, 200)] });
                    return self.drop(l, store, now, wall, "the far daemon refused it");
                },
                else => {},
            }
            if (l.conn == null) return;
        }
        if (!alive) self.drop(l, store, now, wall, "the far side closed it");
    }

    fn dialFailed(self: *Links, l: *Link, now: i64, why: []const u8) void {
        _ = self;
        if (l.dial_fd >= 0) {
            _ = c.close(l.dial_fd);
            l.dial_fd = -1;
        }
        l.phase = .waiting;
        const wait = l.backoff.fail(now);
        log.warn("peer federation: dialing {s} failed ({s}); retrying in {d} s", .{ l.domain, why, @divTrunc(wait, 1000) });
    }

    fn drop(self: *Links, l: *Link, store: *peermail.Store, now: i64, wall: i64, why: []const u8) void {
        _ = self;
        const id = l.conn_id;
        if (l.conn) |*conn| conn.deinit();
        l.conn = null;
        l.conn_id = 0;
        l.broken = false;
        l.phase = .waiting;
        const wait = l.backoff.fail(now);
        log.warn("peer federation: link to {s} down ({s}); redialing in {d} s", .{ l.domain, why, @divTrunc(wait, 1000) });
        store.connGone(id, wall);
    }
};

/// The forked dialer: connect, hand the socket and a `DialResult` to the
/// broker, exit. Never returns.
fn dialChild(spec: []const u8, out_fd: c_int) noreturn {
    // A detached broker has fds 0-2 closed; seat /dev/null there so the
    // ssh plumbing below never lands a socket in the stdio range.
    for (0..3) |i| {
        if (c.fcntl(@as(c_int, @intCast(i)), c.F_GETFD) < 0) _ = c.open("/dev/null", c.O_RDWR);
    }
    const a = std.heap.c_allocator;
    var cfg = Config.load(a);
    var res = DialResult{};
    var conn_fd: c_int = -1;
    if (muxclient.Conn.connectRemote(a, spec, cfg.muxConnectOptions())) |conn| {
        res = .{
            .ok = true,
            .proto = conn.proto,
            .server_proto = conn.server_proto,
            .peers = conn.caps.peers,
            .peer_federation = conn.caps.peer_federation,
            .peer_callin = conn.caps.peer_callin,
            .peer_slow_mail = conn.caps.peer_slow_mail,
        };
        conn_fd = conn.fd;
    } else |e| res.@"error" = @errorName(e);
    const json = std.json.Stringify.valueAlloc(a, res, .{}) catch c._exit(1);
    var iov = c.struct_iovec{ .iov_base = @constCast(json.ptr), .iov_len = json.len };
    var cbuf: [64]u8 align(@alignOf(c.struct_cmsghdr)) = std.mem.zeroes([64]u8);
    var mh = std.mem.zeroes(c.struct_msghdr);
    mh.msg_iov = @ptrCast(&iov);
    mh.msg_iovlen = 1;
    if (conn_fd >= 0) {
        mh.msg_control = &cbuf;
        mh.msg_controllen = @intCast(scmrights.pack(&cbuf, &.{conn_fd}));
    }
    _ = c.sendmsg(out_fd, &mh, 0);
    c._exit(0);
}

const t = std.testing;

test "a dial federates only with both welcome flags; an old daemon is unsupported" {
    try t.expectEqual(Verdict.failed, verdict(.{ .ok = false, .@"error" = "HostUnreachable" }, false));
    // A daemon from before peers, and one with peers but no federation.
    try t.expectEqual(Verdict.unsupported, verdict(.{ .ok = true, .proto = 7 }, false));
    try t.expectEqual(Verdict.unsupported, verdict(.{ .ok = true, .proto = 7, .peers = true }, false));
    try t.expectEqual(Verdict.federate, verdict(.{ .ok = true, .proto = 7, .peers = true, .peer_federation = true }, false));
    // A call-in member also needs its hub's peer_callin: an older hub is unsupported.
    try t.expectEqual(Verdict.unsupported, verdict(.{ .ok = true, .proto = 7, .peers = true, .peer_federation = true }, true));
    try t.expectEqual(Verdict.federate, verdict(.{ .ok = true, .proto = 7, .peers = true, .peer_federation = true, .peer_callin = true }, true));
    // The answer round-trips as the dialer writes it; unknown keys are skipped.
    const json = try std.json.Stringify.valueAlloc(t.allocator, DialResult{ .ok = true, .peers = true }, .{});
    defer t.allocator.free(json);
    const back = try std.json.parseFromSlice(DialResult, t.allocator, json, .{ .ignore_unknown_fields = true });
    defer back.deinit();
    try t.expectEqual(Verdict.unsupported, verdict(back.value, false));
}

test "the welcome flags a dial reads come from the one capability table" {
    // An old daemon's welcome lacks the flag; a current one carries it.
    const old = @import("capabilities.zig").parse(t.allocator, "{\"proto\":7,\"peers\":true}");
    try t.expect(old.peers and !old.peer_federation and !old.peer_callin);
    const now = @import("capabilities.zig").all;
    try t.expect(now.peers and now.peer_federation and now.peer_callin);
}

test "links come only from federated domains with a usable name" {
    var cfg = try Config.loadFromBytes(t.allocator,
        \\peer_hub = true
        \\[domain.box]
        \\host = box.example
        \\transport = ssh
        \\peers = true
        \\[domain.plain]
        \\host = plain.example
        \\[domain.self]
        \\host = me.example
        \\peers = true
        \\[domain.aeor]
        \\peers = true
        \\peer_link = inbound
        \\[domain.lost]
        \\peers = true
        \\
    );
    defer cfg.deinit();
    var links = try Links.init(t.allocator, &cfg, "self");
    defer links.deinit();
    // `lost` has no host and is outbound: there is nothing to dial.
    try t.expectEqual(@as(usize, 2), links.items.items.len);
    try t.expectEqualStrings("box", links.items.items[0].domain);
    try t.expectEqualStrings("ssh:box.example", links.items.items[0].spec);
    try t.expectEqual(PeerLinkDirection.inbound, links.items.items[1].direction);
    try t.expectEqualStrings("", links.items.items[1].spec);
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    try t.expectEqualStrings("box", (try links.domains(arena.allocator()))[0]);
    try t.expectEqualStrings("aeor", (try links.inbound(arena.allocator()))[0]);
}

test "the hub takes a call-in only from a configured inbound domain, and a newer one replaces the older" {
    var cfg = try Config.loadFromBytes(t.allocator, "peer_hub = true\n[domain.box]\nhost = b\npeers = true\n[domain.aeor]\npeers = true\npeer_link = inbound\n");
    defer cfg.deinit();
    var links = try Links.init(t.allocator, &cfg, "hub");
    defer links.deinit();
    var rec: struct {
        relays: u32 = 0,
        fn emit(ctx: *anyopaque, _: u32, out: peermail.Out) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (out == .relay) self.relays += 1;
            return true;
        }
    } = .{};
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var store = try peermail.Store.init(t.allocator, .{ .host = "hub", .hub = true, .domains = try links.domains(arena.allocator()), .inbound = try links.inbound(arena.allocator()), .emit = .{ .ctx = &rec, .func = @TypeOf(rec).emit } });
    defer store.deinit();
    // 1. An unknown host and an outbound domain are refused, naming why.
    try t.expectError(error.UnknownDomain, links.callin("nowhere"));
    try t.expectError(error.NotInbound, links.callin("box"));
    // 2. The inbound member calls in: its link is up over that client.
    const l = try links.callin("aeor");
    try t.expectEqual(@as(u32, 0), links.acceptCallin(l, 7, true, &store, 100));
    const hosts = try store.hostList(arena.allocator());
    try t.expectEqual(PeerLink.up, hosts[1].link);
    try t.expectEqual(@as(?PeerLinkDirection, .inbound), hosts[1].direction);
    // 3. It calls in again before the old client is gone: the new one
    // replaces it, and the old one's late hang-up changes nothing.
    try t.expectEqual(@as(u32, 7), links.acceptCallin(l, 9, true, &store, 200));
    links.clientGone(7);
    store.connGone(7, 210);
    try t.expectEqual(PeerLink.up, (try store.hostList(arena.allocator()))[1].link);
    // 4. The live one hangs up: the domain stays listed, down.
    links.clientGone(9);
    store.connGone(9, 300);
    try t.expectEqual(PeerLink.down, (try store.hostList(arena.allocator()))[1].link);
    try t.expectEqual(@as(u32, 0), l.conn_id);
}

const PeerLink = peermail.PeerLink;
