//! Headless transparency smoke — validates that background_opacity
//! < 1.0 actually produces a rendered framebuffer with semi-
//! transparent background pixels. Drives the same Atlas + CellPass
//! + GridPass stack as smoke_cell, but with `screen.default_bg.a =
//! 0.5` and asserts the readback alpha channel reflects it.
//!
//! Run: `zig build smoke-transparency`. Exits 0 on PASS.
//!
//! Plan-v3.md called for this gating before C (transparency)
//! shipped — added retroactively so further regressions in the
//! alpha path get caught.

const std = @import("std");
const c = @import("c.zig").c;
const Atlas = @import("render/atlas.zig").Atlas;
const CellPass = @import("render/cell_pass.zig").CellPass;
const GridPass = @import("render/grid_pass.zig").GridPass;
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

const W: c_int = 320;
const H: c_int = 96;
const FONT_SIZE: u16 = 14;
const BG_ALPHA: f32 = 0.5;

pub fn main() !u8 {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // EGL surfaceless context (mirrors smoke_cell setup).
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
        c_egl.EGL_RED_SIZE,    8,                          c_egl.EGL_GREEN_SIZE,   8,                              c_egl.EGL_BLUE_SIZE, 8, c_egl.EGL_ALPHA_SIZE, 8,
        c_egl.EGL_RENDERABLE_TYPE, c_egl.EGL_OPENGL_ES3_BIT,
        c_egl.EGL_SURFACE_TYPE,    c_egl.EGL_PBUFFER_BIT,
        c_egl.EGL_NONE,
    };
    var cfg: c_egl.EGLConfig = null;
    var n_cfg: c_egl.EGLint = 0;
    if (c_egl.eglChooseConfig(display, &cfg_attribs, &cfg, 1, &n_cfg) == c_egl.EGL_FALSE or n_cfg < 1) return 1;
    const ctx_attribs = [_]c_egl.EGLint{ c_egl.EGL_CONTEXT_MAJOR_VERSION, 3, c_egl.EGL_CONTEXT_MINOR_VERSION, 0, c_egl.EGL_NONE };
    const ctx = c_egl.eglCreateContext(display, cfg, c_egl.EGL_NO_CONTEXT, &ctx_attribs);
    if (ctx == c_egl.EGL_NO_CONTEXT) return 1;
    if (c_egl.eglMakeCurrent(display, c_egl.EGL_NO_SURFACE, c_egl.EGL_NO_SURFACE, ctx) == c_egl.EGL_FALSE) return 1;

    std.debug.print("smoke-transparency: GL_VERSION={s}\n", .{c.glGetString(c.GL_VERSION)});

    // Offscreen RGBA8 FBO — alpha channel is what we care about.
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
    // Clear with alpha=0.5 — this is the "compositor sees through"
    // baseline that bg pixels should retain.
    c.glClearColor(0.10, 0.10, 0.10, BG_ALPHA);
    c.glClear(c.GL_COLOR_BUFFER_BIT);

    var atlas: ?*Atlas = null;
    for (FONT_CANDIDATES) |path| {
        if (Atlas.init(allocator, path, FONT_SIZE)) |a| {
            atlas = a;
            break;
        } else |_| continue;
    }
    if (atlas == null) {
        std.debug.print("smoke-transparency: no font found\n", .{});
        return 1;
    }
    defer atlas.?.deinit();
    atlas.?.realize();

    var pool = try StylePool.init(allocator);
    defer pool.deinit();
    const screen = try Screen.init(allocator, &pool, 40, 5);
    defer screen.deinit();
    // Set the screen's default_bg with alpha=0.5 — this is what
    // cell_pass picks up for bg quads on default-bg cells.
    screen.default_bg = .{ 0.10, 0.10, 0.10, BG_ALPHA };

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
    // Just plain text — no fancy SGR bg colours, so cells use the
    // default_bg with alpha=0.5.
    const greeting = "Hello, sketerm!";
    parser.advance(greeting, Emit.cb, @ptrCast(&ec));

    var cell_pass = CellPass.init(allocator);
    defer cell_pass.deinit();
    try cell_pass.realize();
    try cell_pass.rebuildAndUpload(screen, &pool, atlas.?);
    cell_pass.draw(atlas.?, W, H);

    var grid_pass = GridPass.init(allocator);
    defer grid_pass.deinit();
    try grid_pass.realize();
    grid_pass.canvas_w = @floatFromInt(W);
    grid_pass.canvas_h = @floatFromInt(H);
    // focused=false skips the focus-border quad which is opaque
    // and would push corner pixel alphas up to 1.0.
    try grid_pass.buildVertices(screen, &pool, atlas.?, false, true, &.{});
    grid_pass.draw(atlas.?, W, H);
    c.glFinish();

    const fb_bytes: usize = @intCast(W * H * 4);
    const fb = try allocator.alloc(u8, fb_bytes);
    defer allocator.free(fb);
    c.glReadPixels(0, 0, W, H, c.GL_RGBA, c.GL_UNSIGNED_BYTE, fb.ptr);

    // Histogram the alpha channel. For a 0.5 background:
    // - Background pixels (no glyph) should land near alpha=128.
    // - Glyph fill pixels are opaque (alpha=255).
    // - Glyph anti-aliased edges land between.
    // Threshold 200 (78%) separates "kept transparency" from "now
    // opaque." On a 320×96 frame with a single 15-char greeting in
    // row 1, the vast majority of pixels are background.
    var translucent: usize = 0;
    var fully_opaque: usize = 0;
    var i: usize = 0;
    while (i < fb_bytes) : (i += 4) {
        const a: u8 = fb[i + 3];
        if (a < 200) translucent += 1;
        if (a >= 250) fully_opaque += 1;
    }
    const total: usize = @intCast(W * H);
    std.debug.print(
        "smoke-transparency: total={d} translucent={d} fully_opaque={d}\n",
        .{ total, translucent, fully_opaque },
    );

    // Most of the frame should be translucent (bg with alpha=0.5).
    // Require >= 90 % to catch regressions where bg_a leaks to 1.0.
    if (translucent * 10 < total * 9) {
        std.debug.print("smoke-transparency: FAIL — too few translucent pixels\n", .{});
        return 2;
    }
    // A few opaque pixels should exist (glyph fill).
    if (fully_opaque < 5) {
        std.debug.print("smoke-transparency: FAIL — text not rendered as opaque\n", .{});
        return 3;
    }
    std.debug.print("smoke-transparency: PASS\n", .{});
    return 0;
}
