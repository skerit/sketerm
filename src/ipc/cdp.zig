//! Chrome DevTools Protocol client for the MCP browser tools: plain
//! libc TCP + a hand-rolled WebSocket client (RFC 6455, client side)
//! + JSON-RPC-ish CDP calls. GTK-free. Every read/write/connect is
//! deadline-bounded — a wedged browser costs a described error, never
//! a hung MCP tool call.

const std = @import("std");
const c = @import("../c.zig").c;

pub const Error = error{
    ConnectFailed,
    Timeout,
    Protocol,
    Closed,
    TooBig,
    OutOfMemory,
};

const MAX_MSG = 32 * 1024 * 1024;

fn nowMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.tv_sec) * 1000 + @divTrunc(ts.tv_nsec, 1_000_000);
}

/// Non-blocking loopback TCP connect with a deadline.
fn tcpConnect(port: u16, timeout_ms: i64) Error!c_int {
    const fd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
    if (fd < 0) return Error.ConnectFailed;
    errdefer _ = c.close(fd);
    const fl = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
    _ = c.fcntl(fd, c.F_SETFL, fl | c.O_NONBLOCK);
    var addr: c.struct_sockaddr_in = std.mem.zeroes(c.struct_sockaddr_in);
    addr.sin_family = c.AF_INET;
    addr.sin_port = c.htons(port);
    _ = c.inet_pton(c.AF_INET, "127.0.0.1", &addr.sin_addr);
    const rc = c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_in));
    if (rc != 0) {
        const errno = std.posix.errno(rc);
        if (errno != .INPROGRESS) return Error.ConnectFailed;
        var pfd = c.struct_pollfd{ .fd = fd, .events = c.POLLOUT, .revents = 0 };
        if (c.poll(&pfd, 1, @intCast(std.math.clamp(timeout_ms, 1, 60_000))) <= 0)
            return Error.Timeout;
        var so_err: c_int = 0;
        var slen: c.socklen_t = @sizeOf(c_int);
        if (c.getsockopt(fd, c.SOL_SOCKET, c.SO_ERROR, &so_err, &slen) != 0 or so_err != 0)
            return Error.ConnectFailed;
    }
    return fd;
}

fn writeAll(fd: c_int, data: []const u8, deadline: i64) Error!void {
    var off: usize = 0;
    while (off < data.len) {
        const n = c.write(fd, data.ptr + off, data.len - off);
        if (n > 0) {
            off += @intCast(n);
            continue;
        }
        const errno = std.posix.errno(n);
        if (errno != .AGAIN and errno != .INTR) return Error.Closed;
        const left = deadline - nowMs();
        if (left <= 0) return Error.Timeout;
        var pfd = c.struct_pollfd{ .fd = fd, .events = c.POLLOUT, .revents = 0 };
        _ = c.poll(&pfd, 1, @intCast(@min(left, 1000)));
    }
}

/// Read some bytes (>=1) into `buf`, waiting up to the deadline.
fn readSome(fd: c_int, buf: []u8, deadline: i64) Error!usize {
    while (true) {
        const n = c.read(fd, buf.ptr, buf.len);
        if (n > 0) return @intCast(n);
        if (n == 0) return Error.Closed;
        const errno = std.posix.errno(n);
        if (errno != .AGAIN and errno != .INTR) return Error.Closed;
        const left = deadline - nowMs();
        if (left <= 0) return Error.Timeout;
        var pfd = c.struct_pollfd{ .fd = fd, .events = c.POLLIN, .revents = 0 };
        _ = c.poll(&pfd, 1, @intCast(@min(left, 1000)));
    }
}

