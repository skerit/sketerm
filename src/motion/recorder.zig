//! The motion trainer's model: turns device events (with their device
//! timestamps) into a motion pack, and decides which target to show
//! next from a coverage grid. GTK-free so the whole recording logic is
//! unit-testable; `src/ui/motiontrainer.zig` only feeds it events.
//!
//! Nothing typed is stored: key events arrive as a key CLASS and a
//! timestamp, never as text.

const std = @import("std");
const pack_mod = @import("pack.zig");
const KeyClass = pack_mod.KeyClass;

/// Coverage cells: distance x direction x target-size buckets, each
/// wanting `PER_CELL` reaches (8 x 8 x 3 x 4 = 768, ~15-20 minutes).
pub const DIST_BUCKETS = [_]f64{ 60, 110, 170, 250, 350, 480, 650, 900 };
pub const DIRS = 8;
pub const SIZES = [_]f64{ 14, 32, 72 };
pub const PER_CELL = 4;
pub const CELLS = DIST_BUCKETS.len * DIRS * SIZES.len;

/// A gap between wheel events longer than this starts a new burst.
pub const BURST_GAP_MS: f64 = 260;
/// A flight longer than this is a pause, not a digraph.
pub const MAX_FLIGHT_MS: f64 = 1500;

pub const Target = struct { x: f64, y: f64, w: f64, h: f64, cell: usize };

pub const Coverage = struct {
    counts: [CELLS]u8 = @splat(0),

    pub fn cellOf(d: f64, theta: f64, w: f64) usize {
        var di: usize = 0;
        var best = std.math.inf(f64);
        for (DIST_BUCKETS, 0..) |b, i| {
            const e = @abs(@log(@max(d, 1) / b));
            if (e < best) {
                best = e;
                di = i;
            }
        }
        const turn = @mod(theta + std.math.pi / @as(f64, DIRS), 2 * std.math.pi);
        const dir: usize = @min(@as(usize, @intFromFloat(turn / (2 * std.math.pi) * DIRS)), DIRS - 1);
        var si: usize = 0;
        best = std.math.inf(f64);
        for (SIZES, 0..) |s, i| {
            const e = @abs(@log(@max(w, 1) / s));
            if (e < best) {
                best = e;
                si = i;
            }
        }
        return (di * DIRS + dir) * SIZES.len + si;
    }

    pub fn note(self: *Coverage, cell: usize) void {
        self.counts[cell] +|= 1;
    }

    /// Reaches still wanted for a complete pack.
    pub fn missing(self: *const Coverage) usize {
        var n: usize = 0;
        for (self.counts) |cnt| n += PER_CELL -| cnt;
        return n;
    }

    pub fn filledCells(self: *const Coverage) usize {
        var n: usize = 0;
        for (self.counts) |cnt| {
            if (cnt >= PER_CELL) n += 1;
        }
        return n;
    }

    /// The next target from `from` inside a `w` x `h` area: the
    /// least-filled cell that fits, ties broken by `rng`. Null when no
    /// cell fits the area at all.
    pub fn next(self: *const Coverage, from: [2]f64, area_w: f64, area_h: f64, rng: std.Random) ?Target {
        var best: ?Target = null;
        var best_count: u8 = std.math.maxInt(u8);
        var seen: usize = 0;
        const margin: f64 = 4;
        for (0..CELLS) |cell| {
            const si = cell % SIZES.len;
            const dir = (cell / SIZES.len) % DIRS;
            const di = cell / (SIZES.len * DIRS);
            const size = SIZES[si];
            const theta = @as(f64, @floatFromInt(dir)) * 2 * std.math.pi / DIRS + (rng.float(f64) - 0.5) * 0.5;
            const d = DIST_BUCKETS[di] * (0.92 + 0.16 * rng.float(f64));
            const cx = from[0] + d * @cos(theta);
            const cy = from[1] + d * @sin(theta);
            if (cx - size / 2 < margin or cy - size / 2 < margin or cx + size / 2 > area_w - margin or cy + size / 2 > area_h - margin) continue;
            const cnt = self.counts[cell];
            if (cnt > best_count) continue;
            if (cnt < best_count) seen = 0;
            seen += 1;
            // Reservoir pick among the equally least-filled cells.
            if (cnt < best_count or rng.uintLessThan(usize, seen) == 0) {
                best_count = cnt;
                best = .{ .x = cx - size / 2, .y = cy - size / 2, .w = size, .h = size, .cell = Coverage.cellOf(std.math.hypot(cx - from[0], cy - from[1]), std.math.atan2(cy - from[1], cx - from[0]), size) };
            }
        }
        return best;
    }
};

