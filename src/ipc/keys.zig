//! Key-chord → PTY byte encoder for the `send-keys` IPC command.
//! Pure data, no GTK — unit-tests headless. Encodes xterm-style
//! sequences; kitty-keyboard-protocol apps still see the legacy
//! encoding (fine for driving CLIs/TUIs remotely).
//!
//! Chord grammar: `[mod+]*key`, mods `ctrl`/`alt`/`shift` (aliases
//! `control`, `meta`, `c`, `a`, `m`, `s`). Keys: named specials
//! (enter, tab, escape, up, f1..f12, …) or a single literal
//! character. A chord string holds whitespace-separated chords:
//! "ctrl+c up up enter".

const std = @import("std");

pub const Error = error{ UnknownKey, OutOfMemory };

const Mods = struct {
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,

    /// xterm modifier parameter: 1 + shift(1) + alt(2) + ctrl(4).
    fn param(self: Mods) u8 {
        var p: u8 = 1;
        if (self.shift) p += 1;
        if (self.alt) p += 2;
        if (self.ctrl) p += 4;
        return p;
    }

    fn any(self: Mods) bool {
        return self.ctrl or self.alt or self.shift;
    }
};

/// CSI-encoded special key: `esc [ <num> ~` style (`tilde` set) or
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

fn specialFor(name: []const u8) ?Special {
    const eql = std.ascii.eqlIgnoreCase;
    if (eql(name, "up")) return .{ .letter = 'A', .ss3_in_app = true };
    if (eql(name, "down")) return .{ .letter = 'B', .ss3_in_app = true };
    if (eql(name, "right")) return .{ .letter = 'C', .ss3_in_app = true };
    if (eql(name, "left")) return .{ .letter = 'D', .ss3_in_app = true };
    if (eql(name, "home")) return .{ .letter = 'H', .ss3_in_app = true };
    if (eql(name, "end")) return .{ .letter = 'F', .ss3_in_app = true };
    if (eql(name, "insert")) return .{ .num = 2 };
    if (eql(name, "delete") or eql(name, "del")) return .{ .num = 3 };
    if (eql(name, "pageup") or eql(name, "pgup")) return .{ .num = 5 };
    if (eql(name, "pagedown") or eql(name, "pgdn")) return .{ .num = 6 };
    if (eql(name, "f1")) return .{ .letter = 'P', .always_ss3 = true };
    if (eql(name, "f2")) return .{ .letter = 'Q', .always_ss3 = true };
    if (eql(name, "f3")) return .{ .letter = 'R', .always_ss3 = true };
    if (eql(name, "f4")) return .{ .letter = 'S', .always_ss3 = true };
    if (eql(name, "f5")) return .{ .num = 15 };
    if (eql(name, "f6")) return .{ .num = 17 };
    if (eql(name, "f7")) return .{ .num = 18 };
    if (eql(name, "f8")) return .{ .num = 19 };
    if (eql(name, "f9")) return .{ .num = 20 };
    if (eql(name, "f10")) return .{ .num = 21 };
    if (eql(name, "f11")) return .{ .num = 23 };
    if (eql(name, "f12")) return .{ .num = 24 };
    return null;
}

fn isMod(seg: []const u8, out: *Mods) bool {
    const eql = std.ascii.eqlIgnoreCase;
    if (eql(seg, "ctrl") or eql(seg, "control") or eql(seg, "c")) {
        out.ctrl = true;
        return true;
    }
    if (eql(seg, "alt") or eql(seg, "meta") or eql(seg, "m") or eql(seg, "a")) {
        out.alt = true;
        return true;
    }
    if (eql(seg, "shift") or eql(seg, "s")) {
        out.shift = true;
        return true;
    }
    return false;
}

