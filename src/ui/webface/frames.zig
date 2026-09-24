//! Frame presentation, the face half: adopting the helper's buffers,
//! dma-buf imports, inline and memfd damage, and snapping the texture
//! onto the device pixel grid (see "Rendering" in `webface.zig`'s
//! header; `webframe.zig` holds what webaction.zig shares). Split out of `webface.zig`; the `WebFace` methods are free functions
//! taking `*WebFace`, re-exported from `WebFace` by name.

const std = @import("std");
const c = @import("../../c.zig").c;
const cast = @import("../../util/cast.zig");
const clock = @import("../../util/clock.zig");
const proto = @import("../../web/protocol.zig");
const webframe = @import("../webframe.zig");
const host_mod = @import("../webface.zig");
const WebFace = host_mod.WebFace;

/// One imported dma-buf pool buffer: the pool id and the GdkTexture
/// wrapping it (owned reference).
pub const DmabufEntry = struct {
    buf_id: u32 = 0,
    tex: ?*c.GdkTexture = null,
};

/// Descriptors owned by a built dmabuf texture, closed when GDK
/// releases it.
pub const DmabufFds = struct {
    fds: [proto.MAX_PLANES]c_int,
    n: u8,
    allocator: std.mem.Allocator,

    pub fn destroy(user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(DmabufFds, user);
        for (self.fds[0..self.n]) |fd| _ = c.close(fd);
        self.allocator.destroy(self);
    }
};

/// Drop OUR reference to the frame mapping, and every GPU import
/// keyed on the geometry it described. The picture keeps showing the
/// last presented texture (whose own references keep what it needs
/// alive) until a new frame replaces it.
pub fn dropMap(self: *WebFace) void {
    if (self.map) |m| {
        m.unref();
        self.map = null;
    }
    self.clearDmabufCache();
    // The update chain must not diff a new buffer against a texture
    // built over the old one.
    if (self.tex_prev) |t| {
        c.g_object_unref(@ptrCast(t));
        self.tex_prev = null;
    }
    self.buf_id = 0;
    self.buf_w = 0;
    self.buf_h = 0;
}

pub fn clearDmabufCache(self: *WebFace) void {
    for (&self.dmabuf_tex) |*e| {
        if (e.tex) |t| c.g_object_unref(@ptrCast(t));
        e.* = .{};
    }
}

/// Report a new buffer's geometry against the widget's, under
/// `SKETERM_WEB_STATS=1`. Buffers are rare (creation, resize, scale
/// change), so this is a handful of lines per session and it is the
/// only place the "is the FIRST frame already the right size"
/// question is answerable — the defect it exists for corrects itself
/// on the next interaction and is invisible afterwards.
pub fn noteBufferGeometry(self: *WebFace, pw: u16, ph: u16) void {
    if (!host_mod.g_stats.enabled()) return;
    const alloc = self.allocationSize();
    const lw = logicalOf(pw, self.sent_scale);
    const lh = logicalOf(ph, self.sent_scale);
    const fits = alloc.w == 0 or (lw == alloc.w and lh == alloc.h);
    std.debug.print(
        "webface geometry: buffer {d}x{d} phys = {d}x{d} logical at scale {d}, area {d}x{d} logical, match={s}\n",
        .{ pw, ph, lw, lh, self.sent_scale, alloc.w, alloc.h, if (fits) "yes" else "NO" },
    );
}

/// A PHYSICAL extent back in logical pixels. Rounded to nearest so
/// an exact-fit frame stays an exact fit (1707 * 1500 / 1000 = 2560
/// must come back as 1707, not 1706).
pub fn logicalOf(physical: u16, scale_x1000: u16) u16 {
    if (scale_x1000 == 0) return physical;
    const n = (@as(u32, physical) * 1000 + scale_x1000 / 2) / scale_x1000;
    return @intCast(@min(n, std.math.maxInt(u16)));
}

