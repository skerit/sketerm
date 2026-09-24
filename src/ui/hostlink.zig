//! The process's shared daemon connection per host, for main-thread
//! clients that talk the file-service lane asynchronously.
//!
//! Every file-manager view, file picker (Save As, Print to PDF, the
//! portal picker, Download File without a lending pane) and every
//! second file-manager pane on a host used to dial that host's daemon
//! for itself -- an ssh bootstrap per remote open, and a local connect
//! plus stale-daemon probe per local one. A `Link` is the one
//! connection per host in this process; each client holds a `Lessee`
//! on it, the same shape as `Terminal.FsLease` (a pane lending its own
//! session connection), so a view does not care which of the two it
//! rides.
//!
//! Frames are BROADCAST: every lessee sees every frame and claims only
//! its own ids. That is sound because the browser's request, view and
//! transfer ids are minted process-wide (`browser/conn.zig`), and job
//! ids are the daemon's. A link with no lessees lingers for
//! `LINGER_MS` so a picker opened again soon reuses it, then closes.
//!
//! Threading: everything here is main-thread, except the remote dial,
//! which runs on a detached worker touching only its `DialJob` and
//! hands back through `g_idle_add` (CLAUDE.md's threading rule). The
//! link outlives the job: it stays in the table while `.connecting`.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const muxclient = @import("../mux/client.zig");
const mux_wire = @import("../mux/wire.zig");
const hostEq = @import("../filebrowser/paths.zig").hostEq;

/// How long an unused link stays open for the next lessee.
pub const LINGER_MS: c.guint = 60_000;

/// Frame-parse budget per main-loop dispatch; leftovers continue on an
/// idle so input interleaves with a fast host's stream.
const DRAIN_BUDGET_US: i64 = 8_000;

const alloc = std.heap.c_allocator;

pub const State = enum { connecting, ready, dead };

/// One client of a link. Owned by the client, which must keep it at a
/// stable address until `release`.
pub const Lessee = struct {
    ctx: *anyopaque,
    on_frame: *const fn (ctx: *anyopaque, ftype: mux_wire.FrameType, payload: []const u8) void,
    /// The link died after it was ready (transport lost).
    on_lost: *const fn (ctx: *anyopaque) void,
    /// A connecting link came up.
    on_ready: *const fn (ctx: *anyopaque) void,
    /// A connecting link's dial failed.
    on_failed: *const fn (ctx: *anyopaque) void,
    link: ?*Link = null,

    /// The shared connection while the link is ready.
    pub fn conn(self: *Lessee) ?*muxclient.Conn {
        const l = self.link orelse return null;
        if (l.state != .ready) return null;
        return &l.conn;
    }

    /// Deliver what the lessee queued on the shared connection.
    pub fn flush(self: *Lessee) void {
        const l = self.link orelse return;
        l.armWrite();
    }

    /// Leave the link; no callback fires after this.
    pub fn release(self: *Lessee) void {
        const l = self.link orelse return;
        self.link = null;
        l.remove(self);
    }
};

