//! The editor face's disk half: daemon-backed loads and saves, the
//! external-change probe and its inline banner, and the per-host pool
//! of file-service connections every editor worker shares.
//!
//! Every daemon call here BLOCKS, so it runs on a detached worker that
//! touches no GTK or document state and hands back through `g_idle_add`
//! fenced by `EditorView.Fence` (CLAUDE.md's threading rule). The GUI
//! never touches the disk itself.
//!
//! ## One connection per host, reused
//!
//! A remote connection costs an ssh bootstrap, and loads, saves, focus
//! probes, gutter refreshes and project searches used to dial one EACH.
//! `pool` keeps a finished job's connection for the next one on the same
//! host. A connection comes back only when it is still usable, and an
//! idle one is reused only while it is young and its socket is quiet (a
//! readable or hung-up idle request/reply socket is dead or out of
//! sync). Idempotent jobs retry once on a fresh connection when a REUSED
//! one fails in transport; a save never retries, because the first
//! attempt may have landed and a replay would then trip its own conflict
//! guard.
//!
//! ## External changes are a poll, not a watch
//!
//! The daemon's live views are directory-scoped (a full listing of the
//! containing directory per open file), need a connection parked on the
//! GLib loop, and their inotify backend is Linux-only, so a remote
//! macOS/BSD host would behave differently; they also carry no
//! IN_MODIFY. A batched stat probe has none of that: one connection per
//! HOST carries every open document's stat, identical local and remote.
//! It fires when the user comes back to the editor (canvas focus, pane
//! focus, tab switch), which is exactly when a stale buffer starts to
//! matter, and the save path is guarded by the daemon-side mtime check,
//! which is race-free in a way no poll can be.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const clock = @import("../util/clock.zig");
const ev = @import("editorview.zig");
const EditorView = ev.EditorView;
const ETab = ev.ETab;
const Fence = ev.Fence;
const Document = @import("../editor/document.zig").Document;
const reload = @import("../editor/reload.zig");
const ediff = @import("../editor/diff.zig");
const sel_mod = @import("../editor/selection.zig");
const Selection = sel_mod.Selection;
const fsdrive = @import("../ipc/fsdrive.zig");
const muxclient = @import("../mux/client.zig");
const paths = @import("../filebrowser/paths.zig");
const confirm = @import("confirm.zig");
const editorproj = @import("editorproj.zig");
const editoroutline = @import("editoroutline.zig");
const editorjournal = @import("editorjournal.zig");
const editorlang = @import("editorlang.zig");
const Config = @import("../config.zig").Config;

/// Open size cap: bigger files are refused with a clear error.
pub const MAX_FILE_BYTES: usize = 64 << 20;

// ======================================================================
// Connection pool
// ======================================================================

/// How long an idle connection stays worth reusing. Long enough to cover
/// the bursts one user action causes (open + probe + gutter + project),
/// short enough that a NAT that dropped a quiet ssh session is rarely
/// the one handed out.
pub const POOL_IDLE_MAX_MS: i64 = 5 * 60 * 1000;
/// Idle connections kept per host; a burst beyond it dials extra ones
/// and lets them go afterwards.
pub const POOL_IDLE_PER_HOST: usize = 2;

/// A keyed pool of exclusive-use connections, generic so the reuse rules
/// are testable without a daemon. Thread-safe: workers acquire and
/// release concurrently.
pub fn KeyedPool(comptime Conn: type, comptime Ops: type) type {
    return struct {
        const Self = @This();

        mutex: c.pthread_mutex_t = std.mem.zeroes(c.pthread_mutex_t),
        inited: bool = false,
        idle: std.ArrayList(Idle) = .empty,
        alloc: std.mem.Allocator,

        const Idle = struct {
            /// Owned; "" = the local daemon.
            host: []u8,
            conn: Conn,
            since_ms: i64,
        };

        /// One exclusive connection; hand it back with `release`.
        pub const Lease = struct {
            conn: Conn,
            /// It came from the idle list rather than a fresh dial.
            reused: bool,
        };

        fn lock(self: *Self) void {
            if (!self.inited) {
                _ = c.pthread_mutex_init(&self.mutex, null);
                self.inited = true;
            }
            _ = c.pthread_mutex_lock(&self.mutex);
        }

        fn unlock(self: *Self) void {
            _ = c.pthread_mutex_unlock(&self.mutex);
        }

        /// A healthy idle connection for `host`, else a fresh dial.
        pub fn acquire(self: *Self, host: ?[]const u8) !Lease {
            const key = host orelse "";
            const now = clock.nowMs();
            var stale: std.ArrayList(Conn) = .empty;
            defer {
                for (stale.items) |*s| Ops.deinit(s);
                stale.deinit(self.alloc);
            }
            self.lock();
            var found: ?Conn = null;
            var i: usize = self.idle.items.len;
            while (i > 0) {
                i -= 1;
                const it = self.idle.items[i];
                if (!std.mem.eql(u8, it.host, key)) continue;
                const entry = self.idle.orderedRemove(i);
                self.alloc.free(entry.host);
                var conn = entry.conn;
                if (found == null and now - entry.since_ms <= POOL_IDLE_MAX_MS and Ops.idleHealthy(&conn)) {
                    found = conn;
                } else {
                    stale.append(self.alloc, conn) catch Ops.deinit(&conn);
                }
            }
            self.unlock();
            if (found) |conn| return .{ .conn = conn, .reused = true };
            return .{ .conn = try Ops.dial(host), .reused = false };
        }

        /// Hand a lease back: kept for reuse when it is still usable and
        /// the host has room, closed otherwise.
        pub fn release(self: *Self, host: ?[]const u8, lease: *Lease) void {
            if (!Ops.usable(&lease.conn)) {
                Ops.deinit(&lease.conn);
                return;
            }
            Ops.reset(&lease.conn);
            const key = host orelse "";
            self.lock();
            defer self.unlock();
            var n: usize = 0;
            for (self.idle.items) |it| {
                if (std.mem.eql(u8, it.host, key)) n += 1;
            }
            if (n >= POOL_IDLE_PER_HOST) {
                Ops.deinit(&lease.conn);
                return;
            }
            const owned = self.alloc.dupe(u8, key) catch {
                Ops.deinit(&lease.conn);
                return;
            };
            self.idle.append(self.alloc, .{ .host = owned, .conn = lease.conn, .since_ms = clock.nowMs() }) catch {
                self.alloc.free(owned);
                Ops.deinit(&lease.conn);
            };
        }

        /// Close a lease that failed; it is never pooled.
        pub fn discard(_: *Self, lease: *Lease) void {
            Ops.deinit(&lease.conn);
        }

        /// Idle connections currently held for `host` (tests).
        pub fn idleCount(self: *Self, host: ?[]const u8) usize {
            self.lock();
            defer self.unlock();
            var n: usize = 0;
            for (self.idle.items) |it| {
                if (std.mem.eql(u8, it.host, host orelse "")) n += 1;
            }
            return n;
        }
    };
}

