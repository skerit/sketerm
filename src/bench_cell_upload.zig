//! Headless cell-pipeline benchmark — measures `cell_pass.rebuildAndUpload`
//! + `cell_pass.draw` per-iteration latency on an EGL surfaceless context.
//!
//! Purpose: isolate the GL-side cost of the streaming-instance upload
//! pattern from GTK4's GtkGLArea + Wayland compositing layer. Both run
//! on the same Mesa driver against the same GPU, so if this bench is
//! fast (sub-millisecond) and interactive sketerm is slow (multi-
//! millisecond), the bottleneck is the GTK4 / Wayland integration —
//! not our buffer upload pattern.
//!
//! Usage: `zig build bench-cell-upload`. Prints per-stage stats to
//! stderr on exit.
//!
//! The render dimensions and screen size mimic a maximised 4K HiDPI
//! window: 3840×2160 framebuffer, 100×60 cell grid. Each iteration
//! marks every visible row dirty (the worst case — full screen
//! refresh) so the upload path is fully exercised.

const std = @import("std");
const c = @import("c.zig").c;
const Atlas = @import("render/atlas.zig").Atlas;
const CellPass = @import("render/cell_pass.zig").CellPass;
const Screen = @import("grid/screen.zig").Screen;
const StylePool = @import("grid/style_pool.zig").Pool;

const c_egl = @cImport({
    @cInclude("epoxy/egl.h");
});

const FONT_CANDIDATES = [_][*:0]const u8{
    "/usr/share/fonts/TTF/Hack-Regular.ttf",
    "/usr/share/fonts/Adwaita/AdwaitaMono-Regular.ttf",
    "/usr/share/fonts/TTF/VeraMono.ttf",
    "/usr/share/fonts/gnu-free/FreeMono.otf",
    "/usr/share/fonts/dejavu/DejaVuSansMono.ttf",
    "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
    "/usr/share/fonts/noto/NotoSansMono-Regular.ttf",
};

const W: c_int = 3840;
const H: c_int = 2160;
const FONT_SIZE: u16 = 32;
const COLS: u16 = 100;
const ROWS: u16 = 60;
const ITERATIONS: usize = 500;
const WARMUP: usize = 20;

