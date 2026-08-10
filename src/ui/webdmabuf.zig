//! Importing a browser helper's GPU frames (`frame_dmabuf`, capability
//! "frames-dmabuf") into a GL texture the web face can draw, without
//! copying the pixels.
//!
//! ## Why an EGLImage and not a GdkDmabufTexture
//!
//! The web face already owns a `GtkGLArea` and draws its frames through
//! `render/web_pass.zig` — that is what turned a 33 MB whole-surface
//! upload per frame into a 16 KB damage rect on the software path. A
//! `GdkDmabufTexture` would hand the frame to GSK instead, which means a
//! second widget (`GtkPicture`), a second presentation path, and two
//! copies of every lifetime rule. Importing the dma-buf INTO THE AREA'S
//! OWN CONTEXT keeps one widget, one pass and one draw: `eglCreateImage`
//! with `EGL_LINUX_DMA_BUF_EXT`, `glEGLImageTargetTexture2DOES` onto a
//! texture name, and `WebPass.showExternal`.
//!
//! ## The three things that make this correct
//!
//! DESCRIPTOR OWNERSHIP is simple here, and that is the point.
//! `EGL_EXT_image_dma_buf_import` says EGL does not take ownership of
//! the descriptors: they are consumed by `eglCreateImage` and may be
//! closed straight after. So nothing here outlives its call — no
//! destroy notify, no heap-allocated fd owner, no "GDK will get round
//! to it" — and the CALLER closes the descriptors once, after both this
//! and the mapped fallback have had their turn.
//!
//! POOL IDENTITY. The engine renders into a small pool and cycles
//! through it, so the same underlying buffer comes back every few
//! frames. `buf_id` names the buffer rather than the paint, and the
//! cache keys imports on it: a steady-state animating page imports two
//! or three textures in total instead of one per frame. A frame whose
//! buffer is already imported costs a `close` per plane and a texture
//! rebind.
//!
//! CONTEXT LIFETIME. Every image and texture here belongs to the area's
//! `GdkGLContext`, which is destroyed and rebuilt whenever the pane is
//! reparented (see `terminal_surface.zig onRealize` for the same rule).
//! `clear` deletes them and needs that context current; `forgetGL` drops
//! the handles without touching a context that is already gone. Both are
//! wired to the area's realize/unrealize exactly like `WebPass`.
//!
//! ## Fallback
//!
//! `acquire` returns null when there is no EGL at all (GLX-backed GDK),
//! when the driver cannot import the modifier the engine allocated, when
//! GPU frames are switched off, or when `SKETERM_WEB_DMABUF_IMPORT=0`
//! refuses every import so the fallback itself can be exercised. The face then MAPS the buffer and
//! uploads it through the same `WebPass` texture the memfd path uses —
//! `mapLinear` here, `uploadRect` there — which costs what the software
//! path costs and is never a black pane. That only works for a single
//! linear plane, which is what CEF produces; anything else leaves the
//! last frame on screen.

const std = @import("std");
const c = @import("../c.zig").c;
const proto = @import("../web/protocol.zig");

/// DRM_FORMAT_MOD_LINEAR: no tiling, so a CPU mapping of the buffer is
/// plain rows of pixels.
pub const MOD_LINEAR: u64 = 0;
/// The "driver picks" sentinel; the modifier attributes are then omitted
/// from the image rather than sent as a real value.
pub const MOD_INVALID: u64 = 0x00ff_ffff_ffff_ffff;

const FOURCC_ARGB8888: u32 = fourcc('A', 'R', '2', '4');
const FOURCC_ABGR8888: u32 = fourcc('A', 'B', '2', '4');
const FOURCC_XRGB8888: u32 = fourcc('X', 'R', '2', '4');

fn fourcc(a: u8, b: u8, c0: u8, d: u8) u32 {
    return @as(u32, a) | (@as(u32, b) << 8) | (@as(u32, c0) << 16) | (@as(u32, d) << 24);
}

