//! Cursor-trail animation state machine — a critically-damped spring
//! per corner of the cursor rectangle, so the leading edge snaps to
//! the new cell while the trailing edge lags and the quad spanned by
//! the four corners stretches along the path of travel.
//!
//! Pure math: no GL, no GTK, no allocator. The renderer asks for
//! `quad()` and the pane asks `advance()` whether to schedule another
//! frame. Ported from Rio's `trail_cursor.rs`, which is itself a port
//! of neovide's cursor VFX.
//!
//! Termination is the load-bearing property: the pane runs a 60 Hz
//! GLib timeout while `animating` is set, so a spring that only ever
//! approached its target would pin the frame clock forever. Two
//! independent guarantees prevent that — the spring snaps to rest
//! below a 0.01 px offset (its analytic solution decays as e^-wt, so
//! that bound is crossed in finitely many steps), and `advance`
//! force-snaps once the configured `duration` has elapsed, whatever
//! the springs report.
//!
//! The deadline is not merely a safety net. A critically damped
//! spring reaches 2% of its *initial* amplitude at its time
//! constant, so the absolute settle time grows with jump distance;
//! without the deadline a 40-row jump would twitch for half a second
//! past its nominal length. Cutting at `duration` leaves a residual
//! offset of roughly `a0 * 13 * e^-12` px — under a fifth of a pixel
//! for any jump a terminal can produce — so the cut is invisible and
//! `duration` genuinely is "the trail is gone within this long".

const std = @import("std");

/// `duration` divided by this is the spring time constant. 3 gives
/// the tail room to decay to sub-pixel before the deadline cuts it.
const WATCHDOG_FACTOR: f32 = 3.0;

/// Per-frame delta clamp. The lower bound guarantees forward progress
/// even if two timer callbacks land on the same clock reading; the
/// upper bound stops a stalled main loop (tab switch, modal drag)
/// from teleporting the trail through a huge integration step.
const DT_MIN: f32 = 0.001;
const DT_MAX: f32 = 0.1;

/// Short horizontal hops (typing) use this instead of the configured
/// length — a full 150 ms smear per keystroke reads as lag, not
/// polish. Matches Rio's SHORT_ANIMATION_LENGTH.
const SHORT_LEN: f32 = 0.04;

/// Cell-distance thresholds for "this was just typing".
const SHORT_MAX_COLS: f32 = 2.001;
const SHORT_MAX_ROWS: f32 = 0.001;

/// Critically damped (zeta = 1) harmonic oscillator, integrated
/// analytically so a variable `dt` is exact rather than accumulating
/// Euler error.
///
/// `position` is the *remaining offset* from the destination in
/// pixels, not an absolute coordinate: rest is 0.
pub const Spring = struct {
    position: f32 = 0,
    velocity: f32 = 0,

    pub fn reset(self: *Spring) void {
        self.position = 0;
        self.velocity = 0;
    }

    /// @return true while still moving.
    pub fn update(self: *Spring, dt: f32, animation_length: f32) bool {
        // A frame longer than the whole animation: nothing to show.
        if (animation_length <= dt) {
            self.reset();
            return false;
        }
        if (self.position == 0) return false;

        // omega picked so the offset falls inside ~2% of its initial
        // magnitude after `animation_length` seconds.
        const omega = 4.0 / animation_length;
        const a = self.position;
        const b = a * omega + self.velocity;
        const decay = @exp(-omega * dt);

        self.position = (a + b * dt) * decay;
        self.velocity = decay * (-a * omega - b * dt * omega + b);

        if (@abs(self.position) < 0.01) {
            self.reset();
            return false;
        }
        return true;
    }
};

