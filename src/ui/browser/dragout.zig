//! Browser entries leaving sketerm by drag: the content provider that
//! hands them to other applications as files.
//!
//! The provider offers the MIME types GTK serializes a GdkFileList to
//! (text/uri-list, plus the document portal's
//! `application/vnd.portal.filetransfer` when the portal is running) and
//! answers them with `gdk_content_serialize_async` on a real GdkFileList,
//! so URI encoding and portal export are GTK's own. Nothing is fetched
//! until a receiver asks for one of those types: a drag that is
//! cancelled, or dropped on a sketerm surface (those read
//! `dragspecs`), never downloads anything.
//!
//! A remote entry is fetched on that first request through the
//! transfer service (`submitDelivery`, a daemon `cross_copy` into
//! `$XDG_CACHE_HOME/sketerm/dnd/drag-*/<name>`), so it shows in the
//! Transfer Center with progress, retries and Cancel; the pending
//! request completes when every entry is staged, or fails with the
//! transfer's error. Once requested, a fetch runs to completion even if
//! the drag ends: receivers with a short read timeout (Qt, XWayland
//! bridges) give up on a slow fetch, and the finished copy is then
//! handed instantly to the next drag of the same unchanged file
//! (`dragout.reusable`). Staged copies are swept after
//! `dragout.STAGE_TTL_SECS`, because receivers such as chat clients
//! upload asynchronously after the drop.

const std = @import("std");
const c = @import("../../c.zig").c;
const dragout = @import("../../filebrowser/dragout.zig");
const file_transfers = @import("../file_transfers.zig");
const dirsweep = @import("../../util/dirsweep.zig");
const nowMs = @import("../../util/clock.zig").nowMs;

/// One dragged entry as the drag source knows it.
pub const Source = struct {
    /// Null for an entry on this machine.
    host: ?[]const u8,
    path: []const u8,
    fp: dragout.Fingerprint,
};

/// How often running fetches are polled.
const POLL_MS: c.guint = 250;

/// A fetch whose ledger state and byte count stay unchanged this long
/// fails its waiting drops instead of hanging them (an unreachable
/// daemon, a queue that never admits it).
const STALL_MS: i64 = 120_000;

/// One remote entry's journey into the staging cache. Shared by every
/// drag that names the same entry while it is running or reusable.
const Fetch = struct {
    refs: u32 = 1,
    host: []u8,
    path: []u8,
    fp: dragout.Fingerprint,
    /// The browser view that asked first: the Transfer Center shows the
    /// row there. Only ever compared, never dereferenced.
    origin: ?*anyopaque,
    phase: enum { idle, running, ready, failed } = .idle,
    staged: ?[:0]u8 = null,
    token: ?[]u8 = null,
    message_buf: [256]u8 = undefined,
    message_len: usize = 0,
    finished_ms: i64 = 0,
    /// Stall detection: the last observed (state, bytes) and when it changed.
    last_state: u8 = 0,
    last_done: u64 = 0,
    last_change_ms: i64 = 0,

    fn message(self: *const Fetch) []const u8 {
        return self.message_buf[0..self.message_len];
    }

    fn setMessage(self: *Fetch, text: []const u8) void {
        const n = @min(text.len, self.message_buf.len);
        @memcpy(self.message_buf[0..n], text[0..n]);
        self.message_len = n;
    }

    fn unref(self: *Fetch) void {
        self.refs -= 1;
        if (self.refs > 0) return;
        const a = registry.allocator;
        a.free(self.host);
        a.free(self.path);
        if (self.staged) |s| a.free(s);
        if (self.token) |t| a.free(t);
        a.destroy(self);
    }

    /// Whether the staged copy can serve a new drag of `fp`.
    fn servable(self: *const Fetch, fp: dragout.Fingerprint, now: i64) bool {
        return switch (self.phase) {
            .idle, .running => self.fp.eql(fp),
            .ready => dragout.reusable(self.fp, fp, self.finished_ms, now) and stagedExists(self),
            .failed => false,
        };
    }
};

