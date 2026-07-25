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
const hostEq = @import("../../filebrowser/paths.zig").hostEq;

/// Heap context handed to the connect worker thread. The thread only
/// touches this struct (its own allocator for the Conn); the idle
/// handback runs on the main thread.
pub const ConnectCtx = struct {
    allocator: std.mem.Allocator,
    hc: *HostConn,
    host: []u8,
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
    const th = std.Thread.spawn(.{}, connectThreadMain, .{ctx}) catch {
        self.allocator.free(ctx.host);
        self.allocator.destroy(ctx);
        hc.state = .dead;
        self.setStatusFmt("cannot start connection to {s}", .{host.?});
        return hc;
    };
    th.detach();
    self.setStatusFmt("connecting to {s}…", .{host.?});
    return hc;
}

pub fn connectThreadMain(ctx: *ConnectCtx) void {
    const alloc = std.heap.c_allocator;
    const result = if (std.mem.startsWith(u8, ctx.host, "udp:"))
        muxclient.Conn.connectUdp(alloc, ctx.host[4..], null)
    else
        muxclient.Conn.connectSsh(alloc, ctx.host);
    if (result) |conn| {
        ctx.result = conn;
    } else |_| {
        ctx.result = null;
    }
    _ = c.g_idle_add(@ptrCast(&onConnectIdle), @ptrCast(ctx));
}

