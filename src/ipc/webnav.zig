//! What a navigation produced, derived from the view's request log (the
//! records `web_network` reports) after the call that navigated: the
//! main document's status, final url, redirect chain, content type, and
//! which of the ways a navigation can end it took. No second request
//! log exists; this only reads the one the helper already keeps.
//!
//! GTK-free and engine-free on purpose: both test roots import it.

const std = @import("std");

/// How a navigation ended. ONE vocabulary: the `navigation.outcome`
/// schema enum is generated from it.
pub const Outcome = enum {
    /// The document arrived with an HTTP status below 400.
    page,
    /// The server answered 4xx/5xx; the page shows its body, or the
    /// engine's error page when it sent none.
    http_error,
    /// No HTTP answer at all: DNS, TLS, refused, reset, timed out.
    network_error,
    /// Stopped or cancelled, and nothing replaced it.
    aborted,
    /// Another top-level navigation superseded the requested one.
    replaced,
    /// The response became a download, not a page.
    download,
    /// Refused inside the engine (filter list or network policy) before
    /// it left the process.
    blocked,
    /// A scheme with no HTTP status (data:, about:, file:, blob:).
    non_http,
    /// The document had not finished inside the budget.
    pending,
    /// No document request was logged: a back/forward-cache or
    /// same-document navigation, or a view the log does not cover.
    no_request,
    /// The server redirected and the view was told not to follow
    /// (`web_fetch follow_redirects:false`): status and url are the
    /// redirect's own, `location` is where it pointed.
    redirect,
};

/// The conditions `web_wait for` takes; `web_open`/`web_navigate` `wait`
/// take every one but `response` (`inNavigation`).
pub const WaitFor = enum {
    load,
    title,
    text,
    idle,
    selector,
    network_idle,
    response,

    pub fn inNavigation(self: WaitFor) bool {
        return self != .response;
    }

    /// Conditions whose `arg` is required.
    pub fn needsArg(self: WaitFor) bool {
        return self == .selector;
    }
};

/// JSON enum body (`"load","title",...`) of the conditions a navigation
/// call's `wait` takes.
pub const NAV_WAIT_ITEMS = blk: {
    var out: []const u8 = "";
    for (std.enums.values(WaitFor)) |w| {
        if (!w.inNavigation()) continue;
        out = out ++ (if (out.len > 0) "," else "") ++ "\"" ++ @tagName(w) ++ "\"";
    }
    break :blk out;
};

/// One request log row, as `web_proto.netLogJson*` renders it.
pub const Entry = struct {
    seq: u32,
    document: bool,
    url: []const u8,
    blocked: bool = false,
    reason: []const u8 = "",
    /// False while the request is in flight.
    done: bool = false,
    status: u16 = 0,
    size: u32 = 0,
    redirect: bool = false,
    prev_seq: u32 = 0,
    mime: []const u8 = "",
    status_text: []const u8 = "",
    err: i32 = 0,
    err_name: []const u8 = "",
};

pub const Log = struct {
    next_seq: u32 = 0,
    /// The helper sent `net-log-detail` (redirect chain, content type,
    /// status text, net errors); false = status/size only.
    detail: bool = false,
    entries: []const Entry = &.{},
};

fn getStr(o: std.json.ObjectMap, k: []const u8) []const u8 {
    const v = o.get(k) orelse return "";
    return if (v == .string) v.string else "";
}

fn getInt(o: std.json.ObjectMap, k: []const u8) ?i64 {
    const v = o.get(k) orelse return null;
    return if (v == .integer) v.integer else null;
}

fn getBool(o: std.json.ObjectMap, k: []const u8) bool {
    const v = o.get(k) orelse return false;
    return v == .bool and v.bool;
}

fn clampU(comptime T: type, v: ?i64) T {
    return @intCast(std.math.clamp(v orelse 0, 0, std.math.maxInt(T)));
}

