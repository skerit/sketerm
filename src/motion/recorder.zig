//! The motion trainer's model: turns device events (with their device
//! timestamps) into a motion pack, and decides which target to show
//! next from a coverage grid. GTK-free so the whole recording logic is
//! unit-testable; `src/ui/motiontrainer.zig` only feeds it events.
//!
//! Nothing typed is stored: key events arrive as a key CLASS and a
//! timestamp, never as text.
//!
//! What may be stored is decided by `pack.zig` alone (`Reach.problem`,
//! `Burst.problem`, `Idle.problem`, `durationOk` and the `MAX_*` caps):
//! an item it would refuse is dropped when recorded and filtered again
//! at `write`, so one bad item can never block a save.

const std = @import("std");
const pack_mod = @import("pack.zig");
const KeyClass = pack_mod.KeyClass;

/// Coverage cells: distance x direction x target-size buckets
/// (8 x 8 x 3 = 192). One reach in every cell is a complete pack; more
/// reaches per cell only add variety.
pub const DIST_BUCKETS = [_]f64{ 60, 110, 170, 250, 350, 480, 650, 900 };
pub const DIRS = 8;
pub const SIZES = [_]f64{ 14, 32, 72 };
pub const CELLS = DIST_BUCKETS.len * DIRS * SIZES.len;

/// Reaches from which replayed clicks have enough to pick from.
pub const USABLE_REACHES = 50;

/// What the trainer records, one page each.
pub const Section = enum {
    reaches,
    typing,
    scrolling,
    idle,

    /// The progress count at which the section is complete (see
    /// `Session.progress`). Typing: ~60 short prompts, enough holds per
    /// key class and flights per class pair. Scrolling: bursts of both
    /// directions and lengths. Idle: about a minute of an idling user's pointer.
    pub fn goal(self: Section) usize {
        return switch (self) {
            .reaches => CELLS,
            .typing => 300,
            .scrolling => 40,
            .idle => 8,
        };
    }

    /// The stored item, plural, as messages name it.
    pub fn noun(self: Section) []const u8 {
        return switch (self) {
            .reaches => "reaches",
            .typing => "key timings",
            .scrolling => "scroll bursts",
            .idle => "idle segments",
        };
    }
};

/// Stored items per section (reaches, key holds, bursts, idle segments).
pub const Counts = std.EnumArray(Section, usize);

/// A gap between wheel events longer than this starts a new burst.
pub const BURST_GAP_MS: f64 = 260;
/// A flight longer than this is a pause, not a digraph; stricter than
/// what a pack may hold.
pub const DIGRAPH_MAX_MS: f64 = 1500;
comptime {
    std.debug.assert(DIGRAPH_MAX_MS <= pack_mod.MAX_FLIGHT_MS);
}
/// A reach whose pointer has been still this long (target ignored, page
/// switched away, hand off the mouse) restarts at its next motion from
/// where the pointer rested, so the pause never becomes reach time. Far
/// below `pack.MAX_PRESS_MS`, and far above any real reaction time.
pub const REACH_PAUSE_MS: f64 = 3_000;
/// Motion intervals the measured rate needs before it is trusted.
pub const RATE_MIN_INTERVALS = 32;
/// The measured rate is the median of this many most recent intervals.
pub const RATE_WINDOW = 1024;

pub const Target = struct { x: f64, y: f64, w: f64, h: f64, cell: usize };

