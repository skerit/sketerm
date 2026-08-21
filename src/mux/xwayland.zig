//! Daemon-owned rootless Xwayland infrastructure via xwayland-satellite.
//!
//! The daemon owns the X listeners, display lock and Xauthority record;
//! satellite owns Xwayland + XWM semantics and presents every X11 window to
//! our existing compositor as an ordinary xdg-shell surface.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("../c.zig").c;
const platform = @import("../util/platform.zig");
const pathZ = @import("../util/pathz.zig").pathZ;
const log = @import("log.zig");

const X11_DIR = "/tmp/.X11-unix";
const DISPLAY_FIRST: u16 = 100;
const DISPLAY_TRIES: u16 = 100;

pub const Instance = struct {
    allocator: std.mem.Allocator,
    number: u16,
    display_name: []u8,
    auth_path: []u8,
    socket_path: []u8,
    lock_path: []u8,
    wayland_display: []u8,
    runtime_dir: []u8,
    unix_fd: c_int,
    abstract_fd: c_int,
    pid: c.pid_t = -1,
    pgid: c.pid_t = -1,
    gpu: bool,
    retry_after_ms: i64 = 0,

    pub fn setup(
        allocator: std.mem.Allocator,
        base_dir: []const u8,
        wayland_display: []const u8,
        runtime_dir: []const u8,
        gpu: bool,
    ) !?Instance {
        if (comptime builtin.os.tag != .linux) return null;
        if (!executableOnPath("xwayland-satellite") or !executableOnPath("Xwayland")) return null;
        try ensureX11Dir();

        var number: u16 = DISPLAY_FIRST;
        while (number < DISPLAY_FIRST + DISPLAY_TRIES) : (number += 1) {
            if (try reserve(allocator, base_dir, wayland_display, runtime_dir, gpu, number)) |instance|
                return instance;
        }
        return error.NoFreeXDisplay;
    }

    pub fn deinit(self: *Instance) void {
        self.stop();
        if (self.unix_fd >= 0) _ = c.close(self.unix_fd);
        if (self.abstract_fd >= 0) _ = c.close(self.abstract_fd);
        unlinkOwned(self.socket_path);
        unlinkOwned(self.lock_path);
        unlinkOwned(self.auth_path);
        self.allocator.free(self.display_name);
        self.allocator.free(self.auth_path);
        self.allocator.free(self.socket_path);
        self.allocator.free(self.lock_path);
        self.allocator.free(self.wayland_display);
        self.allocator.free(self.runtime_dir);
        self.* = undefined;
    }

    pub fn start(self: *Instance) bool {
        if (comptime builtin.os.tag != .linux) return false;
        if (self.pid > 0) return true;
        const now = nowMs();
        if (now < self.retry_after_ms) return false;
        self.retry_after_ms = now + 1000;

        var display_buf: [16:0]u8 = undefined;
        const display = std.fmt.bufPrintZ(&display_buf, "{s}", .{self.display_name}) catch return false;
        var unix_buf: [16:0]u8 = undefined;
        const unix_fd = std.fmt.bufPrintZ(&unix_buf, "{d}", .{self.unix_fd}) catch return false;
        var abstract_buf: [16:0]u8 = undefined;
        const abstract_fd = std.fmt.bufPrintZ(&abstract_buf, "{d}", .{self.abstract_fd}) catch return false;
        var auth_buf: [4096:0]u8 = undefined;
        const auth = std.fmt.bufPrintZ(&auth_buf, "{s}", .{self.auth_path}) catch return false;
        var wl_buf: [4096:0]u8 = undefined;
        const wl = std.fmt.bufPrintZ(&wl_buf, "{s}", .{self.wayland_display}) catch return false;
        var rt_buf: [4096:0]u8 = undefined;
        const rt = std.fmt.bufPrintZ(&rt_buf, "{s}", .{self.runtime_dir}) catch return false;

        const owner_pid = c.getpid();
        const pid = c.fork();
        if (pid < 0) return false;
        if (pid == 0) {
            _ = c.setpgid(0, 0);
            // A SIGKILLed daemon cannot run deinit; ask the kernel to notify
            // satellite, whose normal SIGTERM path tears Xwayland down too.
            _ = c.prctl(c.PR_SET_PDEATHSIG, @as(c_ulong, @intCast(c.SIGTERM)), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0));
            if (c.getppid() != owner_pid) c._exit(125);
            clearCloexec(self.unix_fd);
            clearCloexec(self.abstract_fd);
            // A durable display must not keep the creating CLI's pipes open
            // or inject satellite diagnostics into its JSON/stdout stream.
            const null_fd = c.open("/dev/null", c.O_RDWR | c.O_CLOEXEC);
            if (null_fd >= 0) {
                _ = c.dup2(null_fd, 0);
                _ = c.dup2(null_fd, 1);
                _ = c.dup2(null_fd, 2);
                if (null_fd > 2) _ = c.close(null_fd);
            }
            _ = c.setenv("WAYLAND_DISPLAY", wl.ptr, 1);
            _ = c.setenv("XDG_RUNTIME_DIR", rt.ptr, 1);
            _ = c.unsetenv("DISPLAY");
            _ = c.unsetenv("WAYLAND_SOCKET");
            if (!self.gpu)
                _ = c.setenv("LIBGL_ALWAYS_SOFTWARE", "1", 1)
            else
                _ = c.unsetenv("LIBGL_ALWAYS_SOFTWARE");
            var argv: [14:null]?[*:0]const u8 = .{
                "xwayland-satellite",
                display.ptr,
                "-listenfd",
                unix_fd.ptr,
                "-listenfd",
                abstract_fd.ptr,
                "-auth",
                auth.ptr,
                "-nolisten",
                "tcp",
                null,
                null,
                null,
                null,
            };
            if (!self.gpu) {
                argv[10] = "-glamor";
                argv[11] = "none";
            }
            _ = c.execvp("xwayland-satellite", @ptrCast(@constCast(&argv)));
            c._exit(127);
        }
        _ = c.setpgid(pid, pid);
        self.pid = pid;
        self.pgid = pid;
        log.info("rootless Xwayland starting pid={d} display={s} gpu={}", .{ pid, self.display_name, self.gpu });
        return true;
    }

    pub fn reap(self: *Instance) void {
        if (self.pid <= 0) return;
        var status: c_int = 0;
        const pid = self.pid;
        const result = c.waitpid(pid, &status, c.WNOHANG);
        if (result != pid) return;
        self.pid = -1;
        if (self.pgid > 0) _ = c.kill(-self.pgid, c.SIGKILL);
        self.pgid = -1;
        self.retry_after_ms = nowMs() + 500;
        log.warn("rootless Xwayland exited display={s} status={d}", .{ self.display_name, status });
    }

    pub fn maybeStart(self: *Instance) void {
        self.reap();
        if (self.pid <= 0) _ = self.start();
    }

    pub fn ownsPeer(self: *const Instance, fd: c_int) bool {
        if (comptime builtin.os.tag != .linux) return false;
        if (self.pid <= 0) return false;
        const Cred = extern struct { pid: c.pid_t, uid: c.uid_t, gid: c.gid_t };
        var cred: Cred = undefined;
        var len: c.socklen_t = @sizeOf(Cred);
        if (c.getsockopt(fd, c.SOL_SOCKET, c.SO_PEERCRED, &cred, &len) != 0) return false;
        return cred.pid == self.pid;
    }

    fn stop(self: *Instance) void {
        const pid = self.pid;
        const pgid = self.pgid;
        self.pid = -1;
        self.pgid = -1;
        if (pgid <= 0) return;
        if (c.kill(-pgid, c.SIGTERM) < 0 and pid > 0) _ = c.kill(pid, c.SIGTERM);
        var status: c_int = 0;
        var tries: u32 = 0;
        var reaped = false;
        while (tries < 50) : (tries += 1) {
            if (pid > 0 and c.waitpid(pid, &status, c.WNOHANG) == pid) {
                reaped = true;
                break;
            }
            _ = c.usleep(10_000);
        }
        _ = c.kill(-pgid, c.SIGKILL);
        if (pid > 0 and !reaped) {
            while (c.waitpid(pid, &status, 0) < 0 and std.posix.errno(@as(c_int, -1)) == .INTR) {}
        }
    }
};

