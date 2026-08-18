//! Failure-atomic installation of an unpacked WebExtension archive.

const std = @import("std");
const c = @import("cbindings");
const manifest = @import("manifest.zig");
const zip = @import("zip.zig");
const pathz = @import("../../util/pathz.zig");
const platform = @import("../../util/platform.zig");

pub const Error = error{
    BadManifest,
    UnsupportedManifestVersion,
    IdentityMismatch,
    VersionMismatch,
    MissingAsset,
    UnsafeAsset,
    PathTooLong,
    MkdirFailed,
    LockFailed,
    ConcurrentInstall,
    OpenFailed,
    PermissionFailed,
    WriteFailed,
    DataSyncFailed,
    CloseFailed,
    RenameFailed,
    OutOfMemory,
};

const MAX_PATH = 4096;
const MAX_ASSET = 4 * 1024 * 1024;
const STAGE_ATTEMPTS = 128;
var next_stage = std.atomic.Value(u64).init(1);

const PosixWriteOps = struct {
    // `c.mode_t` is c_uint on Linux and c_ushort on Darwin: spelling
    // either concretely here is a hard compile error on the other.
    fn open(_: *@This(), path: [*:0]const u8, flags: c_int, mode: c.mode_t) c_int {
        return c.open(path, flags, mode);
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
};

pub const Transaction = struct {
    gpa: std.mem.Allocator,
    base: []u8,
    id: []u8,
    name: []u8,
    version: []u8,
    dest: []u8,
    stage: []u8,
    lock_fd: c_int,
    phase: enum { staged, committed, done } = .staged,
    replaced_existing: bool = false,
    /// The directory swap, as a field so a test can run the whole
    /// upgrade on a filesystem that has no RENAME_EXCHANGE.
    exchange: *const fn ([*:0]const u8, [*:0]const u8) platform.RenameExchangeResult = platform.renameExchange,
    /// The directory fsync, as a field for the same reason `exchange` is
    /// one: a test has to be able to run the whole install on a
    /// filesystem whose directory fsync fails.
    sync_dir: *const fn ([*:0]const u8) c_int = posixSyncDir,

    /// Put the complete staged tree at its live path without deleting the old tree.
    pub fn commit(self: *Transaction) Error!void {
        if (self.phase != .staged) return error.RenameFailed;
        var dest_z_buf: [MAX_PATH]u8 = undefined;
        const dest_z = pathz.pathZ(&dest_z_buf, self.dest) catch return error.PathTooLong;
        var stage_z_buf: [MAX_PATH]u8 = undefined;
        const stage_z = pathz.pathZ(&stage_z_buf, self.stage) catch return error.PathTooLong;

        var st: c.struct_stat = undefined;
        if (c.lstat(dest_z, &st) == 0) {
            if ((st.st_mode & c.S_IFMT) != c.S_IFDIR) return error.RenameFailed;
            try self.swapTrees(stage_z, dest_z);
            self.replaced_existing = true;
        } else {
            if (std.c._errno().* != c.ENOENT) return error.RenameFailed;
            switch (platform.renameNoReplace(stage_z, dest_z)) {
                .ok => {},
                else => return error.RenameFailed,
            }
        }
        self.phase = .committed;
        self.syncBase();
    }

    /// Push the install directory's entry to disk, best effort.
    ///
    /// Every caller runs AFTER a rename that has already committed and
    /// cannot be rolled back. A directory fsync fails outright on FUSE
    /// and network homes, so reporting it would tell the caller nothing
    /// was installed while the new tree is already live.
    fn syncBase(self: *Transaction) void {
        var base_z_buf: [MAX_PATH]u8 = undefined;
        const base_z = pathz.pathZ(&base_z_buf, self.base) catch return;
        _ = self.sync_dir(base_z);
    }

    /// Exchange the staged and live trees, leaving the old tree at the
    /// stage path — the state `finish` and `rollback` are written for.
    ///
    /// `RENAME_EXCHANGE` does not exist on NFS, CIFS, a pre-4.x
    /// overlayfs upper, or macOS HFS+ (`renamex_np` answers ENOTSUP), so
    /// collapsing `.unsupported` into a failure made FRESH installs work
    /// (that path uses the better-supported `RENAME_NOREPLACE`) while
    /// every UPGRADE failed permanently. The fallback is a rename aside
    /// and back through a sibling under the same install lock: not
    /// atomic, but each step is a rename, so a crash leaves the tree at
    /// exactly one of three named paths rather than half-written.
    fn swapTrees(self: *Transaction, stage_z: [*:0]const u8, dest_z: [*:0]const u8) Error!void {
        switch (self.exchange(stage_z, dest_z)) {
            .ok => return,
            .unsupported => {},
            else => return error.RenameFailed,
        }
        var aside_buf: [MAX_PATH]u8 = undefined;
        const aside_z = std.fmt.bufPrintZ(&aside_buf, "{s}.swap", .{self.stage}) catch
            return error.PathTooLong;
        if (c.rename(dest_z, aside_z) != 0) return error.RenameFailed;
        if (c.rename(stage_z, dest_z) != 0) {
            // Put the live tree back before giving up.
            _ = c.rename(aside_z, dest_z);
            return error.RenameFailed;
        }
        if (c.rename(aside_z, stage_z) != 0) return error.RenameFailed;
    }

    /// Restore the pre-commit tree and remove only the rejected candidate.
    pub fn rollback(self: *Transaction) Error!void {
        if (self.phase == .done) return;
        if (self.phase == .staged) {
            _ = removeTree(self.stage);
            self.phase = .done;
            return self.releaseLock();
        }

        var dest_z_buf: [MAX_PATH]u8 = undefined;
        const dest_z = pathz.pathZ(&dest_z_buf, self.dest) catch return error.PathTooLong;
        var stage_z_buf: [MAX_PATH]u8 = undefined;
        const stage_z = pathz.pathZ(&stage_z_buf, self.stage) catch return error.PathTooLong;
        if (self.replaced_existing) {
            try self.swapTrees(stage_z, dest_z);
        } else if (c.rename(dest_z, stage_z) != 0) {
            return error.RenameFailed;
        }
        _ = removeTree(self.stage);
        self.syncBase();
        self.phase = .done;
        return self.releaseLock();
    }

    /// Accept the committed tree, then remove the obsolete tree left at the stage path.
    pub fn finish(self: *Transaction) Error!void {
        if (self.phase != .committed) return error.RenameFailed;
        const removed = !self.replaced_existing or removeTree(self.stage);
        self.syncBase();
        self.phase = .done;
        const release_result = self.releaseLock();
        if (!removed) return error.WriteFailed;
        try release_result;
    }

    pub fn deinit(self: *Transaction) void {
        if (self.phase != .done) self.rollback() catch {
            if (self.phase == .staged) _ = removeTree(self.stage);
            _ = c.flock(self.lock_fd, c.LOCK_UN);
            _ = c.close(self.lock_fd);
            self.phase = .done;
        };
        self.gpa.free(self.base);
        self.gpa.free(self.id);
        self.gpa.free(self.name);
        self.gpa.free(self.version);
        self.gpa.free(self.dest);
        self.gpa.free(self.stage);
    }

    fn releaseLock(self: *Transaction) Error!void {
        if (self.lock_fd < 0) return;
        const fd = self.lock_fd;
        self.lock_fd = -1;
        if (c.flock(fd, c.LOCK_UN) != 0) {
            _ = c.close(fd);
            return error.LockFailed;
        }
        if (c.close(fd) != 0) return error.CloseFailed;
    }
};

/// Extract an archive into a locked unique sibling stage and validate it from disk.
pub fn begin(
    gpa: std.mem.Allocator,
    base: []const u8,
    arc: *const zip.Archive,
    expected: *const manifest.Manifest,
) Error!Transaction {
    var ops: PosixWriteOps = .{};
    return beginWithOps(gpa, base, arc, expected, &ops);
}

fn beginWithOps(
    gpa: std.mem.Allocator,
    base: []const u8,
    arc: *const zip.Archive,
    expected: *const manifest.Manifest,
    ops: anytype,
) Error!Transaction {
    var id_buf: [manifest.MAX_ID_LEN]u8 = undefined;
    const expected_id = manifest.extensionId(expected, &id_buf);
    try mkdirAll(base);

    const owned_base = gpa.dupe(u8, base) catch return error.OutOfMemory;
    errdefer gpa.free(owned_base);
    const owned_id = gpa.dupe(u8, expected_id) catch return error.OutOfMemory;
    errdefer gpa.free(owned_id);
    const owned_name = gpa.dupe(u8, expected.name) catch return error.OutOfMemory;
    errdefer gpa.free(owned_name);
    const owned_version = gpa.dupe(u8, expected.version) catch return error.OutOfMemory;
    errdefer gpa.free(owned_version);
    const dest = std.fmt.allocPrint(gpa, "{s}/{s}", .{ base, expected_id }) catch return error.OutOfMemory;
    errdefer gpa.free(dest);
    const lock_path = std.fmt.allocPrint(gpa, "{s}/.{s}.install.lock", .{ base, expected_id }) catch return error.OutOfMemory;
    defer gpa.free(lock_path);

    var lock_z_buf: [MAX_PATH]u8 = undefined;
    const lock_z = pathz.pathZ(&lock_z_buf, lock_path) catch return error.PathTooLong;
    const lock_fd = c.open(lock_z, c.O_RDWR | c.O_CREAT | c.O_CLOEXEC | c.O_NOFOLLOW, @as(c_uint, 0o600));
    if (lock_fd < 0) return error.LockFailed;
    errdefer _ = c.close(lock_fd);
    if (c.fchmod(lock_fd, 0o600) != 0) return error.PermissionFailed;
    if (c.flock(lock_fd, c.LOCK_EX | c.LOCK_NB) != 0) {
        if (std.c._errno().* == c.EWOULDBLOCK or std.c._errno().* == c.EAGAIN)
            return error.ConcurrentInstall;
        return error.LockFailed;
    }
    errdefer _ = c.flock(lock_fd, c.LOCK_UN);

    const prefix = std.fmt.allocPrint(gpa, ".{s}.sketerm-stage-", .{expected_id}) catch return error.OutOfMemory;
    defer gpa.free(prefix);
    cleanupStages(base, prefix);

    var stage: ?[]u8 = null;
    for (0..STAGE_ATTEMPTS) |_| {
        const serial = next_stage.fetchAdd(1, .monotonic);
        const candidate = std.fmt.allocPrint(gpa, "{s}/{s}{d}-{x}", .{ base, prefix, c.getpid(), serial }) catch return error.OutOfMemory;
        var candidate_z_buf: [MAX_PATH]u8 = undefined;
        const candidate_z = pathz.pathZ(&candidate_z_buf, candidate) catch {
            gpa.free(candidate);
            return error.PathTooLong;
        };
        if (c.mkdir(candidate_z, 0o700) == 0) {
            stage = candidate;
            break;
        }
        const err = std.c._errno().*;
        gpa.free(candidate);
        if (err != c.EEXIST) return error.MkdirFailed;
    }
    const stage_path = stage orelse return error.MkdirFailed;
    errdefer gpa.free(stage_path);
    errdefer _ = removeTree(stage_path);

    for (arc.entries) |entry| {
        _ = zip.validateName(entry.name) catch return error.UnsafeAsset;
        const clean = if (entry.is_dir) entry.name[0 .. entry.name.len - 1] else entry.name;
        const full = std.fmt.allocPrint(gpa, "{s}/{s}", .{ stage_path, clean }) catch return error.OutOfMemory;
        defer gpa.free(full);
        if (entry.is_dir) {
            try mkdirAll(full);
        } else {
            if (std.fs.path.dirname(full)) |parent| try mkdirAll(parent);
            try writeEntry(ops, full, entry.data);
        }
    }
    try syncTree(stage_path, 0);

    var staged = try validateDirectory(gpa, stage_path, expected_id, expected.version, expected.name);
    staged.deinit();
    return .{
        .gpa = gpa,
        .base = owned_base,
        .id = owned_id,
        .name = owned_name,
        .version = owned_version,
        .dest = dest,
        .stage = stage_path,
        .lock_fd = lock_fd,
    };
}

/// Parse and verify a staged package through the same filesystem paths the helper will load.
pub fn validateDirectory(
    gpa: std.mem.Allocator,
    dir: []const u8,
    expected_id: []const u8,
    expected_version: []const u8,
    expected_name: ?[]const u8,
) Error!manifest.Manifest {
    const path = std.fmt.allocPrint(gpa, "{s}/manifest.json", .{dir}) catch return error.OutOfMemory;
    defer gpa.free(path);
    const bytes = try readFile(gpa, path, 4 * 1024 * 1024);
    defer gpa.free(bytes);
    var man = manifest.parse(gpa, bytes) catch |err| return mapManifestError(err);
    errdefer man.deinit();

    var id_buf: [manifest.MAX_ID_LEN]u8 = undefined;
    if (!std.mem.eql(u8, manifest.extensionId(&man, &id_buf), expected_id)) return error.IdentityMismatch;
    if (!std.mem.eql(u8, man.version, expected_version)) return error.VersionMismatch;
    if (expected_name) |name| {
        if (!std.mem.eql(u8, man.name, name)) return error.IdentityMismatch;
    }

    for (man.content_scripts) |script| {
        for (script.js) |asset| try validateAsset(gpa, dir, asset);
        for (script.css) |asset| try validateAsset(gpa, dir, asset);
    }
    if (man.background) |background| {
        if (background.page) |asset| try validateAsset(gpa, dir, asset);
        for (background.scripts) |asset| try validateAsset(gpa, dir, asset);
    }
    if (man.browser_action orelse man.page_action) |action| {
        if (action.default_icon) |asset| try validateAsset(gpa, dir, asset);
        if (action.default_popup) |asset| try validateAsset(gpa, dir, asset);
    }
    if (man.default_locale) |locale| {
        const asset = std.fmt.allocPrint(gpa, "_locales/{s}/messages.json", .{locale}) catch return error.OutOfMemory;
        defer gpa.free(asset);
        try validateAsset(gpa, dir, asset);
    }
    return man;
}

fn validateAsset(gpa: std.mem.Allocator, dir: []const u8, raw: []const u8) Error!void {
    const clean = std.mem.trimStart(u8, raw, "/");
    if (clean.len == 0) return error.UnsafeAsset;
    const is_dir = zip.validateName(clean) catch return error.UnsafeAsset;
    if (is_dir) return error.UnsafeAsset;
    const path = std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, clean }) catch return error.OutOfMemory;
    defer gpa.free(path);
    var path_z_buf: [MAX_PATH]u8 = undefined;
    const path_z = pathz.pathZ(&path_z_buf, path) catch return error.PathTooLong;
    var st: c.struct_stat = undefined;
    if (c.lstat(path_z, &st) != 0 or (st.st_mode & c.S_IFMT) != c.S_IFREG or
        st.st_size < 0 or st.st_size > MAX_ASSET) return error.MissingAsset;
}

