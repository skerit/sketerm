//! Async GUI client for the daemon-side web store (web_op/web_reply).
//!
//! ## Which daemon owns your browsing data
//!
//! History and bookmarks live on a DAEMON, not in the GUI's config, so
//! that they follow the user rather than the machine. Which daemon is
//! resolved once, in `storeSocket`, in this order:
//!
//! 1. `web_store_socket` in config.conf — an explicit daemon socket.
//!    Point it at a forwarded socket (`ssh -L`, or a bind-mount) and
//!    every sketerm you run reads and writes ONE history.
//! 2. `$SKETERM_MUX_SOCKET` — the daemon this environment belongs to.
//!    A GUI launched from inside a pane inherits it, which is also what
//!    keeps an isolated test instance off the user's real store.
//! 3. The per-user local daemon (autostarted), the historical default.
//!
//! What this deliberately does NOT do is dial a remote host itself: the
//! socket must be reachable as a PATH. A transport of its own would
//! duplicate the session transports for a store that is a few hundred
//! kB of JSONL, and a forwarded socket already covers the case.
//!
//! One process-wide connection (the webface Client singleton shape),
//! lazily opened and watched with g_unix_fd_add —
//! the GLib loop is never blocked on the socket. Requests are nonce-
//! correlated; replies hand the raw JSON payload to the caller's
//! callback. Liveness follows the disconnect-at-teardown rule: an
//! owner whose callbacks resolve through `ctx` MUST call `cancelFor`
//! from its own deinit choke point.

