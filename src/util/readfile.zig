//! Bounded whole-file reads, the one home for "open, size, allocate,
//! read, close" in libc-land.
//!
//! Two strategies, because the call sites genuinely need both and the
//! five hand-rolled copies this replaced had drifted into a mix:
//!
//! - `sized` seeks to learn the length and reads it in one `fread`. It
//!   refuses a file it cannot size (0 bytes, a pipe, most of procfs),
//!   which is exactly what its callers want: a 0-byte icon or desktop
//!   entry is a MISS, not an empty document.
//! - `capped` streams into an ArrayList, so it also works on a file
//!   whose size is unknown or moving, and yields an empty slice for an
//!   empty file.
//!
//! The cap is a PARAMETER in both, never a constant in here: it is the
//! only thing standing between a hostile or runaway file and this
//! process's memory, so each caller states its own.

const std = @import("std");
const c = @import("cbindings");
const pathz = @import("pathz.zig");
const xdg = @import("xdg.zig");

pub const Error = error{ OpenFailed, ReadFailed, StreamTooLong, OutOfMemory };

/// Read at most `cap` bytes, rejecting excess data and incomplete reads.
pub fn cappedAlloc(allocator: std.mem.Allocator, path: []const u8, cap: usize) ![]u8 {
    var z: [4096]u8 = undefined;
    const p = try pathz.pathZ(&z, path);
    const fp = c.fopen(p, "rb") orelse return error.OpenFailed;
    defer _ = c.fclose(fp);
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const remaining = cap - list.items.len;
        const n = c.fread(&buf, 1, @min(buf.len, remaining +| 1), fp);
        const interrupted = c.ferror(fp) != 0;
        if (interrupted) {
            if (std.c._errno().* != c.EINTR) return error.ReadFailed;
            c.clearerr(fp);
        }
        if (n > remaining) return error.StreamTooLong;
        try list.appendSlice(allocator, buf[0..n]);
        if (n == 0 and !interrupted) break;
    }
    return list.toOwnedSlice(allocator);
}

/// `cappedAlloc` for callers with nothing to say about a failure.
pub fn capped(allocator: std.mem.Allocator, path: []const u8, cap: usize) ?[]u8 {
    return cappedAlloc(allocator, path, cap) catch null;
}

/// A user config file `<xdg config dir>/<rel>`, read through `capped`.
/// @return null when no config directory can be named, or the file is absent, unreadable or over `cap`.
pub fn userConfig(allocator: std.mem.Allocator, rel: []const u8, cap: usize) ?[]u8 {
    var buf: [4096]u8 = undefined;
    const path = xdg.configPath(&buf, rel) orelse return null;
    return capped(allocator, path, cap);
}

/// Whole file into memory via seek + one read.
/// @return null when the file is absent, empty, unseekable, larger
/// than `cap`, or read short; error only for the allocation.
pub fn sized(allocator: std.mem.Allocator, path: []const u8, cap: usize) error{OutOfMemory}!?[]u8 {
    var z: [4096]u8 = undefined;
    const p = pathz.pathZ(&z, path) catch return null;
    const fp = c.fopen(p, "rb") orelse return null;
    defer _ = c.fclose(fp);
    if (c.fseek(fp, 0, c.SEEK_END) != 0) return null;
    const raw = c.ftell(fp);
    if (raw <= 0) return null;
    const size: usize = @intCast(raw);
    if (size > cap) return null;
    if (c.fseek(fp, 0, c.SEEK_SET) != 0) return null;
    const out = try allocator.alloc(u8, size);
    if (c.fread(out.ptr, 1, size, fp) != size) {
        allocator.free(out);
        return null;
    }
    return out;
}

/// `sized` for callers that treat an allocation failure as a miss too.
pub fn sizedOrNull(allocator: std.mem.Allocator, path: []const u8, cap: usize) ?[]u8 {
    return sized(allocator, path, cap) catch null;
}

