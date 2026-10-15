//! Key-chord names and grammar shared by every key-injecting backend: the PTY encoder (ipc/keys.zig), the evdev
//! seat (ipc/evkeys.zig) and the web view (web/webkeys.zig). std only, usable from every target.
//!
//! A chord is `[mod+]*key`, names case-insensitive. A trailing `+` is the key itself (`+`, `ctrl++`). Each
//! backend maps `Named` and `Mod` with an exhaustive switch and refuses what it cannot send. `super`, `cmd` and
//! `win` are Super everywhere; `meta` alone differs by convention, so every backend declares a `Dialect`.

const std = @import("std");

pub const Mod = enum {
    ctrl,
    alt,
    shift,
    super,

    /// The modifier as a key of its own, for a caller that holds one rather than chording it.
    pub fn key(self: Mod) Named {
        return switch (self) {
            .ctrl => .ctrl,
            .alt => .alt,
            .shift => .shift,
            .super => .super,
        };
    }
};

pub const Mods = std.EnumSet(Mod);

/// A backend's reading of the names whose meaning is a convention rather than a key.
pub const Dialect = struct {
    /// The modifier `meta` names: Alt to a terminal (ESC prefix, xterm bit 2), Super where Meta is the
    /// Command/Windows key (DOM metaKey, the evdev seat).
    meta: Mod,
};

/// Non-character keys; the tag is the canonical name.
pub const Named = enum {
    enter,
    tab,
    escape,
    backspace,
    space,
    delete,
    insert,
    home,
    end,
    page_up,
    page_down,
    up,
    down,
    left,
    right,
    menu,
    caps_lock,
    shift,
    ctrl,
    alt,
    super,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
};

pub const Key = union(enum) {
    named: Named,
    /// Exactly one UTF-8 encoded codepoint, case preserved.
    char: []const u8,
};

pub const Chord = struct {
    mods: Mods = .initEmpty(),
    key: Key,
};

pub const Error = error{ EmptyChord, UnknownModifier, UnknownKey };

const Alias = struct { name: []const u8, key: Named };

const key_aliases = [_]Alias{
    .{ .name = "return", .key = .enter },
    .{ .name = "cr", .key = .enter },
    .{ .name = "esc", .key = .escape },
    .{ .name = "bs", .key = .backspace },
    .{ .name = "del", .key = .delete },
    .{ .name = "pageup", .key = .page_up },
    .{ .name = "pgup", .key = .page_up },
    .{ .name = "pagedown", .key = .page_down },
    .{ .name = "pgdn", .key = .page_down },
    .{ .name = "arrowup", .key = .up },
    .{ .name = "arrowdown", .key = .down },
    .{ .name = "arrowleft", .key = .left },
    .{ .name = "arrowright", .key = .right },
    .{ .name = "capslock", .key = .caps_lock },
};

const mod_aliases = [_]struct { name: []const u8, mod: Mod }{
    .{ .name = "control", .mod = .ctrl },
    .{ .name = "option", .mod = .alt },
    .{ .name = "cmd", .mod = .super },
    .{ .name = "win", .mod = .super },
};

/// The modifier a `mod+` prefix names, any case. Single letters are never modifiers, so "a+b" is refused rather than read as alt+b.
pub fn modFor(name: []const u8, dialect: Dialect) ?Mod {
    if (std.ascii.eqlIgnoreCase(name, "meta")) return dialect.meta;
    inline for (comptime std.enums.values(Mod)) |m| {
        if (std.ascii.eqlIgnoreCase(name, @tagName(m))) return m;
    }
    for (mod_aliases) |a| if (std.ascii.eqlIgnoreCase(name, a.name)) return a.mod;
    return null;
}

/// The non-character key `name` stands for, any case; modifier names are their own keys.
pub fn namedFor(name: []const u8, dialect: Dialect) ?Named {
    inline for (comptime std.enums.values(Named)) |n| {
        if (std.ascii.eqlIgnoreCase(name, @tagName(n))) return n;
    }
    for (key_aliases) |a| if (std.ascii.eqlIgnoreCase(name, a.name)) return a.key;
    if (modFor(name, dialect)) |m| return m.key();
    return null;
}

/// Parse one `mod+key` chord.
pub fn parse(spec: []const u8, dialect: Dialect) Error!Chord {
    var mods: Mods = .initEmpty();
    var rest = spec;
    while (std.mem.indexOfScalar(u8, rest, '+')) |plus| {
        if (plus + 1 == rest.len) break; // the key IS '+'
        mods.insert(modFor(rest[0..plus], dialect) orelse return error.UnknownModifier);
        rest = rest[plus + 1 ..];
    }
    if (rest.len == 0) return error.EmptyChord;
    if (namedFor(rest, dialect)) |n| return .{ .mods = mods, .key = .{ .named = n } };
    const view = std.unicode.Utf8View.init(rest) catch return error.UnknownKey;
    var it = view.iterator();
    _ = it.nextCodepoint() orelse return error.UnknownKey;
    if (it.nextCodepoint() != null) return error.UnknownKey;
    return .{ .mods = mods, .key = .{ .char = rest } };
}

