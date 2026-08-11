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
const classicmenu = @import("classicmenu.zig");
const cssutil = @import("../cssutil.zig");
const copyZ = @import("../../filebrowser/format.zig").copyZN;
const fmtSize = @import("../../filebrowser/format.zig").fmtSize;
const jobs = @import("jobs.zig");

/// Panel refresh cadence while any row is active.
const TICK_MS: c.guint = 500;
/// Bounded Transfer Center height; the cards scroll inside it.
const CENTER_MAX_HEIGHT = 340;
const SPARK_W = 110;
const SPARK_H = 16;

const Kind = enum { batch, pending, conflict, probe, daemon, xfer, durable, copy, deferred };

/// Stable identity of a panel row across rebuilds.
const Key = struct {
    kind: Kind,
    /// *HostConn for daemon jobs, *ActiveTransfer for client-mediated
    /// ones, unused for durable rows.
    ptr: usize = 0,
    job: u64 = 0,
    /// Durable/retry token (owned by the Meter, borrowed by a Row).
    token: []const u8 = "",

    fn eql(a: Key, b: Key) bool {
        if (a.kind != b.kind) return false;
        return switch (a.kind) {
            .batch => a.job == b.job,
            .durable => std.mem.eql(u8, a.token, b.token),
            .daemon => if (a.token.len > 0 or b.token.len > 0)
                a.token.len > 0 and b.token.len > 0 and std.mem.eql(u8, a.token, b.token)
            else
                a.ptr == b.ptr and a.job == b.job,
            .pending, .conflict, .probe, .xfer, .copy, .deferred => a.ptr == b.ptr,
        };
    }

    fn hash(self: Key, h: *std.hash.Wyhash) void {
        h.update(std.mem.asBytes(&@intFromEnum(self.kind)));
        if ((self.kind == .daemon or self.kind == .durable) and self.token.len > 0) {
            h.update(self.token);
        } else {
            h.update(std.mem.asBytes(&self.ptr));
            h.update(std.mem.asBytes(&self.job));
        }
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
    /// Only a cross-host copy offers it: the staged partial on the
    /// destination is what makes a retry a RESUME rather than a
    /// three-gigabyte transfer starting over.
    retry: bool = false,
};

/// One row as collected from its source; arena-lived, rebuilt per
/// render.
const Row = struct {
    key: Key,
    label: []const u8,
    /// Name-first presentation: the thing being moved leads the card;
    /// the destination is host + parent directory, dimmed. The full
    /// paths stay in `src`/`dst` for tooltips and the context menu.
    name: []const u8 = "",
    dest_host: []const u8 = "",
    dest_dir: []const u8 = "",
    state: RowState,
    done: u64 = 0,
    total: u64 = 0,
    resumed_from: u64 = 0,
    /// Batch fallback fraction when byte totals are only partially
    /// known: finished members plus the running members' own byte
    /// fractions, over the member count. 0 = unset.
    frac_hint: f64 = 0,
    src: []const u8 = "",
    dst: []const u8 = "",
    /// Null when the source cannot report the file in flight.
    current_file: ?[]const u8 = null,
    files_done: usize = 0,
    files_total: usize = 0,
    message: []const u8 = "",
    controls: Controls = .{},
    /// Shared presentation identity of one paste/drop command.
    batch_id: u64 = 0,
    batch_total: usize = 0,
    /// Durable item identity used to collapse predecessor/successor
    /// rows while an automatic retry changes queue representation.
    batch_item: []const u8 = "",
    move: bool = false,
    /// Expanded batch members are indented under their synthetic row.
    batch_child: bool = false,
    /// Daemon-job rows carry their HostConn, transfer rows their
    /// transfer, queued cross-host copies their queue item: the button
    /// handlers act on these.
    hc: ?*HostConn = null,
    transfer: ?*ActiveTransfer = null,
    copy: ?*jobs.CopyItem = null,
    deferred: ?*jobs.DeferredTransfer = null,

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

/// Segment-aware progress bar model, owned by its drawing area (freed
/// by the widget's GDestroyNotify — same lifetime rule as Spark).
const BarData = struct {
    allocator: std.mem.Allocator,
    fraction: f64 = 0,
    /// Leading portion that was RESUMED rather than transferred this
    /// run, drawn dimmer: a continued transfer visibly starts where it
    /// left off instead of lying with 0%.
    resumed: f64 = 0,
    kind: PaintKind = .accent,

    fn free(user: ?*anyopaque) callconv(.c) void {
        const self: *BarData = @ptrCast(@alignCast(user.?));
        self.allocator.destroy(self);
    }
};

/// Aggregate progress ring on the ambient strip, same ownership rule.
const RingData = struct {
    allocator: std.mem.Allocator,
    fraction: f64 = 0,
    indeterminate: bool = false,
    kind: PaintKind = .accent,

    fn free(user: ?*anyopaque) callconv(.c) void {
        const self: *RingData = @ptrCast(@alignCast(user.?));
        self.allocator.destroy(self);
    }
};

const PaintKind = enum(u8) { accent, ok, err, warn, dim };

fn paintColor(kind: PaintKind, cr: ?*c.cairo_t, alpha: f64) void {
    switch (kind) {
        .accent => c.cairo_set_source_rgba(cr, 0.22, 0.53, 0.90, alpha),
        .ok => c.cairo_set_source_rgba(cr, 0.20, 0.75, 0.50, alpha),
        .err => c.cairo_set_source_rgba(cr, 0.94, 0.38, 0.33, alpha),
        .warn => c.cairo_set_source_rgba(cr, 0.90, 0.66, 0.10, alpha),
        .dim => c.cairo_set_source_rgba(cr, 0.55, 0.55, 0.60, alpha),
    }
}

/// Per-row measurement plus the widgets of the current build.
const Meter = struct {
    key: Key,
    /// Owned copy of a token-bearing row's token (Key.token points at it).
    token: []u8 = &.{},
    sampler: progress.Sampler = .{},
    status: progress.Status = .{},
    expanded: bool = false,
    seen: bool = false,
    /// Presentation order, assigned once at first sight: a card keeps
    /// its position for its lifetime; state changes never reshuffle
    /// the list under the cursor.
    order: u64 = 0,
    /// First seen running / first seen settled — the finished card's
    /// honest "1.1 GB in 3:12".
    started_ms: i64 = 0,
    settled_ms: i64 = 0,
    /// Sticky: the daemon reports it only on the terminal event.
    resumed_from: u64 = 0,
    state_icon: ?*c.GtkWidget = null,
    name_label: ?*c.GtkLabel = null,
    dest_label: ?*c.GtkLabel = null,
    stats_label: ?*c.GtkLabel = null,
    badge_label: ?*c.GtkLabel = null,
    chip_resumed: ?*c.GtkWidget = null,
    cur_label: ?*c.GtkLabel = null,
    msg_label: ?*c.GtkLabel = null,
    bar: ?*c.GtkWidget = null,
    /// Borrowed: owned by the drawing areas below.
    bar_data: ?*BarData = null,
    spark: ?*c.GtkWidget = null,
    spark_data: ?*Spark = null,

    fn forgetWidgets(self: *Meter) void {
        self.state_icon = null;
        self.name_label = null;
        self.dest_label = null;
        self.stats_label = null;
        self.badge_label = null;
        self.chip_resumed = null;
        self.cur_label = null;
        self.msg_label = null;
        self.bar = null;
        self.bar_data = null;
        self.spark = null;
        self.spark_data = null;
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
    /// Tier 2 visible? Toggled by the strip's Details button, a click
    /// on the strip, or Ctrl+Shift+J. Session-local.
    center_open: bool = false,
    /// Monotonic source for Meter.order.
    next_order: u64 = 1,
    rows_box: ?*c.GtkWidget = null,
    summary: ?*c.GtkLabel = null,
    strip_label: ?*c.GtkLabel = null,
    strip_nums: ?*c.GtkLabel = null,
    strip_ring: ?*c.GtkWidget = null,
    /// Borrowed: owned by the ring drawing area.
    ring_data: ?*RingData = null,
    scroller: ?*c.GtkWidget = null,
    scroll_restore: c.guint = 0,
    scroll_state: ?ScrollState = null,

    pub fn deinit(self: *Panel, allocator: std.mem.Allocator) void {
        if (self.tick != 0) {
            _ = c.g_source_remove(self.tick);
            self.tick = 0;
        }
        if (self.scroll_restore != 0) {
            _ = c.g_source_remove(self.scroll_restore);
            self.scroll_restore = 0;
        }
        self.scroll_state = null;
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

/// Host string for display: the transport prefix is plumbing, not a
/// place ("ssh:mercer" reads worse than "mercer").
fn displayHost(host: []const u8) []const u8 {
    return @import("../../filebrowser/paths.zig").browserHost(host) orelse host;
}

/// The parent directory of a destination path, with a trailing slash
/// so it reads as a place rather than a file.
fn destDirOf(arena: std.mem.Allocator, path: []const u8) []const u8 {
    const dir = std.fs.path.dirname(path) orelse return path;
    if (dir.len <= 1) return "/";
    return std.fmt.allocPrint(arena, "{s}/", .{dir}) catch dir;
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
            .name = d.label,
            .dest_host = d.dst_host,
            .dest_dir = destDirOf(arena, d.dst_path),
            .state = state,
            .done = d.done,
            .total = d.total,
            .resumed_from = d.resumed_from,
            .src = hostQualified(arena, d.src_host, d.src_path),
            .dst = hostQualified(arena, d.dst_host, d.dst_path),
            .message = d.message,
            .batch_id = d.batch_id,
            .batch_total = @intCast(d.batch_total),
            .batch_item = d.token,
            .move = d.delete_src_after,
            .controls = .{
                .pause = !terminal and !d.paused,
                .unpause = !terminal and d.paused,
                .cancel = !terminal,
                // moveQueued only reorders queued intents.
                .reorder = d.state == .queued,
                .dismiss = terminal,
                .retry = d.mediated and d.state == .failed,
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
            .name = t.label,
            .dest_host = t.dst_hc.host orelse "",
            .dest_dir = destDirOf(arena, t.x.dst_root),
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
            .batch_id = t.batch_id,
            .batch_total = t.batch_total,
            .batch_item = t.token orelse "",
            .move = t.delete_src_after,
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
        const successor_active = jobs.copySuccessorActive(self, j);
        const state: RowState = switch (j.state) {
            .running => .running,
            .paused => .paused,
            .finished => .finished,
            .failed => .failed,
            .canceled => .canceled,
        };
        // The real transfer endpoints live on the retry record; the
        // HostConn is only the COORDINATOR, whose host string renders
        // a remote destination as a local-looking path.
        const dest_host = if (j.retry) |retry| retry.dst_hc.host orelse "" else j.hc.host orelse "";
        const dest_path = if (j.retry) |retry| retry.dst_path else j.paths.dstPath();
        out.append(arena, .{
            .key = .{
                .kind = .daemon,
                .ptr = @intFromPtr(j.hc),
                .job = j.job,
                .token = if (j.retry) |retry| retry.token else "",
            },
            .label = std.fmt.allocPrint(arena, "{s} on {s}", .{ j.label, j.hc.label() }) catch j.label,
            .name = j.label,
            .dest_host = dest_host,
            .dest_dir = destDirOf(arena, dest_path),
            .state = state,
            .done = j.done,
            .total = j.total,
            .resumed_from = j.resumed_from,
            .src = hostQualified(arena, j.hc.host orelse "", j.paths.srcPath()),
            .dst = hostQualified(arena, j.hc.host orelse "", j.paths.dstPath()),
            .current_file = if (j.currentFile().len > 0) j.currentFile() else null,
            .files_done = @intCast(j.files_done),
            .files_total = @intCast(j.files_total),
            .message = j.messageText(),
            .batch_id = j.batch_id,
            .batch_total = j.batch_total,
            .batch_item = if (j.retry) |retry| retry.token else "",
            .move = if (j.retry) |retry| retry.move else false,
            .controls = .{
                .pause = !j.terminal() and j.state != .paused,
                .unpause = j.state == .paused,
                .cancel = !j.terminal(),
                .dismiss = j.terminal() and !j.retry_scheduled and !successor_active,
                .retry = j.state == .failed and j.retry != null and !j.retry_scheduled and !successor_active,
            },
            .hc = j.hc,
        }) catch return;
    }
}

/// Batched start requests waiting for the daemon's job id. They are
/// hidden under the collapsed batch row, but keep its full count and
/// waiting state visible before the first reply arrives.
fn pendingBatchRows(self: *BrowserView, arena: std.mem.Allocator, out: *std.ArrayList(Row)) void {
    for (self.pending_jobs.items) |pending| {
        if (pending.batch_id == 0) continue;
        out.append(arena, .{
            .key = .{ .kind = .pending, .ptr = @intFromPtr(pending) },
            .label = pending.label,
            .name = pending.label,
            .dest_host = if (pending.retry) |retry| retry.dst_hc.host orelse "" else "",
            .dest_dir = destDirOf(arena, pending.paths.dstPath()),
            .state = .queued,
            .src = pending.paths.srcPath(),
            .dst = pending.paths.dstPath(),
            .batch_id = pending.batch_id,
            .batch_total = pending.batch_total,
            .batch_item = if (pending.retry) |retry| retry.token else "",
            .move = if (pending.retry) |retry| retry.move else false,
            .message = "waiting for the daemon to start the job",
        }) catch return;
    }
}

fn conflictRows(self: *BrowserView, arena: std.mem.Allocator, out: *std.ArrayList(Row)) void {
    for (self.conflicts.queue.items) |item| {
        if (item.batch_id == 0) continue;
        out.append(arena, .{
            .key = .{ .kind = .conflict, .ptr = @intFromPtr(item) },
            .label = std.fs.path.basename(item.src),
            .name = std.fs.path.basename(item.src),
            .dest_host = item.dst_hc.host orelse "",
            .dest_dir = destDirOf(arena, item.dst),
            .state = .queued,
            .src = hostQualified(arena, item.src_hc.host orelse "", item.src),
            .dst = hostQualified(arena, item.dst_hc.host orelse "", item.dst),
            .message = "waiting for a name-conflict decision",
            .batch_id = item.batch_id,
            .batch_total = item.batch_total,
            .move = item.cut,
        }) catch return;
    }
}

fn dropProbeRows(self: *BrowserView, arena: std.mem.Allocator, out: *std.ArrayList(Row)) void {
    for (self.drop_probes.items) |probe| {
        if (probe.batch_id == 0) continue;
        out.append(arena, .{
            .key = .{ .kind = .probe, .ptr = @intFromPtr(probe) },
            .label = std.fs.path.basename(probe.src),
            .name = std.fs.path.basename(probe.src),
            .dest_host = probe.dst_hc.host orelse "",
            .dest_dir = destDirOf(arena, probe.dst),
            .state = .queued,
            .src = hostQualified(arena, probe.src_hc.host orelse "", probe.src),
            .dst = hostQualified(arena, probe.dst_hc.host orelse "", probe.dst),
            .message = "checking for a name conflict",
            .batch_id = probe.batch_id,
            .batch_total = probe.batch_total,
            .move = probe.cut,
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
            .name = item.label,
            .dest_host = item.dst_hc.host orelse "",
            .dest_dir = destDirOf(arena, item.dst_path),
            .state = .queued,
            .src = hostQualified(arena, item.src_hc.host orelse "", item.src_path),
            .dst = hostQualified(arena, item.dst_hc.host orelse "", item.dst_path),
            .message = "waiting for the destination to be free",
            .batch_id = item.batch_id,
            .batch_total = item.batch_total,
            .batch_item = item.token,
            .move = item.move,
            .controls = .{ .cancel = true, .reorder = true },
            .copy = item,
        }) catch return;
    }
}

fn deferredRows(self: *BrowserView, arena: std.mem.Allocator, out: *std.ArrayList(Row)) void {
    for (self.deferred_transfers.items) |item| {
        const waiting = if (item.wait_for_coordinator)
            "waiting for a durable coordinator"
        else if (item.src_hc.state != .ready)
            "waiting for the source host"
        else
            "waiting for the destination host";
        out.append(arena, .{
            .key = .{ .kind = .deferred, .ptr = @intFromPtr(item) },
            .label = std.fmt.allocPrint(arena, "{s} -> {s}", .{ std.fs.path.basename(item.src_path), item.dst_hc.label() }) catch item.src_path,
            .name = std.fs.path.basename(item.src_path),
            .dest_host = item.dst_hc.host orelse "",
            .dest_dir = destDirOf(arena, item.dst_path),
            .state = .queued,
            .src = hostQualified(arena, item.src_hc.host orelse "", item.src_path),
            .dst = hostQualified(arena, item.dst_hc.host orelse "", item.dst_path),
            .message = waiting,
            .batch_id = item.batch_id,
            .batch_total = item.batch_total,
            .batch_item = item.token orelse "",
            .move = item.delete_src_after,
            .controls = .{ .cancel = true },
            .deferred = item,
        }) catch return;
    }
}

fn collectRows(self: *BrowserView, arena: std.mem.Allocator) []Row {
    var rows: std.ArrayList(Row) = .empty;
    durableRows(self, arena, &rows);
    transferRows(self, arena, &rows);
    pendingBatchRows(self, arena, &rows);
    conflictRows(self, arena, &rows);
    dropProbeRows(self, arena, &rows);
    copyQueueRows(self, arena, &rows);
    deferredRows(self, arena, &rows);
    daemonRows(self, arena, &rows);
    return rows.items;
}

const BatchAgg = struct {
    id: u64,
    expected: usize = 0,
    admitting: bool = false,
    admission_done: usize = 0,
    children: usize = 0,
    running: usize = 0,
    queued: usize = 0,
    paused: usize = 0,
    finished: usize = 0,
    failed: usize = 0,
    canceled: usize = 0,
    done: u64 = 0,
    total: u64 = 0,
    resumed_from: u64 = 0,
    totals_known: bool = true,
    move: bool = false,
    dst: []const u8 = "",
    dest_host: []const u8 = "",
    dest_dir: []const u8 = "",
    /// Sum of the active members' own byte fractions — drives the bar
    /// when some members have no byte total yet (a single big file no
    /// longer sits at 0% because a queued sibling reports no size).
    active_frac: f64 = 0,
    current_file: ?[]const u8 = null,
};

fn satAdd(a: u64, b: u64) u64 {
    return a +| b;
}

fn batchState(batch: BatchAgg) RowState {
    if (batch.running > 0) return .running;
    if (batch.admitting or batch.queued > 0) return .queued;
    if (batch.paused > 0) return .paused;
    if (batch.failed > 0) return .failed;
    if (batch.finished > 0) return .finished;
    if (batch.canceled > 0) return .canceled;
    return .queued;
}

fn batchMessage(arena: std.mem.Allocator, batch: BatchAgg) []const u8 {
    var w: std.Io.Writer.Allocating = .init(arena);
    var has_text = false;
    if (batch.admitting) {
        w.writer.print("queuing {d} of {d}", .{ batch.admission_done, batch.expected }) catch {};
        has_text = true;
    }
    const absent = if (!batch.admitting and batch.expected > batch.children)
        batch.expected - batch.children
    else
        0;
    const counts = [_]struct { n: usize, label: []const u8 }{
        .{ .n = batch.running, .label = "running" },
        .{ .n = batch.queued, .label = "waiting" },
        .{ .n = batch.paused, .label = "paused" },
        .{ .n = batch.finished, .label = "finished" },
        .{ .n = batch.failed, .label = "failed" },
        .{ .n = batch.canceled, .label = "canceled" },
        .{ .n = absent, .label = "not active" },
    };
    for (counts) |part| {
        if (part.n == 0) continue;
        if (has_text) w.writer.writeAll(", ") catch {};
        w.writer.print("{d} {s}", .{ part.n, part.label }) catch {};
        has_text = true;
    }
    return w.written();
}

/// Replace every nonzero batch id with one synthetic collapsed row.
/// The existing item rows remain the expansion contents and retain all
/// of their individual controls.
fn groupedRows(self: *BrowserView, arena: std.mem.Allocator, raw: []const Row) []Row {
    var batches: std.ArrayList(BatchAgg) = .empty;
    var by_id: std.AutoHashMapUnmanaged(u64, usize) = .empty;
    var seen_items: std.StringHashMapUnmanaged(void) = .empty;
    var members: std.ArrayList(Row) = .empty;

    for (self.paste_runs.items) |run| {
        if (run.batch_id == 0) continue;
        const gop = by_id.getOrPut(arena, run.batch_id) catch continue;
        if (!gop.found_existing) {
            const index = batches.items.len;
            batches.append(arena, .{ .id = run.batch_id }) catch {
                _ = by_id.remove(run.batch_id);
                continue;
            };
            gop.value_ptr.* = index;
        }
        const batch = &batches.items[gop.value_ptr.*];
        batch.expected = run.total;
        batch.admitting = true;
        batch.admission_done = @min(run.total, run.next);
        batch.move = run.cut;
        batch.dst = hostQualified(arena, run.dst_hc.host orelse "", run.dst_dir);
        batch.dest_host = run.dst_hc.host orelse "";
        batch.dest_dir = destDirOf(arena, run.dst_dir);
    }

    for (raw) |row| {
        if (row.batch_id == 0) continue;
        if (row.batch_item.len > 0) {
            const seen = seen_items.getOrPut(arena, row.batch_item) catch continue;
            if (seen.found_existing) continue;
        }
        members.append(arena, row) catch continue;
        const gop = by_id.getOrPut(arena, row.batch_id) catch continue;
        if (!gop.found_existing) {
            const index = batches.items.len;
            batches.append(arena, .{ .id = row.batch_id }) catch {
                _ = by_id.remove(row.batch_id);
                continue;
            };
            gop.value_ptr.* = index;
        }
        const batch = &batches.items[gop.value_ptr.*];
        batch.children += 1;
        batch.expected = @max(batch.expected, row.batch_total);
        batch.move = batch.move or row.move;
        if (batch.dst.len == 0)
            batch.dst = std.fs.path.dirname(row.dst) orelse row.dst;
        // Prefer a member that knows the REAL destination host: the
        // coordinator-relative fallback renders a remote destination
        // as a local-looking path.
        if (batch.dest_dir.len == 0 or (batch.dest_host.len == 0 and row.dest_host.len > 0)) {
            batch.dest_host = row.dest_host;
            batch.dest_dir = row.dest_dir;
        }
        if (batch.current_file == null and row.current_file != null)
            batch.current_file = row.current_file;
        batch.done = satAdd(batch.done, row.done);
        batch.resumed_from = satAdd(batch.resumed_from, row.resumed_from);
        if (row.total == 0 and row.active()) {
            batch.totals_known = false;
        } else {
            batch.total = satAdd(batch.total, row.total);
        }
        if (row.active() and row.total > 0)
            batch.active_frac += @min(1.0, @as(f64, @floatFromInt(row.done)) / @as(f64, @floatFromInt(row.total)));
        switch (row.state) {
            .running => batch.running += 1,
            .queued => batch.queued += 1,
            .paused => batch.paused += 1,
            .finished => batch.finished += 1,
            .failed => batch.failed += 1,
            .canceled => batch.canceled += 1,
        }
    }

    var out: std.ArrayList(Row) = .empty;
    for (batches.items) |stored| {
        const batch = stored;
        const count = if (batch.expected > 0) batch.expected else batch.children;
        const label = std.fmt.allocPrint(arena, "{s} {d} items to {s}", .{
            if (batch.move) "Move" else "Copy", count, if (batch.dst.len > 0) batch.dst else "destination",
        }) catch "File operation batch";
        const settled = batch.finished + batch.failed + batch.canceled;
        const key = Key{ .kind = .batch, .job = batch.id };
        out.append(arena, .{
            .key = key,
            .label = label,
            .name = std.fmt.allocPrint(arena, "{s} {d} items", .{
                if (batch.move) "Move" else "Copy", count,
            }) catch "File operation",
            .dest_host = batch.dest_host,
            .dest_dir = if (batch.dest_dir.len > 0) batch.dest_dir else batch.dst,
            .state = batchState(batch),
            .done = batch.done,
            .total = if (batch.totals_known) batch.total else 0,
            .resumed_from = batch.resumed_from,
            .frac_hint = if (count > 0)
                @min(1.0, (@as(f64, @floatFromInt(settled)) + batch.active_frac) / @as(f64, @floatFromInt(count)))
            else
                0,
            .dst = batch.dst,
            .current_file = batch.current_file,
            .files_done = settled,
            .files_total = count,
            .message = batchMessage(arena, batch),
            .move = batch.move,
        }) catch return out.items;
        const expanded = if (self.jobs_panel.find(key)) |meter| meter.expanded else false;
        if (!expanded or batch.admitting) continue;
        for (members.items) |row| {
            if (row.batch_id != batch.id) continue;
            var child = row;
            child.batch_child = true;
            out.append(arena, child) catch return out.items;
        }
    }
    for (raw) |row| {
        if (row.batch_id == 0) out.append(arena, row) catch return out.items;
    }
    return out.items;
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
            m.* = .{ .key = r.key, .order = panel.next_order };
            panel.next_order += 1;
            if (r.key.token.len > 0) {
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
        if (r.state == .running and meter.started_ms == 0) meter.started_ms = now;
        if (!r.active() and meter.settled_ms == 0) meter.settled_ms = now;
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

// ── row content ─────────────────────────────────────────────────

/// State icon + Adwaita color class for the head of a row.
const StateLook = struct { icon: [*:0]const u8, class: [*:0]const u8 };

fn stateLook(state: RowState, stalled: bool) StateLook {
    return switch (state) {
        .queued => .{ .icon = "hourglass-symbolic", .class = "dim-label" },
        .running => if (stalled)
            .{ .icon = "network-offline-symbolic", .class = "warning" }
        else
            .{ .icon = "network-transmit-receive-symbolic", .class = "accent" },
        .paused => .{ .icon = "media-playback-pause-symbolic", .class = "dim-label" },
        .finished => .{ .icon = "emblem-ok-symbolic", .class = "success" },
        .failed => .{ .icon = "dialog-error-symbolic", .class = "error" },
        .canceled => .{ .icon = "process-stop-symbolic", .class = "dim-label" },
    };
}

/// Link-state pill derived from the job's live message: the free-text
/// "reconnected to gobelijn; resuming…" prose becomes a small colored
/// badge instead of a sentence glued onto the head line.
const Badge = struct { text: [*:0]const u8, class: [*:0]const u8 };

fn linkBadge(row: Row) ?Badge {
    if (!row.active()) return null;
    const m = row.message;
    if (m.len == 0) return null;
    if (std.mem.indexOf(u8, m, "waiting for") != null or
        std.mem.indexOf(u8, m, "connecting") != null)
        return .{ .text = "connecting", .class = "warning" };
    if (std.mem.indexOf(u8, m, "unreachable") != null or
        std.mem.indexOf(u8, m, "reconnecting") != null)
        return .{ .text = "reconnecting", .class = "warning" };
    if (std.mem.indexOf(u8, m, "reconnected") != null or
        std.mem.indexOf(u8, m, "resuming") != null)
        return .{ .text = "reconnected", .class = "success" };
    return null;
}

/// The card's right-aligned numbers: state-appropriate, never padded
/// with placeholders.
fn statsText(buf: []u8, row: Row, meter: *const Meter) []const u8 {
    var a: [48:0]u8 = undefined;
    var b: [48:0]u8 = undefined;
    var rate_buf: [32]u8 = undefined;
    var eta_buf: [32]u8 = undefined;
    var w = std.Io.Writer.fixed(buf);
    switch (row.state) {
        .running => {
            if (row.total > 0) {
                w.print("{s} / {s}", .{ fmtSize(&a, row.done), fmtSize(&b, row.total) }) catch {};
            } else if (row.done > 0) {
                w.print("{s}", .{fmtSize(&a, row.done)}) catch {};
            }
            if (meter.status.stalled) {
                w.print(" · stalled", .{}) catch {};
            } else if (meter.status.rate_bps) |bps| {
                w.print(" · {s}", .{progress.formatRate(&rate_buf, bps)}) catch {};
                if (meter.status.eta_s) |eta|
                    w.print(" · {s} left", .{progress.formatEta(&eta_buf, eta)}) catch {};
            }
        },
        .paused => {
            if (row.total > 0)
                w.print("{s} / {s} · ", .{ fmtSize(&a, row.done), fmtSize(&b, row.total) }) catch {};
            w.print("paused", .{}) catch {};
        },
        .queued => w.print("queued", .{}) catch {},
        .finished => {
            const size = if (row.total > 0) row.total else row.done;
            if (size > 0) w.print("{s}", .{fmtSize(&a, size)}) catch {};
            if (meter.started_ms > 0 and meter.settled_ms > meter.started_ms) {
                const secs: u64 = @intCast(@divTrunc(meter.settled_ms - meter.started_ms, 1000));
                if (secs > 0) w.print(" in {s}", .{progress.formatEta(&eta_buf, secs)}) catch {};
            }
            if (w.buffered().len == 0) w.print("done", .{}) catch {};
        },
        .failed => w.print("failed", .{}) catch {},
        .canceled => w.print("canceled", .{}) catch {},
    }
    return w.buffered();
}

// ── the ambient strip's aggregate ───────────────────────────────

const StripMode = enum { hidden, active, queued_only, failed, done };

/// Everything the one-line strip shows, computed from the top-level
/// rows (batch children are detail, not additional operations).
const StripInfo = struct {
    mode: StripMode = .hidden,
    fraction: f64 = 0,
    indeterminate: bool = false,
    kind: PaintKind = .accent,
    text_buf: [256]u8 = undefined,
    text_len: usize = 0,
    nums_buf: [96]u8 = undefined,
    nums_len: usize = 0,

    fn text(self: *const StripInfo) []const u8 {
        return self.text_buf[0..self.text_len];
    }
    fn nums(self: *const StripInfo) []const u8 {
        return self.nums_buf[0..self.nums_len];
    }
};

fn stripInfo(rows: []const Row, panel: *Panel) StripInfo {
    var info = StripInfo{};
    var running: usize = 0;
    var waiting: usize = 0;
    var failed: usize = 0;
    var finished: usize = 0;
    var stalled = false;
    var items: usize = 0;
    var moves: usize = 0;
    var copies: usize = 0;
    var rate: u64 = 0;
    var remaining: u64 = 0;
    var remaining_known = true;
    var frac_sum: f64 = 0;
    var frac_n: usize = 0;
    var done_bytes: u64 = 0;
    var first_name: []const u8 = "";
    var first_host: []const u8 = "";
    var fail_msg: []const u8 = "";
    for (rows) |r| {
        if (r.batch_child) continue;
        const meter = panel.find(r.key);
        items += if (r.key.kind == .batch) @max(r.files_total, 1) else 1;
        if (r.move) moves += 1 else copies += 1;
        frac_sum += fraction(r);
        frac_n += 1;
        switch (r.state) {
            .running, .paused => {
                running += 1;
                if (first_name.len == 0) {
                    first_name = if (r.current_file) |f| std.fs.path.basename(f) else r.name;
                    first_host = r.dest_host;
                }
                if (meter) |m| {
                    if (m.status.stalled) stalled = true;
                    if (m.status.rate_bps) |bps| rate += bps;
                }
                if (r.total > 0) remaining += r.total -| r.done else remaining_known = false;
            },
            .queued => waiting += 1,
            .failed => {
                failed += 1;
                // A batch row's message is member-count bookkeeping
                // ("2 failed"); its name is the sentence.
                if (fail_msg.len == 0)
                    fail_msg = if (r.key.kind != .batch and r.message.len > 0) r.message else r.name;
            },
            .finished => {
                finished += 1;
                done_bytes +|= if (r.total > 0) r.total else r.done;
            },
            .canceled => {},
        }
    }
    if (frac_n == 0) return info;
    info.fraction = frac_sum / @as(f64, @floatFromInt(frac_n));
    var w = std.Io.Writer.fixed(&info.text_buf);
    var nw = std.Io.Writer.fixed(&info.nums_buf);
    const verb: []const u8 = if (moves > 0 and copies == 0) "Moving" else if (moves == 0) "Copying" else "Working on";
    if (running > 0) {
        info.mode = .active;
        info.kind = if (stalled) .warn else .accent;
        info.indeterminate = !remaining_known and rate == 0;
        if (items == 1 and first_name.len > 0) {
            w.print("{s} {s}", .{ verb, first_name }) catch {};
        } else {
            w.print("{s} {d} items", .{ verb, items }) catch {};
        }
        if (first_host.len > 0) w.print(" to {s}", .{displayHost(first_host)}) catch {};
        if (items > 1 and first_name.len > 0) w.print(" — {s}", .{first_name}) catch {};
        if (failed > 0) w.print(" · {d} failed", .{failed}) catch {};
        nw.print("{d}%", .{@as(u64, @intFromFloat(info.fraction * 100.0))}) catch {};
        if (stalled) {
            nw.print(" · stalled", .{}) catch {};
        } else if (rate > 0) {
            var rate_buf: [32]u8 = undefined;
            nw.print(" · {s}", .{progress.formatRate(&rate_buf, rate)}) catch {};
            if (remaining_known and remaining > 0) {
                var eta_buf: [32]u8 = undefined;
                nw.print(" · {s} left", .{progress.formatEta(&eta_buf, remaining / rate)}) catch {};
            }
        }
    } else if (waiting > 0 and failed == 0) {
        info.mode = .queued_only;
        info.kind = .dim;
        info.indeterminate = true;
        w.print("{d} queued — waiting to start", .{waiting}) catch {};
    } else if (failed > 0) {
        info.mode = .failed;
        info.kind = .err;
        info.fraction = 1;
        if (failed == 1) {
            w.print("1 transfer failed — {s}", .{fail_msg}) catch {};
        } else {
            w.print("{d} transfers failed — {s}", .{ failed, fail_msg }) catch {};
        }
    } else if (finished > 0) {
        info.mode = .done;
        info.kind = .ok;
        info.fraction = 1;
        var size_buf: [48:0]u8 = undefined;
        const done_verb: []const u8 = if (moves > 0 and copies == 0) "Moved" else "Copied";
        if (done_bytes > 0) {
            w.print("{s} {d} item{s} — {s}", .{
                done_verb, items, if (items == 1) "" else "s", fmtSize(&size_buf, done_bytes),
            }) catch {};
        } else {
            w.print("{d} operation{s} finished", .{ items, if (items == 1) "" else "s" }) catch {};
        }
    } else {
        info.mode = .queued_only;
        info.kind = .dim;
        w.print("{d} operation{s}", .{ items, if (items == 1) "" else "s" }) catch {};
    }
    info.text_len = w.buffered().len;
    info.nums_len = nw.buffered().len;
    return info;
}

/// The Transfer Center's header summary.
fn centerSummary(buf: []u8, rows: []const Row, panel: *Panel) []const u8 {
    var running: usize = 0;
    var waiting: usize = 0;
    var rate: u64 = 0;
    for (rows) |r| {
        if (r.batch_child) continue;
        switch (r.state) {
            .running, .paused => running += 1,
            .queued => waiting += 1,
            else => {},
        }
        if (panel.find(r.key)) |m| {
            if (m.status.rate_bps) |bps| rate += bps;
        }
    }
    var w = std.Io.Writer.fixed(buf);
    w.print("{d} active · {d} queued", .{ running, waiting }) catch {};
    if (rate > 0) {
        var rate_buf: [32]u8 = undefined;
        w.print(" · {s} total", .{progress.formatRate(&rate_buf, rate)}) catch {};
    }
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
    deferred: ?*jobs.DeferredTransfer = null,
    /// Durable ledger token (owned).
    service_token: ?[]u8 = null,
    meter_key: Key,
    /// Owned storage when meter_key carries a durable token.
    meter_token: ?[]u8 = null,
    kind: enum { pause, resume_, cancel, dismiss, move_up, move_down, expand, retry, center, clear_done },

    fn free(user: ?*anyopaque, closure: ?*anyopaque) callconv(.c) void {
        _ = closure;
        const ctx: *JobBtnCtx = @ptrCast(@alignCast(user.?));
        if (ctx.service_token) |token| ctx.allocator.free(token);
        if (ctx.meter_token) |token| ctx.allocator.free(token);
        ctx.allocator.destroy(ctx);
    }
};

pub fn jobsButton(self: *BrowserView, row: *c.GtkWidget, icon: [*:0]const u8, ctx_in: JobBtnCtx) void {
    const ctx = self.allocator.create(JobBtnCtx) catch {
        if (ctx_in.service_token) |token| ctx_in.allocator.free(token);
        if (ctx_in.meter_token) |token| ctx_in.allocator.free(token);
        return;
    };
    ctx.* = ctx_in;
    const btn = c.gtk_button_new_from_icon_name(icon);
    c.gtk_button_set_has_frame(@ptrCast(btn), 0);
    const tip: [*:0]const u8 = switch (ctx_in.kind) {
        .pause => "Pause",
        .resume_ => "Resume",
        .cancel => "Cancel",
        .dismiss => "Dismiss",
        .move_up => "Move up in the queue",
        .move_down => "Move down in the queue",
        .expand => "Show details",
        .retry => "Retry",
        .center => "Transfer details (Ctrl+Shift+J)",
        .clear_done => "Clear finished",
    };
    c.gtk_widget_set_tooltip_text(btn, tip);
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
    if (ctx.kind == .center) {
        self.jobs_panel.center_open = !self.jobs_panel.center_open;
        self.renderJobs();
        return;
    }
    if (ctx.kind == .clear_done) {
        clearFinished(self);
        return;
    }
    if (ctx.service_token) |token| {
        const service = self.transfer_service orelse return;
        switch (ctx.kind) {
            .move_up => service.moveQueued(token, -1),
            .move_down => service.moveQueued(token, 1),
            .cancel => service.cancel(token),
            .dismiss => if (!service.dismissMediated(token)) {
                self.setStatus("could not persist transfer dismissal");
                return;
            },
            .pause => service.setPaused(token, true),
            .resume_ => service.setPaused(token, false),
            .retry => service.retryMediated(token),
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
    if (ctx.deferred) |item| {
        if (ctx.kind == .cancel) self.cancelDeferredTransfer(item);
        self.renderJobs();
        return;
    }
    const hc = ctx.hc orelse return;
    switch (ctx.kind) {
        .pause => {
            for (self.jobs.items) |j| {
                if (j.hc == hc and j.job == ctx.job) if (j.retry) |retry| {
                    if (self.transfer_service) |service| if (!service.setMediatedPaused(retry.token, true)) {
                        self.setStatus("could not persist transfer pause state");
                        return;
                    };
                };
            }
            self.sendOp(hc, .{ .req = self.nextReq(), .op = "job_pause", .job = ctx.job });
            self.markJob(hc, ctx.job, .paused);
        },
        .resume_ => {
            for (self.jobs.items) |j| {
                if (j.hc == hc and j.job == ctx.job) if (j.retry) |retry| {
                    if (self.transfer_service) |service| if (!service.setMediatedPaused(retry.token, false)) {
                        self.setStatus("could not persist transfer pause state");
                        return;
                    };
                };
            }
            self.sendOp(hc, .{ .req = self.nextReq(), .op = "job_resume", .job = ctx.job });
            self.markJob(hc, ctx.job, .running);
        },
        .cancel => {
            for (self.jobs.items) |j| {
                if (j.hc != hc or j.job != ctx.job) continue;
                if (j.retry) |retry| {
                    const service = self.transfer_service orelse return;
                    if (!service.requestMediatedCancel(retry.token)) {
                        self.setStatus("could not persist transfer cancellation");
                        return;
                    }
                }
                break;
            }
            self.sendOp(hc, .{ .req = self.nextReq(), .op = "job_cancel", .job = ctx.job });
        },
        .retry => {
            for (self.jobs.items) |j| {
                if (j.hc == hc and j.job == ctx.job) {
                    self.retryCopyJob(j);
                    break;
                }
            }
        },
        .dismiss => {
            var i: usize = 0;
            while (i < self.jobs.items.len) : (i += 1) {
                const j = self.jobs.items[i];
                if (j.hc == hc and j.job == ctx.job) {
                    if (j.retry) |retry| {
                        if (self.transfer_service) |service| {
                            if (!service.dismissMediated(retry.token)) {
                                self.setStatus("could not persist transfer dismissal");
                                return;
                            }
                        }
                        self.cancelScheduledRetry(retry.token);
                    }
                    if (j.undo_op) |u| u.destroy(self.allocator);
                    if (j.undo_trash_orig) |o| self.allocator.free(o);
                    if (j.retry) |r| r.destroy(self.allocator);
                    self.allocator.free(j.label);
                    self.allocator.destroy(j);
                    _ = self.jobs.orderedRemove(i);
                    break;
                }
            }
        },
        .move_up, .move_down, .expand, .center, .clear_done => {},
    }
    self.renderJobs();
}

/// Dismiss every settled row in one go: the Transfer Center's "Clear
/// finished" and the strip's dismiss on a green/red summary line. Same
/// semantics as pressing each row's own dismiss.
fn clearFinished(self: *BrowserView) void {
    if (self.transfer_service) |service| {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        if (service.rows(arena.allocator(), @ptrCast(self))) |rows| {
            for (rows) |d| {
                const terminal = d.state == .done or d.state == .failed or d.state == .canceled;
                if (!terminal) continue;
                if (!service.dismissMediated(d.token)) {
                    self.setStatus("could not persist transfer dismissal");
                    break;
                }
            }
        } else |_| {}
    }
    var i: usize = 0;
    while (i < self.jobs.items.len) {
        const j = self.jobs.items[i];
        const successor_active = jobs.copySuccessorActive(self, j);
        if (!j.terminal() or j.retry_scheduled or successor_active) {
            i += 1;
            continue;
        }
        if (j.retry) |retry| {
            if (self.transfer_service) |service| {
                if (!service.dismissMediated(retry.token)) {
                    self.setStatus("could not persist transfer dismissal");
                    return;
                }
            }
            self.cancelScheduledRetry(retry.token);
        }
        if (j.undo_op) |u| u.destroy(self.allocator);
        if (j.undo_trash_orig) |o| self.allocator.free(o);
        if (j.retry) |r| r.destroy(self.allocator);
        self.allocator.free(j.label);
        self.allocator.destroy(j);
        _ = self.jobs.orderedRemove(i);
    }
    self.renderJobs();
}

/// Public entry for the Ctrl+Shift+J chord and the palette.
pub fn toggleTransferCenter(self: *BrowserView) void {
    self.jobs_panel.center_open = !self.jobs_panel.center_open;
    self.renderJobs();
}

/// The meter a button belongs to, from the identity it carries.
fn meterOf(ctx: *JobBtnCtx, self: *BrowserView) ?*Meter {
    return self.jobs_panel.find(ctx.meter_key);
}

fn identityCtx(self: *BrowserView, row: Row, kind: @FieldType(JobBtnCtx, "kind")) JobBtnCtx {
    var ctx: JobBtnCtx = .{
        .allocator = self.allocator,
        .view = self,
        .hc = row.hc,
        .job = row.key.job,
        .transfer = row.transfer,
        .copy = row.copy,
        .deferred = row.deferred,
        .service_token = if (row.key.kind == .durable) (self.allocator.dupe(u8, row.key.token) catch null) else null,
        .meter_key = row.key,
        .kind = kind,
    };
    if (row.key.token.len > 0) {
        ctx.meter_token = self.allocator.dupe(u8, row.key.token) catch null;
        if (ctx.meter_token) |token| ctx.meter_key.token = token;
    }
    return ctx;
}

fn drawSpark(_: ?*c.GtkDrawingArea, cr: ?*c.cairo_t, width: c_int, height: c_int, user: c.gpointer) callconv(.c) void {
    const spark: *Spark = @ptrCast(@alignCast(user.?));
    const samples = spark.values[0..spark.len];
    const peak = spark.peak;
    const w: f64 = @floatFromInt(width);
    const h: f64 = @floatFromInt(height);
    // Baseline so an idle spark still reads as a chart, not a box.
    c.cairo_set_line_width(cr, 1.0);
    c.cairo_set_source_rgba(cr, 0.5, 0.5, 0.55, 0.35);
    c.cairo_move_to(cr, 0, h - 0.5);
    c.cairo_line_to(cr, w, h - 0.5);
    c.cairo_stroke(cr);
    if (samples.len < 2 or peak == 0) return;
    const step = w / @as(f64, @floatFromInt(progress.HISTORY_LEN - 1));
    const top: f64 = @floatFromInt(peak);
    // Area fill under the line, then the line with its newest point
    // emphasized.
    c.cairo_move_to(cr, 0, h - 1);
    for (samples, 0..) |value, i| {
        const x = @as(f64, @floatFromInt(i)) * step;
        const y = h - 1 - (@as(f64, @floatFromInt(value)) / top) * (h - 3);
        c.cairo_line_to(cr, x, y);
    }
    c.cairo_line_to(cr, @as(f64, @floatFromInt(samples.len - 1)) * step, h - 1);
    c.cairo_close_path(cr);
    paintColor(.accent, cr, 0.18);
    c.cairo_fill(cr);
    paintColor(.accent, cr, 0.9);
    for (samples, 0..) |value, i| {
        const x = @as(f64, @floatFromInt(i)) * step;
        const y = h - 1 - (@as(f64, @floatFromInt(value)) / top) * (h - 3);
        if (i == 0) c.cairo_move_to(cr, x, y) else c.cairo_line_to(cr, x, y);
    }
    c.cairo_stroke(cr);
}

fn roundedRect(cr: ?*c.cairo_t, x: f64, y: f64, w: f64, h: f64, r: f64) void {
    const rr = @min(r, @min(w, h) / 2);
    c.cairo_new_sub_path(cr);
    c.cairo_arc(cr, x + w - rr, y + rr, rr, -std.math.pi / 2.0, 0);
    c.cairo_arc(cr, x + w - rr, y + h - rr, rr, 0, std.math.pi / 2.0);
    c.cairo_arc(cr, x + rr, y + h - rr, rr, std.math.pi / 2.0, std.math.pi);
    c.cairo_arc(cr, x + rr, y + rr, rr, std.math.pi, std.math.pi * 1.5);
    c.cairo_close_path(cr);
}

fn drawBar(_: ?*c.GtkDrawingArea, cr: ?*c.cairo_t, width: c_int, height: c_int, user: c.gpointer) callconv(.c) void {
    const bar: *BarData = @ptrCast(@alignCast(user.?));
    const w: f64 = @floatFromInt(width);
    const h: f64 = @floatFromInt(height);
    // Track.
    c.cairo_set_source_rgba(cr, 0.5, 0.5, 0.55, 0.22);
    roundedRect(cr, 0, 0, w, h, h / 2);
    c.cairo_fill(cr);
    const frac = std.math.clamp(bar.fraction, 0.0, 1.0);
    if (frac <= 0) return;
    const fill_w = @max(h, w * frac);
    // Resumed prefix, dimmer: the part this run did not have to move.
    const resumed = std.math.clamp(bar.resumed, 0.0, frac);
    if (resumed > 0.01) {
        paintColor(bar.kind, cr, 0.45);
        roundedRect(cr, 0, 0, @max(h, w * resumed), h, h / 2);
        c.cairo_fill(cr);
        paintColor(bar.kind, cr, 1.0);
        // Fresh progress continues from the resumed prefix; keep one
        // rounded capsule by overdrawing from just before it.
        roundedRect(cr, @max(0, w * resumed - h), 0, fill_w - @max(0, w * resumed - h), h, h / 2);
        c.cairo_fill(cr);
    } else {
        paintColor(bar.kind, cr, 1.0);
        roundedRect(cr, 0, 0, fill_w, h, h / 2);
        c.cairo_fill(cr);
    }
}

fn drawRing(_: ?*c.GtkDrawingArea, cr: ?*c.cairo_t, width: c_int, height: c_int, user: c.gpointer) callconv(.c) void {
    const ring: *RingData = @ptrCast(@alignCast(user.?));
    const w: f64 = @floatFromInt(width);
    const h: f64 = @floatFromInt(height);
    const cx = w / 2;
    const cy = h / 2;
    const radius = @min(w, h) / 2 - 1.5;
    c.cairo_set_line_width(cr, 2.5);
    c.cairo_set_source_rgba(cr, 0.5, 0.5, 0.55, 0.25);
    c.cairo_arc(cr, cx, cy, radius, 0, std.math.pi * 2);
    c.cairo_stroke(cr);
    paintColor(ring.kind, cr, 1.0);
    const start = -std.math.pi / 2.0;
    if (ring.indeterminate) {
        c.cairo_arc(cr, cx, cy, radius, start, start + std.math.pi * 0.6);
    } else {
        const frac = std.math.clamp(ring.fraction, 0.0, 1.0);
        if (frac <= 0.005) return;
        c.cairo_arc(cr, cx, cy, radius, start, start + std.math.pi * 2 * frac);
    }
    c.cairo_stroke(cr);
}

/// One-time CSS for the panel's badge pill.
fn ensurePanelCss() void {
    const css =
        ".job-badge { padding: 1px 8px; border-radius: 10px; font-size: 0.85em; " ++
        "background: alpha(currentColor, 0.12); }\n" ++
        ".xfer-strip { border-top: 1px solid alpha(currentColor, 0.15); " ++
        "padding: 3px 10px; }\n" ++
        ".xfer-card { background: alpha(currentColor, 0.05); border-radius: 8px; " ++
        "border: 1px solid alpha(currentColor, 0.08); padding: 6px 10px 5px 10px; }\n" ++
        ".xfer-card-err { border-left: 3px solid @error_color; }\n" ++
        ".xfer-card-dim { background: transparent; border-color: transparent; " ++
        "padding-top: 1px; padding-bottom: 1px; }\n" ++
        ".xfer-name { font-weight: 600; }\n";
    cssutil.install("browser_jobpanel", null, css);
}

/// Swap the Adwaita color class on a widget (the classes are mutually
/// exclusive, so all candidates are cleared first).
fn setColorClass(widget: *c.GtkWidget, class: [*:0]const u8) void {
    const candidates = [_][*:0]const u8{ "success", "warning", "error", "accent", "dim-label" };
    for (candidates) |cl| c.gtk_widget_remove_css_class(widget, cl);
    c.gtk_widget_add_css_class(widget, class);
}

/// Write every dynamic part of a card into its widgets. Shared by the
/// initial build and every refresh, so the two can never drift.
fn applyRow(row: Row, meter: *Meter) void {
    const look = stateLook(row.state, meter.status.stalled);
    if (meter.name_label) |label| {
        var z: [512:0]u8 = undefined;
        c.gtk_label_set_text(label, copyZ(&z, if (row.name.len > 0) row.name else row.label));
    }
    if (meter.dest_label) |label| {
        var buf: [512]u8 = undefined;
        var z: [512:0]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        if (row.dest_dir.len > 0) {
            if (row.dest_host.len > 0) {
                w.print("→ {s}:{s}", .{ displayHost(row.dest_host), row.dest_dir }) catch {};
            } else {
                w.print("→ {s}", .{row.dest_dir}) catch {};
            }
        }
        c.gtk_label_set_text(label, copyZ(&z, w.buffered()));
    }
    if (meter.state_icon) |icon| {
        c.gtk_image_set_from_icon_name(@ptrCast(icon), look.icon);
        setColorClass(icon, look.class);
    }
    if (meter.badge_label) |badge| {
        if (linkBadge(row)) |bd| {
            c.gtk_label_set_text(badge, bd.text);
            setColorClass(@ptrCast(@alignCast(badge)), bd.class);
            c.gtk_widget_add_css_class(@ptrCast(@alignCast(badge)), "job-badge");
            c.gtk_widget_set_visible(@ptrCast(@alignCast(badge)), 1);
        } else {
            c.gtk_widget_set_visible(@ptrCast(@alignCast(badge)), 0);
        }
    }
    if (meter.stats_label) |label| {
        var buf: [160]u8 = undefined;
        var z: [192:0]u8 = undefined;
        c.gtk_label_set_text(label, copyZ(&z, statsText(&buf, row, meter)));
        setColorClass(@ptrCast(@alignCast(label)), switch (row.state) {
            .running => if (meter.status.stalled) "warning" else "dim-label",
            .failed => "error",
            else => "dim-label",
        });
    }
    if (meter.bar_data) |bar| {
        bar.fraction = fraction(row);
        const resumed = @max(meter.resumed_from, row.resumed_from);
        bar.resumed = if (row.total > 0 and resumed > 0)
            @as(f64, @floatFromInt(resumed)) / @as(f64, @floatFromInt(row.total))
        else
            0;
        bar.kind = switch (row.state) {
            .failed => .err,
            .paused, .queued => .dim,
            .running => if (meter.status.stalled) .warn else .accent,
            else => .accent,
        };
        if (meter.bar) |bar_widget| c.gtk_widget_queue_draw(bar_widget);
    }
    if (meter.chip_resumed) |chip| {
        const resumed = @max(meter.resumed_from, row.resumed_from);
        if (resumed > 0 and row.active()) {
            var size_buf: [48:0]u8 = undefined;
            var z: [64:0]u8 = undefined;
            var buf: [64]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "resumed at {s}", .{fmtSize(&size_buf, resumed)}) catch "resumed";
            c.gtk_label_set_text(@ptrCast(@alignCast(chip)), copyZ(&z, text));
            c.gtk_widget_set_visible(chip, 1);
        } else {
            c.gtk_widget_set_visible(chip, 0);
        }
    }
    if (meter.cur_label) |label| {
        var buf: [512]u8 = undefined;
        var z: [512:0]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        if (row.state == .running) {
            if (row.current_file) |file| {
                if (row.files_total > 1 or row.key.kind == .batch) {
                    w.print("{d} of {d} — {s}", .{
                        @min(row.files_done + 1, row.files_total), row.files_total, std.fs.path.basename(file),
                    }) catch {};
                } else if (!std.mem.eql(u8, std.fs.path.basename(file), row.name)) {
                    w.print("{s}", .{std.fs.path.basename(file)}) catch {};
                }
            } else if (row.files_total > 1) {
                w.print("{d} of {d} files", .{ @min(row.files_done + 1, row.files_total), row.files_total }) catch {};
            }
        }
        const text = w.buffered();
        c.gtk_label_set_text(label, copyZ(&z, text));
        c.gtk_widget_set_visible(@ptrCast(@alignCast(label)), if (text.len > 0) 1 else 0);
    }
    if (meter.msg_label) |label| {
        var z: [512:0]u8 = undefined;
        c.gtk_label_set_text(label, copyZ(&z, row.message));
        c.gtk_widget_set_visible(@ptrCast(@alignCast(label)), if (row.message.len > 0) 1 else 0);
    }
    if (meter.spark_data) |data| data.take(&meter.sampler);
    if (meter.spark) |spark| c.gtk_widget_queue_draw(spark);
}

/// Owned by the card's right-click gesture: the full endpoint paths a
/// poweruser copies out. The menu items get their own root-owned copy
/// so a mid-popup rebuild cannot dangle them.
const CardMenuCtx = struct {
    allocator: std.mem.Allocator,
    view: *BrowserView,
    card: *c.GtkWidget,
    src: []u8,
    dst: []u8,

    fn free(user: ?*anyopaque, closure: ?*anyopaque) callconv(.c) void {
        _ = closure;
        const ctx: *CardMenuCtx = @ptrCast(@alignCast(user.?));
        ctx.allocator.free(ctx.src);
        ctx.allocator.free(ctx.dst);
        ctx.allocator.destroy(ctx);
    }
};

/// One menu invocation's payload, owned by the classicmenu Root.
const CardMenuItemCtx = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    card: *c.GtkWidget,

    fn cleanup(user: ?*anyopaque) callconv(.c) void {
        const ctx: *CardMenuItemCtx = @ptrCast(@alignCast(user.?));
        ctx.allocator.free(ctx.path);
        ctx.allocator.destroy(ctx);
    }
};

fn onCardCopyPath(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *CardMenuItemCtx = @ptrCast(@alignCast(user.?));
    var z: [4096:0]u8 = undefined;
    const n = @min(ctx.path.len, z.len - 1);
    @memcpy(z[0..n], ctx.path[0..n]);
    z[n] = 0;
    const clip = c.gtk_widget_get_clipboard(ctx.card);
    c.gdk_clipboard_set_text(clip, &z);
}

fn cardMenuItem(root: *classicmenu.Root, m: classicmenu.Menu, ctx: *const CardMenuCtx, label: [*:0]const u8, path: []const u8) void {
    if (path.len == 0) return;
    const item_ctx = ctx.allocator.create(CardMenuItemCtx) catch return;
    const path_owned = ctx.allocator.dupe(u8, path) catch {
        ctx.allocator.destroy(item_ctx);
        return;
    };
    item_ctx.* = .{ .allocator = ctx.allocator, .path = path_owned, .card = ctx.card };
    root.own(&CardMenuItemCtx.cleanup, @ptrCast(item_ctx));
    m.item(label, &onCardCopyPath, @ptrCast(item_ctx));
}

fn onCardMenu(gesture: ?*c.GtkGestureClick, _: c.gint, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    _ = gesture;
    const ctx: *CardMenuCtx = @ptrCast(@alignCast(user.?));
    const root = classicmenu.Root.create(ctx.view.allocator) orelse return;
    const m = root.top();
    cardMenuItem(root, m, ctx, "Copy Source Path", ctx.src);
    cardMenuItem(root, m, ctx, "Copy Destination Path", ctx.dst);
    _ = root.popupVia(ctx.card, ctx.view.root_box, x, y);
}

/// One Transfer Center card: name-first head line, byte-driven bar
/// with the resumed prefix shaded, a live second line for tree
/// progress and throughput, and a full-sentence message when the row
/// has something to say.
fn buildCard(self: *BrowserView, parent: *c.GtkWidget, row: Row, meter: *Meter) void {
    ensurePanelCss();
    const card = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 2);
    c.gtk_widget_add_css_class(card, "xfer-card");
    const settled = row.state == .finished or row.state == .canceled;
    if (row.state == .failed) c.gtk_widget_add_css_class(card, "xfer-card-err");
    if (settled) c.gtk_widget_add_css_class(card, "xfer-card-dim");
    if (row.batch_child) c.gtk_widget_set_margin_start(card, 26);

    // Full endpoints stay reachable: tooltip + right-click copy.
    if (row.src.len > 0 or row.dst.len > 0) {
        var tip_buf: [1024]u8 = undefined;
        var tip_z: [1024:0]u8 = undefined;
        var w = std.Io.Writer.fixed(&tip_buf);
        if (row.src.len > 0) w.print("{s}", .{row.src}) catch {};
        if (row.dst.len > 0) w.print("\n→ {s}", .{row.dst}) catch {};
        c.gtk_widget_set_tooltip_text(card, copyZ(&tip_z, w.buffered()));
        const menu_ctx = self.allocator.create(CardMenuCtx) catch null;
        if (menu_ctx) |ctx| blk: {
            const src_owned = self.allocator.dupe(u8, row.src) catch {
                self.allocator.destroy(ctx);
                break :blk;
            };
            const dst_owned = self.allocator.dupe(u8, row.dst) catch {
                self.allocator.free(src_owned);
                self.allocator.destroy(ctx);
                break :blk;
            };
            ctx.* = .{ .allocator = self.allocator, .view = self, .card = card.?, .src = src_owned, .dst = dst_owned };
            const click = c.gtk_gesture_click_new();
            c.gtk_gesture_single_set_button(@ptrCast(click), 3);
            _ = c.g_signal_connect_data(click, "pressed", @ptrCast(&onCardMenu), @ptrCast(ctx), @ptrCast(&CardMenuCtx.free), c.G_CONNECT_DEFAULT);
            c.gtk_widget_add_controller(card, @ptrCast(click));
        }
    }

    const head = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 7);
    if (row.key.kind == .batch)
        jobsButton(self, head, if (meter.expanded) "pan-down-symbolic" else "pan-end-symbolic", identityCtx(self, row, .expand));

    const icon = c.gtk_image_new_from_icon_name("hourglass-symbolic");
    c.gtk_box_append(@ptrCast(head), icon);

    const name = c.gtk_label_new("");
    c.gtk_label_set_xalign(@ptrCast(name), 0);
    c.gtk_label_set_ellipsize(@ptrCast(name), c.PANGO_ELLIPSIZE_END);
    c.gtk_widget_add_css_class(name, "xfer-name");
    c.gtk_box_append(@ptrCast(head), name);

    const dest = c.gtk_label_new("");
    c.gtk_label_set_xalign(@ptrCast(dest), 0);
    c.gtk_widget_set_hexpand(dest, 1);
    c.gtk_label_set_ellipsize(@ptrCast(dest), c.PANGO_ELLIPSIZE_MIDDLE);
    c.gtk_widget_add_css_class(dest, "dim-label");
    c.gtk_box_append(@ptrCast(head), dest);

    const badge = c.gtk_label_new("");
    c.gtk_widget_add_css_class(badge, "job-badge");
    c.gtk_widget_set_valign(badge, c.GTK_ALIGN_CENTER);
    c.gtk_widget_set_visible(badge, 0);
    c.gtk_box_append(@ptrCast(head), badge);

    const stats = c.gtk_label_new("");
    c.gtk_label_set_xalign(@ptrCast(stats), 1);
    c.gtk_widget_add_css_class(stats, "numeric");
    c.gtk_widget_add_css_class(stats, "dim-label");
    c.gtk_box_append(@ptrCast(head), stats);

    if (row.controls.reorder) {
        jobsButton(self, head, "go-up-symbolic", identityCtx(self, row, .move_up));
        jobsButton(self, head, "go-down-symbolic", identityCtx(self, row, .move_down));
    }
    if (row.controls.unpause)
        jobsButton(self, head, "media-playback-start-symbolic", identityCtx(self, row, .resume_));
    if (row.controls.pause)
        jobsButton(self, head, "media-playback-pause-symbolic", identityCtx(self, row, .pause));
    if (row.controls.retry)
        jobsButton(self, head, "view-refresh-symbolic", identityCtx(self, row, .retry));
    if (row.controls.cancel)
        jobsButton(self, head, "process-stop-symbolic", identityCtx(self, row, .cancel));
    if (row.controls.dismiss)
        jobsButton(self, head, "window-close-symbolic", identityCtx(self, row, .dismiss));
    c.gtk_box_append(@ptrCast(card), head);

    var bar: ?*c.GtkWidget = null;
    var bar_data: ?*BarData = null;
    if (row.active()) {
        bar = c.gtk_drawing_area_new();
        c.gtk_widget_set_size_request(bar, -1, 5);
        c.gtk_widget_set_hexpand(bar, 1);
        c.gtk_widget_set_margin_top(bar, 1);
        c.gtk_widget_set_margin_bottom(bar, 1);
        bar_data = self.allocator.create(BarData) catch null;
        if (bar_data) |data| {
            data.* = .{ .allocator = self.allocator };
            c.gtk_drawing_area_set_draw_func(@ptrCast(bar), @ptrCast(&drawBar), @ptrCast(data), @ptrCast(&BarData.free));
        }
        c.gtk_box_append(@ptrCast(card), bar);
    }

    var chip_resumed: ?*c.GtkWidget = null;
    var cur: ?*c.GtkWidget = null;
    var spark: ?*c.GtkWidget = null;
    var spark_data: ?*Spark = null;
    if (row.active()) {
        const detail = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 10);
        chip_resumed = c.gtk_label_new("");
        c.gtk_widget_add_css_class(chip_resumed, "job-badge");
        c.gtk_widget_add_css_class(chip_resumed, "accent");
        c.gtk_widget_add_css_class(chip_resumed, "caption");
        c.gtk_widget_set_valign(chip_resumed, c.GTK_ALIGN_CENTER);
        c.gtk_widget_set_visible(chip_resumed, 0);
        c.gtk_box_append(@ptrCast(detail), chip_resumed);

        cur = c.gtk_label_new("");
        c.gtk_label_set_xalign(@ptrCast(@alignCast(cur)), 0);
        c.gtk_widget_set_hexpand(cur, 1);
        c.gtk_label_set_ellipsize(@ptrCast(@alignCast(cur)), c.PANGO_ELLIPSIZE_START);
        c.gtk_widget_add_css_class(cur, "dim-label");
        c.gtk_widget_add_css_class(cur, "caption");
        c.gtk_widget_add_css_class(cur, "numeric");
        c.gtk_box_append(@ptrCast(detail), cur);

        if (row.state == .running) {
            spark = c.gtk_drawing_area_new();
            c.gtk_widget_set_size_request(spark, SPARK_W, SPARK_H);
            c.gtk_widget_set_valign(spark, c.GTK_ALIGN_CENTER);
            c.gtk_widget_set_tooltip_text(spark, "Recent throughput");
            spark_data = self.allocator.create(Spark) catch null;
            if (spark_data) |data| {
                data.* = .{ .allocator = self.allocator };
                data.take(&meter.sampler);
                c.gtk_drawing_area_set_draw_func(@ptrCast(spark), @ptrCast(&drawSpark), @ptrCast(data), @ptrCast(&Spark.free));
            }
            c.gtk_box_append(@ptrCast(detail), spark);
        }
        c.gtk_box_append(@ptrCast(card), detail);
    }

    var msg: ?*c.GtkWidget = null;
    if (row.state == .failed or row.state == .canceled or
        (row.state == .queued and row.message.len > 0))
    {
        msg = c.gtk_label_new("");
        c.gtk_label_set_xalign(@ptrCast(@alignCast(msg)), 0);
        c.gtk_label_set_ellipsize(@ptrCast(@alignCast(msg)), c.PANGO_ELLIPSIZE_END);
        c.gtk_label_set_selectable(@ptrCast(@alignCast(msg)), 1);
        c.gtk_widget_add_css_class(msg, "caption");
        c.gtk_widget_add_css_class(msg, if (row.state == .failed) "error" else "dim-label");
        c.gtk_widget_set_visible(msg, 0);
        c.gtk_box_append(@ptrCast(card), msg);
    }

    c.gtk_box_append(@ptrCast(parent), card);

    meter.state_icon = icon;
    meter.name_label = @ptrCast(@alignCast(name));
    meter.dest_label = @ptrCast(@alignCast(dest));
    meter.stats_label = @ptrCast(@alignCast(stats));
    meter.badge_label = @ptrCast(@alignCast(badge));
    meter.chip_resumed = chip_resumed;
    meter.cur_label = if (cur) |widget| @ptrCast(@alignCast(widget)) else null;
    meter.msg_label = if (msg) |widget| @ptrCast(@alignCast(widget)) else null;
    meter.bar = bar;
    meter.bar_data = bar_data;
    meter.spark = spark;
    meter.spark_data = spark_data;
    applyRow(row, meter);
}

fn onStripClick(_: ?*c.GtkGestureClick, _: c.gint, _: f64, _: f64, user: ?*anyopaque) callconv(.c) void {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    self.jobs_panel.center_open = !self.jobs_panel.center_open;
    self.renderJobs();
}

/// Tier 1: the one-line ambient strip. Ring + sentence + numbers +
/// Details toggle; a click anywhere on it opens the Transfer Center.
fn buildStrip(self: *BrowserView, parent: *c.GtkWidget, info: *const StripInfo) void {
    ensurePanelCss();
    const panel = &self.jobs_panel;
    const strip = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 10);
    c.gtk_widget_add_css_class(strip, "xfer-strip");

    const ring = c.gtk_drawing_area_new();
    c.gtk_widget_set_size_request(ring, 16, 16);
    c.gtk_widget_set_valign(ring, c.GTK_ALIGN_CENTER);
    const ring_data = self.allocator.create(RingData) catch null;
    if (ring_data) |data| {
        data.* = .{ .allocator = self.allocator };
        c.gtk_drawing_area_set_draw_func(@ptrCast(ring), @ptrCast(&drawRing), @ptrCast(data), @ptrCast(&RingData.free));
    }
    c.gtk_box_append(@ptrCast(strip), ring);

    const label = c.gtk_label_new("");
    c.gtk_label_set_xalign(@ptrCast(label), 0);
    c.gtk_widget_set_hexpand(label, 1);
    c.gtk_label_set_ellipsize(@ptrCast(label), c.PANGO_ELLIPSIZE_END);
    c.gtk_box_append(@ptrCast(strip), label);

    const nums = c.gtk_label_new("");
    c.gtk_label_set_xalign(@ptrCast(nums), 1);
    c.gtk_widget_add_css_class(nums, "numeric");
    c.gtk_widget_add_css_class(nums, "dim-label");
    c.gtk_box_append(@ptrCast(strip), nums);

    if (info.mode == .done or info.mode == .failed)
        jobsButton(self, strip, "edit-clear-all-symbolic", identityCtx(self, .{ .key = .{ .kind = .batch }, .label = "", .state = .finished }, .clear_done));
    jobsButton(
        self,
        strip,
        if (panel.center_open) "pan-down-symbolic" else "pan-up-symbolic",
        identityCtx(self, .{ .key = .{ .kind = .batch }, .label = "", .state = .running }, .center),
    );

    // A click on the strip itself (buttons keep their own clicks)
    // toggles the Transfer Center.
    const click = c.gtk_gesture_click_new();
    _ = c.g_signal_connect_data(click, "released", @ptrCast(&onStripClick), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_controller(strip, @ptrCast(click));

    c.gtk_box_append(@ptrCast(parent), strip);
    panel.strip_ring = ring;
    panel.ring_data = ring_data;
    panel.strip_label = @ptrCast(@alignCast(label));
    panel.strip_nums = @ptrCast(@alignCast(nums));
    applyStrip(panel, info);
}

/// Write the strip's dynamic content; shared by build and refresh.
fn applyStrip(panel: *Panel, info: *const StripInfo) void {
    if (panel.strip_label) |label| {
        var z: [280:0]u8 = undefined;
        c.gtk_label_set_text(label, copyZ(&z, info.text()));
        setColorClass(@ptrCast(@alignCast(label)), switch (info.mode) {
            .failed => "error",
            .done => "success",
            .queued_only => "dim-label",
            else => "accent",
        });
        // The sentence carries the meaning; only failure/success tint
        // it. An active line reads in the normal foreground.
        if (info.mode == .active) c.gtk_widget_remove_css_class(@ptrCast(@alignCast(label)), "accent");
    }
    if (panel.strip_nums) |nums| {
        var z: [112:0]u8 = undefined;
        c.gtk_label_set_text(nums, copyZ(&z, info.nums()));
    }
    if (panel.ring_data) |data| {
        data.fraction = info.fraction;
        data.indeterminate = info.indeterminate;
        data.kind = info.kind;
        if (panel.strip_ring) |ring| c.gtk_widget_queue_draw(ring);
    }
}

fn fraction(row: Row) f64 {
    if (row.state == .finished) return 1.0;
    if (row.total == 0) {
        // Bytes are the honest unit but not always fully known: a
        // batch's in-flight byte fractions still move the bar, so a
        // single large file no longer sits at 0% for minutes.
        if (row.frac_hint > 0) return @min(1.0, row.frac_hint);
        if (row.files_total == 0) return 0.0;
        return @min(1.0, @as(f64, @floatFromInt(row.files_done)) / @as(f64, @floatFromInt(row.files_total)));
    }
    const f = @as(f64, @floatFromInt(row.done)) / @as(f64, @floatFromInt(row.total));
    return @min(1.0, @max(0.0, f));
}

const ScrollState = struct {
    value: f64,
    at_bottom: bool,
};

const ScrollRestore = struct {
    allocator: std.mem.Allocator,
    adjustment: *c.GtkAdjustment,
    panel: *Panel,

    fn destroy(user: ?*anyopaque) callconv(.c) void {
        const self: *ScrollRestore = @ptrCast(@alignCast(user.?));
        c.g_object_unref(@as(?*anyopaque, @ptrCast(self.adjustment)));
        self.allocator.destroy(self);
    }
};

fn captureScroll(panel: *Panel) ?ScrollState {
    const scroller = panel.scroller orelse return null;
    const adjustment = c.gtk_scrolled_window_get_vadjustment(@ptrCast(@alignCast(scroller))) orelse return null;
    const value = c.gtk_adjustment_get_value(adjustment);
    const lower = c.gtk_adjustment_get_lower(adjustment);
    const bottom = c.gtk_adjustment_get_upper(adjustment) - c.gtk_adjustment_get_page_size(adjustment);
    return .{ .value = value, .at_bottom = bottom > lower + 1.0 and bottom - value <= 1.0 };
}

fn scrollTarget(state: ScrollState, lower: f64, upper: f64, page_size: f64) f64 {
    const bottom = @max(lower, upper - page_size);
    return if (state.at_bottom) bottom else std.math.clamp(state.value, lower, bottom);
}

fn restoreScroll(self: *BrowserView, scroller: *c.GtkWidget, state: ScrollState) void {
    const panel = &self.jobs_panel;
    if (panel.scroll_restore != 0) {
        _ = c.g_source_remove(panel.scroll_restore);
        panel.scroll_restore = 0;
    }
    const adjustment = c.gtk_scrolled_window_get_vadjustment(@ptrCast(@alignCast(scroller))) orelse return;
    const ctx = self.allocator.create(ScrollRestore) catch return;
    _ = c.g_object_ref(@as(?*anyopaque, @ptrCast(adjustment)));
    panel.scroll_state = state;
    ctx.* = .{ .allocator = self.allocator, .adjustment = adjustment, .panel = panel };
    panel.scroll_restore = c.g_idle_add_full(
        c.G_PRIORITY_DEFAULT_IDLE,
        @ptrCast(&restoreScrollIdle),
        @ptrCast(ctx),
        @ptrCast(&ScrollRestore.destroy),
    );
}

fn restoreScrollIdle(user: ?*anyopaque) callconv(.c) c.gboolean {
    const ctx: *ScrollRestore = @ptrCast(@alignCast(user.?));
    const adjustment = ctx.adjustment;
    const state = ctx.panel.scroll_state orelse return 0;
    c.gtk_adjustment_set_value(adjustment, scrollTarget(
        state,
        c.gtk_adjustment_get_lower(adjustment),
        c.gtk_adjustment_get_upper(adjustment),
        c.gtk_adjustment_get_page_size(adjustment),
    ));
    ctx.panel.scroll_state = null;
    ctx.panel.scroll_restore = 0;
    return 0;
}

fn rebuild(self: *BrowserView, rows: []const Row, info: *const StripInfo) void {
    const panel = &self.jobs_panel;
    const old_scroll = panel.scroll_state orelse captureScroll(panel);
    if (panel.scroll_restore != 0) {
        _ = c.g_source_remove(panel.scroll_restore);
        panel.scroll_restore = 0;
    }
    while (c.gtk_widget_get_first_child(self.jobs_box)) |child| {
        c.gtk_box_remove(@ptrCast(self.jobs_box), child);
    }
    // Widgets are gone: no meter may keep a pointer into them, and the
    // rows that vanished can now release their measurement state.
    for (panel.meters.items) |m| m.forgetWidgets();
    panel.rows_box = null;
    panel.summary = null;
    panel.strip_label = null;
    panel.strip_nums = null;
    panel.strip_ring = null;
    panel.ring_data = null;
    panel.scroller = null;
    dropUnseenMeters(self);
    if (rows.len == 0) {
        panel.scroll_state = null;
        panel.built = false;
        return;
    }

    // Tier 2 above tier 1: the Transfer Center opens upward from the
    // strip, scrolling inside a bounded height so many cards never
    // push the listing off the pane.
    if (panel.center_open) {
        const center = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 6);
        c.gtk_widget_set_margin_start(center, 8);
        c.gtk_widget_set_margin_end(center, 8);
        c.gtk_widget_set_margin_top(center, 6);

        const header = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 10);
        const title = c.gtk_label_new("Transfers");
        c.gtk_widget_add_css_class(title, "heading");
        c.gtk_box_append(@ptrCast(header), title);
        var sbuf: [128]u8 = undefined;
        var sz: [160:0]u8 = undefined;
        const summary = c.gtk_label_new(copyZ(&sz, centerSummary(&sbuf, rows, panel)));
        c.gtk_label_set_xalign(@ptrCast(summary), 0);
        c.gtk_widget_set_hexpand(summary, 1);
        c.gtk_widget_add_css_class(summary, "dim-label");
        c.gtk_box_append(@ptrCast(header), summary);
        panel.summary = @ptrCast(@alignCast(summary));
        jobsButton(self, header, "edit-clear-all-symbolic", identityCtx(self, .{ .key = .{ .kind = .batch }, .label = "", .state = .finished }, .clear_done));
        c.gtk_box_append(@ptrCast(center), header);

        const scroller = c.gtk_scrolled_window_new();
        c.gtk_scrolled_window_set_policy(@ptrCast(scroller), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
        c.gtk_scrolled_window_set_propagate_natural_height(@ptrCast(scroller), 1);
        c.gtk_scrolled_window_set_max_content_height(@ptrCast(scroller), CENTER_MAX_HEIGHT);
        const rows_box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 6);
        for (rows) |r| {
            const meter = panel.find(r.key) orelse continue;
            buildCard(self, rows_box, r, meter);
        }
        c.gtk_scrolled_window_set_child(@ptrCast(scroller), rows_box);
        c.gtk_box_append(@ptrCast(center), scroller);
        c.gtk_box_append(@ptrCast(self.jobs_box), center);
        panel.rows_box = rows_box;
        panel.scroller = scroller;
    }

    buildStrip(self, self.jobs_box, info);
    panel.built = true;
    if (panel.center_open) {
        if (old_scroll) |state| {
            if (panel.scroller) |scroller| restoreScroll(self, scroller, state);
        }
    }
}

fn refresh(self: *BrowserView, rows: []const Row, info: *const StripInfo) void {
    const panel = &self.jobs_panel;
    if (panel.center_open) {
        for (rows) |r| {
            const meter = panel.find(r.key) orelse continue;
            applyRow(r, meter);
        }
        if (panel.summary) |summary| {
            var sbuf: [128]u8 = undefined;
            var sz: [160:0]u8 = undefined;
            c.gtk_label_set_text(summary, copyZ(&sz, centerSummary(&sbuf, rows, panel)));
        }
    }
    applyStrip(panel, info);
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

/// A card keeps its position for its lifetime: top-level rows sort by
/// their meter's first-seen order, and a batch's expanded children
/// follow their parent. Without this, state changes reshuffled the
/// list under the cursor.
fn orderedRows(self: *BrowserView, arena: std.mem.Allocator, rows: []const Row) []Row {
    const panel = &self.jobs_panel;
    const Keyed = struct {
        row: Row,
        ord: u64,

        fn lessThan(_: void, a: @This(), b: @This()) bool {
            return a.ord < b.ord;
        }
    };
    var tops: std.ArrayList(Keyed) = .empty;
    for (rows) |r| {
        if (r.batch_child) continue;
        const ord = if (panel.find(r.key)) |m| m.order else std.math.maxInt(u64);
        tops.append(arena, .{ .row = r, .ord = ord }) catch return @constCast(rows);
    }
    std.mem.sort(Keyed, tops.items, {}, Keyed.lessThan);
    var out: std.ArrayList(Row) = .empty;
    for (tops.items) |top| {
        out.append(arena, top.row) catch return @constCast(rows);
        if (top.row.key.kind != .batch) continue;
        for (rows) |r| {
            if (r.batch_child and r.batch_id == top.row.key.job)
                out.append(arena, r) catch return @constCast(rows);
        }
    }
    return out.items;
}

/// Rebuild or refresh the two-tier transfers UI (hidden when empty).
pub fn renderJobs(self: *BrowserView) void {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const raw = collectRows(self, arena.allocator());
    const grouped = groupedRows(self, arena.allocator(), raw);
    c.gtk_widget_set_visible(self.jobs_box, if (grouped.len > 0) 1 else 0);
    syncMeters(self, grouped);
    const rows = orderedRows(self, arena.allocator(), grouped);
    const info = stripInfo(rows, &self.jobs_panel);
    var h = std.hash.Wyhash.init(signature(rows, &self.jobs_panel));
    h.update(std.mem.asBytes(&self.jobs_panel.center_open));
    h.update(std.mem.asBytes(&@intFromEnum(info.mode)));
    const sig = h.final();
    if (self.jobs_panel.built and sig == self.jobs_panel.signature) {
        refresh(self, rows, &info);
    } else {
        rebuild(self, rows, &info);
        self.jobs_panel.signature = sig;
    }
    armTick(self, rows);
}

test "strip aggregates an active transfer into one honest line" {
    var panel = Panel{};
    const rows = [_]Row{
        .{
            .key = .{ .kind = .durable },
            .label = "video-project.bin",
            .name = "video-project.bin",
            .dest_host = "mercer",
            .state = .running,
            .done = 350 << 20,
            .total = 700 << 20,
        },
        .{ .key = .{ .kind = .copy, .ptr = 1 }, .label = "next", .name = "next", .state = .queued },
    };
    const info = stripInfo(&rows, &panel);
    try std.testing.expectEqual(StripMode.active, info.mode);
    try std.testing.expectEqualStrings("Copying 2 items to mercer — video-project.bin", info.text());
    // Half of one item plus a queued one: 25%.
    try std.testing.expect(info.fraction > 0.24 and info.fraction < 0.26);
}

test "strip failure and completion lines" {
    var panel = Panel{};
    const failed = [_]Row{.{
        .key = .{ .kind = .daemon, .ptr = 1, .job = 7 },
        .label = "big.bin",
        .name = "big.bin",
        .state = .failed,
        .message = "the copy is complete and installed; delete failed",
    }};
    const fail_info = stripInfo(&failed, &panel);
    try std.testing.expectEqual(StripMode.failed, fail_info.mode);
    try std.testing.expectEqualStrings(
        "1 transfer failed — the copy is complete and installed; delete failed",
        fail_info.text(),
    );
    const done = [_]Row{.{
        .key = .{ .kind = .daemon, .ptr = 1, .job = 8 },
        .label = "big.bin",
        .name = "big.bin",
        .state = .finished,
        .total = 1 << 30,
    }};
    const done_info = stripInfo(&done, &panel);
    try std.testing.expectEqual(StripMode.done, done_info.mode);
    try std.testing.expectEqualStrings("Copied 1 item — 1.0 GB", done_info.text());
}

test "batch fraction moves with the running member's bytes" {
    // Two files, byte total unknown for the queued one: the hint keeps
    // the bar honest instead of parking it at 0%.
    try std.testing.expectApproxEqAbs(@as(f64, 0.31), fraction(.{
        .key = .{ .kind = .batch, .job = 1 },
        .label = "batch",
        .state = .running,
        .frac_hint = 0.31,
        .files_total = 2,
    }), 0.0001);
}

test "batch state and progress stay aggregate" {
    try std.testing.expectEqual(RowState.running, batchState(.{ .id = 1, .running = 1, .queued = 399 }));
    try std.testing.expectEqual(RowState.failed, batchState(.{ .id = 1, .finished = 399, .failed = 1 }));
    try std.testing.expectEqual(RowState.finished, batchState(.{ .id = 1, .expected = 10, .children = 8, .finished = 8 }));
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), fraction(.{
        .key = .{ .kind = .batch, .job = 1 },
        .label = "batch",
        .state = .running,
        .files_done = 100,
        .files_total = 400,
    }), 0.0001);
}

test "panel scroll restoration preserves position and bottom following" {
    try std.testing.expectEqual(@as(f64, 75), scrollTarget(.{ .value = 75, .at_bottom = false }, 0, 500, 100));
    try std.testing.expectEqual(@as(f64, 400), scrollTarget(.{ .value = 300, .at_bottom = true }, 0, 500, 100));
    try std.testing.expectEqual(@as(f64, 40), scrollTarget(.{ .value = 75, .at_bottom = false }, 0, 100, 60));
}