/// Whether the imported bytes are BGRA and so need `WebPass`'s B/R swap.
/// Only relevant for the MAPPED fallback: a real EGL import is described
/// to the driver by its FourCC, so sampling already yields the right
/// components.
fn mappedIsBgra(f4cc: u32) ?bool {
    return switch (f4cc) {
        FOURCC_ARGB8888, FOURCC_XRGB8888 => true,
        FOURCC_ABGR8888 => false,
        else => null,
    };
}

/// Whether GPU frames are wanted at all. `SKETERM_WEB_GPU=0` is the same
/// switch the helper reads, so one variable turns the whole path off on
/// both sides of the socket.
pub fn gpuEnabled() bool {
    const v = c.getenv("SKETERM_WEB_GPU") orelse return true;
    const s = std.mem.span(v);
    return !(std.mem.eql(u8, s, "0") or std.mem.eql(u8, s, "off") or std.mem.eql(u8, s, "no"));
}

// ---------------------------------------------------------------------
// EGL, resolved at runtime
// ---------------------------------------------------------------------
//
// Runtime-loaded rather than linked, for the same reason
// `src/mux/dmabuf_egl.zig` does it: an absent or ancient libEGL must
// degrade to the software path, not fail to start the GUI. The types
// are spelled out here because `vendor/cimport_root.h` deliberately
// carries no EGL headers.

const EglBoolean = c_uint;
const EglInt = i32;
const EglEnum = c_uint;
const EglDisplay = ?*anyopaque;
const EglContext = ?*anyopaque;
const EglImage = ?*anyopaque;
const EglClientBuffer = ?*anyopaque;

const EGL_FALSE: EglBoolean = 0;
const EGL_NONE: EglInt = 0x3038;
const EGL_EXTENSIONS: EglInt = 0x3055;
const EGL_LINUX_DMA_BUF_EXT: EglEnum = 0x3270;
const EGL_WIDTH: EglInt = 0x3057;
const EGL_HEIGHT: EglInt = 0x3056;
const EGL_LINUX_DRM_FOURCC_EXT: EglInt = 0x3271;

const EGL_DMA_BUF_PLANE_FD = [_]EglInt{ 0x3272, 0x3275, 0x3278, 0x3440 };
const EGL_DMA_BUF_PLANE_OFFSET = [_]EglInt{ 0x3273, 0x3276, 0x3279, 0x3441 };
const EGL_DMA_BUF_PLANE_PITCH = [_]EglInt{ 0x3274, 0x3277, 0x327A, 0x3442 };
const EGL_DMA_BUF_PLANE_MOD_LO = [_]EglInt{ 0x3443, 0x3445, 0x3447, 0x3449 };
const EGL_DMA_BUF_PLANE_MOD_HI = [_]EglInt{ 0x3444, 0x3446, 0x3448, 0x344A };

const GetCurrentDisplay = *const fn () callconv(.c) EglDisplay;
const QueryString = *const fn (EglDisplay, EglInt) callconv(.c) ?[*:0]const u8;
const GetProcAddress = *const fn ([*:0]const u8) callconv(.c) ?*anyopaque;
const CreateImage = *const fn (EglDisplay, EglContext, EglEnum, EglClientBuffer, [*]const EglInt) callconv(.c) EglImage;
const DestroyImage = *const fn (EglDisplay, EglImage) callconv(.c) EglBoolean;
const ImageTargetTexture = *const fn (c_uint, EglImage) callconv(.c) void;

extern fn dlopen(filename: [*:0]const u8, flags: c_int) ?*anyopaque;
extern fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;

const RTLD_LAZY: c_int = 0x1;
const RTLD_LOCAL: c_int = 0;

const Egl = struct {
    get_current_display: GetCurrentDisplay,
    query_string: QueryString,
    create_image: CreateImage,
    destroy_image: DestroyImage,
    image_target_texture: ImageTargetTexture,
};

var g_egl: ?Egl = null;
var g_egl_tried: bool = false;

