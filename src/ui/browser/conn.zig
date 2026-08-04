//! Per-host mux connections and the fs wire.
//!
//! Remote connects run on a worker thread with a g_idle_add handback
//! (a dead host degrades ONE tab, never the GUI), and every ready
//! connection is watched with g_unix_fd_add so the GLib loop is never
//! blocked on a reply. Listings are subscriptions (open_view): this
//! module owns the request numbering, the pending-listing table, and
//! the reply/delta dispatch into the rest of the view.

const std = @import("std");
const c = @import("../../c.zig").c;
const colkeys = @import("../../filebrowser/colkeys.zig");
const colview = @import("colview.zig");
const mediacols = @import("mediacols.zig");
const muxclient = @import("../../mux/client.zig");

const BTab = @import("types.zig").BTab;
const BrowserView = @import("view.zig").BrowserView;
const Dir = @import("types.zig").Dir;
const HostConn = @import("types.zig").HostConn;
const JobRow = @import("types.zig").JobRow;
const MAX_ATTR_COLUMNS = @import("render.zig").MAX_ATTR_COLUMNS;
const Pending = @import("types.zig").Pending;
const WireDelta = @import("types.zig").WireDelta;
const WireReply = @import("types.zig").WireReply;
const errorPhrase = @import("../../filebrowser/format.zig").errorPhrase;
const hostEq = @import("../../filebrowser/paths.zig").hostEq;

/// Heap context handed to the connect worker thread. The thread only
/// touches this struct (its own allocator for the Conn); the idle
/// handback runs on the main thread.
pub const ConnectCtx = struct {
    allocator: std.mem.Allocator,
    hc: *HostConn,
    host: []u8,
    /// Owned copy of Config.mux_udp_port_range (empty = unset); the
    /// worker cannot touch the config arena, which may be swapped
    /// by a reload while the connect is in flight.
    port_range: []u8 = &.{},
    /// Brokered UDP connection ticket (env from the spawning GUI, or
    /// minted in-process over a live terminal connection). The worker
    /// tries it first and falls back to the normal transports.
    ticket: ?muxclient.UdpTicket = null,
    result: ?muxclient.Conn = null,
};

/// The live (ready or connecting) connection for `host`, creating
/// one when needed. Dead connections are skipped, so navigating
/// again after a drop reconnects. null on immediate failure.
pub fn hostConnFor(self: *BrowserView, host: ?[]const u8) ?*HostConn {
    for (self.conns.items) |hc| {
        if (hc.state != .dead and hostEq(hc.host, host)) return hc;
    }
    const hc = self.allocator.create(HostConn) catch return null;
    hc.* = .{
        .view = self,
        .host = if (host) |h| (self.allocator.dupe(u8, h) catch {
            self.allocator.destroy(hc);
            return null;
        }) else null,
    };
    self.conns.append(self.allocator, hc) catch {
        if (hc.host) |h| self.allocator.free(h);
        self.allocator.destroy(hc);
        return null;
    };

    if (host == null) {
        // Local: synchronous autostart connect (fast; existing
        // GUI behavior for local panes).
        hc.conn = muxclient.Conn.connectLocalAutostart(self.allocator) catch {
            hc.state = .dead;
            self.setStatus("local daemon unreachable");
            return hc;
        };
        // A leftover daemon from before an upgrade keeps serving old
        // code forever; when it is idle, replace it now.
        if (hc.conn.upgradeStaleIdle(self.allocator)) {
            hc.conn.deinit();
            hc.conn = muxclient.Conn.connectLocalAutostart(self.allocator) catch {
                hc.state = .dead;
                self.setStatus("local daemon unreachable");
                return hc;
            };
        }
        self.wireReady(hc);
        return hc;
    }

    // Remote: worker thread; Conn buffers use the C allocator
    // (thread-safe) since the connect runs off-main.
    const ctx = self.allocator.create(ConnectCtx) catch return hc;
    ctx.* = .{
        .allocator = self.allocator,
        .hc = hc,
        .host = self.allocator.dupe(u8, host.?) catch {
            self.allocator.destroy(ctx);
            return hc;
        },
    };
    var cfg = @import("../../config.zig").Config.load(self.allocator);
    defer cfg.deinit();
    if (cfg.udpRange()) |range| {
        ctx.port_range = self.allocator.dupe(u8, range) catch &.{};
    }
    // Connection-ticket brokering: reach a UDP host's daemon over a
    // pre-minted single-use listener instead of a fresh ssh bootstrap.
    // A spawned files process gets its ticket from the GUI via env; a
    // browser pane inside the terminal GUI mints one over a live UDP
    // terminal connection to the same host (async — the worker thread
    // starts when the mint resolves, ticket or not).
    if (muxclient.takeTicketFromEnv(ctx.host)) |ticket| {
        ctx.ticket = ticket;
    } else if (self.ownerWindow()) |win| {
        const remotectl = @import("../remotectl.zig");
        const bare = muxclient.RemoteSpec.parse(ctx.host).host;
        if (remotectl.mintUdpTicket(win, bare, @ptrCast(ctx), onMintForConnect)) {
            self.setStatusFmt("connecting to {s}…", .{host.?});
            return hc;
        }
    }
    startConnectThread(ctx);
    self.setStatusFmt("connecting to {s}…", .{host.?});
    return hc;
}

/// Ticket mint resolved (ticket or null) — start the connect worker.
/// The view may have moved on during the wait: mirror onConnectIdle's
/// orphan/dead handling, because with no thread spawned yet nobody
/// else will free this HostConn.
fn onMintForConnect(user: ?*anyopaque, ticket: ?muxclient.UdpTicket) void {
    const ctx: *ConnectCtx = @ptrCast(@alignCast(user.?));
    const hc = ctx.hc;
    const allocator = ctx.allocator;
    if (hc.orphaned) {
        if (ctx.port_range.len > 0) allocator.free(ctx.port_range);
        allocator.free(ctx.host);
        allocator.destroy(ctx);
        if (hc.host) |h| allocator.free(h);
        allocator.destroy(hc);
        return;
    }
    if (hc.view.widgets_dead) {
        hc.state = .dead;
        if (ctx.port_range.len > 0) allocator.free(ctx.port_range);
        allocator.free(ctx.host);
        allocator.destroy(ctx);
        return;
    }
    ctx.ticket = ticket;
    startConnectThread(ctx);
}

/// Spawn the connect worker, taking ownership of `ctx`. On spawn
/// failure the HostConn dies and every listing queued on it is
/// refused (they would otherwise sit at "Listing…" forever).
fn startConnectThread(ctx: *ConnectCtx) void {
    const hc = ctx.hc;
    const view = hc.view;
    const allocator = ctx.allocator;
    const th = std.Thread.spawn(.{}, connectThreadMain, .{ctx}) catch {
        hc.state = .dead;
        view.setStatusFmt("cannot start connection to {s}", .{hc.label()});
        var buf: [256]u8 = undefined;
        const why = std.fmt.bufPrint(&buf, "cannot connect to {s}", .{hc.label()}) catch "cannot connect";
        view.failPendingListings(hc, why);
        if (ctx.port_range.len > 0) allocator.free(ctx.port_range);
        allocator.free(ctx.host);
        allocator.destroy(ctx);
        return;
    };
    th.detach();
}

