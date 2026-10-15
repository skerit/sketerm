//! Whole-tree jobs: delete, size, disk usage and permissions.

const std = @import("std");
const c = @import("../../c.zig").c;
const pathz = @import("../../util/pathz.zig");
const disk_usage = @import("../disk_usage.zig");
const fsjob = @import("../fsjob.zig");
const Job = fsjob.Job;
const Progress = fsjob.Progress;
const common = @import("common.zig");
const statOf = common.statOf;

// ── delete_tree ─────────────────────────────────────────────────

pub fn runDeleteTree(job: *const Job) u8 {
    const spec = job.spec;
    var st: c.struct_stat = undefined;
    if (!statOf(spec.src, &st, false)) return job.emitErrno("stat");
    var progress = Progress{};
    if ((st.st_mode & c.S_IFMT) == c.S_IFDIR) {
        // Count first (a stat walk, cheap against the unlink storm to
        // come) so the panel can show a fraction rather than a
        // number climbing toward an unknown ceiling.
        var bytes: u64 = 0;
        var entries: u64 = 0;
        dirSizeWalk(job, spec.src, &bytes, &entries, false);
        progress.total = entries + 1; // + the root directory itself
        progress.entries_total = progress.total;
        if (!deleteTreeDir(spec.src, &progress)) return job.emitErrno("delete");
    } else {
        progress.entries_total = 1;
        progress.total = 1;
        progress.setFile(spec.src);
        var z: [4096]u8 = undefined;
        const p = pathz.pathZ(&z, spec.src) catch return job.emitError("path too long");
        if (c.unlink(p) != 0) return job.emitErrno("unlink");
        progress.done += 1;
        if (!progress.entryDone()) return job.emitError("file-count overflow");
    }
    job.emit(.{
        .ev = "done",
        .done = progress.done,
        .total = progress.done,
        .resumed_from = @as(u64, 0),
        .files_done = progress.entries_done,
        .files_total = progress.entries_done,
    });
    return 0;
}

/// Post-order removal. Progress counts ENTRIES (files + dirs), since
/// byte totals mean nothing for deletion. Stack-recursive over path
/// depth; the wide-directory retry is a LOOP, because as recursion it
/// grew the stack per batch and, on a directory that cannot drain, per
/// batch for ever. A directory that is readable but not SEARCHABLE
/// (mode 0444) is exactly that: readdir lists its 2500+ names, every
/// lstat fails with EACCES, nothing is removed, and the old
/// `if (overflow) return deleteTreeDir(...)` re-ran the identical pass
/// until the 64 KiB-per-frame buffer overflowed the stack and took the
/// job helper down mid-delete. No progress in a pass is a failure.
pub fn deleteTreeDir(dir_path: []const u8, progress: *Progress) bool {
    var z: [4096]u8 = undefined;
    const dz = pathz.pathZ(&z, dir_path) catch return false;
    while (true) {
        const dir = c.opendir(dz) orelse return false;
        // Collect names first: unlink-during-readdir is UB on some libcs.
        var names_buf: [64 * 1024]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&names_buf);
        var names: std.ArrayList([]u8) = .empty;
        var overflow = false;
        while (c.readdir(dir)) |de| {
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&de.*.d_name)));
            if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            const owned = fba.allocator().dupe(u8, name) catch {
                overflow = true;
                break;
            };
            names.append(fba.allocator(), owned) catch {
                overflow = true;
                break;
            };
        }
        _ = c.closedir(dir);

        var removed: usize = 0;
        for (names.items) |name| {
            var fbuf: [4096]u8 = undefined;
            var w = std.Io.Writer.fixed(&fbuf);
            w.print("{s}/{s}", .{ dir_path, name }) catch return false;
            const full = w.buffered();
            var zf: [4096]u8 = undefined;
            const fz = pathz.pathZ(&zf, full) catch return false;
            var st: c.struct_stat = undefined;
            if (c.lstat(fz, &st) != 0) continue;
            if ((st.st_mode & c.S_IFMT) == c.S_IFDIR) {
                if (!deleteTreeDir(full, progress)) return false;
            } else {
                progress.setFile(full);
                if (c.unlink(fz) != 0) return false;
                progress.done += 1;
                if (!progress.entryDone()) return false;
            }
            removed += 1;
        }
        // A directory too wide for the name buffer: re-read this level
        // until it drains, batches of ~what fits. A pass that removed
        // nothing never will, so it stops rather than spins.
        if (!overflow) break;
        if (removed == 0) return false;
    }
    progress.setFile(dir_path);
    if (c.rmdir(dz) != 0) return false;
    progress.done += 1;
    if (!progress.entryDone()) return false;
    return true;
}

