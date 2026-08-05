//! Editor colour themes: highlight kind -> colour + face, plus the
//! chrome colours the editor pass paints around the text.
//!
//! GTK-free and allocation-free — a theme is a comptime constant, and
//! `byName` returns a pointer to one of them (never a copy), so a
//! config reload that re-points every theme user costs nothing.
//!
//! Bold/italic are THEME data, not hardcoded rules: `editor_layout`
//! turns them into font-itemization style spans, so a comment renders
//! in the italic face when the atlas has one and degrades to regular
//! when it does not (editor_font's documented fallback).

const std = @import("std");
const syntax = @import("syntax.zig");
const Kind = syntax.Kind;

pub const Style = struct {
    rgba: [4]f32,
    bold: bool = false,
    italic: bool = false,
    /// Draw a line THROUGH the glyphs. Only a modifier ever sets it, and
    /// only `editor_pass` reads it — it is a decoration, not a face, so
    /// it deliberately does NOT split an itemization run the way
    /// bold/italic do.
    strike: bool = false,
};

/// What a theme may say about ONE semantic-token modifier, applied on
/// top of whatever `Style` the token's kind resolved to.
///
/// Deliberately a small delta rather than a second palette: a modifier
/// qualifies a kind ("this variable is readonly"), it does not replace
/// it, and giving every (kind x modifier) pair its own entry would be
/// 20 x 8 colours per theme for a distinction users read as a shade.
pub const ModStyle = struct {
    /// Blend the kind's colour this far toward `toward` (0 = no change,
    /// 1 = replace). Alpha is never touched.
    blend: f32 = 0,
    toward: [4]f32 = .{ 0, 0, 0, 1 },
    /// Force the face on or off; null leaves the kind's own choice.
    bold: ?bool = null,
    italic: ?bool = null,
    strike: bool = false,

    fn apply(self: ModStyle, s: Style) Style {
        var out = s;
        if (self.blend > 0) {
            const t = @min(self.blend, 1.0);
            inline for (0..3) |i| out.rgba[i] = s.rgba[i] * (1 - t) + self.toward[i] * t;
        }
        if (self.bold) |b| out.bold = b;
        if (self.italic) |i| out.italic = i;
        if (self.strike) out.strike = true;
        return out;
    }
};

pub const Theme = struct {
    name: []const u8,
    /// Window clear colour behind the document.
    bg: [4]f32,
    /// Unhighlighted text (also `Kind.none`).
    fg: [4]f32,
    selection: [4]f32,
    caret: [4]f32,
    gutter_bg: [4]f32,
    gutter_fg: [4]f32,
    current_line: [4]f32,
    match: [4]f32,
    match_current: [4]f32,
    preedit_bg: [4]f32,
    /// Box behind each half of the bracket pair around the caret.
    bracket: [4]f32,
    /// Badge drawn where a folded region's hidden lines were.
    fold_badge: [4]f32,
    /// The gutter's fold chevron (and the badge's dots).
    fold_fg: [4]f32,
    /// Indexed by `@intFromEnum(Kind)`.
    kinds: [syntax.KIND_COUNT]Style,
    /// The three semantic-token modifiers a theme can speak about, in
    /// the order they are folded in (a symbol can carry all three).
    mod_readonly: ModStyle = .{},
    mod_default_library: ModStyle = .{},
    mod_deprecated: ModStyle = .{},

    /// Resolved style for a kind BYTE — the palette tag plus whatever
    /// modifier bits `editorlsp` packed alongside it (syntax.zig). Every
    /// caller passes a byte straight off a glyph, so masking here rather
    /// than at each call site is what keeps the modifier band invisible
    /// to the layout and the highlighter.
    pub fn style(self: *const Theme, kind: Kind) Style {
        var out = self.kinds[@intFromEnum(syntax.baseKind(kind))];
        const mods = syntax.modsOf(kind);
        if (mods == 0) return out;
        if (mods & syntax.MOD_READONLY != 0) out = self.mod_readonly.apply(out);
        if (mods & syntax.MOD_DEFAULT_LIBRARY != 0) out = self.mod_default_library.apply(out);
        // Deprecated is folded LAST so its dimming survives the others.
        if (mods & syntax.MOD_DEPRECATED != 0) out = self.mod_deprecated.apply(out);
        return out;
    }

    pub fn colorOf(self: *const Theme, kind: Kind) [4]f32 {
        return self.style(kind).rgba;
    }
};

fn rgb(hex: u32) [4]f32 {
    return .{
        @as(f32, @floatFromInt((hex >> 16) & 0xFF)) / 255.0,
        @as(f32, @floatFromInt((hex >> 8) & 0xFF)) / 255.0,
        @as(f32, @floatFromInt(hex & 0xFF)) / 255.0,
        1.0,
    };
}

fn rgba(hex: u32, alpha: f32) [4]f32 {
    var v = rgb(hex);
    v[3] = alpha;
    return v;
}

