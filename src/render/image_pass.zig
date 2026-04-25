//! Image pass — draws each image in the store as a textured quad.

const std = @import("std");
const c = @import("../c.zig").c;
const gl = @import("gl.zig");
const ImageStore = @import("../grid/image_store.zig").Store;

const VERT_SRC =
    \\#version 300 es
    \\in vec2 a_pos;
    \\in vec2 a_uv;
    \\uniform vec2 u_screen_px;
    \\out vec2 v_uv;
    \\void main() {
    \\    vec2 ndc = (a_pos / u_screen_px) * 2.0 - 1.0;
    \\    ndc.y = -ndc.y;
    \\    gl_Position = vec4(ndc, 0.0, 1.0);
    \\    v_uv = a_uv;
    \\}
;

const FRAG_SRC =
    \\#version 300 es
    \\precision mediump float;
    \\in vec2 v_uv;
    \\uniform sampler2D u_image;
    \\out vec4 o_frag;
    \\void main() {
    \\    o_frag = texture(u_image, v_uv);
    \\}
;

const Vertex = extern struct {
    pos: [2]f32,
    uv: [2]f32,
};

pub const ImagePass = struct {
    program: c_uint = 0,
    vao: c_uint = 0,
    vbo: c_uint = 0,
    u_screen_px: c_int = -1,
    u_image: c_int = -1,

    pub fn init() ImagePass {
        return .{};
    }

    pub fn deinit(self: *ImagePass) void {
        // GL resources are tied to the context (see GridPass.deinit).
        _ = self;
    }

    /// Drop cached GL handles — call after context loss before
    /// re-realizing into a new context.
    pub fn forgetGL(self: *ImagePass) void {
        self.program = 0;
        self.vao = 0;
        self.vbo = 0;
        self.u_screen_px = -1;
        self.u_image = -1;
    }

    pub fn realize(self: *ImagePass) !void {
        if (self.program != 0) return;
        self.program = try gl.buildProgram(VERT_SRC, FRAG_SRC);
        self.u_screen_px = c.glGetUniformLocation(self.program, "u_screen_px");
        self.u_image = c.glGetUniformLocation(self.program, "u_image");

        c.glGenVertexArrays(1, &self.vao);
        c.glBindVertexArray(self.vao);
        c.glGenBuffers(1, &self.vbo);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbo);

        const stride: c_int = @sizeOf(Vertex);
        const a_pos: c_uint = @intCast(c.glGetAttribLocation(self.program, "a_pos"));
        const a_uv: c_uint = @intCast(c.glGetAttribLocation(self.program, "a_uv"));
        c.glEnableVertexAttribArray(a_pos);
        c.glVertexAttribPointer(a_pos, 2, c.GL_FLOAT, c.GL_FALSE, stride, @ptrFromInt(@offsetOf(Vertex, "pos")));
        c.glEnableVertexAttribArray(a_uv);
        c.glVertexAttribPointer(a_uv, 2, c.GL_FLOAT, c.GL_FALSE, stride, @ptrFromInt(@offsetOf(Vertex, "uv")));
        c.glBindVertexArray(0);
    }

    pub fn draw(self: *ImagePass, store: *ImageStore, viewport_w: i32, viewport_h: i32) void {
        if (store.images.items.len == 0) return;
        c.glUseProgram(self.program);
        c.glUniform2f(self.u_screen_px, @floatFromInt(viewport_w), @floatFromInt(viewport_h));
        c.glActiveTexture(c.GL_TEXTURE0);
        c.glUniform1i(self.u_image, 0);
        c.glBindVertexArray(self.vao);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbo);
        c.glEnable(c.GL_BLEND);
        c.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);

        for (store.images.items) |img| {
            if (img.gl_tex == 0) continue;
            const x: f32 = @as(f32, @floatFromInt(img.cell_col)) * store.cell_w;
            const y: f32 = @as(f32, @floatFromInt(img.cell_row)) * store.cell_h;
            const w: f32 = @floatFromInt(img.width);
            const h: f32 = @floatFromInt(img.height);
            const verts = [_]Vertex{
                .{ .pos = .{ x, y }, .uv = .{ 0, 0 } },
                .{ .pos = .{ x + w, y }, .uv = .{ 1, 0 } },
                .{ .pos = .{ x, y + h }, .uv = .{ 0, 1 } },
                .{ .pos = .{ x + w, y }, .uv = .{ 1, 0 } },
                .{ .pos = .{ x + w, y + h }, .uv = .{ 1, 1 } },
                .{ .pos = .{ x, y + h }, .uv = .{ 0, 1 } },
            };
            c.glBindTexture(c.GL_TEXTURE_2D, img.gl_tex);
            c.glBufferData(c.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(verts)), &verts, c.GL_DYNAMIC_DRAW);
            c.glDrawArrays(c.GL_TRIANGLES, 0, 6);
        }

        c.glDisable(c.GL_BLEND);
        c.glBindVertexArray(0);
    }
};