fn symbol(comptime T: type, handle: ?*anyopaque, name: [*:0]const u8) ?T {
    return @ptrCast(@alignCast(dlsym(handle, name) orelse return null));
}

/// The EGL entry points, loaded once. Null means this GUI cannot import
/// dma-bufs at all (no libEGL, or a GDK that realized a GLX context).
fn egl() ?*const Egl {
    if (g_egl_tried) return if (g_egl) |*e| e else null;
    g_egl_tried = true;
    if (!gpuEnabled()) return null;
    const handle = dlopen("libEGL.so.1", RTLD_LAZY | RTLD_LOCAL) orelse
        dlopen("libEGL.so", RTLD_LAZY | RTLD_LOCAL) orelse return null;
    const get_proc = symbol(GetProcAddress, handle, "eglGetProcAddress") orelse return null;
    const resolve = struct {
        fn f(comptime T: type, h: ?*anyopaque, gp: GetProcAddress, name: [*:0]const u8) ?T {
            const addr = dlsym(h, name) orelse gp(name) orelse return null;
            return @ptrCast(@alignCast(addr));
        }
    }.f;
    g_egl = .{
        .get_current_display = symbol(GetCurrentDisplay, handle, "eglGetCurrentDisplay") orelse return null,
        .query_string = symbol(QueryString, handle, "eglQueryString") orelse return null,
        // The KHR spelling is the one every driver ships; EGL 1.5's
        // `eglCreateImage` takes EGLAttrib (isize) parameters instead,
        // so the two are NOT interchangeable behind one signature.
        .create_image = resolve(CreateImage, handle, get_proc, "eglCreateImageKHR") orelse return null,
        .destroy_image = resolve(DestroyImage, handle, get_proc, "eglDestroyImageKHR") orelse return null,
        .image_target_texture = resolve(ImageTargetTexture, handle, get_proc, "glEGLImageTargetTexture2DOES") orelse return null,
    };
    return if (g_egl) |*e| e else null;
}

var g_refuse: struct { on: bool = false, checked: bool = false } = .{};

/// Whether EGL import is refused outright — the test lever for the
/// mapped fallback, checked once.
fn importRefused() bool {
    if (!g_refuse.checked) {
        g_refuse.checked = true;
        if (c.getenv("SKETERM_WEB_DMABUF_IMPORT")) |v| {
            const s = std.mem.span(v);
            g_refuse.on = std.mem.eql(u8, s, "0") or std.mem.eql(u8, s, "off") or std.mem.eql(u8, s, "no");
        }
    }
    return g_refuse.on;
}

fn hasExtension(list: []const u8, wanted: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, list, ' ');
    while (it.next()) |e| {
        if (std.mem.eql(u8, e, wanted)) return true;
    }
    return false;
}

/// The display the CURRENT context belongs to, once it is known to
/// support dma-buf import. Null on a GLX context or a driver without the
/// extension, which is the software path's cue.
fn currentDisplay(e: *const Egl) EglDisplay {
    const dpy = e.get_current_display();
    if (dpy == null) return null;
    const exts_z = e.query_string(dpy, EGL_EXTENSIONS) orelse return null;
    if (!hasExtension(std.mem.span(exts_z), "EGL_EXT_image_dma_buf_import")) return null;
    return dpy;
}

