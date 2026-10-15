//! Freedesktop trash jobs: move to trash and restore.

const std = @import("std");
const c = @import("../../c.zig").c;
const pathz = @import("../../util/pathz.zig");
const fsserve = @import("../fsserve.zig");
const platform = @import("../../util/platform.zig");
const fsjob = @import("../fsjob.zig");
const Job = fsjob.Job;
const common = @import("common.zig");
const statOf = common.statOf;

// ── freedesktop trash ────────────────────────────────────────────

fn trashRoot(buf: []u8) ?[]const u8 {
    return fsserve.trashRoot(fsserve.envOpt("XDG_DATA_HOME"), fsserve.envOpt("HOME"), buf);
}

fn ensureTrashDirs(root: []const u8) bool {
    var files: [4096]u8 = undefined;
    var info: [4096]u8 = undefined;
    const fp = std.fmt.bufPrint(&files, "{s}/files", .{root}) catch return false;
    const ip = std.fmt.bufPrint(&info, "{s}/info", .{root}) catch return false;
    pathz.makeParentDirs(fp) catch return false;
    var z: [4096]u8 = undefined;
    const rz = pathz.pathZ(&z, root) catch return false;
    if (c.mkdir(rz, 0o700) != 0 and std.posix.errno(@as(c_int, -1)) != .EXIST) return false;
    const fz = pathz.pathZ(&z, fp) catch return false;
    if (c.mkdir(fz, 0o700) != 0 and std.posix.errno(@as(c_int, -1)) != .EXIST) return false;
    const iz = pathz.pathZ(&z, ip) catch return false;
    return c.mkdir(iz, 0o700) == 0 or std.posix.errno(@as(c_int, -1)) == .EXIST;
}

fn deletionStamp(buf: *[32]u8) []const u8 {
    var now: c.time_t = c.time(null);
    var tm: c.struct_tm = undefined;
    _ = c.localtime_r(&now, &tm);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
        tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec,
    }) catch "1970-01-01T00:00:00";
}

pub fn runTrash(job: *const Job) u8 {
    const spec = job.spec;
    if (spec.src.len <= 1) return job.emitError("refusing to trash root");
    var root_buf: [4096]u8 = undefined;
    const home_root = trashRoot(&root_buf) orelse return job.emitError("cannot locate trash directory");
    switch (trashInto(job, spec.src, home_root)) {
        .ok => return 0,
        .fail => return job.emitErrno("move to trash"),
        .xdev => {},
    }
    // Different filesystem: freedesktop $topdir/.Trash-$uid fallback.
    var mp_buf: [4096]u8 = undefined;
    const mp = deviceMountpoint(spec.src, &mp_buf) orelse return job.emitError("move to trash: cross-device and no mountpoint found");
    var top_buf: [4096]u8 = undefined;
    const top_root = std.fmt.bufPrint(&top_buf, "{s}/.Trash-{d}", .{
        if (mp.len == 1) "" else mp, c.getuid(),
    }) catch return job.emitError("trash path too long");
    return switch (trashInto(job, spec.src, top_root)) {
        .ok => 0,
        else => job.emitErrno("move to trash (topdir)"),
    };
}

const TrashResult = enum { ok, xdev, fail };

