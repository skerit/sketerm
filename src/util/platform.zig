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

extern fn _NSGetEnviron() [*c][*c][*c]u8;

/// Empty the process environment without depending on Darwin's missing clearenv declaration.
pub fn clearEnvironment() void {
    if (is_linux) {
        _ = c.clearenv();
    } else {
        const slot = _NSGetEnviron();
        if (slot != null and slot[0] != null) slot[0][0] = null;
    }
}

/// Clears libc's thread-local errno before an API whose sentinel is ambiguous.
pub fn clearErrno() void {
    if (is_linux)
        c.__errno_location().* = 0
    else
        c.__error().* = 0;
}

/// Returns libc's current thread-local errno value.
pub fn currentErrno() c_int {
    return if (is_linux) c.__errno_location().* else c.__error().*;
}

pub const RenameNoReplaceResult = enum { ok, exists, cross_device, failed };
pub const RenameExchangeResult = enum { ok, unsupported, cross_device, failed };

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

/// Atomically exchange two existing paths on the same filesystem.
pub fn renameExchange(first: [*:0]const u8, second: [*:0]const u8) RenameExchangeResult {
    if (is_linux) {
        const linux = std.os.linux;
        return switch (linux.errno(linux.renameat2(c.AT_FDCWD, first, c.AT_FDCWD, second, .{ .EXCHANGE = true }))) {
            .SUCCESS => .ok,
            .NOSYS, .INVAL, .OPNOTSUPP => .unsupported,
            .XDEV => .cross_device,
            else => .failed,
        };
    }
    const rc = c.renamex_np(first, second, @intCast(c.RENAME_SWAP));
    if (rc == 0) return .ok;
    return switch (std.posix.errno(rc)) {
        .NOSYS, .INVAL, .OPNOTSUPP => .unsupported,
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

/// PID on the other end of a connected Unix socket, when the OS exposes it.
pub fn unixPeerPid(fd: c_int) ?c.pid_t {
    if (is_linux) {
        const Cred = extern struct { pid: c.pid_t, uid: c.uid_t, gid: c.gid_t };
        var cred: Cred = undefined;
        var len: c.socklen_t = @sizeOf(Cred);
        if (c.getsockopt(fd, c.SOL_SOCKET, c.SO_PEERCRED, &cred, &len) != 0) return null;
        return if (cred.pid > 0) cred.pid else null;
    }
    if (is_macos) {
        // Darwin's LOCAL_PEERPID is stable but absent from Zig's bundled
        // cross-target headers. SOL_LOCAL=0 and LOCAL_PEERPID=2 are the XNU ABI.
        var pid: c.pid_t = 0;
        var len: c.socklen_t = @sizeOf(c.pid_t);
        if (c.getsockopt(fd, 0, 2, &pid, &len) != 0) return null;
        return if (pid > 0) pid else null;
    }
    return null;
}

/// The handler slot of `struct sigaction` is a union whose name AND
/// member spellings differ: glibc calls it `__sigaction_handler` with
/// `.sa_handler`/`.sa_sigaction`, Darwin calls it `__sigaction_u` with
/// `.__sa_handler`/`.__sa_sigaction`. These two setters are the only
/// place either spelling appears — callers just pass the function.
pub fn setSigHandler(sa: *c.struct_sigaction, handler: *const fn (c_int) callconv(.c) void) void {
    if (is_macos) {
        sa.__sigaction_u = .{ .__sa_handler = handler };
    } else {
        sa.__sigaction_handler = .{ .sa_handler = handler };
    }
}

/// SA_SIGINFO form of `setSigHandler` (three-argument handler).
pub fn setSigAction(
    sa: *c.struct_sigaction,
    handler: *const fn (c_int, [*c]c.siginfo_t, ?*anyopaque) callconv(.c) void,
) void {
    if (is_macos) {
        sa.__sigaction_u = .{ .__sa_sigaction = handler };
    } else {
        sa.__sigaction_handler = .{ .sa_sigaction = handler };
    }
}

/// Control socketpair for the broker↔worker channel: every control
/// message is ONE message carrying at most one SCM_RIGHTS fd, and
/// messages as large as `capacity` bytes have to survive the trip.
///
/// Linux uses SOCK_SEQPACKET. Darwin's AF_UNIX has no SEQPACKET at all —
/// socketpair() fails outright with EPROTONOSUPPORT — so it uses
/// SOCK_DGRAM, which preserves the same message boundaries. Two Darwin
/// consequences, both of which callers must handle:
///   * a closed peer surfaces as recv() == -1/ECONNRESET, NOT 0, so
///     "channel gone" has to be tested as `n <= 0`, never `n == 0`;
///   * the per-message size limit comes from the SOCKET BUFFER, and
///     net.local.dgram.maxdgram is only 2048 — well under one worker
///     metadata push. The buffers are raised here to fit `capacity`,
///     because a message over the limit is refused with EMSGSIZE and
///     the sender's change-hash has already moved on, so it is never
///     resent (the same permanent-staleness trap the truncation note
///     on WORKER_META_BUF describes).
/// Returns 0 on success (libc convention).
pub fn controlSocketpair(pair: *[2]c_int, capacity: usize) c_int {
    if (is_linux) return c.socketpair(c.AF_UNIX, c.SOCK_SEQPACKET, 0, pair);
    const r = c.socketpair(c.AF_UNIX, c.SOCK_DGRAM, 0, pair);
    if (r != 0) return r;
    // Ask for headroom over the payload: the buffer also has to cover
    // per-message bookkeeping, so an exactly-sized one can still refuse
    // a full-capacity message. Capped well under kern.ipc.maxsockbuf.
    const want: c_int = @intCast(@min(capacity *| 2, 4 << 20));
    for (pair) |fd| {
        for ([_]c_int{ c.SO_SNDBUF, c.SO_RCVBUF }) |opt| {
            _ = c.setsockopt(fd, c.SOL_SOCKET, opt, &want, @sizeOf(c_int));
        }
    }
    return 0;
}

/// Let any same-uid process attach a debugger to the CALLING process.
///
/// Linux Yama (`kernel.yama.ptrace_scope=1`, the distro default) allows
/// ptrace only from an ancestor. A daemon-hosted app therefore cannot be
/// traced by a gdb the daemon spawns — gdb is the app's SIBLING — which
/// is why `gdb -p` against one returns EPERM even to its own user. The
/// relaxation survives `execve`, so this is called once in the forked
/// child before exec and holds for the app's whole life.
///
/// Deliberately scoped: only sessions whose spawn request asked to be
/// debuggable (headless automation) call it. No-op off Linux, and a
/// no-op on a kernel without Yama, where the prctl simply fails.
pub fn allowAnyPtracer() void {
    if (!is_linux) return;
    // PR_SET_PTRACER_ANY, spelled out: musl's header defines it as
    // `(unsigned long)-1` and translate-c turns that into a negation of
    // an unsigned type, which does not compile (the mux-portable build
    // is where this surfaces).
    const ptracer_any: c_ulong = std.math.maxInt(c_ulong);
    _ = c.prctl(c.PR_SET_PTRACER, ptracer_any, @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0));
}

// ── runtime library probing ─────────────────────────────────────

extern fn dlopen(filename: [*:0]const u8, flags: c_int) ?*anyopaque;
const RTLD_LAZY: c_int = 0x1;

/// Prefixes to try in front of a bare soname on Darwin, in order.
/// Empty string first = the plain soname (system libraries, and any
/// DYLD_LIBRARY_PATH the user set).
const dl_prefixes = [_][]const u8{
    "",
    "/opt/homebrew/lib/", // Homebrew, Apple Silicon
    "/usr/local/lib/", // Homebrew, Intel
    "/opt/local/lib/", // MacPorts
};

/// dlopen the first of `names` that resolves, trying the prefixes a
/// package manager may have installed it under.
///
/// On Linux a bare soname is enough: ld.so's cache covers every
/// library directory the distro configured. **dyld has no equivalent
/// for third-party prefixes** — it searches `/usr/lib` and the shared
/// cache only — so a Homebrew library is invisible by soname alone.
/// Every runtime-probed optional feature then reports itself absent on
/// a Mac that has the library installed: no WebP/JXL preview codecs
/// (remote thumbnails degrade), no Opus compression, no OCR.
/// `$SKETERM_LIB_DIR` is honoured first for unusual prefixes.
pub fn dlopenAny(names: []const [*:0]const u8) ?*anyopaque {
    for (names) |name| {
        if (dlopen(name, RTLD_LAZY)) |h| return h;
        if (!is_macos) continue;
        const soname = std.mem.span(name);
        // A .so name on Darwin is a Linux entry in the same list; skip
        // the prefix expansion rather than build paths that cannot exist.
        if (std.mem.indexOf(u8, soname, ".dylib") == null) continue;
        var buf: [512]u8 = undefined;
        if (c.getenv("SKETERM_LIB_DIR")) |dir| {
            const d = std.mem.span(@as([*:0]const u8, @ptrCast(dir)));
            if (std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ std.mem.trimEnd(u8, d, "/"), soname })) |p| {
                if (dlopen(p.ptr, RTLD_LAZY)) |h| return h;
            } else |_| {}
        }
        for (dl_prefixes[1..]) |prefix| {
            const p = std.fmt.bufPrintZ(&buf, "{s}{s}", .{ prefix, soname }) catch continue;
            if (dlopen(p.ptr, RTLD_LAZY)) |h| return h;
        }
    }
    return null;
}

