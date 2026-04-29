//! Keyboard encoding conformance tests inspired by
//! kitty/kitty_tests/keys.py — Kitty's tests use their own
//! GLFW-style key constants and progressive-enhancement encoder,
//! so we can't port them verbatim. These exercise our own
//! cursorKey / tildeKey / ssoKey / modCode helpers in
//! src/ui/input.zig at every modifier combo.

const std = @import("std");

// Re-import the helpers via a thin internal module include.
// The helpers are private to input.zig; we test them through
// public-style copies kept in sync with the originals.
//
// Instead of duplicating the helpers, we re-export them by
// importing input.zig — these tests then live in the same module
// and can call the private functions directly.
const input = @import("input.zig");

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

test "cursorKey shift only → ESC [ 1 ; 2 X" {
    var buf: [16]u8 = undefined;
    const n = input.cursorKey(&buf, '[', 'A', true, false, false);
    try std.testing.expectEqualStrings("\x1b[1;2A", buf[0..n]);
}

test "cursorKey alt only → ESC [ 1 ; 3 X" {
    var buf: [16]u8 = undefined;
    const n = input.cursorKey(&buf, '[', 'A', false, true, false);
    try std.testing.expectEqualStrings("\x1b[1;3A", buf[0..n]);
}

test "cursorKey ctrl only → ESC [ 1 ; 5 X" {
    var buf: [16]u8 = undefined;
    const n = input.cursorKey(&buf, '[', 'D', false, false, true);
    try std.testing.expectEqualStrings("\x1b[1;5D", buf[0..n]);
}

test "cursorKey ctrl+shift → ESC [ 1 ; 6 X" {
    var buf: [16]u8 = undefined;
    const n = input.cursorKey(&buf, '[', 'D', true, false, true);
    try std.testing.expectEqualStrings("\x1b[1;6D", buf[0..n]);
}

test "cursorKey ctrl+alt+shift → ESC [ 1 ; 8 X" {
    var buf: [16]u8 = undefined;
    const n = input.cursorKey(&buf, '[', 'D', true, true, true);
    try std.testing.expectEqualStrings("\x1b[1;8D", buf[0..n]);
}

test "tildeKey plain (PgUp = 5)" {
    var buf: [16]u8 = undefined;
    const n = input.tildeKey(&buf, 5, false, false, false);
    try std.testing.expectEqualStrings("\x1b[5~", buf[0..n]);
}

test "tildeKey with shift (PgDn = 6)" {
    var buf: [16]u8 = undefined;
    const n = input.tildeKey(&buf, 6, true, false, false);
    try std.testing.expectEqualStrings("\x1b[6;2~", buf[0..n]);
}

test "tildeKey F5 (15) ctrl" {
    var buf: [16]u8 = undefined;
    const n = input.tildeKey(&buf, 15, false, false, true);
    try std.testing.expectEqualStrings("\x1b[15;5~", buf[0..n]);
}

test "tildeKey Insert (2) alt+shift" {
    var buf: [16]u8 = undefined;
    const n = input.tildeKey(&buf, 2, true, true, false);
    try std.testing.expectEqualStrings("\x1b[2;4~", buf[0..n]);
}

test "ssoKey F1 plain → ESC O P" {
    var buf: [16]u8 = undefined;
    const n = input.ssoKey(&buf, 'P', false, false, false);
    try std.testing.expectEqualStrings("\x1bOP", buf[0..n]);
}

test "ssoKey F4 ctrl → ESC [ 1 ; 5 S" {
    var buf: [16]u8 = undefined;
    const n = input.ssoKey(&buf, 'S', false, false, true);
    try std.testing.expectEqualStrings("\x1b[1;5S", buf[0..n]);
}

test "ssoKey F2 shift+alt → ESC [ 1 ; 4 Q" {
    var buf: [16]u8 = undefined;
    const n = input.ssoKey(&buf, 'Q', true, true, false);
    try std.testing.expectEqualStrings("\x1b[1;4Q", buf[0..n]);
}

test "kittyKey plain Esc → CSI 27 u" {
    var buf: [16]u8 = undefined;
    const n = input.kittyKey(&buf, 27, false, false, false);
    try std.testing.expectEqualStrings("\x1b[27u", buf[0..n]);
}

test "kittyKey Shift+Tab → CSI 9 ; 2 u" {
    var buf: [16]u8 = undefined;
    const n = input.kittyKey(&buf, 9, true, false, false);
    try std.testing.expectEqualStrings("\x1b[9;2u", buf[0..n]);
}

test "kittyKey Ctrl+I → CSI 105 ; 5 u" {
    var buf: [16]u8 = undefined;
    const n = input.kittyKey(&buf, 105, false, false, true);
    try std.testing.expectEqualStrings("\x1b[105;5u", buf[0..n]);
}