/// Parse a `{"next_seq","detail","entries"}` log. Strings borrow from
/// the parsed value, which lives in `arena`.
pub fn parseLog(arena: std.mem.Allocator, json: []const u8) !Log {
    const doc = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
    if (doc != .object) return error.Malformed;
    const o = doc.object;
    var out: Log = .{ .next_seq = clampU(u32, getInt(o, "next_seq")), .detail = getBool(o, "detail") };
    const arr = o.get("entries") orelse return out;
    if (arr != .array) return error.Malformed;
    var list: std.ArrayList(Entry) = .empty;
    for (arr.array.items) |item| {
        if (item != .object) continue;
        const e = item.object;
        const status = getInt(e, "status");
        try list.append(arena, .{
            .seq = clampU(u32, getInt(e, "seq")),
            .document = std.mem.eql(u8, getStr(e, "type"), "document"),
            .url = getStr(e, "url"),
            .blocked = getBool(e, "blocked"),
            .reason = getStr(e, "reason"),
            .done = getBool(e, "blocked") or status != null,
            .status = clampU(u16, status),
            .size = clampU(u32, getInt(e, "size")),
            .redirect = getBool(e, "redirect"),
            .prev_seq = clampU(u32, getInt(e, "prev_seq")),
            .mime = getStr(e, "mime"),
            .status_text = getStr(e, "status_text"),
            .err = @intCast(std.math.clamp(getInt(e, "error_code") orelse 0, std.math.minInt(i32), std.math.maxInt(i32))),
            .err_name = getStr(e, "error"),
        });
    }
    out.entries = list.items;
    return out;
}

/// Requests still in flight (neither finished nor refused).
pub fn pendingCount(log: Log) usize {
    var n: usize = 0;
    for (log.entries) |e| {
        if (!e.done) n += 1;
    }
    return n;
}

/// A content type the engine shows as a page rather than handing to
/// the download manager.
pub fn renderable(mime: []const u8) bool {
    const prefixes = [_][]const u8{ "text/", "image/", "video/", "audio/", "multipart/x-mixed-replace" };
    for (prefixes) |p| if (std.ascii.startsWithIgnoreCase(mime, p)) return true;
    const exact = [_][]const u8{ "application/xhtml+xml", "application/xml", "application/json", "application/javascript", "application/pdf", "application/rss+xml", "application/atom+xml" };
    for (exact) |x| if (std.ascii.eqlIgnoreCase(mime, x)) return true;
    return false;
}

/// The url's scheme, lower-case as the engine reports it; "" without one.
pub fn schemeOf(url: []const u8) []const u8 {
    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return "";
    for (url[0..colon]) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '+' or ch == '-' or ch == '.')) return "";
    }
    return url[0..colon];
}

fn isHttp(url: []const u8) bool {
    const s = schemeOf(url);
    return std.ascii.eqlIgnoreCase(s, "http") or std.ascii.eqlIgnoreCase(s, "https");
}

pub const Hop = struct { url: []const u8, status: u16 };

/// What the caller knows besides the log.
pub const Input = struct {
    /// The url the call asked for; null for back/forward/reload.
    requested: ?[]const u8 = null,
    /// The view's url now (full length; log urls are cut at 256 bytes).
    view_url: []const u8 = "",
    /// The view's main-frame load failure record, if any.
    load_error: ?struct { code: i64, msg: []const u8 } = null,
    /// The view still reports a load in flight.
    loading: bool = false,
    /// A download the engine started for this navigation (headless).
    download_path: ?[]const u8 = null,
};

pub const Nav = struct {
    outcome: Outcome,
    url: []const u8,
    requested_url: ?[]const u8 = null,
    status: ?u16 = null,
    status_text: ?[]const u8 = null,
    redirects: []const Hop = &.{},
    content_type: ?[]const u8 = null,
    size: ?u32 = null,
    error_code: ?i64 = null,
    @"error": ?[]const u8 = null,
    blocked_reason: ?[]const u8 = null,
    scheme: []const u8 = "",
    /// The url the requested navigation had reached when another one
    /// superseded it (`replaced` only).
    replaced_url: ?[]const u8 = null,
    /// Where an unfollowed redirect pointed (`redirect` only).
    location: ?[]const u8 = null,
    download_path: ?[]const u8 = null,
    /// `net-log-detail` was available: redirects, content type, status
    /// text and net errors are measured; false = they are unknown.
    detail: bool = false,
};

/// The `reason` a refused redirect hop is logged with
/// (`web_proto.NetReason.redirect_refused`; this module stays engine-free,
/// and a test in `mcp_web.zig` pins the two together).
pub const REDIRECT_REFUSED = "redirect_refused";

