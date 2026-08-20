//! This machine's mount table: one reader, two consumers.
//!
//! `forEach` walks the platform's mount list -- `/proc/self/mounts` on
//! Linux, `getmntinfo()` on macOS, which has no /proc at all. `detect`
//! (direct mux bypass: which sshfs/nfs mount holds this path) and the
//! file browser's Devices sidebar both go through it. They had grown
//! SEPARATE readers, and the sidebar's was Linux-only -- so on a Mac
//! it opened /proc, got null, returned, and the whole section
//! rendered as nothing at all.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("../c.zig").c;

pub const Hit = struct {
    host_buf: [256]u8 = undefined,
    host_len: usize = 0,
    path_buf: [4096]u8 = undefined,
    path_len: usize = 0,
    mount_buf: [1024]u8 = undefined,
    mount_len: usize = 0,

    pub fn host(self: *const Hit) []const u8 { return self.host_buf[0..self.host_len]; }
    pub fn path(self: *const Hit) []const u8 { return self.path_buf[0..self.path_len]; }
    pub fn mountpoint(self: *const Hit) []const u8 { return self.mount_buf[0..self.mount_len]; }
};

/// One mount, as the platform reports it. The slices point into the
/// walker's own scratch and are valid ONLY for the duration of the
/// `visit` call -- copy anything that must outlive it.
pub const Entry = struct {
    source: []const u8,
    mountpoint: []const u8,
    fstype: []const u8,
    /// The system's own answer to "should a file manager show this?"
    /// (macOS MNT_DONTBROWSE). Always false where the platform has no
    /// such concept: a filter that treats it as "hide" therefore hides
    /// nothing extra on Linux.
    dont_browse: bool = false,
};

/// Walk this machine's mount table, passing each entry to
/// `ctx.visit(Entry)`. Visiting stops early when `visit` returns false
/// (the Devices sidebar stops at its row budget). Reading the table is
/// best-effort: an unreadable one yields no entries rather than an
/// error, because every caller's answer to "no mounts" and "cannot
/// tell" is the same.
pub fn forEach(ctx: anytype) void {
    if (comptime builtin.os.tag == .macos) {
        var list: [*c]c.struct_statfs = null;
        const count = c.getmntinfo(&list, c.MNT_NOWAIT);
        if (count <= 0 or list == null) return;
        var i: usize = 0;
        while (i < @as(usize, @intCast(count))) : (i += 1) {
            const rec = &list[i];
            if (!ctx.visit(.{
                .source = std.mem.span(@as([*:0]const u8, @ptrCast(&rec.f_mntfromname))),
                .mountpoint = std.mem.span(@as([*:0]const u8, @ptrCast(&rec.f_mntonname))),
                .fstype = std.mem.span(@as([*:0]const u8, @ptrCast(&rec.f_fstypename))),
                .dont_browse = rec.f_flags & @as(u32, @intCast(c.MNT_DONTBROWSE)) != 0,
            })) return;
        }
        return;
    }
    const f = c.fopen("/proc/self/mounts", "r") orelse c.fopen("/proc/mounts", "r") orelse return;
    defer _ = c.fclose(f);
    var line: [4096]u8 = undefined;
    while (c.fgets(&line, line.len, f) != null) {
        const text = std.mem.sliceTo(std.mem.span(@as([*:0]const u8, @ptrCast(&line))), '\n');
        var it = std.mem.tokenizeScalar(u8, text, ' ');
        const src_raw = it.next() orelse continue;
        const mp_raw = it.next() orelse continue;
        const fs = it.next() orelse continue;
        // /proc/mounts octal-escapes spaces and tabs in both names;
        // decoding here is what stops each consumer inventing its own
        // answer (the sidebar simply showed them raw).
        var sb: [1024]u8 = undefined;
        var mb: [1024]u8 = undefined;
        if (!ctx.visit(.{
            .source = unescape(&sb, src_raw),
            .mountpoint = unescape(&mb, mp_raw),
            .fstype = fs,
        })) return;
    }
}

fn unescape(buf: []u8, src: []const u8) []const u8 {
    var w: usize = 0;
    var r: usize = 0;
    while (r < src.len and w < buf.len) {
        if (src[r] == '\\' and r + 3 < src.len) {
            const v = std.fmt.parseInt(u8, src[r + 1 .. r + 4], 8) catch {
                buf[w] = src[r]; w += 1; r += 1; continue;
            };
            buf[w] = v; w += 1; r += 4;
        } else {
            buf[w] = src[r]; w += 1; r += 1;
        }
    }
    return buf[0..w];
}

