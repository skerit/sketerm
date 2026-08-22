//! Keyboard encoding conformance tests inspired by
//! kitty/kitty_tests/keys.py — Kitty's tests use their own
//! GLFW-style key constants and progressive-enhancement encoder,
//! so we can't port them verbatim. These exercise our own
//! cursorKey / tildeKey / ssoKey / modCode helpers in
//! src/ui/input.zig at every modifier combo.

const std = @import("std");
const builtin = @import("builtin");

// Re-import the helpers via a thin internal module include.
// The helpers are private to input.zig; we test them through
// public-style copies kept in sync with the originals.
//
// Instead of duplicating the helpers, we re-export them by
// importing input.zig — these tests then live in the same module
// and can call the private functions directly.
const input = @import("input.zig");
const ecmd = @import("../editor/commands.zig");

// Sanity: modCode covers all 8 modifier combos with the xterm
// 1+shift+alt*2+ctrl*4 formula.
test "modCode all 8 combos" {
    const Tbl = struct {
        s: bool,
        a: bool,
        c: bool,
        m: u8,
    };
    const cases = [_]Tbl{
        .{ .s = false, .a = false, .c = false, .m = 1 },
        .{ .s = true, .a = false, .c = false, .m = 2 },
        .{ .s = false, .a = true, .c = false, .m = 3 },
        .{ .s = true, .a = true, .c = false, .m = 4 },
        .{ .s = false, .a = false, .c = true, .m = 5 },
        .{ .s = true, .a = false, .c = true, .m = 6 },
        .{ .s = false, .a = true, .c = true, .m = 7 },
        .{ .s = true, .a = true, .c = true, .m = 8 },
    };
    for (cases) |t| {
        try std.testing.expectEqual(t.m, input.modCode(t.s, t.a, t.c));
    }
}

test "cursorKey legacy mode (DECCKM=off): plain → ESC [ X" {
    var buf: [16]u8 = undefined;
    inline for (.{ 'A', 'B', 'C', 'D', 'H', 'F' }) |final| {
        const n = input.cursorKey(&buf, '[', final, false, false, false);
        const expected = "\x1b[" ++ &[_]u8{final};
        try std.testing.expectEqualSlices(u8, expected, buf[0..n]);
    }
}

test "cursorKey app mode (DECCKM=on): plain → ESC O X" {
    var buf: [16]u8 = undefined;
    inline for (.{ 'A', 'B', 'C', 'D', 'H', 'F' }) |final| {
        const n = input.cursorKey(&buf, 'O', final, false, false, false);
        const expected = "\x1bO" ++ &[_]u8{final};
        try std.testing.expectEqualSlices(u8, expected, buf[0..n]);
    }
}

/// One modifier-encoding case: the key handed to the encoder, the three
/// modifier flags, and the exact bytes it must produce.
const ModCase = struct {
    key: u8,
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
    want: []const u8,
};

/// Run one encoder over its cases, naming the row that fails.
fn expectMods(cases: []const ModCase, comptime encode: fn ([]u8, u8, bool, bool, bool) usize) !void {
    for (cases) |row| {
        var buf: [16]u8 = undefined;
        const n = encode(&buf, row.key, row.shift, row.alt, row.ctrl);
        errdefer std.debug.print("failing case: key {d}, want \"{s}\"\n", .{ row.key, row.want });
        try std.testing.expectEqualStrings(row.want, buf[0..n]);
    }
}

test "cursorKey modifier columns" {
    try expectMods(&.{
        .{ .key = 'A', .shift = true, .want = "\x1b[1;2A" },
        .{ .key = 'A', .alt = true, .want = "\x1b[1;3A" },
        .{ .key = 'D', .ctrl = true, .want = "\x1b[1;5D" },
        .{ .key = 'D', .shift = true, .ctrl = true, .want = "\x1b[1;6D" },
        .{ .key = 'D', .shift = true, .alt = true, .ctrl = true, .want = "\x1b[1;8D" },
    }, struct {
        fn f(buf: []u8, key: u8, shift: bool, alt: bool, ctrl: bool) usize {
            return input.cursorKey(buf, '[', key, shift, alt, ctrl);
        }
    }.f);
}

test "tildeKey modifier columns" {
    try expectMods(&.{
        .{ .key = 5, .want = "\x1b[5~" }, // PgUp
        .{ .key = 6, .shift = true, .want = "\x1b[6;2~" }, // PgDn
        .{ .key = 15, .ctrl = true, .want = "\x1b[15;5~" }, // F5
        .{ .key = 2, .shift = true, .alt = true, .want = "\x1b[2;4~" }, // Insert
    }, input.tildeKey);
}

test "ssoKey modifier columns" {
    try expectMods(&.{
        .{ .key = 'P', .want = "\x1bOP" }, // F1
        .{ .key = 'S', .ctrl = true, .want = "\x1b[1;5S" }, // F4
        .{ .key = 'Q', .shift = true, .alt = true, .want = "\x1b[1;4Q" }, // F2
    }, input.ssoKey);
}