/// One corner of the cursor rectangle. `rel_x`/`rel_y` are its offset
/// from the cell centre in cell units, so the corner's destination
/// tracks the cursor across font-size changes for free.
const Corner = struct {
    spring_x: Spring = .{},
    spring_y: Spring = .{},
    /// Current animated position, physical pixels.
    x: f32 = 0,
    y: f32 = 0,
    rel_x: f32,
    rel_y: f32,
    prev_dest_x: f32 = -1e6,
    prev_dest_y: f32 = -1e6,
    anim_length: f32 = 0,

    fn destination(self: Corner, cx: f32, cy: f32, cw: f32, ch: f32) [2]f32 {
        return .{ cx + self.rel_x * cw, cy + self.rel_y * ch };
    }

    fn update(self: *Corner, cx: f32, cy: f32, cw: f32, ch: f32, dt: f32, immediate: bool) bool {
        const dest = self.destination(cx, cy, cw, ch);

        // Destination moved: fold the distance still to travel into
        // the spring's offset so an interrupted animation retargets
        // from where it currently is instead of jumping.
        if (@abs(dest[0] - self.prev_dest_x) > 0.01 or @abs(dest[1] - self.prev_dest_y) > 0.01) {
            self.spring_x.position = dest[0] - self.x;
            self.spring_y.position = dest[1] - self.y;
            self.prev_dest_x = dest[0];
            self.prev_dest_y = dest[1];
        }

        if (immediate) {
            self.x = dest[0];
            self.y = dest[1];
            self.spring_x.reset();
            self.spring_y.reset();
            return false;
        }

        var moving = self.spring_x.update(dt, self.anim_length);
        if (self.spring_y.update(dt, self.anim_length)) moving = true;
        self.x = dest[0] - self.spring_x.position;
        self.y = dest[1] - self.spring_y.position;
        return moving;
    }

    /// Dot product of this corner's direction from the cell centre
    /// with the direction of travel. Higher = leading the movement.
    fn directionAlignment(self: Corner, cx: f32, cy: f32, cw: f32, ch: f32) f32 {
        const dest = self.destination(cx, cy, cw, ch);
        const rel_len = @max(1e-6, @sqrt(self.rel_x * self.rel_x + self.rel_y * self.rel_y));
        const dx = dest[0] - self.x;
        const dy = dest[1] - self.y;
        const travel = @max(1e-6, @sqrt(dx * dx + dy * dy));
        return (dx / travel) * (self.rel_x / rel_len) + (dy / travel) * (self.rel_y / rel_len);
    }
};

