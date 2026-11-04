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

/// Retransmit timeout bounds. The timeout itself is adaptive (RFC 6298:
/// SRTT + 4*RTTVAR over samples of segments never retransmitted); the
/// old fixed 80ms timer read every ordinary delay spike on a VPN or
/// Wi-Fi path as loss and collapsed the congestion window.
const RTO_MIN_MS: i64 = 100;
const RTO_INIT_MS: i64 = 500;
const RTO_MAX_MS: i64 = 2000;
/// Clock granularity floor for the variance term (RFC 6298's G).
const RTO_GRANULARITY_US: i64 = 10_000;
const KEEPALIVE_MS: i64 = 3000;
/// In-flight segment cap (~4.9 MB). 128 segments capped throughput at
/// ~150 KB per round trip, i.e. well under 1 MB/s on a 200ms path.
const WINDOW: usize = 4096;
/// Receiver-side out-of-order hold: segments up to this far ahead of
/// recv_expected are buffered instead of dropped, so one lost
/// datagram costs one retransmit, not the whole window behind it.
const REORDER_MAX: u32 = WINDOW;
/// Duplicate pure acks before the head segment is resent without
/// waiting for the RTO (TCP-style fast retransmit).
const DUP_ACK_FAST: u8 = 3;
/// Compact the backlog buffer once this many consumed bytes sit in
/// front of it (amortized O(1) drain instead of a memmove per seg).
const BACKLOG_COMPACT: usize = 1 << 20;
/// Same for the acked prefix of the in-flight list, in segments.
const INFLIGHT_COMPACT: usize = 256;
/// Congestion window bounds (segments): slow start up to ssthresh,
/// then additive increase; halve on fast retransmit, floor on RTO.
/// Blasting the full window back-to-back induced loss on tunneled
/// paths, which is why the start is small.
const CWND_MIN: usize = 4;
const CWND_START: usize = 16;

pub const EmitFn = *const fn (ctx: ?*anyopaque, datagram: []const u8) void;

const Segment = struct {
    seq: u32,
    data: []u8,
    sent_at: i64 = 0,
    /// Karn's rule: an ack covering a resent segment is no RTT sample.
    retx: bool = false,
};

