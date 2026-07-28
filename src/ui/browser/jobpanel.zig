//! The jobs and transfers panel: one compact row per job with an
//! expandable detail area, live speed/ETA, and per-job controls.
//!
//! Three sources feed one list: daemon jobs this view started, the
//! client-mediated transfers it drives itself, and the window-level
//! durable transfer service. Each row's measurement state (a
//! progress.Sampler plus its rate history) lives in a Meter that
//! OUTLIVES the widgets, so a rebuild never resets a rate.
//!
//! Rebuild vs refresh: renderJobs hashes the structural shape of the
//! list (identities, states, which controls apply). An unchanged shape
//! only rewrites label text and queues one sparkline redraw, so a
//! progress event costs no widget churn. A 500 ms tick samples the
//! same rows while anything is active -- that is what makes a stall
//! visible even though the daemon emits progress only every 4 MB.

const std = @import("std");
const c = @import("../../c.zig").c;
const progress = @import("../../filebrowser/progress.zig");

const ActiveTransfer = @import("types.zig").ActiveTransfer;
const BrowserView = @import("view.zig").BrowserView;
const HostConn = @import("types.zig").HostConn;
const copyZ = @import("../../filebrowser/format.zig").copyZN;
const fmtSize = @import("../../filebrowser/format.zig").fmtSize;
const jobs = @import("jobs.zig");

/// Panel refresh cadence while any row is active.
const TICK_MS: c.guint = 500;
/// Bounded panel height; the rows scroll inside it.
const MAX_PANEL_HEIGHT = 168;
const SPARK_W = 96;
const SPARK_H = 18;

const Kind = enum { daemon, xfer, durable, copy };

/// Stable identity of a panel row across rebuilds.
const Key = struct {
    kind: Kind,
    /// *HostConn for daemon jobs, *ActiveTransfer for client-mediated
    /// ones, unused for durable rows.
    ptr: usize = 0,
    job: u64 = 0,
    /// Durable ledger token (owned by the Meter, borrowed by a Row).
    token: []const u8 = "",

    fn eql(a: Key, b: Key) bool {
        if (a.kind != b.kind) return false;
        return switch (a.kind) {
            .durable => std.mem.eql(u8, a.token, b.token),
            .daemon => a.ptr == b.ptr and a.job == b.job,
            .xfer, .copy => a.ptr == b.ptr,
        };
    }

    fn hash(self: Key, h: *std.hash.Wyhash) void {
        h.update(std.mem.asBytes(&@intFromEnum(self.kind)));
        h.update(std.mem.asBytes(&self.ptr));
        h.update(std.mem.asBytes(&self.job));
        h.update(self.token);
    }
};

const RowState = enum { queued, running, paused, finished, failed, canceled };

/// Which controls this row's underlying job actually supports. A
/// control that cannot work is never rendered, rather than rendered
/// inert.
const Controls = struct {
    pause: bool = false,
    unpause: bool = false,
    cancel: bool = false,
    reorder: bool = false,
    dismiss: bool = false,
};

/// One row as collected from its source; arena-lived, rebuilt per
/// render.
const Row = struct {
    key: Key,
    label: []const u8,
    state: RowState,
    done: u64 = 0,
    total: u64 = 0,
    resumed_from: u64 = 0,
    src: []const u8 = "",
    dst: []const u8 = "",
    /// Null when the source cannot report the file in flight.
    current_file: ?[]const u8 = null,
    files_done: usize = 0,
    files_total: usize = 0,
    message: []const u8 = "",
    controls: Controls = .{},
    /// Daemon-job rows carry their HostConn, transfer rows their
    /// transfer, queued cross-host copies their queue item: the button
    /// handlers act on these.
    hc: ?*HostConn = null,
    transfer: ?*ActiveTransfer = null,
    copy: ?*jobs.CopyItem = null,

    fn active(self: Row) bool {
        return self.state == .queued or self.state == .running or self.state == .paused;
    }
};

/// The sparkline's own copy of the samples, owned by its drawing area
/// (freed by the widget's GDestroyNotify). The draw callback must
/// never reach into a Meter: a rebuild can drop meters while GTK still
/// holds the widget.
const Spark = struct {
    allocator: std.mem.Allocator,
    len: usize = 0,
    peak: u32 = 0,
    values: [progress.HISTORY_LEN]u32 = @splat(0),

    fn take(self: *Spark, sampler: *const progress.Sampler) void {
        const samples = sampler.samples();
        self.len = samples.len;
        @memcpy(self.values[0..samples.len], samples);
        self.peak = sampler.peak();
    }

    fn free(user: ?*anyopaque) callconv(.c) void {
        const self: *Spark = @ptrCast(@alignCast(user.?));
        self.allocator.destroy(self);
    }
};