pub const Link = struct {
    /// null = the local daemon. Owned.
    host: ?[]u8,
    conn: muxclient.Conn = .{ .allocator = alloc, .fd = -1 },
    state: State = .connecting,
    /// Slots go null while a dispatch is iterating; compacted after.
    lessees: std.ArrayList(?*Lessee) = .empty,
    dispatching: u32 = 0,
    watch_id: c.guint = 0,
    write_watch_id: c.guint = 0,
    drain_idle: c.guint = 0,
    linger_src: c.guint = 0,

    fn liveCount(self: *const Link) usize {
        var n: usize = 0;
        for (self.lessees.items) |l| {
            if (l != null) n += 1;
        }
        return n;
    }

    fn add(self: *Link, lessee: *Lessee) bool {
        self.lessees.append(alloc, lessee) catch return false;
        lessee.link = self;
        if (self.linger_src != 0) {
            _ = c.g_source_remove(self.linger_src);
            self.linger_src = 0;
        }
        return true;
    }

    fn remove(self: *Link, lessee: *Lessee) void {
        for (self.lessees.items, 0..) |l, i| {
            if (l != lessee) continue;
            if (self.dispatching > 0) self.lessees.items[i] = null else _ = self.lessees.orderedRemove(i);
            break;
        }
        self.maybeLinger();
    }

    fn compact(self: *Link) void {
        var i: usize = 0;
        while (i < self.lessees.items.len) {
            if (self.lessees.items[i] == null) _ = self.lessees.orderedRemove(i) else i += 1;
        }
    }

    fn maybeLinger(self: *Link) void {
        if (self.state != .ready or self.liveCount() > 0 or self.linger_src != 0) return;
        self.linger_src = c.g_timeout_add(LINGER_MS, @ptrCast(&onLinger), @ptrCast(self));
    }

    fn wire(self: *Link) void {
        self.state = .ready;
        self.conn.setNonBlocking();
        self.watch_id = c.g_unix_fd_add(self.conn.fd, c.G_IO_IN | c.G_IO_HUP | c.G_IO_ERR, @ptrCast(&onReadable), @ptrCast(self));
    }

    fn armWrite(self: *Link) void {
        if (self.state != .ready or self.write_watch_id != 0) return;
        if (self.conn.wbuf.items.len == 0) return;
        self.write_watch_id = c.g_unix_fd_add(self.conn.fd, c.G_IO_OUT | c.G_IO_HUP | c.G_IO_ERR, @ptrCast(&onWritable), @ptrCast(self));
    }

    /// Hand one frame to every lessee. A lessee may release itself (or
    /// lease another) from its callback; the slots stay put meanwhile.
    fn broadcast(self: *Link, ftype: mux_wire.FrameType, payload: []const u8) void {
        self.dispatching += 1;
        var i: usize = 0;
        while (i < self.lessees.items.len) : (i += 1) {
            const l = self.lessees.items[i] orelse continue;
            l.on_frame(l.ctx, ftype, payload);
        }
        self.dispatching -= 1;
        if (self.dispatching == 0) self.compact();
    }

    /// Parse buffered frames for at most the budget.
    /// @return true when frames are still buffered.
    fn drain(self: *Link) bool {
        const deadline = c.g_get_monotonic_time() + DRAIN_BUDGET_US;
        while (self.state == .ready) {
            if (c.g_get_monotonic_time() > deadline) return true;
            const f = (self.conn.takeFrame() catch null) orelse return false;
            defer f.deinit(self.conn.allocator);
            self.broadcast(f.ftype, f.payload);
        }
        return false;
    }

    /// The connection is gone: out of the table (the next lease dials
    /// afresh), every lessee told, then freed. Callers must not touch
    /// the link afterwards.
    fn die(self: *Link) void {
        const was = self.state;
        self.state = .dead;
        unlist(self);
        self.dropSources();
        self.dispatching += 1;
        for (self.lessees.items) |maybe| {
            const l = maybe orelse continue;
            l.link = null;
            if (was == .ready) l.on_lost(l.ctx) else l.on_failed(l.ctx);
        }
        self.dispatching -= 1;
        self.destroy();
    }

    fn dropSources(self: *Link) void {
        inline for (.{ "watch_id", "write_watch_id", "drain_idle", "linger_src" }) |name| {
            if (@field(self, name) != 0) {
                _ = c.g_source_remove(@field(self, name));
                @field(self, name) = 0;
            }
        }
    }

    fn destroy(self: *Link) void {
        self.dropSources();
        if (self.conn.fd >= 0) self.conn.deinit();
        self.lessees.deinit(alloc);
        if (self.host) |h| alloc.free(h);
        alloc.destroy(self);
    }
};

/// Every link in the process (main thread only).
var links: std.ArrayList(*Link) = .empty;
/// The local daemon's stale-build check runs once per process, not per
/// open: a leftover daemon from before an upgrade is replaced the first
/// time this process reaches it.
var local_stale_checked = false;
/// Dials performed (tests and diagnostics).
pub var dial_count: usize = 0;

/// Test seam: a synchronous dialer replacing the real one for every host.
pub var test_dial: ?*const fn (host: ?[]const u8) ?muxclient.Conn = null;

fn unlist(link: *Link) void {
    for (links.items, 0..) |l, i| {
        if (l == link) {
            _ = links.orderedRemove(i);
            return;
        }
    }
}

/// Options for a remote dial, captured on the main thread.
pub const DialOptions = struct {
    /// Config.mux_udp_port_range (empty = unset).
    port_range: []const u8 = "",
    tor_socks_endpoint: []const u8 = "",
    /// The window whose live UDP terminal connection to the same host
    /// may mint a brokered ticket (`remotectl.mintUdpTicket`); null
    /// skips minting.
    window: ?*@import("window.zig").Window = null,
};