/// Wrap-safe `a >= b` over stream sequence numbers.
fn seqAtOrAfter(a: u32, b: u32) bool {
    return a -% b < (1 << 31);
}

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

    // Sender side.
    next_seq: u32 = 0,
    /// Unacked segments from `inflight_head` on; the acked prefix is
    /// compacted lazily (an ordered remove per ack is O(window)).
    inflight: std.ArrayList(Segment) = .empty,
    inflight_head: usize = 0,
    /// Bytes accepted by send() but not yet segmented into the
    /// window (window full). Drained by poll().
    backlog: std.ArrayList(u8) = .empty,
    /// Consumed prefix of `backlog`; compacted lazily.
    backlog_off: usize = 0,
    rto_ms: i64 = RTO_INIT_MS,
    retransmit_at: i64 = 0,
    /// RTT estimator state in microseconds; meaningless until has_rtt.
    srtt_us: i64 = 0,
    rttvar_us: i64 = 0,
    has_rtt: bool = false,
    last_emit_at: i64 = 0,
    /// Fast-retransmit state: last cumulative ack seen + how many
    /// pure acks repeated it without progress.
    last_ack: u32 = 0,
    dup_acks: u8 = 0,
    /// Congestion window: how much of WINDOW may actually be in
    /// flight right now.
    cwnd: usize = CWND_START,
    ssthresh: usize = WINDOW,
    /// Acked segments not yet worth a whole congestion-avoidance step.
    cwnd_credit: usize = 0,
    /// Loss recovery, entered on fast retransmit or RTO and left once
    /// the cumulative ack reaches `recover` (the next_seq at entry).
    in_recovery: bool = false,
    recover: u32 = 0,
    /// Fast recovery: segments before this seq were already resent in
    /// this episode, so repeated hole reports do not resend them again.
    rtx_high: u32 = 0,
    /// After an RTO the whole flight is resent go-back-N, paced by
    /// cwnd; `rtx_next` is the flight index of the next one to resend.
    go_back_n: bool = false,
    rtx_next: usize = 0,

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
        for (self.flight()) |s| self.allocator.free(s.data);
        self.inflight.deinit(self.allocator);
        self.backlog.deinit(self.allocator);
        for (self.reorder.items) |s| self.allocator.free(s.data);
        self.reorder.deinit(self.allocator);
    }

    /// The unacked segments, oldest first.
    fn flight(self: *const Channel) []Segment {
        return self.inflight.items[self.inflight_head..];
    }

    pub fn queuedBytes(self: *const Channel) usize {
        var total = self.backlog.items.len - self.backlog_off;
        for (self.flight()) |segment| total += segment.data.len;
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
        self.pumpRetransmits(now_ms, emit, ctx);
        const limit = @min(self.cwnd, WINDOW);
        while (!self.go_back_n and self.backlog.items.len > self.backlog_off and self.flight().len < limit) {
            const avail = self.backlog.items.len - self.backlog_off;
            const take = @min(avail, SEG_MAX);
            const data = try self.allocator.dupe(u8, self.backlog.items[self.backlog_off..][0..take]);
            errdefer self.allocator.free(data);
            const seg = Segment{ .seq = self.next_seq, .data = data, .sent_at = now_ms };
            try self.inflight.append(self.allocator, seg);
            self.backlog_off += take;
            self.next_seq +%= 1;
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
        if (self.flight().len > 0 and self.retransmit_at == 0) {
            self.retransmit_at = now_ms + self.rto_ms;
        }
    }

    /// Go-back-N after an RTO: resend the flight in order while the
    /// resent-but-unacked count (`rtx_next`) is below cwnd.
    fn pumpRetransmits(self: *Channel, now_ms: i64, emit: EmitFn, ctx: ?*anyopaque) void {
        if (!self.go_back_n) return;
        const f = self.flight();
        while (self.rtx_next < f.len and self.rtx_next < self.cwnd) : (self.rtx_next += 1) {
            self.resend(&f[self.rtx_next], now_ms, emit, ctx);
        }
        if (self.rtx_next >= f.len) self.go_back_n = false;
    }

    fn resend(self: *Channel, seg: *Segment, now_ms: i64, emit: EmitFn, ctx: ?*anyopaque) void {
        seg.retx = true;
        seg.sent_at = now_ms;
        self.emitSegment(seg.*, now_ms, emit, ctx);
    }

    /// Fast recovery: resend the first `hole` flight segments (the
    /// receiver's reported gap, or just the head when it reports none)
    /// that this episode has not resent yet.
    fn repairHole(self: *Channel, hole: u32, now_ms: i64, emit: EmitFn, ctx: ?*anyopaque) void {
        const f = self.flight();
        if (f.len == 0) return;
        const head = f[0].seq;
        const from: usize = if (seqAtOrAfter(self.rtx_high, head)) @min(self.rtx_high -% head, f.len) else 0;
        const to: usize = @min(@max(hole, 1), f.len);
        if (from >= to) return;
        for (f[from..to]) |*seg| self.resend(seg, now_ms, emit, ctx);
        self.rtx_high = head +% @as(u32, @intCast(to));
    }

    fn sampleRtt(self: *Channel, rtt_ms: i64) void {
        const r = @max(rtt_ms, 0) * 1000;
        if (!self.has_rtt) {
            self.has_rtt = true;
            self.srtt_us = r;
            self.rttvar_us = @divTrunc(r, 2);
            return;
        }
        const err: i64 = @intCast(@abs(self.srtt_us - r));
        self.rttvar_us = @divTrunc(3 * self.rttvar_us + err, 4);
        self.srtt_us = @divTrunc(7 * self.srtt_us + r, 8);
    }

    fn computedRto(self: *const Channel) i64 {
        if (!self.has_rtt) return RTO_INIT_MS;
        const rto_us = self.srtt_us + @max(4 * self.rttvar_us, RTO_GRANULARITY_US);
        return std.math.clamp(@divTrunc(rto_us + 999, 1000), RTO_MIN_MS, RTO_MAX_MS);
    }

    fn growCwnd(self: *Channel, acked: usize) void {
        if (self.cwnd < self.ssthresh) {
            self.cwnd = @min(self.cwnd + acked, WINDOW);
            return;
        }
        self.cwnd_credit += acked;
        if (self.cwnd_credit >= self.cwnd) {
            self.cwnd_credit -= self.cwnd;
            self.cwnd = @min(self.cwnd + 1, WINDOW);
        }
    }

    fn compactInflight(self: *Channel) void {
        const h = self.inflight_head;
        const len = self.inflight.items.len;
        if (h == len) {
            self.inflight.clearRetainingCapacity();
            self.inflight_head = 0;
            return;
        }
        if (h < INFLIGHT_COMPACT and h * 2 < len) return;
        std.mem.copyForwards(Segment, self.inflight.items[0 .. len - h], self.inflight.items[h..]);
        self.inflight.shrinkRetainingCapacity(len - h);
        self.inflight_head = 0;
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

    /// A control datagram's stream_seq field is 0 except on an ACK,
    /// where it carries the length of the receiver's first hole (0 when
    /// it holds nothing out of order) so fast recovery can resend the
    /// whole gap in one round trip. Peers predating it send 0 and
    /// ignore the field, which degrades to resending the head only.
    fn emitControl(self: *Channel, t: u8, now_ms: i64, emit: EmitFn, ctx: ?*anyopaque) void {
        var inner_buf: [INNER_HDR]u8 = undefined;
        inner_buf[0] = t;
        std.mem.writeInt(u32, inner_buf[1..5], self.recv_expected, .little);
        const hole: u32 = if (t == TYPE_ACK and self.reorder.items.len > 0)
            self.reorder.items[0].seq -% self.recv_expected
        else
            0;
        std.mem.writeInt(u32, inner_buf[5..9], hole, .little);
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
        try self.onAck(t, ack, if (t == TYPE_ACK) seq else 0, now_ms, emit, ctx);

        switch (t) {
            TYPE_DATA => {
                const payload = inner[INNER_HDR..];
                if (seq == self.recv_expected) {
                    try deliver.appendSlice(self.allocator, payload);
                    self.recv_expected +%= 1;
                    try self.drainReorder(deliver);
                    self.ack_pending = true;
                } else {
                    try self.holdReorder(seq, payload);
                    // Gap or duplicate: ack at once and as a PURE ack
                    // (only those count as duplicates), so the sender
                    // learns of the hole within one round trip.
                    self.emitControl(TYPE_ACK, now_ms, emit, ctx);
                }
            },
            TYPE_BYE => {
                self.closed = true;
                return false;
            },
            else => {},
        }
        return true;
    }

    /// Sender half of onDatagram: retire acked segments, update the
    /// RTT estimate and congestion state, and repair reported loss.
    fn onAck(self: *Channel, t: u8, ack: u32, hole: u32, now_ms: i64, emit: EmitFn, ctx: ?*anyopaque) !void {
        var acked: usize = 0;
        var any_retx = false;
        var newest_sent: i64 = 0;
        for (self.flight()) |seg| {
            // Window ≤ WINDOW so wraparound-safe distance comparison.
            const dist = ack -% seg.seq;
            if (dist == 0 or dist > WINDOW * 2) break;
            any_retx = any_retx or seg.retx;
            newest_sent = seg.sent_at;
            self.allocator.free(seg.data);
            acked += 1;
        }
        if (acked > 0) {
            self.inflight_head += acked;
            self.compactInflight();
            if (!any_retx) self.sampleRtt(now_ms - newest_sent);
            self.rto_ms = self.computedRto();
            self.last_ack = ack;
            self.dup_acks = 0;
            if (self.in_recovery and seqAtOrAfter(ack, self.recover)) {
                self.in_recovery = false;
                self.go_back_n = false;
            }
            if (self.go_back_n) {
                if (acked > self.rtx_next) {
                    // The ack jumped past every resent segment, so the
                    // receiver holds the rest of the flight: the RTO
                    // was a delay spike or a single loss, not an
                    // outage. Repair reported holes instead of
                    // resending what it already has.
                    self.go_back_n = false;
                    self.rtx_next = 0;
                    self.rtx_high = ack;
                    self.cwnd = @max(self.cwnd, self.ssthresh);
                    if (hole > 0) self.repairHole(hole, now_ms, emit, ctx);
                } else {
                    self.rtx_next -= acked;
                    self.growCwnd(acked);
                }
            } else if (self.in_recovery) {
                // Partial ack: the next hole starts at the new head.
                self.repairHole(hole, now_ms, emit, ctx);
            } else {
                self.growCwnd(acked);
            }
            self.retransmit_at = if (self.flight().len > 0) now_ms + self.rto_ms else 0;
            try self.pump(now_ms, emit, ctx);
        } else if (t == TYPE_ACK and self.flight().len > 0 and ack == self.last_ack) {
            // The peer keeps acking below our head: it is alive and
            // missing at least the head segment. Resend it now rather
            // than after a full RTO.
            if (self.in_recovery) {
                if (!self.go_back_n) self.repairHole(hole, now_ms, emit, ctx);
                return;
            }
            self.dup_acks +|= 1;
            if (self.dup_acks >= DUP_ACK_FAST) {
                self.dup_acks = 0;
                self.ssthresh = @max(self.flight().len / 2, CWND_MIN);
                self.cwnd = self.ssthresh;
                self.cwnd_credit = 0;
                self.in_recovery = true;
                self.recover = self.next_seq;
                self.rtx_high = ack;
                self.repairHole(hole, now_ms, emit, ctx);
                self.retransmit_at = now_ms + self.rto_ms;
            }
        } else if (ack != self.last_ack) {
            self.last_ack = ack;
            self.dup_acks = 0;
        }
    }

    /// Buffer an out-of-order segment (ahead of recv_expected) so a
    /// single head retransmit later releases the whole run. Old
    /// duplicates and segments past the hold window are dropped.
    fn holdReorder(self: *Channel, seq: u32, payload: []const u8) !void {
        const dist = seq -% self.recv_expected;
        if (dist == 0 or dist >= REORDER_MAX) return;
        // Arrivals are mostly ascending: scan from the tail.
        var insert_at: usize = self.reorder.items.len;
        while (insert_at > 0) : (insert_at -= 1) {
            const held_dist = self.reorder.items[insert_at - 1].seq -% self.recv_expected;
            if (held_dist == dist) return; // duplicate
            if (held_dist < dist) break;
        }
        const copy = try self.allocator.dupe(u8, payload);
        errdefer self.allocator.free(copy);
        try self.reorder.insert(self.allocator, insert_at, .{ .seq = seq, .data = copy });
    }

    /// Deliver every buffered segment that is now in order.
    fn drainReorder(self: *Channel, deliver: *std.ArrayList(u8)) !void {
        var n: usize = 0;
        defer if (n > 0) {
            const rest = self.reorder.items.len - n;
            std.mem.copyForwards(Segment, self.reorder.items[0..rest], self.reorder.items[n..]);
            self.reorder.shrinkRetainingCapacity(rest);
        };
        while (n < self.reorder.items.len) {
            const held = self.reorder.items[n];
            if (held.seq != self.recv_expected) break;
            try deliver.appendSlice(self.allocator, held.data);
            self.allocator.free(held.data);
            n += 1;
            self.recv_expected +%= 1;
        }
    }

    /// Timer driver: retransmit on RTO, flush pending acks, emit
    /// keepalives. Returns the next deadline (ms) the caller should
    /// poll() with, or null for "nothing scheduled" (use keepalive).
    pub fn tick(self: *Channel, now_ms: i64, emit: EmitFn, ctx: ?*anyopaque) ?i64 {
        if (self.closed) return null;
        if (self.flight().len > 0 and self.retransmit_at != 0 and now_ms >= self.retransmit_at) {
            // RTO: the ack clock stopped (an outage, or a lost
            // retransmit). Treat the whole flight as lost and resend
            // it go-back-N from a small window; the receiver's reorder
            // buffer makes the ack jump past whatever it already holds.
            self.ssthresh = @max(self.flight().len / 2, CWND_MIN);
            self.cwnd = CWND_MIN;
            self.cwnd_credit = 0;
            self.dup_acks = 0;
            self.in_recovery = true;
            self.recover = self.next_seq;
            self.go_back_n = true;
            self.rtx_next = 0;
            self.pumpRetransmits(now_ms, emit, ctx);
            self.rto_ms = @min(self.rto_ms * 2, RTO_MAX_MS);
            self.retransmit_at = now_ms + self.rto_ms;
        }
        if (self.ack_pending) self.emitControl(TYPE_ACK, now_ms, emit, ctx);
        if (now_ms - self.last_emit_at >= KEEPALIVE_MS) self.emitControl(TYPE_ACK, now_ms, emit, ctx);

        var deadline: i64 = self.last_emit_at + KEEPALIVE_MS;
        if (self.flight().len > 0 and self.retransmit_at != 0) {
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

/// A network with a fixed one-way delay, for timing-sensitive tests.
const DelayNet = struct {
    allocator: std.mem.Allocator,
    one_way_ms: i64,
    now: i64 = 0,
    /// Datagrams A emitted (originals and retransmits alike).
    sent_a: usize = 0,
    /// Random loss in both directions, for the stress test.
    loss_pct: u8 = 0,
    prng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(99),
    queue: std.ArrayList(Pending) = .empty,

    const Pending = struct { at: i64, to_b: bool, data: []u8 };

    fn push(self: *DelayNet, to_b: bool, d: []const u8) void {
        if (self.loss_pct > 0 and self.prng.random().intRangeAtMost(u8, 0, 99) < self.loss_pct) return;
        const copy = self.allocator.dupe(u8, d) catch return;
        self.queue.append(self.allocator, .{ .at = self.now + self.one_way_ms, .to_b = to_b, .data = copy }) catch self.allocator.free(copy);
    }

    fn emitToB(ctx: ?*anyopaque, d: []const u8) void {
        const self: *DelayNet = @ptrCast(@alignCast(ctx.?));
        self.sent_a += 1;
        self.push(true, d);
    }

    fn emitToA(ctx: ?*anyopaque, d: []const u8) void {
        const self: *DelayNet = @ptrCast(@alignCast(ctx.?));
        self.push(false, d);
    }

    /// Advance by `dt` ms, delivering every datagram now due in order, then tick both ends.
    fn step(self: *DelayNet, dt: i64, ca: *Channel, cb: *Channel, b_rx: *std.ArrayList(u8)) !void {
        self.now += dt;
        var sink: std.ArrayList(u8) = .empty;
        defer sink.deinit(self.allocator);
        var i: usize = 0;
        while (i < self.queue.items.len) {
            const p = self.queue.items[i];
            if (p.at > self.now) {
                i += 1;
                continue;
            }
            _ = self.queue.orderedRemove(i);
            defer self.allocator.free(p.data);
            if (p.to_b) {
                _ = try cb.onDatagram(p.data, self.now, b_rx, emitToA, @ptrCast(self));
            } else {
                _ = try ca.onDatagram(p.data, self.now, &sink, emitToB, @ptrCast(self));
            }
        }
        _ = ca.tick(self.now, emitToB, @ptrCast(self));
        _ = cb.tick(self.now, emitToA, @ptrCast(self));
    }

    fn deinit(self: *DelayNet) void {
        for (self.queue.items) |p| self.allocator.free(p.data);
        self.queue.deinit(self.allocator);
    }
};

test "rudp: a steady 300ms path never retransmits and the window outgrows 128 segments" {
    const a = std.testing.allocator;
    const key: [KEY_LEN]u8 = @splat(12);
    var net = DelayNet{ .allocator = a, .one_way_ms = 150 };
    defer net.deinit();
    var ca = Channel.init(a, key, true);
    defer ca.deinit();
    var cb = Channel.init(a, key, false);
    defer cb.deinit();
    var received: std.ArrayList(u8) = .empty;
    defer received.deinit(a);

    const segs = 400;
    const payload = try a.alloc(u8, SEG_MAX * segs);
    defer a.free(payload);
    var prng = std.Random.DefaultPrng.init(21);
    prng.random().bytes(payload);
    try ca.send(payload, 0, DelayNet.emitToB, @ptrCast(&net));

    var max_flight: usize = 0;
    var rounds: usize = 0;
    while (received.items.len < payload.len and rounds < 2000) : (rounds += 1) {
        try net.step(5, &ca, &cb, &received);
        max_flight = @max(max_flight, ca.flight().len);
    }
    try std.testing.expectEqualSlices(u8, payload, received.items);
    // The old fixed 80ms timer resent every segment of this path.
    try std.testing.expectEqual(@as(usize, segs), net.sent_a);
    try std.testing.expect(max_flight > 128);
    try std.testing.expect(ca.rto_ms >= 300);
}

test "rudp: 2 MB over a lossy 100ms path arrives intact with bounded resends" {
    const a = std.testing.allocator;
    const key: [KEY_LEN]u8 = @splat(16);
    var net = DelayNet{ .allocator = a, .one_way_ms = 50, .loss_pct = 3 };
    defer net.deinit();
    var ca = Channel.init(a, key, true);
    defer ca.deinit();
    var cb = Channel.init(a, key, false);
    defer cb.deinit();
    var received: std.ArrayList(u8) = .empty;
    defer received.deinit(a);

    const payload = try a.alloc(u8, 2 << 20);
    defer a.free(payload);
    var prng = std.Random.DefaultPrng.init(23);
    prng.random().bytes(payload);
    try ca.send(payload, 0, DelayNet.emitToB, @ptrCast(&net));

    var rounds: usize = 0;
    while (received.items.len < payload.len and rounds < 20_000) : (rounds += 1) {
        try net.step(5, &ca, &cb, &received);
    }
    try std.testing.expectEqualSlices(u8, payload, received.items);
    const segs = (payload.len + SEG_MAX - 1) / SEG_MAX;
    // 3% loss each way; repairs should stay far below resending everything.
    try std.testing.expect(net.sent_a < segs + segs / 4);
}

test "rudp: a contiguous burst loss is resent whole from one hole report" {
    const a = std.testing.allocator;
    const key: [KEY_LEN]u8 = @splat(13);
    var net = TestNet{ .allocator = a, .prng = std.Random.DefaultPrng.init(5) };
    defer net.deinit();
    var ca = Channel.init(a, key, true);
    defer ca.deinit();
    var cb = Channel.init(a, key, false);
    defer cb.deinit();
    var received: std.ArrayList(u8) = .empty;
    defer received.deinit(a);

    ca.cwnd = 128;
    const payload = try a.alloc(u8, SEG_MAX * 100);
    defer a.free(payload);
    var prng = std.Random.DefaultPrng.init(17);
    prng.random().bytes(payload);
    try ca.send(payload, 0, TestNet.emitToB, @ptrCast(&net));
    try std.testing.expectEqual(@as(usize, 100), net.to_b.items.len);

    // Lose segments 10..29 in one burst; the rest arrives.
    for (net.to_b.items, 0..) |d, i| {
        if (i >= 10 and i < 30) continue;
        _ = try cb.onDatagram(d, 0, &received, TestNet.emitToA, @ptrCast(&net));
    }
    for (net.to_b.items) |d| a.free(d);
    net.to_b.clearRetainingCapacity();
    _ = cb.tick(0, TestNet.emitToA, @ptrCast(&net));

    var sink: std.ArrayList(u8) = .empty;
    defer sink.deinit(a);
    for (net.to_a.items) |d| _ = try ca.onDatagram(d, 1, &sink, TestNet.emitToB, @ptrCast(&net));
    for (net.to_a.items) |d| a.free(d);
    net.to_a.clearRetainingCapacity();

    // Exactly the 20 missing segments, each once, without waiting for an RTO.
    try std.testing.expectEqual(@as(usize, 20), net.to_b.items.len);
    for (net.to_b.items) |d| _ = try cb.onDatagram(d, 2, &received, TestNet.emitToA, @ptrCast(&net));
    try std.testing.expectEqualSlices(u8, payload, received.items);
}

test "rudp: a spurious RTO does not resend the flight the receiver already holds" {
    const a = std.testing.allocator;
    const key: [KEY_LEN]u8 = @splat(14);
    var net = TestNet{ .allocator = a, .prng = std.Random.DefaultPrng.init(6) };
    defer net.deinit();
    var ca = Channel.init(a, key, true);
    defer ca.deinit();
    var cb = Channel.init(a, key, false);
    defer cb.deinit();
    var received: std.ArrayList(u8) = .empty;
    defer received.deinit(a);

    ca.cwnd = 64;
    const payload = try a.alloc(u8, SEG_MAX * 50);
    defer a.free(payload);
    @memset(payload, 0x42);
    try ca.send(payload, 0, TestNet.emitToB, @ptrCast(&net));
    // The path stalls past the RTO: a small go-back-N burst goes out.
    _ = ca.tick(RTO_INIT_MS + 1, TestNet.emitToB, @ptrCast(&net));
    try std.testing.expectEqual(@as(usize, 50 + CWND_MIN), net.to_b.items.len);
    try std.testing.expect(ca.go_back_n);

    // Then the delayed originals 0..39 land and their ack comes back.
    for (net.to_b.items[0..40]) |d| _ = try cb.onDatagram(d, 600, &received, TestNet.emitToA, @ptrCast(&net));
    for (net.to_b.items) |d| a.free(d);
    net.to_b.clearRetainingCapacity();
    _ = cb.tick(600, TestNet.emitToA, @ptrCast(&net));
    var sink: std.ArrayList(u8) = .empty;
    defer sink.deinit(a);
    for (net.to_a.items) |d| _ = try ca.onDatagram(d, 601, &sink, TestNet.emitToB, @ptrCast(&net));

    try std.testing.expect(!ca.go_back_n);
    try std.testing.expectEqual(@as(usize, 0), net.to_b.items.len);
    try std.testing.expectEqual(@as(usize, 10), ca.flight().len);
}

test "rudp: acks piggybacked on reverse data are not duplicate acks" {
    const a = std.testing.allocator;
    const key: [KEY_LEN]u8 = @splat(15);
    var net = TestNet{ .allocator = a, .prng = std.Random.DefaultPrng.init(7) };
    defer net.deinit();
    var ca = Channel.init(a, key, true);
    defer ca.deinit();
    var cb = Channel.init(a, key, false);
    defer cb.deinit();

    const payload = try a.alloc(u8, SEG_MAX * 20);
    defer a.free(payload);
    @memset(payload, 0x11);
    try ca.send(payload, 0, TestNet.emitToB, @ptrCast(&net));
    try cb.send(payload, 0, TestNet.emitToA, @ptrCast(&net));
    const a_sent = net.to_b.items.len;

    // B's data was sent before it saw any of A's, so it all carries
    // ack 0. That is B being busy, not B missing A's head.
    var sink: std.ArrayList(u8) = .empty;
    defer sink.deinit(a);
    for (net.to_a.items) |d| _ = try ca.onDatagram(d, 0, &sink, TestNet.emitToB, @ptrCast(&net));
    try std.testing.expect(!ca.in_recovery);
    try std.testing.expectEqual(a_sent, net.to_b.items.len);
    try std.testing.expectEqualSlices(u8, payload[0 .. SEG_MAX * CWND_START], sink.items);
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