/// The view widget's LOGICAL size, or 0x0 when it has never been laid
/// out. `gtk_widget_get_width` reports the allocation, which exists
/// from the first size-allocate — well before the first render.
pub fn allocationSize(self: *WebFace) struct { w: u16, h: u16 } {
    if (self.widgets_dead) return .{ .w = 0, .h = 0 };
    const w = c.gtk_widget_get_width(self.view_area);
    const h = c.gtk_widget_get_height(self.view_area);
    if (w <= 0 or h <= 0) return .{ .w = 0, .h = 0 };
    return .{
        .w = @intCast(@min(w, std.math.maxInt(u16))),
        .h = @intCast(@min(h, std.math.maxInt(u16))),
    };
}

/// A fresh frame buffer for this view: map it (refcounted), drop
/// the previous one, and tell the helper the old buffer is ours no
/// more. Nothing is presented yet — a fresh buffer holds nothing
/// until its first damage batch, and the picture keeps the last
/// good frame meanwhile.
pub fn adoptBuffer(self: *WebFace, fb: proto.FrameBuffer, fd: c_int) void {
    defer _ = c.close(fd);
    const mref = webframe.mapFrameFd(self.allocator, fd, fb.w, fb.h, fb.stride) orelse return;
    const old_id = self.buf_id;
    self.dropMap();
    self.map = mref;
    self.buf_id = fb.buf_id;
    self.buf_w = fb.w;
    self.buf_h = fb.h;
    self.buf_stride = fb.stride;
    if (old_id != 0) self.cl.post(proto.FrameRelease{ .view = self.view, .buf_id = old_id });
    self.noteBufferGeometry(fb.w, fb.h);
    // A fresh buffer holds nothing yet: ask for the repaint that
    // fills it rather than waiting for the idle floor.
}

/// Hand a frame texture to the picture, sized to its LOGICAL extent
/// and re-snapped onto the device pixel grid. Takes ownership of
/// the caller's reference. There is still no frame QUEUE anywhere:
/// the paintable always wraps the newest pixels, so batches landing
/// between two GTK paints collapse into one.
pub fn presentTexture(self: *WebFace, tex: *c.GdkTexture, lw: u16, lh: u16, is_shm: bool) void {
    if (self.widgets_dead) {
        c.g_object_unref(@ptrCast(tex));
        return;
    }
    if (lw != self.frame_lw or lh != self.frame_lh) {
        self.frame_lw = lw;
        self.frame_lh = lh;
        if (self.observed) self.layoutObserved() else c.gtk_widget_set_size_request(self.picture, lw, lh);
    }
    c.gtk_picture_set_paintable(@ptrCast(self.picture), @ptrCast(tex));
    if (self.tex_prev) |old| c.g_object_unref(@ptrCast(old));
    self.tex_prev = tex;
    self.tex_prev_is_shm = is_shm;
    self.snapAlignment();
    self.noteFrameGeometry();
    // A GdkTexture never invalidates itself (immutability contract),
    // and on the GPU path the SAME texture object is re-presented
    // over live pool memory — the explicit draw is what shows it.
    c.gtk_widget_queue_draw(self.picture);
}

/// Nudge the picture onto the device pixel grid. A GdkTexture whose
/// device size matches 1:1 still blurs completely when its origin
/// falls between device pixels (MEASURED: at 1.5x a half-pixel
/// offset turns a 1px-stripe texture into uniform gray), and GTK
/// margins are integer LOGICAL px — so the fix is the smallest
/// margin that lands the origin on the grid: at 1.5 it is 0 or 1,
/// at 1.25 up to 3. Input coordinates subtract `snap_dx/dy`.
pub fn snapAlignment(self: *WebFace) void {
    if (self.widgets_dead) return;
    // An observed frame is fitted, not pixel-snapped: its margins
    // are the letterbox offsets (`layoutObserved`).
    if (self.observed) return;
    const native = c.gtk_widget_get_native(self.view_area) orelse return;
    const surface = c.gtk_native_get_surface(native) orelse return;
    const scale = c.gdk_surface_get_scale(surface);
    if (!(scale > 0)) return;
    var sx: f64 = 0;
    var sy: f64 = 0;
    c.gtk_native_get_surface_transform(native, &sx, &sy);
    var src = c.graphene_point_t{ .x = 0, .y = 0 };
    var out: c.graphene_point_t = undefined;
    if (c.gtk_widget_compute_point(self.picture, @ptrCast(@alignCast(native)), &src, &out) == 0) return;
    const base_x = sx + @as(f64, out.x) - @as(f64, @floatFromInt(self.snap_dx));
    const base_y = sy + @as(f64, out.y) - @as(f64, @floatFromInt(self.snap_dy));
    const dx = snapDelta(base_x, scale);
    const dy = snapDelta(base_y, scale);
    if (dx == self.snap_dx and dy == self.snap_dy) return;
    self.snap_dx = dx;
    self.snap_dy = dy;
    c.gtk_widget_set_margin_start(self.picture, dx);
    c.gtk_widget_set_margin_top(self.picture, dy);
}