pub fn connectThreadMain(ctx: *ConnectCtx) void {
    const alloc = std.heap.c_allocator;
    if (ctx.ticket) |ticket| {
        if (muxclient.Conn.connectUdpTicket(alloc, ctx.host, ticket)) |conn| {
            ctx.result = upgradeReconnect(alloc, ctx, conn);
            _ = c.g_idle_add(@ptrCast(&onConnectIdle), @ptrCast(ctx));
            return;
        } else |_| {}
        // Ticket didn't carry (listener expired, filtered UDP): the
        // normal transports below are the unchanged fallback.
    }
    const result = muxclient.Conn.connectRemote(
        alloc,
        ctx.host,
        if (ctx.port_range.len > 0) ctx.port_range else null,
    );
    if (result) |conn| {
        ctx.result = upgradeReconnect(alloc, ctx, conn);
    } else |_| {
        ctx.result = null;
    }
    _ = c.g_idle_add(@ptrCast(&onConnectIdle), @ptrCast(ctx));
}

/// Stale-daemon upgrade, on the worker thread where blocking is
/// cheap: an idle daemon of a different build is asked to exit and
/// the reconnect autostarts the freshly deployed binary. One attempt;
/// any failure keeps or replaces the connection best-effort — a
/// still-stale daemon is served as-is (and the status line says so).
fn upgradeReconnect(alloc: std.mem.Allocator, ctx: *ConnectCtx, conn: muxclient.Conn) ?muxclient.Conn {
    var live = conn;
    if (!live.upgradeStaleIdle(alloc)) return live;
    live.deinit();
    if (muxclient.Conn.connectRemote(
        alloc,
        ctx.host,
        if (ctx.port_range.len > 0) ctx.port_range else null,
    )) |fresh| {
        return fresh;
    } else |_| {
        return null;
    }
}

pub fn onConnectIdle(user: ?*anyopaque) callconv(.c) c.gboolean {
    const ctx: *ConnectCtx = @ptrCast(@alignCast(user.?));
    const hc = ctx.hc;
    const allocator = ctx.allocator;
    defer {
        if (ctx.port_range.len > 0) allocator.free(ctx.port_range);
        allocator.free(ctx.host);
        allocator.destroy(ctx);
    }
    if (hc.orphaned) {
        if (ctx.result) |conn| {
            var mut = conn;
            mut.deinit();
        }
        if (hc.host) |h| allocator.free(h);
        allocator.destroy(hc);
        return 0;
    }
    const view = hc.view;
    if (view.widgets_dead) {
        if (ctx.result) |conn| {
            var mut = conn;
            mut.deinit();
        }
        hc.state = .dead;
        return 0;
    }
    if (ctx.result) |conn| {
        hc.conn = conn;
        view.wireReady(hc);
        const remote = muxclient.RemoteSpec.parse(ctx.host);
        if (conn.buildStale()) {
            // Busy daemons cannot be bounced (their sessions are the
            // user's running work) — but serving old code silently is
            // how "the fix didn't work" happens. Say it.
            view.setStatusFmt(
                "{s}: daemon runs an older sketerm build (busy; upgrades when its sessions end)",
                .{remote.host},
            );
        } else if (remote.mode == .auto and conn.transport == .ssh) {
            view.setStatusFmt("UDP unavailable; connected to {s} over SSH", .{remote.host});
        } else {
            view.setStatusFmt("connected to {s} over {s}", .{ remote.host, @tagName(conn.transport) });
        }
    } else {
        hc.state = .dead;
        view.setStatusFmt("cannot connect to {s}", .{hc.label()});
        view.pumpDeferredTransfers();
        view.pumpCopyAcks();
        // The listings queued while connecting will never be answered.
        // Without this the tabs that asked for them sit at "Listing..."
        // for good, which reads like a slow host rather than a dead one.
        var buf: [256]u8 = undefined;
        const why = std.fmt.bufPrint(&buf, "cannot connect to {s}", .{hc.label()}) catch "cannot connect";
        view.failPendingListings(hc, why);
    }
    return 0;
}

/// Refuse every in-flight listing on `hc`, recording `reason` where
/// the listing was going to be shown. A dropped listing that leaves no
/// trace is indistinguishable from a directory that is still loading.
pub fn failPendingListings(self: *BrowserView, hc: *HostConn, reason: []const u8) void {
    var i: usize = 0;
    while (i < self.pending.items.len) {
        const p = self.pending.items[i];
        if (p.hc != hc) {
            i += 1;
            continue;
        }
        if (p.navigation != null) {
            if (p.navigation_generation == p.tab.navigation_generation) p.tab.setNavError(reason);
        } else if (!p.dir.loaded) {
            p.dir.setLoadError(reason);
        }
        self.dropPending(i);
    }
    self.renderCurrent();
}

/// Make a freshly connected HostConn live: non-blocking fd, GLib
/// watch, and flush every request that queued while connecting.
pub fn wireReady(self: *BrowserView, hc: *HostConn) void {
    hc.conn.setNonBlocking();
    hc.state = .ready;
    hc.watch_id = c.g_unix_fd_add(
        hc.conn.fd,
        c.G_IO_IN | c.G_IO_HUP | c.G_IO_ERR,
        @ptrCast(&onFdReadable),
        @ptrCast(hc),
    );
    for (self.pending.items) |p| {
        if (p.sent or p.hc != hc) continue;
        self.sendListingOp(p);
    }
    // Tabs stranded on a DEAD HostConn to this same host adopt the
    // fresh connection and re-subscribe their views (the old view
    // subscriptions died with the old socket).
    for (self.tabs.items) |tab| {
        if (tab.hc == hc or tab.hc.state != .dead or !hostEq(tab.hc.host, hc.host)) continue;
        tab.hc = hc;
        tab.free_req = 0;
        tab.free_dirty = false;
        tab.free_bytes = null;
        tab.root.view_id = 0;
        self.openDir(tab, tab.root);
        for (tab.subdirs.items) |d| {
            d.view_id = 0;
            self.openDir(tab, d);
        }
    }
    self.clearReconnect(hc.host);
    self.requestHostDirs(hc);
    self.pumpTransferQueue();
    self.pumpCopyQueue();
    self.pumpDeferredTransfers();
    @import("jobs.zig").pumpCopyAcks(self);
    // Warm the host's FUSE mount NOW, while the user is still
    // browsing: the mount helper's own connect (ssh auth, deploy
    // check) is the whole latency of the first double-click open.
    if (hc.host) |host| _ = @import("../hostmount.zig").ensure(self.allocator, host);
}

/// One host being re-dialed after a drop, with backoff. Owned by
/// BrowserView.reconnects; the timer holds the pointer.
pub const Reconnect = struct {
    view: *BrowserView,
    host: []u8,
    attempts: u32 = 0,
    source: c.guint = 0,

    pub fn destroy(self: *Reconnect, allocator: std.mem.Allocator) void {
        if (self.source != 0) _ = c.g_source_remove(self.source);
        allocator.free(self.host);
        allocator.destroy(self);
    }
};