/// One trash attempt into `root` (files/ + info/ created as needed).
/// Emits the done event itself on success.
fn trashInto(job: *const Job, src: []const u8, root: []const u8) TrashResult {
    if (!ensureTrashDirs(root)) return .fail;
    const base = std.fs.path.basename(src);
    var name_buf: [512]u8 = undefined;
    var files_buf: [4096]u8 = undefined;
    var info_buf: [4096]u8 = undefined;
    var attempt: u32 = 0;
    var trashed: []const u8 = undefined;
    var info_path: []const u8 = undefined;
    while (attempt < 10000) : (attempt += 1) {
        const name = if (attempt == 0)
            std.fmt.bufPrint(&name_buf, "{s}", .{base}) catch return .fail
        else
            std.fmt.bufPrint(&name_buf, "{s}.{d}", .{ base, attempt }) catch return .fail;
        trashed = std.fmt.bufPrint(&files_buf, "{s}/files/{s}", .{ root, name }) catch return .fail;
        info_path = std.fmt.bufPrint(&info_buf, "{s}/info/{s}.trashinfo", .{ root, name }) catch return .fail;
        var z: [4096]u8 = undefined;
        var st: c.struct_stat = undefined;
        if (c.lstat(pathz.pathZ(&z, trashed) catch return .fail, &st) != 0 and
            std.posix.errno(@as(c_int, -1)) == .NOENT) break;
    }
    if (attempt == 10000) return .fail;

    var text: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&text);
    w.writeAll("[Trash Info]\nPath=") catch return .fail;
    @import("../../util/percent.zig").encode(&w, .file_uri, src) catch return .fail;
    var stamp_buf: [32]u8 = undefined;
    w.print("\nDeletionDate={s}\n", .{deletionStamp(&stamp_buf)}) catch return .fail;
    var iz: [4096]u8 = undefined;
    const ip = pathz.pathZ(&iz, info_path) catch return .fail;
    const info = c.fopen(ip, "wx") orelse return .fail;
    if (c.fwrite(w.buffered().ptr, 1, w.buffered().len, info) != w.buffered().len or c.fclose(info) != 0) {
        _ = c.unlink(ip);
        return .fail;
    }
    var sz: [4096]u8 = undefined;
    var tz: [4096]u8 = undefined;
    if (c.rename(pathz.pathZ(&sz, src) catch return .fail, pathz.pathZ(&tz, trashed) catch return .fail) != 0) {
        const failed_errno = std.posix.errno(@as(c_int, -1));
        _ = c.unlink(ip);
        return if (failed_errno == .XDEV) .xdev else .fail;
    }
    job.emit(.{ .ev = "done", .done = @as(u64, 1), .total = @as(u64, 1), .path = trashed, .text = info_path });
    return .ok;
}

/// The mountpoint holding `path`: walk parents until st_dev changes.
fn deviceMountpoint(path: []const u8, buf: []u8) ?[]const u8 {
    var st: c.struct_stat = undefined;
    if (!statOf(path, &st, false)) return null;
    const dev = st.st_dev;
    var cur_buf: [4096]u8 = undefined;
    var cur: []const u8 = std.fs.path.dirname(path) orelse "/";
    if (cur.len > cur_buf.len) return null;
    @memcpy(cur_buf[0..cur.len], cur);
    cur = cur_buf[0..cur.len];
    while (cur.len > 1) {
        const parent = std.fs.path.dirname(cur) orelse "/";
        var pst: c.struct_stat = undefined;
        if (!statOf(parent, &pst, false)) break;
        if (pst.st_dev != dev) break;
        const plen = parent.len;
        std.mem.copyForwards(u8, cur_buf[0..plen], parent);
        cur = cur_buf[0..plen];
    }
    if (cur.len > buf.len) return null;
    @memcpy(buf[0..cur.len], cur);
    return buf[0..cur.len];
}

pub fn runTrashRestore(job: *const Job) u8 {
    const spec = job.spec;
    if (spec.dst.len == 0) return job.emitError("trash_restore needs original destination");
    pathz.makeParentDirs(spec.dst) catch return job.emitError("cannot create restore parent");
    var sz: [4096]u8 = undefined;
    var dz: [4096]u8 = undefined;
    const src = pathz.pathZ(&sz, spec.src) catch return job.emitError("path too long");
    const dst = pathz.pathZ(&dz, spec.dst) catch return job.emitError("path too long");
    switch (platform.renameNoReplace(src, dst)) {
        .ok => {},
        .exists => return job.emitErrorKind("permanent", "restore from trash: destination already exists; item remains in Trash"),
        .cross_device => return job.emitError("restore from trash: XDEV"),
        .failed => |err| {
            var buf: [128]u8 = undefined;
            return job.emitError(std.fmt.bufPrint(&buf, "restore from trash: {s}", .{@tagName(err)}) catch "restore from trash failed");
        },
    }
    if (spec.pattern.len > 0) {
        var iz: [4096]u8 = undefined;
        _ = c.unlink(pathz.pathZ(&iz, spec.pattern) catch return job.emitError("trash info path too long"));
    }
    job.emit(.{ .ev = "done", .done = @as(u64, 1), .total = @as(u64, 1) });
    return 0;
}

