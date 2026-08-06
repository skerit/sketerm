//! Blend-space plumbing for `text_blending = native | linear |
//! linear_corrected`.
//!
//! ## Why
//!
//! Every pass historically blended with `glBlendFunc(GL_SRC_ALPHA,
//! GL_ONE_MINUS_SRC_ALPHA)` straight into the GtkGLArea framebuffer,
//! whose values are sRGB-ENCODED. sRGB values are not proportional to
//! light, so a half-covered edge pixel between black and white lands
//! at ~21% of the light it should carry. Visible as a dark fringe
//! wherever fg and bg are complementary (red on green) and as
//! light-on-dark text reading thin.
//!
//! ## How
//!
//! `linear` and `linear_corrected` redirect the whole pane frame into
//! `LinearTarget`: an offscreen `GL_SRGB8_ALPHA8` texture. On that
//! format the GL blend unit DECODES both operands to linear light,
//! blends, and RE-ENCODES on write — which is exactly the physically
//! correct thing, and it costs no extra precision because the storage
//! stays 8-bit sRGB. `finish()` then resolves that texture back to the
//! RGBA8 GtkGLArea framebuffer with a fullscreen triangle.
//!
//! This detour is unavoidable: `GtkGLArea`'s framebuffer is a
//! hardcoded `GL_RGBA8` texture (a literal inside a static GTK
//! function — no property, no vfunc), so `GL_FRAMEBUFFER_SRGB` on the
//! default framebuffer is not reachable. See `docs/config.md` for the
//! cost note.
//!
//! Because the target sRGB-encodes on write, EVERY fragment shader
//! feeding it must hand it LINEAR light — hence `GLSL_HELPERS` and the
//! `sk_out()` wrapper every pass's `o_frag` assignment goes through.
//!
//! `linear_corrected` additionally rewrites the glyph coverage alpha
//! so a linear blend reproduces `native`'s apparent stem weight. The
//! maths is ghostty's, verbatim in intent (see `sk_correctCoverage`).

const std = @import("std");
const c = @import("../c.zig").c;
const gl = @import("gl.zig");

/// Wire value of `config.TextBlending`, mirrored here so the render
/// layer does not import config (which compiles into `sketerm-mux`).
pub const Mode = enum(c_int) {
    native = 0,
    linear = 1,
    linear_corrected = 2,

    pub fn needsLinearTarget(self: Mode) bool {
        return self != .native;
    }
};

/// GLSL prelude appended to every fragment shader that writes into the
/// pane framebuffer. Carries NO `#version` / `precision` line —
/// `gl.compileShader` injects the per-API header (CLAUDE.md).
///
/// `u_blend_mode` is `Mode` as an int. When it is 0 every helper is an
/// identity, so `native` output is byte-for-byte what it was before
/// this file existed.
pub const GLSL_HELPERS =
    \\uniform int u_blend_mode;
    \\
    \\const vec3 SK_LUMA = vec3(0.2126, 0.7152, 0.0722);
    \\
    \\// sRGB EOTF / OETF, scalar and vector. Standard curve, no
    \\// custom constants.
    \\float sk_linearize(float v) {
    \\    return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4);
    \\}
    \\vec3 sk_linearize3(vec3 v) {
    \\    vec3 lo = v / 12.92;
    \\    vec3 hi = pow((v + 0.055) / 1.055, vec3(2.4));
    \\    return mix(lo, hi, step(vec3(0.04045), v));
    \\}
    \\float sk_unlinearize(float v) {
    \\    return v <= 0.0031308 ? v * 12.92 : pow(v, 1.0 / 2.4) * 1.055 - 0.055;
    \\}
    \\
    \\// Final write. In `native` the fragment goes out untouched; in
    \\// the linear modes the destination sRGB-encodes on write, so the
    \\// shader owes it linear light. Alpha is never encoded (sRGB
    \\// framebuffers keep the alpha channel linear).
    \\vec4 sk_out(vec4 col) {
    \\    if (u_blend_mode == 0) return col;
    \\    return vec4(sk_linearize3(col.rgb), col.a);
    \\}
    \\
    \\// Linear-blending weight correction (ghostty's
    \\// `use_linear_correction`; algebraically identical to kitty's
    \\// `text_composition_strategy legacy`).
    \\//
    \\// Solve for the coverage a' that makes a LINEAR interpolation
    \\// bg -> fg land on the same LUMINANCE a gamma-space
    \\// interpolation with the original coverage `a` would have
    \\// produced. `fg`/`bg` are sRGB-encoded here; the luminances are
    \\// taken on linear light, gamma-blended, then mapped back onto
    \\// [bg_l, fg_l].
    \\//
    \\// Only mode 2 corrects. Mode 1 (`linear`) deliberately does not:
    \\// its thinner-dark / thicker-light text IS the mode.
    \\float sk_correctCoverage(float a, vec3 fg, vec3 bg) {
    \\    if (u_blend_mode != 2) return a;
    \\    float fg_l = dot(sk_linearize3(fg), SK_LUMA);
    \\    float bg_l = dot(sk_linearize3(bg), SK_LUMA);
    \\    // Guard the degenerate case: fg and bg the same brightness
    \\    // makes the remap a 0/0. Epsilon is ghostty's.
    \\    if (abs(fg_l - bg_l) <= 0.001) return a;
    \\    float blend_l = sk_linearize(sk_unlinearize(fg_l) * a + sk_unlinearize(bg_l) * (1.0 - a));
    \\    return clamp((blend_l - bg_l) / (fg_l - bg_l), 0.0, 1.0);
    \\}
    \\
