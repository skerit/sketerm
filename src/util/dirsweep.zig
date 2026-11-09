//! The one "delete our old scratch files" walk.
//!
//! Three caches (viewer batch manifests, Quick Look open-copies, the
//! remote thumbnail cache) had each grown their own readdir + lstat +
//! unlink loop with a different idea of what "old" meant. This walk
//! implements both policies -- an age bound and a file-count cap
//! trimmed oldest-first -- and only ever removes regular files the
//! calling user owns, so a sweep pointed at the wrong directory by a
//! bad environment cannot delete anything that is not ours.
//! `sweepTrees` is the directory-tree variant (drag staging copies):
//! the same ownership rule on the swept directory, and no symlink is
//! ever followed.

const std = @import("std");
const c = @import("../c.zig").c;

pub const Policy = struct {
    /// Only names with this prefix and suffix are candidates.
    prefix: []const u8 = "",
    suffix: []const u8 = "",
    /// Remove candidates whose mtime is older than this many seconds.
    max_age_secs: ?i64 = null,
    /// Keep at most this many candidates; the oldest past it go.
    max_files: ?usize = null,
    /// When trimming by count, remove this many extra so the next
    /// sweep is not due at the very next write.
    trim_extra: usize = 0,
};

/// A candidate remembered for the count trim; the name is bounded by
/// what `readdir` can hand out.
const Candidate = struct {
    mtime: i64,
    name_len: u8,
    name: [255]u8,

    fn slice(self: *const Candidate) []const u8 {
        return self.name[0..self.name_len];
    }
};

const mtimeSec = @import("platform.zig").mtimeSecs;

/// Sweep `dir` under `policy`. Best effort: an unreadable directory
/// removes nothing, and the count trim bounds its own collection at
/// twice the cap (a later sweep picks up the rest).
pub fn sweep(dir: [*:0]const u8, policy: Policy) void {
    const d = c.opendir(dir) orelse return;
    defer _ = c.closedir(d);
    const now = c.time(null);
    const uid = c.geteuid();
    var kept: std.ArrayList(Candidate) = .empty;
    defer kept.deinit(std.heap.c_allocator);
    const collect_cap: usize = if (policy.max_files) |cap| cap * 2 else 0;
    while (c.readdir(d)) |ent| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
        if (!std.mem.startsWith(u8, name, policy.prefix) or !std.mem.endsWith(u8, name, policy.suffix)) continue;
        if (name.len > 255) continue;
        var pz: [4352:0]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&pz, "{s}/{s}", .{ std.mem.span(dir), name }, 0) catch continue;
        var st: c.struct_stat = undefined;
        if (c.lstat(path.ptr, &st) != 0 or st.st_uid != uid or (st.st_mode & c.S_IFMT) != c.S_IFREG) continue;
        const mtime = mtimeSec(&st);
        if (policy.max_age_secs) |age| {
            if (mtime + age < now) {
                _ = c.unlink(path.ptr);
                continue;
            }
        }
        if (policy.max_files != null and kept.items.len < collect_cap) {
            var cand: Candidate = .{ .mtime = mtime, .name_len = @intCast(name.len), .name = undefined };
            @memcpy(cand.name[0..name.len], name);
            kept.append(std.heap.c_allocator, cand) catch break;
        }
    }
    const cap = policy.max_files orelse return;
    if (kept.items.len <= cap) return;
    std.mem.sort(Candidate, kept.items, {}, struct {
        fn lt(_: void, x: Candidate, y: Candidate) bool {
            return x.mtime < y.mtime;
        }
    }.lt);
    const doomed = @min(kept.items.len - cap + policy.trim_extra, kept.items.len);
    for (kept.items[0..doomed]) |cand| {
        var pz: [4352:0]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&pz, "{s}/{s}", .{ std.mem.span(dir), cand.slice() }, 0) catch continue;
        _ = c.unlink(path.ptr);
    }
}

