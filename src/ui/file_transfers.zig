//! Process-level durable downloads, sync-back uploads and the records
//! of client-mediated transfers.
//!
//! Ownership is PER RECORD (see filebrowser/transfers.zig): every
//! durable transfer is its own locked file, so any number of GUI
//! processes run their own transfers at the same time and a record
//! whose owner died is adopted -- exactly once, because adoption IS
//! taking the record's lock. Nothing here is a singleton across
//! processes any more; the only single-process rule left is the
//! `shared` service below, so one process has one owner per record.
//!
//! Three record kinds live here:
//!   * daemon-coordinated downloads/uploads, submitted as `cross_copy`
//!     jobs and driven by this service directly;
//!   * client-mediated transfers (fstransfer), which need a browser
//!     face with both host connections to run. Those are adopted only
//!     while a DRIVER is registered, and handed to it.
//!   * batch admission manifests, one fsynced command whose fixed child
//!     tokens are materialized incrementally by that same driver.

const std = @import("std");
const c = @import("../c.zig").c;
const muxclient = @import("../mux/client.zig");
const wire = @import("../mux/wire.zig");
const store = @import("../filebrowser/transfers.zig");
const xferqueue = @import("../filebrowser/xferqueue.zig");
const pathz = @import("../util/pathz.zig");
const cast = @import("../util/cast.zig");
const nowMs = @import("../util/clock.zig").nowMs;
const wallMs = @import("../util/clock.zig").wallMs;

pub const NotifyFn = *const fn (ctx: *anyopaque, text: []const u8) void;
const Subscriber = struct { ctx: *anyopaque, callback: NotifyFn };

/// How often orphaned records (an owner that crashed) are looked for.
const SWEEP_MS: c.guint = 15_000;
pub const AUTO_RETRIES: u8 = 3;
pub const RETRY_DELAY_MS: c.guint = 5_000;

pub fn retryableFailureKind(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "transport") or std.mem.eql(u8, kind, "unreachable");
}

pub fn automaticRetryAllowed(failures: u8, retryable: bool) bool {
    return retryable and failures <= AUTO_RETRIES;
}

fn transferRetryEligible(it: *const Intent) bool {
    if (it.state != .waiting_retry) return false;
    return !it.cancel_requested or it.job != 0 or it.submission_uncertain or it.mediated;
}

fn cancelNeedsSubmissionRecovery(it: *const Intent) bool {
    return (it.state == .queued or it.state == .waiting_retry) and
        it.submission_uncertain and it.ack_job == 0;
}

const Intent = struct {
    handle: store.Handle,
    record_version: u32 = store.VERSION,
    /// Record identity (ledger file name, panel row key).
    token: []u8,
    /// Daemon idempotency key; re-minted on every retry, which is why
    /// it is not the record identity.
    client_token: []u8,
    kind: store.Kind,
    src_host: []u8,
    src_path: []u8,
    dst_host: []u8,
    dst_path: []u8,
    app_id: []u8,
    state: store.State,
    job: u64,
    order: u64,
    watch_token: []u8,
    submitted_generation: u64,
    message: []u8,
    attempts: u8 = 0,
    /// Volatile monotonic deadline for the visible retry countdown.
    retry_due_ms: i64 = 0,
    cancel_requested: bool = false,
    submitted_size: u64 = 0,
    submitted_mtime_ns: i64 = 0,
    /// User-held: never submitted, and SIGSTOPped daemon-side while
    /// running. Persisted, so a pause survives a GUI restart.
    paused: bool = false,
    /// The daemon job is paused but this client has no id for it yet
    /// (the pause outlived the connection); resume once it replies.
    resume_pending: bool = false,
    /// Terminal daemon job still owed a job_ack, and the in-flight
    /// request carrying it.
    ack_job: u64 = 0,
    ack_req: u32 = 0,
    /// The current ack_job identity is present in the on-disk record.
    ack_durable: bool = false,
    /// Finished; the record exists only until its ack lands.
    retired: bool = false,
    /// Client-mediated: run by a registered driver, not by this
    /// service. `claimed` means the driver currently holds it.
    mediated: bool = false,
    user_copy: bool = false,
    batch_id: u64 = 0,
    batch_total: u64 = 0,
    batch_token: []u8,
    coordinator_host: []u8,
    coordinator_set: bool = false,
    submission_uncertain: bool = false,
    ack_host: []u8,
    claimed: bool = false,
    open_when_done: bool = false,
    delete_src_after: bool = false,
    no_replace: bool = false,
    watch_after: bool = false,
    /// Scheduler identity of the destination (host plus local device).
    dest_key: u64 = 0,
    /// Live progress from the daemon's job events; volatile, the
    /// daemon replays it after every reconnect.
    done: u64 = 0,
    total: u64 = 0,
    resumed_from: u64 = 0,
    /// The view (driver ctx) that submitted this record, or null for
    /// records without one (restart recovery, watch sync-backs).
    /// Volatile on purpose: it routes the PANEL ROW to the pane that
    /// started the transfer, so a split view does not show every
    /// download twice; ownership/recovery ignore it.
    origin: ?*anyopaque = null,

    fn record(self: *const Intent) store.Record {
        return .{
            .version = self.record_version,
            .rtype = .intent,
            .intent = .{
                .token = self.token,
                .client_token = self.client_token,
                .kind = self.kind,
                .src = .{ .host = self.src_host, .path = self.src_path },
                .dst = .{ .host = self.dst_host, .path = self.dst_path },
                .app_id = self.app_id,
                .state = self.state,
                .job = self.job,
                .order = self.order,
                .watch_token = self.watch_token,
                .submitted_generation = self.submitted_generation,
                .message = self.message,
                .attempts = self.attempts,
                .cancel_requested = self.cancel_requested,
                .submitted_size = self.submitted_size,
                .submitted_mtime_ns = self.submitted_mtime_ns,
                .paused = self.paused,
                .ack_job = self.ack_job,
                .retired = self.retired,
                .mediated = self.mediated,
                .user_copy = self.user_copy,
                .batch_id = self.batch_id,
                .batch_total = self.batch_total,
                .batch_token = self.batch_token,
                .coordinator_host = self.coordinator_host,
                .coordinator_set = self.coordinator_set,
                .submission_uncertain = self.submission_uncertain,
                .ack_host = self.ack_host,
                .open_when_done = self.open_when_done,
                .delete_src_after = self.delete_src_after,
                .no_replace = self.no_replace,
                .watch_after = self.watch_after,
            },
        };
    }

    fn destroy(self: *Intent, a: std.mem.Allocator) void {
        inline for (.{ self.token, self.client_token, self.src_host, self.src_path, self.dst_host, self.dst_path, self.app_id, self.watch_token, self.message, self.coordinator_host, self.ack_host, self.batch_token }) |s|
            a.free(s);
        a.destroy(self);
    }
};

/// One all-or-nothing durable mutation of an Intent.
///
/// The snapshot is the WHOLE record, so a field added to Intent is
/// rolled back without touching any call site; the mutation itself runs
/// between `begin` and `commit`. Slices the mutation allocated are
/// still the caller's to free on failure -- `saved` holds the pointers
/// it replaced, which is also where a successful caller finds the old
/// ones to release.
const IntentTxn = struct {
    service: *Service,
    intent: *Intent,
    saved: Intent,

    fn begin(service: *Service, it: *Intent) IntentTxn {
        return .{ .service = service, .intent = it, .saved = it.* };
    }

    /// @return false after restoring every field, when the record could
    /// not be persisted.
    fn commit(self: IntentTxn) bool {
        if (self.service.writeIntentOk(self.intent)) return true;
        self.intent.* = self.saved;
        return false;
    }
};

const Watch = struct {
    service: *Service,
    handle: store.Handle,
    token: []u8,
    host: []u8,
    remote_path: []u8,
    cache_path: []u8,
    dirty_generation: u64,
    synced_generation: u64,
    synced_size: u64,
    synced_mtime_ns: i64,
    monitor: ?*c.GFileMonitor = null,

    fn record(self: *const Watch) store.Record {
        return .{
            .rtype = .watch,
            .watch = .{
                .token = self.token,
                .host = self.host,
                .remote_path = self.remote_path,
                .cache_path = self.cache_path,
                .dirty_generation = self.dirty_generation,
                .synced_generation = self.synced_generation,
                .synced_size = self.synced_size,
                .synced_mtime_ns = self.synced_mtime_ns,
            },
        };
    }

    fn destroy(self: *Watch, a: std.mem.Allocator) void {
        if (self.monitor) |m| {
            _ = c.g_file_monitor_cancel(m);
            c.g_object_unref(m);
        }
        a.free(self.token);
        a.free(self.host);
        a.free(self.remote_path);
        a.free(self.cache_path);
        a.destroy(self);
    }
};

pub const BatchItemRec = struct {
    token: []u8,
    src_path: []u8,
    dst_path: []u8,
    conflict_is_dir: ?bool = null,

    fn destroy(self: BatchItemRec, allocator: std.mem.Allocator) void {
        allocator.free(self.token);
        allocator.free(self.src_path);
        allocator.free(self.dst_path);
    }
};

fn dupBatchItem(allocator: std.mem.Allocator, item: store.BatchItem) !BatchItemRec {
    const token = try allocator.dupe(u8, item.token);
    errdefer allocator.free(token);
    const src_path = try allocator.dupe(u8, item.src_path);
    errdefer allocator.free(src_path);
    const dst_path = try allocator.dupe(u8, item.dst_path);
    return .{
        .token = token,
        .src_path = src_path,
        .dst_path = dst_path,
        .conflict_is_dir = item.conflict_is_dir,
    };
}

const UserBatch = struct {
    handle: store.Handle,
    token: []u8,
    batch_id: u64,
    batch_total: u64,
    src_host: []u8,
    dst_host: []u8,
    move: bool,
    no_replace: bool,
    items: []BatchItemRec,
    /// Volatile driver identity. The durable lock belongs to the
    /// service; this only prevents two panes in one process from
    /// materializing the same manifest concurrently.
    owner: ?*anyopaque = null,

    fn record(self: *const UserBatch, allocator: std.mem.Allocator) !store.Record {
        const items = try allocator.alloc(store.BatchItem, self.items.len);
        for (self.items, 0..) |item, i| items[i] = .{
            .token = item.token,
            .src_path = item.src_path,
            .dst_path = item.dst_path,
            .conflict_is_dir = item.conflict_is_dir,
        };
        return .{ .rtype = .batch, .batch = .{
            .token = self.token,
            .batch_id = self.batch_id,
            .batch_total = self.batch_total,
            .src_host = self.src_host,
            .dst_host = self.dst_host,
            .move = self.move,
            .no_replace = self.no_replace,
            .items = items,
        } };
    }

    fn destroy(self: *UserBatch, allocator: std.mem.Allocator) void {
        allocator.free(self.token);
        allocator.free(self.src_host);
        allocator.free(self.dst_host);
        for (self.items) |item| item.destroy(allocator);
        allocator.free(self.items);
        allocator.destroy(self);
    }
};

const Pending = struct { req: u32, intent: *Intent };

pub const QueueRow = struct {
    token: []const u8,
    label: []const u8,
    state: store.State,
    done: u64,
    total: u64,
    kind: store.Kind = .download,
    paused: bool = false,
    src_host: []const u8 = "",
    src_path: []const u8 = "",
    dst_host: []const u8 = "",
    dst_path: []const u8 = "",
    resumed_from: u64 = 0,
    message: []const u8 = "",
    mediated: bool = false,
    batch_id: u64 = 0,
    batch_total: u64 = 0,
    delete_src_after: bool = false,
    attempts: u8 = 0,
    retry_due_ms: i64 = 0,
};

/// One client-mediated transfer as handed to a driver.
pub const MediatedRec = struct {
    record_version: u32,
    token: []const u8,
    client_token: []const u8,
    src_host: []const u8,
    src_path: []const u8,
    dst_host: []const u8,
    dst_path: []const u8,
    app_id: []const u8,
    paused: bool,
    open_when_done: bool,
    delete_src_after: bool,
    no_replace: bool,
    watch_after: bool,
    user_copy: bool,
    batch_id: u64,
    batch_total: u64,
    coordinator_host: []const u8,
    coordinator_set: bool,
    ack_host: []const u8,
    ack_job: u64,
    cancel_requested: bool,
    retired: bool,
    attempts: u8,
    state: store.State,
};

pub const BatchSpec = struct {
    src_path: []const u8,
    dst_path: []const u8,
    conflict_is_dir: ?bool = null,
};
pub const BatchRec = struct {
    token: []const u8,
    batch_id: u64,
    batch_total: u64,
    src_host: []const u8,
    dst_host: []const u8,
    move: bool,
    no_replace: bool,
    items: []const BatchItemRec,
};

pub const MediatedFn = *const fn (ctx: *anyopaque, rec: MediatedRec) void;
pub const BatchFn = *const fn (ctx: *anyopaque, rec: BatchRec) void;
/// Repaint the jobs/transfers panel: rows can appear without any user
/// action here (an adopted orphan, a sync-back queued by a watch), and
/// the panel's own sampling tick only runs while rows already exist.
pub const RefreshFn = *const fn (ctx: *anyopaque) void;
const Driver = struct { ctx: *anyopaque, callback: MediatedFn, batch_callback: BatchFn, refresh: RefreshFn };