fn reserve(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    wayland_display: []const u8,
    runtime_dir: []const u8,
    gpu: bool,
    number: u16,
) !?Instance {
    var committed = false;
    const lock_path = try std.fmt.allocPrint(allocator, "/tmp/.X{d}-lock", .{number});
    defer if (!committed) allocator.free(lock_path);
    const socket_path = try std.fmt.allocPrint(allocator, X11_DIR ++ "/X{d}", .{number});
    defer if (!committed) allocator.free(socket_path);
    var lock_buf: [4096:0]u8 = undefined;
    const lock_z = pathZ(&lock_buf, lock_path) catch return error.BadPath;
    const lock_fd = (try acquireDisplayLock(lock_z, socket_path)) orelse return null;
    var keep_lock = false;
    defer {
        _ = c.close(lock_fd);
        if (!keep_lock) _ = c.unlink(lock_z);
    }
    // We own the lock now. A leftover filesystem node is reclaimable only
    // when it is not still backed by an orphaned live listener.
    var socket_zbuf: [4096:0]u8 = undefined;
    const socket_z = pathZ(&socket_zbuf, socket_path) catch return error.BadPath;
    if (c.access(socket_z, c.F_OK) == 0) {
        if (socketAccepts(socket_path)) return null;
        _ = c.unlink(socket_z);
    }
    const unix_fd = bindFilesystem(socket_path) catch return null;
    defer if (!committed) {
        _ = c.close(unix_fd);
        unlinkOwned(socket_path);
    };
    const abstract_fd = bindAbstract(number) catch return null;
    defer if (!committed) {
        _ = c.close(abstract_fd);
    };

    const auth_path = try std.fmt.allocPrint(allocator, "{s}/xauth-{d}-{d}", .{ base_dir, c.getpid(), number });
    defer if (!committed) allocator.free(auth_path);
    try writeAuthority(auth_path, number);
    defer if (!committed) unlinkOwned(auth_path);

    const display_name = try std.fmt.allocPrint(allocator, ":{d}", .{number});
    defer if (!committed) allocator.free(display_name);
    const wl_owned = try allocator.dupe(u8, wayland_display);
    defer if (!committed) allocator.free(wl_owned);
    const rt_owned = try allocator.dupe(u8, runtime_dir);
    defer if (!committed) allocator.free(rt_owned);

    var instance = Instance{
        .allocator = allocator,
        .number = number,
        .display_name = display_name,
        .auth_path = auth_path,
        .socket_path = socket_path,
        .lock_path = lock_path,
        .wayland_display = wl_owned,
        .runtime_dir = rt_owned,
        .unix_fd = unix_fd,
        .abstract_fd = abstract_fd,
        .gpu = gpu,
    };
    if (!instance.start()) {
        return error.SpawnFailed;
    }
    keep_lock = true;
    committed = true;
    return instance;
}

