//! Encrypted reliable datagram channel for the mux UDP transport.
//!
//! Mosh-inspired (concepts from the published SSP design — no GPL
//! code): every datagram is sealed with ChaCha20-Poly1305 under a
//! key exchanged over the SSH bootstrap; the 64-bit crypto sequence
//! doubles as the nonce and feeds an anti-replay window; the peer
//! address is learned from the latest *authenticated* datagram,
//! which is what makes roaming (Wi-Fi → LTE, suspend/resume) free.
//!
//! On top of the sealed datagrams runs a small reliable stream:
//! 1200-byte segments, cumulative acks (piggybacked on data), a
//! receiver-side reorder buffer (a lost datagram holds back only
//! itself, not the window behind it), duplicate-ack fast retransmit,
//! timer-driven retransmission with exponential backoff, periodic
//! keepalives. Both mux peers speak the same byte-stream protocol
//! as over SSH — this layer only replaces the pipe.
//!
//! Pure state machine: time is injected, output datagrams go
//! through a callback — unit-tested with simulated loss, replay,
//! tampering, and clock control. No sockets in this file.

const std = @import("std");
const Aead = std.crypto.aead.chacha_poly.ChaCha20Poly1305;

pub const KEY_LEN = Aead.key_length; // 32
pub const TAG_LEN = Aead.tag_length; // 16
pub const HDR_LEN = 8; // outer u64 crypto seq
/// Inner header: type u8 + ack u32 + stream_seq u32.
pub const INNER_HDR = 9;
/// Stream payload per datagram. 1200 + overhead stays under every
/// sane path MTU (mosh uses ~1280 total for the same reason).
pub const SEG_MAX = 1200;
pub const MAX_DGRAM = HDR_LEN + INNER_HDR + SEG_MAX + TAG_LEN;

const TYPE_DATA: u8 = 1;
const TYPE_ACK: u8 = 2;
const TYPE_BYE: u8 = 3;

const RTO_MIN_MS: i64 = 80;
const RTO_MAX_MS: i64 = 1000;
const KEEPALIVE_MS: i64 = 3000;
/// In-flight segment cap; beyond it send() queues unsent.
const WINDOW: usize = 128;
/// Receiver-side out-of-order hold: segments up to this far ahead of
/// recv_expected are buffered instead of dropped, so one lost
/// datagram costs one retransmit, not the whole window behind it.
const REORDER_MAX: u32 = WINDOW;
/// Duplicate cumulative acks before the head segment is resent
/// without waiting for the RTO (TCP-style fast retransmit).
const DUP_ACK_FAST: u8 = 3;
/// Compact the backlog buffer once this many consumed bytes sit in
/// front of it (amortized O(1) drain instead of a memmove per seg).
const BACKLOG_COMPACT: usize = 1 << 20;

pub const EmitFn = *const fn (ctx: ?*anyopaque, datagram: []const u8) void;

const Segment = struct {
    seq: u32,
    data: []u8,
};

/// Standard sliding-window replay filter over the crypto sequence.
const ReplayWindow = struct {
    highest: u64 = 0,
    bitmap: u64 = 0,
    any: bool = false,

    /// Returns true exactly once per sequence number.
    fn checkAndSet(self: *ReplayWindow, seq: u64) bool {
        if (!self.any) {
            self.any = true;
            self.highest = seq;
            self.bitmap = 1;
            return true;
        }
        if (seq > self.highest) {
            const shift = seq - self.highest;
            self.bitmap = if (shift >= 64) 1 else (self.bitmap << @intCast(shift)) | 1;
            self.highest = seq;
            return true;
        }
        const back = self.highest - seq;
        if (back >= 64) return false;
        const bit = @as(u64, 1) << @intCast(back);
        if (self.bitmap & bit != 0) return false;
        self.bitmap |= bit;
        return true;
    }
};