pub const Trail = struct {
    /// Top-left, top-right, bottom-right, bottom-left.
    corners: [4]Corner = .{
        .{ .rel_x = -0.5, .rel_y = -0.5 },
        .{ .rel_x = 0.5, .rel_y = -0.5 },
        .{ .rel_x = 0.5, .rel_y = 0.5 },
        .{ .rel_x = -0.5, .rel_y = 0.5 },
    },
    /// Destination cursor-cell centre, physical pixels.
    dest_cx: f32 = 0,
    dest_cy: f32 = 0,
    prev_dest_cx: f32 = -1e6,
    prev_dest_cy: f32 = -1e6,
    /// Centre before the pending jump, kept so `startJump` can
    /// measure the travel distance in cells.
    jump_from_cx: f32 = -1e6,
    jump_from_cy: f32 = -1e6,
    /// Set by `setDestination`, consumed by `advance`.
    jumped: bool = false,
    /// Next `advance` teleports instead of animating. Set at init and
    /// by `snap()`.
    immediate: bool = true,
    animating: bool = false,
    /// Seconds since the current jump began; drives the deadline.
    elapsed: f32 = 0,
    /// Hard cap on how long one jump may take, in seconds. This is
    /// the user-facing `cursor_trail_ms`.
    duration: f32 = 0.3,

    pub fn init(duration_s: f32) Trail {
        var t = Trail{};
        t.setDuration(duration_s);
        return t;
    }

    pub fn setDuration(self: *Trail, duration_s: f32) void {
        self.duration = std.math.clamp(duration_s, 0.03, 2.0);
    }

    /// Spring time constant derived from the visible duration.
    fn animLen(self: Trail) f32 {
        return self.duration / WATCHDOG_FACTOR;
    }

    /// Abandon any in-flight animation and teleport to the current
    /// destination on the next `advance`. Called on alternate-screen
    /// switches, full-screen erases, resizes, focus gain and whenever
    /// the cursor reappears — a trail dragged across a viewport that
    /// just changed underneath it is smear, not motion.
    pub fn snap(self: *Trail) void {
        self.immediate = true;
        self.jumped = false;
        self.animating = false;
        self.elapsed = 0;
        for (&self.corners) |*corner| {
            corner.spring_x.reset();
            corner.spring_y.reset();
        }
    }

    /// Point the trail at the cursor's top-left pixel. Call once per
    /// frame before `advance`.
    pub fn setDestination(self: *Trail, x: f32, y: f32, cw: f32, ch: f32) void {
        const cx = x + cw * 0.5;
        const cy = y + ch * 0.5;
        self.dest_cx = cx;
        self.dest_cy = cy;
        if (@abs(cx - self.prev_dest_cx) > 0.01 or @abs(cy - self.prev_dest_cy) > 0.01) {
            self.jump_from_cx = self.prev_dest_cx;
            self.jump_from_cy = self.prev_dest_cy;
            self.prev_dest_cx = cx;
            self.prev_dest_cy = cy;
            self.jumped = true;
        }
    }

    /// Integrate one frame. @return true while the trail still needs
    /// redrawing; false means fully settled and the caller may drop
    /// its timer.
    pub fn advance(self: *Trail, dt_s: f32, cw: f32, ch: f32) bool {
        const dt = std.math.clamp(dt_s, DT_MIN, DT_MAX);
        const immediate = self.immediate;
        self.immediate = false;

        if (self.jumped and !immediate) {
            self.startJump(cw, ch);
            self.elapsed = 0;
        }
        self.jumped = false;

        // Deadline: unconditional stop, independent of the springs.
        if (!immediate) {
            self.elapsed += dt;
            if (self.elapsed > self.duration) {
                self.snap();
                self.settleCorners(cw, ch);
                return false;
            }
        }

        var moving = false;
        for (&self.corners) |*corner| {
            if (corner.update(self.dest_cx, self.dest_cy, cw, ch, dt, immediate)) moving = true;
        }
        self.animating = moving;
        return moving;
    }

    /// Park every corner exactly on its destination (used by the
    /// deadline so a forced stop leaves no stale geometry behind).
    fn settleCorners(self: *Trail, cw: f32, ch: f32) void {
        for (&self.corners) |*corner| {
            const dest = corner.destination(self.dest_cx, self.dest_cy, cw, ch);
            corner.x = dest[0];
            corner.y = dest[1];
            corner.prev_dest_x = dest[0];
            corner.prev_dest_y = dest[1];
        }
    }

    /// Rank the corners by how well they lead the movement and hand
    /// the leaders a shorter animation than the stragglers — that
    /// spread is what stretches the quad into a trail.
    fn startJump(self: *Trail, cw: f32, ch: f32) void {
        const jump_cols = if (cw > 0) @abs(self.dest_cx - self.jump_from_cx) / cw else 0;
        const jump_rows = if (ch > 0) @abs(self.dest_cy - self.jump_from_cy) / ch else 0;

        const anim_len = self.animLen();

        // Typing: uniform, brief, no stretch worth computing.
        if (jump_cols <= SHORT_MAX_COLS and jump_rows < SHORT_MAX_ROWS) {
            const len = @min(anim_len, SHORT_LEN);
            for (&self.corners) |*corner| corner.anim_length = len;
            return;
        }

        var order: [4]usize = .{ 0, 1, 2, 3 };
        var align_by: [4]f32 = undefined;
        for (self.corners, 0..) |corner, i| {
            align_by[i] = corner.directionAlignment(self.dest_cx, self.dest_cy, cw, ch);
        }
        // Insertion sort ascending; index breaks ties so the ranking
        // is deterministic (four elements, not worth anything fancier).
        var i: usize = 1;
        while (i < order.len) : (i += 1) {
            var j = i;
            while (j > 0) : (j -= 1) {
                const a = order[j - 1];
                const b = order[j];
                if (align_by[a] < align_by[b] or (align_by[a] == align_by[b] and a < b)) break;
                order[j - 1] = b;
                order[j] = a;
            }
        }

        // Lowest alignment = most trailing = longest lag. The leading
        // pair gets 0, i.e. it snaps to the new cell immediately.
        var rank: [4]usize = undefined;
        for (order, 0..) |corner_idx, r| rank[corner_idx] = r;
        const trailing = anim_len;
        const mid = trailing * 0.5;
        for (&self.corners, 0..) |*corner, idx| {
            corner.anim_length = switch (rank[idx]) {
                0 => trailing,
                1 => mid,
                else => 0,
            };
        }
    }

    /// The four animated corner positions in physical pixels, in
    /// TL, TR, BR, BL winding.
    pub fn quad(self: Trail) [4][2]f32 {
        return .{
            .{ self.corners[0].x, self.corners[0].y },
            .{ self.corners[1].x, self.corners[1].y },
            .{ self.corners[2].x, self.corners[2].y },
            .{ self.corners[3].x, self.corners[3].y },
        };
    }

    /// Axis-aligned bounding box of `quad()` — cheap way for a test
    /// or a damage tracker to ask "how far does this reach".
    pub fn bounds(self: Trail) [4]f32 {
        const q = self.quad();
        var min_x = q[0][0];
        var min_y = q[0][1];
        var max_x = q[0][0];
        var max_y = q[0][1];
        for (q[1..]) |p| {
            min_x = @min(min_x, p[0]);
            min_y = @min(min_y, p[1]);
            max_x = @max(max_x, p[0]);
            max_y = @max(max_y, p[1]);
        }
        return .{ min_x, min_y, max_x, max_y };
    }
};