/// Re-dial delays; after the last one the host stays dead until the
/// user navigates (every attempt may spawn a real ssh).
const RECONNECT_DELAYS_MS = [_]c.guint{ 3_000, 8_000, 20_000, 45_000 };

/// A connection dropped while tabs were on it: retry by timer so a
/// rebooted host comes back without the user re-navigating.
pub fn scheduleReconnect(self: *BrowserView, host: []const u8) void {
    for (self.reconnects.items) |r| {
        if (std.mem.eql(u8, r.host, host)) return;
    }
    const r = self.allocator.create(Reconnect) catch return;
    r.* = .{
        .view = self,
        .host = self.allocator.dupe(u8, host) catch {
            self.allocator.destroy(r);
            return;
        },
    };
    self.reconnects.append(self.allocator, r) catch {
        self.allocator.free(r.host);
        self.allocator.destroy(r);
        return;
    };
    r.source = c.g_timeout_add(RECONNECT_DELAYS_MS[0], @ptrCast(&onReconnectTick), @ptrCast(r));
}

pub fn clearReconnect(self: *BrowserView, host: ?[]const u8) void {
    const h = host orelse return;
    for (self.reconnects.items, 0..) |r, i| {
        if (!std.mem.eql(u8, r.host, h)) continue;
        _ = self.reconnects.orderedRemove(i);
        r.destroy(self.allocator);
        return;
    }
}

fn onReconnectTick(user: ?*anyopaque) callconv(.c) c.gboolean {
    const r: *Reconnect = @ptrCast(@alignCast(user.?));
    const self = r.view;
    r.source = 0;
    if (self.widgets_dead) return 0;
    // Anything already live (or dialing) for this host? Then this
    // timer's job is done — wireReady adopts the stranded tabs.
    for (self.conns.items) |hc| {
        if (hc.state != .dead and hostEq(hc.host, r.host)) {
            self.clearReconnect(r.host);
            return 0;
        }
    }
    // Still worth dialing? Only while a tab is stranded on this host.
    var stranded = false;
    for (self.tabs.items) |tab| {
        if (tab.hc.state == .dead and hostEq(tab.hc.host, r.host)) stranded = true;
    }
    if (!stranded) {
        self.clearReconnect(r.host);
        return 0;
    }
    r.attempts += 1;
    if (r.attempts > RECONNECT_DELAYS_MS.len) {
        self.setStatusFmt("gave up reconnecting to {s} -- navigate to retry", .{r.host});
        self.clearReconnect(r.host);
        return 0;
    }
    self.setStatusFmt("reconnecting to {s} (attempt {d})…", .{ r.host, r.attempts });
    var host_buf: [512]u8 = undefined;
    const n = @min(r.host.len, host_buf.len);
    @memcpy(host_buf[0..n], r.host[0..n]);
    _ = self.hostConnFor(host_buf[0..n]);
    const next = RECONNECT_DELAYS_MS[@min(r.attempts, RECONNECT_DELAYS_MS.len - 1)];
    r.source = c.g_timeout_add(next, @ptrCast(&onReconnectTick), @ptrCast(r));
    return 0;
}

/// Ask the host to identify its own directories -- once per
/// connection, at connect time so the answer is there before the
/// first menu needs it.
///
/// This is the single `homedir` request path. templates.zig used to
/// issue its own because this one was never sent (the request number
/// was read and cleared but never assigned), which left two request
/// paths for one reply. Callers read the answer off the HostConn.
pub fn requestHostDirs(self: *BrowserView, hc: *HostConn) void {
    if (hc.dirs_known or hc.dirs_req != 0 or hc.state != .ready) return;
    hc.dirs_req = self.nextReq();
    self.sendOp(hc, .{ .req = hc.dirs_req, .op = "homedir", .path = "/" });
}

/// Connection died: fail its transfers FIRST (they hold *Conn),
/// then release the socket. Tabs keep referencing the dead
/// HostConn; navigating again reconnects.
fn rememberRedispatch(self: *BrowserView, list: *std.ArrayList([]u8), token: []const u8) void {
    for (list.items) |existing| if (std.mem.eql(u8, existing, token)) return;
    const owned = self.allocator.dupe(u8, token) catch return;
    list.append(self.allocator, owned) catch self.allocator.free(owned);
}

