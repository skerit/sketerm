//! `web_fetch`: the content of several urls, read through real browser
//! tabs the caller never sees. Each url gets a BACKGROUND view
//! (`webdrive.Engine.openViewBackground`): never a tab, never a target,
//! never presented, closed as soon as its result is read.
//!
//! The call is DEFERRED: `start` queues it and returns, the server loop
//! calls `service` between requests, and the reply goes out through
//! `mcp.replyLater` once every url has an answer. That is what lets two
//! concurrent calls share the instance-wide tab budget (`webfetch.Queue`)
//! instead of running one after the other, and keeps every other tool
//! answering while a fetch waits on slow pages.
//!
//! Everything a url produces is read with the machinery the tab tools
//! use: the navigation fact (`mcp_web.navOf`), reader mode
//! (`mcp_web.readerOp`), the document source (`mcp_web.sourceOf`: a
//! capture's response body, else the DOM), downloads through the engine's download
//! path, and `web_open`'s `wait` (`mcp_web.WaitProbe`, stepped here).

const std = @import("std");
const mcp = @import("mcp.zig");
const web = @import("mcp_web.zig");
const webdrive = @import("webdrive.zig");
const webfetch = @import("webfetch.zig");
const webread = @import("webread.zig");
const webpersist = @import("webpersist.zig");
const webnav = @import("webnav.zig");
const filter = @import("../web/filter.zig");
const clock = @import("../util/clock.zig");
const pathz = @import("../util/pathz.zig");
const mcp_term = @import("mcp_term.zig");

const gpa = std.heap.c_allocator;

/// How often the server loop wakes while a fetch runs.
const TICK_MS: i64 = 40;
/// Fetch views render at this size; nobody looks at them.
const VIEW_W: u16 = 1280;
const VIEW_H: u16 = 800;

var g_queue: webfetch.Queue = .{};
var g_jobs: std.ArrayList(*Job) = .empty;
var g_next_call: u64 = 1;

/// `web_fetch_max_tabs` from config; null keeps the default.
pub fn configure(max_tabs: ?u16) void {
    g_queue.cap = std.math.clamp(max_tabs orelse webfetch.DEFAULT_MAX_TABS, 1, webfetch.MAX_MAX_TABS);
}

/// What `capabilities` reports as `web_fetch`.
pub fn capability() struct {
    available: bool,
    reason: ?[]const u8,
    per_call_tabs: u16 = webfetch.PER_CALL_TABS,
    max_tabs: u16,
    max_urls: usize = webfetch.MAX_URLS,
    modes: []const []const u8 = fetchModeNames(),
    statuses: []const []const u8 = web.enumNames(webfetch.Status),
    /// The running helper keeps fetch tabs out of every viewer and can
    /// refuse redirects (view-flags); null before it starts.
    background_tabs: ?bool,
    in_flight: u16,
    queued: usize,
    /// Fetch views the engine holds right now (a tab outliving its
    /// result would show here).
    open_tabs: usize,
} {
    var bg: ?bool = null;
    var open_tabs: usize = 0;
    if (!web.guiDrivesWeb()) if (web.headlessEngine()) |e| {
        if (e.state == .ready) bg = e.backgroundHonoured();
        open_tabs = e.views.items.len - e.tabCount();
    };
    var queued: usize = 0;
    for (g_queue.calls.items) |cl| queued += cl.total - cl.next;
    return .{
        .available = unavailableReason() == null,
        .reason = unavailableReason(),
        .max_tabs = g_queue.cap,
        .background_tabs = bg,
        .in_flight = g_queue.running,
        .queued = queued,
        .open_tabs = open_tabs,
    };
}

fn unavailableReason() ?[]const u8 {
    if (web.guiDrivesWeb()) return "web_fetch runs on this server's own headless browser; with the user's GUI browser (web_gui or --shared) its tabs would be the user's";
    if (web.instanceDir() == null) return "this server has no headless browser (no instance directory)";
    return null;
}

pub fn active() bool {
    return g_jobs.items.len > 0;
}

/// Milliseconds until the server loop must call `service`; null idle.
pub fn dueInMs(_: i64) ?i64 {
    return if (active()) TICK_MS else null;
}

/// The modes `web_fetch` takes (`webread.Mode.fetchable`).
fn fetchModeNames() []const []const u8 {
    comptime {
        var out: []const []const u8 = &.{};
        for (std.enums.values(webread.Mode)) |m| {
            if (m.fetchable()) out = out ++ [_][]const u8{@tagName(m)};
        }
        return out;
    }
}