/// The `EGL_LINUX_DMA_BUF_EXT` attribute list for `f`. `fds` may be
/// empty, which describes the same layout with placeholder descriptors
/// — that is how the layout is tested without a driver.
fn buildAttributes(f: proto.FrameDmabuf, fds: []const c_int, attrs: *[48]EglInt) []const EglInt {
    var n: usize = 0;
    const add = struct {
        fn pair(storage: *[48]EglInt, index: *usize, key: EglInt, value: EglInt) void {
            storage[index.*] = key;
            storage[index.* + 1] = value;
            index.* += 2;
        }
    }.pair;
    add(attrs, &n, EGL_WIDTH, @intCast(f.w));
    add(attrs, &n, EGL_HEIGHT, @intCast(f.h));
    add(attrs, &n, EGL_LINUX_DRM_FOURCC_EXT, @bitCast(f.fourcc));
    for (f.planes[0..f.nplanes], 0..) |p, i| {
        add(attrs, &n, EGL_DMA_BUF_PLANE_FD[i], if (i < fds.len) fds[i] else -1);
        add(attrs, &n, EGL_DMA_BUF_PLANE_OFFSET[i], @bitCast(p.offset));
        add(attrs, &n, EGL_DMA_BUF_PLANE_PITCH[i], @bitCast(p.stride));
        if (f.modifier != MOD_INVALID) {
            add(attrs, &n, EGL_DMA_BUF_PLANE_MOD_LO[i], @bitCast(@as(u32, @truncate(f.modifier))));
            add(attrs, &n, EGL_DMA_BUF_PLANE_MOD_HI[i], @bitCast(@as(u32, @truncate(f.modifier >> 32))));
        }
    }
    attrs[n] = EGL_NONE;
    return attrs[0 .. n + 1];
}

/// Import counters, for the same `SKETERM_WEB_STATS=1` line the memfd
/// path already prints. `copied` staying above zero is the visible
/// symptom of a driver that cannot import what the engine allocates.
pub const Stats = struct {
    imported: u32 = 0,
    copied: u32 = 0,
};

/// A CPU mapping of a linear single-plane dma-buf, for the fallback.
/// Owns the mapping; `unmap` when the frame has been uploaded.
pub const Mapping = struct {
    base: [*]align(std.heap.page_size_min) u8,
    len: usize,
    /// Where the pixels start inside the mapping, and their row pitch.
    pixels: [*]const u8,
    stride: u32,
    /// Whether the bytes are BGRA (`WebPass.showOwned`'s argument).
    bgra: bool,

    pub fn unmap(self: *const Mapping) void {
        _ = c.munmap(self.base, self.len);
    }
};

/// Map plane 0 so the caller can upload it like a memfd frame. Only
/// LINEAR single-plane buffers can be read this way; a tiled one has no
/// meaningful CPU layout and returns null.
pub fn mapLinear(f: proto.FrameDmabuf, fd: c_int) ?Mapping {
    if (f.nplanes != 1) return null;
    if (f.modifier != MOD_LINEAR and f.modifier != MOD_INVALID) return null;
    const bgra = mappedIsBgra(f.fourcc) orelse return null;
    const len: usize = @as(usize, f.planes[0].stride) * @as(usize, f.h) + f.planes[0].offset;
    if (len == 0) return null;
    const addr = c.mmap(null, len, c.PROT_READ, c.MAP_SHARED, fd, 0);
    if (addr == c.MAP_FAILED) return null;
    const base: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(addr));
    return .{
        .base = base,
        .len = len,
        .pixels = base + f.planes[0].offset,
        .stride = f.planes[0].stride,
        .bgra = bgra,
    };
}

// ---------------------------------------------------------------------
// The per-face import cache
// ---------------------------------------------------------------------

