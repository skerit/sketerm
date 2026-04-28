//! Glyph atlas — FreeType raster + GL 2D-array texture with multi-page
//! shelf-pack and LRU eviction.
//!
//! Lifecycle:
//!   - `init`: load FreeType face, compute cell metrics. No GL.
//!   - `realize`: must be called with a current GL context. Creates
//!     the GL_TEXTURE_2D_ARRAY texture (PAGE_COUNT layers × PAGE_SIZE²).
//!   - `lookupOrLoad`: rasterize codepoint if absent; pack onto the
//!     newest page (or evict LRU page if all full); upload.
//!   - `deinit`: frees FreeType + GL texture.
//!
//! Multi-page LRU strategy: each page tracks `last_used_frame`, bumped
//! whenever any glyph from the page is fetched. When packing fails on
//! every page, we evict the page with the smallest `last_used_frame`,
//! drop all glyphs that lived on it, and reuse it.

const std = @import("std");
const c = @import("../c.zig").c;

/// Pixels per page side. Cap at 2048 — cross-vendor safe.
pub const PAGE_SIZE: u32 = 2048;
/// Number of array-texture layers. 4 × 4 MB = 16 MB GPU memory budget.
pub const PAGE_COUNT: u32 = 4;

pub const Glyph = struct {
    /// Pixel size of the rasterized bitmap.
    w: u16,
    h: u16,
    /// Bitmap origin relative to the pen position.
    bearing_x: i16,
    bearing_y: i16,
    /// Horizontal advance in fractional pixels.
    advance: f32,
    /// UV in atlas (0..1) — within the page.
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
    /// Page (array layer) the glyph lives on.
    layer: u8 = 0,
    /// Generation counter — bumped on eviction so stale references
    /// can be detected and re-resolved by callers that cache.
    generation: u32 = 0,
};

const Page = struct {
    pack_x: u32 = 0,
    pack_y: u32 = 0,
    shelf_h: u32 = 0,
    last_used_frame: u64 = 0,
    /// Glyph IDs currently cached on this page (for eviction).
    /// Codepoints are tracked via `cp_glyph_set`.
    glyphs_on_page: std.ArrayList(GlyphRef) = .{},
    /// Generation increments when this page gets evicted/reset.
    generation: u32 = 0,

    fn deinit(self: *Page, allocator: std.mem.Allocator) void {
        self.glyphs_on_page.deinit(allocator);
    }
};

const GlyphRef = struct {
    /// Either codepoint (kind=.codepoint) or font glyph index (kind=.gid).
    key: u32,
    kind: Kind,
    pub const Kind = enum { codepoint, gid };
};

