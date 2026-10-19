//! The user's own URL shortener for the long links in web text lanes
//! (`[mcp] web_url_shortener`): a GET template holding `{url}` whose
//! reply body IS the short URL, the plain-text shape YOURLS
//! (`format=simple`), Shlink (`format=txt`), Polr (`plain_text`) and
//! TinyURL-alikes all answer.
//!
//! A lookup never holds an MCP call past its budget: a detached worker,
//! spawned while URLs are queued and gone once the queue drains, does the
//! HTTP; results land in a cache; `rewrite` substitutes what is cached
//! by its deadline and leaves the rest long (they are short next time).
//! `std.http.Client` has no timeouts, so a shortener that hangs stalls
//! only the worker, never a call. Shared state is fixed-capacity so the
//! spinlock is never held across an allocation.

const std = @import("std");
const c = @import("../c.zig").c;
const SpinLock = @import("../util/spinlock.zig").SpinLock;
const clock = @import("../util/clock.zig");

/// URLs shorter than this many bytes stay as they are, unless configured.
pub const DEFAULT_MIN_LEN: u16 = 120;
/// How long a text lane waits for lookups it just queued.
pub const WAIT_MS: i64 = 3000;
const MAX_CACHE = 4096;
const MAX_QUEUE = 512;
/// A reply longer than this is not a short URL.
const MAX_REPLY = 1024;

const Entry = union(enum) { pending, short: []u8, failed };

var lock: SpinLock = .init;
var gpa: std.mem.Allocator = undefined;
var template: []u8 = &.{};
var origin: []const u8 = "";
var min_len: usize = DEFAULT_MIN_LEN;
var cache: std.StringHashMapUnmanaged(Entry) = .empty;
var queue: [MAX_QUEUE][]const u8 = undefined;
var queue_head: usize = 0;
var queue_len: usize = 0;
var worker_running = false;
var shortened: u64 = 0;
var failed: u64 = 0;
var last_error_buf: [160]u8 = undefined;
var last_error_len: usize = 0;

pub const ConfigError = error{ BadTemplate, OutOfMemory };

/// Whether `tmpl` is a usable template: an http(s) URL holding `{url}`.
pub fn validTemplate(tmpl: []const u8) bool {
    return (std.mem.startsWith(u8, tmpl, "https://") or std.mem.startsWith(u8, tmpl, "http://")) and
        std.mem.indexOf(u8, tmpl, "{url}") != null and std.mem.indexOfAny(u8, tmpl, " \t\r\n") == null;
}

/// Turn shortening on; an empty `tmpl` leaves it off. Call once, before any lookup.
pub fn configure(allocator: std.mem.Allocator, tmpl: []const u8, min: ?u16) ConfigError!void {
    if (tmpl.len == 0) return;
    if (!validTemplate(tmpl)) return error.BadTemplate;
    gpa = allocator;
    template = try allocator.dupe(u8, tmpl);
    errdefer {
        allocator.free(template);
        template = &.{};
    }
    try cache.ensureTotalCapacity(allocator, MAX_CACHE);
    const scheme_end = std.mem.indexOf(u8, template, "://").? + 3;
    const host_end = std.mem.indexOfScalarPos(u8, template, scheme_end, '/') orelse template.len;
    origin = template[0..host_end];
    min_len = min orelse DEFAULT_MIN_LEN;
}

pub fn enabled() bool {
    return template.len > 0;
}

pub const Stats = struct {
    configured: bool,
    min_len: usize,
    shortened: u64,
    failed: u64,
    /// Borrowed from `buf`.
    last_error: []const u8,
};

/// Counters for `capabilities`; the template itself (it may hold a key) is never reported.
pub fn stats(buf: *[160]u8) Stats {
    lock.lock();
    defer lock.unlock();
    @memcpy(buf[0..last_error_len], last_error_buf[0..last_error_len]);
    return .{ .configured = enabled(), .min_len = min_len, .shortened = shortened, .failed = failed, .last_error = buf[0..last_error_len] };
}

