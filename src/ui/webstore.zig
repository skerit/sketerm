//! Async GUI client for the daemon-side web store (web_op/web_reply).
//!
//! One process-wide connection to the LOCAL daemon (the webface Client
//! singleton shape), lazily opened and watched with g_unix_fd_add —
//! the GLib loop is never blocked on the socket. Requests are nonce-
//! correlated; replies hand the raw JSON payload to the caller's
//! callback. Liveness follows the disconnect-at-teardown rule: an
//! owner whose callbacks resolve through `ctx` MUST call `cancelFor`
//! from its own deinit choke point.

const std = @import("std");
const c = @import("../c.zig").c;
const muxclient = @import("../mux/client.zig");
const mux_webstore = @import("../mux/webstore.zig");

pub const originOf = mux_webstore.originOf;

/// Reply callback: `ok` is transport-level ("a web_reply arrived");
/// `payload` is that frame's raw JSON ({req, ok, error?, ...}), empty
/// when the connection died with the request in flight.
pub const Callback = *const fn (ctx: ?*anyopaque, ok: bool, payload: []const u8) void;

const Pending = struct {
    req: u32,
    ctx: ?*anyopaque,
    cb: Callback,
};

const RETRY_MS: i64 = 5_000;

const Store = struct {
    gpa: std.mem.Allocator = undefined,
    state: enum { idle, ready, dead } = .idle,
    conn: muxclient.Conn = undefined,
    watch_id: c.guint = 0,
    write_watch_id: c.guint = 0,
    next_req: u32 = 1,
    pending: std.ArrayList(Pending) = .empty,
    /// Dead-state backoff: no reconnect storm while the daemon is gone.
    retry_at_ms: i64 = 0,
};

var g_store: Store = .{};

fn nowMs() i64 {
    return @divTrunc(c.g_get_monotonic_time(), 1000);
}

/// Bring the connection up (or report why not). False = degrade
/// silently, exactly like a store-less daemon.
fn ensure(gpa: std.mem.Allocator) bool {
    const s = &g_store;
    switch (s.state) {
        .ready => return true,
        .dead => {
            if (nowMs() < s.retry_at_ms) return false;
            s.state = .idle;
        },
        .idle => {},
    }
    s.gpa = gpa;
    // Local autostart connect is synchronous but fast — the existing
    // GUI behavior for local panes and the local file browser.
    s.conn = muxclient.Conn.connectLocalAutostart(gpa) catch {
        markDeadNoConn();
        return false;
    };
    if (!s.conn.web_store) {
        // A stale daemon predating the store; it may be upgraded any
        // time, so retry on the normal backoff.
        s.conn.deinit();
        markDeadNoConn();
        return false;
    }
    s.conn.setNonBlocking();
    s.watch_id = c.g_unix_fd_add(s.conn.fd, c.G_IO_IN | c.G_IO_HUP | c.G_IO_ERR, &onReadable, null);
    s.state = .ready;
    return true;
}

fn markDeadNoConn() void {
    const s = &g_store;
    s.state = .dead;
    s.retry_at_ms = nowMs() + RETRY_MS;
    failPending();
}

fn markDead() void {
    const s = &g_store;
    if (s.state != .ready) return;
    if (s.watch_id != 0) {
        _ = c.g_source_remove(s.watch_id);
        s.watch_id = 0;
    }
    if (s.write_watch_id != 0) {
        _ = c.g_source_remove(s.write_watch_id);
        s.write_watch_id = 0;
    }
    s.conn.deinit();
    markDeadNoConn();
}

fn failPending() void {
    const s = &g_store;
    // Swap the list out first: a callback may issue new requests.
    var doomed = s.pending;
    s.pending = .empty;
    defer doomed.deinit(s.gpa);
    for (doomed.items) |p| p.cb(p.ctx, false, "");
}

/// Drop every pending reply whose callback resolves through `ctx`.
/// The single teardown choke point for callers (WebFace.deinit).
pub fn cancelFor(ctx: *anyopaque) void {
    const s = &g_store;
    var i: usize = 0;
    while (i < s.pending.items.len) {
        if (s.pending.items[i].ctx == ctx) {
            _ = s.pending.swapRemove(i);
        } else i += 1;
    }
}

