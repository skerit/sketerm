//! Details-column width policy (GTK-free): which widths the non-Name
//! columns of a listing actually get, so Name always keeps a usable
//! share of the viewport.
//!
//! A stored width is a preference. GtkColumnView grows a column for as
//! long as a grip drag rests near the view's edge (its autoscroll widens
//! the column every frame, pointer still), so a stored width can be far
//! wider than anyone meant; honouring it verbatim scrolled Name out of
//! sight behind one huge column.

const std = @import("std");

/// Below this the Name column is nothing but an icon stub.
pub const MIN_NAME_WIDTH: i32 = 80;

/// Narrowest a column may be dragged: below this the header title is
/// nothing but an ellipsis.
pub const MIN_COLUMN_WIDTH: i32 = 40;

/// Widest any non-Name column may be stored, whatever the viewport.
pub const MAX_COLUMN_WIDTH: i32 = 1000;

/// Share of the viewport other columns' dragged EXCESS can never take
/// from Name: 1/NAME_SHARE_DIV of it (MIN_NAME_WIDTH in narrow panes).
/// MIN_NAME_WIDTH alone still left Name at "a ..." beside one column
/// widened by the autoscroll.
pub const NAME_SHARE_DIV: i32 = 4;

/// Room a `viewport`-px listing keeps for Name against widened columns.
pub fn nameReserve(viewport: i32) i32 {
    return @max(MIN_NAME_WIDTH, @divFloor(viewport, NAME_SHARE_DIV));
}

/// One non-Name column's wish.
pub const Want = struct {
    /// Stored (dragged) width, or the default when never dragged.
    pref: i32,
    /// The column type's default width.
    default: i32,
};

/// A stored non-Name width made safe to keep; 0 stays "never dragged".
pub fn clampStored(width: i32) i32 {
    if (width <= 0) return 0;
    return std.math.clamp(width, MIN_COLUMN_WIDTH, MAX_COLUMN_WIDTH);
}

/// The widths to apply to the non-Name columns of a `viewport`-px
/// listing, into `out` (parallel to `wants`).
///
/// Columns wider than their default give back that excess,
/// proportionally, until Name has nameReserve(); a column never drops
/// below min(pref, default), so when even those floors do not fit the
/// listing overflows exactly as it would with every column at its
/// default. `viewport` <= 0 (not allocated yet) applies the preferences.
pub fn fit(viewport: i32, wants: []const Want, out: []i32) void {
    std.debug.assert(out.len >= wants.len);
    var floors: i64 = 0;
    var excess: i64 = 0;
    for (wants, 0..) |w, i| {
        const pref = std.math.clamp(w.pref, MIN_COLUMN_WIDTH, MAX_COLUMN_WIDTH);
        const floor = @min(pref, w.default);
        out[i] = pref;
        floors += floor;
        excess += pref - floor;
    }
    if (viewport <= 0 or excess == 0) return;
    const budget: i64 = @as(i64, viewport) - nameReserve(viewport) - floors;
    if (budget >= excess) return;
    const give: i64 = @max(budget, 0);
    for (wants, 0..) |w, i| {
        const floor = @min(out[i], w.default);
        const extra: i64 = out[i] - floor;
        out[i] = floor + @as(i32, @intCast(@divFloor(extra * give, excess)));
    }
}

/// The widest a dragged non-Name column may become in a `viewport`-px
/// listing whose other non-Name columns want `others` px in total:
/// what leaves Name nameReserve(), but never less than the column's
/// `default` (a narrow pane already overflows at the defaults).
pub fn dragCap(viewport: i32, others: i32, default: i32) i32 {
    if (viewport <= 0) return MAX_COLUMN_WIDTH;
    const room = viewport - nameReserve(viewport) - others;
    return std.math.clamp(@max(room, default), MIN_COLUMN_WIDTH, MAX_COLUMN_WIDTH);
}

const t = std.testing;

test "clampStored keeps never-dragged and bounds the rest" {
    try t.expectEqual(@as(i32, 0), clampStored(0));
    try t.expectEqual(@as(i32, 0), clampStored(-5));
    try t.expectEqual(MIN_COLUMN_WIDTH, clampStored(3));
    try t.expectEqual(@as(i32, 121), clampStored(121));
    try t.expectEqual(MAX_COLUMN_WIDTH, clampStored(5000));
}

test "fit applies preferences when they leave Name its minimum" {
    const wants = [_]Want{ .{ .pref = 104, .default = 104 }, .{ .pref = 300, .default = 100 }, .{ .pref = 160, .default = 160 } };
    var out: [3]i32 = undefined;
    fit(1200, &wants, &out);
    try t.expectEqualSlices(i32, &.{ 104, 300, 160 }, &out);
}

test "nameReserve is a quarter of the viewport, never under the minimum" {
    try t.expectEqual(MIN_NAME_WIDTH, nameReserve(0));
    try t.expectEqual(MIN_NAME_WIDTH, nameReserve(300));
    try t.expectEqual(@as(i32, 300), nameReserve(1200));
}

test "fit trims an oversized column so Name keeps its reserve" {
    // Size dragged to 900 in a 1000-px pane: Name would get nothing.
    const wants = [_]Want{ .{ .pref = 104, .default = 104 }, .{ .pref = 900, .default = 100 }, .{ .pref = 160, .default = 160 } };
    var out: [3]i32 = undefined;
    fit(1000, &wants, &out);
    try t.expectEqualSlices(i32, &.{ 104, 486, 160 }, &out);
    var sum: i32 = 0;
    for (out) |w| sum += w;
    try t.expectEqual(1000 - nameReserve(1000), sum);
}

test "fit shares the trim proportionally and never goes below the floors" {
    const wants = [_]Want{ .{ .pref = 300, .default = 100 }, .{ .pref = 500, .default = 100 }, .{ .pref = 60, .default = 160 } };
    var out: [3]i32 = undefined;
    // floors 100 + 100 + 60 = 260, excess 600; budget 600 - 150 - 260 = 190.
    fit(600, &wants, &out);
    try t.expectEqualSlices(i32, &.{ 163, 226, 60 }, &out);
    // Narrower than the floors: every column at its floor, nothing negative.
    fit(200, &wants, &out);
    try t.expectEqualSlices(i32, &.{ 100, 100, 60 }, &out);
}

test "fit before allocation and with absurd preferences" {
    const wants = [_]Want{ .{ .pref = 1_000_000, .default = 100 }, .{ .pref = -3, .default = 160 } };
    var out: [2]i32 = undefined;
    fit(0, &wants, &out);
    try t.expectEqualSlices(i32, &.{ MAX_COLUMN_WIDTH, MIN_COLUMN_WIDTH }, &out);
    fit(800, &wants, &out);
    try t.expectEqualSlices(i32, &.{ 800 - nameReserve(800) - MIN_COLUMN_WIDTH, MIN_COLUMN_WIDTH }, &out);
}

test "dragCap leaves Name its reserve but never undercuts the default" {
    try t.expectEqual(1000 - nameReserve(1000) - 264, dragCap(1000, 264, 100));
    try t.expectEqual(@as(i32, 100), dragCap(300, 264, 100));
    try t.expectEqual(MAX_COLUMN_WIDTH, dragCap(0, 264, 100));
    try t.expectEqual(MAX_COLUMN_WIDTH, dragCap(9000, 0, 100));
}