/// Smallest whole-logical-pixel nudge that puts `base * scale` on
/// an integer device coordinate (closest achievable otherwise).
pub fn snapDelta(base: f64, scale: f64) u16 {
    var best: u16 = 0;
    var best_err: f64 = 1e9;
    var d: u16 = 0;
    while (d < 8) : (d += 1) {
        const dev = (base + @as(f64, @floatFromInt(d))) * scale;
        const err = @abs(dev - @round(dev));
        if (err < best_err - 1e-9) {
            best_err = err;
            best = d;
            if (err < 1e-6) break;
        }
    }
    return best;
}

/// A GPU frame: wrap the engine's dma-buf as a `GdkDmabufTexture`
/// and hand it to the picture. GSK imports it (EGLImage on GL,
/// VkImage on Vulkan) and samples the engine's LIVE buffer — no
/// pixel is copied and none enters this process. Imports are cached
/// per pool buffer id, so a steady 100fps costs two or three
/// imports in total; the descriptors handed to GDK are dups closed
/// when it releases the texture, and the frame's own fds are closed
/// before this returns.
pub fn onDmabuf(self: *WebFace, f: proto.FrameDmabuf, fds: []const c_int) void {
    defer for (fds) |fd| {
        _ = c.close(fd);
    };
    if (self.widgets_dead) return;
    const stats = host_mod.g_stats.enabled();
    const t0 = if (stats) clock.nowNs() else 0;

    // Geometry changes retire the whole pool: a cached import is the
    // old size, and the ids start over.
    if (f.w != self.buf_w or f.h != self.buf_h) {
        self.clearDmabufCache();
        self.buf_w = f.w;
        self.buf_h = f.h;
    }

    var tex: ?*c.GdkTexture = null;
    for (&self.dmabuf_tex) |*e| {
        if (e.buf_id == f.buf_id and e.tex != null) {
            tex = e.tex;
            break;
        }
    }
    if (tex == null) tex = self.importDmabuf(f, fds);
    const t = tex orelse {
        // Not importable; the last frame stays up rather than a
        // black pane, and the next frame tries again.
        if (!self.dmabuf_import_warned) {
            self.dmabuf_import_warned = true;
            std.debug.print("webface: GDK could not import a dma-buf frame; page frozen on the GPU path\n", .{});
        }
        return;
    };
    _ = c.g_object_ref(@ptrCast(t));
    self.presentTexture(t, logicalOf(f.w, self.sent_scale), logicalOf(f.h, self.sent_scale), false);
    if (stats) {
        host_mod.g_stats.gpu_imports += 1;
        host_mod.g_stats.note(clock.nowNs() - t0, 0);
    }
    self.notePaint();
    self.clearStatus();
}

