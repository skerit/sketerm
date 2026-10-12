//! Turning a motion pack into one concrete, never-verbatim replay: reach
//! selection with a per-connection exclusion window, the similarity warp
//! onto the wanted start and landing point, Fitts's-law time scaling,
//! seeded jitter, keystroke timing draws and wheel-burst scaling.
//!
//! Pure: std only. The browser helper executes the plans on its own poll
//! loop; nothing here sleeps or knows about events.

const std = @import("std");
const pack_mod = @import("pack.zig");
const Pack = pack_mod.Pack;
const Reach = pack_mod.Reach;
const KeyClass = pack_mod.KeyClass;

pub const Rng = std.Random.DefaultPrng;

/// How an automated action's input is produced: config
/// `web_motion_default`, `sketerm mcp --web-motion-default`, and the
/// per-call `motion` argument all speak this vocabulary.
pub const Mode = enum {
    /// Synthesized input: one move, then press and release at once.
    direct,
    /// Recorded human motion from the selected motion pack.
    replay,

    pub fn parse(s: []const u8) ?Mode {
        return std.meta.stringToEnum(Mode, s);
    }
};

/// Where a motion setting came from (`capabilities` reports it).
pub const Source = enum { built_in, config, profile, flag };

/// What an action reports it got (`motion` on web_act / web_scroll).
pub const Outcome = enum { direct, replayed };

/// Recently used entries of one kind, excluded from the next picks.
pub const Recent = struct {
    pub const CAP = 32;
    buf: [CAP]u32 = undefined,
    len: usize = 0,
    head: usize = 0,

    pub fn contains(self: *const Recent, idx: u32, window: usize) bool {
        const n = @min(self.len, window);
        var k: usize = 0;
        while (k < n) : (k += 1) {
            const at = (self.head + CAP - 1 - k) % CAP;
            if (self.buf[at] == idx) return true;
        }
        return false;
    }

    pub fn push(self: *Recent, idx: u32) void {
        self.buf[self.head] = idx;
        self.head = (self.head + 1) % CAP;
        self.len = @min(self.len + 1, CAP);
    }
};

/// How many recent picks are excluded for a pool of `n` entries: a
/// quarter of the pool, so a small pack still has choices left.
pub fn exclusionWindow(n: usize) usize {
    return @min(n / 4, Recent.CAP);
}

/// MT = a + b * log2(D/W + 1), fitted from the pack's own reaches.
pub const Fitts = struct {
    a: f64,
    b: f64,

    pub fn id(d: f64, w: f64) f64 {
        return std.math.log2(@max(d, 0) / @max(w, 1) + 1);
    }

    pub fn mt(self: Fitts, d: f64, w: f64) f64 {
        return self.a + self.b * id(d, w);
    }

    /// Least squares over (ID, time-to-press); a degenerate pack gets
    /// b = 0, which makes every ratio 1.
    pub fn fit(reaches: []const Reach) Fitts {
        if (reaches.len == 0) return .{ .a = 0, .b = 0 };
        var sx: f64 = 0;
        var sy: f64 = 0;
        for (reaches) |r| {
            sx += id(r.distance(), r.width());
            sy += moveTime(r);
        }
        const n: f64 = @floatFromInt(reaches.len);
        const mx = sx / n;
        const my = sy / n;
        var cov: f64 = 0;
        var varx: f64 = 0;
        for (reaches) |r| {
            const dx = id(r.distance(), r.width()) - mx;
            cov += dx * (moveTime(r) - my);
            varx += dx * dx;
        }
        if (varx < 1e-9 or cov <= 0) return .{ .a = my, .b = 0 };
        const b = cov / varx;
        return .{ .a = my - b * mx, .b = b };
    }

    /// Time stretch from a recorded reach to a wanted (D, W), clamped
    /// so a badly fitted pack cannot produce absurd motion.
    pub fn ratio(self: Fitts, rec_d: f64, rec_w: f64, d: f64, w: f64) f64 {
        const rec = self.mt(rec_d, rec_w);
        const want = self.mt(d, w);
        if (rec < 1 or want < 1) return 1;
        return std.math.clamp(want / rec, 0.5, 2.0);
    }
};

/// Movement time of a reach: first path sample to the press.
fn moveTime(r: Reach) f64 {
    const p = r.path();
    return r.down - p[0].t;
}

fn angleDiff(a: f64, b: f64) f64 {
    var d = @abs(a - b);
    while (d > std.math.pi) d = @abs(d - 2 * std.math.pi);
    return d;
}

