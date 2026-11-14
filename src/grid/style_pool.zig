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

pub const borders = @import("borders.zig");
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

/// Bit order is wire format: snapshots carry the raw u16, so a new
/// attribute takes a `_pad` bit and never moves an existing one.
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
    dotted_underline: bool = false,
    dashed_underline: bool = false,
    _pad: u2 = 0,

    /// The SGR `4:N` underline styles, numbered as the sub-parameter
    /// numbers them; this enum is the one home of that vocabulary.
    pub const UnderlineStyle = enum(u3) {
        none = 0,
        single = 1,
        double = 2,
        curly = 3,
        dotted = 4,
        dashed = 5,
    };

    /// The one underline style these attrs carry; dotted and dashed
    /// are tested before curly because they carry its bit too.
    pub fn underlineStyle(self: Attrs) UnderlineStyle {
        if (self.dotted_underline) return .dotted;
        if (self.dashed_underline) return .dashed;
        if (self.curly_underline) return .curly;
        if (self.double_underline) return .double;
        if (self.underline) return .single;
        return .none;
    }

    /// Replaces whatever underline style was set; `.none` clears them all.
    /// Dotted and dashed also set the curly bit, so a peer that predates
    /// their bits draws the undercurl it always drew for `4:4` / `4:5`.
    pub fn setUnderlineStyle(self: *Attrs, style: UnderlineStyle) void {
        self.underline = style == .single;
        self.double_underline = style == .double;
        self.curly_underline = style == .curly or style == .dotted or style == .dashed;
        self.dotted_underline = style == .dotted;
        self.dashed_underline = style == .dashed;
    }
};

