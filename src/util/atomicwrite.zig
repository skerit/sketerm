//! Durable whole-file replacement through a unique sibling stage.

const std = @import("std");
const c = @import("cbindings");

pub const Error = error{
    NameTooLong,
    NotFound,
    StatFailed,
    ParentOpenFailed,
    OpenFailed,
    PermissionDenied,
    ReadOnlyFileSystem,
    PermissionFailed,
    WriteFailed,
    DataSyncFailed,
    CloseFailed,
    RenameFailed,
    DeleteFailed,
};

pub const MAX_PATH = 4096;
const STAGE_ATTEMPTS = 128;
var next_stage = std.atomic.Value(u64).init(1);

const SyncPolicy = enum { durable, recoverable_cache };
const ModePolicy = enum { preserve_existing, exact };

const PosixOps = struct {
    fn open(_: *@This(), path: [*:0]const u8, flags: c_int, mode: c.mode_t) c_int {
        return c.open(path, flags, mode);
    }

    fn lstat(_: *@This(), path: [*:0]const u8, st: *c.struct_stat) c_int {
        return c.lstat(path, st);
    }

    fn fchmod(_: *@This(), fd: c_int, mode: c.mode_t) c_int {
        return c.fchmod(fd, mode);
    }

    fn write(_: *@This(), fd: c_int, bytes: [*]const u8, len: usize) isize {
        return c.write(fd, bytes, len);
    }

    fn fsync(_: *@This(), fd: c_int) c_int {
        return c.fsync(fd);
    }

    fn close(_: *@This(), fd: c_int) c_int {
        return c.close(fd);
    }

    fn unlink(_: *@This(), path: [*:0]const u8) c_int {
        return c.unlink(path);
    }

    fn renameFile(_: *@This(), from: [*:0]const u8, to: [*:0]const u8) c_int {
        return c.rename(from, to);
    }
};

/// Atomically replace `path`, preserving an existing regular file's mode.
pub fn writeFile(path: []const u8, bytes: []const u8, create_mode: u32) Error!void {
    var ops: PosixOps = .{};
    return writeFileWithOps(&ops, path, bytes, create_mode, .durable, .preserve_existing);
}

/// Atomically replace `path` with exactly `mode`, including on replacement.
pub fn writeFileExact(path: []const u8, bytes: []const u8, mode: u32) Error!void {
    var ops: PosixOps = .{};
    return writeFileWithOps(&ops, path, bytes, mode, .durable, .exact);
}

/// Atomically replace a rebuildable cache file without forcing it to stable storage.
pub fn writeCacheFile(path: []const u8, bytes: []const u8, mode: u32) Error!void {
    var ops: PosixOps = .{};
    return writeFileWithOps(&ops, path, bytes, mode, .recoverable_cache, .exact);
}

/// Durably delete one file by syncing its parent after unlink.
pub fn deleteFile(path: []const u8) Error!void {
    if (path.len == 0 or path.len >= MAX_PATH) return error.NameTooLong;
    var path_buf: [MAX_PATH:0]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return error.NameTooLong;
    const parent = std.fs.path.dirname(path) orelse ".";
    var parent_buf: [MAX_PATH:0]u8 = undefined;
    const parent_z = std.fmt.bufPrintZ(&parent_buf, "{s}", .{parent}) catch return error.NameTooLong;
    const parent_fd = c.open(parent_z.ptr, c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC, @as(c.mode_t, 0));
    if (parent_fd < 0) return syscallError(error.ParentOpenFailed);
    defer _ = c.close(parent_fd);
    if (c.unlink(path_z.ptr) != 0) return syscallError(error.DeleteFailed);
    // The unlink is committed and cannot be rolled back. Losing the
    // directory sync weakens crash durability, but reporting it would tell
    // the caller the file is still there when it is already gone.
    _ = c.fsync(parent_fd);
}

const PosixFileWriter = struct {
    fn write(_: *@This(), path: []const u8, bytes: []const u8, create_mode: u32) Error!void {
        return writeFile(path, bytes, create_mode);
    }
};

