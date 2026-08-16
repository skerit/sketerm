//! Local SOCKS5 -> mux egress bridge.
//!
//! A loopback SOCKS5 listener whose every CONNECT is relayed over a mux
//! connection to a chosen host via the `stream_open` verb, so the
//! browser's traffic LEAVES from that host and its DNS resolves there
//! ("browse via server X"). The per-container CEF request context is
//! pointed at `socks5://127.0.0.1:<port>`; this is what that url reaches.
//!
//! GTK-free: it owns a `mux/client.Conn` and a plain poll loop, so it
//! runs on a detached worker thread and touches no GTK/Screen state. The
//! SOCKS5 protocol driver (`Socks`) is a pure state machine over
//! `socks5.zig`, unit-tested headless; the poll loop is exercised by the
//! smoke-web egress stage.

const std = @import("std");
const c = @import("../c.zig").c;
const socks5 = @import("socks5.zig");
const wire = @import("../mux/wire.zig");
const client = @import("../mux/client.zig");

// ---------------------------------------------------------------------
// SOCKS5 protocol driver (pure, unit-tested)
// ---------------------------------------------------------------------

/// What a `feed` produced. `reply` (borrowing the driver's own buffer)
/// is written to the client; `connect_host`/`connect_port`, when set,
/// mean the request parsed and the transport must open the tunnel;
/// `close` closes the client after the reply.
pub const Action = struct {
    reply: []const u8 = &.{},
    connect_host: ?[]const u8 = null,
    connect_port: u16 = 0,
    close: bool = false,
};

const Phase = enum { greeting, request, tunnel };

/// One SOCKS5 conversation up to the point the byte tunnel takes over.
pub const Socks = struct {
    phase: Phase = .greeting,
    acc: [1024]u8 = undefined,
    acc_len: usize = 0,
    reply_buf: [16]u8 = undefined,
    host_buf: [256]u8 = undefined,

    fn dropAcc(self: *Socks, n: usize) void {
        std.mem.copyForwards(u8, self.acc[0 .. self.acc_len - n], self.acc[n..self.acc_len]);
        self.acc_len -= n;
    }

    /// Feed client bytes received before the tunnel exists. Returns the
    /// action the transport must take. Handles greeting and request in a
    /// single call when the client pipelines them.
    pub fn feed(self: *Socks, data: []const u8) Action {
        if (self.acc_len + data.len > self.acc.len) return .{ .close = true };
        @memcpy(self.acc[self.acc_len..][0..data.len], data);
        self.acc_len += data.len;

        var reply_len: usize = 0;

        if (self.phase == .greeting) {
            const g = (parseGreetingSafe(self.acc[0..self.acc_len]) catch return .{ .close = true }) orelse
                return .{};
            self.dropAcc(g.consumed);
            if (!g.offers_no_auth) {
                @memcpy(self.reply_buf[0..2], &socks5.methodReply(false));
                return .{ .reply = self.reply_buf[0..2], .close = true };
            }
            @memcpy(self.reply_buf[0..2], &socks5.methodReply(true));
            reply_len = 2;
            self.phase = .request;
        }

        if (self.phase == .request) {
            const r = parseRequestSafe(self.acc[0..self.acc_len]) catch |e| {
                const rep: socks5.Rep = switch (e) {
                    error.UnsupportedAtyp => .atyp_not_supported,
                    else => .general_failure,
                };
                @memcpy(self.reply_buf[reply_len..][0..10], &socks5.connectReply(rep));
                return .{ .reply = self.reply_buf[0 .. reply_len + 10], .close = true };
            } orelse return .{ .reply = self.reply_buf[0..reply_len] };
            self.dropAcc(r.consumed);
            if (r.cmd != .connect) {
                @memcpy(self.reply_buf[reply_len..][0..10], &socks5.connectReply(.cmd_not_supported));
                return .{ .reply = self.reply_buf[0 .. reply_len + 10], .close = true };
            }
            const host = socks5.formatHost(r.addr, &self.host_buf);
            self.phase = .tunnel;
            return .{
                .reply = self.reply_buf[0..reply_len],
                .connect_host = host,
                .connect_port = r.port,
            };
        }

        return .{ .reply = self.reply_buf[0..reply_len] };
    }

    /// The tunnel opened: the CONNECT success reply to send the client.
    pub fn openedReply(self: *Socks) []const u8 {
        @memcpy(self.reply_buf[0..10], &socks5.connectReply(.ok));
        return self.reply_buf[0..10];
    }

    /// The tunnel could not open: the failure reply to send the client.
    pub fn failedReply(self: *Socks) []const u8 {
        @memcpy(self.reply_buf[0..10], &socks5.connectReply(.host_unreachable));
        return self.reply_buf[0..10];
    }

    /// Client bytes that arrived accumulated before the tunnel opened
    /// (rare for CONNECT, but a pipelining client is legal) — flushed
    /// into the tunnel once it is ready.
    pub fn pretunnelBytes(self: *const Socks) []const u8 {
        return self.acc[0..self.acc_len];
    }
};

