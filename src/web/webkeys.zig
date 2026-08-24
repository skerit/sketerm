//! Key-name chords -> `input_key` wire values, for clients that inject
//! keys by NAME (the MCP `web_key` tool) rather than from a real GTK
//! event. std + protocol only, usable from every target.
//!
//! A chord is `[mod+]*key`: mods are ctrl/control, shift, alt, meta,
//! super/cmd; the key is a named non-printable (the names `keymap.zig`
//! maps on the helper side) or a single character. The wire carries the
//! XKB keysym exactly as the GUI would: Latin-1 characters are their
//! own keysym, anything else is `0x01000000 | codepoint`.

const std = @import("std");
const proto = @import("protocol.zig");

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

const Named = struct { name: []const u8, keysym: u32 };

/// The names accepted case-insensitively. Aliases sit beside their
/// canonical entry; every keysym here is in the helper's keymap table.
const NAMED = [_]Named{
    .{ .name = "enter", .keysym = 0xff0d },
    .{ .name = "return", .keysym = 0xff0d },
    .{ .name = "tab", .keysym = 0xff09 },
    .{ .name = "escape", .keysym = 0xff1b },
    .{ .name = "esc", .keysym = 0xff1b },
    .{ .name = "backspace", .keysym = 0xff08 },
    .{ .name = "delete", .keysym = 0xffff },
    .{ .name = "del", .keysym = 0xffff },
    .{ .name = "insert", .keysym = 0xff63 },
    .{ .name = "home", .keysym = 0xff50 },
    .{ .name = "end", .keysym = 0xff57 },
    .{ .name = "pageup", .keysym = 0xff55 },
    .{ .name = "page_up", .keysym = 0xff55 },
    .{ .name = "pagedown", .keysym = 0xff56 },
    .{ .name = "page_down", .keysym = 0xff56 },
    .{ .name = "up", .keysym = 0xff52 },
    .{ .name = "down", .keysym = 0xff54 },
    .{ .name = "left", .keysym = 0xff51 },
    .{ .name = "right", .keysym = 0xff53 },
    .{ .name = "arrowup", .keysym = 0xff52 },
    .{ .name = "arrowdown", .keysym = 0xff54 },
    .{ .name = "arrowleft", .keysym = 0xff51 },
    .{ .name = "arrowright", .keysym = 0xff53 },
    .{ .name = "space", .keysym = ' ' },
};

pub const Error = error{ UnknownKey, UnknownModifier, EmptyChord };

/// One `mod+key` chord. A single character stands for itself; a
/// bare-shift chord over a printable produces that character's text
/// (the caller writes the character they mean, "?" not "shift+/").
pub fn parseChord(spec: []const u8) Error!Chord {
    var mods: u32 = 0;
    var rest = spec;
    while (std.mem.indexOfScalar(u8, rest, '+')) |plus| {
        // A trailing '+' means the KEY is '+' ("ctrl++" or a bare "+").
        if (plus + 1 == rest.len) break;
        const m = rest[0..plus];
        if (std.ascii.eqlIgnoreCase(m, "ctrl") or std.ascii.eqlIgnoreCase(m, "control"))
            mods |= proto.mod_ctrl
        else if (std.ascii.eqlIgnoreCase(m, "shift"))
            mods |= proto.mod_shift
        else if (std.ascii.eqlIgnoreCase(m, "alt"))
            mods |= proto.mod_alt
        else if (std.ascii.eqlIgnoreCase(m, "meta") or std.ascii.eqlIgnoreCase(m, "super") or std.ascii.eqlIgnoreCase(m, "cmd"))
            mods |= proto.mod_super
        else
            return error.UnknownModifier;
        rest = rest[plus + 1 ..];
    }
    if (rest.len == 0) return error.EmptyChord;

    for (&NAMED) |n| {
        if (std.ascii.eqlIgnoreCase(rest, n.name)) return .{ .keysym = n.keysym, .mods = mods };
    }
    // F1..F12.
    if ((rest[0] == 'f' or rest[0] == 'F') and rest.len >= 2 and rest.len <= 3) {
        if (std.fmt.parseInt(u8, rest[1..], 10)) |num| {
            if (num >= 1 and num <= 12) return .{ .keysym = 0xffbe + @as(u32, num) - 1, .mods = mods };
        } else |_| {}
    }
    // A single character (one codepoint).
    const view = std.unicode.Utf8View.init(rest) catch return error.UnknownKey;
    var it = view.iterator();
    const cp = it.nextCodepoint() orelse return error.UnknownKey;
    if (it.nextCodepoint() != null) return error.UnknownKey;
    var chord = Chord{
        .keysym = if (cp < 0x100) @as(u32, cp) else 0x01000000 | @as(u32, cp),
        .mods = mods,
    };
    // Text rides only when the chord actually types: ctrl/alt chords
    // and control characters carry none (the helper maps the keysym).
    if (mods & (proto.mod_ctrl | proto.mod_alt) == 0 and cp >= 0x20 and cp != 0x7f) {
        chord.text_len = @intCast(std.unicode.utf8Encode(@intCast(cp), &chord.text) catch 0);
    }
    return chord;
}

/// Whitespace-separated chords, filled into `out`; returns how many.
pub fn parseKeys(spec: []const u8, out: []Chord) Error!usize {
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, spec, " \t\n");
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
}
