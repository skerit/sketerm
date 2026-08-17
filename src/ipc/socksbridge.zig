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
const channel_pump = @import("../mux/channel_pump.zig");
const platform = @import("../util/platform.zig");
const FdCancel = @import("../util/fdcancel.zig").FdCancel;

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
    local: channel_pump.Local = .{},
    socks: Socks = .{},
    req_id: u32 = 0,
    tunneled: bool = false,

    fn active(self: *const Session) bool {
        return self.local.active();
    }

    fn pollEvents(self: *const Session, mux_blocked: bool) c_short {
        return self.local.events(!mux_blocked);
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
    stop: ?platform.Wakeup = null,
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
        try self.listenUsing(want_port, platform.Wakeup.init);
    }

    fn listenUsing(
        self: *Bridge,
        want_port: u16,
        wakeup_init: *const fn () anyerror!platform.Wakeup,
    ) !void {
        const lfd = platformSocket();
        if (lfd < 0) return error.SocketFailed;
        self.listen_fd = lfd;
        errdefer {
            _ = c.close(lfd);
            self.listen_fd = -1;
            self.port = 0;
        }
        try channel_pump.configureFd(lfd);
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
        self.stop = try wakeup_init();
    }

    /// Wake the poll loop and make `run` return.
    pub fn requestStop(self: *Bridge) void {
        if (self.stop) |wake| wake.signal();
    }

    pub fn deinit(self: *Bridge) void {
        self.closeServing();
        if (self.stop) |wake| {
            wake.close();
            self.stop = null;
        }
    }

    fn closeServing(self: *Bridge) void {
        for (&self.sessions) |*s| {
            self.closeSession(s, false);
        }
        if (self.listen_fd >= 0) {
            _ = c.close(self.listen_fd);
            self.listen_fd = -1;
            self.port = 0;
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
            if (s.active() and !s.local.close_after_flush and s.req_id == req and !s.tunneled) return s;
        }
        return null;
    }

    fn byChan(self: *Bridge, chan: u32) ?*Session {
        for (&self.sessions) |*s| {
            if (s.active() and !s.local.close_after_flush and s.tunneled and s.local.chan == chan) return s;
        }
        return null;
    }

    fn closeSession(self: *Bridge, s: *Session, notify_channel: bool) void {
        var pump = self.channelPump() orelse {
            s.local.deinit(self.allocator);
            s.* = .{};
            return;
        };
        pump.closeLocal(&s.local, notify_channel and s.tunneled);
        s.* = .{};
    }

    /// Copy a complete payload into the session queue, then make one
    /// nonblocking flush attempt. Allocation failure and the documented
    /// queue bound are fatal for this session; EAGAIN is not.
    fn queueSession(self: *Bridge, s: *Session, data: []const u8, close_after: bool) void {
        var pump = self.channelPump() orelse {
            self.closeSession(s, false);
            return;
        };
        const active = pump.queueLocal(&s.local, data, close_after, false) catch {
            self.closeSession(s, true);
            return;
        };
        if (!active) s.* = .{};
    }

    fn flushSession(self: *Bridge, s: *Session) void {
        var pump = self.channelPump() orelse return self.closeSession(s, false);
        if (!pump.flushLocal(&s.local)) s.* = .{};
    }

    fn closeAfterFlush(self: *Bridge, s: *Session) void {
        var pump = self.channelPump() orelse return self.closeSession(s, false);
        if (!pump.remoteClose(&s.local)) s.* = .{};
    }

    fn readSession(self: *Bridge, s: *Session, buf: []u8) ?[]const u8 {
        return switch (channel_pump.readLocal(s.local.fd, buf)) {
            .data => |data| data,
            .would_block => null,
            .eof, .failed => blk: {
                self.closeSession(s, true);
                break :blk null;
            },
        };
    }

    fn channelPump(self: *Bridge) ?channel_pump.Pump {
        return channel_pump.Pump.init(self.allocator, self.conn orelse return null);
    }

    fn finishMuxClose(self: *Bridge) void {
        var refs: [MAX_SESSIONS]*channel_pump.Local = undefined;
        for (&self.sessions, 0..) |*s, index| refs[index] = &s.local;
        var pump = self.channelPump() orelse return;
        const cancel_fd = if (self.stop) |stop| stop.read_fd else -1;
        pump.finishAfterMuxClose(&refs, cancel_fd, channel_pump.nowMs() + 5000);
        for (&self.sessions) |*s| {
            if (!s.local.active()) s.* = .{};
        }
    }

    /// Serve until `requestStop` or the mux connection drops.
    pub fn run(self: *Bridge) void {
        const conn = self.conn orelse return;
        const stop = self.stop orelse return;
        defer self.closeServing();
        var pump = channel_pump.Pump.init(self.allocator, conn);
        pump.prepare() catch return;
        while (true) {
            if (!self.drainConnFrames()) return;
            const mux_blocked = conn.wbuf.items.len != 0;
            var fds: [3 + MAX_SESSIONS]c.struct_pollfd = undefined;
            fds[0] = .{
                .fd = conn.fd,
                .events = pump.muxEvents(true),
                .revents = 0,
            };
            fds[1] = .{ .fd = self.listen_fd, .events = if (mux_blocked) 0 else c.POLLIN, .revents = 0 };
            fds[2] = .{ .fd = stop.read_fd, .events = c.POLLIN, .revents = 0 };
            for (&self.sessions, 0..) |*s, i| {
                fds[3 + i] = .{
                    .fd = if (s.active()) s.local.fd else -1,
                    .events = if (s.active()) s.pollEvents(mux_blocked) else 0,
                    .revents = 0,
                };
            }
            if (channel_pump.wait(&fds, 2, null) != .ready) return;

            if (fds[0].revents & c.POLLOUT != 0 and !pump.flushMux()) return;

            if (fds[1].revents & c.POLLIN != 0 and conn.wbuf.items.len == 0) self.acceptOne();

            if (fds[0].revents & (c.POLLIN | c.POLLHUP) != 0) {
                if (!self.pumpConn()) return;
            }
            if (channel_pump.badPoll(fds[0].revents) or channel_pump.badPoll(fds[1].revents)) return;

            for (&self.sessions, 0..) |*s, i| {
                if (!s.active()) continue;
                const revents = fds[3 + i].revents;
                if (revents & c.POLLOUT != 0) self.flushSession(s);
                if (!s.active()) continue;
                if (revents & (c.POLLIN | c.POLLHUP) != 0 and conn.wbuf.items.len == 0)
                    self.pumpSession(s);
                if (!s.active()) continue;
                if (channel_pump.badPoll(revents)) self.closeSession(s, true);
            }
        }
    }

    fn acceptOne(self: *Bridge) void {
        const afd = (channel_pump.accept(self.listen_fd) catch return) orelse return;
        const slot = self.freeSlot() orelse {
            _ = c.close(afd);
            return;
        };
        slot.* = .{};
        slot.local.open(afd, MAX_SESSION_OUT) catch {
            _ = c.close(afd);
            return;
        };
    }

    /// Client bytes for one session: SOCKS handshake pre-tunnel, raw
    /// tunnel bytes after.
    fn pumpSession(self: *Bridge, s: *Session) void {
        var buf: [32 * 1024]u8 = undefined;
        const data = self.readSession(s, &buf) orelse return;
        if (s.tunneled) {
            self.sendChanData(s.local.chan, data);
            return;
        }
        const act = s.socks.feed(data);
        if (act.reply.len != 0 or act.close) self.queueSession(s, act.reply, act.close);
        if (!s.active()) return;
        if (act.connect_host) |host| {
            const conn = self.conn orelse return;
            // The wire contract forbids probing an old daemon with an
            // unknown frame. Keep the listener fail-closed and answer the
            // browser in SOCKS terms instead of leaving CONNECT pending.
            if (!conn.stream_open) {
                self.queueSession(s, s.socks.failedReply(), true);
                return;
            }
            s.req_id = self.next_req;
            self.next_req += 1;
            conn.queueJson(.stream_open, .{
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
        var pump = self.channelPump() orelse return false;
        if (pump.receive(self, Bridge.handlePumpFrame) == .open) return true;
        self.finishMuxClose();
        return false;
    }

    fn drainConnFrames(self: *Bridge) bool {
        var pump = self.channelPump() orelse return false;
        if (pump.drainBuffered(self, Bridge.handlePumpFrame) == .open) return true;
        self.finishMuxClose();
        return false;
    }

    fn handlePumpFrame(self: *Bridge, ftype: wire.FrameType, payload: []const u8) bool {
        self.handleConnFrame(ftype, payload);
        return true;
    }

    fn failPending(self: *Bridge) void {
        for (&self.sessions) |*s| {
            if (s.active() and !s.tunneled and s.req_id != 0)
                self.queueSession(s, s.socks.failedReply(), true);
        }
    }

    fn handleConnFrame(self: *Bridge, ftype: wire.FrameType, payload: []const u8) void {
        switch (ftype) {
            .stream_reply => {
                var parsed = std.json.parseFromSlice(StreamReply, self.allocator, payload, .{
                    .ignore_unknown_fields = true,
                }) catch {
                    self.failPending();
                    return;
                };
                defer parsed.deinit();
                const r = parsed.value;
                const s = self.byReq(r.req) orelse return;
                if (r.ok and r.chan != 0) {
                    s.local.chan = r.chan;
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
                if (self.byChan(id)) |s| self.closeAfterFlush(s);
            },
            // This connection is dedicated to stream egress, but `.err`
            // has no request id. Fail every pending CONNECT so none can
            // wait forever; established channels remain valid.
            .err => self.failPending(),
            // chan_open (kind tcp_forward) is confirmation only — we
            // correlate by req via stream_reply.
            else => {},
        }
    }

    fn sendChanData(self: *Bridge, chan: u32, data: []const u8) void {
        var pump = self.channelPump() orelse return;
        pump.queueData(chan, data) catch {};
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
    cancel: FdCancel = .{},

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
        defer self.bridge.closeServing();
        const h: ?[]const u8 = if (self.host_len == 0) null else self.host[0..self.host_len];
        if (self.connectFn(self.allocator, h)) |conn| {
            self.conn = conn;
            self.conn_ok = true;
            if (!self.conn.stream_open) {
                _ = c.fprintf(
                    platform.stderr(),
                    "sketerm web: egress through %.*s is unavailable: that host's sketerm-mux is too old (welcome lacks stream_open:true); SOCKS requests will fail closed\n",
                    @as(c_int, @intCast(self.host_len)),
                    self.host[0..].ptr,
                );
            }
            if (!(self.cancel.publish(self.conn.fd) catch return)) return;
            defer self.cancel.release();
            self.bridge.setConn(&self.conn);
            self.bridge.run();
            return;
        }
        // A connect failure leaves nothing to serve.
    }

    /// Stop serving, join the worker, close everything. Safe to call
    /// once; the caller frees the Egress afterwards via `destroy`.
    pub fn stop(self: *Egress) void {
        self.cancel.stop();
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
    return platform.socketCloexec(c.AF_INET, c.SOCK_STREAM, 0);
}

// ---------------------------------------------------------------------
// Tests
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
    var mux_pair: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), platform.socketpairCloexec(&mux_pair));
    defer _ = c.close(mux_pair[1]);
    var conn = client.Conn{ .allocator = a, .fd = mux_pair[0], .proto = wire.PROTO_VERSION };
    defer conn.deinit();

    var bridge = Bridge.init(a);
    defer bridge.deinit();
    bridge.setConn(&conn);
    const s = &bridge.sessions[0];
    try s.local.open(pair[0], MAX_SESSION_OUT);

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
    s.local.chan = 9;

    const body = try a.alloc(u8, 512 * 1024);
    defer a.free(body);
    for (body, 0..) |*byte, i| byte.* = @truncate(i *% 131 +% 17);
    try expected.appendSlice(a, body);
    bridge.queueSession(s, body, false);
    try t.expect(s.active());
    try t.expect(s.local.pending() != 0);
    try t.expect(s.local.pending() <= MAX_SESSION_OUT);

    // A remote chan_close is ordered after every accepted chan_data byte.
    // While that close is pending, only writability can advance the session.
    bridge.closeAfterFlush(s);
    try t.expect(s.active());
    try t.expect(s.pollEvents(false) & c.POLLIN == 0);
    try t.expect(s.pollEvents(false) & c.POLLOUT != 0);

    var received: std.ArrayList(u8) = .empty;
    defer received.deinit(a);
    while (s.active()) {
        try t.expect(!try testDrainSocket(pair[1], &received));
        if (!s.active()) break;
        var pfd = c.struct_pollfd{ .fd = s.local.fd, .events = c.POLLOUT, .revents = 0 };
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
    var mux_pair: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), platform.socketpairCloexec(&mux_pair));
    defer _ = c.close(mux_pair[1]);
    var conn = client.Conn{ .allocator = a, .fd = mux_pair[0], .proto = wire.PROTO_VERSION };
    defer conn.deinit();

    var bridge = Bridge.init(a);
    defer bridge.deinit();
    bridge.setConn(&conn);
    const s = &bridge.sessions[0];
    try s.local.open(pair[0], MAX_SESSION_OUT);
    const over_limit = try a.alloc(u8, MAX_SESSION_OUT + 1);
    defer a.free(over_limit);
    bridge.queueSession(s, over_limit, false);

    try t.expect(!s.active());
    try t.expectEqual(@as(usize, 0), s.local.out.items.len);
    try t.expectEqual(@as(usize, 0), s.local.out.capacity);
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
    s.* = .{ .req_id = 42 };
    try s.local.open(local_pair[0], MAX_SESSION_OUT);

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

    // Preloading several frames makes the regression deterministic: no fd
    // readiness recurs after the buffered batch is drained.
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

test "transport: local tunnel EOF queues chan_close" {
    const t = std.testing;
    var mux_pair: [2]c_int = undefined;
    var local_pair: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), platform.socketpairCloexec(&mux_pair));
    try t.expectEqual(@as(c_int, 0), platform.socketpairCloexec(&local_pair));
    var conn = client.Conn{ .allocator = t.allocator, .fd = mux_pair[0], .proto = wire.PROTO_VERSION };
    defer conn.deinit();
    var daemon = client.Conn{ .allocator = t.allocator, .fd = mux_pair[1], .proto = wire.PROTO_VERSION };
    defer daemon.deinit();
    var bridge = Bridge.init(t.allocator);
    defer bridge.deinit();
    bridge.setConn(&conn);
    const s = &bridge.sessions[0];
    try s.local.open(local_pair[0], MAX_SESSION_OUT);
    s.local.chan = 31;
    s.tunneled = true;
    _ = c.close(local_pair[1]);

    bridge.pumpSession(s);
    try t.expect(!s.active());
    const frame = try daemon.recvExpectFor(&.{.chan_close}, 1000);
    defer frame.deinit(t.allocator);
    try t.expectEqual(@as(?u32, 31), wire.decodeChanId(frame.payload));
}