pub const Coverage = struct {
    counts: [CELLS]u16 = @splat(0),

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

    pub fn noteReach(self: *Coverage, r: pack_mod.Reach) void {
        const cell = cellOf(r.distance(), r.direction(), r.width());
        self.counts[cell] +|= 1;
    }

    /// Cells holding at least one reach.
    pub fn filledCells(self: *const Coverage) usize {
        var n: usize = 0;
        for (self.counts) |cnt| {
            if (cnt > 0) n += 1;
        }
        return n;
    }

    /// The next target from `from` inside a `w` x `h` area: the
    /// least-filled cell that fits, ties broken by `rng`. Null when no
    /// cell fits the area at all.
    pub fn next(self: *const Coverage, from: [2]f64, area_w: f64, area_h: f64, rng: std.Random) ?Target {
        var best: ?Target = null;
        var best_count: u16 = std.math.maxInt(u16);
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

/// What became of a released reach.
pub const Release = union(enum) {
    /// No pressed reach was open.
    none,
    kept,
    /// Dropped; the `Reach.problem` sentence says why.
    refused: []const u8,
    /// Dropped: the pack already holds `pack.MAX_REACHES`.
    full,
};

pub const Session = struct {
    arena: std.heap.ArenaAllocator,
    device: pack_mod.Device = .unknown,
    scale: f64 = 1,
    /// Set to `arrival` by a recorder whose display sent no timestamps.
    clock: pack_mod.Clock = .device,
    recorder: []const u8 = "",
    created: []const u8 = "",
    coverage: Coverage = .{},

    reaches: std.ArrayList(pack_mod.Reach) = .empty,
    hold: [KeyClass.count]std.ArrayList(f64) = @splat(.empty),
    flight: [KeyClass.count][KeyClass.count]std.ArrayList(f64) = @splat(@splat(.empty)),
    bursts: std.ArrayList(pack_mod.Burst) = .empty,
    idle: std.ArrayList(pack_mod.Idle) = .empty,

    /// The most recent device intervals between motion samples (a ring),
    /// and how many this session measured in all.
    intervals: [RATE_WINDOW]f64 = undefined,
    interval_n: usize = 0,
    last_motion_t: ?f64 = null,
    /// The rate of a loaded pack, used until this session measured its own.
    base_rate: f64 = 0,
    /// Items loaded from the pack this session continues.
    base: Counts = .initFill(0),
    /// Items at the last save (loaded base items count as saved).
    saved: Counts = .initFill(0),
    /// Sections where a pack cap made the recorder drop an item.
    capped: std.EnumSet(Section) = .empty,

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
            if (dt > 0 and dt < 250) {
                self.intervals[self.interval_n % RATE_WINDOW] = dt;
                self.interval_n += 1;
            }
        }
        self.last_motion_t = t;
        if (self.cur) |*r| if (r.down == null) {
            const last = r.samples.items[r.samples.items.len - 1];
            const last_abs = r.appeared + last.t;
            if (t > last_abs) {
                if (t - last_abs > REACH_PAUSE_MS) {
                    // Restart from where the pointer rested, one sample
                    // interval before this motion.
                    r.start = .{ r.start[0] + last.x, r.start[1] + last.y };
                    r.appeared = t - @min(t - last_abs, self.sampleStepMs());
                    r.samples = .empty;
                    try r.samples.append(self.a(), .{ .t = 0, .x = 0, .y = 0 });
                }
                try r.samples.append(self.a(), .{ .t = t - r.appeared, .x = x - r.start[0], .y = y - r.start[1] });
            }
        };
        if (self.idle_cur) |*seg| {
            // The segment starts at its first sample: the trainer's
            // "start" click has no device timestamp of its own.
            if (seg.samples.items.len == 0) {
                seg.t0 = t;
                seg.origin = .{ x, y };
            }
            const fresh = seg.samples.items.len == 0 or t - seg.t0 > seg.samples.items[seg.samples.items.len - 1].t;
            if (fresh and seg.samples.items.len < pack_mod.MAX_SAMPLES)
                try seg.samples.append(self.a(), .{ .t = t - seg.t0, .x = x - seg.origin[0], .y = y - seg.origin[1] });
        }
    }

    fn sampleStepMs(self: *const Session) f64 {
        const rate = self.rateHz();
        return if (rate > 1) 1000 / rate else 8;
    }

    /// A target appeared at time `t` with the pointer at `at`.
    pub fn beginReach(self: *Session, t: f64, at: [2]f64, target: Target) !void {
        self.cur = .{ .appeared = t, .start = at, .target = target, .samples = .empty };
        try self.cur.?.samples.append(self.a(), .{ .t = 0, .x = 0, .y = 0 });
    }

    /// Drop the reach in progress (its target is gone).
    pub fn cancelReach(self: *Session) void {
        self.cur = null;
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

    /// The button came up: the reach is complete, and kept only when the
    /// pack would accept it.
    pub fn release(self: *Session, t: f64) !Release {
        const r = self.cur orelse return .none;
        const down = r.down orelse return .none;
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
        if (reach.problem()) |why| return .{ .refused = why };
        if (!try self.keepReach(reach)) return .full;
        return .kept;
    }

    fn keepReach(self: *Session, reach: pack_mod.Reach) !bool {
        if (self.reaches.items.len >= pack_mod.MAX_REACHES) {
            self.capped.insert(.reaches);
            return false;
        }
        try self.reaches.append(self.a(), reach);
        self.coverage.noteReach(reach);
        return true;
    }

    /// Append one key duration to `list` when the pack would hold it.
    fn keepDuration(self: *Session, list: *std.ArrayList(f64), ms: f64, cap_ms: f64) !void {
        if (!pack_mod.durationOk(ms, cap_ms)) return;
        if (list.items.len >= pack_mod.MAX_KEY_SAMPLES) {
            self.capped.insert(.typing);
            return;
        }
        try list.append(self.a(), ms);
    }

    /// A key went down (`code`: the hardware keycode, so a repeat or a
    /// rollover is told apart; `class`: where the key sits).
    pub fn keyDown(self: *Session, t: f64, code: u32, class: KeyClass) !void {
        if (self.keys_down.contains(code)) return; // auto-repeat
        if (self.last_key_down) |prev| {
            const f = t - prev.t;
            if (f <= DIGRAPH_MAX_MS) try self.keepDuration(&self.flight[@intFromEnum(prev.class)][@intFromEnum(class)], f, pack_mod.MAX_FLIGHT_MS);
        }
        self.last_key_down = .{ .t = t, .class = class };
        try self.keys_down.put(self.a(), code, .{ .t = t, .class = class });
    }

    pub fn keyUp(self: *Session, t: f64, code: u32) !void {
        const kv = self.keys_down.fetchRemove(code) orelse return;
        try self.keepDuration(&self.hold[@intFromEnum(kv.value.class)], t - kv.value.t, pack_mod.MAX_HOLD_MS);
    }

    /// A typing prompt ended: the next key is not a digraph of the last.
    pub fn typingBreak(self: *Session) void {
        self.last_key_down = null;
    }

    pub fn wheel(self: *Session, t: f64, dx: f64, dy: f64, smooth: bool) !void {
        if (self.burst.items.len > 0) {
            const last = self.burst.items[self.burst.items.len - 1];
            // A burst the pack could not hold is cut, not lost.
            const cut = self.burst.items.len >= pack_mod.MAX_BURST_EVENTS or t - self.burst_t0 > pack_mod.MAX_BURST_MS;
            if (cut or t - (self.burst_t0 + last.t) > BURST_GAP_MS or smooth != self.burst_smooth) try self.closeBurst();
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
        defer self.burst = .empty;
        const b: pack_mod.Burst = .{ .smooth = self.burst_smooth, .events = self.burst.items };
        if (b.problem() != null) return;
        if (self.bursts.items.len >= pack_mod.MAX_BURSTS) {
            self.capped.insert(.scrolling);
            return;
        }
        try self.bursts.append(self.a(), .{ .smooth = b.smooth, .events = try self.a().dupe(pack_mod.Wheel, b.events) });
    }

    /// Start an idle-drift segment; it begins at the next motion sample.
    pub fn beginIdle(self: *Session) void {
        self.idle_cur = .{ .t0 = 0, .origin = .{ 0, 0 }, .samples = .empty };
    }

    /// What became of the idle segment `endIdle` closed.
    pub const IdleEnd = enum {
        kept,
        /// No segment was being recorded, or no motion sample arrived.
        nothing,
        /// The pointer never moved, so idle drift would have nothing to replay.
        no_motion,
        capped,
    };

    pub fn endIdle(self: *Session) !IdleEnd {
        const seg = self.idle_cur orelse return .nothing;
        self.idle_cur = null;
        const idle: pack_mod.Idle = .{ .samples = seg.samples.items };
        if (idle.samples.len == 0 or idle.problem() != null) return .nothing;
        if (!idle.replayable()) return .no_motion;
        if (self.idle.items.len >= pack_mod.MAX_IDLE) {
            self.capped.insert(.idle);
            return .capped;
        }
        try self.idle.append(self.a(), idle);
        return .kept;
    }

    /// The pack's sample rate: the median of this session's recent motion
    /// intervals once `RATE_MIN_INTERVALS` exist (the device being used
    /// now is the best witness of its own rate), else the continued
    /// pack's rate, else 0 (unknown).
    pub fn rateHz(self: *const Session) f64 {
        if (self.interval_n >= RATE_MIN_INTERVALS) {
            const n = @min(self.interval_n, RATE_WINDOW);
            var copy: [RATE_WINDOW]f64 = undefined;
            @memcpy(copy[0..n], self.intervals[0..n]);
            std.mem.sort(f64, copy[0..n], {}, std.sort.asc(f64));
            const med = copy[n / 2];
            if (med > 0) return @min(1000 / med, 8000);
        }
        return if (self.base_rate > 1) self.base_rate else 0;
    }

    pub fn keyCount(self: *const Session) usize {
        var n: usize = 0;
        for (self.hold) |h| n += h.items.len;
        return n;
    }

    pub fn counts(self: *const Session) Counts {
        var out: Counts = .initFill(0);
        out.set(.reaches, self.reaches.items.len);
        out.set(.typing, self.keyCount());
        out.set(.scrolling, self.bursts.items.len);
        out.set(.idle, self.idle.items.len);
        return out;
    }

    /// The count `Section.goal` is measured against: covered cells for
    /// reaches, stored items (and an open burst) for the rest.
    pub fn progress(self: *const Session, s: Section) usize {
        return switch (s) {
            .reaches => self.coverage.filledCells(),
            .scrolling => self.bursts.items.len + @intFromBool(self.burst.items.len > 0),
            .typing, .idle => self.counts().get(s),
        };
    }

    /// Items this session recorded on top of what it loaded as a base.
    pub fn added(self: *const Session) Counts {
        return diff(self.counts(), self.base);
    }

    /// Items recorded since the last save.
    pub fn unsaved(self: *const Session) usize {
        const d = diff(self.counts(), self.saved);
        var n: usize = 0;
        for (d.values) |v| n += v;
        return n;
    }

    fn total(self: *const Session) usize {
        var n: usize = 0;
        for (self.counts().values) |v| n += v;
        return n;
    }

    pub fn markSaved(self: *Session) void {
        self.saved = self.counts();
    }

    /// Record the pointer device class; a session (and so a pack) holds
    /// ONE class, and the first one seen or loaded wins.
    pub fn useDevice(self: *Session, dev: pack_mod.Device, scale: f64) error{DeviceMismatch}!void {
        if (self.device == .unknown) {
            self.device = dev;
            self.scale = scale;
            return;
        }
        if (self.device != dev) return error.DeviceMismatch;
    }

    /// Move to arrival time (the display stamps nothing). Refused once
    /// anything is stored: one pack never mixes two clocks.
    pub fn useArrivalClock(self: *Session) error{ClockMismatch}!void {
        if (self.clock == .arrival) return;
        if (self.total() > 0) return error.ClockMismatch;
        self.clock = .arrival;
        self.interval_n = 0;
    }

    pub const LoadError = error{ DeviceMismatch, ClockMismatch, OutOfMemory };

    /// Add a parsed pack's items to this session: `as_base` when
    /// continuing it (its items count as saved and not as added), else
    /// a restored draft whose items are all unsaved. Refused, with
    /// nothing changed, when the pack's device class or clock differs
    /// from what the session already holds.
    pub fn load(self: *Session, p: pack_mod.Pack, as_base: bool) LoadError!void {
        if (p.header.device != .unknown and self.device != .unknown and p.header.device != self.device) return error.DeviceMismatch;
        const empty = self.total() == 0;
        if (p.header.clock != self.clock) {
            if (!empty) return error.ClockMismatch;
            self.clock = p.header.clock;
            self.interval_n = 0;
        }
        if (self.device == .unknown and p.header.device != .unknown) {
            self.device = p.header.device;
            self.scale = p.header.scale;
        }
        if (empty and p.header.created.len > 0) self.created = try self.a().dupe(u8, p.header.created);
        if (self.base_rate <= 1) self.base_rate = p.header.rate_hz;
        const before = self.counts();

        for (p.reaches) |r| {
            if (r.problem() != null) continue;
            var copy = r;
            copy.samples = try self.a().dupe(pack_mod.Sample, r.samples);
            if (!try self.keepReach(copy)) break;
        }
        for (p.keys.hold, &self.hold) |src, *dst| for (src) |ms| try self.keepDuration(dst, ms, pack_mod.MAX_HOLD_MS);
        for (p.keys.flight, &self.flight) |srow, *drow| for (srow, drow) |src, *dst| {
            for (src) |ms| try self.keepDuration(dst, ms, pack_mod.MAX_FLIGHT_MS);
        };
        for (p.scroll) |b| {
            if (b.problem() != null) continue;
            if (self.bursts.items.len >= pack_mod.MAX_BURSTS) {
                self.capped.insert(.scrolling);
                break;
            }
            try self.bursts.append(self.a(), .{ .smooth = b.smooth, .events = try self.a().dupe(pack_mod.Wheel, b.events) });
        }
        for (p.idle) |seg| {
            if (seg.problem() != null) continue;
            if (self.idle.items.len >= pack_mod.MAX_IDLE) {
                self.capped.insert(.idle);
                break;
            }
            try self.idle.append(self.a(), .{ .samples = try self.a().dupe(pack_mod.Sample, seg.samples) });
        }

        if (as_base) {
            const got = diff(self.counts(), before);
            for (&self.base.values, &self.saved.values, got.values) |*b, *s, g| {
                b.* += g;
                s.* += g;
            }
        }
    }

    /// The pack as JSON: every stored item `pack.parse` accepts, so one
    /// bad item never blocks the rest. `error.NoRate` when no rate is
    /// known, `error.Empty` when nothing storable was recorded. An open
    /// wheel burst is not included (`closeBurst` first to keep it).
    pub fn write(self: *const Session, w: *std.Io.Writer) !void {
        const rate = self.rateHz();
        if (rate <= 1) return error.NoRate;
        var tmp: std.heap.ArenaAllocator = .init(self.arena.child_allocator);
        defer tmp.deinit();
        const ta = tmp.allocator();

        var reaches: std.ArrayList(pack_mod.Reach) = .empty;
        for (self.reaches.items) |r| if (r.problem() == null and reaches.items.len < pack_mod.MAX_REACHES) try reaches.append(ta, r);
        var keys: pack_mod.Keys = .{};
        for (&keys.hold, self.hold) |*dst, src| dst.* = try durations(ta, src.items, pack_mod.MAX_HOLD_MS);
        for (&keys.flight, self.flight) |*row, srow| for (row, srow) |*dst, src| {
            dst.* = try durations(ta, src.items, pack_mod.MAX_FLIGHT_MS);
        };
        var bursts: std.ArrayList(pack_mod.Burst) = .empty;
        for (self.bursts.items) |b| if (b.problem() == null and bursts.items.len < pack_mod.MAX_BURSTS) try bursts.append(ta, b);
        var idle: std.ArrayList(pack_mod.Idle) = .empty;
        for (self.idle.items) |s| if (s.problem() == null and idle.items.len < pack_mod.MAX_IDLE) try idle.append(ta, s);

        if (reaches.items.len == 0 and keys.holdCount() == 0 and bursts.items.len == 0) return error.Empty;
        const p: pack_mod.Pack = .{
            .header = .{ .device = self.device, .rate_hz = rate, .scale = self.scale, .clock = self.clock, .recorder = self.recorder, .created = self.created },
            .reaches = reaches.items,
            .keys = keys,
            .scroll = bursts.items,
            .idle = idle.items,
        };
        try pack_mod.write(p, w);
    }
};

fn diff(x: Counts, y: Counts) Counts {
    var out: Counts = .initFill(0);
    for (&out.values, x.values, y.values) |*o, xv, yv| o.* = xv -| yv;
    return out;
}

fn durations(ta: std.mem.Allocator, src: []const f64, cap_ms: f64) ![]const f64 {
    var out: std.ArrayList(f64) = .empty;
    for (src) |ms| if (pack_mod.durationOk(ms, cap_ms) and out.items.len < pack_mod.MAX_KEY_SAMPLES) try out.append(ta, ms);
    return out.items;
}

const testing = std.testing;

/// One reach from `at` to the centre of the next target, sampled every
/// 8 ms; returns the release outcome and moves `at` and `now`.
fn reachOnce(s: *Session, rng: std.Random, at: *[2]f64, now: *f64, press_delay: f64) !Release {
    const tg = s.coverage.next(at.*, 1200, 800, rng).?;
    try s.beginReach(now.*, at.*, tg);
    const goal = [2]f64{ tg.x + tg.w / 2, tg.y + tg.h / 2 };
    var k: f64 = 1;
    while (k <= 20) : (k += 1) {
        now.* += 8;
        try s.motion(now.*, at[0] + (goal[0] - at[0]) * k / 20, at[1] + (goal[1] - at[1]) * k / 20);
    }
    now.* += press_delay;
    try testing.expect(s.press(now.*, goal[0], goal[1]));
    const out = try s.release(now.* + 90);
    now.* += 400;
    at.* = goal;
    return out;
}

fn parsed(arena: *std.heap.ArenaAllocator, s: *Session) !pack_mod.Pack {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try s.write(&out.writer);
    var diag: pack_mod.Diag = .{};
    return pack_mod.parse(arena.allocator(), try arena.allocator().dupe(u8, out.written()), &diag) catch |err| {
        std.debug.print("refused: {s}\n", .{diag.msg()});
        return err;
    };
}

test "a recorded session becomes a pack that validates, with nothing typed in it" {
    var s = Session.init(testing.allocator);
    defer s.deinit();
    s.device = .mouse;
    var prng = std.Random.DefaultPrng.init(3);
    const rng = prng.random();
    var at = [2]f64{ 400, 300 };
    var now: f64 = 1000;
    var added: usize = 0;
    for (0..6) |i| {
        if (i == 0) {
            // A miss first: the reach stays open.
            const tg = s.coverage.next(at, 1200, 800, rng).?;
            try s.beginReach(now, at, tg);
            try testing.expect(!s.press(now + 5, tg.x - 50, tg.y - 50));
            s.cancelReach();
        }
        if (try reachOnce(&s, rng, &at, &now, 40) == .kept) added += 1;
    }
    try testing.expectEqual(@as(usize, 6), added);
    try testing.expectEqual(@as(usize, 6), s.progress(.reaches));

    // "hello" typed: only classes and times are kept.
    const word = "hello";
    for (word, 0..) |ch, i| {
        const t0 = now + @as(f64, @floatFromInt(i)) * 170;
        try s.keyDown(t0, ch, KeyClass.of(ch));
        try s.keyDown(t0 + 30, ch, KeyClass.of(ch)); // auto-repeat ignored
        try s.keyUp(t0 + 90, ch);
    }
    try testing.expectEqual(@as(usize, 5), s.keyCount());
    for (0..5) |i| try s.wheel(now + @as(f64, @floatFromInt(i)) * 15, 0, 40, true);
    s.beginIdle();
    for (0..10) |i| try s.motion(now + 100 + @as(f64, @floatFromInt(i)) * 8, 300 + @as(f64, @floatFromInt(i % 3)), 200);
    try testing.expectEqual(Session.IdleEnd.kept, try s.endIdle());
    try testing.expectEqual(@as(usize, 1), s.idle.items.len);
    // A pointer that never moved records nothing drift could replay.
    s.beginIdle();
    try s.motion(now + 300, 300, 200);
    try testing.expectEqual(Session.IdleEnd.no_motion, try s.endIdle());
    try testing.expectEqual(Session.IdleEnd.nothing, try s.endIdle());
    try testing.expectEqual(@as(f64, 0), s.idle.items[0].samples[0].t);
    try s.wheel(now + 2000, 0, 120, false);
    try s.closeBurst();

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try s.write(&out.writer);
    try testing.expect(std.mem.indexOf(u8, out.written(), "hello") == null);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p = try parsed(&arena, &s);
    try testing.expectEqual(@as(usize, 6), p.reaches.len);
    try testing.expectEqual(@as(usize, 2), p.scroll.len);
    try testing.expectApproxEqAbs(@as(f64, 125), p.header.rate_hz, 1);
    try testing.expectEqual(@as(usize, 4), p.keys.hold[@intFromEnum(KeyClass.right)].len);
    try testing.expectEqual(@as(usize, 6 + 5 + 2 + 1), s.unsaved());
    s.markSaved();
    try testing.expectEqual(@as(usize, 0), s.unsaved());
}

test "an empty session refuses to write" {
    var s = Session.init(testing.allocator);
    defer s.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectError(error.NoRate, s.write(&out.writer));
}

test "a late click is refused at release and never blocks a save" {
    var s = Session.init(testing.allocator);
    defer s.deinit();
    s.device = .mouse;
    var prng = std.Random.DefaultPrng.init(5);
    const rng = prng.random();
    var at = [2]f64{ 400, 300 };
    var now: f64 = 1000;
    try testing.expectEqual(Release.kept, try reachOnce(&s, rng, &at, &now, 40));
    // The pointer arrives, then rests on the target past the press limit.
    const r = try reachOnce(&s, rng, &at, &now, pack_mod.MAX_PRESS_MS + 1000);
    try testing.expect(r == .refused);
    try testing.expect(std.mem.indexOf(u8, r.refused, "after the target appeared") != null);
    try testing.expectEqual(@as(usize, 1), s.reaches.items.len);
    try testing.expectEqual(Release.kept, try reachOnce(&s, rng, &at, &now, 40));
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(usize, 2), (try parsed(&arena, &s)).reaches.len);
}

test "a long still pause restarts the reach at the next motion" {
    var s = Session.init(testing.allocator);
    defer s.deinit();
    for (0..40) |i| try s.motion(@floatFromInt(i * 8), 100, 100);
    const tg: Target = .{ .x = 380, .y = 90, .w = 32, .h = 32, .cell = 0 };
    try s.beginReach(400, .{ 100, 100 }, tg);
    // Ninety seconds without motion, then the reach itself.
    var now: f64 = 90_400;
    var k: f64 = 1;
    while (k <= 10) : (k += 1) {
        now += 8;
        try s.motion(now, 100 + 29.6 * k, 100 + 0.6 * k);
    }
    try testing.expect(s.press(now + 30, 396, 106));
    try testing.expectEqual(Release.kept, try s.release(now + 110));
    const reach = s.reaches.items[0];
    try testing.expect(reach.down < 200);
    try testing.expectApproxEqAbs(@as(f64, 8), reach.samples[1].t, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 296), reach.distance(), 1);
}

