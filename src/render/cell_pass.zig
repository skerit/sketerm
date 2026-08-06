//! Cell pass — instanced rendering of the cell grid.
//!
//! One instance per cell. Each instance carries cell bg + fg + glyph
//! UV/layer/size — the vertex shader emits either a bg quad (kind=0)
//! or a glyph quad (kind=1) depending on a uniform. We render in two
//! draw calls per frame: bgs first, then glyphs over them, so a
//! left-leaning italic from cell N can overflow into cell N+1's bg
//! and not get clobbered.
//!
//! Persistent VBO sized for `rows × cols` instances. On a per-row
//! basis we re-upload only the rows whose `Line.dirty` is true. A
//! resize regrows the buffer and marks every row dirty.

const std = @import("std");
const c = @import("../c.zig").c;
const gl = @import("gl.zig");
const atlas_mod = @import("atlas.zig");
const Atlas = atlas_mod.Atlas;
const Screen = @import("../grid/screen.zig").Screen;
const StylePool = @import("../grid/style_pool.zig").Pool;
const StyleEntry = @import("../grid/style_pool.zig").Entry;
const Color = @import("../grid/style_pool.zig").Color;
const Cell = @import("../grid/cell.zig").Cell;
const Line = @import("../grid/line.zig").Line;
const Scaling = @import("../grid/line.zig").Scaling;
const palette_default = @import("../grid/palette.zig").default_256;
const style_util = @import("style.zig");

/// Per-cell instance data. Layout matches the vertex attribs
/// declared in `realize`. 100 bytes — for 200×80 cells: 1.6 MB.
pub const Instance = extern struct {
    cell_xy: [2]f32 = .{ 0, 0 },
    cell_size: [2]f32 = .{ 0, 0 },
    bg: [4]f32 = .{ 0, 0, 0, 0 },
    fg: [4]f32 = .{ 0, 0, 0, 0 },
    glyph_xy: [2]f32 = .{ 0, 0 },
    glyph_size: [2]f32 = .{ 0, 0 },
    glyph_uv0: [2]f32 = .{ 0, 0 },
    glyph_uv1: [2]f32 = .{ 0, 0 },
    /// Atlas array layer (0..PAGE_COUNT-1).
    glyph_layer: f32 = 0,
    /// 0 = render glyph normally; >0.5 = no glyph (degenerate triangle).
    has_glyph: f32 = 0,
    /// Line-decoration kind. 0 = none, 1 = underline, 2 = double
    /// underline, 3 = curly underline, 4 = strikethrough, 5 = overline.
    /// Drawn in a third pass after bg + glyph; uses `fg` for color.
    deco: f32 = 0,
    /// 1.0 = render this glyph italicized via a horizontal shear in
    /// the glyph pass. 0.0 = upright. Cheaper than loading a second
    /// FreeType face (italic glyph caching) and works for any
    /// monospace font without an italic variant.
    italic: f32 = 0,
    /// 1.0 = render this glyph faux-bold by sampling the atlas at
    /// the original UV AND a 1-pixel offset in u, taking max alpha.
    /// Same idea as italic — cheap, no second FT face needed.
    bold: f32 = 0,
    /// 1.0 = colour (emoji) glyph: the atlas texels carry straight
    /// RGBA sampled directly; fg tint does not apply.
    colored: f32 = 0,
    /// Decoration (underline/strike/overline) colour. Defaults to the
    /// cell fg; SGR 58 overrides it (diagnostic squiggles).
    deco_color: [4]f32 = .{ 0, 0, 0, 0 },
};

// ITALIC_SHEAR = tan(13°) ≈ 0.231: horizontal-shear factor used to
// fake italics for any monospace font without a second FT face.
pub const VERT_SRC =
    \\const float ITALIC_SHEAR = 0.231;
