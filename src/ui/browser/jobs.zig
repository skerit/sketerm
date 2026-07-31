//! Daemon jobs and client-mediated transfers.
//!
//! Every mutation is a job with an id: this module starts them and
//! folds their streamed events back into the view. Cross-host copies
//! ride fstransfer.Xfer instead, queued by the shared scheduling
//! policy in filebrowser/xferqueue.zig so that transfers to one
//! destination serialize while unrelated ones run in parallel. The
//! panel that displays all of this lives in jobpanel.zig.

const std = @import("std");
const c = @import("../../c.zig").c;
const wire = @import("../../mux/wire.zig");
const file_transfers = @import("../file_transfers.zig");
const fstransfer = @import("../../ipc/fstransfer.zig");
const xferqueue = @import("../../filebrowser/xferqueue.zig");

const ActiveTransfer = @import("types.zig").ActiveTransfer;
const BTab = @import("types.zig").BTab;
const BrowserView = @import("view.zig").BrowserView;
const CopyRetry = @import("types.zig").CopyRetry;
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
        // A held transfer moves no bytes, so it occupies no slot and
        // holds no destination: the ones that CAN work go first.
        if (t.paused) continue;
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
        self.ensureWriteFlush(t.src_hc);
        self.ensureWriteFlush(t.dst_hc);
        self.setStatusFmt("transfer started: {s}", .{t.label});
    }
}

