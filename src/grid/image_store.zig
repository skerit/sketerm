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
    /// Kitty graphics image_id (0 = no id, sixel/iterm2).
    image_id: u32 = 0,
    /// Marked for deletion — flushUploads will free its GL texture.
    deleting: bool = false,
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
        // Free pending pixel buffers. GL textures are owned by their
        // context — when the widget is unrealized, GTK destroys the
        // context which frees the textures. Calling glDeleteTextures
        // here without a current context is a no-op or crash; skip.
        for (self.images.items) |*img| {
            if (img.pending) |p| self.allocator.free(p);
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
        return self.addWithId(rgba, width, height, row, col, 0);
    }

    pub fn addWithId(
        self: *Store,
        rgba: []const u8,
        width: u32,
        height: u32,
        row: u16,
        col: u16,
        image_id: u32,
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
            .image_id = image_id,
        });
    }

    /// Mark all images for deletion. Real teardown happens in
    /// flushUploads when the GL context is current.
    pub fn markAllForDelete(self: *Store) void {
        for (self.images.items) |*img| img.deleting = true;
    }

    /// Mark images with a matching kitty image_id for deletion.
    pub fn markByIdForDelete(self: *Store, image_id: u32) void {
        if (image_id == 0) return;
        for (self.images.items) |*img| {
            if (img.image_id == image_id) img.deleting = true;
        }
    }

    /// How many images are currently held (including those marked
    /// for deletion until the next flushUploads).
    pub fn count(self: *const Store) usize {
        return self.images.items.len;
    }

    /// Drop the cached GL texture IDs — call after context loss
    /// before the next realize. The textures are gone with the
    /// dead context; without `pending` data we can't rebuild them,
    /// so any previously-uploaded image is effectively lost. This
    /// is a v1 limitation (a re-upload mechanism would need to
    /// keep the source pixels around indefinitely).
    pub fn forgetGL(self: *Store) void {
        // Drop everything that has no pending data to re-upload.
        // Items with pending data still have their pixels and can
        // be re-uploaded on the next flush.
        var i: usize = 0;
        while (i < self.images.items.len) {
            if (self.images.items[i].pending == null) {
                _ = self.images.orderedRemove(i);
                continue;
            }
            self.images.items[i].gl_tex = 0;
            i += 1;
        }
    }

    /// Free all images and their pending buffers, ignoring GL
    /// teardown — only safe to call after the GL context is gone
    /// or was never established. Used by tests.
    pub fn freeAllNoGL(self: *Store) void {
        for (self.images.items) |*img| {
            if (img.pending) |p| self.allocator.free(p);
        }
        self.images.clearRetainingCapacity();
    }

    /// Like flushUploads but skips the GL-side work — for tests.
    pub fn flushDeletesNoGL(self: *Store) void {
        var i: usize = 0;
        while (i < self.images.items.len) {
            const img = &self.images.items[i];
            if (img.deleting) {
                if (img.pending) |p| self.allocator.free(p);
                _ = self.images.orderedRemove(i);
                continue;
            }
            i += 1;
        }
    }

    /// Upload pending images to GL, free deleted ones. Caller must
    /// have a current GL context.
    pub fn flushUploads(self: *Store) void {
        // Free GL textures for items marked deleting.
        var i: usize = 0;
        while (i < self.images.items.len) {
            const img = &self.images.items[i];
            if (img.deleting) {
                if (img.pending) |p| self.allocator.free(p);
                if (img.gl_tex != 0) c.glDeleteTextures(1, &img.gl_tex);
                _ = self.images.orderedRemove(i);
                continue;
            }
            i += 1;
        }
        // Upload pending pixel buffers.
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

test "addWithId stores image_id" {
    var s = Store.init(std.testing.allocator);
    defer s.images.deinit(std.testing.allocator);
    defer s.freeAllNoGL();
    const rgba = [_]u8{0} ** 16; // 2x2 RGBA
    try s.addWithId(&rgba, 2, 2, 0, 0, 42);
    try std.testing.expectEqual(@as(u32, 42), s.images.items[0].image_id);
}

test "markByIdForDelete flags only matching images" {
    var s = Store.init(std.testing.allocator);
    defer s.images.deinit(std.testing.allocator);
    defer s.freeAllNoGL();
    const rgba = [_]u8{0} ** 16;
    try s.addWithId(&rgba, 2, 2, 0, 0, 1);
    try s.addWithId(&rgba, 2, 2, 0, 0, 2);
    try s.addWithId(&rgba, 2, 2, 0, 0, 1);
    s.markByIdForDelete(1);
    try std.testing.expect(s.images.items[0].deleting);
    try std.testing.expect(!s.images.items[1].deleting);
    try std.testing.expect(s.images.items[2].deleting);
    s.flushDeletesNoGL();
    try std.testing.expectEqual(@as(usize, 1), s.count());
    try std.testing.expectEqual(@as(u32, 2), s.images.items[0].image_id);
}

test "markAllForDelete flags everything" {
    var s = Store.init(std.testing.allocator);
    defer s.images.deinit(std.testing.allocator);
    defer s.freeAllNoGL();
    const rgba = [_]u8{0} ** 16;
    try s.addWithId(&rgba, 2, 2, 0, 0, 1);
    try s.addWithId(&rgba, 2, 2, 0, 0, 2);
    s.markAllForDelete();
    s.flushDeletesNoGL();
    try std.testing.expectEqual(@as(usize, 0), s.count());
}