pub const Channel = struct {
    allocator: std.mem.Allocator,
    key: [KEY_LEN]u8,
    /// Nonce direction bytes — must differ between the two peers so
    /// the same key never reuses a nonce. Client uses 0, server 1.
    dir_send: u8,

    crypto_seq: u64 = 0,
    replay: ReplayWindow = .{},

    // Sender side (go-back-N).
    next_seq: u32 = 0,
    inflight: std.ArrayList(Segment) = .empty,
    /// Bytes accepted by send() but not yet segmented into the
    /// window (window full). Drained by poll().
    backlog: std.ArrayList(u8) = .empty,
    /// Consumed prefix of `backlog`; compacted lazily.
    backlog_off: usize = 0,
    rto_ms: i64 = RTO_MIN_MS,
    retransmit_at: i64 = 0,
    last_emit_at: i64 = 0,
    /// Fast-retransmit state: last cumulative ack seen + how many
    /// times it repeated without progress.
    last_ack: u32 = 0,
    dup_acks: u8 = 0,

    // Receiver side.
    recv_expected: u32 = 0,
    ack_pending: bool = false,
    /// Out-of-order segments held until the gap fills, sorted by
    /// distance from recv_expected. Bounded by REORDER_MAX.
    reorder: std.ArrayList(Segment) = .empty,

    /// Peer said bye / fatal — no further traffic.
    closed: bool = false,

    /// Set by onDatagram when the LAST fed datagram authenticated.
    /// The transport reads this to learn/update the peer address
    /// (roaming): only packets that prove key possession may move
    /// where we send replies.
    last_rx_authenticated: bool = false,

    pub fn init(allocator: std.mem.Allocator, key: [KEY_LEN]u8, is_client: bool) Channel {
        return .{
            .allocator = allocator,
            .key = key,
            .dir_send = if (is_client) 0 else 1,
        };
    }

    pub fn deinit(self: *Channel) void {
        for (self.inflight.items) |s| self.allocator.free(s.data);
        self.inflight.deinit(self.allocator);
        self.backlog.deinit(self.allocator);
        for (self.reorder.items) |s| self.allocator.free(s.data);
        self.reorder.deinit(self.allocator);
    }

    pub fn queuedBytes(self: *const Channel) usize {
        var total = self.backlog.items.len - self.backlog_off;
        for (self.inflight.items) |segment| total += segment.data.len;
        return total;
    }

    fn seal(self: *Channel, inner: []const u8, out: []u8) []const u8 {
        self.crypto_seq += 1;
        const seq = self.crypto_seq;
        std.mem.writeInt(u64, out[0..8], seq, .little);
        var nonce: [Aead.nonce_length]u8 = @splat(0);
        nonce[0] = self.dir_send;
        std.mem.writeInt(u64, nonce[1..9], seq, .little);
        const ct = out[HDR_LEN .. HDR_LEN + inner.len];
        const tag = out[HDR_LEN + inner.len .. HDR_LEN + inner.len + TAG_LEN];
        Aead.encrypt(ct, tag[0..TAG_LEN], inner, out[0..8], nonce, self.key);
        return out[0 .. HDR_LEN + inner.len + TAG_LEN];
    }

    /// Decrypt + authenticate + replay-check. Returns the inner
    /// plaintext (written into `scratch`) or null for any invalid
    /// datagram (tampered, replayed, garbage — all silently dropped,
    /// exactly like mosh: an attacker learns nothing).
    pub fn open(self: *Channel, dgram: []const u8, scratch: []u8) ?[]const u8 {
        if (dgram.len < HDR_LEN + TAG_LEN or dgram.len > MAX_DGRAM) return null;
        const seq = std.mem.readInt(u64, dgram[0..8], .little);
        const inner_len = dgram.len - HDR_LEN - TAG_LEN;
        var nonce: [Aead.nonce_length]u8 = @splat(0);
        nonce[0] = 1 - self.dir_send; // peer's direction
        std.mem.writeInt(u64, nonce[1..9], seq, .little);
        const ct = dgram[HDR_LEN .. HDR_LEN + inner_len];
        const tag = dgram[HDR_LEN + inner_len ..][0..TAG_LEN];
        Aead.decrypt(scratch[0..inner_len], ct, tag.*, dgram[0..8], nonce, self.key) catch return null;
        // Replay window only AFTER authentication (unauthenticated
        // seqs must not be able to poison the window).
        if (!self.replay.checkAndSet(seq)) return null;
        return scratch[0..inner_len];
    }

    /// Queue stream bytes for transmission. Segments are emitted
    /// immediately while the window has room; the rest goes to the
    /// backlog and drains on acks.
    pub fn send(self: *Channel, bytes: []const u8, now_ms: i64, emit: EmitFn, ctx: ?*anyopaque) !void {
        if (self.closed) return;
        try self.backlog.appendSlice(self.allocator, bytes);
        try self.pump(now_ms, emit, ctx);
    }

    fn pump(self: *Channel, now_ms: i64, emit: EmitFn, ctx: ?*anyopaque) !void {
        while (self.backlog.items.len > self.backlog_off and self.inflight.items.len < WINDOW) {
            const avail = self.backlog.items.len - self.backlog_off;
            const take = @min(avail, SEG_MAX);
            const data = try self.allocator.dupe(u8, self.backlog.items[self.backlog_off..][0..take]);
            errdefer self.allocator.free(data);
            self.backlog_off += take;
            const seg = Segment{ .seq = self.next_seq, .data = data };
            self.next_seq +%= 1;
            try self.inflight.append(self.allocator, seg);
            self.emitSegment(seg, now_ms, emit, ctx);
        }
        if (self.backlog_off == self.backlog.items.len) {
            self.backlog.clearRetainingCapacity();
            self.backlog_off = 0;
        } else if (self.backlog_off >= BACKLOG_COMPACT) {
            const remaining = self.backlog.items.len - self.backlog_off;
            std.mem.copyForwards(u8, self.backlog.items[0..remaining], self.backlog.items[self.backlog_off..]);
            self.backlog.shrinkRetainingCapacity(remaining);
            self.backlog_off = 0;
        }
        if (self.inflight.items.len > 0 and self.retransmit_at == 0) {
            self.retransmit_at = now_ms + self.rto_ms;
        }
    }

    fn emitSegment(self: *Channel, seg: Segment, now_ms: i64, emit: EmitFn, ctx: ?*anyopaque) void {
        var inner_buf: [INNER_HDR + SEG_MAX]u8 = undefined;
        inner_buf[0] = TYPE_DATA;
        std.mem.writeInt(u32, inner_buf[1..5], self.recv_expected, .little);
        std.mem.writeInt(u32, inner_buf[5..9], seg.seq, .little);
        @memcpy(inner_buf[INNER_HDR .. INNER_HDR + seg.data.len], seg.data);
        var out: [MAX_DGRAM]u8 = undefined;
        const dgram = self.seal(inner_buf[0 .. INNER_HDR + seg.data.len], &out);
        self.ack_pending = false; // piggybacked
        self.last_emit_at = now_ms;
        emit(ctx, dgram);
    }

    fn emitControl(self: *Channel, t: u8, now_ms: i64, emit: EmitFn, ctx: ?*anyopaque) void {
        var inner_buf: [INNER_HDR]u8 = undefined;
        inner_buf[0] = t;
        std.mem.writeInt(u32, inner_buf[1..5], self.recv_expected, .little);
        std.mem.writeInt(u32, inner_buf[5..9], 0, .little);
        var out: [MAX_DGRAM]u8 = undefined;
        const dgram = self.seal(&inner_buf, &out);
        self.ack_pending = false;
        self.last_emit_at = now_ms;
        emit(ctx, dgram);
    }

    pub fn sendBye(self: *Channel, now_ms: i64, emit: EmitFn, ctx: ?*anyopaque) void {
        self.emitControl(TYPE_BYE, now_ms, emit, ctx);
        self.closed = true;
    }

    /// Feed one received datagram. In-order stream payload is
    /// appended to `deliver`. Returns false when the peer said bye.
    pub fn onDatagram(
        self: *Channel,
        dgram: []const u8,
        now_ms: i64,
        deliver: *std.ArrayList(u8),
        emit: EmitFn,
        ctx: ?*anyopaque,
    ) !bool {
        var scratch: [MAX_DGRAM]u8 = undefined;
        self.last_rx_authenticated = false;
        const inner = self.open(dgram, &scratch) orelse return true;
        self.last_rx_authenticated = true;
        if (inner.len < INNER_HDR) return true;
        const t = inner[0];
        const ack = std.mem.readInt(u32, inner[1..5], .little);
        const seq = std.mem.readInt(u32, inner[5..9], .little);

        // Cumulative ack: drop fully-acked in-flight segments.
        var progressed = false;
        while (self.inflight.items.len > 0) {
            const head = self.inflight.items[0];
            // Window ≤ 128 so wraparound-safe distance comparison.
            const dist = ack -% head.seq;
            if (dist == 0 or dist > WINDOW * 2) break;
            self.allocator.free(head.data);
            _ = self.inflight.orderedRemove(0);
            progressed = true;
        }
        if (progressed) {
            self.rto_ms = RTO_MIN_MS;
            self.retransmit_at = if (self.inflight.items.len > 0) now_ms + self.rto_ms else 0;
            self.last_ack = ack;
            self.dup_acks = 0;
            try self.pump(now_ms, emit, ctx);
        } else if (self.inflight.items.len > 0 and ack == self.last_ack) {
            // The peer keeps acking below our head: it is alive and
            // missing exactly the head segment. Resend it now rather
            // than after a full RTO (the receiver's reorder buffer
            // turns this one datagram into a whole-window ack jump).
            self.dup_acks +|= 1;
            if (self.dup_acks >= DUP_ACK_FAST) {
                self.dup_acks = 0;
                self.emitSegment(self.inflight.items[0], now_ms, emit, ctx);
                self.retransmit_at = now_ms + self.rto_ms;
            }
        } else {
            self.last_ack = ack;
            self.dup_acks = 0;
        }

        switch (t) {
            TYPE_DATA => {
                const payload = inner[INNER_HDR..];
                if (seq == self.recv_expected) {
                    try deliver.appendSlice(self.allocator, payload);
                    self.recv_expected +%= 1;
                    try self.drainReorder(deliver);
                } else {
                    try self.holdReorder(seq, payload);
                }
                // Dup or gap: (re-)ack so the sender converges.
                self.ack_pending = true;
            },
            TYPE_BYE => {
                self.closed = true;
                return false;
            },
            else => {},
        }
        return true;
    }

    /// Buffer an out-of-order segment (ahead of recv_expected) so a
    /// single head retransmit later releases the whole run. Old
    /// duplicates and segments past the hold window are dropped.
    fn holdReorder(self: *Channel, seq: u32, payload: []const u8) !void {
        const dist = seq -% self.recv_expected;
        if (dist == 0 or dist >= REORDER_MAX) return;
        var insert_at: usize = self.reorder.items.len;
        for (self.reorder.items, 0..) |held, i| {
            const held_dist = held.seq -% self.recv_expected;
            if (held_dist == dist) return; // duplicate
            if (held_dist > dist) {
                insert_at = i;
                break;
            }
        }
        const copy = try self.allocator.dupe(u8, payload);
        errdefer self.allocator.free(copy);
        try self.reorder.insert(self.allocator, insert_at, .{ .seq = seq, .data = copy });
    }

    /// Deliver every buffered segment that is now in order.
    fn drainReorder(self: *Channel, deliver: *std.ArrayList(u8)) !void {
        while (self.reorder.items.len > 0) {
            const head = self.reorder.items[0];
            if (head.seq != self.recv_expected) break;
            try deliver.appendSlice(self.allocator, head.data);
            self.allocator.free(head.data);
            _ = self.reorder.orderedRemove(0);
            self.recv_expected +%= 1;
        }
    }

    /// Timer driver: retransmit on RTO, flush pending acks, emit
    /// keepalives. Returns the next deadline (ms) the caller should
    /// poll() with, or null for "nothing scheduled" (use keepalive).
    pub fn tick(self: *Channel, now_ms: i64, emit: EmitFn, ctx: ?*anyopaque) ?i64 {
        if (self.closed) return null;
        if (self.inflight.items.len > 0 and self.retransmit_at != 0 and now_ms >= self.retransmit_at) {
            // Go-back-N: resend the whole window (bounded burst).
            const burst = @min(self.inflight.items.len, 8);
            for (self.inflight.items[0..burst]) |seg| self.emitSegment(seg, now_ms, emit, ctx);
            self.rto_ms = @min(self.rto_ms * 2, RTO_MAX_MS);
            self.retransmit_at = now_ms + self.rto_ms;
        }
        if (self.ack_pending) self.emitControl(TYPE_ACK, now_ms, emit, ctx);
        if (now_ms - self.last_emit_at >= KEEPALIVE_MS) self.emitControl(TYPE_ACK, now_ms, emit, ctx);

        var deadline: i64 = self.last_emit_at + KEEPALIVE_MS;
        if (self.inflight.items.len > 0 and self.retransmit_at != 0) {
            deadline = @min(deadline, self.retransmit_at);
        }
        return deadline;
    }
};

