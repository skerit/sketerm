//! Pure chord/char → evdev keycode encoder for driving forwarded
//! Wayland apps (the seat speaks evdev + xkb modifier masks, pc105/us
//! keymap — see wlhost/compositor.zig). Character table layout ported
//! from kwin-mcp's input.py (MIT, (c) isac322) against the same us
//! keymap. US-QWERTY only; non-ASCII needs the clipboard-paste path.

const std = @import("std");

/// xkb modifier mask bits under the pc105/us keymap.
pub const Mods = struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,

    pub fn bits(self: Mods) u32 {
        var v: u32 = 0;
        if (self.shift) v |= 1; // Shift
        if (self.ctrl) v |= 4; // Control
        if (self.alt) v |= 8; // Mod1
        if (self.super) v |= 64; // Mod4
        return v;
    }

    pub fn any(self: Mods) bool {
        return self.shift or self.ctrl or self.alt or self.super;
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

const named = [_]struct { name: []const u8, code: u32 }{
    .{ .name = "enter", .code = KEY_ENTER },
    .{ .name = "return", .code = KEY_ENTER },
    .{ .name = "tab", .code = 15 },
    .{ .name = "escape", .code = KEY_ESC },
    .{ .name = "esc", .code = KEY_ESC },
    .{ .name = "backspace", .code = 14 },
    .{ .name = "space", .code = KEY_SPACE },
    .{ .name = "up", .code = 103 },
    .{ .name = "down", .code = 108 },
    .{ .name = "left", .code = 105 },
    .{ .name = "right", .code = 106 },
    .{ .name = "home", .code = 102 },
    .{ .name = "end", .code = 107 },
    .{ .name = "pageup", .code = 104 },
    .{ .name = "pagedown", .code = 109 },
    .{ .name = "insert", .code = 110 },
    .{ .name = "delete", .code = 111 },
    .{ .name = "menu", .code = 127 },
};

/// Non-character key by name (lowercase); f1..f12 included.
pub fn namedKey(name: []const u8) ?u32 {
    for (named) |n| {
        if (std.mem.eql(u8, n.name, name)) return n.code;
    }
    if (name.len >= 2 and name.len <= 3 and name[0] == 'f') {
        const num = std.fmt.parseInt(u8, name[1..], 10) catch return null;
        if (num >= 1 and num <= 10) return 59 + @as(u32, num) - 1;
        if (num == 11) return 87;
        if (num == 12) return 88;
    }
    return null;
}

pub const Chord = struct { mods: Mods, key: Key };

/// "ctrl+shift+t", "alt+F4", "enter", "ctrl+c" → mods + evdev key.
pub fn parseChord(spec: []const u8) ?Chord {
    var mods = Mods{};
    var it = std.mem.splitScalar(u8, spec, '+');
    var last: ?[]const u8 = null;
    while (it.next()) |part| {
        var lower_buf: [24]u8 = undefined;
        if (part.len == 0 or part.len > lower_buf.len) return null;
        const lower = std.ascii.lowerString(&lower_buf, part);
        if (std.mem.eql(u8, lower, "ctrl") or std.mem.eql(u8, lower, "control")) {
            mods.ctrl = true;
        } else if (std.mem.eql(u8, lower, "alt") or std.mem.eql(u8, lower, "meta") or std.mem.eql(u8, lower, "option")) {
            mods.alt = true;
        } else if (std.mem.eql(u8, lower, "shift")) {
            mods.shift = true;
        } else if (std.mem.eql(u8, lower, "super") or std.mem.eql(u8, lower, "cmd") or std.mem.eql(u8, lower, "win")) {
            mods.super = true;
        } else {
            if (last != null) return null; // two non-modifier parts
            last = part;
        }
    }
    const key_part = last orelse return null;
    var lower_buf: [24]u8 = undefined;
    if (key_part.len > lower_buf.len) return null;
    const lower = std.ascii.lowerString(&lower_buf, key_part);
    if (namedKey(lower)) |code| return .{ .mods = mods, .key = .{ .code = code } };
    if (key_part.len == 1) {
        const k = charKey(key_part[0]) orelse return null;
        var m = mods;
        if (k.shift) m.shift = true;
        return .{ .mods = m, .key = .{ .code = k.code } };
    }
    return null;
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
}
