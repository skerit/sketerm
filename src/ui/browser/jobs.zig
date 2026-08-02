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

pub const CopyAck = struct {
    req: u32 = 0,
    job: u64,
    token: []u8,
    hc: *HostConn,
    attempts: u8 = 0,
};

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
    if (t.token) |token| {
        if (self.transfer_service) |service| {
            if (!service.setMediatedPaused(token, paused)) {
                self.setStatus("could not persist transfer pause state");
                return;
            }
        }
    }
    t.paused = paused;
    if (paused) {
        if (t.started) t.x.pause();
    } else if (t.started) {
        t.x.unpause();
        self.ensureWriteFlush(t.src_hc);
        self.ensureWriteFlush(t.dst_hc);
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
        const ok = t.x.ok();
        const canceled = t.x.state == .canceled;
        if ((ok or canceled) and t.token != null) {
            const service = self.transfer_service orelse {
                i += 1;
                continue;
            };
            // Completion must be crash-durable before launch/watch
            // side effects can make it externally observable.
            if (!service.finishMediated(t.token.?)) {
                i += 1;
                continue;
            }
        }
        if (t.upload_watch) |wt| {
            wt.uploading = false;
            if (t.x.ok()) {
                self.setStatusFmt("synced back: {s}", .{std.fs.path.basename(wt.remote_path)});
            } else if (t.x.state != .canceled) {
                self.setStatusFmt("sync-back failed: {s} ({s})", .{ t.label, t.x.errMsg() });
            }
        } else if (ok) {
            self.setStatusFmt("transfer done: {s}", .{t.label});
            if (t.open_when_done) {
                if (t.open_with_appid) |appid| {
                    launchLocalWithApp(appid, t.x.dst_root);
                } else {
                    launchLocal(t.x.dst_root);
                }
                if (t.watch_host != null and t.watch_remote != null)
                    self.registerEditWatch(t.watch_host.?, t.watch_remote.?, t.x.dst_root);
            }
        } else if (canceled) {
            self.setStatusFmt("transfer canceled: {s}", .{t.label});
        } else {
            self.setStatusFmt("transfer failed: {s} ({s})", .{ t.label, t.x.errMsg() });
        }
        const token_copy = if (t.token) |token|
            (self.allocator.dupe(u8, token) catch null)
        else
            null;
        if (t.token != null and token_copy == null) {
            if (self.transfer_service) |service| service.abandonMediated(t.token.?);
        }
        _ = self.transfers.orderedRemove(i);
        var retry_mediated = false;
        if (token_copy) |token| {
            if (self.transfer_service) |service| {
                if (!ok and !canceled) {
                    retry_mediated = service.recordMediatedFailure(token, t.x.errMsg(), COPY_AUTO_RETRIES);
                }
            }
        }
        t.x.deinit();
        self.allocator.free(t.label);
        t.freeExtras(self.allocator);
        self.allocator.destroy(t);
        if (token_copy) |token| {
            if (retry_mediated and !scheduleMediatedRetry(self, token)) {
                if (self.transfer_service) |service| service.setMediatedFailed(token, "could not schedule transfer retry", true);
            }
            self.allocator.free(token);
        }
    }
    self.pumpTransferQueue();
}

