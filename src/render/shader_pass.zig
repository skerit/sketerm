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
    /// Config-driven `shader_param.<name>` overrides for the
    /// shader's tunable uniforms. Points into the live Config (the
    /// Window re-points it on every reload); values are read each
    /// frame, so changes apply live without recompiling.
    overrides: []const ParamKV = &.{},
};

/// One `shader_param.<name> = <value>` config entry.
pub const ParamKV = struct {
    name: []const u8,
    value: f32,
};

pub const MAX_PARAMS = 16;

/// A tunable uniform declared by the shader via a default line:
///   //@param <name> <default>
/// The shader also declares `uniform float <name>;` and uses it.
pub const Param = struct {
    name_buf: [32]u8 = undefined,
    name_len: u8 = 0,
    default_value: f32 = 0,
    /// Uniform location in the built program; -1 = absent/unused.
    loc: c_int = -1,

    pub fn name(self: *const Param) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

/// Scan shader source for `//@param name default` lines. Pure —
/// unit-tested without GL. Malformed lines are skipped; at most
/// MAX_PARAMS are collected.
pub fn parseParams(src: []const u8, out: *[MAX_PARAMS]Param) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |line_raw| {
        if (count >= MAX_PARAMS) break;
        const line = std.mem.trim(u8, line_raw, " \t\r");
        const marker = "//@param ";
        if (!std.mem.startsWith(u8, line, marker)) continue;
        var it = std.mem.tokenizeAny(u8, line[marker.len..], " \t");
        const pname = it.next() orelse continue;
        const pdefault = it.next() orelse continue;
        if (pname.len == 0 or pname.len > 31) continue;
        const val = std.fmt.parseFloat(f32, pdefault) catch continue;
        var p = Param{ .default_value = val, .name_len = @intCast(pname.len) };
        @memcpy(p.name_buf[0..pname.len], pname);
        out[count] = p;
        count += 1;
    }
    return count;
}

test "parseParams: extracts name/default, skips malformed" {
    const src =
        "// a comment\n" ++
        "//@param glow 0.55\n" ++
        "  //@param vignette 0.28  // trailing words ignored\n" ++
        "//@param broken\n" ++
        "//@param bad_value abc\n" ++
        "uniform float glow;\n";
    var params: [MAX_PARAMS]Param = undefined;
    const n = parseParams(src, &params);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("glow", params[0].name());
    try std.testing.expectEqual(@as(f32, 0.55), params[0].default_value);
    try std.testing.expectEqualStrings("vignette", params[1].name());
    try std.testing.expectEqual(@as(f32, 0.28), params[1].default_value);
}

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
    /// Tunable uniforms parsed from `//@param` lines at build time.
    params: [MAX_PARAMS]Param = undefined,
    params_len: usize = 0,

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

        // Tunable uniforms: //@param declarations → locations. A
        // param whose uniform got optimized out keeps loc -1 and is
        // skipped at upload.
        self.params_len = parseParams(user, &self.params);
        for (self.params[0..self.params_len]) |*p| {
            var name_z: [33]u8 = undefined;
            @memcpy(name_z[0..p.name_len], p.name());
            name_z[p.name_len] = 0;
            p.loc = c.glGetUniformLocation(self.program, @ptrCast(&name_z));
        }

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
        // Tunable params: shader default, overridden by any matching
        // `shader_param.<name>` config entry. Uploaded every frame so
        // a config reload re-tunes live without recompiling.
        const overrides: []const ParamKV = if (self.source) |s| s.overrides else &.{};
        for (self.params[0..self.params_len]) |p| {
            if (p.loc < 0) continue;
            var value = p.default_value;
            for (overrides) |kv| {
                if (std.mem.eql(u8, kv.name, p.name())) {
                    value = kv.value;
                    break;
                }
            }
            c.glUniform1f(p.loc, value);
        }
        self.last_time_s = time_s;
        self.frame_counter +%= 1;
        c.glBindVertexArray(self.vao);
        c.glDrawArrays(c.GL_TRIANGLES, 0, 3);
        c.glBindVertexArray(0);
        c.glEnable(c.GL_BLEND);
    }
};
