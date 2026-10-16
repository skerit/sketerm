//! The client side of the `peer_*` frames over one mux `Conn`, so the
//! MCP server and the CLI never touch the wire. A peer connection gets
//! pushes (`peer_deliver`, `peer_event`, the `peer_list` answering a
//! registration) at any time, also while it waits for a reply: those are
//! kept in `inbox`, never dropped, and taken with `nextPush`.

const std = @import("std");
const wire = @import("wire.zig");
const muxclient = @import("client.zig");
pub const peermail = @import("peermail.zig");

const Conn = muxclient.Conn;
const OwnedFrame = Conn.OwnedFrame;
const nowMs = @import("../util/clock.zig").nowMs;

/// One decoded push.
pub const Push = union(enum) {
    deliver: std.json.Parsed(peermail.Deliver),
    event: std.json.Parsed(peermail.Event),
    /// The answer to a `peer_register` (`self` set).
    registered: std.json.Parsed(peermail.ListReply),

    pub fn deinit(self: Push) void {
        switch (self) {
            inline else => |p| p.deinit(),
        }
    }
};

pub const Peer = struct {
    conn: *Conn,
    inbox: std.ArrayList(OwnedFrame) = .empty,
    next_req: u32 = 0,

    pub fn init(conn: *Conn) Peer {
        return .{ .conn = conn };
    }

    pub fn deinit(self: *Peer) void {
        for (self.inbox.items) |f| f.deinit(self.conn.allocator);
        self.inbox.deinit(self.conn.allocator);
    }

    /// Whether the daemon serves peers at all (welcome flag `peers`).
    pub fn available(self: *const Peer) bool {
        return self.conn.caps.peers;
    }

    /// Announce (or update) this connection; the answer arrives as a
    /// `registered` push.
    pub fn register(self: *Peer, req: peermail.RegisterReq) !void {
        if (!self.available()) return error.Unsupported;
        try self.conn.sendJson(.peer_register, req);
    }

    /// Every known peer.
    pub fn list(self: *Peer, allocator: std.mem.Allocator, timeout_ms: i64) !std.json.Parsed(peermail.ListReply) {
        if (!self.available()) return error.Unsupported;
        const req = self.nextReq();
        try self.conn.sendJson(.peer_list_req, peermail.ListReq{ .req = req });
        return self.awaitReply(peermail.ListReply, allocator, .peer_list, req, timeout_ms);
    }

    /// Send one message (`req.req` is set here) and wait for its outcome.
    /// `quiet` and `to_list` need `slowMail()`; an older daemon would
    /// ignore them and wake every recipient of `to` alone.
    pub fn send(self: *Peer, allocator: std.mem.Allocator, req: peermail.SendReq, timeout_ms: i64) !std.json.Parsed(peermail.SendReply) {
        if (!self.available()) return error.Unsupported;
        if ((req.quiet or req.to_list.len > 0) and !self.slowMail()) return error.Unsupported;
        var r = req;
        r.req = self.nextReq();
        try self.conn.sendJson(.peer_send, r);
        return self.awaitReply(peermail.SendReply, allocator, .peer_send_reply, r.req, timeout_ms);
    }

    /// Whether the broker judges wakes and takes slow mail and `to_list`
    /// (welcome flag `peer_slow_mail`).
    pub fn slowMail(self: *const Peer) bool {
        return self.conn.caps.peer_slow_mail;
    }

    /// These ids were handed to the client; the broker forgets them.
    pub fn ack(self: *Peer, ids: []const []const u8) !void {
        if (!self.available()) return error.Unsupported;
        try self.conn.sendJson(.peer_ack, peermail.AckReq{ .ids = ids });
    }

    /// Whether the broker keeps user-set subjects (welcome flag `peer_subject`).
    pub fn subjects(self: *const Peer) bool {
        return self.conn.caps.peer_subject;
    }

    /// Whether the broker keeps aliases (welcome flag `peer_alias`): a
    /// client then registers an opaque address and asks for its name as
    /// an alias (`RegisterReq.alias`).
    pub fn aliases(self: *const Peer) bool {
        return self.conn.caps.peer_alias;
    }

    /// Whether the broker reports which peers poll (welcome flag `peer_polls`).
    pub fn polls(self: *const Peer) bool {
        return self.conn.caps.peer_polls;
    }

    /// Whether the broker keeps each live peer's note (welcome flag `peer_note`).
    pub fn notes(self: *const Peer) bool {
        return self.conn.caps.peer_note;
    }

    /// Ask (`subject` null), set or clear (`""`) the subject of `address`.
    pub fn subject(self: *Peer, allocator: std.mem.Allocator, address: []const u8, value: ?[]const u8, timeout_ms: i64) !std.json.Parsed(peermail.SubjectReply) {
        if (!self.subjects()) return error.Unsupported;
        return self.identity(allocator, .{ .address = address, .subject = value }, timeout_ms);
    }

    /// Ask (`value` null), set or clear (`""`) the note of the live peer
    /// `address`; the reply carries the subject too.
    pub fn note(self: *Peer, allocator: std.mem.Allocator, address: []const u8, value: ?[]const u8, timeout_ms: i64) !std.json.Parsed(peermail.SubjectReply) {
        if (!self.notes()) return error.Unsupported;
        return self.identity(allocator, .{ .address = address, .note = value }, timeout_ms);
    }

    /// One `peer_subject` request (`req.req` is set here) and its reply.
    fn identity(self: *Peer, allocator: std.mem.Allocator, req: peermail.SubjectReq, timeout_ms: i64) !std.json.Parsed(peermail.SubjectReply) {
        var r = req;
        r.req = self.nextReq();
        try self.conn.sendJson(.peer_subject, r);
        return self.awaitReply(peermail.SubjectReply, allocator, .peer_subject_reply, r.req, timeout_ms);
    }

    /// The oldest push received so far, or the next one within `timeout_ms`
    /// (0 = only what has already arrived: the inbox, frames buffered on
    /// the connection and bytes waiting on its socket); other frames are
    /// skipped.
    /// @return null on timeout.
    pub fn nextPush(self: *Peer, allocator: std.mem.Allocator, timeout_ms: i64) !?Push {
        const deadline = nowMs() + timeout_ms;
        while (true) {
            if (self.inbox.items.len > 0) {
                const f = self.inbox.orderedRemove(0);
                defer f.deinit(self.conn.allocator);
                if (try decode(allocator, f)) |p| return p;
                continue;
            }
            const remain = deadline - nowMs();
            const f = if (remain > 0) self.conn.recvFrameFor(remain) catch |e| switch (e) {
                error.Timeout => return null,
                else => return e,
            } else blk: {
                if (!self.conn.fillAvailable()) return error.Disconnected;
                break :blk (try self.conn.takeFrame()) orelse return null;
            };
            defer f.deinit(self.conn.allocator);
            if (try decode(allocator, f)) |p| return p;
        }
    }

    fn nextReq(self: *Peer) u32 {
        self.next_req +%= 1;
        if (self.next_req == 0) self.next_req = 1;
        return self.next_req;
    }

    fn awaitReply(self: *Peer, comptime T: type, allocator: std.mem.Allocator, want: wire.FrameType, req: u32, timeout_ms: i64) !std.json.Parsed(T) {
        const deadline = nowMs() + timeout_ms;
        while (true) {
            const remain = deadline - nowMs();
            if (remain <= 0) return error.Timeout;
            const f = try self.conn.recvFrameFor(remain);
            if (f.ftype == want) {
                defer f.deinit(self.conn.allocator);
                const parsed = try std.json.parseFromSlice(T, allocator, f.payload, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
                if (parsed.value.req == req) return parsed;
                // A `peer_list` with req 0 is a registration answer: a push.
                parsed.deinit();
                if (want != .peer_list) continue;
                const keep = OwnedFrame{ .ftype = f.ftype, .payload = try self.conn.allocator.dupe(u8, f.payload) };
                try self.inbox.append(self.conn.allocator, keep);
                continue;
            }
            if (isPush(f.ftype)) {
                self.inbox.append(self.conn.allocator, f) catch |e| {
                    f.deinit(self.conn.allocator);
                    return e;
                };
                continue;
            }
            defer f.deinit(self.conn.allocator);
            if (f.ftype == .err) return error.DaemonError;
        }
    }
};

fn isPush(ftype: wire.FrameType) bool {
    return ftype == .peer_deliver or ftype == .peer_event or ftype == .peer_list;
}

/// Decode a pushed frame; null for any frame that is not a peer push
/// (including a `peer_list` that answers a request rather than a registration).
pub fn decode(allocator: std.mem.Allocator, f: OwnedFrame) !?Push {
    const opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true, .allocate = .alloc_always };
    switch (f.ftype) {
        .peer_deliver => return .{ .deliver = try std.json.parseFromSlice(peermail.Deliver, allocator, f.payload, opts) },
        .peer_event => return .{ .event = try std.json.parseFromSlice(peermail.Event, allocator, f.payload, opts) },
        .peer_list => {
            const p = try std.json.parseFromSlice(peermail.ListReply, allocator, f.payload, opts);
            if (p.value.req == 0 and p.value.self != null) return .{ .registered = p };
            p.deinit();
            return null;
        },
        else => return null,
    }
}

