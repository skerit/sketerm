//! PTY spawn / read / write.
//!
//! `spawn` opens a pseudo-tty pair and forks. Child sets up a
//! controlling terminal, dup2's the slave over fds 0/1/2, and
//! execvp's the requested program. Parent keeps the master fd and
//! the child pid.
//!
//! See `docs/lifecycle.md` for the full sequence and invariants.

const std = @import("std");
const build_options = @import("build_options");
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
    /// `TERM` env value the child should see. xterm-256color is the
    /// safe default — it advertises 256 colours but no sixel.
    term: [*:0]const u8 = "xterm-256color",
    /// `COLORTERM` env value. "truecolor" makes apps emit 24-bit SGR.
    color_term: [*:0]const u8 = "truecolor",
    /// Spawn as a login shell — argv[0] in the child gets a leading
    /// `-` per Unix convention so /etc/profile etc. are sourced.
    login_shell: bool = false,
    /// Remote-control identity exported into the child env
    /// (SKETERM_PANE_ID / SKETERM_SOCKET). 0 / null = not exported.
    pane_id: u32 = 0,
    socket_path: ?[*:0]const u8 = null,
};

/// Cap on queued bytes per Pty before we start dropping. Hit only
/// when the child is hung (not draining the slave) and the user
/// keeps typing / pasting / broadcasting. 1 MiB ≈ 30 minutes of
/// typing at 60 wpm; in practice the queue empties within ms.
const WRITE_QUEUE_CAP: usize = 1024 * 1024;