fn onReadable(fd: c_int, cond: c.GIOCondition, user: ?*anyopaque) callconv(.c) c.gboolean {
    _ = fd;
    _ = user;
    const s = &g_store;
    if (s.state != .ready) {
        s.watch_id = 0;
        return 0;
    }
    const alive = s.conn.fillAvailable();
    while (true) {
        const f = (s.conn.takeFrame() catch null) orelse break;
        defer f.deinit(s.conn.allocator);
        if (f.ftype != .web_reply) continue; // welcome noise etc.
        dispatchReply(f.payload);
    }
    if (!alive or cond & (c.G_IO_HUP | c.G_IO_ERR) != 0) {
        s.watch_id = 0;
        markDead();
        return 0;
    }
    return 1;
}

fn dispatchReply(payload: []const u8) void {
    const s = &g_store;
    const Head = struct { req: u32 = 0 };
    const parsed = std.json.parseFromSlice(Head, s.gpa, payload, .{
        .ignore_unknown_fields = true,
    }) catch return;
    const req = parsed.value.req;
    parsed.deinit();
    for (s.pending.items, 0..) |p, i| {
        if (p.req != req) continue;
        _ = s.pending.swapRemove(i);
        p.cb(p.ctx, true, payload);
        return;
    }
    // No taker: the requester was torn down (cancelFor) — fine.
}

fn onWritable(fd: c_int, cond: c.GIOCondition, user: ?*anyopaque) callconv(.c) c.gboolean {
    _ = fd;
    _ = user;
    const s = &g_store;
    if (s.state != .ready) {
        s.write_watch_id = 0;
        return 0;
    }
    if (cond & (c.G_IO_HUP | c.G_IO_ERR) != 0) {
        s.write_watch_id = 0;
        markDead();
        return 0;
    }
    s.conn.flushQueued() catch {
        s.write_watch_id = 0;
        markDead();
        return 0;
    };
    if (s.conn.wbuf.items.len == 0) {
        s.write_watch_id = 0;
        return 0;
    }
    return 1;
}

/// Queue one web_op; EAGAIN leftovers drain on a G_IO_OUT watch so a
/// full socket buffer never blocks the main loop.
fn send(gpa: std.mem.Allocator, value: anytype) bool {
    if (!ensure(gpa)) return false;
    const s = &g_store;
    s.conn.queueJson(.web_op, value) catch {
        markDead();
        return false;
    };
    if (s.conn.wbuf.items.len > 0 and s.write_watch_id == 0) {
        s.write_watch_id = c.g_unix_fd_add(s.conn.fd, c.G_IO_OUT | c.G_IO_HUP | c.G_IO_ERR, &onWritable, null);
    }
    return true;
}

fn sendTracked(gpa: std.mem.Allocator, ctx: ?*anyopaque, cb: Callback, value: anytype) bool {
    const s = &g_store;
    s.pending.append(gpa, .{ .req = valueReq(value), .ctx = ctx, .cb = cb }) catch return false;
    if (send(gpa, value)) return true;
    _ = s.pending.pop();
    return false;
}

fn valueReq(value: anytype) u32 {
    return value.req;
}

fn nextReq() u32 {
    const s = &g_store;
    const r = s.next_req;
    s.next_req +%= 1;
    if (s.next_req == 0) s.next_req = 1;
    return r;
}

// ── public API ──────────────────────────────────────────────────

/// Record one committed navigation (fire-and-forget).
pub fn recordVisit(gpa: std.mem.Allocator, url: []const u8, title: []const u8) void {
    _ = send(gpa, .{ .req = nextReq(), .op = "history_add", .url = url, .title = title });
}

/// Attach a late title to an already-recorded visit (no extra count).
pub fn recordTitle(gpa: std.mem.Allocator, url: []const u8, title: []const u8) void {
    _ = send(gpa, .{ .req = nextReq(), .op = "history_title", .url = url, .title = title });
}

pub fn historyDelete(gpa: std.mem.Allocator, url: []const u8) void {
    _ = send(gpa, .{ .req = nextReq(), .op = "history_delete", .url = url });
}