/// Atomically reserves an X lock, reclaiming only a dead lock whose pathname
/// still names the inode we inspected under an advisory lock.
fn acquireDisplayLock(lock_z: [*:0]const u8, socket_path: []const u8) !?c_int {
    if (try createDisplayLock(lock_z)) |fd| return fd;

    const stale_fd = c.open(lock_z, c.O_RDONLY | c.O_CLOEXEC | c.O_NOFOLLOW | c.O_NONBLOCK);
    if (stale_fd < 0) {
        if (std.posix.errno(stale_fd) == .NOENT) {
            return try createDisplayLock(lock_z);
        }
        return null;
    }
    defer _ = c.close(stale_fd);
    if (c.flock(stale_fd, c.LOCK_EX | c.LOCK_NB) != 0) return null;

    var opened: c.struct_stat = undefined;
    var current: c.struct_stat = undefined;
    if (c.fstat(stale_fd, &opened) != 0 or c.lstat(lock_z, &current) != 0 or
        (opened.st_mode & c.S_IFMT) != c.S_IFREG or
        (current.st_mode & c.S_IFMT) != c.S_IFREG or
        opened.st_dev != current.st_dev or opened.st_ino != current.st_ino) return null;

    var pid_buf: [64]u8 = undefined;
    const n = c.read(stale_fd, &pid_buf, pid_buf.len);
    if (n > 0) {
        const text = std.mem.trim(u8, pid_buf[0..@intCast(n)], " \t\r\n\x00");
        if (std.fmt.parseInt(c.pid_t, text, 10)) |pid| {
            if (pid > 0) {
                const alive = c.kill(pid, 0);
                if (alive == 0 or std.posix.errno(alive) == .PERM) return null;
            }
        } else |_| {}
    }
    if (socketAccepts(socket_path)) return null;

    if (c.unlink(lock_z) != 0) return null;
    return try createDisplayLock(lock_z);
}

