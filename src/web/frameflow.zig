//! Frame flow shared by every pushed-pixel path (the V1 web stream,
//! observer and owner-inline frames): an ack window that never queues
//! frames, and a bounded damage rect list read against the LIVE buffer
//! when a frame is finally cut, so a slow reader sees fewer, newer frames.
//!
//! Pure std: no CEF, no sockets, no allocator.

const std = @import("std");

pub const Rect = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,

    /// Any x/y/w/h rect (a protocol's narrower one) widened to this.
    pub fn of(r: anytype) Rect {
        return .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
    }

    pub fn empty(self: Rect) bool {
        return self.w == 0 or self.h == 0;
    }

    pub fn area(self: Rect) u64 {
        return @as(u64, self.w) * self.h;
    }

    /// The smallest rect covering both.
    pub fn unite(a: Rect, b: Rect) Rect {
        if (a.empty()) return b;
        if (b.empty()) return a;
        const x0 = @min(a.x, b.x);
        const y0 = @min(a.y, b.y);
        const x1 = @max(@as(u64, a.x) + a.w, @as(u64, b.x) + b.w);
        const y1 = @max(@as(u64, a.y) + a.h, @as(u64, b.y) + b.h);
        return .{ .x = x0, .y = y0, .w = @intCast(x1 - x0), .h = @intCast(y1 - y0) };
    }

    /// `self` clipped to a `w`x`h` surface; empty when fully outside.
    pub fn clip(self: Rect, w: u32, h: u32) Rect {
        if (self.x >= w or self.y >= h) return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        return .{
            .x = self.x,
            .y = self.y,
            .w = @intCast(@min(@as(u64, self.w), w - self.x)),
            .h = @intCast(@min(@as(u64, self.h), h - self.y)),
        };
    }

    /// Whether the two overlap or leave at most `gap` pixels between them
    /// on BOTH axes (a rect far away on either axis is not near).
    pub fn near(a: Rect, b: Rect, gap: u32) bool {
        return @as(u64, a.x) <= @as(u64, b.x) + b.w + gap and
            @as(u64, b.x) <= @as(u64, a.x) + a.w + gap and
            @as(u64, a.y) <= @as(u64, b.y) + b.h + gap and
            @as(u64, b.y) <= @as(u64, a.y) + a.h + gap;
    }
};

/// A `window`-unacked-frames flow. Serials start at 1 and grow by one per
/// frame end; an ACK names one outstanding serial and retires it and every
/// older one. Anything else is a protocol violation.
pub fn Flow(comptime window: usize) type {
    return struct {
        const Self = @This();
        next: u64 = 1,
        inflight: [window]u64 = @splat(0),
        n: usize = 0,

        pub fn canSend(self: *const Self) bool {
            return self.n < window;
        }

        /// Record a sent frame end and return its serial.
        pub fn sent(self: *Self) u64 {
            std.debug.assert(self.canSend());
            const s = self.next;
            self.next += 1;
            self.inflight[self.n] = s;
            self.n += 1;
            return s;
        }

        pub fn ack(self: *Self, serial: u64) error{InvalidAck}!void {
            for (self.inflight[0..self.n], 0..) |s, i| {
                if (s != serial) continue;
                const keep = self.n - (i + 1);
                std.mem.copyForwards(u64, self.inflight[0..keep], self.inflight[i + 1 .. self.n]);
                self.n = keep;
                return;
            }
            return error.InvalidAck;
        }
    };
}

