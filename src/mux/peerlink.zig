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
//! A failed or dropped link redials after a 2-60 s `Backoff` (`waitAfter`;
//! refused because another daemon holds it: `peerhold.HELD_RETRY_MS` at
//! least, never the 2 s floor); a daemon
//! without the flags it needs is marked unsupported and retried at the
//! ceiling. An inbound domain (`peer_link = inbound`) is never dialed:
//! its member's call-in arrives as a broker client (`callin`), which
//! then is that domain's link, through the same `up` step. Who may hold a
//! link, beats and silence are `peerhold`'s, kept on the store's routes.

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
const peerhold = @import("peerhold.zig");
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
    peer_link_beat: bool = false,
    /// A failed dial: why (`dialWhy`), and what said so.
    why: ?PeerLinkWhy = null,
    detail: []const u8 = "",
    /// The far daemon's version (its welcome), "" = it named none.
    version: []const u8 = "",
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

/// Why a dial failed and what said so.
pub const DialWhy = struct { why: PeerLinkWhy, detail: []const u8 };

/// What a failed `connectRemote` means, from what its transport noted on
/// the dialing thread: ssh's line that the host could not be reached
/// (`client.sshUnreachable`), a route's failing hop (`routeFailure`), ssh's
/// last line otherwise (`sshSaid`: a refused login reads `auth_failed`),
/// else the error's name.
pub fn dialWhy(err_name: []const u8, unreachable_line: []const u8, route_failure: []const u8, said: []const u8) DialWhy {
    if (unreachable_line.len > 0) return .{ .why = .@"unreachable", .detail = unreachable_line };
    if (route_failure.len > 0) return .{ .why = .dial_failed, .detail = route_failure };
    for (AUTH_REFUSALS) |needle| {
        if (std.mem.indexOf(u8, said, needle) != null) return .{ .why = .auth_failed, .detail = said };
    }
    return .{ .why = .dial_failed, .detail = if (said.len > 0) said else err_name };
}

/// What ssh writes when it reached the host and the login failed.
const AUTH_REFUSALS = [_][]const u8{ "Permission denied", "Host key verification failed", "Too many authentication failures", "Authentication failed" };

