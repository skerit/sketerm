//! Window-owned durable downloads and remote edit synchronization.

const std = @import("std");
const c = @import("../c.zig").c;
const muxclient = @import("../mux/client.zig");
const wire = @import("../mux/wire.zig");
const store = @import("../filebrowser/transfers.zig");
const xferqueue = @import("../filebrowser/xferqueue.zig");
const pathz = @import("../util/pathz.zig");

pub const NotifyFn = *const fn (ctx: *anyopaque, text: []const u8) void;
const Subscriber = struct { ctx: *anyopaque, callback: NotifyFn };

const Intent = struct {
    token: []u8,
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
    /// Scheduler identity of the destination (host plus local device).
    dest_key: u64 = 0,
    /// Live progress from the daemon's job events; volatile, the
    /// daemon replays it after every reconnect.
    done: u64 = 0,
    total: u64 = 0,
    resumed_from: u64 = 0,

    fn destroy(self: *Intent, a: std.mem.Allocator) void {
        inline for (.{ self.token, self.src_host, self.src_path, self.dst_host, self.dst_path, self.app_id, self.watch_token, self.message }) |s|
            a.free(s);
        a.destroy(self);
    }
};

const Watch = struct {
    service: *Service,
    token: []u8,
    host: []u8,
    remote_path: []u8,
    cache_path: []u8,
    dirty_generation: u64,
    synced_generation: u64,
    synced_size: u64,
    synced_mtime_ns: i64,
    monitor: ?*c.GFileMonitor = null,

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
const PendingAck = struct { req: u32, job: u64 };

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

pub const Service = struct {
    allocator: std.mem.Allocator,
    lock_fd: c_int = -1,
    conn: ?muxclient.Conn = null,
    fd_watch: c.guint = 0,
    retry_source: c.guint = 0,
    next_req: u32 = 1,
    next_order: u64 = 1,
    intents: std.ArrayList(*Intent) = .empty,
    watches: std.ArrayList(*Watch) = .empty,
    pending: std.ArrayList(Pending) = .empty,
    acknowledgments: std.ArrayList(u64) = .empty,
    pending_acks: std.ArrayList(PendingAck) = .empty,
    subscribers: std.ArrayList(Subscriber) = .empty,
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
        try self.lockLedger();
        self.load();
        if (self.durability_error) return self;
        self.connect();
        for (self.watches.items) |w| {
            self.armWatch(w);
            self.detectOfflineEdit(w);
        }
        var i: usize = 0;
        while (i < self.intents.items.len and !self.durability_error) {
            const it = self.intents.items[i];
            if (it.state == .done) {
                self.complete(it, true, it.message);
            } else i += 1;
        }
        self.queueDirtyWatches();
        self.pump();
        return self;
    }

    pub fn deinit(self: *Service) void {
        self.shutting_down = true;
        if (self.lock_fd >= 0) self.persist();
        if (self.retry_source != 0) _ = c.g_source_remove(self.retry_source);
        if (self.fd_watch != 0) _ = c.g_source_remove(self.fd_watch);
        if (self.conn) |*conn| conn.deinit();
        if (self.lock_fd >= 0) _ = c.close(self.lock_fd);
        for (self.intents.items) |it| it.destroy(self.allocator);
        self.intents.deinit(self.allocator);
        for (self.watches.items) |w| w.destroy(self.allocator);
        self.watches.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.acknowledgments.deinit(self.allocator);
        self.pending_acks.deinit(self.allocator);
        self.subscribers.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn lockLedger(self: *Service) !void {
        const path = try store.filePath(self.allocator);
        defer self.allocator.free(path);
        try pathz.makeParentDirs(path);
        const lock_path = try std.fmt.allocPrint(self.allocator, "{s}.lock", .{path});
        defer self.allocator.free(lock_path);
        var z: [4096]u8 = undefined;
        const fd = c.open(try pathz.pathZ(&z, lock_path), c.O_RDWR | c.O_CREAT | c.O_CLOEXEC, @as(c.mode_t, 0o600));
        if (fd < 0) return error.TransferLedgerLockFailed;
        var lock = c.struct_flock{ .l_type = c.F_WRLCK, .l_whence = c.SEEK_SET, .l_start = 0, .l_len = 0, .l_pid = 0 };
        if (c.fcntl(fd, c.F_SETLK, &lock) != 0) {
            _ = c.close(fd);
            return error.TransferLedgerBusy;
        }
        self.lock_fd = fd;
    }

    fn notify(self: *Service, comptime fmt: []const u8, args: anytype) void {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch fmt;
        for (self.subscribers.items) |subscriber| subscriber.callback(subscriber.ctx, msg);
    }

    fn dupIntent(self: *Service, value: store.Intent) !*Intent {
        const a = self.allocator;
        const it = try a.create(Intent);
        errdefer a.destroy(it);
        const token = try a.dupe(u8, value.token);
        errdefer a.free(token);
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
            .token = token,
            .kind = value.kind,
            .src_host = src_host,
            .src_path = src_path,
            .dst_host = dst_host,
            .dst_path = dst_path,
            .app_id = app_id,
            .state = if (value.state == .done or value.state == .canceled or value.state == .failed) value.state else .queued,
            .job = value.job,
            .order = value.order,
            .watch_token = watch_token,
            .submitted_generation = value.submitted_generation,
            .message = message,
            .attempts = value.attempts,
            .cancel_requested = value.cancel_requested,
            .submitted_size = value.submitted_size,
            .submitted_mtime_ns = value.submitted_mtime_ns,
            .paused = value.paused,
            .dest_key = destinationKey(value.dst.host, value.dst.path),
        };
        return it;
    }

    fn dupWatch(self: *Service, value: store.Watch) !*Watch {
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

    fn load(self: *Service) void {
        const parsed = (store.load(self.allocator) catch {
            self.durability_error = true;
            self.notify("transfer recovery ledger is unreadable; refusing to overwrite it", .{});
            return;
        }) orelse return;
        defer parsed.deinit();
        if (parsed.value.version != 1) {
            self.durability_error = true;
            self.notify("transfer recovery ledger version is unsupported; refusing to overwrite it", .{});
            return;
        }
        self.next_order = parsed.value.next_order;
        for (parsed.value.intents) |value| {
            if (value.state == .canceled) continue;
            const it = self.dupIntent(value) catch {
                self.durability_error = true;
                self.notify("cannot reconstruct transfer recovery state", .{});
                return;
            };
            self.intents.append(self.allocator, it) catch {
                it.destroy(self.allocator);
                self.durability_error = true;
                self.notify("cannot reconstruct transfer recovery state", .{});
                return;
            };
        }
        for (parsed.value.watches) |value| {
            const w = self.dupWatch(value) catch {
                self.durability_error = true;
                self.notify("cannot reconstruct transfer recovery state", .{});
                return;
            };
            self.watches.append(self.allocator, w) catch {
                w.destroy(self.allocator);
                self.durability_error = true;
                self.notify("cannot reconstruct transfer recovery state", .{});
                return;
            };
        }
        self.acknowledgments.appendSlice(self.allocator, parsed.value.acknowledgments) catch {
            self.durability_error = true;
            self.notify("cannot reconstruct transfer recovery state", .{});
        };
    }

    fn persist(self: *Service) void {
        // Never replace an unreadable ledger or continue after a write
        // failure; preserving the recovery evidence is safer than
        // pretending subsequent work is durable.
        if (self.durability_error) return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const intents = a.alloc(store.Intent, self.intents.items.len) catch {
            self.durability_error = true;
            self.notify("cannot allocate transfer recovery snapshot", .{});
            return;
        };
        for (self.intents.items, 0..) |it, i| intents[i] = .{
            .token = it.token,
            .kind = it.kind,
            .src = .{ .host = it.src_host, .path = it.src_path },
            .dst = .{ .host = it.dst_host, .path = it.dst_path },
            .app_id = it.app_id,
            .state = it.state,
            .job = it.job,
            .order = it.order,
            .watch_token = it.watch_token,
            .submitted_generation = it.submitted_generation,
            .message = it.message,
            .attempts = it.attempts,
            .cancel_requested = it.cancel_requested,
            .submitted_size = it.submitted_size,
            .submitted_mtime_ns = it.submitted_mtime_ns,
            .paused = it.paused,
        };
        const watches = a.alloc(store.Watch, self.watches.items.len) catch {
            self.durability_error = true;
            self.notify("cannot allocate transfer recovery snapshot", .{});
            return;
        };
        for (self.watches.items, 0..) |w, i| watches[i] = .{
            .token = w.token,
            .host = w.host,
            .remote_path = w.remote_path,
            .cache_path = w.cache_path,
            .dirty_generation = w.dirty_generation,
            .synced_generation = w.synced_generation,
            .synced_size = w.synced_size,
            .synced_mtime_ns = w.synced_mtime_ns,
        };
        store.save(self.allocator, .{ .next_order = self.next_order, .intents = intents, .watches = watches, .acknowledgments = self.acknowledgments.items }) catch {
            self.durability_error = true;
            self.notify("cannot persist transfer recovery state", .{});
            return;
        };
        self.durability_error = false;
    }

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
        self.pending_acks.clearRetainingCapacity();
        for (self.intents.items) |it| {
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
        for (self.pending_acks.items, 0..) |pending, i| {
            if (pending.req != rep.req) continue;
            _ = self.pending_acks.orderedRemove(i);
            if (!rep.ok and !std.mem.eql(u8, rep.@"error", "no such job")) {
                self.scheduleRetry();
                return;
            }
            for (self.acknowledgments.items, 0..) |job, j| {
                if (job == pending.job) {
                    _ = self.acknowledgments.orderedRemove(j);
                    break;
                }
            }
            self.persist();
            return;
        }
        for (self.pending.items, 0..) |p, i| {
            if (p.req != rep.req) continue;
            _ = self.pending.orderedRemove(i);
            if (!rep.ok or rep.job == 0) {
                if (p.intent.cancel_requested) {
                    p.intent.state = .canceled;
                    self.removeIntent(p.intent);
                    self.persist();
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
            if (it.job != ev.job) continue;
            if (std.mem.eql(u8, ev.ev, "done")) {
                self.complete(it, true, "");
            } else if (std.mem.eql(u8, ev.ev, "error") or std.mem.eql(u8, ev.ev, "canceled")) {
                self.complete(it, false, ev.message);
            } else if (std.mem.eql(u8, ev.ev, "paused") or std.mem.eql(u8, ev.ev, "resumed")) {
                // The daemon is the authority on whether the helper is
                // stopped; a pause from another client shows up here.
                it.paused = std.mem.eql(u8, ev.ev, "paused");
                self.persist();
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
                if (terminal_job != 0 and !self.stageAck(terminal_job)) return;
                it.state = .canceled;
                self.notify("transfer canceled: {s}", .{std.fs.path.basename(it.dst_path)});
                self.removeIntent(it);
                self.persist();
                self.pump();
                return;
            }
            it.attempts +|= 1;
            if (it.attempts >= 8) {
                if (terminal_job != 0 and !self.stageAck(terminal_job)) return;
                it.state = .failed;
                self.replaceMessage(it, message);
                self.notify("transfer failed: {s}", .{std.fs.path.basename(it.dst_path)});
                self.persist();
                self.pump();
                return;
            }
            // A terminal daemon job cannot be restarted under the same
            // idempotency token. A fresh attempt keeps the .skpart
            // checkpoint but receives a new job identity.
            const token = self.newToken() catch null;
            if (token) |fresh| {
                self.allocator.free(it.token);
                it.token = fresh;
                it.job = 0;
            }
            it.state = .waiting_retry;
            if (terminal_job != 0 and !self.stageAck(terminal_job)) return;
            self.replaceMessage(it, message);
            self.notify("transfer deferred: {s}", .{std.fs.path.basename(it.dst_path)});
            self.persist();
            self.scheduleRetry();
            self.pump();
            return;
        }
        it.state = .done;
        if (terminal_job != 0 and !self.stageAck(terminal_job)) return;
        if (it.kind == .download) {
            const w = self.ensureWatch(it.watch_token, it.src_host, it.src_path, it.dst_path);
            const watch = w orelse {
                it.state = .failed;
                self.replaceMessage(it, "cannot create durable edit watch");
                self.persist();
                self.notify("download held because edit recovery could not be created: {s}", .{std.fs.path.basename(it.dst_path)});
                return;
            };
            self.captureFingerprint(watch);
            watch.synced_generation = watch.dirty_generation;
            self.armWatch(watch);
            self.persist(); // arm recovery before launching an external app
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
                self.notify("synced back: {s}", .{std.fs.path.basename(w.remote_path)});
            }
        }
        self.removeIntent(it);
        self.queueDirtyWatches();
        self.persist();
        self.pump();
    }

    fn removeIntent(self: *Service, needle: *Intent) void {
        for (self.intents.items, 0..) |it, i| {
            if (it != needle) continue;
            _ = self.intents.orderedRemove(i);
            it.destroy(self.allocator);
            return;
        }
    }

    fn newToken(self: *Service) ![]u8 {
        var raw: [16]u8 = undefined;
        if (c.getentropy(&raw, raw.len) != 0) {
            std.mem.writeInt(u64, raw[0..8], @intCast(c.getpid()), .little);
            std.mem.writeInt(u64, raw[8..16], self.next_order, .little);
        }
        return std.fmt.allocPrint(self.allocator, "{x}", .{raw});
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
            if (it.kind == .download and std.mem.eql(u8, it.src_host, host) and std.mem.eql(u8, it.src_path, remote_path)) return;
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
        self.next_order += 1;
        self.intents.append(self.allocator, it) catch { it.destroy(self.allocator); return; };
        self.persist();
        if (self.durability_error) {
            self.removeIntent(it);
            return;
        }
        self.pump();
    }

    fn createIntent(self: *Service, kind: store.Kind, src_host: []const u8, src_path: []const u8, dst_host: []const u8, dst_path: []const u8, app_id: []const u8, watch_token: []const u8, generation: u64) !*Intent {
        const a = self.allocator;
        const it = try a.create(Intent);
        errdefer a.destroy(it);
        const token = try self.newToken();
        errdefer a.free(token);
        const sh = try a.dupe(u8, src_host);
        errdefer a.free(sh);
        const sp = try a.dupe(u8, src_path);
        errdefer a.free(sp);
        const dh = try a.dupe(u8, dst_host);
        errdefer a.free(dh);
        const dp = try a.dupe(u8, dst_path);
        errdefer a.free(dp);
        const app = try a.dupe(u8, app_id);
        errdefer a.free(app);
        const watch = try a.dupe(u8, watch_token);
        errdefer a.free(watch);
        const message = try a.dupe(u8, "");
        const submitted = if (kind == .upload) fingerprint(src_path) else null;
        it.* = .{
            .token = token,
            .kind = kind,
            .src_host = sh,
            .src_path = sp,
            .dst_host = dh,
            .dst_path = dp,
            .app_id = app,
            .state = .queued,
            .job = 0,
            .order = self.next_order,
            .watch_token = watch,
            .submitted_generation = generation,
            .message = message,
            .attempts = 0,
            .submitted_size = if (submitted) |fp| fp.size else 0,
            .submitted_mtime_ns = if (submitted) |fp| fp.mtime_ns else 0,
            .dest_key = destinationKey(dst_host, dst_path),
        };
        return it;
    }

    /// Submit whatever the queue policy admits. A transfer that is
    /// in flight holds its destination whether or not it is paused:
    /// the SIGSTOPped job still owns the staged partial there.
    fn pump(self: *Service) void {
        const conn = if (self.conn) |*v| v else { self.connect(); return; };
        if (!self.pumpAcks(conn)) return;
        std.mem.sort(*Intent, self.intents.items, {}, struct { fn less(_: void, a: *Intent, b: *Intent) bool { return a.order < b.order; } }.less);
        const slots = self.allocator.alloc(xferqueue.Slot, self.intents.items.len) catch return;
        defer self.allocator.free(slots);
        const map = self.allocator.alloc(usize, self.intents.items.len) catch return;
        defer self.allocator.free(map);
        var n: usize = 0;
        for (self.intents.items, 0..) |it, i| {
            const state: ?xferqueue.State = switch (it.state) {
                .submitting, .running => .running,
                .queued => if (it.paused or it.cancel_requested) null else .queued,
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
            .client_token = it.token,
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
            self.persist();
            if (!paused) self.pump();
            return;
        }
    }

    pub fn moveQueued(self: *Service, token: []const u8, direction: i8) void {
        var idx: ?usize = null;
        for (self.intents.items, 0..) |it, i| if (std.mem.eql(u8, it.token, token) and it.state == .queued) { idx = i; break; };
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
                self.removeIntent(it);
                self.persist();
                self.pump();
                return;
            }
            it.cancel_requested = true;
            if (it.job != 0 and !self.sendJobControl(it.job, "job_cancel")) self.requestDisconnect();
            self.persist();
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

    fn stageAck(self: *Service, job: u64) bool {
        for (self.acknowledgments.items) |existing| if (existing == job) return true;
        self.acknowledgments.append(self.allocator, job) catch {
            self.durability_error = true;
            self.notify("cannot allocate transfer acknowledgment recovery state", .{});
            return false;
        };
        return true;
    }

    fn pumpAcks(self: *Service, conn: *muxclient.Conn) bool {
        for (self.acknowledgments.items) |job| {
            var pending = false;
            for (self.pending_acks.items) |item| if (item.job == job) { pending = true; break; };
            if (pending) continue;
            const req = self.next_req;
            self.next_req +%= 1;
            if (self.next_req == 0) self.next_req = 1;
            self.pending_acks.append(self.allocator, .{ .req = req, .job = job }) catch continue;
            conn.sendJson(.fs_op, .{ .req = req, .op = "job_ack", .job = job }) catch {
                _ = self.pending_acks.pop();
                self.disconnect_after_drain = true;
                return false;
            };
        }
        return true;
    }

    pub fn rows(self: *Service, allocator: std.mem.Allocator) ![]QueueRow {
        const out = try allocator.alloc(QueueRow, self.intents.items.len);
        for (self.intents.items, 0..) |it, i| out[i] = .{
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
        };
        return out;
    }

    fn watchByToken(self: *Service, token: []const u8) ?*Watch {
        for (self.watches.items) |w| if (std.mem.eql(u8, w.token, token)) return w;
        return null;
    }

    fn ensureWatch(self: *Service, token: []const u8, host: []const u8, remote_path: []const u8, cache_path: []const u8) ?*Watch {
        if (self.watchByToken(token)) |w| return w;
        const w = self.dupWatch(.{ .token = token, .host = host, .remote_path = remote_path, .cache_path = cache_path }) catch return null;
        self.watches.append(self.allocator, w) catch { w.destroy(self.allocator); return null; };
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
            self.persist();
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
        w.service.persist();
        w.service.queueDirtyWatches();
        w.service.pump();
    }

    fn queueDirtyWatches(self: *Service) void {
        for (self.watches.items) |w| {
            if (w.dirty_generation <= w.synced_generation) continue;
            var active = false;
            for (self.intents.items) |it| if (it.kind == .upload and std.mem.eql(u8, it.watch_token, w.token)) { active = true; break; };
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
            for (service.subscribers.items) |subscriber| if (subscriber.ctx == notify_ctx.?) { exists = true; break; };
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
