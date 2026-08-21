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

const eglboot = @import("smoke/eglboot.zig");

const crt_glsl = @embedFile("crt_glsl");

pub fn main() !u8 {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Desktop GL, not GLES — this is the whole point. Every step but
    // the last is a SKIP: a host without desktop-GL EGL cannot answer
    // the question this rig asks, and must not fail the build for it.
    _ = eglboot.surfaceless(.gl33_core) catch |e| {
        switch (e) {
            error.NoDisplay => std.debug.print("smoke-gl-core: no EGL display — SKIP\n", .{}),
            error.Init => std.debug.print("smoke-gl-core: eglInitialize failed — SKIP\n", .{}),
            error.BindApi => std.debug.print("smoke-gl-core: no desktop-GL EGL support — SKIP\n", .{}),
            error.ChooseConfig => std.debug.print("smoke-gl-core: no desktop-GL config — SKIP\n", .{}),
            error.CreateContext => std.debug.print("smoke-gl-core: 3.3 core context failed — SKIP\n", .{}),
            error.MakeCurrent => return 1,
        }
        return 0;
    };

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
