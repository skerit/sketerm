//! Motion packs: one person's recorded pointer reaches, typing rhythm,
//! wheel bursts and idle drift on ONE device, as the versioned JSON file
//! `sketerm motion record` writes and the browser helper replays from.
//!
//! Pure: std only, no GTK, no CEF, no file IO. A parsed `Pack` lives in
//! the arena it was parsed into; every count and bound is re-derived
//! from the body, never trusted from the header.

const std = @import("std");

pub const FORMAT = "sketerm-motion";
pub const VERSION: i64 = 1;
/// Largest pack file anyone reads or sends; a full trainer session is
/// well under a tenth of it.
pub const MAX_BYTES: usize = 32 << 20;
pub const MAX_REACHES: usize = 4096;
pub const MAX_SAMPLES: usize = 4096;
pub const MAX_KEY_SAMPLES: usize = 8192;
pub const MAX_BURSTS: usize = 1024;
pub const MAX_BURST_EVENTS: usize = 1024;
pub const MAX_IDLE: usize = 256;
/// A reach shorter than this (start to press) carries no direction.
pub const MIN_REACH_PX: f64 = 4;
/// Latest press after a reach's target appeared, ms.
pub const MAX_PRESS_MS: f64 = 60_000;
/// Longest press-to-release of a reach, ms.
pub const MAX_CLICK_MS: f64 = 5_000;
/// Longest key hold, ms.
pub const MAX_HOLD_MS: f64 = 2_000;
/// Longest key-down to key-down flight, ms.
pub const MAX_FLIGHT_MS: f64 = 5_000;
/// Longest scroll burst, first event to last, ms.
pub const MAX_BURST_MS: f64 = 60_000;

/// Whether a hold or flight of `ms` fits under `cap_ms`.
pub fn durationOk(ms: f64, cap_ms: f64) bool {
    return std.math.isFinite(ms) and ms > 0 and ms <= cap_ms;
}

/// Why a sample list cannot be stored, or null when it can.
pub fn samplesProblem(samples: []const Sample) ?[]const u8 {
    if (samples.len > MAX_SAMPLES) return std.fmt.comptimePrint("more than {d} pointer samples", .{MAX_SAMPLES});
    for (samples, 0..) |s, i| {
        if (!std.math.isFinite(s.t) or !std.math.isFinite(s.x) or !std.math.isFinite(s.y)) return "a sample is not a finite number";
        if (s.t < 0) return "a sample has a negative time";
        if (i > 0 and s.t <= samples[i - 1].t) return "sample times are not strictly increasing";
    }
    return null;
}

pub const Device = enum {
    mouse,
    touchpad,
    pen,
    unknown,

    pub fn parse(s: []const u8) ?Device {
        return std.meta.stringToEnum(Device, s);
    }
};

/// Which clock a pack's sample times come from. `arrival` means the
/// display sent events without timestamps and the recorder stamped them
/// on arrival, which blurs the device's real timing; a pack written
/// before this field existed is read as `device`.
pub const Clock = enum {
    device,
    arrival,

    pub fn parse(s: []const u8) ?Clock {
        return std.meta.stringToEnum(Clock, s);
    }
};

/// Where a key sits on a US keyboard, which is all the typing timing is
/// keyed by: the recorder never stores which letter was typed.
pub const KeyClass = enum {
    left,
    right,
    space,
    other,

    pub const count = @typeInfo(KeyClass).@"enum".fields.len;

    /// The class of the key that types `cp` on a US layout.
    pub fn of(cp: u21) KeyClass {
        const lower: u21 = if (cp >= 'A' and cp <= 'Z') cp + 32 else cp;
        if (lower == ' ') return .space;
        if (lower > 0x7f) return .other;
        const ch: u8 = @intCast(lower);
        if (std.mem.indexOfScalar(u8, "qwertasdfgzxcvb`12345~!@#$%QWERTASDFGZXCVB", ch) != null) return .left;
        if (std.mem.indexOfScalar(u8, "yuiophjklnm67890-=[]\\;',./^&*()_+{}|:\"<>?", ch) != null) return .right;
        return .other;
    }
};

/// One pointer sample: ms since the target appeared, CSS px from the
/// reach's start point.
pub const Sample = struct { t: f64, x: f64, y: f64 };