fn mapManifestError(err: manifest.ParseError) Error {
    return switch (err) {
        error.UnsupportedManifestVersion => error.UnsupportedManifestVersion,
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadManifest,
    };
}

fn writeEntry(ops: anytype, path: []const u8, bytes: []const u8) Error!void {
    var path_z_buf: [MAX_PATH]u8 = undefined;
    const path_z = pathz.pathZ(&path_z_buf, path) catch return error.PathTooLong;
    const fd = ops.open(path_z, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC | c.O_NOFOLLOW, 0o644);
    if (fd < 0) return error.OpenFailed;
    var open = true;
    errdefer {
        if (open) _ = ops.close(fd);
    }
    if (ops.fchmod(fd, 0o644) != 0) return error.PermissionFailed;
    var off: usize = 0;
    while (off < bytes.len) {
        const n = ops.write(fd, bytes.ptr + off, bytes.len - off);
        if (n < 0 and std.c._errno().* == c.EINTR) continue;
        if (n <= 0) return error.WriteFailed;
        off += @intCast(n);
    }
    if (ops.fsync(fd) != 0) return error.DataSyncFailed;
    open = false;
    if (ops.close(fd) != 0) return error.CloseFailed;
}

fn readFile(gpa: std.mem.Allocator, path: []const u8, max: usize) Error![]u8 {
    var path_z_buf: [MAX_PATH]u8 = undefined;
    const path_z = pathz.pathZ(&path_z_buf, path) catch return error.PathTooLong;
    const fd = c.open(path_z, c.O_RDONLY | c.O_CLOEXEC | c.O_NOFOLLOW);
    if (fd < 0) return error.OpenFailed;
    var open = true;
    errdefer {
        if (open) _ = c.close(fd);
    }
    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0 or st.st_size <= 0 or st.st_size > max) return error.BadManifest;
    const size: usize = @intCast(st.st_size);
    const bytes = gpa.alloc(u8, size) catch return error.OutOfMemory;
    errdefer gpa.free(bytes);
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.read(fd, bytes.ptr + off, bytes.len - off);
        if (n < 0 and std.c._errno().* == c.EINTR) continue;
        if (n <= 0) return error.WriteFailed;
        off += @intCast(n);
    }
    open = false;
    if (c.close(fd) != 0) return error.CloseFailed;
    return bytes;
}

