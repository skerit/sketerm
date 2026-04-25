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
const Atlas = @import("atlas.zig").Atlas;
const Screen = @import("../grid/screen.zig").Screen;
const StylePool = @import("../grid/style_pool.zig").Pool;
const Color = @import("../grid/style_pool.zig").Color;
const Cell = @import("../grid/cell.zig").Cell;

const VERT_SRC =
    \\#version 300 es
    \\in vec2 a_pos;
    \\in vec3 a_uv; // (u, v, layer)
    \\in vec4 a_color;
    \\in float a_is_glyph;
    \\
    \\uniform vec2 u_screen_px;
    \\
    \\out vec3 v_uv;
    \\out vec4 v_color;
    \\out float v_is_glyph;
    \\
    \\void main() {
    \\    vec2 ndc = (a_pos / u_screen_px) * 2.0 - 1.0;
    \\    ndc.y = -ndc.y;
    \\    gl_Position = vec4(ndc, 0.0, 1.0);
    \\    v_uv = a_uv;
    \\    v_color = a_color;
    \\    v_is_glyph = a_is_glyph;
    \\}
;

const FRAG_SRC =
    \\#version 300 es
    \\precision mediump float;
    \\precision mediump sampler2DArray;
    \\
    \\in vec3 v_uv;
    \\in vec4 v_color;
    \\in float v_is_glyph;
    \\
    \\uniform sampler2DArray u_atlas;
    \\
    \\out vec4 o_frag;
    \\
    \\void main() {
    \\    if (v_is_glyph > 0.5) {
    \\        float a = texture(u_atlas, v_uv).r;
    \\        o_frag = vec4(v_color.rgb, a * v_color.a);
    \\    } else {
    \\        o_frag = v_color;
    \\    }
    \\}
;

const Vertex = extern struct {
    pos: [2]f32,
    uv: [3]f32,
    color: [4]f32,
    is_glyph: f32,
};

