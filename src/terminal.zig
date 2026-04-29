//! Composes pty + parser + ring + worker thread for one pane.
//!
//! Lifecycle: `init` spawns the worker thread and starts reading
//! from the PTY master fd. Events flow through the SPSC ring; the
//! main thread drains them via `g_main_context_invoke` (coalesced
//! by `drain_pending`). `deinit` joins the worker and reaps the
//! child.

const std = @import("std");
const c = @import("c.zig").c;
const Parser = @import("parser/vt.zig").Parser;
const Event = @import("parser/event.zig").Event;
const ring_mod = @import("util/ring.zig");
const Pty = @import("pty.zig").Pty;
const Screen = @import("grid/screen.zig").Screen;
const Pool = @import("grid/style_pool.zig").Pool;
const percent = @import("util/percent.zig");

/// SPSC ring capacity — power of 2; one Event per slot. Sized to
/// absorb roughly 100ms of worker throughput at 16384 × 96B = 1.5MB.
/// When the main thread is briefly stalled (input handling, GTK
/// frame work), the worker can keep parsing instead of spin-waiting.
pub const RING_CAP: usize = 16384;

pub const EventRing = ring_mod.Ring(Event, RING_CAP);

/// Stable trampoline target for `g_main_context_invoke` callbacks.
/// Lives independently of Terminal so a callback that fires AFTER
/// Terminal.deinit (queued before, dispatched after) can safely
/// no-op instead of dereferencing a freed Terminal.
///
/// The handle is allocated alongside Terminal in init, but is NOT
/// freed in deinit — it leaks intentionally. Realistic apps create
/// O(panes) terminals over their lifetime; per-handle leak is < 32
/// bytes. Reclaiming would require tracking pending invocations,
/// which glib doesn't expose.
pub const DrainHandle = struct {
    drain_pending: std.atomic.Value(bool) = .{ .raw = false },
    /// Cleared in Terminal.deinit. mainDrain bails when alive=false.
    alive: std.atomic.Value(bool) = .{ .raw = true },
    /// Borrowed; nulled in deinit.
    terminal: ?*Terminal = null,
};

