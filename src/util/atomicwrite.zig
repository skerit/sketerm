//! Crash-safe whole-file replacement: write a sibling `.part`, fsync it,
//! rename it over the target.
//!
//! libc-only (Zig 0.16 has no `std.fs.Dir`), so the daemon, the GUI and
//! the browser helper can all use the same implementation. A reader
//! therefore sees either the previous file or the complete new one, and
//! never a truncated one — which for a filter list, a journal or a
//! layout is the difference between "stale" and "silently broken".

const std = @import("std");
const c = @import("cbindings");

pub const Error = error{ NameTooLong, OpenFailed, WriteFailed, RenameFailed };

/// Longest destination path, leaving room for the `.part` suffix.
pub const MAX_PATH = 4096;

/// Replace `path` with `bytes`, creating it with `mode` if absent.
///
/// `O_NOFOLLOW` on the temporary: a symlink planted where our `.part`
/// goes would otherwise redirect the write. The partial file is
/// unlinked on every failure, so a failed write leaves nothing behind
/// and the previous contents intact. The temporary name is FIXED
/// (`<path>.part`, not per-pid): a crash between open and rename leaves
/// one file the next write truncates and reuses, and the filter-cache
/// sweep in `web/cefhost.zig` only recognizes that exact name.
pub fn writeFile(path: []const u8, bytes: []const u8, mode: u32) Error!void {
    if (path.len >= MAX_PATH) return error.NameTooLong;
    var tmp_buf: [MAX_PATH + 8]u8 = undefined;
    const tmp = std.fmt.bufPrintZ(&tmp_buf, "{s}.part", .{path}) catch return error.NameTooLong;
    var dst_buf: [MAX_PATH + 8]u8 = undefined;
    const dst = std.fmt.bufPrintZ(&dst_buf, "{s}", .{path}) catch return error.NameTooLong;
    const parent = std.fs.path.dirname(path) orelse ".";
    var parent_buf: [MAX_PATH + 8]u8 = undefined;
    const parent_z = std.fmt.bufPrintZ(&parent_buf, "{s}", .{parent}) catch return error.NameTooLong;
    const dir_fd = c.open(parent_z.ptr, c.O_RDONLY | c.O_CLOEXEC);
    if (dir_fd < 0) return error.OpenFailed;
    defer _ = c.close(dir_fd);

    const fd = c.open(
        tmp.ptr,
        c.O_WRONLY | c.O_CREAT | c.O_TRUNC | c.O_CLOEXEC | c.O_NOFOLLOW,
        @as(c_uint, @intCast(mode)),
    );
    if (fd < 0) return error.OpenFailed;
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(fd, bytes.ptr + off, bytes.len - off);
        if (n < 0 and std.c._errno().* == c.EINTR) continue;
        if (n <= 0) {
            _ = c.close(fd);
            _ = c.unlink(tmp.ptr);
            return error.WriteFailed;
        }
        off += @intCast(n);
    }
    // The fsync must succeed BEFORE the rename: a rename over a file
    // whose data never reached the disk is exactly the truncated file
    // this helper exists to prevent.
    const sync_ok = c.fsync(fd) == 0;
    const close_ok = c.close(fd) == 0;
    if (!sync_ok or !close_ok) {
        _ = c.unlink(tmp.ptr);
        return error.WriteFailed;
    }
    if (c.rename(tmp.ptr, dst.ptr) != 0) {
        _ = c.unlink(tmp.ptr);
        return error.RenameFailed;
    }
    // The destination is committed now and cannot be rolled back safely.
    // A directory-sync failure weakens crash durability, but must not be
    // reported as though the previous file were still in place.
    _ = c.fsync(dir_fd);
}

test "writeFile replaces contents and leaves no partial file" {
    var tmpl = "/tmp/sketerm-atomicwrite-XXXXXX".*;
    const dir = c.mkdtemp(&tmpl) orelse return error.SkipZigTest;
    const base = std.mem.span(@as([*:0]u8, @ptrCast(dir)));
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/list.txt", .{base});
    var z_buf: [512:0]u8 = undefined;
    const z = try std.fmt.bufPrintZ(&z_buf, "{s}", .{path});
    defer _ = c.rmdir(dir);
    defer _ = c.unlink(z.ptr);

    try writeFile(path, "first", 0o600);
    try writeFile(path, "second-and-longer", 0o600);

    const fd = c.open(z.ptr, c.O_RDONLY);
    try std.testing.expect(fd >= 0);
    defer _ = c.close(fd);
    var got: [64]u8 = undefined;
    const n = c.read(fd, &got, got.len);
    try std.testing.expectEqualStrings("second-and-longer", got[0..@intCast(n)]);

    var part_buf: [512:0]u8 = undefined;
    const part = try std.fmt.bufPrintZ(&part_buf, "{s}.part", .{path});
    var st: c.struct_stat = undefined;
    try std.testing.expect(c.stat(part.ptr, &st) != 0);
}

test "writeFile refuses an unopenable destination" {
    try std.testing.expectError(
        error.OpenFailed,
        writeFile("/proc/definitely/not/writable", "x", 0o600),
    );
    const long = [_]u8{'a'} ** MAX_PATH;
    try std.testing.expectError(error.NameTooLong, writeFile(&long, "x", 0o600));
}
