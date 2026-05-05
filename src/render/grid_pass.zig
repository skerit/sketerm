//! Overlay pass — cursor, selection, preedit, bell flash, focus
//! border, scrollback indicator, and the bidi-reordered glyph runs
//! that don't fit the cell-instance pipeline (any row containing
//! non-ASCII characters or per-line scaling).
//!
//! The cell grid itself (per-cell bg + per-cell glyph for ASCII /
//! single-scaling rows) lives in `cell_pass.zig` and uses GPU
//! instancing + a persistent VBO. Anything OUTSIDE the cell-aligned
//! single-scale ASCII grid lands here.
//!
//! Per-frame VBO. Acceptable size since overlays are tiny vs. the
//! cell grid: cursor + selection + a bell flash is at most ~50 quads.

const std = @import("std");
const c = @import("../c.zig").c;
const gl = @import("gl.zig");
const atlas_mod = @import("atlas.zig");
const Atlas = atlas_mod.Atlas;
const Screen = @import("../grid/screen.zig").Screen;
const StylePool = @import("../grid/style_pool.zig").Pool;
const Color = @import("../grid/style_pool.zig").Color;
const Cell = @import("../grid/cell.zig").Cell;
const style_util = @import("style.zig");

const VERT_SRC =
    \\#version 300 es
    \\in vec2 a_pos;
    \\in vec3 a_uv; // (u, v, layer)
    \\in vec4 a_color;
    \\in float a_is_glyph;
    \\// Per-vertex dim source: 0 = no dim (cursor, selection, focus
    \\// border, search highlight, bell flash); 1 = use u_dim_fg (cell
    \\// glyphs, IME preedit); 2 = use u_dim_bg (cell bg quads).
    \\in float a_dim;
    \\// Italic shear: 1.0 = apply tan(13°) ≈ 0.231 horizontal shear
    \\// pivoted around the cell's bottom edge. 0 = no shear.
    \\in float a_italic;
    \\// Faux-bold flag: passed through to fragment for double-sample.
    \\in float a_bold;
    \\// Cell bottom-edge y in pixel space — pivot for italic shear.
    \\in float a_baseline_y;
    \\
    \\uniform vec2 u_screen_px;
    \\uniform float u_dim_fg;
    \\uniform float u_dim_bg;
    \\
    \\out vec3 v_uv;
    \\out vec4 v_color;
    \\out float v_is_glyph;
    \\out float v_bold;
    \\
    \\void main() {
    \\    vec2 pos = a_pos;
    \\    if (a_italic > 0.5) {
    \\        pos.x += (a_baseline_y - pos.y) * 0.231;
    \\    }
    \\    vec2 ndc = (pos / u_screen_px) * 2.0 - 1.0;
    \\    ndc.y = -ndc.y;
    \\    gl_Position = vec4(ndc, 0.0, 1.0);
    \\    v_uv = a_uv;
    \\    float k = 1.0;
    \\    if (a_dim > 1.5) k = u_dim_bg;
    \\    else if (a_dim > 0.5) k = u_dim_fg;
    \\    v_color = vec4(a_color.rgb * k, a_color.a);
    \\    v_is_glyph = a_is_glyph;
    \\    v_bold = a_bold;
    \\}
;

// ATLAS_TEXEL = 1/PAGE_SIZE — per-texel UV step for the faux-bold
// left-neighbor sample (see cell_pass.zig comment).
const FRAG_SRC = std.fmt.comptimePrint(
    \\#version 300 es
    \\precision mediump float;
    \\precision mediump sampler2DArray;
    \\
    \\const float ATLAS_TEXEL = 1.0 / {d}.0;
    \\
    \\in vec3 v_uv;
    \\in vec4 v_color;
    \\in float v_is_glyph;
    \\in float v_bold;
    \\
    \\uniform sampler2DArray u_atlas;
    \\
    \\out vec4 o_frag;
    \\
    \\void main() {{
    \\    if (v_is_glyph > 0.5) {{
    \\        float a = texture(u_atlas, v_uv).r;
    \\        if (v_bold > 0.5) {{
    \\            // See cell_pass.zig faux-bold comment — sample
    \\            // LEFT (extends right) preserves the antialiased
    \\            // left edge instead of overwriting it.
    \\            float a2 = texture(u_atlas, v_uv - vec3(ATLAS_TEXEL, 0.0, 0.0)).r;
    \\            a = max(a, a2);
    \\        }}
    \\        o_frag = vec4(v_color.rgb, a * v_color.a);
    \\    }} else {{
    \\        o_frag = v_color;
    \\    }}
    \\}}
, .{atlas_mod.PAGE_SIZE});

const Vertex = extern struct {
    pos: [2]f32,
    uv: [3]f32,
    color: [4]f32,
    is_glyph: f32,
    dim: f32 = 0.0,
    italic: f32 = 0.0,
    bold: f32 = 0.0,
    baseline_y: f32 = 0.0,
};

/// Snapshot of every input that affects the overlay vertex buffer
/// (cursor, selection, search, preedit, focus border, scrollbar,
/// bell flash, default colors/palette, viewport, atlas metrics, and
/// the GridPass-owned tunables). Cell content is *not* in here — the
/// caller passes a separate `cells_changed` flag from CellPass.
///
/// Compared field-by-field via `std.meta.eql`; nested fixed arrays
/// (palette, color vecs) recurse element-wise. Slice contents that
/// can vary at the same length (search highlights, preedit text) are
/// hashed instead of compared by ptr+len.
const Snapshot = struct {
    canvas_w: f32 = 0,
    canvas_h: f32 = 0,
    pad: f32 = 0,
    focused: bool = false,

    use_alt: bool = false,
    view_off: u32 = 0,
    sb_count: u32 = 0,

    rows: u16 = 0,
    cols: u16 = 0,
    cell_w: u16 = 0,
    cell_h: u16 = 0,
    ascent: i16 = 0,

    reverse_screen: bool = false,
    default_fg: [4]f32 = .{ 0, 0, 0, 0 },
    default_bg: [4]f32 = .{ 0, 0, 0, 0 },
    palette: [256][3]u8 = std.mem.zeroes([256][3]u8),

    cursor_visible: bool = false,
    cursor_blink_on: bool = false,
    cursor_shape: u8 = 0,
    cursor_row: u16 = 0,
    cursor_col: u16 = 0,
    cursor_color: [4]f32 = .{ 0, 0, 0, 0 },

    selection_mode: u8 = 0,
    selection_anchor_row: i32 = 0,
    selection_anchor_col: i32 = 0,
    selection_end_row: i32 = 0,
    selection_end_col: i32 = 0,

    search_count: u32 = 0,
    search_active_idx: i32 = -1,
    search_hash: u64 = 0,

    preedit_hash: u64 = 0,
    preedit_len: usize = 0,

    bell_at_us: i64 = 0,

    dim_fg: f32 = 1.0,
    dim_bg: f32 = 1.0,
    enable_url_underline: bool = true,
    enable_bidi: bool = true,
    enable_ligatures: bool = true,
    allow_bold: bool = true,
    bold_is_bright: bool = true,
};

