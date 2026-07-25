//! Daemon jobs and client-mediated transfers.
//!
//! Every mutation is a job with an id: this module starts them and
//! folds their streamed events back into the view. Cross-host copies
//! ride fstransfer.Xfer instead, queued by the shared scheduling
//! policy in filebrowser/xferqueue.zig so that transfers to one
//! destination serialize while unrelated ones run in parallel. The
//! panel that displays all of this lives in jobpanel.zig.

const std = @import("std");
const wire = @import("../../mux/wire.zig");
const file_transfers = @import("../file_transfers.zig");
const fstransfer = @import("../../ipc/fstransfer.zig");
const xferqueue = @import("../../filebrowser/xferqueue.zig");

const ActiveTransfer = @import("types.zig").ActiveTransfer;
const BrowserView = @import("view.zig").BrowserView;
const EditWatch = @import("types.zig").EditWatch;
const HistoryDirection = @import("types.zig").HistoryDirection;
const HostConn = @import("types.zig").HostConn;
const JobRow = @import("types.zig").JobRow;
const PendingJob = @import("types.zig").PendingJob;
const UndoOp = @import("types.zig").UndoOp;
const WireJobEv = @import("types.zig").WireJobEv;
const fmtSize = @import("../../filebrowser/format.zig").fmtSize;
const launchLocal = @import("open.zig").launchLocal;
const launchLocalWithApp = @import("open.zig").launchLocalWithApp;

pub fn feedTransfers(self: *BrowserView, hc: *HostConn, ftype: wire.FrameType, payload: []const u8) bool {
    for (self.transfers.items) |t| {
        if (t.src_hc == hc and t.x.feed(.src, ftype, payload)) return true;
        if (t.dst_hc == hc and t.x.feed(.dst, ftype, payload)) return true;
    }
    return false;
}

/// Start whatever the queue policy admits: one transfer per
/// destination at a time, distinct destinations in parallel, under a
/// global ceiling. A transfer whose hosts are not both connected is
/// not offered to the policy -- it cannot start, and holding a
/// destination slot for it would stall the ones that can.
pub fn pumpTransferQueue(self: *BrowserView) void {
    if (self.transfers.items.len == 0) return;
    const slots = self.allocator.alloc(xferqueue.Slot, self.transfers.items.len) catch return;
    defer self.allocator.free(slots);
    const map = self.allocator.alloc(usize, self.transfers.items.len) catch return;
    defer self.allocator.free(map);
    var n: usize = 0;
    for (self.transfers.items, 0..) |t, i| {
        if (t.x.isTerminal()) continue;
        const ready = t.src_hc.state == .ready and t.dst_hc.state == .ready;
        if (!t.started and !ready) continue;
        slots[n] = .{ .dest = t.dest_key, .state = if (t.started) .running else .queued };
        map[n] = i;
        n += 1;
    }
    var admitted: [xferqueue.MAX_ACTIVE]usize = undefined;
    for (xferqueue.admissible(slots[0..n], &admitted)) |k| {
        const t = self.transfers.items[map[k]];
        t.started = true;
        t.x.start();
        self.setStatusFmt("transfer started: {s}", .{t.label});
    }
}

/// Move a not-yet-started transfer within the queue; the order here
/// IS the start order. A queued transfer never overtakes a running
/// one (that would not change what starts next anyway).
pub fn moveTransfer(self: *BrowserView, t: *ActiveTransfer, direction: i8) void {
    if (t.started) return;
    const i = for (self.transfers.items, 0..) |item, idx| {
        if (item == t) break idx;
    } else return;
    const j: usize = if (direction < 0)
        (if (i == 0) return else i - 1)
    else
        (if (i + 1 >= self.transfers.items.len) return else i + 1);
    if (self.transfers.items[j].started) return;
    std.mem.swap(*ActiveTransfer, &self.transfers.items[i], &self.transfers.items[j]);
}

