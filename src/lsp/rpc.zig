//! JSON-RPC 2.0 over the LSP base protocol: `Content-Length: N\r\n\r\n`
//! headers followed by exactly N bytes of UTF-8 JSON.
//!
//! `Reader` is a byte-at-a-time-safe incremental parser: the GUI feeds
//! it whatever a non-blocking `read()` returned (which may cut a header
//! in half, or carry three whole messages plus a fragment) and pulls
//! complete bodies out. It never blocks and never allocates per message
//! beyond growing its own buffer.
//!
//! Gotcha: `next()`'s slice points INTO the reader's buffer and is
//! invalidated by the following `feed`/`next`. Callers parse it (into
//! their own arena) before pulling the next message.
//!
//! `Content-Type` and any other header are accepted and ignored; a
//! header block without a usable `Content-Length` is a protocol error
//! the caller must treat as "kill this server", because there is no way
//! to resynchronise a stream whose framing we have lost.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    /// A header block with no parsable Content-Length.
    BadFraming,
    /// A message larger than `max_body` — a runaway or hostile server.
    BodyTooLarge,
} || Allocator.Error;

/// 64 MiB. Real completion responses from clangd on a big TU reach
/// single-digit MiB; anything past this is a bug on the other side.
pub const MAX_BODY: usize = 64 << 20;

pub const Reader = struct {
    buf: std.ArrayList(u8) = .empty,
    /// Bytes at the head of `buf` already handed out and consumable.
    start: usize = 0,
    max_body: usize = MAX_BODY,

    pub fn deinit(self: *Reader, alloc: Allocator) void {
        self.buf.deinit(alloc);
        self.* = .{};
    }

    pub fn feed(self: *Reader, alloc: Allocator, bytes: []const u8) Allocator.Error!void {
        self.compact(alloc);
        try self.buf.appendSlice(alloc, bytes);
    }

    /// Drop the already-consumed prefix. Done lazily (on feed) so a
    /// burst of `next()` calls does not memmove per message.
    fn compact(self: *Reader, alloc: Allocator) void {
        _ = alloc;
        if (self.start == 0) return;
        const rest = self.buf.items[self.start..];
        std.mem.copyForwards(u8, self.buf.items[0..rest.len], rest);
        self.buf.shrinkRetainingCapacity(rest.len);
        self.start = 0;
    }

    /// Next complete message body, or null when more bytes are needed.
    /// The slice is invalidated by the next feed/next call.
    pub fn next(self: *Reader) Error!?[]const u8 {
        const avail = self.buf.items[self.start..];
        const sep = std.mem.indexOf(u8, avail, "\r\n\r\n") orelse return null;
        const header = avail[0..sep];
        const body_start = sep + 4;
        const len = parseContentLength(header) orelse return Error.BadFraming;
        if (len > self.max_body) return Error.BodyTooLarge;
        if (avail.len < body_start + len) return null;
        self.start += body_start + len;
        return avail[body_start .. body_start + len];
    }

    /// Bytes buffered but not yet formed into a message (diagnostics).
    pub fn pending(self: *const Reader) usize {
        return self.buf.items.len - self.start;
    }
};

fn parseContentLength(header: []const u8) ?usize {
    var lines = std.mem.splitSequence(u8, header, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "content-length")) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        return std.fmt.parseInt(usize, value, 10) catch null;
    }
    return null;
}

/// Prepend the base-protocol header to `body` (caller owns the result).
pub fn frame(alloc: Allocator, body: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var head: [48]u8 = undefined;
    const h = std.fmt.bufPrint(&head, "Content-Length: {d}\r\n\r\n", .{body.len}) catch unreachable;
    try out.appendSlice(alloc, h);
    try out.appendSlice(alloc, body);
    return out.toOwnedSlice(alloc);
}

/// Append the framed message to an existing outbound queue — the shape
/// the GUI's write queue wants (one buffer, no per-message allocation).
pub fn frameInto(alloc: Allocator, out: *std.ArrayList(u8), body: []const u8) Allocator.Error!void {
    var head: [48]u8 = undefined;
    const h = std.fmt.bufPrint(&head, "Content-Length: {d}\r\n\r\n", .{body.len}) catch unreachable;
    try out.appendSlice(alloc, h);
    try out.appendSlice(alloc, body);
}