// ── Kitty keyboard protocol ───────────────────────────────────────
//
// Expectations below are taken from the protocol specification and
// cross-checked against kitty's own kitty_tests/keys.py, which is the
// only authority on the cases the prose leaves implicit.

const c = @import("../c.zig").c;

/// Encode one key, spelling out only the fields a case cares about.
fn enc(buf: []u8, in: input.KeyInput) []const u8 {
    return buf[0..input.encode(buf, in)];
}

test "emitCsi: shortest form omits a default key number" {
    var buf: [64]u8 = undefined;
    // Up arrow, nothing held: `CSI A`, not `CSI 1 A`.
    try std.testing.expectEqualStrings("\x1b[A", buf[0..input.emitCsi(&buf, .{ .trailer = 'A' })]);
    // A key number that is not the default is always spelled out.
    try std.testing.expectEqualStrings("\x1b[27u", buf[0..input.emitCsi(&buf, .{ .num = 27 })]);
}

test "emitCsi: event type forces the modifier column" {
    var buf: [64]u8 = undefined;
    const n = input.emitCsi(&buf, .{ .num = 97, .event = .release });
    try std.testing.expectEqualStrings("\x1b[97;1:3u", buf[0..n]);
}

test "emitCsi: text section is positional after an absent modifier column" {
    var buf: [64]u8 = undefined;
    const text = [_]u32{ 104, 105 };
    const n = input.emitCsi(&buf, .{ .num = 97, .text = &text });
    try std.testing.expectEqualStrings("\x1b[97;;104:105u", buf[0..n]);
}

test "emitCsi: an empty shifted field still positions the base-layout key" {
    var buf: [64]u8 = undefined;
    const n = input.emitCsi(&buf, .{ .num = 99, .base_layout = 101, .mods = .{ .ctrl = true } });
    try std.testing.expectEqualStrings("\x1b[99::101;5u", buf[0..n]);
}

test "Mods: kitty parameter carries super, hyper, meta and the locks" {
    try std.testing.expectEqual(@as(u32, 9), (input.Mods{ .super = true }).kittyParam());
    try std.testing.expectEqual(@as(u32, 17), (input.Mods{ .hyper = true }).kittyParam());
    try std.testing.expectEqual(@as(u32, 33), (input.Mods{ .meta = true }).kittyParam());
    try std.testing.expectEqual(@as(u32, 65), (input.Mods{ .caps_lock = true }).kittyParam());
    try std.testing.expectEqual(@as(u32, 129), (input.Mods{ .num_lock = true }).kittyParam());
    try std.testing.expectEqual(@as(u32, 69), (input.Mods{ .ctrl = true, .caps_lock = true }).kittyParam());
    // The legacy parameter deliberately ignores everything xterm has
    // no encoding for, so a non-kitty application never sees a
    // sequence change because Caps Lock happens to be on.
    try std.testing.expectEqual(@as(u8, 1), (input.Mods{ .super = true, .caps_lock = true }).legacyParam());
}

test "no flags: legacy encodings are untouched" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("a", enc(&buf, .{ .keyval = c.GDK_KEY_a }));
    try std.testing.expectEqualStrings("\r", enc(&buf, .{ .keyval = c.GDK_KEY_Return }));
    try std.testing.expectEqualStrings("\t", enc(&buf, .{ .keyval = c.GDK_KEY_Tab }));
    try std.testing.expectEqualStrings("\x7f", enc(&buf, .{ .keyval = c.GDK_KEY_BackSpace }));
    try std.testing.expectEqualStrings("\x1b", enc(&buf, .{ .keyval = c.GDK_KEY_Escape }));
    try std.testing.expectEqualStrings("\x1b[A", enc(&buf, .{ .keyval = c.GDK_KEY_Up }));
    try std.testing.expectEqualStrings("\x1bOA", enc(&buf, .{ .keyval = c.GDK_KEY_Up, .app_cursor = true }));
    try std.testing.expectEqualStrings("\x1b[1;5A", enc(&buf, .{ .keyval = c.GDK_KEY_Up, .mods = .{ .ctrl = true } }));
    try std.testing.expectEqualStrings("\x1bOP", enc(&buf, .{ .keyval = c.GDK_KEY_F1 }));
    try std.testing.expectEqualStrings("\x1b[15~", enc(&buf, .{ .keyval = c.GDK_KEY_F5 }));
    try std.testing.expectEqualStrings("\x1b[Z", enc(&buf, .{ .keyval = c.GDK_KEY_ISO_Left_Tab }));
    try std.testing.expectEqualStrings("\x08", enc(&buf, .{ .keyval = c.GDK_KEY_BackSpace, .mods = .{ .ctrl = true } }));
    try std.testing.expectEqualStrings("\x1b\x7f", enc(&buf, .{ .keyval = c.GDK_KEY_BackSpace, .mods = .{ .alt = true } }));
}