pub const Entry = struct {
    fg: Color = .default,
    bg: Color = .default,
    /// SGR 58/59 underline (decoration) colour. `.default` = follow
    /// the cell's fg, the pre-SGR-58 behaviour.
    underline_color: Color = .default,
    attrs: Attrs = .{},
    /// The cell's border set: an ID into `Pool.border_sets`, 0 = none.
    /// Living in the style is what makes it the pen: every path that
    /// stamps `cur_style` on a cell (print, BCE erase, DECSC) carries it.
    border: u16 = 0,

    pub fn equal(a: Entry, b: Entry) bool {
        if (!Color.equal(a.fg, b.fg)) return false;
        if (!Color.equal(a.bg, b.bg)) return false;
        if (!Color.equal(a.underline_color, b.underline_color)) return false;
        return a.border == b.border and @as(u16, @bitCast(a.attrs)) == @as(u16, @bitCast(b.attrs));
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
        (@as(u128, e.border) << 16) | @as(u16, @bitCast(e.attrs));
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
    /// Interned border sets: ID `n` is slot `n - 1`, ID 0 the empty set.
    /// Slots are stable, so collecting never renumbers a surviving set;
    /// unused slots hold `borders.empty` and sit on `border_free`.
    border_sets: std.ArrayList(borders.Set) = .empty,
    border_index: std.HashMapUnmanaged(borders.Set, u16, borders.SetContext, std.hash_map.default_max_load_percentage) = .empty,
    border_free: std.ArrayList(u16) = .empty,
    /// Failed reclaims left to skip. A reclaim that frees nothing arms
    /// this, so a pool saturated with live styles is rescanned once per
    /// `reclaim_backoff` failed interns instead of once per cell.
    reclaim_cooldown: u16 = 0,

    pub const reclaim_backoff: u16 = 4096;
    /// IDs are u16 with 0 reserved for the empty set.
    pub const max_border_sets: usize = 0xFFFF - 1;

    pub fn borderSet(self: *const Pool, id: u16) borders.Set {
        if (id == 0 or id > self.border_sets.items.len) return borders.empty;
        return self.border_sets.items[id - 1];
    }

    /// The border set a cell with this style draws.
    pub fn bordersOf(self: *const Pool, style_ref: u16) borders.Set {
        return self.borderSet(self.get(style_ref).border);
    }

    /// Whether any live border set exists; renderers bail on false.
    pub fn hasBorders(self: *const Pool) bool {
        return self.border_sets.items.len > self.border_free.items.len;
    }

    /// The ID of `set`, interning it if new. The ID is unrooted until a
    /// style entry holds it: `collectBorders` frees it before then.
    pub fn internBorder(self: *Pool, set: borders.Set) !u16 {
        if (borders.isEmpty(set)) return 0;
        if (self.border_index.get(set)) |id| return id;
        const reuse = self.border_free.items.len > 0;
        if (!reuse) {
            if (self.border_sets.items.len >= max_border_sets) return error.PoolFull;
            try self.border_sets.ensureUnusedCapacity(self.allocator, 1);
        }
        const id: u16 = if (reuse)
            self.border_free.items[self.border_free.items.len - 1]
        else
            @intCast(self.border_sets.items.len + 1);
        try self.border_index.put(self.allocator, set, id);
        if (reuse) {
            _ = self.border_free.pop();
            self.border_sets.items[id - 1] = set;
        } else {
            self.border_sets.appendAssumeCapacity(set);
        }
        return id;
    }

    /// `entry` with its border set replaced by `set`, interned. A set
    /// interned only for an entry that then fails is released again, so
    /// a failed intern leaves no orphan for a reclaim to mistake for
    /// progress.
    pub fn internWithBorders(self: *Pool, entry: Entry, set: borders.Set) !u16 {
        const known = borders.isEmpty(set) or self.border_index.contains(set);
        var e = entry;
        e.border = try self.internBorder(set);
        return self.intern(e) catch |err| {
            if (!known) self.releaseBorder(e.border);
            return err;
        };
    }

    /// Return an unrooted ID's slot to the free list.
    fn releaseBorder(self: *Pool, id: u16) void {
        const slot = &self.border_sets.items[id - 1];
        // Without room on the free list the set stays interned as an
        // orphan, which the next `collectBorders` frees.
        self.border_free.append(self.allocator, id) catch return;
        _ = self.border_index.remove(slot.*);
        slot.* = borders.empty;
    }

    /// Free every border set no style entry references. Callers run it
    /// only when no unrooted ID from `internBorder` is still in hand.
    pub fn collectBorders(self: *Pool) void {
        if (self.border_sets.items.len == 0) return;
        const used = self.allocator.alloc(bool, self.border_sets.items.len + 1) catch return;
        defer self.allocator.free(used);
        @memset(used, false);
        for (self.entries.items) |e| {
            if (e.border <= self.border_sets.items.len) used[e.border] = true;
        }
        self.border_free.ensureTotalCapacity(self.allocator, self.border_sets.items.len) catch return;
        self.border_free.clearRetainingCapacity();
        for (self.border_sets.items, 1..) |*set, id| {
            if (used[id]) continue;
            if (!borders.isEmpty(set.*)) _ = self.border_index.remove(set.*);
            set.* = borders.empty;
            self.border_free.appendAssumeCapacity(@intCast(id));
        }
    }

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
        self.border_sets.deinit(self.allocator);
        self.border_index.deinit(self.allocator);
        self.border_free.deinit(self.allocator);
    }

    /// Builds a complete pool while leaving `entries` and `border_sets`
    /// caller-owned on error. Rejects a border table the interning paths
    /// could not have produced (a duplicate set, or an entry naming a
    /// missing or empty slot), which only untrusted input can hold.
    pub fn initReplacement(
        allocator: std.mem.Allocator,
        entries: std.ArrayList(Entry),
        border_sets: std.ArrayList(borders.Set),
    ) !Pool {
        var replacement = Pool{ .allocator = allocator };
        errdefer {
            replacement.index.deinit(allocator);
            replacement.border_index.deinit(allocator);
            replacement.border_free.deinit(allocator);
        }
        if (border_sets.items.len > max_border_sets) return error.InvalidBorderTable;
        for (border_sets.items, 1..) |set, id| {
            if (borders.isEmpty(set)) {
                try replacement.border_free.append(allocator, @intCast(id));
                continue;
            }
            const slot = try replacement.border_index.getOrPut(allocator, set);
            if (slot.found_existing) return error.InvalidBorderTable;
            slot.value_ptr.* = @intCast(id);
        }
        for (entries.items, 0..) |entry, i| {
            if (entry.border != 0 and (entry.border > border_sets.items.len or
                borders.isEmpty(border_sets.items[entry.border - 1])))
                return error.InvalidBorderTable;
            try replacement.index.put(allocator, entryKey(entry), @intCast(i));
        }
        replacement.entries = entries;
        replacement.border_sets = border_sets;
        return replacement;
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

test "Attrs keeps its u16 wire layout with the new underline bits in the pad" {
    // The snapshot format serialises attrs as this raw integer; the
    // twelve original bits must stay where an older peer reads them.
    var a = Attrs{};
    a.overline = true;
    try std.testing.expectEqual(@as(u16, 1 << 11), @as(u16, @bitCast(a)));
    a = .{};
    a.dotted_underline = true;
    try std.testing.expectEqual(@as(u16, 1 << 12), @as(u16, @bitCast(a)));
    a = .{};
    a.dashed_underline = true;
    try std.testing.expectEqual(@as(u16, 1 << 13), @as(u16, @bitCast(a)));
}

test "setUnderlineStyle is exclusive and underlineStyle reads it back" {
    var a = Attrs{};
    inline for (comptime std.enums.values(Attrs.UnderlineStyle)) |style| {
        a.setUnderlineStyle(style);
        try std.testing.expectEqual(style, a.underlineStyle());
        var set: u8 = 0;
        inline for (.{ "underline", "double_underline", "curly_underline", "dotted_underline", "dashed_underline" }) |name| {
            set += @intFromBool(@field(a, name));
        }
        const want: u8 = switch (style) {
            .none => 0,
            // Their own bit plus the curly fallback bit.
            .dotted, .dashed => 2,
            else => 1,
        };
        try std.testing.expectEqual(want, set);
    }
    // Switching styles replaces rather than accumulates.
    a.setUnderlineStyle(.double);
    a.setUnderlineStyle(.curly);
    try std.testing.expect(!a.double_underline and a.curly_underline);
    a.setUnderlineStyle(.dotted);
    a.setUnderlineStyle(.single);
    try std.testing.expect(!a.dotted_underline and !a.curly_underline and a.underline);
}

test "dotted and dashed read as curly to a peer without their bits" {
    // An older peer's Attrs ends at overline with a u4 pad: it sees the
    // low twelve bits only, and must find the curly bit there.
    const Old = packed struct(u16) {
        bold: bool,
        dim: bool,
        italic: bool,
        underline: bool,
        blink: bool,
        fast_blink: bool,
        reverse: bool,
        invisible: bool,
        strikethrough: bool,
        double_underline: bool,
        curly_underline: bool,
        overline: bool,
        _pad: u4,
    };
    inline for (.{ Attrs.UnderlineStyle.dotted, Attrs.UnderlineStyle.dashed }) |style| {
        var a = Attrs{};
        a.setUnderlineStyle(style);
        const old: Old = @bitCast(a);
        try std.testing.expect(old.curly_underline and !old.underline and !old.double_underline);
    }
}

test "intern truecolor" {
    var p = try Pool.init(std.testing.allocator);
    defer p.deinit();
    const e = Entry{ .fg = .{ .rgb = .{ .r = 255, .g = 128, .b = 0 } } };
    const i = try p.intern(e);
    const r = p.get(i);
    try std.testing.expect(Color.equal(r.fg, e.fg));
}