/// One recorded reach: from where the pointer rested to a press on a
/// target box, then the release.
pub const Reach = struct {
    start: [2]f64,
    /// x, y, w, h in the same frame as `start`.
    target: [4]f64,
    samples: []const Sample,
    down: f64,
    up: f64,
    /// Where the press landed, normalised to the target box (0..1).
    land: [2]f64,

    /// Samples up to and including the press: the path a replay warps.
    pub fn path(self: Reach) []const Sample {
        var n: usize = 0;
        while (n < self.samples.len and self.samples[n].t <= self.down) n += 1;
        return self.samples[0..n];
    }

    /// The path's end relative to its start.
    pub fn end(self: Reach) [2]f64 {
        const p = self.path();
        const last = p[p.len - 1];
        return .{ last.x - p[0].x, last.y - p[0].y };
    }

    pub fn distance(self: Reach) f64 {
        const e = self.end();
        return std.math.hypot(e[0], e[1]);
    }

    pub fn direction(self: Reach) f64 {
        const e = self.end();
        return std.math.atan2(e[1], e[0]);
    }

    /// Target size along its smaller side, the W of Fitts's law.
    pub fn width(self: Reach) f64 {
        return @min(self.target[2], self.target[3]);
    }

    /// Why this reach cannot be stored, or null when it can. The ONE
    /// rule: `parse` refuses a pack holding such a reach, and the
    /// recorder drops one before it is kept.
    pub fn problem(self: Reach) ?[]const u8 {
        if (!(self.target[2] > 0 and self.target[3] > 0)) return "the target has no area";
        if (samplesProblem(self.samples)) |why| return why;
        if (!(self.land[0] >= 0 and self.land[0] <= 1 and self.land[1] >= 0 and self.land[1] <= 1)) return "\"land\" is outside the target box";
        if (!(self.up > self.down)) return "release is not after the press";
        if (self.down > MAX_PRESS_MS) return std.fmt.comptimePrint("the press came more than {d} s after the target appeared", .{MAX_PRESS_MS / 1000});
        if (self.up - self.down > MAX_CLICK_MS) return std.fmt.comptimePrint("the button was held down more than {d} s", .{MAX_CLICK_MS / 1000});
        if (self.path().len < 2) return "fewer than two samples before the press";
        if (self.distance() < MIN_REACH_PX) return std.fmt.comptimePrint("shorter than {d}px", .{MIN_REACH_PX});
        return null;
    }
};

/// One wheel event of a burst: ms since the burst began, deltas in the
/// recorded device's own units (positive dy scrolls DOWN).
pub const Wheel = struct { t: f64, dx: f64, dy: f64 };

pub const Burst = struct {
    /// Smooth (touchpad, hi-res) rather than notched deltas.
    smooth: bool,
    events: []const Wheel,

    /// The burst's total along x and y.
    pub fn total(self: Burst) [2]f64 {
        var s: [2]f64 = .{ 0, 0 };
        for (self.events) |e| {
            s[0] += e.dx;
            s[1] += e.dy;
        }
        return s;
    }

    /// Why this burst cannot be stored, or null when it can.
    pub fn problem(self: Burst) ?[]const u8 {
        if (self.events.len == 0) return "it has no events";
        if (self.events.len > MAX_BURST_EVENTS) return std.fmt.comptimePrint("more than {d} events", .{MAX_BURST_EVENTS});
        for (self.events, 0..) |e, j| {
            if (!std.math.isFinite(e.t) or !std.math.isFinite(e.dx) or !std.math.isFinite(e.dy)) return "an event is not a finite number";
            if (e.t < 0 or e.t > MAX_BURST_MS or (j > 0 and e.t < self.events[j - 1].t)) return "event times are out of order";
        }
        return null;
    }
};

