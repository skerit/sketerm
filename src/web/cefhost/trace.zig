//! Tracing ops (`perf_req` trace_start/trace_stop, capability "web-trace") over the view's DevTools session.
//!
//! `Tracing.dataCollected` chunks are appended to a staged file as they
//! arrive, so the helper never holds a trace in memory. The trace ends on
//! the `Tracing.tracingComplete` EVENT: the method result of `Tracing.end`
//! was measured never to arrive (see CLAUDE.md).

const std = @import("std");
const cef = @import("cef");
const proto = @import("../protocol.zig");
const host_mod = @import("../cefhost.zig");
const devtools = @import("devtools_session.zig");
const perf = @import("perf.zig");
const clock = @import("../../util/clock.zig");

const Host = host_mod.Host;
const View = host_mod.View;

/// The longest trace a client may ask for; also the helper's own bound.
pub const max_trace_ms: u32 = 30_000;
/// Past this many bytes of trace file the helper stops collecting and ends the trace.
pub const max_bytes: u64 = 256 * 1024 * 1024;
/// How long the engine gets to flush and report `tracingComplete` after `Tracing.end`.
const complete_timeout_ms: i64 = 60_000;
const method_timeout_ms: i64 = 10_000;

/// The fixed category preset: the main-thread timeline with JS stacks on
/// forced style/layout, user timing and frames; never the V8 sampler.
pub const categories = [_][]const u8{
    "devtools.timeline",
    "disabled-by-default-devtools.timeline",
    "disabled-by-default-devtools.timeline.frame",
    "disabled-by-default-devtools.timeline.stack",
    "v8.execute",
    "v8",
    "blink.user_timing",
    "toplevel",
    "__metadata",
};
/// Added by `TRACE_SELECTOR_STATS`: per-selector timings inside every style recalc (expensive).
pub const selector_stats_category = "disabled-by-default-blink.debug";

const HEAD = "{\"traceEvents\":[";
const TAIL = "\n]}\n";

pub const Phase = enum { idle, starting, running, ending };

/// Per-view trace state; dies with the browser.
pub const State = struct {
    phase: Phase = .idle,
    file: ?devtools.StagedFile = null,
    bytes: u64 = 0,
    /// At least one event was written (the next one needs a separating comma).
    any_event: bool = false,
    truncated: bool = false,
    /// A chunk could not be used; the note says so.
    bad_chunks: u32 = 0,
    /// The cap was reached inside an event callback; `pump` sends the end.
    want_end: bool = false,
    start_id: c_int = 0,
    start_req: u32 = 0,
    started_ms: i64 = 0,
    limit_ms: u32 = 0,
    end_deadline_ms: i64 = 0,
    loads_at_start: u32 = 0,
    /// A client stop waiting for `tracingComplete`.
    stop_req: u32 = 0,
    note: []const u8 = "",
    /// A trace that ended with nobody waiting (time limit or size cap): owned path for the next stop.
    done_path: ?[]u8 = null,
    done_text: ?[]u8 = null,
    done_navs: u32 = 0,

    pub fn busy(self: *const State) bool {
        return self.phase != .idle;
    }
};

fn dropDone(gpa: std.mem.Allocator, s: *State) void {
    if (s.done_path) |p| {
        unlinkPath(gpa, p);
        gpa.free(p);
    }
    if (s.done_text) |t| gpa.free(t);
    s.done_path = null;
    s.done_text = null;
}

fn unlinkPath(gpa: std.mem.Allocator, p: []const u8) void {
    const z = gpa.dupeSentinel(u8, p, 0) catch return;
    defer gpa.free(z);
    _ = @import("cbindings").unlink(z.ptr);
}

/// The `Tracing.start` params for `flags` (`TRACE_*`).
pub fn startParams(gpa: std.mem.Allocator, flags: u32) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"transferMode\":\"ReportEvents\",\"traceConfig\":{\"recordMode\":\"recordAsMuchAsPossible\",\"excludedCategories\":[\"*\"],\"includedCategories\":[");
    for (categories, 0..) |cat, i| try w.print("{s}\"{s}\"", .{ if (i == 0) "" else ",", cat });
    if (flags & proto.TRACE_SELECTOR_STATS != 0) try w.print(",\"{s}\"", .{selector_stats_category});
    try w.writeAll("]}}");
    return out.toOwnedSlice();
}

