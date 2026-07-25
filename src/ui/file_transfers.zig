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
//! Two record kinds live here:
//!   * daemon-coordinated downloads/uploads, submitted as `cross_copy`
//!     jobs and driven by this service directly;
//!   * client-mediated transfers (fstransfer), which need a browser
//!     face with both host connections to run. Those are adopted only
//!     while a DRIVER is registered, and handed to it.

const std = @import("std");
const c = @import("../c.zig").c;
const muxclient = @import("../mux/client.zig");
const wire = @import("../mux/wire.zig");
const store = @import("../filebrowser/transfers.zig");
const xferqueue = @import("../filebrowser/xferqueue.zig");
const pathz = @import("../util/pathz.zig");

pub const NotifyFn = *const fn (ctx: *anyopaque, text: []const u8) void;
const Subscriber = struct { ctx: *anyopaque, callback: NotifyFn };

/// How often orphaned records (an owner that crashed) are looked for.
const SWEEP_MS: c.guint = 15_000;

const Intent = struct {
    handle: store.Handle,
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
    /// Finished; the record exists only until its ack lands.
    retired: bool = false,
    /// Client-mediated: run by a registered driver, not by this
    /// service. `claimed` means the driver currently holds it.
    mediated: bool = false,
    claimed: bool = false,
    open_when_done: bool = false,
    delete_src_after: bool = false,
    watch_after: bool = false,
    /// Scheduler identity of the destination (host plus local device).
    dest_key: u64 = 0,
    /// Live progress from the daemon's job events; volatile, the
    /// daemon replays it after every reconnect.
    done: u64 = 0,
    total: u64 = 0,
    resumed_from: u64 = 0,

    fn record(self: *const Intent) store.Record {
        return .{
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
                .open_when_done = self.open_when_done,
                .delete_src_after = self.delete_src_after,
                .watch_after = self.watch_after,
            },
        };
    }

    fn destroy(self: *Intent, a: std.mem.Allocator) void {
        inline for (.{ self.token, self.client_token, self.src_host, self.src_path, self.dst_host, self.dst_path, self.app_id, self.watch_token, self.message }) |s|
            a.free(s);
        a.destroy(self);
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
};

/// One client-mediated transfer as handed to a driver.
pub const MediatedRec = struct {
    token: []const u8,
    src_host: []const u8,
    src_path: []const u8,
    dst_host: []const u8,
    dst_path: []const u8,
    app_id: []const u8,
    paused: bool,
    open_when_done: bool,
    delete_src_after: bool,
    watch_after: bool,
};

pub const MediatedFn = *const fn (ctx: *anyopaque, rec: MediatedRec) void;
/// Repaint the jobs/transfers panel: rows can appear without any user
/// action here (an adopted orphan, a sync-back queued by a watch), and
/// the panel's own sampling tick only runs while rows already exist.
pub const RefreshFn = *const fn (ctx: *anyopaque) void;
const Driver = struct { ctx: *anyopaque, callback: MediatedFn, refresh: RefreshFn };

