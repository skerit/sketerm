//! The ONE DevTools-protocol observer of a view: method results matched by message id with their payload, events, deadlines and detach.
//!
//! Registering it attaches nothing; the engine attaches an agent on the first
//! method sent. Nothing here may send `Runtime.enable` or `Debugger.enable`
//! (an attached inspector is what devtools detectors measure, see CLAUDE.md).

const std = @import("std");
const c = @import("cbindings");
const cef = @import("cef");
const host_mod = @import("../cefhost.zig");
const clock = @import("../../util/clock.zig");

/// Requests a session tracks at once; more are refused rather than evicting one.
pub const MAX_REQUESTS = 16;

/// Where a method's result payload goes.
pub const Sink = enum {
    /// Kept in memory, for small results.
    memory,
    /// Written to a fresh staging file as it arrives (a multi-MB profile never sits in a frame or a heap copy).
    staged,
};

pub const Outcome = union(enum) {
    pending,
    /// The result JSON (memory sink) or the staging file path (staged sink).
    ok: []const u8,
    failed: []const u8,
};

const Request = struct {
    id: c_int,
    deadline_ms: i64,
    sink: Sink,
    /// staged: which member of the result object to write (empty = the whole result).
    member: []const u8 = "",
    /// The method name, for failure reasons; a static string or empty.
    method: []const u8 = "",
    state: enum { pending, ok, failed } = .pending,
    /// When the engine answered, 0 while pending.
    answered_ms: i64 = 0,
    /// Owned: the result payload, a staging path, or a failure reason.
    data: []u8 = &.{},
    /// A static failure reason when `data` is empty.
    reason: []const u8 = "",
};

/// Receives every DevTools event of the session's browser while installed.
pub const EventSink = struct {
    ctx: *anyopaque,
    on_event: *const fn (ctx: *anyopaque, method: []const u8, params: []const u8) void,
};

