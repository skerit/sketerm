//! GTK-free location and path predicates shared by the file browser:
//! spec parsing, network-mount bypass, trash/archive/media
//! classification and destination-name uniquing.

const std = @import("std");
const c = @import("../c.zig").c;
const model = @import("model.zig");
const mounts = @import("../util/mounts.zig");

/// A parsed location spec. Bare "/path" keeps the CURRENT host
/// (current = local when there is no current tab); "local:/path"
/// forces local; "host:/path", "user@host:/path" and "udp:host:/path"
/// use the terminal host-string convention.
pub const Loc = struct {
    /// null = local, .current = keep the tab's host.
    host: ?[]const u8,
    current_host: bool,
    path: []const u8,
};

pub fn parseSpec(spec: []const u8) Loc {
    if (spec.len == 0) return .{ .host = null, .current_host = false, .path = "/" };
    if (spec[0] == '/') return .{ .host = null, .current_host = true, .path = spec };
    if (model.hostOnlySpec(spec)) |host| {
        if (std.mem.eql(u8, host, "local"))
            return .{ .host = null, .current_host = false, .path = "/" };
        return .{ .host = host, .current_host = false, .path = "/" };
    }
    if (std.mem.indexOf(u8, spec, ":/")) |i| {
        const host = spec[0..i];
        const path = spec[i + 1 ..];
        if (host.len == 0 or std.mem.eql(u8, host, "local"))
            return .{ .host = null, .current_host = false, .path = path };
        return .{ .host = host, .current_host = false, .path = path };
    }
    return .{ .host = null, .current_host = true, .path = spec };
}

/// Buffer size a caller must provide to hold any spec `formatSpec`
/// can produce (host + ':' + a PATH_MAX-class path).
pub const SPEC_BUF_LEN = 4300;

/// The inverse of `parseSpec`: render (host, path) as an unambiguous
/// spec. Local paths are host-qualified as "local:" so a round trip
/// never picks up a "current host". Falls back to the bare path when
/// `buf` is too small, so the result is NOT always a slice of `buf`.
pub fn formatSpec(buf: []u8, host: ?[]const u8, path: []const u8) []const u8 {
    const absolute = if (path.len == 0) "/" else path;
    if (host) |h| return std.fmt.bufPrint(buf, "{s}:{s}", .{ h, absolute }) catch absolute;
    return std.fmt.bufPrint(buf, "local:{s}", .{absolute}) catch absolute;
}

/// Whether `name` is offered as a path-bar completion for `prefix`
/// (dotfiles are never suggested; matching is case-insensitive).
pub fn completionMatches(name: []const u8, prefix: []const u8) bool {
    if (name.len > 0 and name[0] == '.') return false;
    if (prefix.len > name.len) return false;
    return std.ascii.eqlIgnoreCase(prefix, name[0..prefix.len]);
}

/// A network-mount bypass hit: (mountpoint under `path`) rewritten
/// to direct mux access on the mount's source host.
pub const BypassHit = struct {
    host_buf: [256]u8 = undefined,
    host_len: usize = 0,
    path_buf: [4096]u8 = undefined,
    path_len: usize = 0,
    mp_buf: [1024]u8 = undefined,
    mp_len: usize = 0,

    pub fn host(self: *const BypassHit) []const u8 {
        return self.host_buf[0..self.host_len];
    }
    pub fn path(self: *const BypassHit) []const u8 {
        return self.path_buf[0..self.path_len];
    }
    pub fn mountpoint(self: *const BypassHit) []const u8 {
        return self.mp_buf[0..self.mp_len];
    }
};

