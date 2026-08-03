//! spike-editor-text — de-risking spike: can the existing GL + font
//! stack render GPU-accelerated PROPORTIONAL text (the foundation for
//! a future editor pane)?
//!
//! Headless (no GTK): EGL surfaceless context, exactly like smoke-cell.
//! Reuses verbatim: render/atlas.zig (fontconfig resolve, FreeType
//! raster, HarfBuzz shapeRun, gid-keyed atlas packing) and
//! render/gl.zig (versionless-shader compile helpers).
//!
//! Run: `zig build spike-editor-text`. Exits 0 on PASS; writes
//! zig-out/spike-editor-text.png for visual inspection.

const std = @import("std");
const c = @import("c.zig").c;
const gl = @import("render/gl.zig");
const atlas_mod = @import("render/atlas.zig");
const Atlas = atlas_mod.Atlas;

const c_egl = @cImport({
    @cInclude("epoxy/egl.h");
});

const W: c_int = 880;
const H: c_int = 560;
const FONT_SIZE: u16 = 18;
const MARGIN_X: f32 = 16.0;
const MARGIN_Y: f32 = 12.0;

const LINES = [_][]const u8{
    "The quick brown fox jumps over the lazy dog.",
    "Pack my box with five dozen liquor jugs 0123456789.",
    "Efficient office affix: fi fl ffi ffl waffle traffic", // ligature-capable
    "AV To Ye Wa Ta P. F. (kerning pairs)",
    "iiiiiiiiii wwwwwwwwww mmmmm lllll", // proportional-width contrast
    "Ellinika: \u{0395}\u{03bb}\u{03bb}\u{03b7}\u{03bd}\u{03b9}\u{03ba}\u{03ac} \u{03b1}\u{03b2}\u{03b3}\u{03b4}\u{03b5}",
    "Kirillica: \u{041f}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}, \u{043c}\u{0438}\u{0440}!",
    "\u{0627}\u{0644}\u{0639}\u{0631}\u{0628}\u{064a}\u{0629} \u{0633}\u{0644}\u{0627}\u{0645}", // Arabic (RTL, contextual)
    "Sphinx of black quartz, judge my vow.",
    "How vexingly quick daft zebras jump!",
    "Jived fox nymph grabs quick waltz.",
    "Glib jocks quiz nymph to vex dwarf.",
    "editor.line = { glyphs, clusters, x_advances };",
    "fn hitTest(x: f32) -> ByteOffset { ... }",
    "Proportional text in a terminal's GL stack.",
    "abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOPQRSTUVWXYZ",
    "0.1 + 0.2 == 0.30000000000000004 (float trivia)",
    "Waltz, bad nymph, for quick jigs vex.",
    "The five boxing wizards jump quickly.",
    "final line: hit-testing maps pixels back to bytes.",
};

fn nowNs() u64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(u64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(ts.tv_nsec));
}

/// One positioned glyph quad, in pixel coordinates (y-down).
const PGlyph = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
    layer: f32,
};

/// One shaping cluster: byte range in the source text + x pixel range
/// on screen. This is the hit-testing currency.
const Seg = struct {
    byte_start: u32,
    byte_end: u32,
    x0: f32,
    x1: f32,
};

const Line = struct {
    text: []const u8,
    glyphs: []PGlyph,
    segs: []Seg,
    n_codepoints: usize,
    n_glyphs: usize,
};

fn countCodepoints(text: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        i += std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        n += 1;
    }
    return n;
}

