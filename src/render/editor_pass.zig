//! Editor pass — instanced GPU rendering for proportional document
//! text, copied from CellPass's template (rotating triple VBO, three
//! u_kind draws, forgetGL/releaseGL/realize/deinit contract) but fed
//! from editor_layout.LaidLine instead of the cell grid.
//!
//! One Instance per quad, tagged with a per-instance kind; each of the
//! three draw calls sets u_kind and the vertex shader collapses
//! non-matching instances to a degenerate position, so ordering is
//! bg rects (selections, gutter) -> glyphs -> decorations (caret bars).
//!
//! The instance list is rebuilt every buildFrame (no per-row dirty
//! tracking — an editor viewport is a few thousand quads, far below
//! the terminal grid's cost). Atlas eviction safety comes from the
//! Layout's per-line generation check: stale lines re-shape before
//! this pass ever sees their glyphs.

const std = @import("std");
const c = @import("../c.zig").c;
const gl = @import("gl.zig");
const atlas_mod = @import("atlas.zig");
const Atlas = atlas_mod.Atlas;
const layout_mod = @import("editor_layout.zig");
const Layout = layout_mod.Layout;
const LaidLine = layout_mod.LaidLine;
const Document = @import("../editor/document.zig").Document;
const SelectionSet = @import("../editor/selection.zig").SelectionSet;

/// One quad instance. Layout matches bindVertexAttribs. 64 bytes.
pub const Instance = extern struct {
    xy: [2]f32 = .{ 0, 0 },
    size: [2]f32 = .{ 0, 0 },
    color: [4]f32 = .{ 0, 0, 0, 0 },
    uv0: [2]f32 = .{ 0, 0 },
    uv1: [2]f32 = .{ 0, 0 },
    layer: f32 = 0,
    /// 0 = bg rect, 1 = glyph, 2 = decoration (caret bar).
    kind: f32 = 0,
    /// 1 = colour (emoji) glyph — sample straight RGBA, no fg tint.
    colored: f32 = 0,
    _pad: f32 = 0,
};

pub const VERT_SRC =
    \\in vec2 a_xy;
    \\in vec2 a_size;
    \\in vec4 a_color;
    \\in vec2 a_uv0;
    \\in vec2 a_uv1;
    \\in float a_layer;
    \\in float a_kind;
    \\in float a_colored;
    \\
    \\uniform vec2 u_screen_px;
    \\uniform int u_kind;
    \\
    \\out vec4 v_color;
    \\out vec3 v_uvw;
    \\out float v_is_glyph;
    \\out float v_colored;
    \\
    \\const vec2 corners[6] = vec2[6](
    \\    vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(0.0, 1.0),
    \\    vec2(1.0, 0.0), vec2(1.0, 1.0), vec2(0.0, 1.0)
    \\);
    \\
    \\void main() {
    \\    vec2 corner = corners[gl_VertexID];
    \\    v_color = a_color;
    \\    v_colored = a_colored;
    \\    v_is_glyph = (u_kind == 1) ? 1.0 : 0.0;
    \\    v_uvw = vec3(mix(a_uv0, a_uv1, corner), a_layer);
    \\    vec2 pos = a_xy + corner * a_size;
    \\    bool emit = int(a_kind + 0.5) == u_kind
    \\        && a_size.x > 0.0 && a_size.y > 0.0 && a_color.a > 0.001;
    \\    if (!emit) pos = vec2(-10000.0);
    \\    vec2 ndc = (pos / u_screen_px) * 2.0 - 1.0;
    \\    ndc.y = -ndc.y;
    \\    gl_Position = vec4(ndc, 0.0, 1.0);
    \\}
;

pub const FRAG_SRC =
    \\in vec4 v_color;
    \\in vec3 v_uvw;
    \\in float v_is_glyph;
    \\in float v_colored;
    \\
    \\uniform sampler2DArray u_atlas;
    \\
    \\out vec4 o_frag;
    \\
    \\void main() {
    \\    if (v_is_glyph > 0.5) {
    \\        vec4 t = texture(u_atlas, v_uvw);
    \\        if (v_colored > 0.5) {
    \\            o_frag = vec4(t.rgb, t.a * v_color.a);
    \\        } else {
    \\            o_frag = vec4(v_color.rgb, t.a * v_color.a);
    \\        }
    \\    } else {
    \\        o_frag = v_color;
    \\    }
    \\}
