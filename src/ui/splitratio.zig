//! Divider bookkeeping for one split, free of GTK so it can be tested.
//!
//! GtkPaned keeps only an integer start-child size. On every resize it
//! rescales that integer (`pos * new / old`, rounded), and it clamps it
//! to the children's minimum sizes, so a window that shrinks below the
//! children's minimums and grows back, or a stream of small resizes,
//! moves the divider for good: the paned has nothing to restore it
//! from. This tracker keeps the split's fraction as the source of truth
//! instead. A notification is classified as a layout change (the
//! content space or the clamp bounds moved: re-derive the position from
//! the fraction) or as a user move (nothing about the layout changed
//! but the position did: adopt it as the new fraction), and a clamped
//! position is never read back into the fraction.

const std = @import("std");

pub const Tracker = struct {
    /// Start child's share of the content space (the paned's size minus
    /// its handle), in (0, 1).
    ratio: f64,
    /// Layout the last decision saw. Zeros/-1 before the first
    /// allocation, so the first observation always counts as a layout
    /// change.
    avail: i32 = 0,
    min: i32 = -1,
    max: i32 = -1,
    /// Position last applied or accepted; a differing position on an
    /// unchanged layout is the user's.
    pos: i32 = -1,

    pub const Observed = struct {
        /// Content space: the paned's size along its orientation minus
        /// the handle (what GtkPaned divides between its children).
        avail: i32,
        /// GtkPaned's `min-position` / `max-position`.
        min: i32,
        max: i32,
        pos: i32,
        /// Positions are kept on multiples of this (see
        /// `window.alignmentForScale`); 1 means any pixel.
        grid: u32 = 1,
    };

    pub fn init(ratio: f64) Tracker {
        return .{ .ratio = sane(ratio) };
    }

    /// Feed one notification. @return the position to set, or null to leave
    /// the paned alone.
    pub fn observe(self: *Tracker, o: Observed) ?i32 {
        if (o.avail <= 0) return null;
        const layout_changed = o.avail != self.avail or o.min != self.min or o.max != self.max;
        self.avail = o.avail;
        self.min = o.min;
        self.max = o.max;
        if (!layout_changed) {
            if (o.pos == self.pos) return null;
            // The user dragged (or keyboard-moved) the handle.
            const snapped = clampPos(snapNearest(o.pos, o.grid), o.min, o.max);
            self.ratio = sane(@as(f64, @floatFromInt(snapped)) / @as(f64, @floatFromInt(o.avail)));
            self.pos = snapped;
            return if (snapped != o.pos) snapped else null;
        }
        return self.apply(o);
    }

    /// Re-derive the position from the fraction regardless of what changed
    /// (the paned was remapped). @return the position to set, or null.
    pub fn reapply(self: *Tracker, o: Observed) ?i32 {
        if (o.avail <= 0) return null;
        self.avail = o.avail;
        self.min = o.min;
        self.max = o.max;
        return self.apply(o);
    }

    fn apply(self: *Tracker, o: Observed) ?i32 {
        const want = target(self.ratio, o);
        self.pos = want;
        return if (want != o.pos) want else null;
    }

    /// The position this fraction asks for in `o`'s layout, clamped the
    /// way GtkPaned would clamp it so setting it cannot start a clamp loop.
    pub fn target(ratio: f64, o: Observed) i32 {
        const raw: i32 = @intFromFloat(@round(ratio * @as(f64, @floatFromInt(o.avail))));
        return clampPos(snapNearest(raw, o.grid), o.min, o.max);
    }
};

/// Fractions that would hide a child (outside the open interval, NaN)
/// become an even split.
pub fn sane(r: f64) f64 {
    return if (r > 0 and r < 1) r else 0.5;
}

/// Nearest multiple of `m`, kept above zero. Rounding to the nearest
/// rather than down matters: a split re-snapped on every resize must
/// not creep towards the start.
pub fn snapNearest(pos: i32, m: u32) i32 {
    if (m <= 1 or pos <= 0) return pos;
    const im: i32 = @intCast(m);
    const snapped = @divFloor(pos + @divFloor(im, 2), im) * im;
    return if (snapped <= 0) im else snapped;
}

