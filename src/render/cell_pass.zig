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
const Atlas = @import("atlas.zig").Atlas;
const Screen = @import("../grid/screen.zig").Screen;
const StylePool = @import("../grid/style_pool.zig").Pool;
const Color = @import("../grid/style_pool.zig").Color;
const Cell = @import("../grid/cell.zig").Cell;
const Line = @import("../grid/line.zig").Line;
const Scaling = @import("../grid/line.zig").Scaling;
const palette_default = @import("../grid/palette.zig").default_256;

/// Per-cell instance data. Layout matches the vertex attribs
/// declared in `realize`. 88 bytes — for 200×80 cells: 1.4 MB.
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
};

const VERT_SRC =
    \\#version 300 es
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
    \\
    \\uniform vec2 u_screen_px;
    \\uniform int u_kind; // 0 = bg, 1 = glyph
    \\
    \\out vec4 v_color;
    \\out vec3 v_uvw;
    \\out float v_is_glyph;
    \\out float v_emit;
    \\
    \\const vec2 corners[6] = vec2[6](
    \\    vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(0.0, 1.0),
    \\    vec2(1.0, 0.0), vec2(1.0, 1.0), vec2(0.0, 1.0)
    \\);
    \\
    \\void main() {
    \\    vec2 corner = corners[gl_VertexID];
    \\    vec2 origin;
    \\    vec2 size;
    \\    vec2 uv;
    \\    if (u_kind == 0) {
    \\        // Background quad.
    \\        origin = a_cell_xy;
    \\        size = a_cell_size;
    \\        v_color = a_bg;
    \\        uv = vec2(0.0);
    \\        v_is_glyph = 0.0;
    \\        v_emit = (a_bg.a > 0.001) ? 1.0 : 0.0;
    \\    } else {
    \\        // Glyph quad.
    \\        origin = a_glyph_xy;
    \\        size = a_glyph_size;
    \\        v_color = a_fg;
    \\        uv = mix(a_glyph_uv0, a_glyph_uv1, corner);
    \\        v_is_glyph = 1.0;
    \\        v_emit = (a_has_glyph < 0.5 && a_glyph_size.x > 0.0 && a_glyph_size.y > 0.0) ? 1.0 : 0.0;
    \\    }
    \\    v_uvw = vec3(uv, a_glyph_layer);
    \\    vec2 pos = origin + corner * size;
    \\    if (v_emit < 0.5) {
    \\        // Collapse degenerate.
    \\        pos = vec2(-10000.0);
    \\    }
    \\    vec2 ndc = (pos / u_screen_px) * 2.0 - 1.0;
    \\    ndc.y = -ndc.y;
    \\    gl_Position = vec4(ndc, 0.0, 1.0);
    \\}
;

const FRAG_SRC =
    \\#version 300 es
    \\precision mediump float;
    \\precision mediump sampler2DArray;
    \\
    \\in vec4 v_color;
    \\in vec3 v_uvw;
    \\in float v_is_glyph;
    \\in float v_emit;
    \\
    \\uniform sampler2DArray u_atlas;
    \\
    \\out vec4 o_frag;
    \\
    \\void main() {
    \\    if (v_emit < 0.5) discard;
    \\    if (v_is_glyph > 0.5) {
    \\        float a = texture(u_atlas, v_uvw).r;
    \\        o_frag = vec4(v_color.rgb, a * v_color.a);
    \\    } else {
    \\        o_frag = v_color;
    \\    }
    \\}
;