pub const Service = struct {
    allocator: std.mem.Allocator,
    conn: ?muxclient.Conn = null,
    fd_watch: c.guint = 0,
    retry_source: c.guint = 0,
    transfer_retry_source: c.guint = 0,
    sweep_source: c.guint = 0,
    next_req: u32 = 1,
    order_seq: u64 = 0,
    intents: std.ArrayList(*Intent) = .empty,
    watches: std.ArrayList(*Watch) = .empty,
    batches: std.ArrayList(*UserBatch) = .empty,
    pending: std.ArrayList(Pending) = .empty,
    subscribers: std.ArrayList(Subscriber) = .empty,
    drivers: std.ArrayList(Driver) = .empty,
    shutting_down: bool = false,
    refs: usize = 1,
    retry_delay_ms: c.guint = 1000,
    durability_error: bool = false,
    disconnect_after_drain: bool = false,
    in_fd_callback: bool = false,
    legacy_lock: ?store.LegacyLock = null,

    pub fn init(allocator: std.mem.Allocator, notify_ctx: ?*anyopaque, notify_fn: ?NotifyFn) !*Service {
        const self = try allocator.create(Service);
        self.* = .{ .allocator = allocator };
        errdefer self.deinit();
        if (notify_ctx != null and notify_fn != null)
            try self.subscribers.append(allocator, .{ .ctx = notify_ctx.?, .callback = notify_fn.? });
        // A ledger directory we cannot even create means no durable
        // transfer can be recorded; the caller degrades honestly.
        try self.probeLedger();
        self.migrateLegacy();
        self.adoptOrphans();
        self.connect();
        self.sweep_source = c.g_timeout_add(SWEEP_MS, @ptrCast(&onSweep), @ptrCast(self));
        self.pump();
        return self;
    }

    pub fn deinit(self: *Service) void {
        self.shutting_down = true;
        self.persist();
        if (self.sweep_source != 0) _ = c.g_source_remove(self.sweep_source);
        if (self.retry_source != 0) _ = c.g_source_remove(self.retry_source);
        if (self.transfer_retry_source != 0) _ = c.g_source_remove(self.transfer_retry_source);
        if (self.fd_watch != 0) _ = c.g_source_remove(self.fd_watch);
        if (self.conn) |*conn| conn.deinit();
        if (self.legacy_lock) |lock| lock.release();
        for (self.intents.items) |it| {
            it.handle.release();
            it.destroy(self.allocator);
        }
        self.intents.deinit(self.allocator);
        for (self.watches.items) |w| {
            w.handle.release();
            w.destroy(self.allocator);
        }
        self.watches.deinit(self.allocator);
        for (self.batches.items) |batch| {
            batch.handle.release();
            batch.destroy(self.allocator);
        }
        self.batches.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.subscribers.deinit(self.allocator);
        self.drivers.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn probeLedger(self: *Service) !void {
        const dir = try store.dirPath(self.allocator);
        defer self.allocator.free(dir);
        var probe: [4096]u8 = undefined;
        const inside = std.fmt.bufPrint(&probe, "{s}/x", .{dir}) catch return error.TransferLedgerUnavailable;
        pathz.makeParentDirs(inside) catch return error.TransferLedgerUnavailable;
        var z: [4096]u8 = undefined;
        _ = c.mkdir(pathz.pathZ(&z, dir) catch return error.TransferLedgerUnavailable, 0o700);
        var st: c.struct_stat = undefined;
        if (c.stat(pathz.pathZ(&z, dir) catch return error.TransferLedgerUnavailable, &st) != 0)
            return error.TransferLedgerUnavailable;
    }

    fn notify(self: *Service, comptime fmt: []const u8, args: anytype) void {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch fmt;
        for (self.subscribers.items) |subscriber| subscriber.callback(subscriber.ctx, msg);
    }

    // ── record ownership ────────────────────────────────────────

    fn ownsIntent(self: *Service, token: []const u8) bool {
        for (self.intents.items) |it| if (std.mem.eql(u8, it.token, token)) return true;
        return false;
    }

    fn ownsWatch(self: *Service, token: []const u8) bool {
        for (self.watches.items) |w| if (std.mem.eql(u8, w.token, token)) return true;
        return false;
    }

    fn ownsBatch(self: *Service, token: []const u8) bool {
        for (self.batches.items) |batch| if (std.mem.eql(u8, batch.token, token)) return true;
        return false;
    }

    /// Take over every record no live process owns. Called at startup
    /// and on a timer: a peer GUI can die at any moment, and its
    /// transfers must not wait for a restart of THIS one.
    fn adoptOrphans(self: *Service) void {
        const entries = store.list(self.allocator) catch return;
        defer store.freeList(self.allocator, entries);
        // Parents are loaded before children regardless of readdir
        // order. The child also carries its parent token for the case
        // where another process still owns that parent lock.
        for ([_]store.RType{ .batch, .intent, .watch }) |rtype| {
            for (entries) |e| {
                if (e.rtype != rtype) continue;
                switch (e.rtype) {
                    .intent => if (self.ownsIntent(e.token)) continue,
                    .watch => if (self.ownsWatch(e.token)) continue,
                    .batch => if (self.ownsBatch(e.token)) continue,
                }
                var handle = (store.open(self.allocator, e.rtype, e.token) catch continue) orelse continue;
                const parsed = store.readFile(self.allocator, handle.json_path) catch {
                    // An unreadable record may be transient I/O failure or
                    // memory pressure. Keep it for a later sweep rather
                    // than converting a read failure into data loss.
                    handle.release();
                    self.notify("cannot read transfer recovery state; retrying", .{});
                    continue;
                };
                const rec = parsed orelse {
                    // A lock with no record: debris of an owner that died
                    // between creating the lock and writing the record.
                    _ = handle.destroyRecord();
                    continue;
                };
                defer rec.deinit();
                if (!store.readableVersion(rec.value.version)) {
                    handle.release();
                    continue;
                }
                switch (e.rtype) {
                    .intent => {
                        const value = rec.value.intent;
                        if (value.batch_token.len > 0 and self.batchByToken(value.batch_token) == null and self.childManifestExists(value.token, value.batch_token)) {
                            // Another process owns the parent. Do not split
                            // the lock set by retaining one of its children;
                            // the parent owner will acquire it on a later
                            // sweep, or this process will acquire both after
                            // that owner exits.
                            handle.release();
                            continue;
                        }
                        if ((value.retired or value.state == .done or value.state == .canceled) and value.ack_job == 0 and !self.childManifestExists(value.token, value.batch_token)) {
                            _ = handle.destroyRecord();
                            continue;
                        }
                        if (value.mediated and self.drivers.items.len == 0) {
                            // Nothing here can run it; leave it adoptable.
                            handle.release();
                            continue;
                        }
                        const it = self.dupIntent(handle, value) catch {
                            handle.release();
                            continue;
                        };
                        it.record_version = rec.value.version;
                        if (it.record_version < store.VERSION and it.mediated and it.job != 0) {
                            it.state = .failed;
                            it.claimed = false;
                            self.replaceMessage(it, "legacy transfer held because its running job identity is not durable");
                        }
                        self.intents.append(self.allocator, it) catch {
                            it.handle.release();
                            it.destroy(self.allocator);
                            continue;
                        };
                    },
                    .watch => {
                        const w = self.dupWatch(handle, rec.value.watch) catch {
                            handle.release();
                            continue;
                        };
                        self.watches.append(self.allocator, w) catch {
                            w.handle.release();
                            w.destroy(self.allocator);
                            continue;
                        };
                        self.armWatch(w);
                        self.detectOfflineEdit(w);
                    },
                    .batch => {
                        if (self.drivers.items.len == 0) {
                            handle.release();
                            continue;
                        }
                        const batch = self.dupBatch(handle, rec.value.batch) catch {
                            handle.release();
                            continue;
                        };
                        if (batch.items.len == 0) {
                            _ = batch.handle.destroyRecord();
                            batch.destroy(self.allocator);
                            continue;
                        }
                        self.batches.append(self.allocator, batch) catch {
                            batch.handle.release();
                            batch.destroy(self.allocator);
                            continue;
                        };
                    },
                }
            }
        }
        // Dispatch AFTER the scan: a driver may call back into the
        // service, and the lists must be settled first.
        self.handLooseIntents();
        self.handAllBatches();
        self.queueDirtyWatches();
        self.armTransferRetry();
        self.refreshViews();
    }

    fn onSweep(user: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast.userData(Service, user);
        if (self.shutting_down) return 0;
        self.migrateLegacy();
        self.adoptOrphans();
        self.persist();
        self.pump();
        return 1;
    }

    /// Import a pre-upgrade single-document ledger, once.
    fn migrateLegacy(self: *Service) void {
        if (self.legacy_lock == null) self.legacy_lock = (store.lockLegacy(self.allocator) catch return) orelse {
            // A pre-upgrade binary still owns that document and is
            // still running those transfers; importing them here would
            // run every one of them twice.
            return;
        };
        const parsed = (store.loadLegacy(self.allocator) catch {
            self.notify("the old transfer ledger is unreadable; it was left in place", .{});
            self.legacy_lock.?.release();
            self.legacy_lock = null;
            return;
        }) orelse {
            self.legacy_lock.?.release();
            self.legacy_lock = null;
            return;
        };
        defer parsed.deinit();
        var imported: usize = 0;
        var migration_ok = true;
        for (parsed.value.intents) |value| {
            if (value.state == .canceled) continue;
            if (value.token.len == 0) continue;
            if (self.intentByToken(value.token)) |it| {
                if (!self.writeIntentOk(it)) migration_ok = false;
            } else if (self.importIntent(value, parsed.value.acknowledgments)) {
                imported += 1;
            } else migration_ok = false;
        }
        for (parsed.value.watches) |value| {
            if (value.token.len == 0) continue;
            if (self.watchByToken(value.token)) |w| {
                self.writeWatch(w);
                if (self.durability_error) {
                    migration_ok = false;
                } else {
                    self.armWatch(w);
                }
            } else if (self.importWatch(value)) {
                imported += 1;
            } else migration_ok = false;
        }
        // Acknowledgments with no surviving intent still have to reach
        // the daemon: carry each in a retired record of its own.
        for (parsed.value.acknowledgments) |job| {
            var covered = false;
            for (self.intents.items) |it| if (it.ack_job == job) {
                covered = true;
                break;
            };
            if (!covered and self.importAck(job)) imported += 1 else if (!covered) migration_ok = false;
        }
        if (!migration_ok) {
            self.notify("the old transfer ledger is only partly imported; retrying", .{});
            return;
        }
        if (!store.retireLegacy(self.allocator)) {
            self.notify("the old transfer ledger could not be retired; retrying", .{});
            return;
        }
        self.legacy_lock.?.release();
        self.legacy_lock = null;
        if (imported > 0) self.notify("imported {d} transfer record(s) from the old ledger", .{imported});
    }

    fn importIntent(self: *Service, value: store.Intent, acks: []const u64) bool {
        var handle = (store.open(self.allocator, .intent, value.token) catch return false) orelse return false;
        const it = self.dupIntent(handle, value) catch {
            handle.release();
            return false;
        };
        for (acks) |job| {
            if (job != 0 and job == value.job) {
                it.ack_job = job;
                it.ack_durable = false;
            }
        }
        self.intents.append(self.allocator, it) catch {
            it.handle.release();
            it.destroy(self.allocator);
            return false;
        };
        return self.writeIntentOk(it);
    }

    fn importWatch(self: *Service, value: store.Watch) bool {
        var handle = (store.open(self.allocator, .watch, value.token) catch return false) orelse return false;
        const w = self.dupWatch(handle, value) catch {
            handle.release();
            return false;
        };
        self.watches.append(self.allocator, w) catch {
            w.handle.release();
            w.destroy(self.allocator);
            return false;
        };
        self.writeWatch(w);
        const written = !self.durability_error;
        self.armWatch(w);
        self.detectOfflineEdit(w);
        return written or !self.durability_error;
    }

    fn importAck(self: *Service, job: u64) bool {
        const token = self.newToken() catch return false;
        defer self.allocator.free(token);
        var handle = (store.open(self.allocator, .intent, token) catch return false) orelse return false;
        const it = self.dupIntent(handle, .{
            .token = token,
            .state = .done,
            .job = job,
            .ack_job = job,
            .retired = true,
        }) catch {
            handle.release();
            return false;
        };
        it.ack_durable = false;
        self.intents.append(self.allocator, it) catch {
            it.handle.release();
            it.destroy(self.allocator);
            return false;
        };
        return self.writeIntentOk(it);
    }

    fn dupIntent(self: *Service, handle: store.Handle, value: store.Intent) !*Intent {
        const a = self.allocator;
        const it = try a.create(Intent);
        errdefer a.destroy(it);
        const token = try a.dupe(u8, value.token);
        errdefer a.free(token);
        // A record written before client_token existed used its
        // identity as the idempotency key.
        const client_token = try a.dupe(u8, if (value.client_token.len > 0) value.client_token else value.token);
        errdefer a.free(client_token);
        const src_host = try a.dupe(u8, value.src.host);
        errdefer a.free(src_host);
        const src_path = try a.dupe(u8, value.src.path);
        errdefer a.free(src_path);
        const dst_host = try a.dupe(u8, value.dst.host);
        errdefer a.free(dst_host);
        const dst_path = try a.dupe(u8, value.dst.path);
        errdefer a.free(dst_path);
        const app_id = try a.dupe(u8, value.app_id);
        errdefer a.free(app_id);
        const watch_token = try a.dupe(u8, value.watch_token);
        errdefer a.free(watch_token);
        const message = try a.dupe(u8, value.message);
        errdefer a.free(message);
        const coordinator_host = try a.dupe(u8, value.coordinator_host);
        errdefer a.free(coordinator_host);
        const ack_host = try a.dupe(u8, value.ack_host);
        errdefer a.free(ack_host);
        const batch_token = try a.dupe(u8, value.batch_token);
        it.* = .{
            .handle = handle,
            .token = token,
            .client_token = client_token,
            .kind = value.kind,
            .src_host = src_host,
            .src_path = src_path,
            .dst_host = dst_host,
            .dst_path = dst_path,
            .app_id = app_id,
            .state = if (value.state == .done or value.state == .canceled or value.state == .failed or value.state == .waiting_retry)
                value.state
            else
                .queued,
            .job = value.job,
            .order = if (value.order == 0) self.nextOrder() else value.order,
            .watch_token = watch_token,
            .submitted_generation = value.submitted_generation,
            .message = message,
            .attempts = value.attempts,
            // Monotonic timestamps cannot survive a restart. Give a
            // recovered retry a fresh full delay rather than running it
            // immediately or persisting a wall-clock deadline.
            .retry_due_ms = if (value.state == .waiting_retry) nowMs() + RETRY_DELAY_MS else 0,
            .cancel_requested = value.cancel_requested,
            .submitted_size = value.submitted_size,
            .submitted_mtime_ns = value.submitted_mtime_ns,
            .paused = value.paused,
            .ack_job = value.ack_job,
            .ack_durable = value.ack_job != 0,
            .retired = value.retired,
            .mediated = value.mediated,
            .user_copy = value.user_copy,
            .batch_id = value.batch_id,
            .batch_total = value.batch_total,
            .batch_token = batch_token,
            .coordinator_host = coordinator_host,
            .coordinator_set = value.coordinator_set,
            .submission_uncertain = value.submission_uncertain,
            .ack_host = ack_host,
            .open_when_done = value.open_when_done,
            .delete_src_after = value.delete_src_after,
            .no_replace = value.no_replace,
            .watch_after = value.watch_after,
            .dest_key = destinationKey(value.dst.host, value.dst.path),
        };
        return it;
    }

    fn dupWatch(self: *Service, handle: store.Handle, value: store.Watch) !*Watch {
        const a = self.allocator;
        const w = try a.create(Watch);
        errdefer a.destroy(w);
        const token = try a.dupe(u8, value.token);
        errdefer a.free(token);
        const host = try a.dupe(u8, value.host);
        errdefer a.free(host);
        const remote_path = try a.dupe(u8, value.remote_path);
        errdefer a.free(remote_path);
        const cache_path = try a.dupe(u8, value.cache_path);
        w.* = .{
            .service = self,
            .handle = handle,
            .token = token,
            .host = host,
            .remote_path = remote_path,
            .cache_path = cache_path,
            .dirty_generation = value.dirty_generation,
            .synced_generation = value.synced_generation,
            .synced_size = value.synced_size,
            .synced_mtime_ns = value.synced_mtime_ns,
        };
        return w;
    }

    fn dupBatch(self: *Service, handle: store.Handle, value: store.Batch) !*UserBatch {
        const a = self.allocator;
        const batch = try a.create(UserBatch);
        errdefer a.destroy(batch);
        const token = try a.dupe(u8, value.token);
        errdefer a.free(token);
        const src_host = try a.dupe(u8, value.src_host);
        errdefer a.free(src_host);
        const dst_host = try a.dupe(u8, value.dst_host);
        errdefer a.free(dst_host);
        const items = try a.alloc(BatchItemRec, value.items.len);
        var initialized: usize = 0;
        errdefer {
            for (items[0..initialized]) |item| item.destroy(a);
            a.free(items);
        }
        for (value.items, 0..) |item, i| {
            items[i] = try dupBatchItem(a, item);
            initialized += 1;
        }
        batch.* = .{
            .handle = handle,
            .token = token,
            .batch_id = value.batch_id,
            .batch_total = value.batch_total,
            .src_host = src_host,
            .dst_host = dst_host,
            .move = value.move,
            .no_replace = value.no_replace,
            .items = items,
        };
        return batch;
    }

    // ── persistence ─────────────────────────────────────────────

    fn writeIntentOk(self: *Service, it: *Intent) bool {
        it.handle.write(it.record()) catch {
            self.durability_error = true;
            self.notify("cannot persist transfer recovery state", .{});
            return false;
        };
        // A record that landed proves the ledger is writable again;
        // leaving the flag set would refuse every later transfer over
        // one transient failure.
        self.durability_error = false;
        it.ack_durable = it.ack_job != 0;
        return true;
    }

    fn writeIntent(self: *Service, it: *Intent) void {
        if (!self.writeIntentOk(it)) return;
        if (it.mediated and !it.claimed and (it.ack_job != 0 or it.state == .queued or it.state == .waiting_retry))
            self.handToDriver(it);
    }

    fn writeWatch(self: *Service, w: *Watch) void {
        w.handle.write(w.record()) catch {
            self.durability_error = true;
            self.notify("cannot persist transfer recovery state", .{});
            return;
        };
        self.durability_error = false;
    }

    fn writeBatchOk(self: *Service, batch: *UserBatch) bool {
        const record = batch.record(self.allocator) catch return false;
        defer self.allocator.free(record.batch.items);
        batch.handle.write(record) catch {
            self.durability_error = true;
            self.notify("cannot persist transfer batch recovery state", .{});
            return false;
        };
        self.durability_error = false;
        return true;
    }

    /// Write every owned record whose content changed.
    fn persist(self: *Service) void {
        var i: usize = 0;
        while (i < self.intents.items.len) {
            const it = self.intents.items[i];
            self.writeIntent(it);
            if (i < self.intents.items.len and self.intents.items[i] == it) i += 1;
        }
        for (self.watches.items) |w| self.writeWatch(w);
        for (self.batches.items) |batch| _ = self.writeBatchOk(batch);
    }

    fn nextOrder(self: *Service) u64 {
        // Wall-clock based so records minted by DIFFERENT processes
        // still order against each other; the counter breaks ties
        // inside one millisecond.
        const ms: u64 = @intCast(wallMs());
        self.order_seq = (self.order_seq + 1) % 1000;
        return ms * 1000 + self.order_seq;
    }

    // ── connection ──────────────────────────────────────────────

    fn connect(self: *Service) void {
        if (self.conn != null or self.shutting_down) return;
        var conn = muxclient.Conn.connectLocalAutostart(self.allocator) catch {
            self.scheduleRetry();
            return;
        };
        if (conn.upgradeStaleIdle(self.allocator)) {
            conn.deinit();
            conn = muxclient.Conn.connectLocalAutostart(self.allocator) catch {
                self.scheduleRetry();
                return;
            };
        }
        conn.setNonBlocking();
        self.conn = conn;
        self.retry_delay_ms = 1000;
        self.fd_watch = c.g_unix_fd_add(conn.fd, c.G_IO_IN | c.G_IO_HUP | c.G_IO_ERR, @ptrCast(&onFd), @ptrCast(self));
    }

    fn scheduleRetry(self: *Service) void {
        if (self.retry_source == 0 and !self.shutting_down)
            self.retry_source = c.g_timeout_add(self.retry_delay_ms, @ptrCast(&onRetry), @ptrCast(self));
        self.retry_delay_ms = @min(@as(c.guint, 30_000), self.retry_delay_ms * 2);
    }

    fn scheduleTransferRetry(self: *Service, it: *Intent) void {
        it.retry_due_ms = nowMs() + RETRY_DELAY_MS;
        self.armTransferRetry();
    }

    fn armTransferRetry(self: *Service) void {
        if (self.transfer_retry_source != 0 or self.shutting_down) return;
        const now = nowMs();
        var delay: ?i64 = null;
        for (self.intents.items) |it| {
            if (!transferRetryEligible(it)) continue;
            // A submitted job whose cancel reply was lost must be
            // re-owned so the cancellation fence can finish. An
            // unsubmitted cancellation has no daemon state and is
            // retired synchronously by cancel().
            const remaining = @max(@as(i64, 1), it.retry_due_ms - now);
            delay = if (delay) |d| @min(d, remaining) else remaining;
        }
        if (delay) |ms|
            self.transfer_retry_source = c.g_timeout_add(@intCast(@min(ms, std.math.maxInt(c.guint))), @ptrCast(&onTransferRetry), @ptrCast(self));
    }

    fn onTransferRetry(user: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast.userData(Service, user);
        self.transfer_retry_source = 0;
        const now = nowMs();
        var i: usize = 0;
        while (i < self.intents.items.len) {
            const it = self.intents.items[i];
            if (!transferRetryEligible(it) or it.retry_due_ms > now) {
                i += 1;
                continue;
            }
            it.retry_due_ms = 0;
            it.state = .queued;
            if (it.mediated) {
                if (!it.claimed) {
                    // Live views retain their claim and run their own
                    // per-record deadline. A recovered record has no
                    // owner, so hand it back once its durable delay
                    // expires instead of feeding it to pump(), which
                    // intentionally handles daemon-owned work only.
                    if (self.writeIntentOk(it)) self.handToDriver(it);
                }
            } else {
                self.writeIntent(it);
            }
            if (i < self.intents.items.len and self.intents.items[i] == it) i += 1;
        }
        self.pump();
        self.refreshViews();
        self.armTransferRetry();
        return 0;
    }

    fn onRetry(user: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast.userData(Service, user);
        self.retry_source = 0;
        self.connect();
        self.pump();
        return 0;
    }

    fn recordDirectTransportLoss(self: *Service, it: *Intent) void {
        const unresolved = it.submission_uncertain or it.job != 0;
        if (!it.cancel_requested and !unresolved) it.attempts +|= 1;
        // Reclaiming a possibly-live idempotent attempt is not permission
        // to create new work and cannot be bounded by the work retry budget.
        const retry = it.cancel_requested or unresolved or automaticRetryAllowed(it.attempts, true);
        it.state = if (retry) .waiting_retry else .failed;
        it.retry_due_ms = if (retry) nowMs() + RETRY_DELAY_MS else 0;
        self.replaceMessage(it, "daemon connection lost during transfer");
        if (!retry)
            self.notify("transfer failed: {s}", .{std.fs.path.basename(it.dst_path)});
    }

    fn disconnected(self: *Service) void {
        if (self.fd_watch != 0) {
            const source = self.fd_watch;
            self.fd_watch = 0;
            _ = c.g_source_remove(source);
        }
        if (self.conn) |*conn| conn.deinit();
        self.conn = null;
        self.pending.clearRetainingCapacity();
        for (self.intents.items) |it| {
            it.ack_req = 0;
            if (!it.mediated and (it.state == .submitting or it.state == .running)) {
                self.recordDirectTransportLoss(it);
            }
        }
        self.persist();
        self.armTransferRetry();
        self.refreshViews();
        self.scheduleRetry();
    }

    fn requestDisconnect(self: *Service) void {
        if (self.in_fd_callback) {
            self.disconnect_after_drain = true;
        } else {
            self.disconnected();
        }
    }

    fn onFd(_: c_int, cond: c.GIOCondition, user: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast.userData(Service, user);
        self.in_fd_callback = true;
        defer self.in_fd_callback = false;
        const conn = if (self.conn) |*v| v else {
            // The source dies with this return; forget its id so no
            // later removal targets a stale one.
            self.fd_watch = 0;
            return 0;
        };
        const alive = conn.fillAvailable();
        while (conn.takeFrame() catch null) |f| {
            defer f.deinit(conn.allocator);
            switch (f.ftype) {
                .fs_reply => self.onReply(f.payload),
                .fs_job => self.onJob(f.payload),
                else => {},
            }
        }
        if (!alive or self.disconnect_after_drain or cond & (c.G_IO_HUP | c.G_IO_ERR) != 0) {
            self.disconnect_after_drain = false;
            self.disconnected();
            return 0;
        }
        return 1;
    }

    fn onReply(self: *Service, payload: []const u8) void {
        const Reply = struct { req: u32 = 0, ok: bool = false, job: u64 = 0, state: []const u8 = "", done: u64 = 0, total: u64 = 0, @"error": []const u8 = "", message: []const u8 = "", kind: []const u8 = "" };
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const rep = std.json.parseFromSliceLeaky(Reply, arena.allocator(), payload, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return;
        for (self.intents.items) |it| {
            if (it.ack_req == 0 or it.ack_req != rep.req) continue;
            it.ack_req = 0;
            if (!rep.ok and !std.mem.eql(u8, rep.@"error", "no such job")) {
                self.scheduleRetry();
                return;
            }
            it.ack_job = 0;
            it.ack_durable = false;
            if (it.retired) {
                self.removeIntent(it);
            } else {
                self.writeIntent(it);
            }
            return;
        }
        for (self.pending.items, 0..) |p, i| {
            if (p.req != rep.req) continue;
            _ = self.pending.orderedRemove(i);
            p.intent.submission_uncertain = false;
            if (!rep.ok or rep.job == 0) {
                if (p.intent.cancel_requested) {
                    p.intent.state = .canceled;
                    self.removeIntent(p.intent);
                    self.pump();
                    return;
                }
                p.intent.state = .failed;
                self.replaceMessage(p.intent, rep.@"error");
            } else {
                p.intent.job = rep.job;
                p.intent.state = parseState(rep.state) orelse .running;
                p.intent.done = rep.done;
                p.intent.total = rep.total;
                if (p.intent.cancel_requested and p.intent.state == .running and !self.sendJobControl(p.intent.job, "job_cancel"))
                    self.disconnect_after_drain = true;
                if (p.intent.resume_pending and p.intent.state == .running) {
                    p.intent.resume_pending = false;
                    if (!self.sendJobControl(p.intent.job, "job_resume")) self.disconnect_after_drain = true;
                } else if (p.intent.paused and p.intent.state == .running) {
                    // A pause the daemon has not seen (it re-owns the
                    // job on this resubmission) must be re-asserted.
                    if (!self.sendJobControl(p.intent.job, "job_pause")) self.disconnect_after_drain = true;
                }
                if (p.intent.state == .done)
                    self.complete(p.intent, true, false, rep.message, false)
                else if (p.intent.state == .failed or p.intent.state == .canceled) {
                    const canceled = p.intent.state == .canceled;
                    if (canceled) p.intent.cancel_requested = true;
                    self.complete(p.intent, false, canceled, rep.message, retryableFailureKind(rep.kind));
                }
            }
            self.persist();
            self.pump();
            return;
        }
    }

    fn onJob(self: *Service, payload: []const u8) void {
        const Event = struct {
            job: u64 = 0,
            ev: []const u8 = "",
            message: []const u8 = "",
            done: u64 = 0,
            total: u64 = 0,
            resumed_from: u64 = 0,
            kind: []const u8 = "",
        };
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const ev = std.json.parseFromSliceLeaky(Event, arena.allocator(), payload, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return;
        for (self.intents.items) |it| {
            if (it.job != ev.job or it.retired) continue;
            if (std.mem.eql(u8, ev.ev, "done")) {
                self.complete(it, true, false, "", false);
            } else if (std.mem.eql(u8, ev.ev, "error") or std.mem.eql(u8, ev.ev, "canceled")) {
                const canceled = std.mem.eql(u8, ev.ev, "canceled");
                if (canceled) it.cancel_requested = true;
                self.complete(it, false, canceled, ev.message, std.mem.eql(u8, ev.ev, "error") and retryableFailureKind(ev.kind));
            } else if (std.mem.eql(u8, ev.ev, "paused") or std.mem.eql(u8, ev.ev, "resumed")) {
                // The daemon is the authority on whether the helper is
                // stopped; a pause from another client shows up here.
                it.paused = std.mem.eql(u8, ev.ev, "paused");
                self.writeIntent(it);
                self.pump();
            } else {
                it.done = ev.done;
                if (ev.total > 0) it.total = ev.total;
                if (ev.resumed_from > 0) it.resumed_from = ev.resumed_from;
            }
            return;
        }
    }

    fn parseState(s: []const u8) ?store.State {
        if (std.mem.eql(u8, s, "running") or std.mem.eql(u8, s, "paused")) return .running;
        if (std.mem.eql(u8, s, "done")) return .done;
        if (std.mem.eql(u8, s, "failed")) return .failed;
        if (std.mem.eql(u8, s, "canceled")) return .canceled;
        return null;
    }

    fn replaceMessage(self: *Service, it: *Intent, msg: []const u8) void {
        const replacement = self.allocator.dupe(u8, msg) catch return;
        self.allocator.free(it.message);
        it.message = replacement;
    }

    fn scheduleCancellationRecovery(self: *Service, it: *Intent, message: []const u8) bool {
        const fresh = self.newToken() catch return false;
        const replacement_message = self.allocator.dupe(u8, message) catch {
            self.allocator.free(fresh);
            return false;
        };
        const txn = IntentTxn.begin(self, it);
        it.record_version = store.VERSION;
        it.client_token = fresh;
        it.message = replacement_message;
        it.ack_job = 0;
        it.ack_durable = false;
        it.state = .waiting_retry;
        it.retry_due_ms = nowMs() + RETRY_DELAY_MS;
        it.submission_uncertain = false;
        it.claimed = false;
        it.cancel_requested = true;
        if (!txn.commit()) {
            self.allocator.free(fresh);
            self.allocator.free(replacement_message);
            return false;
        }
        self.allocator.free(txn.saved.client_token);
        self.allocator.free(txn.saved.message);
        self.armTransferRetry();
        return true;
    }

    fn complete(self: *Service, it: *Intent, ok: bool, canceled: bool, message: []const u8, retryable: bool) void {
        const terminal_job = it.job;
        it.submission_uncertain = false;
        if (!ok) {
            if (canceled) {
                it.ack_job = terminal_job;
                it.ack_durable = false;
                it.state = .canceled;
                if (!self.retire(it)) return;
                self.notify("transfer canceled: {s}", .{std.fs.path.basename(it.dst_path)});
                self.pump();
                return;
            }
            if (it.cancel_requested) {
                // A terminal error is not proof that cancellation safely
                // restored the source. Rotate the client identity to restart
                // durable cleanup, but keep the old job unacknowledged until
                // the helper reports a source-safe terminal result.
                if (self.scheduleCancellationRecovery(it, message))
                    self.notify("transfer cancellation recovery scheduled: {s}", .{std.fs.path.basename(it.dst_path)})
                else
                    self.notify("transfer cancellation needs attention: {s}", .{std.fs.path.basename(it.dst_path)});
                self.pump();
                return;
            }
            if (!retryable) {
                it.ack_job = terminal_job;
                it.ack_durable = false;
                it.state = .failed;
                self.replaceMessage(it, message);
                self.notify("transfer failed: {s}", .{std.fs.path.basename(it.dst_path)});
                if (!self.writeIntentOk(it)) return;
                self.pumpAcksNow();
                self.pump();
                return;
            }
            it.attempts +|= 1;
            if (!automaticRetryAllowed(it.attempts, true)) {
                it.ack_job = terminal_job;
                it.ack_durable = false;
                it.state = .failed;
                self.replaceMessage(it, message);
                self.notify("transfer failed: {s}", .{std.fs.path.basename(it.dst_path)});
                if (!self.writeIntentOk(it)) return;
                self.pumpAcksNow();
                self.pump();
                return;
            }
            // A terminal daemon job cannot be restarted under the same
            // idempotency token. A fresh attempt keeps the .skpart
            // checkpoint but receives a new job identity.
            // Deliberately NOT an IntentTxn rollback: when the retry
            // rotation cannot be made durable, restoring the pre-mutation
            // record would advertise a waiting_retry that no ledger backs
            // and that a GUI restart silently drops. Downgrading to
            // .failed keeps the row visible and manually retryable, and
            // the ack fields stay mutated because the daemon job is
            // terminal whether or not our write succeeded.
            const fresh = self.newToken() catch {
                it.ack_job = terminal_job;
                it.ack_durable = false;
                it.state = .failed;
                it.retry_due_ms = 0;
                self.replaceMessage(it, "could not allocate a durable retry identity");
                if (self.writeIntentOk(it)) self.pumpAcksNow();
                self.pump();
                return;
            };
            const previous_token = it.client_token;
            const previous_job = it.job;
            it.client_token = fresh;
            it.job = 0;
            it.state = .waiting_retry;
            it.ack_job = terminal_job;
            it.ack_durable = false;
            it.retry_due_ms = nowMs() + RETRY_DELAY_MS;
            self.replaceMessage(it, message);
            if (!self.writeIntentOk(it)) {
                // Same rule as above: the identity fields roll back, but
                // the state intentionally lands on .failed instead of the
                // pre-mutation value — an unpersisted waiting_retry is a
                // silent no-op after a restart.
                it.client_token = previous_token;
                it.job = previous_job;
                it.state = .failed;
                it.retry_due_ms = 0;
                self.allocator.free(fresh);
                return;
            }
            self.allocator.free(previous_token);
            self.notify("transfer deferred: {s}", .{std.fs.path.basename(it.dst_path)});
            self.armTransferRetry();
            self.pump();
            return;
        }
        it.state = .done;
        it.ack_job = terminal_job;
        it.ack_durable = false;
        if (it.kind == .download) {
            const w = self.ensureWatch(it.watch_token, it.src_host, it.src_path, it.dst_path);
            const watch = w orelse {
                it.state = .failed;
                it.ack_job = terminal_job;
                it.ack_durable = false;
                self.replaceMessage(it, "cannot create durable edit watch");
                if (self.writeIntentOk(it)) self.pumpAcksNow();
                self.notify("download held because edit recovery could not be created: {s}", .{std.fs.path.basename(it.dst_path)});
                return;
            };
            self.captureFingerprint(watch);
            watch.synced_generation = watch.dirty_generation;
            self.armWatch(watch);
            self.writeWatch(watch); // arm recovery before launching an external app
            if (self.durability_error) return;
        } else {
            if (self.watchByToken(it.watch_token)) |w| {
                w.synced_generation = @max(w.synced_generation, it.submitted_generation);
                const current = fingerprint(w.cache_path);
                if (current) |fp| {
                    if (fp.size == it.submitted_size and fp.mtime_ns == it.submitted_mtime_ns) {
                        w.synced_size = fp.size;
                        w.synced_mtime_ns = fp.mtime_ns;
                    } else {
                        // The file changed after this upload snapshot.
                        // Ensure a follow-up generation even when the
                        // monitor coalesced or missed the intermediate event.
                        w.dirty_generation = @max(w.dirty_generation, it.submitted_generation + 1);
                    }
                }
                self.writeWatch(w);
                if (self.durability_error) return;
            }
        }
        if (!self.retire(it)) return;
        if (it.kind == .download) {
            if (it.app_id.len > 0) launchWithApp(it.app_id, it.dst_path) else launchDefault(it.dst_path);
            self.notify("download complete: {s}", .{std.fs.path.basename(it.dst_path)});
        } else if (self.watchByToken(it.watch_token)) |w| {
            self.notify("synced back: {s}", .{std.fs.path.basename(w.remote_path)});
        }
        self.queueDirtyWatches();
        self.pump();
        self.refreshViews();
    }

    /// A finished intent leaves the queue but its record survives
    /// until the daemon has acknowledged the job, so a crash in
    /// between cannot strand the job on the daemon.
    fn retire(self: *Service, it: *Intent) bool {
        if (it.ack_job == 0) {
            if (self.childManifestExists(it.token, it.batch_token)) {
                it.retired = true;
                return self.writeIntentOk(it);
            }
            self.removeIntent(it);
            return true;
        }
        it.retired = true;
        if (!self.writeIntentOk(it)) return false;
        self.pumpAcksNow();
        return true;
    }

    fn removeIntent(self: *Service, needle: *Intent) void {
        self.removeIntentMode(needle, true);
    }

    fn removeIntentMode(self: *Service, needle: *Intent, sync_parent: bool) void {
        for (self.intents.items, 0..) |it, i| {
            if (it != needle) continue;
            _ = self.intents.orderedRemove(i);
            const removed = if (sync_parent)
                it.handle.destroyRecord()
            else
                it.handle.destroyRecordUnsynced();
            if (!removed) {
                self.durability_error = true;
                self.notify("cannot remove transfer recovery state", .{});
            }
            it.destroy(self.allocator);
            return;
        }
    }

    fn newToken(self: *Service) ![]u8 {
        var raw: [16]u8 = undefined;
        if (c.getentropy(&raw, raw.len) != 0) {
            std.mem.writeInt(u64, raw[0..8], @intCast(c.getpid()), .little);
            std.mem.writeInt(u64, raw[8..16], self.nextOrder(), .little);
        }
        return std.fmt.allocPrint(self.allocator, "{x}", .{raw});
    }

    // ── downloads and sync-back ─────────────────────────────────

    /// A record in the ledger, owned by ANY process, that already
    /// downloads `host:remote_path`. Cross-process duplicate detection:
    /// two processes downloading the same file would write the same
    /// staged `.skpart`.
    fn foreignDownloadExists(self: *Service, host: []const u8, remote_path: []const u8) bool {
        const entries = store.list(self.allocator) catch return false;
        defer store.freeList(self.allocator, entries);
        for (entries) |e| {
            if (e.rtype != .intent) continue;
            if (self.ownsIntent(e.token)) continue;
            const parsed = (store.readToken(self.allocator, .intent, e.token) catch null) orelse continue;
            defer parsed.deinit();
            const v = parsed.value.intent;
            if (v.retired or v.state == .canceled) continue;
            if (v.kind != .download) continue;
            if (std.mem.eql(u8, v.src.host, host) and std.mem.eql(u8, v.src.path, remote_path)) return true;
        }
        return false;
    }

    /// A watch record held by another process for the same remote
    /// file, with its cache copy still present. That copy is the one
    /// to open: re-downloading it would fight over the same path.
    fn foreignWatchCache(self: *Service, allocator: std.mem.Allocator, host: []const u8, remote_path: []const u8) ?[]u8 {
        const entries = store.list(self.allocator) catch return null;
        defer store.freeList(self.allocator, entries);
        for (entries) |e| {
            if (e.rtype != .watch) continue;
            if (self.ownsWatch(e.token)) continue;
            const parsed = (store.readToken(self.allocator, .watch, e.token) catch null) orelse continue;
            defer parsed.deinit();
            const v = parsed.value.watch;
            if (!std.mem.eql(u8, v.host, host) or !std.mem.eql(u8, v.remote_path, remote_path)) continue;
            if (fingerprint(v.cache_path) == null) continue;
            return allocator.dupe(u8, v.cache_path) catch null;
        }
        return null;
    }

    pub fn submitDownload(self: *Service, host: []const u8, remote_path: []const u8, cache_path: []const u8, app_id: ?[]const u8, origin: ?*anyopaque) void {
        for (self.watches.items) |w| {
            if (!std.mem.eql(u8, w.host, host) or !std.mem.eql(u8, w.remote_path, remote_path)) continue;
            const current = fingerprint(w.cache_path);
            // A watched cache may contain edits that deliberately kept
            // size and timestamps. Never replace it implicitly; opening
            // the existing local copy is the only lossless choice.
            if (current != null) {
                if (app_id) |id| launchWithApp(id, w.cache_path) else launchDefault(w.cache_path);
                if (w.dirty_generation > w.synced_generation)
                    self.notify("opened local edits while sync-back is pending: {s}", .{std.fs.path.basename(w.cache_path)})
                else
                    // Say so: this copy is not re-fetched, so it can be
                    // older than what the host holds now.
                    self.notify("opened the existing local copy: {s}", .{std.fs.path.basename(w.cache_path)});
                return;
            }
        }
        for (self.intents.items) |it| {
            if (it.retired) continue;
            if (it.kind == .download and std.mem.eql(u8, it.src_host, host) and std.mem.eql(u8, it.src_path, remote_path)) return;
        }
        if (self.foreignWatchCache(self.allocator, host, remote_path)) |cached| {
            defer self.allocator.free(cached);
            if (app_id) |id| launchWithApp(id, cached) else launchDefault(cached);
            self.notify("opened the copy another sketerm window already holds: {s}", .{std.fs.path.basename(cached)});
            return;
        }
        if (self.foreignDownloadExists(host, remote_path)) {
            self.notify("another sketerm window is already downloading {s}", .{std.fs.path.basename(remote_path)});
            return;
        }
        const watch_token = self.newToken() catch return;
        defer self.allocator.free(watch_token);
        self.appendIntent(.download, host, remote_path, "", cache_path, app_id orelse "", watch_token, 0, origin);
    }

    /// Submit a one-way upload of a LOCAL file to `host:remote_path`
    /// as a durable daemon transfer with no edit watch attached — the
    /// web download manager's redirect-to-server handoff. Returns the
    /// ledger token (allocated from `allocator`, caller owns) so the
    /// submitter can poll `intentProgress`, or null when the record
    /// could not be created.
    pub fn submitUpload(self: *Service, allocator: std.mem.Allocator, local_path: []const u8, host: []const u8, remote_path: []const u8, origin: ?*anyopaque) ?[]u8 {
        if (self.durability_error) {
            self.notify("transfer not started because recovery state is unavailable", .{});
            return null;
        }
        const it = self.createIntent(.upload, "", local_path, host, remote_path, "", "", 0) catch return null;
        it.origin = origin;
        self.intents.append(self.allocator, it) catch {
            _ = it.handle.destroyRecord();
            it.destroy(self.allocator);
            return null;
        };
        const token = allocator.dupe(u8, it.token) catch null;
        self.writeIntent(it);
        if (self.durability_error) {
            self.removeIntent(it);
            if (token) |t| allocator.free(t);
            return null;
        }
        self.pump();
        self.refreshViews();
        return token;
    }

    pub const IntentProgress = struct { state: store.State, done: u64, total: u64 };

    /// Live progress for one owned intent, or null when the record is
    /// gone — which, for a token this process submitted and has been
    /// polling, means it finished and was acknowledged away.
    pub fn intentProgress(self: *Service, token: []const u8) ?IntentProgress {
        for (self.intents.items) |it| {
            if (!std.mem.eql(u8, it.token, token)) continue;
            return .{ .state = it.state, .done = it.done, .total = it.total };
        }
        return null;
    }

    fn appendIntent(self: *Service, kind: store.Kind, src_host: []const u8, src_path: []const u8, dst_host: []const u8, dst_path: []const u8, app_id: []const u8, watch_token: []const u8, generation: u64, origin: ?*anyopaque) void {
        if (self.durability_error) {
            self.notify("transfer not started because recovery state is unavailable", .{});
            return;
        }
        const it = self.createIntent(kind, src_host, src_path, dst_host, dst_path, app_id, watch_token, generation) catch return;
        it.origin = origin;
        self.intents.append(self.allocator, it) catch {
            _ = it.handle.destroyRecord();
            it.destroy(self.allocator);
            return;
        };
        self.writeIntent(it);
        if (self.durability_error) {
            self.removeIntent(it);
            return;
        }
        self.pump();
        self.refreshViews();
    }

    fn createIntent(self: *Service, kind: store.Kind, src_host: []const u8, src_path: []const u8, dst_host: []const u8, dst_path: []const u8, app_id: []const u8, watch_token: []const u8, generation: u64) !*Intent {
        const token = try self.newToken();
        defer self.allocator.free(token);
        var handle = (try store.open(self.allocator, .intent, token)) orelse return error.LedgerBusy;
        errdefer handle.release();
        const submitted = if (kind == .upload) fingerprint(src_path) else null;
        return self.dupIntent(handle, .{
            .token = token,
            .kind = kind,
            .src = .{ .host = src_host, .path = src_path },
            .dst = .{ .host = dst_host, .path = dst_path },
            .app_id = app_id,
            .state = .queued,
            .order = self.nextOrder(),
            .watch_token = watch_token,
            .submitted_generation = generation,
            .submitted_size = if (submitted) |fp| fp.size else 0,
            .submitted_mtime_ns = if (submitted) |fp| fp.mtime_ns else 0,
        });
    }

    /// Submit whatever the queue policy admits. A PAUSED transfer does
    /// not occupy an active slot: it is doing no work, so holding a
    /// destination for it would only stall the transfers that are.
    fn pump(self: *Service) void {
        const conn = if (self.conn) |*v| v else {
            self.connect();
            return;
        };
        const current_durable_copy = conn.durable_copy and conn.durable_copy_v2;
        if (!current_durable_copy) {
            if (!self.pumpAcks(conn)) return;
            var changed = false;
            var legacy_work = false;
            for (self.intents.items) |it| {
                if (it.retired or it.ack_job != 0 or it.mediated) continue;
                if (it.record_version < store.VERSION and conn.durable_copy) {
                    // v2 service jobs already used their ledger token
                    // as an idempotency key and remain safe to reown on
                    // the daemon that created them.
                    legacy_work = true;
                    continue;
                }
                if (it.job != 0) continue;
                it.record_version = store.VERSION;
                it.mediated = true;
                it.claimed = false;
                self.writeIntent(it);
                self.handToDriver(it);
                changed = true;
            }
            if (changed) self.refreshViews();
            if (!legacy_work) {
                // Retry the handshake periodically: once the stale
                // daemon becomes idle, connect() can replace it.
                self.requestDisconnect();
                return;
            }
        }
        if (!self.pumpAcks(conn)) return;
        std.mem.sort(*Intent, self.intents.items, {}, struct {
            fn less(_: void, a: *Intent, b: *Intent) bool {
                return a.order < b.order;
            }
        }.less);
        const slots = self.allocator.alloc(xferqueue.Slot, self.intents.items.len) catch return;
        defer self.allocator.free(slots);
        const map = self.allocator.alloc(usize, self.intents.items.len) catch return;
        defer self.allocator.free(map);
        var n: usize = 0;
        for (self.intents.items, 0..) |it, i| {
            if (it.retired or it.mediated or it.paused or it.ack_job != 0) continue;
            if (!current_durable_copy and it.record_version >= store.VERSION) continue;
            const state: ?xferqueue.State = switch (it.state) {
                .submitting, .running => .running,
                // A canceled queued record can only get here after a
                // connection loss with a known daemon job. Re-submit
                // the stable token, learn the live job id, then
                // re-assert job_cancel in onReply.
                .queued => if (it.cancel_requested and it.job == 0 and !it.submission_uncertain) null else .queued,
                else => null,
            };
            if (state) |s| {
                slots[n] = .{ .dest = it.dest_key, .state = s };
                map[n] = i;
                n += 1;
            }
        }
        var admitted: [xferqueue.MAX_ACTIVE]usize = undefined;
        for (xferqueue.admissible(slots[0..n], &admitted)) |k| {
            if (!self.submit(conn, self.intents.items[map[k]])) return;
        }
        self.persist();
    }

    /// @return false when the connection died mid-submit (the caller
    /// must stop touching `conn`).
    fn submit(self: *Service, conn: *muxclient.Conn, it: *Intent) bool {
        const req = self.next_req;
        self.next_req +%= 1;
        if (self.next_req == 0) self.next_req = 1;
        if (conn.durable_copy_v2) it.record_version = store.VERSION;
        self.pending.append(self.allocator, .{ .req = req, .intent = it }) catch {
            it.state = .failed;
            it.submission_uncertain = false;
            it.retry_due_ms = 0;
            self.replaceMessage(it, "could not queue transfer request");
            self.writeIntent(it);
            self.refreshViews();
            return true;
        };
        it.state = .submitting;
        it.submission_uncertain = true;
        if (!self.writeIntentOk(it)) {
            _ = self.pending.pop();
            it.state = .failed;
            it.submission_uncertain = false;
            return true;
        }
        conn.sendJson(.fs_op, .{
            .req = req,
            .op = "cross_copy",
            .path = it.src_path,
            .to = it.dst_path,
            .src_host = it.src_host,
            .dst_host = it.dst_host,
            .@"resume" = true,
            .client_token = it.client_token,
            // Stable across attempts: a capable daemon restarts the
            // failed job (and its staged data) instead of duplicating.
            .transfer_token = it.token,
        }) catch |err| {
            _ = self.pending.pop();
            if (err == error.WriteFailed) {
                self.requestDisconnect();
                return false;
            }
            it.state = .failed;
            it.submission_uncertain = false;
            it.retry_due_ms = 0;
            self.replaceMessage(it, "could not serialize transfer request");
            self.writeIntent(it);
            self.refreshViews();
            return true;
        };
        return true;
    }

    /// Hold or release one queued/running transfer. A queued one is
    /// simply never submitted; a running one is SIGSTOPped daemon-side.
    pub fn setPaused(self: *Service, token: []const u8, paused: bool) void {
        for (self.intents.items) |it| {
            if (!std.mem.eql(u8, it.token, token)) continue;
            if (it.paused == paused) return;
            const txn = IntentTxn.begin(self, it);
            it.paused = paused;
            if (!txn.commit()) return;
            const live = it.job != 0 and (it.state == .running or it.state == .submitting);
            if (live) {
                if (!self.sendJobControl(it.job, if (paused) "job_pause" else "job_resume"))
                    self.requestDisconnect();
            } else if (!paused and it.job != 0) {
                // The daemon job outlived the client that paused it;
                // resume as soon as the resubmission returns its id.
                it.resume_pending = true;
            }
            self.pump();
            return;
        }
    }

    pub fn moveQueued(self: *Service, token: []const u8, direction: i8) void {
        var idx: ?usize = null;
        for (self.intents.items, 0..) |it, i| if (std.mem.eql(u8, it.token, token) and it.state == .queued) {
            idx = i;
            break;
        };
        const i = idx orelse return;
        const j: usize = if (direction < 0) (if (i == 0) return else i - 1) else (if (i + 1 >= self.intents.items.len) return else i + 1);
        if (self.intents.items[j].state != .queued) return;
        const order = self.intents.items[i].order;
        self.intents.items[i].order = self.intents.items[j].order;
        self.intents.items[j].order = order;
        // rows() reports array order, so the array has to follow the
        // reordering or the move looks like it did nothing.
        std.mem.swap(*Intent, &self.intents.items[i], &self.intents.items[j]);
        self.persist();
    }

    /// Persist cancellation before any caller removes volatile retry state.
    pub fn cancel(self: *Service, token: []const u8) bool {
        for (self.intents.items) |it| {
            if (!std.mem.eql(u8, it.token, token)) continue;
            return self.cancelIntent(it);
        }
        return true;
    }

    /// The cancel waterfall: the first matching case owns the record,
    /// and each case is its own durable transaction.
    fn cancelIntent(self: *Service, it: *Intent) bool {
        if (it.cancel_requested and it.state != .done and it.state != .canceled)
            return self.reassertCancel(it);
        if (cancelNeedsSubmissionRecovery(it))
            return self.cancelUnresolvedSubmission(it);
        if (it.mediated and it.user_copy and it.coordinator_set and
            (it.state == .waiting_retry or it.state == .failed))
        {
            const scheduled = self.scheduleCancellationRecovery(it, "automatic retry canceled; cleaning destination staging data");
            self.refreshViews();
            return scheduled;
        }
        if (it.mediated and (it.state == .waiting_retry or it.state == .failed))
            return self.cancelIdleMediated(it);
        if (it.job == 0 and (it.state == .queued or it.state == .waiting_retry or it.state == .failed))
            return self.cancelUnsubmitted(it);
        return self.flagCancelRequested(it);
    }

    /// Already durably canceled: re-assert it toward the daemon rather
    /// than writing the same record again.
    fn reassertCancel(self: *Service, it: *Intent) bool {
        if (it.state == .waiting_retry) self.armTransferRetry();
        if (it.job != 0 and (it.state == .running or it.state == .submitting) and
            !self.sendJobControl(it.job, "job_cancel")) self.requestDisconnect();
        return true;
    }

    /// A lost start reply leaves job=0 even though the coordinator may
    /// be running the copy. Keep the record until a driver reclaims the
    /// stable token and reasserts job_cancel against the recovered id.
    fn cancelUnresolvedSubmission(self: *Service, it: *Intent) bool {
        const txn = IntentTxn.begin(self, it);
        it.cancel_requested = true;
        it.state = .waiting_retry;
        it.retry_due_ms = nowMs();
        it.claimed = false;
        if (!txn.commit()) return false;
        self.armTransferRetry();
        self.refreshViews();
        return true;
    }

    /// A mediated transfer with no daemon work left: cancel it outright.
    fn cancelIdleMediated(self: *Service, it: *Intent) bool {
        const txn = IntentTxn.begin(self, it);
        it.cancel_requested = true;
        it.retry_due_ms = 0;
        it.state = .canceled;
        it.retired = true;
        if (!txn.commit()) return false;
        if (it.ack_job == 0 and !self.childManifestExists(it.token, it.batch_token)) self.removeIntent(it);
        self.refreshViews();
        return true;
    }

    /// Never handed to a daemon job: cancel and retire it directly.
    fn cancelUnsubmitted(self: *Service, it: *Intent) bool {
        const txn = IntentTxn.begin(self, it);
        it.state = .canceled;
        it.retired = true;
        if (!txn.commit()) return false;
        _ = self.retire(it);
        self.pump();
        return true;
    }

    /// Live daemon work: record the request, then ask the daemon.
    fn flagCancelRequested(self: *Service, it: *Intent) bool {
        const txn = IntentTxn.begin(self, it);
        it.cancel_requested = true;
        if (!txn.commit()) return false;
        if (it.job != 0 and !self.sendJobControl(it.job, "job_cancel")) self.requestDisconnect();
        return true;
    }

    /// job_cancel / job_pause / job_resume toward a live job.
    /// @return false when the frame could not be queued.
    fn sendJobControl(self: *Service, job: u64, op: []const u8) bool {
        if (self.conn) |*conn| {
            const req = self.next_req;
            self.next_req +%= 1;
            conn.sendJson(.fs_op, .{ .req = req, .op = op, .job = job }) catch return false;
            return true;
        }
        return false;
    }

    fn pumpAcksNow(self: *Service) void {
        const conn = if (self.conn) |*v| v else return;
        _ = self.pumpAcks(conn);
    }

    fn pumpAcks(self: *Service, conn: *muxclient.Conn) bool {
        for (self.intents.items) |it| {
            if (it.mediated or it.ack_job == 0 or !it.ack_durable or it.ack_req != 0) continue;
            const req = self.next_req;
            self.next_req +%= 1;
            if (self.next_req == 0) self.next_req = 1;
            it.ack_req = req;
            conn.sendJson(.fs_op, .{ .req = req, .op = "job_ack", .job = it.ack_job }) catch {
                it.ack_req = 0;
                self.disconnect_after_drain = true;
                return false;
            };
        }
        return true;
    }

    /// True when `viewer` is the view that should render rows nobody
    /// claims: the first registered driver (or anyone, with none).
    fn viewerIsPrimary(self: *Service, viewer: ?*anyopaque) bool {
        if (self.drivers.items.len == 0) return true;
        return viewer != null and self.drivers.items[0].ctx == viewer.?;
    }

    /// Whether `origin` names a view that still renders a panel.
    fn originLive(self: *Service, origin: ?*anyopaque) bool {
        const o = origin orelse return false;
        for (self.drivers.items) |d| {
            if (d.ctx == o) return true;
        }
        return false;
    }

    pub fn rows(self: *Service, allocator: std.mem.Allocator, viewer: ?*anyopaque) ![]QueueRow {
        var out: std.ArrayList(QueueRow) = .empty;
        for (self.intents.items) |it| {
            // Retired records are bookkeeping, and mediated ones are
            // rendered by the view that runs them except while no live
            // attempt exists and the logical retry must remain visible.
            if (it.retired) continue;
            if (it.mediated and it.state != .waiting_retry and (it.state != .failed or it.claimed)) continue;
            // One panel per record: the pane that submitted it, or --
            // for records without a living submitter (recovery,
            // watch sync-backs, a closed pane) -- the primary view.
            // Without this a split view showed every download twice.
            if (self.originLive(it.origin)) {
                if (it.origin.? != viewer) continue;
            } else if (!self.viewerIsPrimary(viewer)) continue;
            try out.append(allocator, .{
                .token = it.token,
                .label = std.fs.path.basename(it.dst_path),
                .state = it.state,
                .done = it.done,
                .total = it.total,
                .kind = it.kind,
                .paused = it.paused,
                .src_host = it.src_host,
                .src_path = it.src_path,
                .dst_host = it.dst_host,
                .dst_path = it.dst_path,
                .resumed_from = it.resumed_from,
                .message = it.message,
                .mediated = it.mediated and it.record_version >= store.VERSION,
                .batch_id = it.batch_id,
                .batch_total = it.batch_total,
                .delete_src_after = it.delete_src_after,
                .attempts = it.attempts,
                .retry_due_ms = it.retry_due_ms,
            });
        }
        return out.toOwnedSlice(allocator);
    }

    // ── client-mediated records ─────────────────────────────────

    fn intentByToken(self: *Service, token: []const u8) ?*Intent {
        for (self.intents.items) |it| if (std.mem.eql(u8, it.token, token)) return it;
        return null;
    }

    fn mediatedRec(it: *const Intent) MediatedRec {
        return .{
            .record_version = it.record_version,
            .token = it.token,
            .client_token = it.client_token,
            .src_host = it.src_host,
            .src_path = it.src_path,
            .dst_host = it.dst_host,
            .dst_path = it.dst_path,
            .app_id = it.app_id,
            .paused = it.paused,
            .open_when_done = it.open_when_done,
            .delete_src_after = it.delete_src_after,
            .no_replace = it.no_replace,
            .watch_after = it.watch_after,
            .user_copy = it.user_copy,
            .batch_id = it.batch_id,
            .batch_total = it.batch_total,
            .coordinator_host = it.coordinator_host,
            .coordinator_set = it.coordinator_set,
            .ack_host = it.ack_host,
            .ack_job = it.ack_job,
            .cancel_requested = it.cancel_requested,
            .retired = it.retired,
            .attempts = it.attempts,
            .state = it.state,
        };
    }

    fn batchRec(batch: *const UserBatch) BatchRec {
        return .{
            .token = batch.token,
            .batch_id = batch.batch_id,
            .batch_total = batch.batch_total,
            .src_host = batch.src_host,
            .dst_host = batch.dst_host,
            .move = batch.move,
            .no_replace = batch.no_replace,
            .items = batch.items,
        };
    }

    /// Tell every registered view that the row set may have changed.
    fn refreshViews(self: *Service) void {
        for (self.drivers.items) |d| d.refresh(d.ctx);
    }

    fn handToDriver(self: *Service, it: *Intent) void {
        if (it.claimed) return;
        if (it.state == .waiting_retry and it.retry_due_ms > nowMs()) {
            self.armTransferRetry();
            return;
        }
        if (it.ack_job == 0 and (it.retired or it.state == .done or it.state == .canceled)) return;
        if (it.state == .failed and it.ack_job == 0) return;
        const driver = if (self.drivers.items.len > 0) self.drivers.items[0] else return;
        self.handIntentTo(driver, it);
    }

    fn handIntentTo(self: *Service, driver: Driver, it: *Intent) void {
        if (it.claimed) return;
        if (it.state == .waiting_retry and it.retry_due_ms > nowMs()) {
            self.armTransferRetry();
            return;
        }
        if (it.ack_job == 0 and (it.retired or it.state == .done or it.state == .canceled)) return;
        if (it.state == .failed and it.ack_job == 0) return;
        it.claimed = true;
        driver.callback(driver.ctx, mediatedRec(it));
    }

    fn handBatchToDriver(self: *Service, batch: *UserBatch) void {
        if (batch.owner != null) return;
        for (self.drivers.items) |driver| {
            batch.owner = driver.ctx;
            driver.batch_callback(driver.ctx, batchRec(batch));
            var retained = false;
            for (self.batches.items) |owned| {
                if (owned == batch) {
                    retained = true;
                    break;
                }
            }
            if (!retained) return;
            if (batch.owner != driver.ctx) continue;
            for (batch.items) |item| {
                if (self.intentByToken(item.token)) |it| self.handIntentTo(driver, it);
            }
            return;
        }
    }

    fn handAllBatches(self: *Service) void {
        var i: usize = 0;
        while (i < self.batches.items.len) {
            const batch = self.batches.items[i];
            self.handBatchToDriver(batch);
            if (i < self.batches.items.len and self.batches.items[i] == batch) i += 1;
        }
    }

    fn handLooseIntents(self: *Service) void {
        var i: usize = 0;
        while (i < self.intents.items.len) {
            const it = self.intents.items[i];
            if (it.mediated and !self.childManifestExists(it.token, it.batch_token)) self.handToDriver(it);
            if (i < self.intents.items.len and self.intents.items[i] == it) i += 1;
        }
    }

    fn reassignBatches(self: *Service, owner: *anyopaque) void {
        var i: usize = 0;
        while (i < self.batches.items.len) {
            const batch = self.batches.items[i];
            if (batch.owner == owner) {
                batch.owner = null;
                self.handBatchToDriver(batch);
            }
            if (i < self.batches.items.len and self.batches.items[i] == batch) i += 1;
        }
    }

    /// Register a runner for client-mediated records. The FIRST driver
    /// registered runs them; the rest only matter when it goes away.
    pub fn addMediatedDriver(self: *Service, ctx: *anyopaque, callback: MediatedFn, batch_callback: BatchFn, refresh: RefreshFn) void {
        for (self.drivers.items) |d| if (d.ctx == ctx) return;
        self.drivers.append(self.allocator, .{ .ctx = ctx, .callback = callback, .batch_callback = batch_callback, .refresh = refresh }) catch return;
        if (self.drivers.items.len == 1) {
            self.adoptOrphans();
            self.handLooseIntents();
        }
        self.handAllBatches();
    }

    pub fn removeMediatedDriver(self: *Service, ctx: *anyopaque) void {
        var was_head = false;
        for (self.drivers.items, 0..) |d, i| {
            if (d.ctx != ctx) continue;
            was_head = i == 0;
            _ = self.drivers.orderedRemove(i);
            break;
        }
        if (self.drivers.items.len > 0) {
            self.handLooseIntents();
            self.reassignBatches(ctx);
            return;
        }
        if (!was_head) return;
        // Nothing left here can run them: drop ownership so another
        // process (or a later browser face) picks them up.
        var i: usize = 0;
        while (i < self.intents.items.len) {
            const it = self.intents.items[i];
            if (!it.mediated) {
                i += 1;
                continue;
            }
            self.writeIntent(it);
            _ = self.intents.orderedRemove(i);
            it.handle.release();
            it.destroy(self.allocator);
        }
        i = 0;
        while (i < self.batches.items.len) {
            const batch = self.batches.items[i];
            _ = self.batches.orderedRemove(i);
            batch.handle.release();
            batch.destroy(self.allocator);
        }
    }

    /// The driver no longer runs `token` (its view is going away), but
    /// the record stays: another driver or process resumes it.
    pub fn unclaimMediated(self: *Service, token: []const u8) void {
        const it = self.intentByToken(token) orelse return;
        it.claimed = false;
    }

    /// Hand a record whose view-side setup failed back through normal
    /// adoption immediately; paths come from the ledger, not from the
    /// dying queue object.
    pub fn redispatchMediated(self: *Service, token: []const u8) void {
        const it = self.intentByToken(token) orelse return;
        it.claimed = false;
        self.handToDriver(it);
    }

    pub fn redispatchUserBatch(self: *Service, token: []const u8) void {
        const batch = self.batchByToken(token) orelse return;
        batch.owner = null;
        self.handBatchToDriver(batch);
    }

    pub fn unclaimUserBatch(self: *Service, token: []const u8) void {
        const batch = self.batchByToken(token) orelse return;
        batch.owner = null;
    }

    /// Give up this process's lock without deleting the durable record.
    /// Used when view-side setup cannot even construct a runnable item.
    pub fn abandonMediated(self: *Service, token: []const u8) void {
        for (self.intents.items, 0..) |it, i| {
            if (!std.mem.eql(u8, it.token, token)) continue;
            _ = self.writeIntentOk(it);
            _ = self.intents.orderedRemove(i);
            it.handle.release();
            it.destroy(self.allocator);
            self.refreshViews();
            return;
        }
    }

    fn batchByToken(self: *Service, token: []const u8) ?*UserBatch {
        for (self.batches.items) |batch| if (std.mem.eql(u8, batch.token, token)) return batch;
        return null;
    }

    fn batchForChild(self: *Service, token: []const u8) ?*UserBatch {
        for (self.batches.items) |batch| for (batch.items) |item| {
            if (std.mem.eql(u8, item.token, token)) return batch;
        };
        return null;
    }

    fn childManifestExists(self: *Service, child_token: []const u8, batch_token: []const u8) bool {
        if (self.batchForChild(child_token) != null) return true;
        if (batch_token.len == 0) return false;
        if (self.batchByToken(batch_token) != null) return true;
        const parsed = store.readToken(self.allocator, .batch, batch_token) catch return true;
        const record = parsed orelse return false;
        record.deinit();
        return true;
    }

    fn removeBatch(self: *Service, needle: *UserBatch) bool {
        for (self.batches.items, 0..) |batch, i| {
            if (batch != needle) continue;
            _ = self.batches.orderedRemove(i);
            const removed = batch.handle.destroyRecord();
            if (!removed) {
                self.durability_error = true;
                self.notify("cannot remove completed transfer batch recovery state", .{});
            }
            batch.destroy(self.allocator);
            return removed;
        }
        return false;
    }

    /// Persist one whole cross-host paste command before any child is
    /// admitted. Child tokens are fixed in this single fsynced record.
    pub fn newUserBatch(
        self: *Service,
        src_host: []const u8,
        dst_host: []const u8,
        move: bool,
        batch_id: u64,
        batch_total: usize,
        specs: []const BatchSpec,
        owner: *anyopaque,
    ) ?[]const u8 {
        if (specs.len == 0) return null;
        var estimated_bytes: usize = 512;
        for (specs) |spec| {
            // JSON can expand a path byte to a six-byte \u00xx escape.
            // Reject before allocating/serializing a manifest that the
            // ledger's bounded reader could never recover.
            estimated_bytes +|= 128 +| (spec.src_path.len +| spec.dst_path.len) *| 6;
            if (estimated_bytes > store.MAX_RECORD_BYTES) return null;
        }
        const token = self.newToken() catch return null;
        var handle = (store.open(self.allocator, .batch, token) catch {
            self.allocator.free(token);
            return null;
        }) orelse {
            self.allocator.free(token);
            return null;
        };
        const batch = self.allocator.create(UserBatch) catch {
            handle.release();
            self.allocator.free(token);
            return null;
        };
        const src_host_owned = self.allocator.dupe(u8, src_host) catch {
            handle.release();
            self.allocator.destroy(batch);
            self.allocator.free(token);
            return null;
        };
        const dst_host_owned = self.allocator.dupe(u8, dst_host) catch {
            handle.release();
            self.allocator.free(src_host_owned);
            self.allocator.destroy(batch);
            self.allocator.free(token);
            return null;
        };
        const items = self.allocator.alloc(BatchItemRec, specs.len) catch {
            handle.release();
            self.allocator.free(src_host_owned);
            self.allocator.free(dst_host_owned);
            self.allocator.destroy(batch);
            self.allocator.free(token);
            return null;
        };
        var initialized: usize = 0;
        while (initialized < specs.len) : (initialized += 1) {
            const item_token = self.newToken() catch break;
            const src_path = self.allocator.dupe(u8, specs[initialized].src_path) catch {
                self.allocator.free(item_token);
                break;
            };
            const dst_path = self.allocator.dupe(u8, specs[initialized].dst_path) catch {
                self.allocator.free(item_token);
                self.allocator.free(src_path);
                break;
            };
            items[initialized] = .{
                .token = item_token,
                .src_path = src_path,
                .dst_path = dst_path,
                .conflict_is_dir = specs[initialized].conflict_is_dir,
            };
        }
        if (initialized != specs.len) {
            for (items[0..initialized]) |item| item.destroy(self.allocator);
            self.allocator.free(items);
            handle.release();
            self.allocator.free(src_host_owned);
            self.allocator.free(dst_host_owned);
            self.allocator.destroy(batch);
            self.allocator.free(token);
            return null;
        }
        batch.* = .{
            .handle = handle,
            .token = token,
            .batch_id = batch_id,
            .batch_total = @intCast(batch_total),
            .src_host = src_host_owned,
            .dst_host = dst_host_owned,
            .move = move,
            .no_replace = true,
            .items = items,
            .owner = owner,
        };
        self.batches.append(self.allocator, batch) catch {
            _ = batch.handle.destroyRecord();
            batch.destroy(self.allocator);
            return null;
        };
        if (!self.writeBatchOk(batch)) {
            _ = self.removeBatch(batch);
            return null;
        }
        return batch.token;
    }

    /// Materialize one deterministic child record from its manifest.
    /// Existing children are returned unchanged after restart.
    pub fn materializeUserBatchItem(
        self: *Service,
        batch_token: []const u8,
        index: usize,
        coordinator_host: ?[]const u8,
        dst_override: ?[]const u8,
        no_replace: ?bool,
        owner: *anyopaque,
    ) ?[]const u8 {
        return self.materializeUserBatchItemState(batch_token, index, coordinator_host, dst_override, no_replace, owner, false);
    }

    /// A NEW copy command for endpoints an older, never-started intent
    /// still holds is a supersession, not a second transfer: retire
    /// the stale one so the panel shows ONE row per logical copy (the
    /// duplicated "Copy N items" rows were exactly this — resurrected
    /// queued intents from an earlier session stacking behind a fresh
    /// paste of the same files). An intent that already runs, or
    /// failed with a daemon job behind it, is left alone: it owns
    /// resumable staged state.
    fn retireSupersededDuplicates(self: *Service, kind: store.Kind, src_host: []const u8, src_path: []const u8, dst_host: []const u8, dst_path: []const u8, keep_batch: u64, include_settled: bool) void {
        for (self.intents.items) |it| {
            if (it.retired or it.kind != kind) continue;
            if (keep_batch != 0 and it.batch_id == keep_batch) continue;
            const stale_queued = it.job == 0 and (it.state == .queued or it.state == .waiting_retry);
            // Once the same endpoints have SUCCEEDED, any sibling still
            // pending or claiming failure for them is stale bookkeeping,
            // not a transfer (only a genuinely RUNNING one is left to
            // finish on its own terms).
            const moot = include_settled and
                (it.state == .failed or it.state == .waiting_retry or it.state == .queued);
            if (!stale_queued and !moot) continue;
            if (!std.mem.eql(u8, it.src_host, src_host) or !std.mem.eql(u8, it.src_path, src_path)) continue;
            if (!std.mem.eql(u8, it.dst_host, dst_host) or !std.mem.eql(u8, it.dst_path, dst_path)) continue;
            it.cancel_requested = true;
            it.state = .canceled;
            it.retired = true;
            it.claimed = false;
            self.replaceMessage(it, "superseded by a newer copy of the same files");
            self.writeIntent(it);
        }
    }

    fn materializeUserBatchItemState(
        self: *Service,
        batch_token: []const u8,
        index: usize,
        coordinator_host: ?[]const u8,
        dst_override: ?[]const u8,
        no_replace: ?bool,
        owner: *anyopaque,
        skipped: bool,
    ) ?[]const u8 {
        const batch = self.batchByToken(batch_token) orelse return null;
        if (batch.owner != owner) return null;
        if (index >= batch.items.len) return null;
        const item = batch.items[index];
        if (self.intentByToken(item.token)) |existing| {
            if (skipped and !existing.retired) {
                existing.cancel_requested = true;
                existing.state = .canceled;
                existing.retired = true;
                existing.claimed = false;
                if (!self.writeIntentOk(existing)) return null;
            } else if (!skipped) {
                existing.claimed = true;
            }
            return existing.token;
        }
        var handle = (store.open(self.allocator, .intent, item.token) catch return null) orelse return null;
        const persisted = store.readFile(self.allocator, handle.json_path) catch {
            handle.release();
            return null;
        };
        if (persisted) |rec| {
            defer rec.deinit();
            if (rec.value.rtype != .intent or !store.readableVersion(rec.value.version) or !std.mem.eql(u8, rec.value.intent.token, item.token)) {
                handle.release();
                return null;
            }
            const existing = self.dupIntent(handle, rec.value.intent) catch {
                handle.release();
                return null;
            };
            existing.record_version = rec.value.version;
            if (skipped and !existing.retired) {
                existing.cancel_requested = true;
                existing.state = .canceled;
                existing.retired = true;
            }
            existing.claimed = !skipped;
            self.intents.append(self.allocator, existing) catch {
                existing.handle.release();
                existing.destroy(self.allocator);
                return null;
            };
            if (skipped and !self.writeIntentOk(existing)) return null;
            return existing.token;
        }
        if (!skipped) {
            // ADOPTION: a re-paste of the same endpoints is the same
            // logical transfer. Reusing the existing intent keeps its
            // token — which is the transfer_token the daemon restarts
            // the old job by, staged data and all — instead of minting
            // a sibling that races it to the same destination.
            const dst_path = dst_override orelse item.dst_path;
            for (self.intents.items) |existing| {
                if (existing.retired or existing.kind != .download) continue;
                if (existing.state == .running or existing.state == .submitting or existing.state == .done) continue;
                if (existing.cancel_requested or existing.ack_job != 0) continue;
                if (!std.mem.eql(u8, existing.src_host, batch.src_host) or
                    !std.mem.eql(u8, existing.src_path, item.src_path)) continue;
                if (!std.mem.eql(u8, existing.dst_host, batch.dst_host) or
                    !std.mem.eql(u8, existing.dst_path, dst_path)) continue;
                if (!self.replaceIntentString(&existing.batch_token, batch.token)) break;
                handle.release();
                // A fresh attempt identity: the daemon then RESTARTS
                // the failed job by transfer_token instead of replaying
                // the spent attempt's terminal state.
                if (self.newToken()) |fresh| {
                    self.allocator.free(existing.client_token);
                    existing.client_token = fresh;
                } else |_| {}
                existing.batch_id = batch.batch_id;
                existing.batch_total = batch.batch_total;
                existing.order = self.nextOrder();
                existing.state = .queued;
                existing.attempts = 0;
                existing.job = 0;
                existing.mediated = true;
                existing.user_copy = true;
                existing.claimed = true;
                existing.paused = false;
                existing.delete_src_after = batch.move;
                existing.no_replace = no_replace orelse batch.no_replace;
                existing.coordinator_set = coordinator_host != null;
                if (!self.replaceIntentString(&existing.coordinator_host, coordinator_host orelse ""))
                    existing.coordinator_set = false;
                self.replaceMessage(existing, "");
                self.writeIntent(existing);
                return existing.token;
            }
            // Anything not adopted (a second stale duplicate) is
            // superseded rather than left to race the new transfer.
            self.retireSupersededDuplicates(.download, batch.src_host, item.src_path, batch.dst_host, dst_path, batch.batch_id, false);
        }
        const it = self.dupIntent(handle, .{
            .token = item.token,
            .kind = .download,
            .src = .{ .host = batch.src_host, .path = item.src_path },
            .dst = .{ .host = batch.dst_host, .path = dst_override orelse item.dst_path },
            .state = if (skipped) .canceled else .running,
            .order = self.nextOrder(),
            .mediated = true,
            .user_copy = true,
            .batch_id = batch.batch_id,
            .batch_total = batch.batch_total,
            .batch_token = batch.token,
            .coordinator_host = coordinator_host orelse "",
            .coordinator_set = coordinator_host != null,
            .delete_src_after = batch.move,
            .no_replace = no_replace orelse batch.no_replace,
            .cancel_requested = skipped,
            .retired = skipped,
        }) catch {
            handle.release();
            return null;
        };
        it.claimed = !skipped;
        self.intents.append(self.allocator, it) catch {
            _ = it.handle.destroyRecord();
            it.destroy(self.allocator);
            return null;
        };
        if (!self.writeIntentOk(it)) {
            self.removeIntent(it);
            return null;
        }
        return it.token;
    }

    pub fn userBatchItemMaterialized(self: *Service, batch_token: []const u8, index: usize) bool {
        const batch = self.batchByToken(batch_token) orelse return false;
        if (index >= batch.items.len) return false;
        return self.intentByToken(batch.items[index].token) != null;
    }

    pub fn markUserBatchConflict(self: *Service, batch_token: []const u8, index: usize, is_dir: bool) bool {
        const batch = self.batchByToken(batch_token) orelse return false;
        if (index >= batch.items.len) return false;
        batch.items[index].conflict_is_dir = is_dir;
        return self.writeBatchOk(batch);
    }

    pub fn skipUserBatchItem(self: *Service, batch_token: []const u8, index: usize, owner: *anyopaque) bool {
        return self.materializeUserBatchItemState(batch_token, index, null, null, null, owner, true) != null;
    }

    /// Remove a manifest only after every deterministic child exists.
    pub fn finishUserBatch(self: *Service, batch_token: []const u8) bool {
        const batch = self.batchByToken(batch_token) orelse return true;
        for (batch.items) |item| {
            if (self.intentByToken(item.token) == null) return false;
        }
        var batch_index: ?usize = null;
        for (self.batches.items, 0..) |candidate, i| {
            if (candidate == batch) {
                batch_index = i;
                break;
            }
        }
        const index = batch_index orelse return false;
        if (!batch.handle.destroyRecord()) {
            self.durability_error = true;
            self.notify("cannot remove completed transfer batch recovery state", .{});
            batch.destroy(self.allocator);
            _ = self.batches.orderedRemove(index);
            return false;
        }
        _ = self.batches.orderedRemove(index);
        var i: usize = 0;
        while (i < self.intents.items.len) {
            const it = self.intents.items[i];
            const is_child = for (batch.items) |item| {
                if (std.mem.eql(u8, item.token, it.token)) break true;
            } else false;
            if (is_child and it.retired and it.ack_job == 0) {
                self.removeIntentMode(it, false);
                continue;
            }
            i += 1;
        }
        batch.destroy(self.allocator);
        self.refreshViews();
        return true;
    }

    /// Record a client-mediated transfer so it survives a restart.
    /// @return the ledger token, borrowed and stable until the record
    /// is finished; null when no record could be created.
    pub fn newMediated(
        self: *Service,
        src_host: []const u8,
        src_path: []const u8,
        dst_host: []const u8,
        dst_path: []const u8,
        opts: struct {
            app_id: []const u8 = "",
            open_when_done: bool = false,
            delete_src_after: bool = false,
            no_replace: bool = false,
            watch_after: bool = false,
        },
    ) ?[]const u8 {
        const token = self.newToken() catch return null;
        defer self.allocator.free(token);
        var handle = (store.open(self.allocator, .intent, token) catch return null) orelse return null;
        const it = self.dupIntent(handle, .{
            .token = token,
            .kind = .download,
            .src = .{ .host = src_host, .path = src_path },
            .dst = .{ .host = dst_host, .path = dst_path },
            .app_id = opts.app_id,
            .state = .running,
            .order = self.nextOrder(),
            .mediated = true,
            .open_when_done = opts.open_when_done,
            .delete_src_after = opts.delete_src_after,
            .no_replace = opts.no_replace,
            .watch_after = opts.watch_after,
        }) catch {
            handle.release();
            return null;
        };
        it.claimed = true;
        self.intents.append(self.allocator, it) catch {
            _ = it.handle.destroyRecord();
            it.destroy(self.allocator);
            return null;
        };
        if (!self.writeIntentOk(it)) {
            self.removeIntent(it);
            return null;
        }
        return it.token;
    }

    /// Record a normal copy/move before it enters the view's queue.
    /// The returned record token is distinct from the per-attempt
    /// daemon token, so failed terminal jobs can be retried safely.
    pub fn newUserCopy(
        self: *Service,
        src_host: []const u8,
        src_path: []const u8,
        dst_host: []const u8,
        dst_path: []const u8,
        move: bool,
        no_replace: bool,
        batch_id: u64,
        batch_total: usize,
        coordinator_host: ?[]const u8,
    ) ?[]const u8 {
        const token = self.newToken() catch return null;
        defer self.allocator.free(token);
        var handle = (store.open(self.allocator, .intent, token) catch return null) orelse return null;
        const it = self.dupIntent(handle, .{
            .token = token,
            .kind = .download,
            .src = .{ .host = src_host, .path = src_path },
            .dst = .{ .host = dst_host, .path = dst_path },
            .state = .running,
            .order = self.nextOrder(),
            .mediated = true,
            .user_copy = true,
            .batch_id = batch_id,
            .batch_total = @intCast(batch_total),
            .coordinator_host = coordinator_host orelse "",
            .coordinator_set = coordinator_host != null,
            .delete_src_after = move,
            .no_replace = no_replace,
        }) catch {
            handle.release();
            return null;
        };
        it.claimed = true;
        self.intents.append(self.allocator, it) catch {
            _ = it.handle.destroyRecord();
            it.destroy(self.allocator);
            return null;
        };
        if (!self.writeIntentOk(it)) {
            self.removeIntent(it);
            return null;
        }
        return it.token;
    }

    /// Current idempotency key for one externally-driven attempt.
    pub fn mediatedClientToken(self: *Service, token: []const u8) ?[]const u8 {
        const it = self.intentByToken(token) orelse return null;
        return it.client_token;
    }

    pub fn mediatedAttempts(self: *Service, token: []const u8) u8 {
        const it = self.intentByToken(token) orelse return 0;
        return it.attempts;
    }

    pub fn mediatedRetryDue(self: *Service, token: []const u8) i64 {
        const it = self.intentByToken(token) orelse return 0;
        return it.retry_due_ms;
    }

    pub fn requestMediatedCancel(self: *Service, token: []const u8) bool {
        const it = self.intentByToken(token) orelse return false;
        const txn = IntentTxn.begin(self, it);
        it.cancel_requested = true;
        return txn.commit();
    }

    /// Cancel work that has not been submitted to a daemon yet.
    pub fn cancelMediatedQueued(self: *Service, token: []const u8) bool {
        const it = self.intentByToken(token) orelse return false;
        if (it.submission_uncertain) return false;
        const txn = IntentTxn.begin(self, it);
        it.cancel_requested = true;
        it.submission_uncertain = false;
        it.state = .canceled;
        it.retired = true;
        if (!txn.commit()) return false;
        if (!self.childManifestExists(it.token, it.batch_token)) self.removeIntent(it);
        self.refreshViews();
        return true;
    }

    /// Complete cancellation after an authoritative start rejection.
    pub fn cancelRejectedMediated(self: *Service, token: []const u8) bool {
        const it = self.intentByToken(token) orelse return false;
        if (!it.cancel_requested) return false;
        const txn = IntentTxn.begin(self, it);
        it.submission_uncertain = false;
        it.state = .canceled;
        it.retired = true;
        if (!txn.commit()) return false;
        if (!self.childManifestExists(it.token, it.batch_token)) self.removeIntent(it);
        self.refreshViews();
        return true;
    }

    /// Mark an explicit start rejection as proof that no submission is live.
    pub fn mediatedSubmissionRejected(self: *Service, token: []const u8) bool {
        const it = self.intentByToken(token) orelse return false;
        it.submission_uncertain = false;
        return true;
    }

    pub fn mediatedCancelRequested(self: *Service, token: []const u8) bool {
        const it = self.intentByToken(token) orelse return false;
        return it.cancel_requested;
    }

    pub fn mediatedPaused(self: *Service, token: []const u8) bool {
        const it = self.intentByToken(token) orelse return false;
        return it.paused;
    }

    pub fn mediatedRunnable(self: *Service, token: []const u8) bool {
        const it = self.intentByToken(token) orelse return false;
        return !it.retired and it.state != .failed and it.state != .canceled and it.state != .done and
            (it.state != .waiting_retry or it.retry_due_ms <= nowMs());
    }

    pub fn mediatedAckPending(self: *Service, token: []const u8) bool {
        const it = self.intentByToken(token) orelse return false;
        return it.ack_job != 0;
    }

    fn replaceIntentString(self: *Service, target: *[]u8, value: []const u8) bool {
        const replacement = self.allocator.dupe(u8, value) catch return false;
        self.allocator.free(target.*);
        target.* = replacement;
        return true;
    }

    /// Persist the daemon selected for this idempotent attempt before
    /// the request can be sent.
    pub fn setMediatedCoordinator(self: *Service, token: []const u8, host: []const u8) bool {
        const it = self.intentByToken(token) orelse return false;
        if (!it.coordinator_set or !std.mem.eql(u8, it.coordinator_host, host)) {
            if (!self.replaceIntentString(&it.coordinator_host, host)) return false;
            it.coordinator_set = true;
            self.writeIntent(it);
        }
        return !self.durability_error;
    }

    /// Record the daemon job identity once its start reply arrives.
    pub fn mediatedJobStarted(self: *Service, token: []const u8, job: u64) bool {
        const it = self.intentByToken(token) orelse return false;
        it.job = job;
        it.submission_uncertain = false;
        it.state = .running;
        it.retry_due_ms = 0;
        self.writeIntent(it);
        return !self.durability_error;
    }

    /// Fence the interval between sending a start request and learning
    /// its job id, so cancellation waits for and targets the real job.
    pub fn mediatedSubmissionStarted(self: *Service, token: []const u8) bool {
        const it = self.intentByToken(token) orelse return false;
        if (it.retired or it.state == .canceled or it.state == .done) return false;
        it.record_version = store.VERSION;
        it.state = .submitting;
        it.submission_uncertain = true;
        return self.writeIntentOk(it);
    }

    /// Persist terminal acknowledgment state before retry/retirement.
    pub fn noteMediatedTerminal(self: *Service, token: []const u8, host: []const u8, job: u64, finish: bool) bool {
        const it = self.intentByToken(token) orelse return false;
        if (!self.replaceIntentString(&it.ack_host, host)) return false;
        it.ack_job = job;
        it.ack_durable = false;
        it.submission_uncertain = false;
        const terminal = finish;
        it.retired = terminal;
        it.state = if (terminal and it.cancel_requested) .canceled else if (terminal) .done else .waiting_retry;
        if (!self.writeIntentOk(it)) {
            // A later sweep retries the write and hands the durable ACK
            // back to a driver once it succeeds.
            it.claimed = false;
            return false;
        }
        // This exact copy just succeeded: siblings still claiming these
        // endpoints failed (a crashed session's leftovers) are moot.
        if (it.state == .done)
            self.retireSupersededDuplicates(it.kind, it.src_host, it.src_path, it.dst_host, it.dst_path, it.batch_id, true);
        return true;
    }

    /// Clear one durable acknowledgment, deleting a retired intent only
    /// after the coordinator confirmed it no longer retains the job.
    pub fn mediatedAcked(self: *Service, token: []const u8, job: u64) bool {
        const it = self.intentByToken(token) orelse return false;
        if (it.ack_job != job) return false;
        it.ack_job = 0;
        it.ack_durable = false;
        if (!self.replaceIntentString(&it.ack_host, "")) return false;
        if (it.retired) {
            if (self.childManifestExists(it.token, it.batch_token)) {
                self.writeIntent(it);
            } else {
                self.removeIntent(it);
            }
        } else {
            self.writeIntent(it);
        }
        self.refreshViews();
        return true;
    }

    /// Record one failed mediated attempt and decide whether it may
    /// retry automatically. A spent record remains visible and durable.
    pub fn recordMediatedFailure(self: *Service, token: []const u8, message: []const u8, retryable: bool) bool {
        const it = self.intentByToken(token) orelse return false;
        if (!retryable) {
            self.replaceMessage(it, message);
            it.retry_due_ms = 0;
            it.state = .failed;
            it.submission_uncertain = false;
            it.claimed = false;
            if (!self.writeIntentOk(it)) return false;
            self.refreshViews();
            return false;
        }
        it.attempts +|= 1;
        self.replaceMessage(it, message);
        // Re-submitting an uncertain idempotency token recovers the
        // same possible daemon job; it is cancellation/source-safety
        // resolution, not permission to create another work attempt.
        const retry = it.submission_uncertain or automaticRetryAllowed(it.attempts, true);
        it.state = if (retry) .waiting_retry else .failed;
        it.retry_due_ms = if (retry) nowMs() + RETRY_DELAY_MS else 0;
        if (!retry) it.claimed = false;
        if (!self.writeIntentOk(it)) {
            if (retry) it.claimed = false;
            return false;
        }
        if (retry) self.armTransferRetry();
        self.refreshViews();
        return retry and !self.durability_error;
    }

    pub fn setMediatedFailed(self: *Service, token: []const u8, message: []const u8, unclaim: bool) void {
        const it = self.intentByToken(token) orelse return;
        self.replaceMessage(it, message);
        it.state = .failed;
        it.retry_due_ms = 0;
        if (unclaim) it.claimed = false;
        self.writeIntent(it);
    }

    pub fn retryMediated(self: *Service, token: []const u8) void {
        const it = self.intentByToken(token) orelse return;
        if (it.record_version < store.VERSION or it.state != .failed or it.ack_job != 0) return;
        const fresh = self.newToken() catch return;
        self.allocator.free(it.client_token);
        it.client_token = fresh;
        it.attempts = 0;
        it.retry_due_ms = 0;
        it.state = .queued;
        it.submission_uncertain = false;
        it.retired = false;
        it.claimed = false;
        if (!self.writeIntentOk(it)) return;
        self.handToDriver(it);
        self.refreshViews();
    }

    /// Reset a spent attempt for the live daemon-row Retry button; the
    /// caller already owns the row and submits the replacement itself.
    pub fn restartMediatedAttempt(self: *Service, token: []const u8) bool {
        const it = self.intentByToken(token) orelse return false;
        if (!it.claimed or it.state != .failed or it.ack_job != 0) return false;
        const fresh = self.newToken() catch return false;
        self.allocator.free(it.client_token);
        it.client_token = fresh;
        it.attempts = 0;
        it.retry_due_ms = 0;
        it.job = 0;
        it.state = .queued;
        it.submission_uncertain = false;
        it.retired = false;
        if (!self.writeIntentOk(it)) {
            it.claimed = false;
            return false;
        }
        return true;
    }

    /// User dismissed a terminal mediated attempt. Preserve any owed
    /// daemon acknowledgment and delete the record only after it lands.
    pub fn dismissMediated(self: *Service, token: []const u8) bool {
        const it = self.intentByToken(token) orelse return true;
        if (it.cancel_requested and it.state != .canceled and it.state != .done) return false;
        if (it.ack_job == 0) {
            it.retired = true;
            it.state = .canceled;
            if (!self.writeIntentOk(it)) return false;
            if (!self.childManifestExists(it.token, it.batch_token)) self.removeIntent(it);
            return true;
        }
        it.retired = true;
        it.state = .canceled;
        return self.writeIntentOk(it);
    }

    /// Switch a user-copy intent to the client-mediated fallback used
    /// when the connected daemon predates cross_move.
    pub fn useMediatedFallback(self: *Service, token: []const u8) bool {
        const it = self.intentByToken(token) orelse return false;
        it.coordinator_set = false;
        it.submission_uncertain = false;
        if (!self.replaceIntentString(&it.coordinator_host, "")) return false;
        self.writeIntent(it);
        return !self.durability_error;
    }

    /// Mint the next daemon idempotency key after a terminal attempt.
    pub fn renewMediatedAttempt(self: *Service, token: []const u8, coordinator_host: []const u8, count_attempt: bool) bool {
        const it = self.intentByToken(token) orelse return false;
        if (it.retired or it.cancel_requested) return false;
        const fresh = self.newToken() catch return false;
        if (!self.replaceIntentString(&it.coordinator_host, coordinator_host)) {
            self.allocator.free(fresh);
            return false;
        }
        self.allocator.free(it.client_token);
        it.client_token = fresh;
        it.coordinator_set = true;
        it.job = 0;
        it.submission_uncertain = false;
        if (count_attempt) it.attempts +|= 1;
        it.state = .waiting_retry;
        it.retry_due_ms = nowMs() + RETRY_DELAY_MS;
        if (!self.writeIntentOk(it)) {
            it.claimed = false;
            return false;
        }
        self.armTransferRetry();
        return true;
    }

    /// Fold a lost coordinator into the same bounded retry policy as a
    /// structured transport failure. Work that had not started waits but
    /// does not spend an attempt.
    pub fn recordMediatedTransportLoss(self: *Service, token: []const u8, message: []const u8, attempt_started: bool) bool {
        const it = self.intentByToken(token) orelse return false;
        if (it.retired or it.state == .done or it.state == .canceled or it.state == .failed)
            return false;
        if (it.state == .waiting_retry) {
            // The view-side retry object died with its HostConn. Drop
            // that volatile claim so this or another driver can rebuild
            // it from the durable record when the deadline expires.
            it.claimed = false;
            if (attempt_started or it.job != 0) {
                it.record_version = store.VERSION;
                it.submission_uncertain = true;
            }
            if (!self.writeIntentOk(it)) return false;
            self.armTransferRetry();
            return true;
        }
        self.replaceMessage(it, message);
        if (attempt_started and !it.cancel_requested) it.attempts +|= 1;
        const unresolved = it.submission_uncertain or attempt_started or it.job != 0;
        if (unresolved) it.record_version = store.VERSION;
        const retry = it.cancel_requested or unresolved or automaticRetryAllowed(it.attempts, true);
        it.state = if (retry) .waiting_retry else .failed;
        it.retry_due_ms = if (retry) nowMs() + RETRY_DELAY_MS else 0;
        it.submission_uncertain = unresolved;
        // Connection teardown destroys every live view-side attempt,
        // including one that is waiting only to re-assert cancellation.
        it.claimed = false;
        if (!self.writeIntentOk(it)) {
            return false;
        }
        if (retry) self.armTransferRetry();
        self.refreshViews();
        return retry;
    }

    /// Retry durable cleanup after a canceled daemon job ended ambiguously.
    pub fn recordMediatedCancellationFailure(self: *Service, token: []const u8, message: []const u8) bool {
        const it = self.intentByToken(token) orelse return false;
        if (!it.cancel_requested or it.ack_job != 0) return false;
        const scheduled = self.scheduleCancellationRecovery(it, message);
        self.refreshViews();
        return scheduled;
    }

    pub fn setMediatedPaused(self: *Service, token: []const u8, paused: bool) bool {
        const it = self.intentByToken(token) orelse return false;
        if (it.paused == paused) return true;
        const previous = it.paused;
        it.paused = paused;
        if (!self.writeIntentOk(it)) {
            it.paused = previous;
            return false;
        }
        return true;
    }

    /// The mediated transfer reached a terminal state; drop its record.
    pub fn finishMediated(self: *Service, token: []const u8) bool {
        const it = self.intentByToken(token) orelse return true;
        it.retired = true;
        it.state = if (it.cancel_requested) .canceled else .done;
        it.submission_uncertain = false;
        if (!self.writeIntentOk(it)) return false;
        // This exact copy just succeeded: siblings still claiming these
        // endpoints failed (a crashed session's leftovers) are moot.
        if (it.state == .done)
            self.retireSupersededDuplicates(it.kind, it.src_host, it.src_path, it.dst_host, it.dst_path, it.batch_id, true);
        return self.retire(it);
    }

    // ── edit watches ────────────────────────────────────────────

    fn watchByToken(self: *Service, token: []const u8) ?*Watch {
        for (self.watches.items) |w| if (std.mem.eql(u8, w.token, token)) return w;
        return null;
    }

    fn ensureWatch(self: *Service, token: []const u8, host: []const u8, remote_path: []const u8, cache_path: []const u8) ?*Watch {
        if (self.watchByToken(token)) |w| return w;
        var handle = (store.open(self.allocator, .watch, token) catch return null) orelse return null;
        const w = self.dupWatch(handle, .{ .token = token, .host = host, .remote_path = remote_path, .cache_path = cache_path }) catch {
            handle.release();
            return null;
        };
        self.watches.append(self.allocator, w) catch {
            _ = w.handle.destroyRecord();
            w.destroy(self.allocator);
            return null;
        };
        return w;
    }

    fn fingerprint(path: []const u8) ?struct { size: u64, mtime_ns: i64 } {
        var z: [4096]u8 = undefined;
        var st: c.struct_stat = undefined;
        if (c.stat(pathz.pathZ(&z, path) catch return null, &st) != 0) return null;
        const ts = if (@hasField(c.struct_stat, "st_mtim")) st.st_mtim else st.st_mtimespec;
        return .{ .size = @intCast(st.st_size), .mtime_ns = @as(i64, ts.tv_sec) * 1_000_000_000 + @as(i64, @intCast(ts.tv_nsec)) };
    }

    fn captureFingerprint(self: *Service, w: *Watch) void {
        _ = self;
        const fp = fingerprint(w.cache_path) orelse return;
        w.synced_size = fp.size;
        w.synced_mtime_ns = fp.mtime_ns;
    }

    fn detectOfflineEdit(self: *Service, w: *Watch) void {
        const fp = fingerprint(w.cache_path) orelse return;
        if (fp.size != w.synced_size or fp.mtime_ns != w.synced_mtime_ns) {
            w.dirty_generation += 1;
            self.writeWatch(w);
        }
    }

    fn armWatch(self: *Service, w: *Watch) void {
        _ = self;
        if (w.monitor != null) return;
        const parent = std.fs.path.dirname(w.cache_path) orelse return;
        var z: [4096:0]u8 = undefined;
        const pz = std.fmt.bufPrintZ(&z, "{s}", .{parent}) catch return;
        const file = c.g_file_new_for_path(pz.ptr);
        defer c.g_object_unref(file);
        w.monitor = c.g_file_monitor_directory(file, c.G_FILE_MONITOR_NONE, null, null);
        if (w.monitor) |m| _ = c.g_signal_connect_data(m, "changed", @ptrCast(&onWatchChanged), @ptrCast(w), null, c.G_CONNECT_DEFAULT);
    }

    fn onWatchChanged(_: *c.GFileMonitor, _: ?*c.GFile, _: ?*c.GFile, event: c.GFileMonitorEvent, user: ?*anyopaque) callconv(.c) void {
        if (event != c.G_FILE_MONITOR_EVENT_CHANGES_DONE_HINT and event != c.G_FILE_MONITOR_EVENT_CREATED and event != c.G_FILE_MONITOR_EVENT_MOVED_IN) return;
        const w = cast.userData(Watch, user);
        const fp = fingerprint(w.cache_path) orelse return;
        if (fp.size == w.synced_size and fp.mtime_ns == w.synced_mtime_ns) return;
        w.dirty_generation += 1;
        w.service.writeWatch(w);
        w.service.queueDirtyWatches();
        w.service.pump();
    }

    fn queueDirtyWatches(self: *Service) void {
        for (self.watches.items) |w| {
            if (w.dirty_generation <= w.synced_generation) continue;
            var active = false;
            for (self.intents.items) |it| if (it.kind == .upload and !it.retired and std.mem.eql(u8, it.watch_token, w.token)) {
                active = true;
                break;
            };
            if (!active) self.appendIntent(.upload, "", w.cache_path, w.host, w.remote_path, "", w.token, w.dirty_generation, null);
        }
    }
};

/// Scheduler identity of a transfer destination: the host, plus the
/// filesystem device for local paths so two copies onto one disk
/// serialize while one per disk do not. A remote destination is
/// identified by its host alone -- the device lives on the far side,
/// where this process cannot stat it.
pub fn destinationKey(host: []const u8, path: []const u8) u64 {
    return xferqueue.destKey(host, if (host.len == 0) localDevice(path) else 0);
}

/// st_dev of the nearest existing ancestor of `path` (0 when unknown:
/// unknown devices then share one key, which serializes rather than
/// over-parallelizes).
fn localDevice(path: []const u8) u64 {
    var probe = path;
    while (probe.len > 0) {
        var z: [4096]u8 = undefined;
        var st: c.struct_stat = undefined;
        if (pathz.pathZ(&z, probe)) |pz| {
            if (c.stat(pz, &st) == 0) return @intCast(st.st_dev);
        } else |_| {}
        probe = std.fs.path.dirname(probe) orelse return 0;
    }
    return 0;
}

var shared: ?*Service = null;

test "closing a non-primary driver hands its transfer to a live pane" {
    const t = std.testing;
    const Capture = struct {
        calls: usize = 0,
        batch_calls: usize = 0,
        token: []const u8 = "",
        service: ?*Service = null,
        accept_batch: bool = true,

        fn adopt(ctx: *anyopaque, rec: MediatedRec) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            self.token = rec.token;
        }

        fn adoptBatch(ctx: *anyopaque, rec: BatchRec) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.batch_calls += 1;
            self.token = rec.token;
            if (!self.accept_batch) self.service.?.unclaimUserBatch(rec.token);
        }

        fn refresh(_: *anyopaque) void {}
    };

    var service = Service{ .allocator = t.allocator };
    defer service.drivers.deinit(t.allocator);
    defer service.intents.deinit(t.allocator);
    defer service.batches.deinit(t.allocator);
    var primary = Capture{ .service = &service, .accept_batch = false };
    var fallback = Capture{ .service = &service };
    var origin = Capture{};
    try service.drivers.append(t.allocator, .{ .ctx = @ptrCast(&primary), .callback = &Capture.adopt, .batch_callback = &Capture.adoptBatch, .refresh = &Capture.refresh });
    try service.drivers.append(t.allocator, .{ .ctx = @ptrCast(&fallback), .callback = &Capture.adopt, .batch_callback = &Capture.adoptBatch, .refresh = &Capture.refresh });
    try service.drivers.append(t.allocator, .{ .ctx = @ptrCast(&origin), .callback = &Capture.adopt, .batch_callback = &Capture.adoptBatch, .refresh = &Capture.refresh });
    var intent = Intent{
        .handle = .{
            .allocator = t.allocator,
            .rtype = .intent,
            .token = @constCast(""),
            .json_path = @constCast(""),
            .lock_path = @constCast(""),
            .lock_fd = -1,
        },
        .token = @constCast("copy-record"),
        .client_token = @constCast("attempt"),
        .kind = .download,
        .src_host = @constCast(""),
        .src_path = @constCast("/source"),
        .dst_host = @constCast("box"),
        .dst_path = @constCast("/dest"),
        .app_id = @constCast(""),
        .state = .running,
        .job = 0,
        .order = 1,
        .watch_token = @constCast(""),
        .submitted_generation = 0,
        .message = @constCast(""),
        .coordinator_host = @constCast(""),
        .ack_host = @constCast(""),
        .batch_token = @constCast(""),
        .mediated = true,
        .user_copy = true,
        .claimed = false, // origin unclaimed it before teardown
    };
    try service.intents.append(t.allocator, &intent);
    var no_items: [0]BatchItemRec = .{};
    var batch = UserBatch{
        .handle = .{
            .allocator = t.allocator,
            .rtype = .batch,
            .token = @constCast(""),
            .json_path = @constCast(""),
            .lock_path = @constCast(""),
            .lock_fd = -1,
        },
        .token = @constCast("batch-record"),
        .batch_id = 9,
        .batch_total = 2,
        .src_host = @constCast(""),
        .dst_host = @constCast("box"),
        .move = false,
        .no_replace = true,
        .items = &no_items,
        .owner = @ptrCast(&origin),
    };
    try service.batches.append(t.allocator, &batch);

    service.removeMediatedDriver(@ptrCast(&origin));
    try t.expectEqual(@as(usize, 1), primary.calls);
    try t.expectEqual(@as(usize, 1), primary.batch_calls);
    try t.expectEqual(@as(usize, 1), fallback.batch_calls);
    try t.expectEqual(@as(?*anyopaque, @ptrCast(&fallback)), batch.owner);
    try t.expectEqualStrings("batch-record", fallback.token);
}

test "a durable batch materializes deterministic child records" {
    const t = std.testing;
    const Cleanup = struct {
        fn destroy(service: *Service, allocator: std.mem.Allocator) void {
            for (service.intents.items) |it| {
                _ = it.handle.destroyRecord();
                it.destroy(allocator);
            }
            service.intents.deinit(allocator);
            for (service.batches.items) |batch| {
                _ = batch.handle.destroyRecord();
                batch.destroy(allocator);
            }
            service.batches.deinit(allocator);
            service.drivers.deinit(allocator);
        }

        fn release(service: *Service, allocator: std.mem.Allocator) void {
            for (service.intents.items) |it| {
                it.handle.release();
                it.destroy(allocator);
            }
            service.intents.deinit(allocator);
            for (service.batches.items) |batch| {
                batch.handle.release();
                batch.destroy(allocator);
            }
            service.batches.deinit(allocator);
            service.drivers.deinit(allocator);
        }
    };
    const Capture = struct {
        mediated: usize = 0,
        batches: usize = 0,

        fn adopt(ctx: *anyopaque, _: MediatedRec) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.mediated += 1;
        }

        fn adoptBatch(ctx: *anyopaque, _: BatchRec) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.batches += 1;
        }

        fn refresh(_: *anyopaque) void {}
    };
    const old_state = if (@import("../util/profile.zig").getenv("XDG_STATE_HOME")) |value|
        try t.allocator.dupe(u8, value)
    else
        null;
    defer {
        if (old_state) |value| {
            var z: [4096:0]u8 = undefined;
            if (std.fmt.bufPrintZ(&z, "{s}", .{value})) |state| _ = c.setenv("XDG_STATE_HOME", state.ptr, 1) else |_| {}
            t.allocator.free(value);
        } else {
            _ = c.unsetenv("XDG_STATE_HOME");
        }
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var state_buf: [4096:0]u8 = undefined;
    const state = try std.fmt.bufPrintZ(&state_buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    _ = c.setenv("XDG_STATE_HOME", state.ptr, 1);

    var service = Service{ .allocator = t.allocator };
    var service_owned = true;
    defer if (service_owned) Cleanup.destroy(&service, t.allocator);
    const specs = [_]BatchSpec{
        .{ .src_path = "/source/a", .dst_path = "/dest/a" },
        .{ .src_path = "/source/b", .dst_path = "/dest/b" },
    };
    var owner: u8 = 0;
    const batch_token = service.newUserBatch("", "box", true, 77, 2, &specs, @ptrCast(&owner)) orelse return error.BatchCreateFailed;
    const child_token = service.materializeUserBatchItem(batch_token, 1, "relay", null, null, @ptrCast(&owner)) orelse return error.ChildCreateFailed;
    const child = service.intentByToken(child_token) orelse return error.ChildMissing;
    try t.expectEqual(@as(u64, 77), child.batch_id);
    try t.expectEqual(@as(u64, 2), child.batch_total);
    try t.expectEqualStrings(batch_token, child.batch_token);
    try t.expect(child.delete_src_after and child.coordinator_set);
    try t.expectEqualStrings("/source/b", child.src_path);
    try t.expectEqualStrings("relay", child.coordinator_host);
    try t.expect(service.mediatedSubmissionStarted(child_token));
    _ = service.cancel(child_token);
    const canceling = service.intentByToken(child_token) orelse return error.ChildMissing;
    try t.expect(canceling.cancel_requested and !canceling.retired);
    try t.expectEqual(store.State.submitting, canceling.state);
    const canceling_record = (try store.readToken(t.allocator, .intent, child_token)) orelse return error.ChildMissing;
    defer canceling_record.deinit();
    try t.expect(canceling_record.value.intent.cancel_requested and !canceling_record.value.intent.retired);
    try t.expectEqual(store.State.submitting, canceling_record.value.intent.state);
    try t.expect(service.finishMediated(child_token));
    try t.expectEqual(@as(usize, 1), service.intents.items.len);

    const batch_token_copy = try t.allocator.dupe(u8, batch_token);
    defer t.allocator.free(batch_token_copy);
    const child_token_copy = try t.allocator.dupe(u8, child_token);
    defer t.allocator.free(child_token_copy);
    Cleanup.release(&service, t.allocator);
    service_owned = false;

    var recovered = Service{ .allocator = t.allocator };
    defer Cleanup.destroy(&recovered, t.allocator);
    var capture = Capture{};
    try recovered.drivers.append(t.allocator, .{
        .ctx = @ptrCast(&capture),
        .callback = &Capture.adopt,
        .batch_callback = &Capture.adoptBatch,
        .refresh = &Capture.refresh,
    });
    recovered.adoptOrphans();
    try t.expectEqual(@as(usize, 1), capture.batches);
    try t.expectEqual(@as(usize, 0), capture.mediated);
    try t.expectEqual(@as(usize, 1), recovered.batches.items.len);
    try t.expectEqual(@as(usize, 1), recovered.intents.items.len);
    try t.expect(!recovered.mediatedRunnable(child_token_copy));
    try t.expectEqualStrings(child_token_copy, recovered.materializeUserBatchItem(batch_token_copy, 1, "relay", null, null, @ptrCast(&capture)) orelse return error.ChildMissing);

    var intruder: u8 = 0;
    try t.expectEqual(@as(?[]const u8, null), recovered.materializeUserBatchItem(batch_token_copy, 0, "relay", null, null, @ptrCast(&intruder)));
    try t.expect(recovered.skipUserBatchItem(batch_token_copy, 0, @ptrCast(&capture)));
    const skipped = recovered.intentByToken(recovered.batches.items[0].items[0].token) orelse return error.ChildMissing;
    try t.expect(skipped.retired and skipped.cancel_requested and skipped.state == .canceled);
    const skipped_record = (try store.readToken(t.allocator, .intent, skipped.token)) orelse return error.ChildMissing;
    defer skipped_record.deinit();
    try t.expect(skipped_record.value.intent.retired and skipped_record.value.intent.cancel_requested);
    try t.expectEqual(store.State.canceled, skipped_record.value.intent.state);
    try t.expect(recovered.finishUserBatch(batch_token_copy));
    try t.expectEqual(@as(usize, 0), recovered.batches.items.len);
    try t.expectEqual(@as(usize, 0), recovered.intents.items.len);
}

test "automatic retry policy is transient-only and allows three retries" {
    try std.testing.expect(retryableFailureKind("transport"));
    try std.testing.expect(retryableFailureKind("unreachable"));
    try std.testing.expect(!retryableFailureKind("permanent"));
    try std.testing.expect(!retryableFailureKind(""));
    try std.testing.expect(automaticRetryAllowed(1, true));
    try std.testing.expect(automaticRetryAllowed(3, true));
    try std.testing.expect(!automaticRetryAllowed(4, true));
    try std.testing.expect(!automaticRetryAllowed(1, false));
}

/// A fully-initialized test Intent, off the ledger.
///
/// This build is ReleaseFast only, so `var it: Intent = undefined` plus
/// a few assignments leaves real stack garbage in every other field --
/// including the ones a predicate under test reads. Going through
/// `dupIntent` gives every field its declared default instead. The
/// handle is inert (lock_fd -1, empty paths); free with
/// `destroyTestIntent`.
fn testIntent(service: *Service, value: store.Intent) !*Intent {
    const a = service.allocator;
    const token = try a.dupe(u8, value.token);
    errdefer a.free(token);
    const json_path = try a.dupe(u8, "");
    errdefer a.free(json_path);
    const lock_path = try a.dupe(u8, "");
    errdefer a.free(lock_path);
    return service.dupIntent(.{
        .allocator = a,
        .rtype = .intent,
        .token = token,
        .json_path = json_path,
        .lock_path = lock_path,
        .lock_fd = -1,
    }, value);
}

fn destroyTestIntent(it: *Intent, allocator: std.mem.Allocator) void {
    it.handle.release();
    it.destroy(allocator);
}

test "cancellation retries only when daemon work may still exist" {
    const t = std.testing;
    var service = Service{ .allocator = t.allocator };
    const it = try testIntent(&service, .{
        .token = "retry-eligible",
        .state = .waiting_retry,
        .cancel_requested = true,
    });
    defer destroyTestIntent(it, t.allocator);
    try t.expect(!transferRetryEligible(it));

    it.job = 41;
    try t.expect(transferRetryEligible(it));

    it.job = 0;
    it.submission_uncertain = true;
    try t.expect(transferRetryEligible(it));

    it.submission_uncertain = false;
    it.mediated = true;
    try t.expect(transferRetryEligible(it));
}

test "cancellation retains an unresolved submitted attempt" {
    const t = std.testing;
    var service = Service{ .allocator = t.allocator };
    const it = try testIntent(&service, .{
        .token = "cancel-uncertain",
        .state = .waiting_retry,
        .submission_uncertain = true,
    });
    defer destroyTestIntent(it, t.allocator);
    try t.expect(cancelNeedsSubmissionRecovery(it));

    it.ack_job = 9;
    try t.expect(!cancelNeedsSubmissionRecovery(it));
    it.ack_job = 0;
    it.submission_uncertain = false;
    try t.expect(!cancelNeedsSubmissionRecovery(it));
    it.submission_uncertain = true;
    it.state = .failed;
    try t.expect(!cancelNeedsSubmissionRecovery(it));
    it.state = .queued;
    try t.expect(cancelNeedsSubmissionRecovery(it));
}

test "recovered retry waits and repeated transport loss spends one bounded attempt" {
    const t = std.testing;
    const old = if (c.getenv("XDG_STATE_HOME")) |value|
        try t.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(value))))
    else
        null;
    defer {
        if (old) |value| {
            var z: [4096:0]u8 = undefined;
            const restored = std.fmt.bufPrintZ(&z, "{s}", .{value}) catch unreachable;
            _ = c.setenv("XDG_STATE_HOME", restored.ptr, 1);
            t.allocator.free(value);
        } else {
            _ = c.unsetenv("XDG_STATE_HOME");
        }
    }
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var state_buf: [4096:0]u8 = undefined;
    const state = try std.fmt.bufPrintZ(&state_buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    _ = c.setenv("XDG_STATE_HOME", state.ptr, 1);

    var service = Service{ .allocator = t.allocator };
    const handle = (try store.open(t.allocator, .intent, "retry-test")).?;
    const before = nowMs();
    const it = try service.dupIntent(handle, .{
        .token = "retry-test",
        .state = .waiting_retry,
        .attempts = 2,
        .mediated = true,
    });
    try service.intents.append(t.allocator, it);
    defer {
        if (service.transfer_retry_source != 0) _ = c.g_source_remove(service.transfer_retry_source);
        service.intents.deinit(t.allocator);
        _ = it.handle.destroyRecord();
        it.destroy(t.allocator);
    }
    try t.expectEqual(store.State.waiting_retry, it.state);
    try t.expectEqual(@as(u8, 2), it.attempts);
    try t.expect(it.retry_due_ms >= before + RETRY_DELAY_MS);

    it.state = .running;
    it.retry_due_ms = 0;
    it.claimed = true;
    try t.expect(service.recordMediatedTransportLoss(it.token, "connection lost", true));
    try t.expectEqual(@as(u8, 3), it.attempts);
    try t.expectEqual(store.State.waiting_retry, it.state);
    try t.expect(!it.claimed);
    it.claimed = true;
    try t.expect(service.recordMediatedTransportLoss(it.token, "connection lost again", true));
    try t.expectEqual(@as(u8, 3), it.attempts);
    try t.expect(!it.claimed);

    it.state = .running;
    it.retry_due_ms = 0;
    it.submission_uncertain = false;
    try t.expect(!service.recordMediatedFailure(it.token, "structured transport failure", true));
    try t.expectEqual(@as(u8, 4), it.attempts);
    try t.expectEqual(store.State.failed, it.state);
    try t.expectEqual(@as(i64, 0), it.retry_due_ms);

    it.state = .running;
    it.retry_due_ms = 0;
    it.claimed = true;
    it.cancel_requested = true;
    try t.expect(service.recordMediatedTransportLoss(it.token, "connection lost while canceling", true));
    try t.expectEqual(@as(u8, 4), it.attempts);
    try t.expectEqual(store.State.waiting_retry, it.state);
    try t.expect(!it.claimed);
}