pub fn historyClear(gpa: std.mem.Allocator) void {
    _ = send(gpa, .{ .req = nextReq(), .op = "history_clear" });
}

/// Ranked history query ("" = top entries). Reply via `cb`; parse the
/// payload with `parseHits`. False = degraded, cb will never fire.
pub fn historyQuery(gpa: std.mem.Allocator, q: []const u8, max: u32, ctx: ?*anyopaque, cb: Callback) bool {
    return sendTracked(gpa, ctx, cb, .{ .req = nextReq(), .op = "history_query", .q = q, .max = max });
}

pub fn bookmarkAdd(gpa: std.mem.Allocator, url: []const u8, title: []const u8, folder: []const u8) void {
    _ = send(gpa, .{ .req = nextReq(), .op = "bookmark_add", .url = url, .title = title, .folder = folder });
}

pub fn bookmarkRemove(gpa: std.mem.Allocator, id: u64) void {
    _ = send(gpa, .{ .req = nextReq(), .op = "bookmark_remove", .id = id });
}

/// Reply via `cb`; parse with `parseBookmarks`.
pub fn bookmarkList(gpa: std.mem.Allocator, ctx: ?*anyopaque, cb: Callback) bool {
    return sendTracked(gpa, ctx, cb, .{ .req = nextReq(), .op = "bookmark_list" });
}

/// Fetch one origin's settings; parse the payload with `parseSite`.
pub fn siteGet(gpa: std.mem.Allocator, origin: []const u8, ctx: ?*anyopaque, cb: Callback) bool {
    return sendTracked(gpa, ctx, cb, .{ .req = nextReq(), .op = "site_get", .origin = origin });
}

/// Persist one origin's zoom (0 clears it back to default).
pub fn siteSetZoom(gpa: std.mem.Allocator, origin: []const u8, zoom_x100: i32) void {
    _ = send(gpa, .{ .req = nextReq(), .op = "site_set", .origin = origin, .zoom_x100 = zoom_x100 });
}

// ── reply parsing ───────────────────────────────────────────────

pub const SiteInfo = struct {
    zoom_x100: i32 = 0,
    popup: []const u8 = "",
    block: ?bool = null,
};

pub const SiteReply = struct {
    ok: bool = false,
    origin: []const u8 = "",
    site: ?SiteInfo = null,
};

/// Parse a site_get web_reply. Slices borrow `arena` memory.
pub fn parseSite(arena: std.mem.Allocator, payload: []const u8) ?SiteReply {
    const parsed = std.json.parseFromSliceLeaky(SiteReply, arena, payload, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    return parsed;
}

pub const HistoryHit = struct {
    url: []const u8 = "",
    title: []const u8 = "",
    visits: u32 = 0,
    last_ms: i64 = 0,
    score: u64 = 0,
};

const HitsReply = struct {
    ok: bool = false,
    hits: []const HistoryHit = &.{},
};

/// Parse a history_query web_reply. Slices borrow `arena` memory.
pub fn parseHits(arena: std.mem.Allocator, payload: []const u8) []const HistoryHit {
    const parsed = std.json.parseFromSliceLeaky(HitsReply, arena, payload, .{
        .ignore_unknown_fields = true,
    }) catch return &.{};
    if (!parsed.ok) return &.{};
    return parsed.hits;
}

pub const BookmarkEntry = struct {
    id: u64 = 0,
    url: []const u8 = "",
    title: []const u8 = "",
    folder: []const u8 = "",
};

const BookmarksReply = struct {
    ok: bool = false,
    bookmarks: []const BookmarkEntry = &.{},
};

/// Parse a bookmark_list web_reply. Slices borrow `arena` memory.
pub fn parseBookmarks(arena: std.mem.Allocator, payload: []const u8) []const BookmarkEntry {
    const parsed = std.json.parseFromSliceLeaky(BookmarksReply, arena, payload, .{
        .ignore_unknown_fields = true,
    }) catch return &.{};
    if (!parsed.ok) return &.{};
    return parsed.bookmarks;
}
