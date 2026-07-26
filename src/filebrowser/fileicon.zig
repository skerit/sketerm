//! Pure presentation helpers for browser rows: the icon a listing
//! entry deserves, and the text a directory shows where a file shows
//! its size. GTK-free on purpose so both live in tests.

const std = @import("std");

/// Icon theme name for a listing entry, given its `kind` and whether
/// it resolves to a directory.
///
/// Non-symbolic names deliberately: the file manager wants the user's
/// full-colour icon theme (Papirus, Breeze, ...), the way Nemo does.
/// A null answer means "ask the content type", which needs GLib and so
/// cannot live here.
pub fn folderIconName(kind: []const u8, resolves_to_dir: bool) ?[]const u8 {
    if (resolves_to_dir or std.mem.eql(u8, kind, "dir")) return "folder";
    return null;
}

/// Fallback icon name for a file whose content type is unknown.
pub const GENERIC_ICON = "text-x-generic";

/// A directory's child count as the Size column shows it.
///
/// `n` below zero means the daemon did not answer, which is NOT the
/// same as an empty directory and must not read as "0 items".
pub fn fmtItems(buf: []u8, n: i64) []const u8 {
    if (n < 0) return "--";
    if (n == 1) return std.fmt.bufPrint(buf, "1 item", .{}) catch "1 item";
    return std.fmt.bufPrint(buf, "{d} items", .{n}) catch "?";
}

test "fmtItems singular, plural, empty and unknown" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("--", fmtItems(&buf, -1));
    try std.testing.expectEqualStrings("--", fmtItems(&buf, -7));
    try std.testing.expectEqualStrings("0 items", fmtItems(&buf, 0));
    try std.testing.expectEqualStrings("1 item", fmtItems(&buf, 1));
    try std.testing.expectEqualStrings("2 items", fmtItems(&buf, 2));
    try std.testing.expectEqualStrings("1042 items", fmtItems(&buf, 1042));
}

test "folderIconName picks the themed folder for directories only" {
    try std.testing.expectEqualStrings("folder", folderIconName("dir", false).?);
    try std.testing.expectEqualStrings("folder", folderIconName("link", true).?);
    try std.testing.expect(folderIconName("file", false) == null);
    try std.testing.expect(folderIconName("link", false) == null);
}