;

/// Resolve the linear target back to the RGBA8 GtkGLArea framebuffer.
/// Sampling an sRGB texture hardware-decodes to linear, so the shader
/// re-encodes; the round trip is identity to 8-bit.
pub const RESOLVE_VERT_SRC =
    \\in vec2 a_pos;
    \\out vec2 v_uv;
    \\void main() {
    \\    v_uv = a_pos * 0.5 + 0.5;
    \\    gl_Position = vec4(a_pos, 0.0, 1.0);
    \\}
;

pub const RESOLVE_FRAG_SRC =
    \\in vec2 v_uv;
    \\uniform sampler2D u_src;
    \\out vec4 o_frag;
    \\vec3 sk_unlinearize3(vec3 v) {
    \\    vec3 lo = v * 12.92;
    \\    vec3 hi = pow(v, vec3(1.0 / 2.4)) * 1.055 - 0.055;
    \\    return mix(lo, hi, step(vec3(0.0031308), v));
    \\}
    \\void main() {
    \\    vec4 t = texture(u_src, v_uv);
    \\    o_frag = vec4(sk_unlinearize3(t.rgb), t.a);
    \\}
;

/// sRGB offscreen target the linear modes render into.
///
/// Lifetime mirrors `ShaderPass`: `forgetGL` after a context loss
/// (reparenting unrealizes the GtkGLArea and destroys its
/// GdkGLContext — see CLAUDE.md), `releaseGL` on an orderly unrealize
/// while the context is still current.
pub const LinearTarget = struct {
    fbo: c_uint = 0,
    tex: c_uint = 0,
    tex_w: c_int = 0,
    tex_h: c_int = 0,
    program: c_uint = 0,
    vao: c_uint = 0,
    vbo: c_uint = 0,
    u_src: c_int = -1,
    /// Framebuffer that was bound when `begin` redirected. GtkGLArea
    /// renders into its own FBO, never 0.
    prev_fbo: c_int = 0,
    /// Set by `begin`, cleared by `finish` — the caller uses it to
    /// decide whether a matching `finish` is owed.
    engaged: bool = false,
    failed: bool = false,

    /// Drop every GL name without deleting: the context that owned
    /// them is gone. Non-zero cached ids from a dead context render
    /// silent black.
    pub fn forgetGL(self: *LinearTarget) void {
        self.fbo = 0;
        self.tex = 0;
        self.tex_w = 0;
        self.tex_h = 0;
        self.program = 0;
        self.vao = 0;
        self.vbo = 0;
        self.u_src = -1;
        self.engaged = false;
        self.failed = false;
    }

    /// Delete GL objects — the caller must have the owning context
    /// current.
    pub fn releaseGL(self: *LinearTarget) void {
        if (self.fbo != 0) {
            var f = self.fbo;
            c.glDeleteFramebuffers(1, &f);
        }
        if (self.tex != 0) {
            var t = self.tex;
            c.glDeleteTextures(1, &t);
        }
        if (self.vbo != 0) {
            var b = self.vbo;
            c.glDeleteBuffers(1, &b);
        }
        if (self.vao != 0) {
            var v = self.vao;
            c.glDeleteVertexArrays(1, &v);
        }
        if (self.program != 0) c.glDeleteProgram(self.program);
        self.forgetGL();
    }

    fn ensureProgram(self: *LinearTarget) bool {
        if (self.program != 0) return true;
        self.program = gl.buildProgram(RESOLVE_VERT_SRC, RESOLVE_FRAG_SRC) catch {
            std.debug.print("sketerm: text_blending resolve shader failed — rendering native\n", .{});
            return false;
        };
        self.u_src = c.glGetUniformLocation(self.program, "u_src");
        const quad = [_]f32{ -1, -1, 3, -1, -1, 3 }; // fullscreen triangle
        c.glGenVertexArrays(1, &self.vao);
        c.glGenBuffers(1, &self.vbo);
        c.glBindVertexArray(self.vao);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbo);
        c.glBufferData(c.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(quad)), &quad, c.GL_STATIC_DRAW);
        const loc = c.glGetAttribLocation(self.program, "a_pos");
        if (loc >= 0) {
            const l: c_uint = @intCast(loc);
            c.glEnableVertexAttribArray(l);
            c.glVertexAttribPointer(l, 2, c.GL_FLOAT, c.GL_FALSE, 0, null);
        }
        c.glBindVertexArray(0);
        return true;
    }

    fn ensureTarget(self: *LinearTarget, w: c_int, h: c_int) bool {
        if (self.fbo != 0 and self.tex_w == w and self.tex_h == h) return true;
        if (self.fbo == 0) c.glGenFramebuffers(1, &self.fbo);
        if (self.tex == 0) c.glGenTextures(1, &self.tex);
        c.glBindTexture(c.GL_TEXTURE_2D, self.tex);
        // SRGB8_ALPHA8 is color-renderable in GLES 3.0 core and
        // desktop GL 3.0 core — no extension check needed on either
        // half of `gl.Api`.
        c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_SRGB8_ALPHA8, w, h, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, null);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.fbo);
        c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, self.tex, 0);
        const ok = c.glCheckFramebufferStatus(c.GL_FRAMEBUFFER) == c.GL_FRAMEBUFFER_COMPLETE;
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, @intCast(self.prev_fbo));
        if (!ok) {
            std.debug.print("sketerm: text_blending sRGB target incomplete — rendering native\n", .{});
            return false;
        }
        self.tex_w = w;
        self.tex_h = h;
        return true;
    }

    /// Redirect subsequent drawing into the sRGB target. Returns false
    /// (and leaves the binding alone) for `native`, or if the target
    /// could not be built — the caller then renders `native`.
    pub fn begin(self: *LinearTarget, mode: Mode, w: c_int, h: c_int) bool {
        if (!mode.needsLinearTarget() or self.failed or w <= 0 or h <= 0) return false;
        c.glGetIntegerv(c.GL_DRAW_FRAMEBUFFER_BINDING, &self.prev_fbo);
        if (!self.ensureProgram() or !self.ensureTarget(w, h)) {
            self.failed = true;
            return false;
        }
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.fbo);
        // Desktop GL gates sRGB encode-on-write behind an enable; GLES
        // 3.0 has no such switch and always encodes for an sRGB
        // attachment, where the enum would just raise GL_INVALID_ENUM.
        if (gl.api == .gl_core) c.glEnable(c.GL_FRAMEBUFFER_SRGB);
        self.engaged = true;
        return true;
    }

    /// Resolve the sRGB target back onto whatever was bound before
    /// `begin`, re-encoding to that framebuffer's plain RGBA8.
    pub fn finish(self: *LinearTarget, w: c_int, h: c_int) void {
        if (!self.engaged) return;
        self.engaged = false;
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, @intCast(self.prev_fbo));
        // Must be off for the resolve itself: the destination is a
        // plain RGBA8 framebuffer and the shader already encoded.
        if (gl.api == .gl_core) c.glDisable(c.GL_FRAMEBUFFER_SRGB);
        c.glViewport(0, 0, w, h);
        c.glDisable(c.GL_BLEND);
        c.glUseProgram(self.program);
        c.glActiveTexture(c.GL_TEXTURE0);
        c.glBindTexture(c.GL_TEXTURE_2D, self.tex);
        c.glUniform1i(self.u_src, 0);
        c.glBindVertexArray(self.vao);
        c.glDrawArrays(c.GL_TRIANGLES, 0, 3);
        c.glBindVertexArray(0);
        c.glEnable(c.GL_BLEND);
    }
};

