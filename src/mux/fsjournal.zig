//! Atomic persistent records for daemon-owned filesystem jobs.

const std = @import("std");
const c = @import("../c.zig").c;
const pathz = @import("../util/pathz.zig");
const atomicwrite = @import("../util/atomicwrite.zig");

pub const VERSION: u32 = 5;
pub const MIN_READ_VERSION: u32 = 1;

pub const Record = struct {
    version: u32 = VERSION,
    id: u64,
    op: []const u8,
    state: []const u8 = "running",
    src: []const u8 = "",
    dst: []const u8 = "",
    pattern: []const u8 = "",
    src_host: []const u8 = "",
    dst_host: []const u8 = "",
    @"resume": bool = false,
    /// copy: per-entry collision policy inside a tree. Persisted
    /// because it is a SEMANTIC choice — a job restarted after a
    /// daemon crash must not start overwriting what the user chose to
    /// skip. `dir_mode` deliberately is NOT persisted: replacing the
    /// destination already happened before any copying, and doing it
    /// again on restart would only destroy the partial result.
    conflict: []const u8 = "",
    no_replace: bool = false,
    /// cross_copy: this job is a MOVE (source deleted after verify).
    /// Persisted for the same reason as `conflict`: a respawn that
    /// dropped it would silently turn the move into a copy.
    delete_src: bool = false,
    /// Local copy verification policy; a restart must not resume with
    /// weaker integrity guarantees than the submitted operation.
    verify: bool = false,
    /// cross_copy move durability boundary: "rename_planned" captures
    /// source identity, "destination_staged" protects a no-replace
    /// directory install, "copied" means every entry was installed and
    /// verified, "quarantined" captures the source root, and
    /// "deleting" commits to source cleanup (cancellation can no longer
    /// restore a complete tree), and "source_deleted" means it completed.
    phase: []const u8 = "",
    /// Persisted before source quarantine so a lost rename reply or
    /// helper crash can resume without ever deleting `src` by pathname.
    source_quarantine: []const u8 = "",
    /// Job-owned root used to make no-replace directory copies
    /// resumable without accepting an unrelated final directory.
    destination_stage: []const u8 = "",
    /// Commitment to the copied source snapshot. The root identity is
    /// also explicit because directory metadata changes during cleanup.
    source_fingerprint: []const u8 = "",
    source_kind: []const u8 = "",
    source_dev: u64 = 0,
    source_ino: u64 = 0,
    /// Automatic cleanup-helper restarts are bounded; validation or a
    /// deterministic crash must eventually fail closed with quarantine.
    recovery_attempts: u32 = 0,
    pid: i64 = -1,
    done: u64 = 0,
    total: u64 = 0,
    resumed_from: u64 = 0,
    files_done: u64 = 0,
    files_total: u64 = 0,
    message: []const u8 = "",
    /// Structured terminal cause used by clients to decide whether an
    /// automatic retry is safe (for example "transport" or "permanent").
    error_kind: []const u8 = "",
    /// Stable caller identity used to reconcile a submission whose
    /// reply was lost when the client disconnected.
    client_token: []const u8 = "",
    /// Logical-transfer identity that survives attempt boundaries: the
    /// client rotates `client_token` per attempt but keeps this one, so
    /// a retry can adopt the failed job's journal (stage, quarantine,
    /// phase) instead of orphaning the staged data under a fresh job.
    transfer_token: []const u8 = "",
    /// The durable client ledger has recorded this terminal outcome.
    acknowledged: bool = false,
};

pub fn phaseRank(phase: []const u8) u8 {
    if (std.mem.eql(u8, phase, "source_deleted")) return 6;
    if (std.mem.eql(u8, phase, "deleting")) return 5;
    if (std.mem.eql(u8, phase, "quarantined")) return 4;
    if (std.mem.eql(u8, phase, "copied")) return 3;
    if (std.mem.eql(u8, phase, "destination_staged")) return 2;
    if (std.mem.eql(u8, phase, "rename_planned")) return 1;
    return 0;
}

