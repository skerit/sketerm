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
/// Number of array-texture layers. RGBA8: 4 × 16 MB = 64 MB GPU budget.
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
    /// True for color (emoji) glyphs: atlas texels carry actual RGBA;
    /// the shader samples them directly instead of tinting coverage
    /// with the cell fg.
    colored: bool = false,
};

const Page = struct {
    pack_x: u32 = 0,
    pack_y: u32 = 0,
    shelf_h: u32 = 0,
    last_used_frame: u64 = 0,
    /// Glyph IDs currently cached on this page (for eviction).
    /// Codepoints are tracked via `cp_glyph_set`.
    glyphs_on_page: std.ArrayList(GlyphRef) = .empty,
    /// Generation increments when this page gets evicted/reset.
    generation: u32 = 0,

    fn deinit(self: *Page, allocator: std.mem.Allocator) void {
        self.glyphs_on_page.deinit(allocator);
    }
};

const GlyphRef = struct {
    /// Either codepoint (kind=.codepoint) or font glyph index (kind=.gid),
    /// with `BOLD_KEY_BIT` OR-ed in for bold variants — the same encoding
    /// the `cache` / `glyph_cache` maps use, so eviction removes the right
    /// entry without a separate bold flag.
    key: u32,
    kind: Kind,
    pub const Kind = enum { codepoint, gid };
};

/// Bold / italic glyphs share the `cache` / `glyph_cache` maps with
/// their regular counterparts, distinguished by these high bits in the
/// key. Codepoints top out at 0x10FFFF (~2^21) and font glyph indices
/// fit in a face's glyph count (< 2^16 for any sfnt), so bits 29/30
/// are always free.
const BOLD_KEY_BIT: u32 = 0x4000_0000;
const ITALIC_KEY_BIT: u32 = 0x2000_0000;

fn styleKey(base: u32, bold: bool, italic: bool) u32 {
    var key = base;
    if (bold) key |= BOLD_KEY_BIT;
    if (italic) key |= ITALIC_KEY_BIT;
    return key;
}

/// Resolve a font family name ("JetBrains Mono") to a file path via
/// fontconfig. Returned slice is allocated with `allocator`; caller
/// frees. Note fontconfig substitutes rather than failing: an unknown
/// family resolves to the system default monospace-ish match.
pub fn resolveFamilyPath(allocator: std.mem.Allocator, family: []const u8) ?[:0]u8 {
    if (family.len == 0) return null;
    if (c.FcInit() == 0) return null;
    const fam_z = allocator.allocSentinel(u8, family.len, 0) catch return null;
    defer allocator.free(fam_z);
    @memcpy(fam_z, family);

    const pattern = c.FcPatternCreate() orelse return null;
    defer c.FcPatternDestroy(pattern);
    _ = c.FcPatternAddString(pattern, c.FC_FAMILY, @ptrCast(fam_z.ptr));
    _ = c.FcPatternAddInteger(pattern, c.FC_WEIGHT, c.FC_WEIGHT_REGULAR);
    _ = c.FcPatternAddInteger(pattern, c.FC_SLANT, c.FC_SLANT_ROMAN);
    _ = c.FcPatternAddBool(pattern, c.FC_SCALABLE, c.FcTrue);
    _ = c.FcConfigSubstitute(null, pattern, c.FcMatchPattern);
    c.FcDefaultSubstitute(pattern);

    var result: c.FcResult = undefined;
    const match = c.FcFontMatch(null, pattern, &result) orelse return null;
    defer c.FcPatternDestroy(match);

    var file_ptr: [*c]c.FcChar8 = undefined;
    if (c.FcPatternGetString(match, c.FC_FILE, 0, &file_ptr) != c.FcResultMatch) return null;
    const span = std.mem.span(@as([*:0]const u8, @ptrCast(file_ptr)));
    return allocator.dupeZ(u8, span) catch null;
}