/// The GL texture + EGLImage built over each pool buffer, keyed on the
/// helper's `buf_id`, so the NEXT frame out of that buffer is a bind
/// rather than an import.
///
/// Small and linear on purpose: a scan is not worth a hash table at this
/// size. SIXTEEN entries rather than the pool's own depth, because that
/// depth is not a constant — the pinned CEF cycles 2-3 buffers per view
/// where the distro build was measured cycling 11, and a table smaller
/// than the live pool degrades to an import per frame instead of one per
/// buffer.
pub const Cache = struct {
    pub const SIZE = 16;

    const Entry = struct {
        buf_id: u32 = 0,
        image: EglImage = null,
        tex: c_uint = 0,
        seen: u64 = 0,
    };

    entries: [SIZE]Entry = @splat(.{}),
    clock: u64 = 0,

    /// Import `f`'s planes as a GL texture in the CURRENT context, or
    /// return the one already built over this pool buffer. `fds` are
    /// BORROWED: EGL keeps no reference to them, and closing them is the
    /// caller's job on every path.
    ///
    /// Null means the caller should fall back to `mapLinear` + an
    /// ordinary upload.
    pub fn acquire(self: *Cache, f: proto.FrameDmabuf, fds: []const c_int) ?c_uint {
        // `SKETERM_WEB_DMABUF_IMPORT=0` refuses every import so the
        // MAPPED fallback below can be exercised on a machine whose
        // driver imports everything happily. A fallback nobody has ever
        // run is not a fallback.
        if (importRefused()) return null;
        if (fds.len != f.nplanes or f.nplanes == 0 or f.nplanes > proto.MAX_PLANES) return null;
        if (self.get(f.buf_id)) |tex| return tex;
        const e = egl() orelse return null;
        const dpy = currentDisplay(e) orelse return null;

        var attrs_storage: [48]EglInt = undefined;
        const attrs = buildAttributes(f, fds, &attrs_storage);
        const image = e.create_image(dpy, null, EGL_LINUX_DMA_BUF_EXT, null, attrs.ptr);
        if (image == null) return null;

        var tex: c_uint = 0;
        c.glGenTextures(1, &tex);
        if (tex == 0) {
            _ = e.destroy_image(dpy, image);
            return null;
        }
        c.glBindTexture(c.GL_TEXTURE_2D, tex);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
        while (c.glGetError() != c.GL_NO_ERROR) {}
        e.image_target_texture(c.GL_TEXTURE_2D, image);
        if (c.glGetError() != c.GL_NO_ERROR) {
            c.glDeleteTextures(1, &tex);
            _ = e.destroy_image(dpy, image);
            return null;
        }
        self.put(f.buf_id, image, tex);
        return tex;
    }

    fn get(self: *Cache, buf_id: u32) ?c_uint {
        self.clock += 1;
        for (&self.entries) |*e| {
            if (e.buf_id != buf_id or e.tex == 0) continue;
            e.seen = self.clock;
            return e.tex;
        }
        return null;
    }

    fn put(self: *Cache, buf_id: u32, image: EglImage, tex: c_uint) void {
        var lru: usize = 0;
        for (&self.entries, 0..) |*e, i| {
            if (e.tex == 0) {
                lru = i;
                break;
            }
            if (e.seen < self.entries[lru].seen) lru = i;
        }
        self.destroyEntry(&self.entries[lru]);
        self.clock += 1;
        self.entries[lru] = .{ .buf_id = buf_id, .image = image, .tex = tex, .seen = self.clock };
    }

    fn destroyEntry(self: *Cache, e: *Entry) void {
        _ = self;
        if (e.tex != 0) {
            var t = e.tex;
            c.glDeleteTextures(1, &t);
        }
        if (e.image != null) {
            if (egl()) |api| {
                const dpy = api.get_current_display();
                if (dpy != null) _ = api.destroy_image(dpy, e.image);
            }
        }
        e.* = .{};
    }

    /// Drop every import, deleting the GL objects. A resize retires the
    /// whole pool, and so does tearing the face down. REQUIRES the
    /// area's context to be current.
    pub fn clear(self: *Cache) void {
        for (&self.entries) |*e| self.destroyEntry(e);
    }

    /// Drop the handles WITHOUT deleting them: their context is already
    /// gone (a reparent unrealized the area), so deleting would touch a
    /// dead context or, worse, a name that now belongs to somebody else.
    pub fn forgetGL(self: *Cache) void {
        self.entries = @splat(.{});
    }
};

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

fn testFrame(nplanes: u8, modifier: u64) proto.FrameDmabuf {
    return .{
        .view = 1,
        .buf_id = 1,
        .gen = 1,
        .w = 16,
        .h = 8,
        .fourcc = FOURCC_ARGB8888,
        .modifier = modifier,
        .nplanes = nplanes,
        .planes = .{
            .{ .stride = 64, .offset = 0 },
            .{ .stride = 32, .offset = 4096 },
            .{ .stride = 0, .offset = 0 },
            .{ .stride = 0, .offset = 0 },
        },
    };
}

