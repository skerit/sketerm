//! PTY spawn / read / write.
//!
//! `spawn` opens a pseudo-tty pair and forks. Child sets up a
//! controlling terminal, dup2's the slave over fds 0/1/2, and
//! execvp's the requested program. Parent keeps the master fd and
//! the child pid.
//!
//! See `docs/lifecycle.md` for the full sequence and invariants.

const std = @import("std");
const c = @import("c.zig").c;

pub const SpawnError = error{
    OpenPty,
    Fork,
    ArgvTooLong,
};

pub const SpawnOpts = struct {
    /// Null-terminated argv. argv[0] is the binary to exec.
    argv: []const [*:0]const u8,
    /// Working directory for the child. null = inherit.
    cwd: ?[]const u8 = null,
    rows: u16 = 24,
    cols: u16 = 80,
    /// Extra env strings (`KEY=VALUE`); appended to inherited env.
    extra_env: []const [*:0]const u8 = &.{},
};

pub const Pty = struct {
    master_fd: c_int,
    child_pid: c.pid_t,

    pub fn spawn(opts: SpawnOpts) SpawnError!Pty {
        var master: c_int = undefined;
        var slave: c_int = undefined;
        var winsz = c.struct_winsize{
            .ws_row = opts.rows,
            .ws_col = opts.cols,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };

        if (c.openpty(&master, &slave, null, null, &winsz) != 0) return error.OpenPty;

        // FD_CLOEXEC on master.
        const flags = c.fcntl(master, c.F_GETFD, @as(c_int, 0));
        if (flags >= 0) _ = c.fcntl(master, c.F_SETFD, flags | c.FD_CLOEXEC);

        if (opts.argv.len == 0 or opts.argv.len + 1 > 64) {
            _ = c.close(master);
            _ = c.close(slave);
            return error.ArgvTooLong;
        }

        const pid = c.fork();
        if (pid < 0) {
            _ = c.close(master);
            _ = c.close(slave);
            return error.Fork;
        }

        if (pid == 0) {
            childExec(slave, master, &opts);
            // childExec doesn't return.
        }

        // Parent.
        _ = c.close(slave);
        return .{
            .master_fd = master,
            .child_pid = pid,
        };
    }

    fn childExec(slave: c_int, master: c_int, opts: *const SpawnOpts) noreturn {
        _ = c.setsid();
        _ = c.ioctl(slave, c.TIOCSCTTY, @as(c_int, 0));
        _ = c.dup2(slave, 0);
        _ = c.dup2(slave, 1);
        _ = c.dup2(slave, 2);
        if (slave > 2) _ = c.close(slave);
        _ = c.close(master);

        // Reset signal mask (parent may have blocked SIGCHLD around fork).
        var empty_mask: c.sigset_t = undefined;
        _ = c.sigemptyset(&empty_mask);
        _ = c.sigprocmask(c.SIG_SETMASK, &empty_mask, null);

        // Set sketerm-specific env vars (overwrites if present).
        _ = c.setenv("TERM", "xterm-256color", 1);
        _ = c.setenv("COLORTERM", "truecolor", 1);
        _ = c.setenv("TERM_PROGRAM", "sketerm", 1);
        _ = c.setenv("TERM_PROGRAM_VERSION", "0.1.0", 1);

        // chdir if requested.
        if (opts.cwd) |cwd| {
            var buf: [4096]u8 = undefined;
            const n = @min(cwd.len, 4095);
            @memcpy(buf[0..n], cwd[0..n]);
            buf[n] = 0;
            _ = c.chdir(@ptrCast(&buf));
        }

        // Build argv on the stack.
        var argv_buf: [64]?[*:0]u8 = undefined;
        for (opts.argv, 0..) |arg, i| argv_buf[i] = @constCast(arg);
        argv_buf[opts.argv.len] = null;

        _ = c.execvp(opts.argv[0], @ptrCast(&argv_buf));
        // execvp returned → failure.
        const msg = "sketerm: execvp failed\n";
        _ = c.write(2, msg.ptr, msg.len);
        c._exit(127);
    }

    pub fn setSize(self: Pty, rows: u16, cols: u16) void {
        var ws = c.struct_winsize{
            .ws_row = rows,
            .ws_col = cols,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };
        _ = c.ioctl(self.master_fd, c.TIOCSWINSZ, &ws);
    }

    /// Close master and reap child synchronously. SIGCHLD path is
    /// preferable in a real loop; this is for explicit shutdown.
    pub fn closeAndReap(self: Pty) void {
        _ = c.close(self.master_fd);
        var status: c_int = 0;
        _ = c.waitpid(self.child_pid, &status, 0);
    }

    pub fn writeAll(self: Pty, bytes: []const u8) usize {
        var written: usize = 0;
        while (written < bytes.len) {
            const n = c.write(self.master_fd, bytes.ptr + written, bytes.len - written);
            if (n <= 0) break;
            written += @intCast(n);
        }
        return written;
    }
};
