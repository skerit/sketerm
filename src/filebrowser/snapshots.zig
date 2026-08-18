//! GTK-free btrfs-snapshot version logic for the Properties dialog:
//! candidate-path mapping for the Timeshift, snapper and plain
//! snapshot-directory layouts, the ancestor `.snapshots` walk,
//! newest-first ordering, and the identical-run dedupe.

const std = @import("std");

/// Where Timeshift mounts its btrfs snapshot set.
pub const TIMESHIFT_ROOT = "/run/timeshift/backup/timeshift-btrfs/snapshots";
/// The per-subvolume snapshot directory name probed on every ancestor
/// of the file (snapper configs and most hand-rolled setups use it).
pub const SNAPDIR_NAME = ".snapshots";

/// Stat-storm cap: only the newest snapshots are probed.
pub const MAX_SNAPSHOTS = 64;

/// How a snapshot maps the file to its versioned copy. Timeshift
/// roots the system subvolume under `localhost/` or `@/`; snapper
/// numbers its snapshots and nests the tree under `snapshot/`; plain
/// covers btrbk-style and hand-rolled directories whose entries ARE
/// the snapshot roots.
pub const Layout = enum { timeshift_localhost, timeshift_at, snapper, plain };

/// The mapping used for one entry of an ancestor snapshot directory:
/// numeric names are snapper snapshots (`N/snapshot/...`), anything
/// else is a plain snapshot root.
pub fn snapdirNameLayout(name: []const u8) Layout {
    return if (isSnapperName(name)) .snapper else .plain;
}

/// The directory whose existence proves which Timeshift sub-layout a
/// snapshot uses (`localhost/` vs `@/`).
pub fn timeshiftProbe(buf: []u8, name: []const u8, at: bool) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}/{s}", .{
        TIMESHIFT_ROOT, name, if (at) "@" else "localhost",
    }) catch null;
}

/// The versioned copy of the file inside snapshot `name` of the
/// listed directory `list_root`, or null when it does not fit `buf`.
/// `rel` is the file's path relative to the subvolume the snapshots
/// cover and must start with '/' (for Timeshift that is the absolute
/// path; for an ancestor snapdir it is the remainder past the
/// ancestor).
pub fn versionPath(buf: []u8, layout: Layout, list_root: []const u8, name: []const u8, rel: []const u8) ?[]const u8 {
    if (rel.len == 0 or rel[0] != '/') return null;
    return switch (layout) {
        .timeshift_localhost => std.fmt.bufPrint(buf, "{s}/{s}/localhost{s}", .{ list_root, name, rel }),
        .timeshift_at => std.fmt.bufPrint(buf, "{s}/{s}/@{s}", .{ list_root, name, rel }),
        .snapper => std.fmt.bufPrint(buf, "{s}/{s}/snapshot{s}", .{ list_root, name, rel }),
        .plain => std.fmt.bufPrint(buf, "{s}/{s}{s}", .{ list_root, name, rel }),
    } catch null;
}

/// Walks the file's ancestor directories nearest-first, yielding each
/// `<ancestor>/.snapshots` candidate with the file's path relative to
/// that ancestor. snapper is per-subvolume (a "home" config lives at
/// /home/.snapshots, not /.snapshots), so probing only the root
/// misses every non-root config.
pub const SnapdirIter = struct {
    file_path: []const u8,
    /// Byte length of the current ancestor prefix; 0 is the root.
    dir_len: usize,
    done: bool = false,

    /// @return null unless `file_path` is absolute with a parent.
    pub fn init(file_path: []const u8) ?SnapdirIter {
        if (file_path.len < 2 or file_path[0] != '/') return null;
        const cut = std.mem.lastIndexOfScalar(u8, file_path, '/') orelse return null;
        return .{ .file_path = file_path, .dir_len = cut };
    }

    pub const Probe = struct {
        /// The candidate snapshot directory (borrowed from `buf`).
        snapdir: []const u8,
        /// The file's path relative to the ancestor, starting with '/'.
        rel: []const u8,
    };

    pub fn next(self: *SnapdirIter, buf: []u8) ?Probe {
        if (self.done) return null;
        const dir = self.file_path[0..self.dir_len];
        const snapdir = std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, SNAPDIR_NAME }) catch {
            self.done = true;
            return null;
        };
        const rel = self.file_path[self.dir_len..];
        if (self.dir_len == 0) {
            self.done = true;
        } else {
            self.dir_len = std.mem.lastIndexOfScalar(u8, self.file_path[0..self.dir_len], '/') orelse 0;
        }
        return .{ .snapdir = snapdir, .rel = rel };
    }
};

/// snapper snapshots are plain numbers; anything else is treated as a
/// plain snapshot root by `snapdirNameLayout`.
pub fn isSnapperName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |ch| {
        if (!std.ascii.isDigit(ch)) return false;
    }
    return true;
}