test "direct transport loss waits and exhausts the same retry budget" {
    const t = std.testing;
    var service = Service{ .allocator = t.allocator };
    var handle = store.Handle{
        .allocator = t.allocator,
        .rtype = .intent,
        .token = try t.allocator.dupe(u8, ""),
        .json_path = try t.allocator.dupe(u8, ""),
        .lock_path = try t.allocator.dupe(u8, ""),
        .lock_fd = -1,
    };
    const it = service.dupIntent(handle, .{
        .token = "direct-retry",
        .state = .running,
        .dst = .{ .path = "/destination" },
    }) catch |err| {
        handle.release();
        return err;
    };
    defer {
        it.handle.release();
        it.destroy(t.allocator);
    }

    var failure: u8 = 1;
    while (failure <= AUTO_RETRIES) : (failure += 1) {
        const before = nowMs();
        service.recordDirectTransportLoss(it);
        try t.expectEqual(failure, it.attempts);
        try t.expectEqual(store.State.waiting_retry, it.state);
        try t.expect(it.retry_due_ms >= before + RETRY_DELAY_MS);
        it.state = .running;
    }
    service.recordDirectTransportLoss(it);
    try t.expectEqual(AUTO_RETRIES + 1, it.attempts);
    try t.expectEqual(store.State.failed, it.state);
    try t.expectEqual(@as(i64, 0), it.retry_due_ms);

    it.state = .running;
    it.job = 91;
    it.cancel_requested = true;
    service.recordDirectTransportLoss(it);
    try t.expectEqual(AUTO_RETRIES + 1, it.attempts);
    try t.expectEqual(store.State.waiting_retry, it.state);
    try t.expect(it.retry_due_ms > 0);
}