/// Publishes a complete, flocked lock inode atomically, so a competing
/// allocator can never observe an empty lock and misclassify it as stale.
fn createDisplayLock(lock_z: [*:0]const u8) !?c_int {
    var temp_buf: [4096:0]u8 = undefined;
    const temp = std.fmt.bufPrintZ(&temp_buf, "{s}.sketerm-{d}-{d}", .{ std.mem.span(lock_z), c.getpid(), nowMs() }) catch
        return error.BadPath;
    const fd = c.open(temp.ptr, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC, @as(c_uint, 0o600));
    if (fd < 0) return error.LockFailed;
    var published = false;
    defer {
        _ = c.unlink(temp.ptr);
        if (!published) _ = c.close(fd);
    }
    if (c.flock(fd, c.LOCK_EX | c.LOCK_NB) != 0) return error.LockFailed;
    var pid_text: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&pid_text, "{d: >10}\n", .{c.getpid()}) catch return error.LockFailed;
    if (!writeAll(fd, text) or c.fchmod(fd, 0o444) != 0) return error.LockFailed;
    const linked = c.link(temp.ptr, lock_z);
    if (linked != 0) {
        if (std.posix.errno(linked) == .EXIST) return null;
        return error.LockFailed;
    }
    published = true;
    return fd;
}

fn socketAccepts(path: []const u8) bool {
    const fd = platform.socketCloexec(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (fd < 0) return false;
    defer _ = c.close(fd);
    var addr: c.struct_sockaddr_un = undefined;
    fillSockaddrUn(&addr, path) catch return false;
    const flags = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
    _ = c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK);
    const result = c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un));
    if (result == 0) return true;
    const errno = std.posix.errno(result);
    if (errno == .CONNREFUSED or errno == .NOENT) return false;
    if (errno != .INPROGRESS and errno != .AGAIN) return false;
    var pfd = c.struct_pollfd{ .fd = fd, .events = c.POLLOUT, .revents = 0 };
    const polled = c.poll(&pfd, 1, 100);
    if (polled <= 0) return true; // Uncertain means occupied, never reclaim.
    var so_error: c_int = 0;
    var len: c.socklen_t = @sizeOf(c_int);
    if (c.getsockopt(fd, c.SOL_SOCKET, c.SO_ERROR, &so_error, &len) != 0) return true;
    return so_error == 0;
}

fn ensureX11Dir() !void {
    const made = c.mkdir(X11_DIR, 0o1777);
    if (made == 0) {
        if (c.chmod(X11_DIR, 0o1777) != 0) return error.X11DirectoryFailed;
    } else if (std.posix.errno(made) != .EXIST) return error.X11DirectoryFailed;
    var st: c.struct_stat = undefined;
    if (c.lstat(X11_DIR, &st) != 0) return error.X11DirectoryFailed;
    if ((st.st_mode & c.S_IFMT) != c.S_IFDIR or
        (st.st_mode & 0o022) != 0o022 or (st.st_mode & 0o1000) == 0 or
        (st.st_uid != 0 and st.st_uid != c.geteuid()))
        return error.UnsafeX11Directory;
}

fn bindFilesystem(path: []const u8) !c_int {
    const fd = platform.socketCloexec(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = c.close(fd);
    var addr: c.struct_sockaddr_un = undefined;
    fillSockaddrUn(&addr, path) catch return error.BadPath;
    var zbuf: [4096:0]u8 = undefined;
    const z = pathZ(&zbuf, path) catch return error.BadPath;
    if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0) return error.BindFailed;
    errdefer _ = c.unlink(z);
    if (c.listen(fd, 32) != 0) return error.ListenFailed;
    _ = c.chmod(z, 0o777);
    return fd;
}

