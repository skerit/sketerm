//! Path helpers shared by GUI and mux targets.
//!
//! Both live in libc-land: Zig 0.16 dropped `std.fs.Dir`, and every
//! file/socket syscall we make goes through C, which wants
//! NUL-terminated paths.

const std = @import("std");
// `cbindings` directly rather than through `../c.zig`, which is a bare
// re-export of it: every target that compiles this file already imports
// the module under that name, the browser helper included.
const c = @import("cbindings");

pub const Error = error{ PathTooLong, MkdirFailed };

/// NUL-terminate `path` into the caller's stack buffer.
/// @return pointer into `buf`, valid only while `buf` lives.
pub fn pathZ(buf: *[4096]u8, path: []const u8) Error![*:0]const u8 {
    if (path.len >= buf.len) return error.PathTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return @ptrCast(buf);
}

/// Create `path` and every missing component of it via `mkdir(2)`, like
/// `mkdir -p path`. Idempotent: EEXIST is ignored.
/// @return error.MkdirFailed for the first component that could not be
/// created for any other reason.
pub fn makeDirs(path: []const u8, mode: u32) Error!void {
    if (path.len == 0) return error.MkdirFailed;
    var path_z: [4096]u8 = undefined;
    if (path.len >= path_z.len) return error.PathTooLong;
    var i: usize = 0;
    while (i < path.len) {
        // Walk to the next '/' (or end), then mkdir the prefix. Skips
        // the leading '/' of absolute paths and empty "//" components.
        const start = i;
        while (i < path.len and path[i] != '/') i += 1;
        if (i == start) {
            i += 1;
            continue;
        }
        const slice_len = i;
        @memcpy(path_z[0..slice_len], path[0..slice_len]);
        path_z[slice_len] = 0;
        if (c.mkdir(@ptrCast(&path_z), @intCast(mode)) != 0 and std.c._errno().* != c.EEXIST)
            return error.MkdirFailed;
        i += 1;
    }
}

/// Create every missing parent directory of `path`, like
/// `mkdir -p $(dirname path)`.
///
/// A component that could not be created is deliberately SWALLOWED
/// here: every caller goes on to open the file itself, and that open is
/// the error the caller can act on. Use `makeDirs` when the directory
/// is the result.
pub fn makeParentDirs(path: []const u8) Error!void {
    const dirname = std.fs.path.dirname(path) orelse return;
    if (dirname.len == 0) return;
    makeDirs(dirname, 0o755) catch |err| switch (err) {
        error.PathTooLong => return error.PathTooLong,
        error.MkdirFailed => {},
    };
}

/// Remove `path` and everything under it, best effort: failures are
/// ignored and a plain file or symlink is unlinked rather than descended.
/// Names are collected BEFORE anything is unlinked: deleting during
/// readdir skips entries and quietly leaves half the tree behind.
pub fn removeTree(path: []const u8) void {
    var z_buf: [4096]u8 = undefined;
    const zpath = pathZ(&z_buf, path) catch return;
    // lstat BEFORE opendir: opendir follows a symlink, and a link to a
    // directory must be unlinked, never emptied.
    var st: c.struct_stat = undefined;
    if (c.lstat(zpath, &st) != 0) return;
    const is_dir = (st.st_mode & c.S_IFMT) == c.S_IFDIR;
    if (!is_dir) {
        _ = c.unlink(zpath);
        return;
    }
    if (c.opendir(zpath)) |dir| {
        const a = std.heap.page_allocator;
        var kids: std.ArrayList([]u8) = .empty;
        defer {
            for (kids.items) |k| a.free(k);
            kids.deinit(a);
        }
        while (c.readdir(dir)) |ent| {
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            const child = std.fmt.allocPrint(a, "{s}/{s}", .{ path, name }) catch continue;
            kids.append(a, child) catch a.free(child);
        }
        _ = c.closedir(dir);
        for (kids.items) |child| removeTree(child);
    }
    _ = c.rmdir(zpath);
}