pub fn keyToHex(key: [KEY_LEN]u8, out: *[KEY_LEN * 2]u8) []const u8 {
    const hex = "0123456789abcdef";
    for (key, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0xF];
    }
    return out[0 .. KEY_LEN * 2];
}

pub fn keyFromHex(s: []const u8) ?[KEY_LEN]u8 {
    if (s.len != KEY_LEN * 2) return null;
    var key: [KEY_LEN]u8 = undefined;
    for (0..KEY_LEN) |i| {
        key[i] = std.fmt.parseInt(u8, s[i * 2 .. i * 2 + 2], 16) catch return null;
    }
    return key;
}

/// A parsed "SKETERM-UDP <port> <keyhex>" bootstrap announcement.
/// `keyhex` points into the caller's line.
pub const Announce = struct { port: u16, keyhex: []const u8 };

/// Parse the --udp-listen announcement line (shared by the ssh
/// bootstrap client and the daemon's ticket broker).
pub fn parseAnnounce(line: []const u8) ?Announce {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const tag = it.next() orelse return null;
    if (!std.mem.eql(u8, tag, "SKETERM-UDP")) return null;
    const port_s = it.next() orelse return null;
    const keyhex = it.next() orelse return null;
    if (it.next() != null) return null;
    const port = std.fmt.parseInt(u16, port_s, 10) catch return null;
    if (port == 0 or keyFromHex(keyhex) == null) return null;
    return .{ .port = port, .keyhex = keyhex };
}