fn parseGreetingSafe(buf: []const u8) !?socks5.Greeting {
    return socks5.parseGreeting(buf);
}
fn parseRequestSafe(buf: []const u8) !?socks5.Request {
    return socks5.parseRequest(buf);
}

// ---------------------------------------------------------------------
// Transport: poll loop over a mux Conn
// ---------------------------------------------------------------------

const MAX_SESSIONS = 64;
/// Per-session client-bound backlog. A stalled browser connection is
/// closed rather than allowing the bridge's detached worker to grow
/// without bound (64 sessions therefore retain at most 64 MiB queued).
const MAX_SESSION_OUT = 1 << 20;

const Session = struct {
    fd: c_int = -1,
    socks: Socks = .{},
    req_id: u32 = 0,
    chan_id: u32 = 0,
    tunneled: bool = false,
    out: std.ArrayList(u8) = .empty,
    out_off: usize = 0,
    close_after_flush: bool = false,
    remote_closed: bool = false,

    fn active(self: *const Session) bool {
        return self.fd >= 0;
    }

    fn pendingOut(self: *const Session) usize {
        return self.out.items.len - self.out_off;
    }

    fn pollEvents(self: *const Session) c_short {
        var events: c_short = if (self.close_after_flush) 0 else c.POLLIN;
        if (self.pendingOut() != 0) events |= c.POLLOUT;
        return events;
    }

    /// Append one whole protocol/data payload or reject it without
    /// changing the queue when the per-session bound would be exceeded.
    fn enqueue(self: *Session, allocator: std.mem.Allocator, data: []const u8) !void {
        if (self.close_after_flush) return error.SessionClosing;
        if (self.out_off != 0) {
            const pending = self.pendingOut();
            std.mem.copyForwards(u8, self.out.items[0..pending], self.out.items[self.out_off..]);
            self.out.shrinkRetainingCapacity(pending);
            self.out_off = 0;
        }
        if (data.len > MAX_SESSION_OUT - self.out.items.len) return error.Backpressure;
        try self.out.appendSlice(allocator, data);
    }
};