/// GtkPaned's own CLAMP: when the bounds cross (both children's minimums
/// exceed the space) the upper bound wins, as it does there.
pub fn clampPos(pos: i32, min: i32, max: i32) i32 {
    if (pos > max) return max;
    if (pos < min) return min;
    return pos;
}

// -- tests -------------------------------------------------------------

const t = std.testing;

/// GtkPaned's own rescale for a set position when the content space
/// changes from `last` to `alloc` with both children resizable
/// (gtk_paned_compute_position, GTK 4.24), clamped to the bounds.
fn gtkRescale(pos: i32, last: i32, alloc: i32, min: i32, max: i32) i32 {
    const p: i32 = @intFromFloat(@as(f64, @floatFromInt(alloc)) * (@as(f64, @floatFromInt(pos)) / @as(f64, @floatFromInt(last))) + 0.5);
    return clampPos(p, min, max);
}

/// One simulated paned: GTK rescales and clamps, then the tracker (when
/// present) gets the notification and may override.
const Sim = struct {
    pos: i32,
    last: i32,
    child_min: i32,
    grid: u32,

    fn resize(self: *Sim, tr: ?*Tracker, alloc: i32) void {
        const min = self.child_min;
        const max = alloc - self.child_min;
        self.pos = gtkRescale(self.pos, self.last, alloc, min, max);
        self.last = alloc;
        if (tr) |k| {
            if (k.observe(.{ .avail = alloc, .min = min, .max = max, .pos = self.pos, .grid = self.grid })) |p|
                self.pos = clampPos(p, min, max);
        }
    }
};

test "an even split stays even through a long run of window resizes" {
    var tr = Tracker.init(0.5);
    var sim: Sim = .{ .pos = 0, .last = 0, .child_min = 0, .grid = 10 };
    // First allocation.
    _ = tr.observe(.{ .avail = 1000, .min = 0, .max = 1000, .pos = 500, .grid = 10 });
    sim.pos = 500;
    sim.last = 1000;
    // An interactive resize: shrink then grow one pixel at a time.
    var a: i32 = 1000;
    while (a > 700) : (a -= 1) sim.resize(&tr, a);
    while (a < 1000) : (a += 1) sim.resize(&tr, a);
    try t.expectEqual(@as(i32, 500), sim.pos);
    try t.expectEqual(@as(f64, 0.5), tr.ratio);
}

/// The pre-tracker handler over a shrink-then-grow resize in `step` px
/// events: GtkPaned rescales, then the handler snapped the result DOWN to
/// the grid whenever it changed and remembered that. @return the start
/// child's size at the smallest and at the restored width.
fn oldRule(step: i32, grid: i32, low: i32) [2]i32 {
    var pos: i32 = 500;
    var last: i32 = 1000;
    var a: i32 = 1000;
    while (a > low) {
        a = @max(low, a - step);
        const p = gtkRescale(pos, last, a, 0, a);
        last = a;
        pos = if (p != pos) @divFloor(p, grid) * grid else p;
    }
    const at_low = pos;
    while (a < 1000) {
        a = @min(1000, a + step);
        const p = gtkRescale(pos, last, a, 0, a);
        last = a;
        pos = if (p != pos) @divFloor(p, grid) * grid else p;
    }
    return .{ at_low, pos };
}

test "the pre-tracker rule drifts; the tracker does not" {
    // At scale 1.3 (grid 10) every rescale that moved the position was
    // snapped down, so the start child ratchets smaller with each event:
    // 7 px events from 1000 to 700 and back leave it at 70 of 1000.
    try t.expect(oldRule(7, 10, 700)[1] <= 100);
    // Even on an integer scale GtkPaned's rounded rescale alone does
    // not come back to where it started (521 of 1000 here).
    try t.expect(oldRule(7, 1, 700)[1] != 500);

    for ([_]i32{ 1, 7 }) |step| {
        var tr = Tracker.init(0.5);
        var sim: Sim = .{ .pos = 500, .last = 1000, .child_min = 0, .grid = 10 };
        _ = tr.observe(.{ .avail = 1000, .min = 0, .max = 1000, .pos = 500, .grid = 10 });
        var a: i32 = 1000;
        while (a > 700) {
            a = @max(700, a - step);
            sim.resize(&tr, a);
        }
        try t.expectEqual(@as(i32, 350), sim.pos);
        while (a < 1000) {
            a = @min(1000, a + step);
            sim.resize(&tr, a);
        }
        try t.expectEqual(@as(i32, 500), sim.pos);
    }
}