fn mkdirAll(path: []const u8) Error!void {
    pathz.makeDirs(path, 0o700) catch |err| return switch (err) {
        error.PathTooLong => error.PathTooLong,
        error.MkdirFailed => error.MkdirFailed,
    };
    var path_z_buf: [MAX_PATH]u8 = undefined;
    const path_z = pathz.pathZ(&path_z_buf, path) catch return error.PathTooLong;
    var st: c.struct_stat = undefined;
    if (c.lstat(path_z, &st) != 0 or (st.st_mode & c.S_IFMT) != c.S_IFDIR) return error.MkdirFailed;
}

/// Open, fsync and close one directory. @return -1 on any failure.
fn posixSyncDir(path_z: [*:0]const u8) c_int {
    const fd = c.open(path_z, c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC);
    if (fd < 0) return -1;
    const synced = c.fsync(fd);
    if (c.close(fd) != 0) return -1;
    return synced;
}

/// Best-effort directory sync; see `Transaction.syncBase` for why a
/// directory fsync is never a verdict on whether the data is there.
fn syncDir(path: []const u8) void {
    var path_z_buf: [MAX_PATH]u8 = undefined;
    const path_z = pathz.pathZ(&path_z_buf, path) catch return;
    _ = posixSyncDir(path_z);
}