fn recordPath(buf: []u8, dir: []const u8, id: u64) ![:0]u8 {
    return std.fmt.bufPrintZ(buf, "{s}/{d}.json", .{ dir, id });
}

fn cancelPath(buf: []u8, dir: []const u8, id: u64) ![:0]u8 {
    return std.fmt.bufPrintZ(buf, "{s}/{d}.cancel", .{ dir, id });
}

fn controlPath(buf: []u8, dir: []const u8, id: u64) ![:0]u8 {
    return std.fmt.bufPrintZ(buf, "{s}/{d}.control", .{ dir, id });
}

fn syncDir(dir: []const u8) bool {
    var z: [4096]u8 = undefined;
    const dfd = c.open(pathz.pathZ(&z, dir) catch return false, c.O_RDONLY | c.O_DIRECTORY);
    if (dfd < 0) return false;
    defer _ = c.close(dfd);
    return c.fsync(dfd) == 0;
}

pub const ControlLock = struct {
    fd: c_int,

    pub fn release(self: ControlLock) void {
        _ = c.close(self.fd);
    }
};

/// Serialize cancellation with the helper's delete and terminal commits.
pub fn lockControl(dir: []const u8, id: u64) !ControlLock {
    if (!ensureDir(dir)) return error.CreateFailed;
    var path_buf: [4096:0]u8 = undefined;
    const path = try controlPath(&path_buf, dir, id);
    const fd = c.open(path.ptr, c.O_RDWR | c.O_CREAT | c.O_CLOEXEC, @as(c.mode_t, 0o600));
    if (fd < 0) return error.LockFailed;
    errdefer _ = c.close(fd);
    while (c.flock(fd, c.LOCK_EX) != 0) {
        if (std.posix.errno(@as(c_int, -1)) == .INTR) continue;
        return error.LockFailed;
    }
    return .{ .fd = fd };
}

/// Try the cancellation election without blocking the daemon poll loop.
pub fn tryLockControl(dir: []const u8, id: u64) !?ControlLock {
    if (!ensureDir(dir)) return error.CreateFailed;
    var path_buf: [4096:0]u8 = undefined;
    const path = try controlPath(&path_buf, dir, id);
    const fd = c.open(path.ptr, c.O_RDWR | c.O_CREAT | c.O_CLOEXEC, @as(c.mode_t, 0o600));
    if (fd < 0) return error.LockFailed;
    errdefer _ = c.close(fd);
    if (c.flock(fd, c.LOCK_EX | c.LOCK_NB) != 0) {
        if (std.posix.errno(@as(c_int, -1)) == .AGAIN) {
            _ = c.close(fd);
            return null;
        }
        return error.LockFailed;
    }
    return .{ .fd = fd };
}

pub const CancelResult = enum {
    requested,
    delete_committed,
    finished,
};

fn createCancel(dir: []const u8, id: u64) bool {
    var path_buf: [4096:0]u8 = undefined;
    const path = cancelPath(&path_buf, dir, id) catch return false;
    const fd = c.open(path.ptr, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC, @as(c.mode_t, 0o600));
    if (fd < 0) {
        if (std.posix.errno(@as(c_int, -1)) != .EXIST) return false;
        return true;
    }
    if (c.fsync(fd) != 0) {
        _ = c.close(fd);
        _ = c.unlink(path.ptr);
        return false;
    }
    if (c.close(fd) != 0) {
        _ = c.unlink(path.ptr);
        return false;
    }
    return syncDir(dir);
}

/// Try to persist cancellation now; null means the helper owns the
/// election. Cancellation succeeds only when source deletion has not
/// committed. There is deliberately no blocking variant: the daemon
/// must never wait on the helper's flock in its poll loop.
pub fn tryRequestCancel(allocator: std.mem.Allocator, dir: []const u8, id: u64) !?CancelResult {
    const guard = (try tryLockControl(dir, id)) orelse return null;
    defer guard.release();
    return try requestCancelLocked(allocator, dir, id, false);
}