/// Serialize at most `max_bytes` before atomically replacing `path`.
pub fn writeSerialized(
    allocator: std.mem.Allocator,
    path: []const u8,
    max_bytes: usize,
    create_mode: u32,
    value: anytype,
    comptime serialise: anytype,
) !void {
    var file_writer: PosixFileWriter = .{};
    return writeSerializedWith(
        allocator,
        path,
        max_bytes,
        create_mode,
        value,
        serialise,
        &file_writer,
    );
}

fn writeSerializedWith(
    allocator: std.mem.Allocator,
    path: []const u8,
    max_bytes: usize,
    create_mode: u32,
    value: anytype,
    comptime serialise: anytype,
    file_writer: anytype,
) !void {
    // Allocating gives formatters their normal growable-writer semantics;
    // the fixed backing allocator turns the load limit into a hard ceiling.
    const storage = try allocator.alloc(u8, max_bytes);
    defer allocator.free(storage);
    var bounded = std.heap.FixedBufferAllocator.init(storage);
    var out = std.Io.Writer.Allocating.initCapacity(bounded.allocator(), max_bytes) catch
        return error.OutOfMemory;
    defer out.deinit();

    serialise(value, &out.writer) catch |err| {
        // The bounded allocator is the only source of Writer failure here.
        if (err == error.WriteFailed) return error.OutputTooLarge;
        return err;
    };
    try file_writer.write(path, out.written(), create_mode);
}

fn syscallError(fallback: Error) Error {
    return switch (std.c._errno().*) {
        c.ENOENT => error.NotFound,
        c.EACCES, c.EPERM => error.PermissionDenied,
        c.EROFS => error.ReadOnlyFileSystem,
        else => fallback,
    };
}

fn writeFileWithOps(
    ops: anytype,
    path: []const u8,
    bytes: []const u8,
    create_mode: u32,
    sync_policy: SyncPolicy,
    mode_policy: ModePolicy,
) Error!void {
    if (path.len == 0 or path.len >= MAX_PATH) return error.NameTooLong;

    var dst_buf: [MAX_PATH:0]u8 = undefined;
    const dst = std.fmt.bufPrintZ(&dst_buf, "{s}", .{path}) catch return error.NameTooLong;
    const parent = std.fs.path.dirname(path) orelse ".";
    var parent_buf: [MAX_PATH:0]u8 = undefined;
    const parent_z = std.fmt.bufPrintZ(&parent_buf, "{s}", .{parent}) catch return error.NameTooLong;

    var install_mode: c.mode_t = @intCast(create_mode & 0o777);
    if (mode_policy == .preserve_existing) {
        var target_stat: c.struct_stat = undefined;
        if (ops.lstat(dst.ptr, &target_stat) == 0) {
            if ((target_stat.st_mode & c.S_IFMT) == c.S_IFREG)
                install_mode = @intCast(target_stat.st_mode & 0o777);
        } else if (std.c._errno().* != c.ENOENT) {
            return syscallError(error.StatFailed);
        }
    }

    // Durable replacements hold the directory open across the install so
    // the final sync names the directory in which the rename happened.
    const parent_fd = if (sync_policy == .durable)
        ops.open(parent_z.ptr, c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC, 0)
    else
        -1;
    if (sync_policy == .durable and parent_fd < 0)
        return syscallError(error.ParentOpenFailed);
    defer {
        if (parent_fd >= 0) _ = ops.close(parent_fd);
    }

    var stage_buf: [MAX_PATH + 64:0]u8 = undefined;
    var stage: [:0]u8 = undefined;
    var fd: c_int = -1;
    for (0..STAGE_ATTEMPTS) |_| {
        const serial = next_stage.fetchAdd(1, .monotonic);
        stage = std.fmt.bufPrintZ(&stage_buf, "{s}.sketerm-tmp-{d}-{x}", .{
            path,
            c.getpid(),
            serial,
        }) catch return error.NameTooLong;
        fd = ops.open(
            stage.ptr,
            c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC | c.O_NOFOLLOW,
            install_mode,
        );
        if (fd >= 0) break;
        if (std.c._errno().* != c.EEXIST) return syscallError(error.OpenFailed);
    }
    if (fd < 0) return error.OpenFailed;

    var stage_exists = true;
    defer {
        if (stage_exists) _ = ops.unlink(stage.ptr);
    }
    var stage_open = true;
    defer {
        if (stage_open) _ = ops.close(fd);
    }

    // Apply the exact requested/preserved access bits instead of allowing
    // umask or a reused process environment to broaden or narrow them.
    if (ops.fchmod(fd, install_mode) != 0)
        return syscallError(error.PermissionFailed);

    var off: usize = 0;
    while (off < bytes.len) {
        const n = ops.write(fd, bytes.ptr + off, bytes.len - off);
        if (n < 0 and std.c._errno().* == c.EINTR) continue;
        if (n < 0) return syscallError(error.WriteFailed);
        // A zero-length write is not an error, so errno still holds
        // whatever an earlier call left there; classifying it would
        // invent a NotFound/PermissionDenied that never happened.
        if (n == 0) return error.WriteFailed;
        off += @intCast(n);
    }
    // A signal during fsync must not discard a fully written stage.
    if (sync_policy == .durable) {
        while (ops.fsync(fd) != 0) {
            if (std.c._errno().* == c.EINTR) continue;
            return syscallError(error.DataSyncFailed);
        }
    }

    stage_open = false;
    if (ops.close(fd) != 0) return syscallError(error.CloseFailed);
    if (ops.renameFile(stage.ptr, dst.ptr) != 0)
        return syscallError(error.RenameFailed);
    stage_exists = false;

    // The destination is committed now and cannot be rolled back safely.
    // A directory-sync failure weakens crash durability, but must not be
    // reported as though the previous file were still in place: FUSE and
    // network filesystems fail fsync() on a directory fd outright, and a
    // caller that rolls back there discards data that is already on disk.
    if (sync_policy == .durable) _ = ops.fsync(parent_fd);
}

