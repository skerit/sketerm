//! Bounded, thread-safe event queue between a rendered panel and the
//! MCP layer.
//!
//! Pure Zig + libc (`util/clock.zig`, `nanosleep`), NO GTK/GLib -
//! lives in both test roots. Events are flat fixed-size structs so
//! `push` can never fail and never allocates (it runs inside GTK
//! signal handlers). Synchronization is `util/spinlock.zig`, whose
//! docblock is where the "why a spinlock and not a Mutex" rationale
//! lives; every critical section here is a few dozen instructions
//! over the fixed ring, which is exactly what a spinlock is for.
//!
//! Threading contract for the next agent (`ui_wait_event`):
//! - `push` is called on the GTK main thread by the renderer.
//! - `waitAny(timeout_ms)` BLOCKS (bounded 10ms poll granularity) and
//!   therefore must NEVER be called on the GTK main thread. It exists
//!   for a bridge thread that is allowed to sleep; an MCP process
//!   blocking on its own socket read does not need it.
//! - A main-loop host that must not block instead sets `on_push`,
//!   which fires on the pushing (main) thread after the lock is
//!   released. Reliable consumers use `reliableInto`; legacy consumers
//!   use the destructive `drainInto`. A legacy drain advances the shared
//!   cursor and counts every removed event as unavailable to reliable retry;
//!   sequence and cursor values never regress when readers are mixed.
//! - `close()` makes further waits return immediately (within one
//!   poll tick) and further pushes no-ops; pending events stay
//!   drainable. It is how panel teardown unblocks a pending
//!   `ui_wait_event`. Idempotent.

const std = @import("std");
const c = @import("../../c.zig").c;
const clock = @import("../../util/clock.zig");
const vocab = @import("../../panelvocab.zig");
const SpinLock = @import("../../util/spinlock.zig").SpinLock;

/// Longest component id. Declared once in `panelvocab.zig`, because
/// the daemon's presenter validator bounds the same ids.
pub const MAX_ID: usize = vocab.MAX_ID;
/// Longest text payload an event carries. This accommodates submitted
/// text_input values without allocating in GTK signal handlers.
pub const MAX_TEXT: usize = vocab.MAX_TEXT;
/// Existing short interaction values (button actions and select
/// options) retain their original bound.
pub const MAX_SHORT_TEXT: usize = vocab.MAX_SHORT_TEXT;
/// Ring capacity. Full queue drops the OLDEST event (the consumer
/// prefers fresh interactions over stale ones) and counts the drop.
pub const CAP: usize = 64;

/// waitAny poll granularity. Human-interaction latency tolerance is
/// orders of magnitude above this; the on_push hook exists for hosts
/// that need instant delivery.
const POLL_NS: c_long = 10 * std.time.ns_per_ms;

pub const Kind = vocab.Kind;

pub const Value = union(enum) {
    none: void,
    number: f64,
    boolean: bool,
    text: Text,

    pub const Text = struct {
        buf: [MAX_TEXT]u8 = undefined,
        len: u16 = 0,

        pub fn slice(self: *const Text) []const u8 {
            return self.buf[0..self.len];
        }
    };

    pub fn fromText(s: []const u8) Value {
        var txt: Text = .{};
        const n = @min(s.len, MAX_TEXT);
        @memcpy(txt.buf[0..n], s[0..n]);
        txt.len = @intCast(n);
        return .{ .text = txt };
    }
};

pub const Event = struct {
    /// Queue-assigned monotonic sequence. Zero means not queued yet.
    seq: u64 = 0,
    id_buf: [MAX_ID]u8 = undefined,
    id_len: u8 = 0,
    kind: Kind = .click,
    value: Value = .none,
    /// Monotonic milliseconds (`util/clock.nowMs` epoch): ordering and
    /// deltas only, not wall time.
    ts_ms: i64 = 0,

    pub fn init(component_id: []const u8, kind: Kind, value: Value) Event {
        var ev = Event{ .kind = kind, .value = value, .ts_ms = clock.nowMs() };
        const n = @min(component_id.len, MAX_ID);
        @memcpy(ev.id_buf[0..n], component_id[0..n]);
        ev.id_len = @intCast(n);
        return ev;
    }

    pub fn id(self: *const Event) []const u8 {
        return self.id_buf[0..self.id_len];
    }
};

