//! `web_perf`'s fixed-shape report: the difference of two `Performance.getMetrics` samples.
//!
//! `Report`'s fields ARE the tool's key vocabulary: the output schema is
//! generated from them, so a key cannot exist in one place only.

const std = @import("std");
const reflect = @import("../../util/reflect.zig");

/// One `getMetrics` sample plus the helper's paint counter.
pub const Sample = struct {
    /// Seconds, monotonic.
    timestamp_s: f64 = 0,
    script_s: f64 = 0,
    style_s: f64 = 0,
    style_count: i64 = 0,
    layout_s: f64 = 0,
    layout_count: i64 = 0,
    task_s: f64 = 0,
    nodes: i64 = 0,
    heap_used: i64 = 0,
    listeners: i64 = 0,
    paints: u32 = 0,
};

pub const Report = struct {
    /// True on a tab's first call: the numbers are cumulative since the agent attached and window_ms is 0.
    baseline: bool,
    window_ms: f64,
    script_ms: f64,
    style_ms: f64,
    style_count: i64,
    layout_ms: f64,
    layout_count: i64,
    task_ms: f64,
    main_thread_busy_pct: f64,
    dom_nodes: i64,
    dom_nodes_delta: i64,
    js_heap_used_bytes: i64,
    js_heap_delta_bytes: i64,
    event_listeners: i64,
    /// Paints the helper counted for the view; null on a baseline.
    frames: ?i64,
    fps: ?f64,
    cpu_throttle: f64,
};

/// The report keys, in output order.
pub const KEYS = blk: {
    const fs = reflect.fields(Report);
    var out: [fs.len][]const u8 = undefined;
    for (fs, 0..) |f, i| out[i] = f.name;
    const final = out;
    break :blk final;
};

/// Read a `Performance.getMetrics` result (`{"metrics":[{name,value}]}`).
pub fn parseSample(arena: std.mem.Allocator, json: []const u8, paints: u32) !Sample {
    const Metric = struct { name: []const u8, value: f64 };
    const parsed = std.json.parseFromSliceLeaky(struct { metrics: []const Metric }, arena, json, .{ .ignore_unknown_fields = true }) catch return error.BadMetrics;
    var s: Sample = .{ .paints = paints };
    for (parsed.metrics) |m| {
        const eq = std.mem.eql;
        const i: i64 = if (std.math.isFinite(m.value)) @intFromFloat(m.value) else 0;
        if (eq(u8, m.name, "Timestamp")) s.timestamp_s = m.value;
        if (eq(u8, m.name, "ScriptDuration")) s.script_s = m.value;
        if (eq(u8, m.name, "RecalcStyleDuration")) s.style_s = m.value;
        if (eq(u8, m.name, "RecalcStyleCount")) s.style_count = i;
        if (eq(u8, m.name, "LayoutDuration")) s.layout_s = m.value;
        if (eq(u8, m.name, "LayoutCount")) s.layout_count = i;
        if (eq(u8, m.name, "TaskDuration")) s.task_s = m.value;
        if (eq(u8, m.name, "Nodes")) s.nodes = i;
        if (eq(u8, m.name, "JSHeapUsedSize")) s.heap_used = i;
        if (eq(u8, m.name, "JSEventListeners")) s.listeners = i;
    }
    if (s.timestamp_s == 0) return error.BadMetrics;
    return s;
}

fn ms(seconds: f64) f64 {
    return @round(seconds * 1_000_000) / 1000;
}

/// `now` minus `before` (null: a baseline of everything since attach).
pub fn report(before: ?Sample, now: Sample, cpu_throttle: f64) Report {
    const b = before orelse Sample{ .timestamp_s = now.timestamp_s };
    const window = ms(now.timestamp_s - b.timestamp_s);
    const task = ms(now.task_s - b.task_s);
    const frames: ?i64 = if (before != null) @as(i64, now.paints -% b.paints) else null;
    return .{
        .baseline = before == null,
        .window_ms = window,
        .script_ms = ms(now.script_s - b.script_s),
        .style_ms = ms(now.style_s - b.style_s),
        .style_count = now.style_count - b.style_count,
        .layout_ms = ms(now.layout_s - b.layout_s),
        .layout_count = now.layout_count - b.layout_count,
        .task_ms = task,
        .main_thread_busy_pct = if (window > 0) @round(@min(task / window, 1) * 1000) / 10 else 0,
        .dom_nodes = now.nodes,
        .dom_nodes_delta = now.nodes - b.nodes,
        .js_heap_used_bytes = now.heap_used,
        .js_heap_delta_bytes = now.heap_used - b.heap_used,
        .event_listeners = now.listeners,
        .frames = frames,
        .fps = if (frames) |f| (if (window > 0) @round(@as(f64, @floatFromInt(f)) * 10_000 / window) / 10 else null) else null,
        .cpu_throttle = cpu_throttle,
    };
}

test "two samples give one fixed-shape delta, a first call a baseline" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a = try parseSample(arena,
        \\{"metrics":[{"name":"Timestamp","value":100.0},{"name":"LayoutCount","value":3},{"name":"LayoutDuration","value":0.01},{"name":"TaskDuration","value":0.5},{"name":"Nodes","value":40},{"name":"JSHeapUsedSize","value":1000},{"name":"Other","value":1}]}
    , 10);
    const b = try parseSample(arena,
        \\{"metrics":[{"name":"Timestamp","value":102.0},{"name":"LayoutCount","value":13},{"name":"LayoutDuration","value":0.03},{"name":"TaskDuration","value":1.5},{"name":"Nodes","value":140},{"name":"JSHeapUsedSize","value":900},{"name":"JSEventListeners","value":7}]}
    , 130);
    const r = report(a, b, 4);
    try std.testing.expect(!r.baseline);
    try std.testing.expectEqual(@as(f64, 2000), r.window_ms);
    try std.testing.expectEqual(@as(i64, 10), r.layout_count);
    try std.testing.expectEqual(@as(f64, 20), r.layout_ms);
    try std.testing.expectEqual(@as(f64, 50), r.main_thread_busy_pct);
    try std.testing.expectEqual(@as(i64, 100), r.dom_nodes_delta);
    try std.testing.expectEqual(@as(i64, -100), r.js_heap_delta_bytes);
    try std.testing.expectEqual(@as(?i64, 120), r.frames);
    try std.testing.expectEqual(@as(?f64, 60), r.fps);
    try std.testing.expectEqual(@as(f64, 4), r.cpu_throttle);
    const first = report(null, b, 1);
    try std.testing.expect(first.baseline);
    try std.testing.expectEqual(@as(i64, 13), first.layout_count);
    try std.testing.expect(first.frames == null and first.fps == null);
    try std.testing.expectEqualStrings("baseline", KEYS[0]);
    try std.testing.expectEqualStrings("cpu_throttle", KEYS[KEYS.len - 1]);
    try std.testing.expectError(error.BadMetrics, parseSample(arena, "{\"metrics\":[]}", 0));
}