;

/// Plain RGBA colour params — no terminal palette coupling.
pub const Colors = struct {
    text: [4]f32 = .{ 0.90, 0.91, 0.88, 1.0 },
    selection: [4]f32 = .{ 0.20, 0.35, 0.60, 0.85 },
    caret: [4]f32 = .{ 0.95, 0.35, 0.25, 1.0 },
    gutter_bg: [4]f32 = .{ 0.13, 0.13, 0.16, 1.0 },
    gutter_fg: [4]f32 = .{ 0.50, 0.52, 0.55, 1.0 },
};

pub const View = struct {
    width_px: f32,
    height_px: f32,
    /// Vertical scroll offset in px (0 = document top at viewport top).
    scroll_y: f32 = 0,
    /// Horizontal padding between gutter and text.
    margin_x: f32 = 8,
};

pub const EditorPass = struct {
    program: c_uint = 0,
    vaos: [3]c_uint = .{ 0, 0, 0 },
    vbos: [3]c_uint = .{ 0, 0, 0 },
    vbo_caps: [3]usize = .{ 0, 0, 0 },
    vbo_slot: u8 = 0,
    u_screen_px: c_int = -1,
    u_atlas: c_int = -1,
    u_kind: c_int = -1,

    instances: std.ArrayList(Instance) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) EditorPass {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *EditorPass) void {
        self.instances.deinit(self.allocator);
    }

    /// Drop GL object ids without deleting them — the context they
    /// lived in is gone (GtkGLArea re-realize). realize() rebuilds.
    pub fn forgetGL(self: *EditorPass) void {
        self.program = 0;
        @memset(&self.vaos, 0);
        @memset(&self.vbos, 0);
        @memset(&self.vbo_caps, 0);
        self.vbo_slot = 0;
        self.u_screen_px = -1;
        self.u_atlas = -1;
        self.u_kind = -1;
    }

    /// glDelete every owned resource under a still-current context,
    /// then forget. Call from the pane's unrealize handler.
    pub fn releaseGL(self: *EditorPass) void {
        if (self.program != 0) c.glDeleteProgram(self.program);
        c.glDeleteVertexArrays(3, &self.vaos[0]);
        c.glDeleteBuffers(3, &self.vbos[0]);
        self.forgetGL();
    }

    /// Build program + rotating VAO/VBO pairs. Idempotent; needs a
    /// current GL context.
    pub fn realize(self: *EditorPass) !void {
        if (self.program != 0) return;
        self.program = try gl.buildProgram(VERT_SRC, FRAG_SRC);
        self.u_screen_px = c.glGetUniformLocation(self.program, "u_screen_px");
        self.u_atlas = c.glGetUniformLocation(self.program, "u_atlas");
        self.u_kind = c.glGetUniformLocation(self.program, "u_kind");
        c.glGenVertexArrays(3, &self.vaos[0]);
        c.glGenBuffers(3, &self.vbos[0]);
        for (0..3) |i| {
            c.glBindVertexArray(self.vaos[i]);
            c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbos[i]);
            self.bindVertexAttribs();
        }
        c.glBindVertexArray(0);
    }

    fn bindVertexAttribs(self: *EditorPass) void {
        const stride: c_int = @sizeOf(Instance);
        const fields = [_]struct { name: [:0]const u8, off: usize, count: c_int }{
            .{ .name = "a_xy", .off = @offsetOf(Instance, "xy"), .count = 2 },
            .{ .name = "a_size", .off = @offsetOf(Instance, "size"), .count = 2 },
            .{ .name = "a_color", .off = @offsetOf(Instance, "color"), .count = 4 },
            .{ .name = "a_uv0", .off = @offsetOf(Instance, "uv0"), .count = 2 },
            .{ .name = "a_uv1", .off = @offsetOf(Instance, "uv1"), .count = 2 },
            .{ .name = "a_layer", .off = @offsetOf(Instance, "layer"), .count = 1 },
            .{ .name = "a_kind", .off = @offsetOf(Instance, "kind"), .count = 1 },
            .{ .name = "a_colored", .off = @offsetOf(Instance, "colored"), .count = 1 },
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

    // ---- frame building ----------------------------------------------

    fn addRect(self: *EditorPass, kind: f32, x: f32, y: f32, w: f32, h: f32, color: [4]f32) !void {
        try self.instances.append(self.allocator, .{
            .xy = .{ x, y },
            .size = .{ w, h },
            .color = color,
            .kind = kind,
        });
    }

    fn addGlyph(self: *EditorPass, g: atlas_mod.Glyph, x: f32, baseline_y: f32, y_off: f32, color: [4]f32) !void {
        if (g.w == 0 or g.h == 0) return;
        try self.instances.append(self.allocator, .{
            .xy = .{
                x + @as(f32, @floatFromInt(g.bearing_x)),
                baseline_y - y_off - @as(f32, @floatFromInt(g.bearing_y)),
            },
            .size = .{ @floatFromInt(g.w), @floatFromInt(g.h) },
            .color = color,
            .uv0 = .{ g.u0, g.v0 },
            .uv1 = .{ g.u1, g.v1 },
            .layer = @floatFromInt(g.layer),
            .kind = 1,
            .colored = if (g.colored) 1.0 else 0.0,
        });
    }

    /// Rebuild the instance list for the current document/selection
    /// state: gutter with right-aligned line numbers, selection rects,
    /// glyphs, caret bars. Only lines whose visual rows intersect the
    /// viewport EMIT instances (every line up to the viewport bottom is
    /// still laid out — row heights aren't known without layout).
    pub fn buildFrame(
        self: *EditorPass,
        layout: *Layout,
        doc: *const Document,
        sels: *const SelectionSet,
        colors: Colors,
        view: View,
    ) !void {
        self.instances.clearRetainingCapacity();
        const atlas = layout.book.atlas;
        atlas.markFrame();
        const line_h = layout.lineHeight();
        const asc = layout.ascent();
        const n_lines = doc.rope.lineCount();

        // Gutter width: digits of the last line number, right-aligned.
        var digits: usize = 1;
        {
            var v = n_lines;
            while (v >= 10) : (v /= 10) digits += 1;
        }
        const digit_g = try atlas.lookupOrLoad('0', false, false);
        const gutter_pad: f32 = 6;
        const gutter_w = @as(f32, @floatFromInt(digits)) * digit_g.advance + gutter_pad * 2;
        const text_x0 = gutter_w + view.margin_x;
        try self.addRect(0, 0, 0, gutter_w, view.height_px, colors.gutter_bg);

        var y: f32 = -view.scroll_y;
        var li: usize = 0;
        while (li < n_lines and y < view.height_px) : (li += 1) {
            const ll = try layout.line(doc, li);
            const n_rows: f32 = @floatFromInt(ll.rows.len);
            const line_bottom = y + n_rows * line_h;
            defer y = line_bottom;
            if (line_bottom < 0) continue;

            // Line number, right-aligned in the gutter, on the first row.
            {
                var buf: [20]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{li + 1}) catch unreachable;
                var w: f32 = 0;
                for (s) |ch| {
                    const g = try atlas.lookupOrLoad(ch, false, false);
                    w += g.advance;
                }
                var gx = gutter_w - gutter_pad - w;
                for (s) |ch| {
                    const g = try atlas.lookupOrLoad(ch, false, false);
                    try self.addGlyph(g, gx, y + asc, 0, colors.gutter_fg);
                    gx += g.advance;
                }
            }

            // Selection rects: per cluster overlapped by any selection
            // (correct across RTL runs and wraps — a selection is a set
            // of clusters, not one x span).
            for (sels.sels.items) |sel| {
                if (sel.isCaret()) continue;
                const s = sel.start();
                const e = sel.end();
                if (e <= ll.byte_start or s >= ll.byte_end + 1) continue;
                const ls = if (s > ll.byte_start) s - ll.byte_start else 0;
                const le = if (e < ll.byte_end) e - ll.byte_start else ll.text.len;
                for (ll.clusters) |cl| {
                    if (cl.byte_start >= le or cl.byte_end <= ls) continue;
                    const row_y = y + @as(f32, @floatFromInt(cl.row)) * line_h;
                    try self.addRect(
                        0,
                        text_x0 + cl.x0 - ll.rows[cl.row].x0,
                        row_y,
                        cl.x1 - cl.x0,
                        line_h,
                        colors.selection,
                    );
                }
            }

            // Glyphs.
            for (ll.glyphs) |pg| {
                const row_y = y + @as(f32, @floatFromInt(pg.row)) * line_h;
                try self.addGlyph(
                    pg.glyph,
                    text_x0 + pg.x - ll.rows[pg.row].x0,
                    row_y + asc,
                    pg.y_offset,
                    colors.text,
                );
            }

            // Caret bars (kind 2, drawn last). A caret at the line's
            // trailing edge (byte == byte_end) also renders here.
            for (sels.sels.items) |sel| {
                if (!sel.isCaret()) continue;
                if (sel.head < ll.byte_start or sel.head > ll.byte_end) continue;
                const cp = Layout.caretPos(ll, sel.head - ll.byte_start);
                const row_y = y + @as(f32, @floatFromInt(cp.row)) * line_h;
                try self.addRect(2, text_x0 + cp.x, row_y, 2, line_h, colors.caret);
            }
        }
    }

    // ---- upload + draw ------------------------------------------------

    fn upload(self: *EditorPass) void {
        const total_bytes: usize = self.instances.items.len * @sizeOf(Instance);
        if (total_bytes == 0 or self.vbos[0] == 0) return;
        self.vbo_slot = (self.vbo_slot + 1) % 3;
        const slot: usize = self.vbo_slot;
        c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbos[slot]);
        if (self.vbo_caps[slot] < total_bytes) {
            c.glBufferData(c.GL_ARRAY_BUFFER, @intCast(total_bytes), null, c.GL_STREAM_DRAW);
            self.vbo_caps[slot] = total_bytes;
        }
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
            c.glBufferData(
                c.GL_ARRAY_BUFFER,
                @intCast(total_bytes),
                self.instances.items.ptr,
                c.GL_STREAM_DRAW,
            );
        }
    }

    /// Upload the built instance list and issue the three kind draws.
    pub fn draw(self: *EditorPass, atlas: *Atlas, viewport_w: i32, viewport_h: i32) void {
        if (self.program == 0 or self.instances.items.len == 0) return;
        self.upload();
        c.glUseProgram(self.program);
        c.glUniform2f(self.u_screen_px, @floatFromInt(viewport_w), @floatFromInt(viewport_h));
        c.glActiveTexture(c.GL_TEXTURE0);
        c.glBindTexture(c.GL_TEXTURE_2D_ARRAY, atlas.gl_tex);
        c.glUniform1i(self.u_atlas, 0);
        c.glBindVertexArray(self.vaos[self.vbo_slot]);
        c.glEnable(c.GL_BLEND);
        c.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);
        const n: c_int = @intCast(self.instances.items.len);
        c.glUniform1i(self.u_kind, 0);
        c.glDrawArraysInstanced(c.GL_TRIANGLES, 0, 6, n);
        c.glUniform1i(self.u_kind, 1);
        c.glDrawArraysInstanced(c.GL_TRIANGLES, 0, 6, n);
        c.glUniform1i(self.u_kind, 2);
        c.glDrawArraysInstanced(c.GL_TRIANGLES, 0, 6, n);
        c.glDisable(c.GL_BLEND);
        c.glBindVertexArray(0);
    }
};

test "editor pass Instance is 64 bytes" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(Instance));
}
