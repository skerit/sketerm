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
    /// Directory of the shader file (owner-managed memory) —
    /// relative //@texture paths resolve against it. null = only
    /// absolute and builtin: paths work.
    dir: ?[]const u8 = null,
};

pub const MAX_TEXTURES = 4;

/// An extra texture input declared by the shader:
///   //@texture <uniform_name> <path|builtin:noise> ["Label"]
/// Bound to texture units 2.. (0 = iChannel0, 1 = iChannel1).
/// `builtin:noise` is a generated 256×256 RGBA noise tile
/// (GL_REPEAT) — what cool-retro-term-style static/jitter wants,
/// no asset file needed. Image paths load via stb (PNG/JPEG/BMP),
/// relative to the shader file.
pub const TextureDecl = struct {
    name_buf: [32]u8 = undefined,
    name_len: u8 = 0,
    path_buf: [256]u8 = undefined,
    path_len: u8 = 0,

    pub fn name(self: *const TextureDecl) []const u8 {
        return self.name_buf[0..self.name_len];
    }
    pub fn path(self: *const TextureDecl) []const u8 {
        return self.path_buf[0..self.path_len];
    }
};

/// One `shader_param.<name> = <value>` config entry. Float params
/// carry `value`; color params (hex `#rrggbb` in the config) carry
/// `color` and ignore `value`.
pub const ParamKV = struct {
    name: []const u8,
    value: f32 = 0,
    color: ?[3]f32 = null,
};

pub const MAX_PARAMS = 24;

pub const ParamKind = enum { float, color };

/// A tunable uniform declared by the shader. Two float syntaxes:
///   #pragma parameter <name> "<Label>" <default> <min> <max> [step]
///       (RetroArch-compatible — their shaders' params Just Work)
///   //@param <name> <default> [min max [step]] ["Label"]
/// and a color (vec3) syntax RetroArch has no equivalent for:
///   //@color <name> <r> <g> <b> ["Label"]
/// The shader also declares `uniform float/vec3 <name>;` itself.
pub const Param = struct {
    name_buf: [32]u8 = undefined,
    name_len: u8 = 0,
    label_buf: [64]u8 = undefined,
    label_len: u8 = 0,
    kind: ParamKind = .float,
    default_value: f32 = 0,
    min: f32 = 0,
    max: f32 = 1,
    step: f32 = 0.01,
    default_color: [3]f32 = .{ 1, 1, 1 },
    /// Uniform location in the built program; -1 = absent/unused.
    loc: c_int = -1,

    pub fn name(self: *const Param) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    /// UI label: the declared one, else the uniform name.
    pub fn label(self: *const Param) []const u8 {
        if (self.label_len > 0) return self.label_buf[0..self.label_len];
        return self.name();
    }
};

/// Shader self-description for the config dialog header.
pub const Meta = struct {
    title_buf: [64]u8 = undefined,
    title_len: u8 = 0,
    desc_buf: [256]u8 = undefined,
    desc_len: u8 = 0,

    pub fn title(self: *const Meta) []const u8 {
        return self.title_buf[0..self.title_len];
    }
    pub fn desc(self: *const Meta) []const u8 {
        return self.desc_buf[0..self.desc_len];
    }
};

fn setName(p: *Param, s: []const u8) bool {
    if (s.len == 0 or s.len > 31) return false;
    @memcpy(p.name_buf[0..s.len], s);
    p.name_len = @intCast(s.len);
    return true;
}

fn setLabel(p: *Param, s: []const u8) void {
    const n = @min(s.len, p.label_buf.len);
    @memcpy(p.label_buf[0..n], s[0..n]);
    p.label_len = @intCast(n);
}