/// Fixed resident queue storage per live panel, excluding the PanelView and
/// transient heap scratch used to serialize a response.
pub const STORAGE_BYTES: usize = @sizeOf(Event) * CAP;

fn sleepBriefly() void {
    var ts: c.struct_timespec = .{ .tv_sec = 0, .tv_nsec = POLL_NS };
    _ = c.nanosleep(&ts, null);
}

pub const Queue = struct {
    lock: SpinLock = .{},
    ring: [CAP]Event = undefined,
    head: usize = 0,
    count: usize = 0,
    next_seq: u64 = 1,
    /// Highest sequence returned or made unavailable by either reader mode.
    reliable_cursor: u64 = 0,
    dropped: u64 = 0,
    dropped_total: u64 = 0,
    closed: bool = false,
    /// Fired on the pushing thread, after the lock is released, once
    /// per successful push. For main-loop hosts that cannot block.
    on_push: ?*const fn (?*anyopaque) void = null,
    on_push_ctx: ?*anyopaque = null,

    pub fn init() Queue {
        return .{};
    }

    fn acquire(self: *Queue) void {
        self.lock.lock();
    }

    fn release(self: *Queue) void {
        self.lock.unlock();
    }

    /// Append (never fails). Consecutive `.change` events from the
    /// same component COALESCE into one — a slider drag emits a value
    /// stream and only the latest matters — so a drag cannot evict a
    /// click that preceded it.
    pub fn push(self: *Queue, ev: Event) void {
        var notify = false;
        {
            self.acquire();
            defer self.release();
            if (self.closed) return;
            var coalesced = false;
            if (ev.kind == .change and self.count > 0) {
                const last = &self.ring[(self.head + self.count - 1) % CAP];
                // Once a reliable reader has observed an event, replacing it
                // would make a lost-reply retry return different bytes. Append
                // after that cursor; only unseen tail changes may coalesce.
                if (last.seq > self.reliable_cursor and last.kind == .change and std.mem.eql(u8, last.id(), ev.id())) {
                    var replacement = ev;
                    replacement.seq = last.seq;
                    last.* = replacement;
                    coalesced = true;
                }
            }
            if (!coalesced) {
                // Never recycle sequence numbers. At u64 exhaustion, report
                // every further event as dropped rather than making an old ack
                // ambiguous with a new epoch.
                if (self.next_seq == 0) {
                    self.noteDropped();
                    notify = true;
                } else {
                    if (self.count == CAP) {
                        self.head = (self.head + 1) % CAP;
                        self.count -= 1;
                        self.noteDropped();
                    }
                    var queued = ev;
                    queued.seq = self.next_seq;
                    self.next_seq +%= 1;
                    self.ring[(self.head + self.count) % CAP] = queued;
                    self.count += 1;
                }
            }
            notify = true;
        }
        if (notify) {
            if (self.on_push) |cb| cb(self.on_push_ctx);
        }
    }

    fn noteDropped(self: *Queue) void {
        self.dropped +|= 1;
        self.dropped_total +|= 1;
    }

    fn noteReliableUnavailable(self: *Queue, ev: Event) void {
        self.reliable_cursor = @max(self.reliable_cursor, ev.seq);
        self.dropped_total +|= 1;
    }

    /// Oldest pending event, or null. Non-blocking; main-thread safe.
    pub fn tryPop(self: *Queue) ?Event {
        self.acquire();
        defer self.release();
        if (self.count == 0) return null;
        const ev = self.ring[self.head];
        self.noteReliableUnavailable(ev);
        self.head = (self.head + 1) % CAP;
        self.count -= 1;
        return ev;
    }

    /// Drain up to `buf.len` events in arrival order. Non-blocking.
    pub fn drainInto(self: *Queue, buf: []Event) usize {
        self.acquire();
        defer self.release();
        var n: usize = 0;
        while (n < buf.len and self.count > 0) : (n += 1) {
            buf[n] = self.ring[self.head];
            self.noteReliableUnavailable(buf[n]);
            self.head = (self.head + 1) % CAP;
            self.count -= 1;
        }
        return n;
    }

    pub const Reliable = struct {
        count: usize,
        cursor: u64,
        dropped_total: u64,
    };

    /// Acknowledge only sequences this queue has previously returned, then
    /// COPY all remaining events without removing them. A retry with the same
    /// ack therefore repeats every unacknowledged event unless bounded
    /// overflow explicitly increased dropped_total.
    pub fn reliableInto(self: *Queue, ack: u64, buf: []Event) Reliable {
        self.acquire();
        defer self.release();
        const effective_ack = @min(ack, self.reliable_cursor);
        while (self.count > 0) {
            const event = self.ring[self.head];
            if (event.seq > effective_ack) break;
            self.head = (self.head + 1) % CAP;
            self.count -= 1;
        }
        const n = @min(buf.len, self.count);
        for (0..n) |i| buf[i] = self.ring[(self.head + i) % CAP];
        if (n > 0) self.reliable_cursor = @max(self.reliable_cursor, buf[n - 1].seq);
        return .{
            .count = n,
            .cursor = self.reliable_cursor,
            .dropped_total = self.dropped_total,
        };
    }

    pub fn pending(self: *Queue) usize {
        self.acquire();
        defer self.release();
        return self.count;
    }

    pub fn isClosed(self: *Queue) bool {
        self.acquire();
        defer self.release();
        return self.closed;
    }

    /// Drop count since the last call, reset on read.
    pub fn takeDropped(self: *Queue) u64 {
        self.acquire();
        defer self.release();
        const d = self.dropped;
        self.dropped = 0;
        return d;
    }

    /// Block until at least one event is pending, the queue closes, or
    /// `timeout_ms` elapses; 10ms poll granularity. @return pending
    /// count (0 = timeout or closed-and-empty). NEVER call on the GTK
    /// main thread.
    pub fn waitAny(self: *Queue, timeout_ms: u64) usize {
        const capped: i64 = @intCast(@min(timeout_ms, std.math.maxInt(i64) / 2));
        const deadline = clock.nowMs() + capped;
        while (true) {
            self.acquire();
            const n = self.count;
            const done = self.closed;
            self.release();
            if (n > 0 or done) return n;
            if (clock.nowMs() >= deadline) return 0;
            sleepBriefly();
        }
    }

    /// Further pushes are ignored, pending events stay drainable, and
    /// every waiter returns within one poll tick. Idempotent — every
    /// teardown path may call it.
    pub fn close(self: *Queue) void {
        self.acquire();
        defer self.release();
        self.closed = true;
    }
};