/// Build the `GdkDmabufTexture` for a pool buffer and cache it by
/// pool id (evicting the oldest slot). The dups handed to GDK are
/// closed by the texture's destroy notify.
pub fn importDmabuf(self: *WebFace, f: proto.FrameDmabuf, fds: []const c_int) ?*c.GdkTexture {
    if (self.widgets_dead or fds.len == 0 or f.w == 0 or f.h == 0) return null;
    const display = c.gtk_widget_get_display(self.view_area) orelse return null;
    const own = self.allocator.create(DmabufFds) catch return null;
    own.* = .{ .fds = @splat(-1), .n = 0, .allocator = self.allocator };
    const b = c.gdk_dmabuf_texture_builder_new() orelse {
        self.allocator.destroy(own);
        return null;
    };
    defer c.g_object_unref(@ptrCast(b));
    c.gdk_dmabuf_texture_builder_set_display(b, display);
    c.gdk_dmabuf_texture_builder_set_width(b, f.w);
    c.gdk_dmabuf_texture_builder_set_height(b, f.h);
    c.gdk_dmabuf_texture_builder_set_fourcc(b, f.fourcc);
    c.gdk_dmabuf_texture_builder_set_modifier(b, f.modifier);
    c.gdk_dmabuf_texture_builder_set_n_planes(b, f.nplanes);
    c.gdk_dmabuf_texture_builder_set_premultiplied(b, 1);
    var i: usize = 0;
    while (i < f.nplanes) : (i += 1) {
        const dup = c.fcntl(fds[i], c.F_DUPFD_CLOEXEC, @as(c_int, 3));
        if (dup < 0) {
            DmabufFds.destroy(own);
            return null;
        }
        own.fds[i] = dup;
        own.n += 1;
        c.gdk_dmabuf_texture_builder_set_fd(b, @intCast(i), dup);
        c.gdk_dmabuf_texture_builder_set_stride(b, @intCast(i), f.planes[i].stride);
        c.gdk_dmabuf_texture_builder_set_offset(b, @intCast(i), f.planes[i].offset);
    }
    var err: [*c]c.GError = null;
    const tex = c.gdk_dmabuf_texture_builder_build(b, DmabufFds.destroy, own, &err) orelse {
        if (err != null) c.g_error_free(err);
        // Build never ran the destroy notify; the dups are ours.
        DmabufFds.destroy(own);
        return null;
    };
    // Cache it: reuse this pool id's slot, else the first empty,
    // else evict slot 0 (pool ids cycle; eviction only costs a
    // re-import).
    var slot: usize = 0;
    var found = false;
    for (&self.dmabuf_tex, 0..) |*e, idx| {
        if (e.tex == null or e.buf_id == f.buf_id) {
            slot = idx;
            found = true;
            break;
        }
    }
    if (!found) slot = 0;
    if (self.dmabuf_tex[slot].tex) |old| c.g_object_unref(@ptrCast(old));
    self.dmabuf_tex[slot] = .{ .buf_id = f.buf_id, .tex = tex };
    return tex;
}

/// An inline frame (capability "frames-inline", remote helpers):
/// pixels arrived in-band, so the face materialises the buffer the
/// memfd path would have mapped — an anonymous mapping in the SAME
/// `MapRef` shape — decodes the damaged rects into it, and then
/// takes the ordinary `onDamage` presentation path (GSK uploads
/// only the damaged region, exactly as for shm frames).
pub fn onInline(self: *WebFace, fi: proto.FrameInline) void {
    if (self.widgets_dead) return;
    if (fi.w == 0 or fi.h == 0) return;
    const stride: u32 = @as(u32, fi.w) * 4;
    const size: usize = @as(usize, stride) * @as(usize, fi.h);
    const need_new = self.map == null or self.buf_w != fi.w or self.buf_h != fi.h;
    if (need_new) {
        const mref = webframe.mapAnon(self.allocator, size) orelse return;
        self.dropMap();
        self.map = mref;
        self.buf_w = fi.w;
        self.buf_h = fi.h;
        self.buf_stride = stride;
        // Local id only — the helper never announced this buffer, so
        // no frame_release goes back for it either.
        self.buf_id +%= 1;
        if (self.buf_id == 0) self.buf_id = 1;
        self.noteBufferGeometry(fi.w, fi.h);
    }
    const m = self.map orelse return;
    var rects_buf: [32]proto.Rect = undefined;
    var n: usize = 0;
    for (fi.rects) |r| {
        if (!webframe.decodeInlineRect(self.allocator, m, stride, fi.w, fi.h, r)) continue;
        if (n < rects_buf.len) {
            rects_buf[n] = .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
            n += 1;
        }
    }
    if (n == 0) return;
    // A fresh buffer has undefined pixels outside this frame's
    // rects; present the WHOLE surface once so nothing stale shows.
    if (need_new) {
        rects_buf[0] = .{ .x = 0, .y = 0, .w = fi.w, .h = fi.h };
        n = 1;
    }
    self.onDamage(.{
        .view = fi.view,
        .buf_id = self.buf_id,
        .gen = fi.gen,
        .rects = rects_buf[0..n],
    });
}