/// Arm cleanup before restarting a failed durable transfer.
pub fn tryRequestRecoveryCancel(allocator: std.mem.Allocator, dir: []const u8, id: u64) !?CancelResult {
    const guard = (try tryLockControl(dir, id)) orelse return null;
    defer guard.release();
    return try requestCancelLocked(allocator, dir, id, true);
}

fn requestCancelLocked(allocator: std.mem.Allocator, dir: []const u8, id: u64, allow_failed: bool) !CancelResult {
    if (cancelRequested(dir, id)) return .requested;

    var path_buf: [4096]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{d}.json", .{ dir, id });
    const parsed = try load(allocator, path);
    defer parsed.deinit();
    if (phaseRank(parsed.value.phase) >= phaseRank("deleting")) return .delete_committed;
    if (std.mem.eql(u8, parsed.value.state, "done") or
        (!allow_failed and std.mem.eql(u8, parsed.value.state, "failed")) or
        std.mem.eql(u8, parsed.value.state, "canceled")) return .finished;
    if (!createCancel(dir, id)) return error.WriteFailed;
    return .requested;
}

pub fn cancelRequested(dir: []const u8, id: u64) bool {
    var path_buf: [4096:0]u8 = undefined;
    const path = cancelPath(&path_buf, dir, id) catch return false;
    return c.access(path.ptr, c.F_OK) == 0;
}

/// Remove a cancellation fence after a terminal journal record is durable.
pub fn clearCancel(dir: []const u8, id: u64) bool {
    var path_buf: [4096:0]u8 = undefined;
    const path = cancelPath(&path_buf, dir, id) catch return false;
    if (c.unlink(path.ptr) != 0 and std.posix.errno(@as(c_int, -1)) != .NOENT) return false;
    return syncDir(dir);
}

/// Remove the inactive serialization sidecar with the job journal.
pub fn clearControl(dir: []const u8, id: u64) void {
    var path_buf: [4096:0]u8 = undefined;
    const path = controlPath(&path_buf, dir, id) catch return;
    _ = c.unlink(path.ptr);
}

pub fn ensureDir(dir: []const u8) bool {
    var z: [4096]u8 = undefined;
    pathz.makeParentDirs(dir) catch return false;
    const p = pathz.pathZ(&z, dir) catch return false;
    return c.mkdir(p, 0o700) == 0 or std.posix.errno(@as(c_int, -1)) == .EXIST;
}

/// Replace one job record durably.
///
/// The shared writer owns the staging and the directory sync: its stage is
/// unique per CALL, where the old fixed `.json.tmp-<pid>` let two saves in
/// one process corrupt each other's, and it opens `O_EXCL|O_NOFOLLOW`
/// where `fopen` followed a symlink into the journal directory.
pub fn save(dir: []const u8, record: Record) !void {
    if (!ensureDir(dir)) return error.CreateFailed;
    var final_buf: [4096:0]u8 = undefined;
    const final = try recordPath(&final_buf, dir, record.id);
    var bytes: [16 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&bytes);
    std.json.Stringify.value(record, .{}, &w) catch return error.WriteFailed;
    atomicwrite.writeFileExact(final, w.buffered(), 0o600) catch return error.WriteFailed;
}