test "no flags: Super cannot perturb a legacy sequence" {
    var buf: [64]u8 = undefined;
    // On macOS the GUI-modifier chord is swallowed outright (see the
    // companion test below); on Linux it must pass through unperturbed
    // because X11 keymaps routinely alias Meta onto the Alt key.
    const expected = if (builtin.os.tag == .macos) "" else "\x1b[A";
    try std.testing.expectEqualStrings(expected, enc(&buf, .{ .keyval = c.GDK_KEY_Up, .mods = .{ .super = true } }));
}

test "no flags: an unbound Command chord produces no bytes (macOS)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var buf: [64]u8 = undefined;
    // The legacy encodings cannot express Cmd; falling through used to
    // fabricate a keypress (Cmd+Y typed 'y', Cmd+Left acted as Left).
    try std.testing.expectEqualStrings("", enc(&buf, .{ .keyval = c.GDK_KEY_y, .mods = .{ .meta = true } }));
    try std.testing.expectEqualStrings("", enc(&buf, .{ .keyval = c.GDK_KEY_Left, .mods = .{ .meta = true } }));
    try std.testing.expectEqualStrings("", enc(&buf, .{ .keyval = c.GDK_KEY_Return, .mods = .{ .meta = true } }));
    try std.testing.expectEqualStrings("", enc(&buf, .{ .keyval = c.GDK_KEY_y, .mods = .{ .meta = true, .shift = true } }));
}

test "kitty opt-in still reports Command chords (macOS)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    // An application that asked for disambiguation expects to bind
    // GUI-modifier chords; meta is bit 5, so the parameter is 1+32.
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[121;33u", enc(&buf, .{
        .keyval = c.GDK_KEY_y,
        .mods = .{ .meta = true },
        .kitty_flags = input.FLAG_DISAMBIGUATE,
    }));
}

test "0x01 disambiguate: only Escape and modified keys change" {
    var buf: [64]u8 = undefined;
    const f = input.FLAG_DISAMBIGUATE;
    try std.testing.expectEqualStrings("a", enc(&buf, .{ .keyval = c.GDK_KEY_a, .kitty_flags = f }));
    try std.testing.expectEqualStrings("\x1b[27u", enc(&buf, .{ .keyval = c.GDK_KEY_Escape, .kitty_flags = f }));
    try std.testing.expectEqualStrings("\r", enc(&buf, .{ .keyval = c.GDK_KEY_Return, .kitty_flags = f }));
    try std.testing.expectEqualStrings("\t", enc(&buf, .{ .keyval = c.GDK_KEY_Tab, .kitty_flags = f }));
    try std.testing.expectEqualStrings("\x7f", enc(&buf, .{ .keyval = c.GDK_KEY_BackSpace, .kitty_flags = f }));
    try std.testing.expectEqualStrings("\x1b[13;2u", enc(&buf, .{ .keyval = c.GDK_KEY_Return, .mods = .{ .shift = true }, .kitty_flags = f }));
    try std.testing.expectEqualStrings("\x1b[9;2u", enc(&buf, .{ .keyval = c.GDK_KEY_ISO_Left_Tab, .kitty_flags = f }));
    try std.testing.expectEqualStrings("\x1b[97;5u", enc(&buf, .{ .keyval = c.GDK_KEY_a, .mods = .{ .ctrl = true }, .kitty_flags = f }));
    // Shift alone on a text key stays legacy: it selects a glyph, and
    // the glyph is what gets sent.
    try std.testing.expectEqualStrings("A", enc(&buf, .{ .keyval = c.GDK_KEY_A, .mods = .{ .shift = true }, .kitty_flags = f }));
    // F-keys and arrows keep their VT encodings under disambiguate.
    try std.testing.expectEqualStrings("\x1bOP", enc(&buf, .{ .keyval = c.GDK_KEY_F1, .kitty_flags = f }));
    try std.testing.expectEqualStrings("\x1b[A", enc(&buf, .{ .keyval = c.GDK_KEY_Up, .kitty_flags = f }));
}

test "0x08 report-all: every key becomes an escape code" {
    var buf: [64]u8 = undefined;
    const f = input.FLAG_REPORT_ALL;
    try std.testing.expectEqualStrings("\x1b[97u", enc(&buf, .{ .keyval = c.GDK_KEY_a, .kitty_flags = f }));
    try std.testing.expectEqualStrings("\x1b[97;5u", enc(&buf, .{ .keyval = c.GDK_KEY_a, .mods = .{ .ctrl = true }, .kitty_flags = f }));
    try std.testing.expectEqualStrings("\x1b[13u", enc(&buf, .{ .keyval = c.GDK_KEY_Return, .kitty_flags = f }));
    try std.testing.expectEqualStrings("\x1b[9u", enc(&buf, .{ .keyval = c.GDK_KEY_Tab, .kitty_flags = f }));
    try std.testing.expectEqualStrings("\x1b[127u", enc(&buf, .{ .keyval = c.GDK_KEY_BackSpace, .kitty_flags = f }));
    try std.testing.expectEqualStrings("\x1b[27u", enc(&buf, .{ .keyval = c.GDK_KEY_Escape, .kitty_flags = f }));
}

