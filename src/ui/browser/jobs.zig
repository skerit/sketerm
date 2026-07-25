//! Daemon jobs and client-mediated transfers.
//!
//! Every mutation is a job with an id: this module starts them, folds
//! their streamed events back into the view, and renders the jobs
//! panel. Cross-host copies ride fstransfer.Xfer instead, queued so at
//! most MAX_ACTIVE_TRANSFERS run at once.

const std = @import("std");
const c = @import("../../c.zig").c;
const wire = @import("../../mux/wire.zig");
const fstransfer = @import("../../ipc/fstransfer.zig");

const ActiveTransfer = @import("types.zig").ActiveTransfer;
const BrowserView = @import("view.zig").BrowserView;
const EditWatch = @import("types.zig").EditWatch;
const HistoryDirection = @import("types.zig").HistoryDirection;
const HostConn = @import("types.zig").HostConn;
const JobRow = @import("types.zig").JobRow;
const MAX_ACTIVE_TRANSFERS = @import("types.zig").MAX_ACTIVE_TRANSFERS;
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

/// Start queued transfers while below the concurrency cap.
pub fn pumpTransferQueue(self: *BrowserView) void {
    var running: usize = 0;
    for (self.transfers.items) |t| {
        if (t.started and !t.x.isTerminal()) running += 1;
    }
    for (self.transfers.items) |t| {
        if (running >= MAX_ACTIVE_TRANSFERS) break;
        if (t.started or t.x.isTerminal()) continue;
        if (t.src_hc.state != .ready or t.dst_hc.state != .ready) continue;
        t.started = true;
        t.x.start();
        running += 1;
        self.setStatusFmt("transfer started: {s}", .{t.label});
    }
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
        // reconnect through the stable job journal.
        const coordinator = self.hostConnFor(null) orelse return;
        if (coordinator.state != .ready) {
            self.setStatus("local transfer coordinator is not connected");
            return;
        }
        const req = self.nextReq();
        const label = std.fmt.allocPrint(self.allocator, "{s}:{s} -> {s}", .{
            src_hc.label(), std.fs.path.basename(src_path), dst_hc.label(),
        }) catch return;
        const pj = self.allocator.create(PendingJob) catch {
            self.allocator.free(label);
            return;
        };
        pj.* = .{ .req = req, .hc = coordinator, .label = label };
        self.pending_jobs.append(self.allocator, pj) catch {
            self.allocator.free(label);
            self.allocator.destroy(pj);
            return;
        };
        self.sendOp(coordinator, .{
            .req = req,
            .op = "cross_copy",
            .path = src_path,
            .to = dst_path,
            .src_host = src_hc.host orelse "",
            .dst_host = dst_hc.host orelse "",
            .@"resume" = true,
        });
        self.setStatusFmt("durable transfer queued: {s}", .{label});
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
        if (row.state == .running) self.setStatusFmt("{s}: {d} / {d} MB", .{
            row.label, e.done >> 20, e.total >> 20,
        });
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
    self.pending_jobs.append(self.allocator, pj) catch {
        self.allocator.free(pj.label);
        self.allocator.destroy(pj);
        return;
    };
    self.sendOp(hc, .{ .req = req, .op = op, .path = path, .to = to, .pattern = pattern });
}

/// Heap context for one jobs-panel button, freed with the button.
pub const JobBtnCtx = struct {
    allocator: std.mem.Allocator,
    view: *BrowserView,
    /// Daemon job target (hc+job), or transfer target (xfer).
    hc: ?*HostConn = null,
    job: u64 = 0,
    xfer: ?*fstransfer.Xfer = null,
    service_token: ?[]u8 = null,
    kind: enum { pause, resume_, cancel, dismiss, move_up, move_down },

    fn free(user: ?*anyopaque, closure: ?*anyopaque) callconv(.c) void {
        _ = closure;
        const ctx: *JobBtnCtx = @ptrCast(@alignCast(user.?));
        if (ctx.service_token) |token| ctx.allocator.free(token);
        ctx.allocator.destroy(ctx);
    }
};