/// The reach nearest a wanted (distance, direction, width), avoiding the
/// last `exclusionWindow` picks; one of the best three, chosen by `rng`.
pub fn select(pack: Pack, d: f64, theta: f64, w: f64, recent: *const Recent, rng: std.Random) ?u32 {
    if (pack.reaches.len == 0) return null;
    const window = exclusionWindow(pack.reaches.len);
    const K = 3;
    var best: [K]struct { idx: u32, score: f64 } = undefined;
    var n: usize = 0;
    for (0..2) |pass| {
        for (pack.reaches, 0..) |r, i| {
            const idx: u32 = @intCast(i);
            if (pass == 0 and recent.contains(idx, window)) continue;
            const score = @abs(@log(@max(d, 1) / @max(r.distance(), 1))) +
                0.6 * angleDiff(theta, r.direction()) / std.math.pi +
                0.5 * @abs(@log(@max(w, 1) / @max(r.width(), 1)));
            // Insertion into the small sorted best-list.
            var at: usize = n;
            while (at > 0 and best[at - 1].score > score) : (at -= 1) {}
            if (at >= K) continue;
            var j: usize = @min(n, K - 1);
            while (j > at) : (j -= 1) best[j] = best[j - 1];
            best[at] = .{ .idx = idx, .score = score };
            n = @min(n + 1, K);
        }
        if (n > 0) break;
    }
    if (n == 0) return null;
    return best[rng.uintLessThan(usize, n)].idx;
}

pub const Move = struct { t: f64, x: f64, y: f64 };

/// One replayed reach: moves in ms from the plan's start, then (for a
/// click) the press and release times. The last move is the landing.
pub const PointerPlan = struct {
    moves: []Move,
    press: f64,
    release: f64,
    reach: ?u32,

    pub fn deinit(self: PointerPlan, gpa: std.mem.Allocator) void {
        gpa.free(self.moves);
    }

    pub fn duration(self: PointerPlan, click: bool) f64 {
        if (click) return self.release;
        return if (self.moves.len > 0) self.moves[self.moves.len - 1].t else 0;
    }
};

/// Where in `box` (x, y, w, h) the press lands: the reach's own
/// normalised landing, jittered, kept off the box's edge.
pub fn landing(r: Reach, box: [4]f64, rng: std.Random) [2]f64 {
    var out: [2]f64 = undefined;
    inline for (0..2) |k| {
        const size = box[2 + k];
        const u = std.math.clamp(r.land[k] + (rng.float(f64) - 0.5) * 0.15, 0.2, 0.8);
        out[k] = if (size < 4) box[k] + size / 2 else box[k] + u * size;
    }
    return out;
}

/// Plan a reach from `from` to a landing inside `box`. A pointer
/// already within a few pixels of the landing gets no path, only the
/// dwell and press of the selected reach.
pub fn planReach(gpa: std.mem.Allocator, pack: Pack, fitts: Fitts, from: [2]f64, box: [4]f64, recent: *Recent, rng: std.Random) !PointerPlan {
    const centre = [2]f64{ box[0] + box[2] / 2, box[1] + box[3] / 2 };
    const want_d = std.math.hypot(centre[0] - from[0], centre[1] - from[1]);
    const theta = std.math.atan2(centre[1] - from[1], centre[0] - from[0]);
    const w = @min(box[2], box[3]);
    const idx = select(pack, want_d, theta, w, recent, rng) orelse return error.NoReaches;
    recent.push(idx);
    const r = pack.reaches[idx];
    const land = landing(r, box, rng);
    const path = r.path();
    const d = std.math.hypot(land[0] - from[0], land[1] - from[1]);
    const dwell = (r.down - path[path.len - 1].t) * (0.9 + 0.2 * rng.float(f64));
    const hold = (r.up - r.down) * (0.9 + 0.2 * rng.float(f64));
    if (d < pack_mod.MIN_REACH_PX) {
        const moves = try gpa.alloc(Move, 1);
        moves[0] = .{ .t = 0, .x = land[0], .y = land[1] };
        const press = @max(dwell, 8);
        return .{ .moves = moves, .press = press, .release = press + @max(hold, 20), .reach = idx };
    }
    const moves = try warp(gpa, r, from, land, fitts.ratio(r.distance(), r.width(), d, w), rng);
    const press = moves[moves.len - 1].t + @max(dwell, 4);
    return .{ .moves = moves, .press = press, .release = press + @max(hold, 20), .reach = idx };
}

