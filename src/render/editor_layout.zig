//! Proportional line layout over the editor document core.
//!
//! Turns a Document line into positioned glyph quads + a cluster map
//! (the hit-testing currency): bidi level runs first (fribidi), then
//! font itemization (editor_font.FontBook), HarfBuzz shaping per run,
//! tab stops, optional greedy soft wrap at cluster boundaries, and a
//! per-line cache invalidated by document revision + atlas page
//! generations.
//!
//! Simplifications (deliberate, documented):
//! - Caret affinity is trailing-edge only: a byte offset maps to the
//!   visual LEFT edge of its cluster; no split-caret at bidi
//!   boundaries.
//! - Tabs inside RTL bidi runs advance in visual order like LTR tabs.
//! - Soft wrap breaks at grapheme-cluster boundaries in VISUAL order
//!   (no word wrap, and a bidi line wraps by visual runs).
//! - Clusters whose start is not a grapheme boundary merge into their
//!   visually-previous cluster so a caret can never land inside a
//!   grapheme.
//!
//! ## Syntax highlighting
//!
//! When a `Highlighter` and a `Theme` are attached, each line asks the
//! highlighter for one `syntax.Kind` byte per line byte. Those kinds do
//! two things: the theme's per-kind bold/italic becomes the
//! `StyleSpan` list handed to itemization (so a bold keyword shapes
//! with the bold FACE, not a synthesized smear), and every
//! `PlacedGlyph` carries its kind so editor_pass can colour it.
//!
//! The per-line cache therefore keys on the highlighter's `gen` as well
//! as the document revision: a debounced re-parse lands at the SAME
//! revision the lines were laid out at, and without that key the
//! viewport would keep painting the pre-parse colours.
//! A stale highlighter is not an error here — the line simply lays out
//! unhighlighted and re-lays out when the parse catches up.

const std = @import("std");
const atlas_mod = @import("atlas.zig");
const Atlas = atlas_mod.Atlas;
const Glyph = atlas_mod.Glyph;
const font_mod = @import("editor_font.zig");
const FontBook = font_mod.FontBook;
const StyleSpan = font_mod.StyleSpan;
const bidi = @import("../grid/bidi.zig");
const unicode = @import("../editor/unicode.zig");
const Document = @import("../editor/document.zig").Document;
const syntax = @import("../editor/syntax.zig");
const theme_mod = @import("../editor/theme.zig");

/// One positioned glyph. `x` is the UNWRAPPED visual pen position of
/// the glyph (hb x_offset applied); the renderer adds bearings and
/// subtracts the wrap row's x origin.
pub const PlacedGlyph = struct {
    x: f32,
    /// HarfBuzz y_offset in pixels, positive UP from the baseline.
    y_offset: f32,
    glyph: Glyph,
    /// Byte offset of the glyph's cluster within the line text.
    cluster_byte: u32,
    advance: f32,
    /// Soft-wrap row index (0 when not wrapping).
    row: u32,
    /// `@intFromEnum(syntax.Kind)` of the glyph's cluster; 0 (`.none`)
    /// when the line is unhighlighted.
    kind: u8 = 0,
};

/// One hit-testing cluster: byte range + unwrapped x range, in VISUAL
/// order (ascending x). byte_start is always a grapheme boundary.
pub const Cluster = struct {
    byte_start: u32,
    byte_end: u32,
    x0: f32,
    x1: f32,
    row: u32,
};

/// One soft-wrap visual row: [x0, x1) in unwrapped coordinates.
pub const WrapRow = struct {
    x0: f32,
    x1: f32,
};

pub const LaidLine = struct {
    line_index: usize,
    /// Absolute document byte range (newline excluded).
    byte_start: usize,
    byte_end: usize,
    /// Owned copy of the line's text.
    text: []u8,
    glyphs: []PlacedGlyph,
    clusters: []Cluster,
    rows: []WrapRow,
    /// Widest row, px.
    width: f32,
    /// Itemization stats (smoke assertions).
    n_runs: usize,
    n_notdef: usize,
    revision: u64,
    atlas_gens: [atlas_mod.PAGE_COUNT]u32,
    /// Highlighter generation the kinds came from (0 = unhighlighted).
    hl_gen: u64 = 0,

    fn free(self: *LaidLine, alloc: std.mem.Allocator) void {
        alloc.free(self.text);
        alloc.free(self.glyphs);
        alloc.free(self.clusters);
        alloc.free(self.rows);
        alloc.destroy(self);
    }
};