/// Queue every long URL in `text` that is not known yet, without waiting.
pub fn prefetch(text: []const u8) void {
    if (!enabled()) return;
    var spawn = false;
    var it = Scan{ .text = text };
    while (it.next()) |span| {
        const url = text[span.start..span.end];
        if (!wanted(url)) continue;
        lock.lock();
        const known = cache.contains(url);
        lock.unlock();
        if (known) continue;
        const key = gpa.dupe(u8, url) catch return;
        lock.lock();
        if (cache.contains(key) or cache.count() >= MAX_CACHE or queue_len >= MAX_QUEUE) {
            lock.unlock();
            gpa.free(key);
            continue;
        }
        cache.putAssumeCapacity(key, .pending);
        queue[(queue_head + queue_len) % MAX_QUEUE] = key;
        queue_len += 1;
        if (!worker_running) {
            worker_running = true;
            spawn = true;
        }
        lock.unlock();
    }
    if (!spawn) return;
    const th = std.Thread.spawn(.{}, work, .{}) catch {
        lock.lock();
        defer lock.unlock();
        worker_running = false;
        noteError("cannot start the shortener worker");
        return;
    };
    th.detach();
}

/// `text` with every long URL the cache has a short form for replaced,
/// after waiting up to `wait_ms` for lookups `text` itself queues.
pub fn rewrite(arena: std.mem.Allocator, text: []const u8, wait_ms: i64) ![]const u8 {
    if (!enabled()) return text;
    prefetch(text);
    const deadline = clock.nowMs() + wait_ms;
    while (anyPending(text) and clock.nowMs() < deadline) _ = c.usleep(20_000);
    var out: std.Io.Writer.Allocating = .init(arena);
    var last: usize = 0;
    var it = Scan{ .text = text };
    var buf: [MAX_REPLY]u8 = undefined;
    while (it.next()) |span| {
        const url = text[span.start..span.end];
        if (!wanted(url)) continue;
        const short = cachedShort(url, &buf) orelse continue;
        try out.writer.writeAll(text[last..span.start]);
        try out.writer.writeAll(short);
        last = span.end;
    }
    if (last == 0) return text;
    try out.writer.writeAll(text[last..]);
    return out.written();
}

fn wanted(url: []const u8) bool {
    return url.len >= min_len and !std.mem.startsWith(u8, url, origin);
}

fn anyPending(text: []const u8) bool {
    var it = Scan{ .text = text };
    lock.lock();
    defer lock.unlock();
    while (it.next()) |span| {
        const url = text[span.start..span.end];
        if (!wanted(url)) continue;
        if (cache.get(url)) |e| if (e == .pending) return true;
    }
    return false;
}

fn cachedShort(url: []const u8, buf: *[MAX_REPLY]u8) ?[]const u8 {
    lock.lock();
    defer lock.unlock();
    const e = cache.get(url) orelse return null;
    return switch (e) {
        .short => |s| blk: {
            @memcpy(buf[0..s.len], s);
            break :blk buf[0..s.len];
        },
        else => null,
    };
}

/// Lock held.
fn noteError(msg: []const u8) void {
    const n = @min(msg.len, last_error_buf.len);
    @memcpy(last_error_buf[0..n], msg[0..n]);
    last_error_len = n;
}

fn work() void {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var client: std.http.Client = .{ .allocator = gpa, .io = threaded.io() };
    defer client.deinit();
    while (true) {
        lock.lock();
        if (queue_len == 0) {
            worker_running = false;
            lock.unlock();
            return;
        }
        const url = queue[queue_head];
        queue_head = (queue_head + 1) % MAX_QUEUE;
        queue_len -= 1;
        lock.unlock();

        var why: []const u8 = "";
        const short = lookup(&client, url, &why);
        lock.lock();
        if (cache.getPtr(url)) |e| e.* = if (short) |s| .{ .short = s } else .failed;
        if (short != null) shortened += 1 else {
            failed += 1;
            noteError(why);
        }
        lock.unlock();
    }
}

