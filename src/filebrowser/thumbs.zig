//! Freedesktop thumbnail-spec plumbing (GTK-free, unit-tested).
//!
//! Thumbnails live in the cache of the HOST that owns the file:
//! local files use the local $XDG_CACHE_HOME/thumbnails, remote
//! files use the REMOTE host's cache (read and written over the fs
//! wire), so they are shared with every freedesktop app on that
//! host and never duplicated onto the viewer's disk.
//!
//! Spec: key = md5 of the file:// URI (percent-encoded path),
//! stored as thumbnails/normal/<md5>.png (128px tier) with
//! Thumb::URI + Thumb::MTime tEXt chunks for staleness checks.

const std = @import("std");

/// RFC 3986 unreserved set plus '/'; everything else is %XX-encoded
/// (matches g_filename_to_uri for ASCII and UTF-8 paths).
fn isUriSafe(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or switch (ch) {
        '-', '.', '_', '~', '/' => true,
        else => false,
    };
}

/// Write the file:// URI for an absolute POSIX path.
pub fn fileUri(path: []const u8, buf: []u8) ?[]const u8 {
    var w = std.Io.Writer.fixed(buf);
    w.writeAll("file://") catch return null;
    const hex = "0123456789ABCDEF";
    for (path) |ch| {
        if (isUriSafe(ch)) {
            w.writeByte(ch) catch return null;
        } else {
            w.writeByte('%') catch return null;
            w.writeByte(hex[ch >> 4]) catch return null;
            w.writeByte(hex[ch & 15]) catch return null;
        }
    }
    return w.buffered();
}

/// The md5-hex thumbnail key for an absolute path.
pub fn thumbKey(path: []const u8) ?[32]u8 {
    var ubuf: [4096 * 3 + 8]u8 = undefined;
    const uri = fileUri(path, &ubuf) orelse return null;
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(uri, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// The normal-tier (128px) thumbnail path inside `cache_dir`
/// (…/thumbnails/normal/<md5>.png).
pub fn thumbPath(cache_dir: []const u8, path: []const u8, buf: []u8) ?[]const u8 {
    const key = thumbKey(path) orelse return null;
    return std.fmt.bufPrint(buf, "{s}/thumbnails/normal/{s}.png", .{ cache_dir, &key }) catch null;
}

test "fileUri percent-encodes exactly like the spec examples" {
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "file:///home/jens/photos/me.png",
        fileUri("/home/jens/photos/me.png", &buf).?,
    );
    try std.testing.expectEqualStrings(
        "file:///tmp/a%20b%27c",
        fileUri("/tmp/a b'c", &buf).?,
    );
}

test "thumbKey matches the canonical spec example" {
    // From the freedesktop thumbnail spec: the URI
    // file:///home/jens/photos/me.png hashes to this key.
    const key = thumbKey("/home/jens/photos/me.png").?;
    try std.testing.expectEqualStrings("c6ee772d9e49320e97ec29a7eb5b1697", &key);
}

test "thumbPath composes cache dir, tier, and key" {
    var buf: [4096]u8 = undefined;
    const p = thumbPath("/home/x/.cache", "/home/jens/photos/me.png", &buf).?;
    try std.testing.expectEqualStrings(
        "/home/x/.cache/thumbnails/normal/c6ee772d9e49320e97ec29a7eb5b1697.png",
        p,
    );
}
