//! Allocators for allocation-failure tests.

const std = @import("std");

/// `std.testing.allocator`, but never resizing in place: every growth is a
/// fresh allocation that `FailingAllocator` counts and can fail.
///
/// Zig 0.17's testing allocator (`SafeAllocator`) grows in place whenever the
/// heap layout allows, so a growth may skip the allocation a failure index
/// targets and the count varies between runs (`checkAllAllocationFailures`
/// then reports `NondeterministicMemoryUsage`). Memory from here may be
/// freed through `std.testing.allocator` and vice versa.
pub const no_resize: std.mem.Allocator = .{
    .ptr = undefined,
    .vtable = &.{
        .alloc = alloc,
        .resize = std.mem.Allocator.noResize,
        .remap = std.mem.Allocator.noRemap,
        .free = free,
    },
};

fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    return std.testing.allocator.rawAlloc(len, alignment, ret_addr);
}

fn free(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    std.testing.allocator.rawFree(memory, alignment, ret_addr);
}

test "no_resize turns every growth into a counted allocation" {
    var failing = std.testing.FailingAllocator.init(no_resize, .{});
    const a = failing.allocator();
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(a);
    for (0..4096) |i| try list.append(a, @truncate(i));
    try std.testing.expect(failing.alloc_index > 1);
}
