//! The copy job: single files, symlinks and whole trees, with resume and verify.

const std = @import("std");
const c = @import("../../c.zig").c;
const pathz = @import("../../util/pathz.zig");
const fsserve = @import("../fsserve.zig");
const platform = @import("../../util/platform.zig");
const uniqueName = @import("../../filebrowser/paths.zig").uniqueName;
const Sha256 = std.crypto.hash.sha2.Sha256;
const fsjob = @import("../fsjob.zig");
const Job = fsjob.Job;
const Spec = fsjob.Spec;
const Progress = fsjob.Progress;
const CHUNK = fsjob.CHUNK;
const PART_SUFFIX = fsjob.PART_SUFFIX;
const LINK_PART_SUFFIX = fsjob.LINK_PART_SUFFIX;
const common = @import("common.zig");
const statOf = common.statOf;
const hashPrefix = @import("hash.zig").hashPrefix;
const deleteTreeDir = @import("tree.zig").deleteTreeDir;

// ── copy ────────────────────────────────────────────────────────

const fsyncParent = pathz.fsyncParent;

pub fn runCopy(job: *const Job) u8 {
    const spec = job.spec;
    if (spec.dst.len == 0) return job.emitError("copy needs dst");
    // dst inside src would recurse into its own output.
    if (spec.dst.len > spec.src.len and
        std.mem.startsWith(u8, spec.dst, spec.src) and spec.dst[spec.src.len] == '/')
        return job.emitError("dst is inside src");

    var st: c.struct_stat = undefined;
    if (!statOf(spec.src, &st, false)) return job.emitErrno("stat src");

    if ((st.st_mode & c.S_IFMT) == c.S_IFDIR) return runCopyTree(job);
    if ((st.st_mode & c.S_IFMT) == c.S_IFLNK) return runCopyRootLink(job);

    var progress = Progress{
        .total = if (st.st_size > 0) @intCast(st.st_size) else 0,
        .entries_total = 1,
    };
    switch (copyOneFile(spec.src, spec.dst, st, spec.@"resume", spec.verify, spec.no_replace, &progress)) {
        .ok => if (!progress.entryDone()) return job.emitError("file-count overflow"),
        .err => |m| return job.emitError(m),
        .errno => |what| return job.emitErrno(what),
    }
    job.emitCopyDone(&progress);
    return 0;
}

fn runCopyRootLink(job: *const Job) u8 {
    const spec = job.spec;
    var src_z: [4096]u8 = undefined;
    const src = pathz.pathZ(&src_z, spec.src) catch return job.emitError("path too long");
    var target_buf: [4096]u8 = undefined;
    const n = c.readlink(src, &target_buf, target_buf.len);
    if (n < 0) return job.emitErrno("readlink");
    var temp_buf: [4096]u8 = undefined;
    const temp = std.fmt.bufPrint(&temp_buf, "{s}" ++ LINK_PART_SUFFIX ++ "-{d}", .{ spec.dst, c.getpid() }) catch
        return job.emitError("path too long");
    var temp_z_buf: [4096]u8 = undefined;
    const temp_z = pathz.pathZ(&temp_z_buf, temp) catch return job.emitError("path too long");
    _ = c.unlink(temp_z);
    if (c.symlink(pathz.pathZ(&src_z, target_buf[0..@intCast(n)]) catch return job.emitError("symlink target too long"), temp_z) != 0)
        return job.emitErrno("create symlink");
    var dst_z_buf: [4096]u8 = undefined;
    const dst_z = pathz.pathZ(&dst_z_buf, spec.dst) catch return job.emitError("path too long");
    if (spec.no_replace) {
        switch (platform.renameNoReplace(temp_z, dst_z)) {
            .ok => {},
            .exists => {
                _ = c.unlink(temp_z);
                return job.emitError("destination exists");
            },
            .cross_device => {
                _ = c.unlink(temp_z);
                return job.emitError("install symlink crossed filesystems");
            },
            .failed => {
                _ = c.unlink(temp_z);
                return job.emitError("install symlink failed");
            },
        }
    } else if (c.rename(temp_z, dst_z) != 0) {
        _ = c.unlink(temp_z);
        return job.emitErrno("replace symlink");
    }
    if (!fsyncParent(spec.dst)) return job.emitErrno("fsync symlink parent");
    const progress = Progress{ .entries_done = 1, .entries_total = 1 };
    job.emitCopyDone(&progress);
    return 0;
}