/// Finish (and drop) transfers that reached a terminal state.
pub fn reapTransfers(self: *BrowserView) void {
    var i: usize = 0;
    while (i < self.transfers.items.len) {
        const t = self.transfers.items[i];
        if (!t.x.isTerminal()) {
            i += 1;
            continue;
        }
        if (t.upload_watch) |wt| {
            wt.uploading = false;
            if (t.x.ok()) {
                self.setStatusFmt("synced back: {s}", .{std.fs.path.basename(wt.remote_path)});
            } else if (t.x.state != .canceled) {
                self.setStatusFmt("sync-back failed: {s} ({s})", .{ t.label, t.x.errMsg() });
            }
        } else if (t.x.ok()) {
            self.setStatusFmt("transfer done: {s}", .{t.label});
            if (t.delete_src_after) {
                // The copy hash-verified; complete the MOVE by
                // removing the source (recursive when a tree).
                var lbl: [128]u8 = undefined;
                const dlabel = std.fmt.bufPrint(&lbl, "move cleanup {s}", .{std.fs.path.basename(t.x.src_root)}) catch "move cleanup";
                self.startDaemonJob(t.src_hc, "delete_tree", t.x.src_root, "", dlabel);
            }
            if (t.open_when_done) {
                if (t.open_with_appid) |appid| {
                    launchLocalWithApp(appid, t.x.dst_root);
                } else {
                    launchLocal(t.x.dst_root);
                }
                if (t.watch_host != null and t.watch_remote != null)
                    self.registerEditWatch(t.watch_host.?, t.watch_remote.?, t.x.dst_root);
            }
        } else if (t.x.state == .canceled) {
            self.setStatusFmt("transfer canceled: {s}", .{t.label});
        } else {
            self.setStatusFmt("transfer failed: {s} ({s})", .{ t.label, t.x.errMsg() });
        }
        t.x.deinit();
        self.allocator.free(t.label);
        t.freeExtras(self.allocator);
        self.allocator.destroy(t);
        _ = self.transfers.orderedRemove(i);
    }
    self.pumpTransferQueue();
}

/// One cross-host copy waiting for its destination to be free. The
/// daemon owns a copy once it is submitted; until then it is view
/// state, so a queued copy can still be reordered or dropped.
pub const CopyItem = struct {
    coordinator: *HostConn,
    src_hc: *HostConn,
    dst_hc: *HostConn,
    src_path: []u8,
    dst_path: []u8,
    label: []u8,
    dest_key: u64,

    pub fn destroy(self: *CopyItem, allocator: std.mem.Allocator) void {
        allocator.free(self.src_path);
        allocator.free(self.dst_path);
        allocator.free(self.label);
        allocator.destroy(self);
    }
};

/// Cross-host copies not yet handed to the daemon, in queue order.
pub const CopyQueue = struct {
    items: std.ArrayList(*CopyItem) = .empty,

    pub fn deinit(self: *CopyQueue, allocator: std.mem.Allocator) void {
        for (self.items.items) |item| item.destroy(allocator);
        self.items.deinit(allocator);
    }
};

fn enqueueCrossCopy(
    self: *BrowserView,
    coordinator: *HostConn,
    src_hc: *HostConn,
    src_path: []const u8,
    dst_hc: *HostConn,
    dst_path: []const u8,
) void {
    const item = self.allocator.create(CopyItem) catch return;
    const src = self.allocator.dupe(u8, src_path) catch {
        self.allocator.destroy(item);
        return;
    };
    const dst = self.allocator.dupe(u8, dst_path) catch {
        self.allocator.free(src);
        self.allocator.destroy(item);
        return;
    };
    const label = std.fmt.allocPrint(self.allocator, "{s}:{s} -> {s}", .{
        src_hc.label(), std.fs.path.basename(src_path), dst_hc.label(),
    }) catch {
        self.allocator.free(src);
        self.allocator.free(dst);
        self.allocator.destroy(item);
        return;
    };
    item.* = .{
        .coordinator = coordinator,
        .src_hc = src_hc,
        .dst_hc = dst_hc,
        .src_path = src,
        .dst_path = dst,
        .label = label,
        .dest_key = file_transfers.destinationKey(dst_hc.host orelse "", dst_path),
    };
    self.copy_queue.items.append(self.allocator, item) catch {
        item.destroy(self.allocator);
        return;
    };
    self.setStatusFmt("transfer queued: {s}", .{label});
    self.pumpCopyQueue();
    self.renderJobs();
}

