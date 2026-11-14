//! `web_perf`, `web_cpu_profile` and `web_trace`: page performance through the view's DevTools session (helper capabilities `web-perf`, `web-trace`).
//!
//! Headless only, like emulation: the GUI's tabs answer `unavailable`. A raw
//! profile or trace reaches this process as a STAGED helper file, never a
//! frame, and is summarized here; a helper on another host is refused because
//! its staging file is on that host.

const std = @import("std");
const mcp = @import("mcp.zig");
const web = @import("mcp_web.zig");
const webdrive = @import("webdrive.zig");
const web_proto = @import("../web/protocol.zig");
const clock = @import("../util/clock.zig");
const reflect = @import("../util/reflect.zig");
const readfile = @import("../util/readfile.zig");
const c = @import("../c.zig").c;
const metrics = @import("perf/metrics.zig");
const cpuprofile = @import("perf/cpuprofile.zig");
const sourcemap = @import("perf/sourcemap.zig");
const trace = @import("perf/trace.zig");

pub const MAX_PERF_WINDOW_MS: i64 = 60_000;
pub const MAX_PROFILE_MS: i64 = 120_000;
pub const DEFAULT_INTERVAL_US: i64 = 1000;
pub const DEFAULT_TOP: i64 = 20;
pub const MAX_TOP: i64 = 100;
/// Largest profile file this process reads back for the summary.
const PROFILE_READ_CAP: usize = 512 * 1024 * 1024;
/// Largest source map fetched through the page (an eval result's string budget).
const MAP_FETCH_CAP: u32 = web_proto.MAX_EVAL_STR;

/// The previous `web_perf` sample per tab, so a call without a window reports since the last one.
const Last = struct { engine: usize, pane: u32, sample: metrics.Sample };
var last_samples: [32]?Last = @splat(null);
var last_next: usize = 0;

fn lastFor(e: *webdrive.Engine, pane: u32) ?*Last {
    for (&last_samples) |*slot| if (slot.*) |*l| if (l.engine == @intFromPtr(e) and l.pane == pane) return l;
    return null;
}

fn remember(e: *webdrive.Engine, pane: u32, s: metrics.Sample) void {
    if (lastFor(e, pane)) |l| {
        l.sample = s;
        return;
    }
    last_samples[last_next] = .{ .engine = @intFromPtr(e), .pane = pane, .sample = s };
    last_next = (last_next + 1) % last_samples.len;
}

pub fn tool(drv: web.Driver, arena: std.mem.Allocator, name: []const u8, args: std.json.Value, view: web.View) ![]const u8 {
    const e = switch (drv) {
        .gui => return mcp.errRes(arena, .unavailable, try std.fmt.allocPrint(arena, "{s} is headless only: a tab of the sketerm GUI has no DevTools session this server may attach to", .{name})),
        .headless => |engine| engine,
    };
    const needed: web_proto.Cap = if (std.mem.eql(u8, name, "web_trace")) .web_trace else .web_perf;
    if (!e.has(needed)) return mcp.errRes(arena, .unavailable, if (needed == .web_trace)
        "this browser helper predates web-trace (capabilities web_trace), so it cannot trace the page; nothing was traced"
    else
        "this browser helper predates web-perf (capabilities web_perf), so it cannot measure the page; nothing was measured");
    if (mcp.argValue(args, "cpu_throttle")) |v| {
        const rate: f64 = switch (v) {
            .integer => |n| @floatFromInt(n),
            .float => |n| n,
            else => return mcp.errRes(arena, .invalid_args, "cpu_throttle must be a number from 1 (off) through 20"),
        };
        if (!std.math.isFinite(rate) or rate < 1 or rate > 20) return mcp.errRes(arena, .invalid_args, "cpu_throttle must be a number from 1 (off) through 20");
        switch (try perfOp(drv, arena, e, view.pane, .throttle, @intFromFloat(@round(rate * 100)), 0, 10_000, null)) {
            .err => |r| return r,
            .ok => {},
        }
    }
    if (std.mem.eql(u8, name, "web_perf")) return perfTool(drv, arena, e, args, view);
    if (std.mem.eql(u8, name, "web_trace")) return traceTool(drv, arena, e, args, view);
    return profileTool(drv, arena, e, args, view);
}

const Done = struct { text: []const u8, staged: []const u8, throttle: u32, paints: u32, navigations: u32 };
const PerfResult = union(enum) { ok: Done, err: []const u8 };

