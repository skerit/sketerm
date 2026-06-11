//! Background pass — gradient or image behind everything else.
//!
//! Drawn right after the clear, before kitty below-text images and
//! the cell grid. Cells with an explicit bg still paint over it;
//! default-bg cells let it show through, so text stays readable at
//! low opacity (kitty's background_image model).
//!
//! The CPU-side `Source` is owned by the Window (one decode shared
//! by every pane); each pane's BgPass uploads its own texture into
//! its own GL context and re-uploads when `Source.generation` moves.

const std = @import("std");
const c = @import("../c.zig").c;
const gl = @import("gl.zig");

pub const Mode = enum { none, gradient, image };

pub const Source = struct {
    mode: Mode = .none,
    color0: [4]f32 = .{ 0, 0, 0, 1 },
    color1: [4]f32 = .{ 0, 0, 0, 1 },
    /// Gradient direction in degrees; 0 = left→right, 90 = top→bottom.
    angle_deg: f32 = 90,
    /// Layer alpha. Gradients usually want 1.0; images ~0.2-0.4.
    opacity: f32 = 1.0,
    /// Decoded RGBA8 pixels (stbi allocation — freed by the owner
    /// via stbi_image_free, not a Zig allocator).
    pixels: ?[*]u8 = null,
    w: i32 = 0,
    h: i32 = 0,
    /// Bumped on every change; panes re-upload textures lazily.
    generation: u32 = 0,
};

pub const VERT_SRC =
    \\in vec2 a_pos;
    \\out vec2 v_uv;
    \\void main() {
    \\    v_uv = a_pos * 0.5 + 0.5;
    \\    v_uv.y = 1.0 - v_uv.y;
    \\    gl_Position = vec4(a_pos, 0.0, 1.0);
    \\}
;

pub const FRAG_SRC =
    \\in vec2 v_uv;
    \\uniform int u_mode;       // 0 = gradient, 1 = image
    \\uniform vec4 u_color0;
    \\uniform vec4 u_color1;
    \\uniform vec2 u_dir;       // gradient direction unit vector
    \\uniform float u_opacity;
    \\uniform vec2 u_uv_scale;  // image cover-crop transform
    \\uniform vec2 u_uv_off;
    \\uniform sampler2D u_image;
    \\out vec4 o_frag;
    \\void main() {
    \\    if (u_mode == 0) {
    \\        float t = clamp(dot(v_uv - 0.5, u_dir) + 0.5, 0.0, 1.0);
    \\        vec4 col = mix(u_color0, u_color1, t);
    \\        o_frag = vec4(col.rgb, col.a * u_opacity);
    \\    } else {
    \\        vec4 tex = texture(u_image, u_uv_off + v_uv * u_uv_scale);
    \\        o_frag = vec4(tex.rgb, tex.a * u_opacity);
    \\    }
    \\}
;

/// UV transform that scales the image to cover the viewport
/// (fill + center-crop, CSS `background-size: cover`).
pub fn coverTransform(vw: f32, vh: f32, iw: f32, ih: f32) struct { scale: [2]f32, off: [2]f32 } {
    if (vw <= 0 or vh <= 0 or iw <= 0 or ih <= 0)
        return .{ .scale = .{ 1, 1 }, .off = .{ 0, 0 } };
    const va = vw / vh;
    const ia = iw / ih;
    if (ia > va) {
        // Image wider than viewport: crop left/right.
        const sx = va / ia;
        return .{ .scale = .{ sx, 1 }, .off = .{ (1 - sx) / 2, 0 } };
    }
    // Image taller: crop top/bottom.
    const sy = ia / va;
    return .{ .scale = .{ 1, sy }, .off = .{ 0, (1 - sy) / 2 } };
}