/// One-shot HTTP/1.1 GET to 127.0.0.1:port; returns the body.
/// Also used (with method PUT) for the /json/new endpoint.
pub fn httpRequest(allocator: std.mem.Allocator, port: u16, method: []const u8, path: []const u8, timeout_ms: i64) Error![]u8 {
    const deadline = nowMs() + timeout_ms;
    const fd = try tcpConnect(port, timeout_ms);
    defer _ = c.close(fd);
    const req = std.fmt.allocPrint(allocator, "{s} {s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nConnection: close\r\n\r\n", .{ method, path, port }) catch return Error.OutOfMemory;
    defer allocator.free(req);
    try writeAll(fd, req, deadline);
    var all: std.ArrayList(u8) = .empty;
    errdefer all.deinit(allocator);
    var buf: [16384]u8 = undefined;
    // Chromium's DevTools server keeps the connection open despite
    // `Connection: close`, so honor Content-Length and stop there;
    // read-until-close is only the fallback.
    while (true) {
        if (std.mem.indexOf(u8, all.items, "\r\n\r\n")) |hdr_end| {
            if (contentLength(all.items[0..hdr_end])) |want| {
                if (all.items.len >= hdr_end + 4 + want) break;
            }
        }
        const n = readSome(fd, &buf, deadline) catch |err| switch (err) {
            Error.Closed => break,
            else => return err,
        };
        all.appendSlice(allocator, buf[0..n]) catch return Error.OutOfMemory;
        if (all.items.len > MAX_MSG) return Error.TooBig;
    }
    const text = all.items;
    const split = std.mem.indexOf(u8, text, "\r\n\r\n") orelse return Error.Protocol;
    const headers = text[0..split];
    var body: []const u8 = text[split + 4 ..];
    // The DevTools endpoint answers Connection: close without chunked
    // encoding, but be tolerant of a chunked reply anyway.
    if (std.ascii.indexOfIgnoreCase(headers, "transfer-encoding: chunked") != null) {
        body = dechunk(body);
    }
    const out = allocator.dupe(u8, body) catch return Error.OutOfMemory;
    all.deinit(allocator);
    return out;
}

/// Case-insensitive Content-Length lookup in a raw header block.
fn contentLength(headers: []const u8) ?usize {
    const at = std.ascii.indexOfIgnoreCase(headers, "content-length:") orelse return null;
    var i = at + "content-length:".len;
    while (i < headers.len and headers[i] == ' ') i += 1;
    var val: usize = 0;
    var digits: usize = 0;
    while (i < headers.len and headers[i] >= '0' and headers[i] <= '9') : (i += 1) {
        val = val * 10 + (headers[i] - '0');
        digits += 1;
    }
    return if (digits > 0) val else null;
}

test "contentLength" {
    const t = std.testing;
    try t.expectEqual(@as(?usize, 120), contentLength("HTTP/1.1 200 OK\r\nContent-Length: 120\r\nX: y"));
    try t.expectEqual(@as(?usize, null), contentLength("HTTP/1.1 200 OK\r\nX: y"));
}

/// Best-effort in-place view of a chunked body's first run of chunks.
fn dechunk(body: []const u8) []const u8 {
    const nl = std.mem.indexOf(u8, body, "\r\n") orelse return body;
    const size = std.fmt.parseInt(usize, std.mem.trim(u8, body[0..nl], " "), 16) catch return body;
    const start = nl + 2;
    if (start + size > body.len) return body[@min(start, body.len)..];
    return body[start .. start + size];
}

/// Parse "DevTools listening on ws://127.0.0.1:PORT/..." → PORT.
pub fn parseDevtoolsPort(text: []const u8) ?u16 {
    const needle = "DevTools listening on ws://127.0.0.1:";
    const at = std.mem.indexOf(u8, text, needle) orelse return null;
    var i = at + needle.len;
    var port: u32 = 0;
    var digits: usize = 0;
    while (i < text.len and text[i] >= '0' and text[i] <= '9') : (i += 1) {
        port = port * 10 + (text[i] - '0');
        digits += 1;
        if (port > 65535) return null;
    }
    if (digits == 0 or port == 0) return null;
    return @intCast(port);
}

// ── WebSocket framing ─────────────────────────────────────────────