test "0x08 report-all: keys with a legacy encoding keep it" {
    // The Private Use Area codepoints are for keys that never had a
    // VT sequence. Reporting `CSI 57352 u` for Up instead of `CSI A`
    // leaves the arrow keys dead in every application that does not
    // implement kitty's optional alias table.
    var buf: [64]u8 = undefined;
    const f = input.FLAG_REPORT_ALL;
    try std.testing.expectEqualStrings("\x1b[A", enc(&buf, .{ .keyval = c.GDK_KEY_Up, .kitty_flags = f }));
    try std.testing.expectEqualStrings("\x1b[D", enc(&buf, .{ .keyval = c.GDK_KEY_Left, .kitty_flags = f }));
    try std.testing.expectEqualStrings("\x1b[H", enc(&buf, .{ .keyval = c.GDK_KEY_Home, .kitty_flags = f }));
    try std.testing.expectEqualStrings("\x1b[5~", enc(&buf, .{ .keyval = c.GDK_KEY_Page_Up, .kitty_flags = f }));
    try std.testing.expectEqualStrings("\x1b[3~", enc(&buf, .{ .keyval = c.GDK_KEY_Delete, .kitty_flags = f }));
    try std.testing.expectEqualStrings("\x1bOP", enc(&buf, .{ .keyval = c.GDK_KEY_F1, .kitty_flags = f }));
    try std.testing.expectEqualStrings("\x1b[1;5S", enc(&buf, .{ .keyval = c.GDK_KEY_F4, .mods = .{ .ctrl = true }, .kitty_flags = f }));
    try std.testing.expectEqualStrings("\x1b[24~", enc(&buf, .{ .keyval = c.GDK_KEY_F12, .kitty_flags = f }));
}

test "keys with no legacy encoding use their Private Use Area codepoint" {
    var buf: [64]u8 = undefined;
    const f = input.FLAG_REPORT_ALL;
    try std.testing.expectEqualStrings("\x1b[57376u", enc(&buf, .{ .keyval = c.GDK_KEY_F13, .kitty_flags = f }));
    try std.testing.expectEqualStrings("\x1b[57398u", enc(&buf, .{ .keyval = c.GDK_KEY_F35, .kitty_flags = f }));
    try std.testing.expectEqualStrings("\x1b[57404u", enc(&buf, .{ .keyval = c.GDK_KEY_KP_5, .kitty_flags = f }));
    try std.testing.expectEqualStrings("\x1b[57414u", enc(&buf, .{ .keyval = c.GDK_KEY_KP_Enter, .kitty_flags = f }));
    try std.testing.expectEqualStrings("\x1b[57423u", enc(&buf, .{ .keyval = c.GDK_KEY_KP_Home, .kitty_flags = f }));
    try std.testing.expectEqualStrings("\x1b[57358u", enc(&buf, .{ .keyval = c.GDK_KEY_Caps_Lock, .kitty_flags = f }));
    try std.testing.expectEqualStrings("\x1b[57363u", enc(&buf, .{ .keyval = c.GDK_KEY_Menu, .kitty_flags = f }));
    try std.testing.expectEqualStrings("\x1b[57440u", enc(&buf, .{ .keyval = c.GDK_KEY_AudioMute, .kitty_flags = f }));
}

test "modifier keys report only under report-all" {
    var buf: [64]u8 = undefined;
    for ([_]u8{ 0, input.FLAG_DISAMBIGUATE, input.FLAG_EVENT_TYPES, input.FLAG_ALTERNATE_KEYS }) |f| {
        try std.testing.expectEqualStrings("", enc(&buf, .{ .keyval = c.GDK_KEY_Shift_L, .kitty_flags = f }));
    }
    const f = input.FLAG_REPORT_ALL;
    try std.testing.expectEqualStrings("\x1b[57441u", enc(&buf, .{ .keyval = c.GDK_KEY_Shift_L, .kitty_flags = f }));
    try std.testing.expectEqualStrings("\x1b[57448u", enc(&buf, .{ .keyval = c.GDK_KEY_Control_R, .kitty_flags = f }));
    try std.testing.expectEqualStrings("\x1b[57444u", enc(&buf, .{ .keyval = c.GDK_KEY_Super_L, .kitty_flags = f }));
    try std.testing.expectEqualStrings("\x1b[57453u", enc(&buf, .{ .keyval = c.GDK_KEY_ISO_Level3_Shift, .kitty_flags = f }));
    // …and their release, once event types are on too.
    const n = input.encode(&buf, .{
        .keyval = c.GDK_KEY_Shift_L,
        .event = .release,
        .kitty_flags = input.FLAG_REPORT_ALL | input.FLAG_EVENT_TYPES,
    });
    try std.testing.expectEqualStrings("\x1b[57441;1:3u", buf[0..n]);
}