/// Recursive size: bytes plus an entry count, walked host-side so a
/// remote "calculate folder size" never streams a listing per level.
pub fn runDirSize(job: *const Job) u8 {
    const spec = job.spec;
    var st: c.struct_stat = undefined;
    if (!statOf(spec.src, &st, false)) return job.emitErrno("stat");
    var bytes: u64 = 0;
    var entries: u64 = 0;
    if ((st.st_mode & c.S_IFMT) == c.S_IFDIR) {
        dirSizeWalk(job, spec.src, &bytes, &entries, true);
    } else {
        bytes = @intCast(st.st_size);
        entries = 1;
    }
    job.emit(.{ .ev = "done", .done = bytes, .total = entries });
    return 0;
}

fn emitDiskUsageEvent(context: ?*anyopaque, event: disk_usage.Event) void {
    const job: *const Job = @ptrCast(@alignCast(context.?));
    switch (event) {
        .usage => |usage| job.emit(.{
            .ev = "usage",
            .path = usage.path,
            .kind = @tagName(usage.kind),
            .size = usage.size,
            .allocated = usage.allocated,
            .items = usage.items,
            .errors = usage.errors,
            .skipped = usage.skipped,
            .mtime_ms = usage.mtime_ms,
        }),
        .progress => |progress| job.emit(.{
            .ev = "progress",
            .done = progress.done,
            .total = progress.total,
            .files_done = progress.files_done,
            .file = progress.file,
        }),
    }
}

pub fn runDiskUsage(job: *const Job) u8 {
    const allocator = job.allocator;
    const spec = job.spec;
    const result = disk_usage.scan(
        allocator,
        spec.src,
        std.mem.eql(u8, spec.pattern, "all-filesystems"),
        .{ .context = @ptrCast(@constCast(job)), .on_event = emitDiskUsageEvent },
    ) catch |err| return switch (err) {
        error.InvalidRoot => job.emitError("path must be an absolute directory"),
        error.RootNotDirectory => job.emitError("disk usage root is not a directory"),
        error.RootStatFailed => job.emitErrno("stat"),
        error.RootOpenFailed => job.emitErrno("open"),
        error.OutOfMemory => job.emitError("disk usage scanner out of memory"),
    };
    job.emit(.{
        .ev = "done",
        .path = spec.src,
        .kind = "dir",
        .done = result.totals.size,
        .total = result.totals.allocated,
        .size = result.totals.size,
        .allocated = result.totals.allocated,
        .items = result.totals.items,
        .errors = result.totals.errors,
        .skipped = result.totals.skipped,
        .mtime_ms = result.mtime_ms,
        .files_done = result.totals.items,
        .truncated = result.truncated,
    });
    return 0;
}

/// @param report false when the walk is a silent pre-count (delete's
/// entry total) rather than the dir_size job's own answer.
fn dirSizeWalk(job: *const Job, dir_path: []const u8, bytes: *u64, entries: *u64, report: bool) void {
    var z: [4096]u8 = undefined;
    const dz = pathz.pathZ(&z, dir_path) catch return;
    const dir = c.opendir(dz) orelse return;
    defer _ = c.closedir(dir);
    var since_emit: u64 = 0;
    while (c.readdir(dir)) |de| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&de.*.d_name)));
        if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        var fbuf: [4096]u8 = undefined;
        var w = std.Io.Writer.fixed(&fbuf);
        w.print("{s}/{s}", .{ if (dir_path.len == 1) "" else dir_path, name }) catch continue;
        const full = w.buffered();
        var st: c.struct_stat = undefined;
        if (!statOf(full, &st, false)) continue;
        entries.* += 1;
        if ((st.st_mode & c.S_IFMT) == c.S_IFDIR) {
            dirSizeWalk(job, full, bytes, entries, report);
        } else {
            bytes.* += @intCast(st.st_size);
        }
        since_emit += 1;
        if (report and since_emit >= 2000) {
            since_emit = 0;
            job.emit(.{ .ev = "progress", .done = bytes.*, .total = entries.* });
        }
    }
}

