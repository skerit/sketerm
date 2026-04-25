//! Line — one row of Cells plus dirty / wrap metadata.

const std = @import("std");
const Cell = @import("cell.zig").Cell;

/// VT100 line-scaling mode (ESC #3/#4/#5/#6).
pub const Scaling = enum(u8) {
    single = 0, // DECSWL — single width, single height (default)
    dwl = 1, // DECDWL — double width, single height
    dhl_top = 2, // DECDHL top half
    dhl_bot = 3, // DECDHL bottom half
};

pub const Line = struct {
    cells: []Cell,
    /// True if the line was modified since the renderer last
    /// observed it. Renderer clears after consuming.
    dirty: bool = true,
    /// True if this line is the soft-wrap continuation of the line
    /// above (set by the printer when autowrap triggered).
    continues_above: bool = false,
    /// Monotonic line ID assigned at line birth (LF / scroll / fill).
    /// Stays attached to the same logical content as it scrolls into
    /// scrollback or shifts under reflow. 0 = unassigned (legacy
    /// callers; init() leaves it at 0 — Screen owns the ID counter).
    id: u64 = 0,
    /// Per-line scaling (DECDHL/DECDWL/DECSWL). Resets to .single on
    /// .clear() — VT100 spec keeps it through erases of cell content
    /// but resets when the line is fully recycled (scroll, RIS).
    scaling: Scaling = .single,

    pub fn init(allocator: std.mem.Allocator, cols: u16) !Line {
        const cells = try allocator.alloc(Cell, cols);
        @memset(cells, .{});
        return .{ .cells = cells };
    }

    pub fn deinit(self: *Line, allocator: std.mem.Allocator) void {
        if (self.cells.len > 0) allocator.free(self.cells);
        self.cells = &.{};
    }

    pub fn clear(self: *Line) void {
        @memset(self.cells, .{});
        self.dirty = true;
        self.continues_above = false;
        self.scaling = .single;
    }

    /// Erase a half-open range [from, to).
    pub fn eraseRange(self: *Line, from: u16, to: u16) void {
        const lo = @min(from, @as(u16, @intCast(self.cells.len)));
        const hi = @min(to, @as(u16, @intCast(self.cells.len)));
        if (lo >= hi) return;
        @memset(self.cells[lo..hi], .{});
        self.dirty = true;
    }
};