pub const Terminal = struct {
    pty: Pty,
    parser: Parser,
    ring: *EventRing,
    worker_thread: std.Thread,
    shutdown_fd: c_int,
    /// Heap-allocated handle that outlives the Terminal so glib
    /// callbacks queued before deinit can safely run after deinit.
    /// drain_pending lives on the handle.
    drain: *DrainHandle,
    allocator: std.mem.Allocator,

    /// Style pool + Screen — main-thread state, mutated only in drain.
    pool: Pool,
    screen: *Screen,

    /// User-level callbacks (e.g. wired by main.zig to GTK).
    user_ctx: ?*anyopaque = null,
    on_title: ?*const fn (ctx: ?*anyopaque, title: []const u8) void = null,
    /// Fired after OSC 7 updates `self.cwd`. UI uses this to refresh
    /// the AdwTabPage tooltip so hovering shows the live shell cwd.
    on_cwd_changed: ?*const fn (ctx: ?*anyopaque, cwd: []const u8) void = null,
    on_clipboard_set: ?*const fn (ctx: ?*anyopaque, text: []const u8) void = null,
    /// Fires once at the end of `mainDrain` when events left
    /// `screen.dirty = true` (and we're not in DECSET 2026 sync
    /// mode). UI uses it to schedule a GL render directly from the
    /// drain instead of waiting for the next 60 Hz tick to notice
    /// the dirty bit — saves up to one frame of latency on
    /// keystroke echo + heavy output.
    on_render_request: ?*const fn (ctx: ?*anyopaque) void = null,
    on_bell: ?*const fn (ctx: ?*anyopaque) void = null,
    on_image: ?*const fn (ctx: ?*anyopaque, img: Screen.ImageEvent) void = null,
    on_image_delete_full: ?*const fn (ctx: ?*anyopaque, ev: Screen.ImageDeleteEvent) void = null,
    on_notification: ?*const fn (ctx: ?*anyopaque, title: []const u8, body: []const u8) void = null,
    on_pointer_shape: ?*const fn (ctx: ?*anyopaque, name: []const u8) void = null,

    /// Optional broadcast-typing filter. When set, every byte from
    /// USER input (keystrokes, paste, hyperlink launch) goes through
    /// here instead of straight to the local PTY. Parser reply
    /// channel (`sinkWritePty`) is unaffected — DA / DSR / OSC 52 /
    /// kitty kbd reports are per-pane and must NOT broadcast.
    /// Window installs this when groupsend != .off.
    broadcast_sink: ?*const fn (ctx: ?*anyopaque, source: *Terminal, bytes: []const u8) void = null,
    broadcast_ctx: ?*anyopaque = null,

    /// Most recent cwd reported via OSC 7 (file://host/path → /path).
    /// Owned. Used by layout save in preference to /proc lookup.
    cwd: ?[]u8 = null,

    /// If true, drain prints events to stderr. M1 debug aid.
    debug_to_stderr: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        pty: Pty,
        cols: u16,
        rows: u16,
    ) !*Terminal {
        const self = try allocator.create(Terminal);
        errdefer allocator.destroy(self);

        const ring = try allocator.create(EventRing);
        errdefer allocator.destroy(ring);
        ring.* = .{};

        const efd = c.eventfd(0, c.EFD_NONBLOCK | c.EFD_CLOEXEC);
        if (efd < 0) return error.EventFd;
        errdefer _ = c.close(efd);

        var pool = try Pool.init(allocator);
        errdefer pool.deinit();

        const screen = try Screen.init(allocator, undefined, cols, rows);
        // Screen.init takes a *Pool; we'll wire the real pointer below.
        // (the field can be re-assigned safely before any apply runs.)
        errdefer screen.deinit();

        // Heap handle for glib callbacks. Intentionally never freed.
        const drain = try allocator.create(DrainHandle);
        drain.* = .{};
        errdefer allocator.destroy(drain);

        self.* = .{
            .pty = pty,
            .parser = Parser.init(allocator),
            .ring = ring,
            .worker_thread = undefined,
            .shutdown_fd = efd,
            .drain = drain,
            .allocator = allocator,
            .pool = pool,
            .screen = screen,
        };
        // Back-link: handle holds a borrowed pointer, cleared in deinit.
        drain.terminal = self;
        // Now that the Terminal exists, point Screen at our pool +
        // wire the side-effect sink.
        self.screen.pool = &self.pool;
        self.screen.sink = .{
            .ctx = @ptrCast(self),
            .on_title = sinkTitle,
            .on_bell = sinkBell,
            .on_write_pty = sinkWritePty,
            .on_clipboard_set = sinkClipboard,
            .on_cwd = sinkCwd,
            .on_image = sinkImage,
            .on_image_delete_full = sinkImageDeleteFull,
            .on_decanm = sinkDecanm,
            .on_notification = sinkNotification,
            .on_pointer_shape = sinkPointerShape,
        };

        self.worker_thread = try std.Thread.spawn(.{}, workerMain, .{self});
        return self;
    }

    fn sinkTitle(ctx: ?*anyopaque, title: []const u8) void {
        const self: *Terminal = @ptrCast(@alignCast(ctx.?));
        if (self.on_title) |f| f(self.user_ctx, title);
    }

    fn sinkBell(ctx: ?*anyopaque) void {
        const self: *Terminal = @ptrCast(@alignCast(ctx.?));
        if (self.on_bell) |f| f(self.user_ctx);
    }

    fn sinkWritePty(ctx: ?*anyopaque, bytes: []const u8) void {
        const self: *Terminal = @ptrCast(@alignCast(ctx.?));
        _ = self.pty.writeAll(bytes);
    }

    fn sinkClipboard(ctx: ?*anyopaque, text: []const u8) void {
        const self: *Terminal = @ptrCast(@alignCast(ctx.?));
        if (self.on_clipboard_set) |f| f(self.user_ctx, text);
    }

    fn sinkCwd(ctx: ?*anyopaque, cwd_in: []const u8) void {
        const self: *Terminal = @ptrCast(@alignCast(ctx.?));
        // OSC 7 sends `file://hostname/path/to/cwd`.
        const raw: []const u8 = blk: {
            if (std.mem.startsWith(u8, cwd_in, "file://")) {
                const after = cwd_in[7..];
                if (std.mem.indexOfScalar(u8, after, '/')) |slash| break :blk after[slash..];
                break :blk after;
            }
            break :blk cwd_in;
        };
        const decoded = percent.decode(self.allocator, raw) catch return;
        if (self.cwd) |old| self.allocator.free(old);
        self.cwd = decoded;
        if (self.on_cwd_changed) |f| f(self.user_ctx, decoded);
    }

    fn sinkImage(ctx: ?*anyopaque, img: Screen.ImageEvent) void {
        const self: *Terminal = @ptrCast(@alignCast(ctx.?));
        if (self.on_image) |f| f(self.user_ctx, img);
    }

    fn sinkDecanm(ctx: ?*anyopaque, ansi: bool) void {
        const self: *Terminal = @ptrCast(@alignCast(ctx.?));
        // ansi==true → leave VT52, return to ANSI/VT100. ansi==false → VT52.
        self.parser.vt52_mode = !ansi;
        if (ansi) {
            self.parser.vt52_y_state = 0;
        }
    }

    fn sinkImageDeleteFull(ctx: ?*anyopaque, ev: Screen.ImageDeleteEvent) void {
        const self: *Terminal = @ptrCast(@alignCast(ctx.?));
        if (self.on_image_delete_full) |f| f(self.user_ctx, ev);
    }

    fn sinkNotification(ctx: ?*anyopaque, title: []const u8, body: []const u8) void {
        const self: *Terminal = @ptrCast(@alignCast(ctx.?));
        if (self.on_notification) |f| f(self.user_ctx, title, body);
    }

    fn sinkPointerShape(ctx: ?*anyopaque, name: []const u8) void {
        const self: *Terminal = @ptrCast(@alignCast(ctx.?));
        if (self.on_pointer_shape) |f| f(self.user_ctx, name);
    }

    /// Send user input bytes (keystrokes, paste, etc) to the PTY,
    /// optionally fanned out across panes when broadcast typing is on.
    /// Parser reply channel (`sinkWritePty`) deliberately bypasses
    /// this — those bytes are responses TO this PTY (DA, DSR, OSC 52,
    /// kitty kbd reports) and must not be broadcast.
    pub fn writeUserInput(self: *Terminal, bytes: []const u8) void {
        if (self.broadcast_sink) |f| {
            f(self.broadcast_ctx, self, bytes);
            return;
        }
        _ = self.pty.writeAll(bytes);
    }

    pub fn deinit(self: *Terminal) void {
        // Mark the drain handle dead BEFORE freeing anything else, so
        // any g_main_context_invoke(mainDrain) that was queued before
        // this call but hasn't been dispatched yet will safely no-op
        // when it eventually runs. The handle itself is intentionally
        // leaked — glib doesn't expose a way to cancel one-shot
        // invocations. The leak is bounded by terminal-creation count.
        self.drain.terminal = null;
        self.drain.alive.store(false, .release);

        // Signal worker. Loop on EINTR — eventfd write is atomic
        // 8 bytes but a signal arriving mid-call still returns -1.
        const one: u64 = 1;
        while (true) {
            const w = c.write(self.shutdown_fd, &one, 8);
            if (w >= 0) break;
            if (std.posix.errno(w) != .INTR) break;
        }
        self.worker_thread.join();

        _ = c.close(self.shutdown_fd);
        self.pty.closeAndReap();

        // Drain remaining events to free their owned payloads.
        while (self.ring.pop()) |ev| {
            var mut_ev = ev;
            mut_ev.deinit(self.allocator);
        }

        self.screen.deinit();
        self.pool.deinit();
        self.parser.deinit();
        if (self.cwd) |path| self.allocator.free(path);
        self.allocator.destroy(self.ring);
        self.allocator.destroy(self);
    }

    fn workerMain(self: *Terminal) void {
        // Block SIGCHLD; only main thread handles it.
        var set: c.sigset_t = undefined;
        _ = c.sigemptyset(&set);
        _ = c.sigaddset(&set, c.SIGCHLD);
        _ = c.pthread_sigmask(c.SIG_BLOCK, &set, null);

        var pfds = [_]c.struct_pollfd{
            .{ .fd = self.pty.master_fd, .events = c.POLLIN, .revents = 0 },
            .{ .fd = self.shutdown_fd, .events = c.POLLIN, .revents = 0 },
        };

        while (true) {
            const n = c.poll(&pfds, pfds.len, -1);
            if (n < 0) {
                // EINTR — signal arrived during the blocking poll.
                // Resume; SIGTERM/HUP will reach us through the
                // shutdown_fd, not via interrupting the syscall.
                const errn = std.posix.errno(n);
                if (errn == .INTR) continue;
                break;
            }

            // Shutdown event takes priority.
            if (pfds[1].revents & c.POLLIN != 0) break;

            if (pfds[0].revents & c.POLLIN != 0) {
                var buf: [16384]u8 = undefined;
                const r = c.read(self.pty.master_fd, &buf, buf.len);
                if (r < 0) {
                    // EINTR / EAGAIN are transient — resume the poll
                    // loop. Other errors fall through as EOF.
                    const errn = std.posix.errno(r);
                    if (errn == .INTR or errn == .AGAIN) continue;
                    self.pushSpinning(.{ .child_eof = self.reapStatus() });
                    self.scheduleDrain();
                    break;
                }
                if (r == 0) {
                    self.pushSpinning(.{ .child_eof = self.reapStatus() });
                    self.scheduleDrain();
                    break;
                }
                self.parser.advance(buf[0..@intCast(r)], emitFromWorker, @ptrCast(self));
                self.scheduleDrain();
            }

            if (pfds[0].revents & (c.POLLHUP | c.POLLERR) != 0) {
                self.pushSpinning(.{ .child_eof = self.reapStatus() });
                self.scheduleDrain();
                break;
            }
        }
    }

    /// Non-blocking waitpid; returns 0 if child not yet reaped or
    /// the WEXITSTATUS-style code (or -signo for fatal signals).
    fn reapStatus(self: *Terminal) i32 {
        var status: c_int = 0;
        const r = c.waitpid(self.pty.child_pid, &status, c.WNOHANG);
        if (r != self.pty.child_pid) return 0;
        if ((status & 0x7F) == 0) return @intCast((status >> 8) & 0xFF); // WIFEXITED
        return -@as(i32, @intCast(status & 0x7F)); // WIFSIGNALED → -signo
    }

    fn emitFromWorker(ctx: ?*anyopaque, ev: Event) void {
        const self: *Terminal = @ptrCast(@alignCast(ctx.?));
        self.pushSpinning(ev);
    }

    fn pushSpinning(self: *Terminal, ev: Event) void {
        // If ring is full, yield until space appears (back-pressure).
        var attempts: u32 = 0;
        while (!self.ring.push(ev)) {
            attempts +%= 1;
            if (attempts & 0x3FF == 0) {
                std.Thread.yield() catch {};
            } else {
                std.atomic.spinLoopHint();
            }
        }
    }

    fn scheduleDrain(self: *Terminal) void {
        const was_pending = self.drain.drain_pending.swap(true, .acq_rel);
        if (!was_pending) {
            _ = c.g_main_context_invoke(null, mainDrain, @ptrCast(self.drain));
        }
    }

    fn mainDrain(user: ?*anyopaque) callconv(.c) c.gboolean {
        const handle: *DrainHandle = @ptrCast(@alignCast(user.?));
        // First check: was the Terminal torn down between the worker's
        // schedule and this dispatch? If so the handle is still valid
        // (intentionally leaked) but the back-pointer is null. Bail.
        if (!handle.alive.load(.acquire)) return 0; // G_SOURCE_REMOVE
        const self = handle.terminal orelse return 0;
        // Reset BEFORE draining: if worker pushes during drain it
        // will reschedule us on the next batch.
        handle.drain_pending.store(false, .release);

        var stderr_buf: [4096]u8 = undefined;
        var stderr_writer: ?std.fs.File.Writer = if (self.debug_to_stderr)
            std.fs.File.stderr().writer(&stderr_buf)
        else
            null;

        while (self.ring.pop()) |ev| {
            var mut_ev = ev;
            if (stderr_writer) |*w| {
                debugFormatEvent(&w.interface, ev) catch {};
            }
            // Apply to grid.
            self.screen.apply(ev);
            mut_ev.deinit(self.allocator);
        }

        if (stderr_writer) |*w| {
            w.interface.flush() catch {};
        }

        // Direct render dispatch: drain cleared the ring, leaving the
        // screen dirty. Skip in DECSET 2026 sync mode — the running
        // app will tell us when to flush.
        if (self.screen.dirty and !self.screen.sync_output) {
            if (self.on_render_request) |f| f(self.user_ctx);
        }

        return @intFromBool(false); // G_SOURCE_REMOVE
    }
};