test "write filters an item the pack would refuse instead of failing" {
    var s = Session.init(testing.allocator);
    defer s.deinit();
    s.device = .mouse;
    var prng = std.Random.DefaultPrng.init(7);
    const rng = prng.random();
    var at = [2]f64{ 400, 300 };
    var now: f64 = 1000;
    for (0..3) |_| try testing.expectEqual(Release.kept, try reachOnce(&s, rng, &at, &now, 40));
    // Smuggled past `release`: a reach and a hold no pack may hold.
    var bad = s.reaches.items[1];
    bad.down = pack_mod.MAX_PRESS_MS * 2;
    bad.up = bad.down + 50;
    try s.reaches.append(s.a(), bad);
    try s.hold[0].append(s.a(), pack_mod.MAX_HOLD_MS * 3);
    try s.hold[0].append(s.a(), 90);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p = try parsed(&arena, &s);
    try testing.expectEqual(@as(usize, 3), p.reaches.len);
    try testing.expectEqual(@as(usize, 1), p.keys.hold[0].len);
}

test "a continued pack adds this session's items and recomputes coverage" {
    const synth = @import("synth.zig");
    const bytes = try synth.generate(testing.allocator, .{ .seed = 4 });
    defer testing.allocator.free(bytes);
    var parena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer parena.deinit();
    var diag: pack_mod.Diag = .{};
    const base = try pack_mod.parse(parena.allocator(), bytes, &diag);

    var s = Session.init(testing.allocator);
    defer s.deinit();
    try s.load(base, true);
    try testing.expectEqual(pack_mod.Device.mouse, s.device);
    try testing.expectEqual(base.reaches.len, s.reaches.items.len);
    try testing.expectEqual(@as(usize, 0), s.unsaved());
    try testing.expectEqual(@as(usize, 0), s.added().get(.reaches));
    var cov: Coverage = .{};
    for (base.reaches) |r| cov.noteReach(r);
    try testing.expectEqual(cov.filledCells(), s.progress(.reaches));
    // No motion yet: the pack's own rate stands in.
    try testing.expectEqual(base.header.rate_hz, s.rateHz());

    var prng = std.Random.DefaultPrng.init(8);
    const rng = prng.random();
    var at = [2]f64{ 400, 300 };
    var now: f64 = 1000;
    for (0..3) |_| try testing.expectEqual(Release.kept, try reachOnce(&s, rng, &at, &now, 40));
    try testing.expectEqual(@as(usize, 3), s.added().get(.reaches));
    try testing.expectEqual(@as(usize, 3), s.unsaved());

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p = try parsed(&arena, &s);
    try testing.expectEqual(base.reaches.len + 3, p.reaches.len);
    try testing.expectEqual(base.keys.holdCount(), p.keys.holdCount());
    try testing.expectEqual(base.scroll.len, p.scroll.len);
    try testing.expectEqual(base.idle.len, p.idle.len);
    // 57 new 8 ms intervals: the measured 125 Hz is what is written.
    try testing.expect(s.interval_n >= RATE_MIN_INTERVALS);
    try testing.expectApproxEqAbs(@as(f64, 125), p.header.rate_hz, 1);

    // Loading the result again as a restored draft: everything unsaved.
    var d = Session.init(testing.allocator);
    defer d.deinit();
    try d.load(p, false);
    try testing.expectEqual(p.reaches.len, d.added().get(.reaches));
    try testing.expect(d.unsaved() > 0);
}