pub const Layout = struct {
    alloc: std.mem.Allocator,
    book: *FontBook,
    /// Tab stop width in multiples of the primary space advance.
    tab_cols: u16 = 4,
    /// Soft wrap width in px (null = no wrap).
    wrap_width: ?f32 = null,
    /// Syntax highlighter for this document (null = plain text). Owned
    /// by the caller and allowed to lag the document — a stale one is
    /// simply not consulted.
    hl: ?*syntax.Highlighter = null,
    /// Colour + face source for highlight kinds.
    theme: *const theme_mod.Theme = &theme_mod.dark,
    cache: std.AutoHashMap(usize, *LaidLine),

    pub fn init(alloc: std.mem.Allocator, book: *FontBook) Layout {
        return .{
            .alloc = alloc,
            .book = book,
            .cache = std.AutoHashMap(usize, *LaidLine).init(alloc),
        };
    }

    pub fn deinit(self: *Layout) void {
        self.invalidateAll();
        self.cache.deinit();
    }

    /// Drop every cached line — call after changing wrap_width/tab_cols.
    pub fn invalidateAll(self: *Layout) void {
        var it = self.cache.iterator();
        while (it.next()) |e| e.value_ptr.*.free(self.alloc);
        self.cache.clearRetainingCapacity();
    }

    pub fn lineHeight(self: *const Layout) f32 {
        return @floatFromInt(self.book.atlas.cell_h);
    }

    pub fn ascent(self: *const Layout) f32 {
        return @floatFromInt(self.book.atlas.ascent);
    }

    fn atlasGens(self: *const Layout) [atlas_mod.PAGE_COUNT]u32 {
        var gens: [atlas_mod.PAGE_COUNT]u32 = undefined;
        for (self.book.atlas.pages, 0..) |p, i| gens[i] = p.generation;
        return gens;
    }

    /// Lay out (or fetch cached) line `idx`. The returned pointer stays
    /// valid until this line is re-laid-out or the Layout is deinit-ed.
    /// Highlighter generation usable for `doc` right now — 0 when there
    /// is no highlighter or it has not caught up (revision-stamped
    /// results are rejected rather than painted onto moved bytes).
    fn liveHlGen(self: *Layout, doc: *const Document) u64 {
        const hl = self.hl orelse return 0;
        if (hl.isStale(doc)) return 0;
        return hl.gen;
    }

    pub fn line(self: *Layout, doc: *const Document, idx: usize) !*const LaidLine {
        const gens = self.atlasGens();
        const hl_gen = self.liveHlGen(doc);
        if (self.cache.get(idx)) |cached| {
            if (cached.revision == doc.revision and
                cached.hl_gen == hl_gen and
                std.mem.eql(u32, &cached.atlas_gens, &gens))
                return cached;
            cached.free(self.alloc);
            _ = self.cache.remove(idx);
        }
        const start = doc.rope.lineToOffset(idx);
        const end = if (idx + 1 < doc.rope.lineCount())
            doc.rope.lineToOffset(idx + 1) - 1
        else
            doc.rope.len();
        const text = try doc.rope.sliceAlloc(self.alloc, start, end);
        errdefer self.alloc.free(text);

        // One highlight kind per line byte. A highlighter that errors
        // (stale, or a window it cannot serve) degrades to plain text
        // rather than failing the frame.
        var kinds: ?[]u8 = null;
        defer if (kinds) |k| self.alloc.free(k);
        if (hl_gen != 0 and text.len > 0) {
            const buf = try self.alloc.alloc(u8, text.len);
            if (self.hl.?.fillKinds(doc, start, end, buf)) |_| {
                kinds = buf;
            } else |_| {
                self.alloc.free(buf);
            }
        }

        const built = try self.buildLine(text, kinds);
        const ll = try self.alloc.create(LaidLine);
        errdefer self.alloc.destroy(ll);
        ll.* = .{
            .line_index = idx,
            .byte_start = start,
            .byte_end = end,
            .text = text,
            .glyphs = built.glyphs,
            .clusters = built.clusters,
            .rows = built.rows,
            .width = built.width,
            .n_runs = built.n_runs,
            .n_notdef = built.n_notdef,
            .revision = doc.revision,
            .atlas_gens = gens,
            .hl_gen = if (kinds != null) hl_gen else 0,
        };
        try self.cache.put(idx, ll);
        return ll;
    }

    const Built = struct {
        glyphs: []PlacedGlyph,
        clusters: []Cluster,
        rows: []WrapRow,
        width: f32,
        n_runs: usize,
        n_notdef: usize,
    };

    fn buildLine(self: *Layout, text: []const u8, kinds: ?[]const u8) !Built {
        const alloc = self.alloc;
        var glyphs: std.ArrayList(PlacedGlyph) = .empty;
        errdefer glyphs.deinit(alloc);
        var clusters: std.ArrayList(Cluster) = .empty;
        errdefer clusters.deinit(alloc);

        var n_runs: usize = 0;
        var n_notdef: usize = 0;
        var pen: f32 = 0;

        const space_g = try self.book.atlas.lookupOrLoad(' ', false, false);
        const tab_px: f32 = @max(1.0, space_g.advance * @as(f32, @floatFromInt(self.tab_cols)));

        if (text.len > 0) {
            // Decode to codepoints for fribidi.
            var cps: std.ArrayList(u32) = .empty;
            defer cps.deinit(alloc);
            var cp_off: std.ArrayList(u32) = .empty;
            defer cp_off.deinit(alloc);
            {
                var i: usize = 0;
                while (i < text.len) {
                    const d = unicode.decodeAt(text, i);
                    try cps.append(alloc, d.cp);
                    try cp_off.append(alloc, @intCast(i));
                    i += d.len;
                }
            }
            const levels = try alloc.alloc(u8, cps.items.len);
            defer alloc.free(levels);
            _ = bidi.lineLevels(cps.items, levels, .auto);

            // Maximal same-level codepoint runs -> byte ranges.
            const BidiRun = struct { start: u32, end: u32, level: u8 };
            var bruns: std.ArrayList(BidiRun) = .empty;
            defer bruns.deinit(alloc);
            {
                var rs: usize = 0;
                var i: usize = 1;
                while (i <= cps.items.len) : (i += 1) {
                    if (i == cps.items.len or levels[i] != levels[rs]) {
                        const bend: u32 = if (i == cps.items.len) @intCast(text.len) else cp_off.items[i];
                        try bruns.append(alloc, .{
                            .start = cp_off.items[rs],
                            .end = bend,
                            .level = levels[rs],
                        });
                        rs = i;
                    }
                }
            }
            // Visual order of bidi runs (UAX #9 L2 at run granularity).
            const run_levels = try alloc.alloc(u8, bruns.items.len);
            defer alloc.free(run_levels);
            const run_order = try alloc.alloc(usize, bruns.items.len);
            defer alloc.free(run_order);
            for (bruns.items, 0..) |br, i| {
                run_levels[i] = br.level;
                run_order[i] = i;
            }
            bidi.levelsToVisualOrder(run_levels, run_order);

            for (run_order) |ri| {
                const br = bruns.items[ri];
                const rtl = br.level % 2 == 1;
                // Split the bidi run at tabs.
                var seg_start: usize = br.start;
                var i: usize = br.start;
                while (i <= br.end) : (i += 1) {
                    const at_tab = i < br.end and text[i] == '\t';
                    if (i == br.end or at_tab) {
                        if (i > seg_start) {
                            const stats = try self.emitPiece(
                                text,
                                kinds,
                                @intCast(seg_start),
                                @intCast(i),
                                rtl,
                                &pen,
                                &glyphs,
                                &clusters,
                            );
                            n_runs += stats.runs;
                            n_notdef += stats.notdef;
                        }
                        if (at_tab) {
                            const stop = (@floor(pen / tab_px) + 1.0) * tab_px;
                            try clusters.append(alloc, .{
                                .byte_start = @intCast(i),
                                .byte_end = 0,
                                .x0 = pen,
                                .x1 = stop,
                                .row = 0,
                            });
                            pen = stop;
                            seg_start = i + 1;
                        }
                    }
                }
            }
        }

        // Merge clusters whose byte_start is inside a grapheme into the
        // visually-previous cluster; build old->new index remap for the
        // glyph row assignment below.
        const remap = try alloc.alloc(u32, clusters.items.len);
        defer alloc.free(remap);
        var merged: std.ArrayList(Cluster) = .empty;
        errdefer merged.deinit(alloc);
        for (clusters.items, 0..) |cl, i| {
            const boundary = unicode.isGraphemeBoundary(text, cl.byte_start);
            if (!boundary and merged.items.len > 0) {
                const prev = &merged.items[merged.items.len - 1];
                prev.byte_start = @min(prev.byte_start, cl.byte_start);
                prev.x1 = @max(prev.x1, cl.x1);
                remap[i] = @intCast(merged.items.len - 1);
            } else {
                remap[i] = @intCast(merged.items.len);
                try merged.append(alloc, cl);
            }
        }
        clusters.deinit(alloc);

        // byte_end per cluster = smallest byte_start strictly greater
        // (RTL clusters land in descending byte order, so "next in the
        // list" is wrong — same trick as the spike, but via a sorted
        // start array so long lines stay O(n log n)).
        {
            const starts = try alloc.alloc(u32, merged.items.len);
            defer alloc.free(starts);
            for (merged.items, 0..) |cl, i| starts[i] = cl.byte_start;
            std.mem.sort(u32, starts, {}, std.sort.asc(u32));
            for (merged.items) |*cl| {
                var lo: usize = 0;
                var hi: usize = starts.len;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    if (starts[mid] <= cl.byte_start) lo = mid + 1 else hi = mid;
                }
                cl.byte_end = if (lo < starts.len) starts[lo] else @intCast(text.len);
            }
        }

        // Soft wrap: greedy walk in visual order, breaking before the
        // cluster that would overflow (unless it is the row's first).
        var rows: std.ArrayList(WrapRow) = .empty;
        errdefer rows.deinit(alloc);
        {
            var row_x0: f32 = 0;
            var row_idx: u32 = 0;
            for (merged.items) |*cl| {
                if (self.wrap_width) |ww| {
                    if (cl.x1 - row_x0 > ww and cl.x0 > row_x0) {
                        try rows.append(alloc, .{ .x0 = row_x0, .x1 = cl.x0 });
                        row_x0 = cl.x0;
                        row_idx += 1;
                    }
                }
                cl.row = row_idx;
            }
            const last_x1 = if (merged.items.len > 0) merged.items[merged.items.len - 1].x1 else 0;
            try rows.append(alloc, .{ .x0 = row_x0, .x1 = last_x1 });
        }
        var width: f32 = 0;
        for (rows.items) |r| width = @max(width, r.x1 - r.x0);

        // Glyph rows: PlacedGlyph.row held the pre-merge cluster index.
        for (glyphs.items) |*g| {
            g.row = merged.items[remap[g.row]].row;
        }

        return .{
            .glyphs = try glyphs.toOwnedSlice(alloc),
            .clusters = try merged.toOwnedSlice(alloc),
            .rows = try rows.toOwnedSlice(alloc),
            .width = width,
            .n_runs = n_runs,
            .n_notdef = n_notdef,
        };
    }

    const PieceStats = struct { runs: usize, notdef: usize };

    /// Itemize + shape + place one tab-free slice of a bidi run.
    /// Coalesce the piece's highlight kinds into itemization style
    /// spans (bold/italic runs). Caller frees.
    fn styleSpansFor(
        self: *Layout,
        kinds: []const u8,
    ) ![]StyleSpan {
        var spans: std.ArrayList(StyleSpan) = .empty;
        errdefer spans.deinit(self.alloc);
        var i: usize = 0;
        while (i < kinds.len) {
            const st = self.theme.style(@enumFromInt(kinds[i]));
            var j = i + 1;
            while (j < kinds.len) : (j += 1) {
                const s2 = self.theme.style(@enumFromInt(kinds[j]));
                if (s2.bold != st.bold or s2.italic != st.italic) break;
            }
            try spans.append(self.alloc, .{
                .end = @intCast(j),
                .bold = st.bold,
                .italic = st.italic,
            });
            i = j;
        }
        return spans.toOwnedSlice(self.alloc);
    }

    fn emitPiece(
        self: *Layout,
        text: []const u8,
        kinds: ?[]const u8,
        piece_start: u32,
        piece_end: u32,
        rtl: bool,
        pen: *f32,
        glyphs: *std.ArrayList(PlacedGlyph),
        clusters: *std.ArrayList(Cluster),
    ) !PieceStats {
        const alloc = self.alloc;
        const piece = text[piece_start..piece_end];
        const spans: []StyleSpan = if (kinds) |k|
            try self.styleSpansFor(k[piece_start..piece_end])
        else
            &.{};
        defer if (spans.len > 0) alloc.free(spans);
        const runs = try self.book.itemize(alloc, piece, spans, rtl);
        defer alloc.free(runs);
        var notdef: usize = 0;

        // RTL bidi runs place their itemized sub-runs right-to-left,
        // i.e. in reverse logical order.
        var k: usize = 0;
        while (k < runs.len) : (k += 1) {
            const run = if (rtl) runs[runs.len - 1 - k] else runs[k];
            const slice = piece[run.start..run.end];
            const shaped = try self.book.shape(run, slice);
            var i: usize = 0;
            while (i < shaped.len) {
                const cluster = shaped[i].cluster;
                const seg_x0 = pen.*;
                const temp_cluster_idx: u32 = @intCast(clusters.items.len);
                const cluster_byte = piece_start + run.start + cluster;
                const cluster_kind: u8 = if (kinds) |kk|
                    (if (cluster_byte < kk.len) kk[cluster_byte] else 0)
                else
                    0;
                while (i < shaped.len and shaped[i].cluster == cluster) : (i += 1) {
                    const sg = shaped[i];
                    if (sg.glyph_id == 0) notdef += 1;
                    const g = self.book.glyphFor(run.face, sg.glyph_id) catch continue;
                    // Colour strikes carry an atlas-normalized advance
                    // (the hb advance is in strike units, not cell px).
                    const adv: f32 = if (g.colored)
                        g.advance
                    else
                        @as(f32, @floatFromInt(sg.x_advance)) / 64.0;
                    try glyphs.append(alloc, .{
                        .x = pen.* + @as(f32, @floatFromInt(sg.x_offset)) / 64.0,
                        .y_offset = @as(f32, @floatFromInt(sg.y_offset)) / 64.0,
                        .glyph = g,
                        .cluster_byte = cluster_byte,
                        .advance = adv,
                        .row = temp_cluster_idx,
                        .kind = cluster_kind,
                    });
                    pen.* += adv;
                }
                try clusters.append(alloc, .{
                    .byte_start = cluster_byte,
                    .byte_end = 0,
                    .x0 = seg_x0,
                    .x1 = pen.*,
                    .row = 0,
                });
            }
        }
        return .{ .runs = runs.len, .notdef = notdef };
    }

    // ---- hit testing --------------------------------------------------

    pub const CaretPos = struct { x: f32, row: u32 };

    /// Visual caret position (row-local x) for a byte offset within the
    /// line. Trailing-edge simplification: the caret sits at the visual
    /// LEFT edge of the cluster containing `byte`; byte == text.len maps
    /// to the last row's right edge.
    pub fn caretPos(ll: *const LaidLine, byte: usize) CaretPos {
        if (ll.clusters.len == 0) return .{ .x = 0, .row = 0 };
        if (byte >= ll.text.len) {
            const last = ll.rows[ll.rows.len - 1];
            return .{ .x = last.x1 - last.x0, .row = @intCast(ll.rows.len - 1) };
        }
        for (ll.clusters) |cl| {
            if (byte >= cl.byte_start and byte < cl.byte_end) {
                return .{ .x = cl.x0 - ll.rows[cl.row].x0, .row = cl.row };
            }
        }
        return .{ .x = 0, .row = 0 };
    }

    /// Midpoint x of the cluster containing `byte` (round-trip anchor
    /// for xToByte). Null when no cluster contains it.
    pub fn byteToX(ll: *const LaidLine, byte: usize) ?CaretPos {
        for (ll.clusters) |cl| {
            if (byte >= cl.byte_start and byte < cl.byte_end) {
                return .{ .x = (cl.x0 + cl.x1) * 0.5 - ll.rows[cl.row].x0, .row = cl.row };
            }
        }
        return null;
    }

    /// Row-local pixel x -> byte offset (always a grapheme boundary —
    /// clusters are grapheme-merged at build time). x past the row's
    /// last cluster maps to that cluster's byte_end.
    pub fn xToByte(ll: *const LaidLine, row: u32, x: f32) usize {
        if (ll.clusters.len == 0) return 0;
        const r = if (row < ll.rows.len) row else @as(u32, @intCast(ll.rows.len - 1));
        const xa = x + ll.rows[r].x0;
        var best: usize = 0;
        var best_dist: f32 = std.math.floatMax(f32);
        var row_last: ?Cluster = null;
        for (ll.clusters) |cl| {
            if (cl.row != r) continue;
            if (xa >= cl.x0 and xa < cl.x1) return cl.byte_start;
            if (row_last == null or cl.x1 > row_last.?.x1) row_last = cl;
            const mid = (cl.x0 + cl.x1) * 0.5;
            const d = @abs(xa - mid);
            if (d < best_dist) {
                best_dist = d;
                best = cl.byte_start;
            }
        }
        if (row_last) |rl| {
            if (xa >= rl.x1) return rl.byte_end;
        }
        return best;
    }
};

