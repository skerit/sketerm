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
const mux_client = @import("mux/client.zig");
const mux_wire = @import("mux/wire.zig");
const mux_snapshot = @import("mux/snapshot.zig");
const predict_mod = @import("mux/predict.zig");
const cell_mod = @import("grid/cell.zig");
const profile_util = @import("util/profile.zig");

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

    /// Non-null = this Terminal renders a sketerm-mux session
    /// instead of owning a PTY. No worker thread, no ring; the
    /// socket is watched on the GLib main loop and decoded events
    /// are applied to the Screen directly.
    remote: ?*Remote = null,

    /// Remote (mux) attachment state.
    pub const Remote = struct {
        conn: mux_client.Conn,
        session: []u8,
        watch_id: c_uint = 0,
        /// Set when the daemon said GONE/EXIT — no more writes.
        closed: bool = false,
        /// Predictive local echo (mosh-style). The expiry timer only
        /// runs while predictions are outstanding, so echo-less input
        /// (password prompts) flushes even when no events arrive.
        predictor: predict_mod.Predictor,
        expire_timer: c_uint = 0,

        pub fn sendInput(self: *Remote, bytes: []const u8) void {
            if (self.closed) return;
            self.conn.sendFrame(.input, bytes) catch {
                self.closed = true;
            };
        }
    };

    /// Attach to an existing sketerm-mux session. `conn` must have
    /// already completed ATTACH and received the first SNAPSHOT
    /// (passed as `snap_payload`, seq header included) — that keeps
    /// all blocking I/O in the caller, before the Terminal exists.
    /// Takes ownership of `conn`.
    pub fn initRemote(
        allocator: std.mem.Allocator,
        conn: mux_client.Conn,
        session_name: []const u8,
        snap_payload: []const u8,
    ) !*Terminal {
        if (snap_payload.len < 8) return error.BadSnapshot;
        const self = try allocator.create(Terminal);
        errdefer allocator.destroy(self);

        var pool = try Pool.init(allocator);
        errdefer pool.deinit();

        const drain = try allocator.create(DrainHandle);
        drain.* = .{};
        errdefer allocator.destroy(drain);

        // On failure the CALLER still owns `conn` (closes it); we
        // only clean up what we allocated here.
        const remote = try allocator.create(Remote);
        errdefer allocator.destroy(remote);
        remote.* = .{
            .conn = conn,
            .session = try allocator.dupe(u8, session_name),
            .predictor = predict_mod.Predictor.init(allocator),
        };
        if (profile_util.getenv("SKETERM_PREDICT")) |v| {
            if (std.mem.eql(u8, v, "always")) remote.predictor.force = .always;
            if (std.mem.eql(u8, v, "never")) remote.predictor.force = .never;
        }
        errdefer allocator.free(remote.session);

        self.* = .{
            .pty = .{ .master_fd = -1, .child_pid = -1 },
            .parser = Parser.init(allocator),
            .ring = undefined,
            .worker_thread = undefined,
            .shutdown_fd = -1,
            .drain = drain,
            .allocator = allocator,
            .pool = pool,
            .screen = undefined,
            .remote = remote,
        };
        drain.terminal = self;

        // Restore the snapshot into our pool; wire sinks like init.
        self.screen = try mux_snapshot.restore(allocator, &self.pool, snap_payload[8..]);
        errdefer self.screen.deinit();
        self.wireScreenSink();

        // Non-blocking + main-loop watch for the live stream.
        const fl = c.fcntl(remote.conn.fd, c.F_GETFL, @as(c_int, 0));
        _ = c.fcntl(remote.conn.fd, c.F_SETFL, fl | c.O_NONBLOCK);
        remote.watch_id = c.g_unix_fd_add(
            remote.conn.fd,
            c.G_IO_IN | c.G_IO_HUP | c.G_IO_ERR,
            @ptrCast(&remoteSocketCb),
            @ptrCast(self),
        );
        return self;
    }

    fn wireScreenSink(self: *Terminal) void {
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
    }

    /// Socket readable: peel frames, apply events / snapshots.
    fn remoteSocketCb(_: c_int, condition: c.GIOCondition, user: ?*anyopaque) callconv(.c) c.gboolean {
        const self: *Terminal = @ptrCast(@alignCast(user.?));
        const remote = self.remote orelse return 0;
        if ((condition & (c.G_IO_HUP | c.G_IO_ERR)) != 0) {
            self.remoteClosed("connection lost");
            return 0;
        }

        var tmp: [32768]u8 = undefined;
        var rounds: u8 = 0;
        while (rounds < 8) : (rounds += 1) {
            const n = c.read(remote.conn.fd, &tmp, tmp.len);
            if (n < 0) {
                if (std.posix.errno(n) == .AGAIN or std.posix.errno(n) == .INTR) break;
                self.remoteClosed("read error");
                return 0;
            }
            if (n == 0) {
                self.remoteClosed("daemon closed");
                return 0;
            }
            remote.conn.rbuf.appendSlice(self.allocator, tmp[0..@intCast(n)]) catch break;
            if (@as(usize, @intCast(n)) < tmp.len) break;
        }

        while (true) {
            const peeled = mux_wire.peelFrame(remote.conn.rbuf.items) catch {
                self.remoteClosed("protocol error");
                return 0;
            } orelse break;
            self.handleRemoteFrame(peeled.frame);
            const remaining = remote.conn.rbuf.items.len - peeled.consumed;
            std.mem.copyForwards(u8, remote.conn.rbuf.items[0..remaining], remote.conn.rbuf.items[peeled.consumed..]);
            remote.conn.rbuf.shrinkRetainingCapacity(remaining);
        }

        if (self.screen.dirty and !self.screen.sync_output) {
            if (self.on_render_request) |f| f(self.user_ctx);
        }
        return 1;
    }

    fn handleRemoteFrame(self: *Terminal, frame: mux_wire.Frame) void {
        switch (frame.ftype) {
            .events => {
                if (frame.payload.len < 12) return;
                var r = mux_wire.Reader.init(frame.payload[12..]);
                while (!r.atEnd()) {
                    var ev = r.getEvent(self.allocator) catch return;
                    self.screen.apply(ev);
                    ev.deinit(self.allocator);
                }
                if (self.remote) |remote| {
                    remote.predictor.reconcile(
                        .{ .ctx = @ptrCast(self), .cpAt = predictCpAt },
                        profile_util.milliTimestamp(),
                    );
                    self.syncPredictions();
                }
            },
            .snapshot => {
                if (frame.payload.len < 8) return;
                const fresh = mux_snapshot.restore(self.allocator, &self.pool, frame.payload[8..]) catch return;
                // Carry over GUI-side fields the snapshot doesn't own.
                fresh.scrollback_capacity = self.screen.scrollback_capacity;
                fresh.word_chars = self.screen.word_chars;
                fresh.cell_pixel_w = self.screen.cell_pixel_w;
                fresh.cell_pixel_h = self.screen.cell_pixel_h;
                const old = self.screen;
                self.screen = fresh;
                self.wireScreenSink();
                old.deinit();
                // Predicted positions are meaningless on a new grid.
                if (self.remote) |remote| {
                    remote.predictor.pending.clearRetainingCapacity();
                    remote.predictor.overlay.clearRetainingCapacity();
                }
                self.replayRetainedImages();
                if (self.on_render_request) |f| f(self.user_ctx);
            },
            .exit, .gone => self.remoteClosed("session ended"),
            else => {},
        }
    }

    fn remoteClosed(self: *Terminal, reason: []const u8) void {
        const remote = self.remote orelse return;
        if (remote.closed) return;
        remote.closed = true;
        remote.watch_id = 0; // we return 0 from the cb; source removed
        self.screen.child_exited = true;
        self.screen.dirty = true;
        std.debug.print("sketerm: mux session '{s}': {s}\n", .{ remote.session, reason });
        if (self.on_render_request) |f| f(self.user_ctx);
    }

    /// PTY-or-socket write for parser replies / mouse / focus
    /// reports. Use this instead of touching `pty` directly.
    pub fn writeRaw(self: *Terminal, bytes: []const u8) void {
        if (self.remote) |r| {
            r.sendInput(bytes);
            return;
        }
        _ = self.pty.writeAll(bytes);
    }

    /// Resize, routed to the PTY or the mux daemon. The daemon
    /// answers with a fresh snapshot, so remote panes skip the local
    /// screen.resize (the snapshot replaces the grid wholesale).
    pub fn requestResize(self: *Terminal, rows: u16, cols: u16) void {
        if (self.remote) |r| {
            if (r.closed) return;
            var payload: [4]u8 = undefined;
            std.mem.writeInt(u16, payload[0..2], rows, .little);
            std.mem.writeInt(u16, payload[2..4], cols, .little);
            r.conn.sendFrame(.resize, &payload) catch {
                r.closed = true;
            };
            return;
        }
        self.pty.setSize(rows, cols);
    }

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
        self.writeRaw(bytes);
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

    /// Replay snapshot-restored image placements into the image sink
    /// and drop them. Must run AFTER the pane wired `on_image` (the
    /// sink chain ends in the pane's ImageStore) — Window calls this
    /// when attaching a mux tab; the snapshot branch of
    /// handleRemoteFrame calls it directly since the pane exists.
    pub fn replayRetainedImages(self: *Terminal) void {
        if (self.screen.retained_images.items.len == 0) return;
        // The snapshot replaced the whole grid; placements from the
        // previous attach are stale. Flush before replaying.
        if (self.screen.sink.on_image_delete_full) |f| {
            f(self.screen.sink.ctx, .{ .what = 'A' });
        }
        for (self.screen.retained_images.items) |ri| {
            if (self.screen.sink.on_image) |f| f(self.screen.sink.ctx, ri.ev);
        }
        self.screen.clearRetainedImages();
        self.screen.dirty = true;
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

    /// Null out every external sink + the user_ctx pointer, so nothing
    /// dispatched after this call can reach into a freed Pane / Window.
    /// Used by Window.deinit to fence the terminals before tearing
    /// down the panes that own the sink targets.
    pub fn clearSinks(self: *Terminal) void {
        self.user_ctx = null;
        self.on_title = null;
        self.on_cwd_changed = null;
        self.on_clipboard_set = null;
        self.on_render_request = null;
        self.on_bell = null;
        self.on_image = null;
        self.on_image_delete_full = null;
        self.on_notification = null;
        self.on_pointer_shape = null;
    }

    /// Send user input bytes (keystrokes, paste, etc) to the PTY,
    /// optionally fanned out across panes when broadcast typing is on.
    /// Parser reply channel (`sinkWritePty`) deliberately bypasses
    /// this — those bytes are responses TO this PTY (DA, DSR, OSC 52,
    /// kitty kbd reports) and must not be broadcast.
    pub fn writeUserInput(self: *Terminal, bytes: []const u8) void {
        // Predictive echo speculates on keystrokes only — parser
        // replies and mouse reports go through writeRaw directly and
        // must not disturb the prediction state.
        if (self.remote) |remote| {
            if (!remote.closed) {
                remote.predictor.onInput(
                    bytes,
                    self.screen.row,
                    self.screen.col,
                    self.screen.cols,
                    self.screen.use_alt,
                    profile_util.milliTimestamp(),
                );
                self.syncPredictions();
                self.ensurePredictTimer();
            }
        }
        if (self.broadcast_sink) |f| {
            f(self.broadcast_ctx, self, bytes);
            return;
        }
        self.writeRaw(bytes);
    }

    /// Active-screen cell reader for prediction reconcile. Returns
    /// U+FFFD for anything a simple prediction can't match (alt
    /// screen, clusters, out of range) so the predictor self-clears.
    fn predictCpAt(ctx: ?*anyopaque, row: u16, col: u16) u21 {
        const self: *Terminal = @ptrCast(@alignCast(ctx.?));
        const s = self.screen;
        if (s.use_alt or row >= s.rows or col >= s.cols) return 0xFFFD;
        const cell = s.cellAt(row, col).*;
        const fl: cell_mod.Flags = @bitCast(cell.flags);
        if (fl.is_cluster or fl.is_wide_left or fl.is_wide_cont) return 0xFFFD;
        return @intCast(cell.rune & 0x1FFFFF);
    }

    /// Mirror the predictor's visible cells into the Screen overlay
    /// and redraw when it changed.
    fn syncPredictions(self: *Terminal) void {
        const remote = self.remote orelse return;
        const cells = remote.predictor.visibleCells();
        const prev = self.screen.predictions_overlay;
        self.screen.predictions_overlay = cells;
        if (prev.len != 0 or cells.len != 0) {
            self.screen.dirty = true;
            if (self.on_render_request) |f| f(self.user_ctx);
        }
    }

    /// Run the expiry sweep while predictions are outstanding, so
    /// echo-less input (password prompts) can't pin stale glyphs.
    fn ensurePredictTimer(self: *Terminal) void {
        const remote = self.remote orelse return;
        if (remote.expire_timer != 0) return;
        if (remote.predictor.pending.items.len == 0) return;
        remote.expire_timer = c.g_timeout_add(250, @ptrCast(&predictTimerCb), @ptrCast(self));
    }

    fn predictTimerCb(user: ?*anyopaque) callconv(.c) c.gboolean {
        const self: *Terminal = @ptrCast(@alignCast(user.?));
        const remote = self.remote orelse return 0;
        if (remote.predictor.expire(profile_util.milliTimestamp())) {
            self.syncPredictions();
        }
        if (remote.predictor.pending.items.len == 0) {
            remote.expire_timer = 0;
            return 0;
        }
        return 1;
    }

    pub fn deinit(self: *Terminal) void {
        if (self.remote) |remote| {
            // Detach, don't kill: the session keeps running in the
            // daemon — that's the entire point.
            self.drain.terminal = null;
            self.drain.alive.store(false, .release);
            if (remote.watch_id != 0) _ = c.g_source_remove(remote.watch_id);
            if (remote.expire_timer != 0) _ = c.g_source_remove(remote.expire_timer);
            remote.predictor.deinit();
            if (!remote.closed) remote.conn.sendFrame(.detach, "") catch {};
            remote.conn.deinit();
            self.allocator.free(remote.session);
            self.allocator.destroy(remote);
            self.screen.deinit();
            self.pool.deinit();
            self.parser.deinit();
            if (self.cwd) |path| self.allocator.free(path);
            self.allocator.destroy(self);
            return;
        }
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
        // Async reap: closes master_fd + sends SIGHUP synchronously,
        // then escalates SIGTERM / SIGKILL on a g_timeout chain so
        // a child that ignores HUP doesn't freeze the GLib main
        // thread for ~500 ms while we close a tab.
        self.pty.closeAndReapAsync();

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
        // Remote terminals have child_pid == -1; waitpid(-1) would
        // reap ARBITRARY children of the GUI (the forked mux daemon,
        // file-chooser portals…). Never let that happen.
        if (self.pty.child_pid <= 0) return 0;
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

        // Debug-trace events to stderr. Zig 0.16 removed
        // `std.fs.File.stderr()`; we accumulate into a fixed buffer
        // and flush via libc's stderr.
        var stderr_buf: [4096]u8 = undefined;
        var stderr_writer: ?std.Io.Writer = if (self.debug_to_stderr)
            std.Io.Writer.fixed(&stderr_buf)
        else
            null;

        // Budgeted drain: an output flood (cat largefile, fast TUI)
        // can refill the ring as fast as we pop it. Without a cap
        // this loop owns the main thread for the whole burst and GTK
        // can't paint or process input. Cap by event count, with a
        // coarse time check so heavyweight events (images) can't
        // blow the budget — then re-arm and yield back to the loop.
        const max_events: u32 = 4096;
        const budget_ms: i64 = 3;
        const start_ms = profile_util.milliTimestamp();
        var processed: u32 = 0;
        var over_budget = false;
        while (self.ring.pop()) |ev| {
            var mut_ev = ev;
            if (stderr_writer) |*w| {
                debugFormatEvent(w, ev) catch {};
            }
            // Apply to grid.
            self.screen.apply(ev);
            mut_ev.deinit(self.allocator);
            processed += 1;
            if (processed >= max_events or
                (processed & 0xFF == 0 and profile_util.milliTimestamp() - start_ms >= budget_ms))
            {
                over_budget = true;
                break;
            }
        }

        if (stderr_writer) |*w| {
            const bytes = w.buffered();
            if (bytes.len > 0) _ = c.fwrite(bytes.ptr, 1, bytes.len, c.stderr);
        }

        // Direct render dispatch: drain cleared the ring, leaving the
        // screen dirty. Skip in DECSET 2026 sync mode — the running
        // app will tell us when to flush.
        if (self.screen.dirty and !self.screen.sync_output) {
            if (self.on_render_request) |f| f(self.user_ctx);
        }

        // Ring not empty: re-arm with the same coalescing dance the
        // worker uses, so we never double-queue an invoke.
        if (over_budget) {
            const was_pending = handle.drain_pending.swap(true, .acq_rel);
            if (!was_pending) {
                _ = c.g_main_context_invoke(null, mainDrain, @ptrCast(handle));
            }
        }

        return @intFromBool(false); // G_SOURCE_REMOVE
    }
};

fn debugFormatEvent(w: *std.Io.Writer, ev: Event) !void {
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
