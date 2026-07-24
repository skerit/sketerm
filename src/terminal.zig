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
const builtin = @import("builtin");
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
    /// Fired when the session died UNEXPECTEDLY (worker/daemon crash — the
    /// conn dropped without a clean .exit/.gone). The GUI shows a crashed-tab
    /// overlay (sad face + "Start new session"). Distinct from a clean exit,
    /// which goes through the child-exit / exit_action path.
    on_crashed: ?*const fn (ctx: ?*anyopaque) void = null,
    /// Fired from the drain ONLY when the visible grid actually changed
    /// this batch (content hash differs) — the tab-activity signal.
    /// Distinct from on_render_request, which fires on any dirty.
    on_activity: ?*const fn (ctx: ?*anyopaque) void = null,
    /// Tab-activity detection state (drives the aurora glow + inactivity
    /// warning): the last visible-content hash and whether it's valid. The
    /// remote event-apply path compares against these to fire `on_activity`
    /// only on a real visible change — ported from the old in-process drain.
    last_content_hash: u64 = 0,
    hash_valid: bool = false,
    /// Bumped on every applied EVENTS batch and on a SNAPSHOT swap.
    /// IPC `screen-info` exposes it so remote drivers (MCP) can
    /// detect output quiescence by polling.
    activity_seq: u64 = 0,
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
    /// Fired when the daemon acks a recording start/stop (see
    /// `recording`), so the UI can toggle its menu/indicator.
    on_recording_changed: ?*const fn (ctx: ?*anyopaque, recording: bool) void = null,
    /// True while the daemon records this session as an asciicast
    /// (client-side mirror; set on the daemon's rec_start/stop OK).
    recording: bool = false,
    /// Fired as a file transfer (upload OR download) to/from a remote
    /// session progresses. The GUI drives the tab progress ring + a
    /// completion/failure toast.
    on_transfer: ?*const fn (ctx: ?*anyopaque, ev: TransferEvent) void = null,
    /// Fired with a remote directory listing (answer to `requestList`).
    /// The remote-file-picker dialog consumes this. `listing_ctx` is its
    /// own context, independent of `user_ctx`.
    on_listing: ?*const fn (ctx: ?*anyopaque, listing: Listing) void = null,
    listing_ctx: ?*anyopaque = null,
    /// Fired with the remote host's installed-app list (answer to
    /// `requestApps`). The launcher dialog consumes it.
    on_apps: ?*const fn (ctx: ?*anyopaque, apps: []const AppEntry) void = null,
    apps_ctx: ?*anyopaque = null,
    /// Attach roster of this session (peer_info frames). `drivers` =
    /// headless MCP clients: the "assistant is driving" signal.
    peer_total: u32 = 0,
    peer_drivers: u32 = 0,
    /// Fired when the attach roster changes.
    on_peers: ?*const fn (ctx: ?*anyopaque) void = null,
    /// Fired when this session's primary app host changes: non-null
    /// (an `*wlapp.AppHost`, erased to keep this header GTK-light)
    /// when app windows exist, null when the last one closed. The
    /// pane uses it to swap in a live app view.
    on_app_view: ?*const fn (ctx: ?*anyopaque, host: ?*anyopaque) void = null,
    /// Fired once per app channel when its FIRST toplevel window
    /// actually appears (see app_window_opened). The pane shows its
    /// "app window open" banner off this in window view mode.
    on_app_window: ?*const fn (ctx: ?*anyopaque) void = null,

    /// OSC 133/633 shell-integration command lifecycle: running=true
    /// at C (output starts), running=false at D with the exit code.
    /// duration_ms is 0 on the running=true call and when the C was
    /// never seen (attach mid-command).
    on_cmd_status: ?*const fn (ctx: ?*anyopaque, running: bool, exit: i32, duration_ms: i64) void = null,
    /// Monotonic µs of the last OSC 133 C, 0 = no command running.
    cmd_started_us: i64 = 0,

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

    /// One entry of a remote directory listing.
    pub const DirEntry = struct { name: []const u8, is_dir: bool, size: u64 };

    /// One installed app (answer to `requestApps`). Slices valid only
    /// for the `on_apps` callback.
    pub const AppEntry = struct { name: []const u8, exec: []const u8, icon: []const u8 };

    /// A remote directory listing (answer to `requestList`). Slices are
    /// valid only for the duration of the `on_listing` callback — the
    /// consumer must copy anything it keeps.
    pub const Listing = struct {
        /// Resolved (canonical) directory path that was listed.
        path: []const u8,
        entries: []const DirEntry,
        /// Non-empty on failure (e.g. permission denied); entries empty.
        err: []const u8 = "",
        /// Listing was capped (very large directory).
        truncated: bool = false,
    };

    pub const TransferPhase = enum { started, progress, done, failed };
    pub const TransferDir = enum { upload, download };

    /// One step of a file transfer's lifecycle, reported to the GUI.
    pub const TransferEvent = struct {
        dir: TransferDir,
        phase: TransferPhase,
        /// File's display name (basename).
        name: []const u8,
        /// The "other end" path: for an upload, the resolved remote
        /// path; for a download, the local path it saved to. Empty
        /// until known.
        dest: []const u8 = "",
        /// Bytes transferred so far.
        sent: u64 = 0,
        /// Total file size, 0 if unknown.
        total: u64 = 0,
        /// Human-readable reason on `.failed`.
        message: []const u8 = "",
    };

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
        /// rec_start (1) / rec_stop (2) awaiting the daemon's OK.
        /// Interactive actions are one-at-a-time, so a single slot
        /// suffices (like pending_rename).
        pending_record: u8 = 0,
        watch_id: c_uint = 0,
        /// Set when the daemon said GONE/EXIT — no more writes.
        closed: bool = false,
        /// This session is GUI-owned (a flipped local tab, not an explicit
        /// durable/remote one): tearing the terminal down KILLS the session
        /// rather than detaching, so closing a tab doesn't leak a daemon
        /// session. A GUI crash skips deinit, so the session still survives
        /// for reattach — that is the durability.
        ephemeral: bool = false,
        /// This session is a forwarded GUI app (`sketerm app`), per the
        /// daemon's snapshot header. On app exit the pane holds open with
        /// the log visible instead of detaching to a shell.
        is_app: bool = false,
        /// An app channel (Wayland or pixel-stream window) opened at least
        /// once. Distinguishes "app ran and its window closed" (detach as
        /// usual) from "app died before showing anything" (hold the log).
        app_window_opened: bool = false,
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
        /// Remote-audio channels (local playback via audio_sink.zig).
        aapps: std.ArrayList(*AApp) = .empty,
        /// File uploads to this session. One streams at a time (`upload`);
        /// the rest wait in `upload_queue` as owned local-path strings.
        upload: ?*Upload = null,
        upload_queue: std.ArrayList([]u8) = .empty,
        /// Per-connection transfer-id counter (unique on our side, shared
        /// by uploads and downloads so ids never collide).
        upload_next_id: u32 = 1,
        /// Active file download (one at a time), null = none.
        download: ?*Download = null,
        /// xfer id of the most recent directory-list request; a listing
        /// with a different id is stale (we navigated away) and ignored.
        list_xfer: u32 = 0,

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

    /// One remote-audio channel (kind audio; Linux GUIs only —
    /// audio_sink.zig plays through libpulse on the GLib loop).
    const AApp = if (builtin.os.tag == .linux) struct {
        terminal: *Terminal,
        id: u32,
        sink: *@import("audio_sink.zig").AudioSink,
    } else struct {
        terminal: *Terminal,
        id: u32,
    };

    /// Chunk size for a streamed upload. Small enough that one
    /// blocking socket write never stalls the GLib loop noticeably,
    /// big enough to keep the pipe full.
    const upload_chunk = 128 * 1024;

    /// One in-flight file upload: a local file streamed to the daemon
    /// as file_* frames. `buf` holds the 4-byte transfer-id header
    /// followed by the read chunk, so each pump is a single send.
    const Upload = struct {
        terminal: *Terminal,
        xfer: u32,
        /// Local source fd (O_RDONLY), -1 once finished.
        fd: c_int,
        name: []u8, // basename, owned (display)
        dest: ?[]u8 = null, // remote path once known, owned
        size: u64 = 0,
        sent: u64 = 0, // bytes handed to the socket
        acked: u64 = 0, // bytes the daemon confirmed written
        idle_id: c_uint = 0, // GLib idle pump, 0 = not armed
        eof_sent: bool = false,
        /// True while the pump runs on a 20ms timeout source instead of an
        /// idle source: socket backpressure must not busy-spin the loop.
        pump_timer: bool = false,
        /// g_get_monotonic_time() when backpressure was first seen, 0 when
        /// the socket is keeping up. Bounds a wedged link.
        stall_start_us: i64 = 0,
        buf: [4 + upload_chunk]u8 = undefined,
    };

    /// One in-flight file download: the daemon streams a remote file's
    /// bytes (file_data frames) and we write them to a local file.
    const Download = struct {
        terminal: *Terminal,
        xfer: u32,
        /// Local destination fd (O_WRONLY), -1 until "ready" / once done.
        fd: c_int = -1,
        name: []u8, // remote basename, owned (display)
        local_path: ?[]u8 = null, // resolved local path, owned
        size: u64 = 0, // expected total, from "ready"
        recv: u64 = 0, // bytes written locally
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
        const envelope = mux_snapshot.peelEnvelope(snap_payload) catch return error.BadSnapshot;
        const self = try allocator.create(Terminal);
        errdefer allocator.destroy(self);

        var pool = try Pool.init(allocator);
        var pool_is_local = true;
        errdefer if (pool_is_local) pool.deinit();

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
            .is_app = envelope.app,
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
        pool_is_local = false;
        errdefer self.pool.deinit();
        drain.terminal = self;

        // Restore the snapshot into our pool; wire sinks like init.
        self.screen = try mux_snapshot.restore(allocator, &self.pool, envelope.body);
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
        // Attach-time recvExpect may have buffered frames PAST the
        // snapshot into conn.rbuf; the fd watch only fires on NEW
        // socket bytes, so a quiet session would leave them
        // unprocessed. One idle-time poke drains them after the
        // caller finished wiring (routed through the DrainHandle so
        // a teardown-before-idle can't dangle).
        _ = c.g_idle_add(@ptrCast(&remoteIdleKick), @ptrCast(drain));
        return self;
    }

    /// One-shot idle: drain frames recvExpect buffered before the
    /// fd watch existed. G_SOURCE_REMOVE either way.
    fn remoteIdleKick(user: ?*anyopaque) callconv(.c) c.gboolean {
        const drain: *DrainHandle = @ptrCast(@alignCast(user.?));
        if (drain.alive.load(.acquire)) {
            if (drain.terminal) |term| {
                _ = remoteSocketCb(-1, c.G_IO_IN, @ptrCast(term));
            }
        }
        return 0;
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
            .on_cmd_start = sinkCmdStart,
            .on_cmd_end = sinkCmdEnd,
        };
    }

    /// Socket readable: peel frames, apply events / snapshots.
    fn remoteSocketCb(_: c_int, condition: c.GIOCondition, user: ?*anyopaque) callconv(.c) c.gboolean {
        const self: *Terminal = @ptrCast(@alignCast(user.?));
        const remote = self.remote orelse return 0;
        // HUP/ERR arrive TOGETHER with the final readable data when the
        // daemon flushes .exit/.gone and closes right after (an app
        // session's worker exits the moment its session dies). Declaring
        // the crash before draining threw the clean termination frame
        // away and painted a false crash face on every app quit — so
        // drain and peel first, close only after.
        var dead = (condition & (c.G_IO_HUP | c.G_IO_ERR)) != 0;

        var tmp: [32768]u8 = undefined;
        var rounds: u8 = 0;
        while (rounds < 8) : (rounds += 1) {
            const n = c.read(remote.conn.fd, &tmp, tmp.len);
            if (n < 0) {
                if (std.posix.errno(n) == .AGAIN or std.posix.errno(n) == .INTR) break;
                dead = true;
                break;
            }
            if (n == 0) {
                dead = true;
                break;
            }
            remote.conn.rbuf.appendSlice(self.allocator, tmp[0..@intCast(n)]) catch break;
            if (@as(usize, @intCast(n)) < tmp.len) break;
        }

        while (true) {
            const peeled = mux_wire.peelFrame(remote.conn.rbuf.items) catch {
                self.remoteClosed("protocol error", true);
                return 0;
            } orelse break;
            self.handleRemoteFrame(peeled.frame);
            // A frame (e.g. .exit/.gone) may have run remoteClosed, which
            // zeroes watch_id on the assumption this callback returns
            // G_SOURCE_REMOVE. Stop touching `remote` and drop the source
            // NOW — returning G_SOURCE_CONTINUE here would leave a live fd
            // watch on a Terminal that detachPaneToShell is about to free.
            if (remote.closed) return 0;
            const remaining = remote.conn.rbuf.items.len - peeled.consumed;
            std.mem.copyForwards(u8, remote.conn.rbuf.items[0..remaining], remote.conn.rbuf.items[peeled.consumed..]);
            remote.conn.rbuf.shrinkRetainingCapacity(remaining);
        }

        if (dead) {
            self.remoteClosed("connection lost", true);
            return 0;
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
                // Snapshot the line-id counter so we can tell, after applying,
                // whether new lines were born (scroll/append) — a definite
                // visible change — vs. an in-place repaint that needs hashing.
                const line_id_before = self.screen.next_line_id;
                var any = false;
                var r = mux_wire.Reader.init(frame.payload[12..]);
                while (!r.atEnd()) {
                    var ev = r.getEvent(self.allocator) catch return;
                    self.screen.apply(ev);
                    ev.deinit(self.allocator);
                    any = true;
                }
                if (any) self.activity_seq +%= 1;
                // Tab-activity signal (drives the aurora glow + inactivity
                // warning). Ported from the old in-process drain: fire only on
                // a real VISIBLE change, gated by config + DECSET 2026 sync.
                if (any and self.screen.track_activity and !self.screen.sync_output) {
                    if (self.screen.next_line_id != line_id_before) {
                        self.hash_valid = false;
                        if (self.on_activity) |f| f(self.user_ctx);
                    } else {
                        const h = self.screen.contentHash();
                        if (!self.hash_valid) {
                            self.last_content_hash = h;
                            self.hash_valid = true;
                        } else if (h != self.last_content_hash) {
                            self.last_content_hash = h;
                            if (self.on_activity) |f| f(self.user_ctx);
                        }
                    }
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
                const envelope = mux_snapshot.peelEnvelope(frame.payload) catch return;
                const fresh = mux_snapshot.restore(self.allocator, &self.pool, envelope.body) catch return;
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
                // Grid replaced wholesale — the activity hash baseline is now
                // stale; rebaseline on the next events batch (don't glow on a
                // reattach/resize snapshot).
                self.hash_valid = false;
                self.activity_seq +%= 1;
                // Predicted positions are meaningless on a new grid.
                if (self.remote) |remote| {
                    remote.predictor.pending.clearRetainingCapacity();
                    remote.predictor.overlay.clearRetainingCapacity();
                }
                self.replayRetainedImages();
                if (self.on_render_request) |f| f(self.user_ctx);
            },
            // A clean termination frame — shell exited (.exit) or the session
            // was killed / the daemon shut down (.gone). Not a crash. The
            // .exit frame carries the child's i32 WEXITSTATUS; record it so
            // the exit handler can show it (e.g. an app that died nonzero).
            .exit, .gone => {
                if (frame.ftype == .exit and frame.payload.len >= 4) {
                    self.screen.child_exit_status = std.mem.readInt(i32, frame.payload[0..4], .little);
                }
                self.remoteClosed("session ended", false);
            },
            // OK/ERR answer renames and rec_start/rec_stop (resize
            // answers with a SNAPSHOT; detach is sent during
            // teardown). Both are one-at-a-time interactive actions;
            // record is checked first, rename keeps its guard.
            .ok => {
                const remote = self.remote orelse return;
                if (remote.pending_record != 0) {
                    self.recording = remote.pending_record == 1;
                    remote.pending_record = 0;
                    if (self.on_recording_changed) |f| f(self.user_ctx, self.recording);
                    return;
                }
                const pending = remote.pending_rename orelse return;
                remote.pending_rename = null;
                self.allocator.free(remote.session);
                remote.session = pending;
                if (self.on_session_renamed) |f| f(self.user_ctx, pending);
            },
            .err => {
                const remote = self.remote orelse return;
                if (remote.pending_record != 0) {
                    std.debug.print("sketerm: session record request rejected: {s}\n", .{frame.payload});
                    remote.pending_record = 0;
                    self.recording = false;
                    if (self.on_recording_changed) |f| f(self.user_ctx, false);
                    return;
                }
                if (remote.pending_rename) |pending| {
                    std.debug.print("sketerm: mux rename of '{s}' rejected: {s}\n", .{ remote.session, frame.payload });
                    self.allocator.free(pending);
                    remote.pending_rename = null;
                }
            },
            .file_reply => self.handleFileReply(frame.payload),
            .file_listing => self.handleFileListing(frame.payload),
            .app_listing => self.handleAppListing(frame.payload),
            .peer_info => self.handlePeerInfo(frame.payload),
            .file_data => self.downloadData(frame.payload),
            .chan_open => self.chanOpen(frame.payload),
            .chan_data => self.chanData(frame.payload),
            .chan_close => {
                const id = mux_wire.decodeChanId(frame.payload) orelse return;
                if (self.findNApp(id)) |na| self.destroyNApp(na);
                if (self.findWsApp(id)) |wa| self.destroyWsApp(wa);
                if (self.findAApp(id)) |aa| self.destroyAApp(aa);
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

    /// The session ended. `crashed` = the connection dropped WITHOUT a clean
    /// .exit/.gone frame (worker process died — crash/OOM/SIGKILL — or the
    /// daemon vanished). A clean exit runs the normal exit_action; a crash
    /// paints a sad-face over the pane and keeps it open (browser-style), so
    /// the user sees that this one session died — not the others.
    fn remoteClosed(self: *Terminal, reason: []const u8, crashed: bool) void {
        const remote = self.remote orelse return;
        if (remote.closed) return;
        remote.closed = true;
        remote.watch_id = 0; // we return 0 from the cb; source removed
        self.cancelUploads();
        self.cancelDownload();
        self.destroyAllChans();
        if (crashed) {
            // Prefer the GUI's crashed-tab overlay (sad face + recover button);
            // fall back to painting the grid if no GUI is wired.
            if (self.on_crashed) |f| f(self.user_ctx) else self.paintCrashFace();
        } else {
            self.screen.child_exited = true; // → pane fires exit_action
        }
        self.screen.dirty = true;
        std.debug.print("sketerm: mux session '{s}': {s}{s}\n", .{ remote.session, reason, if (crashed) " (crashed)" else "" });
        if (self.on_render_request) |f| f(self.user_ctx);
    }

    /// Replace the visible grid with a centred sad face — the pane's session
    /// died unexpectedly. Reuses the normal cell renderer (no new draw path).
    fn paintCrashFace(self: *Terminal) void {
        const s = self.screen;
        if (s.rows == 0 or s.cols == 0) return;
        const grid = if (s.use_alt) (s.alt orelse s.active) else s.active;
        for (grid) |*ln| {
            for (ln.cells) |*cell| cell.* = .{};
            ln.dirty = true;
        }
        const mid = s.rows / 2;
        writeCentered(grid, s.cols, if (mid >= 1) mid - 1 else 0, ":(");
        writeCentered(grid, s.cols, mid, "session crashed");
        if (mid + 2 < s.rows) writeCentered(grid, s.cols, mid + 2, "this tab can be closed");
    }

    fn writeCentered(grid: []@import("grid/line.zig").Line, cols: u16, row: u16, text: []const u8) void {
        if (row >= grid.len) return;
        const ln = &grid[row];
        const start: usize = if (text.len < cols) (cols - text.len) / 2 else 0;
        var col = start;
        for (text) |ch| {
            if (col >= cols) break;
            ln.cells[col] = .{ .rune = ch };
            col += 1;
        }
        ln.dirty = true;
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
            .audio => self.aappOpen(open.id),
            else => self.sendChanClose(open.id),
        }
    }

    // ── remote-audio channels (local playback) ──────────────────

    fn findAApp(self: *Terminal, id: u32) ?*AApp {
        const remote = self.remote orelse return null;
        for (remote.aapps.items) |aa| {
            if (aa.id == id) return aa;
        }
        return null;
    }

    fn aappOpen(self: *Terminal, id: u32) void {
        if (comptime builtin.os.tag != .linux) return self.sendChanClose(id);
        const remote = self.remote orelse return;
        const sink = @import("audio_sink.zig").AudioSink.create(self.allocator) catch {
            self.sendChanClose(id);
            return;
        };
        const aa = self.allocator.create(AApp) catch {
            sink.destroy();
            self.sendChanClose(id);
            return;
        };
        aa.* = .{ .terminal = self, .id = id, .sink = sink };
        sink.on_flush = aappFlushCb;
        sink.flush_ctx = aa;
        remote.aapps.append(self.allocator, aa) catch {
            sink.destroy();
            self.allocator.destroy(aa);
            self.sendChanClose(id);
            return;
        };
        // Opt into audio: the daemon only ships samples to subscribers.
        // Flags bit0 advertises that libopus is available for decode.
        const pulse = @import("mux/pulse.zig");
        const opuscodec = @import("mux/opuscodec.zig");
        var units: std.ArrayList(u8) = .empty;
        defer units.deinit(self.allocator);
        const flags: []const u8 = if (opuscodec.available()) "\x01" else "";
        pulse.appendUnit(&units, self.allocator, .subscribe, flags) catch return;
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.allocator);
        var idb: [4]u8 = undefined;
        std.mem.writeInt(u32, &idb, id, .little);
        payload.appendSlice(self.allocator, &idb) catch return;
        payload.appendSlice(self.allocator, units.items) catch return;
        remote.conn.sendFrame(.chan_data, payload.items) catch {
            remote.closed = true;
        };
    }

    fn aappData(self: *Terminal, aa: *AApp, bytes: []const u8) void {
        if (comptime builtin.os.tag != .linux) return;
        aa.sink.feed(bytes);
        self.aappFlush(aa);
    }

    fn aappFlush(self: *Terminal, aa: *AApp) void {
        if (comptime builtin.os.tag != .linux) return;
        const remote = self.remote orelse return;
        if (remote.closed) return;
        const out = aa.sink.takeOut();
        if (out.len == 0) return;
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.allocator);
        var idb: [4]u8 = undefined;
        std.mem.writeInt(u32, &idb, aa.id, .little);
        payload.appendSlice(self.allocator, &idb) catch return;
        payload.appendSlice(self.allocator, out) catch return;
        aa.sink.clearOut();
        remote.conn.sendFrame(.chan_data, payload.items) catch {
            remote.closed = true;
        };
    }

    fn aappFlushCb(ctx: ?*anyopaque) void {
        const aa = @import("util/cast.zig").userData(AApp, ctx);
        aa.terminal.aappFlush(aa);
    }

    fn destroyAApp(self: *Terminal, aa: *AApp) void {
        if (comptime builtin.os.tag == .linux) aa.sink.destroy();
        if (self.remote) |remote| {
            for (remote.aapps.items, 0..) |it, i| {
                if (it == aa) {
                    _ = remote.aapps.swapRemove(i);
                    break;
                }
            }
        }
        self.allocator.destroy(aa);
    }

    // ── File upload (file_* frames) ──────────────────────────────
    // Stream local files to the daemon, which writes them into the
    // remote session's working directory. One transfer streams at a
    // time; the rest wait in remote.upload_queue.

    /// Queue local files for upload to this remote session. No-op on a
    /// local (non-remote) or closed terminal. Paths are copied.
    pub fn startUpload(self: *Terminal, paths: []const []const u8) void {
        const remote = self.remote orelse return;
        if (remote.closed) return;
        for (paths) |p| {
            if (p.len == 0) continue;
            const owned = self.allocator.dupe(u8, p) catch continue;
            remote.upload_queue.append(self.allocator, owned) catch {
                self.allocator.free(owned);
            };
        }
        self.kickUploadQueue();
    }

    fn kickUploadQueue(self: *Terminal) void {
        const remote = self.remote orelse return;
        while (remote.upload == null and remote.upload_queue.items.len > 0) {
            const path = remote.upload_queue.orderedRemove(0);
            defer self.allocator.free(path);
            self.beginUpload(path);
        }
    }

    fn beginUpload(self: *Terminal, path: []const u8) void {
        const remote = self.remote orelse return;
        const base = std.fs.path.basename(path);
        var zbuf: [4096]u8 = undefined;
        const zpath = std.fmt.bufPrintZ(&zbuf, "{s}", .{path}) catch {
            self.emitUploadFail(base, "path too long");
            return;
        };
        const fd = c.open(zpath.ptr, c.O_RDONLY, @as(c_uint, 0));
        if (fd < 0) {
            self.emitUploadFail(base, "cannot open file");
            return;
        }
        var st: c.struct_stat = undefined;
        var size: u64 = 0;
        if (c.fstat(fd, &st) == 0) {
            if ((st.st_mode & c.S_IFMT) == c.S_IFDIR) {
                _ = c.close(fd);
                self.emitUploadFail(base, "directories can't be uploaded");
                return;
            }
            if (st.st_size > 0) size = @intCast(st.st_size);
        }
        const name = self.allocator.dupe(u8, base) catch {
            _ = c.close(fd);
            return;
        };
        const up = self.allocator.create(Upload) catch {
            _ = c.close(fd);
            self.allocator.free(name);
            return;
        };
        up.* = .{ .terminal = self, .xfer = remote.upload_next_id, .fd = fd, .name = name, .size = size };
        remote.upload_next_id += 1;
        remote.upload = up;
        // Ask the daemon to create the destination; we stream on "ready".
        remote.conn.sendJson(.file_open, .{ .xfer = up.xfer, .name = base, .size = size }) catch {
            self.finishUpload(.failed, "connection lost");
            return;
        };
        self.emitUpload(.started, up, "");
    }

    /// GLib idle pump: send one chunk (or the closing frame) per tick,
    /// yielding to the loop between chunks. Socket backpressure leaves a
    /// resumable partial frame in Conn.wbuf; no poll blocks the main loop.
    fn uploadPumpCb(user: ?*anyopaque) callconv(.c) c.gboolean {
        const up: *Upload = @ptrCast(@alignCast(user.?));
        const self = up.terminal;
        const remote = self.remote orelse {
            up.idle_id = 0;
            return 0; // G_SOURCE_REMOVE
        };
        if (remote.closed or remote.upload != up) {
            up.idle_id = 0;
            return 0; // G_SOURCE_REMOVE
        }
        remote.conn.flushQueued() catch {
            up.idle_id = 0;
            self.finishUpload(.failed, "connection lost");
            return 0;
        };
        if (remote.conn.wbuf.items.len > 0) {
            // Backpressure: an idle source re-fires immediately and would
            // spin a core. Poll on a 20ms timer instead, bounded by the
            // connection's write timeout so a wedged link fails the upload.
            const now = c.g_get_monotonic_time();
            if (up.stall_start_us == 0) up.stall_start_us = now;
            if (now - up.stall_start_us > @as(i64, remote.conn.write_timeout_ms) * 1000) {
                up.idle_id = 0;
                self.finishUpload(.failed, "connection lost");
                return 0;
            }
            if (up.pump_timer) return 1; // stay on the 20ms timer
            up.pump_timer = true;
            up.idle_id = c.g_timeout_add(20, @ptrCast(&uploadPumpCb), @ptrCast(up));
            return 0; // remove the idle source
        }
        up.stall_start_us = 0;
        if (up.pump_timer) {
            // Drained: move back to an idle source for full throughput.
            up.pump_timer = false;
            up.idle_id = c.g_idle_add(@ptrCast(&uploadPumpCb), @ptrCast(up));
            return 0; // remove the timer source
        }
        if (up.eof_sent) {
            up.idle_id = 0;
            return 0;
        }
        const n = c.read(up.fd, up.buf[4..], upload_chunk);
        if (n < 0) {
            if (std.posix.errno(n) == .INTR) return 1; // G_SOURCE_CONTINUE
            up.idle_id = 0;
            self.finishUpload(.failed, "read error");
            return 0; // G_SOURCE_REMOVE
        }
        if (n == 0) {
            // EOF: send the close frame; the daemon answers "done".
            up.eof_sent = true;
            var hdr: [4]u8 = undefined;
            remote.conn.queueFrame(.file_close, mux_wire.putChanHeader(&hdr, up.xfer)) catch {
                up.idle_id = 0;
                self.finishUpload(.failed, "connection lost");
                return 0;
            };
            if (remote.conn.wbuf.items.len == 0) {
                up.idle_id = 0;
                return 0;
            }
            return 1;
        }
        _ = mux_wire.putChanHeader(up.buf[0..4], up.xfer);
        const len: usize = @intCast(n);
        remote.conn.queueFrame(.file_data, up.buf[0 .. 4 + len]) catch {
            up.idle_id = 0;
            self.finishUpload(.failed, "connection lost");
            return 0; // G_SOURCE_REMOVE
        };
        up.sent += len;
        return 1; // G_SOURCE_CONTINUE
    }

    fn armUploadPump(self: *Terminal, up: *Upload) void {
        _ = self;
        if (up.idle_id != 0 or up.eof_sent) return;
        up.idle_id = c.g_idle_add(@ptrCast(&uploadPumpCb), @ptrCast(up));
    }

    /// JSON shape of a daemon file_reply (upload acks + download status).
    const FileReplyMsg = struct {
        xfer: u32 = 0,
        status: []const u8 = "",
        written: u64 = 0,
        path: []const u8 = "",
        message: []const u8 = "",
        size: u64 = 0,
    };

    /// Route a file_reply to the matching upload or download by xfer.
    fn handleFileReply(self: *Terminal, payload: []const u8) void {
        const remote = self.remote orelse return;
        const parsed = std.json.parseFromSlice(FileReplyMsg, self.allocator, payload, .{ .ignore_unknown_fields = true }) catch return;
        defer parsed.deinit();
        const r = parsed.value;
        if (remote.upload) |up| {
            if (r.xfer == up.xfer) return self.uploadReply(up, r);
        }
        if (remote.download) |dl| {
            if (r.xfer == dl.xfer) return self.downloadReply(dl, r);
        }
    }

    fn uploadReply(self: *Terminal, up: *Upload, r: FileReplyMsg) void {
        if (std.mem.eql(u8, r.status, "ready")) {
            if (up.dest == null and r.path.len > 0) up.dest = self.allocator.dupe(u8, r.path) catch null;
            self.armUploadPump(up);
        } else if (std.mem.eql(u8, r.status, "progress")) {
            up.acked = r.written;
            self.emitUpload(.progress, up, "");
        } else if (std.mem.eql(u8, r.status, "done")) {
            up.acked = r.written;
            if (up.dest == null and r.path.len > 0) up.dest = self.allocator.dupe(u8, r.path) catch null;
            self.finishUpload(.done, "");
        } else if (std.mem.eql(u8, r.status, "error")) {
            self.finishUpload(.failed, if (r.message.len > 0) r.message else "upload failed");
        }
    }

    /// Tear down the active upload, emit its terminal event, and start
    /// the next queued one.
    fn finishUpload(self: *Terminal, phase: TransferPhase, message: []const u8) void {
        const remote = self.remote orelse return;
        const up = remote.upload orelse return;
        self.emitUpload(phase, up, message);
        if (up.idle_id != 0) _ = c.g_source_remove(up.idle_id);
        if (up.fd >= 0) _ = c.close(up.fd);
        self.allocator.free(up.name);
        if (up.dest) |d| self.allocator.free(d);
        self.allocator.destroy(up);
        remote.upload = null;
        self.kickUploadQueue();
    }

    /// Cancel the active upload and drop the queue (terminal teardown /
    /// connection loss). No events emitted — the pane is going away.
    fn cancelUploads(self: *Terminal) void {
        const remote = self.remote orelse return;
        if (remote.upload) |up| {
            if (up.idle_id != 0) _ = c.g_source_remove(up.idle_id);
            if (up.fd >= 0) _ = c.close(up.fd);
            self.allocator.free(up.name);
            if (up.dest) |d| self.allocator.free(d);
            self.allocator.destroy(up);
            remote.upload = null;
        }
        for (remote.upload_queue.items) |p| self.allocator.free(p);
        remote.upload_queue.clearRetainingCapacity();
    }

    fn emitUpload(self: *Terminal, phase: TransferPhase, up: *Upload, message: []const u8) void {
        const f = self.on_transfer orelse return;
        f(self.user_ctx, .{
            .dir = .upload,
            .phase = phase,
            .name = up.name,
            .dest = if (up.dest) |d| d else "",
            .sent = up.acked,
            .total = up.size,
            .message = message,
        });
    }

    fn emitUploadFail(self: *Terminal, name: []const u8, message: []const u8) void {
        const f = self.on_transfer orelse return;
        f(self.user_ctx, .{ .dir = .upload, .phase = .failed, .name = name, .message = message });
    }

    // ── File download (file_get + reverse file_data) ─────────────

    /// Request a remote file and stream it to the local Downloads dir.
    /// `remote_path` may be absolute, relative to the session cwd, or a
    /// file:// URI. One download runs at a time.
    pub fn startDownload(self: *Terminal, remote_path: []const u8) void {
        const remote = self.remote orelse return;
        if (remote.closed) return;
        const path = stripFileUri(remote_path);
        const base = std.fs.path.basename(path);
        if (path.len == 0 or base.len == 0) return;
        if (remote.download != null) {
            self.emitTransferFail(.download, base, "a download is already in progress");
            return;
        }
        const name = self.allocator.dupe(u8, base) catch return;
        const dl = self.allocator.create(Download) catch {
            self.allocator.free(name);
            return;
        };
        dl.* = .{ .terminal = self, .xfer = remote.upload_next_id, .name = name };
        remote.upload_next_id += 1;
        remote.download = dl;
        remote.conn.sendJson(.file_get, .{ .xfer = dl.xfer, .path = path }) catch {
            self.finishDownload(.failed, "connection lost");
            return;
        };
        self.emitDownload(.started, dl, "");
    }

    fn downloadReply(self: *Terminal, dl: *Download, r: FileReplyMsg) void {
        if (std.mem.eql(u8, r.status, "ready")) {
            dl.size = r.size;
            const dest = self.openDownloadDest(dl.name) orelse {
                self.finishDownload(.failed, "cannot create local file");
                return;
            };
            dl.fd = dest.fd;
            dl.local_path = dest.path;
            // bytes now arrive as file_data frames (handled in downloadData)
        } else if (std.mem.eql(u8, r.status, "done")) {
            if (dl.fd >= 0) _ = c.fsync(dl.fd);
            self.finishDownload(.done, "");
        } else if (std.mem.eql(u8, r.status, "error")) {
            self.finishDownload(.failed, if (r.message.len > 0) r.message else "download failed");
        }
    }

    /// Reverse file_data ([u32 xfer | bytes]): write to the local file.
    fn downloadData(self: *Terminal, payload: []const u8) void {
        const remote = self.remote orelse return;
        const xfer = mux_wire.decodeChanId(payload) orelse return;
        const dl = remote.download orelse return;
        if (xfer != dl.xfer or dl.fd < 0) return;
        const bytes = payload[4..];
        var off: usize = 0;
        while (off < bytes.len) {
            const n = c.write(dl.fd, bytes.ptr + off, bytes.len - off);
            if (n > 0) {
                off += @intCast(n);
                continue;
            }
            if (std.posix.errno(n) == .INTR) continue;
            self.finishDownload(.failed, "local write failed");
            return;
        }
        dl.recv += bytes.len;
        self.emitDownload(.progress, dl, "");
    }

    fn finishDownload(self: *Terminal, phase: TransferPhase, message: []const u8) void {
        const remote = self.remote orelse return;
        const dl = remote.download orelse return;
        self.emitDownload(phase, dl, message);
        if (dl.fd >= 0) _ = c.close(dl.fd);
        self.allocator.free(dl.name);
        if (dl.local_path) |p| self.allocator.free(p);
        self.allocator.destroy(dl);
        remote.download = null;
    }

    fn cancelDownload(self: *Terminal) void {
        const remote = self.remote orelse return;
        const dl = remote.download orelse return;
        if (dl.fd >= 0) _ = c.close(dl.fd);
        self.allocator.free(dl.name);
        if (dl.local_path) |p| self.allocator.free(p);
        self.allocator.destroy(dl);
        remote.download = null;
    }

    fn emitDownload(self: *Terminal, phase: TransferPhase, dl: *Download, message: []const u8) void {
        const f = self.on_transfer orelse return;
        f(self.user_ctx, .{
            .dir = .download,
            .phase = phase,
            .name = dl.name,
            .dest = if (dl.local_path) |p| p else "",
            .sent = dl.recv,
            .total = dl.size,
            .message = message,
        });
    }

    fn emitTransferFail(self: *Terminal, dir: TransferDir, name: []const u8, message: []const u8) void {
        const f = self.on_transfer orelse return;
        f(self.user_ctx, .{ .dir = dir, .phase = .failed, .name = name, .message = message });
    }

    // ── Remote directory browse (file_list) ──────────────────────

    /// Request a remote directory listing (empty path = the shell cwd).
    /// The reply arrives via `on_listing`.
    pub fn requestList(self: *Terminal, path: []const u8) void {
        const remote = self.remote orelse return;
        if (remote.closed) return;
        remote.list_xfer = remote.upload_next_id;
        remote.upload_next_id += 1;
        remote.conn.sendJson(.file_list, .{ .xfer = remote.list_xfer, .path = path }) catch {};
    }

    fn handleFileListing(self: *Terminal, payload: []const u8) void {
        const remote = self.remote orelse return;
        const f = self.on_listing orelse return;
        const Msg = struct {
            xfer: u32 = 0,
            path: []const u8 = "",
            entries: []const struct { name: []const u8 = "", dir: bool = false, size: u64 = 0 } = &.{},
            @"error": []const u8 = "",
            truncated: bool = false,
        };
        const parsed = std.json.parseFromSlice(Msg, self.allocator, payload, .{ .ignore_unknown_fields = true }) catch return;
        defer parsed.deinit();
        const m = parsed.value;
        if (m.xfer != remote.list_xfer) return; // stale (navigated away)

        // Repack into the public DirEntry shape (transient — valid only
        // for the callback).
        var entries = self.allocator.alloc(DirEntry, m.entries.len) catch return;
        defer self.allocator.free(entries);
        for (m.entries, 0..) |e, i| entries[i] = .{ .name = e.name, .is_dir = e.dir, .size = e.size };
        f(self.listing_ctx, .{
            .path = m.path,
            .entries = entries,
            .err = m.@"error",
            .truncated = m.truncated,
        });
    }

    /// Request the remote host's installed-app list. Reply → `on_apps`.
    pub fn requestApps(self: *Terminal) void {
        const remote = self.remote orelse return;
        if (remote.closed) return;
        remote.conn.sendFrame(.app_list, "") catch {};
    }

    /// Start recording this session as an asciicast v2 file. The file
    /// is written by the DAEMON on its host — remote sessions record
    /// to a remote path. `recording` flips when the daemon acks.
    pub fn requestRecordStart(self: *Terminal, path: []const u8) void {
        const remote = self.remote orelse return;
        if (remote.closed) return;
        remote.pending_record = 1;
        remote.conn.sendJson(.rec_start, .{ .path = path }) catch {};
    }

    pub fn requestRecordStop(self: *Terminal) void {
        const remote = self.remote orelse return;
        if (remote.closed) return;
        remote.pending_record = 2;
        remote.conn.sendFrame(.rec_stop, "") catch {};
    }

    fn handleAppListing(self: *Terminal, payload: []const u8) void {
        const f = self.on_apps orelse return;
        const Msg = struct {
            apps: []const struct { name: []const u8 = "", exec: []const u8 = "", icon: []const u8 = "" } = &.{},
            @"error": []const u8 = "",
        };
        const parsed = std.json.parseFromSlice(Msg, self.allocator, payload, .{ .ignore_unknown_fields = true }) catch return;
        defer parsed.deinit();
        var entries = self.allocator.alloc(AppEntry, parsed.value.apps.len) catch return;
        defer self.allocator.free(entries);
        for (parsed.value.apps, 0..) |e, i| entries[i] = .{ .name = e.name, .exec = e.exec, .icon = e.icon };
        f(self.apps_ctx, entries);
    }

    fn handlePeerInfo(self: *Terminal, payload: []const u8) void {
        const Msg = struct { total: u32 = 0, guis: u32 = 0, drivers: u32 = 0 };
        const parsed = std.json.parseFromSlice(Msg, self.allocator, payload, .{ .ignore_unknown_fields = true }) catch return;
        defer parsed.deinit();
        const changed = self.peer_total != parsed.value.total or self.peer_drivers != parsed.value.drivers;
        self.peer_total = parsed.value.total;
        self.peer_drivers = parsed.value.drivers;
        if (changed) {
            if (self.on_peers) |f| f(self.user_ctx);
        }
    }

    /// "file://host/path" → "/path"; otherwise unchanged.
    fn stripFileUri(p: []const u8) []const u8 {
        const pfx = "file://";
        if (!std.mem.startsWith(u8, p, pfx)) return p;
        const after = p[pfx.len..];
        const slash = std.mem.indexOfScalar(u8, after, '/') orelse return p;
        return after[slash..];
    }

    /// Open a non-clobbering file named `name` in the user's Downloads
    /// dir (or $HOME). Returns the open fd + owned absolute path.
    fn openDownloadDest(self: *Terminal, name: []const u8) ?struct { fd: c_int, path: []u8 } {
        const dir_c = c.g_get_user_special_dir(c.G_USER_DIRECTORY_DOWNLOAD) orelse c.g_get_home_dir();
        if (dir_c == null) return null;
        const dir = std.mem.span(@as([*:0]const u8, @ptrCast(dir_c)));
        const dot = std.mem.lastIndexOfScalar(u8, name, '.');
        const stem = if (dot) |d| (if (d == 0) name else name[0..d]) else name;
        const ext = if (dot) |d| (if (d == 0) "" else name[d..]) else "";
        var buf: [4096]u8 = undefined;
        var n: u32 = 0;
        while (n < 1000) : (n += 1) {
            const path = if (n == 0)
                std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ dir, name }) catch return null
            else
                std.fmt.bufPrintZ(&buf, "{s}/{s} ({d}){s}", .{ dir, stem, n, ext }) catch return null;
            const fd = c.open(path.ptr, c.O_WRONLY | c.O_CREAT | c.O_EXCL, @as(c_uint, 0o644));
            if (fd >= 0) {
                const owned = self.allocator.dupe(u8, path) catch {
                    _ = c.close(fd);
                    return null;
                };
                return .{ .fd = fd, .path = owned };
            }
            if (std.posix.errno(fd) != .EXIST) return null;
        }
        return null;
    }

    fn chanData(self: *Terminal, payload: []const u8) void {
        const id = mux_wire.decodeChanId(payload) orelse return;
        if (self.findNApp(id)) |na| return self.nappData(na, payload[4..]);
        if (self.findWsApp(id)) |wa| return self.wsappData(wa, payload[4..]);
        if (self.findAApp(id)) |aa| return self.aappData(aa, payload[4..]);
    }

    fn destroyAllChans(self: *Terminal) void {
        const remote = self.remote orelse return;
        while (remote.napps.items.len > 0) {
            self.destroyNApp(remote.napps.items[remote.napps.items.len - 1]);
        }
        while (remote.wsapps.items.len > 0) {
            self.destroyWsApp(remote.wsapps.items[remote.wsapps.items.len - 1]);
        }
        while (remote.aapps.items.len > 0) {
            self.destroyAApp(remote.aapps.items[remote.aapps.items.len - 1]);
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
        remote.app_window_opened = true;
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
        host.on_first_window = nappFirstWindow;
        host.first_window_ctx = na;
        host.setDriven(self.peer_drivers > 0);
        // Append BEFORE firing on_app_view: the callback reads napps.items[0],
        // which dereferences the empty-slice sentinel (addr 0x8) on the first
        // app if the list is still empty.
        remote.napps.append(self.allocator, na) catch {
            host.destroy();
            self.allocator.destroy(na);
            self.sendChanClose(id);
            return;
        };
        if (self.on_app_view) |f| f(self.user_ctx, @ptrCast(remote.napps.items[0].host));
    }

    /// First toplevel frame of this app channel: NOW the session
    /// counts as having shown a window (channel-open alone doesn't —
    /// single-instance apps connect, hand off, and exit windowless;
    /// those must take the hold-with-log exit path, not detach).
    fn nappFirstWindow(ctx: ?*anyopaque) void {
        const na = @import("util/cast.zig").userData(NApp, ctx);
        const t = na.terminal;
        const remote = t.remote orelse return;
        remote.app_window_opened = true;
        if (t.on_app_window) |f| f(t.user_ctx);
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
        if (self.remote) |remote| {
            for (remote.napps.items, 0..) |it, i| {
                if (it == na) {
                    _ = remote.napps.swapRemove(i);
                    break;
                }
            }
            // Fire BEFORE destroying the host: the pane's handler
            // detaches its mirror from the OLD host via setMirror,
            // which must still be alive here (was a use-after-free).
            if (self.on_app_view) |f| {
                f(self.user_ctx, if (remote.napps.items.len > 0)
                    @ptrCast(remote.napps.items[0].host)
                else
                    null);
            }
        }
        na.host.destroy();
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

    fn sinkCmdStart(ctx: ?*anyopaque) void {
        const self: *Terminal = @ptrCast(@alignCast(ctx.?));
        self.cmd_started_us = c.g_get_monotonic_time();
        if (self.on_cmd_status) |f| f(self.user_ctx, true, 0, 0);
    }

    fn sinkCmdEnd(ctx: ?*anyopaque, exit: i32) void {
        const self: *Terminal = @ptrCast(@alignCast(ctx.?));
        const dur_ms: i64 = if (self.cmd_started_us > 0)
            @divTrunc(c.g_get_monotonic_time() - self.cmd_started_us, 1000)
        else
            0;
        self.cmd_started_us = 0;
        if (self.on_cmd_status) |f| f(self.user_ctx, false, exit, dur_ms);
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
        self.on_crashed = null;
        self.on_activity = null;
        self.on_bell = null;
        self.on_image = null;
        self.on_image_delete_full = null;
        self.on_notification = null;
        self.on_progress = null;
        self.on_pointer_shape = null;
        self.on_set_profile = null;
        self.on_session_renamed = null;
        self.on_recording_changed = null;
        self.on_transfer = null;
        self.on_listing = null;
        self.listing_ctx = null;
        self.on_apps = null;
        self.apps_ctx = null;
        self.on_peers = null;
        // Deferred Terminal.deinit runs destroyAllChans AFTER this
        // fence; a still-set on_app_view would fire into the freed
        // Pane with a nulled user_ctx (was a crash on app-tab close).
        self.on_app_view = null;
        self.on_app_window = null;
        // The app hosts' pane-facing callbacks (banner window-count
        // tracking, embed notifications) point at the Pane too and
        // must be fenced with the rest — window closes arriving after
        // pane teardown would fire into freed memory.
        if (self.remote) |remote| {
            for (remote.napps.items) |na| {
                na.host.on_embed = null;
                na.host.on_request_embed = null;
                na.host.on_windows_changed = null;
                na.host.embed_ctx = null;
            }
        }
        self.on_cmd_status = null;
        self.broadcast_sink = null;
        self.broadcast_ctx = null;
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
            self.cancelUploads();
            self.cancelDownload();
            remote.upload_queue.deinit(self.allocator);
            self.destroyAllChans();
            remote.napps.deinit(self.allocator);
            remote.wsapps.deinit(self.allocator);
            remote.aapps.deinit(self.allocator);
            remote.predictor.deinit();
            if (!remote.closed) {
                // A stalled upload can leave queued frames in conn.wbuf;
                // the kill/detach below must not silently queue behind
                // them and die with the fd. Bounded, best-effort drain.
                remote.conn.flushQueuedFor(remote.conn.write_timeout_ms) catch {};
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

test "nappOpen appends before firing on_app_view (empty-list deref regression)" {
    // Regression: nappOpen used to read remote.napps.items[0] to source the
    // on_app_view host BEFORE appending the new NApp. On the first app window
    // the list was still empty, so items[0] dereferenced the empty-slice
    // sentinel (address 0x8) and the GUI segfaulted the moment any forwarded
    // app opened its first window.
    const alloc = std.testing.allocator;

    const Captured = struct { fired: bool = false, host: ?*anyopaque = null };
    var cap: Captured = .{};
    const Cb = struct {
        fn onView(ctx: ?*anyopaque, host: ?*anyopaque) void {
            const c2: *Captured = @ptrCast(@alignCast(ctx.?));
            c2.fired = true;
            c2.host = host;
        }
    };

    var remote: Terminal.Remote = undefined;
    remote.napps = .empty;
    remote.app_window_opened = false;

    var term: Terminal = undefined;
    term.allocator = alloc;
    term.remote = &remote;
    term.peer_drivers = 0;
    term.on_app_window = null;
    term.user_ctx = &cap;
    term.on_app_view = Cb.onView;

    term.nappOpen(123);

    try std.testing.expectEqual(@as(usize, 1), remote.napps.items.len);
    try std.testing.expect(cap.fired);
    const na = remote.napps.items[0];
    try std.testing.expectEqual(@as(u32, 123), na.id);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(na.host)), cap.host);

    // Channel open alone must NOT count as a shown window: single-
    // instance apps connect to the display, hand off, and exit
    // windowless — only the first toplevel frame flips the flag.
    try std.testing.expect(!remote.app_window_opened);
    try std.testing.expect(na.host.on_first_window != null);
    na.host.on_first_window.?(na.host.first_window_ctx);
    try std.testing.expect(remote.app_window_opened);

    na.host.destroy();
    alloc.destroy(na);
    remote.napps.deinit(alloc);
}

test "destroyNApp fires on_app_view before destroying the host" {
    // Regression: destroyNApp used to destroy the AppHost FIRST and fire
    // on_app_view after. The pane's handler calls setMirror(null) on the
    // OLD host -- freed memory by then (use-after-free on every app-window
    // close). The callback must observe the departing host still alive.
    const alloc = std.testing.allocator;

    const Captured = struct { fired: bool = false, host: ?*anyopaque = null, old_dead: bool = true, old: ?*@import("wlapp.zig").AppHost = null };
    var cap: Captured = .{};
    const Cb = struct {
        fn onView(ctx: ?*anyopaque, host: ?*anyopaque) void {
            const c2: *Captured = @ptrCast(@alignCast(ctx.?));
            c2.fired = true;
            c2.host = host;
            if (c2.old) |h| c2.old_dead = h.dead;
        }
    };

    var remote: Terminal.Remote = undefined;
    remote.napps = .empty;
    remote.wsapps = .empty;
    remote.aapps = .empty;
    remote.app_window_opened = false;
    remote.closed = true; // sendChanClose must not touch conn

    var term: Terminal = undefined;
    term.allocator = alloc;
    term.remote = &remote;
    term.peer_drivers = 0;
    term.on_app_window = null;
    term.user_ctx = null;
    term.on_app_view = null;

    term.nappOpen(7);
    try std.testing.expectEqual(@as(usize, 1), remote.napps.items.len);
    const na = remote.napps.items[0];
    cap.old = na.host;
    term.user_ctx = &cap;
    term.on_app_view = Cb.onView;

    // Park the host: destroy() defers finalFree while a clipboard read
    // is outstanding, keeping the memory valid so the dead flag stays
    // observable under BOTH orderings (deterministic, no UAF in-test).
    na.host.pending_reads = 1;
    term.destroyNApp(na);

    try std.testing.expect(cap.fired);
    try std.testing.expectEqual(@as(?*anyopaque, null), cap.host);
    try std.testing.expect(!cap.old_dead); // host alive at callback time

    // Drain the parked read so the doomed host frees (no test leak).
    cap.old.?.pending_reads = 0;
    try std.testing.expect(cap.old.?.doomed);
    cap.old.?.finalFree();
    remote.napps.deinit(alloc);
    remote.wsapps.deinit(alloc);
    remote.aapps.deinit(alloc);
}

test "clearSinks fences on_app_view (fenced-pane teardown crash regression)" {
    // Regression: clearSinks nulled user_ctx but left on_app_view set, so
    // the deferred Terminal.deinit -> destroyAllChans fired the callback
    // into the freed Pane with a null ctx (SIGSEGV on closing a tab whose
    // app session still had a live Wayland channel).
    const alloc = std.testing.allocator;

    const Captured = struct { fired: bool = false };
    var cap: Captured = .{};
    const Cb = struct {
        fn onView(ctx: ?*anyopaque, host: ?*anyopaque) void {
            _ = host;
            const c2: *Captured = @ptrCast(@alignCast(ctx.?));
            c2.fired = true;
        }
    };

    var remote: Terminal.Remote = undefined;
    remote.napps = .empty;
    remote.wsapps = .empty;
    remote.aapps = .empty;
    remote.app_window_opened = false;
    remote.closed = true; // sendChanClose must not touch conn

    var term: Terminal = undefined;
    term.allocator = alloc;
    term.remote = &remote;
    term.peer_drivers = 0;
    term.on_app_window = null;
    term.user_ctx = &cap;
    term.on_app_view = Cb.onView;

    term.nappOpen(9);
    cap.fired = false;

    term.clearSinks();
    try std.testing.expectEqual(@as(?*anyopaque, null), term.user_ctx);
    term.destroyAllChans();

    try std.testing.expect(!cap.fired); // fence held: nothing reached the pane
    try std.testing.expectEqual(@as(usize, 0), remote.napps.items.len);
    remote.napps.deinit(alloc);
    remote.wsapps.deinit(alloc);
    remote.aapps.deinit(alloc);
}
