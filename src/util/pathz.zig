//! Path helpers shared by GUI and mux targets.
//!
//! Both live in libc-land: Zig 0.16 dropped `std.fs.Dir`, and every
//! file/socket syscall we make goes through C, which wants
//! NUL-terminated paths.

const std = @import("std");
const c = @import("../c.zig").c;

pub const Error = error{PathTooLong};

/// NUL-terminate `path` into the caller's stack buffer.
/// @return pointer into `buf`, valid only while `buf` lives.
pub fn pathZ(buf: *[4096]u8, path: []const u8) Error![*:0]const u8 {
    if (path.len >= buf.len) return error.PathTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return @ptrCast(buf);
}

/// Create every missing parent directory of `path` via `mkdir(2)`,
/// like `mkdir -p $(dirname path)`. Idempotent: EEXIST is ignored.
pub fn makeParentDirs(path: []const u8) Error!void {
    const dirname = std.fs.path.dirname(path) orelse return;
    if (dirname.len == 0) return;
    var path_z: [4096]u8 = undefined;
    if (dirname.len >= path_z.len) return error.PathTooLong;
    var i: usize = 0;
    while (i < dirname.len) {
        // Walk to the next '/' (or end), then mkdir the prefix. Skips
        // the leading '/' of absolute paths and empty "//" components.
        const start = i;
        while (i < dirname.len and dirname[i] != '/') i += 1;
        if (i == start) {
            i += 1;
            continue;
        }
        const slice_len = i;
        @memcpy(path_z[0..slice_len], dirname[0..slice_len]);
        path_z[slice_len] = 0;
        _ = c.mkdir(@ptrCast(&path_z), 0o755);
        i += 1;
    }
}

test "pathZ round-trips and rejects oversize" {
    var buf: [4096]u8 = undefined;
    const z = try pathZ(&buf, "/tmp/x");
    try std.testing.expectEqualStrings("/tmp/x", std.mem.span(z));
    const big = [_]u8{'a'} ** 4096;
    try std.testing.expectError(error.PathTooLong, pathZ(&buf, &big));
}

test "makeParentDirs creates nested dirs" {
    var tmpl = "/tmp/sketerm-pathz-XXXXXX".*;
    const dir = c.mkdtemp(&tmpl) orelse return error.SkipZigTest;
    const base = std.mem.span(@as([*:0]u8, @ptrCast(dir)));
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try w.print("{s}/a/b/c/file", .{base});
    const target = w.buffered();
    try makeParentDirs(target);
    var z_buf: [4096]u8 = undefined;
    var st: c.struct_stat = undefined;
    const dir_path = target[0 .. target.len - "/file".len];
    try std.testing.expect(c.stat(try pathZ(&z_buf, dir_path), &st) == 0);
    try std.testing.expect(st.st_mode & c.S_IFDIR != 0);
}