// ── extended attributes ─────────────────────────────────────────
//
// All four act on the LINK itself, never following a symlink. Linux
// spells that with an `l` prefix; Darwin has no such variants and takes
// XATTR_NOFOLLOW as an options flag, plus a `position` argument that is
// only meaningful for resource forks (always 0 here). Both platforms
// return the name list as NUL-separated strings.
//
// The `user.` namespace the callers require is a Linux rule (only that
// namespace is writable unprivileged). It is not required on Darwin but
// is kept there anyway: it keeps the browser away from `com.apple.*`
// attributes like quarantine and FinderInfo, and keeps one tag spelling
// across both platforms.

pub fn lgetxattr(path: [*:0]const u8, name: [*:0]const u8, buf: []u8) isize {
    if (is_linux) return c.lgetxattr(path, name, buf.ptr, buf.len);
    return c.getxattr(path, name, buf.ptr, buf.len, 0, c.XATTR_NOFOLLOW);
}

pub fn lsetxattr(path: [*:0]const u8, name: [*:0]const u8, value: []const u8) bool {
    if (is_linux) return c.lsetxattr(path, name, value.ptr, value.len, 0) == 0;
    return c.setxattr(path, name, value.ptr, value.len, 0, c.XATTR_NOFOLLOW) == 0;
}