/// The pointer's wander while its user idles at the screen: samples in
/// ms and CSS px, relative to the segment's own first sample.
pub const Idle = struct {
    samples: []const Sample,

    /// The larger side of the wander's bounding box, px.
    pub fn extent(self: Idle) f64 {
        if (self.samples.len == 0) return 0;
        var lo = [2]f64{ self.samples[0].x, self.samples[0].y };
        var hi = lo;
        for (self.samples) |s| {
            lo = .{ @min(lo[0], s.x), @min(lo[1], s.y) };
            hi = .{ @max(hi[0], s.x), @max(hi[1], s.y) };
        }
        return @max(hi[0] - lo[0], hi[1] - lo[1]);
    }

    /// Why this segment cannot be stored, or null when it can.
    pub fn problem(self: Idle) ?[]const u8 {
        return samplesProblem(self.samples);
    }

    /// Whether idle drift can replay this segment: it moved at all. The
    /// ONE rule, read by replay, the MCP pre-check, the trainer and
    /// `capabilities`. How far it travels is deliberately unbounded: an
    /// idling user's pointer wanders, and replay keeps it inside the view.
    pub fn replayable(self: Idle) bool {
        return self.samples.len >= 2 and self.extent() >= 1;
    }
};

/// Per key class hold times and per class-pair down-to-down flight
/// times, in ms, as observed (an empirical distribution, drawn from).
pub const Keys = struct {
    hold: [KeyClass.count][]const f64 = @splat(&.{}),
    flight: [KeyClass.count][KeyClass.count][]const f64 = @splat(@splat(&.{})),

    pub fn holdCount(self: Keys) usize {
        var n: usize = 0;
        for (self.hold) |h| n += h.len;
        return n;
    }
};

pub const Header = struct {
    device: Device = .unknown,
    rate_hz: f64 = 0,
    scale: f64 = 1,
    clock: Clock = .device,
    recorder: []const u8 = "",
    created: []const u8 = "",
};

pub const Pack = struct {
    header: Header = .{},
    reaches: []const Reach = &.{},
    keys: Keys = .{},
    scroll: []const Burst = &.{},
    idle: []const Idle = &.{},

    pub const Summary = struct {
        device: Device,
        rate_hz: f64,
        scale: f64,
        reaches: usize,
        keys: usize,
        scroll: usize,
        idle: usize,
        /// Idle segments drift can replay (`Idle.replayable`).
        drift: usize,
    };

    pub fn driftCount(self: Pack) usize {
        var n: usize = 0;
        for (self.idle) |seg| n += @intFromBool(seg.replayable());
        return n;
    }

    pub fn summary(self: Pack) Summary {
        return .{
            .device = self.header.device,
            .rate_hz = self.header.rate_hz,
            .scale = self.header.scale,
            .reaches = self.reaches.len,
            .keys = self.keys.holdCount(),
            .scroll = self.scroll.len,
            .idle = self.idle.len,
            .drift = self.driftCount(),
        };
    }
};

/// Why a pack was refused, as one sentence naming the offending part.
pub const Diag = struct {
    buf: [200]u8 = undefined,
    len: usize = 0,

    pub fn msg(self: *const Diag) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn set(self: *Diag, comptime fmt: []const u8, args: anytype) error{Invalid} {
        const out: []const u8 = std.fmt.bufPrint(&self.buf, fmt, args) catch "";
        self.len = out.len;
        return error.Invalid;
    }
};

pub const ParseError = error{ Invalid, OutOfMemory };

/// Parse and validate a pack. Everything returned lives in `arena`.
pub fn parse(arena: std.mem.Allocator, bytes: []const u8, diag: *Diag) ParseError!Pack {
    if (bytes.len > MAX_BYTES) return diag.set("pack is {d} bytes, past the {d}-byte limit", .{ bytes.len, MAX_BYTES });
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return diag.set("pack is not JSON ({s})", .{@errorName(err)}),
    };
    if (root != .object) return diag.set("pack is not a JSON object", .{});
    const obj = root.object;
    const format = obj.get("format") orelse return diag.set("pack has no \"format\"", .{});
    if (format != .string or !std.mem.eql(u8, format.string, FORMAT)) return diag.set("\"format\" is not \"{s}\"", .{FORMAT});
    const version = obj.get("version") orelse return diag.set("pack has no \"version\"", .{});
    if (version != .integer) return diag.set("\"version\" is not an integer", .{});
    if (version.integer != VERSION) return diag.set("unsupported pack version {d} (this build reads version {d})", .{ version.integer, VERSION });

    var pack: Pack = .{};
    pack.header = try parseHeader(obj.get("header") orelse return diag.set("pack has no \"header\"", .{}), diag);
    if (obj.get("reaches")) |r| pack.reaches = try parseReaches(arena, r, diag);
    if (obj.get("keys")) |k| pack.keys = try parseKeys(arena, k, diag);
    if (obj.get("scroll")) |s| pack.scroll = try parseBursts(arena, s, diag);
    if (obj.get("idle")) |i| pack.idle = try parseIdle(arena, i, diag);
    if (pack.reaches.len == 0 and pack.keys.holdCount() == 0 and pack.scroll.len == 0)
        return diag.set("pack holds no reaches, key timings or scroll bursts", .{});
    return pack;
}