pub fn load(allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(Record) {
    var z: [4096]u8 = undefined;
    const fp = c.fopen(try pathz.pathZ(&z, path), "rb") orelse return error.OpenFailed;
    defer _ = c.fclose(fp);
    var bytes: [16 * 1024]u8 = undefined;
    const n = c.fread(&bytes, 1, bytes.len, fp);
    if (n == 0 or n == bytes.len) return error.BadRecord;
    const Header = struct { version: ?u32 = null };
    const header = try std.json.parseFromSlice(Header, allocator, bytes[0..n], .{
        .ignore_unknown_fields = true,
    });
    defer header.deinit();
    const record_version = header.value.version orelse return error.BadRecord;
    if (record_version < MIN_READ_VERSION or record_version > VERSION)
        return error.UnsupportedVersion;
    return std.json.parseFromSlice(Record, allocator, bytes[0..n], .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

test "job journal save/load is atomic and complete" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const base = try std.fmt.allocPrint(arena.allocator(), ".zig-cache/tmp/{s}/jobs", .{&tmp.sub_path});
    try save(base, .{
        .id = 42,
        .op = "copy",
        .src = "/src",
        .dst = "/dst",
        .@"resume" = true,
        .done = 99,
        .total = 123,
        .resumed_from = 11,
        .files_done = 7,
        .files_total = 9,
        .client_token = "intent-42",
        .transfer_token = "transfer-42",
        .conflict = "skip",
        .no_replace = true,
        .delete_src = true,
        .verify = true,
        .phase = "copied",
        .source_quarantine = "/src/.sketerm-move-42-deadbeef",
        .destination_stage = "/dst/.sketerm-copy-42-deadbeef",
        .source_fingerprint = "0123456789abcdef",
        .source_kind = "dir",
        .source_dev = 7,
        .source_ino = 9,
        .recovery_attempts = 2,
        .error_kind = "transport",
        .acknowledged = true,
    });
    const path = try std.fmt.allocPrint(arena.allocator(), "{s}/42.json", .{base});
    var path_buf: [4096]u8 = undefined;
    var st: c.struct_stat = undefined;
    try std.testing.expect(c.stat(try pathz.pathZ(&path_buf, path), &st) == 0);
    try std.testing.expectEqual(@as(c_uint, 0o600), @as(c_uint, @intCast(st.st_mode & 0o777)));

    try std.testing.expectError(error.WriteFailed, save(base, .{
        .id = 42,
        .op = "copy",
        .message = "x" ** (17 * 1024),
    }));
    const parsed = try load(arena.allocator(), path);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u64, 42), parsed.value.id);
    try std.testing.expectEqualStrings("/src", parsed.value.src);
    try std.testing.expect(parsed.value.@"resume");
    try std.testing.expectEqual(@as(u64, 99), parsed.value.done);
    try std.testing.expectEqual(@as(u64, 123), parsed.value.total);
    try std.testing.expectEqual(@as(u64, 11), parsed.value.resumed_from);
    try std.testing.expectEqual(@as(u64, 7), parsed.value.files_done);
    try std.testing.expectEqual(@as(u64, 9), parsed.value.files_total);
    try std.testing.expectEqualStrings("intent-42", parsed.value.client_token);
    try std.testing.expectEqualStrings("transfer-42", parsed.value.transfer_token);
    try std.testing.expectEqualStrings("skip", parsed.value.conflict);
    try std.testing.expect(parsed.value.no_replace);
    try std.testing.expect(parsed.value.delete_src);
    try std.testing.expect(parsed.value.verify);
    try std.testing.expectEqualStrings("copied", parsed.value.phase);
    try std.testing.expectEqualStrings("/src/.sketerm-move-42-deadbeef", parsed.value.source_quarantine);
    try std.testing.expectEqualStrings("/dst/.sketerm-copy-42-deadbeef", parsed.value.destination_stage);
    try std.testing.expectEqualStrings("0123456789abcdef", parsed.value.source_fingerprint);
    try std.testing.expectEqualStrings("dir", parsed.value.source_kind);
    try std.testing.expectEqual(@as(u64, 7), parsed.value.source_dev);
    try std.testing.expectEqual(@as(u64, 9), parsed.value.source_ino);
    try std.testing.expectEqual(@as(u32, 2), parsed.value.recovery_attempts);
    try std.testing.expectEqualStrings("transport", parsed.value.error_kind);
    try std.testing.expect(parsed.value.acknowledged);
}

