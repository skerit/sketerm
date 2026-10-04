//! A scripted loopback HTTP/1.1 server for the agent tests: routes answer
//! fixed responses, and every `GET /event` connection streams the pushed
//! SSE events as chunked `data:` lines, like opencode's server. A route can
//! push events when it is hit, so a reply the client sends is answered on
//! the stream the way the real server answers it; a `hook` answers what a
//! fixed route cannot (it sees the request body).
//!
//! Test support only: the agent tests import it, and smoke-mcp serves it
//! on a chosen port as a fake `opencode serve`. Each accepted connection
//! runs on its own thread; shared state lives in fixed arrays behind the
//! repo's spinlock, which is never held across an allocation or IO.

const std = @import("std");
const c = @import("../c.zig").c;
const tcpserver = @import("../smoke/tcpserver.zig");
const SpinLock = @import("../util/spinlock.zig").SpinLock;
const clock = @import("../util/clock.zig");

pub const Reply = struct {
    status: u16 = 200,
    body: []const u8 = "",
    chunked: bool = false,
    /// Answer with the request's own body.
    echo: bool = false,
    delay_ms: u32 = 0,
    /// Close the connection after answering.
    close_after: bool = false,
    /// Claim `Connection: keep-alive` even when closing (a stale reuse).
    keep_alive_header: bool = false,
    /// SSE event payloads pushed onto every stream once answered.
    events: []const []const u8 = &.{},
    /// Announce this Content-Length instead of the body's (a body too
    /// large to send, without sending it).
    claim_length: ?usize = null,
};

const Route = struct { key: []const u8, reply: Reply };

/// Answers a request before the routes do, or null to leave it to them.
/// Runs on the connection's thread; it may `pushEvent`.
pub const Hook = *const fn (ctx: ?*anyopaque, srv: *Server, method: []const u8, path: []const u8, body: []const u8) ?Reply;

const MAX_ROUTES = 64;
const MAX_REQUESTS = 256;
const MAX_EVENTS = 1024;
const MAX_THREADS = 64;