/// Reach `r`'s path rotated and scaled so its start is `from` and its
/// end exactly `land`, its intervals stretched by `ratio` and jittered,
/// with sub-pixel position jitter that tapers to zero at both ends.
pub fn warp(gpa: std.mem.Allocator, r: Reach, from: [2]f64, land: [2]f64, ratio: f64, rng: std.Random) ![]Move {
    const path = r.path();
    const v = [2]f64{ land[0] - from[0], land[1] - from[1] };
    const e = r.end();
    const e2 = e[0] * e[0] + e[1] * e[1];
    // Complex multiplier m = v / e: rotates and scales the recorded
    // vector onto the wanted one.
    const mr = (v[0] * e[0] + v[1] * e[1]) / e2;
    const mi = (v[1] * e[0] - v[0] * e[1]) / e2;
    const moves = try gpa.alloc(Move, path.len);
    const last = path.len - 1;
    var t: f64 = 0;
    for (path, 0..) |s, i| {
        const px = s.x - path[0].x;
        const py = s.y - path[0].y;
        var x = from[0] + mr * px - mi * py;
        var y = from[1] + mi * px + mr * py;
        if (i > 0) {
            const step = (s.t - path[i - 1].t) * ratio * (0.94 + 0.12 * rng.float(f64));
            t += @max(step, 0.25);
        }
        if (i > 0 and i < last) {
            const taper = @sin(std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(last)));
            x += (rng.float(f64) - 0.5) * 0.9 * taper;
            y += (rng.float(f64) - 0.5) * 0.9 * taper;
        }
        moves[i] = .{ .t = t, .x = x, .y = y };
    }
    moves[last].x = land[0];
    moves[last].y = land[1];
    return moves;
}

/// Where a pointer enters a view it has never been in: the edge nearest
/// the target, at a point near the target's projection onto it.
pub fn entryPoint(view_w: f64, view_h: f64, target: [2]f64, rng: std.Random) [2]f64 {
    const dl = target[0];
    const dr = view_w - 1 - target[0];
    const dt = target[1];
    const db = view_h - 1 - target[1];
    const m = @min(@min(dl, dr), @min(dt, db));
    const slide_x = std.math.clamp(target[0] + (rng.float(f64) - 0.5) * view_w * 0.3, 0, view_w - 1);
    const slide_y = std.math.clamp(target[1] + (rng.float(f64) - 0.5) * view_h * 0.3, 0, view_h - 1);
    if (m == dl) return .{ 0, slide_y };
    if (m == dr) return .{ view_w - 1, slide_y };
    if (m == dt) return .{ slide_x, 0 };
    return .{ slide_x, view_h - 1 };
}

/// One typed character's edges, ms from the plan's start. The shift
/// times are meaningful only for a character typed with Shift.
pub const KeyTime = struct { down: f64, up: f64, shift_down: f64, shift_up: f64 };

fn draw(list: []const f64, rng: std.Random) f64 {
    return list[rng.uintLessThan(usize, list.len)] * (0.92 + 0.16 * rng.float(f64));
}

fn drawHold(pack: Pack, cls: KeyClass, rng: std.Random) ?f64 {
    const own = pack.keys.hold[@intFromEnum(cls)];
    if (own.len > 0) return draw(own, rng);
    for (pack.keys.hold) |h| if (h.len > 0) return draw(h, rng);
    return null;
}

fn drawFlight(pack: Pack, from: KeyClass, to: KeyClass, rng: std.Random) ?f64 {
    const own = pack.keys.flight[@intFromEnum(from)][@intFromEnum(to)];
    if (own.len > 0) return draw(own, rng);
    for (pack.keys.flight) |row| {
        const f = row[@intFromEnum(to)];
        if (f.len > 0) return draw(f, rng);
    }
    for (pack.keys.flight) |row| for (row) |f| {
        if (f.len > 0) return draw(f, rng);
    };
    return null;
}