const FaultOps = struct {
    short_write: usize = std.math.maxInt(usize),
    fail_write_after: ?usize = null,
    fail_data_sync: bool = false,
    eintr_data_syncs: usize = 0,
    fail_parent_sync: bool = false,
    fail_rename: bool = false,
    collide_once: bool = false,
    written: usize = 0,
    parent_fd: c_int = -1,
    data_syncs: usize = 0,
    parent_syncs: usize = 0,
    last_stage: [MAX_PATH + 64:0]u8 = undefined,
    last_stage_len: usize = 0,
    collision_stage: [MAX_PATH + 64:0]u8 = undefined,
    collision_stage_len: usize = 0,

    fn remember(buf: *[MAX_PATH + 64:0]u8, len: *usize, path: [*:0]const u8) void {
        const value = std.mem.span(path);
        @memcpy(buf[0..value.len], value);
        buf[value.len] = 0;
        len.* = value.len;
    }

    fn open(self: *@This(), path: [*:0]const u8, flags: c_int, mode: c.mode_t) c_int {
        if ((flags & c.O_DIRECTORY) != 0) {
            const fd = c.open(path, flags, mode);
            self.parent_fd = fd;
            return fd;
        }
        if ((flags & c.O_EXCL) != 0) {
            remember(&self.last_stage, &self.last_stage_len, path);
            if (self.collide_once) {
                self.collide_once = false;
                const stale = c.open(path, flags, mode);
                if (stale >= 0) {
                    _ = c.close(stale);
                    remember(&self.collision_stage, &self.collision_stage_len, path);
                    std.c._errno().* = c.EEXIST;
                    return -1;
                }
                return stale;
            }
        }
        return c.open(path, flags, mode);
    }

    fn lstat(_: *@This(), path: [*:0]const u8, st: *c.struct_stat) c_int {
        return c.lstat(path, st);
    }

    fn fchmod(_: *@This(), fd: c_int, mode: c.mode_t) c_int {
        return c.fchmod(fd, mode);
    }

    fn write(self: *@This(), fd: c_int, bytes: [*]const u8, len: usize) isize {
        if (self.fail_write_after) |limit| {
            if (self.written >= limit) {
                std.c._errno().* = c.EIO;
                return -1;
            }
        }
        var take = @min(len, self.short_write);
        if (self.fail_write_after) |limit| take = @min(take, limit - self.written);
        const n = c.write(fd, bytes, take);
        if (n > 0) self.written += @intCast(n);
        return n;
    }

    fn fsync(self: *@This(), fd: c_int) c_int {
        if (fd == self.parent_fd) {
            self.parent_syncs += 1;
            if (self.fail_parent_sync) {
                // EROFS is what made the old failure indistinguishable from
                // "the write never happened"; keep that exact laundering here.
                std.c._errno().* = c.EROFS;
                return -1;
            }
        } else if (self.fail_data_sync) {
            std.c._errno().* = c.EIO;
            return -1;
        } else if (self.eintr_data_syncs > 0) {
            self.eintr_data_syncs -= 1;
            std.c._errno().* = c.EINTR;
            return -1;
        } else {
            self.data_syncs += 1;
        }
        return c.fsync(fd);
    }

    fn close(_: *@This(), fd: c_int) c_int {
        return c.close(fd);
    }

    fn unlink(_: *@This(), path: [*:0]const u8) c_int {
        return c.unlink(path);
    }

    fn renameFile(self: *@This(), from: [*:0]const u8, to: [*:0]const u8) c_int {
        if (self.fail_rename) {
            std.c._errno().* = c.EIO;
            return -1;
        }
        return c.rename(from, to);
    }

    fn lastStage(self: *@This()) [:0]const u8 {
        return self.last_stage[0..self.last_stage_len :0];
    }

    fn collisionStage(self: *@This()) [:0]const u8 {
        return self.collision_stage[0..self.collision_stage_len :0];
    }
};

