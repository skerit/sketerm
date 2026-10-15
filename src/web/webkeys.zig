//! Key-name chords -> `input_key` wire values, for clients that inject
//! keys by NAME (the MCP `web_key` tool) rather than from a real GTK
//! event. std + protocol only, usable from every target.
//!
//! Names and grammar are util/keychord.zig's (`meta` is Super). The
//! wire carries the XKB keysym exactly as the GUI would: Latin-1
//! characters are their own keysym, anything else is
//! `0x01000000 | codepoint`.

const std = @import("std");
const proto = @import("protocol.zig");
const keychord = @import("../util/keychord.zig");

pub const Chord = struct {
    keysym: u32,
    mods: u32,
    /// UTF-8 text for the down event; empty for non-printables and for
    /// ctrl/alt chords, matching what the GUI puts on the wire
    /// (webframe.zig: the helper maps the keysym itself there).
    text: [4]u8 = @splat(0),
    text_len: u8 = 0,

    pub fn textSlice(self: *const Chord) []const u8 {
        return self.text[0..self.text_len];
    }
};

pub const Error = keychord.Error;

fn bitFor(m: keychord.Mod) u32 {
    return switch (m) {
        .ctrl => proto.mod_ctrl,
        .shift => proto.mod_shift,
        .alt => proto.mod_alt,
        .super => proto.mod_super,
    };
}

/// The `proto.mod_*` bit a modifier name stands for, any case.
pub fn modBit(name: []const u8) ?u32 {
    return bitFor(keychord.modFor(name) orelse return null);
}

/// The keysym of a named key; every one is in the helper's keymap table (web/keymap.zig), which has no Menu.
fn namedKeysym(n: keychord.Named) ?u32 {
    return switch (n) {
        .enter => 0xff0d,
        .tab => 0xff09,
        .escape => 0xff1b,
        .backspace => 0xff08,
        .delete => 0xffff,
        .insert => 0xff63,
        .home => 0xff50,
        .end => 0xff57,
        .page_up => 0xff55,
        .page_down => 0xff56,
        .up => 0xff52,
        .down => 0xff54,
        .left => 0xff51,
        .right => 0xff53,
        .space => ' ',
        .shift => 0xffe1,
        .ctrl => 0xffe3,
        .alt => 0xffe9,
        .super => 0xffeb,
        .caps_lock => 0xffe5,
        .menu => null,
        .f1 => 0xffbe,
        .f2 => 0xffbf,
        .f3 => 0xffc0,
        .f4 => 0xffc1,
        .f5 => 0xffc2,
        .f6 => 0xffc3,
        .f7 => 0xffc4,
        .f8 => 0xffc5,
        .f9 => 0xffc6,
        .f10 => 0xffc7,
        .f11 => 0xffc8,
        .f12 => 0xffc9,
    };
}

/// One `mod+key` chord. A single character stands for itself; a
/// bare-shift chord over a printable produces that character's text
/// (the caller writes the character they mean, "?" not "shift+/").
pub fn parseChord(spec: []const u8) Error!Chord {
    const parsed = try keychord.parse(spec);
    var mods: u32 = 0;
    var it = parsed.mods.iterator();
    while (it.next()) |m| mods |= bitFor(m);
    const text = switch (parsed.key) {
        .named => |n| return .{ .keysym = namedKeysym(n) orelse return error.UnknownKey, .mods = mods },
        .char => |s| s,
    };
    const cp = std.unicode.utf8Decode(text) catch return error.UnknownKey;
    var chord = Chord{
        .keysym = if (cp < 0x100) @as(u32, cp) else 0x01000000 | @as(u32, cp),
        .mods = mods,
    };
    // Text rides only when the chord actually types: ctrl/alt chords
    // and control characters carry none (the helper maps the keysym).
    if (mods & (proto.mod_ctrl | proto.mod_alt) == 0 and cp >= 0x20 and cp != 0x7f) {
        chord.text_len = @intCast(std.unicode.utf8Encode(cp, &chord.text) catch 0);
    }
    return chord;
}

/// Whitespace-separated chords, filled into `out`; returns how many.
pub fn parseKeys(spec: []const u8, out: []Chord) Error!usize {
    var n: usize = 0;
    var it = keychord.chords(spec);
    while (it.next()) |tok| {
        if (n == out.len) break;
        out[n] = try parseChord(tok);
        n += 1;
    }
    if (n == 0) return error.EmptyChord;
    return n;
}

test "webkeys parses named keys, chords and characters" {
    const t = std.testing;
    try t.expectEqual(@as(u32, 0xff09), (try parseChord("Tab")).keysym);
    try t.expectEqual(@as(u32, 0xff0d), (try parseChord("enter")).keysym);
    try t.expectEqual(@as(u32, 0xffc2), (try parseChord("F5")).keysym);

    const ctrl_a = try parseChord("ctrl+a");
    try t.expectEqual(@as(u32, 'a'), ctrl_a.keysym);
    try t.expectEqual(proto.mod_ctrl, ctrl_a.mods);
    try t.expectEqual(@as(usize, 0), ctrl_a.textSlice().len);

    const sh_tab = try parseChord("Shift+Tab");
    try t.expectEqual(@as(u32, 0xff09), sh_tab.keysym);
    try t.expectEqual(proto.mod_shift, sh_tab.mods);

    // A modifier named alone is that key, typing nothing; as a prefix it stays a modifier.
    const shift = try parseChord("Shift");
    try t.expectEqual(@as(u32, 0xffe1), shift.keysym);
    try t.expectEqual(@as(u32, 0), shift.mods);
    try t.expectEqual(@as(usize, 0), shift.textSlice().len);
    try t.expectEqual(@as(u32, 0xffe3), (try parseChord("Control")).keysym);
    try t.expectEqual(proto.mod_ctrl, (try parseChord("ctrl+Shift")).mods);

    const q = try parseChord("?");
    try t.expectEqualStrings("?", q.textSlice());
    const plus = try parseChord("ctrl++");
    try t.expectEqual(@as(u32, '+'), plus.keysym);
    try t.expectEqual(proto.mod_ctrl, plus.mods);
    const uni = try parseChord("\xc3\xaa"); // e-circumflex U+00EA
    try t.expectEqual(@as(u32, 0xea), uni.keysym);
    try t.expectEqualStrings("\xc3\xaa", uni.textSlice());

    try t.expectError(error.UnknownModifier, parseChord("hyper+a"));
    try t.expectError(error.UnknownKey, parseChord("NotAKey"));

    var chords: [8]Chord = undefined;
    try t.expectEqual(@as(usize, 3), try parseKeys("Tab Tab Enter", &chords));
    try t.expectError(error.EmptyChord, parseKeys("   ", &chords));

    // Both page-key spellings, meta as Super, and a literal plus alone.
    try t.expectEqual(@as(u32, 0xff55), (try parseChord("pgup")).keysym);
    try t.expectEqual(@as(u32, 0xff56), (try parseChord("PgDn")).keysym);
    try t.expectEqual(@as(u32, 0xff56), (try parseChord("page_down")).keysym);
    try t.expectEqual(proto.mod_super, (try parseChord("meta+a")).mods);
    try t.expectEqual(proto.mod_super, modBit("cmd").?);
    try t.expectEqual(proto.mod_alt, modBit("option").?);
    try t.expectEqualStrings("+", (try parseChord("+")).textSlice());
    try t.expectError(error.UnknownKey, parseChord("menu"));
}