/// The detail of an `unsupported` link: the far daemon's version, and
/// what it lacks.
fn unsupportedDetail(buf: []u8, r: DialResult, callin: bool) []const u8 {
    const lacks = if (callin and r.peers and r.peer_federation) "call-in members (no peer_callin)" else "peer federation (no peer_federation)";
    return std.fmt.bufPrint(buf, "it runs {s}, which predates {s}", .{ if (r.version.len > 0) r.version else "a version it does not name", lacks }) catch "it predates federation";
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
    /// A queue failed inside the store's sink, or the store hung the link
    /// up; dropped on the next tick, for `hangup` when the store said why.
    broken: bool = false,
    hangup: ?[]const u8 = null,
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
            if (l.broken) self.drop(l, store, now, wall, .dropped, l.hangup orelse "its connection stopped taking data");
            if (l.phase == .dialing and now - l.dial_started_ms > DIAL_TIMEOUT_MS) {
                if (l.dial_pid > 0) _ = c.kill(l.dial_pid, c.SIGKILL);
                self.dialFailed(l, store, now, wall, .dial_failed, std.fmt.comptimePrint("no answer within {d} s", .{@divExact(DIAL_TIMEOUT_MS, 1000)}));
            }
            if (l.phase == .greeting and now - l.dial_started_ms > DIAL_TIMEOUT_MS) self.drop(l, store, now, wall, .dropped, "the hub never answered the hello");
            switch (l.direction) {
                .outbound => if (l.phase == .waiting and l.dial_pid < 0 and l.backoff.due(now)) self.startDial(d, store, l, now, wall),
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
    /// `peer_hub_hello` already queued, `peermail.Store.admit` asked
    /// first), to `far`. A live older link is replaced by the store.
    pub fn acceptCallin(self: *Links, l: *Link, client_id: u32, far: peermail.Far, store: *peermail.Store, wall: i64, mono: i64) void {
        self.up(l, client_id, far, store, wall, mono);
    }

    /// Broker client `id` went away: an inbound link it carried is down
    /// (the store learns it from the same `clientGone`).
    pub fn clientGone(self: *Links, id: u32) void {
        for (self.items.items) |l| {
            if (l.direction != .inbound or l.conn_id != id or id == 0) continue;
            l.conn_id = 0;
            l.phase = .waiting;
            log.warn("peer federation: link to {s} down (its connection closed); waiting for it to call in", .{l.domain});
        }
    }

    /// The one "a link is up" step, whichever side dialed: on a hub the
    /// domain's mail now routes over `conn_id`; a member's store already
    /// took the hub's hello. A flapping link is not logged every time.
    fn up(self: *Links, l: *Link, conn_id: u32, far: peermail.Far, store: *peermail.Store, wall: i64, mono: i64) void {
        l.conn_id = conn_id;
        l.phase = .up;
        l.broken = false;
        l.hangup = null;
        l.backoff.reset();
        if (self.hub) store.linkUp(l.domain, conn_id, far, wall, mono);
        if (!store.linkFlapping(l.domain)) log.info("peer federation: link to {s} up ({s})", .{ l.domain, @tagName(l.direction) });
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
        const l = self.dialed(conn_id) orelse return false;
        return queued(l, l.conn.?.queueJson(relayFrame(self.hub), relay));
    }

    /// Queue one `peer_link_beat` on dialed link `conn_id`.
    pub fn queueBeat(self: *Links, conn_id: u32) bool {
        const l = self.dialed(conn_id) orelse return false;
        return queued(l, l.conn.?.queueFrame(.peer_link_beat, ""));
    }

    /// The store closed dialed link `conn_id` (replaced, or silent): it is
    /// dropped on the next tick, `why` (static) naming it.
    pub fn hangup(self: *Links, conn_id: u32, why: []const u8) void {
        const l = self.dialed(conn_id) orelse return;
        l.broken = true;
        l.hangup = why;
    }

    /// The dialed link `conn_id` names, while it takes data.
    fn dialed(self: *Links, conn_id: u32) ?*Link {
        for (self.items.items) |l| {
            if (l.conn_id == conn_id and !l.broken and l.conn != null) return l;
        }
        return null;
    }

    fn queued(l: *Link, res: anyerror!void) bool {
        res catch {
            l.broken = true;
            return false;
        };
        if (l.conn.?.wbuf.items.len > WBUF_MAX) l.broken = true;
        return !l.broken;
    }

    fn startDial(self: *Links, d: *Daemon, store: *peermail.Store, l: *Link, now: i64, wall: i64) void {
        var sp: [2]c_int = undefined;
        if (platform.socketpairCloexec(&sp) != 0) return self.dialFailed(l, store, now, wall, .dial_failed, "socketpair failed");
        const pid = c.fork();
        if (pid < 0) {
            _ = c.close(sp[0]);
            _ = c.close(sp[1]);
            return self.dialFailed(l, store, now, wall, .dial_failed, "fork failed");
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
        store.linkDialing(l.domain);
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
            return self.dialFailed(l, store, now, wall, .dial_failed, "the dialer exited without an answer");
        }
        const parsed = std.json.parseFromSlice(DialResult, self.allocator, buf[0..@intCast(n)], .{ .ignore_unknown_fields = true }) catch {
            if (fd >= 0) _ = c.close(fd);
            return self.dialFailed(l, store, now, wall, .dial_failed, "the dialer's answer did not parse");
        };
        defer parsed.deinit();
        const res = parsed.value;
        switch (verdict(res, !self.hub)) {
            .failed => {
                if (fd >= 0) _ = c.close(fd);
                return self.dialFailed(l, store, now, wall, res.why orelse .dial_failed, if (res.detail.len > 0) res.detail else res.@"error");
            },
            .unsupported => {
                if (fd >= 0) _ = c.close(fd);
                l.phase = .waiting;
                const wait = waitAfter(&l.backoff, .unsupported, now);
                var db: [256]u8 = undefined;
                const detail = unsupportedDetail(&db, res, !self.hub);
                store.linkUnsupported(l.domain, wall);
                store.linkWhy(l.domain, .unsupported, detail, wait, wall);
                log.warn("peer federation: {s}'s daemon is too old: {s}; retrying in {d} s", .{ l.domain, detail, @divTrunc(wait, 1000) });
            },
            .federate => {
                if (fd < 0) return self.dialFailed(l, store, now, wall, .dial_failed, "the dialer sent no socket");
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
                l.conn.?.caps.peer_link_beat = res.peer_link_beat;
                const far: peermail.Far = .{ .beats = res.peer_link_beat, .slow = res.peer_slow_mail };
                const hello = if (self.hub)
                    l.conn.?.queueJson(.peer_hub_hello, peermail.HubHello{ .host = store.host, .as = l.domain, .slow_mail = true, .instance = store.selfInstance(), .beat = true })
                else
                    l.conn.?.queueJson(.peer_member_hello, peermail.MemberHello{ .host = store.host, .slow_mail = true, .instance = store.selfInstance(), .beat = true });
                hello catch return self.drop(l, store, now, wall, .dropped, "the hello could not be sent");
                if (self.hub) return self.up(l, id, far, store, wall, now);
                l.phase = .greeting;
                l.dial_started_ms = now;
                store.linkWhy(l.domain, .greeting, "", 0, wall);
                log.info("peer federation: called in to {s}; waiting for its hello", .{l.domain});
            },
        }
    }

    fn serviceUp(self: *Links, l: *Link, revents: c_short, store: *peermail.Store, now: i64, wall: i64) void {
        const conn = if (l.conn) |*cc| cc else return;
        if (revents & c.POLLOUT != 0) conn.flushQueued() catch return self.drop(l, store, now, wall, .dropped, "a write failed");
        if (revents & (c.POLLIN | c.POLLHUP | c.POLLERR) == 0) return;
        const alive = conn.fillAvailable();
        while (true) {
            const f = conn.takeFrame() catch return self.drop(l, store, now, wall, .dropped, "a malformed frame arrived");
            const frame = f orelse break;
            defer frame.deinit(self.allocator);
            store.linkHeard(l.conn_id, now);
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
                        return self.drop(l, store, now, wall, .dropped, "the hub's hello did not parse");
                    defer parsed.deinit();
                    switch (store.admit(l.domain, parsed.value.instance)) {
                        .take, .replace => {},
                        .refuse => |r| {
                            var hb: [256]u8 = undefined;
                            var db: [peermail.LINK_DETAIL_MAX]u8 = undefined;
                            const detail = std.fmt.bufPrint(&db, "another hub holds this host's uplink ({s})", .{r.holder.describe(&hb)}) catch "another hub holds this host's uplink";
                            return self.drop(l, store, now, wall, .taken, detail);
                        },
                    }
                    store.uplinkUp(l.conn_id, parsed.value, .outbound, wall, now) catch |e|
                        return self.drop(l, store, now, wall, .refused, @errorName(e));
                    log.info("peer federation: hub {s} linked, calling this host {s}", .{ parsed.value.host, parsed.value.as });
                    self.up(l, l.conn_id, parsed.value.far(), store, wall, now);
                },
                // Only liveness: `linkHeard` above took it.
                .peer_link_beat => {},
                .err => {
                    // Its words: `.err` carries `{"error": ..., "for": ...}`,
                    // and `link_held` when another daemon holds the link.
                    const parsed = std.json.parseFromSlice(peermail.LinkRefused, self.allocator, frame.payload, .{ .ignore_unknown_fields = true }) catch null;
                    defer if (parsed) |p| p.deinit();
                    const said = if (parsed) |p| p.value.@"error" else std.mem.trim(u8, frame.payload[0..@min(frame.payload.len, 200)], " \r\n");
                    const held = if (parsed) |p| p.value.link_held else false;
                    log.warn("peer federation: {s} refused the link: {s}", .{ l.domain, said });
                    return self.drop(l, store, now, wall, if (held) .taken else .refused, said);
                },
                else => {},
            }
            if (l.conn == null) return;
        }
        if (!alive) self.drop(l, store, now, wall, .dropped, "the far side closed it");
    }

    fn dialFailed(self: *Links, l: *Link, store: *peermail.Store, now: i64, wall: i64, why: PeerLinkWhy, detail: []const u8) void {
        _ = self;
        if (l.dial_fd >= 0) {
            _ = c.close(l.dial_fd);
            l.dial_fd = -1;
        }
        l.phase = .waiting;
        const wait = waitAfter(&l.backoff, why, now);
        store.linkWhy(l.domain, why, detail, wait, wall);
        log.warn("peer federation: dialing {s} failed ({s}: {s}); retrying in {d} s", .{ l.domain, why.label(), detail, @divTrunc(wait, 1000) });
    }

    fn drop(self: *Links, l: *Link, store: *peermail.Store, now: i64, wall: i64, why: PeerLinkWhy, detail: []const u8) void {
        _ = self;
        const id = l.conn_id;
        if (l.conn) |*conn| conn.deinit();
        l.conn = null;
        l.conn_id = 0;
        l.broken = false;
        l.hangup = null;
        l.phase = .waiting;
        const wait = waitAfter(&l.backoff, why, now);
        log.warn("peer federation: link to {s} down ({s}: {s}); redialing in {d} s", .{ l.domain, why.label(), detail, @divTrunc(wait, 1000) });
        store.connGone(id, wall);
        store.linkWhy(l.domain, why, detail, wait, wall);
    }
};

