//! The one client for a GUI's JSON-lines control socket: `sketerm cli`,
//! the MCP server and its panel/web transports all talk through it.
//!
//! libc only, no GLib, so both test roots carry it. Every connect,
//! write and read is non-blocking under one absolute deadline, and a
//! failure says whether any request byte left this process: a request
//! nothing was written for can be resent, one that was partially or
//! fully written may already have run.

const std = @import("std");
const c = @import("../c.zig").c;
const clock = @import("../util/clock.zig");
const platform = @import("../util/platform.zig");
const sockpath = @import("../mux/sockpath.zig");

/// A reply line larger than this is refused rather than buffered: the
/// biggest legitimate reply is a panel document (4 MiB request bound).
pub const MAX_REPLY: usize = 16 << 20;

/// Whether a failed exchange could have reached the GUI.
pub const Delivery = enum { pre_delivery, uncertain_delivery };

pub const Failure = struct {
    err: anyerror,
    delivery: Delivery,
};

/// One request's outcome: the reply line (no newline, caller frees) or
/// a failure classified by delivery phase.
pub const Result = union(enum) {
    reply: []u8,
    failure: Failure,
};

/// A connection that can carry several request/reply exchanges.
pub const Conn = struct {
    fd: c_int,
    /// Bytes read past the end of the previous reply line.
    pending: std.ArrayList(u8) = .empty,

    /// Connect to `path` before `deadline_ms` (monotonic).
    pub fn open(path: []const u8, deadline_ms: i64) !Conn {
        if (deadline_ms - clock.nowMs() <= 0) return error.Timeout;
        const fd = platform.socketCloexec(c.AF_UNIX, c.SOCK_STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        errdefer _ = c.close(fd);
        const flags = c.fcntl(fd, c.F_GETFL);
        if (flags < 0 or c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK) != 0)
            return error.NonBlockingFailed;
        var addr: c.struct_sockaddr_un = undefined;
        try sockpath.fillSockaddrUn(&addr, path);
        const rc = c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un));
        if (rc != 0) {
            const e = std.posix.errno(rc);
            if (e != .INPROGRESS and e != .AGAIN and e != .ALREADY) return error.ConnectFailed;
            try pollUntil(fd, c.POLLOUT, deadline_ms);
        }
        var so_error: c_int = 0;
        var so_len: c.socklen_t = @sizeOf(c_int);
        if (c.getsockopt(fd, c.SOL_SOCKET, c.SO_ERROR, &so_error, &so_len) != 0 or so_error != 0)
            return error.ConnectFailed;
        return .{ .fd = fd };
    }

    pub fn close(self: *Conn, allocator: std.mem.Allocator) void {
        self.pending.deinit(allocator);
        if (self.fd >= 0) _ = c.close(self.fd);
        self.fd = -1;
    }

    /// True when an idle connection can no longer carry a request: the
    /// peer hung up, or sent bytes nobody asked for (the stream's
    /// position is then unknown). Never blocks.
    pub fn peerClosed(self: *const Conn) bool {
        if (self.fd < 0 or self.pending.items.len > 0) return true;
        var pfd = c.struct_pollfd{ .fd = self.fd, .events = c.POLLIN, .revents = 0 };
        const rc = c.poll(&pfd, 1, 0);
        if (rc < 0) return std.posix.errno(rc) != .INTR;
        if (rc == 0) return false;
        return pfd.revents & (c.POLLIN | c.POLLERR | c.POLLHUP | c.POLLNVAL) != 0;
    }

    /// Send `line` (a newline is appended) and read one reply line.
    pub fn exchange(self: *Conn, allocator: std.mem.Allocator, line: []const u8, deadline_ms: i64) Result {
        const sent = self.writeLine(line, deadline_ms);
        if (sent) |f| return .{ .failure = f };
        return self.readLine(allocator, deadline_ms);
    }

    fn writeLine(self: *Conn, line: []const u8, deadline_ms: i64) ?Failure {
        var written: usize = 0;
        const total = line.len + 1;
        while (written < total) {
            if (deadline_ms - clock.nowMs() <= 0) return failure(error.Timeout, written > 0);
            const chunk: []const u8 = if (written < line.len) line[written..] else "\n";
            const n = if (comptime @hasDecl(c, "MSG_NOSIGNAL"))
                c.send(self.fd, chunk.ptr, chunk.len, c.MSG_NOSIGNAL)
            else
                c.write(self.fd, chunk.ptr, chunk.len);
            if (n > 0) {
                written += @intCast(n);
                continue;
            }
            const e = std.posix.errno(n);
            if (e == .INTR) continue;
            if (e != .AGAIN) return failure(error.WriteFailed, written > 0);
            pollUntil(self.fd, c.POLLOUT, deadline_ms) catch |err| return failure(err, written > 0);
        }
        return null;
    }

    fn readLine(self: *Conn, allocator: std.mem.Allocator, deadline_ms: i64) Result {
        while (true) {
            if (std.mem.indexOfScalar(u8, self.pending.items, '\n')) |end| {
                const owned = allocator.dupe(u8, self.pending.items[0..end]) catch |err|
                    return .{ .failure = failure(err, true) };
                const rest = self.pending.items.len - (end + 1);
                std.mem.copyForwards(u8, self.pending.items[0..rest], self.pending.items[end + 1 ..]);
                self.pending.shrinkRetainingCapacity(rest);
                return .{ .reply = owned };
            }
            if (self.pending.items.len >= MAX_REPLY) return .{ .failure = failure(error.ResponseTooLarge, true) };
            var buf: [16 << 10]u8 = undefined;
            const n = c.read(self.fd, &buf, buf.len);
            if (n > 0) {
                self.pending.appendSlice(allocator, buf[0..@intCast(n)]) catch |err|
                    return .{ .failure = failure(err, true) };
                continue;
            }
            if (n == 0) return .{ .failure = failure(error.NoResponse, true) };
            const e = std.posix.errno(n);
            if (e == .INTR) continue;
            if (e != .AGAIN) return .{ .failure = failure(error.NoResponse, true) };
            pollUntil(self.fd, c.POLLIN, deadline_ms) catch |err| return .{ .failure = failure(err, true) };
        }
    }
};