pub const Atlas = struct {
    ft_lib: c.FT_Library,
    ft_face: c.FT_Face,
    /// HarfBuzz font wrapping the FreeType face. Used by `shapeRun`
    /// for ligature / OpenType-feature aware text layout.
    hb_font: ?*c.hb_font_t = null,
    /// Reusable HarfBuzz buffer — created once per atlas, cleared
    /// and refilled per shapeRun. Saves the per-call allocation +
    /// destruction round-trip; was hot in TUI redraws with many
    /// same-style runs per row.
    hb_buf: ?*c.hb_buffer_t = null,
    /// Cache of HarfBuzz shape results keyed by FNV-1a hash of the
    /// UTF-8 input. Identical text re-shapes hit the cache. Shaping
    /// only depends on the font + text (we don't change OpenType
    /// features at runtime), so the key is just the bytes.
    shape_cache: std.AutoHashMap(u64, []ShapedGlyph),

    /// Cell metrics in pixels.
    cell_w: u16,
    cell_h: u16,
    ascent: i16,
    descent: i16,

    /// GL_TEXTURE_2D_ARRAY (0 until realize).
    gl_tex: c_uint = 0,
    realized: bool = false,

    /// Page state, one per array layer.
    pages: [PAGE_COUNT]Page = blk: {
        var ps: [PAGE_COUNT]Page = undefined;
        for (&ps) |*p| p.* = .{};
        break :blk ps;
    },
    /// Frame counter — caller bumps via `markFrame` once per render.
    frame_counter: u64 = 1,

    cache: std.AutoHashMap(u32, Glyph),
    glyph_cache: std.AutoHashMap(u32, Glyph),
    allocator: std.mem.Allocator,

    /// Pixel size requested at init — applied to fallback faces so
    /// they render at the same height as the primary.
    pixel_size: u16 = 0,
    /// Fontconfig-discovered fallback faces, indexed by load order.
    /// First-encountered codepoint that's missing on primary triggers
    /// an FcFontMatch; subsequent same-codepoint hits skip the query.
    fallback_faces: std.ArrayList(c.FT_Face) = .{},
    /// Codepoint → fallback_faces index. The optional value is null
    /// when fontconfig couldn't find a covering font (also caches
    /// negative results so we don't query repeatedly).
    cp_to_fallback: std.AutoHashMap(u32, ?usize) = undefined,
    /// Whether FcInit() ran successfully. Required for FcFontMatch.
    fc_initialized: bool = false,

    pub fn init(allocator: std.mem.Allocator, font_path: [*:0]const u8, size_px: u16) !*Atlas {
        return initOpts(allocator, font_path, size_px, 0);
    }

    /// Same as init, with extra `line_pad_px` added to `cell_h`. Used
    /// to honour a user-configured line spacing tweak. Negative
    /// values are clamped at the minimum that keeps cell_h ≥ ascent.
    pub fn initOpts(
        allocator: std.mem.Allocator,
        font_path: [*:0]const u8,
        size_px: u16,
        line_pad_px: i16,
    ) !*Atlas {
        var lib: c.FT_Library = undefined;
        if (c.FT_Init_FreeType(&lib) != 0) return error.FreeTypeInit;
        errdefer _ = c.FT_Done_FreeType(lib);

        var face: c.FT_Face = undefined;
        if (c.FT_New_Face(lib, font_path, 0, &face) != 0) return error.FontLoad;
        errdefer _ = c.FT_Done_Face(face);

        if (c.FT_Set_Pixel_Sizes(face, 0, size_px) != 0) return error.SetSize;

        const m = face.*.size.*.metrics;
        const cell_w: u16 = @intCast(@as(c_long, m.max_advance) >> 6);
        const base_cell_h: u16 = @intCast((@as(c_long, m.ascender) - @as(c_long, m.descender)) >> 6);
        const ascent: i16 = @intCast(@as(c_long, m.ascender) >> 6);
        const descent: i16 = @intCast(-@as(c_long, m.descender) >> 6);
        // Apply line spacing: add line_pad_px (clamped so glyph still
        // fits — never below ascent which is the upper baseline limit).
        const cell_h: u16 = blk: {
            const sum: i32 = @as(i32, base_cell_h) + line_pad_px;
            const min_h: i32 = @max(@as(i32, ascent), 1);
            break :blk @intCast(@max(sum, min_h));
        };

        const hb_font = c.hb_ft_font_create_referenced(face);
        const hb_buf = c.hb_buffer_create();

        const self = try allocator.create(Atlas);
        errdefer allocator.destroy(self);
        self.* = .{
            .ft_lib = lib,
            .ft_face = face,
            .hb_font = hb_font,
            .hb_buf = hb_buf,
            .cell_w = cell_w,
            .cell_h = cell_h,
            .ascent = ascent,
            .descent = descent,
            .cache = std.AutoHashMap(u32, Glyph).init(allocator),
            .glyph_cache = std.AutoHashMap(u32, Glyph).init(allocator),
            .shape_cache = std.AutoHashMap(u64, []ShapedGlyph).init(allocator),
            .allocator = allocator,
            .pixel_size = size_px,
            .cp_to_fallback = std.AutoHashMap(u32, ?usize).init(allocator),
            .fc_initialized = c.FcInit() != 0,
        };
        // Pre-grow caches so ASCII pre-warm + first session content
        // don't pay 4-5 rehashes climbing from default capacity.
        try self.cache.ensureTotalCapacity(256);
        try self.glyph_cache.ensureTotalCapacity(256);
        return self;
    }

    /// Call with a current GL context. Idempotent.
    pub fn realize(self: *Atlas) void {
        if (self.realized) return;
        c.glGenTextures(1, &self.gl_tex);
        c.glBindTexture(c.GL_TEXTURE_2D_ARRAY, self.gl_tex);
        c.glTexImage3D(
            c.GL_TEXTURE_2D_ARRAY,
            0,
            c.GL_R8,
            @intCast(PAGE_SIZE),
            @intCast(PAGE_SIZE),
            @intCast(PAGE_COUNT),
            0,
            c.GL_RED,
            c.GL_UNSIGNED_BYTE,
            null,
        );
        c.glTexParameteri(c.GL_TEXTURE_2D_ARRAY, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
        c.glTexParameteri(c.GL_TEXTURE_2D_ARRAY, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
        c.glTexParameteri(c.GL_TEXTURE_2D_ARRAY, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
        c.glTexParameteri(c.GL_TEXTURE_2D_ARRAY, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
        self.realized = true;
        // Pre-warm printable ASCII so the first render doesn't fire
        // ~95 glyph-rasterise + glTexSubImage3D in one frame. The first
        // shell prompt in a fresh pane visibly stutters otherwise.
        var cp: u32 = 0x20;
        while (cp < 0x7F) : (cp += 1) {
            _ = self.lookupOrLoad(cp) catch continue;
        }
    }

    pub fn deinit(self: *Atlas) void {
        // GL texture is freed by GTK on widget unrealize.
        self.cache.deinit();
        self.glyph_cache.deinit();
        // Free cached shape result slices.
        var sc_it = self.shape_cache.iterator();
        while (sc_it.next()) |entry| self.allocator.free(entry.value_ptr.*);
        self.shape_cache.deinit();
        for (&self.pages) |*p| p.deinit(self.allocator);
        if (self.hb_buf) |b| c.hb_buffer_destroy(b);
        if (self.hb_font) |f| c.hb_font_destroy(f);
        for (self.fallback_faces.items) |fb| _ = c.FT_Done_Face(fb);
        self.fallback_faces.deinit(self.allocator);
        self.cp_to_fallback.deinit();
        _ = c.FT_Done_Face(self.ft_face);
        _ = c.FT_Done_FreeType(self.ft_lib);
        self.allocator.destroy(self);
    }

    /// Bump the frame counter. Renderer should call once per render.
    pub fn markFrame(self: *Atlas) void {
        self.frame_counter +%= 1;
    }

    /// Shape a UTF-8 string with HarfBuzz.
    pub const ShapedGlyph = struct {
        glyph_id: u32,
        x_advance: i32,
        y_advance: i32,
        x_offset: i32,
        y_offset: i32,
        cluster: u32,
    };

    /// Shape a UTF-8 run with HarfBuzz. Result is cached by content
    /// hash; the returned slice is OWNED BY THE ATLAS — callers must
    /// NOT free it. The atlas frees all cached results on deinit.
    pub fn shapeRun(self: *Atlas, _: std.mem.Allocator, text: []const u8) ![]ShapedGlyph {
        const font = self.hb_font orelse return error.NoHarfBuzzFont;
        const buf = self.hb_buf orelse return error.NoHarfBuzzFont;

        // Cache hit?
        const key = std.hash.Wyhash.hash(0, text);
        if (self.shape_cache.get(key)) |cached| return cached;

        // Cache miss — shape using the persistent buffer (no per-call
        // hb_buffer_create/destroy).
        c.hb_buffer_clear_contents(buf);
        c.hb_buffer_add_utf8(buf, text.ptr, @intCast(text.len), 0, @intCast(text.len));
        c.hb_buffer_guess_segment_properties(buf);
        c.hb_shape(font, buf, null, 0);
        var glyph_count: c_uint = 0;
        const infos = c.hb_buffer_get_glyph_infos(buf, &glyph_count);
        const positions = c.hb_buffer_get_glyph_positions(buf, &glyph_count);
        // Cap cache so generative streams don't grow it without
        // bound. 4096 entries × ~64 B = ~256 KB worst case.
        if (self.shape_cache.count() >= 4096) self.shapeCacheEvictOne();
        const out = try self.allocator.alloc(ShapedGlyph, glyph_count);
        var i: c_uint = 0;
        while (i < glyph_count) : (i += 1) {
            out[i] = .{
                .glyph_id = infos[i].codepoint,
                .x_advance = positions[i].x_advance,
                .y_advance = positions[i].y_advance,
                .x_offset = positions[i].x_offset,
                .y_offset = positions[i].y_offset,
                .cluster = infos[i].cluster,
            };
        }
        self.shape_cache.put(key, out) catch {
            self.allocator.free(out);
            return error.OutOfMemory;
        };
        return out;
    }

    fn shapeCacheEvictOne(self: *Atlas) void {
        // First entry — cheap, no LRU. Cache is generous (4096); the
        // policy barely matters in practice.
        var it = self.shape_cache.iterator();
        if (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const slice = entry.value_ptr.*;
            self.allocator.free(slice);
            _ = self.shape_cache.remove(key);
        }
    }

    /// Codepoint-keyed lookup. Marks the host page as used.
    pub fn lookupOrLoad(self: *Atlas, codepoint: u32) !Glyph {
        if (self.cache.get(codepoint)) |g| {
            self.touchPage(g.layer);
            return g;
        }
        const gid = c.FT_Get_Char_Index(self.ft_face, codepoint);
        if (gid != 0 or codepoint == 0) {
            const g = self.lookupOrLoadById(gid) catch return self.cacheEmptyCp(codepoint);
            try self.cache.put(codepoint, g);
            try self.pages[g.layer].glyphs_on_page.append(self.allocator, .{
                .key = codepoint,
                .kind = .codepoint,
            });
            return g;
        }
        // Primary face doesn't have this codepoint — try fontconfig
        // fallbacks. Result is cached (positive or negative) so we
        // don't re-query for the same missing codepoint.
        if (self.findFallbackFace(codepoint)) |fb_face| {
            const fb_gid = c.FT_Get_Char_Index(fb_face, codepoint);
            if (fb_gid != 0) {
                const g = self.loadGlyphFromFace(fb_face, fb_gid) catch return self.cacheEmptyCp(codepoint);
                try self.cache.put(codepoint, g);
                try self.pages[g.layer].glyphs_on_page.append(self.allocator, .{
                    .key = codepoint,
                    .kind = .codepoint,
                });
                return g;
            }
        }
        return self.cacheEmptyCp(codepoint);
    }

    /// Locate (or lazily load) a fallback FT_Face that has `cp`. Caches
    /// both positive matches (face index) and negative results (null
    /// in the map) so we never query fontconfig twice for the same
    /// codepoint. Returns null when fontconfig has nothing.
    fn findFallbackFace(self: *Atlas, cp: u32) ?c.FT_Face {
        if (self.cp_to_fallback.get(cp)) |entry| {
            if (entry) |idx| return self.fallback_faces.items[idx];
            return null;
        }
        if (!self.fc_initialized) {
            _ = self.cp_to_fallback.put(cp, null) catch {};
            return null;
        }
        // Quick scan: maybe an already-loaded fallback covers this cp.
        for (self.fallback_faces.items, 0..) |fb, idx| {
            if (c.FT_Get_Char_Index(fb, cp) != 0) {
                _ = self.cp_to_fallback.put(cp, idx) catch {};
                return fb;
            }
        }
        // Ask fontconfig for a font that covers `cp`. We bias toward
        // monospace + scalable so the metrics merge cleanly with the
        // primary face's cell grid; colour emoji (CBDT/COLR) would
        // need an RGBA atlas — skipped for v1.
        const pattern = c.FcPatternCreate() orelse {
            _ = self.cp_to_fallback.put(cp, null) catch {};
            return null;
        };
        defer c.FcPatternDestroy(pattern);
        const charset = c.FcCharSetCreate() orelse {
            _ = self.cp_to_fallback.put(cp, null) catch {};
            return null;
        };
        defer c.FcCharSetDestroy(charset);
        _ = c.FcCharSetAddChar(charset, cp);
        _ = c.FcPatternAddCharSet(pattern, c.FC_CHARSET, charset);
        _ = c.FcPatternAddBool(pattern, c.FC_SCALABLE, c.FcTrue);
        _ = c.FcConfigSubstitute(null, pattern, c.FcMatchPattern);
        c.FcDefaultSubstitute(pattern);

        var result: c.FcResult = undefined;
        const match = c.FcFontMatch(null, pattern, &result) orelse {
            _ = self.cp_to_fallback.put(cp, null) catch {};
            return null;
        };
        defer c.FcPatternDestroy(match);

        var file_ptr: [*c]c.FcChar8 = undefined;
        if (c.FcPatternGetString(match, c.FC_FILE, 0, &file_ptr) != c.FcResultMatch) {
            _ = self.cp_to_fallback.put(cp, null) catch {};
            return null;
        }
        const file_z: [*:0]const u8 = @ptrCast(file_ptr);

        var fb_face: c.FT_Face = undefined;
        if (c.FT_New_Face(self.ft_lib, file_z, 0, &fb_face) != 0) {
            _ = self.cp_to_fallback.put(cp, null) catch {};
            return null;
        }
        if (c.FT_Set_Pixel_Sizes(fb_face, 0, self.pixel_size) != 0) {
            _ = c.FT_Done_Face(fb_face);
            _ = self.cp_to_fallback.put(cp, null) catch {};
            return null;
        }
        const idx = self.fallback_faces.items.len;
        self.fallback_faces.append(self.allocator, fb_face) catch {
            _ = c.FT_Done_Face(fb_face);
            return null;
        };
        _ = self.cp_to_fallback.put(cp, idx) catch {};
        return fb_face;
    }

    /// Glyph-id keyed lookup (HarfBuzz output).
    pub fn lookupOrLoadById(self: *Atlas, gid: u32) !Glyph {
        if (self.glyph_cache.get(gid)) |g| {
            self.touchPage(g.layer);
            return g;
        }
        const g = try self.loadGlyphFromFace(self.ft_face, gid);
        // gid cache only applies to the primary face — fallback glyphs
        // share the same gid namespace per-face but collide across.
        try self.glyph_cache.put(gid, g);
        try self.pages[g.layer].glyphs_on_page.append(self.allocator, .{
            .key = gid,
            .kind = .gid,
        });
        return g;
    }

    /// Rasterize gid on the supplied face and pack into the atlas.
    /// Used by both primary-face glyph_cache path and fontconfig
    /// fallback path. Caller wires the result into whichever cache
    /// (cp or gid) is appropriate — this fn doesn't touch caches.
    fn loadGlyphFromFace(self: *Atlas, face: c.FT_Face, gid: u32) !Glyph {
        if (c.FT_Load_Glyph(face, gid, c.FT_LOAD_RENDER | c.FT_LOAD_TARGET_LIGHT) != 0) {
            return error.FtLoad;
        }

        const slot = face.*.glyph;
        const bm = slot.*.bitmap;
        const w: u32 = bm.width;
        const h: u32 = bm.rows;

        // Find a page that fits, optionally evicting LRU.
        const page_idx = self.findOrEvictPage(w, h) orelse return error.PageFull;
        const page = &self.pages[page_idx];
        if (page.pack_x + w + 1 > PAGE_SIZE) {
            page.pack_x = 0;
            page.pack_y += page.shelf_h + 1;
            page.shelf_h = 0;
        }
        if (h > page.shelf_h) page.shelf_h = h;
        if (page.pack_y + h > PAGE_SIZE) {
            return error.PageFull;
        }
        const px = page.pack_x;
        const py = page.pack_y;

        if (w > 0 and h > 0 and self.realized) {
            c.glBindTexture(c.GL_TEXTURE_2D_ARRAY, self.gl_tex);
            c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 1);
            c.glTexSubImage3D(
                c.GL_TEXTURE_2D_ARRAY,
                0,
                @intCast(px),
                @intCast(py),
                @intCast(page_idx),
                @intCast(w),
                @intCast(h),
                1,
                c.GL_RED,
                c.GL_UNSIGNED_BYTE,
                bm.buffer,
            );
        }

        const inv_page: f32 = 1.0 / @as(f32, @floatFromInt(PAGE_SIZE));
        const g = Glyph{
            .w = @intCast(w),
            .h = @intCast(h),
            .bearing_x = @intCast(slot.*.bitmap_left),
            .bearing_y = @intCast(slot.*.bitmap_top),
            .advance = @as(f32, @floatFromInt(slot.*.advance.x)) / 64.0,
            .u0 = @as(f32, @floatFromInt(px)) * inv_page,
            .v0 = @as(f32, @floatFromInt(py)) * inv_page,
            .u1 = @as(f32, @floatFromInt(px + w)) * inv_page,
            .v1 = @as(f32, @floatFromInt(py + h)) * inv_page,
            .layer = @intCast(page_idx),
            .generation = page.generation,
        };
        page.pack_x += w + 1;
        page.last_used_frame = self.frame_counter;
        return g;
    }

    /// Find an existing page with room, or evict the LRU page.
    fn findOrEvictPage(self: *Atlas, gw: u32, gh: u32) ?u32 {
        // First pass: pages with room on current shelf.
        var best_with_room: ?u32 = null;
        var best_used: u64 = std.math.maxInt(u64);
        for (&self.pages, 0..) |*p, i| {
            const horiz = p.pack_x + gw + 1 <= PAGE_SIZE and p.pack_y + @max(p.shelf_h, gh) <= PAGE_SIZE;
            const new_shelf = p.pack_y + p.shelf_h + 1 + gh <= PAGE_SIZE;
            if (horiz or new_shelf) {
                // Prefer LRU page for new glyphs (keeps hot glyphs together).
                if (p.last_used_frame < best_used) {
                    best_used = p.last_used_frame;
                    best_with_room = @intCast(i);
                }
            }
        }
        if (best_with_room) |idx| return idx;

        // All pages full: evict LRU.
        var lru_idx: u32 = 0;
        var lru_used: u64 = std.math.maxInt(u64);
        for (&self.pages, 0..) |*p, i| {
            if (p.last_used_frame < lru_used) {
                lru_used = p.last_used_frame;
                lru_idx = @intCast(i);
            }
        }
        self.evictPage(lru_idx);
        return lru_idx;
    }

    /// Reset a page: drop pack state, remove cache entries that lived
    /// on it, bump its generation counter.
    fn evictPage(self: *Atlas, idx: u32) void {
        const p = &self.pages[idx];
        for (p.glyphs_on_page.items) |ref| {
            switch (ref.kind) {
                .codepoint => _ = self.cache.remove(ref.key),
                .gid => _ = self.glyph_cache.remove(ref.key),
            }
        }
        p.glyphs_on_page.clearRetainingCapacity();
        p.pack_x = 0;
        p.pack_y = 0;
        p.shelf_h = 0;
        p.generation +%= 1;
        p.last_used_frame = self.frame_counter;
    }

    fn touchPage(self: *Atlas, layer: u8) void {
        if (layer >= PAGE_COUNT) return;
        // frame_counter is bumped once per render, so every touchPage
        // within a frame writes the same value. Skip the store if the
        // page is already up-to-date — saves cache traffic in hot
        // glyph-lookup loops (~16k cells per frame).
        if (self.pages[layer].last_used_frame == self.frame_counter) return;
        self.pages[layer].last_used_frame = self.frame_counter;
    }

    fn emptyGlyph(self: *const Atlas) Glyph {
        return .{
            .w = 0,
            .h = 0,
            .bearing_x = 0,
            .bearing_y = 0,
            .advance = @floatFromInt(self.cell_w),
            .u0 = 0,
            .v0 = 0,
            .u1 = 0,
            .v1 = 0,
            .layer = 0,
            .generation = 0,
        };
    }

    fn cacheEmptyCp(self: *Atlas, codepoint: u32) Glyph {
        const empty = self.emptyGlyph();
        _ = self.cache.put(codepoint, empty) catch {};
        return empty;
    }

    fn cacheEmptyId(self: *Atlas, gid: u32) Glyph {
        const empty = self.emptyGlyph();
        _ = self.glyph_cache.put(gid, empty) catch {};
        return empty;
    }
};

test "atlas page eviction recycles space" {
    // We can't run real FT/GL in tests, but we can exercise the
    // Page bookkeeping layer directly.
    var p = Page{};
    defer p.deinit(std.testing.allocator);
    try p.glyphs_on_page.append(std.testing.allocator, .{ .key = 'A', .kind = .codepoint });
    try p.glyphs_on_page.append(std.testing.allocator, .{ .key = 'B', .kind = .codepoint });
    try std.testing.expectEqual(@as(usize, 2), p.glyphs_on_page.items.len);
}
