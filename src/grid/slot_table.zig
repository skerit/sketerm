//! Interned values behind stable u16 IDs: the one table behind every
//! side table a style entry names by ID (cell-border sets, overstrike
//! layer lists).
//!
//! ID 0 is the empty value and is never stored; ID `n` is slot `n - 1`.
//! Slots never move, so collecting never renumbers a survivor; a freed
//! slot holds the empty value and sits on `free` until an intern reuses
//! it. `T` must be canonical (equal values have equal bytes, no padding):
//! its bytes are its identity for hashing and equality.

const std = @import("std");

pub fn SlotTable(comptime T: type, comptime empty: T) type {
    comptime {
        if (@sizeOf(T) * 8 != @bitSizeOf(T)) @compileError("SlotTable values must have no padding bits");
    }
    return struct {
        const Self = @This();

        slots: std.ArrayList(T) = .empty,
        index: std.HashMapUnmanaged(T, u16, Context, std.hash_map.default_max_load_percentage) = .empty,
        free: std.ArrayList(u16) = .empty,

        /// IDs are u16 with 0 reserved for the empty value.
        pub const max_slots: usize = 0xFFFF - 1;

        pub const Context = struct {
            pub fn hash(_: Context, v: T) u64 {
                return std.hash.Wyhash.hash(0, std.mem.asBytes(&v));
            }

            pub fn eql(_: Context, a: T, b: T) bool {
                return std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));
            }
        };

        pub fn isEmpty(v: T) bool {
            return std.mem.eql(u8, std.mem.asBytes(&v), std.mem.asBytes(&empty));
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.slots.deinit(allocator);
            self.index.deinit(allocator);
            self.free.deinit(allocator);
        }

        /// The value of `id`; an unknown ID reads as empty.
        pub fn get(self: *const Self, id: u16) T {
            if (id == 0 or id > self.slots.items.len) return empty;
            return self.slots.items[id - 1];
        }

        /// Whether any live value exists; renderers bail on false.
        pub fn hasLive(self: *const Self) bool {
            return self.slots.items.len > self.free.items.len;
        }

        pub fn contains(self: *const Self, v: T) bool {
            return self.index.contains(v);
        }

        /// The ID of `v`, interning it if new. The ID is unrooted until a
        /// style entry holds it: `collect` frees it before then.
        pub fn intern(self: *Self, allocator: std.mem.Allocator, v: T) !u16 {
            if (isEmpty(v)) return 0;
            if (self.index.get(v)) |id| return id;
            const reuse = self.free.items.len > 0;
            if (!reuse) {
                if (self.slots.items.len >= max_slots) return error.PoolFull;
                try self.slots.ensureUnusedCapacity(allocator, 1);
            }
            const id: u16 = if (reuse)
                self.free.items[self.free.items.len - 1]
            else
                @intCast(self.slots.items.len + 1);
            try self.index.put(allocator, v, id);
            if (reuse) {
                _ = self.free.pop();
                self.slots.items[id - 1] = v;
            } else {
                self.slots.appendAssumeCapacity(v);
            }
            return id;
        }

        /// Return an unrooted ID's slot to the free list.
        pub fn release(self: *Self, allocator: std.mem.Allocator, id: u16) void {
            if (id == 0 or id > self.slots.items.len) return;
            const slot = &self.slots.items[id - 1];
            // Without room on the free list the value stays interned as
            // an orphan, which the next `collect` frees.
            self.free.append(allocator, id) catch return;
            _ = self.index.remove(slot.*);
            slot.* = empty;
        }

        /// Free every slot `used` (indexed by ID, length at least
        /// `slots.len + 1`) does not mark. Callers run it only when no
        /// unrooted ID from `intern` is still in hand.
        pub fn collect(self: *Self, allocator: std.mem.Allocator, used: []const bool) void {
            self.free.ensureTotalCapacity(allocator, self.slots.items.len) catch return;
            self.free.clearRetainingCapacity();
            for (self.slots.items, 1..) |*slot, id| {
                if (used[id]) continue;
                if (!isEmpty(slot.*)) _ = self.index.remove(slot.*);
                slot.* = empty;
                self.free.appendAssumeCapacity(@intCast(id));
            }
        }

        /// Fill `index` and `free` for `slots` without taking them, so a
        /// caller can still own them on error. Rejects what the interning
        /// paths could not have produced (too many slots, a duplicate),
        /// which only untrusted input can hold.
        pub fn indexSlots(self: *Self, allocator: std.mem.Allocator, slots: []const T) !void {
            if (slots.len > max_slots) return error.InvalidTable;
            for (slots, 1..) |v, id| {
                if (isEmpty(v)) {
                    try self.free.append(allocator, @intCast(id));
                    continue;
                }
                const slot = try self.index.getOrPut(allocator, v);
                if (slot.found_existing) return error.InvalidTable;
                slot.value_ptr.* = @intCast(id);
            }
        }

        /// Whether a style entry may name `id` in a table of `slots`.
        pub fn validRef(slots: []const T, id: u16) bool {
            return id == 0 or (id <= slots.len and !isEmpty(slots[id - 1]));
        }
    };
}

const testing = std.testing;

test "intern dedups, release recycles, collect keeps used slots in place" {
    const Table = SlotTable(u32, 0);
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 0), try t.intern(testing.allocator, 0));
    const a = try t.intern(testing.allocator, 7);
    const b = try t.intern(testing.allocator, 9);
    try testing.expectEqual(a, try t.intern(testing.allocator, 7));
    try testing.expect(a != b);
    t.release(testing.allocator, a);
    try testing.expectEqual(@as(u32, 0), t.get(a));
    try testing.expectEqual(a, try t.intern(testing.allocator, 11));
    var used = [_]bool{ false, false, true };
    t.collect(testing.allocator, &used);
    try testing.expectEqual(@as(u32, 9), t.get(b));
    try testing.expectEqual(@as(u32, 0), t.get(a));
    try testing.expect(t.hasLive());
    used[2] = false;
    t.collect(testing.allocator, &used);
    try testing.expect(!t.hasLive());
}

test "indexSlots rejects duplicates and validRef rejects empty slots" {
    const Table = SlotTable(u32, 0);
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    try testing.expectError(error.InvalidTable, t.indexSlots(testing.allocator, &.{ 3, 0, 3 }));
    var ok: Table = .{};
    defer ok.deinit(testing.allocator);
    try ok.indexSlots(testing.allocator, &.{ 3, 0, 4 });
    try testing.expect(Table.validRef(&.{ 3, 0, 4 }, 3));
    try testing.expect(!Table.validRef(&.{ 3, 0, 4 }, 2));
    try testing.expect(!Table.validRef(&.{ 3, 0, 4 }, 4));
}