/// The production connection: a hello-probed daemon file-service link.
const FsOps = struct {
    fn dial(host: ?[]const u8) !fsdrive.Fs {
        const allocator = std.heap.c_allocator;
        const conn = if (host) |remote| blk: {
            var config = Config.load(allocator);
            defer config.deinit();
            break :blk try muxclient.Conn.connectRemote(allocator, remote, config.muxConnectOptions());
        } else try muxclient.Conn.connectLocalAutostart(allocator);
        return fsdrive.Fs.initConn(allocator, conn);
    }

    fn usable(fs: *fsdrive.Fs) bool {
        return fs.usable();
    }

    /// An idle request/reply socket has nothing to say: readable means
    /// EOF or a stray frame, either way it cannot be trusted.
    fn idleHealthy(fs: *fsdrive.Fs) bool {
        var pfd = c.struct_pollfd{ .fd = fs.pollFd(), .events = c.POLLIN, .revents = 0 };
        if (c.poll(&pfd, 1, 0) < 0) return false;
        return (pfd.revents & (c.POLLIN | c.POLLHUP | c.POLLERR | c.POLLNVAL)) == 0;
    }

    /// Drop whatever the last user left stashed, so the next one sees
    /// only its own events.
    fn reset(fs: *fsdrive.Fs) void {
        while (fs.takeJobEvent()) |e0| {
            var e = e0;
            e.deinit();
        }
        while (fs.takeDelta()) |d0| {
            var d = d0;
            d.deinit();
        }
    }

    fn deinit(fs: *fsdrive.Fs) void {
        fs.deinit();
    }
};

pub const FsPool = KeyedPool(fsdrive.Fs, FsOps);

/// The process-wide pool every editor worker draws from.
pub var pool: FsPool = .{ .alloc = std.heap.c_allocator };

/// A daemon answer (the connection is fine) versus a transport failure.
pub fn isTransportError(err: anyerror) bool {
    return err == fsdrive.Error.NotConnected or err == fsdrive.Error.Timeout or err == fsdrive.Error.BadReply;
}

/// Run an IDEMPOTENT daemon operation on a pooled connection for `host`,
/// retrying once on a fresh connection when a reused one fails in
/// transport. `op` is `fn (ctx, *fsdrive.Fs) !void`.
pub fn withFs(host: ?[]const u8, ctx: anytype, comptime op: anytype) !void {
    var lease = try pool.acquire(host);
    op(ctx, &lease.conn) catch |err| {
        if (!lease.reused or !isTransportError(err)) {
            if (isTransportError(err)) pool.discard(&lease) else pool.release(host, &lease);
            return err;
        }
        pool.discard(&lease);
        var fresh = try pool.acquire(host);
        op(ctx, &fresh.conn) catch |err2| {
            if (isTransportError(err2)) pool.discard(&fresh) else pool.release(host, &fresh);
            return err2;
        };
        pool.release(host, &fresh);
        return;
    };
    pool.release(host, &lease);
}

// ======================================================================
// Reads
// ======================================================================

/// Observe one path's identity, following symlinks (fsdrive.statFollow
/// explains why the follow is mandatory).
///
/// A missing path answers `present = false`; a TRANSPORT failure returns
/// the error, so a dead link can never be mistaken for a deleted file.
pub fn probePath(fs: *fsdrive.Fs, path: []const u8, out: *reload.DiskState) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const e = fs.statFollow(arena.allocator(), path) catch |err| {
        if (err == fsdrive.Error.FsOpFailed or err == fsdrive.Error.BadRequest) {
            out.* = .{ .known = true, .present = false };
            return;
        }
        return err;
    };
    out.* = .{
        .known = true,
        .present = true,
        .mtime_ns = e.mtime_ns,
        .mtime_ms = e.mtime_ms,
        .size = e.size,
        .ino = e.ino,
        .mode = e.mode,
    };
}

/// Read a whole host-side file into `out`, refusing anything over `cap`.
/// The project layer reads files through this too, so a candidate that
/// is too big is refused identically to one the user tries to open.
pub fn readAllCapped(fs: *fsdrive.Fs, path: []const u8, out: *std.ArrayList(u8), cap: usize) !void {
    var info: fsdrive.ReadInfo = .{ .size = 0, .eof = true };
    return readAllInto(fs, path, out, cap, &info);
}

fn readAllInto(fs: *fsdrive.Fs, path: []const u8, out: *std.ArrayList(u8), cap: usize, info_out: *fsdrive.ReadInfo) !void {
    const allocator = std.heap.c_allocator;
    const probe = try fs.read(path, 0, 0, out);
    if (probe.size > cap) return error.SourceTooLarge;
    info_out.* = probe;
    try out.ensureTotalCapacity(allocator, @intCast(probe.size));
    var offset: u64 = 0;
    while (offset < probe.size) {
        const before = out.items.len;
        const remaining = probe.size - offset;
        const requested: u32 = @intCast(@min(remaining, fsdrive.fsserve.MAX_READ));
        const info = try fs.read(path, offset, requested, out);
        const received = out.items.len - before;
        if (received == 0) return error.ShortRead;
        offset += received;
        if (out.items.len > cap) return error.SourceTooLarge;
        if (info.eof) break;
    }
    if (offset != probe.size) return error.ShortRead;
}