/// Run one perf op to its answer; `deliver_to` moves a staged result there before the record is dropped.
fn perfOp(drv: web.Driver, arena: std.mem.Allocator, e: *webdrive.Engine, pane: u32, op: web_proto.PerfOp, arg: u32, limit_ms: u32, timeout_ms: i64, deliver_to: ?[]const u8) !PerfResult {
    const req = e.startPerf(pane, op, arg, limit_ms) catch |err| return .{ .err = switch (err) {
        error.Unsupported => try mcp.errRes(arena, .unavailable, if (op.capability() == .web_trace) "this browser helper predates web-trace" else "this browser helper predates web-perf"),
        else => try web.failRes(arena, try web.headlessFail(arena, e, err)),
    } };
    defer e.takePerf(req);
    const deadline = clock.nowMs() + timeout_ms;
    while (e.perfState(req)) |p| {
        if (p.state != .pending) break;
        if (clock.nowMs() >= deadline)
            return .{ .err = try mcp.errRes(arena, .timeout, "the browser helper did not answer the perf request in time") };
        drv.sleep(web.POLL_MS);
    } else return .{ .err = try mcp.errRes(arena, .unavailable, "the perf request was lost with the browser helper") };
    const p = e.perfState(req).?;
    if (p.state == .failed) return .{ .err = try mcp.errRes(arena, .failed, try arena.dupe(u8, if (p.text.len != 0) p.text else "the browser engine refused the perf request")) };
    if (deliver_to) |dest| {
        if (p.staged.len == 0) return .{ .err = try mcp.errRes(arena, .failed, "the helper named no staged profile file") };
        if (e.deliverStaged(p.staged, dest)) |why| return .{ .err = try mcp.errRes(arena, .io_failed, why) };
    }
    return .{ .ok = .{ .text = try arena.dupe(u8, p.text), .staged = try arena.dupe(u8, p.staged), .throttle = p.throttle, .paints = p.paints, .navigations = p.navigations } };
}

fn throttleOf(x100: u32) f64 {
    return @as(f64, @floatFromInt(x100)) / 100;
}

/// Sleep `ms` while the engine keeps pumping; false when the caller hung up.
fn wait(drv: web.Driver, ms: i64) void {
    const until = clock.nowMs() + ms;
    while (clock.nowMs() < until) drv.sleep(@intCast(@min(@max(until - clock.nowMs(), 1), 200)));
}

// ---------------------------------------------------------------------
// web_perf
// ---------------------------------------------------------------------

fn sample(drv: web.Driver, arena: std.mem.Allocator, e: *webdrive.Engine, pane: u32) !union(enum) { ok: struct { s: metrics.Sample, throttle: u32 }, err: []const u8 } {
    const d = switch (try perfOp(drv, arena, e, pane, .metrics, 0, 0, 10_000, null)) {
        .err => |r| return .{ .err = r },
        .ok => |d| d,
    };
    const s = metrics.parseSample(arena, d.text, d.paints) catch
        return .{ .err = try mcp.errRes(arena, .failed, try std.fmt.allocPrint(arena, "the engine answered Performance.getMetrics with no usable metrics: {s}", .{d.text[0..@min(d.text.len, 300)]})) };
    return .{ .ok = .{ .s = s, .throttle = d.throttle } };
}

fn perfTool(drv: web.Driver, arena: std.mem.Allocator, e: *webdrive.Engine, args: std.json.Value, view: web.View) ![]const u8 {
    const duration = mcp.argInt(args, "duration_ms");
    if (duration) |d| if (d < 1 or d > MAX_PERF_WINDOW_MS) return mcp.errRes(arena, .invalid_args, "duration_ms must be from 1 through 60000");
    var before: ?metrics.Sample = if (lastFor(e, view.pane)) |l| l.sample else null;
    if (duration) |d| {
        before = switch (try sample(drv, arena, e, view.pane)) {
            .err => |r| return r,
            .ok => |s| s.s,
        };
        wait(drv, d);
    }
    const now = switch (try sample(drv, arena, e, view.pane)) {
        .err => |r| return r,
        .ok => |s| s,
    };
    remember(e, view.pane, now.s);
    const r = metrics.report(before, now.s, throttleOf(now.throttle));

    var res = mcp.Res.init(arena);
    try web.head(&res, arena, drv.mode(), view);
    inline for (reflect.fields(metrics.Report)) |f| try res.fact(f.name, @field(r, f.name));
    if (r.baseline)
        try res.textf("baseline (first web_perf on this tab): totals since the DevTools agent attached; the next call reports the window since this one. dom {d} nodes, heap {d} B, {d} listeners, cpu_throttle {d}x", .{ r.dom_nodes, r.js_heap_used_bytes, r.event_listeners, r.cpu_throttle })
    else
        try res.textf("window {d}ms: busy {d}% (tasks {d}ms), script {d}ms, layout {d}x {d}ms, style {d}x {d}ms, dom {d} nodes (delta {d}), heap {d} B (delta {d}), {d} listeners, frames {?d} fps {?d}, cpu_throttle {d}x", .{
            r.window_ms,       r.main_thread_busy_pct, r.task_ms,   r.script_ms,       r.layout_count,       r.layout_ms,
            r.style_count,     r.style_ms,             r.dom_nodes, r.dom_nodes_delta, r.js_heap_used_bytes, r.js_heap_delta_bytes,
            r.event_listeners, r.frames,               r.fps,       r.cpu_throttle,
        });
    return res.finish();
}

