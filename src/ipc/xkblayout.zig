//! Compiled-xkb keymap parser: derives codepoint -> (evdev key,
//! shift/altgr) from the same blob the session's apps receive, so
//! MCP typing works on any embedded layout (wlhost/keymaps.zig).
//! Levels: 1 plain, 2 Shift, 3 AltGr (Mod5), 4 Shift+AltGr. Only the
//! first group is read; dead keys and non-character keysyms are
//! skipped (the clipboard-paste path covers what the map can't).

const std = @import("std");

pub const Entry = struct {
    /// evdev keycode (xkb keycode - 8).
    code: u32,
    shift: bool = false,
    altgr: bool = false,
};

pub const Layout = struct {
    map: std.AutoHashMapUnmanaged(u21, Entry) = .empty,

    pub fn deinit(self: *Layout, a: std.mem.Allocator) void {
        self.map.deinit(a);
    }

    pub fn lookup(self: *const Layout, cp: u21) ?Entry {
        return self.map.get(cp);
    }
};

fn levelCost(e: Entry) u8 {
    return (@as(u8, @intFromBool(e.shift))) + (@as(u8, @intFromBool(e.altgr)) * 2);
}

/// Keysym name -> codepoint for the printable range our keymaps use
/// (ASCII names, Latin-1, a few common extras). Single-character
/// names and U+hex forms are handled separately in symToCp.
const named_syms = [_]struct { n: []const u8, cp: u21 }{
    .{ .n = "space", .cp = ' ' },
    .{ .n = "exclam", .cp = '!' },
    .{ .n = "quotedbl", .cp = '"' },
    .{ .n = "numbersign", .cp = '#' },
    .{ .n = "dollar", .cp = '$' },
    .{ .n = "percent", .cp = '%' },
    .{ .n = "ampersand", .cp = '&' },
    .{ .n = "apostrophe", .cp = '\'' },
    .{ .n = "parenleft", .cp = '(' },
    .{ .n = "parenright", .cp = ')' },
    .{ .n = "asterisk", .cp = '*' },
    .{ .n = "plus", .cp = '+' },
    .{ .n = "comma", .cp = ',' },
    .{ .n = "minus", .cp = '-' },
    .{ .n = "period", .cp = '.' },
    .{ .n = "slash", .cp = '/' },
    .{ .n = "colon", .cp = ':' },
    .{ .n = "semicolon", .cp = ';' },
    .{ .n = "less", .cp = '<' },
    .{ .n = "equal", .cp = '=' },
    .{ .n = "greater", .cp = '>' },
    .{ .n = "question", .cp = '?' },
    .{ .n = "at", .cp = '@' },
    .{ .n = "bracketleft", .cp = '[' },
    .{ .n = "backslash", .cp = '\\' },
    .{ .n = "bracketright", .cp = ']' },
    .{ .n = "asciicircum", .cp = '^' },
    .{ .n = "underscore", .cp = '_' },
    .{ .n = "grave", .cp = '`' },
    .{ .n = "braceleft", .cp = '{' },
    .{ .n = "bar", .cp = '|' },
    .{ .n = "braceright", .cp = '}' },
    .{ .n = "asciitilde", .cp = '~' },
    .{ .n = "exclamdown", .cp = 0xA1 },
    .{ .n = "cent", .cp = 0xA2 },
    .{ .n = "sterling", .cp = 0xA3 },
    .{ .n = "currency", .cp = 0xA4 },
    .{ .n = "yen", .cp = 0xA5 },
    .{ .n = "brokenbar", .cp = 0xA6 },
    .{ .n = "section", .cp = 0xA7 },
    .{ .n = "diaeresis", .cp = 0xA8 },
    .{ .n = "copyright", .cp = 0xA9 },
    .{ .n = "ordfeminine", .cp = 0xAA },
    .{ .n = "guillemotleft", .cp = 0xAB },
    .{ .n = "notsign", .cp = 0xAC },
    .{ .n = "registered", .cp = 0xAE },
    .{ .n = "macron", .cp = 0xAF },
    .{ .n = "degree", .cp = 0xB0 },
    .{ .n = "plusminus", .cp = 0xB1 },
    .{ .n = "twosuperior", .cp = 0xB2 },
    .{ .n = "threesuperior", .cp = 0xB3 },
    .{ .n = "acute", .cp = 0xB4 },
    .{ .n = "mu", .cp = 0xB5 },
    .{ .n = "paragraph", .cp = 0xB6 },
    .{ .n = "periodcentered", .cp = 0xB7 },
    .{ .n = "cedilla", .cp = 0xB8 },
    .{ .n = "onesuperior", .cp = 0xB9 },
    .{ .n = "masculine", .cp = 0xBA },
    .{ .n = "guillemotright", .cp = 0xBB },
    .{ .n = "onequarter", .cp = 0xBC },
    .{ .n = "onehalf", .cp = 0xBD },
    .{ .n = "threequarters", .cp = 0xBE },
    .{ .n = "questiondown", .cp = 0xBF },
    .{ .n = "Agrave", .cp = 0xC0 },
    .{ .n = "Aacute", .cp = 0xC1 },
    .{ .n = "Acircumflex", .cp = 0xC2 },
    .{ .n = "Atilde", .cp = 0xC3 },
    .{ .n = "Adiaeresis", .cp = 0xC4 },
    .{ .n = "Aring", .cp = 0xC5 },
    .{ .n = "AE", .cp = 0xC6 },
    .{ .n = "Ccedilla", .cp = 0xC7 },
    .{ .n = "Egrave", .cp = 0xC8 },
    .{ .n = "Eacute", .cp = 0xC9 },
    .{ .n = "Ecircumflex", .cp = 0xCA },
    .{ .n = "Ediaeresis", .cp = 0xCB },
    .{ .n = "Ntilde", .cp = 0xD1 },
    .{ .n = "Ograve", .cp = 0xD2 },
    .{ .n = "Oacute", .cp = 0xD3 },
    .{ .n = "Ocircumflex", .cp = 0xD4 },
    .{ .n = "Otilde", .cp = 0xD5 },
    .{ .n = "Odiaeresis", .cp = 0xD6 },
    .{ .n = "Ooblique", .cp = 0xD8 },
    .{ .n = "Ugrave", .cp = 0xD9 },
    .{ .n = "Uacute", .cp = 0xDA },
    .{ .n = "Ucircumflex", .cp = 0xDB },
    .{ .n = "Udiaeresis", .cp = 0xDC },
    .{ .n = "ssharp", .cp = 0xDF },
    .{ .n = "agrave", .cp = 0xE0 },
    .{ .n = "aacute", .cp = 0xE1 },
    .{ .n = "acircumflex", .cp = 0xE2 },
    .{ .n = "atilde", .cp = 0xE3 },
    .{ .n = "adiaeresis", .cp = 0xE4 },
    .{ .n = "aring", .cp = 0xE5 },
    .{ .n = "ae", .cp = 0xE6 },
    .{ .n = "ccedilla", .cp = 0xE7 },
    .{ .n = "egrave", .cp = 0xE8 },
    .{ .n = "eacute", .cp = 0xE9 },
    .{ .n = "ecircumflex", .cp = 0xEA },
    .{ .n = "ediaeresis", .cp = 0xEB },
    .{ .n = "igrave", .cp = 0xEC },
    .{ .n = "iacute", .cp = 0xED },
    .{ .n = "icircumflex", .cp = 0xEE },
    .{ .n = "idiaeresis", .cp = 0xEF },
    .{ .n = "ntilde", .cp = 0xF1 },
    .{ .n = "ograve", .cp = 0xF2 },
    .{ .n = "oacute", .cp = 0xF3 },
    .{ .n = "ocircumflex", .cp = 0xF4 },
    .{ .n = "otilde", .cp = 0xF5 },
    .{ .n = "odiaeresis", .cp = 0xF6 },
    .{ .n = "division", .cp = 0xF7 },
    .{ .n = "oslash", .cp = 0xF8 },
    .{ .n = "ugrave", .cp = 0xF9 },
    .{ .n = "uacute", .cp = 0xFA },
    .{ .n = "ucircumflex", .cp = 0xFB },
    .{ .n = "udiaeresis", .cp = 0xFC },
    .{ .n = "yacute", .cp = 0xFD },
    .{ .n = "ydiaeresis", .cp = 0xFF },
    .{ .n = "oe", .cp = 0x153 },
    .{ .n = "OE", .cp = 0x152 },
    .{ .n = "EuroSign", .cp = 0x20AC },
};

