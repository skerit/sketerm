//! `web_perf` and `web_cpu_profile`: page performance through the view's DevTools session (helper capability `web-perf`).
//!
//! Headless only, like emulation: the GUI's tabs answer `unavailable`. The raw
//! profile reaches this process as a STAGED helper file, never a frame, and is
//! summarized here; a helper on another host is refused because its staging
//! file is on that host.

const std = @import("std");
const mcp = @import("mcp.zig");
const web = @import("mcp_web.zig");
const webdrive = @import("webdrive.zig");
const web_proto = @import("../web/protocol.zig");
const clock = @import("../util/clock.zig");
const reflect = @import("../util/reflect.zig");
const readfile = @import("../util/readfile.zig");
const metrics = @import("perf/metrics.zig");
const cpuprofile = @import("perf/cpuprofile.zig");
const sourcemap = @import("perf/sourcemap.zig");

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
    if (!e.has(.web_perf))
        return mcp.errRes(arena, .unavailable, "this browser helper predates web-perf (capabilities web_perf), so it cannot measure the page; nothing was measured");
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
    return profileTool(drv, arena, e, args, view);
}

const Done = struct { text: []const u8, staged: []const u8, throttle: u32, paints: u32, navigations: u32 };
const PerfResult = union(enum) { ok: Done, err: []const u8 };

/// Run one perf op to its answer; `deliver_to` moves a staged result there before the record is dropped.
fn perfOp(drv: web.Driver, arena: std.mem.Allocator, e: *webdrive.Engine, pane: u32, op: web_proto.PerfOp, arg: u32, limit_ms: u32, timeout_ms: i64, deliver_to: ?[]const u8) !PerfResult {
    const req = e.startPerf(pane, op, arg, limit_ms) catch |err| return .{ .err = switch (err) {
        error.Unsupported => try mcp.errRes(arena, .unavailable, "this browser helper predates web-perf"),
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

fn profileTool(drv: web.Driver, arena: std.mem.Allocator, e: *webdrive.Engine, args: std.json.Value, view: web.View) ![]const u8 {
    const action = mcp.argStr(args, "action");
    const duration = mcp.argInt(args, "duration_ms");
    if ((action == null) == (duration == null))
        return mcp.errRes(arena, .invalid_args, "web_cpu_profile needs either action:\"start\"|\"stop\" or duration_ms for a one-shot");
    if (action) |a| if (!std.mem.eql(u8, a, "start") and !std.mem.eql(u8, a, "stop"))
        return mcp.errRes(arena, .invalid_args, "action must be start or stop");
    if (duration) |d| if (d < 1 or d > MAX_PROFILE_MS) return mcp.errRes(arena, .invalid_args, "duration_ms must be from 1 through 120000");
    const interval = mcp.argInt(args, "interval_us") orelse DEFAULT_INTERVAL_US;
    if (interval < web_proto.PERF_INTERVAL_MIN_US or interval > 1_000_000) return mcp.errRes(arena, .invalid_args, "interval_us must be from 100 through 1000000");
    const top = mcp.argInt(args, "top") orelse DEFAULT_TOP;
    if (top < 1 or top > MAX_TOP) return mcp.errRes(arena, .invalid_args, "top must be from 1 through 100");
    // The profile is staged on the helper's host and moved here.
    if (e.route_kind == .remote_browser)
        return mcp.errRes(arena, .unavailable, "this view's browser runs on another host, where its profile would be staged; web_cpu_profile profiles views of a local browser helper (web_perf works there)");
    const starting = duration != null or std.mem.eql(u8, action.?, "start");
    const stopping = duration != null or std.mem.eql(u8, action.?, "stop");
    var save: []const u8 = "";
    if (stopping) {
        save = mcp.argStr(args, "save") orelse try tempProfilePath(arena);
        if (save.len == 0 or save[0] != '/') return mcp.errRes(arena, .invalid_args, "'save' must be an absolute file path");
    }
    if (starting) {
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
    return summaryResult(drv, arena, e, args, view, sum, done, save, @intCast(top), if (duration != null) interval else @intCast(sum.interval_us));
}

fn tempProfilePath(arena: std.mem.Allocator) ![]const u8 {
    const c = @import("../c.zig").c;
    const dir: []const u8 = if (c.getenv("TMPDIR")) |t| std.mem.span(t) else "/tmp";
    var rnd: [4]u8 = undefined;
    _ = c.getentropy(&rnd, rnd.len);
    return std.fmt.allocPrint(arena, "{s}/sketerm-{d}-{x}.cpuprofile", .{ if (dir.len > 0 and dir[0] == '/') dir else "/tmp", clock.wallMs(), std.mem.readInt(u32, &rnd, .little) });
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

fn summaryResult(drv: web.Driver, arena: std.mem.Allocator, e: *webdrive.Engine, args: std.json.Value, view: web.View, sum: cpuprofile.Summary, done: Done, save: []const u8, top: usize, interval: i64) ![]const u8 {
    const busy = sum.busyUs();
    const top_self = try topList(arena, sum.by_self, top, busy);
    const top_total = try topList(arena, sum.by_total, top, busy);
    const maps_line: ?[]const u8 = if (mcp.argValue(args, "source_maps")) |v| (if (v == .bool and !v.bool) null else try resolveMaps(drv, arena, e, args, view, top_self, top_total)) else try resolveMaps(drv, arena, e, args, view, top_self, top_total);

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
        try w.print("{d}. {s} self {d}ms ({d}%) total {d}ms {s}:{d}:{d}", .{ i, t.function, t.self_ms, t.self_pct, t.total_ms, if (t.url.len != 0) t.url else "(no url)", t.line, t.column });
        if (t.source) |s| try w.print(" -> {s}:{d}", .{ s, t.source_line orelse 0 });
        if (t.source_name) |n| try w.print(" {s}", .{n});
        try w.writeByte('\n');
    }
    try res.section(name, body.written());
}

// ---------------------------------------------------------------------
// source maps
// ---------------------------------------------------------------------

const MapEntry = struct { url: []const u8, map: ?sourcemap.Map, why: []const u8 };

/// Resolve the top lists' functions through their scripts' source maps; returns the status line.
fn resolveMaps(drv: web.Driver, arena: std.mem.Allocator, e: *webdrive.Engine, args: std.json.Value, view: web.View, a: []TopFn, b: []TopFn) ![]const u8 {
    _ = e;
    var cache: std.ArrayList(MapEntry) = .empty;
    var wanted: usize = 0;
    var resolved: usize = 0;
    var reasons: std.ArrayList(u8) = .empty;
    for ([_][]TopFn{ a, b }) |list| for (list) |*t| {
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