/// One connection kept open across requests to the same socket: a
/// long-lived client (the MCP server) pays one connect, not one per
/// call. A connection the GUI closed while idle is noticed before the
/// write and replaced; a reused connection that fails before any byte
/// left is redialed once (the GUI may have closed it between the check
/// and the write). Anything else drops the connection, since the
/// stream's position is then unknown, and is never resent.
pub const Persistent = struct {
    allocator: std.mem.Allocator,
    conn: ?Conn = null,
    /// The path `conn` was opened for; a different path redials.
    path_buf: [128]u8 = undefined,
    path_len: usize = 0,
    /// Connections opened so far (tests assert reuse through it).
    dials: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) Persistent {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Persistent) void {
        self.drop();
    }

    fn drop(self: *Persistent) void {
        if (self.conn) |*conn| conn.close(self.allocator);
        self.conn = null;
    }

    /// Send `line` to `path` and read its reply (owned by `allocator`).
    pub fn exchange(self: *Persistent, allocator: std.mem.Allocator, path: []const u8, line: []const u8, timeout_ms: i64) Result {
        const deadline = clock.nowMs() + @max(timeout_ms, 0);
        if (self.conn) |*conn| {
            if (!std.mem.eql(u8, self.path_buf[0..self.path_len], path) or conn.peerClosed()) self.drop();
        }
        var attempt: u8 = 0;
        while (true) : (attempt += 1) {
            const reused = self.conn != null;
            if (self.conn == null) {
                if (path.len > self.path_buf.len) return .{ .failure = failure(error.PathTooLong, false) };
                self.conn = Conn.open(path, deadline) catch |err| return .{ .failure = failure(err, false) };
                self.dials += 1;
                @memcpy(self.path_buf[0..path.len], path);
                self.path_len = path.len;
            }
            switch (self.conn.?.exchange(self.allocator, line, deadline)) {
                .reply => |reply| {
                    defer self.allocator.free(reply);
                    const owned = allocator.dupe(u8, reply) catch |err| return .{ .failure = failure(err, true) };
                    return .{ .reply = owned };
                },
                .failure => |f| {
                    self.drop();
                    if (reused and attempt == 0 and f.delivery == .pre_delivery) continue;
                    return .{ .failure = f };
                },
            }
        }
    }
};