/// Parse a JSON state file off disk, ignoring unknown fields.
///
/// Everything about a state file we cannot read is the same answer:
/// null, meaning "no saved state", never an error the caller has to
/// invent a recovery for. The parse allocates always, so the returned
/// `Parsed` owns its strings and outlives the file buffer.
pub fn json(comptime T: type, allocator: std.mem.Allocator, path: []const u8, cap: usize) ?std.json.Parsed(T) {
    const bytes = sizedOrNull(allocator, path, cap) orelse return null;
    defer allocator.free(bytes);
    return std.json.parseFromSlice(T, allocator, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch null;
}

// ─── tests ──────────────────────────────────────────────────────

const t = std.testing;

fn writeTemp(dir: []const u8, name: []const u8, bytes: []const u8, buf: *[4096:0]u8) ![]const u8 {
    const path = try std.fmt.bufPrintSentinel(buf, "{s}/{s}", .{ dir, name }, 0);
    const fp = c.fopen(path.ptr, "wb") orelse return error.SkipZigTest;
    defer _ = c.fclose(fp);
    if (bytes.len > 0) try t.expect(c.fwrite(bytes.ptr, 1, bytes.len, fp) == bytes.len);
    return path;
}

test "sized: under, exactly at and over the cap" {
    const td = pathz.TempDir.make("readfile") orelse return error.SkipZigTest;
    defer td.remove();
    var buf: [4096:0]u8 = undefined;
    const path = try writeTemp(td.path(), "f", "0123456789", &buf);

    const exact = (try sized(t.allocator, path, 10)).?;
    defer t.allocator.free(exact);
    try t.expectEqualStrings("0123456789", exact);

    const under = (try sized(t.allocator, path, 64)).?;
    defer t.allocator.free(under);
    try t.expectEqualStrings("0123456789", under);

    try t.expectEqual(@as(?[]u8, null), try sized(t.allocator, path, 9));
}

test "sized: an empty file and a missing file are both a miss" {
    const td = pathz.TempDir.make("readfile-empty") orelse return error.SkipZigTest;
    defer td.remove();
    var buf: [4096:0]u8 = undefined;
    const path = try writeTemp(td.path(), "empty", "", &buf);
    try t.expectEqual(@as(?[]u8, null), try sized(t.allocator, path, 64));

    var missing: [4096]u8 = undefined;
    const gone = try std.fmt.bufPrint(&missing, "{s}/nope", .{td.path()});
    try t.expectEqual(@as(?[]u8, null), try sized(t.allocator, gone, 64));
}

test "cappedAlloc: under, exactly at and over the cap" {
    const td = pathz.TempDir.make("readfile-cap") orelse return error.SkipZigTest;
    defer td.remove();
    var buf: [4096:0]u8 = undefined;
    const path = try writeTemp(td.path(), "f", "0123456789", &buf);

    const exact = try cappedAlloc(t.allocator, path, 10);
    defer t.allocator.free(exact);
    try t.expectEqualStrings("0123456789", exact);

    try t.expectError(error.StreamTooLong, cappedAlloc(t.allocator, path, 9));
    try t.expectEqual(@as(?[]u8, null), capped(t.allocator, path, 9));

    // An empty file yields an empty slice here, unlike `sized`.
    const empty_path = try writeTemp(td.path(), "empty", "", &buf);
    const empty = try cappedAlloc(t.allocator, empty_path, 64);
    defer t.allocator.free(empty);
    try t.expectEqual(@as(usize, 0), empty.len);

    var missing: [4096]u8 = undefined;
    const gone = try std.fmt.bufPrint(&missing, "{s}/nope", .{td.path()});
    try t.expectError(error.OpenFailed, cappedAlloc(t.allocator, gone, 64));
}

test "cappedAlloc refuses read errors instead of returning an empty file" {
    const td = pathz.TempDir.make("readfile-error") orelse return error.SkipZigTest;
    defer td.remove();
    try t.expectError(error.ReadFailed, cappedAlloc(t.allocator, td.path(), 64));
    try t.expectEqual(@as(?[]u8, null), capped(t.allocator, td.path(), 64));
}

test "cappedAlloc rejects excess bytes before allocating them" {
    const td = pathz.TempDir.make("readfile-zero") orelse return error.SkipZigTest;
    defer td.remove();
    var buf: [4096:0]u8 = undefined;
    const path = try writeTemp(td.path(), "f", "x", &buf);
    var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    try t.expectError(error.StreamTooLong, cappedAlloc(failing.allocator(), path, 0));
    try t.expect(!failing.has_induced_failure);
    const empty_path = try writeTemp(td.path(), "empty", "", &buf);
    const empty = try cappedAlloc(failing.allocator(), empty_path, 0);
    defer failing.allocator().free(empty);
    try t.expectEqual(@as(usize, 0), empty.len);
}

test "userConfig reads under XDG_CONFIG_HOME, refuses over-cap files and a missing config dir" {
    const env = @import("env.zig");
    const td = pathz.TempDir.make("readfile-usercfg") orelse return error.SkipZigTest;
    defer td.remove();
    var dir_buf: [4096:0]u8 = undefined;
    const dir = try std.fmt.bufPrintSentinel(&dir_buf, "{s}/sketerm", .{td.path()}, 0);
    try t.expect(c.mkdir(dir.ptr, 0o700) == 0);
    var buf: [4096:0]u8 = undefined;
    _ = try writeTemp(dir, "x.conf", "a = b\n", &buf);
    var saved_cfg: env.Saved = .{};
    try saved_cfg.override("XDG_CONFIG_HOME", td.pathZ());
    defer saved_cfg.restore();
    var saved_home: env.Saved = .{};
    try saved_home.take("HOME");
    defer saved_home.restore();

    const got = userConfig(t.allocator, "x.conf", 64).?;
    defer t.allocator.free(got);
    try t.expectEqualStrings("a = b\n", got);
    try t.expect(userConfig(t.allocator, "x.conf", 3) == null);
    try t.expect(userConfig(t.allocator, "absent.conf", 64) == null);
    _ = env.unset("XDG_CONFIG_HOME");
    try t.expect(userConfig(t.allocator, "x.conf", 64) == null);
}

test "json: round-trips, ignores unknown fields, nulls on garbage" {
    const State = struct { n: u32 = 0, name: []const u8 = "" };
    const td = pathz.TempDir.make("readfile-json") orelse return error.SkipZigTest;
    defer td.remove();
    var buf: [4096:0]u8 = undefined;

    const ok = try writeTemp(td.path(), "ok.json", "{\"n\":7,\"name\":\"x\",\"extra\":true}", &buf);
    const parsed = json(State, t.allocator, ok, 64 * 1024).?;
    defer parsed.deinit();
    try t.expectEqual(@as(u32, 7), parsed.value.n);
    try t.expectEqualStrings("x", parsed.value.name);

    const bad = try writeTemp(td.path(), "bad.json", "not json", &buf);
    try t.expect(json(State, t.allocator, bad, 64 * 1024) == null);

    // Past the cap the file is unreadable, so there is no state.
    try t.expect(json(State, t.allocator, ok, 4) == null);
}
