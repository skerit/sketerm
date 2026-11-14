//! Cell-border renderer (`grid/borders.zig`): the one place border
//! strokes become pixels, for every row whatever pass draws its text.
//!
//! Borders are cell attributes, but drawing one needs the four
//! neighbours (shared-edge merging) and a centred stroke bleeds into the
//! next row, so this pass walks the whole visible grid instead of living
//! inside CellPass's or GridPass's per-row emitters. That also gives the
//! CellPass rows and the GridPass rows (bidi, complex script, DECDWL /
//! DECDHL) identical geometry by construction. `TerminalSurface` draws it
//! twice: `.below_text` after every background, `.above_text` after the
//! text and the block cursor (see its `onRender`).
//!
//! Version 1 leaves DECDWL / DECDHL undefined; those rows are drawn at
//! single-width cell geometry like any other.

const std = @import("std");
const c = @import("../c.zig").c;
const gl = @import("gl.zig");
const blend = @import("blend.zig");
const borders = @import("../grid/borders.zig");
const Screen = @import("../grid/screen.zig").Screen;
const StylePool = @import("../grid/style_pool.zig").Pool;

pub const VERT_SRC =
    \\in vec2 a_pos;
    \\in vec4 a_color;
    \\uniform vec2 u_screen_px;
    \\out vec4 v_color;
    \\void main() {
    \\    vec2 ndc = (a_pos / u_screen_px) * 2.0 - 1.0;
    \\    ndc.y = -ndc.y;
    \\    gl_Position = vec4(ndc, 0.0, 1.0);
    \\    v_color = a_color;
    \\}
;

pub const FRAG_SRC = blend.GLSL_HELPERS ++
    \\in vec4 v_color;
    \\out vec4 o_frag;
    \\void main() {
    \\    o_frag = sk_out(v_color);
    \\}
;

/// An axis-aligned pixel rectangle, half-open.
pub const Rect = struct {
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,

    pub fn clip(self: Rect, to: Rect) ?Rect {
        const r = Rect{
            .x0 = @max(self.x0, to.x0),
            .y0 = @max(self.y0, to.y0),
            .x1 = @min(self.x1, to.x1),
            .y1 = @min(self.y1, to.y1),
        };
        return if (r.x0 < r.x1 and r.y0 < r.y1) r else null;
    }
};

/// Stroke thickness in device pixels: `width`/256 of the cell width,
/// rounded, never under one pixel.
pub fn thickness(width: u7, cell_w: i32) i32 {
    return @max(1, @divFloor(@as(i32, width) * cell_w + 128, 256));
}

/// The pixel rectangle `seg` covers when drawn with `stroke` in the cell
/// whose top-left pixel is `x`,`y`. Lines that meet overlap at their
/// joint: a centre arm runs through the perpendicular arm's band, and a
/// centred edge runs past the corner by half its thickness, so square
/// corners and junctions have no notch when the widths agree.
pub fn segmentRect(seg: borders.Segment, stroke: borders.Stroke, x: i32, y: i32, cell_w: i32, cell_h: i32) Rect {
    const line = seg.line();
    const t = thickness(stroke.width, cell_w);
    const half = @divFloor(t, 2);
    const horizontal = line.axis == .horizontal;
    // Along the line, then across it.
    const along_origin = if (horizontal) x else y;
    const along_size = if (horizontal) cell_w else cell_h;
    const across_origin = if (horizontal) y else x;
    const across_size = if (horizontal) cell_h else cell_w;

    const centred = !line.onEdge() or stroke.placement == .centred;
    const across_lo = if (centred)
        anchorPx(line.at, across_origin, across_size) - half
    else if (line.at == .start)
        across_origin
    else
        across_origin + across_size - t;

    var along_lo = anchorPx(line.from, along_origin, along_size);
    var along_hi = anchorPx(line.to, along_origin, along_size);
    if (!line.onEdge()) {
        // A centre arm reaches through the perpendicular arm's band.
        if (line.from == .middle) along_lo -= half;
        if (line.to == .middle) along_hi += t - half;
    } else if (stroke.placement == .centred) {
        // A centred edge reaches past the corner point; edge halves meet
        // at the middle without overlap.
        if (line.from == .start) along_lo -= half;
        if (line.to == .end) along_hi += t - half;
    }

    return if (horizontal)
        .{ .x0 = along_lo, .x1 = along_hi, .y0 = across_lo, .y1 = across_lo + t }
    else
        .{ .x0 = across_lo, .x1 = across_lo + t, .y0 = along_lo, .y1 = along_hi };
}