test "unresolved cancellation retains both recovery ledgers" {
    const t = std.testing;
    const old = if (c.getenv("XDG_STATE_HOME")) |value|
        try t.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(value))))
    else
        null;
    defer {
        if (old) |value| {
            var z: [4096:0]u8 = undefined;
            const restored = std.fmt.bufPrintZ(&z, "{s}", .{value}) catch unreachable;
            _ = c.setenv("XDG_STATE_HOME", restored.ptr, 1);
            t.allocator.free(value);
        } else {
            _ = c.unsetenv("XDG_STATE_HOME");
        }
    }
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var state_buf: [4096:0]u8 = undefined;
    const state = try std.fmt.bufPrintZ(&state_buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    _ = c.setenv("XDG_STATE_HOME", state.ptr, 1);

    var service = Service{ .allocator = t.allocator, .shutting_down = true };
    const handle = (try store.open(t.allocator, .intent, "cancel-unresolved")).?;
    const it = try service.dupIntent(handle, .{
        .token = "cancel-unresolved",
        .state = .running,
        .job = 91,
        .cancel_requested = true,
        .dst = .{ .path = "/destination" },
    });
    try service.intents.append(t.allocator, it);
    defer {
        service.intents.deinit(t.allocator);
        _ = it.handle.destroyRecord();
        it.destroy(t.allocator);
    }

    service.complete(it, false, false, "source identity could not be proven", false);
    try t.expectEqual(store.State.waiting_retry, it.state);
    try t.expect(it.retry_due_ms > 0);
    try t.expect(!it.retired);
    try t.expectEqual(@as(u64, 0), it.ack_job);
    try t.expectEqual(@as(u64, 91), it.job);
    try t.expect(!service.dismissMediated(it.token));
    const record = (try store.readToken(t.allocator, .intent, it.token)) orelse return error.MissingRecord;
    defer record.deinit();
    try t.expect(record.value.intent.cancel_requested);
    try t.expect(!record.value.intent.retired);
    try t.expectEqual(store.State.waiting_retry, record.value.intent.state);
    try t.expectEqual(@as(u64, 91), record.value.intent.job);
}

