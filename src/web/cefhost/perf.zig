//! Performance ops (`perf_req`, capability "web-perf") over the view's DevTools session.
//!
//! An agent attaches only when a client asks for one of these. Never add
//! `Runtime.enable` or `Debugger.enable` here: smoke-web's dt stage fails a
//! helper that attaches an inspector by default, and these domains are not needed.

const std = @import("std");
const cef = @import("cef");
const proto = @import("../protocol.zig");
const host_mod = @import("../cefhost.zig");
const devtools = @import("devtools_session.zig");
const host_trace = @import("trace.zig");
const clock = @import("../../util/clock.zig");

const Host = host_mod.Host;
const View = host_mod.View;

/// Deadline for an ordinary perf method.
const method_timeout_ms: i64 = 10_000;
/// Deadline for `Profiler.stop`, which serializes the whole profile.
const stop_timeout_ms: i64 = 60_000;
/// The longest profile a client may ask for; also the helper's own bound when it asks for none.
pub const max_profile_ms: u32 = 120_000;

const Job = struct {
    /// Client correlation id; 0 for the helper's own auto-stop.
    req: u32,
    op: proto.PerfOp,
    /// Methods sent for this job, answered in order; the last one carries the result.
    ids: [3]c_int = @splat(0),
    n: u8 = 0,
    rate_x100: u32 = 0,
    /// metrics: `Performance.enable` was sent alone; `getMetrics` follows its answer
    /// (pipelined, the engine answered it with an empty list).
    then_metrics: bool = false,
};

/// Per-view perf state; survives navigations, dies with the browser.
pub const State = struct {
    throttle_x100: u32 = 100,
    perf_enabled: bool = false,
    profiling: bool = false,
    profile_started_ms: i64 = 0,
    profile_limit_ms: u32 = 0,
    loads: u32 = 0,
    loads_at_start: u32 = 0,
    /// A profile the helper stopped itself (limit reached), waiting for the client's stop. Owned path.
    auto_staged: ?[]u8 = null,
    auto_note: []const u8 = "",
    jobs: [4]?Job = @splat(null),
    trace: host_trace.State = .{},

    /// Release what the state owns, removing an uncollected profile, and reset it.
    pub fn deinit(self: *State, gpa: std.mem.Allocator) void {
        if (self.auto_staged) |p| {
            unlinkPath(gpa, p);
            gpa.free(p);
        }
        self.* = .{};
    }
};

fn unlinkPath(gpa: std.mem.Allocator, p: []const u8) void {
    const z = gpa.dupeSentinel(u8, p, 0) catch return;
    defer gpa.free(z);
    _ = @import("cbindings").unlink(z.ptr);
}

pub fn answer(host: *Host, v: *const View, req: u32, op: u8, ok: bool, text: []const u8, staged: []const u8, navigations: u32) void {
    if (req == 0) return;
    host.post(proto.EvPerfResult{
        .view = v.id,
        .req = req,
        .op = op,
        .ok = @intFromBool(ok),
        .throttle = v.perf.throttle_x100,
        .paints = v.paints,
        .navigations = navigations,
        .text = text,
        .staged = staged,
    });
}

pub fn refuse(host: *Host, view: u32, req: proto.PerfReq, why: []const u8) void {
    host.post(proto.EvPerfResult{ .view = view, .req = req.req, .op = req.op, .ok = 0, .throttle = 100, .paints = 0, .navigations = 0, .text = why, .staged = "" });
}