pub fn hostDied(self: *BrowserView, hc: *HostConn) void {
    var redispatch: std.ArrayList([]u8) = .empty;
    defer {
        for (redispatch.items) |token| self.allocator.free(token);
        redispatch.deinit(self.allocator);
    }
    mediacols.hostDied(self, hc);
    // In-flight listings can never be answered. A navigation
    // request also OWNS its candidate directory until it commits,
    // so dropping it here is what frees it -- and whatever was
    // waiting for one is told why it is not coming.
    var lost_buf: [256]u8 = undefined;
    const lost = std.fmt.bufPrint(&lost_buf, "connection to {s} lost", .{hc.label()}) catch "connection lost";
    self.failPendingListings(hc, lost);
    var i: usize = 0;
    while (i < self.transfers.items.len) {
        const t = self.transfers.items[i];
        if (t.src_hc == hc or t.dst_hc == hc) {
            self.setStatusFmt("transfer failed: connection to {s} lost", .{hc.label()});
            if (t.upload_watch) |wt| wt.uploading = false;
            if (t.token) |token| rememberRedispatch(self, &redispatch, token);
            t.x.deinit();
            self.allocator.free(t.label);
            t.freeExtras(self.allocator);
            self.allocator.destroy(t);
            _ = self.transfers.orderedRemove(i);
        } else i += 1;
    }
    i = 0;
    while (i < self.pending_jobs.items.len) {
        const pj = self.pending_jobs.items[i];
        if (pj.hc != hc or pj.retry == null) {
            i += 1;
            continue;
        }
        if (pj.retry) |retry| {
            rememberRedispatch(self, &redispatch, retry.token);
            retry.destroy(self.allocator);
        }
        self.allocator.free(pj.label);
        self.allocator.destroy(pj);
        _ = self.pending_jobs.orderedRemove(i);
    }
    i = 0;
    while (i < self.drop_probes.items.len) {
        const probe = self.drop_probes.items[i];
        if (probe.dst_hc != hc and probe.src_hc != hc) {
            i += 1;
            continue;
        }
        _ = self.drop_probes.orderedRemove(i);
        if (probe.manifest_token) |token| self.settleUserBatch(token);
        probe.destroy(self.allocator);
        self.setStatus("drop canceled because a host disconnected");
    }
    i = 0;
    while (i < self.jobs.items.len) {
        const row = self.jobs.items[i];
        if (row.hc != hc or row.retry == null) {
            i += 1;
            continue;
        }
        if (row.retry) |retry| {
            rememberRedispatch(self, &redispatch, retry.token);
            retry.destroy(self.allocator);
        }
        self.allocator.free(row.label);
        self.allocator.destroy(row);
        _ = self.jobs.orderedRemove(i);
    }
    i = 0;
    while (i < self.copy_acks.items.len) {
        const ack = self.copy_acks.items[i];
        if (ack.hc != hc) {
            i += 1;
            continue;
        }
        rememberRedispatch(self, &redispatch, ack.token);
        self.allocator.free(ack.token);
        _ = self.copy_acks.orderedRemove(i);
    }
    i = 0;
    while (i < self.pending_history.items.len) {
        const ph = self.pending_history.items[i];
        if (ph.hc == hc) {
            ph.op.destroy(self.allocator);
            _ = self.pending_history.orderedRemove(i);
            self.history_busy = false;
            self.setStatus("history outcome unknown after connection loss");
        } else i += 1;
    }
    for (self.pending_jobs.items) |pj| {
        if (pj.hc == hc and pj.history_op != null) {
            pj.history_op.?.destroy(self.allocator);
            pj.history_op = null;
            pj.history_direction = null;
            self.history_busy = false;
        }
    }
    for (self.jobs.items) |job| {
        if (job.hc == hc and job.history_op != null) {
            job.history_op.?.destroy(self.allocator);
            job.history_op = null;
            job.history_direction = null;
            self.history_busy = false;
        }
    }
    self.previewHostDied(hc);
    self.endProbesFor(hc, "host connection lost");
    if (self.git_rhc == hc) {
        self.git_rhc = null;
        self.git_rreq = 0;
        self.git_rjob = 0;
    }
    if (self.diff.hc == hc) {
        self.diff.hc = null;
        self.diff.req = 0;
        self.diff.job = 0;
    }
    if (self.attr_request) |request| {
        if (request.hc == hc) self.endAttrRequest();
    }
    if (self.snap_request) |sr| {
        if (sr.hc == hc) @import("props.zig").snapDegrade(self);
    }
    i = 0;
    while (i < self.remote_thumbs.items.len) {
        const rt = self.remote_thumbs.items[i];
        if (rt.hc == hc) {
            _ = self.remote_thumbs.orderedRemove(i);
            rt.destroy(self.allocator);
        } else i += 1;
    }
    i = 0;
    while (i < self.remote_thumb_queue.items.len) {
        const rt = self.remote_thumb_queue.items[i];
        if (rt.hc == hc) {
            _ = self.remote_thumb_queue.orderedRemove(i);
            rt.destroy(self.allocator);
        } else i += 1;
    }
    self.pumpRemoteThumbs();
    hc.watch_id = 0;
    if (hc.write_watch_id != 0) {
        _ = c.g_source_remove(hc.write_watch_id);
        hc.write_watch_id = 0;
    }
    if (hc.drain_idle != 0) {
        _ = c.g_source_remove(hc.drain_idle);
        hc.drain_idle = 0;
    }
    hc.conn.deinit();
    hc.state = .dead;
    self.pumpCopyQueue();
    self.pumpDeferredTransfers();
    if (self.transfer_service) |service| {
        for (redispatch.items) |token| service.redispatchMediated(token);
    }
    self.renderJobs();
    // A remote host with tabs still on it gets re-dialed by timer; a
    // local daemon reconnects on the next op anyway.
    if (hc.host) |host| {
        var stranded = false;
        for (self.tabs.items) |tab| {
            if (tab.hc == hc) stranded = true;
        }
        if (stranded) {
            self.setStatusFmt("connection to {s} lost — reconnecting…", .{hc.label()});
            self.scheduleReconnect(host);
            return;
        }
    }
    self.setStatusFmt("connection to {s} lost — navigate to reconnect", .{hc.label()});
}

pub fn sendOp(self: *BrowserView, hc: *HostConn, args: anytype) void {
    _ = self.sendOpOk(hc, args);
}

pub fn sendOpOk(self: *BrowserView, hc: *HostConn, args: anytype) bool {
    if (hc.state != .ready) {
        self.setStatusFmt("not connected to {s}", .{hc.label()});
        return false;
    }
    hc.conn.queueJson(.fs_op, args) catch {
        self.setStatus("daemon connection lost");
        return false;
    };
    self.ensureWriteFlush(hc);
    return true;
}

pub fn closeViewOf(self: *BrowserView, hc: *HostConn, dir: *Dir) void {
    if (dir.view_id == 0 or hc.state != .ready) return;
    hc.conn.queueJson(.fs_op, .{
        .req = @as(u32, 0),
        .op = "close_view",
        .view = dir.view_id,
    }) catch {};
    self.ensureWriteFlush(hc);
}

/// Sends on the GUI thread only queue (a stalled host must degrade
/// its own pane, never wedge the GLib loop on POLLOUT): whenever a
/// send leaves a wbuf remainder, a writable-fd watch finishes the
/// delivery.
pub fn ensureWriteFlush(self: *BrowserView, hc: *HostConn) void {
    _ = self;
    if (hc.state != .ready or hc.write_watch_id != 0) return;
    if (hc.conn.wbuf.items.len == 0) return;
    hc.write_watch_id = c.g_unix_fd_add(
        hc.conn.fd,
        c.G_IO_OUT | c.G_IO_HUP | c.G_IO_ERR,
        @ptrCast(&onFdWritable),
        @ptrCast(hc),
    );
}

/// The read watch normally removes itself by returning 0 from
/// onFdReadable; a death discovered on the WRITE side must remove it
/// explicitly or it keeps firing on a dead fd.
fn dropReadWatch(hc: *HostConn) void {
    if (hc.watch_id != 0) {
        _ = c.g_source_remove(hc.watch_id);
        hc.watch_id = 0;
    }
}

fn onFdWritable(fd: c_int, cond: c.GIOCondition, user: ?*anyopaque) callconv(.c) c.gboolean {
    _ = fd;
    const hc: *HostConn = @ptrCast(@alignCast(user.?));
    const self = hc.view;
    if (self.widgets_dead) {
        hc.write_watch_id = 0;
        return 0;
    }
    if (cond & (c.G_IO_HUP | c.G_IO_ERR) != 0) {
        hc.write_watch_id = 0;
        dropReadWatch(hc);
        self.hostDied(hc);
        return 0;
    }
    hc.conn.flushQueued() catch {
        hc.write_watch_id = 0;
        dropReadWatch(hc);
        self.hostDied(hc);
        return 0;
    };
    if (hc.conn.wbuf.items.len == 0) {
        hc.write_watch_id = 0;
        return 0;
    }
    return 1;
}