/// A `mkdtemp` scratch directory for tests, removed whole by `remove`.
/// Tests that forget the `defer td.remove()` leave one per run in /tmp.
pub const TempDir = struct {
    buf: [64:0]u8 = undefined,
    len: usize = 0,

    /// @return null when mkdtemp fails (callers `return error.SkipZigTest`).
    pub fn make(comptime stem: []const u8) ?TempDir {
        const tmpl = "/tmp/sketerm-" ++ stem ++ "-XXXXXX";
        var self = TempDir{};
        @memcpy(self.buf[0..tmpl.len], tmpl);
        self.buf[tmpl.len] = 0;
        if (c.mkdtemp(@ptrCast(&self.buf)) == null) return null;
        self.len = tmpl.len;
        return self;
    }

    pub fn path(self: *const TempDir) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn pathZ(self: *const TempDir) [*:0]const u8 {
        return @ptrCast(&self.buf);
    }

    pub fn remove(self: *const TempDir) void {
        removeTree(self.path());
    }
};

test "pathZ round-trips and rejects oversize" {
    var buf: [4096]u8 = undefined;
    const z = try pathZ(&buf, "/tmp/x");
    try std.testing.expectEqualStrings("/tmp/x", std.mem.span(z));
    const big = [_]u8{'a'} ** 4096;
    try std.testing.expectError(error.PathTooLong, pathZ(&buf, &big));
}

test "makeParentDirs creates nested dirs" {
    const td = TempDir.make("pathz") orelse return error.SkipZigTest;
    defer td.remove();
    const base = td.path();
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

test "makeDirs is idempotent and reports an uncreatable component" {
    const td = TempDir.make("mkdirs") orelse return error.SkipZigTest;
    defer td.remove();
    const base = td.path();
    var buf: [4096]u8 = undefined;
    const nested = try std.fmt.bufPrint(&buf, "{s}/a/b/c", .{base});
    try makeDirs(nested, 0o700);
    try makeDirs(nested, 0o700);
    var z_buf: [4096]u8 = undefined;
    var st: c.struct_stat = undefined;
    try std.testing.expect(c.stat(try pathZ(&z_buf, nested), &st) == 0);
    try std.testing.expect(st.st_mode & c.S_IFDIR != 0);

    try std.testing.expectError(error.MkdirFailed, makeDirs("", 0o700));
    try std.testing.expectError(error.MkdirFailed, makeDirs("/proc/definitely/not/creatable", 0o700));
}

test "removeTree takes a nested tree, a lone file and a missing path in stride" {
    const td = TempDir.make("rmtree") orelse return error.SkipZigTest;
    var buf: [4096]u8 = undefined;
    const nested = try std.fmt.bufPrint(&buf, "{s}/a/b/c", .{td.path()});
    try makeDirs(nested, 0o700);
    var fbuf: [4096:0]u8 = undefined;
    const file = try std.fmt.bufPrintZ(&fbuf, "{s}/a/b/c/f", .{td.path()});
    const fp = c.fopen(file.ptr, "wb") orelse return error.SkipZigTest;
    _ = c.fclose(fp);
    var z_buf: [4096]u8 = undefined;
    var st: c.struct_stat = undefined;
    // A file path is unlinked, not descended.
    removeTree(file);
    try std.testing.expect(c.stat(file.ptr, &st) != 0);
    // A symlink to a directory OUTSIDE the tree is unlinked, never
    // followed: the target keeps its contents.
    const keep = TempDir.make("rmtree-keep") orelse return error.SkipZigTest;
    defer keep.remove();
    var kbuf: [4096:0]u8 = undefined;
    const kept = try std.fmt.bufPrintZ(&kbuf, "{s}/kept", .{keep.path()});
    const kf = c.fopen(kept.ptr, "wb") orelse return error.SkipZigTest;
    _ = c.fclose(kf);
    var lbuf: [4096:0]u8 = undefined;
    const link = try std.fmt.bufPrintZ(&lbuf, "{s}/a/link", .{td.path()});
    try std.testing.expect(c.symlink(keep.pathZ(), link.ptr) == 0);
    td.remove();
    try std.testing.expect(c.stat(try pathZ(&z_buf, td.path()), &st) != 0);
    try std.testing.expect(c.stat(kept.ptr, &st) == 0);
    // Already gone: a no-op, not a crash.
    td.remove();
}