fn stagedExists(f: *const Fetch) bool {
    const staged = f.staged orelse return false;
    // A receiver given MOVE may have taken the copy away.
    return c.access(staged.ptr, c.F_OK) == 0;
}

/// A receiver's pending request for one MIME type.
const Waiter = struct {
    task: *c.GTask,
    export_: *Instance,
    mime: [*:0]const u8,
    stream: *c.GOutputStream,
    priority: c_int,
    cancellable: ?*c.GCancellable,
};

/// Process-wide fetch bookkeeping; everything runs on the main thread.
const Registry = struct {
    /// The app's long-lived allocator, adopted from the first drag: the
    /// transfer service appends our subscription with it, so it must be
    /// the one every other subscriber uses.
    allocator: std.mem.Allocator = undefined,
    allocator_set: bool = false,
    fetches: std.ArrayList(*Fetch) = .empty,
    waiters: std.ArrayList(*Waiter) = .empty,
    timer: c.guint = 0,
    service: ?*file_transfers.Service = null,
    seq: u64 = 0,
    last_sweep_ms: i64 = std.math.minInt(i64),
};

var registry: Registry = .{};

/// Remote fetches started by drag requests in this process (the
/// `dnd-probe` verification command reports it).
pub var fetches_started: u64 = 0;

/// One dragged entry inside a provider.
const Item = struct {
    /// The entry's own path when it is local.
    local: ?[:0]u8 = null,
    /// The fetch staging it when it is remote (a held reference).
    fetch: ?*Fetch = null,
};

const State = struct {
    allocator: std.mem.Allocator,
    items: []Item,

    fn deinit(self: *State) void {
        for (self.items) |item| {
            if (item.local) |p| self.allocator.free(p);
            if (item.fetch) |f| f.unref();
        }
        self.allocator.free(self.items);
        self.allocator.destroy(self);
    }

    fn hasRemote(self: *const State) bool {
        for (self.items) |item| if (item.fetch != null) return true;
        return false;
    }

    const Status = union(enum) { ready, pending, failed: []const u8 };

    fn status(self: *const State) Status {
        var pending = false;
        for (self.items) |item| {
            const f = item.fetch orelse continue;
            switch (f.phase) {
                .ready => {},
                .failed => return .{ .failed = f.message() },
                .idle, .running => pending = true,
            }
        }
        return if (pending) .pending else .ready;
    }
};

const Instance = extern struct {
    parent: c.GdkContentProvider,
    state: ?*State,
};

var gtype: c.GType = 0;
var parent_class: ?*c.GdkContentProviderClass = null;
/// Identifies this provider's GTasks (any unique address will do).
var source_tag: u8 = 0;

fn ensureType() c.GType {
    if (gtype != 0) return gtype;
    gtype = c.g_type_register_static_simple(
        c.gdk_content_provider_get_type(),
        "SketermFileExport",
        @sizeOf(c.GdkContentProviderClass),
        @ptrCast(&classInit),
        @sizeOf(Instance),
        null,
        c.G_TYPE_FLAG_NONE,
    );
    return gtype;
}

fn classInit(klass: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    parent_class = @ptrCast(@alignCast(c.g_type_class_peek_parent(klass)));
    const object_class: *c.GObjectClass = @ptrCast(@alignCast(klass));
    object_class.finalize = &finalize;
    const provider_class: *c.GdkContentProviderClass = @ptrCast(@alignCast(klass));
    provider_class.ref_formats = &refFormats;
    provider_class.write_mime_type_async = &writeMimeTypeAsync;
    provider_class.write_mime_type_finish = &writeMimeTypeFinish;
    provider_class.get_value = &getValue;
}

fn instanceOf(p: ?*anyopaque) *Instance {
    return @ptrCast(@alignCast(p.?));
}

fn finalize(object: [*c]c.GObject) callconv(.c) void {
    const inst = instanceOf(object);
    if (inst.state) |s| s.deinit();
    inst.state = null;
    const object_class: *c.GObjectClass = @ptrCast(@alignCast(parent_class.?));
    if (object_class.finalize) |f| f(object);
}