const CopyResult = union(enum) { ok, err: []const u8, errno: []const u8 };

/// What a tree copy does about names that already exist at the
/// destination. `replace` is a property of the TOP-level directory
/// only; nested collisions are always resolved per entry.
const CopyOpts = struct {
    allow_resume: bool = false,
    conflict: enum { overwrite, skip, keep_both } = .overwrite,
    replace: bool = false,
    verify: bool = false,
    no_replace: bool = false,

    fn fromSpec(spec: Spec) CopyOpts {
        return .{
            .allow_resume = spec.@"resume",
            .verify = spec.verify,
            .conflict = if (std.mem.eql(u8, spec.conflict, "skip"))
                .skip
            else if (std.mem.eql(u8, spec.conflict, "keep_both"))
                .keep_both
            else
                .overwrite,
            .replace = std.mem.eql(u8, spec.dir_mode, "replace"),
            .no_replace = spec.no_replace,
        };
    }
};

/// Single-file copy via a staged `.skpart` with hash-verified resume,
/// fsync, mode preservation, and atomic rename.
fn copyOneFile(src: []const u8, dst: []const u8, src_st: c.struct_stat, allow_resume: bool, verify: bool, no_replace: bool, progress: *Progress) CopyResult {
    var part_buf: [4096]u8 = undefined;
    var wpart = std.Io.Writer.fixed(&part_buf);
    wpart.print("{s}" ++ PART_SUFFIX, .{dst}) catch return .{ .err = "path too long" };
    const part = wpart.buffered();

    const src_size: u64 = if (src_st.st_size > 0) @intCast(src_st.st_size) else 0;

    // Resume decision: an existing partial continues only when its
    // FULL content hashes equal to the same-length source prefix.
    var start: u64 = 0;
    if (allow_resume) {
        var pst: c.struct_stat = undefined;
        if (statOf(part, &pst, true) and pst.st_size > 0 and @as(u64, @intCast(pst.st_size)) <= src_size) {
            const plen: u64 = @intCast(pst.st_size);
            const part_h = hashPrefix(part, plen, null);
            const src_h = hashPrefix(src, plen, null);
            if (part_h != null and src_h != null and
                std.mem.eql(u8, &part_h.?, &src_h.?)) start = plen;
        }
    }
    // Cumulative, not assigned: inside a tree copy `done` already
    // carries every earlier file (assigning here made the panel's
    // percentage restart from zero on every file of a tree).
    progress.resumed = std.math.add(u64, progress.resumed, start) catch
        return .{ .err = "copy progress overflow" };
    progress.done = std.math.add(u64, progress.done, start) catch
        return .{ .err = "copy progress overflow" };
    progress.setFile(src);

    var zs: [4096]u8 = undefined;
    const sp = pathz.pathZ(&zs, src) catch return .{ .err = "path too long" };
    const sfd = c.open(sp, c.O_RDONLY | c.O_CLOEXEC);
    if (sfd < 0) return .{ .errno = "open src" };
    defer _ = c.close(sfd);

    var zd: [4096]u8 = undefined;
    const pp = pathz.pathZ(&zd, part) catch return .{ .err = "path too long" };
    const dflags: c_int = if (start > 0) c.O_WRONLY | c.O_CLOEXEC else c.O_WRONLY | c.O_CREAT | c.O_TRUNC | c.O_CLOEXEC;
    const dfd = c.open(pp, dflags, @as(c.mode_t, 0o600));
    if (dfd < 0) return .{ .errno = "open dst" };
    defer _ = c.close(dfd);
    if (start > 0) {
        if (c.lseek(dfd, @intCast(start), c.SEEK_SET) < 0) return .{ .errno = "seek dst" };
        if (c.lseek(sfd, @intCast(start), c.SEEK_SET) < 0) return .{ .errno = "seek src" };
    }

    var buf: [CHUNK]u8 = undefined;
    while (true) {
        const n = c.read(sfd, &buf, buf.len);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n < 0) return .{ .errno = "read src" };
        if (n == 0) break;
        var off: usize = 0;
        while (off < @as(usize, @intCast(n))) {
            const w = c.write(dfd, buf[off..].ptr, @as(usize, @intCast(n)) - off);
            if (w < 0 and std.posix.errno(w) == .INTR) continue;
            if (w <= 0) return .{ .errno = "write dst" };
            off += @intCast(w);
        }
        if (!progress.add(@intCast(n))) return .{ .err = "copy progress overflow" };
    }

    if (c.fsync(dfd) != 0) return .{ .errno = "fsync" };
    _ = c.fchmod(dfd, src_st.st_mode & 0o7777);
    // Verify-after-copy: the staged bytes must hash like the source
    // BEFORE the rename installs them; a mismatch leaves the
    // destination untouched and discards the stage.
    if (verify) {
        const part_h = hashPrefix(part, src_size, null);
        const src_h = hashPrefix(src, src_size, null);
        if (part_h == null or src_h == null or !std.mem.eql(u8, &part_h.?, &src_h.?)) {
            _ = c.unlink(pp);
            return .{ .err = "copy verification failed (checksum mismatch)" };
        }
    }
    var zr: [4096]u8 = undefined;
    const dp = pathz.pathZ(&zr, dst) catch return .{ .err = "path too long" };
    if (no_replace) {
        switch (platform.renameNoReplace(pp, dp)) {
            .ok => {},
            .exists => {
                _ = c.unlink(pp);
                return .{ .err = "destination exists" };
            },
            .cross_device => {
                _ = c.unlink(pp);
                return .{ .err = "install destination crossed filesystems" };
            },
            .failed => {
                _ = c.unlink(pp);
                return .{ .err = "install destination failed" };
            },
        }
    } else if (c.rename(pp, dp) != 0) return .{ .errno = "rename" };
    if (!fsyncParent(dst)) return .{ .errno = "fsync destination parent" };
    return .ok;
}