/// A software damage batch: wrap the mapping as a `GdkMemoryTexture`
/// whose `update_region` is exactly the damaged rects, diffed
/// against the previous frame's texture — GSK then uploads ONLY
/// those rects into its GPU copy. That is the damage-rect economy
/// the old GL pass had, now implemented by GTK. The `GBytes` holds a
/// reference on the mapping, so a buffer replacement can never pull
/// pages out from under a texture GSK still reads.
pub fn onDamage(self: *WebFace, dmg: proto.FrameDamage) void {
    if (self.widgets_dead) return;
    // A damage batch for a buffer we already replaced describes
    // pixels we no longer have; the new buffer repaints in full.
    if (dmg.buf_id != self.buf_id) return;
    const m = self.map orelse return;
    if (self.buf_w == 0 or self.buf_h == 0) return;
    const stats = host_mod.g_stats.enabled();
    const t0 = if (stats) clock.nowNs() else 0;

    var uploaded: usize = 0;
    var region: ?*c.cairo_region_t = null;
    defer if (region) |r| c.cairo_region_destroy(r);
    var update_tex: ?*c.GdkTexture = null;
    if (self.tex_prev != null and self.tex_prev_is_shm) {
        region = c.cairo_region_create();
        for (dmg.rects) |r| {
            var cr = c.cairo_rectangle_int_t{
                .x = r.x,
                .y = r.y,
                .width = r.w,
                .height = r.h,
            };
            _ = c.cairo_region_union_rectangle(region, &cr);
            uploaded += @as(usize, r.w) * @as(usize, r.h) * 4;
        }
        update_tex = self.tex_prev;
    } else {
        uploaded = m.len;
    }
    const tex = webframe.buildBgraTexture(m, self.buf_w, self.buf_h, self.buf_stride, update_tex, region) orelse return;
    const frame_scale = if (self.observed) self.obs_scale else self.sent_scale;
    self.presentTexture(tex, logicalOf(self.buf_w, frame_scale), logicalOf(self.buf_h, frame_scale), true);

    // Measurement harness: `SKETERM_WEB_DUMP=<path>` keeps writing
    // the engine's raw BGRA buffer (the pre-presentation ground
    // truth) to <path> plus a .txt with its geometry.
    if (c.getenv("SKETERM_WEB_DUMP")) |dp| {
        const path = std.mem.span(dp);
        if (c.fopen(path.ptr, "wb")) |f| {
            _ = c.fwrite(m.ptr, 1, m.len, f);
            _ = c.fclose(f);
        }
        var meta_buf: [512]u8 = undefined;
        if (std.fmt.bufPrintZ(&meta_buf, "{s}.txt", .{path}) catch null) |mp| {
            if (c.fopen(mp.ptr, "wb")) |f| {
                var line: [128]u8 = undefined;
                const t = std.fmt.bufPrint(&line, "{d} {d} {d}\n", .{ self.buf_w, self.buf_h, self.buf_stride }) catch "";
                _ = c.fwrite(t.ptr, 1, t.len, f);
                _ = c.fclose(f);
            }
        }
    }
    self.probeMapping(m);
    self.notePaint();
    self.clearStatus();
    if (stats) host_mod.g_stats.note(clock.nowNs() - t0, uploaded);
}