/// Encode one chord ("ctrl+c", "enter", "shift+tab") into `out`.
pub fn encodeChord(out: *std.ArrayList(u8), allocator: std.mem.Allocator, chord: []const u8, app_cursor: bool) Error!void {
    var mods: Mods = .{};
    var key: []const u8 = chord;

    // Peel `mod+` prefixes. A trailing '+' after a mod means the key
    // IS '+' ("ctrl++"); a bare "+" chord is the literal plus key.
    while (std.mem.indexOfScalar(u8, key, '+')) |plus| {
        if (plus == 0 or plus == key.len - 1) break; // literal-plus forms
        if (!isMod(key[0..plus], &mods)) break; // "some+thing" that isn't a mod
        key = key[plus + 1 ..];
    }
    if (key.len == 0) return Error.UnknownKey;

    const eql = std.ascii.eqlIgnoreCase;

    // Simple named keys (modifier-insensitive forms first).
    if (eql(key, "enter") or eql(key, "return") or eql(key, "cr")) {
        if (mods.alt) try out.append(allocator, 0x1b);
        try out.append(allocator, '\r');
        return;
    }
    if (eql(key, "escape") or eql(key, "esc")) {
        if (mods.alt) try out.append(allocator, 0x1b);
        try out.append(allocator, 0x1b);
        return;
    }
    if (eql(key, "tab")) {
        if (mods.shift) {
            try out.appendSlice(allocator, "\x1b[Z");
        } else {
            if (mods.alt) try out.append(allocator, 0x1b);
            try out.append(allocator, '\t');
        }
        return;
    }
    if (eql(key, "space")) {
        if (mods.ctrl) {
            // Ctrl+Space = NUL.
            if (mods.alt) try out.append(allocator, 0x1b);
            try out.append(allocator, 0x00);
        } else {
            if (mods.alt) try out.append(allocator, 0x1b);
            try out.append(allocator, ' ');
        }
        return;
    }
    if (eql(key, "backspace") or eql(key, "bs")) {
        if (mods.alt) try out.append(allocator, 0x1b);
        try out.append(allocator, 0x7f);
        return;
    }

    if (specialFor(key)) |sp| {
        var buf: [16]u8 = undefined;
        const s = blk: {
            if (sp.num != 0) {
                // Tilde form: esc [ <num> [;mod] ~
                if (mods.any())
                    break :blk std.fmt.bufPrint(&buf, "\x1b[{d};{d}~", .{ sp.num, mods.param() }) catch unreachable;
                break :blk std.fmt.bufPrint(&buf, "\x1b[{d}~", .{sp.num}) catch unreachable;
            }
            // Modified letter form is always CSI 1;m<letter>.
            if (mods.any())
                break :blk std.fmt.bufPrint(&buf, "\x1b[1;{d}{c}", .{ mods.param(), sp.letter }) catch unreachable;
            if (sp.always_ss3 or (sp.ss3_in_app and app_cursor))
                break :blk std.fmt.bufPrint(&buf, "\x1bO{c}", .{sp.letter}) catch unreachable;
            break :blk std.fmt.bufPrint(&buf, "\x1b[{c}", .{sp.letter}) catch unreachable;
        };
        try out.appendSlice(allocator, s);
        return;
    }

    // Literal single character (possibly multi-byte UTF-8).
    const seq_len = std.unicode.utf8ByteSequenceLength(key[0]) catch return Error.UnknownKey;
    if (seq_len != key.len) return Error.UnknownKey;
    if (mods.ctrl) {
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
        if (mods.alt) try out.append(allocator, 0x1b);
        try out.append(allocator, byte);
        return;
    }
    if (mods.alt) try out.append(allocator, 0x1b);
    try out.appendSlice(allocator, key);
}

/// Encode a whitespace-separated chord list ("ctrl+c up enter").
pub fn encode(out: *std.ArrayList(u8), allocator: std.mem.Allocator, chords: []const u8, app_cursor: bool) Error!void {
    var it = std.mem.tokenizeAny(u8, chords, " \t\n");
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
    try expectEnc("ctrl+c up up enter", false, "\x03\x1b[A\x1b[A\r");
}

test "unknown keys rejected" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try std.testing.expectError(Error.UnknownKey, encode(&out, a, "bogus_key", false));
    try std.testing.expectError(Error.UnknownKey, encode(&out, a, "ctrl+ä", false));
}
