//! Preview pane and thumbnails.
//!
//! Nothing here ever blocks the GLib loop: local probe/decode/save
//! runs on a worker thread; remote thumbnails ride the nonblocking fs
//! wire (read the HOST's cache, else fetch source bytes, encode on the
//! worker, write the PNG BACK to the host's cache so it is shared with
//! that machine's own apps).

const std = @import("std");
const c = @import("../../c.zig").c;
const wire = @import("../../mux/wire.zig");
const thumbs_mod = @import("../../filebrowser/thumbs.zig");

const BTab = @import("types.zig").BTab;
const BrowserView = @import("view.zig").BrowserView;
const Entry = @import("types.zig").Entry;
const HostConn = @import("types.zig").HostConn;
const WireJobEv = @import("types.zig").WireJobEv;
const WireReply = @import("types.zig").WireReply;
const entryForPath = @import("nav.zig").entryForPath;
const fmtSize = @import("../../filebrowser/format.zig").fmtSize;
const fmtTimeZ = @import("../../filebrowser/format.zig").fmtTimeZ;
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

/// One in-flight remote preview fetch (chunked fs read).
pub const PreviewRead = struct {
    req: u32,
    hc: *HostConn,
    path: []u8,
    phase: enum { start_job, wait_job, read_asset } = .start_job,
    job: u64 = 0,
    generation: u64,
    off: u64 = 0,
    buf: std.ArrayList(u8) = .empty,

    pub fn destroy(self: *PreviewRead, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.buf.deinit(allocator);
        allocator.destroy(self);
    }
};

/// Content caps: whole image (bounded) vs a text head.
pub const PREVIEW_IMAGE_CAP: usize = 8 << 20;