/// How long a link waits before dialing again after failing for `why`:
/// another daemon holding it is not retried at the floor, a daemon too
/// old waits the ceiling.
fn waitAfter(b: *Backoff, why: PeerLinkWhy, now: i64) i64 {
    return switch (why) {
        .taken => b.failAtLeast(now, peerhold.HELD_RETRY_MS),
        .unsupported => b.failLong(now),
        .dialing, .@"unreachable", .auth_failed, .dial_failed, .refused, .dropped, .awaiting_dial, .greeting, .flapping => b.fail(now),
    };
}

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
            .peer_link_beat = conn.caps.peer_link_beat,
            .version = conn.serverVersion(),
        };
        conn_fd = conn.fd;
    } else |e| {
        const dw = dialWhy(@errorName(e), muxclient.sshUnreachable(), muxclient.routeFailure(), muxclient.sshSaid());
        res.@"error" = @errorName(e);
        res.why = dw.why;
        res.detail = dw.detail;
    }
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
        hungup: u32 = 0,
        fn emit(ctx: *anyopaque, conn: u32, out: peermail.Out) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (out == .relay) self.relays += 1;
            if (out == .hangup) self.hungup = conn;
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
    links.acceptCallin(l, 7, .{ .slow = true }, &store, 100, 0);
    const hosts = try store.hostList(arena.allocator(), 0);
    try t.expectEqual(PeerLink.up, hosts[1].link);
    try t.expectEqual(@as(?PeerLinkDirection, .inbound), hosts[1].direction);
    // 3. It calls in again before the old client is gone (an older build:
    // no instance): the new one replaces it, the store hangs the old one
    // up, and its late hang-up changes nothing.
    try std.testing.expect(store.admit("aeor", .{}) == .replace);
    links.acceptCallin(l, 9, .{ .slow = true }, &store, 200, 1);
    try t.expectEqual(@as(u32, 7), rec.hungup);
    links.clientGone(7);
    store.connGone(7, 210);
    try t.expectEqual(PeerLink.up, (try store.hostList(arena.allocator(), 0))[1].link);
    // 4. The live one hangs up: the domain stays listed, down.
    links.clientGone(9);
    store.connGone(9, 300);
    try t.expectEqual(PeerLink.down, (try store.hostList(arena.allocator(), 0))[1].link);
    try t.expectEqual(@as(u32, 0), l.conn_id);
}