/// Submit the cross-host copies the queue policy admits. Running
/// copies are the daemon jobs this queue started (they carry the
/// destination key), so a copy released by a finished one starts here.
pub fn pumpCopyQueue(self: *BrowserView) void {
    if (self.copy_queue.items.items.len == 0) return;
    var running: usize = 0;
    for (self.jobs.items) |j| {
        if (j.dest_key != 0 and !j.terminal()) running += 1;
    }
    for (self.pending_jobs.items) |pj| {
        if (pj.dest_key != 0) running += 1;
    }
    const total = running + self.copy_queue.items.items.len;
    const slots = self.allocator.alloc(xferqueue.Slot, total) catch return;
    defer self.allocator.free(slots);
    var n: usize = 0;
    for (self.jobs.items) |j| {
        if (j.dest_key == 0 or j.terminal()) continue;
        slots[n] = .{ .dest = j.dest_key, .state = .running };
        n += 1;
    }
    for (self.pending_jobs.items) |pj| {
        if (pj.dest_key == 0) continue;
        slots[n] = .{ .dest = pj.dest_key, .state = .running };
        n += 1;
    }
    const first_queued = n;
    for (self.copy_queue.items.items) |item| {
        slots[n] = .{ .dest = item.dest_key, .state = .queued };
        n += 1;
    }
    var admitted: [xferqueue.MAX_ACTIVE]usize = undefined;
    const start = xferqueue.admissible(slots[0..n], &admitted);
    // Submitting removes items, so collect the targets first.
    var targets: [xferqueue.MAX_ACTIVE]*CopyItem = undefined;
    var count: usize = 0;
    for (start) |k| {
        targets[count] = self.copy_queue.items.items[k - first_queued];
        count += 1;
    }
    for (targets[0..count]) |item| submitCrossCopy(self, item);
}

fn submitCrossCopy(self: *BrowserView, item: *CopyItem) void {
    for (self.copy_queue.items.items, 0..) |queued, i| {
        if (queued == item) {
            _ = self.copy_queue.items.orderedRemove(i);
            break;
        }
    }
    if (item.coordinator.state != .ready) {
        self.setStatusFmt("transfer dropped, coordinator offline: {s}", .{item.label});
        item.destroy(self.allocator);
        return;
    }
    const req = self.nextReq();
    const pj = self.allocator.create(PendingJob) catch {
        item.destroy(self.allocator);
        return;
    };
    // The label moves into the job record; the paths do not outlive it.
    pj.* = .{ .req = req, .hc = item.coordinator, .label = item.label, .dest_key = item.dest_key };
    pj.paths.set(item.src_path, item.dst_path);
    self.pending_jobs.append(self.allocator, pj) catch {
        self.allocator.destroy(pj);
        item.destroy(self.allocator);
        return;
    };
    self.sendOp(item.coordinator, .{
        .req = req,
        .op = "cross_copy",
        .path = item.src_path,
        .to = item.dst_path,
        .src_host = item.src_hc.host orelse "",
        .dst_host = item.dst_hc.host orelse "",
        .@"resume" = true,
    });
    self.setStatusFmt("durable transfer started: {s}", .{item.label});
    self.allocator.free(item.src_path);
    self.allocator.free(item.dst_path);
    self.allocator.destroy(item);
}

/// Drop a queued cross-host copy that was never submitted.
pub fn cancelQueuedCopy(self: *BrowserView, item: *CopyItem) void {
    for (self.copy_queue.items.items, 0..) |queued, i| {
        if (queued != item) continue;
        _ = self.copy_queue.items.orderedRemove(i);
        self.setStatusFmt("transfer canceled: {s}", .{item.label});
        item.destroy(self.allocator);
        return;
    }
}