// ── Tests ────────────────────────────────────────────────────

const testing = std.testing;

const CW: f32 = 10;
const CH: f32 = 20;

/// Drive the trail like the pane's timer does. @return frames spent
/// before it reported "settled".
fn runToSettle(t: *Trail, dt: f32, max_frames: usize) !usize {
    var frames: usize = 0;
    while (frames < max_frames) : (frames += 1) {
        if (!t.advance(dt, CW, CH)) return frames;
    }
    return error.NeverSettled;
}

test "spring reaches rest and reports it" {
    var s = Spring{ .position = 100 };
    var steps: usize = 0;
    while (s.update(1.0 / 60.0, 0.15)) : (steps += 1) {
        try testing.expect(steps < 1000);
    }
    try testing.expectEqual(@as(f32, 0), s.position);
    try testing.expectEqual(@as(f32, 0), s.velocity);
    try testing.expect(steps > 0);
}

test "spring with a frame longer than the animation snaps immediately" {
    var s = Spring{ .position = 100 };
    try testing.expect(!s.update(0.2, 0.15));
    try testing.expectEqual(@as(f32, 0), s.position);
}

test "first destination teleports without animating" {
    var t = Trail.init(0.15);
    t.setDestination(0, 0, CW, CH);
    try testing.expect(!t.advance(1.0 / 60.0, CW, CH));
    try testing.expect(!t.animating);
    const q = t.quad();
    try testing.expectApproxEqAbs(@as(f32, 0), q[0][0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), q[0][1], 0.001);
    try testing.expectApproxEqAbs(CW, q[2][0], 0.001);
    try testing.expectApproxEqAbs(CH, q[2][1], 0.001);
}