/// Key edges for a run of characters of `classes`, with per-key holds
/// and down-to-down flights drawn from the pack. Keys never overlap: a
/// hold that would outlast the next key's down is cut short.
pub fn planTyping(gpa: std.mem.Allocator, pack: Pack, classes: []const KeyClass, shifted: []const bool, rng: std.Random) ![]KeyTime {
    std.debug.assert(classes.len == shifted.len);
    if (pack.keys.holdCount() == 0) return error.NoKeys;
    const out = try gpa.alloc(KeyTime, classes.len);
    errdefer gpa.free(out);
    var t: f64 = 0;
    for (classes, 0..) |cls, i| {
        if (i > 0) t += @max(drawFlight(pack, classes[i - 1], cls, rng) orelse 160, 25);
        const hold = @max(drawHold(pack, cls, rng) orelse 90, 15);
        out[i] = .{ .down = t, .up = t + hold, .shift_down = t, .shift_up = t + hold };
    }
    // Second pass: clamp holds and place the Shift edges between keys.
    for (out, 0..) |*k, i| {
        const next_down: f64 = if (i + 1 < out.len) out[i + 1].down else k.up + 120;
        const prev_up: f64 = if (i > 0) out[i - 1].up else k.down - 60;
        if (k.up > next_down - 8) k.up = @max(k.down + 10, next_down - 8);
        if (shifted[i]) {
            const lead = @min(45, @max(0, (k.down - prev_up) * 0.45));
            const lag = @min(35, @max(0, (next_down - k.up) * 0.4));
            k.shift_down = k.down - lead;
            k.shift_up = k.up + lag;
        }
    }
    // Plans start at 0: shift the whole run so the first edge is there.
    var first = out[0].down;
    for (out) |k| first = @min(first, @min(k.down, k.shift_down));
    for (out) |*k| {
        k.down -= first;
        k.up -= first;
        k.shift_down -= first;
        k.shift_up -= first;
    }
    return out;
}

pub const WheelStep = struct { t: f64, dx: i32, dy: i32 };

/// Integer split of `total` by cumulative fraction, so the parts sum
/// to `total` exactly.
fn part(total: i32, num: f64) i32 {
    return @intFromFloat(@round(@as(f64, @floatFromInt(total)) * num));
}

/// Wheel events that scroll exactly (`dx`, `dy`) in recorded burst
/// shapes: the wanted distance is split over 1..8 bursts (never-recent
/// ones), each scaled along its own major axis, with a recorded-looking
/// pause between bursts.
pub fn planScroll(gpa: std.mem.Allocator, pack: Pack, dx: i32, dy: i32, typical_burst_px: f64, recent: *Recent, rng: std.Random) ![]WheelStep {
    if (pack.scroll.len == 0) return error.NoScroll;
    const major_y = @abs(dy) >= @abs(dx);
    const want_major: i32 = if (major_y) dy else dx;
    const want_minor: i32 = if (major_y) dx else dy;
    const n_bursts: usize = std.math.clamp(@as(usize, @intFromFloat(@round(@as(f64, @floatFromInt(@abs(want_major))) / @max(typical_burst_px, 1)))), 1, 8);
    var out: std.ArrayList(WheelStep) = .empty;
    errdefer out.deinit(gpa);
    var t: f64 = 0;
    const window = exclusionWindow(pack.scroll.len);
    for (0..n_bursts) |b| {
        // Pick a burst with a usable major-axis total.
        var pick: ?usize = null;
        for (0..2) |pass| {
            const off = rng.uintLessThan(usize, pack.scroll.len);
            for (0..pack.scroll.len) |k| {
                const i = (off + k) % pack.scroll.len;
                if (pass == 0 and recent.contains(@intCast(i), window)) continue;
                const tot = pack.scroll[i].total();
                if (@abs(if (major_y) tot[1] else tot[0]) < 1e-6 and @abs(tot[0]) + @abs(tot[1]) < 1e-6) continue;
                pick = i;
                break;
            }
            if (pick != null) break;
        }
        const bi = pick orelse return error.NoScroll;
        recent.push(@intCast(bi));
        const burst = pack.scroll[bi];
        const lo = @as(f64, @floatFromInt(b)) / @as(f64, @floatFromInt(n_bursts));
        const hi = @as(f64, @floatFromInt(b + 1)) / @as(f64, @floatFromInt(n_bursts));
        const major_total = part(want_major, hi) - part(want_major, lo);
        const minor_total = part(want_minor, hi) - part(want_minor, lo);
        // Cumulative fraction of the burst's own travel per event, by
        // absolute delta so a burst recorded on the other axis or in the
        // other direction still gives a shape.
        var travel: f64 = 0;
        for (burst.events) |e| travel += @abs(if (major_y) e.dy else e.dx) + 1e-3;
        var cum: f64 = 0;
        var prev_major: i32 = 0;
        var prev_minor: i32 = 0;
        const t0 = burst.events[0].t;
        for (burst.events) |e| {
            cum += @abs(if (major_y) e.dy else e.dx) + 1e-3;
            const frac = cum / travel;
            const now_major = part(major_total, frac);
            const now_minor = part(minor_total, frac);
            const step_major = now_major - prev_major;
            const step_minor = now_minor - prev_minor;
            prev_major = now_major;
            prev_minor = now_minor;
            if (step_major == 0 and step_minor == 0) continue;
            try out.append(gpa, .{
                .t = t + (e.t - t0) * (0.95 + 0.1 * rng.float(f64)),
                .dx = if (major_y) step_minor else step_major,
                .dy = if (major_y) step_major else step_minor,
            });
        }
        if (out.items.len > 0) t = out.items[out.items.len - 1].t;
        t += 140 + rng.float(f64) * 220;
    }
    // Enforce non-decreasing times after the per-event jitter.
    var i: usize = 1;
    while (i < out.items.len) : (i += 1) {
        if (out.items[i].t < out.items[i - 1].t) out.items[i].t = out.items[i - 1].t;
    }
    return out.toOwnedSlice(gpa);
}