fn readTestFile(path: []const u8, buf: []u8) ![]const u8 {
    var path_buf: [MAX_PATH:0]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_buf, "{s}", .{path});
    const fd = c.open(path_z.ptr, c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return error.ReadFailed;
    defer _ = c.close(fd);
    var used: usize = 0;
    while (used < buf.len) {
        const n = c.read(fd, buf.ptr + used, buf.len - used);
        if (n < 0 and std.c._errno().* == c.EINTR) continue;
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        used += @intCast(n);
    }
    return buf[0..used];
}

const SerializedFixture = struct {
    bytes: []const u8,
    fail: bool = false,

    fn serialise(self: *const @This(), writer: *std.Io.Writer) !void {
        try writer.writeAll(self.bytes);
        if (self.fail) return error.SerializationFailed;
    }
};

const FailingFileWriter = struct {
    failure: ?Error = null,
    calls: usize = 0,

    fn write(self: *@This(), path: []const u8, bytes: []const u8, create_mode: u32) Error!void {
        self.calls += 1;
        if (self.failure) |err| return err;
        return writeFile(path, bytes, create_mode);
    }
};

test "writeSerialized preserves the old file across every pre-install failure" {
    const t = std.testing;
    var tmpl = "/tmp/sketerm-serialized-fail-XXXXXX".*;
    const dir = c.mkdtemp(&tmpl) orelse return error.SkipZigTest;
    defer _ = c.rmdir(dir);
    const base = std.mem.span(@as([*:0]u8, @ptrCast(dir)));
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/state.json", .{base});
    var path_z_buf: [512:0]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_z_buf, "{s}", .{path});
    defer _ = c.unlink(path_z.ptr);
    try writeFile(path, "old-valid", 0o600);

    const fixture: SerializedFixture = .{ .bytes = "new-valid" };
    var allocator_config: t.FailingAllocator.Config = .{};
    allocator_config.fail_index = 0;
    var failing_allocator = t.FailingAllocator.init(t.allocator, allocator_config);
    var file_writer: FailingFileWriter = .{};
    try t.expectError(error.OutOfMemory, writeSerializedWith(
        failing_allocator.allocator(),
        path,
        64,
        0o600,
        &fixture,
        SerializedFixture.serialise,
        &file_writer,
    ));
    try t.expect(failing_allocator.has_induced_failure);
    try t.expectEqual(@as(usize, 0), file_writer.calls);

    const broken: SerializedFixture = .{ .bytes = "partial", .fail = true };
    try t.expectError(error.SerializationFailed, writeSerializedWith(
        t.allocator,
        path,
        64,
        0o600,
        &broken,
        SerializedFixture.serialise,
        &file_writer,
    ));
    try t.expectEqual(@as(usize, 0), file_writer.calls);

    const oversized: SerializedFixture = .{ .bytes = "123456789" };
    try t.expectError(error.OutputTooLarge, writeSerializedWith(
        t.allocator,
        path,
        8,
        0o600,
        &oversized,
        SerializedFixture.serialise,
        &file_writer,
    ));
    try t.expectEqual(@as(usize, 0), file_writer.calls);

    file_writer.failure = error.WriteFailed;
    try t.expectError(error.WriteFailed, writeSerializedWith(
        t.allocator,
        path,
        64,
        0o600,
        &fixture,
        SerializedFixture.serialise,
        &file_writer,
    ));
    try t.expectEqual(@as(usize, 1), file_writer.calls);

    file_writer.failure = error.RenameFailed;
    try t.expectError(error.RenameFailed, writeSerializedWith(
        t.allocator,
        path,
        64,
        0o600,
        &fixture,
        SerializedFixture.serialise,
        &file_writer,
    ));
    try t.expectEqual(@as(usize, 2), file_writer.calls);

    var got: [32]u8 = undefined;
    try t.expectEqualStrings("old-valid", try readTestFile(path, &got));
}

