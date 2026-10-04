//! A minimal HTTP/1.1 client for loopback APIs (opencode's server), plus
//! an incremental Server-Sent Events reader.
//!
//! Every socket is non-blocking and every wait has a deadline (the MCP
//! rule: no plain blocking recv). A `Client` keeps a few keep-alive
//! connections and reuses them: a request takes an idle one (dialing only
//! when none is idle), so a long request (opencode's synchronous command
//! route) never blocks a quick one behind it. An `EventStream` is the one
//! long-lived `GET` whose chunked body is parsed as SSE.
//!
//! Gotcha: a keep-alive connection the server closed while idle (opencode
//! closes after 5 s) is only noticed when reused. A request that fails on a
//! REUSED connection before a single response byte arrived is sent again
//! on a fresh one; a failure on a fresh connection is the caller's.

const std = @import("std");
const c = @import("../c.zig").c;
const headers = @import("../util/headers.zig");
const b64 = @import("../util/b64.zig");
const dbusconn = @import("../mux/dbusconn.zig");
const socks5 = @import("../mux/socks5_client.zig");
const nowMs = @import("../util/clock.zig").nowMs;

pub const Method = enum { GET, POST, PATCH, DELETE };

pub const Request = struct {
    method: Method,
    /// Path plus query (`/session/ses_1/abort`).
    path: []const u8,
    /// JSON body; null sends none.
    body: ?[]const u8 = null,
};

pub const Response = struct {
    status: u16,
    /// Allocated from the client's allocator.
    body: []u8,

    pub fn ok(self: Response) bool {
        return self.status >= 200 and self.status < 300;
    }

    pub fn deinit(self: Response, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
    }
};

/// Largest response body accepted (opencode's `/provider` is several MiB).
pub const MAX_BODY: usize = 64 << 20;
/// Largest response head accepted.
pub const MAX_HEAD: usize = 64 << 10;
/// Largest single SSE event accepted.
pub const MAX_EVENT: usize = 16 << 20;
/// Connections one client keeps; also its cap on requests in flight.
pub const MAX_CONNS = 4;
/// Deadline for sending an async request (its response may take as long
/// as it takes) and for re-sending one on a fresh connection.
const SEND_TIMEOUT_MS: i64 = 10_000;

pub const Error = error{
    Timeout,
    ConnectFailed,
    /// The connection ended before the response was complete.
    Closed,
    BadResponse,
    TooLarge,
    /// Every connection has a request in flight.
    Busy,
    /// A stream answered with something other than 200 text/event-stream.
    NotAStream,
    /// The server rejected the credentials (a stream open; a request
    /// returns its 401 as a response).
    Unauthorized,
};

// ── chunked transfer coding ──────────────────────────────────────

pub const ChunkDecoder = struct {
    state: State = .size,
    remaining: u64 = 0,
    digits: u8 = 0,

    const State = enum { size, ext, size_lf, data, data_cr, data_lf, trailer, trailer_skip, trailer_lf, done };

    /// Decode what `in` holds, appending payload to `out`.
    /// @return bytes of `in` consumed; less than `in.len` only once done.
    pub fn feed(self: *ChunkDecoder, allocator: std.mem.Allocator, in: []const u8, out: *std.ArrayList(u8)) !usize {
        var i: usize = 0;
        while (i < in.len and self.state != .done) {
            const b = in[i];
            switch (self.state) {
                .size => {
                    if (std.fmt.charToDigit(b, 16)) |d| {
                        if (self.digits >= 15) return error.BadResponse;
                        self.remaining = self.remaining * 16 + d;
                        self.digits += 1;
                    } else |_| switch (b) {
                        ';' => self.state = .ext,
                        ' ', '\t' => {},
                        '\r' => self.state = .size_lf,
                        '\n' => self.endSizeLine(),
                        else => return error.BadResponse,
                    }
                    i += 1;
                },
                .ext => {
                    if (b == '\r') self.state = .size_lf else if (b == '\n') self.endSizeLine();
                    i += 1;
                },
                .size_lf => {
                    if (b != '\n') return error.BadResponse;
                    self.endSizeLine();
                    i += 1;
                },
                .data => {
                    const n: usize = @intCast(@min(self.remaining, in.len - i));
                    try out.appendSlice(allocator, in[i .. i + n]);
                    self.remaining -= n;
                    i += n;
                    if (self.remaining == 0) self.state = .data_cr;
                },
                .data_cr => {
                    self.state = switch (b) {
                        '\r' => .data_lf,
                        '\n' => .size,
                        else => return error.BadResponse,
                    };
                    i += 1;
                },
                .data_lf => {
                    if (b != '\n') return error.BadResponse;
                    self.state = .size;
                    i += 1;
                },
                .trailer => {
                    self.state = switch (b) {
                        '\r' => .trailer_lf,
                        '\n' => .done,
                        else => .trailer_skip,
                    };
                    i += 1;
                },
                .trailer_skip => {
                    if (b == '\n') self.state = .trailer;
                    i += 1;
                },
                .trailer_lf => {
                    if (b != '\n') return error.BadResponse;
                    self.state = .done;
                    i += 1;
                },
                .done => unreachable,
            }
        }
        return i;
    }

    fn endSizeLine(self: *ChunkDecoder) void {
        if (self.digits == 0) {
            // A size line without digits is malformed; treat it as the end
            // rather than waiting forever on a chunk that never comes.
            self.state = .trailer;
            return;
        }
        self.digits = 0;
        self.state = if (self.remaining == 0) .trailer else .data;
    }

    pub fn done(self: ChunkDecoder) bool {
        return self.state == .done;
    }
};