/// sRGB EOTF — CPU mirror of `sk_linearize`, used for the clear colour
/// (`glClear` writes through the same sRGB encode as a fragment does,
/// so the clear colour must be handed over as linear light).
pub fn linearize(v: f32) f32 {
    return if (v <= 0.04045) v / 12.92 else std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
}

/// sRGB OETF — inverse of `linearize`.
pub fn unlinearize(v: f32) f32 {
    return if (v <= 0.0031308) v * 12.92 else std.math.pow(f32, v, 1.0 / 2.4) * 1.055 - 0.055;
}

/// Clear colour for a pane frame. RGB is handed to `glClearColor` in
/// whatever space the bound framebuffer stores, so the linear modes
/// need it linearized; alpha is never encoded.
pub fn clearColor(mode: Mode, rgba: [4]f32) [4]f32 {
    if (!mode.needsLinearTarget()) return rgba;
    return .{ linearize(rgba[0]), linearize(rgba[1]), linearize(rgba[2]), rgba[3] };
}

/// CPU mirror of `sk_correctCoverage` — the reference the shader is
/// tested against. `fg`/`bg` are sRGB-encoded, `a` is glyph coverage.
pub fn correctCoverage(a: f32, fg: [3]f32, bg: [3]f32) f32 {
    const luma = [3]f32{ 0.2126, 0.7152, 0.0722 };
    var fg_l: f32 = 0;
    var bg_l: f32 = 0;
    for (0..3) |i| {
        fg_l += luma[i] * linearize(fg[i]);
        bg_l += luma[i] * linearize(bg[i]);
    }
    if (@abs(fg_l - bg_l) <= 0.001) return a;
    const blend_l = linearize(unlinearize(fg_l) * a + unlinearize(bg_l) * (1.0 - a));
    return std.math.clamp((blend_l - bg_l) / (fg_l - bg_l), 0.0, 1.0);
}