test "writeFile completes short writes and syncs the parent" {
    var tmpl = "/tmp/sketerm-atomicwrite-short-XXXXXX".*;
    const dir = c.mkdtemp(&tmpl) orelse return error.SkipZigTest;
    defer _ = c.rmdir(dir);
    const base = std.mem.span(@as([*:0]u8, @ptrCast(dir)));
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/state.json", .{base});
    defer {
        var z: [512:0]u8 = undefined;
        if (std.fmt.bufPrintZ(&z, "{s}", .{path})) |p| _ = c.unlink(p.ptr) else |_| {}
    }

    var ops: FaultOps = .{ .short_write = 3 };
    try writeFileWithOps(&ops, path, "complete short write", 0o600, .durable, .preserve_existing);
    var got: [64]u8 = undefined;
    try std.testing.expectEqualStrings("complete short write", try readTestFile(path, &got));
    try std.testing.expectEqual(@as(usize, 1), ops.parent_syncs);
}

test "writeCacheFile keeps atomic install checks but deliberately skips syncs" {
    var tmpl = "/tmp/sketerm-atomicwrite-cache-XXXXXX".*;
    const dir = c.mkdtemp(&tmpl) orelse return error.SkipZigTest;
    defer _ = c.rmdir(dir);
    const base = std.mem.span(@as([*:0]u8, @ptrCast(dir)));
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/cache.bin", .{base});
    var path_z_buf: [512:0]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_z_buf, "{s}", .{path});
    defer _ = c.unlink(path_z.ptr);

    try writeFile(path, "old-public-cache", 0o644);
    var ops: FaultOps = .{ .short_write = 2, .fail_data_sync = true };
    try writeFileWithOps(&ops, path, "recoverable", 0o600, .recoverable_cache, .exact);
    var got: [32]u8 = undefined;
    try std.testing.expectEqualStrings("recoverable", try readTestFile(path, &got));
    try std.testing.expectEqual(@as(usize, 0), ops.data_syncs);
    try std.testing.expectEqual(@as(usize, 0), ops.parent_syncs);
    var st: c.struct_stat = undefined;
    try std.testing.expect(c.lstat(path_z.ptr, &st) == 0);
    try std.testing.expectEqual(@as(c.mode_t, 0o600), @as(c.mode_t, @intCast(st.st_mode & 0o777)));
}

