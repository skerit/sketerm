//! Thin wrapper over libfribidi (UAX #9 implementation) used by the
//! renderer for line-level bidi resolution.
//!
//! We don't try to expose the full fribidi surface — only what we
//! need: per-cell embedding levels for a line of codepoints, and a
//! visual-order remap so the renderer can reverse RTL runs.

const std = @import("std");
const c = @import("../c.zig").c;

pub const Direction = enum { auto, ltr, rtl };

/// Compute embedding levels for a line of codepoints. `levels` must
/// have at least `cps.len` elements; on return `levels[i]` is the
/// embedding level for `cps[i]` (even = LTR, odd = RTL).
///
/// Returns the resolved paragraph direction. `dir == .auto` lets
/// fribidi sniff it from the contents.
pub fn lineLevels(cps: []const u32, levels: []u8, dir: Direction) Direction {
    if (cps.len == 0) return .ltr;
    std.debug.assert(levels.len >= cps.len);

    const n: c.FriBidiStrIndex = @intCast(cps.len);

    // Fribidi expects FriBidiChar (u32), FriBidiCharType, FriBidiLevel.
    // It mutates the type buffer (resolves neutrals, etc) — we keep
    // that internal.
    const types = std.heap.c_allocator.alloc(c.FriBidiCharType, cps.len) catch return .ltr;
    defer std.heap.c_allocator.free(types);
    const brackets = std.heap.c_allocator.alloc(c.FriBidiBracketType, cps.len) catch return .ltr;
    defer std.heap.c_allocator.free(brackets);

    // FriBidiChar is u32 — same shape as our cps slice.
    c.fribidi_get_bidi_types(@ptrCast(cps.ptr), n, types.ptr);
    c.fribidi_get_bracket_types(@ptrCast(cps.ptr), n, types.ptr, brackets.ptr);

    var pbase: c.FriBidiParType = switch (dir) {
        .auto => @bitCast(@as(c_int, c.FRIBIDI_PAR_ON)),
        .ltr => @bitCast(@as(c_int, c.FRIBIDI_PAR_LTR)),
        .rtl => @bitCast(@as(c_int, c.FRIBIDI_PAR_RTL)),
    };

    const out_levels = std.heap.c_allocator.alloc(c.FriBidiLevel, cps.len) catch return .ltr;
    defer std.heap.c_allocator.free(out_levels);

    _ = c.fribidi_get_par_embedding_levels_ex(
        types.ptr,
        brackets.ptr,
        n,
        &pbase,
        out_levels.ptr,
    );

    var i: usize = 0;
    while (i < cps.len) : (i += 1) {
        levels[i] = @intCast(out_levels[i]);
    }

    // Resolved paragraph direction: even = LTR, odd = RTL.
    const par_int: c_int = @bitCast(pbase);
    const is_rtl = par_int == c.FRIBIDI_PAR_RTL or par_int == c.FRIBIDI_PAR_WRTL;
    return if (is_rtl) .rtl else .ltr;
}

/// Reorder `levels`/`indices` to visual order in-place. Caller passes
/// `indices[i] = i` initially; on return `indices` describes the
/// visual run order: `cells[indices[v]]` is the cell that should
/// appear at visual column v. Implementation: iterative mirror-of
/// odd-level runs, per UAX #9 line ordering.
pub fn levelsToVisualOrder(levels: []u8, indices: []usize) void {
    std.debug.assert(levels.len == indices.len);
    if (levels.len == 0) return;

    // Find max level.
    var max_level: u8 = 0;
    for (levels) |l| if (l > max_level) {
        max_level = l;
    };

    // Reverse runs at each odd level from max down to 1.
    var lvl: u8 = max_level;
    while (lvl >= 1) : (lvl -= 1) {
        var i: usize = 0;
        while (i < levels.len) {
            if (levels[i] < lvl) {
                i += 1;
                continue;
            }
            // Find the end of the run at level >= lvl.
            var j = i;
            while (j < levels.len and levels[j] >= lvl) j += 1;
            // Reverse [i, j) in indices.
            var lo = i;
            var hi = j - 1;
            while (lo < hi) {
                const tmp = indices[lo];
                indices[lo] = indices[hi];
                indices[hi] = tmp;
                lo += 1;
                hi -= 1;
            }
            i = j;
        }
        if (lvl == 1) break;
    }
}

test "all-LTR levels are 0" {
    const cps = [_]u32{ 'h', 'i' };
    var levels: [2]u8 = undefined;
    const dir = lineLevels(&cps, &levels, .auto);
    try std.testing.expectEqual(Direction.ltr, dir);
    try std.testing.expectEqual(@as(u8, 0), levels[0]);
    try std.testing.expectEqual(@as(u8, 0), levels[1]);
}

test "Hebrew line resolves RTL" {
    // Aleph, Bet, Gimel
    const cps = [_]u32{ 0x05D0, 0x05D1, 0x05D2 };
    var levels: [3]u8 = undefined;
    const dir = lineLevels(&cps, &levels, .auto);
    try std.testing.expectEqual(Direction.rtl, dir);
    try std.testing.expect(levels[0] >= 1);
}

test "visual order reverses an RTL run inside LTR text" {
    // Cells: L L R R R L L  →  L L R R R L L  visually with RTL run reversed
    // levels:  0 0 1 1 1 0 0
    var levels = [_]u8{ 0, 0, 1, 1, 1, 0, 0 };
    var indices: [7]usize = undefined;
    for (&indices, 0..) |*ix, i| ix.* = i;
    levelsToVisualOrder(&levels, &indices);
    // Expect indices: 0 1 4 3 2 5 6
    try std.testing.expectEqual(@as(usize, 0), indices[0]);
    try std.testing.expectEqual(@as(usize, 1), indices[1]);
    try std.testing.expectEqual(@as(usize, 4), indices[2]);
    try std.testing.expectEqual(@as(usize, 3), indices[3]);
    try std.testing.expectEqual(@as(usize, 2), indices[4]);
    try std.testing.expectEqual(@as(usize, 5), indices[5]);
    try std.testing.expectEqual(@as(usize, 6), indices[6]);
}

test "logical col 0 maps to last visual col on pure-RTL line" {
    // Three Hebrew letters: aleph, bet, gimel.
    var levels = [_]u8{ 1, 1, 1 };
    var indices: [3]usize = undefined;
    for (&indices, 0..) |*ix, i| ix.* = i;
    levelsToVisualOrder(&levels, &indices);
    // After reverse: visual[0]=2, visual[1]=1, visual[2]=0.
    // Logical 0 (aleph) appears at visual 2.
    var visual_col: usize = 0;
    for (indices, 0..) |logical, vis| {
        if (logical == 0) {
            visual_col = vis;
            break;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), visual_col);
}