test "a continued pack respects the reach cap" {
    var parena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer parena.deinit();
    const one: pack_mod.Reach = .{
        .start = .{ 0, 0 },
        .target = .{ 90, -10, 20, 20 },
        .samples = &.{ .{ .t = 0, .x = 0, .y = 0 }, .{ .t = 8, .x = 40, .y = 1 }, .{ .t = 16, .x = 100, .y = 0 } },
        .down = 30,
        .up = 110,
        .land = .{ 0.5, 0.5 },
    };
    const many = try parena.allocator().alloc(pack_mod.Reach, pack_mod.MAX_REACHES);
    @memset(many, one);
    var s = Session.init(testing.allocator);
    defer s.deinit();
    try s.load(.{ .header = .{ .device = .mouse, .rate_hz = 125 }, .reaches = many }, true);
    try testing.expect(!s.capped.contains(.reaches));
    try s.load(.{ .header = .{ .device = .mouse, .rate_hz = 125 }, .reaches = many[0..2] }, false);
    try testing.expectEqual(pack_mod.MAX_REACHES, s.reaches.items.len);
    try testing.expect(s.capped.contains(.reaches));
    // A reach recorded at the cap is dropped and says so.
    s.cur = .{ .appeared = 0, .start = .{ 0, 0 }, .target = .{ .x = 90, .y = -10, .w = 20, .h = 20, .cell = 0 }, .samples = .empty, .down = 30, .down_at = .{ 100, 0 } };
    try s.cur.?.samples.appendSlice(s.a(), one.samples);
    try testing.expectEqual(Release.full, try s.release(110));
}

