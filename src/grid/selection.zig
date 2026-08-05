//! Selection — text selection model.
//!
//! Coordinates use signed i32 so negative rows can refer to scrollback.

const std = @import("std");
const Cell = @import("cell.zig").Cell;

pub const Mode = enum { none, normal, rectangular, line_select };

pub const Selection = struct {
    mode: Mode = .none,
    /// Anchor (where mouse-down happened).
    anchor_row: i32 = 0,
    anchor_col: i32 = 0,
    /// Active end (current mouse position).
    end_row: i32 = 0,
    end_col: i32 = 0,

    pub fn isActive(self: *const Selection) bool {
        return self.mode != .none;
    }

    /// True when the selection actually covers at least one cell.
    ///
    /// `isActive` is not that test: a bare left click calls `start`
    /// and leaves mode = .normal with anchor == end, so the selection
    /// is active but extracts to "". UI that offers a Copy affordance
    /// must gate on this, or the row is sensitive and does nothing.
    /// A line_select of one row is a whole line, so it always counts.
    pub fn hasContent(self: *const Selection) bool {
        if (!self.isActive()) return false;
        if (self.mode == .line_select) return true;
        return self.anchor_row != self.end_row or self.anchor_col != self.end_col;
    }

    pub fn start(self: *Selection, row: i32, col: i32, mode: Mode) void {
        self.mode = mode;
        self.anchor_row = row;
        self.anchor_col = col;
        self.end_row = row;
        self.end_col = col;
    }

    pub fn extend(self: *Selection, row: i32, col: i32) void {
        self.end_row = row;
        self.end_col = col;
    }

    pub fn clear(self: *Selection) void {
        self.mode = .none;
    }

    pub const Rect = struct {
        top_row: i32,
        top_col: i32,
        bot_row: i32,
        bot_col: i32,
    };

    /// Returns the selection bounds, normalized so top is before bottom.
    pub fn rect(self: *const Selection) ?Rect {
        if (!self.isActive()) return null;
        if (self.anchor_row < self.end_row) {
            return .{
                .top_row = self.anchor_row,
                .top_col = self.anchor_col,
                .bot_row = self.end_row,
                .bot_col = self.end_col,
            };
        }
        if (self.anchor_row > self.end_row) {
            return .{
                .top_row = self.end_row,
                .top_col = self.end_col,
                .bot_row = self.anchor_row,
                .bot_col = self.anchor_col,
            };
        }
        // Same row — order columns.
        if (self.anchor_col <= self.end_col) {
            return .{
                .top_row = self.anchor_row,
                .top_col = self.anchor_col,
                .bot_row = self.end_row,
                .bot_col = self.end_col,
            };
        }
        return .{
            .top_row = self.end_row,
            .top_col = self.end_col,
            .bot_row = self.anchor_row,
            .bot_col = self.anchor_col,
        };
    }

    /// True if (row, col) is inside the selection.
    pub fn contains(self: *const Selection, row: i32, col: i32) bool {
        const r = self.rect() orelse return false;
        switch (self.mode) {
            .none => return false,
            .normal => {
                if (row < r.top_row or row > r.bot_row) return false;
                if (row == r.top_row and col < r.top_col) return false;
                if (row == r.bot_row and col >= r.bot_col) return false;
                return true;
            },
            .rectangular => {
                const lo = @min(r.top_col, r.bot_col);
                const hi = @max(r.top_col, r.bot_col);
                return row >= r.top_row and row <= r.bot_row and col >= lo and col < hi;
            },
            .line_select => return row >= r.top_row and row <= r.bot_row,
        }
    }
};

test "selection rect normalizes" {
    var s = Selection{};
    s.start(2, 5, .normal);
    s.extend(0, 1);
    const r = s.rect().?;
    try std.testing.expectEqual(@as(i32, 0), r.top_row);
    try std.testing.expectEqual(@as(i32, 1), r.top_col);
    try std.testing.expectEqual(@as(i32, 2), r.bot_row);
    try std.testing.expectEqual(@as(i32, 5), r.bot_col);
}

test "selection contains normal" {
    var s = Selection{};
    s.start(1, 2, .normal);
    s.extend(2, 5);
    try std.testing.expect(s.contains(1, 2));
    try std.testing.expect(s.contains(1, 10)); // mid line
    try std.testing.expect(s.contains(2, 0));
    try std.testing.expect(!s.contains(0, 5)); // before
    try std.testing.expect(!s.contains(2, 5)); // exclusive end col
    try std.testing.expect(!s.contains(2, 6)); // after end
    try std.testing.expect(!s.contains(1, 1)); // before start col on top row
}

test "hasContent separates a bare click from a real selection" {
    var s = Selection{};
    try std.testing.expect(!s.hasContent()); // never started

    // A bare left click: start() with no drag. Active, but empty —
    // this is the case that used to leave a Copy row sensitive.
    s.start(3, 7, .normal);
    try std.testing.expect(s.isActive());
    try std.testing.expect(!s.hasContent());

    // One cell to the right is a real selection.
    s.extend(3, 8);
    try std.testing.expect(s.hasContent());

    // Same for a rectangular selection collapsed to a point.
    s.start(1, 1, .rectangular);
    try std.testing.expect(!s.hasContent());
    s.extend(4, 1);
    try std.testing.expect(s.hasContent());

    // A line selection of a single row still covers that whole line.
    s.start(2, 0, .line_select);
    try std.testing.expect(s.hasContent());

    s.clear();
    try std.testing.expect(!s.hasContent());
}
