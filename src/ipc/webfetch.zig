//! `web_fetch`'s pure half: the instance-wide queue of fetch tabs and
//! what a response body is for reading. The reading vocabulary it shares
//! with `web_read` (modes, body sources, caps, regex matches) is
//! `webread.zig`. std-only and engine-free, so both test roots import
//! it; `mcp_webfetch.zig` is the driver.

const std = @import("std");
const capture = @import("../web/capture.zig");

/// How one url ended. ONE vocabulary (`results[].status`).
pub const Status = enum {
    /// The navigation finished and whatever it produced was read (a
    /// 404's body included: `navigation` says it was an error page).
    done,
    /// No usable answer: the navigation failed, was refused, or its
    /// body/file could not be read; `error` says which.
    failed,
    /// The url's own timeout passed first.
    timed_out,
    /// The call was cancelled before this url finished.
    cancelled,
    /// Not an http(s) url; nothing was opened.
    invalid_url,
};

/// Tabs one call keeps in flight at most.
pub const PER_CALL_TABS: u16 = 4;
/// Instance-wide fetch tabs when `web_fetch_max_tabs` is not set.
pub const DEFAULT_MAX_TABS: u16 = 8;
/// Upper bound for `web_fetch_max_tabs`: each fetch tab holds one of the
/// helper's capture slots (`web_proto.MAX_POLICY_VIEWS`), and tabs of
/// their own need some too.
pub const MAX_MAX_TABS: u16 = 16;
/// Urls one call takes.
pub const MAX_URLS: usize = 64;

pub const DEFAULT_TIMEOUT_MS: i64 = 30_000;

/// What a response body is, for reading it.
pub const Kind = enum {
    /// A document the engine renders as a page: text is reader mode.
    html,
    /// Plain text, XML, JSON, feeds, scripts: the body IS the text.
    text,
    /// Anything else (PDF, archives, images, octet streams): saved to a
    /// file through the download path.
    file,
};

const HTML_MIMES = [_][]const u8{ "text/html", "application/xhtml+xml" };

/// The kind a content type reads as: text is whatever the capture
/// machinery presents as text (`capture.isTextMime`, the one list); an
/// unknown type (no detail from an older helper) is taken as a page.
pub fn kindOf(mime_raw: []const u8) Kind {
    const mime = std.mem.trim(u8, if (std.mem.indexOfScalar(u8, mime_raw, ';')) |i| mime_raw[0..i] else mime_raw, " \t");
    if (mime.len == 0) return .html;
    for (HTML_MIMES) |h| if (std.ascii.eqlIgnoreCase(mime, h)) return .html;
    return if (capture.isTextMime(mime)) .text else .file;
}

pub fn httpUrl(url: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(url, "http://") or std.ascii.startsWithIgnoreCase(url, "https://");
}

/// The instance-wide fetch-tab queue: every `web_fetch` call's urls wait
/// here until a tab is free. At most `cap` tabs run across all calls and
/// `per_call` within one; a free tab goes to the call AFTER the one that
/// got the previous tab (round robin in arrival order), so a call of 40
/// urls cannot starve one of 2 that arrived behind it.
pub const Queue = struct {
    cap: u16 = DEFAULT_MAX_TABS,
    per_call: u16 = PER_CALL_TABS,
    calls: std.ArrayList(Call) = .empty,
    running: u16 = 0,
    /// Highest `running` ever seen, for the reply and the rigs.
    peak: u16 = 0,
    /// Index in `calls` of the call whose turn is next.
    rr: usize = 0,

    pub const Call = struct {
        id: u64,
        total: u16,
        /// Next url index not yet admitted.
        next: u16 = 0,
        running: u16 = 0,
        peak: u16 = 0,
    };

    pub const Admitted = struct { call: u64, index: u16 };

    pub fn deinit(self: *Queue, gpa: std.mem.Allocator) void {
        self.calls.deinit(gpa);
        self.* = .{ .cap = self.cap, .per_call = self.per_call };
    }

    pub fn addCall(self: *Queue, gpa: std.mem.Allocator, id: u64, urls: u16) !void {
        try self.calls.append(gpa, .{ .id = id, .total = urls });
    }

    fn find(self: *Queue, id: u64) ?usize {
        for (self.calls.items, 0..) |cl, i| if (cl.id == id) return i;
        return null;
    }

    pub fn call(self: *Queue, id: u64) ?*Call {
        const i = self.find(id) orelse return null;
        return &self.calls.items[i];
    }

    /// Give the next free tab to a waiting url; null when every tab is
    /// taken or nothing eligible waits.
    pub fn admit(self: *Queue) ?Admitted {
        if (self.running >= self.cap or self.calls.items.len == 0) return null;
        const n = self.calls.items.len;
        var k: usize = 0;
        while (k < n) : (k += 1) {
            const i = (self.rr + k) % n;
            const cl = &self.calls.items[i];
            if (cl.next >= cl.total or cl.running >= self.per_call) continue;
            const idx = cl.next;
            cl.next += 1;
            cl.running += 1;
            cl.peak = @max(cl.peak, cl.running);
            self.running += 1;
            self.peak = @max(self.peak, self.running);
            self.rr = (i + 1) % n;
            return .{ .call = cl.id, .index = idx };
        }
        return null;
    }

    /// One of `id`'s tabs closed.
    pub fn finish(self: *Queue, id: u64) void {
        const cl = self.call(id) orelse return;
        if (cl.running == 0) return;
        cl.running -= 1;
        self.running -= 1;
    }

    /// The call ended (answered or cancelled): tabs it still counts as
    /// running are released, urls it never started are dropped.
    pub fn removeCall(self: *Queue, id: u64) void {
        const i = self.find(id) orelse return;
        self.running -= self.calls.items[i].running;
        _ = self.calls.orderedRemove(i);
        // The turn stays with the same call; a removed one passes it on.
        if (i < self.rr) self.rr -= 1;
        if (self.rr >= self.calls.items.len) self.rr = 0;
    }
};