/// Connect, exchange one request line, close: the shape of every
/// one-shot command.
pub fn exchangeOnce(allocator: std.mem.Allocator, path: []const u8, line: []const u8, timeout_ms: i64) Result {
    const deadline = clock.nowMs() + @max(timeout_ms, 0);
    var conn = Conn.open(path, deadline) catch |err| return .{ .failure = failure(err, false) };
    defer conn.close(allocator);
    return conn.exchange(allocator, line, deadline);
}

/// True when `path` has a listener accepting connections; a stale file
/// left by a crashed instance refuses the connect.
pub fn alive(path: []const u8) bool {
    var conn = Conn.open(path, clock.nowMs() + 1_000) catch return false;
    _ = c.close(conn.fd);
    conn.fd = -1;
    return true;
}

fn failure(err: anyerror, started: bool) Failure {
    return .{ .err = err, .delivery = if (started) .uncertain_delivery else .pre_delivery };
}

fn pollUntil(fd: c_int, events: c_short, deadline_ms: i64) !void {
    while (true) {
        const remain = deadline_ms - clock.nowMs();
        if (remain <= 0) return error.Timeout;
        var pfd = c.struct_pollfd{ .fd = fd, .events = events, .revents = 0 };
        const rc = c.poll(&pfd, 1, @intCast(@min(remain, 100)));
        if (rc < 0 and std.posix.errno(rc) == .INTR) continue;
        if (rc > 0 and pfd.revents & events != 0) return;
        if (rc < 0 or pfd.revents & (c.POLLERR | c.POLLHUP | c.POLLNVAL) != 0)
            return error.Disconnected;
    }
}

// ── tests ─────────────────────────────────────────────────────────

const t = std.testing;

