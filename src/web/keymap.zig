//! XKB keysym -> Chromium key-event mapping for the browser helper.
//!
//! The GUI has XKB keysyms natively and puts them on the wire; the
//! engine wants a Windows virtual-key code plus (for text-producing
//! keys) a UTF-16 character. This file owns that translation and
//! nothing else: std only, no CEF — the numeric constants below are
//! Chromium/Windows ABI values, not CEF types, and `cefhost.zig`
//! comptime-asserts the event-flag values against the real headers.
//!
//! Scope is deliberately the keys a browser actually needs: printable
//! Latin-1, the editing/navigation cluster, F1-F12 and the modifiers.
//! Anything else falls through to the codepoint rule (keysym == Unicode
//! for Latin-1, `0x01000000 | cp` for the rest), which produces a
//! correct CHAR event with a zero virtual-key code.

const std = @import("std");

/// Windows virtual-key codes used below (winuser.h names).
pub const VK_BACK: i32 = 0x08;
pub const VK_TAB: i32 = 0x09;
pub const VK_CLEAR: i32 = 0x0C;
pub const VK_RETURN: i32 = 0x0D;
pub const VK_SHIFT: i32 = 0x10;
pub const VK_CONTROL: i32 = 0x11;
pub const VK_MENU: i32 = 0x12;
pub const VK_PAUSE: i32 = 0x13;
pub const VK_CAPITAL: i32 = 0x14;
pub const VK_ESCAPE: i32 = 0x1B;
pub const VK_SPACE: i32 = 0x20;
pub const VK_PRIOR: i32 = 0x21;
pub const VK_NEXT: i32 = 0x22;
pub const VK_END: i32 = 0x23;
pub const VK_HOME: i32 = 0x24;
pub const VK_LEFT: i32 = 0x25;
pub const VK_UP: i32 = 0x26;
pub const VK_RIGHT: i32 = 0x27;
pub const VK_DOWN: i32 = 0x28;
pub const VK_INSERT: i32 = 0x2D;
pub const VK_DELETE: i32 = 0x2E;
pub const VK_LWIN: i32 = 0x5B;
pub const VK_RWIN: i32 = 0x5C;
pub const VK_NUMLOCK: i32 = 0x90;
pub const VK_SCROLL: i32 = 0x91;
pub const VK_F1: i32 = 0x70;
pub const VK_OEM_1: i32 = 0xBA; // ;:
pub const VK_OEM_PLUS: i32 = 0xBB;
pub const VK_OEM_COMMA: i32 = 0xBC;
pub const VK_OEM_MINUS: i32 = 0xBD;
pub const VK_OEM_PERIOD: i32 = 0xBE;
pub const VK_OEM_2: i32 = 0xBF; // /?
pub const VK_OEM_3: i32 = 0xC0; // `~
pub const VK_OEM_4: i32 = 0xDB; // [{
pub const VK_OEM_5: i32 = 0xDC; // \|
pub const VK_OEM_6: i32 = 0xDD; // ]}
pub const VK_OEM_7: i32 = 0xDE; // '"

/// Chromium event-flag bits (cef_event_flags_t values). Duplicated here
/// so this file stays CEF-free; cefhost asserts they still match.
pub const flag_caps_lock: u32 = 1 << 0;
pub const flag_shift: u32 = 1 << 1;
pub const flag_control: u32 = 1 << 2;
pub const flag_alt: u32 = 1 << 3;
pub const flag_left_mouse: u32 = 1 << 4;
pub const flag_middle_mouse: u32 = 1 << 5;
pub const flag_right_mouse: u32 = 1 << 6;
pub const flag_command: u32 = 1 << 7;
pub const flag_num_lock: u32 = 1 << 8;
pub const flag_is_key_pad: u32 = 1 << 9;