// ======================================================================
// Load / save jobs
// ======================================================================

/// One daemon-backed read or atomic write, run on a detached thread.
/// Owned allocations via c_allocator; delivered with g_idle_add.
const IoJob = struct {
    fence: *Fence,
    /// Matches ETab.io_gen; a mismatch at delivery = orphaned.
    gen: u64,
    kind: enum { load, save },
    spec: []u8,
    save_bytes: []u8 = &.{},
    expected_mtime: ?i64 = null,
    /// Document revision and history state the save snapshot was taken
    /// at: what is on disk once it lands.
    revision: u64 = 0,
    state: u64 = 0,

    ok: bool = false,
    conflict: bool = false,
    /// Load of a path that does not exist (yet): a new empty file.
    not_found: bool = false,
    binary: bool = false,
    err_buf: [96]u8 = undefined,
    err_len: usize = 0,
    bytes: []u8 = &.{},
    /// Post-op identity of the file: the new conflict baseline after a
    /// load/save, and the OTHER file's identity after a conflict.
    disk: reload.DiskState = .{},
    /// Reload that must land on the current cursor/scroll, not at the
    /// top of the document.
    keep_position: bool = false,
    /// `.editorconfig` properties for the loaded path.
    ec: @import("../editor/editorconfig.zig").Props = .{},

    fn setErr(self: *IoJob, text: []const u8) void {
        self.err_len = @min(text.len, self.err_buf.len);
        @memcpy(self.err_buf[0..self.err_len], text[0..self.err_len]);
    }

    fn errText(self: *const IoJob) []const u8 {
        return self.err_buf[0..self.err_len];
    }

    fn destroy(self: *IoJob) void {
        const a = std.heap.c_allocator;
        a.free(self.spec);
        if (self.save_bytes.len > 0) a.free(self.save_bytes);
        if (self.bytes.len > 0) a.free(self.bytes);
        self.fence.unref();
        a.destroy(self);
    }

    /// The load body; resets its outputs so a retry starts clean.
    fn load(self: *IoJob, fs: *fsdrive.Fs) !void {
        const allocator = std.heap.c_allocator;
        const loc = paths.parseSpec(self.spec);
        self.ec = editorlang.readEditorconfig(fs, loc.path);
        var out: std.ArrayList(u8) = .empty;
        var info: fsdrive.ReadInfo = .{ .size = 0, .eof = true };
        readAllInto(fs, loc.path, &out, MAX_FILE_BYTES, &info) catch |err| {
            out.deinit(allocator);
            if (isTransportError(err)) return err;
            if (err == error.SourceTooLarge or err == error.ShortRead) {
                self.setErr(@errorName(err));
            } else {
                // Unreadable = treat as a NEW file (editor convention).
                self.not_found = true;
                self.ok = true;
            }
            return;
        };
        if (@import("../editor/document.zig").looksBinary(out.items)) {
            out.deinit(allocator);
            self.binary = true;
            self.setErr("binary file (NUL bytes near the start) \u{2014} refusing to edit");
            return;
        }
        self.bytes = out.toOwnedSlice(allocator) catch {
            out.deinit(allocator);
            self.setErr("OutOfMemory");
            return;
        };
        // Identity from the FD the bytes came through (never a separate
        // stat, which could see a newer file than the one just read) —
        // with the permission bits filled in from a follow-stat, since a
        // read cannot report them.
        self.disk = .{
            .known = true,
            .present = true,
            .mtime_ns = info.mtime_ns,
            .size = info.size,
            .ino = info.ino,
        };
        var st: reload.DiskState = .{};
        probePath(fs, loc.path, &st) catch {};
        if (st.present) {
            self.disk.mode = st.mode;
            if (self.disk.mtime_ns == 0) self.disk.mtime_ns = st.mtime_ns;
            self.disk.mtime_ms = st.mtime_ms;
        }
        self.ok = true;
    }

    fn save(self: *IoJob, fs: *fsdrive.Fs) void {
        const loc = paths.parseSpec(self.spec);
        const res = fs.writeFileAtomic(loc.path, self.save_bytes, self.expected_mtime) catch |err| {
            if (err == fsdrive.Error.Conflict) {
                self.conflict = true;
                if (fs.lastConflict()) |ci| self.disk = .{
                    .known = true,
                    .present = true,
                    .mtime_ns = ci.mtime_ns,
                    .mtime_ms = ci.mtime_ms,
                    .size = ci.size,
                    .ino = ci.ino,
                    .mode = ci.mode,
                };
            } else {
                const detail = fs.lastErr();
                if (detail.len > 0) self.setErr(detail) else self.setErr(@errorName(err));
            }
            return;
        };
        self.disk = .{
            .known = true,
            .present = true,
            .mtime_ns = res.mtime_ns,
            .mtime_ms = res.mtime_ms,
            .size = res.size,
            .ino = res.ino,
            .mode = res.mode,
        };
        self.ok = true;
    }
};

fn ioThread(job: *IoJob) void {
    const host = paths.parseSpec(job.spec).host;
    switch (job.kind) {
        .load => withFs(host, job, IoJob.load) catch |err| job.setErr(@errorName(err)),
        .save => {
            // Never retried: see the module header.
            if (pool.acquire(host)) |lease_val| {
                var lease = lease_val;
                job.save(&lease.conn);
                pool.release(host, &lease);
            } else |err| job.setErr(@errorName(err));
        },
    }
    _ = c.g_idle_add(@ptrCast(&ioIdle), @ptrCast(job));
}

fn ioIdle(user: ?*anyopaque) callconv(.c) c.gboolean {
    const job = cast.userData(IoJob, user);
    if (job.fence.viewIfAlive()) |view| onIoDone(view, job);
    job.destroy();
    return 0;
}