fn bySeq(entries: []const Entry, seq: u32) ?*const Entry {
    for (entries) |*e| if (e.seq == seq) return e;
    return null;
}

/// The hops of the chain ending at `last`, oldest first.
fn chainOf(arena: std.mem.Allocator, docs: []const Entry, last: *const Entry) ![]const *const Entry {
    var rev: std.ArrayList(*const Entry) = .empty;
    var at: ?*const Entry = last;
    while (at) |e| {
        try rev.append(arena, e);
        if (rev.items.len > docs.len) break; // a cycle cannot happen; never loop on one
        at = if (e.prev_seq != 0) bySeq(docs, e.prev_seq) else null;
    }
    std.mem.reverse(*const Entry, rev.items);
    return rev.items;
}

/// Derive the navigation from the main-document rows logged since the
/// call's cursor.
pub fn derive(arena: std.mem.Allocator, log: Log, in: Input) !Nav {
    var docs: std.ArrayList(Entry) = .empty;
    for (log.entries) |e| if (e.document) try docs.append(arena, e);

    var nav: Nav = .{ .outcome = .no_request, .url = in.view_url, .requested_url = in.requested, .detail = log.detail };
    if (in.load_error) |le| {
        nav.error_code = le.code;
        nav.@"error" = le.msg;
    }
    if (docs.items.len == 0) {
        const where = if (in.view_url.len > 0) in.view_url else in.requested orelse "";
        nav.scheme = schemeOf(where);
        nav.outcome = if (in.download_path != null)
            .download
        else if (in.load_error != null)
            .network_error
        else if (where.len > 0 and !isHttp(where))
            .non_http
        else if (in.loading)
            .pending
        else
            .no_request;
        nav.download_path = in.download_path;
        return nav;
    }

    var last = &docs.items[docs.items.len - 1];
    for (docs.items) |*d| {
        if (d.seq > last.seq) last = d;
    }
    var earliest = &docs.items[0];
    for (docs.items) |*d| {
        if (d.seq < earliest.seq) earliest = d;
    }
    // An older helper links no hops, and its ring hands a redirected
    // request's completion to the FIRST hop's row while the last stays
    // pending: the newest finished row is the best it can say.
    if (!log.detail) {
        var done: ?*const Entry = null;
        for (docs.items) |*d| {
            if (d.done and (done == null or d.seq > done.?.seq)) done = d;
        }
        if (done) |d| last = @constCast(d);
    }
    const chain = if (log.detail) try chainOf(arena, docs.items, last) else &[_]*const Entry{last};
    // The earliest document row starts the navigation this call asked
    // for; a final chain that does not begin there superseded it.
    const superseded = log.detail and chain[0].seq != earliest.seq;

    var hops: std.ArrayList(Hop) = .empty;
    for (chain[0 .. chain.len - 1]) |h| try hops.append(arena, .{ .url = h.url, .status = h.status });
    nav.redirects = hops.items;
    // The log keeps 256 bytes of a url; the view knows the whole one.
    nav.url = if ((!log.detail and in.view_url.len > 0) or (in.view_url.len > last.url.len and std.mem.startsWith(u8, in.view_url, last.url))) in.view_url else last.url;
    nav.scheme = schemeOf(last.url);
    if (last.mime.len > 0) nav.content_type = last.mime;
    if (last.done and !last.blocked) nav.size = last.size;
    if (last.err != 0) {
        nav.error_code = last.err;
        nav.@"error" = last.err_name;
    }
    const http = isHttp(last.url);
    if (http and last.done and !last.blocked and last.status != 0) {
        nav.status = last.status;
        if (last.status_text.len > 0) nav.status_text = last.status_text;
    }

    // The refused hop of an unfollowed redirect: the navigation IS the
    // 3xx before it, and the refused url is where it pointed.
    if (last.blocked and std.mem.eql(u8, last.reason, REDIRECT_REFUSED) and chain.len >= 2) {
        const r = chain[chain.len - 2];
        nav.redirects = hops.items[0 .. hops.items.len - 1];
        nav.url = r.url;
        nav.scheme = schemeOf(r.url);
        nav.status = r.status;
        nav.status_text = if (r.status_text.len > 0) r.status_text else null;
        nav.content_type = if (r.mime.len > 0) r.mime else null;
        nav.size = null;
        nav.error_code = null;
        nav.@"error" = null;
        nav.location = last.url;
        nav.outcome = .redirect;
        return nav;
    }

    nav.outcome = blk: {
        if (last.blocked) {
            nav.blocked_reason = last.reason;
            break :blk .blocked;
        }
        if (in.download_path != null) break :blk .download;
        if (last.done and last.status >= 200 and last.status < 300 and last.mime.len > 0 and !renderable(last.mime)) break :blk .download;
        if (!last.done) break :blk if (superseded) .replaced else .pending;
        if (http and last.status >= 400) break :blk .http_error;
        if (last.err == -3) break :blk if (superseded) .replaced else .aborted;
        if (last.err != 0) break :blk .network_error;
        if (!http) break :blk .non_http;
        if (superseded) break :blk .replaced;
        if (in.load_error != null and last.status == 0) break :blk .network_error;
        break :blk .page;
    };
    if (nav.outcome == .download) nav.download_path = in.download_path;
    if (superseded) {
        // The last hop the requested navigation reached.
        var reached = earliest;
        for (docs.items) |*d| {
            if (d.prev_seq == reached.seq) reached = d;
        }
        nav.replaced_url = reached.url;
    }
    return nav;
}