fn fillSockaddrUn(addr: *c.struct_sockaddr_un, path: []const u8) !void {
    addr.* = std.mem.zeroes(c.struct_sockaddr_un);
    addr.sun_family = c.AF_UNIX;
    if (path.len >= addr.sun_path.len) return error.BadPath;
    @memcpy(addr.sun_path[0..path.len], path);
    addr.sun_path[path.len] = 0;
}

fn bindAbstract(number: u16) !c_int {
    if (comptime builtin.os.tag != .linux) return error.Unsupported;
    const fd = platform.socketCloexec(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = c.close(fd);
    var addr = std.mem.zeroes(c.struct_sockaddr_un);
    addr.sun_family = c.AF_UNIX;
    var name_buf: [96]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "/tmp/.X11-unix/X{d}", .{number}) catch return error.BadPath;
    if (name.len + 1 > addr.sun_path.len) return error.BadPath;
    addr.sun_path[0] = 0;
    @memcpy(addr.sun_path[1 .. 1 + name.len], name);
    const addr_len: c.socklen_t = @intCast(@offsetOf(c.struct_sockaddr_un, "sun_path") + 1 + name.len);
    if (c.bind(fd, @ptrCast(&addr), addr_len) != 0) return error.BindFailed;
    if (c.listen(fd, 32) != 0) return error.ListenFailed;
    return fd;
}

/// Proves the X listener accepted the private cookie; a socket existing is
/// not readiness because the daemon owns it before satellite starts.
pub fn waitReady(display: []const u8, authority: []const u8, timeout_ms: i32) bool {
    if (comptime builtin.os.tag != .linux) return false;
    if (display.len < 2 or display[0] != ':') return false;
    const end = std.mem.indexOfScalar(u8, display[1..], '.') orelse display.len - 1;
    const number = display[1 .. 1 + end];
    _ = std.fmt.parseInt(u16, number, 10) catch return false;

    var cookie: [16]u8 = undefined;
    if (!parseAuthority(authority, number, &cookie)) return false;
    var path_buf: [108]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, X11_DIR ++ "/X{s}", .{number}) catch return false;
    const fd = platform.socketCloexec(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (fd < 0) return false;
    defer _ = c.close(fd);
    const flags = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
    _ = c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK);
    var addr: c.struct_sockaddr_un = undefined;
    fillSockaddrUn(&addr, path) catch return false;
    const deadline = nowMs() + timeout_ms;
    while (true) {
        const connected = c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un));
        if (connected == 0 or std.posix.errno(connected) == .INPROGRESS) break;
        if (std.posix.errno(connected) == .INTR) continue;
        if (std.posix.errno(connected) != .AGAIN or nowMs() >= deadline) return false;
        _ = c.usleep(10_000);
    }
    if (!pollFd(fd, c.POLLOUT, deadline)) return false;
    var so_error: c_int = 0;
    var so_len: c.socklen_t = @sizeOf(c_int);
    if (c.getsockopt(fd, c.SOL_SOCKET, c.SO_ERROR, &so_error, &so_len) != 0 or so_error != 0) return false;

    const auth_name = "MIT-MAGIC-COOKIE-1";
    var setup = [_]u8{0} ** 48;
    setup[0] = 'l';
    std.mem.writeInt(u16, setup[2..4], 11, .little);
    std.mem.writeInt(u16, setup[6..8], auth_name.len, .little);
    std.mem.writeInt(u16, setup[8..10], cookie.len, .little);
    @memcpy(setup[12 .. 12 + auth_name.len], auth_name);
    @memcpy(setup[32..48], &cookie);
    if (!writeDeadline(fd, &setup, deadline)) return false;

    var reply: [8]u8 = undefined;
    var off: usize = 0;
    while (off < reply.len) {
        if (!pollFd(fd, c.POLLIN, deadline)) return false;
        const n = c.read(fd, reply[off..].ptr, reply.len - off);
        if (n < 0 and (std.posix.errno(n) == .INTR or std.posix.errno(n) == .AGAIN)) continue;
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return reply[0] == 1;
}