// ── responses ────────────────────────────────────────────────────

/// Incremental response parser: head, then a fixed, chunked or
/// close-delimited body. With `stream` set the body is never complete by
/// length; the caller drains `body` as it grows.
pub const ResponseParser = struct {
    phase: Phase = .head,
    head: std.ArrayList(u8) = .empty,
    body: std.ArrayList(u8) = .empty,
    status: u16 = 0,
    keep_alive: bool = false,
    remaining: usize = 0,
    chunks: ChunkDecoder = .{},
    /// Bytes received for this response (a retry is only safe at 0).
    received: usize = 0,

    const Phase = enum { head, fixed, chunked, until_close, done };

    pub fn deinit(self: *ResponseParser, allocator: std.mem.Allocator) void {
        self.head.deinit(allocator);
        self.body.deinit(allocator);
        self.* = .{};
    }

    pub fn reset(self: *ResponseParser) void {
        self.head.clearRetainingCapacity();
        self.body.clearRetainingCapacity();
        const head = self.head;
        const body = self.body;
        self.* = .{ .head = head, .body = body };
    }

    pub fn done(self: *const ResponseParser) bool {
        return self.phase == .done;
    }

    /// The header block (status line included), valid once past the head.
    pub fn headBlock(self: *const ResponseParser) []const u8 {
        return self.head.items;
    }

    pub const FeedError = error{ BadResponse, TooLarge } || std.mem.Allocator.Error;

    pub fn feed(self: *ResponseParser, allocator: std.mem.Allocator, bytes: []const u8) FeedError!void {
        self.received += bytes.len;
        var rest = bytes;
        while (rest.len > 0) {
            switch (self.phase) {
                .head => {
                    const scan_from = self.head.items.len -| 3;
                    try self.head.appendSlice(allocator, rest);
                    const end = std.mem.indexOfPos(u8, self.head.items, scan_from, "\r\n\r\n") orelse {
                        if (self.head.items.len > MAX_HEAD) return error.TooLarge;
                        return;
                    };
                    const after = try allocator.dupe(u8, self.head.items[end + 4 ..]);
                    defer allocator.free(after);
                    self.head.shrinkRetainingCapacity(end);
                    try self.parseHead();
                    // A 1xx interim response: the real head follows.
                    if (self.phase == .head) self.head.clearRetainingCapacity();
                    self.received -= after.len;
                    return self.feed(allocator, after);
                },
                .fixed => {
                    const n = @min(self.remaining, rest.len);
                    try self.appendBody(allocator, rest[0..n]);
                    self.remaining -= n;
                    rest = rest[n..];
                    if (self.remaining == 0) self.phase = .done;
                },
                .chunked => {
                    const used = try self.chunks.feed(allocator, rest, &self.body);
                    if (self.body.items.len > MAX_BODY) return error.TooLarge;
                    rest = rest[used..];
                    if (self.chunks.done()) self.phase = .done;
                },
                .until_close => {
                    try self.appendBody(allocator, rest);
                    rest = &.{};
                },
                .done => return error.BadResponse,
            }
        }
    }

    /// The peer closed: completes a close-delimited body.
    pub fn feedEof(self: *ResponseParser) !void {
        switch (self.phase) {
            .until_close => self.phase = .done,
            .done => {},
            else => return error.Closed,
        }
    }

    fn appendBody(self: *ResponseParser, allocator: std.mem.Allocator, bytes: []const u8) !void {
        if (self.body.items.len + bytes.len > MAX_BODY) return error.TooLarge;
        try self.body.appendSlice(allocator, bytes);
    }

    fn parseHead(self: *ResponseParser) !void {
        const block = self.head.items;
        const line_end = std.mem.indexOf(u8, block, "\r\n") orelse block.len;
        var parts = std.mem.tokenizeScalar(u8, block[0..line_end], ' ');
        const version = parts.next() orelse return error.BadResponse;
        if (!std.mem.startsWith(u8, version, "HTTP/1.")) return error.BadResponse;
        const code = parts.next() orelse return error.BadResponse;
        self.status = std.fmt.parseInt(u16, code, 10) catch return error.BadResponse;
        if (self.status >= 100 and self.status < 200) return; // interim: stay in .head
        const v11 = !std.mem.eql(u8, version, "HTTP/1.0");
        self.keep_alive = if (v11) !headers.hasToken(block, "connection", "close") else headers.hasToken(block, "connection", "keep-alive");
        if (self.status == 204 or self.status == 304) {
            self.phase = .done;
        } else if (headers.hasToken(block, "transfer-encoding", "chunked")) {
            self.phase = .chunked;
        } else if (headers.value(block, "content-length")) |len_text| {
            self.remaining = std.fmt.parseInt(usize, len_text, 10) catch return error.BadResponse;
            if (self.remaining > MAX_BODY) return error.TooLarge;
            self.phase = if (self.remaining == 0) .done else .fixed;
        } else {
            self.phase = .until_close;
            self.keep_alive = false;
        }
    }
};