pub const Bridge = struct {
    allocator: std.mem.Allocator,
    /// Borrowed connection to the egress host; the bridge does not own
    /// it (the caller connects and deinits). Set before `run` — nullable
    /// so the listener can be bound (and its port learned) BEFORE the
    /// possibly-slow connect completes on another thread.
    conn: ?*client.Conn = null,
    listen_fd: c_int = -1,
    stop_r: c_int = -1,
    stop_w: c_int = -1,
    /// Bound loopback port (host order), valid after `listen`.
    port: u16 = 0,
    next_req: u32 = 1,
    sessions: [MAX_SESSIONS]Session = @splat(.{}),

    pub fn init(allocator: std.mem.Allocator) Bridge {
        return .{ .allocator = allocator };
    }

    pub fn setConn(self: *Bridge, conn: *client.Conn) void {
        self.conn = conn;
    }

    /// Bind 127.0.0.1 on `want_port` (0 = auto-pick) and start listening.
    pub fn listen(self: *Bridge, want_port: u16) !void {
        const lfd = platformSocket();
        if (lfd < 0) return error.SocketFailed;
        self.listen_fd = lfd;
        errdefer {
            _ = c.close(lfd);
            self.listen_fd = -1;
            self.port = 0;
        }
        var one: c_int = 1;
        _ = c.setsockopt(lfd, c.SOL_SOCKET, c.SO_REUSEADDR, &one, @sizeOf(c_int));
        var sa = std.mem.zeroes(c.struct_sockaddr_in);
        sa.sin_family = c.AF_INET;
        sa.sin_port = std.mem.nativeToBig(u16, want_port);
        sa.sin_addr.s_addr = std.mem.nativeToBig(u32, c.INADDR_LOOPBACK);
        if (c.bind(lfd, @ptrCast(&sa), @sizeOf(c.struct_sockaddr_in)) != 0) return error.BindFailed;
        if (c.listen(lfd, 16) != 0) return error.ListenFailed;
        // Read back the actual port when auto-picked.
        var got = std.mem.zeroes(c.struct_sockaddr_in);
        var glen: c.socklen_t = @sizeOf(c.struct_sockaddr_in);
        if (c.getsockname(lfd, @ptrCast(&got), &glen) != 0) return error.GetsocknameFailed;
        self.port = std.mem.bigToNative(u16, got.sin_port);
        if (self.port == 0) return error.InvalidPort;
        // Self-pipe so another thread can wake the loop to stop it.
        var pipefds: [2]c_int = .{ -1, -1 };
        if (c.pipe(&pipefds) != 0) return error.PipeFailed;
        self.stop_r = pipefds[0];
        self.stop_w = pipefds[1];
        _ = c.fcntl(self.stop_r, c.F_SETFL, c.O_NONBLOCK);
    }

    /// Wake the poll loop and make `run` return. Thread-safe (a single
    /// byte on the self-pipe).
    pub fn requestStop(self: *Bridge) void {
        if (self.stop_w >= 0) {
            const b: [1]u8 = .{0};
            _ = c.write(self.stop_w, &b, 1);
        }
    }

    pub fn deinit(self: *Bridge) void {
        for (&self.sessions) |*s| {
            self.closeSession(s, false);
        }
        if (self.listen_fd >= 0) {
            _ = c.close(self.listen_fd);
            self.listen_fd = -1;
        }
        if (self.stop_r >= 0) {
            _ = c.close(self.stop_r);
            self.stop_r = -1;
        }
        if (self.stop_w >= 0) {
            _ = c.close(self.stop_w);
            self.stop_w = -1;
        }
    }

    fn freeSlot(self: *Bridge) ?*Session {
        for (&self.sessions) |*s| {
            if (!s.active()) return s;
        }
        return null;
    }

    fn byReq(self: *Bridge, req: u32) ?*Session {
        for (&self.sessions) |*s| {
            if (s.active() and !s.close_after_flush and s.req_id == req and !s.tunneled) return s;
        }
        return null;
    }

    fn byChan(self: *Bridge, chan: u32) ?*Session {
        for (&self.sessions) |*s| {
            if (s.active() and !s.close_after_flush and s.tunneled and s.chan_id == chan) return s;
        }
        return null;
    }

    fn closeSession(self: *Bridge, s: *Session, notify_channel: bool) void {
        if (notify_channel and s.tunneled and !s.remote_closed) self.sendChanClose(s.chan_id);
        if (s.fd >= 0) _ = c.close(s.fd);
        s.out.deinit(self.allocator);
        s.* = .{};
    }

    /// Copy a complete payload into the session queue, then make one
    /// nonblocking flush attempt. Allocation failure and the documented
    /// queue bound are fatal for this session; EAGAIN is not.
    fn queueSession(self: *Bridge, s: *Session, data: []const u8, close_after: bool) void {
        s.enqueue(self.allocator, data) catch {
            self.closeSession(s, true);
            return;
        };
        if (close_after) s.close_after_flush = true;
        self.flushSession(s);
    }

    fn flushSession(self: *Bridge, s: *Session) void {
        while (s.pendingOut() != 0) {
            const data = s.out.items[s.out_off..];
            const n = if (comptime @hasDecl(c, "MSG_NOSIGNAL"))
                c.send(s.fd, data.ptr, data.len, c.MSG_NOSIGNAL)
            else
                c.write(s.fd, data.ptr, data.len);
            if (n > 0) {
                s.out_off += @intCast(n);
                continue;
            }
            if (n == 0) {
                self.closeSession(s, true);
                return;
            }
            const e = std.posix.errno(n);
            if (e == .INTR) continue;
            if (e == .AGAIN) return;
            self.closeSession(s, true);
            return;
        }
        s.out.clearRetainingCapacity();
        s.out_off = 0;
        if (s.close_after_flush) self.closeSession(s, false);
    }

    fn closeAfterFlush(self: *Bridge, s: *Session, remote_closed: bool) void {
        s.remote_closed = remote_closed;
        self.queueSession(s, &.{}, true);
    }

    fn readSession(self: *Bridge, s: *Session, buf: []u8) ?[]const u8 {
        while (true) {
            const n = c.read(s.fd, buf.ptr, buf.len);
            if (n > 0) return buf[0..@intCast(n)];
            if (n == 0) {
                self.closeSession(s, true);
                return null;
            }
            const e = std.posix.errno(n);
            if (e == .INTR) continue;
            if (e == .AGAIN) return null;
            self.closeSession(s, true);
            return null;
        }
    }

    /// Serve until `requestStop` or the mux connection drops.
    pub fn run(self: *Bridge) void {
        const conn = self.conn orelse return;
        while (true) {
            var fds: [3 + MAX_SESSIONS]c.struct_pollfd = undefined;
            fds[0] = .{ .fd = conn.fd, .events = c.POLLIN, .revents = 0 };
            fds[1] = .{ .fd = self.listen_fd, .events = c.POLLIN, .revents = 0 };
            fds[2] = .{ .fd = self.stop_r, .events = c.POLLIN, .revents = 0 };
            for (&self.sessions, 0..) |*s, i| {
                fds[3 + i] = .{
                    .fd = if (s.active()) s.fd else -1,
                    .events = if (s.active()) s.pollEvents() else 0,
                    .revents = 0,
                };
            }
            const poll_result = c.poll(&fds, fds.len, -1);
            if (poll_result < 0) {
                if (std.posix.errno(poll_result) == .INTR) continue;
                return;
            }

            if (fds[2].revents & c.POLLIN != 0) return;

            if (fds[1].revents & c.POLLIN != 0) self.acceptOne();

            if (fds[0].revents & (c.POLLIN | c.POLLHUP) != 0) {
                if (!self.pumpConn()) return;
            }
            if (fds[0].revents & (c.POLLERR | c.POLLNVAL) != 0) return;

            for (&self.sessions, 0..) |*s, i| {
                if (!s.active()) continue;
                const revents = fds[3 + i].revents;
                if (revents & c.POLLOUT != 0) self.flushSession(s);
                if (!s.active()) continue;
                if (revents & (c.POLLIN | c.POLLHUP) != 0) self.pumpSession(s);
                if (!s.active()) continue;
                if (revents & (c.POLLERR | c.POLLNVAL) != 0) self.closeSession(s, true);
            }
        }
    }

    fn acceptOne(self: *Bridge) void {
        const afd = c.accept(self.listen_fd, null, null);
        if (afd < 0) return;
        _ = c.fcntl(afd, c.F_SETFL, c.O_NONBLOCK);
        const slot = self.freeSlot() orelse {
            _ = c.close(afd);
            return;
        };
        slot.* = .{ .fd = afd };
    }

    /// Client bytes for one session: SOCKS handshake pre-tunnel, raw
    /// tunnel bytes after.
    fn pumpSession(self: *Bridge, s: *Session) void {
        var buf: [32 * 1024]u8 = undefined;
        const data = self.readSession(s, &buf) orelse return;
        if (s.tunneled) {
            self.sendChanData(s.chan_id, data);
            return;
        }
        const act = s.socks.feed(data);
        if (act.reply.len != 0 or act.close) self.queueSession(s, act.reply, act.close);
        if (!s.active()) return;
        if (act.connect_host) |host| {
            s.req_id = self.next_req;
            self.next_req += 1;
            const conn = self.conn orelse return;
            conn.sendJson(.stream_open, .{
                .req = s.req_id,
                .host = host,
                .port = act.connect_port,
            }) catch {
                self.closeSession(s, false);
                return;
            };
            return;
        }
    }

    const StreamReply = struct { req: u32 = 0, ok: bool = false, chan: u32 = 0 };

    /// Frames from the daemon: `stream_reply`, `chan_data`, `chan_close`.
    fn pumpConn(self: *Bridge) bool {
        const conn = self.conn orelse return false;
        var f = conn.recvFrame() catch return false;
        while (true) {
            self.handleConnFrame(f.ftype, f.payload);
            f.deinit(self.allocator);
            f = (conn.takeFrame() catch return false) orelse break;
        }
        return true;
    }

    fn handleConnFrame(self: *Bridge, ftype: wire.FrameType, payload: []const u8) void {
        switch (ftype) {
            .stream_reply => {
                var parsed = std.json.parseFromSlice(StreamReply, self.allocator, payload, .{
                    .ignore_unknown_fields = true,
                }) catch return;
                defer parsed.deinit();
                const r = parsed.value;
                const s = self.byReq(r.req) orelse return;
                if (r.ok and r.chan != 0) {
                    s.chan_id = r.chan;
                    s.tunneled = true;
                    self.queueSession(s, s.socks.openedReply(), false);
                    if (!s.active()) return;
                    const pre = s.socks.pretunnelBytes();
                    if (pre.len != 0) self.sendChanData(r.chan, pre);
                } else {
                    self.queueSession(s, s.socks.failedReply(), true);
                }
            },
            .chan_data => {
                if (payload.len < 4) return;
                const id = wire.decodeChanId(payload) orelse return;
                if (self.byChan(id)) |s| self.queueSession(s, payload[4..], false);
            },
            .chan_close => {
                const id = wire.decodeChanId(payload) orelse return;
                if (self.byChan(id)) |s| self.closeAfterFlush(s, true);
            },
            // chan_open (kind tcp_forward) is confirmation only — we
            // correlate by req via stream_reply.
            else => {},
        }
    }

    fn sendChanData(self: *Bridge, chan: u32, data: []const u8) void {
        var hdr: [4]u8 = undefined;
        var msg: [4 + 32 * 1024]u8 = undefined;
        _ = wire.putChanHeader(&hdr, chan);
        var off: usize = 0;
        while (off < data.len) {
            const take = @min(data.len - off, msg.len - 4);
            @memcpy(msg[0..4], &hdr);
            @memcpy(msg[4 .. 4 + take], data[off .. off + take]);
            (self.conn orelse return).sendFrame(.chan_data, msg[0 .. 4 + take]) catch return;
            off += take;
        }
    }

    fn sendChanClose(self: *Bridge, chan: u32) void {
        var hdr: [4]u8 = undefined;
        (self.conn orelse return).sendFrame(.chan_close, wire.putChanHeader(&hdr, chan)) catch {};
    }
};

