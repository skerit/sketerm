//! Editor pass — instanced GPU rendering for proportional document
//! text, copied from CellPass's template (rotating triple VBO, one
//! draw per u_kind, forgetGL/releaseGL/realize/deinit contract) but
//! fed from editor_layout.LaidLine instead of the cell grid.
//!
//! One Instance per quad, tagged with a per-instance kind; each draw
//! call sets u_kind and the vertex shader collapses non-matching
//! instances to a degenerate position, so painter ordering is
//! backgrounds (current line, match highlights, selections) ->
//! document glyphs -> gutter -> preedit background -> preedit glyphs
//! -> decorations (caret bars, preedit underline). Two orderings there
//! are load-bearing: the GUTTER is above the document because it does
//! not scroll horizontally and text passes under it, and the PREEDIT
//! pair is above the document glyphs because an IME composition is
//! drawn over the text it will displace and its opaque backing rect
//! has to mask those glyphs.
//!
//! The instance list is rebuilt every buildFrame (no per-row dirty
//! tracking — an editor viewport is a few thousand quads, far below
//! the terminal grid's cost). Atlas eviction safety comes from the
//! Layout's per-line generation check: stale lines re-shape before
//! this pass ever sees their glyphs.
//!
//! ## Viewport anchoring (performance contract)
//!
//! `View.anchor` is a `(line, row, offset)` triple, not an absolute
//! pixel — see editor_viewport.zig for why. buildFrame therefore
//! starts laying out AT the anchor line and stops at the first line
//! below the viewport, so the cost of a frame is O(visible rows)
//! whatever the document size. `lines_laid_out` counts the
//! `Layout.line` calls of the last frame; the smoke rig asserts it
//! stays proportional to the viewport after a jump to the end of a
//! 200k-line document.

const std = @import("std");
const c = @import("../c.zig").c;
const gl = @import("gl.zig");
const atlas_mod = @import("atlas.zig");
const Atlas = atlas_mod.Atlas;
const layout_mod = @import("editor_layout.zig");
const Layout = layout_mod.Layout;
const LaidLine = layout_mod.LaidLine;
const viewport_mod = @import("editor_viewport.zig");
const Anchor = viewport_mod.Anchor;
const RowIndex = viewport_mod.RowIndex;
const Document = @import("../editor/document.zig").Document;
const SelectionSet = @import("../editor/selection.zig").SelectionSet;
const search = @import("../editor/search.zig");
const theme_mod = @import("../editor/theme.zig");
const structure = @import("../editor/structure.zig");
const lsp_diag = @import("../lsp/diagnostics.zig");
const gitdiff = @import("../editor/gitdiff.zig");

pub const KIND_BG: f32 = 0;
pub const KIND_GLYPH: f32 = 1;
/// The gutter paints ABOVE the document: with wrap off and the view
/// scrolled right, text passes UNDER it (the gutter itself never
/// scrolls), and everything document-side is clipped at `clip_x0`.
pub const KIND_GUTTER_BG: f32 = 2;
pub const KIND_GUTTER_GLYPH: f32 = 3;
pub const KIND_PREEDIT_BG: f32 = 4;
pub const KIND_PREEDIT_GLYPH: f32 = 5;
pub const KIND_DECOR: f32 = 6;
const KIND_COUNT: c_int = 7;