/// Decode /proc/mounts octal escapes (\040 = space, …) in place.
pub fn unescapeMnt(buf: []u8, src: []const u8) []const u8 {
    var w: usize = 0;
    var r: usize = 0;
    while (r < src.len and w < buf.len) {
        if (src[r] == '\\' and r + 3 < src.len) {
            const v = std.fmt.parseInt(u8, src[r + 1 .. r + 4], 8) catch {
                buf[w] = src[r];
                w += 1;
                r += 1;
                continue;
            };
            buf[w] = v;
            w += 1;
            r += 4;
        } else {
            buf[w] = src[r];
            w += 1;
            r += 1;
        }
    }
    return buf[0..w];
}

/// Detect an sshfs/NFS mount covering `p` and rewrite to direct mux
/// access: the mount source ("user@host:/remote") names both the ssh
/// host and the remote prefix. Longest mountpoint wins. Linux-only
/// (/proc/mounts); false elsewhere.
pub fn mountBypass(p: []const u8, out: *BypassHit) bool {
    var hit: mounts.Hit = .{};
    if (!mounts.detect(p, &hit)) return false;
    @memcpy(out.host_buf[0..hit.host_len], hit.host());
    out.host_len = hit.host_len;
    @memcpy(out.path_buf[0..hit.path_len], hit.path());
    out.path_len = hit.path_len;
    @memcpy(out.mp_buf[0..hit.mount_len], hit.mountpoint());
    out.mp_len = hit.mount_len;
    return true;
}

pub fn hostEq(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

/// Extensions the preview pane and row thumbnails treat as images
/// (decodable by gdk-pixbuf).
pub fn isImageName(name: []const u8) bool {
    const exts = [_][]const u8{ ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".svg", ".ico", ".tif", ".tiff", ".avif", ".heic", ".heif" };
    for (exts) |ext| if (std.ascii.endsWithIgnoreCase(name, ext)) return true;
    return false;
}

pub fn isWorkerImageName(name: []const u8) bool {
    const exts = [_][]const u8{ ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".svg", ".ico", ".tif", ".tiff" };
    for (exts) |ext| if (std.ascii.endsWithIgnoreCase(name, ext)) return true;
    return false;
}

pub fn isPreviewMediaName(name: []const u8) bool {
    if (isImageName(name)) return true;
    const exts = [_][]const u8{
        ".pdf", ".mp4", ".mkv", ".webm", ".avi", ".mov", ".m4v", ".mpeg", ".mpg",
        ".mp3", ".flac", ".ogg", ".opus", ".wav", ".m4a", ".aac",
    };
    for (exts) |ext| if (std.ascii.endsWithIgnoreCase(name, ext)) return true;
    return false;
}

pub fn isArchivePath(path: []const u8) bool {
    const exts = [_][]const u8{ ".zip", ".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tar.xz", ".txz", ".7z" };
    for (exts) |ext| if (std.ascii.endsWithIgnoreCase(path, ext)) return true;
    return false;
}

/// Decode %XX escapes (freedesktop .trashinfo Path values).
pub fn urlUnescape(s: []const u8, buf: []u8) ?[]const u8 {
    var out: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (out >= buf.len) return null;
        if (s[i] == '%' and i + 2 < s.len) {
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch {
                buf[out] = s[i];
                out += 1;
                i += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch {
                buf[out] = s[i];
                out += 1;
                i += 1;
                continue;
            };
            buf[out] = (hi << 4) | lo;
            out += 1;
            i += 3;
        } else {
            buf[out] = s[i];
            out += 1;
            i += 1;
        }
    }
    return buf[0..out];
}

/// True when a LOCAL path sits on a sketerm FUSE mount (whose pin/
/// evict xattrs control the hydration cache).
pub fn isSketermMount(path: []const u8) bool {
    const f = c.fopen("/proc/mounts", "rb") orelse return false;
    defer _ = c.fclose(f);
    var buf: [32 * 1024]u8 = undefined;
    const n = c.fread(&buf, 1, buf.len, f);
    var it = std.mem.tokenizeScalar(u8, buf[0..n], '\n');
    while (it.next()) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        _ = fields.next() orelse continue;
        const mp = fields.next() orelse continue;
        const fstype = fields.next() orelse continue;
        if (!std.mem.eql(u8, fstype, "fuse.sketerm")) continue;
        if (std.mem.startsWith(u8, path, mp) and
            (path.len == mp.len or path[mp.len] == '/')) return true;
    }
    return false;
}

