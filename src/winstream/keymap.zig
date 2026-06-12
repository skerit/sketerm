//! Input translation tables for the macOS window-stream agent.
//!
//! The wire carries Linux evdev key codes and X11-order modifier
//! bits (winstream/proto.zig input_key) — the GUI side produces
//! them from raw X11/Wayland keycodes with zero translation. The
//! Darwin agent maps them here to CGKeyCodes (kVK_*, ANSI layout)
//! and CGEventFlags before posting CGEvents. Pure data: compiled
//! and unit-tested on every OS.

/// Linux evdev key code → macOS virtual key code (kVK_*).
/// ANSI-US positional mapping — the same convention the Wayland
/// pipe uses (fixed pc105/us keymap). Unmappable codes (media
/// keys, etc.) return null and are dropped.
pub fn evdevToCgKeycode(evdev: u32) ?u16 {
    return switch (evdev) {
        1 => 0x35, // ESC
        2 => 0x12, // 1
        3 => 0x13, // 2
        4 => 0x14, // 3
        5 => 0x15, // 4
        6 => 0x17, // 5
        7 => 0x16, // 6
        8 => 0x1A, // 7
        9 => 0x1C, // 8
        10 => 0x19, // 9
        11 => 0x1D, // 0
        12 => 0x1B, // MINUS
        13 => 0x18, // EQUAL
        14 => 0x33, // BACKSPACE → Delete
        15 => 0x30, // TAB
        16 => 0x0C, // Q
        17 => 0x0D, // W
        18 => 0x0E, // E
        19 => 0x0F, // R
        20 => 0x11, // T
        21 => 0x10, // Y
        22 => 0x20, // U
        23 => 0x22, // I
        24 => 0x1F, // O
        25 => 0x23, // P
        26 => 0x21, // LEFTBRACE
        27 => 0x1E, // RIGHTBRACE
        28 => 0x24, // ENTER → Return
        29 => 0x3B, // LEFTCTRL
        30 => 0x00, // A
        31 => 0x01, // S
        32 => 0x02, // D
        33 => 0x03, // F
        34 => 0x05, // G
        35 => 0x04, // H
        36 => 0x26, // J
        37 => 0x28, // K
        38 => 0x25, // L
        39 => 0x29, // SEMICOLON
        40 => 0x27, // APOSTROPHE → Quote
        41 => 0x32, // GRAVE
        42 => 0x38, // LEFTSHIFT
        43 => 0x2A, // BACKSLASH
        44 => 0x06, // Z
        45 => 0x07, // X
        46 => 0x08, // C
        47 => 0x09, // V
        48 => 0x0B, // B
        49 => 0x2D, // N
        50 => 0x2E, // M
        51 => 0x2B, // COMMA
        52 => 0x2F, // DOT → Period
        53 => 0x2C, // SLASH
        54 => 0x3C, // RIGHTSHIFT
        55 => 0x43, // KPASTERISK
        56 => 0x3A, // LEFTALT → Option
        57 => 0x31, // SPACE
        58 => 0x39, // CAPSLOCK
        59 => 0x7A, // F1
        60 => 0x78, // F2
        61 => 0x63, // F3
        62 => 0x76, // F4
        63 => 0x60, // F5
        64 => 0x61, // F6
        65 => 0x62, // F7
        66 => 0x64, // F8
        67 => 0x65, // F9
        68 => 0x6D, // F10
        69 => 0x47, // NUMLOCK → KeypadClear
        71 => 0x59, // KP7
        72 => 0x5B, // KP8
        73 => 0x5C, // KP9
        74 => 0x4E, // KPMINUS
        75 => 0x56, // KP4
        76 => 0x57, // KP5
        77 => 0x58, // KP6
        78 => 0x45, // KPPLUS
        79 => 0x53, // KP1
        80 => 0x54, // KP2
        81 => 0x55, // KP3
        82 => 0x52, // KP0
        83 => 0x41, // KPDOT → KeypadDecimal
        86 => 0x0A, // 102ND → ISO_Section
        87 => 0x67, // F11
        88 => 0x6F, // F12
        96 => 0x4C, // KPENTER
        97 => 0x3E, // RIGHTCTRL
        98 => 0x4B, // KPSLASH → KeypadDivide
        100 => 0x3D, // RIGHTALT → RightOption
        102 => 0x73, // HOME
        103 => 0x7E, // UP
        104 => 0x74, // PAGEUP
        105 => 0x7B, // LEFT
        106 => 0x7C, // RIGHT
        107 => 0x77, // END
        108 => 0x7D, // DOWN
        109 => 0x79, // PAGEDOWN
        110 => 0x72, // INSERT → Help (closest physical slot)
        111 => 0x75, // DELETE → ForwardDelete
        117 => 0x51, // KPEQUAL
        125 => 0x37, // LEFTMETA → Command
        126 => 0x36, // RIGHTMETA → RightCommand
        else => null,
    };
}