// ======================================================================
// Tests (font-gated — skip on fontless systems; no GL needed: the
// atlas rasterizes + packs without a realized texture)
// ======================================================================

const testing = std.testing;

const TestRig = struct {
    atlas: *Atlas,
    book: FontBook,
    layout: Layout,

    fn open(alloc: std.mem.Allocator) ?*TestRig {
        const path = atlas_mod.resolveFamilyPath(alloc, "DejaVu Sans") orelse
            atlas_mod.resolveFamilyPath(alloc, "Sans") orelse return null;
        defer alloc.free(path);
        const atlas = Atlas.init(alloc, path.ptr, 16) catch return null;
        const rig = alloc.create(TestRig) catch {
            atlas.deinit();
            return null;
        };
        rig.* = .{ .atlas = atlas, .book = FontBook.init(atlas), .layout = undefined };
        rig.layout = Layout.init(alloc, &rig.book);
        return rig;
    }

    fn close(self: *TestRig, alloc: std.mem.Allocator) void {
        self.layout.deinit();
        self.atlas.deinit();
        alloc.destroy(self);
    }
};

test "layout: tab advances to the next tab stop" {
    const a = testing.allocator;
    const rig = TestRig.open(a) orelse return error.SkipZigTest;
    defer rig.close(a);

    var doc = try Document.initFromBytes(a, "a\tb\tc");
    defer doc.deinit();
    const ll = try rig.layout.line(&doc, 0);

    const space_g = try rig.atlas.lookupOrLoad(' ', false, false);
    const tab_px = space_g.advance * 4.0;

    // Find the tab clusters (bytes 1 and 3): each must end exactly on
    // a tab-stop multiple and be non-degenerate.
    var found: usize = 0;
    for (ll.clusters) |cl| {
        if (cl.byte_start == 1 or cl.byte_start == 3) {
            found += 1;
            try testing.expect(cl.x1 > cl.x0);
            const stops = cl.x1 / tab_px;
            try testing.expectApproxEqAbs(@round(stops), stops, 0.01);
        }
    }
    try testing.expectEqual(@as(usize, 2), found);
}

