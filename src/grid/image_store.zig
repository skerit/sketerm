//! Image store — per-pane decoded images + GL texture lifecycle.
//!
//! v1: simple list (not yet keyed by Kitty image_id; add() always
//! creates a new entry). Pending RGBA bytes are uploaded to GL on
//! the main thread inside the pane's render callback.

const std = @import("std");
const c = @import("../c.zig").c;
const image_size = @import("image_size.zig");

pub const Image = struct {
    width: u32,
    height: u32,
    /// Top-left cell of the placement. `cell_row` is the row at
    /// placement time; the live draw row is `draw_row`, recomputed each
    /// frame from `anchor_id` so the image scrolls with its content.
    cell_row: u16,
    cell_col: u16,
    /// Stable line id of the placement's top row (0 = pinned: draw_row
    /// stays at cell_row). Resolved against the Screen every frame.
    anchor_id: u64 = 0,
    /// Live display row, set by `Pane.resolveImageRows` before drawing.
    /// Signed so an image straddling the top edge draws at a negative y.
    draw_row: i32 = 0,
    /// False when the anchor line is currently off-viewport — skip the
    /// draw but keep the image (it may scroll back into view).
    on_screen: bool = true,
    /// 0 until uploaded; cleared on forgetGL after context loss.
    gl_tex: c_uint = 0,
    /// Owned source RGBA. Retained AFTER upload too so that GL
    /// context loss (split / pane shuffle) can re-upload from this
    /// buffer rather than losing the image. Freed on .deleting flush
    /// or store deinit.
    pending: ?[]u8 = null,
    /// Kitty graphics image_id (0 = no id, sixel/iterm2).
    image_id: u32 = 0,
    /// Kitty placement_id (multiple placements of same image).
    placement_id: u32 = 0,
    /// Z-index for stacking. Higher = drawn on top.
    z_index: i32 = 0,
    /// Marked for deletion — flushUploads will free its GL texture.
    deleting: bool = false,
    /// Destination size in cells. 0 = use native pixel size. When
    /// non-zero the renderer scales the image to fit cells_wide *
    /// cell_w x cells_high * cell_h pixels.
    cells_wide: u32 = 0,
    cells_high: u32 = 0,
    /// Pixel offset inside the top-left cell (kitty `X=`/`Y=`).
    cell_x_offset: u32 = 0,
    cell_y_offset: u32 = 0,
    /// Source-rect crop (image-pixel coords). When src_w/src_h are
    /// 0, the whole image is rendered.
    src_x: u32 = 0,
    src_y: u32 = 0,
    src_w: u32 = 0,
    src_h: u32 = 0,
    /// Last seen `Manager.StoredImage.generation` for animated images.
    /// When the source's generation differs, the placement re-fetches
    /// the current frame's RGBA via `replacePending`.
    last_seen_generation: u32 = 0,
    /// True when `pending` holds bytes that haven't been uploaded yet
    /// (newly added image, frame advance, post-context-loss). Cleared
    /// by flushUploads after the GL upload completes.
    pending_dirty: bool = true,
};