/// Take a possibly-quoted token: `"Two words"` or a bare word.
fn takeQuoted(rest: []const u8) ?struct { text: []const u8, remaining: []const u8 } {
    const t = std.mem.trimStart(u8, rest, " \t");
    if (t.len == 0) return null;
    if (t[0] == '"') {
        const end = std.mem.indexOfScalarPos(u8, t, 1, '"') orelse return null;
        return .{ .text = t[1..end], .remaining = t[end + 1 ..] };
    }
    const end = std.mem.indexOfAny(u8, t, " \t") orelse t.len;
    return .{ .text = t[0..end], .remaining = t[end..] };
}

/// Scan shader source for parameter declarations + meta. Pure —
/// unit-tested without GL. Malformed lines are skipped; at most
/// MAX_PARAMS are collected.
pub fn parseParams(src: []const u8, out: *[MAX_PARAMS]Param, meta: ?*Meta) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");

        if (meta) |m| {
            if (std.mem.startsWith(u8, line, "//@name ")) {
                const t = std.mem.trim(u8, line["//@name ".len..], " \t");
                const n = @min(t.len, m.title_buf.len);
                @memcpy(m.title_buf[0..n], t[0..n]);
                m.title_len = @intCast(n);
                continue;
            }
            if (std.mem.startsWith(u8, line, "//@desc ")) {
                const t = std.mem.trim(u8, line["//@desc ".len..], " \t");
                const n = @min(t.len, m.desc_buf.len);
                @memcpy(m.desc_buf[0..n], t[0..n]);
                m.desc_len = @intCast(n);
                continue;
            }
        }
        if (count >= MAX_PARAMS) continue;

        // RetroArch: #pragma parameter name "Label" default min max [step]
        if (std.mem.startsWith(u8, line, "#pragma parameter ")) {
            var rest = line["#pragma parameter ".len..];
            var p = Param{};
            const nm = takeQuoted(rest) orelse continue;
            if (!setName(&p, nm.text)) continue;
            rest = nm.remaining;
            const lb = takeQuoted(rest) orelse continue;
            setLabel(&p, lb.text);
            rest = lb.remaining;
            var it = std.mem.tokenizeAny(u8, rest, " \t");
            p.default_value = std.fmt.parseFloat(f32, it.next() orelse continue) catch continue;
            p.min = std.fmt.parseFloat(f32, it.next() orelse continue) catch continue;
            p.max = std.fmt.parseFloat(f32, it.next() orelse continue) catch continue;
            if (it.next()) |s| p.step = std.fmt.parseFloat(f32, s) catch 0.01;
            if (p.max <= p.min) continue;
            out[count] = p;
            count += 1;
            continue;
        }

        // //@param name default [min max [step]] ["Label"]
        if (std.mem.startsWith(u8, line, "//@param ")) {
            var rest = line["//@param ".len..];
            var p = Param{};
            const nm = takeQuoted(rest) orelse continue;
            if (!setName(&p, nm.text)) continue;
            rest = nm.remaining;
            const dv = takeQuoted(rest) orelse continue;
            p.default_value = std.fmt.parseFloat(f32, dv.text) catch continue;
            rest = dv.remaining;
            // Optional min/max/step, then optional quoted label.
            var floats: [3]f32 = undefined;
            var nfloats: usize = 0;
            while (nfloats < 3) {
                const tk = takeQuoted(rest) orelse break;
                if (tk.text.len > 0 and tk.text[0] == '/') break; // trailing comment
                const v = std.fmt.parseFloat(f32, tk.text) catch break;
                floats[nfloats] = v;
                nfloats += 1;
                rest = tk.remaining;
            }
            if (nfloats >= 2) {
                p.min = floats[0];
                p.max = floats[1];
                if (nfloats == 3) p.step = floats[2];
            } else {
                // Derive a usable range around the default.
                p.min = 0;
                p.max = @max(1.0, p.default_value * 2.0);
            }
            if (takeQuoted(rest)) |lb| {
                if (lb.text.len > 0 and lb.text[0] != '/') setLabel(&p, lb.text);
            }
            if (p.max <= p.min) continue;
            out[count] = p;
            count += 1;
            continue;
        }

        // //@color name r g b ["Label"]
        if (std.mem.startsWith(u8, line, "//@color ")) {
            var rest = line["//@color ".len..];
            var p = Param{ .kind = .color };
            const nm = takeQuoted(rest) orelse continue;
            if (!setName(&p, nm.text)) continue;
            rest = nm.remaining;
            var ok = true;
            for (0..3) |i| {
                const tk = takeQuoted(rest) orelse {
                    ok = false;
                    break;
                };
                p.default_color[i] = std.fmt.parseFloat(f32, tk.text) catch {
                    ok = false;
                    break;
                };
                rest = tk.remaining;
            }
            if (!ok) continue;
            if (takeQuoted(rest)) |lb| {
                if (lb.text.len > 0 and lb.text[0] != '/') setLabel(&p, lb.text);
            }
            out[count] = p;
            count += 1;
            continue;
        }
    }
    return count;
}