/// Vacuously true on an empty slice: length is the caller's own guard
/// (`symToCp` requires 4-6 digits before it asks).
fn allHex(s: []const u8) bool {
    for (s) |ch| {
        if (!std.ascii.isHex(ch)) return false;
    }
    return true;
}

fn symToCp(sym: []const u8) ?u21 {
    if (sym.len == 1) {
        const ch = sym[0];
        if (ch >= 0x21 and ch < 0x7F) return ch;
        return null;
    }
    // Uxxxx unicode escape: the WHOLE remainder must be hex and 4-6
    // digits long. "starts with U and the next char is hex" also
    // matches the named keysyms `Uacute`, `Ucircumflex`, `Udiaeresis`
    // (real letters on European layouts), which were parsed as hex,
    // failed, and returned nothing instead of reaching named_syms. A
    // failed parse (six digits past U+10FFFF) falls through for the
    // same reason.
    if (sym.len >= 5 and sym.len <= 7 and sym[0] == 'U' and allHex(sym[1..])) {
        if (std.fmt.parseInt(u21, sym[1..], 16)) |cp| return cp else |_| {}
    }
    if (std.mem.startsWith(u8, sym, "0x")) {
        const v = std.fmt.parseInt(u32, sym[2..], 16) catch return null;
        // Keysym unicode range 0x01000000 | cp.
        if (v >= 0x0100_0000) return @intCast(v & 0x00FF_FFFF);
        return null;
    }
    for (named_syms) |e| {
        if (std.mem.eql(u8, e.n, sym)) return e.cp;
    }
    return null;
}