/// Layout one line: shape with HarfBuzz (atlas.shapeRun), rasterize
/// each glyph into the atlas (lookupOrLoadById), position quads at
/// variable advances, and build the cluster segment map.
fn layoutLine(
    allocator: std.mem.Allocator,
    atlas: *Atlas,
    text: []const u8,
    baseline_y: f32,
) !Line {
    const shaped = try atlas.shapeRun(allocator, text, false, false);

    var glyphs: std.ArrayList(PGlyph) = .empty;
    errdefer glyphs.deinit(allocator);
    var segs: std.ArrayList(Seg) = .empty;
    errdefer segs.deinit(allocator);

    var pen: f32 = MARGIN_X;
    var i: usize = 0;
    while (i < shaped.len) {
        // Group consecutive glyphs sharing a cluster (e.g. base +
        // marks, or a ligature that is one glyph for many bytes).
        const cluster = shaped[i].cluster;
        const seg_x0 = pen;
        while (i < shaped.len and shaped[i].cluster == cluster) : (i += 1) {
            const sg = shaped[i];
            const g = try atlas.lookupOrLoadById(sg.glyph_id, false, false);
            const gx = pen + @as(f32, @floatFromInt(sg.x_offset)) / 64.0 + @as(f32, @floatFromInt(g.bearing_x));
            const gy = baseline_y - @as(f32, @floatFromInt(sg.y_offset)) / 64.0 - @as(f32, @floatFromInt(g.bearing_y));
            if (g.w > 0 and g.h > 0) {
                try glyphs.append(allocator, .{
                    .x = gx,
                    .y = gy,
                    .w = @floatFromInt(g.w),
                    .h = @floatFromInt(g.h),
                    .u0 = g.u0,
                    .v0 = g.v0,
                    .u1 = g.u1,
                    .v1 = g.v1,
                    .layer = @floatFromInt(g.layer),
                });
            }
            pen += @as(f32, @floatFromInt(sg.x_advance)) / 64.0;
        }
        try segs.append(allocator, .{
            .byte_start = cluster,
            .byte_end = 0, // filled below
            .x0 = seg_x0,
            .x1 = pen,
        });
    }

    // byte_end of a cluster = the smallest byte_start strictly greater
    // than it among all segs (RTL runs come out in visual order —
    // descending clusters — so "next seg" is NOT the answer), else
    // text.len.
    for (segs.items) |*s| {
        var end: u32 = @intCast(text.len);
        for (segs.items) |o| {
            if (o.byte_start > s.byte_start and o.byte_start < end) end = o.byte_start;
        }
        s.byte_end = end;
    }

    return .{
        .text = text,
        .glyphs = try glyphs.toOwnedSlice(allocator),
        .segs = try segs.toOwnedSlice(allocator),
        .n_codepoints = countCodepoints(text),
        .n_glyphs = shaped.len,
    };
}

/// Pixel x → byte offset, via the cluster segment map. Positions past
/// the last cluster clamp to the nearest segment's start.
fn xToByte(line: *const Line, x: f32) u32 {
    var best: u32 = 0;
    var best_dist: f32 = std.math.floatMax(f32);
    for (line.segs) |s| {
        const lo = @min(s.x0, s.x1);
        const hi = @max(s.x0, s.x1);
        if (x >= lo and x < hi) return s.byte_start;
        const mid = (lo + hi) * 0.5;
        const d = @abs(x - mid);
        if (d < best_dist) {
            best_dist = d;
            best = s.byte_start;
        }
    }
    return best;
}

/// Byte offset → x pixel midpoint of its cluster (0 when not found).
fn byteToX(line: *const Line, byte: u32) ?f32 {
    for (line.segs) |s| {
        if (byte >= s.byte_start and byte < s.byte_end) return (s.x0 + s.x1) * 0.5;
    }
    return null;
}

const VS =
    \\layout(location = 0) in vec2 a_pos;
    \\layout(location = 1) in vec3 a_uvl;
    \\uniform vec2 u_viewport;
    \\out vec3 v_uvl;
    \\void main() {
    \\    v_uvl = a_uvl;
    \\    gl_Position = vec4(a_pos.x / u_viewport.x * 2.0 - 1.0,
    \\                       1.0 - a_pos.y / u_viewport.y * 2.0, 0.0, 1.0);
    \\}
;

const FS =
    \\uniform sampler2DArray u_atlas;
    \\uniform vec3 u_fg;
    \\in vec3 v_uvl;
    \\out vec4 frag;
    \\void main() {
    \\    vec4 t = texture(u_atlas, v_uvl);
    \\    frag = vec4(t.rgb * u_fg, t.a);
    \\}
;

