//! Mount bypass decisions: when a local path under an sshfs/NFS mount
//! may be browsed through the source host's own daemon instead.
//!
//! The mount table only says WHERE the bytes come from. Rerouting is
//! a change of authority (host-side jobs, that host's trash, that
//! host's daemon's view of the files), so it is earned in three
//! steps, all decided here and merely plumbed by the GTK side:
//! 1. `resolve`: which host string to dial. The mount source ("box",
//!    "user@box:/srv") is always a candidate; every host the browser
//!    already talks to that names the same machine is another, and
//!    more than one DISTINCT candidate is ambiguous -- the user picks
//!    once and the answer is remembered per mount source.
//! 2. `sameFile`: the mount's view and the host's view of the same
//!    path must agree before anything is rerouted; a stale mount, a
//!    wrong alias or a different export tree fails this and the tab
//!    stays on the plain mount.
//! 3. An unreachable host is the same outcome as a mismatch: the
//!    mount path keeps working, the reroute simply never happens.

const std = @import("std");

/// What both sides report about one path. `mtime_ms` is compared to
/// the second: sshfs and NFS truncate or round sub-second timestamps.
pub const Identity = struct {
    kind: []const u8,
    size: u64,
    mtime_ms: i64,
};

/// The mount's and the host's stat agree on kind, mtime (seconds)
/// and, for a regular file, size. Directories skip the size: the
/// reported size of a directory is filesystem-specific.
pub fn sameFile(mount: Identity, host: Identity) bool {
    if (!std.mem.eql(u8, mount.kind, host.kind)) return false;
    if (@divFloor(mount.mtime_ms, 1000) != @divFloor(host.mtime_ms, 1000)) return false;
    if (std.mem.eql(u8, mount.kind, "file") and mount.size != host.size) return false;
    return true;
}

/// The machine a host string names: transport prefix and user
/// stripped, so `ssh:me@box`, `udp:box` and `box` are one machine.
pub fn bareHost(host: []const u8) []const u8 {
    var h = host;
    for ([_][]const u8{ "ssh:", "udp:", "tor:" }) |prefix| {
        if (std.mem.startsWith(u8, h, prefix)) {
            h = h[prefix.len..];
            break;
        }
    }
    if (std.mem.lastIndexOfScalar(u8, h, '@')) |at| h = h[at + 1 ..];
    return h;
}

/// Cap on distinct candidates offered; a machine reachable under more
/// aliases than this is a configuration, not a choice.
pub const MAX_CANDIDATES = 8;

pub const Resolution = union(enum) {
    /// One host string to dial (the remembered answer, the only
    /// candidate, or the source itself when nothing else matches).
    host: []const u8,
    /// Several distinct host strings name the machine; `candidates`
    /// borrows from the inputs, source first.
    ambiguous: []const []const u8,
};

/// Decide which host string reaches the mount's source machine.
/// `known` are host strings the browser already has connections or
/// tabs on; `remembered` is the stored answer for this source, which
/// wins outright. `out` receives the candidate list on ambiguity.
pub fn resolve(source: []const u8, known: []const []const u8, remembered: ?[]const u8, out: *[MAX_CANDIDATES][]const u8) Resolution {
    if (remembered) |r| if (r.len > 0) return .{ .host = r };
    var n: usize = 0;
    out[n] = source;
    n += 1;
    const machine = bareHost(source);
    for (known) |k| {
        if (k.len == 0 or !std.mem.eql(u8, bareHost(k), machine)) continue;
        const dup = for (out[0..n]) |seen| {
            if (std.mem.eql(u8, seen, k)) break true;
        } else false;
        if (dup) continue;
        if (n == MAX_CANDIDATES) break;
        out[n] = k;
        n += 1;
    }
    if (n == 1) return .{ .host = out[0] };
    return .{ .ambiguous = out[0..n] };
}

/// The mount-relative tail of `local_path` under `mountpoint`, as the
/// path on the host: `root` is the exported directory the mount was
/// made from. "/" roots and "/" mountpoints do not double a slash.
pub fn hostPath(buf: []u8, mountpoint: []const u8, root: []const u8, local_path: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, local_path, mountpoint)) return null;
    var rest = local_path[mountpoint.len..];
    if (rest.len > 0 and rest[0] != '/') {
        if (mountpoint.len != 1) return null;
        // A "/" mountpoint: the whole path is the tail.
        rest = local_path;
    }
    const base = if (std.mem.eql(u8, root, "/")) "" else std.mem.trimEnd(u8, root, "/");
    const joined = std.fmt.bufPrint(buf, "{s}{s}", .{ base, rest }) catch return null;
    return if (joined.len == 0) "/" else joined;
}