/// Recursive tree copy. Pass 1 sizes the job (progress totals);
/// pass 2 copies: dirs mkdir'ed, symlinks recreated as symlinks,
/// regular files staged like the single-file path. On resume,
/// completed files are reused only after source/destination hashing;
/// the in-flight partial is likewise prefix-verified before resume.
///
/// A destination directory that already exists is MERGED by default:
/// the walk recurses into it and entries that exist only there are
/// left alone. `dir_mode = "replace"` deletes the destination tree
/// first, so those entries are gone.
fn runCopyTree(job: *const Job) u8 {
    const allocator = job.allocator;
    const spec = job.spec;
    var progress = Progress{};
    var before_hash = Sha256.init(.{});
    if (!sizeTree(allocator, spec.src, &progress.total, &progress.entries_total, &before_hash))
        return job.emitError("cannot size source tree (listing failed or truncated)");
    var before: [Sha256.digest_length]u8 = undefined;
    before_hash.final(&before);

    const opts = CopyOpts.fromSpec(spec);
    if (opts.no_replace and opts.replace)
        return job.emitError("no_replace conflicts with dir_mode=replace");
    if (opts.replace) {
        var dst_st: c.struct_stat = undefined;
        if (statOf(spec.dst, &dst_st, false)) {
            var drop = Progress{ .quiet = true };
            const removed = if ((dst_st.st_mode & c.S_IFMT) == c.S_IFDIR)
                deleteTreeDir(spec.dst, &drop)
            else blk: {
                var z: [4096]u8 = undefined;
                break :blk c.unlink(pathz.pathZ(&z, spec.dst) catch
                    return job.emitError("path too long")) == 0;
            };
            if (!removed) return job.emitErrno("replace destination");
        }
    }
    switch (copyTreeDir(allocator, spec.src, spec.dst, opts, &progress, true)) {
        .ok => {},
        .err => |m| return job.emitError(m),
        .errno => |what| return job.emitErrno(what),
    }
    if (progress.done != progress.total or progress.entries_done != progress.entries_total)
        return job.emitError("source tree changed while it was copied; progress manifest drifted");
    var after_total: u64 = 0;
    var after_files: u64 = 0;
    var after_hash = Sha256.init(.{});
    if (!sizeTree(allocator, spec.src, &after_total, &after_files, &after_hash))
        return job.emitError("source tree changed while it was copied; final listing failed");
    var after: [Sha256.digest_length]u8 = undefined;
    after_hash.final(&after);
    if (after_total != progress.total or after_files != progress.entries_total or
        !std.mem.eql(u8, &before, &after))
        return job.emitError("source tree changed while it was copied; source fingerprint drifted");
    job.emitCopyDone(&progress);
    return 0;
}