test "0x02 event types: releases and repeats for every reportable key" {
    var buf: [64]u8 = undefined;
    const ev = input.FLAG_EVENT_TYPES;
    // Without the flag there is no release report at all.
    try std.testing.expectEqualStrings("", enc(&buf, .{ .keyval = c.GDK_KEY_a, .event = .release }));
    try std.testing.expectEqualStrings("", enc(&buf, .{ .keyval = c.GDK_KEY_Up, .event = .release }));
    // With it, a text key's non-press events switch to CSI form.
    try std.testing.expectEqualStrings("\x1b[97;1:3u", enc(&buf, .{ .keyval = c.GDK_KEY_a, .event = .release, .kitty_flags = ev }));
    try std.testing.expectEqualStrings("\x1b[97;1:2u", enc(&buf, .{ .keyval = c.GDK_KEY_a, .event = .repeat, .kitty_flags = ev }));
    try std.testing.expectEqualStrings("\x1b[97;2:3u", enc(&buf, .{ .keyval = c.GDK_KEY_A, .mods = .{ .shift = true }, .event = .release, .kitty_flags = ev }));
    // Functional keys keep their trailer and gain the event column.
    try std.testing.expectEqualStrings("\x1b[1;1:3A", enc(&buf, .{ .keyval = c.GDK_KEY_Up, .event = .release, .kitty_flags = ev }));
    try std.testing.expectEqualStrings("\x1b[15;1:3~", enc(&buf, .{ .keyval = c.GDK_KEY_F5, .event = .release, .kitty_flags = ev }));
    try std.testing.expectEqualStrings("\x1b[57376;1:3u", enc(&buf, .{ .keyval = c.GDK_KEY_F13, .event = .release, .kitty_flags = ev }));
}

test "0x02 event types: a plain control byte has no release form" {
    // Escape, Enter, Tab and Backspace are sent as single control
    // bytes here, and a control byte cannot carry an event type, so
    // the release is dropped rather than invented. Verified against
    // kitty, which drops it too.
    var buf: [64]u8 = undefined;
    const f = input.FLAG_DISAMBIGUATE | input.FLAG_EVENT_TYPES;
    try std.testing.expectEqualStrings("\x7f", enc(&buf, .{ .keyval = c.GDK_KEY_BackSpace, .kitty_flags = f }));
    try std.testing.expectEqualStrings("", enc(&buf, .{ .keyval = c.GDK_KEY_BackSpace, .event = .release, .kitty_flags = f }));
    try std.testing.expectEqualStrings("", enc(&buf, .{ .keyval = c.GDK_KEY_Return, .event = .release, .kitty_flags = f }));
    // Once they ARE escape codes, their releases report normally.
    const g = input.FLAG_REPORT_ALL | input.FLAG_EVENT_TYPES;
    try std.testing.expectEqualStrings("\x1b[127;1:3u", enc(&buf, .{ .keyval = c.GDK_KEY_BackSpace, .event = .release, .kitty_flags = g }));
}

test "0x04 alternate keys: shifted variant only while Shift is held" {
    var buf: [64]u8 = undefined;
    const f = input.FLAG_ALTERNATE_KEYS | input.FLAG_REPORT_ALL;
    try std.testing.expectEqualStrings("\x1b[97u", enc(&buf, .{
        .keyval = c.GDK_KEY_a,
        .base_keyval = c.GDK_KEY_a,
        .shifted_keyval = c.GDK_KEY_A,
        .kitty_flags = f,
    }));
    try std.testing.expectEqualStrings("\x1b[97:65;2u", enc(&buf, .{
        .keyval = c.GDK_KEY_A,
        .mods = .{ .shift = true },
        .base_keyval = c.GDK_KEY_a,
        .shifted_keyval = c.GDK_KEY_A,
        .kitty_flags = f,
    }));
}

test "0x04 alternate keys: the key number is the unshifted key" {
    // Shift+2 on a US layout is '@'. The protocol wants the key ('2')
    // with the glyph as its shifted variant, not the glyph as the key.
    var buf: [64]u8 = undefined;
    const n = input.encode(&buf, .{
        .keyval = c.GDK_KEY_at,
        .mods = .{ .shift = true },
        .base_keyval = c.GDK_KEY_2,
        .shifted_keyval = c.GDK_KEY_at,
        .kitty_flags = input.FLAG_ALTERNATE_KEYS | input.FLAG_REPORT_ALL,
    });
    try std.testing.expectEqualStrings("\x1b[50:64;2u", buf[0..n]);
}

