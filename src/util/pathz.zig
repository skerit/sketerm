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

/// Unlink `path`, ignoring every failure (already gone, permissions,
/// oversize path). For the "drop the file we own" call sites, where
/// nothing can be done about a failure and nothing wants to know.
pub fn unlinkPath(path: []const u8) void {
    var z: [4096]u8 = undefined;
    if (pathZ(&z, path)) |p| {
        _ = c.unlink(p);
    } else |_| {}
}

/// Force `path`'s DIRECTORY entry to stable storage, so a crash cannot
/// lose a rename or unlink that already returned.
///
/// A path with no directory component names an entry in the current
/// directory, so that is what gets synced: the two hand-rolled copies
/// this replaced disagreed there (one claimed success without syncing
/// anything, the other reported failure), and both were wrong about
/// the same case.
/// @return false when the parent could not be opened or fsynced.
pub fn fsyncParent(path: []const u8) bool {
    const parent = std.fs.path.dirname(path) orelse ".";
    var z: [4096]u8 = undefined;
    const dfd = c.open(pathZ(&z, parent) catch return false, c.O_RDONLY | c.O_DIRECTORY);
    if (dfd < 0) return false;
    defer _ = c.close(dfd);
    return c.fsync(dfd) == 0;
}

/// Whether `name` resolves to an executable through `$PATH`.
///
/// Empty `$PATH` entries are SKIPPED rather than read as ".": every
/// caller is probing for an optional helper binary, and picking one up
/// out of the current directory is not what any of them mean.
pub fn executableOnPath(name: []const u8) bool {
    const path_env = c.getenv("PATH") orelse return false;
    var it = std.mem.splitScalar(u8, std.mem.span(@as([*:0]const u8, @ptrCast(path_env))), ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        var z: [4096:0]u8 = undefined;
        const p = std.fmt.bufPrintZ(&z, "{s}/{s}", .{ dir, name }) catch continue;
        if (c.access(p.ptr, c.X_OK) == 0) return true;
    }
    return false;
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

test "unlinkPath drops a file and shrugs at a missing one" {
    const td = TempDir.make("unlinkp") orelse return error.SkipZigTest;
    defer td.remove();
    var buf: [4096:0]u8 = undefined;
    const file = try std.fmt.bufPrintZ(&buf, "{s}/gone", .{td.path()});
    const fp = c.fopen(file.ptr, "wb") orelse return error.SkipZigTest;
    _ = c.fclose(fp);
    var st: c.struct_stat = undefined;
    try std.testing.expect(c.stat(file.ptr, &st) == 0);
    unlinkPath(file);
    try std.testing.expect(c.stat(file.ptr, &st) != 0);
    // Absent path, oversize path and a directory: all silent.
    unlinkPath(file);
    unlinkPath(&([_]u8{'a'} ** 5000));
    unlinkPath(td.path());
    try std.testing.expect(c.stat(td.pathZ(), &st) == 0);
}

test "fsyncParent syncs a real parent and reports an unopenable one" {
    const td = TempDir.make("fsyncp") orelse return error.SkipZigTest;
    defer td.remove();
    var buf: [4096]u8 = undefined;
    const file = try std.fmt.bufPrint(&buf, "{s}/f", .{td.path()});
    try std.testing.expect(fsyncParent(file));
    // No directory component: the current directory is the parent.
    try std.testing.expect(fsyncParent("f"));
    try std.testing.expect(!fsyncParent("/definitely/not/a/directory/f"));
}

test "executableOnPath finds a real binary and misses a made-up one" {
    const saved = c.getenv("PATH");
    var saved_copy: [4096:0]u8 = undefined;
    var saved_len: usize = 0;
    if (saved) |p| {
        const span = std.mem.span(@as([*:0]const u8, @ptrCast(p)));
        if (span.len >= saved_copy.len) return error.SkipZigTest;
        @memcpy(saved_copy[0..span.len], span);
        saved_len = span.len;
    }
    saved_copy[saved_len] = 0;
    defer if (saved != null) {
        _ = c.setenv("PATH", &saved_copy, 1);
    } else {
        _ = c.unsetenv("PATH");
    };

    const td = TempDir.make("onpath") orelse return error.SkipZigTest;
    defer td.remove();
    var buf: [4096:0]u8 = undefined;
    const bin = try std.fmt.bufPrintZ(&buf, "{s}/sketerm-fake-tool", .{td.path()});
    const fp = c.fopen(bin.ptr, "wb") orelse return error.SkipZigTest;
    _ = c.fclose(fp);
    try std.testing.expect(c.chmod(bin.ptr, 0o755) == 0);

    // An empty entry and a trailing colon are both skipped, never read
    // as the current directory.
    var path_buf: [4096:0]u8 = undefined;
    const path_env = try std.fmt.bufPrintZ(&path_buf, "::{s}:", .{td.path()});
    try std.testing.expect(c.setenv("PATH", path_env.ptr, 1) == 0);
    try std.testing.expect(executableOnPath("sketerm-fake-tool"));
    try std.testing.expect(!executableOnPath("sketerm-no-such-tool"));

    // Non-executable file on PATH is not a hit.
    try std.testing.expect(c.chmod(bin.ptr, 0o644) == 0);
    try std.testing.expect(!executableOnPath("sketerm-fake-tool"));

    // Empty PATH: nothing resolves, and "." is not consulted.
    try std.testing.expect(c.setenv("PATH", "", 1) == 0);
    try std.testing.expect(!executableOnPath("sketerm-fake-tool"));
}