// ── Server-Sent Events ───────────────────────────────────────────

pub const SseEvent = struct {
    /// The `event:` field, "message" when absent.
    event: []u8,
    /// The `data:` lines joined by newlines.
    data: []u8,
    /// The last `id:` seen on the stream ("" when none).
    id: []u8,

    pub fn deinit(self: SseEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.event);
        allocator.free(self.data);
        allocator.free(self.id);
    }
};

/// Incremental SSE parser (the WHATWG event-stream grammar): lines end in
/// CRLF, LF or CR, a blank line dispatches, `:` starts a comment.
pub const SseReader = struct {
    line: std.ArrayList(u8) = .empty,
    data: std.ArrayList(u8) = .empty,
    event: std.ArrayList(u8) = .empty,
    id: std.ArrayList(u8) = .empty,
    has_data: bool = false,
    /// The previous byte was a CR (a following LF belongs to it).
    after_cr: bool = false,

    pub fn deinit(self: *SseReader, allocator: std.mem.Allocator) void {
        self.line.deinit(allocator);
        self.data.deinit(allocator);
        self.event.deinit(allocator);
        self.id.deinit(allocator);
        self.* = .{};
    }

    /// Parse `bytes`, appending every completed event to `out` (owned by
    /// `allocator`).
    pub fn feed(self: *SseReader, allocator: std.mem.Allocator, bytes: []const u8, out: *std.ArrayList(SseEvent)) !void {
        for (bytes) |b| {
            if (self.after_cr) {
                self.after_cr = false;
                if (b == '\n') continue;
            }
            switch (b) {
                '\r', '\n' => {
                    self.after_cr = b == '\r';
                    try self.endLine(allocator, out);
                },
                else => {
                    if (self.line.items.len + self.data.items.len >= MAX_EVENT) return error.TooLarge;
                    try self.line.append(allocator, b);
                },
            }
        }
    }

    fn endLine(self: *SseReader, allocator: std.mem.Allocator, out: *std.ArrayList(SseEvent)) !void {
        defer self.line.clearRetainingCapacity();
        const l = self.line.items;
        if (l.len == 0) return self.dispatch(allocator, out);
        if (l[0] == ':') return;
        const colon = std.mem.indexOfScalar(u8, l, ':');
        const field = if (colon) |i| l[0..i] else l;
        var value: []const u8 = if (colon) |i| l[i + 1 ..] else "";
        if (value.len > 0 and value[0] == ' ') value = value[1..];
        if (std.mem.eql(u8, field, "data")) {
            try self.data.appendSlice(allocator, value);
            try self.data.append(allocator, '\n');
            self.has_data = true;
        } else if (std.mem.eql(u8, field, "event")) {
            self.event.clearRetainingCapacity();
            try self.event.appendSlice(allocator, value);
        } else if (std.mem.eql(u8, field, "id")) {
            if (std.mem.indexOfScalar(u8, value, 0) == null) {
                self.id.clearRetainingCapacity();
                try self.id.appendSlice(allocator, value);
            }
        }
    }

    fn dispatch(self: *SseReader, allocator: std.mem.Allocator, out: *std.ArrayList(SseEvent)) !void {
        defer {
            self.data.clearRetainingCapacity();
            self.event.clearRetainingCapacity();
            self.has_data = false;
        }
        if (!self.has_data) return;
        const data = self.data.items[0 .. self.data.items.len - 1];
        const ev = SseEvent{
            .event = try allocator.dupe(u8, if (self.event.items.len > 0) self.event.items else "message"),
            .data = undefined,
            .id = undefined,
        };
        errdefer allocator.free(ev.event);
        var full = ev;
        full.data = try allocator.dupe(u8, data);
        errdefer allocator.free(full.data);
        full.id = try allocator.dupe(u8, self.id.items);
        errdefer allocator.free(full.id);
        try out.append(allocator, full);
    }
};

// ── connections ──────────────────────────────────────────────────

/// Loopback endpoint plus the credentials every request carries.
pub const Target = struct {
    port: u16,
    /// Basic-auth user and password; no Authorization header when the
    /// password is empty.
    user: []const u8 = "",
    password: []const u8 = "",
};