pub const Pty = struct {
    master_fd: c_int,
    child_pid: c.pid_t,
    /// Bytes that wouldn't fit a non-blocking `write` because the
    /// slave's input queue (TIOCINQ, typically 4 KiB) was full. We
    /// hold them in user-space and drain via a `g_unix_fd_add`
    /// G_IO_OUT watch when the kernel signals writability. The
    /// queue uses `std.heap.c_allocator` so its lifetime is
    /// independent of any caller's allocator (the GLib watch can
    /// outlive a tab tear-down by exactly one event-loop iteration).
    write_queue: std.ArrayList(u8) = .empty,
    /// GLib source id for the POLLOUT watch, or 0 when no watch is
    /// active. `g_source_remove` ignores 0, so we don't gate the
    /// removal on this — but the field is the canonical "is the
    /// watch live" signal for adders.
    write_watch_id: c_uint = 0,

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

        // O_NONBLOCK on master so `writeAll` never parks the GLib
        // main thread. A hung child (one that has stopped reading
        // its slave) used to block the whole UI for the duration of
        // every keystroke broadcast / motion-mode mouse event. Now
        // EAGAIN bounces back into our user-space queue and a GLib
        // POLLOUT watch drains it asynchronously.
        const file_flags = c.fcntl(master, c.F_GETFL, @as(c_int, 0));
        if (file_flags >= 0) _ = c.fcntl(master, c.F_SETFL, file_flags | c.O_NONBLOCK);

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
        _ = c.setenv("TERM", opts.term, 1);
        _ = c.setenv("COLORTERM", opts.color_term, 1);
        _ = c.setenv("TERM_PROGRAM", "sketerm", 1);
        _ = c.setenv("TERM_PROGRAM_VERSION", "0.1.0", 1);
        // Image-protocol detection hints. Most tools (yazi, lf, btop,
        // chafa, viu) look at $KITTY_WINDOW_ID for kitty graphics
        // capability and trust it without further interrogation. We
        // *do* support kitty graphics, so it's accurate. Sixel users
        // get DA1's `;4;` advertisement plus the `xterm-256color`
        // terminfo `Sixel` flag (when set via `term = ` in config).
        _ = c.setenv("KITTY_WINDOW_ID", "1", 1);
        // Remote control: lets `sketerm cli` inside the terminal find
        // the socket and self-address its own pane.
        if (opts.pane_id != 0) {
            var id_buf: [16]u8 = undefined;
            if (std.fmt.bufPrintZ(&id_buf, "{d}", .{opts.pane_id})) |s| {
                _ = c.setenv("SKETERM_PANE_ID", s.ptr, 1);
            } else |_| {}
        }
        if (opts.socket_path) |sp| _ = c.setenv("SKETERM_SOCKET", sp, 1);

        // chdir if requested.
        if (opts.cwd) |cwd| {
            var buf: [4096]u8 = undefined;
            const n = @min(cwd.len, 4095);
            @memcpy(buf[0..n], cwd[0..n]);
            buf[n] = 0;
            _ = c.chdir(@ptrCast(&buf));
        }

        // Build argv on the stack. login_shell mode: replace argv[0]
        // with `-<basename>` so the child sees itself as a login shell
        // and sources /etc/profile + ~/.profile (Unix convention).
        var argv_buf: [64]?[*:0]u8 = undefined;
        var login_buf: [128:0]u8 = undefined;
        for (opts.argv, 0..) |arg, i| argv_buf[i] = @constCast(arg);
        argv_buf[opts.argv.len] = null;
        if (opts.login_shell and opts.argv.len > 0) {
            const argv0_slice = std.mem.span(opts.argv[0]);
            // Find basename of the executable path.
            const slash = std.mem.lastIndexOfScalar(u8, argv0_slice, '/');
            const base = if (slash) |s| argv0_slice[s + 1 ..] else argv0_slice;
            login_buf[0] = '-';
            const n = @min(base.len, login_buf.len - 1);
            @memcpy(login_buf[1 .. 1 + n], base[0..n]);
            login_buf[1 + n] = 0;
            argv_buf[0] = @ptrCast(&login_buf);
        }

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

    /// Close master and reap child. Closing the master delivers SIGHUP
    /// to the child via the kernel; most shells exit immediately. If
    /// the child ignores SIGHUP we escalate to TERM, then KILL.
    pub fn closeAndReap(self: *Pty) void {
        self.releaseWriteResources();
        _ = c.close(self.master_fd);
        var status: c_int = 0;
        // Phase 1: poll for natural exit (~300 ms total).
        var i: u32 = 0;
        while (i < 30) : (i += 1) {
            const r = c.waitpid(self.child_pid, &status, c.WNOHANG);
            if (r == self.child_pid) return;
            if (r < 0) {
                // EINTR — try again. Other errors (ECHILD = no such
                // child, EINVAL etc.) mean we can't reap; bail.
                if (std.posix.errno(r) == .INTR) continue;
                return;
            }
            _ = c.usleep(10 * 1000);
        }
        // Phase 2: SIGTERM, poll briefly.
        _ = c.kill(self.child_pid, c.SIGTERM);
        i = 0;
        while (i < 20) : (i += 1) {
            const r = c.waitpid(self.child_pid, &status, c.WNOHANG);
            if (r == self.child_pid) return;
            if (r < 0) {
                if (std.posix.errno(r) == .INTR) continue;
                return;
            }
            _ = c.usleep(10 * 1000);
        }
        // Phase 3: SIGKILL, blocking wait. Loop on EINTR.
        _ = c.kill(self.child_pid, c.SIGKILL);
        while (true) {
            const r = c.waitpid(self.child_pid, &status, 0);
            if (r == self.child_pid) return;
            if (r < 0 and std.posix.errno(r) == .INTR) continue;
            return;
        }
    }

    /// Same intent as `closeAndReap`, but moves the SIGHUP →
    /// SIGTERM → SIGKILL escalation chain off the main thread via
    /// `g_timeout_add`. The synchronous version blocks the GLib
    /// main loop up to ~500 ms when the child ignores HUP/TERM —
    /// closing a tab freezes the UI for half a second. This variant
    /// closes the master fd and sends SIGHUP synchronously (cheap),
    /// then if the child hasn't exited yet, hands a small Reaper
    /// struct to a g_timeout that polls every 10 ms and escalates
    /// signals over time. Caller returns immediately.
    ///
    /// The Reaper outlives the Pty by design — children that ignore
    /// every signal would keep the Pty pinned in memory if it were
    /// the owner. On app exit, any still-running children become
    /// orphans (reparented to init) which the kernel handles. The
    /// Reaper allocates from `std.heap.c_allocator` so its lifetime
    /// is independent of any Terminal/Window allocator.
    pub fn closeAndReapAsync(self: *Pty) void {
        // Without a GLib main loop (sketerm-mux) there is nothing to
        // schedule the Reaper on — block briefly instead.
        if (comptime !build_options.glib) return self.closeAndReap();
        // Drop the POLLOUT watch + queued bytes BEFORE closing the
        // master fd — once closed, the watch's callback could fire
        // one more time and dereference a freed Pty otherwise. The
        // watch's GDestroyNotify only frees its own ctx, not the
        // queue or the Pty.
        self.releaseWriteResources();
        _ = c.close(self.master_fd);

        // Most shells exit on master close (EIO on slave reads) so a
        // synchronous WNOHANG poll usually catches it without ever
        // scheduling a timeout. Send SIGHUP first to nudge any that
        // don't get the EIO signal naturally (e.g. ssh sessions).
        _ = c.kill(self.child_pid, c.SIGHUP);
        var status: c_int = 0;
        const r = c.waitpid(self.child_pid, &status, c.WNOHANG);
        if (r == self.child_pid) return;

        const reaper = std.heap.c_allocator.create(Reaper) catch {
            // Allocation failure — fall back to the blocking path.
            // Better to freeze the UI briefly than leak a child.
            var sync_pty = Pty{ .master_fd = -1, .child_pid = self.child_pid };
            sync_pty.closeAndReap();
            return;
        };
        reaper.* = .{ .pid = self.child_pid, .attempts = 0 };
        _ = c.g_timeout_add(10, @ptrCast(&reapStep), @ptrCast(reaper));
    }

    /// Free queued bytes + cancel the POLLOUT watch. Idempotent;
    /// called by both close paths so deinit-on-error of fresh spawns
    /// doesn't trip on the queue's hot pointer.
    fn releaseWriteResources(self: *Pty) void {
        if (comptime build_options.glib) {
            if (self.write_watch_id != 0) {
                _ = c.g_source_remove(self.write_watch_id);
                self.write_watch_id = 0;
            }
        }
        self.write_queue.deinit(std.heap.c_allocator);
    }

    /// Try a non-blocking write. Bytes that don't fit (EAGAIN) get
    /// queued and the kernel signals us via POLLOUT when it can take
    /// more. Caller-visible behaviour: writes never block, queue
    /// preserves order across calls. Return value is the number of
    /// bytes that have been *delivered to the kernel* — anything
    /// that ended up queued counts as 0 because it hasn't reached
    /// the slave yet.
    pub fn writeAll(self: *Pty, bytes: []const u8) usize {
        // Preserve ordering: if there's already queued data, append
        // and let the POLLOUT watch flush it. A direct write here
        // would race ahead of the queued bytes.
        if (self.write_queue.items.len > 0) {
            self.queueBytes(bytes);
            return 0;
        }

        var written: usize = 0;
        while (written < bytes.len) {
            const n = c.write(self.master_fd, bytes.ptr + written, bytes.len - written);
            if (n < 0) {
                const errn = std.posix.errno(n);
                if (errn == .INTR) continue; // signal interrupted — retry
                if (errn == .AGAIN) {
                    // Slave's input queue full. Hand the rest to the
                    // POLLOUT watch.
                    self.queueBytes(bytes[written..]);
                    return written;
                }
                // Real error (EBADF, EIO, EPIPE, ...) — return what
                // we managed; caller can't do much about it.
                break;
            }
            if (n == 0) break;
            written += @intCast(n);
        }
        return written;
    }

    /// Append to the user-space queue (capped to `WRITE_QUEUE_CAP` —
    /// further bytes are dropped to bound memory in the hung-child
    /// case) and arm the POLLOUT watch if it isn't already running.
    fn queueBytes(self: *Pty, bytes: []const u8) void {
        // No GLib main loop (sketerm-mux): drain with a bounded
        // blocking poll loop instead of a POLLOUT watch. The daemon
        // writes keystrokes, not bulk data; a full PTY input queue
        // means a wedged child — give up after ~1 s rather than hang.
        if (comptime !build_options.glib) {
            var rest = bytes;
            var spins: u32 = 0;
            while (rest.len > 0 and spins < 100) : (spins += 1) {
                var pfd = [_]c.struct_pollfd{.{ .fd = self.master_fd, .events = c.POLLOUT, .revents = 0 }};
                _ = c.poll(&pfd, 1, 10);
                const n = c.write(self.master_fd, rest.ptr, rest.len);
                if (n > 0) {
                    rest = rest[@intCast(n)..];
                } else if (n < 0 and std.posix.errno(n) != .AGAIN and std.posix.errno(n) != .INTR) {
                    break;
                }
            }
            return;
        }
        const cap_left = WRITE_QUEUE_CAP -| self.write_queue.items.len;
        const take = @min(bytes.len, cap_left);
        if (take > 0) {
            self.write_queue.appendSlice(std.heap.c_allocator, bytes[0..take]) catch {};
        }
        if (self.write_watch_id == 0 and self.write_queue.items.len > 0) {
            self.write_watch_id = c.g_unix_fd_add(
                self.master_fd,
                c.G_IO_OUT | c.G_IO_HUP | c.G_IO_ERR,
                @ptrCast(&drainWatchCb),
                @ptrCast(self),
            );
        }
    }

    /// POLLOUT-handler entry point. GLib calls us with `condition`
    /// containing the events that fired. We drain as much as the
    /// kernel will take; on empty queue or fatal condition we
    /// remove the watch by returning false.
    fn drainWatchCb(_: c_int, condition: c.GIOCondition, user: ?*anyopaque) callconv(.c) c.gboolean {
        const self: *Pty = @ptrCast(@alignCast(user.?));
        // HUP / ERR: child died or pipe broke. Drop everything.
        if ((condition & (c.G_IO_HUP | c.G_IO_ERR)) != 0) {
            self.write_queue.clearRetainingCapacity();
            self.write_watch_id = 0;
            return 0;
        }
        // Drain as much as the kernel will take.
        while (self.write_queue.items.len > 0) {
            const n = c.write(
                self.master_fd,
                self.write_queue.items.ptr,
                self.write_queue.items.len,
            );
            if (n < 0) {
                const errn = std.posix.errno(n);
                if (errn == .INTR) continue;
                if (errn == .AGAIN) break; // wait for next POLLOUT
                // Other errors — abandon the queue.
                self.write_queue.clearRetainingCapacity();
                self.write_watch_id = 0;
                return 0;
            }
            if (n == 0) break;
            const consumed: usize = @intCast(n);
            // Shift remaining bytes down. Cheaper than a ring buffer
            // for the typical "small queue, occasional spike" pattern.
            const remaining = self.write_queue.items.len - consumed;
            std.mem.copyForwards(
                u8,
                self.write_queue.items[0..remaining],
                self.write_queue.items[consumed..],
            );
            self.write_queue.shrinkRetainingCapacity(remaining);
        }
        if (self.write_queue.items.len == 0) {
            self.write_watch_id = 0;
            return 0;
        }
        return 1;
    }
};