/// Serve one `perf_req`; every request is answered exactly once.
pub fn perfReq(host: *Host, req: proto.PerfReq) void {
    const v = host.find(req.view) orelse return refuse(host, req.view, req, "no such view");
    const browser = v.browser orelse return refuse(host, v.id, req, "the view has no live browser (discarded or closing)");
    const op = std.enums.fromInt(proto.PerfOp, req.op) orelse return refuse(host, v.id, req, "unknown perf op");
    if (op == .trace_start or op == .trace_stop) {
        const session = host.devtoolsFor(v) catch return refuse(host, v.id, req, "the engine refused a DevTools session for this view");
        return host_trace.request(host, v, session, browser, req, op);
    }
    const slot = freeSlot(v) orelse return refuse(host, v.id, req, "too many perf requests in flight on this view");
    const session = host.devtoolsFor(v) catch return refuse(host, v.id, req, "the engine refused a DevTools session for this view");
    var job: Job = .{ .req = req.req, .op = op };
    switch (op) {
        .metrics => {
            if (!v.perf.perf_enabled) {
                push(&job, session.send(browser, "Performance.enable", "{\"timeDomain\":\"timeTicks\"}", method_timeout_ms, .memory, "")) catch
                    return refuse(host, v.id, req, "the engine refused Performance.enable");
                job.then_metrics = true;
            } else push(&job, session.send(browser, "Performance.getMetrics", null, method_timeout_ms, .memory, "")) catch
                return refuse(host, v.id, req, "the engine refused Performance.getMetrics");
        },
        .throttle => {
            if (req.arg < 100 or req.arg > proto.PERF_THROTTLE_MAX) return refuse(host, v.id, req, "throttle rate out of range (1..20)");
            job.rate_x100 = req.arg;
            push(&job, sendThrottle(session, browser, req.arg)) catch
                return refuse(host, v.id, req, "the engine refused Emulation.setCPUThrottlingRate");
        },
        .profile_start => {
            if (v.perf.profiling or profileJob(v) != null) return refuse(host, v.id, req, "a CPU profile is already running on this view; stop it first");
            if (req.arg < proto.PERF_INTERVAL_MIN_US) return refuse(host, v.id, req, "sampling interval below 100us");
            if (v.perf.auto_staged) |p| {
                unlinkPath(host.gpa, p);
                host.gpa.free(p);
                v.perf.auto_staged = null;
            }
            var params: [64]u8 = undefined;
            const interval = std.fmt.bufPrint(&params, "{{\"interval\":{d}}}", .{req.arg}) catch unreachable;
            push(&job, session.send(browser, "Profiler.enable", null, method_timeout_ms, .memory, "")) catch
                return refuse(host, v.id, req, "the engine refused Profiler.enable");
            push(&job, session.send(browser, "Profiler.setSamplingInterval", interval, method_timeout_ms, .memory, "")) catch
                return failSent(session, &job, host, v, req, "the engine refused Profiler.setSamplingInterval");
            push(&job, session.send(browser, "Profiler.start", null, method_timeout_ms, .memory, "")) catch
                return failSent(session, &job, host, v, req, "the engine refused Profiler.start");
            v.perf.profile_limit_ms = if (req.limit_ms == 0) max_profile_ms else @min(req.limit_ms, max_profile_ms);
        },
        .profile_stop => {
            if (v.perf.auto_staged) |path| {
                v.perf.auto_staged = null;
                defer host.gpa.free(path);
                answer(host, v, req.req, req.op, true, v.perf.auto_note, path, v.perf.loads -% v.perf.loads_at_start);
                return;
            }
            if (profileJob(v)) |j| if (j.op == .profile_stop) {
                // The helper's own stop at the limit is in flight: its answer becomes this request's.
                if (j.req != 0) return refuse(host, v.id, req, "the profile is already being stopped");
                j.req = req.req;
                return;
            };
            if (!v.perf.profiling) return refuse(host, v.id, req, "no CPU profile is running on this view");
            push(&job, session.send(browser, "Profiler.stop", null, stop_timeout_ms, .staged, "profile")) catch
                return refuse(host, v.id, req, "the engine refused Profiler.stop");
        },
        .trace_start, .trace_stop => unreachable,
        _ => return refuse(host, v.id, req, "unknown perf op"),
    }
    slot.* = job;
}

fn failSent(session: *devtools.Session, job: *Job, host: *Host, v: *View, req: proto.PerfReq, why: []const u8) void {
    for (job.ids[0..job.n]) |id| session.forget(id);
    refuse(host, v.id, req, why);
}

fn push(job: *Job, id: anyerror!c_int) !void {
    job.ids[job.n] = try id;
    job.n += 1;
}

fn sendThrottle(session: *devtools.Session, browser: *cef.cef_browser_t, rate_x100: u32) !c_int {
    var params: [64]u8 = undefined;
    const json = std.fmt.bufPrint(&params, "{{\"rate\":{d}.{d:0>2}}}", .{ rate_x100 / 100, rate_x100 % 100 }) catch unreachable;
    return session.send(browser, "Emulation.setCPUThrottlingRate", json, method_timeout_ms, .memory, "");
}

fn freeSlot(v: *View) ?*?Job {
    for (&v.perf.jobs) |*j| if (j.* == null) return j;
    return null;
}

fn profileJob(v: *View) ?*Job {
    for (&v.perf.jobs) |*j| if (j.*) |*job| if (job.op == .profile_start or job.op == .profile_stop) return job;
    return null;
}

/// The view's browser is going away: answer every pending request, then reset.
pub fn browserGone(host: *Host, v: *View) void {
    for (&v.perf.jobs) |*entry| {
        const job = entry.* orelse continue;
        entry.* = null;
        answer(host, v, job.req, @intFromEnum(job.op), false, "the view's browser went away (closed, discarded or crashed)", "", 0);
    }
    host_trace.browserGone(host, v);
    v.perf.deinit(host.gpa);
}

