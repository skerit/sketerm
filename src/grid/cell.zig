//! Cell — 8-byte fixed-size grid cell.
//!
//! `extern struct` (C ABI), not `packed struct` — `packed` in Zig
//! has bitfield semantics; we want byte-level layout. The comptime
//! assert locks the size.
//!
//! Heavy data (per-cell image refs, OSC 8 link ids, multi-codepoint
//! grapheme clusters) lives in side tables keyed by cell coord, NOT
//! embedded in the Cell struct. See architecture.md D3.

const std = @import("std");

pub const Cell = extern struct {
    /// Unicode codepoint, or ClusterId in `rune_pool` when
    /// `flags.is_cluster` is set. 0 = blank.
    rune: u32 = 0,

    /// Index into `StylePool`. 0 = default style.
    style_ref: u16 = 0,

    /// Bit-packed flags. See `Flags` for layout.
    flags: u8 = 0,

    /// Reserved for future use (alignment/padding to 8 bytes).
    reserved: u8 = 0,
};

comptime {
    std.debug.assert(@sizeOf(Cell) == 8);
    std.debug.assert(@alignOf(Cell) == 4);
}

pub const Flags = packed struct(u8) {
    /// Wide cell, left half. Cell stores the actual rune.
    is_wide_left: bool = false,
    /// Wide cell, right half. Placeholder; real rune is in left neighbour.
    is_wide_cont: bool = false,
    /// has OSC 8 hyperlink id in side table.
    has_link: bool = false,
    /// covered by an image placement (see image_store).
    has_image: bool = false,
    /// `rune` is a ClusterId, look up grapheme cluster in rune_pool.
    is_cluster: bool = false,
    _pad: u3 = 0,
};

pub fn flagsFromU8(v: u8) Flags {
    return @bitCast(v);
}

pub fn flagsToU8(f: Flags) u8 {
    return @bitCast(f);
}

test "Cell is 8 bytes" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Cell));
}

test "Cell default is blank" {
    const c: Cell = .{};
    try std.testing.expectEqual(@as(u32, 0), c.rune);
    try std.testing.expectEqual(@as(u16, 0), c.style_ref);
    try std.testing.expectEqual(@as(u8, 0), c.flags);
}

test "Flags pack/unpack" {
    const f = Flags{ .has_link = true, .has_image = true };
    const u = flagsToU8(f);
    const f2 = flagsFromU8(u);
    try std.testing.expectEqual(true, f2.has_link);
    try std.testing.expectEqual(true, f2.has_image);
    try std.testing.expectEqual(false, f2.is_wide_left);
}