/// Section body between the first '{' after `header` and its
/// matching '}' (brace-counted).
fn sectionBody(text: []const u8, header: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, text, header) orelse return null;
    const open = std.mem.indexOfScalarPos(u8, text, at, '{') orelse return null;
    var depth: usize = 0;
    var i = open;
    while (i < text.len) : (i += 1) {
        if (text[i] == '{') depth += 1;
        if (text[i] == '}') {
            depth -= 1;
            if (depth == 0) return text[open + 1 .. i];
        }
    }
    return null;
}

pub fn parse(allocator: std.mem.Allocator, keymap: []const u8) !Layout {
    var layout = Layout{};
    errdefer layout.deinit(allocator);

    // 1. keycodes: `<NAME> = N;` -> name -> evdev code (N - 8).
    var codes: std.StringHashMapUnmanaged(u32) = .empty;
    defer codes.deinit(allocator);
    const kc = sectionBody(keymap, "xkb_keycodes") orelse return error.BadKeymap;
    var lines = std.mem.splitScalar(u8, kc, '\n');
    while (lines.next()) |line| {
        const lt = std.mem.trim(u8, line, " \t\r");
        if (lt.len < 4 or lt[0] != '<') continue;
        const close = std.mem.indexOfScalar(u8, lt, '>') orelse continue;
        const eq = std.mem.indexOfScalarPos(u8, lt, close, '=') orelse continue;
        const semi = std.mem.indexOfScalarPos(u8, lt, eq, ';') orelse continue;
        const num = std.mem.trim(u8, lt[eq + 1 .. semi], " \t");
        const xcode = std.fmt.parseInt(u32, num, 10) catch continue;
        if (xcode < 8) continue;
        try codes.put(allocator, lt[1..close], xcode - 8);
    }

    // 2. symbols: `key <NAME> { ... [ syms ] ... };`
    const sy = sectionBody(keymap, "xkb_symbols") orelse return error.BadKeymap;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, sy, pos, "key <")) |kat| {
        const name_end = std.mem.indexOfScalarPos(u8, sy, kat + 5, '>') orelse break;
        const name = sy[kat + 5 .. name_end];
        const blk_open = std.mem.indexOfScalarPos(u8, sy, name_end, '{') orelse break;
        var depth: usize = 0;
        var i = blk_open;
        var blk_close = blk_open;
        while (i < sy.len) : (i += 1) {
            if (sy[i] == '{') depth += 1;
            if (sy[i] == '}') {
                depth -= 1;
                if (depth == 0) {
                    blk_close = i;
                    break;
                }
            }
        }
        pos = blk_close + 1;
        const blk = sy[blk_open + 1 .. blk_close];
        const code = codes.get(name) orelse continue;

        // Symbol list: after `symbols[...]=` when present (the group
        // index bracket comes first there), else the first bracket.
        var list = blk;
        if (std.mem.indexOf(u8, blk, "symbols[")) |sat| {
            const eq2 = std.mem.indexOfScalarPos(u8, blk, sat, '=') orelse continue;
            list = blk[eq2 + 1 ..];
        }
        const lb = std.mem.indexOfScalar(u8, list, '[') orelse continue;
        const rb = std.mem.indexOfScalarPos(u8, list, lb, ']') orelse continue;
        var level: u8 = 0;
        var syms = std.mem.splitScalar(u8, list[lb + 1 .. rb], ',');
        while (syms.next()) |raw| {
            level += 1;
            if (level > 4) break;
            const sym = std.mem.trim(u8, raw, " \t\r\n");
            const cp = symToCp(sym) orelse continue;
            const entry = Entry{
                .code = code,
                .shift = (level == 2 or level == 4),
                .altgr = (level == 3 or level == 4),
            };
            const gop = try layout.map.getOrPut(allocator, cp);
            if (!gop.found_existing or levelCost(entry) < levelCost(gop.value_ptr.*)) {
                gop.value_ptr.* = entry;
            }
        }
    }
    if (layout.map.count() < 30) return error.BadKeymap;
    return layout;
}