fn debugFormatEvent(w: *std.io.Writer, ev: Event) !void {
    switch (ev) {
        .print => |cp| try w.print("U+{X:0>4} ", .{cp}),
        .print_byte => |b| {
            if (b >= 0x20 and b < 0x7F) {
                try w.print("{c}", .{b});
            } else {
                try w.print("\\x{x:0>2}", .{b});
            }
        },
        .print_run => |run| {
            for (run.bytes[0..run.len]) |b| {
                if (b >= 0x20 and b < 0x7F) {
                    try w.print("{c}", .{b});
                } else {
                    try w.print("\\x{x:0>2}", .{b});
                }
            }
        },
        .execute => |b| {
            switch (b) {
                '\r' => try w.print("[CR]", .{}),
                '\n' => try w.print("[LF]\n", .{}),
                '\t' => try w.print("[TAB]", .{}),
                0x08 => try w.print("[BS]", .{}),
                0x07 => try w.print("[BEL]", .{}),
                else => try w.print("[exec 0x{x:0>2}]", .{b}),
            }
        },
        .csi => |csi| {
            try w.print("«CSI", .{});
            if (csi.private != 0) try w.print(" {c}", .{csi.private});
            if (csi.n_params > 0) {
                try w.print(" ", .{});
                for (csi.params[0..csi.n_params], 0..) |p, i| {
                    if (i > 0) try w.print(";", .{});
                    try w.print("{d}", .{p});
                }
            }
            try w.print(" {c}»", .{csi.final});
        },
        .esc_final => |ef| try w.print("«ESC {c}»", .{ef.final}),
        .osc => |o| try w.print("«OSC {s}»", .{o.bytes}),
        .apc => |a| try w.print("«APC {s}»", .{a.bytes}),
        .dcs => |d| try w.print("«DCS {c} body={d}B»", .{ d.proto.final, d.body.len }),
        .dcs_start => |d| try w.print("«DCS-start {c}»", .{d.final}),
        .dcs_data => try w.print("«DCS-data»", .{}),
        .dcs_end => try w.print("«DCS-end»", .{}),
        .child_eof => |s| try w.print("\n«child-eof status={d}»\n", .{s}),
    }
}
