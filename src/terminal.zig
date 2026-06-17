//! One pane's terminal: a thin client of the mux daemon, which owns the
//! PTY + parser + authoritative Screen.
//!
//! `initRemote` is the only constructor — it restores the attach snapshot
//! into a local mirror Screen and watches the daemon socket via
//! `g_unix_fd_add`; inbound EVENTS apply directly to the mirror and a
//! SNAPSHOT swaps it wholesale. `writeRaw`/`requestResize` send INPUT/RESIZE
//! frames back. There is NO in-process PTY path anymore (no worker thread,
//! no ring) — local shells are daemon sessions the GUI attaches to.

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
const platform = @import("util/platform.zig");
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
/// Outlives the Terminal so a deferred glib callback (e.g. the async OSC 52
/// clipboard-read reply) can detect a pane/terminal teardown between request
/// and dispatch: it checks `alive` (cleared in deinit) before touching
/// `terminal` (nulled in deinit).
pub const DrainHandle = struct {
    alive: std.atomic.Value(bool) = .{ .raw = true },
    /// Borrowed; nulled in deinit.
    terminal: ?*Terminal = null,
};

pub const Terminal = struct {
    parser: Parser,
    /// Heap-allocated handle that outlives the Terminal so glib
    /// callbacks queued before deinit can safely run after deinit.
    /// (Async sink replies — e.g. OSC 52 clipboard reads — check
    /// `alive` to detect a teardown between request and callback.)
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
    /// OSC 52 read query (only fired when the screen allows reads).
    on_clipboard_get: ?*const fn (ctx: ?*anyopaque, selection: u8) void = null,
    /// Fires once at the end of `mainDrain` when events left
    /// `screen.dirty = true` (and we're not in DECSET 2026 sync
    /// mode). UI uses it to schedule a GL render directly from the
    /// drain instead of waiting for the next 60 Hz tick to notice
    /// the dirty bit — saves up to one frame of latency on
    /// keystroke echo + heavy output.
    on_render_request: ?*const fn (ctx: ?*anyopaque) void = null,
    /// Fired from the drain ONLY when the visible grid actually changed
    /// this batch (content hash differs) — the tab-activity signal.
    /// Distinct from on_render_request, which fires on any dirty.
    on_activity: ?*const fn (ctx: ?*anyopaque) void = null,
    on_bell: ?*const fn (ctx: ?*anyopaque) void = null,
    on_image: ?*const fn (ctx: ?*anyopaque, img: Screen.ImageEvent) void = null,
    on_image_delete_full: ?*const fn (ctx: ?*anyopaque, ev: Screen.ImageDeleteEvent) void = null,
    on_notification: ?*const fn (ctx: ?*anyopaque, ev: Screen.NotificationEvent) void = null,
    on_pointer_shape: ?*const fn (ctx: ?*anyopaque, name: []const u8) void = null,
    /// OSC 1337 ; SetProfile=<name> — app asks the GUI to restyle this
    /// pane with a configured profile.
    on_set_profile: ?*const fn (ctx: ?*anyopaque, name: []const u8) void = null,
    on_progress: ?*const fn (ctx: ?*anyopaque, state: u8, percent: u8) void = null,
    /// Fired when the mux daemon confirmed a session rename. The new
    /// name is already committed to `remote.session`.
    on_session_renamed: ?*const fn (ctx: ?*anyopaque, name: []const u8) void = null,

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
        /// Transport host string ("user@box", "udp:box") or null for
        /// the local daemon. Owned; set by Window right after attach.
        host: ?[]u8 = null,
        /// Rename sent to the daemon, awaiting its OK. Committed to
        /// `session` on .ok, dropped on .err. Owned while non-null.
        pending_rename: ?[]u8 = null,
        watch_id: c_uint = 0,
        /// Set when the daemon said GONE/EXIT — no more writes.
        closed: bool = false,
        /// This session is GUI-owned (a flipped local tab, not an explicit
        /// durable/remote one): tearing the terminal down KILLS the session
        /// rather than detaching, so closing a tab doesn't leak a daemon
        /// session. A GUI crash skips deinit, so the session still survives
        /// for reattach — that is the durability.
        ephemeral: bool = false,
        /// Predictive local echo (mosh-style). The expiry timer only
        /// runs while predictions are outstanding, so echo-less input
        /// (password prompts) flushes even when no events arrive.
        predictor: predict_mod.Predictor,
        expire_timer: c_uint = 0,
        /// Sketerm-native app channels: the wlhost compositor brain
        /// renders these as local windows.
        napps: std.ArrayList(*NApp) = .empty,
        /// Window-stream channels (pixel capture remotes).
        wsapps: std.ArrayList(*WsApp) = .empty,

        pub fn sendInput(self: *Remote, bytes: []const u8) void {
            if (self.closed) return;
            self.conn.sendFrame(.input, bytes) catch {
                self.closed = true;
            };
        }
    };

    /// One sketerm-native app channel (kind wayland_native).
    const NApp = struct {
        terminal: *Terminal,
        id: u32,
        host: *@import("wlapp.zig").AppHost,
    };

    /// One window-stream channel (kind winstream).
    const WsApp = struct {
        terminal: *Terminal,
        id: u32,
        host: *@import("winapp.zig").WsHost,
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
            .parser = Parser.init(allocator),
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
        // Mirror screens never answer protocol queries — the daemon's
        // authoritative Screen already does; replying here would
        // double every DSR/DA/DECRQM response the app sees.
        self.screen.mute_responses = true;
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
            .on_clipboard_get = sinkClipboardGet,
            .on_cwd = sinkCwd,
            .on_image = sinkImage,
            .on_image_delete_full = sinkImageDeleteFull,
            .on_decanm = sinkDecanm,
            .on_notification = sinkNotification,
            .on_progress = sinkProgress,
            .on_pointer_shape = sinkPointerShape,
            .on_set_profile = sinkSetProfile,
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
                fresh.mute_responses = self.screen.mute_responses;
                fresh.allow_clipboard_read = self.screen.allow_clipboard_read;
                fresh.color_scheme_dark = self.screen.color_scheme_dark;
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
            // The only request the GUI sends that's answered with
            // OK/ERR while attached is a rename (resize answers with
            // a SNAPSHOT; detach is sent during teardown). Guarded by
            // pending_rename anyway, so a future frame can't misfire.
            .ok => {
                const remote = self.remote orelse return;
                const pending = remote.pending_rename orelse return;
                remote.pending_rename = null;
                self.allocator.free(remote.session);
                remote.session = pending;
                if (self.on_session_renamed) |f| f(self.user_ctx, pending);
            },
            .err => {
                const remote = self.remote orelse return;
                if (remote.pending_rename) |pending| {
                    std.debug.print("sketerm: mux rename of '{s}' rejected: {s}\n", .{ remote.session, frame.payload });
                    self.allocator.free(pending);
                    remote.pending_rename = null;
                }
            },
            .chan_open => self.chanOpen(frame.payload),
            .chan_data => self.chanData(frame.payload),
            .chan_close => {
                const id = mux_wire.decodeChanId(frame.payload) orelse return;
                if (self.findNApp(id)) |na| self.destroyNApp(na);
                if (self.findWsApp(id)) |wa| self.destroyWsApp(wa);
            },
            else => {},
        }
    }

    /// Ask the daemon to rename this remote session. The new name is
    /// committed (and `on_session_renamed` fired) only when the OK
    /// frame comes back.
    pub fn renameSession(self: *Terminal, new_name: []const u8) void {
        const remote = self.remote orelse return;
        if (remote.closed) return;
        if (new_name.len == 0 or new_name.len > 64) return;
        if (std.mem.eql(u8, new_name, remote.session)) return;
        const pending = self.allocator.dupe(u8, new_name) catch return;
        if (remote.pending_rename) |old| self.allocator.free(old);
        remote.pending_rename = pending;
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        std.json.Stringify.value(.{ .name = remote.session, .new_name = new_name }, .{}, &aw.writer) catch return;
        remote.conn.sendFrame(.rename, aw.written()) catch {
            remote.closed = true;
        };
    }

    fn remoteClosed(self: *Terminal, reason: []const u8) void {
        const remote = self.remote orelse return;
        if (remote.closed) return;
        remote.closed = true;
        remote.watch_id = 0; // we return 0 from the cb; source removed
        self.destroyAllChans();
        self.screen.child_exited = true;
        self.screen.dirty = true;
        std.debug.print("sketerm: mux session '{s}': {s}\n", .{ remote.session, reason });
        if (self.on_render_request) |f| f(self.user_ctx);
    }

    // ── Forwarded app channels ───────────────────────────────────

    fn sendChanClose(self: *Terminal, id: u32) void {
        const remote = self.remote orelse return;
        if (remote.closed) return;
        var hdr: [4]u8 = undefined;
        remote.conn.sendFrame(.chan_close, mux_wire.putChanHeader(&hdr, id)) catch {};
    }

    fn chanOpen(self: *Terminal, payload: []const u8) void {
        const open = mux_wire.decodeChanOpen(payload) orelse return;
        switch (open.kind) {
            .wayland_native => self.nappOpen(open.id),
            .winstream => self.wsappOpen(open.id),
            else => self.sendChanClose(open.id),
        }
    }

    fn chanData(self: *Terminal, payload: []const u8) void {
        const id = mux_wire.decodeChanId(payload) orelse return;
        if (self.findNApp(id)) |na| return self.nappData(na, payload[4..]);
        if (self.findWsApp(id)) |wa| return self.wsappData(wa, payload[4..]);
    }

    fn destroyAllChans(self: *Terminal) void {
        const remote = self.remote orelse return;
        while (remote.napps.items.len > 0) {
            self.destroyNApp(remote.napps.items[remote.napps.items.len - 1]);
        }
        while (remote.wsapps.items.len > 0) {
            self.destroyWsApp(remote.wsapps.items[remote.wsapps.items.len - 1]);
        }
    }

    // ── window-stream channels (pixel capture remotes) ──────────

    fn findWsApp(self: *Terminal, id: u32) ?*WsApp {
        const remote = self.remote orelse return null;
        for (remote.wsapps.items) |wa| {
            if (wa.id == id) return wa;
        }
        return null;
    }

    fn wsappOpen(self: *Terminal, id: u32) void {
        const remote = self.remote orelse return;
        const host = @import("winapp.zig").WsHost.create(self.allocator) catch {
            self.sendChanClose(id);
            return;
        };
        const wa = self.allocator.create(WsApp) catch {
            host.destroy();
            self.sendChanClose(id);
            return;
        };
        wa.* = .{ .terminal = self, .id = id, .host = host };
        host.on_flush = wsappFlushCb;
        host.flush_ctx = wa;
        remote.wsapps.append(self.allocator, wa) catch {
            host.destroy();
            self.allocator.destroy(wa);
            self.sendChanClose(id);
            return;
        };
    }

    fn wsappData(self: *Terminal, wa: *WsApp, bytes: []const u8) void {
        wa.host.feed(bytes) catch {
            self.sendChanClose(wa.id);
            self.destroyWsApp(wa);
            return;
        };
        self.wsappFlush(wa);
    }

    fn wsappFlush(self: *Terminal, wa: *WsApp) void {
        const remote = self.remote orelse return;
        if (remote.closed) return;
        const out = wa.host.takeOut();
        if (out.len == 0) return;
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.allocator);
        var idb: [4]u8 = undefined;
        std.mem.writeInt(u32, &idb, wa.id, .little);
        payload.appendSlice(self.allocator, &idb) catch return;
        payload.appendSlice(self.allocator, out) catch return;
        wa.host.clearOut();
        remote.conn.sendFrame(.chan_data, payload.items) catch {
            remote.closed = true;
        };
    }

    fn wsappFlushCb(ctx: ?*anyopaque) void {
        const wa = @import("util/cast.zig").userData(WsApp, ctx);
        wa.terminal.wsappFlush(wa);
    }

    fn destroyWsApp(self: *Terminal, wa: *WsApp) void {
        wa.host.destroy();
        if (self.remote) |remote| {
            for (remote.wsapps.items, 0..) |it, i| {
                if (it == wa) {
                    _ = remote.wsapps.swapRemove(i);
                    break;
                }
            }
        }
        self.allocator.destroy(wa);
    }

    // ── sketerm-native app channels (wlhost compositor) ──────────

    fn findNApp(self: *Terminal, id: u32) ?*NApp {
        const remote = self.remote orelse return null;
        for (remote.napps.items) |na| {
            if (na.id == id) return na;
        }
        return null;
    }

    fn nappOpen(self: *Terminal, id: u32) void {
        const remote = self.remote orelse return;
        const host = @import("wlapp.zig").AppHost.create(self.allocator) catch {
            self.sendChanClose(id);
            return;
        };
        const na = self.allocator.create(NApp) catch {
            host.destroy();
            self.sendChanClose(id);
            return;
        };
        na.* = .{ .terminal = self, .id = id, .host = host };
        host.on_flush = nappFlushCb;
        host.flush_ctx = na;
        remote.napps.append(self.allocator, na) catch {
            host.destroy();
            self.allocator.destroy(na);
            self.sendChanClose(id);
            return;
        };
    }

    fn nappData(self: *Terminal, na: *NApp, bytes: []const u8) void {
        na.host.feed(bytes) catch {
            self.sendChanClose(na.id);
            self.destroyNApp(na);
            return;
        };
        self.nappFlush(na);
    }

    /// Ship pending compositor events to the daemon.
    fn nappFlush(self: *Terminal, na: *NApp) void {
        const remote = self.remote orelse return;
        if (remote.closed) return;
        const out = na.host.takeOut();
        if (out.len == 0) return;
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.allocator);
        var idb: [4]u8 = undefined;
        std.mem.writeInt(u32, &idb, na.id, .little);
        payload.appendSlice(self.allocator, &idb) catch return;
        payload.appendSlice(self.allocator, out) catch return;
        na.host.clearOut();
        remote.conn.sendFrame(.chan_data, payload.items) catch {
            remote.closed = true;
        };
    }

    fn nappFlushCb(ctx: ?*anyopaque) void {
        const na = @import("util/cast.zig").userData(NApp, ctx);
        na.terminal.nappFlush(na);
    }

    fn destroyNApp(self: *Terminal, na: *NApp) void {
        na.host.destroy();
        if (self.remote) |remote| {
            for (remote.napps.items, 0..) |it, i| {
                if (it == na) {
                    _ = remote.napps.swapRemove(i);
                    break;
                }
            }
        }
        self.allocator.destroy(na);
    }

    /// Socket write for parser replies / mouse / focus reports / user
    /// input. Routed to the mux daemon (every Terminal is daemon-backed).
    pub fn writeRaw(self: *Terminal, bytes: []const u8) void {
        const r = self.remote orelse return;
        r.sendInput(bytes);
    }

    /// Resize, routed to the mux daemon. The daemon answers with a fresh
    /// snapshot, so the pane skips a local screen.resize (the snapshot
    /// replaces the grid wholesale).
    pub fn requestResize(self: *Terminal, rows: u16, cols: u16) void {
        const r = self.remote orelse return;
        if (r.closed) return;
        var payload: [4]u8 = undefined;
        std.mem.writeInt(u16, payload[0..2], rows, .little);
        std.mem.writeInt(u16, payload[2..4], cols, .little);
        r.conn.sendFrame(.resize, &payload) catch {
            r.closed = true;
        };
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

    fn sinkClipboardGet(ctx: ?*anyopaque, selection: u8) void {
        const self: *Terminal = @ptrCast(@alignCast(ctx.?));
        if (self.on_clipboard_get) |f| f(self.user_ctx, selection);
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

    fn sinkNotification(ctx: ?*anyopaque, ev: Screen.NotificationEvent) void {
        const self: *Terminal = @ptrCast(@alignCast(ctx.?));
        if (self.on_notification) |f| f(self.user_ctx, ev);
    }

    fn sinkProgress(ctx: ?*anyopaque, state: u8, pct: u8) void {
        const self: *Terminal = @ptrCast(@alignCast(ctx.?));
        if (self.on_progress) |f| f(self.user_ctx, state, pct);
    }

    fn sinkPointerShape(ctx: ?*anyopaque, name: []const u8) void {
        const self: *Terminal = @ptrCast(@alignCast(ctx.?));
        if (self.on_pointer_shape) |f| f(self.user_ctx, name);
    }

    fn sinkSetProfile(ctx: ?*anyopaque, name: []const u8) void {
        const self: *Terminal = @ptrCast(@alignCast(ctx.?));
        if (self.on_set_profile) |f| f(self.user_ctx, name);
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
        self.on_clipboard_get = null;
        self.on_render_request = null;
        self.on_activity = null;
        self.on_bell = null;
        self.on_image = null;
        self.on_image_delete_full = null;
        self.on_notification = null;
        self.on_progress = null;
        self.on_pointer_shape = null;
        self.on_set_profile = null;
        self.on_session_renamed = null;
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
            self.destroyAllChans();
            remote.napps.deinit(self.allocator);
            remote.wsapps.deinit(self.allocator);
            remote.predictor.deinit();
            if (!remote.closed) {
                if (remote.ephemeral) {
                    // GUI-owned session: kill it so a closed tab doesn't
                    // leak a daemon session. Session names are GUI-minted
                    // (`s<pid>-<n>`), so the inline JSON is safe.
                    var kbuf: [128]u8 = undefined;
                    if (std.fmt.bufPrint(&kbuf, "{{\"name\":\"{s}\"}}", .{remote.session})) |payload| {
                        remote.conn.sendFrame(.kill, payload) catch {};
                    } else |_| {}
                } else {
                    remote.conn.sendFrame(.detach, "") catch {};
                }
            }
            remote.conn.deinit();
            if (remote.host) |h| self.allocator.free(h);
            if (remote.pending_rename) |p| self.allocator.free(p);
            self.allocator.free(remote.session);
            self.allocator.destroy(remote);
            self.screen.deinit();
            self.pool.deinit();
            self.parser.deinit();
            if (self.cwd) |path| self.allocator.free(path);
            self.allocator.destroy(self);
            return;
        }
        // Every Terminal is daemon-backed (initRemote) now — `remote` is
        // always set, so the branch above always returns. This is unreachable.
        unreachable;
    }

};

