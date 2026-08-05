//! Overlay-scrollbar geometry and hit-testing.
//!
//! Pure math, no GL and no GTK: `GridPass` draws from `layout` and
//! `Pane` hit-tests pointer events against the same result, so the
//! thumb a user grabs is always the thumb they see.
//!
//! Every length is in framebuffer (physical) pixels — the unit the
//! render passes work in. Callers holding GTK logical coordinates
//! must scale them by the widget's scale factor first.

const std = @import("std");

pub const Mode = @import("../config.zig").ScrollbarMode;

/// Floor on the thumb so a huge scrollback still leaves something
/// grabbable. It costs travel, which is why `layout` maps position
/// over `h - thumb_h` rather than over `h`.
pub const MIN_THUMB: f32 = 8.0;

/// Everything the geometry depends on.
pub const View = struct {
    /// Pane framebuffer size.
    canvas_w: f32,
    canvas_h: f32,
    /// Track width; <= 0 disables the scrollbar.
    width: f32,
    /// Lines of scrollback above the live screen.
    sb_count: u32,
    /// Visible rows.
    rows: u16,
    /// Lines scrolled back from the live bottom (0 = at bottom).
    view_off: u32,
};

pub const Layout = struct {
    /// Track rectangle (the track always spans the full height).
    x: f32,
    w: f32,
    h: f32,
    thumb_y: f32,
    thumb_h: f32,
};

pub const Hit = enum { none, thumb, page_up, page_down };

/// True when the scrollbar should be drawn and take pointer events.
pub fn visible(mode: Mode, width: f32, sb_count: u32) bool {
    if (width <= 0) return false;
    return switch (mode) {
        .never => false,
        .auto => sb_count > 0,
        .always => true,
    };
}

/// Track + thumb rectangles, or null when the pane is too small to
/// hold either.
pub fn layout(v: View) ?Layout {
    if (v.width <= 0 or v.canvas_h <= 0 or v.canvas_w <= v.width) return null;
    const total: f32 = @floatFromInt(@as(u64, v.sb_count) + v.rows);
    if (total <= 0) return null;
    const h = v.canvas_h;
    const rows_f: f32 = @floatFromInt(v.rows);
    const thumb_h = @min(h, @max(MIN_THUMB, rows_f / total * h));
    const travel = h - thumb_h;
    const view_off = @min(v.view_off, v.sb_count);
    // view_top = first buffer line on screen. It runs 0..sb_count,
    // and drives the thumb over the whole travel — which reduces to
    // the naive `view_top / total * h` whenever MIN_THUMB isn't
    // clamping, and stays consistent when it is.
    const thumb_y = if (v.sb_count == 0) 0.0 else blk: {
        const view_top: f32 = @floatFromInt(v.sb_count - view_off);
        break :blk view_top / @as(f32, @floatFromInt(v.sb_count)) * travel;
    };
    return .{
        .x = v.canvas_w - v.width,
        .w = v.width,
        .h = h,
        .thumb_y = thumb_y,
        .thumb_h = thumb_h,
    };
}

/// Which part of the scrollbar a point lands on. Points outside the
/// track are `.none` — the caller must then fall through to its
/// normal selection / mouse-reporting handling.
pub fn hitTest(l: Layout, x: f32, y: f32) Hit {
    if (x < l.x or x >= l.x + l.w) return .none;
    if (y < 0 or y >= l.h) return .none;
    if (y < l.thumb_y) return .page_up;
    if (y >= l.thumb_y + l.thumb_h) return .page_down;
    return .thumb;
}

/// The `view_offset` that puts the thumb's TOP at `thumb_y`.
pub fn offsetForThumbTop(v: View, l: Layout, thumb_y: f32) u32 {
    if (v.sb_count == 0) return 0;
    const travel = l.h - l.thumb_h;
    if (travel <= 0) return 0;
    const frac = std.math.clamp(thumb_y / travel, 0.0, 1.0);
    const sb: f32 = @floatFromInt(v.sb_count);
    const view_top: u32 = @intFromFloat(@round(frac * sb));
    return v.sb_count - @min(view_top, v.sb_count);
}

/// The `view_offset` after paging one screenful. `up` scrolls toward
/// older lines (a larger offset).
pub fn pageOffset(v: View, up: bool) u32 {
    const page: u32 = @max(1, v.rows);
    const off = @min(v.view_off, v.sb_count);
    if (up) return @min(v.sb_count, off + page);
    return if (off > page) off - page else 0;
}

