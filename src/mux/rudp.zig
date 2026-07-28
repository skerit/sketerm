//! Encrypted reliable datagram channel for the mux UDP transport.
//!
//! Mosh-inspired (concepts from the published SSP design — no GPL
//! code): every datagram is sealed with ChaCha20-Poly1305 under a
//! key exchanged over the SSH bootstrap; the 64-bit crypto sequence
//! doubles as the nonce and feeds an anti-replay window; the peer
//! address is learned from the latest *authenticated* datagram,
//! which is what makes roaming (Wi-Fi → LTE, suspend/resume) free.
//!
//! On top of the sealed datagrams runs a small go-back-N stream:
//! 1200-byte segments, cumulative acks (piggybacked on data),
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
    rto_ms: i64 = RTO_MIN_MS,
    retransmit_at: i64 = 0,
    last_emit_at: i64 = 0,

    // Receiver side.
    recv_expected: u32 = 0,
    ack_pending: bool = false,

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
    }

    pub fn queuedBytes(self: *const Channel) usize {
        var total = self.backlog.items.len;
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
        while (self.backlog.items.len > 0 and self.inflight.items.len < WINDOW) {
            const take = @min(self.backlog.items.len, SEG_MAX);
            const data = try self.allocator.dupe(u8, self.backlog.items[0..take]);
            errdefer self.allocator.free(data);
            const remaining = self.backlog.items.len - take;
            std.mem.copyForwards(u8, self.backlog.items[0..remaining], self.backlog.items[take..]);
            self.backlog.shrinkRetainingCapacity(remaining);
            const seg = Segment{ .seq = self.next_seq, .data = data };
            self.next_seq +%= 1;
            try self.inflight.append(self.allocator, seg);
            self.emitSegment(seg, now_ms, emit, ctx);
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
            try self.pump(now_ms, emit, ctx);
        }

        switch (t) {
            TYPE_DATA => {
                const payload = inner[INNER_HDR..];
                if (seq == self.recv_expected) {
                    try deliver.appendSlice(self.allocator, payload);
                    self.recv_expected +%= 1;
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