/// One line of prose for the reply's text lane.
pub fn sentence(arena: std.mem.Allocator, nav: Nav) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    switch (nav.outcome) {
        .page => try w.print("navigation: HTTP {d}{s}{s}", .{ nav.status orelse 0, if (nav.status_text != null) " " else "", nav.status_text orelse "" }),
        .http_error => try w.print("navigation: HTTP ERROR {d}{s}{s} (the page shows the server's error body, or the engine's error page when it sent none)", .{ nav.status orelse 0, if (nav.status_text != null) " " else "", nav.status_text orelse "" }),
        .network_error => try w.print("navigation: NETWORK ERROR {s} ({d}): no HTTP answer", .{ nav.@"error" orelse "unknown", nav.error_code orelse 0 }),
        .aborted => try w.writeAll("navigation: ABORTED before a page arrived, and nothing replaced it"),
        .replaced => try w.print("navigation: REPLACED - another navigation superseded the one asked for (it had reached {s})", .{nav.replaced_url orelse "?"}),
        .download => try w.print("navigation: DOWNLOAD, not a page ({s}){s}{s}", .{ nav.content_type orelse "content type unknown", if (nav.download_path != null) " saved to " else "", nav.download_path orelse "" }),
        .blocked => try w.print("navigation: BLOCKED inside the engine ({s}); nothing left the process", .{nav.blocked_reason orelse "?"}),
        .non_http => try w.print("navigation: {s}: url, no HTTP status exists for it", .{if (nav.scheme.len > 0) nav.scheme else "non-HTTP"}),
        .pending => try w.writeAll("navigation: the document had not finished inside the budget"),
        .no_request => try w.writeAll("navigation: no document request was logged (a back/forward-cache or same-document navigation)"),
        .redirect => try w.print("navigation: REDIRECT {d}{s}{s} to {s}, not followed (follow_redirects:false)", .{ nav.status orelse 0, if (nav.status_text != null) " " else "", nav.status_text orelse "", nav.location orelse "?" }),
    }
    if (nav.redirects.len > 0) {
        try w.writeAll(" after ");
        for (nav.redirects, 0..) |h, i| try w.print("{s}{d}", .{ if (i > 0) "," else "", h.status });
        try w.print(" redirect{s}", .{if (nav.redirects.len > 1) "s" else ""});
    }
    if (nav.outcome != .download) if (nav.content_type) |ct| try w.print(", {s}", .{ct});
    if (nav.size) |sz| if (nav.outcome == .page or nav.outcome == .http_error) try w.print(", {d} bytes", .{sz});
    if (!nav.detail) try w.writeAll(" (this browser helper reports no redirect chain, content type or net error; those are null)");
    return aw.written();
}

// -- tests -----------------------------------------------------------

const t = std.testing;

fn testLog(arena: std.mem.Allocator, json: []const u8) Log {
    return parseLog(arena, json) catch unreachable;
}