test "a link refused because another daemon holds it waits HELD_RETRY_MS, never the 2 s floor" {
    var b = RECONNECT;
    try t.expectEqual(peerhold.HELD_RETRY_MS, waitAfter(&b, .taken, 0));
    b.reset();
    try t.expectEqual(RECONNECT.min_ms, waitAfter(&b, .dropped, 0));
    b.reset();
    try t.expectEqual(RECONNECT.max_ms, waitAfter(&b, .unsupported, 0));
}

test "a failed dial names why: unreachable, a refused login, a route's hop, else what ssh said or the error; an old daemon names its version" {
    const unreach = dialWhy("HostUnreachable", "ssh: connect to host dalaran port 22: Connection refused", "", "ssh: connect to host dalaran port 22: Connection refused");
    try t.expectEqual(PeerLinkWhy.@"unreachable", unreach.why);
    try t.expectEqualStrings("ssh: connect to host dalaran port 22: Connection refused", unreach.detail);
    const auth = dialWhy("SshTransportFailed", "", "", "me@dalaran: Permission denied (publickey).");
    try t.expectEqual(PeerLinkWhy.auth_failed, auth.why);
    try t.expectEqual(PeerLinkWhy.auth_failed, dialWhy("SshTransportFailed", "", "", "Host key verification failed.").why);
    const hop = dialWhy("RouteHopUnreachable", "", "route hop b did not answer: x", "x");
    try t.expectEqual(PeerLinkWhy.dial_failed, hop.why);
    try t.expectEqualStrings("route hop b did not answer: x", hop.detail);
    try t.expectEqualStrings("sh: 1: sketerm-mux: not found", dialWhy("SshTransportFailed", "", "", "sh: 1: sketerm-mux: not found").detail);
    try t.expectEqualStrings("Timeout", dialWhy("Timeout", "", "", "").detail);
    var buf: [256]u8 = undefined;
    try t.expectEqualStrings("it runs 0.2.2, which predates peer federation (no peer_federation)", unsupportedDetail(&buf, .{ .ok = true, .peers = true, .version = "0.2.2" }, false));
    try t.expectEqualStrings("it runs 0.3.0, which predates call-in members (no peer_callin)", unsupportedDetail(&buf, .{ .ok = true, .peers = true, .peer_federation = true, .version = "0.3.0" }, true));
    // The dialer's answer carries it across the socketpair.
    const json = try std.json.Stringify.valueAlloc(t.allocator, DialResult{ .@"error" = "HostUnreachable", .why = .@"unreachable", .detail = "ssh: x" }, .{});
    defer t.allocator.free(json);
    const back = try std.json.parseFromSlice(DialResult, t.allocator, json, .{ .ignore_unknown_fields = true });
    defer back.deinit();
    try t.expectEqual(@as(?PeerLinkWhy, .@"unreachable"), back.value.why);
}

const PeerLink = peermail.PeerLink;
const PeerLinkWhy = peermail.PeerLinkWhy;
