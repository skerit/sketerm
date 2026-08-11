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

const Session = struct {
    fd: c_int = -1,
    socks: Socks = .{},
    req_id: u32 = 0,
    chan_id: u32 = 0,
    tunneled: bool = false,

    fn active(self: *const Session) bool {
        return self.fd >= 0;
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
        if (c.getsockname(lfd, @ptrCast(&got), &glen) == 0) {
            self.port = std.mem.bigToNative(u16, got.sin_port);
        } else {
            self.port = want_port;
        }
        // Self-pipe so another thread can wake the loop to stop it.
        var pipefds: [2]c_int = .{ -1, -1 };
        if (c.pipe(&pipefds) == 0) {
            self.stop_r = pipefds[0];
            self.stop_w = pipefds[1];
            _ = c.fcntl(self.stop_r, c.F_SETFL, c.O_NONBLOCK);
        }
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
            if (s.active()) _ = c.close(s.fd);
        }
        if (self.listen_fd >= 0) _ = c.close(self.listen_fd);
        if (self.stop_r >= 0) _ = c.close(self.stop_r);
        if (self.stop_w >= 0) _ = c.close(self.stop_w);
    }

    fn freeSlot(self: *Bridge) ?*Session {
        for (&self.sessions) |*s| {
            if (!s.active()) return s;
        }
        return null;
    }

    fn byReq(self: *Bridge, req: u32) ?*Session {
        for (&self.sessions) |*s| {
            if (s.active() and s.req_id == req and !s.tunneled) return s;
        }
        return null;
    }

    fn byChan(self: *Bridge, chan: u32) ?*Session {
        for (&self.sessions) |*s| {
            if (s.active() and s.tunneled and s.chan_id == chan) return s;
        }
        return null;
    }

    fn closeSession(self: *Bridge, s: *Session) void {
        _ = self;
        if (s.tunneled) {
            // caller sends chan_close where appropriate
        }
        if (s.fd >= 0) _ = c.close(s.fd);
        s.* = .{};
    }

    fn writeAll(fd: c_int, data: []const u8) void {
        var off: usize = 0;
        while (off < data.len) {
            const n = c.write(fd, data.ptr + off, data.len - off);
            if (n <= 0) return;
            off += @intCast(n);
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
                fds[3 + i] = .{ .fd = if (s.active()) s.fd else -1, .events = c.POLLIN, .revents = 0 };
            }
            if (c.poll(&fds, fds.len, -1) < 0) return;

            if (fds[2].revents & c.POLLIN != 0) return;

            if (fds[1].revents & c.POLLIN != 0) self.acceptOne();

            if (fds[0].revents & (c.POLLIN | c.POLLHUP) != 0) {
                if (!self.pumpConn()) return;
            }

            for (&self.sessions, 0..) |*s, i| {
                if (!s.active()) continue;
                if (fds[3 + i].revents & (c.POLLIN | c.POLLHUP) == 0) continue;
                self.pumpSession(s);
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
        const n = c.read(s.fd, &buf, buf.len);
        if (n <= 0) {
            if (s.tunneled) self.sendChanClose(s.chan_id);
            self.closeSession(s);
            return;
        }
        const data = buf[0..@intCast(n)];
        if (s.tunneled) {
            self.sendChanData(s.chan_id, data);
            return;
        }
        const act = s.socks.feed(data);
        if (act.reply.len != 0) writeAll(s.fd, act.reply);
        if (act.connect_host) |host| {
            s.req_id = self.next_req;
            self.next_req += 1;
            const conn = self.conn orelse return;
            conn.sendJson(.stream_open, .{
                .req = s.req_id,
                .host = host,
                .port = act.connect_port,
            }) catch {
                self.closeSession(s);
                return;
            };
            return;
        }
        if (act.close) self.closeSession(s);
    }

    const StreamReply = struct { req: u32 = 0, ok: bool = false, chan: u32 = 0 };

    /// Frames from the daemon: `stream_reply`, `chan_data`, `chan_close`.
    fn pumpConn(self: *Bridge) bool {
        const conn = self.conn orelse return false;
        const f = conn.recvFrame() catch return false;
        defer f.deinit(self.allocator);
        switch (f.ftype) {
            .stream_reply => {
                var parsed = std.json.parseFromSlice(StreamReply, self.allocator, f.payload, .{
                    .ignore_unknown_fields = true,
                }) catch return true;
                defer parsed.deinit();
                const r = parsed.value;
                const s = self.byReq(r.req) orelse return true;
                if (r.ok and r.chan != 0) {
                    s.chan_id = r.chan;
                    s.tunneled = true;
                    writeAll(s.fd, s.socks.openedReply());
                    const pre = s.socks.pretunnelBytes();
                    if (pre.len != 0) self.sendChanData(r.chan, pre);
                } else {
                    writeAll(s.fd, s.socks.failedReply());
                    self.closeSession(s);
                }
            },
            .chan_data => {
                if (f.payload.len < 4) return true;
                const id = wire.decodeChanId(f.payload) orelse return true;
                if (self.byChan(id)) |s| writeAll(s.fd, f.payload[4..]);
            },
            .chan_close => {
                const id = wire.decodeChanId(f.payload) orelse return true;
                if (self.byChan(id)) |s| self.closeSession(s);
            },
            // chan_open (kind tcp_forward) is confirmation only — we
            // correlate by req via stream_reply.
            else => {},
        }
        return true;
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

    pub fn spawn(self: *Egress) void {
        self.thread = std.Thread.spawn(.{}, Egress.worker, .{self}) catch null;
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
