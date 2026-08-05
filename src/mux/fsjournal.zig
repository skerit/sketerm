//! Atomic persistent records for daemon-owned filesystem jobs.

const std = @import("std");
const c = @import("../c.zig").c;
const pathz = @import("../util/pathz.zig");

pub const Record = struct {
    version: u32 = 4,
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
    /// "source_deleted" means its removal completed.
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
    if (std.mem.eql(u8, phase, "source_deleted")) return 5;
    if (std.mem.eql(u8, phase, "quarantined")) return 4;
    if (std.mem.eql(u8, phase, "copied")) return 3;
    if (std.mem.eql(u8, phase, "destination_staged")) return 2;
    if (std.mem.eql(u8, phase, "rename_planned")) return 1;
    return 0;
}

fn recordPath(buf: []u8, dir: []const u8, id: u64, temporary: bool) ![:0]u8 {
    return if (temporary)
        std.fmt.bufPrintZ(buf, "{s}/{d}.json.tmp-{d}", .{ dir, id, c.getpid() })
    else
        std.fmt.bufPrintZ(buf, "{s}/{d}.json", .{ dir, id });
}

pub fn ensureDir(dir: []const u8) bool {
    var z: [4096]u8 = undefined;
    pathz.makeParentDirs(dir) catch return false;
    const p = pathz.pathZ(&z, dir) catch return false;
    return c.mkdir(p, 0o700) == 0 or std.posix.errno(@as(c_int, -1)) == .EXIST;
}

pub fn save(dir: []const u8, record: Record) !void {
    if (!ensureDir(dir)) return error.CreateFailed;
    var final_buf: [4096:0]u8 = undefined;
    var temp_buf: [4096:0]u8 = undefined;
    const final = try recordPath(&final_buf, dir, record.id, false);
    const temp = try recordPath(&temp_buf, dir, record.id, true);
    const fp = c.fopen(temp.ptr, "wb") orelse return error.WriteFailed;
    var bytes: [16 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&bytes);
    std.json.Stringify.value(record, .{}, &w) catch {
        _ = c.fclose(fp);
        _ = c.unlink(temp.ptr);
        return error.WriteFailed;
    };
    const out = w.buffered();
    if (c.fwrite(out.ptr, 1, out.len, fp) != out.len or c.fflush(fp) != 0) {
        _ = c.fclose(fp);
        _ = c.unlink(temp.ptr);
        return error.WriteFailed;
    }
    const fd = c.fileno(fp);
    if (fd < 0 or c.fsync(fd) != 0) {
        _ = c.fclose(fp);
        _ = c.unlink(temp.ptr);
        return error.WriteFailed;
    }
    if (c.fclose(fp) != 0) {
        _ = c.unlink(temp.ptr);
        return error.WriteFailed;
    }
    if (c.rename(temp.ptr, final.ptr) != 0) {
        _ = c.unlink(temp.ptr);
        return error.WriteFailed;
    }
    // Persist the directory entry too: after a power loss a durable
    // job must not regress to the pre-rename record.
    var dir_buf: [4096]u8 = undefined;
    const dir_z = pathz.pathZ(&dir_buf, dir) catch return;
    const dfd = c.open(dir_z, c.O_RDONLY | c.O_DIRECTORY);
    if (dfd < 0) return error.WriteFailed;
    defer _ = c.close(dfd);
    if (c.fsync(dfd) != 0) return error.WriteFailed;
}

pub fn load(allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(Record) {
    var z: [4096]u8 = undefined;
    const fp = c.fopen(try pathz.pathZ(&z, path), "rb") orelse return error.OpenFailed;
    defer _ = c.fclose(fp);
    var bytes: [16 * 1024]u8 = undefined;
    const n = c.fread(&bytes, 1, bytes.len, fp);
    if (n == 0 or n == bytes.len) return error.BadRecord;
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
        .acknowledged = true,
    });
    const path = try std.fmt.allocPrint(arena.allocator(), "{s}/42.json", .{base});
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
    try std.testing.expect(parsed.value.acknowledged);
}

test "move journal phases are monotonic" {
    try std.testing.expect(phaseRank("") < phaseRank("rename_planned"));
    try std.testing.expect(phaseRank("rename_planned") < phaseRank("destination_staged"));
    try std.testing.expect(phaseRank("destination_staged") < phaseRank("copied"));
    try std.testing.expect(phaseRank("copied") < phaseRank("quarantined"));
    try std.testing.expect(phaseRank("quarantined") < phaseRank("source_deleted"));
}
