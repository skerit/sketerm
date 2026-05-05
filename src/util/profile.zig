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

pub fn init() void {
    if (std.posix.getenv("SKETERM_PROFILE")) |v| {
        enabled = std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true");
    }
    if (enabled) {
        last_flush_ns = std.time.nanoTimestamp();
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

    const now = std.time.nanoTimestamp();
    if (now - last_flush_ns >= flush_interval_ns) {
        flush();
        last_flush_ns = now;
    }
}

fn flush() void {
    var buf: [1024]u8 = undefined;
    var w = std.io.fixedBufferStream(&buf);
    const writer = w.writer();
    writer.writeAll("sketerm-profile:") catch return;

    const fields = @typeInfo(Stage).@"enum".fields;
    inline for (fields) |f| {
        const s = &stats[f.value];
        if (s.count > 0) {
            const avg_us: f64 = @as(f64, @floatFromInt(s.total_ns)) / @as(f64, @floatFromInt(s.count)) / 1000.0;
            const max_us: f64 = @as(f64, @floatFromInt(s.max_ns)) / 1000.0;
            const total_us: f64 = @as(f64, @floatFromInt(s.total_ns)) / 1000.0;
            writer.print(" {s} x{d} avg={d:.1}us max={d:.1}us total={d:.1}us |",
                .{ f.name, s.count, avg_us, max_us, total_us }) catch {};
            s.* = .{};
        }
    }
    std.debug.print("{s}\n", .{w.getWritten()});
}