test "write and data-sync failures preserve the old file and clean the stage" {
    var tmpl = "/tmp/sketerm-atomicwrite-disk-XXXXXX".*;
    const dir = c.mkdtemp(&tmpl) orelse return error.SkipZigTest;
    defer _ = c.rmdir(dir);
    const base = std.mem.span(@as([*:0]u8, @ptrCast(dir)));
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/state.json", .{base});
    defer {
        var z: [512:0]u8 = undefined;
        if (std.fmt.bufPrintZ(&z, "{s}", .{path})) |p| _ = c.unlink(p.ptr) else |_| {}
    }
    try writeFile(path, "old-valid", 0o600);

    var write_ops: FaultOps = .{ .short_write = 2, .fail_write_after = 4 };
    try std.testing.expectError(error.WriteFailed, writeFileWithOps(&write_ops, path, "new-incomplete", 0o600, .durable, .preserve_existing));
    var st: c.struct_stat = undefined;
    try std.testing.expect(c.lstat(write_ops.lastStage().ptr, &st) != 0);
    var got: [64]u8 = undefined;
    try std.testing.expectEqualStrings("old-valid", try readTestFile(path, &got));

    var sync_ops: FaultOps = .{ .fail_data_sync = true };
    try std.testing.expectError(error.DataSyncFailed, writeFileWithOps(&sync_ops, path, "new-unsynced", 0o600, .durable, .preserve_existing));
    try std.testing.expect(c.lstat(sync_ops.lastStage().ptr, &st) != 0);
    try std.testing.expectEqualStrings("old-valid", try readTestFile(path, &got));
}

test "an interrupted data sync is retried and a stalled write is not misclassified" {
    var tmpl = "/tmp/sketerm-atomicwrite-eintr-XXXXXX".*;
    const dir = c.mkdtemp(&tmpl) orelse return error.SkipZigTest;
    defer _ = c.rmdir(dir);
    const base = std.mem.span(@as([*:0]u8, @ptrCast(dir)));
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/state.json", .{base});
    var path_z_buf: [512:0]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_z_buf, "{s}", .{path});
    defer _ = c.unlink(path_z.ptr);

    var eintr_ops: FaultOps = .{ .eintr_data_syncs = 2 };
    try writeFileWithOps(&eintr_ops, path, "survives a signal", 0o600, .durable, .preserve_existing);
    var got: [64]u8 = undefined;
    try std.testing.expectEqualStrings("survives a signal", try readTestFile(path, &got));
    try std.testing.expectEqual(@as(usize, 1), eintr_ops.data_syncs);

    // The destination's lstat leaves ENOENT in errno; a write that returns
    // zero must not be reported through it as though the path were missing.
    var missing_buf: [512]u8 = undefined;
    const missing = try std.fmt.bufPrint(&missing_buf, "{s}/fresh.json", .{base});
    var stall_ops: FaultOps = .{ .short_write = 0 };
    try std.testing.expectError(error.WriteFailed, writeFileWithOps(
        &stall_ops,
        missing,
        "never lands",
        0o600,
        .durable,
        .preserve_existing,
    ));
    var st: c.struct_stat = undefined;
    try std.testing.expect(c.lstat(stall_ops.lastStage().ptr, &st) != 0);
}

test "a failed parent sync reports the committed replacement as saved" {
    var tmpl = "/tmp/sketerm-atomicwrite-dirsync-XXXXXX".*;
    const dir = c.mkdtemp(&tmpl) orelse return error.SkipZigTest;
    defer _ = c.rmdir(dir);
    const base = std.mem.span(@as([*:0]u8, @ptrCast(dir)));
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/state.json", .{base});
    var path_z_buf: [512:0]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_z_buf, "{s}", .{path});
    defer _ = c.unlink(path_z.ptr);
    try writeFile(path, "old-valid", 0o600);

    // A directory fsync that fails (FUSE, NFS) must not be laundered into a
    // "nothing was written" error: the rename already committed, so a caller
    // that rolls back or warns here discards data that is on disk.
    var ops: FaultOps = .{ .fail_parent_sync = true };
    try writeFileWithOps(&ops, path, "new-committed", 0o600, .durable, .preserve_existing);
    try std.testing.expectEqual(@as(usize, 1), ops.parent_syncs);
    var got: [64]u8 = undefined;
    try std.testing.expectEqualStrings("new-committed", try readTestFile(path, &got));
    var st: c.struct_stat = undefined;
    try std.testing.expect(c.lstat(ops.lastStage().ptr, &st) != 0);
}