fn num(v: std.json.Value) ?f64 {
    const x: f64 = switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => return null,
    };
    return if (std.math.isFinite(x)) x else null;
}

fn parseHeader(v: std.json.Value, diag: *Diag) ParseError!Header {
    if (v != .object) return diag.set("\"header\" is not an object", .{});
    var h: Header = .{};
    const dev = v.object.get("device") orelse return diag.set("header has no \"device\"", .{});
    h.device = if (dev == .string) (Device.parse(dev.string) orelse return diag.set("unknown device class \"{s}\"", .{dev.string})) else return diag.set("header \"device\" is not a string", .{});
    h.rate_hz = num(v.object.get("rate_hz") orelse return diag.set("header has no \"rate_hz\"", .{})) orelse return diag.set("header \"rate_hz\" is not a number", .{});
    if (h.rate_hz <= 1 or h.rate_hz > 8000) return diag.set("header rate_hz {d} is outside 1..8000", .{h.rate_hz});
    if (v.object.get("scale")) |s| h.scale = num(s) orelse return diag.set("header \"scale\" is not a number", .{});
    if (h.scale <= 0 or h.scale > 8) return diag.set("header scale {d} is outside 0..8", .{h.scale});
    if (v.object.get("clock")) |s| {
        h.clock = if (s == .string) (Clock.parse(s.string) orelse return diag.set("unknown clock \"{s}\"", .{s.string})) else return diag.set("header \"clock\" is not a string", .{});
    }
    if (v.object.get("recorder")) |s| if (s == .string) {
        h.recorder = s.string;
    };
    if (v.object.get("created")) |s| if (s == .string) {
        h.created = s.string;
    };
    return h;
}

/// Structure only; what makes a sample list storable is `samplesProblem`.
fn parseSamples(arena: std.mem.Allocator, v: std.json.Value, what: []const u8, idx: usize, diag: *Diag) ParseError![]Sample {
    if (v != .array) return diag.set("{s} {d}: \"samples\" is not an array", .{ what, idx });
    const out = try arena.alloc(Sample, v.array.items.len);
    for (v.array.items, 0..) |s, i| {
        if (s != .array or s.array.items.len != 3) return diag.set("{s} {d}: sample {d} is not [t, dx, dy]", .{ what, idx, i });
        const t = num(s.array.items[0]) orelse return diag.set("{s} {d}: sample {d} has a non-numeric field", .{ what, idx, i });
        const x = num(s.array.items[1]) orelse return diag.set("{s} {d}: sample {d} has a non-numeric field", .{ what, idx, i });
        const y = num(s.array.items[2]) orelse return diag.set("{s} {d}: sample {d} has a non-numeric field", .{ what, idx, i });
        out[i] = .{ .t = t, .x = x, .y = y };
    }
    return out;
}

fn pair(v: ?std.json.Value) ?[2]f64 {
    const a = v orelse return null;
    if (a != .array or a.array.items.len != 2) return null;
    return .{ num(a.array.items[0]) orelse return null, num(a.array.items[1]) orelse return null };
}

