//! The repo's one spinlock.
//!
//! Zig 0.16 has no `std.Thread.Mutex`/`Condition` — they moved behind
//! an `Io` instance — and `pthread.h` is deliberately absent from
//! `vendor/cimport_core.h` so the mux set stays musl-clean. That leaves
//! an atomic guard plus `spinLoopHint`, and it is the right primitive
//! here anyway: every critical section this locks is a few dozen
//! instructions over fixed-size storage (a ring push, a table lookup, a
//! counter update), which is exactly what a spinlock is for.
//!
//! **A spinlock is only correct for a critical section that is short and
//! never blocks.** Nothing held across an allocation, a syscall that can
//! sleep, file or socket IO, an unbounded loop, or a call into GTK/CEF
//! belongs here — a waiter burns a core for the whole duration, and on a
//! single core it can deadlock outright. If a critical section ever
//! genuinely needs to block, the right fix is a real condvar (adding
//! `pthread.h` to `vendor/cimport_core.h`, musl-clean), not a longer
//! spin.
//!
//! Pure `std`: no libc, no GTK, usable from every dependency set.

const std = @import("std");

/// Non-recursive test-and-set lock. Locking a lock this thread already
/// holds hangs forever; there is no owner tracking to detect it.
pub const SpinLock = struct {
    guard: std.atomic.Value(bool) = .init(false),

    pub const init: SpinLock = .{};

    pub fn lock(self: *SpinLock) void {
        while (self.guard.cmpxchgWeak(false, true, .acquire, .monotonic) != null)
            std.atomic.spinLoopHint();
    }

    /// Take the lock if it is free. Never spins.
    pub fn tryLock(self: *SpinLock) bool {
        return self.guard.cmpxchgStrong(false, true, .acquire, .monotonic) == null;
    }

    pub fn unlock(self: *SpinLock) void {
        self.guard.store(false, .release);
    }
};

const t = std.testing;

test "lock/unlock round-trips" {
    var l: SpinLock = .init;
    l.lock();
    l.unlock();
    l.lock();
    l.unlock();
}

test "tryLock fails while held and succeeds once released" {
    var l: SpinLock = .{};
    try t.expect(l.tryLock());
    try t.expect(!l.tryLock());
    l.unlock();
    try t.expect(l.tryLock());
    l.unlock();
}

test "lock serializes concurrent increments" {
    const Shared = struct {
        lock: SpinLock = .{},
        counter: u64 = 0,

        fn bump(self: *@This(), times: u64) void {
            var i: u64 = 0;
            while (i < times) : (i += 1) {
                self.lock.lock();
                defer self.lock.unlock();
                // Read-modify-write with no atomics of its own: only the
                // lock can make this come out right.
                const next = self.counter + 1;
                self.counter = next;
            }
        }
    };

    var shared: Shared = .{};
    const per_thread: u64 = 20_000;
    const a = try std.Thread.spawn(.{}, Shared.bump, .{ &shared, per_thread });
    const b = try std.Thread.spawn(.{}, Shared.bump, .{ &shared, per_thread });
    a.join();
    b.join();
    try t.expectEqual(per_thread * 2, shared.counter);
}
