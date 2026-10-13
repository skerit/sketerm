//! A SYNTHETIC motion pack for tests: minimum-jerk reaches with curvature,
//! Fitts-shaped timing, key and wheel distributions, generated from a
//! seed. Never a person's motion, and never shipped as a pack; the unit
//! tests, smoke-web and smoke-mcp write one where a test needs a pack.

const std = @import("std");
const pack_mod = @import("pack.zig");

pub const Options = struct {
    seed: u64 = 1,
    rate_hz: f64 = 125,
    /// Reaches per (distance, direction, size) cell.
    per_cell: usize = 1,
};

const distances = [_]f64{ 60, 140, 300, 600 };
const sizes = [_]f64{ 12, 30, 70 };
const directions = 8;

/// The pack as version-1 JSON, allocated in `gpa`.
pub fn generate(gpa: std.mem.Allocator, opts: Options) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var prng = std.Random.DefaultPrng.init(opts.seed);
    const rng = prng.random();
    const dt = 1000 / opts.rate_hz;

    var reaches: std.ArrayList(pack_mod.Reach) = .empty;
    for (distances) |d| for (sizes) |w| for (0..directions) |dir| for (0..opts.per_cell) |_| {
        const theta = @as(f64, @floatFromInt(dir)) * std.math.pi / 4 + (rng.float(f64) - 0.5) * 0.3;
        const u = 0.3 + 0.4 * rng.float(f64);
        const v = 0.3 + 0.4 * rng.float(f64);
        const start = [2]f64{ 500, 400 };
        const cx = start[0] + d * @cos(theta);
        const cy = start[1] + d * @sin(theta);
        const target = [4]f64{ cx - w / 2, cy - w / 2, w, w };
        const end = [2]f64{ target[0] + u * w - start[0], target[1] + v * w - start[1] };
        const mt = (130 + 120 * std.math.log2(d / w + 1)) * (0.9 + 0.2 * rng.float(f64));
        const react = 150 + 80 * rng.float(f64);
        const bend = (rng.float(f64) - 0.5) * 0.12;
        var samples: std.ArrayList(pack_mod.Sample) = .empty;
        try samples.append(a, .{ .t = react - dt, .x = 0, .y = 0 });
        var t: f64 = 0;
        while (t < mt) : (t += dt * (0.9 + 0.2 * rng.float(f64))) {
            const tau = t / mt;
            const s = 10 * std.math.pow(f64, tau, 3) - 15 * std.math.pow(f64, tau, 4) + 6 * std.math.pow(f64, tau, 5);
            const off = bend * d * @sin(std.math.pi * tau);
            const len = std.math.hypot(end[0], end[1]);
            try samples.append(a, .{
                .t = react + t,
                .x = end[0] * s - end[1] / len * off,
                .y = end[1] * s + end[0] / len * off,
            });
        }
        try samples.append(a, .{ .t = react + mt, .x = end[0], .y = end[1] });
        const down = react + mt + 30 + 60 * rng.float(f64);
        try reaches.append(a, .{
            .start = start,
            .target = target,
            .samples = samples.items,
            .down = down,
            .up = down + 70 + 60 * rng.float(f64),
            .land = .{ u, v },
        });
    };

    var keys: pack_mod.Keys = .{};
    for (&keys.hold) |*h| h.* = try normals(a, rng, 40, 95, 20, 30);
    for (&keys.flight) |*row| for (row) |*f| {
        f.* = try normals(a, rng, 20, 175, 50, 45);
    };

    var bursts: std.ArrayList(pack_mod.Burst) = .empty;
    for (0..12) |i| {
        const n = 4 + rng.uintLessThan(usize, 5);
        const events = try a.alloc(pack_mod.Wheel, n);
        var t: f64 = 0;
        const sign: f64 = if (i % 4 == 3) -1 else 1;
        for (events, 0..) |*e, k| {
            const decay = 42 * std.math.pow(f64, 0.75, @floatFromInt(k));
            e.* = .{ .t = t, .dx = 0, .dy = sign * @max(decay, 3) };
            t += 12 + 6 * rng.float(f64);
        }
        try bursts.append(a, .{ .smooth = true, .events = events });
    }

    var idle: std.ArrayList(pack_mod.Idle) = .empty;
    for (0..3) |_| {
        const samples = try a.alloc(pack_mod.Sample, 20);
        var x: f64 = 0;
        var y: f64 = 0;
        for (samples, 0..) |*s, k| {
            x += (rng.float(f64) - 0.5) * 2.4;
            y += (rng.float(f64) - 0.5) * 2.4;
            s.* = .{ .t = @as(f64, @floatFromInt(k)) * 40, .x = x, .y = y };
        }
        try idle.append(a, .{ .samples = samples });
    }

    const p: pack_mod.Pack = .{
        .header = .{ .device = .mouse, .rate_hz = opts.rate_hz, .scale = 1, .recorder = "sketerm synthetic test pack", .created = "1970-01-01T00:00:00Z" },
        .reaches = reaches.items,
        .keys = keys,
        .scroll = bursts.items,
        .idle = idle.items,
    };
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try pack_mod.write(p, &out.writer);
    return out.toOwnedSlice();
}

fn normals(a: std.mem.Allocator, rng: std.Random, n: usize, mean: f64, sd: f64, floor: f64) ![]f64 {
    const out = try a.alloc(f64, n);
    for (out) |*x| x.* = @max(mean + rng.floatNorm(f64) * sd, floor);
    return out;
}

test "the synthetic pack validates and covers every cell" {
    const bytes = try generate(std.testing.allocator, .{ .seed = 42 });
    defer std.testing.allocator.free(bytes);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diag: pack_mod.Diag = .{};
    const p = pack_mod.parse(arena.allocator(), bytes, &diag) catch |err| {
        std.debug.print("synthetic pack refused: {s}\n", .{diag.msg()});
        return err;
    };
    try std.testing.expectEqual(distances.len * sizes.len * directions, p.reaches.len);
    try std.testing.expect(p.keys.holdCount() > 0);
    try std.testing.expectEqual(@as(usize, 12), p.scroll.len);
}