pub const BgPass = struct {
    program: c_uint = 0,
    vao: c_uint = 0,
    vbo: c_uint = 0,
    tex: c_uint = 0,
    tex_generation: u32 = std.math.maxInt(u32),
    u_mode: c_int = -1,
    u_color0: c_int = -1,
    u_color1: c_int = -1,
    u_dir: c_int = -1,
    u_opacity: c_int = -1,
    u_uv_scale: c_int = -1,
    u_uv_off: c_int = -1,
    u_image: c_int = -1,
    /// Window-owned shared source. Null until the Window wires it.
    source: ?*const Source = null,

    pub fn forgetGL(self: *BgPass) void {
        self.program = 0;
        self.vao = 0;
        self.vbo = 0;
        self.tex = 0;
        self.tex_generation = std.math.maxInt(u32);
    }

    pub fn releaseGL(self: *BgPass) void {
        if (self.program != 0) c.glDeleteProgram(self.program);
        if (self.vao != 0) {
            var v = self.vao;
            c.glDeleteVertexArrays(1, &v);
        }
        if (self.vbo != 0) {
            var b = self.vbo;
            c.glDeleteBuffers(1, &b);
        }
        if (self.tex != 0) {
            var t = self.tex;
            c.glDeleteTextures(1, &t);
        }
        self.forgetGL();
    }

    pub fn realize(self: *BgPass) !void {
        if (self.program != 0) return;
        self.program = try gl.buildProgram(VERT_SRC, FRAG_SRC);
        self.u_mode = c.glGetUniformLocation(self.program, "u_mode");
        self.u_color0 = c.glGetUniformLocation(self.program, "u_color0");
        self.u_color1 = c.glGetUniformLocation(self.program, "u_color1");
        self.u_dir = c.glGetUniformLocation(self.program, "u_dir");
        self.u_opacity = c.glGetUniformLocation(self.program, "u_opacity");
        self.u_uv_scale = c.glGetUniformLocation(self.program, "u_uv_scale");
        self.u_uv_off = c.glGetUniformLocation(self.program, "u_uv_off");
        self.u_image = c.glGetUniformLocation(self.program, "u_image");

        c.glGenVertexArrays(1, &self.vao);
        c.glBindVertexArray(self.vao);
        c.glGenBuffers(1, &self.vbo);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbo);
        const quad = [_]f32{ -1, -1, 1, -1, -1, 1, 1, -1, 1, 1, -1, 1 };
        c.glBufferData(c.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(quad)), &quad, c.GL_STATIC_DRAW);
        const a_pos: c_uint = @intCast(c.glGetAttribLocation(self.program, "a_pos"));
        c.glEnableVertexAttribArray(a_pos);
        c.glVertexAttribPointer(a_pos, 2, c.GL_FLOAT, c.GL_FALSE, 2 * @sizeOf(f32), null);
        c.glBindVertexArray(0);
    }

    pub fn draw(self: *BgPass, viewport_w: i32, viewport_h: i32) void {
        const src = self.source orelse return;
        if (src.mode == .none or self.program == 0) return;
        if (src.mode == .image and src.pixels == null) return;

        c.glUseProgram(self.program);
        c.glBindVertexArray(self.vao);
        c.glEnable(c.GL_BLEND);
        c.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);

        switch (src.mode) {
            .gradient => {
                const rad = src.angle_deg * std.math.pi / 180.0;
                c.glUniform1i(self.u_mode, 0);
                c.glUniform4fv(self.u_color0, 1, &src.color0);
                c.glUniform4fv(self.u_color1, 1, &src.color1);
                c.glUniform2f(self.u_dir, @cos(rad), @sin(rad));
                c.glUniform1f(self.u_opacity, src.opacity);
            },
            .image => {
                if (self.tex == 0 or self.tex_generation != src.generation) {
                    if (self.tex == 0) c.glGenTextures(1, &self.tex);
                    c.glBindTexture(c.GL_TEXTURE_2D, self.tex);
                    c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA8, src.w, src.h, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, src.pixels.?);
                    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
                    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
                    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
                    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
                    self.tex_generation = src.generation;
                }
                const tr = coverTransform(
                    @floatFromInt(viewport_w),
                    @floatFromInt(viewport_h),
                    @floatFromInt(src.w),
                    @floatFromInt(src.h),
                );
                c.glUniform1i(self.u_mode, 1);
                c.glUniform1f(self.u_opacity, src.opacity);
                c.glUniform2f(self.u_uv_scale, tr.scale[0], tr.scale[1]);
                c.glUniform2f(self.u_uv_off, tr.off[0], tr.off[1]);
                c.glActiveTexture(c.GL_TEXTURE0);
                c.glBindTexture(c.GL_TEXTURE_2D, self.tex);
                c.glUniform1i(self.u_image, 0);
            },
            .none => unreachable,
        }

        c.glDrawArrays(c.GL_TRIANGLES, 0, 6);
        c.glDisable(c.GL_BLEND);
        c.glBindVertexArray(0);
    }
};

test "coverTransform crops the longer axis, centred" {
    // Wide image in a square viewport: x cropped, y full.
    const wide = coverTransform(100, 100, 200, 100);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), wide.scale[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), wide.scale[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), wide.off[0], 1e-6);
    // Tall image: y cropped.
    const tall = coverTransform(100, 100, 100, 200);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), tall.scale[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), tall.scale[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), tall.off[1], 1e-6);
    // Matching aspect: identity.
    const same = coverTransform(200, 100, 400, 200);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), same.scale[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), same.scale[1], 1e-6);
    // Degenerate sizes: identity, no NaN.
    const degen = coverTransform(0, 0, 0, 0);
    try std.testing.expectEqual(@as(f32, 1.0), degen.scale[0]);
}
