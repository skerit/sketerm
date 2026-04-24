//! Glyph atlas — FreeType raster + GL texture page (R8 grayscale).
//!
//! v1: single 1024×1024 R8 page, shelf-packed. LRU eviction and
//! multi-page growth come post-M3.
//!
//! Lifecycle:
//!   - `init`: load FreeType face, compute cell metrics. No GL.
//!   - `realize`: must be called with a current GL context. Creates
//!     the GL texture.
//!   - `lookupOrLoad`: rasterize codepoint if absent; pack; upload.
//!   - `deinit`: frees FreeType + GL texture.

const std = @import("std");
const c = @import("../c.zig").c;

pub const PAGE_SIZE: u32 = 1024;

pub const Glyph = struct {
    /// Pixel size of the rasterized bitmap.
    w: u16,
    h: u16,
    /// Bitmap origin relative to the pen position.
    bearing_x: i16,
    bearing_y: i16,
    /// Horizontal advance in fractional pixels.
    advance: f32,
    /// UV in atlas (0..1).
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
};

pub const Atlas = struct {
    ft_lib: c.FT_Library,
    ft_face: c.FT_Face,

    /// Cell metrics in pixels — used by the renderer to lay out the grid.
    cell_w: u16,
    cell_h: u16,
    /// Pixels above baseline.
    ascent: i16,
    /// Pixels below baseline (positive).
    descent: i16,

    /// GL texture id (0 until realize).
    gl_tex: c_uint = 0,
    realized: bool = false,

    /// Shelf-pack state.
    pack_x: u32 = 0,
    pack_y: u32 = 0,
    shelf_h: u32 = 0,

    cache: std.AutoHashMap(u32, Glyph),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, font_path: [*:0]const u8, size_px: u16) !*Atlas {
        var lib: c.FT_Library = undefined;
        if (c.FT_Init_FreeType(&lib) != 0) return error.FreeTypeInit;
        errdefer _ = c.FT_Done_FreeType(lib);

        var face: c.FT_Face = undefined;
        if (c.FT_New_Face(lib, font_path, 0, &face) != 0) return error.FontLoad;
        errdefer _ = c.FT_Done_Face(face);

        if (c.FT_Set_Pixel_Sizes(face, 0, size_px) != 0) return error.SetSize;

        const m = face.*.size.*.metrics;
        const cell_w: u16 = @intCast(@as(c_long, m.max_advance) >> 6);
        const cell_h: u16 = @intCast((@as(c_long, m.ascender) - @as(c_long, m.descender)) >> 6);
        const ascent: i16 = @intCast(@as(c_long, m.ascender) >> 6);
        const descent: i16 = @intCast(-@as(c_long, m.descender) >> 6);

        const self = try allocator.create(Atlas);
        errdefer allocator.destroy(self);
        self.* = .{
            .ft_lib = lib,
            .ft_face = face,
            .cell_w = cell_w,
            .cell_h = cell_h,
            .ascent = ascent,
            .descent = descent,
            .cache = std.AutoHashMap(u32, Glyph).init(allocator),
            .allocator = allocator,
        };
        return self;
    }

    /// Call with a current GL context. Idempotent.
    pub fn realize(self: *Atlas) void {
        if (self.realized) return;
        c.glGenTextures(1, &self.gl_tex);
        c.glBindTexture(c.GL_TEXTURE_2D, self.gl_tex);
        c.glTexImage2D(
            c.GL_TEXTURE_2D,
            0,
            c.GL_R8,
            @intCast(PAGE_SIZE),
            @intCast(PAGE_SIZE),
            0,
            c.GL_RED,
            c.GL_UNSIGNED_BYTE,
            null,
        );
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
        self.realized = true;
    }

    pub fn deinit(self: *Atlas) void {
        if (self.realized) {
            c.glDeleteTextures(1, &self.gl_tex);
            self.realized = false;
        }
        self.cache.deinit();
        _ = c.FT_Done_Face(self.ft_face);
        _ = c.FT_Done_FreeType(self.ft_lib);
        self.allocator.destroy(self);
    }

    /// Get an existing glyph or rasterize + upload.
    pub fn lookupOrLoad(self: *Atlas, codepoint: u32) !Glyph {
        if (self.cache.get(codepoint)) |g| return g;

        // Rasterize.
        const gid = c.FT_Get_Char_Index(self.ft_face, codepoint);
        if (gid == 0 and codepoint != 0) {
            return self.cacheEmpty(codepoint);
        }

        if (c.FT_Load_Glyph(self.ft_face, gid, c.FT_LOAD_RENDER | c.FT_LOAD_TARGET_LIGHT) != 0) {
            return self.cacheEmpty(codepoint);
        }

        const slot = self.ft_face.*.glyph;
        const bm = slot.*.bitmap;
        const w: u32 = bm.width;
        const h: u32 = bm.rows;

        // Shelf-pack.
        if (self.pack_x + w + 1 > PAGE_SIZE) {
            self.pack_x = 0;
            self.pack_y += self.shelf_h + 1;
            self.shelf_h = 0;
        }
        if (h > self.shelf_h) self.shelf_h = h;
        if (self.pack_y + h > PAGE_SIZE) {
            // Atlas full — return placeholder.
            return self.cacheEmpty(codepoint);
        }

        const px = self.pack_x;
        const py = self.pack_y;

        // Upload pixels.
        if (w > 0 and h > 0 and self.realized) {
            c.glBindTexture(c.GL_TEXTURE_2D, self.gl_tex);
            c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 1);
            c.glTexSubImage2D(
                c.GL_TEXTURE_2D,
                0,
                @intCast(px),
                @intCast(py),
                @intCast(w),
                @intCast(h),
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
        };

        self.pack_x += w + 1;
        try self.cache.put(codepoint, g);
        return g;
    }

    fn cacheEmpty(self: *Atlas, codepoint: u32) Glyph {
        const empty = Glyph{
            .w = 0,
            .h = 0,
            .bearing_x = 0,
            .bearing_y = 0,
            .advance = @floatFromInt(self.cell_w),
            .u0 = 0,
            .v0 = 0,
            .u1 = 0,
            .v1 = 0,
        };
        _ = self.cache.put(codepoint, empty) catch {};
        return empty;
    }
};
