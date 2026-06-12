//! GUI-side half of Wayland app forwarding (GUI-only; GLib links).
//!
//! Owns ONE `waypipe client` child for the whole process: it talks
//! to the real local compositor and listens on a private Unix
//! socket. Every forwarded app stream (a chan_* byte channel from a
//! mux daemon — see mux/wire.zig) gets its own connection to that
//! socket; terminal.zig pumps the bytes. The child is spawned
//! lazily on the first channel and SIGTERMed at exit.

const std = @import("std");
const c = @import("c.zig").c;

var g_pid: c.pid_t = -1;
var g_failed: bool = false;
var g_sock_buf: [4096:0]u8 = undefined;
var g_sock_len: usize = 0;

/// Connect a fresh nonblocking fd to the local waypipe client,
/// spawning it on first use. Null when there's no local Wayland
/// session or waypipe is missing/unstartable (cached — we don't
/// retry a failed spawn on every app).
pub fn connectApp() ?c_int {
    const sock = ensureClient() orelse return null;
    var tries: u32 = 0;
    while (tries < 40) : (tries += 1) {
        const fd = @import("util/platform.zig").socketCloexec(c.AF_UNIX, c.SOCK_STREAM, 0);
        if (fd < 0) return null;
        var addr: c.struct_sockaddr_un = undefined;
        addr = std.mem.zeroes(c.struct_sockaddr_un);
        addr.sun_family = c.AF_UNIX;
        if (sock.len >= addr.sun_path.len) {
            _ = c.close(fd);
            return null;
        }
        @memcpy(addr.sun_path[0..sock.len], sock);
        if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) == 0) {
            const fl = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
            _ = c.fcntl(fd, c.F_SETFL, fl | c.O_NONBLOCK);
            return fd;
        }
        _ = c.close(fd);
        // waypipe may still be starting up (first launch only).
        _ = c.usleep(25_000);
    }
    return null;
}

fn ensureClient() ?[]const u8 {
    if (g_pid > 0) {
        // Reap-check: a dead client (compositor restart, crash) gets
        // respawned instead of leaving a zombie + dead socket.
        var st: c_int = 0;
        const r = c.waitpid(g_pid, &st, c.WNOHANG);
        if (r == 0) return g_sock_buf[0..g_sock_len];
        g_pid = -1;
    }
    if (g_failed) return null;
    g_failed = true; // cleared on success below

    if (c.getenv("WAYLAND_DISPLAY") == null) {
        std.debug.print("sketerm: remote app needs a local Wayland session\n", .{});
        return null;
    }

    const rt = @import("util/platform.zig").runtimeDir();
    const path = std.fmt.bufPrintZ(&g_sock_buf, "{s}/sketerm/wp-gui-{d}.sock", .{ rt, c.getpid() }) catch return null;
    g_sock_len = path.len;
    // Parent dir exists whenever the IPC server is up; make sure
    // anyway, and clear a stale socket from a recycled pid.
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |sl| {
        var dir_buf: [4096:0]u8 = undefined;
        if (std.fmt.bufPrintZ(&dir_buf, "{s}", .{path[0..sl]})) |dz| {
            _ = c.mkdir(dz.ptr, 0o700);
        } else |_| {}
    }
    _ = c.unlink(path.ptr);

    // Without a Vulkan driver waypipe aborts any connection whose
    // compositor advertises GPU buffers — force shm transfer then.
    const no_gpu = !@import("remoteapp.zig").hasLocalVulkanIcd();

    const pid = c.fork();
    if (pid < 0) return null;
    if (pid == 0) {
        var argv = [_:null]?[*:0]const u8{
            "waypipe", "--socket", path.ptr, "client", null, null,
        };
        if (no_gpu) {
            argv[1] = "--no-gpu";
            argv[2] = "--socket";
            argv[3] = path.ptr;
            argv[4] = "client";
        }
        _ = c.execvp("waypipe", @ptrCast(@constCast(&argv)));
        c._exit(127);
    }
    g_pid = pid;
    g_failed = false;
    _ = c.atexit(killClient);
    return g_sock_buf[0..g_sock_len];
}

fn killClient() callconv(.c) void {
    if (g_pid > 0) {
        _ = c.kill(g_pid, c.SIGTERM);
        g_pid = -1;
    }
    if (g_sock_len > 0) _ = c.unlink(@ptrCast(&g_sock_buf));
}