/// A main-frame load started: count it, and keep a throttle the engine may have dropped with a renderer swap.
pub fn onMainLoadStart(host: *Host, v: *View) void {
    v.perf.loads +%= 1;
    if (v.perf.throttle_x100 == 100) return;
    const session = v.devtools orelse return;
    const browser = v.browser orelse return;
    const id = sendThrottle(session, browser, v.perf.throttle_x100) catch return;
    // Nobody waits on the re-application; its answer is dropped when it lands.
    _ = host;
    session.forget(id);
}

/// Advance every view's perf jobs; called from the host watchdog.
pub fn pump(host: *Host, now_ms: i64) void {
    for (host.views.items) |v| {
        const session = v.devtools orelse continue;
        session.expire(now_ms);
        host_trace.pump(host, v, session, now_ms);
        if (v.perf.profiling and v.perf.auto_staged == null and profileJob(v) == null and
            now_ms - v.perf.profile_started_ms >= v.perf.profile_limit_ms)
        {
            if (freeSlot(v)) |slot| if (v.browser) |browser| {
                if (session.send(browser, "Profiler.stop", null, stop_timeout_ms, .staged, "profile")) |id| {
                    slot.* = .{ .req = 0, .op = .profile_stop, .ids = .{ id, 0, 0 }, .n = 1 };
                } else |_| {}
            };
        }
        for (&v.perf.jobs) |*entry| {
            const job = &(entry.* orelse continue);
            if (step(host, v, session, job)) entry.* = null;
        }
    }
}

fn failJob(host: *Host, v: *View, session: *devtools.Session, job: *Job, why: []const u8) bool {
    for (job.ids[0..job.n]) |id| session.forget(id);
    answer(host, v, job.req, @intFromEnum(job.op), false, why, "", 0);
    return true;
}

/// True once the job was answered.
fn step(host: *Host, v: *View, session: *devtools.Session, job: *Job) bool {
    const op: u8 = @intFromEnum(job.op);
    // Every prerequisite must have succeeded; the last id carries the result.
    for (job.ids[0..job.n]) |id| {
        switch (session.outcome(id)) {
            .pending => return false,
            .failed => |why| {
                const text = host.gpa.dupe(u8, why) catch "";
                defer if (text.len != 0) host.gpa.free(text);
                for (job.ids[0..job.n]) |other| session.forget(other);
                if (job.op == .profile_stop) {
                    v.perf.profiling = false;
                    const msg = if (std.mem.indexOf(u8, text, "not started") != null)
                        "the profiler was no longer running in this page's renderer (a cross-process navigation or a renderer crash ends a profile)"
                    else
                        text;
                    if (job.req == 0) {
                        v.perf.auto_note = "the helper's own stop at the time limit failed";
                    } else answer(host, v, job.req, op, false, msg, "", v.perf.loads -% v.perf.loads_at_start);
                } else answer(host, v, job.req, op, false, text, "", 0);
                return true;
            },
            .ok => {},
        }
    }
    if (job.then_metrics) {
        job.then_metrics = false;
        v.perf.perf_enabled = true;
        const browser = v.browser orelse return failJob(host, v, session, job, "the view lost its browser");
        const id = session.send(browser, "Performance.getMetrics", null, method_timeout_ms, .memory, "") catch
            return failJob(host, v, session, job, "the engine refused Performance.getMetrics");
        job.ids[job.n] = id;
        job.n += 1;
        return false;
    }
    const last = job.ids[job.n - 1];
    const result = session.outcome(last).ok;
    switch (job.op) {
        .metrics => {
            v.perf.perf_enabled = true;
            answer(host, v, job.req, op, true, result, "", 0);
        },
        .throttle => {
            v.perf.throttle_x100 = job.rate_x100;
            answer(host, v, job.req, op, true, "", "", 0);
        },
        .profile_start => {
            v.perf.profiling = true;
            v.perf.profile_started_ms = clock.nowMs();
            v.perf.loads_at_start = v.perf.loads;
            answer(host, v, job.req, op, true, "", "", 0);
        },
        .profile_stop => {
            v.perf.profiling = false;
            session.takeStaged(last);
            const navs = v.perf.loads -% v.perf.loads_at_start;
            if (job.req == 0) {
                v.perf.auto_staged = host.gpa.dupe(u8, result) catch null;
                v.perf.auto_note = "the helper stopped the profile itself at its time limit";
                if (v.perf.auto_staged == null) unlinkPath(host.gpa, result);
            } else answer(host, v, job.req, op, true, if (navs != 0) "the page navigated while profiling; samples after a renderer swap are missing" else "", result, navs);
            // Release the V8 profiler; nobody waits on the answer.
            if (v.browser) |b| if (session.send(b, "Profiler.disable", null, method_timeout_ms, .memory, "")) |id| session.forget(id) else |_| {};
        },
        else => unreachable,
    }
    for (job.ids[0..job.n]) |id| session.forget(id);
    return true;
}