fn parseReaches(arena: std.mem.Allocator, v: std.json.Value, diag: *Diag) ParseError![]Reach {
    if (v != .array) return diag.set("\"reaches\" is not an array", .{});
    if (v.array.items.len > MAX_REACHES) return diag.set("{d} reaches, past {d}", .{ v.array.items.len, MAX_REACHES });
    const out = try arena.alloc(Reach, v.array.items.len);
    for (v.array.items, 0..) |r, i| {
        if (r != .object) return diag.set("reach {d} is not an object", .{i});
        const o = r.object;
        const start = pair(o.get("start")) orelse return diag.set("reach {d}: \"start\" is not [x, y]", .{i});
        const tv = o.get("target") orelse return diag.set("reach {d} has no \"target\"", .{i});
        if (tv != .array or tv.array.items.len != 4) return diag.set("reach {d}: \"target\" is not [x, y, w, h]", .{i});
        var target: [4]f64 = undefined;
        for (&target, tv.array.items) |*dst, src| dst.* = num(src) orelse return diag.set("reach {d}: \"target\" has a non-numeric field", .{i});
        const samples = try parseSamples(arena, o.get("samples") orelse return diag.set("reach {d} has no \"samples\"", .{i}), "reach", i, diag);
        const down = num(o.get("down") orelse return diag.set("reach {d} has no \"down\"", .{i})) orelse return diag.set("reach {d}: \"down\" is not a number", .{i});
        const up = num(o.get("up") orelse return diag.set("reach {d} has no \"up\"", .{i})) orelse return diag.set("reach {d}: \"up\" is not a number", .{i});
        const land = pair(o.get("land")) orelse return diag.set("reach {d}: \"land\" is not [u, v]", .{i});
        out[i] = .{ .start = start, .target = target, .samples = samples, .down = down, .up = up, .land = land };
        if (out[i].problem()) |why| return diag.set("reach {d}: {s}", .{ i, why });
    }
    return out;
}

fn parseDurations(arena: std.mem.Allocator, v: std.json.Value, what: []const u8, cap_ms: f64, diag: *Diag) ParseError![]f64 {
    if (v != .array) return diag.set("keys {s} is not an array", .{what});
    if (v.array.items.len > MAX_KEY_SAMPLES) return diag.set("keys {s}: past {d} samples", .{ what, MAX_KEY_SAMPLES });
    const out = try arena.alloc(f64, v.array.items.len);
    for (v.array.items, 0..) |x, i| {
        out[i] = num(x) orelse return diag.set("keys {s}: entry {d} is not a number", .{ what, i });
        if (!durationOk(out[i], cap_ms)) return diag.set("keys {s}: entry {d} is outside 0..{d}ms", .{ what, i, cap_ms });
    }
    return out;
}

fn parseKeys(arena: std.mem.Allocator, v: std.json.Value, diag: *Diag) ParseError!Keys {
    if (v != .object) return diag.set("\"keys\" is not an object", .{});
    var keys: Keys = .{};
    if (v.object.get("hold")) |h| {
        if (h != .object) return diag.set("keys \"hold\" is not an object", .{});
        var it = h.object.iterator();
        while (it.next()) |e| {
            const cls = std.meta.stringToEnum(KeyClass, e.key_ptr.*) orelse return diag.set("keys hold: unknown key class \"{s}\"", .{e.key_ptr.*});
            keys.hold[@intFromEnum(cls)] = try parseDurations(arena, e.value_ptr.*, e.key_ptr.*, MAX_HOLD_MS, diag);
        }
    }
    if (v.object.get("flight")) |f| {
        if (f != .object) return diag.set("keys \"flight\" is not an object", .{});
        var it = f.object.iterator();
        while (it.next()) |e| {
            const sep = std.mem.indexOfScalar(u8, e.key_ptr.*, '>') orelse return diag.set("keys flight: \"{s}\" is not \"<class>><class>\"", .{e.key_ptr.*});
            const from = std.meta.stringToEnum(KeyClass, e.key_ptr.*[0..sep]) orelse return diag.set("keys flight: unknown key class in \"{s}\"", .{e.key_ptr.*});
            const to = std.meta.stringToEnum(KeyClass, e.key_ptr.*[sep + 1 ..]) orelse return diag.set("keys flight: unknown key class in \"{s}\"", .{e.key_ptr.*});
            keys.flight[@intFromEnum(from)][@intFromEnum(to)] = try parseDurations(arena, e.value_ptr.*, e.key_ptr.*, MAX_FLIGHT_MS, diag);
        }
    }
    return keys;
}