pub fn main() !u8 {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // EGL surfaceless context (same setup as smoke-cell).
    const display = blk: {
        const eglGetPlatformDisplayEXT_addr = c_egl.eglGetProcAddress("eglGetPlatformDisplayEXT");
        if (eglGetPlatformDisplayEXT_addr) |p| {
            const fn_ptr: *const fn (c_uint, ?*anyopaque, ?[*]const c_egl.EGLint) callconv(.c) c_egl.EGLDisplay = @ptrCast(@alignCast(p));
            const PLATFORM_SURFACELESS_MESA: c_uint = 0x31DD;
            const d = fn_ptr(PLATFORM_SURFACELESS_MESA, null, null);
            if (d != null and d != c_egl.EGL_NO_DISPLAY) break :blk d;
        }
        break :blk c_egl.eglGetDisplay(c_egl.EGL_DEFAULT_DISPLAY);
    };
    if (display == c_egl.EGL_NO_DISPLAY) return 1;
    var major: c_egl.EGLint = 0;
    var minor: c_egl.EGLint = 0;
    if (c_egl.eglInitialize(display, &major, &minor) == c_egl.EGL_FALSE) return 1;
    if (c_egl.eglBindAPI(c_egl.EGL_OPENGL_ES_API) == c_egl.EGL_FALSE) return 1;

    const cfg_attribs = [_]c_egl.EGLint{
        c_egl.EGL_RED_SIZE, 8, c_egl.EGL_GREEN_SIZE, 8, c_egl.EGL_BLUE_SIZE, 8, c_egl.EGL_ALPHA_SIZE, 8,
        c_egl.EGL_RENDERABLE_TYPE, c_egl.EGL_OPENGL_ES3_BIT,
        c_egl.EGL_SURFACE_TYPE, c_egl.EGL_PBUFFER_BIT,
        c_egl.EGL_NONE,
    };
    var cfg: c_egl.EGLConfig = null;
    var n_cfg: c_egl.EGLint = 0;
    if (c_egl.eglChooseConfig(display, &cfg_attribs, &cfg, 1, &n_cfg) == c_egl.EGL_FALSE or n_cfg < 1) return 1;
    const ctx_attribs = [_]c_egl.EGLint{ c_egl.EGL_CONTEXT_MAJOR_VERSION, 3, c_egl.EGL_CONTEXT_MINOR_VERSION, 0, c_egl.EGL_NONE };
    const ctx = c_egl.eglCreateContext(display, cfg, c_egl.EGL_NO_CONTEXT, &ctx_attribs);
    if (ctx == c_egl.EGL_NO_CONTEXT) return 1;
    if (c_egl.eglMakeCurrent(display, c_egl.EGL_NO_SURFACE, c_egl.EGL_NO_SURFACE, ctx) == c_egl.EGL_FALSE) return 1;

    std.debug.print("bench-cell-upload: GL_VENDOR={s}\n", .{c.glGetString(c.GL_VENDOR)});
    std.debug.print("bench-cell-upload: GL_RENDERER={s}\n", .{c.glGetString(c.GL_RENDERER)});
    std.debug.print("bench-cell-upload: GL_VERSION={s}\n", .{c.glGetString(c.GL_VERSION)});
    std.debug.print("bench-cell-upload: framebuffer = {d}x{d}, grid = {d}x{d}, font_size = {d}px\n",
        .{ W, H, COLS, ROWS, FONT_SIZE });

    // Offscreen FBO at 4K to mimic real conditions.
    var fbo: c_uint = 0;
    var rbo: c_uint = 0;
    c.glGenFramebuffers(1, &fbo);
    c.glBindFramebuffer(c.GL_FRAMEBUFFER, fbo);
    c.glGenRenderbuffers(1, &rbo);
    c.glBindRenderbuffer(c.GL_RENDERBUFFER, rbo);
    c.glRenderbufferStorage(c.GL_RENDERBUFFER, c.GL_RGBA8, W, H);
    c.glFramebufferRenderbuffer(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_RENDERBUFFER, rbo);
    if (c.glCheckFramebufferStatus(c.GL_FRAMEBUFFER) != c.GL_FRAMEBUFFER_COMPLETE) return 1;
    c.glViewport(0, 0, W, H);

    // Atlas.
    var atlas: ?*Atlas = null;
    for (FONT_CANDIDATES) |path| {
        if (Atlas.init(allocator, path, FONT_SIZE)) |a| {
            atlas = a;
            break;
        } else |_| continue;
    }
    if (atlas == null) {
        std.debug.print("bench-cell-upload: no font found\n", .{});
        return 1;
    }
    defer atlas.?.deinit();
    atlas.?.realize();

    var pool = try StylePool.init(allocator);
    defer pool.deinit();
    const screen = try Screen.init(allocator, &pool, COLS, ROWS);
    defer screen.deinit();

    // Fill the screen with htop-ish content: a colourful header row +
    // many rows of column-formatted text. Use SGR so we exercise the
    // styled-cell path (multiple style_refs per row, cache misses
    // inside the inner loop).
    var parser = @import("parser/vt.zig").Parser.init(allocator);
    defer parser.deinit();
    const Ctx = struct {
        screen: *Screen,
        allocator: std.mem.Allocator,
    };
    const Emit = struct {
        fn cb(user: ?*anyopaque, ev: @import("parser/event.zig").Event) void {
            const ec: *Ctx = @ptrCast(@alignCast(user.?));
            var mut_ev = ev;
            ec.screen.apply(ev);
            mut_ev.deinit(ec.allocator);
        }
    };
    var ec = Ctx{ .screen = screen, .allocator = allocator };

    // Build htop-shaped content into a buffer and feed it once for warmup.
    var content: std.ArrayList(u8) = .{};
    defer content.deinit(allocator);
    try content.appendSlice(allocator, "\x1b[2J\x1b[H");
    // Green-bg header.
    try content.appendSlice(allocator, "\x1b[42;30m");
    var hi: u16 = 0;
    while (hi < COLS) : (hi += 1) try content.append(allocator, 'H');
    try content.appendSlice(allocator, "\x1b[0m\r\n");
    var r: u16 = 1;
    while (r < ROWS) : (r += 1) {
        // Mix of plain + colored cells.
        try content.appendSlice(allocator, "\x1b[36m");
        try content.appendSlice(allocator, "12345 user      ");
        try content.appendSlice(allocator, "\x1b[33m");
        try content.appendSlice(allocator, "20 ");
        try content.appendSlice(allocator, "\x1b[31m");
        try content.appendSlice(allocator, "  4567 ");
        try content.appendSlice(allocator, "\x1b[0m");
        try content.appendSlice(allocator, "  process_name_here    ");
        // Pad to COLS.
        const used: u16 = @min(COLS, 50);
        var pad: u16 = used;
        while (pad < COLS) : (pad += 1) try content.append(allocator, ' ');
        try content.appendSlice(allocator, "\r\n");
    }
    parser.advance(content.items, Emit.cb, @ptrCast(&ec));

    var cell_pass = CellPass.init(allocator);
    defer cell_pass.deinit();
    try cell_pass.realize();

    // Warmup: fully populate atlas + run a few cycles so glyph
    // rasterization isn't on the critical path.
    var w: usize = 0;
    while (w < WARMUP) : (w += 1) {
        markAllRowsDirty(screen);
        try cell_pass.rebuildAndUpload(screen, &pool, atlas.?);
        cell_pass.draw(atlas.?, W, H);
        c.glFinish();
    }

    // Per-iteration timings — same operations the interactive render path runs.
    var t_rebuild = std.array_list.Aligned(u64, null){};
    defer t_rebuild.deinit(allocator);
    var t_upload_only = std.array_list.Aligned(u64, null){};
    defer t_upload_only.deinit(allocator);
    var t_draw = std.array_list.Aligned(u64, null){};
    defer t_draw.deinit(allocator);
    var t_finish = std.array_list.Aligned(u64, null){};
    defer t_finish.deinit(allocator);
    var t_total = std.array_list.Aligned(u64, null){};
    defer t_total.deinit(allocator);
    try t_rebuild.ensureTotalCapacity(allocator, ITERATIONS);
    try t_upload_only.ensureTotalCapacity(allocator, ITERATIONS);
    try t_draw.ensureTotalCapacity(allocator, ITERATIONS);
    try t_finish.ensureTotalCapacity(allocator, ITERATIONS);
    try t_total.ensureTotalCapacity(allocator, ITERATIONS);

    var i: usize = 0;
    while (i < ITERATIONS) : (i += 1) {
        markAllRowsDirty(screen);

        const t0 = std.time.nanoTimestamp();
        // rebuildAndUpload includes the CPU loop AND the GL upload.
        try cell_pass.rebuildAndUpload(screen, &pool, atlas.?);
        const t1 = std.time.nanoTimestamp();
        cell_pass.draw(atlas.?, W, H);
        const t2 = std.time.nanoTimestamp();
        c.glFinish();
        const t3 = std.time.nanoTimestamp();

        try t_rebuild.append(allocator, @intCast(t1 - t0));
        try t_draw.append(allocator, @intCast(t2 - t1));
        try t_finish.append(allocator, @intCast(t3 - t2));
        try t_total.append(allocator, @intCast(t3 - t0));
    }

    summarize("rebuildAndUpload (CPU loop + GL upload)", t_rebuild.items);
    summarize("cell_pass.draw    (GL draw issue)        ", t_draw.items);
    summarize("glFinish          (GPU sync)             ", t_finish.items);
    summarize("total per iter    (rebuild+draw+finish)  ", t_total.items);

    return 0;
}