test "repeated cancellation keeps an unresolved mediated recovery" {
    const t = std.testing;
    var service = Service{ .allocator = t.allocator, .shutting_down = true };
    defer service.intents.deinit(t.allocator);
    const it = try testIntent(&service, .{
        .token = "cancel-repeat",
        .mediated = true,
        .state = .waiting_retry,
        .job = 91,
        .cancel_requested = true,
    });
    defer destroyTestIntent(it, t.allocator);
    try service.intents.append(t.allocator, it);
    defer {
        if (service.transfer_retry_source != 0) _ = c.g_source_remove(service.transfer_retry_source);
    }

    _ = service.cancel("cancel-repeat");
    try t.expectEqual(store.State.waiting_retry, it.state);
    try t.expect(!it.retired);
    try t.expectEqual(@as(u64, 91), it.job);
    try t.expect(it.retry_due_ms > 0);
}

test "canceling a scheduled daemon retry durably rotates cleanup identity" {
    const t = std.testing;
    const old_state = if (c.getenv("XDG_STATE_HOME")) |value|
        try t.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(value))))
    else
        null;
    defer {
        if (old_state) |value| {
            var z: [4096:0]u8 = undefined;
            const restored = std.fmt.bufPrintZ(&z, "{s}", .{value}) catch unreachable;
            _ = c.setenv("XDG_STATE_HOME", restored.ptr, 1);
            t.allocator.free(value);
        } else {
            _ = c.unsetenv("XDG_STATE_HOME");
        }
    }
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var state_buf: [4096:0]u8 = undefined;
    const state = try std.fmt.bufPrintZ(&state_buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    _ = c.setenv("XDG_STATE_HOME", state.ptr, 1);

    var service = Service{ .allocator = t.allocator, .shutting_down = true };
    const handle = (try store.open(t.allocator, .intent, "cancel-scheduled")).?;
    const it = try service.dupIntent(handle, .{
        .token = "cancel-scheduled",
        .client_token = "old-attempt",
        .state = .waiting_retry,
        .job = 91,
        .ack_job = 91,
        .ack_host = "relay",
        .mediated = true,
        .user_copy = true,
        .coordinator_set = true,
    });
    it.record_version = 5;
    try service.intents.append(t.allocator, it);
    it.claimed = true;
    defer {
        service.intents.deinit(t.allocator);
        _ = it.handle.destroyRecord();
        it.destroy(t.allocator);
    }

    try t.expect(service.cancel(it.token));
    try t.expect(it.cancel_requested);
    try t.expectEqual(store.State.waiting_retry, it.state);
    try t.expectEqual(@as(u64, 0), it.ack_job);
    try t.expect(!it.claimed);
    try t.expectEqual(store.VERSION, it.record_version);
    try t.expect(!std.mem.eql(u8, it.client_token, "old-attempt"));
    const record = (try store.readToken(t.allocator, .intent, it.token)) orelse return error.MissingRecord;
    defer record.deinit();
    try t.expect(record.value.intent.cancel_requested);
    try t.expectEqual(store.State.waiting_retry, record.value.intent.state);
    try t.expectEqual(@as(u64, 0), record.value.intent.ack_job);
    try t.expectEqual(store.VERSION, record.value.version);
}

