//! Surfaceless EGL bootstrap for the headless GL rigs.
//!
//! Seven rigs (smoke-cell, smoke-image, smoke-editor, smoke-
//! transparency, smoke-gl-core, bench-cell-upload, spike-editor-text)
//! all began with the same Mesa-surfaceless display acquisition, config
//! choice, context creation and offscreen RGBA8 framebuffer. The block
//! was byte-identical between them apart from two axes, both parameters
//! here: which client API the context is for, and what a rig prints
//! when a step fails.
//!
//! GUI-side only: it needs EGL, so it must never be reachable from
//! `sketerm-mux` or `src/tests_core.zig`.

const std = @import("std");
const c = @import("../c.zig").c;

const c_egl = @cImport({
    @cInclude("epoxy/egl.h");
});

/// Which client API the context binds. `gl33_core` exists for
/// smoke-gl-core, which compiles every shader the way macOS desktop GL
/// would see it.
pub const Api = enum { gles3, gl33_core };

/// One member per EGL step, so a caller keeps its own per-step message
/// (and smoke-gl-core keeps treating each as a SKIP rather than a FAIL).
pub const Error = error{
    NoDisplay,
    Init,
    BindApi,
    ChooseConfig,
    CreateContext,
    MakeCurrent,
};

/// The live context. Returned rather than kept in a global so the
/// vendor string is queried on the display that was actually chosen,
/// not on whatever `EGL_DEFAULT_DISPLAY` resolves to.
pub const Context = struct {
    display: c_egl.EGLDisplay,
    major: c_egl.EGLint = 0,
    minor: c_egl.EGLint = 0,

    pub fn vendor(self: Context) [*c]const u8 {
        return c_egl.eglQueryString(self.display, c_egl.EGL_VENDOR);
    }
};

/// Bring up a surfaceless context and make it current.
pub fn surfaceless(api: Api) Error!Context {
    const display = blk: {
        const get_platform = c_egl.eglGetProcAddress("eglGetPlatformDisplayEXT");
        if (get_platform) |p| {
            const fn_ptr: *const fn (c_uint, ?*anyopaque, ?[*]const c_egl.EGLint) callconv(.c) c_egl.EGLDisplay = @ptrCast(@alignCast(p));
            const PLATFORM_SURFACELESS_MESA: c_uint = 0x31DD;
            const d = fn_ptr(PLATFORM_SURFACELESS_MESA, null, null);
            if (d != null and d != c_egl.EGL_NO_DISPLAY) break :blk d;
        }
        break :blk c_egl.eglGetDisplay(c_egl.EGL_DEFAULT_DISPLAY);
    };
    if (display == c_egl.EGL_NO_DISPLAY) return error.NoDisplay;

    var out = Context{ .display = display };
    if (c_egl.eglInitialize(display, &out.major, &out.minor) == c_egl.EGL_FALSE) return error.Init;

    const bind_api: c_egl.EGLenum = switch (api) {
        .gles3 => c_egl.EGL_OPENGL_ES_API,
        .gl33_core => c_egl.EGL_OPENGL_API,
    };
    if (c_egl.eglBindAPI(bind_api) == c_egl.EGL_FALSE) return error.BindApi;

    const renderable: c_egl.EGLint = switch (api) {
        .gles3 => c_egl.EGL_OPENGL_ES3_BIT,
        .gl33_core => c_egl.EGL_OPENGL_BIT,
    };
    const cfg_attribs = [_]c_egl.EGLint{
        c_egl.EGL_RED_SIZE,        8,
        c_egl.EGL_GREEN_SIZE,      8,
        c_egl.EGL_BLUE_SIZE,       8,
        c_egl.EGL_ALPHA_SIZE,      8,
        c_egl.EGL_RENDERABLE_TYPE, renderable,
        c_egl.EGL_SURFACE_TYPE,    c_egl.EGL_PBUFFER_BIT,
        c_egl.EGL_NONE,
    };
    var cfg: c_egl.EGLConfig = null;
    var n_cfg: c_egl.EGLint = 0;
    if (c_egl.eglChooseConfig(display, &cfg_attribs, &cfg, 1, &n_cfg) == c_egl.EGL_FALSE or n_cfg < 1) {
        return error.ChooseConfig;
    }

    const ctx = switch (api) {
        .gles3 => ctx: {
            const attribs = [_]c_egl.EGLint{
                c_egl.EGL_CONTEXT_MAJOR_VERSION, 3,
                c_egl.EGL_CONTEXT_MINOR_VERSION, 0,
                c_egl.EGL_NONE,
            };
            break :ctx c_egl.eglCreateContext(display, cfg, c_egl.EGL_NO_CONTEXT, &attribs);
        },
        .gl33_core => ctx: {
            const attribs = [_]c_egl.EGLint{
                c_egl.EGL_CONTEXT_MAJOR_VERSION,       3,
                c_egl.EGL_CONTEXT_MINOR_VERSION,       3,
                c_egl.EGL_CONTEXT_OPENGL_PROFILE_MASK, c_egl.EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
                c_egl.EGL_NONE,
            };
            break :ctx c_egl.eglCreateContext(display, cfg, c_egl.EGL_NO_CONTEXT, &attribs);
        },
    };
    if (ctx == c_egl.EGL_NO_CONTEXT) return error.CreateContext;
    if (c_egl.eglMakeCurrent(display, c_egl.EGL_NO_SURFACE, c_egl.EGL_NO_SURFACE, ctx) == c_egl.EGL_FALSE) {
        return error.MakeCurrent;
    }
    return out;
}

/// The EGL error code of the last failed call, for the rigs that print
/// it (smoke-image reports it on context/make-current failures).
pub fn lastError() c_egl.EGLint {
    return c_egl.eglGetError();
}

/// An offscreen colour target, bound and left current.
pub const Fbo = struct {
    fbo: c_uint = 0,
    rbo: c_uint = 0,
};

/// Bind a fresh RGBA8 renderbuffer FBO of `w` x `h` and set the
/// viewport to it. The caller clears: every rig wants a different clear
/// colour, and smoke-transparency's alpha is the thing it asserts on.
pub fn offscreenRgba8(w: c_int, h: c_int) error{Incomplete}!Fbo {
    var out: Fbo = .{};
    c.glGenFramebuffers(1, &out.fbo);
    c.glBindFramebuffer(c.GL_FRAMEBUFFER, out.fbo);
    c.glGenRenderbuffers(1, &out.rbo);
    c.glBindRenderbuffer(c.GL_RENDERBUFFER, out.rbo);
    c.glRenderbufferStorage(c.GL_RENDERBUFFER, c.GL_RGBA8, w, h);
    c.glFramebufferRenderbuffer(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_RENDERBUFFER, out.rbo);
    if (c.glCheckFramebufferStatus(c.GL_FRAMEBUFFER) != c.GL_FRAMEBUFFER_COMPLETE) return error.Incomplete;
    c.glViewport(0, 0, w, h);
    return out;
}