test "a 301 -> 302 -> 200 chain is three hops of one request" {
    var a = std.heap.ArenaAllocator.init(t.allocator);
    defer a.deinit();
    const log = testLog(a.allocator(),
        \\{"next_seq":9,"detail":true,"entries":[
        \\{"seq":5,"blocked":false,"type":"document","method":"GET","url":"http://h/a","status":301,"duration_ms":1,"size":0,"redirect":true,"status_text":"Moved Permanently"},
        \\{"seq":6,"blocked":false,"type":"document","method":"GET","url":"http://h/b","status":302,"duration_ms":1,"size":0,"redirect":true,"prev_seq":5,"status_text":"Found"},
        \\{"seq":7,"blocked":false,"type":"document","method":"GET","url":"http://h/c","status":200,"duration_ms":1,"size":42,"prev_seq":6,"mime":"text/html","status_text":"OK"},
        \\{"seq":8,"blocked":false,"type":"image","method":"GET","url":"http://h/x.png","status":200,"duration_ms":1,"size":3}]}
    );
    const nav = try derive(a.allocator(), log, .{ .requested = "http://h/a", .view_url = "http://h/c" });
    try t.expectEqual(Outcome.page, nav.outcome);
    try t.expectEqual(@as(?u16, 200), nav.status);
    try t.expectEqualStrings("OK", nav.status_text.?);
    try t.expectEqualStrings("http://h/c", nav.url);
    try t.expectEqual(@as(usize, 2), nav.redirects.len);
    try t.expectEqual(@as(u16, 301), nav.redirects[0].status);
    try t.expectEqualStrings("http://h/b", nav.redirects[1].url);
    try t.expectEqualStrings("text/html", nav.content_type.?);
    try t.expectEqual(@as(?u32, 42), nav.size);
    const line = try sentence(a.allocator(), nav);
    try t.expect(std.mem.indexOf(u8, line, "301,302 redirects") != null);
}