pub const PREVIEW_TEXT_CAP: usize = 4096;

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
                const bound: f64 = if (req.preview_generation != 0) 480.0 else 128.0;
                const scale = @max(w / bound, h / bound);
                const nw: c_int = if (scale > 1) @intFromFloat(@max(1.0, w / scale)) else @intFromFloat(w);
                const nh: c_int = if (scale > 1) @intFromFloat(@max(1.0, h / scale)) else @intFromFloat(h);
                pixbuf = c.gdk_pixbuf_scale_simple(full, nw, nh, c.GDK_INTERP_BILINEAR);
            }
        }
        c.g_object_unref(loader); // drops `full` with it
        if (pixbuf) |pb| if (!req.cached_png and req.preview_generation == 0) {
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
    if (res.preview_generation != 0) {
        defer if (res.pixbuf) |pb| c.g_object_unref(pb);
        if (res.preview_generation == self.preview_generation) {
            if (res.pixbuf) |pb| {
                const tex = c.gdk_texture_new_for_pixbuf(pb);
                if (tex) |t| {
                    c.gtk_picture_set_paintable(@ptrCast(self.preview_pic), @ptrCast(t));
                    c.g_object_unref(@as(?*anyopaque, @ptrCast(t)));
                }
            } else {
                c.gtk_label_set_text(self.preview_text, "(cannot decode preview image)");
            }
        }
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
                    self.queueRemoteDecode(rt, true, 0);
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
pub fn queueRemoteDecode(self: *BrowserView, rt: *RemoteThumb, cached_png: bool, preview_generation: u64) void {
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
    tc.queue.append(a, .{ .path = path, .cache_key = key, .mtime_ms = rt.mtime_ms, .data = data, .cached_png = cached_png, .preview_generation = preview_generation, .remote_id = rt.id }) catch {
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

pub fn clearPreviewContent(self: *BrowserView) void {
    c.gtk_picture_set_paintable(@ptrCast(self.preview_pic), null);
    c.gtk_label_set_text(self.preview_text, "");
}

pub fn abandonPreviewRead(self: *BrowserView) void {
    if (self.preview_read) |pr| {
        if (pr.phase == .wait_job and pr.job != 0 and pr.hc.state == .ready) {
            // req 0 = fire-and-forget: the helper is ephemeral and
            // may already have finished and been reaped, and that
            // "no such job" reply is not a user-facing failure.
            self.sendOp(pr.hc, .{ .req = @as(u32, 0), .op = "job_cancel", .job = pr.job });
        }
        pr.destroy(self.allocator);
        self.preview_read = null;
    }
}

/// Refresh the preview panel from the current tab's selection.
pub fn updatePreview(self: *BrowserView) void {
    if (!self.preview_on) return;
    self.preview_generation +%= 1;
    if (self.preview_generation == 0) self.preview_generation = 1;
    self.abandonPreviewRead();
    self.clearPreviewContent();
    const tab = self.currentTab() orelse {
        c.gtk_label_set_text(self.preview_meta, "");
        return;
    };
    if (tab.selected.items.len == 0) {
        c.gtk_label_set_text(self.preview_meta, "No selection");
        return;
    }
    const path = tab.selected.items[tab.selected.items.len - 1];
    const entry = entryForPath(tab, path);

    var meta: [1024:0]u8 = undefined;
    var w = std.Io.Writer.fixed(meta[0 .. meta.len - 1]);
    w.print("{s}", .{std.fs.path.basename(path)}) catch {};
    if (entry) |e| {
        var sz: [48:0]u8 = undefined;
        var tz: [40:0]u8 = undefined;
        w.print("\n{s}", .{e.kind}) catch {};
        if (!std.mem.eql(u8, e.kind, "dir"))
            w.print("  {s}", .{fmtSize(&sz, e.size)}) catch {};
        if (e.mtime_ms != 0)
            w.print("\n{s}", .{fmtTimeZ(&tz, e.mtime_ms)}) catch {};
        if (e.tags.len > 0) w.print("\ntags: {s}", .{e.tags}) catch {};
    }
    meta[w.buffered().len] = 0;
    c.gtk_label_set_text(self.preview_meta, &meta);

    // Directories: metadata only.
    if (entry != null and entry.?.tdir) return;
    self.previewRemoteStart(tab, path);
}

pub fn showTextPreview(self: *BrowserView, data: []const u8) void {
    if (data.len == 0) {
        c.gtk_label_set_text(self.preview_text, "(empty file)");
        return;
    }
    if (std.mem.indexOfScalar(u8, data, 0) != null) {
        c.gtk_label_set_text(self.preview_text, "(binary file)");
        return;
    }
    var z: [PREVIEW_TEXT_CAP + 1:0]u8 = undefined;
    const n = @min(data.len, PREVIEW_TEXT_CAP);
    @memcpy(z[0..n], data[0..n]);
    z[n] = 0;
    const valid = c.g_utf8_make_valid(&z, @intCast(n));
    c.gtk_label_set_text(self.preview_text, valid);
    c.g_free(valid);
}

pub fn previewRemoteStart(self: *BrowserView, tab: *BTab, path: []const u8) void {
    if (tab.hc.state != .ready) return;
    const pr = self.allocator.create(PreviewRead) catch return;
    pr.* = .{
        .req = self.nextReq(),
        .hc = tab.hc,
        .path = self.allocator.dupe(u8, path) catch {
            self.allocator.destroy(pr);
            return;
        },
        .generation = self.preview_generation,
    };
    self.preview_read = pr;
    c.gtk_label_set_text(self.preview_text, "loading…");
    self.sendOp(tab.hc, .{ .req = pr.req, .op = "preview", .path = pr.path });
}

/// Feed preview-fetch frames; true when consumed.
pub fn feedPreview(self: *BrowserView, hc: *HostConn, ftype: wire.FrameType, payload: []const u8) bool {
    const pr = self.preview_read orelse return false;
    if (pr.hc != hc) return false;
    switch (ftype) {
        .fs_data => {
            if (payload.len < 12) return false;
            if (std.mem.readInt(u32, payload[0..4], .little) != pr.req) return false;
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
            if (pr.phase == .start_job) {
                if (!rep.ok or rep.job == 0) {
                    c.gtk_label_set_text(self.preview_text, "(preview unavailable)");
                    self.abandonPreviewRead();
                } else {
                    pr.job = rep.job;
                    pr.phase = .wait_job;
                }
                return true;
            }
            if (pr.phase != .read_asset) return false;
            if (!rep.ok or pr.buf.items.len == 0) {
                c.gtk_label_set_text(self.preview_text, "(cannot read generated preview)");
                self.abandonPreviewRead();
                return true;
            }
            self.queuePreviewDecode(pr);
            self.abandonPreviewRead();
            return true;
        },
        .fs_job => {
            if (pr.phase != .wait_job) return false;
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const ev = std.json.parseFromSliceLeaky(WireJobEv, arena.allocator(), payload, .{ .ignore_unknown_fields = true }) catch return false;
            if (ev.job != pr.job) return false;
            if (std.mem.eql(u8, ev.ev, "done")) {
                if (ev.text.len > 0)
                    self.showTextPreview(ev.text)
                else
                    // Drop the "loading…" placeholder; a rendered
                    // image must not sit under stale status text.
                    c.gtk_label_set_text(self.preview_text, "");
                if (ev.path.len == 0) {
                    self.abandonPreviewRead();
                } else {
                    pr.phase = .read_asset;
                    pr.req = self.nextReq();
                    pr.buf.clearRetainingCapacity();
                    self.sendOp(pr.hc, .{ .req = pr.req, .op = "read", .path = ev.path, .off = @as(u64, 0), .len = @as(u64, 2 << 20) });
                }
            } else if (std.mem.eql(u8, ev.ev, "error") or std.mem.eql(u8, ev.ev, "canceled")) {
                self.showTextPreview(if (ev.message.len > 0) ev.message else "(preview unavailable)");
                self.abandonPreviewRead();
            }
            return true;
        },
        else => return false,
    }
}

pub fn queuePreviewDecode(self: *BrowserView, pr: *PreviewRead) void {
    const tc = self.ensureThumbWorker() orelse return;
    const a = std.heap.c_allocator;
    const path = a.dupe(u8, pr.path) catch return;
    const key = a.dupe(u8, pr.path) catch { a.free(path); return; };
    const data = a.dupe(u8, pr.buf.items) catch { a.free(path); a.free(key); return; };
    tc.lock();
    defer tc.unlock();
    tc.queue.append(a, .{
        .path = path,
        .cache_key = key,
        .mtime_ms = 0,
        .data = data,
        .cached_png = true,
        .preview_generation = pr.generation,
    }) catch {
        a.free(path);
        a.free(key);
        a.free(data);
        return;
    };
    _ = c.pthread_cond_signal(&tc.cond);
}

pub fn onPreviewToggled(btn: *c.GtkToggleButton, user: ?*anyopaque) callconv(.c) void {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    self.preview_on = c.gtk_toggle_button_get_active(btn) != 0;
    c.gtk_widget_set_visible(self.preview_box, @intFromBool(self.preview_on));
    if (self.preview_on) self.updatePreview() else self.abandonPreviewRead();
}
