//! Minimal GL helpers — shader compilation + program linking.

const std = @import("std");
const c = @import("../c.zig").c;

pub const ShaderError = error{
    CompileFailed,
    LinkFailed,
};

pub fn compileShader(stage: c_uint, source: []const u8) !c_uint {
    const sh = c.glCreateShader(stage);
    if (sh == 0) return error.CompileFailed;
    var len: c_int = @intCast(source.len);
    const src_ptr: ?[*]const u8 = source.ptr;
    c.glShaderSource(sh, 1, @ptrCast(&src_ptr), &len);
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