pub const Service = struct {
    allocator: std.mem.Allocator,
    conn: ?muxclient.Conn = null,
    fd_watch: c.guint = 0,
    retry_source: c.guint = 0,
    sweep_source: c.guint = 0,
    next_req: u32 = 1,
    order_seq: u64 = 0,
    intents: std.ArrayList(*Intent) = .empty,
    watches: std.ArrayList(*Watch) = .empty,
    pending: std.ArrayList(Pending) = .empty,
    subscribers: std.ArrayList(Subscriber) = .empty,
    drivers: std.ArrayList(Driver) = .empty,
    shutting_down: bool = false,
    refs: usize = 1,
    retry_delay_ms: c.guint = 1000,
    durability_error: bool = false,
    disconnect_after_drain: bool = false,
    in_fd_callback: bool = false,

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
        if (self.fd_watch != 0) _ = c.g_source_remove(self.fd_watch);
        if (self.conn) |*conn| conn.deinit();
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

    /// Take over every record no live process owns. Called at startup
    /// and on a timer: a peer GUI can die at any moment, and its
    /// transfers must not wait for a restart of THIS one.
    fn adoptOrphans(self: *Service) void {
        const entries = store.list(self.allocator) catch return;
        defer store.freeList(self.allocator, entries);
        var handed: std.ArrayList(*Intent) = .empty;
        defer handed.deinit(self.allocator);
        for (entries) |e| {
            switch (e.rtype) {
                .intent => if (self.ownsIntent(e.token)) continue,
                .watch => if (self.ownsWatch(e.token)) continue,
            }
            var handle = (store.open(self.allocator, e.rtype, e.token) catch continue) orelse continue;
            const parsed = store.readFile(self.allocator, handle.json_path) catch null;
            const rec = parsed orelse {
                // A lock with no record: debris of an owner that died
                // between creating the lock and writing the record.
                handle.destroyRecord();
                continue;
            };
            defer rec.deinit();
            if (rec.value.version != store.VERSION) {
                handle.release();
                continue;
            }
            switch (e.rtype) {
                .intent => {
                    const value = rec.value.intent;
                    if (value.state == .canceled) {
                        handle.destroyRecord();
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
                    self.intents.append(self.allocator, it) catch {
                        it.handle.release();
                        it.destroy(self.allocator);
                        continue;
                    };
                    if (it.mediated) handed.append(self.allocator, it) catch {};
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
            }
        }
        // Dispatch AFTER the scan: a driver may call back into the
        // service, and the lists must be settled first.
        for (handed.items) |it| self.handToDriver(it);
        self.queueDirtyWatches();
        self.refreshViews();
    }

    fn onSweep(user: ?*anyopaque) callconv(.c) c.gboolean {
        const self: *Service = @ptrCast(@alignCast(user.?));
        if (self.shutting_down) return 0;
        self.adoptOrphans();
        self.pump();
        return 1;
    }

    /// Import a pre-upgrade single-document ledger, once.
    fn migrateLegacy(self: *Service) void {
        const lock = (store.lockLegacy(self.allocator) catch return) orelse {
            // A pre-upgrade binary still owns that document and is
            // still running those transfers; importing them here would
            // run every one of them twice.
            return;
        };
        defer lock.release();
        const parsed = (store.loadLegacy(self.allocator) catch {
            self.notify("the old transfer ledger is unreadable; it was left in place", .{});
            return;
        }) orelse return;
        defer parsed.deinit();
        var imported: usize = 0;
        for (parsed.value.intents) |value| {
            if (value.state == .canceled) continue;
            if (value.token.len == 0) continue;
            if (self.importIntent(value, parsed.value.acknowledgments)) imported += 1;
        }
        for (parsed.value.watches) |value| {
            if (value.token.len == 0) continue;
            if (self.importWatch(value)) imported += 1;
        }
        // Acknowledgments with no surviving intent still have to reach
        // the daemon: carry each in a retired record of its own.
        for (parsed.value.acknowledgments) |job| {
            var covered = false;
            for (self.intents.items) |it| if (it.ack_job == job) {
                covered = true;
                break;
            };
            if (!covered and self.importAck(job)) imported += 1;
        }
        store.retireLegacy(self.allocator);
        if (imported > 0) self.notify("imported {d} transfer record(s) from the old ledger", .{imported});
    }

    fn importIntent(self: *Service, value: store.Intent, acks: []const u64) bool {
        var handle = (store.open(self.allocator, .intent, value.token) catch return false) orelse return false;
        const it = self.dupIntent(handle, value) catch {
            handle.release();
            return false;
        };
        for (acks) |job| {
            if (job != 0 and job == value.job) it.ack_job = job;
        }
        self.intents.append(self.allocator, it) catch {
            it.handle.release();
            it.destroy(self.allocator);
            return false;
        };
        self.writeIntent(it);
        return true;
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
        self.armWatch(w);
        self.detectOfflineEdit(w);
        return true;
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
        self.intents.append(self.allocator, it) catch {
            it.handle.release();
            it.destroy(self.allocator);
            return false;
        };
        self.writeIntent(it);
        return true;
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
            .state = if (value.state == .done or value.state == .canceled or value.state == .failed) value.state else .queued,
            .job = value.job,
            .order = if (value.order == 0) self.nextOrder() else value.order,
            .watch_token = watch_token,
            .submitted_generation = value.submitted_generation,
            .message = message,
            .attempts = value.attempts,
            .cancel_requested = value.cancel_requested,
            .submitted_size = value.submitted_size,
            .submitted_mtime_ns = value.submitted_mtime_ns,
            .paused = value.paused,
            .ack_job = value.ack_job,
            .retired = value.retired,
            .mediated = value.mediated,
            .open_when_done = value.open_when_done,
            .delete_src_after = value.delete_src_after,
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

    // ── persistence ─────────────────────────────────────────────

    fn writeIntent(self: *Service, it: *Intent) void {
        it.handle.write(it.record()) catch {
            self.durability_error = true;
            self.notify("cannot persist transfer recovery state", .{});
            return;
        };
        // A record that landed proves the ledger is writable again;
        // leaving the flag set would refuse every later transfer over
        // one transient failure.
        self.durability_error = false;
    }

    fn writeWatch(self: *Service, w: *Watch) void {
        w.handle.write(w.record()) catch {
            self.durability_error = true;
            self.notify("cannot persist transfer recovery state", .{});
            return;
        };
        self.durability_error = false;
    }

    /// Write every owned record whose content changed.
    fn persist(self: *Service) void {
        for (self.intents.items) |it| self.writeIntent(it);
        for (self.watches.items) |w| self.writeWatch(w);
    }

    fn nextOrder(self: *Service) u64 {
        // Wall-clock based so records minted by DIFFERENT processes
        // still order against each other; the counter breaks ties
        // inside one millisecond.
        var ts: c.struct_timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_REALTIME, &ts);
        const ms: u64 = @as(u64, @intCast(ts.tv_sec)) * 1000 + @as(u64, @intCast(@divTrunc(ts.tv_nsec, 1_000_000)));
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

    fn onRetry(user: ?*anyopaque) callconv(.c) c.gboolean {
        const self: *Service = @ptrCast(@alignCast(user.?));
        self.retry_source = 0;
        self.connect();
        for (self.intents.items) |it| {
            if (it.state == .waiting_retry and !it.cancel_requested) it.state = .queued;
        }
        self.pump();
        return 0;
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
            if (it.state == .submitting or it.state == .running) it.state = .queued;
        }
        self.persist();
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
        const self: *Service = @ptrCast(@alignCast(user.?));
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
        const Reply = struct { req: u32 = 0, ok: bool = false, job: u64 = 0, state: []const u8 = "", done: u64 = 0, total: u64 = 0, @"error": []const u8 = "", message: []const u8 = "" };
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
            if (!rep.ok or rep.job == 0) {
                if (p.intent.cancel_requested) {
                    p.intent.state = .canceled;
                    self.removeIntent(p.intent);
                    self.pump();
                    return;
                }
                p.intent.state = .waiting_retry;
                self.replaceMessage(p.intent, rep.@"error");
                self.scheduleRetry();
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
                    self.complete(p.intent, true, rep.message)
                else if (p.intent.state == .failed or p.intent.state == .canceled)
                    self.complete(p.intent, false, rep.message);
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
        };
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const ev = std.json.parseFromSliceLeaky(Event, arena.allocator(), payload, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return;
        for (self.intents.items) |it| {
            if (it.job != ev.job or it.retired) continue;
            if (std.mem.eql(u8, ev.ev, "done")) {
                self.complete(it, true, "");
            } else if (std.mem.eql(u8, ev.ev, "error") or std.mem.eql(u8, ev.ev, "canceled")) {
                self.complete(it, false, ev.message);
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

    fn complete(self: *Service, it: *Intent, ok: bool, message: []const u8) void {
        const terminal_job = it.job;
        if (!ok) {
            if (it.cancel_requested) {
                it.ack_job = terminal_job;
                it.state = .canceled;
                self.notify("transfer canceled: {s}", .{std.fs.path.basename(it.dst_path)});
                self.retire(it);
                self.pump();
                return;
            }
            it.attempts +|= 1;
            if (it.attempts >= 8) {
                it.ack_job = terminal_job;
                it.state = .failed;
                self.replaceMessage(it, message);
                self.notify("transfer failed: {s}", .{std.fs.path.basename(it.dst_path)});
                self.writeIntent(it);
                self.pumpAcksNow();
                self.pump();
                return;
            }
            // A terminal daemon job cannot be restarted under the same
            // idempotency token. A fresh attempt keeps the .skpart
            // checkpoint but receives a new job identity.
            const token = self.newToken() catch null;
            if (token) |fresh| {
                self.allocator.free(it.client_token);
                it.client_token = fresh;
                it.job = 0;
            }
            it.state = .waiting_retry;
            it.ack_job = terminal_job;
            self.replaceMessage(it, message);
            self.notify("transfer deferred: {s}", .{std.fs.path.basename(it.dst_path)});
            self.writeIntent(it);
            self.scheduleRetry();
            self.pump();
            return;
        }
        it.state = .done;
        it.ack_job = terminal_job;
        if (it.kind == .download) {
            const w = self.ensureWatch(it.watch_token, it.src_host, it.src_path, it.dst_path);
            const watch = w orelse {
                it.state = .failed;
                it.ack_job = terminal_job;
                self.replaceMessage(it, "cannot create durable edit watch");
                self.writeIntent(it);
                self.notify("download held because edit recovery could not be created: {s}", .{std.fs.path.basename(it.dst_path)});
                return;
            };
            self.captureFingerprint(watch);
            watch.synced_generation = watch.dirty_generation;
            self.armWatch(watch);
            self.writeWatch(watch); // arm recovery before launching an external app
            if (self.durability_error) return;
            if (it.app_id.len > 0) launchWithApp(it.app_id, it.dst_path) else launchDefault(it.dst_path);
            self.notify("download complete: {s}", .{std.fs.path.basename(it.dst_path)});
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
                self.notify("synced back: {s}", .{std.fs.path.basename(w.remote_path)});
            }
        }
        self.retire(it);
        self.queueDirtyWatches();
        self.pump();
        self.refreshViews();
    }

    /// A finished intent leaves the queue but its record survives
    /// until the daemon has acknowledged the job, so a crash in
    /// between cannot strand the job on the daemon.
    fn retire(self: *Service, it: *Intent) void {
        if (it.ack_job == 0) {
            self.removeIntent(it);
            return;
        }
        it.retired = true;
        self.writeIntent(it);
        self.pumpAcksNow();
    }

    fn removeIntent(self: *Service, needle: *Intent) void {
        for (self.intents.items, 0..) |it, i| {
            if (it != needle) continue;
            _ = self.intents.orderedRemove(i);
            it.handle.destroyRecord();
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

    pub fn submitDownload(self: *Service, host: []const u8, remote_path: []const u8, cache_path: []const u8, app_id: ?[]const u8) void {
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
        self.appendIntent(.download, host, remote_path, "", cache_path, app_id orelse "", watch_token, 0);
    }

    fn appendIntent(self: *Service, kind: store.Kind, src_host: []const u8, src_path: []const u8, dst_host: []const u8, dst_path: []const u8, app_id: []const u8, watch_token: []const u8, generation: u64) void {
        if (self.durability_error) {
            self.notify("transfer not started because recovery state is unavailable", .{});
            return;
        }
        const it = self.createIntent(kind, src_host, src_path, dst_host, dst_path, app_id, watch_token, generation) catch return;
        self.intents.append(self.allocator, it) catch {
            it.handle.destroyRecord();
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
            if (it.retired or it.mediated or it.paused) continue;
            const state: ?xferqueue.State = switch (it.state) {
                .submitting, .running => .running,
                .queued => if (it.cancel_requested) null else .queued,
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
        it.state = .submitting;
        self.pending.append(self.allocator, .{ .req = req, .intent = it }) catch {
            it.state = .queued;
            return true;
        };
        conn.sendJson(.fs_op, .{
            .req = req,
            .op = "cross_copy",
            .path = it.src_path,
            .to = it.dst_path,
            .src_host = it.src_host,
            .dst_host = it.dst_host,
            .@"resume" = true,
            .client_token = it.client_token,
        }) catch {
            _ = self.pending.pop();
            it.state = .queued;
            self.requestDisconnect();
            return false;
        };
        return true;
    }

    /// Hold or release one queued/running transfer. A queued one is
    /// simply never submitted; a running one is SIGSTOPped daemon-side.
    pub fn setPaused(self: *Service, token: []const u8, paused: bool) void {
        for (self.intents.items) |it| {
            if (!std.mem.eql(u8, it.token, token)) continue;
            if (it.paused == paused) return;
            it.paused = paused;
            const live = it.job != 0 and (it.state == .running or it.state == .submitting);
            if (live) {
                if (!self.sendJobControl(it.job, if (paused) "job_pause" else "job_resume"))
                    self.requestDisconnect();
            } else if (!paused and it.job != 0) {
                // The daemon job outlived the client that paused it;
                // resume as soon as the resubmission returns its id.
                it.resume_pending = true;
            }
            self.writeIntent(it);
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

    pub fn cancel(self: *Service, token: []const u8) void {
        for (self.intents.items) |it| {
            if (!std.mem.eql(u8, it.token, token)) continue;
            if (it.state == .queued or it.state == .waiting_retry or it.state == .failed) {
                it.state = .canceled;
                self.retire(it);
                self.pump();
                return;
            }
            it.cancel_requested = true;
            if (it.job != 0 and !self.sendJobControl(it.job, "job_cancel")) self.requestDisconnect();
            self.writeIntent(it);
            return;
        }
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
            if (it.ack_job == 0 or it.ack_req != 0) continue;
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

    pub fn rows(self: *Service, allocator: std.mem.Allocator) ![]QueueRow {
        var out: std.ArrayList(QueueRow) = .empty;
        for (self.intents.items) |it| {
            // Retired records are bookkeeping, and mediated ones are
            // rendered by the view that runs them.
            if (it.retired or it.mediated) continue;
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
            .token = it.token,
            .src_host = it.src_host,
            .src_path = it.src_path,
            .dst_host = it.dst_host,
            .dst_path = it.dst_path,
            .app_id = it.app_id,
            .paused = it.paused,
            .open_when_done = it.open_when_done,
            .delete_src_after = it.delete_src_after,
            .watch_after = it.watch_after,
        };
    }

    /// Tell every registered view that the row set may have changed.
    fn refreshViews(self: *Service) void {
        for (self.drivers.items) |d| d.refresh(d.ctx);
    }

    fn handToDriver(self: *Service, it: *Intent) void {
        if (it.claimed) return;
        const driver = if (self.drivers.items.len > 0) self.drivers.items[0] else return;
        it.claimed = true;
        driver.callback(driver.ctx, mediatedRec(it));
    }

    /// Register a runner for client-mediated records. The FIRST driver
    /// registered runs them; the rest only matter when it goes away.
    pub fn addMediatedDriver(self: *Service, ctx: *anyopaque, callback: MediatedFn, refresh: RefreshFn) void {
        for (self.drivers.items) |d| if (d.ctx == ctx) return;
        self.drivers.append(self.allocator, .{ .ctx = ctx, .callback = callback, .refresh = refresh }) catch return;
        if (self.drivers.items.len != 1) return;
        self.adoptOrphans();
        for (self.intents.items) |it| {
            if (it.mediated) self.handToDriver(it);
        }
    }

    pub fn removeMediatedDriver(self: *Service, ctx: *anyopaque) void {
        var was_head = false;
        for (self.drivers.items, 0..) |d, i| {
            if (d.ctx != ctx) continue;
            was_head = i == 0;
            _ = self.drivers.orderedRemove(i);
            break;
        }
        if (!was_head) return;
        if (self.drivers.items.len > 0) {
            for (self.intents.items) |it| {
                if (it.mediated) self.handToDriver(it);
            }
            return;
        }
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
    }

    /// The driver no longer runs `token` (its view is going away), but
    /// the record stays: another driver or process resumes it.
    pub fn unclaimMediated(self: *Service, token: []const u8) void {
        const it = self.intentByToken(token) orelse return;
        it.claimed = false;
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
            .watch_after = opts.watch_after,
        }) catch {
            handle.release();
            return null;
        };
        it.claimed = true;
        self.intents.append(self.allocator, it) catch {
            it.handle.destroyRecord();
            it.destroy(self.allocator);
            return null;
        };
        self.writeIntent(it);
        return it.token;
    }

    pub fn setMediatedPaused(self: *Service, token: []const u8, paused: bool) void {
        const it = self.intentByToken(token) orelse return;
        if (it.paused == paused) return;
        it.paused = paused;
        self.writeIntent(it);
    }

    /// The mediated transfer reached a terminal state; drop its record.
    pub fn finishMediated(self: *Service, token: []const u8) void {
        const it = self.intentByToken(token) orelse return;
        self.removeIntent(it);
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
            w.handle.destroyRecord();
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
        const w: *Watch = @ptrCast(@alignCast(user.?));
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
            if (!active) self.appendIntent(.upload, "", w.cache_path, w.host, w.remote_path, "", w.token, w.dirty_generation);
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