/// The local freedesktop trash "files" directory.
pub fn trashFilesDir(buf: []u8) ?[]const u8 {
    if (c.getenv("XDG_DATA_HOME")) |xd| {
        const s = std.mem.span(@as([*:0]const u8, @ptrCast(xd)));
        return std.fmt.bufPrint(buf, "{s}/Trash/files", .{s}) catch null;
    }
    if (c.getenv("HOME")) |h| {
        const s = std.mem.span(@as([*:0]const u8, @ptrCast(h)));
        return std.fmt.bufPrint(buf, "{s}/.local/share/Trash/files", .{s}) catch null;
    }
    return null;
}

/// True when `path` is inside a freedesktop trash "files" dir —
/// the home trash (…/Trash/files) or a topdir one (…/.Trash-UID/files).
pub fn isTrashPath(path: []const u8) bool {
    if (std.mem.indexOf(u8, path, "/Trash/files") != null) return true;
    if (std.mem.indexOf(u8, path, "/.Trash-")) |i| {
        return std.mem.indexOf(u8, path[i..], "/files") != null;
    }
    return false;
}

/// The child name inside `ancestor` on the way toward `root`, or
/// null when root is not under ancestor.
pub fn millerNextSegment(ancestor: []const u8, root: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, root, ancestor)) return null;
    var rest = root[ancestor.len..];
    if (rest.len > 0 and rest[0] == '/') rest = rest[1..];
    if (rest.len == 0) return null;
    const end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    return rest[0..end];
}

/// Pick a name that collides with nothing in `taken`: "base-copy",
/// then "base-copy2"... `taken` is anything with a
/// `contains([]const u8) bool` method (the live target listing, in
/// the browser's case).
/// @return null when `buf` is too small or 999 names are all taken.
pub fn uniqueName(base: []const u8, buf: []u8, taken: anytype) ?[]const u8 {
    var candidate = std.fmt.bufPrint(buf, "{s}-copy", .{base}) catch return null;
    var n: u32 = 2;
    while (taken.contains(candidate)) : (n += 1) {
        if (n > 999) return null;
        candidate = std.fmt.bufPrint(buf, "{s}-copy{d}", .{ base, n }) catch return null;
    }
    return candidate;
}

test "isImageName recognizes previewable extensions" {
    const t = std.testing;
    try t.expect(isImageName("photo.JPG"));
    try t.expect(isImageName("a.webp"));
    try t.expect(!isImageName("notes.txt"));
    try t.expect(!isImageName("jpg"));
}

test "isPreviewMediaName includes document video and audio formats" {
    const t = std.testing;
    try t.expect(isPreviewMediaName("manual.PDF"));
    try t.expect(isPreviewMediaName("clip.webm"));
    try t.expect(isPreviewMediaName("album.flac"));
    try t.expect(!isPreviewMediaName("source.zig"));
}