/// Deepest directory nesting `sweepTrees` descends into; a deeper tree
/// is left partly in place for a later sweep rather than recursed into
/// without bound.
const MAX_TREE_DEPTH: usize = 64;

/// Sweep whole directory trees out of `dir`: every subdirectory whose
/// name carries `policy.prefix`, that the calling user owns, and whose
/// own mtime is older than `policy.max_age_secs` goes with everything
/// in it. Symlinks are removed, never followed. `max_files` and
/// `suffix` are ignored; without `max_age_secs` nothing is removed.
pub fn sweepTrees(dir: [*:0]const u8, policy: Policy) void {
    const age = policy.max_age_secs orelse return;
    const dfd = c.open(dir, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
    if (dfd < 0) return;
    defer _ = c.close(dfd);
    const dup = c.dup(dfd);
    if (dup < 0) return;
    const d = c.fdopendir(dup) orelse {
        _ = c.close(dup);
        return;
    };
    defer _ = c.closedir(d);
    const now = c.time(null);
    const uid = c.geteuid();
    while (c.readdir(d)) |ent| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
        if (!std.mem.startsWith(u8, name, policy.prefix)) continue;
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        var st: c.struct_stat = undefined;
        if (c.fstatat(dfd, @ptrCast(&ent.*.d_name), &st, c.AT_SYMLINK_NOFOLLOW) != 0) continue;
        if (st.st_uid != uid or (st.st_mode & c.S_IFMT) != c.S_IFDIR) continue;
        if (mtimeSec(&st) + age >= now) continue;
        removeTree(dfd, @ptrCast(&ent.*.d_name), 0);
    }
}

/// Remove `name` (a directory under `parent`) and its contents. Best
/// effort: whatever cannot be removed stays.
fn removeTree(parent: c_int, name: [*:0]const u8, depth: usize) void {
    if (depth < MAX_TREE_DEPTH) {
        const fd = c.openat(parent, name, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
        if (fd >= 0) {
            if (c.fdopendir(fd)) |d| {
                defer _ = c.closedir(d);
                const inner = c.dirfd(d);
                while (c.readdir(d)) |ent| {
                    const child: [*:0]const u8 = @ptrCast(&ent.*.d_name);
                    const span = std.mem.span(child);
                    if (std.mem.eql(u8, span, ".") or std.mem.eql(u8, span, "..")) continue;
                    var st: c.struct_stat = undefined;
                    if (c.fstatat(inner, child, &st, c.AT_SYMLINK_NOFOLLOW) != 0) continue;
                    if ((st.st_mode & c.S_IFMT) == c.S_IFDIR)
                        removeTree(inner, child, depth + 1)
                    else
                        _ = c.unlinkat(inner, child, 0);
                }
            } else _ = c.close(fd);
        }
    }
    _ = c.unlinkat(parent, name, c.AT_REMOVEDIR);
}

/// Test scaffolding: an empty file with the given mtime.
fn touchAt(dir: []const u8, name: []const u8, mtime: i64) !void {
    var pz: [4352:0]u8 = undefined;
    const p = try std.fmt.bufPrintSentinel(&pz, "{s}/{s}", .{ dir, name }, 0);
    const fd = c.open(p.ptr, c.O_WRONLY | c.O_CREAT | c.O_TRUNC, @as(c.mode_t, 0o600));
    if (fd < 0) return error.CreateFailed;
    _ = c.close(fd);
    const times = [2]c.struct_timespec{ .{ .tv_sec = mtime, .tv_nsec = 0 }, .{ .tv_sec = mtime, .tv_nsec = 0 } };
    if (c.utimensat(c.AT_FDCWD, p.ptr, &times, 0) != 0) return error.UtimeFailed;
}

fn present(dir: []const u8, name: []const u8) bool {
    var pz: [4352:0]u8 = undefined;
    const p = std.fmt.bufPrintSentinel(&pz, "{s}/{s}", .{ dir, name }, 0) catch return false;
    return c.access(p.ptr, c.F_OK) == 0;
}

test "sweep removes only aged own regular files with the named shape, and trims oldest past a cap" {
    const t = std.testing;
    const td = @import("pathz.zig").TempDir.make("dirsweep") orelse return error.SkipZigTest;
    defer td.remove();
    const dir = td.path();
    const now = c.time(null);
    const ancient = now - 10_000;

    // Age policy: an old "open-" file goes; a fresh one and a
    // differently named old one stay.
    try touchAt(dir, "open-old", ancient);
    try touchAt(dir, "open-new", now);
    try touchAt(dir, "keep-old", ancient);
    sweep(td.pathZ(), .{ .prefix = "open-", .max_age_secs = 3600 });
    try t.expect(!present(dir, "open-old"));
    try t.expect(present(dir, "open-new"));
    try t.expect(present(dir, "keep-old"));

    // Count policy: five ".thumb" files, cap 3 with one extra trimmed,
    // leaves the two newest; the earlier survivors are not candidates.
    // (The collection bound is twice the cap, so all five are seen.)
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "t{d}.thumb", .{i});
        try touchAt(dir, name, ancient + @as(i64, @intCast(i)) * 100);
    }
    sweep(td.pathZ(), .{ .suffix = ".thumb", .max_files = 3, .trim_extra = 1 });
    try t.expect(!present(dir, "t0.thumb"));
    try t.expect(!present(dir, "t1.thumb"));
    try t.expect(!present(dir, "t2.thumb"));
    try t.expect(present(dir, "t3.thumb"));
    try t.expect(present(dir, "t4.thumb"));
    try t.expect(present(dir, "open-new"));
}

