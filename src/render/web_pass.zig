//! Web pass — presents one browser frame buffer as a single textured
//! quad filling a GtkGLArea.
//!
//! It exists because the web face used to hand GTK a fresh
//! `GdkMemoryTexture` over the WHOLE frame mapping on every damage
//! batch. That is a full-surface GPU upload plus a paintable swap per
//! frame: 33 MB at 3840x2160, i.e. ~2 GB/s at 60fps, which no
//! CPU-side trick can remove because the copy is GTK's, not ours.
//!
//! Here the texture is PERSISTENT and only the damaged rects are
//! uploaded, straight out of the mmap via `GL_UNPACK_ROW_LENGTH` (no
//! staging buffer, no per-row loop). A page whose spinner damages
//! 64x64 px uploads 16 KB instead of 33 MB.
//!
//! The texture is recreated only when the buffer geometry changes (a
//! resize or a scale change replaces the helper's memfd), and dropped
//! on context loss like every other pass — see `forgetGL`.
//!
//! Frame bytes are BGRA (CEF's OSR layout). GLES 3.0 has no BGRA
//! internal format, so they are uploaded as RGBA and swizzled in the
//! fragment shader; alpha is forced opaque because a browser view is.

const std = @import("std");
const c = @import("../c.zig").c;
const gl = @import("gl.zig");

pub const VERT_SRC =
    \\in vec2 a_pos;
    \\out vec2 v_uv;
    \\void main() {
    \\    // Row 0 of the frame buffer is the TOP row; GL texture
    \\    // coordinates start at the bottom, hence the y flip.
    \\    v_uv = vec2(a_pos.x * 0.5 + 0.5, 0.5 - a_pos.y * 0.5);
    \\    gl_Position = vec4(a_pos, 0.0, 1.0);
    \\}
;

pub const FRAG_SRC =
    \\in vec2 v_uv;
    \\uniform sampler2D u_tex;
    \\out vec4 o_frag;
    \\void main() {
    \\    // CEF hands over PREMULTIPLIED BGRA and paints transparently
    \\    // wherever a page sets no background. Compositing over white
    \\    // is what a browser shows there; leaving it alone would show
    \\    // black, since a fully transparent texel is all zeroes.
    \\    vec4 t = texture(u_tex, v_uv);
    \\    o_frag = vec4(t.bgr + (1.0 - t.a), 1.0);
    \\}
;

pub const WebPass = struct {
    program: c_uint = 0,
    vao: c_uint = 0,
    vbo: c_uint = 0,
    tex: c_uint = 0,
    u_tex: c_int = -1,
    /// Physical size of the allocated texture; 0 = none yet.
    tex_w: u16 = 0,
    tex_h: u16 = 0,

    /// Drop cached GL handles without deleting them — the context they
    /// belonged to is already gone (re-realize after a reparent).
    pub fn forgetGL(self: *WebPass) void {
        self.program = 0;
        self.vao = 0;
        self.vbo = 0;
        self.tex = 0;
        self.u_tex = -1;
        self.tex_w = 0;
        self.tex_h = 0;
    }

    /// Like `forgetGL` but also deletes what we own. Requires a current
    /// context; the area's `unrealize` is the last chance.
    pub fn releaseGL(self: *WebPass) void {
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

    /// Build the program and the fullscreen quad. Idempotent;
    /// `forgetGL` first to rebuild against a fresh context.
    pub fn realize(self: *WebPass) !void {
        if (self.program != 0) return;
        self.program = try gl.buildProgram(VERT_SRC, FRAG_SRC);
        self.u_tex = c.glGetUniformLocation(self.program, "u_tex");

        c.glGenVertexArrays(1, &self.vao);
        c.glBindVertexArray(self.vao);
        c.glGenBuffers(1, &self.vbo);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbo);
        const verts = [_]f32{ -1, -1, 1, -1, -1, 1, 1, 1 };
        c.glBufferData(c.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(verts)), &verts, c.GL_STATIC_DRAW);
        const loc = c.glGetAttribLocation(self.program, "a_pos");
        if (loc >= 0) {
            const idx: c_uint = @intCast(loc);
            c.glEnableVertexAttribArray(idx);
            c.glVertexAttribPointer(idx, 2, c.GL_FLOAT, c.GL_FALSE, 2 * @sizeOf(f32), null);
        }
        c.glBindVertexArray(0);
    }

    /// Make sure a `w` x `h` texture exists. Returns true when it had
    /// to be (re)allocated, which leaves the contents undefined — the
    /// caller then owes a full-surface upload.
    pub fn ensureTexture(self: *WebPass, w: u16, h: u16) bool {
        if (w == 0 or h == 0) return false;
        if (self.tex != 0 and self.tex_w == w and self.tex_h == h) return false;
        if (self.tex != 0) {
            var t = self.tex;
            c.glDeleteTextures(1, &t);
            self.tex = 0;
        }
        c.glGenTextures(1, &self.tex);
        c.glBindTexture(c.GL_TEXTURE_2D, self.tex);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
        c.glTexImage2D(
            c.GL_TEXTURE_2D,
            0,
            c.GL_RGBA8,
            @intCast(w),
            @intCast(h),
            0,
            c.GL_RGBA,
            c.GL_UNSIGNED_BYTE,
            null,
        );
        self.tex_w = w;
        self.tex_h = h;
        return true;
    }

    /// Upload one rect of `base` (a BGRA buffer of `stride` bytes per
    /// row) into the texture at the same coordinates. The rect is read
    /// in place: `GL_UNPACK_ROW_LENGTH` lets GL stride over the rest of
    /// each row, so no staging copy is needed.
    pub fn uploadRect(self: *WebPass, base: [*]const u8, stride: u32, x: u16, y: u16, w: u16, h: u16) void {
        if (self.tex == 0 or w == 0 or h == 0) return;
        if (x >= self.tex_w or y >= self.tex_h) return;
        const cw = @min(w, self.tex_w - x);
        const ch = @min(h, self.tex_h - y);
        c.glBindTexture(c.GL_TEXTURE_2D, self.tex);
        c.glPixelStorei(c.GL_UNPACK_ROW_LENGTH, @intCast(stride / 4));
        c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 4);
        const off = @as(usize, y) * @as(usize, stride) + @as(usize, x) * 4;
        c.glTexSubImage2D(
            c.GL_TEXTURE_2D,
            0,
            @intCast(x),
            @intCast(y),
            @intCast(cw),
            @intCast(ch),
            c.GL_RGBA,
            c.GL_UNSIGNED_BYTE,
            base + off,
        );
        c.glPixelStorei(c.GL_UNPACK_ROW_LENGTH, 0);
    }

    /// Draw the texture over the whole viewport. No-op until both the
    /// program and a texture exist, so an unpainted view stays at
    /// whatever the caller cleared to.
    pub fn draw(self: *WebPass) void {
        if (self.program == 0 or self.tex == 0) return;
        c.glDisable(c.GL_BLEND);
        c.glUseProgram(self.program);
        c.glActiveTexture(c.GL_TEXTURE0);
        c.glBindTexture(c.GL_TEXTURE_2D, self.tex);
        c.glUniform1i(self.u_tex, 0);
        c.glBindVertexArray(self.vao);
        c.glDrawArrays(c.GL_TRIANGLE_STRIP, 0, 4);
        c.glBindVertexArray(0);
    }
};