const Opts = struct {
    mode: webread.Mode = .text,
    /// Set for mode regex.
    regex: ?webread.RegexOpts = null,
    max_chars: usize = webread.DEFAULT_MAX_CHARS,
    follow: bool = true,
    timeout_ms: i64 = webfetch.DEFAULT_TIMEOUT_MS,
    to_dir: ?[]const u8 = null,
    wait: ?web.NavWait = null,
};

/// One url's result, as the reply's `results[]` carries it.
const Row = struct {
    index: usize,
    url: []const u8,
    status: webfetch.Status = .done,
    navigation: ?webnav.Nav = null,
    kind: ?webfetch.Kind = null,
    body: ?[]const u8 = null,
    body_source: ?webread.BodySource = null,
    truncated: bool = false,
    bytes: u64 = 0,
    path: ?[]const u8 = null,
    /// Whether `path` survives this MCP instance; null without a file.
    outlives_instance: ?bool = null,
    content_type: ?[]const u8 = null,
    matches: []const webread.Match = &.{},
    match_count: usize = 0,
    matches_capped: bool = false,
    wait: ?web.WaitReport = null,
    @"error": ?[]const u8 = null,
    queued_ms: i64 = 0,
    elapsed_ms: i64 = 0,
};

const Phase = enum { queued, loading, waiting, downloading, done };

const Item = struct {
    phase: Phase = .queued,
    view: u32 = 0,
    enqueued_ms: i64,
    started_ms: i64 = 0,
    deadline: i64 = 0,
    probe: ?web.WaitProbe = null,
    next_poll_ms: i64 = 0,
    /// The download this url became, once known: the engine's request
    /// id (a page-initiated one gets one too).
    dl_req: ?u32 = null,
    row: Row,
};

const Job = struct {
    arena_state: std.heap.ArenaAllocator,
    call: u64,
    /// The request id, as JSON text, the reply carries.
    id_json: []const u8,
    opts: Opts,
    items: []Item,
    /// Paths handed out in this call's directories.
    used: std.StringHashMapUnmanaged(void) = .empty,
    /// Where files land: `to_dir`, else the instance's fetch directory.
    file_dir: []const u8,
    background_honoured: bool = true,

    fn arena(self: *Job) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    fn done(self: *const Job) bool {
        for (self.items) |it| if (it.phase != .done) return false;
        return true;
    }
};

fn refuse(arena: std.mem.Allocator, code: mcp.ErrCode, msg: []const u8) !mcp.Called {
    return .{ .reply = try mcp.errRes(arena, code, msg) };
}