test "0x04 alternate keys: base layout rescues shortcuts on a non-Latin layout" {
    // Ctrl+С on a Cyrillic layout sits on the physical 'c' key
    // (evdev 46 + 8), so the application still sees a 'c' to bind.
    var buf: [64]u8 = undefined;
    const n = input.encode(&buf, .{
        .keyval = 0x06d3, // Cyrillic_es
        .mods = .{ .ctrl = true },
        .keycode = 54,
        .base_keyval = 0x06d3,
        .kitty_flags = input.FLAG_ALTERNATE_KEYS | input.FLAG_DISAMBIGUATE,
    });
    // PLATFORM GAP, not a test quirk: `input.baseLayoutCodepoint` maps
    // evdev-derived hardware keycodes, which only X11 and Wayland
    // deliver, so it returns 0 off Linux and the base-layout alternate
    // is omitted. The consequence is REAL — Ctrl+shortcuts on a
    // non-Latin layout get no base-layout rescue on macOS. Do not
    // "fix" this by faking a codepoint; fixing it means teaching
    // baseLayoutCodepoint the macOS keycode space.
    if (builtin.os.tag != .linux) {
        try std.testing.expectEqualStrings("\x1b[1089;5u", buf[0..n]);
        return;
    }
    try std.testing.expectEqualStrings("\x1b[1089::99;5u", buf[0..n]);
}

test "0x10 associated text" {
    var buf: [64]u8 = undefined;
    const f = input.FLAG_ASSOCIATED_TEXT | input.FLAG_REPORT_ALL;
    try std.testing.expectEqualStrings("\x1b[97;;97u", enc(&buf, .{ .keyval = c.GDK_KEY_a, .base_keyval = c.GDK_KEY_a, .kitty_flags = f }));
    try std.testing.expectEqualStrings("\x1b[97;2;65u", enc(&buf, .{
        .keyval = c.GDK_KEY_A,
        .mods = .{ .shift = true },
        .base_keyval = c.GDK_KEY_a,
        .kitty_flags = f,
    }));
    // A control modifier means the keystroke would have produced no
    // text, so the section is omitted entirely.
    try std.testing.expectEqualStrings("\x1b[97;5u", enc(&buf, .{
        .keyval = c.GDK_KEY_a,
        .mods = .{ .ctrl = true },
        .kitty_flags = input.FLAG_ASSOCIATED_TEXT | input.FLAG_DISAMBIGUATE,
    }));
}

test "lock keys reach the wire only through the protocol's modifier field" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[97;69u", enc(&buf, .{
        .keyval = c.GDK_KEY_a,
        .mods = .{ .ctrl = true, .caps_lock = true },
        .base_keyval = c.GDK_KEY_a,
        .kitty_flags = input.FLAG_DISAMBIGUATE,
    }));
    // Same event with no flags: the legacy control byte, unchanged.
    try std.testing.expectEqualStrings("\x01", enc(&buf, .{
        .keyval = c.GDK_KEY_a,
        .mods = .{ .ctrl = true, .caps_lock = true },
    }));
}

// ── matchBinding dispatch table coverage ──────────────────────────

test "matchBinding: Ctrl+Shift+T → new_tab (Linux table)" {
    const ctrl_shift = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK;
    const got = input.matchBinding(&input.linux_default_bindings, c.GDK_KEY_t, ctrl_shift);
    try std.testing.expectEqual(@as(?input.Action, .new_tab), got);
}

test "matchBinding: Ctrl+Tab → next_tab on BOTH platform tables" {
    for ([_][]const input.Binding{ &input.linux_default_bindings, &input.macos_default_bindings }) |tbl| {
        const got = input.matchBinding(tbl, c.GDK_KEY_Tab, c.GDK_CONTROL_MASK);
        try std.testing.expectEqual(@as(?input.Action, .next_tab), got);
    }
}

test "matchBinding: macOS app defaults live on Command" {
    const M: c_uint = c.GDK_META_MASK;
    const MS: c_uint = c.GDK_META_MASK | c.GDK_SHIFT_MASK;
    const cases = [_]struct { keyval: c_uint, mods: c_uint, action: input.Action }{
        .{ .keyval = c.GDK_KEY_t, .mods = M, .action = .new_tab },
        .{ .keyval = c.GDK_KEY_w, .mods = M, .action = .close_tab },
        // Cmd+C is a PLAIN copy: Ctrl+C reaches the shell untouched on
        // macOS, so the interrupt_or_copy heuristic has no reason to
        // exist there.
        .{ .keyval = c.GDK_KEY_c, .mods = M, .action = .copy_selection },
        .{ .keyval = c.GDK_KEY_v, .mods = M, .action = .paste_clipboard },
        .{ .keyval = c.GDK_KEY_a, .mods = M, .action = .select_all },
        .{ .keyval = c.GDK_KEY_comma, .mods = M, .action = .prefs_open },
        .{ .keyval = c.GDK_KEY_1, .mods = M, .action = .goto_tab_1 },
        .{ .keyval = c.GDK_KEY_9, .mods = M, .action = .goto_tab_9 },
        // Cmd+Shift+T, the macOS-browser reopen convention — NOT
        // Cmd+Z, which means Undo everywhere.
        .{ .keyval = c.GDK_KEY_t, .mods = MS, .action = .restore_closed_tab },
        .{ .keyval = c.GDK_KEY_p, .mods = MS, .action = .command_palette },
        .{ .keyval = c.GDK_KEY_braceleft, .mods = MS, .action = .prev_tab },
        .{ .keyval = c.GDK_KEY_braceright, .mods = MS, .action = .next_tab },
    };
    for (cases) |case| {
        try std.testing.expectEqual(
            @as(?input.Action, case.action),
            input.matchBinding(&input.macos_default_bindings, case.keyval, case.mods),
        );
    }
    // Cmd+Z stays free for Undo.
    try std.testing.expectEqual(
        @as(?input.Action, null),
        input.matchBinding(&input.macos_default_bindings, c.GDK_KEY_z, M),
    );
}

