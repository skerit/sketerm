//! Lightweight render-pipeline profiler. Off by default; enable by
//! launching sketerm with `SKETERM_PROFILE=1`. Records nanosecond
//! durations per labelled stage and flushes a one-line summary to
//! stderr roughly every second. Single-threaded by contract — every
//! call site lives on the GLib main thread.
//!
//! All hooks are wrapped in `if (profile.enabled)` so a normal build
//! pays only an atomic-bool load per call site.

const std = @import("std");

pub const Stage = enum(u8) {
    onrender_total,
    cell_rebuild,
    cell_rebuild_loop,
    cell_upload,
    cell_draw,
    grid_build,
    grid_draw,
    image_pass,
};

const N_STAGES = @typeInfo(Stage).@"enum".fields.len;

const Stats = struct {
    count: u64 = 0,
    total_ns: u64 = 0,
    min_ns: u64 = std.math.maxInt(u64),
    max_ns: u64 = 0,
};

pub var enabled: bool = false;

var stats: [N_STAGES]Stats = blk: {
    var s: [N_STAGES]Stats = undefined;
    for (&s) |*entry| entry.* = .{};
    break :blk s;
};
var last_flush_ns: i128 = 0;
const flush_interval_ns: i128 = 1_000_000_000;

/// Zig 0.16 removed `std.time.nanoTimestamp` and `std.posix.clock_gettime`;
/// the replacement (`Io.Clock.now`) requires an `Io` instance we don't
/// thread through every call site. We link libc, so just call clock_gettime
/// directly.
pub fn nanoTimestamp() i128 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
}

pub fn microTimestamp() i64 {
    return @intCast(@divTrunc(nanoTimestamp(), std.time.ns_per_us));
}

pub fn milliTimestamp() i64 {
    return @intCast(@divTrunc(nanoTimestamp(), std.time.ns_per_ms));
}

/// Zig 0.16 removed `std.posix.getenv`. We link libc, so just delegate
/// to the C runtime. Returns the same `?[]const u8` shape the old API
/// had so the existing `if (… getenv(name)) |v| …` patterns still work.
pub fn getenv(name: [*:0]const u8) ?[]const u8 {
    const c = @import("../c.zig").c;
    const raw = c.getenv(name);
    if (raw == null) return null;
    return std.mem.span(raw);
}

pub fn init() void {
    const c = @import("../c.zig").c;
    const raw = c.getenv("SKETERM_PROFILE");
    if (raw != null) {
        const v = std.mem.span(raw);
        enabled = std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true");
    }
    if (enabled) {
        last_flush_ns = nanoTimestamp();
        std.debug.print("sketerm-profile: enabled (flush interval 1s)\n", .{});
    }
}

pub fn record(stage: Stage, ns: u64) void {
    if (!enabled) return;
    const i: usize = @intFromEnum(stage);
    var s = &stats[i];
    s.count += 1;
    s.total_ns += ns;
    if (ns < s.min_ns) s.min_ns = ns;
    if (ns > s.max_ns) s.max_ns = ns;

    const now = nanoTimestamp();
    if (now - last_flush_ns >= flush_interval_ns) {
        flush();
        last_flush_ns = now;
    }
}

fn flush() void {
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    w.writeAll("sketerm-profile:") catch return;

    const fields = @typeInfo(Stage).@"enum".fields;
    inline for (fields) |f| {
        const s = &stats[f.value];
        if (s.count > 0) {
            const avg_us: f64 = @as(f64, @floatFromInt(s.total_ns)) / @as(f64, @floatFromInt(s.count)) / 1000.0;
            const max_us: f64 = @as(f64, @floatFromInt(s.max_ns)) / 1000.0;
            const total_us: f64 = @as(f64, @floatFromInt(s.total_ns)) / 1000.0;
            w.print(" {s} x{d} avg={d:.1}us max={d:.1}us total={d:.1}us |",
                .{ f.name, s.count, avg_us, max_us, total_us }) catch {};
            s.* = .{};
        }
    }
    std.debug.print("{s}\n", .{w.buffered()});
}