const std = @import("std");
const c = @import("../c.zig").c;
const muxclient = @import("../mux/client.zig");
const mux_webstore = @import("../mux/webstore.zig");
const proto = @import("../web/protocol.zig");

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
    // Autostart connect is synchronous but fast — the existing GUI
    // behavior for local panes and the local file browser.
    var sock_buf: [4096]u8 = undefined;
    s.conn = muxclient.Conn.connectLocalAutostartAt(gpa, storeSocket(&sock_buf)) catch {
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

/// The daemon socket the store lives on, or null for the per-user
/// default. See the header for the order and why there is no remote
/// transport here. `buf` holds the returned slice.
fn storeSocket(buf: []u8) ?[]const u8 {
    if (g_store_socket) |p| {
        if (p.len > 0 and p.len < buf.len) {
            @memcpy(buf[0..p.len], p);
            return buf[0..p.len];
        }
    }
    if (c.getenv("SKETERM_MUX_SOCKET")) |env| {
        const p = std.mem.span(env);
        if (p.len > 0 and p.len < buf.len) {
            @memcpy(buf[0..p.len], p);
            return buf[0..p.len];
        }
    }
    return null;
}

/// Config's `web_store_socket`, pointed at the live config arena by the
/// Window on startup and on every `applyConfigChange` (config-arena
/// slices are re-pointed there, never retained across a reload).
var g_store_socket: ?[]const u8 = null;

/// Called by the Window whenever the config is (re)applied. A change
/// only takes effect on the next connection, so an already-open store
/// is dropped when the target moves.
pub fn setStoreSocket(path: []const u8) void {
    const now: ?[]const u8 = if (path.len > 0) path else null;
    const same = blk: {
        if (g_store_socket == null and now == null) break :blk true;
        if (g_store_socket) |a| {
            if (now) |b| break :blk std.mem.eql(u8, a, b);
        }
        break :blk false;
    };
    g_store_socket = now;
    if (!same) reconnect();
}

/// Drop any open connection so the next request re-resolves the target.
/// `markDead` is the shared teardown (it owns both watch sources); the
/// state is then forced back to `idle` so the next request reconnects
/// at once instead of sitting out the backoff.
fn reconnect() void {
    const s = &g_store;
    if (s.state == .idle) return;
    markDead();
    s.state = .idle;
    s.retry_at_ms = 0;
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
    const req: u32 = value.req;
    s.pending.append(gpa, .{ .req = req, .ctx = ctx, .cb = cb }) catch return false;
    if (send(gpa, value)) return true;
    // A failed send may have marked the store dead, which already
    // swapped the pending list out and failed our entry — only pop
    // when the entry is still the tail we just appended.
    if (s.pending.items.len > 0 and s.pending.items[s.pending.items.len - 1].req == req)
        _ = s.pending.pop();
    return false;
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

/// Retitle / re-folder / reorder one bookmark. An empty url or title
/// and a null index mean "leave that field alone" (the daemon's rule);
/// `folder` is optional instead, because an EMPTY folder is meaningful
/// — it moves the bookmark back to the top level.
pub fn bookmarkUpdate(
    gpa: std.mem.Allocator,
    id: u64,
    url: []const u8,
    title: []const u8,
    folder: ?[]const u8,
    index: ?u32,
) void {
    _ = send(gpa, .{
        .req = nextReq(),
        .op = "bookmark_update",
        .id = id,
        .url = url,
        .title = title,
        .folder = folder,
        .index = index,
    });
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

/// Persist one origin's popup override; "" restores the app default.
pub fn siteSetPopup(gpa: std.mem.Allocator, origin: []const u8, popup: []const u8) void {
    _ = send(gpa, .{ .req = nextReq(), .op = "site_set", .origin = origin, .popup = popup });
}

/// Persist one origin's content-blocking override; null clears it back
/// to "follow the global default".
pub fn siteSetBlock(gpa: std.mem.Allocator, origin: []const u8, block: ?bool) void {
    if (block) |b| {
        _ = send(gpa, .{ .req = nextReq(), .op = "site_set", .origin = origin, .block = b });
    } else {
        _ = send(gpa, .{ .req = nextReq(), .op = "site_set", .origin = origin, .block_clear = true });
    }
}

/// Persist one permission decision for an origin. `decision` is
/// "allow" / "deny"; "" (or "default") forgets it.
pub fn siteSetPerm(gpa: std.mem.Allocator, origin: []const u8, perm: []const u8, decision: []const u8) void {
    _ = send(gpa, .{
        .req = nextReq(),
        .op = "site_set",
        .origin = origin,
        .perm = perm,
        .decision = decision,
    });
}

// ── userscripts / userstyles ────────────────────────────────────

/// Store a userscript (enabled); the reply carries its id. `name` is
/// display-only — parse it out of the source's metadata block first.
pub fn userscriptAdd(gpa: std.mem.Allocator, name: []const u8, source: []const u8, ctx: ?*anyopaque, cb: Callback) bool {
    return sendTracked(gpa, ctx, cb, .{ .req = nextReq(), .op = "userscript_add", .name = name, .source = source });
}

pub fn userscriptRemove(gpa: std.mem.Allocator, id: u64, ctx: ?*anyopaque, cb: Callback) bool {
    return sendTracked(gpa, ctx, cb, .{ .req = nextReq(), .op = "userscript_remove", .id = id });
}

pub fn userscriptEnable(gpa: std.mem.Allocator, id: u64, enabled: bool, ctx: ?*anyopaque, cb: Callback) bool {
    return sendTracked(gpa, ctx, cb, .{ .req = nextReq(), .op = "userscript_enable", .id = id, .enabled = enabled });
}

/// Reply via `cb`; parse with `parseUserscripts` (sources included).
pub fn userscriptList(gpa: std.mem.Allocator, ctx: ?*anyopaque, cb: Callback) bool {
    return sendTracked(gpa, ctx, cb, .{ .req = nextReq(), .op = "userscript_list" });
}

/// Set/replace the one style stored for `host` (empty css deletes it).
pub fn userstyleSet(gpa: std.mem.Allocator, host: []const u8, css: []const u8, enabled: bool, ctx: ?*anyopaque, cb: Callback) bool {
    return sendTracked(gpa, ctx, cb, .{ .req = nextReq(), .op = "userstyle_set", .host = host, .css = css, .enabled = enabled });
}

/// Reply via `cb`; parse with `parseUserstyle`.
pub fn userstyleGet(gpa: std.mem.Allocator, host: []const u8, ctx: ?*anyopaque, cb: Callback) bool {
    return sendTracked(gpa, ctx, cb, .{ .req = nextReq(), .op = "userstyle_get", .host = host });
}

/// Reply via `cb`; parse with `parseUserstyles`.
pub fn userstyleList(gpa: std.mem.Allocator, ctx: ?*anyopaque, cb: Callback) bool {
    return sendTracked(gpa, ctx, cb, .{ .req = nextReq(), .op = "userstyle_list" });
}

// ── containers ──────────────────────────────────────────────────

/// Every container plus every per-site rule, in one reply; parse with
/// `parseContainers`.
pub fn containerList(gpa: std.mem.Allocator, ctx: ?*anyopaque, cb: Callback) bool {
    return sendTracked(gpa, ctx, cb, .{ .req = nextReq(), .op = "container_list" });
}

/// Create a container. `jar` "" seeds the (immutable) jar key from the
/// name; reply carries the new id, parsed with `parseContainerId`.
pub fn containerAdd(
    gpa: std.mem.Allocator,
    name: []const u8,
    jar: []const u8,
    color: [3]u8,
    egress_host: []const u8,
    remote_host: []const u8,
    ctx: ?*anyopaque,
    cb: Callback,
) bool {
    return sendTracked(gpa, ctx, cb, .{
        .req = nextReq(),
        .op = "container_add",
        .name = name,
        .jar = jar,
        .color = packRgb(color),
        .egress_host = egress_host,
        .remote_host = remote_host,
    });
}

/// Rename / recolour / re-route. A null field is left alone; "" clears
/// a host. The jar key and the id can never change.
pub fn containerUpdate(
    gpa: std.mem.Allocator,
    id: u32,
    name: ?[]const u8,
    color: ?[3]u8,
    egress_host: ?[]const u8,
    remote_host: ?[]const u8,
    ctx: ?*anyopaque,
    cb: Callback,
) bool {
    return sendTracked(gpa, ctx, cb, .{
        .req = nextReq(),
        .op = "container_update",
        .container = id,
        .name = name orelse "",
        .color = if (color) |rgb| packRgb(rgb) else null,
        .egress_host = egress_host,
        .remote_host = remote_host,
    });
}

pub fn containerRemove(gpa: std.mem.Allocator, id: u32, ctx: ?*anyopaque, cb: Callback) bool {
    return sendTracked(gpa, ctx, cb, .{ .req = nextReq(), .op = "container_remove", .container = id });
}

/// "Always open this host in container X"; `id` 0 clears the rule.
pub fn containerSiteSet(gpa: std.mem.Allocator, host: []const u8, id: u32, ctx: ?*anyopaque, cb: Callback) bool {
    return sendTracked(gpa, ctx, cb, .{
        .req = nextReq(),
        .op = "container_site_set",
        .host = host,
        .container = id,
    });
}

fn packRgb(rgb: [3]u8) u32 {
    return (@as(u32, rgb[0]) << 16) | (@as(u32, rgb[1]) << 8) | @as(u32, rgb[2]);
}

// ── permission bitmask <-> store key ────────────────────────────

/// The store keys permissions by NAME, the engine by bitmask, and a
/// prompt may carry several bits at once (camera+microphone is the
/// common one). The key is therefore the '+'-joined names in bit
/// order, which round-trips exactly — matching a remembered decision
/// is on the exact bit set, so an approximate key would answer the
/// wrong prompt.
const perm_names = [_]struct { bit: u32, name: []const u8 }{
    .{ .bit = proto.perm_geolocation, .name = "geolocation" },
    .{ .bit = proto.perm_notifications, .name = "notifications" },
    .{ .bit = proto.perm_camera, .name = "camera" },
    .{ .bit = proto.perm_microphone, .name = "microphone" },
    .{ .bit = proto.perm_midi, .name = "midi" },
    .{ .bit = proto.perm_clipboard, .name = "clipboard" },
    .{ .bit = proto.perm_pointer_lock, .name = "pointer_lock" },
    .{ .bit = proto.perm_idle_detection, .name = "idle_detection" },
    .{ .bit = proto.perm_storage_access, .name = "storage_access" },
    .{ .bit = proto.perm_window_management, .name = "window_management" },
    .{ .bit = proto.perm_protected_media, .name = "protected_media" },
    .{ .bit = proto.perm_local_fonts, .name = "local_fonts" },
    .{ .bit = proto.perm_file_system, .name = "file_system" },
    .{ .bit = proto.perm_downloads, .name = "downloads" },
    .{ .bit = proto.perm_sensors, .name = "sensors" },
    .{ .bit = proto.perm_vr, .name = "vr" },
    .{ .bit = proto.perm_other, .name = "other" },
};

/// Null for an empty mask or one carrying a bit this build cannot
/// name — a decision that cannot be read back must not be written.
pub fn permKey(buf: []u8, types: u32) ?[]const u8 {
    if (types == 0) return null;
    var covered: u32 = 0;
    var len: usize = 0;
    for (perm_names) |p| {
        if (types & p.bit == 0) continue;
        covered |= p.bit;
        if (len > 0) {
            if (len + 1 > buf.len) return null;
            buf[len] = '+';
            len += 1;
        }
        if (len + p.name.len > buf.len) return null;
        @memcpy(buf[len .. len + p.name.len], p.name);
        len += p.name.len;
    }
    if (covered != types) return null;
    return buf[0..len];
}

/// Inverse of `permKey`; null when any component is unknown.
pub fn permTypes(key: []const u8) ?u32 {
    if (key.len == 0) return null;
    var types: u32 = 0;
    var it = std.mem.splitScalar(u8, key, '+');
    while (it.next()) |part| {
        const bit = for (perm_names) |p| {
            if (std.mem.eql(u8, p.name, part)) break p.bit;
        } else return null;
        types |= bit;
    }
    return types;
}

// ── reply parsing ───────────────────────────────────────────────

pub const PermEntry = struct {
    /// A `permKey` string.
    name: []const u8 = "",
    /// "allow" | "deny" (anything else is ignored).
    decision: []const u8 = "",
};

pub const SiteInfo = struct {
    zoom_x100: i32 = 0,
    popup: []const u8 = "",
    block: ?bool = null,
    perms: []const PermEntry = &.{},
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

pub const UserscriptEntry = struct {
    id: u64 = 0,
    enabled: bool = true,
    name: []const u8 = "",
    source: []const u8 = "",
};

const UserscriptsReply = struct {
    ok: bool = false,
    scripts: []const UserscriptEntry = &.{},
};

/// Parse a userscript_list web_reply. Slices borrow `arena` memory.
pub fn parseUserscripts(arena: std.mem.Allocator, payload: []const u8) []const UserscriptEntry {
    const parsed = std.json.parseFromSliceLeaky(UserscriptsReply, arena, payload, .{
        .ignore_unknown_fields = true,
    }) catch return &.{};
    if (!parsed.ok) return &.{};
    return parsed.scripts;
}

pub const UserstyleEntry = struct {
    host: []const u8 = "",
    enabled: bool = true,
    css: []const u8 = "",
};

const UserstyleReply = struct {
    ok: bool = false,
    style: ?UserstyleEntry = null,
};

/// Parse a userstyle_get web_reply; null = nothing stored (or error).
pub fn parseUserstyle(arena: std.mem.Allocator, payload: []const u8) ?UserstyleEntry {
    const parsed = std.json.parseFromSliceLeaky(UserstyleReply, arena, payload, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    if (!parsed.ok) return null;
    return parsed.style;
}

const UserstylesReply = struct {
    ok: bool = false,
    styles: []const UserstyleEntry = &.{},
};

/// Parse a userstyle_list web_reply. Slices borrow `arena` memory.
pub fn parseUserstyles(arena: std.mem.Allocator, payload: []const u8) []const UserstyleEntry {
    const parsed = std.json.parseFromSliceLeaky(UserstylesReply, arena, payload, .{
        .ignore_unknown_fields = true,
    }) catch return &.{};
    if (!parsed.ok) return &.{};
    return parsed.styles;
}

/// A stored container, as the daemon reports it. `jar` is the engine's
/// immutable cache key, NOT the display name.
pub const ContainerEntry = struct {
    id: u32 = 0,
    name: []const u8 = "",
    jar: []const u8 = "",
    color: [3]u8 = .{ 0, 0, 0 },
    egress_host: []const u8 = "",
    remote_host: []const u8 = "",
};

pub const ContainerSiteEntry = struct {
    host: []const u8 = "",
    container: u32 = 0,
};

pub const ContainersReply = struct {
    ok: bool = false,
    containers: []const ContainerEntry = &.{},
    sites: []const ContainerSiteEntry = &.{},
};

/// Parse a container_list web_reply. Slices borrow `arena` memory.
pub fn parseContainers(arena: std.mem.Allocator, payload: []const u8) ContainersReply {
    return std.json.parseFromSliceLeaky(ContainersReply, arena, payload, .{
        .ignore_unknown_fields = true,
    }) catch .{};
}

const ContainerIdReply = struct {
    ok: bool = false,
    id: u32 = 0,
};

/// The id a container_add minted, or 0 if the store refused it.
pub fn parseContainerId(arena: std.mem.Allocator, payload: []const u8) u32 {
    const parsed = std.json.parseFromSliceLeaky(ContainerIdReply, arena, payload, .{
        .ignore_unknown_fields = true,
    }) catch return 0;
    if (!parsed.ok) return 0;
    return parsed.id;
}

test "webstore: container_list reply parses containers and site rules" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const payload =
        \\{"req":3,"ok":true,
        \\ "containers":[{"id":7,"name":"Employer","jar":"Work","color":[59,130,246],
        \\                "egress_host":"","remote_host":""}],
        \\ "sites":[{"host":"example.com","container":7}]}
    ;
    const rep = parseContainers(arena.allocator(), payload);
    try t.expect(rep.ok);
    try t.expectEqual(@as(usize, 1), rep.containers.len);
    try t.expectEqual(@as(u32, 7), rep.containers[0].id);
    // The display name and the jar key are independent: this container
    // was renamed and kept its cookies.
    try t.expectEqualStrings("Employer", rep.containers[0].name);
    try t.expectEqualStrings("Work", rep.containers[0].jar);
    try t.expectEqual(@as(u8, 130), rep.containers[0].color[1]);
    try t.expectEqual(@as(usize, 1), rep.sites.len);
    try t.expectEqualStrings("example.com", rep.sites[0].host);
    try t.expectEqual(@as(u32, 7), rep.sites[0].container);
}

test "webstore: a failed container reply yields nothing, not a wrong id" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expectEqual(@as(u32, 0), parseContainerId(arena.allocator(), "{\"ok\":false,\"id\":9}"));
    try t.expectEqual(@as(u32, 5), parseContainerId(arena.allocator(), "{\"ok\":true,\"id\":5}"));
    const rep = parseContainers(arena.allocator(), "{\"ok\":false}");
    try t.expectEqual(@as(usize, 0), rep.containers.len);
    // Garbage must not throw: a degraded store is silent, never fatal.
    const bad = parseContainers(arena.allocator(), "not json");
    try t.expect(!bad.ok);
}

// ── tests ───────────────────────────────────────────────────────

test "webstore: userscript and userstyle replies parse" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const scripts = parseUserscripts(arena.allocator(),
        \\{"req":1,"ok":true,"scripts":[
        \\{"id":3,"enabled":false,"name":"A","source":"x()"},
        \\{"id":4,"name":"B","source":"y()"}]}
    );
    try t.expectEqual(@as(usize, 2), scripts.len);
    try t.expect(!scripts[0].enabled);
    try t.expectEqualStrings("x()", scripts[0].source);
    try t.expect(scripts[1].enabled);

    const style = parseUserstyle(arena.allocator(),
        \\{"req":2,"ok":true,"style":{"host":"a.com","enabled":true,"css":"b{}"}}
    ).?;
    try t.expectEqualStrings("a.com", style.host);
    try t.expect(parseUserstyle(arena.allocator(), "{\"req\":3,\"ok\":true,\"style\":null}") == null);

    const styles = parseUserstyles(arena.allocator(),
        \\{"req":4,"ok":true,"styles":[{"host":"","enabled":true,"css":"*{}"}]}
    );
    try t.expectEqual(@as(usize, 1), styles.len);
    try t.expectEqualStrings("", styles[0].host);
}

test "webstore: permission keys round-trip, including combinations" {
    const t = std.testing;
    var buf: [128]u8 = undefined;
    try t.expectEqualStrings("geolocation", permKey(&buf, proto.perm_geolocation).?);
    try t.expectEqualStrings("camera+microphone", permKey(&buf, proto.perm_camera | proto.perm_microphone).?);
    // Bit order, not argument order.
    try t.expectEqualStrings("camera+microphone", permKey(&buf, proto.perm_microphone | proto.perm_camera).?);
    try t.expectEqualStrings("other", permKey(&buf, proto.perm_other).?);

    try t.expectEqual(@as(?u32, proto.perm_geolocation), permTypes("geolocation"));
    try t.expectEqual(
        @as(?u32, proto.perm_camera | proto.perm_microphone),
        permTypes("camera+microphone"),
    );
    // An unnamed bit is never written, so it can never be misread.
    try t.expectEqual(@as(?[]const u8, null), permKey(&buf, 1 << 20));
    try t.expectEqual(@as(?[]const u8, null), permKey(&buf, proto.perm_camera | (1 << 20)));
    try t.expectEqual(@as(?[]const u8, null), permKey(&buf, 0));
    try t.expectEqual(@as(?u32, null), permTypes("teleportation"));
    try t.expectEqual(@as(?u32, null), permTypes("camera+teleportation"));
    try t.expectEqual(@as(?u32, null), permTypes(""));

    // A buffer too small fails rather than truncating into a key that
    // would name a different permission set.
    var tiny: [6]u8 = undefined;
    try t.expectEqual(@as(?[]const u8, null), permKey(&tiny, proto.perm_camera | proto.perm_microphone));
}

test "webstore: site_get replies parse their perms" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const payload =
        \\{"req":3,"ok":true,"origin":"https://a.com",
        \\"site":{"zoom_x100":200,"popup":"block","block":true,
        \\"perms":[{"name":"geolocation","decision":"deny"}]}}
    ;
    const rep = parseSite(arena.allocator(), payload).?;
    try t.expect(rep.ok);
    const site = rep.site.?;
    try t.expectEqual(@as(i32, 200), site.zoom_x100);
    try t.expectEqualStrings("block", site.popup);
    try t.expectEqual(@as(?bool, true), site.block);
    try t.expectEqual(@as(usize, 1), site.perms.len);
    try t.expectEqualStrings("deny", site.perms[0].decision);
    try t.expectEqual(@as(?u32, proto.perm_geolocation), permTypes(site.perms[0].name));

    // An origin with nothing stored: `site` is null, not an error.
    const none = parseSite(
        arena.allocator(),
        "{\"req\":4,\"ok\":true,\"origin\":\"https://b.com\",\"site\":null}",
    ).?;
    try t.expect(none.ok);
    try t.expect(none.site == null);
}