test "transport: gone and mux EOF stop the SOCKS bridge" {
    const t = std.testing;
    var pair: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), platform.socketpairCloexec(&pair));
    var conn = client.Conn{ .allocator = t.allocator, .fd = pair[0], .proto = wire.PROTO_VERSION };
    defer conn.deinit();
    var bridge = Bridge.init(t.allocator);
    defer bridge.deinit();
    bridge.setConn(&conn);
    try wire.appendFrame(&conn.rbuf, t.allocator, .gone, "");
    try t.expect(!bridge.drainConnFrames());
    _ = c.shutdown(pair[1], c.SHUT_RDWR);
    _ = c.close(pair[1]);
    try t.expect(!bridge.pumpConn());
}

fn testWakeupFailure() !platform.Wakeup {
    return error.TestWakeupFailure;
}

fn testRunAndStop(bridge: *Bridge) !void {
    const thread = try std.Thread.spawn(.{}, Bridge.run, .{bridge});
    _ = c.usleep(20_000);
    const start = testNowMs();
    bridge.requestStop();
    thread.join();
    try std.testing.expect(testNowMs() - start < 1_000);
}

fn testNowMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.tv_sec) * 1000 + @divTrunc(ts.tv_nsec, 1_000_000);
}

const TestMuxPair = struct {
    conn: client.Conn,
    daemon: client.Conn,

    fn init(welcome: []const u8) !TestMuxPair {
        const a = std.testing.allocator;
        var pair: [2]c_int = undefined;
        try std.testing.expectEqual(@as(c_int, 0), platform.socketpairCloexec(&pair));
        var daemon = client.Conn{ .allocator = a, .fd = pair[1] };
        errdefer daemon.deinit();

        // A fake daemon may queue its welcome before reading hello; the
        // socket still proves that Conn.probe emitted and consumed both.
        try daemon.sendFrame(.welcome, welcome);
        var conn = try client.Conn.probe(a, .{ .allocator = a, .fd = pair[0] });
        errdefer conn.deinit();
        const hello = try daemon.recvExpectFor(&.{.hello}, 1_000);
        hello.deinit(a);
        return .{ .conn = conn, .daemon = daemon };
    }

    fn deinit(self: *TestMuxPair) void {
        self.conn.deinit();
        self.daemon.deinit();
    }
};