const t = std.testing;

fn drain(q: *Queue, out: []Queue.Admitted) usize {
    var n: usize = 0;
    while (q.admit()) |a| : (n += 1) out[n] = a;
    return n;
}

test "one call keeps at most four tabs and the next url starts when one finishes" {
    var q: Queue = .{ .cap = 8 };
    defer q.deinit(t.allocator);
    try q.addCall(t.allocator, 1, 6);
    var got: [16]Queue.Admitted = undefined;
    try t.expectEqual(@as(usize, 4), drain(&q, &got));
    for (got[0..4], 0..) |a, i| try t.expectEqual(@as(u16, @intCast(i)), a.index);
    q.finish(1);
    try t.expectEqual(@as(usize, 1), drain(&q, &got));
    try t.expectEqual(@as(u16, 4), got[0].index);
    q.finish(1);
    q.finish(1);
    try t.expectEqual(@as(usize, 1), drain(&q, &got));
    try t.expectEqual(@as(usize, 0), drain(&q, &got));
    try t.expectEqual(@as(u16, 4), q.peak);
    try t.expectEqual(@as(u16, 4), q.call(1).?.peak);
}

test "the instance cap holds across calls and free tabs rotate fairly" {
    var q: Queue = .{ .cap = 3 };
    defer q.deinit(t.allocator);
    try q.addCall(t.allocator, 10, 4);
    try q.addCall(t.allocator, 20, 4);
    var got: [16]Queue.Admitted = undefined;
    try t.expectEqual(@as(usize, 3), drain(&q, &got));
    // Alternating, in arrival order.
    try t.expectEqual(@as(u64, 10), got[0].call);
    try t.expectEqual(@as(u64, 20), got[1].call);
    try t.expectEqual(@as(u64, 10), got[2].call);
    try t.expectEqual(@as(u16, 3), q.running);
    // A tab of call 10 frees: call 20 is next in turn, not 10 again.
    q.finish(10);
    try t.expectEqual(@as(usize, 1), drain(&q, &got));
    try t.expectEqual(@as(u64, 20), got[0].call);
    try t.expect(q.peak <= 3);
    // Ten calls of four never exceed the cap.
    var big: Queue = .{ .cap = 8 };
    defer big.deinit(t.allocator);
    for (0..10) |i| try big.addCall(t.allocator, i, 4);
    var many: [64]Queue.Admitted = undefined;
    try t.expectEqual(@as(usize, 8), drain(&big, &many));
    var seen = [_]u8{0} ** 10;
    for (many[0..8]) |a| seen[@intCast(a.call)] += 1;
    for (seen) |s| try t.expect(s <= 1);
}

test "a removed call releases its tabs and its turn" {
    var q: Queue = .{ .cap = 4 };
    defer q.deinit(t.allocator);
    try q.addCall(t.allocator, 1, 8);
    try q.addCall(t.allocator, 2, 8);
    var got: [16]Queue.Admitted = undefined;
    try t.expectEqual(@as(usize, 4), drain(&q, &got));
    q.finish(1);
    q.finish(1);
    q.removeCall(1);
    try t.expectEqual(@as(u16, 2), q.running);
    try t.expectEqual(@as(usize, 2), drain(&q, &got));
    try t.expectEqual(@as(u64, 2), got[0].call);
    try t.expectEqual(@as(u16, 4), q.running);
    q.removeCall(2);
    try t.expectEqual(@as(u16, 0), q.running);
    try t.expect(q.admit() == null);
}

test "kinds and http urls" {
    try t.expectEqual(Kind.html, kindOf("text/html; charset=utf-8"));
    try t.expectEqual(Kind.html, kindOf(""));
    try t.expectEqual(Kind.text, kindOf("text/plain"));
    try t.expectEqual(Kind.text, kindOf("application/xml"));
    try t.expectEqual(Kind.text, kindOf("Application/JSON"));
    try t.expectEqual(Kind.text, kindOf("application/rss+xml"));
    try t.expectEqual(Kind.file, kindOf("application/pdf"));
    try t.expectEqual(Kind.file, kindOf("application/zip"));
    try t.expect(httpUrl("HTTPS://x/") and !httpUrl("file:///etc/passwd") and !httpUrl("data:,x"));
}