/// Join (or open) the link for `host`.
/// @return the link's state after joining: `.ready` means `conn()` is
/// usable now; `.connecting` means `on_ready`/`on_failed` follows;
/// `.dead` means the dial failed immediately (no callback follows).
pub fn lease(host: ?[]const u8, lessee: *Lessee, opts: DialOptions) State {
    for (links.items) |l| {
        if (l.state == .dead or !hostEq(l.host, host)) continue;
        if (!l.add(lessee)) return .dead;
        return l.state;
    }
    const link = alloc.create(Link) catch return .dead;
    link.* = .{ .host = if (host) |h| (alloc.dupe(u8, h) catch {
        alloc.destroy(link);
        return .dead;
    }) else null };
    links.append(alloc, link) catch {
        link.destroy();
        return .dead;
    };
    if (!link.add(lessee)) {
        unlist(link);
        link.destroy();
        return .dead;
    }
    if (test_dial) |dial| {
        dial_count += 1;
        if (dial(host)) |conn| {
            link.conn = conn;
            link.wire();
            return .ready;
        }
        return failNow(link, lessee);
    }
    if (host == null) {
        // Local: a unix-socket connect is fast, so it stays synchronous.
        dial_count += 1;
        link.conn = muxclient.Conn.connectLocalAutostart(alloc) catch return failNow(link, lessee);
        if (!local_stale_checked) {
            local_stale_checked = true;
            if (link.conn.upgradeStaleIdle(alloc)) {
                link.conn.deinit();
                link.conn = .{ .allocator = alloc, .fd = -1 };
                link.conn = muxclient.Conn.connectLocalAutostart(alloc) catch return failNow(link, lessee);
            }
        }
        link.wire();
        return .ready;
    }
    startRemoteDial(link, host.?, opts) catch return failNow(link, lessee);
    return .connecting;
}

/// An immediate failure: the caller learns it from the return value,
/// so no lessee callback fires for it.
fn failNow(link: *Link, lessee: *Lessee) State {
    lessee.link = null;
    link.lessees.clearRetainingCapacity();
    link.state = .dead;
    unlist(link);
    link.destroy();
    return .dead;
}

/// Live links (tests).
pub fn linkCount() usize {
    return links.items.len;
}

/// Close every idle link now (tests).
pub fn closeIdleForTest() void {
    var i: usize = 0;
    while (i < links.items.len) {
        const l = links.items[i];
        if (l.liveCount() == 0 and l.state != .connecting) {
            _ = links.orderedRemove(i);
            l.destroy();
        } else i += 1;
    }
}

/// Deliver whatever the link's socket holds now (tests; production
/// drains from the fd watch).
pub fn pumpForTest(lessee: *Lessee) void {
    const l = lessee.link orelse return;
    _ = l.conn.fillAvailable();
    while (l.drain()) {}
}

fn onLinger(user: ?*anyopaque) callconv(.c) c.gboolean {
    const link = cast.userData(Link, user);
    link.linger_src = 0;
    if (link.liveCount() > 0) return 0;
    unlist(link);
    link.destroy();
    return 0;
}

fn onReadable(fd: c_int, cond: c.GIOCondition, user: ?*anyopaque) callconv(.c) c.gboolean {
    _ = fd;
    const link = cast.userData(Link, user);
    const alive = link.conn.fillAvailable();
    const more = link.drain();
    if (!alive or cond & (c.G_IO_HUP | c.G_IO_ERR) != 0) {
        link.watch_id = 0;
        link.die();
        return 0;
    }
    if (more and link.drain_idle == 0) link.drain_idle = c.g_idle_add(@ptrCast(&onDrainIdle), @ptrCast(link));
    return 1;
}

fn onDrainIdle(user: ?*anyopaque) callconv(.c) c.gboolean {
    const link = cast.userData(Link, user);
    const alive = link.conn.fillAvailable();
    const more = link.drain();
    if (!alive) {
        link.drain_idle = 0;
        link.die();
        return 0;
    }
    if (more) return 1;
    link.drain_idle = 0;
    return 0;
}

