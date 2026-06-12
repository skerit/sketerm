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

/// socket(2) with close-on-exec. SOCK_CLOEXEC as a type flag is a
/// Linux extension; Darwin sets the flag post-hoc via fcntl (the
/// fork window race is acceptable — children exec immediately).
pub fn socketCloexec(domain: c_int, sock_type: c_int, proto: c_int) c_int {
    if (is_linux) return c.socket(domain, sock_type | c.SOCK_CLOEXEC, proto);
    const fd = c.socket(domain, sock_type, proto);
    if (fd >= 0) _ = c.fcntl(fd, c.F_SETFD, c.FD_CLOEXEC);
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
pub inline fn stdin() [*c]c.FILE {
    return if (is_macos) c.stdin() else c.stdin;
}
pub inline fn stdout() [*c]c.FILE {
    return if (is_macos) c.stdout() else c.stdout;
}
pub inline fn stderr() [*c]c.FILE {
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
