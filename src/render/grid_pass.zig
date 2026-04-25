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
    /// Runtime 256-color palette. Synced from `screen.palette` at
    /// the start of buildVertices so OSC 4 / 104 take effect.
    palette: [256][3]u8 = palette_256,
    /// Inner padding (pixels). Cells are offset by this amount so
    /// content doesn't sit flush against the focus border.
    pad: f32 = 6.0,
    /// Render canvas size in physical pixels. Set by onRender so
    /// buildVertices can position the focus border at the actual
    /// pane edges.
    canvas_w: f32 = 0,
    canvas_h: f32 = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) GridPass {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *GridPass) void {
        // GL resources are tied to the context, which GTK destroys
        // on widget unrealize. Skip explicit GL deletes.
        self.vbuf.deinit(self.allocator);
    }

    /// Drop our cached GL handles — call after context loss, before
    /// re-realizing into a new context. The GPU-side resources are
    /// already gone (the context took them with it).
    pub fn forgetGL(self: *GridPass) void {
        self.program = 0;
        self.vao = 0;
        self.vbo = 0;
        self.u_screen_px = -1;
        self.u_atlas = -1;
    }

    /// Build shaders + buffers. Requires a current GL context.
    /// Idempotent: a second call after a successful first is a
    /// no-op. To re-realize after context loss call `forgetGL`
    /// first.
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
    /// `focused` adds a thin accent border at the pane edges.
    pub fn buildVertices(
        self: *GridPass,
        screen: *Screen,
        pool: *const StylePool,
        atlas: *Atlas,
        focused: bool,
    ) !void {
        self.vbuf.clearRetainingCapacity();
        // Sync default fg/bg + palette from screen — OSC 4 / 10 / 11 /
        // 104 / 110 / 111 mutate them.
        self.default_fg = screen.default_fg;
        self.default_bg = screen.default_bg;
        self.palette = screen.palette;

        const cw: f32 = @floatFromInt(atlas.cell_w);
        const ch: f32 = @floatFromInt(atlas.cell_h);
        const ascent: f32 = @floatFromInt(atlas.ascent);
        // Cells are offset by `pad` to leave breathing room between
        // content and the focus border at the canvas edges.
        const pad: f32 = self.pad;

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

                const x: f32 = pad + @as(f32, @floatFromInt(col)) * cw;
                const y: f32 = pad + @as(f32, @floatFromInt(row)) * ch;

                // Background quad (only if non-default).
                if (style.bg != .default or style.attrs.reverse) {
                    try self.pushQuad(.{ x, y }, .{ cw, ch }, .{ 0, 0 }, .{ 0, 0 }, bg, 0.0);
                }

                // Skip wide-char continuation cells (right half of a
                // 2-column glyph). Their rune is 0 by design.
                if (cell.flags & 0b0000_0010 != 0) {
                    // is_wide_cont — handled by the left cell.
                } else if (cell.rune != 0 and cell.rune != ' ') {
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

        // Selection overlay (translucent). Maps selection rows
        // (which use 0..rows-1 for active screen and negative for
        // scrollback) into widget visible rows via view_off.
        if (screen.selection.isActive()) {
            const r_opt = screen.selection.rect();
            if (r_opt) |r| {
                var sr = r.top_row;
                while (sr <= r.bot_row) : (sr += 1) {
                    const visible_row: i32 = sr + @as(i32, @intCast(view_off));
                    if (visible_row < 0 or visible_row >= @as(i32, @intCast(screen.rows))) continue;
                    const start_col: i32 = if (sr == r.top_row) r.top_col else 0;
                    const end_col: i32 = if (sr == r.bot_row) r.bot_col else screen.cols;
                    if (end_col <= start_col) continue;
                    const x: f32 = pad + @as(f32, @floatFromInt(@max(0, start_col))) * cw;
                    const y: f32 = pad + @as(f32, @floatFromInt(visible_row)) * ch;
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

        // Bell flash — translucent white overlay that fades over 200ms.
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
                try self.pushQuad(
                    .{ 0, 0 },
                    .{ w, h },
                    .{ 0, 0 },
                    .{ 0, 0 },
                    .{ 1.0, 1.0, 1.0, alpha },
                    0.0,
                );
            }
        }

        // IME preedit overlay — render at cursor position with
        // an underline beneath.
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
                const cell_w_count: u16 = if (@import("../grid/screen.zig").Screen.isWide(cp)) 2 else 1;
                // Draw a solid block bg behind the preedit so it stands out.
                try self.pushQuad(
                    .{ x, y },
                    .{ cw * @as(f32, @floatFromInt(cell_w_count)), ch },
                    .{ 0, 0 },
                    .{ 0, 0 },
                    .{ 0.05, 0.05, 0.10, 0.85 },
                    0.0,
                );
                // Glyph.
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
                    try self.pushQuad(
                        .{ gx, gy },
                        .{ gw, gh },
                        .{ g.u0, g.v0 },
                        .{ g.u1, g.v1 },
                        self.default_fg,
                        1.0,
                    );
                }
                // Underline beneath.
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

        // Cursor — draw last (overlay). Hide while scrolled back
        // or while blink phase is off for a blinking shape.
        const blinking = switch (screen.cursor_shape) {
            .block_blink, .underline_blink, .bar_blink => true,
            else => false,
        };
        const blink_visible = !blinking or screen.cursor_blink_on;
        if (view_off == 0 and screen.cursor_visible and blink_visible and
            screen.row < screen.rows and screen.col < screen.cols)
        {
            const cx: f32 = pad + @as(f32, @floatFromInt(screen.col)) * cw;
            const cy: f32 = pad + @as(f32, @floatFromInt(screen.row)) * ch;
            // OSC 12 cursor color override: use it when alpha > 0,
            // otherwise fall back to default fg.
            const fg = if (screen.cursor_color[3] > 0) screen.cursor_color else self.default_fg;
            const block_alpha: f32 = 0.85;

            if (focused) {
                // Filled cursor in the configured shape.
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
                            .{ fg[0], fg[1], fg[2], 0.95 },
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
                            .{ fg[0], fg[1], fg[2], 0.95 },
                            0.0,
                        );
                    },
                }
            } else {
                // Unfocused: hollow outline, never blinks.
                const t: f32 = 1.0;
                const a: f32 = 0.55;
                try self.pushQuad(.{ cx, cy }, .{ cw, t }, .{ 0, 0 }, .{ 0, 0 }, .{ fg[0], fg[1], fg[2], a }, 0.0);
                try self.pushQuad(.{ cx, cy + ch - t }, .{ cw, t }, .{ 0, 0 }, .{ 0, 0 }, .{ fg[0], fg[1], fg[2], a }, 0.0);
                try self.pushQuad(.{ cx, cy }, .{ t, ch }, .{ 0, 0 }, .{ 0, 0 }, .{ fg[0], fg[1], fg[2], a }, 0.0);
                try self.pushQuad(.{ cx + cw - t, cy }, .{ t, ch }, .{ 0, 0 }, .{ 0, 0 }, .{ fg[0], fg[1], fg[2], a }, 0.0);
            }
        }

        // Focus border — thin accent rectangles at the pane edges.
        // Drawn at the canvas edge (not the cell-grid edge) so the
        // padding shows as breathing room between border and content.
        if (focused) {
            const w: f32 = if (self.canvas_w > 0) self.canvas_w
                else @as(f32, @floatFromInt(screen.cols)) * cw + 2 * pad;
            const h: f32 = if (self.canvas_h > 0) self.canvas_h
                else @as(f32, @floatFromInt(screen.rows)) * ch + 2 * pad;
            const border: f32 = 2.0;
            const accent = .{ 0.40, 0.55, 0.85, 0.75 };
            try self.pushQuad(.{ 0, 0 }, .{ w, border }, .{ 0, 0 }, .{ 0, 0 }, accent, 0.0);
            try self.pushQuad(.{ 0, h - border }, .{ w, border }, .{ 0, 0 }, .{ 0, 0 }, accent, 0.0);
            try self.pushQuad(.{ 0, 0 }, .{ border, h }, .{ 0, 0 }, .{ 0, 0 }, accent, 0.0);
            try self.pushQuad(.{ w - border, 0 }, .{ border, h }, .{ 0, 0 }, .{ 0, 0 }, accent, 0.0);
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
            .palette => |p| self.paletteToVec(p, is_fg),
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

// Standard xterm 256-color palette — shared with src/grid/palette.zig
// so OSC 4 queries report the same colors the renderer uses.
const palette_256 = @import("../grid/palette.zig").default_256;
