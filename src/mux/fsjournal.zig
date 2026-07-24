//! Atomic persistent records for daemon-owned filesystem jobs.

const std = @import("std");
const c = @import("../c.zig").c;
const pathz = @import("../util/pathz.zig");

pub const Record = struct {
    version: u32 = 1,
    id: u64,
    op: []const u8,
    state: []const u8 = "running",
    src: []const u8 = "",
    dst: []const u8 = "",
    pattern: []const u8 = "",
    src_host: []const u8 = "",
    dst_host: []const u8 = "",
    @"resume": bool = false,
    pid: i64 = -1,
    done: u64 = 0,
    total: u64 = 0,
    resumed_from: u64 = 0,
    message: []const u8 = "",
};

fn recordPath(buf: []u8, dir: []const u8, id: u64, temporary: bool) ![:0]u8 {
    return std.fmt.bufPrintZ(buf, "{s}/{d}.json{s}", .{ dir, id, if (temporary) ".tmp" else "" });
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
    if (fd >= 0) _ = c.fsync(fd);
    if (c.fclose(fp) != 0) {
        _ = c.unlink(temp.ptr);
        return error.WriteFailed;
    }
    if (c.rename(temp.ptr, final.ptr) != 0) {
        _ = c.unlink(temp.ptr);
        return error.WriteFailed;
    }
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
    });
    const path = try std.fmt.allocPrint(arena.allocator(), "{s}/42.json", .{base});
    const parsed = try load(arena.allocator(), path);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u64, 42), parsed.value.id);
    try std.testing.expectEqualStrings("/src", parsed.value.src);
    try std.testing.expect(parsed.value.@"resume");
    try std.testing.expectEqual(@as(u64, 99), parsed.value.done);
}
