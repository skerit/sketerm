//! Minimal GL helpers — shader compilation + program linking.
//!
//! GLSL version portability: shader sources in src/render/ carry NO
//! `#version` / `precision` lines — compileShader prepends a header
//! for the active API. Linux GTK contexts are GLES 3.0 (`300 es`);
//! macOS GDK is desktop-GL-only (4.1 core via CGL), where the same
//! bodies compile as `330 core`. `api` is set from the realized
//! GdkGLContext (Pane.onRealize) and defaults per-OS so headless
//! tools work without a GTK context.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("../c.zig").c;

pub const Api = enum { gles, gl_core };

/// Process-wide: every context in the share group has the same API.
pub var api: Api = if (builtin.os.tag == .macos) .gl_core else .gles;

/// Version + default-precision preamble for the active API.
/// Desktop GLSL 1.30+ accepts (and ignores) float/int precision
/// qualifiers but NOT default-precision statements for sampler
/// types, so those live only in the ES header.
pub fn shaderHeader(stage: c_uint) []const u8 {
    return switch (api) {
        .gles => if (stage == c.GL_FRAGMENT_SHADER)
            "#version 300 es\nprecision highp float;\nprecision mediump sampler2DArray;\n#line 0\n"
        else
            "#version 300 es\n#line 0\n",
        .gl_core => "#version 330 core\n#line 0\n",
    };
}

/// Configure a GtkGLArea for the platform's GL API. Linux keeps the
/// historical GLES request; macOS GDK is desktop-GL-only and FAILS
/// realize (black widget) when restricted to GLES, so it gets GL.
pub fn requestArea(area: *c.GtkGLArea) void {
    if (builtin.os.tag == .macos) {
        c.gtk_gl_area_set_allowed_apis(area, @intCast(c.GDK_GL_API_GL));
    } else {
        c.gtk_gl_area_set_use_es(area, 1);
    }
}

/// Sync `api` with what GDK actually realized for this area — call
/// after make_current in a realize handler. No-op when the context
/// is unavailable (error state).
pub fn adoptAreaApi(area: *c.GtkGLArea) void {
    const ctx = c.gtk_gl_area_get_context(area) orelse return;
    const got: c_int = @intCast(c.gdk_gl_context_get_api(ctx));
    api = if (got == c.GDK_GL_API_GL) .gl_core else .gles;
}

pub const ShaderError = error{
    CompileFailed,
    LinkFailed,
};

pub fn compileShader(stage: c_uint, source: []const u8) !c_uint {
    const sh = c.glCreateShader(stage);
    if (sh == 0) return error.CompileFailed;
    const header = shaderHeader(stage);
    const ptrs = [2]?[*]const u8{ header.ptr, source.ptr };
    const lens = [2]c_int{ @intCast(header.len), @intCast(source.len) };
    c.glShaderSource(sh, 2, @ptrCast(&ptrs), &lens);
    c.glCompileShader(sh);

    var ok: c_int = 0;
    c.glGetShaderiv(sh, c.GL_COMPILE_STATUS, &ok);
    if (ok == 0) {
        var log_buf: [2048]u8 = undefined;
        var log_len: c_int = 0;
        c.glGetShaderInfoLog(sh, @intCast(log_buf.len), &log_len, &log_buf);
        std.debug.print("shader compile failed:\n{s}\n", .{log_buf[0..@intCast(log_len)]});
        c.glDeleteShader(sh);
        return error.CompileFailed;
    }
    return sh;
}

pub fn linkProgram(vs: c_uint, fs: c_uint) !c_uint {
    const prog = c.glCreateProgram();
    if (prog == 0) return error.LinkFailed;
    c.glAttachShader(prog, vs);
    c.glAttachShader(prog, fs);
    c.glLinkProgram(prog);

    var ok: c_int = 0;
    c.glGetProgramiv(prog, c.GL_LINK_STATUS, &ok);
    if (ok == 0) {
        var log_buf: [2048]u8 = undefined;
        var log_len: c_int = 0;
        c.glGetProgramInfoLog(prog, @intCast(log_buf.len), &log_len, &log_buf);
        std.debug.print("program link failed:\n{s}\n", .{log_buf[0..@intCast(log_len)]});
        c.glDeleteProgram(prog);
        return error.LinkFailed;
    }
    return prog;
}

pub fn buildProgram(vs_src: []const u8, fs_src: []const u8) !c_uint {
    const vs = try compileShader(c.GL_VERTEX_SHADER, vs_src);
    defer c.glDeleteShader(vs);
    const fs = try compileShader(c.GL_FRAGMENT_SHADER, fs_src);
    defer c.glDeleteShader(fs);
    return try linkProgram(vs, fs);
}