test "layout: ASCII cluster map is monotone in bytes and x" {
    const a = testing.allocator;
    const rig = TestRig.open(a) orelse return error.SkipZigTest;
    defer rig.close(a);

    var doc = try Document.initFromBytes(a, "The quick brown fox");
    defer doc.deinit();
    const ll = try rig.layout.line(&doc, 0);
    try testing.expect(ll.clusters.len > 10);
    var prev_byte: u32 = 0;
    var prev_x: f32 = -1;
    for (ll.clusters, 0..) |cl, i| {
        if (i > 0) {
            try testing.expect(cl.byte_start > prev_byte);
            try testing.expect(cl.x0 >= prev_x);
        }
        try testing.expect(cl.byte_end > cl.byte_start);
        prev_byte = cl.byte_start;
        prev_x = cl.x0;
    }
    // byte -> x -> byte round-trips through every cluster.
    for (ll.clusters) |cl| {
        if (cl.x1 - cl.x0 < 0.01) continue;
        const p = Layout.byteToX(ll, cl.byte_start).?;
        try testing.expectEqual(@as(usize, cl.byte_start), Layout.xToByte(ll, p.row, p.x));
    }
}

test "layout: grapheme merge keeps carets out of combining clusters" {
    const a = testing.allocator;
    const rig = TestRig.open(a) orelse return error.SkipZigTest;
    defer rig.close(a);

    // e + COMBINING ACUTE + x: byte 1 is inside a grapheme.
    var doc = try Document.initFromBytes(a, "e\u{301}x");
    defer doc.deinit();
    const ll = try rig.layout.line(&doc, 0);
    for (ll.clusters) |cl| {
        try testing.expect(unicode.isGraphemeBoundary(ll.text, cl.byte_start));
    }
    // Any x across the line resolves to a grapheme boundary.
    var x: f32 = 0;
    while (x < ll.width + 4.0) : (x += 1.0) {
        const b = Layout.xToByte(ll, 0, x);
        try testing.expect(unicode.isGraphemeBoundary(ll.text, b));
        try testing.expect(b != 1);
    }
}