/// Hold or release one client-mediated transfer. A started one stops
/// at its next chunk boundary and continues later from the staged
/// `.skpart` through the ordinary hash-verified resume; an unstarted
/// one simply stays out of the queue. The hold is written to the
/// durable ledger record, so it survives a GUI restart.
pub fn setTransferPaused(self: *BrowserView, t: *ActiveTransfer, paused: bool) void {
    if (t.paused == paused) return;
    t.paused = paused;
    if (paused) {
        if (t.started) t.x.pause();
    } else if (t.started) {
        t.x.unpause();
        self.ensureWriteFlush(t.src_hc);
        self.ensureWriteFlush(t.dst_hc);
    }
    if (t.token) |token| {
        if (self.transfer_service) |service| service.setMediatedPaused(token, paused);
    }
    if (!paused) self.pumpTransferQueue();
    self.setStatusFmt("transfer {s}: {s}", .{ if (paused) "paused" else "resumed", t.label });
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
        if (t.token) |token| {
            if (self.transfer_service) |service| service.finishMediated(token);
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
    move: bool = false,
    direct: bool = false,

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
    move: bool,
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
        .move = move,
        .direct = coordinator.host != null,
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
    // The queue item's owned strings move into the retry record, which
    // outlives the job: a copy that dies with a staged partial must be
    // resumable without asking the user to find the paths again.
    const retry = self.allocator.create(CopyRetry) catch {
        item.destroy(self.allocator);
        return;
    };
    retry.* = .{
        .coordinator = item.coordinator,
        .src_hc = item.src_hc,
        .dst_hc = item.dst_hc,
        .src_path = item.src_path,
        .dst_path = item.dst_path,
        .label = item.label,
        .dest_key = item.dest_key,
        .move = item.move,
        .direct = item.direct,
    };
    self.allocator.destroy(item);
    _ = submitRetry(self, retry);
}

/// Hand one cross-host copy to the coordinating daemon. Shared by the
/// first submission and every resume, so a retry is the same request
/// with the same idempotent `resume` flag -- never a second code path.
/// @return false when nothing was sent (the record is destroyed then).
fn submitRetry(self: *BrowserView, retry: *CopyRetry) bool {
    if (retry.coordinator.state != .ready) {
        self.setStatusFmt("transfer dropped, coordinator offline: {s}", .{retry.label});
        retry.destroy(self.allocator);
        return false;
    }
    const req = self.nextReq();
    const pj = self.allocator.create(PendingJob) catch {
        retry.destroy(self.allocator);
        return false;
    };
    pj.* = .{
        .req = req,
        .hc = retry.coordinator,
        .label = self.allocator.dupe(u8, retry.label) catch {
            self.allocator.destroy(pj);
            retry.destroy(self.allocator);
            return false;
        },
        .dest_key = retry.dest_key,
        .retry = retry,
    };
    pj.paths.set(retry.src_path, retry.dst_path);
    self.pending_jobs.append(self.allocator, pj) catch {
        self.allocator.free(pj.label);
        self.allocator.destroy(pj);
        retry.destroy(self.allocator);
        return false;
    };
    // Host strings are relative to the COORDINATOR: the side the
    // coordinator itself owns is "" (its own disk), and a remote
    // coordinator resolves the other side through ITS OWN ssh/UDP
    // config — which is exactly what direct transfer means.
    self.sendOp(retry.coordinator, .{
        .req = req,
        .op = "cross_copy",
        .path = retry.src_path,
        .to = retry.dst_path,
        .src_host = if (retry.src_hc == retry.coordinator) "" else retry.src_hc.host orelse "",
        .dst_host = if (retry.dst_hc == retry.coordinator) "" else retry.dst_hc.host orelse "",
        .@"resume" = true,
        .delete_src = retry.move,
        .dial_tries = @as(u32, if (retry.direct) 2 else 0),
    });
    if (retry.attempts == 0) {
        self.setStatusFmt("durable transfer started: {s}", .{retry.label});
    } else {
        self.setStatusFmt("resuming transfer (attempt {d}): {s}", .{ retry.attempts + 1, retry.label });
    }
    return true;
}

/// The resumed attempt's row replaces the failed one it came from:
/// without this, every dropped link left a spent `.failed` row (with a
/// live Retry button) stacked next to the copy that superseded it.
pub fn dropSupersededRetryRows(self: *BrowserView, fresh: *JobRow) void {
    const fr = fresh.retry orelse return;
    var i: usize = 0;
    while (i < self.jobs.items.len) {
        const j = self.jobs.items[i];
        const jr = j.retry;
        if (j != fresh and j.terminal() and jr != null and
            std.mem.eql(u8, jr.?.src_path, fr.src_path) and
            std.mem.eql(u8, jr.?.dst_path, fr.dst_path))
        {
            if (j.undo_op) |u| u.destroy(self.allocator);
            if (j.undo_trash_orig) |o| self.allocator.free(o);
            if (j.history_op) |op| op.destroy(self.allocator);
            jr.?.destroy(self.allocator);
            self.allocator.free(j.label);
            self.allocator.destroy(j);
            _ = self.jobs.orderedRemove(i);
            continue;
        }
        i += 1;
    }
}

/// Automatic attempts a failed cross-host copy makes before the row
/// settles as failed and waits for the user's Retry button. Each one
/// resumes from the staged partial, so a retry costs a reconnect, not
/// the bytes already moved.
const COPY_AUTO_RETRIES: u8 = 3;
/// Delay before an automatic resume: the daemon-side job already spent
/// its own reconnect budget, so a host that answers again needs a
/// moment, not another immediate hammering.
const COPY_RETRY_DELAY_MS: c.guint = 5_000;

/// Submit everything whose delay has elapsed. The records live on the
/// view, so a pane torn down while a retry is pending drops them in
/// `deinit` and the timer with them -- nothing outlives the face.
fn onRetryTimer(user: ?*anyopaque) callconv(.c) c.gboolean {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    self.retry_timer = 0;
    var pending = self.retry_pending;
    self.retry_pending = .empty;
    defer pending.deinit(self.allocator);
    for (pending.items) |retry| _ = submitRetry(self, retry);
    self.renderJobs();
    return 0;
}

/// A DIRECT remote-to-remote copy whose coordinator could not reach
/// its peer: resubmit the SAME job through the local daemon (the
/// relay), which resumes from any staged partial. Spends no automatic
/// resume attempt — the direct try moved no bytes.
fn fallbackDirectCopy(self: *BrowserView, row: *JobRow, kind: []const u8) bool {
    const retry = row.retry orelse return false;
    if (!retry.direct or !std.mem.eql(u8, kind, "unreachable")) return false;
    // hostConnFor STARTS a local connection when the view has none yet
    // (a view browsing two remotes never needed one before) — so a
    // still-connecting coordinator goes through the retry timer, by
    // which point the unix-socket autostart has long finished.
    const local = self.hostConnFor(null) orelse return false;
    if (local.state == .dead) return false;
    if (retry.move and local.state == .ready and !local.conn.cross_move) return false;
    retry.coordinator = local;
    retry.direct = false;
    row.retry = retry.clone(self.allocator);
    if (local.state == .ready) return submitRetry(self, retry);
    self.retry_pending.append(self.allocator, retry) catch {
        retry.destroy(self.allocator);
        return false;
    };
    row.retry_scheduled = true;
    if (self.retry_timer == 0)
        self.retry_timer = c.g_timeout_add(COPY_RETRY_DELAY_MS, @ptrCast(&onRetryTimer), @ptrCast(self));
    return true;
}

/// Take over a failed copy's retry record and arm the next attempt.
/// Returns false when the attempts are spent, which is what leaves the
/// row failed with its reason and a Retry button.
fn scheduleCopyRetry(self: *BrowserView, row: *JobRow) bool {
    const retry = row.retry orelse return false;
    if (retry.attempts >= COPY_AUTO_RETRIES) return false;
    retry.attempts += 1;
    // The row keeps a clone: the user can still press Retry after the
    // automatic attempts are done, and the failed row is what carries
    // that button.
    row.retry = retry.clone(self.allocator);
    self.retry_pending.append(self.allocator, retry) catch {
        retry.destroy(self.allocator);
        return false;
    };
    // No Retry button while an automatic attempt is armed: pressing it
    // then would run the same copy twice.
    row.retry_scheduled = true;
    if (self.retry_timer == 0)
        self.retry_timer = c.g_timeout_add(COPY_RETRY_DELAY_MS, @ptrCast(&onRetryTimer), @ptrCast(self));
    return true;
}

/// Drop everything waiting on the retry timer (view teardown).
pub fn cancelPendingRetries(self: *BrowserView) void {
    if (self.retry_timer != 0) {
        _ = c.g_source_remove(self.retry_timer);
        self.retry_timer = 0;
    }
    for (self.retry_pending.items) |retry| retry.destroy(self.allocator);
    self.retry_pending.deinit(self.allocator);
    self.retry_pending = .empty;
}

/// The jobs panel's Retry button: resume a copy the automatic attempts
/// gave up on. The record is cloned so the failed row keeps its own
/// (the user may press Retry again after a second failure).
pub fn retryCopyJob(self: *BrowserView, row: *JobRow) void {
    if (row.retry_scheduled) return;
    const retry = row.retry orelse return;
    const fresh = retry.clone(self.allocator) orelse return;
    fresh.attempts = 0;
    // The new attempt's row replaces this one once the daemon answers
    // (dropSupersededRetryRows); until then the button stays hidden.
    if (submitRetry(self, fresh)) row.retry_scheduled = true;
    self.renderJobs();
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

/// The daemon that should coordinate a cross-host copy/move, or null
/// when none qualifies (a move then degrades to client-mediated).
/// Remote-to-remote picks the destination daemon when it advertises
/// cross_move; everything else (and the fallback) is the local daemon,
/// which for a MOVE must itself advertise cross_move.
fn pickCoordinator(self: *BrowserView, src_hc: *HostConn, dst_hc: *HostConn, move: bool) ?*HostConn {
    if (src_hc.host != null and dst_hc.host != null and src_hc != dst_hc and
        dst_hc.state == .ready and dst_hc.conn.cross_move)
        return dst_hc;
    const local = self.hostConnFor(null) orelse return null;
    if (local.state != .ready) return null;
    if (move and !local.conn.cross_move) return null;
    return local;
}

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
    if (!open_when_done and opts.upload_watch == null) {
        // User copies and moves are coordinated by a DAEMON, not this
        // BrowserView. They therefore survive pane/window teardown and
        // reconnect through the stable job journal. They still queue
        // here first, so a paste of ten files does not put ten helpers
        // on one destination disk at once.
        //
        // Coordinator choice: remote-to-remote prefers the DESTINATION
        // host's own daemon, whose helper dials the source directly —
        // the bytes never route through this machine. That needs the
        // cross_move capability (fast dial-failure reporting; for a
        // move, delete_src honored rather than silently dropped). An
        // "unreachable" failure falls back to the local relay, which
        // resumes from the same staged partial.
        if (pickCoordinator(self, src_hc, dst_hc, opts.delete_src_after)) |coordinator| {
            enqueueCrossCopy(self, coordinator, src_hc, src_path, dst_hc, dst_path, opts.delete_src_after);
            return;
        }
        if (!opts.delete_src_after) {
            self.setStatus("local transfer coordinator is not connected");
            return;
        }
        // A move with no capable daemon anywhere degrades to the old
        // client-mediated transfer below rather than refusing.
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
        t.freeExtras(self.allocator);
        self.allocator.destroy(t);
        return;
    };
    // Record it so a pause -- or a crash -- can be picked up again,
    // here or by another sketerm process. A sync-back upload is
    // deliberately not recorded: it belongs to an in-view EditWatch
    // that no other process can reconstruct.
    if (opts.upload_watch == null) {
        if (self.transfer_service) |service| {
            const token = service.newMediated(
                src_hc.host orelse "",
                src_path,
                dst_hc.host orelse "",
                dst_path,
                .{
                    .app_id = opts.open_with_appid orelse "",
                    .open_when_done = open_when_done,
                    .delete_src_after = opts.delete_src_after,
                    .watch_after = opts.watch_host != null,
                },
            );
            if (token) |tok| t.token = self.allocator.dupe(u8, tok) catch null;
        }
    }
    self.setStatusFmt("transfer queued: {s}", .{label});
    self.pumpTransferQueue();
    self.renderJobs();
}

/// Rebuild a client-mediated transfer from its ledger record: the
/// service hands over records whose previous owner is gone (a closed
/// browser face, a crashed process), and the staged `.skpart` plus the
/// ordinary hash-verified resume carry it on from where it stopped.
pub fn adoptMediated(ctx: *anyopaque, rec: @import("../file_transfers.zig").MediatedRec) void {
    const self: *BrowserView = @ptrCast(@alignCast(ctx));
    for (self.transfers.items) |t| {
        if (t.token) |tok| {
            if (std.mem.eql(u8, tok, rec.token)) return;
        }
    }
    const src_hc = self.hostConnFor(if (rec.src_host.len == 0) null else rec.src_host) orelse return;
    const dst_hc = self.hostConnFor(if (rec.dst_host.len == 0) null else rec.dst_host) orelse return;
    const x = fstransfer.Xfer.init(
        self.allocator,
        &src_hc.conn,
        &dst_hc.conn,
        &self.next_req,
        rec.src_path,
        rec.dst_path,
        true,
    ) catch return;
    const label = std.fmt.allocPrint(self.allocator, "{s}:{s} → {s}", .{
        src_hc.label(), std.fs.path.basename(rec.src_path), dst_hc.label(),
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
        .open_when_done = rec.open_when_done,
        .open_with_appid = if (rec.app_id.len > 0) (self.allocator.dupe(u8, rec.app_id) catch null) else null,
        .watch_host = if (rec.watch_after and rec.src_host.len > 0) (self.allocator.dupe(u8, rec.src_host) catch null) else null,
        .watch_remote = if (rec.watch_after and rec.src_host.len > 0) (self.allocator.dupe(u8, rec.src_path) catch null) else null,
        .delete_src_after = rec.delete_src_after,
        .paused = rec.paused,
        .token = self.allocator.dupe(u8, rec.token) catch null,
        .dest_key = file_transfers.destinationKey(rec.dst_host, rec.dst_path),
    };
    self.transfers.append(self.allocator, t) catch {
        x.deinit();
        self.allocator.free(label);
        t.freeExtras(self.allocator);
        self.allocator.destroy(t);
        return;
    };
    self.setStatusFmt("transfer recovered{s}: {s}", .{ if (rec.paused) " (paused)" else "", t.label });
    self.pumpTransferQueue();
    self.renderJobs();
}

/// Repaint the panel for a change the service made on its own (an
/// adopted orphan, a queued sync-back). Without it a transfer this
/// process took over stays invisible until the user touches something:
/// the panel's sampling tick only runs while it already has rows.
pub fn refreshJobsPanel(ctx: *anyopaque) void {
    const self: *BrowserView = @ptrCast(@alignCast(ctx));
    self.renderJobs();
}

/// Give up the client-mediated transfers this view is running, without
/// finishing them: the records stay, so the next browser face (or
/// another sketerm process) resumes them.
pub fn unclaimMediated(self: *BrowserView) void {
    const service = self.transfer_service orelse return;
    for (self.transfers.items) |t| {
        if (t.token) |token| service.unclaimMediated(token);
    }
}

pub fn startDaemonJob(self: *BrowserView, hc: *HostConn, comptime op: []const u8, path: []const u8, to: []const u8, label: []const u8) void {
    self.startDaemonJobKind(hc, op, path, to, "", label, .{});
}

/// Who the job's reply belongs to. The daemon answers a start request
/// with the job id, and only then can a machine that streams events
/// (a tab's query, the duplicate finder, a compare side) recognize
/// its own events -- so the request has to remember its owner.
pub const JobBind = struct {
    kind: @FieldType(PendingJob, "kind") = .normal,
    /// The tab whose query this job feeds (`.query` only). Never
    /// dereferenced without `tabAlive`: a tab can close while its
    /// start request is still in flight.
    tab: ?*BTab = null,
};

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
    op: []const u8,
    path: []const u8,
    to: []const u8,
    pattern: []const u8,
    label: []const u8,
    bind: JobBind,
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
        .kind = bind.kind,
        .tab = bind.tab,
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
    // Per-tab queries: searches, live queries, panels and flat views
    // all stream into the tab that owns the job.
    if (self.queryConsumeEvent(hc, e)) return;
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
            // An archive that could not be read must not read as an
            // archive with no members.
            if (self.arch_tab) |at| {
                if (self.tabAlive(at)) {
                    at.root.setLoadError(if (e.message.len > 0) e.message else "the archive could not be read");
                    self.renderTab(at);
                }
            }
        }
    }
    // Streaming query events belong to whichever tab owns the job;
    // one that reaches here has no owner left and is simply spent.
    if (std.mem.eql(u8, e.ev, "match") or std.mem.eql(u8, e.ev, "unmatch") or
        std.mem.eql(u8, e.ev, "resync") or std.mem.eql(u8, e.ev, "ready") or
        std.mem.eql(u8, e.ev, "reject")) return;
    const row = for (self.jobs.items) |j| {
        if (j.hc == hc and j.job == e.job) break j;
    } else return;
    // Detail the daemon repeats on every event kind, so it is folded
    // in before the per-event branches rather than in each of them.
    if (e.file.len > 0) row.setCurrentFile(e.file);
    if (e.resumed_from > 0) row.resumed_from = e.resumed_from;
    if (e.files_done > row.files_done) row.files_done = e.files_done;
    if (e.files_total > row.files_total) row.files_total = e.files_total;
    // The daemon repeats the last message on every event, and a
    // RUNNING job uses it to say why it is not advancing.
    if (e.message.len > 0) row.setMessage(e.message);
    if (std.mem.eql(u8, e.ev, "progress")) {
        row.done = e.done;
        row.total = e.total;
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
        // A cross-host copy resumes itself: the destination still holds
        // the verified `.skpart`, so the next attempt continues from
        // where the link died instead of restarting the transfer. Only
        // once the automatic attempts are spent does the row settle as
        // failed, with the reason and a Retry button.
        if (fallbackDirectCopy(self, row, e.kind)) {
            self.setStatusFmt("direct host-to-host failed, relaying via this machine: {s}", .{row.label});
            row.setMessage("hosts cannot reach each other -- relaying via this machine");
        } else if (scheduleCopyRetry(self, row)) {
            self.setStatusFmt("transfer interrupted, resuming shortly: {s} ({s})", .{ row.label, e.message });
            row.setMessage("interrupted -- resuming automatically");
        } else {
            self.setStatusFmt("job failed: {s} ({s})", .{ row.label, e.message });
        }
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

/// Copy-collision policy forwarded to the daemon's copy verb.
/// `dir_mode` decides what happens to a destination DIRECTORY of the
/// same name; `conflict` decides it per entry inside the tree.
pub const CopyMode = struct {
    conflict: []const u8 = "",
    dir_mode: []const u8 = "",
};

/// startDaemonJob variant that records an undo op on completion.
pub fn startDaemonJobUndo(self: *BrowserView, hc: *HostConn, comptime op: []const u8, path: []const u8, to: []const u8, label: []const u8, undo: ?*UndoOp, mode: CopyMode) void {
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
    self.sendOp(hc, .{
        .req = req,
        .op = op,
        .path = path,
        .to = to,
        .@"resume" = false,
        .conflict = mode.conflict,
        .dir_mode = mode.dir_mode,
    });
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