/// What the engine needs for one key.
pub const Key = struct {
    /// Windows virtual-key code; 0 when the keysym only produces text.
    windows_key_code: i32 = 0,
    /// UTF-16 unit to deliver as a CHAR event; 0 when the key produces
    /// no text of its own. Codepoints above the BMP have no single
    /// unit and arrive as committed `text` on the wire instead.
    character: u16 = 0,
    /// Keypad origin, for the IS_KEY_PAD event flag.
    keypad: bool = false,
};

/// XKB keysym constants this table names (keysymdef.h).
const XK_BackSpace: u32 = 0xff08;
const XK_Tab: u32 = 0xff09;
const XK_Return: u32 = 0xff0d;
const XK_Pause: u32 = 0xff13;
const XK_Scroll_Lock: u32 = 0xff14;
const XK_Escape: u32 = 0xff1b;
const XK_Home: u32 = 0xff50;
const XK_Left: u32 = 0xff51;
const XK_Up: u32 = 0xff52;
const XK_Right: u32 = 0xff53;
const XK_Down: u32 = 0xff54;
const XK_Prior: u32 = 0xff55;
const XK_Next: u32 = 0xff56;
const XK_End: u32 = 0xff57;
const XK_Begin: u32 = 0xff58;
const XK_Insert: u32 = 0xff63;
const XK_Num_Lock: u32 = 0xff7f;
const XK_KP_Enter: u32 = 0xff8d;
const XK_KP_Home: u32 = 0xff95;
const XK_KP_Delete: u32 = 0xff9f;
const XK_F1: u32 = 0xffbe;
const XK_F12: u32 = 0xffc9;
const XK_Shift_L: u32 = 0xffe1;
const XK_Shift_R: u32 = 0xffe2;
const XK_Control_L: u32 = 0xffe3;
const XK_Control_R: u32 = 0xffe4;
const XK_Caps_Lock: u32 = 0xffe5;
const XK_Meta_L: u32 = 0xffe7;
const XK_Meta_R: u32 = 0xffe8;
const XK_Alt_L: u32 = 0xffe9;
const XK_Alt_R: u32 = 0xffea;
const XK_Super_L: u32 = 0xffeb;
const XK_Super_R: u32 = 0xffec;
const XK_ISO_Left_Tab: u32 = 0xfe20;
const XK_Delete: u32 = 0xffff;

/// Keypad keysyms occupy one contiguous block (KP_Space .. KP_9).
const XK_KP_Space: u32 = 0xff80;
const XK_KP_9: u32 = 0xffb9;

const Entry = struct { sym: u32, key: Key };