test "linearize / unlinearize round-trip" {
    var v: f32 = 0.0;
    while (v <= 1.0) : (v += 1.0 / 255.0) {
        try std.testing.expectApproxEqAbs(v, unlinearize(linearize(v)), 1e-5);
    }
}

test "correctCoverage is identity at full and zero coverage" {
    const white = [3]f32{ 1, 1, 1 };
    const black = [3]f32{ 0, 0, 0 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), correctCoverage(0.0, white, black), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), correctCoverage(1.0, white, black), 1e-5);
}

test "correctCoverage reproduces the gamma-space luminance" {
    // The whole point: blending bg -> fg LINEARLY with the corrected
    // coverage must land on the same luminance a gamma-space blend
    // with the original coverage produces.
    const fg = [3]f32{ 1, 1, 1 };
    const bg = [3]f32{ 0, 0, 0 };
    const a: f32 = 0.5;
    const a2 = correctCoverage(a, fg, bg);
    const fg_l = linearize(1.0);
    const bg_l = linearize(0.0);
    const want = linearize(unlinearize(fg_l) * a + unlinearize(bg_l) * (1 - a));
    try std.testing.expectApproxEqAbs(want, bg_l + a2 * (fg_l - bg_l), 1e-4);
    // White-on-black at 50% coverage: gamma blending puts the edge at
    // 0.5 encoded = 21.4% of the light. The corrected coverage must
    // therefore be ~0.214, far below the naive 0.5.
    try std.testing.expectApproxEqAbs(@as(f32, 0.2140), a2, 1e-3);
}

test "correctCoverage bails out when fg and bg have equal luminance" {
    // Red vs a green of matching luminance: the remap would be 0/0.
    const fg = [3]f32{ 1, 0, 0 };
    const bg_l = linearize(1.0) * 0.2126;
    // Green channel value whose linear luminance equals red's.
    const g = unlinearize(bg_l / 0.7152);
    const bg = [3]f32{ 0, g, 0 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), correctCoverage(0.5, fg, bg), 1e-6);
}

test "clearColor only converts in the linear modes" {
    const rgba = [4]f32{ 0.5, 0.25, 1.0, 0.8 };
    try std.testing.expectEqual(rgba, clearColor(.native, rgba));
    const lin = clearColor(.linear, rgba);
    try std.testing.expectApproxEqAbs(linearize(0.5), lin[0], 1e-6);
    try std.testing.expectEqual(@as(f32, 0.8), lin[3]);
}