/// Validate a call and queue it; nothing opens before every argument
/// checked out.
pub fn start(arena: std.mem.Allocator, id: ?std.json.Value, args: std.json.Value) !mcp.Called {
    const rid = id orelse return refuse(arena, .invalid_args, "web_fetch must be a request with an id: its answer arrives after the urls are read");
    if (unavailableReason()) |why| return refuse(arena, .unavailable, why);
    const urls_v = mcp.argValue(args, "urls") orelse return refuse(arena, .invalid_args, "web_fetch needs 'urls': an array of http(s) urls");
    if (urls_v != .array or urls_v.array.items.len == 0)
        return refuse(arena, .invalid_args, "'urls' must be a non-empty array of url strings");
    if (urls_v.array.items.len > webfetch.MAX_URLS)
        return refuse(arena, .invalid_args, try std.fmt.allocPrint(arena, "'urls' holds {d} entries; the cap is {d} per call", .{ urls_v.array.items.len, webfetch.MAX_URLS }));
    for (urls_v.array.items) |u| if (u != .string) return refuse(arena, .invalid_args, "'urls' must hold url STRINGS");

    var opts: Opts = .{};
    if (mcp.argStr(args, "mode")) |m| {
        const mode = std.meta.stringToEnum(webread.Mode, m);
        if (mode == null or !mode.?.fetchable()) return refuse(arena, .invalid_args, "'mode' must be text, raw or regex (the element lists are web_read's, on a tab)");
        opts.mode = mode.?;
    }
    switch (try web.parseRegexArgs(arena, args, opts.mode == .regex)) {
        .none => {},
        .err => |why| return refuse(arena, .invalid_args, why),
        .regex => |r| opts.regex = r,
    }
    opts.max_chars = web.argClamped(args, "max_chars", webread.DEFAULT_MAX_CHARS, webread.MAX_MAX_CHARS);
    if (mcp.argValue(args, "follow_redirects")) |f| {
        if (f != .bool) return refuse(arena, .invalid_args, "'follow_redirects' must be a boolean");
        opts.follow = f.bool;
    }
    opts.timeout_ms = mcp.waitCap(mcp.argInt(args, "timeout_ms"), webfetch.DEFAULT_TIMEOUT_MS);
    if (opts.timeout_ms < 1000) opts.timeout_ms = 1000;
    if (mcp.argStr(args, "to_dir")) |d| {
        if (d.len == 0 or d[0] != '/') return refuse(arena, .invalid_args, "'to_dir' must be an ABSOLUTE directory on the machine running this MCP server");
        if (opts.mode == .regex) return refuse(arena, .invalid_args, "mode regex returns its matches inline; 'to_dir' writes bodies (mode text or raw)");
        opts.to_dir = d;
    }
    opts.wait = switch (web.parseNavWait(args)) {
        .none => null,
        .err => |f| return .{ .reply = try web.failRes(arena, f) },
        .wait => |w| w,
    };

    const job = try gpa.create(Job);
    job.* = .{
        .arena_state = std.heap.ArenaAllocator.init(gpa),
        .call = g_next_call,
        .id_json = "",
        .opts = opts,
        .items = &.{},
        .file_dir = "",
    };
    errdefer {
        job.arena_state.deinit();
        gpa.destroy(job);
    }
    const ar = job.arena();
    var aw: std.Io.Writer.Allocating = .init(ar);
    try std.json.Stringify.value(rid, .{}, &aw.writer);
    job.id_json = aw.written();
    if (opts.regex) |r| job.opts.regex.?.pattern = try ar.dupe(u8, r.pattern);
    if (opts.to_dir) |d| job.opts.to_dir = try ar.dupe(u8, std.mem.trimEnd(u8, d, "/"));
    if (opts.wait) |w| job.opts.wait.?.arg = try ar.dupe(u8, w.arg);
    job.file_dir = job.opts.to_dir orelse try std.fmt.allocPrint(ar, "{s}/web-fetch", .{web.instanceDir().?});
    const now = clock.nowMs();
    job.items = try ar.alloc(Item, urls_v.array.items.len);
    for (job.items, urls_v.array.items, 0..) |*it, u, i| {
        it.* = .{ .enqueued_ms = now, .row = .{ .index = i, .url = try ar.dupe(u8, u.string) } };
        if (!webfetch.httpUrl(u.string)) {
            it.phase = .done;
            it.row.status = .invalid_url;
            it.row.@"error" = "not an http(s) url; nothing was opened";
        }
    }
    try g_jobs.ensureUnusedCapacity(gpa, 1);
    try g_queue.addCall(gpa, job.call, @intCast(job.items.len));
    g_jobs.appendAssumeCapacity(job);
    g_next_call += 1;
    return .deferred;
}

/// Advance every fetch: step the open tabs, hand free tabs to waiting
/// urls, answer the calls that are complete. Server loop only.
pub fn service() void {
    var scratch_state = std.heap.ArenaAllocator.init(gpa);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    const e_opt = web.headlessEngine();
    if (e_opt) |e| e.pumpOnce(0);
    for (g_jobs.items) |job| {
        for (job.items) |*it| {
            const e = e_opt orelse {
                if (it.phase != .queued and it.phase != .done) failItem(job, it, null, "the headless browser is gone");
                continue;
            };
            step(job, it, e, scratch) catch |err| failItem(job, it, e, @errorName(err));
            _ = scratch_state.reset(.retain_capacity);
        }
    }
    while (g_queue.admit()) |a| {
        const job = findJob(a.call) orelse continue;
        const it = &job.items[a.index];
        if (it.phase == .done) {
            // An invalid url holds a turn but never a tab.
            g_queue.finish(job.call);
            continue;
        }
        const e = e_opt orelse {
            failItem(job, it, null, "no headless browser is configured");
            continue;
        };
        open(job, it, e) catch |err| {
            // The same sentences the tab tools give for a helper failure.
            const f = web.headlessFail(job.arena(), e, err) catch web.fail(.io_failed, @errorName(err));
            failItem(job, it, e, f.text);
        };
    }
    var i: usize = 0;
    while (i < g_jobs.items.len) {
        const job = g_jobs.items[i];
        if (!job.done()) {
            i += 1;
            continue;
        }
        answer(job) catch {};
        _ = g_jobs.orderedRemove(i);
        dropJob(job);
    }
}