/// Non-printable keys. Printable ones are derived, not tabulated.
const table = [_]Entry{
    .{ .sym = XK_BackSpace, .key = .{ .windows_key_code = VK_BACK } },
    .{ .sym = XK_Tab, .key = .{ .windows_key_code = VK_TAB } },
    .{ .sym = XK_ISO_Left_Tab, .key = .{ .windows_key_code = VK_TAB } },
    .{ .sym = XK_Return, .key = .{ .windows_key_code = VK_RETURN, .character = '\r' } },
    .{ .sym = XK_KP_Enter, .key = .{ .windows_key_code = VK_RETURN, .character = '\r', .keypad = true } },
    .{ .sym = XK_Escape, .key = .{ .windows_key_code = VK_ESCAPE, .character = 0x1b } },
    .{ .sym = XK_Pause, .key = .{ .windows_key_code = VK_PAUSE } },
    .{ .sym = XK_Scroll_Lock, .key = .{ .windows_key_code = VK_SCROLL } },
    .{ .sym = XK_Home, .key = .{ .windows_key_code = VK_HOME } },
    .{ .sym = XK_Left, .key = .{ .windows_key_code = VK_LEFT } },
    .{ .sym = XK_Up, .key = .{ .windows_key_code = VK_UP } },
    .{ .sym = XK_Right, .key = .{ .windows_key_code = VK_RIGHT } },
    .{ .sym = XK_Down, .key = .{ .windows_key_code = VK_DOWN } },
    .{ .sym = XK_Prior, .key = .{ .windows_key_code = VK_PRIOR } },
    .{ .sym = XK_Next, .key = .{ .windows_key_code = VK_NEXT } },
    .{ .sym = XK_End, .key = .{ .windows_key_code = VK_END } },
    .{ .sym = XK_Begin, .key = .{ .windows_key_code = VK_CLEAR } },
    .{ .sym = XK_Insert, .key = .{ .windows_key_code = VK_INSERT } },
    .{ .sym = XK_Delete, .key = .{ .windows_key_code = VK_DELETE } },
    .{ .sym = XK_KP_Delete, .key = .{ .windows_key_code = VK_DELETE, .keypad = true } },
    .{ .sym = XK_Num_Lock, .key = .{ .windows_key_code = VK_NUMLOCK } },
    .{ .sym = XK_Caps_Lock, .key = .{ .windows_key_code = VK_CAPITAL } },
    .{ .sym = XK_Shift_L, .key = .{ .windows_key_code = VK_SHIFT } },
    .{ .sym = XK_Shift_R, .key = .{ .windows_key_code = VK_SHIFT } },
    .{ .sym = XK_Control_L, .key = .{ .windows_key_code = VK_CONTROL } },
    .{ .sym = XK_Control_R, .key = .{ .windows_key_code = VK_CONTROL } },
    .{ .sym = XK_Alt_L, .key = .{ .windows_key_code = VK_MENU } },
    .{ .sym = XK_Alt_R, .key = .{ .windows_key_code = VK_MENU } },
    .{ .sym = XK_Meta_L, .key = .{ .windows_key_code = VK_MENU } },
    .{ .sym = XK_Meta_R, .key = .{ .windows_key_code = VK_MENU } },
    .{ .sym = XK_Super_L, .key = .{ .windows_key_code = VK_LWIN } },
    .{ .sym = XK_Super_R, .key = .{ .windows_key_code = VK_RWIN } },
};

/// Virtual-key code for a printable ASCII character, following the
/// Windows layout Chromium expects (letters uppercase, digits bare,
/// punctuation on the US-layout OEM keys).
fn asciiVk(ch: u8) i32 {
    return switch (ch) {
        ' ' => VK_SPACE,
        '0'...'9' => @as(i32, ch),
        'a'...'z' => @as(i32, ch - 'a' + 'A'),
        'A'...'Z' => @as(i32, ch),
        ';', ':' => VK_OEM_1,
        '=', '+' => VK_OEM_PLUS,
        ',', '<' => VK_OEM_COMMA,
        '-', '_' => VK_OEM_MINUS,
        '.', '>' => VK_OEM_PERIOD,
        '/', '?' => VK_OEM_2,
        '`', '~' => VK_OEM_3,
        '[', '{' => VK_OEM_4,
        '\\', '|' => VK_OEM_5,
        ']', '}' => VK_OEM_6,
        '\'', '"' => VK_OEM_7,
        // Shifted digits sit on the digit keys.
        '!' => '1',
        '@' => '2',
        '#' => '3',
        '$' => '4',
        '%' => '5',
        '^' => '6',
        '&' => '7',
        '*' => '8',
        '(' => '9',
        ')' => '0',
        else => 0,
    };
}

/// Map one XKB keysym. Never fails: an unrecognised keysym that still
/// carries a codepoint yields a text-only Key, and one that does not
/// yields an all-zero Key the caller can drop.
pub fn map(keysym: u32) Key {
    for (table) |e| {
        if (e.sym == keysym) return e.key;
    }
    if (keysym >= XK_F1 and keysym <= XK_F12) {
        return .{ .windows_key_code = VK_F1 + @as(i32, @intCast(keysym - XK_F1)) };
    }
    const cp = codepoint(keysym) orelse return .{};
    var key = Key{ .character = if (cp <= 0xffff) @intCast(cp) else 0 };
    if (keysym >= XK_KP_Space and keysym <= XK_KP_9) key.keypad = true;
    if (cp < 0x80) key.windows_key_code = asciiVk(@intCast(cp));
    return key;
}