test "macOS defaults: Control belongs to the shell" {
    // The one deliberate exception is the Ctrl+Tab tab-switch family;
    // every other Control chord must reach the child so Ctrl+C is
    // SIGINT and readline keeps its whole namespace.
    for (input.macos_default_bindings) |b| {
        if (b.mods & c.GDK_CONTROL_MASK == 0) continue;
        try std.testing.expect(b.keyval == c.GDK_KEY_Tab or b.keyval == c.GDK_KEY_ISO_Left_Tab);
    }
}

test "parseAccel: <Cmd>/<Command> alias <Meta>, round-trip stable" {
    const p = input.parseAccel("<Cmd>t").?;
    try std.testing.expectEqual(@as(c_uint, c.GDK_KEY_t), p.keyval);
    try std.testing.expect(p.mods & c.GDK_META_MASK != 0);
    const q = input.parseAccel("<Command><Shift>p").?;
    try std.testing.expect(q.mods & c.GDK_META_MASK != 0);
    try std.testing.expect(q.mods & c.GDK_SHIFT_MASK != 0);
    // parse → format → parse: gtk_accelerator_name spells it <Meta>,
    // which must land on the same (keyval, mods).
    const s = try input.accelToString(std.testing.allocator, p.keyval, p.mods);
    defer std.testing.allocator.free(s);
    const p2 = input.parseAccel(s).?;
    try std.testing.expectEqual(p.keyval, p2.keyval);
    try std.testing.expectEqual(p.mods, p2.mods);
}

test "matchBinding: Linux tree-tab defaults match their documented chords" {
    const cases = [_]struct { keyval: c_uint, mods: c_uint, action: input.Action }{
        .{ .keyval = c.GDK_KEY_b, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK | c.GDK_ALT_MASK, .action = .toggle_tab_sidebar },
        .{ .keyval = c.GDK_KEY_h, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK | c.GDK_ALT_MASK, .action = .tab_collapse },
        .{ .keyval = c.GDK_KEY_e, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK | c.GDK_ALT_MASK, .action = .tab_expand },
        .{ .keyval = c.GDK_KEY_Page_Down, .mods = c.GDK_CONTROL_MASK | c.GDK_ALT_MASK, .action = .tab_tree_next },
        .{ .keyval = c.GDK_KEY_Page_Up, .mods = c.GDK_CONTROL_MASK | c.GDK_ALT_MASK, .action = .tab_tree_prev },
    };
    for (cases) |case| {
        try std.testing.expectEqual(
            @as(?input.Action, case.action),
            input.matchBinding(&input.linux_default_bindings, case.keyval, case.mods),
        );
    }
}

test "matchBinding: macOS tree-tab defaults stay outside VoiceOver chords" {
    const cases = [_]struct { keyval: c_uint, mods: c_uint, action: input.Action }{
        .{ .keyval = c.GDK_KEY_b, .mods = c.GDK_META_MASK | c.GDK_SHIFT_MASK | c.GDK_ALT_MASK, .action = .toggle_tab_sidebar },
        .{ .keyval = c.GDK_KEY_h, .mods = c.GDK_META_MASK | c.GDK_SHIFT_MASK | c.GDK_ALT_MASK, .action = .tab_collapse },
        .{ .keyval = c.GDK_KEY_e, .mods = c.GDK_META_MASK | c.GDK_SHIFT_MASK | c.GDK_ALT_MASK, .action = .tab_expand },
        .{ .keyval = c.GDK_KEY_Page_Down, .mods = c.GDK_META_MASK | c.GDK_ALT_MASK, .action = .tab_tree_next },
        .{ .keyval = c.GDK_KEY_Page_Up, .mods = c.GDK_META_MASK | c.GDK_ALT_MASK, .action = .tab_tree_prev },
    };
    for (cases) |case| {
        try std.testing.expect(case.mods & c.GDK_CONTROL_MASK == 0);
        try std.testing.expectEqual(
            @as(?input.Action, case.action),
            input.matchBinding(&input.macos_default_bindings, case.keyval, case.mods),
        );
    }
}

fn expectNoBindingCollisions(bindings: []const input.Binding) !void {
    for (bindings, 0..) |binding, i| {
        for (bindings[i + 1 ..]) |other| {
            const same_key = binding.keyval == other.keyval;
            const same_mods = (binding.mods & input.SIGNIFICANT_MODS) ==
                (other.mods & input.SIGNIFICANT_MODS);
            if (same_key and same_mods) {
                std.debug.print("default actions {s} and {s} share one accelerator\n", .{
                    input.actionName(binding.action),
                    input.actionName(other.action),
                });
                return error.DefaultBindingCollision;
            }
        }
    }
}