fn stampU64(hash: *Sha256, value: u64) void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, value, .little);
    hash.update(&buf);
}

pub fn stampEntry(hash: *Sha256, path: []const u8, kind: []const u8, size: u64, mode: u32, mtime_ns: i64, ctime_ns: i64, dev: u64, ino: u64, target: []const u8) void {
    stampU64(hash, path.len);
    hash.update(path);
    stampU64(hash, kind.len);
    hash.update(kind);
    stampU64(hash, size);
    stampU64(hash, mode);
    stampU64(hash, @bitCast(mtime_ns));
    stampU64(hash, @bitCast(ctime_ns));
    stampU64(hash, dev);
    stampU64(hash, ino);
    stampU64(hash, target.len);
    hash.update(target);
}

fn sizeTree(allocator: std.mem.Allocator, dir_path: []const u8, total: *u64, files: *u64, hash: *Sha256) bool {
    var dir_st: c.struct_stat = undefined;
    if (!statOf(dir_path, &dir_st, false)) return false;
    const dir_mtime = if (@hasField(c.struct_stat, "st_mtim")) dir_st.st_mtim else dir_st.st_mtimespec;
    const dir_ctime = if (@hasField(c.struct_stat, "st_ctim")) dir_st.st_ctim else dir_st.st_ctimespec;
    stampEntry(hash, dir_path, "dir", 0, @intCast(dir_st.st_mode & 0o7777), @as(i64, @intCast(dir_mtime.tv_sec)) * std.time.ns_per_s + @as(i64, @intCast(dir_mtime.tv_nsec)), @as(i64, @intCast(dir_ctime.tv_sec)) * std.time.ns_per_s + @as(i64, @intCast(dir_ctime.tv_nsec)), @intCast(dir_st.st_dev), @intCast(dir_st.st_ino), "");
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const l = fsserve.listDir(arena_state.allocator(), dir_path, fsserve.MAX_ENTRIES) catch return false;
    if (l.truncated) return false;
    for (l.entries) |e| {
        var buf: [4096]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        w.print("{s}/{s}", .{ dir_path, e.name }) catch return false;
        const child = w.buffered();
        stampEntry(hash, child, e.kind, e.size, e.mode, e.mtime_ns, e.ctime_ns, e.dev, e.ino, e.target orelse "");
        if (std.mem.eql(u8, e.kind, "dir")) {
            if (!sizeTree(allocator, child, total, files, hash)) return false;
        } else if (std.mem.eql(u8, e.kind, "file")) {
            total.* = std.math.add(u64, total.*, e.size) catch return false;
            files.* = std.math.add(u64, files.*, 1) catch return false;
        }
    }
    return true;
}

/// A destination name that is free in `dir`, "name (copy).ext" first —
/// the same scheme the browser's own Keep Both uses.
fn uniqueInDir(dir: []const u8, base: []const u8, is_dir: bool, buf: []u8) ?[]const u8 {
    const OnDisk = struct {
        dir: []const u8,
        pub fn contains(self: @This(), name: []const u8) bool {
            var full: [4096]u8 = undefined;
            var z: [4096]u8 = undefined;
            const p = std.fmt.bufPrint(&full, "{s}/{s}", .{ if (self.dir.len == 1) "" else self.dir, name }) catch return true;
            var st: c.struct_stat = undefined;
            return c.lstat(pathz.pathZ(&z, p) catch return true, &st) == 0;
        }
    };
    return uniqueName(base, is_dir, buf, OnDisk{ .dir = dir });
}

