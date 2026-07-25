//! Preview pane, Quick Look overlay and thumbnails.
//!
//! Nothing here ever blocks the GLib loop: local probe/decode/save
//! runs on a worker thread; remote thumbnails ride the nonblocking fs
//! wire (read the HOST's cache, else fetch source bytes, encode on the
//! worker, write the PNG BACK to the host's cache so it is shared with
//! that machine's own apps).
//!
//! The side panel and the Quick Look overlay are two views of ONE
//! pipeline: `previewers.resolve` picks a handler for the entry, one
//! `PreviewRead` fetches it over the fs wire, the result lands in a
//! bounded cache and is painted into whichever of the two is live.
//! A user handler's `host <command>` needs no new daemon verb: the
//! daemon already runs an arbitrary host-side command as a job
//! (`panelize`) and already serves ranged reads, so a previewer is
//! exactly "run this there, then read what it made".

const std = @import("std");
const c = @import("../../c.zig").c;
const wire = @import("../../mux/wire.zig");
const hexdump = @import("../../filebrowser/hexdump.zig");
const previewers = @import("../../filebrowser/previewers.zig");
const thumbs_mod = @import("../../filebrowser/thumbs.zig");

const BTab = @import("types.zig").BTab;
const BrowserView = @import("view.zig").BrowserView;
const Entry = @import("types.zig").Entry;
const HostConn = @import("types.zig").HostConn;
const WireJobEv = @import("types.zig").WireJobEv;
const WireReply = @import("types.zig").WireReply;
const entryForPath = @import("nav.zig").entryForPath;
const fmtModeZ = @import("../../filebrowser/format.zig").fmtModeZ;
const fmtSize = @import("../../filebrowser/format.zig").fmtSize;
const fmtTimeZ = @import("../../filebrowser/format.zig").fmtTimeZ;
const guessMime = @import("open.zig").guessMime;
const isImageName = @import("../../filebrowser/paths.zig").isImageName;
const isPreviewMediaName = @import("../../filebrowser/paths.zig").isPreviewMediaName;
const isWorkerImageName = @import("../../filebrowser/paths.zig").isWorkerImageName;

/// Shared context between a BrowserView and its thumbnail worker
/// thread. Refcounted: the thread holds one ref, every in-flight
/// idle handback holds one; the view's deinit orphans it so late
/// results are dropped, never applied to a dead view.
pub const ThumbCtx = struct {
    view: *BrowserView,
    /// pthread via libc: Zig 0.16 std.Thread has no Mutex.
    mutex: c.pthread_mutex_t = undefined,
    cond: c.pthread_cond_t = undefined,
    queue: std.ArrayList(ThumbReq) = .empty,
    shutdown: bool = false,
    orphaned: bool = false,
    refs: u32 = 1,
    /// LOCAL cache dir (owned, c_allocator).
    cache_dir: []u8,

    pub fn lock(self: *ThumbCtx) void {
        _ = c.pthread_mutex_lock(&self.mutex);
    }
    pub fn unlock(self: *ThumbCtx) void {
        _ = c.pthread_mutex_unlock(&self.mutex);
    }

    pub fn ref(self: *ThumbCtx) void {
        self.lock();
        defer self.unlock();
        self.refs += 1;
    }

    pub fn unref(self: *ThumbCtx) void {
        self.lock();
        self.refs -= 1;
        const dead = self.refs == 0;
        self.unlock();
        if (dead) {
            const a = std.heap.c_allocator;
            for (self.queue.items) |*q| q.deinitReq();
            self.queue.deinit(a);
            a.free(self.cache_dir);
            _ = c.pthread_mutex_destroy(&self.mutex);
            _ = c.pthread_cond_destroy(&self.cond);
            a.destroy(self);
        }
    }
};

/// What a decode is for: a 128px row icon or a large preview image.
pub const ThumbKind = enum { row_thumb, preview };

/// One worker task: probe/generate a LOCAL thumbnail, or decode
/// remote SOURCE bytes into a spec-compliant thumbnail PNG.
pub const ThumbReq = struct {
    /// Absolute path on its OWNING host (key material).
    path: []u8,
    mtime_ms: i64,
    /// Remote-source bytes to decode (null = local file probe).
    data: ?[]u8 = null,
    /// Viewer-memory identity includes host; disk identity deliberately
    /// remains path-only because each host owns a separate cache.
    cache_key: []u8,
    cached_png: bool = false,
    kind: ThumbKind = .row_thumb,
    /// The view generation allowed to DISPLAY this result; 0 means
    /// cache-only (a preload must never paint over a newer selection).
    preview_generation: u64 = 0,
    remote_id: u64 = 0,

    pub fn deinitReq(self: *ThumbReq) void {
        const a = std.heap.c_allocator;
        a.free(self.path);
        a.free(self.cache_key);
        if (self.data) |d| a.free(d);
    }
};

/// Worker -> main-thread handback.
pub const ThumbResult = struct {
    ctx: *ThumbCtx,
    /// In-memory cache key ("path\x00mtime", owned by c_allocator).
    key: []u8,
    pixbuf: ?*c.GdkPixbuf,
    /// Spec PNG bytes for remote write-back (owned, c_allocator).
    png: ?[]u8 = null,
    /// Original path (owned) — locates the remote write-back target.
    path: []u8,
    mtime_ms: i64,
    kind: ThumbKind = .row_thumb,
    preview_generation: u64 = 0,
    remote_id: u64 = 0,
};

/// One remote thumbnail fetch in flight (serial per view).
pub const RemoteThumb = struct {
    id: u64,
    hc: *HostConn,
    path: []u8,
    mtime_ms: i64,
    phase: enum { start_job, wait_job, read_thumb } = .start_job,
    req: u32 = 0,
    job: u64 = 0,
    buf: std.ArrayList(u8) = .empty,

    pub fn destroy(self: *RemoteThumb, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.buf.deinit(allocator);
        allocator.destroy(self);
    }
};

/// One in-flight preview fetch (chunked fs read, optionally behind a
/// generator job). The same struct serves the foreground target and
/// the preloader; `preload` decides whether its result may paint.
pub const PreviewRead = struct {
    req: u32,
    hc: *HostConn,
    /// Source file on `hc`'s host (owned).
    path: []u8,
    /// Cache identity, "host\x00path\x00mtime" (owned).
    key: []u8,
    /// Host-side scratch file to unlink once read (owned; empty for
    /// producers that read the source or the thumbnail cache).
    temp: []u8 = &.{},
    output: previewers.Output,
    /// Always render as hex, whatever the bytes look like.
    force_hex: bool = false,
    preload: bool,
    /// Generation allowed to paint this result; 0 for a preload.
    generation: u64,
    /// `job_start` waits for the id, `job_wait` for its events,
    /// `read_file` streams the bytes to show.
    phase: enum { job_start, job_wait, read_file } = .job_start,
    job: u64 = 0,
    /// Metadata the generator reported alongside its image (owned).
    note: []u8 = &.{},
    buf: std.ArrayList(u8) = .empty,

    pub fn destroy(self: *PreviewRead, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.key);
        if (self.temp.len > 0) allocator.free(self.temp);
        if (self.note.len > 0) allocator.free(self.note);
        self.buf.deinit(allocator);
        allocator.destroy(self);
    }
};

/// One finished preview, kept so arrowing back is instant. Exactly
/// one of `texture`/`text` is set unless the fetch failed, in which
/// case `note` carries the honest reason.
pub const CacheItem = struct {
    key: []u8,
    texture: ?*c.GdkTexture = null,
    text: ?[]u8 = null,
    note: ?[]u8 = null,
    failed: bool = false,
    /// The text is a hex dump: its columns only line up unwrapped.
    hex: bool = false,

    /// A generator's metadata is parked under the key before its
    /// image finishes decoding; until then the entry is not yet a
    /// cache HIT, or arrowing back would show the note alone forever.
    fn complete(self: *const CacheItem) bool {
        return self.failed or self.texture != null or self.text != null;
    }

    fn deinit(self: *CacheItem, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        if (self.texture) |t| c.g_object_unref(@ptrCast(t));
        if (self.text) |s| allocator.free(s);
        if (self.note) |s| allocator.free(s);
    }
};

/// One queued neighbour to warm.
pub const PreloadItem = struct {
    hc: *HostConn,
    path: []u8,
    key: []u8,
    mtime_ms: i64,

    fn deinit(self: *PreloadItem, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.key);
    }
};