test "parseParams: //@param with range/label, defaults derived" {
    const src =
        "//@param glow 0.55 0.0 2.0 0.05 \"Glow strength\"\n" ++
        "  //@param vignette 0.28\n" ++
        "//@param broken\n" ++
        "//@param bad_value abc\n" ++
        "uniform float glow;\n";
    var params: [MAX_PARAMS]Param = undefined;
    const n = parseParams(src, &params, null);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("glow", params[0].name());
    try std.testing.expectEqualStrings("Glow strength", params[0].label());
    try std.testing.expectEqual(@as(f32, 0.55), params[0].default_value);
    try std.testing.expectEqual(@as(f32, 2.0), params[0].max);
    try std.testing.expectEqual(@as(f32, 0.05), params[0].step);
    try std.testing.expectEqualStrings("vignette", params[1].name());
    try std.testing.expectEqualStrings("vignette", params[1].label());
    try std.testing.expectEqual(@as(f32, 1.0), params[1].max);
}

test "parseParams: RetroArch #pragma parameter + meta + color" {
    const src =
        "//@name Amber CRT\n" ++
        "//@desc Phosphor monitor with scanlines.\n" ++
        "#pragma parameter SCANLINE \"Scanline strength\" 0.22 0.0 1.0 0.01\n" ++
        "#pragma parameter CURV \"Curvature\" 0.06 0.0 0.5\n" ++
        "//@color phosphor 1.0 0.7 0.2 \"Phosphor tint\"\n";
    var params: [MAX_PARAMS]Param = undefined;
    var meta = Meta{};
    const n = parseParams(src, &params, &meta);
    try std.testing.expectEqualStrings("Amber CRT", meta.title());
    try std.testing.expectEqualStrings("Phosphor monitor with scanlines.", meta.desc());
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("SCANLINE", params[0].name());
    try std.testing.expectEqualStrings("Scanline strength", params[0].label());
    try std.testing.expectEqual(@as(f32, 0.01), params[0].step);
    try std.testing.expectEqualStrings("CURV", params[1].name());
    try std.testing.expectEqual(@as(f32, 0.5), params[1].max);
    try std.testing.expectEqual(ParamKind.color, params[2].kind);
    try std.testing.expectEqual(@as(f32, 0.7), params[2].default_color[1]);
    try std.testing.expectEqualStrings("Phosphor tint", params[2].label());
}

/// Scan shader source for //@texture declarations. Pure.
pub fn parseTextures(src: []const u8, out: *[MAX_TEXTURES]TextureDecl) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |line_raw| {
        if (count >= MAX_TEXTURES) break;
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "//@texture ")) continue;
        var rest = line["//@texture ".len..];
        var t = TextureDecl{};
        const nm = takeQuoted(rest) orelse continue;
        if (nm.text.len == 0 or nm.text.len > 31) continue;
        @memcpy(t.name_buf[0..nm.text.len], nm.text);
        t.name_len = @intCast(nm.text.len);
        rest = nm.remaining;
        const pt = takeQuoted(rest) orelse continue;
        if (pt.text.len == 0 or pt.text.len > 255) continue;
        @memcpy(t.path_buf[0..pt.text.len], pt.text);
        t.path_len = @intCast(pt.text.len);
        out[count] = t;
        count += 1;
    }
    return count;
}