/// Order snapshot names newest first: numeric names compare
/// numerically (snapper), everything else lexicographically
/// (Timeshift's `YYYY-MM-DD_HH-MM-SS` stamps and btrbk-style
/// `name.20260818T1200` both order that way). Families are ordered
/// non-numeric-first so the comparison stays a strict weak order in
/// a mixed directory.
pub fn sortNewestFirst(names: [][]u8) void {
    std.mem.sort([]u8, names, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            const an = isSnapperName(a);
            const bn = isSnapperName(b);
            if (an != bn) return bn;
            if (an) {
                const na = std.fmt.parseInt(u64, a, 10) catch 0;
                const nb = std.fmt.parseInt(u64, b, 10) catch 0;
                if (na != nb) return na > nb;
            }
            return std.mem.order(u8, a, b) == .gt;
        }
    }.lt);
}

/// One surviving version of the file: which snapshot (index into the
/// caller's newest-first name list) plus the stat identity.
pub const Version = struct {
    snap: usize,
    size: u64,
    mtime_ms: i64,
};

/// Collapse runs of consecutive identical versions (same size and
/// mtime) in a NEWEST-FIRST list, keeping the OLDEST of each run.
/// Compacts in place.
/// @return the new length.
pub fn dedupeNewestFirst(items: []Version) usize {
    var out: usize = 0;
    for (items, 0..) |v, i| {
        if (i + 1 < items.len and
            items[i + 1].size == v.size and
            items[i + 1].mtime_ms == v.mtime_ms) continue;
        items[out] = v;
        out += 1;
    }
    return out;
}

/// "Restore a Copy" destination: the original full path with the
/// version date appended, so the original is never overwritten.
pub fn restoreCopyPath(buf: []u8, file_path: []const u8, date: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s} (from {s})", .{ file_path, date }) catch null;
}

test "versionPath maps every layout and refuses relative paths" {
    const t = std.testing;
    var buf: [512]u8 = undefined;
    try t.expectEqualStrings(
        "/run/timeshift/backup/timeshift-btrfs/snapshots/2026-07-28_20-00-01/localhost/home/u/a.txt",
        versionPath(&buf, .timeshift_localhost, TIMESHIFT_ROOT, "2026-07-28_20-00-01", "/home/u/a.txt").?,
    );
    try t.expectEqualStrings(
        "/run/timeshift/backup/timeshift-btrfs/snapshots/2026-07-28_20-00-01/@/home/u/a.txt",
        versionPath(&buf, .timeshift_at, TIMESHIFT_ROOT, "2026-07-28_20-00-01", "/home/u/a.txt").?,
    );
    try t.expectEqualStrings(
        "/.snapshots/42/snapshot/etc/fstab",
        versionPath(&buf, .snapper, "/.snapshots", "42", "/etc/fstab").?,
    );
    try t.expectEqualStrings(
        "/home/.snapshots/42/snapshot/u/a.txt",
        versionPath(&buf, .snapper, "/home/.snapshots", "42", "/u/a.txt").?,
    );
    try t.expectEqualStrings(
        "/home/.snapshots/home.20260818T1200/u/a.txt",
        versionPath(&buf, .plain, "/home/.snapshots", "home.20260818T1200", "/u/a.txt").?,
    );
    try t.expect(versionPath(&buf, .snapper, "/.snapshots", "42", "relative") == null);
    try t.expect(versionPath(&buf, .snapper, "/.snapshots", "42", "") == null);
    var tiny: [8]u8 = undefined;
    try t.expect(versionPath(&tiny, .snapper, "/.snapshots", "42", "/etc/fstab") == null);
}

test "timeshiftProbe names the sub-layout directory" {
    const t = std.testing;
    var buf: [256]u8 = undefined;
    try t.expectEqualStrings(
        "/run/timeshift/backup/timeshift-btrfs/snapshots/s1/localhost",
        timeshiftProbe(&buf, "s1", false).?,
    );
    try t.expectEqualStrings(
        "/run/timeshift/backup/timeshift-btrfs/snapshots/s1/@",
        timeshiftProbe(&buf, "s1", true).?,
    );
}