test "a pack of another device class or clock is refused, unchanged" {
    const synth = @import("synth.zig");
    const bytes = try synth.generate(testing.allocator, .{ .seed = 2 });
    defer testing.allocator.free(bytes);
    var parena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer parena.deinit();
    var diag: pack_mod.Diag = .{};
    const mouse = try pack_mod.parse(parena.allocator(), bytes, &diag);

    var s = Session.init(testing.allocator);
    defer s.deinit();
    try s.useDevice(.touchpad, 1);
    try testing.expectError(error.DeviceMismatch, s.load(mouse, true));
    try testing.expectEqual(@as(usize, 0), s.reaches.items.len);

    var arrival = mouse;
    arrival.header.clock = .arrival;
    var t = Session.init(testing.allocator);
    defer t.deinit();
    try t.load(mouse, true);
    try testing.expectError(error.ClockMismatch, t.load(arrival, false));
    try testing.expectError(error.ClockMismatch, t.useArrivalClock());
    try testing.expectError(error.DeviceMismatch, t.useDevice(.pen, 1));
    try testing.expectEqual(mouse.reaches.len, t.reaches.items.len);

    // An empty session adopts the pack's clock instead.
    var u = Session.init(testing.allocator);
    defer u.deinit();
    try u.load(arrival, true);
    try testing.expectEqual(pack_mod.Clock.arrival, u.clock);
}

test "the measured rate replaces the pack's once enough intervals exist" {
    var s = Session.init(testing.allocator);
    defer s.deinit();
    s.base_rate = 125;
    try testing.expectEqual(@as(f64, 125), s.rateHz());
    var now: f64 = 0;
    for (0..RATE_MIN_INTERVALS) |_| {
        try s.motion(now, 0, 0);
        now += 1;
    }
    // One interval short: still the pack's rate.
    try testing.expectEqual(@as(f64, 125), s.rateHz());
    try s.motion(now, 0, 0);
    try testing.expectApproxEqAbs(@as(f64, 1000), s.rateHz(), 1e-9);
}

test "goals: one reach per coverage cell, the rest by item count" {
    try testing.expectEqual(@as(usize, 192), Section.reaches.goal());
    try testing.expect(USABLE_REACHES < Section.reaches.goal());
    for (std.enums.values(Section)) |sec| try testing.expect(sec.goal() > 0);
}