/// Everything the preview feature owns beyond the side panel's
/// widgets. One BrowserView field instead of a scalar per concern.
pub const State = struct {
    /// User previewer rules, loaded on first use.
    rules: ?previewers.Rules = null,
    cache: std.ArrayList(CacheItem) = .empty,
    /// Neighbours still to warm (bounded by PRELOAD_QUEUE_CAP).
    preload_queue: std.ArrayList(PreloadItem) = .empty,
    /// The one preload fetch in flight, behind the foreground one.
    preload_read: ?*PreviewRead = null,
    ql: ?*QuickLook = null,
    /// Nonce source for host-side scratch file names.
    temp_seq: u64 = 0,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (self.ql) |ql| ql.destroy();
        if (self.preload_read) |pr| pr.destroy(allocator);
        for (self.preload_queue.items) |*it| it.deinit(allocator);
        self.preload_queue.deinit(allocator);
        for (self.cache.items) |*it| it.deinit(allocator);
        self.cache.deinit(allocator);
        if (self.rules) |*r| r.deinit();
    }

    fn cacheFind(self: *State, key: []const u8) ?*CacheItem {
        for (self.cache.items) |*it| {
            if (std.mem.eql(u8, it.key, key)) return it;
        }
        return null;
    }

    /// Insert (replacing any same-key entry), dropping the oldest
    /// once the cache is full. Takes ownership of `item`.
    /// @return the stored entry, or null when it could not be kept
    /// (the item is released in that case).
    fn cachePut(self: *State, allocator: std.mem.Allocator, item: CacheItem) ?*CacheItem {
        if (self.cacheFind(item.key)) |old| {
            var replaced = old.*;
            replaced.deinit(allocator);
            old.* = item;
            return old;
        }
        if (self.cache.items.len >= PREVIEW_CACHE_CAP) {
            var oldest = self.cache.orderedRemove(0);
            oldest.deinit(allocator);
        }
        self.cache.append(allocator, item) catch {
            var dead = item;
            dead.deinit(allocator);
            return null;
        };
        return &self.cache.items[self.cache.items.len - 1];
    }
};

/// Content caps: whole image (bounded) vs a text head.
pub const PREVIEW_IMAGE_CAP: usize = 8 << 20;

pub const PREVIEW_TEXT_CAP: usize = 4096;

/// Bytes fetched for the head/hex producers.
pub const PREVIEW_HEAD_CAP: u64 = 4096;

/// Finished previews kept in memory. Small on purpose: each image
/// entry holds a decoded texture.
pub const PREVIEW_CACHE_CAP: usize = 12;

/// Fixed lookahead around the current entry. The inventory's number
/// one remote pain point is thumbnail storms, so this never grows
/// with the directory: at most PRELOAD_QUEUE_CAP entries are queued
/// and exactly one is fetched at a time, behind the foreground read.
pub const PRELOAD_BEHIND: usize = 1;

pub const PRELOAD_AHEAD: usize = 2;

pub const PRELOAD_QUEUE_CAP: usize = PRELOAD_BEHIND + PRELOAD_AHEAD;

/// Row thumbnails decode local images up to this size.
pub const THUMB_FILE_CAP: u64 = 8 << 20;

pub const THUMB_CACHE_CAP: usize = 256;

pub fn ensureThumbWorker(self: *BrowserView) ?*ThumbCtx {
    if (self.thumb_ctx) |tc| return tc;
    const a = std.heap.c_allocator;
    const cache_root = c.g_get_user_cache_dir();
    const cd = std.mem.span(@as([*:0]const u8, @ptrCast(cache_root)));
    const tc = a.create(ThumbCtx) catch return null;
    tc.* = .{
        .view = self,
        .refs = 2, // worker thread + this view
        .cache_dir = a.dupe(u8, cd) catch {
            a.destroy(tc);
            return null;
        },
    };
    _ = c.pthread_mutex_init(&tc.mutex, null);
    _ = c.pthread_cond_init(&tc.cond, null);
    const th = std.Thread.spawn(.{}, thumbWorkerMain, .{tc}) catch {
        a.free(tc.cache_dir);
        a.destroy(tc);
        return null;
    };
    th.detach();
    self.thumb_ctx = tc;
    return tc;
}

pub fn thumbWorkerMain(tc: *ThumbCtx) void {
    defer tc.unref();
    while (true) {
        tc.lock();
        while (tc.queue.items.len == 0 and !tc.shutdown)
            _ = c.pthread_cond_wait(&tc.cond, &tc.mutex);
        if (tc.shutdown) {
            tc.unlock();
            return;
        }
        var req = tc.queue.orderedRemove(0);
        tc.unlock();
        thumbProcess(tc, &req);
        req.deinitReq();
    }
}

/// Worker-side: probe the freedesktop cache, else decode +
/// save (local) / encode for write-back (remote bytes).
pub fn thumbProcess(tc: *ThumbCtx, req: *ThumbReq) void {
    const a = std.heap.c_allocator;
    var pixbuf: ?*c.GdkPixbuf = null;
    var png_out: ?[]u8 = null;

    var ubuf: [4096 * 3 + 8]u8 = undefined;
    const uri = thumbs_mod.fileUri(req.path, &ubuf) orelse return;
    var mstr: [24:0]u8 = undefined;
    const msec = std.fmt.bufPrintZ(&mstr, "{d}", .{@divTrunc(req.mtime_ms, 1000)}) catch return;

    if (req.data == null) {
        // LOCAL: cached thumbnail first (validated by MTime).
        var tp_buf: [4300:0]u8 = undefined;
        const tp = thumbs_mod.thumbPath(tc.cache_dir, req.path, tp_buf[0 .. tp_buf.len - 1]) orelse return;
        tp_buf[tp.len] = 0;
        if (c.gdk_pixbuf_new_from_file(&tp_buf, null)) |cached| {
            const mt = c.gdk_pixbuf_get_option(cached, "tEXt::Thumb::MTime");
            const ur = c.gdk_pixbuf_get_option(cached, "tEXt::Thumb::URI");
            if (mt != null and ur != null and std.mem.eql(u8, std.mem.span(mt), msec) and std.mem.eql(u8, std.mem.span(ur), uri)) {
                pixbuf = cached;
            } else {
                c.g_object_unref(cached);
            }
        }
        if (pixbuf == null) {
            var pz: [4300:0]u8 = undefined;
            const pp = std.fmt.bufPrintZ(&pz, "{s}", .{req.path}) catch return;
            pixbuf = c.gdk_pixbuf_new_from_file_at_size(pp.ptr, 128, 128, null);
            if (pixbuf != null) thumbSaveLocal(tc, pixbuf.?, &tp_buf, tp.len, uri, msec);
        }
    } else {
        // Wire-delivered PNG/source bytes: all decode/scale work
        // stays on this worker, never in the fd callback.
        const loader = c.gdk_pixbuf_loader_new();
        var loaded = false;
        if (c.gdk_pixbuf_loader_write(loader, req.data.?.ptr, req.data.?.len, null) != 0)
            loaded = c.gdk_pixbuf_loader_close(loader, null) != 0
        else
            _ = c.gdk_pixbuf_loader_close(loader, null);
        if (loaded) {
            if (c.gdk_pixbuf_loader_get_pixbuf(loader)) |full| {
                const w: f64 = @floatFromInt(c.gdk_pixbuf_get_width(full));
                const h: f64 = @floatFromInt(c.gdk_pixbuf_get_height(full));
                const bound: f64 = if (req.kind == .preview) 480.0 else 128.0;
                const scale = @max(w / bound, h / bound);
                const nw: c_int = if (scale > 1) @intFromFloat(@max(1.0, w / scale)) else @intFromFloat(w);
                const nh: c_int = if (scale > 1) @intFromFloat(@max(1.0, h / scale)) else @intFromFloat(h);
                pixbuf = c.gdk_pixbuf_scale_simple(full, nw, nh, c.GDK_INTERP_BILINEAR);
            }
        }
        c.g_object_unref(loader); // drops `full` with it
        if (pixbuf) |pb| if (!req.cached_png and req.kind == .row_thumb) {
            var uz: [4096 * 3 + 8:0]u8 = undefined;
            @memcpy(uz[0..uri.len], uri);
            uz[uri.len] = 0;
            var out_buf: [*c]u8 = null;
            var out_len: usize = 0;
            if (c.gdk_pixbuf_save_to_buffer(pb, &out_buf, &out_len, "png", null, "tEXt::Thumb::URI", &uz, "tEXt::Thumb::MTime", msec.ptr, @as(?*anyopaque, null)) != 0) {
                png_out = a.dupe(u8, out_buf[0..out_len]) catch null;
                c.g_free(out_buf);
            }
        };
    }

    // Hand the result to the main thread.
    const key = std.fmt.allocPrint(a, "{s}\x00{d}", .{ req.cache_key, req.mtime_ms }) catch {
        if (pixbuf) |pb| c.g_object_unref(pb);
        if (png_out) |pg| a.free(pg);
        return;
    };
    const res = a.create(ThumbResult) catch {
        a.free(key);
        if (pixbuf) |pb| c.g_object_unref(pb);
        if (png_out) |pg| a.free(pg);
        return;
    };
    res.* = .{
        .ctx = tc,
        .key = key,
        .pixbuf = pixbuf,
        .png = png_out,
        .path = a.dupe(u8, req.path) catch {
            a.free(key);
            a.destroy(res);
            if (pixbuf) |pb| c.g_object_unref(pb);
            if (png_out) |pg| a.free(pg);
            return;
        },
        .mtime_ms = req.mtime_ms,
        .kind = req.kind,
        .preview_generation = req.preview_generation,
        .remote_id = req.remote_id,
    };
    tc.ref();
    _ = c.g_idle_add(@ptrCast(&onThumbIdle), @ptrCast(res));
}