/// How deep the tree walkers below will follow.
///
/// `zip.limits.name_depth` bounds what an archive can ask us to create,
/// so this is comfortably above any tree we mint; it exists because
/// these walks recurse on directory contents, which a tree we did NOT
/// mint could nest arbitrarily. Refusing is recoverable, a smashed main
/// -thread stack under live GTK frames is not.
const MAX_TREE_DEPTH: usize = 64;

fn syncTree(path: []const u8, depth: usize) Error!void {
    if (depth > MAX_TREE_DEPTH) return error.UnsafeAsset;
    var path_z_buf: [MAX_PATH]u8 = undefined;
    const path_z = pathz.pathZ(&path_z_buf, path) catch return error.PathTooLong;
    const dir = c.opendir(path_z) orelse return error.OpenFailed;
    var open = true;
    errdefer {
        if (open) _ = c.closedir(dir);
    }
    while (c.readdir(dir)) |entry| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        var child_buf: [MAX_PATH]u8 = undefined;
        const child = std.fmt.bufPrint(&child_buf, "{s}/{s}", .{ path, name }) catch return error.PathTooLong;
        var child_z_buf: [MAX_PATH]u8 = undefined;
        const child_z = pathz.pathZ(&child_z_buf, child) catch return error.PathTooLong;
        var st: c.struct_stat = undefined;
        if (c.lstat(child_z, &st) != 0) return error.OpenFailed;
        if ((st.st_mode & c.S_IFMT) == c.S_IFDIR) try syncTree(child, depth + 1);
    }
    open = false;
    if (c.closedir(dir) != 0) return error.CloseFailed;
    syncDir(path);
}