pub fn startLoad(view: *EditorView, tab: *ETab) void {
    startLoadEx(view, tab, false);
}

fn startLoadEx(view: *EditorView, tab: *ETab, keep_position: bool) void {
    const spec = tab.spec orelse return;
    const a = std.heap.c_allocator;
    const job = a.create(IoJob) catch return;
    const owned = a.dupe(u8, spec) catch {
        a.destroy(job);
        return;
    };
    view.fence.ref();
    tab.io_gen = view.next_io_gen;
    view.next_io_gen += 1;
    job.* = .{
        .fence = view.fence,
        .gen = tab.io_gen,
        .kind = .load,
        .spec = owned,
        .keep_position = keep_position,
    };
    tab.loading = true;
    view.updateStatus();
    const thread = std.Thread.spawn(.{}, ioThread, .{job}) catch {
        tab.loading = false;
        tab.io_gen = 0;
        job.destroy();
        return;
    };
    thread.detach();
}

pub fn saveTab(view: *EditorView, tab: *ETab) void {
    if (tab.loading) {
        view.setStatusText("Still loading \u{2014} try again in a moment.");
        return;
    }
    if (tab.io_gen != 0) {
        view.setStatusText("A save is already in flight.");
        return;
    }
    if (tab.spec == null) {
        view.saveTabAs(tab);
        return;
    }
    editorlang.beforeSave(view, tab);
    // The guarded save IS the before-save disk check: the daemon compares
    // the baseline against the destination inside the install, which no
    // client-side poll can do race-free.
    const guard: ?i64 = if (tab.disk.present and tab.disk.mtime_ns != 0) tab.disk.mtime_ns else null;
    startSave(view, tab, guard);
}

pub fn startSave(view: *EditorView, tab: *ETab, expected_mtime: ?i64) void {
    const spec = tab.spec orelse return;
    const a = std.heap.c_allocator;
    const bytes = tab.doc.materialize(a) catch return;
    const job = a.create(IoJob) catch {
        a.free(bytes);
        return;
    };
    const owned = a.dupe(u8, spec) catch {
        a.free(bytes);
        a.destroy(job);
        return;
    };
    view.fence.ref();
    tab.io_gen = view.next_io_gen;
    view.next_io_gen += 1;
    job.* = .{
        .fence = view.fence,
        .gen = tab.io_gen,
        .kind = .save,
        .spec = owned,
        .save_bytes = bytes,
        .expected_mtime = expected_mtime,
        .revision = tab.doc.revision,
        .state = tab.doc.state(),
    };
    view.setStatusText("Saving\u{2026}");
    const thread = std.Thread.spawn(.{}, ioThread, .{job}) catch {
        tab.io_gen = 0;
        job.destroy();
        return;
    };
    thread.detach();
}

fn onIoDone(view: *EditorView, job: *IoJob) void {
    const tab = view.findTabByGen(job.gen) orelse return;
    tab.io_gen = 0;
    switch (job.kind) {
        .load => onLoadDone(view, tab, job),
        .save => onSaveDone(view, tab, job),
    }
}

fn onLoadDone(view: *EditorView, tab: *ETab, job: *IoJob) void {
    tab.loading = false;
    // A cross-file edit (rename, code action, project replace) parks its
    // hunk for a LOADING tab and the outcome line already told the user
    // it applied. So every exit below must either deliver it or say it
    // was lost — enforced here rather than remembered at four return
    // statements. The delivering paths clear `undelivered`; the
    // tab-closing ones report through their own close.
    var undelivered = true;
    const load_tab_id = tab.id; // the closing paths free `tab`
    defer if (undelivered) view.failDeferredEdits(load_tab_id, "the file could not be loaded");
    if (job.binary) {
        errorDialog(view, "Cannot edit binary file", job.errText());
        view.closeTabForce(tab);
        return;
    }
    if (!job.ok) {
        errorDialog(view, "Could not open file", job.errText());
        view.closeTabForce(tab);
        return;
    }
    if (job.not_found) {
        // New file (or an unreadable one): keep the empty document and
        // record NO baseline, so the disk probe stays silent about a file
        // we never read.
        tab.disk = .{};
        tab.keep_active = false;
        clearAlert(view, tab);
        undelivered = false;
        view.deliverDeferredEdits(tab, job.gen);
        // No document-replace rides on this branch, so the (empty, but
        // now FINAL) buffer has to be opened on the server from here —
        // `openDocument` defers while `loading` is set, which it no
        // longer is.
        if (view.lsp) |m| m.ensureOpen(tab) else view.attachLsp(tab);
        editorlang.onLoaded(view, tab, job.ec);
        view.setStatusText("New file.");
        view.refresh(tab);
        return;
    }
    if (job.keep_position and tab.keep_active) {
        finishReloadInPlace(view, tab, job);
        editorlang.onLoaded(view, tab, job.ec);
        // The document object SURVIVES a reload-in-place, so no replace
        // hook runs and this is the only place the queued edits can be
        // delivered. True even when the diff failed: the buffer is then
        // the text the server described, so the edits still fit.
        undelivered = false;
        view.deliverDeferredEdits(tab, job.gen);
        return;
    }
    const new_doc = Document.initFromBytes(view.allocator, job.bytes) catch {
        errorDialog(view, "Could not open file", "OutOfMemory");
        view.closeTabForce(tab);
        return;
    };
    view.replaceDocument(tab, new_doc);
    editorlang.onLoaded(view, tab, job.ec);
    tab.layout.invalidateAll();
    tab.rows_lines = 0;
    tab.anchor = .{};
    tab.scroll_x = 0;
    tab.max_width = 0;
    view.applyWrapWidth(tab);
    tab.disk = job.disk;
    tab.seen = job.disk;
    clearAlert(view, tab);
    {
        const caret = @min(tab.want_cursor orelse 0, tab.doc.rope.len());
        tab.want_cursor = null;
        tab.sels.keepPrimaryOnly();
        tab.sels.sels.items[0] = Selection.caret(caret);
    }
    // Deferred edits first, so the server is told about the final text
    // in one didChange rather than two.
    undelivered = false;
    view.deliverDeferredEdits(tab, job.gen);
    // The observer the swap dropped has to be re-installed and the server
    // told the content changed wholesale; a first-time load is where the
    // server is attached.
    if (view.lsp) |m| m.onDocumentReplaced(tab) else view.attachLsp(tab);
    if (tab.want_pos) |p| {
        tab.want_pos = null;
        view.applyWantPos(tab, p);
    } else if (tab.want_top_line) |top| {
        // Restored scroll: a LINE, so it survives a different pane width
        // and wrap setting. Applied only when nothing else claimed the
        // viewport.
        tab.want_top_line = null;
        const lines = tab.doc.rope.lineCount();
        tab.anchor = .{ .line = @min(top, lines -| 1), .row = 0, .offset = 0 };
    }
    tab.keep_active = false;
    // The document is new: its project may be too, and the gutter marks
    // anchored into the old byte space are gone.
    tab.git.clear();
    tab.outline.clear();
    tab.outline_rev = 0;
    editorproj.resolveProject(view, tab);
    editorproj.refreshGit(view, tab);
    editoroutline.refresh(view, tab, true);
    view.refresh(tab);
}