/// Recursive chmod/chown. Symlinks are never followed: their own
/// permissions are meaningless and following them would let a link
/// inside the tree redirect the change outside it.
pub fn runPermTree(job: *const Job) u8 {
    const spec = job.spec;
    var st: c.struct_stat = undefined;
    if (!statOf(spec.src, &st, false)) return job.emitErrno("stat");
    var progress = Progress{};
    if (!permApply(job, spec.src, &progress)) return job.emitError("could not apply to every entry");
    job.emit(.{ .ev = "done", .done = progress.done, .total = progress.done });
    return 0;
}

fn permApply(job: *const Job, path: []const u8, progress: *Progress) bool {
    const spec = job.spec;
    var z: [4096]u8 = undefined;
    const pz = pathz.pathZ(&z, path) catch return false;
    var st: c.struct_stat = undefined;
    if (c.lstat(pz, &st) != 0) return false;
    const is_link = (st.st_mode & c.S_IFMT) == c.S_IFLNK;
    if (spec.uid >= 0 or spec.gid >= 0) {
        const uid: c.uid_t = if (spec.uid >= 0) @intCast(spec.uid) else @bitCast(@as(c_int, -1));
        const gid: c.gid_t = if (spec.gid >= 0) @intCast(spec.gid) else @bitCast(@as(c_int, -1));
        if (c.lchown(pz, uid, gid) != 0) return false;
    }
    if (spec.mode != 0 and !is_link) {
        if (c.chmod(pz, @intCast(spec.mode & 0o7777)) != 0) return false;
    }
    progress.done += 1;
    if (progress.done % 500 == 0)
        job.emit(.{ .ev = "progress", .done = progress.done, .total = @as(u64, 0) });
    if ((st.st_mode & c.S_IFMT) != c.S_IFDIR) return true;

    const dir = c.opendir(pz) orelse return false;
    var names_buf: [64 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&names_buf);
    var names: std.ArrayList([]u8) = .empty;
    var overflow_at: ?[]const u8 = null;
    while (c.readdir(dir)) |de| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&de.*.d_name)));
        if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        const owned = fba.allocator().dupe(u8, name) catch {
            overflow_at = name;
            break;
        };
        names.append(fba.allocator(), owned) catch {
            overflow_at = name;
            break;
        };
    }
    _ = c.closedir(dir);
    if (overflow_at != null) {
        // A directory wider than the name buffer would silently skip
        // the tail; say so rather than report a complete apply.
        job.emit(.{ .ev = "progress", .done = progress.done, .total = @as(u64, 0) });
        return false;
    }
    for (names.items) |name| {
        var fbuf: [4096]u8 = undefined;
        var w = std.Io.Writer.fixed(&fbuf);
        w.print("{s}/{s}", .{ if (path.len == 1) "" else path, name }) catch return false;
        if (!permApply(job, w.buffered(), progress)) return false;
    }
    return true;
}

test "a wide directory that cannot drain fails instead of spinning" {
    const t = std.testing;
    if (c.geteuid() == 0) return error.SkipZigTest; // root ignores the mode
    const td = pathz.TempDir.make("fsjob-wide") orelse return error.SkipZigTest;
    defer td.remove();

    var z: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&z);
    try w.print("{s}/wide", .{td.path()});
    const wide = w.buffered();
    var wz: [4096:0]u8 = undefined;
    const widez = try pathz.pathZ(&wz, wide);
    if (c.mkdir(widez, 0o755) != 0) return error.SkipZigTest;

    // More names than the 64 KiB batch buffer holds, so the drain
    // loop runs at all.
    var i: usize = 0;
    while (i < 3000) : (i += 1) {
        var nb: [4096]u8 = undefined;
        var nw = std.Io.Writer.fixed(&nb);
        try nw.print("{s}/f{d:0>6}.dat", .{ wide, i });
        var nz: [4096:0]u8 = undefined;
        const namez = try pathz.pathZ(&nz, nw.buffered());
        const fd = c.open(namez, c.O_WRONLY | c.O_CREAT | c.O_TRUNC, @as(c_uint, 0o600));
        if (fd < 0) return error.SkipZigTest;
        _ = c.close(fd);
    }
    // Readable but NOT searchable: readdir lists every name, every
    // lstat fails, nothing can be removed. The retry used to recurse
    // on the identical pass with a 64 KiB frame each time, until the
    // job helper died on the stack.
    if (c.chmod(widez, 0o444) != 0) return error.SkipZigTest;
    var progress = Progress{};
    const ok = deleteTreeDir(wide, &progress);
    _ = c.chmod(widez, 0o755);
    try t.expect(!ok);
    try t.expectEqual(@as(u64, 0), progress.entries_done);
}
