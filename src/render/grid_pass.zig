//! Grid pass — draws cells with backgrounds and glyphs.
//!
//! v1 strategy: per-frame dynamic VBO with 6 vertices per cell
//! (two triangles). Each vertex carries (pos, uv, fg, bg, is_glyph).
//! Two-pass draw: solid bg quads first, then textured fg quads.
//!
//! 80×24 grid × 6 verts × 32 B = ~360 KB/frame. Acceptable.
//! Optimize via instancing once profiling demands.

const std = @import("std");
const c = @import("../c.zig").c;
const gl = @import("gl.zig");
const Atlas = @import("atlas.zig").Atlas;
const Screen = @import("../grid/screen.zig").Screen;
const StylePool = @import("../grid/style_pool.zig").Pool;
const Color = @import("../grid/style_pool.zig").Color;

const VERT_SRC =
    \\#version 300 es
    \\in vec2 a_pos;
    \\in vec2 a_uv;
    \\in vec4 a_color;
    \\in float a_is_glyph;
    \\
    \\uniform vec2 u_screen_px;
    \\
    \\out vec2 v_uv;
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
    \\
    \\in vec2 v_uv;
    \\in vec4 v_color;
    \\in float v_is_glyph;
    \\
    \\uniform sampler2D u_atlas;
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
    uv: [2]f32,
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
    /// Default fg/bg used when style.fg/bg is .default.
    default_fg: [4]f32 = .{ 0.92, 0.92, 0.92, 1.0 },
    default_bg: [4]f32 = .{ 0.10, 0.10, 0.10, 1.0 },
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) GridPass {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *GridPass) void {
        if (self.program != 0) c.glDeleteProgram(self.program);
        if (self.vbo != 0) c.glDeleteBuffers(1, &self.vbo);
        if (self.vao != 0) c.glDeleteVertexArrays(1, &self.vao);
        self.vbuf.deinit(self.allocator);
    }

    /// Realize GL resources. Requires a current context.
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
        c.glVertexAttribPointer(a_uv, 2, c.GL_FLOAT, c.GL_FALSE, stride, @ptrFromInt(@offsetOf(Vertex, "uv")));
        c.glEnableVertexAttribArray(a_color);
        c.glVertexAttribPointer(a_color, 4, c.GL_FLOAT, c.GL_FALSE, stride, @ptrFromInt(@offsetOf(Vertex, "color")));
        c.glEnableVertexAttribArray(a_is_glyph);
        c.glVertexAttribPointer(a_is_glyph, 1, c.GL_FLOAT, c.GL_FALSE, stride, @ptrFromInt(@offsetOf(Vertex, "is_glyph")));

        c.glBindVertexArray(0);
    }

    /// Build the vertex buffer for the current screen state.
    pub fn buildVertices(
        self: *GridPass,
        screen: *Screen,
        pool: *const StylePool,
        atlas: *Atlas,
    ) !void {
        self.vbuf.clearRetainingCapacity();

        const cw: f32 = @floatFromInt(atlas.cell_w);
        const ch: f32 = @floatFromInt(atlas.cell_h);
        const ascent: f32 = @floatFromInt(atlas.ascent);

        const buf = if (screen.use_alt) screen.alt.? else screen.active;
        const sb_count: u32 = if (screen.use_alt) 0 else screen.scrollbackCount();
        const view_off: u32 = @min(screen.view_offset, sb_count);

        var row: u16 = 0;
        while (row < screen.rows) : (row += 1) {
            // Resolve which logical line to display at this row.
            // view_off lines from scrollback are visible at top.
            const ln_ptr: *const @TypeOf(buf[0]) = if (row < view_off) blk: {
                const sb_idx = sb_count - view_off + row;
                break :blk screen.scrollbackLine(sb_idx);
            } else &buf[row - view_off];
            const ln = ln_ptr.*;
            var col: u16 = 0;
            while (col < screen.cols) : (col += 1) {
                const cell = ln.cells[col];
                const style = pool.get(cell.style_ref);
                const fg = self.colorToVec(style.fg, true, style.attrs.reverse);
                const bg = self.colorToVec(style.bg, false, style.attrs.reverse);

                const x: f32 = @as(f32, @floatFromInt(col)) * cw;
                const y: f32 = @as(f32, @floatFromInt(row)) * ch;

                // Background quad (only if non-default).
                if (style.bg != .default or style.attrs.reverse) {
                    try self.pushQuad(.{ x, y }, .{ cw, ch }, .{ 0, 0 }, .{ 0, 0 }, bg, 0.0);
                }

                if (cell.rune != 0 and cell.rune != ' ') {
                    const g = atlas.lookupOrLoad(cell.rune) catch continue;
                    if (g.w == 0 or g.h == 0) continue;
                    const gx: f32 = x + @as(f32, @floatFromInt(g.bearing_x));
                    const gy: f32 = y + ascent - @as(f32, @floatFromInt(g.bearing_y));
                    const gw: f32 = @floatFromInt(g.w);
                    const gh: f32 = @floatFromInt(g.h);
                    try self.pushQuad(
                        .{ gx, gy },
                        .{ gw, gh },
                        .{ g.u0, g.v0 },
                        .{ g.u1, g.v1 },
                        fg,
                        1.0,
                    );
                }
            }
        }

        // Selection overlay (translucent).
        if (screen.selection.isActive() and view_off == 0) {
            const r_opt = screen.selection.rect();
            if (r_opt) |r| {
                var sr = r.top_row;
                while (sr <= r.bot_row) : (sr += 1) {
                    if (sr < 0 or sr >= screen.rows) continue;
                    const start_col: i32 = if (sr == r.top_row) r.top_col else 0;
                    const end_col: i32 = if (sr == r.bot_row) r.bot_col else screen.cols;
                    if (end_col <= start_col) continue;
                    const x: f32 = @as(f32, @floatFromInt(@max(0, start_col))) * cw;
                    const y: f32 = @as(f32, @floatFromInt(sr)) * ch;
                    const w: f32 = @as(f32, @floatFromInt(end_col - @max(0, start_col))) * cw;
                    try self.pushQuad(
                        .{ x, y },
                        .{ w, ch },
                        .{ 0, 0 },
                        .{ 0, 0 },
                        .{ 0.4, 0.55, 0.85, 0.45 },
                        0.0,
                    );
                }
            }
        }

        // Cursor — draw last (overlay). Hide while scrolled back.
        if (view_off == 0 and screen.cursor_visible and screen.row < screen.rows and screen.col < screen.cols) {
            const cx: f32 = @as(f32, @floatFromInt(screen.col)) * cw;
            const cy: f32 = @as(f32, @floatFromInt(screen.row)) * ch;
            const fg = self.default_fg;
            const block_alpha: f32 = 0.55;

            const Shape = @import("../grid/screen.zig").Screen.CursorShape;
            switch (screen.cursor_shape) {
                .block_blink, .block_steady => {
                    try self.pushQuad(
                        .{ cx, cy },
                        .{ cw, ch },
                        .{ 0, 0 },
                        .{ 0, 0 },
                        .{ fg[0], fg[1], fg[2], block_alpha },
                        0.0,
                    );
                },
                .underline_blink, .underline_steady => {
                    const h: f32 = @max(2.0, ch / 8.0);
                    try self.pushQuad(
                        .{ cx, cy + ch - h },
                        .{ cw, h },
                        .{ 0, 0 },
                        .{ 0, 0 },
                        .{ fg[0], fg[1], fg[2], 0.85 },
                        0.0,
                    );
                },
                .bar_blink, .bar_steady => {
                    const w: f32 = @max(2.0, cw / 6.0);
                    try self.pushQuad(
                        .{ cx, cy },
                        .{ w, ch },
                        .{ 0, 0 },
                        .{ 0, 0 },
                        .{ fg[0], fg[1], fg[2], 0.85 },
                        0.0,
                    );
                },
            }
            _ = Shape; // (kept import for clarity)
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
        const tu0 = uv0[0];
        const tv0 = uv0[1];
        const tu1 = uv1[0];
        const tv1 = uv1[1];
        const verts = [_]Vertex{
            .{ .pos = .{ px0, py0 }, .uv = .{ tu0, tv0 }, .color = color, .is_glyph = is_glyph },
            .{ .pos = .{ px1, py0 }, .uv = .{ tu1, tv0 }, .color = color, .is_glyph = is_glyph },
            .{ .pos = .{ px0, py1 }, .uv = .{ tu0, tv1 }, .color = color, .is_glyph = is_glyph },
            .{ .pos = .{ px1, py0 }, .uv = .{ tu1, tv0 }, .color = color, .is_glyph = is_glyph },
            .{ .pos = .{ px1, py1 }, .uv = .{ tu1, tv1 }, .color = color, .is_glyph = is_glyph },
            .{ .pos = .{ px0, py1 }, .uv = .{ tu0, tv1 }, .color = color, .is_glyph = is_glyph },
        };
        try self.vbuf.appendSlice(self.allocator, &verts);
    }

    fn colorToVec(self: *const GridPass, color: Color, is_fg: bool, reverse: bool) [4]f32 {
        const base = switch (color) {
            .default => if (is_fg != reverse) self.default_fg else self.default_bg,
            .palette => |p| paletteToVec(p, is_fg),
            .rgb => |c_rgb| [_]f32{
                @as(f32, @floatFromInt(c_rgb.r)) / 255.0,
                @as(f32, @floatFromInt(c_rgb.g)) / 255.0,
                @as(f32, @floatFromInt(c_rgb.b)) / 255.0,
                1.0,
            },
        };
        if (reverse) {
            // Toggle between fg/bg semantics: caller already passed
            // the appropriate `is_fg`; reverse swaps default mapping
            // above. For palette/rgb, no automatic swap (would
            // require both colors). Acceptable v1 limitation.
        }
        return base;
    }

    fn paletteToVec(idx: u8, is_fg: bool) [4]f32 {
        _ = is_fg;
        // Standard xterm 16-color palette + 256-color extension.
        const p = palette_256[idx];
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
        c.glBindTexture(c.GL_TEXTURE_2D, atlas.gl_tex);
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

// Standard xterm 256-color palette (subset; rest computed).
const palette_256: [256][3]u8 = blk: {
    @setEvalBranchQuota(10_000);
    var p: [256][3]u8 = undefined;
    // 16 ANSI colors.
    const ansi = [_][3]u8{
        .{ 0x00, 0x00, 0x00 }, .{ 0xCC, 0x00, 0x00 }, .{ 0x4E, 0x9A, 0x06 }, .{ 0xC4, 0xA0, 0x00 },
        .{ 0x34, 0x65, 0xA4 }, .{ 0x75, 0x50, 0x7B }, .{ 0x06, 0x98, 0x9A }, .{ 0xD3, 0xD7, 0xCF },
        .{ 0x55, 0x57, 0x53 }, .{ 0xEF, 0x29, 0x29 }, .{ 0x8A, 0xE2, 0x34 }, .{ 0xFC, 0xE9, 0x4F },
        .{ 0x72, 0x9F, 0xCF }, .{ 0xAD, 0x7F, 0xA8 }, .{ 0x34, 0xE2, 0xE2 }, .{ 0xEE, 0xEE, 0xEC },
    };
    for (ansi, 0..) |col, i| p[i] = col;
    // 6×6×6 cube (216 colors, indices 16..231).
    var i: usize = 0;
    while (i < 216) : (i += 1) {
        const r = i / 36;
        const g = (i / 6) % 6;
        const b = i % 6;
        const ramp = [_]u8{ 0, 0x5F, 0x87, 0xAF, 0xD7, 0xFF };
        p[16 + i] = .{ ramp[r], ramp[g], ramp[b] };
    }
    // Grayscale (24 levels, indices 232..255).
    var k: usize = 0;
    while (k < 24) : (k += 1) {
        const v: u8 = @intCast(8 + k * 10);
        p[232 + k] = .{ v, v, v };
    }
    break :blk p;
};