fn onSaveDone(view: *EditorView, tab: *ETab, job: *IoJob) void {
    if (job.conflict) {
        tab.close_after_save = false;
        // NOT a modal: the same inline banner the probe raises, so a
        // refused save and an observed change can never produce two
        // competing prompts.
        tab.seen = job.disk;
        tab.dismissed = null;
        tab.alert = .changed;
        tab.alert_from_save = true;
        updateBanner(view);
        view.setStatusText("Save refused: the file changed on disk.");
        return;
    }
    if (!job.ok) {
        tab.close_after_save = false;
        errorDialog(view, "Save failed", job.errText());
        view.updateStatus();
        return;
    }
    tab.disk = job.disk;
    tab.seen = job.disk;
    clearAlert(view, tab);
    // The history position the write snapshotted is what is on disk,
    // even when the user kept typing while it was in flight.
    tab.doc.markStateSaved(job.state, job.revision);
    editorjournal.onClean(view, tab);
    if (view.lsp) |m| m.onSaved(tab);
    editorproj.refreshGit(view, tab);
    if (tab.close_after_save) {
        tab.close_after_save = false;
        if (!tab.isDirty()) {
            view.closeTabForce(tab);
            return;
        }
    }
    view.refresh(tab);
    view.setStatusText("Saved.");
}

/// A reload that KEEPS the document: the arriving bytes are diffed onto
/// the live buffer as ONE transaction (editor/diff.zig), so undo restores
/// the pre-reload text, every edit observer (highlighter,
/// folds/git/outline anchors, LSP didChange, a11y change log) sees
/// ordinary edits, and carets/selections map through instead of
/// clamping.
fn finishReloadInPlace(view: *EditorView, tab: *ETab, job: *IoJob) void {
    tab.keep_active = false;
    const changed = ediff.reloadFromBytes(view.allocator, &tab.doc, job.bytes, &tab.sels) catch {
        // Out of memory mid-diff: the transaction applied atomically or
        // not at all, so the buffer is intact — just stale.
        view.setStatusText("Reload failed: out of memory.");
        return;
    };
    tab.disk = job.disk;
    tab.seen = job.disk;
    clearAlert(view, tab);
    editorjournal.onClean(view, tab);
    if (!changed) {
        view.refresh(tab);
        return;
    }
    // A changed line count moves the whole row estimate.
    tab.rows_lines = 0;
    // A reload only changes the language via a new shebang. The same
    // language keeps the incrementally-updated tree (the highlighter
    // observer already saw the edits) and just needs the debounced
    // re-parse; a different one swaps grammars.
    if (!std.meta.eql(view.detectLang(tab), tab.hl_lang)) {
        view.ensureHighlighter(tab);
    } else {
        view.scheduleParse(tab);
    }
    // The LSP observer captured the diff as ordinary edits, but this path
    // does not go through `afterDocEdit` — the only other caller of
    // `onEdited` — so nothing would arm the didChange debounce.
    if (view.lsp) |m| m.onEdited(tab);
    view.clampAnchor(tab, view.viewportHeightPx());
    editorproj.refreshGit(view, tab);
    editoroutline.refresh(view, tab, true);
    view.refresh(tab);
    view.setStatusText("Reloaded: the file changed on disk.");
}

fn errorDialog(view: *EditorView, heading: [*:0]const u8, detail: []const u8) void {
    var body: [200:0]u8 = undefined;
    const b = std.fmt.bufPrintZ(&body, "{s}", .{detail}) catch "unknown error";
    _ = confirm.present(view.dialogParent(), .{
        .heading = heading,
        .body = b.ptr,
        .responses = &.{
            .{ .id = "ok", .label = "OK", .is_default = true, .is_close = true },
        },
    }, null);
}

// ======================================================================
// External-change detection
// ======================================================================

/// One document's slot in a batched probe.
const ProbeItem = struct {
    tab_id: u64,
    path: []u8,
    state: reload.DiskState = .{},
    /// False when the probe could not be taken (transport failure) —
    /// which must never be reported as "the file is gone".
    ok: bool = false,
};

const ProbeJob = struct {
    fence: *Fence,
    /// Owned copy of the host part of the specs ("" = local).
    host: []u8,
    items: []ProbeItem,

    fn destroy(self: *ProbeJob) void {
        const a = std.heap.c_allocator;
        for (self.items) |it| a.free(it.path);
        a.free(self.items);
        a.free(self.host);
        self.fence.unref();
        a.destroy(self);
    }

    fn run(self: *ProbeJob, fs: *fsdrive.Fs) !void {
        for (self.items) |*it| {
            probePath(fs, it.path, &it.state) catch |err| {
                if (isTransportError(err)) return err;
                continue;
            };
            it.ok = true;
        }
    }
};