test "SnapdirIter walks ancestors nearest-first down to the root" {
    const t = std.testing;
    var buf: [256]u8 = undefined;

    var it = SnapdirIter.init("/home/u/docs/a.txt").?;
    var p = it.next(&buf).?;
    try t.expectEqualStrings("/home/u/docs/.snapshots", p.snapdir);
    try t.expectEqualStrings("/a.txt", p.rel);
    p = it.next(&buf).?;
    try t.expectEqualStrings("/home/u/.snapshots", p.snapdir);
    try t.expectEqualStrings("/docs/a.txt", p.rel);
    p = it.next(&buf).?;
    try t.expectEqualStrings("/home/.snapshots", p.snapdir);
    try t.expectEqualStrings("/u/docs/a.txt", p.rel);
    p = it.next(&buf).?;
    try t.expectEqualStrings("/.snapshots", p.snapdir);
    try t.expectEqualStrings("/home/u/docs/a.txt", p.rel);
    try t.expect(it.next(&buf) == null);

    // A file directly under the root only probes /.snapshots.
    var top = SnapdirIter.init("/a.txt").?;
    const only = top.next(&buf).?;
    try t.expectEqualStrings("/.snapshots", only.snapdir);
    try t.expectEqualStrings("/a.txt", only.rel);
    try t.expect(top.next(&buf) == null);

    // Relative paths and the root itself have no ancestors.
    try t.expect(SnapdirIter.init("relative") == null);
    try t.expect(SnapdirIter.init("/") == null);
}

test "snapdirNameLayout routes numeric names to snapper, others to plain" {
    const t = std.testing;
    try t.expect(snapdirNameLayout("7") == .snapper);
    try t.expect(snapdirNameLayout("123") == .snapper);
    try t.expect(snapdirNameLayout("home.20260818T1200") == .plain);
    try t.expect(snapdirNameLayout("grub-snapshot") == .plain);
}

test "isSnapperName accepts only plain numbers" {
    const t = std.testing;
    try t.expect(isSnapperName("7"));
    try t.expect(isSnapperName("123"));
    try t.expect(!isSnapperName(""));
    try t.expect(!isSnapperName("7a"));
    try t.expect(!isSnapperName("grub-snapshot"));
}

test "sortNewestFirst orders snapper numerically and stamps lexically" {
    const t = std.testing;
    var a1 = "9".*;
    var a2 = "10".*;
    var a3 = "2".*;
    var nums = [_][]u8{ &a1, &a2, &a3 };
    sortNewestFirst(&nums);
    try t.expectEqualStrings("10", nums[0]);
    try t.expectEqualStrings("9", nums[1]);
    try t.expectEqualStrings("2", nums[2]);

    var b1 = "2026-07-28_20-00-01".*;
    var b2 = "2026-07-30_08-00-00".*;
    var b3 = "2025-12-31_23-59-59".*;
    var stamps = [_][]u8{ &b1, &b2, &b3 };
    sortNewestFirst(&stamps);
    try t.expectEqualStrings("2026-07-30_08-00-00", stamps[0]);
    try t.expectEqualStrings("2026-07-28_20-00-01", stamps[1]);
    try t.expectEqualStrings("2025-12-31_23-59-59", stamps[2]);

    // A mixed directory keeps a stable lexicographic order between
    // the two families instead of misparsing the stamps as numbers.
    var m1 = "12".*;
    var m2 = "home.20260818T1200".*;
    var m3 = "9".*;
    var mixed = [_][]u8{ &m1, &m2, &m3 };
    sortNewestFirst(&mixed);
    try t.expectEqualStrings("home.20260818T1200", mixed[0]);
    try t.expectEqualStrings("12", mixed[1]);
    try t.expectEqualStrings("9", mixed[2]);
}

test "dedupeNewestFirst keeps the OLDEST of each identical run" {
    const t = std.testing;
    // Newest first: snaps 0..4. 0 and 1 identical, 2 differs,
    // 3 and 4 identical again.
    var items = [_]Version{
        .{ .snap = 0, .size = 100, .mtime_ms = 5000 },
        .{ .snap = 1, .size = 100, .mtime_ms = 5000 },
        .{ .snap = 2, .size = 90, .mtime_ms = 4000 },
        .{ .snap = 3, .size = 90, .mtime_ms = 3000 },
        .{ .snap = 4, .size = 90, .mtime_ms = 3000 },
    };
    const n = dedupeNewestFirst(&items);
    try t.expectEqual(@as(usize, 3), n);
    try t.expectEqual(@as(usize, 1), items[0].snap);
    try t.expectEqual(@as(usize, 2), items[1].snap);
    try t.expectEqual(@as(usize, 4), items[2].snap);

    // A single version always survives; an empty list stays empty.
    var one = [_]Version{.{ .snap = 0, .size = 1, .mtime_ms = 1 }};
    try t.expectEqual(@as(usize, 1), dedupeNewestFirst(&one));
    var empty = [_]Version{};
    try t.expectEqual(@as(usize, 0), dedupeNewestFirst(&empty));
}

test "restoreCopyPath appends the version date to the full path" {
    const t = std.testing;
    var buf: [256]u8 = undefined;
    try t.expectEqualStrings(
        "/home/u/report.pdf (from 2026-07-28)",
        restoreCopyPath(&buf, "/home/u/report.pdf", "2026-07-28").?,
    );
    var tiny: [4]u8 = undefined;
    try t.expect(restoreCopyPath(&tiny, "/home/u/report.pdf", "2026-07-28") == null);
}
