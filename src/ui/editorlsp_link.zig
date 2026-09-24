//! Remote LSP transport: one link per host, carrying language servers'
//! raw JSON-RPC as byte channels.
//!
//! The daemon on the file's host spawns the server near the files
//! (`lsp_open`) and relays its stdio; this side relays those bytes into
//! an ordinary `Session`. Only `Conn.pumpWrite` and `handleFrame` know the
//! transport is not a pipe. The link rides the process's shared
//! connection to the host (`hostlink.zig`, the one file-manager panes
//! and pickers on that host use too) rather than dialing its own; it is
//! separate only from the editor's file pool, whose short blocking
//! request/reply pumps would tangle with a long-lived frame stream.
//!
//! ## A dead link is redialed on demand, with backoff
//!
//! The shared link's connect runs on a worker (the ssh bootstrap blocks)
//! and hands back through `g_idle_add`. A link that failed, or whose daemon
//! predates `lsp:true`, stays listed as `.dead` with a retry time; the
//! next attach that needs the host (a feature request, an edit, a newly
//! opened document) redials once that time has passed, doubling the wait
//! from `BACKOFF_MIN_MS` up to `BACKOFF_MAX_MS` after each failure and
//! resetting it on success. So an unreachable host costs one quiet dial
//! per window instead of a storm, and a host that comes back is used
//! again without recreating the editor.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const clock = @import("../util/clock.zig");
const editorlsp = @import("editorlsp.zig");
const Manager = editorlsp.Manager;
const ETab = @import("editorview.zig").ETab;
const conn_mod = @import("editorlsp_conn.zig");
const Conn = conn_mod.Conn;
const registry = &conn_mod.registry;
const muxclient = @import("../mux/client.zig");
const wire = @import("../mux/wire.zig");
const servers = @import("../lsp/servers.zig");
const paths = @import("../filebrowser/paths.zig");
const Config = @import("../config.zig").Config;
const hostlink = @import("hostlink.zig");
const dbg = editorlsp.dbg;

/// First wait before redialing a failed host, and the ceiling the
/// doubling stops at.
pub const BACKOFF_MIN_MS: i64 = 2_000;
pub const BACKOFF_MAX_MS: i64 = 5 * 60 * 1000;

/// The wait after one more failure.
pub fn nextBackoff(prev_ms: i64) i64 {
    if (prev_ms <= 0) return BACKOFF_MIN_MS;
    return @min(prev_ms * 2, BACKOFF_MAX_MS);
}