/// Per-row measurement plus the widgets of the current build.
const Meter = struct {
    key: Key,
    /// Owned copy of a durable row's token (Key.token points at it).
    token: []u8 = &.{},
    sampler: progress.Sampler = .{},
    status: progress.Status = .{},
    expanded: bool = false,
    seen: bool = false,
    /// Sticky: the daemon reports it only on the terminal event.
    resumed_from: u64 = 0,
    head_label: ?*c.GtkLabel = null,
    detail_label: ?*c.GtkLabel = null,
    detail_box: ?*c.GtkWidget = null,
    spark: ?*c.GtkWidget = null,
    /// Borrowed: owned by the drawing area above.
    spark_data: ?*Spark = null,
    bar: ?*c.GtkProgressBar = null,

    fn forgetWidgets(self: *Meter) void {
        self.head_label = null;
        self.detail_label = null;
        self.detail_box = null;
        self.spark = null;
        self.spark_data = null;
        self.bar = null;
    }

    fn destroy(self: *Meter, allocator: std.mem.Allocator) void {
        if (self.token.len > 0) allocator.free(self.token);
        allocator.destroy(self);
    }
};

/// The panel's own state, owned by the BrowserView through one field.
pub const Panel = struct {
    meters: std.ArrayList(*Meter) = .empty,
    /// Structural shape of the last build; an equal shape refreshes.
    signature: u64 = 0,
    built: bool = false,
    tick: c.guint = 0,
    /// Guards the tick source against being removed from inside its
    /// own dispatch.
    in_tick: bool = false,
    rows_box: ?*c.GtkWidget = null,
    summary: ?*c.GtkLabel = null,

    pub fn deinit(self: *Panel, allocator: std.mem.Allocator) void {
        if (self.tick != 0) {
            _ = c.g_source_remove(self.tick);
            self.tick = 0;
        }
        for (self.meters.items) |m| m.destroy(allocator);
        self.meters.deinit(allocator);
    }

    fn find(self: *Panel, key: Key) ?*Meter {
        for (self.meters.items) |m| {
            if (m.key.eql(key)) return m;
        }
        return null;
    }
};

const nowMs = @import("../../util/clock.zig").nowMs;

// ── row collection ──────────────────────────────────────────────

fn hostQualified(arena: std.mem.Allocator, host: []const u8, path: []const u8) []const u8 {
    if (host.len == 0) return path;
    return std.fmt.allocPrint(arena, "{s}:{s}", .{ host, path }) catch path;
}

fn durableRows(self: *BrowserView, arena: std.mem.Allocator, out: *std.ArrayList(Row)) void {
    const service = self.transfer_service orelse return;
    const rows = service.rows(arena, @ptrCast(self)) catch return;
    for (rows) |d| {
        const terminal = d.state == .done or d.state == .failed or d.state == .canceled;
        const state: RowState = switch (d.state) {
            .queued, .submitting, .waiting_retry => if (d.paused) .paused else .queued,
            .running => if (d.paused) .paused else .running,
            .done => .finished,
            .failed => .failed,
            .canceled => .canceled,
        };
        const verb = if (d.kind == .upload) "sync back" else "download";
        out.append(arena, .{
            .key = .{ .kind = .durable, .token = d.token },
            .label = std.fmt.allocPrint(arena, "{s} {s}", .{ verb, d.label }) catch d.label,
            .state = state,
            .done = d.done,
            .total = d.total,
            .resumed_from = d.resumed_from,
            .src = hostQualified(arena, d.src_host, d.src_path),
            .dst = hostQualified(arena, d.dst_host, d.dst_path),
            .message = d.message,
            .controls = .{
                .pause = !terminal and !d.paused,
                .unpause = !terminal and d.paused,
                .cancel = !terminal,
                // moveQueued only reorders queued intents.
                .reorder = d.state == .queued,
                .dismiss = terminal,
            },
        }) catch return;
    }
}

