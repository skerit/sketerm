//! Platform abstraction — the small set of OS-specific primitives
//! sketerm needs. Everything else in the tree is POSIX-portable;
//! anything Linux-vs-macOS lives HERE, keyed on `builtin.os.tag` at
//! comptime so dead branches never reference missing C decls.
//!
//! Importable from both dependency sets (GUI cbindings and the lean
//! mux core set) — only libc symbols, no GTK/GLib.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("../c.zig").c;

pub const is_linux = builtin.os.tag == .linux;
pub const is_macos = builtin.os.tag == .macos;

pub const RenameNoReplaceResult = enum { ok, exists, cross_device, failed };

/// Atomically install `old_path` at a destination that must not exist.
pub fn renameNoReplace(old_path: [*:0]const u8, new_path: [*:0]const u8) RenameNoReplaceResult {
    if (is_linux) {
        const linux = std.os.linux;
        return switch (linux.errno(linux.renameat2(c.AT_FDCWD, old_path, c.AT_FDCWD, new_path, .{ .NOREPLACE = true }))) {
            .SUCCESS => .ok,
            .EXIST => .exists,
            .XDEV => .cross_device,
            else => .failed,
        };
    }
    const rc = c.renamex_np(old_path, new_path, @intCast(c.RENAME_EXCL));
    if (rc == 0) return .ok;
    return switch (std.posix.errno(rc)) {
        .EXIST => .exists,
        .XDEV => .cross_device,
        else => .failed,
    };
}

/// macOS: dyld's path-of-this-binary call (libc, always present).
extern fn _NSGetExecutablePath(buf: [*]u8, bufsize: *u32) c_int;

/// Absolute path of the running executable, written into `buf`.
/// Linux: /proc/self/exe. macOS: _NSGetExecutablePath + realpath
/// (the dyld path may contain symlinks/"..").
pub fn exePath(buf: *[4096]u8) ?[]const u8 {
    if (is_macos) {
        var raw: [4096]u8 = undefined;
        var size: u32 = raw.len;
        if (_NSGetExecutablePath(&raw, &size) != 0) return null;
        // realpath(3) needs its own out buffer of PATH_MAX.
        if (c.realpath(@ptrCast(&raw), @ptrCast(buf)) == null) {
            // Unresolvable (deleted dir?) — fall back to the raw path.
            const len = std.mem.len(@as([*:0]const u8, @ptrCast(&raw)));
            if (len >= buf.len) return null;
            @memcpy(buf[0..len], raw[0..len]);
            return buf[0..len];
        }
        return std.mem.sliceTo(buf, 0);
    }
    const n = c.readlink("/proc/self/exe", buf, buf.len - 1);
    if (n <= 0) return null;
    return buf[0..@intCast(n)];
}

/// Path to exec THIS process's own image, for self-spawn sites
/// (job helpers, keepers, daemon autostart).
/// Linux: the literal "/proc/self/exe" symlink — readlink of it
/// grows a " (deleted)" suffix once a package upgrade replaces the
/// binary on disk, and execv of that string fails (the long-running
/// daemon then reports "job helper died" for every job). Execing
/// the symlink itself always runs the caller's own (consistent)
/// image. macOS has no such symlink; the resolved path is the best
/// available there.
pub fn selfExecPathZ(buf: *[4096:0]u8) ?[:0]const u8 {
    if (is_linux) {
        const p = "/proc/self/exe";
        @memcpy(buf[0..p.len], p);
        buf[p.len] = 0;
        return buf[0..p.len :0];
    }
    return exePathZ(buf);
}

/// socket(2) with close-on-exec. SOCK_CLOEXEC as a type flag is a
/// Linux extension; Darwin sets the flag post-hoc via fcntl (the
/// fork window race is acceptable — children exec immediately).
pub fn socketCloexec(domain: c_int, sock_type: c_int, proto: c_int) c_int {
    if (is_linux) return c.socket(domain, sock_type | c.SOCK_CLOEXEC, proto);
    const fd = c.socket(domain, sock_type, proto);
    if (fd >= 0) _ = c.fcntl(fd, c.F_SETFD, c.FD_CLOEXEC);
    return fd;
}