fn parseBursts(arena: std.mem.Allocator, v: std.json.Value, diag: *Diag) ParseError![]Burst {
    if (v != .array) return diag.set("\"scroll\" is not an array", .{});
    if (v.array.items.len > MAX_BURSTS) return diag.set("{d} scroll bursts, past {d}", .{ v.array.items.len, MAX_BURSTS });
    const out = try arena.alloc(Burst, v.array.items.len);
    for (v.array.items, 0..) |b, i| {
        if (b != .object) return diag.set("scroll burst {d} is not an object", .{i});
        const ev = b.object.get("events") orelse return diag.set("scroll burst {d} has no \"events\"", .{i});
        if (ev != .array) return diag.set("scroll burst {d}: \"events\" is not an array", .{i});
        const events = try arena.alloc(Wheel, ev.array.items.len);
        for (ev.array.items, 0..) |e, j| {
            if (e != .array or e.array.items.len != 3) return diag.set("scroll burst {d}: event {d} is not [t, dx, dy]", .{ i, j });
            const t = num(e.array.items[0]) orelse return diag.set("scroll burst {d}: event {d} has a non-numeric field", .{ i, j });
            const dx = num(e.array.items[1]) orelse return diag.set("scroll burst {d}: event {d} has a non-numeric field", .{ i, j });
            const dy = num(e.array.items[2]) orelse return diag.set("scroll burst {d}: event {d} has a non-numeric field", .{ i, j });
            events[j] = .{ .t = t, .dx = dx, .dy = dy };
        }
        const smooth = if (b.object.get("smooth")) |s| (s == .bool and s.bool) else false;
        out[i] = .{ .smooth = smooth, .events = events };
        if (out[i].problem()) |why| return diag.set("scroll burst {d}: {s}", .{ i, why });
    }
    return out;
}

fn parseIdle(arena: std.mem.Allocator, v: std.json.Value, diag: *Diag) ParseError![]Idle {
    if (v != .array) return diag.set("\"idle\" is not an array", .{});
    if (v.array.items.len > MAX_IDLE) return diag.set("{d} idle segments, past {d}", .{ v.array.items.len, MAX_IDLE });
    const out = try arena.alloc(Idle, v.array.items.len);
    for (v.array.items, 0..) |s, i| {
        if (s != .object) return diag.set("idle segment {d} is not an object", .{i});
        out[i] = .{ .samples = try parseSamples(arena, s.object.get("samples") orelse return diag.set("idle segment {d} has no \"samples\"", .{i}), "idle segment", i, diag) };
        if (out[i].problem()) |why| return diag.set("idle segment {d}: {s}", .{ i, why });
    }
    return out;
}

/// Serialize `pack` as the version-1 file format, header counts included.
pub fn write(pack: Pack, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const s = pack.summary();
    try w.print("{{\"format\":\"{s}\",\"version\":{d},\"header\":{{\"device\":\"{s}\",\"rate_hz\":{d:.1},\"scale\":{d:.3},\"clock\":\"{s}\",\"recorder\":", .{ FORMAT, VERSION, @tagName(pack.header.device), pack.header.rate_hz, pack.header.scale, @tagName(pack.header.clock) });
    try std.json.Stringify.value(pack.header.recorder, .{}, w);
    try w.writeAll(",\"created\":");
    try std.json.Stringify.value(pack.header.created, .{}, w);
    try w.print(",\"counts\":{{\"reaches\":{d},\"keys\":{d},\"scroll\":{d},\"idle\":{d}}}}},\"reaches\":[", .{ s.reaches, s.keys, s.scroll, s.idle });
    for (pack.reaches, 0..) |r, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"start\":[{d:.2},{d:.2}],\"target\":[{d:.2},{d:.2},{d:.2},{d:.2}],\"samples\":", .{ r.start[0], r.start[1], r.target[0], r.target[1], r.target[2], r.target[3] });
        try writeSamples(r.samples, w);
        try w.print(",\"down\":{d:.3},\"up\":{d:.3},\"land\":[{d:.4},{d:.4}]}}", .{ r.down, r.up, r.land[0], r.land[1] });
    }
    try w.writeAll("],\"keys\":{\"hold\":{");
    var first = true;
    for (pack.keys.hold, 0..) |h, ci| {
        if (h.len == 0) continue;
        if (!first) try w.writeByte(',');
        first = false;
        try w.print("\"{s}\":", .{@tagName(@as(KeyClass, @enumFromInt(ci)))});
        try writeDurations(h, w);
    }
    try w.writeAll("},\"flight\":{");
    first = true;
    for (pack.keys.flight, 0..) |row, fi| for (row, 0..) |f, ti| {
        if (f.len == 0) continue;
        if (!first) try w.writeByte(',');
        first = false;
        try w.print("\"{s}>{s}\":", .{ @tagName(@as(KeyClass, @enumFromInt(fi))), @tagName(@as(KeyClass, @enumFromInt(ti))) });
        try writeDurations(f, w);
    };
    try w.writeAll("}},\"scroll\":[");
    for (pack.scroll, 0..) |b, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"smooth\":{},\"events\":[", .{b.smooth});
        for (b.events, 0..) |e, j| {
            if (j > 0) try w.writeByte(',');
            try w.print("[{d:.3},{d:.3},{d:.3}]", .{ e.t, e.dx, e.dy });
        }
        try w.writeAll("]}");
    }
    try w.writeAll("],\"idle\":[");
    for (pack.idle, 0..) |seg, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"samples\":");
        try writeSamples(seg.samples, w);
        try w.writeByte('}');
    }
    try w.writeAll("]}\n");
}