/// The inverse of `hostPath`: where a host path under `root` shows
/// through the mount, for falling back when the host goes away.
pub fn mountPath(buf: []u8, mountpoint: []const u8, root: []const u8, host_path: []const u8) ?[]const u8 {
    const base = if (std.mem.eql(u8, root, "/")) "" else std.mem.trimEnd(u8, root, "/");
    if (!std.mem.startsWith(u8, host_path, base)) return null;
    const rest = host_path[base.len..];
    if (rest.len > 0 and rest[0] != '/') return null;
    const mp = if (std.mem.eql(u8, mountpoint, "/")) "" else std.mem.trimEnd(u8, mountpoint, "/");
    const joined = std.fmt.bufPrint(buf, "{s}{s}", .{ mp, rest }) catch return null;
    return if (joined.len == 0) "/" else joined;
}

/// Whether `host_path` on `host` still lies inside a bypassed mount's
/// export: the badge shows, and the fallback applies, only there.
pub fn within(host: ?[]const u8, host_path: []const u8, link_host: []const u8, root: []const u8) bool {
    const h = host orelse return false;
    if (!std.mem.eql(u8, h, link_host)) return false;
    const base = if (std.mem.eql(u8, root, "/")) "" else std.mem.trimEnd(u8, root, "/");
    if (!std.mem.startsWith(u8, host_path, base)) return false;
    return host_path.len == base.len or host_path[base.len] == '/';
}

test "sameFile agrees to the second and sizes only regular files" {
    const t = std.testing;
    try t.expect(sameFile(.{ .kind = "file", .size = 10, .mtime_ms = 1_000_400 }, .{ .kind = "file", .size = 10, .mtime_ms = 1_000_900 }));
    try t.expect(!sameFile(.{ .kind = "file", .size = 10, .mtime_ms = 1_000_400 }, .{ .kind = "file", .size = 11, .mtime_ms = 1_000_400 }));
    try t.expect(!sameFile(.{ .kind = "file", .size = 10, .mtime_ms = 1_000_400 }, .{ .kind = "file", .size = 10, .mtime_ms = 2_000_400 }));
    try t.expect(sameFile(.{ .kind = "dir", .size = 4096, .mtime_ms = 5_000 }, .{ .kind = "dir", .size = 12, .mtime_ms = 5_999 }));
    try t.expect(!sameFile(.{ .kind = "dir", .size = 1, .mtime_ms = 5_000 }, .{ .kind = "file", .size = 1, .mtime_ms = 5_000 }));
}

test "resolve: the source alone, a remembered answer, and distinct aliases" {
    const t = std.testing;
    var out: [MAX_CANDIDATES][]const u8 = undefined;
    switch (resolve("box", &.{ "other", "" }, null, &out)) {
        .host => |h| try t.expectEqualStrings("box", h),
        .ambiguous => return error.TestUnexpectedResult,
    }
    switch (resolve("me@box", &.{ "udp:box", "me@box", "ssh:box" }, null, &out)) {
        .host => return error.TestUnexpectedResult,
        .ambiguous => |list| {
            try t.expectEqual(@as(usize, 3), list.len);
            try t.expectEqualStrings("me@box", list[0]);
            try t.expectEqualStrings("udp:box", list[1]);
            try t.expectEqualStrings("ssh:box", list[2]);
        },
    }
    switch (resolve("me@box", &.{ "udp:box", "ssh:box" }, "udp:box", &out)) {
        .host => |h| try t.expectEqualStrings("udp:box", h),
        .ambiguous => return error.TestUnexpectedResult,
    }
    try t.expectEqualStrings("box", bareHost("ssh:me@box"));
    try t.expectEqualStrings("10.0.0.5", bareHost("udp:10.0.0.5"));
}

test "hostPath and mountPath round-trip under every root shape" {
    const t = std.testing;
    var buf: [4096]u8 = undefined;
    try t.expectEqualStrings("/srv/data/x", hostPath(&buf, "/mnt/box", "/srv/data", "/mnt/box/x").?);
    try t.expectEqualStrings("/srv/data", hostPath(&buf, "/mnt/box", "/srv/data", "/mnt/box").?);
    try t.expectEqualStrings("/x", hostPath(&buf, "/mnt/box", "/", "/mnt/box/x").?);
    try t.expectEqualStrings("/", hostPath(&buf, "/mnt/box", "/", "/mnt/box").?);
    try t.expect(hostPath(&buf, "/mnt/box", "/srv", "/mnt/boxy/x") == null);
    var back: [4096]u8 = undefined;
    try t.expectEqualStrings("/mnt/box/x", mountPath(&back, "/mnt/box", "/srv/data", "/srv/data/x").?);
    try t.expectEqualStrings("/mnt/box", mountPath(&back, "/mnt/box", "/srv/data", "/srv/data").?);
    try t.expectEqualStrings("/mnt/box/x", mountPath(&back, "/mnt/box", "/", "/x").?);
    try t.expect(mountPath(&back, "/mnt/box", "/srv/data", "/srv/dataset") == null);
    try t.expect(within("box", "/srv/data/x", "box", "/srv/data"));
    try t.expect(!within("box", "/srv/dataset", "box", "/srv/data"));
    try t.expect(!within(null, "/srv/data", "box", "/srv/data"));
}