// ── tests ───────────────────────────────────────────────────────

const TestNet = struct {
    /// Queued datagrams per direction.
    to_b: std.ArrayList([]u8) = .empty,
    to_a: std.ArrayList([]u8) = .empty,
    allocator: std.mem.Allocator,
    /// Deterministic PRNG for loss simulation.
    prng: std.Random.DefaultPrng,
    loss_pct: u8 = 0,

    fn emitToB(ctx: ?*anyopaque, d: []const u8) void {
        const self: *TestNet = @ptrCast(@alignCast(ctx.?));
        if (self.prng.random().intRangeAtMost(u8, 0, 99) < self.loss_pct) return;
        const copy = self.allocator.dupe(u8, d) catch return;
        self.to_b.append(self.allocator, copy) catch {};
    }

    fn emitToA(ctx: ?*anyopaque, d: []const u8) void {
        const self: *TestNet = @ptrCast(@alignCast(ctx.?));
        if (self.prng.random().intRangeAtMost(u8, 0, 99) < self.loss_pct) return;
        const copy = self.allocator.dupe(u8, d) catch return;
        self.to_a.append(self.allocator, copy) catch {};
    }

    fn deinit(self: *TestNet) void {
        for (self.to_a.items) |d| self.allocator.free(d);
        for (self.to_b.items) |d| self.allocator.free(d);
        self.to_a.deinit(self.allocator);
        self.to_b.deinit(self.allocator);
    }
};