/// One quad instance. Layout matches bindVertexAttribs. 64 bytes.
pub const Instance = extern struct {
    xy: [2]f32 = .{ 0, 0 },
    size: [2]f32 = .{ 0, 0 },
    color: [4]f32 = .{ 0, 0, 0, 0 },
    uv0: [2]f32 = .{ 0, 0 },
    uv1: [2]f32 = .{ 0, 0 },
    layer: f32 = 0,
    /// KIND_* above.
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
    \\    v_is_glyph = (u_kind == 1 || u_kind == 3 || u_kind == 5) ? 1.0 : 0.0;
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
    /// Subtle band behind the caret's visual row.
    current_line: [4]f32 = .{ 1.0, 1.0, 1.0, 0.045 },
    /// Every find-bar match…
    match: [4]f32 = .{ 0.85, 0.72, 0.25, 0.32 },
    /// …and the one Enter would step off.
    match_current: [4]f32 = .{ 0.95, 0.72, 0.20, 0.65 },
    /// Opaque backing behind an IME composition (masks the document
    /// glyphs the composition is drawn over).
    preedit_bg: [4]f32 = .{ 0.09, 0.09, 0.12, 1.0 },
    /// Box behind each half of the bracket pair around the caret.
    bracket: [4]f32 = .{ 0.44, 0.83, 0.78, 0.42 },
    /// Badge standing in for a folded region's hidden lines.
    fold_badge: [4]f32 = .{ 0.50, 0.53, 0.57, 0.25 },
    /// Gutter chevron + the badge's dots.
    fold_fg: [4]f32 = .{ 0.60, 0.64, 0.68, 1.0 },
    /// Language-server diagnostic squiggles + gutter stripes, one
    /// colour per LSP severity.
    diag_error: [4]f32 = .{ 0.90, 0.30, 0.28, 1.0 },
    diag_warning: [4]f32 = .{ 0.92, 0.70, 0.20, 1.0 },
    diag_info: [4]f32 = .{ 0.35, 0.65, 0.92, 1.0 },
    diag_hint: [4]f32 = .{ 0.45, 0.75, 0.55, 1.0 },
    /// Per-line VCS change markers, at the gutter's RIGHT edge (the
    /// diagnostic stripe owns the left one, and a line can legitimately
    /// carry both).
    git_added: [4]f32 = .{ 0.35, 0.72, 0.40, 1.0 },
    git_modified: [4]f32 = .{ 0.35, 0.60, 0.90, 1.0 },
    git_deleted: [4]f32 = .{ 0.85, 0.35, 0.32, 1.0 },

    pub fn gitColor(self: *const Colors, kind: gitdiff.Kind) [4]f32 {
        return switch (kind) {
            .added => self.git_added,
            .modified => self.git_modified,
            .deleted => self.git_deleted,
        };
    }

    pub fn diagColor(self: *const Colors, sev: lsp_diag.Severity) [4]f32 {
        return switch (sev) {
            .err => self.diag_error,
            .warning => self.diag_warning,
            .information => self.diag_info,
            .hint => self.diag_hint,
        };
    }
};

/// One gutter fold affordance. `folded` picks the glyph direction and
/// is what makes the marker a toggle rather than a decoration.
pub const FoldMarker = struct {
    line: usize,
    folded: bool,
};

pub const View = struct {
    width_px: f32,
    height_px: f32,
    /// First visible (line, wrapped row, px into that row).
    anchor: Anchor = .{},
    /// Horizontal scroll offset in px (wrap-off only; the gutter never
    /// scrolls).
    scroll_x: f32 = 0,
    /// Horizontal padding between gutter and text.
    margin_x: f32 = 8,
    /// Draw the line-number gutter.
    show_line_numbers: bool = true,
    /// Reserve the fold column. A VIEW flag, not "does this viewport
    /// contain a marker": the gutter's width must not change while you
    /// scroll, or the text shifts sideways under the caret.
    show_fold_column: bool = false,
    /// Band behind the caret row (single collapsed caret only).
    highlight_current_line: bool = false,
    /// Blink phase — false hides the document carets (never the
    /// preedit caret, which must stay visible while composing).
    caret_on: bool = true,
};

/// An in-flight IME composition, laid out by the caller into its own
/// throwaway Document/Layout so it shapes exactly like real text.
pub const Preedit = struct {
    line: *const LaidLine,
    /// Document offset the composition is anchored at (the primary
    /// caret).
    at: usize,
    /// Caret position WITHIN the composition, in bytes.
    cursor: usize,
};