// ─── tests ──────────────────────────────────────────────────────

test "queue preserves order and bounds by dropping oldest" {
    var q = Queue.init();
    var i: usize = 0;
    while (i < CAP + 10) : (i += 1) {
        var idbuf: [16]u8 = undefined;
        const id = try std.fmt.bufPrint(&idbuf, "b{d}", .{i});
        q.push(Event.init(id, .click, .none));
    }
    try std.testing.expectEqual(@as(usize, CAP), q.pending());
    try std.testing.expectEqual(@as(u64, 10), q.takeDropped());
    // Oldest surviving event is number 10.
    const first = q.tryPop().?;
    try std.testing.expectEqualStrings("b10", first.id());
    var last: Event = undefined;
    while (q.tryPop()) |ev| last = ev;
    try std.testing.expectEqualStrings("b73", last.id());
}

test "consecutive change events from one component coalesce" {
    var q = Queue.init();
    q.push(Event.init("s1", .change, .{ .number = 1 }));
    q.push(Event.init("s1", .change, .{ .number = 2 }));
    q.push(Event.init("s1", .change, .{ .number = 3 }));
    try std.testing.expectEqual(@as(usize, 1), q.pending());
    try std.testing.expectEqual(@as(f64, 3), q.tryPop().?.value.number);
    // A click in between breaks the run.
    q.push(Event.init("s1", .change, .{ .number = 4 }));
    q.push(Event.init("ok", .click, .none));
    q.push(Event.init("s1", .change, .{ .number = 5 }));
    try std.testing.expectEqual(@as(usize, 3), q.pending());
}