/// The short form of `url`, owned by `gpa`, or null with `why` set.
fn lookup(client: *std.http.Client, url: []const u8, why: *[]const u8) ?[]u8 {
    var req: std.Io.Writer.Allocating = .init(gpa);
    defer req.deinit();
    fillTemplate(&req.writer, url) catch {
        why.* = "out of memory";
        return null;
    };
    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    const res = client.fetch(.{ .location = .{ .url = req.written() }, .response_writer = &body.writer }) catch |e| {
        why.* = @errorName(e);
        return null;
    };
    if (@intFromEnum(res.status) < 200 or @intFromEnum(res.status) >= 300) {
        why.* = "the shortener answered a non-2xx status";
        return null;
    }
    const short = std.mem.trim(u8, body.written(), " \t\r\n");
    if (!looksLikeShortUrl(short, url)) {
        why.* = "the shortener's reply is not a shorter http(s) URL";
        return null;
    }
    return gpa.dupe(u8, short) catch {
        why.* = "out of memory";
        return null;
    };
}

fn looksLikeShortUrl(short: []const u8, long: []const u8) bool {
    if (!std.mem.startsWith(u8, short, "https://") and !std.mem.startsWith(u8, short, "http://")) return false;
    if (short.len > MAX_REPLY or short.len >= long.len) return false;
    for (short) |ch| if (ch <= ' ' or ch == 0x7f) return false;
    return true;
}

/// The template with every `{url}` replaced by `url`, percent-encoded.
fn fillTemplate(w: *std.Io.Writer, url: []const u8) !void {
    var rest: []const u8 = template;
    while (std.mem.indexOf(u8, rest, "{url}")) |i| {
        try w.writeAll(rest[0..i]);
        for (url) |ch| {
            if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '.' or ch == '_' or ch == '~')
                try w.writeByte(ch)
            else
                try w.print("%{X:0>2}", .{ch});
        }
        rest = rest[i + "{url}".len ..];
    }
    try w.writeAll(rest);
}

/// The http(s) URLs in a text lane: a markdown target keeps its balanced
/// parentheses (`/wiki/Ghent_(disambiguation)`), and prose punctuation
/// after a bare URL is not part of it.
const Scan = struct {
    text: []const u8,
    pos: usize = 0,

    const Span = struct { start: usize, end: usize };

    fn next(self: *Scan) ?Span {
        while (std.mem.indexOfPos(u8, self.text, self.pos, "http")) |i| {
            self.pos = i + 4;
            const rest = self.text[i..];
            if (!std.mem.startsWith(u8, rest, "http://") and !std.mem.startsWith(u8, rest, "https://")) continue;
            if (i > 0 and (std.ascii.isAlphanumeric(self.text[i - 1]) or self.text[i - 1] == '%')) continue;
            var end = i;
            var depth: usize = 0;
            while (end < self.text.len) : (end += 1) {
                const ch = self.text[end];
                if (ch <= ' ' or ch == '<' or ch == '>' or ch == '"' or ch == '`' or ch == ']') break;
                if (ch == '(') depth += 1;
                if (ch == ')') {
                    if (depth == 0) break;
                    depth -= 1;
                }
            }
            while (end > i and std.mem.indexOfScalar(u8, ".,;:!?", self.text[end - 1]) != null) end -= 1;
            self.pos = end;
            return .{ .start = i, .end = end };
        }
        return null;
    }
};

/// Free everything once the worker is idle. A worker still inside a
/// request after `wait_ms` (a hung shortener) is left alone, along with
/// what it uses: freeing under it would be a use-after-free.
pub fn deinit(wait_ms: i64) void {
    const deadline = clock.nowMs() + wait_ms;
    while (true) {
        lock.lock();
        const busy = worker_running;
        lock.unlock();
        if (!busy) break;
        if (clock.nowMs() >= deadline) return;
        _ = c.usleep(5000);
    }
    var it = cache.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* == .short) gpa.free(e.value_ptr.short);
        gpa.free(e.key_ptr.*);
    }
    cache.deinit(gpa);
    cache = .empty;
    if (template.len > 0) gpa.free(template);
    template = &.{};
    origin = "";
    queue_head = 0;
    queue_len = 0;
    shortened = 0;
    failed = 0;
    last_error_len = 0;
}

const testserver = @import("../agent/testserver.zig");

const ShortCtx = struct { port: u16, n: std.atomic.Value(u32) = .init(0) };

