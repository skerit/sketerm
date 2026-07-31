//! GTK-free btrfs-snapshot version logic for the Properties dialog:
//! candidate-path mapping for the Timeshift and snapper layouts,
//! newest-first snapshot ordering, and the identical-run dedupe.

const std = @import("std");

/// Where Timeshift mounts its btrfs snapshot set.
pub const TIMESHIFT_ROOT = "/run/timeshift/backup/timeshift-btrfs/snapshots";
/// snapper's in-place snapshot directory.
pub const SNAPPER_ROOT = "/.snapshots";

/// Stat-storm cap: only the newest snapshots are probed.
pub const MAX_SNAPSHOTS = 64;

/// How a snapshot maps an original absolute path to its versioned
/// copy. Timeshift roots the system subvolume under either
/// `localhost/` or `@/` depending on the setup, so both are layouts.
pub const Layout = enum { timeshift_localhost, timeshift_at, snapper };

/// The directory listed to discover snapshot names for `layout`.
pub fn listRoot(layout: Layout) []const u8 {
    return switch (layout) {
        .timeshift_localhost, .timeshift_at => TIMESHIFT_ROOT,
        .snapper => SNAPPER_ROOT,
    };
}

/// The directory whose existence proves which Timeshift sub-layout a
/// snapshot uses (`localhost/` vs `@/`).
pub fn timeshiftProbe(buf: []u8, name: []const u8, at: bool) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}/{s}", .{
        TIMESHIFT_ROOT, name, if (at) "@" else "localhost",
    }) catch null;
}

/// The versioned copy of absolute path `file_path` inside snapshot
/// `name`, or null when it does not fit `buf`.
pub fn versionPath(buf: []u8, layout: Layout, name: []const u8, file_path: []const u8) ?[]const u8 {
    if (file_path.len == 0 or file_path[0] != '/') return null;
    return switch (layout) {
        .timeshift_localhost => std.fmt.bufPrint(buf, "{s}/{s}/localhost{s}", .{ TIMESHIFT_ROOT, name, file_path }),
        .timeshift_at => std.fmt.bufPrint(buf, "{s}/{s}/@{s}", .{ TIMESHIFT_ROOT, name, file_path }),
        .snapper => std.fmt.bufPrint(buf, "{s}/{s}/snapshot{s}", .{ SNAPPER_ROOT, name, file_path }),
    } catch null;
}

/// snapper snapshots are plain numbers; anything else in /.snapshots
/// (its "info" files live inside the numbered dirs, but be safe) is
/// not a snapshot.
pub fn isSnapperName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |ch| {
        if (!std.ascii.isDigit(ch)) return false;
    }
    return true;
}

/// Order snapshot names newest first. snapper names order numerically;
/// Timeshift's `YYYY-MM-DD_HH-MM-SS` stamps order lexicographically.
pub fn sortNewestFirst(names: [][]u8, numeric: bool) void {
    std.mem.sort([]u8, names, numeric, struct {
        fn lt(num: bool, a: []u8, b: []u8) bool {
            if (num) {
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
        versionPath(&buf, .timeshift_localhost, "2026-07-28_20-00-01", "/home/u/a.txt").?,
    );
    try t.expectEqualStrings(
        "/run/timeshift/backup/timeshift-btrfs/snapshots/2026-07-28_20-00-01/@/home/u/a.txt",
        versionPath(&buf, .timeshift_at, "2026-07-28_20-00-01", "/home/u/a.txt").?,
    );
    try t.expectEqualStrings(
        "/.snapshots/42/snapshot/etc/fstab",
        versionPath(&buf, .snapper, "42", "/etc/fstab").?,
    );
    try t.expect(versionPath(&buf, .snapper, "42", "relative") == null);
    try t.expect(versionPath(&buf, .snapper, "42", "") == null);
    var tiny: [8]u8 = undefined;
    try t.expect(versionPath(&tiny, .snapper, "42", "/etc/fstab") == null);
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

test "isSnapperName accepts only plain numbers" {
    const t = std.testing;
    try t.expect(isSnapperName("7"));
    try t.expect(isSnapperName("123"));
    try t.expect(!isSnapperName(""));
    try t.expect(!isSnapperName("7a"));
    try t.expect(!isSnapperName("grub-snapshot"));
}

test "sortNewestFirst orders snapper numerically and timeshift lexically" {
    const t = std.testing;
    var a1 = "9".*;
    var a2 = "10".*;
    var a3 = "2".*;
    var nums = [_][]u8{ &a1, &a2, &a3 };
    sortNewestFirst(&nums, true);
    try t.expectEqualStrings("10", nums[0]);
    try t.expectEqualStrings("9", nums[1]);
    try t.expectEqualStrings("2", nums[2]);

    var b1 = "2026-07-28_20-00-01".*;
    var b2 = "2026-07-30_08-00-00".*;
    var b3 = "2025-12-31_23-59-59".*;
    var stamps = [_][]u8{ &b1, &b2, &b3 };
    sortNewestFirst(&stamps, false);
    try t.expectEqualStrings("2026-07-30_08-00-00", stamps[0]);
    try t.expectEqualStrings("2026-07-28_20-00-01", stamps[1]);
    try t.expectEqualStrings("2025-12-31_23-59-59", stamps[2]);
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