fn transferRows(self: *BrowserView, arena: std.mem.Allocator, out: *std.ArrayList(Row)) void {
    for (self.transfers.items) |t| {
        const p = t.x.progress();
        const counts = t.x.fileCounts();
        const terminal = t.x.isTerminal();
        const state: RowState = if (terminal) switch (t.x.state) {
            .done => .finished,
            .failed => .failed,
            else => .canceled,
        } else if (t.paused)
            .paused
        else if (!t.started)
            .queued
        else
            .running;
        out.append(arena, .{
            .key = .{ .kind = .xfer, .ptr = @intFromPtr(t) },
            .label = t.label,
            .state = state,
            .done = p.done,
            .total = p.total,
            .resumed_from = t.x.resumed_bytes,
            .src = hostQualified(arena, t.src_hc.host orelse "", t.x.src_root),
            .dst = hostQualified(arena, t.dst_hc.host orelse "", t.x.dst_root),
            .current_file = t.x.currentFile(),
            .files_done = counts.done,
            .files_total = counts.total,
            .message = if (state == .failed) t.x.errMsg() else "",
            // A terminal one is reaped rather than dismissed by hand.
            // Pause stops the pumping at the next chunk boundary; the
            // staged partial is the checkpoint it resumes from.
            .controls = .{
                .pause = !terminal and !t.paused,
                .unpause = !terminal and t.paused,
                .cancel = !terminal,
                .reorder = !t.started and !t.paused,
            },
            .transfer = t,
        }) catch return;
    }
}

fn daemonRows(self: *BrowserView, arena: std.mem.Allocator, out: *std.ArrayList(Row)) void {
    for (self.jobs.items) |j| {
        const state: RowState = switch (j.state) {
            .running => .running,
            .paused => .paused,
            .finished => .finished,
            .failed => .failed,
            .canceled => .canceled,
        };
        out.append(arena, .{
            .key = .{ .kind = .daemon, .ptr = @intFromPtr(j.hc), .job = j.job },
            .label = std.fmt.allocPrint(arena, "{s} on {s}", .{ j.label, j.hc.label() }) catch j.label,
            .state = state,
            .done = j.done,
            .total = j.total,
            .resumed_from = j.resumed_from,
            .src = hostQualified(arena, j.hc.host orelse "", j.paths.srcPath()),
            .dst = hostQualified(arena, j.hc.host orelse "", j.paths.dstPath()),
            .current_file = if (j.currentFile().len > 0) j.currentFile() else null,
            .files_done = @intCast(j.files_done),
            .files_total = @intCast(j.files_total),
            .controls = .{
                .pause = !j.terminal() and j.state != .paused,
                .unpause = j.state == .paused,
                .cancel = !j.terminal(),
                .dismiss = j.terminal(),
            },
            .hc = j.hc,
        }) catch return;
    }
}

/// Cross-host copies the queue policy has not admitted yet. They have
/// no daemon job, hence no bytes and no controls beyond order/cancel.
fn copyQueueRows(self: *BrowserView, arena: std.mem.Allocator, out: *std.ArrayList(Row)) void {
    for (self.copy_queue.items.items) |item| {
        out.append(arena, .{
            .key = .{ .kind = .copy, .ptr = @intFromPtr(item) },
            .label = item.label,
            .state = .queued,
            .src = hostQualified(arena, item.src_hc.host orelse "", item.src_path),
            .dst = hostQualified(arena, item.dst_hc.host orelse "", item.dst_path),
            .message = "waiting for the destination to be free",
            .controls = .{ .cancel = true, .reorder = true },
            .copy = item,
        }) catch return;
    }
}

fn collectRows(self: *BrowserView, arena: std.mem.Allocator) []Row {
    var rows: std.ArrayList(Row) = .empty;
    durableRows(self, arena, &rows);
    transferRows(self, arena, &rows);
    daemonRows(self, arena, &rows);
    copyQueueRows(self, arena, &rows);
    return rows.items;
}

/// Everything a rebuild depends on: which rows exist, in what order,
/// in what state, with which controls, and which are expanded. Byte
/// counts deliberately stay out -- they only rewrite text.
fn signature(rows: []const Row, panel: *Panel) u64 {
    var h = std.hash.Wyhash.init(0x10b5);
    for (rows) |r| {
        r.key.hash(&h);
        h.update(std.mem.asBytes(&@intFromEnum(r.state)));
        h.update(std.mem.asBytes(&r.controls));
        h.update(r.label);
        const expanded = if (panel.find(r.key)) |m| m.expanded else false;
        h.update(std.mem.asBytes(&expanded));
    }
    return h.final();
}