pub const GridPass = struct {
    program: c_uint = 0,
    vao: c_uint = 0,
    vbo: c_uint = 0,
    u_screen_px: c_int = -1,
    u_atlas: c_int = -1,
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
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) GridPass {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *GridPass) void {
        self.vbuf.deinit(self.allocator);
    }

    pub fn forgetGL(self: *GridPass) void {
        self.program = 0;
        self.vao = 0;
        self.vbo = 0;
        self.u_screen_px = -1;
        self.u_atlas = -1;
    }

    pub fn realize(self: *GridPass) !void {
        if (self.program != 0) return;
        self.program = try gl.buildProgram(VERT_SRC, FRAG_SRC);
        self.u_screen_px = c.glGetUniformLocation(self.program, "u_screen_px");
        self.u_atlas = c.glGetUniformLocation(self.program, "u_atlas");

        c.glGenVertexArrays(1, &self.vao);
        c.glBindVertexArray(self.vao);
        c.glGenBuffers(1, &self.vbo);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbo);

        const stride: c_int = @sizeOf(Vertex);
        const a_pos: c_uint = @intCast(c.glGetAttribLocation(self.program, "a_pos"));
        const a_uv: c_uint = @intCast(c.glGetAttribLocation(self.program, "a_uv"));
        const a_color: c_uint = @intCast(c.glGetAttribLocation(self.program, "a_color"));
        const a_is_glyph: c_uint = @intCast(c.glGetAttribLocation(self.program, "a_is_glyph"));

        c.glEnableVertexAttribArray(a_pos);
        c.glVertexAttribPointer(a_pos, 2, c.GL_FLOAT, c.GL_FALSE, stride, @ptrFromInt(@offsetOf(Vertex, "pos")));
        c.glEnableVertexAttribArray(a_uv);
        c.glVertexAttribPointer(a_uv, 3, c.GL_FLOAT, c.GL_FALSE, stride, @ptrFromInt(@offsetOf(Vertex, "uv")));
        c.glEnableVertexAttribArray(a_color);
        c.glVertexAttribPointer(a_color, 4, c.GL_FLOAT, c.GL_FALSE, stride, @ptrFromInt(@offsetOf(Vertex, "color")));
        c.glEnableVertexAttribArray(a_is_glyph);
        c.glVertexAttribPointer(a_is_glyph, 1, c.GL_FLOAT, c.GL_FALSE, stride, @ptrFromInt(@offsetOf(Vertex, "is_glyph")));

        c.glBindVertexArray(0);
    }

    /// Build the vertex buffer for the current screen state.
    /// `focused` adds a thin accent border at the pane edges.
    pub fn buildVertices(
        self: *GridPass,
        screen: *Screen,
        pool: *const StylePool,
        atlas: *Atlas,
        focused: bool,
    ) !void {
        self.vbuf.clearRetainingCapacity();

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
        var row: u16 = 0;
        while (row < screen.rows) : (row += 1) {
            const ln_ptr: *const @TypeOf(buf[0]) = if (row < view_off) blk: {
                const sb_idx = sb_count - view_off + row;
                break :blk screen.scrollbackLine(sb_idx);
            } else &buf[row - view_off];
            const ln = ln_ptr.*;
            const cells = ln.cells[0..screen.cols];

            const need_overlay = ln.scaling != .single or rowNeedsBidi(cells);
            if (!need_overlay) continue;

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
                try self.pushQuad(
                    .{ x, y },
                    .{ cw * @as(f32, @floatFromInt(cell_w_count)), ch },
                    .{ 0, 0 },
                    .{ 0, 0 },
                    .{ 0.05, 0.05, 0.10, 0.85 },
                    0.0,
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
                    try self.pushGlyphQuad(.{ gx, gy }, .{ gw, gh }, .{ g.u0, g.v0 }, .{ g.u1, g.v1 }, @floatFromInt(g.layer), self.default_fg);
                }
                try self.pushQuad(
                    .{ x, y + ch - 2 },
                    .{ cw * @as(f32, @floatFromInt(cell_w_count)), 2 },
                    .{ 0, 0 },
                    .{ 0, 0 },
                    .{ 0.4, 0.55, 0.85, 0.95 },
                    0.0,
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
                var any_non_ascii = false;
                for (row_cells) |rc| if (rc.rune > 0x7F) { any_non_ascii = true; break; };
                if (!any_non_ascii) break :blk screen.col;
                const bidi = @import("../grid/bidi.zig");
                const cps = self.allocator.alloc(u32, row_cells.len) catch break :blk screen.col;
                defer self.allocator.free(cps);
                const lvls = self.allocator.alloc(u8, row_cells.len) catch break :blk screen.col;
                defer self.allocator.free(lvls);
                const idx2 = self.allocator.alloc(usize, row_cells.len) catch break :blk screen.col;
                defer self.allocator.free(idx2);
                for (row_cells, 0..) |rc, i| {
                    cps[i] = if (rc.rune == 0) ' ' else rc.rune;
                    idx2[i] = i;
                }
                _ = bidi.lineLevels(cps, lvls, .auto);
                bidi.levelsToVisualOrder(lvls, idx2);
                for (idx2, 0..) |logical, visual| if (logical == screen.col) break :blk @intCast(visual);
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
            try self.pushQuad(.{ x, y }, .{ cw * x_scale, ch }, .{ 0, 0 }, .{ 0, 0 }, bg, 0.0);
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
            // Bold lifts palette 0..7 → 8..15.
            var fg_color = if (style.attrs.reverse) style.bg else style.fg;
            if (style.attrs.bold) {
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
                try self.pushGlyphQuad(.{ gx, gy }, .{ gw, gh }, .{ g.u0, g.v0 }, .{ g.u1, g.v1 }, @floatFromInt(g.layer), fg);
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

        const levels = self.allocator.alloc(u8, cells.len) catch return;
        defer self.allocator.free(levels);
        const indices = self.allocator.alloc(usize, cells.len) catch return;
        defer self.allocator.free(indices);
        const cps = self.allocator.alloc(u32, cells.len) catch return;
        defer self.allocator.free(cps);
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
            if (style.attrs.bold) {
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
            try self.pushGlyphQuad(.{ gx, gy }, .{ gw, gh }, .{ g.u0, g.v0 }, .{ g.u1, g.v1 }, @floatFromInt(g.layer), fg);
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
        const px0 = origin[0];
        const py0 = origin[1];
        const px1 = origin[0] + size[0];
        const py1 = origin[1] + size[1];
        const verts = [_]Vertex{
            .{ .pos = .{ px0, py0 }, .uv = .{ uv0[0], uv0[1], 0 }, .color = color, .is_glyph = is_glyph },
            .{ .pos = .{ px1, py0 }, .uv = .{ uv1[0], uv0[1], 0 }, .color = color, .is_glyph = is_glyph },
            .{ .pos = .{ px0, py1 }, .uv = .{ uv0[0], uv1[1], 0 }, .color = color, .is_glyph = is_glyph },
            .{ .pos = .{ px1, py0 }, .uv = .{ uv1[0], uv0[1], 0 }, .color = color, .is_glyph = is_glyph },
            .{ .pos = .{ px1, py1 }, .uv = .{ uv1[0], uv1[1], 0 }, .color = color, .is_glyph = is_glyph },
            .{ .pos = .{ px0, py1 }, .uv = .{ uv0[0], uv1[1], 0 }, .color = color, .is_glyph = is_glyph },
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
        const px0 = origin[0];
        const py0 = origin[1];
        const px1 = origin[0] + size[0];
        const py1 = origin[1] + size[1];
        const verts = [_]Vertex{
            .{ .pos = .{ px0, py0 }, .uv = .{ uv0[0], uv0[1], layer }, .color = color, .is_glyph = 1.0 },
            .{ .pos = .{ px1, py0 }, .uv = .{ uv1[0], uv0[1], layer }, .color = color, .is_glyph = 1.0 },
            .{ .pos = .{ px0, py1 }, .uv = .{ uv0[0], uv1[1], layer }, .color = color, .is_glyph = 1.0 },
            .{ .pos = .{ px1, py0 }, .uv = .{ uv1[0], uv0[1], layer }, .color = color, .is_glyph = 1.0 },
            .{ .pos = .{ px1, py1 }, .uv = .{ uv1[0], uv1[1], layer }, .color = color, .is_glyph = 1.0 },
            .{ .pos = .{ px0, py1 }, .uv = .{ uv0[0], uv1[1], layer }, .color = color, .is_glyph = 1.0 },
        };
        try self.vbuf.appendSlice(self.allocator, &verts);
    }

    /// Resolve a Color → RGBA without considering reverse video. The
    /// caller swaps fg/bg explicitly (for cells with explicit colors
    /// reverse should still flip them).
    fn resolveColor(self: *const GridPass, color: Color, is_fg: bool) [4]f32 {
        return switch (color) {
            .default => if (is_fg) self.default_fg else self.default_bg,
            .palette => |p| self.paletteToVec(p, is_fg),
            .rgb => |c_rgb| [_]f32{
                @as(f32, @floatFromInt(c_rgb.r)) / 255.0,
                @as(f32, @floatFromInt(c_rgb.g)) / 255.0,
                @as(f32, @floatFromInt(c_rgb.b)) / 255.0,
                1.0,
            },
        };
    }

    fn colorToVec(self: *const GridPass, color: Color, is_fg: bool, reverse: bool) [4]f32 {
        const base = switch (color) {
            .default => if (is_fg != reverse) self.default_fg else self.default_bg,
            .palette => |p| self.paletteToVec(p, is_fg),
            .rgb => |c_rgb| [_]f32{
                @as(f32, @floatFromInt(c_rgb.r)) / 255.0,
                @as(f32, @floatFromInt(c_rgb.g)) / 255.0,
                @as(f32, @floatFromInt(c_rgb.b)) / 255.0,
                1.0,
            },
        };
        return base;
    }

    fn paletteToVec(self: *const GridPass, idx: u8, is_fg: bool) [4]f32 {
        _ = is_fg;
        const p = self.palette[idx];
        return .{
            @as(f32, @floatFromInt(p[0])) / 255.0,
            @as(f32, @floatFromInt(p[1])) / 255.0,
            @as(f32, @floatFromInt(p[2])) / 255.0,
            1.0,
        };
    }

    pub fn draw(self: *GridPass, atlas: *Atlas, viewport_w: i32, viewport_h: i32) void {
        if (self.vbuf.items.len == 0) return;
        c.glUseProgram(self.program);
        c.glUniform2f(self.u_screen_px, @floatFromInt(viewport_w), @floatFromInt(viewport_h));
        c.glActiveTexture(c.GL_TEXTURE0);
        c.glBindTexture(c.GL_TEXTURE_2D_ARRAY, atlas.gl_tex);
        c.glUniform1i(self.u_atlas, 0);

        c.glBindVertexArray(self.vao);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbo);
        const bytes: c.GLsizeiptr = @intCast(self.vbuf.items.len * @sizeOf(Vertex));
        c.glBufferData(c.GL_ARRAY_BUFFER, bytes, self.vbuf.items.ptr, c.GL_DYNAMIC_DRAW);

        c.glEnable(c.GL_BLEND);
        c.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);
        c.glDrawArrays(c.GL_TRIANGLES, 0, @intCast(self.vbuf.items.len));
        c.glDisable(c.GL_BLEND);
        c.glBindVertexArray(0);
    }
};

const palette_256 = @import("../grid/palette.zig").default_256;