fn findJob(call: u64) ?*Job {
    for (g_jobs.items) |j| if (j.call == call) return j;
    return null;
}

fn dropJob(job: *Job) void {
    g_queue.removeCall(job.call);
    job.arena_state.deinit();
    gpa.destroy(job);
}

/// The client cancelled request `rid`: close its tabs and forget it.
pub fn cancel(arena: std.mem.Allocator, rid: std.json.Value) void {
    var aw: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(rid, .{}, &aw.writer) catch return;
    const key = aw.written();
    for (g_jobs.items, 0..) |job, i| {
        if (!std.mem.eql(u8, job.id_json, key)) continue;
        closeAll(job);
        _ = g_jobs.orderedRemove(i);
        dropJob(job);
        return;
    }
}

/// Close every fetch tab; part of server teardown.
pub fn shutdown() void {
    for (g_jobs.items) |job| {
        closeAll(job);
        dropJob(job);
    }
    g_jobs.clearAndFree(gpa);
    g_queue.deinit(gpa);
}

fn closeAll(job: *Job) void {
    const e = web.headlessEngine();
    for (job.items) |*it| {
        if (it.phase == .queued or it.phase == .done) continue;
        if (e) |eng| eng.closeView(it.view);
        g_queue.finish(job.call);
        it.phase = .done;
        it.row.status = .cancelled;
    }
}

/// The tab records its own document, and nothing else.
fn captureFilter() webdrive.CaptureFilter {
    return .{ .types = filter.RType.document.bit() };
}

fn open(job: *Job, it: *Item, e: *webdrive.Engine) !void {
    const now = clock.nowMs();
    it.row.queued_ms = now - it.enqueued_ms;
    it.started_ms = now;
    it.deadline = now + job.opts.timeout_ms;
    pathz.makeDirs(job.file_dir, 0o700) catch {};
    // The capture is how raw and plain-text bodies are read; a helper
    // without it still fetches, through the DOM.
    const cap: ?webdrive.CaptureFilter = if (e.state != .ready or e.has(.capture)) captureFilter() else null;
    const v = e.openViewBackground(it.row.url, VIEW_W, VIEW_H, if (cap) |*f| f else null, .{
        .no_redirect = !job.opts.follow,
        .download_dir = job.file_dir,
    }) catch |err| switch (err) {
        error.CaptureUnsupported => try e.openViewBackground(it.row.url, VIEW_W, VIEW_H, null, .{
            .no_redirect = !job.opts.follow,
            .download_dir = job.file_dir,
        }),
        else => return err,
    };
    it.view = v.id;
    it.phase = .loading;
    job.background_honoured = job.background_honoured and e.backgroundHonoured();
}