fn onWritable(fd: c_int, cond: c.GIOCondition, user: ?*anyopaque) callconv(.c) c.gboolean {
    _ = fd;
    const link = cast.userData(Link, user);
    if (cond & (c.G_IO_HUP | c.G_IO_ERR) != 0) {
        link.write_watch_id = 0;
        link.die();
        return 0;
    }
    link.conn.flushQueued() catch {
        link.write_watch_id = 0;
        link.die();
        return 0;
    };
    if (link.conn.wbuf.items.len == 0) {
        link.write_watch_id = 0;
        return 0;
    }
    return 1;
}

// ======================================================================
// Remote dial (worker thread)
// ======================================================================

const DialJob = struct {
    link: *Link,
    host: []u8,
    port_range: []u8,
    tor_socks_endpoint: []u8,
    ticket: ?muxclient.UdpTicket = null,
    result: ?muxclient.Conn = null,

    fn destroy(self: *DialJob) void {
        alloc.free(self.host);
        alloc.free(self.port_range);
        alloc.free(self.tor_socks_endpoint);
        alloc.destroy(self);
    }

    fn options(self: *const DialJob) muxclient.ConnectOptions {
        return .{
            .udp_port_range = if (self.port_range.len > 0) self.port_range else null,
            .tor_socks_endpoint = self.tor_socks_endpoint,
        };
    }
};

fn startRemoteDial(link: *Link, host: []const u8, opts: DialOptions) !void {
    const job = try alloc.create(DialJob);
    errdefer alloc.destroy(job);
    const host_owned = try alloc.dupe(u8, host);
    errdefer alloc.free(host_owned);
    const range = try alloc.dupe(u8, opts.port_range);
    errdefer alloc.free(range);
    const tor = try alloc.dupe(u8, opts.tor_socks_endpoint);
    job.* = .{ .link = link, .host = host_owned, .port_range = range, .tor_socks_endpoint = tor };
    // Connection-ticket brokering: reach a UDP host's daemon over a
    // pre-minted single-use listener instead of a fresh ssh bootstrap.
    // A spawned files process gets its ticket from the GUI via env; a
    // view inside the terminal GUI mints one over a live UDP terminal
    // connection to the same host (the dial starts when it resolves).
    if (muxclient.udpTicketEligible(host)) {
        if (muxclient.takeTicketFromEnv(host)) |ticket| {
            job.ticket = ticket;
        } else if (opts.window) |win| {
            const remotectl = @import("remotectl.zig");
            if (remotectl.mintUdpTicket(win, muxclient.RemoteSpec.parse(host).host, @ptrCast(job), onMint)) return;
        }
    }
    spawnDial(job);
}

fn onMint(user: ?*anyopaque, ticket: ?muxclient.UdpTicket) void {
    const job = cast.userData(DialJob, user);
    job.ticket = ticket;
    spawnDial(job);
}

fn spawnDial(job: *DialJob) void {
    const th = std.Thread.spawn(.{}, dialThreadMain, .{job}) catch {
        job.result = null;
        _ = onDialIdle(@ptrCast(job));
        return;
    };
    th.detach();
}

fn dialThreadMain(job: *DialJob) void {
    job.result = dialRemote(job);
    _ = c.g_idle_add(@ptrCast(&onDialIdle), @ptrCast(job));
}

fn dialRemote(job: *DialJob) ?muxclient.Conn {
    if (job.ticket) |ticket| {
        if (muxclient.Conn.connectUdpTicket(alloc, job.host, ticket)) |conn| {
            return upgradeReconnect(job, conn);
        } else |_| {}
        // Ticket didn't carry (listener expired, filtered UDP): the
        // normal transports below are the unchanged fallback.
    }
    const conn = muxclient.Conn.connectRemote(alloc, job.host, job.options()) catch return null;
    return upgradeReconnect(job, conn);
}

/// Stale-daemon upgrade, on the worker where blocking is cheap: an idle
/// daemon of a different build is asked to exit and the reconnect
/// autostarts the freshly deployed binary. One attempt per dial.
fn upgradeReconnect(job: *DialJob, conn: muxclient.Conn) ?muxclient.Conn {
    var live = conn;
    if (!live.upgradeStaleIdle(alloc)) return live;
    live.deinit();
    return muxclient.Conn.connectRemote(alloc, job.host, job.options()) catch null;
}