test "sweepTrees removes only aged own prefixed directories, whole, without following links" {
    const t = std.testing;
    const td = @import("pathz.zig").TempDir.make("dirsweep-trees") orelse return error.SkipZigTest;
    defer td.remove();
    const dir = td.path();
    const now = c.time(null);
    const ancient = now - 10_000;
    var pz: [4352:0]u8 = undefined;

    // An outside file a planted symlink points at: it must survive.
    try touchAt(dir, "outside", now);
    for ([_][]const u8{ "drag-old", "drag-old/sub", "drag-new", "other-old" }) |rel| {
        const p = try std.fmt.bufPrintSentinel(&pz, "{s}/{s}", .{ dir, rel }, 0);
        try t.expect(c.mkdir(p.ptr, 0o700) == 0);
    }
    try touchAt(dir, "drag-old/sub/f", ancient);
    try touchAt(dir, "drag-old/g", ancient);
    const target = try std.fmt.bufPrintSentinel(&pz, "{s}/outside", .{dir}, 0);
    var link_buf: [4352:0]u8 = undefined;
    const link = try std.fmt.bufPrintSentinel(&link_buf, "{s}/drag-old/link", .{dir}, 0);
    try t.expect(c.symlink(target.ptr, link.ptr) == 0);
    // Age the directories last: adding children refreshed their mtimes.
    for ([_][]const u8{ "drag-old", "other-old" }) |rel| {
        const p = try std.fmt.bufPrintSentinel(&pz, "{s}/{s}", .{ dir, rel }, 0);
        const times = [2]c.struct_timespec{ .{ .tv_sec = ancient, .tv_nsec = 0 }, .{ .tv_sec = ancient, .tv_nsec = 0 } };
        try t.expect(c.utimensat(c.AT_FDCWD, p.ptr, &times, 0) == 0);
    }
    sweepTrees(td.pathZ(), .{ .prefix = "drag-", .max_age_secs = 3600 });
    try t.expect(!present(dir, "drag-old"));
    try t.expect(present(dir, "drag-new"));
    try t.expect(present(dir, "other-old"));
    try t.expect(present(dir, "outside"));
}