/// The provider for `sources`, or null when nothing can be offered.
/// `origin` names the browser view whose Transfer Center shows the fetches.
pub fn newProvider(allocator: std.mem.Allocator, sources: []const Source, origin: ?*anyopaque) ?*c.GdkContentProvider {
    if (!registry.allocator_set) {
        registry.allocator = allocator;
        registry.allocator_set = true;
    }
    const state = allocator.create(State) catch return null;
    state.* = .{ .allocator = allocator, .items = allocator.alloc(Item, sources.len) catch {
        allocator.destroy(state);
        return null;
    } };
    @memset(state.items, .{});
    for (sources, state.items) |src, *item| {
        if (src.host) |host| {
            item.fetch = fetchFor(host, src.path, src.fp, origin) orelse {
                state.deinit();
                return null;
            };
        } else {
            item.local = allocator.dupeSentinel(u8, src.path, 0) catch {
                state.deinit();
                return null;
            };
        }
    }
    const obj = c.g_object_new(ensureType(), null) orelse {
        state.deinit();
        return null;
    };
    instanceOf(obj).state = state;
    return @ptrCast(@alignCast(obj));
}

/// A held reference to the fetch serving this remote entry: a running
/// or reusable one when there is one, else a new idle one.
fn fetchFor(host: []const u8, path: []const u8, fp: dragout.Fingerprint, origin: ?*anyopaque) ?*Fetch {
    const now = nowMs();
    prune(now);
    for (registry.fetches.items) |f| {
        if (!std.mem.eql(u8, f.host, host) or !std.mem.eql(u8, f.path, path)) continue;
        if (!f.servable(fp, now)) continue;
        f.refs += 1;
        return f;
    }
    const a = registry.allocator;
    const f = a.create(Fetch) catch return null;
    f.* = .{
        .host = a.dupe(u8, host) catch {
            a.destroy(f);
            return null;
        },
        .path = a.dupe(u8, path) catch {
            a.free(f.host);
            a.destroy(f);
            return null;
        },
        .fp = fp,
        .origin = origin,
    };
    registry.fetches.append(a, f) catch {
        f.unref();
        return null;
    };
    // One reference for the registry, one for the caller.
    f.refs += 1;
    return f;
}

/// The MIME types a GdkFileList serializes to, minus plain text (the
/// drag's own quoted-spec string answers that).
fn refFormats(_: [*c]c.GdkContentProvider) callconv(.c) ?*c.GdkContentFormats {
    const builder = c.gdk_content_formats_builder_new();
    const files = c.gdk_content_formats_union_serialize_mime_types(c.gdk_content_formats_new_for_gtype(c.gdk_file_list_get_type()));
    defer c.gdk_content_formats_unref(files);
    var n: usize = 0;
    const mimes = c.gdk_content_formats_get_mime_types(files, &n);
    for (0..n) |i| {
        const mime = std.mem.span(@as([*:0]const u8, @ptrCast(mimes[i])));
        if (std.mem.startsWith(u8, mime, "text/plain")) continue;
        c.gdk_content_formats_builder_add_mime_type(builder, mimes[i]);
    }
    return c.gdk_content_formats_builder_free_to_formats(builder);
}

/// In-process readers only: a local drag answers at once; a remote one
/// refuses rather than fetch for a sketerm surface (they read `dragspecs`).
fn getValue(provider: [*c]c.GdkContentProvider, value: [*c]c.GValue, err: [*c][*c]c.GError) callconv(.c) c.gboolean {
    const inst = instanceOf(provider);
    if (c.g_type_check_value_holds(value, c.gdk_file_list_get_type()) != 0) {
        if (inst.state) |state| {
            if (state.status() == .ready) {
                const list = fileList(state) orelse {
                    c.g_set_error_literal(err, c.g_io_error_quark(), c.G_IO_ERROR_FAILED, "out of memory");
                    return 0;
                };
                c.g_value_take_boxed(value, list);
                return 1;
            }
            if (state.hasRemote()) {
                c.g_set_error_literal(err, c.g_io_error_quark(), c.G_IO_ERROR_FAILED, "remote entries are fetched only for other applications");
                return 0;
            }
        }
    }
    const pc = parent_class orelse return 0;
    const f = pc.get_value orelse return 0;
    return f(provider, value, err);
}