// ---------------------------------------------------------------------
// web_cpu_profile
// ---------------------------------------------------------------------

/// The start/stop/one-shot arguments both recording tools share.
const Recording = struct {
    duration: ?i64,
    starting: bool,
    stopping: bool,
    top: usize,
    /// Where the raw file goes on a stop; empty on a start.
    save: []const u8,

    fn parse(arena: std.mem.Allocator, args: std.json.Value, comptime tool_name: []const u8, comptime max_ms: i64, comptime default_top: i64, comptime max_top: i64, comptime ext: []const u8) !union(enum) { ok: Recording, err: []const u8 } {
        const action = mcp.argStr(args, "action");
        const duration = mcp.argInt(args, "duration_ms");
        if ((action == null) == (duration == null))
            return .{ .err = try mcp.errRes(arena, .invalid_args, tool_name ++ " needs either action:\"start\"|\"stop\" or duration_ms for a one-shot") };
        if (action) |a| if (!std.mem.eql(u8, a, "start") and !std.mem.eql(u8, a, "stop"))
            return .{ .err = try mcp.errRes(arena, .invalid_args, "action must be start or stop") };
        if (duration) |d| if (d < 1 or d > max_ms) return .{ .err = try mcp.errRes(arena, .invalid_args, std.fmt.comptimePrint("duration_ms must be from 1 through {d}", .{max_ms})) };
        const top = mcp.argInt(args, "top") orelse default_top;
        if (top < 1 or top > max_top) return .{ .err = try mcp.errRes(arena, .invalid_args, std.fmt.comptimePrint("top must be from 1 through {d}", .{max_top})) };
        var out: Recording = .{
            .duration = duration,
            .starting = duration != null or std.mem.eql(u8, action.?, "start"),
            .stopping = duration != null or std.mem.eql(u8, action.?, "stop"),
            .top = @intCast(top),
            .save = "",
        };
        if (out.stopping) {
            out.save = mcp.argStr(args, "save") orelse try tempPath(arena, ext);
            if (out.save.len == 0 or out.save[0] != '/') return .{ .err = try mcp.errRes(arena, .invalid_args, "'save' must be an absolute file path") };
        }
        return .{ .ok = out };
    }
};

fn profileTool(drv: web.Driver, arena: std.mem.Allocator, e: *webdrive.Engine, args: std.json.Value, view: web.View) ![]const u8 {
    const rec = switch (try Recording.parse(arena, args, "web_cpu_profile", MAX_PROFILE_MS, DEFAULT_TOP, MAX_TOP, "cpuprofile")) {
        .err => |r| return r,
        .ok => |r| r,
    };
    const duration = rec.duration;
    const interval = mcp.argInt(args, "interval_us") orelse DEFAULT_INTERVAL_US;
    if (interval < web_proto.PERF_INTERVAL_MIN_US or interval > 1_000_000) return mcp.errRes(arena, .invalid_args, "interval_us must be from 100 through 1000000");
    // The profile is staged on the helper's host and moved here.
    if (e.route_kind == .remote_browser)
        return mcp.errRes(arena, .unavailable, "this view's browser runs on another host, where its profile would be staged; web_cpu_profile profiles views of a local browser helper (web_perf works there)");
    const save = rec.save;
    const top: i64 = @intCast(rec.top);
    if (rec.starting) {
        const limit: u32 = @intCast(if (duration) |d| @min(d + 5_000, MAX_PROFILE_MS) else MAX_PROFILE_MS);
        const started = switch (try perfOp(drv, arena, e, view.pane, .profile_start, @intCast(interval), limit, 10_000, null)) {
            .err => |r| return r,
            .ok => |d| d,
        };
        if (duration == null) {
            var res = mcp.Res.init(arena);
            try web.head(&res, arena, drv.mode(), view);
            try res.fact("profiling", true);
            try res.fact("interval_us", interval);
            try res.fact("max_duration_ms", MAX_PROFILE_MS);
            try res.fact("cpu_throttle", throttleOf(started.throttle));
            try res.textf("CPU profile started (sampling every {d}us, cpu_throttle {d}x); it stops by itself after {d}s. Stop it with web_cpu_profile action:\"stop\"", .{ interval, throttleOf(started.throttle), @divTrunc(MAX_PROFILE_MS, 1000) });
            return res.finish();
        }
        wait(drv, duration.?);
    }
    const done = switch (try perfOp(drv, arena, e, view.pane, .profile_stop, 0, 0, 90_000, save)) {
        .err => |r| return r,
        .ok => |d| d,
    };
    const json = readfile.cappedAlloc(arena, save, PROFILE_READ_CAP) catch
        return mcp.errRes(arena, .io_failed, try std.fmt.allocPrint(arena, "the profile was saved to {s} but could not be read back for the summary", .{save}));
    const sum = cpuprofile.summarize(arena, json) catch
        return mcp.errRes(arena, .failed, try std.fmt.allocPrint(arena, "the engine's profile at {s} is not a readable .cpuprofile", .{save}));
    if (sum.sample_count == 0)
        return mcp.errRes(arena, .failed, try std.fmt.allocPrint(arena, "the profile at {s} holds no samples{s}", .{ save, if (done.navigations != 0) " (the page navigated while profiling; a renderer swap ends a profile)" else "" }));
    // A stop knows nothing of the start's interval; the profile's own mean is the honest figure.
    return summaryResult(drv, arena, args, view, sum, done, save, @intCast(top), if (duration != null) interval else @intCast(sum.interval_us));
}