/// Build the kind table from an exhaustive switch so ADDING a `Kind`
/// is a compile error in every theme rather than a silently black
/// token.
fn kindTable(comptime f: fn (Kind) Style) [syntax.KIND_COUNT]Style {
    var out: [syntax.KIND_COUNT]Style = undefined;
    for (std.enums.values(Kind)) |k| out[@intFromEnum(k)] = f(k);
    return out;
}

fn darkStyle(k: Kind) Style {
    return switch (k) {
        .none => .{ .rgba = rgb(0xE6E8E3) },
        .keyword => .{ .rgba = rgb(0xE08A54), .bold = true },
        .string => .{ .rgba = rgb(0x9BC46B) },
        .number => .{ .rgba = rgb(0xD7A2E8) },
        .comment => .{ .rgba = rgb(0x6F7A6B), .italic = true },
        .function => .{ .rgba = rgb(0x77B7E0) },
        .type => .{ .rgba = rgb(0x6BC2B4) },
        .constant => .{ .rgba = rgb(0xD7A2E8) },
        .operator => .{ .rgba = rgb(0xC9CBC4) },
        .punctuation => .{ .rgba = rgb(0x9AA096) },
        .variable => .{ .rgba = rgb(0xE6E8E3) },
        .attribute => .{ .rgba = rgb(0xE0C25A) },
        .property => .{ .rgba = rgb(0xBFD4EC) },
        .namespace => .{ .rgba = rgb(0x6BC2B4) },
        .escape => .{ .rgba = rgb(0xE0C25A) },
        .label => .{ .rgba = rgb(0xE0C25A) },
        .heading => .{ .rgba = rgb(0x77B7E0), .bold = true },
        .link => .{ .rgba = rgb(0x6BC2B4) },
        .emphasis => .{ .rgba = rgb(0xE6E8E3), .italic = true },
        .strong => .{ .rgba = rgb(0xE6E8E3), .bold = true },
        // Only ever called from kindTable, over the NAMED kinds. The
        // `_` prong is the price of the modifier band living in the same
        // byte; adding a named kind is still a compile error here.
        _ => unreachable,
    };
}

fn lightStyle(k: Kind) Style {
    return switch (k) {
        .none => .{ .rgba = rgb(0x2B2F33) },
        .keyword => .{ .rgba = rgb(0xA5411A), .bold = true },
        .string => .{ .rgba = rgb(0x3F7A22) },
        .number => .{ .rgba = rgb(0x7A3FA5) },
        .comment => .{ .rgba = rgb(0x7A857A), .italic = true },
        .function => .{ .rgba = rgb(0x1F5FA5) },
        .type => .{ .rgba = rgb(0x0F6F63) },
        .constant => .{ .rgba = rgb(0x7A3FA5) },
        .operator => .{ .rgba = rgb(0x40464C) },
        .punctuation => .{ .rgba = rgb(0x6A7078) },
        .variable => .{ .rgba = rgb(0x2B2F33) },
        .attribute => .{ .rgba = rgb(0x8A6A00) },
        .property => .{ .rgba = rgb(0x2A4E75) },
        .namespace => .{ .rgba = rgb(0x0F6F63) },
        .escape => .{ .rgba = rgb(0x8A6A00) },
        .label => .{ .rgba = rgb(0x8A6A00) },
        .heading => .{ .rgba = rgb(0x1F5FA5), .bold = true },
        .link => .{ .rgba = rgb(0x0F6F63) },
        .emphasis => .{ .rgba = rgb(0x2B2F33), .italic = true },
        .strong => .{ .rgba = rgb(0x2B2F33), .bold = true },
        _ => unreachable,
    };
}

/// Matches sketerm's own dark chrome — the default.
pub const dark = Theme{
    .name = "dark",
    .bg = rgb(0x14161A),
    .fg = rgb(0xE6E8E3),
    .selection = rgba(0x33599C, 0.85),
    .caret = rgb(0xF25A40),
    .gutter_bg = rgb(0x212429),
    .gutter_fg = rgb(0x808891),
    .current_line = .{ 1.0, 1.0, 1.0, 0.045 },
    .match = rgba(0xD9B840, 0.32),
    .match_current = rgba(0xF2B833, 0.65),
    .preedit_bg = rgb(0x17191F),
    .bracket = rgba(0x6FD3C8, 0.42),
    .fold_badge = rgba(0x808891, 0.25),
    .fold_fg = rgb(0x9AA3AD),
    .kinds = kindTable(darkStyle),
    // A readonly binding reads like a constant, because that is what it
    // is — half-way to the palette's constant violet, whatever kind the
    // server actually gave it.
    .mod_readonly = .{ .blend = 0.45, .toward = rgb(0xD7A2E8) },
    // Standard-library symbols pull toward the type/namespace teal: the
    // grammar can never know a name is not this project's.
    .mod_default_library = .{ .blend = 0.35, .toward = rgb(0x6BC2B4) },
    // Struck through and dimmed toward the comment grey — the one
    // rendering every editor agrees on.
    .mod_deprecated = .{ .blend = 0.5, .toward = rgb(0x6F7A6B), .strike = true },
};