fn anchorPx(a: borders.Anchor, origin: i32, size: i32) i32 {
    return switch (a) {
        .start => origin,
        .middle => origin + @divFloor(size, 2),
        .end => origin + size,
    };
}

/// Colour inputs a stroke resolves against at draw time.
pub const Palette = struct {
    default_fg: [4]f32,
    palette: *const [256][3]u8,

    pub fn resolve(self: Palette, color: borders.Color) [4]f32 {
        return switch (color.kind) {
            .fg => self.default_fg,
            .palette => rgb(self.palette[@intCast(color.value)]),
            .rgb => rgb(.{ @truncate(color.value >> 16), @truncate(color.value >> 8), @truncate(color.value) }),
            _ => self.default_fg,
        };
    }

    fn rgb(v: [3]u8) [4]f32 {
        return .{ @as(f32, @floatFromInt(v[0])) / 255.0, @as(f32, @floatFromInt(v[1])) / 255.0, @as(f32, @floatFromInt(v[2])) / 255.0, 1.0 };
    }
};

/// The visible grid's border sets, one per cell, as the walk reads them.
pub const Grid = struct {
    rows: u16,
    cols: u16,
    /// `rows * cols` border-set IDs, row-major.
    ids: []const u16,
    pool: *const StylePool,

    fn stroke(self: Grid, row: i32, col: i32, seg: borders.Segment) borders.Stroke {
        if (row < 0 or col < 0 or row >= self.rows or col >= self.cols) return .absent;
        const id = self.ids[@as(usize, @intCast(row)) * self.cols + @as(usize, @intCast(col))];
        if (id == 0) return .absent;
        return self.pool.borderSet(id)[@intFromEnum(seg)];
    }

    /// Whether the stroke on `seg` of (row, col) is drawn after
    /// shared-edge merging with its neighbour.
    pub fn draws(self: Grid, row: i32, col: i32, seg: borders.Segment) bool {
        const own = self.stroke(row, col, seg);
        const p = borders.partner(seg) orelse return own.present();
        const theirs = self.stroke(row + p.drow, col + p.dcol, p.segment);
        return borders.keepsSharedEdge(own, theirs, p.own_is_later);
    }
};

/// Layout of the grid on the canvas, in device pixels. Cell geometry is
/// integral so strokes stay pixel-aligned; `pad` is where CellPass puts
/// the grid's origin, added to every vertex.
pub const Geometry = struct {
    cell_w: i32,
    cell_h: i32,
    pad: f32,
};

const Vertex = extern struct {
    pos: [2]f32,
    color: [4]f32,
};

const ATTRIBS = [_]gl.Attrib{
    .{ .name = "a_pos", .off = @offsetOf(Vertex, "pos"), .count = 2 },
    .{ .name = "a_color", .off = @offsetOf(Vertex, "color"), .count = 4 },
};

/// Every input the vertex list depends on besides cell content, which
/// the caller reports through `cells_changed`.
const Key = struct {
    geometry: Geometry = .{ .cell_w = 0, .cell_h = 0, .pad = 0 },
    rows: u16 = 0,
    cols: u16 = 0,
    view_off: u32 = 0,
    use_alt: bool = false,
    default_fg: [4]f32 = .{ 0, 0, 0, 0 },
    palette: [256][3]u8 = std.mem.zeroes([256][3]u8),
};

