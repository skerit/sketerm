//! Key-chord → PTY byte encoder for the `send-keys` IPC command.
//! Pure data, no GTK — unit-tests headless. Encodes xterm-style
//! sequences; kitty-keyboard-protocol apps still see the legacy
//! encoding (fine for driving CLIs/TUIs remotely).
//!
//! Names and grammar are util/keychord.zig's. Super (`meta`, `cmd`)
//! rides only the CSI forms (modifier bit 8, as xterm and kitty
//! number it); a chord the legacy encoding has no bytes for is
//! refused with UnsupportedModifier rather than sent without it.

const std = @import("std");
const keychord = @import("../util/keychord.zig");

pub const Error = keychord.Error || error{ UnsupportedModifier, OutOfMemory };

/// xterm modifier parameter: 1 + shift(1) + alt(2) + ctrl(4) + super(8).
fn modParam(mods: keychord.Mods) u8 {
    var p: u8 = 1;
    var it = mods.iterator();
    while (it.next()) |m| p += switch (m) {
        .shift => 1,
        .alt => 2,
        .ctrl => 4,
        .super => 8,
    };
    return p;
}

/// CSI-encoded special key: `esc [ <num> ~` style (`num` set) or
/// `esc [ 1 ; m <letter>` / `esc O <letter>` style.
const Special = struct {
    /// Final letter for letter-form keys ('A' for up), 0 for tilde-form.
    letter: u8 = 0,
    /// Number for tilde-form keys (3 for delete), 0 for letter-form.
    num: u8 = 0,
    /// Letter-form keys that emit SS3 (`esc O X`) in app-cursor mode.
    ss3_in_app: bool = false,
    /// F1-F4 emit SS3 unmodified regardless of cursor mode.
    always_ss3: bool = false,
};

/// One byte, Alt as an ESC prefix; Shift and Ctrl have no legacy form here and are dropped.
fn plain(out: *std.ArrayList(u8), allocator: std.mem.Allocator, mods: keychord.Mods, byte: u8) Error!void {
    if (mods.contains(.super)) return Error.UnsupportedModifier;
    if (mods.contains(.alt)) try out.append(allocator, 0x1b);
    try out.append(allocator, byte);
}

fn special(out: *std.ArrayList(u8), allocator: std.mem.Allocator, mods: keychord.Mods, sp: Special, app_cursor: bool) Error!void {
    var buf: [16]u8 = undefined;
    const any = mods.count() != 0;
    const s = blk: {
        if (sp.num != 0) {
            // Tilde form: esc [ <num> [;mod] ~
            if (any) break :blk std.fmt.bufPrint(&buf, "\x1b[{d};{d}~", .{ sp.num, modParam(mods) }) catch unreachable;
            break :blk std.fmt.bufPrint(&buf, "\x1b[{d}~", .{sp.num}) catch unreachable;
        }
        // Modified letter form is always CSI 1;m<letter>.
        if (any) break :blk std.fmt.bufPrint(&buf, "\x1b[1;{d}{c}", .{ modParam(mods), sp.letter }) catch unreachable;
        if (sp.always_ss3 or (sp.ss3_in_app and app_cursor))
            break :blk std.fmt.bufPrint(&buf, "\x1bO{c}", .{sp.letter}) catch unreachable;
        break :blk std.fmt.bufPrint(&buf, "\x1b[{c}", .{sp.letter}) catch unreachable;
    };
    try out.appendSlice(allocator, s);
}

/// A literal character (possibly multi-byte UTF-8); Ctrl maps the C0 set.
fn literal(out: *std.ArrayList(u8), allocator: std.mem.Allocator, mods: keychord.Mods, key: []const u8) Error!void {
    if (mods.contains(.super)) return Error.UnsupportedModifier;
    if (mods.contains(.ctrl)) {
        if (key.len != 1) return Error.UnknownKey;
        const ch = std.ascii.toLower(key[0]);
        const byte: u8 = switch (ch) {
            'a'...'z' => @intCast(ch - 'a' + 1),
            '@' => 0x00,
            '[' => 0x1b,
            '\\' => 0x1c,
            ']' => 0x1d,
            '^' => 0x1e,
            '_', '/' => 0x1f,
            '?' => 0x7f,
            else => return Error.UnknownKey,
        };
        return plain(out, allocator, mods, byte);
    }
    if (mods.contains(.alt)) try out.append(allocator, 0x1b);
    try out.appendSlice(allocator, key);
}