/// Move a queued cross-host copy; the order here IS the start order.
pub fn moveQueuedCopy(self: *BrowserView, item: *CopyItem, direction: i8) void {
    const items = self.copy_queue.items.items;
    const i = for (items, 0..) |queued, idx| {
        if (queued == item) break idx;
    } else return;
    const j: usize = if (direction < 0)
        (if (i == 0) return else i - 1)
    else
        (if (i + 1 >= items.len) return else i + 1);
    std.mem.swap(*CopyItem, &items[i], &items[j]);
}

pub const TransferOpts = struct {
    open_when_done: bool = false,
    /// Launch with a specific application id (duped in).
    open_with_appid: ?[]const u8 = null,
    /// Register a sync-back watch on the landed download.
    watch_host: ?[]const u8 = null,
    watch_remote: ?[]const u8 = null,
    /// This transfer is a sync-back upload for that watch.
    upload_watch: ?*EditWatch = null,
    /// Cross-host MOVE: delete the source once the copy landed.
    delete_src_after: bool = false,
};

pub fn startTransfer(
    self: *BrowserView,
    src_hc: *HostConn,
    src_path: []const u8,
    dst_hc: *HostConn,
    dst_path: []const u8,
    opts: TransferOpts,
) void {
    const open_when_done = opts.open_when_done;
    if (src_hc.state != .ready or dst_hc.state != .ready) {
        self.setStatus("both hosts must be connected — retry in a moment");
        return;
    }
    if (!open_when_done and opts.upload_watch == null and !opts.delete_src_after) {
        // User copies are coordinated by the local daemon, not this
        // BrowserView. They therefore survive pane/window teardown and
        // reconnect through the stable job journal. They still queue
        // here first, so a paste of ten files does not put ten helpers
        // on one destination disk at once.
        const coordinator = self.hostConnFor(null) orelse return;
        if (coordinator.state != .ready) {
            self.setStatus("local transfer coordinator is not connected");
            return;
        }
        enqueueCrossCopy(self, coordinator, src_hc, src_path, dst_hc, dst_path);
        return;
    }
    const x = fstransfer.Xfer.init(
        self.allocator,
        &src_hc.conn,
        &dst_hc.conn,
        &self.next_req,
        src_path,
        dst_path,
        true,
    ) catch return;
    const label = std.fmt.allocPrint(self.allocator, "{s}:{s} → {s}", .{
        src_hc.label(), std.fs.path.basename(src_path), dst_hc.label(),
    }) catch {
        x.deinit();
        return;
    };
    const t = self.allocator.create(ActiveTransfer) catch {
        x.deinit();
        self.allocator.free(label);
        return;
    };
    t.* = .{
        .x = x,
        .src_hc = src_hc,
        .dst_hc = dst_hc,
        .label = label,
        .open_when_done = open_when_done,
        .open_with_appid = if (opts.open_with_appid) |s| (self.allocator.dupe(u8, s) catch null) else null,
        .watch_host = if (opts.watch_host) |s| (self.allocator.dupe(u8, s) catch null) else null,
        .watch_remote = if (opts.watch_remote) |s| (self.allocator.dupe(u8, s) catch null) else null,
        .upload_watch = opts.upload_watch,
        .delete_src_after = opts.delete_src_after,
        .dest_key = file_transfers.destinationKey(dst_hc.host orelse "", dst_path),
    };
    self.transfers.append(self.allocator, t) catch {
        x.deinit();
        self.allocator.free(label);
        self.allocator.destroy(t);
        return;
    };
    self.setStatusFmt("transfer queued: {s}", .{label});
    self.pumpTransferQueue();
    self.renderJobs();
}

pub fn startDaemonJob(self: *BrowserView, hc: *HostConn, comptime op: []const u8, path: []const u8, to: []const u8, label: []const u8) void {
    self.startDaemonJobKind(hc, op, path, to, "", label, .normal);
}