/// One cross-host copy waiting for its destination to be free. The
/// view owns the live queue object; its token points at the persistent
/// intent another view/process adopts if this one closes.
pub const CopyItem = struct {
    coordinator: *HostConn,
    src_hc: *HostConn,
    dst_hc: *HostConn,
    src_path: []u8,
    dst_path: []u8,
    label: []u8,
    token: []u8,
    batch_id: u64 = 0,
    batch_total: usize = 0,
    dest_key: u64,
    move: bool = false,
    no_replace: bool = false,
    direct: bool = false,

    pub fn destroy(self: *CopyItem, allocator: std.mem.Allocator) void {
        allocator.free(self.src_path);
        allocator.free(self.dst_path);
        allocator.free(self.label);
        allocator.free(self.token);
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
    no_replace: bool,
    batch_id: u64,
    batch_total: usize,
    recovery_token: ?[]const u8,
) void {
    const item = self.allocator.create(CopyItem) catch {
        if (recovery_token) |token| if (self.transfer_service) |service| service.abandonMediated(token);
        return;
    };
    const src = self.allocator.dupe(u8, src_path) catch {
        self.allocator.destroy(item);
        if (recovery_token) |token| if (self.transfer_service) |service| service.abandonMediated(token);
        return;
    };
    const dst = self.allocator.dupe(u8, dst_path) catch {
        self.allocator.free(src);
        self.allocator.destroy(item);
        if (recovery_token) |token| if (self.transfer_service) |service| service.abandonMediated(token);
        return;
    };
    const label = std.fmt.allocPrint(self.allocator, "{s}:{s} -> {s}", .{
        src_hc.label(), std.fs.path.basename(src_path), dst_hc.label(),
    }) catch {
        self.allocator.free(src);
        self.allocator.free(dst);
        self.allocator.destroy(item);
        if (recovery_token) |token| if (self.transfer_service) |service| service.abandonMediated(token);
        return;
    };
    const service = self.transfer_service orelse {
        self.allocator.free(src);
        self.allocator.free(dst);
        self.allocator.free(label);
        self.allocator.destroy(item);
        self.setStatus("transfer not started because durable recovery is unavailable");
        return;
    };
    const record_token = recovery_token orelse service.newUserCopy(
        src_hc.host orelse "",
        src_path,
        dst_hc.host orelse "",
        dst_path,
        move,
        no_replace,
        batch_id,
        batch_total,
        coordinator.host,
    ) orelse {
        self.allocator.free(src);
        self.allocator.free(dst);
        self.allocator.free(label);
        self.allocator.destroy(item);
        self.setStatus("transfer not started because its recovery record could not be saved");
        return;
    };
    const token = self.allocator.dupe(u8, record_token) catch {
        service.abandonMediated(record_token);
        self.allocator.free(src);
        self.allocator.free(dst);
        self.allocator.free(label);
        self.allocator.destroy(item);
        return;
    };
    if (!service.setMediatedCoordinator(record_token, coordinator.host orelse "")) {
        service.abandonMediated(record_token);
        self.allocator.free(src);
        self.allocator.free(dst);
        self.allocator.free(label);
        self.allocator.free(token);
        self.allocator.destroy(item);
        return;
    }
    item.* = .{
        .coordinator = coordinator,
        .src_hc = src_hc,
        .dst_hc = dst_hc,
        .src_path = src,
        .dst_path = dst,
        .label = label,
        .token = token,
        .batch_id = batch_id,
        .batch_total = batch_total,
        .dest_key = file_transfers.destinationKey(dst_hc.host orelse "", dst_path),
        .move = move,
        .no_replace = no_replace,
        .direct = coordinator.host != null,
    };
    self.copy_queue.items.append(self.allocator, item) catch {
        service.abandonMediated(item.token);
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
    if (!coordinatorSupports(item.coordinator, item.move, item.no_replace)) {
        const replacement = if (item.direct)
            self.hostConnFor(null)
        else
            self.hostConnFor(item.coordinator.host);
        if (replacement) |hc| {
            if (coordinatorSupports(hc, item.move, item.no_replace)) {
                item.coordinator = hc;
                item.direct = false;
            }
        }
        if (!coordinatorSupports(item.coordinator, item.move, item.no_replace)) {
            self.setStatusFmt("transfer waiting for its coordinator: {s}", .{item.label});
            return;
        }
    }
    for (self.copy_queue.items.items, 0..) |queued, i| {
        if (queued == item) {
            _ = self.copy_queue.items.orderedRemove(i);
            break;
        }
    }
    // The queue item's owned strings move into the retry record, which
    // outlives the job: a copy that dies with a staged partial must be
    // resumable without asking the user to find the paths again.
    const retry = self.allocator.create(CopyRetry) catch {
        if (self.transfer_service) |service| service.abandonMediated(item.token);
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
        .token = item.token,
        .batch_id = item.batch_id,
        .batch_total = item.batch_total,
        .dest_key = item.dest_key,
        .attempts = if (self.transfer_service) |service| service.mediatedAttempts(item.token) else 0,
        .move = item.move,
        .no_replace = item.no_replace,
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
    const service = self.transfer_service orelse {
        retry.destroy(self.allocator);
        return false;
    };
    if (!service.mediatedRunnable(retry.token)) {
        retry.destroy(self.allocator);
        return false;
    }
    if (service.mediatedAckPending(retry.token)) {
        self.retry_pending.append(self.allocator, retry) catch {
            service.setMediatedFailed(retry.token, "could not wait for transfer acknowledgment", true);
            retry.destroy(self.allocator);
            return false;
        };
        if (self.retry_timer == 0)
            self.retry_timer = c.g_timeout_add(COPY_RETRY_DELAY_MS, @ptrCast(&onRetryTimer), @ptrCast(self));
        return true;
    }
    if (retry.coordinator.state != .ready) {
        service.redispatchMediated(retry.token);
        retry.destroy(self.allocator);
        return false;
    }
    if (!coordinatorSupports(retry.coordinator, retry.move, retry.no_replace) or
        !service.setMediatedCoordinator(retry.token, retry.coordinator.host orelse ""))
    {
        service.abandonMediated(retry.token);
        retry.destroy(self.allocator);
        return false;
    }
    const req = self.nextReq();
    const pj = self.allocator.create(PendingJob) catch {
        service.abandonMediated(retry.token);
        retry.destroy(self.allocator);
        return false;
    };
    pj.* = .{
        .req = req,
        .hc = retry.coordinator,
        .label = self.allocator.dupe(u8, retry.label) catch {
            self.allocator.destroy(pj);
            service.abandonMediated(retry.token);
            retry.destroy(self.allocator);
            return false;
        },
        .batch_id = retry.batch_id,
        .batch_total = retry.batch_total,
        .dest_key = retry.dest_key,
        .retry = retry,
    };
    pj.paths.set(retry.src_path, retry.dst_path);
    self.pending_jobs.append(self.allocator, pj) catch {
        self.allocator.free(pj.label);
        self.allocator.destroy(pj);
        service.abandonMediated(retry.token);
        retry.destroy(self.allocator);
        return false;
    };
    // Host strings are relative to the COORDINATOR: the side the
    // coordinator itself owns is "" (its own disk), and a remote
    // coordinator resolves the other side through ITS OWN ssh/UDP
    // config — which is exactly what direct transfer means.
    const client_token = service.mediatedClientToken(retry.token) orelse {
        for (self.pending_jobs.items, 0..) |pending, i| {
            if (pending == pj) {
                _ = self.pending_jobs.orderedRemove(i);
                break;
            }
        }
        self.allocator.free(pj.label);
        self.allocator.destroy(pj);
        retry.destroy(self.allocator);
        return false;
    };
    self.sendOp(retry.coordinator, .{
        .req = req,
        .op = "cross_copy",
        .path = retry.src_path,
        .to = retry.dst_path,
        .src_host = if (retry.src_hc == retry.coordinator) "" else retry.src_hc.host orelse "",
        .dst_host = if (retry.dst_hc == retry.coordinator) "" else retry.dst_hc.host orelse "",
        .@"resume" = true,
        .delete_src = retry.move,
        .no_replace = retry.no_replace,
        .dial_tries = @as(u32, if (retry.direct) 2 else 0),
        .client_token = client_token,
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
            std.mem.eql(u8, jr.?.token, fr.token))
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

/// Submit everything whose delay has elapsed. The timer is view-owned,
/// but every retry also has a ledger record another face can adopt.
pub fn onRetryTimer(user: ?*anyopaque) callconv(.c) c.gboolean {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    self.retry_timer = 0;
    var pending = self.retry_pending;
    self.retry_pending = .empty;
    defer pending.deinit(self.allocator);
    for (pending.items) |retry| _ = submitRetry(self, retry);
    var mediated = self.mediated_retry_tokens;
    self.mediated_retry_tokens = .empty;
    defer mediated.deinit(self.allocator);
    for (mediated.items) |token| {
        if (self.transfer_service) |service| service.redispatchMediated(token);
        self.allocator.free(token);
    }
    for (self.copy_acks.items) |*ack| {
        if (ack.hc.state == .dead)
            ack.hc = self.hostConnFor(ack.hc.host) orelse ack.hc;
    }
    pumpCopyAcks(self);
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
    if (local.state == .ready and !coordinatorSupports(local, retry.move, retry.no_replace)) return false;
    retry.coordinator = local;
    retry.direct = false;
    if (self.transfer_service) |service| {
        if (!service.renewMediatedAttempt(retry.token, local.host orelse "", false)) return false;
        retry.attempts = service.mediatedAttempts(retry.token);
    } else return false;
    row.retry = retry.clone(self.allocator);
    if (local.state == .ready) {
        const submitted = submitRetry(self, retry);
        if (submitted) row.retry_scheduled = true;
        return submitted;
    }
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
    if (retry.attempts >= COPY_AUTO_RETRIES) {
        if (self.transfer_service) |service| service.setMediatedFailed(retry.token, row.messageText(), false);
        return false;
    }
    if (self.transfer_service) |service| {
        if (!service.renewMediatedAttempt(retry.token, retry.coordinator.host orelse "", true)) return false;
        retry.attempts = service.mediatedAttempts(retry.token);
    } else return false;
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
    for (self.mediated_retry_tokens.items) |token| self.allocator.free(token);
    self.mediated_retry_tokens.deinit(self.allocator);
    self.mediated_retry_tokens = .empty;
}

pub fn cancelScheduledRetry(self: *BrowserView, token: []const u8) void {
    var i: usize = 0;
    while (i < self.retry_pending.items.len) {
        const retry = self.retry_pending.items[i];
        if (!std.mem.eql(u8, retry.token, token)) {
            i += 1;
            continue;
        }
        _ = self.retry_pending.orderedRemove(i);
        retry.destroy(self.allocator);
    }
    i = 0;
    while (i < self.mediated_retry_tokens.items.len) {
        const pending = self.mediated_retry_tokens.items[i];
        if (!std.mem.eql(u8, pending, token)) {
            i += 1;
            continue;
        }
        _ = self.mediated_retry_tokens.orderedRemove(i);
        self.allocator.free(pending);
    }
}

fn scheduleMediatedRetry(self: *BrowserView, token: []const u8) bool {
    const owned = self.allocator.dupe(u8, token) catch return false;
    self.mediated_retry_tokens.append(self.allocator, owned) catch {
        self.allocator.free(owned);
        return false;
    };
    if (self.retry_timer == 0)
        self.retry_timer = c.g_timeout_add(COPY_RETRY_DELAY_MS, @ptrCast(&onRetryTimer), @ptrCast(self));
    return true;
}

/// A daemon refused the start request before a JobRow existed. Keep
/// the durable record and retry it through the same bounded resume
/// path instead of letting an invisible claimed record strand it.
pub fn retryRejectedCopy(self: *BrowserView, retry: *CopyRetry, reason: []const u8) bool {
    if (retry.no_replace and (std.mem.indexOf(u8, reason, "destination exists") != null or
        std.mem.indexOf(u8, reason, "EXIST") != null))
    {
        if (self.transfer_service) |service|
            _ = service.recordMediatedFailure(retry.token, "destination appeared before the transfer could be installed", 1);
        retry.destroy(self.allocator);
        return false;
    }
    if (retry.attempts >= COPY_AUTO_RETRIES) {
        if (self.transfer_service) |service| _ = service.recordMediatedFailure(retry.token, "daemon refused the transfer start", 1);
        retry.destroy(self.allocator);
        return false;
    }
    const service = self.transfer_service orelse {
        retry.destroy(self.allocator);
        return false;
    };
    if (!service.renewMediatedAttempt(retry.token, retry.coordinator.host orelse "", true)) {
        service.abandonMediated(retry.token);
        retry.destroy(self.allocator);
        return false;
    }
    retry.attempts = service.mediatedAttempts(retry.token);
    self.retry_pending.append(self.allocator, retry) catch {
        _ = service.recordMediatedFailure(retry.token, "could not schedule transfer retry", 1);
        retry.destroy(self.allocator);
        return false;
    };
    if (self.retry_timer == 0)
        self.retry_timer = c.g_timeout_add(COPY_RETRY_DELAY_MS, @ptrCast(&onRetryTimer), @ptrCast(self));
    return true;
}

/// The jobs panel's Retry button: resume a copy the automatic attempts
/// gave up on. The record is cloned so the failed row keeps its own
/// (the user may press Retry again after a second failure).
pub fn retryCopyJob(self: *BrowserView, row: *JobRow) void {
    if (row.retry_scheduled) return;
    const retry = row.retry orelse return;
    if (self.transfer_service) |service| {
        if (!service.restartMediatedAttempt(retry.token)) return;
    } else return;
    const fresh = retry.clone(self.allocator) orelse return;
    fresh.attempts = 0;
    // The new attempt's row replaces this one once the daemon answers
    // (dropSupersededRetryRows); until then the button stays hidden.
    if (submitRetry(self, fresh)) row.retry_scheduled = true;
    self.renderJobs();
}

fn queueUserCopyAck(self: *BrowserView, token_in: []const u8, job: u64, host: []const u8) bool {
    if (job == 0) return true;
    for (self.copy_acks.items) |ack| {
        if (ack.job == job and std.mem.eql(u8, ack.token, token_in)) return true;
    }
    const hc = self.hostConnFor(if (host.len == 0) null else host) orelse return false;
    const token = self.allocator.dupe(u8, token_in) catch return false;
    self.copy_acks.append(self.allocator, .{
        .job = job,
        .token = token,
        .hc = hc,
    }) catch {
        self.allocator.free(token);
        return false;
    };
    pumpCopyAcks(self);
    return true;
}

pub fn pumpCopyAcks(self: *BrowserView) void {
    for (self.copy_acks.items) |*ack| {
        if (ack.hc.state == .dead) {
            if (self.retry_timer == 0)
                self.retry_timer = c.g_timeout_add(COPY_RETRY_DELAY_MS, @ptrCast(&onRetryTimer), @ptrCast(self));
            continue;
        }
        if (ack.req != 0 or ack.hc.state != .ready) continue;
        ack.req = self.nextReq();
        self.sendOp(ack.hc, .{ .req = ack.req, .op = "job_ack", .job = ack.job });
    }
}

fn acknowledgeUserCopy(self: *BrowserView, row: *JobRow, finish: bool) bool {
    const retry = row.retry orelse return true;
    const service = self.transfer_service orelse return false;
    const host = row.hc.host orelse "";
    if (!service.noteMediatedTerminal(retry.token, host, row.job, finish)) return false;
    if (!queueUserCopyAck(self, retry.token, row.job, host)) service.unclaimMediated(retry.token);
    return true;
}

fn refreshJobFreeSpace(self: *BrowserView, row: *JobRow) void {
    for (self.tabs.items) |tab| {
        var affected = tab.hc == row.hc;
        if (row.retry) |retry| {
            affected = affected or
                @import("../../filebrowser/paths.zig").hostEq(tab.hc.host, retry.src_hc.host) or
                @import("../../filebrowser/paths.zig").hostEq(tab.hc.host, retry.dst_hc.host);
        }
        if (affected) self.requestFreeSpace(tab);
    }
}

/// Drop a queued cross-host copy that was never submitted.
pub fn cancelQueuedCopy(self: *BrowserView, item: *CopyItem) void {
    for (self.copy_queue.items.items, 0..) |queued, i| {
        if (queued != item) continue;
        if (self.transfer_service) |service| {
            if (!service.cancelMediatedQueued(item.token)) {
                self.setStatus("could not persist transfer cancellation");
                return;
            }
        } else return;
        _ = self.copy_queue.items.orderedRemove(i);
        self.setStatusFmt("transfer canceled: {s}", .{item.label});
        item.destroy(self.allocator);
        return;
    }
}

/// Drop a host/coordinator wait before any copy job was submitted.
pub fn cancelDeferredTransfer(self: *BrowserView, item: *DeferredTransfer) void {
    for (self.deferred_transfers.items, 0..) |deferred, i| {
        if (deferred != item) continue;
        if (deferred.token) |token| {
            const service = self.transfer_service orelse return;
            if (!service.cancelMediatedQueued(token)) {
                self.setStatus("could not persist transfer cancellation");
                return;
            }
        }
        _ = self.deferred_transfers.orderedRemove(i);
        self.setStatusFmt("transfer canceled: {s}", .{std.fs.path.basename(deferred.src_path)});
        deferred.destroy(self.allocator);
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
    no_replace: bool = false,
    batch_id: u64 = 0,
    batch_total: usize = 0,
};

/// The daemon that should coordinate a cross-host copy/move, or null
/// when none qualifies (a move then degrades to client-mediated).
/// Remote-to-remote picks the destination daemon when it advertises
/// cross_move; everything else (and the fallback) is the local daemon,
/// which for a MOVE must itself advertise cross_move.
fn coordinatorSupports(hc: *const HostConn, move: bool, no_replace: bool) bool {
    return hc.state == .ready and hc.conn.durable_copy and
        (!move or hc.conn.cross_move) and
        (!no_replace or hc.conn.copy_no_replace);
}

fn pickCoordinator(self: *BrowserView, src_hc: *HostConn, dst_hc: *HostConn, move: bool, no_replace: bool) ?*HostConn {
    if (src_hc.host != null and dst_hc.host != null and src_hc != dst_hc and
        coordinatorSupports(dst_hc, move, no_replace))
        return dst_hc;
    const local = self.hostConnFor(null) orelse return null;
    return if (coordinatorSupports(local, move, no_replace)) local else null;
}

/// A paste/send that arrived while its source or destination host was
/// still CONNECTING. Held here and released by wireReady — the first
/// paste onto a cold host used to be silently dropped with "retry in
/// a moment" as the only recovery.
pub const DeferredTransfer = struct {
    src_hc: *HostConn,
    dst_hc: *HostConn,
    coordinator: ?*HostConn = null,
    wait_for_coordinator: bool = false,
    src_path: []u8,
    dst_path: []u8,
    open_when_done: bool,
    open_with_appid: ?[]u8,
    watch_host: ?[]u8,
    watch_remote: ?[]u8,
    delete_src_after: bool,
    no_replace: bool,
    batch_id: u64,
    batch_total: usize,
    /// Existing user-copy recovery record when admission had to wait.
    token: ?[]u8 = null,

    pub fn destroy(self: *DeferredTransfer, allocator: std.mem.Allocator) void {
        allocator.free(self.src_path);
        allocator.free(self.dst_path);
        if (self.open_with_appid) |s| allocator.free(s);
        if (self.watch_host) |s| allocator.free(s);
        if (self.watch_remote) |s| allocator.free(s);
        if (self.token) |s| allocator.free(s);
        allocator.destroy(self);
    }
};

fn deferTransfer(
    self: *BrowserView,
    src_hc: *HostConn,
    src_path: []const u8,
    dst_hc: *HostConn,
    dst_path: []const u8,
    opts: TransferOpts,
    recovery_token: ?[]const u8,
    coordinator: ?*HostConn,
    wait_for_coordinator: bool,
) void {
    const d = self.allocator.create(DeferredTransfer) catch {
        if (recovery_token) |token| if (self.transfer_service) |service| service.abandonMediated(token);
        return;
    };
    const src = self.allocator.dupe(u8, src_path) catch {
        self.allocator.destroy(d);
        if (recovery_token) |token| if (self.transfer_service) |service| service.abandonMediated(token);
        return;
    };
    const dst = self.allocator.dupe(u8, dst_path) catch {
        self.allocator.free(src);
        self.allocator.destroy(d);
        if (recovery_token) |token| if (self.transfer_service) |service| service.abandonMediated(token);
        return;
    };
    const token_owned = if (recovery_token) |s| self.allocator.dupe(u8, s) catch {
        self.allocator.free(src);
        self.allocator.free(dst);
        self.allocator.destroy(d);
        if (self.transfer_service) |service| service.abandonMediated(s);
        return;
    } else null;
    d.* = .{
        .src_hc = src_hc,
        .dst_hc = dst_hc,
        .coordinator = coordinator,
        .wait_for_coordinator = wait_for_coordinator,
        .src_path = src,
        .dst_path = dst,
        .open_when_done = opts.open_when_done,
        .open_with_appid = if (opts.open_with_appid) |s| (self.allocator.dupe(u8, s) catch null) else null,
        .watch_host = if (opts.watch_host) |s| (self.allocator.dupe(u8, s) catch null) else null,
        .watch_remote = if (opts.watch_remote) |s| (self.allocator.dupe(u8, s) catch null) else null,
        .delete_src_after = opts.delete_src_after,
        .no_replace = opts.no_replace,
        .batch_id = opts.batch_id,
        .batch_total = opts.batch_total,
        .token = token_owned,
    };
    self.deferred_transfers.append(self.allocator, d) catch {
        if (d.token) |token| {
            if (self.transfer_service) |service| service.abandonMediated(token);
        }
        d.destroy(self.allocator);
        return;
    };
    const waiting = if (src_hc.state != .ready) src_hc else dst_hc;
    self.setStatusFmt("transfer queued — waiting for {s} to connect", .{waiting.label()});
}

/// Release every deferred transfer whose hosts are now both ready.
/// User copies remain ledger-backed while a host reconnects.
pub fn pumpDeferredTransfers(self: *BrowserView) void {
    var i: usize = 0;
    while (i < self.deferred_transfers.items.len) {
        const d = self.deferred_transfers.items[i];
        if (d.src_hc.state == .dead) d.src_hc = self.hostConnFor(d.src_hc.host) orelse d.src_hc;
        if (d.dst_hc.state == .dead) d.dst_hc = self.hostConnFor(d.dst_hc.host) orelse d.dst_hc;
        if (d.wait_for_coordinator) {
            const coordinator = pickCoordinator(self, d.src_hc, d.dst_hc, d.delete_src_after, d.no_replace) orelse {
                i += 1;
                continue;
            };
            d.coordinator = coordinator;
            d.wait_for_coordinator = false;
        }
        if (d.coordinator) |coordinator| {
            if (coordinator.state == .dead)
                d.coordinator = self.hostConnFor(coordinator.host);
            if (d.coordinator == null or d.coordinator.?.state != .ready) {
                i += 1;
                continue;
            }
        }
        if (d.src_hc.state == .dead or d.dst_hc.state == .dead) {
            if (d.token != null) {
                i += 1;
                continue;
            }
            const gone = if (d.src_hc.state == .dead) d.src_hc else d.dst_hc;
            self.setStatusFmt("transfer dropped — {s} is unreachable: {s}", .{ gone.label(), std.fs.path.basename(d.src_path) });
            _ = self.deferred_transfers.orderedRemove(i);
            d.destroy(self.allocator);
            continue;
        }
        if (d.src_hc.state != .ready or d.dst_hc.state != .ready) {
            i += 1;
            continue;
        }
        _ = self.deferred_transfers.orderedRemove(i);
        startTransferImpl(self, d.src_hc, d.src_path, d.dst_hc, d.dst_path, .{
            .open_when_done = d.open_when_done,
            .open_with_appid = d.open_with_appid,
            .watch_host = d.watch_host,
            .watch_remote = d.watch_remote,
            .delete_src_after = d.delete_src_after,
            .no_replace = d.no_replace,
            .batch_id = d.batch_id,
            .batch_total = d.batch_total,
        }, if (d.token) |token| token else null, d.coordinator);
        d.destroy(self.allocator);
    }
}

pub fn startTransfer(
    self: *BrowserView,
    src_hc: *HostConn,
    src_path: []const u8,
    dst_hc: *HostConn,
    dst_path: []const u8,
    opts: TransferOpts,
) void {
    startTransferImpl(self, src_hc, src_path, dst_hc, dst_path, opts, null, null);
}

/// Admit one child whose durable identity already lives in a batch
/// manifest. The per-item record is materialized before queue ownership
/// moves into the ordinary transfer path.
pub fn startBatchTransfer(
    self: *BrowserView,
    src_hc: *HostConn,
    src_path: []const u8,
    dst_hc: *HostConn,
    dst_path: []const u8,
    opts: TransferOpts,
    batch_token: []const u8,
    item_index: usize,
) bool {
    const service = self.transfer_service orelse return false;
    const coordinator = pickCoordinator(self, src_hc, dst_hc, opts.delete_src_after, opts.no_replace);
    const token = service.materializeUserBatchItem(
        batch_token,
        item_index,
        if (coordinator) |hc| hc.host else null,
        dst_path,
        opts.no_replace,
        @ptrCast(self),
    ) orelse return false;
    if (copyTokenActive(self, token)) return true;
    // Recovery can encounter a child that completed before the
    // manifest itself was retired. Its retained tombstone proves this
    // item needs no second submission.
    if (!service.mediatedRunnable(token)) return true;
    const before = self.pending_jobs.items.len + self.copy_queue.items.items.len +
        self.deferred_transfers.items.len + self.transfers.items.len;
    startTransferImpl(self, src_hc, src_path, dst_hc, dst_path, opts, token, coordinator);
    return self.pending_jobs.items.len + self.copy_queue.items.items.len +
        self.deferred_transfers.items.len + self.transfers.items.len > before;
}

fn startTransferImpl(
    self: *BrowserView,
    src_hc: *HostConn,
    src_path: []const u8,
    dst_hc: *HostConn,
    dst_path: []const u8,
    opts: TransferOpts,
    recovery_token: ?[]const u8,
    forced_coordinator: ?*HostConn,
) void {
    const open_when_done = opts.open_when_done;
    const user_copy = !open_when_done and opts.upload_watch == null;
    const initial_coordinator = forced_coordinator orelse
        (if (user_copy) pickCoordinator(self, src_hc, dst_hc, opts.delete_src_after, opts.no_replace) else null);
    var user_token = recovery_token;
    if (user_copy and user_token == null) {
        const service = self.transfer_service orelse {
            self.setStatus("transfer not started because durable recovery is unavailable");
            return;
        };
        user_token = service.newUserCopy(
            src_hc.host orelse "",
            src_path,
            dst_hc.host orelse "",
            dst_path,
            opts.delete_src_after,
            opts.no_replace,
            opts.batch_id,
            opts.batch_total,
            if (initial_coordinator) |coordinator| coordinator.host else null,
        ) orelse {
            self.setStatus("transfer not started because its recovery record could not be saved");
            return;
        };
    }
    // User copies are daemon-coordinated and ledger-backed before
    // queue admission. A local coordinator can dial a still-connecting
    // endpoint itself, while remote-to-remote still prefers the
    // destination daemon's direct path.
    if (user_copy) {
        if (initial_coordinator) |coordinator| {
            if (coordinator.state != .ready) {
                deferTransfer(self, src_hc, src_path, dst_hc, dst_path, opts, user_token, coordinator, false);
                return;
            }
            if (coordinator.conn.durable_copy and (!opts.no_replace or coordinator.conn.copy_no_replace) and (!opts.delete_src_after or coordinator.conn.cross_move)) {
                enqueueCrossCopy(self, coordinator, src_hc, src_path, dst_hc, dst_path, opts.delete_src_after, opts.no_replace, opts.batch_id, opts.batch_total, user_token);
                return;
            }
        }
        if (opts.delete_src_after) {
            deferTransfer(self, src_hc, src_path, dst_hc, dst_path, opts, user_token, null, true);
            self.setStatus("move queued until a daemon with durable move support is available");
            return;
        }
        if (src_hc.state != .ready or dst_hc.state != .ready) {
            deferTransfer(self, src_hc, src_path, dst_hc, dst_path, opts, user_token, initial_coordinator, false);
            return;
        }
        const service = self.transfer_service orelse return;
        if (!service.useMediatedFallback(user_token.?)) {
            self.setStatus("transfer not started because its recovery record could not be updated");
            service.abandonMediated(user_token.?);
            return;
        }
    }
    if (src_hc.state != .ready or dst_hc.state != .ready) {
        // A sync-back upload carries a raw EditWatch pointer that must
        // not outlive this call — that one path keeps the old refusal.
        if (!user_copy and (src_hc.state == .dead or dst_hc.state == .dead or opts.upload_watch != null)) {
            self.setStatus("both hosts must be connected — retry in a moment");
            return;
        }
        deferTransfer(self, src_hc, src_path, dst_hc, dst_path, opts, user_token, initial_coordinator, false);
        return;
    }
    if (opts.no_replace and !dst_hc.conn.copy_no_replace) {
        self.setStatusFmt("transfer not queued: {s} lacks safe no-replace support", .{dst_hc.label()});
        if (user_token) |token| if (self.transfer_service) |service| service.abandonMediated(token);
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
    ) catch {
        if (user_token) |token| if (self.transfer_service) |service| service.abandonMediated(token);
        return;
    };
    x.no_replace = opts.no_replace;
    const label = std.fmt.allocPrint(self.allocator, "{s}:{s} → {s}", .{
        src_hc.label(), std.fs.path.basename(src_path), dst_hc.label(),
    }) catch {
        x.deinit();
        if (user_token) |token| if (self.transfer_service) |service| service.abandonMediated(token);
        return;
    };
    const t = self.allocator.create(ActiveTransfer) catch {
        x.deinit();
        self.allocator.free(label);
        if (user_token) |token| if (self.transfer_service) |service| service.abandonMediated(token);
        return;
    };
    t.* = .{
        .x = x,
        .src_hc = src_hc,
        .dst_hc = dst_hc,
        .label = label,
        .batch_id = opts.batch_id,
        .batch_total = opts.batch_total,
        .open_when_done = open_when_done,
        .open_with_appid = if (opts.open_with_appid) |s| (self.allocator.dupe(u8, s) catch null) else null,
        .watch_host = if (opts.watch_host) |s| (self.allocator.dupe(u8, s) catch null) else null,
        .watch_remote = if (opts.watch_remote) |s| (self.allocator.dupe(u8, s) catch null) else null,
        .upload_watch = opts.upload_watch,
        .delete_src_after = opts.delete_src_after,
        .user_copy = user_copy,
        .dest_key = file_transfers.destinationKey(dst_hc.host orelse "", dst_path),
    };
    self.transfers.append(self.allocator, t) catch {
        x.deinit();
        self.allocator.free(label);
        t.freeExtras(self.allocator);
        self.allocator.destroy(t);
        if (user_token) |token| if (self.transfer_service) |service| service.abandonMediated(token);
        return;
    };
    // Record it so a pause -- or a crash -- can be picked up again,
    // here or by another sketerm process. A sync-back upload is
    // deliberately not recorded: it belongs to an in-view EditWatch
    // that no other process can reconstruct.
    if (opts.upload_watch == null) {
        if (user_token) |token| {
            t.token = self.allocator.dupe(u8, token) catch {
                for (self.transfers.items, 0..) |active, i| if (active == t) {
                    _ = self.transfers.orderedRemove(i);
                    break;
                };
                t.x.deinit();
                self.allocator.free(t.label);
                t.freeExtras(self.allocator);
                self.allocator.destroy(t);
                if (self.transfer_service) |service| service.abandonMediated(token);
                return;
            };
        } else if (self.transfer_service) |service| {
            const token = service.newMediated(
                src_hc.host orelse "",
                src_path,
                dst_hc.host orelse "",
                dst_path,
                .{
                    .app_id = opts.open_with_appid orelse "",
                    .open_when_done = open_when_done,
                    .delete_src_after = opts.delete_src_after,
                    .no_replace = opts.no_replace,
                    .watch_after = opts.watch_host != null,
                },
            );
            if (token) |tok| {
                t.token = self.allocator.dupe(u8, tok) catch {
                    for (self.transfers.items, 0..) |active, i| if (active == t) {
                        _ = self.transfers.orderedRemove(i);
                        break;
                    };
                    t.x.deinit();
                    self.allocator.free(t.label);
                    t.freeExtras(self.allocator);
                    self.allocator.destroy(t);
                    service.abandonMediated(tok);
                    return;
                };
            }
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
    if (rec.record_version < @import("../../filebrowser/transfers.zig").VERSION and rec.delete_src_after) {
        if (self.transfer_service) |service|
            _ = service.recordMediatedFailure(rec.token, "legacy move held because its copy/delete phase is unknown", 1);
        self.setStatus("legacy move held safely; retry it with the current daemon");
        return;
    }
    if (rec.user_copy) {
        if (rec.ack_job != 0) {
            const service = self.transfer_service orelse return;
            if (!queueUserCopyAck(self, rec.token, rec.ack_job, rec.ack_host)) {
                service.unclaimMediated(rec.token);
                return;
            }
            if (!rec.retired) service.unclaimMediated(rec.token);
            return;
        }
        if (rec.state == .failed) {
            if (self.transfer_service) |service| service.unclaimMediated(rec.token);
            return;
        }
        if (rec.retired) return;
        if (copyTokenActive(self, rec.token)) return;
        const src_hc = self.hostConnFor(if (rec.src_host.len == 0) null else rec.src_host) orelse return;
        const dst_hc = self.hostConnFor(if (rec.dst_host.len == 0) null else rec.dst_host) orelse return;
        const coordinator = if (rec.coordinator_set)
            self.hostConnFor(if (rec.coordinator_host.len == 0) null else rec.coordinator_host)
        else
            null;
        const recovered_name = self.allocator.dupe(u8, std.fs.path.basename(rec.src_path)) catch null;
        defer if (recovered_name) |name| self.allocator.free(name);
        startTransferImpl(self, src_hc, rec.src_path, dst_hc, rec.dst_path, .{
            .delete_src_after = rec.delete_src_after,
            .no_replace = rec.no_replace,
            .batch_id = rec.batch_id,
            .batch_total = @intCast(rec.batch_total),
        }, rec.token, coordinator);
        self.renderJobs();
        self.setStatusFmt("transfer recovered: {s}", .{recovered_name orelse "transfer"});
        return;
    }
    if (rec.state == .failed) return;
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
    x.no_replace = rec.no_replace;
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
        .batch_id = rec.batch_id,
        .batch_total = @intCast(rec.batch_total),
        .open_when_done = rec.open_when_done,
        .open_with_appid = if (rec.app_id.len > 0) (self.allocator.dupe(u8, rec.app_id) catch null) else null,
        .watch_host = if (rec.watch_after and rec.src_host.len > 0) (self.allocator.dupe(u8, rec.src_host) catch null) else null,
        .watch_remote = if (rec.watch_after and rec.src_host.len > 0) (self.allocator.dupe(u8, rec.src_path) catch null) else null,
        .delete_src_after = rec.delete_src_after,
        .user_copy = rec.user_copy,
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

fn copyTokenActive(self: *BrowserView, token: []const u8) bool {
    for (self.copy_queue.items.items) |item| if (std.mem.eql(u8, item.token, token)) return true;
    for (self.deferred_transfers.items) |item| if (item.token) |t| {
        if (std.mem.eql(u8, t, token)) return true;
    };
    for (self.pending_jobs.items) |item| if (item.retry) |retry| {
        if (std.mem.eql(u8, retry.token, token)) return true;
    };
    for (self.jobs.items) |item| if (item.retry) |retry| {
        if (std.mem.eql(u8, retry.token, token) and (!item.terminal() or item.retry_scheduled)) return true;
    };
    for (self.retry_pending.items) |retry| {
        if (std.mem.eql(u8, retry.token, token)) return true;
    }
    for (self.mediated_retry_tokens.items) |pending| {
        if (std.mem.eql(u8, pending, token)) return true;
    }
    return false;
}

/// True when a terminal daemon row already handed its token onward.
pub fn copySuccessorActive(self: *BrowserView, predecessor: *JobRow) bool {
    const token = if (predecessor.retry) |retry| retry.token else return false;
    for (self.transfers.items) |item| if (item.token) |active| {
        if (std.mem.eql(u8, active, token)) return true;
    };
    for (self.copy_queue.items.items) |item| if (std.mem.eql(u8, item.token, token)) return true;
    for (self.deferred_transfers.items) |item| if (item.token) |active| {
        if (std.mem.eql(u8, active, token)) return true;
    };
    for (self.pending_jobs.items) |item| if (item.retry) |retry| {
        if (std.mem.eql(u8, retry.token, token)) return true;
    };
    for (self.jobs.items) |item| if (item != predecessor) if (item.retry) |retry| {
        if (std.mem.eql(u8, retry.token, token)) return true;
    };
    for (self.retry_pending.items) |retry| if (std.mem.eql(u8, retry.token, token)) return true;
    for (self.mediated_retry_tokens.items) |active| if (std.mem.eql(u8, active, token)) return true;
    return false;
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
    for (self.copy_queue.items.items) |item| service.unclaimMediated(item.token);
    for (self.deferred_transfers.items) |item| if (item.token) |token| service.unclaimMediated(token);
    for (self.retry_pending.items) |retry| service.unclaimMediated(retry.token);
    for (self.mediated_retry_tokens.items) |token| service.unclaimMediated(token);
    for (self.pending_jobs.items) |item| if (item.retry) |retry| service.unclaimMediated(retry.token);
    for (self.jobs.items) |item| if (item.retry) |retry| service.unclaimMediated(retry.token);
    for (self.copy_acks.items) |ack| service.unclaimMediated(ack.token);
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
    self.sendOp(hc, .{ .req = req, .op = op, .path = path, .to = to, .@"resume" = true, .verify = self.verifyCopies() });
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
        self.sendOp(hc, .{ .req = req, .op = op, .path = path, .to = to, .@"resume" = false, .verify = self.verifyCopies() });
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
        if (!acknowledgeUserCopy(self, row, true))
            self.setStatus("copy completed, but its durable acknowledgment could not be saved");
        refreshJobFreeSpace(self, row);
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
        const ack_saved = acknowledgeUserCopy(self, row, false);
        // A cross-host copy resumes itself: the destination still holds
        // the verified `.skpart`, so the next attempt continues from
        // where the link died instead of restarting the transfer. Only
        // once the automatic attempts are spent does the row settle as
        // failed, with the reason and a Retry button.
        const destination_collision = if (row.retry) |retry|
            retry.no_replace and (std.mem.indexOf(u8, e.message, "destination exists") != null or
                std.mem.indexOf(u8, e.message, "EXIST") != null)
        else
            false;
        if (row.retry != null and !ack_saved) {
            self.setStatus("transfer failed, but its durable acknowledgment could not be saved");
        } else if (destination_collision) {
            if (row.retry) |retry| if (self.transfer_service) |service|
                service.setMediatedFailed(retry.token, "destination appeared before the transfer could be installed", false);
            self.setStatusFmt("transfer stopped because the destination now exists: {s}", .{row.label});
            row.setMessage("destination appeared before install");
        } else if (fallbackDirectCopy(self, row, e.kind)) {
            self.setStatusFmt("direct host-to-host failed, relaying via this machine: {s}", .{row.label});
            row.setMessage("hosts cannot reach each other -- relaying via this machine");
        } else if (scheduleCopyRetry(self, row)) {
            self.setStatusFmt("transfer interrupted, resuming shortly: {s} ({s})", .{ row.label, e.message });
            row.setMessage("interrupted -- resuming automatically");
        } else {
            self.setStatusFmt("job failed: {s} ({s})", .{ row.label, e.message });
            // Out of automatic attempts: remember the interrupted copy
            // so a later paste of the same source offers Continue.
            if (row.retry) |r| @import("../../filebrowser/incomplete.zig").record(
                self.allocator,
                r.src_hc.host orelse "",
                r.src_path,
                r.dst_hc.host orelse "",
                r.dst_path,
            );
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
        _ = acknowledgeUserCopy(self, row, true);
        self.setStatusFmt("canceled: {s}", .{row.label});
        if (row.retry) |r| @import("../../filebrowser/incomplete.zig").record(
            self.allocator,
            r.src_hc.host orelse "",
            r.src_path,
            r.dst_hc.host orelse "",
            r.dst_path,
        );
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
    // A completed copy is no longer "interrupted".
    if (row.state == .finished) {
        if (row.retry) |r| @import("../../filebrowser/incomplete.zig").clear(
            self.allocator,
            r.dst_hc.host orelse "",
            r.dst_path,
        );
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
    no_replace: bool = false,
    batch_id: u64 = 0,
    batch_total: usize = 0,
};

/// startDaemonJob variant that records an undo op on completion.
pub fn startDaemonJobUndo(self: *BrowserView, hc: *HostConn, comptime op: []const u8, path: []const u8, to: []const u8, label: []const u8, undo: ?*UndoOp, mode: CopyMode) bool {
    if (hc.state != .ready) {
        self.setStatusFmt("not connected to {s}", .{hc.label()});
        if (undo) |u| u.destroy(self.allocator);
        return false;
    }
    if (mode.no_replace and !hc.conn.copy_no_replace) {
        self.setStatusFmt("operation not queued: {s} lacks safe no-replace support", .{hc.label()});
        if (undo) |u| u.destroy(self.allocator);
        return false;
    }
    const req = self.nextReq();
    const pj = self.allocator.create(PendingJob) catch {
        if (undo) |u| u.destroy(self.allocator);
        return false;
    };
    pj.* = .{
        .req = req,
        .hc = hc,
        .label = self.allocator.dupe(u8, label) catch {
            self.allocator.destroy(pj);
            if (undo) |u| u.destroy(self.allocator);
            return false;
        },
        .batch_id = mode.batch_id,
        .batch_total = mode.batch_total,
        .undo_op = undo,
    };
    pj.paths.set(path, to);
    self.pending_jobs.append(self.allocator, pj) catch {
        self.allocator.free(pj.label);
        self.allocator.destroy(pj);
        if (undo) |u| u.destroy(self.allocator);
        return false;
    };
    if (!self.sendOpOk(hc, .{
        .req = req,
        .op = op,
        .path = path,
        .to = to,
        .@"resume" = false,
        .conflict = mode.conflict,
        .dir_mode = mode.dir_mode,
        .no_replace = mode.no_replace,
        .verify = self.verifyCopies(),
    })) {
        const dropped = self.pending_jobs.pop().?;
        self.allocator.free(dropped.label);
        if (dropped.undo_op) |u| u.destroy(self.allocator);
        self.allocator.destroy(dropped);
        return false;
    }
    return true;
}

/// files_verify_copy: hash-compare every copied file before install.
pub fn verifyCopies(self: *BrowserView) bool {
    if (self.ownerWindow()) |win| return win.config.files_verify_copy;
    return false;
}

pub fn startHistoryJob(self: *BrowserView, hc: *HostConn, op_name: []const u8, path: []const u8, to: []const u8, pattern: []const u8, label: []const u8, op: *UndoOp, direction: HistoryDirection, no_replace: bool) void {
    if (no_replace and !hc.conn.copy_no_replace) {
        self.setStatusFmt("history operation retained: {s} lacks safe no-replace support", .{hc.label()});
        return self.restoreHistory(op, direction);
    }
    const req = self.nextReq();
    const pj = self.allocator.create(PendingJob) catch return self.restoreHistory(op, direction);
    pj.* = .{
        .req = req,
        .hc = hc,
        .label = self.allocator.dupe(u8, label) catch {
            self.allocator.destroy(pj);
            return self.restoreHistory(op, direction);
        },
        .history_op = op,
        .history_direction = direction,
    };
    pj.paths.set(path, to);
    self.pending_jobs.append(self.allocator, pj) catch {
        self.allocator.free(pj.label);
        self.allocator.destroy(pj);
        return self.restoreHistory(op, direction);
    };
    self.sendOp(hc, .{ .req = req, .op = op_name, .path = path, .to = to, .pattern = pattern, .no_replace = no_replace });
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
