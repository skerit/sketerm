//! Desktop-GL core shader smoke — `zig build smoke-gl-core`.
//!
//! macOS GDK realizes desktop OpenGL (4.1 core) contexts, never GLES,
//! so every shader must also compile under a core profile with the
//! `#version 330 core` header gl.zig injects. This smoke creates a
//! desktop-GL 3.3 core context via EGL (Mesa) on Linux and compiles
//! EVERY render-pass program pair plus the shipped CRT preset through
//! the shader_pass wrapper — proving the macOS GL path on a Linux box.

const std = @import("std");
const c = @import("c.zig").c;
const gl = @import("render/gl.zig");
const bg_pass = @import("render/bg_pass.zig");
const image_pass = @import("render/image_pass.zig");
const cell_pass = @import("render/cell_pass.zig");
const grid_pass = @import("render/grid_pass.zig");
const shader_pass = @import("render/shader_pass.zig");
const editor_pass = @import("render/editor_pass.zig");
const blend = @import("render/blend.zig");

const c_egl = @cImport({
    @cInclude("epoxy/egl.h");
});

const crt_glsl = @embedFile("crt_glsl");

pub fn main() !u8 {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

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
    if (display == c_egl.EGL_NO_DISPLAY) {
        std.debug.print("smoke-gl-core: no EGL display — SKIP\n", .{});
        return 0;
    }
    var major: c_egl.EGLint = 0;
    var minor: c_egl.EGLint = 0;
    if (c_egl.eglInitialize(display, &major, &minor) == c_egl.EGL_FALSE) {
        std.debug.print("smoke-gl-core: eglInitialize failed — SKIP\n", .{});
        return 0;
    }
    // Desktop GL, not GLES — this is the whole point.
    if (c_egl.eglBindAPI(c_egl.EGL_OPENGL_API) == c_egl.EGL_FALSE) {
        std.debug.print("smoke-gl-core: no desktop-GL EGL support — SKIP\n", .{});
        return 0;
    }
    const cfg_attribs = [_]c_egl.EGLint{
        c_egl.EGL_RED_SIZE,        8,
        c_egl.EGL_GREEN_SIZE,      8,
        c_egl.EGL_BLUE_SIZE,       8,
        c_egl.EGL_ALPHA_SIZE,      8,
        c_egl.EGL_RENDERABLE_TYPE, c_egl.EGL_OPENGL_BIT,
        c_egl.EGL_SURFACE_TYPE,    c_egl.EGL_PBUFFER_BIT,
        c_egl.EGL_NONE,
    };
    var cfg: c_egl.EGLConfig = null;
    var n_cfg: c_egl.EGLint = 0;
    if (c_egl.eglChooseConfig(display, &cfg_attribs, &cfg, 1, &n_cfg) == c_egl.EGL_FALSE or n_cfg < 1) {
        std.debug.print("smoke-gl-core: no desktop-GL config — SKIP\n", .{});
        return 0;
    }
    const ctx_attribs = [_]c_egl.EGLint{
        c_egl.EGL_CONTEXT_MAJOR_VERSION,       3,
        c_egl.EGL_CONTEXT_MINOR_VERSION,       3,
        c_egl.EGL_CONTEXT_OPENGL_PROFILE_MASK, c_egl.EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
        c_egl.EGL_NONE,
    };
    const ctx = c_egl.eglCreateContext(display, cfg, c_egl.EGL_NO_CONTEXT, &ctx_attribs);
    if (ctx == c_egl.EGL_NO_CONTEXT) {
        std.debug.print("smoke-gl-core: 3.3 core context failed — SKIP\n", .{});
        return 0;
    }
    if (c_egl.eglMakeCurrent(display, c_egl.EGL_NO_SURFACE, c_egl.EGL_NO_SURFACE, ctx) == c_egl.EGL_FALSE) return 1;

    std.debug.print("smoke-gl-core: GL_VERSION={s}\n", .{c.glGetString(c.GL_VERSION)});
    gl.api = .gl_core;

    // Core profiles require a bound VAO for any vertex work; the
    // pass programs only COMPILE here, but be safe.
    var vao: c_uint = 0;
    c.glGenVertexArrays(1, &vao);
    c.glBindVertexArray(vao);

    var failures: u8 = 0;
    failures += try check("bg_pass", bg_pass.VERT_SRC, bg_pass.FRAG_SRC);
    failures += try check("image_pass", image_pass.VERT_SRC, image_pass.FRAG_SRC);
    failures += try check("cell_pass", cell_pass.VERT_SRC, cell_pass.FRAG_SRC);
    failures += try check("grid_pass", grid_pass.VERT_SRC, grid_pass.FRAG_SRC);
    failures += try check("editor_pass", editor_pass.VERT_SRC, editor_pass.FRAG_SRC);
    // The linear-blending resolve pass — its sources are private to
    // blend.zig, so it exposes them for exactly this check.
    failures += try check("blend(resolve)", blend.RESOLVE_VERT_SRC, blend.RESOLVE_FRAG_SRC);

    // shader_pass: identity dim shader and the real shipped CRT
    // preset, wrapped exactly the way ensureProgram wraps them.
    const dim_full = try std.mem.concat(allocator, u8, &.{
        shader_pass.FRAG_HEADER, shader_pass.DIM_IDENTITY_SRC, shader_pass.FRAG_FOOTER,
    });
    defer allocator.free(dim_full);
    failures += try check("shader_pass(dim)", shader_pass.VERT_SRC, dim_full);

    const crt_full = try std.mem.concat(allocator, u8, &.{
        shader_pass.FRAG_HEADER, crt_glsl, shader_pass.FRAG_FOOTER,
    });
    defer allocator.free(crt_full);
    failures += try check("shader_pass(crt)", shader_pass.VERT_SRC, crt_full);

    if (failures != 0) {
        std.debug.print("smoke-gl-core: FAIL ({d} programs)\n", .{failures});
        return 1;
    }
    std.debug.print("smoke-gl-core: PASS (all shaders compile under GL 3.3 core)\n", .{});
    return 0;
}

fn check(name: []const u8, vert: []const u8, frag: []const u8) !u8 {
    const prog = gl.buildProgram(vert, frag) catch {
        std.debug.print("smoke-gl-core: {s} FAILED\n", .{name});
        return 1;
    };
    c.glDeleteProgram(prog);
    std.debug.print("smoke-gl-core: {s} ok\n", .{name});
    return 0;
}