pub const Atlas = struct {
    ft_lib: c.FT_Library,
    ft_face: c.FT_Face,
    /// The font's real bold face (fontconfig match of the primary
    /// family at bold weight), or null when the family ships no bold
    /// variant — in which case `synthesize_bold` is set and bold glyphs
    /// are produced by FreeType outline-embolden of the regular face.
    ft_face_bold: ?c.FT_Face = null,
    /// True when there is no real bold face and bold must be synthesized
    /// via `FT_Outline_Embolden` on the regular (or fallback) face.
    synthesize_bold: bool = true,
    /// Real italic / bold-italic faces (fontconfig matches of the
    /// primary family), or null — italic then degrades to the shader
    /// shear and bold-italic to italic-face + embolden (or bold face
    /// + shear, or regular + both).
    ft_face_italic: ?c.FT_Face = null,
    ft_face_bold_italic: ?c.FT_Face = null,
    /// HarfBuzz font wrapping the FreeType face. Used by `shapeRun`
    /// for ligature / OpenType-feature aware text layout.
    hb_font: ?*c.hb_font_t = null,
    /// HarfBuzz font over `ft_face_bold`, for shaping bold ligature
    /// runs (their glyph ids live in the bold face's namespace). Null
    /// when there is no real bold face.
    hb_font_bold: ?*c.hb_font_t = null,
    hb_font_italic: ?*c.hb_font_t = null,
    hb_font_bold_italic: ?*c.hb_font_t = null,
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

    /// OpenType features applied to every hb_shape call. Parsed once
    /// by setFontFeatures; rare enough that a fixed array suffices.
    features: [16]c.hb_feature_t = undefined,
    n_features: usize = 0,

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
    fallback_faces: std.ArrayList(c.FT_Face) = .empty,
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

        const fc_ok = c.FcInit() != 0;
        // Resolve real bold / italic / bold-italic faces up front
        // (best quality). Missing variants degrade to synthesis:
        // outline-embolden for bold, shader shear for italic.
        const bold_face = if (fc_ok) loadVariantFace(lib, face, font_path, size_px, c.FC_WEIGHT_BOLD, c.FC_SLANT_ROMAN) else null;
        const italic_face = if (fc_ok) loadVariantFace(lib, face, font_path, size_px, c.FC_WEIGHT_REGULAR, c.FC_SLANT_ITALIC) else null;
        const bold_italic_face = if (fc_ok) loadVariantFace(lib, face, font_path, size_px, c.FC_WEIGHT_BOLD, c.FC_SLANT_ITALIC) else null;
        const hb_font_bold = if (bold_face) |bf| c.hb_ft_font_create_referenced(bf) else null;
        const hb_font_italic = if (italic_face) |f| c.hb_ft_font_create_referenced(f) else null;
        const hb_font_bold_italic = if (bold_italic_face) |f| c.hb_ft_font_create_referenced(f) else null;

        const self = try allocator.create(Atlas);
        errdefer allocator.destroy(self);
        self.* = .{
            .ft_lib = lib,
            .ft_face = face,
            .ft_face_bold = bold_face,
            .synthesize_bold = bold_face == null,
            .ft_face_italic = italic_face,
            .ft_face_bold_italic = bold_italic_face,
            .hb_font = hb_font,
            .hb_font_bold = hb_font_bold,
            .hb_font_italic = hb_font_italic,
            .hb_font_bold_italic = hb_font_bold_italic,
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
            .fc_initialized = fc_ok,
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
        // RGBA so colour emoji (CBDT/sbix strikes) can live alongside
        // monochrome glyphs. Mono coverage is stored in alpha with
        // RGB=255 — shaders tint with the cell fg; colour glyphs carry
        // straight (un-premultiplied) RGBA sampled directly.
        c.glTexImage3D(
            c.GL_TEXTURE_2D_ARRAY,
            0,
            c.GL_RGBA8,
            @intCast(PAGE_SIZE),
            @intCast(PAGE_SIZE),
            @intCast(PAGE_COUNT),
            0,
            c.GL_RGBA,
            c.GL_UNSIGNED_BYTE,
            null,
        );
        // Explicitly zero every page. glTexImage3D with a NULL pointer
        // leaves contents *undefined* per the GL ES 3.0 spec — most
        // drivers happen to clear, but AMD/radeonsi has been observed
        // to leave residual data in the inter-glyph padding strips
        // (`pack_x += w + 1` reserves 1 texel between glyphs but never
        // writes it). The faux-bold path in cell_pass samples one
        // texel to the LEFT of each glyph, and at the leftmost column
        // that lands inside that padding strip — undefined memory there
        // shows up as a faint vertical line on the left of every bold
        // narrow glyph (`i`, `l`, `v`). Zero-filling once at realize
        // costs ~64 MB of TexSubImage3D up front and fixes it.
        const zero = self.allocator.alloc(u8, PAGE_SIZE * PAGE_SIZE * 4) catch null;
        defer if (zero) |z| self.allocator.free(z);
        if (zero) |z| {
            @memset(z, 0);
            c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 1);
            var layer: c_int = 0;
            while (layer < PAGE_COUNT) : (layer += 1) {
                c.glTexSubImage3D(
                    c.GL_TEXTURE_2D_ARRAY,
                    0,
                    0,
                    0,
                    layer,
                    @intCast(PAGE_SIZE),
                    @intCast(PAGE_SIZE),
                    1,
                    c.GL_RGBA,
                    c.GL_UNSIGNED_BYTE,
                    z.ptr,
                );
            }
        }
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
            _ = self.lookupOrLoad(cp, false, false) catch continue;
        }
    }

    pub fn deinit(self: *Atlas) void {
        // GL texture is NOT freed here — by design, atlas can be
        // deinit-ed without a current GL context (e.g. from Pane
        // teardown after the GLArea has been unrealized). Use
        // `releaseGL` from the pane's `unrealize` handler, or
        // `glDeleteTextures` manually before deinit, when a context
        // is current.
        self.cache.deinit();
        self.glyph_cache.deinit();
        // Free cached shape result slices.
        var sc_it = self.shape_cache.iterator();
        while (sc_it.next()) |entry| self.allocator.free(entry.value_ptr.*);
        self.shape_cache.deinit();
        for (&self.pages) |*p| p.deinit(self.allocator);
        if (self.hb_buf) |b| c.hb_buffer_destroy(b);
        if (self.hb_font) |f| c.hb_font_destroy(f);
        if (self.hb_font_bold) |f| c.hb_font_destroy(f);
        if (self.hb_font_italic) |f| c.hb_font_destroy(f);
        if (self.hb_font_bold_italic) |f| c.hb_font_destroy(f);
        for (self.fallback_faces.items) |fb| _ = c.FT_Done_Face(fb);
        self.fallback_faces.deinit(self.allocator);
        self.cp_to_fallback.deinit();
        if (self.ft_face_bold) |bf| _ = c.FT_Done_Face(bf);
        if (self.ft_face_italic) |f| _ = c.FT_Done_Face(f);
        if (self.ft_face_bold_italic) |f| _ = c.FT_Done_Face(f);
        _ = c.FT_Done_Face(self.ft_face);
        _ = c.FT_Done_FreeType(self.ft_lib);
        self.allocator.destroy(self);
    }

    /// Free the GL texture under a still-current GL context. Call
    /// from the pane's `unrealize` handler before `deinit`. Sets
    /// `realized=false` so subsequent calls are no-ops.
    pub fn releaseGL(self: *Atlas) void {
        if (self.realized and self.gl_tex != 0) {
            c.glDeleteTextures(1, &self.gl_tex);
            self.gl_tex = 0;
        }
        self.realized = false;
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
    pub fn shapeRun(self: *Atlas, _: std.mem.Allocator, text: []const u8, bold: bool, italic: bool) ![]ShapedGlyph {
        // A styled run shapes with the matching HarfBuzz font so its
        // glyph ids land in that face's namespace. With no real styled
        // face we shape with the regular font (gids stay regular and
        // are emboldened/sheared at raster/draw time), so the cache key
        // must NOT be style-tagged then — else identical text would
        // shape twice for one result. The key tag must mirror the face
        // styledFace() will pick at glyph-load time.
        const sf = self.styledFace(bold, italic);
        const font = (sf.hb orelse self.hb_font) orelse return error.NoHarfBuzzFont;
        const buf = self.hb_buf orelse return error.NoHarfBuzzFont;

        // Cache hit?
        var key = std.hash.Wyhash.hash(0, text);
        if (font == self.hb_font_bold) key ^= 0x9E37_79B9_7F4A_7C15;
        if (font == self.hb_font_italic) key ^= 0x5851_F42D_4C95_7F2D;
        if (font == self.hb_font_bold_italic) key ^= 0x2545_F491_4F6C_DD1D;
        if (self.shape_cache.get(key)) |cached| return cached;

        // Cache miss — shape using the persistent buffer (no per-call
        // hb_buffer_create/destroy).
        c.hb_buffer_clear_contents(buf);
        c.hb_buffer_add_utf8(buf, text.ptr, @intCast(text.len), 0, @intCast(text.len));
        c.hb_buffer_guess_segment_properties(buf);
        c.hb_shape(font, buf, if (self.n_features > 0) &self.features else null, @intCast(self.n_features));
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

    /// Parse a whitespace/comma-separated OpenType feature spec
    /// ("-calt +ss01 zero cv05=3", CSS/kitty syntax accepted by
    /// hb_feature_from_string). Unparseable tokens are skipped; at
    /// most 16 features stick. Clears the shape cache — cached runs
    /// were shaped under the old feature set.
    pub fn setFontFeatures(self: *Atlas, spec: []const u8) void {
        self.n_features = 0;
        var it = std.mem.tokenizeAny(u8, spec, " \t,");
        while (it.next()) |tok| {
            if (self.n_features >= self.features.len) break;
            var feat: c.hb_feature_t = undefined;
            if (c.hb_feature_from_string(tok.ptr, @intCast(tok.len), &feat) != 0) {
                self.features[self.n_features] = feat;
                self.n_features += 1;
            }
        }
        self.clearShapeCache();
    }

    fn clearShapeCache(self: *Atlas) void {
        var it = self.shape_cache.iterator();
        while (it.next()) |entry| self.allocator.free(entry.value_ptr.*);
        self.shape_cache.clearRetainingCapacity();
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

    /// Codepoint-keyed lookup. Marks the host page as used. When `bold`
    /// / `italic` are set, the glyph is drawn from the matching real
    /// face (or synthesized: embolden for bold; italic without a real
    /// face is sheared by the renderer) and cached under a style-tagged
    /// key.
    pub fn lookupOrLoad(self: *Atlas, codepoint: u32, bold: bool, italic: bool) !Glyph {
        const key = styleKey(codepoint, bold, italic);
        if (self.cache.get(key)) |g| {
            self.touchPage(g.layer);
            return g;
        }
        const sf = self.styledFace(bold, italic);
        const gid = c.FT_Get_Char_Index(sf.face, codepoint);
        if (gid != 0 or codepoint == 0) {
            const g = self.loadGlyphFromFace(sf.face, gid, sf.embolden) catch return self.cacheEmpty(key);
            try self.cache.put(key, g);
            try self.pages[g.layer].glyphs_on_page.append(self.allocator, .{
                .key = key,
                .kind = .codepoint,
            });
            return g;
        }
        // Styled face doesn't have this codepoint — try the regular
        // face before fontconfig fallbacks (an italic variant can ship
        // fewer glyphs than its regular sibling).
        if (sf.face != self.ft_face) {
            const reg_gid = c.FT_Get_Char_Index(self.ft_face, codepoint);
            if (reg_gid != 0) {
                const g = self.loadGlyphFromFace(self.ft_face, reg_gid, bold) catch return self.cacheEmpty(key);
                try self.cache.put(key, g);
                try self.pages[g.layer].glyphs_on_page.append(self.allocator, .{
                    .key = key,
                    .kind = .codepoint,
                });
                return g;
            }
        }
        // Fontconfig fallbacks. Result is cached (positive or negative)
        // so we don't re-query for the same missing codepoint. Styled
        // fallback glyphs are always synthesized (fallback faces rarely
        // ship matching variants).
        if (self.findFallbackFace(codepoint)) |fb_face| {
            const fb_gid = c.FT_Get_Char_Index(fb_face, codepoint);
            if (fb_gid != 0) {
                const g = self.loadGlyphFromFace(fb_face, fb_gid, bold) catch return self.cacheEmpty(key);
                try self.cache.put(key, g);
                try self.pages[g.layer].glyphs_on_page.append(self.allocator, .{
                    .key = key,
                    .kind = .codepoint,
                });
                return g;
            }
        }
        return self.cacheEmpty(key);
    }

    /// Best-effort negative caching: under allocation pressure we may
    /// re-query fontconfig, but correctness is preserved.
    fn markNoFallback(self: *Atlas, cp: u32) void {
        _ = self.cp_to_fallback.put(cp, null) catch {};
    }

    /// Codepoints whose fontconfig fallback should prefer a colour
    /// (emoji) font over a scalable monochrome one. Covers the emoji
    /// blocks plus the handful of emoji-presentation symbols outside
    /// them (watch, hourglass, media controls, misc symbols, dingbats).
    fn isEmojiCp(cp: u32) bool {
        return switch (cp) {
            0x1F000...0x1FAFF => true, // mahjong..symbols-extended-A (incl. emoticons, transport, flags)
            0x2600...0x27BF => true, // misc symbols + dingbats
            0x231A, 0x231B => true, // watch, hourglass
            0x23E9...0x23FA => true, // media controls, alarm clock
            0x25FD, 0x25FE => true, // small squares
            0x2B05...0x2B07, 0x2B1B, 0x2B1C, 0x2B50, 0x2B55 => true,
            else => false,
        };
    }

    /// Apply `px` to a face. Scalable faces use FT_Set_Pixel_Sizes;
    /// fixed-strike (bitmap, e.g. CBDT emoji) faces select the nearest
    /// available strike instead — the rasterized bitmap is rescaled to
    /// cell size at glyph-load time.
    fn setFaceSize(face: c.FT_Face, px: u16) bool {
        if (c.FT_Set_Pixel_Sizes(face, 0, px) == 0) return true;
        const n = face.*.num_fixed_sizes;
        if (n <= 0 or face.*.available_sizes == null) return false;
        var best: c_int = 0;
        var best_diff: u64 = std.math.maxInt(u64);
        var i: c_int = 0;
        while (i < n) : (i += 1) {
            const h: i64 = @intCast(face.*.available_sizes[@intCast(i)].height);
            const diff: u64 = @abs(h - @as(i64, px));
            if (diff < best_diff) {
                best_diff = diff;
                best = i;
            }
        }
        return c.FT_Select_Size(face, best) == 0;
    }

    /// Locate (or lazily load) a fallback FT_Face that has `cp`. Caches
    /// both positive matches (face index) and negative results (null
    /// in the map). Best-effort negative caching: under allocation
    /// pressure we may re-query fontconfig, but correctness is
    /// preserved. Returns null when fontconfig has nothing.
    fn findFallbackFace(self: *Atlas, cp: u32) ?c.FT_Face {
        if (self.cp_to_fallback.get(cp)) |entry| {
            if (entry) |idx| return self.fallback_faces.items[idx];
            return null;
        }
        if (!self.fc_initialized) {
            self.markNoFallback(cp);
            return null;
        }
        // Quick scan: maybe an already-loaded fallback covers this cp.
        for (self.fallback_faces.items, 0..) |fb, idx| {
            if (c.FT_Get_Char_Index(fb, cp) != 0) {
                _ = self.cp_to_fallback.put(cp, idx) catch {};
                return fb;
            }
        }
        // Ask fontconfig for a font that covers `cp`. For regular text
        // we bias toward scalable faces so the metrics merge cleanly
        // with the primary face's cell grid. For emoji codepoints we
        // instead prefer a colour font (CBDT/sbix — e.g. Noto Color
        // Emoji); its fixed-size strikes are rescaled at load.
        const pattern = c.FcPatternCreate() orelse {
            self.markNoFallback(cp);
            return null;
        };
        defer c.FcPatternDestroy(pattern);
        const charset = c.FcCharSetCreate() orelse {
            self.markNoFallback(cp);
            return null;
        };
        defer c.FcCharSetDestroy(charset);
        _ = c.FcCharSetAddChar(charset, cp);
        _ = c.FcPatternAddCharSet(pattern, c.FC_CHARSET, charset);
        if (isEmojiCp(cp)) {
            _ = c.FcPatternAddBool(pattern, c.FC_COLOR, c.FcTrue);
        } else {
            _ = c.FcPatternAddBool(pattern, c.FC_SCALABLE, c.FcTrue);
        }
        _ = c.FcConfigSubstitute(null, pattern, c.FcMatchPattern);
        c.FcDefaultSubstitute(pattern);

        var result: c.FcResult = undefined;
        const match = c.FcFontMatch(null, pattern, &result) orelse {
            self.markNoFallback(cp);
            return null;
        };
        defer c.FcPatternDestroy(match);

        var file_ptr: [*c]c.FcChar8 = undefined;
        if (c.FcPatternGetString(match, c.FC_FILE, 0, &file_ptr) != c.FcResultMatch) {
            self.markNoFallback(cp);
            return null;
        }
        const file_z: [*:0]const u8 = @ptrCast(file_ptr);

        var fb_face: c.FT_Face = undefined;
        if (c.FT_New_Face(self.ft_lib, file_z, 0, &fb_face) != 0) {
            self.markNoFallback(cp);
            return null;
        }
        if (!setFaceSize(fb_face, self.pixel_size)) {
            _ = c.FT_Done_Face(fb_face);
            self.markNoFallback(cp);
            return null;
        }
        const idx = self.fallback_faces.items.len;
        self.fallback_faces.append(self.allocator, fb_face) catch {
            _ = c.FT_Done_Face(fb_face);
            return null;
        };
        // Under OOM we'll re-scan but won't double-load (FT_Face is already in fallback_faces).
        _ = self.cp_to_fallback.put(cp, idx) catch {};
        return fb_face;
    }

    /// Glyph-id keyed lookup (HarfBuzz output). When `bold` / `italic`
    /// are set the gid is interpreted in the matching styled face's
    /// namespace (the caller shaped the run with that face's HarfBuzz
    /// font — shapeRun and this function pick faces via the same
    /// styledFace()); with no styled face the regular gid is used and
    /// bold is emboldened at raster time.
    pub fn lookupOrLoadById(self: *Atlas, gid: u32, bold: bool, italic: bool) !Glyph {
        const key = styleKey(gid, bold, italic);
        if (self.glyph_cache.get(key)) |g| {
            self.touchPage(g.layer);
            return g;
        }
        const sf = self.styledFace(bold, italic);
        const g = try self.loadGlyphFromFace(sf.face, gid, sf.embolden);
        // gid cache only applies to the primary faces — fallback glyphs
        // share the same gid namespace per-face but collide across.
        try self.glyph_cache.put(key, g);
        try self.pages[g.layer].glyphs_on_page.append(self.allocator, .{
            .key = key,
            .kind = .gid,
        });
        return g;
    }

    /// Ask fontconfig for a styled variant (weight/slant) of the
    /// primary face's family and load it with FreeType. Returns null
    /// when no genuine variant exists (caller then synthesizes: bold
    /// via outline-embolden, italic via the shader shear). The caller
    /// has already verified FcInit() succeeded.
    fn loadVariantFace(
        lib: c.FT_Library,
        regular: c.FT_Face,
        regular_path: [*:0]const u8,
        size_px: u16,
        want_weight: c_int,
        want_slant: c_int,
    ) ?c.FT_Face {
        const fam = regular.*.family_name;
        if (fam == null) return null;
        const pattern = c.FcPatternCreate() orelse return null;
        defer c.FcPatternDestroy(pattern);
        _ = c.FcPatternAddString(pattern, c.FC_FAMILY, @ptrCast(fam));
        _ = c.FcPatternAddInteger(pattern, c.FC_WEIGHT, want_weight);
        _ = c.FcPatternAddInteger(pattern, c.FC_SLANT, want_slant);
        _ = c.FcPatternAddBool(pattern, c.FC_SCALABLE, c.FcTrue);
        _ = c.FcConfigSubstitute(null, pattern, c.FcMatchPattern);
        c.FcDefaultSubstitute(pattern);

        var result: c.FcResult = undefined;
        const match = c.FcFontMatch(null, pattern, &result) orelse return null;
        defer c.FcPatternDestroy(match);

        var file_ptr: [*c]c.FcChar8 = undefined;
        if (c.FcPatternGetString(match, c.FC_FILE, 0, &file_ptr) != c.FcResultMatch) return null;
        const file_z: [*:0]const u8 = @ptrCast(file_ptr);

        // Reject the match unless it genuinely has the requested
        // style AND is a different file than the regular face. When
        // the family ships no such sibling, fontconfig returns the
        // regular file at regular style; loading that would just
        // duplicate the regular face — fall through to synthesis.
        if (want_weight >= c.FC_WEIGHT_BOLD) {
            var weight: c_int = 0;
            _ = c.FcPatternGetInteger(match, c.FC_WEIGHT, 0, &weight);
            if (weight < c.FC_WEIGHT_SEMIBOLD) return null;
        }
        if (want_slant >= c.FC_SLANT_ITALIC) {
            var slant: c_int = 0;
            _ = c.FcPatternGetInteger(match, c.FC_SLANT, 0, &slant);
            // Accept italic or oblique — either is a real slanted face.
            if (slant < c.FC_SLANT_ITALIC) return null;
        }
        if (std.mem.orderZ(u8, file_z, regular_path) == .eq) return null;

        var variant: c.FT_Face = undefined;
        if (c.FT_New_Face(lib, file_z, 0, &variant) != 0) return null;
        if (c.FT_Set_Pixel_Sizes(variant, 0, size_px) != 0) {
            _ = c.FT_Done_Face(variant);
            return null;
        }
        return variant;
    }

    /// Pick the best-matching primary face for a style, with graceful
    /// degradation. `embolden` reports whether the caller must still
    /// synthesize bold; renderers consult `hasItalic()` to decide on
    /// the shader shear.
    const StyledFace = struct {
        face: c.FT_Face,
        hb: ?*c.hb_font_t,
        embolden: bool,
    };

    fn styledFace(self: *const Atlas, bold: bool, italic: bool) StyledFace {
        // The renderer's shear decision is global (hasItalic), so the
        // italic branches are taken only when ft_face_italic exists —
        // a bold-italic-without-italic family would otherwise get
        // double-slanted (real slant + shear).
        if (bold and italic and self.hasItalic()) {
            if (self.ft_face_bold_italic) |f| return .{ .face = f, .hb = self.hb_font_bold_italic, .embolden = false };
            return .{ .face = self.ft_face_italic.?, .hb = self.hb_font_italic, .embolden = true };
        }
        if (italic and self.hasItalic()) {
            return .{ .face = self.ft_face_italic.?, .hb = self.hb_font_italic, .embolden = false };
        }
        if (bold) {
            if (self.ft_face_bold) |f| return .{ .face = f, .hb = self.hb_font_bold, .embolden = false };
            return .{ .face = self.ft_face, .hb = self.hb_font, .embolden = true };
        }
        return .{ .face = self.ft_face, .hb = self.hb_font, .embolden = false };
    }

    /// Whether a real italic face is available. When true, renderers
    /// draw italic cells from it and skip the synthetic shear.
    pub fn hasItalic(self: *const Atlas) bool {
        return self.ft_face_italic != null;
    }

    /// Rasterize `gid` on `face`, packing into the atlas. When `embolden`
    /// is set the outline is thickened via `FT_Outline_Embolden` before
    /// rendering (synthetic bold for faces with no bold variant) — a real
    /// outline thickening, not a shader-side pixel smear.
    fn loadGlyphFromFace(self: *Atlas, face: c.FT_Face, gid: u32, embolden: bool) !Glyph {
        if (embolden) {
            if (c.FT_Load_Glyph(face, gid, c.FT_LOAD_DEFAULT | c.FT_LOAD_COLOR) != 0) return error.FtLoad;
            const s = face.*.glyph;
            if (s.*.format == c.FT_GLYPH_FORMAT_OUTLINE) {
                // Same strength FreeType's own ftsynth.c uses for
                // synthetic bold: ~1/24 em scaled to the rendered size.
                const strength = @divTrunc(c.FT_MulFix(face.*.units_per_EM, face.*.size.*.metrics.y_scale), 24);
                _ = c.FT_Outline_Embolden(&s.*.outline, strength);
            }
            if (c.FT_Render_Glyph(s, c.FT_RENDER_MODE_LIGHT) != 0) return error.FtLoad;
        } else if (c.FT_Load_Glyph(face, gid, c.FT_LOAD_RENDER | c.FT_LOAD_TARGET_LIGHT | c.FT_LOAD_COLOR) != 0) {
            return error.FtLoad;
        }

        const slot = face.*.glyph;
        const bm = slot.*.bitmap;

        // Convert the FreeType bitmap to straight RGBA. Two source
        // forms: 8-bit coverage (outline fonts — stored as RGB=255 +
        // coverage in alpha so shaders can tint with the cell fg) and
        // premultiplied BGRA (colour emoji strikes — rescaled to cell
        // size and un-premultiplied for the SRC_ALPHA blend pipeline).
        var w: u32 = bm.width;
        var h: u32 = bm.rows;
        const colored = bm.pixel_mode == c.FT_PIXEL_MODE_BGRA;
        var rgba: ?[]u8 = null;
        defer if (rgba) |b| self.allocator.free(b);
        var bearing_x: i16 = if (w > 0) @intCast(slot.*.bitmap_left) else 0;
        var bearing_y: i16 = if (h > 0) @intCast(slot.*.bitmap_top) else 0;
        var advance: f32 = @as(f32, @floatFromInt(slot.*.advance.x)) / 64.0;

        if (w > 0 and h > 0) {
            if (colored) {
                // Emoji strike: fit into a 2-cell × cell_h box, keeping
                // aspect. Strikes are fixed-size (Noto: 128 px) and
                // almost never match the cell, so this nearly always
                // rescales.
                const box_w: f32 = @floatFromInt(@as(u32, self.cell_w) * 2);
                const box_h: f32 = @floatFromInt(self.cell_h);
                const scale = @min(box_h / @as(f32, @floatFromInt(h)), box_w / @as(f32, @floatFromInt(w)));
                const dw: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(w)) * scale))));
                const dh: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(h)) * scale))));
                rgba = try scaleBgraToRgba(self.allocator, bm, dw, dh);
                // Centre in the 2-cell box: top-left of the glyph quad
                // is computed as (x + bearing_x, y + ascent - bearing_y).
                const dwi: i32 = @intCast(dw);
                const dhi: i32 = @intCast(dh);
                bearing_x = @intCast(@max(0, @divTrunc(@as(i32, self.cell_w) * 2 - dwi, 2)));
                bearing_y = @intCast(self.ascent - @divTrunc(@as(i32, self.cell_h) - dhi, 2));
                advance = @floatFromInt(@as(u32, self.cell_w) * 2);
                w = dw;
                h = dh;
            } else if (bm.pixel_mode == c.FT_PIXEL_MODE_GRAY) {
                rgba = try grayToRgba(self.allocator, bm);
            } else {
                // MONO and exotic modes — treat as missing rather than
                // uploading garbage.
                return error.FtLoad;
            }
        }

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

        if (rgba != null and self.realized) {
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
                c.GL_RGBA,
                c.GL_UNSIGNED_BYTE,
                rgba.?.ptr,
            );
        }

        const inv_page: f32 = 1.0 / @as(f32, @floatFromInt(PAGE_SIZE));
        const g = Glyph{
            .w = @intCast(w),
            .h = @intCast(h),
            .bearing_x = bearing_x,
            .bearing_y = bearing_y,
            .advance = advance,
            .u0 = @as(f32, @floatFromInt(px)) * inv_page,
            .v0 = @as(f32, @floatFromInt(py)) * inv_page,
            .u1 = @as(f32, @floatFromInt(px + w)) * inv_page,
            .v1 = @as(f32, @floatFromInt(py + h)) * inv_page,
            .layer = @intCast(page_idx),
            .generation = page.generation,
            .colored = colored,
        };
        page.pack_x += w + 1;
        page.last_used_frame = self.frame_counter;
        return g;
    }

    /// Expand an 8-bit FreeType coverage bitmap to RGBA: RGB=255,
    /// coverage in alpha. Honours `pitch` (rows may be padded).
    fn grayToRgba(allocator: std.mem.Allocator, bm: c.FT_Bitmap) ![]u8 {
        const w: usize = bm.width;
        const h: usize = bm.rows;
        const out = try allocator.alloc(u8, w * h * 4);
        const pitch: usize = @intCast(@abs(bm.pitch));
        var row: usize = 0;
        while (row < h) : (row += 1) {
            const src = bm.buffer + row * pitch;
            var col: usize = 0;
            while (col < w) : (col += 1) {
                const o = (row * w + col) * 4;
                out[o + 0] = 255;
                out[o + 1] = 255;
                out[o + 2] = 255;
                out[o + 3] = src[col];
            }
        }
        return out;
    }

    /// Box-filter a premultiplied-BGRA strike bitmap down (or up) to
    /// dw×dh and convert to straight RGBA. Box averaging over the
    /// source rect per destination pixel handles the typical large
    /// downscale (128 px strike → ~20 px cell) without aliasing;
    /// upscale degenerates to nearest-neighbour, which is fine for
    /// the ≤2× cases that occur with small strikes.
    fn scaleBgraToRgba(allocator: std.mem.Allocator, bm: c.FT_Bitmap, dw: u32, dh: u32) ![]u8 {
        const sw: usize = bm.width;
        const sh: usize = bm.rows;
        const pitch: usize = @intCast(@abs(bm.pitch));
        const out = try allocator.alloc(u8, @as(usize, dw) * @as(usize, dh) * 4);
        var dy: u32 = 0;
        while (dy < dh) : (dy += 1) {
            // Source row span [y0, y1) for this destination row.
            var y0: usize = @intFromFloat(@floor(@as(f32, @floatFromInt(dy)) * @as(f32, @floatFromInt(sh)) / @as(f32, @floatFromInt(dh))));
            var y1: usize = @intFromFloat(@ceil(@as(f32, @floatFromInt(dy + 1)) * @as(f32, @floatFromInt(sh)) / @as(f32, @floatFromInt(dh))));
            y0 = @min(y0, sh - 1);
            y1 = @max(@min(y1, sh), y0 + 1);
            var dx: u32 = 0;
            while (dx < dw) : (dx += 1) {
                var x0: usize = @intFromFloat(@floor(@as(f32, @floatFromInt(dx)) * @as(f32, @floatFromInt(sw)) / @as(f32, @floatFromInt(dw))));
                var x1: usize = @intFromFloat(@ceil(@as(f32, @floatFromInt(dx + 1)) * @as(f32, @floatFromInt(sw)) / @as(f32, @floatFromInt(dw))));
                x0 = @min(x0, sw - 1);
                x1 = @max(@min(x1, sw), x0 + 1);
                // Average premultiplied channels over the box.
                var sum_b: u32 = 0;
                var sum_g: u32 = 0;
                var sum_r: u32 = 0;
                var sum_a: u32 = 0;
                var sy = y0;
                while (sy < y1) : (sy += 1) {
                    const src_row = bm.buffer + sy * pitch;
                    var sx = x0;
                    while (sx < x1) : (sx += 1) {
                        const s = src_row + sx * 4;
                        sum_b += s[0];
                        sum_g += s[1];
                        sum_r += s[2];
                        sum_a += s[3];
                    }
                }
                const count: u32 = @intCast((y1 - y0) * (x1 - x0));
                const a: u32 = sum_a / count;
                const o = (@as(usize, dy) * dw + dx) * 4;
                if (a == 0) {
                    out[o + 0] = 0;
                    out[o + 1] = 0;
                    out[o + 2] = 0;
                    out[o + 3] = 0;
                } else {
                    // Un-premultiply: averaged premult channel / alpha.
                    out[o + 0] = @intCast(@min(255, (sum_r / count) * 255 / a));
                    out[o + 1] = @intCast(@min(255, (sum_g / count) * 255 / a));
                    out[o + 2] = @intCast(@min(255, (sum_b / count) * 255 / a));
                    out[o + 3] = @intCast(a);
                }
            }
        }
        return out;
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

    fn cacheEmpty(self: *Atlas, key: u32) Glyph {
        const empty = self.emptyGlyph();
        _ = self.cache.put(key, empty) catch {};
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