/// Damage painted since the last frame was cut, as at most `MAX_RECTS`
/// pairwise disjoint rects. A new rect absorbs every stored rect it is
/// `near` within `MERGE_GAP` (repeatedly, since the grown rect can reach
/// further ones); when the list is full the pair whose union adds the
/// fewest uncovered pixels is merged, so two small far-apart animations
/// stay two small rects instead of one near-full-surface box.
pub const Damage = struct {
    pub const MAX_RECTS = 8;
    /// Pixels of slack under which neighbours merge: a few rows of extra
    /// pixels cost less than another rect's header and band setup.
    pub const MERGE_GAP: u32 = 16;

    rects: [MAX_RECTS]Rect = undefined,
    n: usize = 0,

    pub fn pending(self: *const Damage) bool {
        return self.n != 0;
    }

    pub fn clear(self: *Damage) void {
        self.n = 0;
    }

    /// Replace whatever is pending with the whole `w`x`h` surface.
    pub fn full(self: *Damage, w: u32, h: u32) void {
        self.n = 0;
        self.add(.{ .x = 0, .y = 0, .w = w, .h = h });
    }

    pub fn add(self: *Damage, r: Rect) void {
        if (r.empty()) return;
        var cur = r;
        var i: usize = 0;
        while (i < self.n) {
            if (!cur.near(self.rects[i], MERGE_GAP)) {
                i += 1;
                continue;
            }
            cur = cur.unite(self.rects[i]);
            self.n -= 1;
            self.rects[i] = self.rects[self.n];
            // The grown rect may now reach one already passed.
            i = 0;
        }
        if (self.n < MAX_RECTS) {
            self.rects[self.n] = cur;
            self.n += 1;
            return;
        }
        // Full: merge the cheapest pair among the stored rects and `cur`.
        var all: [MAX_RECTS + 1]Rect = undefined;
        @memcpy(all[0..MAX_RECTS], &self.rects);
        all[MAX_RECTS] = cur;
        var best_a: usize = 0;
        var best_b: usize = 1;
        var best: u64 = std.math.maxInt(u64);
        for (0..all.len) |a| for (a + 1..all.len) |b| {
            const waste = all[a].unite(all[b]).area() - all[a].area() - all[b].area();
            if (waste < best) {
                best = waste;
                best_a = a;
                best_b = b;
            }
        };
        const merged = all[best_a].unite(all[best_b]);
        // Keep the other MAX_RECTS - 1, then add the union back, which
        // absorbs whatever it now overlaps and always fits.
        self.n = 0;
        for (all, 0..) |x, k| {
            if (k == best_a or k == best_b) continue;
            self.rects[self.n] = x;
            self.n += 1;
        }
        self.add(merged);
    }

    /// `add` each of a slice of any x/y/w/h rects.
    pub fn addAll(self: *Damage, rects: anytype) void {
        for (rects) |r| self.add(Rect.of(r));
    }

    /// Yield the pending rects clipped to a `w`x`h` surface (rects fully
    /// outside it are dropped) and clear the list.
    pub fn take(self: *Damage, w: u32, h: u32, out: *[MAX_RECTS]Rect) []Rect {
        var k: usize = 0;
        for (self.rects[0..self.n]) |r| {
            const cr = r.clip(w, h);
            if (cr.empty()) continue;
            out[k] = cr;
            k += 1;
        }
        self.n = 0;
        return out[0..k];
    }

    /// The bounding box of everything pending, unclipped, and clear the
    /// list; for readers that track what a frame touched, not senders.
    pub fn takeBounds(self: *Damage) ?Rect {
        defer self.n = 0;
        if (self.n == 0) return null;
        var u = self.rects[0];
        for (self.rects[1..self.n]) |r| u = u.unite(r);
        return u;
    }
};

// -- tests ----------------------------------------------------------------

const t = std.testing;

test "flow allows a window of unacked frames and rejects unknown ACKs" {
    var f: Flow(2) = .{};
    try t.expectEqual(@as(u64, 1), f.sent());
    try t.expectEqual(@as(u64, 2), f.sent());
    try t.expect(!f.canSend());
    try t.expectError(error.InvalidAck, f.ack(3));
    try t.expectError(error.InvalidAck, f.ack(0));
    // ACKing the newer one retires both.
    try f.ack(2);
    try t.expect(f.canSend());
    try t.expectError(error.InvalidAck, f.ack(1));
    try t.expectEqual(@as(u64, 3), f.sent());
    try f.ack(3);
    try t.expectError(error.InvalidAck, f.ack(3));
}

fn pendingArea(d: *const Damage) u64 {
    var a: u64 = 0;
    for (d.rects[0..d.n]) |r| a += r.area();
    return a;
}

/// The list invariant: no two stored rects are within merge reach.
fn disjoint(d: *const Damage) bool {
    for (d.rects[0..d.n], 0..) |a, i| for (d.rects[i + 1 .. d.n]) |b| {
        if (a.near(b, Damage.MERGE_GAP)) return false;
    };
    return true;
}