pub const BorderPass = struct {
    program: c_uint = 0,
    vao: c_uint = 0,
    vbo: c_uint = 0,
    u_screen_px: c_int = -1,
    u_blend_mode: c_int = -1,
    /// Must match every other pass drawing into the framebuffer.
    blend_mode: blend.Mode = .native,

    allocator: std.mem.Allocator,
    verts: std.ArrayList(Vertex) = .empty,
    /// Vertex count of the below-text layer; the above-text layer
    /// follows it in `verts`.
    below_len: usize = 0,
    ids: std.ArrayList(u16) = .empty,
    last_key: Key = .{},
    built: bool = false,
    uploaded: bool = false,

    pub fn init(allocator: std.mem.Allocator) BorderPass {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *BorderPass) void {
        self.verts.deinit(self.allocator);
        self.ids.deinit(self.allocator);
    }

    pub fn forgetGL(self: *BorderPass) void {
        self.program = 0;
        self.vao = 0;
        self.vbo = 0;
        self.u_screen_px = -1;
        self.u_blend_mode = -1;
        self.uploaded = false;
    }

    pub fn releaseGL(self: *BorderPass) void {
        gl.deleteProgram(&self.program);
        gl.deleteVertexArray(&self.vao);
        gl.deleteBuffer(&self.vbo);
        self.forgetGL();
    }

    pub fn realize(self: *BorderPass) !void {
        if (self.program != 0) return;
        self.program = try gl.buildProgram(VERT_SRC, FRAG_SRC);
        self.u_screen_px = c.glGetUniformLocation(self.program, "u_screen_px");
        self.u_blend_mode = c.glGetUniformLocation(self.program, "u_blend_mode");
        c.glGenVertexArrays(1, &self.vao);
        c.glBindVertexArray(self.vao);
        c.glGenBuffers(1, &self.vbo);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbo);
        gl.bindAttribs(self.program, @sizeOf(Vertex), &ATTRIBS, false);
        c.glBindVertexArray(0);
    }

    /// Rebuild the vertex list when cell content (`cells_changed`, the
    /// CellPass flag: palette and default-colour changes rebuild every
    /// row too) or the layout moved. Free while no cell has borders.
    pub fn build(self: *BorderPass, screen: *const Screen, pool: *const StylePool, geometry: Geometry, cells_changed: bool) !void {
        if (!pool.hasBorders()) {
            if (self.verts.items.len != 0) {
                self.verts.clearRetainingCapacity();
                self.below_len = 0;
                self.uploaded = false;
            }
            self.built = false;
            return;
        }
        const sb_count: u32 = if (screen.use_alt) 0 else screen.scrollbackCount();
        const key = Key{
            .geometry = geometry,
            .rows = screen.rows,
            .cols = screen.cols,
            .view_off = @min(screen.view_offset, sb_count),
            .use_alt = screen.use_alt,
            .default_fg = if (screen.reverse_screen) screen.default_bg else screen.default_fg,
            .palette = screen.palette,
        };
        if (self.built and !cells_changed and std.meta.eql(key, self.last_key)) return;

        const n: usize = @as(usize, key.rows) * key.cols;
        try self.ids.resize(self.allocator, n);
        for (0..key.rows) |row| {
            const out = self.ids.items[row * key.cols ..][0..key.cols];
            const cells = screen.lineCellsAtPub(@as(i32, @intCast(row)) - @as(i32, @intCast(key.view_off))) orelse &.{};
            for (out, 0..) |*id, col| {
                id.* = if (col < cells.len) pool.get(cells[col].style_ref).border else 0;
            }
        }
        const grid = Grid{ .rows = key.rows, .cols = key.cols, .ids = self.ids.items, .pool = pool };
        const colors = Palette{ .default_fg = key.default_fg, .palette = &screen.palette };

        self.verts.clearRetainingCapacity();
        self.uploaded = false;
        try self.emitLayer(grid, colors, geometry, .below_text);
        self.below_len = self.verts.items.len;
        try self.emitLayer(grid, colors, geometry, .above_text);
        self.last_key = key;
        self.built = true;
    }

    /// Rows top to bottom, cells left to right, segments in bit order.
    fn emitLayer(self: *BorderPass, grid: Grid, colors: Palette, g: Geometry, layer: borders.Layer) !void {
        const area = Rect{
            .x0 = 0,
            .y0 = 0,
            .x1 = @as(i32, grid.cols) * g.cell_w,
            .y1 = @as(i32, grid.rows) * g.cell_h,
        };
        for (0..grid.rows) |row_u| {
            const row: i32 = @intCast(row_u);
            for (0..grid.cols) |col_u| {
                const col: i32 = @intCast(col_u);
                const id = grid.ids[row_u * grid.cols + col_u];
                if (id == 0) continue;
                const set = grid.pool.borderSet(id);
                for (borders.segments) |seg| {
                    const stroke = set[@intFromEnum(seg)];
                    if (!stroke.present() or stroke.layer != layer) continue;
                    if (!grid.draws(row, col, seg)) continue;
                    const r = segmentRect(seg, stroke, col * g.cell_w, row * g.cell_h, g.cell_w, g.cell_h);
                    const clipped = r.clip(area) orelse continue;
                    try self.pushRect(clipped, g.pad, colors.resolve(stroke.color));
                }
            }
        }
    }

    fn pushRect(self: *BorderPass, r: Rect, origin: f32, color: [4]f32) !void {
        const x0: f32 = origin + @as(f32, @floatFromInt(r.x0));
        const y0: f32 = origin + @as(f32, @floatFromInt(r.y0));
        const x1: f32 = origin + @as(f32, @floatFromInt(r.x1));
        const y1: f32 = origin + @as(f32, @floatFromInt(r.y1));
        try self.verts.appendSlice(self.allocator, &[_]Vertex{
            .{ .pos = .{ x0, y0 }, .color = color },
            .{ .pos = .{ x1, y0 }, .color = color },
            .{ .pos = .{ x0, y1 }, .color = color },
            .{ .pos = .{ x1, y0 }, .color = color },
            .{ .pos = .{ x1, y1 }, .color = color },
            .{ .pos = .{ x0, y1 }, .color = color },
        });
    }

    pub fn draw(self: *BorderPass, layer: borders.Layer, viewport_w: i32, viewport_h: i32) void {
        const range: [2]usize = switch (layer) {
            .below_text => .{ 0, self.below_len },
            .above_text => .{ self.below_len, self.verts.items.len },
        };
        if (self.program == 0 or range[1] == range[0]) return;
        c.glUseProgram(self.program);
        c.glUniform2f(self.u_screen_px, @floatFromInt(viewport_w), @floatFromInt(viewport_h));
        c.glUniform1i(self.u_blend_mode, @intFromEnum(self.blend_mode));
        c.glBindVertexArray(self.vao);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbo);
        if (!self.uploaded) {
            const bytes: c.GLsizeiptr = @intCast(self.verts.items.len * @sizeOf(Vertex));
            c.glBufferData(c.GL_ARRAY_BUFFER, bytes, self.verts.items.ptr, c.GL_DYNAMIC_DRAW);
            self.uploaded = true;
        }
        c.glEnable(c.GL_BLEND);
        c.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);
        c.glDrawArrays(c.GL_TRIANGLES, @intCast(range[0]), @intCast(range[1] - range[0]));
        c.glDisable(c.GL_BLEND);
        c.glBindVertexArray(0);
    }
};

