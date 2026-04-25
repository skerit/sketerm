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