test "rudp: bulk transfer survives 30% loss, in order" {
    const a = std.testing.allocator;
    var key: [KEY_LEN]u8 = undefined;
    for (&key, 0..) |*b, i| b.* = @truncate(i * 7 + 3);

    var net = TestNet{ .allocator = a, .prng = std.Random.DefaultPrng.init(42), .loss_pct = 30 };
    defer net.deinit();
    var ca = Channel.init(a, key, true);
    defer ca.deinit();
    var cb = Channel.init(a, key, false);
    defer cb.deinit();

    // 64 KB deterministic payload.
    var payload: [65536]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(7);
    prng.random().bytes(&payload);

    var received: std.ArrayList(u8) = .empty;
    defer received.deinit(a);

    var now: i64 = 0;
    try ca.send(&payload, now, TestNet.emitToB, @ptrCast(&net));

    var rounds: u32 = 0;
    while (received.items.len < payload.len and rounds < 20000) : (rounds += 1) {
        now += 17;
        // Drain network both ways.
        while (net.to_b.items.len > 0) {
            const d = net.to_b.orderedRemove(0);
            defer a.free(d);
            _ = try cb.onDatagram(d, now, &received, TestNet.emitToA, @ptrCast(&net));
        }
        var sink_a: std.ArrayList(u8) = .empty;
        defer sink_a.deinit(a);
        while (net.to_a.items.len > 0) {
            const d = net.to_a.orderedRemove(0);
            defer a.free(d);
            _ = try ca.onDatagram(d, now, &sink_a, TestNet.emitToB, @ptrCast(&net));
        }
        _ = ca.tick(now, TestNet.emitToB, @ptrCast(&net));
        _ = cb.tick(now, TestNet.emitToA, @ptrCast(&net));
    }

    try std.testing.expectEqual(payload.len, received.items.len);
    try std.testing.expectEqualSlices(u8, &payload, received.items);
}

