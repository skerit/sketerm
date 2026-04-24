//! Interned style pool.
//!
//! Cells carry a `style_ref: u16` index instead of embedding
//! foreground / background / attribute fields. Runs of consecutive
//! cells almost always share style, so dedup gets ~98 %.
//!
//! v1 uses a linear scan for intern. Add a hash if profiling
//! shows pain.

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
    attrs: Attrs = .{},

    pub fn equal(a: Entry, b: Entry) bool {
        if (!Color.equal(a.fg, b.fg)) return false;
        if (!Color.equal(a.bg, b.bg)) return false;
        return @as(u16, @bitCast(a.attrs)) == @as(u16, @bitCast(b.attrs));
    }
};

pub const Pool = struct {
    entries: std.ArrayList(Entry) = .{},
    allocator: std.mem.Allocator,

    pub const default_index: u16 = 0;

    pub fn init(allocator: std.mem.Allocator) !Pool {
        var p = Pool{ .allocator = allocator };
        try p.entries.append(allocator, .{}); // index 0 = default
        return p;
    }

    pub fn deinit(self: *Pool) void {
        self.entries.deinit(self.allocator);
    }

    /// Returns the index for an existing entry, or appends a new one.
    pub fn intern(self: *Pool, e: Entry) !u16 {
        for (self.entries.items, 0..) |existing, i| {
            if (Entry.equal(existing, e)) return @intCast(i);
        }
        if (self.entries.items.len >= 0xFFFF) return error.PoolFull;
        const idx = self.entries.items.len;
        try self.entries.append(self.allocator, e);
        return @intCast(idx);
    }

    pub fn get(self: *const Pool, idx: u16) Entry {
        return self.entries.items[idx];
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