const Conn = struct {
    fd: c_int = -1,
    /// The request in flight, null when idle.
    ticket: ?u64 = null,
    /// Driven by `Client.service` (an async request) rather than `call`.
    async_: bool = false,
    /// It served a response before this request.
    reused: bool = false,
    deadline: ?i64 = null,
    /// The request bytes, kept for the one retry on a stale connection.
    request: []u8 = &.{},
    parser: ResponseParser = .{},

    fn close(self: *Conn) void {
        if (self.fd >= 0) _ = c.close(self.fd);
        self.fd = -1;
        self.reused = false;
    }
};

pub const Completion = struct {
    ticket: u64,
    result: Result,

    pub const Result = union(enum) {
        response: Response,
        failed: anyerror,
    };
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    endpoint: socks5.Endpoint,
    port: u16,
    /// `Basic <base64>`, "" without a password.
    auth: []u8,
    conns: [MAX_CONNS]Conn = @splat(.{}),
    next_ticket: u64 = 1,
    completions: std.ArrayList(Completion) = .empty,

    pub fn init(allocator: std.mem.Allocator, target: Target) !Client {
        var auth: []u8 = &.{};
        if (target.password.len > 0) {
            const pair = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ target.user, target.password });
            defer {
                std.crypto.secureZero(u8, pair);
                allocator.free(pair);
            }
            const enc = try b64.encodeAlloc(allocator, pair);
            defer allocator.free(enc);
            auth = try std.fmt.allocPrint(allocator, "Basic {s}", .{enc});
        }
        return .{
            .allocator = allocator,
            .endpoint = .{ .ipv4 = .{ .addr = .{ 127, 0, 0, 1 }, .port = target.port } },
            .port = target.port,
            .auth = auth,
        };
    }

    pub fn deinit(self: *Client) void {
        for (&self.conns) |*cn| {
            cn.close();
            self.allocator.free(cn.request);
            cn.parser.deinit(self.allocator);
        }
        for (self.completions.items) |done| switch (done.result) {
            .response => |r| r.deinit(self.allocator),
            .failed => {},
        };
        self.completions.deinit(self.allocator);
        std.crypto.secureZero(u8, self.auth);
        self.allocator.free(self.auth);
    }

    /// Send `req` and wait for its response until `deadline_ms`.
    /// @return the response (any status); the caller frees it.
    pub fn call(self: *Client, req: Request, deadline_ms: i64) !Response {
        const ticket = try self.begin(req, deadline_ms, false);
        const cn = self.connOf(ticket).?;
        return self.finishSync(cn);
    }

    /// Send `req` and return; its outcome arrives as a `Completion` through
    /// `service`. A null deadline waits as long as the request takes.
    /// @return the ticket the completion carries.
    pub fn start(self: *Client, req: Request, deadline_ms: ?i64) !u64 {
        const send_deadline = deadline_ms orelse nowMs() + SEND_TIMEOUT_MS;
        const ticket = try self.begin(req, send_deadline, true);
        self.connOf(ticket).?.deadline = deadline_ms;
        return ticket;
    }

    /// Progress every async request without blocking.
    pub fn service(self: *Client, now_ms: i64) !void {
        for (&self.conns) |*cn| {
            const ticket = cn.ticket orelse continue;
            if (!cn.async_) continue;
            const outcome = self.pump(cn);
            if (outcome) |finished| {
                if (finished) try self.complete(cn, ticket, null);
            } else |err| {
                if (err == error.Closed and self.canRetry(cn)) {
                    self.resend(cn, nowMs() + SEND_TIMEOUT_MS) catch |e| try self.complete(cn, ticket, e);
                } else try self.complete(cn, ticket, err);
                continue;
            }
            if (cn.ticket != null) {
                if (cn.deadline) |d| {
                    if (now_ms >= d) try self.complete(cn, ticket, error.Timeout);
                }
            }
        }
    }

    /// The next finished async request, oldest first.
    pub fn takeCompletion(self: *Client) ?Completion {
        if (self.completions.items.len == 0) return null;
        return self.completions.orderedRemove(0);
    }

    /// The completion of `ticket` once it finished; the others stay queued.
    pub fn takeCompletionOf(self: *Client, ticket: u64) ?Completion {
        for (self.completions.items, 0..) |done, i| {
            if (done.ticket == ticket) return self.completions.orderedRemove(i);
        }
        return null;
    }

    /// Give up on async request `ticket`. Gotcha: its connection is closed,
    /// and a server may stop handling a request whose client went away
    /// (opencode 2.x does, measured).
    pub fn cancel(self: *Client, ticket: u64) void {
        if (self.connOf(ticket)) |cn| self.release(cn, false);
        if (self.takeCompletionOf(ticket)) |done| switch (done.result) {
            .response => |r| r.deinit(self.allocator),
            .failed => {},
        };
    }

    /// The fds of async requests in flight (for the caller's poll).
    pub fn pollFds(self: *const Client, out: []c.struct_pollfd) usize {
        var n: usize = 0;
        for (self.conns) |cn| {
            if (cn.ticket == null or !cn.async_ or n == out.len) continue;
            out[n] = .{ .fd = cn.fd, .events = c.POLLIN, .revents = 0 };
            n += 1;
        }
        return n;
    }

    // ── internals ──

    fn connOf(self: *Client, ticket: u64) ?*Conn {
        for (&self.conns) |*cn| {
            if (cn.ticket == ticket) return cn;
        }
        return null;
    }

    fn begin(self: *Client, req: Request, deadline: i64, is_async: bool) !u64 {
        const cn = try self.pickConn(deadline);
        const bytes = try self.format(req);
        self.allocator.free(cn.request);
        cn.request = bytes;
        const ticket = self.next_ticket;
        self.next_ticket += 1;
        cn.ticket = ticket;
        cn.async_ = is_async;
        cn.deadline = deadline;
        cn.parser.reset();
        self.send(cn, deadline) catch |err| {
            if (!self.canRetry(cn)) {
                self.release(cn, false);
                return err;
            }
            self.resend(cn, deadline) catch |e| {
                self.release(cn, false);
                return e;
            };
        };
        return ticket;
    }

    /// An idle live connection, or a fresh one.
    fn pickConn(self: *Client, deadline: i64) !*Conn {
        for (&self.conns) |*cn| {
            if (cn.ticket != null or cn.fd < 0) continue;
            if (stillOpen(cn.fd)) return cn;
            cn.close();
        }
        for (&self.conns) |*cn| {
            if (cn.ticket != null or cn.fd >= 0) continue;
            cn.fd = self.endpoint.connect(deadline) catch |err| return if (err == error.Timeout) error.Timeout else error.ConnectFailed;
            cn.reused = false;
            return cn;
        }
        return error.Busy;
    }

    fn send(self: *Client, cn: *Conn, deadline: i64) !void {
        _ = self;
        dbusconn.writeAll(cn.fd, cn.request, deadline) catch |err| return if (err == error.Timeout) error.Timeout else error.Closed;
    }

    fn canRetry(self: *const Client, cn: *const Conn) bool {
        _ = self;
        return cn.reused and cn.parser.received == 0;
    }

    /// Send the request again on a fresh connection (the reused one was
    /// stale).
    fn resend(self: *Client, cn: *Conn, deadline: i64) !void {
        cn.close();
        cn.fd = self.endpoint.connect(deadline) catch |err| return if (err == error.Timeout) error.Timeout else error.ConnectFailed;
        cn.parser.reset();
        try self.send(cn, deadline);
    }

    fn finishSync(self: *Client, cn: *Conn) !Response {
        while (true) {
            const finished = self.pump(cn) catch |err| {
                if (err == error.Closed and self.canRetry(cn)) {
                    self.resend(cn, cn.deadline.?) catch |e| {
                        self.release(cn, false);
                        return e;
                    };
                    continue;
                }
                self.release(cn, false);
                return err;
            };
            if (finished) return self.takeResponse(cn);
            dbusconn.waitFd(cn.fd, c.POLLIN, cn.deadline.?) catch |err| {
                if (err == error.Timeout) {
                    self.release(cn, false);
                    return error.Timeout;
                }
                // POLLHUP without data: the next read sees the EOF.
            };
        }
    }

    /// Read what is available into the parser.
    /// @return true once the response is complete.
    fn pump(self: *Client, cn: *Conn) !bool {
        var buf: [16 * 1024]u8 = undefined;
        while (true) {
            const n = c.read(cn.fd, &buf, buf.len);
            if (n > 0) {
                try cn.parser.feed(self.allocator, buf[0..@intCast(n)]);
                if (cn.parser.done()) return true;
                continue;
            }
            if (n == 0) {
                try cn.parser.feedEof();
                return true;
            }
            const e = std.posix.errno(n);
            if (e == .INTR) continue;
            if (e == .AGAIN) return false;
            return error.Closed;
        }
    }

    fn takeResponse(self: *Client, cn: *Conn) !Response {
        const body = try cn.parser.body.toOwnedSlice(self.allocator);
        const resp = Response{ .status = cn.parser.status, .body = body };
        self.release(cn, cn.parser.keep_alive);
        return resp;
    }

    /// The request is over: keep the connection for the next one or close it.
    fn release(self: *Client, cn: *Conn, keep: bool) void {
        _ = self;
        cn.ticket = null;
        cn.async_ = false;
        cn.deadline = null;
        if (keep and cn.fd >= 0) {
            cn.reused = true;
        } else cn.close();
        cn.parser.reset();
    }

    fn complete(self: *Client, cn: *Conn, ticket: u64, failure: ?anyerror) !void {
        if (failure) |err| {
            self.release(cn, false);
            return self.completions.append(self.allocator, .{ .ticket = ticket, .result = .{ .failed = err } });
        }
        const resp = try self.takeResponse(cn);
        self.completions.append(self.allocator, .{ .ticket = ticket, .result = .{ .response = resp } }) catch |err| {
            resp.deinit(self.allocator);
            return err;
        };
    }

    fn format(self: *Client, req: Request) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        const w = &out.writer;
        try w.print("{s} {s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nAccept: application/json\r\n", .{ @tagName(req.method), req.path, self.port });
        if (self.auth.len > 0) try w.print("Authorization: {s}\r\n", .{self.auth});
        if (req.body) |body| {
            try w.print("Content-Type: application/json\r\nContent-Length: {d}\r\n\r\n", .{body.len});
            try w.writeAll(body);
        } else if (req.method == .GET) {
            try w.writeAll("\r\n");
        } else {
            try w.writeAll("Content-Length: 0\r\n\r\n");
        }
        return out.toOwnedSlice();
    }
};