fn copyTreeDir(allocator: std.mem.Allocator, src_dir: []const u8, dst_dir: []const u8, opts: CopyOpts, progress: *Progress, root: bool) CopyResult {
    var src_st: c.struct_stat = undefined;
    if (!statOf(src_dir, &src_st, true)) return .{ .errno = "stat dir" };
    {
        var z: [4096]u8 = undefined;
        const dp = pathz.pathZ(&z, dst_dir) catch return .{ .err = "path too long" };
        const rc = c.mkdir(dp, src_st.st_mode & 0o7777);
        if (rc == 0) {
            if (!fsyncParent(dst_dir)) return .{ .errno = "fsync directory parent" };
        } else if (std.posix.errno(@as(c_int, -1)) == .EXIST) {
            if (root and opts.no_replace) return .{ .err = "destination exists" };
            var st2: c.struct_stat = undefined;
            if (c.stat(dp, &st2) != 0 or (st2.st_mode & c.S_IFMT) != c.S_IFDIR) return .{ .errno = "mkdir" };
        } else return .{ .errno = "mkdir" };
    }

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const l = fsserve.listDir(arena_state.allocator(), src_dir, fsserve.MAX_ENTRIES) catch
        return .{ .err = "cannot list source dir" };
    if (l.truncated) return .{ .err = "source directory listing truncated" };

    for (l.entries) |e| {
        var sbuf: [4096]u8 = undefined;
        var sw = std.Io.Writer.fixed(&sbuf);
        sw.print("{s}/{s}", .{ src_dir, e.name }) catch return .{ .err = "path too long" };
        const spath = sw.buffered();
        var dbuf: [4096]u8 = undefined;
        var dw = std.Io.Writer.fixed(&dbuf);
        dw.print("{s}/{s}", .{ dst_dir, e.name }) catch return .{ .err = "path too long" };
        var dpath = dw.buffered();

        // Per-entry collision policy. Directories are exempt: merging
        // recurses into them, which is what makes merge a merge.
        var unique_buf: [4096]u8 = undefined;
        if (opts.conflict != .overwrite and !std.mem.eql(u8, e.kind, "dir")) {
            var exist_st: c.struct_stat = undefined;
            if (statOf(dpath, &exist_st, false)) {
                if (opts.conflict == .skip) {
                    // Counted as handled: `total` already includes it,
                    // so not counting it would strand the bar short.
                    if (std.mem.eql(u8, e.kind, "file") and !progress.add(e.size))
                        return .{ .err = "copy progress overflow" };
                    if (!progress.entryDone()) return .{ .err = "file-count overflow" };
                    continue;
                }
                const name = uniqueInDir(dst_dir, e.name, std.mem.eql(u8, e.kind, "dir"), &unique_buf) orelse
                    return .{ .err = "no free destination name" };
                var rw = std.Io.Writer.fixed(&dbuf);
                rw.print("{s}/{s}", .{ dst_dir, name }) catch return .{ .err = "path too long" };
                dpath = rw.buffered();
            }
        }

        if (std.mem.eql(u8, e.kind, "dir")) {
            switch (copyTreeDir(allocator, spath, dpath, opts, progress, false)) {
                .ok => {},
                else => |r| return r,
            }
        } else if (std.mem.eql(u8, e.kind, "link")) {
            var zt: [4096]u8 = undefined;
            var zl: [4096]u8 = undefined;
            var ztmp: [4096]u8 = undefined;
            const tgt = pathz.pathZ(&zt, e.target orelse return .{ .err = "symlink target missing" }) catch
                return .{ .err = "path too long" };
            const lp = pathz.pathZ(&zl, dpath) catch return .{ .err = "path too long" };
            var temp_buf: [4096]u8 = undefined;
            const temp = std.fmt.bufPrint(&temp_buf, "{s}" ++ LINK_PART_SUFFIX ++ "-{d}", .{ dpath, c.getpid() }) catch return .{ .err = "path too long" };
            const temp_z = pathz.pathZ(&ztmp, temp) catch return .{ .err = "path too long" };
            _ = c.unlink(temp_z);
            if (c.symlink(tgt, temp_z) != 0) return .{ .errno = "create symlink" };
            if (c.rename(temp_z, lp) != 0) {
                _ = c.unlink(temp_z);
                return .{ .errno = "replace symlink" };
            }
            const parent = std.fs.path.dirname(dpath) orelse dst_dir;
            var zd: [4096]u8 = undefined;
            const dfd = c.open(pathz.pathZ(&zd, parent) catch return .{ .err = "path too long" }, c.O_RDONLY | c.O_DIRECTORY);
            if (dfd < 0) return .{ .errno = "open symlink parent" };
            defer _ = c.close(dfd);
            if (c.fsync(dfd) != 0) return .{ .errno = "fsync symlink parent" };
        } else if (std.mem.eql(u8, e.kind, "file")) {
            progress.setFile(spath);
            if (opts.allow_resume) {
                var dst_st: c.struct_stat = undefined;
                if (statOf(dpath, &dst_st, false) and (dst_st.st_mode & c.S_IFMT) == c.S_IFREG and
                    @as(u64, @intCast(dst_st.st_size)) == e.size)
                {
                    const src_h = hashPrefix(spath, e.size, null);
                    const dst_h = hashPrefix(dpath, e.size, null);
                    if (src_h != null and dst_h != null and std.mem.eql(u8, &src_h.?, &dst_h.?)) {
                        progress.resumed = std.math.add(u64, progress.resumed, e.size) catch
                            return .{ .err = "copy progress overflow" };
                        if (!progress.add(e.size) or !progress.entryDone())
                            return .{ .err = "copy progress overflow" };
                        continue;
                    }
                }
            }
            var fst: c.struct_stat = undefined;
            if (!statOf(spath, &fst, true)) return .{ .errno = "stat source file" };
            // Only regular files are counted: `entries_total` comes
            // from sizeTree, which counts exactly those.
            switch (copyOneFile(spath, dpath, fst, opts.allow_resume, opts.verify, false, progress)) {
                .ok => if (!progress.entryDone()) return .{ .err = "file-count overflow" },
                else => |r| return r,
            }
        }
        // "other" (sockets, fifos): skipped by design.
    }
    return .ok;
}