fn testConnectBridge(port: u16) !c_int {
    const fd = platformSocket();
    if (fd < 0) return error.SocketFailed;
    errdefer _ = c.close(fd);
    var sa = std.mem.zeroes(c.struct_sockaddr_in);
    sa.sin_family = c.AF_INET;
    sa.sin_port = std.mem.nativeToBig(u16, port);
    sa.sin_addr.s_addr = std.mem.nativeToBig(u32, c.INADDR_LOOPBACK);
    if (c.connect(fd, @ptrCast(&sa), @sizeOf(c.struct_sockaddr_in)) != 0)
        return error.ConnectFailed;
    return fd;
}

fn testWriteAll(fd: c_int, data: []const u8) !void {
    var off: usize = 0;
    while (off < data.len) {
        const n = if (comptime @hasDecl(c, "MSG_NOSIGNAL"))
            c.send(fd, data.ptr + off, data.len - off, c.MSG_NOSIGNAL)
        else
            c.write(fd, data.ptr + off, data.len - off);
        if (n > 0) {
            off += @intCast(n);
            continue;
        }
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        return error.WriteFailed;
    }
}

fn testReadExactFor(fd: c_int, out: []u8, timeout_ms: i64) !void {
    const deadline = testNowMs() + timeout_ms;
    var off: usize = 0;
    while (off < out.len) {
        const left = deadline - testNowMs();
        if (left <= 0) return error.Timeout;
        var pfd = c.struct_pollfd{ .fd = fd, .events = c.POLLIN, .revents = 0 };
        const polled = c.poll(&pfd, 1, @intCast(left));
        if (polled < 0 and std.posix.errno(polled) == .INTR) continue;
        if (polled <= 0) return error.Timeout;
        const n = c.read(fd, out.ptr + off, out.len - off);
        if (n > 0) {
            off += @intCast(n);
            continue;
        }
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        return error.UnexpectedEof;
    }
}