pub const CellPass = struct {
    program: c_uint = 0,
    vao: c_uint = 0,
    vbo: c_uint = 0,
    u_screen_px: c_int = -1,
    u_atlas: c_int = -1,
    u_kind: c_int = -1,

    /// Persistent instance buffer (rows × cols instances).
    instances: std.ArrayList(Instance) = .{},
    /// Allocated rows / cols — re-init the buffer when these change.
    cap_rows: u16 = 0,
    cap_cols: u16 = 0,
    /// Per-row "needs upload" flag — set when a row's instance data
    /// in `instances` changed since the last GL upload.
    row_needs_upload: std.ArrayList(bool) = .{},
    /// Capacity of the GL VBO in bytes.
    vbo_capacity: usize = 0,

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

    /// Atlas page generation per layer — when a layer is evicted by
    /// the atlas, every cached glyph that lived on it becomes stale.
    /// We snapshot generations at the start of each rebuild and force
    /// a full re-pack when any layer's generation differs from last
    /// frame's snapshot.
    last_atlas_generations: [@import("atlas.zig").PAGE_COUNT]u32 =
        [_]u32{0} ** @import("atlas.zig").PAGE_COUNT,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CellPass {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *CellPass) void {
        self.instances.deinit(self.allocator);
        self.row_needs_upload.deinit(self.allocator);
    }

    pub fn forgetGL(self: *CellPass) void {
        self.program = 0;
        self.vao = 0;
        self.vbo = 0;
        self.u_screen_px = -1;
        self.u_atlas = -1;
        self.u_kind = -1;
        self.vbo_capacity = 0;
        // Mark every row to re-upload into the new context.
        for (self.row_needs_upload.items) |*r| r.* = true;
    }

    pub fn realize(self: *CellPass) !void {
        if (self.program != 0) return;
        self.program = try gl.buildProgram(VERT_SRC, FRAG_SRC);
        self.u_screen_px = c.glGetUniformLocation(self.program, "u_screen_px");
        self.u_atlas = c.glGetUniformLocation(self.program, "u_atlas");
        self.u_kind = c.glGetUniformLocation(self.program, "u_kind");

        c.glGenVertexArrays(1, &self.vao);
        c.glBindVertexArray(self.vao);
        c.glGenBuffers(1, &self.vbo);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbo);

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
        };
        for (fields) |f| {
            const loc = c.glGetAttribLocation(self.program, f.name.ptr);
            if (loc < 0) continue;
            const idx: c_uint = @intCast(loc);
            c.glEnableVertexAttribArray(idx);
            c.glVertexAttribPointer(idx, f.count, c.GL_FLOAT, c.GL_FALSE, stride, @ptrFromInt(f.off));
            c.glVertexAttribDivisor(idx, 1);
        }

        c.glBindVertexArray(0);
    }

    /// Re-allocate the instance buffer when grid size changes.
    fn ensureCapacity(self: *CellPass, rows: u16, cols: u16) !void {
        if (rows == self.cap_rows and cols == self.cap_cols and self.instances.items.len == @as(usize, rows) * @as(usize, cols)) return;
        const total: usize = @as(usize, rows) * @as(usize, cols);
        try self.instances.resize(self.allocator, total);
        @memset(self.instances.items, .{});
        try self.row_needs_upload.resize(self.allocator, rows);
        for (self.row_needs_upload.items) |*r| r.* = true;
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
        // Sync default fg/bg / palette / reverse-screen swap.
        if (screen.reverse_screen) {
            self.default_fg = screen.default_bg;
            self.default_bg = screen.default_fg;
        } else {
            self.default_fg = screen.default_fg;
            self.default_bg = screen.default_bg;
        }
        self.palette = screen.palette;

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

        const cw: f32 = @floatFromInt(atlas.cell_w);
        const ch: f32 = @floatFromInt(atlas.cell_h);
        const ascent: f32 = @floatFromInt(atlas.ascent);
        const pad = self.pad;

        const buf = if (screen.use_alt) screen.alt.? else screen.active;
        const sb_count: u32 = if (screen.use_alt) 0 else screen.scrollbackCount();
        const view_off: u32 = @min(screen.view_offset, sb_count);

        // When scrolled, ALL rows shown change content — mark dirty.
        if (view_off != 0) {
            for (self.row_needs_upload.items) |*r| r.* = true;
        }

        // Build dirty rows.
        var row: u16 = 0;
        while (row < screen.rows) : (row += 1) {
            const ln_ptr: *Line = if (row < view_off) blk: {
                const sb_idx = sb_count - view_off + row;
                break :blk @constCast(screen.scrollbackLine(sb_idx));
            } else &buf[row - view_off];

            const need_rebuild = ln_ptr.*.dirty or self.row_needs_upload.items[row] or atlas_evicted or view_off != 0;
            if (!need_rebuild) continue;

            try self.rebuildRow(ln_ptr.*, row, screen.cols, atlas, pool, cw, ch, ascent, pad);
            ln_ptr.*.dirty = false;
            self.row_needs_upload.items[row] = true;
        }

        // Upload dirty rows to GL.
        try self.uploadDirtyRows();
    }

    fn rebuildRow(
        self: *CellPass,
        ln: Line,
        row: u16,
        cols: u16,
        atlas: *Atlas,
        pool: *const StylePool,
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
        var col: u16 = 0;
        const cells = ln.cells[0..@min(@as(usize, cols), ln.cells.len)];
        while (col < cells.len) : (col += 1) {
            const cell = cells[col];
            const style = pool.get(cell.style_ref);
            const is_wide = (cell.flags & 0b0000_0001) != 0;
            const cell_w_count: f32 = if (is_wide) 2.0 else 1.0;
            const cx: f32 = pad + @as(f32, @floatFromInt(col)) * cw * x_scale;
            const cell_w: f32 = cw * cell_w_count * x_scale;

            slice[col].cell_xy = .{ cx, y };
            slice[col].cell_size = .{ cell_w, ch };

            // Background — set even when default (alpha=0 will discard).
            const bg = self.colorToVec(style.bg, false, style.attrs.reverse);
            const has_explicit_bg = style.bg != .default or style.attrs.reverse;
            slice[col].bg = if (has_explicit_bg) bg else .{ 0, 0, 0, 0 };

            // Foreground for the glyph.
            const fg = self.colorToVec(style.fg, true, style.attrs.reverse);
            slice[col].fg = fg;
            slice[col].has_glyph = 1.0; // 1 = no glyph until we set one

            // Per-codepoint glyph (will be overridden by ligature shaping
            // below if applicable).
            if (cell.rune != 0 and cell.rune != ' ' and (cell.flags & 0b0000_0010) == 0) {
                const g = atlas.lookupOrLoad(cell.rune) catch continue;
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

            // Build UTF-8 of the run.
            var bytes: [256]u8 = undefined;
            var blen: usize = 0;
            var k: u16 = 0;
            while (k < run_len) : (k += 1) {
                const cp = cells[run_start + k].rune;
                if (blen >= bytes.len) break;
                bytes[blen] = @intCast(cp);
                blen += 1;
            }
            if (blen == 0) continue;

            const shaped = atlas.shapeRun(self.allocator, bytes[0..blen]) catch continue;
            defer self.allocator.free(shaped);
            if (shaped.len == 0 or shaped.len == run_len) continue; // No ligation occurred.

            // Clear all run cells' glyphs first; we'll repopulate.
            var cc: u16 = run_start;
            while (cc < run_start + run_len) : (cc += 1) instances[cc].has_glyph = 1.0;

            const style = pool.get(run_style);
            const fg = self.colorToVec(style.fg, true, style.attrs.reverse);

            for (shaped) |sg| {
                const cluster_col = run_start + @as(u16, @intCast(@min(@as(usize, sg.cluster), @as(usize, run_len) - 1)));
                const g = atlas.lookupOrLoadById(sg.glyph_id) catch continue;
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
        if (self.vbo == 0) return;
        c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbo);
        const total_bytes: usize = self.instances.items.len * @sizeOf(Instance);

        // Reallocate the GL buffer if needed (orphan).
        if (total_bytes > self.vbo_capacity) {
            c.glBufferData(
                c.GL_ARRAY_BUFFER,
                @intCast(total_bytes),
                self.instances.items.ptr,
                c.GL_DYNAMIC_DRAW,
            );
            self.vbo_capacity = total_bytes;
            for (self.row_needs_upload.items) |*r| r.* = false;
            return;
        }

        // Per-row glBufferSubData for dirty rows. Coalesce contiguous
        // dirty runs to reduce driver overhead.
        const cols = self.cap_cols;
        const row_bytes = @as(usize, cols) * @sizeOf(Instance);
        var i: usize = 0;
        while (i < self.row_needs_upload.items.len) {
            if (!self.row_needs_upload.items[i]) {
                i += 1;
                continue;
            }
            const start = i;
            while (i < self.row_needs_upload.items.len and self.row_needs_upload.items[i]) i += 1;
            const len = i - start;
            const offset_bytes = start * row_bytes;
            const upload_bytes = len * row_bytes;
            const ptr = @as([*]const u8, @ptrCast(self.instances.items.ptr)) + offset_bytes;
            c.glBufferSubData(
                c.GL_ARRAY_BUFFER,
                @intCast(offset_bytes),
                @intCast(upload_bytes),
                ptr,
            );
            for (self.row_needs_upload.items[start..i]) |*r| r.* = false;
        }
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
        c.glActiveTexture(c.GL_TEXTURE0);
        c.glBindTexture(c.GL_TEXTURE_2D_ARRAY, atlas.gl_tex);
        c.glUniform1i(self.u_atlas, 0);

        c.glBindVertexArray(self.vao);
        c.glEnable(c.GL_BLEND);
        c.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);

        // Pass 1: backgrounds.
        c.glUniform1i(self.u_kind, 0);
        c.glDrawArraysInstanced(c.GL_TRIANGLES, 0, 6, @intCast(self.instances.items.len));

        // Pass 2: glyphs.
        c.glUniform1i(self.u_kind, 1);
        c.glDrawArraysInstanced(c.GL_TRIANGLES, 0, 6, @intCast(self.instances.items.len));

        c.glDisable(c.GL_BLEND);
        c.glBindVertexArray(0);
    }

    fn colorToVec(self: *const CellPass, color: Color, is_fg: bool, reverse: bool) [4]f32 {
        return switch (color) {
            .default => if (is_fg != reverse) self.default_fg else self.default_bg,
            .palette => |p| .{
                @as(f32, @floatFromInt(self.palette[p][0])) / 255.0,
                @as(f32, @floatFromInt(self.palette[p][1])) / 255.0,
                @as(f32, @floatFromInt(self.palette[p][2])) / 255.0,
                1.0,
            },
            .rgb => |r| .{
                @as(f32, @floatFromInt(r.r)) / 255.0,
                @as(f32, @floatFromInt(r.g)) / 255.0,
                @as(f32, @floatFromInt(r.b)) / 255.0,
                1.0,
            },
        };
    }
};

/// True iff the cells contain any non-ASCII (>0x7F) printable rune.
/// Triggers the bidi/HB-shaped overlay path in GridPass; CellPass
/// skips these rows so they're not rendered twice.
fn rowHasNonAscii(cells: []const Cell) bool {
    for (cells) |cl| if (cl.rune > 0x7F) return true;
    return false;
}

test "Instance is 88 bytes" {
    try std.testing.expectEqual(@as(usize, 88), @sizeOf(Instance));
}