fn probeThread(job: *ProbeJob) void {
    const host: ?[]const u8 = if (job.host.len == 0) null else job.host;
    withFs(host, job, ProbeJob.run) catch {};
    _ = c.g_idle_add(@ptrCast(&probeIdle), @ptrCast(job));
}

fn probeIdle(user: ?*anyopaque) callconv(.c) c.gboolean {
    const job = cast.userData(ProbeJob, user);
    if (job.fence.viewIfAlive()) |view| onProbeDone(view, job);
    job.destroy();
    return 0;
}

/// Rate limit: focus-in storms (click, alt-tab, tab switch) must not
/// turn into a round trip each.
const PROBE_MIN_INTERVAL_MS: i64 = 400;

/// Probe every open document's file for external changes. Cheap,
/// idempotent and safe to call from any user-facing event.
pub fn checkDisk(view: *EditorView) void {
    if (view.widgets_dead) return;
    if (view.probes_in_flight > 0) return;
    const now = clock.nowMs();
    if (now - view.last_probe_ms < PROBE_MIN_INTERVAL_MS) return;
    view.last_probe_ms = now;

    const a = std.heap.c_allocator;
    var hosts: std.ArrayList([]const u8) = .empty;
    defer hosts.deinit(a);
    for (view.tabs.items) |t| {
        const spec = t.spec orelse continue;
        if (t.io_gen != 0 or t.loading) continue;
        const host = paths.parseSpec(spec).host orelse "";
        var seen = false;
        for (hosts.items) |h| {
            if (std.mem.eql(u8, h, host)) seen = true;
        }
        if (!seen) hosts.append(a, host) catch return;
    }
    for (hosts.items) |host| probeHost(view, host);
}

/// One probe job for every document on `host` — one connection, one
/// thread, N stats.
fn probeHost(view: *EditorView, host: []const u8) void {
    const a = std.heap.c_allocator;
    var items: std.ArrayList(ProbeItem) = .empty;
    defer items.deinit(a);
    for (view.tabs.items) |t| {
        const spec = t.spec orelse continue;
        if (t.io_gen != 0 or t.loading) continue;
        const loc = paths.parseSpec(spec);
        if (!std.mem.eql(u8, loc.host orelse "", host)) continue;
        const path = a.dupe(u8, loc.path) catch continue;
        items.append(a, .{ .tab_id = t.id, .path = path }) catch {
            a.free(path);
            continue;
        };
    }
    if (items.items.len == 0) return;
    const owned_items = items.toOwnedSlice(a) catch return;
    const owned_host = a.dupe(u8, host) catch {
        for (owned_items) |it| a.free(it.path);
        a.free(owned_items);
        return;
    };
    const job = a.create(ProbeJob) catch {
        for (owned_items) |it| a.free(it.path);
        a.free(owned_items);
        a.free(owned_host);
        return;
    };
    view.fence.ref();
    job.* = .{ .fence = view.fence, .host = owned_host, .items = owned_items };
    view.probes_in_flight += 1;
    const thread = std.Thread.spawn(.{}, probeThread, .{job}) catch {
        view.probes_in_flight -= 1;
        job.destroy();
        return;
    };
    thread.detach();
}

fn onProbeDone(view: *EditorView, job: *ProbeJob) void {
    if (view.probes_in_flight > 0) view.probes_in_flight -= 1;
    if (view.widgets_dead) return;
    for (job.items) |it| {
        // A probe that could not be TAKEN (dead link, unreachable host)
        // says nothing — it must never read as "deleted".
        if (!it.ok) continue;
        const tab = view.findTabById(it.tab_id) orelse continue;
        // A load/save started after the probe owns the baseline.
        if (tab.io_gen != 0 or tab.loading) continue;
        applyDiskState(view, tab, it.state);
    }
    updateBanner(view);
}

/// What one probe result means for a document.
pub const DiskAction = enum {
    /// Nothing changed (a raised banner about a reverted change drops).
    clear,
    /// Only the permission bits moved: re-baseline silently.
    rebaseline_mode,
    /// The file is gone: keep the buffer, raise the "deleted" banner.
    deleted,
    /// Changed under a clean buffer: reload quietly, keeping position.
    reload,
    /// Changed under a dirty buffer: raise the "changed" banner.
    changed,
    /// The user dismissed exactly this state already.
    ignore,
};

/// The whole external-change policy for one document, pure.
pub fn decideDiskAction(
    baseline: reload.DiskState,
    obs: reload.DiskState,
    dismissed: ?reload.DiskState,
    dirty: bool,
) DiskAction {
    return switch (reload.compare(baseline, obs)) {
        .unchanged => .clear,
        .permissions => .rebaseline_mode,
        .deleted => if (dismissed != null and reload.sameState(dismissed.?, obs)) .ignore else .deleted,
        .modified, .replaced, .reappeared => blk: {
            if (dismissed != null and reload.sameState(dismissed.?, obs)) break :blk .ignore;
            break :blk if (dirty) .changed else .reload;
        },
    };
}

/// The whole external-change state machine for one document.
fn applyDiskState(view: *EditorView, tab: *ETab, obs: reload.DiskState) void {
    tab.seen = obs;
    switch (decideDiskAction(tab.disk, obs, tab.dismissed, tab.isDirty())) {
        .ignore => {},
        .clear => {
            // Reverted underneath us: a banner about a change that is no
            // longer there is noise.
            if (tab.alert != .none) clearAlert(view, tab);
            tab.dismissed = null;
        },
        .rebaseline_mode => {
            // Content is identical; only the bits moved. Re-baseline so
            // the next save is not refused for it.
            tab.disk.mode = obs.mode;
            view.setStatusText("Permissions changed on disk.");
        },
        .deleted => {
            // Keep the content; the buffer is simply no longer backed by
            // a file, and Save recreates it (the absent baseline drops
            // the conflict guard).
            tab.disk = obs;
            tab.dismissed = null;
            tab.alert = .deleted;
            tab.alert_from_save = false;
        },
        .reload => {
            tab.dismissed = null;
            // Clean buffer: reload quietly, keeping the caret and the
            // scroll position. No prompt — that is what good editors do.
            reloadKeepingPosition(view, tab);
        },
        .changed => {
            tab.dismissed = null;
            tab.alert = .changed;
            tab.alert_from_save = false;
        },
    }
}