test "a jump animates and then settles exactly on the target" {
    var t = Trail.init(0.15);
    t.setDestination(0, 0, CW, CH);
    _ = t.advance(1.0 / 60.0, CW, CH);

    // Ten rows down, twenty columns right.
    t.setDestination(20 * CW, 10 * CH, CW, CH);
    try testing.expect(t.advance(1.0 / 60.0, CW, CH));
    try testing.expect(t.animating);

    // Mid-animation the quad must still reach back toward the origin:
    // that overlap with the travelled path IS the trail.
    const mid = t.bounds();
    try testing.expect(mid[0] < 20 * CW);
    try testing.expect(mid[1] < 10 * CH);

    const frames = try runToSettle(&t, 1.0 / 60.0, 600);
    try testing.expect(frames > 0);
    try testing.expect(!t.animating);

    // Settled means the quad IS the cursor cell, to the pixel.
    const b = t.bounds();
    try testing.expectApproxEqAbs(20 * CW, b[0], 0.02);
    try testing.expectApproxEqAbs(10 * CH, b[1], 0.02);
    try testing.expectApproxEqAbs(21 * CW, b[2], 0.02);
    try testing.expectApproxEqAbs(11 * CH, b[3], 0.02);
}

test "settling never outlives the configured duration" {
    // Long jumps are the case that needs the deadline: the springs
    // alone would keep twitching well past `duration`.
    for ([_]f32{ 0.1, 0.3, 1.0 }) |duration| {
        var t = Trail.init(duration);
        t.setDestination(0, 0, CW, CH);
        _ = t.advance(1.0 / 60.0, CW, CH);
        t.setDestination(0, 30 * CH, CW, CH);

        const dt: f32 = 1.0 / 60.0;
        const frames = try runToSettle(&t, dt, 2000);
        // +2 frames of slack: the jump is detected on the first
        // advance, and the settle is reported on the one after the
        // last move.
        const budget: usize = @intFromFloat(@ceil(duration / dt) + 2);
        try testing.expect(frames <= budget);
    }
}

test "the residual left by the deadline is invisibly small" {
    var t = Trail.init(0.3);
    t.setDestination(0, 0, CW, CH);
    _ = t.advance(1.0 / 60.0, CW, CH);
    t.setDestination(0, 60 * CH, CW, CH);

    // Step to one frame before the deadline and measure how far the
    // laggiest corner still is from where it belongs.
    var elapsed: f32 = 0;
    const dt: f32 = 1.0 / 60.0;
    var worst: f32 = 0;
    while (t.advance(dt, CW, CH)) {
        elapsed += dt;
        if (elapsed + dt > t.duration) {
            const b = t.bounds();
            worst = @max(worst, @abs(b[1] - 60 * CH));
            break;
        }
    }
    try testing.expect(worst < 1.0);
}

test "termination holds for every frame rate, distance and duration" {
    const dts = [_]f32{ 0, 0.0001, 1.0 / 240.0, 1.0 / 60.0, 1.0 / 30.0, 0.09, 0.5 };
    const lens = [_]f32{ 0.03, 0.12, 0.3, 2.0 };
    const jumps = [_][2]f32{ .{ 1, 0 }, .{ 0, 1 }, .{ 3, 0 }, .{ 80, 0 }, .{ 0, 200 }, .{ -60, -40 } };
    for (dts) |dt| {
        for (lens) |len| {
            for (jumps) |j| {
                var t = Trail.init(len);
                t.setDestination(0, 0, CW, CH);
                _ = t.advance(dt, CW, CH);
                t.setDestination(j[0] * CW, j[1] * CH, CW, CH);
                // Bounded by the deadline even when dt is clamped up
                // to its 1 ms floor: 2 s / 1 ms = 2000 frames.
                _ = try runToSettle(&t, dt, 2100);
                try testing.expect(!t.animating);
            }
        }
    }
}

test "a zero delta still terminates via the dt floor" {
    var t = Trail.init(0.15);
    t.setDestination(0, 0, CW, CH);
    _ = t.advance(0, CW, CH);
    t.setDestination(0, 40 * CH, CW, CH);
    // dt is clamped up to DT_MIN, so a frozen clock cannot stall the
    // deadline: 0.15 s / 1 ms = 150 frames worst case.
    _ = try runToSettle(&t, 0, 300);
    try testing.expect(!t.animating);
}