test "rudp: replayed and tampered datagrams are rejected" {
    const a = std.testing.allocator;
    const key: [KEY_LEN]u8 = @splat(9);
    var net = TestNet{ .allocator = a, .prng = std.Random.DefaultPrng.init(1) };
    defer net.deinit();
    var ca = Channel.init(a, key, true);
    defer ca.deinit();
    var cb = Channel.init(a, key, false);
    defer cb.deinit();

    var received: std.ArrayList(u8) = .empty;
    defer received.deinit(a);

    try ca.send("hello", 0, TestNet.emitToB, @ptrCast(&net));
    try std.testing.expectEqual(@as(usize, 1), net.to_b.items.len);
    const dgram = net.to_b.items[0];

    // First delivery works.
    _ = try cb.onDatagram(dgram, 0, &received, TestNet.emitToA, @ptrCast(&net));
    try std.testing.expectEqualStrings("hello", received.items);

    // Replay: dropped (nothing delivered twice).
    _ = try cb.onDatagram(dgram, 0, &received, TestNet.emitToA, @ptrCast(&net));
    try std.testing.expectEqualStrings("hello", received.items);

    // Tamper: flip a ciphertext byte of a fresh datagram.
    try ca.send("world", 0, TestNet.emitToB, @ptrCast(&net));
    const d2 = net.to_b.items[net.to_b.items.len - 1];
    d2[HDR_LEN] ^= 0x40;
    _ = try cb.onDatagram(d2, 0, &received, TestNet.emitToA, @ptrCast(&net));
    try std.testing.expectEqualStrings("hello", received.items);

    // Wrong key: a third party can't even produce a valid packet.
    const key2: [KEY_LEN]u8 = @splat(8);
    var cx = Channel.init(a, key2, true);
    defer cx.deinit();
    try cx.send("evil", 0, TestNet.emitToB, @ptrCast(&net));
    const d3 = net.to_b.items[net.to_b.items.len - 1];
    _ = try cb.onDatagram(d3, 0, &received, TestNet.emitToA, @ptrCast(&net));
    try std.testing.expectEqualStrings("hello", received.items);
}

