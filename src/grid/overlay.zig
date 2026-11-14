//! Overstrike layers: glyphs drawn on top of a cell (mintty's `CSI 8:7 m`
//! and DECSET 20, the DEC VK100 overstrike mode).
//!
//! A cell keeps its base codepoint in `Cell.rune` and its own rendition;
//! everything overstruck onto it is a layer here, named by the cell's
//! style entry (`style_pool.Entry.overlay`, an ID into the pool's interned
//! table). Each layer carries its codepoint and a value copy of the
//! rendition it was drawn with, so nothing in a layer points back into the
//! pool. Text consumers (selection, search, URL scan, accessibility) read
//! only the base: copying an overstruck cell yields its base character.

const std = @import("std");
const style_pool = @import("style_pool.zig");
const Entry = style_pool.Entry;
const Color = style_pool.Color;

/// Layers one cell can hold. A further overstrike drops the OLDEST layer,
/// so the most recent `max_layers` drawings stay visible.
pub const max_layers = 4;

/// One overstruck glyph. The all-zero value is the absent layer and the
/// only absent encoding, so a `List` compares and hashes by its bytes.
/// Snapshots carry the bits verbatim: append fields into `_pad`.
pub const Layer = packed struct(u128) {
    cp: u21 = 0,
    fg: u26 = 0,
    bg: u26 = 0,
    underline_color: u26 = 0,
    attrs: u16 = 0,
    _pad: u13 = 0,

    pub const absent: Layer = .{};

    /// `cp` drawn with the rendition of `r` (its border and overlay IDs
    /// are not part of a layer).
    pub fn init(cp: u21, r: Entry) Layer {
        return .{
            .cp = cp,
            .fg = r.fg.pack(),
            .bg = r.bg.pack(),
            .underline_color = r.underline_color.pack(),
            .attrs = @bitCast(r.attrs),
        };
    }

    pub fn present(self: Layer) bool {
        return self.cp != 0;
    }

    /// The rendition this layer was drawn with, as a style entry the
    /// renderers' colour resolution takes.
    pub fn rendition(self: Layer) Entry {
        return .{
            .fg = Color.unpack(self.fg) orelse .default,
            .bg = Color.unpack(self.bg) orelse .default,
            .underline_color = Color.unpack(self.underline_color) orelse .default,
            .attrs = @bitCast(self.attrs),
        };
    }

    pub fn bits(self: Layer) u128 {
        return @bitCast(self);
    }

    /// Whether untrusted bits (a snapshot) decode to a present layer
    /// `init` could have produced.
    pub fn valid(self: Layer) bool {
        if (self.cp == 0 or self.cp > 0x10FFFF or self._pad != 0) return false;
        return Color.unpack(self.fg) != null and Color.unpack(self.bg) != null and
            Color.unpack(self.underline_color) != null;
    }
};

/// A cell's layers, bottom first; present layers form a prefix and the
/// rest are absent.
pub const List = [max_layers]Layer;

pub const empty: List = @splat(Layer.absent);

pub fn count(list: List) usize {
    for (list, 0..) |layer, i| if (!layer.present()) return i;
    return max_layers;
}

/// `list` with `layer` on top; a full list drops its oldest layer.
pub fn withLayer(list: List, layer: Layer) List {
    var out = list;
    const n = count(list);
    if (n < max_layers) {
        out[n] = layer;
        return out;
    }
    std.mem.copyForwards(Layer, out[0 .. max_layers - 1], list[1..]);
    out[max_layers - 1] = layer;
    return out;
}

/// Whether untrusted layers (a snapshot) form a list `withLayer` could
/// have produced: a non-empty valid prefix, absent after it.
pub fn validList(list: List) bool {
    const n = count(list);
    if (n == 0) return false;
    for (list[0..n]) |layer| if (!layer.valid()) return false;
    for (list[n..]) |layer| if (layer.bits() != 0) return false;
    return true;
}

const testing = std.testing;

test "a layer round-trips its rendition" {
    var e = Entry{ .fg = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } }, .bg = .{ .palette = 200 }, .underline_color = .default };
    e.attrs.bold = true;
    e.attrs.setUnderlineStyle(.curly);
    const layer = Layer.init('/', e);
    try testing.expect(layer.valid());
    try testing.expect(Entry.equal(e, layer.rendition()));
}

test "withLayer appends, then drops the oldest past the bound" {
    var list = empty;
    for (0..max_layers + 2) |i| list = withLayer(list, Layer.init(@intCast('a' + i), .{}));
    try testing.expectEqual(@as(usize, max_layers), count(list));
    try testing.expectEqual(@as(u21, 'c'), list[0].cp);
    try testing.expectEqual(@as(u21, 'a' + max_layers + 1), list[max_layers - 1].cp);
    try testing.expect(validList(list));
}

test "validList rejects gaps, garbage and the empty list" {
    try testing.expect(!validList(empty));
    var gap = empty;
    gap[1] = Layer.init('x', .{});
    try testing.expect(!validList(gap));
    var bad = empty;
    bad[0] = @bitCast(@as(u128, 'x') | (@as(u128, 3) << (21 + 24)));
    try testing.expect(!validList(bad));
}