/// A fresh temp file name with extension `ext`.
fn tempPath(arena: std.mem.Allocator, comptime ext: []const u8) ![]const u8 {
    const dir: []const u8 = if (c.getenv("TMPDIR")) |t| std.mem.span(t) else "/tmp";
    var rnd: [4]u8 = undefined;
    _ = c.getentropy(&rnd, rnd.len);
    return std.fmt.allocPrint(arena, "{s}/sketerm-{d}-{x}." ++ ext, .{ if (dir.len > 0 and dir[0] == '/') dir else "/tmp", clock.wallMs(), std.mem.readInt(u32, &rnd, .little) });
}

// ---------------------------------------------------------------------
// web_trace
// ---------------------------------------------------------------------

pub const MAX_TRACE_MS: i64 = 30_000;
pub const DEFAULT_TRACE_TOP: i64 = 10;
pub const MAX_TRACE_TOP: i64 = 50;

fn traceTool(drv: web.Driver, arena: std.mem.Allocator, e: *webdrive.Engine, args: std.json.Value, view: web.View) ![]const u8 {
    const rec = switch (try Recording.parse(arena, args, "web_trace", MAX_TRACE_MS, DEFAULT_TRACE_TOP, MAX_TRACE_TOP, "trace.json")) {
        .err => |r| return r,
        .ok => |r| r,
    };
    const selector_stats = if (mcp.argValue(args, "selector_stats")) |v| v == .bool and v.bool else false;
    if (e.route_kind == .remote_browser)
        return mcp.errRes(arena, .unavailable, "this view's browser runs on another host, where its trace would be staged; web_trace traces views of a local browser helper (web_perf works there)");
    if (rec.starting) {
        const limit: u32 = @intCast(if (rec.duration) |d| @min(d + 5_000, MAX_TRACE_MS) else MAX_TRACE_MS);
        const started = switch (try perfOp(drv, arena, e, view.pane, .trace_start, if (selector_stats) web_proto.TRACE_SELECTOR_STATS else 0, limit, 15_000, null)) {
            .err => |r| return r,
            .ok => |d| d,
        };
        if (rec.duration == null) {
            var res = mcp.Res.init(arena);
            try web.head(&res, arena, drv.mode(), view);
            try res.fact("tracing", true);
            try res.fact("selector_stats_requested", selector_stats);
            try res.fact("max_duration_ms", MAX_TRACE_MS);
            try res.fact("cpu_throttle", throttleOf(started.throttle));
            try res.textf("trace started (cpu_throttle {d}x{s}); it ends by itself after {d}s. Stop it with web_trace action:\"stop\"", .{ throttleOf(started.throttle), if (selector_stats) ", selector stats" else "", @divTrunc(MAX_TRACE_MS, 1000) });
            return res.finish();
        }
        wait(drv, rec.duration.?);
    }
    const done = switch (try perfOp(drv, arena, e, view.pane, .trace_stop, 0, 0, 90_000, rec.save)) {
        .err => |r| return r,
        .ok => |d| d,
    };
    const stop = std.json.parseFromSliceLeaky(web_proto.TraceStop, arena, done.text, .{ .ignore_unknown_fields = true }) catch web_proto.TraceStop{};
    var file = FileSource.open(rec.save) orelse
        return mcp.errRes(arena, .io_failed, try std.fmt.allocPrint(arena, "the trace was saved to {s} but could not be read back for the summary", .{rec.save}));
    defer file.close();
    const sum = trace.summarize(arena, file.source(), rec.top) catch |err| return mcp.errRes(arena, .failed, try std.fmt.allocPrint(arena, "the trace at {s} could not be summarized: {s}", .{ rec.save, @errorName(err) }));
    return traceResult(drv, arena, args, view, sum, done, stop, rec.save);
}

