//! Pure chord/char → evdev keycode encoder for driving forwarded
//! Wayland apps (the seat speaks evdev + xkb modifier masks, pc105/us
//! keymap — see wlhost/compositor.zig). Character table layout ported
//! from kwin-mcp's input.py (MIT, (c) isac322) against the same us
//! keymap. US-QWERTY only; non-ASCII needs the clipboard-paste path.

const std = @import("std");
const keychord = @import("../util/keychord.zig");

/// `meta` is Super: the seat has a real Super key (pc105 Mod4).
pub const dialect: keychord.Dialect = .{ .meta = .super };

/// xkb modifier mask bits under the pc105 keymaps.
pub const Mods = struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,
    altgr: bool = false,

    pub fn bits(self: Mods) u32 {
        var v: u32 = 0;
        if (self.shift) v |= 1; // Shift
        if (self.ctrl) v |= 4; // Control
        if (self.alt) v |= 8; // Mod1
        if (self.super) v |= 64; // Mod4
        if (self.altgr) v |= 128; // Mod5 (ISO_Level3_Shift)
        return v;
    }

    pub fn any(self: Mods) bool {
        return self.bits() != 0;
    }
};

pub const Key = struct { code: u32, shift: bool = false };

// evdev keycodes (linux/input-event-codes.h).
pub const KEY_ESC: u32 = 1;
pub const KEY_ENTER: u32 = 28;
pub const KEY_LEFTCTRL: u32 = 29;
pub const KEY_LEFTSHIFT: u32 = 42;
pub const KEY_LEFTALT: u32 = 56;
pub const KEY_SPACE: u32 = 57;
pub const KEY_LEFTMETA: u32 = 125;

const row_digits = "1234567890";
const row_q = "qwertyuiop";
const row_a = "asdfghjkl";
const row_z = "zxcvbnm";

/// Printable ASCII → evdev key (+ whether shift is held).
pub fn charKey(ch: u8) ?Key {
    switch (ch) {
        'a'...'z' => {},
        'A'...'Z' => return .{ .code = charKey(ch - 'A' + 'a').?.code, .shift = true },
        else => {},
    }
    if (std.mem.indexOfScalar(u8, row_digits, ch)) |i| return .{ .code = @intCast(2 + i) };
    if (std.mem.indexOfScalar(u8, row_q, ch)) |i| return .{ .code = @intCast(16 + i) };
    if (std.mem.indexOfScalar(u8, row_a, ch)) |i| return .{ .code = @intCast(30 + i) };
    if (std.mem.indexOfScalar(u8, row_z, ch)) |i| return .{ .code = @intCast(44 + i) };
    return switch (ch) {
        ' ' => .{ .code = KEY_SPACE },
        '\n' => .{ .code = KEY_ENTER },
        '\t' => .{ .code = 15 },
        '-' => .{ .code = 12 },
        '=' => .{ .code = 13 },
        '[' => .{ .code = 26 },
        ']' => .{ .code = 27 },
        ';' => .{ .code = 39 },
        '\'' => .{ .code = 40 },
        '`' => .{ .code = 41 },
        '\\' => .{ .code = 43 },
        ',' => .{ .code = 51 },
        '.' => .{ .code = 52 },
        '/' => .{ .code = 53 },
        '!' => .{ .code = 2, .shift = true },
        '@' => .{ .code = 3, .shift = true },
        '#' => .{ .code = 4, .shift = true },
        '$' => .{ .code = 5, .shift = true },
        '%' => .{ .code = 6, .shift = true },
        '^' => .{ .code = 7, .shift = true },
        '&' => .{ .code = 8, .shift = true },
        '*' => .{ .code = 9, .shift = true },
        '(' => .{ .code = 10, .shift = true },
        ')' => .{ .code = 11, .shift = true },
        '_' => .{ .code = 12, .shift = true },
        '+' => .{ .code = 13, .shift = true },
        '{' => .{ .code = 26, .shift = true },
        '}' => .{ .code = 27, .shift = true },
        ':' => .{ .code = 39, .shift = true },
        '"' => .{ .code = 40, .shift = true },
        '~' => .{ .code = 41, .shift = true },
        '|' => .{ .code = 43, .shift = true },
        '<' => .{ .code = 51, .shift = true },
        '>' => .{ .code = 52, .shift = true },
        '?' => .{ .code = 53, .shift = true },
        else => null,
    };
}

