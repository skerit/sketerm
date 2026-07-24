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
const c = @import("../c.zig").c;
const pathz = @import("../util/pathz.zig");

pub const Tier = enum { normal, large, x_large };

fn tierName(tier: Tier) []const u8 {
    return switch (tier) { .normal => "normal", .large => "large", .x_large => "x-large" };
}

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
    return thumbPathTier(cache_dir, path, .normal, buf);
}

pub fn thumbPathTier(cache_dir: []const u8, path: []const u8, tier: Tier, buf: []u8) ?[]const u8 {
    const key = thumbKey(path) orelse return null;
    return std.fmt.bufPrint(buf, "{s}/thumbnails/{s}/{s}.png", .{ cache_dir, tierName(tier), &key }) catch null;
}

fn appendChunk(out: *std.ArrayList(u8), allocator: std.mem.Allocator, kind: *const [4]u8, data: []const u8) !void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(data.len), .big);
    try out.appendSlice(allocator, &len);
    try out.appendSlice(allocator, kind);
    try out.appendSlice(allocator, data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    var sum: [4]u8 = undefined;
    std.mem.writeInt(u32, &sum, crc.final(), .big);
    try out.appendSlice(allocator, &sum);
}

/// Add the freedesktop URI/MTime chunks to a generated PNG and
/// atomically install it with spec permissions.
pub fn installPng(
    allocator: std.mem.Allocator,
    generated_path: []const u8,
    final_path: []const u8,
    uri: []const u8,
    mtime_sec: i64,
) !void {
    var gz: [4096]u8 = undefined;
    const fp = c.fopen(try pathz.pathZ(&gz, generated_path), "rb") orelse return error.OpenFailed;
    defer _ = c.fclose(fp);
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(allocator);
    var block: [64 * 1024]u8 = undefined;
    while (true) {
        const n = c.fread(&block, 1, block.len, fp);
        if (n > 0) try input.appendSlice(allocator, block[0..n]);
        if (n < block.len) break;
        if (input.items.len > 64 << 20) return error.TooLarge;
    }
    if (input.items.len < 20 or !std.mem.eql(u8, input.items[0..8], "\x89PNG\r\n\x1a\n")) return error.BadPng;
    var i: usize = 8;
    var iend: ?usize = null;
    while (i + 12 <= input.items.len) {
        const len = std.mem.readInt(u32, input.items[i..][0..4], .big);
        const end = i + 12 + @as(usize, len);
        if (end > input.items.len) return error.BadPng;
        if (std.mem.eql(u8, input.items[i + 4 .. i + 8], "IEND")) { iend = i; break; }
        i = end;
    }
    const cut = iend orelse return error.BadPng;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try output.appendSlice(allocator, input.items[0..cut]);
    const uri_text = try std.fmt.allocPrint(allocator, "Thumb::URI\x00{s}", .{uri});
    defer allocator.free(uri_text);
    try appendChunk(&output, allocator, "tEXt", uri_text);
    const mtime = try std.fmt.allocPrint(allocator, "Thumb::MTime\x00{d}", .{mtime_sec});
    defer allocator.free(mtime);
    try appendChunk(&output, allocator, "tEXt", mtime);
    try output.appendSlice(allocator, input.items[cut..]);

    try pathz.makeParentDirs(final_path);
    const temp = try std.fmt.allocPrint(allocator, "{s}.tmp-{d}", .{ final_path, c.getpid() });
    defer allocator.free(temp);
    var tz: [4096]u8 = undefined;
    const out = c.fopen(try pathz.pathZ(&tz, temp), "wb") orelse return error.WriteFailed;
    if (c.fwrite(output.items.ptr, 1, output.items.len, out) != output.items.len or c.fflush(out) != 0) {
        _ = c.fclose(out);
        return error.WriteFailed;
    }
    _ = c.fsync(c.fileno(out));
    if (c.fclose(out) != 0) return error.WriteFailed;
    _ = c.chmod(try pathz.pathZ(&tz, temp), 0o600);
    var fz: [4096]u8 = undefined;
    if (c.rename(try pathz.pathZ(&tz, temp), try pathz.pathZ(&fz, final_path)) != 0) return error.WriteFailed;
}

/// Validate both mandatory freedesktop metadata chunks without
/// decoding pixels.
pub fn validatePng(path: []const u8, uri: []const u8, mtime_sec: i64) bool {
    var z: [4096]u8 = undefined;
    const fp = c.fopen(pathz.pathZ(&z, path) catch return false, "rb") orelse return false;
    defer _ = c.fclose(fp);
    var bytes: [2 * 1024 * 1024]u8 = undefined;
    const n = c.fread(&bytes, 1, bytes.len, fp);
    if (n == bytes.len) return false;
    return validatePngBytes(bytes[0..n], uri, mtime_sec);
}

fn validatePngBytes(bytes: []const u8, uri: []const u8, mtime_sec: i64) bool {
    if (bytes.len < 20 or !std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return false;
    var mtime_buf: [32]u8 = undefined;
    const mtime = std.fmt.bufPrint(&mtime_buf, "{d}", .{mtime_sec}) catch return false;
    var have_uri = false;
    var have_mtime = false;
    var have_iend = false;
    var i: usize = 8;
    while (i + 12 <= bytes.len) {
        const len: usize = std.mem.readInt(u32, bytes[i..][0..4], .big);
        const end = i + 12 + len;
        if (end > bytes.len) return false;
        const kind = bytes[i + 4 .. i + 8];
        const data = bytes[i + 8 .. i + 8 + len];
        var crc = std.hash.Crc32.init();
        crc.update(kind);
        crc.update(data);
        if (crc.final() != std.mem.readInt(u32, bytes[i + 8 + len ..][0..4], .big)) return false;
        if (std.mem.eql(u8, kind, "tEXt")) {
            if (std.mem.startsWith(u8, data, "Thumb::URI\x00") and std.mem.eql(u8, data[11..], uri)) have_uri = true;
            if (std.mem.startsWith(u8, data, "Thumb::MTime\x00") and std.mem.eql(u8, data[13..], mtime)) have_mtime = true;
        }
        if (std.mem.eql(u8, kind, "IEND")) {
            if (len != 0) return false;
            have_iend = true;
            break;
        }
        i = end;
    }
    return have_uri and have_mtime and have_iend;
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

test "large thumbnail tier has a distinct spec path" {
    var buf: [4096]u8 = undefined;
    const p = thumbPathTier("/cache", "/a.pdf", .large, &buf).?;
    try std.testing.expect(std.mem.indexOf(u8, p, "/thumbnails/large/") != null);
}

test "PNG cache validation rejects a corrupt chunk CRC" {
    const a = std.testing.allocator;
    var png: std.ArrayList(u8) = .empty;
    defer png.deinit(a);
    try png.appendSlice(a, "\x89PNG\r\n\x1a\n");
    try appendChunk(&png, a, "tEXt", "Thumb::URI\x00file:///tmp/a.png");
    try appendChunk(&png, a, "tEXt", "Thumb::MTime\x00123");
    try appendChunk(&png, a, "IEND", "");
    try std.testing.expect(validatePngBytes(png.items, "file:///tmp/a.png", 123));
    png.items[20] ^= 1;
    try std.testing.expect(!validatePngBytes(png.items, "file:///tmp/a.png", 123));
}