++ "\nconst float ATLAS_TEXEL = 1.0 / " ++ std.fmt.comptimePrint("{d}", .{atlas_mod.PAGE_SIZE}) ++ ".0;\n" ++
    \\in vec2 a_cell_xy;
    \\in vec2 a_cell_size;
    \\in vec4 a_bg;
    \\in vec4 a_fg;
    \\in vec2 a_glyph_xy;
    \\in vec2 a_glyph_size;
    \\in vec2 a_glyph_uv0;
    \\in vec2 a_glyph_uv1;
    \\in float a_glyph_layer;
    \\in float a_has_glyph;
    \\in float a_deco;
    \\in float a_italic;
    \\in float a_bold;
    \\in float a_colored;
    \\in vec4 a_deco_color;
    \\
    \\uniform vec2 u_screen_px;
    \\uniform int u_kind; // 0 = bg, 1 = glyph, 2 = decoration
    \\// Inactive-pane dimming. 1.0 = no dim. Applied to both fg
    \\// (glyphs + decorations) and bg quads. Cursor / selection /
    \\// border / search overlay live in a different pass and stay at
    \\// full brightness.
    \\uniform float u_dim_fg;
    \\uniform float u_dim_bg;
    \\
    \\out vec4 v_color;
    \\out vec3 v_uvw;
    \\out float v_is_glyph;
    \\out float v_emit;
    \\out float v_deco_kind;
    \\out vec2 v_deco_local;
    \\out float v_deco_w_px;
    \\out float v_bold;
    \\out float v_colored;
    \\out float v_dim_k;
    \\
    \\const vec2 corners[6] = vec2[6](
    \\    vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(0.0, 1.0),
    \\    vec2(1.0, 0.0), vec2(1.0, 1.0), vec2(0.0, 1.0)
    \\);
    \\
    \\void main() {
    \\    vec2 corner = corners[gl_VertexID];
    \\    vec2 origin = a_cell_xy;
    \\    vec2 size = a_cell_size;
    \\    vec2 uv = vec2(0.0);
    \\    v_deco_kind = 0.0;
    \\    v_deco_local = vec2(0.0);
    \\    v_deco_w_px = a_cell_size.x;
    \\    v_bold = a_bold;
    \\    v_colored = a_colored;
    \\    v_dim_k = u_dim_fg;
    \\    if (u_kind == 0) {
    \\        v_color = vec4(a_bg.rgb * u_dim_bg, a_bg.a);
    \\        v_is_glyph = 0.0;
    \\        v_emit = (a_bg.a > 0.001) ? 1.0 : 0.0;
    \\    } else if (u_kind == 1) {
    \\        origin = a_glyph_xy;
    \\        size = a_glyph_size;
    \\        vec2 uv1 = a_glyph_uv1;
    \\        // Bold is a real glyph from the atlas (bold face or
    \\        // outline-embolden) — `a_bold` is inert, no quad fakery.
    \\        v_color = vec4(a_fg.rgb * u_dim_fg, a_fg.a);
    \\        uv = mix(a_glyph_uv0, uv1, corner);
    \\        v_is_glyph = 1.0;
    \\        v_emit = (a_has_glyph < 0.5 && a_glyph_size.x > 0.0 && a_glyph_size.y > 0.0) ? 1.0 : 0.0;
    \\        // Italic via horizontal shear in pixel space. tan(13°) ≈ 0.231.
    \\        // Shear pivots around the cell baseline so the bottom of
    \\        // the glyph stays put and the top tilts right. We compute
    \\        // the post-shear position later (after the corner-mix below
    \\        // assembles `pos`).
    \\    } else {
    \\        // Decoration: derive a strip rect from the cell rect.
    \\        // Heights: thin = max(2, ch/12). Curly is taller (ch/6)
    \\        // because the wave needs vertical room.
    \\        float kind = a_deco + 0.5;
    \\        float ch = a_cell_size.y;
    \\        float thin = max(2.0, ch / 12.0);
    \\        float curly_h = max(3.0, ch / 6.0);
    \\        float dy = 0.0;
    \\        float dh = thin;
    \\        if (kind >= 1.0 && kind < 2.0) {
    \\            // single underline — bottom strip
    \\            dy = ch - thin;
    \\            dh = thin;
    \\        } else if (kind >= 2.0 && kind < 3.0) {
    \\            // double underline — bottom 3px strip; frag draws 2 lines
    \\            dy = ch - thin * 2.0 - 1.0;
    \\            dh = thin * 2.0 + 1.0;
    \\        } else if (kind >= 3.0 && kind < 4.0) {
    \\            // curly underline — taller strip near the bottom
    \\            dy = ch - curly_h;
    \\            dh = curly_h;
    \\        } else if (kind >= 4.0 && kind < 5.0) {
    \\            // strikethrough — middle
    \\            dy = ch * 0.55 - thin * 0.5;
    \\            dh = thin;
    \\        } else if (kind >= 5.0 && kind < 6.0) {
    \\            // overline — top strip
    \\            dy = 0.0;
    \\            dh = thin;
    \\        }
    \\        origin = a_cell_xy + vec2(0.0, dy);
    \\        size = vec2(a_cell_size.x, dh);
    \\        v_color = vec4(a_deco_color.rgb * u_dim_fg, a_deco_color.a);
    \\        v_is_glyph = 0.0;
    \\        v_deco_kind = a_deco;
    \\        v_deco_local = corner;
    \\        v_emit = (a_deco > 0.5) ? 1.0 : 0.0;
    \\    }
    \\    v_uvw = vec3(uv, a_glyph_layer);
    \\    vec2 pos = origin + corner * size;
    \\    // Italic shear: only on glyph pass (u_kind == 1) and only
    \\    // when the cell is marked italic. Pivot around the cell's
    \\    // bottom edge so descenders stay anchored. tan(13°) ≈ 0.231.
    \\    if (u_kind == 1 && a_italic > 0.5) {
    \\        float baseline_y = a_cell_xy.y + a_cell_size.y;
    \\        pos.x += (baseline_y - pos.y) * ITALIC_SHEAR;
    \\    }
    \\    if (v_emit < 0.5) pos = vec2(-10000.0);
    \\    vec2 ndc = (pos / u_screen_px) * 2.0 - 1.0;
    \\    ndc.y = -ndc.y;
    \\    gl_Position = vec4(ndc, 0.0, 1.0);
    \\}
;

// GLSL-side named constants:
//   ATLAS_TEXEL    = 1 / atlas page size — used for the faux-bold
//                    one-texel left-neighbor sample.
//   WAVE_TWO_PI    = 2π — period of the sine used for curly underline.
//   WAVE_AMPLITUDE = vertical amplitude of the curly wave (0..1 within
//                    the strip's local y).
//   WAVE_THICKNESS_PX
//                  = curly underline line thickness, in pixels.
pub const FRAG_SRC = std.fmt.comptimePrint(
    \\
    \\const float ATLAS_TEXEL = 1.0 / {d}.0;
    \\const float WAVE_TWO_PI = 6.2831853;
    \\const float WAVE_AMPLITUDE = 0.45;
    \\const float WAVE_THICKNESS_PX = 1.5;
    \\
    \\in vec4 v_color;
    \\in vec3 v_uvw;
    \\in float v_is_glyph;
    \\in float v_emit;
    \\in float v_deco_kind;
    \\in vec2 v_deco_local;
    \\in float v_deco_w_px;
    \\in float v_bold;
    \\in float v_colored;
    \\in float v_dim_k;
    \\
    \\uniform sampler2DArray u_atlas;
    \\
    \\out vec4 o_frag;
    \\
    \\void main() {{
    \\    if (v_emit < 0.5) discard;
    \\    if (v_is_glyph > 0.5) {{
    \\        // Bold is baked into the atlas glyph now (real bold face or
    \\        // FT outline-embolden); no shader dilation. `v_bold` is inert.
    \\        // Atlas is RGBA: mono coverage lives in alpha (RGB=255) and
    \\        // gets tinted with the cell fg; colour emoji carry straight
    \\        // RGBA sampled directly (only pane-dim applies).
    \\        vec4 t = texture(u_atlas, v_uvw);
    \\        if (v_colored > 0.5) {{
    \\            o_frag = vec4(t.rgb * v_dim_k, t.a * v_color.a);
    \\        }} else {{
    \\            o_frag = vec4(v_color.rgb, t.a * v_color.a);
    \\        }}
    \\        return;
    \\    }}
    \\    if (v_deco_kind < 0.5) {{
    \\        // Plain bg quad.
    \\        o_frag = v_color;
    \\        return;
    \\    }}
    \\    // Decoration shaders: kinds 1/4/5 (under, strike, over) are flat
    \\    // strips; 2 (double-underline) draws two thin sub-lines; 3 (curly)
    \\    // is a sine wave covered by anti-aliased stamping.
    \\    float kind = v_deco_kind + 0.5;
    \\    if (kind >= 2.0 && kind < 3.0) {{
    \\        // Double underline: top half + bottom half drawn, gap in middle.
    \\        float vy = v_deco_local.y;
    \\        if (vy > 0.33 && vy < 0.66) discard;
    \\        o_frag = v_color;
    \\        return;
    \\    }}
    \\    if (kind >= 3.0 && kind < 4.0) {{
    \\        // Curly: y midline with sine wave. Period ~= cell width / WAVE_THICKNESS_PX.
    \\        float x = v_deco_local.x * v_deco_w_px;
    \\        float wave = sin(x * WAVE_TWO_PI / max(8.0, v_deco_w_px / WAVE_THICKNESS_PX));
    \\        float yc = 0.5 + WAVE_AMPLITUDE * wave; // 0..1 within strip
    \\        float dist = abs(v_deco_local.y - yc);
    \\        // ~WAVE_THICKNESS_PX px-equivalent line thickness in strip space.
    \\        float strip_px = max(3.0, v_deco_w_px / 6.0);
    \\        float thickness = WAVE_THICKNESS_PX / strip_px;
    \\        if (dist > thickness) discard;
    \\        // Anti-alias the edge.
    \\        float aa = clamp((thickness - dist) / (thickness * 0.5), 0.0, 1.0);
    \\        o_frag = vec4(v_color.rgb, v_color.a * aa);
    \\        return;
    \\    }}
    \\    o_frag = v_color;
    \\}}
, .{atlas_mod.PAGE_SIZE});