fn testExpectEofFor(fd: c_int, timeout_ms: i64) !void {
    const deadline = testNowMs() + timeout_ms;
    while (true) {
        const left = deadline - testNowMs();
        if (left <= 0) return error.Timeout;
        var pfd = c.struct_pollfd{ .fd = fd, .events = c.POLLIN, .revents = 0 };
        const polled = c.poll(&pfd, 1, @intCast(left));
        if (polled < 0 and std.posix.errno(polled) == .INTR) continue;
        if (polled <= 0) return error.Timeout;
        var byte: u8 = 0;
        const n = c.read(fd, &byte, 1);
        if (n == 0) return;
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        return error.UnexpectedData;
    }
}

test "transport: old daemon capability fails SOCKS CONNECT without stream_open" {
    const t = std.testing;
    var mux = try TestMuxPair.init("{\"proto\":6,\"negotiation\":1}");
    defer mux.deinit();
    try t.expect(!mux.conn.stream_open);

    var bridge = Bridge.init(t.allocator);
    defer bridge.deinit();
    try bridge.listen(0);
    bridge.setConn(&mux.conn);
    const runner = try std.Thread.spawn(.{}, Bridge.run, .{&bridge});
    defer {
        bridge.requestStop();
        runner.join();
    }

    const local = try testConnectBridge(bridge.port);
    defer _ = c.close(local);
    const request = [_]u8{
        0x05, 0x01, 0x00,
        0x05, 0x01, 0x00,
        0x01, 127,  0,
        0,    1,    0x01,
        0xbb,
    };
    try testWriteAll(local, &request);
    var got: [12]u8 = undefined;
    try testReadExactFor(local, &got, 1_000);
    try t.expectEqualSlices(u8, &socks5.methodReply(true), got[0..2]);
    try t.expectEqualSlices(u8, &socks5.connectReply(.host_unreachable), got[2..]);
    try testExpectEofFor(local, 1_000);

    var pfd = c.struct_pollfd{ .fd = mux.daemon.fd, .events = c.POLLIN, .revents = 0 };
    try t.expectEqual(@as(c_int, 0), c.poll(&pfd, 1, 50));
}