fn cleanupStages(base: []const u8, prefix: []const u8) void {
    var base_z_buf: [MAX_PATH]u8 = undefined;
    const base_z = pathz.pathZ(&base_z_buf, base) catch return;
    const dir = c.opendir(base_z) orelse return;
    defer _ = c.closedir(dir);
    while (c.readdir(dir)) |entry| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
        if (!std.mem.startsWith(u8, name, prefix)) continue;
        var child_buf: [MAX_PATH]u8 = undefined;
        const child = std.fmt.bufPrint(&child_buf, "{s}/{s}", .{ base, name }) catch continue;
        _ = removeTree(child);
    }
}

/// Allocation-free recursive cleanup so OOM cannot strand a partial stage by itself.
/// @return false when anything was left behind, over-deep trees included.
fn removeTree(path: []const u8) bool {
    return removeTreeAt(path, 0);
}

fn removeTreeAt(path: []const u8, depth: usize) bool {
    if (depth > MAX_TREE_DEPTH) return false;
    var path_z_buf: [MAX_PATH]u8 = undefined;
    const path_z = pathz.pathZ(&path_z_buf, path) catch return false;
    var st: c.struct_stat = undefined;
    if (c.lstat(path_z, &st) != 0) return std.c._errno().* == c.ENOENT;
    if ((st.st_mode & c.S_IFMT) != c.S_IFDIR) return c.unlink(path_z) == 0;
    const dir = c.opendir(path_z) orelse return false;
    var ok = true;
    while (c.readdir(dir)) |entry| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        var child_buf: [MAX_PATH]u8 = undefined;
        const child = std.fmt.bufPrint(&child_buf, "{s}/{s}", .{ path, name }) catch {
            ok = false;
            continue;
        };
        if (!removeTreeAt(child, depth + 1)) ok = false;
    }
    if (c.closedir(dir) != 0) ok = false;
    if (c.rmdir(path_z) != 0) ok = false;
    return ok;
}

// -- tests ------------------------------------------------------------

const t = std.testing;
const test_id = "transaction@sketerm.test";
const manifest_v1 =
    \\{"manifest_version":2,"name":"Transaction Test","version":"1",
    \\ "browser_specific_settings":{"gecko":{"id":"transaction@sketerm.test"}},
    \\ "background":{"scripts":["old.js"]}}
;
const manifest_v2 =
    \\{"manifest_version":2,"name":"Transaction Test","version":"2",
    \\ "browser_specific_settings":{"gecko":{"id":"transaction@sketerm.test"}},
    \\ "background":{"scripts":["new.js"]}}
;

const TestDir = struct {
    storage: [96:0]u8,

    fn init() !TestDir {
        var self = TestDir{ .storage = undefined };
        const template = "/tmp/sketerm-webext-install-XXXXXX";
        @memcpy(self.storage[0..template.len], template);
        self.storage[template.len] = 0;
        _ = c.mkdtemp(@ptrCast(&self.storage)) orelse return error.SkipZigTest;
        return self;
    }

    fn path(self: *const TestDir) []const u8 {
        return std.mem.sliceTo(&self.storage, 0);
    }

    fn deinit(self: *TestDir) void {
        _ = removeTree(self.path());
    }
};

fn archive(entries: []zip.Entry) zip.Archive {
    return .{ .entries = entries, .gpa = t.allocator };
}

fn parseExpected(json: []const u8) !manifest.Manifest {
    return manifest.parse(t.allocator, json);
}

fn writeTestFile(path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try mkdirAll(parent);
    var ops: PosixWriteOps = .{};
    return writeEntry(&ops, path, bytes);
}

fn readTestFile(path: []const u8, buf: []u8) ![]const u8 {
    const bytes = try readFile(t.allocator, path, buf.len);
    defer t.allocator.free(bytes);
    @memcpy(buf[0..bytes.len], bytes);
    return buf[0..bytes.len];
}

fn setupOld(base: []const u8) ![]u8 {
    const dest = try std.fmt.allocPrint(t.allocator, "{s}/{s}", .{ base, test_id });
    errdefer t.allocator.free(dest);
    try mkdirAll(dest);
    const man_path = try std.fmt.allocPrint(t.allocator, "{s}/manifest.json", .{dest});
    defer t.allocator.free(man_path);
    try writeTestFile(man_path, manifest_v1);
    const old_path = try std.fmt.allocPrint(t.allocator, "{s}/old.js", .{dest});
    defer t.allocator.free(old_path);
    try writeTestFile(old_path, "old-valid");
    return dest;
}

fn expectOld(dest: []const u8) !void {
    const old_path = try std.fmt.allocPrint(t.allocator, "{s}/old.js", .{dest});
    defer t.allocator.free(old_path);
    var buf: [32]u8 = undefined;
    try t.expectEqualStrings("old-valid", try readTestFile(old_path, &buf));
}

