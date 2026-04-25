//! SPSC lock-free ring buffer.
//!
//! One producer (the PTY worker thread) and one consumer (the GTK
//! main thread). Uses release/acquire ordering on head/tail.
//!
//! Capacity is a power of two so wrap-around is a bit-mask.

const std = @import("std");

pub fn Ring(comptime T: type, comptime capacity: usize) type {
    if (capacity == 0 or (capacity & (capacity - 1)) != 0) {
        @compileError("Ring capacity must be a non-zero power of two");
    }
    return struct {
        const Self = @This();
        const mask: usize = capacity - 1;

        items: [capacity]T = undefined,
        // Producer side advances head; consumer side advances tail.
        // Both monotonically increasing — wrap is via &mask on access.
        head: std.atomic.Value(usize) align(64) = std.atomic.Value(usize).init(0),
        tail: std.atomic.Value(usize) align(64) = std.atomic.Value(usize).init(0),
        // Consumer-private cache of the last head value seen via
        // acquire. Subsequent pops can compare against this without
        // re-acquiring until they catch up. Cache-line aligned to keep
        // it off the producer's path.
        cached_head: usize align(64) = 0,

        pub fn init() Self {
            return .{};
        }

        pub fn capacityVal() usize {
            return capacity;
        }

        /// Producer side. Returns true if pushed, false if full.
        pub fn push(self: *Self, item: T) bool {
            const head = self.head.load(.monotonic);
            const tail = self.tail.load(.acquire);
            if (head -% tail >= capacity) return false; // full
            self.items[head & mask] = item;
            self.head.store(head +% 1, .release);
            return true;
        }

        /// Consumer side. Returns the next item, or null if empty.
        ///
        /// Uses a private `cached_head` snapshot so a drain loop only
        /// pays one `head.load(.acquire)` per batch instead of one per
        /// item. The cache is refreshed lazily when the consumer
        /// catches up to it.
        pub fn pop(self: *Self) ?T {
            const tail = self.tail.load(.monotonic);
            if (tail == self.cached_head) {
                self.cached_head = self.head.load(.acquire);
                if (tail == self.cached_head) return null;
            }
            const item = self.items[tail & mask];
            self.tail.store(tail +% 1, .release);
            return item;
        }

        pub fn isEmpty(self: *Self) bool {
            return self.head.load(.acquire) == self.tail.load(.acquire);
        }

        pub fn len(self: *Self) usize {
            const head = self.head.load(.acquire);
            const tail = self.tail.load(.acquire);
            return head -% tail;
        }
    };
}

test "ring push/pop ordering" {
    var r = Ring(u32, 4).init();
    try std.testing.expect(r.push(10));
    try std.testing.expect(r.push(20));
    try std.testing.expect(r.push(30));
    try std.testing.expectEqual(@as(?u32, 10), r.pop());
    try std.testing.expectEqual(@as(?u32, 20), r.pop());
    try std.testing.expect(r.push(40));
    try std.testing.expect(r.push(50));
    try std.testing.expectEqual(@as(?u32, 30), r.pop());
    try std.testing.expectEqual(@as(?u32, 40), r.pop());
    try std.testing.expectEqual(@as(?u32, 50), r.pop());
    try std.testing.expectEqual(@as(?u32, null), r.pop());
}

test "ring respects capacity" {
    var r = Ring(u32, 4).init();
    try std.testing.expect(r.push(1));
    try std.testing.expect(r.push(2));
    try std.testing.expect(r.push(3));
    try std.testing.expect(r.push(4));
    try std.testing.expect(!r.push(5)); // full
    _ = r.pop();
    try std.testing.expect(r.push(5));
}