test "transport: generic daemon error fails the pending SOCKS CONNECT" {
    const t = std.testing;
    var mux = try TestMuxPair.init("{\"proto\":6,\"negotiation\":1,\"stream_open\":true}");
    defer mux.deinit();
    try t.expect(mux.conn.stream_open);

    var bridge = Bridge.init(t.allocator);
    defer bridge.deinit();
    try bridge.listen(0);
    bridge.setConn(&mux.conn);
    const runner = try std.Thread.spawn(.{}, Bridge.run, .{&bridge});
    defer {
        bridge.requestStop();
        runner.join();
    }

    const local = try testConnectBridge(bridge.port);
    defer _ = c.close(local);
    const request = [_]u8{
        0x05, 0x01, 0x00,
        0x05, 0x01, 0x00,
        0x01, 127,  0,
        0,    1,    0x01,
        0xbb,
    };
    try testWriteAll(local, &request);
    var greeting: [2]u8 = undefined;
    try testReadExactFor(local, &greeting, 1_000);
    try t.expectEqualSlices(u8, &socks5.methodReply(true), &greeting);
    const open = try mux.daemon.recvExpectFor(&.{.stream_open}, 1_000);
    open.deinit(t.allocator);
    try mux.daemon.sendFrame(.err, "{\"error\":\"unknown frame\"}");

    var failed: [10]u8 = undefined;
    try testReadExactFor(local, &failed, 1_000);
    try t.expectEqualSlices(u8, &socks5.connectReply(.host_unreachable), &failed);
    try testExpectEofFor(local, 1_000);
}