// ---- JSON envelope ----------------------------------------------------

pub const MessageKind = enum { response, notification, request, invalid };

/// The parts of a JSON-RPC envelope a client cares about. `result`,
/// `params` and `err` borrow from the caller's parsed document.
pub const Envelope = struct {
    kind: MessageKind,
    /// Present on responses and server->client requests.
    id: ?i64 = null,
    /// String request id, when the server minted one (zls's
    /// `workspace/configuration` uses "i_haz_configuration"). Only ever
    /// set on server->client REQUESTS — responses match our own ids,
    /// which are always integers. Borrows from the parsed document.
    id_str: []const u8 = "",
    /// Present on notifications and requests.
    method: []const u8 = "",
    params: std.json.Value = .null,
    result: std.json.Value = .null,
    err_code: i64 = 0,
    err_message: []const u8 = "",
    has_error: bool = false,
};

/// Classify a parsed JSON-RPC message. Server->client REQUESTS (id +
/// method) are distinguished from notifications (method, no id) and
/// responses (id, no method), because a request MUST be answered or the
/// server stalls waiting (clangd's `window/workDoneProgress/create` is
/// the one every client trips over).
pub fn classify(v: std.json.Value) Envelope {
    const obj = switch (v) {
        .object => |o| o,
        else => return .{ .kind = .invalid },
    };
    const raw_id = obj.get("id") orelse std.json.Value.null;
    const id: ?i64 = switch (raw_id) {
        .integer => |i| i,
        else => null,
    };
    // String ids are legal JSON-RPC. We never mint them, so a RESPONSE
    // carrying one answers a request we did not send — but a
    // server->client REQUEST may use any id it likes (zls does) and
    // must be answered with that id echoed back verbatim.
    const id_str: []const u8 = switch (raw_id) {
        .string => |s| s,
        else => "",
    };
    const method: []const u8 = switch (obj.get("method") orelse std.json.Value.null) {
        .string => |s| s,
        else => "",
    };
    if (method.len > 0) {
        return .{
            .kind = if (id != null or id_str.len > 0) .request else .notification,
            .id = id,
            .id_str = id_str,
            .method = method,
            .params = obj.get("params") orelse .null,
        };
    }
    if (id == null) return .{ .kind = .invalid };
    var env = Envelope{
        .kind = .response,
        .id = id,
        .result = obj.get("result") orelse .null,
    };
    if (obj.get("error")) |e| {
        if (e == .object) {
            env.has_error = true;
            env.err_code = switch (e.object.get("code") orelse std.json.Value.null) {
                .integer => |i| i,
                else => 0,
            };
            env.err_message = switch (e.object.get("message") orelse std.json.Value.null) {
                .string => |s| s,
                else => "",
            };
        }
    }
    return env;
}

/// JSON-RPC error code for "the request you sent was cancelled".
pub const REQUEST_CANCELLED: i64 = -32800;
/// "the result is stale, request it again" (LSP 3.17 content-modified).
pub const CONTENT_MODIFIED: i64 = -32801;

// ======================================================================
// Tests
// ======================================================================

const testing = std.testing;

test "rpc reader: one whole message" {
    var r = Reader{};
    defer r.deinit(testing.allocator);
    try r.feed(testing.allocator, "Content-Length: 2\r\n\r\n{}");
    const body = (try r.next()).?;
    try testing.expectEqualStrings("{}", body);
    try testing.expect((try r.next()) == null);
}

test "rpc reader: byte-at-a-time delivery" {
    const wire = "Content-Length: 13\r\n\r\n{\"jsonrpc\":1}";
    var r = Reader{};
    defer r.deinit(testing.allocator);
    for (wire, 0..) |ch, i| {
        try r.feed(testing.allocator, wire[i .. i + 1]);
        _ = ch;
        if (i + 1 < wire.len) try testing.expect((try r.next()) == null);
    }
    try testing.expectEqualStrings("{\"jsonrpc\":1}", (try r.next()).?);
}