pub fn onConnectIdle(user: ?*anyopaque) callconv(.c) c.gboolean {
    const ctx: *ConnectCtx = @ptrCast(@alignCast(user.?));
    const hc = ctx.hc;
    const allocator = ctx.allocator;
    defer {
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
    if (ctx.result) |conn| {
        hc.conn = conn;
        view.wireReady(hc);
        view.setStatusFmt("connected to {s}", .{hc.label()});
    } else {
        hc.state = .dead;
        view.setStatusFmt("cannot connect to {s}", .{hc.label()});
    }
    return 0;
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
    self.pumpTransferQueue();
    self.pumpCopyQueue();
}

/// Connection died: fail its transfers FIRST (they hold *Conn),
/// then release the socket. Tabs keep referencing the dead
/// HostConn; navigating again reconnects.
pub fn hostDied(self: *BrowserView, hc: *HostConn) void {
    mediacols.hostDied(self, hc);
    var i: usize = 0;
    // In-flight listings can never be answered. A navigation
    // request also OWNS its candidate directory until it commits,
    // so dropping it here is what frees it.
    while (i < self.pending.items.len) {
        if (self.pending.items[i].hc == hc) self.dropPending(i) else i += 1;
    }
    i = 0;
    while (i < self.transfers.items.len) {
        const t = self.transfers.items[i];
        if (t.src_hc == hc or t.dst_hc == hc) {
            self.setStatusFmt("transfer failed: connection to {s} lost", .{hc.label()});
            if (t.upload_watch) |wt| wt.uploading = false;
            t.x.deinit();
            self.allocator.free(t.label);
            t.freeExtras(self.allocator);
            self.allocator.destroy(t);
            _ = self.transfers.orderedRemove(i);
        } else i += 1;
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
    if (self.attr_request) |request| {
        if (request.hc == hc) self.endAttrRequest();
    }
    if (self.remote_thumb) |rt| {
        if (rt.hc == hc) {
            rt.destroy(self.allocator);
            self.remote_thumb = null;
        }
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
    hc.conn.deinit();
    hc.state = .dead;
    self.setStatusFmt("connection to {s} lost — navigate to reconnect", .{hc.label()});
    self.renderJobs();
}

pub fn sendOp(self: *BrowserView, hc: *HostConn, args: anytype) void {
    if (hc.state != .ready) {
        self.setStatusFmt("not connected to {s}", .{hc.label()});
        return;
    }
    hc.conn.sendJson(.fs_op, args) catch self.setStatus("daemon connection lost");
}

pub fn closeViewOf(self: *BrowserView, hc: *HostConn, dir: *Dir) void {
    _ = self;
    if (dir.view_id == 0 or hc.state != .ready) return;
    hc.conn.sendJson(.fs_op, .{
        .req = @as(u32, 0),
        .op = "close_view",
        .view = dir.view_id,
    }) catch {};
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
        self.setStatusFmt("not connected to {s}", .{tab.hc.label()});
    }
}

pub fn nextReq(self: *BrowserView) u32 {
    const r = self.next_req;
    self.next_req +%= 1;
    if (self.next_req == 0) self.next_req = 1;
    return r;
}

pub fn onFdReadable(fd: c_int, cond: c.GIOCondition, user: ?*anyopaque) callconv(.c) c.gboolean {
    _ = fd;
    const hc: *HostConn = @ptrCast(@alignCast(user.?));
    const self = hc.view;
    const alive = hc.conn.fillAvailable();
    var dirty = false;
    var xfer_touched = false;
    while (hc.conn.takeFrame() catch null) |f| {
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
    if (dirty) self.renderCurrent();
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

    // A breadcrumb segment's sibling listing?
    if (self.feedSiblings(hc, rep)) return false;

    // Listing chunk run?
    for (self.pending.items, 0..) |p, i| {
        if (p.req != rep.req) continue;
        if (!rep.ok) {
            self.setStatusFmt("cannot open: {s}", .{rep.@"error"});
            if (p.navigation != null and p.navigation_generation == p.tab.navigation_generation) self.syncPathEntry(p.tab);
            self.dropPending(i);
            return true;
        }
        for (rep.entries) |we| {
            if (p.dir.own(we)) |e| p.staged.append(self.allocator, e) catch {};
        }
        if (!rep.more) {
            for (p.dir.entries.items) |*e| e.deinit(self.allocator);
            p.dir.entries.deinit(self.allocator);
            p.dir.entries = p.staged;
            p.staged = .empty;
            p.dir.loaded = true;
            p.dir.sort();
            if (rep.truncated) self.setStatus("listing truncated (very large directory)");
            if (p.navigation) |intent| {
                if (p.navigation_generation != p.tab.navigation_generation) {
                    self.dropPending(i);
                    return false;
                }
                p.navigation = null;
                _ = self.pending.swapRemove(i);
                p.staged.deinit(self.allocator);
                self.commitNavigation(p.tab, p.hc, p.dir, intent, rep.path);
                self.allocator.destroy(p);
                return true;
            }
            self.dropPending(i);
            return true;
        }
        return false;
    }
    // Job start reply?
    for (self.pending_jobs.items, 0..) |pj, i| {
        if (pj.req != rep.req) continue;
        if (rep.ok and rep.job != 0) {
            if (pj.kind == .search) {
                self.search_job = rep.job;
                self.search_hc = hc;
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
            if (pj.kind == .flat_view) {
                self.views.flat_job = rep.job;
                self.views.flat_hc = hc;
            }
            const row = self.allocator.create(JobRow) catch break;
            row.* = .{
                .hc = hc,
                .job = rep.job,
                .label = pj.label,
                .undo_op = pj.undo_op,
                .undo_trash_orig = pj.undo_trash_orig,
                .open_on_done = pj.open_on_done,
                .history_op = pj.history_op,
                .history_direction = pj.history_direction,
                .paths = pj.paths,
                .dest_key = pj.dest_key,
            };
            self.jobs.append(self.allocator, row) catch {
                if (row.history_op) |op| self.restoreHistory(op, row.history_direction.?);
                self.allocator.destroy(row);
                self.allocator.free(pj.label);
                _ = self.pending_jobs.orderedRemove(i);
                self.allocator.destroy(pj);
                return false;
            };
            _ = self.pending_jobs.orderedRemove(i);
            self.allocator.destroy(pj);
            self.renderJobs();
        } else {
            self.setStatusFmt("operation failed: {s}", .{rep.@"error"});
            if (pj.kind == .compare_left or pj.kind == .compare_right) {
                if (self.compare) |cmp| cmp.sideFailed(pj.kind == .compare_left);
            }
            if (pj.undo_op) |u| u.destroy(self.allocator);
            if (pj.undo_trash_orig) |o| self.allocator.free(o);
            if (pj.history_op) |op| self.restoreHistory(op, pj.history_direction.?);
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
        } else {
            pu.op.destroy(self.allocator);
            self.setStatusFmt("operation failed: {s}", .{rep.@"error"});
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
            self.setStatusFmt("history operation failed: {s}", .{rep.@"error"});
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
    // Host cache-dir (homedir) reply?
    if (hc.cache_req != 0 and rep.req == hc.cache_req) {
        hc.cache_req = 0;
        if (rep.ok and rep.cache.len > 0) {
            hc.cache_dir = self.allocator.dupe(u8, rep.cache) catch null;
        }
        self.pumpRemoteThumbs();
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
        self.setStatusFmt("operation failed: {s}", .{rep.@"error"});
        return false;
    }
    return false;
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
                self.setStatusFmt("{s} no longer exists", .{dir.path});
            } else {
                // Expanded subdir vanished: its own delta already
                // removed the entry from the parent; drop the view.
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
        for (d.changes) |ch| {
            if (std.mem.eql(u8, ch.op, "upsert")) {
                if (ch.entry) |we| dir.upsert(we);
            } else if (std.mem.eql(u8, ch.op, "del")) {
                dir.del(ch.name);
            }
        }
        return true;
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