/// The evdev keycode of a named key; f1..f10 are contiguous, f11/f12 are not.
fn namedCode(n: keychord.Named) u32 {
    return switch (n) {
        .enter => KEY_ENTER,
        .tab => 15,
        .escape => KEY_ESC,
        .backspace => 14,
        .space => KEY_SPACE,
        .delete => 111,
        .insert => 110,
        .home => 102,
        .end => 107,
        .page_up => 104,
        .page_down => 109,
        .up => 103,
        .down => 108,
        .left => 105,
        .right => 106,
        .menu => 127,
        .caps_lock => 58,
        .shift => KEY_LEFTSHIFT,
        .ctrl => KEY_LEFTCTRL,
        .alt => KEY_LEFTALT,
        .super => KEY_LEFTMETA,
        .f1 => 59,
        .f2 => 60,
        .f3 => 61,
        .f4 => 62,
        .f5 => 63,
        .f6 => 64,
        .f7 => 65,
        .f8 => 66,
        .f9 => 67,
        .f10 => 68,
        .f11 => 87,
        .f12 => 88,
    };
}

pub const Chord = struct {
    mods: Mods,
    key: Key,
    /// The literal character the key part came from (null for named
    /// keys) — lets layout-aware callers re-resolve the keycode.
    ch: ?u8 = null,
};

/// "ctrl+shift+t", "alt+F4", "enter", "ctrl+c" → mods + evdev key, per util/keychord.zig's grammar.
/// Only a US-QWERTY ASCII character is a character key here.
pub fn parseChord(spec: []const u8) ?Chord {
    const parsed = keychord.parse(spec, dialect) catch return null;
    var mods = Mods{};
    var it = parsed.mods.iterator();
    while (it.next()) |m| switch (m) {
        .shift => mods.shift = true,
        .ctrl => mods.ctrl = true,
        .alt => mods.alt = true,
        .super => mods.super = true,
    };
    switch (parsed.key) {
        .named => |n| return .{ .mods = mods, .key = .{ .code = namedCode(n) } },
        .char => |text| {
            if (text.len != 1) return null;
            const k = charKey(text[0]) orelse return null;
            if (k.shift) mods.shift = true;
            return .{ .mods = mods, .key = .{ .code = k.code }, .ch = text[0] };
        },
    }
}

// ─── tests ──────────────────────────────────────────────────────

const t = std.testing;

test "charKey covers letters, digits and shifted symbols" {
    try t.expectEqual(Key{ .code = 30 }, charKey('a').?);
    try t.expectEqual(Key{ .code = 30, .shift = true }, charKey('A').?);
    try t.expectEqual(Key{ .code = 2 }, charKey('1').?);
    try t.expectEqual(Key{ .code = 2, .shift = true }, charKey('!').?);
    try t.expectEqual(Key{ .code = 53, .shift = true }, charKey('?').?);
    try t.expectEqual(Key{ .code = KEY_SPACE }, charKey(' ').?);
    try t.expectEqual(@as(?Key, null), charKey(0xC3));
}

test "parseChord handles modifiers, named keys and case" {
    const cc = parseChord("ctrl+c").?;
    try t.expect(cc.mods.ctrl and !cc.mods.shift);
    try t.expectEqual(@as(u32, 46), cc.key.code);

    const f4 = parseChord("alt+F4").?;
    try t.expect(f4.mods.alt);
    try t.expectEqual(@as(u32, 62), f4.key.code);

    const sh = parseChord("ctrl+T").?; // uppercase letter implies shift
    try t.expect(sh.mods.ctrl and sh.mods.shift);
    try t.expectEqual(@as(u32, 20), sh.key.code);

    try t.expectEqual(@as(u32, KEY_ENTER), parseChord("enter").?.key.code);
    try t.expect(parseChord("ctrl+") == null);
    try t.expect(parseChord("ctrl+a+b") == null);
    try t.expectEqual(@as(u32, 1 | 4), parseChord("ctrl+shift+t").?.mods.bits());

    // Both page-key spellings, meta as Super, and a literal plus.
    try t.expectEqual(@as(u32, 104), parseChord("pgup").?.key.code);
    try t.expectEqual(@as(u32, 104), parseChord("page_up").?.key.code);
    try t.expectEqual(@as(u32, 109), parseChord("PgDn").?.key.code);
    try t.expectEqual(@as(u32, 64), parseChord("meta+t").?.mods.bits());
    try t.expectEqual(@as(u32, 8), parseChord("option+t").?.mods.bits());
    const plus = parseChord("ctrl++").?;
    try t.expectEqual(@as(u32, 13), plus.key.code);
    try t.expect(plus.mods.ctrl and plus.mods.shift);
    try t.expectEqual(@as(?u8, '+'), plus.ch);
    try t.expectEqual(@as(u32, 13), parseChord("+").?.key.code);
    // A modifier alone is its own key.
    try t.expectEqual(KEY_LEFTMETA, parseChord("super").?.key.code);
    try t.expect(parseChord("\xc3\xa9") == null);
}