test "a symlink planted at the old fixed stage name cannot be written through" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/jobs", .{&tmp.sub_path});
    try std.testing.expect(ensureDir(base));

    const victim = try std.fmt.allocPrint(a, "{s}/victim", .{base});
    var victim_buf: [4096]u8 = undefined;
    const victim_z = try pathz.pathZ(&victim_buf, victim);
    const vfd = c.open(victim_z, c.O_WRONLY | c.O_CREAT | c.O_TRUNC | c.O_CLOEXEC, @as(c.mode_t, 0o600));
    try std.testing.expect(vfd >= 0);
    try std.testing.expect(c.write(vfd, "keep-me", 7) == 7);
    _ = c.close(vfd);

    // The old writer opened `<id>.json.tmp-<pid>` with fopen("wb"), which
    // follows a symlink out of the journal directory.
    const bait = try std.fmt.allocPrint(a, "{s}/7.json.tmp-{d}", .{ base, c.getpid() });
    var bait_buf: [4096]u8 = undefined;
    try std.testing.expect(c.symlink(victim_z, try pathz.pathZ(&bait_buf, bait)) == 0);

    try save(base, .{ .id = 7, .op = "copy", .src = "/a", .dst = "/b" });

    const vfd2 = c.open(victim_z, c.O_RDONLY | c.O_CLOEXEC);
    try std.testing.expect(vfd2 >= 0);
    defer _ = c.close(vfd2);
    var got: [32]u8 = undefined;
    const n = c.read(vfd2, &got, got.len);
    try std.testing.expect(n == 7);
    try std.testing.expectEqualStrings("keep-me", got[0..7]);

    const path = try std.fmt.allocPrint(a, "{s}/7.json", .{base});
    const parsed = try load(a, path);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u64, 7), parsed.value.id);
}

test "cancel fence is durable, idempotent, and independent of journal saves" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const base = try std.fmt.allocPrint(arena.allocator(), ".zig-cache/tmp/{s}/jobs", .{&tmp.sub_path});
    try save(base, .{ .id = 7, .op = "cross_copy", .state = "running" });
    try std.testing.expectEqual(CancelResult.requested, (try tryRequestCancel(std.testing.allocator, base, 7)).?);
    try std.testing.expectEqual(CancelResult.requested, (try tryRequestCancel(std.testing.allocator, base, 7)).?);
    try std.testing.expect(cancelRequested(base, 7));
    try std.testing.expect(cancelRequested(base, 7));
    try std.testing.expect(clearCancel(base, 7));
    try std.testing.expect(!cancelRequested(base, 7));
}

test "cancel request loses after the deleting boundary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const base = try std.fmt.allocPrint(arena.allocator(), ".zig-cache/tmp/{s}/jobs", .{&tmp.sub_path});
    try save(base, .{ .id = 8, .op = "cross_copy", .state = "running", .phase = "deleting" });
    try std.testing.expectEqual(CancelResult.delete_committed, (try tryRequestCancel(std.testing.allocator, base, 8)).?);
    try std.testing.expect(!cancelRequested(base, 8));
}

test "nonblocking cancellation election reports a held helper lock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const base = try std.fmt.allocPrint(arena.allocator(), ".zig-cache/tmp/{s}/jobs", .{&tmp.sub_path});
    try save(base, .{ .id = 9, .op = "cross_copy", .state = "running" });
    const held = try lockControl(base, 9);
    try std.testing.expect((try tryRequestCancel(std.testing.allocator, base, 9)) == null);
    held.release();
    try std.testing.expectEqual(CancelResult.requested, (try tryRequestCancel(std.testing.allocator, base, 9)).?);
}

test "journal reader rejects a future durability version" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const base = try std.fmt.allocPrint(arena.allocator(), ".zig-cache/tmp/{s}/jobs", .{&tmp.sub_path});
    try save(base, .{ .version = VERSION + 1, .id = 10, .op = "cross_copy" });
    const path = try std.fmt.allocPrint(arena.allocator(), "{s}/10.json", .{base});
    try std.testing.expectError(error.UnsupportedVersion, load(arena.allocator(), path));
}

test "move journal phases are monotonic" {
    try std.testing.expect(phaseRank("") < phaseRank("rename_planned"));
    try std.testing.expect(phaseRank("rename_planned") < phaseRank("destination_staged"));
    try std.testing.expect(phaseRank("destination_staged") < phaseRank("copied"));
    try std.testing.expect(phaseRank("copied") < phaseRank("quarantined"));
    try std.testing.expect(phaseRank("quarantined") < phaseRank("deleting"));
    try std.testing.expect(phaseRank("deleting") < phaseRank("source_deleted"));
}