/// Whether an idle keep-alive connection is still usable: nothing to read
/// and no hangup. Unsolicited bytes on an idle connection make it unusable
/// too.
fn stillOpen(fd: c_int) bool {
    var pfd = c.struct_pollfd{ .fd = fd, .events = c.POLLIN, .revents = 0 };
    const rc = c.poll(&pfd, 1, 0);
    return rc == 0;
}

// ── the event stream ─────────────────────────────────────────────

/// One long-lived `GET` whose body is an SSE stream.
pub const EventStream = struct {
    allocator: std.mem.Allocator,
    fd: c_int = -1,
    parser: ResponseParser = .{},
    sse: SseReader = .{},

    pub fn init(allocator: std.mem.Allocator) EventStream {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *EventStream) void {
        self.close();
        self.parser.deinit(self.allocator);
        self.sse.deinit(self.allocator);
    }

    pub fn isOpen(self: *const EventStream) bool {
        return self.fd >= 0;
    }

    pub fn close(self: *EventStream) void {
        if (self.fd >= 0) _ = c.close(self.fd);
        self.fd = -1;
        self.parser.reset();
        self.sse.deinit(self.allocator);
    }

    /// Dial, send `GET path` with the client's credentials and wait for a
    /// 200 `text/event-stream` head until `deadline_ms`. Events already
    /// sent with the head are parsed by the next `read`.
    pub fn open(self: *EventStream, client: *Client, path: []const u8, deadline_ms: i64) !void {
        self.close();
        const fd = client.endpoint.connect(deadline_ms) catch |err| return if (err == error.Timeout) error.Timeout else error.ConnectFailed;
        self.fd = fd;
        errdefer self.close();
        var req: std.Io.Writer.Allocating = .init(self.allocator);
        defer req.deinit();
        try req.writer.print("GET {s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nAccept: text/event-stream\r\nCache-Control: no-cache\r\n", .{ path, client.port });
        if (client.auth.len > 0) try req.writer.print("Authorization: {s}\r\n", .{client.auth});
        try req.writer.writeAll("\r\n");
        dbusconn.writeAll(fd, req.written(), deadline_ms) catch |err| return if (err == error.Timeout) error.Timeout else error.Closed;
        var buf: [16 * 1024]u8 = undefined;
        while (self.parser.phase == .head) {
            dbusconn.waitFd(fd, c.POLLIN, deadline_ms) catch |err| return if (err == error.Timeout) error.Timeout else error.Closed;
            const n = c.read(fd, &buf, buf.len);
            if (n == 0) return error.Closed;
            if (n < 0) {
                const e = std.posix.errno(n);
                if (e == .INTR or e == .AGAIN) continue;
                return error.Closed;
            }
            try self.parser.feed(self.allocator, buf[0..@intCast(n)]);
        }
        const ctype = headers.value(self.parser.headBlock(), "content-type") orelse "";
        if (self.parser.status == 401) return error.Unauthorized;
        if (self.parser.status != 200 or !std.mem.startsWith(u8, ctype, "text/event-stream")) return error.NotAStream;
    }

    /// Read what is available without blocking, appending parsed events to
    /// `out` (owned by the stream's allocator).
    /// @return false once the stream has ended (the fd is closed then).
    pub fn read(self: *EventStream, out: *std.ArrayList(SseEvent)) !bool {
        if (self.fd < 0) return false;
        // Bytes that arrived with the head.
        try self.drainBody(out);
        var buf: [16 * 1024]u8 = undefined;
        while (true) {
            const n = c.read(self.fd, &buf, buf.len);
            if (n > 0) {
                self.parser.feed(self.allocator, buf[0..@intCast(n)]) catch |err| {
                    self.close();
                    return err;
                };
                try self.drainBody(out);
                if (self.parser.done()) {
                    self.close();
                    return false;
                }
                continue;
            }
            if (n == 0) {
                self.close();
                return false;
            }
            const e = std.posix.errno(n);
            if (e == .INTR) continue;
            if (e == .AGAIN) return true;
            self.close();
            return false;
        }
    }

    fn drainBody(self: *EventStream, out: *std.ArrayList(SseEvent)) !void {
        if (self.parser.body.items.len == 0) return;
        defer self.parser.body.clearRetainingCapacity();
        try self.sse.feed(self.allocator, self.parser.body.items, out);
    }
};