/// The tab's EXTENDED-ATTRIBUTE columns as the wire's
/// comma-separated request. Empty when the tab shows none, so
/// ordinary listings pay nothing for the feature.
///
/// Media columns are deliberately absent: their values are not
/// xattrs, they come from a batched media_meta job (mediacols.zig).
/// That is also why Entry.attrs stays dense over the XATTR columns
/// only, and colkeys.subIndex maps a column position into it.
pub fn attrSpec(self: *BrowserView, tab: *BTab, buf: []u8) []const u8 {
    var emblem_names: [MAX_ATTR_COLUMNS][]const u8 = undefined;
    const wanted = self.emblems.attrNames(&emblem_names);
    const xattr_columns = colkeys.countOf(tab.attr_columns.items, .xattr);
    if (xattr_columns == 0 and wanted.len == 0) return "";
    var w = std.Io.Writer.fixed(buf);
    var n: usize = 0;
    for (tab.attr_columns.items) |name| {
        if (colkeys.sourceOf(name) != .xattr) continue;
        if (n > 0) w.writeByte(',') catch break;
        w.writeAll(name) catch break;
        n += 1;
    }
    // Emblem attributes ride the same listing; the column values
    // stay first so row rendering can index by column position.
    for (wanted) |name| {
        var dup = false;
        for (tab.attr_columns.items) |col| {
            if (colkeys.sourceOf(col) != .xattr) continue;
            if (std.mem.eql(u8, col, name)) dup = true;
        }
        if (dup or n >= MAX_ATTR_COLUMNS) continue;
        if (n > 0) w.writeByte(',') catch break;
        w.writeAll(name) catch break;
        n += 1;
    }
    return w.buffered();
}

pub fn sendListingOp(self: *BrowserView, p: *Pending) void {
    p.sent = true;
    var spec_buf: [1024]u8 = undefined;
    const attrs = self.attrSpec(p.tab, &spec_buf);
    switch (p.op) {
        .open_view => self.sendOp(p.hc, .{
            .req = p.req,
            .op = "open_view",
            .path = p.dir.path,
            .view = p.dir.view_id,
            .attrs = attrs,
        }),
        .list => self.sendOp(p.hc, .{
            .req = p.req,
            .op = "list",
            .path = p.dir.path,
            .attrs = attrs,
        }),
    }
    // Free space rides every root listing: navigation, reload and
    // resync all keep the status line's figure current for cheap.
    if (p.dir == p.tab.root) self.requestFreeSpace(p.tab);
}

/// Coalesced statfs refresh for one tab's current root.
pub fn requestFreeSpace(self: *BrowserView, tab: *BTab) void {
    if (tab.free_req != 0) {
        tab.free_dirty = true;
        return;
    }
    if (tab.hc.state != .ready) return;
    tab.free_dirty = false;
    tab.free_req = self.nextReq();
    self.sendOp(tab.hc, .{ .req = tab.free_req, .op = "statfs", .path = tab.root.path });
}

const FreeSpaceReply = struct {
    bytes: ?u64,
    refresh: bool,
};

fn freeSpaceReply(ok: bool, bavail: u64, frsize: u64, dirty: bool) FreeSpaceReply {
    if (dirty) return .{ .bytes = null, .refresh = true };
    const bytes = if (ok and frsize > 0 and bavail <= std.math.maxInt(u64) / frsize)
        bavail * frsize
    else
        null;
    return .{ .bytes = bytes, .refresh = false };
}

/// Subscribe a directory and start collecting its listing. When
/// the tab's host is still connecting, the request queues and the
/// connect handback sends it.
pub fn openDir(self: *BrowserView, tab: *BTab, dir: *Dir) void {
    self.queueListing(tab, dir, .open_view);
}

/// Refetch a live dir's entries without dropping its view (the
/// resync path): one-shot `list` reusing the Pending accumulator.
pub fn refreshDir(self: *BrowserView, tab: *BTab, dir: *Dir) void {
    self.queueListing(tab, dir, .list);
}

pub fn queueListing(self: *BrowserView, tab: *BTab, dir: *Dir, op: @FieldType(Pending, "op")) void {
    const req = self.nextReq();
    const p = self.allocator.create(Pending) catch return;
    p.* = .{ .req = req, .tab = tab, .dir = dir, .hc = tab.hc, .op = op };
    self.pending.append(self.allocator, p) catch {
        self.allocator.destroy(p);
        return;
    };
    if (tab.hc.state == .ready) {
        self.sendListingOp(p);
    } else if (tab.hc.state == .dead) {
        // Nothing will ever answer this one, so the listing area is
        // told now rather than left looking like a slow host.
        var buf: [256]u8 = undefined;
        const why = std.fmt.bufPrint(&buf, "not connected to {s}", .{tab.hc.label()}) catch "not connected";
        self.setStatus(why);
        dir.setLoadError(why);
    }
}

pub fn nextReq(self: *BrowserView) u32 {
    const r = self.next_req;
    self.next_req +%= 1;
    if (self.next_req == 0) self.next_req = 1;
    return r;
}

/// Frame-parse budget per main-loop dispatch. fillAvailable buffers
/// up to 4 MB per call; parsing it all in one dispatch stalls input
/// for as long as a fast host keeps the pipe full. Leftovers continue
/// on an idle so clicks interleave with the parse.
const DRAIN_BUDGET_US: i64 = 8_000;

/// Parse buffered frames for at most the budget.
/// @return true when the budget ran out with frames still buffered.
fn drainFrames(self: *BrowserView, hc: *HostConn) bool {
    const deadline = c.g_get_monotonic_time() + DRAIN_BUDGET_US;
    var dirty = false;
    var xfer_touched = false;
    var over_budget = false;
    while (true) {
        // A reply can end the view mid-drain: the picker's typed-name
        // probe accepts a path, which delivers and destroys the
        // picker window. Nothing after that fence may be fed.
        if (self.widgets_dead) break;
        if (c.g_get_monotonic_time() > deadline) {
            // Possibly nothing left; the idle drains once for free.
            over_budget = true;
            break;
        }
        const f = (hc.conn.takeFrame() catch null) orelse break;
        // The frame payload belongs to the CONN's allocator (the
        // C allocator for thread-connected remotes), not ours.
        defer f.deinit(hc.conn.allocator);
        if (self.feedTransfers(hc, f.ftype, f.payload)) {
            xfer_touched = true;
            continue;
        }
        if (self.feedPreview(hc, f.ftype, f.payload)) continue;
        if (self.feedRestore(hc, f.ftype, f.payload)) continue;
        if (self.feedRemoteThumb(hc, f.ftype, f.payload)) continue;
        if (self.feedProbes(hc, f.ftype, f.payload)) continue;
        if (self.feedAttrRequest(hc, f.ftype, f.payload)) continue;
        if (self.feedSnapRequest(hc, f.ftype, f.payload)) continue;
        if (self.feedGit(hc, f.ftype, f.payload)) continue;
        if (self.feedDiff(hc, f.ftype, f.payload)) continue;
        if (mediacols.feed(self, hc, f.ftype, f.payload)) continue;
        switch (f.ftype) {
            .fs_reply => {
                if (self.onReply(hc, f.payload)) dirty = true;
            },
            .fs_delta => {
                if (self.onDelta(hc, f.payload)) dirty = true;
            },
            .fs_job => self.onJobEvent(hc, f.payload),
            else => {},
        }
    }
    if (xfer_touched) self.reapTransfers();
    if (xfer_touched) self.renderJobs();
    if (xfer_touched) {
        // fstransfer sends only QUEUE; a chunk that outgrew the
        // socket buffer needs the writable watch to finish delivery.
        for (self.transfers.items) |t| {
            self.ensureWriteFlush(t.src_hc);
            self.ensureWriteFlush(t.dst_hc);
        }
    }
    // Socket-driven renders are throttled: chunk runs and delta
    // storms otherwise rebuild the listing model per drain, which
    // eats clicks and flickers hover for as long as the data trickles.
    if (dirty) self.scheduleListingRender();
    return over_budget;
}

