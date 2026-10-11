//! Kitty Unicode-placeholder tiles, drawn from the grid being rendered.
//!
//! A placeholder cell is the image's content in that cell, so the tiles
//! are resolved every frame from the cells on screen (`Screen`
//! `collectPlaceholderRuns`) instead of being turned into placements when
//! printed: text written over a cell retires its tile, and an image that
//! arrives after its cells shows without them being printed again.

const std = @import("std");
const grid_screen = @import("../grid/screen.zig");
const Screen = grid_screen.Screen;
const ImageStore = @import("../grid/image_store.zig").Store;
const ImagePass = @import("image_pass.zig").ImagePass;

/// Per-frame working lists, kept by the caller so a frame allocates
/// nothing once they have grown.
pub const Scratch = struct {
    runs: std.ArrayList(grid_screen.PlaceholderRun) = .empty,
    quads: std.ArrayList(ImagePass.Quad) = .empty,

    pub fn deinit(self: *Scratch, allocator: std.mem.Allocator) void {
        self.runs.deinit(allocator);
        self.quads.deinit(allocator);
    }
};

/// Draw the placeholder tiles of the rows on screen with one texture bind
/// per image, at the store's cell size and the pass's padding. Caller
/// must have a current GL context.
pub fn draw(
    screen: *Screen,
    store: *ImageStore,
    pass: *ImagePass,
    scratch: *Scratch,
    allocator: std.mem.Allocator,
    viewport_w: i32,
    viewport_h: i32,
) void {
    // Textures of images the store has dropped go first, every frame, so
    // `d=I` frees GPU memory even when no tile is drawn again.
    if (store.sources.items.len > 0) store.sweepSources(&screen.kitty_images);
    if (screen.ph_tiles.count() == 0) return;
    const runs = &scratch.runs;
    runs.clearRetainingCapacity();
    screen.collectPlaceholderRuns(allocator, runs) catch return;
    if (runs.items.len == 0) return;
    std.mem.sort(grid_screen.PlaceholderRun, runs.items, {}, struct {
        fn lt(_: void, a: grid_screen.PlaceholderRun, b: grid_screen.PlaceholderRun) bool {
            return a.image_id < b.image_id;
        }
    }.lt);

    const cw = store.cell_w;
    const ch = store.cell_h;
    var first: usize = 0;
    while (first < runs.items.len) {
        const id = runs.items[first].image_id;
        var end = first;
        while (end < runs.items.len and runs.items[end].image_id == id) end += 1;
        defer first = end;
        // A cell whose image is not stored draws nothing; the U+10EEEE
        // glyph itself is never drawn either (`Atlas.lookupGlyph`).
        const stored = screen.kitty_images.get(id) orelse continue;
        const g = screen.placeholderGrid(id, @intFromFloat(cw), @intFromFloat(ch)) orelse continue;
        scratch.quads.clearRetainingCapacity();
        for (runs.items[first..end]) |run| {
            const q = quadFor(run, g, cw, ch, pass.pad) orelse continue;
            scratch.quads.append(allocator, q) catch return;
        }
        if (scratch.quads.items.len == 0) continue;
        pass.drawQuads(store.sourceTexture(id, stored), scratch.quads.items, viewport_w, viewport_h);
    }
}

/// The canvas quad and image sub-rectangle of one run, stretched over the
/// image's cell grid, or null when the run lies outside that grid.
fn quadFor(run: grid_screen.PlaceholderRun, g: Screen.PlaceholderGrid, cw: f32, ch: f32, pad: f32) ?ImagePass.Quad {
    if (run.img_row >= g.rows or run.img_col >= g.cols) return null;
    const len: u32 = @min(run.len, g.cols - run.img_col);
    const fcols: f32 = @floatFromInt(g.cols);
    const frows: f32 = @floatFromInt(g.rows);
    const c0: f32 = @floatFromInt(run.img_col);
    const r0: f32 = @floatFromInt(run.img_row);
    const flen: f32 = @floatFromInt(len);
    return .{
        .x = pad + @as(f32, @floatFromInt(run.col)) * cw,
        .y = pad + @as(f32, @floatFromInt(run.display_row)) * ch,
        .w = flen * cw,
        .h = ch,
        .uv0 = .{ c0 / fcols, r0 / frows },
        .uv1 = .{ (c0 + flen) / fcols, (r0 + 1) / frows },
    };
}