test "platform default bindings contain no accelerator collisions" {
    try expectNoBindingCollisions(&input.linux_default_bindings);
    try expectNoBindingCollisions(&input.macos_default_bindings);
}

test "tree-tab defaults do not shadow face-local command registries" {
    for (input.linux_tree_bindings ++ input.macos_tree_bindings) |binding| {
        for (0..ecmd.COMMAND_COUNT) |i| {
            const cmd: ecmd.Command = @enumFromInt(i);
            const parsed = input.parseAccel(ecmd.defaultAccel(cmd)) orelse continue;
            if (binding.keyval == parsed.keyval and
                (binding.mods & input.SIGNIFICANT_MODS) == (parsed.mods & input.SIGNIFICANT_MODS))
            {
                std.debug.print("tree action {s} shadows editor command {s}\n", .{
                    input.actionName(binding.action),
                    ecmd.name(cmd),
                });
                return error.TreeBindingShadowsEditorCommand;
            }
        }
    }
}

test "Linux tree-tab defaults avoid common desktop reservations" {
    const reserved = [_]struct { keyval: c_uint, mods: c_uint, what: []const u8 }{
        .{ .keyval = c.GDK_KEY_Tab, .mods = c.GDK_ALT_MASK, .what = "switch applications" },
        .{ .keyval = c.GDK_KEY_Tab, .mods = c.GDK_CONTROL_MASK | c.GDK_ALT_MASK, .what = "switch panels" },
        .{ .keyval = c.GDK_KEY_Escape, .mods = c.GDK_ALT_MASK, .what = "cycle windows" },
        .{ .keyval = c.GDK_KEY_Escape, .mods = c.GDK_CONTROL_MASK | c.GDK_ALT_MASK, .what = "cycle panels" },
        .{ .keyval = c.GDK_KEY_Up, .mods = c.GDK_CONTROL_MASK | c.GDK_ALT_MASK, .what = "workspace up" },
        .{ .keyval = c.GDK_KEY_Down, .mods = c.GDK_CONTROL_MASK | c.GDK_ALT_MASK, .what = "workspace down" },
        .{ .keyval = c.GDK_KEY_Left, .mods = c.GDK_CONTROL_MASK | c.GDK_ALT_MASK, .what = "workspace left" },
        .{ .keyval = c.GDK_KEY_Right, .mods = c.GDK_CONTROL_MASK | c.GDK_ALT_MASK, .what = "workspace right" },
        .{ .keyval = c.GDK_KEY_r, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK | c.GDK_ALT_MASK, .what = "screen recording" },
    };
    for (input.linux_tree_bindings) |binding| {
        for (reserved) |desktop| {
            if (binding.keyval == desktop.keyval and
                (binding.mods & input.SIGNIFICANT_MODS) == (desktop.mods & input.SIGNIFICANT_MODS))
            {
                std.debug.print("tree action {s} collides with desktop shortcut {s}\n", .{
                    input.actionName(binding.action),
                    desktop.what,
                });
                return error.TreeBindingDesktopCollision;
            }
        }
    }
}

test "matchBinding: ignores Lock + Group bits via SIGNIFICANT_MODS filter" {
    // Caps Lock (GDK_LOCK_MASK = 0x02) is NOT in the significant set;
    // a binding for Ctrl+Shift+T should still match when Lock is on.
    // (The Linux table, explicitly: the macOS table has no Ctrl+Shift
    // chords and the filter under test is platform-independent.)
    const bindings = &input.linux_default_bindings;
    const mods: c_uint = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK | c.GDK_LOCK_MASK;
    const got = input.matchBinding(bindings, c.GDK_KEY_t, mods);
    try std.testing.expectEqual(@as(?input.Action, .new_tab), got);
}

test "matchBinding: unmatched key returns null" {
    const bindings = input.default_bindings[0..];
    // No default binding for plain F12.
    const got = input.matchBinding(bindings, c.GDK_KEY_F12, 0);
    try std.testing.expectEqual(@as(?input.Action, null), got);
}

test "matchBinding: wrong mods don't match (Ctrl+T alone, no Shift)" {
    const bindings = input.default_bindings[0..];
    const got = input.matchBinding(bindings, c.GDK_KEY_t, c.GDK_CONTROL_MASK);
    try std.testing.expectEqual(@as(?input.Action, null), got);
}

test "matchBinding: first-match wins on duplicate accelerators" {
    // Build a table where two entries collide on the accel — first
    // wins per the linear-scan implementation. Documents the contract
    // so callers can rely on order when overriding defaults.
    const bindings = [_]input.Binding{
        .{ .keyval = c.GDK_KEY_a, .mods = 0, .action = .copy },
        .{ .keyval = c.GDK_KEY_a, .mods = 0, .action = .paste },
    };
    const got = input.matchBinding(bindings[0..], c.GDK_KEY_a, 0);
    try std.testing.expectEqual(@as(?input.Action, .copy), got);
}