/// A new GdkFileList of every item's local path (all must be ready).
fn fileList(state: *const State) ?*c.GdkFileList {
    var list: [*c]c.GSList = null;
    var i = state.items.len;
    while (i > 0) {
        i -= 1;
        const item = state.items[i];
        const path = item.local orelse (item.fetch orelse unreachable).staged orelse {
            c.g_slist_free_full(list, &c.g_object_unref);
            return null;
        };
        list = c.g_slist_prepend(list, c.g_file_new_for_path(path.ptr));
    }
    defer c.g_slist_free_full(list, &c.g_object_unref);
    return c.gdk_file_list_new_from_list(list);
}

fn writeMimeTypeAsync(
    provider: [*c]c.GdkContentProvider,
    mime: [*c]const u8,
    stream: [*c]c.GOutputStream,
    priority: c_int,
    cancellable: [*c]c.GCancellable,
    callback: c.GAsyncReadyCallback,
    user: c.gpointer,
) callconv(.c) void {
    const inst = instanceOf(provider);
    const task = c.g_task_new(provider, cancellable, callback, user) orelse return;
    c.g_task_set_source_tag(task, &source_tag);
    const state = inst.state orelse return failTask(task, "drag content is gone");
    const waiter = registry.allocator.create(Waiter) catch return failTask(task, "out of memory");
    waiter.* = .{
        .task = task,
        .export_ = inst,
        .mime = @ptrCast(mime),
        .stream = @ptrCast(@alignCast(c.g_object_ref(stream))),
        .priority = priority,
        .cancellable = if (cancellable != null) @ptrCast(@alignCast(c.g_object_ref(cancellable))) else null,
    };
    // A request (re)starts every fetch it needs; one that failed for an
    // earlier request gets a fresh attempt.
    for (state.items) |item| {
        const f = item.fetch orelse continue;
        if (f.phase == .idle or f.phase == .failed) start(f);
    }
    registry.waiters.append(registry.allocator, waiter) catch {
        destroyWaiter(waiter);
        return failTask(task, "out of memory");
    };
    settleWaiters();
    ensureTimer();
}

fn writeMimeTypeFinish(_: [*c]c.GdkContentProvider, result: ?*c.GAsyncResult, err: [*c][*c]c.GError) callconv(.c) c.gboolean {
    return c.g_task_propagate_boolean(@ptrCast(@alignCast(result)), err);
}

fn failTask(task: *c.GTask, msg: []const u8) void {
    var z: [320:0]u8 = undefined;
    const text = std.fmt.bufPrintSentinel(&z, "{s}", .{msg}, 0) catch "file transfer failed";
    c.g_task_return_new_error_literal(task, c.g_io_error_quark(), c.G_IO_ERROR_FAILED, text.ptr);
    c.g_object_unref(task);
}

fn destroyWaiter(w: *Waiter) void {
    c.g_object_unref(w.stream);
    if (w.cancellable) |cn| c.g_object_unref(cn);
    registry.allocator.destroy(w);
}

/// Answer every waiter whose fetches all settled.
fn settleWaiters() void {
    var i: usize = 0;
    while (i < registry.waiters.items.len) {
        const w = registry.waiters.items[i];
        const state = w.export_.state orelse {
            _ = registry.waiters.orderedRemove(i);
            failTask(w.task, "drag content is gone");
            destroyWaiter(w);
            continue;
        };
        switch (state.status()) {
            .pending => {
                i += 1;
                continue;
            },
            .failed => |msg| {
                _ = registry.waiters.orderedRemove(i);
                failTask(w.task, if (msg.len > 0) msg else "file transfer failed");
                destroyWaiter(w);
            },
            .ready => {
                _ = registry.waiters.orderedRemove(i);
                serialize(w, state);
            },
        }
    }
}