/// Serve `trace_start`/`trace_stop`; every request is answered exactly once.
pub fn request(host: *Host, v: *View, session: *devtools.Session, browser: *cef.cef_browser_t, req: proto.PerfReq, op: proto.PerfOp) void {
    const s = &v.perf.trace;
    switch (op) {
        .trace_start => {
            if (s.busy()) return perf.refuse(host, v.id, req, "a trace is already running on this view; stop it first");
            if (session.events != null) return perf.refuse(host, v.id, req, "another DevTools event consumer is active on this view");
            dropDone(host.gpa, s);
            var file = devtools.StagedFile.open("trace") orelse return perf.refuse(host, v.id, req, "could not create a staging file for the trace");
            if (!file.write(HEAD)) {
                file.abort();
                return perf.refuse(host, v.id, req, "could not write the trace staging file");
            }
            const params = startParams(host.gpa, req.arg) catch {
                file.abort();
                return perf.refuse(host, v.id, req, "out of memory building the trace config");
            };
            defer host.gpa.free(params);
            session.events = .{ .ctx = v, .on_event = onEvent };
            const id = session.send(browser, "Tracing.start", params, method_timeout_ms, .memory, "") catch {
                session.events = null;
                file.abort();
                return perf.refuse(host, v.id, req, "the engine refused Tracing.start");
            };
            s.* = .{
                .phase = .starting,
                .file = file,
                .bytes = HEAD.len,
                .start_id = id,
                .start_req = req.req,
                .limit_ms = if (req.limit_ms == 0) max_trace_ms else @min(req.limit_ms, max_trace_ms),
                .loads_at_start = v.perf.loads,
            };
        },
        .trace_stop => {
            if (s.done_path) |path| {
                const text = s.done_text orelse "";
                perf.answer(host, v, req.req, req.op, true, text, path, s.done_navs);
                host.gpa.free(path);
                if (s.done_text) |t| host.gpa.free(t);
                s.done_path = null;
                s.done_text = null;
                return;
            }
            switch (s.phase) {
                .idle => return perf.refuse(host, v.id, req, "no trace is running on this view"),
                .starting => return perf.refuse(host, v.id, req, "the trace is still starting; stop it once web_trace start answered"),
                .ending => {
                    if (s.stop_req != 0) return perf.refuse(host, v.id, req, "the trace is already being stopped");
                    s.stop_req = req.req;
                },
                .running => {
                    s.stop_req = req.req;
                    endTrace(host, v, session, "");
                },
            }
        },
        else => unreachable,
    }
}

/// Ask the engine to flush and complete; the result of `Tracing.end` itself is never awaited.
fn endTrace(host: *Host, v: *View, session: *devtools.Session, note: []const u8) void {
    _ = host;
    const s = &v.perf.trace;
    s.phase = .ending;
    s.want_end = false;
    if (note.len != 0 and s.note.len == 0) s.note = note;
    s.end_deadline_ms = clock.nowMs() + complete_timeout_ms;
    const browser = v.browser orelse return;
    if (session.send(browser, "Tracing.end", null, method_timeout_ms, .memory, "")) |id| session.forget(id) else |_| {}
}

fn onEvent(ctx: *anyopaque, method: []const u8, params: []const u8) void {
    const v: *View = @ptrCast(@alignCast(ctx));
    const s = &v.perf.trace;
    if (std.mem.eql(u8, method, "Tracing.dataCollected")) return collect(s, params);
    if (std.mem.eql(u8, method, "Tracing.tracingComplete")) {
        if (s.phase == .running or s.phase == .ending) s.phase = .idle;
        // Finished in `pump`, outside the engine's callback.
        s.want_end = false;
    }
}

/// Append one `dataCollected` chunk's events to the file, or stop collecting at the cap.
fn collect(s: *State, params: []const u8) void {
    if (s.truncated) return;
    const file = if (s.file) |*f| f else return;
    const arr = devtools.memberSlice(params, "value") orelse {
        s.bad_chunks += 1;
        return;
    };
    if (arr.len < 2 or arr[0] != '[') {
        s.bad_chunks += 1;
        return;
    }
    const inner = std.mem.trim(u8, arr[1 .. arr.len - 1], " \t\r\n");
    if (inner.len == 0) return;
    if (s.bytes + inner.len + 2 > max_bytes - TAIL.len) {
        s.truncated = true;
        if (s.phase == .running) s.want_end = true;
        if (s.note.len == 0) s.note = "the trace reached the helper's 256 MiB cap; later events were dropped";
        return;
    }
    const sep: []const u8 = if (s.any_event) ",\n" else "\n";
    if (!file.write(sep) or !file.write(inner)) {
        s.truncated = true;
        if (s.phase == .running) s.want_end = true;
        if (s.note.len == 0) s.note = "writing the trace file failed; later events were dropped";
        return;
    }
    s.bytes += sep.len + inner.len;
    s.any_event = true;
}