// ---------------------------------------------------------------------
// Egress orchestration: bind on the caller's thread (so the loopback
// port is known synchronously for the proxy url), then connect the mux
// transport and serve on a detached worker.
// ---------------------------------------------------------------------

pub const Egress = struct {
    allocator: std.mem.Allocator,
    bridge: Bridge,
    /// Owned connection to the egress host; connected on the worker.
    conn: client.Conn = undefined,
    conn_ok: bool = false,
    host: [256]u8 = undefined,
    host_len: usize = 0,
    thread: ?std.Thread = null,

    /// How the worker reaches the egress host's daemon. Mirrors the mux
    /// host-string convention: null = local autostart socket.
    connectFn: *const fn (allocator: std.mem.Allocator, host: ?[]const u8) ?client.Conn,

    /// Bind the loopback listener and return a heap-owned egress whose
    /// `port` is already known. `host` is copied. Call `spawn` to start
    /// serving. Returns null if the listener cannot bind.
    pub fn create(
        allocator: std.mem.Allocator,
        host: []const u8,
        connectFn: *const fn (allocator: std.mem.Allocator, host: ?[]const u8) ?client.Conn,
    ) ?*Egress {
        const self = allocator.create(Egress) catch return null;
        self.* = .{ .allocator = allocator, .bridge = Bridge.init(allocator), .connectFn = connectFn };
        self.host_len = @min(host.len, self.host.len);
        @memcpy(self.host[0..self.host_len], host[0..self.host_len]);
        self.bridge.listen(0) catch {
            allocator.destroy(self);
            return null;
        };
        return self;
    }

    pub fn port(self: *const Egress) u16 {
        return self.bridge.port;
    }

    pub fn spawn(self: *Egress) bool {
        self.thread = std.Thread.spawn(.{}, Egress.worker, .{self}) catch return false;
        return true;
    }

    fn worker(self: *Egress) void {
        const h: ?[]const u8 = if (self.host_len == 0) null else self.host[0..self.host_len];
        if (self.connectFn(self.allocator, h)) |conn| {
            self.conn = conn;
            self.conn_ok = true;
            self.bridge.setConn(&self.conn);
            self.bridge.run();
        }
        // Connect failed OR the bridge returned (mux dropped / stopped):
        // nothing left to serve, the loop exits with the thread.
    }

    /// Stop serving, join the worker, close everything. Safe to call
    /// once; the caller frees the Egress afterwards via `destroy`.
    pub fn stop(self: *Egress) void {
        self.bridge.requestStop();
        if (self.thread) |t| t.join();
        self.thread = null;
        self.bridge.deinit();
        if (self.conn_ok) {
            self.conn.deinit();
            self.conn_ok = false;
        }
    }

    pub fn destroy(self: *Egress) void {
        const a = self.allocator;
        a.destroy(self);
    }
};