/// Worker-side spec save: dirs 700, temp file in place, PNG with
/// URI/MTime tEXt chunks, chmod 600, atomic rename.
pub fn thumbSaveLocal(tc: *ThumbCtx, pb: *c.GdkPixbuf, tp_buf: *[4300:0]u8, tp_len: usize, uri: []const u8, msec: [:0]const u8) void {
    var dbuf: [4300]u8 = undefined;
    const dir1 = std.fmt.bufPrint(&dbuf, "{s}/thumbnails", .{tc.cache_dir}) catch return;
    var z: [4300:0]u8 = undefined;
    if (std.fmt.bufPrintZ(&z, "{s}", .{dir1})) |d1| {
        _ = c.mkdir(d1.ptr, 0o700);
    } else |_| return;
    if (std.fmt.bufPrintZ(&z, "{s}/normal", .{dir1})) |d2| {
        _ = c.mkdir(d2.ptr, 0o700);
    } else |_| return;
    var tmp: [4320:0]u8 = undefined;
    const tmps = std.fmt.bufPrintZ(&tmp, "{s}.sketerm-tmp-{x}", .{ tp_buf[0..tp_len], @intFromPtr(tc) }) catch return;
    var uz: [4096 * 3 + 8:0]u8 = undefined;
    @memcpy(uz[0..uri.len], uri);
    uz[uri.len] = 0;
    if (c.gdk_pixbuf_save(pb, tmps.ptr, "png", null, "tEXt::Thumb::URI", &uz, "tEXt::Thumb::MTime", msec.ptr, @as(?*anyopaque, null)) == 0) return;
    _ = c.chmod(tmps.ptr, 0o600);
    _ = c.rename(tmps.ptr, tp_buf);
}

pub fn onThumbIdle(user: ?*anyopaque) callconv(.c) c.gboolean {
    const res: *ThumbResult = @ptrCast(@alignCast(user.?));
    const a = std.heap.c_allocator;
    const tc = res.ctx;
    defer {
        a.free(res.key);
        a.free(res.path);
        if (res.png) |pg| a.free(pg);
        a.destroy(res);
        tc.unref();
    }
    tc.lock();
    const orphaned = tc.orphaned;
    tc.unlock();
    if (orphaned) {
        if (res.pixbuf) |pb| c.g_object_unref(pb);
        return 0;
    }
    const self = tc.view;
    self.applyThumbResult(res);
    return 0;
}

pub fn applyThumbResult(self: *BrowserView, res: *ThumbResult) void {
    if (res.kind == .preview) {
        defer if (res.pixbuf) |pb| c.g_object_unref(pb);
        storePreviewImage(self, res);
        // The decode was the last step of a fetch; the next
        // neighbour may start now.
        self.pumpPreload();
        return;
    }
    if (res.pixbuf) |pb| {
        defer c.g_object_unref(pb);
        const tex = c.gdk_texture_new_for_pixbuf(pb) orelse return;
        if (self.thumbs.count() >= THUMB_CACHE_CAP) self.clearThumbCache();
        const owned = self.allocator.dupe(u8, res.key) catch {
            c.g_object_unref(@as(?*anyopaque, @ptrCast(tex)));
            return;
        };
        self.thumbs.put(owned, tex) catch {
            self.allocator.free(owned);
            c.g_object_unref(@as(?*anyopaque, @ptrCast(tex)));
            return;
        };
        // Remote result: write the PNG back into the OWNING
        // host's cache (best-effort, req 0 = replies ignored).
        if (res.png) |png| self.thumbWriteBack(res.remote_id, res.path, png);
        self.scheduleThumbRender();
    } else {
        if (self.thumb_failed.count() >= THUMB_CACHE_CAP) {
            var it = self.thumb_failed.iterator();
            while (it.next()) |kv| self.allocator.free(kv.key_ptr.*);
            self.thumb_failed.clearRetainingCapacity();
        }
        const owned = self.allocator.dupe(u8, res.key) catch return;
        self.thumb_failed.put(owned, {}) catch self.allocator.free(owned);
    }
    // A remote decode holds the pipeline slot until now.
    self.releaseRemoteThumbFor(res.remote_id);
}

/// Push a generated thumbnail PNG into the owning host's
/// freedesktop cache over the fs wire (mkdirs + write + rename;
/// all best-effort with ignored replies).
pub fn thumbWriteBack(self: *BrowserView, remote_id: u64, path: []const u8, png: []const u8) void {
    // The path's host is the CURRENT remote pipeline's host.
    const rt = self.remote_thumb orelse return;
    if (remote_id == 0 or rt.id != remote_id or !std.mem.eql(u8, rt.path, path)) return;
    const hc = rt.hc;
    if (hc.state != .ready) return;
    const cache = hc.cache_dir orelse return;
    var tbuf: [4300]u8 = undefined;
    const tp = thumbs_mod.thumbPath(cache, path, &tbuf) orelse return;
    var dbuf: [4300]u8 = undefined;
    if (std.fmt.bufPrint(&dbuf, "{s}/thumbnails", .{cache})) |d| {
        self.sendOp(hc, .{ .req = @as(u32, 0), .op = "mkdir", .path = d });
    } else |_| {}
    if (std.fmt.bufPrint(&dbuf, "{s}/thumbnails/normal", .{cache})) |d| {
        self.sendOp(hc, .{ .req = @as(u32, 0), .op = "mkdir", .path = d });
    } else |_| {}
    var tmpb: [4340]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tmpb, "{s}.sketerm-tmp", .{tp}) catch return;
    // fs_write frame: [u32 req][u64 off][u8 flags][u16 len][path][data]
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(self.allocator);
    var hdr: [15]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], 0, .little);
    std.mem.writeInt(u64, hdr[4..12], 0, .little);
    hdr[12] = 0b011; // create + truncate
    std.mem.writeInt(u16, hdr[13..15], @intCast(tmp.len), .little);
    payload.appendSlice(self.allocator, &hdr) catch return;
    payload.appendSlice(self.allocator, tmp) catch return;
    payload.appendSlice(self.allocator, png) catch return;
    hc.conn.sendFrame(.fs_write, payload.items) catch return;
    self.sendOp(hc, .{ .req = @as(u32, 0), .op = "rename", .path = tmp, .to = tp });
}

/// Coalesced re-render ~8x/s while thumbnails trickle in.
pub fn scheduleThumbRender(self: *BrowserView) void {
    if (self.thumb_render_src != 0) return;
    self.thumb_render_src = c.g_timeout_add(120, @ptrCast(&onThumbRenderTick), @ptrCast(self));
}

pub fn onThumbRenderTick(user: ?*anyopaque) callconv(.c) c.gboolean {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    self.thumb_render_src = 0;
    self.renderCurrent();
    return 0; // one-shot
}

/// The render-time lookup: cached texture, or a queued async
/// request (local worker / remote pipeline) and null for now.
pub fn thumbLookup(self: *BrowserView, hc: *HostConn, full: []const u8, e: Entry) ?*c.GdkTexture {
    if (!std.mem.eql(u8, e.kind, "file") or !isPreviewMediaName(e.name)) return null;
    if (isImageName(e.name) and e.size > THUMB_FILE_CAP) return null;
    var identity_buf: [4600]u8 = undefined;
    const identity = if (hc.host) |host|
        std.fmt.bufPrint(&identity_buf, "{s}:{s}", .{ host, full }) catch return null
    else
        full;
    var key_buf: [4700]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "{s}\x00{d}", .{ identity, e.mtime_ms }) catch return null;
    if (self.thumbs.get(key)) |t| return t;
    if (self.thumb_failed.contains(key)) return null;
    if (hc.host == null and isWorkerImageName(e.name)) {
        const tc = self.ensureThumbWorker() orelse return null;
        const a = std.heap.c_allocator;
        tc.lock();
        defer tc.unlock();
        for (tc.queue.items) |q| {
            if (std.mem.eql(u8, q.path, full)) return null; // queued
        }
        if (tc.queue.items.len > 512) return null; // bounded
        const owned = a.dupe(u8, full) catch return null;
        const cache_key = a.dupe(u8, full) catch { a.free(owned); return null; };
        tc.queue.append(a, .{ .path = owned, .cache_key = cache_key, .mtime_ms = e.mtime_ms }) catch {
            a.free(owned);
            a.free(cache_key);
            return null;
        };
        _ = c.pthread_cond_signal(&tc.cond);
    } else {
        self.enqueueRemoteThumb(hc, full, e.mtime_ms);
    }
    return null;
}