fn ensureDrainIdle(hc: *HostConn) void {
    if (hc.drain_idle != 0) return;
    hc.drain_idle = c.g_idle_add(@ptrCast(&onDrainIdle), @ptrCast(hc));
}

fn onDrainIdle(user: ?*anyopaque) callconv(.c) c.gboolean {
    const hc: *HostConn = @ptrCast(@alignCast(user.?));
    const self = hc.view;
    if (self.widgets_dead or hc.state != .ready) {
        hc.drain_idle = 0;
        return 0;
    }
    const alive = hc.conn.fillAvailable();
    const more = drainFrames(self, hc);
    if (!alive) {
        hc.drain_idle = 0;
        dropReadWatch(hc);
        self.hostDied(hc);
        return 0;
    }
    if (more) return 1;
    hc.drain_idle = 0;
    return 0;
}

pub fn onFdReadable(fd: c_int, cond: c.GIOCondition, user: ?*anyopaque) callconv(.c) c.gboolean {
    _ = fd;
    const hc: *HostConn = @ptrCast(@alignCast(user.?));
    const self = hc.view;
    if (self.widgets_dead) {
        hc.watch_id = 0;
        return 0;
    }
    const alive = hc.conn.fillAvailable();
    const more = drainFrames(self, hc);
    if (more) ensureDrainIdle(hc);
    if (!alive or cond & (c.G_IO_HUP | c.G_IO_ERR) != 0) {
        self.hostDied(hc);
        return 0;
    }
    return 1;
}