/// The whitespace-separated chords of a chord list ("ctrl+c up enter").
pub fn chords(spec: []const u8) std.mem.TokenIterator(u8, .any) {
    return std.mem.tokenizeAny(u8, spec, " \t\n");
}

const t = std.testing;

const as_super: Dialect = .{ .meta = .super };
const as_alt: Dialect = .{ .meta = .alt };

fn expectNamed(spec: []const u8, want: Named) !void {
    const ch = try parse(spec, as_super);
    try t.expectEqual(want, ch.key.named);
}

test "every alias spelling reaches its canonical key, any case" {
    try expectNamed("Enter", .enter);
    try expectNamed("return", .enter);
    try expectNamed("CR", .enter);
    try expectNamed("pgup", .page_up);
    try expectNamed("PageUp", .page_up);
    try expectNamed("page_up", .page_up);
    try expectNamed("pgdn", .page_down);
    try expectNamed("pagedown", .page_down);
    try expectNamed("Page_Down", .page_down);
    try expectNamed("ArrowLeft", .left);
    try expectNamed("del", .delete);
    try expectNamed("bs", .backspace);
    try expectNamed("capslock", .caps_lock);
    try expectNamed("F12", .f12);
    try t.expectError(error.UnknownKey, parse("f13", as_super));
    try t.expectError(error.UnknownKey, parse("bogus_key", as_super));
}

test "meta follows the backend's dialect; super, cmd and win are Super in every dialect" {
    for ([_]Dialect{ as_super, as_alt }) |d| {
        for ([_][]const u8{ "Super", "cmd", "win" }) |name| try t.expectEqual(Mod.super, modFor(name, d).?);
        for ([_][]const u8{ "alt", "Option" }) |name| try t.expectEqual(Mod.alt, modFor(name, d).?);
        try t.expectEqual(Mod.ctrl, modFor("control", d).?);
        try t.expectEqual(Mod.shift, modFor("SHIFT", d).?);
        try t.expectEqual(@as(?Mod, null), modFor("hyper", d));
        for ([_][]const u8{ "c", "a", "s", "m" }) |letter| try t.expectEqual(@as(?Mod, null), modFor(letter, d));
    }
    try t.expectEqual(Mod.super, modFor("Meta", as_super).?);
    try t.expectEqual(Mod.alt, modFor("Meta", as_alt).?);
    try t.expect((try parse("meta+x", as_alt)).mods.contains(.alt));
    // A modifier named alone is its key.
    try expectNamed("meta", .super);
    try t.expectEqual(Named.alt, (try parse("meta", as_alt)).key.named);
    try expectNamed("Control", .ctrl);
    try expectNamed("option", .alt);
}

test "a literal plus parses the same way in every position" {
    const bare = try parse("+", as_super);
    try t.expectEqualStrings("+", bare.key.char);
    try t.expectEqual(@as(usize, 0), bare.mods.count());
    const ctrl_plus = try parse("ctrl++", as_super);
    try t.expectEqualStrings("+", ctrl_plus.key.char);
    try t.expect(ctrl_plus.mods.contains(.ctrl));
    const two = try parse("ctrl+shift++", as_super);
    try t.expect(two.mods.contains(.ctrl) and two.mods.contains(.shift));
    try t.expectError(error.UnknownModifier, parse("++", as_super));
    try t.expectError(error.UnknownModifier, parse("hyper+a", as_super));
    try t.expectError(error.UnknownModifier, parse("ctrl+a+b", as_super));
    try t.expectError(error.UnknownKey, parse("ctrl+", as_super));
    try t.expectError(error.EmptyChord, parse("", as_super));
}

test "a character key is one codepoint with its case kept" {
    try t.expectEqualStrings("T", (try parse("ctrl+T", as_super)).key.char);
    try t.expectEqualStrings("\xc3\xa9", (try parse("\xc3\xa9", as_super)).key.char);
    try t.expectError(error.UnknownKey, parse("ab", as_super));
    try t.expectError(error.UnknownKey, parse("\xc3", as_super));
    var it = chords(" ctrl+c\tup  enter\n");
    try t.expectEqualStrings("ctrl+c", it.next().?);
    try t.expectEqualStrings("up", it.next().?);
    try t.expectEqualStrings("enter", it.next().?);
    try t.expect(it.next() == null);
}