fn parseAuthority(path: []const u8, number: []const u8, cookie: *[16]u8) bool {
    var zbuf: [4096:0]u8 = undefined;
    const z = pathZ(&zbuf, path) catch return false;
    const fd = c.open(z, c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return false;
    defer _ = c.close(fd);
    var buf: [512]u8 = undefined;
    var used: usize = 0;
    while (used < buf.len) {
        const n = c.read(fd, buf[used..].ptr, buf.len - used);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n < 0) return false;
        if (n == 0) break;
        used += @intCast(n);
    }
    if (used == 0) return false;
    const bytes = buf[0..used];
    var pos: usize = 0;
    _ = takeBe16(bytes, &pos) orelse return false;
    _ = takeField(bytes, &pos) orelse return false;
    const record_number = takeField(bytes, &pos) orelse return false;
    const name = takeField(bytes, &pos) orelse return false;
    const data = takeField(bytes, &pos) orelse return false;
    if (!std.mem.eql(u8, record_number, number) or
        !std.mem.eql(u8, name, "MIT-MAGIC-COOKIE-1") or data.len != cookie.len) return false;
    @memcpy(cookie, data);
    return true;
}

fn takeBe16(bytes: []const u8, pos: *usize) ?u16 {
    if (pos.* + 2 > bytes.len) return null;
    const value = std.mem.readInt(u16, bytes[pos.*..][0..2], .big);
    pos.* += 2;
    return value;
}

fn takeField(bytes: []const u8, pos: *usize) ?[]const u8 {
    const len = takeBe16(bytes, pos) orelse return null;
    if (pos.* + len > bytes.len) return null;
    const value = bytes[pos.* .. pos.* + len];
    pos.* += len;
    return value;
}

fn writeDeadline(fd: c_int, bytes: []const u8, deadline: i64) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(fd, bytes[off..].ptr, bytes.len - off);
        if (n > 0) {
            off += @intCast(n);
            continue;
        }
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n < 0 and std.posix.errno(n) == .AGAIN and pollFd(fd, c.POLLOUT, deadline)) continue;
        return false;
    }
    return true;
}

fn pollFd(fd: c_int, events: c_short, deadline: i64) bool {
    while (true) {
        const remaining = deadline - nowMs();
        if (remaining <= 0) return false;
        var pfd = c.struct_pollfd{ .fd = fd, .events = events, .revents = 0 };
        const result = c.poll(&pfd, 1, @intCast(@min(remaining, 1000)));
        if (result < 0 and std.posix.errno(result) == .INTR) continue;
        if (result <= 0) continue;
        if (pfd.revents & events != 0) return true;
        if (pfd.revents & (c.POLLERR | c.POLLHUP | c.POLLNVAL) != 0) return false;
    }
}

fn writeAuthority(path: []const u8, number: u16) !void {
    var cookie: [16]u8 = undefined;
    if (c.getentropy(&cookie, cookie.len) != 0) return error.RandomFailed;
    var number_buf: [8]u8 = undefined;
    const number_text = std.fmt.bufPrint(&number_buf, "{d}", .{number}) catch return error.BadPath;
    const auth_name = "MIT-MAGIC-COOKIE-1";
    var bytes: [128]u8 = undefined;
    var pos: usize = 0;
    putBe16(&bytes, &pos, 0xffff); // FamilyWild
    putBe16(&bytes, &pos, 0); // address
    putField(&bytes, &pos, number_text);
    putField(&bytes, &pos, auth_name);
    putField(&bytes, &pos, &cookie);
    var zbuf: [4096:0]u8 = undefined;
    const z = pathZ(&zbuf, path) catch return error.BadPath;
    const fd = c.open(z, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC, @as(c_uint, 0o600));
    if (fd < 0) return error.AuthFileFailed;
    var committed = false;
    defer if (!committed) {
        _ = c.unlink(z);
    };
    defer _ = c.close(fd);
    if (c.fchmod(fd, 0o600) != 0) return error.AuthFileFailed;
    if (!writeAll(fd, bytes[0..pos])) return error.AuthFileFailed;
    committed = true;
}