/// Build one masked client frame around `payload` (opcode 1 = text).
pub fn wsEncodeFrame(allocator: std.mem.Allocator, opcode: u8, payload: []const u8, mask: [4]u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, 0x80 | opcode);
    if (payload.len < 126) {
        try out.append(allocator, 0x80 | @as(u8, @intCast(payload.len)));
    } else if (payload.len <= 0xffff) {
        try out.append(allocator, 0x80 | 126);
        var b: [2]u8 = undefined;
        std.mem.writeInt(u16, &b, @intCast(payload.len), .big);
        try out.appendSlice(allocator, &b);
    } else {
        try out.append(allocator, 0x80 | 127);
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, payload.len, .big);
        try out.appendSlice(allocator, &b);
    }
    try out.appendSlice(allocator, &mask);
    const start = out.items.len;
    try out.appendSlice(allocator, payload);
    for (out.items[start..], 0..) |*b, i| b.* ^= mask[i % 4];
    return out.toOwnedSlice(allocator);
}

pub const WsFrame = struct {
    opcode: u8,
    fin: bool,
    payload_start: usize,
    payload_len: usize,
    total_len: usize,
};

/// Parse one server frame header from `data`; null = need more bytes.
pub fn wsDecodeHeader(data: []const u8) !?WsFrame {
    if (data.len < 2) return null;
    const fin = data[0] & 0x80 != 0;
    const opcode = data[0] & 0x0f;
    if (data[1] & 0x80 != 0) return error.MaskedServerFrame;
    var len: u64 = data[1] & 0x7f;
    var off: usize = 2;
    if (len == 126) {
        if (data.len < 4) return null;
        len = std.mem.readInt(u16, data[2..4], .big);
        off = 4;
    } else if (len == 127) {
        if (data.len < 10) return null;
        len = std.mem.readInt(u64, data[2..10], .big);
        off = 10;
    }
    if (len > MAX_MSG) return error.FrameTooBig;
    if (data.len < off + len) return null;
    return .{ .opcode = opcode, .fin = fin, .payload_start = off, .payload_len = @intCast(len), .total_len = off + @as(usize, @intCast(len)) };
}

// ── The client ────────────────────────────────────────────────────