test "parseSpec forms" {
    const t = std.testing;
    var l = parseSpec("/home/x");
    try t.expect(l.current_host and l.host == null);
    try t.expectEqualStrings("/home/x", l.path);
    l = parseSpec("nas:/srv/data");
    try t.expect(!l.current_host);
    try t.expectEqualStrings("nas", l.host.?);
    try t.expectEqualStrings("/srv/data", l.path);
    l = parseSpec("user@box:/p");
    try t.expectEqualStrings("user@box", l.host.?);
    l = parseSpec("udp:box:/p");
    try t.expectEqualStrings("udp:box", l.host.?);
    try t.expectEqualStrings("/p", l.path);
    l = parseSpec("local:/etc");
    try t.expect(l.host == null and !l.current_host);
    try t.expectEqualStrings("/etc", l.path);
    // An empty spec is the only form that does NOT inherit the host.
    l = parseSpec("");
    try t.expect(l.host == null and !l.current_host);
    try t.expectEqualStrings("/", l.path);
    // A relative word is a path on the current host, not a host name.
    l = parseSpec("docs");
    try t.expect(l.current_host);
    try t.expectEqualStrings("docs", l.path);
    // Old persisted host-only recents name the host root, not a
    // relative path on whichever tab happens to be current.
    l = parseSpec("archdev:");
    try t.expect(!l.current_host);
    try t.expectEqualStrings("archdev", l.host.?);
    try t.expectEqualStrings("/", l.path);
    l = parseSpec("local:");
    try t.expect(l.host == null and !l.current_host);
    try t.expectEqualStrings("/", l.path);
}

test "formatSpec round-trips through parseSpec" {
    const t = std.testing;
    var buf: [SPEC_BUF_LEN]u8 = undefined;

    try t.expectEqualStrings("local:/etc", formatSpec(&buf, null, "/etc"));
    try t.expectEqualStrings("nas:/srv/data", formatSpec(&buf, "nas", "/srv/data"));
    try t.expectEqualStrings("udp:box:/p", formatSpec(&buf, "udp:box", "/p"));
    try t.expectEqualStrings("nas:/", formatSpec(&buf, "nas", ""));

    // The spec a browser tab hands out must parse back to the same
    // (host, path) with no dependence on a "current" host.
    const local = parseSpec(formatSpec(&buf, null, "/etc"));
    try t.expect(local.host == null and !local.current_host);
    try t.expectEqualStrings("/etc", local.path);
    const remote = parseSpec(formatSpec(&buf, "user@box", "/home/x"));
    try t.expectEqualStrings("user@box", remote.host.?);
    try t.expectEqualStrings("/home/x", remote.path);
}

test "formatSpec results in separate buffers do not alias" {
    const t = std.testing;
    // The regression: both specs used to be written into one
    // BrowserView-owned scratch buffer, so the first result was
    // silently rewritten by the second.
    var a_buf: [SPEC_BUF_LEN]u8 = undefined;
    var b_buf: [SPEC_BUF_LEN]u8 = undefined;
    const a = formatSpec(&a_buf, "nas", "/srv/data");
    const b = formatSpec(&b_buf, null, "/etc");
    try t.expectEqualStrings("nas:/srv/data", a);
    try t.expectEqualStrings("local:/etc", b);
}

test "formatSpec falls back to the bare path when the buffer is too small" {
    const t = std.testing;
    var tiny: [4]u8 = undefined;
    // Not a slice of `tiny` - documented in formatSpec's docblock.
    try t.expectEqualStrings("/srv/data", formatSpec(&tiny, "nas", "/srv/data"));
}

test "completionMatches skips dotfiles and matches case-insensitively" {
    const t = std.testing;
    try t.expect(completionMatches("Downloads", "dow"));
    try t.expect(completionMatches("downloads", "Dow"));
    try t.expect(completionMatches("downloads", ""));
    try t.expect(!completionMatches(".config", ""));
    try t.expect(!completionMatches(".config", ".co"));
    try t.expect(!completionMatches("doc", "docs"));
    try t.expect(!completionMatches("etc", "us"));
}

test "isWorkerImageName excludes what gdk-pixbuf may not decode" {
    const t = std.testing;
    // The worker set is a strict subset: these decode everywhere.
    try t.expect(isWorkerImageName("a.PNG"));
    try t.expect(isWorkerImageName("a.svg"));
    // ...while these are preview-only (loader may be missing).
    try t.expect(isImageName("a.avif") and !isWorkerImageName("a.avif"));
    try t.expect(isImageName("a.heic") and !isWorkerImageName("a.heic"));
}