// ── measurement ─────────────────────────────────────────────────

fn syncMeters(self: *BrowserView, rows: []const Row) void {
    const panel = &self.jobs_panel;
    for (panel.meters.items) |m| m.seen = false;
    const now = nowMs();
    for (rows) |r| {
        const meter = panel.find(r.key) orelse blk: {
            const m = self.allocator.create(Meter) catch continue;
            m.* = .{ .key = r.key };
            if (r.key.kind == .durable) {
                m.token = self.allocator.dupe(u8, r.key.token) catch {
                    self.allocator.destroy(m);
                    continue;
                };
                m.key.token = m.token;
            }
            panel.meters.append(self.allocator, m) catch {
                m.destroy(self.allocator);
                continue;
            };
            break :blk m;
        };
        meter.seen = true;
        if (r.resumed_from > 0) meter.resumed_from = r.resumed_from;
        if (r.state == .running) {
            meter.sampler.observe(now, r.done);
            meter.status = meter.sampler.status(now, r.done, r.total);
        } else {
            // Queued, paused or finished: time spent not running is not
            // a stall, and a rate that is not being achieved right now
            // must not be shown as if it were.
            meter.sampler.idle(now);
            meter.status = .{};
        }
    }
}

fn dropUnseenMeters(self: *BrowserView) void {
    const panel = &self.jobs_panel;
    var i: usize = 0;
    while (i < panel.meters.items.len) {
        const m = panel.meters.items[i];
        if (m.seen) {
            i += 1;
            continue;
        }
        _ = panel.meters.orderedRemove(i);
        m.destroy(self.allocator);
    }
}

// ── text ────────────────────────────────────────────────────────

fn stateWord(state: RowState, stalled: bool) []const u8 {
    return switch (state) {
        .queued => "queued",
        .running => if (stalled) "stalled" else "",
        .paused => "paused",
        .finished => "done",
        .failed => "failed",
        .canceled => "canceled",
    };
}

fn headText(buf: []u8, row: Row, meter: *const Meter) []const u8 {
    var done_buf: [48:0]u8 = undefined;
    var total_buf: [48:0]u8 = undefined;
    var rate_buf: [32]u8 = undefined;
    var eta_buf: [32]u8 = undefined;
    var w = std.Io.Writer.fixed(buf);
    w.print("{s}", .{row.label}) catch return w.buffered();
    const word = stateWord(row.state, meter.status.stalled);
    if (word.len > 0) w.print(" [{s}]", .{word}) catch {};
    if (row.total > 0) {
        const pct: u64 = @min(@as(u64, 100), row.done * 100 / row.total);
        w.print(" {d}% ({s} of {s})", .{ pct, fmtSize(&done_buf, row.done), fmtSize(&total_buf, row.total) }) catch {};
    } else if (row.done > 0) {
        w.print(" {s}", .{fmtSize(&done_buf, row.done)}) catch {};
    }
    if (meter.status.rate_bps) |bps| {
        w.print(" - {s}", .{progress.formatRate(&rate_buf, bps)}) catch {};
    }
    if (meter.status.eta_s) |eta| {
        w.print(" - {s} left", .{progress.formatEta(&eta_buf, eta)}) catch {};
    }
    if (row.message.len > 0 and (row.state == .failed or row.state == .queued))
        w.print(" - {s}", .{row.message}) catch {};
    return w.buffered();
}