test "damage keeps far-apart rects apart and merges near ones" {
    var d: Damage = .{};
    // Two small animations in opposite corners of a 1920x1080 page.
    d.add(.{ .x = 10, .y = 10, .w = 20, .h = 20 });
    d.add(.{ .x = 1880, .y = 1040, .w = 20, .h = 20 });
    try t.expectEqual(@as(usize, 2), d.n);
    try t.expectEqual(@as(u64, 800), pendingArea(&d));
    // Within MERGE_GAP of the first: absorbed into it.
    d.add(.{ .x = 30 + Damage.MERGE_GAP, .y = 10, .w = 5, .h = 5 });
    try t.expectEqual(@as(usize, 2), d.n);
    // One pixel further than the gap is a rect of its own.
    d.add(.{ .x = 100, .y = 200 + Damage.MERGE_GAP + 1, .w = 5, .h = 5 });
    d.add(.{ .x = 100, .y = 190, .w = 5, .h = 10 });
    try t.expectEqual(@as(usize, 4), d.n);
    // A rect bridging two stored ones absorbs both, transitively.
    d.add(.{ .x = 100, .y = 195, .w = 5, .h = 30 });
    try t.expectEqual(@as(usize, 3), d.n);
    try t.expect(disjoint(&d));
    // Empty rects are ignored.
    d.add(.{ .x = 500, .y = 500, .w = 0, .h = 9 });
    try t.expectEqual(@as(usize, 3), d.n);

    var out: [Damage.MAX_RECTS]Rect = undefined;
    const got = d.take(1920, 1080, &out);
    try t.expectEqual(@as(usize, 3), got.len);
    try t.expect(!d.pending());
    try t.expectEqual(@as(usize, 0), d.take(1920, 1080, &out).len);
}

test "damage past the cap merges the cheapest pair, never losing pixels" {
    var d: Damage = .{};
    // A row of well separated 10x10 rects, one more than the cap; the
    // last two are the closest pair (40px apart, the others 100px).
    for (0..Damage.MAX_RECTS - 1) |i| d.add(.{ .x = @intCast(i * 110), .y = 0, .w = 10, .h = 10 });
    const tail: u32 = @intCast((Damage.MAX_RECTS - 1) * 110);
    d.add(.{ .x = tail, .y = 0, .w = 10, .h = 10 });
    try t.expectEqual(@as(usize, Damage.MAX_RECTS), d.n);
    d.add(.{ .x = tail + 50, .y = 0, .w = 10, .h = 10 });
    try t.expectEqual(@as(usize, Damage.MAX_RECTS), d.n);
    try t.expect(disjoint(&d));
    var found = false;
    for (d.rects[0..d.n]) |r| {
        if (r.x == tail and r.w == 60) found = true;
    }
    try t.expect(found);
    // Every painted pixel is still covered.
    const b = d.takeBounds().?;
    try t.expectEqual(Rect{ .x = 0, .y = 0, .w = tail + 60, .h = 10 }, b);
    try t.expect(d.takeBounds() == null);

    // A storm of scattered damage stays bounded and covers its bounds.
    var s: Damage = .{};
    var prng = std.Random.DefaultPrng.init(7);
    const rnd = prng.random();
    var u: ?Rect = null;
    for (0..500) |_| {
        const r = Rect{ .x = rnd.uintLessThan(u32, 1900), .y = rnd.uintLessThan(u32, 1060), .w = 1 + rnd.uintLessThan(u32, 20), .h = 1 + rnd.uintLessThan(u32, 20) };
        u = if (u) |x| x.unite(r) else r;
        s.add(r);
        try t.expect(s.n <= Damage.MAX_RECTS);
        try t.expect(disjoint(&s));
    }
    try t.expectEqual(u.?, s.takeBounds().?);
}

test "damage clips to the surface on take and full replaces everything" {
    var d: Damage = .{};
    d.add(.{ .x = 10, .y = 10, .w = 50, .h = 50 });
    d.add(.{ .x = 200, .y = 0, .w = 5, .h = 5 });
    var out: [Damage.MAX_RECTS]Rect = undefined;
    const got = d.take(16, 12, &out);
    try t.expectEqual(@as(usize, 1), got.len);
    try t.expectEqual(Rect{ .x = 10, .y = 10, .w = 6, .h = 2 }, got[0]);

    const Narrow = struct { x: u16, y: u16, w: u16, h: u16 };
    d.addAll(&[_]Narrow{ .{ .x = 1, .y = 1, .w = 1, .h = 1 }, .{ .x = 900, .y = 900, .w = 1, .h = 1 } });
    try t.expectEqual(@as(usize, 2), d.n);
    d.full(640, 480);
    const all = d.take(640, 480, &out);
    try t.expectEqual(@as(usize, 1), all.len);
    try t.expectEqual(Rect{ .x = 0, .y = 0, .w = 640, .h = 480 }, all[0]);
}