/// Like startDaemonJob, with hash-verified resume on (sync).
pub fn startDaemonJobResumable(self: *BrowserView, hc: *HostConn, comptime op: []const u8, path: []const u8, to: []const u8, label: []const u8) void {
    if (hc.state != .ready) {
        self.setStatusFmt("not connected to {s}", .{hc.label()});
        return;
    }
    const req = self.nextReq();
    const pj = self.allocator.create(PendingJob) catch return;
    pj.* = .{
        .req = req,
        .hc = hc,
        .label = self.allocator.dupe(u8, label) catch {
            self.allocator.destroy(pj);
            return;
        },
    };
    pj.paths.set(path, to);
    self.pending_jobs.append(self.allocator, pj) catch {
        self.allocator.free(pj.label);
        self.allocator.destroy(pj);
        return;
    };
    self.sendOp(hc, .{ .req = req, .op = op, .path = path, .to = to, .@"resume" = true });
}

pub fn startDaemonJobKind(
    self: *BrowserView,
    hc: *HostConn,
    comptime op: []const u8,
    path: []const u8,
    to: []const u8,
    pattern: []const u8,
    label: []const u8,
    kind: @FieldType(PendingJob, "kind"),
) void {
    if (hc.state != .ready) {
        self.setStatusFmt("not connected to {s}", .{hc.label()});
        return;
    }
    const req = self.nextReq();
    const pj = self.allocator.create(PendingJob) catch return;
    pj.* = .{
        .req = req,
        .hc = hc,
        .label = self.allocator.dupe(u8, label) catch {
            self.allocator.destroy(pj);
            return;
        },
        .kind = kind,
    };
    pj.paths.set(path, to);
    self.pending_jobs.append(self.allocator, pj) catch {
        self.allocator.free(pj.label);
        self.allocator.destroy(pj);
        return;
    };
    if (pattern.len > 0) {
        // search_within_ms / search_max_matches are single-shot:
        // set right before their find job, zero for everything
        // else.
        const within = self.search_within_ms;
        self.search_within_ms = 0;
        const maxm = self.search_max_matches;
        self.search_max_matches = 0;
        self.sendOp(hc, .{ .req = req, .op = op, .path = path, .pattern = pattern, .within_ms = within, .max_matches = maxm });
    } else if (to.len > 0) {
        self.sendOp(hc, .{ .req = req, .op = op, .path = path, .to = to, .@"resume" = false });
    } else {
        self.sendOp(hc, .{ .req = req, .op = op, .path = path });
    }
}