fn detailText(buf: []u8, row: Row, meter: *const Meter) []const u8 {
    var a: [48:0]u8 = undefined;
    var b: [48:0]u8 = undefined;
    var rate_buf: [32]u8 = undefined;
    // Second scratch for a line that formats two rates (or a rate and
    // an ETA) at once.
    var alt_buf: [32]u8 = undefined;
    var w = std.Io.Writer.fixed(buf);
    if (row.src.len > 0) w.print("source: {s}\n", .{row.src}) catch {};
    if (row.dst.len > 0) w.print("destination: {s}\n", .{row.dst}) catch {};
    if (row.total > 0) {
        w.print("bytes: {s} of {s}", .{ fmtSize(&a, row.done), fmtSize(&b, row.total) }) catch {};
    } else {
        w.print("bytes: {s} (total unknown)", .{fmtSize(&a, row.done)}) catch {};
    }
    if (meter.resumed_from > 0) w.print(", resumed from {s}", .{fmtSize(&b, meter.resumed_from)}) catch {};
    w.writeByte('\n') catch {};
    if (row.files_total > 0)
        w.print("files: {d} of {d}\n", .{ row.files_done, row.files_total }) catch {};
    if (meter.status.stalled) {
        w.print("rate: stalled (no progress for {d}s)\n", .{@divTrunc(progress.STALL_MS, 1000)}) catch {};
    } else if (meter.status.rate_bps) |bps| {
        w.print("rate: {s}", .{progress.formatRate(&rate_buf, bps)}) catch {};
        if (meter.sampler.peak() > 0)
            w.print(" (peak {s})", .{progress.formatRate(&alt_buf, meter.sampler.peak())}) catch {};
        w.writeByte('\n') catch {};
    } else if (row.state == .running) {
        w.print("rate: measuring\n", .{}) catch {};
    } else if (meter.sampler.average(row.done)) |avg| {
        // Not running: the live rate would be a fiction, but what this
        // run actually achieved is a fact worth keeping.
        w.print("rate: averaged {s}\n", .{progress.formatRate(&rate_buf, avg)}) catch {};
    }
    if (meter.status.eta_s) |eta| {
        w.print("ETA: {s}\n", .{progress.formatEta(&alt_buf, eta)}) catch {};
    } else if (row.total == 0 and row.state == .running) {
        // Honest: no total means no estimate, not a made-up one.
        w.print("ETA: unknown (the job reports no total)\n", .{}) catch {};
    }
    if (row.current_file) |file| {
        w.print("current file: {s}\n", .{file}) catch {};
    } else if (row.state == .running) {
        // Single-step jobs (rename, trash, hash) have no "current
        // file" distinct from the source they already show.
        w.print("current file: this job works on one item\n", .{}) catch {};
    }
    if (row.message.len > 0) w.print("message: {s}\n", .{row.message}) catch {};
    const text = w.buffered();
    return if (text.len > 0 and text[text.len - 1] == '\n') text[0 .. text.len - 1] else text;
}

fn summaryText(buf: []u8, rows: []const Row, panel: *Panel) []const u8 {
    var running: usize = 0;
    var queued: usize = 0;
    var total_rate: u64 = 0;
    for (rows) |r| {
        switch (r.state) {
            .running => running += 1,
            .queued, .paused => queued += 1,
            else => {},
        }
        const meter = panel.find(r.key) orelse continue;
        if (meter.status.rate_bps) |bps| total_rate += bps;
    }
    var rate_buf: [32]u8 = undefined;
    var w = std.Io.Writer.fixed(buf);
    w.print("{d} running, {d} waiting", .{ running, queued }) catch {};
    if (total_rate > 0) w.print(" - {s} total", .{progress.formatRate(&rate_buf, total_rate)}) catch {};
    return w.buffered();
}

// ── widgets ─────────────────────────────────────────────────────

/// Heap context for one jobs-panel button, freed with the button.
/// It carries the row's identity, so the same three fields locate the
/// target job and its meter.
pub const JobBtnCtx = struct {
    allocator: std.mem.Allocator,
    view: *BrowserView,
    /// Daemon job target (hc+job).
    hc: ?*HostConn = null,
    job: u64 = 0,
    /// Client-mediated transfer target.
    transfer: ?*ActiveTransfer = null,
    /// Queued cross-host copy target.
    copy: ?*jobs.CopyItem = null,
    /// Durable ledger token (owned).
    service_token: ?[]u8 = null,
    kind: enum { pause, resume_, cancel, dismiss, move_up, move_down, expand },

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
    if (ctx.kind == .expand) {
        // Expansion is view state, kept on the meter so it survives the
        // rebuild that repaints the expander icon.
        const meter = meterOf(ctx, self) orelse return;
        meter.expanded = !meter.expanded;
        self.renderJobs();
        return;
    }
    if (ctx.service_token) |token| {
        const service = self.transfer_service orelse return;
        switch (ctx.kind) {
            .move_up => service.moveQueued(token, -1),
            .move_down => service.moveQueued(token, 1),
            // A terminal durable row is dropped by the same call that
            // cancels a live one: both end the intent.
            .cancel, .dismiss => service.cancel(token),
            .pause => service.setPaused(token, true),
            .resume_ => service.setPaused(token, false),
            else => {},
        }
        self.renderJobs();
        return;
    }
    if (ctx.transfer) |t| {
        switch (ctx.kind) {
            .move_up => self.moveTransfer(t, -1),
            .move_down => self.moveTransfer(t, 1),
            .cancel => {
                t.x.cancel();
                self.reapTransfers();
            },
            .pause => self.setTransferPaused(t, true),
            .resume_ => self.setTransferPaused(t, false),
            else => {},
        }
        self.renderJobs();
        return;
    }
    if (ctx.copy) |item| {
        switch (ctx.kind) {
            .move_up => self.moveQueuedCopy(item, -1),
            .move_down => self.moveQueuedCopy(item, 1),
            .cancel => self.cancelQueuedCopy(item),
            else => {},
        }
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
        .move_up, .move_down, .expand => {},
    }
    self.renderJobs();
}

