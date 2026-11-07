//! Re-sorting a list that is usually still in order.

const std = @import("std");

/// Out-of-place trailing elements inserted one by one; past this many a
/// full sort is cheaper than the element moves.
pub const INSERT_MAX: usize = 16;

/// Stable sort, the same result as `std.mem.sort`, that costs n-1
/// comparisons when `items` is already in order and one binary-searched
/// insertion per element when only a short tail is out of place (entries
/// appended since the last sort); anything else falls back to the full sort.
pub fn sort(comptime T: type, items: []T, context: anytype, comptime lessThan: fn (@TypeOf(context), T, T) bool) void {
    var p: usize = 1;
    while (p < items.len and !lessThan(context, items[p], items[p - 1])) p += 1;
    if (p >= items.len) return;
    if (items.len - p > INSERT_MAX) return std.mem.sort(T, items, context, lessThan);
    var i = p;
    while (i < items.len) : (i += 1) {
        const x = items[i];
        // After every element it does not precede: equal ones keep their order.
        var lo: usize = 0;
        var hi: usize = i;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (lessThan(context, x, items[mid])) hi = mid else lo = mid + 1;
        }
        std.mem.copyBackwards(T, items[lo + 1 .. i + 1], items[lo..i]);
        items[lo] = x;
    }
}

const Pair = struct { key: u32, seq: u32 };

fn pairLess(_: void, a: Pair, b: Pair) bool {
    return a.key < b.key;
}

test "presorted.sort matches std.mem.sort, ties included, on every shape" {
    const t = std.testing;
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const r = prng.random();
    var a: [300]Pair = undefined;
    var b: [300]Pair = undefined;
    for (0..400) |round| {
        const n = r.uintLessThan(usize, a.len + 1);
        // Few distinct keys so ties are common and stability is tested.
        for (a[0..n], 0..) |*x, i| x.* = .{ .key = r.uintLessThan(u32, 40), .seq = @intCast(i) };
        switch (round % 4) {
            // A sorted run with a short (or long) appended tail.
            0, 1 => {
                const tail = if (round % 4 == 0) r.uintLessThan(usize, INSERT_MAX + 1) else r.uintLessThan(usize, n + 1);
                std.mem.sort(Pair, a[0 .. n - @min(tail, n)], {}, pairLess);
            },
            2 => std.mem.sort(Pair, a[0..n], {}, pairLess),
            else => {},
        }
        @memcpy(b[0..n], a[0..n]);
        sort(Pair, a[0..n], {}, pairLess);
        std.mem.sort(Pair, b[0..n], {}, pairLess);
        try t.expectEqualSlices(Pair, b[0..n], a[0..n]);
    }
}

test "presorted.sort does no comparisons beyond one pass over a sorted list" {
    const Counting = struct {
        calls: *usize,
        fn lt(ctx: @This(), x: u32, y: u32) bool {
            ctx.calls.* += 1;
            return x < y;
        }
    };
    var calls: usize = 0;
    var items = [_]u32{ 1, 2, 2, 3, 5, 8, 13 };
    sort(u32, &items, Counting{ .calls = &calls }, Counting.lt);
    try std.testing.expectEqual(items.len - 1, calls);
}