test "CopyOpts maps the wire strings, defaulting to merge + overwrite" {
    const t = std.testing;
    const plain = CopyOpts.fromSpec(.{});
    try t.expectEqual(@as(@FieldType(CopyOpts, "conflict"), .overwrite), plain.conflict);
    try t.expect(!plain.replace);
    const skip = CopyOpts.fromSpec(.{ .conflict = "skip", .dir_mode = "merge" });
    try t.expectEqual(@as(@FieldType(CopyOpts, "conflict"), .skip), skip.conflict);
    try t.expect(!skip.replace);
    const both = CopyOpts.fromSpec(.{ .conflict = "keep_both", .dir_mode = "replace", .@"resume" = true });
    try t.expectEqual(@as(@FieldType(CopyOpts, "conflict"), .keep_both), both.conflict);
    try t.expect(both.replace and both.allow_resume);
    // An unknown policy is not an error: it falls back to what the
    // verb did before the option existed.
    try t.expectEqual(@as(@FieldType(CopyOpts, "conflict"), .overwrite), CopyOpts.fromSpec(.{ .conflict = "nonsense" }).conflict);
}

test "uniqueInDir walks past every name already on disk" {
    const t = std.testing;
    const td = pathz.TempDir.make("fsjob-uniq") orelse return error.SkipZigTest;
    defer td.remove();
    const dir = td.path();
    var buf: [512]u8 = undefined;
    // Nothing taken yet.
    try t.expectEqualStrings("a (copy).txt", uniqueInDir(dir, "a.txt", false, &buf).?);
    for ([_][]const u8{ "a (copy).txt", "a (copy 2).txt" }) |name| {
        var z: [4096]u8 = undefined;
        var pb: [4096]u8 = undefined;
        const p = try std.fmt.bufPrint(&pb, "{s}/{s}", .{ dir, name });
        const f = c.fopen(try pathz.pathZ(&z, p), "wb") orelse return error.SkipZigTest;
        _ = c.fclose(f);
    }
    try t.expectEqualStrings("a (copy 3).txt", uniqueInDir(dir, "a.txt", false, &buf).?);
    // A directory keeps every dot of its name.
    try t.expectEqualStrings("v1.0 (copy)", uniqueInDir(dir, "v1.0", true, &buf).?);
}