test "parseTextures: name + path, builtin allowed" {
    const src =
        "//@texture noiseTex builtin:noise\n" ++
        "//@texture lut \"sub dir/mask.png\"\n" ++
        "//@texture broken\n";
    var out: [MAX_TEXTURES]TextureDecl = undefined;
    const n = parseTextures(src, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("noiseTex", out[0].name());
    try std.testing.expectEqualStrings("builtin:noise", out[0].path());
    try std.testing.expectEqualStrings("sub dir/mask.png", out[1].path());
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
    \\uniform sampler2D iChannel1;
    \\uniform vec3 iResolution;
    \\uniform float iTime;
    \\uniform float iTimeDelta;
    \\uniform int iFrame;
    \\uniform float sketerm_dim_darken;
    \\uniform float sketerm_dim_desat;
    \\#line 1
    \\
;

// The footer applies the inactive-pane dim to the shader's OUTPUT —
// a single uniform desaturate toward luma then a uniform darken, so
// the whole pane recedes without altering any colour relationship
// (both default 0 = identity for a focused pane).
const FRAG_FOOTER =
    \\
    \\void main() {
    \\    mainImage(sketerm_frag, v_uv * iResolution.xy);
    \\    float sketerm_luma = dot(sketerm_frag.rgb, vec3(0.2126, 0.7152, 0.0722));
    \\    sketerm_frag.rgb = mix(sketerm_frag.rgb, vec3(sketerm_luma), sketerm_dim_desat);
    \\    sketerm_frag.rgb *= (1.0 - sketerm_dim_darken);
    \\}
    \\
;

/// Built-in identity shader: samples the scene unchanged. The footer
/// then applies dim/desaturate. Used for the dim-only path (inactive
/// pane with no custom shader of its own).
const DIM_IDENTITY_SRC =
    \\void mainImage(out vec4 c, in vec2 f) {
    \\    c = texture(iChannel0, f / iResolution.xy);
    \\}
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
    u_channel1: c_int = -1,
    u_resolution: c_int = -1,
    u_time: c_int = -1,
    u_time_delta: c_int = -1,
    u_frame: c_int = -1,
    u_dim_darken: c_int = -1,
    u_dim_desat: c_int = -1,
    /// Inactive-pane dim, applied in the footer (and the dim-only
    /// program). Both 0 = no effect. Driven by the pane per frame
    /// from config + focus.
    dim_darken: f32 = 0,
    dim_desat: f32 = 0,
    /// Lazily-built identity+dim program for the dim-only path (an
    /// inactive pane with no custom shader). Separate from `program`
    /// so it survives the user-shader generation cache.
    dim_program: c_uint = 0,
    dim_u_channel0: c_int = -1,
    dim_u_resolution: c_int = -1,
    dim_u_darken: c_int = -1,
    dim_u_desat: c_int = -1,
    /// Previous-frame feedback (iChannel1): the user shader renders
    /// into a ping-pong texture pair instead of straight to screen;
    /// last frame's OUTPUT is sampled this frame (phosphor
    /// persistence, trails). Only engaged when the program actually
    /// references iChannel1 — other shaders keep the direct path.
    has_feedback: bool = false,
    fb_tex: [2]c_uint = .{ 0, 0 },
    fb_fbo: [2]c_uint = .{ 0, 0 },
    fb_idx: u1 = 0,
    fb_w: c_int = 0,
    fb_h: c_int = 0,
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
    meta: Meta = .{},
    /// Extra texture inputs (//@texture). Units 2..; loaded at
    /// program build, freed on rebuild/release.
    lut_tex: [MAX_TEXTURES]c_uint = .{ 0, 0, 0, 0 },
    lut_loc: [MAX_TEXTURES]c_int = .{ -1, -1, -1, -1 },
    lut_len: usize = 0,

    pub fn forgetGL(self: *ShaderPass) void {
        self.program = 0;
        self.vao = 0;
        self.vbo = 0;
        self.fbo = 0;
        self.tex = 0;
        self.tex_w = 0;
        self.tex_h = 0;
        self.fb_tex = .{ 0, 0 };
        self.fb_fbo = .{ 0, 0 };
        self.fb_idx = 0;
        self.fb_w = 0;
        self.fb_h = 0;
        self.lut_tex = .{ 0, 0, 0, 0 };
        self.lut_loc = .{ -1, -1, -1, -1 };
        self.lut_len = 0;
        self.dim_program = 0;
        self.dim_u_channel0 = -1;
        self.dim_u_resolution = -1;
        self.dim_u_darken = -1;
        self.dim_u_desat = -1;
        self.built_generation = std.math.maxInt(u32);
        self.failed = false;
    }

    pub fn releaseGL(self: *ShaderPass) void {
        if (self.program != 0) c.glDeleteProgram(self.program);
        if (self.dim_program != 0) c.glDeleteProgram(self.dim_program);
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
        for (self.fb_tex) |t| {
            if (t != 0) {
                var tt = t;
                c.glDeleteTextures(1, &tt);
            }
        }
        for (self.fb_fbo) |f| {
            if (f != 0) {
                var ff = f;
                c.glDeleteFramebuffers(1, &ff);
            }
        }
        for (self.lut_tex) |t| {
            if (t != 0) {
                var tt = t;
                c.glDeleteTextures(1, &tt);
            }
        }
        self.forgetGL();
    }

    /// Whether the pass would redirect rendering this frame.
    pub fn active(self: *const ShaderPass) bool {
        const src = self.source orelse return false;
        if (src.src == null) return false;
        return !(self.failed and self.built_generation == src.generation);
    }

    /// Compile/refresh the program for the current Source generation.
    /// pub for the config dialog's preview, which drives the pass
    /// manually (sets `tex` + `prev_fbo`, then calls finish()).
    pub fn ensureProgram(self: *ShaderPass, allocator: std.mem.Allocator) bool {
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
        self.u_channel1 = c.glGetUniformLocation(self.program, "iChannel1");
        self.has_feedback = self.u_channel1 >= 0;
        self.u_resolution = c.glGetUniformLocation(self.program, "iResolution");
        self.u_time = c.glGetUniformLocation(self.program, "iTime");
        self.u_time_delta = c.glGetUniformLocation(self.program, "iTimeDelta");
        self.u_frame = c.glGetUniformLocation(self.program, "iFrame");
        self.u_dim_darken = c.glGetUniformLocation(self.program, "sketerm_dim_darken");
        self.u_dim_desat = c.glGetUniformLocation(self.program, "sketerm_dim_desat");

        // Tunable uniforms: //@param declarations → locations. A
        // param whose uniform got optimized out keeps loc -1 and is
        // skipped at upload.
        self.meta = .{};
        self.params_len = parseParams(user, &self.params, &self.meta);
        for (self.params[0..self.params_len]) |*p| {
            var name_z: [33]u8 = undefined;
            @memcpy(name_z[0..p.name_len], p.name());
            name_z[p.name_len] = 0;
            p.loc = c.glGetUniformLocation(self.program, @ptrCast(&name_z));
        }

        // Extra texture inputs (//@texture). Old set freed first —
        // a recompile may declare different files.
        for (&self.lut_tex) |*t| {
            if (t.* != 0) {
                c.glDeleteTextures(1, t);
                t.* = 0;
            }
        }
        var decls: [MAX_TEXTURES]TextureDecl = undefined;
        self.lut_len = parseTextures(user, &decls);
        for (decls[0..self.lut_len], 0..) |*d, ti| {
            var name_z: [33]u8 = undefined;
            @memcpy(name_z[0..d.name_len], d.name());
            name_z[d.name_len] = 0;
            self.lut_loc[ti] = c.glGetUniformLocation(self.program, @ptrCast(&name_z));
            self.lut_tex[ti] = self.loadTexture(allocator, d.path());
        }

        self.ensureQuad(self.program);
        self.failed = false;
        return true;
    }

    /// Fullscreen-triangle VAO/VBO, shared by the user-shader and
    /// dim-only programs (same VERT_SRC → same a_pos location).
    fn ensureQuad(self: *ShaderPass, program: c_uint) void {
        if (self.vao != 0) return;
        const quad = [_]f32{ -1, -1, 3, -1, -1, 3 }; // fullscreen triangle
        c.glGenVertexArrays(1, &self.vao);
        c.glGenBuffers(1, &self.vbo);
        c.glBindVertexArray(self.vao);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbo);
        c.glBufferData(c.GL_ARRAY_BUFFER, quad.len * @sizeOf(f32), &quad, c.GL_STATIC_DRAW);
        const a_pos: c_uint = @intCast(c.glGetAttribLocation(program, "a_pos"));
        c.glEnableVertexAttribArray(a_pos);
        c.glVertexAttribPointer(a_pos, 2, c.GL_FLOAT, c.GL_FALSE, 0, null);
        c.glBindVertexArray(0);
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

    /// Load one //@texture input: `builtin:noise` generates a
    /// 256×256 RGBA noise tile (deterministic — same grain every
    /// run); anything else loads via stb, relative paths resolved
    /// against Source.dir. Returns 0 on failure (uniform stays
    /// unbound; shader samples black).
    fn loadTexture(self: *ShaderPass, allocator: std.mem.Allocator, path: []const u8) c_uint {
        var tex: c_uint = 0;

        if (std.mem.eql(u8, path, "builtin:noise")) {
            const side = 256;
            const px = allocator.alloc(u8, side * side * 4) catch return 0;
            defer allocator.free(px);
            var seed: u32 = 0x9e3779b9;
            for (px) |*b| {
                seed = seed *% 1664525 +% 1013904223;
                b.* = @truncate(seed >> 24);
            }
            c.glGenTextures(1, &tex);
            c.glBindTexture(c.GL_TEXTURE_2D, tex);
            c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA8, side, side, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, px.ptr);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_REPEAT);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_REPEAT);
            return tex;
        }

        var path_z: [4096]u8 = undefined;
        const resolved: ?[:0]const u8 = blk: {
            if (path.len > 0 and path[0] == '/') {
                break :blk std.fmt.bufPrintZ(&path_z, "{s}", .{path}) catch null;
            }
            const dir = if (self.source) |s| s.dir else null;
            if (dir) |d| {
                break :blk std.fmt.bufPrintZ(&path_z, "{s}/{s}", .{ d, path }) catch null;
            }
            break :blk null;
        };
        const rz = resolved orelse {
            std.debug.print("sketerm: shader texture path unresolvable: {s}\n", .{path});
            return 0;
        };
        var w: c_int = 0;
        var h: c_int = 0;
        var n: c_int = 0;
        const px = c.stbi_load(rz.ptr, &w, &h, &n, 4);
        if (px == null) {
            std.debug.print("sketerm: shader texture load failed: {s}\n", .{rz});
            return 0;
        }
        defer c.stbi_image_free(px);
        c.glGenTextures(1, &tex);
        c.glBindTexture(c.GL_TEXTURE_2D, tex);
        c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA8, w, h, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, px);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_REPEAT);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_REPEAT);
        return tex;
    }

    /// (Re)allocate the feedback ping-pong pair. Cleared to black on
    /// every (re)alloc so a resize doesn't smear garbage trails.
    fn ensureFeedback(self: *ShaderPass, w: c_int, h: c_int) bool {
        if (self.fb_fbo[0] != 0 and self.fb_w == w and self.fb_h == h) return true;
        for (0..2) |i| {
            if (self.fb_tex[i] == 0) c.glGenTextures(1, &self.fb_tex[i]);
            c.glBindTexture(c.GL_TEXTURE_2D, self.fb_tex[i]);
            c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA8, w, h, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, null);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
            if (self.fb_fbo[i] == 0) c.glGenFramebuffers(1, &self.fb_fbo[i]);
            c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.fb_fbo[i]);
            c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, self.fb_tex[i], 0);
            if (c.glCheckFramebufferStatus(c.GL_FRAMEBUFFER) != c.GL_FRAMEBUFFER_COMPLETE) return false;
            c.glClearColor(0, 0, 0, 1);
            c.glClear(c.GL_COLOR_BUFFER_BIT);
        }
        self.fb_w = w;
        self.fb_h = h;
        return true;
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
    /// With feedback (iChannel1 referenced), the shader renders into
    /// a ping-pong texture first — sampling LAST frame's output —
    /// and the result is blitted to the screen and kept for next
    /// frame. `time_s` is monotonic seconds (pane-level epoch).
    pub fn finish(self: *ShaderPass, w: c_int, h: c_int, time_s: f32) void {
        const feedback = self.has_feedback and self.ensureFeedback(w, h);
        if (feedback) {
            c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.fb_fbo[self.fb_idx]);
        } else {
            c.glBindFramebuffer(c.GL_FRAMEBUFFER, @intCast(self.prev_fbo));
        }
        c.glViewport(0, 0, w, h);
        c.glDisable(c.GL_BLEND);
        c.glUseProgram(self.program);
        if (feedback) {
            c.glActiveTexture(c.GL_TEXTURE1);
            c.glBindTexture(c.GL_TEXTURE_2D, self.fb_tex[self.fb_idx ^ 1]);
            c.glUniform1i(self.u_channel1, 1);
        }
        // Extra texture inputs on units 2.. (0 = frame, 1 = feedback).
        for (0..self.lut_len) |ti| {
            if (self.lut_tex[ti] == 0 or self.lut_loc[ti] < 0) continue;
            const unit: c_uint = @intCast(@as(usize, @intCast(c.GL_TEXTURE2)) + ti);
            c.glActiveTexture(unit);
            c.glBindTexture(c.GL_TEXTURE_2D, self.lut_tex[ti]);
            c.glUniform1i(self.lut_loc[ti], @intCast(2 + ti));
        }
        c.glActiveTexture(c.GL_TEXTURE0);
        c.glBindTexture(c.GL_TEXTURE_2D, self.tex);
        c.glUniform1i(self.u_channel0, 0);
        c.glUniform3f(self.u_resolution, @floatFromInt(w), @floatFromInt(h), 1.0);
        c.glUniform1f(self.u_time, time_s);
        c.glUniform1f(self.u_time_delta, @max(0.0, time_s - self.last_time_s));
        c.glUniform1i(self.u_frame, self.frame_counter);
        if (self.u_dim_darken >= 0) c.glUniform1f(self.u_dim_darken, self.dim_darken);
        if (self.u_dim_desat >= 0) c.glUniform1f(self.u_dim_desat, self.dim_desat);
        // Tunable params: shader default, overridden by any matching
        // `shader_param.<name>` config entry. Uploaded every frame so
        // a config reload re-tunes live without recompiling.
        const overrides: []const ParamKV = if (self.source) |s| s.overrides else &.{};
        for (self.params[0..self.params_len]) |p| {
            if (p.loc < 0) continue;
            var value = p.default_value;
            var color = p.default_color;
            for (overrides) |kv| {
                if (std.mem.eql(u8, kv.name, p.name())) {
                    value = kv.value;
                    if (kv.color) |col| color = col;
                    break;
                }
            }
            switch (p.kind) {
                .float => c.glUniform1f(p.loc, value),
                .color => c.glUniform3f(p.loc, color[0], color[1], color[2]),
            }
        }
        self.last_time_s = time_s;
        self.frame_counter +%= 1;
        c.glBindVertexArray(self.vao);
        c.glDrawArrays(c.GL_TRIANGLES, 0, 3);
        c.glBindVertexArray(0);
        if (feedback) {
            // This frame's output → screen, and it stays in fb_tex
            // for next frame's iChannel1.
            c.glBindFramebuffer(c.GL_READ_FRAMEBUFFER, self.fb_fbo[self.fb_idx]);
            c.glBindFramebuffer(c.GL_DRAW_FRAMEBUFFER, @intCast(self.prev_fbo));
            c.glBlitFramebuffer(0, 0, w, h, 0, 0, w, h, c.GL_COLOR_BUFFER_BIT, c.GL_NEAREST);
            c.glBindFramebuffer(c.GL_FRAMEBUFFER, @intCast(self.prev_fbo));
            self.fb_idx ^= 1;
        }
        c.glEnable(c.GL_BLEND);
    }

    /// Whether an inactive-pane dim is requested this frame.
    pub fn wantsDim(self: *const ShaderPass) bool {
        return self.dim_darken > 0.0 or self.dim_desat > 0.0;
    }

    fn ensureDimProgram(self: *ShaderPass, allocator: std.mem.Allocator) bool {
        if (self.dim_program != 0) return true;
        const full = std.mem.concat(allocator, u8, &.{ FRAG_HEADER, DIM_IDENTITY_SRC, FRAG_FOOTER }) catch return false;
        defer allocator.free(full);
        self.dim_program = gl.buildProgram(VERT_SRC, full) catch return false;
        self.dim_u_channel0 = c.glGetUniformLocation(self.dim_program, "iChannel0");
        self.dim_u_resolution = c.glGetUniformLocation(self.dim_program, "iResolution");
        self.dim_u_darken = c.glGetUniformLocation(self.dim_program, "sketerm_dim_darken");
        self.dim_u_desat = c.glGetUniformLocation(self.dim_program, "sketerm_dim_desat");
        self.ensureQuad(self.dim_program);
        return true;
    }

    /// Dim-only offscreen redirect: an inactive pane with no custom
    /// shader still routes through an FBO so `finishDim` can apply the
    /// uniform darken/desaturate. Returns false to render direct.
    pub fn beginDim(self: *ShaderPass, allocator: std.mem.Allocator, w: c_int, h: c_int) bool {
        if (!self.wantsDim()) return false;
        if (!self.ensureDimProgram(allocator)) return false;
        c.glGetIntegerv(c.GL_DRAW_FRAMEBUFFER_BINDING, &self.prev_fbo);
        if (!self.ensureTarget(w, h)) return false;
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.fbo);
        return true;
    }

    /// Composite the scene texture to screen with dim/desaturate.
    pub fn finishDim(self: *ShaderPass, w: c_int, h: c_int) void {
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, @intCast(self.prev_fbo));
        c.glViewport(0, 0, w, h);
        c.glDisable(c.GL_BLEND);
        c.glUseProgram(self.dim_program);
        c.glActiveTexture(c.GL_TEXTURE0);
        c.glBindTexture(c.GL_TEXTURE_2D, self.tex);
        c.glUniform1i(self.dim_u_channel0, 0);
        c.glUniform3f(self.dim_u_resolution, @floatFromInt(w), @floatFromInt(h), 1.0);
        if (self.dim_u_darken >= 0) c.glUniform1f(self.dim_u_darken, self.dim_darken);
        if (self.dim_u_desat >= 0) c.glUniform1f(self.dim_u_desat, self.dim_desat);
        c.glBindVertexArray(self.vao);
        c.glDrawArrays(c.GL_TRIANGLES, 0, 3);
        c.glBindVertexArray(0);
        c.glEnable(c.GL_BLEND);
    }
};