pub fn lremovexattr(path: [*:0]const u8, name: [*:0]const u8) void {
    if (is_linux) {
        _ = c.lremovexattr(path, name);
        return;
    }
    _ = c.removexattr(path, name, c.XATTR_NOFOLLOW);
}

pub fn llistxattr(path: [*:0]const u8, buf: []u8) isize {
    if (is_linux) return c.llistxattr(path, buf.ptr, buf.len);
    return c.listxattr(path, buf.ptr, buf.len, c.XATTR_NOFOLLOW);
}

/// macOS: query a process's vnode paths (cwd + root) via libproc.
extern fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: ?*anyopaque, buffersize: c_int) c_int;

/// Working directory of a live process, written into `buf`; null when
/// it cannot be determined (dead pid, permission, no answer).
///
/// Linux reads the /proc/<pid>/cwd symlink. macOS has no /proc at all —
/// libproc's PROC_PIDVNODEPATHINFO carries the same answer. Layout of
/// `struct proc_vnodepathinfo`: two `vnode_info_path` entries, each
/// { struct vnode_info (152 bytes), char vip_path[MAXPATHLEN] }, so
/// pvi_cdir.vip_path sits at offset 152. VERIFIED on hardware (arm64,
/// macOS 26 SDK): sizeof(vnode_info)=152, offsetof(vip_path)=152,
/// flavor 9, live call matches getcwd().
///
/// This is the ONE implementation: the daemon resolves an upload's
/// destination directory through it, and a /proc-only version there is
/// what made every file transfer on macOS fail with "cannot determine
/// session directory".
pub fn cwdOfPid(pid: c.pid_t, buf: []u8) ?[]const u8 {
    if (pid <= 0) return null;
    if (is_macos) {
        const VNODE_INFO_SIZE = 152;
        const MAXPATHLEN = 1024;
        const PROC_PIDVNODEPATHINFO: c_int = 9;
        var info: [2 * (VNODE_INFO_SIZE + MAXPATHLEN)]u8 align(8) = undefined;
        const n = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, info.len);
        if (n <= VNODE_INFO_SIZE) return null;
        const path_bytes = info[VNODE_INFO_SIZE .. VNODE_INFO_SIZE + MAXPATHLEN];
        const len = std.mem.indexOfScalar(u8, path_bytes, 0) orelse MAXPATHLEN;
        if (len == 0 or len > buf.len) return null;
        @memcpy(buf[0..len], path_bytes[0..len]);
        return buf[0..len];
    }
    var path_buf: [64]u8 = undefined;
    const link = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/cwd", .{pid}) catch return null;
    const n = c.readlink(link.ptr, buf.ptr, buf.len);
    if (n <= 0) return null;
    return buf[0..@intCast(n)];
}