/// The meter a button belongs to, from the identity it carries.
fn meterOf(ctx: *JobBtnCtx, self: *BrowserView) ?*Meter {
    if (ctx.service_token) |token|
        return self.jobs_panel.find(.{ .kind = .durable, .token = token });
    if (ctx.transfer) |t|
        return self.jobs_panel.find(.{ .kind = .xfer, .ptr = @intFromPtr(t) });
    if (ctx.copy) |item|
        return self.jobs_panel.find(.{ .kind = .copy, .ptr = @intFromPtr(item) });
    const hc = ctx.hc orelse return null;
    return self.jobs_panel.find(.{ .kind = .daemon, .ptr = @intFromPtr(hc), .job = ctx.job });
}

fn identityCtx(self: *BrowserView, row: Row, kind: @FieldType(JobBtnCtx, "kind")) JobBtnCtx {
    return .{
        .allocator = self.allocator,
        .view = self,
        .hc = row.hc,
        .job = row.key.job,
        .transfer = row.transfer,
        .copy = row.copy,
        .service_token = if (row.key.kind == .durable) (self.allocator.dupe(u8, row.key.token) catch null) else null,
        .kind = kind,
    };
}

fn drawSpark(_: ?*c.GtkDrawingArea, cr: ?*c.cairo_t, width: c_int, height: c_int, user: c.gpointer) callconv(.c) void {
    const spark: *Spark = @ptrCast(@alignCast(user.?));
    const samples = spark.values[0..spark.len];
    const peak = spark.peak;
    const w: f64 = @floatFromInt(width);
    const h: f64 = @floatFromInt(height);
    c.cairo_set_line_width(cr, 1.0);
    c.cairo_set_source_rgba(cr, 0.5, 0.5, 0.5, 0.25);
    c.cairo_rectangle(cr, 0.5, 0.5, w - 1, h - 1);
    c.cairo_stroke(cr);
    if (samples.len < 2 or peak == 0) return;
    const step = w / @as(f64, @floatFromInt(progress.HISTORY_LEN - 1));
    const top: f64 = @floatFromInt(peak);
    c.cairo_set_source_rgba(cr, 0.30, 0.65, 0.95, 0.9);
    for (samples, 0..) |value, i| {
        const x = @as(f64, @floatFromInt(i)) * step;
        const y = h - 1 - (@as(f64, @floatFromInt(value)) / top) * (h - 2);
        if (i == 0) c.cairo_move_to(cr, x, y) else c.cairo_line_to(cr, x, y);
    }
    c.cairo_stroke(cr);
}