fn reloadKeepingPosition(view: *EditorView, tab: *ETab) void {
    tab.keep_active = true;
    startLoadEx(view, tab, true);
}

// ======================================================================
// The inline banner
// ======================================================================

/// Full-width inline banner for external file changes. Same Adwaita
/// vocabulary as the find bar ("toolbar" styling), hidden until a
/// document needs it; never a modal, because it fires while the user is
/// typing.
pub fn buildBanner(view: *EditorView) void {
    const row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6);
    c.gtk_widget_add_css_class(row, "toolbar");
    c.gtk_widget_add_css_class(row, "warning");
    c.gtk_widget_set_margin_start(row, 6);
    c.gtk_widget_set_margin_end(row, 6);
    c.gtk_widget_set_margin_top(row, 2);
    c.gtk_widget_set_margin_bottom(row, 2);
    c.gtk_widget_set_visible(row, 0);

    const icon = c.gtk_image_new_from_icon_name("dialog-warning-symbolic");
    c.gtk_box_append(@ptrCast(row), icon);

    const label = c.gtk_label_new("");
    c.gtk_label_set_xalign(@ptrCast(label), 0);
    c.gtk_label_set_wrap(@ptrCast(label), 1);
    c.gtk_widget_set_hexpand(label, 1);
    c.gtk_box_append(@ptrCast(row), label);
    view.banner_label = @ptrCast(@alignCast(label));

    const reload_btn = c.gtk_button_new_with_label("Reload");
    c.gtk_widget_set_tooltip_text(reload_btn, "Replace the buffer with the version on disk");
    _ = c.g_signal_connect_data(reload_btn, "clicked", @ptrCast(&onBannerReload), @ptrCast(view), null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(row), reload_btn);
    view.banner_reload = reload_btn.?;

    const save_btn = c.gtk_button_new_with_label("Save Anyway");
    c.gtk_widget_add_css_class(save_btn, "destructive-action");
    c.gtk_widget_set_tooltip_text(save_btn, "Write this buffer over the version on disk");
    _ = c.g_signal_connect_data(save_btn, "clicked", @ptrCast(&onBannerSave), @ptrCast(view), null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(row), save_btn);
    view.banner_save = save_btn.?;

    const dismiss = c.gtk_button_new_from_icon_name("window-close-symbolic");
    c.gtk_button_set_has_frame(@ptrCast(dismiss), 0);
    c.gtk_widget_set_tooltip_text(dismiss, "Dismiss");
    _ = c.g_signal_connect_data(dismiss, "clicked", @ptrCast(&onBannerDismiss), @ptrCast(view), null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(row), dismiss);

    view.banner_box = row.?;
}

pub fn clearAlert(view: *EditorView, tab: *ETab) void {
    tab.alert = .none;
    tab.alert_from_save = false;
    tab.dismissed = null;
    updateBanner(view);
}

/// The banner's sentence for one document's alert.
pub fn bannerText(buf: *[320:0]u8, alert: ev.Alert, from_save: bool, title: []const u8) [:0]const u8 {
    return switch (alert) {
        .none => "",
        .changed => if (from_save)
            std.fmt.bufPrintZ(buf, "Save refused: \"{s}\" changed on disk since you opened it.", .{title}) catch "The file changed on disk."
        else
            std.fmt.bufPrintZ(buf, "\"{s}\" changed on disk.", .{title}) catch "The file changed on disk.",
        .deleted => std.fmt.bufPrintZ(buf, "\"{s}\" no longer exists on disk.", .{title}) catch "The file no longer exists on disk.",
    };
}

/// Render the ACTIVE tab's alert (each document carries its own).
pub fn updateBanner(view: *EditorView) void {
    if (view.widgets_dead) return;
    const tab = view.active orelse {
        c.gtk_widget_set_visible(view.banner_box, 0);
        return;
    };
    if (tab.alert == .none) {
        c.gtk_widget_set_visible(view.banner_box, 0);
        return;
    }
    var buf: [320:0]u8 = undefined;
    const text = bannerText(&buf, tab.alert, tab.alert_from_save, tab.title());
    c.gtk_label_set_text(view.banner_label, text.ptr);
    c.gtk_widget_set_visible(view.banner_reload, if (tab.alert == .changed) 1 else 0);
    c.gtk_button_set_label(
        @ptrCast(view.banner_save),
        if (tab.alert == .deleted) "Save" else "Save Anyway",
    );
    c.gtk_widget_set_visible(view.banner_box, 1);
}

fn onBannerReload(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const view = cast.userData(EditorView, user);
    const tab = view.active orelse return;
    revertTab(view, tab);
}

/// Replace a buffer with the version on disk — the banner's "Reload",
/// reachable for any tab (the tab context menu's "Revert"). A dirty
/// buffer asks first; losing unsaved work stays behind a confirmation.
pub fn revertTab(view: *EditorView, tab: *ETab) void {
    if (tab.isDirty()) {
        confirmReloadDirty(view, tab);
        return;
    }
    clearAlert(view, tab);
    reloadKeepingPosition(view, tab);
}

fn onBannerSave(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const view = cast.userData(EditorView, user);
    const tab = view.active orelse return;
    clearAlert(view, tab);
    // Deliberate overwrite (or re-create): no conflict guard.
    startSave(view, tab, null);
}

