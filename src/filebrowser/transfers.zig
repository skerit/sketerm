//! Persistent intent ledger for browser downloads and edit sync-back.

const std = @import("std");
const c = @import("../c.zig").c;
const pathz = @import("../util/pathz.zig");
const profile = @import("../util/profile.zig");

pub const Kind = enum { download, upload };
pub const State = enum { queued, submitting, running, waiting_retry, done, failed, canceled };

pub const FileRef = struct {
    host: []const u8 = "",
    path: []const u8 = "",
};

pub const Intent = struct {
    token: []const u8 = "",
    kind: Kind = .download,
    src: FileRef = .{},
    dst: FileRef = .{},
    app_id: []const u8 = "",
    state: State = .queued,
    job: u64 = 0,
    order: u64 = 0,
    watch_token: []const u8 = "",
    submitted_generation: u64 = 0,
    message: []const u8 = "",
    attempts: u8 = 0,
    cancel_requested: bool = false,
    submitted_size: u64 = 0,
    submitted_mtime_ns: i64 = 0,
    /// User-held transfer. A plain defaulted field, not a new State
    /// value: an older build parses the ledger with unknown fields
    /// ignored, so a paused entry still loads there.
    paused: bool = false,
};

pub const Watch = struct {
    token: []const u8 = "",
    host: []const u8 = "",
    remote_path: []const u8 = "",
    cache_path: []const u8 = "",
    dirty_generation: u64 = 0,
    synced_generation: u64 = 0,
    synced_size: u64 = 0,
    synced_mtime_ns: i64 = 0,
};

pub const Ledger = struct {
    version: u32 = 1,
    next_order: u64 = 1,
    intents: []const Intent = &.{},
    watches: []const Watch = &.{},
    acknowledgments: []const u64 = &.{},
};

pub fn filePath(allocator: std.mem.Allocator) ![]u8 {
    if (profile.getenv("XDG_STATE_HOME")) |xs|
        return std.fmt.allocPrint(allocator, "{s}/sketerm/file-transfers.json", .{xs});
    if (profile.getenv("HOME")) |home|
        return std.fmt.allocPrint(allocator, "{s}/.local/state/sketerm/file-transfers.json", .{home});
    return allocator.dupe(u8, "/tmp/sketerm-file-transfers.json");
}

pub fn load(allocator: std.mem.Allocator) !?std.json.Parsed(Ledger) {
    const path = try filePath(allocator);
    defer allocator.free(path);
    var z: [4096]u8 = undefined;
    const pz = try pathz.pathZ(&z, path);
    const fp = c.fopen(pz, "rb") orelse {
        if (std.posix.errno(@as(c_int, -1)) == .NOENT) return null;
        return error.ReadFailed;
    };
    defer _ = c.fclose(fp);
    var bytes: [2 * 1024 * 1024]u8 = undefined;
    const n = c.fread(&bytes, 1, bytes.len, fp);
    if (n == 0 or n == bytes.len) return error.BadLedger;
    return std.json.parseFromSlice(Ledger, allocator, bytes[0..n], .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return error.BadLedger;
}

/// Atomically replace the operational ledger, including its directory entry.
pub fn save(allocator: std.mem.Allocator, ledger: Ledger) !void {
    const path = try filePath(allocator);
    defer allocator.free(path);
    try pathz.makeParentDirs(path);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(ledger, .{}, &out.writer);

    const temp = try std.fmt.allocPrint(allocator, "{s}.tmp-{d}", .{ path, c.getpid() });
    defer allocator.free(temp);
    var pz: [4096]u8 = undefined;
    var tz: [4096]u8 = undefined;
    const fp = c.fopen(try pathz.pathZ(&tz, temp), "wb") orelse return error.WriteFailed;
    const bytes = out.written();
    if (c.fwrite(bytes.ptr, 1, bytes.len, fp) != bytes.len or c.fflush(fp) != 0) {
        _ = c.fclose(fp);
        _ = c.unlink(try pathz.pathZ(&tz, temp));
        return error.WriteFailed;
    }
    const fd = c.fileno(fp);
    if (fd < 0 or c.fsync(fd) != 0) {
        _ = c.fclose(fp);
        _ = c.unlink(try pathz.pathZ(&tz, temp));
        return error.WriteFailed;
    }
    if (c.fclose(fp) != 0) return error.WriteFailed;
    if (c.rename(try pathz.pathZ(&tz, temp), try pathz.pathZ(&pz, path)) != 0)
        return error.WriteFailed;

    const parent = std.fs.path.dirname(path) orelse return;
    var dz: [4096]u8 = undefined;
    const dfd = c.open(try pathz.pathZ(&dz, parent), c.O_RDONLY | c.O_DIRECTORY);
    if (dfd < 0) return error.WriteFailed;
    defer _ = c.close(dfd);
    if (c.fsync(dfd) != 0) return error.WriteFailed;
}

test "transfer ledger round trips recovery fields" {
    const t = std.testing;
    const old_state = if (profile.getenv("XDG_STATE_HOME")) |value| try t.allocator.dupe(u8, value) else null;
    defer if (old_state) |value| t.allocator.free(value);
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var state_buf: [4096:0]u8 = undefined;
    const state = try std.fmt.bufPrintZ(&state_buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    _ = c.setenv("XDG_STATE_HOME", state.ptr, 1);
    defer if (old_state) |v| {
        var oldz: [4096:0]u8 = undefined;
        if (std.fmt.bufPrintZ(&oldz, "{s}", .{v})) |z| {
            _ = c.setenv("XDG_STATE_HOME", z.ptr, 1);
        } else |_| {}
    } else {
        _ = c.unsetenv("XDG_STATE_HOME");
    };

    try save(t.allocator, .{
        .next_order = 9,
        .intents = &.{.{
            .token = "abc",
            .src = .{ .host = "box", .path = "/remote/a" },
            .dst = .{ .path = "/cache/a" },
            .state = .running,
            .job = 42,
            .paused = true,
        }},
        .watches = &.{.{
            .token = "watch",
            .host = "box",
            .remote_path = "/remote/a",
            .cache_path = "/cache/a",
            .dirty_generation = 3,
            .synced_generation = 2,
        }},
        .acknowledgments = &.{42},
    });
    const parsed = (try load(t.allocator)) orelse return error.LoadFailed;
    defer parsed.deinit();
    try t.expectEqual(@as(u64, 9), parsed.value.next_order);
    try t.expectEqualStrings("abc", parsed.value.intents[0].token);
    try t.expectEqual(.running, parsed.value.intents[0].state);
    try t.expectEqual(true, parsed.value.intents[0].paused);
    try t.expectEqual(@as(u64, 3), parsed.value.watches[0].dirty_generation);
    try t.expectEqualSlices(u64, &.{42}, parsed.value.acknowledgments);
}