/// macOS: short process name for a pid (libproc). Preferred over
/// picking `pbi_comm` out of `proc_bsdinfo` by offset, which we have no
/// hardware here to verify.
extern fn proc_name(pid: c_int, buffer: ?*anyopaque, buffersize: u32) c_int;

/// Name of the FOREGROUND process on a pty — what the user is actually
/// looking at (`nvim`), not the shell that spawned it. Feeds the
/// `{{ PROGRAM }}` title placeholder.
///
/// `tcgetpgrp` on the MASTER fd gives the foreground process group the
/// terminal is currently steering; its pgid doubles as the group
/// leader's pid. Null when there is no foreground group (child gone,
/// fd not a tty) or the name cannot be read.
///
/// NOT VERIFIED on macOS hardware — the Linux path is what the daemon
/// exercises today; the libproc call is the documented equivalent.
pub fn foregroundProgram(master_fd: c_int, buf: []u8) ?[]const u8 {
    if (master_fd < 0) return null;
    const pgrp = c.tcgetpgrp(master_fd);
    if (pgrp <= 0) return null;

    if (is_macos) {
        var name_buf: [256]u8 = undefined;
        const n = proc_name(@intCast(pgrp), &name_buf, name_buf.len);
        if (n <= 0) return null;
        const len = @min(@as(usize, @intCast(n)), buf.len);
        @memcpy(buf[0..len], name_buf[0..len]);
        return buf[0..len];
    }

    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/comm", .{pgrp}) catch return null;
    const fd = c.open(path.ptr, c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return null;
    defer _ = c.close(fd);
    const n = c.read(fd, buf.ptr, buf.len);
    if (n <= 0) return null;
    var len: usize = @intCast(n);
    // /proc/<pid>/comm is newline-terminated.
    while (len > 0 and (buf[len - 1] == '\n' or buf[len - 1] == 0)) len -= 1;
    return buf[0..len];
}

/// macOS: every pid on the system, in one libproc call.
extern fn proc_listallpids(buffer: ?*anyopaque, buffersize: c_int) c_int;

/// macOS: raw sysctl. Used for KERN_PROCARGS2, the only way to read
/// another process's environment on a system with no /proc.
extern fn sysctl(
    name: [*]c_int,
    namelen: c_uint,
    oldp: ?*anyopaque,
    oldlenp: *usize,
    newp: ?*anyopaque,
    newlen: usize,
) c_int;

/// Every live pid, written into `buf`; returns the slice that fit.
///
/// Exists so a test rig can find the processes ONE of its runs started
/// by looking at their environments — see `environOfPid`. Enumerating
/// pids is the part with no portable spelling: Linux lists /proc,
/// Darwin asks libproc.
pub fn listPids(buf: []c.pid_t) []c.pid_t {
    if (buf.len == 0) return buf[0..0];
    if (is_macos) {
        const bytes: c_int = @intCast(@min(buf.len * @sizeOf(c.pid_t), std.math.maxInt(c_int)));
        const n = proc_listallpids(buf.ptr, bytes);
        if (n <= 0) return buf[0..0];
        return buf[0..@min(@as(usize, @intCast(n)), buf.len)];
    }
    const d = c.opendir("/proc") orelse return buf[0..0];
    defer _ = c.closedir(d);
    var used: usize = 0;
    while (c.readdir(d)) |ent| {
        if (used == buf.len) break;
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
        buf[used] = std.fmt.parseInt(c.pid_t, name, 10) catch continue;
        used += 1;
    }
    return buf[0..used];
}

/// A live process's environment block, NUL-separated, written into
/// `buf`. Null when it cannot be read — a dead pid, another user's
/// process, or a buffer too small to hold the answer.
///
/// **Null means "cannot establish ownership", and every caller must
/// treat that as "not mine".** A sweep that kills what it cannot
/// identify is a sweep that eventually kills the user's real daemon.
///
/// Linux reads /proc/<pid>/environ. macOS has no /proc: KERN_PROCARGS2
/// returns one block laid out as `int argc`, the exec path, NUL
/// padding, `argc` argv strings, and THEN the environment — so the
/// environ block is found by stepping over the first two parts. What
/// comes back is byte-identical in shape to Linux's file (NUL-separated
/// `KEY=VALUE`), which is what lets both callers share one parser.
///
/// The whole args+environ region is copied, so `buf` must be big enough
/// for both; 64 KiB covers any ordinary process. A short buffer fails
/// closed (ENOMEM -> null) rather than returning a truncated block that
/// a substring search could read as a miss.
///
/// **On macOS this is the environment AS OF execve, not the current
/// one** — MEASURED, not assumed: a `setenv` after start is invisible
/// through KERN_PROCARGS2, while the same variable inherited across an
/// exec is right there. Linux's /proc/<pid>/environ has the same
/// property for the same reason, so the two agree. Every caller here
/// marks a child by calling `setenv` in the forked child BEFORE it
/// execs, which is exactly the case that survives; do not switch a
/// caller to marking itself after startup and expect a sweep to see it.
///
/// **macOS discloses the environment only for ORDINARY binaries.** An
/// Apple platform binary (/bin/sleep and friends) comes back as a
/// ~29-byte block holding argc and argv and NO environment at all,
/// however the call is made — also measured. Our own locally built,
/// ad-hoc-signed binaries disclose normally, which is all a sweep for
/// sketerm's own processes needs. A caller that must identify a SYSTEM
/// process this way cannot, and must not read that null as "no match".
pub fn environOfPid(pid: c.pid_t, buf: []u8) ?[]u8 {
    if (pid <= 0 or buf.len == 0) return null;
    if (is_macos) {
        const CTL_KERN: c_int = 1;
        const KERN_PROCARGS2: c_int = 49;
        var mib = [3]c_int{ CTL_KERN, KERN_PROCARGS2, pid };
        var len: usize = buf.len;
        if (sysctl(&mib, mib.len, buf.ptr, &len, null, 0) != 0) return null;
        if (len <= @sizeOf(c_int)) return null;

        var argc: c_int = undefined;
        @memcpy(std.mem.asBytes(&argc), buf[0..@sizeOf(c_int)]);
        if (argc < 0) return null;

        var at: usize = @sizeOf(c_int);
        // The exec path, then the NUL padding that aligns what follows.
        while (at < len and buf[at] != 0) at += 1;
        while (at < len and buf[at] == 0) at += 1;
        // argc argv strings, each NUL-terminated.
        var left: c_int = argc;
        while (left > 0 and at < len) : (left -= 1) {
            while (at < len and buf[at] != 0) at += 1;
            at += 1;
        }
        if (left > 0 or at >= len) return null;
        return buf[at..len];
    }

    var path_buf: [64:0]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/environ", .{pid}) catch return null;
    const fd = c.open(path.ptr, c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return null;
    defer _ = c.close(fd);
    var used: usize = 0;
    while (used < buf.len) {
        const n = c.read(fd, buf.ptr + used, buf.len - used);
        if (n <= 0) break;
        used += @intCast(n);
    }
    if (used == 0) return null;
    if (used == buf.len) {
        // Full buffer: either the block ends exactly here or it does
        // not fit. A partial block must never be returned -- a
        // substring search would misread it as "not my process".
        var probe: [1]u8 = undefined;
        if (c.read(fd, &probe, 1) > 0) return null;
    }
    return buf[0..used];
}

/// A `signal()` handler slot: what libc calls `sig_t`.
pub const SigHandler = ?*const fn (c_int) callconv(.c) void;

/// `SIG_DFL` as a VALUE. <signal.h> defines it as a cast of 0 to a
/// function pointer, and translate-c renders that as a `@compileError`
/// on Darwin — so `c.SIG_DFL` compiles on Linux and breaks the macOS
/// build the moment anything references it. That is not hypothetical:
/// it is what stopped `smoke-e2e` building here at all.
///
/// A null function pointer IS 0, which is what the macro expands to, so
/// this is the same value with a type Zig can carry. `SIG_IGN` gets no
/// twin on purpose — its raw value (1) violates fn-pointer alignment on
/// aarch64-macos; use a no-op handler instead (`sigNoop` in mux_main).
pub const sig_dfl: SigHandler = null;

/// Make the calling process die when its parent does. Called in a
/// forked child, before exec.
///
/// Linux: `prctl(PR_SET_PDEATHSIG, SIGKILL)`. That is a *process
/// attribute* and SURVIVES execve — the only reason it is usable here,
/// since every caller execs immediately afterwards.
///
/// **macOS has no equivalent, and this is deliberately a no-op rather
/// than a kqueue watch.** `EVFILT_PROC`/`NOTE_EXIT` on the parent needs
/// a live kqueue fd and a thread to read it; execve destroys both
/// microseconds later, so the watch would be gone before the child is
/// even the program it is meant to supervise. Covering an exec'd child
/// would take a supervisor process wedged between parent and child.
///
/// Do not add one on the strength of the orphan bug: PDEATHSIG never
/// covered that case on Linux either. The worst orphan a rig leaves is
/// an AUTOSTARTED replacement daemon — double-forked, child of init,
/// nobody's descendant. What catches it on both platforms is the
/// environment sweep built on `listPids` + `environOfPid`.
pub fn dieWithParent() void {
    if (is_linux) {
        const PR_SET_PDEATHSIG: c_long = 1;
        _ = c.syscall(@intFromEnum(std.os.linux.SYS.prctl), PR_SET_PDEATHSIG, @as(c_long, c.SIGKILL));
    }
}

/// memfd_create is in both glibc and musl libc but its declaration
/// hides behind _GNU_SOURCE, which the translate-c pass doesn't
/// define — declare it ourselves (Linux-only; resolved at link).
extern fn memfd_create(name: [*:0]const u8, flags: c_uint) c_int;

/// Anonymous file fd, sized and CLOEXEC — the shm backing for
/// keymaps the mux daemon hands to Wayland apps. Linux: memfd.
/// macOS: shm_open with a throwaway name, unlinked immediately.
///
/// **`size == 0` means "create it, do not size it"**, and that
/// distinction is load-bearing on macOS: a POSIX shared-memory object
/// there accepts `ftruncate` EXACTLY ONCE, and any later call fails
/// with EINVAL. So a caller that sizes the object itself (the browser
/// helper mints a frame buffer, then truncates it to the view's real
/// dimensions) must not have that one chance spent here on a zero-sized
/// truncate. Linux's memfd has no such rule and can be resized freely;
/// passing 0 there simply skips a redundant syscall.
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
    if (size != 0 and c.ftruncate(fd, @intCast(size)) != 0) {
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

test "unixPeerPid identifies a Unix socket peer" {
    var pair: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), socketpairCloexec(&pair));
    defer _ = c.close(pair[0]);
    defer _ = c.close(pair[1]);
    try std.testing.expectEqual(@as(?c.pid_t, c.getpid()), unixPeerPid(pair[0]));
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

test "foregroundProgram reads the real foreground process on a pty" {
    if (!is_linux) return error.SkipZigTest;

    // forkpty does the setsid + TIOCSCTTY dance, so the child's process
    // group really is the pty's foreground group — which is exactly
    // what tcgetpgrp must report.
    var master: c_int = undefined;
    const pid = c.forkpty(&master, null, null, null);
    try std.testing.expect(pid >= 0);
    if (pid == 0) {
        _ = c.execl("/bin/sleep", "sleep", "5", @as([*c]const u8, null));
        c._exit(127);
    }
    defer {
        _ = c.kill(pid, c.SIGKILL);
        var status: c_int = 0;
        _ = c.waitpid(pid, &status, 0);
        _ = c.close(master);
    }

    // Poll: the name only becomes "sleep" once the child has exec'd.
    var buf: [32]u8 = undefined;
    var tries: u32 = 0;
    while (tries < 200) : (tries += 1) {
        if (foregroundProgram(master, &buf)) |name| {
            if (std.mem.eql(u8, name, "sleep")) return;
        }
        _ = c.usleep(10_000);
    }
    return error.ForegroundProgramNeverResolved;
}

test "listPids finds this process among the live pids" {
    var buf: [8192]c.pid_t = undefined;
    const pids = listPids(&buf);
    try std.testing.expect(pids.len > 1);
    const self = c.getpid();
    for (pids) |pid| {
        if (pid == self) return;
    }
    return error.SelfNotListed;
}

test "environOfPid returns a well-formed inherited environment" {
    // PATH is inherited across the exec that started this test runner,
    // so it is in the exec-time snapshot on both platforms. (A marker
    // set by THIS process would not be — see the next test.)
    var buf: [64 * 1024]u8 = undefined;
    const env = environOfPid(c.getpid(), &buf) orelse return error.NoEnviron;
    try std.testing.expect(std.mem.indexOf(u8, env, "PATH=") != null);

    // NUL-separated KEY=VALUE, the shape both sweeps parse.
    var it = std.mem.splitScalar(u8, env, 0);
    var pairs: usize = 0;
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        if (std.mem.indexOfScalar(u8, entry, '=') != null) pairs += 1;
    }
    try std.testing.expect(pairs > 0);
}

test "environOfPid reflects exec time, not the live environment" {
    // Pins the semantic both callers depend on, on BOTH platforms: a
    // process marks a child before exec, never itself afterwards. If
    // this ever starts passing, someone has changed the mechanism and
    // the sweeps' "set it in the child before execv" contract needs
    // rechecking rather than celebrating.
    const key = "SKETERM_PLATFORM_LIVE_ONLY_PROBE";
    try std.testing.expectEqual(@as(c_int, 0), c.setenv(key, "1", 1));
    defer _ = c.unsetenv(key);

    var buf: [64 * 1024]u8 = undefined;
    const env = environOfPid(c.getpid(), &buf) orelse return error.NoEnviron;
    try std.testing.expect(std.mem.indexOf(u8, env, key) == null);
}

test "environOfPid fails closed rather than truncating" {
    // Too small to hold the block: null, never a partial answer a
    // substring search would misread as "this process is not mine".
    var tiny: [16]u8 = undefined;
    try std.testing.expect(environOfPid(c.getpid(), &tiny) == null);
    var buf: [4096]u8 = undefined;
    try std.testing.expect(environOfPid(-1, &buf) == null);
    try std.testing.expect(environOfPid(0, &buf) == null);
}

test "foregroundProgram returns null for a non-tty fd" {
    var buf: [32]u8 = undefined;
    try std.testing.expect(foregroundProgram(-1, &buf) == null);
    // A pipe read end is a valid fd but has no foreground process group.
    var fds: [2]c_int = undefined;
    try std.testing.expect(c.pipe(&fds) == 0);
    defer {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
    }
    try std.testing.expect(foregroundProgram(fds[0], &buf) == null);
}