test "a stale exclusive stage is bypassed without deleting it" {
    var tmpl = "/tmp/sketerm-atomicwrite-stale-XXXXXX".*;
    const dir = c.mkdtemp(&tmpl) orelse return error.SkipZigTest;
    defer _ = c.rmdir(dir);
    const base = std.mem.span(@as([*:0]u8, @ptrCast(dir)));
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/state.json", .{base});
    defer {
        var z: [512:0]u8 = undefined;
        if (std.fmt.bufPrintZ(&z, "{s}", .{path})) |p| _ = c.unlink(p.ptr) else |_| {}
    }

    var ops: FaultOps = .{ .collide_once = true };
    try writeFileWithOps(&ops, path, "new", 0o600, .durable, .preserve_existing);
    defer _ = c.unlink(ops.collisionStage().ptr);
    var st: c.struct_stat = undefined;
    try std.testing.expect(c.lstat(ops.collisionStage().ptr, &st) == 0);
    var got: [16]u8 = undefined;
    try std.testing.expectEqualStrings("new", try readTestFile(path, &got));
}

test "rename failure preserves the old file and removes its stage" {
    var tmpl = "/tmp/sketerm-atomicwrite-rename-XXXXXX".*;
    const dir = c.mkdtemp(&tmpl) orelse return error.SkipZigTest;
    defer _ = c.rmdir(dir);
    const base = std.mem.span(@as([*:0]u8, @ptrCast(dir)));
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/state.json", .{base});
    defer {
        var z: [512:0]u8 = undefined;
        if (std.fmt.bufPrintZ(&z, "{s}", .{path})) |p| _ = c.unlink(p.ptr) else |_| {}
    }
    try writeFile(path, "old-valid", 0o600);

    var ops: FaultOps = .{ .fail_rename = true };
    try std.testing.expectError(error.RenameFailed, writeFileWithOps(&ops, path, "new", 0o600, .durable, .preserve_existing));
    var st: c.struct_stat = undefined;
    try std.testing.expect(c.lstat(ops.lastStage().ptr, &st) != 0);
    var got: [32]u8 = undefined;
    try std.testing.expectEqualStrings("old-valid", try readTestFile(path, &got));
}

test "writeFile creates restrictive files and preserves replacement mode" {
    var tmpl = "/tmp/sketerm-atomicwrite-mode-XXXXXX".*;
    const dir = c.mkdtemp(&tmpl) orelse return error.SkipZigTest;
    defer _ = c.rmdir(dir);
    const base = std.mem.span(@as([*:0]u8, @ptrCast(dir)));
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/state.json", .{base});
    var path_z_buf: [512:0]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_z_buf, "{s}", .{path});
    defer _ = c.unlink(path_z.ptr);

    try writeFile(path, "first", 0o600);
    var st: c.struct_stat = undefined;
    try std.testing.expect(c.lstat(path_z.ptr, &st) == 0);
    try std.testing.expectEqual(@as(c.mode_t, 0o600), @as(c.mode_t, @intCast(st.st_mode & 0o777)));
    try std.testing.expect(c.chmod(path_z.ptr, @as(c.mode_t, 0o640)) == 0);
    try writeFile(path, "second-and-longer", 0o600);
    try std.testing.expect(c.lstat(path_z.ptr, &st) == 0);
    try std.testing.expectEqual(@as(c.mode_t, 0o640), @as(c.mode_t, @intCast(st.st_mode & 0o777)));
    var got: [64]u8 = undefined;
    try std.testing.expectEqualStrings("second-and-longer", try readTestFile(path, &got));
}