fn stageCount(base: []const u8) usize {
    var base_z_buf: [MAX_PATH]u8 = undefined;
    const base_z = pathz.pathZ(&base_z_buf, base) catch return 0;
    const dir = c.opendir(base_z) orelse return 0;
    defer _ = c.closedir(dir);
    var count: usize = 0;
    const prefix = "." ++ test_id ++ ".sketerm-stage-";
    while (c.readdir(dir)) |entry| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
        if (std.mem.startsWith(u8, name, prefix)) count += 1;
    }
    return count;
}

const FaultWriteOps = struct {
    const Failure = enum { none, enospc, permission, sync, close };

    failure: Failure = .none,
    max_write: usize = std.math.maxInt(usize),

    fn open(_: *@This(), path: [*:0]const u8, flags: c_int, mode: c.mode_t) c_int {
        return c.open(path, flags, mode);
    }
    fn fchmod(self: *@This(), fd: c_int, mode: c.mode_t) c_int {
        if (self.failure == .permission) {
            std.c._errno().* = c.EACCES;
            return -1;
        }
        return c.fchmod(fd, mode);
    }
    fn write(self: *@This(), fd: c_int, bytes: [*]const u8, len: usize) isize {
        if (self.failure == .enospc) {
            std.c._errno().* = c.ENOSPC;
            return -1;
        }
        return c.write(fd, bytes, @min(len, self.max_write));
    }
    fn fsync(self: *@This(), fd: c_int) c_int {
        if (self.failure == .sync) {
            std.c._errno().* = c.EIO;
            return -1;
        }
        return c.fsync(fd);
    }
    fn close(self: *@This(), fd: c_int) c_int {
        const rc = c.close(fd);
        if (self.failure == .close) {
            std.c._errno().* = c.EIO;
            return -1;
        }
        return rc;
    }
};

fn beginV2WithOps(base: []const u8, ops: anytype) !Transaction {
    var entries = [_]zip.Entry{
        .{ .name = "manifest.json", .data = @constCast(manifest_v2), .is_dir = false },
        .{ .name = "new.js", .data = @constCast("new-complete"), .is_dir = false },
    };
    var arc = archive(&entries);
    var man = try parseExpected(manifest_v2);
    defer man.deinit();
    return beginWithOps(t.allocator, base, &arc, &man, ops);
}

fn beginV2(base: []const u8) !Transaction {
    var ops: PosixWriteOps = .{};
    return beginV2WithOps(base, &ops);
}

test "archive install completes short writes" {
    var dir = try TestDir.init();
    defer dir.deinit();
    var ops: FaultWriteOps = .{ .max_write = 2 };
    var tx = try beginV2WithOps(dir.path(), &ops);
    defer tx.deinit();
    try t.expectEqual(@as(usize, 1), stageCount(dir.path()));
}

test "archive write ENOSPC permission flush and close failures preserve old version" {
    const cases = [_]struct { failure: FaultWriteOps.Failure, expected: Error }{
        .{ .failure = .enospc, .expected = error.WriteFailed },
        .{ .failure = .permission, .expected = error.PermissionFailed },
        .{ .failure = .sync, .expected = error.DataSyncFailed },
        .{ .failure = .close, .expected = error.CloseFailed },
    };
    for (cases) |case| {
        var dir = try TestDir.init();
        defer dir.deinit();
        const dest = try setupOld(dir.path());
        defer t.allocator.free(dest);
        var ops: FaultWriteOps = .{ .failure = case.failure };
        try t.expectError(case.expected, beginV2WithOps(dir.path(), &ops));
        try expectOld(dest);
        try t.expectEqual(@as(usize, 0), stageCount(dir.path()));
    }
}

test "archive install rejects overlong paths before touching a destination" {
    const long = [_]u8{'x'} ** MAX_PATH;
    var ops: PosixWriteOps = .{};
    var entries = [_]zip.Entry{
        .{ .name = "manifest.json", .data = @constCast(manifest_v2), .is_dir = false },
        .{ .name = "new.js", .data = @constCast("new"), .is_dir = false },
    };
    var arc = archive(&entries);
    var man = try parseExpected(manifest_v2);
    defer man.deinit();
    try t.expectError(error.PathTooLong, beginWithOps(t.allocator, &long, &arc, &man, &ops));
}

