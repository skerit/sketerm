//! Bounded, thread-safe event queue between a rendered panel and the
//! MCP layer.
//!
//! Pure Zig + libc (`util/clock.zig`, `nanosleep`), NO GTK/GLib —
//! lives in both test roots. Events are flat fixed-size structs so
//! `push` can never fail and never allocates (it runs inside GTK
//! signal handlers). Zig 0.16 has no std mutex/condvar (std.Io.Mutex
//! wants an Io instance) and the core cimport set has no pthread.h,
//! so synchronization is the repo's spinlock pattern (see
//! image_decoder.zig) — every critical section here is a few dozen
//! instructions, which is exactly what a spinlock is for.
//!
//! Threading contract for the next agent (`ui_wait_event`):
//! - `push` is called on the GTK main thread by the renderer.
//! - `waitAny(timeout_ms)` BLOCKS (bounded 10ms poll granularity) and
//!   therefore must NEVER be called on the GTK main thread. It exists
//!   for a bridge thread that is allowed to sleep; an MCP process
//!   blocking on its own socket read does not need it.
//! - A main-loop host that must not block instead sets `on_push`,
//!   which fires on the pushing (main) thread after the lock is
//!   released — arm an idle / complete a pending IPC reply from
//!   there, then drain with `drainInto`. This is the zero-latency
//!   path; `waitAny` is the convenience fallback.
//! - `close()` makes further waits return immediately (within one
//!   poll tick) and further pushes no-ops; pending events stay
//!   drainable. It is how panel teardown unblocks a pending
//!   `ui_wait_event`. Idempotent.

const std = @import("std");
const c = @import("../../c.zig").c;
const clock = @import("../../util/clock.zig");

/// Longest component id (mirrored by doc.zig's id validation).
pub const MAX_ID: usize = 64;
/// Longest text payload an event carries (select options and button
/// action names are bounded to this at document parse time).
pub const MAX_TEXT: usize = 128;
/// Ring capacity. Full queue drops the OLDEST event (the assistant
/// prefers fresh interactions over stale ones) and counts the drop.
pub const CAP: usize = 64;

/// waitAny poll granularity. Human-interaction latency tolerance is
/// orders of magnitude above this; the on_push hook exists for hosts
/// that need instant delivery.
const POLL_NS: c_long = 10 * std.time.ns_per_ms;

pub const Kind = enum { click, change };

pub const Value = union(enum) {
    none: void,
    number: f64,
    boolean: bool,
    text: Text,

    pub const Text = struct {
        buf: [MAX_TEXT]u8 = undefined,
        len: u8 = 0,

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

fn sleepBriefly() void {
    var ts: c.struct_timespec = .{ .tv_sec = 0, .tv_nsec = POLL_NS };
    _ = c.nanosleep(&ts, null);
}

pub const Queue = struct {
    lock: std.atomic.Value(u8) = .init(0),
    ring: [CAP]Event = undefined,
    head: usize = 0,
    count: usize = 0,
    dropped: u64 = 0,
    closed: bool = false,
    /// Fired on the pushing thread, after the lock is released, once
    /// per successful push. For main-loop hosts that cannot block.
    on_push: ?*const fn (?*anyopaque) void = null,
    on_push_ctx: ?*anyopaque = null,

    pub fn init() Queue {
        return .{};
    }

    fn acquire(self: *Queue) void {
        while (self.lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn release(self: *Queue) void {
        self.lock.store(0, .release);
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
                if (last.kind == .change and std.mem.eql(u8, last.id(), ev.id())) {
                    last.* = ev;
                    coalesced = true;
                }
            }
            if (!coalesced) {
                if (self.count == CAP) {
                    self.head = (self.head + 1) % CAP;
                    self.count -= 1;
                    self.dropped += 1;
                }
                self.ring[(self.head + self.count) % CAP] = ev;
                self.count += 1;
            }
            notify = true;
        }
        if (notify) {
            if (self.on_push) |cb| cb(self.on_push_ctx);
        }
    }

    /// Oldest pending event, or null. Non-blocking; main-thread safe.
    pub fn tryPop(self: *Queue) ?Event {
        self.acquire();
        defer self.release();
        if (self.count == 0) return null;
        const ev = self.ring[self.head];
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
            self.head = (self.head + 1) % CAP;
            self.count -= 1;
        }
        return n;
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