pub fn enqueueRemoteThumb(self: *BrowserView, hc: *HostConn, path: []const u8, mtime_ms: i64) void {
    if (self.remote_thumb) |rt| {
        if (rt.hc == hc and std.mem.eql(u8, rt.path, path)) return;
    }
    for (self.remote_thumb_queue.items) |rt| {
        if (rt.hc == hc and std.mem.eql(u8, rt.path, path)) return;
    }
    if (self.remote_thumb_queue.items.len > 128) return;
    const rt = self.allocator.create(RemoteThumb) catch return;
    const id = self.next_remote_thumb_id;
    self.next_remote_thumb_id +%= 1;
    if (self.next_remote_thumb_id == 0) self.next_remote_thumb_id = 1;
    rt.* = .{
        .id = id,
        .hc = hc,
        .path = self.allocator.dupe(u8, path) catch {
            self.allocator.destroy(rt);
            return;
        },
        .mtime_ms = mtime_ms,
    };
    self.remote_thumb_queue.append(self.allocator, rt) catch {
        rt.destroy(self.allocator);
        return;
    };
    self.pumpRemoteThumbs();
}

pub fn pumpRemoteThumbs(self: *BrowserView) void {
    if (self.remote_thumb != null) return;
    while (self.remote_thumb_queue.items.len > 0) {
        const rt = self.remote_thumb_queue.orderedRemove(0);
        if (rt.hc.state != .ready) {
            rt.destroy(self.allocator);
            continue;
        }
        rt.req = self.nextReq();
        rt.phase = .start_job;
        self.remote_thumb = rt;
        // Generation happens on the file-owning host. Only the
        // bounded cached PNG returns over the wire.
        self.sendOp(rt.hc, .{ .req = rt.req, .op = "thumbnail", .path = rt.path });
        return;
    }
}

pub fn finishRemoteThumb(self: *BrowserView) void {
    if (self.remote_thumb) |rt| {
        rt.destroy(self.allocator);
        self.remote_thumb = null;
    }
    self.pumpRemoteThumbs();
}

/// Feed frames into the remote-thumbnail pipeline.
pub fn feedRemoteThumb(self: *BrowserView, hc: *HostConn, ftype: wire.FrameType, payload: []const u8) bool {
    const rt = self.remote_thumb orelse return false;
    if (rt.hc != hc) return false;
    switch (ftype) {
        .fs_data => {
            if (payload.len < 12) return false;
            if (std.mem.readInt(u32, payload[0..4], .little) != rt.req) return false;
            rt.buf.appendSlice(self.allocator, payload[12..]) catch {};
            return true;
        },
        .fs_reply => {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const rep = std.json.parseFromSliceLeaky(WireReply, arena.allocator(), payload, .{
                .ignore_unknown_fields = true,
            }) catch return false;
            if (rep.req != rt.req) return false;
            switch (rt.phase) {
                .start_job => {
                    if (!rep.ok or rep.job == 0) {
                        self.markThumbFailed(rt.hc, rt.path, rt.mtime_ms);
                        self.finishRemoteThumb();
                        return true;
                    }
                    rt.job = rep.job;
                    rt.phase = .wait_job;
                    return true;
                },
                .read_thumb => {
                    if (!rep.ok or rt.buf.items.len == 0) {
                        self.markThumbFailed(rt.hc, rt.path, rt.mtime_ms);
                        self.finishRemoteThumb();
                        return true;
                    }
                    self.queueRemoteDecode(rt, true);
                    self.finishRemoteThumbKeepCurrent();
                    return true;
                },
                .wait_job => return false,
            }
        },
        .fs_job => {
            if (rt.phase != .wait_job) return false;
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const ev = std.json.parseFromSliceLeaky(WireJobEv, arena.allocator(), payload, .{ .ignore_unknown_fields = true }) catch return false;
            if (ev.job != rt.job) return false;
            if (std.mem.eql(u8, ev.ev, "done") and ev.path.len > 0) {
                rt.req = self.nextReq();
                rt.phase = .read_thumb;
                rt.buf.clearRetainingCapacity();
                self.sendOp(rt.hc, .{ .req = rt.req, .op = "read", .path = ev.path, .off = @as(u64, 0), .len = @as(u64, 2 << 20) });
            } else if (std.mem.eql(u8, ev.ev, "error") or std.mem.eql(u8, ev.ev, "canceled")) {
                self.markThumbFailed(rt.hc, rt.path, rt.mtime_ms);
                self.finishRemoteThumb();
            }
            return true;
        },
        else => return false,
    }
}

/// Source bytes arrived: hand them to the worker for decode +
/// spec-PNG encode (write-back happens when the result lands).
pub fn queueRemoteDecode(self: *BrowserView, rt: *RemoteThumb, cached_png: bool) void {
    const tc = self.ensureThumbWorker() orelse return;
    const a = std.heap.c_allocator;
    const path = a.dupe(u8, rt.path) catch return;
    const key = if (rt.hc.host) |host|
        std.fmt.allocPrint(a, "{s}:{s}", .{ host, rt.path }) catch { a.free(path); return; }
    else
        a.dupe(u8, rt.path) catch { a.free(path); return; };
    const data = a.dupe(u8, rt.buf.items) catch {
        a.free(path);
        a.free(key);
        return;
    };
    tc.lock();
    defer tc.unlock();
    tc.queue.append(a, .{ .path = path, .cache_key = key, .mtime_ms = rt.mtime_ms, .data = data, .cached_png = cached_png, .remote_id = rt.id }) catch {
        a.free(path);
        a.free(key);
        a.free(data);
        return;
    };
    _ = c.pthread_cond_signal(&tc.cond);
}

/// Advance the queue but KEEP self.remote_thumb until the worker
/// result lands (thumbWriteBack needs its host + path).
pub fn finishRemoteThumbKeepCurrent(self: *BrowserView) void {
    // The worker handback frees it via releaseRemoteThumbFor.
    _ = self;
}

pub fn releaseRemoteThumbFor(self: *BrowserView, remote_id: u64) void {
    if (remote_id == 0) return;
    if (self.remote_thumb) |rt| {
        if (rt.id == remote_id) {
            rt.destroy(self.allocator);
            self.remote_thumb = null;
            self.pumpRemoteThumbs();
        }
    }
}

pub fn markThumbFailed(self: *BrowserView, hc: *HostConn, path: []const u8, mtime_ms: i64) void {
    var identity_buf: [4600]u8 = undefined;
    const identity = if (hc.host) |host|
        std.fmt.bufPrint(&identity_buf, "{s}:{s}", .{ host, path }) catch return
    else
        path;
    var key_buf: [4300]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "{s}\x00{d}", .{ identity, mtime_ms }) catch return;
    const owned = self.allocator.dupe(u8, key) catch return;
    self.thumb_failed.put(owned, {}) catch self.allocator.free(owned);
}

pub fn clearThumbCache(self: *BrowserView) void {
    var it = self.thumbs.iterator();
    while (it.next()) |kv| {
        c.g_object_unref(@ptrCast(kv.value_ptr.*));
        self.allocator.free(kv.key_ptr.*);
    }
    self.thumbs.clearRetainingCapacity();
}

// ── the preview pipeline (side panel + Quick Look) ──────────────

pub fn clearPreviewContent(self: *BrowserView) void {
    c.gtk_picture_set_paintable(@ptrCast(self.preview_pic), null);
    c.gtk_label_set_text(self.preview_text, "");
    if (self.preview_state.ql) |ql| ql.clearContent();
}

/// Drop everything this host owed the preview pipeline.
pub fn previewHostDied(self: *BrowserView, hc: *HostConn) void {
    if (self.preview_read) |pr| {
        if (pr.hc == hc) self.abandonPreviewRead();
    }
    if (self.preview_state.preload_read) |pr| {
        if (pr.hc == hc) self.abandonPreload();
    }
    var i: usize = 0;
    while (i < self.preview_state.preload_queue.items.len) {
        if (self.preview_state.preload_queue.items[i].hc == hc) {
            var it = self.preview_state.preload_queue.orderedRemove(i);
            it.deinit(self.allocator);
        } else i += 1;
    }
}