test "copyOneFile resumes only on matching prefix hash" {
    const t = std.testing;
    const td = pathz.TempDir.make("fsjob") orelse return error.SkipZigTest;
    defer td.remove();
    const dir = td.path();

    var src_buf: [4096]u8 = undefined;
    var sw = std.Io.Writer.fixed(&src_buf);
    try sw.print("{s}/src.bin", .{dir});
    const src = sw.buffered();
    var dst_buf: [4096]u8 = undefined;
    var dw2 = std.Io.Writer.fixed(&dst_buf);
    try dw2.print("{s}/dst.bin", .{dir});
    const dst = dw2.buffered();
    var part_buf: [4096]u8 = undefined;
    var pw = std.Io.Writer.fixed(&part_buf);
    try pw.print("{s}/dst.bin" ++ PART_SUFFIX, .{dir});
    const part = pw.buffered();

    // 1MB deterministic source.
    const data = try t.allocator.alloc(u8, 1 << 20);
    defer t.allocator.free(data);
    for (data, 0..) |*b, i| b.* = @truncate(i *% 13 +% 5);
    {
        var z: [4096]u8 = undefined;
        const f = c.fopen(try pathz.pathZ(&z, src), "wb") orelse return error.SkipZigTest;
        defer _ = c.fclose(f);
        try t.expect(c.fwrite(data.ptr, 1, data.len, f) == data.len);
    }
    // Seed a VALID partial: first 256KB.
    {
        var z: [4096]u8 = undefined;
        const f = c.fopen(try pathz.pathZ(&z, part), "wb") orelse return error.SkipZigTest;
        defer _ = c.fclose(f);
        try t.expect(c.fwrite(data.ptr, 1, 256 * 1024, f) == 256 * 1024);
    }
    var st: c.struct_stat = undefined;
    try t.expect(statOf(src, &st, true));
    // Quiet, and NOT optionally: progress lines go to fd 1, which
    // under `zig build test --listen=-` is the build runner's IPC
    // pipe. Emitting into it corrupts the protocol and wedges the
    // run -- the "test runner hangs" this file caused for a while.
    var progress = Progress{ .total = data.len, .quiet = true };
    switch (copyOneFile(src, dst, st, true, false, false, &progress)) {
        .ok => {},
        else => return error.TestUnexpectedResult,
    }
    try t.expectEqual(@as(u64, 256 * 1024), progress.resumed);
    const out_h = hashPrefix(dst, data.len, null).?;
    var expect_h: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(data, &expect_h, .{});
    try t.expectEqualSlices(u8, &expect_h, &out_h);

    // Seed a CORRUPT partial → restart from 0.
    {
        var z: [4096]u8 = undefined;
        const f = c.fopen(try pathz.pathZ(&z, part), "wb") orelse return error.SkipZigTest;
        defer _ = c.fclose(f);
        var junk: [1024]u8 = @splat(0xAA);
        try t.expect(c.fwrite(&junk, 1, junk.len, f) == junk.len);
    }
    var progress2 = Progress{ .total = data.len, .quiet = true };
    switch (copyOneFile(src, dst, st, true, false, false, &progress2)) {
        .ok => {},
        else => return error.TestUnexpectedResult,
    }
    try t.expectEqual(@as(u64, 0), progress2.resumed);
    const out_h2 = hashPrefix(dst, data.len, null).?;
    try t.expectEqualSlices(u8, &expect_h, &out_h2);
}
