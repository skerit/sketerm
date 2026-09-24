//! The one "delete our old scratch files" walk.
//!
//! Three caches (viewer batch manifests, Quick Look open-copies, the
//! remote thumbnail cache) had each grown their own readdir + lstat +
//! unlink loop with a different idea of what "old" meant. This walk
//! implements both policies -- an age bound and a file-count cap
//! trimmed oldest-first -- and only ever removes regular files the
//! calling user owns, so a sweep pointed at the wrong directory by a
//! bad environment cannot delete anything that is not ours.

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

fn mtimeSec(st: *const c.struct_stat) i64 {
    return if (@hasField(c.struct_stat, "st_mtim")) st.st_mtim.tv_sec else st.st_mtimespec.tv_sec;
}

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
        const path = std.fmt.bufPrintZ(&pz, "{s}/{s}", .{ std.mem.span(dir), name }) catch continue;
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
        const path = std.fmt.bufPrintZ(&pz, "{s}/{s}", .{ std.mem.span(dir), cand.slice() }) catch continue;
        _ = c.unlink(path.ptr);
    }
}

/// Test scaffolding: an empty file with the given mtime.
fn touchAt(dir: []const u8, name: []const u8, mtime: i64) !void {
    var pz: [4352:0]u8 = undefined;
    const p = try std.fmt.bufPrintZ(&pz, "{s}/{s}", .{ dir, name });
    const fd = c.open(p.ptr, c.O_WRONLY | c.O_CREAT | c.O_TRUNC, @as(c.mode_t, 0o600));
    if (fd < 0) return error.CreateFailed;
    _ = c.close(fd);
    const times = [2]c.struct_timespec{ .{ .tv_sec = mtime, .tv_nsec = 0 }, .{ .tv_sec = mtime, .tv_nsec = 0 } };
    if (c.utimensat(c.AT_FDCWD, p.ptr, &times, 0) != 0) return error.UtimeFailed;
}

fn present(dir: []const u8, name: []const u8) bool {
    var pz: [4352:0]u8 = undefined;
    const p = std.fmt.bufPrintZ(&pz, "{s}/{s}", .{ dir, name }) catch return false;
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