pub fn abandonPreviewRead(self: *BrowserView) void {
    endRead(self, &self.preview_read);
}

pub fn abandonPreload(self: *BrowserView) void {
    endRead(self, &self.preview_state.preload_read);
}

/// Cancel and release the read in `slot`. A generator job that may
/// still be running is canceled fire-and-forget: the helper is
/// ephemeral and may already have been reaped, and that "no such
/// job" reply is not a user-facing failure.
fn endRead(self: *BrowserView, slot: *?*PreviewRead) void {
    const pr = slot.* orelse return;
    slot.* = null;
    if (pr.phase == .job_wait and pr.job != 0 and pr.hc.state == .ready)
        self.sendOp(pr.hc, .{ .req = @as(u32, 0), .op = "job_cancel", .job = pr.job });
    if (pr.temp.len > 0 and pr.hc.state == .ready)
        self.sendOp(pr.hc, .{ .req = @as(u32, 0), .op = "unlink", .path = pr.temp });
    pr.destroy(self.allocator);
}

/// The entry the preview is about: the Quick Look cursor when the
/// overlay is open (it arrows independently of the list selection),
/// otherwise the last-selected row.
fn previewTargetPath(self: *BrowserView, tab: *BTab) ?[]const u8 {
    if (self.preview_state.ql) |ql| return ql.path;
    if (tab.selected.items.len == 0) return null;
    return tab.selected.items[tab.selected.items.len - 1];
}

/// Cache identity for one entry: host, path and mtime, so an edited
/// file is never shown from a stale entry.
fn cacheKey(buf: []u8, hc: *HostConn, path: []const u8, mtime_ms: i64) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}\x00{s}\x00{d}", .{
        hc.host orelse "", path, mtime_ms,
    }) catch null;
}

/// The header block shown above every preview.
fn describeEntry(buf: []u8, path: []const u8, entry: ?*Entry) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    w.print("{s}", .{std.fs.path.basename(path)}) catch {};
    const e = entry orelse return w.buffered();
    var sz: [48:0]u8 = undefined;
    var tz: [40:0]u8 = undefined;
    var mz: [16:0]u8 = undefined;
    w.print("\n{s}", .{e.kind}) catch {};
    if (!std.mem.eql(u8, e.kind, "dir"))
        w.print("  {s}", .{fmtSize(&sz, e.size)}) catch {};
    w.print("  {s}", .{std.mem.span(fmtModeZ(&mz, e.mode, e.tdir))}) catch {};
    if (e.mtime_ms != 0) w.print("\n{s}", .{fmtTimeZ(&tz, e.mtime_ms)}) catch {};
    if (e.target) |t| w.print("\n-> {s}", .{t}) catch {};
    if (e.tags.len > 0) w.print("\ntags: {s}", .{e.tags}) catch {};
    return w.buffered();
}

/// Refresh the preview panel and the overlay from the current target.
/// Every call is a new generation: results from the previous one are
/// dropped rather than painted over the new entry.
pub fn updatePreview(self: *BrowserView) void {
    if (!self.preview_on and self.preview_state.ql == null) return;
    self.preview_generation +%= 1;
    if (self.preview_generation == 0) self.preview_generation = 1;
    self.abandonPreviewRead();
    self.clearPreviewContent();

    const tab = self.currentTab() orelse {
        setPreviewMeta(self, "");
        return;
    };
    const path = previewTargetPath(self, tab) orelse {
        setPreviewMeta(self, "No selection");
        return;
    };
    const entry = entryForPath(tab, path);
    var meta_buf: [1024]u8 = undefined;
    setPreviewMeta(self, describeEntry(&meta_buf, path, entry));

    const is_dir = if (entry) |e| e.tdir else false;
    startPreview(self, tab.hc, path, if (entry) |e| e.mtime_ms else 0, is_dir, false);
    self.schedulePreload(tab, path);
}

fn setPreviewMeta(self: *BrowserView, text: []const u8) void {
    var z: [1200:0]u8 = undefined;
    const n = @min(text.len, z.len - 1);
    @memcpy(z[0..n], text[0..n]);
    z[n] = 0;
    c.gtk_label_set_text(self.preview_meta, &z);
    if (self.preview_state.ql) |ql| c.gtk_label_set_text(ql.title, &z);
}

/// The user's previewer rules, loaded once per view.
fn userRules(self: *BrowserView) []const previewers.Rule {
    if (self.preview_state.rules == null)
        self.preview_state.rules = previewers.load(self.allocator);
    return self.preview_state.rules.?.list;
}

/// Start (or serve from cache) the preview of one entry. A preload
/// only fills the cache; the foreground fetch also paints.
fn startPreview(
    self: *BrowserView,
    hc: *HostConn,
    path: []const u8,
    mtime_ms: i64,
    is_dir: bool,
    preload: bool,
) void {
    var key_buf: [4700]u8 = undefined;
    const key = cacheKey(&key_buf, hc, path, mtime_ms) orelse return;
    if (self.preview_state.cacheFind(key)) |item| {
        if (item.complete()) {
            if (!preload) paintPreview(self, item);
            return;
        }
    }
    if (hc.state != .ready) {
        if (!preload) showPreviewNote(self, "host is not connected");
        return;
    }

    const name = std.fs.path.basename(path);
    var mime_buf: [256]u8 = undefined;
    const handler = previewers.resolve(
        userRules(self),
        name,
        guessMime(&mime_buf, name),
        is_dir,
    );
    if (handler.producer == .builtin and handler.producer.builtin == .metadata) {
        // Directories: the header block is the whole summary. Say so
        // rather than leaving an empty box.
        if (!preload) showPreviewNote(self, directorySummary(self, path));
        return;
    }

    const pr = self.allocator.create(PreviewRead) catch return;
    pr.* = .{
        .req = self.nextReq(),
        .hc = hc,
        .path = self.allocator.dupe(u8, path) catch {
            self.allocator.destroy(pr);
            return;
        },
        .key = self.allocator.dupe(u8, key) catch {
            self.allocator.free(pr.path);
            self.allocator.destroy(pr);
            return;
        },
        .output = handler.output,
        .force_hex = handler.producer == .builtin and handler.producer.builtin == .hex,
        .preload = preload,
        .generation = if (preload) 0 else self.preview_generation,
    };
    const slot = if (preload) &self.preview_state.preload_read else &self.preview_read;
    endRead(self, slot);
    slot.* = pr;
    if (!preload) c.gtk_label_set_text(self.preview_text, "loading...");
    if (self.preview_state.ql) |ql| if (!preload) c.gtk_label_set_text(ql.status, "loading...");

    switch (handler.producer) {
        .builtin => |b| switch (b) {
            .thumbnail => self.sendOp(hc, .{ .req = pr.req, .op = "preview", .path = pr.path }),
            .head, .hex => {
                pr.phase = .read_file;
                self.sendOp(hc, .{
                    .req = pr.req,
                    .op = "read",
                    .path = pr.path,
                    .off = @as(u64, 0),
                    .len = PREVIEW_HEAD_CAP,
                });
            },
            .metadata => unreachable, // handled above
        },
        .host_command => |cmd| startHostPreviewer(self, pr, cmd, handler.output),
    }
}

/// An honest one-line summary for a directory: the metadata header
/// plus the item count when this view already has the listing (an
/// unexpanded directory is not worth a recursive scan).
fn directorySummary(self: *BrowserView, path: []const u8) []const u8 {
    const tab = self.currentTab() orelse return "Directory";
    const dir = if (std.mem.eql(u8, tab.root.path, path))
        tab.root
    else
        tab.subdirByPath(path) orelse return "Directory (open it to list its contents)";
    if (!dir.loaded) return "Directory (listing...)";
    var buf: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "Directory - {d} items", .{dir.entries.items.len}) catch "Directory";
    return previewNoteScratch(self, text);
}

/// Copy a transient note into the view's scratch so callers can hand
/// out a slice that outlives their own stack frame.
fn previewNoteScratch(self: *BrowserView, text: []const u8) []const u8 {
    const n = @min(text.len, self.spec_scratch.len);
    @memcpy(self.spec_scratch[0..n], text[0..n]);
    return self.spec_scratch[0..n];
}