pub const GridPass = struct {
    program: c_uint = 0,
    vao: c_uint = 0,
    vbo: c_uint = 0,
    u_screen_px: c_int = -1,
    u_atlas: c_int = -1,
    u_dim_fg: c_int = -1,
    u_dim_bg: c_int = -1,
    /// Inactive-pane dimming. fg multiplier (glyphs + IME preedit) and
    /// bg multiplier (cell bg quads in bidi/DW overlay rows). Cursor,
    /// focus border, selection, search highlight, bell flash are
    /// emitted with `a_dim = 0` so they stay full-bright regardless.
    dim_fg: f32 = 1.0,
    dim_bg: f32 = 1.0,
    vbuf: std.ArrayList(Vertex) = .{},
    /// Default fg/bg used by overlays that need them (preedit text).
    default_fg: [4]f32 = .{ 0.92, 0.92, 0.92, 1.0 },
    default_bg: [4]f32 = .{ 0.10, 0.10, 0.10, 1.0 },
    palette: [256][3]u8 = palette_256,
    pad: f32 = 6.0,
    canvas_w: f32 = 0,
    canvas_h: f32 = 0,
    enable_ligatures: bool = true,
    enable_bidi: bool = true,
    /// Honour the bold attribute at all (font weight + bright-color).
    allow_bold: bool = true,
    /// When bold + allow_bold, lift palette 0..7 to 8..15.
    bold_is_bright: bool = true,
    /// Underline auto-detected http(s) URLs in cell content. Off
    /// skips the per-row scan + render entirely.
    enable_url_underline: bool = true,
    allocator: std.mem.Allocator,
    /// Scratch buffers for bidi resolution + visual ordering. Grow
    /// to cols on first use; subsequent frames reuse them. Avoids
    /// 3 allocs per bidi row per frame.
    bidi_cps: std.ArrayList(u32) = .{},
    bidi_levels: std.ArrayList(u8) = .{},
    bidi_indices: std.ArrayList(usize) = .{},

    /// Vertex-buffer reuse gating. After a successful build, holds
    /// the inputs the build saw. On the next call, if cell content
    /// hasn't changed, atlas pages haven't been evicted, the bell
    /// isn't fading, and the snapshot still matches, `buildVertices`
    /// returns immediately and `draw()` reuses the prior vbuf — the
    /// GL upload is also skipped when `vbo_uploaded` is already set.
    /// Reset by `forgetGL` (GL context loss invalidates everything).
    vbuf_valid: bool = false,
    /// Tracks whether the live VBO contents match `vbuf.items`. Set
    /// after `draw` uploads. Cleared by every `buildVertices` rebuild
    /// and by `forgetGL`. When set, `draw` skips the `glBufferData`.
    vbo_uploaded: bool = false,
    last_snapshot: Snapshot = .{},
    last_atlas_generations: [atlas_mod.PAGE_COUNT]u32 =
        [_]u32{0} ** atlas_mod.PAGE_COUNT,

    /// Per-row caches keyed off the cell pass's `rebuilt_rows` mask.
    /// Each row owns its own `Match` slice (URL hits) and a single
    /// boolean for whether the row needs the bidi/DH overlay path.
    /// Both invalidate on any rebuild signalled from the cell pass.
    row_url_matches: std.ArrayList(std.ArrayList(@import("../grid/url_scan.zig").Match)) = .{},
    row_url_match_count: std.ArrayList(usize) = .{},
    row_overlay_needed: std.ArrayList(bool) = .{},
    row_caches_valid: std.ArrayList(bool) = .{},

    pub fn init(allocator: std.mem.Allocator) GridPass {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *GridPass) void {
        self.vbuf.deinit(self.allocator);
        self.bidi_cps.deinit(self.allocator);
        self.bidi_levels.deinit(self.allocator);
        self.bidi_indices.deinit(self.allocator);
        for (self.row_url_matches.items) |*lst| lst.deinit(self.allocator);
        self.row_url_matches.deinit(self.allocator);
        self.row_url_match_count.deinit(self.allocator);
        self.row_overlay_needed.deinit(self.allocator);
        self.row_caches_valid.deinit(self.allocator);
    }

    /// Ensure scratch capacity for `n` cells. Returns three slices.
    fn bidiScratch(self: *GridPass, n: usize) !struct { cps: []u32, lvls: []u8, idx: []usize } {
        try self.bidi_cps.resize(self.allocator, n);
        try self.bidi_levels.resize(self.allocator, n);
        try self.bidi_indices.resize(self.allocator, n);
        return .{
            .cps = self.bidi_cps.items,
            .lvls = self.bidi_levels.items,
            .idx = self.bidi_indices.items,
        };
    }

    pub fn forgetGL(self: *GridPass) void {
        self.program = 0;
        self.vao = 0;
        self.vbo = 0;
        self.u_screen_px = -1;
        self.u_atlas = -1;
        self.u_dim_fg = -1;
        self.u_dim_bg = -1;
        self.vbuf_valid = false;
        self.vbo_uploaded = false;
        self.last_atlas_generations = [_]u32{0} ** atlas_mod.PAGE_COUNT;
        // Per-row caches don't depend on GL state, but they do hold
        // glyph-position / bidi info that's tied to the atlas. Drop
        // them so a re-realize against a fresh atlas rescans cleanly.
        for (self.row_caches_valid.items) |*r| r.* = false;
    }

    pub fn realize(self: *GridPass) !void {
        if (self.program != 0) return;
        // Pre-grow the vertex buffer once so the first few frames
        // don't repeatedly realloc as the overlay reaches steady state.
        // 2048 vertices × ~52 B = ~100 KB — well within budget.
        if (self.vbuf.capacity < 2048) {
            try self.vbuf.ensureTotalCapacity(self.allocator, 2048);
        }
        self.program = try gl.buildProgram(VERT_SRC, FRAG_SRC);
        self.u_screen_px = c.glGetUniformLocation(self.program, "u_screen_px");
        self.u_atlas = c.glGetUniformLocation(self.program, "u_atlas");
        self.u_dim_fg = c.glGetUniformLocation(self.program, "u_dim_fg");
        self.u_dim_bg = c.glGetUniformLocation(self.program, "u_dim_bg");

        c.glGenVertexArrays(1, &self.vao);
        c.glBindVertexArray(self.vao);
        c.glGenBuffers(1, &self.vbo);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbo);

        const stride: c_int = @sizeOf(Vertex);
        const a_pos: c_uint = @intCast(c.glGetAttribLocation(self.program, "a_pos"));
        const a_uv: c_uint = @intCast(c.glGetAttribLocation(self.program, "a_uv"));
        const a_color: c_uint = @intCast(c.glGetAttribLocation(self.program, "a_color"));
        const a_is_glyph: c_uint = @intCast(c.glGetAttribLocation(self.program, "a_is_glyph"));
        const a_dim: c_uint = @intCast(c.glGetAttribLocation(self.program, "a_dim"));
        const a_italic: c_uint = @intCast(c.glGetAttribLocation(self.program, "a_italic"));
        const a_bold: c_uint = @intCast(c.glGetAttribLocation(self.program, "a_bold"));
        const a_baseline_y: c_uint = @intCast(c.glGetAttribLocation(self.program, "a_baseline_y"));

        c.glEnableVertexAttribArray(a_pos);
        c.glVertexAttribPointer(a_pos, 2, c.GL_FLOAT, c.GL_FALSE, stride, @ptrFromInt(@offsetOf(Vertex, "pos")));
        c.glEnableVertexAttribArray(a_uv);
        c.glVertexAttribPointer(a_uv, 3, c.GL_FLOAT, c.GL_FALSE, stride, @ptrFromInt(@offsetOf(Vertex, "uv")));
        c.glEnableVertexAttribArray(a_color);
        c.glVertexAttribPointer(a_color, 4, c.GL_FLOAT, c.GL_FALSE, stride, @ptrFromInt(@offsetOf(Vertex, "color")));
        c.glEnableVertexAttribArray(a_is_glyph);
        c.glVertexAttribPointer(a_is_glyph, 1, c.GL_FLOAT, c.GL_FALSE, stride, @ptrFromInt(@offsetOf(Vertex, "is_glyph")));
        c.glEnableVertexAttribArray(a_dim);
        c.glVertexAttribPointer(a_dim, 1, c.GL_FLOAT, c.GL_FALSE, stride, @ptrFromInt(@offsetOf(Vertex, "dim")));
        c.glEnableVertexAttribArray(a_italic);
        c.glVertexAttribPointer(a_italic, 1, c.GL_FLOAT, c.GL_FALSE, stride, @ptrFromInt(@offsetOf(Vertex, "italic")));
        c.glEnableVertexAttribArray(a_bold);
        c.glVertexAttribPointer(a_bold, 1, c.GL_FLOAT, c.GL_FALSE, stride, @ptrFromInt(@offsetOf(Vertex, "bold")));
        c.glEnableVertexAttribArray(a_baseline_y);
        c.glVertexAttribPointer(a_baseline_y, 1, c.GL_FLOAT, c.GL_FALSE, stride, @ptrFromInt(@offsetOf(Vertex, "baseline_y")));

        c.glBindVertexArray(0);
    }

    /// Build the vertex buffer for the current screen state.
    /// `focused` adds a thin accent border at the pane edges.
    /// `cells_changed` is the `cells_rebuilt` flag from the cell pass:
    /// when false, no visible row's content moved, so any bidi/DH
    /// overlay row + URL-underline scan would emit identical glyphs.
    /// `rebuilt_rows` is the cell pass's per-row "rebuilt this frame"
    /// mask (slice length == screen.rows). Rows whose entry is true
    /// invalidate the per-row URL/bidi caches; everything else is
    /// reused from the prior frame. An empty slice forces every
    /// row's cache to be rebuilt (used by the smoke binaries).
    pub fn buildVertices(
        self: *GridPass,
        screen: *Screen,
        pool: *const StylePool,
        atlas: *Atlas,
        focused: bool,
        cells_changed: bool,
        rebuilt_rows: []const bool,
    ) !void {
        // Atlas page eviction invalidates every UV/layer baked into
        // the prior vbuf. Detect once per frame; if any layer's
        // generation moved, force a rebuild and snapshot the new
        // generations so we don't keep re-detecting.
        var atlas_evicted = false;
        for (atlas.pages, 0..) |p, i| {
            if (p.generation != self.last_atlas_generations[i]) {
                atlas_evicted = true;
                self.last_atlas_generations[i] = p.generation;
            }
        }

        // Bell flash is time-driven: alpha = 0.4 * (1 - elapsed/200ms).
        // While the fade is running, every frame's overlay differs from
        // the last — never reuse the cached vbuf during this window.
        const bell_animating = blk: {
            if (screen.bell_at_us <= 0) break :blk false;
            const elapsed = std.time.microTimestamp() - screen.bell_at_us;
            break :blk elapsed >= 0 and elapsed < 200_000;
        };

        const snap = self.computeSnapshot(screen, atlas, focused);
        if (self.vbuf_valid and !cells_changed and !atlas_evicted and
            !bell_animating and std.meta.eql(snap, self.last_snapshot))
        {
            return;
        }

        // We're rebuilding — the live VBO contents will diverge from
        // `vbuf.items` until `draw` reuploads.
        self.vbo_uploaded = false;
        self.vbuf.clearRetainingCapacity();

        // Per-row caches: resize to match the current screen and
        // invalidate rows the cell pass rebuilt (or every row when
        // the atlas got evicted — cached glyph/position data is
        // tied to the atlas). Cap capacity to avoid runaway when the
        // grid shrinks and grows repeatedly.
        try self.ensureRowCaches(screen.rows);
        if (atlas_evicted) {
            for (self.row_caches_valid.items) |*v| v.* = false;
        } else if (rebuilt_rows.len == 0) {
            // No rebuilt-row info from the caller (smoke binaries) —
            // safest default is to rescan every row.
            for (self.row_caches_valid.items) |*v| v.* = false;
        } else {
            const n = @min(rebuilt_rows.len, self.row_caches_valid.items.len);
            for (rebuilt_rows[0..n], 0..) |dirty, i| {
                if (dirty) self.row_caches_valid.items[i] = false;
            }
        }

        if (screen.reverse_screen) {
            self.default_fg = screen.default_bg;
            self.default_bg = screen.default_fg;
        } else {
            self.default_fg = screen.default_fg;
            self.default_bg = screen.default_bg;
        }
        self.palette = screen.palette;

        const cw: f32 = @floatFromInt(atlas.cell_w);
        const ch: f32 = @floatFromInt(atlas.cell_h);
        const ascent: f32 = @floatFromInt(atlas.ascent);
        const pad: f32 = self.pad;

        const buf = if (screen.use_alt) screen.alt.? else screen.active;
        const sb_count: u32 = if (screen.use_alt) 0 else screen.scrollbackCount();
        const view_off: u32 = @min(screen.view_offset, sb_count);

        // Bidi rows + DH/DW rows: emit their glyphs here as overlays
        // (the cell pipeline only handles single-scale ASCII rows).
        // The per-row `row_overlay_needed` cache + caches_valid flag
        // means a row that wasn't rebuilt this frame skips the
        // `rowNeedsBidi` cell scan entirely. Mostly-static htop-style
        // content stops paying for the per-cell non-ASCII check on
        // every redraw.
        var row: u16 = 0;
        while (row < screen.rows) : (row += 1) {
            const ln_ptr: *const @TypeOf(buf[0]) = if (row < view_off) blk: {
                const sb_idx = sb_count - view_off + row;
                break :blk screen.scrollbackLine(sb_idx);
            } else &buf[row - view_off];
            const ln = ln_ptr.*;
            const cells = ln.cells[0..screen.cols];

            if (!self.row_caches_valid.items[row]) {
                self.row_overlay_needed.items[row] =
                    ln.scaling != .single or rowNeedsBidi(cells);
            }
            if (!self.row_overlay_needed.items[row]) continue;

            try self.emitOverlayRow(atlas, pool, cells, row, cw, ch, ascent, ln.scaling);
        }

        // Search-result overlay — every match in `screen.search_highlights`
        // gets a translucent yellow rectangle. The active match is
        // bright orange so the user knows which one is current.
        for (screen.search_highlights, 0..) |m, i| {
            const visible_row: i32 = m.row + @as(i32, @intCast(view_off));
            if (visible_row < 0 or visible_row >= @as(i32, @intCast(screen.rows))) continue;
            const x: f32 = pad + @as(f32, @floatFromInt(m.col)) * cw;
            const y: f32 = pad + @as(f32, @floatFromInt(visible_row)) * ch;
            const w: f32 = @as(f32, @floatFromInt(m.len)) * cw;
            const is_active = screen.search_active_idx == @as(i32, @intCast(i));
            const color: [4]f32 = if (is_active)
                .{ 1.0, 0.55, 0.10, 0.55 } // bright orange — current match
            else
                .{ 1.0, 0.85, 0.10, 0.30 }; // dim yellow — other matches
            try self.pushQuad(.{ x, y }, .{ w, ch }, .{ 0, 0 }, .{ 0, 0 }, color, 0.0);
        }

        // Auto-detected URL underlines. Per-row scan results live in
        // `row_url_matches`; rows whose cache is still valid skip the
        // O(cols) `scanRow` call and just re-emit cached matches. The
        // emission itself is a few quads per match — cheap regardless.
        if (self.enable_url_underline) {
            const url_scan = @import("../grid/url_scan.zig");
            var scratch: [16]url_scan.Match = undefined;
            var vrow: u16 = 0;
            while (vrow < screen.rows) : (vrow += 1) {
                if (!self.row_caches_valid.items[vrow]) {
                    const ln_ptr2: *const @TypeOf(buf[0]) = if (vrow < view_off) blk: {
                        const sb_idx = sb_count - view_off + vrow;
                        break :blk screen.scrollbackLine(sb_idx);
                    } else &buf[vrow - view_off];
                    const cells2 = ln_ptr2.cells[0..screen.cols];
                    const n_match = url_scan.scanRow(cells2, &scratch);
                    var slot = &self.row_url_matches.items[vrow];
                    slot.clearRetainingCapacity();
                    if (n_match > 0) {
                        try slot.appendSlice(self.allocator, scratch[0..n_match]);
                    }
                    self.row_url_match_count.items[vrow] = n_match;
                }
                const n_match = self.row_url_match_count.items[vrow];
                if (n_match == 0) continue;
                const y: f32 = pad + @as(f32, @floatFromInt(vrow)) * ch;
                // 1px-equivalent underline near the bottom of the cell.
                const thin: f32 = @max(1.0, ch / 14.0);
                const uy: f32 = y + ch - thin - 1.0;
                const accent: [4]f32 = .{
                    self.default_fg[0],
                    self.default_fg[1],
                    self.default_fg[2],
                    0.85,
                };
                for (self.row_url_matches.items[vrow].items) |m| {
                    const x: f32 = pad + @as(f32, @floatFromInt(m.col_start)) * cw;
                    const w: f32 = @as(f32, @floatFromInt(m.col_end - m.col_start)) * cw;
                    try self.pushQuadDim(.{ x, uy }, .{ w, thin }, .{ 0, 0 }, .{ 0, 0 }, accent, 0.0, 1.0);
                }
            }
        }

        // Selection overlay (translucent). For pure-LTR rows we emit
        // one quad spanning the run; for bidi rows we walk the logical
        // selection cell-by-cell and emit one quad per cell at its
        // visual column (so a logical run that's split across visual
        // segments shows correctly as multiple rectangles).
        if (screen.selection.isActive()) {
            const r_opt = screen.selection.rect();
            if (r_opt) |r| {
                const is_rect = screen.selection.mode == .rectangular;
                const lo_col: i32 = if (is_rect) @min(r.top_col, r.bot_col) else 0;
                const hi_col: i32 = if (is_rect) @max(r.top_col, r.bot_col) else 0;
                var sr = r.top_row;
                while (sr <= r.bot_row) : (sr += 1) {
                    const visible_row: i32 = sr + @as(i32, @intCast(view_off));
                    if (visible_row < 0 or visible_row >= @as(i32, @intCast(screen.rows))) continue;
                    const start_col: i32 = if (is_rect) lo_col
                        else if (sr == r.top_row) r.top_col else 0;
                    const end_col: i32 = if (is_rect) hi_col
                        else if (sr == r.bot_row) r.bot_col else screen.cols;
                    if (end_col <= start_col) continue;
                    const y: f32 = pad + @as(f32, @floatFromInt(visible_row)) * ch;

                    // Quick bidi check on this row.
                    var row_has_bidi = false;
                    if (self.enable_bidi) {
                        const cells = screen.lineCellsAtPub(sr) orelse &.{};
                        for (cells) |cl| if (cl.rune > 0x7F) { row_has_bidi = true; break; };
                    }

                    if (!row_has_bidi) {
                        const x: f32 = pad + @as(f32, @floatFromInt(@max(0, start_col))) * cw;
                        const w: f32 = @as(f32, @floatFromInt(end_col - @max(0, start_col))) * cw;
                        try self.pushQuad(.{ x, y }, .{ w, ch }, .{ 0, 0 }, .{ 0, 0 }, .{ 0.4, 0.55, 0.85, 0.45 }, 0.0);
                    } else {
                        // Per-cell remap. Coalesce visually-adjacent cells
                        // into a single quad to keep vertex count low.
                        var col: i32 = @max(0, start_col);
                        while (col < end_col) : (col += 1) {
                            const visual: u16 = screen.logicalToVisualCol(self.allocator, sr, @intCast(col));
                            const x: f32 = pad + @as(f32, @floatFromInt(visual)) * cw;
                            try self.pushQuad(.{ x, y }, .{ cw, ch }, .{ 0, 0 }, .{ 0, 0 }, .{ 0.4, 0.55, 0.85, 0.45 }, 0.0);
                        }
                    }
                }
            }
        }

        // Bell flash.
        if (screen.bell_at_us > 0) {
            const now = std.time.microTimestamp();
            const elapsed = now - screen.bell_at_us;
            if (elapsed >= 0 and elapsed < 200_000) {
                const t: f32 = @floatCast(@as(f64, @floatFromInt(elapsed)) / 200_000.0);
                const alpha: f32 = 0.4 * (1.0 - t);
                const w: f32 = if (self.canvas_w > 0) self.canvas_w
                    else @as(f32, @floatFromInt(screen.cols)) * cw + 2 * pad;
                const h: f32 = if (self.canvas_h > 0) self.canvas_h
                    else @as(f32, @floatFromInt(screen.rows)) * ch + 2 * pad;
                try self.pushQuad(.{ 0, 0 }, .{ w, h }, .{ 0, 0 }, .{ 0, 0 }, .{ 1.0, 1.0, 1.0, alpha }, 0.0);
            }
        }

        // IME preedit overlay.
        if (view_off == 0 and screen.preedit_text != null) {
            const pre = screen.preedit_text.?;
            var col_off: u16 = 0;
            var idx: usize = 0;
            while (idx < pre.len) {
                const seq_len = std.unicode.utf8ByteSequenceLength(pre[idx]) catch break;
                if (idx + seq_len > pre.len) break;
                const cp = std.unicode.utf8Decode(pre[idx .. idx + seq_len]) catch {
                    idx += seq_len;
                    continue;
                };
                const target_col: u32 = @as(u32, screen.col) + col_off;
                if (target_col >= screen.cols) break;
                const x: f32 = pad + @as(f32, @floatFromInt(target_col)) * cw;
                const y: f32 = pad + @as(f32, @floatFromInt(screen.row)) * ch;
                const cell_w_count: u16 = if (Screen.isWide(cp)) 2 else 1;
                // IME preedit bg + glyph + underline all dim with cell
                // content so the unfocused pane stays consistent.
                try self.pushQuadDim(
                    .{ x, y },
                    .{ cw * @as(f32, @floatFromInt(cell_w_count)), ch },
                    .{ 0, 0 },
                    .{ 0, 0 },
                    .{ 0.05, 0.05, 0.10, 0.85 },
                    0.0,
                    2.0,
                );
                const g = atlas.lookupOrLoad(cp) catch {
                    idx += seq_len;
                    col_off += cell_w_count;
                    continue;
                };
                if (g.w > 0 and g.h > 0) {
                    const gx: f32 = x + @as(f32, @floatFromInt(g.bearing_x));
                    const gy: f32 = y + ascent - @as(f32, @floatFromInt(g.bearing_y));
                    const gw: f32 = @floatFromInt(g.w);
                    const gh: f32 = @floatFromInt(g.h);
                    // IME preedit text is treated as cell content — dim
                    // it the same way as bidi/DW glyphs when unfocused.
                    try self.pushGlyphQuadDim(.{ gx, gy }, .{ gw, gh }, .{ g.u0, g.v0 }, .{ g.u1, g.v1 }, @floatFromInt(g.layer), self.default_fg, 1.0);
                }
                try self.pushQuadDim(
                    .{ x, y + ch - 2 },
                    .{ cw * @as(f32, @floatFromInt(cell_w_count)), 2 },
                    .{ 0, 0 },
                    .{ 0, 0 },
                    .{ 0.4, 0.55, 0.85, 0.95 },
                    0.0,
                    1.0,
                );
                col_off += cell_w_count;
                idx += seq_len;
            }
        }

        // Cursor.
        const blinking = switch (screen.cursor_shape) {
            .block_blink, .underline_blink, .bar_blink => true,
            else => false,
        };
        const blink_visible = !blinking or screen.cursor_blink_on;
        if (view_off == 0 and screen.cursor_visible and blink_visible and
            screen.row < screen.rows and screen.col < screen.cols)
        {
            const visual_col: u16 = blk: {
                if (!self.enable_bidi) break :blk screen.col;
                const row_cells = if (!screen.use_alt) screen.active[screen.row].cells else screen.alt.?[screen.row].cells;
                // Skip the bidi resolution + heap allocs on rows that
                // can't reorder visually. CJK / emoji / box-drawing
                // are non-ASCII but logical == visual.
                if (!@import("cell_pass.zig").rowNeedsBidiOrComplexShape(row_cells)) break :blk screen.col;
                const bidi = @import("../grid/bidi.zig");
                const sc = self.bidiScratch(row_cells.len) catch break :blk screen.col;
                for (row_cells, 0..) |rc, i| {
                    sc.cps[i] = if (rc.rune == 0) ' ' else rc.rune;
                    sc.idx[i] = i;
                }
                _ = bidi.lineLevels(sc.cps, sc.lvls, .auto);
                bidi.levelsToVisualOrder(sc.lvls, sc.idx);
                for (sc.idx, 0..) |logical, visual| if (logical == screen.col) break :blk @intCast(visual);
                break :blk screen.col;
            };
            const cx: f32 = pad + @as(f32, @floatFromInt(visual_col)) * cw;
            const cy: f32 = pad + @as(f32, @floatFromInt(screen.row)) * ch;
            const fg = if (screen.cursor_color[3] > 0) screen.cursor_color else self.default_fg;
            const block_alpha: f32 = 0.85;
            const at = if (!screen.use_alt) screen.active[screen.row].cells[screen.col] else screen.alt.?[screen.row].cells[screen.col];
            const cur_cw: f32 = if (at.flags & 0b0000_0001 != 0) cw * 2.0 else cw;

            if (focused) {
                switch (screen.cursor_shape) {
                    .block_blink, .block_steady => {
                        try self.pushQuad(.{ cx, cy }, .{ cur_cw, ch }, .{ 0, 0 }, .{ 0, 0 }, .{ fg[0], fg[1], fg[2], block_alpha }, 0.0);
                    },
                    .underline_blink, .underline_steady => {
                        const h: f32 = @max(2.0, ch / 8.0);
                        try self.pushQuad(.{ cx, cy + ch - h }, .{ cur_cw, h }, .{ 0, 0 }, .{ 0, 0 }, .{ fg[0], fg[1], fg[2], 0.95 }, 0.0);
                    },
                    .bar_blink, .bar_steady => {
                        const w: f32 = @max(2.0, cw / 6.0);
                        try self.pushQuad(.{ cx, cy }, .{ w, ch }, .{ 0, 0 }, .{ 0, 0 }, .{ fg[0], fg[1], fg[2], 0.95 }, 0.0);
                    },
                }
            } else {
                const t: f32 = 1.0;
                const a: f32 = 0.55;
                try self.pushQuad(.{ cx, cy }, .{ cur_cw, t }, .{ 0, 0 }, .{ 0, 0 }, .{ fg[0], fg[1], fg[2], a }, 0.0);
                try self.pushQuad(.{ cx, cy + ch - t }, .{ cur_cw, t }, .{ 0, 0 }, .{ 0, 0 }, .{ fg[0], fg[1], fg[2], a }, 0.0);
                try self.pushQuad(.{ cx, cy }, .{ t, ch }, .{ 0, 0 }, .{ 0, 0 }, .{ fg[0], fg[1], fg[2], a }, 0.0);
                try self.pushQuad(.{ cx + cur_cw - t, cy }, .{ t, ch }, .{ 0, 0 }, .{ 0, 0 }, .{ fg[0], fg[1], fg[2], a }, 0.0);
            }
        }

        const w_full: f32 = if (self.canvas_w > 0) self.canvas_w
            else @as(f32, @floatFromInt(screen.cols)) * cw + 2 * pad;
        const h_full: f32 = if (self.canvas_h > 0) self.canvas_h
            else @as(f32, @floatFromInt(screen.rows)) * ch + 2 * pad;
        if (focused) {
            const border: f32 = 2.0;
            const accent = .{ 0.40, 0.55, 0.85, 0.75 };
            try self.pushQuad(.{ 0, 0 }, .{ w_full, border }, .{ 0, 0 }, .{ 0, 0 }, accent, 0.0);
            try self.pushQuad(.{ 0, h_full - border }, .{ w_full, border }, .{ 0, 0 }, .{ 0, 0 }, accent, 0.0);
            try self.pushQuad(.{ 0, 0 }, .{ border, h_full }, .{ 0, 0 }, .{ 0, 0 }, accent, 0.0);
            try self.pushQuad(.{ w_full - border, 0 }, .{ border, h_full }, .{ 0, 0 }, .{ 0, 0 }, accent, 0.0);
        }

        if (sb_count > 0) {
            const total_lines: u32 = sb_count + screen.rows;
            const view_top: u32 = sb_count - view_off;
            const visible: u32 = screen.rows;
            const track_w: f32 = 4.0;
            const track_x: f32 = w_full - track_w;
            const track_h: f32 = h_full;
            const track_color = .{ 0.5, 0.5, 0.5, 0.18 };
            try self.pushQuad(.{ track_x, 0 }, .{ track_w, track_h }, .{ 0, 0 }, .{ 0, 0 }, track_color, 0.0);
            const thumb_top_f: f32 = @as(f32, @floatFromInt(view_top)) / @as(f32, @floatFromInt(total_lines));
            const thumb_h_f: f32 = @as(f32, @floatFromInt(visible)) / @as(f32, @floatFromInt(total_lines));
            const thumb_y: f32 = thumb_top_f * track_h;
            const thumb_h: f32 = @max(8.0, thumb_h_f * track_h);
            const thumb_color: [4]f32 = if (view_off == 0)
                .{ 0.5, 0.5, 0.5, 0.30 }
            else
                .{ 0.40, 0.55, 0.85, 0.70 };
            try self.pushQuad(.{ track_x, thumb_y }, .{ track_w, thumb_h }, .{ 0, 0 }, .{ 0, 0 }, thumb_color, 0.0);
        }

        // Per-row caches are now consistent with what we emitted —
        // mark them all valid so the next frame can reuse any row
        // the cell pass doesn't touch.
        for (self.row_caches_valid.items) |*v| v.* = true;
        self.last_snapshot = snap;
        self.vbuf_valid = true;
    }

    fn ensureRowCaches(self: *GridPass, rows: u16) !void {
        const old_len = self.row_url_matches.items.len;
        if (rows == old_len) return;
        if (rows < old_len) {
            // Free the per-row Match lists we're dropping.
            for (self.row_url_matches.items[rows..]) |*lst| lst.deinit(self.allocator);
        }
        try self.row_url_matches.resize(self.allocator, rows);
        try self.row_url_match_count.resize(self.allocator, rows);
        try self.row_overlay_needed.resize(self.allocator, rows);
        try self.row_caches_valid.resize(self.allocator, rows);
        if (rows > old_len) {
            for (self.row_url_matches.items[old_len..]) |*lst| lst.* = .{};
            for (self.row_url_match_count.items[old_len..]) |*c0| c0.* = 0;
            for (self.row_overlay_needed.items[old_len..]) |*c0| c0.* = false;
        }
        // Any growth or shrink invalidates the row->index mapping.
        for (self.row_caches_valid.items) |*v| v.* = false;
    }

    fn computeSnapshot(self: *const GridPass, screen: *const Screen, atlas: *const Atlas, focused: bool) Snapshot {
        const sb_count: u32 = if (screen.use_alt) 0 else screen.scrollbackCount();
        var s: Snapshot = .{
            .canvas_w = self.canvas_w,
            .canvas_h = self.canvas_h,
            .pad = self.pad,
            .focused = focused,

            .use_alt = screen.use_alt,
            .view_off = @min(screen.view_offset, sb_count),
            .sb_count = sb_count,

            .rows = screen.rows,
            .cols = screen.cols,
            .cell_w = atlas.cell_w,
            .cell_h = atlas.cell_h,
            .ascent = atlas.ascent,

            .reverse_screen = screen.reverse_screen,
            .default_fg = screen.default_fg,
            .default_bg = screen.default_bg,
            .palette = screen.palette,

            .cursor_visible = screen.cursor_visible,
            .cursor_blink_on = screen.cursor_blink_on,
            .cursor_shape = @intFromEnum(screen.cursor_shape),
            .cursor_row = screen.row,
            .cursor_col = screen.col,
            .cursor_color = screen.cursor_color,

            .selection_mode = @intFromEnum(screen.selection.mode),
            .selection_anchor_row = screen.selection.anchor_row,
            .selection_anchor_col = screen.selection.anchor_col,
            .selection_end_row = screen.selection.end_row,
            .selection_end_col = screen.selection.end_col,

            .search_count = @intCast(screen.search_highlights.len),
            .search_active_idx = screen.search_active_idx,
            .search_hash = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(screen.search_highlights)),

            .bell_at_us = screen.bell_at_us,

            .dim_fg = self.dim_fg,
            .dim_bg = self.dim_bg,
            .enable_url_underline = self.enable_url_underline,
            .enable_bidi = self.enable_bidi,
            .enable_ligatures = self.enable_ligatures,
            .allow_bold = self.allow_bold,
            .bold_is_bright = self.bold_is_bright,
        };
        if (screen.preedit_text) |t| {
            s.preedit_hash = std.hash.Wyhash.hash(0, t);
            s.preedit_len = t.len;
        }
        return s;
    }

    /// Forwarded from CellPass — see its definition. Only rows with
    /// RTL or complex-script content go through the overlay path.
    /// CJK / emoji / box-drawing / general non-ASCII symbols stay
    /// in CellPass.
    fn rowNeedsBidi(cells: []const Cell) bool {
        return @import("cell_pass.zig").rowNeedsBidiOrComplexShape(cells);
    }

    /// Emit glyphs (and per-cell bg) for a row that needs special
    /// handling: bidi, DW/DH scaling. The cell pipeline doesn't run on
    /// these rows, so we have to draw bg + fg here.
    fn emitOverlayRow(
        self: *GridPass,
        atlas: *Atlas,
        pool: *const StylePool,
        cells: []const Cell,
        row: u16,
        cw: f32,
        ch: f32,
        ascent: f32,
        scaling: @import("../grid/line.zig").Scaling,
    ) !void {
        const pad = self.pad;
        const x_scale: f32 = if (scaling == .single) 1.0 else 2.0;
        const y_scale: f32 = if (scaling == .dhl_top or scaling == .dhl_bot) 2.0 else 1.0;
        const y_origin_shift: f32 = if (scaling == .dhl_bot) -ch else 0.0;
        const y: f32 = pad + @as(f32, @floatFromInt(row)) * ch;

        // Backgrounds (always emit non-default; default bg falls through
        // to clearcolor). Reverse video swaps fg/bg of THIS cell;
        // we resolve fg first then swap below.
        for (cells, 0..) |cell, col| {
            const style = pool.get(cell.style_ref);
            const has_explicit_bg = style.bg != .default or style.attrs.reverse;
            if (!has_explicit_bg) continue;
            // For reverse, draw the cell's fg as the bg.
            const bg = if (style.attrs.reverse)
                self.resolveColor(style.fg, true)
            else
                self.resolveColor(style.bg, false);
            const x: f32 = pad + @as(f32, @floatFromInt(col)) * cw * x_scale;
            // Cell content bg — apply bg-dim when unfocused.
            try self.pushQuadDim(.{ x, y }, .{ cw * x_scale, ch }, .{ 0, 0 }, .{ 0, 0 }, bg, 0.0, 2.0);
        }

        // Glyphs — bidi-reorder runs to visual order before shaping.
        if (rowNeedsBidi(cells) and self.enable_bidi) {
            try self.emitBidiGlyphs(atlas, pool, cells, row, cw, ch, ascent, scaling);
        } else {
            try self.emitLogicalGlyphs(atlas, pool, cells, row, cw, ch, ascent, scaling, x_scale, y_scale, y_origin_shift);
        }
    }

    fn emitLogicalGlyphs(
        self: *GridPass,
        atlas: *Atlas,
        pool: *const StylePool,
        cells: []const Cell,
        row: u16,
        cw: f32,
        ch: f32,
        ascent: f32,
        _: @import("../grid/line.zig").Scaling,
        x_scale: f32,
        y_scale: f32,
        y_origin_shift: f32,
    ) !void {
        const pad = self.pad;
        const y: f32 = pad + @as(f32, @floatFromInt(row)) * ch;

        var col: u16 = 0;
        const cols: u16 = @intCast(cells.len);
        while (col < cols) {
            const cell = cells[col];
            if ((cell.flags & 0b0000_0010) != 0 or cell.rune == 0 or cell.rune == ' ') {
                col += 1;
                continue;
            }
            const style = pool.get(cell.style_ref);
            // Reverse: draw fg using bg color (and bg using fg).
            // Bold lifts palette 0..7 → 8..15 (xterm convention) when
            // allow_bold && bold_is_bright.
            var fg_color = if (style.attrs.reverse) style.bg else style.fg;
            if (style.attrs.bold and self.allow_bold and self.bold_is_bright) {
                if (fg_color == .palette and fg_color.palette < 8) {
                    fg_color = .{ .palette = fg_color.palette + 8 };
                }
            }
            var fg = self.resolveColor(fg_color, !style.attrs.reverse);
            if (style.attrs.dim) {
                fg[0] *= 0.65;
                fg[1] *= 0.65;
                fg[2] *= 0.65;
            }
            const x: f32 = pad + @as(f32, @floatFromInt(col)) * cw * x_scale;
            const g = atlas.lookupOrLoad(cell.rune) catch {
                col += 1;
                continue;
            };
            if (g.w > 0 and g.h > 0) {
                const gx: f32 = x + @as(f32, @floatFromInt(g.bearing_x)) * x_scale;
                const gy: f32 = y + ascent - @as(f32, @floatFromInt(g.bearing_y)) * y_scale + y_origin_shift;
                const gw: f32 = @as(f32, @floatFromInt(g.w)) * x_scale;
                const gh: f32 = @as(f32, @floatFromInt(g.h)) * y_scale;
                // Italic/bold only on single-scale rows. DH/DW rows
                // skip — shear pivot math gets weird with y_scale != 1.
                const is_single = (x_scale == 1.0 and y_scale == 1.0);
                const italic_f: f32 = if (is_single and style.attrs.italic) 1.0 else 0.0;
                const bold_f: f32 = if (is_single and style.attrs.bold and self.allow_bold) 1.0 else 0.0;
                const baseline_y: f32 = y + ch;
                try self.pushGlyphQuadStyled(.{ gx, gy }, .{ gw, gh }, .{ g.u0, g.v0 }, .{ g.u1, g.v1 }, @floatFromInt(g.layer), fg, 1.0, italic_f, bold_f, baseline_y);
            }
            col += 1;
        }
    }

    fn emitBidiGlyphs(
        self: *GridPass,
        atlas: *Atlas,
        pool: *const StylePool,
        cells: []const Cell,
        row: u16,
        cw: f32,
        ch: f32,
        ascent: f32,
        scaling: @import("../grid/line.zig").Scaling,
    ) !void {
        const bidi = @import("../grid/bidi.zig");
        const pad = self.pad;
        const x_scale: f32 = if (scaling == .single) 1.0 else 2.0;
        const y_scale: f32 = if (scaling == .dhl_top or scaling == .dhl_bot) 2.0 else 1.0;
        const y_origin_shift: f32 = if (scaling == .dhl_bot) -ch else 0.0;
        const y: f32 = pad + @as(f32, @floatFromInt(row)) * ch;

        const sc = self.bidiScratch(cells.len) catch return;
        const levels = sc.lvls;
        const indices = sc.idx;
        const cps = sc.cps;
        for (cells, 0..) |cell, i| {
            cps[i] = if (cell.rune == 0) ' ' else cell.rune;
            indices[i] = i;
        }
        _ = bidi.lineLevels(cps, levels, .auto);
        bidi.levelsToVisualOrder(levels, indices);

        for (indices, 0..) |logical, visual| {
            const cell = cells[logical];
            if ((cell.flags & 0b0000_0010) != 0 or cell.rune == 0 or cell.rune == ' ') continue;
            const style = pool.get(cell.style_ref);
            var fg_color = if (style.attrs.reverse) style.bg else style.fg;
            if (style.attrs.bold and self.allow_bold and self.bold_is_bright) {
                if (fg_color == .palette and fg_color.palette < 8) {
                    fg_color = .{ .palette = fg_color.palette + 8 };
                }
            }
            var fg = self.resolveColor(fg_color, !style.attrs.reverse);
            if (style.attrs.dim) {
                fg[0] *= 0.65;
                fg[1] *= 0.65;
                fg[2] *= 0.65;
            }
            const x: f32 = pad + @as(f32, @floatFromInt(visual)) * cw * x_scale;
            const g = atlas.lookupOrLoad(cell.rune) catch continue;
            if (g.w == 0 or g.h == 0) continue;
            const gx: f32 = x + @as(f32, @floatFromInt(g.bearing_x)) * x_scale;
            const gy: f32 = y + ascent - @as(f32, @floatFromInt(g.bearing_y)) * y_scale + y_origin_shift;
            const gw: f32 = @as(f32, @floatFromInt(g.w)) * x_scale;
            const gh: f32 = @as(f32, @floatFromInt(g.h)) * y_scale;
            const is_single = (x_scale == 1.0 and y_scale == 1.0);
            const italic_f: f32 = if (is_single and style.attrs.italic) 1.0 else 0.0;
            const bold_f: f32 = if (is_single and style.attrs.bold and self.allow_bold) 1.0 else 0.0;
            const baseline_y: f32 = y + ch;
            try self.pushGlyphQuadStyled(.{ gx, gy }, .{ gw, gh }, .{ g.u0, g.v0 }, .{ g.u1, g.v1 }, @floatFromInt(g.layer), fg, 1.0, italic_f, bold_f, baseline_y);
        }
    }

    fn pushQuad(
        self: *GridPass,
        origin: [2]f32,
        size: [2]f32,
        uv0: [2]f32,
        uv1: [2]f32,
        color: [4]f32,
        is_glyph: f32,
    ) !void {
        return self.pushQuadDim(origin, size, uv0, uv1, color, is_glyph, 0.0);
    }

    fn pushQuadDim(
        self: *GridPass,
        origin: [2]f32,
        size: [2]f32,
        uv0: [2]f32,
        uv1: [2]f32,
        color: [4]f32,
        is_glyph: f32,
        dim: f32,
    ) !void {
        const px0 = origin[0];
        const py0 = origin[1];
        const px1 = origin[0] + size[0];
        const py1 = origin[1] + size[1];
        const verts = [_]Vertex{
            .{ .pos = .{ px0, py0 }, .uv = .{ uv0[0], uv0[1], 0 }, .color = color, .is_glyph = is_glyph, .dim = dim },
            .{ .pos = .{ px1, py0 }, .uv = .{ uv1[0], uv0[1], 0 }, .color = color, .is_glyph = is_glyph, .dim = dim },
            .{ .pos = .{ px0, py1 }, .uv = .{ uv0[0], uv1[1], 0 }, .color = color, .is_glyph = is_glyph, .dim = dim },
            .{ .pos = .{ px1, py0 }, .uv = .{ uv1[0], uv0[1], 0 }, .color = color, .is_glyph = is_glyph, .dim = dim },
            .{ .pos = .{ px1, py1 }, .uv = .{ uv1[0], uv1[1], 0 }, .color = color, .is_glyph = is_glyph, .dim = dim },
            .{ .pos = .{ px0, py1 }, .uv = .{ uv0[0], uv1[1], 0 }, .color = color, .is_glyph = is_glyph, .dim = dim },
        };
        try self.vbuf.appendSlice(self.allocator, &verts);
    }

    fn pushGlyphQuad(
        self: *GridPass,
        origin: [2]f32,
        size: [2]f32,
        uv0: [2]f32,
        uv1: [2]f32,
        layer: f32,
        color: [4]f32,
    ) !void {
        return self.pushGlyphQuadDim(origin, size, uv0, uv1, layer, color, 0.0);
    }

    fn pushGlyphQuadDim(
        self: *GridPass,
        origin: [2]f32,
        size: [2]f32,
        uv0: [2]f32,
        uv1: [2]f32,
        layer: f32,
        color: [4]f32,
        dim: f32,
    ) !void {
        return self.pushGlyphQuadStyled(origin, size, uv0, uv1, layer, color, dim, 0.0, 0.0, 0.0);
    }

    /// Glyph quad with italic shear + faux-bold support. Used by the
    /// bidi/logical overlay paths so SGR 1/3 attributes survive the
    /// trip through grid_pass — the cell_pass fast path already does
    /// the same. `baseline_y` is the cell's bottom edge in pixels;
    /// the shader pivots the italic shear around it.
    fn pushGlyphQuadStyled(
        self: *GridPass,
        origin: [2]f32,
        size: [2]f32,
        uv0: [2]f32,
        uv1: [2]f32,
        layer: f32,
        color: [4]f32,
        dim: f32,
        italic: f32,
        bold: f32,
        baseline_y: f32,
    ) !void {
        const px0 = origin[0];
        const py0 = origin[1];
        const px1 = origin[0] + size[0];
        const py1 = origin[1] + size[1];
        const v0 = Vertex{ .pos = .{ px0, py0 }, .uv = .{ uv0[0], uv0[1], layer }, .color = color, .is_glyph = 1.0, .dim = dim, .italic = italic, .bold = bold, .baseline_y = baseline_y };
        const v1 = Vertex{ .pos = .{ px1, py0 }, .uv = .{ uv1[0], uv0[1], layer }, .color = color, .is_glyph = 1.0, .dim = dim, .italic = italic, .bold = bold, .baseline_y = baseline_y };
        const v2 = Vertex{ .pos = .{ px0, py1 }, .uv = .{ uv0[0], uv1[1], layer }, .color = color, .is_glyph = 1.0, .dim = dim, .italic = italic, .bold = bold, .baseline_y = baseline_y };
        const v3 = Vertex{ .pos = .{ px1, py1 }, .uv = .{ uv1[0], uv1[1], layer }, .color = color, .is_glyph = 1.0, .dim = dim, .italic = italic, .bold = bold, .baseline_y = baseline_y };
        const verts = [_]Vertex{ v0, v1, v2, v1, v3, v2 };
        try self.vbuf.appendSlice(self.allocator, &verts);
    }

    /// Resolve a Color → RGBA without considering reverse video. The
    /// caller swaps fg/bg explicitly (for cells with explicit colors
    /// reverse should still flip them).
    fn resolveColor(self: *const GridPass, color: Color, is_fg: bool) [4]f32 {
        return style_util.colorToRGBA(color, is_fg, self.default_fg, self.default_bg, &self.palette);
    }

    fn colorToVec(self: *const GridPass, color: Color, is_fg: bool, reverse: bool) [4]f32 {
        return style_util.colorToVec(color, is_fg, reverse, self.default_fg, self.default_bg, &self.palette);
    }

    pub fn draw(self: *GridPass, atlas: *Atlas, viewport_w: i32, viewport_h: i32) void {
        if (self.vbuf.items.len == 0) return;
        c.glUseProgram(self.program);
        c.glUniform2f(self.u_screen_px, @floatFromInt(viewport_w), @floatFromInt(viewport_h));
        c.glUniform1f(self.u_dim_fg, self.dim_fg);
        c.glUniform1f(self.u_dim_bg, self.dim_bg);
        c.glActiveTexture(c.GL_TEXTURE0);
        c.glBindTexture(c.GL_TEXTURE_2D_ARRAY, atlas.gl_tex);
        c.glUniform1i(self.u_atlas, 0);

        c.glBindVertexArray(self.vao);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbo);
        if (!self.vbo_uploaded) {
            const bytes: c.GLsizeiptr = @intCast(self.vbuf.items.len * @sizeOf(Vertex));
            c.glBufferData(c.GL_ARRAY_BUFFER, bytes, self.vbuf.items.ptr, c.GL_DYNAMIC_DRAW);
            self.vbo_uploaded = true;
        }

        c.glEnable(c.GL_BLEND);
        c.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);
        c.glDrawArrays(c.GL_TRIANGLES, 0, @intCast(self.vbuf.items.len));
        c.glDisable(c.GL_BLEND);
        c.glBindVertexArray(0);
    }
};

const palette_256 = @import("../grid/palette.zig").default_256;