/// socketpair(2) with close-on-exec on BOTH ends, same Linux-vs-Darwin
/// split as socketCloexec. Returns 0 on success (libc convention).
pub fn socketpairCloexec(pair: *[2]c_int) c_int {
    if (is_linux) return c.socketpair(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0, pair);
    const r = c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, pair);
    if (r == 0) {
        _ = c.fcntl(pair[0], c.F_SETFD, c.FD_CLOEXEC);
        _ = c.fcntl(pair[1], c.F_SETFD, c.FD_CLOEXEC);
    }
    return r;
}

/// memfd_create is in both glibc and musl libc but its declaration
/// hides behind _GNU_SOURCE, which the translate-c pass doesn't
/// define — declare it ourselves (Linux-only; resolved at link).
extern fn memfd_create(name: [*:0]const u8, flags: c_uint) c_int;

/// Anonymous file fd, sized and CLOEXEC — the shm backing for
/// keymaps the mux daemon hands to Wayland apps. Linux: memfd.
/// macOS: shm_open with a throwaway name, unlinked immediately.
pub fn anonFileFd(size: usize) c_int {
    var fd: c_int = -1;
    if (is_linux) {
        fd = memfd_create("sketerm-anon", 1); // MFD_CLOEXEC
    } else {
        var name_buf: [64]u8 = undefined;
        const name = std.fmt.bufPrintZ(&name_buf, "/sketerm-anon-{d}", .{c.getpid()}) catch return -1;
        // shm_open is variadic on Darwin — the mode needs a fixed type.
        fd = c.shm_open(name.ptr, c.O_RDWR | c.O_CREAT | c.O_EXCL, @as(c.mode_t, 0o600));
        if (fd >= 0) {
            _ = c.shm_unlink(name.ptr);
            _ = c.fcntl(fd, c.F_SETFD, c.FD_CLOEXEC);
        }
    }
    if (fd < 0) return -1;
    if (c.ftruncate(fd, @intCast(size)) != 0) {
        _ = c.close(fd);
        return -1;
    }
    return fd;
}

/// exePath with a NUL terminator — for execv/dirname-style callers.
pub fn exePathZ(buf: *[4096:0]u8) ?[:0]const u8 {
    var tmp: [4096]u8 = undefined;
    const p = exePath(&tmp) orelse return null;
    if (p.len >= buf.len) return null;
    @memcpy(buf[0..p.len], p);
    buf[p.len] = 0;
    return buf[0..p.len :0];
}

/// C stdio streams. glibc exports stdin/stdout/stderr as extern
/// `FILE *` variables, so `c.stdout` is a value. Darwin's <stdio.h>
/// defines them as macros over __stdinp/__stdoutp/__stderrp, which
/// translate-c renders as inline FUNCTIONS — referencing `c.stdout`
/// there yields a function, not a stream. Always go through these.
/// Return type is `?*c.FILE`, not `[*c]c.FILE`: glibc's FILE
/// translates as an opaque struct, and C pointers to opaque types
/// are rejected; Darwin's sized `[*c]FILE` coerces to `?*FILE`.
pub inline fn stdin() ?*c.FILE {
    return if (is_macos) c.stdin() else c.stdin;
}
pub inline fn stdout() ?*c.FILE {
    return if (is_macos) c.stdout() else c.stdout;
}
pub inline fn stderr() ?*c.FILE {
    return if (is_macos) c.stderr() else c.stderr;
}