/// Run a user previewer on the file's host. `panelize` is the
/// daemon's existing "run this command there" job; the wrapper
/// prints the scratch path it produced, which comes back as the
/// job's one match and is then read and unlinked.
fn startHostPreviewer(self: *BrowserView, pr: *PreviewRead, cmd: []const u8, output: previewers.Output) void {
    self.preview_state.temp_seq +%= 1;
    var nonce: [8]u8 = undefined;
    if (c.getentropy(&nonce, nonce.len) != 0)
        std.mem.writeInt(u64, &nonce, self.preview_state.temp_seq, .little);
    var temp_buf: [96]u8 = undefined;
    const temp = std.fmt.bufPrint(&temp_buf, "/tmp/.sketerm-preview-{x}{s}", .{
        std.mem.readInt(u64, &nonce, .little),
        if (output == .image) ".png" else ".txt",
    }) catch return failRead(self, pr, "cannot name a scratch file");
    pr.temp = self.allocator.dupe(u8, temp) catch return failRead(self, pr, "out of memory");
    const script = previewers.hostScript(self.allocator, cmd, pr.path, temp, output) orelse
        return failRead(self, pr, "previewer command is unusable");
    defer self.allocator.free(script);
    const dir = std.fs.path.dirname(pr.path) orelse "/";
    self.sendOp(pr.hc, .{ .req = pr.req, .op = "panelize", .path = dir, .pattern = script });
}

/// Feed preview-fetch frames; true when consumed.
pub fn feedPreview(self: *BrowserView, hc: *HostConn, ftype: wire.FrameType, payload: []const u8) bool {
    if (feedReadSlot(self, &self.preview_read, hc, ftype, payload)) return true;
    return feedReadSlot(self, &self.preview_state.preload_read, hc, ftype, payload);
}

fn feedReadSlot(
    self: *BrowserView,
    slot: *?*PreviewRead,
    hc: *HostConn,
    ftype: wire.FrameType,
    payload: []const u8,
) bool {
    const pr = slot.* orelse return false;
    if (pr.hc != hc) return false;
    switch (ftype) {
        .fs_data => {
            if (payload.len < 12) return false;
            if (std.mem.readInt(u32, payload[0..4], .little) != pr.req) return false;
            if (pr.buf.items.len < PREVIEW_IMAGE_CAP)
                pr.buf.appendSlice(self.allocator, payload[12..]) catch {};
            return true;
        },
        .fs_reply => {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const rep = std.json.parseFromSliceLeaky(WireReply, arena.allocator(), payload, .{
                .ignore_unknown_fields = true,
            }) catch return false;
            if (rep.req != pr.req) return false;
            switch (pr.phase) {
                .job_start => {
                    if (!rep.ok or rep.job == 0) {
                        failRead(self, pr, if (rep.@"error".len > 0) rep.@"error" else "preview unavailable");
                        endSlot(self, slot);
                    } else {
                        pr.job = rep.job;
                        pr.phase = .job_wait;
                    }
                    return true;
                },
                .read_file => {
                    if (!rep.ok or pr.buf.items.len == 0) {
                        failRead(self, pr, if (rep.@"error".len > 0) rep.@"error" else "the preview is empty");
                    } else {
                        deliverRead(self, pr);
                    }
                    endSlot(self, slot);
                    return true;
                },
                .job_wait => return false,
            }
        },
        .fs_job => {
            if (pr.phase != .job_wait) return false;
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const ev = std.json.parseFromSliceLeaky(WireJobEv, arena.allocator(), payload, .{
                .ignore_unknown_fields = true,
            }) catch return false;
            if (ev.job != pr.job) return false;
            if (std.mem.eql(u8, ev.ev, "match")) {
                // A host previewer names its scratch file; the wrapper
                // prints exactly one path.
                if (pr.temp.len > 0 and ev.path.len > 0 and !std.mem.eql(u8, pr.temp, ev.path)) {
                    self.allocator.free(pr.temp);
                    pr.temp = self.allocator.dupe(u8, ev.path) catch &.{};
                }
                return true;
            }
            if (std.mem.eql(u8, ev.ev, "done")) {
                // The generator's own metadata (ffprobe/pdfinfo output)
                // is worth showing next to its image.
                if (ev.text.len > 0 and pr.note.len == 0)
                    pr.note = self.allocator.dupe(u8, ev.text) catch &.{};
                const asset = if (ev.path.len > 0) ev.path else pr.temp;
                if (asset.len == 0) {
                    if (pr.note.len > 0) deliverRead(self, pr) else failRead(self, pr, "the previewer produced no output");
                    endSlot(self, slot);
                    return true;
                }
                pr.phase = .read_file;
                pr.req = self.nextReq();
                pr.buf.clearRetainingCapacity();
                self.sendOp(pr.hc, .{
                    .req = pr.req,
                    .op = "read",
                    .path = asset,
                    .off = @as(u64, 0),
                    .len = @as(u64, 2 << 20),
                });
                return true;
            }
            if (std.mem.eql(u8, ev.ev, "error") or std.mem.eql(u8, ev.ev, "canceled")) {
                failRead(self, pr, if (ev.message.len > 0) ev.message else "preview unavailable");
                endSlot(self, slot);
            }
            return true;
        },
        else => return false,
    }
}

/// Release a finished read (its scratch file is already accounted
/// for) and let the preloader take the freed slot.
fn endSlot(self: *BrowserView, slot: *?*PreviewRead) void {
    endRead(self, slot);
    self.pumpPreload();
}

/// Cache and show an honest failure so the same entry is not retried
/// on every arrow key.
fn failRead(self: *BrowserView, pr: *PreviewRead, message: []const u8) void {
    const key = self.allocator.dupe(u8, pr.key) catch return;
    const note = self.allocator.dupe(u8, message) catch {
        self.allocator.free(key);
        return;
    };
    const stored = self.preview_state.cachePut(self.allocator, .{
        .key = key,
        .note = note,
        .failed = true,
    }) orelse return;
    if (!pr.preload and pr.generation == self.preview_generation) paintPreview(self, stored);
}

/// The bytes arrived: text is rendered here, an image goes to the
/// worker so no decode ever runs in the fd callback.
fn deliverRead(self: *BrowserView, pr: *PreviewRead) void {
    const key = self.allocator.dupe(u8, pr.key) catch return;
    const note: ?[]u8 = if (pr.note.len > 0) (self.allocator.dupe(u8, pr.note) catch null) else null;
    if (pr.output == .image and pr.buf.items.len > 0) {
        // The generator's metadata is ready now; the image follows
        // from the worker and merges into this same entry.
        _ = self.preview_state.cachePut(self.allocator, .{ .key = key, .note = note });
        self.queuePreviewDecode(pr);
        return;
    }
    const rendered = renderText(self.allocator, pr.buf.items, pr.force_hex) orelse {
        self.allocator.free(key);
        if (note) |n| self.allocator.free(n);
        return;
    };
    const stored = self.preview_state.cachePut(self.allocator, .{
        .key = key,
        .text = rendered.text,
        .note = note,
        .hex = rendered.hex,
    }) orelse return;
    if (!pr.preload and pr.generation == self.preview_generation) paintPreview(self, stored);
}

/// Text preview bytes as the user should see them: as text when they
/// read as text, as a bounded hex dump otherwise. This is what makes
/// hex the fallback for any type without a handler.
fn renderText(allocator: std.mem.Allocator, bytes: []const u8, force_hex: bool) ?struct { text: []u8, hex: bool } {
    if (bytes.len == 0) {
        const empty = allocator.dupe(u8, "(empty file)") catch return null;
        return .{ .text = empty, .hex = false };
    }
    if (!force_hex and !hexdump.looksBinary(bytes)) {
        const n = @min(bytes.len, PREVIEW_TEXT_CAP);
        var z: [PREVIEW_TEXT_CAP + 1:0]u8 = undefined;
        @memcpy(z[0..n], bytes[0..n]);
        z[n] = 0;
        const valid = c.g_utf8_make_valid(&z, @intCast(n));
        defer c.g_free(valid);
        const text = allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(valid)))) catch return null;
        return .{ .text = text, .hex = false };
    }
    const n = @min(bytes.len, hexdump.DEFAULT_CAP);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    hexdump.write(&out.writer, bytes[0..n], 0) catch return null;
    const text = out.toOwnedSlice() catch return null;
    return .{ .text = text, .hex = true };
}

/// Hand image bytes to the worker thread for decode + scale.
pub fn queuePreviewDecode(self: *BrowserView, pr: *PreviewRead) void {
    const tc = self.ensureThumbWorker() orelse return;
    const a = std.heap.c_allocator;
    const path = a.dupe(u8, pr.path) catch return;
    // The worker appends "\x00<mtime>" to cache_key; the read's key
    // already carries the mtime, so this one stays identity-only and
    // the result key matches what the cache is looked up with.
    const key = a.dupe(u8, pr.key) catch {
        a.free(path);
        return;
    };
    const data = a.dupe(u8, pr.buf.items) catch {
        a.free(path);
        a.free(key);
        return;
    };
    tc.lock();
    defer tc.unlock();
    tc.queue.append(a, .{
        .path = path,
        .cache_key = key,
        .mtime_ms = 0,
        .data = data,
        .cached_png = true,
        .kind = .preview,
        .preview_generation = if (pr.preload) 0 else pr.generation,
    }) catch {
        a.free(path);
        a.free(key);
        a.free(data);
        return;
    };
    _ = c.pthread_cond_signal(&tc.cond);
}