fn writeSamples(samples: []const Sample, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeByte('[');
    for (samples, 0..) |s, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("[{d:.3},{d:.3},{d:.3}]", .{ s.t, s.x, s.y });
    }
    try w.writeByte(']');
}

fn writeDurations(d: []const f64, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeByte('[');
    for (d, 0..) |x, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{d:.2}", .{x});
    }
    try w.writeByte(']');
}

/// Whether `name` is usable as an installed pack's file stem.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |ch| switch (ch) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '-' => {},
        else => return false,
    };
    return true;
}

const testing = std.testing;

const minimal_reach =
    \\{"format":"sketerm-motion","version":1,"header":{"device":"mouse","rate_hz":125},
    \\ "reaches":[{"start":[0,0],"target":[90,-10,20,20],"samples":[[0,0,0],[8,40,1],[16,100,0]],"down":30,"up":110,"land":[0.5,0.5]}]}
;

test "a minimal pack parses and round-trips through write" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    const p = try parse(arena.allocator(), minimal_reach, &diag);
    try testing.expectEqual(@as(usize, 1), p.reaches.len);
    try testing.expectEqual(Device.mouse, p.header.device);
    // A pack from before the clock field reads as device time.
    try testing.expectEqual(Clock.device, p.header.clock);
    try testing.expectApproxEqAbs(@as(f64, 100), p.reaches[0].distance(), 1e-9);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var arrival = p;
    arrival.header.clock = .arrival;
    try write(arrival, &out.writer);
    const again = try parse(arena.allocator(), out.written(), &diag);
    try testing.expectEqual(@as(usize, 3), again.reaches[0].samples.len);
    try testing.expectApproxEqAbs(@as(f64, 110), again.reaches[0].up, 1e-6);
    try testing.expectEqual(Clock.arrival, again.header.clock);
}