pub const Client = struct {
    allocator: std.mem.Allocator,
    port: u16,
    fd: c_int = -1,
    rbuf: std.ArrayList(u8) = .empty,
    next_id: u32 = 1,
    /// The attached page target's id (for reattach after navigation
    /// that replaces the target).
    target_id: []u8 = &.{},

    pub fn init(allocator: std.mem.Allocator, port: u16) Client {
        return .{ .allocator = allocator, .port = port };
    }

    pub fn deinit(self: *Client) void {
        self.closeFd();
        self.rbuf.deinit(self.allocator);
        if (self.target_id.len > 0) self.allocator.free(self.target_id);
        self.target_id = &.{};
    }

    fn closeFd(self: *Client) void {
        if (self.fd >= 0) _ = c.close(self.fd);
        self.fd = -1;
        self.rbuf.clearRetainingCapacity();
    }

    pub fn connected(self: *const Client) bool {
        return self.fd >= 0;
    }

    /// Discover the newest page target via /json/list and attach its
    /// WebSocket. Reconnects from scratch when already connected.
    pub fn attach(self: *Client, timeout_ms: i64) Error!void {
        self.closeFd();
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const body = try httpRequest(arena, self.port, "GET", "/json/list", timeout_ms);
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return Error.Protocol;
        if (parsed != .array) return Error.Protocol;
        var ws_url: ?[]const u8 = null;
        var tid: ?[]const u8 = null;
        for (parsed.array.items) |item| {
            if (item != .object) continue;
            const ty = item.object.get("type") orelse continue;
            if (ty != .string or !std.mem.eql(u8, ty.string, "page")) continue;
            const u = item.object.get("webSocketDebuggerUrl") orelse continue;
            if (u != .string) continue;
            ws_url = u.string;
            if (item.object.get("id")) |idv| {
                if (idv == .string) tid = idv.string;
            }
            break; // newest page first
        }
        const url = ws_url orelse return Error.Protocol;
        const path_at = std.mem.indexOfPos(u8, url, "ws://".len, "/") orelse return Error.Protocol;
        try self.wsUpgrade(url[path_at..], timeout_ms);
        if (self.target_id.len > 0) self.allocator.free(self.target_id);
        self.target_id = self.allocator.dupe(u8, tid orelse "") catch return Error.OutOfMemory;
    }

    fn wsUpgrade(self: *Client, path: []const u8, timeout_ms: i64) Error!void {
        const deadline = nowMs() + timeout_ms;
        const fd = try tcpConnect(self.port, timeout_ms);
        errdefer _ = c.close(fd);
        var key_raw: [16]u8 = undefined;
        if (c.getentropy(&key_raw, key_raw.len) != 0) return Error.ConnectFailed;
        var key_b64: [24]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&key_b64, &key_raw);
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const req = std.fmt.allocPrint(arena_state.allocator(), "GET {s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n\r\n", .{ path, self.port, key_b64 }) catch return Error.OutOfMemory;
        try writeAll(fd, req, deadline);
        // Read until the header terminator.
        var hdr: std.ArrayList(u8) = .empty;
        defer hdr.deinit(self.allocator);
        var buf: [4096]u8 = undefined;
        while (std.mem.indexOf(u8, hdr.items, "\r\n\r\n") == null) {
            if (hdr.items.len > 65536) return Error.Protocol;
            const n = try readSome(fd, &buf, deadline);
            hdr.appendSlice(self.allocator, buf[0..n]) catch return Error.OutOfMemory;
        }
        const end = std.mem.indexOf(u8, hdr.items, "\r\n\r\n").? + 4;
        if (std.mem.indexOf(u8, hdr.items[0..end], " 101 ") == null) return Error.Protocol;
        self.fd = fd;
        self.rbuf.clearRetainingCapacity();
        // Bytes past the header already belong to the WS stream.
        self.rbuf.appendSlice(self.allocator, hdr.items[end..]) catch return Error.OutOfMemory;
    }

    fn sendFrame(self: *Client, opcode: u8, payload: []const u8, deadline: i64) Error!void {
        if (self.fd < 0) return Error.Closed;
        var mask: [4]u8 = undefined;
        if (c.getentropy(&mask, mask.len) != 0) mask = .{ 0x13, 0x37, 0xbe, 0xef };
        const frame = wsEncodeFrame(self.allocator, opcode, payload, mask) catch return Error.OutOfMemory;
        defer self.allocator.free(frame);
        writeAll(self.fd, frame, deadline) catch |err| {
            self.closeFd();
            return err;
        };
    }

    /// Receive one complete text message (handles continuation and
    /// control frames). Caller frees.
    fn recvMessage(self: *Client, deadline: i64) Error![]u8 {
        if (self.fd < 0) return Error.Closed;
        var msg: std.ArrayList(u8) = .empty;
        errdefer msg.deinit(self.allocator);
        var buf: [65536]u8 = undefined;
        while (true) {
            const frame = (wsDecodeHeader(self.rbuf.items) catch {
                self.closeFd();
                return Error.Protocol;
            }) orelse {
                const n = readSome(self.fd, &buf, deadline) catch |err| {
                    self.closeFd();
                    return err;
                };
                self.rbuf.appendSlice(self.allocator, buf[0..n]) catch return Error.OutOfMemory;
                continue;
            };
            const payload = self.rbuf.items[frame.payload_start .. frame.payload_start + frame.payload_len];
            switch (frame.opcode) {
                0x1, 0x0 => {
                    msg.appendSlice(self.allocator, payload) catch return Error.OutOfMemory;
                    if (msg.items.len > MAX_MSG) return Error.TooBig;
                    const done = frame.fin;
                    self.consume(frame.total_len);
                    if (done) return msg.toOwnedSlice(self.allocator) catch return Error.OutOfMemory;
                },
                0x9 => { // ping → pong
                    const pong = self.allocator.dupe(u8, payload) catch return Error.OutOfMemory;
                    defer self.allocator.free(pong);
                    self.consume(frame.total_len);
                    try self.sendFrame(0xA, pong, deadline);
                },
                0x8 => {
                    self.closeFd();
                    return Error.Closed;
                },
                else => self.consume(frame.total_len), // pong/binary: drop
            }
        }
    }

    fn consume(self: *Client, n: usize) void {
        const remaining = self.rbuf.items.len - n;
        std.mem.copyForwards(u8, self.rbuf.items[0..remaining], self.rbuf.items[n..]);
        self.rbuf.shrinkRetainingCapacity(remaining);
    }

    /// One CDP call: send {id, method, params}, pump messages until
    /// the matching id answers (events are discarded). Returns the
    /// full response object as arena-owned JSON text.
    pub fn call(self: *Client, arena: std.mem.Allocator, method: []const u8, params_json: ?[]const u8, timeout_ms: i64) Error![]u8 {
        const deadline = nowMs() + timeout_ms;
        const id = self.next_id;
        self.next_id += 1;
        const payload = std.fmt.allocPrint(self.allocator, "{{\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}", .{ id, method, params_json orelse "{}" }) catch return Error.OutOfMemory;
        defer self.allocator.free(payload);
        try self.sendFrame(0x1, payload, deadline);
        var needle_buf: [32]u8 = undefined;
        const needle = std.fmt.bufPrint(&needle_buf, "{{\"id\":{d},", .{id}) catch unreachable;
        while (true) {
            const msg = try self.recvMessage(deadline);
            defer self.allocator.free(msg);
            if (std.mem.startsWith(u8, msg, needle)) {
                return arena.dupe(u8, msg) catch return Error.OutOfMemory;
            }
            // Anything else is an event or a stale reply: discard.
            if (nowMs() >= deadline) return Error.Timeout;
        }
    }

    pub const EvalResult = struct {
        /// JSON text of the value (already stringified), or null when
        /// the expression produced undefined.
        value_json: ?[]const u8,
        exception: ?[]const u8,
    };

    /// Runtime.evaluate with returnByValue. `expr` is raw JavaScript.
    pub fn eval(self: *Client, arena: std.mem.Allocator, expr: []const u8, timeout_ms: i64) Error!EvalResult {
        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        w.writeAll("{\"expression\":") catch return Error.OutOfMemory;
        std.json.Stringify.value(expr, .{}, w) catch return Error.OutOfMemory;
        w.writeAll(",\"returnByValue\":true,\"awaitPromise\":true,\"userGesture\":true}") catch return Error.OutOfMemory;
        const resp = try self.call(arena, "Runtime.evaluate", aw.written(), timeout_ms);
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, resp, .{}) catch return Error.Protocol;
        if (parsed != .object) return Error.Protocol;
        const result = parsed.object.get("result") orelse return Error.Protocol;
        if (result != .object) return Error.Protocol;
        if (result.object.get("exceptionDetails")) |ex| {
            var desc: []const u8 = "JavaScript exception";
            if (ex == .object) {
                if (ex.object.get("exception")) |e| {
                    if (e == .object) {
                        if (e.object.get("description")) |d| {
                            if (d == .string) desc = d.string;
                        }
                    }
                }
                if (std.mem.eql(u8, desc, "JavaScript exception")) {
                    if (ex.object.get("text")) |t| {
                        if (t == .string) desc = t.string;
                    }
                }
            }
            return .{ .value_json = null, .exception = desc };
        }
        const inner = result.object.get("result") orelse return .{ .value_json = null, .exception = null };
        if (inner != .object) return .{ .value_json = null, .exception = null };
        const val = inner.object.get("value") orelse return .{ .value_json = null, .exception = null };
        var vw: std.Io.Writer.Allocating = .init(arena);
        std.json.Stringify.value(val, .{}, &vw.writer) catch return Error.OutOfMemory;
        return .{ .value_json = vw.written(), .exception = null };
    }

    /// Dispatch a trusted mouse click at CSS-pixel viewport coords.
    pub fn clickAt(self: *Client, arena: std.mem.Allocator, x: f64, y: f64, button: []const u8, click_count: u32, timeout_ms: i64) Error!void {
        const moved = std.fmt.allocPrint(arena, "{{\"type\":\"mouseMoved\",\"x\":{d},\"y\":{d}}}", .{ x, y }) catch return Error.OutOfMemory;
        _ = try self.call(arena, "Input.dispatchMouseEvent", moved, timeout_ms);
        const pressed = std.fmt.allocPrint(arena, "{{\"type\":\"mousePressed\",\"x\":{d},\"y\":{d},\"button\":\"{s}\",\"clickCount\":{d}}}", .{ x, y, button, click_count }) catch return Error.OutOfMemory;
        _ = try self.call(arena, "Input.dispatchMouseEvent", pressed, timeout_ms);
        const released = std.fmt.allocPrint(arena, "{{\"type\":\"mouseReleased\",\"x\":{d},\"y\":{d},\"button\":\"{s}\",\"clickCount\":{d}}}", .{ x, y, button, click_count }) catch return Error.OutOfMemory;
        _ = try self.call(arena, "Input.dispatchMouseEvent", released, timeout_ms);
    }

    /// Insert text into the focused element as trusted input.
    pub fn insertText(self: *Client, arena: std.mem.Allocator, text: []const u8, timeout_ms: i64) Error!void {
        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        w.writeAll("{\"text\":") catch return Error.OutOfMemory;
        std.json.Stringify.value(text, .{}, w) catch return Error.OutOfMemory;
        w.writeAll("}") catch return Error.OutOfMemory;
        _ = try self.call(arena, "Input.insertText", aw.written(), timeout_ms);
    }
};