fn markAllRowsDirty(screen: *Screen) void {
    const buf = if (screen.use_alt) screen.alt.? else screen.active;
    for (buf) |*ln| ln.dirty = true;
    screen.dirty = true;
}

fn summarize(label: []const u8, samples: []const u64) void {
    if (samples.len == 0) return;
    var sum: u128 = 0;
    var min_v: u64 = std.math.maxInt(u64);
    var max_v: u64 = 0;
    for (samples) |s| {
        sum += s;
        if (s < min_v) min_v = s;
        if (s > max_v) max_v = s;
    }
    const avg = @as(u64, @intCast(sum / @as(u128, samples.len)));
    // Sort a copy for percentiles.
    const sorted = std.heap.page_allocator.alloc(u64, samples.len) catch return;
    defer std.heap.page_allocator.free(sorted);
    @memcpy(sorted, samples);
    std.mem.sort(u64, sorted, {}, std.sort.asc(u64));
    const p50 = sorted[samples.len / 2];
    const p99 = sorted[@min(samples.len - 1, (samples.len * 99) / 100)];
    std.debug.print("bench-cell-upload: {s}: n={d} avg={d:.1}us p50={d:.1}us p99={d:.1}us min={d:.1}us max={d:.1}us\n", .{
        label,
        samples.len,
        @as(f64, @floatFromInt(avg)) / 1000.0,
        @as(f64, @floatFromInt(p50)) / 1000.0,
        @as(f64, @floatFromInt(p99)) / 1000.0,
        @as(f64, @floatFromInt(min_v)) / 1000.0,
        @as(f64, @floatFromInt(max_v)) / 1000.0,
    });
}