test "transport: capable daemon opens a successful stream" {
    const t = std.testing;
    var mux = try TestMuxPair.init("{\"proto\":6,\"negotiation\":1,\"stream_open\":true}");
    defer mux.deinit();
    try t.expect(mux.conn.stream_open);

    var bridge = Bridge.init(t.allocator);
    defer bridge.deinit();
    try bridge.listen(0);
    bridge.setConn(&mux.conn);
    const runner = try std.Thread.spawn(.{}, Bridge.run, .{&bridge});
    defer {
        bridge.requestStop();
        runner.join();
    }

    const local = try testConnectBridge(bridge.port);
    defer _ = c.close(local);
    const request = [_]u8{
        0x05, 0x01, 0x00,
        0x05, 0x01, 0x00,
        0x01, 127,  0,
        0,    1,    0x01,
        0xbb,
    } ++ "early".*;
    try testWriteAll(local, &request);
    var greeting: [2]u8 = undefined;
    try testReadExactFor(local, &greeting, 1_000);
    try t.expectEqualSlices(u8, &socks5.methodReply(true), &greeting);

    const open = try mux.daemon.recvExpectFor(&.{.stream_open}, 1_000);
    defer open.deinit(t.allocator);
    const Open = struct { req: u32, host: []const u8, port: u16 };
    var parsed = try std.json.parseFromSlice(Open, t.allocator, open.payload, .{});
    defer parsed.deinit();
    try t.expectEqualStrings("127.0.0.1", parsed.value.host);
    try t.expectEqual(@as(u16, 443), parsed.value.port);
    const req_id = parsed.value.req;

    const chan: u32 = 17;
    var open_buf: [5]u8 = undefined;
    try mux.daemon.sendFrame(.chan_open, wire.encodeChanOpen(&open_buf, chan, .tcp_forward));
    var reply_buf: [96]u8 = undefined;
    const reply = try std.fmt.bufPrint(&reply_buf, "{{\"req\":{d},\"ok\":true,\"chan\":{d}}}", .{ req_id, chan });
    try mux.daemon.sendFrame(.stream_reply, reply);

    const early = try mux.daemon.recvExpectFor(&.{.chan_data}, 1_000);
    defer early.deinit(t.allocator);
    try t.expectEqual(chan, wire.decodeChanId(early.payload).?);
    try t.expectEqualStrings("early", early.payload[4..]);

    var data: [4 + "remote".len]u8 = undefined;
    var data_hdr: [4]u8 = undefined;
    @memcpy(data[0..4], wire.putChanHeader(&data_hdr, chan));
    @memcpy(data[4..], "remote");
    try mux.daemon.sendFrame(.chan_data, &data);
    var close_hdr: [4]u8 = undefined;
    try mux.daemon.sendFrame(.chan_close, wire.putChanHeader(&close_hdr, chan));

    var got: [10 + "remote".len]u8 = undefined;
    try testReadExactFor(local, &got, 1_000);
    try t.expectEqualSlices(u8, &socks5.connectReply(.ok), got[0..10]);
    try t.expectEqualStrings("remote", got[10..]);
    try testExpectEofFor(local, 1_000);
}