test "rpc reader: several messages plus a trailing fragment" {
    var r = Reader{};
    defer r.deinit(testing.allocator);
    try r.feed(
        testing.allocator,
        "Content-Length: 2\r\n\r\n{}" ++
            "Content-Length: 4\r\n\r\n[1,2" ++
            "Content-Le",
    );
    try testing.expectEqualStrings("{}", (try r.next()).?);
    try testing.expectEqualStrings("[1,2", (try r.next()).?);
    try testing.expect((try r.next()) == null);
    // The fragment survives to the next feed.
    try r.feed(testing.allocator, "ngth: 2\r\n\r\nab");
    try testing.expectEqualStrings("ab", (try r.next()).?);
}

test "rpc reader: extra headers and odd casing are accepted" {
    var r = Reader{};
    defer r.deinit(testing.allocator);
    try r.feed(
        testing.allocator,
        "Content-Type: application/vscode-jsonrpc; charset=utf-8\r\n" ++
            "content-length:  3 \r\n\r\nabc",
    );
    try testing.expectEqualStrings("abc", (try r.next()).?);
}

test "rpc reader: a header block without Content-Length is fatal" {
    var r = Reader{};
    defer r.deinit(testing.allocator);
    try r.feed(testing.allocator, "X-Nonsense: 1\r\n\r\nzz");
    try testing.expectError(Error.BadFraming, r.next());
}

test "rpc reader: oversized body is refused" {
    var r = Reader{};
    defer r.deinit(testing.allocator);
    r.max_body = 4;
    try r.feed(testing.allocator, "Content-Length: 99\r\n\r\n");
    try testing.expectError(Error.BodyTooLarge, r.next());
}

test "rpc reader: multibyte bodies are counted in BYTES not codepoints" {
    var r = Reader{};
    defer r.deinit(testing.allocator);
    // "\u{1F600}" is 4 bytes inside a 6-byte JSON string literal.
    try r.feed(testing.allocator, "Content-Length: 6\r\n\r\n\"\u{1F600}\"rest");
    try testing.expectEqualStrings("\"\u{1F600}\"", (try r.next()).?);
    try testing.expectEqual(@as(usize, 4), r.pending());
}

test "rpc frame writes the header" {
    const f = try frame(testing.allocator, "{\"a\":1}");
    defer testing.allocator.free(f);
    try testing.expectEqualStrings("Content-Length: 7\r\n\r\n{\"a\":1}", f);
}

test "rpc classify: response, notification, request, error" {
    const cases = .{
        .{ "{\"id\":4,\"result\":{\"x\":1}}", MessageKind.response },
        .{ "{\"method\":\"textDocument/publishDiagnostics\",\"params\":{}}", MessageKind.notification },
        .{ "{\"id\":9,\"method\":\"window/workDoneProgress/create\",\"params\":{}}", MessageKind.request },
        .{ "[1,2]", MessageKind.invalid },
    };
    inline for (cases) |case| {
        var p = try std.json.parseFromSlice(std.json.Value, testing.allocator, case[0], .{});
        defer p.deinit();
        try testing.expectEqual(case[1], classify(p.value).kind);
    }

    var p = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"id\":3,\"error\":{\"code\":-32800,\"message\":\"cancelled\"}}",
        .{},
    );
    defer p.deinit();
    const env = classify(p.value);
    try testing.expectEqual(MessageKind.response, env.kind);
    try testing.expect(env.has_error);
    try testing.expectEqual(REQUEST_CANCELLED, env.err_code);
    try testing.expectEqualStrings("cancelled", env.err_message);
}

test "rpc classify: a string-id server request is a request, not a notification" {
    // zls mints "i_haz_configuration" for workspace/configuration; a
    // client that drops the id treats it as a notification, never
    // answers, and zls silently stops serving completions.
    var p = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"i_haz_configuration\",\"method\":\"workspace/configuration\",\"params\":{\"items\":[{}]}}",
        .{},
    );
    defer p.deinit();
    const env = classify(p.value);
    try testing.expectEqual(MessageKind.request, env.kind);
    try testing.expect(env.id == null);
    try testing.expectEqualStrings("i_haz_configuration", env.id_str);

    // A RESPONSE with a string id answers nothing we sent: invalid.
    var p2 = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":\"x\",\"result\":null}",
        .{},
    );
    defer p2.deinit();
    try testing.expectEqual(MessageKind.invalid, classify(p2.value).kind);
}