fn platformSocket() c_int {
    return @import("../util/platform.zig").socketCloexec(c.AF_INET, c.SOCK_STREAM, 0);
}

// ---------------------------------------------------------------------
// Tests (driver only; the poll loop is covered by smoke-web)
// ---------------------------------------------------------------------

test "driver: greeting then domain CONNECT" {
    var s = Socks{};
    // greeting: ver 5, 1 method, no-auth
    var a = s.feed(&.{ 0x05, 0x01, 0x00 });
    try std.testing.expectEqualSlices(u8, &.{ 0x05, 0x00 }, a.reply);
    try std.testing.expectEqual(@as(?[]const u8, null), a.connect_host);
    // request: CONNECT example.com:443
    const reqbytes = [_]u8{ 0x05, 0x01, 0x00, 0x03, 0x0b } ++ "example.com".* ++ [_]u8{ 0x01, 0xBB };
    a = s.feed(&reqbytes);
    try std.testing.expect(a.connect_host != null);
    try std.testing.expectEqualStrings("example.com", a.connect_host.?);
    try std.testing.expectEqual(@as(u16, 443), a.connect_port);
    try std.testing.expectEqualSlices(u8, &.{ 0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0 }, s.openedReply());
}

test "driver: pipelined greeting+request in one feed" {
    var s = Socks{};
    const bytes = [_]u8{ 0x05, 0x01, 0x00, 0x05, 0x01, 0x00, 0x01, 1, 2, 3, 4, 0x00, 0x50 };
    const a = s.feed(&bytes);
    // method reply first, then the connect is signalled (its reply comes
    // after the tunnel).
    try std.testing.expectEqualSlices(u8, &.{ 0x05, 0x00 }, a.reply);
    try std.testing.expect(a.connect_host != null);
    try std.testing.expectEqualStrings("1.2.3.4", a.connect_host.?);
    try std.testing.expectEqual(@as(u16, 80), a.connect_port);
}