/// Outlives the Pty that schedules it. Iterates a g_timeout polling
/// `waitpid(WNOHANG)` and escalating signals at fixed tick counts.
/// Allocated via `std.heap.c_allocator` so its lifetime is decoupled
/// from any Terminal/Window allocator.
const Reaper = struct {
    pid: c.pid_t,
    attempts: u32,
};

const REAP_SIGTERM_TICK: u32 = 30; // 300 ms after SIGHUP
const REAP_SIGKILL_TICK: u32 = 50; // 500 ms after SIGHUP
const REAP_GIVEUP_TICK: u32 = 200; // 2 s — orphan; kernel reaps at app exit

fn reapStep(user: ?*anyopaque) callconv(.c) c.gboolean {
    const r: *Reaper = @ptrCast(@alignCast(user.?));
    var status: c_int = 0;
    const w = c.waitpid(r.pid, &status, c.WNOHANG);
    if (w == r.pid) {
        std.heap.c_allocator.destroy(r);
        return 0; // G_SOURCE_REMOVE
    }
    if (w < 0) {
        const errn = std.posix.errno(w);
        // EINTR — retry on next tick. ECHILD or anything else means
        // the child is unreachable; give up rather than spin forever.
        if (errn != .INTR) {
            std.heap.c_allocator.destroy(r);
            return 0;
        }
    }
    r.attempts += 1;
    switch (r.attempts) {
        REAP_SIGTERM_TICK => _ = c.kill(r.pid, c.SIGTERM),
        REAP_SIGKILL_TICK => _ = c.kill(r.pid, c.SIGKILL),
        REAP_GIVEUP_TICK => {
            // 2 s of failed kills — child is in an unkillable state
            // (uninterruptible sleep, kernel D-state, or PID re-used).
            // Orphan it; init will reap when sketerm exits.
            std.heap.c_allocator.destroy(r);
            return 0;
        },
        else => {},
    }
    return 1; // G_SOURCE_CONTINUE
}