fn step(job: *Job, it: *Item, e: *webdrive.Engine, scratch: std.mem.Allocator) !void {
    const now = clock.nowMs();
    switch (it.phase) {
        .queued, .done => {},
        .loading => {
            const v = e.findView(it.view) orelse return failItem(job, it, e, "the fetch tab vanished (the browser helper restarted?)");
            if (v.create_failed) |why| return failItem(job, it, e, try job.arena().dupe(u8, why));
            if (web.downloadSince(e, it.view, it.started_ms)) {
                it.phase = .downloading;
                return;
            }
            const rec = try web.viewRecord(scratch, e, v, false);
            if (rec.loadBlocked()) return finish(job, it, e);
            if (web.openSettled(rec, false)) {
                if (job.opts.wait) |w| {
                    // The wait reads the view through the job's arena:
                    // its result outlives this tick.
                    const settled = try web.viewRecord(job.arena(), e, v, false);
                    switch (try web.WaitProbe.init(.{ .headless = e }, job.arena(), settled, w.what, w.arg, @min(w.budget, it.deadline - now))) {
                        .done => |o| {
                            it.row.wait = web.navWaitReport(w, o, settled, 0).report;
                            return finish(job, it, e);
                        },
                        .probe => |p| {
                            it.probe = p;
                            it.phase = .waiting;
                            return;
                        },
                    }
                }
                return finish(job, it, e);
            }
            if (now >= it.deadline) {
                it.row.status = .timed_out;
                return finish(job, it, e);
            }
        },
        .waiting => {
            if (now < it.next_poll_ms) return;
            it.next_poll_ms = now + @as(i64, web.WaitProbe.POLL_MS);
            const p = &it.probe.?;
            const w = job.opts.wait.?;
            const out = (try p.step(job.arena())) orelse blk: {
                if (now < p.deadline) return;
                break :blk try p.expired(job.arena());
            };
            it.row.wait = web.navWaitReport(w, out, p.view, now - p.started).report;
            it.probe = null;
            return finish(job, it, e);
        },
        .downloading => {
            const d = downloadOf(e, it) orelse {
                if (now >= it.deadline) {
                    it.row.status = .timed_out;
                    it.row.@"error" = "the download was offered but never started";
                    return close(job, it, e);
                }
                return;
            };
            if (d.terminal()) return fileDone(job, it, e, d);
            if (now >= it.deadline) {
                it.row.status = .timed_out;
                it.row.path = try job.arena().dupe(u8, d.path);
                it.row.bytes = d.received;
                it.row.@"error" = "the download had not finished inside the timeout; it was cancelled with the tab";
                e.cancelDownload(d.req);
                return close(job, it, e);
            }
        },
    }
}

/// The download this url became: the one this fetch started, else the
/// newest the page started.
fn downloadOf(e: *webdrive.Engine, it: *Item) ?*const webdrive.Download {
    if (it.dl_req) |req| return e.download(req);
    var found: ?*const webdrive.Download = null;
    for (e.downloadList()) |*d| {
        if (d.view == it.view and d.started_ms >= it.started_ms) found = d;
    }
    if (found) |d| it.dl_req = d.req;
    return found;
}

/// The navigation settled (or failed, or ran out of time): read what it
/// produced, then close the tab.
fn finish(job: *Job, it: *Item, e: *webdrive.Engine) !void {
    const ar = job.arena();
    const drv: web.Driver = .{ .headless = e };
    const v = e.findView(it.view) orelse return failItem(job, it, e, "the fetch tab vanished before it could be read");
    const rec = try web.viewRecord(ar, e, v, false);
    switch (try web.navOf(drv, ar, rec, 0, it.row.url, it.started_ms)) {
        .nav => |n| it.row.navigation = n,
        .unavailable => |why| it.row.@"error" = why,
    }
    const nav = it.row.navigation orelse {
        if (it.row.status == .done) it.row.status = .failed;
        return close(job, it, e);
    };
    switch (nav.outcome) {
        .download => {
            it.phase = .downloading;
            return;
        },
        .page, .http_error => {},
        .redirect => return close(job, it, e),
        // A file the engine streams into its own viewer (a PDF) settles
        // the view while its request is still open: the content type is
        // enough to fetch it as a file.
        .pending => if (it.row.status != .done or webfetch.kindOf(nav.content_type orelse "") != .file) {
            it.row.status = .timed_out;
            return close(job, it, e);
        },
        .network_error, .aborted, .replaced, .blocked, .non_http, .no_request => {
            if (it.row.status == .done) it.row.status = .failed;
            if (it.row.@"error" == null) it.row.@"error" = try std.fmt.allocPrint(ar, "the navigation ended {s}{s}{s}", .{ @tagName(nav.outcome), if (nav.@"error" != null) ": " else "", nav.@"error" orelse "" });
            return close(job, it, e);
        },
    }
    if (it.row.status != .done) return close(job, it, e);
    const kind = webfetch.kindOf(nav.content_type orelse "");
    it.row.kind = kind;
    it.row.content_type = nav.content_type;
    if (kind == .file) {
        // A file the engine shows as a page (a PDF): fetch it again
        // through the download path, inside this tab's session.
        const path = try web.batchPath(ar, &job.used, job.file_dir, try web.nameFromUrl(ar, nav.url));
        it.dl_req = e.startDownload(it.view, nav.url, path) catch |err| {
            it.row.status = .failed;
            it.row.@"error" = try std.fmt.allocPrint(ar, "the file could not be downloaded ({s})", .{@errorName(err)});
            return close(job, it, e);
        };
        it.phase = .downloading;
        return;
    }
    try readBody(job, it, e, kind, nav);
    return close(job, it, e);
}