test "an explicit modifier rides both 32-bit halves, per plane" {
    var storage: [48]EglInt = undefined;
    const attrs = buildAttributes(testFrame(1, 0x0123_4567_89ab_cdef), &.{}, &storage);
    // width, height, fourcc, then fd/offset/pitch/mod-lo/mod-hi.
    try std.testing.expectEqual(@as(usize, 3 * 2 + 5 * 2 + 1), attrs.len);
    try std.testing.expectEqual(EGL_DMA_BUF_PLANE_MOD_LO[0], attrs[12]);
    try std.testing.expectEqual(@as(EglInt, @bitCast(@as(u32, 0x89ab_cdef))), attrs[13]);
    try std.testing.expectEqual(EGL_DMA_BUF_PLANE_MOD_HI[0], attrs[14]);
    try std.testing.expectEqual(@as(EglInt, 0x0123_4567), attrs[15]);
    try std.testing.expectEqual(EGL_NONE, attrs[attrs.len - 1]);
}

test "the driver-picks sentinel omits the modifier attributes entirely" {
    var storage: [48]EglInt = undefined;
    const attrs = buildAttributes(testFrame(1, MOD_INVALID), &.{}, &storage);
    try std.testing.expectEqual(@as(usize, 3 * 2 + 3 * 2 + 1), attrs.len);
    for (attrs) |a| try std.testing.expect(a != EGL_DMA_BUF_PLANE_MOD_LO[0]);
}

test "every plane gets its own fd, offset and pitch attributes" {
    var storage: [48]EglInt = undefined;
    const attrs = buildAttributes(testFrame(2, MOD_LINEAR), &.{}, &storage);
    try std.testing.expectEqual(@as(usize, 3 * 2 + 2 * 5 * 2 + 1), attrs.len);
    try std.testing.expectEqual(EGL_DMA_BUF_PLANE_FD[1], attrs[16]);
    try std.testing.expectEqual(EGL_DMA_BUF_PLANE_OFFSET[1], attrs[18]);
    try std.testing.expectEqual(@as(EglInt, 4096), attrs[19]);
    try std.testing.expectEqual(EGL_DMA_BUF_PLANE_PITCH[1], attrs[20]);
    try std.testing.expectEqual(@as(EglInt, 32), attrs[21]);
}

test "the mapped fallback knows which FourCCs it can describe" {
    try std.testing.expectEqual(@as(?bool, true), mappedIsBgra(FOURCC_ARGB8888));
    try std.testing.expectEqual(@as(?bool, false), mappedIsBgra(FOURCC_ABGR8888));
    try std.testing.expectEqual(@as(?bool, null), mappedIsBgra(fourcc('N', 'V', '1', '2')));
}

test "a cached buffer id answers without importing, and the LRU is evicted" {
    // The GL side is never touched by get/put bookkeeping, so it is
    // testable without a context as long as nothing is destroyed.
    var cache = Cache{};
    for (0..Cache.SIZE) |i| {
        cache.entries[i] = .{ .buf_id = @intCast(i + 1), .tex = @intCast(i + 1), .seen = i + 1 };
    }
    cache.clock = Cache.SIZE;
    try std.testing.expectEqual(@as(?c_uint, 1), cache.get(1));
    try std.testing.expect(cache.get(99) == null);
    // id 2 is now the coldest, since 1 was just touched.
    var lru: usize = 0;
    for (&cache.entries, 0..) |*e, i| {
        if (e.seen < cache.entries[lru].seen) lru = i;
    }
    try std.testing.expectEqual(@as(u32, 2), cache.entries[lru].buf_id);

    cache.forgetGL();
    for (cache.entries) |e| try std.testing.expectEqual(@as(c_uint, 0), e.tex);
}