test "kittyKey Ctrl+Shift+H → CSI 104 ; 6 u" {
    var buf: [16]u8 = undefined;
    const n = input.kittyKey(&buf, 104, true, false, true);
    try std.testing.expectEqualStrings("\x1b[104;6u", buf[0..n]);
}

test "kittyKeyEvent press → no event suffix" {
    var buf: [16]u8 = undefined;
    const n = input.kittyKeyEvent(&buf, 27, false, false, false, 1);
    try std.testing.expectEqualStrings("\x1b[27u", buf[0..n]);
}

test "kittyKeyEvent release adds :3 sub-parameter" {
    var buf: [16]u8 = undefined;
    const n = input.kittyKeyEvent(&buf, 105, false, false, true, 3);
    try std.testing.expectEqualStrings("\x1b[105;5:3u", buf[0..n]);
}

test "kittyKeyEvent repeat with mods" {
    var buf: [16]u8 = undefined;
    const n = input.kittyKeyEvent(&buf, 113, true, false, false, 2);
    try std.testing.expectEqualStrings("\x1b[113;2:2u", buf[0..n]);
}

test "kittyKeyEvent plain repeat → :2 sub-parameter (no mods)" {
    // Repeat with no modifiers — kitty spec emits `CSI <kc> ; 1 : 2 u`
    // (mod=1 explicitly, even though it's the default, because the
    // `:2` event sub-parameter requires the mods column).
    var buf: [16]u8 = undefined;
    const n = input.kittyKeyEvent(&buf, 97, false, false, false, 2);
    try std.testing.expectEqualStrings("\x1b[97;1:2u", buf[0..n]);
}

const c = @import("../c.zig").c;

test "kitty 0x08: plain 'a' goes through CSI u (report-all-keys)" {
    // Without 0x08, plain 'a' should emit raw byte 0x61.
    var buf: [16]u8 = undefined;
    const n_plain = input.encode(&buf, c.GDK_KEY_a, 0, false, 0, 0, false, false);
    try std.testing.expectEqualStrings("a", buf[0..n_plain]);

    // With 0x08, plain 'a' should emit CSI 97 u.
    const n_all = input.encode(&buf, c.GDK_KEY_a, 0, false, 0, 0x08, false, false);
    try std.testing.expectEqualStrings("\x1b[97u", buf[0..n_all]);
}

test "kitty 0x08: Shift+'a' → CSI 97 ; 2 u (uppercase folds to lowercase)" {
    var buf: [16]u8 = undefined;
    const n = input.encode(&buf, c.GDK_KEY_A, c.GDK_SHIFT_MASK, false, 0, 0x08, false, false);
    try std.testing.expectEqualStrings("\x1b[97;2u", buf[0..n]);
}

test "kitty 0x08: Tab still routes through CSI u (implies disambiguate)" {
    // 0x08 set, 0x01 NOT set — kitty spec says 0x08 implies 0x01.
    // Tab should emit `CSI 9 u` rather than the raw byte 0x09.
    var buf: [16]u8 = undefined;
    const n = input.encode(&buf, c.GDK_KEY_Tab, 0, false, 0, 0x08, false, false);
    try std.testing.expectEqualStrings("\x1b[9u", buf[0..n]);
}

test "kitty 0x08: F1 → CSI 57364 u (kitty PUA codepoint)" {
    var buf: [32]u8 = undefined;
    const n = input.encode(&buf, c.GDK_KEY_F1, 0, false, 0, 0x08, false, false);
    try std.testing.expectEqualStrings("\x1b[57364u", buf[0..n]);
}

test "kitty 0x08: Up → CSI 57352 u" {
    var buf: [32]u8 = undefined;
    const n = input.encode(&buf, c.GDK_KEY_Up, 0, false, 0, 0x08, false, false);
    try std.testing.expectEqualStrings("\x1b[57352u", buf[0..n]);
}

test "kitty 0x01 alone: F1 keeps legacy SS3 P (no PUA switch)" {
    // With disambiguate only, F-keys must NOT switch to PUA codepoints.
    var buf: [32]u8 = undefined;
    const n = input.encode(&buf, c.GDK_KEY_F1, 0, false, 0, 0x01, false, false);
    try std.testing.expectEqualStrings("\x1bOP", buf[0..n]);
}

test "kitty 0x08: Ctrl+F4 → CSI 57367 ; 5 u" {
    var buf: [32]u8 = undefined;
    const n = input.encode(&buf, c.GDK_KEY_F4, c.GDK_CONTROL_MASK, false, 0, 0x08, false, false);
    try std.testing.expectEqualStrings("\x1b[57367;5u", buf[0..n]);
}