test "pushes decode by frame type; a request's list answer is not a push" {
    const t = std.testing;
    const a = t.allocator;
    const d = try std.json.Stringify.valueAlloc(a, peermail.Deliver{ .id = "m-00000000", .from = .{ .address = "Zenit" }, .to = "Qq", .text = "hi", .queued = true }, .{});
    defer a.free(d);
    const p1 = (try decode(a, .{ .ftype = .peer_deliver, .payload = d })).?;
    defer p1.deinit();
    try t.expectEqualStrings("Zenit", p1.deliver.value.from.address);
    try t.expect(p1.deliver.value.queued);
    const e = try std.json.Stringify.valueAlloc(a, peermail.Event{ .id = "m-1", .reason = .not_durable_gone, .to = "anon-x" }, .{});
    defer a.free(e);
    const p2 = (try decode(a, .{ .ftype = .peer_event, .payload = e })).?;
    defer p2.deinit();
    try t.expectEqual(@as(?peermail.RefuseReason, .not_durable_gone), p2.event.value.reason);
    const reg = try std.json.Stringify.valueAlloc(a, peermail.ListReply{ .self = .{ .address = "Qq", .durable = true } }, .{});
    defer a.free(reg);
    const p3 = (try decode(a, .{ .ftype = .peer_list, .payload = reg })).?;
    defer p3.deinit();
    try t.expectEqualStrings("Qq", p3.registered.value.self.?.address);
    const ans = try std.json.Stringify.valueAlloc(a, peermail.ListReply{ .req = 4 }, .{});
    defer a.free(ans);
    try t.expect((try decode(a, .{ .ftype = .peer_list, .payload = ans })) == null);
    try t.expect((try decode(a, .{ .ftype = .welcome, .payload = ans })) == null);
}