pub const Server = struct {
    lis: tcpserver.Listener = .{ .backlog = 16, .poll_ms = 20 },
    allocator: std.mem.Allocator = undefined,
    lock: SpinLock = .init,
    routes: [MAX_ROUTES]Route = undefined,
    n_routes: usize = 0,
    requests: [MAX_REQUESTS][]u8 = undefined,
    n_requests: usize = 0,
    events: [MAX_EVENTS][]u8 = undefined,
    n_events: usize = 0,
    threads: [MAX_THREADS]std.Thread = undefined,
    n_threads: usize = 0,
    conn_count: std.atomic.Value(u32) = .init(0),
    closed_count: std.atomic.Value(u32) = .init(0),
    end: std.atomic.Value(bool) = .init(false),
    stopping: std.atomic.Value(bool) = .init(false),
    hook: ?Hook = null,
    hook_ctx: ?*anyopaque = null,
    /// `Basic <base64(user:password)>` every request must carry ("" = no
    /// check); a request without it is answered 401, like opencode.
    auth: []const u8 = "",
    /// Until this `clock.nowMs()` the server accepts connections but never
    /// answers a request that arrives (it holds the connection open): a
    /// starting opencode does exactly that for a few seconds.
    deaf_until_ms: i64 = 0,

    pub fn start(self: *Server, allocator: std.mem.Allocator) !void {
        self.allocator = allocator;
        if (!self.lis.start(self, onAccept)) return error.ListenFailed;
    }

    /// `start` on loopback `port` (0 = an ephemeral one).
    pub fn startOn(self: *Server, allocator: std.mem.Allocator, port_: u16) !void {
        self.lis.bind_port = port_;
        return self.start(allocator);
    }

    pub fn deinit(self: *Server) void {
        if (self.stopping.swap(true, .acq_rel)) return;
        self.lis.deinit();
        for (self.threads[0..self.n_threads]) |th| th.join();
        for (self.requests[0..self.n_requests]) |r| self.allocator.free(r);
        for (self.events[0..self.n_events]) |e| self.allocator.free(e);
    }

    pub fn port(self: *const Server) u16 {
        return self.lis.port;
    }

    /// Answer `key` (`"POST /session/ses_1/abort"`) with `reply`; a later
    /// route for the same key wins. A key without a query answers every
    /// query; one with a query (`"GET /x?limit=5"`) answers only that exact
    /// target and wins over the bare one.
    pub fn route(self: *Server, key: []const u8, reply: Reply) void {
        self.lock.lock();
        defer self.lock.unlock();
        std.debug.assert(self.n_routes < MAX_ROUTES);
        self.routes[self.n_routes] = .{ .key = key, .reply = reply };
        self.n_routes += 1;
    }

    /// Queue an SSE event payload for every open stream.
    pub fn pushEvent(self: *Server, json: []const u8) void {
        const owned = self.allocator.dupe(u8, json) catch @panic("testserver: out of memory");
        self.lock.lock();
        defer self.lock.unlock();
        std.debug.assert(self.n_events < MAX_EVENTS);
        self.events[self.n_events] = owned;
        self.n_events += 1;
    }

    /// Finish every event stream (terminal chunk, then close); streams
    /// opened meanwhile end at once too.
    pub fn endStreams(self: *Server) void {
        self.end.store(true, .release);
    }

    /// Let new event streams stay open again.
    pub fn resumeStreams(self: *Server) void {
        self.end.store(false, .release);
    }

    pub fn connections(self: *const Server) u32 {
        return self.conn_count.load(.acquire);
    }

    /// Wait until at least `n` connections were closed by the server.
    pub fn waitConnectionsClosed(self: *const Server, n: u32, deadline_ms: i64) void {
        while (self.closed_count.load(.acquire) < n and clock.nowMs() < deadline_ms) _ = c.usleep(2000);
    }

    pub fn requestCount(self: *Server) usize {
        self.lock.lock();
        defer self.lock.unlock();
        return self.n_requests;
    }

    /// The raw bytes (head and body) of the `i`th request received.
    pub fn request(self: *Server, i: usize) []const u8 {
        self.lock.lock();
        defer self.lock.unlock();
        return if (i < self.n_requests) self.requests[i] else "";
    }

    /// The most recent request whose request line starts with `prefix`
    /// (`"POST /permission/"`), or null.
    pub fn lastRequest(self: *Server, prefix: []const u8) ?[]const u8 {
        self.lock.lock();
        defer self.lock.unlock();
        var i = self.n_requests;
        while (i > 0) {
            i -= 1;
            if (std.mem.startsWith(u8, self.requests[i], prefix)) return self.requests[i];
        }
        return null;
    }

    /// Wait until a request starting with `prefix` has arrived.
    pub fn waitRequest(self: *Server, prefix: []const u8, deadline_ms: i64) ?[]const u8 {
        while (clock.nowMs() < deadline_ms) {
            if (self.lastRequest(prefix)) |r| return r;
            _ = c.usleep(2000);
        }
        return null;
    }

    fn onAccept(ctx: ?*anyopaque, fd: c_int) bool {
        const self: *Server = @ptrCast(@alignCast(ctx.?));
        if (self.n_threads >= MAX_THREADS) return false;
        _ = self.conn_count.fetchAdd(1, .acq_rel);
        const th = std.Thread.spawn(.{}, serveConn, .{ self, fd }) catch return false;
        self.threads[self.n_threads] = th;
        self.n_threads += 1;
        return true;
    }

    fn lookup(self: *Server, key: []const u8) ?Reply {
        self.lock.lock();
        defer self.lock.unlock();
        var i = self.n_routes;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.routes[i].key, key)) return self.routes[i].reply;
        }
        return null;
    }

    fn serveConn(self: *Server, fd: c_int) void {
        defer {
            _ = c.close(fd);
            _ = self.closed_count.fetchAdd(1, .acq_rel);
        }
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        while (!self.stopping.load(.acquire)) {
            const req = self.readRequest(fd, &buf) orelse return;
            const line_end = std.mem.indexOf(u8, req, "\r\n") orelse return;
            var parts = std.mem.tokenizeScalar(u8, req[0..line_end], ' ');
            const method = parts.next() orelse return;
            const target = parts.next() orelse return;
            const path = if (std.mem.indexOfScalar(u8, target, '?')) |q| target[0..q] else target;
            const owned = self.allocator.dupe(u8, req) catch return;
            self.lock.lock();
            if (self.n_requests < MAX_REQUESTS) {
                self.requests[self.n_requests] = owned;
                self.n_requests += 1;
            } else self.allocator.free(owned);
            self.lock.unlock();

            if (clock.nowMs() < self.deaf_until_ms) return self.holdUnanswered(fd);
            const head_end = std.mem.indexOf(u8, req, "\r\n\r\n").?;
            if (self.auth.len > 0 and !authorized(req[0..head_end], self.auth)) {
                writeResponse(fd, .{ .status = 401, .close_after = true }, "{\"name\":\"Unauthorized\"}");
                return;
            }
            if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/event")) {
                self.stream(fd);
                return;
            }
            var key_buf: [512]u8 = undefined;
            const key = std.fmt.bufPrint(&key_buf, "{s} {s}", .{ method, path }) catch return;
            var full_buf: [512]u8 = undefined;
            const full = std.fmt.bufPrint(&full_buf, "{s} {s}", .{ method, target }) catch return;
            const hooked = if (self.hook) |h| h(self.hook_ctx, self, method, path, req[head_end + 4 ..]) else null;
            const exact = if (full.len != key.len) self.lookup(full) else null;
            const reply = hooked orelse exact orelse self.lookup(key) orelse Reply{ .status = 404, .body = "{\"name\":\"NotFoundError\",\"data\":{\"message\":\"no route\"}}" };
            var waited: u32 = 0;
            while (waited < reply.delay_ms and !self.stopping.load(.acquire)) : (waited += 5) _ = c.usleep(5000);
            const body = if (reply.echo) req[head_end + 4 ..] else reply.body;
            writeResponse(fd, reply, body);
            for (reply.events) |e| self.pushEvent(e);
            // Consume what the request used; keep pipelined bytes.
            const used = req.len;
            std.mem.copyForwards(u8, buf.items[0 .. buf.items.len - used], buf.items[used..]);
            buf.shrinkRetainingCapacity(buf.items.len - used);
            if (reply.close_after) return;
        }
    }

    /// Never answer: keep the connection until the client drops it or the
    /// server stops (a request sent while the server is deaf is lost).
    fn holdUnanswered(self: *Server, fd: c_int) void {
        var tmp: [1024]u8 = undefined;
        while (!self.stopping.load(.acquire)) {
            var pfd = c.struct_pollfd{ .fd = fd, .events = c.POLLIN, .revents = 0 };
            if (c.poll(&pfd, 1, 20) <= 0) continue;
            if (c.read(fd, &tmp, tmp.len) <= 0) return;
        }
    }

    /// One whole request (head plus Content-Length body) from the front of
    /// `buf`, reading more as needed; null on EOF or shutdown.
    fn readRequest(self: *Server, fd: c_int, buf: *std.ArrayList(u8)) ?[]const u8 {
        while (true) {
            if (std.mem.indexOf(u8, buf.items, "\r\n\r\n")) |he| {
                const head = buf.items[0..he];
                var len: usize = 0;
                var lines = std.mem.splitSequence(u8, head, "\r\n");
                while (lines.next()) |l| {
                    if (std.ascii.startsWithIgnoreCase(l, "content-length:"))
                        len = std.fmt.parseInt(usize, std.mem.trim(u8, l["content-length:".len..], " "), 10) catch 0;
                }
                if (buf.items.len >= he + 4 + len) return buf.items[0 .. he + 4 + len];
            }
            if (self.stopping.load(.acquire)) return null;
            var pfd = c.struct_pollfd{ .fd = fd, .events = c.POLLIN, .revents = 0 };
            if (c.poll(&pfd, 1, 20) <= 0) continue;
            var tmp: [8192]u8 = undefined;
            const n = c.read(fd, &tmp, tmp.len);
            if (n <= 0) return null;
            buf.appendSlice(self.allocator, tmp[0..@intCast(n)]) catch return null;
        }
    }

    /// Like opencode: a new stream starts with `server.connected` and then
    /// carries only events pushed after it opened (taken before the head is
    /// written, so nothing pushed once the client has the head is missed).
    fn stream(self: *Server, fd: c_int) void {
        self.lock.lock();
        var next: usize = self.n_events;
        self.lock.unlock();
        writeAllFd(fd, "HTTP/1.1 200 OK\r\ncache-control: no-cache\r\ncontent-type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n");
        const hello = "data: {\"type\":\"server.connected\",\"properties\":{}}\n\n";
        var size_buf: [16]u8 = undefined;
        writeAllFd(fd, std.fmt.bufPrint(&size_buf, "{x}\r\n", .{hello.len}) catch return);
        writeAllFd(fd, hello ++ "\r\n");
        while (!self.stopping.load(.acquire)) {
            var batch: [MAX_EVENTS][]const u8 = undefined;
            var n: usize = 0;
            self.lock.lock();
            while (next < self.n_events) : (next += 1) {
                batch[n] = self.events[next];
                n += 1;
            }
            self.lock.unlock();
            for (batch[0..n]) |e| {
                var head: [32]u8 = undefined;
                const size = std.fmt.bufPrint(&head, "{x}\r\n", .{e.len + 8}) catch return;
                writeAllFd(fd, size);
                writeAllFd(fd, "data: ");
                writeAllFd(fd, e);
                writeAllFd(fd, "\n\n\r\n");
            }
            if (n == 0 and self.end.load(.acquire)) {
                writeAllFd(fd, "0\r\n\r\n");
                return;
            }
            _ = c.usleep(3000);
        }
    }
};

