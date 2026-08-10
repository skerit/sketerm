//! Web pass — presents one browser frame as a single textured quad
//! filling a GtkGLArea.
//!
//! It draws ONE of two textures, chosen per frame by the face:
//!
//! - the OWNED texture, into which the software (memfd) path uploads
//!   damage rects — see `ensureTexture`/`uploadRect`;
//! - a BORROWED texture, which on the GPU path is the engine's dma-buf
//!   imported as an EGLImage by `src/ui/webdmabuf.zig`. The pass never
//!   owns or deletes it; `showExternal` only records which name to
//!   sample and whether its bytes need the B/R swap.
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
//! THE FRAME IS NEVER STRETCHED. A browser frame is a rasterization at
//! ONE size; scaling it to fill an area of a different size is a lie
//! that reads as a blurry, wrongly proportioned page — and it is exactly
//! what a viewport-filling quad does for the window between "the widget
//! got its allocation" and "the engine painted at that allocation"
//! (browser start, and every live resize). `draw` therefore takes the
//! viewport and places the frame 1:1 at the top-left corner, letting the
//! clear colour show wherever the frame does not reach. A mismatch is
//! then visibly a mismatch that lasts one frame, not a stretch nobody
//! reports because it "fixes itself" as soon as you touch the window.
//!
//! Software frame bytes are BGRA (CEF's OSR layout). GLES 3.0 has no
//! BGRA internal format, so they are uploaded as RGBA and swizzled in
//! the fragment shader. An EGLImage-imported dma-buf needs NO swizzle:
//! the DRM FourCC told the driver the byte order, so sampling already
//! yields the right components — hence `u_swap_rb` rather than two
//! shaders. Alpha is forced opaque because a browser view is.

const std = @import("std");
const c = @import("../c.zig").c;
const gl = @import("gl.zig");

pub const VERT_SRC =
    \\in vec2 a_pos;
    \\out vec2 v_uv;
    \\// xy = the frame's size as a fraction of the viewport, zw = the
    \\// NDC centre that puts it at the top-left corner. (1,1,0,0) is the
    \\// exact-fit case and reduces to a plain fullscreen quad.
    \\uniform vec4 u_rect;
    \\void main() {
    \\    // Row 0 of the frame buffer is the TOP row; GL texture
    \\    // coordinates start at the bottom, hence the y flip. The UVs
    \\    // come from the UNIT quad, so placing the frame never
    \\    // resamples it.
    \\    v_uv = vec2(a_pos.x * 0.5 + 0.5, 0.5 - a_pos.y * 0.5);
    \\    gl_Position = vec4(a_pos * u_rect.xy + u_rect.zw, 0.0, 1.0);
    \\}
;

pub const FRAG_SRC =
    \\in vec2 v_uv;
    \\uniform sampler2D u_tex;
    \\uniform int u_swap_rb;
    \\out vec4 o_frag;
    \\void main() {
    \\    // CEF hands over PREMULTIPLIED pixels and paints transparently
    \\    // wherever a page sets no background. Compositing over white
    \\    // is what a browser shows there; leaving it alone would show
    \\    // black, since a fully transparent texel is all zeroes.
    \\    vec4 t = texture(u_tex, v_uv);
    \\    vec3 rgb = (u_swap_rb != 0) ? t.bgr : t.rgb;
    \\    o_frag = vec4(rgb + (1.0 - t.a), 1.0);
    \\}
;