fn answerShort(ctx: ?*anyopaque, srv: *testserver.Server, method: []const u8, path: []const u8, body: []const u8) ?testserver.Reply {
    _ = method;
    _ = body;
    const sc: *ShortCtx = @ptrCast(@alignCast(ctx.?));
    if (!std.mem.eql(u8, path, "/shorten")) return null;
    // The hook sees no query; the recorded request line has it (the
    // worker sends one request at a time, so the last one is this one).
    const req = srv.lastRequest("GET /shorten?") orelse return .{ .status = 400, .body = "bad" };
    const line = req[0 .. std.mem.indexOf(u8, req, "\r\n") orelse req.len];
    // The long URL must arrive percent-encoded, beside the template's own key.
    if (std.mem.indexOf(u8, line, "key=K&url=https%3A%2F%2Fex.test%2F") == null) return .{ .status = 400, .body = "bad" };
    if (std.mem.indexOf(u8, line, "broken") != null) return .{ .body = "<html>no</html>" };
    const n = sc.n.fetchAdd(1, .acq_rel);
    const S = struct {
        threadlocal var buf: [64]u8 = undefined;
    };
    return .{ .body = std.fmt.bufPrint(&S.buf, "http://127.0.0.1:{d}/s/{d}\n", .{ sc.port, n }) catch "x" };
}

test "long URLs in a text lane become the shortener's, short ones and parentheses survive" {
    const t = std.testing;
    var srv: testserver.Server = .{};
    var sc: ShortCtx = .{ .port = 0 };
    srv.hook = answerShort;
    srv.hook_ctx = &sc;
    try srv.start(t.allocator);
    defer srv.deinit();
    sc.port = srv.port();
    var tbuf: [128]u8 = undefined;
    try configure(t.allocator, try std.fmt.bufPrint(&tbuf, "http://127.0.0.1:{d}/shorten?key=K&url={{url}}", .{sc.port}), 40);
    defer deinit(10_000);

    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const long = "https://ex.test/wiki/Ghent_(disambiguation)?lang=en&a=1&b=2";
    const text = "see [Ghent](" ++ long ++ ") and https://ex.test/x and https://ex.test/long/path/that/is/long/enough/to/shorten.";
    const out = try rewrite(a, text, 5000);
    try t.expect(std.mem.startsWith(u8, out, "see [Ghent](http://127.0.0.1:"));
    try t.expect(std.mem.indexOf(u8, out, "Ghent_(") == null);
    try t.expect(std.mem.indexOf(u8, out, " and https://ex.test/x and ") != null);
    try t.expect(std.mem.endsWith(u8, out, "."));
    try t.expect(std.mem.indexOf(u8, out, "to/shorten") == null);
    // The same URL again is answered from the cache: no second request.
    const before = sc.n.load(.acquire);
    const again = try rewrite(a, "[x](" ++ long ++ ")", 5000);
    try t.expectEqual(before, sc.n.load(.acquire));
    try t.expect(std.mem.indexOf(u8, again, "/s/") != null);
    // A reply that is not a URL leaves the link long and is counted.
    const broken = "[y](https://ex.test/broken/and/long/enough/to/qualify)";
    try t.expectEqualStrings(broken, try rewrite(a, broken, 5000));
    var eb: [160]u8 = undefined;
    const st = stats(&eb);
    try t.expectEqual(@as(u64, 2), st.shortened);
    try t.expectEqual(@as(u64, 1), st.failed);
    try t.expect(std.mem.indexOf(u8, st.last_error, "not a shorter") != null);
}

test "a shortener URL in the text and a disabled shortener leave the text alone" {
    const t = std.testing;
    try t.expectEqualStrings("[a](https://ex.test/very/long/url/indeed/yes)", try rewrite(t.allocator, "[a](https://ex.test/very/long/url/indeed/yes)", 0));
    try t.expect(!validTemplate("https://sho.rt/api?url="));
    try t.expect(!validTemplate("ftp://sho.rt/{url}"));
    try t.expect(validTemplate("https://sho.rt/rest/v3/short-urls/shorten?apiKey=K&format=txt&longUrl={url}"));
}