// ── tests: geometry and merging, no GL ──────────────────────────

const testing = std.testing;

fn testStroke(width: u7, placement: borders.Placement) borders.Stroke {
    return .{ .width = width, .placement = placement };
}

test "thickness is width/256 of the cell width, at least one pixel" {
    try testing.expectEqual(@as(i32, 1), thickness(1, 10));
    try testing.expectEqual(@as(i32, 2), thickness(32, 16));
    try testing.expectEqual(@as(i32, 3), thickness(64, 12));
}

test "inside strokes stay in their cell, flush with the edge" {
    const s = testStroke(32, .inside); // 2px on a 16px cell
    try testing.expectEqual(Rect{ .x0 = 100, .y0 = 50, .x1 = 108, .y1 = 52 }, segmentRect(.top_left, s, 100, 50, 16, 32));
    try testing.expectEqual(Rect{ .x0 = 108, .y0 = 50, .x1 = 116, .y1 = 52 }, segmentRect(.top_right, s, 100, 50, 16, 32));
    try testing.expectEqual(Rect{ .x0 = 114, .y0 = 50, .x1 = 116, .y1 = 66 }, segmentRect(.right_top, s, 100, 50, 16, 32));
    try testing.expectEqual(Rect{ .x0 = 100, .y0 = 80, .x1 = 108, .y1 = 82 }, segmentRect(.bottom_left, s, 100, 50, 16, 32));
    try testing.expectEqual(Rect{ .x0 = 100, .y0 = 66, .x1 = 102, .y1 = 82 }, segmentRect(.left_bottom, s, 100, 50, 16, 32));
}