pub const Store = struct {
    images: std.ArrayList(Image) = .empty,
    cell_w: f32 = 8.0,
    cell_h: f32 = 16.0,
    allocator: std.mem.Allocator,
    /// When true, flushUploads prints upload outcomes to stderr.
    /// Toggled by `--debug-images` CLI flag.
    debug: bool = false,
    /// Live bytes held in `pending` buffers across all images. Tracked so
    /// the FIFO eviction in `addFull` can keep retained image memory under
    /// `budget_bytes` instead of growing until the kernel OOM-kills us.
    live_bytes: usize = 0,
    /// Cap on `live_bytes` (0 = unlimited). Set from `config.image_memory_mb`.
    budget_bytes: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator };
    }

    /// Free an image's pending buffer and keep `live_bytes` in sync.
    fn freePending(self: *Store, img: *Image) void {
        if (img.pending) |p| {
            self.live_bytes -= p.len;
            self.allocator.free(p);
            img.pending = null;
        }
    }

    /// Evict oldest non-deleting images (FIFO) until `incoming` more bytes
    /// fit under the budget. Evicted images keep their entry (so the GL
    /// texture is torn down by the next flush) but drop their CPU pixels now.
    fn evictForBudget(self: *Store, incoming: usize) void {
        if (self.budget_bytes == 0) return;
        var i: usize = 0;
        while (self.live_bytes > self.budget_bytes - incoming and i < self.images.items.len) : (i += 1) {
            const img = &self.images.items[i];
            if (img.deleting or img.pending == null) continue;
            self.freePending(img);
            img.deleting = true;
        }
    }

    pub fn deinit(self: *Store) void {
        // Free pending pixel buffers. GL textures are owned by their
        // context — when the widget is unrealized, GTK destroys the
        // context which frees the textures. Calling glDeleteTextures
        // here without a current context is a no-op or crash; skip.
        for (self.images.items) |*img| self.freePending(img);
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
        return self.addWithPlacement(rgba, width, height, row, col, image_id, 0, 0);
    }

    pub fn addWithPlacement(
        self: *Store,
        rgba: []const u8,
        width: u32,
        height: u32,
        row: u16,
        col: u16,
        image_id: u32,
        placement_id: u32,
        z_index: i32,
    ) !void {
        try self.addFull(.{
            .rgba = rgba,
            .width = width,
            .height = height,
            .row = row,
            .col = col,
            .image_id = image_id,
            .placement_id = placement_id,
            .z_index = z_index,
        });
    }

    /// Add with full Kitty placement parameters: cell-grid scaling
    /// (`cells_wide`/`cells_high`) and source-rect crop.
    pub const AddOpts = struct {
        rgba: []const u8,
        width: u32,
        height: u32,
        row: u16,
        col: u16,
        image_id: u32 = 0,
        placement_id: u32 = 0,
        z_index: i32 = 0,
        cells_wide: u32 = 0,
        cells_high: u32 = 0,
        src_x: u32 = 0,
        src_y: u32 = 0,
        src_w: u32 = 0,
        src_h: u32 = 0,
        /// Pixel offset inside the top-left cell (kitty `X=`/`Y=`).
        cell_x_offset: u32 = 0,
        cell_y_offset: u32 = 0,
        /// Stable line id of the placement's top row (0 = pin to `row`).
        anchor_id: u64 = 0,
    };

    pub fn addFull(self: *Store, o: AddOpts) !void {
        const need = image_size.byteLen(o.width, o.height, 4) catch |err| return err;
        if (o.rgba.len != need) return error.PixelDataLengthMismatch;
        if (self.budget_bytes > 0 and need > self.budget_bytes) return error.ImageBudgetExceeded;
        // Same (image_id, placement_id) replaces — apps that re-place
        // every frame (emberglyph) would otherwise leak entries.
        // Mark for delete; flushUploads/flushDeletesNoGL frees pending
        // and the GL texture next time around.
        if (o.image_id != 0) {
            for (self.images.items) |*img| {
                const same_image = img.image_id == o.image_id;
                const same_pid = (o.placement_id == 0 and img.placement_id == 0) or img.placement_id == o.placement_id;
                if (same_image and same_pid) img.deleting = true;
            }
        }
        // Keep retained image memory bounded: evict oldest before adding.
        self.evictForBudget(need);
        const copy = try self.allocator.dupe(u8, o.rgba[0..need]);
        errdefer self.allocator.free(copy);
        self.live_bytes += copy.len;
        errdefer self.live_bytes -= copy.len;
        try self.images.append(self.allocator, .{
            .width = o.width,
            .height = o.height,
            .cell_row = o.row,
            .cell_col = o.col,
            .anchor_id = o.anchor_id,
            .draw_row = o.row,
            .pending = copy,
            .image_id = o.image_id,
            .placement_id = o.placement_id,
            .z_index = o.z_index,
            .cells_wide = o.cells_wide,
            .cells_high = o.cells_high,
            .src_x = o.src_x,
            .src_y = o.src_y,
            .src_w = o.src_w,
            .src_h = o.src_h,
            .cell_x_offset = o.cell_x_offset,
            .cell_y_offset = o.cell_y_offset,
        });
    }

    /// Mark images with a matching (image_id, placement_id) pair for
    /// deletion. If placement_id == 0, matches any placement of the
    /// given image_id.
    pub fn markByPlacementForDelete(self: *Store, image_id: u32, placement_id: u32) void {
        for (self.images.items) |*img| {
            if (img.image_id != image_id) continue;
            if (placement_id != 0 and img.placement_id != placement_id) continue;
            img.deleting = true;
        }
    }

    /// Mark all images for deletion. Real teardown happens in
    /// flushUploads when the GL context is current.
    /// Mark every placement a kitty `a=d` request selects. Positional
    /// selectors use the placement's live cell rectangle, so an image
    /// that has scrolled is judged where it is NOW — which is what the
    /// application sees.
    pub fn markSelectedForDelete(
        self: *Store,
        ev: @import("screen.zig").Screen.ImageDeleteEvent,
        numberOf: *const fn (ctx: ?*anyopaque, image_id: u32) u32,
        ctx: ?*anyopaque,
    ) void {
        for (self.images.items) |*img| {
            const cols: i32 = if (img.cells_wide > 0) @intCast(img.cells_wide) else 1;
            const rows: i32 = if (img.cells_high > 0) @intCast(img.cells_high) else 1;
            if (ev.selects(
                img.image_id,
                img.placement_id,
                numberOf(ctx, img.image_id),
                img.z_index,
                @intCast(img.cell_col),
                img.draw_row,
                cols,
                rows,
            )) img.deleting = true;
        }
    }

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

    /// Replace the pending RGBA of every placement matching `image_id`
    /// with `rgba` and mark `pending_dirty` so the next flushUploads
    /// pushes it to GL. Caller does NOT need a current GL context.
    pub fn replacePending(self: *Store, image_id: u32, rgba: []const u8, generation: u32) !void {
        for (self.images.items) |*img| {
            if (img.image_id != image_id) continue;
            if (img.last_seen_generation == generation) continue;
            const need = image_size.byteLen(img.width, img.height, 4) catch continue;
            if (rgba.len != need) continue;
            self.freePending(img);
            const dup = try self.allocator.dupe(u8, rgba[0..need]);
            self.live_bytes += dup.len;
            img.pending = dup;
            img.pending_dirty = true;
            img.last_seen_generation = generation;
        }
    }

    /// How many images are currently held (including those marked
    /// for deletion until the next flushUploads).
    pub fn count(self: *const Store) usize {
        return self.images.items.len;
    }

    /// Drop the cached GL texture IDs — call after context loss
    /// before the next realize. We KEEP all images (their source
    /// pixels live on in img.pending), so the next flushUploads
    /// re-uploads them into the new context. Memory cost: each
    /// image holds its RGBA indefinitely until a delete dispatch.
    pub fn forgetGL(self: *Store) void {
        for (self.images.items) |*img| {
            img.gl_tex = 0;
            img.pending_dirty = true;
        }
    }

    /// Like `forgetGL`, but ALSO `glDeleteTextures` on every image
    /// that has one. Caller must have a current GL context — the
    /// pane's `unrealize` signal is the last opportunity. Without
    /// this, every closed pane leaks one GL texture per kitty image
    /// it had displayed, into the shared window context.
    pub fn releaseGL(self: *Store) void {
        for (self.images.items) |*img| {
            if (img.gl_tex != 0) {
                c.glDeleteTextures(1, &img.gl_tex);
                img.gl_tex = 0;
            }
            img.pending_dirty = true;
        }
    }

    /// Free all images and their pending buffers, ignoring GL
    /// teardown — only safe to call after the GL context is gone
    /// or was never established. Used by tests.
    pub fn freeAllNoGL(self: *Store) void {
        for (self.images.items) |*img| self.freePending(img);
        self.images.clearRetainingCapacity();
    }

    /// Like flushUploads but skips the GL-side work — for tests.
    pub fn flushDeletesNoGL(self: *Store) void {
        var i: usize = 0;
        while (i < self.images.items.len) {
            const img = &self.images.items[i];
            if (img.deleting) {
                self.freePending(img);
                _ = self.images.orderedRemove(i);
                continue;
            }
            i += 1;
        }
    }

    /// Upload pending images to GL, free deleted ones. Caller must
    /// have a current GL context. Source pixels (img.pending) are
    /// retained AFTER upload so re-realize after context loss can
    /// re-upload without losing the image.
    pub fn flushUploads(self: *Store) void {
        // Free GL textures for items marked deleting.
        var i: usize = 0;
        while (i < self.images.items.len) {
            const img = &self.images.items[i];
            if (img.deleting) {
                self.freePending(img);
                if (img.gl_tex != 0) c.glDeleteTextures(1, &img.gl_tex);
                _ = self.images.orderedRemove(i);
                continue;
            }
            i += 1;
        }
        // Upload images that have dirty pending pixels — initial
        // upload (gl_tex == 0) creates the texture; frame advance
        // (gl_tex != 0) does a sub-image update.
        for (self.images.items) |*img| {
            if (!img.pending_dirty) continue;
            const pending = img.pending orelse continue;
            if (img.gl_tex == 0) {
                c.glGenTextures(1, &img.gl_tex);
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
                const err = c.glGetError();
                if (self.debug) {
                    std.debug.print(
                        "[image] upload id={d} placement={d} {d}x{d} cell=({d},{d}) tex={d} glErr=0x{x}\n",
                        .{ img.image_id, img.placement_id, img.width, img.height, img.cell_row, img.cell_col, img.gl_tex, err },
                    );
                }
            } else {
                c.glBindTexture(c.GL_TEXTURE_2D, img.gl_tex);
                c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 4);
                c.glTexSubImage2D(
                    c.GL_TEXTURE_2D,
                    0,
                    0,
                    0,
                    @intCast(img.width),
                    @intCast(img.height),
                    c.GL_RGBA,
                    c.GL_UNSIGNED_BYTE,
                    pending.ptr,
                );
            }
            img.pending_dirty = false;
        }
    }

    /// Same as `replacePending` — kept for back-compat at call sites
    /// that named the operation explicitly. The actual GL upload
    /// happens in `flushUploads` which the render path always calls.
    pub fn uploadFrame(self: *Store, image_id: u32, generation: u32, rgba: []const u8) !void {
        try self.replacePending(image_id, rgba, generation);
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

test "addFull rejects invalid dimensions and inconsistent pixel lengths" {
    var s = Store.init(std.testing.allocator);
    defer s.deinit();
    const rgba = [_]u8{0} ** 17;

    try std.testing.expectError(image_size.Error.InvalidDimensions, s.addFull(.{
        .rgba = rgba[0..16],
        .width = 0,
        .height = 2,
        .row = 0,
        .col = 0,
    }));
    try std.testing.expectError(image_size.Error.TooLarge, s.addFull(.{
        .rgba = rgba[0..16],
        .width = std.math.maxInt(u32),
        .height = std.math.maxInt(u32),
        .row = 0,
        .col = 0,
    }));
    try std.testing.expectError(error.PixelDataLengthMismatch, s.addFull(.{
        .rgba = rgba[0..15],
        .width = 2,
        .height = 2,
        .row = 0,
        .col = 0,
    }));
    try std.testing.expectError(error.PixelDataLengthMismatch, s.addFull(.{
        .rgba = &rgba,
        .width = 2,
        .height = 2,
        .row = 0,
        .col = 0,
    }));
    try std.testing.expectEqual(@as(usize, 0), s.count());
}

test "addFull enforces the decoded budget at the exact edge" {
    const rgba = [_]u8{0} ** 16;

    var exact = Store.init(std.testing.allocator);
    defer exact.deinit();
    exact.budget_bytes = rgba.len;
    try exact.addFull(.{ .rgba = &rgba, .width = 2, .height = 2, .row = 0, .col = 0 });
    try std.testing.expectEqual(rgba.len, exact.live_bytes);

    var undersized = Store.init(std.testing.allocator);
    defer undersized.deinit();
    undersized.budget_bytes = rgba.len - 1;
    try std.testing.expectError(error.ImageBudgetExceeded, undersized.addFull(.{
        .rgba = &rgba,
        .width = 2,
        .height = 2,
        .row = 0,
        .col = 0,
    }));
    try std.testing.expectEqual(@as(usize, 0), undersized.live_bytes);
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

test "addWithPlacement stores placement_id and z_index" {
    var s = Store.init(std.testing.allocator);
    defer s.images.deinit(std.testing.allocator);
    defer s.freeAllNoGL();
    const rgba = [_]u8{0} ** 16;
    try s.addWithPlacement(&rgba, 2, 2, 0, 0, 7, 42, 5);
    try std.testing.expectEqual(@as(u32, 7), s.images.items[0].image_id);
    try std.testing.expectEqual(@as(u32, 42), s.images.items[0].placement_id);
    try std.testing.expectEqual(@as(i32, 5), s.images.items[0].z_index);
}

test "markByPlacementForDelete: matches exact placement" {
    var s = Store.init(std.testing.allocator);
    defer s.images.deinit(std.testing.allocator);
    defer s.freeAllNoGL();
    const rgba = [_]u8{0} ** 16;
    try s.addWithPlacement(&rgba, 2, 2, 0, 0, 1, 100, 0);
    try s.addWithPlacement(&rgba, 2, 2, 0, 0, 1, 200, 0);
    try s.addWithPlacement(&rgba, 2, 2, 0, 0, 2, 100, 0);
    s.markByPlacementForDelete(1, 100);
    s.flushDeletesNoGL();
    // Only the (image_id=1, placement_id=100) entry deleted.
    try std.testing.expectEqual(@as(usize, 2), s.count());
}

test "markByPlacementForDelete: placement_id=0 matches all placements of image" {
    var s = Store.init(std.testing.allocator);
    defer s.images.deinit(std.testing.allocator);
    defer s.freeAllNoGL();
    const rgba = [_]u8{0} ** 16;
    try s.addWithPlacement(&rgba, 2, 2, 0, 0, 1, 100, 0);
    try s.addWithPlacement(&rgba, 2, 2, 0, 0, 1, 200, 0);
    try s.addWithPlacement(&rgba, 2, 2, 0, 0, 2, 100, 0);
    s.markByPlacementForDelete(1, 0);
    s.flushDeletesNoGL();
    try std.testing.expectEqual(@as(usize, 1), s.count());
    try std.testing.expectEqual(@as(u32, 2), s.images.items[0].image_id);
}

test "forgetGL keeps all images, drops their GL handles" {
    var s = Store.init(std.testing.allocator);
    defer s.images.deinit(std.testing.allocator);
    defer s.freeAllNoGL();
    const rgba = [_]u8{0} ** 16;
    try s.addWithId(&rgba, 2, 2, 0, 0, 1);
    try s.addWithId(&rgba, 2, 2, 0, 0, 2);
    s.images.items[0].gl_tex = 42; // simulate uploaded
    s.images.items[1].gl_tex = 7;
    s.forgetGL();
    try std.testing.expectEqual(@as(usize, 2), s.count());
    try std.testing.expectEqual(@as(c_uint, 0), s.images.items[0].gl_tex);
    try std.testing.expectEqual(@as(c_uint, 0), s.images.items[1].gl_tex);
    try std.testing.expect(s.images.items[0].pending != null);
    try std.testing.expect(s.images.items[1].pending != null);
}

test "budget evicts oldest images FIFO and bounds live_bytes" {
    var s = Store.init(std.testing.allocator);
    defer s.images.deinit(std.testing.allocator);
    defer s.freeAllNoGL();
    const px = [_]u8{0} ** (4 * 4 * 4); // 64 bytes per image
    s.budget_bytes = 64 * 3; // room for exactly three live images
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        try s.addFull(.{ .rgba = &px, .width = 4, .height = 4, .row = 0, .col = 0, .image_id = i + 1 });
    }
    // Retained pixel memory never exceeds the budget.
    try std.testing.expect(s.live_bytes <= s.budget_bytes);
    try std.testing.expectEqual(@as(usize, 64 * 3), s.live_bytes);
    // The three newest survive (still hold pixels); the rest were evicted.
    var live: usize = 0;
    for (s.images.items) |*img| {
        if (img.pending != null) live += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), live);
    // The most recent image kept its pixels; the oldest lost them.
    try std.testing.expect(s.images.items[s.images.items.len - 1].pending != null);
    try std.testing.expect(s.images.items[0].pending == null);
    try std.testing.expect(s.images.items[0].deleting);
}

test "budget = 0 means unlimited (no eviction)" {
    var s = Store.init(std.testing.allocator);
    defer s.images.deinit(std.testing.allocator);
    defer s.freeAllNoGL();
    const px = [_]u8{0} ** 16;
    var i: u32 = 0;
    while (i < 50) : (i += 1) try s.addWithId(&px, 2, 2, 0, 0, i + 1);
    for (s.images.items) |*img| try std.testing.expect(img.pending != null);
    try std.testing.expectEqual(@as(usize, 50 * 16), s.live_bytes);
}