fn buildRow(self: *BrowserView, parent: *c.GtkWidget, row: Row, meter: *Meter) void {
    const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
    c.gtk_widget_set_margin_start(box, 6);
    c.gtk_widget_set_margin_end(box, 6);

    const head = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6);
    jobsButton(self, head, if (meter.expanded) "pan-down-symbolic" else "pan-end-symbolic", identityCtx(self, row, .expand));

    var text_buf: [512]u8 = undefined;
    var zbuf: [512:0]u8 = undefined;
    const head_text = headText(&text_buf, row, meter);
    const label = c.gtk_label_new(copyZ(&zbuf, head_text));
    c.gtk_label_set_xalign(@ptrCast(label), 0);
    c.gtk_widget_set_hexpand(label, 1);
    c.gtk_label_set_ellipsize(@ptrCast(label), c.PANGO_ELLIPSIZE_MIDDLE);
    c.gtk_box_append(@ptrCast(head), label);

    const bar = c.gtk_progress_bar_new();
    c.gtk_widget_set_size_request(bar, 90, -1);
    c.gtk_widget_set_valign(bar, c.GTK_ALIGN_CENTER);
    c.gtk_progress_bar_set_fraction(@ptrCast(bar), fraction(row));
    c.gtk_box_append(@ptrCast(head), bar);

    if (row.controls.reorder) {
        jobsButton(self, head, "go-up-symbolic", identityCtx(self, row, .move_up));
        jobsButton(self, head, "go-down-symbolic", identityCtx(self, row, .move_down));
    }
    if (row.controls.unpause)
        jobsButton(self, head, "media-playback-start-symbolic", identityCtx(self, row, .resume_));
    if (row.controls.pause)
        jobsButton(self, head, "media-playback-pause-symbolic", identityCtx(self, row, .pause));
    if (row.controls.cancel)
        jobsButton(self, head, "process-stop-symbolic", identityCtx(self, row, .cancel));
    if (row.controls.dismiss)
        jobsButton(self, head, "window-close-symbolic", identityCtx(self, row, .dismiss));
    c.gtk_box_append(@ptrCast(box), head);

    const detail = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8);
    c.gtk_widget_set_margin_start(detail, 24);
    c.gtk_widget_set_margin_bottom(detail, 4);
    var detail_buf: [2048]u8 = undefined;
    var detail_z: [2048:0]u8 = undefined;
    const dlabel = c.gtk_label_new(copyZ(&detail_z, detailText(&detail_buf, row, meter)));
    c.gtk_label_set_xalign(@ptrCast(dlabel), 0);
    c.gtk_label_set_yalign(@ptrCast(dlabel), 0);
    c.gtk_widget_set_hexpand(dlabel, 1);
    c.gtk_label_set_wrap(@ptrCast(dlabel), 1);
    c.gtk_label_set_selectable(@ptrCast(dlabel), 1);
    c.gtk_widget_add_css_class(dlabel, "dim-label");
    c.gtk_box_append(@ptrCast(detail), dlabel);

    const spark = c.gtk_drawing_area_new();
    c.gtk_widget_set_size_request(spark, SPARK_W, SPARK_H);
    c.gtk_widget_set_valign(spark, c.GTK_ALIGN_START);
    c.gtk_widget_set_tooltip_text(spark, "Recent throughput");
    const spark_data = self.allocator.create(Spark) catch null;
    if (spark_data) |data| {
        data.* = .{ .allocator = self.allocator };
        data.take(&meter.sampler);
        c.gtk_drawing_area_set_draw_func(@ptrCast(spark), @ptrCast(&drawSpark), @ptrCast(data), @ptrCast(&Spark.free));
    }
    c.gtk_box_append(@ptrCast(detail), spark);

    c.gtk_widget_set_visible(detail, if (meter.expanded) 1 else 0);
    c.gtk_box_append(@ptrCast(box), detail);
    c.gtk_box_append(@ptrCast(parent), box);

    meter.head_label = @ptrCast(@alignCast(label));
    meter.detail_label = @ptrCast(@alignCast(dlabel));
    meter.detail_box = detail;
    meter.spark = spark;
    meter.spark_data = spark_data;
    meter.bar = @ptrCast(@alignCast(bar));
}

fn fraction(row: Row) f64 {
    if (row.state == .finished) return 1.0;
    if (row.total == 0) return 0.0;
    const f = @as(f64, @floatFromInt(row.done)) / @as(f64, @floatFromInt(row.total));
    return @min(1.0, @max(0.0, f));
}