test "waitAny returns on push, timeout, and close" {
    var q = Queue.init();
    // Timeout with nothing pending.
    try std.testing.expectEqual(@as(usize, 0), q.waitAny(20));
    // Push from another thread unblocks the wait.
    const Pusher = struct {
        fn run(queue: *Queue) void {
            sleepBriefly();
            queue.push(Event.init("go", .click, .none));
        }
    };
    var t1 = try std.Thread.spawn(.{}, Pusher.run, .{&q});
    try std.testing.expect(q.waitAny(5000) >= 1);
    t1.join();
    _ = q.tryPop();
    // Close unblocks an empty wait.
    const Closer = struct {
        fn run(queue: *Queue) void {
            sleepBriefly();
            queue.close();
        }
    };
    var t2 = try std.Thread.spawn(.{}, Closer.run, .{&q});
    try std.testing.expectEqual(@as(usize, 0), q.waitAny(5000));
    t2.join();
    // Pushes after close are ignored; drain still works.
    q.push(Event.init("late", .click, .none));
    try std.testing.expectEqual(@as(usize, 0), q.pending());
}

test "drainInto, on_push hook, and event payload accessors" {
    var q = Queue.init();
    const Hook = struct {
        var hits: usize = 0;
        fn cb(ctx: ?*anyopaque) void {
            _ = ctx;
            hits += 1;
        }
    };
    Hook.hits = 0;
    q.on_push = &Hook.cb;
    q.push(Event.init("pick", .change, Value.fromText("epoch-41")));
    q.push(Event.init("ok", .click, .none));
    try std.testing.expectEqual(@as(usize, 2), Hook.hits);
    var buf: [8]Event = undefined;
    const n = q.drainInto(&buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("pick", buf[0].id());
    try std.testing.expectEqualStrings("epoch-41", buf[0].value.text.slice());
    try std.testing.expectEqualStrings("ok", buf[1].id());
    try std.testing.expect(buf[1].ts_ms >= buf[0].ts_ms);
}

test "submitted text preserves the full 4096-byte payload" {
    const value = "x" ** MAX_TEXT;
    const ev = Event.init("query", .submit, Value.fromText(value));
    try std.testing.expectEqualStrings(value, ev.value.text.slice());
    try std.testing.expectEqual(Kind.submit, ev.kind);
}

test "reliable reads retry exactly, acknowledge through cursor, and protect observed changes from coalescing" {
    var q = Queue.init();
    q.push(Event.init("slider", .change, .{ .number = 1 }));
    var first_buf: [CAP]Event = undefined;
    const first = q.reliableInto(0, &first_buf);
    try std.testing.expectEqual(@as(usize, 1), first.count);
    try std.testing.expectEqual(@as(u64, 1), first.cursor);

    // This cannot replace seq 1 after it was returned but not acknowledged.
    q.push(Event.init("slider", .change, .{ .number = 2 }));
    var retry_buf: [CAP]Event = undefined;
    const retry = q.reliableInto(0, &retry_buf);
    try std.testing.expectEqual(@as(usize, 2), retry.count);
    try std.testing.expectEqual(@as(u64, 1), retry_buf[0].seq);
    try std.testing.expectEqual(@as(f64, 1), retry_buf[0].value.number);
    try std.testing.expectEqual(@as(u64, 2), retry_buf[1].seq);

    var remaining_buf: [CAP]Event = undefined;
    const remaining = q.reliableInto(first.cursor, &remaining_buf);
    try std.testing.expectEqual(@as(usize, 1), remaining.count);
    try std.testing.expectEqual(@as(u64, 2), remaining_buf[0].seq);
    const empty = q.reliableInto(remaining.cursor, &remaining_buf);
    try std.testing.expectEqual(@as(usize, 0), empty.count);
    try std.testing.expectEqual(@as(u64, 2), empty.cursor);
}

test "reliable overflow and mixed legacy loss are cumulative" {
    var q = Queue.init();
    for (0..CAP + 3) |i| {
        var id_buf: [16]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "e{d}", .{i});
        q.push(Event.init(id, .click, .none));
    }
    var reliable_buf: [CAP]Event = undefined;
    const snapshot = q.reliableInto(0, &reliable_buf);
    try std.testing.expectEqual(@as(usize, CAP), snapshot.count);
    try std.testing.expectEqual(@as(u64, 3), snapshot.dropped_total);
    try std.testing.expectEqual(@as(u64, 4), reliable_buf[0].seq);
    const retry = q.reliableInto(0, &reliable_buf);
    try std.testing.expectEqual(snapshot.cursor, retry.cursor);
    try std.testing.expectEqual(snapshot.dropped_total, retry.dropped_total);

    var drained: [CAP]Event = undefined;
    try std.testing.expectEqual(@as(usize, CAP), q.drainInto(&drained));
    try std.testing.expectEqual(@as(usize, 0), q.pending());
    try std.testing.expectEqual(@as(u64, 3), q.takeDropped());
    try std.testing.expectEqual(@as(u64, 0), q.takeDropped());
    const after_legacy = q.reliableInto(0, &reliable_buf);
    try std.testing.expectEqual(@as(u64, CAP + 3), after_legacy.dropped_total);
    try std.testing.expectEqual(snapshot.cursor, after_legacy.cursor);
}