/// A file read through libc, rewindable for the summarizer's two passes.
const FileSource = struct {
    fp: *c.FILE,

    fn open(path: []const u8) ?FileSource {
        var z: [4096:0]u8 = undefined;
        const p = std.fmt.bufPrintSentinel(&z, "{s}", .{path}, 0) catch return null;
        return .{ .fp = c.fopen(p.ptr, "rb") orelse return null };
    }

    fn close(self: *FileSource) void {
        _ = c.fclose(self.fp);
    }

    fn source(self: *FileSource) trace.Source {
        return .{ .ctx = self, .readFn = read, .rewindFn = rewind };
    }

    fn read(ctx: *anyopaque, buf: []u8) error{ReadFailed}!usize {
        const self: *FileSource = @ptrCast(@alignCast(ctx));
        const n = c.fread(buf.ptr, 1, buf.len, self.fp);
        if (n == 0 and c.ferror(self.fp) != 0) return error.ReadFailed;
        return n;
    }

    fn rewind(ctx: *anyopaque) error{ReadFailed}!void {
        const self: *FileSource = @ptrCast(@alignCast(ctx));
        if (c.fseek(self.fp, 0, c.SEEK_SET) != 0) return error.ReadFailed;
    }
};

/// A JS location in a trace list, flat so source-map resolution and the schema read it like `TopFn`.
pub const TraceReflow = struct {
    function: []const u8,
    url: []const u8,
    line: u32,
    column: u32,
    count: u32,
    total_ms: f64,
    style_count: u32,
    layout_count: u32,
    source: ?[]const u8 = null,
    source_line: ?u32 = null,
    source_name: ?[]const u8 = null,
};

pub const TraceLongTask = struct {
    start_ms: f64,
    duration_ms: f64,
    cause: trace.Cause,
    /// The heaviest JS entry when the cause is script; empty otherwise.
    function: []const u8 = "",
    url: []const u8 = "",
    line: u32 = 0,
    column: u32 = 0,
    source: ?[]const u8 = null,
    source_line: ?u32 = null,
    source_name: ?[]const u8 = null,
};

fn shownName(f: []const u8) []const u8 {
    return if (f.len != 0) f else "(anonymous)";
}

