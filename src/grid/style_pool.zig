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
pub const overlay = @import("overlay.zig");
const SlotTable = @import("slot_table.zig").SlotTable;
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

    /// Canonical 26-bit form: the kind (0 default, 1 palette, 2 rgb) in
    /// bits 24-25 and the payload below it. Equal colours pack equal,
    /// which unions cannot promise (inactive payload bytes are undefined).
    pub fn pack(col: Color) u26 {
        return switch (col) {
            .default => 0,
            .palette => |p| (1 << 24) | @as(u26, p),
            .rgb => |c| (2 << 24) | (@as(u26, c.r) << 16) | (@as(u26, c.g) << 8) | c.b,
        };
    }

    /// The inverse of `pack`; null for bits `pack` cannot produce.
    pub fn unpack(bits: u26) ?Color {
        const payload: u24 = @truncate(bits);
        return switch (bits >> 24) {
            0 => if (payload == 0) .default else null,
            1 => if (payload <= 0xFF) .{ .palette = @intCast(payload) } else null,
            2 => .{ .rgb = .{ .r = @truncate(payload >> 16), .g = @truncate(payload >> 8), .b = @truncate(payload) } },
            else => null,
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
    /// The cell's border set: an ID into `Pool.border_table`, 0 = none.
    /// Living in the style is what makes it the pen: every path that
    /// stamps `cur_style` on a cell (print, BCE erase, DECSC) carries it.
    border: u16 = 0,
    /// The cell's overstrike layers: an ID into `Pool.overlay_table`,
    /// 0 = none. Only an overstrike print sets it, on the struck cell's
    /// own entry; `cur_style` never carries one, so every ordinary write
    /// or erase of the cell drops its layers.
    overlay: u16 = 0,

    pub fn equal(a: Entry, b: Entry) bool {
        if (!Color.equal(a.fg, b.fg)) return false;
        if (!Color.equal(a.bg, b.bg)) return false;
        if (!Color.equal(a.underline_color, b.underline_color)) return false;
        return a.border == b.border and a.overlay == b.overlay and
            @as(u16, @bitCast(a.attrs)) == @as(u16, @bitCast(b.attrs));
    }

    /// Whether a cell with this style draws something even with no
    /// rune (borders, overstrike layers): such a blank is content.
    pub fn drawsOnBlank(self: Entry) bool {
        return self.border != 0 or self.overlay != 0;
    }
};

/// 26 bits per colour (`Color.pack`), three of them, then the three u16
/// fields: 126 bits.
fn entryKey(e: Entry) u128 {
    return (@as(u128, e.fg.pack()) << 100) |
        (@as(u128, e.bg.pack()) << 74) |
        (@as(u128, e.underline_color.pack()) << 48) |
        (@as(u128, e.border) << 32) | (@as(u128, e.overlay) << 16) | @as(u16, @bitCast(e.attrs));
}

pub const BorderTable = SlotTable(borders.Set, borders.empty);
pub const OverlayTable = SlotTable(overlay.List, overlay.empty);

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
    /// Interned border sets, named by `Entry.border`.
    border_table: BorderTable = .{},
    /// Interned overstrike layer lists, named by `Entry.overlay`.
    overlay_table: OverlayTable = .{},
    /// Failed reclaims left to skip. A reclaim that frees nothing arms
    /// this, so a pool saturated with live styles is rescanned once per
    /// `reclaim_backoff` failed interns instead of once per cell.
    reclaim_cooldown: u16 = 0,

    pub const reclaim_backoff: u16 = 4096;

    pub fn borderSet(self: *const Pool, id: u16) borders.Set {
        return self.border_table.get(id);
    }

    /// The border set a cell with this style draws.
    pub fn bordersOf(self: *const Pool, style_ref: u16) borders.Set {
        return self.borderSet(self.get(style_ref).border);
    }

    /// Whether any live border set exists; renderers bail on false.
    pub fn hasBorders(self: *const Pool) bool {
        return self.border_table.hasLive();
    }

    pub fn internBorder(self: *Pool, set: borders.Set) !u16 {
        return self.border_table.intern(self.allocator, set);
    }

    pub fn overlayList(self: *const Pool, id: u16) overlay.List {
        return self.overlay_table.get(id);
    }

    /// The overstrike layers a cell with this style draws.
    pub fn overlaysOf(self: *const Pool, style_ref: u16) overlay.List {
        return self.overlayList(self.get(style_ref).overlay);
    }

    /// Whether any live layer list exists; renderers bail on false.
    pub fn hasOverlays(self: *const Pool) bool {
        return self.overlay_table.hasLive();
    }

    /// Free slots across the side tables; a reclaim that grows it freed
    /// something.
    pub fn freeSlots(self: *const Pool) usize {
        return self.border_table.free.items.len + self.overlay_table.free.items.len;
    }

    /// `entry` with its border set and layer list replaced by `set` and
    /// `list`, interned. Takes the side values, never their IDs, so a
    /// reclaim between reading and interning cannot leave a dangling ID.
    /// A value interned only for an entry that then fails is released
    /// again, so a failed intern leaves no orphan for a reclaim to
    /// mistake for progress.
    pub fn internStyle(self: *Pool, entry: Entry, set: borders.Set, list: overlay.List) !u16 {
        const set_known = BorderTable.isEmpty(set) or self.border_table.contains(set);
        const list_known = OverlayTable.isEmpty(list) or self.overlay_table.contains(list);
        var e = entry;
        e.border = try self.border_table.intern(self.allocator, set);
        errdefer if (!set_known) self.border_table.release(self.allocator, e.border);
        e.overlay = try self.overlay_table.intern(self.allocator, list);
        errdefer if (!list_known) self.overlay_table.release(self.allocator, e.overlay);
        return self.intern(e);
    }

    /// Free every border set and layer list no style entry references.
    /// Callers run it only when no unrooted ID is still in hand.
    pub fn collectTables(self: *Pool) void {
        const nb = self.border_table.slots.items.len;
        const no = self.overlay_table.slots.items.len;
        if (nb == 0 and no == 0) return;
        const used = self.allocator.alloc(bool, nb + 1 + no + 1) catch return;
        defer self.allocator.free(used);
        @memset(used, false);
        const used_b = used[0 .. nb + 1];
        const used_o = used[nb + 1 ..];
        for (self.entries.items) |e| {
            if (e.border <= nb) used_b[e.border] = true;
            if (e.overlay <= no) used_o[e.overlay] = true;
        }
        if (nb > 0) self.border_table.collect(self.allocator, used_b);
        if (no > 0) self.overlay_table.collect(self.allocator, used_o);
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
        self.border_table.deinit(self.allocator);
        self.overlay_table.deinit(self.allocator);
    }

    /// Builds a complete pool while leaving `entries` and both slot lists
    /// caller-owned on error. Rejects side tables the interning paths
    /// could not have produced (a duplicate value, or an entry naming a
    /// missing or empty slot), which only untrusted input can hold.
    pub fn initReplacement(
        allocator: std.mem.Allocator,
        entries: std.ArrayList(Entry),
        border_slots: std.ArrayList(borders.Set),
        overlay_slots: std.ArrayList(overlay.List),
    ) !Pool {
        var replacement = Pool{ .allocator = allocator };
        errdefer {
            replacement.index.deinit(allocator);
            replacement.border_table.index.deinit(allocator);
            replacement.border_table.free.deinit(allocator);
            replacement.overlay_table.index.deinit(allocator);
            replacement.overlay_table.free.deinit(allocator);
        }
        try replacement.border_table.indexSlots(allocator, border_slots.items);
        try replacement.overlay_table.indexSlots(allocator, overlay_slots.items);
        for (entries.items, 0..) |entry, i| {
            if (!BorderTable.validRef(border_slots.items, entry.border) or
                !OverlayTable.validRef(overlay_slots.items, entry.overlay))
                return error.InvalidTable;
            try replacement.index.put(allocator, entryKey(entry), @intCast(i));
        }
        replacement.entries = entries;
        replacement.border_table.slots = border_slots;
        replacement.overlay_table.slots = overlay_slots;
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