test "404 with a body, refused connection, download, data: and blocked are distinct" {
    var a = std.heap.ArenaAllocator.init(t.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const e404 = testLog(ar,
        \\{"next_seq":2,"detail":true,"entries":[{"seq":1,"blocked":false,"type":"document","method":"GET","url":"http://h/missing","status":404,"duration_ms":1,"size":20,"mime":"text/html","status_text":"Not Found"}]}
    );
    const n404 = try derive(ar, e404, .{ .view_url = "http://h/missing" });
    try t.expectEqual(Outcome.http_error, n404.outcome);
    try t.expectEqual(@as(?u16, 404), n404.status);

    const refused = testLog(ar,
        \\{"next_seq":2,"detail":true,"entries":[{"seq":1,"blocked":false,"type":"document","method":"GET","url":"http://127.0.0.1:9/","status":0,"duration_ms":1,"size":0,"error_code":-102,"error":"net::ERR_CONNECTION_REFUSED"}]}
    );
    const nr = try derive(ar, refused, .{ .view_url = "http://127.0.0.1:9/", .load_error = .{ .code = -102, .msg = "CONNECTION_REFUSED" } });
    try t.expectEqual(Outcome.network_error, nr.outcome);
    try t.expectEqual(@as(?i64, -102), nr.error_code);
    try t.expectEqualStrings("net::ERR_CONNECTION_REFUSED", nr.@"error".?);
    try t.expectEqual(@as(?u16, null), nr.status);

    const zip = testLog(ar,
        \\{"next_seq":2,"detail":true,"entries":[{"seq":1,"blocked":false,"type":"document","method":"GET","url":"http://h/f.zip","status":200,"duration_ms":1,"size":0,"mime":"application/zip","error_code":-3,"error":"net::ERR_ABORTED"}]}
    );
    try t.expectEqual(Outcome.download, (try derive(ar, zip, .{ .view_url = "about:blank" })).outcome);
    try t.expect(!renderable("application/octet-stream") and renderable("text/html") and renderable("TEXT/plain"));

    const none = testLog(ar, "{\"next_seq\":1,\"detail\":true,\"entries\":[]}");
    const data = try derive(ar, none, .{ .requested = "data:text/html,hi", .view_url = "data:text/html,hi" });
    try t.expectEqual(Outcome.non_http, data.outcome);
    try t.expectEqualStrings("data", data.scheme);
    try t.expectEqual(Outcome.no_request, (try derive(ar, none, .{ .view_url = "https://h/" })).outcome);
    try t.expectEqual(Outcome.pending, (try derive(ar, none, .{ .view_url = "https://h/", .loading = true })).outcome);

    const blocked = testLog(ar,
        \\{"next_seq":2,"detail":true,"entries":[{"seq":1,"blocked":true,"type":"document","method":"GET","url":"http://x/","reason":"top_host"}]}
    );
    const nb = try derive(ar, blocked, .{});
    try t.expectEqual(Outcome.blocked, nb.outcome);
    try t.expectEqualStrings("top_host", nb.blocked_reason.?);
}

test "an aborted navigation is aborted alone and replaced when another one finished" {
    var a = std.heap.ArenaAllocator.init(t.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const alone = testLog(ar,
        \\{"next_seq":2,"detail":true,"entries":[{"seq":1,"blocked":false,"type":"document","method":"GET","url":"http://h/slow","status":0,"duration_ms":1,"size":0,"error_code":-3,"error":"net::ERR_ABORTED"}]}
    );
    try t.expectEqual(Outcome.aborted, (try derive(ar, alone, .{})).outcome);
    const replaced = testLog(ar,
        \\{"next_seq":3,"detail":true,"entries":[{"seq":1,"blocked":false,"type":"document","method":"GET","url":"http://h/slow","status":0,"duration_ms":1,"size":0,"error_code":-3,"error":"net::ERR_ABORTED"},
        \\{"seq":2,"blocked":false,"type":"document","method":"GET","url":"http://h/other","status":200,"duration_ms":1,"size":5,"mime":"text/html"}]}
    );
    const n = try derive(ar, replaced, .{});
    try t.expectEqual(Outcome.replaced, n.outcome);
    try t.expectEqualStrings("http://h/slow", n.replaced_url.?);
    try t.expectEqualStrings("http://h/other", n.url);
    try t.expectEqual(@as(?u16, 200), n.status);
}

test "an older helper's log yields status only, flagged as such" {
    var a = std.heap.ArenaAllocator.init(t.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const old = testLog(ar,
        \\{"next_seq":2,"entries":[{"seq":1,"blocked":false,"type":"document","method":"GET","url":"http://h/","pending":true},{"seq":2,"blocked":false,"type":"document","method":"GET","url":"http://h/x","status":200,"duration_ms":1,"size":9}]}
    );
    try t.expect(!old.detail);
    try t.expectEqual(@as(usize, 1), pendingCount(old));
    const n = try derive(ar, old, .{});
    try t.expect(!n.detail);
    try t.expectEqual(@as(?[]const u8, null), n.content_type);
    try t.expect(std.mem.indexOf(u8, try sentence(ar, n), "null") != null);
}

test "an unfollowed redirect reports the 3xx and where it pointed" {
    var a = std.heap.ArenaAllocator.init(t.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const log = testLog(ar,
        \\{"next_seq":3,"detail":true,"entries":[
        \\{"seq":1,"blocked":false,"type":"document","method":"GET","url":"http://h/r","status":302,"duration_ms":1,"size":0,"redirect":true,"status_text":"Found"},
        \\{"seq":2,"blocked":true,"type":"document","method":"GET","url":"http://h/target","reason":"redirect_refused","prev_seq":1}]}
    );
    const n = try derive(ar, log, .{ .requested = "http://h/r", .view_url = "http://h/r", .load_error = .{ .code = -20, .msg = "BLOCKED_BY_CLIENT" } });
    try t.expectEqual(Outcome.redirect, n.outcome);
    try t.expectEqual(@as(?u16, 302), n.status);
    try t.expectEqualStrings("http://h/r", n.url);
    try t.expectEqualStrings("http://h/target", n.location.?);
    try t.expectEqual(@as(usize, 0), n.redirects.len);
    try t.expect(n.@"error" == null);
    try t.expect(std.mem.indexOf(u8, try sentence(ar, n), "not followed") != null);
}

test "wait conditions: a navigation takes every one but response" {
    try t.expect(std.mem.indexOf(u8, NAV_WAIT_ITEMS, "\"response\"") == null);
    try t.expect(std.mem.indexOf(u8, NAV_WAIT_ITEMS, "\"selector\"") != null);
    try t.expect(WaitFor.selector.needsArg() and !WaitFor.load.needsArg());
}