/// Job progress / completion → jobs panel + status bar (deltas
/// already update the listing itself when the result lands).
pub fn onJobEvent(self: *BrowserView, hc: *HostConn, payload: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const e = std.json.parseFromSliceLeaky(WireJobEv, arena.allocator(), payload, .{
        .ignore_unknown_fields = true,
    }) catch return;
    if (self.compare) |cmp| {
        if (cmp.consumeJobEvent(hc, e)) return;
        if (cmp.consumeHashEvent(hc, e)) return;
    }
    // Calculate Size scan.
    if (self.calc_job != 0 and e.job == self.calc_job and hc == self.calc_hc) {
        if (std.mem.eql(u8, e.ev, "match")) {
            if (!std.mem.eql(u8, e.kind, "dir")) {
                self.calc_total += e.size;
                self.calc_files += 1;
            }
            return;
        }
        if (std.mem.eql(u8, e.ev, "done")) {
            var sz: [48:0]u8 = undefined;
            self.setStatusFmt("total size: {s} in {d} file(s){s}", .{
                fmtSize(&sz, self.calc_total),
                self.calc_files,
                if (e.truncated) " (PARTIAL — scan truncated)" else "",
            });
            self.calc_job = 0;
            // fall through so the jobs panel row completes too
        }
    }
    // Duplicate finder (scan phase + hash-confirm phase).
    if (self.dup) |d| {
        if (d.hc == hc and self.dupConsumeEvent(d, e)) return;
    }
    // Flat/branch view: the subtree stream filling a flat tab.
    if (self.flatConsumeEvent(hc, e)) return;
    // Archive member listing.
    if (self.arch_job != 0 and e.job == self.arch_job and hc == self.arch_hc) {
        if (std.mem.eql(u8, e.ev, "match")) {
            self.onArchiveMember(e);
            return;
        }
        if (std.mem.eql(u8, e.ev, "done")) {
            self.setStatusFmt("archive: {d} member(s){s}", .{
                e.matches, if (e.truncated) " (truncated)" else "",
            });
            self.arch_job = 0;
        } else if (std.mem.eql(u8, e.ev, "error")) {
            self.arch_job = 0;
        }
    }
    if (std.mem.eql(u8, e.ev, "match")) {
        if (e.job == self.search_job and hc == self.search_hc) self.onSearchMatch(e);
        return;
    }
    if (std.mem.eql(u8, e.ev, "unmatch")) {
        if (e.job == self.search_job and hc == self.search_hc) self.onSearchUnmatch(e.path);
        return;
    }
    if (std.mem.eql(u8, e.ev, "resync")) {
        if (e.job == self.search_job and hc == self.search_hc)
            self.setStatus("live query watcher overflowed; rerun the saved query to resync");
        return;
    }
    if (e.job == self.search_job and hc == self.search_hc and std.mem.eql(u8, e.ev, "done")) {
        self.setStatusFmt("search done: {d} match(es){s}", .{
            e.matches, if (e.truncated) " (truncated)" else "",
        });
    }
    const row = for (self.jobs.items) |j| {
        if (j.hc == hc and j.job == e.job) break j;
    } else return;
    if (std.mem.eql(u8, e.ev, "progress")) {
        row.done = e.done;
        row.total = e.total;
        if (e.resumed_from > 0) row.resumed_from = e.resumed_from;
        if (row.state == .running) self.setStatusFmt("{s}: {d} / {d} MB", .{
            row.label, e.done >> 20, e.total >> 20,
        });
    } else if (std.mem.eql(u8, e.ev, "paused") or std.mem.eql(u8, e.ev, "resumed")) {
        // The daemon is the authority: another client may have paused
        // this job, and our own optimistic mark can be wrong.
        if (!row.terminal()) row.state = if (std.mem.eql(u8, e.ev, "paused")) .paused else .running;
    } else if (std.mem.eql(u8, e.ev, "done")) {
        row.state = .finished;
        row.done = e.done;
        row.total = e.total;
        if (e.resumed_from > 0) row.resumed_from = e.resumed_from;
        self.setStatusFmt("done: {s}", .{row.label});
        if (row.undo_op) |u| {
            row.undo_op = null;
            self.pushUndo(u);
        }
        if (row.undo_trash_orig) |orig| {
            row.undo_trash_orig = null;
            if (e.path.len > 0) {
                self.recordTrashUndo(row.hc, orig, e.path, e.text);
            }
            self.allocator.free(orig);
        }
        if (row.open_on_done and e.path.len > 0) {
            row.open_on_done = false;
            self.openPathOnHost(row.hc, e.path);
        }
        if (row.history_op) |op| {
            row.history_op = null;
            const direction = row.history_direction.?;
            row.history_direction = null;
            if (direction == .redo and op.kind == .trash_restore and e.path.len > 0)
                self.updateTrashResult(op, e.path, e.text);
            self.finishHistory(op, direction);
        }
    } else if (std.mem.eql(u8, e.ev, "error")) {
        row.state = .failed;
        self.setStatusFmt("job failed: {s} ({s})", .{ row.label, e.message });
        if (row.undo_op) |u| {
            row.undo_op = null;
            u.destroy(self.allocator);
        }
        if (row.undo_trash_orig) |orig| {
            row.undo_trash_orig = null;
            self.allocator.free(orig);
        }
        if (row.history_op) |op| {
            row.history_op = null;
            const direction = row.history_direction.?;
            row.history_direction = null;
            self.restoreHistory(op, direction);
        }
    } else if (std.mem.eql(u8, e.ev, "canceled")) {
        row.state = .canceled;
        self.setStatusFmt("canceled: {s}", .{row.label});
        if (row.undo_op) |u| {
            row.undo_op = null;
            u.destroy(self.allocator);
        }
        if (row.undo_trash_orig) |orig| {
            row.undo_trash_orig = null;
            self.allocator.free(orig);
        }
        if (row.history_op) |op| {
            row.history_op = null;
            const direction = row.history_direction.?;
            row.history_direction = null;
            self.restoreHistory(op, direction);
        }
    }
    // A finished cross-host copy releases its destination.
    if (row.dest_key != 0 and row.terminal()) self.pumpCopyQueue();
    self.renderJobs();
}