test "driver: rejects auth-required greeting" {
    var s = Socks{};
    // only method 0x02 (user/pass) offered
    const a = s.feed(&.{ 0x05, 0x01, 0x02 });
    try std.testing.expectEqualSlices(u8, &.{ 0x05, 0xFF }, a.reply);
    try std.testing.expect(a.close);
}

test "driver: BIND command is refused" {
    var s = Socks{};
    _ = s.feed(&.{ 0x05, 0x01, 0x00 });
    const a = s.feed(&.{ 0x05, 0x02, 0x00, 0x01, 1, 2, 3, 4, 0x00, 0x50 });
    try std.testing.expect(a.close);
    try std.testing.expectEqual(@as(u8, @intFromEnum(socks5.Rep.cmd_not_supported)), a.reply[a.reply.len - 9]);
}

fn testSetNonBlocking(fd: c_int) !void {
    const flags = c.fcntl(fd, c.F_GETFL);
    try std.testing.expect(flags >= 0);
    try std.testing.expectEqual(@as(c_int, 0), c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK));
}

fn testDrainSocket(fd: c_int, bytes: *std.ArrayList(u8)) !bool {
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n > 0) {
            try bytes.appendSlice(std.testing.allocator, buf[0..@intCast(n)]);
            continue;
        }
        if (n == 0) return true;
        const e = std.posix.errno(n);
        if (e == .INTR) continue;
        if (e == .AGAIN) return false;
        return error.ReadFailed;
    }
}