// X11 modifier mask bits (as winapp.zig sends: GdkModifierType & 0xff).
pub const x11_shift: u32 = 1 << 0;
pub const x11_lock: u32 = 1 << 1;
pub const x11_control: u32 = 1 << 2;
pub const x11_mod1: u32 = 1 << 3; // Alt
pub const x11_mod2: u32 = 1 << 4; // NumLock
pub const x11_mod4: u32 = 1 << 6; // Super

// CGEventFlags masks (CGEventTypes.h).
pub const cg_alpha_shift: u64 = 0x00010000;
pub const cg_shift: u64 = 0x00020000;
pub const cg_control: u64 = 0x00040000;
pub const cg_alternate: u64 = 0x00080000;
pub const cg_command: u64 = 0x00100000;

/// X11-order modifier bits → CGEventFlags. Alt→Option, Super→Command;
/// NumLock has no macOS equivalent and is dropped.
pub fn modsToCgFlags(mods: u32) u64 {
    var flags: u64 = 0;
    if (mods & x11_shift != 0) flags |= cg_shift;
    if (mods & x11_lock != 0) flags |= cg_alpha_shift;
    if (mods & x11_control != 0) flags |= cg_control;
    if (mods & x11_mod1 != 0) flags |= cg_alternate;
    if (mods & x11_mod4 != 0) flags |= cg_command;
    return flags;
}

// ── tests ───────────────────────────────────────────────────────

const std = @import("std");
const t = std.testing;

test "evdev→CGKeyCode spot checks" {
    // Letters (evdev A=30 → kVK_ANSI_A=0).
    try t.expectEqual(@as(?u16, 0x00), evdevToCgKeycode(30));
    try t.expectEqual(@as(?u16, 0x0C), evdevToCgKeycode(16)); // Q
    try t.expectEqual(@as(?u16, 0x2E), evdevToCgKeycode(50)); // M
    // Digits row: evdev 2..11 = 1..0.
    try t.expectEqual(@as(?u16, 0x12), evdevToCgKeycode(2)); // 1
    try t.expectEqual(@as(?u16, 0x1D), evdevToCgKeycode(11)); // 0
    // Controls.
    try t.expectEqual(@as(?u16, 0x24), evdevToCgKeycode(28)); // Enter
    try t.expectEqual(@as(?u16, 0x33), evdevToCgKeycode(14)); // Backspace
    try t.expectEqual(@as(?u16, 0x31), evdevToCgKeycode(57)); // Space
    try t.expectEqual(@as(?u16, 0x35), evdevToCgKeycode(1)); // Esc
    // Arrows.
    try t.expectEqual(@as(?u16, 0x7E), evdevToCgKeycode(103)); // Up
    try t.expectEqual(@as(?u16, 0x7B), evdevToCgKeycode(105)); // Left
    // Unmapped (KEY_MUTE=113) drops.
    try t.expectEqual(@as(?u16, null), evdevToCgKeycode(113));
}

test "every mapped keycode is a valid kVK (< 0x80) and letters are distinct" {
    var seen = [_]bool{false} ** 0x80;
    var mapped: usize = 0;
    var code: u32 = 0;
    while (code < 256) : (code += 1) {
        if (evdevToCgKeycode(code)) |vk| {
            try t.expect(vk < 0x80);
            // No two evdev codes may collide on one kVK.
            try t.expect(!seen[vk]);
            seen[vk] = true;
            mapped += 1;
        }
    }
    try t.expect(mapped > 90);
}

test "mods translation" {
    try t.expectEqual(@as(u64, 0), modsToCgFlags(0));
    try t.expectEqual(cg_shift, modsToCgFlags(x11_shift));
    try t.expectEqual(cg_control | cg_alternate, modsToCgFlags(x11_control | x11_mod1));
    // Super → Command; NumLock dropped.
    try t.expectEqual(cg_command, modsToCgFlags(x11_mod4 | x11_mod2));
}