fn traceResult(drv: web.Driver, arena: std.mem.Allocator, args: std.json.Value, view: web.View, sum: trace.Summary, done: Done, stop: web_proto.TraceStop, save: []const u8) ![]const u8 {
    const reflows = try arena.alloc(TraceReflow, sum.forced_reflows.top.len);
    for (sum.forced_reflows.top, reflows) |r, *o| o.* = .{
        .function = shownName(r.frame.function),
        .url = r.frame.url,
        .line = r.frame.line,
        .column = r.frame.column,
        .count = r.count,
        .total_ms = r.total_ms,
        .style_count = r.style_count,
        .layout_count = r.layout_count,
    };
    const longs = try arena.alloc(TraceLongTask, sum.long_tasks.top.len);
    for (sum.long_tasks.top, longs) |l, *o| {
        o.* = .{ .start_ms = l.start_ms, .duration_ms = l.duration_ms, .cause = l.cause };
        if (l.frame) |f| {
            o.function = shownName(f.function);
            o.url = f.url;
            o.line = f.line;
            o.column = f.column;
        }
    }
    const maps_line: ?[]const u8 = if (wantMaps(args)) try resolveMaps(drv, arena, args, view, .{ reflows, longs }) else null;
    const truncated = stop.truncated or sum.cut;
    const opts: std.json.Stringify.Options = .{ .emit_null_optional_fields = false };
    const mt = sum.main_thread;

    var res = mcp.Res.init(arena);
    try web.head(&res, arena, drv.mode(), view);
    try res.fact("window_ms", sum.window_ms);
    try res.fact("cpu_throttle", throttleOf(done.throttle));
    try res.fact("trace_path", save);
    try res.fact("bytes", stop.bytes);
    try res.fact("events", sum.events);
    try res.fact("truncated", truncated);
    try res.fact("navigations", done.navigations);
    try res.fact("main_thread", .{
        .source = @tagName(sum.main_source),
        .task_ms = mt.task_ms,
        .script_ms = mt.script_ms,
        .style_ms = mt.style_ms,
        .style_count = mt.style_count,
        .layout_ms = mt.layout_ms,
        .layout_count = mt.layout_count,
        .paint_ms = mt.paint_ms,
        .gc_ms = mt.gc_ms,
    });
    try res.raw("long_tasks", try std.json.Stringify.valueAlloc(arena, .{ .count = sum.long_tasks.count, .total_ms = sum.long_tasks.total_ms, .max_ms = sum.long_tasks.max_ms, .top = longs }, opts));
    try res.raw("forced_reflows", try std.json.Stringify.valueAlloc(arena, .{ .count = sum.forced_reflows.count, .total_ms = sum.forced_reflows.total_ms, .top = reflows }, opts));
    try res.raw("selector_stats", try std.json.Stringify.valueAlloc(arena, sum.selector_stats, opts));
    try res.raw("frames", try std.json.Stringify.valueAlloc(arena, sum.frames, opts));
    try res.raw("user_timing", try std.json.Stringify.valueAlloc(arena, sum.user_timing, opts));
    if (maps_line) |l| try res.fact("source_maps", l);
    try web.fileFacts(&res, save);

    try res.textf("trace {d}ms, {d} events, cpu_throttle {d}x: tasks {d}ms, script {d}ms, style {d}ms ({d}x), layout {d}ms ({d}x), paint {d}ms, gc {d}ms; raw trace at {s}", .{
        sum.window_ms, sum.events, throttleOf(done.throttle), mt.task_ms, mt.script_ms, mt.style_ms, mt.style_count, mt.layout_ms, mt.layout_count, mt.paint_ms, mt.gc_ms, save,
    });
    if (truncated) try res.textf("TRUNCATED: {s}", .{if (stop.note.len != 0) stop.note else "the file ended inside the event list; the summary covers what it holds"});
    if (sum.main_source != .tracing_started) try res.textf("main thread: {s}", .{if (sum.main_source == .none) "no renderer main thread in this trace; every section is empty" else "the trace does not name the tab's renderer; every renderer's main thread is counted"});
    if (done.navigations != 0) try res.textf("the page navigated {d}x while tracing; every renderer the tab used is counted", .{done.navigations});
    if (maps_line) |l| try res.textf("source maps: {s}", .{l});
    if (sum.frames) |f| try res.textf("frames drawn {d} ({d} fps)", .{ f.count, f.fps });
    var body: std.Io.Writer.Allocating = .init(arena);
    const w = &body.writer;
    if (sum.long_tasks.count != 0) {
        try w.print("{d} long tasks, {d}ms in all, max {d}ms\n", .{ sum.long_tasks.count, sum.long_tasks.total_ms, sum.long_tasks.max_ms });
        for (longs, 1..) |l, i| {
            try w.print("{d}. {d}ms at +{d}ms {s}", .{ i, l.duration_ms, l.start_ms, @tagName(l.cause) });
            if (l.url.len != 0 or l.function.len != 0) try writeSite(w, l.function, l.url, l.line, l.column, l.source, l.source_line, l.source_name);
            try w.writeByte('\n');
        }
        try res.section("long_tasks", body.written());
        body.clearRetainingCapacity();
    }
    if (sum.forced_reflows.count != 0) {
        try w.print("{d} forced style/layout runs inside JS, {d}ms in all\n", .{ sum.forced_reflows.count, sum.forced_reflows.total_ms });
        for (reflows, 1..) |r, i| {
            try w.print("{d}. {d}x {d}ms ({d} style, {d} layout)", .{ i, r.count, r.total_ms, r.style_count, r.layout_count });
            try writeSite(w, r.function, r.url, r.line, r.column, r.source, r.source_line, r.source_name);
            try w.writeByte('\n');
        }
        try res.section("forced_reflows", body.written());
        body.clearRetainingCapacity();
    }
    if (sum.selector_stats.len != 0) {
        for (sum.selector_stats, 1..) |s, i| try w.print("{d}. {d}ms attempts {d} matches {d} {s} ({s})\n", .{ i, s.elapsed_ms, s.match_attempts, s.match_count, s.selector, s.style_sheet });
        try res.section("selector_stats", body.written());
        body.clearRetainingCapacity();
    }
    if (sum.user_timing.len != 0) {
        for (sum.user_timing) |t| switch (t.kind) {
            .mark => try w.print("mark {s} +{d}ms\n", .{ t.name, t.start_ms }),
            .measure => try w.print("measure {s} +{d}ms {d}ms\n", .{ t.name, t.start_ms, t.duration_ms }),
        };
        try res.section("user_timing", body.written());
    }
    return res.finish();
}

fn writeSite(w: *std.Io.Writer, function: []const u8, url: []const u8, line: u32, column: u32, source: ?[]const u8, source_line: ?u32, source_name: ?[]const u8) !void {
    try w.print(" {s} {s}:{d}:{d}", .{ function, if (url.len != 0) url else "(no url)", line, column });
    if (source) |s| try w.print(" -> {s}:{d}", .{ s, source_line orelse 0 });
    if (source_name) |n| try w.print(" {s}", .{n});
}

const TopFn = struct {
    function: []const u8,
    url: []const u8,
    line: u32,
    column: u32,
    self_ms: f64,
    total_ms: f64,
    self_pct: f64,
    source: ?[]const u8 = null,
    source_line: ?u32 = null,
    source_name: ?[]const u8 = null,
};

fn msOf(us: u64) f64 {
    return @round(@as(f64, @floatFromInt(us)) / 10) / 100;
}