test "layout: cache invalidates on revision bump" {
    const a = testing.allocator;
    const rig = TestRig.open(a) orelse return error.SkipZigTest;
    defer rig.close(a);

    var doc = try Document.initFromBytes(a, "hello");
    defer doc.deinit();
    const ll1 = try rig.layout.line(&doc, 0);
    const n1 = ll1.clusters.len;
    const w1 = ll1.width;
    // Cached: identical pointer while the revision holds.
    try testing.expectEqual(@intFromPtr(ll1), @intFromPtr(try rig.layout.line(&doc, 0)));

    const tr = @import("../editor/transaction.zig");
    var tx = tr.Transaction.init(doc.revision);
    defer tx.deinit(a);
    try tx.addInsert(a, 5, " world");
    _ = try doc.applyTransaction(&tx);

    const ll2 = try rig.layout.line(&doc, 0);
    try testing.expectEqualStrings("hello world", ll2.text);
    try testing.expect(ll2.clusters.len > n1);
    try testing.expect(ll2.width > w1);
    try testing.expectEqual(doc.revision, ll2.revision);
}

test "layout: wrap segmentation covers the line and fits the width" {
    const a = testing.allocator;
    const rig = TestRig.open(a) orelse return error.SkipZigTest;
    defer rig.close(a);

    var doc = try Document.initFromBytes(a, "abcdefghijklmnopqrstuvwxyz0123456789");
    defer doc.deinit();
    rig.layout.wrap_width = 80;
    const ll = try rig.layout.line(&doc, 0);
    try testing.expect(ll.rows.len >= 2);
    // Rows tile the unwrapped x space and (except single-cluster rows)
    // fit the wrap width.
    var prev_x1: f32 = 0;
    for (ll.rows) |r| {
        try testing.expectApproxEqAbs(prev_x1, r.x0, 0.01);
        prev_x1 = r.x1;
    }
    // Cluster rows are non-decreasing and match their row's x range.
    var prev_row: u32 = 0;
    for (ll.clusters) |cl| {
        try testing.expect(cl.row >= prev_row);
        try testing.expect(cl.row < ll.rows.len);
        try testing.expect(cl.x1 - ll.rows[cl.row].x0 <= 80.0 + 0.01);
        prev_row = cl.row;
    }
    // Glyph rows agree with cluster rows.
    for (ll.glyphs) |g| {
        try testing.expect(g.row < ll.rows.len);
    }
}