/// Worker handback for a preview decode: cache the texture, paint it
/// when it still belongs to the entry on screen.
fn storePreviewImage(self: *BrowserView, res: *ThumbResult) void {
    // The worker's key is "<identity>\x00<mtime>" with mtime 0 for
    // previews; strip that suffix back to the read's cache key.
    const key_end = std.mem.lastIndexOfScalar(u8, res.key, 0) orelse res.key.len;
    const key = res.key[0..key_end];
    const texture: ?*c.GdkTexture = if (res.pixbuf) |pb| c.gdk_texture_new_for_pixbuf(pb) else null;
    // deliverRead already parked the generator's metadata under this
    // key; merge the image into it rather than replacing the note.
    const stored = if (self.preview_state.cacheFind(key)) |existing| blk: {
        if (existing.texture) |old| c.g_object_unref(@ptrCast(old));
        existing.texture = texture;
        break :blk existing;
    } else blk: {
        const owned = self.allocator.dupe(u8, key) catch {
            if (texture) |t| c.g_object_unref(@ptrCast(t));
            return;
        };
        break :blk self.preview_state.cachePut(self.allocator, .{
            .key = owned,
            .texture = texture,
        }) orelse return;
    };
    if (stored.texture == null) {
        stored.failed = true;
        if (stored.note == null)
            stored.note = self.allocator.dupe(u8, "(cannot decode preview image)") catch null;
    }
    if (res.preview_generation != 0 and res.preview_generation == self.preview_generation)
        paintPreview(self, stored);
}

/// Paint one finished preview into the side panel and, when it is
/// open, the Quick Look overlay.
fn paintPreview(self: *BrowserView, item: *const CacheItem) void {
    const body: []const u8 = item.text orelse (item.note orelse "");
    // Large enough for either shape of text preview: the UTF-8 head
    // or a full hex dump of the same head.
    var z: [@max(PREVIEW_TEXT_CAP, hexdump.renderedSize(hexdump.DEFAULT_CAP)) + 1:0]u8 = undefined;
    const n = @min(body.len, z.len - 1);
    @memcpy(z[0..n], body[0..n]);
    z[n] = 0;
    c.gtk_picture_set_paintable(@ptrCast(self.preview_pic), @ptrCast(item.texture));
    // A hex dump's columns only survive unwrapped; prose still wraps
    // into the narrow side panel.
    c.gtk_label_set_wrap(self.preview_text, @intFromBool(!item.hex));
    c.gtk_label_set_text(self.preview_text, &z);
    if (self.preview_state.ql) |ql| {
        c.gtk_picture_set_paintable(@ptrCast(ql.picture), @ptrCast(item.texture));
        c.gtk_widget_set_visible(ql.picture, @intFromBool(item.texture != null));
        c.gtk_label_set_text(ql.text, &z);
        c.gtk_widget_set_visible(ql.text_scroll, @intFromBool(n > 0));
        c.gtk_label_set_text(ql.status, if (item.failed) "preview unavailable" else "");
    }
}

/// A note with no content behind it (directory summary, disconnected
/// host): honest text in place of a blank box.
fn showPreviewNote(self: *BrowserView, note: []const u8) void {
    var z: [512:0]u8 = undefined;
    const n = @min(note.len, z.len - 1);
    @memcpy(z[0..n], note[0..n]);
    z[n] = 0;
    c.gtk_label_set_text(self.preview_text, &z);
    if (self.preview_state.ql) |ql| {
        c.gtk_widget_set_visible(ql.picture, 0);
        c.gtk_widget_set_visible(ql.text_scroll, 1);
        c.gtk_label_set_text(ql.text, &z);
        c.gtk_label_set_text(ql.status, "");
    }
}

pub fn onPreviewToggled(btn: *c.GtkToggleButton, user: ?*anyopaque) callconv(.c) void {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    self.preview_on = c.gtk_toggle_button_get_active(btn) != 0;
    c.gtk_widget_set_visible(self.preview_box, @intFromBool(self.preview_on));
    if (self.preview_on) {
        self.updatePreview();
    } else {
        self.abandonPreviewRead();
        self.clearPreloadQueue();
    }
}

// ── preloading ──────────────────────────────────────────────────

/// True when this entry's preview is already finished and warm.
fn previewCached(self: *BrowserView, key: []const u8) bool {
    const item = self.preview_state.cacheFind(key) orelse return false;
    return item.complete();
}

pub fn clearPreloadQueue(self: *BrowserView) void {
    self.abandonPreload();
    for (self.preview_state.preload_queue.items) |*it| it.deinit(self.allocator);
    self.preview_state.preload_queue.clearRetainingCapacity();
}

/// Queue the entries next to `current` so arrowing through them is
/// instant. Cancels the previous lookahead first, so navigation
/// never leaves a growing tail of remote work behind it.
pub fn schedulePreload(self: *BrowserView, tab: *BTab, current: []const u8) void {
    self.clearPreloadQueue();
    if (!self.preview_on and self.preview_state.ql == null) return;
    const list = NavList.of(tab);
    const at = list.indexOf(current) orelse return;
    var offset: isize = -@as(isize, PRELOAD_BEHIND);
    var buf: [4096]u8 = undefined;
    var key_buf: [4700]u8 = undefined;
    while (offset <= @as(isize, PRELOAD_AHEAD)) : (offset += 1) {
        if (offset == 0) continue;
        const idx = @as(isize, @intCast(at)) + offset;
        if (idx < 0) continue;
        const path = list.at(@intCast(idx), &buf) orelse continue;
        const entry = entryForPath(tab, path) orelse continue;
        if (entry.tdir) continue;
        const key = cacheKey(&key_buf, tab.hc, path, entry.mtime_ms) orelse continue;
        if (previewCached(self, key)) continue;
        if (self.preview_state.preload_queue.items.len >= PRELOAD_QUEUE_CAP) break;
        const owned_path = self.allocator.dupe(u8, path) catch continue;
        const owned_key = self.allocator.dupe(u8, key) catch {
            self.allocator.free(owned_path);
            continue;
        };
        self.preview_state.preload_queue.append(self.allocator, .{
            .hc = tab.hc,
            .path = owned_path,
            .key = owned_key,
            .mtime_ms = entry.mtime_ms,
        }) catch {
            self.allocator.free(owned_path);
            self.allocator.free(owned_key);
        };
    }
    self.pumpPreload();
}

/// Start the next queued neighbour. Exactly one preload runs, and
/// never while the visible entry is still loading.
pub fn pumpPreload(self: *BrowserView) void {
    if (self.preview_read != null or self.preview_state.preload_read != null) return;
    while (self.preview_state.preload_queue.items.len > 0) {
        var item = self.preview_state.preload_queue.orderedRemove(0);
        defer item.deinit(self.allocator);
        if (item.hc.state != .ready) continue;
        if (previewCached(self, item.key)) continue;
        startPreview(self, item.hc, item.path, item.mtime_ms, false, true);
        if (self.preview_state.preload_read != null) return;
    }
}

/// The order Quick Look arrows through: the current multi-selection
/// when there is one (the user picked those on purpose), otherwise
/// the tab's visible listing.
const NavList = struct {
    tab: *BTab,
    selection: bool,

    fn of(tab: *BTab) NavList {
        return .{ .tab = tab, .selection = tab.selected.items.len > 1 };
    }

    fn visible(tab: *BTab, e: Entry) bool {
        return tab.show_hidden or e.name.len == 0 or e.name[0] != '.';
    }

    fn at(self: NavList, index: usize, buf: []u8) ?[]const u8 {
        if (self.selection) {
            if (index >= self.tab.selected.items.len) return null;
            return self.tab.selected.items[index];
        }
        var n: usize = 0;
        for (self.tab.root.entries.items) |e| {
            if (!visible(self.tab, e)) continue;
            if (n == index) return self.tab.root.fullPath(e, buf);
            n += 1;
        }
        return null;
    }

    fn indexOf(self: NavList, path: []const u8) ?usize {
        var buf: [4096]u8 = undefined;
        var i: usize = 0;
        while (self.at(i, &buf)) |p| : (i += 1) {
            if (std.mem.eql(u8, p, path)) return i;
        }
        return null;
    }
};

// ── Quick Look overlay ──────────────────────────────────────────