/// Close the file as valid JSON and hand it to the waiting stop, or keep it for the next one.
fn finish(host: *Host, v: *View, incomplete: bool) void {
    const s = &v.perf.trace;
    var file = s.file orelse return;
    s.file = null;
    if (incomplete) {
        s.truncated = true;
        if (s.note.len == 0) s.note = "the engine did not report the trace complete in time; the file holds what had arrived";
    }
    if (s.bad_chunks != 0 and s.note.len == 0) s.note = "some trace chunks were malformed and skipped";
    _ = file.write(TAIL);
    s.bytes += TAIL.len;
    if (file.failed) {
        file.abort();
        if (s.stop_req != 0) perf.answer(host, v, s.stop_req, @intFromEnum(proto.PerfOp.trace_stop), false, "writing the trace file failed", "", 0);
        resetKeepingDone(s);
        return;
    }
    const path = file.finish();
    const navs = v.perf.loads -% s.loads_at_start;
    const text = std.json.Stringify.valueAlloc(host.gpa, proto.TraceStop{ .truncated = s.truncated, .bytes = s.bytes, .note = s.note }, .{}) catch null;
    if (s.stop_req != 0) {
        perf.answer(host, v, s.stop_req, @intFromEnum(proto.PerfOp.trace_stop), true, text orelse "{}", path, navs);
        if (text) |t| host.gpa.free(t);
    } else {
        s.done_path = host.gpa.dupe(u8, path) catch blk: {
            _ = @import("cbindings").unlink(path.ptr);
            break :blk null;
        };
        s.done_text = if (s.done_path != null) text else blk: {
            if (text) |t| host.gpa.free(t);
            break :blk null;
        };
        s.done_navs = navs;
    }
    resetKeepingDone(s);
}

fn resetKeepingDone(s: *State) void {
    const keep_path = s.done_path;
    const keep_text = s.done_text;
    const keep_navs = s.done_navs;
    s.* = .{ .done_path = keep_path, .done_text = keep_text, .done_navs = keep_navs };
}

/// Advance the view's trace: start answers, the time limit, the size cap and completion.
pub fn pump(host: *Host, v: *View, session: *devtools.Session, now_ms: i64) void {
    const s = &v.perf.trace;
    switch (s.phase) {
        .idle => {
            if (s.file != null) {
                session.events = null;
                finish(host, v, false);
            }
        },
        .starting => switch (session.outcome(s.start_id)) {
            .pending => {},
            .failed => |why| {
                const text = host.gpa.dupe(u8, why) catch "";
                defer if (text.len != 0) host.gpa.free(text);
                session.forget(s.start_id);
                session.events = null;
                if (s.file) |*f| f.abort();
                perf.answer(host, v, s.start_req, @intFromEnum(proto.PerfOp.trace_start), false, if (text.len != 0) text else "the engine refused Tracing.start", "", 0);
                resetKeepingDone(s);
            },
            .ok => {
                session.forget(s.start_id);
                s.phase = .running;
                s.started_ms = now_ms;
                perf.answer(host, v, s.start_req, @intFromEnum(proto.PerfOp.trace_start), true, "", "", 0);
            },
        },
        .running => {
            if (s.want_end) {
                endTrace(host, v, session, "");
            } else if (now_ms - s.started_ms >= s.limit_ms) {
                endTrace(host, v, session, "the helper ended the trace itself at its time limit");
            }
        },
        .ending => if (now_ms >= s.end_deadline_ms) {
            session.events = null;
            s.phase = .idle;
            finish(host, v, true);
        },
    }
}

/// The browser is going away: answer what waits and remove every file.
pub fn browserGone(host: *Host, v: *View) void {
    const s = &v.perf.trace;
    const why = "the view's browser went away (closed, discarded or crashed) during the trace";
    if (s.phase == .starting) perf.answer(host, v, s.start_req, @intFromEnum(proto.PerfOp.trace_start), false, why, "", 0);
    if (s.stop_req != 0) perf.answer(host, v, s.stop_req, @intFromEnum(proto.PerfOp.trace_stop), false, why, "", 0);
    if (s.file) |*f| f.abort();
    if (v.devtools) |session| if (s.phase != .idle) {
        session.events = null;
    };
    dropDone(host.gpa, s);
    s.* = .{};
}

test "the trace config names the fixed preset and adds selector stats only on request" {
    const gpa = std.testing.allocator;
    const plain = try startParams(gpa, 0);
    defer gpa.free(plain);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, plain, .{});
    defer parsed.deinit();
    const cfg = parsed.value.object.get("traceConfig").?.object;
    try std.testing.expectEqual(categories.len, cfg.get("includedCategories").?.array.items.len);
    try std.testing.expect(std.mem.indexOf(u8, plain, selector_stats_category) == null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "cpu_profiler") == null);
    const with = try startParams(gpa, proto.TRACE_SELECTOR_STATS);
    defer gpa.free(with);
    try std.testing.expect(std.mem.indexOf(u8, with, selector_stats_category) != null);
}