test "failed scheduled-cancel persistence restores every retry field" {
    const t = std.testing;
    var service = Service{ .allocator = t.allocator, .shutting_down = true };
    var handle = store.Handle{
        .allocator = t.allocator,
        .rtype = .intent,
        .token = try t.allocator.dupe(u8, "cancel-rollback"),
        .json_path = try t.allocator.dupe(u8, "/proc/self/sketerm-cancel-rollback.json"),
        .lock_path = try t.allocator.dupe(u8, "/proc/self/sketerm-cancel-rollback.lock"),
        .lock_fd = -1,
    };
    const it = service.dupIntent(handle, .{
        .token = "cancel-rollback",
        .client_token = "old-attempt",
        .state = .waiting_retry,
        .job = 91,
        .ack_job = 91,
        .ack_host = "relay",
        .message = "retry pending",
        .mediated = true,
        .user_copy = true,
        .coordinator_set = true,
    }) catch |err| {
        handle.release();
        return err;
    };
    try service.intents.append(t.allocator, it);
    it.claimed = true;
    defer {
        service.intents.deinit(t.allocator);
        it.handle.release();
        it.destroy(t.allocator);
    }

    try t.expect(!service.cancel(it.token));
    try t.expect(!it.cancel_requested);
    try t.expectEqual(store.State.waiting_retry, it.state);
    try t.expectEqual(@as(u64, 91), it.ack_job);
    try t.expect(it.claimed);
    try t.expectEqualStrings("old-attempt", it.client_token);
    try t.expectEqualStrings("retry pending", it.message);
    // A second click must retry the durable write rather than take the
    // already-canceled fast path after the first failed mutation.
    try t.expect(!service.cancel(it.token));
    try t.expect(!it.cancel_requested);
    try t.expectEqual(@as(u64, 91), it.ack_job);
}