/// The top `n` functions, without sketerm's own page bridge (`sketerm://`), which only carries a web_eval.
fn topList(arena: std.mem.Allocator, fns: []const cpuprofile.Fn, n: usize, busy_us: u64) ![]TopFn {
    var out: std.ArrayList(TopFn) = .empty;
    for (fns) |f| {
        if (out.items.len == n) break;
        if (std.mem.startsWith(u8, f.url, "sketerm://")) continue;
        try out.append(arena, .{
            .function = if (f.function.len != 0) f.function else "(anonymous)",
            .url = f.url,
            .line = f.line,
            .column = f.column,
            .self_ms = msOf(f.self_us),
            .total_ms = msOf(f.total_us),
            .self_pct = if (busy_us > 0) @round(@as(f64, @floatFromInt(f.self_us)) * 1000 / @as(f64, @floatFromInt(busy_us))) / 10 else 0,
        });
    }
    return out.items;
}

fn summaryResult(drv: web.Driver, arena: std.mem.Allocator, args: std.json.Value, view: web.View, sum: cpuprofile.Summary, done: Done, save: []const u8, top: usize, interval: i64) ![]const u8 {
    const busy = sum.busyUs();
    const top_self = try topList(arena, sum.by_self, top, busy);
    const top_total = try topList(arena, sum.by_total, top, busy);
    const maps_line: ?[]const u8 = if (wantMaps(args)) try resolveMaps(drv, arena, args, view, .{ top_self, top_total }) else null;

    var res = mcp.Res.init(arena);
    try web.head(&res, arena, drv.mode(), view);
    try res.fact("duration_ms", msOf(sum.duration_us));
    try res.fact("sample_count", sum.sample_count);
    try res.fact("interval_us", interval);
    try res.fact("buckets", .{ .idle_ms = msOf(sum.idle_us), .program_ms = msOf(sum.program_us), .gc_ms = msOf(sum.gc_us), .script_ms = msOf(sum.script_us) });
    const opts: std.json.Stringify.Options = .{ .emit_null_optional_fields = false };
    try res.raw("top_self", try std.json.Stringify.valueAlloc(arena, top_self, opts));
    try res.raw("top_total", try std.json.Stringify.valueAlloc(arena, top_total, opts));
    try res.fact("profile_path", save);
    try web.fileFacts(&res, save);
    try res.fact("cpu_throttle", throttleOf(done.throttle));
    try res.fact("navigations", done.navigations);
    if (maps_line) |l| try res.fact("source_maps", l);
    try res.textf("CPU profile {d}ms, {d} samples (every {d}us), cpu_throttle {d}x: script {d}ms, program {d}ms, gc {d}ms, idle {d}ms; raw .cpuprofile at {s}", .{
        msOf(sum.duration_us), sum.sample_count, interval, throttleOf(done.throttle), msOf(sum.script_us), msOf(sum.program_us), msOf(sum.gc_us), msOf(sum.idle_us), save,
    });
    if (done.text.len != 0) try res.text(done.text);
    if (maps_line) |l| try res.textf("source maps: {s}", .{l});
    try writeTop(&res, arena, "top_self", top_self);
    try writeTop(&res, arena, "top_total", top_total);
    return res.finish();
}

fn writeTop(res: *mcp.Res, arena: std.mem.Allocator, name: []const u8, list: []const TopFn) !void {
    var body: std.Io.Writer.Allocating = .init(arena);
    const w = &body.writer;
    for (list, 1..) |t, i| {
        try w.print("{d}. self {d}ms ({d}%) total {d}ms", .{ i, t.self_ms, t.self_pct, t.total_ms });
        try writeSite(w, t.function, t.url, t.line, t.column, t.source, t.source_line, t.source_name);
        try w.writeByte('\n');
    }
    try res.section(name, body.written());
}

// ---------------------------------------------------------------------
// source maps
// ---------------------------------------------------------------------

const MapEntry = struct { url: []const u8, map: ?sourcemap.Map, why: []const u8 };

fn wantMaps(args: std.json.Value) bool {
    const v = mcp.argValue(args, "source_maps") orelse return true;
    return !(v == .bool and !v.bool);
}

/// Resolve the listed functions through their scripts' source maps; `lists` is a tuple of slices of structs with
/// `url`/`line`/`column` (1-based) and optional `source`/`source_line`/`source_name`. Returns the status line.
fn resolveMaps(drv: web.Driver, arena: std.mem.Allocator, args: std.json.Value, view: web.View, lists: anytype) ![]const u8 {
    var cache: std.ArrayList(MapEntry) = .empty;
    var wanted: usize = 0;
    var resolved: usize = 0;
    var reasons: std.ArrayList(u8) = .empty;
    inline for (lists) |list| for (list) |*t| {
        if (t.url.len == 0 or t.line == 0) continue;
        wanted += 1;
        const entry = blk: {
            for (cache.items) |*m| if (std.mem.eql(u8, m.url, t.url)) break :blk m;
            const fresh = try loadMap(drv, arena, args, view, t.url);
            try cache.append(arena, fresh);
            if (fresh.map == null and fresh.why.len != 0)
                try reasons.print(arena, "{s}{s}: {s}", .{ if (reasons.items.len != 0) "; " else "", fresh.url, fresh.why });
            break :blk &cache.items[cache.items.len - 1];
        };
        const map = entry.map orelse continue;
        const o = map.lookup(t.line - 1, if (t.column > 0) t.column - 1 else 0) orelse continue;
        t.source = o.source;
        t.source_line = o.line;
        t.source_name = o.name;
        resolved += 1;
    };
    return std.fmt.allocPrint(arena, "resolved {d} of {d}{s}{s}", .{ resolved, wanted, if (reasons.items.len != 0) "; " else "", reasons.items });
}

