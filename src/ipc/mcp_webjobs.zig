//! Web calls on different tabs, served concurrently over one connection.
//!
//! Every browser-group call (but `web_fetch`, which has its own queue)
//! with a request id goes through here while this server drives its own
//! headless browser (`mcp_web.concurrentCalls`). A call that may start
//! (`webjobs.mayStart`: nothing earlier and unanswered addresses its tab)
//! runs at once; one that answers at once is answered like any call, and
//! one that waits on a page (`mcp_web.Pending`: web_open, web_navigate,
//! web_wait, web_eval) is DEFERRED and stepped by `service` between
//! requests, answered through `mcp.replyLater`. A call that may not start
//! yet is queued and started by `service` once the calls before it on its
//! tab have answered. So N tabs each waiting T answer in about T, while
//! calls on one tab keep their order.

const std = @import("std");
const mcp = @import("mcp.zig");
const web = @import("mcp_web.zig");
const webjobs = @import("webjobs.zig");
const jsonclone = @import("../util/jsonclone.zig");

const gpa = std.heap.c_allocator;

/// How often the server loop wakes while a call waits and none says
/// sooner.
const TICK_MS: i64 = 40;

const Job = struct {
    arena_state: std.heap.ArenaAllocator,
    /// The request id, as JSON text, the reply carries.
    id_json: []const u8,
    backend: mcp.Backend,
    name: []const u8,
    args: std.json.Value,
    scope: webjobs.Scope,
    pending: ?web.Pending = null,

    fn arena(self: *Job) std.mem.Allocator {
        return self.arena_state.allocator();
    }
};

/// Unanswered calls, oldest first.
var g_jobs: std.ArrayList(*Job) = .empty;

/// Calls that answer from state at hand and address no tab: they never
/// wait behind the deferred ones.
fn unordered(name: []const u8) bool {
    return std.mem.eql(u8, name, "web_tabs") or std.mem.eql(u8, name, "web_diagnostic") or
        std.mem.eql(u8, name, "web_route_exit");
}

/// The handle a call names (`pane`, or its synonym `view`).
fn handleOf(args: std.json.Value) ?u32 {
    const v = mcp.argInt(args, "pane") orelse mcp.argInt(args, "view") orelse return null;
    return std.math.cast(u32, v);
}

/// Whether `call` goes through here: a request (with an id) on this
/// server's own headless browser.
pub fn applies(name: []const u8, id: ?std.json.Value) bool {
    return id != null and !unordered(name) and web.concurrentCalls();
}

/// Start a call: answer it now when it may start and does not wait,
/// else defer it.
pub fn start(arena: std.mem.Allocator, backend: mcp.Backend, name: []const u8, args: std.json.Value, id: std.json.Value) !mcp.Called {
    const job = try gpa.create(Job);
    job.* = .{
        .arena_state = std.heap.ArenaAllocator.init(gpa),
        .id_json = "",
        .backend = backend,
        .name = "",
        .args = .null,
        // A label addresses its tabs by name: ordered against everything.
        .scope = if (mcp.argStr(args, "label") != null and !std.mem.eql(u8, name, "web_open")) .all else webjobs.scopeOf(name, handleOf(args)),
    };
    var queued = false;
    defer if (!queued) drop(job);
    const ar = job.arena();
    var aw: std.Io.Writer.Allocating = .init(ar);
    try std.json.Stringify.value(id, .{}, &aw.writer);
    job.id_json = aw.written();
    job.name = try ar.dupe(u8, name);
    job.args = try jsonclone.clone(ar, args);

    try g_jobs.ensureUnusedCapacity(gpa, 1);
    g_jobs.appendAssumeCapacity(job);
    errdefer _ = g_jobs.pop();
    if (!mayStart(g_jobs.items.len - 1)) {
        queued = true;
        return .deferred;
    }
    if (try run(job)) |reply| {
        const out = try arena.dupe(u8, reply);
        _ = g_jobs.pop();
        return .{ .reply = out };
    }
    queued = true;
    return .deferred;
}