test "writeFileExact replaces an existing file with the requested mode" {
    var tmpl = "/tmp/sketerm-atomicwrite-exact-mode-XXXXXX".*;
    const dir = c.mkdtemp(&tmpl) orelse return error.SkipZigTest;
    defer _ = c.rmdir(dir);
    const base = std.mem.span(@as([*:0]u8, @ptrCast(dir)));
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/state.json", .{base});
    var path_z_buf: [512:0]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_z_buf, "{s}", .{path});
    defer _ = c.unlink(path_z.ptr);

    try writeFile(path, "public", 0o644);
    try writeFileExact(path, "private", 0o600);
    var st: c.struct_stat = undefined;
    try std.testing.expect(c.lstat(path_z.ptr, &st) == 0);
    try std.testing.expectEqual(@as(c.mode_t, 0o600), @as(c.mode_t, @intCast(st.st_mode & 0o777)));
    var got: [16]u8 = undefined;
    try std.testing.expectEqualStrings("private", try readTestFile(path, &got));
}

test "concurrent writers install one complete value without stage collisions" {
    var tmpl = "/tmp/sketerm-atomicwrite-concurrent-XXXXXX".*;
    const dir = c.mkdtemp(&tmpl) orelse return error.SkipZigTest;
    defer _ = c.rmdir(dir);
    const base = std.mem.span(@as([*:0]u8, @ptrCast(dir)));
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/state.json", .{base});
    var path_z_buf: [512:0]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_z_buf, "{s}", .{path});
    defer _ = c.unlink(path_z.ptr);

    const a = try std.testing.allocator.alloc(u8, 256 * 1024);
    defer std.testing.allocator.free(a);
    const b = try std.testing.allocator.alloc(u8, 256 * 1024);
    defer std.testing.allocator.free(b);
    @memset(a, 'a');
    @memset(b, 'b');
    const Ctx = struct {
        path: []const u8,
        bytes: []const u8,
        failed: bool = false,

        fn run(self: *@This()) void {
            writeFile(self.path, self.bytes, 0o600) catch {
                self.failed = true;
            };
        }
    };
    var ca: Ctx = .{ .path = path, .bytes = a };
    var cb: Ctx = .{ .path = path, .bytes = b };
    const ta = try std.Thread.spawn(.{}, Ctx.run, .{&ca});
    const tb = try std.Thread.spawn(.{}, Ctx.run, .{&cb});
    ta.join();
    tb.join();
    try std.testing.expect(!ca.failed and !cb.failed);

    const got = try std.testing.allocator.alloc(u8, a.len);
    defer std.testing.allocator.free(got);
    const contents = try readTestFile(path, got);
    try std.testing.expect(contents.len == a.len);
    try std.testing.expect(std.mem.eql(u8, contents, a) or std.mem.eql(u8, contents, b));
}

test "writeFile refuses an unopenable destination" {
    try std.testing.expectError(
        error.NotFound,
        writeFile("/proc/definitely/not/writable", "x", 0o600),
    );
    const long = [_]u8{'a'} ** MAX_PATH;
    try std.testing.expectError(error.NameTooLong, writeFile(&long, "x", 0o600));
}

test "deleteFile removes a file durably and reports absence" {
    var tmpl = "/tmp/sketerm-atomicwrite-delete-XXXXXX".*;
    const dir = c.mkdtemp(&tmpl) orelse return error.SkipZigTest;
    defer _ = c.rmdir(dir);
    const base = std.mem.span(@as([*:0]u8, @ptrCast(dir)));
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/state.json", .{base});
    var path_z_buf: [512:0]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_z_buf, "{s}", .{path});

    try writeFile(path, "state", 0o600);
    try deleteFile(path);
    var st: c.struct_stat = undefined;
    try std.testing.expect(c.lstat(path_z.ptr, &st) != 0);
    try std.testing.expectError(error.NotFound, deleteFile(path));
}