pub fn jobsButton(self: *BrowserView, row: *c.GtkWidget, icon: [*:0]const u8, ctx_in: JobBtnCtx) void {
    const ctx = self.allocator.create(JobBtnCtx) catch return;
    ctx.* = ctx_in;
    const btn = c.gtk_button_new_from_icon_name(icon);
    c.gtk_button_set_has_frame(@ptrCast(btn), 0);
    _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(&onJobBtn), @ptrCast(ctx), @ptrCast(&JobBtnCtx.free), c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(row), btn);
}

pub fn onJobBtn(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *JobBtnCtx = @ptrCast(@alignCast(user.?));
    const self = ctx.view;
    if (ctx.service_token) |token| {
        const service = self.transfer_service orelse return;
        switch (ctx.kind) {
            .move_up => service.moveQueued(token, -1),
            .move_down => service.moveQueued(token, 1),
            .cancel => service.cancel(token),
            else => {},
        }
        self.renderJobs();
        return;
    }
    if (ctx.xfer) |x| {
        switch (ctx.kind) {
            .cancel => x.cancel(),
            else => {},
        }
        self.reapTransfers();
        self.renderJobs();
        return;
    }
    const hc = ctx.hc orelse return;
    switch (ctx.kind) {
        .pause => {
            self.sendOp(hc, .{ .req = self.nextReq(), .op = "job_pause", .job = ctx.job });
            self.markJob(hc, ctx.job, .paused);
        },
        .resume_ => {
            self.sendOp(hc, .{ .req = self.nextReq(), .op = "job_resume", .job = ctx.job });
            self.markJob(hc, ctx.job, .running);
        },
        .cancel => self.sendOp(hc, .{ .req = self.nextReq(), .op = "job_cancel", .job = ctx.job }),
        .dismiss => {
            var i: usize = 0;
            while (i < self.jobs.items.len) : (i += 1) {
                const j = self.jobs.items[i];
                if (j.hc == hc and j.job == ctx.job) {
                    if (j.undo_op) |u| u.destroy(self.allocator);
                    if (j.undo_trash_orig) |o| self.allocator.free(o);
                    self.allocator.free(j.label);
                    self.allocator.destroy(j);
                    _ = self.jobs.orderedRemove(i);
                    break;
                }
            }
        },
        .move_up, .move_down => {},
    }
    self.renderJobs();
}

pub fn markJob(self: *BrowserView, hc: *HostConn, job: u64, state: @FieldType(JobRow, "state")) void {
    for (self.jobs.items) |j| {
        if (j.hc == hc and j.job == job and !j.terminal()) j.state = state;
    }
}