/// Start a job's call; its reply when it answered at once, null when it
/// now waits (`job.pending`).
fn run(job: *Job) !?[]const u8 {
    switch (try web.webCall(job.arena(), job.backend, job.name, job.args)) {
        .reply => |r| return r,
        .pending => |p| {
            job.pending = p;
            web.touchTab(p.pane);
            return null;
        },
    }
}

fn mayStart(index: usize) bool {
    var scopes: [64]webjobs.Scope = undefined;
    // More unanswered calls than that: the oldest 64 decide, the rest
    // wait (a client that deep is pipelining far past any tab count).
    if (index >= scopes.len) return false;
    for (g_jobs.items[0 .. index + 1], 0..) |j, i| scopes[i] = j.scope;
    return webjobs.mayStart(scopes[0 .. index + 1], index);
}

pub fn active() bool {
    return g_jobs.items.len > 0;
}

/// Milliseconds until the server loop must call `service`; null idle.
pub fn dueInMs(_: i64) ?i64 {
    var due: ?i64 = null;
    for (g_jobs.items) |j| {
        const p = j.pending orelse continue;
        const ms: i64 = p.pollMs();
        due = if (due) |d| @min(d, ms) else ms;
    }
    if (due == null and active()) due = TICK_MS;
    return due;
}

/// Step every waiting call, start queued ones whose turn came, answer
/// what finished. Server loop only.
pub fn service() void {
    web.pumpEngines();
    var i: usize = 0;
    while (i < g_jobs.items.len) {
        const job = g_jobs.items[i];
        const reply: ?[]const u8 = if (job.pending) |*p| blk: {
            web.touchTab(p.pane);
            break :blk p.step(job.arena()) catch |err| {
                // The call ends here: release what it holds, so an
                // unfinished web_open closes the tab nobody learned about.
                p.abandon();
                break :blk failed(job, err);
            };
        } else if (mayStart(i))
            run(job) catch |err| failed(job, err)
        else
            null;
        const r = reply orelse {
            i += 1;
            continue;
        };
        answer(job, r);
        _ = g_jobs.orderedRemove(i);
        drop(job);
        // A call queued behind this one may start now: scan again from
        // the front, in order.
        i = 0;
    }
}

/// A call that failed outright answers the way `mcp.callTool` does.
fn failed(job: *Job, err: anyerror) []const u8 {
    const msg = std.fmt.allocPrint(job.arena(), "tool failed: {s}", .{@errorName(err)}) catch return "";
    return mcp.errRes(job.arena(), .failed, msg) catch "";
}

fn answer(job: *Job, reply: []const u8) void {
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    mcp.replyLater(scratch.allocator(), job.id_json, reply);
}

fn drop(job: *Job) void {
    job.arena_state.deinit();
    gpa.destroy(job);
}

/// The client cancelled request `rid`: release what its call holds and
/// forget it, unanswered (MCP cancellation).
pub fn cancel(arena: std.mem.Allocator, rid: std.json.Value) void {
    var aw: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(rid, .{}, &aw.writer) catch return;
    const key = aw.written();
    for (g_jobs.items, 0..) |job, i| {
        if (!std.mem.eql(u8, job.id_json, key)) continue;
        if (job.pending) |*p| p.abandon();
        _ = g_jobs.orderedRemove(i);
        drop(job);
        return;
    }
}

/// Forget every call unanswered; part of server teardown, before the
/// browsers go.
pub fn shutdown() void {
    for (g_jobs.items) |job| {
        if (job.pending) |*p| p.abandon();
        drop(job);
    }
    g_jobs.clearAndFree(gpa);
}

/// What `capabilities` reports as `web_concurrent_tabs`.
pub fn capability() struct {
    /// Calls on different tabs run concurrently; calls on one tab, and
    /// calls naming no tab, keep their order.
    available: bool,
    /// The tools whose waiting overlaps; every other web tool answers at
    /// once, after the earlier calls on its tab.
    waiting_tools: []const []const u8 = &.{ "web_open", "web_navigate", "web_wait", "web_eval" },
    in_flight: usize,
} {
    var n: usize = 0;
    for (g_jobs.items) |j| {
        if (j.pending != null) n += 1;
    }
    return .{ .available = web.concurrentCalls(), .in_flight = n };
}