/// Cross-thread wakeup primitive for poll loops. Linux: an eventfd
/// (one fd, kernel-coalesced counter). macOS/other: a non-blocking
/// pipe pair. Poll `read_fd`; `signal()` from any thread.
pub const Wakeup = struct {
    read_fd: c_int,
    write_fd: c_int,

    pub fn init() !Wakeup {
        if (is_linux) {
            const efd = c.eventfd(0, c.EFD_NONBLOCK | c.EFD_CLOEXEC);
            if (efd < 0) return error.WakeupInit;
            return .{ .read_fd = efd, .write_fd = efd };
        }
        var fds: [2]c_int = undefined;
        if (c.pipe(&fds) != 0) return error.WakeupInit;
        for (fds) |fd| {
            _ = c.fcntl(fd, c.F_SETFD, c.FD_CLOEXEC);
            const fl = c.fcntl(fd, c.F_GETFL);
            _ = c.fcntl(fd, c.F_SETFL, fl | c.O_NONBLOCK);
        }
        return .{ .read_fd = fds[0], .write_fd = fds[1] };
    }

    /// Async-signal-safe, callable from any thread. Loops on EINTR;
    /// a full pipe is fine (the reader is already pending wakeup).
    pub fn signal(self: Wakeup) void {
        const one: u64 = 1;
        const n: usize = if (is_linux) 8 else 1;
        while (true) {
            const w = c.write(self.write_fd, &one, n);
            if (w >= 0) break;
            if (std.posix.errno(w) != .INTR) break;
        }
    }

    pub fn close(self: Wakeup) void {
        _ = c.close(self.read_fd);
        if (self.write_fd != self.read_fd) _ = c.close(self.write_fd);
    }
};

/// Per-user runtime directory for sockets: $XDG_RUNTIME_DIR when set
/// (Linux convention), else $TMPDIR, else /tmp. macOS has no
/// XDG_RUNTIME_DIR; its per-user $TMPDIR (/var/folders/...) gives
/// the same ownership guarantees.
pub fn runtimeDir() []const u8 {
    if (c.getenv("XDG_RUNTIME_DIR")) |p| {
        const s = std.mem.span(@as([*:0]const u8, @ptrCast(p)));
        if (s.len > 0) return s;
    }
    if (is_macos) {
        // $TMPDIR is the per-user temp dir, but a non-interactive SSH
        // session may not have it in the environment — so a daemon
        // launched at GUI login and a `sketerm-mux --proxy` bridge
        // arriving over SSH would resolve DIFFERENT default sockets
        // and never find each other. confstr returns the same
        // /var/folders/.../T path directly, set or not. The static
        // buffer outlives the slice (same as the env spans above).
        const S = struct {
            var buf: [128]u8 = undefined;
        };
        const n = c.confstr(c._CS_DARWIN_USER_TEMP_DIR, &S.buf, S.buf.len);
        // confstr's count includes the trailing NUL; the path has a
        // trailing slash. Keep it only if it fits Darwin's 104-byte
        // sun_path with room for sketerm/<pid>.sock.
        if (n > 1 and n <= S.buf.len and n < 70) {
            return std.mem.trimEnd(u8, S.buf[0 .. n - 1], "/");
        }
    }
    if (c.getenv("TMPDIR")) |p| {
        const s = std.mem.span(@as([*:0]const u8, @ptrCast(p)));
        // Unix socket sun_path is 104 bytes on Darwin — a long
        // /var/folders path still leaves room for sketerm/<pid>.sock.
        if (s.len > 0 and s.len < 70) return std.mem.trimEnd(u8, s, "/");
    }
    return "/tmp";
}

test "runtimeDir returns something usable" {
    const dir = runtimeDir();
    try std.testing.expect(dir.len > 0);
    try std.testing.expect(dir[0] == '/');
}

test "Wakeup signal/read round-trip" {
    const wk = try Wakeup.init();
    defer wk.close();
    wk.signal();
    var pfd = [_]c.struct_pollfd{
        .{ .fd = wk.read_fd, .events = c.POLLIN, .revents = 0 },
    };
    const n = c.poll(&pfd, 1, 1000);
    try std.testing.expect(n == 1);
    try std.testing.expect(pfd[0].revents & c.POLLIN != 0);
}