fn rebuild(self: *BrowserView, rows: []const Row) void {
    const panel = &self.jobs_panel;
    while (c.gtk_widget_get_first_child(self.jobs_box)) |child| {
        c.gtk_box_remove(@ptrCast(self.jobs_box), child);
    }
    // Widgets are gone: no meter may keep a pointer into them, and the
    // rows that vanished can now release their measurement state.
    for (panel.meters.items) |m| m.forgetWidgets();
    panel.rows_box = null;
    panel.summary = null;
    dropUnseenMeters(self);
    if (rows.len == 0) {
        panel.built = false;
        return;
    }

    var sbuf: [128]u8 = undefined;
    var sz: [512:0]u8 = undefined;
    const summary = c.gtk_label_new(copyZ(&sz, summaryText(&sbuf, rows, panel)));
    c.gtk_label_set_xalign(@ptrCast(summary), 0);
    c.gtk_widget_add_css_class(summary, "dim-label");
    c.gtk_widget_set_margin_start(summary, 6);
    c.gtk_widget_set_visible(summary, if (rows.len > 1) 1 else 0);
    c.gtk_box_append(@ptrCast(self.jobs_box), summary);
    panel.summary = @ptrCast(@alignCast(summary));

    // Many concurrent jobs must not push the listing off the pane: the
    // rows scroll inside a bounded box instead.
    const scroller = c.gtk_scrolled_window_new();
    c.gtk_scrolled_window_set_policy(@ptrCast(scroller), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
    c.gtk_scrolled_window_set_propagate_natural_height(@ptrCast(scroller), 1);
    c.gtk_scrolled_window_set_max_content_height(@ptrCast(scroller), MAX_PANEL_HEIGHT);
    const rows_box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 2);
    for (rows) |r| {
        const meter = panel.find(r.key) orelse continue;
        buildRow(self, rows_box, r, meter);
    }
    c.gtk_scrolled_window_set_child(@ptrCast(scroller), rows_box);
    c.gtk_box_append(@ptrCast(self.jobs_box), scroller);
    panel.rows_box = rows_box;
    panel.built = true;
}

fn refresh(self: *BrowserView, rows: []const Row) void {
    const panel = &self.jobs_panel;
    for (rows) |r| {
        const meter = panel.find(r.key) orelse continue;
        var text_buf: [512]u8 = undefined;
        var zbuf: [512:0]u8 = undefined;
        if (meter.head_label) |label|
            c.gtk_label_set_text(label, copyZ(&zbuf, headText(&text_buf, r, meter)));
        if (meter.bar) |bar| c.gtk_progress_bar_set_fraction(bar, fraction(r));
        if (meter.expanded) {
            var detail_buf: [2048]u8 = undefined;
            var detail_z: [2048:0]u8 = undefined;
            if (meter.detail_label) |label|
                c.gtk_label_set_text(label, copyZ(&detail_z, detailText(&detail_buf, r, meter)));
            if (meter.spark_data) |data| data.take(&meter.sampler);
            if (meter.spark) |spark| c.gtk_widget_queue_draw(spark);
        }
    }
    if (panel.summary) |summary| {
        var sbuf: [128]u8 = undefined;
        var sz: [512:0]u8 = undefined;
        c.gtk_label_set_text(summary, copyZ(&sz, summaryText(&sbuf, rows, panel)));
    }
}

/// Run the sampling tick while anything can still move. Rows only
/// change on events, but a rate and a stall are properties of TIME:
/// without this, a job whose daemon went quiet would keep showing the
/// rate it had at its last 4 MB boundary.
fn armTick(self: *BrowserView, rows: []const Row) void {
    const panel = &self.jobs_panel;
    var live = false;
    for (rows) |r| {
        if (r.active()) live = true;
    }
    if (live and panel.tick == 0) {
        panel.tick = c.g_timeout_add(TICK_MS, @ptrCast(&onTick), @ptrCast(self));
    } else if (!live and panel.tick != 0) {
        // Inside its own dispatch the source is torn down by returning
        // G_SOURCE_REMOVE; removing it by id as well is not needed.
        if (!panel.in_tick) _ = c.g_source_remove(panel.tick);
        panel.tick = 0;
    }
}

fn onTick(user: ?*anyopaque) callconv(.c) c.gboolean {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    self.jobs_panel.in_tick = true;
    self.renderJobs();
    self.jobs_panel.in_tick = false;
    return if (self.jobs_panel.tick != 0) 1 else 0;
}

/// Rebuild or refresh the jobs/transfers panel (hidden when empty).
pub fn renderJobs(self: *BrowserView) void {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const rows = collectRows(self, arena.allocator());
    c.gtk_widget_set_visible(self.jobs_box, if (rows.len > 0) 1 else 0);
    syncMeters(self, rows);
    const sig = signature(rows, &self.jobs_panel);
    if (self.jobs_panel.built and sig == self.jobs_panel.signature) {
        refresh(self, rows);
    } else {
        rebuild(self, rows);
        self.jobs_panel.signature = sig;
    }
    armTick(self, rows);
}