test "nextPush 0 takes frames already buffered or arrived, then reports nothing" {
    const t = std.testing;
    const a = t.allocator;
    var pair: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), @import("../util/platform.zig").socketpairCloexec(&pair));
    var conn = Conn{ .allocator = a, .fd = pair[0], .proto = wire.PROTO_VERSION };
    defer conn.deinit();
    var broker = Conn{ .allocator = a, .fd = pair[1], .proto = wire.PROTO_VERSION };
    defer broker.deinit();
    var peer = Peer.init(&conn);
    defer peer.deinit();
    // 1. Two pushes on the socket, none read yet: both arrive with no wait.
    try broker.sendJson(.peer_deliver, peermail.Deliver{ .id = "m-00000001", .from = .{ .address = "Zenit" }, .to = "Qq", .text = "one" });
    try broker.sendJson(.peer_deliver, peermail.Deliver{ .id = "m-00000002", .from = .{ .address = "Zenit" }, .to = "Qq", .text = "two" });
    const p1 = (try peer.nextPush(a, 0)).?;
    defer p1.deinit();
    try t.expectEqualStrings("m-00000001", p1.deliver.value.id);
    // 2. The second is now buffered on the connection (read with the
    // first), not in the inbox and not on the socket: still taken.
    try t.expect(conn.rbuf.items.len > 0);
    const p2 = (try peer.nextPush(a, 0)).?;
    defer p2.deinit();
    try t.expectEqualStrings("m-00000002", p2.deliver.value.id);
    // 3. Nothing left: null at once, the connection still usable.
    try t.expect((try peer.nextPush(a, 0)) == null);
}