test "kitty 0x04+0x08: plain 'a' adds alt-shifted 'A' sub-param" {
    // 0x04 (alt-keys) + 0x08 (report-all) — plain 'a' should be
    // CSI 97:65 u  (alt-shifted = uppercase variant).
    var buf: [32]u8 = undefined;
    const n = input.encode(&buf, c.GDK_KEY_a, 0, false, 0, 0x04 | 0x08, false, false);
    try std.testing.expectEqualStrings("\x1b[97:65u", buf[0..n]);
}

test "kitty 0x04: Ctrl+'a' → CSI 97:65 ; 5 u" {
    var buf: [32]u8 = undefined;
    const n = input.encode(&buf, c.GDK_KEY_a, c.GDK_CONTROL_MASK, false, 0, 0x04 | 0x01, false, false);
    try std.testing.expectEqualStrings("\x1b[97:65;5u", buf[0..n]);
}

test "kitty 0x04: digit '1' has no alt-shifted (layout-dependent)" {
    // Conservative: skip alt-shifted for digits + punctuation since
    // US-layout assumption ('1' → '!') would mislead non-US users.
    var buf: [32]u8 = undefined;
    const n = input.encode(&buf, c.GDK_KEY_1, c.GDK_CONTROL_MASK, false, 0, 0x04 | 0x01, false, false);
    try std.testing.expectEqualStrings("\x1b[49;5u", buf[0..n]);
}

test "kittyKeyEventFull alt_shifted == code_point omits sub-param" {
    var buf: [16]u8 = undefined;
    const n = input.kittyKeyEventFull(&buf, 97, 97, false, false, true, 1);
    try std.testing.expectEqualStrings("\x1b[97;5u", buf[0..n]);
}

test "kitty 0x10+0x08: plain 'a' → CSI 97;;97 u (assoc text)" {
    // Plain 'a' with associated text: code=97, no alts, mods empty
    // (default 1), text=97. Per kitty spec the empty mods section
    // is signalled by `;;` with the text after.
    var buf: [32]u8 = undefined;
    const n = input.encode(&buf, c.GDK_KEY_a, 0, false, 0, 0x10 | 0x08, false, false);
    try std.testing.expectEqualStrings("\x1b[97;;97u", buf[0..n]);
}

test "kitty 0x10+0x08: Shift+'a' → CSI 97;2;65 u (uppercase text)" {
    var buf: [32]u8 = undefined;
    const n = input.encode(&buf, c.GDK_KEY_A, c.GDK_SHIFT_MASK, false, 0, 0x10 | 0x08, false, false);
    try std.testing.expectEqualStrings("\x1b[97;2;65u", buf[0..n]);
}

test "kitty 0x10: Ctrl+'a' produces no text (control byte, no plain output)" {
    // Ctrl+'a' has no plain-mode text, so the associated-text section
    // must be omitted entirely — falls back to CSI 97;5 u.
    var buf: [32]u8 = undefined;
    const n = input.encode(&buf, c.GDK_KEY_a, c.GDK_CONTROL_MASK, false, 0, 0x10 | 0x01, false, false);
    try std.testing.expectEqualStrings("\x1b[97;5u", buf[0..n]);
}

test "kittyKeyEventComplete with text + alt_shifted + mods" {
    var buf: [32]u8 = undefined;
    const n = input.kittyKeyEventComplete(&buf, 97, 65, 65, true, false, false, 1);
    // code:alt = 97:65, mods = 2 (shift), text = 65 (uppercase)
    try std.testing.expectEqualStrings("\x1b[97:65;2;65u", buf[0..n]);
}

// ── matchBinding dispatch table coverage ──────────────────────────

test "matchBinding: Ctrl+Shift+T → new_tab" {
    const bindings = input.default_bindings[0..];
    const ctrl_shift = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK;
    const got = input.matchBinding(bindings, c.GDK_KEY_t, ctrl_shift);
    try std.testing.expectEqual(@as(?input.Action, .new_tab), got);
}

test "matchBinding: Ctrl+Tab → next_tab (lone Ctrl, not Ctrl+Shift)" {
    const bindings = input.default_bindings[0..];
    const got = input.matchBinding(bindings, c.GDK_KEY_Tab, c.GDK_CONTROL_MASK);
    try std.testing.expectEqual(@as(?input.Action, .next_tab), got);
}

test "matchBinding: ignores Lock + Group bits via SIGNIFICANT_MODS filter" {
    // Caps Lock (GDK_LOCK_MASK = 0x02) is NOT in the significant set;
    // a binding for Ctrl+Shift+T should still match when Lock is on.
    const bindings = input.default_bindings[0..];
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