const testing = std.testing;

test "layout: no scrollback puts a full-height thumb at the top" {
    const v: View = .{ .canvas_w = 800, .canvas_h = 600, .width = 4, .sb_count = 0, .rows = 24, .view_off = 0 };
    const l = layout(v).?;
    try testing.expectEqual(@as(f32, 796), l.x);
    try testing.expectEqual(@as(f32, 600), l.thumb_h);
    try testing.expectEqual(@as(f32, 0), l.thumb_y);
}

test "layout: at the live bottom the thumb sits at the bottom" {
    const v: View = .{ .canvas_w = 800, .canvas_h = 600, .width = 4, .sb_count = 76, .rows = 24, .view_off = 0 };
    const l = layout(v).?;
    try testing.expectApproxEqAbs(@as(f32, 144), l.thumb_h, 0.01); // 24/100 * 600
    try testing.expectApproxEqAbs(@as(f32, 456), l.thumb_y, 0.01); // bottom-aligned
}

test "layout: scrolled fully back puts the thumb at the top" {
    const v: View = .{ .canvas_w = 800, .canvas_h = 600, .width = 4, .sb_count = 76, .rows = 24, .view_off = 76 };
    const l = layout(v).?;
    try testing.expectApproxEqAbs(@as(f32, 0), l.thumb_y, 0.01);
}

test "layout: min thumb height still leaves exact end-to-end travel" {
    const v: View = .{ .canvas_w = 800, .canvas_h = 100, .width = 4, .sb_count = 100000, .rows = 24, .view_off = 0 };
    const l = layout(v).?;
    try testing.expectEqual(MIN_THUMB, l.thumb_h);
    try testing.expectApproxEqAbs(l.h - l.thumb_h, l.thumb_y, 0.01);
}

test "hitTest: outside the track is none, inside splits into three zones" {
    const v: View = .{ .canvas_w = 800, .canvas_h = 600, .width = 4, .sb_count = 76, .rows = 24, .view_off = 0 };
    const l = layout(v).?;
    try testing.expectEqual(Hit.none, hitTest(l, 400, 300));
    try testing.expectEqual(Hit.none, hitTest(l, 795.9, 300));
    try testing.expectEqual(Hit.page_up, hitTest(l, 797, 10));
    try testing.expectEqual(Hit.thumb, hitTest(l, 797, 500));
    try testing.expectEqual(Hit.none, hitTest(l, 797, 600));
}

test "offsetForThumbTop inverts layout at both ends and in the middle" {
    const v: View = .{ .canvas_w = 800, .canvas_h = 600, .width = 4, .sb_count = 76, .rows = 24, .view_off = 0 };
    const l = layout(v).?;
    try testing.expectEqual(@as(u32, 76), offsetForThumbTop(v, l, 0));
    try testing.expectEqual(@as(u32, 0), offsetForThumbTop(v, l, l.h - l.thumb_h));
    try testing.expectEqual(@as(u32, 0), offsetForThumbTop(v, l, 99999));
    try testing.expectEqual(@as(u32, 38), offsetForThumbTop(v, l, (l.h - l.thumb_h) / 2));
}

test "offsetForThumbTop round-trips the thumb position it was read from" {
    var v: View = .{ .canvas_w = 800, .canvas_h = 600, .width = 4, .sb_count = 5000, .rows = 40, .view_off = 1234 };
    const l = layout(v).?;
    const back = offsetForThumbTop(v, l, l.thumb_y);
    v.view_off = back;
    const l2 = layout(v).?;
    try testing.expectApproxEqAbs(l.thumb_y, l2.thumb_y, 1.0);
}

test "pageOffset clamps at both ends" {
    const v: View = .{ .canvas_w = 800, .canvas_h = 600, .width = 4, .sb_count = 50, .rows = 24, .view_off = 0 };
    try testing.expectEqual(@as(u32, 24), pageOffset(v, true));
    try testing.expectEqual(@as(u32, 0), pageOffset(v, false));
    var far = v;
    far.view_off = 40;
    try testing.expectEqual(@as(u32, 50), pageOffset(far, true));
    try testing.expectEqual(@as(u32, 16), pageOffset(far, false));
}

test "visible honours the mode and a zero width" {
    try testing.expect(!visible(.never, 4, 100));
    try testing.expect(!visible(.auto, 4, 0));
    try testing.expect(visible(.auto, 4, 1));
    try testing.expect(visible(.always, 4, 0));
    try testing.expect(!visible(.always, 0, 100));
}