test "transport: wakeup setup failure closes the listener" {
    const t = std.testing;
    var bridge = Bridge.init(t.allocator);
    defer bridge.deinit();
    try t.expectError(error.TestWakeupFailure, bridge.listenUsing(0, testWakeupFailure));
    try t.expectEqual(@as(c_int, -1), bridge.listen_fd);
    try t.expectEqual(@as(u16, 0), bridge.port);
    try t.expect(bridge.stop == null);
}

test "transport: stop wakes an idle mux poll" {
    const t = std.testing;
    var pair: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), platform.socketpairCloexec(&pair));
    defer _ = c.close(pair[1]);
    var conn = client.Conn{ .allocator = t.allocator, .fd = pair[0] };
    defer conn.deinit();
    var bridge = Bridge.init(t.allocator);
    defer bridge.deinit();
    try bridge.listen(0);
    bridge.setConn(&conn);
    try testRunAndStop(&bridge);
}

test "transport: stop interrupts a partial mux header" {
    const t = std.testing;
    var pair: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), platform.socketpairCloexec(&pair));
    defer _ = c.close(pair[1]);
    var conn = client.Conn{ .allocator = t.allocator, .fd = pair[0] };
    defer conn.deinit();
    try conn.setNonBlockingChecked();
    var bridge = Bridge.init(t.allocator);
    defer bridge.deinit();
    try bridge.listen(0);
    bridge.setConn(&conn);

    const partial = [_]u8{ 5, 0 };
    try t.expectEqual(@as(isize, partial.len), c.write(pair[1], &partial, partial.len));
    try t.expect(bridge.pumpConn());
    try t.expectEqual(partial.len, conn.rbuf.items.len);
    try testRunAndStop(&bridge);
}

test "transport: stop interrupts mux-send backpressure" {
    const t = std.testing;
    var pair: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), platform.socketpairCloexec(&pair));
    defer _ = c.close(pair[1]);
    const tiny: c_int = 1024;
    try t.expectEqual(@as(c_int, 0), c.setsockopt(pair[0], c.SOL_SOCKET, c.SO_SNDBUF, &tiny, @sizeOf(c_int)));
    var conn = client.Conn{ .allocator = t.allocator, .fd = pair[0] };
    defer conn.deinit();
    try conn.setNonBlockingChecked();
    const payload = [_]u8{0x5a} ** (32 * 1024);
    var attempts: usize = 0;
    while (conn.wbuf.items.len == 0 and attempts < 128) : (attempts += 1)
        try conn.queueFrame(.chan_data, &payload);
    try t.expect(conn.wbuf.items.len != 0);

    var bridge = Bridge.init(t.allocator);
    defer bridge.deinit();
    try bridge.listen(0);
    bridge.setConn(&conn);
    try testRunAndStop(&bridge);
}

const TestEgressConnector = struct {
    var fd: std.atomic.Value(c_int) = .init(-1);

    fn connect(allocator: std.mem.Allocator, _: ?[]const u8) ?client.Conn {
        const owned = fd.swap(-1, .acq_rel);
        if (owned < 0) return null;
        return .{ .allocator = allocator, .fd = owned, .stream_open = true };
    }
};

test "egress stop interrupts the published mux endpoint before join" {
    const t = std.testing;
    var pair: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), platform.socketpairCloexec(&pair));
    defer _ = c.close(pair[1]);
    TestEgressConnector.fd.store(pair[0], .release);
    const egress = Egress.create(t.allocator, "test", TestEgressConnector.connect) orelse
        return error.TestUnexpectedResult;
    var stopped = false;
    defer {
        if (!stopped) egress.stop();
        egress.destroy();
    }
    try t.expect(egress.spawn());
    const deadline = testNowMs() + 1_000;
    while (egress.cancel.fd.load(.acquire) < 0 and testNowMs() < deadline)
        _ = c.usleep(1_000);
    try t.expect(egress.cancel.fd.load(.acquire) >= 0);

    const start = testNowMs();
    egress.stop();
    stopped = true;
    try t.expect(testNowMs() - start < 1_000);
    var byte: u8 = 0;
    try t.expectEqual(@as(isize, 0), c.read(pair[1], &byte, 1));
}