/// Hand the receiver the file list in its MIME type; GTK's serializer
/// writes the URIs (or registers the files with the document portal).
fn serialize(w: *Waiter, state: *const State) void {
    const list = fileList(state) orelse {
        failTask(w.task, "out of memory");
        destroyWaiter(w);
        return;
    };
    var value: c.GValue = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&value, c.gdk_file_list_get_type());
    c.g_value_take_boxed(&value, list);
    defer c.g_value_unset(&value);
    const task = w.task;
    c.gdk_content_serialize_async(w.stream, w.mime, &value, w.priority, w.cancellable, @ptrCast(&onSerialized), task);
    destroyWaiter(w);
}

fn onSerialized(_: ?*c.GObject, result: ?*c.GAsyncResult, user: ?*anyopaque) callconv(.c) void {
    const task: *c.GTask = @ptrCast(@alignCast(user.?));
    var err: ?*c.GError = null;
    if (c.gdk_content_serialize_finish(result, &err) == 0)
        c.g_task_return_error(task, err)
    else
        c.g_task_return_boolean(task, 1);
    c.g_object_unref(task);
}

fn notifyNoop(_: *anyopaque, _: []const u8) void {}

fn ensureService() ?*file_transfers.Service {
    if (registry.service) |s| return s;
    registry.service = file_transfers.acquire(registry.allocator, @ptrCast(&registry), &notifyNoop) catch null;
    return registry.service;
}

fn releaseService() void {
    const s = registry.service orelse return;
    registry.service = null;
    file_transfers.release(s, @ptrCast(&registry));
}

fn failFetch(f: *Fetch, text: []const u8) void {
    f.phase = .failed;
    f.setMessage(text);
    if (f.token) |t| {
        if (registry.service) |s| _ = s.cancel(t);
        registry.allocator.free(t);
        f.token = null;
    }
}

/// Submit one remote entry's delivery into a fresh staging directory.
fn start(f: *Fetch) void {
    const a = registry.allocator;
    if (f.token) |t| a.free(t);
    f.token = null;
    if (f.staged) |s| a.free(s);
    f.staged = null;
    f.message_len = 0;
    const service = ensureService() orelse return failFetch(f, "the transfer service is unavailable");
    var root_buf: [4096:0]u8 = undefined;
    const root = stageRoot(&root_buf) orelse return failFetch(f, "cannot create the drag staging directory");
    sweepSoon(root);
    registry.seq +%= 1;
    var name_buf: [96]u8 = undefined;
    const dir_name = dragout.stageDirName(&name_buf, c.getpid(), c.g_get_monotonic_time(), registry.seq) catch
        return failFetch(f, "cannot name a staging directory");
    var dir_buf: [4352:0]u8 = undefined;
    const dir = std.fmt.bufPrintSentinel(&dir_buf, "{s}/{s}", .{ root, dir_name }, 0) catch
        return failFetch(f, "staging path too long");
    if (c.mkdir(dir.ptr, 0o700) != 0) return failFetch(f, "cannot create a staging directory");
    f.staged = std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ dir, dragout.stagedName(f.path, f.host) }, 0) catch
        return failFetch(f, "out of memory");
    f.token = service.submitDelivery(a, f.host, f.path, "", f.staged.?, false, f.origin) orelse
        return failFetch(f, "the transfer could not be recorded");
    f.phase = .running;
    fetches_started += 1;
    f.last_state = 0xff;
    f.last_change_ms = nowMs();
}

