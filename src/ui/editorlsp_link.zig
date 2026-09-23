//! Remote LSP transport: one dedicated mux connection per host, carrying
//! language servers' raw JSON-RPC as byte channels.
//!
//! The daemon on the file's host spawns the server near the files
//! (`lsp_open`) and relays its stdio; this side relays those bytes into
//! an ordinary `Session`. Only `Conn.pumpWrite` and `handleFrame` know the
//! transport is not a pipe. The link is separate from the editor's file
//! connections on purpose: those are short request/reply pumps that
//! would tangle with a long-lived multiplexed frame stream.
//!
//! ## A dead link is redialed on demand, with backoff
//!
//! The connect runs on a worker (the ssh bootstrap blocks) and hands
//! back through `g_idle_add`. A link that failed, or whose daemon
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
    /// Valid only while `.up`.
    conn: muxclient.Conn = undefined,
    watch_in: c_uint = 0,
    watch_out: c_uint = 0,
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
        self.dropLinkWatches();
        if (self.state == .up) self.conn.deinit();
        self.state = .dead;
        const a = registry.alloc;
        self.pending.deinit(a);
        self.waiting.deinit(a);
        a.free(self.host);
        a.destroy(self);
    }

    fn dropLinkWatches(self: *RemoteLink) void {
        for ([_]*c_uint{ &self.watch_in, &self.watch_out }) |w| {
            if (w.* != 0) _ = c.g_source_remove(w.*);
            w.* = 0;
        }
    }

    /// Whether a dead link may be redialed now.
    pub fn due(self: *const RemoteLink, now_ms: i64) bool {
        return self.state == .dead and now_ms >= self.retry_at_ms;
    }

    /// Start (or restart) the connect worker. The link is `.connecting`
    /// from here on, so attaches park on it.
    pub fn dial(self: *RemoteLink) void {
        self.state = .connecting;
        const a = std.heap.c_allocator;
        const job = a.create(LinkJob) catch return self.failed();
        const job_host = a.dupe(u8, self.host) catch {
            a.destroy(job);
            return self.failed();
        };
        job.* = .{ .host = job_host };
        const th = c.g_thread_new("sketerm-lsplink", @ptrCast(&linkThread), @ptrCast(job));
        if (th == null) {
            job.destroy();
            return self.failed();
        }
        c.g_thread_unref(th);
        dbg("link {s}: connecting", .{self.host});
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
        self.dropLinkWatches();
        if (was_up) self.conn.deinit();
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

    /// Non-blocking flush; a short write leaves the rest in the mux
    /// Conn's wbuf and a G_IO_OUT watch drains it.
    pub fn armWriteWatch(self: *RemoteLink) void {
        if (self.state != .up) return;
        self.conn.flushQueued() catch {
            self.markDead();
            return;
        };
        if (self.conn.wbuf.items.len > 0 and self.watch_out == 0) {
            self.watch_out = c.g_unix_fd_add(
                self.conn.fd,
                c.G_IO_OUT | c.G_IO_ERR | c.G_IO_HUP,
                @ptrCast(&onLinkWritable),
                @ptrCast(self),
            );
        }
    }

    fn onLinkWritable(_: c_int, cond: c.GIOCondition, user: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast.userData(RemoteLink, user);
        if (self.state != .up) {
            self.watch_out = 0;
            return 0;
        }
        if ((cond & (c.G_IO_ERR | c.G_IO_HUP)) != 0) {
            self.watch_out = 0;
            self.markDead();
            return 0;
        }
        self.conn.flushQueued() catch {
            self.watch_out = 0;
            self.markDead();
            return 0;
        };
        if (self.conn.wbuf.items.len == 0) {
            self.watch_out = 0;
            return 0;
        }
        return 1;
    }

    fn onLinkReadable(_: c_int, cond: c.GIOCondition, user: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast.userData(RemoteLink, user);
        if (self.state != .up) {
            self.watch_in = 0;
            return 0;
        }
        if (!self.conn.fillAvailable()) {
            self.watch_in = 0;
            self.markDead();
            return 0;
        }
        while (true) {
            const maybe = self.conn.takeFrame() catch {
                self.watch_in = 0;
                self.markDead();
                return 0;
            };
            const f = maybe orelse break;
            defer f.deinit(self.conn.allocator);
            self.handleFrame(f);
            if (self.state != .up) {
                self.watch_in = 0;
                return 0;
            }
        }
        if ((cond & (c.G_IO_ERR | c.G_IO_HUP)) != 0) {
            self.watch_in = 0;
            self.markDead();
            return 0;
        }
        // Handlers may have queued replies (didOpen after ready, ...).
        self.armWriteWatch();
        return 1;
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

    fn handleFrame(self: *RemoteLink, f: muxclient.Conn.OwnedFrame) void {
        switch (f.ftype) {
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
            // Anything else on this dedicated connection (peer_info,
            // marker pushes, ...) is not for us.
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
        self.conn.queueJson(.lsp_open, .{
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
        self.conn.queueFrame(.chan_close, wire.putChanHeader(&hdr, chan)) catch {
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

/// The blocking half of a link connect: ssh bootstrap + hello/welcome
/// on a g_thread, handed back to the GLib loop via idle. The registry is
/// process-lived, so the handback needs no liveness fence: it finds the
/// link by host or drops the connection.
const LinkJob = struct {
    /// Owned by the job (the link's copy may be freed while we run).
    host: []u8,
    conn: muxclient.Conn = undefined,
    ok: bool = false,
    lsp: bool = false,

    fn destroy(self: *LinkJob) void {
        const a = std.heap.c_allocator;
        a.free(self.host);
        a.destroy(self);
    }
};

fn linkThread(data: ?*anyopaque) callconv(.c) ?*anyopaque {
    const job = cast.userData(LinkJob, data);
    const a = std.heap.c_allocator;
    run: {
        var config = Config.load(a);
        defer config.deinit();
        const conn = muxclient.Conn.connectRemote(a, job.host, config.muxConnectOptions()) catch break :run;
        job.conn = conn;
        job.ok = true;
        job.lsp = conn.lsp_support;
    }
    _ = c.g_idle_add(@ptrCast(&linkIdle), @ptrCast(job));
    return null;
}

fn linkIdle(user: ?*anyopaque) callconv(.c) c.gboolean {
    const job = cast.userData(LinkJob, user);
    defer job.destroy();
    const link = registry.findLink(job.host) orelse {
        if (job.ok) job.conn.deinit();
        return 0;
    };
    if (link.state != .connecting) {
        if (job.ok) job.conn.deinit();
        return 0;
    }
    if (!job.ok or !job.lsp) {
        dbg("link {s}: {s}", .{ link.host, if (!job.ok) "connect failed" else "daemon has no lsp support" });
        if (job.ok) job.conn.deinit();
        link.failed();
        return 0;
    }
    link.conn = job.conn;
    link.conn.setNonBlocking();
    link.state = .up;
    link.backoff_ms = 0;
    link.watch_in = c.g_unix_fd_add(
        link.conn.fd,
        c.G_IO_IN | c.G_IO_ERR | c.G_IO_HUP,
        @ptrCast(&RemoteLink.onLinkReadable),
        @ptrCast(link),
    );
    dbg("link {s}: up", .{link.host});
    registry.onLinkUp(link);
    return 0;
}

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
