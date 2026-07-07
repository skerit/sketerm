//! Embedded compiled-xkb keymaps for forwarded-app sessions.
//! Generated with `xkbcli compile-keymap --layout <l> --model pc105`.
//! The session's keymap must match what drives it: GUI users pass
//! their real hardware keycodes through, MCP typing encodes against
//! the same blob via ipc/xkblayout.zig.

pub const us = @embedFile("us_keymap.txt");
pub const gb = @embedFile("keymap_gb.txt");
pub const fr = @embedFile("keymap_fr.txt");
pub const be = @embedFile("keymap_be.txt");
pub const de = @embedFile("keymap_de.txt");

/// Human-facing list for error messages / docs.
pub const names = "us, gb, fr (azerty), be (azerty), de (qwertz)";

pub fn get(name: []const u8) ?[]const u8 {
    const eql = @import("std").mem.eql;
    if (name.len == 0 or eql(u8, name, "us") or eql(u8, name, "qwerty")) return us;
    if (eql(u8, name, "gb") or eql(u8, name, "uk")) return gb;
    if (eql(u8, name, "fr")) return fr;
    if (eql(u8, name, "be") or eql(u8, name, "azerty")) return be;
    if (eql(u8, name, "de") or eql(u8, name, "qwertz")) return de;
    return null;
}

test "layout lookup resolves names and aliases" {
    const t = @import("std").testing;
    try t.expect(get("us").? .ptr == us.ptr);
    try t.expect(get("").? .ptr == us.ptr);
    try t.expect(get("azerty").? .ptr == be.ptr);
    try t.expect(get("qwertz").? .ptr == de.ptr);
    try t.expect(get("dvorak") == null);
}