// ── tests ────────────────────────────────────────────────────────

const t = std.testing;
const testserver = @import("testserver.zig");

test "chunked decoding across arbitrary splits, extensions and trailers" {
    const wire = "4;ext=1\r\nWiki\r\n5\r\npedia\r\nE\r\n in\r\n\r\nchunks.\r\n0\r\nX-Trailer: 1\r\n\r\n";
    var split: usize = 1;
    while (split < wire.len) : (split += 1) {
        var dec: ChunkDecoder = .{};
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(t.allocator);
        const a = try dec.feed(t.allocator, wire[0..split], &out);
        try t.expectEqual(split, a);
        _ = try dec.feed(t.allocator, wire[split..], &out);
        try t.expect(dec.done());
        try t.expectEqualStrings("Wikipedia in\r\n\r\nchunks.", out.items);
    }
}

test "response parser: content-length, chunked, close-delimited, 204 and a 100 interim" {
    var p: ResponseParser = .{};
    defer p.deinit(t.allocator);
    try p.feed(t.allocator, "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhel");
    try t.expect(!p.done());
    try p.feed(t.allocator, "lo");
    try t.expect(p.done());
    try t.expect(p.keep_alive);
    try t.expectEqualStrings("hello", p.body.items);

    p.reset();
    try p.feed(t.allocator, "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 201 Created\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n3\r\nabc\r\n0\r\n\r\n");
    try t.expect(p.done());
    try t.expectEqual(@as(u16, 201), p.status);
    try t.expect(!p.keep_alive);
    try t.expectEqualStrings("abc", p.body.items);

    p.reset();
    try p.feed(t.allocator, "HTTP/1.0 200 OK\r\n\r\nuntil close");
    try t.expect(!p.done());
    try p.feedEof();
    try t.expectEqualStrings("until close", p.body.items);

    p.reset();
    try p.feed(t.allocator, "HTTP/1.1 204 No Content\r\n\r\n");
    try t.expect(p.done());

    p.reset();
    try p.feed(t.allocator, "HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\nshort");
    try t.expectError(error.Closed, p.feedEof());
}