/// `$XDG_CACHE_HOME/sketerm/dnd`, created private and checked to be ours.
fn stageRoot(buf: *[4096:0]u8) ?[:0]const u8 {
    const cache = c.g_get_user_cache_dir() orelse return null;
    const dir = std.fmt.bufPrintSentinel(buf, "{s}/sketerm/dnd", .{std.mem.span(cache)}, 0) catch return null;
    if (c.g_mkdir_with_parents(dir.ptr, 0o700) != 0) return null;
    var st: c.struct_stat = undefined;
    if (c.lstat(dir.ptr, &st) != 0 or st.st_uid != c.geteuid() or (st.st_mode & c.S_IFMT) != c.S_IFDIR) return null;
    if ((st.st_mode & 0o777) != 0o700 and c.chmod(dir.ptr, @as(c.mode_t, 0o700)) != 0) return null;
    return dir;
}

/// Sweep expired staging trees on a detached worker (it touches no GTK
/// state, and a large tree must not stall the main loop); at most hourly.
fn sweepSoon(root: [:0]const u8) void {
    const now = nowMs();
    if (registry.last_sweep_ms != std.math.minInt(i64) and now - registry.last_sweep_ms < 3600 * 1000) return;
    registry.last_sweep_ms = now;
    const owned = std.heap.c_allocator.dupeSentinel(u8, root, 0) catch return;
    const thread = std.Thread.spawn(.{}, sweepMain, .{owned}) catch {
        std.heap.c_allocator.free(owned);
        return;
    };
    thread.detach();
}

fn sweepMain(root: [:0]u8) void {
    defer std.heap.c_allocator.free(root);
    dirsweep.sweepTrees(root.ptr, .{ .prefix = dragout.STAGE_PREFIX, .max_age_secs = dragout.STAGE_TTL_SECS });
}

fn ensureTimer() void {
    if (registry.timer != 0) return;
    if (registry.waiters.items.len == 0 and !anyRunning()) return;
    registry.timer = c.g_timeout_add(POLL_MS, @ptrCast(&onTick), null);
}

fn anyRunning() bool {
    for (registry.fetches.items) |f| if (f.phase == .running) return true;
    return false;
}

fn onTick(_: ?*anyopaque) callconv(.c) c.gboolean {
    const now = nowMs();
    for (registry.fetches.items) |f| {
        if (f.phase != .running) continue;
        poll(f, now);
    }
    settleWaiters();
    prune(now);
    if (registry.waiters.items.len == 0 and !anyRunning()) {
        registry.timer = 0;
        releaseService();
        return 0;
    }
    return 1;
}

fn poll(f: *Fetch, now: i64) void {
    const service = registry.service orelse return failFetch(f, "the transfer service went away");
    const token = f.token orelse return failFetch(f, "the transfer has no record");
    const progress = service.intentProgress(token) orelse {
        // Gone from the ledger: finished and acknowledged.
        return finishFetch(f, now);
    };
    switch (progress.state) {
        .done => finishFetch(f, now),
        .failed => failFetch(f, if (progress.message.len > 0) progress.message else "the transfer failed"),
        .canceled => failFetch(f, "the transfer was canceled"),
        else => {
            const state: u8 = @intCast(@intFromEnum(progress.state));
            if (state != f.last_state or progress.done != f.last_done) {
                f.last_state = state;
                f.last_done = progress.done;
                f.last_change_ms = now;
            } else if (now - f.last_change_ms > STALL_MS) {
                failFetch(f, "the transfer made no progress");
            }
        },
    }
}

fn finishFetch(f: *Fetch, now: i64) void {
    f.phase = .ready;
    f.finished_ms = now;
    if (f.token) |t| registry.allocator.free(t);
    f.token = null;
}

/// Drop registry references nobody can use any more. The staged files
/// stay; the sweep owns their lifetime.
fn prune(now: i64) void {
    var i: usize = 0;
    while (i < registry.fetches.items.len) {
        const f = registry.fetches.items[i];
        const useless = f.refs == 1 and switch (f.phase) {
            .idle, .failed => true,
            .running => false,
            .ready => now - f.finished_ms >= dragout.REUSE_MS,
        };
        if (useless) {
            _ = registry.fetches.orderedRemove(i);
            f.unref();
        } else i += 1;
    }
}