/// Encode one chord ("ctrl+c", "enter", "shift+tab") into `out`.
pub fn encodeChord(out: *std.ArrayList(u8), allocator: std.mem.Allocator, chord: []const u8, app_cursor: bool) Error!void {
    const parsed = try keychord.parse(chord);
    const mods = parsed.mods;
    const name = switch (parsed.key) {
        .char => |text| return literal(out, allocator, mods, text),
        .named => |n| n,
    };
    const sp: Special = switch (name) {
        .enter => return plain(out, allocator, mods, '\r'),
        .escape => return plain(out, allocator, mods, 0x1b),
        .backspace => return plain(out, allocator, mods, 0x7f),
        .space => return plain(out, allocator, mods, if (mods.contains(.ctrl)) 0x00 else ' '),
        .tab => {
            if (!mods.contains(.shift)) return plain(out, allocator, mods, '\t');
            if (mods.contains(.super)) return Error.UnsupportedModifier;
            return out.appendSlice(allocator, "\x1b[Z");
        },
        .up => .{ .letter = 'A', .ss3_in_app = true },
        .down => .{ .letter = 'B', .ss3_in_app = true },
        .right => .{ .letter = 'C', .ss3_in_app = true },
        .left => .{ .letter = 'D', .ss3_in_app = true },
        .home => .{ .letter = 'H', .ss3_in_app = true },
        .end => .{ .letter = 'F', .ss3_in_app = true },
        .insert => .{ .num = 2 },
        .delete => .{ .num = 3 },
        .page_up => .{ .num = 5 },
        .page_down => .{ .num = 6 },
        .f1 => .{ .letter = 'P', .always_ss3 = true },
        .f2 => .{ .letter = 'Q', .always_ss3 = true },
        .f3 => .{ .letter = 'R', .always_ss3 = true },
        .f4 => .{ .letter = 'S', .always_ss3 = true },
        .f5 => .{ .num = 15 },
        .f6 => .{ .num = 17 },
        .f7 => .{ .num = 18 },
        .f8 => .{ .num = 19 },
        .f9 => .{ .num = 20 },
        .f10 => .{ .num = 21 },
        .f11 => .{ .num = 23 },
        .f12 => .{ .num = 24 },
        // No byte encoding: a held modifier, Caps Lock and Menu are not PTY input.
        .menu, .caps_lock, .shift, .ctrl, .alt, .super => return Error.UnknownKey,
    };
    return special(out, allocator, mods, sp, app_cursor);
}

/// Encode a whitespace-separated chord list ("ctrl+c up enter").
pub fn encode(out: *std.ArrayList(u8), allocator: std.mem.Allocator, chords: []const u8, app_cursor: bool) Error!void {
    var it = keychord.chords(chords);
    while (it.next()) |chord| try encodeChord(out, allocator, chord, app_cursor);
}

fn expectEnc(chords: []const u8, app_cursor: bool, want: []const u8) !void {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try encode(&out, a, chords, app_cursor);
    try std.testing.expectEqualSlices(u8, want, out.items);
}

test "named keys" {
    try expectEnc("enter", false, "\r");
    try expectEnc("escape", false, "\x1b");
    try expectEnc("tab", false, "\t");
    try expectEnc("shift+tab", false, "\x1b[Z");
    try expectEnc("backspace", false, "\x7f");
    try expectEnc("delete", false, "\x1b[3~");
    try expectEnc("pageup pagedown", false, "\x1b[5~\x1b[6~");
    try expectEnc("pgup pgdn page_up page_down", false, "\x1b[5~\x1b[6~\x1b[5~\x1b[6~");
    try expectEnc("f1", false, "\x1bOP");
    try expectEnc("f5", false, "\x1b[15~");
    try expectEnc("f12", false, "\x1b[24~");
}

test "arrows honor app cursor mode" {
    try expectEnc("up", false, "\x1b[A");
    try expectEnc("up", true, "\x1bOA");
    try expectEnc("home end", false, "\x1b[H\x1b[F");
    try expectEnc("left", true, "\x1bOD");
}

test "control combos" {
    try expectEnc("ctrl+c", false, "\x03");
    try expectEnc("ctrl+z", false, "\x1a");
    try expectEnc("ctrl+space", false, "\x00");
    try expectEnc("ctrl+[", false, "\x1b");
    try expectEnc("ctrl+_", false, "\x1f");
    try expectEnc("ctrl+shift+right", false, "\x1b[1;6C");
    try expectEnc("ctrl+delete", false, "\x1b[3;5~");
}

test "alt prefixes and literals" {
    try expectEnc("alt+x", false, "\x1bx");
    try expectEnc("alt+enter", false, "\x1b\r");
    try expectEnc("a", false, "a");
    try expectEnc("+", false, "+");
    try expectEnc("é", false, "é");
    try expectEnc("alt++", false, "\x1b+");
    try expectEnc("ctrl+c up up enter", false, "\x03\x1b[A\x1b[A\r");
}

test "meta is Super: CSI forms carry modifier bit 8, legacy bytes refuse it" {
    try expectEnc("meta+up", false, "\x1b[1;9A");
    try expectEnc("super+shift+delete", false, "\x1b[3;10~");
    try expectEnc("cmd+f1", false, "\x1b[1;9P");
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try std.testing.expectError(Error.UnsupportedModifier, encode(&out, a, "meta+x", false));
    try std.testing.expectError(Error.UnsupportedModifier, encode(&out, a, "meta+enter", false));
    try std.testing.expectError(Error.UnsupportedModifier, encode(&out, a, "meta+shift+tab", false));
}

test "unknown keys rejected" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try std.testing.expectError(Error.UnknownKey, encode(&out, a, "bogus_key", false));
    try std.testing.expectError(Error.UnknownKey, encode(&out, a, "ctrl+ä", false));
    try std.testing.expectError(Error.UnknownKey, encode(&out, a, "shift", false));
    try std.testing.expectError(Error.UnknownModifier, encode(&out, a, "c+x", false));
    // A literal plus has no C0 control byte.
    try std.testing.expectError(Error.UnknownKey, encode(&out, a, "ctrl++", false));
}