/// Typical travel of one burst in the pack, in its own units; what
/// `planScroll` divides the wanted distance by to decide the burst count.
pub fn typicalBurst(pack: Pack, px_per_unit: f64) f64 {
    if (pack.scroll.len == 0) return 1;
    var sum: f64 = 0;
    for (pack.scroll) |b| {
        const tot = b.total();
        sum += @max(@abs(tot[0]), @abs(tot[1]));
    }
    return @max(sum / @as(f64, @floatFromInt(pack.scroll.len)) * px_per_unit, 40);
}

const testing = std.testing;
const synth = @import("synth.zig");

fn testPack(arena: std.mem.Allocator, seed: u64) !Pack {
    const bytes = try synth.generate(arena, .{ .seed = seed });
    var diag: pack_mod.Diag = .{};
    return pack_mod.parse(arena, bytes, &diag);
}

test "the warp starts at the pointer and lands exactly on the sampled point inside the box" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p = try testPack(arena.allocator(), 1);
    const fitts = Fitts.fit(p.reaches);
    var prng = Rng.init(7);
    var recent: Recent = .{};
    const box = [4]f64{ 400, 300, 60, 30 };
    const plan = try planReach(testing.allocator, p, fitts, .{ 20, 40 }, box, &recent, prng.random());
    defer plan.deinit(testing.allocator);
    try testing.expect(plan.moves.len > 5);
    try testing.expectApproxEqAbs(@as(f64, 20), plan.moves[0].x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 40), plan.moves[0].y, 1e-9);
    const last = plan.moves[plan.moves.len - 1];
    try testing.expect(last.x > box[0] and last.x < box[0] + box[2]);
    try testing.expect(last.y > box[1] and last.y < box[1] + box[3]);
    for (plan.moves[1..], 1..) |m, i| try testing.expect(m.t > plan.moves[i - 1].t);
    try testing.expect(plan.press > last.t);
    try testing.expect(plan.release > plan.press);
}

test "the path length scales with the wanted distance and time with the Fitts ratio" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p = try testPack(arena.allocator(), 2);
    const fitts = Fitts.fit(p.reaches);
    try testing.expect(fitts.b > 0);
    // A harder target (farther, smaller) takes longer than an easy one.
    try testing.expect(fitts.mt(800, 10) > fitts.mt(100, 60));
    try testing.expect(fitts.ratio(200, 30, 800, 10) > 1);
    try testing.expect(fitts.ratio(800, 10, 100, 60) < 1);
    try testing.expectApproxEqAbs(@as(f64, 1), fitts.ratio(300, 20, 300, 20), 1e-9);
    // The same reach warped onto 2x the distance has 2x the path length
    // (up to the sub-pixel jitter), and a 1.5 ratio stretches its time.
    const r = p.reaches[0];
    var prng = Rng.init(3);
    const near = try warp(testing.allocator, r, .{ 0, 0 }, .{ 200, 0 }, 1, prng.random());
    defer testing.allocator.free(near);
    prng = Rng.init(3);
    const far = try warp(testing.allocator, r, .{ 0, 0 }, .{ 400, 0 }, 1.5, prng.random());
    defer testing.allocator.free(far);
    const ln = pathLength(near);
    const lf = pathLength(far);
    try testing.expect(lf > ln * 1.9 and lf < ln * 2.1);
    try testing.expectApproxEqAbs(@as(f64, 1.5), far[far.len - 1].t / near[near.len - 1].t, 0.01);
    try testing.expectEqual(@as(f64, 400), far[far.len - 1].x);
    try testing.expectEqual(@as(f64, 0), far[0].x);
}