test "rudp: retransmission recovers a fully-dropped window" {
    const a = std.testing.allocator;
    const key: [KEY_LEN]u8 = @splat(3);
    var net = TestNet{ .allocator = a, .prng = std.Random.DefaultPrng.init(2), .loss_pct = 100 };
    defer net.deinit();
    var ca = Channel.init(a, key, true);
    defer ca.deinit();
    var cb = Channel.init(a, key, false);
    defer cb.deinit();

    var received: std.ArrayList(u8) = .empty;
    defer received.deinit(a);

    try ca.send("important", 0, TestNet.emitToB, @ptrCast(&net));
    try std.testing.expectEqual(@as(usize, 0), net.to_b.items.len); // eaten

    // Heal the network; RTO fires; data arrives.
    net.loss_pct = 0;
    var now: i64 = 0;
    var rounds: u32 = 0;
    while (received.items.len == 0 and rounds < 100) : (rounds += 1) {
        now += 50;
        _ = ca.tick(now, TestNet.emitToB, @ptrCast(&net));
        while (net.to_b.items.len > 0) {
            const d = net.to_b.orderedRemove(0);
            defer a.free(d);
            _ = try cb.onDatagram(d, now, &received, TestNet.emitToA, @ptrCast(&net));
        }
    }
    try std.testing.expectEqualStrings("important", received.items);
}

test "rudp: reorder buffer releases the run behind one lost segment" {
    const a = std.testing.allocator;
    const key: [KEY_LEN]u8 = @splat(5);
    var net = TestNet{ .allocator = a, .prng = std.Random.DefaultPrng.init(3) };
    defer net.deinit();
    var ca = Channel.init(a, key, true);
    defer ca.deinit();
    var cb = Channel.init(a, key, false);
    defer cb.deinit();

    var received: std.ArrayList(u8) = .empty;
    defer received.deinit(a);

    // Ten full segments in one send.
    const payload = try a.alloc(u8, SEG_MAX * 10);
    defer a.free(payload);
    var prng = std.Random.DefaultPrng.init(11);
    prng.random().bytes(payload);
    try ca.send(payload, 0, TestNet.emitToB, @ptrCast(&net));
    try std.testing.expectEqual(@as(usize, 10), net.to_b.items.len);

    // Drop segment 0; deliver 1..9 out of order — nothing reaches the
    // stream yet, but everything is buffered.
    a.free(net.to_b.orderedRemove(0));
    while (net.to_b.items.len > 0) {
        const d = net.to_b.orderedRemove(0);
        defer a.free(d);
        _ = try cb.onDatagram(d, 0, &received, TestNet.emitToA, @ptrCast(&net));
    }
    try std.testing.expectEqual(@as(usize, 0), received.items.len);
    try std.testing.expectEqual(@as(usize, 9), cb.reorder.items.len);

    // The receiver's duplicate acks trigger a fast retransmit of the
    // head — one datagram releases the whole run.
    while (net.to_a.items.len > 0) {
        const d = net.to_a.orderedRemove(0);
        defer a.free(d);
        var sink: std.ArrayList(u8) = .empty;
        defer sink.deinit(a);
        _ = try ca.onDatagram(d, 0, &sink, TestNet.emitToB, @ptrCast(&net));
    }
    _ = ca.tick(1000, TestNet.emitToB, @ptrCast(&net)); // RTO backstop if dup-acks were < 3
    try std.testing.expect(net.to_b.items.len >= 1);
    while (net.to_b.items.len > 0) {
        const d = net.to_b.orderedRemove(0);
        defer a.free(d);
        _ = try cb.onDatagram(d, 1000, &received, TestNet.emitToA, @ptrCast(&net));
    }
    try std.testing.expectEqualSlices(u8, payload, received.items);
    try std.testing.expectEqual(@as(usize, 0), cb.reorder.items.len);
}