fn loadMap(drv: web.Driver, arena: std.mem.Allocator, args: std.json.Value, view: web.View, url: []const u8) !MapEntry {
    var out: MapEntry = .{ .url = url, .map = null, .why = "" };
    // An explicit local map wins over anything the page names.
    if (mcp.argValue(args, "source_map_files")) |files| if (files == .object) {
        var it = files.object.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.* != .string) continue;
            if (!std.mem.eql(u8, url, kv.key_ptr.*) and !std.mem.endsWith(u8, url, kv.key_ptr.*)) continue;
            const text = readfile.cappedAlloc(arena, kv.value_ptr.string, PROFILE_READ_CAP) catch {
                out.why = "source_map_files entry unreadable";
                return out;
            };
            return parsed(arena, out, text);
        }
    };
    if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) {
        out.why = "not an http(s) script";
        return out;
    }
    // The page fetches its own script (its cookies, its route); only the header and tail come back.
    const locate = try std.fmt.allocPrint(arena,
        \\fetch({f}).then(async r => JSON.stringify({{s: r.status, h: r.headers.get('SourceMap') || r.headers.get('X-SourceMap') || '', t: (await r.text()).slice(-8192)}}))
    , .{std.json.fmt(url, .{})});
    const located = switch (try evalString(drv, arena, view.pane, locate, 64 * 1024)) {
        .err => |why| {
            out.why = why;
            return out;
        },
        .ok => |s| s,
    };
    const Loc = struct { s: i64 = 0, h: []const u8 = "", t: []const u8 = "" };
    const loc = std.json.parseFromSliceLeaky(Loc, arena, located, .{ .ignore_unknown_fields = true }) catch {
        out.why = "the script fetch answered malformed";
        return out;
    };
    if (loc.s < 200 or loc.s > 299) {
        out.why = try std.fmt.allocPrint(arena, "the script fetch answered HTTP {d}", .{loc.s});
        return out;
    }
    const ref = if (loc.h.len != 0) loc.h else sourcemap.commentUrl(loc.t) orelse {
        out.why = "no sourceMappingURL";
        return out;
    };
    if (sourcemap.dataUrl(arena, ref) catch {
        out.why = "malformed data: source map url";
        return out;
    }) |text| return parsed(arena, out, text);
    const fetch_map = try std.fmt.allocPrint(arena,
        \\fetch(new URL({f}, {f}).href).then(r => r.ok ? r.text() : Promise.reject(new Error('HTTP ' + r.status)))
    , .{ std.json.fmt(ref, .{}), std.json.fmt(url, .{}) });
    switch (try evalString(drv, arena, view.pane, fetch_map, MAP_FETCH_CAP)) {
        .err => |why| {
            out.why = why;
            return out;
        },
        .ok => |text| return parsed(arena, out, text),
    }
}

fn parsed(arena: std.mem.Allocator, base: MapEntry, text: []const u8) MapEntry {
    var out = base;
    out.map = sourcemap.parse(arena, text) catch |err| {
        out.why = switch (err) {
            error.IndexMapUnsupported => "index source maps (sections) are unsupported",
            else => "the source map is malformed",
        };
        return out;
    };
    return out;
}

fn evalString(drv: web.Driver, arena: std.mem.Allocator, pane: u32, code: []const u8, max_chars: u32) !union(enum) { ok: []const u8, err: []const u8 } {
    switch (try web.runOp(drv, arena, pane, .{ .op = "eval", .data = code, .await_promise = true, .timeout_ms = 15_000, .max_chars = max_chars }, 20_000)) {
        .err => |f| return .{ .err = f.text },
        .done => |r| {
            if (r.timed_out or !r.ok) return .{ .err = "the page could not fetch it" };
            const v = std.json.parseFromSliceLeaky(std.json.Value, arena, r.payload, .{}) catch return .{ .err = "the page's fetch answered malformed" };
            const inner = if (v == .object) v.object.get("value") orelse v else v;
            if (inner == .string) return .{ .ok = inner.string };
            if (inner == .object) if (inner.object.get("__kind")) |k| if (k == .string and std.mem.eql(u8, k.string, "string"))
                return .{ .err = "larger than the page eval budget (4 MiB); pass it through source_map_files" };
            return .{ .err = "the page's fetch answered no text" };
        },
    }
}