pub fn acquire(allocator: std.mem.Allocator, notify_ctx: ?*anyopaque, notify_fn: ?NotifyFn) !*Service {
    if (shared) |service| {
        if (notify_ctx != null and notify_fn != null) {
            var exists = false;
            for (service.subscribers.items) |subscriber| if (subscriber.ctx == notify_ctx.?) {
                exists = true;
                break;
            };
            if (!exists) try service.subscribers.append(allocator, .{ .ctx = notify_ctx.?, .callback = notify_fn.? });
        }
        service.refs = service.subscribers.items.len;
        return service;
    }
    const service = try Service.init(allocator, notify_ctx, notify_fn);
    shared = service;
    return service;
}

pub fn release(service: *Service, notify_ctx: *anyopaque) void {
    for (service.subscribers.items, 0..) |subscriber, i| {
        if (subscriber.ctx == notify_ctx) {
            _ = service.subscribers.orderedRemove(i);
            break;
        }
    }
    service.refs = service.subscribers.items.len;
    if (service.refs > 0) return;
    shared = null;
    service.deinit();
}

fn launchDefault(path: []const u8) void {
    const uri = filenameUri(path) orelse return;
    defer c.g_free(uri);
    _ = c.g_app_info_launch_default_for_uri(uri, null, null);
}

fn launchWithApp(app_id: []const u8, path: []const u8) void {
    const uri = filenameUri(path) orelse return;
    defer c.g_free(uri);
    const apps = c.g_app_info_get_all();
    defer if (apps != null) c.g_list_free_full(apps, @ptrCast(&c.g_object_unref));
    var it = apps;
    while (it != null) : (it = it.*.next) {
        const app: *c.GAppInfo = @ptrCast(@alignCast(it.*.data orelse continue));
        const id = c.g_app_info_get_id(app) orelse continue;
        if (!std.mem.eql(u8, std.mem.span(id), app_id)) continue;
        var list: ?*c.GList = null;
        list = c.g_list_append(list, @ptrCast(uri));
        _ = c.g_app_info_launch_uris(app, list, null, null);
        c.g_list_free(list);
        return;
    }
    launchDefault(path);
}

fn filenameUri(path: []const u8) ?[*c]c.gchar {
    var path_buf: [4096:0]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return null;
    const uri = c.g_filename_to_uri(path_z.ptr, null, null);
    return if (uri == null) null else uri;
}