pub const RemoteLink = struct {
    /// Host part of the spec ("box", "user@box", "udp:box"), owned.
    host: []u8,
    state: enum { connecting, up, dead } = .connecting,
    /// This link's place on the host's shared connection; joined by
    /// `dial`, left when the link dies or is dropped.
    lessee: hostlink.Lessee = undefined,
    next_req: u32 = 1,
    /// lsp_open requests in flight.
    pending: std.ArrayList(Pending) = .empty,
    /// Tabs parked here until the connect worker hands the socket back.
    waiting: std.ArrayList(u64) = .empty,
    /// Monotonic ms before which a dead link is not redialed, and the
    /// wait the NEXT failure will impose.
    retry_at_ms: i64 = 0,
    backoff_ms: i64 = 0,

    const Pending = struct { req: u32, tab_id: u64 };

    pub fn destroyLink(self: *RemoteLink) void {
        if (self.state != .dead) self.lessee.release();
        self.state = .dead;
        const a = registry.alloc;
        self.pending.deinit(a);
        self.waiting.deinit(a);
        a.free(self.host);
        a.destroy(self);
    }

    /// The shared connection; valid only while `.up`.
    pub fn io(self: *RemoteLink) *muxclient.Conn {
        return self.lessee.conn().?;
    }

    /// Whether a dead link may be redialed now.
    pub fn due(self: *const RemoteLink, now_ms: i64) bool {
        return self.state == .dead and now_ms >= self.retry_at_ms;
    }

    /// Join (or open) the host's shared connection. The link is
    /// `.connecting` until it is up, so attaches park on it.
    pub fn dial(self: *RemoteLink) void {
        self.state = .connecting;
        self.lessee = .{
            .ctx = @ptrCast(self),
            .on_frame = onLinkFrame,
            .on_lost = onLinkLost,
            .on_ready = onLinkReady,
            .on_failed = onLinkFailed,
        };
        var config = Config.load(std.heap.c_allocator);
        defer config.deinit();
        const opts: hostlink.DialOptions = .{
            .port_range = config.udpRange() orelse "",
            .tor_socks_endpoint = config.mux_tor_socks_endpoint,
        };
        switch (hostlink.lease(self.host, &self.lessee, opts)) {
            .ready => self.linkUp(),
            .connecting => dbg("link {s}: connecting", .{self.host}),
            .dead => self.failed(),
        }
    }

    /// The shared connection is up: serve LSP on it, when its daemon can.
    fn linkUp(self: *RemoteLink) void {
        if (!self.io().caps.lsp) {
            dbg("link {s}: daemon has no lsp support", .{self.host});
            self.lessee.release();
            self.failed();
            return;
        }
        self.state = .up;
        self.backoff_ms = 0;
        dbg("link {s}: up", .{self.host});
        registry.onLinkUp(self);
    }

    fn onLinkReady(ctx: *anyopaque) void {
        const self: *RemoteLink = @ptrCast(@alignCast(ctx));
        if (self.state == .connecting) self.linkUp();
    }

    fn onLinkFailed(ctx: *anyopaque) void {
        const self: *RemoteLink = @ptrCast(@alignCast(ctx));
        dbg("link {s}: connect failed", .{self.host});
        if (self.state == .connecting) self.failed();
    }

    fn onLinkLost(ctx: *anyopaque) void {
        const self: *RemoteLink = @ptrCast(@alignCast(ctx));
        self.markDead();
    }

    fn onLinkFrame(ctx: *anyopaque, ftype: wire.FrameType, payload: []const u8) void {
        const self: *RemoteLink = @ptrCast(@alignCast(ctx));
        if (self.state != .up) return;
        self.handleFrame(ftype, payload);
        // Handlers may have queued replies (didOpen after ready, ...).
        if (self.state == .up) self.armWriteWatch();
    }

    /// A dial did not produce a usable link: stay dead until the backoff
    /// passes.
    fn failed(self: *RemoteLink) void {
        self.state = .dead;
        self.backoff_ms = nextBackoff(self.backoff_ms);
        self.retry_at_ms = clock.nowMs() + self.backoff_ms;
        self.waiting.clearRetainingCapacity();
    }

    /// The transport failed (EOF, write error, hangup): every server on
    /// it is gone, through the same dead path a local crash takes.
    pub fn markDead(self: *RemoteLink) void {
        if (self.state == .dead) return;
        const was_up = self.state == .up;
        dbg("link {s}: dead", .{self.host});
        // Leaving is a no-op when the link itself died (it let go of
        // every lessee first); otherwise the shared connection stays up
        // for its other users.
        if (was_up or self.state == .connecting) self.lessee.release();
        self.pending.clearRetainingCapacity();
        self.failed();
        for (registry.conns.items) |cn| {
            if (cn.remote) |*rm| {
                if (rm.link == self) {
                    rm.open = false;
                    cn.sess.markDead();
                }
            }
        }
    }

    /// Deliver what was queued; the shared link's writable watch drains
    /// a short write.
    pub fn armWriteWatch(self: *RemoteLink) void {
        if (self.state != .up) return;
        self.lessee.flush();
    }

    fn connByChan(self: *RemoteLink, chan: u32) ?*Conn {
        for (registry.conns.items) |cn| {
            if (cn.closing) continue;
            if (cn.remote) |*rm| {
                if (rm.link == self and rm.chan == chan) return cn;
            }
        }
        return null;
    }

    fn handleFrame(self: *RemoteLink, ftype: wire.FrameType, payload: []const u8) void {
        const f = struct { payload: []const u8 }{ .payload = payload };
        switch (ftype) {
            .lsp_reply => self.onLspReply(f.payload),
            .chan_data => {
                const id = wire.decodeChanId(f.payload) orelse return;
                const cn = self.connByChan(id) orelse return;
                cn.sess.feed(f.payload[4..]);
                if (cn.sess.state != .dead) cn.pumpWrite();
            },
            .chan_close => {
                const id = wire.decodeChanId(f.payload) orelse return;
                const cn = self.connByChan(id) orelse return;
                if (cn.remote) |*rm| rm.open = false;
                // A daemon that keeps the server's stderr ships its tail
                // after the channel id; an older one sends the id alone.
                if (f.payload.len > 4) cn.tail.feed(f.payload[4..]);
                // Same as a local server's stdout EOF.
                cn.sess.markDead();
            },
            // Anything else on the shared connection (file-service
            // frames of the host's other users, peer_info, ...) is not
            // for us.
            else => {},
        }
    }

    /// Queue an lsp_open for `tab`'s document, once. The candidate list
    /// is the CLIENT's config; which of them is installed, and where the
    /// root markers resolve, only the remote host can say.
    pub fn sendOpen(self: *RemoteLink, conf: *const Config, tab: *ETab) void {
        if (self.state != .up) return;
        for (self.pending.items) |p| {
            if (p.tab_id == tab.id) return;
        }
        const a = registry.alloc;
        const spec = tab.spec orelse return;
        const loc = paths.parseSpec(spec);
        const lang = tab.language.lspId();
        if (lang.len == 0) return;
        const candidates = conf.lspServerCandidates(lang, a) catch return;
        defer a.free(candidates);
        if (candidates.len == 0) return;
        const req = self.next_req;
        self.next_req += 1;
        self.pending.append(a, .{ .req = req, .tab_id = tab.id }) catch return;
        dbg("link {s}: lsp_open req={d} dir={s} ({d} candidates)", .{ self.host, req, servers.dirnameOf(loc.path), candidates.len });
        self.io().queueJson(.lsp_open, .{
            .req = req,
            .dir = servers.dirnameOf(loc.path),
            .servers = candidates,
        }) catch {
            self.markDead();
            return;
        };
        self.armWriteWatch();
    }

    /// Park `tab` until the dial lands, once.
    pub fn park(self: *RemoteLink, tab_id: u64) void {
        for (self.waiting.items) |id| {
            if (id == tab_id) return;
        }
        self.waiting.append(registry.alloc, tab_id) catch {};
    }

    fn takePending(self: *RemoteLink, req: u32) ?u64 {
        for (self.pending.items, 0..) |p, i| {
            if (p.req == req) {
                _ = self.pending.swapRemove(i);
                return p.tab_id;
            }
        }
        return null;
    }

    /// Ask the daemon to close (and thereby kill) a channel we ended up
    /// not using: a reply for a tab that closed meanwhile, or a duplicate
    /// spawn that lost the (name, root) dedupe race.
    pub fn discardChannel(self: *RemoteLink, chan: u32) void {
        if (self.state != .up) return;
        var hdr: [4]u8 = undefined;
        self.io().queueFrame(.chan_close, wire.putChanHeader(&hdr, chan)) catch {
            self.markDead();
            return;
        };
        self.armWriteWatch();
    }

    /// `lsp_reply` from the host's daemon: it picked a server, resolved
    /// the root on ITS filesystem and spawned, or found nothing, in
    /// which case the tab silently stays serverless.
    fn onLspReply(self: *RemoteLink, payload: []const u8) void {
        const Reply = struct {
            req: u32 = 0,
            ok: bool = false,
            chan: u32 = 0,
            name: []const u8 = "",
            root: []const u8 = "",
        };
        var parsed = std.json.parseFromSlice(Reply, registry.alloc, payload, .{
            .ignore_unknown_fields = true,
        }) catch return;
        defer parsed.deinit();
        const rep = parsed.value;
        const tab_id = self.takePending(rep.req) orelse {
            if (rep.ok) self.discardChannel(rep.chan);
            return;
        };
        if (!rep.ok) {
            dbg("link {s}: no server for req {d} (remote host has none installed)", .{ self.host, rep.req });
            return;
        }
        const mgr = registry.managerForTab(tab_id) orelse {
            // Closed while the request was in flight; the channel's
            // server was spawned for nothing — take it down.
            self.discardChannel(rep.chan);
            return;
        };
        const tab = mgr.view.findTabById(tab_id) orelse {
            self.discardChannel(rep.chan);
            return;
        };
        dbg("link {s}: {s} root={s} chan={d}", .{ self.host, rep.name, rep.root, rep.chan });
        if (registry.findRemoteConn(self, rep.name, rep.root)) |existing| {
            // Two documents of one project raced their lsp_opens: keep
            // the first server, kill the duplicate.
            self.discardChannel(rep.chan);
            mgr.bindTabToConn(tab, existing);
            return;
        }
        const conf = mgr.cfg() orelse {
            self.discardChannel(rep.chan);
            return;
        };
        const cn = registry.createRemoteConn(self, rep.name, rep.root, rep.chan, conf) orelse {
            self.discardChannel(rep.chan);
            return;
        };
        mgr.bindTabToConn(tab, cn);
    }
};

// ======================================================================
// Tests
// ======================================================================

test "editorlsp link: the redial wait doubles up to its ceiling" {
    const t = std.testing;
    try t.expectEqual(BACKOFF_MIN_MS, nextBackoff(0));
    try t.expectEqual(BACKOFF_MIN_MS * 2, nextBackoff(BACKOFF_MIN_MS));
    var b: i64 = 0;
    for (0..30) |_| b = nextBackoff(b);
    try t.expectEqual(BACKOFF_MAX_MS, b);
}

test "editorlsp link: a dead link is due only once its wait has passed" {
    const t = std.testing;
    var link = RemoteLink{ .host = @constCast(@as([]const u8, "box")) };
    link.state = .dead;
    link.retry_at_ms = 5_000;
    try t.expect(!link.due(4_999));
    try t.expect(link.due(5_000));
    link.state = .connecting;
    try t.expect(!link.due(9_999_999));
}