test "transport: stalled reader preserves replies and tunnel bytes before close" {
    const t = std.testing;
    const a = t.allocator;
    var pair: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &pair));
    defer _ = c.close(pair[1]);
    try testSetNonBlocking(pair[0]);
    try testSetNonBlocking(pair[1]);
    const tiny: c_int = 1024;
    try t.expectEqual(@as(c_int, 0), c.setsockopt(pair[0], c.SOL_SOCKET, c.SO_SNDBUF, &tiny, @sizeOf(c_int)));

    var bridge = Bridge.init(a);
    defer bridge.deinit();
    const s = &bridge.sessions[0];
    s.* = .{ .fd = pair[0] };

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(a);
    const greeting = s.socks.feed(&.{ 0x05, 0x01, 0x00 }).reply;
    try expected.appendSlice(a, greeting);
    bridge.queueSession(s, greeting, false);
    const request = s.socks.feed(&.{ 0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1, 0x01, 0xbb });
    try t.expectEqualStrings("127.0.0.1", request.connect_host.?);
    const connected = s.socks.openedReply();
    try expected.appendSlice(a, connected);
    bridge.queueSession(s, connected, false);
    s.tunneled = true;
    s.chan_id = 9;

    const body = try a.alloc(u8, 512 * 1024);
    defer a.free(body);
    for (body, 0..) |*byte, i| byte.* = @truncate(i *% 131 +% 17);
    try expected.appendSlice(a, body);
    bridge.queueSession(s, body, false);
    try t.expect(s.active());
    try t.expect(s.pendingOut() != 0);
    try t.expect(s.pendingOut() <= MAX_SESSION_OUT);

    // A remote chan_close is ordered after every accepted chan_data byte.
    // While that close is pending, only writability can advance the session.
    bridge.closeAfterFlush(s, true);
    try t.expect(s.active());
    try t.expect(s.pollEvents() & c.POLLIN == 0);
    try t.expect(s.pollEvents() & c.POLLOUT != 0);

    var received: std.ArrayList(u8) = .empty;
    defer received.deinit(a);
    while (s.active()) {
        try t.expect(!try testDrainSocket(pair[1], &received));
        if (!s.active()) break;
        var pfd = c.struct_pollfd{ .fd = s.fd, .events = c.POLLOUT, .revents = 0 };
        try t.expect(c.poll(&pfd, 1, 1000) > 0);
        try t.expect(pfd.revents & c.POLLOUT != 0);
        bridge.flushSession(s);
    }
    while (!try testDrainSocket(pair[1], &received)) {
        var pfd = c.struct_pollfd{ .fd = pair[1], .events = c.POLLIN, .revents = 0 };
        try t.expect(c.poll(&pfd, 1, 1000) > 0);
    }
    try t.expectEqualSlices(u8, expected.items, received.items);
}