test "sse reader: CRLF/LF/CR endings, multi-line data, comments, event and id fields" {
    var r: SseReader = .{};
    defer r.deinit(t.allocator);
    var out: std.ArrayList(SseEvent) = .empty;
    defer {
        for (out.items) |e| e.deinit(t.allocator);
        out.deinit(t.allocator);
    }
    const stream = ": hello\r\ndata: {\"a\":1}\r\n\r\nevent: ping\nid: 7\ndata:x\ndata: y\n\n\rdata: z\r\rdata\n\n";
    // Byte at a time: every split point is a partial read.
    for (stream) |b| try r.feed(t.allocator, &.{b}, &out);
    try t.expectEqual(@as(usize, 4), out.items.len);
    try t.expectEqualStrings("message", out.items[0].event);
    try t.expectEqualStrings("{\"a\":1}", out.items[0].data);
    try t.expectEqualStrings("ping", out.items[1].event);
    try t.expectEqualStrings("x\ny", out.items[1].data);
    try t.expectEqualStrings("7", out.items[1].id);
    try t.expectEqualStrings("z", out.items[2].data);
    try t.expectEqualStrings("message", out.items[2].event);
    try t.expectEqualStrings("7", out.items[2].id);
    try t.expectEqualStrings("", out.items[3].data);
}

test "client: basic auth, JSON body, keep-alive reuse, chunked and 204 responses" {
    var srv: testserver.Server = .{};
    try srv.start(t.allocator);
    defer srv.deinit();
    srv.route("GET /one", .{ .body = "{\"n\":1}" });
    srv.route("POST /echo", .{ .echo = true });
    srv.route("POST /none", .{ .status = 204 });
    srv.route("GET /chunked", .{ .body = "chunked body", .chunked = true });

    var client = try Client.init(t.allocator, .{ .port = srv.port(), .user = "opencode", .password = "pw" });
    defer client.deinit();
    const deadline = nowMs() + 5000;

    const one = try client.call(.{ .method = .GET, .path = "/one" }, deadline);
    defer one.deinit(t.allocator);
    try t.expectEqual(@as(u16, 200), one.status);
    try t.expectEqualStrings("{\"n\":1}", one.body);

    const echo = try client.call(.{ .method = .POST, .path = "/echo", .body = "{\"x\":\"y\"}" }, deadline);
    defer echo.deinit(t.allocator);
    try t.expectEqualStrings("{\"x\":\"y\"}", echo.body);

    const none = try client.call(.{ .method = .POST, .path = "/none" }, deadline);
    defer none.deinit(t.allocator);
    try t.expectEqual(@as(u16, 204), none.status);

    const ch = try client.call(.{ .method = .GET, .path = "/chunked" }, deadline);
    defer ch.deinit(t.allocator);
    try t.expectEqualStrings("chunked body", ch.body);

    // One connection served all four.
    try t.expectEqual(@as(u32, 1), srv.connections());
    const first = srv.request(0);
    try t.expect(std.mem.indexOf(u8, first, "Authorization: Basic b3BlbmNvZGU6cHc=\r\n") != null);
    const second = srv.request(1);
    try t.expect(std.mem.indexOf(u8, second, "Content-Type: application/json\r\nContent-Length: 9\r\n\r\n{\"x\":\"y\"}") != null);
}