pub const WebPass = struct {
    program: c_uint = 0,
    vao: c_uint = 0,
    vbo: c_uint = 0,
    tex: c_uint = 0,
    u_tex: c_int = -1,
    u_swap_rb: c_int = -1,
    u_rect: c_int = -1,
    /// Physical size of the allocated texture; 0 = none yet.
    tex_w: u16 = 0,
    tex_h: u16 = 0,
    /// A texture owned by SOMEBODY ELSE to draw instead of `tex` — the
    /// dma-buf import. 0 = draw the owned one. Never deleted here.
    ext_tex: c_uint = 0,
    /// LOGICAL size of the frame currently in the drawn texture — its
    /// physical size divided by the device scale it was rendered at.
    ///
    /// LOGICAL, deliberately, because that is the only space in which
    /// "does this frame match the widget" is a fair question. The
    /// widget's GL framebuffer is at GTK's INTEGER scale factor (2 on a
    /// 1.5x desktop, with GSK/the compositor doing the fractional step),
    /// while the engine renders at the surface's real fractional scale;
    /// comparing those two physical sizes would report a permanent
    /// mismatch on every fractional desktop. It is NOT `tex_w`/`tex_h`
    /// either, since a dma-buf import brings its own geometry.
    frame_lw: u16 = 0,
    frame_lh: u16 = 0,
    /// Whether the drawn texture's bytes are BGRA and need the shader's
    /// B/R swap. True for the uploaded (software) texture, false for an
    /// EGLImage import, whose FourCC already told the driver.
    swap_rb: bool = true,

    /// Drop cached GL handles without deleting them — the context they
    /// belonged to is already gone (re-realize after a reparent).
    pub fn forgetGL(self: *WebPass) void {
        self.program = 0;
        self.vao = 0;
        self.vbo = 0;
        self.tex = 0;
        self.u_tex = -1;
        self.u_swap_rb = -1;
        self.u_rect = -1;
        self.tex_w = 0;
        self.tex_h = 0;
        self.ext_tex = 0;
        self.swap_rb = true;
        self.frame_lw = 0;
        self.frame_lh = 0;
    }

    /// Draw `tex` (owned by the caller, e.g. a dma-buf import) instead
    /// of the uploaded texture, until `showOwned` takes it back.
    /// `lw`/`lh` are the frame's LOGICAL size — see `frame_lw`.
    pub fn showExternal(self: *WebPass, tex: c_uint, swap_rb: bool, lw: u16, lh: u16) void {
        self.ext_tex = tex;
        self.swap_rb = swap_rb;
        self.frame_lw = lw;
        self.frame_lh = lh;
    }

    /// Go back to drawing the texture this pass uploads into. `swap_rb`
    /// describes the bytes that were uploaded: true for CEF's BGRA.
    pub fn showOwned(self: *WebPass, swap_rb: bool, lw: u16, lh: u16) void {
        self.ext_tex = 0;
        self.swap_rb = swap_rb;
        self.frame_lw = lw;
        self.frame_lh = lh;
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
        self.u_swap_rb = c.glGetUniformLocation(self.program, "u_swap_rb");
        self.u_rect = c.glGetUniformLocation(self.program, "u_rect");

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

    /// Draw the current frame over the part of the viewport its LOGICAL
    /// size covers, anchored top-left — the borrowed texture when the
    /// face set one, else the uploaded one. `aw`/`ah` are the widget's
    /// LOGICAL allocation. No-op until both the program and a texture
    /// exist, so an unpainted view stays at whatever the caller cleared
    /// to.
    ///
    /// A frame whose logical size is not the widget's is PLACED, never
    /// stretched to fit: see the header. A frame that does match fills
    /// the viewport exactly, which is the steady state — it is reached
    /// within one frame, because the same allocation that changed the
    /// viewport has already been sent to the engine.
    pub fn draw(self: *WebPass, aw: u16, ah: u16) void {
        if (self.program == 0) return;
        const tex = if (self.ext_tex != 0) self.ext_tex else self.tex;
        if (tex == 0 or aw == 0 or ah == 0) return;
        const fw: f32 = @floatFromInt(if (self.frame_lw != 0) self.frame_lw else aw);
        const fh: f32 = @floatFromInt(if (self.frame_lh != 0) self.frame_lh else ah);
        // No clamp: a frame LARGER than the widget hangs off the right
        // and bottom and GL clips it, which is 1:1 and honest. Clamping
        // it to fit would be the stretch again, in the other direction.
        const sx = fw / @as(f32, @floatFromInt(aw));
        const sy = fh / @as(f32, @floatFromInt(ah));
        c.glDisable(c.GL_BLEND);
        c.glUseProgram(self.program);
        c.glActiveTexture(c.GL_TEXTURE0);
        c.glBindTexture(c.GL_TEXTURE_2D, tex);
        c.glUniform1i(self.u_tex, 0);
        c.glUniform1i(self.u_swap_rb, if (self.swap_rb) @as(c_int, 1) else 0);
        c.glUniform4f(self.u_rect, sx, sy, sx - 1.0, 1.0 - sy);
        c.glBindVertexArray(self.vao);
        c.glDrawArrays(c.GL_TRIANGLE_STRIP, 0, 4);
        c.glBindVertexArray(0);
    }
};