test "archive install OOM leaves the old tree and no stage" {
    var dir = try TestDir.init();
    defer dir.deinit();
    const dest = try setupOld(dir.path());
    defer t.allocator.free(dest);
    var entries = [_]zip.Entry{
        .{ .name = "manifest.json", .data = @constCast(manifest_v2), .is_dir = false },
        .{ .name = "new.js", .data = @constCast("new"), .is_dir = false },
    };
    var arc = archive(&entries);
    var man = try parseExpected(manifest_v2);
    defer man.deinit();
    var ops: PosixWriteOps = .{};

    var baseline = t.FailingAllocator.init(t.allocator, .{});
    var baseline_tx = try beginWithOps(baseline.allocator(), dir.path(), &arc, &man, &ops);
    const allocation_count = baseline.alloc_index;
    baseline_tx.deinit();
    try t.expect(allocation_count > 6);

    for (0..allocation_count) |fail_index| {
        var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = fail_index });
        if (beginWithOps(failing.allocator(), dir.path(), &arc, &man, &ops)) |tx_value| {
            var tx = tx_value;
            tx.deinit();
        } else |_| {}
        try t.expect(failing.has_induced_failure);
        try expectOld(dest);
        try t.expectEqual(@as(usize, 0), stageCount(dir.path()));
    }
}

test "helper refusal cleans only the staged candidate" {
    var dir = try TestDir.init();
    defer dir.deinit();
    const dest = try setupOld(dir.path());
    defer t.allocator.free(dest);
    var tx = try beginV2(dir.path());
    try tx.rollback();
    defer tx.deinit();
    try expectOld(dest);
    try t.expectEqual(@as(usize, 0), stageCount(dir.path()));
}

test "helper candidate validation refuses missing assets identity and version" {
    var dir = try TestDir.init();
    defer dir.deinit();
    const man_path = try std.fmt.allocPrint(t.allocator, "{s}/manifest.json", .{dir.path()});
    defer t.allocator.free(man_path);
    try writeTestFile(man_path, manifest_v2);

    try t.expectError(error.MissingAsset, validateDirectory(t.allocator, dir.path(), test_id, "2", "Transaction Test"));
    const asset = try std.fmt.allocPrint(t.allocator, "{s}/new.js", .{dir.path()});
    defer t.allocator.free(asset);
    try writeTestFile(asset, "new");
    try t.expectError(error.IdentityMismatch, validateDirectory(t.allocator, dir.path(), "other@sketerm.test", "2", "Transaction Test"));
    try t.expectError(error.VersionMismatch, validateDirectory(t.allocator, dir.path(), test_id, "3", "Transaction Test"));
}

test "crash leftovers are cleaned under the same-extension lock" {
    var dir = try TestDir.init();
    defer dir.deinit();
    const dest = try setupOld(dir.path());
    defer t.allocator.free(dest);
    const stale = try std.fmt.allocPrint(t.allocator, "{s}/.{s}.sketerm-stage-crashed", .{ dir.path(), test_id });
    defer t.allocator.free(stale);
    try mkdirAll(stale);
    const marker = try std.fmt.allocPrint(t.allocator, "{s}/partial", .{stale});
    defer t.allocator.free(marker);
    try writeTestFile(marker, "partial");

    var tx = try beginV2(dir.path());
    defer tx.deinit();
    var stale_z_buf: [MAX_PATH]u8 = undefined;
    var st: c.struct_stat = undefined;
    try t.expect(c.lstat(try pathz.pathZ(&stale_z_buf, stale), &st) != 0);
    try t.expectEqual(@as(usize, 1), stageCount(dir.path()));
    try expectOld(dest);
}

test "same-extension concurrent installs do not share or delete a stage" {
    var dir = try TestDir.init();
    defer dir.deinit();
    var first = try beginV2(dir.path());
    defer first.deinit();
    try t.expectError(error.ConcurrentInstall, beginV2(dir.path()));
    try t.expectEqual(@as(usize, 1), stageCount(dir.path()));
}

test "successful upgrade atomically replaces and then removes the old tree" {
    var dir = try TestDir.init();
    defer dir.deinit();
    const dest = try setupOld(dir.path());
    defer t.allocator.free(dest);
    var tx = try beginV2(dir.path());
    defer tx.deinit();
    try tx.commit();
    const new_path = try std.fmt.allocPrint(t.allocator, "{s}/new.js", .{dest});
    defer t.allocator.free(new_path);
    var buf: [32]u8 = undefined;
    try t.expectEqualStrings("new-complete", try readTestFile(new_path, &buf));
    try t.expectEqual(@as(usize, 1), stageCount(dir.path()));
    try tx.finish();
    try t.expectEqual(@as(usize, 0), stageCount(dir.path()));
    const old_path = try std.fmt.allocPrint(t.allocator, "{s}/old.js", .{dest});
    defer t.allocator.free(old_path);
    var old_z_buf: [MAX_PATH]u8 = undefined;
    var st: c.struct_stat = undefined;
    try t.expect(c.lstat(try pathz.pathZ(&old_z_buf, old_path), &st) != 0);
}

test "rejected committed upgrade rolls back the old tree" {
    var dir = try TestDir.init();
    defer dir.deinit();
    const dest = try setupOld(dir.path());
    defer t.allocator.free(dest);
    var tx = try beginV2(dir.path());
    defer tx.deinit();
    try tx.commit();
    try tx.rollback();
    try expectOld(dest);
    try t.expectEqual(@as(usize, 0), stageCount(dir.path()));
    const new_path = try std.fmt.allocPrint(t.allocator, "{s}/new.js", .{dest});
    defer t.allocator.free(new_path);
    var new_z_buf: [MAX_PATH]u8 = undefined;
    var st: c.struct_stat = undefined;
    try t.expect(c.lstat(try pathz.pathZ(&new_z_buf, new_path), &st) != 0);
}