pub fn onReply(self: *BrowserView, hc: *HostConn, payload: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const rep = std.json.parseFromSliceLeaky(WireReply, arena.allocator(), payload, .{
        .ignore_unknown_fields = true,
    }) catch return false;
    if (rep.req == 0) return false;

    for (self.copy_acks.items, 0..) |ack, i| {
        if (ack.req != rep.req) continue;
        if (!rep.ok and !std.mem.eql(u8, rep.@"error", "no such job")) {
            self.copy_acks.items[i].req = 0;
            self.copy_acks.items[i].attempts +|= 1;
            if (self.retry_timer == 0)
                self.retry_timer = c.g_timeout_add(1000, @ptrCast(&@import("jobs.zig").onRetryTimer), @ptrCast(self));
            return false;
        }
        const completed = self.copy_acks.orderedRemove(i);
        if (self.transfer_service) |service| _ = service.mediatedAcked(completed.token, completed.job);
        self.allocator.free(completed.token);
        return false;
    }

    for (self.tabs.items) |tab| {
        if (tab.free_req != 0 and tab.free_req == rep.req) {
            const result = freeSpaceReply(rep.ok, rep.bavail, rep.frsize, tab.free_dirty);
            tab.free_req = 0;
            tab.free_bytes = result.bytes;
            tab.free_dirty = false;
            if (result.refresh) self.requestFreeSpace(tab);
            return if (self.currentTab()) |cur| cur == tab else false;
        }
    }

    if (self.completion_request) |completion| {
        if (completion.hc == hc and completion.req == rep.req) {
            if (!rep.ok) {
                completion.destroy(self.allocator);
                self.completion_request = null;
                return false;
            }
            for (rep.entries) |entry| {
                if (!entry.tdir) continue;
                const name = self.allocator.dupe(u8, entry.name) catch continue;
                completion.names.append(self.allocator, name) catch self.allocator.free(name);
            }
            if (!rep.more) {
                self.showCompletionNames(completion.display_prefix, completion.typed_prefix, completion.names.items);
                completion.destroy(self.allocator);
                self.completion_request = null;
            }
            return false;
        }
    }

    // The file picker's typed-name stat probe?
    if (self.picker) |pk| {
        if (pk.on_reply) |claim| {
            const is_dir: ?bool = if (rep.entry) |e| e.tdir else null;
            if (claim(pk.ctx, rep.req, rep.ok, is_dir)) return false;
        }
    }
    // A breadcrumb segment's sibling listing?
    if (self.feedSiblings(hc, rep)) return false;
    // A parked paste collision waiting on its two stat replies?
    if (self.feedConflicts(hc, rep)) return false;
    // A drag waiting for a destination collision check?
    if (@import("ops.zig").feedDropProbe(self, hc, rep)) return false;
    // A "New from Template" listing?
    if (self.feedTemplates(hc, rep)) return false;
    // A background-click folder Properties stat?
    if (@import("props.zig").feedFolderProps(self, hc, rep)) return false;

    // Listing chunk run?
    for (self.pending.items, 0..) |p, i| {
        if (p.req != rep.req) continue;
        if (!rep.ok) {
            self.listingRefused(p, rep.@"error");
            self.dropPending(i);
            return true;
        }
        p.dir.clearLoadError();
        if (rep.dev != 0) p.dir.dev = rep.dev;

        if (p.op == .list) {
            // Refresh of a live directory: the rows on screen stay
            // valid, so chunks accumulate aside and swap in whole at
            // the end — a half-swapped refresh would read as loss.
            for (rep.entries) |we| {
                if (p.dir.own(we)) |e| p.staged.append(self.allocator, e) catch {};
            }
            if (!rep.more) {
                colview.invalidateBackingRefs(p.tab);
                for (p.dir.entries.items) |*e| e.deinit(self.allocator);
                p.dir.entries.deinit(self.allocator);
                p.dir.entries = p.staged;
                p.staged = .empty;
                p.dir.loaded = true;
                p.dir.sort();
                if (rep.truncated) self.setStatus("listing truncated (very large directory)");
                self.dropPending(i);
                return true;
            }
            return false;
        }

        // open_view (navigation, new tab, subdir expansion): STREAM.
        // Rows land on screen as each chunk arrives instead of the
        // tab sitting at "Listing..." until the run ends.
        for (rep.entries) |we| {
            if (p.dir.own(we)) |e| p.dir.entries.append(self.allocator, e) catch {};
        }
        p.dir.streaming = rep.more;
        if (!rep.more) p.dir.loaded = true;
        colview.invalidateBackingRefs(p.tab);
        p.dir.sort();
        if (rep.truncated and !rep.more) self.setStatus("listing truncated (very large directory)");
        var rendered = false;
        if (p.navigation) |intent| {
            if (p.navigation_generation != p.tab.navigation_generation) {
                self.dropPending(i);
                return false;
            }
            // The navigation lands on the FIRST chunk, Nemo-style:
            // the user is in the folder immediately and the rest of
            // the rows stream in. Ownership of the candidate dir
            // moves to the tab here, so the eventual dropPending
            // must not (and will not: navigation is nulled) free it.
            p.navigation = null;
            self.commitNavigation(p.tab, p.hc, p.dir, intent, rep.path);
            rendered = true;
        }
        if (!rep.more) self.dropPending(i);
        // commitNavigation already rendered this tab; reporting dirty
        // too would rebuild the same listing again in the same drain.
        return !rendered;
    }
    // Job start reply?
    for (self.pending_jobs.items, 0..) |pj, i| {
        if (pj.req != rep.req) continue;
        if (rep.ok and rep.job != 0) {
            if (pj.retry) |retry| {
                if (self.transfer_service) |service| _ = service.mediatedJobStarted(retry.token, rep.job);
            }
            if (pj.kind == .query) {
                // The tab may have closed since the request went out;
                // its query was forgotten and pj.tab nulled with it.
                if (pj.tab) |t| {
                    if (self.tabAlive(t)) self.queryStarted(t, hc, rep.job);
                }
            }
            if (self.compare) |cmp| {
                if (pj.kind == .compare_left) cmp.left.job = rep.job;
                if (pj.kind == .compare_right) cmp.right.job = rep.job;
            }
            if (pj.kind == .calc_size) {
                self.calc_job = rep.job;
                self.calc_hc = hc;
                self.calc_total = 0;
                self.calc_files = 0;
            }
            if (pj.kind == .dup_scan) {
                if (self.dup) |d| {
                    if (d.hc == hc) d.job = rep.job;
                }
            }
            if (pj.kind == .archive_list) {
                self.arch_job = rep.job;
                self.arch_hc = hc;
            }
            const row = self.allocator.create(JobRow) catch {
                if (pj.retry) |retry| {
                    if (self.transfer_service) |service| service.abandonMediated(retry.token);
                    retry.destroy(self.allocator);
                }
                if (pj.undo_op) |u| u.destroy(self.allocator);
                if (pj.undo_trash_orig) |o| self.allocator.free(o);
                if (pj.history_op) |op| self.restoreHistory(op, pj.history_direction.?);
                self.allocator.free(pj.label);
                _ = self.pending_jobs.orderedRemove(i);
                self.allocator.destroy(pj);
                return false;
            };
            row.* = .{
                .hc = hc,
                .job = rep.job,
                .label = pj.label,
                .batch_id = pj.batch_id,
                .batch_total = pj.batch_total,
                .done = rep.done,
                .total = rep.total,
                .resumed_from = rep.resumed_from,
                .files_done = rep.files_done,
                .files_total = rep.files_total,
                .undo_op = pj.undo_op,
                .undo_trash_orig = pj.undo_trash_orig,
                .open_on_done = pj.open_on_done,
                .history_op = pj.history_op,
                .history_direction = pj.history_direction,
                .paths = pj.paths,
                .dest_key = pj.dest_key,
                .retry = pj.retry,
            };
            if (rep.file.len > 0) row.setCurrentFile(rep.file);
            self.jobs.append(self.allocator, row) catch {
                if (row.history_op) |op| self.restoreHistory(op, row.history_direction.?);
                if (row.retry) |r| {
                    if (self.transfer_service) |service| service.abandonMediated(r.token);
                    r.destroy(self.allocator);
                }
                self.allocator.destroy(row);
                self.allocator.free(pj.label);
                _ = self.pending_jobs.orderedRemove(i);
                self.allocator.destroy(pj);
                return false;
            };
            _ = self.pending_jobs.orderedRemove(i);
            self.allocator.destroy(pj);
            if (row.retry) |retry| {
                if (self.transfer_service) |service| {
                    if (service.mediatedCancelRequested(retry.token)) {
                        self.sendOp(row.hc, .{ .req = self.nextReq(), .op = "job_cancel", .job = row.job });
                    } else if (service.mediatedPaused(retry.token)) {
                        self.sendOp(row.hc, .{ .req = self.nextReq(), .op = "job_pause", .job = row.job });
                    }
                }
            }
            // A resumed cross-host copy supersedes the failed row it
            // came from; one transfer must read as one row.
            if (row.retry != null) self.dropSupersededRetryRows(row);
            self.renderJobs();
        } else {
            self.setStatusFmt("operation failed: {s}", .{errorPhrase(rep.@"error")});
            if (pj.kind == .compare_left or pj.kind == .compare_right) {
                if (self.compare) |cmp| cmp.sideFailed(pj.kind == .compare_left);
            }
            // A query whose job never started must not sit on its tab
            // claiming to be live.
            if (pj.kind == .query) {
                if (pj.tab) |t| {
                    if (self.tabAlive(t)) self.queryForget(t);
                }
            }
            if (pj.undo_op) |u| u.destroy(self.allocator);
            if (pj.undo_trash_orig) |o| self.allocator.free(o);
            if (pj.history_op) |op| self.restoreHistory(op, pj.history_direction.?);
            if (pj.retry) |r| {
                pj.retry = null;
                if (@import("jobs.zig").retryRejectedCopy(self, r, rep.@"error"))
                    self.setStatusFmt("transfer start failed, retrying shortly: {s} ({s})", .{ pj.label, errorPhrase(rep.@"error") });
            }
            self.allocator.free(pj.label);
            _ = self.pending_jobs.orderedRemove(i);
            self.allocator.destroy(pj);
        }
        return false;
    }
    // Undo record for a plain op (rename/mkdir/move)?
    for (self.pending_undo.items, 0..) |pu, i| {
        if (pu.req != rep.req) continue;
        if (rep.ok) {
            self.pushUndo(pu.op);
        } else if (std.mem.eql(u8, rep.@"error", "XDEV") and pu.op.kind == .rename_back) {
            const move_hc = self.hostConnFor(if (pu.op.host) |host| @as(?[]const u8, host) else null);
            if (move_hc) |host_conn| {
                self.startTransfer(host_conn, pu.op.b, host_conn, pu.op.a, .{
                    .delete_src_after = true,
                    .no_replace = pu.no_replace,
                });
                self.setStatusFmt("moving across filesystems: {s}", .{std.fs.path.basename(pu.op.b)});
            } else {
                self.setStatus("move could not be resumed because the host is unavailable");
            }
            pu.op.destroy(self.allocator);
        } else {
            pu.op.destroy(self.allocator);
            self.setStatusFmt("operation failed: {s}", .{errorPhrase(rep.@"error")});
        }
        _ = self.pending_undo.orderedRemove(i);
        return false;
    }
    // Completion of a redo/undo plain mutation.
    for (self.pending_history.items, 0..) |ph, i| {
        if (ph.req != rep.req) continue;
        _ = self.pending_history.orderedRemove(i);
        if (rep.ok) {
            self.finishHistory(ph.op, ph.direction);
        } else {
            self.restoreHistory(ph.op, ph.direction);
            self.setStatusFmt("history operation failed: {s}", .{errorPhrase(rep.@"error")});
        }
        return false;
    }
    // Compare hash-verify start reply?
    if (self.compare) |cmp| {
        if (cmp.consumeHashStart(hc, rep)) return false;
    }
    // Duplicate-finder hash-start reply?
    if (self.dup) |d| {
        if (d.hc == hc) {
            for (d.hashes.items) |*h| {
                if (h.req == rep.req) {
                    if (rep.ok and rep.job != 0) {
                        h.job = rep.job;
                    } else {
                        h.failed = true;
                        h.job = 1; // sentinel: no longer "starting"
                        self.dupMaybeFinish();
                    }
                    return false;
                }
            }
        }
    }
    // Host directory identities (homedir) reply: the Templates dir
    // the New menu lists, resolved on the machine that owns it.
    if (hc.dirs_req != 0 and rep.req == hc.dirs_req) {
        hc.dirs_req = 0;
        hc.dirs_known = true;
        if (rep.ok and rep.templates.len > 0 and hc.templates_dir == null)
            hc.templates_dir = self.allocator.dupe(u8, rep.templates) catch null;
        if (rep.ok and rep.home.len > 0 and hc.home_dir == null)
            hc.home_dir = self.allocator.dupe(u8, rep.home) catch null;
        self.templatesHostDirs(hc);
        // The sidebar's per-host section shows this host's Home once
        // it is known.
        if (self.places_on and hc.host != null) self.renderPlaces();
        return false;
    }
    // Open With host-apps reply?
    if (self.openwith) |ow| {
        if (ow.req != 0 and ow.req == rep.req) {
            self.populateHostApps(ow, rep.ok, rep.apps);
            return false;
        }
    }
    // Plain op reply (mkdir/rename/delete fired from the UI).
    if (!rep.ok) {
        self.setStatusFmt("operation failed: {s}", .{errorPhrase(rep.@"error")});
        return false;
    }
    return false;
}