test "isArchivePath matches multi-part suffixes case-insensitively" {
    const t = std.testing;
    try t.expect(isArchivePath("/x/a.TAR.GZ"));
    try t.expect(isArchivePath("/x/a.tbz2"));
    try t.expect(isArchivePath("a.7z"));
    try t.expect(!isArchivePath("/x/a.tar.zst"));
    try t.expect(!isArchivePath("/x/zip"));
}

test "hostEq treats null as local and compares strings otherwise" {
    const t = std.testing;
    try t.expect(hostEq(null, null));
    try t.expect(!hostEq(null, "box"));
    try t.expect(!hostEq("box", null));
    try t.expect(hostEq("user@box", "user@box"));
    try t.expect(!hostEq("user@box", "box"));
}

test "unescapeMnt decodes /proc/mounts octal escapes" {
    const t = std.testing;
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("/mnt/my disk", unescapeMnt(&buf, "/mnt/my\\040disk"));
    try t.expectEqualStrings("/mnt/a\tb", unescapeMnt(&buf, "/mnt/a\\011b"));
    // A backslash that is not a complete octal triple stays literal.
    try t.expectEqualStrings("/mnt/a\\zz", unescapeMnt(&buf, "/mnt/a\\zz"));
    // Output is capped by the destination buffer.
    var small: [4]u8 = undefined;
    try t.expectEqualStrings("/mnt", unescapeMnt(&small, "/mnt/x"));
}

test "urlUnescape decodes trashinfo Path values" {
    const t = std.testing;
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("/home/x/a b.txt", urlUnescape("/home/x/a%20b.txt", &buf).?);
    try t.expectEqualStrings("100%", urlUnescape("100%25", &buf).?);
    // A malformed escape is copied through byte by byte.
    try t.expectEqualStrings("a%zz", urlUnescape("a%zz", &buf).?);
    // Overflowing the destination is an error, not a truncation.
    var small: [3]u8 = undefined;
    try t.expect(urlUnescape("abcd", &small) == null);
}

test "isTrashPath recognizes home and topdir trash" {
    const t = std.testing;
    try t.expect(isTrashPath("/home/x/.local/share/Trash/files/a"));
    try t.expect(isTrashPath("/mnt/data/.Trash-1000/files/a"));
    try t.expect(!isTrashPath("/mnt/data/.Trash-1000/info/a.trashinfo"));
    try t.expect(!isTrashPath("/home/x/Documents/a"));
}

test "millerNextSegment walks one level down toward the root" {
    const t = std.testing;
    try t.expectEqualStrings("b", millerNextSegment("/a", "/a/b/c").?);
    try t.expectEqualStrings("b", millerNextSegment("/a", "/a/b").?);
    try t.expectEqualStrings("a", millerNextSegment("/", "/a/b").?);
    // The root itself has no next segment, and an unrelated ancestor
    // must not produce one.
    try t.expect(millerNextSegment("/a", "/a") == null);
    try t.expect(millerNextSegment("/z", "/a/b") == null);
}

test "uniqueName suffixes until the target listing has room" {
    const t = std.testing;
    const Taken = struct {
        names: []const []const u8,
        fn contains(self: @This(), name: []const u8) bool {
            for (self.names) |n| if (std.mem.eql(u8, n, name)) return true;
            return false;
        }
    };
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("a-copy", uniqueName("a", &buf, Taken{ .names = &.{} }).?);
    try t.expectEqualStrings("a-copy2", uniqueName("a", &buf, Taken{ .names = &.{"a-copy"} }).?);
    try t.expectEqualStrings("a-copy4", uniqueName("a", &buf, Taken{
        .names = &.{ "a-copy", "a-copy2", "a-copy3" },
    }).?);
    // Too small a buffer is a refusal, never a truncated name.
    var small: [4]u8 = undefined;
    try t.expect(uniqueName("abc", &small, Taken{ .names = &.{} }) == null);
}
