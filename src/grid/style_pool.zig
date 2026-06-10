//! Interned style pool.
//!
//! Cells carry a `style_ref: u16` index instead of embedding
//! foreground / background / attribute fields. Runs of consecutive
//! cells almost always share style, so dedup gets ~98 %.
//!
//! Intern is a hash lookup on a canonical packed key, with a
//! last-returned-index fast path for the "same style, many cells"
//! pattern that dominates real output.

const std = @import("std");

pub const Color = union(enum) {
    /// Use the terminal's default fg/bg.
    default: void,
    /// Indexed palette colour (0..255).
    palette: u8,
    /// Direct truecolor (24-bit).
    rgb: Rgb,

    pub const Rgb = struct { r: u8, g: u8, b: u8 };

    pub fn equal(a: Color, b: Color) bool {
        const TagA = @intFromEnum(a);
        const TagB = @intFromEnum(b);
        if (TagA != TagB) return false;
        return switch (a) {
            .default => true,
            .palette => |p| p == b.palette,
            .rgb => |c| c.r == b.rgb.r and c.g == b.rgb.g and c.b == b.rgb.b,
        };
    }
};

pub const Attrs = packed struct(u16) {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    fast_blink: bool = false,
    reverse: bool = false,
    invisible: bool = false,
    strikethrough: bool = false,
    double_underline: bool = false,
    curly_underline: bool = false,
    overline: bool = false,
    _pad: u4 = 0,
};

pub const Entry = struct {
    fg: Color = .default,
    bg: Color = .default,
    /// SGR 58/59 underline (decoration) colour. `.default` = follow
    /// the cell's fg, the pre-SGR-58 behaviour.
    underline_color: Color = .default,
    attrs: Attrs = .{},

    pub fn equal(a: Entry, b: Entry) bool {
        if (!Color.equal(a.fg, b.fg)) return false;
        if (!Color.equal(a.bg, b.bg)) return false;
        if (!Color.equal(a.underline_color, b.underline_color)) return false;
        return @as(u16, @bitCast(a.attrs)) == @as(u16, @bitCast(b.attrs));
    }
};

/// Canonical packed form of a Color — unions can't be hashed raw
/// (inactive payload bytes are undefined).
fn colorKey(col: Color) u32 {
    return switch (col) {
        .default => 0,
        .palette => |p| 0x0100_0000 | @as(u32, p),
        .rgb => |c| 0x0200_0000 | (@as(u32, c.r) << 16) | (@as(u32, c.g) << 8) | c.b,
    };
}

fn entryKey(e: Entry) u128 {
    return (@as(u128, colorKey(e.fg)) << 96) |
        (@as(u128, colorKey(e.bg)) << 64) |
        (@as(u128, colorKey(e.underline_color)) << 32) |
        @as(u16, @bitCast(e.attrs));
}

pub const Pool = struct {
    entries: std.ArrayList(Entry) = .empty,
    /// entryKey → index, kept in lockstep with `entries`.
    index: std.AutoHashMapUnmanaged(u128, u16) = .empty,
    /// Last-returned index — most call sites re-intern the same entry
    /// many times in a row (a typical TUI emits `\x1b[31m` once and
    /// then prints many cells). One compare wins those without
    /// touching the rest of the array.
    last_idx: u16 = 0,
    allocator: std.mem.Allocator,

    pub const default_index: u16 = 0;

    pub fn init(allocator: std.mem.Allocator) !Pool {
        var p = Pool{ .allocator = allocator };
        errdefer p.deinit();
        try p.entries.append(allocator, .{}); // index 0 = default
        try p.index.put(allocator, entryKey(.{}), 0);
        return p;
    }

    pub fn deinit(self: *Pool) void {
        self.entries.deinit(self.allocator);
        self.index.deinit(self.allocator);
    }

    /// Returns the index for an existing entry, or appends a new one.
    pub fn intern(self: *Pool, e: Entry) !u16 {
        if (self.last_idx < self.entries.items.len and
            Entry.equal(self.entries.items[self.last_idx], e))
        {
            return self.last_idx;
        }
        if (self.index.get(entryKey(e))) |i| {
            self.last_idx = i;
            return i;
        }
        if (self.entries.items.len >= 0xFFFF) return error.PoolFull;
        const idx: u16 = @intCast(self.entries.items.len);
        try self.entries.append(self.allocator, e);
        self.index.put(self.allocator, entryKey(e), idx) catch |err| {
            _ = self.entries.pop();
            return err;
        };
        self.last_idx = idx;
        return idx;
    }

    pub fn get(self: *const Pool, idx: u16) Entry {
        return self.entries.items[idx];
    }

    /// Sentinel index used by `Screen.compactStylePool` to mark an
    /// unreferenced (collectable) entry. The pool can hold at most
    /// 0xFFFF entries (intern errors at that length), so 0xFFFF is
    /// never a live index and is safe as "unused".
    pub const unused_index: u16 = 0xFFFF;

    /// Swap in a freshly compacted entry table. The caller
    /// (`Screen.compactStylePool`) has already remapped every live
    /// `style_ref` / `cur_style` / `saved_style` to the new indices.
    pub fn replaceEntries(self: *Pool, new_entries: std.ArrayList(Entry)) void {
        self.entries.deinit(self.allocator);
        self.entries = new_entries;
        self.last_idx = 0;
        // Rebuild the hash index in lockstep. On OOM fall back to a
        // partially-filled index: misses just re-append, which only
        // costs duplicate entries, never wrong lookups.
        self.index.clearRetainingCapacity();
        for (self.entries.items, 0..) |e, i| {
            self.index.put(self.allocator, entryKey(e), @intCast(i)) catch break;
        }
    }
};

test "default is index 0" {
    var p = try Pool.init(std.testing.allocator);
    defer p.deinit();
    try std.testing.expectEqual(@as(u16, 0), Pool.default_index);
    const e = p.get(0);
    try std.testing.expect(Color.equal(e.fg, .default));
    try std.testing.expect(Color.equal(e.bg, .default));
}

test "intern dedups" {
    var p = try Pool.init(std.testing.allocator);
    defer p.deinit();
    const e1 = Entry{ .fg = .{ .palette = 1 } };
    const e2 = Entry{ .fg = .{ .palette = 1 } };
    const e3 = Entry{ .fg = .{ .palette = 2 } };
    const idx1 = try p.intern(e1);
    const idx2 = try p.intern(e2);
    const idx3 = try p.intern(e3);
    try std.testing.expectEqual(idx1, idx2);
    try std.testing.expect(idx1 != idx3);
}

test "intern truecolor" {
    var p = try Pool.init(std.testing.allocator);
    defer p.deinit();
    const e = Entry{ .fg = .{ .rgb = .{ .r = 255, .g = 128, .b = 0 } } };
    const i = try p.intern(e);
    const r = p.get(i);
    try std.testing.expect(Color.equal(r.fg, e.fg));
}