pub const CellPass = struct {
    program: c_uint = 0,
    /// Three rotating VAO/VBO pairs. Frame N writes to (and draws
    /// from) slot (N mod 3); the next frame advances. By the time
    /// the CPU cycles back to a slot, the GPU finished reading it
    /// ~3 frames ago, so `glBufferData` on it never hits Mesa's
    /// implicit CPU↔GPU sync. The single-VBO orphan-and-upload
    /// alternative was stalling the main thread 5-8 ms per frame
    /// during heavy htop activity (freezing GTK chrome dispatch on
    /// the same surface). Kitty / Alacritty use the same approach.
    /// Each VAO records its OWN VBO binding for vertex attributes,
    /// so we configure each VAO once at realize and just bind the
    /// right VAO at draw time — no per-frame attrib re-binding.
    vaos: [3]c_uint = .{ 0, 0, 0 },
    vbos: [3]c_uint = .{ 0, 0, 0 },
    /// Allocated storage size per slot, in bytes. Tracked separately
    /// so the first visit to each slot does an actual `glBufferData`
    /// (allocate) and subsequent visits use map+invalidate (reuse).
    vbo_caps: [3]usize = .{ 0, 0, 0 },
    /// Slot used by the most recent upload + draw. The next render
    /// advances to `(slot + 1) % 3` before uploading.
    vbo_slot: u8 = 0,
    u_screen_px: c_int = -1,
    u_atlas: c_int = -1,
    u_kind: c_int = -1,
    u_dim_fg: c_int = -1,
    u_dim_bg: c_int = -1,

    /// Dimming applied to fg / bg (and decorations) when the pane is
    /// unfocused. 1.0 = no dim. Set by the renderer (Window /
    /// Pane.onFocusEnter/Leave) — defaults at init are 1.0 so a single
    /// pane with no focus tracking renders normally.
    dim_fg: f32 = 1.0,
    dim_bg: f32 = 1.0,

    /// Persistent instance buffer (rows × cols instances).
    instances: std.ArrayList(Instance) = .empty,
    /// Allocated rows / cols — re-init the buffer when these change.
    cap_rows: u16 = 0,
    cap_cols: u16 = 0,
    /// Per-row "needs upload" flag — set when a row's instance data
    /// in `instances` changed since the last GL upload.
    row_needs_upload: std.ArrayList(bool) = .empty,

    /// Default fg/bg used when style.fg/bg is .default.
    default_fg: [4]f32 = .{ 0.92, 0.92, 0.92, 1.0 },
    default_bg: [4]f32 = .{ 0.10, 0.10, 0.10, 1.0 },
    palette: [256][3]u8 = palette_default,

    /// Inner padding (pixels).
    pad: f32 = 6.0,
    /// Enable HarfBuzz ligature shaping for ASCII runs.
    enable_ligatures: bool = true,
    /// Bidi resolution for non-ASCII rows.
    enable_bidi: bool = true,
    /// Honour the bold attribute at all (font weight + bright-color
    /// promotion). Off renders bold cells the same as normal.
    allow_bold: bool = true,
    /// When bold + allow_bold, also lift palette 0..7 to 8..15
    /// (xterm convention). Off keeps the original colour.
    bold_is_bright: bool = true,
    /// Minimum WCAG contrast ratio enforced between resolved fg and
    /// the cell's effective bg. <= 1.0 disables.
    min_contrast: f32 = 1.0,

    /// Atlas page generation per layer — when a layer is evicted by
    /// the atlas, every cached glyph that lived on it becomes stale.
    /// We snapshot generations at the start of each rebuild and force
    /// a full re-pack when any layer's generation differs from last
    /// frame's snapshot.
    last_atlas_generations: [@import("atlas.zig").PAGE_COUNT]u32 =
        [_]u32{0} ** @import("atlas.zig").PAGE_COUNT,
    /// Last `screen.view_offset` we rendered against. When it changes
    /// (user scrolls scrollback in or out), every visible row sources
    /// from a different scrollback / active line — full rebuild
    /// needed once on the change, not on every frame while scrolled.
    last_view_off: u32 = std.math.maxInt(u32),
    /// Last `screen.scrollbackCount()` snapshot. When it grows AND
    /// we're scrolled-back, the displayed scrollback indices shift —
    /// content at row R now comes from a different cached Line.
    last_sb_count: u32 = std.math.maxInt(u32),
    /// Last `screen.glyphs.generation` (Glyph Protocol glossary). A
    /// register/overwrite/clear changes what a visible PUA cell
    /// renders as WITHOUT touching the cell, so any bump forces a
    /// full rebuild — otherwise stale pixels stay on screen.
    last_glyph_gen: u64 = 0,

    /// Set by `rebuildAndUpload` whenever any row was rebuilt during
    /// the call (covers per-row dirty, color/palette change, atlas
    /// eviction, view-offset shift, scrollback drift). The overlay
    /// pass reads it to decide whether its own per-frame work can be
    /// skipped — bidi/DH/URL-scan rows depend on cell content too.
    cells_rebuilt: bool = false,

    /// Per-row "rebuilt this frame" mask. Mirrors `row_needs_upload`
    /// in shape but with different lifetime: cleared at the *top* of
    /// every `rebuildAndUpload`, set per row that gets rebuilt, and
    /// SURVIVES `uploadDirtyRows` (which clears `row_needs_upload`).
    /// `GridPass` reads this after the cell pass returns so it can
    /// invalidate per-row caches (URL scan results, bidi-needs flag)
    /// only on rows whose content actually moved.
    rebuilt_rows: std.ArrayList(bool) = .empty,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CellPass {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *CellPass) void {
        self.instances.deinit(self.allocator);
        self.row_needs_upload.deinit(self.allocator);
        self.rebuilt_rows.deinit(self.allocator);
    }

    pub fn forgetGL(self: *CellPass) void {
        self.program = 0;
        @memset(&self.vaos, 0);
        @memset(&self.vbos, 0);
        @memset(&self.vbo_caps, 0);
        self.vbo_slot = 0;
        self.u_screen_px = -1;
        self.u_atlas = -1;
        self.u_kind = -1;
        self.u_dim_fg = -1;
        self.u_dim_bg = -1;
        // Mark every row to re-upload into the new context.
        for (self.row_needs_upload.items) |*r| r.* = true;
    }

    /// Like `forgetGL`, but ALSO `glDelete*`s every resource we own.
    /// Caller must have a current GL context — the pane's `unrealize`
    /// signal is the last opportunity. Without this, every closed
    /// pane leaks 1 program + 3 VAOs + 3 VBOs into the shared context.
    pub fn releaseGL(self: *CellPass) void {
        if (self.program != 0) {
            c.glDeleteProgram(self.program);
        }
        // 3 VAOs + 3 VBOs from the rotating slots, all in flat arrays.
        // glDelete* tolerates id == 0, so we can pass the whole array.
        c.glDeleteVertexArrays(3, &self.vaos[0]);
        c.glDeleteBuffers(3, &self.vbos[0]);
        self.forgetGL();
    }

    pub fn realize(self: *CellPass) !void {
        if (self.program != 0) return;
        self.program = try gl.buildProgram(VERT_SRC, FRAG_SRC);
        self.u_screen_px = c.glGetUniformLocation(self.program, "u_screen_px");
        self.u_atlas = c.glGetUniformLocation(self.program, "u_atlas");
        self.u_kind = c.glGetUniformLocation(self.program, "u_kind");
        self.u_dim_fg = c.glGetUniformLocation(self.program, "u_dim_fg");
        self.u_dim_bg = c.glGetUniformLocation(self.program, "u_dim_bg");

        // Three independent VAO+VBO pairs, each pre-configured with
        // the same vertex attribute layout. We rotate slots per frame
        // (see `uploadDirtyRows`) to dodge Mesa's implicit CPU↔GPU
        // sync on buffer reuse.
        c.glGenVertexArrays(3, &self.vaos[0]);
        c.glGenBuffers(3, &self.vbos[0]);
        for (0..3) |i| {
            c.glBindVertexArray(self.vaos[i]);
            c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbos[i]);
            self.bindVertexAttribs();
        }
        c.glBindVertexArray(0);
    }

    /// (Re)set per-instance vertex attribute pointers against the
    /// currently-bound VBO. Must be called at realize-time AND every
    /// time the underlying VBO is recreated (the VAO records buffer
    /// names per attribute — recreating without re-binding leaves
    /// attributes pointing at the freed buffer → SIGSEGV on draw).
    fn bindVertexAttribs(self: *CellPass) void {
        const stride: c_int = @sizeOf(Instance);
        const fields = [_]struct { name: [:0]const u8, off: usize, count: c_int }{
            .{ .name = "a_cell_xy", .off = @offsetOf(Instance, "cell_xy"), .count = 2 },
            .{ .name = "a_cell_size", .off = @offsetOf(Instance, "cell_size"), .count = 2 },
            .{ .name = "a_bg", .off = @offsetOf(Instance, "bg"), .count = 4 },
            .{ .name = "a_fg", .off = @offsetOf(Instance, "fg"), .count = 4 },
            .{ .name = "a_glyph_xy", .off = @offsetOf(Instance, "glyph_xy"), .count = 2 },
            .{ .name = "a_glyph_size", .off = @offsetOf(Instance, "glyph_size"), .count = 2 },
            .{ .name = "a_glyph_uv0", .off = @offsetOf(Instance, "glyph_uv0"), .count = 2 },
            .{ .name = "a_glyph_uv1", .off = @offsetOf(Instance, "glyph_uv1"), .count = 2 },
            .{ .name = "a_glyph_layer", .off = @offsetOf(Instance, "glyph_layer"), .count = 1 },
            .{ .name = "a_has_glyph", .off = @offsetOf(Instance, "has_glyph"), .count = 1 },
            .{ .name = "a_deco", .off = @offsetOf(Instance, "deco"), .count = 1 },
            .{ .name = "a_italic", .off = @offsetOf(Instance, "italic"), .count = 1 },
            .{ .name = "a_bold", .off = @offsetOf(Instance, "bold"), .count = 1 },
            .{ .name = "a_colored", .off = @offsetOf(Instance, "colored"), .count = 1 },
            .{ .name = "a_deco_color", .off = @offsetOf(Instance, "deco_color"), .count = 4 },
        };
        for (fields) |f| {
            const loc = c.glGetAttribLocation(self.program, f.name.ptr);
            if (loc < 0) continue;
            const idx: c_uint = @intCast(loc);
            c.glEnableVertexAttribArray(idx);
            c.glVertexAttribPointer(idx, f.count, c.GL_FLOAT, c.GL_FALSE, stride, @ptrFromInt(f.off));
            c.glVertexAttribDivisor(idx, 1);
        }
    }

    /// Re-allocate the instance buffer when grid size changes.
    fn ensureCapacity(self: *CellPass, rows: u16, cols: u16) !void {
        if (rows == self.cap_rows and cols == self.cap_cols and self.instances.items.len == @as(usize, rows) * @as(usize, cols)) return;
        const total: usize = @as(usize, rows) * @as(usize, cols);
        try self.instances.resize(self.allocator, total);
        @memset(self.instances.items, .{});
        try self.row_needs_upload.resize(self.allocator, rows);
        for (self.row_needs_upload.items) |*r| r.* = true;
        try self.rebuilt_rows.resize(self.allocator, rows);
        for (self.rebuilt_rows.items) |*r| r.* = true;
        self.cap_rows = rows;
        self.cap_cols = cols;
    }

    fn rowSlice(self: *CellPass, row: u16) []Instance {
        const cols: usize = self.cap_cols;
        const start: usize = @as(usize, row) * cols;
        return self.instances.items[start .. start + cols];
    }

    /// Rebuild dirty rows + sync GL buffer. Called from the render path.
    pub fn rebuildAndUpload(
        self: *CellPass,
        screen: *Screen,
        pool: *const StylePool,
        atlas: *Atlas,
    ) !void {
        const profile_mod = @import("../util/profile.zig");
        const t_loop_start = if (profile_mod.enabled) profile_mod.nanoTimestamp() else 0;
        // Reset the per-frame "rebuilt" mask so callers reading after
        // this returns see only rows we actually touched this frame.
        for (self.rebuilt_rows.items) |*r| r.* = false;
        // Sync default fg/bg / palette / reverse-screen swap. When any
        // of these CHANGES from last frame, every cell whose color
        // resolved to default / palette has stale RGBA in the instance
        // VBO — force a full rebuild so colors get re-resolved.
        const want_fg: [4]f32 = if (screen.reverse_screen) screen.default_bg else screen.default_fg;
        const want_bg: [4]f32 = if (screen.reverse_screen) screen.default_fg else screen.default_bg;
        const colors_changed =
            !std.mem.eql(f32, &self.default_fg, &want_fg) or
            !std.mem.eql(f32, &self.default_bg, &want_bg) or
            !std.mem.eql(u8, std.mem.asBytes(&self.palette), std.mem.asBytes(&screen.palette));
        self.default_fg = want_fg;
        self.default_bg = want_bg;
        self.palette = screen.palette;
        if (colors_changed) {
            for (self.row_needs_upload.items) |*r| r.* = true;
        }

        // Capacity: includes scrollback view rows. The instance grid
        // shows exactly screen.rows lines; scrollback content is
        // copied into the appropriate top rows during build.
        try self.ensureCapacity(screen.rows, screen.cols);

        // Detect atlas page eviction since last frame: any layer whose
        // generation moved invalidates ALL cached glyph references in
        // existing instances. Force a full rebuild in that case.
        var atlas_evicted = false;
        for (atlas.pages, 0..) |p, i| {
            if (p.generation != self.last_atlas_generations[i]) {
                atlas_evicted = true;
                self.last_atlas_generations[i] = p.generation;
            }
        }
        if (atlas_evicted) {
            for (self.row_needs_upload.items) |*r| r.* = true;
        }

        // Glyph Protocol glossary mutation — see `last_glyph_gen`.
        if (screen.glyphs.generation != self.last_glyph_gen) {
            self.last_glyph_gen = screen.glyphs.generation;
            for (self.row_needs_upload.items) |*r| r.* = true;
        }

        const cw: f32 = @floatFromInt(atlas.cell_w);
        const ch: f32 = @floatFromInt(atlas.cell_h);
        const ascent: f32 = @floatFromInt(atlas.ascent);
        const pad = self.pad;

        const buf = if (screen.use_alt) screen.alt.? else screen.active;
        const sb_count: u32 = if (screen.use_alt) 0 else screen.scrollbackCount();
        const view_off: u32 = @min(screen.view_offset, sb_count);

        // Scroll-position change: every row sources from a different
        // line. Mark all dirty exactly once on the change instead of
        // every frame while scrolled-back. Also invalidate when
        // scrollback grew while we're scrolled-back (the displayed
        // scrollback indices shift then too).
        const view_changed = view_off != self.last_view_off;
        const sb_drifted = view_off > 0 and sb_count != self.last_sb_count;
        if (view_changed or sb_drifted) {
            for (self.row_needs_upload.items) |*r| r.* = true;
            self.last_view_off = view_off;
        }
        self.last_sb_count = sb_count;

        // Build dirty rows.
        var any_built = false;
        var row: u16 = 0;
        while (row < screen.rows) : (row += 1) {
            const ln_ptr: *Line = if (row < view_off) blk: {
                const sb_idx = sb_count - view_off + row;
                break :blk @constCast(screen.scrollbackLine(sb_idx));
            } else &buf[row - view_off];

            const need_rebuild = ln_ptr.*.dirty or self.row_needs_upload.items[row] or atlas_evicted;
            if (!need_rebuild) continue;

            try self.rebuildRow(ln_ptr.*, row, screen.cols, atlas, pool, &screen.glyphs, cw, ch, ascent, pad);
            ln_ptr.*.dirty = false;
            self.row_needs_upload.items[row] = true;
            self.rebuilt_rows.items[row] = true;
            any_built = true;
        }
        self.cells_rebuilt = any_built;

        // Skip the upload path entirely when nothing's dirty — avoids
        // glBindBuffer + the persistent-mapped fence wait on idle
        // frames where we're only here for cursor blink / overlay
        // state changes.
        if (!any_built) return;
        if (profile_mod.enabled) {
            const now = profile_mod.nanoTimestamp();
            profile_mod.record(.cell_rebuild_loop, @intCast(now - t_loop_start));
        }
        const t_upload = if (profile_mod.enabled) profile_mod.nanoTimestamp() else 0;
        try self.uploadDirtyRows();
        if (profile_mod.enabled) profile_mod.record(.cell_upload, @intCast(profile_mod.nanoTimestamp() - t_upload));
    }

    fn rebuildRow(
        self: *CellPass,
        ln: Line,
        row: u16,
        cols: u16,
        atlas: *Atlas,
        pool: *const StylePool,
        glossary: *const @import("../grid/glyph_glossary.zig").Glossary,
        cw: f32,
        ch: f32,
        ascent: f32,
        pad: f32,
    ) !void {
        const slice = self.rowSlice(row);
        @memset(slice, .{});

        // Bidi rows + DH/DW rows are rendered by GridPass (overlay
        // pipeline), not here — the cell-aligned LTR layout this
        // pipeline assumes is wrong for them. Leave the row's
        // instances zeroed so the cell pass emits nothing.
        const cells_for_check = ln.cells[0..@min(@as(usize, cols), ln.cells.len)];
        if (ln.scaling != .single or rowHasNonAscii(cells_for_check)) return;

        const x_scale: f32 = if (ln.scaling == .single) 1.0 else 2.0;
        const y_scale: f32 = if (ln.scaling == .dhl_top or ln.scaling == .dhl_bot) 2.0 else 1.0;
        const y_origin_shift: f32 = if (ln.scaling == .dhl_bot) -ch else 0.0;
        const y: f32 = pad + @as(f32, @floatFromInt(row)) * ch;

        // First, lay down cell-aligned bg + per-codepoint glyph.
        // Style resolution is expensive (Pool.get + 2 × colorToRGBA +
        // reverse swap + dim multiply + deco-kind chain). Runs of
        // consecutive cells with the same style_ref are common — vim's
        // chrome strings, tree-view rows, status lines. Cache the last
        // resolved values per style_ref and reuse.
        var col: u16 = 0;
        const cells = ln.cells[0..@min(@as(usize, cols), ln.cells.len)];
        var cached_style: u16 = 0xFFFF;
        var cached_fg: [4]f32 = .{ 0, 0, 0, 0 };
        var cached_bg: [4]f32 = .{ 0, 0, 0, 0 };
        var cached_has_bg: bool = false;
        var cached_deco: f32 = 0;
        var cached_deco_color: [4]f32 = .{ 0, 0, 0, 0 };
        var cached_italic: f32 = 0;
        var cached_attr_italic: bool = false;
        var cached_bold: f32 = 0;
        while (col < cells.len) : (col += 1) {
            const cell = cells[col];
            const is_wide = (cell.flags & 0b0000_0001) != 0;
            const cell_w_count: f32 = if (is_wide) 2.0 else 1.0;
            const cx: f32 = pad + @as(f32, @floatFromInt(col)) * cw * x_scale;
            const cell_w: f32 = cw * cell_w_count * x_scale;

            slice[col].cell_xy = .{ cx, y };
            slice[col].cell_size = .{ cell_w, ch };

            if (cell.style_ref != cached_style) {
                const style = pool.get(cell.style_ref);
                const resolved = self.resolveStyleColors(style);
                cached_fg = resolved.fg;
                cached_bg = if (resolved.has_bg) resolved.bg else .{ 0, 0, 0, 0 };
                cached_has_bg = resolved.has_bg;
                cached_deco = if (style.attrs.curly_underline) 3.0
                    else if (style.attrs.double_underline) 2.0
                    else if (style.attrs.underline) 1.0
                    else if (style.attrs.strikethrough) 4.0
                    else if (style.attrs.overline) 5.0
                    else 0.0;
                cached_deco_color = switch (style.underline_color) {
                    .default => cached_fg,
                    else => self.colorToRGBA(style.underline_color, true),
                };
                cached_attr_italic = style.attrs.italic;
                // Shader shear is the fallback for families without a
                // real italic face; with one, the italic glyph itself
                // carries the slant.
                cached_italic = if (style.attrs.italic and !atlas.hasItalic()) 1.0 else 0.0;
                cached_bold = if (style.attrs.bold and self.allow_bold) 1.0 else 0.0;
                cached_style = cell.style_ref;
            }
            slice[col].bg = cached_bg;
            slice[col].fg = cached_fg;
            slice[col].has_glyph = 1.0; // 1 = no glyph until we set one
            slice[col].deco = cached_deco;
            slice[col].deco_color = cached_deco_color;
            slice[col].italic = cached_italic;
            slice[col].bold = cached_bold;
            // Per-codepoint glyph (will be overridden by ligature shaping
            // below if applicable). Bold pulls a real bold glyph from the
            // atlas (bold face or outline-embolden) — no shader fakery.
            if (cell.rune != 0 and cell.rune != ' ' and (cell.flags & 0b0000_0010) == 0) {
                const g = atlas.lookupGlyph(glossary, cell.rune, cached_bold > 0.5, cached_attr_italic, cached_fg) catch continue;
                if (g.w > 0 and g.h > 0) {
                    const gx: f32 = cx + @as(f32, @floatFromInt(g.bearing_x)) * x_scale;
                    const gy: f32 = y + ascent - @as(f32, @floatFromInt(g.bearing_y)) * y_scale + y_origin_shift;
                    const gw: f32 = @as(f32, @floatFromInt(g.w)) * x_scale;
                    const gh: f32 = @as(f32, @floatFromInt(g.h)) * y_scale;
                    slice[col].glyph_xy = .{ gx, gy };
                    slice[col].glyph_size = .{ gw, gh };
                    slice[col].glyph_uv0 = .{ g.u0, g.v0 };
                    slice[col].glyph_uv1 = .{ g.u1, g.v1 };
                    slice[col].glyph_layer = @floatFromInt(g.layer);
                    slice[col].has_glyph = 0.0;
                    slice[col].colored = if (g.colored) 1.0 else 0.0;
                    // No italic shear on colour emoji — shearing the
                    // RGBA strike just distorts it.
                    if (g.colored) slice[col].italic = 0.0;
                }
            }
        }

        // Optionally upgrade to ligature-shaped glyphs for runs of pure
        // ASCII same-style cells. The bidi-aware path stays in the
        // overlay (handled by the legacy GridPass — see grid_pass.zig)
        // when any non-ASCII is present.
        if (self.enable_ligatures and atlas.hb_font != null and ln.scaling == .single) {
            try self.applyLigatures(slice, cells, atlas, pool, cw, y, ascent, pad, row);
        }
    }

    /// Walk same-style ASCII runs and replace per-cell glyphs with
    /// HarfBuzz-shaped output. Cells that lose their glyph (continuation
    /// of a ligature) are cleared. Cells that gain a wider glyph keep
    /// their bg + cell rect untouched, only glyph_xy/size updated.
    fn applyLigatures(
        self: *CellPass,
        instances: []Instance,
        cells: []const Cell,
        atlas: *Atlas,
        pool: *const StylePool,
        cw: f32,
        y: f32,
        ascent: f32,
        pad: f32,
        _: u16,
    ) !void {
        var col: u16 = 0;
        const n: u16 = @intCast(cells.len);
        while (col < n) {
            const cell = cells[col];
            const printable = cell.rune > 0x20 and cell.rune < 0x7F and (cell.flags & 0b0000_0010) == 0;
            if (!printable) {
                col += 1;
                continue;
            }
            const run_start = col;
            const run_style = cell.style_ref;
            while (col < n) : (col += 1) {
                const c2 = cells[col];
                if (c2.rune <= 0x20 or c2.rune >= 0x7F) break;
                if ((c2.flags & 0b0000_0010) != 0) break;
                if (c2.style_ref != run_style) break;
            }
            const run_len = col - run_start;
            if (run_len < 2) continue;

            // Cheap eligibility filter: ligatures in mainstream
            // programming fonts (Fira Code, JetBrains Mono, Cascadia,
            // Iosevka, Hasklug, etc.) only fire on punctuation glyphs.
            // Pure alphanumeric runs cost nothing in the glyph layout
            // pass already; calling hb_shape on them is wasted work.
            // Skip the run unless it contains at least one of the
            // common ligature trigger characters.
            var lig_eligible = false;
            {
                var k: u16 = 0;
                while (k < run_len) : (k += 1) {
                    const cp = cells[run_start + k].rune;
                    switch (cp) {
                        '=', '<', '>', '!', '-', ':', '&', '|',
                        '+', '*', '/', '?', '#', '~', '$', '.', '@',
                        => {
                            lig_eligible = true;
                            break;
                        },
                        else => {},
                    }
                }
            }
            if (!lig_eligible) continue;

            // Build UTF-8 of the run. Programming-font ligatures are
            // ASCII (==, !=, ->, …); on a non-ASCII codepoint we bail
            // rather than pass garbage to HarfBuzz.
            var bytes: [256]u8 = undefined;
            var blen: usize = 0;
            var lig_ascii_only = true;
            var k: u16 = 0;
            while (k < run_len) : (k += 1) {
                const cp = cells[run_start + k].rune;
                if (cp >= 0x80) {
                    lig_ascii_only = false;
                    break;
                }
                if (blen >= bytes.len) break;
                bytes[blen] = @intCast(cp);
                blen += 1;
            }
            if (!lig_ascii_only) continue;
            if (blen == 0) continue;

            // Styled runs shape + rasterize against the matching face
            // (or synthesize) so the ligature matches its cells.
            const run_attrs = pool.get(run_style).attrs;
            const run_bold = run_attrs.bold and self.allow_bold;
            const run_italic = run_attrs.italic;

            // Atlas owns the cached shape slice — do NOT free.
            const shaped = atlas.shapeRun(self.allocator, bytes[0..blen], run_bold, run_italic) catch continue;
            if (shaped.len == 0 or shaped.len == run_len) continue; // No ligation occurred.

            // Clear all run cells' glyphs first; we'll repopulate.
            var cc: u16 = run_start;
            while (cc < run_start + run_len) : (cc += 1) instances[cc].has_glyph = 1.0;

            const style = pool.get(run_style);
            // Must match rebuildRow's resolution exactly (bold-bright
            // lift, reverse swap, dim attenuation) — otherwise ligature
            // glyphs render with a different fg than the surrounding
            // cells. The most visible failure mode: dim placeholder
            // text containing `...`, `->`, `=>` etc. shows a bright
            // glyph at the ligature anchor while the rest stays dim.
            const fg = self.resolveStyleColors(style).fg;

            for (shaped) |sg| {
                const cluster_col = run_start + @as(u16, @intCast(@min(@as(usize, sg.cluster), @as(usize, run_len) - 1)));
                const g = atlas.lookupOrLoadById(sg.glyph_id, run_bold, run_italic) catch continue;
                if (g.w == 0 or g.h == 0) continue;
                const x: f32 = pad + @as(f32, @floatFromInt(cluster_col)) * cw;
                const xoff: f32 = @as(f32, @floatFromInt(sg.x_offset)) / 64.0;
                const yoff: f32 = @as(f32, @floatFromInt(sg.y_offset)) / 64.0;
                const gx: f32 = x + @as(f32, @floatFromInt(g.bearing_x)) + xoff;
                const gy: f32 = y + ascent - @as(f32, @floatFromInt(g.bearing_y)) - yoff;
                instances[cluster_col].glyph_xy = .{ gx, gy };
                instances[cluster_col].glyph_size = .{ @floatFromInt(g.w), @floatFromInt(g.h) };
                instances[cluster_col].glyph_uv0 = .{ g.u0, g.v0 };
                instances[cluster_col].glyph_uv1 = .{ g.u1, g.v1 };
                instances[cluster_col].glyph_layer = @floatFromInt(g.layer);
                instances[cluster_col].fg = fg;
                instances[cluster_col].has_glyph = 0.0;
            }
        }
    }

    fn uploadDirtyRows(self: *CellPass) !void {
        if (self.vbos[0] == 0) return;
        const total_bytes: usize = self.instances.items.len * @sizeOf(Instance);
        if (total_bytes == 0) return;

        // Advance to the next slot. With 3 slots and our render rate,
        // the GPU is long done with whatever was in this slot.
        self.vbo_slot = (self.vbo_slot + 1) % 3;
        const slot: usize = self.vbo_slot;

        c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbos[slot]);

        // Allocate storage on the very first visit to each slot —
        // subsequent calls reuse it via map+invalidate.
        if (self.vbo_caps[slot] < total_bytes) {
            c.glBufferData(c.GL_ARRAY_BUFFER, @intCast(total_bytes), null, c.GL_STREAM_DRAW);
            self.vbo_caps[slot] = total_bytes;
        }

        // glMapBufferRange + INVALIDATE_BUFFER_BIT + UNSYNCHRONIZED_BIT
        // is the documented fastest streaming-upload path. INVALIDATE
        // tells the driver we don't need the existing contents (so it
        // won't preserve them); UNSYNCHRONIZED tells it not to wait
        // for pending GPU work referencing the buffer (we guarantee
        // that with the slot rotation above). With both flags Mesa
        // hands us a fresh memory region without any client-server
        // round-trip.
        const flags: c.GLbitfield = c.GL_MAP_WRITE_BIT |
            c.GL_MAP_INVALIDATE_BUFFER_BIT |
            c.GL_MAP_UNSYNCHRONIZED_BIT;
        const ptr_raw = c.glMapBufferRange(c.GL_ARRAY_BUFFER, 0, @intCast(total_bytes), flags);
        if (ptr_raw != null) {
            const dst: [*]u8 = @ptrCast(ptr_raw);
            const src: [*]const u8 = @ptrCast(self.instances.items.ptr);
            @memcpy(dst[0..total_bytes], src[0..total_bytes]);
            _ = c.glUnmapBuffer(c.GL_ARRAY_BUFFER);
        } else {
            // Fallback if mapping fails for any reason — full re-upload.
            c.glBufferData(
                c.GL_ARRAY_BUFFER,
                @intCast(total_bytes),
                self.instances.items.ptr,
                c.GL_STREAM_DRAW,
            );
        }
        for (self.row_needs_upload.items) |*r| r.* = false;
    }

    /// Mark every row dirty — called when the screen state changed in
    /// ways the renderer can't introspect (palette swap, default colors,
    /// reverse-screen toggle, view scroll).
    pub fn markAllDirty(self: *CellPass) void {
        for (self.row_needs_upload.items) |*r| r.* = true;
    }

    pub fn draw(self: *CellPass, atlas: *Atlas, viewport_w: i32, viewport_h: i32) void {
        if (self.program == 0 or self.instances.items.len == 0) return;
        c.glUseProgram(self.program);
        c.glUniform2f(self.u_screen_px, @floatFromInt(viewport_w), @floatFromInt(viewport_h));
        c.glUniform1f(self.u_dim_fg, self.dim_fg);
        c.glUniform1f(self.u_dim_bg, self.dim_bg);
        c.glActiveTexture(c.GL_TEXTURE0);
        c.glBindTexture(c.GL_TEXTURE_2D_ARRAY, atlas.gl_tex);
        c.glUniform1i(self.u_atlas, 0);

        // Bind the VAO that matches the slot the upload just wrote.
        c.glBindVertexArray(self.vaos[self.vbo_slot]);
        c.glEnable(c.GL_BLEND);
        c.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);

        // Pass 1: backgrounds.
        c.glUniform1i(self.u_kind, 0);
        c.glDrawArraysInstanced(c.GL_TRIANGLES, 0, 6, @intCast(self.instances.items.len));

        // Pass 2: glyphs.
        c.glUniform1i(self.u_kind, 1);
        c.glDrawArraysInstanced(c.GL_TRIANGLES, 0, 6, @intCast(self.instances.items.len));

        // Pass 3: line decorations (underline / double / curly /
        // strike / overline). The vertex shader collapses cells with
        // deco=0 to a degenerate triangle, so cells without
        // decorations cost only the vertex throughput.
        c.glUniform1i(self.u_kind, 2);
        c.glDrawArraysInstanced(c.GL_TRIANGLES, 0, 6, @intCast(self.instances.items.len));

        c.glDisable(c.GL_BLEND);
        c.glBindVertexArray(0);
    }

    fn colorToVec(self: *const CellPass, color: Color, is_fg: bool, reverse: bool) [4]f32 {
        return style_util.colorToVec(color, is_fg, reverse, self.default_fg, self.default_bg, &self.palette);
    }

    /// Resolve a Color to RGBA without considering reverse video —
    /// the caller swaps fg/bg explicitly to honour reverse on
    /// non-default colors too.
    fn colorToRGBA(self: *const CellPass, color: Color, is_fg: bool) [4]f32 {
        return style_util.colorToRGBA(color, is_fg, self.default_fg, self.default_bg, &self.palette);
    }

    /// Resolve a style entry to its final fg/bg vec4s with bold-bright
    /// lifting (palette 0..7 → 8..15 when bold), reverse-video swap,
    /// and dim attenuation applied. `has_bg` reports whether the bg
    /// is explicit (the caller leaves the instance bg zeroed when not,
    /// so the window-clear color shows through).
    fn resolveStyleColors(self: *const CellPass, style: StyleEntry) struct {
        fg: [4]f32,
        bg: [4]f32,
        has_bg: bool,
    } {
        var fg_color = style.fg;
        if (style.attrs.bold and self.allow_bold and self.bold_is_bright) {
            if (fg_color == .palette and fg_color.palette < 8) {
                fg_color = .{ .palette = fg_color.palette + 8 };
            }
        }
        var fg_rgba = self.colorToRGBA(fg_color, true);
        var bg_rgba = self.colorToRGBA(style.bg, false);
        var has_bg = style.bg != .default;
        if (style.attrs.reverse) {
            const tmp = fg_rgba;
            fg_rgba = bg_rgba;
            bg_rgba = tmp;
            has_bg = true;
        }
        if (style.attrs.dim) {
            fg_rgba[0] *= DIM_FG_SCALE;
            fg_rgba[1] *= DIM_FG_SCALE;
            fg_rgba[2] *= DIM_FG_SCALE;
        }
        // Effective bg is the clearcolor when the cell has none.
        const eff_bg = if (has_bg) bg_rgba else self.default_bg;
        fg_rgba = style_util.applyMinContrast(fg_rgba, eff_bg, self.min_contrast);
        return .{ .fg = fg_rgba, .bg = bg_rgba, .has_bg = has_bg };
    }
};

/// Per-channel attenuation applied to fg color when SGR 2 (dim/faint)
/// is set. Matches the value used in grid_pass.zig.
const DIM_FG_SCALE: f32 = 0.65;

/// Forwards to the canonical predicate on Screen. CellPass skips
/// rows for which this returns true so the GridPass overlay path
/// can render them with bidi reorder + complex-script shaping.
fn rowHasNonAscii(cells: []const Cell) bool {
    return Screen.rowNeedsBidiOrComplexShape(cells);
}

pub fn rowNeedsBidiOrComplexShape(cells: []const Cell) bool {
    return Screen.rowNeedsBidiOrComplexShape(cells);
}

test "Instance is 120 bytes" {
    try std.testing.expectEqual(@as(usize, 120), @sizeOf(Instance));
}