/// startDaemonJob variant that records an undo op on completion.
pub fn startDaemonJobUndo(self: *BrowserView, hc: *HostConn, comptime op: []const u8, path: []const u8, to: []const u8, label: []const u8, undo: ?*UndoOp) void {
    if (hc.state != .ready) {
        self.setStatusFmt("not connected to {s}", .{hc.label()});
        if (undo) |u| u.destroy(self.allocator);
        return;
    }
    const req = self.nextReq();
    const pj = self.allocator.create(PendingJob) catch {
        if (undo) |u| u.destroy(self.allocator);
        return;
    };
    pj.* = .{
        .req = req,
        .hc = hc,
        .label = self.allocator.dupe(u8, label) catch {
            self.allocator.destroy(pj);
            if (undo) |u| u.destroy(self.allocator);
            return;
        },
        .undo_op = undo,
    };
    pj.paths.set(path, to);
    self.pending_jobs.append(self.allocator, pj) catch {
        self.allocator.free(pj.label);
        self.allocator.destroy(pj);
        if (undo) |u| u.destroy(self.allocator);
        return;
    };
    self.sendOp(hc, .{ .req = req, .op = op, .path = path, .to = to, .@"resume" = false });
}

pub fn startHistoryJob(self: *BrowserView, hc: *HostConn, op_name: []const u8, path: []const u8, to: []const u8, pattern: []const u8, label: []const u8, op: *UndoOp, direction: HistoryDirection) void {
    const req = self.nextReq();
    const pj = self.allocator.create(PendingJob) catch return self.restoreHistory(op, direction);
    pj.* = .{
        .req = req,
        .hc = hc,
        .label = self.allocator.dupe(u8, label) catch { self.allocator.destroy(pj); return self.restoreHistory(op, direction); },
        .history_op = op,
        .history_direction = direction,
    };
    pj.paths.set(path, to);
    self.pending_jobs.append(self.allocator, pj) catch {
        self.allocator.free(pj.label);
        self.allocator.destroy(pj);
        return self.restoreHistory(op, direction);
    };
    self.sendOp(hc, .{ .req = req, .op = op_name, .path = path, .to = to, .pattern = pattern });
}

/// Job start with path+to+pattern (trash_restore shape).
pub fn startDaemonJobTo(self: *BrowserView, hc: *HostConn, comptime op: []const u8, path: []const u8, to: []const u8, pattern: []const u8, label: []const u8) void {
    if (hc.state != .ready) {
        self.setStatusFmt("not connected to {s}", .{hc.label()});
        return;
    }
    const req = self.nextReq();
    const pj = self.allocator.create(PendingJob) catch return;
    pj.* = .{
        .req = req,
        .hc = hc,
        .label = self.allocator.dupe(u8, label) catch {
            self.allocator.destroy(pj);
            return;
        },
    };
    pj.paths.set(path, to);
    self.pending_jobs.append(self.allocator, pj) catch {
        self.allocator.free(pj.label);
        self.allocator.destroy(pj);
        return;
    };
    self.sendOp(hc, .{ .req = req, .op = op, .path = path, .to = to, .pattern = pattern });
}

pub fn markJob(self: *BrowserView, hc: *HostConn, job: u64, state: @FieldType(JobRow, "state")) void {
    for (self.jobs.items) |j| {
        if (j.hc == hc and j.job == job and !j.terminal()) j.state = state;
    }
}
