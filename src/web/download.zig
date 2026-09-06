//! Download presentation policy shared by browser clients. Values are CEF's
//! download interrupt reasons, carried as integers so this stays CEF-free.
const std = @import("std");

pub fn failureReason(code: i32) []const u8 {
    return switch (code) {
        1 => "Could not write the file. Check the destination and retry.",
        2 => "Permission denied. Choose a writable destination.",
        3 => "The destination is out of disk space. Free space, then retry.",
        5 => "The file name is too long. Choose a shorter name.",
        6 => "The file is too large for the destination filesystem.",
        7, 11, 12 => "The browser blocked this download after a safety check.",
        10 => "A temporary file error interrupted the download. Retry to start again.",
        13, 14 => "The downloaded file is incomplete or failed verification. Retry to start again.",
        15 => "The download source and destination are the same file.",
        20, 21, 22, 23 => "The network connection was interrupted. Reconnect, then retry.",
        24 => "The browser could not make this request. Try the page's download link again.",
        30, 31, 33, 37 => "The server could not deliver the file. Retry or use the page's download link.",
        34, 36 => "The server refused access. Sign in on the page, then try its download link again.",
        35 => "The server's certificate could not be verified. Open the page to inspect the error.",
        38 => "The server content changed during download. Retry to start again.",
        40 => "The download was canceled.",
        41 => "The browser stopped before the download finished. Reload the page and retry.",
        else => "The download was interrupted. Retry to start again, or use the page's download link.",
    };
}

/// The leaf a page-suggested download name may become.
///
/// The suggestion reaching a client is engine-derived, hence
/// page-controlled, and the auto-accept path JOINS it to a directory —
/// so a separator in it picks the destination instead of the user.
/// Both separators are stripped: a name is never a path here, whichever
/// platform's shape it arrived in. "download" when nothing is left.
pub fn safeName(name: []const u8) []const u8 {
    var s = name;
    while (s.len != 0 and (s[s.len - 1] == '/' or s[s.len - 1] == '\\')) s = s[0 .. s.len - 1];
    if (std.mem.lastIndexOfAny(u8, s, "/\\")) |i| s = s[i + 1 ..];
    if (s.len == 0 or std.mem.eql(u8, s, ".") or std.mem.eql(u8, s, "..")) return "download";
    return s;
}

pub const Retry = enum { unavailable, download, delivery };

pub fn retryAction(downloaded: bool, has_url: bool, can_start: bool) Retry {
    if (downloaded) return .delivery;
    return if (has_url and can_start) .download else .unavailable;
}

test "a suggested download name cannot escape the directory it is joined to" {
    const t = std.testing;
    // The engine's suggested name is derived from page-controlled data
    // (Content-Disposition, the url tail). Auto-accept joins it to the
    // XDG download directory, so a separator in it would write anywhere
    // the user can write.
    try t.expectEqualStrings("passwd", safeName("../../../etc/passwd"));
    try t.expectEqualStrings("x", safeName("/tmp/x"));
    try t.expectEqualStrings("evil.desktop", safeName("..\\..\\evil.desktop"));
    // Nothing usable is left: the caller still needs a name.
    try t.expectEqualStrings("download", safeName(""));
    try t.expectEqualStrings("download", safeName(".."));
    try t.expectEqualStrings("download", safeName("."));
    try t.expectEqualStrings("download", safeName("/"));
    try t.expectEqualStrings("download", safeName("../"));
    // An ordinary name is handed back untouched, dots and all.
    try t.expectEqualStrings("report.final.pdf", safeName("report.final.pdf"));
    try t.expectEqualStrings(".bashrc", safeName(".bashrc"));
}

test "completed downloads retry delivery without reissuing the web request" {
    try std.testing.expectEqual(Retry.delivery, retryAction(true, false, false));
    try std.testing.expectEqual(Retry.download, retryAction(false, true, true));
    try std.testing.expectEqual(Retry.unavailable, retryAction(false, true, false));
    try std.testing.expectEqual(Retry.unavailable, retryAction(false, false, true));
    try std.testing.expect(std.mem.indexOf(u8, failureReason(3), "disk space") != null);
    try std.testing.expect(std.mem.indexOf(u8, failureReason(34), "Sign in") != null);
    try std.testing.expect(failureReason(9999).len != 0);
}