fn onDialIdle(user: ?*anyopaque) callconv(.c) c.gboolean {
    const job = cast.userData(DialJob, user);
    const link = job.link;
    const result = job.result;
    job.destroy();
    dial_count += 1;
    const conn = result orelse {
        link.die();
        return 0;
    };
    link.conn = conn;
    link.wire();
    link.dispatching += 1;
    var i: usize = 0;
    while (i < link.lessees.items.len) : (i += 1) {
        const l = link.lessees.items[i] orelse continue;
        l.on_ready(l.ctx);
    }
    link.dispatching -= 1;
    link.compact();
    link.maybeLinger();
    return 0;
}

// ======================================================================
// Tests
// ======================================================================

const testing = std.testing;

const TestClient = struct {
    lessee: Lessee = undefined,
    frames: usize = 0,
    lost: usize = 0,
    last: [32]u8 = undefined,
    last_len: usize = 0,

    fn init(self: *TestClient) void {
        self.lessee = .{
            .ctx = @ptrCast(self),
            .on_frame = onFrame,
            .on_lost = onLost,
            .on_ready = onNothing,
            .on_failed = onNothing,
        };
    }
    fn onFrame(ctx: *anyopaque, _: mux_wire.FrameType, payload: []const u8) void {
        const self: *TestClient = @ptrCast(@alignCast(ctx));
        self.frames += 1;
        self.last_len = @min(payload.len, self.last.len);
        @memcpy(self.last[0..self.last_len], payload[0..self.last_len]);
    }
    fn onLost(ctx: *anyopaque) void {
        const self: *TestClient = @ptrCast(@alignCast(ctx));
        self.lost += 1;
    }
    fn onNothing(_: *anyopaque) void {}
};

var test_peer: c_int = -1;

fn socketpairDial(_: ?[]const u8) ?muxclient.Conn {
    var pair: [2]c_int = undefined;
    if (c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &pair) != 0) return null;
    if (test_peer >= 0) _ = c.close(test_peer);
    test_peer = pair[1];
    return .{ .allocator = alloc, .fd = pair[0], .proto = 1 };
}

test "hostlink: clients of one host share one dial, and an idle link is reused" {
    test_dial = socketpairDial;
    defer {
        test_dial = null;
        closeIdleForTest();
        if (test_peer >= 0) _ = c.close(test_peer);
        test_peer = -1;
    }
    const before = dial_count;

    var a: TestClient = .{};
    a.init();
    var b: TestClient = .{};
    b.init();
    try testing.expectEqual(State.ready, lease(null, &a.lessee, .{}));
    try testing.expectEqual(State.ready, lease(null, &b.lessee, .{}));
    try testing.expectEqual(before + 1, dial_count);
    try testing.expect(a.lessee.conn().? == b.lessee.conn().?);

    // One frame from the daemon reaches both clients.
    var peer: muxclient.Conn = .{ .allocator = alloc, .fd = test_peer, .proto = 1 };
    try peer.sendFrame(.fs_reply, "{\"req\":7}");
    pumpForTest(&a.lessee);
    try testing.expectEqual(@as(usize, 1), a.frames);
    try testing.expectEqual(@as(usize, 1), b.frames);
    try testing.expectEqualStrings("{\"req\":7}", b.last[0..b.last_len]);

    // Both leave; the link lingers and the next client rides it.
    a.lessee.release();
    b.lessee.release();
    try testing.expectEqual(@as(usize, 1), linkCount());
    var d: TestClient = .{};
    d.init();
    try testing.expectEqual(State.ready, lease(null, &d.lessee, .{}));
    try testing.expectEqual(before + 1, dial_count);

    // A dead link is forgotten: the next client dials again. The
    // link's own fd watch sees the hangup (it must be the watch: a
    // hand-called handler would leave the real watch on a closed fd).
    _ = c.shutdown(test_peer, c.SHUT_RDWR);
    var spins: usize = 0;
    while (d.lost == 0 and spins < 1000) : (spins += 1) {
        _ = c.g_main_context_iteration(null, 0);
        if (d.lost == 0) _ = c.usleep(1000);
    }
    try testing.expectEqual(@as(usize, 1), d.lost);
    try testing.expect(d.lessee.link == null);
    try testing.expectEqual(@as(usize, 0), linkCount());
    var e: TestClient = .{};
    e.init();
    try testing.expectEqual(State.ready, lease(null, &e.lessee, .{}));
    try testing.expectEqual(before + 2, dial_count);
    e.lessee.release();
}