test "transport: queue limit closes the session without retaining memory" {
    const t = std.testing;
    const a = t.allocator;
    var pair: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &pair));
    defer _ = c.close(pair[1]);
    try testSetNonBlocking(pair[0]);

    var bridge = Bridge.init(a);
    defer bridge.deinit();
    const s = &bridge.sessions[0];
    s.* = .{ .fd = pair[0] };
    const over_limit = try a.alloc(u8, MAX_SESSION_OUT + 1);
    defer a.free(over_limit);
    bridge.queueSession(s, over_limit, false);

    try t.expect(!s.active());
    try t.expectEqual(@as(usize, 0), s.out.items.len);
    try t.expectEqual(@as(usize, 0), s.out.capacity);
    var byte: [1]u8 = undefined;
    try t.expectEqual(@as(isize, 0), c.read(pair[1], &byte, byte.len));
}

test "transport: buffered daemon frames preserve connect-data-close order" {
    const t = std.testing;
    const a = t.allocator;
    var mux_pair: [2]c_int = undefined;
    var local_pair: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &mux_pair));
    errdefer {
        _ = c.close(mux_pair[0]);
        _ = c.close(mux_pair[1]);
    }
    try t.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &local_pair));
    defer _ = c.close(mux_pair[1]);
    defer _ = c.close(local_pair[1]);

    var conn = client.Conn{ .allocator = a, .fd = mux_pair[0] };
    defer conn.deinit();
    var bridge = Bridge.init(a);
    defer bridge.deinit();
    bridge.setConn(&conn);
    const s = &bridge.sessions[0];
    s.* = .{ .fd = local_pair[0], .req_id = 42 };

    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(a);
    try wire.appendFrame(&stream, a, .stream_reply, "{\"req\":42,\"ok\":true,\"chan\":7}");
    var first = [_]u8{0} ** (4 + 5);
    var first_header: [4]u8 = undefined;
    @memcpy(first[0..4], wire.putChanHeader(&first_header, 7));
    @memcpy(first[4..], "alpha");
    try wire.appendFrame(&stream, a, .chan_data, &first);
    var second = [_]u8{0} ** (4 + 4);
    var second_header: [4]u8 = undefined;
    @memcpy(second[0..4], wire.putChanHeader(&second_header, 7));
    @memcpy(second[4..], "beta");
    try wire.appendFrame(&stream, a, .chan_data, &second);
    var close_header: [4]u8 = undefined;
    try wire.appendFrame(&stream, a, .chan_close, wire.putChanHeader(&close_header, 7));

    // recvFrame may fill rbuf with several frames in one read. Preloading that
    // exact state makes the regression deterministic: no fd readiness recurs.
    try conn.rbuf.appendSlice(a, stream.items);
    try t.expect(bridge.pumpConn());
    try t.expect(!s.active());

    var received: std.ArrayList(u8) = .empty;
    defer received.deinit(a);
    try t.expect(try testDrainSocket(local_pair[1], &received));
    const success = socks5.connectReply(.ok);
    var expected: [success.len + 9]u8 = undefined;
    @memcpy(expected[0..success.len], &success);
    @memcpy(expected[success.len..], "alphabeta");
    try t.expectEqualSlices(u8, &expected, received.items);
}