test "retargeting mid-flight still settles on the final destination" {
    var t = Trail.init(0.15);
    t.setDestination(0, 0, CW, CH);
    _ = t.advance(1.0 / 60.0, CW, CH);
    t.setDestination(0, 20 * CH, CW, CH);
    _ = t.advance(1.0 / 60.0, CW, CH);
    _ = t.advance(1.0 / 60.0, CW, CH);
    // Change our mind before it lands.
    t.setDestination(30 * CW, 5 * CH, CW, CH);
    _ = try runToSettle(&t, 1.0 / 60.0, 600);
    const b = t.bounds();
    try testing.expectApproxEqAbs(30 * CW, b[0], 0.02);
    try testing.expectApproxEqAbs(5 * CH, b[1], 0.02);
}

test "snap abandons an in-flight animation" {
    var t = Trail.init(0.15);
    t.setDestination(0, 0, CW, CH);
    _ = t.advance(1.0 / 60.0, CW, CH);
    t.setDestination(40 * CW, 20 * CH, CW, CH);
    try testing.expect(t.advance(1.0 / 60.0, CW, CH));

    t.snap();
    try testing.expect(!t.animating);
    try testing.expect(!t.advance(1.0 / 60.0, CW, CH));
    const b = t.bounds();
    try testing.expectApproxEqAbs(40 * CW, b[0], 0.001);
    try testing.expectApproxEqAbs(20 * CH, b[1], 0.001);
}

test "typing sideways uses the short animation" {
    var t = Trail.init(0.15);
    t.setDestination(0, 0, CW, CH);
    _ = t.advance(1.0 / 60.0, CW, CH);
    t.setDestination(CW, 0, CW, CH);
    _ = t.advance(1.0 / 60.0, CW, CH);
    for (t.corners) |corner| try testing.expectEqual(SHORT_LEN, corner.anim_length);

    // A vertical hop is never "short", even by one row.
    t.setDestination(CW, CH, CW, CH);
    _ = t.advance(1.0 / 60.0, CW, CH);
    var any_long = false;
    for (t.corners) |corner| {
        if (corner.anim_length > SHORT_LEN) any_long = true;
    }
    try testing.expect(any_long);
}

test "the leading corners snap while the trailing one lags" {
    var t = Trail.init(0.15);
    t.setDestination(0, 0, CW, CH);
    _ = t.advance(1.0 / 60.0, CW, CH);
    // Straight down: the bottom corners lead, the top ones trail.
    t.setDestination(0, 20 * CH, CW, CH);
    _ = t.advance(1.0 / 60.0, CW, CH);
    const q = t.quad();
    // Bottom-right corner is at (or near) the destination already.
    try testing.expect(q[2][1] > 20 * CH);
    // Top-left is still far behind it.
    try testing.expect(q[0][1] < q[2][1] - CH);
}

test "an unmoved cursor never starts animating" {
    var t = Trail.init(0.15);
    t.setDestination(5 * CW, 3 * CH, CW, CH);
    _ = t.advance(1.0 / 60.0, CW, CH);
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        t.setDestination(5 * CW, 3 * CH, CW, CH);
        try testing.expect(!t.advance(1.0 / 60.0, CW, CH));
    }
}

test "the deadline stops a trail whose springs never report rest" {
    var t = Trail.init(0.15);
    t.setDestination(0, 0, CW, CH);
    _ = t.advance(1.0 / 60.0, CW, CH);
    t.setDestination(0, 50 * CH, CW, CH);
    // Re-arm the springs every frame the way a pathological caller
    // would; only the watchdog can end this.
    var frames: usize = 0;
    while (frames < 2000) : (frames += 1) {
        for (&t.corners) |*corner| {
            if (corner.anim_length > 0) corner.spring_y.position = 500;
        }
        if (!t.advance(1.0 / 60.0, CW, CH)) break;
    }
    try testing.expect(frames < 2000);
    try testing.expect(!t.animating);
}