/// The text or raw body of a page or text document, inline or to_dir.
fn readBody(job: *Job, it: *Item, e: *webdrive.Engine, kind: webfetch.Kind, nav: webnav.Nav) !void {
    const ar = job.arena();
    const o = job.opts;
    // Plain text, XML and JSON ARE their body; a page reads as reader
    // mode unless the caller asked for its source.
    const want_raw = kind == .text or o.mode == .raw or (o.regex != null and o.regex.?.in == .raw);
    const got: web.Source = if (want_raw)
        try web.sourceOf(.{ .headless = e }, ar, it.view, kind == .text, @max(it.deadline, clock.nowMs() + 3000))
    else
        try readerText(e, ar, it);
    const body = switch (got) {
        .err => |why| {
            it.row.status = .failed;
            it.row.@"error" = why;
            return;
        },
        .ok => |b| b,
    };
    it.row.body_source = body.source;
    it.row.bytes = body.text.len;
    // The page serializer's own cut is a cut too.
    it.row.truncated = body.truncated;
    if (o.regex) |rx| {
        const m = try webread.findMatches(ar, body.text, rx.pattern, .{ .ignore_case = rx.ignore_case, .context = rx.context, .max = rx.max_matches });
        it.row.matches = m.items;
        it.row.match_count = m.total;
        it.row.matches_capped = m.capped;
        return;
    }
    if (o.to_dir) |dir| {
        var name = try web.nameFromUrl(ar, nav.url);
        if (body.source == .reader) {
            name = try std.fmt.allocPrint(ar, "{s}.md", .{name});
        } else if (std.mem.indexOfScalar(u8, name, '.') == null) {
            name = try std.fmt.allocPrint(ar, "{s}{s}", .{ name, web.extensionFor(nav.content_type orelse "text/html", "utf8") });
        }
        const path = try web.batchPath(ar, &job.used, dir, name);
        pathz.makeDirs(dir, 0o700) catch {};
        switch (try web.writeBodyFile(ar, path, body.text)) {
            .err => |f| {
                it.row.status = .failed;
                it.row.@"error" = f.text;
            },
            .sha => it.row.path = path,
        }
        return;
    }
    const cut = webread.truncate(body.text, o.max_chars);
    it.row.body = cut.text;
    it.row.truncated = it.row.truncated or cut.truncated;
}

fn readerText(e: *webdrive.Engine, ar: std.mem.Allocator, it: *Item) !web.Source {
    const budget = @max(it.deadline - clock.nowMs(), 3000);
    return switch (try web.readerOp(.{ .headless = e }, ar, it.view, budget)) {
        .err => |f| .{ .err = f.text },
        .legacy => |md| .{ .ok = .{ .text = md, .source = .reader } },
        .rich => |parsed| blk: {
            defer parsed.deinit();
            break :blk .{ .ok = .{ .text = try ar.dupe(u8, parsed.value.markdown), .source = .reader } };
        },
    };
}

fn fileDone(job: *Job, it: *Item, e: *webdrive.Engine, d: *const webdrive.Download) !void {
    const ar = job.arena();
    it.row.kind = .file;
    if (d.path.len > 0) it.row.path = try ar.dupe(u8, d.path);
    if (d.mime.len > 0) it.row.content_type = try ar.dupe(u8, d.mime);
    if (d.done) {
        it.row.bytes = mcp_term.fileSize(d.path) orelse d.received;
    } else {
        it.row.status = .failed;
        it.row.bytes = d.received;
        it.row.@"error" = if (d.fail_reason.len > 0) d.fail_reason else "the browser engine did not complete the transfer";
    }
    // A download the navigation itself became has no navigation fact
    // read yet.
    if (it.row.navigation == null) {
        if (e.findView(it.view)) |v| {
            const rec = try web.viewRecord(ar, e, v, false);
            switch (try web.navOf(.{ .headless = e }, ar, rec, 0, it.row.url, it.started_ms)) {
                .nav => |n| it.row.navigation = n,
                .unavailable => {},
            }
        }
    }
    if (it.row.content_type == null) if (it.row.navigation) |n| {
        it.row.content_type = n.content_type;
    };
    return close(job, it, e);
}