test "client: a stale keep-alive connection is retried once on a fresh one" {
    var srv: testserver.Server = .{};
    try srv.start(t.allocator);
    defer srv.deinit();
    srv.route("GET /a", .{ .body = "a", .close_after = true, .keep_alive_header = true });
    srv.route("GET /b", .{ .body = "b" });

    var client = try Client.init(t.allocator, .{ .port = srv.port() });
    defer client.deinit();
    const deadline = nowMs() + 5000;
    const a = try client.call(.{ .method = .GET, .path = "/a" }, deadline);
    defer a.deinit(t.allocator);
    // The server closed after answering while claiming keep-alive; give the
    // FIN time to land so reuse sees a dead socket or a reset.
    srv.waitConnectionsClosed(1, deadline);
    const b = try client.call(.{ .method = .GET, .path = "/b" }, deadline);
    defer b.deinit(t.allocator);
    try t.expectEqualStrings("b", b.body);
    try t.expectEqual(@as(u32, 2), srv.connections());
}

test "client: an async request does not block a quick one, and completes later" {
    var srv: testserver.Server = .{};
    try srv.start(t.allocator);
    defer srv.deinit();
    srv.route("POST /slow", .{ .body = "{\"done\":true}", .delay_ms = 300 });
    srv.route("GET /quick", .{ .body = "q" });

    var client = try Client.init(t.allocator, .{ .port = srv.port() });
    defer client.deinit();
    const ticket = try client.start(.{ .method = .POST, .path = "/slow", .body = "{}" }, null);
    const quick = try client.call(.{ .method = .GET, .path = "/quick" }, nowMs() + 2000);
    defer quick.deinit(t.allocator);
    try t.expectEqualStrings("q", quick.body);
    try t.expect(client.takeCompletion() == null);

    const deadline = nowMs() + 5000;
    const got = while (nowMs() < deadline) {
        var pfds: [MAX_CONNS]c.struct_pollfd = undefined;
        const n = client.pollFds(&pfds);
        _ = c.poll(&pfds, @intCast(n), 50);
        try client.service(nowMs());
        if (client.takeCompletion()) |done| break done;
    } else return error.TestTimeout;
    try t.expectEqual(ticket, got.ticket);
    const resp = got.result.response;
    defer resp.deinit(t.allocator);
    try t.expectEqualStrings("{\"done\":true}", resp.body);
}

test "client: a deadline expires as Timeout and a refused port as ConnectFailed" {
    var srv: testserver.Server = .{};
    try srv.start(t.allocator);
    srv.route("GET /never", .{ .body = "late", .delay_ms = 2000 });
    var client = try Client.init(t.allocator, .{ .port = srv.port() });
    defer client.deinit();
    try t.expectError(error.Timeout, client.call(.{ .method = .GET, .path = "/never" }, nowMs() + 100));
    const port = srv.port();
    srv.deinit();
    var gone = try Client.init(t.allocator, .{ .port = port });
    defer gone.deinit();
    try t.expectError(error.ConnectFailed, gone.call(.{ .method = .GET, .path = "/x" }, nowMs() + 1000));
}

test "event stream: head, chunked SSE split across reads, end of stream" {
    var srv: testserver.Server = .{};
    try srv.start(t.allocator);
    defer srv.deinit();

    var client = try Client.init(t.allocator, .{ .port = srv.port(), .user = "opencode", .password = "pw" });
    defer client.deinit();
    var stream = EventStream.init(t.allocator);
    defer stream.deinit();
    try stream.open(&client, "/event", nowMs() + 2000);
    try t.expect(std.mem.indexOf(u8, srv.request(0), "Accept: text/event-stream\r\n") != null);
    srv.pushEvent("{\"type\":\"session.idle\",\"properties\":{\"sessionID\":\"ses_1\"}}");
    var out: std.ArrayList(SseEvent) = .empty;
    defer {
        for (out.items) |e| e.deinit(t.allocator);
        out.deinit(t.allocator);
    }
    const deadline = nowMs() + 3000;
    while (out.items.len < 2 and nowMs() < deadline) {
        var pfd = c.struct_pollfd{ .fd = stream.fd, .events = c.POLLIN, .revents = 0 };
        _ = c.poll(&pfd, 1, 50);
        try t.expect(try stream.read(&out));
    }
    try t.expectEqual(@as(usize, 2), out.items.len);
    try t.expect(std.mem.indexOf(u8, out.items[0].data, "server.connected") != null);
    try t.expect(std.mem.indexOf(u8, out.items[1].data, "session.idle") != null);
    srv.endStreams();
    const end_deadline = nowMs() + 3000;
    while (nowMs() < end_deadline) {
        var pfd = c.struct_pollfd{ .fd = stream.fd, .events = c.POLLIN, .revents = 0 };
        _ = c.poll(&pfd, 1, 50);
        if (!try stream.read(&out)) break;
    } else return error.TestTimeout;
    try t.expect(!stream.isOpen());
}