test "layout: highlighted glyphs carry kinds and re-lay out on parse" {
    const a = testing.allocator;
    const rig = TestRig.open(a) orelse return error.SkipZigTest;
    defer rig.close(a);

    const src = "const x = 42;\n";
    var doc = try Document.initFromBytes(a, src);
    defer doc.deinit();
    var hl = try syntax.Highlighter.init(a, .zig);
    defer hl.deinit();

    // Attached but NOT yet parsed: the line lays out unhighlighted
    // rather than being blocked or mispainted.
    rig.layout.hl = &hl;
    const plain = try rig.layout.line(&doc, 0);
    try testing.expectEqual(@as(u64, 0), plain.hl_gen);
    for (plain.glyphs) |g| try testing.expectEqual(@as(u8, 0), g.kind);

    // The parse lands at the SAME revision — only the hl_gen key can
    // invalidate the cached line.
    try hl.parse(&doc);
    const lit = try rig.layout.line(&doc, 0);
    try testing.expect(lit.hl_gen != 0);
    try testing.expectEqual(doc.revision, lit.revision);

    var kw: usize = 0;
    var num: usize = 0;
    for (lit.glyphs) |g| {
        const kind: syntax.Kind = @enumFromInt(g.kind);
        if (g.cluster_byte < 5 and kind == .keyword) kw += 1;
        if (g.cluster_byte >= 10 and g.cluster_byte < 12 and kind == .number) num += 1;
    }
    try testing.expect(kw > 0);
    try testing.expect(num > 0);
}