fn failItem(job: *Job, it: *Item, e: ?*webdrive.Engine, why: []const u8) void {
    it.row.status = .failed;
    if (it.row.@"error" == null) it.row.@"error" = why;
    if (it.phase == .queued) {
        it.phase = .done;
        g_queue.finish(job.call);
        return;
    }
    if (it.phase == .done) return;
    close(job, it, e);
}

/// The url has its answer: its tab closes and frees a fetch slot.
fn close(job: *Job, it: *Item, e: ?*webdrive.Engine) void {
    if (it.view != 0) if (e) |eng| eng.closeView(it.view);
    it.row.elapsed_ms = clock.nowMs() - it.started_ms;
    it.phase = .done;
    g_queue.finish(job.call);
}

fn answer(job: *Job) !void {
    const ar = job.arena();
    var res = mcp.Res.init(ar);
    var counts = std.enums.EnumArray(webfetch.Status, usize).initFill(0);
    var rows = try ar.alloc(Row, job.items.len);
    var queued_max: i64 = 0;
    var any_body = false;
    var lost_files: usize = 0;
    for (job.items, 0..) |it, i| {
        rows[i] = it.row;
        if (rows[i].path) |p| {
            const keeps = try web.outlives(ar, p);
            rows[i].outlives_instance = keeps;
            if (!keeps) lost_files += 1;
        }
        counts.getPtr(it.row.status).* += 1;
        queued_max = @max(queued_max, it.row.queued_ms);
        if (it.row.body != null or it.row.matches.len > 0) any_body = true;
    }
    const peak: u16 = if (g_queue.call(job.call)) |cl| cl.peak else 0;
    try res.fact("results", rows);
    try res.fact("count", rows.len);
    try res.fact("done", counts.get(.done));
    try res.fact("failed", counts.get(.failed));
    try res.fact("timed_out", counts.get(.timed_out));
    try res.fact("invalid_url", counts.get(.invalid_url));
    try res.fact("per_call_tabs", webfetch.PER_CALL_TABS);
    try res.fact("max_tabs", g_queue.cap);
    try res.fact("peak_tabs", peak);
    try res.fact("queued_ms_max", queued_max);
    try res.fact("background_tabs", job.background_honoured);
    // The fetch tabs browse in the engine's default identity: whatever a
    // site sets lands in that jar.
    const persist = try web.enginePersistence(ar, web.headlessEngine(), .default, "", 0);
    try res.fact("persistence", persist);
    try res.textf("web_fetch: {d} url(s): {d} done, {d} failed, {d} timed out, {d} invalid; at most {d} tab(s) of this call open at once (per call {d}, server-wide {d}); the longest queue wait {d}ms", .{
        rows.len, counts.get(.done), counts.get(.failed), counts.get(.timed_out), counts.get(.invalid_url),
        peak, webfetch.PER_CALL_TABS, g_queue.cap, queued_max,
    });
    try res.textf("fetch tabs browse in the default identity: {s}", .{try webpersist.sentence(ar, persist)});
    if (lost_files > 0)
        try res.textf("{d} saved file(s) {s} (to_dir keeps them)", .{ lost_files, webpersist.DIES_WITH_INSTANCE });
    if (!job.background_honoured)
        try res.text("this browser helper predates background tabs (view-flags): a user watching the assistant's browser may have seen the fetch tabs");
    for (rows) |r| {
        const nav_line: []const u8 = if (r.navigation) |n| try webnav.sentence(ar, n) else "no navigation";
        try res.textf("[{d}] {s}: {s}; {s}{s}{s}", .{ r.index, try web.clip(ar, r.url, web.URL_MAX), @tagName(r.status), nav_line, if (r.@"error" != null) "; " else "", r.@"error" orelse "" });
        if (r.path) |p| try res.textf("[{d}] {d} bytes at {s}", .{ r.index, r.bytes, p });
        if (job.opts.mode == .regex and r.status == .done and r.kind != .file) {
            try res.textf("[{d}] {d} match(es){s}", .{ r.index, r.match_count, if (r.matches_capped) " (more than shown)" else "" });
            try web.writeMatches(&res, r.matches);
        }
        if (r.body) |b| {
            try web.section(&res, try std.fmt.allocPrint(ar, "[{d}] {s}{s}", .{ r.index, @tagName(r.body_source.?), if (r.truncated) " (truncated)" else "" }), b);
        }
    }
    if (any_body) try res.text(web.TRUST_LINE);
    mcp.replyLater(ar, job.id_json, try res.finish());
}