test "centred edges straddle the edge and run past the corner; centre arms cross the middle" {
    const s = testStroke(32, .centred); // 2px
    // Right edge of a 16x32 cell at x=116: band 115..117, from the
    // corner (minus half) to the middle row.
    try testing.expectEqual(Rect{ .x0 = 115, .y0 = 49, .x1 = 117, .y1 = 66 }, segmentRect(.right_top, s, 100, 50, 16, 32));
    try testing.expectEqual(Rect{ .x0 = 115, .y0 = 66, .x1 = 117, .y1 = 83 }, segmentRect(.right_bottom, s, 100, 50, 16, 32));
    // Placement does not move a centre arm.
    const arm = segmentRect(.h_left, testStroke(32, .inside), 100, 50, 16, 32);
    try testing.expectEqual(Rect{ .x0 = 100, .y0 = 65, .x1 = 109, .y1 = 67 }, arm);
    try testing.expectEqual(Rect{ .x0 = 107, .y0 = 65, .x1 = 116, .y1 = 67 }, segmentRect(.h_right, testStroke(32, .centred), 100, 50, 16, 32));
}

test "shared edges: centred pairs merge to one winner, inside strokes never merge" {
    var pool = try StylePool.init(testing.allocator);
    defer pool.deinit();
    const thin = borders.withStroke(borders.empty, borders.group.right | borders.group.left, testStroke(8, .centred));
    const thick = borders.withStroke(borders.empty, borders.group.right | borders.group.left, testStroke(16, .centred));
    const inside = borders.withStroke(borders.empty, borders.group.right | borders.group.left, testStroke(16, .inside));
    const thin_id = try pool.internBorder(thin);
    const thick_id = try pool.internBorder(thick);
    const inside_id = try pool.internBorder(inside);

    // thin | thin: the tie goes to the right cell.
    var ids = [_]u16{ thin_id, thin_id };
    var grid = Grid{ .rows = 1, .cols = 2, .ids = &ids, .pool = &pool };
    try testing.expect(!grid.draws(0, 0, .right_top));
    try testing.expect(grid.draws(0, 1, .left_top));
    // thick | thin: the wider wins wherever it is.
    ids = .{ thick_id, thin_id };
    try testing.expect(grid.draws(0, 0, .right_bottom));
    try testing.expect(!grid.draws(0, 1, .left_bottom));
    // inside | thick centred: both draw.
    ids = .{ inside_id, thick_id };
    try testing.expect(grid.draws(0, 0, .right_top));
    try testing.expect(grid.draws(0, 1, .left_top));
    // Outer edges of the grid have no neighbour to lose to.
    try testing.expect(grid.draws(0, 0, .left_top));
    grid.cols = 1;
    try testing.expect(grid.draws(0, 0, .right_top));
}

test "palette and fg resolve at draw time" {
    var pal: [256][3]u8 = std.mem.zeroes([256][3]u8);
    pal[3] = .{ 255, 0, 0 };
    const colors = Palette{ .default_fg = .{ 0.5, 0.5, 0.5, 1 }, .palette = &pal };
    try testing.expectEqual([4]f32{ 1, 0, 0, 1 }, colors.resolve(.{ .kind = .palette, .value = 3 }));
    try testing.expectEqual([4]f32{ 0.5, 0.5, 0.5, 1 }, colors.resolve(.{ .kind = .fg }));
    try testing.expectEqual([4]f32{ 0, 1, 0, 1 }, colors.resolve(.{ .kind = .rgb, .value = 0x00ff00 }));
}