/// A listening socket under /tmp (never under cwd: sockaddr_un caps the path).
const TestListener = struct {
    fd: c_int,
    path_buf: [96]u8 = undefined,
    path_len: usize = 0,

    fn init() !TestListener {
        var self: TestListener = .{ .fd = -1 };
        const p = try std.fmt.bufPrint(&self.path_buf, "/tmp/sk-ctl-{d}-{d}.sock", .{ c.getpid(), clock.nowNs() });
        self.path_len = p.len;
        var addr: c.struct_sockaddr_un = undefined;
        try sockpath.fillSockaddrUn(&addr, p);
        self.fd = platform.socketCloexec(c.AF_UNIX, c.SOCK_STREAM, 0);
        if (self.fd < 0) return error.SocketFailed;
        if (c.bind(self.fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0) return error.BindFailed;
        if (c.listen(self.fd, 4) != 0) return error.ListenFailed;
        return self;
    }

    fn path(self: *const TestListener) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    fn deinit(self: *TestListener) void {
        _ = c.close(self.fd);
        var z: [97]u8 = undefined;
        @memcpy(z[0..self.path_len], self.path());
        z[self.path_len] = 0;
        _ = c.unlink(@ptrCast(&z));
    }
};

const Peer = struct {
    /// Replies written after each request line; an empty entry closes
    /// the connection without answering.
    fn serve(listen_fd: c_int, replies: []const []const u8) void {
        const fd = c.accept(listen_fd, null, null);
        if (fd < 0) return;
        defer _ = c.close(fd);
        var buf: [4096]u8 = undefined;
        var have: usize = 0;
        for (replies) |reply| {
            while (std.mem.indexOfScalar(u8, buf[0..have], '\n') == null) {
                const n = c.read(fd, buf[have..].ptr, buf.len - have);
                if (n <= 0) return;
                have += @intCast(n);
            }
            const end = std.mem.indexOfScalar(u8, buf[0..have], '\n').?;
            std.mem.copyForwards(u8, buf[0 .. have - end - 1], buf[end + 1 .. have]);
            have -= end + 1;
            if (reply.len == 0) return;
            _ = c.write(fd, reply.ptr, reply.len);
        }
    }
};

test "one connection carries several exchanges, split replies included" {
    var l = try TestListener.init();
    defer l.deinit();
    // Two replies delivered in ONE write: the second must come from the
    // pending buffer, not a fresh read.
    const th = try std.Thread.spawn(.{}, Peer.serve, .{ l.fd, &[_][]const u8{ "{\"ok\":true,\"n\":1}\n{\"ok\":true,\"n\":2}\n", "-" } });
    defer th.join();
    var conn = try Conn.open(l.path(), clock.nowMs() + 2_000);
    defer conn.close(t.allocator);
    const first = conn.exchange(t.allocator, "{\"cmd\":\"a\"}", clock.nowMs() + 2_000);
    try t.expectEqualStrings("{\"ok\":true,\"n\":1}", first.reply);
    t.allocator.free(first.reply);
    const second = conn.exchange(t.allocator, "{\"cmd\":\"b\"}", clock.nowMs() + 2_000);
    try t.expectEqualStrings("{\"ok\":true,\"n\":2}", second.reply);
    t.allocator.free(second.reply);
}

test "a refused connect is pre-delivery and a lost reply is uncertain" {
    const none = exchangeOnce(t.allocator, "/tmp/sk-ctl-no-such-listener.sock", "{}", 500);
    try t.expectEqual(Delivery.pre_delivery, none.failure.delivery);
    try t.expect(!alive("/tmp/sk-ctl-no-such-listener.sock"));

    var l = try TestListener.init();
    defer l.deinit();
    try t.expect(alive(l.path()));
    // alive() connected once; that peer is accepted and dropped here.
    const drain = c.accept(l.fd, null, null);
    if (drain >= 0) _ = c.close(drain);
    const th = try std.Thread.spawn(.{}, Peer.serve, .{ l.fd, &[_][]const u8{""} });
    defer th.join();
    const lost = exchangeOnce(t.allocator, l.path(), "{\"cmd\":\"x\"}", 2_000);
    try t.expectEqual(Delivery.uncertain_delivery, lost.failure.delivery);
}

test "a persistent client reuses one connection and redials a closed one" {
    var l = try TestListener.init();
    defer l.deinit();
    var client = Persistent.init(t.allocator);
    defer client.deinit();
    {
        // Peer.serve accepts ONE connection: a second dial would never be
        // answered, so two replies prove the connection was reused.
        const th = try std.Thread.spawn(.{}, Peer.serve, .{ l.fd, &[_][]const u8{ "{\"n\":1}\n", "{\"n\":2}\n", "" } });
        defer th.join();
        for ([_][]const u8{ "{\"n\":1}", "{\"n\":2}" }) |want| {
            const r = client.exchange(t.allocator, l.path(), "{}", 2_000);
            try t.expectEqualStrings(want, r.reply);
            t.allocator.free(r.reply);
        }
        try t.expectEqual(@as(u32, 1), client.dials);
        // The third request makes the peer hang up without answering.
        const lost = client.exchange(t.allocator, l.path(), "{}", 2_000);
        try t.expectEqual(Delivery.uncertain_delivery, lost.failure.delivery);
    }
    // A restarted GUI: the next exchange dials afresh.
    const th = try std.Thread.spawn(.{}, Peer.serve, .{ l.fd, &[_][]const u8{"{\"n\":3}\n"} });
    defer th.join();
    const r = client.exchange(t.allocator, l.path(), "{}", 2_000);
    try t.expectEqualStrings("{\"n\":3}", r.reply);
    t.allocator.free(r.reply);
    try t.expectEqual(@as(u32, 2), client.dials);
}

test "an idle connection the peer closed is noticed before the write" {
    var l = try TestListener.init();
    defer l.deinit();
    var client = Persistent.init(t.allocator);
    defer client.deinit();
    {
        const th = try std.Thread.spawn(.{}, Peer.serve, .{ l.fd, &[_][]const u8{"{\"n\":1}\n"} });
        defer th.join();
        const r = client.exchange(t.allocator, l.path(), "{}", 2_000);
        t.allocator.free(r.reply);
    }
    // The peer thread returned and closed its end while we were idle.
    try t.expect(client.conn.?.peerClosed());
    const th = try std.Thread.spawn(.{}, Peer.serve, .{ l.fd, &[_][]const u8{"{\"n\":2}\n"} });
    defer th.join();
    const r = client.exchange(t.allocator, l.path(), "{}", 2_000);
    try t.expectEqualStrings("{\"n\":2}", r.reply);
    t.allocator.free(r.reply);
    try t.expectEqual(@as(u32, 2), client.dials);
}

test "a silent peer costs the deadline, not forever" {
    var l = try TestListener.init();
    defer l.deinit();
    const start = clock.nowMs();
    const r = exchangeOnce(t.allocator, l.path(), "{}", 200);
    try t.expect(r == .failure);
    try t.expectEqual(error.Timeout, r.failure.err);
    try t.expect(clock.nowMs() - start < 1_500);
}