pub const Session = struct {
    arena: std.heap.ArenaAllocator,
    device: pack_mod.Device = .unknown,
    scale: f64 = 1,
    recorder: []const u8 = "",
    created: []const u8 = "",
    coverage: Coverage = .{},

    reaches: std.ArrayList(pack_mod.Reach) = .empty,
    hold: [KeyClass.count]std.ArrayList(f64) = @splat(.empty),
    flight: [KeyClass.count][KeyClass.count]std.ArrayList(f64) = @splat(@splat(.empty)),
    bursts: std.ArrayList(pack_mod.Burst) = .empty,
    idle: std.ArrayList(pack_mod.Idle) = .empty,
    /// Device intervals between consecutive motion samples, for the
    /// measured sample rate.
    intervals: std.ArrayList(f64) = .empty,
    last_motion_t: ?f64 = null,

    // The reach in progress.
    cur: ?struct {
        appeared: f64,
        start: [2]f64,
        target: Target,
        samples: std.ArrayList(pack_mod.Sample),
        down: ?f64 = null,
        down_at: [2]f64 = .{ 0, 0 },
    } = null,
    /// Keys down now: per pressed hardware keycode its down time and class.
    keys_down: std.AutoHashMapUnmanaged(u32, struct { t: f64, class: KeyClass }) = .empty,
    last_key_down: ?struct { t: f64, class: KeyClass } = null,
    burst: std.ArrayList(pack_mod.Wheel) = .empty,
    burst_smooth: bool = false,
    burst_t0: f64 = 0,
    idle_cur: ?struct { t0: f64, origin: [2]f64, samples: std.ArrayList(pack_mod.Sample) } = null,

    pub fn init(gpa: std.mem.Allocator) Session {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(self: *Session) void {
        self.arena.deinit();
    }

    fn a(self: *Session) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// One pointer sample (device time in ms, area coordinates), from
    /// the event itself or its coalesced history.
    pub fn motion(self: *Session, t: f64, x: f64, y: f64) !void {
        if (self.last_motion_t) |prev| {
            const dt = t - prev;
            // Pauses are outvoted by the median; only stops are dropped.
            if (dt > 0 and dt < 250) try self.intervals.append(self.a(), dt);
        }
        self.last_motion_t = t;
        if (self.cur) |*r| {
            if (r.down == null) {
                if (r.samples.items.len > 0 and t <= r.samples.items[r.samples.items.len - 1].t + r.appeared) return;
                try r.samples.append(self.a(), .{ .t = t - r.appeared, .x = x - r.start[0], .y = y - r.start[1] });
            }
        }
        if (self.idle_cur) |*seg| {
            // The segment starts at its first sample: the trainer's
            // "start" click has no device timestamp of its own.
            if (seg.samples.items.len == 0) {
                seg.t0 = t;
                seg.origin = .{ x, y };
            }
            if (seg.samples.items.len == 0 or t - seg.t0 > seg.samples.items[seg.samples.items.len - 1].t)
                try seg.samples.append(self.a(), .{ .t = t - seg.t0, .x = x - seg.origin[0], .y = y - seg.origin[1] });
        }
    }

    /// A target appeared at time `t` with the pointer at `at`.
    pub fn beginReach(self: *Session, t: f64, at: [2]f64, target: Target) !void {
        self.cur = .{ .appeared = t, .start = at, .target = target, .samples = .empty };
        try self.cur.?.samples.append(self.a(), .{ .t = 0, .x = 0, .y = 0 });
    }

    /// The button went down; false (reach kept open) when it missed.
    pub fn press(self: *Session, t: f64, x: f64, y: f64) bool {
        const r = &(self.cur orelse return false);
        const tg = r.target;
        if (x < tg.x or y < tg.y or x > tg.x + tg.w or y > tg.y + tg.h) return false;
        // The press point ends the path: make it the last sample.
        if (r.samples.items.len > 0) {
            const last = r.samples.items[r.samples.items.len - 1];
            if (t - r.appeared > last.t)
                r.samples.append(self.a(), .{ .t = t - r.appeared, .x = x - r.start[0], .y = y - r.start[1] }) catch return false;
        }
        r.down = t;
        r.down_at = .{ x, y };
        return true;
    }

    /// The button came up: the reach is complete and kept when valid.
    /// @return whether a reach was added.
    pub fn release(self: *Session, t: f64) !bool {
        const r = self.cur orelse return false;
        const down = r.down orelse return false;
        self.cur = null;
        const tg = r.target;
        const reach: pack_mod.Reach = .{
            .start = r.start,
            .target = .{ tg.x, tg.y, tg.w, tg.h },
            .samples = r.samples.items,
            .down = down - r.appeared,
            .up = @max(t, down + 1) - r.appeared,
            .land = .{ std.math.clamp((r.down_at[0] - tg.x) / tg.w, 0, 1), std.math.clamp((r.down_at[1] - tg.y) / tg.h, 0, 1) },
        };
        if (reach.path().len < 2 or reach.distance() < pack_mod.MIN_REACH_PX) return false;
        try self.reaches.append(self.a(), reach);
        self.coverage.note(Coverage.cellOf(reach.distance(), reach.direction(), @min(tg.w, tg.h)));
        return true;
    }

    /// A key went down (`code`: the hardware keycode, so a repeat or a
    /// rollover is told apart; `class`: where the key sits).
    pub fn keyDown(self: *Session, t: f64, code: u32, class: KeyClass) !void {
        if (self.keys_down.contains(code)) return; // auto-repeat
        if (self.last_key_down) |prev| {
            const f = t - prev.t;
            if (f > 0 and f <= MAX_FLIGHT_MS) try self.flight[@intFromEnum(prev.class)][@intFromEnum(class)].append(self.a(), f);
        }
        self.last_key_down = .{ .t = t, .class = class };
        try self.keys_down.put(self.a(), code, .{ .t = t, .class = class });
    }

    pub fn keyUp(self: *Session, t: f64, code: u32) !void {
        const kv = self.keys_down.fetchRemove(code) orelse return;
        const h = t - kv.value.t;
        if (h > 0 and h <= 2000) try self.hold[@intFromEnum(kv.value.class)].append(self.a(), h);
    }

    /// A typing prompt ended: the next key is not a digraph of the last.
    pub fn typingBreak(self: *Session) void {
        self.last_key_down = null;
    }

    pub fn wheel(self: *Session, t: f64, dx: f64, dy: f64, smooth: bool) !void {
        if (self.burst.items.len > 0) {
            const last = self.burst.items[self.burst.items.len - 1];
            if (t - (self.burst_t0 + last.t) > BURST_GAP_MS or smooth != self.burst_smooth) try self.closeBurst();
        }
        if (self.burst.items.len == 0) {
            self.burst_t0 = t;
            self.burst_smooth = smooth;
        }
        const rel = @max(t - self.burst_t0, if (self.burst.items.len > 0) self.burst.items[self.burst.items.len - 1].t else 0);
        try self.burst.append(self.a(), .{ .t = rel, .dx = dx, .dy = dy });
    }

    /// Close the wheel burst in progress, if any (also on a time-out).
    pub fn closeBurst(self: *Session) !void {
        if (self.burst.items.len == 0) return;
        if (self.burst.items.len <= pack_mod.MAX_BURST_EVENTS and self.bursts.items.len < pack_mod.MAX_BURSTS)
            try self.bursts.append(self.a(), .{ .smooth = self.burst_smooth, .events = try self.a().dupe(pack_mod.Wheel, self.burst.items) });
        self.burst = .empty;
    }

    /// Whether a burst is open whose last event is older than the gap.
    pub fn burstStale(self: *const Session, now: f64) bool {
        if (self.burst.items.len == 0) return false;
        return now - (self.burst_t0 + self.burst.items[self.burst.items.len - 1].t) > BURST_GAP_MS;
    }

    /// Start an idle-drift segment; it begins at the next motion sample.
    pub fn beginIdle(self: *Session) void {
        self.idle_cur = .{ .t0 = 0, .origin = .{ 0, 0 }, .samples = .empty };
    }

    pub fn endIdle(self: *Session) !void {
        const seg = self.idle_cur orelse return;
        self.idle_cur = null;
        if (seg.samples.items.len >= 2 and self.idle.items.len < pack_mod.MAX_IDLE)
            try self.idle.append(self.a(), .{ .samples = seg.samples.items });
    }

    /// The device's sample rate, from the median motion interval.
    pub fn rateHz(self: *Session) f64 {
        if (self.intervals.items.len < 8) return 0;
        const copy = self.a().dupe(f64, self.intervals.items) catch return 0;
        std.mem.sort(f64, copy, {}, std.sort.asc(f64));
        const med = copy[copy.len / 2];
        return if (med > 0) @min(1000 / med, 8000) else 0;
    }

    pub fn keyCount(self: *const Session) usize {
        var n: usize = 0;
        for (self.hold) |h| n += h.items.len;
        return n;
    }

    /// The pack as JSON. Valid only when something was recorded and the
    /// rate could be measured (`error.Empty` / `error.NoRate` otherwise).
    pub fn write(self: *Session, w: *std.Io.Writer) !void {
        try self.closeBurst();
        const rate = self.rateHz();
        if (rate <= 1) return error.NoRate;
        if (self.reaches.items.len == 0 and self.keyCount() == 0 and self.bursts.items.len == 0) return error.Empty;
        var keys: pack_mod.Keys = .{};
        for (&keys.hold, self.hold) |*dst, src| dst.* = src.items;
        for (&keys.flight, self.flight) |*row, srow| for (row, srow) |*dst, src| {
            dst.* = src.items;
        };
        const p: pack_mod.Pack = .{
            .header = .{ .device = self.device, .rate_hz = rate, .scale = self.scale, .recorder = self.recorder, .created = self.created },
            .reaches = self.reaches.items,
            .keys = keys,
            .scroll = self.bursts.items,
            .idle = self.idle.items,
        };
        try pack_mod.write(p, w);
    }
};

test "a recorded session becomes a pack that validates, with nothing typed in it" {
    const t = std.testing;
    var s = Session.init(t.allocator);
    defer s.deinit();
    s.device = .mouse;
    var prng = std.Random.DefaultPrng.init(3);
    const rng = prng.random();
    var at = [2]f64{ 400, 300 };
    var now: f64 = 1000;
    var added: usize = 0;
    for (0..6) |_| {
        const tg = s.coverage.next(at, 1200, 800, rng).?;
        try s.beginReach(now, at, tg);
        const goal = [2]f64{ tg.x + tg.w / 2, tg.y + tg.h / 2 };
        var k: f64 = 1;
        while (k <= 20) : (k += 1) {
            now += 8;
            try s.motion(now, at[0] + (goal[0] - at[0]) * k / 20, at[1] + (goal[1] - at[1]) * k / 20);
        }
        // A miss first: the reach stays open.
        try t.expect(!s.press(now + 5, tg.x - 50, tg.y - 50));
        try t.expect(s.press(now + 40, goal[0], goal[1]));
        if (try s.release(now + 130)) added += 1;
        now += 400;
        at = goal;
    }
    try t.expectEqual(@as(usize, 6), added);
    try t.expectEqual(CELLS * PER_CELL - 6, s.coverage.missing());

    // "hello" typed: only classes and times are kept.
    const word = "hello";
    for (word, 0..) |ch, i| {
        const t0 = now + @as(f64, @floatFromInt(i)) * 170;
        try s.keyDown(t0, ch, KeyClass.of(ch));
        try s.keyDown(t0 + 30, ch, KeyClass.of(ch)); // auto-repeat ignored
        try s.keyUp(t0 + 90, ch);
    }
    try t.expectEqual(@as(usize, 5), s.keyCount());
    for (0..5) |i| try s.wheel(now + @as(f64, @floatFromInt(i)) * 15, 0, 40, true);
    s.beginIdle();
    for (0..10) |i| try s.motion(now + 100 + @as(f64, @floatFromInt(i)) * 8, 300 + @as(f64, @floatFromInt(i % 3)), 200);
    try s.endIdle();
    try t.expectEqual(@as(usize, 1), s.idle.items.len);
    try t.expectEqual(@as(f64, 0), s.idle.items[0].samples[0].t);
    try s.wheel(now + 2000, 0, 120, false);

    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    try s.write(&out.writer);
    try t.expect(std.mem.indexOf(u8, out.written(), "hello") == null);
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var diag: pack_mod.Diag = .{};
    const p = pack_mod.parse(arena.allocator(), out.written(), &diag) catch |err| {
        std.debug.print("refused: {s}\n", .{diag.msg()});
        return err;
    };
    try t.expectEqual(@as(usize, 6), p.reaches.len);
    try t.expectEqual(@as(usize, 2), p.scroll.len);
    try t.expectApproxEqAbs(@as(f64, 125), p.header.rate_hz, 1);
    try t.expectEqual(@as(usize, 4), p.keys.hold[@intFromEnum(KeyClass.right)].len);
}

test "an empty session refuses to write" {
    var s = Session.init(std.testing.allocator);
    defer s.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expectError(error.NoRate, s.write(&out.writer));
}