fn onBannerDismiss(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const view = cast.userData(EditorView, user);
    const tab = view.active orelse return;
    // Stay quiet for THIS on-disk state only: a further change raises the
    // banner again, and the save baseline is untouched, so Ctrl+S is still
    // refused.
    tab.dismissed = tab.seen;
    tab.alert = .none;
    tab.alert_from_save = false;
    updateBanner(view);
}

fn confirmReloadDirty(view: *EditorView, tab: *ETab) void {
    const ctx = ev.DlgCtx.create(view, tab) orelse return;
    if (confirm.present(view.dialogParent(), .{
        .heading = "Discard your changes?",
        .body = "Reloading replaces the buffer with the on-disk version; your unsaved edits are lost.",
        .responses = &.{
            .{ .id = "cancel", .label = "Cancel", .is_default = true, .is_close = true },
            .{ .id = "reload", .label = "Discard and Reload", .appearance = .destructive },
        },
    }, .{ .allocator = view.allocator, .cb = &onReloadDirtyResponse, .ctx = @ptrCast(ctx) }) == null) ctx.destroy();
}

fn onReloadDirtyResponse(user: ?*anyopaque, resp: []const u8) void {
    const ctx: *ev.DlgCtx = @ptrCast(@alignCast(user.?));
    defer ctx.destroy();
    const r = ctx.resolve() orelse return;
    if (std.mem.eql(u8, resp, "reload")) {
        clearAlert(r.view, r.tab);
        reloadKeepingPosition(r.view, r.tab);
    }
}

// ======================================================================
// Tests
// ======================================================================

const testing = std.testing;

const FakeConn = struct {
    id: u32,
    healthy: bool = true,
    usable_flag: bool = true,
};

var fake_next: u32 = 1;
var fake_live: i32 = 0;

const FakeOps = struct {
    fn dial(_: ?[]const u8) !FakeConn {
        fake_live += 1;
        fake_next += 1;
        return .{ .id = fake_next };
    }
    fn usable(conn: *FakeConn) bool {
        return conn.usable_flag;
    }
    fn idleHealthy(conn: *FakeConn) bool {
        return conn.healthy;
    }
    fn reset(_: *FakeConn) void {}
    fn deinit(_: *FakeConn) void {
        fake_live -= 1;
    }
};

const FakePool = KeyedPool(FakeConn, FakeOps);

fn drainFake(p: *FakePool) void {
    for (p.idle.items) |*it| {
        FakeOps.deinit(&it.conn);
        p.alloc.free(it.host);
    }
    p.idle.deinit(p.alloc);
}

test "editorio pool: a released connection is reused on the same host only" {
    var p = FakePool{ .alloc = testing.allocator };
    defer drainFake(&p);
    fake_live = 0;
    var a = try p.acquire("box");
    try testing.expect(!a.reused);
    const id = a.conn.id;
    p.release("box", &a);
    try testing.expectEqual(@as(usize, 1), p.idleCount("box"));
    // Another host dials its own.
    var other = try p.acquire(null);
    try testing.expect(!other.reused);
    p.release(null, &other);
    var b = try p.acquire("box");
    try testing.expect(b.reused);
    try testing.expectEqual(id, b.conn.id);
    p.release("box", &b);
    try testing.expectEqual(@as(i32, 2), fake_live);
}

test "editorio pool: unusable and unhealthy connections are never handed out" {
    var p = FakePool{ .alloc = testing.allocator };
    defer drainFake(&p);
    fake_live = 0;
    var a = try p.acquire("box");
    a.conn.usable_flag = false;
    p.release("box", &a);
    try testing.expectEqual(@as(usize, 0), p.idleCount("box"));
    try testing.expectEqual(@as(i32, 0), fake_live);

    var b = try p.acquire("box");
    b.conn.healthy = false;
    p.release("box", &b);
    var c2 = try p.acquire("box");
    // The sick idle one was closed, not reused.
    try testing.expect(!c2.reused);
    p.release("box", &c2);
    try testing.expectEqual(@as(i32, 1), fake_live);
}

test "editorio pool: idle connections are capped per host" {
    var p = FakePool{ .alloc = testing.allocator };
    defer drainFake(&p);
    fake_live = 0;
    var leases: [POOL_IDLE_PER_HOST + 2]FakePool.Lease = undefined;
    for (&leases) |*l| l.* = try p.acquire("box");
    for (&leases) |*l| p.release("box", l);
    try testing.expectEqual(POOL_IDLE_PER_HOST, p.idleCount("box"));
    try testing.expectEqual(@as(i32, POOL_IDLE_PER_HOST), fake_live);
}

test "editorio: the external-change policy" {
    const base = reload.DiskState{ .known = true, .present = true, .mtime_ns = 10, .size = 4, .ino = 7, .mode = 0o644 };
    var moved = base;
    moved.mtime_ns = 20;
    moved.size = 5;
    const gone = reload.DiskState{ .known = true, .present = false };
    var chmod = base;
    chmod.mode = 0o600;
    try testing.expectEqual(DiskAction.clear, decideDiskAction(base, base, null, true));
    try testing.expectEqual(DiskAction.reload, decideDiskAction(base, moved, null, false));
    try testing.expectEqual(DiskAction.changed, decideDiskAction(base, moved, null, true));
    try testing.expectEqual(DiskAction.ignore, decideDiskAction(base, moved, moved, true));
    try testing.expectEqual(DiskAction.deleted, decideDiskAction(base, gone, null, false));
    try testing.expectEqual(DiskAction.rebaseline_mode, decideDiskAction(base, chmod, null, true));
}

test "editorio: banner sentences name the document" {
    var buf: [320:0]u8 = undefined;
    try testing.expectEqualStrings("\"a.zig\" changed on disk.", bannerText(&buf, .changed, false, "a.zig"));
    try testing.expectEqualStrings(
        "Save refused: \"a.zig\" changed on disk since you opened it.",
        bannerText(&buf, .changed, true, "a.zig"),
    );
    try testing.expectEqualStrings("\"a.zig\" no longer exists on disk.", bannerText(&buf, .deleted, false, "a.zig"));
}
