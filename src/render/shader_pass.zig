//! Custom-shader pass — user-supplied shadertoy-style post-process.
//!
//! When active, the whole frame (bg, images, cells, overlays) renders
//! into an offscreen FBO; the user's fragment shader then maps that
//! texture onto the GtkGLArea's framebuffer. The user source defines
//! `void mainImage(out vec4 fragColor, in vec2 fragCoord)` and may use
//! `iChannel0` (the terminal frame), `iResolution`, `iTime`,
//! `iTimeDelta` and `iFrame` — the subset of shadertoy/ghostty
//! uniforms that makes existing CRT/glow shaders run unmodified.
//!
//! The CPU-side `Source` is owned by the Window (one file read shared
//! by every pane); each pane's ShaderPass compiles its own program in
//! its own GL context and recompiles when `Source.generation` moves.
//! A compile failure disables the pass (frame renders direct) and is
//! reported once per generation, never per frame.

const std = @import("std");
const c = @import("../c.zig").c;
const gl = @import("gl.zig");

pub const Source = struct {
    /// Wrapped-ready user fragment source (no header). null = off.
    src: ?[]const u8 = null,
    animate: bool = false,
    /// Bumped on every change; panes recompile lazily.
    generation: u32 = 0,
};

const VERT_SRC =
    \\#version 300 es
    \\in vec2 a_pos;
    \\out vec2 v_uv;
    \\void main() {
    \\    v_uv = a_pos * 0.5 + 0.5;
    \\    gl_Position = vec4(a_pos, 0.0, 1.0);
    \\}
;

const FRAG_HEADER =
    \\#version 300 es
    \\precision highp float;
    \\in vec2 v_uv;
    \\out vec4 sketerm_frag;
    \\uniform sampler2D iChannel0;
    \\uniform vec3 iResolution;
    \\uniform float iTime;
    \\uniform float iTimeDelta;
    \\uniform int iFrame;
    \\#line 1
    \\
;

const FRAG_FOOTER =
    \\
    \\void main() {
    \\    mainImage(sketerm_frag, v_uv * iResolution.xy);
    \\}
    \\
;