fn putField(buf: []u8, pos: *usize, value: []const u8) void {
    putBe16(buf, pos, @intCast(value.len));
    @memcpy(buf[pos.* .. pos.* + value.len], value);
    pos.* += value.len;
}

fn putBe16(buf: []u8, pos: *usize, value: u16) void {
    std.mem.writeInt(u16, buf[pos.*..][0..2], value, .big);
    pos.* += 2;
}

fn writeAll(fd: c_int, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(fd, bytes.ptr + off, bytes.len - off);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

fn clearCloexec(fd: c_int) void {
    const flags = c.fcntl(fd, c.F_GETFD);
    if (flags >= 0) _ = c.fcntl(fd, c.F_SETFD, flags & ~c.FD_CLOEXEC);
}

fn unlinkOwned(path: []const u8) void {
    var zbuf: [4096:0]u8 = undefined;
    if (pathZ(&zbuf, path)) |z| _ = c.unlink(z) else |_| {}
}

fn executableOnPath(name: []const u8) bool {
    const path_ptr = c.getenv("PATH") orelse return false;
    var it = std.mem.splitScalar(u8, std.mem.span(path_ptr), ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        var buf: [4096:0]u8 = undefined;
        const path = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ dir, name }) catch continue;
        if (c.access(path.ptr, c.X_OK) == 0) return true;
    }
    return false;
}

const nowMs = @import("../util/clock.zig").nowMs;

test "xwayland authority record is accepted by xauth layout parser" {
    var bytes: [64]u8 = undefined;
    var pos: usize = 0;
    putBe16(&bytes, &pos, 0xffff);
    putBe16(&bytes, &pos, 0);
    putField(&bytes, &pos, "100");
    putField(&bytes, &pos, "MIT-MAGIC-COOKIE-1");
    putField(&bytes, &pos, &([_]u8{0xaa} ** 16));
    try std.testing.expectEqual(@as(u16, 0xffff), std.mem.readInt(u16, bytes[0..2], .big));
    try std.testing.expect(std.mem.indexOf(u8, bytes[0..pos], "MIT-MAGIC-COOKIE-1") != null);
    try std.testing.expectEqual(@as(usize, 2 + 2 + 2 + 3 + 2 + 18 + 2 + 16), pos);
}

test "xwayland display locks reclaim dead owners but not live ones" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    var lock_buf: [256:0]u8 = undefined;
    const lock = try std.fmt.bufPrintZ(&lock_buf, "/tmp/sketerm-xlock-test-{d}", .{c.getpid()});
    var socket_buf: [256]u8 = undefined;
    const socket = try std.fmt.bufPrint(&socket_buf, "/tmp/sketerm-xlock-sock-test-{d}", .{c.getpid()});
    _ = c.unlink(lock.ptr);
    defer _ = c.unlink(lock.ptr);

    var fd = c.open(lock.ptr, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC, @as(c_uint, 0o444));
    try std.testing.expect(fd >= 0);
    try std.testing.expect(writeAll(fd, "999999999\n"));
    _ = c.close(fd);
    fd = (try acquireDisplayLock(lock.ptr, socket)).?;
    _ = c.close(fd);

    _ = c.unlink(lock.ptr);
    fd = c.open(lock.ptr, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC, @as(c_uint, 0o444));
    try std.testing.expect(fd >= 0);
    var pid_buf: [32]u8 = undefined;
    const pid = try std.fmt.bufPrint(&pid_buf, "{d}\n", .{c.getpid()});
    try std.testing.expect(writeAll(fd, pid));
    _ = c.close(fd);
    try std.testing.expect((try acquireDisplayLock(lock.ptr, socket)) == null);

    _ = c.unlink(lock.ptr);
    try std.testing.expect(c.mkfifo(lock.ptr, 0o600) == 0);
    const started = nowMs();
    try std.testing.expect((try acquireDisplayLock(lock.ptr, socket)) == null);
    try std.testing.expect(nowMs() - started < 500);
}
