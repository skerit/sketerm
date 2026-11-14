//! The cell grid's paint order, the one copy `TerminalSurface` and the
//! pixel rigs both draw through.
//!
//! Backgrounds (CellPass rows, then GridPass overlay rows), cell-border
//! below-text strokes, text (both passes, with every overlay up to a
//! focused block cursor), cell-border above-text strokes, then the
//! remaining cursor shapes and the pane chrome. Images are not part of
//! it: they keep their own place around the grid.

const Atlas = @import("atlas.zig").Atlas;
const CellPass = @import("cell_pass.zig").CellPass;
const GridPass = @import("grid_pass.zig").GridPass;
const BorderPass = @import("border_pass.zig").BorderPass;

pub fn drawGrid(cell: *CellPass, grid: *GridPass, border: *BorderPass, atlas: *Atlas, viewport_w: i32, viewport_h: i32) void {
    cell.drawBackgrounds(atlas, viewport_w, viewport_h);
    grid.drawLayer(atlas, viewport_w, viewport_h, .backgrounds);
    border.draw(.below_text, viewport_w, viewport_h);
    cell.drawText(atlas, viewport_w, viewport_h);
    grid.drawLayer(atlas, viewport_w, viewport_h, .text);
    border.draw(.above_text, viewport_w, viewport_h);
    grid.drawLayer(atlas, viewport_w, viewport_h, .chrome);
}