pub const Frame = struct {
    layout: *Layout,
    doc: *const Document,
    sels: *const SelectionSet,
    colors: Colors = .{},
    view: View,
    /// Estimated row index; refined in place as lines are laid out.
    rows: ?*RowIndex = null,
    matches: []const search.Match = &.{},
    current_match: ?usize = null,
    preedit: ?Preedit = null,
    /// Folded regions. Hidden lines are SKIPPED by the layout walk, so
    /// a folded document costs less to render, not more.
    folds: ?*const structure.FoldState = null,
    /// Gutter affordances for the lines this frame will draw, sorted
    /// by line. The caller computes them for the visible range only
    /// (see EditorView.ensureFoldMarkers).
    fold_markers: []const FoldMarker = &.{},
    /// Byte ranges to box as the caret's bracket pair (0, 1 or 2 per
    /// caret).
    brackets: []const structure.Range = &.{},
    /// Language-server diagnostics for the WHOLE document, sorted by
    /// start offset (lsp/diagnostics.zig keeps them that way). Drawn as
    /// squiggles under the offending clusters plus a gutter stripe on
    /// the affected lines — deliberately the same decoration path as
    /// selections and bracket boxes rather than a second overlay: a
    /// squiggle is a per-cluster range rect like any other, and giving
    /// it its own pass would double the atlas/clip bookkeeping.
    diagnostics: []const lsp_diag.Diagnostic = &.{},
    /// Per-line VCS change marks for the WHOLE document, sorted by
    /// anchor (editor/gitdiff.zig keeps them that way). Painted inside
    /// the existing gutter for the same reason the diagnostic stripe is:
    /// a refresh must never re-lay-out the text.
    git_marks: []const gitdiff.Mark = &.{},
    /// Per-highlight-kind glyph colours. Null = every glyph paints in
    /// `colors.text` (plain text, or syntax highlighting switched off).
    /// The layout tags each glyph with its kind; `Kind.none` resolves
    /// to the theme's own foreground, so an unhighlighted region inside
    /// a highlighted document looks identical either way.
    theme: ?*const theme_mod.Theme = null,
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

    /// Lines `Layout.line` was called for during the last buildFrame —
    /// the viewport-anchoring proof (see the module header).
    lines_laid_out: usize = 0,
    /// Widest laid-out row of the last frame, px (horizontal scrollbar
    /// range; only the visible lines contribute, so it grows as the
    /// user scrolls, exactly like the vertical estimate).
    max_row_width: f32 = 0,
    /// x where document text starts (gutter + margin) in the last
    /// frame — the hit-test mirror.
    text_origin_x: f32 = 0,
    /// Left clip edge for document-side quads (the gutter's width).
    clip_x0: f32 = 0,

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

    fn addRectRaw(self: *EditorPass, kind: f32, x: f32, y: f32, w: f32, h: f32, color: [4]f32) !void {
        try self.instances.append(self.allocator, .{
            .xy = .{ x, y },
            .size = .{ w, h },
            .color = color,
            .kind = kind,
        });
    }

    /// Document-side rect, clipped at the gutter's right edge.
    fn addRect(self: *EditorPass, kind: f32, x: f32, y: f32, w: f32, h: f32, color: [4]f32) !void {
        var cx = x;
        var cw = w;
        if (cx < self.clip_x0) {
            cw -= self.clip_x0 - cx;
            cx = self.clip_x0;
        }
        if (cw <= 0) return;
        try self.addRectRaw(kind, cx, y, cw, h, color);
    }

    fn addGlyph(self: *EditorPass, g: atlas_mod.Glyph, x: f32, baseline_y: f32, y_off: f32, color: [4]f32) !void {
        // Wholly under the gutter: drop it. A glyph straddling the edge
        // is drawn whole and the gutter (a later kind) covers the part
        // that overhangs — clamping the quad would shear its UVs.
        if (x + @as(f32, @floatFromInt(g.w)) <= self.clip_x0) return;
        return self.addGlyphRaw(g, x, baseline_y, y_off, color, KIND_GLYPH);
    }

    fn addGlyphRaw(
        self: *EditorPass,
        g: atlas_mod.Glyph,
        x: f32,
        baseline_y: f32,
        y_off: f32,
        color: [4]f32,
        kind: f32,
    ) !void {
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
            .kind = kind,
            .colored = if (g.colored) 1.0 else 0.0,
        });
    }

    /// Gutter width for a document of `n_lines` (0 when neither line
    /// numbers nor a fold column are wanted). Shared with the caller's
    /// hit testing — EditorView.gutterWidth must pass the SAME flags or
    /// clicks land on the wrong column.
    pub fn gutterWidth(atlas: *Atlas, n_lines: usize, show: bool, fold_col: bool) !f32 {
        var w: f32 = 0;
        if (show) {
            var digits: usize = 1;
            var v = n_lines;
            while (v >= 10) : (v /= 10) digits += 1;
            const digit_g = try atlas.lookupOrLoad('0', false, false);
            w += @as(f32, @floatFromInt(digits)) * digit_g.advance + GUTTER_PAD * 2;
        }
        if (fold_col) w += FOLD_COL_W;
        return w;
    }

    const GUTTER_PAD: f32 = 6;
    /// Width of the fold column, on the TEXT side of the line numbers
    /// (VS Code's placement).
    pub const FOLD_COL_W: f32 = 14;

    /// Rebuild the instance list for the current document/selection
    /// state: current-line band, match highlights, selection rects,
    /// gutter with right-aligned line numbers, glyphs, IME preedit and
    /// caret bars.
    ///
    /// Layout starts at `view.anchor` and stops at the first line below
    /// the viewport — never at line 0 (see the module header). Lines it
    /// touches refine `frame.rows`.
    pub fn buildFrame(self: *EditorPass, frame: Frame) !void {
        const layout = frame.layout;
        const doc = frame.doc;
        const sels = frame.sels;
        const colors = frame.colors;
        const view = frame.view;

        self.instances.clearRetainingCapacity();
        self.lines_laid_out = 0;
        self.max_row_width = 0;
        const atlas = layout.book.atlas;
        atlas.markFrame();
        const line_h = layout.lineHeight();
        const asc = layout.ascent();
        const n_lines = doc.rope.lineCount();

        const gutter_w = try gutterWidth(atlas, n_lines, view.show_line_numbers, view.show_fold_column);
        const text_x0 = gutter_w + view.margin_x - view.scroll_x;
        self.text_origin_x = text_x0;
        // Document-side geometry is clipped here; the gutter itself
        // goes through the Raw helpers.
        self.clip_x0 = gutter_w;
        if (gutter_w > 0)
            try self.addRectRaw(KIND_GUTTER_BG, 0, 0, gutter_w, view.height_px, colors.gutter_bg);

        // The caret row the current-line band belongs to, resolved
        // while walking (a single collapsed caret only — with a
        // selection or several carets the band is noise).
        const band_head: ?usize = blk: {
            if (!view.highlight_current_line) break :blk null;
            if (sels.count() != 1) break :blk null;
            const p = sels.primary();
            if (!p.isCaret()) break :blk null;
            break :blk p.head;
        };

        // First visible line's top, in viewport pixels: the anchor row
        // sits `offset` px above the top edge, and the rows of the
        // anchor line ABOVE it are off-screen.
        var li: usize = @min(view.anchor.line, n_lines -| 1);
        // The anchor must never sit on a hidden line; if a fold landed
        // on it between frames, start at the next visible one.
        if (frame.folds) |f| li = f.nextVisible(li);
        var y: f32 = -view.anchor.offset - @as(f32, @floatFromInt(view.anchor.row)) * line_h;

        // Hidden lines are SKIPPED in the step, never visited and
        // `continue`d: folding a 100k-line region must not cost 100k
        // interval lookups per frame.
        while (li < n_lines and y < view.height_px) : (li = nextVisibleLine(frame.folds, li + 1)) {
            const ll = try layout.line(doc, li);
            self.lines_laid_out += 1;
            if (frame.rows) |ri| ri.note(li, @intCast(ll.rows.len));
            const n_rows: f32 = @floatFromInt(ll.rows.len);
            const line_bottom = y + n_rows * line_h;
            defer y = line_bottom;
            if (line_bottom < 0) continue;
            self.max_row_width = @max(self.max_row_width, ll.width);

            // Current-line band, full viewport width behind everything.
            if (band_head) |head| {
                if (head >= ll.byte_start and head <= ll.byte_end) {
                    const cp = Layout.caretPos(ll, head - ll.byte_start);
                    const row_y = y + @as(f32, @floatFromInt(cp.row)) * line_h;
                    try self.addRect(
                        KIND_BG,
                        gutter_w,
                        row_y,
                        view.width_px - gutter_w,
                        line_h,
                        colors.current_line,
                    );
                }
            }

            // Find-bar match highlights (same per-cluster rule as
            // selections, so they are correct across RTL and wraps).
            for (frame.matches, 0..) |m, mi| {
                if (m.end <= ll.byte_start or m.start > ll.byte_end) continue;
                const col = if (frame.current_match != null and frame.current_match.? == mi)
                    colors.match_current
                else
                    colors.match;
                try self.addRangeRects(ll, m.start, m.end, text_x0, y, line_h, col);
            }

            // Line number, right-aligned in the number field (the fold
            // column sits to its right and is not part of it).
            const num_w = gutter_w - (if (view.show_fold_column) FOLD_COL_W else 0);
            if (view.show_line_numbers and num_w > 0) {
                var buf: [20]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{li + 1}) catch unreachable;
                var w: f32 = 0;
                for (s) |ch| {
                    const g = try atlas.lookupOrLoad(ch, false, false);
                    w += g.advance;
                }
                var gx = num_w - GUTTER_PAD - w;
                for (s) |ch| {
                    const g = try atlas.lookupOrLoad(ch, false, false);
                    try self.addGlyphRaw(g, gx, y + asc, 0, colors.gutter_fg, KIND_GUTTER_GLYPH);
                    gx += g.advance;
                }
            }

            // Fold chevron. Drawn as geometry rather than a glyph so it
            // does not depend on the font covering any arrow codepoint.
            if (view.show_fold_column) {
                if (markerFor(frame.fold_markers, li)) |m| {
                    try self.addChevron(num_w, y, line_h, m.folded, colors.fold_fg);
                }
            }

            // Selection rects: per cluster overlapped by any selection
            // (correct across RTL runs and wraps — a selection is a set
            // of clusters, not one x span).
            for (sels.sels.items) |sel| {
                if (sel.isCaret()) continue;
                try self.addRangeRects(ll, sel.start(), sel.end(), text_x0, y, line_h, colors.selection);
            }

            // Glyphs.
            for (ll.glyphs) |pg| {
                const row_y = y + @as(f32, @floatFromInt(pg.row)) * line_h;
                const fg = if (frame.theme) |th|
                    th.colorOf(@enumFromInt(pg.kind))
                else
                    colors.text;
                try self.addGlyph(
                    pg.glyph,
                    text_x0 + pg.x - ll.rows[pg.row].x0,
                    row_y + asc,
                    pg.y_offset,
                    fg,
                );
            }

            // Bracket-pair boxes. KIND_BG, so they paint UNDER the
            // glyphs whatever order they are appended in and the
            // bracket character stays readable through the tint.
            for (frame.brackets) |br| {
                if (br.end <= ll.byte_start or br.start > ll.byte_end) continue;
                try self.addRangeRects(ll, br.start, br.end, text_x0, y, line_h, colors.bracket);
            }

            // Diagnostics: a squiggle per overlapped cluster, and one
            // gutter stripe for the worst severity on the line. The
            // stripe rides KIND_GUTTER_BG (appended after the gutter
            // background, so it lands on top within that kind's draw)
            // and does NOT widen the gutter — the text must not shift
            // sideways when a server publishes.
            if (frame.diagnostics.len > 0) {
                var worst: ?lsp_diag.Severity = null;
                for (frame.diagnostics) |d| {
                    // Sorted by start: everything past this line's end
                    // is past every later line too.
                    if (d.start > ll.byte_end) break;
                    const d_end = @max(d.end, d.start);
                    if (d_end < ll.byte_start) continue;
                    if (worst == null or @intFromEnum(d.severity) < @intFromEnum(worst.?)) worst = d.severity;
                    try self.addRangeSquiggles(
                        ll,
                        d.start,
                        // A zero-width diagnostic ("expected ;") still
                        // has to be visible, so it claims one cluster.
                        if (d.end > d.start) d.end else d.start + 1,
                        text_x0,
                        y,
                        line_h,
                        colors.diagColor(d.severity),
                    );
                }
                if (worst) |sev| {
                    if (gutter_w > 0) try self.addRectRaw(
                        KIND_GUTTER_BG,
                        0,
                        y,
                        DIAG_STRIPE_W,
                        n_rows * line_h,
                        colors.diagColor(sev),
                    );
                }
            }

            // VCS gutter marks: a stripe at the gutter's right edge for
            // an added or modified line, a short tick at the top of the
            // line that closed a deletion. Sorted by anchor, so the scan
            // stops at the first mark past this line.
            if (frame.git_marks.len > 0 and gutter_w > 0) {
                for (frame.git_marks) |m| {
                    if (m.anchor > ll.byte_end) break;
                    if (m.anchor < ll.byte_start) continue;
                    const x = gutter_w - GIT_STRIPE_W;
                    const h = if (m.kind == .deleted) @min(line_h * 0.4, 6) else n_rows * line_h;
                    try self.addRectRaw(
                        KIND_GUTTER_BG,
                        x,
                        y,
                        GIT_STRIPE_W,
                        h,
                        colors.gitColor(m.kind),
                    );
                }
            }

            // Folded-region badge, at the end of the header line's last
            // row: the affordance that says "content is hidden here".
            if (frame.folds) |f| {
                if (f.entryAtLine(li) != null) {
                    const last = ll.rows[ll.rows.len - 1];
                    const last_row: f32 = @floatFromInt(ll.rows.len - 1);
                    try self.addFoldBadge(
                        atlas,
                        text_x0 + (last.x1 - last.x0) + 6,
                        y + last_row * line_h,
                        line_h,
                        asc,
                        colors,
                    );
                }
            }

            // Caret bars. A caret at the line's trailing edge
            // (byte == byte_end) also renders here.
            for (sels.sels.items, 0..) |sel, si| {
                if (!sel.isCaret()) continue;
                if (sel.head < ll.byte_start or sel.head > ll.byte_end) continue;
                // The preedit draws its own caret and replaces the
                // primary one while composing.
                if (frame.preedit != null and si == sels.primary_index) continue;
                if (!view.caret_on) continue;
                const cp = Layout.caretPos(ll, sel.head - ll.byte_start);
                const row_y = y + @as(f32, @floatFromInt(cp.row)) * line_h;
                try self.addRect(KIND_DECOR, text_x0 + cp.x, row_y, 2, line_h, colors.caret);
            }

            // IME preedit, inline at the primary caret on this line.
            if (frame.preedit) |pe| {
                if (pe.at >= ll.byte_start and pe.at <= ll.byte_end) {
                    const cp = Layout.caretPos(ll, pe.at - ll.byte_start);
                    const row_y = y + @as(f32, @floatFromInt(cp.row)) * line_h;
                    try self.addPreedit(pe, text_x0 + cp.x, row_y, line_h, asc, colors);
                }
            }
        }
    }

    /// First visible line at or after `line` (identity with no folds).
    fn nextVisibleLine(folds: ?*const structure.FoldState, line: usize) usize {
        const f = folds orelse return line;
        return f.nextVisible(line);
    }

    fn markerFor(markers: []const FoldMarker, line: usize) ?FoldMarker {
        // Linear: the list only ever covers one viewport.
        for (markers) |m| {
            if (m.line == line) return m;
        }
        return null;
    }

    /// A triangle approximated by stacked rects: pointing DOWN when the
    /// region is open, RIGHT when it is folded.
    ///
    /// KIND_GUTTER_BG, NOT KIND_GUTTER_GLYPH: the *_GLYPH kinds make
    /// the fragment shader sample the atlas, and a rect carries no UVs,
    /// so a chevron tagged as a glyph is drawn perfectly invisibly.
    /// The gutter background is appended before any line is walked, so
    /// within that kind's draw the chevron still lands on top of it.
    fn addChevron(self: *EditorPass, col_x: f32, y: f32, line_h: f32, folded: bool, color: [4]f32) !void {
        const size: f32 = @min(8.0, line_h - 4);
        if (size < 3) return;
        const x0 = col_x + (FOLD_COL_W - size) / 2;
        const y0 = y + (line_h - size) / 2;
        const steps: usize = 4;
        const step = size / @as(f32, @floatFromInt(steps));
        var i: usize = 0;
        while (i < steps) : (i += 1) {
            const t: f32 = @floatFromInt(i);
            if (folded) {
                // Right-pointing: a column per step, shrinking in height.
                const h = size - 2 * t * step;
                if (h <= 0) break;
                try self.addRectRaw(KIND_GUTTER_BG, x0 + t * step, y0 + t * step, step, h, color);
            } else {
                // Down-pointing: a row per step, shrinking in width.
                const w = size - 2 * t * step;
                if (w <= 0) break;
                try self.addRectRaw(KIND_GUTTER_BG, x0 + t * step, y0 + t * step, w, step, color);
            }
        }
    }

    /// The "content hidden here" badge: a tinted pill with three dots.
    fn addFoldBadge(
        self: *EditorPass,
        atlas: *Atlas,
        x: f32,
        row_y: f32,
        line_h: f32,
        asc: f32,
        colors: Colors,
    ) !void {
        const dot = try atlas.lookupOrLoad('.', false, false);
        const w = dot.advance * 3 + 8;
        try self.addRect(KIND_BG, x, row_y + 2, w, line_h - 4, colors.fold_badge);
        var gx = x + 4;
        var i: usize = 0;
        while (i < 3) : (i += 1) {
            try self.addGlyph(dot, gx, row_y + asc, 0, colors.fold_fg);
            gx += dot.advance;
        }
    }

    /// Width of the diagnostic stripe painted at the gutter's left
    /// edge. Inside the existing gutter, so publishing diagnostics
    /// never re-lays-out the text.
    pub const DIAG_STRIPE_W: f32 = 3;

    /// Width of the VCS change stripe at the gutter's right edge. Same
    /// reasoning as DIAG_STRIPE_W: inside the gutter, so a refresh never
    /// shifts the text.
    pub const GIT_STRIPE_W: f32 = 3;

    /// One period of the squiggle, in px. Two rects per period (up,
    /// down) is the cheapest zigzag that still reads as "wavy" at every
    /// font size we support.
    const SQUIGGLE_PERIOD: f32 = 4;

    /// A wavy underline along [x, x+w) sitting on `bottom_y`.
    fn addSquiggle(self: *EditorPass, x: f32, bottom_y: f32, w: f32, color: [4]f32) !void {
        if (w <= 0) return;
        const half = SQUIGGLE_PERIOD / 2;
        var cx = x;
        var up = true;
        // Bound the loop: a pathological wide range must not emit tens
        // of thousands of quads for one line.
        var guard: usize = 0;
        while (cx < x + w and guard < 4096) : (guard += 1) {
            const seg = @min(half, x + w - cx);
            try self.addRect(
                KIND_DECOR,
                cx,
                if (up) bottom_y - 2 else bottom_y - 1,
                seg,
                1.5,
                color,
            );
            cx += half;
            up = !up;
        }
    }

    /// Squiggles for the document byte range [s,e) on `ll`, following
    /// the same per-cluster rule selections use (so a squiggle is
    /// correct across RTL runs and soft wraps).
    fn addRangeSquiggles(
        self: *EditorPass,
        ll: *const LaidLine,
        s: usize,
        e: usize,
        text_x0: f32,
        y: f32,
        line_h: f32,
        color: [4]f32,
    ) !void {
        if (e <= ll.byte_start or s >= ll.byte_end + 1) return;
        const ls = if (s > ll.byte_start) s - ll.byte_start else 0;
        const le = if (e < ll.byte_end) e - ll.byte_start else ll.text.len;
        var drew = false;
        for (ll.clusters) |cl| {
            if (cl.byte_start >= le or cl.byte_end <= ls) continue;
            const row_y = y + @as(f32, @floatFromInt(cl.row)) * line_h;
            try self.addSquiggle(
                text_x0 + cl.x0 - ll.rows[cl.row].x0,
                row_y + line_h - 1,
                cl.x1 - cl.x0,
                color,
            );
            drew = true;
        }
        // A diagnostic pointing past the last character of a line (a
        // missing token) covers no cluster; mark the line's end anyway.
        if (!drew and ls >= ll.text.len and ll.rows.len > 0) {
            const last = ll.rows[ll.rows.len - 1];
            const last_row: f32 = @floatFromInt(ll.rows.len - 1);
            try self.addSquiggle(
                text_x0 + (last.x1 - last.x0),
                y + last_row * line_h + line_h - 1,
                SQUIGGLE_PERIOD * 2,
                color,
            );
        }
    }

    /// Per-cluster rects for the document byte range [s,e) on `ll`.
    fn addRangeRects(
        self: *EditorPass,
        ll: *const LaidLine,
        s: usize,
        e: usize,
        text_x0: f32,
        y: f32,
        line_h: f32,
        color: [4]f32,
    ) !void {
        if (e <= ll.byte_start or s >= ll.byte_end + 1) return;
        const ls = if (s > ll.byte_start) s - ll.byte_start else 0;
        const le = if (e < ll.byte_end) e - ll.byte_start else ll.text.len;
        for (ll.clusters) |cl| {
            if (cl.byte_start >= le or cl.byte_end <= ls) continue;
            const row_y = y + @as(f32, @floatFromInt(cl.row)) * line_h;
            try self.addRect(
                KIND_BG,
                text_x0 + cl.x0 - ll.rows[cl.row].x0,
                row_y,
                cl.x1 - cl.x0,
                line_h,
                color,
            );
        }
    }

    /// The composition run: opaque backing (so it masks the document
    /// text it overlays), glyphs, a full-width underline, and the
    /// caret at the IME's cursor position INSIDE the composition.
    fn addPreedit(
        self: *EditorPass,
        pe: Preedit,
        x0: f32,
        row_y: f32,
        line_h: f32,
        asc: f32,
        colors: Colors,
    ) !void {
        const pl = pe.line;
        const w = @max(pl.width, 1.0);
        try self.addRect(KIND_PREEDIT_BG, x0, row_y, w, line_h, colors.preedit_bg);
        for (pl.glyphs) |pg| {
            // A composition never soft-wraps: it renders as one run.
            if (x0 + pg.x + @as(f32, @floatFromInt(pg.glyph.w)) <= self.clip_x0) continue;
            try self.addGlyphRaw(
                pg.glyph,
                x0 + pg.x,
                row_y + asc,
                pg.y_offset,
                colors.text,
                KIND_PREEDIT_GLYPH,
            );
        }
        // Underline the whole composition (the conventional "not
        // committed yet" affordance).
        try self.addRect(KIND_DECOR, x0, row_y + line_h - 2, w, 1.5, colors.text);
        const cp = Layout.caretPos(pl, @min(pe.cursor, pl.text.len));
        try self.addRect(KIND_DECOR, x0 + cp.x, row_y, 2, line_h, colors.caret);
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
        var kind: c_int = 0;
        while (kind < KIND_COUNT) : (kind += 1) {
            c.glUniform1i(self.u_kind, kind);
            c.glDrawArraysInstanced(c.GL_TRIANGLES, 0, 6, n);
        }
        c.glDisable(c.GL_BLEND);
        c.glBindVertexArray(0);
    }
};

test "editor pass Instance is 64 bytes" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(Instance));
}