test "legacy drain advances reliable loss and old acknowledgements cannot regress" {
    var q = Queue.init();
    q.push(Event.init("seen", .click, .none));
    var reliable_buf: [CAP]Event = undefined;
    const first = q.reliableInto(0, &reliable_buf);
    try std.testing.expectEqual(@as(u64, 1), first.cursor);

    // This event was never acknowledged by the reliable reader, but legacy
    // semantics deliberately consume the complete shared queue.
    q.push(Event.init("legacy-only", .click, .none));
    var legacy_buf: [CAP]Event = undefined;
    try std.testing.expectEqual(@as(usize, 2), q.drainInto(&legacy_buf));
    try std.testing.expectEqual(@as(u64, 2), q.reliable_cursor);

    // The prior reliable cursor is no longer valid in this epoch. Sequence
    // numbers never rewind, so presenting it cannot erase the fresh event.
    q.push(Event.init("fresh", .click, .none));
    const switched = q.reliableInto(first.cursor, &reliable_buf);
    try std.testing.expectEqual(@as(usize, 1), switched.count);
    try std.testing.expectEqualStrings("fresh", reliable_buf[0].id());
    try std.testing.expectEqual(@as(u64, 3), switched.cursor);
    try std.testing.expectEqual(@as(u64, 2), switched.dropped_total);
}

test "sequence exhaustion drops rather than wrapping into an ambiguous epoch" {
    var q = Queue.init();
    q.next_seq = std.math.maxInt(u64);
    q.push(Event.init("last", .click, .none));
    q.push(Event.init("wrapped", .click, .none));
    try std.testing.expectEqual(@as(usize, 1), q.pending());
    var buf: [CAP]Event = undefined;
    const snapshot = q.reliableInto(0, &buf);
    try std.testing.expectEqual(std.math.maxInt(u64), snapshot.cursor);
    try std.testing.expectEqual(std.math.maxInt(u64), buf[0].seq);
    try std.testing.expectEqual(@as(u64, 1), snapshot.dropped_total);
}