/// The large single-key preview. Its own window rather than a child
/// of the browser box: it must survive the listing being rebuilt
/// under it, and it owns its keys (arrows move without closing).
pub const QuickLook = struct {
    view: *BrowserView,
    window: *c.GtkWidget,
    title: *c.GtkLabel,
    picture: *c.GtkWidget,
    text_scroll: *c.GtkWidget,
    text: *c.GtkLabel,
    status: *c.GtkLabel,
    /// The entry on screen (owned); the preview target while open.
    path: []u8,

    fn clearContent(self: *QuickLook) void {
        c.gtk_picture_set_paintable(@ptrCast(self.picture), null);
        c.gtk_widget_set_visible(self.picture, 0);
        c.gtk_label_set_text(self.text, "");
        c.gtk_label_set_text(self.status, "");
    }

    /// Tear down the window and the struct. The view's pointer is
    /// cleared first so the destroy handler does not recurse.
    fn destroy(self: *QuickLook) void {
        const view = self.view;
        view.preview_state.ql = null;
        const window = self.window;
        view.allocator.free(self.path);
        view.allocator.destroy(self);
        c.gtk_window_destroy(@ptrCast(@alignCast(window)));
    }
};

/// Space on a focused entry. @return true when the overlay handled
/// the key (opened or closed), false when there is nothing to show
/// and the key belongs to type-ahead.
pub fn quickLookToggle(self: *BrowserView) bool {
    if (self.preview_state.ql != null) {
        self.quickLookClose();
        return true;
    }
    const tab = self.currentTab() orelse return false;
    if (tab.selected.items.len == 0) return false;
    const path = tab.selected.items[tab.selected.items.len - 1];
    return self.quickLookOpen(path);
}

pub fn quickLookOpen(self: *BrowserView, path: []const u8) bool {
    const ql = self.allocator.create(QuickLook) catch return false;
    const owned = self.allocator.dupe(u8, path) catch {
        self.allocator.destroy(ql);
        return false;
    };

    const window = c.gtk_window_new();
    c.gtk_window_set_title(@ptrCast(window), "Preview");
    if (c.gtk_widget_get_root(self.root_box)) |root|
        c.gtk_window_set_transient_for(@ptrCast(window), @ptrCast(@alignCast(root)));
    const w = c.gtk_widget_get_width(self.root_box);
    const h = c.gtk_widget_get_height(self.root_box);
    c.gtk_window_set_default_size(@ptrCast(window), if (w > 200) w else 900, if (h > 200) h else 700);

    const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 6);
    c.gtk_widget_set_margin_start(box, 10);
    c.gtk_widget_set_margin_end(box, 10);
    c.gtk_widget_set_margin_top(box, 10);
    c.gtk_widget_set_margin_bottom(box, 10);

    const title = c.gtk_label_new("");
    c.gtk_label_set_xalign(@ptrCast(title), 0);
    c.gtk_label_set_selectable(@ptrCast(title), 1);
    c.gtk_box_append(@ptrCast(box), title);

    const picture = c.gtk_picture_new();
    c.gtk_picture_set_can_shrink(@ptrCast(picture), 1);
    c.gtk_picture_set_content_fit(@ptrCast(picture), c.GTK_CONTENT_FIT_CONTAIN);
    c.gtk_widget_set_hexpand(picture, 1);
    c.gtk_widget_set_vexpand(picture, 1);
    c.gtk_widget_set_visible(picture, 0);
    c.gtk_box_append(@ptrCast(box), picture);

    const text_scroll = c.gtk_scrolled_window_new();
    c.gtk_scrolled_window_set_policy(@ptrCast(text_scroll), c.GTK_POLICY_AUTOMATIC, c.GTK_POLICY_AUTOMATIC);
    c.gtk_widget_set_hexpand(text_scroll, 1);
    c.gtk_widget_set_vexpand(text_scroll, 1);
    const text = c.gtk_label_new("");
    c.gtk_label_set_xalign(@ptrCast(text), 0);
    c.gtk_label_set_yalign(@ptrCast(text), 0);
    // Never wrap: a hex dump's columns and a source file's
    // indentation both depend on it, and the scroller handles width.
    c.gtk_label_set_wrap(@ptrCast(text), 0);
    c.gtk_label_set_selectable(@ptrCast(text), 1);
    c.gtk_widget_add_css_class(text, "monospace");
    c.gtk_scrolled_window_set_child(@ptrCast(text_scroll), text);
    c.gtk_box_append(@ptrCast(box), text_scroll);

    const status = c.gtk_label_new("");
    c.gtk_label_set_xalign(@ptrCast(status), 0);
    c.gtk_widget_add_css_class(status, "dim-label");
    c.gtk_box_append(@ptrCast(box), status);

    const hint = c.gtk_label_new("Space or Esc closes - arrows move - Enter opens");
    c.gtk_label_set_xalign(@ptrCast(hint), 0);
    c.gtk_widget_add_css_class(hint, "dim-label");
    c.gtk_box_append(@ptrCast(box), hint);

    c.gtk_window_set_child(@ptrCast(window), box);

    ql.* = .{
        .view = self,
        .window = window,
        .title = @ptrCast(@alignCast(title)),
        .picture = picture,
        .text_scroll = text_scroll,
        .text = @ptrCast(@alignCast(text)),
        .status = @ptrCast(@alignCast(status)),
        .path = owned,
    };
    self.preview_state.ql = ql;

    const keys = c.gtk_event_controller_key_new();
    c.gtk_event_controller_set_propagation_phase(@ptrCast(keys), c.GTK_PHASE_CAPTURE);
    _ = c.g_signal_connect_data(keys, "key-pressed", @ptrCast(&onQuickLookKey), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_controller(window, @ptrCast(keys));
    _ = c.g_signal_connect_data(window, "close-request", @ptrCast(&onQuickLookCloseRequest), @ptrCast(self), null, c.G_CONNECT_DEFAULT);

    c.gtk_window_present(@ptrCast(window));
    self.updatePreview();
    return true;
}

pub fn quickLookClose(self: *BrowserView) void {
    const ql = self.preview_state.ql orelse return;
    ql.destroy();
    self.abandonPreviewRead();
    self.clearPreloadQueue();
    // The target reverts to the list selection.
    self.updatePreview();
}

/// The window went away on its own (WM close button): drop the
/// struct without destroying the window a second time.
pub fn onQuickLookCloseRequest(_: *c.GtkWindow, user: ?*anyopaque) callconv(.c) c.gboolean {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    if (self.preview_state.ql) |ql| {
        self.preview_state.ql = null;
        self.allocator.free(ql.path);
        self.allocator.destroy(ql);
        self.abandonPreviewRead();
        self.clearPreloadQueue();
    }
    return 0; // let the default handler destroy the window
}

pub fn onQuickLookKey(
    _: *c.GtkEventControllerKey,
    keyval: c_uint,
    _: c_uint,
    _: c.GdkModifierType,
    user: ?*anyopaque,
) callconv(.c) c.gboolean {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    switch (keyval) {
        c.GDK_KEY_Escape, c.GDK_KEY_space, c.GDK_KEY_KP_Space => {
            self.quickLookClose();
            return 1;
        },
        c.GDK_KEY_Left, c.GDK_KEY_Up, c.GDK_KEY_Page_Up => {
            self.quickLookStep(-1);
            return 1;
        },
        c.GDK_KEY_Right, c.GDK_KEY_Down, c.GDK_KEY_Page_Down => {
            self.quickLookStep(1);
            return 1;
        },
        c.GDK_KEY_Return, c.GDK_KEY_KP_Enter => {
            self.quickLookActivate();
            return 1;
        },
        else => return 0,
    }
}

/// Move the overlay's cursor without closing it. Clamped at both
/// ends: an arrow that runs off the list is a no-op, not a wrap.
pub fn quickLookStep(self: *BrowserView, delta: isize) void {
    const ql = self.preview_state.ql orelse return;
    const tab = self.currentTab() orelse return;
    const list = NavList.of(tab);
    const at = list.indexOf(ql.path) orelse return;
    const next = @as(isize, @intCast(at)) + delta;
    if (next < 0) return;
    var buf: [4096]u8 = undefined;
    const path = list.at(@intCast(next), &buf) orelse return;
    const owned = self.allocator.dupe(u8, path) catch return;
    self.allocator.free(ql.path);
    ql.path = owned;
    self.updatePreview();
}

/// Enter: open the entry in its default application and close.
pub fn quickLookActivate(self: *BrowserView) void {
    const ql = self.preview_state.ql orelse return;
    const tab = self.currentTab() orelse return;
    var buf: [4096]u8 = undefined;
    if (ql.path.len >= buf.len) return;
    @memcpy(buf[0..ql.path.len], ql.path);
    const path = buf[0..ql.path.len];
    const hc = tab.hc;
    self.quickLookClose();
    self.openPathOnHost(hc, path);
}