test "layout: theme faces become itemization style spans" {
    const a = testing.allocator;
    const rig = TestRig.open(a) orelse return error.SkipZigTest;
    defer rig.close(a);

    // `const` is bold in the theme, the identifier after it is not, so
    // the piece must split into at least two shaping runs.
    const kinds = [_]u8{@intFromEnum(syntax.Kind.keyword)} ** 5 ++
        [_]u8{@intFromEnum(syntax.Kind.none)} ** 5;
    const spans = try rig.layout.styleSpansFor(&kinds);
    defer a.free(spans);
    try testing.expectEqual(@as(usize, 2), spans.len);
    try testing.expectEqual(@as(u32, 5), spans[0].end);
    try testing.expect(spans[0].bold);
    try testing.expectEqual(@as(u32, 10), spans[1].end);
    try testing.expect(!spans[1].bold);
    try testing.expect(!spans[1].italic);

    // Comments are italic in both built-in themes.
    const cm = [_]u8{@intFromEnum(syntax.Kind.comment)} ** 4;
    const cspans = try rig.layout.styleSpansFor(&cm);
    defer a.free(cspans);
    try testing.expectEqual(@as(usize, 1), cspans.len);
    try testing.expect(cspans[0].italic);
}

test "layout: empty line yields one empty row and caret at 0" {
    const a = testing.allocator;
    const rig = TestRig.open(a) orelse return error.SkipZigTest;
    defer rig.close(a);

    var doc = try Document.initFromBytes(a, "\nx");
    defer doc.deinit();
    const ll = try rig.layout.line(&doc, 0);
    try testing.expectEqual(@as(usize, 0), ll.clusters.len);
    try testing.expectEqual(@as(usize, 1), ll.rows.len);
    const cp = Layout.caretPos(ll, 0);
    try testing.expectEqual(@as(f32, 0), cp.x);
    try testing.expectEqual(@as(u32, 0), cp.row);
}