fn splitSource(source: []const u8) ?struct { host: []const u8, root: []const u8 } {
    if (source.len == 0) return null;
    if (source[0] == '[') {
        const close = std.mem.indexOfScalar(u8, source, ']') orelse return null;
        if (close + 1 >= source.len or source[close + 1] != ':') return null;
        return .{ .host = source[1..close], .root = source[close + 2 ..] };
    }
    const colon = std.mem.lastIndexOfScalar(u8, source, ':') orelse return null;
    if (colon == 0) return null;
    return .{ .host = source[0..colon], .root = source[colon + 1 ..] };
}

fn consider(path: []const u8, source: []const u8, mountpoint: []const u8, out: *Hit, best: *usize) void {
    if (mountpoint.len == 0 or mountpoint.len > path.len or mountpoint.len <= best.*) return;
    if (!std.mem.startsWith(u8, path, mountpoint)) return;
    if (mountpoint.len > 1 and path.len > mountpoint.len and path[mountpoint.len] != '/') return;
    const parsed = splitSource(source) orelse return;
    if (parsed.host.len == 0 or parsed.host.len > out.host_buf.len) return;
    const root = if (parsed.root.len == 0) "/" else parsed.root;
    var rest = path[mountpoint.len..];
    if (mountpoint.len == 1 and rest.len > 0 and rest[0] != '/') {
        var temp: [4096]u8 = undefined;
        temp[0] = '/';
        if (rest.len + 1 > temp.len) return;
        @memcpy(temp[1 .. rest.len + 1], rest);
        rest = temp[0 .. rest.len + 1];
        var w = std.Io.Writer.fixed(&out.path_buf);
        w.print("{s}{s}", .{ if (std.mem.eql(u8, root, "/")) "" else root, rest }) catch return;
        out.path_len = w.buffered().len;
    } else {
        var w = std.Io.Writer.fixed(&out.path_buf);
        w.print("{s}{s}", .{ if (std.mem.eql(u8, root, "/") and rest.len > 0) "" else root, rest }) catch return;
        if (w.buffered().len == 0) w.writeByte('/') catch return;
        out.path_len = w.buffered().len;
    }
    @memcpy(out.host_buf[0..parsed.host.len], parsed.host);
    out.host_len = parsed.host.len;
    const mn = @min(mountpoint.len, out.mount_buf.len);
    @memcpy(out.mount_buf[0..mn], mountpoint[0..mn]);
    out.mount_len = mn;
    best.* = mountpoint.len;
}

/// The sshfs/nfs mount that holds `path`, if any: the direct mux
/// bypass asks so it can talk to that host's daemon instead of
/// pushing bytes through the mount.
pub fn detect(path: []const u8, out: *Hit) bool {
    var walk: DetectWalk = .{ .path = path, .out = out };
    forEach(&walk);
    return walk.best > 0;
}

const DetectWalk = struct {
    path: []const u8,
    out: *Hit,
    best: usize = 0,

    fn visit(self: *DetectWalk, e: Entry) bool {
        // A remote mount is what this is for. macOS names the host in
        // the source (`box:/srv`) for every network filesystem, so the
        // colon carries the test there; Linux types them explicitly.
        const remote = if (comptime builtin.os.tag == .macos)
            std.mem.eql(u8, e.fstype, "nfs") or std.mem.indexOf(u8, e.source, ":") != null
        else
            std.mem.eql(u8, e.fstype, "fuse.sshfs") or std.mem.startsWith(u8, e.fstype, "nfs");
        if (remote) consider(self.path, e.source, e.mountpoint, self.out, &self.best);
        return true;
    }
};

test "mount source parsing handles ssh, bracketed IPv6, and root mapping" {
    const a = splitSource("user@box:/srv").?;
    try std.testing.expectEqualStrings("user@box", a.host);
    try std.testing.expectEqualStrings("/srv", a.root);
    const b = splitSource("[2001:db8::1]:/data").?;
    try std.testing.expectEqualStrings("2001:db8::1", b.host);
    var hit: Hit = .{};
    var best: usize = 0;
    consider("/home/me", "box:/", "/", &hit, &best);
    try std.testing.expectEqualStrings("/home/me", hit.path());
}