/// A filesystem with no RENAME_EXCHANGE (NFS, CIFS, old overlayfs upper,
/// HFS+): the syscall is refused, never attempted.
fn testExchangeUnsupported(_: [*:0]const u8, _: [*:0]const u8) platform.RenameExchangeResult {
    return .unsupported;
}

test "an upgrade completes on a filesystem without RENAME_EXCHANGE" {
    var dir = try TestDir.init();
    defer dir.deinit();
    const dest = try setupOld(dir.path());
    defer t.allocator.free(dest);
    var tx = try beginV2(dir.path());
    tx.exchange = testExchangeUnsupported;
    defer tx.deinit();
    try tx.commit();
    const new_path = try std.fmt.allocPrint(t.allocator, "{s}/new.js", .{dest});
    defer t.allocator.free(new_path);
    var buf: [32]u8 = undefined;
    try t.expectEqualStrings("new-complete", try readTestFile(new_path, &buf));
    // The old tree waits at the stage path, exactly as after an exchange.
    try t.expectEqual(@as(usize, 1), stageCount(dir.path()));
    try tx.finish();
    try t.expectEqual(@as(usize, 0), stageCount(dir.path()));
    const old_path = try std.fmt.allocPrint(t.allocator, "{s}/old.js", .{dest});
    defer t.allocator.free(old_path);
    var old_z_buf: [MAX_PATH]u8 = undefined;
    var st: c.struct_stat = undefined;
    try t.expect(c.lstat(try pathz.pathZ(&old_z_buf, old_path), &st) != 0);
}

test "a rejected upgrade rolls back without RENAME_EXCHANGE" {
    var dir = try TestDir.init();
    defer dir.deinit();
    const dest = try setupOld(dir.path());
    defer t.allocator.free(dest);
    var tx = try beginV2(dir.path());
    tx.exchange = testExchangeUnsupported;
    defer tx.deinit();
    try tx.commit();
    try tx.rollback();
    try expectOld(dest);
    try t.expectEqual(@as(usize, 0), stageCount(dir.path()));
    const new_path = try std.fmt.allocPrint(t.allocator, "{s}/new.js", .{dest});
    defer t.allocator.free(new_path);
    var new_z_buf: [MAX_PATH]u8 = undefined;
    var st: c.struct_stat = undefined;
    try t.expect(c.lstat(try pathz.pathZ(&new_z_buf, new_path), &st) != 0);
}

/// A home whose directory fsync is refused (FUSE, NFS, CIFS): EROFS is
/// what made the old failure indistinguishable from "nothing installed".
fn testSyncDirRefused(_: [*:0]const u8) c_int {
    std.c._errno().* = c.EROFS;
    return -1;
}

test "an upgrade completes on a filesystem whose directory fsync fails" {
    var dir = try TestDir.init();
    defer dir.deinit();
    const dest = try setupOld(dir.path());
    defer t.allocator.free(dest);
    var tx = try beginV2(dir.path());
    tx.sync_dir = testSyncDirRefused;
    defer tx.deinit();
    // The rename has committed by the time the directory is synced, so a
    // refused sync must not roll the new tree back out.
    try tx.commit();
    try tx.finish();
    const new_path = try std.fmt.allocPrint(t.allocator, "{s}/new.js", .{dest});
    defer t.allocator.free(new_path);
    var buf: [32]u8 = undefined;
    try t.expectEqualStrings("new-complete", try readTestFile(new_path, &buf));
    try t.expectEqual(@as(usize, 0), stageCount(dir.path()));
    const old_path = try std.fmt.allocPrint(t.allocator, "{s}/old.js", .{dest});
    defer t.allocator.free(old_path);
    var old_z_buf: [MAX_PATH]u8 = undefined;
    var st: c.struct_stat = undefined;
    try t.expect(c.lstat(try pathz.pathZ(&old_z_buf, old_path), &st) != 0);
}

test "tree walks refuse a directory nested deeper than they will recurse" {
    var dir = try TestDir.init();
    defer dir.deinit();
    var deep: std.ArrayList(u8) = .empty;
    defer deep.deinit(t.allocator);
    try deep.appendSlice(t.allocator, dir.path());
    for (0..MAX_TREE_DEPTH + 2) |_| try deep.appendSlice(t.allocator, "/d");
    try mkdirAll(deep.items);

    try t.expectError(error.UnsafeAsset, syncTree(dir.path(), 0));
    try t.expect(!removeTree(dir.path()));

    // TestDir.deinit cannot clean this up either, so unwind by hand from
    // the leaf: that the walkers refuse is the point of the test.
    var len = deep.items.len;
    while (len > dir.path().len) : (len -= 2) {
        var z: [MAX_PATH]u8 = undefined;
        _ = c.rmdir(try pathz.pathZ(&z, deep.items[0..len]));
    }
}
