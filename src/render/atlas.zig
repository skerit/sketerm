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
const boxdraw = @import("boxdraw.zig");
const glyph_glossary = @import("../grid/glyph_glossary.zig");

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
    /// Either codepoint (kind=.codepoint), font glyph index (kind=.gid)
    /// — both with `BOLD_KEY_BIT` OR-ed in for bold variants, the same
    /// encoding the `cache` / `glyph_cache` maps use — a packed
    /// (face_idx+1)<<32 | gid key (kind=.face_gid) matching
    /// `face_gid_cache`, or a Glyph Protocol render_key (kind=.custom)
    /// matching `custom_cache`, so eviction removes the right entry.
    key: u64,
    kind: Kind,
    /// kind=.custom only: the CustomKey.fg half (0 for foreground-
    /// independent rasterisations).
    fg: u32 = 0,
    pub const Kind = enum { codepoint, gid, face_gid, custom };
};

/// Key of `custom_cache`. `fg` is 0 for foreground-independent
/// rasterisations (all glyf, colrv0 without a 0xFFFF layer) and the
/// quantized 0xRRGGBBFF foreground for colrv0 glyphs that reference
/// CPAL index 0xFFFF — those must re-rasterise when the SGR
/// foreground changes (a deliberate non-copy of Rio's stale-colour
/// bug, where the atlas key omits the foreground).
pub const CustomKey = struct {
    render_key: u64,
    fg: u32,
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
    return resolveFamilyStyled(allocator, family, c.FC_WEIGHT_REGULAR, c.FC_SLANT_ROMAN);
}

/// fontconfig's weight scale is not CSS's. 0 = leave it to the caller
/// (regular), otherwise map 100..900 onto the FC_WEIGHT_* ladder.
pub fn fcWeightFor(css_weight: u16) c_int {
    if (css_weight == 0) return c.FC_WEIGHT_REGULAR;
    return switch (css_weight) {
        0...149 => c.FC_WEIGHT_THIN,
        150...249 => c.FC_WEIGHT_EXTRALIGHT,
        250...349 => c.FC_WEIGHT_LIGHT,
        350...399 => c.FC_WEIGHT_DEMILIGHT,
        400...449 => c.FC_WEIGHT_REGULAR,
        450...549 => c.FC_WEIGHT_MEDIUM,
        550...649 => c.FC_WEIGHT_DEMIBOLD,
        650...749 => c.FC_WEIGHT_BOLD,
        750...849 => c.FC_WEIGHT_EXTRABOLD,
        else => c.FC_WEIGHT_BLACK,
    };
}