// ── Tests ─────────────────────────────────────────────────────────

test "parseDevtoolsPort" {
    const t = std.testing;
    try t.expectEqual(@as(?u16, 34567), parseDevtoolsPort("junk\nDevTools listening on ws://127.0.0.1:34567/devtools/browser/abc\nmore"));
    try t.expectEqual(@as(?u16, null), parseDevtoolsPort("no devtools here"));
    try t.expectEqual(@as(?u16, null), parseDevtoolsPort("DevTools listening on ws://127.0.0.1:/x"));
    try t.expectEqual(@as(?u16, 9222), parseDevtoolsPort("DevTools listening on ws://127.0.0.1:9222/"));
}

test "ws frame encode/decode round-trip" {
    const t = std.testing;
    const mask = [4]u8{ 1, 2, 3, 4 };
    // Short frame.
    const short = try wsEncodeFrame(t.allocator, 0x1, "hello", mask);
    defer t.allocator.free(short);
    try t.expectEqual(@as(u8, 0x81), short[0]);
    try t.expectEqual(@as(u8, 0x80 | 5), short[1]);
    // Unmask it back (server frames are unmasked; emulate by clearing
    // the mask bit and stripping the key after XOR).
    var unmasked: [7]u8 = undefined;
    unmasked[0] = short[0];
    unmasked[1] = 5;
    for (short[6..], 0..) |b, i| unmasked[2 + i] = b ^ mask[i % 4];
    const hdr = (try wsDecodeHeader(&unmasked)).?;
    try t.expectEqual(@as(u8, 0x1), hdr.opcode);
    try t.expect(hdr.fin);
    try t.expectEqualStrings("hello", unmasked[hdr.payload_start .. hdr.payload_start + hdr.payload_len]);
    // 16-bit length.
    const big_payload = try t.allocator.alloc(u8, 300);
    defer t.allocator.free(big_payload);
    @memset(big_payload, 'x');
    const big = try wsEncodeFrame(t.allocator, 0x1, big_payload, mask);
    defer t.allocator.free(big);
    try t.expectEqual(@as(u8, 0x80 | 126), big[1]);
    try t.expectEqual(@as(u16, 300), std.mem.readInt(u16, big[2..4], .big));
    // Partial header → null (need more).
    try t.expectEqual(@as(?WsFrame, null), try wsDecodeHeader(&.{0x81}));
    // Masked server frame is a protocol error.
    try t.expectError(error.MaskedServerFrame, wsDecodeHeader(&.{ 0x81, 0x85, 0, 0, 0, 0, 0 }));
}

test "dechunk" {
    const t = std.testing;
    try t.expectEqualStrings("hello", dechunk("5\r\nhello\r\n0\r\n\r\n"));
    try t.expectEqualStrings("notchunked", dechunk("notchunked"));
}