test "rudp: duplicate acks fast-retransmit the head before the RTO" {
    const a = std.testing.allocator;
    const key: [KEY_LEN]u8 = @splat(6);
    var net = TestNet{ .allocator = a, .prng = std.Random.DefaultPrng.init(4) };
    defer net.deinit();
    var ca = Channel.init(a, key, true);
    defer ca.deinit();
    var cb = Channel.init(a, key, false);
    defer cb.deinit();

    var received: std.ArrayList(u8) = .empty;
    defer received.deinit(a);

    const payload = try a.alloc(u8, SEG_MAX * 5);
    defer a.free(payload);
    @memset(payload, 0xab);
    try ca.send(payload, 0, TestNet.emitToB, @ptrCast(&net));
    a.free(net.to_b.orderedRemove(0)); // lose the head

    // Receiver acks each stray segment at the same cumulative value.
    while (net.to_b.items.len > 0) {
        const d = net.to_b.orderedRemove(0);
        defer a.free(d);
        _ = try cb.onDatagram(d, 0, &received, TestNet.emitToA, @ptrCast(&net));
        _ = cb.tick(0, TestNet.emitToA, @ptrCast(&net));
    }
    // Feed those duplicate acks to the sender WITHOUT advancing time:
    // the head must be resent by dup-ack logic alone.
    while (net.to_a.items.len > 0) {
        const d = net.to_a.orderedRemove(0);
        defer a.free(d);
        var sink: std.ArrayList(u8) = .empty;
        defer sink.deinit(a);
        _ = try ca.onDatagram(d, 0, &sink, TestNet.emitToB, @ptrCast(&net));
    }
    try std.testing.expect(net.to_b.items.len >= 1); // fast retransmit fired at t=0
    while (net.to_b.items.len > 0) {
        const d = net.to_b.orderedRemove(0);
        defer a.free(d);
        _ = try cb.onDatagram(d, 0, &received, TestNet.emitToA, @ptrCast(&net));
    }
    try std.testing.expectEqualSlices(u8, payload, received.items);
}

test "rudp: key hex round-trip" {
    var key: [KEY_LEN]u8 = undefined;
    for (&key, 0..) |*b, i| b.* = @truncate(i);
    var hexbuf: [KEY_LEN * 2]u8 = undefined;
    const hex = keyToHex(key, &hexbuf);
    try std.testing.expectEqual(key, keyFromHex(hex).?);
    try std.testing.expectEqual(@as(?[KEY_LEN]u8, null), keyFromHex("short"));
}

test "rudp: queuedBytes includes the window and unsent backlog" {
    const a = std.testing.allocator;
    const key: [KEY_LEN]u8 = @splat(4);
    var channel = Channel.init(a, key, true);
    defer channel.deinit();
    const bytes = try a.alloc(u8, SEG_MAX * (WINDOW + 2));
    defer a.free(bytes);
    @memset(bytes, 0x5a);
    const Drop = struct {
        fn emit(_: ?*anyopaque, _: []const u8) void {}
    };
    try channel.send(bytes, 0, Drop.emit, null);
    try std.testing.expectEqual(bytes.len, channel.queuedBytes());
    try std.testing.expect(channel.backlog.items.len > 0);
}

test "rudp: announce line parses and rejects malformed variants" {
    var key: [KEY_LEN]u8 = @splat(7);
    var hexbuf: [KEY_LEN * 2]u8 = undefined;
    const hex = keyToHex(key, &hexbuf);
    var line_buf: [128]u8 = undefined;
    const line = try std.fmt.bufPrint(&line_buf, "SKETERM-UDP 61234 {s}", .{hex});
    const a = parseAnnounce(line) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 61234), a.port);
    try std.testing.expectEqualStrings(hex, a.keyhex);
    try std.testing.expectEqual(@as(?Announce, null), parseAnnounce("SKETERM-PUNCH 1234"));
    try std.testing.expectEqual(@as(?Announce, null), parseAnnounce("SKETERM-UDP 0 deadbeef"));
    try std.testing.expectEqual(@as(?Announce, null), parseAnnounce("SKETERM-UDP 99999 deadbeef"));
    const bad = try std.fmt.bufPrint(&line_buf, "SKETERM-UDP 1 {s} extra", .{hex});
    try std.testing.expectEqual(@as(?Announce, null), parseAnnounce(bad));
    key[0] = 0;
}