/// CEF owns a transferred observer reference; the view owns another plus the registration.
pub const Session = struct {
    observer: cef.cef_dev_tools_message_observer_t,
    refs: std.atomic.Value(u32) = .init(2),
    gpa: std.mem.Allocator,
    registration: ?*cef.cef_registration_t = null,
    view: u32,
    browser_id: c_int,
    active: bool = true,
    browser_closed: bool = false,
    /// Agent detaches seen. CEF detaches when the inspected contents' agent host closes
    /// (`CefDevToolsController::AgentHostClosed`: the contents going away or every client forced off), and the next
    /// method attaches a FRESH agent without the old one's overrides or enabled domains, so an owner that retained
    /// state re-applies it when this moves; every request pending at the detach failed.
    detaches: u32 = 0,
    requests: std.ArrayList(Request) = .empty,
    events: ?EventSink = null,
    /// Receives `Page.fileChooserOpened` alone (`upload.zig`), apart from
    /// `events` so an upload and a trace never contend for the one sink.
    chooser: ?EventSink = null,
    /// Events received, for diagnostics.
    event_count: u32 = 0,

    pub fn create(gpa: std.mem.Allocator, browser: *cef.cef_browser_t, view: u32) !*Session {
        const bh: *cef.cef_browser_host_t = (browser.get_host orelse return error.DevToolsRefused)(browser) orelse return error.DevToolsRefused;
        defer host_mod.release(&bh.base);
        const add = bh.add_dev_tools_message_observer orelse return error.DevToolsRefused;
        const id = (browser.get_identifier orelse return error.DevToolsRefused)(browser);
        const self = try gpa.create(Session);
        self.* = .{
            .observer = .{
                .base = Ref.base(),
                .on_dev_tools_method_result = onResult,
                .on_dev_tools_event = onEvent,
                .on_dev_tools_agent_detached = onDetached,
            },
            .gpa = gpa,
            .view = view,
            .browser_id = id,
        };
        // add consumes one reference even when registration is refused.
        self.registration = add(bh, &self.observer);
        if (self.registration == null) {
            self.stop();
            return error.DevToolsRefused;
        }
        return self;
    }

    /// Submit `method` with `params_json` (null = no params); the id to poll with `outcome`.
    pub fn send(self: *Session, browser: *cef.cef_browser_t, method: []const u8, params_json: ?[]const u8, timeout_ms: i64, sink: Sink, member: []const u8) !c_int {
        if (!self.active or self.browser_closed) return error.DevToolsRefused;
        if (self.requests.items.len >= MAX_REQUESTS) return error.TooManyRequests;
        try self.requests.ensureUnusedCapacity(self.gpa, 1);
        const id = execute(browser, method, params_json);
        if (trace()) host_mod.logLine("devtools view={d} send {s} id={d}", .{ self.view, method, id });
        if (id <= 0) return error.DevToolsRefused;
        _ = self.track(id, timeout_ms, sink, member);
        if (self.findMut(id)) |r| r.method = method;
        return id;
    }

    /// Await the result of `id`, a method the caller executed itself; false when it cannot be tracked.
    pub fn track(self: *Session, id: c_int, timeout_ms: i64, sink: Sink, member: []const u8) bool {
        if (!self.active or id <= 0 or self.requests.items.len >= MAX_REQUESTS) return false;
        self.requests.append(self.gpa, .{ .id = id, .deadline_ms = clock.nowMs() + timeout_ms, .sink = sink, .member = member }) catch return false;
        return true;
    }

    /// When request `id` was answered; 0 while pending or unknown.
    pub fn answeredAt(self: *const Session, id: c_int) i64 {
        const r = self.find(id) orelse return 0;
        return r.answered_ms;
    }

    /// The state of request `id`; an unknown id reads as failed.
    pub fn outcome(self: *const Session, id: c_int) Outcome {
        const r = self.find(id) orelse return .{ .failed = "unknown DevTools request" };
        return switch (r.state) {
            .pending => .pending,
            .ok => .{ .ok = r.data },
            .failed => .{ .failed = if (r.data.len != 0) r.data else r.reason },
        };
    }

    /// Drop request `id`; a staged file nobody took is removed with it.
    pub fn forget(self: *Session, id: c_int) void {
        for (self.requests.items, 0..) |*r, i| if (r.id == id) {
            self.freeRequest(r, true);
            _ = self.requests.swapRemove(i);
            return;
        };
    }

    /// Hand a staged result's file to the caller: `forget` then leaves it alone.
    pub fn takeStaged(self: *Session, id: c_int) void {
        const r = self.findMut(id) orelse return;
        if (r.sink == .staged and r.state == .ok) r.sink = .memory;
    }

    /// Fail every pending request whose deadline passed.
    pub fn expire(self: *Session, now_ms: i64) void {
        for (self.requests.items) |*r| {
            if (r.state == .pending and now_ms >= r.deadline_ms) self.fail(r, "the DevTools method was not answered before its deadline");
        }
    }

    pub fn closed(self: *Session) void {
        self.browser_closed = true;
        for (self.requests.items) |*r| if (r.state == .pending) self.fail(r, "the browser closed before the DevTools method was answered");
    }

    pub fn stop(self: *Session) void {
        self.active = false;
        self.events = null;
        self.chooser = null;
        if (self.registration) |r| {
            self.registration = null;
            host_mod.release(&r.base);
        }
        host_mod.release(&self.observer.base);
    }

    pub fn destroyOwned(self: *Session) void {
        for (self.requests.items) |*r| self.freeRequest(r, true);
        self.requests.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    fn find(self: *const Session, id: c_int) ?*const Request {
        for (self.requests.items) |*r| if (r.id == id) return r;
        return null;
    }

    fn findMut(self: *Session, id: c_int) ?*Request {
        for (self.requests.items) |*r| if (r.id == id) return r;
        return null;
    }

    fn freeRequest(self: *Session, r: *Request, unlink: bool) void {
        if (r.data.len == 0) return;
        if (unlink and r.sink == .staged and r.state == .ok) {
            const z = self.gpa.dupeSentinel(u8, r.data, 0) catch null;
            if (z) |p| {
                _ = c.unlink(p.ptr);
                self.gpa.free(p);
            }
        }
        self.gpa.free(r.data);
        r.data = &.{};
    }

    fn fail(self: *Session, r: *Request, reason: []const u8) void {
        self.freeRequest(r, true);
        r.state = .failed;
        r.reason = reason;
        if (r.method.len != 0) r.data = std.fmt.allocPrint(self.gpa, "{s}: {s}", .{ r.method, reason }) catch &.{};
    }

    fn matches(self: *const Session, browser: [*c]cef.cef_browser_t) bool {
        if (!self.active or browser == null) return false;
        const get_id = browser.*.get_identifier orelse return false;
        return get_id(browser) == self.browser_id;
    }

    /// Record one method result; the payload is only valid during the call.
    pub fn deliver(self: *Session, id: c_int, success: bool, payload: []const u8) void {
        const r = self.findMut(id) orelse return;
        if (r.state != .pending) return;
        r.answered_ms = clock.nowMs();
        if (trace()) host_mod.logLine("devtools view={d} result id={d} success={d} bytes={d}", .{ self.view, id, @intFromBool(success), payload.len });
        if (!success) {
            const msg = errorMessage(payload);
            r.state = .failed;
            r.data = std.fmt.allocPrint(self.gpa, "the engine refused {s}: {s}", .{ if (r.method.len != 0) r.method else "the DevTools method", msg }) catch &.{};
            if (r.data.len == 0) r.reason = "the engine refused the DevTools method";
            return;
        }
        switch (r.sink) {
            .memory => {
                r.data = self.gpa.dupe(u8, payload) catch return self.fail(r, "out of memory keeping the DevTools result");
                r.state = .ok;
            },
            .staged => {
                const body = if (r.member.len != 0) memberSlice(payload, r.member) orelse payload else payload;
                var file = StagedFile.open("devtools") orelse return self.fail(r, "could not create a staging file for the DevTools result");
                if (!file.write(body)) {
                    file.abort();
                    return self.fail(r, "could not write the DevTools result to its staging file");
                }
                r.data = self.gpa.dupe(u8, file.finish()) catch {
                    _ = c.unlink(file.path().ptr);
                    return self.fail(r, "out of memory naming the staging file");
                };
                r.state = .ok;
            },
        }
    }

    fn onResult(arg: [*c]cef.cef_dev_tools_message_observer_t, browser: [*c]cef.cef_browser_t, id: c_int, success: c_int, result: ?*const anyopaque, size: usize) callconv(.c) void {
        defer host_mod.releaseArg(browser);
        const self = Ref.owner(@ptrCast(arg));
        if (!self.matches(browser) or id <= 0) return;
        const bytes: []const u8 = if (result) |p| @as([*]const u8, @ptrCast(p))[0..size] else "";
        self.deliver(id, success != 0, bytes);
    }

    fn onEvent(arg: [*c]cef.cef_dev_tools_message_observer_t, browser: [*c]cef.cef_browser_t, method: [*c]const cef.cef_string_t, params: ?*const anyopaque, size: usize) callconv(.c) void {
        defer host_mod.releaseArg(browser);
        const self = Ref.owner(@ptrCast(arg));
        if (!self.matches(browser)) return;
        self.event_count +|= 1;
        var name = host_mod.Utf8.init(method);
        defer name.free();
        if (trace()) host_mod.logLine("devtools view={d} event {s} bytes={d}", .{ self.view, name.slice(), size });
        // The agent outlives a renderer crash; what was pending there is never answered.
        if (std.mem.eql(u8, name.slice(), "Inspector.targetCrashed")) {
            for (self.requests.items) |*r| if (r.state == .pending) self.fail(r, "the page's renderer crashed");
        }
        if (self.chooser) |hook| if (std.mem.eql(u8, name.slice(), "Page.fileChooserOpened")) {
            const body: []const u8 = if (params) |p| @as([*]const u8, @ptrCast(p))[0..size] else "";
            hook.on_event(hook.ctx, name.slice(), body);
        };
        const sink = self.events orelse return;
        const bytes: []const u8 = if (params) |p| @as([*]const u8, @ptrCast(p))[0..size] else "";
        sink.on_event(sink.ctx, name.slice(), bytes);
    }

    fn onDetached(arg: [*c]cef.cef_dev_tools_message_observer_t, browser: [*c]cef.cef_browser_t) callconv(.c) void {
        defer host_mod.releaseArg(browser);
        const self = Ref.owner(@ptrCast(arg));
        if (!self.matches(browser)) return;
        if (trace()) host_mod.logLine("devtools view={d} agent detached", .{self.view});
        self.detaches +%= 1;
        for (self.requests.items) |*r| if (r.state == .pending) self.fail(r, "the DevTools agent detached before the method was answered");
    }
};

const Ref = host_mod.HeapRef(Session, "observer");

/// `SKETERM_WEB_DEVTOOLS_TRACE` logs every method, result and event of every session to stderr.
fn trace() bool {
    return c.getenv("SKETERM_WEB_DEVTOOLS_TRACE") != null;
}

/// Submit one method; a positive id means queued only.
pub fn execute(browser: *cef.cef_browser_t, method: []const u8, params_json: ?[]const u8) c_int {
    const get_host = browser.get_host orelse return 0;
    const bh: *cef.cef_browser_host_t = get_host(browser) orelse return 0;
    defer host_mod.release(&bh.base);
    const exec = bh.execute_dev_tools_method orelse return 0;
    var params: ?*cef.cef_dictionary_value_t = null;
    if (params_json) |json| {
        const val: *cef.cef_value_t = cef.cef_parse_json_buffer(json.ptr, json.len, cef.JSON_PARSER_RFC) orelse return 0;
        defer host_mod.release(&val.base);
        params = (val.get_dictionary orelse return 0)(val) orelse return 0;
    }
    var transferred = false;
    defer if (!transferred) if (params) |p| host_mod.release(&p.base);
    var name = std.mem.zeroes(cef.cef_string_t);
    host_mod.setStr(method, &name);
    defer cef.cef_string_utf16_clear(&name);
    if (name.length == 0) return 0;
    // CEF consumes the dictionary reference even if submission fails.
    transferred = true;
    return exec(bh, 0, &name, params);
}

/// The `message` of a CDP error object, or the raw text.
fn errorMessage(payload: []const u8) []const u8 {
    const key = "\"message\":\"";
    const at = std.mem.indexOf(u8, payload, key) orelse return payload[0..@min(payload.len, 200)];
    const rest = payload[at + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse rest.len;
    return rest[0..@min(end, 200)];
}

/// The value of `member` when `payload` is exactly `{"member":VALUE}` (CEF's compact result shape); null otherwise.
pub fn memberSlice(payload: []const u8, member: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, payload, " \t\r\n");
    if (trimmed.len < member.len + 5 or trimmed[0] != '{' or trimmed[trimmed.len - 1] != '}') return null;
    var rest = std.mem.trimStart(u8, trimmed[1..], " \t\r\n");
    if (rest.len < member.len + 3 or rest[0] != '"' or !std.mem.eql(u8, rest[1 .. 1 + member.len], member) or rest[1 + member.len] != '"') return null;
    rest = std.mem.trimStart(u8, rest[member.len + 2 ..], " \t\r\n");
    if (rest.len == 0 or rest[0] != ':') return null;
    const value = std.mem.trim(u8, rest[1 .. rest.len - 1], " \t\r\n");
    if (value.len == 0 or (value[0] != '{' and value[0] != '[')) return null;
    const close: u8 = if (value[0] == '{') '}' else ']';
    // A second member after the value would end with `,"x":...`; the value must close last.
    if (value[value.len - 1] != close) return null;
    return value;
}

/// A private helper-side staging file written in pieces, for results and event streams a client fetches afterwards.
pub const StagedFile = struct {
    fd: c_int,
    buf: [host_mod.STAGING_PATH_MAX:0]u8 = undefined,
    len: usize = 0,
    failed: bool = false,

    pub fn open(comptime kind: []const u8) ?StagedFile {
        var self: StagedFile = .{ .fd = -1 };
        const p = host_mod.stagingFile(&self.buf, kind) orelse return null;
        self.len = p.len;
        self.fd = c.open(p.ptr, c.O_WRONLY | c.O_TRUNC | c.O_CLOEXEC);
        if (self.fd < 0) {
            _ = c.unlink(p.ptr);
            return null;
        }
        return self;
    }

    pub fn path(self: *const StagedFile) [:0]const u8 {
        return self.buf[0..self.len :0];
    }

    /// Append `bytes`; false once any write failed.
    pub fn write(self: *StagedFile, bytes: []const u8) bool {
        var off: usize = 0;
        while (!self.failed and off < bytes.len) {
            const n = c.write(self.fd, bytes[off..].ptr, bytes.len - off);
            if (n <= 0) {
                self.failed = true;
                break;
            }
            off += @intCast(n);
        }
        return !self.failed;
    }

    /// Close and return the path; the file now belongs to whoever is told about it.
    pub fn finish(self: *StagedFile) [:0]const u8 {
        if (self.fd >= 0) _ = c.close(self.fd);
        self.fd = -1;
        return self.path();
    }

    pub fn abort(self: *StagedFile) void {
        _ = c.unlink(self.finish().ptr);
    }
};

test "a profile result is unwrapped to its member only when the shape is exact" {
    const t = std.testing;
    try t.expectEqualStrings("{\"nodes\":[],\"samples\":[]}", memberSlice("{\"profile\":{\"nodes\":[],\"samples\":[]}}", "profile").?);
    try t.expectEqualStrings("{\"a\":1}", memberSlice(" { \"profile\" : {\"a\":1} } ", "profile").?);
    try t.expect(memberSlice("{\"profile\":{\"a\":1},\"x\":2}", "profile") == null);
    try t.expect(memberSlice("{\"other\":{}}", "profile") == null);
    try t.expect(memberSlice("{\"profile\":3}", "profile") == null);
    try t.expectEqualStrings("Profiler is not started", errorMessage("{\"code\":-32000,\"message\":\"Profiler is not started\"}"));
}

test "session requests match by id, keep payloads, expire and fail on detach" {
    const t = std.testing;
    try t.expect(host_mod.apiHash());
    const Fake = struct {
        var host = std.mem.zeroes(cef.cef_browser_host_t);
        var next: c_int = 0;
        var observer: ?*cef.cef_dev_tools_message_observer_t = null;
        var registration = std.mem.zeroes(cef.cef_registration_t);
        fn getHost(_: [*c]cef.cef_browser_t) callconv(.c) [*c]cef.cef_browser_host_t {
            return &host;
        }
        fn id(_: [*c]cef.cef_browser_t) callconv(.c) c_int {
            return 5;
        }
        fn rel(_: [*c]cef.cef_base_ref_counted_t) callconv(.c) c_int {
            return 0;
        }
        fn exec(_: [*c]cef.cef_browser_host_t, _: c_int, _: [*c]const cef.cef_string_t, params: [*c]cef.cef_dictionary_value_t) callconv(.c) c_int {
            if (params != null) host_mod.releaseArg(params);
            next += 1;
            return next;
        }
        fn add(_: [*c]cef.cef_browser_host_t, o: [*c]cef.cef_dev_tools_message_observer_t) callconv(.c) [*c]cef.cef_registration_t {
            observer = o;
            return &registration;
        }
    };
    Fake.host.base.release = Fake.rel;
    Fake.registration.base.release = Fake.rel;
    Fake.host.execute_dev_tools_method = Fake.exec;
    Fake.host.add_dev_tools_message_observer = Fake.add;
    var browser = std.mem.zeroes(cef.cef_browser_t);
    browser.get_host = Fake.getHost;
    browser.get_identifier = Fake.id;
    browser.base.release = Fake.rel;
    browser.base.add_ref = struct {
        fn f(_: [*c]cef.cef_base_ref_counted_t) callconv(.c) void {}
    }.f;
    const s = try Session.create(t.allocator, &browser, 3);
    // The test holds CEF's transferred reference and drops it at the end.
    defer _ = Ref.release(&s.observer.base);
    defer s.stop();
    const a = try s.send(&browser, "Performance.getMetrics", null, 5_000, .memory, "");
    const b = try s.send(&browser, "Performance.enable", "{\"timeDomain\":\"timeTicks\"}", 5_000, .memory, "");
    try t.expect(a != b);
    try t.expect(s.outcome(a) == .pending);
    // A result for another id leaves `a` pending; its own result carries the payload.
    s.deliver(b, true, "{}");
    try t.expect(s.outcome(a) == .pending);
    s.deliver(a, true, "{\"metrics\":[]}");
    try t.expectEqualStrings("{\"metrics\":[]}", s.outcome(a).ok);
    // A second result for an answered id changes nothing.
    s.deliver(a, false, "{\"message\":\"late\"}");
    try t.expectEqualStrings("{\"metrics\":[]}", s.outcome(a).ok);
    s.forget(a);
    try t.expect(s.outcome(a) == .failed);
    const late = try s.send(&browser, "Profiler.stop", null, 1, .staged, "profile");
    s.expire(clock.nowMs() + 10);
    try t.expect(std.mem.indexOf(u8, s.outcome(late).failed, "deadline") != null);
    const refused = try s.send(&browser, "Profiler.start", null, 5_000, .memory, "");
    s.deliver(refused, false, "{\"code\":-32000,\"message\":\"nope\"}");
    try t.expect(std.mem.indexOf(u8, s.outcome(refused).failed, "nope") != null);
    const cut = try s.send(&browser, "Profiler.stop", null, 5_000, .staged, "profile");
    Fake.observer.?.on_dev_tools_agent_detached.?(Fake.observer.?, &browser);
    try t.expectEqual(@as(u32, 1), s.detaches);
    try t.expect(std.mem.indexOf(u8, s.outcome(cut).failed, "detached") != null);
    // A staged result lands in a private file holding the member only.
    const staged = try s.send(&browser, "Profiler.stop", null, 5_000, .staged, "profile");
    const wrapped = "{\"profile\":{\"nodes\":[]}}";
    Fake.observer.?.on_dev_tools_method_result.?(Fake.observer.?, &browser, staged, 1, wrapped, wrapped.len);
    const path = s.outcome(staged).ok;
    var buf: [64]u8 = undefined;
    const pz = try t.allocator.dupeSentinel(u8, path, 0);
    defer t.allocator.free(pz);
    const fd = c.open(pz.ptr, c.O_RDONLY);
    try t.expect(fd >= 0);
    const n = c.read(fd, &buf, buf.len);
    _ = c.close(fd);
    try t.expectEqualStrings("{\"nodes\":[]}", buf[0..@intCast(n)]);
    // Forgetting an untaken staged result removes its file.
    s.forget(staged);
    try t.expect(c.access(pz.ptr, c.F_OK) != 0);
    var too_many: usize = s.requests.items.len;
    while (too_many < MAX_REQUESTS) : (too_many += 1) _ = try s.send(&browser, "Performance.getMetrics", null, 5_000, .memory, "");
    try t.expectError(error.TooManyRequests, s.send(&browser, "Performance.getMetrics", null, 5_000, .memory, ""));
}