pub fn resolveFamilyStyled(
    allocator: std.mem.Allocator,
    family: []const u8,
    weight: c_int,
    slant: c_int,
) ?[:0]u8 {
    if (family.len == 0) return null;
    if (c.FcInit() == 0) return null;
    const fam_z = allocator.allocSentinel(u8, family.len, 0) catch return null;
    defer allocator.free(fam_z);
    @memcpy(fam_z, family);

    const pattern = c.FcPatternCreate() orelse return null;
    defer c.FcPatternDestroy(pattern);
    _ = c.FcPatternAddString(pattern, c.FC_FAMILY, @ptrCast(fam_z.ptr));
    _ = c.FcPatternAddInteger(pattern, c.FC_WEIGHT, weight);
    _ = c.FcPatternAddInteger(pattern, c.FC_SLANT, slant);
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

    /// Shaping-capable fallback faces for the editor's font itemization.
    /// Unlike `fallback_faces` each entry carries its own hb_font so
    /// gid-keyed shaping (hb_shape output) works per face.
    shape_fallbacks: std.ArrayList(ShapeFace) = .empty,
    /// Codepoint → shape_fallbacks index (null = negative cache).
    cp_to_shape_fallback: std.AutoHashMap(u32, ?u16) = undefined,
    /// (face_idx+1)<<32 | gid → Glyph for shape-fallback faces. Kept
    /// separate from `glyph_cache` because its u32 keys have the style
    /// bits (0x4000_0000 / 0x2000_0000) burned into the high range.
    face_gid_cache: std.AutoHashMap(u64, Glyph) = undefined,

    /// Glyph Protocol registrations, keyed by the glossary entry's
    /// process-wide `render_key` — NOT by codepoint. The Atlas is
    /// per-window and shared by every pane while glossaries are
    /// per-Screen, so two panes may legally hold different glyphs at
    /// the same codepoint; keying on render_key also makes stale
    /// pixels after an overwrite unreachable by construction.
    custom_cache: std.AutoHashMap(CustomKey, Glyph) = undefined,

    /// Codepoint ranges pinned to fonts of their own, ahead of the
    /// primary face and the fallback machinery.
    symbol_faces: std.ArrayList(SymbolFace) = .empty,
    /// Draw box/block/Powerline characters from the cell rectangle
    /// instead of the font. On by default: a font's own outlines are
    /// hinted per glyph and rarely tile without seams.
    builtin_box: bool = true,

    /// One such range.
    pub const SymbolFace = struct {
        lo: u32,
        hi: u32,
        face: c.FT_Face,
    };

    /// Everything about a font beyond its file and size. All of it is
    /// optional: an empty Options behaves exactly as `init` did.
    pub const Options = struct {
        line_pad_px: i16 = 0,
        /// Explicit families for the styled faces. Empty = resolve the
        /// style from the primary face's own family, as before.
        bold_family: []const u8 = "",
        italic_family: []const u8 = "",
        bold_italic_family: []const u8 = "",
        /// CSS weights (100..900), 0 = the font's default. Applied to
        /// family resolution and to a variable font's `wght` axis.
        weight: u16 = 0,
        bold_weight: u16 = 0,
        /// Codepoint ranges routed to another family, in priority
        /// order. Ranges may overlap; the first match wins.
        symbol_maps: []const SymbolMapSpec = &.{},
        /// Draw box/block/Powerline characters procedurally.
        builtin_box: bool = true,
    };

    pub const SymbolMapSpec = struct {
        lo: u32,
        hi: u32,
        family: []const u8,
    };

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
        return initWith(allocator, font_path, size_px, .{ .line_pad_px = line_pad_px });
    }

    pub fn initWith(
        allocator: std.mem.Allocator,
        font_path: [*:0]const u8,
        size_px: u16,
        opts: Options,
    ) !*Atlas {
        const line_pad_px = opts.line_pad_px;
        var lib: c.FT_Library = undefined;
        if (c.FT_Init_FreeType(&lib) != 0) return error.FreeTypeInit;
        errdefer _ = c.FT_Done_FreeType(lib);

        var face: c.FT_Face = undefined;
        if (c.FT_New_Face(lib, font_path, 0, &face) != 0) return error.FontLoad;
        errdefer _ = c.FT_Done_Face(face);

        if (c.FT_Set_Pixel_Sizes(face, 0, size_px) != 0) return error.SetSize;
        // A variable font can be any weight; a static one ignores this
        // and keeps whatever fontconfig already picked by file.
        if (opts.weight != 0) setVariableWeight(face, opts.weight);

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
        // An explicitly configured family for a style bypasses the
        // sibling search entirely — that is the whole point of naming
        // one, and the search would refuse a different family anyway.
        const bold_weight_fc = fcWeightFor(if (opts.bold_weight != 0) opts.bold_weight else 700);
        const bold_face = if (opts.bold_family.len > 0)
            loadNamedFace(allocator, lib, opts.bold_family, size_px, bold_weight_fc, c.FC_SLANT_ROMAN, opts.bold_weight)
        else if (fc_ok)
            loadVariantFace(lib, face, font_path, size_px, bold_weight_fc, c.FC_SLANT_ROMAN)
        else
            null;
        const italic_face = if (opts.italic_family.len > 0)
            loadNamedFace(allocator, lib, opts.italic_family, size_px, fcWeightFor(opts.weight), c.FC_SLANT_ITALIC, opts.weight)
        else if (fc_ok)
            loadVariantFace(lib, face, font_path, size_px, fcWeightFor(opts.weight), c.FC_SLANT_ITALIC)
        else
            null;
        const bold_italic_face = if (opts.bold_italic_family.len > 0)
            loadNamedFace(allocator, lib, opts.bold_italic_family, size_px, bold_weight_fc, c.FC_SLANT_ITALIC, opts.bold_weight)
        else if (fc_ok)
            loadVariantFace(lib, face, font_path, size_px, bold_weight_fc, c.FC_SLANT_ITALIC)
        else
            null;
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
            .cp_to_shape_fallback = std.AutoHashMap(u32, ?u16).init(allocator),
            .face_gid_cache = std.AutoHashMap(u64, Glyph).init(allocator),
            .custom_cache = std.AutoHashMap(CustomKey, Glyph).init(allocator),
        };
        self.builtin_box = opts.builtin_box;
        // Symbol maps load eagerly: there are a handful at most, and a
        // lazy load would put an FcFontMatch in the glyph path.
        for (opts.symbol_maps) |spec| {
            const sface = loadNamedFace(allocator, lib, spec.family, size_px, fcWeightFor(opts.weight), c.FC_SLANT_ROMAN, opts.weight) orelse continue;
            self.symbol_faces.append(allocator, .{ .lo = spec.lo, .hi = spec.hi, .face = sface }) catch {
                _ = c.FT_Done_Face(sface);
            };
        }
        // Pre-grow caches so ASCII pre-warm + first session content
        // don't pay 4-5 rehashes climbing from default capacity.
        try self.cache.ensureTotalCapacity(256);
        try self.glyph_cache.ensureTotalCapacity(256);
        return self;
    }

    /// Set a variable font's `wght` axis, clamped to what the face
    /// actually offers. A static face has no axes and is left alone.
    fn setVariableWeight(face: c.FT_Face, css_weight: u16) void {
        if ((face.*.face_flags & c.FT_FACE_FLAG_MULTIPLE_MASTERS) == 0) return;
        var mm: [*c]c.FT_MM_Var = null;
        if (c.FT_Get_MM_Var(face, &mm) != 0 or mm == null) return;
        defer _ = c.FT_Done_MM_Var(face.*.glyph.*.library, mm);

        const n = mm.*.num_axis;
        if (n == 0 or n > 16) return;
        var coords: [16]c.FT_Fixed = undefined;
        var touched = false;
        var i: c_uint = 0;
        while (i < n) : (i += 1) {
            const axis = mm.*.axis[i];
            coords[i] = axis.def;
            // 'wght' as a big-endian tag, the way FreeType reports it.
            if (axis.tag == (@as(c_ulong, 'w') << 24 | @as(c_ulong, 'g') << 16 | @as(c_ulong, 'h') << 8 | @as(c_ulong, 't'))) {
                const want: c.FT_Fixed = @as(c.FT_Fixed, css_weight) << 16;
                coords[i] = std.math.clamp(want, axis.minimum, axis.maximum);
                touched = true;
            }
        }
        if (!touched) return;
        _ = c.FT_Set_Var_Design_Coordinates(face, n, &coords);
    }

    /// Resolve a family name to a face at a given style. Used for the
    /// explicitly configured style families and for symbol maps.
    fn loadNamedFace(
        allocator: std.mem.Allocator,
        lib: c.FT_Library,
        family: []const u8,
        size_px: u16,
        weight: c_int,
        slant: c_int,
        css_weight: u16,
    ) ?c.FT_Face {
        const path = resolveFamilyStyled(allocator, family, weight, slant) orelse return null;
        defer allocator.free(path);
        var face: c.FT_Face = undefined;
        if (c.FT_New_Face(lib, path.ptr, 0, &face) != 0) return null;
        if (!setFaceSize(face, size_px)) {
            _ = c.FT_Done_Face(face);
            return null;
        }
        if (css_weight != 0) setVariableWeight(face, css_weight);
        return face;
    }

    /// Rasterize a built-in box/block/Powerline glyph into the atlas.
    /// The result covers the cell exactly: full advance, no bearing,
    /// which is what makes adjacent cells' lines meet.
    fn drawBuiltin(self: *Atlas, cp: u32) ?Glyph {
        const w: u32 = self.cell_w;
        const h: u32 = self.cell_h;
        if (w == 0 or h == 0) return null;
        const cov = self.allocator.alloc(u8, w * h) catch return null;
        defer self.allocator.free(cov);
        @memset(cov, 0);
        if (!boxdraw.draw(cp, cov, w, h)) return null;

        const rgba = self.allocator.alloc(u8, w * h * 4) catch return null;
        defer self.allocator.free(rgba);
        for (cov, 0..) |a, i| {
            rgba[i * 4 + 0] = 255;
            rgba[i * 4 + 1] = 255;
            rgba[i * 4 + 2] = 255;
            rgba[i * 4 + 3] = a;
        }
        return self.packRgba(rgba, w, h, 0, @intCast(self.ascent), @floatFromInt(w), false) catch null;
    }

    /// Test hook for `symbolFace`, which is otherwise only reachable
    /// from the glyph path.
    pub fn symbolFaceForTest(self: *Atlas, cp: u32) ?c.FT_Face {
        return self.symbolFace(cp);
    }

    /// The face a symbol map pins this codepoint to, if any.
    fn symbolFace(self: *Atlas, cp: u32) ?c.FT_Face {
        for (self.symbol_faces.items) |sf| {
            if (cp >= sf.lo and cp <= sf.hi) return sf.face;
        }
        return null;
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
        for (self.symbol_faces.items) |sf| _ = c.FT_Done_Face(sf.face);
        self.symbol_faces.deinit(self.allocator);
        self.cp_to_fallback.deinit();
        for (self.shape_fallbacks.items) |sf| {
            if (sf.hb) |f| c.hb_font_destroy(f);
            _ = c.FT_Done_Face(sf.face);
        }
        self.shape_fallbacks.deinit(self.allocator);
        self.cp_to_shape_fallback.deinit();
        self.face_gid_cache.deinit();
        self.custom_cache.deinit();
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
        // Box drawing, blocks and Powerline separators are drawn from
        // the cell rectangle rather than the font, because they have
        // to tile exactly and hinted outlines do not. Outranks even a
        // symbol map: a user pinning a Nerd Font for its icons is not
        // asking for its box characters.
        if (self.builtin_box and boxdraw.covers(codepoint)) {
            if (self.drawBuiltin(codepoint)) |g| {
                try self.cache.put(key, g);
                self.pages[g.layer].glyphs_on_page.append(self.allocator, .{
                    .key = key,
                    .kind = .codepoint,
                }) catch |err| {
                    _ = self.cache.remove(key);
                    return err;
                };
                return g;
            }
        }
        // A symbol map outranks the primary face: the user pinned this
        // range to a font precisely because they did not want whatever
        // the main font has there.
        if (self.symbolFace(codepoint)) |sym_face| {
            const sym_gid = c.FT_Get_Char_Index(sym_face, codepoint);
            if (sym_gid != 0) {
                const g = self.loadGlyphFromFace(sym_face, sym_gid, bold) catch return self.cacheEmpty(key);
                try self.cache.put(key, g);
                self.pages[g.layer].glyphs_on_page.append(self.allocator, .{
                    .key = key,
                    .kind = .codepoint,
                }) catch |err| {
                    _ = self.cache.remove(key);
                    return err;
                };
                return g;
            }
        }
        const sf = self.styledFace(bold, italic);
        const gid = c.FT_Get_Char_Index(sf.face, codepoint);
        if (gid != 0 or codepoint == 0) {
            const g = self.loadGlyphFromFace(sf.face, gid, sf.embolden) catch return self.cacheEmpty(key);
            try self.cache.put(key, g);
            self.pages[g.layer].glyphs_on_page.append(self.allocator, .{
                .key = key,
                .kind = .codepoint,
            }) catch |err| {
                _ = self.cache.remove(key);
                return err;
            };
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
                self.pages[g.layer].glyphs_on_page.append(self.allocator, .{
                    .key = key,
                    .kind = .codepoint,
                }) catch |err| {
                    _ = self.cache.remove(key);
                    return err;
                };
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
                self.pages[g.layer].glyphs_on_page.append(self.allocator, .{
                    .key = key,
                    .kind = .codepoint,
                }) catch |err| {
                    _ = self.cache.remove(key);
                    return err;
                };
                return g;
            }
        }
        return self.cacheEmpty(key);
    }

    /// Cell-content glyph resolution with Glyph Protocol precedence:
    /// a live glossary registration outranks the system font. The PUA
    /// range test keeps non-PUA text at one comparison before the
    /// normal path. `fg` is the RESOLVED cell foreground (post
    /// reverse/dim/min-contrast) — colrv0 glyphs with a 0xFFFF layer
    /// bake it into their texels and cache per foreground.
    pub fn lookupGlyph(
        self: *Atlas,
        glossary: *const glyph_glossary.Glossary,
        cp: u32,
        bold: bool,
        italic: bool,
        fg: [4]f32,
    ) !Glyph {
        if (glyph_glossary.isPua(cp)) {
            if (glossary.get(cp)) |e| {
                return self.lookupOrLoadCustom(e.render_key, e.payload, e.fmt, e.upm, e.width, fg);
            }
        }
        return self.lookupOrLoad(cp, bold, italic);
    }

    /// Quantize a resolved foreground to the nonzero cache-key form
    /// (0xRRGGBBFF — the forced alpha byte keeps even black distinct
    /// from the fg-independent sentinel 0).
    fn fgKey(fg: [4]f32) u32 {
        const r: u32 = @intFromFloat(std.math.clamp(fg[0], 0.0, 1.0) * 255.0);
        const g: u32 = @intFromFloat(std.math.clamp(fg[1], 0.0, 1.0) * 255.0);
        const b: u32 = @intFromFloat(std.math.clamp(fg[2], 0.0, 1.0) * 255.0);
        return (r << 24) | (g << 16) | (b << 8) | 0xFF;
    }

    /// Rasterize (or fetch) a Glyph Protocol registration. Keyed by
    /// `render_key`, so an overwritten registration can never serve
    /// the previous rasterisation. Foreground-INDEPENDENT results
    /// (all glyf; colrv0 with no 0xFFFF layer) live under fg=0 and are
    /// rasterised exactly once; a colrv0 glyph referencing 0xFFFF
    /// caches one entry per distinct quantized foreground it is drawn
    /// in (worst case: one atlas slot per distinct fg, reclaimed by
    /// normal page LRU eviction). A structurally broken payload
    /// (which the daemon should have rejected at register time)
    /// caches as an empty glyph under fg=0.
    pub fn lookupOrLoadCustom(
        self: *Atlas,
        render_key: u64,
        payload: []const u8,
        fmt: glyph_glossary.Format,
        upm: u16,
        width: u8,
        fg: [4]f32,
    ) !Glyph {
        // fg=0 first: the common, foreground-independent case — and
        // the only key glyf ever uses.
        if (self.custom_cache.get(.{ .render_key = render_key, .fg = 0 })) |g| {
            self.touchPage(g.layer);
            return g;
        }
        var key = CustomKey{ .render_key = render_key, .fg = 0 };
        if (fmt != .glyf) {
            key.fg = fgKey(fg);
            if (self.custom_cache.get(key)) |g| {
                self.touchPage(g.layer);
                return g;
            }
        }
        const raster: ?CustomRaster = switch (fmt) {
            .glyf => if (self.rasterCustom(payload, upm, width)) |g|
                .{ .g = g, .uses_fg = false }
            else
                null,
            .colrv0 => self.rasterColr(payload, upm, width, key.fg),
            .colrv1 => self.rasterColr1(payload, upm, width, key.fg),
        };
        const r = raster orelse {
            const empty = self.emptyGlyph();
            _ = self.custom_cache.put(.{ .render_key = render_key, .fg = 0 }, empty) catch {};
            return empty;
        };
        if (!r.uses_fg) key.fg = 0;
        try self.custom_cache.put(key, r.g);
        self.pages[r.g.layer].glyphs_on_page.append(self.allocator, .{
            .key = render_key,
            .kind = .custom,
            .fg = key.fg,
        }) catch |err| {
            _ = self.custom_cache.remove(key);
            return err;
        };
        return r.g;
    }

    /// Decode a glyf simple-glyph record and rasterise it into a
    /// `width`-cell × cell_h coverage box via the standalone FreeType
    /// outline API. Coordinates are `upm` units with y=0 at the
    /// baseline (Y-up); `pixel = value * cell_h / upm`. The outline is
    /// fed to FreeType in Cartesian 26.6 space with the baseline
    /// placed `descent` above the bitmap bottom — FT_Outline_Get_Bitmap
    /// with a positive pitch performs the Y-flip itself (buffer row 0
    /// is the TOP row), which the smoke-cell top-half/bottom-half
    /// pixel assertions prove end to end. Spans outside the box are
    /// clipped by the raster.
    fn rasterCustom(self: *Atlas, payload: []const u8, upm: u16, width: u8) ?Glyph {
        const gp = @import("../parser/glyph_protocol.zig");
        if (upm == 0) return null;
        var outline = gp.decodeGlyf(self.allocator, payload) catch return null;
        defer outline.deinit(self.allocator);

        const span: u32 = if (width >= 2) 2 else 1;
        const w: u32 = @as(u32, self.cell_w) * span;
        const h: u32 = self.cell_h;
        if (w == 0 or h == 0) return null;
        if (outline.ends.len == 0 or outline.points.len == 0) {
            // Zero contours is a legal (blank) glyph.
            return self.emptyGlyph();
        }

        const cov = self.renderOutlineCoverage(&outline, upm, w, h) orelse return null;
        defer self.allocator.free(cov);

        // Same alpha-coverage RGBA path as drawBuiltin, so the glyph
        // tints with the cell foreground for free (colored=false).
        const rgba = self.allocator.alloc(u8, w * h * 4) catch return null;
        defer self.allocator.free(rgba);
        for (cov, 0..) |a, i| {
            rgba[i * 4 + 0] = 255;
            rgba[i * 4 + 1] = 255;
            rgba[i * 4 + 2] = 255;
            rgba[i * 4 + 3] = a;
        }
        return self.packRgba(rgba, w, h, 0, @intCast(self.ascent), @floatFromInt(w), false) catch null;
    }

    /// Scan-convert one decoded simple glyph into a w×h 8-bit
    /// coverage buffer (caller frees). Same coordinate mapping as the
    /// original glyf raster: `upm` units, y=0 at the baseline (Y-up),
    /// baseline placed `descent` above the bitmap bottom;
    /// FT_Outline_Get_Bitmap with positive pitch does the Y-flip.
    fn renderOutlineCoverage(
        self: *Atlas,
        outline: *const @import("../parser/glyph_protocol.zig").Outline,
        upm: u16,
        w: u32,
        h: u32,
    ) ?[]u8 {
        const scale: f32 = @as(f32, @floatFromInt(h)) / @as(f32, @floatFromInt(upm));
        const descent_px: f32 = @floatFromInt(@max(0, @as(i32, @intCast(h)) - @as(i32, self.ascent)));

        const pts = self.allocator.alloc(c.FT_Vector, outline.points.len) catch return null;
        defer self.allocator.free(pts);
        const tags = self.allocator.alloc(u8, outline.points.len) catch return null;
        defer self.allocator.free(tags);
        const conts = self.allocator.alloc(c_ushort, outline.ends.len) catch return null;
        defer self.allocator.free(conts);
        for (outline.points, 0..) |p, i| {
            const px = @as(f32, @floatFromInt(p.x)) * scale;
            const py = @as(f32, @floatFromInt(p.y)) * scale + descent_px;
            pts[i] = .{
                .x = @intFromFloat(@round(px * 64.0)),
                .y = @intFromFloat(@round(py * 64.0)),
            };
            tags[i] = if (p.on_curve) c.FT_CURVE_TAG_ON else c.FT_CURVE_TAG_CONIC;
        }
        for (outline.ends, 0..) |e, i| conts[i] = e;

        var ol = c.FT_Outline{
            .n_contours = @intCast(outline.ends.len),
            .n_points = @intCast(outline.points.len),
            .points = pts.ptr,
            .tags = tags.ptr,
            .contours = conts.ptr,
            .flags = c.FT_OUTLINE_NONE,
        };

        const cov = self.allocator.alloc(u8, w * h) catch return null;
        @memset(cov, 0);
        const bm = c.FT_Bitmap{
            .rows = h,
            .width = w,
            .pitch = @intCast(w),
            .buffer = cov.ptr,
            .num_grays = 256,
            .pixel_mode = c.FT_PIXEL_MODE_GRAY,
            .palette_mode = 0,
            .palette = null,
        };
        if (c.FT_Outline_Get_Bitmap(self.ft_lib, &ol, &bm) != 0) {
            self.allocator.free(cov);
            return null;
        }
        return cov;
    }

    const CustomRaster = struct { g: Glyph, uses_fg: bool };

    /// Rasterise a colrv0 container: each layer's outline is
    /// scan-converted to coverage and composited src-over (painter's
    /// order — first layer painted first) with the layer's flat CPAL
    /// colour, or `fg_rgba` for the 0xFFFF foreground sentinel.
    /// Compositing runs premultiplied, then un-premultiplies into
    /// straight RGBA for the emoji SRC_ALPHA pipeline (colored=true —
    /// the shader samples texels instead of tinting coverage).
    fn rasterColr(
        self: *Atlas,
        payload: []const u8,
        upm: u16,
        width: u8,
        fg_rgba: u32,
    ) ?CustomRaster {
        const gp = @import("../parser/glyph_protocol.zig");
        if (upm == 0) return null;
        var colr = gp.decodeColr(self.allocator, payload) catch return null;
        defer colr.deinit(self.allocator);

        const span: u32 = if (width >= 2) 2 else 1;
        const w: u32 = @as(u32, self.cell_w) * span;
        const h: u32 = self.cell_h;
        if (w == 0 or h == 0) return null;
        if (colr.layers.len == 0) {
            // A zero-layer base renders blank — foreground-independent
            // regardless of what unreferenced layers might use.
            return .{ .g = self.emptyGlyph(), .uses_fg = false };
        }

        // Premultiplied f32 accumulation buffer.
        const accum = self.allocator.alloc(f32, w * h * 4) catch return null;
        defer self.allocator.free(accum);
        @memset(accum, 0);

        for (colr.layers) |layer| {
            var outline = gp.decodeGlyf(self.allocator, colr.outlines[layer.glyph]) catch return null;
            defer outline.deinit(self.allocator);
            if (outline.ends.len == 0 or outline.points.len == 0) continue;
            const cov = self.renderOutlineCoverage(&outline, upm, w, h) orelse return null;
            defer self.allocator.free(cov);

            const rgba: u32 = if (layer.is_fg) fg_rgba else layer.rgba;
            const sr: f32 = @as(f32, @floatFromInt((rgba >> 24) & 0xFF)) / 255.0;
            const sg: f32 = @as(f32, @floatFromInt((rgba >> 16) & 0xFF)) / 255.0;
            const sb: f32 = @as(f32, @floatFromInt((rgba >> 8) & 0xFF)) / 255.0;
            const sa: f32 = @as(f32, @floatFromInt(rgba & 0xFF)) / 255.0;
            for (cov, 0..) |cv, i| {
                if (cv == 0) continue;
                const a = @as(f32, @floatFromInt(cv)) / 255.0 * sa;
                const inv = 1.0 - a;
                accum[i * 4 + 0] = sr * a + accum[i * 4 + 0] * inv;
                accum[i * 4 + 1] = sg * a + accum[i * 4 + 1] * inv;
                accum[i * 4 + 2] = sb * a + accum[i * 4 + 2] * inv;
                accum[i * 4 + 3] = a + accum[i * 4 + 3] * inv;
            }
        }

        const rgba_out = self.allocator.alloc(u8, w * h * 4) catch return null;
        defer self.allocator.free(rgba_out);
        var i: usize = 0;
        while (i < w * h) : (i += 1) {
            const a = accum[i * 4 + 3];
            if (a <= 0.0) {
                rgba_out[i * 4 + 0] = 0;
                rgba_out[i * 4 + 1] = 0;
                rgba_out[i * 4 + 2] = 0;
                rgba_out[i * 4 + 3] = 0;
            } else {
                rgba_out[i * 4 + 0] = @intFromFloat(std.math.clamp(accum[i * 4 + 0] / a, 0.0, 1.0) * 255.0);
                rgba_out[i * 4 + 1] = @intFromFloat(std.math.clamp(accum[i * 4 + 1] / a, 0.0, 1.0) * 255.0);
                rgba_out[i * 4 + 2] = @intFromFloat(std.math.clamp(accum[i * 4 + 2] / a, 0.0, 1.0) * 255.0);
                rgba_out[i * 4 + 3] = @intFromFloat(std.math.clamp(a, 0.0, 1.0) * 255.0);
            }
        }

        const g = self.packRgba(rgba_out, w, h, 0, @intCast(self.ascent), @floatFromInt(w), true) catch return null;
        return .{ .g = g, .uses_fg = colr.uses_fg };
    }

    /// Rasterise a colrv1 container by walking its paint graph into a
    /// cairo image surface (cairo is our tiny-skia: gradients with all
    /// three extend modes, affine transforms, clipping, the full
    /// Porter-Duff + separable/HSL operator set). The daemon validated
    /// the graph at register time; this walk stays defensive anyway
    /// (bad node → skip, depth/budget cap → stop) and degrades to a
    /// blank glyph rather than failing.
    ///
    /// Correctness budget, stated Rio-style:
    ///  - painted for real: solid fills, linear + radial gradients
    ///    (pad/repeat/reflect, stops outside [0,1] remapped into range
    ///    by moving the gradient geometry), glyph clips, all ten
    ///    transform forms, PaintColrLayers, PaintColrGlyph, and all 28
    ///    composite modes via native cairo operators;
    ///  - degraded: sweep gradients paint the FIRST colour stop as a
    ///    solid (cairo has no sweep shader — same degradation as Rio /
    ///    tiny-skia); a pad colour line whose stops all share one
    ///    offset paints the last stop's solid;
    ///  - ignored: variation deltas (PaintVar* render at the default
    ///    instance; the protocol cannot carry variation coordinates).
    fn rasterColr1(
        self: *Atlas,
        payload: []const u8,
        upm: u16,
        width: u8,
        fg_rgba: u32,
    ) ?CustomRaster {
        const gp = @import("../parser/glyph_protocol.zig");
        if (upm == 0) return null;
        var c1 = gp.decodeColr1(self.allocator, payload) catch return null;
        defer c1.deinit(self.allocator);

        const span: u32 = if (width >= 2) 2 else 1;
        const w: u32 = @as(u32, self.cell_w) * span;
        const h: u32 = self.cell_h;
        if (w == 0 or h == 0) return null;

        const surface = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, @intCast(w), @intCast(h));
        defer c.cairo_surface_destroy(surface);
        if (c.cairo_surface_status(surface) != c.CAIRO_STATUS_SUCCESS) return null;
        const cr = c.cairo_create(surface);
        defer c.cairo_destroy(cr);
        if (c.cairo_status(cr) != c.CAIRO_STATUS_SUCCESS) return null;

        // Same coordinate mapping as renderOutlineCoverage: font
        // units, y-up, baseline `descent` above the bitmap bottom.
        const scale: f64 = @as(f64, @floatFromInt(h)) / @as(f64, @floatFromInt(upm));
        c.cairo_translate(cr, 0, @floatFromInt(self.ascent));
        c.cairo_scale(cr, scale, -scale);

        if (c1.clip_box) |box| {
            c.cairo_rectangle(
                cr,
                @floatFromInt(box.x_min),
                @floatFromInt(box.y_min),
                @floatFromInt(@as(i32, box.x_max) - box.x_min),
                @floatFromInt(@as(i32, box.y_max) - box.y_min),
            );
            c.cairo_clip(cr);
        }

        var ctx = V1PaintCtx{
            .atlas = self,
            .c1 = &c1,
            .cr = cr,
            .fg = fg_rgba,
            .budget = gp.MAX_V1_NODES,
        };
        ctx.paint(c1.root_paint, 0);

        c.cairo_surface_flush(surface);
        const stride: usize = @intCast(c.cairo_image_surface_get_stride(surface));
        const pix = c.cairo_image_surface_get_data(surface);
        if (pix == null) return null;

        // ARGB32 is premultiplied, native-endian u32 — un-premultiply
        // into the straight RGBA the emoji SRC_ALPHA pipeline expects.
        const rgba_out = self.allocator.alloc(u8, w * h * 4) catch return null;
        defer self.allocator.free(rgba_out);
        var y: usize = 0;
        while (y < h) : (y += 1) {
            const row: [*]const u32 = @ptrCast(@alignCast(pix + y * stride));
            var x: usize = 0;
            while (x < w) : (x += 1) {
                const px = row[x];
                const a: u32 = px >> 24;
                const o = (y * w + x) * 4;
                if (a == 0) {
                    rgba_out[o + 0] = 0;
                    rgba_out[o + 1] = 0;
                    rgba_out[o + 2] = 0;
                    rgba_out[o + 3] = 0;
                } else {
                    rgba_out[o + 0] = @intCast(@min(255, ((px >> 16) & 0xFF) * 255 / a));
                    rgba_out[o + 1] = @intCast(@min(255, ((px >> 8) & 0xFF) * 255 / a));
                    rgba_out[o + 2] = @intCast(@min(255, (px & 0xFF) * 255 / a));
                    rgba_out[o + 3] = @intCast(a);
                }
            }
        }

        const g = self.packRgba(rgba_out, w, h, 0, @intCast(self.ascent), @floatFromInt(w), true) catch return null;
        return .{ .g = g, .uses_fg = c1.uses_fg };
    }

    /// Recursive cairo walker over a validated colrv1 paint graph.
    const V1PaintCtx = struct {
        const gp = @import("../parser/glyph_protocol.zig");

        atlas: *Atlas,
        c1: *const gp.Colr1,
        cr: ?*c.cairo_t,
        /// Resolved cell foreground, straight 0xRRGGBBAA (the atlas
        /// CustomKey.fg quantisation).
        fg: u32,
        budget: usize,

        /// COLR composite mode (0..27) → cairo operator, spec order.
        const OPERATORS = [28]c_uint{
            c.CAIRO_OPERATOR_CLEAR,     c.CAIRO_OPERATOR_SOURCE,
            c.CAIRO_OPERATOR_DEST,      c.CAIRO_OPERATOR_OVER,
            c.CAIRO_OPERATOR_DEST_OVER, c.CAIRO_OPERATOR_IN,
            c.CAIRO_OPERATOR_DEST_IN,   c.CAIRO_OPERATOR_OUT,
            c.CAIRO_OPERATOR_DEST_OUT,  c.CAIRO_OPERATOR_ATOP,
            c.CAIRO_OPERATOR_DEST_ATOP, c.CAIRO_OPERATOR_XOR,
            c.CAIRO_OPERATOR_ADD,       c.CAIRO_OPERATOR_SCREEN,
            c.CAIRO_OPERATOR_OVERLAY,   c.CAIRO_OPERATOR_DARKEN,
            c.CAIRO_OPERATOR_LIGHTEN,   c.CAIRO_OPERATOR_COLOR_DODGE,
            c.CAIRO_OPERATOR_COLOR_BURN, c.CAIRO_OPERATOR_HARD_LIGHT,
            c.CAIRO_OPERATOR_SOFT_LIGHT, c.CAIRO_OPERATOR_DIFFERENCE,
            c.CAIRO_OPERATOR_EXCLUSION, c.CAIRO_OPERATOR_MULTIPLY,
            c.CAIRO_OPERATOR_HSL_HUE,   c.CAIRO_OPERATOR_HSL_SATURATION,
            c.CAIRO_OPERATOR_HSL_COLOR, c.CAIRO_OPERATOR_HSL_LUMINOSITY,
        };

        /// Straight (r, g, b, a) in 0..1 for a palette reference;
        /// 0xFFFF is the current foreground. Alpha clamps to [0,1]
        /// per spec.
        fn resolve(self: *V1PaintCtx, palette: u16, alpha: f32) ?[4]f64 {
            const rgba: u32 = if (palette == gp.PALETTE_FOREGROUND)
                self.fg
            else
                self.c1.cpal.rgba(palette) orelse return null;
            const a = std.math.clamp(alpha, 0.0, 1.0);
            return .{
                @as(f64, @floatFromInt((rgba >> 24) & 0xFF)) / 255.0,
                @as(f64, @floatFromInt((rgba >> 16) & 0xFF)) / 255.0,
                @as(f64, @floatFromInt((rgba >> 8) & 0xFF)) / 255.0,
                @as(f64, @floatFromInt(rgba & 0xFF)) / 255.0 * a,
            };
        }

        fn paint(self: *V1PaintCtx, off: usize, depth: usize) void {
            if (depth >= gp.MAX_V1_DEPTH or self.budget == 0) return;
            self.budget -= 1;
            const node = gp.readPaint(self.c1.colr, off) catch return;
            switch (node) {
                .layers => |l| {
                    var i: usize = 0;
                    while (i < l.count) : (i += 1) {
                        const idx = @as(u64, l.first) + i;
                        if (idx >= self.c1.n_layer_paints) return;
                        const rec = self.c1.layer_list + 4 + @as(usize, @intCast(idx)) * 4;
                        const rel = std.mem.readInt(u32, self.c1.colr[rec..][0..4], .big);
                        const abs = self.c1.layer_list + rel;
                        if (rel == 0 or abs >= self.c1.colr.len) continue;
                        // Layers composite src-over in order — cairo's
                        // default operator, no group needed.
                        self.paint(abs, depth + 1);
                    }
                },
                .solid => |s| {
                    const col = self.resolve(s.palette, s.alpha) orelse return;
                    c.cairo_set_source_rgba(self.cr, col[0], col[1], col[2], col[3]);
                    c.cairo_paint(self.cr);
                },
                .linear => |g| self.paintLinear(g),
                .radial => |g| self.paintRadial(g),
                .sweep => |g| {
                    // DELIBERATE DEGRADATION: cairo has no sweep
                    // (conic) shader, exactly like tiny-skia — Rio
                    // paints the first colour stop as a solid and so
                    // do we. Angles are parsed and dropped.
                    const cl = gp.readColorLine(self.c1.colr, g.color_line) catch return;
                    if (cl.n_stops == 0) return;
                    const stop = gp.readStop(self.c1.colr, cl, 0);
                    const col = self.resolve(stop.palette, stop.alpha) orelse return;
                    c.cairo_set_source_rgba(self.cr, col[0], col[1], col[2], col[3]);
                    c.cairo_paint(self.cr);
                },
                .glyph => |g| {
                    if (g.glyph_id >= self.c1.outlines.len) return;
                    var outline = gp.decodeGlyf(self.atlas.allocator, self.c1.outlines[g.glyph_id]) catch return;
                    defer outline.deinit(self.atlas.allocator);
                    c.cairo_save(self.cr);
                    defer c.cairo_restore(self.cr);
                    c.cairo_new_path(self.cr);
                    addOutlinePath(self.cr, &outline);
                    c.cairo_clip(self.cr);
                    self.paint(g.child, depth + 1);
                },
                .colr_glyph => |g| {
                    const root = self.c1.baseRootPaint(g.glyph_id) orelse return;
                    self.paint(root, depth + 1);
                },
                .transform => |t| {
                    for (t.m) |v| {
                        if (!std.math.isFinite(v)) return; // tan(±90°) skew etc.
                    }
                    var m: c.cairo_matrix_t = undefined;
                    c.cairo_matrix_init(&m, t.m[0], t.m[1], t.m[2], t.m[3], t.m[4], t.m[5]);
                    c.cairo_save(self.cr);
                    defer c.cairo_restore(self.cr);
                    c.cairo_transform(self.cr, &m);
                    // A singular matrix put cr in an error state; all
                    // further ops no-op, which is the blank degrade.
                    self.paint(t.child, depth + 1);
                },
                .composite => |cmp| {
                    if (cmp.mode > gp.MAX_COMPOSITE_MODE) return;
                    // Isolated group: backdrop, then source composited
                    // onto it with the mode, then the result src-over
                    // onto the canvas.
                    c.cairo_push_group(self.cr);
                    self.paint(cmp.backdrop, depth + 1);
                    c.cairo_push_group(self.cr);
                    self.paint(cmp.source, depth + 1);
                    const src = c.cairo_pop_group(self.cr);
                    c.cairo_set_source(self.cr, src);
                    c.cairo_set_operator(self.cr, OPERATORS[cmp.mode]);
                    c.cairo_paint(self.cr);
                    c.cairo_pattern_destroy(src);
                    c.cairo_set_operator(self.cr, c.CAIRO_OPERATOR_OVER);
                    c.cairo_pop_group_to_source(self.cr);
                    c.cairo_paint(self.cr);
                },
            }
        }

        /// Colour-line summary for gradient normalisation.
        const LineInfo = struct {
            cl: gp.ColorLine,
            t_min: f32,
            t_max: f32,
        };

        fn lineInfo(self: *V1PaintCtx, ref: gp.ColorLineRef) ?LineInfo {
            const cl = gp.readColorLine(self.c1.colr, ref) catch return null;
            if (cl.n_stops == 0) return null;
            var t_min = gp.readStop(self.c1.colr, cl, 0).offset;
            var t_max = t_min;
            var i: usize = 1;
            while (i < cl.n_stops) : (i += 1) {
                const t = gp.readStop(self.c1.colr, cl, i).offset;
                t_min = @min(t_min, t);
                t_max = @max(t_max, t);
            }
            return .{ .cl = cl, .t_min = t_min, .t_max = t_max };
        }

        /// Add the (normalised) stops and extend mode to `pattern`,
        /// then fill the clip with it.
        fn fillWithPattern(self: *V1PaintCtx, pattern: ?*c.cairo_pattern_t, info: LineInfo) void {
            defer c.cairo_pattern_destroy(pattern);
            const denom = info.t_max - info.t_min;
            var i: usize = 0;
            while (i < info.cl.n_stops) : (i += 1) {
                const stop = gp.readStop(self.c1.colr, info.cl, i);
                const col = self.resolve(stop.palette, stop.alpha) orelse continue;
                const t: f64 = if (denom > 0) (stop.offset - info.t_min) / denom else 0.0;
                c.cairo_pattern_add_color_stop_rgba(pattern, t, col[0], col[1], col[2], col[3]);
            }
            c.cairo_pattern_set_extend(pattern, switch (info.cl.extend) {
                1 => c.CAIRO_EXTEND_REPEAT,
                2 => c.CAIRO_EXTEND_REFLECT,
                else => c.CAIRO_EXTEND_PAD,
            });
            c.cairo_set_source(self.cr, pattern);
            c.cairo_paint(self.cr);
        }

        /// Degenerate colour lines: repeat/reflect with a zero-length
        /// interval is ill-formed (spec: render nothing); pad paints
        /// the LAST stop's solid (approximates the spec's two-colour
        /// step — the below-first-offset half is rarely visible).
        fn degenerateLine(self: *V1PaintCtx, info: LineInfo) bool {
            if (info.t_max > info.t_min) return false;
            if (info.cl.extend != 0) return true; // painted nothing
            const stop = gp.readStop(self.c1.colr, info.cl, info.cl.n_stops - 1);
            if (self.resolve(stop.palette, stop.alpha)) |col| {
                c.cairo_set_source_rgba(self.cr, col[0], col[1], col[2], col[3]);
                c.cairo_paint(self.cr);
            }
            return true;
        }

        fn paintLinear(self: *V1PaintCtx, g: anytype) void {
            const info = self.lineInfo(g.color_line) orelse return;
            if (self.degenerateLine(info)) return;
            // The spec's p2 rotates the gradient: project p0→p1 onto
            // the perpendicular of p0→p2 (skrifa's algorithm). p1==p0,
            // p2==p0 or p0p1 ∥ p0p2 are ill-formed — render nothing.
            const dx = g.x1 - g.x0;
            const dy = g.y1 - g.y0;
            const rx = g.x2 - g.x0;
            const ry = g.y2 - g.y0;
            if ((dx == 0 and dy == 0) or (rx == 0 and ry == 0)) return;
            const px = ry; // perpendicular of (rx, ry)
            const py = -rx;
            const pp = px * px + py * py;
            const proj = (dx * px + dy * py) / pp;
            const p3x = g.x0 + proj * px;
            const p3y = g.y0 + proj * py;
            if (p3x == g.x0 and p3y == g.y0) return; // parallel
            // Stops outside [0,1]: cairo clamps offsets, so remap the
            // colour line into [0,1] by sliding the gradient geometry
            // instead (exact, not Rio's truncation).
            const ax = g.x0 + (p3x - g.x0) * info.t_min;
            const ay = g.y0 + (p3y - g.y0) * info.t_min;
            const bx = g.x0 + (p3x - g.x0) * info.t_max;
            const by = g.y0 + (p3y - g.y0) * info.t_max;
            const pattern = c.cairo_pattern_create_linear(ax, ay, bx, by);
            self.fillWithPattern(pattern, info);
        }

        fn paintRadial(self: *V1PaintCtx, g: anytype) void {
            const info = self.lineInfo(g.color_line) orelse return;
            if (self.degenerateLine(info)) return;
            if (g.x0 == g.x1 and g.y0 == g.y1 and g.r0 == g.r1) return; // spec: nothing
            // Same [0,1] remap as linear: lerp both circles along ω.
            const lerp = struct {
                fn go(a: f32, b: f32, t: f32) f64 {
                    return a + (b - a) * t;
                }
            }.go;
            // COLR allows negative interpolated radii (the cone
            // algorithm handles them); cairo does not — clamp to 0,
            // a marginal degradation on exotic gradients.
            const pattern = c.cairo_pattern_create_radial(
                lerp(g.x0, g.x1, info.t_min),
                lerp(g.y0, g.y1, info.t_min),
                @max(0.0, lerp(g.r0, g.r1, info.t_min)),
                lerp(g.x0, g.x1, info.t_max),
                lerp(g.y0, g.y1, info.t_max),
                @max(0.0, lerp(g.r0, g.r1, info.t_max)),
            );
            self.fillWithPattern(pattern, info);
        }

        /// Build a cairo path from a decoded TrueType outline (font
        /// units — the CTM does the scaling): conic runs get their
        /// implied on-curve midpoints, quadratics lift to cubics.
        fn addOutlinePath(cr: ?*c.cairo_t, outline: *const gp.Outline) void {
            var start: usize = 0;
            for (outline.ends) |e| {
                const end = @as(usize, e) + 1;
                if (end <= start or end > outline.points.len) return;
                emitContour(cr, outline.points[start..end]);
                start = end;
            }
        }

        const P = struct { x: f64, y: f64 };

        fn pt(p: gp.Point) P {
            return .{ .x = @floatFromInt(p.x), .y = @floatFromInt(p.y) };
        }

        fn mid(a: P, b: P) P {
            return .{ .x = (a.x + b.x) / 2, .y = (a.y + b.y) / 2 };
        }

        fn quadTo(cr: ?*c.cairo_t, from: P, ctrl: P, to: P) void {
            // Exact quadratic→cubic lift.
            const c1x = from.x + (ctrl.x - from.x) * 2.0 / 3.0;
            const c1y = from.y + (ctrl.y - from.y) * 2.0 / 3.0;
            const c2x = to.x + (ctrl.x - to.x) * 2.0 / 3.0;
            const c2y = to.y + (ctrl.y - to.y) * 2.0 / 3.0;
            c.cairo_curve_to(cr, c1x, c1y, c2x, c2y, to.x, to.y);
        }

        fn emitContour(cr: ?*c.cairo_t, pts: []const gp.Point) void {
            const n = pts.len;
            if (n == 0) return;
            // Start point: first on-curve point; a fully off-curve
            // contour starts at the implied midpoint of its ends.
            var first: usize = 0;
            var start: P = undefined;
            if (pts[0].on_curve) {
                start = pt(pts[0]);
                first = 1;
            } else if (pts[n - 1].on_curve) {
                start = pt(pts[n - 1]);
            } else {
                start = mid(pt(pts[n - 1]), pt(pts[0]));
            }
            c.cairo_move_to(cr, start.x, start.y);
            var cur = start;
            var pending: ?P = null;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const idx = (first + i) % n;
                // When we started at the LAST point (off-curve p0
                // case handled above), don't revisit it.
                if (first == 0 and !pts[0].on_curve and pts[n - 1].on_curve and idx == n - 1) continue;
                const p = pt(pts[idx]);
                if (pts[idx].on_curve) {
                    if (pending) |q| {
                        quadTo(cr, cur, q, p);
                        pending = null;
                    } else {
                        c.cairo_line_to(cr, p.x, p.y);
                    }
                    cur = p;
                } else {
                    if (pending) |q| {
                        const m = mid(q, p);
                        quadTo(cr, cur, q, m);
                        cur = m;
                    }
                    pending = p;
                }
            }
            if (pending) |q| {
                quadTo(cr, cur, q, start);
            }
            c.cairo_close_path(cr);
        }
    };

    /// Would the terminal render `cp` as something other than tofu
    /// from system fonts? Answers Glyph Protocol `q` coverage. Uses
    /// the same resolution order as `lookupOrLoad` minus the glossary:
    /// builtin box drawing, symbol maps, the primary face, then the
    /// (cached) fontconfig fallback query.
    pub fn hasSystemGlyph(self: *Atlas, cp: u32) bool {
        if (self.builtin_box and boxdraw.covers(cp)) return true;
        if (self.symbolFace(cp)) |sf| {
            if (c.FT_Get_Char_Index(sf, cp) != 0) return true;
        }
        if (c.FT_Get_Char_Index(self.ft_face, cp) != 0) return true;
        if (self.findFallbackFace(cp)) |fb| {
            if (c.FT_Get_Char_Index(fb, cp) != 0) return true;
        }
        return false;
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

    /// A shaping-capable fallback face: FT face for raster/coverage plus
    /// its own hb_font so gid-keyed shaping works in this face's
    /// namespace.
    pub const ShapeFace = struct {
        face: c.FT_Face,
        hb: ?*c.hb_font_t,
    };

    /// The FT face + hb font a (bold, italic) primary run shapes and
    /// rasterizes with — same selection as the internal styledFace, so
    /// gids from the returned hb font resolve via lookupOrLoadById with
    /// the same style flags.
    pub fn primaryShapeFace(self: *const Atlas, bold: bool, italic: bool) ShapeFace {
        const sf = self.styledFace(bold, italic);
        return .{ .face = sf.face, .hb = sf.hb orelse self.hb_font };
    }

    pub fn shapeFallback(self: *const Atlas, idx: u16) ShapeFace {
        return self.shape_fallbacks.items[idx];
    }

    /// Locate (or lazily load + register) a shape fallback face covering
    /// `cp`. Mirrors findFallbackFace (fontconfig charset match, colour
    /// preference for emoji codepoints, strike-size selection) but each
    /// registered face gets an hb_font. Positive and negative results
    /// are cached per codepoint.
    pub fn shapeFallbackForCp(self: *Atlas, cp: u32) ?u16 {
        if (self.cp_to_shape_fallback.get(cp)) |entry| return entry;
        if (!self.fc_initialized) {
            _ = self.cp_to_shape_fallback.put(cp, null) catch {};
            return null;
        }
        // Already-registered face covering this cp?
        for (self.shape_fallbacks.items, 0..) |sf, idx| {
            if (c.FT_Get_Char_Index(sf.face, cp) != 0) {
                const i16idx: u16 = @intCast(idx);
                _ = self.cp_to_shape_fallback.put(cp, i16idx) catch {};
                return i16idx;
            }
        }
        const miss = struct {
            fn mark(a: *Atlas, mcp: u32) ?u16 {
                _ = a.cp_to_shape_fallback.put(mcp, null) catch {};
                return null;
            }
        }.mark;
        const pattern = c.FcPatternCreate() orelse return miss(self, cp);
        defer c.FcPatternDestroy(pattern);
        const charset = c.FcCharSetCreate() orelse return miss(self, cp);
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
        const match = c.FcFontMatch(null, pattern, &result) orelse return miss(self, cp);
        defer c.FcPatternDestroy(match);

        var file_ptr: [*c]c.FcChar8 = undefined;
        if (c.FcPatternGetString(match, c.FC_FILE, 0, &file_ptr) != c.FcResultMatch)
            return miss(self, cp);
        const file_z: [*:0]const u8 = @ptrCast(file_ptr);

        var fb_face: c.FT_Face = undefined;
        if (c.FT_New_Face(self.ft_lib, file_z, 0, &fb_face) != 0) return miss(self, cp);
        if (!setFaceSize(fb_face, self.pixel_size)) {
            _ = c.FT_Done_Face(fb_face);
            return miss(self, cp);
        }
        // The matched font may still not cover cp (fontconfig substitutes
        // rather than failing) — cache the negative rather than register
        // a useless face.
        if (c.FT_Get_Char_Index(fb_face, cp) == 0) {
            _ = c.FT_Done_Face(fb_face);
            return miss(self, cp);
        }
        const hb = c.hb_ft_font_create_referenced(fb_face);
        const idx: u16 = @intCast(self.shape_fallbacks.items.len);
        self.shape_fallbacks.append(self.allocator, .{ .face = fb_face, .hb = hb }) catch {
            if (hb) |f| c.hb_font_destroy(f);
            _ = c.FT_Done_Face(fb_face);
            return null;
        };
        _ = self.cp_to_shape_fallback.put(cp, idx) catch {};
        return idx;
    }

    /// Glyph-id keyed lookup in a shape-fallback face's namespace.
    /// Colour (emoji) strikes go through the same FT_LOAD_COLOR +
    /// rescale path as primary-face lookups.
    pub fn lookupOrLoadFaceGid(self: *Atlas, face_idx: u16, gid: u32) !Glyph {
        const key: u64 = (@as(u64, face_idx) + 1) << 32 | gid;
        if (self.face_gid_cache.get(key)) |g| {
            self.touchPage(g.layer);
            return g;
        }
        const face = self.shape_fallbacks.items[face_idx].face;
        const g = try self.loadGlyphFromFace(face, gid, false);
        try self.face_gid_cache.put(key, g);
        try self.pages[g.layer].glyphs_on_page.append(self.allocator, .{
            .key = key,
            .kind = .face_gid,
        });
        return g;
    }

    /// Shape a UTF-8 run with an EXPLICIT hb_font and direction (the
    /// editor's itemization path — the run's face was chosen per
    /// script/coverage before shaping). Script/language are guessed
    /// from the content, direction is forced. Cached like shapeRun;
    /// the returned slice is OWNED BY THE ATLAS.
    pub fn shapeWithFont(self: *Atlas, font: *c.hb_font_t, text: []const u8, rtl: bool) ![]ShapedGlyph {
        const buf = self.hb_buf orelse return error.NoHarfBuzzFont;
        var key = std.hash.Wyhash.hash(0x51ED_1704, text);
        key ^= @intFromPtr(font) *% 0x9E37_79B9_7F4A_7C15;
        if (rtl) key ^= 0x0D0A_C0DE_0D0A_C0DE;
        if (self.shape_cache.get(key)) |cached| return cached;

        c.hb_buffer_clear_contents(buf);
        c.hb_buffer_add_utf8(buf, text.ptr, @intCast(text.len), 0, @intCast(text.len));
        c.hb_buffer_guess_segment_properties(buf);
        c.hb_buffer_set_direction(buf, if (rtl) c.HB_DIRECTION_RTL else c.HB_DIRECTION_LTR);
        c.hb_shape(font, buf, if (self.n_features > 0) &self.features else null, @intCast(self.n_features));
        var glyph_count: c_uint = 0;
        const infos = c.hb_buffer_get_glyph_infos(buf, &glyph_count);
        const positions = c.hb_buffer_get_glyph_positions(buf, &glyph_count);
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

        return self.packRgba(rgba, w, h, bearing_x, bearing_y, advance, colored);
    }

    /// Shelf-pack an RGBA bitmap into a page, upload it, and return the
    /// Glyph describing where it landed. `rgba` may be null for an
    /// empty glyph (space), which still gets a slot so its metrics are
    /// cached.
    fn packRgba(
        self: *Atlas,
        rgba: ?[]const u8,
        w: u32,
        h: u32,
        bearing_x: i16,
        bearing_y: i16,
        advance: f32,
        colored: bool,
    ) !Glyph {
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
                .codepoint => _ = self.cache.remove(@intCast(ref.key)),
                .gid => _ = self.glyph_cache.remove(@intCast(ref.key)),
                .face_gid => _ = self.face_gid_cache.remove(ref.key),
                .custom => _ = self.custom_cache.remove(.{ .render_key = ref.key, .fg = ref.fg }),
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