test "a clamp by the children's minimums is undone once the space returns" {
    var tr = Tracker.init(0.5);
    var sim: Sim = .{ .pos = 500, .last = 1000, .child_min = 400, .grid = 1 };
    _ = tr.observe(.{ .avail = 1000, .min = 400, .max = 600, .pos = 500 });
    // Too narrow for both minimums: bounds cross, GTK keeps the upper one.
    sim.resize(&tr, 700);
    sim.resize(&tr, 600);
    try t.expectEqual(@as(f64, 0.5), tr.ratio);
    sim.resize(&tr, 1000);
    try t.expectEqual(@as(i32, 500), sim.pos);

    // Without the tracker the divider stays where the clamp left it.
    var bare: Sim = .{ .pos = 500, .last = 1000, .child_min = 400, .grid = 1 };
    bare.resize(null, 700);
    bare.resize(null, 600);
    bare.resize(null, 1000);
    try t.expect(bare.pos != 500);
}

test "a child's minimum growing at a fixed size is a layout change, not a drag" {
    var tr = Tracker.init(0.5);
    _ = tr.observe(.{ .avail = 1000, .min = 0, .max = 1000, .pos = 500 });
    // The end child's minimum grew to 600: GTK clamps to max = 400 and
    // notifies position and max-position together.
    try t.expectEqual(@as(?i32, null), tr.observe(.{ .avail = 1000, .min = 0, .max = 400, .pos = 400 }));
    try t.expectEqual(@as(f64, 0.5), tr.ratio);
    // The minimum shrinks back: the even split returns.
    try t.expectEqual(@as(?i32, 500), tr.observe(.{ .avail = 1000, .min = 0, .max = 1000, .pos = 400 }));
}

test "a drag at a steady size becomes the new fraction and survives resizes" {
    var tr = Tracker.init(0.5);
    _ = tr.observe(.{ .avail = 1000, .min = 0, .max = 1000, .pos = 500 });
    try t.expectEqual(@as(?i32, null), tr.observe(.{ .avail = 1000, .min = 0, .max = 1000, .pos = 300 }));
    try t.expectEqual(@as(f64, 0.3), tr.ratio);
    // Our own set_position echoes back as a notification: no change.
    try t.expectEqual(@as(?i32, null), tr.observe(.{ .avail = 1000, .min = 0, .max = 1000, .pos = 300 }));
    try t.expectEqual(@as(?i32, 600), tr.observe(.{ .avail = 2000, .min = 0, .max = 2000, .pos = 601 }));
}

test "a drag lands on the device-pixel grid" {
    var tr = Tracker.init(0.5);
    _ = tr.observe(.{ .avail = 1000, .min = 0, .max = 1000, .pos = 500, .grid = 10 });
    try t.expectEqual(@as(?i32, 310), tr.observe(.{ .avail = 1000, .min = 0, .max = 1000, .pos = 307, .grid = 10 }));
    try t.expectEqual(@as(?i32, null), tr.observe(.{ .avail = 1000, .min = 0, .max = 1000, .pos = 310, .grid = 10 }));
    try t.expectApproxEqAbs(@as(f64, 0.31), tr.ratio, 1e-9);
}

test "no allocation yet: nothing to decide" {
    var tr = Tracker.init(0.7);
    try t.expectEqual(@as(?i32, null), tr.observe(.{ .avail = 0, .min = 0, .max = 0, .pos = 0 }));
    try t.expectEqual(@as(?i32, 700), tr.observe(.{ .avail = 1000, .min = 0, .max = 1000, .pos = 12 }));
}

test "snapNearest and clampPos" {
    try t.expectEqual(@as(i32, 500), snapNearest(504, 10));
    try t.expectEqual(@as(i32, 510), snapNearest(505, 10));
    try t.expectEqual(@as(i32, 10), snapNearest(3, 10));
    try t.expectEqual(@as(i32, 7), snapNearest(7, 1));
    try t.expectEqual(@as(i32, 400), clampPos(500, 600, 400));
    try t.expectEqual(@as(f64, 0.5), sane(std.math.nan(f64)));
}