test "bad versions, truncated samples and broken timing are refused with a reason" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { json: []const u8, want: []const u8 }{
        .{ .json = "{\"format\":\"sketerm-motion\",\"version\":2,\"header\":{}}", .want = "unsupported pack version 2" },
        .{ .json = "{\"format\":\"other\",\"version\":1}", .want = "\"format\" is not" },
        .{ .json = "not json", .want = "not JSON" },
        .{ .json = "{\"format\":\"sketerm-motion\",\"version\":1,\"header\":{\"device\":\"mouse\",\"rate_hz\":125},\"reaches\":[{\"start\":[0,0],\"target\":[0,0,5,5],\"samples\":[[0,0,0],[8,40]],\"down\":10,\"up\":20,\"land\":[0.5,0.5]}]}", .want = "sample 1 is not [t, dx, dy]" },
        .{ .json = "{\"format\":\"sketerm-motion\",\"version\":1,\"header\":{\"device\":\"mouse\",\"rate_hz\":125},\"reaches\":[{\"start\":[0,0],\"target\":[0,0,5,5],\"samples\":[[0,0,0],[0,40,0]],\"down\":10,\"up\":20,\"land\":[0.5,0.5]}]}", .want = "not strictly increasing" },
        .{ .json = "{\"format\":\"sketerm-motion\",\"version\":1,\"header\":{\"device\":\"mouse\",\"rate_hz\":125},\"reaches\":[{\"start\":[0,0],\"target\":[0,0,5,5],\"samples\":[[0,0,0],[8,40,0]],\"down\":10,\"up\":10,\"land\":[0.5,0.5]}]}", .want = "release is not after the press" },
        .{ .json = "{\"format\":\"sketerm-motion\",\"version\":1,\"header\":{\"device\":\"trackball\",\"rate_hz\":125}}", .want = "unknown device class" },
        .{ .json = "{\"format\":\"sketerm-motion\",\"version\":1,\"header\":{\"device\":\"mouse\",\"rate_hz\":125}}", .want = "holds no reaches" },
        .{ .json = "{\"format\":\"sketerm-motion\",\"version\":1,\"header\":{\"device\":\"mouse\",\"rate_hz\":125,\"clock\":\"sundial\"}}", .want = "unknown clock" },
        .{ .json = "{\"format\":\"sketerm-motion\",\"version\":1,\"header\":{\"device\":\"mouse\",\"rate_hz\":125},\"keys\":{\"hold\":{\"thumb\":[80]}}}", .want = "unknown key class" },
        .{ .json = "{\"format\":\"sketerm-motion\",\"version\":1,\"header\":{\"device\":\"mouse\",\"rate_hz\":125},\"reaches\":[{\"start\":[0,0],\"target\":[0,0,5,5],\"samples\":[[0,0,0],[70000,40,0]],\"down\":70000,\"up\":70100,\"land\":[0.5,0.5]}]}", .want = "reach 0: the press came more than 60 s after the target appeared" },
        .{ .json = "{\"format\":\"sketerm-motion\",\"version\":1,\"header\":{\"device\":\"mouse\",\"rate_hz\":125},\"keys\":{\"hold\":{\"left\":[80,2500]}}}", .want = "entry 1 is outside 0..2000ms" },
        .{ .json = "{\"format\":\"sketerm-motion\",\"version\":1,\"header\":{\"device\":\"mouse\",\"rate_hz\":125},\"keys\":{\"hold\":{\"left\":[80]}},\"scroll\":[{\"events\":[[0,0,1],[70000,0,1]]}]}", .want = "scroll burst 0: event times are out of order" },
    };
    for (cases) |cs| {
        var diag: Diag = .{};
        try testing.expectError(error.Invalid, parse(a, cs.json, &diag));
        if (std.mem.indexOf(u8, diag.msg(), cs.want) == null) {
            std.debug.print("got \"{s}\", want \"{s}\"\n", .{ diag.msg(), cs.want });
            return error.TestUnexpectedResult;
        }
    }
}

test "key classes follow US hand positions, not letters" {
    try testing.expectEqual(KeyClass.left, KeyClass.of('a'));
    try testing.expectEqual(KeyClass.left, KeyClass.of('T'));
    try testing.expectEqual(KeyClass.right, KeyClass.of('j'));
    try testing.expectEqual(KeyClass.right, KeyClass.of('.'));
    try testing.expectEqual(KeyClass.space, KeyClass.of(' '));
    try testing.expectEqual(KeyClass.other, KeyClass.of(0xe9));
    try testing.expect(validName("my-mouse_1"));
    try testing.expect(!validName("../x"));
    try testing.expect(!validName(""));
}

test "an idle segment is replayable however far it wandered, but not when it never moved" {
    const far = [_]Sample{ .{ .t = 0, .x = 0, .y = 0 }, .{ .t = 400, .x = 310, .y = -120 }, .{ .t = 900, .x = 280, .y = 40 } };
    const still = [_]Sample{ .{ .t = 0, .x = 0, .y = 0 }, .{ .t = 4000, .x = 0.3, .y = 0.2 } };
    const lone = [_]Sample{.{ .t = 0, .x = 0, .y = 0 }};
    try testing.expect((Idle{ .samples = &far }).replayable());
    try testing.expect(!(Idle{ .samples = &still }).replayable());
    try testing.expect(!(Idle{ .samples = &lone }).replayable());
    try testing.expect(!(Idle{ .samples = &.{} }).replayable());
    const p: Pack = .{ .idle = &.{ .{ .samples = &far }, .{ .samples = &still }, .{ .samples = &far } } };
    try testing.expectEqual(@as(usize, 3), p.summary().idle);
    try testing.expectEqual(@as(usize, 2), p.summary().drift);
    try testing.expectEqual(@as(usize, 0), (Pack{}).summary().drift);
}