/// The request head carries `Authorization: <want>`.
fn authorized(head: []const u8, want: []const u8) bool {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    while (lines.next()) |l| {
        if (!std.ascii.startsWithIgnoreCase(l, "authorization:")) continue;
        return std.mem.eql(u8, std.mem.trim(u8, l["authorization:".len..], " "), want);
    }
    return false;
}

fn writeResponse(fd: c_int, reply: Reply, body: []const u8) void {
    var head: [512]u8 = undefined;
    const conn = if (reply.close_after and !reply.keep_alive_header) "close" else "keep-alive";
    const reason = if (reply.status < 300) "OK" else "Error";
    if (reply.status == 204) {
        const h = std.fmt.bufPrint(&head, "HTTP/1.1 204 No Content\r\nConnection: {s}\r\n\r\n", .{conn}) catch return;
        return writeAllFd(fd, h);
    }
    if (reply.chunked) {
        const h = std.fmt.bufPrint(&head, "HTTP/1.1 {d} {s}\r\ncontent-type: application/json\r\nTransfer-Encoding: chunked\r\nConnection: {s}\r\n\r\n", .{ reply.status, reason, conn }) catch return;
        writeAllFd(fd, h);
        // Two chunks, so the decoder sees a boundary inside the body.
        const mid = body.len / 2;
        for ([_][]const u8{ body[0..mid], body[mid..] }) |part| {
            if (part.len == 0) continue;
            const size = std.fmt.bufPrint(&head, "{x}\r\n", .{part.len}) catch return;
            writeAllFd(fd, size);
            writeAllFd(fd, part);
            writeAllFd(fd, "\r\n");
        }
        return writeAllFd(fd, "0\r\n\r\n");
    }
    const h = std.fmt.bufPrint(&head, "HTTP/1.1 {d} {s}\r\ncontent-type: application/json\r\ncontent-length: {d}\r\nConnection: {s}\r\n\r\n", .{ reply.status, reason, reply.claim_length orelse body.len, conn }) catch return;
    writeAllFd(fd, h);
    writeAllFd(fd, body);
}

fn writeAllFd(fd: c_int, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = if (comptime @hasDecl(c, "MSG_NOSIGNAL"))
            c.send(fd, bytes[off..].ptr, bytes.len - off, c.MSG_NOSIGNAL)
        else
            c.write(fd, bytes[off..].ptr, bytes.len - off);
        if (n <= 0) {
            if (n < 0 and std.posix.errno(n) == .INTR) continue;
            return;
        }
        off += @intCast(n);
    }
}
