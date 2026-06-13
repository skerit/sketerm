//! Image pass — draws each image in the store as a textured quad.

const std = @import("std");
const c = @import("../c.zig").c;
const gl = @import("gl.zig");
const ImageStore = @import("../grid/image_store.zig").Store;

pub const VERT_SRC =
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

pub const FRAG_SRC =
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
    /// Inner padding (pixels) applied to the cell grid. Images must
    /// be offset by this same amount so they line up with the cells
    /// that referenced them. Set by the Pane each frame from
    /// `grid_pass.pad`.
    pad: f32 = 0,
    /// When true, draw() prints per-image diagnostics to stderr.
    debug: bool = false,

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

    /// Like `forgetGL`, but ALSO `glDelete*`s every resource we own.
    /// Caller must have a current GL context — the pane's `unrealize`
    /// signal is the last opportunity. Without this, every closed
    /// pane leaks 1 program + 1 VAO + 1 VBO into the shared context.
    pub fn releaseGL(self: *ImagePass) void {
        if (self.program != 0) {
            c.glDeleteProgram(self.program);
        }
        if (self.vao != 0) {
            var v = self.vao;
            c.glDeleteVertexArrays(1, &v);
        }
        if (self.vbo != 0) {
            var b = self.vbo;
            c.glDeleteBuffers(1, &b);
        }
        self.forgetGL();
    }

    /// Build shaders + buffers. Requires a current GL context.
    /// Idempotent; call `forgetGL` first to re-realize after a
    /// context loss.
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
        const fields = [_]struct { name: [*:0]const u8, off: usize, count: c_int }{
            .{ .name = "a_pos", .off = @offsetOf(Vertex, "pos"), .count = 2 },
            .{ .name = "a_uv", .off = @offsetOf(Vertex, "uv"), .count = 2 },
        };
        for (fields) |f| {
            const loc = c.glGetAttribLocation(self.program, f.name);
            if (loc < 0) continue;
            const idx: c_uint = @intCast(loc);
            c.glEnableVertexAttribArray(idx);
            c.glVertexAttribPointer(idx, f.count, c.GL_FLOAT, c.GL_FALSE, stride, @ptrFromInt(f.off));
        }
        c.glBindVertexArray(0);
    }

    /// Z-filter applied to a single draw call. `.below` renders only
    /// images with `z_index < 0` (Kitty: "behind text"); `.above`
    /// renders only `z_index >= 0` (default; on top of text); `.all`
    /// is unfiltered (used by smoke / tests).
    pub const ZFilter = enum { all, below, above };

    pub fn draw(self: *ImagePass, store: *ImageStore, viewport_w: i32, viewport_h: i32) void {
        self.drawZ(store, viewport_w, viewport_h, .all);
    }

    pub fn drawZ(self: *ImagePass, store: *ImageStore, viewport_w: i32, viewport_h: i32, zfilter: ZFilter) void {
        if (self.debug) {
            std.debug.print(
                "[image] draw N={d} viewport={d}x{d} program={d} z={s}\n",
                .{ store.images.items.len, viewport_w, viewport_h, self.program, @tagName(zfilter) },
            );
        }
        if (store.images.items.len == 0) return;
        if (self.program == 0) {
            if (self.debug) std.debug.print("[image] draw: program=0, bailing\n", .{});
            return;
        }
        c.glUseProgram(self.program);
        c.glUniform2f(self.u_screen_px, @floatFromInt(viewport_w), @floatFromInt(viewport_h));
        c.glActiveTexture(c.GL_TEXTURE0);
        c.glUniform1i(self.u_image, 0);
        c.glBindVertexArray(self.vao);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbo);
        c.glEnable(c.GL_BLEND);
        c.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);

        for (store.images.items) |img| {
            switch (zfilter) {
                .below => if (img.z_index >= 0) continue,
                .above => if (img.z_index < 0) continue,
                .all => {},
            }
            if (img.gl_tex == 0) {
                if (self.debug) std.debug.print("[image] skip id={d}: tex=0\n", .{img.image_id});
                continue;
            }
            const x: f32 = self.pad + @as(f32, @floatFromInt(img.cell_col)) * store.cell_w;
            const y: f32 = self.pad + @as(f32, @floatFromInt(img.cell_row)) * store.cell_h;

            // Destination size:
            //   - cells_wide/cells_high > 0 → scale to that many cells
            //   - else native pixel size
            const w: f32 = if (img.cells_wide > 0)
                @as(f32, @floatFromInt(img.cells_wide)) * store.cell_w
            else
                @floatFromInt(img.width);
            const h: f32 = if (img.cells_high > 0)
                @as(f32, @floatFromInt(img.cells_high)) * store.cell_h
            else
                @floatFromInt(img.height);

            // Source-rect crop: pixel offset → UV [0,1].
            const uv_x0: f32 = if (img.width > 0)
                @as(f32, @floatFromInt(img.src_x)) / @as(f32, @floatFromInt(img.width))
            else
                0;
            const uv_y0: f32 = if (img.height > 0)
                @as(f32, @floatFromInt(img.src_y)) / @as(f32, @floatFromInt(img.height))
            else
                0;
            const uv_x1: f32 = if (img.src_w > 0 and img.width > 0)
                @as(f32, @floatFromInt(img.src_x + img.src_w)) / @as(f32, @floatFromInt(img.width))
            else
                1;
            const uv_y1: f32 = if (img.src_h > 0 and img.height > 0)
                @as(f32, @floatFromInt(img.src_y + img.src_h)) / @as(f32, @floatFromInt(img.height))
            else
                1;

            const verts = [_]Vertex{
                .{ .pos = .{ x, y }, .uv = .{ uv_x0, uv_y0 } },
                .{ .pos = .{ x + w, y }, .uv = .{ uv_x1, uv_y0 } },
                .{ .pos = .{ x, y + h }, .uv = .{ uv_x0, uv_y1 } },
                .{ .pos = .{ x + w, y }, .uv = .{ uv_x1, uv_y0 } },
                .{ .pos = .{ x + w, y + h }, .uv = .{ uv_x1, uv_y1 } },
                .{ .pos = .{ x, y + h }, .uv = .{ uv_x0, uv_y1 } },
            };
            c.glBindTexture(c.GL_TEXTURE_2D, img.gl_tex);
            c.glBufferData(c.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(verts)), &verts, c.GL_DYNAMIC_DRAW);
            c.glDrawArrays(c.GL_TRIANGLES, 0, 6);
            if (self.debug) {
                const err = c.glGetError();
                std.debug.print(
                    "[image] drew id={d} pos=({d:.0},{d:.0}) size=({d:.0},{d:.0}) cells=({d}x{d}) tex={d} glErr=0x{x}\n",
                    .{ img.image_id, x, y, w, h, img.cells_wide, img.cells_high, img.gl_tex, err },
                );
            }
        }

        c.glDisable(c.GL_BLEND);
        c.glBindVertexArray(0);
    }
};