/// Unicode codepoint a keysym produces, if any: Latin-1 keysyms ARE
/// their codepoint, and everything else uses the `0x01000000 | cp`
/// Unicode-keysym encoding.
pub fn codepoint(keysym: u32) ?u21 {
    if (keysym >= 0x20 and keysym <= 0x7e) return @intCast(keysym);
    if (keysym >= 0xa0 and keysym <= 0xff) return @intCast(keysym);
    if (keysym >= 0x01000020 and keysym <= 0x0110ffff) return @intCast(keysym & 0xffffff);
    // Keypad digits and operators carry no Latin-1 keysym but do type.
    return switch (keysym) {
        0xffaa => '*',
        0xffab => '+',
        0xffad => '-',
        0xffae => '.',
        0xffaf => '/',
        0xffb0...0xffb9 => @intCast(keysym - 0xffb0 + '0'),
        0xffbd => '=',
        else => null,
    };
}

/// Translate protocol modifier bits into Chromium event flags.
pub fn eventFlags(mods: u32) u32 {
    var out: u32 = 0;
    if (mods & 1 != 0) out |= flag_shift;
    if (mods & 2 != 0) out |= flag_control;
    if (mods & 4 != 0) out |= flag_alt;
    if (mods & 8 != 0) out |= flag_command;
    if (mods & 16 != 0) out |= flag_caps_lock;
    if (mods & 32 != 0) out |= flag_num_lock;
    return out;
}

test "enter maps to VK_RETURN with a carriage return character" {
    const k = map(XK_Return);
    try std.testing.expectEqual(VK_RETURN, k.windows_key_code);
    try std.testing.expectEqual(@as(u16, '\r'), k.character);
    try std.testing.expect(!k.keypad);
    try std.testing.expect(map(XK_KP_Enter).keypad);
}

test "lowercase a maps to VK 'A' but types 'a'" {
    const k = map('a');
    try std.testing.expectEqual(@as(i32, 'A'), k.windows_key_code);
    try std.testing.expectEqual(@as(u16, 'a'), k.character);
    const shifted = map('A');
    try std.testing.expectEqual(@as(i32, 'A'), shifted.windows_key_code);
    try std.testing.expectEqual(@as(u16, 'A'), shifted.character);
}

test "F5 is VK_F1 + 4 and types nothing" {
    const k = map(XK_F1 + 4);
    try std.testing.expectEqual(@as(i32, 0x74), k.windows_key_code);
    try std.testing.expectEqual(@as(u16, 0), k.character);
}

test "left arrow is VK_LEFT and types nothing" {
    const k = map(XK_Left);
    try std.testing.expectEqual(VK_LEFT, k.windows_key_code);
    try std.testing.expectEqual(@as(u16, 0), k.character);
}

test "space, punctuation and unicode keysyms" {
    try std.testing.expectEqual(VK_SPACE, map(' ').windows_key_code);
    try std.testing.expectEqual(@as(u16, ' '), map(' ').character);
    try std.testing.expectEqual(VK_OEM_2, map('/').windows_key_code);
    // e-circumflex arrives as a Unicode keysym: text only, no VK.
    const ecirc = map(0x01000000 | 0xea);
    try std.testing.expectEqual(@as(i32, 0), ecirc.windows_key_code);
    try std.testing.expectEqual(@as(u16, 0xea), ecirc.character);
    // Latin-1 keysyms ARE their codepoint.
    try std.testing.expectEqual(@as(u16, 0xe9), map(0xe9).character);
    // A keysym with no text and no table entry is droppable.
    const dead = map(0xfe51); // ISO_Dead_Circumflex-ish: no codepoint
    try std.testing.expectEqual(@as(i32, 0), dead.windows_key_code);
    try std.testing.expectEqual(@as(u16, 0), dead.character);
}

test "modifier bits become chromium event flags" {
    try std.testing.expectEqual(flag_shift | flag_control, eventFlags(1 | 2));
    try std.testing.expectEqual(flag_alt | flag_command, eventFlags(4 | 8));
    try std.testing.expectEqual(@as(u32, 0), eventFlags(0));
}