fn pathLength(moves: []const Move) f64 {
    var len: f64 = 0;
    for (moves[1..], 1..) |m, i| len += std.math.hypot(m.x - moves[i - 1].x, m.y - moves[i - 1].y);
    return len;
}

test "a fixed seed is deterministic and the exclusion window changes the next pick" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p = try testPack(arena.allocator(), 4);
    const fitts = Fitts.fit(p.reaches);
    const box = [4]f64{ 500, 200, 40, 40 };
    var a_rng = Rng.init(99);
    var b_rng = Rng.init(99);
    var ra: Recent = .{};
    var rb: Recent = .{};
    const a = try planReach(testing.allocator, p, fitts, .{ 10, 10 }, box, &ra, a_rng.random());
    defer a.deinit(testing.allocator);
    const b = try planReach(testing.allocator, p, fitts, .{ 10, 10 }, box, &rb, b_rng.random());
    defer b.deinit(testing.allocator);
    try testing.expectEqual(a.moves.len, b.moves.len);
    for (a.moves, b.moves) |x, y| {
        try testing.expectEqual(x.t, y.t);
        try testing.expectEqual(x.x, y.x);
    }
    // Same wanted reach again on the SAME connection: the used reach is
    // excluded, so the path is a different recording.
    const again = try planReach(testing.allocator, p, fitts, .{ 10, 10 }, box, &ra, a_rng.random());
    defer again.deinit(testing.allocator);
    try testing.expect(again.reach.? != a.reach.?);
    try testing.expect(ra.contains(a.reach.?, exclusionWindow(p.reaches.len)));
}

test "selection prefers the nearest cell" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p = try testPack(arena.allocator(), 5);
    var prng = Rng.init(1);
    const recent: Recent = .{};
    // Straight right, far, small: every one of the best three must be
    // within 90 degrees of the wanted direction.
    for (0..20) |_| {
        const idx = select(p, 700, 0, 12, &recent, prng.random()).?;
        try testing.expect(angleDiff(p.reaches[idx].direction(), 0) < std.math.pi / 2.0);
    }
}

test "typing plans keep keys ordered, non-overlapping, and shift wraps its key" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p = try testPack(arena.allocator(), 6);
    var prng = Rng.init(11);
    const classes = [_]KeyClass{ .left, .right, .space, .left, .right };
    const shifted = [_]bool{ true, false, false, false, true };
    const keys = try planTyping(testing.allocator, p, &classes, &shifted, prng.random());
    defer testing.allocator.free(keys);
    try testing.expectEqual(@as(f64, 0), @min(keys[0].down, keys[0].shift_down));
    for (keys, 0..) |k, i| {
        try testing.expect(k.up > k.down);
        if (shifted[i]) try testing.expect(k.shift_down <= k.down and k.shift_up >= k.up);
        if (i > 0) {
            try testing.expect(k.down > keys[i - 1].up);
            try testing.expect(k.down - keys[i - 1].down >= 25);
        }
    }
    var empty: Pack = p;
    empty.keys = .{};
    try testing.expectError(error.NoKeys, planTyping(testing.allocator, empty, &classes, &shifted, prng.random()));
}

test "scroll plans sum exactly to the wanted distance in non-decreasing time" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p = try testPack(arena.allocator(), 8);
    var prng = Rng.init(5);
    var recent: Recent = .{};
    for ([_][2]i32{ .{ 0, 600 }, .{ 0, -250 }, .{ 300, 7 }, .{ 0, 1 } }) |want| {
        const steps = try planScroll(testing.allocator, p, want[0], want[1], typicalBurst(p, 1), &recent, prng.random());
        defer testing.allocator.free(steps);
        var sx: i32 = 0;
        var sy: i32 = 0;
        for (steps, 0..) |s, i| {
            sx += s.dx;
            sy += s.dy;
            if (i > 0) try testing.expect(s.t >= steps[i - 1].t);
        }
        try testing.expectEqual(want[0], sx);
        try testing.expectEqual(want[1], sy);
    }
}

test "a fresh view is entered from the edge nearest the target" {
    var prng = Rng.init(2);
    const left = entryPoint(1000, 800, .{ 30, 400 }, prng.random());
    try testing.expectEqual(@as(f64, 0), left[0]);
    const bottom = entryPoint(1000, 800, .{ 500, 790 }, prng.random());
    try testing.expectEqual(@as(f64, 799), bottom[1]);
}