pub const light = Theme{
    .name = "light",
    .bg = rgb(0xFBFBF8),
    .fg = rgb(0x2B2F33),
    .selection = rgba(0x9FC3F0, 0.75),
    .caret = rgb(0xC03A22),
    .gutter_bg = rgb(0xEFEFE9),
    .gutter_fg = rgb(0x9198A0),
    .current_line = .{ 0.0, 0.0, 0.0, 0.045 },
    .match = rgba(0xE0C25A, 0.45),
    .match_current = rgba(0xE8A21F, 0.70),
    .preedit_bg = rgb(0xF2F2EC),
    .bracket = rgba(0x1F8C7E, 0.32),
    .fold_badge = rgba(0x9198A0, 0.28),
    .fold_fg = rgb(0x6E757D),
    .kinds = kindTable(lightStyle),
    .mod_readonly = .{ .blend = 0.45, .toward = rgb(0x7A3FA5) },
    .mod_default_library = .{ .blend = 0.35, .toward = rgb(0x0F6F63) },
    .mod_deprecated = .{ .blend = 0.5, .toward = rgb(0x7A857A), .strike = true },
};

pub const all = [_]*const Theme{ &dark, &light };

/// Theme by config name; unknown / empty names fall back to `dark`.
pub fn byName(name: []const u8) *const Theme {
    for (all) |t| {
        if (std.ascii.eqlIgnoreCase(t.name, name)) return t;
    }
    return &dark;
}

// ======================================================================
// Tests
// ======================================================================

const testing = std.testing;

test "theme: byName resolves both built-ins and falls back to dark" {
    try testing.expectEqualStrings("dark", byName("dark").name);
    try testing.expectEqualStrings("light", byName("Light").name);
    try testing.expectEqualStrings("dark", byName("").name);
    try testing.expectEqualStrings("dark", byName("solarized-neon").name);
}

test "theme: a modifier band changes the resolved style, not the palette" {
    for (all) |t| {
        const plain = t.style(.variable);
        try testing.expect(!plain.strike);

        // readonly shifts the colour without touching the palette entry.
        const ro = t.style(syntax.withMods(.variable, syntax.MOD_READONLY));
        try testing.expect(!std.mem.eql(u8, &std.mem.toBytes(plain.rgba), &std.mem.toBytes(ro.rgba)));
        try testing.expect(!ro.strike);
        try testing.expectEqual(@as(f32, 1.0), ro.rgba[3]);
        try testing.expectEqual(plain.rgba[0], t.style(.variable).rgba[0]);

        // deprecated strikes through AND dims.
        const dep = t.style(syntax.withMods(.function, syntax.MOD_DEPRECATED));
        try testing.expect(dep.strike);
        try testing.expect(!std.mem.eql(
            u8,
            &std.mem.toBytes(t.style(.function).rgba),
            &std.mem.toBytes(dep.rgba),
        ));

        // All three at once resolve, and deprecated's strike survives.
        const all_mods = t.style(syntax.withMods(
            .type,
            syntax.MOD_READONLY | syntax.MOD_DEFAULT_LIBRARY | syntax.MOD_DEPRECATED,
        ));
        try testing.expect(all_mods.strike);
        try testing.expectEqual(@as(f32, 1.0), all_mods.rgba[3]);

        // An unmapped modifier bit cannot exist: the band is exactly
        // three bits and every one of them is spoken for.
        try testing.expectEqual(
            @as(u8, syntax.MOD_READONLY | syntax.MOD_DEPRECATED | syntax.MOD_DEFAULT_LIBRARY),
            syntax.MOD_MASK,
        );
    }
}

test "theme: colorOf agrees with style for a byte carrying modifiers" {
    const k = syntax.withMods(.variable, syntax.MOD_READONLY);
    try testing.expectEqual(dark.style(k).rgba, dark.colorOf(k));
    // …and a bare kind is unaffected by the masking.
    try testing.expectEqual(dark.kinds[@intFromEnum(Kind.string)].rgba, dark.colorOf(.string));
}

test "theme: every kind has an opaque colour and a sane face" {
    for (all) |t| {
        for (std.enums.values(Kind)) |k| {
            const s = t.style(k);
            try testing.expectEqual(@as(f32, 1.0), s.rgba[3]);
            // Bold AND italic at once is never tasteful; nothing uses it.
            try testing.expect(!(s.bold and s.italic));
        }
        // Comments italic, keywords bold — the documented house style.
        try testing.expect(t.style(.comment).italic);
        try testing.expect(t.style(.keyword).bold);
        try testing.expect(!t.style(.none).bold);
    }
}

test "theme: dark and light differ in every structural colour" {
    try testing.expect(!std.mem.eql(u8, &std.mem.toBytes(dark.bg), &std.mem.toBytes(light.bg)));
    try testing.expect(!std.mem.eql(u8, &std.mem.toBytes(dark.fg), &std.mem.toBytes(light.fg)));
    // A light theme's background must actually be light.
    try testing.expect(light.bg[0] > 0.8 and light.fg[0] < 0.4);
    try testing.expect(dark.bg[0] < 0.2 and dark.fg[0] > 0.6);
}
