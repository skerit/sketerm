//! Image store — per-pane decoded images + GL texture lifecycle.
//!
//! v1: simple list (not yet keyed by Kitty image_id; add() always
//! creates a new entry). Pending RGBA bytes are uploaded to GL on
//! the main thread inside the pane's render callback.

const std = @import("std");
const c = @import("../c.zig").c;

pub const Image = struct {
    width: u32,
    height: u32,
    /// Top-left cell of the placement.
    cell_row: u16,
    cell_col: u16,
    /// 0 until uploaded.
    gl_tex: c_uint = 0,
    /// Owned pixel buffer pending GL upload.
    pending: ?[]u8 = null,
};

pub const Store = struct {
    images: std.ArrayList(Image) = .{},
    cell_w: f32 = 8.0,
    cell_h: f32 = 16.0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Store) void {
        for (self.images.items) |*img| {
            if (img.pending) |p| self.allocator.free(p);
            if (img.gl_tex != 0) c.glDeleteTextures(1, &img.gl_tex);
        }
        self.images.deinit(self.allocator);
    }

    /// Add an image. Copies the RGBA bytes; caller retains ownership
    /// of the input slice.
    pub fn add(
        self: *Store,
        rgba: []const u8,
        width: u32,
        height: u32,
        row: u16,
        col: u16,
    ) !void {
        const need = width * height * 4;
        if (rgba.len < need) return error.NotEnoughPixels;
        const copy = try self.allocator.dupe(u8, rgba[0..need]);
        try self.images.append(self.allocator, .{
            .width = width,
            .height = height,
            .cell_row = row,
            .cell_col = col,
            .pending = copy,
        });
    }

    /// Upload pending images to GL. Caller must have a current
    /// GL context.
    pub fn flushUploads(self: *Store) void {
        for (self.images.items) |*img| {
            const pending = img.pending orelse continue;
            if (img.gl_tex == 0) c.glGenTextures(1, &img.gl_tex);
            c.glBindTexture(c.GL_TEXTURE_2D, img.gl_tex);
            c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 4);
            c.glTexImage2D(
                c.GL_TEXTURE_2D,
                0,
                c.GL_RGBA8,
                @intCast(img.width),
                @intCast(img.height),
                0,
                c.GL_RGBA,
                c.GL_UNSIGNED_BYTE,
                pending.ptr,
            );
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
            self.allocator.free(pending);
            img.pending = null;
        }
    }
};