pub const ShaderPass = struct {
    program: c_uint = 0,
    vao: c_uint = 0,
    vbo: c_uint = 0,
    fbo: c_uint = 0,
    tex: c_uint = 0,
    tex_w: c_int = 0,
    tex_h: c_int = 0,
    u_channel0: c_int = -1,
    u_resolution: c_int = -1,
    u_time: c_int = -1,
    u_time_delta: c_int = -1,
    u_frame: c_int = -1,
    /// Generation the current program (or failure) was built from.
    built_generation: u32 = std.math.maxInt(u32),
    /// Compile failed for built_generation — render direct, stay quiet.
    failed: bool = false,
    frame_counter: i32 = 0,
    last_time_s: f32 = 0,
    /// Saved GtkGLArea framebuffer binding between begin()/finish().
    prev_fbo: c_int = 0,
    /// Window-owned shared source. Null until the Window wires it.
    source: ?*const Source = null,

    pub fn forgetGL(self: *ShaderPass) void {
        self.program = 0;
        self.vao = 0;
        self.vbo = 0;
        self.fbo = 0;
        self.tex = 0;
        self.tex_w = 0;
        self.tex_h = 0;
        self.built_generation = std.math.maxInt(u32);
        self.failed = false;
    }

    pub fn releaseGL(self: *ShaderPass) void {
        if (self.program != 0) c.glDeleteProgram(self.program);
        if (self.vao != 0) {
            var v = self.vao;
            c.glDeleteVertexArrays(1, &v);
        }
        if (self.vbo != 0) {
            var b = self.vbo;
            c.glDeleteBuffers(1, &b);
        }
        if (self.fbo != 0) {
            var f = self.fbo;
            c.glDeleteFramebuffers(1, &f);
        }
        if (self.tex != 0) {
            var t = self.tex;
            c.glDeleteTextures(1, &t);
        }
        self.forgetGL();
    }

    /// Whether the pass would redirect rendering this frame.
    pub fn active(self: *const ShaderPass) bool {
        const src = self.source orelse return false;
        if (src.src == null) return false;
        return !(self.failed and self.built_generation == src.generation);
    }

    fn ensureProgram(self: *ShaderPass, allocator: std.mem.Allocator) bool {
        const src = self.source orelse return false;
        const user = src.src orelse return false;
        if (self.built_generation == src.generation) return !self.failed;
        self.built_generation = src.generation;
        self.failed = true; // pessimistic until everything below lands

        if (self.program != 0) {
            c.glDeleteProgram(self.program);
            self.program = 0;
        }

        const full = std.mem.concat(allocator, u8, &.{ FRAG_HEADER, user, FRAG_FOOTER }) catch return false;
        defer allocator.free(full);
        self.program = gl.buildProgram(VERT_SRC, full) catch {
            std.debug.print("sketerm: custom_shader compile failed — rendering without it\n", .{});
            return false;
        };
        self.u_channel0 = c.glGetUniformLocation(self.program, "iChannel0");
        self.u_resolution = c.glGetUniformLocation(self.program, "iResolution");
        self.u_time = c.glGetUniformLocation(self.program, "iTime");
        self.u_time_delta = c.glGetUniformLocation(self.program, "iTimeDelta");
        self.u_frame = c.glGetUniformLocation(self.program, "iFrame");

        if (self.vao == 0) {
            const quad = [_]f32{ -1, -1, 3, -1, -1, 3 }; // fullscreen triangle
            c.glGenVertexArrays(1, &self.vao);
            c.glGenBuffers(1, &self.vbo);
            c.glBindVertexArray(self.vao);
            c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbo);
            c.glBufferData(c.GL_ARRAY_BUFFER, quad.len * @sizeOf(f32), &quad, c.GL_STATIC_DRAW);
            const a_pos: c_uint = @intCast(c.glGetAttribLocation(self.program, "a_pos"));
            c.glEnableVertexAttribArray(a_pos);
            c.glVertexAttribPointer(a_pos, 2, c.GL_FLOAT, c.GL_FALSE, 0, null);
            c.glBindVertexArray(0);
        }
        self.failed = false;
        return true;
    }

    fn ensureTarget(self: *ShaderPass, w: c_int, h: c_int) bool {
        if (self.fbo != 0 and self.tex_w == w and self.tex_h == h) return true;
        if (self.fbo == 0) c.glGenFramebuffers(1, &self.fbo);
        if (self.tex == 0) c.glGenTextures(1, &self.tex);
        c.glBindTexture(c.GL_TEXTURE_2D, self.tex);
        c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA8, w, h, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, null);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.fbo);
        c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, self.tex, 0);
        const ok = c.glCheckFramebufferStatus(c.GL_FRAMEBUFFER) == c.GL_FRAMEBUFFER_COMPLETE;
        if (ok) {
            self.tex_w = w;
            self.tex_h = h;
        }
        return ok;
    }

    /// Redirect rendering into the offscreen target. Returns false
    /// when the pass is off/broken — caller renders direct. On true,
    /// `finish` MUST run after the scene passes.
    pub fn begin(self: *ShaderPass, allocator: std.mem.Allocator, w: c_int, h: c_int) bool {
        if (!self.ensureProgram(allocator)) return false;
        // GtkGLArea renders into its own FBO, never 0 — save it.
        c.glGetIntegerv(c.GL_DRAW_FRAMEBUFFER_BINDING, &self.prev_fbo);
        if (!self.ensureTarget(w, h)) return false;
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.fbo);
        return true;
    }

    /// Run the user shader: offscreen texture → GtkGLArea framebuffer.
    /// `time_s` is monotonic seconds (pane-level epoch).
    pub fn finish(self: *ShaderPass, w: c_int, h: c_int, time_s: f32) void {
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, @intCast(self.prev_fbo));
        c.glViewport(0, 0, w, h);
        c.glDisable(c.GL_BLEND);
        c.glUseProgram(self.program);
        c.glActiveTexture(c.GL_TEXTURE0);
        c.glBindTexture(c.GL_TEXTURE_2D, self.tex);
        c.glUniform1i(self.u_channel0, 0);
        c.glUniform3f(self.u_resolution, @floatFromInt(w), @floatFromInt(h), 1.0);
        c.glUniform1f(self.u_time, time_s);
        c.glUniform1f(self.u_time_delta, @max(0.0, time_s - self.last_time_s));
        c.glUniform1i(self.u_frame, self.frame_counter);
        self.last_time_s = time_s;
        self.frame_counter +%= 1;
        c.glBindVertexArray(self.vao);
        c.glDrawArrays(c.GL_TRIANGLES, 0, 3);
        c.glBindVertexArray(0);
        c.glEnable(c.GL_BLEND);
    }
};