// ─── tests ──────────────────────────────────────────────────────

const t = std.testing;
const keymaps = @import("../wlhost/keymaps.zig");

test "symToCp: a named keysym beginning with U is not eaten by the hex branch" {
    // Every one of these starts with 'U' followed by a hex digit, which
    // used to route them into parseInt and lose them entirely.
    try t.expectEqual(@as(?u21, 0xDB), symToCp("Ucircumflex"));
    try t.expectEqual(@as(?u21, 0xDC), symToCp("Udiaeresis"));
    try t.expectEqual(@as(?u21, 0xDA), symToCp("Uacute"));
    // 'g' is not hex, so this one always worked; it still does.
    try t.expectEqual(@as(?u21, 0xD9), symToCp("Ugrave"));

    // The escape form itself keeps working, in the 4-, 5- and
    // 6-digit forms.
    try t.expectEqual(@as(?u21, 0xEA), symToCp("U00EA"));
    try t.expectEqual(@as(?u21, 0x20AC), symToCp("U20ac"));
    try t.expectEqual(@as(?u21, 0x1F600), symToCp("U1F600"));
    try t.expectEqual(@as(?u21, 0x1F600), symToCp("U01F600"));
    try t.expectEqual(@as(?u21, 0x10FFFF), symToCp("U10FFFF"));

    // Out of range: falls through instead of returning a parse error.
    try t.expectEqual(@as(?u21, null), symToCp("UFFFFFF"));
    // Neither an escape nor a name.
    try t.expectEqual(@as(?u21, null), symToCp("Unothing"));
    try t.expectEqual(@as(?u21, null), symToCp("U00"));
}

test "us layout maps letters, digits and shifted symbols" {
    var l = try parse(t.allocator, keymaps.us);
    defer l.deinit(t.allocator);
    try t.expectEqual(Entry{ .code = 30 }, l.lookup('a').?);
    try t.expectEqual(Entry{ .code = 30, .shift = true }, l.lookup('A').?);
    try t.expectEqual(Entry{ .code = 2, .shift = true }, l.lookup('!').?);
    try t.expectEqual(Entry{ .code = 2 }, l.lookup('1').?);
}

test "belgian azerty: a on Q-position, digits shifted, at via altgr" {
    var l = try parse(t.allocator, keymaps.be);
    defer l.deinit(t.allocator);
    // Physical top-left letter key (evdev 16, us 'q') types 'a'.
    try t.expectEqual(@as(u32, 16), l.lookup('a').?.code);
    // Digit row unshifted gives symbols; digits need shift.
    const one = l.lookup('1').?;
    try t.expect(one.shift);
    try t.expectEqual(@as(u32, 2), one.code);
    const amp = l.lookup('&').?;
    try t.expect(!amp.shift);
    // '@' is AltGr+2 (eacute key) on be.
    const at = l.lookup('@').?;
    try t.expect(at.altgr);
    // 'e acute' types directly without modifiers.
    const ea = l.lookup(0xE9).?;
    try t.expect(!ea.shift and !ea.altgr);
}

test "german qwertz: z and y swapped, umlauts direct" {
    var l = try parse(t.allocator, keymaps.de);
    defer l.deinit(t.allocator);
    // Physical Y-position (evdev 21) types 'z' on qwertz.
    try t.expectEqual(@as(u32, 44), l.lookup('y').?.code);
    try t.expectEqual(@as(u32, 21), l.lookup('z').?.code);
    try t.expect(l.lookup(0xFC) != null); // u umlaut
    // Capital U-umlaut is spelled `Udiaeresis` in this very keymap, and
    // the old Uxxxx branch swallowed it: shift+ue was untypable.
    const uuml = l.lookup(0xDC) orelse return error.NoCapitalUUmlaut;
    try t.expect(uuml.shift);
    try t.expectEqual(l.lookup(0xFC).?.code, uuml.code);
    // Euro exists (via the dedicated <I443> key at level 1, which
    // the lowest-cost rule correctly prefers over AltGr+E).
    try t.expect(l.lookup(0x20AC) != null);
}