test "trash restore preserves collisions and retries without losing payload or metadata" {
    const t = std.testing;
    const saved_state = fsjob.durable_state;
    defer fsjob.durable_state = saved_state;

    const Collision = enum { file, directory, dangling_symlink };
    for ([_]Collision{ .file, .directory, .dangling_symlink }) |collision| {
        const td = pathz.TempDir.make("restore-collision") orelse return error.SkipZigTest;
        defer td.remove();
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const src = try std.fmt.allocPrintSentinel(a, "{s}/trashed", .{td.path()}, 0);
        const dst = try std.fmt.allocPrintSentinel(a, "{s}/restored", .{td.path()}, 0);
        const info = try std.fmt.allocPrintSentinel(a, "{s}/item.trashinfo", .{td.path()}, 0);
        const metadata = try std.fmt.allocPrint(a, "[Trash Info]\nPath={s}\n", .{dst});
        const payload = "original trashed contents";
        const payload_path = if (collision == .directory) blk: {
            try t.expect(c.mkdir(src.ptr, 0o700) == 0);
            break :blk try std.fmt.allocPrintSentinel(a, "{s}/child", .{src}, 0);
        } else src;
        const files = [_]struct { path: [:0]const u8, text: []const u8 }{
            .{ .path = payload_path, .text = payload },
            .{ .path = info, .text = metadata },
        };
        for (files) |file| {
            const f = c.fopen(file.path.ptr, "wb") orelse return error.TestUnexpectedResult;
            defer _ = c.fclose(f);
            try t.expectEqual(file.text.len, c.fwrite(file.text.ptr, 1, file.text.len, f));
        }
        switch (collision) {
            .file => {
                const f = c.fopen(dst.ptr, "wb") orelse return error.TestUnexpectedResult;
                defer _ = c.fclose(f);
                const replacement = "replacement contents";
                try t.expectEqual(replacement.len, c.fwrite(replacement.ptr, 1, replacement.len, f));
            },
            .directory => try t.expect(c.mkdir(dst.ptr, 0o700) == 0),
            .dangling_symlink => try t.expect(c.symlink("missing-target", dst.ptr) == 0),
        }
        var before: c.struct_stat = undefined;
        try t.expect(c.lstat(dst.ptr, &before) == 0);
        const job = Job{ .allocator = t.allocator, .spec = .{ .src = src, .dst = dst, .pattern = info } };
        fsjob.durable_state = .{ .defer_terminal = true };
        try t.expectEqual(@as(u8, 1), runTrashRestore(&job));
        try t.expectEqualStrings("permanent", fsjob.durable_state.error_kind.slice());
        try t.expectEqualStrings("restore from trash: destination already exists; item remains in Trash", fsjob.durable_state.message.slice());
        try t.expect(std.mem.indexOf(u8, fsjob.durable_state.terminal_event.slice(), "\"ev\":\"error\"") != null);
        var after: c.struct_stat = undefined;
        try t.expect(c.lstat(dst.ptr, &after) == 0);
        try t.expectEqual(before.st_ino, after.st_ino);
        try t.expectEqual(before.st_mode, after.st_mode);
        if (collision == .file) {
            const f = c.fopen(dst.ptr, "rb") orelse return error.TestUnexpectedResult;
            defer _ = c.fclose(f);
            var buf: [128]u8 = undefined;
            const n = c.fread(&buf, 1, buf.len, f);
            try t.expectEqualStrings("replacement contents", buf[0..n]);
        }
        for (files) |file| {
            const f = c.fopen(file.path.ptr, "rb") orelse return error.TestUnexpectedResult;
            defer _ = c.fclose(f);
            var buf: [512]u8 = undefined;
            const n = c.fread(&buf, 1, buf.len, f);
            try t.expectEqualStrings(file.text, buf[0..n]);
        }

        // Retrying after resolving the collision must still restore the
        // original payload, and only then remove its trash metadata.
        try t.expect((if (collision == .directory) c.rmdir(dst.ptr) else c.unlink(dst.ptr)) == 0);
        fsjob.durable_state = .{ .defer_terminal = true };
        try t.expectEqual(@as(u8, 0), runTrashRestore(&job));
        try t.expect(std.mem.indexOf(u8, fsjob.durable_state.terminal_event.slice(), "\"ev\":\"done\"") != null);
        try t.expect(c.lstat(src.ptr, &after) != 0);
        try t.expectEqual(std.posix.E.NOENT, std.posix.errno(@as(c_int, -1)));
        try t.expect(c.lstat(info.ptr, &after) != 0);
        try t.expectEqual(std.posix.E.NOENT, std.posix.errno(@as(c_int, -1)));
        const restored_payload = if (collision == .directory)
            try std.fmt.allocPrintSentinel(a, "{s}/child", .{dst}, 0)
        else
            dst;
        const f = c.fopen(restored_payload.ptr, "rb") orelse return error.TestUnexpectedResult;
        defer _ = c.fclose(f);
        var buf: [128]u8 = undefined;
        const n = c.fread(&buf, 1, buf.len, f);
        try t.expectEqualStrings(payload, buf[0..n]);
    }
}