pub fn main() !u8 {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // --- EGL surfaceless context (same pattern as smoke-cell) ---
    const display = blk: {
        const getPlatformDisplay = c_egl.eglGetProcAddress("eglGetPlatformDisplayEXT");
        if (getPlatformDisplay) |p| {
            const fn_ptr: *const fn (c_uint, ?*anyopaque, ?[*]const c_egl.EGLint) callconv(.c) c_egl.EGLDisplay = @ptrCast(@alignCast(p));
            const PLATFORM_SURFACELESS_MESA: c_uint = 0x31DD;
            const d = fn_ptr(PLATFORM_SURFACELESS_MESA, null, null);
            if (d != null and d != c_egl.EGL_NO_DISPLAY) break :blk d;
        }
        break :blk c_egl.eglGetDisplay(c_egl.EGL_DEFAULT_DISPLAY);
    };
    if (display == c_egl.EGL_NO_DISPLAY) {
        std.debug.print("spike-editor-text: eglGetDisplay failed\n", .{});
        return 1;
    }
    var maj: c_egl.EGLint = 0;
    var min: c_egl.EGLint = 0;
    if (c_egl.eglInitialize(display, &maj, &min) == c_egl.EGL_FALSE) return 1;
    if (c_egl.eglBindAPI(c_egl.EGL_OPENGL_ES_API) == c_egl.EGL_FALSE) return 1;
    const cfg_attribs = [_]c_egl.EGLint{
        c_egl.EGL_RED_SIZE, 8, c_egl.EGL_GREEN_SIZE, 8, c_egl.EGL_BLUE_SIZE, 8, c_egl.EGL_ALPHA_SIZE, 8,
        c_egl.EGL_RENDERABLE_TYPE, c_egl.EGL_OPENGL_ES3_BIT,
        c_egl.EGL_SURFACE_TYPE, c_egl.EGL_PBUFFER_BIT,
        c_egl.EGL_NONE,
    };
    var cfg: c_egl.EGLConfig = null;
    var n_cfg: c_egl.EGLint = 0;
    if (c_egl.eglChooseConfig(display, &cfg_attribs, &cfg, 1, &n_cfg) == c_egl.EGL_FALSE or n_cfg < 1) return 1;
    const ctx_attribs = [_]c_egl.EGLint{ c_egl.EGL_CONTEXT_MAJOR_VERSION, 3, c_egl.EGL_CONTEXT_MINOR_VERSION, 0, c_egl.EGL_NONE };
    const ctx = c_egl.eglCreateContext(display, cfg, c_egl.EGL_NO_CONTEXT, &ctx_attribs);
    if (ctx == c_egl.EGL_NO_CONTEXT) return 1;
    if (c_egl.eglMakeCurrent(display, c_egl.EGL_NO_SURFACE, c_egl.EGL_NO_SURFACE, ctx) == c_egl.EGL_FALSE) return 1;
    std.debug.print("spike-editor-text: GL_VERSION={s}\n", .{c.glGetString(c.GL_VERSION)});

    // --- Offscreen framebuffer ---
    var fbo: c_uint = 0;
    var rbo: c_uint = 0;
    c.glGenFramebuffers(1, &fbo);
    c.glBindFramebuffer(c.GL_FRAMEBUFFER, fbo);
    c.glGenRenderbuffers(1, &rbo);
    c.glBindRenderbuffer(c.GL_RENDERBUFFER, rbo);
    c.glRenderbufferStorage(c.GL_RENDERBUFFER, c.GL_RGBA8, W, H);
    c.glFramebufferRenderbuffer(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_RENDERBUFFER, rbo);
    if (c.glCheckFramebufferStatus(c.GL_FRAMEBUFFER) != c.GL_FRAMEBUFFER_COMPLETE) {
        std.debug.print("spike-editor-text: framebuffer incomplete\n", .{});
        return 1;
    }
    c.glViewport(0, 0, W, H);
    c.glClearColor(0.09, 0.09, 0.12, 1.0);
    c.glClear(c.GL_COLOR_BUFFER_BIT);

    // --- Proportional font via the existing fontconfig path ---
    const font_path = atlas_mod.resolveFamilyPath(allocator, "DejaVu Sans") orelse
        atlas_mod.resolveFamilyPath(allocator, "Sans") orelse {
            std.debug.print("spike-editor-text: fontconfig found no Sans font\n", .{});
            return 1;
        };
    defer allocator.free(font_path);
    std.debug.print("spike-editor-text: font={s}\n", .{font_path});
    const atlas = try Atlas.init(allocator, font_path.ptr, FONT_SIZE);
    defer atlas.deinit();
    atlas.realize();
    defer atlas.releaseGL();
    std.debug.print(
        "spike-editor-text: atlas metrics cell_w={d} cell_h={d} ascent={d} (cell_w is max_advance — meaningless for layout here, and unused)\n",
        .{ atlas.cell_w, atlas.cell_h, atlas.ascent },
    );

    const line_h: f32 = @floatFromInt(atlas.cell_h + 4);
    const ascent: f32 = @floatFromInt(atlas.ascent);

    // --- Shape + layout (timed; includes first-touch rasterization) ---
    var lines: [LINES.len]Line = undefined;
    const t_shape0 = nowNs();
    var total_glyphs: usize = 0;
    for (LINES, 0..) |text, li| {
        const baseline = MARGIN_Y + @as(f32, @floatFromInt(li)) * line_h + ascent;
        lines[li] = try layoutLine(allocator, atlas, text, baseline);
        total_glyphs += lines[li].n_glyphs;
    }
    const t_shape1 = nowNs();
    defer for (&lines) |*l| {
        allocator.free(l.glyphs);
        allocator.free(l.segs);
    };

    // Warm re-layout: shape cache + glyph cache hot — the editor's
    // steady-state cost for unchanged text.
    const t_warm0 = nowNs();
    for (LINES, 0..) |text, li| {
        const baseline = MARGIN_Y + @as(f32, @floatFromInt(li)) * line_h + ascent;
        var warm = try layoutLine(allocator, atlas, text, baseline);
        allocator.free(warm.glyphs);
        allocator.free(warm.segs);
        warm = undefined;
    }
    const t_warm1 = nowNs();

    // --- Proportionality + shaping evidence ---
    {
        // Distinct positive advances on line 0 prove variable widths.
        const shaped = try atlas.shapeRun(allocator, LINES[0], false, false);
        var distinct: usize = 0;
        var seen: [64]i32 = undefined;
        for (shaped) |sg| {
            if (sg.x_advance <= 0) continue;
            var found = false;
            for (seen[0..distinct]) |s| {
                if (s == sg.x_advance) found = true;
            }
            if (!found and distinct < seen.len) {
                seen[distinct] = sg.x_advance;
                distinct += 1;
            }
        }
        std.debug.print("spike-editor-text: line0 distinct x_advances={d}\n", .{distinct});
        if (distinct < 4) {
            std.debug.print("spike-editor-text: FAIL — advances look fixed-width\n", .{});
            return 2;
        }
        // Ligature line: fewer glyphs than codepoints means ligation
        // (or mark composition) happened. Soft report — fonts differ.
        const lig = &lines[2];
        std.debug.print(
            "spike-editor-text: ligature line codepoints={d} glyphs={d} ({s})\n",
            .{ lig.n_codepoints, lig.n_glyphs, if (lig.n_glyphs < lig.n_codepoints) "ligated" else "no ligation with this font" },
        );
        // Arabic line: contextual shaping — glyph ids must differ for
        // the same base letter in different positions; cheap proxy:
        // RTL cluster order (first visual cluster maps to a LATER byte
        // than the last visual cluster).
        const ar = &lines[7];
        if (ar.segs.len >= 2) {
            const rtl = ar.segs[0].byte_start > ar.segs[ar.segs.len - 1].byte_start;
            // Count .notdef glyphs: shapeRun shapes against the PRIMARY
            // face only — a primary font without Arabic coverage yields
            // gid 0 tofu. Atlas fallback (lookupOrLoad) is codepoint-
            // keyed and can't help a gid path; the editor will need
            // font itemization (per-script run splitting) before shaping.
            const ar_shaped = try atlas.shapeRun(allocator, LINES[7], false, false);
            var notdef: usize = 0;
            for (ar_shaped) |sg| {
                if (sg.glyph_id == 0) notdef += 1;
            }
            std.debug.print(
                "spike-editor-text: arabic line segs={d} rtl_visual_order={} notdef={d}/{d}{s}\n",
                .{ ar.segs.len, rtl, notdef, ar_shaped.len, if (notdef > 0) " (primary face lacks coverage; shapeRun has no fallback itemization)" else "" },
            );
        }
    }

    // --- Hit testing: byte -> x -> byte round-trips ---
    {
        var checked: usize = 0;
        var failed: usize = 0;
        for (&lines, 0..) |*line, li| {
            for (line.segs) |s| {
                if (@abs(s.x1 - s.x0) < 0.01) continue; // zero-width (marks)
                const x = byteToX(line, s.byte_start) orelse {
                    failed += 1;
                    continue;
                };
                const back = xToByte(line, x);
                checked += 1;
                if (back != s.byte_start) {
                    failed += 1;
                    std.debug.print(
                        "spike-editor-text: round-trip MISMATCH line={d} byte={d} x={d:.1} -> byte={d}\n",
                        .{ li, s.byte_start, x, back },
                    );
                }
            }
        }
        std.debug.print("spike-editor-text: hit-test round-trips checked={d} failed={d}\n", .{ checked, failed });
        if (failed != 0 or checked < 100) {
            std.debug.print("spike-editor-text: FAIL — hit testing broken\n", .{});
            return 3;
        }
        // A few demonstrative lookups.
        const demos = [_]struct { line: usize, byte: u32 }{
            .{ .line = 0, .byte = 0 },
            .{ .line = 0, .byte = 4 },
            .{ .line = 2, .byte = 10 },
            .{ .line = 7, .byte = 0 },
        };
        for (demos) |d| {
            if (byteToX(&lines[d.line], d.byte)) |x| {
                std.debug.print(
                    "spike-editor-text: PASS lookup line={d} byte={d} -> x={d:.1} -> byte={d}\n",
                    .{ d.line, d.byte, x, xToByte(&lines[d.line], x) },
                );
            }
        }
    }

    // --- Build one interleaved vertex buffer: pos.xy + uvl.xyz ---
    var verts: std.ArrayList(f32) = .empty;
    defer verts.deinit(allocator);
    var quad_count: usize = 0;
    for (&lines) |*line| {
        for (line.glyphs) |g| {
            const x0 = g.x;
            const y0 = g.y;
            const x1 = g.x + g.w;
            const y1 = g.y + g.h;
            const quad = [_]f32{
                x0, y0, g.u0, g.v0, g.layer,
                x1, y0, g.u1, g.v0, g.layer,
                x1, y1, g.u1, g.v1, g.layer,
                x0, y0, g.u0, g.v0, g.layer,
                x1, y1, g.u1, g.v1, g.layer,
                x0, y1, g.u0, g.v1, g.layer,
            };
            try verts.appendSlice(allocator, &quad);
            quad_count += 1;
        }
    }

    // --- Draw (timed) ---
    const prog = try gl.buildProgram(VS, FS);
    defer c.glDeleteProgram(prog);
    var vao: c_uint = 0;
    var vbo: c_uint = 0;
    c.glGenVertexArrays(1, &vao);
    c.glBindVertexArray(vao);
    c.glGenBuffers(1, &vbo);
    c.glBindBuffer(c.GL_ARRAY_BUFFER, vbo);
    c.glBufferData(
        c.GL_ARRAY_BUFFER,
        @intCast(verts.items.len * @sizeOf(f32)),
        verts.items.ptr,
        c.GL_STATIC_DRAW,
    );
    const stride: c_int = 5 * @sizeOf(f32);
    c.glEnableVertexAttribArray(0);
    c.glVertexAttribPointer(0, 2, c.GL_FLOAT, c.GL_FALSE, stride, null);
    c.glEnableVertexAttribArray(1);
    c.glVertexAttribPointer(1, 3, c.GL_FLOAT, c.GL_FALSE, stride, @ptrFromInt(2 * @sizeOf(f32)));

    const t_draw0 = nowNs();
    c.glUseProgram(prog);
    c.glUniform2f(c.glGetUniformLocation(prog, "u_viewport"), @floatFromInt(W), @floatFromInt(H));
    c.glUniform3f(c.glGetUniformLocation(prog, "u_fg"), 0.92, 0.93, 0.85);
    c.glUniform1i(c.glGetUniformLocation(prog, "u_atlas"), 0);
    c.glActiveTexture(c.GL_TEXTURE0);
    c.glBindTexture(c.GL_TEXTURE_2D_ARRAY, atlas.gl_tex);
    c.glEnable(c.GL_BLEND);
    c.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);
    c.glDrawArrays(c.GL_TRIANGLES, 0, @intCast(quad_count * 6));
    c.glFinish();
    const t_draw1 = nowNs();
    // Second draw: the first submission pays Mesa's deferred pipeline
    // compile; this is the steady-state per-frame cost.
    const t_draw2a = nowNs();
    c.glClear(c.GL_COLOR_BUFFER_BIT);
    c.glDrawArrays(c.GL_TRIANGLES, 0, @intCast(quad_count * 6));
    c.glFinish();
    const t_draw2b = nowNs();

    // --- Read back + assert pixels + write PNG ---
    const fb_bytes: usize = @intCast(W * H * 4);
    const fb = try allocator.alloc(u8, fb_bytes);
    defer allocator.free(fb);
    c.glReadPixels(0, 0, W, H, c.GL_RGBA, c.GL_UNSIGNED_BYTE, fb.ptr);
    var lit: usize = 0;
    var i: usize = 0;
    while (i < fb_bytes) : (i += 4) {
        if (fb[i] > 0x40 and fb[i + 1] > 0x40) lit += 1;
    }
    std.debug.print("spike-editor-text: quads={d} lit_pixels={d}\n", .{ quad_count, lit });
    if (lit < 2000) {
        std.debug.print("spike-editor-text: FAIL — too few lit pixels, text not rendered\n", .{});
        return 4;
    }

    // Flip vertically (GL reads bottom-up) and force opaque alpha.
    const flipped = try allocator.alloc(u8, fb_bytes);
    defer allocator.free(flipped);
    const row_bytes: usize = @intCast(W * 4);
    var row: usize = 0;
    while (row < H) : (row += 1) {
        const src = fb[(@as(usize, @intCast(H)) - 1 - row) * row_bytes ..][0..row_bytes];
        const dst = flipped[row * row_bytes ..][0..row_bytes];
        @memcpy(dst, src);
        var pxi: usize = 3;
        while (pxi < row_bytes) : (pxi += 4) dst[pxi] = 255;
    }
    _ = c.mkdir("zig-out", 0o755);
    const png_path = "zig-out/spike-editor-text.png";
    if (c.stbi_write_png(png_path, W, H, 4, flipped.ptr, @intCast(row_bytes)) == 0) {
        std.debug.print("spike-editor-text: FAIL — could not write {s}\n", .{png_path});
        return 5;
    }
    std.debug.print("spike-editor-text: wrote {s}\n", .{png_path});

    std.debug.print(
        "spike-editor-text: timing shape+layout(cold)={d:.2}ms warm={d:.2}ms draw(first)={d:.2}ms draw(steady)={d:.2}ms for {d} glyphs / {d} lines\n",
        .{
            @as(f64, @floatFromInt(t_shape1 - t_shape0)) / 1e6,
            @as(f64, @floatFromInt(t_warm1 - t_warm0)) / 1e6,
            @as(f64, @floatFromInt(t_draw1 - t_draw0)) / 1e6,
            @as(f64, @floatFromInt(t_draw2b - t_draw2a)) / 1e6,
            total_glyphs,
            LINES.len,
        },
    );
    std.debug.print("spike-editor-text: PASS\n", .{});
    return 0;
}