/// A listing came back refused. Which surface has to say so depends
/// on WHOSE listing it was: the directory a tab shows (or is about to
/// show) owns the listing area, a navigation target that never landed
/// only owns a note, because the rows on screen are still valid.
///
/// `reason` is the daemon's own error field -- errno tags get read out
/// into words by `format.errorPhrase`, everything else is passed
/// through as-is.
pub fn listingRefused(self: *BrowserView, p: *Pending, reason: []const u8) void {
    const why = errorPhrase(reason);
    if (p.navigation != null) {
        // The candidate dir is about to be freed with the Pending, so
        // the refusal is remembered on the tab instead.
        if (p.navigation_generation == p.tab.navigation_generation) {
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "cannot open {s}: {s}", .{ p.dir.path, why }) catch why;
            p.tab.setNavError(msg);
            self.syncPathEntry(p.tab);
        }
    } else {
        p.dir.setLoadError(why);
        // The location control has to stop claiming this path opened.
        if (p.dir == p.tab.root) self.syncPathEntry(p.tab);
    }
    // Say it once immediately too: renderTab repeats it from the state
    // above on every later render.
    self.setStatusFmt("cannot open {s}: {s}", .{ p.dir.path, why });
}

pub fn dropPending(self: *BrowserView, i: usize) void {
    const p = self.pending.swapRemove(i);
    for (p.staged.items) |*e| e.deinit(self.allocator);
    p.staged.deinit(self.allocator);
    if (p.navigation != null) {
        self.closeViewOf(p.hc, p.dir);
        p.dir.deinit();
    }
    self.allocator.destroy(p);
}

/// Drop listing accumulators before their target directory is freed.
pub fn cancelPendingDir(self: *BrowserView, dir: *Dir) void {
    var i: usize = 0;
    while (i < self.pending.items.len) {
        if (self.pending.items[i].dir == dir) {
            self.dropPending(i);
        } else {
            i += 1;
        }
    }
}

pub fn onDelta(self: *BrowserView, hc: *HostConn, payload: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const d = std.json.parseFromSliceLeaky(WireDelta, arena.allocator(), payload, .{
        .ignore_unknown_fields = true,
    }) catch return false;
    for (self.tabs.items) |tab| {
        if (tab.hc != hc) continue;
        const dir = tab.dirByView(d.view) orelse continue;
        if (d.gone) {
            dir.gone = true;
            if (dir == tab.root) {
                // The rows on screen describe a directory that is not
                // there any more; keeping them without saying so is
                // the same lie as an empty listing for a failed one.
                dir.setLoadError("the folder no longer exists");
                self.setStatusFmt("{s} no longer exists", .{dir.path});
                self.syncPathEntry(tab);
            } else {
                // Expanded subdir vanished: its own delta already
                // removed the entry from the parent; drop the view.
                colview.invalidateBackingRefs(tab);
                tab.dropSubdirsUnder(dir.path);
            }
            return true;
        }
        if (d.resync) {
            // Kernel dropped events: deltas alone are no longer
            // sufficient — refetch the whole listing on the SAME
            // live view.
            self.refreshDir(tab, dir);
            return false;
        }
        // Count-only upserts (the daemon's async child counts) are
        // written in place and rebind ONE row: `children` is never a
        // sort input and nothing reallocates, so the listing model
        // stays put — no rebuild, no flicker, no eaten clicks while
        // counts trickle in. Anything structural falls through to
        // the full upsert path and reports dirty. Once one structural
        // change ran, entry pointers may have moved, so the fast path
        // is off for the rest of the batch.
        var structural = false;
        for (d.changes) |ch| {
            if (std.mem.eql(u8, ch.op, "upsert")) {
                const we = ch.entry orelse continue;
                if (!structural) {
                    if (dir.countOnlyIndex(we)) |idx| {
                        dir.entries.items[idx].children = we.children;
                        colview.refreshEntryRow(self, tab, dir, &dir.entries.items[idx]);
                        continue;
                    }
                    structural = true;
                    colview.invalidateBackingRefs(tab);
                }
                tab.noteChanged(dir, we.name);
                dir.upsert(we);
            } else if (std.mem.eql(u8, ch.op, "del")) {
                if (!structural) {
                    structural = true;
                    colview.invalidateBackingRefs(tab);
                }
                tab.noteChanged(dir, ch.name);
                dir.del(ch.name);
            }
        }
        if (structural) self.requestFreeSpace(tab);
        return structural;
    }
    return false;
}

pub fn makeDir(self: *BrowserView, path: []const u8) ?*Dir {
    const d = self.allocator.create(Dir) catch return null;
    const owned = self.allocator.dupe(u8, path) catch {
        self.allocator.destroy(d);
        return null;
    };
    d.* = .{ .allocator = self.allocator, .path = owned, .view_id = self.next_view };
    self.next_view += 1;
    return d;
}

test "statfs coalescing discards stale and overflowing replies" {
    const t = std.testing;
    const stale = freeSpaceReply(true, 10, 4096, true);
    try t.expectEqual(@as(?u64, null), stale.bytes);
    try t.expect(stale.refresh);

    const current = freeSpaceReply(true, 10, 4096, false);
    try t.expectEqual(@as(?u64, 40_960), current.bytes);
    try t.expect(!current.refresh);

    const overflow = freeSpaceReply(true, std.math.maxInt(u64), 2, false);
    try t.expectEqual(@as(?u64, null), overflow.bytes);
    try t.expect(!overflow.refresh);
}