/// Rebuild the jobs/transfers panel (hidden when empty).
pub fn renderJobs(self: *BrowserView) void {
    while (c.gtk_widget_get_first_child(self.jobs_box)) |child| {
        c.gtk_box_remove(@ptrCast(self.jobs_box), child);
    }
    var scratch = std.heap.ArenaAllocator.init(self.allocator);
    defer scratch.deinit();
    const durable_rows = if (self.transfer_service) |service|
        service.rows(scratch.allocator()) catch &.{}
    else
        &.{};
    const any = self.transfers.items.len > 0 or self.jobs.items.len > 0 or durable_rows.len > 0;
    c.gtk_widget_set_visible(self.jobs_box, if (any) 1 else 0);
    if (!any) return;

    for (durable_rows) |d| {
        const row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6);
        c.gtk_widget_set_margin_start(row, 6);
        c.gtk_widget_set_margin_end(row, 6);
        var buf: [256:0]u8 = undefined;
        const txt = std.fmt.bufPrintZ(&buf, "durable: {s} [{s}]", .{ d.label, @tagName(d.state) }) catch "durable transfer";
        const label = c.gtk_label_new(txt.ptr);
        c.gtk_label_set_xalign(@ptrCast(label), 0);
        c.gtk_widget_set_hexpand(label, 1);
        c.gtk_box_append(@ptrCast(row), label);
        if (d.state == .queued or d.state == .waiting_retry) {
            self.jobsButton(row, "go-up-symbolic", .{ .allocator = self.allocator, .view = self, .service_token = self.allocator.dupe(u8, d.token) catch null, .kind = .move_up });
            self.jobsButton(row, "go-down-symbolic", .{ .allocator = self.allocator, .view = self, .service_token = self.allocator.dupe(u8, d.token) catch null, .kind = .move_down });
        }
        self.jobsButton(row, "process-stop-symbolic", .{ .allocator = self.allocator, .view = self, .service_token = self.allocator.dupe(u8, d.token) catch null, .kind = .cancel });
        c.gtk_box_append(@ptrCast(self.jobs_box), row);
    }

    for (self.transfers.items) |t| {
        const row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6);
        c.gtk_widget_set_margin_start(row, 6);
        c.gtk_widget_set_margin_end(row, 6);
        const p = t.x.progress();
        var lbl: [256:0]u8 = undefined;
        const pct: u64 = if (p.total > 0) p.done * 100 / p.total else 0;
        const txt = if (!t.started)
            std.fmt.bufPrintZ(&lbl, "⇄ {s} — [queued]", .{t.label}) catch "transfer"
        else
            std.fmt.bufPrintZ(&lbl, "⇄ {s} — {d}% ({d}/{d} MB)", .{
                t.label, pct, p.done >> 20, p.total >> 20,
            }) catch "transfer";
        const l = c.gtk_label_new(txt.ptr);
        c.gtk_label_set_xalign(@ptrCast(l), 0);
        c.gtk_widget_set_hexpand(l, 1);
        c.gtk_label_set_ellipsize(@ptrCast(l), c.PANGO_ELLIPSIZE_MIDDLE);
        c.gtk_box_append(@ptrCast(row), l);
        self.jobsButton(row, "process-stop-symbolic", .{
            .allocator = self.allocator,
            .view = self,
            .xfer = t.x,
            .kind = .cancel,
        });
        c.gtk_box_append(@ptrCast(self.jobs_box), row);
    }

    for (self.jobs.items) |j| {
        const row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6);
        c.gtk_widget_set_margin_start(row, 6);
        c.gtk_widget_set_margin_end(row, 6);
        var lbl: [256:0]u8 = undefined;
        const state_txt: []const u8 = switch (j.state) {
            .running => "",
            .paused => " [paused]",
            .finished => " [done]",
            .failed => " [failed]",
            .canceled => " [canceled]",
        };
        const pct: u64 = if (j.total > 0) j.done * 100 / j.total else 0;
        const txt = std.fmt.bufPrintZ(&lbl, "{s}@{s} — {d}%{s}", .{
            j.label, j.hc.label(), pct, state_txt,
        }) catch "job";
        const l = c.gtk_label_new(txt.ptr);
        c.gtk_label_set_xalign(@ptrCast(l), 0);
        c.gtk_widget_set_hexpand(l, 1);
        c.gtk_label_set_ellipsize(@ptrCast(l), c.PANGO_ELLIPSIZE_MIDDLE);
        c.gtk_box_append(@ptrCast(row), l);
        if (!j.terminal()) {
            if (j.state == .paused) {
                self.jobsButton(row, "media-playback-start-symbolic", .{
                    .allocator = self.allocator,
                    .view = self,
                    .hc = j.hc,
                    .job = j.job,
                    .kind = .resume_,
                });
            } else {
                self.jobsButton(row, "media-playback-pause-symbolic", .{
                    .allocator = self.allocator,
                    .view = self,
                    .hc = j.hc,
                    .job = j.job,
                    .kind = .pause,
                });
            }
            self.jobsButton(row, "process-stop-symbolic", .{
                .allocator = self.allocator,
                .view = self,
                .hc = j.hc,
                .job = j.job,
                .kind = .cancel,
            });
        } else {
            self.jobsButton(row, "window-close-symbolic", .{
                .allocator = self.allocator,
                .view = self,
                .hc = j.hc,
                .job = j.job,
                .kind = .dismiss,
            });
        }
        c.gtk_box_append(@ptrCast(self.jobs_box), row);
    }
}
